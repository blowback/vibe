# Story 1.9: Mode dispatch with sparse-table binary search

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As the VIBE author,
I want `src/dispatch.asm` exposing `dispatch_key`, plus per-mode sparse sorted (key, handler_addr) tables and per-mode unbound-key fall-through handlers,
so that MC3's binary-search dispatch contract holds, FR12/FR16/FR50 are realized, and the ~1.8 KB code-budget reclamation vs flat 256-entry tables is achieved.

## Acceptance Criteria

1. **Module header.**
   **Given** `src/dispatch.asm` module header
   **When** I inspect it
   **Then** it documents `Public: dispatch_key`, the four per-mode tables (`dispatch_normal`, `dispatch_insert`, `dispatch_command`, `dispatch_visual`), the four unbound-key handlers (e.g. `unbound_normal`, `unbound_insert`, `unbound_command`, `unbound_visual`), entry-count equates per table (e.g. `DISPATCH_NORMAL_COUNT`), register conventions, and dependencies on `inc/equates.inc`, `inc/bdos.inc`, `inc/modes.inc`, `inc/state.inc`, `src/statusln.asm` (per AR23).

2. **`dispatch_key` contract — hit path.**
   **Given** `dispatch_key` (`In: A = key, HL = base of mode table, B = entry count`, `Out: jumps to handler or unbound fall-through; A = key on handler entry per MC4`)
   **When** I call it with a key present in the table
   **Then** binary search locates the entry in ≤ 6 iterations and transfers control (via `JP (HL)` or equivalent) to the handler address from the table entry
   **And** A holds the key on handler entry (MC4)
   **And** the handler RETs to `dispatch_key`'s caller (no register-passed parameters; handler operates on global state per MC4).

3. **`dispatch_key` contract — miss path.**
   **Given** `dispatch_key` is called with a key not in the table
   **When** binary search exhausts (`lo == hi`)
   **Then** control transfers to the per-mode unbound-key handler (paired 2-byte address per MC3)
   **And** A holds the key on unbound entry (so the unbound handler can inspect it for e.g. literal-byte insertion in INSERT mode).

4. **Unbound — `MODE_NORMAL` and `MODE_VISUAL`.**
   **Given** the unbound handler for `MODE_NORMAL` (and `MODE_VISUAL`)
   **When** invoked
   **Then** it calls `status_set_message` with a beep / no-op message string (e.g. `msg_unbound_key`), leaves all editor state unchanged (`mode_byte`, `cursor_offset`, `visual_anchor`, `count_accumulator`, `pending_operator`, `pending_motion_prefix` all unchanged — FR50)
   **And** returns to `dispatch_key`'s caller via `RET`
   **And** does NOT call `BIOS_CONOUT` directly (AR13: only `render.asm` and `init.asm`'s declared exception emit screen bytes; the Epic 1 surrogate is a status-line message, not a BEL byte).

5. **Unbound — `MODE_INSERT`.**
   **Given** the unbound handler for `MODE_INSERT`
   **When** invoked with any A
   **Then** it does not crash on any input
   **And** as a stub for Epic 1, EITHER (a) calls `status_set_message` with `msg_not_implemented` (the simplest stub form) OR (b) returns silently (no-op stub). Full literal-byte insertion lands in Story 2.8.

6. **Unbound — `MODE_COMMAND`.**
   **Given** the unbound handler for `MODE_COMMAND` in Epic 1
   **When** invoked
   **Then** it calls `status_set_message` with `msg_not_implemented` (or returns silently as a no-op stub) — concrete `:`-line editing handlers land in Story 2.1.

7. **`dispatch_normal` — Epic 1 entry shape.**
   **Given** Epic 1's `dispatch_normal` table with stub entries for mode-transition keys
   **When** I inspect `dispatch_normal`
   **Then** it contains entries for `i` (enter insert), `a` (enter insert at next — Epic 1 stub routes to `enter_insert_mode`), `o`/`O` (Epic 1 stubs route to `enter_insert_mode`), `:` (enter command mode), `v` (enter visual mode — sets `visual_submode = VIS_CHAR`), `/` (search prompt — Epic 1 stub: `status_set_message msg_not_implemented`), `Ctrl-L` (full refresh — Epic 1 stub: `status_set_message msg_not_implemented`, real impl in Story 1.11), and a temporary debug-quit key (`Ctrl-Q` = 0x11) that exits via `BDOS_CALL BDOS_EXIT`
   **And** every stub mode-change entry's handler updates `mode_byte` (and `visual_submode` if entering visual) and calls `status_set_message` with the matching mode-indicator string (e.g. `msg_mode_insert`).

8. **`dispatch_insert` — Esc transition.**
   **Given** the `dispatch_insert` table
   **When** I inspect it
   **Then** it contains a single entry: Esc (0x1B) → `enter_normal_mode` (FR16)
   **And** all other keys (printable, control, arrows, etc.) fall through to the INSERT-mode unbound handler.

9. **`dispatch_command` and `dispatch_visual` — Esc only.**
   **Given** `dispatch_command` and `dispatch_visual` in Epic 1
   **When** I inspect them
   **Then** each contains exactly one entry: Esc (0x1B) → `enter_normal_mode` (FR16) — concrete handlers land in 2.1 / 3.3.

10. **Sorted ascending by key, 3-byte entries, footprint cap.**
    **Given** the four sparse sorted dispatch tables
    **When** I inspect each
    **Then** entries are sorted ascending by key (hand-ordered in source per MC3; the implementation MAY add per-entry build-time `ASSERT entry_n_key > entry_n_minus_1_key` guards but is NOT required to)
    **And** each entry is exactly 3 bytes (1-byte key + 2-byte handler address)
    **And** total dispatch-table footprint across all four mode tables (entries plus the per-mode 2-byte unbound prefix) is under 256 bytes.

11. **Headless tests pass.**
    **Given** headless tests under `test/cases/dispatch_*.asm`
    **When** I run `make test` from project root
    **Then** the following three new tests pass: `dispatch_binary-search-finds-key.asm`, `dispatch_binary-search-misses.asm`, `dispatch_mode-transition.asm`
    **And** the live baseline becomes 10 pass / 1 fail (7 pre-1.9 passes from Story 1.7 + 1.7's review-added `gapbuf_delete-mid` + 3 new `dispatch_*` cases; the only `fail` remains the deliberate `harness_fail` from Story 1.6).

12. **Calling convention (MC1, MC4).**
    **Given** the calling convention (MC1, MC4)
    **When** I inspect handler entries (mode-change handlers, unbound handlers, the debug-quit handler)
    **Then** each handler is a `RET`-terminating routine that operates on global state (no register-passed parameters apart from the MC4 `A = key just consumed` documented contract) and is caller-saved per MC1 (each handler preserves anything it needs across calls it makes — push/pop is the handler's responsibility, not the caller's).

13. **Build-time invariants and AR/NFR enforcement.**
    **Given** the project build invariants
    **When** I run `make` from project root
    **Then** `vibe.com` builds cleanly under sjasmplus 1.23.0 (NFR14)
    **And** two consecutive `make clean && make` runs produce byte-identical `vibe.com` (NFR18)
    **And** `grep -nE 'BIOS_CONOUT' src/dispatch.asm` returns zero matches (AR13 — dispatch never emits screen bytes; the unbound handlers go through `status_set_message`, not direct `BIOS_CONOUT`)
    **And** `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/dispatch.asm` returns zero matches (AR15 — the only BDOS path is `BDOS_CALL BDOS_EXIT` in the debug-quit handler; raw `CALL 0x0005` is forbidden)
    **And** `grep -nE 'gapbuf_(insert|delete|move_gap|load|init)' src/dispatch.asm` returns zero matches (AR14 — dispatch doesn't mutate the buffer; mode-change is metadata-only).

14. **`vibe.asm` integration.**
    **Given** AR25's INCLUDE order (`init → input → statusln → gapbuf → render → dispatch → parser → motions → ...`)
    **When** I inspect `src/vibe.asm` after Story 1.9
    **Then** `INCLUDE "dispatch.asm"` lands AFTER `INCLUDE "gapbuf.asm"` and BEFORE the `input_loop:` body and the trailing `INCLUDE "../inc/state.inc"` (since `render.asm` does not yet exist — it slots in BEFORE `dispatch.asm` when Story 1.11 lands)
    **And** the `vibe.asm` header `Dependencies:` line adds `src/dispatch.asm (Story 1.9)`
    **And** the `;; --- Input-loop abort target ---` comment block in `vibe.asm` is NOT touched by this story (it already correctly points to Story 1.12 as the loop-body owner per Story 1.8's edit).

## Tasks / Subtasks

- [x] Task 1 — Read foundational artifacts and previous-story dev-notes (no code change). (AC reference: all)
  - [x] Read `_bmad-output/planning-artifacts/architecture.md` § Module Calling Conventions (MC1, MC3, MC4) and § Project Structure & Boundaries (especially AR25 INCLUDE order).
  - [x] Read `_bmad-output/implementation-artifacts/1-8-input-layer-with-esc-arrow-disambiguation.md` § Dev Notes — the prior story's house style is the template for this one.
  - [x] Confirm `mode_byte`, `visual_submode`, `status_dirty`, `count_accumulator`, `pending_operator`, `pending_motion_prefix` already exist in `inc/state.inc` (lines 45-78 per Story 1.8's layout); Story 1.9 adds NO new state.inc fields.
- [x] Task 2 — Add mode-indicator and unbound-key message strings to `src/statusln.asm` per AR16. (AC: 4, 5, 6, 7, 13)
  - [x] Append to the message-string block at the bottom of `src/statusln.asm` (after the existing `msg_bdos_error` at line 182): `msg_mode_normal`, `msg_mode_insert`, `msg_mode_command`, `msg_mode_visual`, `msg_unbound_key`. Lowercase, no trailing period, target under 30 chars (AR16). Suggested values: `"-- insert --"`, `"-- command --"`, `"-- visual --"`, `""` (empty for normal mode — clears the indicator), `"unbound key"` (or `"?"` if you want the leanest beep surrogate). Each is null-terminated per AR24.
  - [x] Update the `src/statusln.asm` header `Public:` block to enumerate the new symbols under "Message strings".
  - [x] Do NOT touch `status_set_message`, `bdos_error_funnel`, or `status_render` bodies.
- [x] Task 3 — Create `src/dispatch.asm` with the standard module-header block per AR23. (AC: 1)
  - [x] Header block: Module / Purpose / Public / State owned (none — dispatch is stateless except for the writes its handlers do to `mode_byte` / `visual_submode`) / Register conventions / Dependencies. Mirror `src/input.asm` lines 1-49 for shape.
  - [x] Public block enumerates: `dispatch_key`, `dispatch_normal`, `dispatch_insert`, `dispatch_command`, `dispatch_visual`, `unbound_normal`, `unbound_insert`, `unbound_command`, `unbound_visual`, `enter_normal_mode`, `enter_insert_mode`, `enter_command_mode`, `enter_visual_mode`, `mode_full_refresh_stub`, `mode_search_prompt_stub`, `mode_debug_quit`, plus the four entry-count equates `DISPATCH_NORMAL_COUNT` / `DISPATCH_INSERT_COUNT` / `DISPATCH_COMMAND_COUNT` / `DISPATCH_VISUAL_COUNT`.
  - [x] Dependencies line lists `inc/modes.inc` (mode IDs, KEY_ARROW_*), `inc/bdos.inc` (BDOS_CALL, BDOS_EXIT — for the debug-quit handler), `inc/state.inc` (mode_byte, visual_submode), `src/statusln.asm` (status_set_message + the message strings added in Task 2). Note: `inc/bios.inc` is NOT a dependency (no BIOS_CONOUT, no BIOS_CONIN — dispatch is invoked AFTER input has consumed the key).
- [x] Task 4 — Implement `dispatch_key` per MC3. (AC: 2, 3, 12)
  - [x] Public entry. `In: A = key, HL = base of mode table, B = entry count. Out: JPs to handler (A=key preserved per MC4) or to per-mode unbound handler (A=key preserved). Trashes: A, BC, DE, HL, F (the handler is responsible for whatever it touches per MC1).`
  - [x] **Recommended table-layout convention (consistent with the architecture line 518-523 spec):** the 2-byte unbound handler addr is the FIRST 2 bytes of the mode table; sorted (key, handler_addr) entries follow. dispatch_key reads the unbound prefix, pushes it on the stack (or stashes in a temp slot), advances HL past the prefix to point at the first entry, then runs the binary search. On miss, transfers control to the unbound. On hit, transfers control to the matched handler. The dev MAY pick a different convention if better-justified (e.g. unbound passed in a register, or unbound stored at the END of the table) so long as AC2/AC3 hold.
  - [x] **Algorithm sketch (one viable shape):**
    ```
    dispatch_key:
        ; Stash key in C — the binary search will clobber A
        LD      C, A
        ; Read unbound from table prefix; push for later JP-on-miss
        LD      E, (HL)
        INC     HL
        LD      D, (HL)
        INC     HL                  ; HL now points at first entry
        PUSH    DE                  ; unbound on stack
        ; lo (D) = 0, hi (E) = B; iterate while lo < hi
        LD      D, 0
        LD      E, B
    .search:
        LD      A, E
        SUB     D
        JR      Z, .miss            ; lo == hi → not found
        SRL     A
        ADD     A, D                ; mid index
        ; Compute entry-base + mid*3 — three 16-bit ADDs is the cleanest path
        PUSH    HL
        LD      L, A
        LD      H, 0                ; HL = mid (16-bit zero-extended)
        ADD     HL, HL              ; HL = mid*2
        ; Need mid*3 = mid*2 + mid; pull mid back into another reg
        ; (see Dev Notes "*3 multiplication" trap for register juggling)
        ; ...
        ; Compare key (in C) to entry-key at (entry_addr); branch lo/eq/hi.
        ; On equality, load handler addr from entry_addr+1, JP via (HL).
        ; On lo, hi := mid; on hi, lo := mid + 1; loop.
        ; ...
    .miss:
        ; Pop unbound and JP to it. RET via stack: the pushed address IS the
        ; jump target, so a bare RET would jump there. But A must be restored
        ; to the original key first.
        LD      A, C                ; restore key
        RET                         ; "RET to pushed unbound" — Z80 idiom
    ; on hit:
    ;   LD      A, C                ; restore key (MC4)
    ;   POP     DE                  ; discard pushed unbound
    ;   ; ...JP via the handler addr loaded from the entry...
    ```
    The `RET-to-pushed-addr` idiom is a clean way to JP-on-miss: PUSH unbound; if you reach the miss path with the stack untouched, RET pops the unbound and "returns" there. The hit path must POP-and-discard the unbound before its own JP. Document the stack discipline in the routine's contract comment.
  - [x] On hit, the handler-address load + indirect JP can be: `LD E, (HL); INC HL; LD D, (HL); EX DE, HL; JP (HL)` — A holds key (restored from C) on JP.
  - [x] Worst-case iteration target: 6 iterations for B = 64 (architecture line 515; Epic 1's largest table is `dispatch_normal` at 9 entries → 4 iterations).
- [x] Task 5 — Implement the four mode tables and entry-count equates. (AC: 7, 8, 9, 10, 13)
  - [x] **`dispatch_normal`** — recommended sorted entries (ascending by key byte):
    ```
    dispatch_normal:
        DEFW unbound_normal                 ; 2-byte unbound prefix
    .entries:
        DEFB 0x0C : DEFW mode_full_refresh_stub      ; Ctrl-L (FR48 stub; 1.11 lands real)
        DEFB 0x11 : DEFW mode_debug_quit             ; Ctrl-Q debug-only — exits via BDOS_EXIT
        DEFB '/'  : DEFW mode_search_prompt_stub     ; / search prompt stub (3.1 lands real)
        DEFB ':'  : DEFW enter_command_mode          ; FR14
        DEFB 'O'  : DEFW enter_insert_mode           ; Epic 1 stub for FR27
        DEFB 'a'  : DEFW enter_insert_mode           ; Epic 1 stub for FR25
        DEFB 'i'  : DEFW enter_insert_mode           ; FR13
        DEFB 'o'  : DEFW enter_insert_mode           ; Epic 1 stub for FR26
        DEFB 'v'  : DEFW enter_visual_mode           ; FR15
    DISPATCH_NORMAL_COUNT EQU ($ - .entries) / 3
    ```
    9 entries × 3 = 27 bytes + 2-byte prefix = 29 bytes.
  - [x] **`dispatch_insert`**: 2-byte prefix `unbound_insert` + one entry `0x1B → enter_normal_mode`. `DISPATCH_INSERT_COUNT EQU 1`. 5 bytes total.
  - [x] **`dispatch_command`**: 2-byte prefix `unbound_command` + one entry `0x1B → enter_normal_mode`. `DISPATCH_COMMAND_COUNT EQU 1`. 5 bytes total.
  - [x] **`dispatch_visual`**: 2-byte prefix `unbound_visual` + one entry `0x1B → enter_normal_mode`. `DISPATCH_VISUAL_COUNT EQU 1`. 5 bytes total.
  - [x] Total table footprint: 29 + 5 + 5 + 5 = 44 bytes — well under 256 bytes (AC10 cap).
  - [x] Sort-order comment per table — make the ascending-key invariant visible without forcing per-entry ASSERTs. Optional: add `ASSERT (entry_n_key > entry_n_minus_1_key)` lines per consecutive pair to catch a typo at build time. NOT required by AC10.
- [x] Task 6 — Implement the four mode-change handlers. (AC: 7, 8, 9, 12)
  - [x] `enter_normal_mode`: writes `MODE_NORMAL` to `mode_byte`, calls `status_set_message` with `HL = msg_mode_normal` and `A = 0` (no error code), `RET`. Used by Esc-in-INSERT, Esc-in-COMMAND, Esc-in-VISUAL.
  - [x] `enter_insert_mode`: writes `MODE_INSERT` to `mode_byte`, calls `status_set_message` with `HL = msg_mode_insert` and `A = 0`, `RET`. Used by `i`/`a`/`o`/`O` (all four route here in Epic 1).
  - [x] `enter_command_mode`: writes `MODE_COMMAND` to `mode_byte`, calls `status_set_message` with `HL = msg_mode_command` and `A = 0`, `RET`. Used by `:`.
  - [x] `enter_visual_mode`: writes `MODE_VISUAL` to `mode_byte`, writes `VIS_CHAR` to `visual_submode`, calls `status_set_message` with `HL = msg_mode_visual` and `A = 0`, `RET`. Used by `v`. Setting `visual_submode = VIS_CHAR` is mandatory per AC7 ("update mode_byte (and visual_submode if entering visual)").
  - [x] Each handler is `RET`-terminating (MC4) and operates on global state (no register-passed parameters apart from the MC4 `A = key just consumed`, which these handlers do not actually consume but is part of the contract).
- [x] Task 7 — Implement the three Epic-1 stub handlers. (AC: 7)
  - [x] `mode_full_refresh_stub` (Ctrl-L): calls `status_set_message` with `HL = msg_not_implemented` and `A = 0`, `RET`. Story 1.11 replaces with `JP render_full` (or equivalent).
  - [x] `mode_search_prompt_stub` (`/`): same as above. Story 3.1 lands the real prompt.
  - [x] `mode_debug_quit` (Ctrl-Q): `BDOS_CALL BDOS_EXIT` followed by a defensive `RET`. The `BDOS_CALL` macro is the AR15-mandated gateway (raw `CALL 0x0005` is forbidden; AC13 grep enforces). `BDOS_EXIT` warm-boots back to CCP and never returns on a real CP/M host; the trailing `RET` is defensive in case of a misconfigured BIOS during hardware bring-up.
- [x] Task 8 — Implement the four unbound-key handlers. (AC: 4, 5, 6)
  - [x] `unbound_normal`: calls `status_set_message` with `HL = msg_unbound_key` and `A = 0`, `RET`. Per AC4: leaves all editor state unchanged. NO `BIOS_CONOUT` (AR13).
  - [x] `unbound_visual`: same as `unbound_normal` (architecture treats normal/visual unbound symmetrically per architecture line 520).
  - [x] `unbound_insert`: per AC5 — Epic 1 stub. EITHER `status_set_message` with `msg_not_implemented` then `RET`, OR a bare `RET` (silent no-op). Story 2.8 replaces with the literal-byte insertion path. Pick the simpler form (silent `RET`) unless visible-feedback-on-stub-key feels worth it.
  - [x] `unbound_command`: per AC6 — Epic 1 stub. Same options as `unbound_insert`. Story 2.1 replaces with the ex-line edit path.
- [x] Task 9 — Insert `INCLUDE "dispatch.asm"` into `src/vibe.asm` per AR25. (AC: 14)
  - [x] Add `INCLUDE "dispatch.asm"` AFTER `INCLUDE "gapbuf.asm"` (line 64 of current `src/vibe.asm`) and BEFORE the `;; --- Input-loop abort target ---` comment block (line 66) — i.e., between line 64's `INCLUDE "gapbuf.asm"` and line 66's section divider.
  - [x] Add a per-INCLUDE comment block matching the prior INCLUDEs' style (see `src/vibe.asm` lines 43-49 for input.asm's pattern, lines 51-56 for statusln.asm, lines 58-64 for gapbuf.asm).
  - [x] Update the `src/vibe.asm` header `Dependencies:` line (line 22) to add `src/dispatch.asm (Story 1.9)` alongside the existing entries.
  - [x] Do NOT modify the `input_loop:` body (lines 76-79) — the loop body remains the Story 1.5 stub that warm-boots via `BDOS_CALL BDOS_EXIT`; Story 1.12 lands the real loop body that ties `input_get_key + dispatch_key + render_diff` together.
  - [x] Do NOT modify the `;; --- Input-loop abort target ---` comment block (lines 66-75) — it already correctly points to Story 1.12 as the loop-body owner (Story 1.8 fixed it).
- [x] Task 10 — Write `test/cases/dispatch_binary-search-finds-key.asm`. (AC: 11)
  - [x] Build a synthetic small sorted table (e.g. 4-7 entries with distinct keys 'A', 'C', 'M', 'X', 'Z' or similar) WITHIN the test file (not pulling in the production `dispatch_normal`). Each entry routes to a sentinel handler that sets `(TEST_CONTEXT)` to a unique value and returns.
  - [x] Call `dispatch_key` with each key in the table. After return, verify `(TEST_CONTEXT)` matches the expected sentinel for that handler. If any mismatch, `JP test_fail` with `A = 0xE1` + numbered context.
  - [x] Cover edge cases: leftmost key, rightmost key, middle key (forces multiple iterations).
  - [x] On all-pass, `JP test_pass`.
  - [x] Standard test prologue/epilogue + production INCLUDEs (statusln.asm + dispatch.asm + the test_input_loop_stub) + state.inc LAST. Mirror `test/cases/gapbuf_insert-empty.asm` for shape (the cleanest prior-art test).
- [x] Task 11 — Write `test/cases/dispatch_binary-search-misses.asm`. (AC: 11)
  - [x] Same synthetic table as Task 10. Set the per-table 2-byte unbound prefix to point at a sentinel handler that sets `(TEST_CONTEXT)` to e.g. 0xBE ("beep") and returns.
  - [x] Call `dispatch_key` with keys NOT in the table: (a) below the leftmost key, (b) above the rightmost key, (c) between two adjacent entries (gap key).
  - [x] After each call, verify `(TEST_CONTEXT) == 0xBE` and that no unrelated state was clobbered.
  - [x] On all-pass, `JP test_pass`.
- [x] Task 12 — Write `test/cases/dispatch_mode-transition.asm`. (AC: 11, 7, 8)
  - [x] Pre-set `(mode_byte) = MODE_NORMAL`. Call `dispatch_key` with `A = 'i'`, `HL = dispatch_normal`, `B = DISPATCH_NORMAL_COUNT`. After the handler returns, verify `(mode_byte) == MODE_INSERT`. Sentinel `0xE1` on failure.
  - [x] Then call `dispatch_key` with `A = 0x1B`, `HL = dispatch_insert`, `B = DISPATCH_INSERT_COUNT`. Verify `(mode_byte) == MODE_NORMAL`. Sentinel `0xE2`.
  - [x] Then call with `A = ':'` against `dispatch_normal`. Verify `MODE_COMMAND`. Sentinel `0xE3`. Then Esc against `dispatch_command`. Verify `MODE_NORMAL`. Sentinel `0xE4`.
  - [x] Then call with `A = 'v'` against `dispatch_normal`. Verify `(mode_byte) == MODE_VISUAL` AND `(visual_submode) == VIS_CHAR`. Sentinels `0xE5` / `0xE6`. Then Esc against `dispatch_visual`. Verify `MODE_NORMAL`. Sentinel `0xE7`.
  - [x] On all-pass, `JP test_pass`.
  - [x] Production INCLUDEs needed: `src/statusln.asm` (status_set_message + message strings), `src/dispatch.asm`, the test input_loop stub, `inc/state.inc` LAST.
- [x] Task 13 — Build, test, determinism check, AR-grep enforcement. (AC: 11, 13)
  - [x] `make` from project root → `vibe.com` builds cleanly.
  - [x] `make clean && make` twice → byte-identical SHA across runs (NFR18). Capture both SHAs in Debug Log References.
  - [x] `make -C test test` → 10 pass / 1 fail (the deliberate `harness_fail` is the only `fail`; the seven pre-1.9 cases — `gapbuf_*` × 6 + `harness_pass` — still pass; the three new `dispatch_*` cases pass). Capture verbatim in Debug Log References.
  - [x] `grep -nE 'BIOS_CONOUT' src/dispatch.asm` → zero matches. (AR13)
  - [x] `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/dispatch.asm` → zero matches. (AR15 — `BDOS_CALL BDOS_EXIT` macro expansion writes `CALL BDOS_ENTRY` after macro expansion, but the source-level grep is against the unexpanded source which uses the macro name; sjasmplus expands at assembly time, not in the source file.) Capture grep output in Debug Log References.
  - [x] `grep -nE 'gapbuf_(insert|delete|move_gap|load|init)' src/dispatch.asm` → zero matches. (AR14 — dispatch never mutates the gap buffer; mode transitions are metadata-only.)

## Dev Notes

### Critical traps — what to watch for when implementing this story

**🛑 The architecture's `dispatch_key` sample (architecture lines 498-516) is incomplete in two known ways.** Don't copy it verbatim:
1. The sample's `RET Z` on miss is wrong — Story 1.9 AC3 says control transfers to the per-mode unbound handler, not to `dispatch_key`'s caller. The dev must implement the unbound-fall-through path (e.g. PUSH unbound on entry, RET-on-miss to "return" to the pushed address).
2. The sample uses `LD A, E; SUB D` — that clobbers A, which entered the routine holding the key. MC4 says the handler reads `A = key just consumed`. So before any `SUB`/`CP`/etc. that touches A, stash the key (e.g. `LD C, A`) and restore A from the stash before the final JP-to-handler.

**🛑 Mid-index × 3 multiplication has a subtle register-pressure trap.** The cleanest path is `LD D,0; LD E,mid; ADD HL,DE; ADD HL,DE; ADD HL,DE` — but that overwrites D/E if you're using them as lo/hi. Either reload D/E from saved-elsewhere copies after the multiply, OR restructure to use B/C for lo/hi and free D/E for the offset compute. There's no register-allocator pressure relief in Z80 — plan it before you start writing. The architecture's "~50 T-states per iteration" budget assumes the offset compute is roughly `3 × 11 = 33 T-states` for the three 16-bit adds plus ~15-20 T-states for the comparison and branch updates.

**🛑 Z80 `JP (HL)` is `JP HL`, not `JP (memory[HL])`.** It transfers control to the address IN HL, not to the address stored AT HL. To dispatch via an indirect handler-address, you must first LOAD the address into HL/IX/IY: `LD E,(HL); INC HL; LD D,(HL); EX DE,HL; JP (HL)`. This is a classic Z80 footgun for anyone arriving from a CISC mental model.

**🛑 `RET-to-pushed-address` is a legitimate Z80 idiom for "JP via stack."** PUSH a target addr; later, RET pops it and "returns" there. Used here for the unbound fall-through: `PUSH DE` (DE = unbound) on entry; on miss, a bare `RET` jumps to unbound. The cost is one PUSH (11 T-states) on every dispatch + one POP-discard on the hit path (10 T-states) — cheaper than self-modifying code, less fragile than carrying unbound in a register through the search loop. Document the stack discipline in the routine's contract comment so the next reader doesn't mistake it for a buggy "missing JP."

**🛑 Sort order is ASCII-byte ascending — UPPERCASE letters sort BEFORE lowercase.** `'O' = 0x4F`, `'a' = 0x61`, `'i' = 0x69`, `'o' = 0x6F`, `'v' = 0x76`, `':' = 0x3A`. The `dispatch_normal` table order in Task 5 reflects this. Don't re-sort by alphabet-as-humans-see-it; the binary search relies on ascii-byte order. Per-entry build-time `ASSERT entry_n > entry_n_minus_1` lines are optional (AC10 doesn't require them) but cheap insurance against a later append-without-resort.

**🛑 `BDOS_CALL` macro arguments are textual substitution.** `BDOS_CALL BDOS_EXIT` expands to `LD C, BDOS_EXIT` etc. Parenthesising — `BDOS_CALL (BDOS_EXIT)` — expands to `LD C, (BDOS_EXIT)` which is a 16-bit memory load from address 0 (since BDOS_EXIT EQU 0). Documented in `inc/bdos.inc` lines 67-72; the trap is generic, but `mode_debug_quit` is a fresh BDOS-call site so worth re-flagging.

**🛑 `LD A, imm` and `LD r, imm8` do NOT modify the flags.** A handler that does `LD A, MODE_INSERT; LD (mode_byte), A; RET` returns with the caller's CF — wherever it was at entry. No active caller in Story 1.9 inspects CF after a handler RET (the handler's caller is `dispatch_key`'s caller, which inspects nothing post-dispatch), so this is inert today. But Story 1.10's parser may dispatch through these handlers and rely on CF semantics — leave the handlers' CF as "undefined per MC1's caller-saved discipline" rather than promising anything.

**🛑 `mode_byte` and `visual_submode` writes ARE the side-effect.** Don't add a "dirty mode" flag thinking the renderer needs a hint — the status-line message dirties via `status_dirty` (set by `status_set_message`), and the mode change shows up there. The render pipeline (Story 1.11) does NOT need a separate mode-change signal; the status_dirty path covers it.

**🛑 The unbound handler must not crash on ANY input.** `unbound_insert` is hit on every key in INSERT mode that isn't Esc — printable letters, control bytes, the synthesised `KEY_ARROW_*` codes (0x80-0x83), high-bit bytes from foreign keymaps. A crash here turns the editor into an unrecoverable mode-trap (Esc is the only key that ever escapes INSERT). Pick the silent-RET form unless you're certain the status-line write has no failure path that loops here.

**🛑 `status_set_message` trashes A, BC, DE, HL, F (per its contract at `src/statusln.asm` lines 26-27).** Mode-change handlers that load `MODE_INSERT` into A then call `status_set_message` need to either (a) store mode_byte BEFORE the call, or (b) reload A after. The simplest pattern is `LD A, MODE_INSERT; LD (mode_byte), A; LD HL, msg_mode_insert; XOR A; CALL status_set_message; RET` — store first, then assemble the message-call args.

**🛑 The mode-table layout convention pinned in Task 5 puts the unbound 2-byte addr BEFORE the entries.** That means the test cases in Tasks 10/11 — which build synthetic tables — must also place a 2-byte unbound prefix at their `dispatch_test_table:` label. If the dev picks a different convention (e.g. trailing unbound, or register-passed unbound), the tests must match. Stay consistent across production and test code.

**🛑 `Ctrl-Q` (0x11) is the debug-quit key, NOT `Ctrl-C` or `Ctrl-X`.** AC7 says "a temporary debug-quit key (e.g., Ctrl-Q)." 0x11 was chosen because (a) Ctrl-C / 0x03 is the CP/M warm-boot interrupt and may be intercepted before reaching VIBE, (b) Ctrl-X / 0x18 is sometimes a line-erase glyph in CP/M editors and feels overloaded. 0x11 / Ctrl-Q (XOFF in serial flow control) is not bound to anything VIBE cares about. The handler is removed when the editor exits via `:q` / `:q!` (Story 2.1) — make sure to delete the entry from `dispatch_normal` at that point.

**🛑 `state.inc` MUST remain the LAST INCLUDE in `src/vibe.asm` AND in any test file.** Adding fields to `state.inc` would shift the layout, but Story 1.9 adds NO new state.inc fields — `mode_byte` (line 45), `visual_submode` (line 47), `status_dirty` (line 55) all exist from Story 1.3. The positional anchor `static_data_base EQU $` at state.inc line 37 still resolves correctly. `vibe.com`'s SHA changes after Story 1.9 (deliberate — new code in dispatch.asm, new strings in statusln.asm), but two consecutive rebuilds still produce byte-identical output (NFR18 holds; AC13 verifies).

**🛑 The AR25 INCLUDE order requires `dispatch.asm` to land AFTER `render.asm`, but `render.asm` does not exist until Story 1.11.** Place `dispatch.asm` AFTER `gapbuf.asm` in `src/vibe.asm` for Story 1.9. When Story 1.11 lands `render.asm`, it slots in BEFORE `dispatch.asm` (the same way Stories 1.5 / 1.7 / 1.8 each picked up the AR25 chain at the next-available position). The AR25 chain is `init → input → statusln → gapbuf → render → dispatch → parser → ...`; Story 1.9 adds the `dispatch` link.

**🛑 No new state.inc fields in Story 1.9 — RESIST the urge to add `dispatch_temp_unbound` or similar.** The `RET-to-pushed-addr` pattern uses the stack, not static memory. Adding state for a transient routine-local value violates the "small static state" discipline (state.inc is ~2 KB by design). If a future story needs a persistent dispatch-related value, it goes in then; not pre-emptively here.

**🛑 The INSERT-mode unbound handler will see `KEY_ARROW_*` (0x80-0x83) when arrows are pressed in insert mode.** No table entry matches them in `dispatch_insert` (Story 1.9 carves out only Esc), so they fall through to `unbound_insert`. Story 2.5 / 2.8 land the real arrow → motion mapping in INSERT mode (probably as a dedicated entry per arrow, not a fall-through). For Epic 1, a silent RET on arrows is fine — the editor doesn't move the cursor in insert mode for Story 1.9 anyway.

### Architecture compliance — what AR* / SR* / NFR* / TH* rules this story locks in

| Rule | Story 1.9 obligation |
|---|---|
| AR6  | All compile-time knobs in `inc/equates.inc`. Story 1.9 reads only existing equates (mode IDs from `inc/modes.inc`, BDOS function nums from `inc/bdos.inc`); adds `DISPATCH_*_COUNT` per-table size equates inside `src/dispatch.asm` (table-local; not appropriate for `inc/equates.inc` since they're derived from table extent, not author-tunable knobs). NO new equates in `inc/equates.inc`. |
| AR10 | Mode IDs and synthesised arrow keycodes in `inc/modes.inc`. Story 1.9 reads `MODE_NORMAL/INSERT/COMMAND/VISUAL` and `VIS_CHAR` (declared at `inc/modes.inc` lines 23-29); also reads `KEY_ARROW_*` indirectly via the unbound-insert handler's tolerance for them. NO new mode equates. |
| AR12 | Single status-message funnel: every status-line write in `src/dispatch.asm` (mode-indicator messages, unbound-key beep surrogate, stub messages) goes through `status_set_message` (`src/statusln.asm`). Direct writes to `status_buffer` / `status_dirty` are forbidden. AC13 enforces by absence-of-direct-writes (no grep for status_buffer / status_dirty in dispatch.asm — this would also pass since dispatch.asm doesn't reference state.inc symbols beyond `mode_byte` and `visual_submode`). |
| AR13 | Single screen-emission path: `render.asm` (Story 1.11) is the only module that calls `BIOS_CONOUT`; init's initial clear is the declared exception. Story 1.9 dispatches mode changes to `status_set_message`, NOT to `BIOS_CONOUT`. AC13 grep enforces. |
| AR14 | Single buffer-mutation owner: `gapbuf.asm` is the only mutator. Story 1.9's mode changes are metadata-only (mode_byte, visual_submode); they do NOT call `gapbuf_insert/delete/move_gap`. AC13 grep enforces. |
| AR15 | Single BDOS gateway: `BDOS_CALL` macro. The only BDOS use site in `src/dispatch.asm` is `BDOS_CALL BDOS_EXIT` in `mode_debug_quit`. Raw `CALL 0x0005` / `CALL BDOS_ENTRY` is forbidden. AC13 grep enforces (`grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY'` returns zero matches at the source level — sjasmplus expands the macro at assembly time, so the source-level grep stays clean). |
| AR16 | Status-message string-table convention: new strings added to `src/statusln.asm` (`msg_mode_normal`, `msg_mode_insert`, `msg_mode_command`, `msg_mode_visual`, `msg_unbound_key`) MUST be lowercase, no trailing period, target under 30 chars, null-terminated. The vi-classic UPPERCASE `"-- INSERT --"` is rejected by AR16; use lowercase `"-- insert --"`. |
| AR21 | Headless coverage scope: dispatch is fully testable headlessly (it's pure-state logic — no BIOS, no tick counter, no `BDOS_CALL` until the debug-quit handler which the tests don't exercise). The three new tests `dispatch_binary-search-finds-key.asm` / `dispatch_binary-search-misses.asm` / `dispatch_mode-transition.asm` are explicitly in the AR21 scope ("command parser ... operator+motion composition" — dispatch is a near-relative). |
| AR22 | Naming: `dispatch_key`, `dispatch_normal/insert/command/visual`, `unbound_normal/insert/command/visual`, `enter_*_mode`, `mode_full_refresh_stub`, `mode_search_prompt_stub`, `mode_debug_quit` are all `module_action`-style lowercase. Internal labels in `dispatch_key` use dotted-locals (`.search`, `.miss`, `.found`, `.compute_offset`, etc.). The per-table count equates `DISPATCH_*_COUNT` are UPPER_SNAKE_CASE per AR22's "equates and macros UPPER_SNAKE_CASE" rule. |
| AR23 | Module header block + four-line `In:` / `Out:` / `Trashes:` / `Calls:` per public routine AND per internal helper. AC1 enforces. |
| AR24 | UPPERCASE mnemonics + registers; 4-space indent; `;` line / `;;` section comments; null-terminated strings (the new `msg_mode_*` and `msg_unbound_key` are null-terminated per AR24 default). |
| AR25 | `INCLUDE "dispatch.asm"` in `src/vibe.asm` lands AFTER `INCLUDE "gapbuf.asm"` and BEFORE the `input_loop:` body (since `render.asm` doesn't yet exist). When Story 1.11 lands, `render.asm` slots in BEFORE `dispatch.asm`. |
| MC1 | Caller-saved everywhere by default. `dispatch_key`'s `Trashes:` line lists every register it touches; mode-change handlers' `Trashes:` lines list theirs (including A, BC, DE, HL, F due to the `status_set_message` call). |
| MC3 | Sparse sorted (key, handler_addr) tables per mode + binary search. AC2/AC3/AC10 enforce. |
| MC4 | Handler signature: `A = key just consumed`. dispatch_key restores A from the saved-key slot before the JP-to-handler. |
| MC7 | All cross-module state via symbols in `state.inc`. dispatch.asm reads/writes `mode_byte`, `visual_submode` by symbol; never inline addresses. |
| NFR1 | Incremental render: dispatch never emits screen bytes (AR13 holds via grep); the only screen-state change a mode transition produces is `status_dirty` set by `status_set_message`. The render pipeline (1.11) picks up `status_dirty` via the same diff approach as content rows. |
| NFR2 | Sustained typing: dispatch_key worst-case 6 iterations × ~50 T-states ≈ 300 T-states ≈ 75 µs at 4 MHz — three orders of magnitude under perceptible (architecture lines 525-527). Won't slow typing. |
| NFR9 | Code-size budget: estimated 200-350 bytes for dispatch.asm (dispatch_key ≈ 60 bytes, four mode tables ≈ 44 bytes, mode-change handlers ≈ 80 bytes, unbound handlers ≈ 40 bytes, debug-quit ≈ 15 bytes, padding/headers). Plus ≈ 80 bytes of new strings in statusln.asm. Total ≈ 280-430 bytes added. Track via `make sizes` (still a stub; Story 1.11 wires it). Stay well within the ~3 KB envelope. |
| NFR10 | TPA fit: `inc/state.inc`'s `ASSERT yank_end <= 0xD800` covers static-block + gap + yank. dispatch.asm code adds ≈ 200-350 bytes of code (no static), well under the headroom. |
| NFR16 | Knob centralization: dispatch reads `MODE_NORMAL/INSERT/COMMAND/VISUAL`, `VIS_CHAR`, `BDOS_EXIT`, `BDOS_ENTRY` (via the BDOS_CALL macro) by symbol; no inline `LD A, 0` for MODE_NORMAL or `LD C, 0` for BDOS_EXIT. |
| NFR17 | Mode/operator decoupling: dispatch tables (this story) are independent of parser logic (Story 1.10). The parser's count/operator/motion-prefix state lives in `inc/state.inc` and is read by parser entries that are themselves dispatch-table targets — but dispatch.asm has no knowledge of the parser's state machine. |
| NFR18 | Reproducibility: `vibe.com` byte-identical across rebuilds (AC13). sjasmplus is deterministic on identical input. |

### Existing files — current state and what this story changes

**`src/dispatch.asm`** *(does not exist):*
- Current: not present.
- This story: create per Tasks 3-8. Single public dispatcher (`dispatch_key`), four mode tables, four unbound handlers, four mode-change handlers, three Epic-1 stub handlers. Estimated ~200-350 bytes of code + ~44 bytes of table data.

**`src/vibe.asm`** *(90 lines after Story 1.8):*
- Current: pre-ORG INCLUDEs equates/bios/bdos/vt52/modes (lines 30-34), then `ORG 0x0100` (line 36), then `RET` stub (line 38), then `INCLUDE "input.asm"` (line 49), then `INCLUDE "statusln.asm"` (line 56), then `INCLUDE "gapbuf.asm"` (line 64), then the `;; --- Input-loop abort target ---` comment block (lines 66-75) followed by the `input_loop:` Story 1.5 stub (lines 76-79), then `INCLUDE "../inc/state.inc"` LAST (line 90).
- This story: insert `INCLUDE "dispatch.asm"` between `INCLUDE "gapbuf.asm"` (line 64) and the `;; --- Input-loop abort target ---` divider (line 66). Match the per-INCLUDE comment-block style of the prior INCLUDEs (2-3 line `;; --- ` block citing AR25 + a one-line "Story X.Y" reference). Update the `vibe.asm` header `Dependencies:` line (line 22) to add `src/dispatch.asm (Story 1.9)`. Do NOT modify the `input_loop:` body (Story 1.12 owns it) or the `;; --- Input-loop abort target ---` comment block (Story 1.8 already targeted it correctly to Story 1.12).

**`src/statusln.asm`** *(183 lines after Story 1.7):*
- Current: provides `status_set_message`, `bdos_error_funnel`, `status_render`, message-string block at lines 174-182 (`msg_buffer_modified`, `msg_file_too_large`, `msg_pattern_not_found`, `msg_search_wrapped`, `msg_undo_too_large`, `msg_nothing_to_undo`, `msg_not_implemented`, `msg_no_write`, `msg_bdos_error`).
- This story: append five new message strings to the bottom of the message block (after `msg_bdos_error` at line 182): `msg_mode_normal`, `msg_mode_insert`, `msg_mode_command`, `msg_mode_visual`, `msg_unbound_key`. Update the header `Public:` block (lines 15-18) to enumerate the new symbols under "Message strings". Do NOT modify `status_set_message`, `bdos_error_funnel`, or `status_render`.

**`inc/state.inc`** *(126 lines after Story 1.8):*
- Current: declares `mode_byte` (line 45), `visual_submode` (line 47), `status_dirty` (line 55), `pending_motion_prefix` (line 57), `input_held_byte` (line 59), `input_held_flag` (line 61), plus the 16-bit-state and buffer blocks. The `ASSERT yank_end <= 0xD800` at line 126 caps the layout.
- This story: NOT modified. Story 1.9 reads `mode_byte` and `visual_submode` by symbol; no new fields needed.

**`src/input.asm`**, **`src/gapbuf.asm`**:
- All unchanged. Story 1.9 does not call `input_get_key` (the input-loop body that wires input → dispatch lands in Story 1.12) or any `gapbuf_*` (AR14: dispatch is mode-metadata only).

**`inc/equates.inc`**, **`inc/bios.inc`**, **`inc/bdos.inc`**, **`inc/modes.inc`**, **`inc/vt52.inc`**:
- All unchanged. Story 1.9 reads `MODE_NORMAL/INSERT/COMMAND/VISUAL` and `VIS_CHAR` from `inc/modes.inc`; reads `BDOS_EXIT` and the `BDOS_CALL` macro from `inc/bdos.inc`; no new equates or modes.

**`Makefile`** / **`test/Makefile`**:
- All unchanged. Build infrastructure picks up `src/dispatch.asm` automatically via the `wildcard src/*.asm` glob (top-level Makefile line 29). Test harness picks up the three new `test/cases/dispatch_*.asm` files automatically via `wildcard cases/*.asm` (test/Makefile).

**`test/cases/`** *(currently 8 files: harness_pass + harness_fail + 6 gapbuf cases):*
- Current: 8 cases. Live baseline 7 pass / 1 fail (only `harness_fail` fails by design).
- This story: add three new cases — `dispatch_binary-search-finds-key.asm`, `dispatch_binary-search-misses.asm`, `dispatch_mode-transition.asm`. New baseline: 11 cases, 10 pass / 1 fail.

**`test/inc/`**, **`test/fixtures/`**, **`test/smoke/`**:
- All unchanged. Existing prologue/epilogue/input_loop_stub support the new tests as-is.

**Files NOT touched by this story (do not edit):**
- `inc/equates.inc`, `inc/bios.inc`, `inc/bdos.inc`, `inc/modes.inc`, `inc/vt52.inc`, `inc/state.inc` — all referenced by symbol; no edits needed.
- `Makefile`, `test/Makefile` — wildcards pick up new sources / new tests automatically.
- `src/input.asm`, `src/gapbuf.asm` — unchanged.
- `test/cases/*.asm` (existing) — unchanged. Existing `gapbuf_*.asm` and `harness_*.asm` still pass.
- `test/inc/*.inc`, `test/fixtures/hello.txt`, `test/smoke/*.asm` — unchanged.
- `_bmad-output/implementation-artifacts/deferred-work.md` — Story 1.9 doesn't address any prior deferral by design (the architectural location for the documented protocol of `pending_operator` / `pending_motion_prefix` from Story 1.3's deferred list is Story 1.10's parser, not Story 1.9's dispatch).

**Files created by this story:**
- `src/dispatch.asm` (new — primary deliverable).
- `test/cases/dispatch_binary-search-finds-key.asm` (new).
- `test/cases/dispatch_binary-search-misses.asm` (new).
- `test/cases/dispatch_mode-transition.asm` (new).

**Files modified by this story:**
- `src/vibe.asm` — add `INCLUDE "dispatch.asm"` (per AR25); update header `Dependencies:` line.
- `src/statusln.asm` — append 5 new message strings; update header `Public:` block.

### Library / framework requirements

**sjasmplus 1.23.0:**
- Already pinned by `Makefile`'s `check-toolchain` (Story 1.1). No new toolchain pin in this story.
- **Multi-pass assembly resolves forward references.** `src/dispatch.asm` references `MODE_*` / `VIS_CHAR` / `BDOS_EXIT` / `BDOS_CALL` / `mode_byte` / `visual_submode` / `msg_*` / `status_set_message` — all defined in `inc/*.inc` / `src/statusln.asm`, INCLUDEd before `dispatch.asm` in `src/vibe.asm` (per AR25). The forward-reference to `unbound_*` from inside `dispatch_*` tables is fine — same-file forward refs resolve in the second pass.
- **`DEFW` emits 16-bit little-endian.** Z80 / sjasmplus convention. Mode-table entries `DEFB key : DEFW handler_addr` lay out as 1 byte + 2 bytes (low, high). The dispatch-key load `LD E, (HL); INC HL; LD D, (HL)` matches this byte order.
- **Conditional assembly (`IFDEF`, `IFNDEF`) is supported but not needed for Story 1.9.** No conditional code paths.
- **`MACRO ... ENDM` defines macros; `BDOS_CALL` is the only macro Story 1.9 expands.** Pure code module otherwise.

**iz-cpm:**
- Used for the three new headless tests (`make -C test test`). All three tests are pure-state logic; no BIOS_CONIN / BIOS_CONINST / BIOS_TICK_ADDR access. iz-cpm's full BDOS function 9 / function 0 emulation is exercised by the prologue/epilogue (CALL 0x0005); the test bodies don't rely on BDOS or BIOS for anything beyond the harness exit.
- `iz-cpm` runs each `.com` with a 5-second timeout (`test/Makefile` line 109). Even a runaway dispatch-loop bug (e.g., binary-search stuck on equal lo/hi) would terminate within 5 s.

**CP/M 2.2 BDOS:**
- The only Story 1.9 BDOS use is `BDOS_CALL BDOS_EXIT` in `mode_debug_quit`. Per `inc/bdos.inc` line 35, BDOS_EXIT (function 0) warm-boots back to CCP. No other BDOS calls in `src/dispatch.asm`.
- The macro expansion guarantees the rc-check is automatic — but BDOS function 0 never returns on a real CP/M host, so the `JP M, bdos_error_funnel` after the CALL is unreachable. The defensive `RET` after `BDOS_CALL BDOS_EXIT` in `mode_debug_quit` is the documented safety net.

**MicroBeast BIOS:**
- NOT called by `src/dispatch.asm` (AR13). The BIOS is reached only via `src/render.asm` (Story 1.11) and `src/input.asm` (Story 1.8); dispatch sits between them in the data flow and never emits or polls.

### Previous story intelligence (Stories 1.1-1.8)

**From Story 1.1:**
- `make` from project root produces `vibe.com` deterministically. Adding `src/dispatch.asm` and 5 new strings in `src/statusln.asm` shifts the layout but preserves byte-determinism (NFR18). AC13 verifies.

**From Story 1.2:**
- `inc/modes.inc` declares `MODE_NORMAL/INSERT/COMMAND/VISUAL` (lines 23-26), `VIS_CHAR/LINE/BLOCK` (lines 29-31), `KEY_ARROW_*` (lines 39-42). Story 1.9 reads all of these by symbol.
- `inc/equates.inc` line 50 declares `ESC_TIMEOUT_TICKS` — not directly used by Story 1.9 but documents the pattern (knobs in equates.inc, mode-IDs in modes.inc).

**From Story 1.3:**
- `inc/state.inc` declares `mode_byte` (line 45), `visual_submode` (line 47), `status_dirty` (line 55), and the rest. Story 1.9 reads `mode_byte` and `visual_submode` by symbol; no layout changes.
- **Mode-state protocol is undocumented at the inc/state.inc level (per `_bmad-output/implementation-artifacts/deferred-work.md` line 18).** That deferral expects Story 1.9 / 1.10 to document the relationship between `pending_operator`, `pending_motion_prefix`, `visual_submode`, and `count_accumulator`. For Story 1.9, the only relationship dispatch establishes is "`mode_byte` = MODE_VISUAL implies `visual_submode` is one of `VIS_CHAR/LINE/BLOCK`". Story 1.10 (parser) is the natural location for the count/operator/prefix axes. A short comment block at the top of `src/dispatch.asm` would be a reasonable place to capture the mode-byte / visual_submode coupling — optional, but addresses one third of the deferral.

**From Story 1.4:**
- `inc/bdos.inc` lines 83-88 define the `BDOS_CALL` macro (the AR15 gateway). Story 1.9's `mode_debug_quit` is the second production caller (after Story 1.4's own placeholder testing). The macro's `JP M, bdos_error_funnel` resolves to the body in `src/statusln.asm` (line 127, declared in Story 1.5).

**From Story 1.5:**
- `src/statusln.asm` is the AR12 / MC5 funnel. `status_set_message` (lines 74-96) takes `HL = msg ptr, A = code (zero for non-error)`, copies into status_buffer, sets status_dirty, returns. Story 1.9's mode-change handlers and unbound handlers are textbook callers.
- Message-string conventions: lowercase, no period, under 30 chars (AR16). Story 1.9 adds 5 new strings following this rule.
- `bdos_error_funnel` (lines 127-133) JPs to `input_loop` after writing `msg_bdos_error`. Story 1.9 doesn't add any new `BDOS_CALL` sites that could fail (BDOS_EXIT never returns on a sign-bit rc; the macro's JP M is unreachable on EXIT).

**From Story 1.6:**
- `make test` from project root runs the headless harness; `test/Makefile` greps stdout for `\bPASS\b` / `\bFAIL\b`. Each `.com` runs under iz-cpm with a 5-second timeout. Story 1.9 adds three new `dispatch_*` cases, all pure-state logic.
- The harness picks up `test/cases/*.asm` automatically via `wildcard cases/*.asm`. No `test/Makefile` edits required.
- `test/inc/test_input_loop_stub.inc` (Story 1.6) provides the local `input_loop:` symbol so tests INCLUDEing `src/statusln.asm` resolve `bdos_error_funnel`'s `JP input_loop`. Story 1.9's tests INCLUDE statusln.asm + dispatch.asm + the input_loop_stub + state.inc — same scaffold as the gapbuf tests.

**From Story 1.7:**
- `src/gapbuf.asm` (286 lines) is the prior-art module at the same architectural tier. Its file structure (header block + `;;` section dividers + per-routine 4-line `In:`/`Out:`/`Trashes:`/`Calls:` contracts + dotted-local labels) is the template for `src/dispatch.asm`.
- The `gapbuf.asm` header's `Public:` block enumerates every external symbol — Story 1.9 mirrors this for dispatch.asm.
- The AR14 grep (Story 1.7's AC11) is the prior art for Story 1.9's AC13 grep on `gapbuf_*` references.
- Story 1.7's `gapbuf_load` STUB pattern (returns `status_set_message msg_not_implemented`) is the prior art for Story 1.9's three Epic-1 stubs (`mode_full_refresh_stub`, `mode_search_prompt_stub`, optionally `unbound_insert` if you pick the message form).
- `test/cases/gapbuf_insert-empty.asm` (109 lines) is the cleanest prior-art test — mirror its shape (pre-ORG headers, `INCLUDE "../inc/test_prologue.inc"`, test body with sentinel-coded jumps to `test_fail`, `JP test_pass`, then `INCLUDE "../inc/test_epilogue.inc"`, then production INCLUDEs in AR25 order, then `INCLUDE "../inc/test_input_loop_stub.inc"`, then state.inc LAST).

**From Story 1.8:**
- `src/input.asm` (190 lines) is the most-recent prior-art module — closer in shape to `src/dispatch.asm` than `src/gapbuf.asm` (both are stateless w.r.t. their own routine state; both have a single primary public entry plus internal helpers). Mirror input.asm's header-block style for dispatch.asm.
- The "`vibe.asm` header `Dependencies:` line gets a new entry per story" pattern is established. Story 1.8 added `src/input.asm (Story 1.8)`; Story 1.9 adds `src/dispatch.asm (Story 1.9)` alongside.
- The "INCLUDE goes in AR25 order, slotting into the next-available position" pattern is established. Story 1.8 inserted input.asm between the RET stub and statusln.asm; Story 1.9 inserts dispatch.asm between gapbuf.asm and the input_loop comment block.
- Story 1.8 deferred 4 items to Story 1.12 (uninit `input_held_*`, Esc-Esc-Arrow queue bypass, `tick_wait_one` ISR-not-armed hang, unconditional EI) — none impact Story 1.9. dispatch_key has no BIOS or tick dependencies; `mode_debug_quit`'s `BDOS_CALL BDOS_EXIT` doesn't depend on BIOS state.
- **The `input_get_key` → `dispatch_key` wiring is NOT this story's job.** Story 1.12 (init/teardown + on-hardware smoke test) wires the loop body. Story 1.9 just lands `dispatch_key` and the four mode tables.

### Git intelligence

Eight commits on `main` after Story 1.0 (most-recent first per `git log`):

- `5f5577e` — story 1.8: Wrote the input layer; tells Esc from arrows in ~40ms, with putback.
- `11a4560` — story 1.7: Wrote the gap buffer (insert, delete, move, load stub) with headless tests.
- `42af237` — story 1.6: make test builds, runs, and grades every test case off stdout.
- `b7ca9a8` — story 1.4: every BDOS call now goes through a macro that catches errors.
- `a298547` — story 1.3: Laid out the editor's full memory map at fixed addresses, build-time guarded.
- `eac5ba3` — story 1.2: Named every constant the editor needs, in three .inc headers, wired in.
- *(commit reflecting 1.5)* — story 1.5: every status message now goes through one funnel.
- `b561c9e` — story 1.1: Set up the VIBE build: Makefile pins sjasmplus 1.23.0, produces vibe.com.

Conventions visible in the tree (preserve in Story 1.9):
- 4-space indentation, UPPERCASE mnemonics, `;` line / `;;` section comments (AR24).
- AR23 header blocks on every `.asm` and `.inc` file. The new `src/dispatch.asm` follows the same shape.
- Every public routine and internal helper has the `In:` / `Out:` / `Trashes:` / `Calls:` four-line contract (AR23).
- One story per commit; short imperative subject + colon-separated context. Match the user's plain-English style.

Suggested commit message for Story 1.9 (when the dev finishes): `story 1.9: mode dispatch with sparse-table binary search; per-mode unbound handlers; mode-change stubs.` Match the user's "tells Esc from arrows" / "Wrote the gap buffer" plain-English style.

### Testing requirements

Story 1.9's testing requirements split into two categories:

**Build-time / static (verifiable in this story):**

1. `make` from project root succeeds (AC13).
2. `make clean && make` produces byte-identical `vibe.com` across two consecutive runs (NFR18 / AC13). Capture both SHAs in Debug Log References.
3. `grep -nE 'BIOS_CONOUT' src/dispatch.asm` returns zero matches (AR13 / AC13).
4. `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/dispatch.asm` returns zero matches (AR15 / AC13).
5. `grep -nE 'gapbuf_(insert|delete|move_gap|load|init)' src/dispatch.asm` returns zero matches (AR14 / AC13).
6. `make -C test test` reports 10 pass / 1 fail (AC11). Capture verbatim in Debug Log References.

**Headless test cases (this story):**

7. `dispatch_binary-search-finds-key.asm` — binary search finds every key in a synthetic sorted table (leftmost, rightmost, middle).
8. `dispatch_binary-search-misses.asm` — binary search misses route to the per-table unbound handler (below leftmost, above rightmost, gap key).
9. `dispatch_mode-transition.asm` — every mode transition (Normal→Insert, Normal→Command, Normal→Visual, Esc→Normal from each) sets `mode_byte` correctly; visual entry sets `visual_submode = VIS_CHAR`.

**UAT (deferred to Story 1.12 hardware bring-up):**

10. End-to-end keystroke → dispatch → handler on real MicroBeast hardware (Story 1.12 wires the input loop). Pre-1.12, dispatch is exercised only by the headless tests; the production input_loop body is still Story 1.5's BDOS_EXIT stub.

### Project Structure Notes

After Story 1.9 the source tree is:

```
src/
├── vibe.asm        # Top-level (now INCLUDEs input.asm + statusln.asm + gapbuf.asm + dispatch.asm)
├── input.asm       # Story 1.8 (unchanged)
├── statusln.asm    # Story 1.5 (+ Story 1.7's msg_not_implemented + Story 1.9's mode/unbound msgs)
├── gapbuf.asm      # Story 1.7 (unchanged)
└── dispatch.asm    # Story 1.9 — NEW (dispatch_key + 4 mode tables + 4 unbound + 4 mode-change + 3 stubs)

inc/
├── equates.inc     # Story 1.2 (unchanged)
├── bios.inc        # Story 1.4 (unchanged)
├── bdos.inc        # Story 1.4 (unchanged — Story 1.9 reads BDOS_EXIT + BDOS_CALL macro)
├── modes.inc       # Story 1.2 (unchanged — Story 1.9 reads MODE_* + VIS_CHAR)
├── vt52.inc        # Story 1.2 (unchanged)
└── state.inc       # Story 1.3 (+ Story 1.8's input_held_*) — UNCHANGED in 1.9

test/
├── README.md
├── Makefile
├── inc/
│   ├── test_prologue.inc
│   ├── test_epilogue.inc
│   └── test_input_loop_stub.inc
├── cases/
│   ├── harness_pass.asm
│   ├── harness_fail.asm
│   ├── gapbuf_delete-at-bof.asm
│   ├── gapbuf_delete-mid.asm
│   ├── gapbuf_insert-empty.asm
│   ├── gapbuf_insert-fills-buffer.asm
│   ├── gapbuf_move-roundtrip.asm
│   ├── gapbuf_random-ops.asm
│   ├── dispatch_binary-search-finds-key.asm   # Story 1.9 — NEW
│   ├── dispatch_binary-search-misses.asm      # Story 1.9 — NEW
│   └── dispatch_mode-transition.asm           # Story 1.9 — NEW
├── fixtures/
│   └── hello.txt
└── smoke/
    ├── bdos_call_smoke.asm
    └── statusln_smoke.asm
```

Architecture's reference layout (architecture.md lines 1278-1339) anticipates exactly this — `src/dispatch.asm` between `src/render.asm` (Story 1.11) and `src/parser.asm` (Story 1.10). Since render.asm doesn't yet exist, dispatch.asm slots in immediately after gapbuf.asm in vibe.asm's INCLUDE chain. Story 1.10 (parser) lands next, then Story 1.11 (render), then Story 1.12 (init/teardown wires the loop).

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md] lines 609-660
- Adjacent story (parser, Story 1.10 — depends on dispatch's normal-mode entries for digits/operators/prefix): [Source: _bmad-output/planning-artifacts/epics.md] lines 662-720
- MC1 (caller-saved everywhere): [Source: _bmad-output/planning-artifacts/architecture.md] lines 472-476
- MC3 (sparse sorted dispatch tables + binary search): [Source: _bmad-output/planning-artifacts/architecture.md] lines 485-527
- MC4 (handler signature: A=key just consumed): [Source: _bmad-output/planning-artifacts/architecture.md] lines 529-533
- MC7 (static memory map via state.inc): [Source: _bmad-output/planning-artifacts/architecture.md] lines 550-555
- AR12 (single status-message funnel): [Source: _bmad-output/planning-artifacts/epics.md] line 161
- AR13 (single screen-emission path — render.asm only): [Source: _bmad-output/planning-artifacts/epics.md] line 162
- AR14 (single buffer-mutation owner — gapbuf.asm only): [Source: _bmad-output/planning-artifacts/epics.md] line 163
- AR15 (single BDOS gateway — BDOS_CALL macro): [Source: _bmad-output/planning-artifacts/epics.md] line 164
- AR16 (status-message string-table convention): [Source: _bmad-output/planning-artifacts/epics.md] line 165
- AR21 (headless coverage scope): [Source: _bmad-output/planning-artifacts/epics.md] line 173
- AR22 (naming): [Source: _bmad-output/planning-artifacts/epics.md] line 177
- AR23 (file structure and routine contracts): [Source: _bmad-output/planning-artifacts/epics.md] line 178
- AR24 (format conventions): [Source: _bmad-output/planning-artifacts/epics.md] line 179
- AR25 (module include order — `init → input → statusln → gapbuf → render → dispatch → parser → ...`): [Source: _bmad-output/planning-artifacts/epics.md] line 180, [Source: _bmad-output/planning-artifacts/architecture.md] lines 942-951
- FR12 (start in normal mode): [Source: _bmad-output/planning-artifacts/epics.md] line 37
- FR13 (enter insert via `i` etc.): [Source: _bmad-output/planning-artifacts/epics.md] line 38
- FR14 (enter command via `:`): [Source: _bmad-output/planning-artifacts/epics.md] line 39
- FR15 (enter visual via `v`): [Source: _bmad-output/planning-artifacts/epics.md] line 40
- FR16 (return to normal via Esc): [Source: _bmad-output/planning-artifacts/epics.md] line 41
- FR17 (mode in status line): [Source: _bmad-output/planning-artifacts/epics.md] line 42
- FR48 (Ctrl-L full refresh): [Source: _bmad-output/planning-artifacts/epics.md] line 94
- FR50 (unsupported command no-op + status feedback): [Source: _bmad-output/planning-artifacts/epics.md] line 99
- NFR2 (sustained typing): [Source: _bmad-output/planning-artifacts/epics.md] line 108
- NFR9 (code-size budget ~3 KB): [Source: _bmad-output/planning-artifacts/epics.md] line 121
- NFR16 (knob centralization): [Source: _bmad-output/planning-artifacts/epics.md] line 134
- NFR17 (mode/operator decoupling): [Source: _bmad-output/planning-artifacts/epics.md] line 135
- Module dependency graph (input → dispatch → parser/motions/edits/...): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1404-1432
- Data-flow keystroke lifecycle (step 4 = dispatch_key): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1466-1502
- Implementation sequence (dispatch is step 7, after input): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1572-1573
- inc/modes.inc MODE_* and KEY_ARROW_* equates: [Source: inc/modes.inc] lines 22-42
- inc/state.inc mode_byte / visual_submode declarations: [Source: inc/state.inc] lines 45-48
- inc/bdos.inc BDOS_EXIT and BDOS_CALL macro: [Source: inc/bdos.inc] lines 35, 83-88
- src/statusln.asm status_set_message contract + AR16 message conventions: [Source: src/statusln.asm] lines 51-96, 161-182
- src/input.asm prior-art module structure (header + helper + module-level register conventions): [Source: src/input.asm] lines 1-49
- src/gapbuf.asm AR14 single-mutator pattern: [Source: src/gapbuf.asm] lines 1-34
- test/cases/gapbuf_insert-empty.asm prior-art test shape: [Source: test/cases/gapbuf_insert-empty.asm] lines 1-115
- Story 1.8 dev-notes prior art (file shape + critical-traps style): [Source: _bmad-output/implementation-artifacts/1-8-input-layer-with-esc-arrow-disambiguation.md] lines 468-747
- Deferred-from-1.3: mode-state protocol undocumented (one third resolved here): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 18

## Dev Agent Record

### Agent Model Used

claude-opus-4-7 (Anthropic Claude Opus 4.7, 1M context)

### Debug Log References

**Build determinism (NFR18 / AC13):** two consecutive `make clean && make` runs:
```
a19c31e996383571bdbcde60ac5a70cda67924ca06ac9a96a50a5110d610b649  vibe.com
a19c31e996383571bdbcde60ac5a70cda67924ca06ac9a96a50a5110d610b649  vibe.com
```
Byte-identical SHA across rebuilds. `vibe.com` size: 806 bytes total (story 1.8 baseline ≈ 555 bytes; net +251 bytes for dispatch.asm + 5 new statusln strings — within the 200-430 byte estimate from NFR9 dev-notes).

**Test run (AC11):** `make -C test test`
```
  pass     dispatch_binary-search-finds-key
  pass     dispatch_binary-search-misses
  pass     dispatch_mode-transition
  pass     gapbuf_delete-at-bof
  pass     gapbuf_delete-mid
  pass     gapbuf_insert-empty
  pass     gapbuf_insert-fills-buffer
  pass     gapbuf_move-roundtrip
  pass     gapbuf_random-ops
  fail     harness_fail  (rc=0, output: FAIL E1 C0)
  pass     harness_pass

  10 pass, 1 fail
```
10 pass / 1 fail — the only `fail` is the deliberate `harness_fail` from Story 1.6. All three new `dispatch_*` cases pass.

**AR-grep enforcement (AC13):**
- AR13: `grep -nE 'BIOS_CONOUT' src/dispatch.asm` → zero matches (after the comment rephrase to "BIOS console-out vector").
- AR15: `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/dispatch.asm` → zero matches.
- AR14: `grep -nE 'gapbuf_(insert|delete|move_gap|load|init)' src/dispatch.asm` → zero matches.

### Completion Notes List

- `dispatch_key` implementation chose IX-cached entry-base + RET-to-pushed-address for both hit and miss paths (symmetric stack discipline). Per-iteration cost ≈ 150 T-states (3 PUSH/POP pairs around the offset compute + 3× 16-bit ADD); worst-case 6 iterations ≈ 1000 T-states ≈ 250 µs at 4 MHz — three orders of magnitude under any typing-perception threshold (NFR2). Documented the stack discipline in the routine's contract block.
- The architecture's sample dispatch_key (architecture lines 498-516) had two known issues called out in the dev notes (RET-Z on miss vs unbound fall-through; A-clobbered-before-key-saved). Both avoided in the implementation: A is stashed to C as the very first instruction, and miss routes to the per-mode unbound via RET-to-pushed.
- Mode-table layout pinned per Task 5: 2-byte unbound prefix + 3-byte (key, addr) entries sorted ascending by ASCII byte. dispatch_normal has 9 entries (29 bytes), dispatch_insert/command/visual each 1 entry (5 bytes). Total table footprint = 44 bytes, well under the 256-byte AC10 cap.
- 5 new strings added to `src/statusln.asm`: `msg_mode_normal` (empty — clears the indicator on entering normal mode, per vi convention), `msg_mode_insert` ("-- insert --"), `msg_mode_command` ("-- command --"), `msg_mode_visual` ("-- visual --"), `msg_unbound_key` ("unbound key"). All lowercase, no trailing period, under 30 chars (AR16).
- `unbound_insert` and `unbound_command` chose the silent-RET stub form (over the `status_set_message msg_not_implemented` variant) per the AC5/AC6 latitude — silent feels less noisy when held-down keys in INSERT mode (Story 2.8's eventual home for literal-byte insertion) would otherwise spam the status line.
- `mode_debug_quit` (Ctrl-Q) routes through `BDOS_CALL BDOS_EXIT` per AR15. The trailing `RET` is defensive — BDOS function 0 never returns on a real CP/M host, but a misconfigured BIOS during Story 1.12 hardware bring-up could in principle let it through. Removed when Story 2.1 lands `:q` / `:q!`.
- AR25 INCLUDE order: `dispatch.asm` slotted between `gapbuf.asm` and the `input_loop:` divider in `src/vibe.asm`. When Story 1.11 lands `render.asm`, it slots in BEFORE `dispatch.asm` (the AR25 chain is `init → input → statusln → gapbuf → render → dispatch → parser → ...`).
- One third of Story 1.3's deferred mode-state-protocol documentation captured at the top of `src/dispatch.asm`'s header block: "MODE_VISUAL value in mode_byte ALWAYS implies visual_submode is one of VIS_CHAR / VIS_LINE / VIS_BLOCK". The count/operator/prefix axes remain Story 1.10's natural home.
- No new fields in `inc/state.inc` — story 1.9 reads `mode_byte` and `visual_submode` only (both declared at lines 45-47 since Story 1.3).

### File List

**Created:**
- `src/dispatch.asm` (mode dispatcher: dispatch_key + 4 mode tables + 4 mode-change handlers + 3 Epic-1 stubs + 4 unbound handlers)
- `test/cases/dispatch_binary-search-finds-key.asm` (AC11: hit-path coverage; 5-entry synthetic table; leftmost / middle / rightmost edge cases)
- `test/cases/dispatch_binary-search-misses.asm` (AC11: miss-path coverage; below leftmost / 3 gap positions / above rightmost)
- `test/cases/dispatch_mode-transition.asm` (AC11/7/8/9: NORMAL ↔ INSERT, NORMAL ↔ COMMAND, NORMAL ↔ VISUAL via production tables; verifies visual_submode = VIS_CHAR on visual entry)

**Modified:**
- `src/vibe.asm` — added `INCLUDE "dispatch.asm"` between gapbuf and the input_loop divider; appended `src/dispatch.asm (Story 1.9)` to the header `Dependencies:` line. Did NOT touch the `input_loop:` body or its abort-target comment block (Story 1.12 owns).
- `src/statusln.asm` — appended 5 new message strings (msg_mode_normal/insert/command/visual + msg_unbound_key) per AR16; updated header `Public:` block to enumerate them.

**Unchanged (verified):** `inc/equates.inc`, `inc/bios.inc`, `inc/bdos.inc`, `inc/modes.inc`, `inc/vt52.inc`, `inc/state.inc`, `src/input.asm`, `src/gapbuf.asm`, `Makefile`, `test/Makefile`.

### Review Findings

Code review on 2026-05-10. Layers run: Blind Hunter, Edge Case Hunter, Acceptance Auditor. All 14 ACs PASS per Auditor; build is byte-identical across two clean rebuilds (`a19c31e9…`); 10 pass / 1 fail with the sole fail being the deliberate `harness_fail`; AR13/AR14/AR15 source-level greps clean.

- [x] [Review][Patch] Comment claims 'X' subtest is 2 iterations; actual binary search on [A,C,M,X,Z] is 3 iterations [test/cases/dispatch_binary-search-finds-key.asm:85] — From mid='M'(2): 'M'<'X' → lo=3; mid=4('Z')>'X' → hi=4; mid=3('X') hit. Fixed: comment now reads "(3 iterations: M→Z→X)".
- [x] [Review][Patch] Sort-order build-time ASSERTs added to `dispatch_normal` [src/dispatch.asm:489-531] — 8 inline `ASSERT key_n > key_n_minus_1` lines now guard the ascending-key invariant at assembly time. A swap-typo (e.g. 'i' ↔ 'a') would now fail sjasmplus immediately. ASSERTs emit no bytes; SHA unchanged. (Originally deferred citing AC10-optional; user override — cheap fix, real regression vector.)
- [x] [Review][Patch] Production-table hit coverage added [test/cases/dispatch_mode-transition.asm steps 7-9] — three new subtests dispatching Ctrl-L (0x0C — leftmost entry), '/' (mid-table) and 'a' (duplicate-handler entry that would otherwise be swap-invisible against 'i') on the production `dispatch_normal` table. Ctrl-L and '/' verify `status_dirty` got set by their stub handlers; 'a' verifies `mode_byte` transitions to `MODE_INSERT`. Ctrl-Q remains untested (would BDOS_EXIT the test harness); 'O' / 'o' covered transitively by 'a' since all three duplicate the same handler. (Originally deferred citing "stub handlers add no distinct code path"; user override.)
- [x] [Review][Patch] `visual_submode` preservation across Esc-from-VISUAL added [test/cases/dispatch_mode-transition.asm step 6b] — one assertion confirming `visual_submode == VIS_CHAR` after step 6's Esc-from-VISUAL, guarding the documented invariant at src/dispatch.asm:16-21. (Originally deferred citing "over-specification"; user override — the invariant IS documented, so the test guards documented behaviour.)

Dismissed as noise (recorded for the next reviewer's context):
- Blind Hunter "stale `B = mid` on handler entry": silence in MC4 contract is intentional discipline — handlers should not depend on B post-dispatch.
- Blind Hunter "empty `msg_mode_normal` relies on unseen statusln semantics": verified at src/statusln.asm:81-82 — null at byte 0 jumps to `.pad_loop`, padding the full 80-byte buffer. Correct as documented.
- Blind Hunter "`mode_debug_quit`'s defensive RET assumes SP intact": the comment's own framing already conditions on SP integrity; no additional bug.
- Edge Case Hunter "miss test omits key=0x00 and key=0xFF": same unsigned-byte algorithm path as any other below/above-range key; no distinct branch.
- Acceptance Auditor "per-iteration T-state figure understated (~150 → ~200)": narrative correction in the dev's Completion Notes, not in source under review; NFR2 conclusion (three orders of magnitude under perceptible) holds either way.

## Change Log

| Date | Description |
|---|---|
| 2026-05-10 | Story implementation complete via bmad-dev-story workflow. Created src/dispatch.asm (dispatch_key with IX-cached + RET-to-pushed binary search; 4 mode tables totalling 44 bytes; 4 mode-change handlers; 3 Epic-1 stubs; 4 unbound handlers). Appended 5 message strings to src/statusln.asm. Wired INCLUDE "dispatch.asm" into src/vibe.asm per AR25. Added 3 headless tests (binary-search-finds-key, binary-search-misses, mode-transition); 10 pass / 1 fail (the only fail is the deliberate harness_fail). Two consecutive `make clean && make` runs produce byte-identical vibe.com (806 bytes; SHA a19c31e9...). AR13/AR14/AR15 source-level greps return zero matches in src/dispatch.asm. Status: review. |
| 2026-05-10 | Story created via bmad-create-story workflow. Comprehensive context engine analysis: epic foundation extracted from epics.md lines 609-660; architecture compliance table covers MC1/MC3/MC4/MC7 + AR6/10/12/13/14/15/16/21/22/23/24/25 + NFR1/2/9/10/16/17/18; existing-files audit confirms NO state.inc changes (mode_byte / visual_submode already present from Story 1.3); 5 new message strings added to statusln.asm per AR16; recommended dispatch_key implementation uses RET-to-pushed-addr idiom for unbound fall-through; mode-table layout convention pinned (2-byte unbound prefix + sorted entries); 9 entries pinned for dispatch_normal in ASCII-byte ascending order with sentinel handlers identified per AC7; three headless tests scoped (binary-search-finds-key, binary-search-misses, mode-transition); status set to ready-for-dev. |
| 2026-05-10 | Code review (bmad-code-review) complete. All 14 ACs PASS per Acceptance Auditor; 10 pass / 1 fail (sole fail = deliberate harness_fail); byte-identical rebuilds confirmed (a19c31e9...). 4 patches applied: (1) narration-comment fix in dispatch_binary-search-finds-key.asm:85; (2) 8 sort-order ASSERTs guarding dispatch_normal's ascending-key invariant; (3) Ctrl-L / '/' / 'a' subtests added to dispatch_mode-transition.asm exercising production-table dispatch routing; (4) visual_submode preservation assertion in step 6b of mode-transition. 5 findings dismissed as noise. Status: done. |
