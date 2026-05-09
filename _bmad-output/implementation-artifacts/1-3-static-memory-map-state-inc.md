# Story 1.3: Static memory map (state.inc)

Status: done

<!-- Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As the VIBE author,
I want all cross-module runtime state declared in a single `inc/state.inc` memory map,
So that MC7's "no inline addresses" rule holds, every module reads/writes shared state by symbolic name, and the static footprint is auditable in one place.

## Acceptance Criteria

1. **AC1 — `inc/state.inc` declares the full cross-module state set at fixed labels.**
   Given the static-data block in `inc/state.inc`,
   When I inspect it,
   Then the **single-byte / small state** is declared (one label per byte): `mode_byte`, `visual_submode`, `buffer_dirty`, `pending_operator`, `yank_kind`, `status_dirty`, `pending_motion_prefix`,
   And the **16-bit state** is declared (one label per 2-byte word): `cursor_offset`, `gap_start`, `gap_end`, `visual_anchor`, `count_accumulator`, `yank_length`, `top_line_offset`,
   And the **buffers** are declared at fixed labels with the architecture-canonical sizes: `status_buffer` (`STATUS_LINE_WIDTH` bytes = 80), `search_pattern` (1 length byte + `SEARCH_PATTERN_BUFFER` raw bytes = 65 total), `ex_buffer` (1 length byte + `EX_COMMAND_BUFFER` raw bytes = 65 total), `filename_buffer` (16 bytes), `shadow_buffer` (`SCREEN_ROWS * SCREEN_COLS` = 1920 bytes), `dirty_rows` (3 bytes — 24-bit row bitmap), `undo_buffer` (`UNDO_BUFFER_SIZE` bytes = 256),
   And every state label uses lowercase per AR22 (variables in static data are lowercase; only `GAP_BUFFER_BASE` is uppercase as a compile-time-constant address).

2. **AC2 — Static-data block is positioned after code, gap buffer is positioned after the static block.**
   Given `inc/state.inc` is INCLUDEd by `src/vibe.asm` at its AR25 position,
   When `make` succeeds,
   Then the listing file (`build/vibe.lst`) shows every state label at an address ≥ end-of-code (currently `0x0101` since code is just `RET` at `0x0100`),
   And `GAP_BUFFER_BASE` resolves to the **first address past the static block** (i.e. equals `static_data_base + static_block_size`),
   And no state label resolves below `0x0101` or above `GAP_BUFFER_BASE`.

3. **AC3 — `yank_buffer` is placed in the reserved pool at `GAP_BUFFER_BASE + GAP_BUFFER_MAX`, not in `state.inc`'s state block.**
   Given the SR6 yank-register placement policy,
   When I inspect `inc/state.inc`,
   Then `yank_buffer EQU GAP_BUFFER_BASE + GAP_BUFFER_MAX` appears in a clearly-labelled `;; --- Yank register (reserved pool, SR6) ---` section after `GAP_BUFFER_BASE`,
   And `yank_buffer` is **not** included in the static-block size accounting (its 1024 bytes live past the gap buffer, not before it),
   And a comment at the line documents that `YANK_BUFFER_SIZE` (= 1024) bytes are reserved at this address for the yank register.

4. **AC4 — `vibe.com` is byte-identical to Story 1.2 (no code reads state yet).**
   Given `inc/state.inc` declares state via EQU-style positional addresses (no emitting directives),
   When I run `make clean && make`,
   Then assembly succeeds with no errors and no warnings,
   And `sha256sum vibe.com` equals `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a` (the Story 1.1 baseline preserved by Story 1.2),
   And a second `make clean && make` produces the same SHA (NFR18 reproducibility).

5. **AC5 — NFR10 (TPA fit) is verifiable at assembly time.**
   Given the layout `code → static block → gap buffer → yank register → reserved pool → BDOS at 0xD800` (PC2),
   When `make` runs,
   Then `inc/state.inc` contains an `ASSERT yank_buffer + YANK_BUFFER_SIZE <= 0xD800` directive (or equivalent compile-time check) that **fails the build** if any future change pushes the highest VIBE-owned address past the BDOS entry,
   And `build/vibe.lst` lists `static_data_base`, `GAP_BUFFER_BASE`, `yank_buffer`, and an end-of-state sentinel (e.g. `static_end`) so the layout is mechanically auditable from the listing alone.

## Tasks / Subtasks

- [x] **Task 1 — Populate `inc/state.inc` with the static memory map** (AC: 1, 2, 3)
  - [x] Preserve the existing AR23 header block. Update `Public:` from `(none yet — populated in Story 1.3; will declare ...)` to enumerate the symbols this story lands (the small/16-bit state labels, the buffer labels, `static_data_base`, `static_end`, `GAP_BUFFER_BASE`, `yank_buffer`). Update `State owned (read/write)` to `(this file IS the static memory map; every cross-module variable is declared here)` and keep `Dependencies` as `inc/equates.inc` (sizes come from equates).
  - [x] Below the header, anchor the layout with `static_data_base EQU $`. **Use EQU-style positional declarations only** — see "🛑 No DEFB / DEFW / DEFS in state.inc" in the Dev Notes for the trap and the canonical pattern.
  - [x] Use a single re-assignable counter (sjasmplus `=` syntax) advanced after each label. Reference pattern (full layout — emit verbatim or refactor with a macro, but keep label names and order):
    ```
    static_data_base    EQU $        ; first address past code at INCLUDE site
    static_off          =   0        ; running offset, advanced per declaration

    ;; --- Single-byte / small state ---
    mode_byte               EQU static_data_base + static_off
    static_off              =   static_off + 1
    visual_submode          EQU static_data_base + static_off
    static_off              =   static_off + 1
    buffer_dirty            EQU static_data_base + static_off
    static_off              =   static_off + 1
    pending_operator        EQU static_data_base + static_off
    static_off              =   static_off + 1
    yank_kind               EQU static_data_base + static_off
    static_off              =   static_off + 1
    status_dirty            EQU static_data_base + static_off
    static_off              =   static_off + 1
    pending_motion_prefix   EQU static_data_base + static_off
    static_off              =   static_off + 1

    ;; --- 16-bit state ---
    cursor_offset           EQU static_data_base + static_off
    static_off              =   static_off + 2
    gap_start               EQU static_data_base + static_off
    static_off              =   static_off + 2
    gap_end                 EQU static_data_base + static_off
    static_off              =   static_off + 2
    visual_anchor           EQU static_data_base + static_off
    static_off              =   static_off + 2
    count_accumulator       EQU static_data_base + static_off
    static_off              =   static_off + 2
    yank_length             EQU static_data_base + static_off
    static_off              =   static_off + 2
    top_line_offset         EQU static_data_base + static_off
    static_off              =   static_off + 2

    ;; --- Buffers ---
    status_buffer           EQU static_data_base + static_off
    static_off              =   static_off + STATUS_LINE_WIDTH
    search_pattern          EQU static_data_base + static_off
    static_off              =   static_off + 1 + SEARCH_PATTERN_BUFFER
    ex_buffer               EQU static_data_base + static_off
    static_off              =   static_off + 1 + EX_COMMAND_BUFFER
    filename_buffer         EQU static_data_base + static_off
    static_off              =   static_off + 16
    shadow_buffer           EQU static_data_base + static_off
    static_off              =   static_off + SCREEN_ROWS * SCREEN_COLS
    dirty_rows              EQU static_data_base + static_off
    static_off              =   static_off + 3
    undo_buffer             EQU static_data_base + static_off
    static_off              =   static_off + UNDO_BUFFER_SIZE

    ;; --- Sentinel: end of static block ---
    static_end              EQU static_data_base + static_off

    ;; --- Gap buffer base (positional; SR2) ---
    GAP_BUFFER_BASE         EQU static_end

    ;; --- Yank register (reserved pool, SR6) ---
    ; YANK_BUFFER_SIZE (1024) bytes reserved at this address.
    yank_buffer             EQU GAP_BUFFER_BASE + GAP_BUFFER_MAX
    ```
  - [x] If you compress the boilerplate with a sjasmplus macro (e.g. `DECLARE_BYTE label`, `DECLARE_WORD label`, `DECLARE_BUFFER label, size`), the macro must be in `inc/state.inc` itself and must NOT use any emitting directive. The declared label set and the linear ordering must match the reference pattern above exactly. Order matters for AR25 stability: don't reorder fields casually.
  - [x] Preserve the architecture-canonical order within each section (small state → 16-bit state → buffers → sentinel → GAP_BUFFER_BASE → yank_buffer). Source: `_bmad-output/planning-artifacts/architecture.md` lines 1349–1394.
  - [x] Use 4-space indentation (AR24); UPPER_SNAKE for `EQU` keywords (sjasmplus is case-sensitive on directive case in some configs — match the existing `EQU` casing already in `equates.inc`).
  - [x] **Do not** declare `tick_counter` here — it's a BIOS-managed memory address and lives in `inc/bios.inc` (Story 1.4). Architecture lines 1384–1386 are explicit on this.

- [x] **Task 2 — Add NFR10 compile-time guardrail** (AC: 5)
  - [x] At the bottom of `inc/state.inc` (after `yank_buffer`), add:
    ```
    ;; --- NFR10 TPA-fit guardrail ---
    ; Highest VIBE-owned address must stay below CCP/BDOS at 0xD800
    ; (PC2: TPA = 0x0100..0xD7FF). If a future story grows code or
    ; the static block past this line, the build fails here, not at
    ; runtime on hardware.
        ASSERT yank_buffer + YANK_BUFFER_SIZE <= 0xD800
    ```
  - [x] Verify the assertion fires when violated: temporarily edit `inc/equates.inc` to set `GAP_BUFFER_MAX EQU 0xD000` (large enough that `yank_buffer + 1024` exceeds 0xD800); run `make`; confirm sjasmplus errors out with the assertion message; revert the edit; re-run `make` and confirm the SHA returns to baseline. **Do not commit the test edit.** This is a one-time validation that the guardrail is real.
  - [x] If sjasmplus 1.23.0's `ASSERT` syntax differs from the form above, use whatever sjasmplus directive enforces a build-time check (`IF condition / .ERROR / ENDIF`, or `DISPLAY` + condition). The mechanism is interchangeable; the requirement is "the build fails when the layout exceeds the TPA". Document the chosen form in a one-line comment.

- [x] **Task 3 — INCLUDE `inc/state.inc` from `src/vibe.asm` at its AR25 position** (AC: 2, 4)
  - [x] Current `src/vibe.asm` includes (above `ORG 0x0100`): `equates.inc → vt52.inc → modes.inc`. The AR25 final order is `equates → bios → bdos → vt52 → modes → state`. Story 1.4 will splice `bios.inc` and `bdos.inc` into their slots. **This story splices `state.inc` after `modes.inc`** (its AR25 slot, the last position). The post-1.3 block reads:
    ```
    ;; --- Includes (dependency order per AR25) ---
        INCLUDE "../inc/equates.inc"
        INCLUDE "../inc/vt52.inc"
        INCLUDE "../inc/modes.inc"
        INCLUDE "../inc/state.inc"
    ```
  - [x] Update the `Dependencies:` line in `src/vibe.asm`'s header from `inc/equates.inc, inc/vt52.inc, inc/modes.inc (bios.inc and bdos.inc arrive in Story 1.4; state.inc in 1.3)` to reflect that state.inc is now included (e.g., `inc/equates.inc, inc/vt52.inc, inc/modes.inc, inc/state.inc — bios.inc and bdos.inc arrive in Story 1.4`).
  - [x] **Do not** INCLUDE `bios.inc` or `bdos.inc` yet — they remain header-only stubs until Story 1.4. Match the Story 1.2 pattern: each story lands its content + its INCLUDE together.
  - [x] Path form: `"../inc/state.inc"` (relative to `src/`, matching the existing INCLUDE lines).
  - [x] **Do not** touch `ORG 0x0100` or the `RET` body. Story 1.12 owns the init/teardown; the AC4 SHA-identity check requires the emitted code to be exactly `0xC9` at `0x0100`.

- [x] **Task 4 — Build, verify clean assembly, verify NFR18 byte-identity** (AC: 4, 5)
  - [x] `make clean && make` — expect zero stdout (sjasmplus `--msg=err` quiet on success). Any warning/error halts the task.
  - [x] `sha256sum vibe.com` — **Expected hash:** `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a` (Story 1.1 baseline, preserved through Story 1.2). State.inc declares only EQU labels and one ASSERT — no emitting directives — so the only byte in the .com is still the `RET` at `0x0100`. **If the SHA differs**, the most likely cause is an accidental `DEFB`/`DEFW`/`DEFS`/`DB`/`DW`/`DS`/`BLOCK` in `inc/state.inc`. See "🛑 No DEFB / DEFW / DEFS" in Dev Notes for the trap.
  - [x] `make clean && make` a second time — same SHA (NFR18 reproducibility).
  - [x] Inspect `build/vibe.lst` symbol table:
    - `static_data_base` = `0x0101` (one byte past the `RET` — varies if code grows later, but for this story it's exactly `0x0101`).
    - `mode_byte` = `static_data_base + 0` = `0x0101`.
    - `visual_submode` = `0x0102`. `pending_motion_prefix` = `0x0107`.
    - `cursor_offset` = `0x0108` (first 16-bit field).
    - `top_line_offset` = `0x0114`.
    - `status_buffer` = `0x0116`. `search_pattern` = `0x0166`. `ex_buffer` = `0x01A7`. `filename_buffer` = `0x01E8`. `shadow_buffer` = `0x01F8`. `dirty_rows` = `0x0978`. `undo_buffer` = `0x097B`.
    - `static_end` = `0x0A7B`. `GAP_BUFFER_BASE` = `0x0A7B`. `yank_buffer` = `0x0A7B + 0x8000` = `0x8A7B`.
    - **NFR10 sanity:** `yank_buffer + 1024` = `0x8E7B` — well below `0xD800`, with ~18 KB of headroom for the post-MVP reserved pool. (Numbers are exact for this story; they shift as code grows in later stories.)
  - [x] If any address differs from the predictions above, the layout is wrong — recheck the per-field size in Task 1's reference pattern. The Task 1 reference is the source of truth.

- [x] **Task 5 — Verify naming, format, and convention compliance** (AC: 1)
  - [x] AR22 — every label declared in `inc/state.inc` matches its expected case: lowercase for state variables (`mode_byte`, `cursor_offset`, …, `static_data_base`, `static_off`, `static_end`, `yank_buffer`); UPPER_SNAKE for `GAP_BUFFER_BASE` only (it's the architecture's named compile-time-constant address per architecture lines 437, 1394). Spot-check: `grep -E '^[A-Z]' inc/state.inc` should match only `GAP_BUFFER_BASE` (and the AR23 header lines, which start with `;`).
  - [x] AR24 — 4-space indentation, never tabs: `grep -P '^\t' inc/state.inc` produces no matches.
  - [x] AR24 — section dividers use `;;`; line comments use `;`; no trailing periods on inline comments.
  - [x] AR23 header block preserved and `Public:` updated.

## Dev Notes

### Why this story exists

Story 1.2 landed compile-time constants (`equates.inc`, `modes.inc`, `vt52.inc`); this story lands their *runtime counterpart* — every cross-module mutable address. Together they realize MC7 ("Static memory map — fixed addresses for cross-module state"). After 1.3, every module written from Story 1.5 onward references state by symbol (`LD A, (mode_byte)`, `LD HL, (gap_start)`, etc.), and those references all bottom out in this file's labels. Getting the layout wrong here ripples into every module.

`state.inc` is also the single place where the architecture's "TPA layout: code → static data → gap buffer → reserved pool → BDOS" (architecture line 376) is *mechanically* expressed: `GAP_BUFFER_BASE EQU static_end` makes the gap buffer's address a function of the static block's size, and `yank_buffer EQU GAP_BUFFER_BASE + GAP_BUFFER_MAX` chains the reserved-pool layout from there. Adding a new state field automatically slides the gap buffer up; removing one slides it down. No magic numbers, no manual offset bookkeeping in code modules.

### Critical guardrails for the dev agent

**🛑 No `DEFB` / `DEFW` / `DEFS` / `DB` / `DW` / `DS` / `BLOCK` in `inc/state.inc`.** These directives **emit bytes** into the assembled output. If `state.inc` uses any of them, `vibe.com` grows by ~2,426 zero bytes (the static block size) and the AC4 SHA-identity check fails. The architecture document (lines 1349–1382) shows the layout *conceptually* using `DEFB`/`DEFW`/`DEFS`, but that snippet is a layout sketch, not the implementation form. The implementation form is **EQU-only**: positional addresses computed from `static_data_base + static_off`. Story 1.2 dev notes (lines 130) named the same firewall: "If you find yourself reaching for `DEFB`, you're in the wrong file." That guidance applies fully to Story 1.3. Verified empirically: an EQU-only `state.inc` keeps `vibe.com` at 1 byte (the `RET`), SHA = baseline; a single `DEFS` of any size breaks the SHA on the next build.

**🛑 `static_off` uses sjasmplus `=` (re-assignable), not `EQU` (single-assignment).** Each label gets `EQU` because addresses are constants once computed; the running offset uses `=` because it advances. Mixing them up — `static_off EQU static_off + 1` — is a single-assignment redefinition error in sjasmplus. The reference pattern in Task 1 has the right operators on every line; copy it as-is rather than re-deriving.

**🛑 `static_data_base EQU $` is correct here; `GAP_BUFFER_BASE EQU $` is NOT.** The phrase "positional EQU at the end of the static-data block" appears in Story 1.2's dev notes (line 128) and in `equates.inc`'s deferral comment (currently lines 53–62 of `inc/equates.inc`), which both reference `GAP_BUFFER_BASE EQU $`. That phrasing assumed a `DEFS`-emitting layout (where `$` advances). Since this story uses **EQU-only declarations**, `$` does NOT advance past `static_data_base`. `GAP_BUFFER_BASE` therefore must be `EQU static_end` (which equals `static_data_base + static_off` after every field has been declared). The "positional" intent is preserved — `GAP_BUFFER_BASE` is the first address past the static block, computed from the layout — only the mechanism differs.

**🛑 `yank_buffer` is in the reserved pool, NOT in the static block.** SR6 (architecture lines 456–461) places the 1024-byte yank register at `GAP_BUFFER_BASE + GAP_BUFFER_MAX`, in the reserved pool past the gap buffer. Do not include it in `static_off` accounting and do not declare it before `GAP_BUFFER_BASE` in the file. It's the *one* state address that lives past the gap buffer; treat it as a separate section. Architecture line 1389: "The yank register is *not* in `state.inc`" refers to its position (past the gap buffer, not in the static block) — but its EQU declaration *does* live in `inc/state.inc` per the architecture's worked example at line 1394.

**🛑 AR25 include order: state.inc is the LAST include before `ORG 0x0100`.** AR25 final order: `equates → bios → bdos → vt52 → modes → state`. Currently `bios.inc` and `bdos.inc` are still empty stubs (Story 1.4 lands them with their content + INCLUDE), so after this story the include block is `equates → vt52 → modes → state`. Don't insert state.inc before vt52.inc or modes.inc — it goes at the end. Don't preemptively splice in INCLUDEs for `bios.inc` / `bdos.inc` either; Story 1.2's dev notes (line 132) named that anti-pattern.

**🛑 `tick_counter` does NOT live in `state.inc`.** Architecture lines 1384–1386 explicitly route it to `inc/bios.inc` (it's a BIOS-managed memory address, read-only from VIBE, populated when `bios.inc` is wired in Story 1.4). If you find yourself adding a `tick_counter` label here, stop.

**🛑 Total static block size matters; per-field sizes must match the architecture exactly.**
| Field | Size | Source |
|---|---|---|
| 7 single-byte fields | 7 B | architecture lines 1349–1358 |
| 7 16-bit fields | 14 B | architecture lines 1361–1371 |
| `status_buffer` | 80 B (`STATUS_LINE_WIDTH`) | architecture line 1374 |
| `search_pattern` | 65 B (1 length + `SEARCH_PATTERN_BUFFER`) | architecture lines 1375–1376 |
| `ex_buffer` | 65 B (1 length + `EX_COMMAND_BUFFER`) | architecture lines 1377–1378 |
| `filename_buffer` | 16 B (8.3 + drive + null + slack) | architecture line 1379 |
| `shadow_buffer` | 1920 B (`SCREEN_ROWS * SCREEN_COLS`) | architecture line 1380 |
| `dirty_rows` | 3 B (24-bit row bitmap) | architecture line 1381 |
| `undo_buffer` | 256 B (`UNDO_BUFFER_SIZE`) | architecture line 1382 |
| **Total** | **2426 B** | |

If your computed addresses in `build/vibe.lst` disagree with Task 4's predicted values, recheck per-field sizes against this table.

**🛑 No `tick_counter`, no `paste_kind`, no `paste_length`, no `bdos_error_funnel` here.** Architecture mentions all four — `tick_counter` lives in `bios.inc` (Story 1.4); `paste_kind` and `paste_length` are *fields inside* the yank register's 1024-byte block, not separate state.inc labels (they're at `yank_buffer + 0` and `yank_buffer + 1` and read by yank/paste handlers in Stories 2.10/2.12; Story 1.3 doesn't carve sub-fields); `bdos_error_funnel` is a code label in `bdos.inc`'s macro expansion (Story 1.4). Stay strictly inside the AC1 list.

### Architecture compliance — what AR* / SR* / NFR* rules this story locks in

| AR / SR / NFR | Story 1.3 obligation |
|----|----------------------|
| AR11 / MC7 | `inc/state.inc` populated as the single static memory map; every cross-module variable accessed by symbol. |
| AR22 | State labels lowercase; `GAP_BUFFER_BASE` UPPER (architecture's named compile-time-constant address). |
| AR23 | Existing AR23 header block preserved; `Public:` enumerates landed symbols. |
| AR24 | UPPERCASE directives (`EQU`, `ASSERT`); 4-space indentation; `;` line / `;;` section comments; no trailing periods on inline comments. |
| AR25 | INCLUDE order in `vibe.asm`: `equates → vt52 → modes → state` (AR25 final order, with `bios`/`bdos` slots empty until Story 1.4). |
| AR26 | Reserved pool earmarked: `yank_buffer` placed at `GAP_BUFFER_BASE + GAP_BUFFER_MAX`; nothing else allocates from the pool in MVP. |
| SR1 | `cursor_offset` is a single 16-bit logical-file-space offset; no cached line/col fields. |
| SR2 | `gap_start` and `gap_end` are 16-bit physical addresses (not offsets). |
| SR4 | `mode_byte` and `visual_submode` are separate single-byte addresses. |
| SR5 | `visual_anchor` is a 16-bit logical offset alongside `visual_submode`. |
| SR6 | Yank register at `GAP_BUFFER_BASE + GAP_BUFFER_MAX`; sub-fields (`paste_kind`, `paste_length`) deferred to yank/paste implementation. |
| V2 | `top_line_offset` is in the 16-bit state block (validation issue V2 fixed inline at state.inc). |
| V3 | `pending_motion_prefix` is in the small state block (validation issue V3 fixed inline at state.inc). |
| V4 | Status funnel name is `status_set_message` (no `status_set_error`); not directly relevant to state.inc but the `status_buffer` and `status_dirty` labels declared here are the funnel's storage. |
| NFR10 | `ASSERT yank_buffer + YANK_BUFFER_SIZE <= 0xD800` enforces the TPA-fit invariant at every build. |
| NFR12 | All buffers sized at assembly time via named source equates (no runtime allocator, no dynamic sizing). |
| NFR16 | All sizes (`STATUS_LINE_WIDTH`, `SEARCH_PATTERN_BUFFER`, `EX_COMMAND_BUFFER`, `SCREEN_ROWS`, `SCREEN_COLS`, `UNDO_BUFFER_SIZE`, `GAP_BUFFER_MAX`, `YANK_BUFFER_SIZE`) sourced from `inc/equates.inc`; no magic numbers in `state.inc`. |
| NFR18 | `vibe.com` SHA-256 unchanged from Story 1.1 baseline (state.inc emits zero bytes). |

### Existing files — current state and what this story changes

**`inc/state.inc`** *(22 lines, AR23 header only — `Public: (none yet — populated in Story 1.3)`):*
- Current: header block; body is empty.
- This story: keep the header (update `Public:` to enumerate the landed symbols and update `State owned (read/write):` to reflect that this file IS the state declaration); append the EQU-style memory-map body per Task 1; append the NFR10 ASSERT per Task 2.

**`src/vibe.asm`** *(35 lines: AR23 header + 3-line INCLUDE block above `ORG 0x0100` + `RET` body):*
- Current: includes `equates.inc → vt52.inc → modes.inc`; header `Dependencies:` line names the three included headers and notes `bios/bdos/state` arrival in Stories 1.3–1.4.
- This story: append `INCLUDE "../inc/state.inc"` as the fourth and final line of the INCLUDE block (its AR25 slot); update header `Dependencies:` line to add `inc/state.inc`. **Do NOT touch** `ORG 0x0100` or the `RET` body — Story 1.12 owns init/teardown, and the SHA-identity check depends on the body byte.

**Files NOT touched by this story (do not edit):**
- `inc/equates.inc` — populated by Story 1.2 with `GAP_BUFFER_MAX`, `UNDO_BUFFER_SIZE`, `STATUS_LINE_WIDTH`, `SEARCH_PATTERN_BUFFER`, `EX_COMMAND_BUFFER`, `YANK_BUFFER_SIZE`, `SCREEN_ROWS`, `SCREEN_COLS`, `EDITABLE_ROWS`, `STATUS_ROW`, `ESC_TIMEOUT_TICKS`, `INDENT_BYTE`. Story 1.3 *consumes* these; do not redefine. Note: `equates.inc`'s "Notes" block (lines 53–62) describes `GAP_BUFFER_BASE` as `EQU $` at the end of state.inc — that wording assumed a DEFS-emitting layout. Leave the comment as-is for now (correcting it is in scope for Story 1.3 review if reviewers flag it; the dev should not preemptively edit the comment).
- `inc/modes.inc`, `inc/vt52.inc` — populated by Story 1.2; no changes here.
- `inc/bios.inc`, `inc/bdos.inc` — Story 1.4 (still empty stubs).
- `Makefile` — `$(wildcard inc/*.inc)` already picks up `inc/state.inc` for rebuild dependency; no change needed.
- `test/*` — headless harness lands in Story 1.6.

### Library / framework requirements

**sjasmplus 1.23.0 specifics relevant to this story:**

- **`EQU` is single-assignment.** Each label can only be `EQU`'d once. Don't try to redefine in a later pass.
- **`=` (or `DEFL`) is re-assignable.** This is what `static_off` needs. `static_off = 0` then `static_off = static_off + N` is well-formed. `static_off EQU 0` followed by `static_off = static_off + 1` is an error.
- **`$` is the current program-counter value.** `static_data_base EQU $` captures the PC at the include site. With EQU-only declarations afterward, `$` does NOT advance — only emitting directives (`DEFB`, `DEFW`, `DEFS`, `ORG addr`, etc.) advance the PC.
- **`ASSERT condition[, message]`** halts assembly with an error if the condition is false. Available since early sjasmplus; works in 1.23.0. Use this for NFR10 compile-time fit checking.
- **`--raw=<file>`** writes a flat binary from the lowest emitted byte to the highest. With state.inc as EQU-only, no bytes emit past the `RET` at `0x0100`; the .com is exactly 1 byte. (Empirically validated: an EQU-only test file produced `vibe.com` of 1 byte with SHA matching the Story 1.1 baseline.)
- **`--msg=err`** suppresses informational messages on success; only errors print. The Story 1.1/1.2 build pattern. Don't change the Makefile's flag set.
- **No header-only "include guards" needed.** sjasmplus doesn't multiply-include by default in this Make pattern (each INCLUDE is a single source-tree splice).

### Previous story intelligence (Stories 1.1 and 1.2)

**From Story 1.1:**
- **NFR18 baseline SHA:** `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a`. Story 1.2 preserved it; Story 1.3 must too.
- `vibe.com` lives at the project root (BA1), not under `build/`.
- The Makefile has a `check-toolchain` order-only prereq enforcing sjasmplus 1.23.0 (NFR14). Don't relitigate.
- Empty-directory policy: no `.gitkeep` files. Doesn't affect this story.

**From Story 1.2:**
- The pattern "land content + INCLUDE in the same story" is established. Story 1.3 follows it for `state.inc`; Story 1.4 will follow it for `bios.inc` and `bdos.inc`.
- **Don't pre-add INCLUDE directives for files that will be empty stubs at story end.** `bios.inc` and `bdos.inc` still have no content — leave them out of `vibe.asm` until Story 1.4.
- INCLUDE order strictly follows AR25 — *with empty slots when files aren't yet populated*. After 1.3 the slots are: `equates → (bios) → (bdos) → vt52 → modes → state`. The `(bios)` and `(bdos)` slots stay empty in the include block; Story 1.4 splices them in.
- AR23 header `Public:` lines are kept in sync with what the file actually exposes. This story updates state.inc's header similarly.
- Code review style: Blind Hunter + Edge Case Hunter + Acceptance Auditor. Story 1.2's reviewers caught NFR16-spirit violations (literal `80`s drifting independently from `SCREEN_COLS`) and a missing `STATUS_ROW` derivation. Expect similar scrutiny on state.inc — particularly on whether per-field sizes derive from named equates rather than literals (the reference pattern in Task 1 already does this; don't introduce a literal `80` for `status_buffer`'s size — use `STATUS_LINE_WIDTH`).
- Story 1.2 review patched `equates.inc` and `vt52.inc`; one item was deferred ("`VT52_GOTO` row/col clamp must land in render path") to Story 1.11. That's tracked in `_bmad-output/implementation-artifacts/deferred-work.md`. No state.inc dependencies on that.

### Git intelligence

Two commits on `main`:

- `b561c9e` — Story 1.1: Makefile pins sjasmplus 1.23.0, produces vibe.com.
- `eac5ba3` — Story 1.2: named every constant the editor needs, in three .inc headers, wired in.

Conventions visible in the tree:
- 4-space indentation, UPPERCASE mnemonics/directives, `;` line / `;;` section comments — preserve.
- `inc/*.inc` files are pure non-emitting (story 1.2 used only `EQU`); state.inc continues this — only `EQU`, `=`, and `ASSERT`.
- Header blocks (AR23) on every `.asm`/`.inc` file — preserve.
- `Makefile`'s `SOURCES := $(wildcard src/*.asm) $(wildcard inc/*.inc)` rebuilds when any `.inc` changes — no Makefile edit needed.

Commit-message style is short imperative + colon-separated context; one story per commit. Match it.

### Latest tech information

- **sjasmplus 1.23.0 release/manual:** EQU/=/ASSERT semantics described above are stable across 1.x. The `--raw` output mode emits the contiguous range from lowest to highest emitted byte; non-emitting directives (EQU, =, ASSERT) leave the PC and the emit window untouched.
- **CP/M 2.2 TPA:** PC2 names the TPA bounds as `0x0100..0xD7FF` (~54 KB). The static block + gap buffer + yank register total ~35 KB, leaving ~16–18 KB of headroom for code (tentative ~3 KB ceiling per NFR9) plus reserved pool. The NFR10 ASSERT in Task 2 enforces this mechanically.
- **No web research relevant.** This story is pure layout against fixed architecture; no third-party APIs or library versions to verify.

### Testing requirements

This story has **no headless test cases** — the iz-cpm test harness lands in Story 1.6. Verification is mechanical and entirely build-time:

1. `make clean && make` succeeds with no errors and no warnings.
2. `sha256sum vibe.com` equals `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a` (Story 1.1 / 1.2 baseline).
3. `make clean && make` a second time produces the same SHA (NFR18 reproducibility).
4. `build/vibe.lst` symbol table contains every state label predicted in Task 4 at the predicted address.
5. NFR10 ASSERT fires under a deliberate violation (Task 2 sub-task) and is removed/reverted before commit.
6. `grep -E '^[A-Z]' inc/state.inc | grep -v '^;'` matches only `GAP_BUFFER_BASE` (AR22 case audit).

Once Story 1.6 lands the harness, retroactive headless tests for the layout would mostly be tautological (sjasmplus already enforces it). The mechanical checks above are sufficient.

### Project Structure Notes

No new files are created. No directories are added. The structural changes are:
- `inc/state.inc` gains a populated body (was AR23-header-only stub).
- `src/vibe.asm`'s INCLUDE block grows by one line (`INCLUDE "../inc/state.inc"`) at the AR25-mandated position.

The `Complete Project Directory Structure` section of architecture.md (lines 1241–1339) anticipates exactly this state for `inc/state.inc`. No deviations from architecture.

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md#story-13-static-memory-map-stateinc] (lines 353–384)
- AR11 (state.inc as single static memory map): [Source: _bmad-output/planning-artifacts/epics.md] line 157
- AR22, AR23, AR24, AR25 (naming, header, format, include order): [Source: _bmad-output/planning-artifacts/epics.md] lines 177–180
- AR26 (reserved pool earmarked): [Source: _bmad-output/planning-artifacts/epics.md] line 184
- MC7 (static memory map): [Source: _bmad-output/planning-artifacts/architecture.md] lines 550–555
- SR1 (cursor as 16-bit offset, no cached line/col): [Source: _bmad-output/planning-artifacts/architecture.md] lines 426–431
- SR2 (gap pointers, two-halves invariant): [Source: _bmad-output/planning-artifacts/architecture.md] lines 433–439
- SR4 (mode byte + visual sub-mode at fixed addresses): [Source: _bmad-output/planning-artifacts/architecture.md] lines 447–450
- SR5 (visual anchor as 16-bit offset): [Source: _bmad-output/planning-artifacts/architecture.md] lines 452–454
- SR6 (yank register in reserved pool): [Source: _bmad-output/planning-artifacts/architecture.md] lines 456–461
- V2 (top_line_offset added inline at state.inc): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1653–1660
- V3 (pending_motion_prefix added inline at state.inc): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1662–1668
- Canonical state.inc layout block: [Source: _bmad-output/planning-artifacts/architecture.md#static-memory-map-incstateinc] lines 1341–1399
- AR25 final include order: [Source: _bmad-output/planning-artifacts/architecture.md#file-structure-patterns] lines 918–956
- TPA bounds (PC2): [Source: _bmad-output/planning-artifacts/architecture.md] lines 99–103; [Source: _bmad-output/planning-artifacts/implementation-readiness-report-2026-05-08.md] line 167
- NFR10 (TPA fit), NFR12 (static allocation only), NFR16 (knob centralization), NFR18 (reproducible build): [Source: _bmad-output/planning-artifacts/prd.md]; [Source: _bmad-output/planning-artifacts/epics.md] lines 121–124, 134–136
- NFR18 baseline SHA (preserved through 1.2): [Source: _bmad-output/implementation-artifacts/1-2-compile-time-constants-equates-modes-vt52.md] lines 39, 93, 200, 234–236
- Story 1.2 dev-notes hand-off ("GAP_BUFFER_BASE positional", "no DEFB in equates"): [Source: _bmad-output/implementation-artifacts/1-2-compile-time-constants-equates-modes-vt52.md] lines 116–143
- Story 1.2 review patches relevant here (`STATUS_LINE_WIDTH = SCREEN_COLS`, `EDITABLE_ROWS = SCREEN_ROWS-1`, `STATUS_ROW`): [Source: _bmad-output/implementation-artifacts/1-2-compile-time-constants-equates-modes-vt52.md] lines 107–113
- Deferred-work register (no state.inc-relevant items): [Source: _bmad-output/implementation-artifacts/deferred-work.md]

## Dev Agent Record

### Agent Model Used

Claude Opus 4.7 (1M context)

### Debug Log References

- `make clean && make` — clean assembly, zero warnings, `vibe.com` is 1 byte (`RET` at `0x0100`).
- `sha256sum vibe.com` — `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a` (Story 1.1/1.2 baseline preserved).
- `sjasmplus --lstlab=sort` symbol dump — every Task 4 predicted address verified exact:
  - `static_data_base = 0x0101`, `mode_byte = 0x0101`, `visual_submode = 0x0102`, `buffer_dirty = 0x0103`, `pending_motion_prefix = 0x0107`.
  - `cursor_offset = 0x0108`, `top_line_offset = 0x0114`.
  - `status_buffer = 0x0116`, `search_pattern = 0x0166`, `ex_buffer = 0x01A7`, `filename_buffer = 0x01E8`, `shadow_buffer = 0x01F8`, `dirty_rows = 0x0978`, `undo_buffer = 0x097B`.
  - `static_end = 0x0A7B`, `GAP_BUFFER_BASE = 0x0A7B`, `yank_buffer = 0x8A7B`. NFR10 headroom: `yank_buffer + 1024 = 0x8E7B`, ~18 KB below `0xD800`.
- NFR10 ASSERT verification — temporarily set `GAP_BUFFER_MAX EQU 0xD000` in equates.inc; build halted with `state.inc(110): error: [ASSERT] Assertion failed: yank_buffer + YANK_BUFFER_SIZE <= 0xD800`. Reverted; SHA returned to baseline.
- AR22 case audit: `grep -nE '^[A-Z]' inc/state.inc` matches only `GAP_BUFFER_BASE` (line 97).
- AR24 indent audit: `grep -nP '^\t' inc/state.inc` returns no matches.

### Completion Notes List

- All 5 tasks and every subtask complete; all 5 ACs satisfied.
- `inc/state.inc` populated with EQU-only positional declarations using a single re-assignable `static_off` counter, plus NFR10 `ASSERT yank_buffer + YANK_BUFFER_SIZE <= 0xD800`.
- `src/vibe.asm` includes `state.inc` AFTER the `RET` so that `static_data_base EQU $` resolves to `0x0101` (first address past code).
- **Spec deviation (resolved):** Task 3's literal placement (state.inc INCLUDE in the pre-`ORG 0x0100` block) contradicted AC2 ("every state label at an address ≥ end-of-code") and Task 4's predicted addresses. With state.inc included before `ORG`, `$` resolves to `0x0000`, putting `mode_byte` on top of the CP/M warm-boot vector. Per user direction, INCLUDE was placed after the `RET`. AR25 logical order is preserved (state is the last include in source order); the architecture's TPA layout (code → static block → gap buffer → reserved pool) is honored. Pure-EQU headers (`equates.inc`, `vt52.inc`, `modes.inc`) remain in the pre-`ORG` block since they are position-independent.
- `vibe.com` byte-identical to Story 1.1 / 1.2 baseline (NFR18); reproducible across two clean builds.

### File List

- `inc/state.inc` — populated body (was AR23-header-only stub); added EQU-style positional memory map for small state, 16-bit state, buffers, sentinel, `GAP_BUFFER_BASE`, `yank_buffer`, plus NFR10 `ASSERT`. Updated AR23 header `Public:` and `State owned:` fields.
- `src/vibe.asm` — header `Dependencies:` updated to add `inc/state.inc`; pre-`ORG` include block divider clarified ("Compile-time-constant includes"); new `INCLUDE "../inc/state.inc"` placed after the `RET` with a comment explaining why position matters.

### Change Log

| Date | Author | Change |
|------|--------|--------|
| 2026-05-09 | Story author | Initial story context — populates inc/state.inc with EQU-only memory map (single-byte + 16-bit + buffer state, GAP_BUFFER_BASE, yank_buffer), splices INCLUDE into vibe.asm at AR25 position, NFR10 ASSERT guardrail, preserves NFR18 baseline SHA. |
| 2026-05-09 | Amelia (dev) | Implemented state.inc EQU memory map and NFR10 ASSERT; wired INCLUDE into vibe.asm. INCLUDE placed after RET (not in the pre-ORG block) to satisfy AC2's "addresses ≥ end-of-code" requirement — resolves a contradiction between Task 3's literal placement and Task 4's predicted addresses. SHA preserved at baseline. |
| 2026-05-09 | Code review | Three-layer review (Blind / Edge / Auditor); 8 patches applied, 7 deferred, 11 dismissed. Hardened layout against future drift: `FILENAME_BUFFER_SIZE` and `DIRTY_ROWS_BITMAP_BYTES` equates added (NFR16), lower-bound `ASSERT static_data_base >= 0x0101` and `yank_end` sentinel symbol added, equates.inc Notes block patched to match EQU-only layout, "must stay above ASSERT" / "must be last INCLUDE" tripwires documented. SHA preserved at baseline; status → done. |

### Review Findings

Code review run 2026-05-09 with three parallel layers (Blind Hunter, Edge Case Hunter, Acceptance Auditor). Triage: 8 patches, 7 deferred, 11 dismissed as noise. Acceptance Auditor explicitly **endorsed** the dev's spec deviation on the state.inc INCLUDE placement (post-`RET` vs pre-`ORG`); all 5 ACs verified passing.

**Patch findings:**

- [x] [Review][Patch] `dirty_rows` size is the literal `3` instead of derived from `SCREEN_ROWS` — silently under-allocates if `SCREEN_ROWS` ever grows past 24. NFR16 violation. Add `DIRTY_ROWS_BITMAP_BYTES EQU (EDITABLE_ROWS + 7) / 8` to `inc/equates.inc` and reference in state.inc. [`inc/state.inc:86`, `inc/equates.inc`]
- [x] [Review][Patch] `filename_buffer` size is the literal `16` instead of from a named equate — NFR16 symmetry. Add `FILENAME_BUFFER_SIZE EQU 16` to `inc/equates.inc` and reference in state.inc. [`inc/state.inc:82`, `inc/equates.inc`]
- [x] [Review][Patch] No lower-bound ASSERT on `static_data_base`. The dev had to navigate exactly this trap (pre-ORG INCLUDE resolves `$ = 0x0000`); a future maintainer could trip again. Add `ASSERT static_data_base >= 0x0101` near the top of state.inc. [`inc/state.inc`]
- [x] [Review][Patch] `vibe.asm:25` comment ("Pure-EQU headers; no bytes emit, position before ORG is fine") overstates safety — state.inc is also pure-EQU but is NOT safe before ORG (uses `$`). Tighten to: `; Pure-EQU headers that do not use $; safe before ORG.` [`src/vibe.asm:25`]
- [x] [Review][Patch] ASSERT uses `yank_buffer + YANK_BUFFER_SIZE` rather than a `yank_end` sentinel symbol. A future maintainer "fixing" the apparent asymmetry by setting `yank_buffer EQU GAP_BUFFER_BASE + GAP_BUFFER_MAX + YANK_BUFFER_SIZE` would silently shift the pool and the ASSERT would still pass. Introduce `yank_end EQU yank_buffer + YANK_BUFFER_SIZE` as the named past-the-end address; rewrite ASSERT as `ASSERT yank_end <= 0xD800`. Also exposes a usable named symbol for any future "highest VIBE-owned address" check. [`inc/state.inc:103,110`]
- [x] [Review][Patch] ASSERT placement is vulnerable to future state being appended below it (the guard would no longer cover the new highest address). Add an explicit comment above the NFR10 block: `; All VIBE-owned state must be declared ABOVE this line. Future fields go above this divider.` [`inc/state.inc:106-110`]
- [x] [Review][Patch] `vibe.asm` allows future code to be added below the state.inc INCLUDE, which would emit bytes past `static_data_base` and overlap declared statics with no build-time error. Add a comment near the INCLUDE: `; state.inc MUST be the last source emitted from vibe.asm. Do not add code below this line.` Optionally add `ASSERT $ <= static_data_base` immediately after the include as a tripwire. [`src/vibe.asm:41`]
- [x] [Review][Patch] `inc/equates.inc:53-62` Notes block describes the obsolete `GAP_BUFFER_BASE EQU $` DEFS-emitting layout — the implementation went EQU-only, so the prose is now misleading. Spec line 245 explicitly authorizes patching this at review time. Rewrite to describe the current EQU-only `GAP_BUFFER_BASE EQU static_end` form. [`inc/equates.inc:53-62`]

**Deferred:**

- [x] [Review][Defer] `search_pattern` and `ex_buffer` "1 length byte + N payload" convention has no compile-time enforcement on consumers — defer to ex/search story implementations (2.1, 3.1) where the convention is first read.
- [x] [Review][Defer] Static state has no zero-initialization story — CP/M `.com` files do not zero TPA. Belongs in Story 1.12 (init/teardown).
- [x] [Review][Defer] No alignment / page-crossing consideration for `shadow_buffer` (potential `H = row + base_high` render fast-path) — relevant when render code lands (Story 1.11).
- [x] [Review][Defer] Mode-state protocol undocumented — `pending_operator` vs `pending_motion_prefix` vs `visual_submode` semantics. Defer to mode-dispatch and command-parser stories (1.9, 1.10).
- [x] [Review][Defer] `inc/state.inc` has no `IFDEF` re-include guard. sjasmplus's natural EQU-collision catches accidental double-include, but a project-wide convention would be defensive.
- [x] [Review][Defer] No per-section sentinels (`small_state_end`, `word_state_end`, `buffer_block_end`) with ASSERTs catching a missed `static_off` advance. EQU collision currently catches only direct overlap; a forgotten advance silently aliases.
- [x] [Review][Defer] No file-naming or comment convention to distinguish EQU-only vs positional `.inc` headers — project-wide structural question. The current state.inc/equates.inc split documents it only in two scattered comments.

**Dismissed (11):** GAP_BUFFER_MAX naming convention; mixed casing (verified AR22-compliant); ASSERT half-open bound notation (correct convention); 16-bit overflow in `yank_buffer` arithmetic (sjasmplus uses higher-precision expressions; ASSERT catches it); `filename_buffer` length-byte asymmetry (architecture explicitly defines NUL-terminated); `shadow_buffer` EDITABLE-vs-all-rows (architecture line 1380 specifies `SCREEN_ROWS * SCREEN_COLS`); `static_off` symbol leak (informational; final value = total static block size); `yank_length` 16-bit choice (fine); reliance on undefined-in-this-file equates (NFR16 by design); total-size accounting comment (already exposed via `static_off` in `vibe.lst`); spec post-hoc patch of Task 3 placement (deviation already logged in Completion Notes; spec is a historical artifact).

---

**Completion note:** Ultimate context engine analysis completed — comprehensive developer guide created.
