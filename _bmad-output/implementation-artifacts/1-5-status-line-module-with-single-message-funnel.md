# Story 1.5: Status-line module with single-message funnel

Status: done

<!-- Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As the VIBE author,
I want `src/statusln.asm` exposing `status_set_message` as the single error/info funnel, plus the message-string convention table and the body of `bdos_error_funnel` that Story 1.4 left as a forward reference,
so that MC5 (single status funnel) and AR12 (only `statusln.asm` writes `status_buffer`) become structural rules rather than review-time conventions, every later module's error/info path has a working entry point, AR16's lowercase / no-period / under-30-chars message style ships with concrete examples, and the implementation-sequence step 4 (`statusln.asm`) is closed before any feature work depends on the funnel.

## Acceptance Criteria

1. **AC1 — `src/statusln.asm` ships with the AR23 module header naming its public surface, owned state, register conventions, and dependencies.**
   Given `src/statusln.asm`,
   When I inspect its module header,
   Then it documents `Module: statusln`, `Purpose:` (the single status / error funnel; owns the bottom screen-row buffer; lands the `bdos_error_funnel` body that Story 1.4 forward-referenced),
   And `Public:` lists `status_set_message`, `bdos_error_funnel`, `status_render`,
   And `State owned (read/write):` lists `status_buffer` (write-only outside this module per AR12), `status_dirty` (write-only outside this module),
   And `Register conventions (across public entry points):` summarises each entry's contract (or refers to the per-routine block below),
   And `Dependencies:` lists `inc/equates.inc` (`STATUS_LINE_WIDTH`), `inc/state.inc` (`status_buffer`, `status_dirty`), `inc/bdos.inc` (`BDOS_CALL`, `BDOS_EXIT`), `inc/bios.inc` (`BDOS_ENTRY` via the macro chain).

2. **AC2 — `status_set_message` matches the MC5 contract verbatim.**
   Given the public entry `status_set_message`,
   When I inspect its routine contract block (immediately above the label),
   Then it specifies exactly:
     - `In:      HL = pointer to null-terminated message string`
     - `         A  = optional error code (zero for non-error; reserved for routing — currently ignored)`
     - `Out:     (none — side effect: status_buffer populated, status_dirty set nonzero)`
     - `Trashes: A, BC, DE, HL, F`
     - `Calls:   (none)`,
   And the implementation copies up to `STATUS_LINE_WIDTH` (80) bytes from `(HL)` into `status_buffer`, stopping at the first `0x00`,
   And on a short message, the remainder of `status_buffer` is space-padded (`0x20`) to the full `STATUS_LINE_WIDTH`,
   And on a message ≥ `STATUS_LINE_WIDTH` bytes (no `0x00` within the first 80), exactly the first 80 bytes are copied (truncation, no padding),
   And `status_dirty` is set to a nonzero value (project convention: `1`) on every call.

3. **AC3 — Message-string table ships with the AR16 enumeration and conforms to AR16 + AR24.**
   Given the message-string section near end-of-module,
   When I inspect it,
   Then it defines at minimum: `msg_buffer_modified`, `msg_file_too_large`, `msg_pattern_not_found`, `msg_search_wrapped`, `msg_undo_too_large`, `msg_nothing_to_undo`, `msg_no_write` (the seven enumerated by epics line 444),
   And it additionally defines `msg_bdos_error` (the safety-net message used by `bdos_error_funnel`),
   And every message string conforms to AR16: all-lowercase ASCII, no trailing period, under 30 characters of payload (count excluding the terminating `0x00`),
   And every string is null-terminated with a single `0x00` (AR24 default for inline strings — the length-prefix convention is reserved for `search_pattern` and `ex_buffer` only),
   And the section is fenced by a `;; --- Status-line message strings (AR16 conventions) ---` divider (AR24 `;;` for section dividers).

4. **AC4 — Headless smoke test under iz-cpm exercises `status_set_message` end-to-end.**
   Given a one-off smoke test program at `test/smoke/statusln_smoke.asm` (mirrors the Story 1.4 smoke pattern under `test/smoke/`; **not** part of the Story 1.6 harness yet),
   When I assemble it (sjasmplus 1.23.0) and run it under iz-cpm,
   Then the program pre-writes a "never ran" sentinel byte `0xAA` to `0xCFFE` at entry (mirrors Story 1.4 smoke),
   And the program loads `HL` with a known sample message (e.g. `"hello status line"`, null-terminated), zeroes `A`, and `CALL status_set_message`,
   And after the call the program inspects:
     - `status_dirty` is nonzero,
     - `status_buffer + 0` equals the first byte of the sample message (`'h'`, `0x68`),
     - `status_buffer + (sample_len)` equals `0x20` (space pad — proves the pad loop ran),
     - `status_buffer + STATUS_LINE_WIDTH - 1` equals `0x20` (last byte is part of the pad — proves the buffer is fully populated),
   And on all checks passing it writes `0x01` to `0xCFFE` and exits via `BDOS_EXIT`,
   And on any check failing it writes a distinct fail-code (e.g. `0xE1` for `status_dirty == 0`, `0xE2` for first-byte mismatch, `0xE3` for short-pad miss, `0xE4` for tail-pad miss) to `0xCFFE` and exits,
   And iz-cpm exits within 5 seconds (no hang, no crash),
   And `--call-trace` shows `BDOS function 0` (warm-boot exit) and **no** `BDOS function 15+` calls — proving `bdos_error_funnel` was not entered (smoke does not trigger any BDOS file-I/O),
   And the smoke `.com` is gitignored (`*.com` already covered by Story 1.1's `.gitignore`); the smoke `.asm` may be committed as a runnable reference.

5. **AC5 — `src/vibe.asm` INCLUDEs `statusln.asm` at its AR25 position; `vibe.com` builds clean and reproducibly.**
   Given the AR25 final include order,
   When I inspect `src/vibe.asm`,
   Then `INCLUDE "statusln.asm"` is placed **after** the `RET` at `0x0100` and **before** the `INCLUDE "../inc/state.inc"` line,
   And `vibe.asm` provides a `input_loop` stub label (NEW for this story) that warm-boots back to CCP via `BDOS_CALL BDOS_EXIT` — this is the abort-target referenced by `bdos_error_funnel`, and is documented as a Story-1.5 stub that Story 1.8 (input layer) replaces with the real input-loop top-of-frame,
   And `make clean && make` succeeds with no errors and no warnings,
   And `make clean && make` a **second** time produces the **same** SHA-256 of `vibe.com` (NFR18 reproducibility — the actual SHA value is **not** the Story 1.1 baseline because this story emits real code; record the new baseline in the story's Dev Agent Record for stories 1.6+ to reference until the next emit-changing story),
   And `build/vibe.lst` symbol table contains `status_set_message`, `bdos_error_funnel`, `status_render`, `input_loop`, plus every `msg_*` label from AC3.

6. **AC6 — AR12 cross-check: `statusln.asm` is the only writer to `status_buffer` and `status_dirty`.**
   Given the source tree post-implementation,
   When I run `grep -nE '\\(status_buffer|\\(status_dirty' src/ inc/ test/`,
   Then `LD (status_buffer), …` and `LD (status_dirty), …` (and any indirect `LD (DE), A` / `LD (HL), A` whose target proveably resolves to `status_buffer` / `status_dirty`) appear **only** inside `src/statusln.asm`,
   And no other `.asm` / `.inc` file in `src/` or `inc/` writes either symbol — establishes AR12 structurally for the rest of the project,
   And the smoke test (`test/smoke/statusln_smoke.asm`) may **read** `status_buffer` / `status_dirty` but does **not write** them directly — its only path to `status_dirty` is via `status_set_message`.

7. **AC7 — `bdos_error_funnel` body resolves Story 1.4's forward reference and routes through `status_set_message`.**
   Given the public entry `bdos_error_funnel`,
   When I inspect its body,
   Then it loads `HL` with `msg_bdos_error`, zeroes `A`, and `CALL status_set_message`,
   And after the call it `JP input_loop` (the Story-1.5 stub abort target — Story 1.8 lands the real input-loop label),
   And the body has a routine contract block documenting the entry (`from BDOS_CALL macro's JP M after a sign-bit BDOS rc`), the `In:` (`A = 0xFF`-class rc, `C = preserved BDOS fn — see assumption note`), the `Out:` (`does not return; control transfers to input_loop`), and the C-preservation assumption (iz-cpm verified; real CP/M to confirm in Story 1.12 / W1),
   And per-fn message dispatch is **explicitly deferred** to Story 2.x (`fileio.asm`) which sets context-rich messages **before** its BDOS calls fail; the Story 1.5 funnel uses a single generic `msg_bdos_error` ("bdos error") as the safety-net default (the architecture's "selects message by saved fn-number" clause becomes meaningful when fileio adds the per-fn refinement; for Story 1.5, the safety net is enough to satisfy NFR5 / NFR8).

8. **AC8 — `status_render` ships as a no-op stub that clears `status_dirty`.**
   Given `status_render`,
   When I inspect it,
   Then it has a routine contract block documenting that Story 1.11 (render pipeline) replaces this body with the real VT52 status-row diff'd emit (mirrors the main render diff path, per architecture lines 1495-1499),
   And the Story 1.5 body is a no-op: `XOR A` / `LD (status_dirty), A` / `RET`,
   And no VT52 emission, no BIOS_CONOUT call, no shadow_buffer touch — purely a flag-clear stub.

9. **AC9 — Casing / format / naming audit (AR22, AR23, AR24).**
   Given `src/statusln.asm` post-implementation,
   When I run audits:
     - `grep -nE '^[A-Z_][A-Z0-9_]*[^:]' src/statusln.asm` — every match is a section divider or an `EQU` keyword (no uppercase labels at column 0; AR22 says public symbols are `module_action` lowercase),
     - `grep -nP '^\\t' src/statusln.asm` — no tabs (AR24 — 4-space indent only),
     - `grep -nE '\\..*$' src/statusln.asm` — internal labels (`.copy_loop`, `.pad_loop`, etc.) use the dotted-local convention (AR22),
   And the AR23 header block is present and complete per AC1.

## Tasks / Subtasks

- [x] **Task 1 — Create `src/statusln.asm` skeleton with AR23 header + section fences** (AC: 1, 9)
  - [x] Module header matches the AR23 template used in Stories 1.2-1.4 (`; Module: …`, `; Purpose: …`, `; Public: …`, `; State owned: …`, `; Register conventions: …`, `; Dependencies: …`, separated by the `; ====` rule). Reference any existing `.asm` / `.inc` for tone.
  - [x] Three section fences in this order, each a `;; ============================================================` rule with a `;; --- <name> ---` short divider above the labels:
    1. `Public entry points` — contains `status_set_message`, `bdos_error_funnel`, `status_render` (in this order — `status_set_message` first because the funnel and stub reference it).
    2. `Internal helpers` — empty for Story 1.5 (the routines above are flat enough not to need helpers; reserve the section for future growth).
    3. `Status-line message strings` — contains the eight `msg_*` labels enumerated in AC3, all `DEFB "…", 0`.
  - [x] Use 4-space indentation (AR24); UPPERCASE mnemonics and registers; `;` line / `;;` section comments; no trailing periods on inline comments. Match the existing style of the `.inc` files written in Stories 1.2-1.4.
  - [x] **Do not** define any runtime variable in `src/statusln.asm` — `status_buffer` and `status_dirty` are owned by `inc/state.inc` (already declared in Story 1.3, `state.inc:54, 79`). `statusln.asm` only **uses** the addresses; it does **not** allocate them.
  - [x] **Do not** add an `INCLUDE "../inc/*.inc"` line inside `statusln.asm`. The headers are already INCLUDEd by `vibe.asm` before `statusln.asm` is INCLUDEd; AR25 makes `statusln.asm` post-headers in the include graph. The smoke test (Task 5) is the only place that re-INCLUDEs the headers — because its standalone build needs them, just like Story 1.4's smoke.

- [x] **Task 2 — Implement `status_set_message` per the MC5 contract** (AC: 2, 6)
  - [x] Routine contract block immediately above the label, matching AC2's `In:` / `Out:` / `Trashes:` / `Calls:` exactly. Document the truncation behavior (no `0x00` in the first 80 bytes → exactly 80 bytes copied, no padding) and the padding behavior (short message → space-pad to 80) explicitly so `fileio.asm` and `search.asm` callers can rely on it.
  - [x] Reference implementation (emit verbatim or with cosmetic variation; loop variants OK as long as the contract holds and the byte count is reasonable):
    ```asm
    ; ----------------------------------------------------------------
    ; status_set_message
    ; Single status-message funnel (MC5). Copy a null-terminated
    ; message into status_buffer, padding with spaces to the full
    ; STATUS_LINE_WIDTH, and set status_dirty so the next render pass
    ; emits the row.
    ;
    ; In:      HL = pointer to null-terminated message string
    ;          A  = optional error code (zero for non-error;
    ;               reserved for future routing — currently ignored)
    ; Out:     (none — side effect: status_buffer populated,
    ;          status_dirty set nonzero)
    ; Trashes: A, BC, DE, HL, F
    ; Calls:   (none)
    ;
    ; Behaviour:
    ;   - Copies bytes from (HL) into status_buffer until either the
    ;     null terminator is hit OR STATUS_LINE_WIDTH bytes have been
    ;     copied (truncation; no overflow into status_buffer + 80).
    ;   - On null hit, pads the remainder with 0x20 (ASCII space).
    ;   - On 80-byte truncation, no padding (buffer is already full).
    ;   - Sets status_dirty to 1 unconditionally.
    ; ----------------------------------------------------------------
    status_set_message:
        LD      DE, status_buffer
        LD      B, STATUS_LINE_WIDTH    ; max bytes left to copy
    .copy_loop:
        LD      A, (HL)
        OR      A                       ; null terminator?
        JR      Z, .pad_loop
        LD      (DE), A
        INC     HL
        INC     DE
        DJNZ    .copy_loop
        JR      .set_dirty              ; reached width; no pad needed

    .pad_loop:
        LD      A, ' '                  ; AR24: prefer literal char
        LD      (DE), A
        INC     DE
        DJNZ    .pad_loop

    .set_dirty:
        LD      A, 1
        LD      (status_dirty), A
        RET
    ```
  - [x] **Trace check.** With `STATUS_LINE_WIDTH = 80` and a 17-byte message `"hello status line"`:
    - Iter 1..17: copy 17 bytes; `B = 80 - 17 = 63` after iter 17; `HL` now points at the `0x00`.
    - Iter 18: `LD A, (HL)` reads `0x00`; `OR A` sets Z; `JR Z, .pad_loop`. `B = 63`, `DE` → `status_buffer + 17`.
    - Pad 63 spaces (DJNZ down from 63 to 0). `DE` ends at `status_buffer + 80`.
    - `.set_dirty`: store `1` at `status_dirty`, RET.
    - Final: `status_buffer[0..16]` = "hello status line", `status_buffer[17..79]` = 63 × `0x20`. `status_dirty = 1`.
  - [x] **Boundary trace.** With an 80-byte message containing **no** null in the first 80:
    - Iters 1..80: copy 80 bytes; after iter 80, `B = 0`, DJNZ falls through, `JR .set_dirty`. No pad.
    - Final: 80 bytes copied verbatim, no padding, `status_dirty = 1`.
  - [x] **Boundary trace.** With a 79-byte message + null at position 79:
    - Iters 1..79: copy 79 bytes; `B = 1` after iter 79.
    - Iter 80: `LD A, (HL)` reads `0x00`; `JR Z, .pad_loop`. `B = 1`, `DE` → `status_buffer + 79`.
    - Pad: store one `0x20` at offset 79, `B = 0`, fall through to `.set_dirty`.
    - Final: 79 message bytes + 1 space = 80 bytes total. `status_dirty = 1`.
  - [x] **Trashes contract.** The reference uses A, BC (B specifically), DE, HL, F. C is unused — could relax to `Trashes: A, B, DE, HL, F`, but using the wider `BC` form gives implementation flexibility (e.g. switching to `LDIR` later) without re-documenting. Match the wider form unless the dev agent has a strong reason.
  - [x] **AR12 enforcement** (AC6): the only `LD (status_buffer), …` / `LD (status_dirty), …` writes in the entire source tree are inside this routine and `status_render` (status_dirty clear). Verify by `grep -nE '\\(status_(buffer|dirty)\\),' src/ inc/`.

- [x] **Task 3 — Implement `bdos_error_funnel` body (resolves Story 1.4's forward reference)** (AC: 7)
  - [x] Routine contract block per AC7. Explicitly call out that this is the body Story 1.4's `BDOS_CALL` macro JPs to on a sign-bit BDOS rc (NFR8 enforcement endpoint).
  - [x] Reference implementation:
    ```asm
    ; ----------------------------------------------------------------
    ; bdos_error_funnel
    ; Entry from BDOS_CALL macro's `JP M, bdos_error_funnel` after a
    ; sign-bit BDOS rc (typically 0xFF from FCB ops). This is the
    ; abort path Story 1.4 forward-referenced; Story 2.x's fileio
    ; layer is the first production caller via the macro.
    ;
    ; In:      A = sign-bit BDOS rc (caller-side meaning: the BDOS
    ;              function failed)
    ;          C = preserved BDOS fn-number (assumption: iz-cpm and
    ;              typical CP/M BIOSes preserve C through BDOS;
    ;              real-MicroBeast confirmation lands in Story 1.12
    ;              W1). For Story 1.5 we do not actually inspect C
    ;              — per-fn dispatch is deferred (see Note below).
    ; Out:     (does not return — control transfers to input_loop)
    ; Trashes: A, BC, DE, HL, F (matches status_set_message)
    ; Calls:   status_set_message
    ;
    ; Note: per-fn message dispatch is deferred to fileio.asm
    ; (Story 2.x), which will set a context-rich message via
    ; status_set_message BEFORE its BDOS call. When the BDOS call
    ; then fails into this funnel, the prior message remains the
    ; visible status — and the funnel's own write of msg_bdos_error
    ; gets superseded by fileio's pre-call message at most paths.
    ; The funnel writes msg_bdos_error as a safety net for unexpected
    ; entries (fileio bugs, future BDOS users without context-aware
    ; pre-call messages) so the user never sees a blank-but-aborted
    ; editor (NFR5).
    ; ----------------------------------------------------------------
    bdos_error_funnel:
        LD      HL, msg_bdos_error
        XOR     A                       ; non-error-code arg (reserved)
        CALL    status_set_message
        JP      input_loop              ; abort current operation:
                                        ; Story 1.5 stub warm-boots;
                                        ; Story 1.8 lands the real loop
    ```
  - [x] **Forward reference: `input_loop`.** The label is **not** defined in `src/statusln.asm`. It is defined in `src/vibe.asm` (Task 4) as a Story-1.5 stub. Story 1.8 replaces the stub body with the real input-loop top-of-frame.
  - [x] **Do not** introduce a per-fn message lookup in this story. AC7's deferral is explicit. The architecture's "selects message by saved fn-number" clause is satisfied by the planned Story-2.x integration where `fileio.asm` sets the per-context message before each BDOS call — at which point the funnel's job is just "make sure something sane is on the status row even if the caller forgot".

- [x] **Task 4 — Update `src/vibe.asm`: INCLUDE statusln.asm + add `input_loop` stub** (AC: 5, 7)
  - [x] Current pre-INCLUDE block (post-Story 1.4) at lines 28-32 is unchanged.
  - [x] After the `RET` at `0x0100` (currently line 36-39) and **before** the post-RET `INCLUDE "../inc/state.inc"` (currently line 50), add the following block:
    ```asm
    ;; --- Status-line module (MC5; statusln.asm — Story 1.5) ---
    ; statusln.asm INCLUDEs here so its emitted code lands after the
    ; RET stub at 0x0100 and before state.inc anchors the static map
    ; past code. Per AR25 module include order: statusln is "early —
    ; depended on by everything" (architecture line 939).
        INCLUDE "statusln.asm"

    ;; --- Input-loop abort target (Story 1.5 stub; Story 1.8 owns) ---
    ; bdos_error_funnel JPs here after writing its status message.
    ; Story 1.5: stub that warm-boots back to CCP via BDOS_EXIT — a
    ; clean exit when the editor cannot continue (NFR5: no crash).
    ; Story 1.8 replaces this body with the real input-loop top of
    ; frame (read a key, dispatch, render, repeat) so the editor
    ; recovers from a BDOS error rather than exiting.
    input_loop:
        BDOS_CALL BDOS_EXIT
        RET                             ; defensive — BDOS_EXIT never
                                        ; returns on a real CP/M host
    ```
  - [x] Update the AR23 header `Dependencies:` line at `src/vibe.asm:20-21` to include `src/statusln.asm` between the inc/* headers — this story extends the dependency graph beyond inc/* into actual code modules for the first time. Suggested wording: `inc/equates.inc, inc/bios.inc, inc/bdos.inc, inc/vt52.inc, inc/modes.inc, inc/state.inc; src/statusln.asm (Story 1.5)`.
  - [x] Update the file's top-level Purpose comment (`src/vibe.asm:3-8`) to drop the "currently a stub" framing now that the file actually emits code — replace with a one-line note that the include block grows over Stories 1.5+ as modules land. Keep it terse.
  - [x] **Do not** add a `CALL init` or `CALL input_loop` from the `RET`-stub at `0x0100`. Story 1.12 owns init/teardown; the `RET` stub stays. The new `input_loop` label is reachable only via the funnel's `JP input_loop` — it is not the program's entry point in Story 1.5.
  - [x] **AR15 cross-check.** The new `input_loop` body uses `BDOS_CALL BDOS_EXIT` (the macro), not raw `CALL BDOS_ENTRY`. Story 1.4's macro covers BDOS_EXIT cleanly: `LD C, 0` / `CALL BDOS_ENTRY` / `OR A` / `JP M, bdos_error_funnel`. The `JP M` is unreachable for fn 0 (BDOS_EXIT does not return), but harmless if it ever fires (would re-enter the funnel → status set → JP input_loop → tight loop until iz-cpm 5-second budget kills us; on real CP/M the warm boot fires before any of this).

- [x] **Task 5 — Headless smoke test under iz-cpm** (AC: 4)
  - [x] Create `test/smoke/statusln_smoke.asm` (sibling of `bdos_call_smoke.asm` from Story 1.4). Same conventions: standalone build that re-INCLUDEs the production headers and `src/statusln.asm`. The Story 1.6 harness will normalise smoke-test layout when it lands.
  - [x] Reference structure (cosmetic variation OK; the AC4 checks are the contract):
    ```asm
    ; ============================================================
    ; Module: test/smoke/statusln_smoke.asm
    ; Purpose: One-off smoke test for statusln.asm (Story 1.5 AC4).
    ;          Calls status_set_message with a 17-char sample,
    ;          inspects status_buffer + status_dirty for the
    ;          documented post-call invariants, writes a per-result
    ;          sentinel byte at 0xCFFE (TH1 pattern), exits via
    ;          BDOS_EXIT.
    ;
    ;          NOT part of the Story 1.6 harness. test/cases/ is
    ;          owned by Story 1.6 and may relocate or replace this
    ;          artifact.
    ; ============================================================
        INCLUDE "../../inc/equates.inc"
        INCLUDE "../../inc/bios.inc"
        INCLUDE "../../inc/bdos.inc"

        ORG 0x0100

        ;; Pre-write a "never ran" sentinel so post-run inspection
        ;; can distinguish "smoke entered" from "memory was already
        ;; the pass-code from a prior run".
        LD      A, 0xAA
        LD      (0xCFFE), A

        ;; Exercise status_set_message.
        LD      HL, sample_msg
        XOR     A                       ; non-error-code arg
        CALL    status_set_message

        ;; Check 1: status_dirty must be nonzero.
        LD      A, (status_dirty)
        OR      A
        JR      Z, .fail_dirty

        ;; Check 2: status_buffer[0] must be 'h' (first byte of
        ;; "hello status line").
        LD      A, (status_buffer)
        CP      'h'
        JR      NZ, .fail_first

        ;; Check 3: status_buffer[17] must be 0x20 (first byte of
        ;; the pad — proves the pad loop ran).
        LD      A, (status_buffer + 17)
        CP      ' '
        JR      NZ, .fail_pad_short

        ;; Check 4: status_buffer[STATUS_LINE_WIDTH - 1] must be
        ;; 0x20 (last byte — proves the pad reached the end).
        LD      A, (status_buffer + STATUS_LINE_WIDTH - 1)
        CP      ' '
        JR      NZ, .fail_pad_tail

        LD      A, 0x01                 ; pass
        LD      (0xCFFE), A
        JR      .exit

    .fail_dirty:
        LD      A, 0xE1
        LD      (0xCFFE), A
        JR      .exit
    .fail_first:
        LD      A, 0xE2
        LD      (0xCFFE), A
        JR      .exit
    .fail_pad_short:
        LD      A, 0xE3
        LD      (0xCFFE), A
        JR      .exit
    .fail_pad_tail:
        LD      A, 0xE4
        LD      (0xCFFE), A

    .exit:
        LD      C, BDOS_EXIT
        CALL    BDOS_ENTRY              ; warm-boot to CCP / iz-cpm
        RET                             ; defensive

    sample_msg:
        DEFB    "hello status line", 0

        ;; Pull in statusln.asm's code and message strings so the
        ;; smoke is a standalone .com.
        INCLUDE "../../src/statusln.asm"

        ;; Local stub for the bdos_error_funnel's JP input_loop —
        ;; not reached in this smoke (no BDOS file-I/O here), but
        ;; the build needs the symbol to resolve the reference
        ;; inside statusln.asm.
    input_loop:
        LD      C, BDOS_EXIT
        CALL    BDOS_ENTRY
        RET

        ;; state.inc anchors past all emitted code — same pattern
        ;; as production vibe.asm.
        INCLUDE "../../inc/state.inc"
    ```
  - [x] Assemble: `sjasmplus --nologo --msg=err --raw=test/smoke/statusln_smoke.com test/smoke/statusln_smoke.asm` (mirror Story 1.4's smoke flag set).
  - [x] Run: `cd test/smoke && iz-cpm --call-trace statusln_smoke.com`. Expected trace: only `BDOS function 0` (the BDOS_EXIT at the end), no `function 15+` calls (proves the funnel was not entered, which would itself indicate a bug — funnel reaches `BDOS_CALL BDOS_EXIT` in `input_loop`, and that's a separate path). Exit within 5 seconds.
  - [x] **Verification methods.** Two acceptable verifications, mirror Story 1.4:
    - **Trace + sentinel together** (preferred): `--call-trace` confirms the BDOS_EXIT and the absence of any other BDOS calls; the sentinel byte at `0xCFFE` confirms which path through the smoke was taken (`0x01` pass, `0xE1`-`0xE4` per-check fail, `0xAA` "never reached the path that writes the sentinel"). The sentinel observation requires a memory-dump probe; for Story 1.5 the trace alone is acceptable evidence given the smoke's branching is local and inspectable.
    - **Trace alone** (acceptable per Story 1.4 precedent): if `--call-trace` shows clean exit and no unexpected BDOS calls, AC4 is satisfied.
  - [x] **If iz-cpm is not available locally**: defer AC4 verification to Story 1.6 with a deferred-work entry under "code review of story-1.5 (date)" in `_bmad-output/implementation-artifacts/deferred-work.md`. Per Story 1.4 dev notes, iz-cpm is at `~/.local/bin/iz-cpm` and was used successfully for Story 1.4's smoke, so this fallback should not trigger.

- [x] **Task 6 — Build, NFR18 reproducibility, AR15/AR12 cross-checks** (AC: 5, 6, 9)
  - [x] `make clean && make` — expect zero stdout (sjasmplus `--msg=err` quiet on success). Any warning/error halts the task.
  - [x] `sha256sum vibe.com` — record the SHA in the Dev Agent Record. **Note**: this story emits real code (statusln + input_loop stub + message strings), so the SHA will **not** match the Story 1.1 baseline `4fb733be…14de523a`. The Story 1.5 SHA establishes a new baseline that subsequent code-light stories (none planned in Epic 1 Phase A — Stories 1.6 is the test harness, 1.7 is gap buffer which emits) must preserve until the next emit-changing story. There is no fixed SHA target for this story; the contract is reproducibility (same SHA on a second `make clean && make`).
  - [x] `make clean && make` a second time — same SHA on the second build (NFR18). If the SHA differs, the cause is non-deterministic emit (timestamp, build-time-dependent expression). Investigate before declaring complete.
  - [x] `build/vibe.lst` — verify the symbol table contains `status_set_message`, `bdos_error_funnel`, `status_render`, `input_loop`, plus every `msg_*` label (eight: `msg_buffer_modified`, `msg_file_too_large`, `msg_pattern_not_found`, `msg_search_wrapped`, `msg_undo_too_large`, `msg_nothing_to_undo`, `msg_no_write`, `msg_bdos_error`). All resolve at addresses ≥ `0x0101` (post the RET stub).
  - [x] AR12 cross-check (AC6): `grep -nE '\\(status_(buffer|dirty)\\)' src/ inc/` returns matches **only** in `src/statusln.asm` (write paths in `status_set_message` and `status_render`). The smoke test and any future test under `test/` may **read** the symbols (`LD A, (status_dirty)`, `LD A, (status_buffer)`) — read-only access does not violate AR12. Document the grep output in the Dev Agent Record.
  - [x] AR15 cross-check: `grep -rnE 'CALL +(0x0005|BDOS_ENTRY)' src/ inc/` matches only:
    - `inc/bdos.inc:74` — inside the `BDOS_CALL` macro body (Story 1.4 baseline).
    - `src/vibe.asm` — inside the `BDOS_CALL BDOS_EXIT` expansion in `input_loop` (Story 1.5 expansion site).
    No other matches.
  - [x] `state.inc:121` ASSERT (`yank_end <= 0xD800`) still holds after the new code emit. Story 1.5 adds maybe 150-250 bytes of code; static map shifts by the same amount; `yank_end` shifts by the same amount. Headroom is generous (`0xD800 - yank_end_after_1.3` ≈ tens of KB). Verify in `build/vibe.lst`.
  - [x] `state.inc:40` ASSERT (`static_data_base >= 0x0101`) still holds. statusln's code lands between `0x0101` and `static_data_base`; static_data_base is now the first address past statusln's code. Lower bound preserved.

- [x] **Task 7 — Naming, format, convention compliance** (AC: 9)
  - [x] AR22 — public symbols are `module_action` lowercase: `status_set_message`, `status_render`, `bdos_error_funnel` ✓; internal labels are `.copy_loop`, `.pad_loop`, `.set_dirty`, `.fail_*`, `.exit` (dotted-locals); message strings are `msg_*` lowercase per AR16's "all lowercase" extension. `grep -nE '^[A-Z_][A-Z0-9_]*[^:]:?\\s' src/statusln.asm` should match no public labels (no UPPER_SNAKE labels in statusln.asm — that namespace is reserved for equates/macros).
  - [x] AR23 header block on `src/statusln.asm` per the Story 1.2-1.4 template; `Public:` enumerates the three landed routines; `State owned:` cites `status_buffer`, `status_dirty` (both declared in state.inc, written only here per AR12).
  - [x] AR24 — UPPERCASE mnemonics + registers; 4-space indentation, never tabs (`grep -nP '^\\t' src/statusln.asm` matches nothing); `;` line / `;;` section comments; no trailing periods on inline comments. Routine contract blocks use the same multiline `;` + 4-space-indent prose style established in `inc/bdos.inc`'s `BDOS_CALL` doc block.
  - [x] AR16 audit — every `msg_*` string is all-lowercase, has no trailing period, has under 30 character payload (count excluding the terminating `0x00`). Quick check:
    - `"buffer modified"` (15) ✓
    - `"file too large"` (14) ✓
    - `"pattern not found"` (17) ✓
    - `"search wrapped"` (14) ✓
    - `"undo not possible - too large"` (29 — right at the limit; matches architecture's exact wording at line 1028) ✓
    - `"nothing to undo"` (15) ✓
    - `"no write since last change"` (26) ✓
    - `"bdos error"` (10) ✓ (Story 1.5 own addition for the safety net).

## Dev Notes

### Why this story exists

Story 1.5 closes implementation-sequence step 4 (architecture line 1566-1567: "**`statusln.asm`** — even pre-render-pipeline, set up the message funnel so later modules can use it"). Together with Story 1.4 (BDOS_CALL macro), this completes the "error / status surface" the editor exposes to itself. Every subsequent module (gapbuf, input, render, motions, edits, fileio, search, undo) has a working error/info entry point from the moment it lands; no later story has to bootstrap status reporting before doing its real work.

The single largest reason this story matters: **MC5 + AR12 — every status path goes through `status_set_message`, and `status_buffer` has exactly one writer**. A real Z80 codebase fails this by accident — one module decides to peek-poke `status_buffer` directly because "it's just one line of text", and now the dirty-flag is out of sync, the truncation behaviour is inconsistent, and rendering races with the writer. Locking the writer to `statusln.asm` and proving it via a tree-wide grep (AC6) makes the funnel structural rather than convention. NFR8 (BDOS rc check completeness) lands its closing piece here too: Story 1.4's macro routes errors to `bdos_error_funnel`; Story 1.5 lands the funnel body so the routing actually does something.

This story also introduces the project's first **forward-referencing pattern across stories** (Story 1.4 forward-referenced `bdos_error_funnel` from a macro body; Story 1.5 forward-references `input_loop` from a routine body — Story 1.8 lands the real `input_loop`). The pattern is: a story that needs an abort target which doesn't exist yet provides a stub at the highest level (vibe.asm) that warm-boots back to CCP, so the build always assembles and the editor always exits cleanly even if no caller has implemented the proper recovery yet.

### Critical guardrails for the dev agent

**🛑 `status_buffer` and `status_dirty` are owned exclusively by `status_set_message` (write) and `status_render` (write to clear `status_dirty`).** AR12 makes this a tree-wide rule. The grep in AC6 / Task 6 enforces it. If you need to set the status from a future module, `CALL status_set_message` — never `LD (status_buffer), …`. Direct writes are a code-review red flag and a build-time grep failure.

**🛑 The MC5 contract is `In: HL = ptr, A = optional code; Out: side effect`.** Do not change the calling convention to push args on the stack, pass via DE, or return a status code. Every later module is going to be written assuming this contract; changing it later is a tree-wide refactor.

**🛑 Truncate at exactly `STATUS_LINE_WIDTH` (80 bytes), pad with `0x20` (ASCII space).** Do not zero-pad (`0x00`) — the status row is rendered as character cells; a `0x00` would render as a glyph (or nothing, or a control character, depending on the VT52 implementation) and produce visual noise. ASCII space is always a safe pad. Also do not pad with the `'.'` or `'-'` character; padding is "fill with empty so the row renders cleanly", not "indicate continuation".

**🛑 `bdos_error_funnel` MUST `JP input_loop`, not `RET` and not warm-boot directly.** Story 1.5 stubs `input_loop` in `vibe.asm` to warm-boot, but the funnel itself must not bypass the indirection. Story 1.8 replaces `input_loop`'s body with the real input-loop top-of-frame; the funnel keeps its `JP input_loop` unchanged. This is the same forward-reference pattern Story 1.4 established for `bdos_error_funnel` itself.

**🛑 Do NOT introduce per-fn message dispatch in `bdos_error_funnel` for Story 1.5.** AC7 explicitly defers it. The architecture's "selects message by saved fn-number" clause becomes implementable when fileio.asm (Story 2.x) sets context-rich messages BEFORE its BDOS calls — at which point the funnel's job is just safety net. Story 1.5's funnel writes `msg_bdos_error` and that's all. If the dev agent feels strongly about implementing per-fn, raise it as a deferred-work item; do not exceed scope here.

**🛑 `status_render` is a **stub** that clears `status_dirty`. Period.** No VT52 emission. No BIOS_CONOUT. No shadow_buffer touch. Story 1.11 owns the real render path. Stub = `XOR A : LD (status_dirty), A : RET`. Three instructions. Anything more is scope creep.

**🛑 `statusln.asm` does NOT INCLUDE any `inc/*.inc` header.** The headers are INCLUDEd by `vibe.asm` BEFORE `statusln.asm` is INCLUDEd; sjasmplus's symbol table sees them. The smoke test re-INCLUDEs the headers because it builds standalone — that's a smoke-only pattern, not a `statusln.asm` pattern. Adding `INCLUDE "../inc/equates.inc"` to `statusln.asm` would silently work (sjasmplus tolerates re-include for EQU since values match) but breaks the AR25 dependency-order discipline and makes the file non-portable to a future restructuring.

**🛑 The smoke test's local `input_loop` stub is necessary because the smoke INCLUDEs `statusln.asm`, which contains `JP input_loop`.** Without the stub the smoke build fails with `Label not found: input_loop`. Pattern matches Story 1.4's smoke providing its own `bdos_error_funnel` stub. Story 1.6 (harness) will normalise this when it lands a proper test framework.

**🛑 Message strings live near end-of-module, fenced by `;; --- Status-line message strings ---`.** Architecture line 1019-1037 specifies "near end-of-code (so size audit can spot string-table growth)". Place after `status_render`'s body, before any (currently empty) internal-helpers section. Do not interleave message strings with code — keep them as a single block.

**🛑 `last_bdos_fn` is NOT introduced by this story.** Some implementations save the BDOS fn number to a state variable for the funnel to inspect; Story 1.5 deliberately does not. The funnel reads `C` (assumed preserved by BDOS) when it needs fn — and for Story 1.5 it doesn't even do that. If a future story (Story 1.12 hardware bring-up, or Story 2.x fileio) discovers that `C` is not preserved by real CP/M BIOSes, that story can introduce `last_bdos_fn` to state.inc and update the BDOS_CALL macro to save fn before CALL — but it is **not** Story 1.5's job to pre-empt that.

**🛑 `vibe.com` SHA-256 IS NOT preserved against the Story 1.1 baseline.** Stories 1.2, 1.3, 1.4 preserved `4fb733be…14de523a` because they emitted no bytes. Story 1.5 emits real code. The new SHA is recorded in this story's Dev Agent Record and becomes the baseline for any subsequent emit-light story. NFR18 reproducibility (same SHA on a second build) is the only constraint here — verify by `make clean && make` twice.

**🛑 The new `input_loop` stub in `vibe.asm` warm-boots via `BDOS_CALL BDOS_EXIT`, not raw `CALL BDOS_ENTRY`.** AR15 applies even to bootstrap stubs. The macro's `JP M` path at fn 0 is unreachable in practice (BDOS_EXIT does not return), so the stub is two instructions of effective code (the rest of the macro is dead code in this expansion) plus the defensive `RET` after the macro. Total stub size: ~10 bytes.

### Architecture compliance — what AR* / SR* / NFR* / MC* rules this story locks in

| Rule | Story 1.5 obligation |
|---|---|
| AR12 | Single status-message funnel: only `statusln.asm` writes `status_buffer` / `status_dirty`. AC6 grep proves it tree-wide. |
| AR15 | `BDOS_CALL` macro is the only BDOS gateway. The new `input_loop` stub in `vibe.asm` uses `BDOS_CALL BDOS_EXIT` — first production-side macro expansion in the project (Story 1.4 had no expansion sites). |
| AR16 | Status-message string-table convention: all-lowercase, no trailing period, target under 30 chars; eight messages enumerated and audited. |
| AR22 | Public symbols `module_action` lowercase (`status_set_message`, `status_render`, `bdos_error_funnel`, `input_loop`); internal labels dotted-locals (`.copy_loop`, `.pad_loop`, `.fail_*`); message labels `msg_*` lowercase; equates remain UPPER_SNAKE (untouched). |
| AR23 | `src/statusln.asm` ships with the standard Module/Purpose/Public/State/Register-conventions/Dependencies header. |
| AR24 | UPPERCASE mnemonics + registers; 4-space indent never tabs; `;` line / `;;` section dividers; no trailing periods. |
| AR25 | `INCLUDE "statusln.asm"` is placed after the `RET` at `0x0100` and before the post-RET `INCLUDE "../inc/state.inc"`. statusln is "early — depended on by everything" per architecture line 939. |
| MC1 | Caller-saved everywhere by default. `status_set_message` documents `Trashes: A, BC, DE, HL, F`; callers save what they need. |
| MC2 | Named-purpose register conventions documented per public entry — every routine has its `In:` / `Out:` / `Trashes:` / `Calls:` block. |
| MC5 | `status_set_message` is the single status-message funnel. Eight messages live in the AR16-conforming table; later modules `CALL status_set_message` rather than poking `status_buffer`. |
| MC6 | `BDOS_CALL` macro routes errors here via `JP M, bdos_error_funnel`. Story 1.5 lands the funnel body that closes the loop (status set + JP input_loop). |
| NFR5 | No crashes: every BDOS error path now has a defined post-condition (status row reflects the error, `input_loop` is the abort target). The Story 1.5 stub `input_loop` warm-boots cleanly — the editor exits but does not crash; Story 1.8 upgrades to "stays running and prompts for next key". |
| NFR8 | Every BDOS rc check is enforced by the macro at the call site, and unexpected codes terminate cleanly via the funnel + status_set_message path. AC7 closes the loop Story 1.4 left open. |
| NFR16 | All status-line magic numbers are named equates: `STATUS_LINE_WIDTH` (80), `STATUS_ROW` (23 — declared in equates.inc but not used by the stub), space pad as the literal `' '` (ASCII 0x20). No bare numeric literals in `statusln.asm` outside the `0x01` dirty-flag value (project convention: 1 = dirty). |
| NFR18 | `vibe.com` builds reproducibly (same SHA twice in succession). The Story 1.1 baseline is **not** preserved here — Story 1.5 establishes a new SHA baseline as the first code-emitting story since 1.1. |
| FR49 | Status line on row 24 — partially: the buffer + dirty flag are now wired; the actual VT52 emit lands in Story 1.11. |
| FR50 | Unsupported-command no-op surfaces in status — partial: `status_set_message` is the future call site for dispatch's unbound-key handler (Story 1.9). |
| FR51 | I/O failure surfacing — partial: `bdos_error_funnel` is wired; fileio.asm (Story 2.x) supplies context. |

### Existing files — current state and what this story changes

**`src/statusln.asm`** *(NEW; does not currently exist):*
- Create from scratch per Tasks 1-3, 7. AR23 header + three section fences + three routine bodies + eight `msg_*` strings.
- Approximate code emit: `status_set_message` ~25-30 bytes, `bdos_error_funnel` ~10 bytes, `status_render` 5 bytes, message strings ~155 bytes (sum of payload + null terminators ≈ "buffer modified\0" 16 + "file too large\0" 15 + "pattern not found\0" 18 + "search wrapped\0" 15 + "undo not possible - too large\0" 30 + "nothing to undo\0" 16 + "no write since last change\0" 27 + "bdos error\0" 11 = 148 bytes). Total: ~190-200 bytes of emit. Final size in `build/vibe.lst`.

**`src/vibe.asm`** *(48 lines; modified in Story 1.4 to splice bios.inc / bdos.inc INCLUDEs):*
- Update top-of-file Purpose comment to drop the "currently a stub" framing.
- Update AR23 `Dependencies:` line to add `src/statusln.asm (Story 1.5)`.
- Insert `INCLUDE "statusln.asm"` after the `RET` at `0x0100` and before the post-RET `INCLUDE "../inc/state.inc"`.
- Insert `input_loop:` stub label with `BDOS_CALL BDOS_EXIT` body between the new statusln INCLUDE and the state.inc INCLUDE.
- Approximate diff: +10 lines (label + stub + comment fences).

**`inc/state.inc`** *(122 lines; declared `status_buffer` and `status_dirty` in Story 1.3):*
- **Not modified.** `status_buffer` (line 79) and `status_dirty` (line 54) are already declared. Story 1.5 only consumes them. No new state needed.

**`inc/bdos.inc`** *(80 lines; Story 1.4):*
- **Not modified.** `BDOS_CALL` macro and `BDOS_EXIT` EQU are exactly what this story needs.

**`inc/bios.inc`** *(50 lines; Story 1.4):*
- **Not modified.** No new BIOS / zero-page addresses needed.

**`inc/equates.inc`** *(65 lines; Story 1.2 + review patches):*
- **Not modified.** `STATUS_LINE_WIDTH` (line 46) is already declared.

**`inc/vt52.inc`, `inc/modes.inc`** — **Not modified.** Story 1.5 stub does not emit VT52; Story 1.11 owns that.

**`Makefile`** — **Not modified.** `$(wildcard src/*.asm) $(wildcard inc/*.inc)` already covers `src/statusln.asm` for rebuild dependency.

**`test/Makefile`** — **Not modified.** The smoke test (Task 5) is invoked manually via `sjasmplus` + `iz-cpm`, not via `make test`. Story 1.6 owns the harness.

**Files NOT touched by this story (do not edit):**

- `inc/equates.inc` / `inc/state.inc` / `inc/bios.inc` / `inc/bdos.inc` / `inc/vt52.inc` / `inc/modes.inc` — all final per Stories 1.2-1.4.
- `Makefile`, `.gitignore` — Story 1.1's baseline.
- `test/Makefile` — placeholder; Story 1.6 owns.
- `_bmad-output/implementation-artifacts/deferred-work.md` — touch only if a Story 1.5 decision is deferred.

**Files created by this story:**

- `src/statusln.asm` — the module.
- `test/smoke/statusln_smoke.asm` — one-off smoke test for AC4. Lives alongside Story 1.4's `bdos_call_smoke.asm`.

### Library / framework requirements

**sjasmplus 1.23.0 specifics relevant to this story:**

- **`DEFB "string", 0` literal-string + null-terminator** is the canonical pattern. Use double-quoted strings with the comma-separated `0` terminator on the same line. Do not use `DEFM` (some sjasmplus dialects); `DEFB "…"` is portable.
- **`INCLUDE "statusln.asm"`** is resolved relative to the file containing the INCLUDE. From `src/vibe.asm`, `"statusln.asm"` resolves to `src/statusln.asm`. From `test/smoke/statusln_smoke.asm`, `"../../src/statusln.asm"` resolves the same way.
- **Forward references** at the routine-body level (not just macro-body level) are resolved on the second pass. `JP input_loop` inside `statusln.asm` is fine as long as `input_loop` is defined somewhere in the same translation unit by the end of the file. The smoke test must define a local `input_loop` because its translation unit doesn't include `vibe.asm`'s real one.
- **`--raw=<file>`** writes a flat binary from the lowest emitted byte to the highest. With `statusln.asm` emitting code post-`RET`, the .com size grows from 1 byte to ~200 bytes. The .com is a valid CP/M executable; the `RET` at `0x0100` is still the entry point and still warm-boots back immediately on launch (until Story 1.12 lands `init`).
- **`--lst=build/vibe.lst`** produces the symbol-table listing used by AC5 / AC6 / Task 6 verification. Inspect manually; no automated check here yet (Story 1.6 territory).

### CP/M 2.2 status-line conventions (for the dev agent's mental model)

CP/M 2.2 has no concept of a "status line" — it's a VT52 / VIBE-specific construction. The convention: row 24 (0-indexed: `STATUS_ROW = SCREEN_ROWS - 1 = 23`) of an 80×24 VT52 terminal is reserved for status. `STATUS_LINE_WIDTH = SCREEN_COLS = 80` (full width). `status_buffer` is the in-RAM copy of what should be on row 24; `status_dirty` is the "needs redraw" flag that the next render pass picks up.

vi convention (which VIBE follows in spirit per PRD line 48-51): the status line shows mode, filename, dirty flag, line/column, and transient messages in a single line at the bottom. VIBE's MVP scope (Stories 1.5 + 1.11 + 1.12) stops at **transient messages** — mode display, filename, dirty marker, and line/col are deferred to Story 1.11 (`status_render` real body) or Story 2.x (when the relevant feature lands and gets its own status integration).

Architecture line 1003-1037 specifies the message-string format conventions. Architecture line 1019-1037 specifies the message-table location near end-of-module. AC3 enumerates the seven-plus-`msg_bdos_error` minimum set; later stories add more (e.g. Story 2.2 adds `"can't open <filename>"` — but that's runtime-formatted, not a static `msg_*` literal).

### Previous story intelligence (Stories 1.1, 1.2, 1.3, 1.4)

**From Story 1.1:**
- `vibe.com` Story 1.1 baseline SHA `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a` is **not** preserved by Story 1.5 (this story emits real code).
- Makefile's sjasmplus 1.23.0 pin and `--raw` flag set are inherited unchanged.
- iz-cpm at `~/.local/bin/iz-cpm` is available for the smoke test.

**From Story 1.2:**
- `STATUS_LINE_WIDTH` (line 46 of `equates.inc`) is the only screen-geometry constant Story 1.5 reads. Reading it from code via `LD B, STATUS_LINE_WIDTH` (an immediate) is the right pattern — the assembler resolves the constant at assemble time; no runtime lookup.
- Pre-emptive thoroughness on documentation pays off in code review (Story 1.2's review caught NFR16-spirit violations and a missing derivation). For Story 1.5 the equivalent: every `msg_*` string explicitly listed in AC3 with byte-count check; every routine has full `In:`/`Out:`/`Trashes:`/`Calls:` block; the truncate vs. pad behavior of `status_set_message` is explicitly specified, not implicit.

**From Story 1.3:**
- `status_buffer` (`state.inc:79`) and `status_dirty` (`state.inc:54`) are the addresses Story 1.5 writes. `state.inc` is INCLUDEd post-RET (uses `$` to anchor); statusln INCLUDEs **before** state.inc so static_data_base anchors past statusln's code.
- The "🛑 No DEFB/DEFW/DEFS in headers" firewall does NOT apply to `src/statusln.asm` — it applies only to `inc/*.inc`. statusln.asm is a code module and freely uses `DEFB` for message strings (after all routine bodies, fenced as a section).
- The lower-bound ASSERT (`static_data_base >= 0x0101`, `state.inc:40`) and upper-bound ASSERT (`yank_end <= 0xD800`, `state.inc:121`) both still hold after Story 1.5's emit. Verify in `build/vibe.lst`.

**From Story 1.4:**
- `BDOS_CALL BDOS_EXIT` is the canonical "warm-boot" expansion — used in `input_loop` stub. Story 1.4's smoke test verified the macro expansion works under iz-cpm; Story 1.5's `input_loop` is the first production expansion.
- `bdos_error_funnel` was forward-referenced inside the `BDOS_CALL` macro body in Story 1.4. Story 1.5 lands the body — first time the symbol resolves to a real address. Macro-body forward references resolve at expansion time per sjasmplus 1.23.0 semantics; the funnel must be defined before the first real expansion in `src/`. Order: `vibe.asm` INCLUDEs `statusln.asm` (defines `bdos_error_funnel`), then `vibe.asm`'s own `input_loop` body expands `BDOS_CALL BDOS_EXIT` (the first production expansion). Lexical order matters — keep the INCLUDE before the `input_loop` body.
- Story 1.4 review hardening: explicit reader contracts on tick counter (DI/EI bracket, unsigned compare), CP/M-illegal FCB names in smoke tests, "never ran" sentinel marker. For Story 1.5 the equivalent: explicit truncate-vs-pad branches in `status_set_message`, explicit per-check sentinel codes in the smoke (E1-E4), structurally-illegal-or-mandatory test conditions in AC4.
- The sjasmplus include guard pattern Story 1.4 review introduced (`DEFINE BIOS_INC_LOADED` in `bios.inc` + `IFNDEF BIOS_INC_LOADED` in `bdos.inc`) sets a project convention. Story 1.5 does not introduce a new include guard — `statusln.asm` is a code module, not a header, and the smoke test's re-INCLUDE of headers is already guarded by Story 1.4's pattern.

### Git intelligence

Four commits on `main` after Story 1.0:

- `b561c9e` — Story 1.1: Makefile pins sjasmplus 1.23.0, produces vibe.com.
- `eac5ba3` — Story 1.2: named every constant the editor needs, in three .inc headers, wired in.
- `a298547` — Story 1.3: Laid out the editor's full memory map at fixed addresses, build-time guarded.
- *(uncommitted at story-create time)* — Story 1.4: every BDOS call now goes through a macro that catches errors.

Conventions visible in the tree (preserve):
- 4-space indentation, UPPERCASE mnemonics/directives, `;` line / `;;` section comments.
- Header blocks (AR23) on every `.asm` / `.inc` file.
- `Makefile`'s `SOURCES := $(wildcard src/*.asm) $(wildcard inc/*.inc)` rebuilds when any source changes — Story 1.5's new `src/statusln.asm` is picked up automatically.
- One story per commit; short imperative subject + colon-separated context. Exceptionally, the user's last commit message style was "story 1.4: every BDOS call now goes through a macro that catches errors" — plain English, no PM gobbledegook. Match this tone.

Suggested commit message for Story 1.5 (when the dev finishes): `story 1.5: every status message now goes through one funnel; the BDOS error path lands here.` (Match the user's tone established in the 1.4 commit subject.)

### Latest tech information

- **sjasmplus 1.23.0 macro-expansion order.** The first production expansion of `BDOS_CALL` lands in `vibe.asm`'s `input_loop` body in this story. Because `INCLUDE "statusln.asm"` precedes the `input_loop` definition in `vibe.asm`, `bdos_error_funnel` (defined inside `statusln.asm`) is resolved by the time the macro expansion runs. No special handling needed.
- **`DEFB`/`DEFS` byte counts.** sjasmplus emits exactly the bytes specified; `DEFB "string", 0` emits `len(string) + 1` bytes (one per character + the explicit `0`). For `msg_undo_too_large: DEFB "undo not possible - too large", 0` that's 30 bytes (29 + 1). All `msg_*` byte counts above are AR16-compliant (under-30 payload + 1-byte terminator).
- **CP/M 2.2 BDOS preserves C** in the typical implementation (function number is read from C; BDOS uses other registers internally). iz-cpm is verified to preserve C through any BDOS call (Story 1.4 trace evidence). MicroBeast's actual CP/M 2.2 BIOS confirmation is part of Story 1.12's Watchpoint W1. For Story 1.5 the C-preservation assumption is documented in `bdos_error_funnel`'s contract block; per-fn message dispatch is deferred (AC7 explicitly), so even if C-preservation turned out to be wrong, the Story 1.5 funnel still works (it doesn't read C).
- **No web research relevant.** Story 1.5 is platform-fixed (CP/M 2.2 + sjasmplus 1.23.0 + VT52); no third-party APIs, library versions, or framework upgrades to verify.

### Testing requirements

Story 1.5 has **one mechanical headless test** (Task 5's smoke test) plus the standard build-time mechanical checks. The full iz-cpm test harness lands in Story 1.6; until then verification is:

1. `make clean && make` succeeds with no errors and no warnings.
2. `sha256sum vibe.com` reproducible across two consecutive `make clean && make` invocations (NFR18). The actual SHA is **not** the Story 1.1 baseline — record it in the Dev Agent Record as the new baseline for downstream stories until the next emit-changing story.
3. `build/vibe.lst` symbol table contains every Task 1-3 declared symbol (`status_set_message`, `bdos_error_funnel`, `status_render`, `input_loop`, eight `msg_*` labels).
4. AR12 grep audit (Task 6): `grep -nE '\\(status_(buffer|dirty)\\),' src/ inc/` matches only `src/statusln.asm`.
5. AR15 grep audit (Task 6): `grep -rnE 'CALL +(0x0005|BDOS_ENTRY)' src/ inc/` matches only `inc/bdos.inc:74` (macro body) and the `BDOS_CALL BDOS_EXIT` expansion in `src/vibe.asm`.
6. AR22 / AR24 audits: lowercase public symbols, no tabs in source.
7. AR16 audit on `msg_*` strings: lowercase, no period, under 30 chars (Task 7 enumerated check).
8. **Smoke test (Task 5):** `test/smoke/statusln_smoke.com` runs under iz-cpm without crashing or hanging; the four post-call checks (status_dirty != 0, first byte = 'h', short pad = ' ', tail pad = ' ') all pass; sentinel byte at `0xCFFE` is `0x01` on completion (or one of `0xE1`-`0xE4` on a per-check failure).

Once Story 1.6 lands the proper harness, this smoke test may be normalised into `test/cases/statusln.asm` with a sentinel-byte epilogue, or replaced by per-routine micro-tests under `test/cases/statusln_*.asm` (TH-naming convention).

### Project Structure Notes

This story creates one new file (`src/statusln.asm`) and one new file in the existing `test/smoke/` directory (`statusln_smoke.asm`). No new directories are created.

The `Complete Project Directory Structure` in architecture.md (lines 249-261, 1287-1289) anticipates `src/statusln.asm` exactly as this story populates it. `test/smoke/` was created by Story 1.4 as a transitional location; Story 1.5 reuses it. Both will be reviewed by Story 1.6 when the harness lands.

After Story 1.5 the `src/` directory contains exactly two files: `vibe.asm` (top-level) and `statusln.asm`. The `inc/` directory remains at six files (`equates.inc`, `bios.inc`, `bdos.inc`, `vt52.inc`, `modes.inc`, `state.inc`). `test/smoke/` contains two `.asm` smoke tests + their gitignored `.com` build outputs.

The user's auto-memory pinned design commitments (project_vibe.md) explicitly named the status-line message style ("`status_set_message` single funnel, AR16 lowercase / no period / <30 chars") as a finalised PRD commitment as of 2026-05-08. Story 1.5 implements that commitment.

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md] lines 423-459
- Epic 1 objective: [Source: _bmad-output/planning-artifacts/epics.md] lines 277-279
- AR12 (single status-message funnel): [Source: _bmad-output/planning-artifacts/epics.md] line 161
- AR15 (single BDOS gateway): [Source: _bmad-output/planning-artifacts/epics.md] line 164
- AR16 (status-message string-table convention): [Source: _bmad-output/planning-artifacts/epics.md] line 165
- AR22 (naming), AR23 (header), AR24 (format), AR25 (include order): [Source: _bmad-output/planning-artifacts/epics.md] lines 177-180
- MC5 (`status_set_message` funnel): [Source: _bmad-output/planning-artifacts/architecture.md] lines 535-541
- MC6 (BDOS_CALL expansion + bdos_error_funnel routing): [Source: _bmad-output/planning-artifacts/architecture.md] lines 543-548
- statusln.asm purpose / placement: [Source: _bmad-output/planning-artifacts/architecture.md] lines 249-250, 939, 1287-1289, 1439-1441
- Status-line message format conventions + table location: [Source: _bmad-output/planning-artifacts/architecture.md] lines 1003-1037
- Status row position (row 24 = STATUS_ROW = SCREEN_ROWS - 1): [Source: _bmad-output/planning-artifacts/architecture.md] line 110, [Source: inc/equates.inc] lines 42-46
- Render pipeline status-row emit (deferred to Story 1.11): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1492-1499
- Implementation sequence step 4 (statusln.asm): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1565-1567
- FR49 (status line on row 24): [Source: _bmad-output/planning-artifacts/prd.md] lines 789-790
- FR50 / FR51 / FR52 (unsupported-cmd no-op, I/O failure surfacing, no-silent-truncate): [Source: _bmad-output/planning-artifacts/prd.md] lines 795-805
- NFR5 (no crashes — every unexpected condition reported in status): [Source: _bmad-output/planning-artifacts/prd.md] lines 834-838
- NFR8 (BDOS rc check completeness — unexpected codes abort with status message): [Source: _bmad-output/planning-artifacts/prd.md] lines 842-848
- TH1 sentinel byte at 0xCFFE: [Source: _bmad-output/planning-artifacts/architecture.md] lines 710-716
- AR12 enforcement guideline (only statusln writes status_buffer): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1163-1167
- Pattern example for module header + routine contract: [Source: _bmad-output/planning-artifacts/architecture.md] lines 1183-1221 (search.asm reference)
- Story 1.1 baseline (NOT preserved here): [Source: _bmad-output/implementation-artifacts/1-1-project-skeleton-reproducible-build.md]
- Story 1.2 hand-off (STATUS_LINE_WIDTH, layered headers): [Source: _bmad-output/implementation-artifacts/1-2-compile-time-constants-equates-modes-vt52.md]
- Story 1.3 hand-off (status_buffer / status_dirty in state.inc, ASSERTs, post-RET INCLUDE pattern): [Source: _bmad-output/implementation-artifacts/1-3-static-memory-map-state-inc.md]
- Story 1.4 hand-off (BDOS_CALL macro, bdos_error_funnel forward reference, smoke test pattern): [Source: _bmad-output/implementation-artifacts/1-4-bios-bdos-shims-with-bdos-call-macro.md]
- Deferred-work register: [Source: _bmad-output/implementation-artifacts/deferred-work.md]
- Implementation readiness — FR17 / FR49 coverage: [Source: _bmad-output/planning-artifacts/implementation-readiness-report-2026-05-08.md] lines 278, 310
- Implementation readiness — dirty-buffer indicator decision deferred: [Source: _bmad-output/planning-artifacts/implementation-readiness-report-2026-05-08.md] lines 420-421, 548 (recorded as a Story 1.11 decision; not Story 1.5's scope)

## Dev Agent Record

### Agent Model Used

claude-opus-4-7 (1M context) — Claude Code dev-story workflow.

### Debug Log References

`make clean && make` (both runs identical):

```
RUN1: 23f4f144c20b2018504c50799869711c4029c040181b22717c60a61d95564fd7
RUN2: 23f4f144c20b2018504c50799869711c4029c040181b22717c60a61d95564fd7
MATCH (NFR18 OK)
vibe.com size: 202 bytes
```

This is the new SHA baseline as the first emit-changing story since 1.1 (Story 1.1 baseline `4fb733be…14de523a` retired).

Symbol-table addresses from `build/vibe.lst`:

```
0101  status_set_message
011D  bdos_error_funnel
0124  JP input_loop          (at offset 0x0124, jumps to 0x01C0)
0127  status_render
012C  msg_buffer_modified
013C  msg_file_too_large
014B  msg_pattern_not_found
015D  msg_search_wrapped
016C  msg_undo_too_large
018A  msg_nothing_to_undo
019A  msg_no_write
01B5  msg_bdos_error
01C0  input_loop
01CA  static_data_base       (was 0x0101 post-Story 1.4; shifted +201 by this story's emit)
```

state.inc ASSERTs:
- `static_data_base >= 0x0101` ✓ (0x01CA)
- `yank_end <= 0xD800` ✓ (build succeeded)

Smoke (`test/smoke/statusln_smoke.com`) under iz-cpm:

`--call-trace-all` output:
```
[[BDOS command 0: P_TERMCPM(028a)]][[Cold boot]]
RUN_EXIT=0
```

Only one BDOS call (function 0 = warm-boot exit). No fn 15+ calls — bdos_error_funnel was not entered, as expected for a smoke that does no file I/O.

`--cpu-trace` definitive pass-path evidence:
```
0102: LD (cffeh), A    AF:aaff   ; pre-write 0xAA "never ran" marker
0167: JR Z, +9         AF:6828   ; .copy_loop iter 1: A=0x68='h', NZ → continue
0167: JR Z, +9         AF:6524   ; .copy_loop iter 2: A=0x65='e'
... (17 iterations through "hello status line")
0167: JR Z, +9         AF:0044   ; iter 18: A=0x00, Z set → JR Z fires (.pad_loop)
0110: JR Z, +1e        AF:0100   ; check 1: status_dirty=1, NZ → don't fail
0117: JR NZ, +1e       AF:686a   ; check 2: A=0x68='h', Z set → don't fail
011e: JR NZ, +1e       AF:2062   ; check 3: A=0x20=' ', Z set → don't fail
0125: JR NZ, +1e       AF:2062   ; check 4: A=0x20=' ', Z set → don't fail
0129: LD (cffeh), A    AF:0162   ; *** A=0x01 PASS sentinel written to 0xCFFE ***
012c: JR +1c                     ; JR .exit
0005: JP f800h                   ; BDOS_ENTRY → iz-cpm BDOS fn 0 dispatch
```

AR12 grep audit (writes to status_buffer/status_dirty in src/ inc/):

```
src/statusln.asm:88:    LD      (status_dirty), A   ; status_set_message: set dirty
src/statusln.asm:144:   LD      (status_dirty), A   ; status_render: clear dirty
```

`status_buffer` is written via indirect `LD (DE), A` inside `.copy_loop` and `.pad_loop` of `status_set_message` (DE initialised from `LD DE, status_buffer`); also entirely inside src/statusln.asm. No other src/ or inc/ file writes either symbol. Test reads (smoke) are read-only and allowed.

AR15 grep audit (raw CALL 0x0005 / CALL BDOS_ENTRY in src/ inc/):

```
inc/bdos.inc:85:        CALL    BDOS_ENTRY    ; inside BDOS_CALL macro body
```

(plus comment matches in inc/bdos.inc:5/45/46/51 which document the rule). No raw matches in src/ — all production BDOS entry goes through the macro. The new `BDOS_CALL BDOS_EXIT` invocation in `src/vibe.asm:input_loop` is a macro invocation in source, expanded by sjasmplus at assembly time.

### Completion Notes List

- All 7 tasks and all 9 acceptance criteria satisfied.
- **MC5 funnel landed.** `status_set_message` (HL = msg, A = code) copies up to STATUS_LINE_WIDTH bytes, pads remainder with 0x20, sets status_dirty = 1. Truncation behaviour (no padding when 80 bytes copied without null) and padding behaviour (short message → space-pad) verified by trace.
- **AR12 locked structurally.** Tree-wide grep confirms only `src/statusln.asm` writes status_buffer / status_dirty. No other src/ or inc/ file touches them.
- **bdos_error_funnel body landed.** Story 1.4's forward reference now resolves; the funnel writes msg_bdos_error (safety-net default) via status_set_message, then JPs to input_loop. Per-fn dispatch deferred to Story 2.x as specified by AC7.
- **input_loop stub** added in src/vibe.asm; warm-boots via `BDOS_CALL BDOS_EXIT` (AR15 — first production macro expansion). Story 1.8 will replace the body with the real input-loop top-of-frame.
- **status_render** is the documented no-op stub (XOR A; LD (status_dirty), A; RET). Story 1.11 owns the real render path.
- **AR16 message strings** — eight messages (seven enumerated + msg_bdos_error safety net), all lowercase, no trailing periods, longest = 29 chars (msg_undo_too_large). Confirmed by length audit.
- **vibe.com SHA new baseline.** Story 1.1's `4fb733be…14de523a` retired (Story 1.5 emits 201 new bytes). New baseline: `23f4f144c20b2018504c50799869711c4029c040181b22717c60a61d95564fd7`. Reproducible across two clean rebuilds.
- **Smoke verification — definitive pass.** CPU trace confirms execution reached `LD (CFFE), A` with A=0x01 (pass sentinel). All four post-call checks passed: status_dirty != 0, status_buffer[0] = 'h', status_buffer[17] = ' ', status_buffer[79] = ' '. Only BDOS call observed: fn 0 (P_TERMCPM); no fn 15+ — proves bdos_error_funnel was not entered.
- **AR15 cross-check** confirms no raw CALL 0x0005 / CALL BDOS_ENTRY outside the macro body. The input_loop stub uses the macro form `BDOS_CALL BDOS_EXIT`.
- **Story 1.6 harness already landed** (out of dev-story-1.5 strict scope). The smoke is intentionally still under `test/smoke/` per AC4 ("not part of the Story 1.6 harness yet"). Future work may relocate to `test/cases/`.

### File List

Created:
- `src/statusln.asm`
- `test/smoke/statusln_smoke.asm`

Modified:
- `src/vibe.asm` (header Purpose + Public + Dependencies updated; INCLUDE statusln + input_loop stub spliced after the RET at 0x0100, before INCLUDE state.inc)

Not touched (per Dev Notes):
- `inc/equates.inc`, `inc/state.inc`, `inc/bios.inc`, `inc/bdos.inc`, `inc/vt52.inc`, `inc/modes.inc`
- Project-root `Makefile`, `.gitignore`
- `test/Makefile` (Story 1.6 owns; the smoke runs via manual sjasmplus + iz-cpm per dev notes)
- `test/smoke/bdos_call_smoke.asm` (Story 1.4 artifact; left alone)

### Change Log

| Date | Author | Change |
|------|--------|--------|
| 2026-05-09 | Story author | Initial story context — creates src/statusln.asm with status_set_message (MC5 funnel), bdos_error_funnel body (resolves Story 1.4's forward reference), status_render no-op stub, eight AR16-conforming msg_* strings; splices statusln INCLUDE into src/vibe.asm at AR25 position with input_loop stub abort target; smoke-tests status_set_message under iz-cpm against four invariants (dirty flag set, first byte copied, short-pad ran, tail-pad reached); establishes new vibe.com SHA baseline (Story 1.1 baseline retired — first emit-changing story since 1.1); locks AR12 (statusln-only writer of status_buffer/status_dirty) and MC5 structurally for the rest of the project. |

### Review Findings

Code review run 2026-05-09 (Blind Hunter + Edge Case Hunter + Acceptance Auditor). Auditor: all 9 ACs PASS, vibe.com SHA reproducible (`23f4f144…64fd7`). Patches and defers below; ~13 findings dismissed as noise (over-trashed BC is per spec template, hardcoded `80` matches AC2 prose, null-ptr defensive checks not project style, etc.).

- [x] [Review][Patch] statusln.asm header omits external `input_loop` symbol from Dependencies [src/statusln.asm:36-40] — applied: Dependencies now lists `src/vibe.asm (input_loop — abort target JPed to by bdos_error_funnel; Story 1.5 stub, Story 1.8 lands the real loop)`.
- [x] [Review][Patch] Smoke's input_loop stub silently masks unintended funnel entry [test/smoke/statusln_smoke.asm:86-95] — applied: the stub now writes `0xE5` to `0xCFFE` before BDOS_EXIT so an unintended funnel entry produces a distinct fail sentinel.
- [x] [Review][Patch] Smoke 0xCFFE sentinel address has no rationale comment [test/smoke/statusln_smoke.asm:18-25] — applied: comment now states `0xCFFE` is TPA scratch above yank_end and below CCP at 0xD800 (TH1 convention).
- [x] [Review][Patch] Smoke does not exercise truncation path (≥80-byte source) [test/smoke/statusln_smoke.asm] — applied: added Phase 3 with 80-byte `long_msg` ("0123456789ABCDEF" × 5), verifies status_buffer[0]='0', [79]='F', dirty re-set. Fail codes 0xE7-0xE9.
- [x] [Review][Patch] Smoke does not invoke bdos_error_funnel [test/smoke/statusln_smoke.asm] — applied: added Phase 4 — pre-flag 0xCFFE=0x01, CALL bdos_error_funnel; input_loop reads pre-flag to distinguish deliberate test from unintended entry, verifies status_buffer = "bdos error" + space pad. Fail codes 0xEA-0xEC.
- [x] [Review][Patch] Smoke does not invoke status_render [test/smoke/statusln_smoke.asm] — applied: added Phase 2 — set dirty=1, CALL status_render, verify dirty=0. Fail code 0xE6.

Re-ran via `iz-cpm --cpu-trace`: pre-flag 0x01 written at PC 0x0152, input_loop reads 0xCFFE at PC 0x02b6 with no subsequent overwrite — final 0xCFFE = 0x01 (PASS for all four phases).
| 2026-05-09 | Dev (claude-opus-4-7) | Implemented all 7 tasks. Wrote src/statusln.asm (status_set_message, bdos_error_funnel, status_render, eight msg_* strings). Updated src/vibe.asm (purpose comment, dependencies line, INCLUDE statusln, input_loop stub via BDOS_CALL BDOS_EXIT). Wrote test/smoke/statusln_smoke.asm; verified pass-path under iz-cpm with --cpu-trace (sentinel 0x01 written; all 4 checks passed). NFR18 verified — vibe.com SHA reproducible across two clean rebuilds; new baseline 23f4f144...64fd7 (202 bytes). AR12 grep confirmed statusln.asm is the only status_buffer/status_dirty writer in src/ inc/. AR15 grep confirmed only the BDOS_CALL macro body has raw CALL BDOS_ENTRY. All 9 ACs satisfied. Status: review. |
