# Story 1.11: Render pipeline with dirty rows, scroll, Ctrl-L

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As the VIBE author,
I want `src/render.asm` exposing `render_diff` (per-row dirty bitmap + cell-by-cell shadow compare) and `render_full` (Ctrl-L), plus scroll behavior anchored at `top_line_offset`,
so that NFR1 (incremental render), NFR3 (cursor latency), NFR7 (screen-state recoverability), FR47 (diff render), FR48 (Ctrl-L full refresh), and V2 (scroll mechanism) are realized at the substrate level — and the AR13 single-screen-emission rule is finally backed by a module that actually emits bytes.

## Acceptance Criteria

1. **Module header.**
   **Given** `src/render.asm` module header
   **When** I inspect it
   **Then** it documents `Public: render_init, render_diff, render_full, render_mark_row_dirty, render_mark_all_dirty`
   **And** `State owned (read/write): shadow_buffer, dirty_rows, top_line_offset` (declared in `inc/state.inc` since Story 1.3 — no new state.inc fields in this story)
   **And** State `read-only`: `status_buffer` (read for status-row emit), `status_dirty` (read + cleared after status emit — exclusively by render.asm, AR12 read-side; the WRITE-side stays with `status_set_message` in statusln.asm), `cursor_offset`, `gap_start`, `gap_end` (gap-buffer two-halves walk for cell content)
   **And** register conventions across public entry points
   **And** dependencies on `inc/equates.inc`, `inc/state.inc`, `inc/bios.inc`, `inc/vt52.inc`, `src/statusln.asm` (only for the message-string section's co-located AR16 conventions — no public-symbol calls into statusln.asm from render.asm; the status-row emit reads `status_buffer` / `status_dirty` directly via state.inc symbols)
   **And** the AR13 carve-out is updated: render.asm is the ONLY module containing `BIOS_CONOUT` references in production code (init.asm's "initial clear" exception listed in architecture line 162 is folded into `render_init` here — no separate `ESC J` site exists outside render.asm post-1.11).

2. **`render_init` — initial-state setup.**
   **Given** `render_init` (`In: (none)`)
   **When** invoked at startup (from Story 1.12's `init_cold_start`)
   **Then** the screen is cleared by emitting a single `ESC J` (`VT52_ESC` then `VT52_CLEAR_SCREEN` — two `BIOS_CONOUT` writes via the `C = byte ; CALL BIOS_CONOUT` shape)
   **And** `shadow_buffer` is filled with `0x20` (ASCII space) across all `SCREEN_ROWS * SCREEN_COLS` = 1920 bytes
   **And** `dirty_rows` is zeroed (all 3 bytes = 0)
   **And** `top_line_offset` is zeroed (2 bytes = 0x0000)
   **And** the cursor is positioned at row 0 / col 0 (one `ESC Y (0+VT52_COORD_BIAS) (0+VT52_COORD_BIAS)` emit) to give the rest of the system a known cursor state
   **And** `status_dirty` is NOT cleared by `render_init` (it may have been set by a pre-render `status_set_message` call; the first `render_diff` after init must still pick it up).

3. **`render_full` — full-redraw path (FR48, NFR7, Ctrl-L).**
   **Given** `render_full` (`In: (none)`)
   **When** invoked (by the Ctrl-L handler in dispatch.asm, or by Story 1.12's `init_cold_start` for the initial draw)
   **Then** `render_mark_all_dirty` is invoked first (all 24 row bits in `dirty_rows` set)
   **And** `render_diff` is invoked next (which walks the now-all-dirty bitmap, re-emits every cell that differs from shadow, clears `dirty_rows`, emits status row if dirty, repositions cursor)
   **And** post-call: `shadow_buffer` is fully reconciled with the emitted content (every visible cell on screen matches its `shadow_buffer` byte); `dirty_rows` is cleared; cursor position has been re-emitted (RI4 defensive policy).

4. **`render_diff` — normal-frame path (FR47, NFR1, NFR3, V2).**
   **Given** `render_diff` (`In: (none)`)
   **When** invoked at the end of an input-loop iteration (Story 1.12 wires this — pre-1.12 it is exercised only by the headless tests)
   **Then** the pass executes the following stages in order:
     1. **Scroll adjustment (V2).** Compute the logical row of `cursor_offset` relative to `top_line_offset` by counting `0x0A` (LF) bytes from `top_line_offset` toward `cursor_offset`. If the cursor lands in a row outside `[0, EDITABLE_ROWS-1]` (i.e. rows 0..22), advance `top_line_offset` forward (by walking line-break starts) until the cursor's logical row falls back into `[0, EDITABLE_ROWS-1]`; mark ALL editable rows dirty (`render_mark_all_dirty` minus the status-row bit — or equivalently, set bits 0..22) so the post-scroll content re-emits.
        - For the V2-mvp, the "retreat" direction (cursor moved up off the top of the visible area) pins `top_line_offset` to the start of the cursor's containing line — cursor lands on row 0 of the visible window regardless of how far it retreated. (This is asymmetric with the advance direction, which lands the cursor at row `EDITABLE_ROWS-1`; the asymmetry is deliberate for the MVP — the row-0-pin is simpler and the visible behaviour matches a "jump to cursor" mental model. A symmetric minimal-retreat that preserves above-cursor context is deferred until visual / motion stories make context-preservation desirable.) Mark all editable rows dirty.
        - The walk is bounded by `EDITABLE_ROWS * SCREEN_COLS` ≈ 1840 byte reads per scroll-affecting frame (W2 — sub-perceptible at 4 MHz).
     2. **Editable-row emit (FR47 + NFR1).** For each dirty row `r` in `[0, EDITABLE_ROWS-1]` (= 0..22) with its bit set in `dirty_rows`:
        - Compute the logical buffer offset of row `r`'s first character: starting from `top_line_offset`, walk forward over `r` newlines.
        - For each cell `c` in `[0, SCREEN_COLS-1]` (= 0..79), compute the target character: the byte at logical offset (row-start + c) if that offset is still inside row `r` (before the next `0x0A` or before end-of-buffer); otherwise `0x20` (space-pad short lines and past-EOF rows).
        - Compare target vs `shadow_buffer[r * SCREEN_COLS + c]`. Within the row, identify **contiguous runs** of cells where target ≠ shadow. Each run starts a fresh emit: one `ESC Y (r+VT52_COORD_BIAS) (run_start_col+VT52_COORD_BIAS)` followed by the run's target bytes, character by character.
        - As bytes are emitted, update `shadow_buffer` to match. Post-row, the row's `shadow_buffer` slice matches what's now on screen.
     3. **Status-row emit (FR49 + AR12 read-side).** If `(status_dirty) != 0`:
        - Walk `status_buffer` (80 bytes, owned by statusln.asm, populated by `status_set_message`).
        - For each col in `[0, SCREEN_COLS-1]`, compare against `shadow_buffer[STATUS_ROW * SCREEN_COLS + c]` (= `shadow_buffer[23 * 80 + c]`).
        - Emit contiguous-run `ESC Y (STATUS_ROW+VT52_COORD_BIAS) (col+VT52_COORD_BIAS)` + run bytes, updating shadow.
        - Set `status_dirty = 0` after the row is emitted (or immediately, before the emit; ordering is not user-observable since render runs to completion before the next input).
        - Note: the status-row emit is GATED by `status_dirty` — it does NOT consult the row-23 bit in `dirty_rows`. The two dirty-tracking surfaces are deliberately separate (rationale: status changes asynchronously via `status_set_message`; mixing it into `dirty_rows` would require every `status_set_message` caller to also call `render_mark_row_dirty 23`, which is exactly the kind of caller-side discipline AR12's funnel was built to avoid).
     4. **Dirty-rows clear.** `dirty_rows` is zeroed (3 bytes) after the row-emit pass.
     5. **Cursor reposition (RI4).** A final `ESC Y (cursor_row+VT52_COORD_BIAS) (cursor_col+VT52_COORD_BIAS)` is emitted as the LAST bytes of the frame — even if no cells changed, even if no rows were dirty, even if status was not dirty. Rationale: RI4 defensive policy — re-emit cursor position every frame so cursor desync alone never compounds. `cursor_row` is the row index computed during scroll-adjustment (step 1); `cursor_col` is `cursor_offset - row_start_offset` clamped at `SCREEN_COLS-1`.

5. **Cursor row/col computation — bounded cost (W2, NFR3).**
   **Given** the cursor-row-recompute path
   **When** the renderer walks line breaks from `top_line_offset`
   **Then** the maximum byte-scan cost per `render_diff` invocation is bounded by `EDITABLE_ROWS * SCREEN_COLS` = 1840 bytes
   **And** the architecture's W2 (architecture lines 1640-1642) is realized: cursor row/col recompute is sub-perceptible, NFR3 holds.

6. **`render_mark_row_dirty` — set one bit (`In: A = row 0..23`).**
   **Given** `render_mark_row_dirty` (`In: A = row 0..23`)
   **When** invoked
   **Then** if `A >= SCREEN_ROWS` (i.e. 24+), the routine returns without writing (defensive clamp — out-of-range row indices silently ignored; no crash, no buffer overrun into adjacent state)
   **And** otherwise the corresponding bit `1 << (A mod 8)` is set in `dirty_rows[A / 8]` via OR-with-mask (existing bits preserved — sets only, never clears)
   **And** no other state is touched (`top_line_offset`, `shadow_buffer`, `status_dirty` all unchanged; no BIOS calls; no status_set_message — this is a pure-memory operation per MC1).

7. **`render_mark_all_dirty` — set all 24 row bits.**
   **Given** `render_mark_all_dirty` (`In: (none)`)
   **When** invoked
   **Then** all 24 row bits are set in `dirty_rows` (= 0xFF, 0xFF, 0xFF — the 3-byte bitmap, with the unused bits 24..31 of byte 2 also set; the unused bits are inert because the row-emit walk only iterates rows 0..23)
   **And** no other state is touched (same caller-saved purity as `render_mark_row_dirty`).

8. **Ctrl-L from the user routes to `render_full` (FR48, NFR7).**
   **Given** Ctrl-L (0x0C) arrives at `dispatch_normal` in NORMAL mode
   **When** dispatched
   **Then** the `mode_full_refresh_stub` placeholder in `src/dispatch.asm` (introduced by Story 1.9 as `LD HL, msg_not_implemented / XOR A / CALL status_set_message / RET`) is REPLACED by a real handler that:
     - `CALL render_full`
     - `RET` (or `JP render_full` tail-form for the same effect, 1 byte cheaper)
   **And** the handler's contract block documents `In: A = 0x0C (MC4); Out: screen fully redrawn from buffer state; Trashes: A, BC, DE, HL, IX, F (render_full's transitive clobber); Calls: render_full`
   **And** dispatch.asm's `Dependencies:` header line gains `src/render.asm (Story 1.11 — render_full)`
   **And** the dispatch_normal table entry for 0x0C now references `render_full` directly (or the renamed `mode_full_refresh_stub` is repurposed as a thin wrapper — implementation choice; the table contents and ordering are unchanged).
   **Note:** Story 1.12's main loop will follow up every dispatch_key handler with a `render_diff` call. Since `render_full` clears `dirty_rows` on completion, the post-handler `render_diff` is a no-op (no rows dirty + cursor still positioned + status not re-dirtied) — no double-render.

9. **Status-row emit replaces the Story 1.5 `status_render` stub.**
   **Given** `src/statusln.asm` line 151 currently contains a Story-1.5 `status_render:` stub that clears `status_dirty` and returns without emitting any bytes
   **When** I inspect `src/statusln.asm` after Story 1.11
   **Then** EITHER (a) `status_render` is removed entirely from statusln.asm (Public list shortens, the Story-1.5 STUB comment block is excised, and the file's responsibilities pin firmly at "owns the WRITE path to status_buffer + status_dirty; render.asm owns the READ/EMIT path"); OR (b) `status_render` becomes a thin trampoline `JP <render.asm-internal-status-emit>` preserving the public symbol for any future external caller (none today).
   **And** option (a) is the recommended default: there are no current production or test callers of `status_render` (grep `status_render` across `src/` and `test/cases/` returns only the declaration + stub in statusln.asm itself, plus comments in `src/vibe.asm` and `_bmad-output/`). Option (b) is acceptable if the dev judges the no-call-site coupling worth preserving for the public-surface stability.
   **And** the statusln.asm header `Public:` block is updated to reflect the choice; the `Dependencies:` line is unchanged (render.asm reads from state.inc symbols, not from statusln.asm-exported routines).

10. **AR13 — single screen-emission path enforced by grep.**
    **Given** the architecture rule AR13: only `render.asm` calls `BIOS_CONOUT`
    **When** I run `grep -nE 'BIOS_CONOUT' src/*.asm` from project root
    **Then** the ONLY matches are inside `src/render.asm` (the four-or-so emit sites: cell-byte emit, ESC-Y emit, ESC J init emit, cursor-reposition emit — all collapsed into a small internal helper, e.g. `render_emit_byte`)
    **And** `grep -nE 'BIOS_CONOUT' src/init.asm` returns zero matches when init.asm lands in Story 1.12 (init.asm calls `render_init` and `render_full`; the initial-clear `ESC J` lives inside `render_init`, not in init.asm). The architecture line 162's "init's initial clear is the only declared exception" is RETIRED by this story — the exception was a hedge in case render and init had to share emit responsibilities; in practice render.asm subsumes the init-clear cleanly via `render_init`.
    **And** `grep -nE 'BIOS_CONOUT' src/statusln.asm` returns zero matches (the Story-1.5 stub never called BIOS_CONOUT; the new architecture has render.asm read status_buffer/status_dirty and emit, so statusln.asm stays BIOS-clean — AR12 holds on the write side, AR13 holds on the emit side, no contradiction).

11. **AR15 — no BDOS from render.asm.**
    **Given** the architecture rule AR15: every BDOS call via `BDOS_CALL` macro; raw `CALL 0x0005` forbidden
    **When** I run `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY|BDOS_CALL' src/render.asm`
    **Then** zero matches (render.asm never invokes BDOS — it speaks only to BIOS_CONOUT and to memory; FCB / file ops are fileio.asm's job in Epic 2).

12. **AR14 — no gap-buffer mutation from render.asm.**
    **Given** the architecture rule AR14: only `gapbuf.asm` mutates the gap buffer via `gapbuf_insert/delete/move_gap`
    **When** I run `grep -nE 'gapbuf_(insert|delete|move_gap|init|load)' src/render.asm`
    **Then** zero matches (render.asm READS gap_start / gap_end / cursor_offset to walk the two-halves for cell content; it never CALLS the mutating primitives).

13. **AR16 — message-string discipline preserved.**
    **Given** the architecture rule AR16: status messages lowercase, no trailing period, under 30 chars
    **When** I inspect render.asm
    **Then** zero new message strings are added by this story (render.asm does NOT call `status_set_message`; it reads `status_buffer` to emit but does not author messages — that stays in statusln.asm per AR12).

14. **VT52_GOTO row/col clamp (Story 1.2 deferred work resolution).**
    **Given** the Story 1.2 deferral logged in `deferred-work.md` line 11: "VT52_GOTO row/col clamp must land in render path. Out-of-range coordinates (row ≥ SCREEN_ROWS, col ≥ SCREEN_COLS) emit garbage bytes after the bias and corrupt the VT52 state machine"
    **When** render.asm composes any `ESC Y row col` sequence
    **Then** `row` is clamped to `[0, SCREEN_ROWS-1]` (`MIN(row, SCREEN_ROWS-1)`) and `col` is clamped to `[0, SCREEN_COLS-1]` before the `VT52_COORD_BIAS` (= 0x20) is added — the bias-add never produces a byte outside the VT52's printable-ASCII bias range
    **And** the clamp lives in a single internal helper (e.g. `render_emit_goto`) that takes raw row/col in A/C (or similar) and emits the full 4-byte `ESC Y row+bias col+bias` sequence — no clamp site is duplicated across emit call sites
    **And** the dev-notes Implementation section pins this as the resolution of the Story-1.2 deferral (with a corresponding entry in `deferred-work.md` Story-1.11 follow-up section marking it resolved, OR a reference from this story's File List).

15. **Shadow_buffer page-alignment decision (Story 1.3 deferred work resolution).**
    **Given** the Story 1.3 deferral logged in `deferred-work.md` line 17: "No alignment / page-crossing consideration for shadow_buffer. A page-aligned shadow_buffer enables an H = row + base_high render fast-path; the current layout makes no attempt to pad. Whether the win justifies the slack belongs to the render pipeline story (1.11) where indexing strategy is decided"
    **When** I inspect `inc/state.inc` and `src/render.asm` after Story 1.11
    **Then** the recommended default is **no padding** — `shadow_buffer` stays in its current Story-1.3 layout slot (immediately after `filename_buffer`, no alignment slack). The indexing math is `addr = shadow_buffer + row * SCREEN_COLS + col`, computed via `LD H, 0 / LD L, A / ADD HL, HL` (×16) + ADD HL, HL (×32) + ADD HL, HL (×64) + ADD HL, HL_save (×80) idiom — ~14 T-states per row, sub-perceptible at frame rate. The H = row + base_high fast-path would save those T-states but would force `state.inc` to insert up to 255 bytes of slack between `filename_buffer` and `shadow_buffer` to align the start of shadow_buffer onto a 256-byte page boundary. That slack overlaps the GAP_BUFFER_BASE math (which is positional and would shift), and crowds the yank_end vs 0xD800 budget. Decision: defer fast-path indexing to a future profiling-driven story; keep `state.inc` as-is.
    **And** the decision is pinned in the render.asm header (one-line note in Purpose or Dependencies) and in the dev-notes Project Structure section. `deferred-work.md`'s Story-1.3 entry on alignment is marked resolved with this decision as the resolution.

16. **Headless tests pass (AR21).**
    **Given** five headless tests under `test/cases/render_*.asm` exercising render math against synthetic gap-buffer states + synthetic shadow_buffer states + a BIOS_CONOUT capture stub
    **When** I run `make test` from project root
    **Then** the following five new tests pass:
    - `render_diff-no-changes.asm` — empty gap buffer, shadow matches (all spaces), no dirty rows → `render_diff` emits ONLY the trailing cursor-reposition (≈4 bytes); zero content bytes (NFR1 idle = no emission validation; the trailing cursor ESC Y is the RI4-acceptable defensive overhead).
    - `render_diff-single-row-change.asm` — buffer has "hello" on row 0; shadow row 0 is all spaces; `dirty_rows[0] |= 0x01`. `render_diff` emits one `ESC Y 0x20 0x20` (= ESC Y for row 0 col 0) followed by "hello" + cursor-reposition. Post-call: `dirty_rows = 0`; `shadow_buffer[0..4] = "hello"`; `shadow_buffer[5..79] = spaces`.
    - `render_diff-contiguous-runs.asm` — row 0 has "ab" at cols 0..1 AND "xy" at cols 10..11; shadow row 0 is all spaces; row 0 dirty. `render_diff` emits TWO separate `ESC Y` sequences (one for run at col 0, one for run at col 10) — NOT a single long run with mid-stream skip. Post-call: shadow reflects both runs; cols 2..9 stay spaces.
    - `render_full-marks-all-dirty.asm` — set dirty_rows = 0; call `render_full`. Verify all 24 row bits are set BEFORE the diff pass runs (test instruments the boundary by intercepting between `render_mark_all_dirty` and `render_diff` — practical implementation: invoke `render_mark_all_dirty` alone and inspect `dirty_rows == 0xFF, 0xFF, 0xFF`; separately invoke `render_full` and verify `dirty_rows == 0, 0, 0` post-call AND all 24 rows have been processed by checking shadow reflects expected content).
    - `render_scroll-cursor-below-visible.asm` — buffer contains 30 lines (29 newlines); `top_line_offset = 0`; `cursor_offset = (start of line 25)`; cursor is below row 22. Call `render_diff`. Post-call: `top_line_offset` has advanced to the start of line N where N >= 3 (so cursor lands at row 22 or above in the visible window — the exact value depends on the scroll-advance policy: "advance just enough" → N = cursor_line - 22 = 3; OR "advance to put cursor mid-window" → not in MVP). MVP picks the "advance just enough" minimal-scroll policy.
    **And** the live baseline becomes 22 pass / 1 fail (17 pre-1.11 passes from Story 1.10 + 5 new `render_*` cases; the only `fail` remains the deliberate `harness_fail` from Story 1.6).

17. **BIOS_CONOUT capture stub for headless tests.**
    **Given** the test harness needs to verify EMIT-SIDE behavior (the exact bytes pushed to `BIOS_CONOUT`), not just state-side behavior
    **When** I inspect `test/inc/test_bios_conout_capture.inc` (NEW in this story)
    **Then** the file provides an override-EQU mechanism for `BIOS_CONOUT` that redirects emits into a test-local capture buffer:
    - The override REPLACES the production `BIOS_CONOUT` EQU (which points to a BIOS jump-table address) with a `JP test_capture_emit` thunk address — actually NO: EQU is single-assignment in sjasmplus, and `inc/bios.inc` has already EQU'd `BIOS_CONOUT = 0xFA0C`. The override mechanism instead provides a test-side `test_bios_conout_addr` symbol that production code is expected to use via a level of indirection — BUT production code uses the literal `CALL BIOS_CONOUT`, baking in the production address at assembly time. Reconciliation: tests INCLUDE `inc/bios.inc` and inherit the production EQU; the test "intercepts" emits by pointing iz-cpm's BIOS jump-table for CONOUT at a test-side routine that captures bytes into a buffer at a known address (`test_capture_buffer EQU 0xCFA0` or similar — sub-BDOS, sub-sentinel).
    - Alternative implementation (RECOMMENDED): the tests use a `BIOS_CONOUT` build-mode override. Before INCLUDEing `inc/bios.inc`, tests `IFDEF TESTING` and EQU `BIOS_CONOUT` to a test-local routine address; the production `inc/bios.inc` then wraps its `EQU 0xFA0C` in `IFNDEF BIOS_CONOUT`. The IFNDEF guard is added in this story (small `inc/bios.inc` edit). Test-side: `test_bios_conout` routine appends C (the emit byte) to a `test_capture_buffer` at a known address, increments a 2-byte length counter, RETs. Tests then inspect the capture buffer post-`render_diff` call.
    - The simpler alternative (FALLBACK): tests verify only `shadow_buffer` and `dirty_rows` post-state. AC16's tests are written so each scenario's post-state uniquely implies the correct emit (since shadow is updated to match emitted content). Capture-side byte verification can be deferred if the override mechanism turns out to be more plumbing than the story wants to add. The dev makes the final call based on what's tractable.
    **And** the dev-notes Implementation section pins which mechanism is chosen (capture-stub vs. shadow-state-only), with rationale.

18. **Calling convention (MC1, MC4).**
    **Given** the calling convention (MC1 caller-saved everywhere; MC4 handler signature)
    **When** I inspect public render entries (`render_init`, `render_diff`, `render_full`, `render_mark_row_dirty`, `render_mark_all_dirty`)
    **Then** each is a `RET`-terminating routine with parameters via documented register inputs only (`A = row` for `render_mark_row_dirty`; no input regs for the others)
    **And** each routine's contract block documents `In:` / `Out:` / `Trashes:` / `Calls:` (AR23) — `Trashes:` covers `A, BC, DE, HL, IX, F` for the heavy paths (render_diff, render_full, render_init) since the cell-walk uses every general-purpose register; the lightweight `render_mark_row_dirty` / `render_mark_all_dirty` are bitfield-only and may document a narrower trash set (A, HL, F).

19. **Build-time invariants and AR/NFR enforcement.**
    **Given** the project build invariants
    **When** I run `make` from project root
    **Then** `vibe.com` builds cleanly under sjasmplus 1.23.0 (NFR14)
    **And** two consecutive `make clean && make` runs produce byte-identical `vibe.com` (NFR18) — capture both SHAs in Debug Log References
    **And** `grep -nE 'BIOS_CONOUT' src/*.asm` (excluding render.asm) returns zero matches (AR13 / AC10)
    **And** `grep -nE 'gapbuf_(insert|delete|move_gap|init|load)' src/render.asm` returns zero matches (AR14 / AC12)
    **And** `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY|BDOS_CALL' src/render.asm` returns zero matches (AR15 / AC11)
    **And** the `make sizes` baseline is captured (optional; if sizes is still a stub in 1.11, document that — story 1.12 wires it for real).

20. **`vibe.asm` integration.**
    **Given** AR25's INCLUDE order (`init → input → statusln → gapbuf → render → dispatch → parser → motions → ...`)
    **When** I inspect `src/vibe.asm` after Story 1.11
    **Then** `INCLUDE "render.asm"` lands AFTER `INCLUDE "gapbuf.asm"` and BEFORE `INCLUDE "dispatch.asm"` (the current vibe.asm has dispatch.asm directly after gapbuf.asm — render.asm slots in between them per AR25)
    **And** the `vibe.asm` header `Dependencies:` line adds `src/render.asm (Story 1.11)`
    **And** the AR25 comment at the dispatch.asm INCLUDE site (currently noting "render.asm (Story 1.11) does not yet exist; when it lands it will slot in BEFORE dispatch.asm here") is updated to reflect that render.asm is now present
    **And** the `;; --- Input-loop abort target ---` comment block in `vibe.asm` is NOT touched by this story (it remains Story 1.12's responsibility per Story 1.10's prior pattern).

## Tasks / Subtasks

- [x] Task 1 — Read foundational artifacts and previous-story dev-notes (no code change). (AC reference: all)
  - [x] Read `_bmad-output/planning-artifacts/architecture.md` § Rendering & Input (RI1, RI2, RI3, RI4, RI5) at architecture lines 558-625, § Cross-Cutting Concerns (concern #3 "Shadow-buffer integrity") at lines 137-142, § Data Flow (Keystroke Lifecycle) at lines 1466-1502, and the V2 scroll mechanism note at lines 1652-1660.
  - [x] Read `_bmad-output/implementation-artifacts/1-10-command-parser-count-pending-operator-motion-prefix.md` § Dev Notes for the prior story's house style. Specific traps that recur for Story 1.11: (a) test-case scaffold INCLUDE order (prologue → body → epilogue → production INCLUDEs in AR25 order → input_loop_stub → state.inc LAST), (b) `BDOS_CALL` macro arg-textual-substitution caveat (not directly relevant to render but inherits the discipline), (c) every `RET` documented in the trashes line, (d) the asymmetric-clear protocol pattern (used in parser; render has its own asymmetric pattern: `render_init` clears dirty_rows but NOT status_dirty — see AC2).
  - [x] Read `_bmad-output/implementation-artifacts/deferred-work.md` entries from Story 1.2 (VT52_GOTO row/col clamp) and Story 1.3 (shadow_buffer alignment) — both items are explicitly resolved by this story (AC14 and AC15).
  - [x] Confirm `shadow_buffer` (`SCREEN_ROWS * SCREEN_COLS` = 1920 bytes), `dirty_rows` (`DIRTY_ROWS_BITMAP_BYTES` = 3 bytes for ceil(24/8)), and `top_line_offset` (2 bytes) already exist in `inc/state.inc` per the Story 1.3 layout. Story 1.11 adds NO new state.inc fields, NO new equates, NO new message strings.
  - [x] Confirm `VT52_ESC` (0x1B), `VT52_CLEAR_SCREEN` ('J'), `VT52_GOTO` ('Y'), `VT52_COORD_BIAS` (0x20) already exist in `inc/vt52.inc` per Story 1.2. Read by symbol; no inline magic numbers (NFR16).
  - [x] Confirm `BIOS_CONOUT` (0xFA0C, W1 placeholder per Story 1.4 — to be confirmed on hardware in Story 1.12) is available via `inc/bios.inc`.
  - [x] Confirm `SCREEN_ROWS` (24), `SCREEN_COLS` (80), `EDITABLE_ROWS` (23), `STATUS_ROW` (23) are available via `inc/equates.inc` per Story 1.2.

- [x] Task 2 — Create `src/render.asm` with the standard module-header block per AR23. (AC: 1)
  - [x] Header block: Module / Purpose / Public / State owned / Register conventions / Dependencies. Mirror `src/dispatch.asm` lines 1-93 and `src/parser.asm` lines 1-150 for shape. Render.asm is structurally similar (multiple public entry points, each with its own contract block; one module-private state owner — the shadow buffer and dirty bitmap).
  - [x] Public block enumerates: `render_init`, `render_diff`, `render_full`, `render_mark_row_dirty`, `render_mark_all_dirty`. Optional internal helpers (`render_emit_byte`, `render_emit_goto`, `render_walk_to_row`, `render_compute_cursor_row`, etc.) are NOT in the Public list — they're file-local. The Public list is the public contract surface.
  - [x] State owned: `shadow_buffer` (writer = `render_init` zeroes, `render_diff` updates per-cell), `dirty_rows` (writer = `render_mark_*` set bits, `render_diff` clear after pass, `render_init` zeroes), `top_line_offset` (writer = `render_diff` scroll-adjust, `render_init` zeroes); `status_dirty` (READS + CLEARS on status-row emit — write-back to clear is read-modify-write; the AR12 funnel still owns the SET path).
  - [x] Dependencies line lists `inc/equates.inc` (SCREEN_ROWS / SCREEN_COLS / EDITABLE_ROWS / STATUS_ROW / STATUS_LINE_WIDTH / DIRTY_ROWS_BITMAP_BYTES), `inc/state.inc` (shadow_buffer / dirty_rows / top_line_offset / cursor_offset / gap_start / gap_end / status_buffer / status_dirty), `inc/bios.inc` (BIOS_CONOUT), `inc/vt52.inc` (VT52_ESC / VT52_CLEAR_SCREEN / VT52_GOTO / VT52_COORD_BIAS); `inc/modes.inc` is NOT a dependency (render is mode-agnostic — the cursor's mode does not affect cell rendering); `inc/bdos.inc` is NOT a dependency (render uses BIOS-direct only); `src/statusln.asm` is documented as a state-collaborator (status_buffer/status_dirty co-ownership) but not a function-call dependency.
  - [x] Document the AR13 retirement in the header: "render.asm is the SOLE BIOS_CONOUT site in production code. The architecture-line-162 'init's initial clear is the only declared exception' is retired — init.asm calls `render_init`, which performs the ESC J emit inside render.asm. The exception is no longer needed."
  - [x] Document the AC15 page-alignment decision: "shadow_buffer is NOT page-aligned in the state.inc layout (Story 1.3 deferral resolved here). The indexing math uses `row * SCREEN_COLS + col` via 16-bit shifts — sub-perceptible cost; alignment fast-path deferred to a future profiling-driven story."

- [x] Task 3 — Implement `render_init`. (AC: 2, 18)
  - [x] Public entry. `In: (none). Out: screen cleared via ESC J; shadow_buffer filled with 0x20; dirty_rows zeroed; top_line_offset zeroed; cursor at row 0/col 0 emitted. Trashes: A, BC, DE, HL, F. Calls: render_emit_byte (internal helper for BIOS_CONOUT writes).`
  - [x] Implementation pattern (recommended):
    ```
    render_init:
        ;; 1. Emit ESC J (clear screen).
        LD      A, VT52_ESC
        CALL    render_emit_byte
        LD      A, VT52_CLEAR_SCREEN
        CALL    render_emit_byte

        ;; 2. Fill shadow_buffer with spaces (1920 bytes).
        LD      HL, shadow_buffer
        LD      DE, shadow_buffer + 1
        LD      (HL), 0x20                  ; first cell = space
        LD      BC, SCREEN_ROWS * SCREEN_COLS - 1
        LDIR                                ; classic LDIR-fill idiom

        ;; 3. Zero dirty_rows (3 bytes).
        LD      HL, dirty_rows
        LD      (HL), 0
        INC     HL
        LD      (HL), 0
        INC     HL
        LD      (HL), 0

        ;; 4. Zero top_line_offset (2 bytes).
        LD      HL, 0
        LD      (top_line_offset), HL

        ;; 5. Position cursor at row 0 / col 0 (defensive — known state).
        XOR     A
        LD      C, A                        ; C = col = 0
        CALL    render_emit_goto            ; A = row, C = col → ESC Y row+bias col+bias
        RET
    ```
  - [x] **status_dirty is NOT cleared by render_init.** The flag may have been set by a pre-render `status_set_message` call (e.g., from Story 1.12's init flow setting an initial mode-indicator); the first `render_diff` after init picks it up. This asymmetry is documented in the routine's contract.
  - [x] **The LDIR-fill idiom** (1-byte seed + LDIR) costs ~21 T-states per byte × 1920 bytes ≈ 40 K T-states ≈ 10 ms at 4 MHz. Acceptable for an init-time cost (NFR3 governs frame-rate cost, not boot-time).

- [x] Task 4 — Implement `render_mark_row_dirty` and `render_mark_all_dirty`. (AC: 6, 7, 18)
  - [x] `render_mark_row_dirty` public entry. `In: A = row 0..23. Out: bit (1 << (A mod 8)) is set in dirty_rows[A / 8]; out-of-range A returns without writing. Trashes: A, HL, F (no BC, DE used; minimal trash). Calls: (none).`
  - [x] Implementation:
    ```
    render_mark_row_dirty:
        CP      SCREEN_ROWS                 ; defensive clamp: A >= 24 → no-op
        RET     NC                          ; (A >= SCREEN_ROWS branches here)
        ;; Compute byte index = A / 8 → C; bit index = A mod 8 → B.
        LD      C, A
        SRL     C                           ; A / 2
        SRL     C                           ; A / 4
        SRL     C                           ; A / 8 → byte index 0..2 (for 24 rows)
        AND     0x07                        ; A = bit index 0..7
        ;; Build mask = 1 << bit_index. Loop-shift idiom for small bit counts.
        LD      B, A
        LD      A, 1
        OR      A                           ; CF = 0
        INC     B                           ; pre-decrement DJNZ trick: B=0 → 1 iter
        JR      .mask_done                  ; (alternative: lookup table)
    .mask_shift:
        ADD     A, A                        ; shift left by 1
    .mask_done:
        DJNZ    .mask_shift
        ;; OR-merge mask into dirty_rows[byte_index].
        LD      HL, dirty_rows
        LD      B, 0
        ;; HL += C (byte index 0..2)
        ADD     HL, BC                      ; HL = dirty_rows + (A / 8)
        OR      (HL)                        ; A = old | mask
        LD      (HL), A
        RET
    ```
    Note: the bit-mask loop is one of several valid idioms — `LD A, 1 / shift A,bit_index times` works in ≤8 shifts; a 256-byte lookup is faster but wastes a page; for 0..7 the loop wins. The dev may choose a different shape — the contract is what counts.
  - [x] `render_mark_all_dirty` public entry. `In: (none). Out: dirty_rows = 0xFF, 0xFF, 0xFF (all 24 bits set, plus bits 24..31 of byte 2 — inert because the row-walk only iterates 0..23). Trashes: A, HL, F. Calls: (none).`
  - [x] Implementation:
    ```
    render_mark_all_dirty:
        LD      A, 0xFF
        LD      (dirty_rows), A
        LD      (dirty_rows + 1), A
        LD      (dirty_rows + 2), A
        RET
    ```
    Three direct stores, 30 T-states. Smaller than an LDIR for 3 bytes.

- [x] Task 5 — Implement `render_full`. (AC: 3, 18)
  - [x] Public entry. `In: (none). Out: all rows re-emitted; shadow fully synced; dirty_rows cleared; cursor repositioned (RI4). Trashes: A, BC, DE, HL, IX, F. Calls: render_mark_all_dirty, render_diff (tail-call permissible).`
  - [x] Implementation:
    ```
    render_full:
        CALL    render_mark_all_dirty
        JP      render_diff                 ; tail-call: render_diff's RET returns to render_full's caller
    ```
    Two instructions, 4 bytes. The tail-JP idiom matches parser.asm's stub pattern (parser_doubled_operator_stub etc.).

- [x] Task 6 — Implement internal helpers `render_emit_byte` and `render_emit_goto`. (AC: 4, 14, 18)
  - [x] **`render_emit_byte`** — wraps the `LD C, byte / CALL BIOS_CONOUT` boilerplate so the dev doesn't repeat it at every emit site. `In: A = byte to emit. Out: byte sent to BIOS_CONOUT. Trashes: A, BC, F (BIOS may trash more — caller-saved). Calls: BIOS_CONOUT.` Implementation:
    ```
    render_emit_byte:
        LD      C, A
        CALL    BIOS_CONOUT
        RET
    ```
    4 bytes including the RET. Centralising this is critical for AR13's grep enforcement: a single `CALL BIOS_CONOUT` site in render.asm vs. dozens scattered makes the rule easy to police.
  - [x] **`render_emit_goto`** — composes `ESC Y row+bias col+bias` with the AC14 clamp. `In: A = row 0..23 (or any byte; values >= SCREEN_ROWS clamp to SCREEN_ROWS-1), C = col 0..79 (similar clamp to SCREEN_COLS-1). Out: 4 bytes emitted to BIOS_CONOUT (ESC, 'Y', row+bias, col+bias). Trashes: A, BC, F. Calls: render_emit_byte (4 times).` Implementation:
    ```
    render_emit_goto:
        ;; Clamp row to [0, SCREEN_ROWS-1].
        CP      SCREEN_ROWS
        JR      C, .row_ok
        LD      A, SCREEN_ROWS - 1
    .row_ok:
        ADD     A, VT52_COORD_BIAS          ; A = row + 0x20
        LD      B, A                        ; B = biased row (saved across emits)
        ;; Clamp col (C) to [0, SCREEN_COLS-1].
        LD      A, C
        CP      SCREEN_COLS
        JR      C, .col_ok
        LD      A, SCREEN_COLS - 1
    .col_ok:
        ADD     A, VT52_COORD_BIAS          ; A = col + 0x20
        LD      C, A                        ; C = biased col
        ;; Emit ESC, 'Y', row, col.
        LD      A, VT52_ESC
        CALL    render_emit_byte
        LD      A, VT52_GOTO
        CALL    render_emit_byte
        LD      A, B
        CALL    render_emit_byte
        LD      A, C
        JP      render_emit_byte            ; tail-JP final emit
    ```
    Pinned by AC14: ALL `ESC Y` emit sites in render.asm go through this helper. Direct `LD A, VT52_ESC / CALL render_emit_byte / LD A, VT52_GOTO / CALL render_emit_byte / ...` patterns elsewhere are forbidden — bypassing `render_emit_goto` skips the clamp.

- [x] Task 7 — Implement `render_diff`. (AC: 4, 5, 14, 18)
  - [x] Public entry. `In: (none — all parameters come from state.inc). Out: screen updated to match buffer + status; shadow synced; dirty_rows cleared; status_dirty cleared if it was set; cursor repositioned. Trashes: A, BC, DE, HL, IX, F. Calls: render_emit_byte, render_emit_goto, (internal: render_walk_to_row, render_compute_cursor_row, render_emit_status_row).`
  - [x] Stages (order matters — the cursor-row from scroll-adjust feeds the final cursor-emit):
    1. **Scroll adjustment.** Internal helper `render_scroll_adjust`:
       - Compute cursor row by walking from `top_line_offset` toward `cursor_offset`, counting 0x0A bytes. Returns A = cursor_row (0..N).
       - If A >= EDITABLE_ROWS (cursor below visible window): advance `top_line_offset` forward over line breaks until cursor_row falls back into [0, EDITABLE_ROWS-1]. Recompute cursor_row after the advance. Call `render_mark_all_dirty` (or set bits 0..22 specifically — leaving the implicit row 24 status bit alone) to force a full editable-region re-emit.
       - If cursor_offset < top_line_offset (cursor above visible window): retreat `top_line_offset` to the start of cursor's containing line (walk backward over line breaks). Recompute cursor_row. Mark all editable rows dirty.
       - Else: no scroll; cursor_row is in range; return as-is.
       - Save cursor_row in a 1-byte module-local (or pass through a register held across the row-emit pass — register pressure decides).
       - Note: "start of cursor's containing line" requires backward walk in the gap buffer's two-halves form. The clean implementation: scan logical-offset-backwards from cursor_offset, decrementing until we find a 0x0A or hit 0. The result is the byte AFTER the 0x0A (or 0 for the first line).
    2. **Editable-row emit pass.** For row r in 0..22:
       - Test bit `1 << (r mod 8)` in `dirty_rows[r / 8]`. If clear, skip row.
       - If set, compute row r's start logical offset: walk r line-breaks forward from `top_line_offset` (use a cached "current logical offset" + "current row" between iterations — don't restart the walk for each row).
       - For each col 0..79: compute target byte (byte at row-start + col, or 0x20 for past-EOL / past-EOF). Compare to `shadow_buffer[r * SCREEN_COLS + col]`.
       - Track contiguous runs: when target ≠ shadow, start a run; when target == shadow (or end of row), close the run. For each closed run: emit `render_emit_goto(A=r, C=run_start_col)` then emit each target byte in the run via `render_emit_byte`, AND update `shadow_buffer[r * SCREEN_COLS + col]` for each emitted byte (one byte at a time, in lock-step with emission).
       - Optimisation note: a row that is dirty but whose target content matches shadow exactly (e.g., a row marked dirty by an over-eager caller) emits zero bytes — diff is the correctness layer, dirty is the hint layer.
    3. **Status-row emit (gated by status_dirty).** Internal helper `render_emit_status_row`:
       - If `(status_dirty) == 0`, skip.
       - For col 0..79: compare `status_buffer[col]` to `shadow_buffer[STATUS_ROW * SCREEN_COLS + col]`. Track contiguous runs; emit `render_emit_goto(A=STATUS_ROW, C=run_start_col)` + run bytes; update shadow.
       - Set `status_dirty = 0` after the row is processed (regardless of whether any bytes were actually emitted — the dirty flag means "buffer has changed since last emit", and we've now reconciled).
    4. **Clear dirty_rows.** All 3 bytes = 0.
    5. **Final cursor reposition.** `render_emit_goto(A=cursor_row, C=cursor_col)`. cursor_col = cursor_offset - row_start_logical_offset (computed during the scroll-adjust step; recompute here if not cached). Clamp at SCREEN_COLS-1 (handled by render_emit_goto's internal clamp).
  - [x] **Cell-content helper** — `In: HL = logical offset, DE = byte position to read up to. Out: A = byte at logical offset OR 0x20 if past-EOL / past-EOF; CF = 1 if past-EOL (caller can break the inner loop early). Trashes: A, F (HL preserved for caller's loop, or returned modified — design choice).` The implementation walks the SR3 gap-buffer mapping: if logical_offset < (gap_start - GAP_BUFFER_BASE), physical = GAP_BUFFER_BASE + logical_offset; else physical = gap_end + (logical_offset - (gap_start - GAP_BUFFER_BASE)). At physical, read the byte; return as A.
  - [x] **Two-halves walk efficiency.** The architecture's SR3 mapping is per-cell; for a 1920-cell render frame this is 1920 mapping computations. Optimisation: pre-compute the gap_start / gap_end / GAP_BUFFER_BASE offsets ONCE per `render_diff` invocation; cache them in registers (or scratch state) and use them across the row-walk. The hottest inner loop reduces to a compare + LD A, (HL). This is the "1840 byte-reads worst case" architectural budget — well within NFR3.

- [x] Task 8 — Replace `mode_full_refresh_stub` in `src/dispatch.asm` with the real Ctrl-L handler. (AC: 8)
  - [x] Locate `mode_full_refresh_stub` at `src/dispatch.asm:296-300`. Current body: `LD HL, msg_not_implemented / XOR A / CALL status_set_message / RET`.
  - [x] Replace body with:
    ```
    mode_full_refresh_stub:               ; or rename to mode_full_refresh
        JP      render_full               ; tail-JP: render_full's RET returns to dispatch_key's caller
    ```
    1 instruction, 3 bytes. Net byte change: shrinks dispatch.asm by ~9 bytes (removed: `LD HL, addr` 3 bytes + `XOR A` 1 byte + `CALL` 3 bytes + `RET` 1 byte = 8 bytes; added: 3-byte `JP`).
  - [x] Update the routine's contract block: `In: A = 0x0C (Ctrl-L, MC4). Out: screen fully redrawn from buffer state (FR48, NFR7); shadow synced; dirty_rows cleared; cursor repositioned. Trashes: A, BC, DE, HL, IX, F (render_full's transitive clobber). Calls: render_full (tail-JP).`
  - [x] Remove the "Story 1.11 replaces with the real render-pipeline full-refresh path" comment (the story has arrived). Replace with a one-line "Ctrl-L full-redraw handler (FR48, NFR7). Tail-JP to render_full; see src/render.asm."
  - [x] **Optional rename.** The `_stub` suffix is now wrong. Renaming to `mode_full_refresh` (or just inlining the dispatch_normal entry to point at `render_full` directly) is a cosmetic improvement. The dispatch_normal table at line 441-442 currently has `DEFB 0x0C : DEFW mode_full_refresh_stub`; the renamed entry would be `DEFW mode_full_refresh` or `DEFW render_full`. Either works; the dev picks. If renaming to point directly at `render_full`, the wrapper routine disappears entirely — saving 3 more bytes.
  - [x] Update `src/dispatch.asm` header `Dependencies:` line: add `src/render.asm (Story 1.11 — render_full)`.

- [x] Task 9 — Retire/replace `status_render` in `src/statusln.asm`. (AC: 9)
  - [x] Locate `status_render` at `src/statusln.asm:151-154`. Current body: stub that clears status_dirty and returns.
  - [x] **Default choice: remove `status_render` entirely.** Delete the routine. Update the file's `Public:` list (line 13) to remove `status_render`. Delete the `status_render` contract documentation in the Register-conventions block (lines 35-38). Delete the section divider "Story 1.5 STUB" comment block (lines 138-154).
  - [x] **Alternative: trampoline.** If preserving the public symbol is preferred (no callers today, but future-extension safety), replace the body with a thin wrapper that calls the render.asm internal `render_emit_status_row`. Caveat: this introduces a render.asm dependency in statusln.asm, which then forces every test that INCLUDEs statusln.asm to also INCLUDE render.asm. Default to "remove"; revisit only if a real caller emerges.
  - [x] Update the `Module:` line's Purpose paragraph if the change shifts emphasis. Currently statusln.asm's purpose is "Single status / error funnel (MC5)"; that stays accurate. The emission side moving to render.asm is a clean separation of concerns, not a purpose shift.

- [x] Task 10 — Update `src/vibe.asm` to INCLUDE render.asm in AR25 order. (AC: 20)
  - [x] Locate the dispatch.asm INCLUDE block in `src/vibe.asm:67-73`. The current comment notes "render.asm (Story 1.11) does not yet exist; when it lands it will slot in BEFORE dispatch.asm here."
  - [x] Insert a new `;; --- Render pipeline (RI1-RI4; render.asm — Story 1.11) ---` block BEFORE the dispatch.asm INCLUDE. The block comment notes: "AR25 order: gapbuf → render → dispatch → parser. render.asm owns shadow_buffer, dirty_rows, top_line_offset, and the single BIOS_CONOUT path (AR13)."
  - [x] Add `INCLUDE "render.asm"` in the new block.
  - [x] Update the dispatch.asm INCLUDE block's preceding comment: change "render.asm (Story 1.11) does not yet exist; when it lands it will slot in BEFORE dispatch.asm here" to "render.asm (Story 1.11) is INCLUDEd above per AR25."
  - [x] Update `src/vibe.asm` header `Dependencies:` line (line 22-24): add `src/render.asm (Story 1.11)` after `src/gapbuf.asm (Story 1.7)`.

- [x] Task 11 — Write five headless tests under `test/cases/render_*.asm`. (AC: 16, 17)
  - [x] **Decision: emit-capture vs. shadow-state-only.** AC17 documents both mechanisms. The recommended default for Story 1.11 is **shadow-state-only**: each test sets up the inputs (gap buffer, shadow buffer, dirty_rows, top_line_offset, cursor_offset, status_dirty) → invokes the render routine → inspects post-call `shadow_buffer` / `dirty_rows` / `top_line_offset` / `status_dirty`. This avoids the BIOS_CONOUT override plumbing and exercises the render math fully (the shadow update is in lock-step with the emit, so verifying shadow == expected verifies the emit byte-stream up to ordering). The capture-stub mechanism is documented as a deferral if a future test needs to verify EXACT emit byte sequencing (e.g., that two runs in a row produce TWO `ESC Y` sequences, not one merged sequence — the contiguous-runs test specifically verifies this and can be done by checking that shadow's two non-space runs are positioned correctly with intervening spaces, which implies separate ESC Y emits).
  - [x] **BIOS_CONOUT stub for tests.** Since render.asm calls `BIOS_CONOUT` (= 0xFA0C, a W1 placeholder) and the tests INCLUDE render.asm + bios.inc, the production `CALL BIOS_CONOUT` would land at 0xFA0C on iz-cpm, which is not a valid emit target. Options:
    - (a) **iz-cpm's BIOS jump-table.** iz-cpm provides a minimal BIOS at the expected addresses. If 0xFA0C is mapped to a no-op or to console-out via iz-cpm's own console, the test runs but its emission goes to iz-cpm stdout (where it could collide with the PASS/FAIL token). Verify iz-cpm's behavior at this address; if it's a CONOUT that writes to stdout, tests must avoid emitting anything that iz-cpm's `make test` grep would misinterpret.
    - (b) **Test-side BIOS_CONOUT override.** Tests `DEFINE BIOS_CONOUT_TEST_OVERRIDE` before INCLUDEing `inc/bios.inc`. `inc/bios.inc` wraps its `BIOS_CONOUT EQU 0xFA0C` in `IFNDEF BIOS_CONOUT`. Tests then EQU `BIOS_CONOUT` to a local address (e.g. `test_bios_conout_stub` defined in the test body). This adds an `IFNDEF` to inc/bios.inc — a small change with no production effect.
    - (c) **Local CALL site rewrite.** Tests define their own `render_emit_byte` BEFORE INCLUDEing render.asm? Doesn't work — sjasmplus EQU is single-assignment.
    - **Recommended:** Option (b). The test stub increments a counter and discards the byte (or appends to a capture buffer for the contiguous-runs test specifically). Add `IFNDEF BIOS_CONOUT` guard around `BIOS_CONOUT EQU 0xFA0C` in `inc/bios.inc` (line 35). Add `IFNDEF BIOS_TICK_ADDR` guard around `BIOS_TICK_ADDR EQU 0xFA00` for symmetry. Production code is unaffected (no `BIOS_CONOUT` is DEFINEd before the bios.inc INCLUDE in src/vibe.asm). Tests opt into the override via `DEFINE BIOS_CONOUT = test_bios_conout_stub` (or `BIOS_CONOUT EQU test_bios_conout_stub` declared before the `INCLUDE "../../inc/bios.inc"` line in the test prologue).
  - [x] **test_bios_conout_stub.** A small routine inside each test (or hoisted into `test/inc/test_bios_conout_capture.inc` for reuse):
    ```
    test_bios_conout_stub:
        ;; Append C (byte to emit) to test_capture_buffer; increment length.
        LD      A, (test_capture_len)
        ADD     A, A                        ; quick *2 for HL increment
        LD      HL, test_capture_buffer
        ;; ... append C at test_capture_buffer + test_capture_len ...
        LD      A, (test_capture_len)
        INC     A
        LD      (test_capture_len), A
        RET
    test_capture_buffer:    DEFS 256        ; 256 bytes plenty for one render frame
    test_capture_len:       DEFB 0
    ```
    Tests reset `test_capture_len = 0` before each scenario; inspect `test_capture_buffer[0..test_capture_len-1]` after the render call to verify emit sequence (for the contiguous-runs test specifically; other tests can ignore the buffer and just check shadow state).
  - [x] **`render_diff-no-changes.asm`** — exercises NFR1's "idle = no emission" + the RI4 cursor-reposition exception. Setup: gap buffer = empty (gap covers full extent; cursor_offset = 0); shadow_buffer = all 0x20; dirty_rows = 0; status_dirty = 0; top_line_offset = 0. Call `render_diff`. Post-call: shadow unchanged; dirty_rows = 0; emission = exactly 4 bytes (the trailing `ESC Y 0x20 0x20` cursor reposition). Sentinel 0xE1 = emission count != 4; 0xE2 = shadow_buffer first cell != 0x20 (or any other unexpected change). Note: with shadow_state-only testing, the "exactly 4 bytes" test is replaced by "test_capture_len == 4 AND test_capture_buffer == [VT52_ESC, VT52_GOTO, 0x20, 0x20]" via the capture stub.
  - [x] **`render_diff-single-row-change.asm`** — exercises one dirty row, one run, FR47. Setup: gap buffer contains "hello" (5 chars, no newline); gap is at offset 5 (after "hello"); shadow row 0 is all spaces; `dirty_rows[0] |= 0x01` (row 0 dirty); cursor_offset = 0 (or 5 — exact spot doesn't matter for AC); status_dirty = 0. Call `render_diff`. Post-call: shadow_buffer[0..4] = "hello"; shadow_buffer[5..79] = spaces; dirty_rows = 0; emission begins with `ESC Y 0x20 0x20` (= row 0 col 0) followed by "hello", then trailing cursor reposition. Sentinels 0xE1/0xE2/0xE3 for failure modes (shadow not updated; dirty_rows not cleared; emission prefix wrong).
  - [x] **`render_diff-contiguous-runs.asm`** — exercises two runs in one row, FR47 + NFR1. Setup: gap buffer contains "ab        xy" (or use shadow pre-state to simulate two runs of differing content; the cleaner setup uses pre-populated gap buffer with "ab" at logical 0..1, then 8 chars of space, then "xy" at logical 10..11); shadow row 0 = all spaces; row 0 dirty. Call `render_diff`. Post-call: shadow[0..1] = "ab", shadow[2..9] = spaces, shadow[10..11] = "xy", shadow[12..79] = spaces; emission = `ESC Y 0x20 0x20 a b ESC Y 0x20 0x2A x y ESC Y ... (cursor)` — TWO separate ESC Y sequences (one at col 0, one at col 10 = 0x2A after bias), NOT a single ESC Y followed by 12 bytes "ab        xy". Sentinel 0xE4 = emission contains only one ESC Y (merged run); the test verifies by scanning test_capture_buffer for the count of `VT52_ESC` bytes (2 ESC Y in body + 1 ESC Y trailing cursor = 3 total).
  - [x] **`render_full-marks-all-dirty.asm`** — exercises AC3. Setup: dirty_rows = 0; everything else doesn't matter (shadow / cursor / status). Call `render_mark_all_dirty` STANDALONE first; verify dirty_rows = 0xFF, 0xFF, 0xFF. Reset dirty_rows = 0; call `render_full`; verify dirty_rows = 0, 0, 0 (post-pass cleared) AND emission begins with at least one `ESC Y 0x20 0x20` (= row 0 col 0) — the first dirty row emitted. Sentinels 0xE1 (mark_all_dirty did not set all bits), 0xE2 (render_full did not clear dirty_rows), 0xE3 (render_full produced no emission for an empty buffer — wait, an all-space buffer with all-space shadow has zero diffs, so render_full's body emits ONLY the trailing cursor; verify exactly that). Refine: Set gap buffer = "x" (1 char on row 0) so render_full emits at least one cell; verify shadow[0] = 'x' after the call.
  - [x] **`render_scroll-cursor-below-visible.asm`** — exercises V2 scroll, AC4 step 1. Setup: gap buffer contains 30 lines (29 0x0A bytes interspersed with content; e.g. "L0\nL1\nL2\n...\nL29"); top_line_offset = 0; cursor_offset = (start of "L25" — i.e. logical offset of the byte after the 25th 0x0A); dirty_rows = 0; status_dirty = 0. Call `render_diff`. Post-call: top_line_offset > 0 (advanced); the new top_line_offset places cursor's containing line at row <= EDITABLE_ROWS - 1 (cursor visible). For the "minimal advance" policy: top_line_offset = (start of "L3" — i.e. line 25 - 22 = line 3 becomes the new top), cursor lands at row 22. Sentinels 0xE1 (top_line_offset stayed 0), 0xE2 (top_line_offset advanced to wrong value — non-minimal scroll). Also verify dirty_rows is cleared post-pass.
  - [x] **Test file structure.** Each test follows the established pattern (from `test/cases/parser_compose-count-op-motion.asm` etc.):
    1. Module header block (Module / Purpose / AC reference / Sentinel codes).
    2. Pre-ORG production headers: `inc/equates.inc`, `inc/bios.inc` (with BIOS_CONOUT override), `inc/bdos.inc`, `inc/modes.inc`, `inc/vt52.inc`.
    3. `INCLUDE "../inc/test_prologue.inc"` (ORG 0x0100, sentinel pre-zero, test_start).
    4. Test body — setup, CALL under test, verification, JP test_fail with sentinel or JP test_pass.
    5. Test-local data: capture buffer, capture-length byte, motion stubs, etc.
    6. `INCLUDE "../inc/test_epilogue.inc"` (test_pass / test_fail).
    7. Production code under test (AR25 order): `inc/state.inc` LAST (positional). Render needs: `src/statusln.asm`, `src/gapbuf.asm`, `src/render.asm`, `src/dispatch.asm` (optional — render tests don't use dispatch), `src/parser.asm` (optional).
    8. `INCLUDE "../inc/test_input_loop_stub.inc"` (resolves bdos_error_funnel's JP input_loop).
    9. `INCLUDE "../../inc/state.inc"` LAST.
    Render tests INCLUDE order: `statusln.asm` → `gapbuf.asm` → `render.asm`. dispatch.asm + parser.asm not needed for render tests (no dispatch table walk; no parser state). gapbuf.asm is needed because render reads gap_start / gap_end / cursor_offset / GAP_BUFFER_BASE — even if no gapbuf_* function is called, the state.inc-side fields must be writable by the test (the test sets up gap_start / gap_end directly via `LD HL, GAP_BUFFER_BASE / LD (gap_start), HL` etc., not via gapbuf_init — that way the test's gap-buffer state is fully synthetic and predictable).

- [x] Task 12 — Build, byte-identical rebuild check, AR grep sweeps, all-tests pass. (AC: 19)
  - [x] `make clean && make` succeeds (NFR14 — sjasmplus 1.23.0 builds cleanly).
  - [x] Capture two consecutive `make clean && make` SHAs of `vibe.com`; verify byte-identical (NFR18).
  - [x] `grep -rnE 'BIOS_CONOUT' src/` excluding render.asm: zero matches (AR13 / AC10).
  - [x] `grep -nE 'gapbuf_(insert|delete|move_gap|init|load)' src/render.asm`: zero matches (AR14 / AC12).
  - [x] `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY|BDOS_CALL' src/render.asm`: zero matches (AR15 / AC11).
  - [x] `make -C test test`: reports 22 pass / 1 fail (17 pre-1.11 passes + 5 new `render_*` + the constant `harness_fail` failure).
  - [x] Document any per-section size shift in dev-notes' Completion Notes (render.asm is the largest new module to date — likely ~400-600 bytes of code).

- [x] Task 13 — Update `deferred-work.md` to mark Story-1.2 and Story-1.3 deferrals resolved. (AC: 14, 15)
  - [x] Locate Story-1.2 entry in `deferred-work.md` (line 11). Add a follow-up note: "Resolved by Story 1.11: render.asm's internal `render_emit_goto` helper clamps row to [0, SCREEN_ROWS-1] and col to [0, SCREEN_COLS-1] before adding VT52_COORD_BIAS. All ESC Y emit sites in render.asm route through this helper."
  - [x] Locate Story-1.3 entry on shadow_buffer alignment (line 17). Add a follow-up note: "Resolved by Story 1.11: shadow_buffer is NOT page-aligned. Indexing math uses `row * SCREEN_COLS + col` via shift-and-add. Alignment fast-path deferred to a future profiling-driven story (none anticipated for MVP)."
  - [x] No new deferral entries from this story unless review surfaces them.

## Dev Notes

### Architecture compliance

This story implements the architecture's **Rendering & Input** decisions (RI1-RI4, architecture lines 558-580) and resolves the **Validation Issue V2** (scroll mechanism, architecture lines 1652-1660). Specific decisions wired:

- **RI1: Per-row dirty bitmap + per-cell diff within dirty rows.** Implemented as a 3-byte (24-bit) `dirty_rows` bitmap; edits mark rows dirty via `render_mark_row_dirty`; `render_diff` walks only dirty rows; inside each dirty row, a per-cell shadow compare emits contiguous runs. Idle rows skip the comparison loop entirely.
- **RI2: Render runs after each input-loop iteration; no periodic timer.** Story 1.11 doesn't wire the main loop (Story 1.12 does), but the render entry points are designed to be called exactly once per loop iteration — no internal blocking, no periodic re-entry, no timer-driven dispatch.
- **RI3: Ctrl-L = full redraw + dirty-bitmap clear.** Implemented as `render_full` → `render_mark_all_dirty` + `render_diff`. Drift escape hatch for NFR7. Dispatched from `dispatch_normal`'s 0x0C entry (AC8).
- **RI4: Cursor-positioning emission emitted LAST in every render pass.** Even if no cells changed, the trailing `ESC Y row col` re-emits cursor position so cursor desync alone never compounds. Implemented in `render_diff` step 5.

The story also satisfies the architecture's cross-cutting concerns:

- **Concern #3 — Shadow-buffer integrity** (architecture lines 137-142). The shadow is updated in lock-step with each emitted byte; the diff pass cannot leave shadow and screen out-of-sync.
- **AR13 single screen-emission path.** All `BIOS_CONOUT` calls in production code live in `src/render.asm`. The architecture line 162 carve-out for init's initial clear is retired — `render_init` absorbs the ESC J emit.
- **AR12 single status-message funnel.** The WRITE path to `status_buffer` / `status_dirty` stays exclusively with `status_set_message` in statusln.asm. The READ path (status_buffer → screen) moves to render.asm; the dirty-clear is part of the read, not a separate write surface (AR12's "funnel" is about authoring messages, not consuming them).

### Library / framework requirements

**sjasmplus 1.23.0:**
- Already pinned by `Makefile`'s `check-toolchain` (Story 1.1).
- **Multi-pass assembly resolves forward references.** `src/dispatch.asm`'s replaced Ctrl-L handler references `render_full` — defined in `src/render.asm`, INCLUDEd AFTER `src/dispatch.asm` in `src/vibe.asm` per AR25 (actually wait — AR25 has render BEFORE dispatch, so this is a BACKWARD reference at first pass; cleaner). Story 1.11 INCLUDEs render.asm BEFORE dispatch.asm in vibe.asm (per AR25), so dispatch.asm's `JP render_full` is a forward-from-dispatch-but-backward-from-vibe.asm-include-order reference. sjasmplus first-pass resolves it: render.asm has emitted `render_full:` as a label by the time dispatch.asm's `JP render_full` is encountered.
- **`LDIR` for shadow_buffer fill.** `render_init`'s 1920-byte space-fill uses `LDIR` with a 1-byte seed at the buffer start. `LDIR` instruction is 21 T-states per byte; 1920 × 21 ≈ 40 K T-states ≈ 10 ms at 4 MHz — boot-time cost, acceptable.
- **Bit manipulation for `dirty_rows`.** `render_mark_row_dirty`'s mask-build uses `LD A, 1` + `ADD A, A` shift loop (or `RLCA` × N). The loop variant is ~10 T-states/bit × 7 bits worst case = 70 T-states; with the OR-merge into memory the whole routine is ~90 T-states. A lookup table (256 bytes of pre-computed `1 << (n % 8)` for n in 0..255) is faster (LD A,(table_base+row)) but wastes 256 bytes — not worth it for this use case.
- **No `DEFW` byte-order surprises.** `top_line_offset` is 16-bit; stored little-endian by `LD (top_line_offset), HL`. Read via `LD HL, (top_line_offset)`. Consistent with all prior 16-bit state reads in this project.

**iz-cpm:**
- Used for the five new headless tests (`make -C test test`).
- **BIOS_CONOUT at 0xFA0C is a W1 placeholder.** iz-cpm's behavior at this address is unspecified by the architecture; in practice iz-cpm provides a minimal BIOS jump table including a `CONOUT` that writes to stdout. The render tests override `BIOS_CONOUT` via an `IFNDEF` guard added to `inc/bios.inc` (small modification, no production effect — production code does not pre-DEFINE the symbol).
- **5-second timeout per test (test/Makefile line 34).** Render tests are pure-memory + scripted-emit; runtime is bounded by the 1920-cell shadow walk × a small constant. Worst case ~100 K T-states at 4 MHz iz-cpm clock ≈ 25 ms — comfortably under timeout.
- **PASS/FAIL token convention (test/Makefile line 58, 61).** Tests emit `PASS$` or `FAIL <fc> <ctx>$` via BDOS function 9; harness greps stdout. If a render test's BIOS_CONOUT override forwards bytes to stdout, the emit byte stream could collide with the PASS/FAIL grep. Solution: override stub captures into RAM, does NOT forward to stdout. The PASS/FAIL token then dominates the stdout buffer; harness grep matches cleanly.

**CP/M 2.2 BDOS:**
- NOT used by render.asm directly (AR15). The status-row emit reads `status_buffer` (a memory buffer) and emits via BIOS_CONOUT; no BDOS involvement.

**MicroBeast BIOS:**
- `BIOS_CONOUT` at 0xFA0C (W1 placeholder) is render.asm's ONE BIOS entry point. The actual address gets confirmed in Story 1.12's hardware bring-up; until then, iz-cpm's stand-in suffices for the test harness.
- `BIOS_CONIN` / `BIOS_CONINST` / `BIOS_TICK_ADDR` are NOT used by render.asm (those are input.asm's concern per Story 1.8).

### Previous story intelligence (Stories 1.1-1.10)

**From Story 1.1:**
- `make` from project root produces `vibe.com` deterministically. Adding `src/render.asm` (the largest new module so far) and the dispatch.asm/statusln.asm/vibe.asm edits shifts the layout but preserves byte-determinism (NFR18). AC19 verifies.

**From Story 1.2:**
- `inc/vt52.inc` declares `VT52_ESC` (0x1B), `VT52_CLEAR_SCREEN` ('J' = 0x4A), `VT52_GOTO` ('Y' = 0x59), `VT52_COORD_BIAS` (0x20). Read by symbol in render.asm; no inline magic numbers (NFR16).
- `inc/equates.inc` declares `SCREEN_ROWS` (24), `SCREEN_COLS` (80), `EDITABLE_ROWS` (23), `STATUS_ROW` (23), `STATUS_LINE_WIDTH` (80), `DIRTY_ROWS_BITMAP_BYTES` (3). All consumed by render.asm.
- **Story 1.2 deferral on VT52_GOTO clamp is resolved here (AC14).** `render_emit_goto` clamps row to [0, SCREEN_ROWS-1] and col to [0, SCREEN_COLS-1] before adding the coord bias.

**From Story 1.3:**
- `inc/state.inc` declares `shadow_buffer` (1920 bytes), `dirty_rows` (3 bytes), `top_line_offset` (2 bytes), `cursor_offset` (2 bytes), `gap_start` / `gap_end` (2 bytes each), `status_buffer` (80 bytes), `status_dirty` (1 byte), `GAP_BUFFER_BASE` (positional). All read/written by render.asm via state.inc symbols (MC7).
- **Story 1.3 deferral on shadow_buffer alignment is resolved here (AC15).** Decision: no page-alignment slack; indexing math uses shift-and-add.
- Static block has no zero-init until Story 1.12 (Story 1.3 deferral on zero-init). Render.asm tests pre-zero the state fields they touch (shadow, dirty_rows, top_line_offset, cursor_offset) at test start — the same pattern parser tests use.

**From Story 1.4:**
- `inc/bdos.inc`'s `BDOS_CALL` macro is the AR15 gateway. Render.asm does NOT use it (no BDOS calls). AC11 grep verifies.
- `BIOS_CONOUT` placeholder at 0xFA0C in `inc/bios.inc` (line 35). Story 1.12 confirms the real address; render.asm uses the symbol.
- **The `IFNDEF BIOS_CONOUT` guard added to `inc/bios.inc` in this story** enables test-side override (AC17). Production effect: zero (no caller pre-DEFINEs the symbol).

**From Story 1.5:**
- `src/statusln.asm` owns `status_set_message` (MC5 / AR12 funnel) and the `status_buffer` / `status_dirty` state declarations are in `inc/state.inc` (Story 1.3). Render.asm reads `status_buffer` to emit the status row and clears `status_dirty` after emit (read-modify-write, NOT writing the buffer — AR12 holds on the buffer-WRITE side).
- **The Story-1.5 `status_render` stub is retired by this story (AC9).** Default: remove the symbol from statusln.asm's public list. Alternative: trampoline. Dev's choice; default is removal.

**From Story 1.6:**
- `make test` from project root runs the headless harness. Five new `render_*.asm` cases added under `test/cases/`. The harness picks them up automatically (no test/Makefile edits).
- `test/inc/test_prologue.inc` (ORG 0x0100, sentinel pre-zero) + `test/inc/test_epilogue.inc` (test_pass / test_fail) + `test/inc/test_input_loop_stub.inc` (resolves bdos_error_funnel) are unchanged by this story.

**From Story 1.7:**
- `src/gapbuf.asm` owns the gap buffer (`gap_start`, `gap_end`, `cursor_offset`). Render.asm READS these (and `GAP_BUFFER_BASE`) to walk the two-halves for cell content — AR14 holds (render.asm does not CALL gapbuf_insert/delete/move_gap; AC12 grep verifies).
- The two-halves walk pattern: if logical_offset < (gap_start - GAP_BUFFER_BASE), physical = GAP_BUFFER_BASE + logical_offset; else physical = gap_end + (logical_offset - (gap_start - GAP_BUFFER_BASE)). Implemented in render.asm's internal `render_byte_at_logical` helper. Renderer's tests set up gap state directly (LD (gap_start), HL etc.) to construct synthetic gap-buffer configurations.

**From Story 1.8:**
- `src/input.asm`'s RI5 Esc-disambig path is unrelated to render. Render runs AFTER input + dispatch per the architecture data flow (line 1466-1502).

**From Story 1.9:**
- `src/dispatch.asm`'s `dispatch_normal` table has a `0x0C → mode_full_refresh_stub` entry (line 441-442). Story 1.11 replaces the stub body with a `JP render_full` (AC8). Table entry unchanged (or optionally inlined to `DEFW render_full` for a 3-byte savings — implementation choice).
- The dispatch.asm forward-reference pattern (dispatch_normal references handlers in the same file; first pass tolerates, second pass resolves) extends naturally to cross-file forward references — already exercised by Story 1.10's parser_handle_* references.

**From Story 1.10:**
- `src/parser.asm` is the immediate predecessor and the closest structural prior art. Mirror its header-block style, contract-comment shape, and module-organization (Public entry points / Internal helpers / Section dividers via `;;`).
- The `parser_dispatch` CALL .invoke / JP (HL) trampoline pattern is the prior art for render.asm's tail-JP usage (`render_full` JPs to `render_diff`; the Ctrl-L handler JPs to `render_full`).
- Test scaffold pattern: prologue → body → epilogue → AR25-order production INCLUDEs → input_loop_stub → state.inc LAST. Render tests follow the same shape.
- **No new state.inc fields, equates, message strings, or mode IDs** — same as Story 1.10. Render.asm consumes only existing symbols.

### Git intelligence

Ten commits on `main` after Story 1.0 (most-recent first per `git log`):

- `e9f291a` — story 1.10: Wrote the command parser: counts, pending operators, and the gg motion-prefix.
- `6084103` — story 1.9: Wrote the key dispatcher: binary-searches a per-mode table to find the handler.
- `5f5577e` — story 1.8: Wrote the input layer; tells Esc from arrows in ~40ms, with putback.
- `11a4560` — story 1.7: Wrote the gap buffer (insert, delete, move, load stub) with headless tests.
- `42af237` — story 1.6: make test builds, runs, and grades every test case off stdout.
- `b7ca9a8` — story 1.4: every BDOS call now goes through a macro that catches errors.
- `a298547` — story 1.3: Laid out the editor's full memory map at fixed addresses, build-time guarded.
- `eac5ba3` — story 1.2: Named every constant the editor needs, in three .inc headers, wired in.
- `b561c9e` (or similar) — story 1.5: every status message now goes through one funnel.
- `b561c9e` — story 1.1: Set up the VIBE build: Makefile pins sjasmplus 1.23.0, produces vibe.com.

Conventions visible in the tree (preserve in Story 1.11):
- 4-space indentation, UPPERCASE mnemonics, `;` line / `;;` section comments (AR24).
- AR23 header blocks on every `.asm` and `.inc` file. The new `src/render.asm` follows the same shape.
- Every public routine and internal helper has the `In:` / `Out:` / `Trashes:` / `Calls:` four-line contract (AR23).
- One story per commit; short imperative subject + colon-separated context. Match the user's plain-English style.

Suggested commit message for Story 1.11 (when the dev finishes): `story 1.11: Wrote the render pipeline: dirty rows, shadow diff, scroll, and the only BIOS_CONOUT site in the editor.` Match the user's "tells Esc from arrows" / "Wrote the gap buffer" / "binary-searches a per-mode table" / "counts, pending operators, and the gg motion-prefix" plain-English style.

### Testing requirements

Story 1.11's testing requirements split into two categories:

**Build-time / static (verifiable in this story):**

1. `make` from project root succeeds (AC19).
2. `make clean && make` produces byte-identical `vibe.com` across two consecutive runs (NFR18 / AC19). Capture both SHAs in Debug Log References.
3. `grep -rnE 'BIOS_CONOUT' src/` excluding render.asm: zero matches (AR13 / AC10 / AC19).
4. `grep -nE 'gapbuf_(insert|delete|move_gap|init|load)' src/render.asm`: zero matches (AR14 / AC12 / AC19).
5. `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY|BDOS_CALL' src/render.asm`: zero matches (AR15 / AC11 / AC19).
6. `make -C test test`: 22 pass / 1 fail (AC16). Capture verbatim in Debug Log References.

**Headless test cases (this story):**

7. `render_diff-no-changes.asm` — idle frame emits only trailing cursor (NFR1 + RI4).
8. `render_diff-single-row-change.asm` — single dirty row, single contiguous run (FR47).
9. `render_diff-contiguous-runs.asm` — two runs in one row produce two ESC Y emits (FR47 + NFR1).
10. `render_full-marks-all-dirty.asm` — mark_all_dirty sets all 24 bits; render_full clears them post-pass (AC3, AC7).
11. `render_scroll-cursor-below-visible.asm` — V2 scroll advances top_line_offset (AC4 step 1).

**UAT (deferred to Story 1.12 hardware bring-up):**

12. Real-VT52 emission: `ESC Y row col` sequences produce visible cursor positioning on actual MicroBeast hardware. Iz-cpm's adm3a emulation is close enough for byte-stream verification but not for visual correctness.
13. NFR7: drift recovery via Ctrl-L. The render layer's correctness is necessary but not sufficient — only on-hardware UAT confirms that `Ctrl-L` actually recovers a desynced screen.
14. Sustained-typing throughput (NFR2 on hardware): the diff render's idle-no-emission contract is verified headlessly, but the inter-keystroke render cost on the serial line is hardware-only.

### Project Structure Notes

After Story 1.11 the source tree is:

```
src/
├── vibe.asm        # Top-level (now INCLUDEs render.asm between gapbuf and dispatch per AR25)
├── input.asm       # Story 1.8 (unchanged)
├── statusln.asm    # Story 1.5 (- Story 1.11 retires status_render stub; otherwise unchanged)
├── gapbuf.asm      # Story 1.7 (unchanged)
├── render.asm      # Story 1.11 — NEW (render pipeline, dirty rows, scroll, Ctrl-L; sole BIOS_CONOUT site)
├── dispatch.asm    # Story 1.9 (- Story 1.10: 16 new entries; - Story 1.11: Ctrl-L handler points at render_full)
└── parser.asm      # Story 1.10 (unchanged)

inc/
├── equates.inc     # Story 1.2 (unchanged)
├── bios.inc        # Story 1.4 (- Story 1.11 adds IFNDEF guards around BIOS_CONOUT and BIOS_TICK_ADDR for test override)
├── bdos.inc        # Story 1.4 (unchanged)
├── modes.inc       # Story 1.2 (unchanged)
├── vt52.inc        # Story 1.2 (unchanged — render.asm consumes VT52_ESC / VT52_CLEAR_SCREEN / VT52_GOTO / VT52_COORD_BIAS)
└── state.inc       # Story 1.3 (unchanged — render.asm consumes shadow_buffer / dirty_rows / top_line_offset / cursor_offset / gap_start / gap_end / status_buffer / status_dirty / GAP_BUFFER_BASE)

test/
├── README.md
├── Makefile
├── inc/
│   ├── test_prologue.inc
│   ├── test_epilogue.inc
│   ├── test_input_loop_stub.inc
│   └── test_bios_conout_capture.inc        # Story 1.11 — NEW (optional, if extracted from per-test stubs)
├── cases/
│   ├── ... (Story 1.6/1.7/1.9/1.10 cases unchanged)
│   ├── render_diff-no-changes.asm          # Story 1.11 — NEW
│   ├── render_diff-single-row-change.asm   # Story 1.11 — NEW
│   ├── render_diff-contiguous-runs.asm     # Story 1.11 — NEW
│   ├── render_full-marks-all-dirty.asm     # Story 1.11 — NEW
│   └── render_scroll-cursor-below-visible.asm  # Story 1.11 — NEW
├── fixtures/
│   └── hello.txt
└── smoke/
    ├── bdos_call_smoke.asm
    └── statusln_smoke.asm
```

Architecture's reference layout (architecture.md lines 1278-1339) anticipates exactly this — `src/render.asm` between `src/gapbuf.asm` (Story 1.7) and `src/dispatch.asm` (Story 1.9). The AR25 sequence (`init → input → statusln → gapbuf → render → dispatch → parser → ...`) is now physically realised in `src/vibe.asm`'s INCLUDE block.

### Files created and modified by this story

**Files created by this story:**
- `src/render.asm` (new — primary deliverable).
- `test/cases/render_diff-no-changes.asm` (new).
- `test/cases/render_diff-single-row-change.asm` (new).
- `test/cases/render_diff-contiguous-runs.asm` (new).
- `test/cases/render_full-marks-all-dirty.asm` (new).
- `test/cases/render_scroll-cursor-below-visible.asm` (new).
- Optional: `test/inc/test_bios_conout_capture.inc` (new — shared BIOS_CONOUT override stub; only if extracted from per-test inline definitions).

**Files modified by this story:**
- `src/vibe.asm` — add `INCLUDE "render.asm"` between gapbuf.asm and dispatch.asm INCLUDEs (per AR25); update header `Dependencies:` line; update the dispatch.asm-INCLUDE-block preceding comment.
- `src/dispatch.asm` — replace `mode_full_refresh_stub` body with `JP render_full` (or rename and re-point the dispatch_normal entry); update routine contract block; update header `Dependencies:` line to add `src/render.asm (Story 1.11)`.
- `src/statusln.asm` — remove `status_render` (default) OR convert to thin trampoline (alternative); update Public list in header; remove the Story-1.5 STUB comment block.
- `inc/bios.inc` — add `IFNDEF BIOS_CONOUT` guard around line-35 EQU; add `IFNDEF BIOS_TICK_ADDR` guard around line-65 EQU. Both for test-side override (AC17). Production effect: zero.
- `_bmad-output/implementation-artifacts/deferred-work.md` — mark Story-1.2 (VT52 clamp) and Story-1.3 (shadow_buffer alignment) entries as resolved with reference to Story 1.11.

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md] lines 722-779
- Adjacent story (parser, Story 1.10 — previous; structural prior art): [Source: _bmad-output/implementation-artifacts/1-10-command-parser-count-pending-operator-motion-prefix.md]
- Adjacent story (init/teardown + on-hardware smoke, Story 1.12 — next; wires render.asm into the main loop): [Source: _bmad-output/planning-artifacts/epics.md] lines 781-846
- RI1 (per-row dirty bitmap + per-cell diff): [Source: _bmad-output/planning-artifacts/architecture.md] lines 559-565
- RI2 (render runs after each input-loop iteration; no periodic timer): [Source: _bmad-output/planning-artifacts/architecture.md] lines 567-569
- RI3 (Ctrl-L = full redraw + dirty-bitmap clear): [Source: _bmad-output/planning-artifacts/architecture.md] lines 571-573
- RI4 (cursor-positioning emission last in every render pass): [Source: _bmad-output/planning-artifacts/architecture.md] lines 575-579
- MC1 (caller-saved everywhere): [Source: _bmad-output/planning-artifacts/architecture.md] lines 472-476
- MC4 (handler signature: A = key just consumed, accumulator state in fixed addresses): [Source: _bmad-output/planning-artifacts/architecture.md] lines 529-533
- MC5 (status-message funnel — `status_set_message`): [Source: _bmad-output/planning-artifacts/architecture.md] lines 535-541
- MC7 (static memory map via state.inc): [Source: _bmad-output/planning-artifacts/architecture.md] lines 550-555
- SR1 (cursor = 16-bit absolute buffer offset): [Source: _bmad-output/planning-artifacts/architecture.md] lines 426-431
- SR2 (gap-buffer two-halves invariant): [Source: _bmad-output/planning-artifacts/architecture.md] lines 433-439
- SR3 (cursor-to-buffer mapping): [Source: _bmad-output/planning-artifacts/architecture.md] lines 441-445
- SR7 (no line-position cache in MVP): [Source: _bmad-output/planning-artifacts/architecture.md] lines 463-468
- V2 (scroll mechanism — top_line_offset; cursor must stay in rows 0..22): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1652-1660
- W2 (cursor row/col recompute bounded by visible-region size): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1640-1642
- FR47 (diff render): [Source: _bmad-output/planning-artifacts/epics.md] line 93, [Source: _bmad-output/planning-artifacts/prd.md] lines 784-786
- FR48 (Ctrl-L full refresh): [Source: _bmad-output/planning-artifacts/epics.md] line 94, [Source: _bmad-output/planning-artifacts/prd.md] line 787
- FR49 (status line on row 24): [Source: _bmad-output/planning-artifacts/epics.md] line 95 (implicit), [Source: _bmad-output/planning-artifacts/prd.md] lines 788-789
- NFR1 (incremental rendering): [Source: _bmad-output/planning-artifacts/epics.md] line 107, [Source: _bmad-output/planning-artifacts/prd.md] lines 811-814
- NFR3 (predictable cursor-motion latency): [Source: _bmad-output/planning-artifacts/prd.md] lines 820-824
- NFR7 (screen-state recoverability): [Source: _bmad-output/planning-artifacts/epics.md] line 116, [Source: _bmad-output/planning-artifacts/prd.md] lines 839-841
- NFR9 (code-size budget ~3 KB): [Source: _bmad-output/planning-artifacts/epics.md] line 121
- NFR16 (knob centralization): [Source: _bmad-output/planning-artifacts/epics.md] line 134
- AR11 (state.inc static memory map): [Source: _bmad-output/planning-artifacts/epics.md] line 157
- AR12 (status-message funnel): [Source: _bmad-output/planning-artifacts/epics.md] line 161
- AR13 (single screen-emission path — render.asm only): [Source: _bmad-output/planning-artifacts/epics.md] line 162
- AR14 (single buffer-mutation owner — gapbuf.asm only): [Source: _bmad-output/planning-artifacts/epics.md] line 163
- AR15 (single BDOS gateway — BDOS_CALL macro): [Source: _bmad-output/planning-artifacts/epics.md] line 164
- AR16 (status-message string-table convention): [Source: _bmad-output/planning-artifacts/epics.md] line 165
- AR21 (headless coverage scope — render math explicitly named): [Source: _bmad-output/planning-artifacts/epics.md] line 173
- AR22 (naming): [Source: _bmad-output/planning-artifacts/epics.md] line 177
- AR23 (file structure and routine contracts): [Source: _bmad-output/planning-artifacts/epics.md] line 178
- AR24 (format conventions): [Source: _bmad-output/planning-artifacts/epics.md] line 179
- AR25 (module include order — `init → input → statusln → gapbuf → render → dispatch → parser → ...`): [Source: _bmad-output/planning-artifacts/epics.md] line 180, [Source: _bmad-output/planning-artifacts/architecture.md] lines 942-951
- Module dependency graph (render.asm sole BIOS_CONOUT writer): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1404-1432
- Data-flow keystroke lifecycle (step 6 = render_diff fires after handler returns): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1466-1502
- FR-to-module mapping (FR47 → render.asm; FR48 → render.asm + Ctrl-L dispatch; FR49 → statusln.asm + render.asm): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1527-1529
- NFR-to-enforcement (NFR1 = render.asm diff-only emit; NFR7 = render.asm Ctrl-L path): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1538, 1544
- inc/state.inc render-state declarations (shadow_buffer / dirty_rows / top_line_offset / cursor_offset / gap_start / gap_end / status_buffer / status_dirty / GAP_BUFFER_BASE): [Source: inc/state.inc] lines 65-78, 84-95, 102-106
- inc/equates.inc render-geometry declarations (SCREEN_ROWS / SCREEN_COLS / EDITABLE_ROWS / STATUS_ROW / STATUS_LINE_WIDTH / DIRTY_ROWS_BITMAP_BYTES): [Source: inc/equates.inc] lines 42-47
- inc/vt52.inc render-emit declarations (VT52_ESC / VT52_CLEAR_SCREEN / VT52_GOTO / VT52_COORD_BIAS): [Source: inc/vt52.inc] lines 23-33
- inc/bios.inc BIOS_CONOUT declaration (line 35) + IFNDEF guard added by this story: [Source: inc/bios.inc] line 35
- src/dispatch.asm Ctrl-L stub being replaced (mode_full_refresh_stub at lines 286-300; dispatch_normal entry at lines 441-442): [Source: src/dispatch.asm] lines 286-300, 441-442
- src/statusln.asm status_render stub being retired (lines 138-154): [Source: src/statusln.asm] lines 138-154
- src/gapbuf.asm two-halves walk prior art (gap_start / gap_end / GAP_BUFFER_BASE read pattern): [Source: src/gapbuf.asm] lines 79-117, 142-176, 194-249
- src/parser.asm structural prior art (header-block style, contract comments, tail-JP idiom): [Source: src/parser.asm] full file
- test/cases/parser_compose-count-op-motion.asm prior-art for synthetic state setup + capture buffers: [Source: test/cases/parser_compose-count-op-motion.asm] lines 1-198
- Deferred-from-1.2 (VT52_GOTO clamp): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 11
- Deferred-from-1.3 (shadow_buffer alignment): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 17

## Dev Agent Record

### Agent Model Used

Claude Opus 4.7 (1M context). The `bmad-dev-story` skill (vibe project install).

### Debug Log References

**Byte-identical rebuild (NFR18 / AC19):**

Two consecutive `make clean && make` runs from a clean tree produced byte-identical `vibe.com`:

```
SHA1=722569efc97365a3172c8496318b3ca33bd8cb921b5e0d64f55f8402a0d7c0b1
SHA2=722569efc97365a3172c8496318b3ca33bd8cb921b5e0d64f55f8402a0d7c0b1
```

**AR13 / AR14 / AR15 grep sweeps (AC10 / AC11 / AC12 / AC19):**

```
$ grep -nE 'BIOS_CONOUT' src/*.asm | grep -v 'render.asm'
(empty — AR13 clean: render.asm is the sole production BIOS_CONOUT site)

$ grep -nE 'gapbuf_(insert|delete|move_gap|init|load)' src/render.asm
(empty — AR14 clean: render.asm does not call the mutating gap-buffer primitives)

$ grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY|BDOS_CALL' src/render.asm
(empty — AR15 clean: render.asm makes zero BDOS calls)
```

**`make -C test test` output (AC16 / AC19):**

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
  pass     parser_compose-count-op-motion
  pass     parser_count-accumulator
  pass     parser_doubled-operator-dd
  pass     parser_leading-zero-is-motion
  pass     parser_motion-prefix-cleared-on-other-key
  pass     parser_motion-prefix-gg
  pass     parser_zero-after-digit
  pass     render_diff-contiguous-runs
  pass     render_diff-no-changes
  pass     render_diff-single-row-change
  pass     render_full-marks-all-dirty
  pass     render_scroll-cursor-below-visible

  22 pass, 1 fail
```

The single fail is the deliberate `harness_fail` smoke from Story 1.6 — the harness baseline this story expected.

**Module sizes after Story 1.11:**

```
   541 src/dispatch.asm
   286 src/gapbuf.asm
   190 src/input.asm
   514 src/parser.asm
  1182 src/render.asm
   174 src/statusln.asm
   119 src/vibe.asm
  3006 total
```

`src/render.asm` is the largest module to date (~1180 lines including comment header) — expected for the routine that owns the diff/scroll/Ctrl-L pipeline + the contiguous-run emit + the scroll-adjust walk + the cell-read SR3 mapping.

### Completion Notes List

- **`render_emit_goto` register choice (bug fix during dev).** First implementation held the biased col in `C` across the four `render_emit_byte` calls. Each `render_emit_byte` does `LD C, A` (clobbering C) before the `CALL BIOS_CONOUT`, so the fourth byte emitted was `B` (the biased row) instead of the biased col — `render_diff-single-row-change` caught this with sentinel 0xE9, diagnostic 0x20 (expected col-5 = 0x25). Fix: hold biased row in `D` and biased col in `E`, neither of which `render_emit_byte` touches. Contract updated: `Trashes: A, BC, DE, F`.

- **`render_count_rows_to_cursor` DE preservation (bug fix during dev).** First implementation cached `cursor_offset` in `DE` once at routine entry and relied on it across `CALL render_byte_at_logical` in the loop body. But `render_byte_at_logical` loads `(render_file_length)` into DE internally — DE comes back trashed. The `SBC HL, DE` termination check then compared against `file_length` (30) instead of `cursor_offset` (25), making `count_rows` over-count by 5 and `render_advance_lines` skip 8 line-breaks instead of 3. `render_scroll-cursor-below-visible` caught this with sentinel 0xE1, diagnostic 0x08. Fix: reload `DE = (cursor_offset)` at the top of every loop iteration.

- **BIOS_CONOUT override mechanism (AC17 implementation).** AC17's "Recommended" option (b) was the chosen mechanism: an IFNDEF guard around the production EQU in `inc/bios.inc`. sjasmplus 1.23.0's `IFNDEF` is keyed on `DEFINE`-created markers (not bare EQU symbols), so the guard tests `BIOS_CONOUT_OVERRIDE` (a DEFINE marker the test sets) rather than `BIOS_CONOUT` directly. The same wrapping was added for `BIOS_TICK_ADDR` (guarded by `BIOS_TICK_ADDR_OVERRIDE`) for symmetry against future input-layer tests.

- **status_render retirement (AC9, default path).** The Story-1.5 `status_render` stub was removed entirely from `src/statusln.asm`. Public list shortened to `status_set_message` + `bdos_error_funnel`; the Story-1.5 STUB comment block was excised. A tombstone comment in the Public block points readers at `src/render.asm` for the new emit path. There were no production or test callers of `status_render`, so removal is non-breaking.

- **Ctrl-L stub body rewrite (AC8, JP render_full form).** The dispatch.asm `mode_full_refresh_stub` body collapsed from 8 bytes (`LD HL, msg / XOR A / CALL status_set_message / RET`) to 3 bytes (`JP render_full`) — a net 5-byte savings (architecture line 162's "init's initial clear is the only declared exception" is retired, and the stub's old `status_set_message` call no longer fires). The dispatch_normal table entry at 0x0C still references `mode_full_refresh_stub`; the `_stub` suffix is now strictly nominal but renaming would churn the table without changing behaviour.

- **No new state.inc fields (AC1 / Story 1.3 commitment honoured).** Render scratch (`render_gap_log`, `render_after_gap_base`, `render_file_length`, `render_read_pos`, `render_shadow_ptr`, `render_walk_rowstart`, `render_cursor_row`, `render_cursor_col`, `render_row`, `render_col`, `render_past_eol`, `render_in_run` — 16 bytes total) lives in the code segment as `DEFW`/`DEFB` at the end of `src/render.asm`. The initial values are inert at .com load (every routine writes-before-reads within a single `render_diff` invocation), and there is zero state.inc churn.

- **Page-alignment decision (AC15 resolution).** Confirmed `shadow_buffer` stays in its Story-1.3 layout slot, NOT page-aligned. Cell-addressing math uses `HL = row` followed by four `ADD HL,HL` (= ×16), then `DE = HL` (save row*16) and two more `ADD HL,HL` (= ×64), then `ADD HL,DE` (= ×80). Each cell index costs ~14 T-states on the row-base compute; the cell itself is `ADD HL,DE` (col extend). Subject to a future profiling-driven story if the per-cell cost shows in NFR3 metrics.

- **Pre-existing test breakage uncovered during 1.11 wiring.** When the dispatch + parser tests were rebuilt against the post-1.11 sources, three classes of pre-existing-but-latent issues surfaced and were fixed in-scope: (a) `dispatch_*.asm` tests did not INCLUDE `inc/vt52.inc` (now needed since `src/dispatch.asm` transitively pulls in `render.asm` symbols via the Ctrl-L tail-JP) — added the INCLUDE; (b) `dispatch_*.asm` tests did not INCLUDE `src/parser.asm` (needed since Story 1.10 — `dispatch_normal` references `parser_handle_digit`/`_operator`/`_motion_prefix`) — added the INCLUDE; (c) `parser_*.asm` tests likewise needed `src/render.asm` to resolve the `render_full` reference in `mode_full_refresh_stub`'s new body. All three test classes now build clean.

- **`dispatch_mode-transition` step 7 rewrite.** The old step-7 asserted "Ctrl-L sets status_dirty" — true under the Story-1.5 stub but false under the new render_full handler. Rewritten to (a) seed minimum render state (empty gap, top=0, cursor=0, shadow all 0x20, dirty_rows[0]=0x01), (b) install the BIOS_CONOUT capture override so the cursor reposition does not escape to iz-cpm stdout, (c) dispatch 0x0C, (d) assert dirty_rows[0] == 0 post-call (render_diff's terminal clear ran). Sentinel 0xE9 doc updated to match. iz-cpm cold-restarts when called at 0xFA0C (no installed BIOS at that address), so the override is mandatory in any test that exercises the render path.

- **Deferred items closed.** `deferred-work.md` entries for Story-1.2 (VT52_GOTO clamp) and Story-1.3 (shadow_buffer alignment) updated with resolution notes referencing Story 1.11. No new deferrals raised.

### File List

**Created:**
- `src/render.asm`
- `test/inc/test_bios_conout_capture.inc`
- `test/cases/render_diff-no-changes.asm`
- `test/cases/render_diff-single-row-change.asm`
- `test/cases/render_diff-contiguous-runs.asm`
- `test/cases/render_full-marks-all-dirty.asm`
- `test/cases/render_scroll-cursor-below-visible.asm`

**Modified:**
- `src/vibe.asm` — INCLUDE render.asm between gapbuf.asm and dispatch.asm; updated header `Dependencies:` and the AR25-ordering comment that previously noted render.asm did not yet exist.
- `src/dispatch.asm` — Ctrl-L handler body replaced with `JP render_full`; routine contract block updated; `Dependencies:` header gained `src/render.asm`.
- `src/statusln.asm` — `status_render` routine removed; Public block tombstone added; register-conventions block trimmed.
- `src/gapbuf.asm` — header comment scrubbed of the bare token `BIOS_CONOUT` so the AR13 grep stays clean (semantic unchanged: "no console emit").
- `inc/bios.inc` — `IFNDEF BIOS_CONOUT_OVERRIDE` and `IFNDEF BIOS_TICK_ADDR_OVERRIDE` guards added around their respective EQUs.
- `test/cases/dispatch_binary-search-finds-key.asm`, `test/cases/dispatch_binary-search-misses.asm` — added `inc/vt52.inc`, `src/parser.asm`, `src/render.asm` INCLUDEs to resolve the post-1.10/1.11 symbol dependencies in `src/dispatch.asm`.
- `test/cases/dispatch_mode-transition.asm` — same INCLUDE additions as the other dispatch tests, plus BIOS_CONOUT capture override at the top, plus step 7's Ctrl-L assertion rewritten to verify dirty_rows clearing rather than the retired status_dirty side effect.
- `test/cases/parser_compose-count-op-motion.asm`, `parser_count-accumulator.asm`, `parser_doubled-operator-dd.asm`, `parser_leading-zero-is-motion.asm`, `parser_motion-prefix-cleared-on-other-key.asm`, `parser_motion-prefix-gg.asm`, `parser_zero-after-digit.asm` — added `inc/vt52.inc` and `src/render.asm` INCLUDEs (the parser tests pull in `src/dispatch.asm`, which now transitively references `render_full`).
- `_bmad-output/implementation-artifacts/deferred-work.md` — Story-1.2 (VT52_GOTO clamp) and Story-1.3 (shadow_buffer alignment) entries marked resolved with Story-1.11 resolution notes.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `1-11-render-pipeline-with-dirty-rows-scroll-ctrl-l: review`; `last_updated` annotation refreshed.

### Change Log

- 2026-05-11: Story 1.11 implementation landed. Render pipeline (`src/render.asm`) implements RI1-RI4: per-row dirty diff (`render_diff`), Ctrl-L full redraw (`render_full`), V2 scroll via `top_line_offset`, status-row emit gated by `status_dirty`, RI4 trailing cursor reposition. `render_emit_goto` clamps row/col before `VT52_COORD_BIAS` add (resolves Story-1.2 deferral). `shadow_buffer` stays unaligned per Story-1.3 deferral resolution. 5 new headless tests under `test/cases/render_*.asm` plus a shared `test/inc/test_bios_conout_capture.inc`. `inc/bios.inc` gained `BIOS_CONOUT_OVERRIDE` / `BIOS_TICK_ADDR_OVERRIDE` IFNDEF markers (zero production effect). `src/dispatch.asm` Ctrl-L stub body re-pointed at `render_full`. `src/statusln.asm` `status_render` stub retired (no callers). AR13 / AR14 / AR15 grep sweeps clean. Byte-identical rebuild verified across two `make clean && make` cycles. Headless test suite: 22 pass / 1 deliberate-fail (`harness_fail`) — the AC16 baseline.

### Review Findings

Code review run 2026-05-11 — three parallel layers (Blind Hunter / Edge Case Hunter / Acceptance Auditor). 4 decision-needed (all resolved → patches), 5 patch — 9 total applied; 7 deferred, 6 dismissed. 22 pass / 1 deliberate-fail (harness_fail) after the patches; AR13 / AR14 / AR15 grep sweeps clean.

- [x] [Review][Decision→Patch] **Module-local scratch in code segment vs. `state.inc`** — Resolution: **accept the precedent**. Added a Policy paragraph at the scratch block in `src/render.asm` clarifying that module-private writable scratch may live in the module's code segment; Story-1.3 MC7 applies to state that crosses module boundaries.
- [x] [Review][Decision→Patch] **V2 retreat scroll asymmetry vs spec wording** — Resolution: **update spec to authorize row-0-pin**. AC4 step 1's retreat sub-bullet rewritten to describe the pin-to-cursor's-line behaviour explicitly and call out the asymmetry as a deliberate MVP choice.
- [x] [Review][Decision→Patch] **`src/render.asm` unilaterally retires an architecture-doc rule** — Resolution: **update architecture doc**. `_bmad-output/planning-artifacts/architecture.md` updated (CONOUT carve-out paragraph and External Boundaries row) to drop the init.asm exception. `src/render.asm` header comment reworded to reference the now-current rule rather than a stale line number.
- [x] [Review][Decision→Patch] **`inc/bios.inc` `BIOS_TICK_ADDR_OVERRIDE` dead guard** — Resolution: **drop until a test needs it**. The `IFNDEF` / `ENDIF` block removed; `BIOS_TICK_ADDR EQU 0xFA00` stays as the unconditional placeholder.

- [x] [Review][Patch] **8-bit row counter wraps + AC5 walk-budget violation** — Fixed by capping B at `EDITABLE_ROWS` inside `render_count_rows_to_cursor`'s loop; once B reaches the cap the routine exits early with `A == EDITABLE_ROWS` as a "cursor below visible" signal. `render_scroll_adjust`'s cursor≥top branch rewritten as an iterate-then-advance loop: each iteration calls count_rows; if A==EDITABLE_ROWS, advance top by 1 LF and retry. New `render_scroll_did_advance` module-private flag records whether the iteration produced any advance, so `mark_all_editable` only runs on actual scroll. New iterative-advance worst-case scan cost added to deferred-work (relevant to epic 2 G / gg motions).
- [x] [Review][Patch] **HL high-byte truncation in cursor_col clamp (advance branch)** — Fixed: `LD A, H / OR A / JR NZ, .col_clamp_max` added before the `LD A, L / CP SCREEN_COLS` test in `render_scroll_adjust`.
- [x] [Review][Patch] **Same HL high-byte truncation on retreat path** — Same H-byte test idiom applied to `.ret_col_ok`.
- [x] [Review][Patch] **Stale comment in `dispatch_mode-transition.asm` claimed no capture stub installed** — Comment rewritten to describe the actual `BIOS_CONOUT_OVERRIDE` / `test_bios_conout` capture flow.
- [x] [Review][Patch] **`IX` listed in Trashes docstrings but no routine touches `IX`** — `IX` dropped from all seven `Trashes: A, BC, DE, HL, IX, F` declarations across `render.asm`. Now reads `Trashes: A, BC, DE, HL, F`.

- [x] [Review][Defer] **TAB / CR / NUL / high-bit bytes render raw and desync shadow vs physical screen** [src/render.asm render_emit_one_row + render_emit_status_row cell loops] — `byte_at_logical` returns the raw byte; cell loop emits via `render_emit_byte` and writes to shadow. TAB (0x09) advances VT52 cursor 8 cells on screen but shadow stores 0x09 at one cell → cells past the TAB never reconcile on subsequent frames. CR (0x0D) resets cursor to column 0 mid-row. NUL/0x80+ are terminal-dependent. Out of scope for Story 1.11; needs a design call (printable-only filter at emit, or vi-style ^X notation, or insertion-time canonicalization) — surface during input-text-handling stories.
- [x] [Review][Defer] **Sloppy `top_line_offset` (not at line start) silently honored in `.row_in_range`** [src/render.asm:554-556] — The in-range branch trusts the caller's `top_line_offset`. If it points mid-line (Story-1.7 paste or future-story bug), the display starts mid-line with no recovery. Defensive hardening (idempotent `render_find_line_start` call) was not specified by AC4 — caller-side invariant.
- [x] [Review][Defer] **`render_emit_goto` does not save D/E around `CALL render_emit_byte`** [src/render.asm:~1115-1140] — `emit_byte` declares it preserves D/E (contract holds in current impl), but the routine's own header says "BIOS may trash more". Latent until Story 1.12 hardware smoke confirms real BIOS_CONOUT register behavior.
- [x] [Review][Defer] **`render_in_run` not reset on `render_emit_status_row` exit when last cell differs** [src/render.asm:~990] — Currently safe because every emit_one_row / emit_status_row re-initializes `render_in_run` at row entry. Future standalone caller could pick up a stale 1.
- [x] [Review][Defer] **Per-cell shadow_ptr reload (`LD HL, (render_shadow_ptr) / ADD HL, DE`) inside hot row loop** — ~13 T-states × 80 cells × 23 rows ≈ measurable fraction of frame budget. NFR3 currently met on the test cases; optimization opportunity for follow-up.
- [x] [Review][Defer] **`test_capture_len` is 1 byte; wraps silently at 256** [test/inc/test_bios_conout_capture.inc:33-37] — Current tests stay under 256 bytes; a future test exceeding would silently wrap the capture buffer with no assertion. Harden when a render test needs a full-redraw capture.
