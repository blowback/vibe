# Story 1.4: BIOS/BDOS shims with BDOS_CALL macro

Status: done

<!-- Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As the VIBE author,
I want `inc/bios.inc` and `inc/bdos.inc` populated with the BIOS jump-table addresses, BDOS function numbers, and the `BDOS_CALL` checked-call macro,
so that NFR8 (every BDOS rc checked) and NFR15 (CP/M 2.2 BDOS only) are enforced at every future call site by convention, raw `CALL 0x0005` becomes a review-fail by AR15, and the implementation-sequence step 3 (BIOS/BDOS shims) is closed before `statusln.asm` lands in Story 1.5.

## Acceptance Criteria

1. **AC1 — `inc/bios.inc` declares BIOS jump-table addresses, the BDOS entry, the CP/M default-FCB / default-DMA addresses, and a tick-counter address symbol.**
   Given `inc/bios.inc`,
   When I inspect it,
   Then it defines `BIOS_CONIN`, `BIOS_CONINST`, `BIOS_CONOUT` (BIOS jump-table addresses for blocking-read / status / write — used by `input.asm` and `render.asm` in later stories),
   And it defines `BDOS_ENTRY EQU 0x0005`, `DEFAULT_FCB EQU 0x005C`, `DEFAULT_DMA EQU 0x0080` (CP/M 2.2 zero-page well-known addresses),
   And it defines a tick-counter address symbol named `BIOS_TICK_ADDR` (read by `input.asm` for Esc/arrow disambiguation per RI5/NFR4 in Story 1.8 — architecture line 1386 names this symbol explicitly: `LD HL, (BIOS_TICK_ADDR)`),
   And the three jump-table addresses (`BIOS_CONIN`, `BIOS_CONINST`, `BIOS_CONOUT`) and `BIOS_TICK_ADDR` are documented as **Watchpoint W1 placeholders** to be confirmed against MicroBeast BIOS docs/disassembly when init wires hardware bring-up in Story 1.12,
   And a section comment header explains these MUST be sourced from the MicroBeast BIOS jump table (and not invented) before code in any later story actually expands them.

2. **AC2 — `inc/bdos.inc` declares exactly the CP/M 2.2 BDOS function numbers VIBE will use, and only those — NFR15.**
   Given `inc/bdos.inc`,
   When I inspect it,
   Then it defines: `BDOS_EXIT EQU 0` (system reset / warm boot return — used by `:q` in 2.1 and by every `test/cases/*.asm` epilogue per TH1/TH2), `BDOS_CONOUT EQU 2`, `BDOS_OPEN EQU 15`, `BDOS_CLOSE EQU 16`, `BDOS_DELETE EQU 19`, `BDOS_READ_SEQ EQU 20`, `BDOS_WRITE_SEQ EQU 21`, `BDOS_MAKE EQU 22`,
   And no CP/M 3.x extensions are present (no functions 100+, no banked-memory calls, no record-locking calls, no time-of-day calls),
   And no MicroBeast-specific BDOS calls are present (NFR15),
   And every function-number EQU is annotated with a one-line comment naming its purpose plus its return-code shape (e.g. `; FCB ops: A = 0..3 ok / 0xFF fail; READ/WRITE_SEQ: A = 0 ok / 1 EOF / 2-9 err`).

3. **AC3 — `BDOS_CALL` macro is defined in `inc/bdos.inc` and matches the MC6 expansion exactly.**
   Given the macro definition,
   When I expand `BDOS_CALL <fn>` for any function-number constant `fn`,
   Then the expansion is exactly: `LD C, fn` → `CALL BDOS_ENTRY` → `OR A` → `JP M, bdos_error_funnel`,
   And the macro's documentation block (in `inc/bdos.inc`, immediately above the macro) names it as the **single project-wide BDOS gateway** per AR15 / MC6, names raw `CALL 0x0005` as forbidden,
   And the documentation block notes that `bdos_error_funnel` is a forward reference whose body lands in Story 1.5 (statusln.asm or sibling) — for Story 1.4, the macro is a definition only and is **not expanded** anywhere in `src/vibe.asm`,
   And the documentation block calls out the macro's return-code coverage: the `JP M` only catches sign-bit return codes (`0xFF`, the FCB-op fail signal); functions whose failure modes use small positive codes (e.g. `READ_SEQ` returning 1 for EOF, `WRITE_SEQ` returning 1-2 for disk-full / read-only) require the caller to test `A` after the macro returns,
   And `BDOS_CALL` uses UPPER_SNAKE_CASE per AR22 (this is the same condition as AC6 — verifying once is sufficient).

4. **AC4 — Smoke test under iz-cpm: BDOS_CALL with a non-existent FCB is detected, the funnel is entered, and the program exits cleanly.**
   Given a one-off smoke test program at `test/smoke/bdos_call_smoke.asm` (NEW directory; see Project Structure Notes),
   When I assemble it (sjasmplus 1.23.0) and run it under iz-cpm,
   Then the program issues `BDOS_CALL BDOS_OPEN` against an FCB pointing at a filename that does not exist on the mounted drive,
   And the BDOS return code (`A = 0xFF`) is detected by the macro's `OR A : JP M, bdos_error_funnel` sequence,
   And control transfers to a stub `bdos_error_funnel` provided by the smoke test (writes a sentinel byte at `0xCFFE` per TH1 to record "funnel reached" then exits via `BDOS_EXIT`),
   And iz-cpm exits within 5 seconds (no crash, no hang, no infinite loop),
   And the sentinel byte at `0xCFFE` is non-zero on test completion (proving the funnel path was taken — not the success path),
   And the smoke test artifact is **not** committed to `test/cases/` (TH-naming convention is owned by Story 1.6 which lands the harness; the smoke test is a one-off verification, not a permanent harness fixture).

5. **AC5 — `inc/bios.inc` and `inc/bdos.inc` are INCLUDEd by `src/vibe.asm` at their AR25 positions, and `vibe.com` remains byte-identical to the Story 1.3 baseline.**
   Given the AR25 final include order (`equates → bios → bdos → vt52 → modes → state`),
   When I inspect `src/vibe.asm`,
   Then the pre-`ORG 0x0100` include block reads (in order): `equates.inc → bios.inc → bdos.inc → vt52.inc → modes.inc` — the two new INCLUDEs splice between `equates.inc` and `vt52.inc`,
   And the post-`RET` `state.inc` INCLUDE remains unchanged (state.inc is the only header that uses `$` and therefore must INCLUDE after code; bios.inc and bdos.inc are EQU + MACRO only, no `$`, safe in the pre-ORG block alongside equates / vt52 / modes),
   And `make clean && make` succeeds with no errors and no warnings,
   And `sha256sum vibe.com` equals `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a` (Story 1.1 baseline preserved by Stories 1.2 and 1.3),
   And a second `make clean && make` produces the same SHA (NFR18 reproducibility).

6. **AC6 — Casing audit: `BDOS_CALL` is UPPER_SNAKE_CASE per AR22; equate names are UPPER_SNAKE_CASE; no runtime variable names introduced (this story declares no static state).**
   Given the file contents post-implementation,
   When I run `grep -nE '^[A-Z_][A-Z0-9_]*' inc/bios.inc inc/bdos.inc`,
   Then every label-column match is a compile-time constant or macro name (UPPER_SNAKE),
   And `grep -nP '^\t' inc/bios.inc inc/bdos.inc` returns no matches (AR24 — 4-space indent only),
   And `grep -nE '^[a-z_]' inc/bios.inc inc/bdos.inc` returns no matches in label column (no runtime variables introduced).

## Tasks / Subtasks

- [x] **Task 1 — Populate `inc/bios.inc` with BIOS + BDOS-zero-page + tick-counter equates** (AC: 1)
  - [x] Preserve the existing AR23 header block. Update `Public:` from `(none yet — populated in Story 1.4)` to enumerate the symbols this story lands: `BIOS_CONIN`, `BIOS_CONINST`, `BIOS_CONOUT`, `BIOS_TICK_ADDR`, `BDOS_ENTRY`, `DEFAULT_FCB`, `DEFAULT_DMA`. Keep `State owned (read/write):` as `(none — equates and BIOS-managed addresses only)`. Update `Dependencies:` to `(none — bios.inc is a leaf header in the include graph)`. Architecture line 1457-1461 confirms BIOS surfaces are read-only from VIBE's perspective.
  - [x] Add three sections in this order:
    1. `;; --- BIOS jump-table addresses (W1 — placeholders, confirm in Story 1.12) ---` — defines `BIOS_CONIN`, `BIOS_CONINST`, `BIOS_CONOUT`. Use the placeholder values from architecture lines 1097-1099 verbatim: `0xFA06`, `0xFA09`, `0xFA0C`. Add a multi-line section comment naming these as Watchpoint W1 placeholders, sourced from architecture line 1635-1637 (initial-implementation story populates from MicroBeast BIOS docs).
    2. `;; --- CP/M zero-page well-known addresses ---` — defines `BDOS_ENTRY EQU 0x0005`, `DEFAULT_FCB EQU 0x005C`, `DEFAULT_DMA EQU 0x0080`. These are CP/M 2.2 conventions, **not** placeholders, and do not require Story-1.12 confirmation.
    3. `;; --- Tick counter (BIOS-managed, read-only — W1 placeholder) ---` — defines `BIOS_TICK_ADDR` with a placeholder value (e.g., `0xFA00`). Architecture line 1386 names the symbol exactly: `LD HL, (BIOS_TICK_ADDR)`. Treat as 16-bit; the 50 Hz ISR maintains it. Read by `input.asm` (Story 1.8) for Esc/arrow disambiguation per RI5 / NFR4.
  - [x] Reference layout (full body, emit verbatim or with minor cosmetic variation but keep the symbol set, ordering, values, and W1-comment placement):
    ```
    ;; --- BIOS jump-table addresses (W1 — placeholders, confirm in Story 1.12) ---
    ; The MicroBeast BIOS exposes its routines via a jump table at fixed
    ; addresses high in memory. The values below are documented placeholders
    ; per architecture lines 1097-1099; the actual addresses must be
    ; confirmed against MicroBeast BIOS docs / disassembly when init.asm
    ; wires hardware bring-up in Story 1.12 (Watchpoint W1, architecture
    ; lines 1635-1637). Until then no code expands these — wrong values
    ; are inert at assembly time, but MUST be corrected before Story 1.12
    ; or the editor will not run on real hardware.
    BIOS_CONIN     EQU 0xFA06   ; blocking byte read from console
    BIOS_CONINST   EQU 0xFA09   ; nonzero in A if a byte is ready
    BIOS_CONOUT    EQU 0xFA0C   ; emit byte in C to console

    ;; --- CP/M zero-page well-known addresses ---
    ; CP/M 2.2 conventions — NOT MicroBeast-specific, NOT W1 placeholders.
    BDOS_ENTRY     EQU 0x0005   ; CP/M BDOS entry; gateway via BDOS_CALL only (AR15)
    DEFAULT_FCB    EQU 0x005C   ; CP/M default FCB; cmd-line filename lands here
    DEFAULT_DMA    EQU 0x0080   ; CP/M default DMA — 128-byte sector buffer

    ;; --- Tick counter (BIOS-managed, read-only — W1 placeholder) ---
    ; The MicroBeast 50 Hz timer ISR maintains a free-running 16-bit tick
    ; counter at this address. Read via LD HL, (BIOS_TICK_ADDR); compare
    ; for advance-by-N to time the ESC_TIMEOUT_TICKS window in Story 1.8
    ; (input layer / RI5 / NFR4). Architecture line 1386 names the symbol.
    ; Confirm address in Story 1.12 alongside the BIOS jump-table addresses
    ; above.
    BIOS_TICK_ADDR EQU 0xFA00   ; placeholder — confirm in Story 1.12 (W1)
    ```
  - [x] Use 4-space indentation (AR24); UPPER_SNAKE for `EQU` keyword and constant names; `;` for line comments / `;;` for section dividers; no trailing periods on inline comments. Match the existing style of `inc/equates.inc`, `inc/vt52.inc`, `inc/modes.inc` — read those first if uncertain.
  - [x] **Do not** declare `tick_counter` as a runtime variable in `inc/state.inc` — it's BIOS-managed and read-only from VIBE; architecture lines 1384-1386 explicitly route the symbol to `bios.inc`. Story 1.3's dev notes (lines 191, 209) repeat this guardrail.
  - [x] **Do not** define `BDOS_CALL` here — the macro lives in `inc/bdos.inc` (Task 2). `bios.inc` must remain pure-equate so the include order `bios → bdos` makes sense (bdos depends on `BDOS_ENTRY`).

- [x] **Task 2 — Populate `inc/bdos.inc` with CP/M 2.2 BDOS function numbers and the `BDOS_CALL` macro** (AC: 2, 3, 6)
  - [x] Preserve the existing AR23 header block. Update `Public:` from `(none yet — populated in Story 1.4)` to enumerate landed symbols: `BDOS_EXIT`, `BDOS_CONOUT`, `BDOS_OPEN`, `BDOS_CLOSE`, `BDOS_DELETE`, `BDOS_READ_SEQ`, `BDOS_WRITE_SEQ`, `BDOS_MAKE`, `BDOS_CALL` (macro). Keep `State owned (read/write):` as `(none)`. Update `Dependencies:` to `inc/bios.inc (BDOS_ENTRY)` — bdos.inc references the symbol defined by bios.inc; the AR25 include order ensures bios.inc is processed first.
  - [x] Add a `;; --- CP/M 2.2 BDOS function numbers (NFR15) ---` section. Reference layout (function set is closed — do NOT add more without epic-level approval; NFR15 forbids 3.x extensions):
    ```
    ;; --- CP/M 2.2 BDOS function numbers (NFR15 — only 2.2 functions used) ---
    ; FCB ops (OPEN/CLOSE/DELETE/MAKE) return A = 0..3 success / 0xFF fail.
    ; READ_SEQ / WRITE_SEQ return A = 0 success / 1 EOF or partial / 2-9 err.
    ; BDOS_CALL's JP M only catches the sign-bit (0xFF) family; positive
    ; failure codes from READ/WRITE_SEQ require a caller-side A check.
    BDOS_EXIT       EQU 0    ; system reset / warm-boot return to CCP
    BDOS_CONOUT     EQU 2    ; print byte in E (BIOS-direct preferred; reserved)
    BDOS_OPEN       EQU 15   ; open file: DE = FCB; A = 0..3 ok / 0xFF fail
    BDOS_CLOSE      EQU 16   ; close file: DE = FCB; A = 0..3 ok / 0xFF fail
    BDOS_DELETE     EQU 19   ; delete file: DE = FCB; A = 0..3 ok / 0xFF fail
    BDOS_READ_SEQ   EQU 20   ; read sector to DMA: DE = FCB; A = 0 ok / 1 EOF
    BDOS_WRITE_SEQ  EQU 21   ; write sector from DMA: DE = FCB; A = 0 ok / 1+ err
    BDOS_MAKE       EQU 22   ; create file: DE = FCB; A = 0..3 ok / 0xFF fail
    ```
    Comment text may shorten — the function numbers, names, and rc-shape annotation are the contract. `BDOS_CONOUT` is included even though the console path is BIOS-direct (NFR15 / PRD §Input & Keyboard); it stays for completeness and to keep the AC2 enumeration explicit.
  - [x] Add a `;; --- BDOS_CALL macro (MC6 / AR15 / NFR8) ---` section with the documentation block AND macro body. Reference layout:
    ```
    ;; --- BDOS_CALL macro (MC6 / AR15 / NFR8) ---
    ; The single, project-wide gateway to BDOS. Raw `CALL 0x0005` (or
    ; `CALL BDOS_ENTRY` outside this macro) is forbidden by AR15 — every
    ; BDOS call site MUST use BDOS_CALL so the rc check is automatic.
    ;
    ; Expansion (per architecture line 543-548, MC6):
    ;     LD   C, fn
    ;     CALL BDOS_ENTRY        ; 0x0005 from inc/bios.inc
    ;     OR   A                 ; sign flag set if A bit 7 is set (0xFF)
    ;     JP   M, bdos_error_funnel
    ;
    ; Caller contract:
    ;   In:      DE = FCB / param ptr (per BDOS function); other regs as
    ;            documented per BDOS function.
    ;   Out:     A = BDOS rc.
    ;            On sign-bit rc (0xFF): control transfers to
    ;            bdos_error_funnel — this expansion never returns
    ;            normally on a sign-bit return.
    ;            On non-sign rc (0..0x7F): caller MUST inspect A.
    ;            Examples: READ_SEQ rc=1 (EOF), WRITE_SEQ rc=1-2
    ;            (disk-full / read-only) — bit 7 clear, JP M does not
    ;            fire, caller branches on A.
    ;   Trashes: A, BC, DE, HL, F (BDOS function-specific contract)
    ;
    ; bdos_error_funnel is a FORWARD REFERENCE resolved by Story 1.5
    ; (statusln.asm or sibling). Selects an error message by function
    ; number, routes through status_set_message (MC5), then aborts the
    ; current operation (returns to the input loop — never crashes,
    ; NFR5 / NFR8). For Story 1.4 the macro is defined only; no
    ; expansion site exists yet (vibe.com stays byte-identical, AC5).
    ;
    ; AR22: macro name UPPER_SNAKE per "equates and macros UPPER_SNAKE_CASE".

    BDOS_CALL MACRO fn
        LD      C, fn
        CALL    BDOS_ENTRY
        OR      A
        JP      M, bdos_error_funnel
    ENDM
    ```
  - [x] **Macro body — MUST emit no bytes when defined.** sjasmplus's `MACRO` directive defines without expanding; only `BDOS_CALL <arg>` invocations expand. Confirm via Task 3's SHA-identity check. If the .com SHA shifts after this task, the most likely cause is a stray non-macro instruction outside the `MACRO`/`ENDM` block (e.g., a bare `LD C, ...` left at file scope from an aborted edit). Fence the macro carefully.
  - [x] **Forward reference is intentional.** `bdos_error_funnel` does not resolve to a defined symbol at end of Story 1.4. sjasmplus does not error on undefined symbols inside un-expanded macro bodies — the body is text until expansion. Story 1.5 lands the funnel; if `dev-story` accidentally expands `BDOS_CALL` here (e.g., a stray test invocation in `bdos.inc` or `vibe.asm`), the build will fail with `bdos_error_funnel` undefined — which is the diagnostic you want for that mistake.
  - [x] **Do not** define `bdos_error_funnel` in `inc/bdos.inc`. The funnel is **code**, lives in a `.asm` source file (Story 1.5's statusln.asm is the natural home — it owns the status funnel via MC5). Defining the funnel body in `inc/bdos.inc` would either emit bytes (breaking AC5's SHA identity) or require an `IFDEF`-guarded text inclusion that doesn't exist in this project. Story 1.5 will land the funnel as a real routine that calls `status_set_message`.
  - [x] **sjasmplus 1.23.0 macro syntax** — see Library / framework requirements. Use `MACRO` / `ENDM`, not `.macro` / `.endm` and not `MACRO ARGS` (no parens). Argument is a single bareword `fn`. The macro reference pattern above is the canonical sjasmplus form for this version.

- [x] **Task 3 — INCLUDE `bios.inc` and `bdos.inc` in `src/vibe.asm` at their AR25 positions** (AC: 5)
  - [x] Current `src/vibe.asm` pre-`ORG 0x0100` include block (Story 1.3 result):
    ```
    INCLUDE "../inc/equates.inc"
    INCLUDE "../inc/vt52.inc"
    INCLUDE "../inc/modes.inc"
    ```
  - [x] After this story (the AR25 final order, with the new `bios.inc` / `bdos.inc` slots filled):
    ```
    INCLUDE "../inc/equates.inc"
    INCLUDE "../inc/bios.inc"
    INCLUDE "../inc/bdos.inc"
    INCLUDE "../inc/vt52.inc"
    INCLUDE "../inc/modes.inc"
    ```
    Splice the two new INCLUDEs between `equates.inc` and `vt52.inc`. **Order matters**: `bdos.inc` references `BDOS_ENTRY` (defined in `bios.inc`); processing bdos before bios would error at the `BDOS_ENTRY` reference inside the macro body (sjasmplus resolves macro-body symbols at expansion, but the lexical order also matters for some directives — keep the AR25 order to avoid edge cases).
  - [x] Update the AR23 `Dependencies:` line in `src/vibe.asm`'s header from `inc/equates.inc, inc/vt52.inc, inc/modes.inc, inc/state.inc (bios.inc and bdos.inc arrive in Story 1.4)` to `inc/equates.inc, inc/bios.inc, inc/bdos.inc, inc/vt52.inc, inc/modes.inc, inc/state.inc`.
  - [x] Update the pre-ORG section comment in `src/vibe.asm` from "Compile-time-constant includes (dependency order per AR25)" to keep its "Pure-EQU headers that do NOT use $; safe to place before ORG" caveat — bios.inc and bdos.inc are pure-EQU + macro-definition (no `$` use, no emit before expansion), so they belong in the pre-ORG block alongside equates / vt52 / modes. The macro DEFINITION emits no bytes; only EXPANSIONS do, and there are no expansions yet.
  - [x] **Do not** touch the post-`RET` `INCLUDE "../inc/state.inc"` line. Story 1.3 placed it post-RET because state.inc anchors `static_data_base EQU $`; bios.inc and bdos.inc do **not** use `$`, so they correctly belong in the pre-ORG block. The post-RET state.inc INCLUDE remains unchanged.
  - [x] **Do not** touch `ORG 0x0100` or the `RET` body. Same reason as Story 1.3 (Story 1.12 owns init/teardown; AC5's SHA-identity check requires the emitted code byte to remain `0xC9` at `0x0100`).

- [x] **Task 4 — Build, verify clean assembly, verify NFR18 byte-identity** (AC: 5)
  - [x] `make clean && make` — expect zero stdout (sjasmplus `--msg=err` quiet on success). Any warning/error halts the task.
  - [x] `sha256sum vibe.com` — **Expected hash:** `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a` (Story 1.1 baseline; preserved through 1.2 and 1.3). bios.inc declares only EQU labels (no emit). bdos.inc declares EQU labels + a MACRO definition (definitions emit no bytes). The two new INCLUDEs add no bytes to `vibe.com`. **If the SHA differs**, the most likely causes (in priority order):
    1. A bare instruction outside the `MACRO`/`ENDM` fence in `bdos.inc` — e.g. `LD C, BDOS_OPEN` at file scope from a copy-paste accident. Search `bdos.inc` for any line that is not a comment, `EQU`, `MACRO`, `ENDM`, or inside the macro body.
    2. A `DEFB`/`DEFW`/`DEFS`/`DB`/`DW`/`DS`/`BLOCK` directive in either header. Headers must be **pure-equate / macro-definition only** (Story 1.2's "no DEFB in equates" firewall, Story 1.3's "no DEFB in state.inc" firewall — same rule applies here).
    3. An accidental `BDOS_CALL ...` expansion in `vibe.asm` or `bdos.inc`. The macro must remain unexpanded in this story.
  - [x] `make clean && make` a second time — same SHA (NFR18 reproducibility).
  - [x] Inspect `build/vibe.lst` symbol table for the new equates: `BIOS_CONIN`, `BIOS_CONINST`, `BIOS_CONOUT`, `BDOS_ENTRY`, `DEFAULT_FCB`, `DEFAULT_DMA`, `BIOS_TICK_ADDR`, plus the eight `BDOS_*` function-number symbols. All should resolve to their EQU values; `BDOS_CALL` may appear as a macro definition (sjasmplus marks macros differently from EQUs in the listing — both should be present).
  - [x] State.inc's address layout is unaffected — `static_data_base` still resolves to `0x0101` (one byte past the `RET` at `0x0100`). Spot-check this in `build/vibe.lst` if you want extra reassurance; it's a free check that the new pre-ORG INCLUDEs didn't accidentally emit bytes.

- [x] **Task 5 — Smoke test the macro under iz-cpm (AC4)** (AC: 4)
  - [x] Create directory `test/smoke/` (NEW). This is a one-off smoke-test location, **not** the `test/cases/` location owned by Story 1.6's harness. Naming: `bdos_call_smoke.asm` (snake_case, descriptive). Story 1.6 will own `test/cases/*.asm` naming and may relocate or replace this artifact when the harness lands.
  - [x] Test program structure (assemble with sjasmplus, run under iz-cpm):
    ```asm
    ; test/smoke/bdos_call_smoke.asm
    ; One-off smoke test: BDOS_CALL BDOS_OPEN against a non-existent FCB
    ; should detect the 0xFF return, enter bdos_error_funnel, write a
    ; sentinel byte at 0xCFFE (TH1), and exit cleanly via BDOS_EXIT.
    ; NOT part of the Story 1.6 harness — a one-off proof that the macro
    ; expands and runs.
        INCLUDE "../../inc/equates.inc"
        INCLUDE "../../inc/bios.inc"
        INCLUDE "../../inc/bdos.inc"

        ORG 0x0100
        ; Construct an FCB at a fixed local address that names a file
        ; that does not exist on the iz-cpm B: drive (or A:, depending on
        ; mount). 36-byte FCB: drive byte + 8 name + 3 ext + 24 metadata.
        LD      DE, fcb
        BDOS_CALL BDOS_OPEN          ; expansion: LD C,15 / CALL 0005 /
                                     ; OR A / JP M, bdos_error_funnel
        ; If we land here, OPEN returned A != 0xFF — unexpected for a
        ; non-existent file. Mark fail and exit.
        LD      A, 0xEE              ; "unexpected success" fail code
        LD      (0xCFFE), A
        JR      smoke_exit

    bdos_error_funnel:
        ; Funnel was reached as expected — write sentinel and exit.
        LD      A, 0x01              ; "funnel reached" — non-zero pass
        LD      (0xCFFE), A
        JR      smoke_exit

    smoke_exit:
        LD      C, BDOS_EXIT
        CALL    BDOS_ENTRY           ; warm-boot to CCP / iz-cpm exit
        ; Defensive: should never return from BDOS_EXIT. RET to be safe.
        RET

        ;; --- FCB for a file that does not exist ---
        ; CP/M FCB layout (drive byte + 8.3 name + metadata, 36 bytes).
        ; Name "NOFILE  " ext "XXX" — extremely unlikely to exist.
    fcb:
        DEFB 0                       ; drive: 0 = default current
        DEFB "NOFILE  "              ; 8 bytes name (space-padded)
        DEFB "XXX"                   ; 3 bytes extension
        DEFS 24                      ; ex/s1/s2/rc/d/cr/r0/r1/r2 — zeros
    ```
  - [x] Assemble: `sjasmplus --nologo --msg=err --raw=test/smoke/bdos_call_smoke.com test/smoke/bdos_call_smoke.asm` (mirror the production flag set; no `--lst` needed for a one-off).
  - [x] Run under iz-cpm: `cd test/smoke && iz-cpm bdos_call_smoke.com` — should exit within 5 seconds without a crash. iz-cpm prints minimal output on a clean exit.
  - [x] Verify the funnel path was taken. Two acceptable verification methods:
    - **Trace-based:** run with `iz-cpm --call-trace bdos_call_smoke.com` and confirm the trace shows `BDOS function 15 (Open File)` followed by the BDOS_EXIT (function 0) return. Absence of a hang or unrecognized BDOS function indicates clean termination.
    - **Memory-dump-based (preferred — matches Story 1.6's TH1 sentinel pattern):** add a tiny amendment to the smoke test that prints `(0xCFFE)` via `BDOS_CONOUT` before exit — but this requires expanding BDOS_CALL again, which is fine for the smoke. Alternatively, write a minimal harness wrapper that reads `0xCFFE` after iz-cpm exits (post-Story 1.6 territory; for now trace-based is sufficient).
  - [x] **Acceptance**: AC4 is satisfied when the smoke test (a) assembles cleanly with the production header set, (b) runs under iz-cpm without crashing or hanging, and (c) the BDOS_OPEN against the non-existent file produces a 0xFF return that the macro's `JP M` catches (verifiable via `--call-trace` showing no second BDOS call if the funnel exits, or showing only `BDOS_EXIT` after `BDOS_OPEN`). The sentinel-byte mechanism is preferred for parity with TH1 but is not strictly required for this one-off — Story 1.6 will retroactively normalize this.
  - [x] **Do not commit** the smoke .com or any iz-cpm output. The .gitignore already covers `*.com` (Story 1.1). The smoke .asm itself can be committed under `test/smoke/` if you find it useful as a reference; otherwise leave it out — Story 1.6 will provide the proper home.
  - [x] **If iz-cpm is not available locally**, defer AC4's verification to Story 1.6 and add a deferred-work entry citing the dependency. iz-cpm is listed as a prerequisite in `README.md` (Story 1.1); it should be installed already.

- [x] **Task 6 — Verify naming, format, and convention compliance** (AC: 6)
  - [x] AR22 — every label declared in `inc/bios.inc` and `inc/bdos.inc` is UPPER_SNAKE_CASE (compile-time constants and one macro name). `grep -nE '^[A-Z_][A-Z0-9_]*' inc/bios.inc inc/bdos.inc` matches only the declared symbol set; no lowercase labels are introduced (this story declares no runtime variables).
  - [x] AR24 — 4-space indentation, never tabs: `grep -nP '^\t' inc/bios.inc inc/bdos.inc` produces no matches.
  - [x] AR24 — section dividers use `;;`; line comments use `;`; no trailing periods on inline comments. Macro body uses 4-space indentation for its instructions.
  - [x] AR23 header blocks preserved on both files; `Public:` lines updated to enumerate landed symbols; `Dependencies:` lines updated (`bios.inc`: `(none — leaf)`; `bdos.inc`: `inc/bios.inc (BDOS_ENTRY)`).
  - [x] AR15 cross-check: `grep -nE 'CALL +(0x0005|BDOS_ENTRY)' src/ inc/` should match only the `CALL BDOS_ENTRY` line **inside** the `BDOS_CALL` macro body (and the smoke-test's `CALL BDOS_ENTRY` for the BDOS_EXIT call, which is acceptable in a one-off test outside the harness — Story 1.6 / Story 2.1 will revisit whether smoke and test code go through `BDOS_CALL` for non-fatal exits, since the BDOS function 0 path doesn't return). No other matches should exist anywhere in the source tree.

### Review Findings

_Code review run: 2026-05-09. Layers: Blind Hunter + Edge Case Hunter + Acceptance Auditor. AC1–AC6 PASS, all critical guardrails honored, NFR18 SHA matches baseline twice. Decision resolved → 7 patches applied, 1 deferred, 9 dismissed as noise (by-design or out-of-scope). Post-patch `vibe.com` SHA still equals baseline `4fb733be…14de523a`; smoke test re-run under iz-cpm — funnel path taken, clean cold-boot exit._

- [x] [Review][Patch] **`inc/bdos.inc` made self-contained against `BDOS_ENTRY`** — Decision: add a sjasmplus include-guard. Note: sjasmplus 1.23.0's `IFNDEF` checks `DEFINE` symbols, not EQU labels, so the guard uses a `DEFINE BIOS_INC_LOADED` marker placed at the top of `bios.inc` and an `IFNDEF BIOS_INC_LOADED / INCLUDE "bios.inc" / ENDIF` block at the top of `bdos.inc`. Establishes a project-wide include-guard precedent — see deferred-work `inc/state.inc has no IFDEF-style re-include guard` from story 1.3 review for the broader convention question. Source: Edge Case Hunter.

- [x] [Review][Patch] **BDOS_CALL doc block now warns against parenthesised `fn`** [`inc/bdos.inc`] — Caller contract paragraph added: `fn` must be a bareword token or numeric expression; parenthesising (`BDOS_CALL (BDOS_OPEN)`) expands to `LD C, (BDOS_OPEN)` — a 16-bit memory load from address 15 — silently dispatching the wrong BDOS function. Source: Edge Case Hunter.

- [x] [Review][Patch] **`BDOS_CONOUT` inline comment clarified** [`inc/bdos.inc`] — Replaced ambiguous "BIOS-direct preferred; reserved" with "enumerated for AC2 completeness; console path uses BIOS-direct, do not call". Source: Blind Hunter.

- [x] [Review][Patch] **Tick-counter reader contract added to `inc/bios.inc`** [`inc/bios.inc`] — Header doc now explicitly tells Story 1.8 (and any other consumer) that the 16-bit `LD HL, (BIOS_TICK_ADDR)` is non-atomic vs. the 50 Hz ISR (mitigate via DI/EI bracket or read-twice-and-compare) and that wrap-safe comparisons MUST use unsigned `SBC HL,DE` (signed `JP M`/`JP P` inverts at the 0xFFFF→0x0000 boundary). Replaces the previous bare `LD HL, (BIOS_TICK_ADDR)` recommendation. Source: Edge Case Hunter (was F2 + F3).

- [x] [Review][Patch] **Smoke FCB now names a file CP/M cannot match** [`test/smoke/bdos_call_smoke.asm`] — Replaced `"NOFILE  "` with `"?NOFILE "`; the leading `?` is the CP/M wildcard byte and is illegal in real filenames, so the "file does not exist" precondition is structural rather than relying on the iz-cpm mount being free of any specific name. iz-cpm rc still 0xFF; funnel still fires. Source: Edge Case Hunter (was F4).

- [x] [Review][Patch] **Smoke pre-writes a "never ran" sentinel marker** [`test/smoke/bdos_call_smoke.asm`] — Smoke entry now writes `0xAA` to `0xCFFE` before the BDOS_OPEN, so post-run inspection unambiguously distinguishes funnel-path (`0x01`), success-path (`0xEE`), and never-ran/crashed (`0xAA` or pre-run garbage). Source: Edge Case Hunter (was F5).

- [x] [Review][Defer] **Tick-counter placeholder address overlaps BIOS jump table** [`inc/bios.inc`] — `BIOS_TICK_ADDR EQU 0xFA00` is six bytes below `BIOS_CONIN EQU 0xFA06`; on a typical CP/M 2.2 BIOS (17 jumps × 3 bytes = 51 bytes from base) the tick counter would land inside the jump-table region. Both are W1 placeholders mandated verbatim by spec Task 1 from architecture lines 1097-1099 — changing the value here would deviate from the spec contract. Story 1.12 (init/teardown, hardware bring-up) selects real values that lay the tick counter outside the jump table. Source: Blind Hunter + Edge Case Hunter.

_Dismissed as noise (9): macro "never returns" smoke-funnel mismatch (misread of contract — control transfers to funnel; funnel is free to exit); smoke `RET` stack underflow (defensive RET, BDOS_EXIT does not return on real CP/M); Trashes list (accurately describes the BDOS-function-specific worst case); smoke `CALL BDOS_ENTRY` for `BDOS_EXIT` bypassing AR15 (Task 6 explicitly allows this); FCB metadata zeroing (sjasmplus DEFS fills with 0); `BDOS_CALL MACRO` column alignment vs EQU column (cosmetic; sjasmplus canonical form); BDOS_CALL silently passing positive failure codes from READ_SEQ/WRITE_SEQ (by design per MC6; documented in macro doc); BDOS_EXIT vs OR A/JP M unreachable code (function 0 doesn't return; harmless); `bdos_error_funnel` forward-reference unresolved (by design — spec explicitly notes the assembly error from premature expansion is the desired diagnostic; Story 1.5 lands the body); smoke re-INCLUDEs equates.inc (mandated by spec for symmetry)._

## Dev Notes

### Why this story exists

Story 1.4 closes the implementation-sequence step 3 (architecture line 1564-1565: "BIOS / BDOS shims (`bios.inc`, `bdos.inc`) + checked-call macro (MC6) — every later module uses these"). Together with Story 1.2 (compile-time constants) and Story 1.3 (static memory map), this completes the "shared-headers floor" — every cross-module symbol the editor will use is now declared, and the project-wide BDOS gateway is defined. Story 1.5 (statusln.asm + the `bdos_error_funnel` body) and Story 1.7+ (modules that actually expand `BDOS_CALL`) build on this floor.

The single largest reason this story matters: **NFR8 — "every BDOS file-I/O call checks its return value; no return code is ignored"**. A real Z80 codebase fails NFR8 by accident — one untested error path is enough. The `BDOS_CALL` macro turns the error check into a structural property of every call site: invoking BDOS without going through `BDOS_CALL` becomes a code-review red flag (AR15) rather than a hand-audit-every-time obligation. It also serves AR15 (single BDOS gateway), MC6 (checked-BDOS-call macro), and indirectly NFR5 (no crashes — the funnel terminates cleanly rather than letting an unchecked error code corrupt later state).

This story also lands a couple of W1 placeholders that Story 1.12 will revisit: the BIOS jump-table addresses and `BIOS_TICK_ADDR`. They are safe to ship as placeholders because no code expands them yet — wrong values are inert at assembly time. Story 1.12 has the on-hardware bring-up that *would* surface a wrong jump-table address; this story merely declares the symbols.

### Critical guardrails for the dev agent

**🛑 No emit from `inc/bios.inc` or `inc/bdos.inc`.** Both files MUST be EQU + MACRO definition only. No `DEFB` / `DEFW` / `DEFS` / `DB` / `DW` / `DS` / `BLOCK`, no instructions outside the `MACRO`/`ENDM` fence. The AC5 SHA-identity check is the sole tripwire — Story 1.2's "no DEFB in equates" firewall and Story 1.3's "no DEFB in state.inc" firewall apply identically here. If the SHA shifts, see Task 4's diagnostic priority list.

**🛑 `BDOS_CALL` is a macro DEFINITION, not an expansion site.** sjasmplus's `MACRO` / `ENDM` registers the macro for later use; nothing emits until a `BDOS_CALL <fn>` line appears at the call site. Story 1.4 has no call sites in `vibe.asm`. The first real expansion lands in Story 1.7+ (file I/O modules) or Story 2.1 (`:q` warm-boot via `BDOS_CALL BDOS_EXIT`). The smoke test in Task 5 is the only Story 1.4 expansion, and it lives in a one-off file outside `vibe.asm`.

**🛑 `bdos_error_funnel` is a forward reference; do NOT define it in `inc/bdos.inc` or `vibe.asm`.** The funnel body lands in Story 1.5 (statusln.asm or sibling). Defining it here would either emit bytes (breaks AC5) or shadow Story 1.5's definition. Story 1.5's `bdos_error_funnel`:
- selects an error message string from a table indexed by the failed BDOS function number,
- calls `status_set_message`,
- aborts the current operation (returns to the input loop, never crashes).

For the Story 1.4 smoke test (Task 5), the test file provides its own minimal stub funnel inline. That stub is for the smoke test only — it never sees `vibe.asm` or `vibe.com`.

**🛑 `BDOS_ENTRY` lives in `inc/bios.inc`, not in `inc/bdos.inc`.** It is a CP/M zero-page address, not a CP/M function code. Architecture line 1100 places it in bios.inc's example block. Don't duplicate it; bdos.inc references it via the AR25 include order (bios processed before bdos).

**🛑 The function-number set is closed.** AC2 enumerates exactly 8 functions (BDOS_EXIT, BDOS_CONOUT, BDOS_OPEN, BDOS_CLOSE, BDOS_DELETE, BDOS_READ_SEQ, BDOS_WRITE_SEQ, BDOS_MAKE). Architecture line 1104-1111 lists 7 (omits `BDOS_EXIT`); `BDOS_EXIT EQU 0` is required because `:q` (Story 2.1) and every test epilogue (architecture line 1077-1079) use BDOS function 0 to warm-boot. Do **not** add any other function — NFR15 forbids 3.x extensions, and any other 2.2 function (e.g. function 9 print-string, function 11 console-status, function 13 reset-disk) is unnecessary for VIBE's chosen file/console architecture (PRD §Filesystem and §Input & Keyboard pin BIOS-direct console + FCB-only file I/O). If a later story discovers a need, that story extends the set with epic-level approval — not Story 1.4.

**🛑 `BIOS_CONIN`, `BIOS_CONINST`, `BIOS_CONOUT`, `BIOS_TICK_ADDR` are W1 placeholders.** Use the architecture-suggested values verbatim (`0xFA06`, `0xFA09`, `0xFA0C`, and a similar high-memory placeholder like `0xFA00` for the tick counter). Do NOT attempt to look up real MicroBeast BIOS addresses now — the dev does not have access to that documentation in this story. Story 1.12 will replace these with real values when init.asm wires hardware bring-up; until then no code expands the addresses, so wrong values are inert. Confirming addresses from BIOS docs is **explicitly Story 1.12's job** (Watchpoint W1, architecture line 1635-1637).

**🛑 AR25 INCLUDE order matters for symbol resolution.** `bdos.inc` references `BDOS_ENTRY` (defined in `bios.inc`). Place `bios.inc` before `bdos.inc` in `vibe.asm`'s pre-ORG include block. The full pre-ORG order after this story: `equates → bios → bdos → vt52 → modes`. The post-RET `state.inc` is unchanged.

**🛑 The macro's `JP M` only catches sign-bit returns.** For BDOS functions whose failure modes use small positive codes (`READ_SEQ` rc=1=EOF, `WRITE_SEQ` rc=1-2=disk-full / read-only), the caller must inspect `A` after `BDOS_CALL` returns. The macro's documentation block (Task 2) flags this; future fileio.asm story (in Epic 2) will add caller-side branches on positive failure codes. Do not change the macro to handle them — the architecture's MC6 specifies `OR A : JP M` exactly, and broadening to `JR NZ` would also branch on success codes 1-3 from FCB ops.

**🛑 `inc/equates.inc`'s notes block (lines 55-64) talks about state.inc / GAP_BUFFER_BASE.** It does NOT need any update for this story. Don't touch equates.inc; everything Story 1.4 needs is already there (no new size knobs introduced).

**🛑 sjasmplus 1.23.0 macro-name placement.** The canonical sjasmplus form is:
```
NAME    MACRO  args
        body
        ENDM
```
The "NAME MACRO args" form puts the macro name in the label column and `MACRO` as the directive. The alternative "MACRO NAME args / body / ENDM" form is also accepted but unconventional. Use the first form. The reference pattern in Task 2 follows the canonical form.

### Architecture compliance — what AR\* / SR\* / NFR\* / MC\* rules this story locks in

| Rule | Story 1.4 obligation |
|---|---|
| AR7 | `inc/bios.inc` populated as the BIOS jump-table address header (CONIN, CONINST, CONOUT, tick counter). |
| AR8 | `inc/bdos.inc` populated as the BDOS function-number header + `BDOS_CALL` macro home. |
| AR15 | `BDOS_CALL` macro is the single BDOS gateway; raw `CALL 0x0005` is forbidden by convention. The macro's documentation block makes this the literal contract. |
| AR22 | `BDOS_CALL`, `BIOS_*`, `BDOS_*`, `DEFAULT_FCB`, `DEFAULT_DMA` all UPPER_SNAKE_CASE (constants and macros). |
| AR23 | Existing AR23 header blocks preserved; `Public:` enumerates landed symbols; `Dependencies:` reflects the new bios → bdos chain. |
| AR24 | UPPERCASE directives (`EQU`, `MACRO`, `ENDM`); 4-space indentation; `;` line / `;;` section comments; no trailing periods. |
| AR25 | INCLUDE order in `vibe.asm`: `equates → bios → bdos → vt52 → modes` (pre-ORG block, AR25 final order with `bios`/`bdos` slots filled this story). state.inc remains post-RET. |
| MC6 | `BDOS_CALL` macro defined per the exact MC6 expansion: `LD C, fn` / `CALL BDOS_ENTRY` / `OR A` / `JP M, bdos_error_funnel`. |
| NFR5 | No crashes: the macro's `JP M, bdos_error_funnel` ensures every BDOS error transfers to a controlled abort path (Story 1.5 lands the funnel body that closes the loop). |
| NFR8 | Every BDOS rc check is automatic at every call site that uses the macro; AR15 makes non-macro calls a review-fail. |
| NFR15 | bdos.inc enumerates only CP/M 2.2 functions (0, 2, 15, 16, 19, 20, 21, 22). No 3.x extensions, no MicroBeast-specific BDOS calls. |
| NFR16 | All BIOS / BDOS magic addresses and codes are named equates in their dedicated headers. No magic numbers in code. |
| NFR18 | `vibe.com` SHA-256 unchanged from Story 1.1 baseline. bios.inc / bdos.inc emit no bytes (EQU + MACRO definition only). |
| W1 | BIOS jump-table placeholders documented and bounded to Story 1.12 confirmation. |

### Existing files — current state and what this story changes

**`inc/bios.inc`** *(19 lines, AR23 header only — `Public: (none yet — populated in Story 1.4)`):*
- Current: header block; body empty.
- This story: keep the header (update `Public:` to enumerate the landed symbols and update `Dependencies:` to `(none — leaf)`); append the three sections per Task 1 (BIOS jump-table addresses with W1 comment, CP/M zero-page addresses, tick-counter address with W1 comment).

**`inc/bdos.inc`** *(21 lines, AR23 header only — `Public: (none yet — populated in Story 1.4; will export BDOS_CALL macro and BDOS_* function-code equates)`):*
- Current: header block; body empty.
- This story: keep the header (update `Public:` to enumerate landed symbols and update `Dependencies:` to `inc/bios.inc (BDOS_ENTRY)`); append the BDOS function-number block per Task 2; append the `BDOS_CALL` macro definition with its documentation block per Task 2.

**`src/vibe.asm`** *(48 lines: AR23 header + 3-line pre-ORG include block + `ORG 0x0100` + `RET` + post-RET state.inc INCLUDE):*
- Current: pre-ORG includes `equates → vt52 → modes`; post-RET includes `state`. AR23 `Dependencies:` line names all six headers and notes that bios/bdos arrived in 1.4 (well, the comment will need updating after this story).
- This story: insert two new lines in the pre-ORG block — `INCLUDE "../inc/bios.inc"` and `INCLUDE "../inc/bdos.inc"` — between `equates.inc` and `vt52.inc`. Update header `Dependencies:` line to drop the "bios/bdos arrive in Story 1.4" parenthetical. Pre-ORG section comment ("Pure-EQU headers that do NOT use $; safe to place before ORG") remains accurate — bios.inc and bdos.inc fit the description (pure EQU + macro definition, no `$` reference, no emit).

**Files NOT touched by this story (do not edit):**

- `inc/equates.inc` — Story 1.2's content + Story 1.3's review patches. No new equates needed for this story.
- `inc/state.inc` — Story 1.3's content. **Crucially**, `tick_counter` is **NOT** added here (architecture lines 1384-1386 + Story 1.3 dev notes line 191 explicitly route the symbol to `bios.inc`). This story declares `BIOS_TICK_ADDR` in bios.inc; no state.inc touch.
- `inc/vt52.inc`, `inc/modes.inc` — Story 1.2's content; no changes.
- `Makefile` — `$(wildcard inc/*.inc)` already picks up bios.inc and bdos.inc for rebuild dependency. No Makefile change.
- `test/Makefile` — Story 1.6 will replace it with the real harness; this story does not touch it. The smoke test in Task 5 is invoked manually, not via `make test`.
- `_bmad-output/implementation-artifacts/deferred-work.md` — touch only if Task 5's iz-cpm smoke test is deferred (e.g., iz-cpm not available); add a single bullet under a "Deferred from: code review of story-1.4" header if so.

**File created by this story:**

- `test/smoke/bdos_call_smoke.asm` — one-off smoke test for AC4. Lives in a NEW `test/smoke/` directory. **Not** part of the harness; `test/cases/` is owned by Story 1.6.

### Library / framework requirements

**sjasmplus 1.23.0 specifics relevant to this story:**

- **`MACRO` / `ENDM` directives** define a parameterized macro. Canonical form for sjasmplus 1.x:
  ```
  BDOS_CALL   MACRO  fn
              LD     C, fn
              CALL   BDOS_ENTRY
              OR     A
              JP     M, bdos_error_funnel
              ENDM
  ```
  The macro name in the label column, `MACRO` as the directive, single argument `fn` (no parens). `ENDM` closes the body. Macro arguments are textual substitution at expansion time.

- **Macro definitions emit no bytes.** Only macro **expansions** (i.e., references to `BDOS_CALL <fn>` at code-emission sites) emit bytes. This story has no expansion in `vibe.asm`, so `vibe.com` stays byte-identical.

- **Forward references inside macro bodies.** sjasmplus accepts `JP M, bdos_error_funnel` inside a macro body even when `bdos_error_funnel` has not yet been defined. The reference is resolved at macro-expansion time. Since this story does not expand `BDOS_CALL` in any production source file, the forward reference never materializes — no error. (The Task 5 smoke test does expand the macro and provides its own local `bdos_error_funnel` stub for the expansion to resolve against.)

- **`EQU` is single-assignment.** Each constant gets one `EQU`. Don't redefine.

- **`$` is the current program counter.** Bios.inc and bdos.inc must NOT use `$` — they're processed in the pre-ORG block where `$` is undefined / 0. Story 1.3's state.inc deliberately uses `$` and lives post-RET for that reason; bios.inc and bdos.inc deliberately do NOT use `$` and live pre-ORG.

- **`--raw=<file>`** writes a flat binary from the lowest emitted byte to the highest. With bios.inc / bdos.inc emitting nothing, the .com size remains 1 byte (the `RET` at `0x0100`), SHA matches baseline.

- **`--msg=err`** suppresses informational messages on success. Inherited from Story 1.1's flag set; do not modify.

### CP/M 2.2 BDOS reference (for the dev agent's mental model)

CP/M 2.2 BDOS is invoked by `LD C, function_number` + (function-specific param in DE / E / etc.) + `CALL 0x0005`. Functions used in VIBE:

| Func | Name | Param | Returns |
|---|---|---|---|
| 0 | System Reset / Exit | — | does not return; warm-boots to CCP |
| 2 | Console Output | E = byte | A = trashed; no error code |
| 15 | Open File | DE = FCB | A = 0..3 (directory code) on success / 0xFF on fail |
| 16 | Close File | DE = FCB | A = 0..3 on success / 0xFF on fail |
| 19 | Delete File | DE = FCB | A = 0..3 on success / 0xFF on fail |
| 20 | Read Sequential | DE = FCB | A = 0 ok / 1 EOF / 9-12 hardware error |
| 21 | Write Sequential | DE = FCB | A = 0 ok / 1 dir full / 2 disk full / 0xFF read-only |
| 22 | Make File | DE = FCB | A = 0..3 on success / 0xFF on fail |

The `BDOS_CALL` macro's `OR A : JP M, bdos_error_funnel` catches the 0xFF returns from the FCB ops cleanly. For READ_SEQ / WRITE_SEQ where rc=1-2 means partial failure, the caller branches on `A` after the macro returns. This division of labor is intentional — the macro covers the common-case categorical failure (fail vs. ok-or-non-fatal); the caller covers the function-specific semantics (EOF vs. disk-full vs. ok).

### Previous story intelligence (Stories 1.1, 1.2, 1.3)

**From Story 1.1:**
- **NFR18 baseline SHA:** `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a`. Stories 1.2 and 1.3 preserved it; Story 1.4 must too.
- `vibe.com` lives at the project root (BA1).
- The Makefile has a `check-toolchain` order-only prereq enforcing sjasmplus 1.23.0 (NFR14). Don't relitigate.
- iz-cpm is listed in README.md prerequisites; available locally for Task 5's smoke test.

**From Story 1.2:**
- The pattern "land content + INCLUDE in the same story" is established. Story 1.4 follows it for `bios.inc` and `bdos.inc` together (not split across two sub-stories — the macro depends on `BDOS_ENTRY` from bios.inc, and the include order makes them naturally co-arriving).
- INCLUDE order strictly follows AR25; with empty slots when files aren't yet populated. After 1.4 the AR25 slots are: `equates → bios → bdos → vt52 → modes → state` — every slot filled.
- AR23 header `Public:` lines kept in sync with file content.
- Code review style: Blind Hunter + Edge Case Hunter + Acceptance Auditor. Story 1.2's reviewers caught NFR16-spirit violations (literal `80`s drifting from `SCREEN_COLS`) and a missing `STATUS_ROW` derivation. Expect similar scrutiny on bios.inc / bdos.inc — particularly on whether comment annotations are **complete** for a future maintainer (e.g. "is the rc-shape annotation present on every function-number EQU?", "is the macro's caller contract documented?", "is the W1-placeholder caveat unmistakable?"). Pre-emptively be thorough on doc.
- Story 1.2 review patched `equates.inc` and `vt52.inc`; one item deferred (`VT52_GOTO` row/col clamp → Story 1.11). No bdos.inc / bios.inc dependency on that.

**From Story 1.3:**
- The "🛑 No DEFB / DEFW / DEFS in headers" firewall is now a project-wide convention (Story 1.2 and 1.3 each cited it). bios.inc and bdos.inc are EQU + MACRO only — same rule.
- Story 1.3 placed `state.inc`'s INCLUDE post-RET because `state.inc` uses `$`. bios.inc and bdos.inc do NOT use `$`, so they go in the pre-ORG block — no symmetry trap.
- AR25 final include order, with bios/bdos still-empty slots, was achieved in 1.3 by naming bios/bdos as future-arrivals. This story fills those slots — reproduce 1.3's hand-off pattern: update `vibe.asm`'s AR23 `Dependencies:` line to drop the parenthetical.
- Story 1.3's review hardened the layout against drift (`FILENAME_BUFFER_SIZE` and `DIRTY_ROWS_BITMAP_BYTES` equates, lower-bound ASSERTs, `yank_end` sentinel, equates.inc Notes block patched). For Story 1.4, the equivalent drift hardening would be: **annotate every BDOS function-number EQU with its rc-shape**, **document the `JP M`-only-catches-sign-bit limitation in the macro doc block**, **add the W1-confirm-in-Story-1.12 callout to every BIOS placeholder**. The reference patterns in Tasks 1 and 2 already include these — adopt them directly.
- Deferred-work entries from 1.3 reviewed for relevance to 1.4: none of the seven deferred items affect this story (search/ex length-byte conventions belong to consumers; static-state zero-init belongs to 1.12; shadow-buffer alignment belongs to 1.11; mode-state protocol belongs to 1.9/1.10; per-section sentinels and IFDEF guards are project-wide; EQU-only vs positional .inc convention is a docs cleanup). Do not pre-address them in this story.

### Git intelligence

Three commits on `main` after Story 1.3:

- `b561c9e` — Story 1.1: Makefile pins sjasmplus 1.23.0, produces vibe.com.
- `eac5ba3` — Story 1.2: named every constant the editor needs, in three .inc headers, wired in.
- `a298547` — Story 1.3: Laid out the editor's full memory map at fixed addresses, build-time guarded.

Conventions visible in the tree (preserve):
- 4-space indentation, UPPERCASE mnemonics/directives, `;` line / `;;` section comments.
- `inc/*.inc` files are pure non-emitting (Stories 1.2 and 1.3 used only `EQU` and `=` and `ASSERT`; Story 1.4 adds `MACRO` / `ENDM` — also non-emitting until expansion).
- Header blocks (AR23) on every `.asm`/`.inc` file — preserve.
- `Makefile`'s `SOURCES := $(wildcard src/*.asm) $(wildcard inc/*.inc)` rebuilds when any `.inc` changes — no Makefile edit needed.
- One story per commit; short imperative subject + colon-separated context.

Commit-message form for Story 1.4 (when the dev finishes): `story 1.4: BIOS jump-table addresses, CP/M 2.2 BDOS function numbers, BDOS_CALL macro — the project-wide BDOS gateway (NFR8 / AR15 / MC6).` Match the prior tone.

### Latest tech information

- **sjasmplus 1.23.0 macro semantics** — `MACRO` / `ENDM` register a textual macro; expansions resolve symbols at expansion time. Forward references inside macro bodies are legal as long as the symbol is defined before the first expansion. The `--raw` output mode emits the contiguous range from lowest to highest emitted byte; macro definitions and EQUs do not advance the PC.

- **CP/M 2.2 BDOS** is well-documented (Digital Research's CP/M 2.2 Operating System Manual, freely available). Function semantics summarized in the table above. The "FCB ops return 0..3 success / 0xFF fail" pattern dates to CP/M 1.4 and is stable through 2.2 and unchanged in 3.x for these functions (NFR15 forbids 3.x-specific behaviors only; the 2.2 functions retain identical signatures in 3.x). VIBE will not call any 3.x-only function.

- **iz-cpm** (the host emulator used for headless testing) is at `~/.local/bin/iz-cpm` per local check; supports the standard CP/M 2.2 BDOS contract; `--call-trace` flag traces BDOS calls; mounts a directory as drive A: by default and an optional `--disk-b` for B:. For Task 5's smoke test, the default A: mount is sufficient — the FCB's drive byte 0 = "use current default" which iz-cpm interprets as the first mounted disk.

- **No web research relevant.** Story 1.4 is platform-fixed (CP/M 2.2 + sjasmplus 1.23.0); no third-party APIs, library versions, or framework upgrades to verify.

### Testing requirements

This story has **one mechanical headless test** (Task 5's smoke test) plus the standard build-time mechanical checks. The full iz-cpm test harness lands in Story 1.6; until then verification is:

1. `make clean && make` succeeds with no errors and no warnings.
2. `sha256sum vibe.com` equals `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a` (Story 1.1 / 1.2 / 1.3 baseline).
3. `make clean && make` a second time produces the same SHA (NFR18 reproducibility).
4. `build/vibe.lst` symbol table contains every Task 1 and Task 2 declared symbol.
5. AR22 case audit: `grep -nE '^[a-z_]' inc/bios.inc inc/bdos.inc` matches no labels (no runtime variables introduced).
6. AR24 indent audit: `grep -nP '^\t' inc/bios.inc inc/bdos.inc` matches nothing.
7. AR15 cross-check: `grep -nE 'CALL +(0x0005|BDOS_ENTRY)' src/ inc/` matches only the `CALL BDOS_ENTRY` inside the `BDOS_CALL` macro body.
8. **Smoke test (Task 5)**: `test/smoke/bdos_call_smoke.com` runs under iz-cpm without crashing or hanging; the BDOS_OPEN against a non-existent file produces a 0xFF return that the macro's `JP M` catches; the program exits via `BDOS_EXIT` (BDOS function 0) within 5 seconds.

Once Story 1.6 lands the proper harness, this smoke test may be normalized into `test/cases/bdos_call_smoke.asm` with a sentinel-byte epilogue, or replaced by per-function tests under `test/cases/fileio_*.asm` (Story 2.4 territory).

### Project Structure Notes

This story creates one new directory:

- `test/smoke/` (NEW) — one-off smoke tests not part of the harness. Story 1.6 owns `test/cases/` (the harness location); `test/smoke/` is for ad-hoc verification before the harness exists. After Story 1.6, `test/smoke/` may be retired or repurposed; for now it cleanly separates "verification I ran by hand" from "harness fixtures". The directory is not gitignored; whether to commit `bdos_call_smoke.asm` is the dev's call (it's a useful reference but Story 1.6 may supersede it). The compiled `*.com` is gitignored by the project's .gitignore (Story 1.1).

No other structural changes. The `Complete Project Directory Structure` in architecture.md (lines 1241-1339) anticipates `inc/bios.inc` and `inc/bdos.inc` exactly as this story populates them. `test/smoke/` is not in the architecture's directory tree — it's a Story-1.4-specific transitional location.

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md#story-14-biosbdos-shims-with-bdos-call-macro] (lines 386-422)
- AR7 (`bios.inc` purpose): [Source: _bmad-output/planning-artifacts/epics.md] line 153
- AR8 (`bdos.inc` purpose, BDOS_CALL macro home): [Source: _bmad-output/planning-artifacts/epics.md] line 154
- AR15 (single BDOS gateway, raw `CALL 0x0005` forbidden): [Source: _bmad-output/planning-artifacts/epics.md] line 164
- AR22 (UPPER_SNAKE for macros), AR23 (header block), AR24 (format), AR25 (include order): [Source: _bmad-output/planning-artifacts/epics.md] lines 177-180
- MC6 (`BDOS_CALL` macro spec): [Source: _bmad-output/planning-artifacts/architecture.md] lines 543-548
- bios.inc / bdos.inc example layout: [Source: _bmad-output/planning-artifacts/architecture.md] lines 1095-1123
- BIOS_TICK_ADDR symbol name: [Source: _bmad-output/planning-artifacts/architecture.md] line 1386
- bios.inc / bdos.inc directory structure intent: [Source: _bmad-output/planning-artifacts/architecture.md] lines 1260-1265
- AR25 full module include order example: [Source: _bmad-output/planning-artifacts/architecture.md#file-structure-patterns] lines 918-951
- Watchpoint W1 (BIOS jump-table placeholders, init.asm wiring): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1635-1637
- NFR8 (BDOS rc check completeness): [Source: _bmad-output/planning-artifacts/prd.md]; [Source: _bmad-output/planning-artifacts/epics.md] line 117
- NFR15 (CP/M 2.2 BDOS only): [Source: _bmad-output/planning-artifacts/epics.md] line 130
- NFR18 (reproducible build, baseline SHA): [Source: _bmad-output/planning-artifacts/epics.md] line 136
- TH1 sentinel byte at 0xCFFE: [Source: _bmad-output/planning-artifacts/architecture.md] lines 710-716
- Test prologue/epilogue conventions (BDOS function 0 exit): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1058-1084
- CP/M zero-page well-known addresses (FCB at 0x005C, DMA at 0x0080, BDOS at 0x0005): [Source: _bmad-output/planning-artifacts/prd.md] §Hardware & Memory; [Source: _bmad-output/planning-artifacts/architecture.md] lines 99-103
- Story 1.1 baseline SHA preserved: [Source: _bmad-output/implementation-artifacts/1-1-project-skeleton-reproducible-build.md]
- Story 1.2 hand-off ("no DEFB in equates", land content + INCLUDE together): [Source: _bmad-output/implementation-artifacts/1-2-compile-time-constants-equates-modes-vt52.md]
- Story 1.3 hand-off (state.inc post-RET, bios.inc / bdos.inc still empty stubs, AR25 final order): [Source: _bmad-output/implementation-artifacts/1-3-static-memory-map-state-inc.md] lines 137-147, 191
- Implementation sequence step 3 (BIOS/BDOS shims position in build order): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1564-1565
- Deferred-work register (no items relevant to story 1.4): [Source: _bmad-output/implementation-artifacts/deferred-work.md]

## Dev Agent Record

### Agent Model Used

claude-opus-4-7[1m]

### Debug Log References

- `make clean && make` — clean assemble, no stdout, no warnings.
- `sha256sum vibe.com` (run twice across `make clean && make`):
  `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a` — matches the Story 1.1 baseline byte-for-byte. NFR18 preserved.
- `build/vibe.lst` — verified the seven `inc/bios.inc` symbols, the eight `BDOS_*` function-number EQUs, and the `BDOS_CALL MACRO fn` directive are all present. `static_data_base` still resolves at `0x0101` (one byte past the `RET` at `0x0100`) — confirms the new pre-ORG includes emit no bytes.
- Smoke test (Task 5): `test/smoke/bdos_call_smoke.com` (68 bytes), assembled with the production flag set. Run under iz-cpm with `--call-trace`:
  - `[[BDOS command 15: F_OPEN(0120)]]` — confirms the macro emitted `LD C,15 / CALL 0x0005` correctly and DE pointed at the local FCB.
  - `[[Open file NOFILE.XXX]][[=>ff]]` — BDOS returned `0xFF` for the absent file, so the macro's `OR A : JP M, bdos_error_funnel` fired and routed control to the smoke's local stub funnel.
  - `[[Cold boot]]` — the stub funnel ran `BDOS_EXIT` (function 0), iz-cpm warm-booted out cleanly. Exit code 0, well under the 5-second budget. Sentinel byte at `0xCFFE` was written by the funnel path (not observable from outside without a memory-dump probe; trace evidence is sufficient per AC4's two-method allowance).
- AR22 / AR24 / AR15 audits (Task 6) — all clean. The only `CALL BDOS_ENTRY` instruction in `src/` + `inc/` is at `inc/bdos.inc:74`, inside the `BDOS_CALL` macro body, exactly where AR15 requires it.

### Completion Notes List

- All six ACs satisfied. No deviations from the story's reference layouts.
- The `BDOS_CALL` macro is a pure definition in this story — no expansion site exists in `src/vibe.asm`. The first production expansion will land in Story 1.7+ (file I/O) or Story 2.1 (`:q` via `BDOS_CALL BDOS_EXIT`). The Task 5 smoke test is the only Story-1.4 expansion and lives in a one-off file outside `vibe.asm`.
- The smoke test ships its own local `bdos_error_funnel` stub so the macro's forward reference resolves at expansion time. Story 1.5's real funnel (statusln.asm) supersedes this when production code starts expanding the macro.
- `test/smoke/bdos_call_smoke.asm` is left in the tree as a runnable reference. The compiled `.com` is covered by the project `.gitignore` (`*.com`). Story 1.6 owns `test/cases/` and may relocate or replace this artifact.
- No edits to `inc/equates.inc`, `inc/state.inc`, `inc/vt52.inc`, `inc/modes.inc`, `Makefile`, or `test/Makefile` — none were required.
- W1 placeholders intact: `BIOS_CONIN`, `BIOS_CONINST`, `BIOS_CONOUT`, `BIOS_TICK_ADDR` use the architecture-suggested values (`0xFA06`, `0xFA09`, `0xFA0C`, `0xFA00`) with prominent "confirm in Story 1.12" callouts. Wrong-value risk is inert at assembly time because no production code expands them yet.
- No new deferred-work entries.

### File List

**Modified:**
- `inc/bios.inc` — header `Public:` and `Dependencies:` updated; three sections added (BIOS jump table W1, CP/M zero page, BIOS_TICK_ADDR W1).
- `inc/bdos.inc` — header `Public:` and `Dependencies:` updated; eight `BDOS_*` function-number EQUs and the `BDOS_CALL` macro (with documentation block) added.
- `src/vibe.asm` — `Dependencies:` line updated; `INCLUDE "../inc/bios.inc"` and `INCLUDE "../inc/bdos.inc"` spliced into the pre-ORG block between `equates.inc` and `vt52.inc` (AR25 final order).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — story `1-4-bios-bdos-shims-with-bdos-call-macro` advanced from `ready-for-dev` → `in-progress` → `review`.
- `_bmad-output/implementation-artifacts/1-4-bios-bdos-shims-with-bdos-call-macro.md` — task checkboxes ticked, Dev Agent Record / File List / Change Log filled, Status set to `review`.

**Created:**
- `test/smoke/` (new directory).
- `test/smoke/bdos_call_smoke.asm` — one-off AC4 smoke test (assembles standalone; runs under iz-cpm; verifies macro expansion + funnel path + clean exit).

**Untracked build outputs (gitignored, not committed):**
- `vibe.com`, `build/vibe.lst`, `build/vibe.sld`, `test/smoke/bdos_call_smoke.com`.

### Change Log

| Date | Author | Change |
|------|--------|--------|
| 2026-05-09 | Story author | Initial story context — populates inc/bios.inc with BIOS jump-table + zero-page + tick-counter equates (W1 placeholders), inc/bdos.inc with CP/M 2.2 BDOS function numbers + BDOS_CALL macro (MC6 / AR15 / NFR8 enforcement), splices both INCLUDEs into vibe.asm at AR25 positions, smoke-tests the macro under iz-cpm, preserves NFR18 baseline SHA. |
| 2026-05-09 | Amelia (dev agent) | Implementation complete. Populated inc/bios.inc and inc/bdos.inc per the reference layouts; spliced both INCLUDEs into src/vibe.asm at the AR25-final positions; built twice — `vibe.com` SHA equals the Story 1.1 baseline `4fb733be…14de523a` (NFR18 preserved); ran the iz-cpm smoke test — F_OPEN against NOFILE.XXX returned 0xFF, the macro's `JP M` fired, the stub funnel exited via BDOS function 0 (clean cold boot under the 5-second budget); AR22 / AR24 / AR15 audits all clean. Status: review. |
| 2026-05-09 | Code reviewer | Code review complete. Acceptance Auditor: AC1–AC6 PASS, critical guardrails honored, NFR18 SHA preserved. Triage (after user pushback on over-eager deferral): 7 patches applied — (1) sjasmplus include guard via `DEFINE BIOS_INC_LOADED` marker in bios.inc + `IFNDEF` block in bdos.inc; (2) BDOS_CALL doc warns against parenthesised `fn`; (3) BDOS_CONOUT inline comment clarified; (4) tick-counter reader contract added to bios.inc (DI/EI bracket for atomicity, unsigned `SBC HL,DE` for wrap); (5) smoke FCB now `?NOFILE.XXX` — leading `?` is the CP/M wildcard byte, structurally illegal as a real filename, so absence is structural; (6) smoke pre-writes `0xAA` "never ran" sentinel; (7) re-ran smoke under iz-cpm: F_OPEN(?NOFILE.XXX) → 0xFF, JP M fired, cold boot. Post-patch `vibe.com` SHA still `4fb733be…14de523a`. 1 item deferred (BIOS_TICK_ADDR placeholder overlap — value mandated verbatim by spec Task 1; Story 1.12 picks real values). Status: done. |
