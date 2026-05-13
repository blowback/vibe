# Story 2.1: Ex command-line infrastructure + :q / :q!

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want a working `:` command-line where I can type `:q` to quit (refused if the buffer is dirty) or `:q!` to force-quit, with Backspace correcting typos and Esc cancelling cleanly,
So that VIBE exits through the proper vi mechanism — and the Story 1.12 Ctrl-Q debug-quit (and its `mode_debug_quit` handler) can be retired now that `:q` / `:q!` own the real exit paths.

## Acceptance Criteria

**AC1 — Entering COMMAND mode from `:` in NORMAL mode.**

**Given** I'm in NORMAL mode (`mode_byte == MODE_NORMAL`) and press `:` (0x3A)
**When** `dispatch_normal` resolves the entry and transfers control
**Then** `exline_begin` runs (NOT the Story-1.10 stub `enter_command_mode`, which is retired by this story — see AC9), and:
  - `mode_byte` is set to `MODE_COMMAND`
  - The length byte at `ex_buffer` is reset to 0 (length-prefixed buffer is now empty)
  - `status_buffer` is recomposed via the AR12 funnel (`status_set_message`) so the row reads `":"` at col 0 followed by 79 spaces — i.e., a clean status row showing just the `:` prompt
  - `status_dirty` is set so the next `render_diff` pass picks up the new status row
  - The handler RETs back into the input loop body

**And** the next `render_diff` invocation:
  - Emits the status row (status_dirty is set)
  - Reads `mode_byte` at the trailing cursor-reposition step (RI4), sees `MODE_COMMAND`, and overrides the cursor target: row = `STATUS_ROW` (23), col = `1 + (ex_buffer)` = 1 (after the `:` glyph)
  - Emits a single `ESC Y` placing the cursor at row 23 col 1

**AC2 — Typing characters in COMMAND mode appends to `ex_buffer`.**

**Given** I'm in `MODE_COMMAND` and a printable byte arrives via `input_get_key`
**When** the input loop's per-mode demultiplex picks `dispatch_command` and the binary search reaches the unbound-prefix fall-through
**Then** control transfers to `exline_append_literal` (the new `dispatch_command` unbound-prefix target, replacing the Story-1.9 silent-no-op `unbound_command`), which:
  - Filters non-printable bytes: any A < 0x20 or A >= 0x7F is silently dropped (RETs without state change) — this skips synthesised arrow keycodes (KEY_ARROW_* = 0x80..0x83) and stray control bytes
  - On a buffer-full condition (`ex_buffer` length == `EX_COMMAND_BUFFER` = 64): silently drops the byte (RETs without state change). Vi-spirit: no beep, no status banner — typing past the limit just stops registering. The user can still Backspace or Esc.
  - Otherwise: increments `ex_buffer`'s length byte, stores A at `ex_buffer + 1 + (old length)`, recomposes `status_buffer` via `exline_compose_status` (which calls `status_set_message` with `":<content>\0"` assembled in a file-local 66-byte scratch), sets `status_dirty`, RETs

**And** after the next `render_diff` the status row shows `":" + <typed content>` and the cursor sits at row 23 col `1 + new_length`

**AC3 — Backspace deletes the previous character in COMMAND mode.**

**Given** I'm in `MODE_COMMAND` with `ex_buffer` length > 0 and Backspace (0x08) arrives
**When** `dispatch_command`'s binary-search resolves the 0x08 entry
**Then** `exline_backspace` runs and:
  - Decrements `ex_buffer`'s length byte
  - Recomposes `status_buffer` via `exline_compose_status` (the `:` prompt plus the now-shorter content padded with spaces)
  - Sets `status_dirty`
  - RETs

**And** if `ex_buffer` length is already 0 on Backspace entry: silent RET (no underflow, no beep — same vi-spirit as the buffer-full case)

**And** after `render_diff` the cursor lands at row 23 col `1 + new_length` (one to the left of where it was, with the prior glyph erased by the diff's space write)

**AC4 — Esc cancels the ex-line and returns to NORMAL.**

**Given** I'm in `MODE_COMMAND` (any `ex_buffer` length) and Esc (0x1B) arrives
**When** `dispatch_command`'s binary-search resolves the 0x1B entry
**Then** `exline_cancel` runs (NOT `enter_normal_mode` — the Story-1.10 `dispatch_command` table's Esc-entry is re-pointed from `enter_normal_mode` to `exline_cancel` so that ex_buffer cleanup happens atomically with the mode switch) and:
  - `ex_buffer`'s length byte is reset to 0
  - `mode_byte` is set to `MODE_NORMAL`
  - `status_buffer` is composed via `status_set_message msg_mode_normal` (the empty-string banner — full-width space pad per AR16 / vi-convention "no banner in normal mode")
  - `status_dirty` is set
  - RETs

**And** after `render_diff` the status row is fully blank, the cursor returns to the buffer's `cursor_offset` row/col (the mode-aware RI4 override no longer fires because `mode_byte != MODE_COMMAND`), and the editor is back in NORMAL

**AC5 — Enter dispatches `ex_buffer` through the command table.**

**Given** I'm in `MODE_COMMAND` and Enter (0x0D, CR) arrives
**When** `dispatch_command`'s binary-search resolves the 0x0D entry
**Then** `exline_dispatch` runs, which:
  - Walks `exline_command_table` — a list of (null-terminated key string, 2-byte handler address) entries terminated by a zero-length key (single 0x00 byte)
  - For each table entry: compares the bytes at `ex_buffer + 1` (i.e. `ex_buffer_text`, see AC10) against the entry's key string, length-checked against the `ex_buffer` length byte. Match means full-string equality (same length AND same bytes).
  - On match: tail-JPs to the entry's handler (cmd_quit / cmd_quit_force for Story 2.1)
  - On no match (table walked to the terminator): sets `msg_not_editor_command` via `status_set_message`, then tail-JPs to `exline_cancel` (which clears `ex_buffer`, sets mode to NORMAL, and sets `status_dirty` — but `exline_cancel`'s own `status_set_message msg_mode_normal` would clobber the just-set error message; see Dev Notes on the "set message THEN cancel, with cancel skipping the normal banner" pattern)

**Note on the cancel/message ordering:** `exline_cancel` cannot blindly call `status_set_message msg_mode_normal` after the unknown-command path has already written an error — the empty banner would clobber the error the user needs to see. The dev resolves this by either:
  - (a) Splitting `exline_cancel` into a "core" (clear ex_buffer + set mode to NORMAL + set status_dirty) and a "banner" path (`status_set_message msg_mode_normal`), and having `exline_dispatch`'s no-match path call only the core; OR
  - (b) Having `exline_dispatch`'s no-match path set the error message AFTER calling the core cleanup.

Either is acceptable. Recommended: option (a) — name the core `exline_cancel_core` (clears ex_buffer + mode = NORMAL + sets status_dirty if not already set) and `exline_cancel` (calls core then writes msg_mode_normal). dispatch_command's Esc entry binds `exline_cancel`; `exline_dispatch`'s no-match path writes the error first, then JPs `exline_cancel_core`. See template skeleton in Dev Notes § Library/framework requirements.

**AC6 — `:q` on a clean buffer warm-boots to CCP.**

**Given** I'm in `MODE_COMMAND` with `ex_buffer` containing `q` (length 1, byte 'q' at `ex_buffer_text`), `buffer_dirty == 0`, and Enter arrives
**When** `exline_dispatch` matches the `q` table entry and tail-JPs to `cmd_quit`
**Then** `cmd_quit`:
  - Reads `buffer_dirty`; on zero, tail-JPs to `init_teardown` (src/init.asm) — the same teardown path Story 1.12 wired (uninstall user ISR via `MBB_SET_USR_INT`, then `render_init` for screen clear + cursor home, then `BDOS_CALL BDOS_EXIT` warm-boot)
  - Control transfers to CCP via BDOS function 0; does not return on a real CP/M host

**AC7 — `:q` on a dirty buffer refuses with `msg_no_write` and stays in NORMAL.**

**Given** I'm in `MODE_COMMAND` with `ex_buffer` containing `q`, `buffer_dirty != 0`, and Enter arrives
**When** `exline_dispatch` matches `q` and tail-JPs to `cmd_quit`
**Then** `cmd_quit`:
  - Reads `buffer_dirty`; on nonzero, sets `msg_no_write` (existing in statusln.asm — "no write since last change") via `status_set_message`
  - JPs to `exline_cancel_core` (which clears `ex_buffer`, sets `mode_byte = MODE_NORMAL`, sets `status_dirty` if not already set)
  - The msg_no_write banner remains in `status_buffer` (the core path does NOT write msg_mode_normal)
  - RET (back to input loop)

**And** the next `render_diff` shows the status row reading `"no write since last change"` (left-aligned, padded with spaces), mode is NORMAL, cursor returns to the file's `cursor_offset` row/col, and editor continues — BH5 compliant (architecture lines 699-702)

**AC8 — `:q!` unconditionally warm-boots regardless of dirty state.**

**Given** I'm in `MODE_COMMAND` with `ex_buffer` containing `q!` (length 2, bytes 'q' '!' at `ex_buffer_text` and `ex_buffer_text + 1`), buffer_dirty state irrelevant, and Enter arrives
**When** `exline_dispatch` matches the `q!` table entry and tail-JPs to `cmd_quit_force`
**Then** `cmd_quit_force` unconditionally tail-JPs to `init_teardown` — no `buffer_dirty` check; the user's `!` is the explicit consent to abandon (FR8 / architecture BH5)

**AC9 — Remove the Story-1.12 Ctrl-Q debug-quit hook.**

**Given** `dispatch.asm` post-Story 2.1
**When** I inspect `dispatch_normal`'s entry table
**Then** the `0x11` (Ctrl-Q) entry is removed — `mode_debug_quit` is no longer reachable from any dispatch path. The handler body (`mode_debug_quit: JP init_teardown`) is also removed from `dispatch.asm`. The ASSERT comparing `0x11 > 0x0C` is replaced by `ASSERT '/' > 0x0C` (the next entry's adjacent-pair assert chain is re-stitched).

**And** the now-orphaned `enter_command_mode` handler (Story 1.10 stub, dispatch_normal's `:` entry pointed there) is removed — `dispatch_normal`'s `:` entry is re-pointed to `exline_begin` (new, in src/exline.asm).

**And** the now-orphaned `unbound_command` handler (Story 1.9 silent-no-op stub, dispatch_command's unbound-prefix slot) is removed — `dispatch_command`'s unbound-prefix is re-pointed to `exline_append_literal` (new, in src/exline.asm). The literal-append path IS the "fall-through" semantic for COMMAND mode (mirrors how `unbound_insert` in INSERT mode is destined to become the literal-insert path in Story 2.8).

**And** the `dispatch_command` table loses its single Esc-only entry shape and gains three entries (Backspace 0x08, Enter 0x0D, Esc 0x1B), sorted ascending by ASCII; the Esc entry's handler is re-pointed from `enter_normal_mode` to `exline_cancel` (so the cancel path can clear `ex_buffer` and skip the duplicate mode banner write).

**And** statusln.asm's `msg_mode_command: DEFB "-- command --", 0` is removed (no longer referenced; ex_buffer's `:` prompt is the COMMAND-mode indicator).

**And** `dispatch.asm`'s header comments are swept clean of `mode_debug_quit` / `enter_command_mode` / `unbound_command` references; `Dependencies:` drops `inc/bdos.inc` (no BDOS call site remains in dispatch.asm — the `BDOS_CALL BDOS_EXIT` line that made dispatch.asm AR15's lone non-render-non-init carve-out is GONE) and drops the "Story 1.12 — init_teardown for mode_debug_quit's screen-clear-on-exit path" note (init_teardown is still depended on, but now via exline.asm's cmd_quit / cmd_quit_force — and that dependency lives in exline.asm's header, not dispatch.asm's).

**And** init.asm's header references to `mode_debug_quit` are reworded to point at exline.asm's `cmd_quit` / `cmd_quit_force` (init_teardown's caller-list updates: Story 1.12 said "mode_debug_quit's target"; Story 2.1 says "cmd_quit / cmd_quit_force's target").

**AC10 — Resolve the Story-1.3 deferral on `ex_buffer` length-byte naming.**

**Given** `inc/state.inc` post-Story 2.1
**When** I inspect the `ex_buffer` declaration
**Then** a new positional EQU lands:
```
ex_buffer_text   EQU ex_buffer + 1   ; first byte of ex_buffer payload (length-byte at ex_buffer)
```
**And** every read site for the ex_buffer payload (exline.asm's content walks, dispatch's compare loops, the test cases) reads via `ex_buffer_text`, NOT `ex_buffer + 1`. A grep of `src/*.asm` and `test/cases/exline_*.asm` for `ex_buffer\s*\+\s*1` outside of state.inc (the EQU declaration) yields zero matches.

**Note:** the sibling `search_pattern_text EQU search_pattern + 1` is deliberately NOT added by this story — search_pattern has no consumers until Story 3.1, and adding the symbol with no consumer surfaces an unused-symbol that future-self has to either justify or sweep. The Story-1.3 deferred-work entry's "ex/search consumer stories (2.1, 3.1)" splits the resolution at the obvious seam. Update `_bmad-output/implementation-artifacts/deferred-work.md` to mark the ex_buffer half resolved by Story 2.1 and leave the search_pattern half as deferred to Story 3.1.

**AC11 — render_diff places the cursor on the status row in COMMAND mode.**

**Given** `render_diff`'s tail-cursor-emit step (lines 384-389 of `src/render.asm` pre-Story 2.1)
**When** Story 2.1's mode-aware override lands
**Then** the final cursor-emit reads `mode_byte` before loading `render_cursor_row` / `render_cursor_col`. If `mode_byte == MODE_COMMAND`:
  - `render_cursor_row` is overridden to `STATUS_ROW` (= EDITABLE_ROWS = 23)
  - `render_cursor_col` is overridden to `1 + (ex_buffer)` (the length byte; col 0 holds the `:` glyph, col 1 is the first free slot)
**Else:** no change to the existing logic (the values set by `render_scroll_adjust` survive).

**And** `render.asm`'s header `Dependencies:` (currently lists state symbols `cursor_offset`, `gap_start`, `gap_end`, `top_line_offset`, `dirty_rows`, `shadow_buffer`, `status_buffer`, `status_dirty`, `GAP_BUFFER_BASE`) gains two read-only state symbols: `mode_byte` (new) and `ex_buffer` (new).

**And** `render.asm`'s `Dependencies:` block also lists `inc/modes.inc` (currently absent — render had no mode awareness pre-Story 2.1) for the `MODE_COMMAND` equate.

**Note on the byte-width of `ex_buffer`'s length byte vs `render_cursor_col`:** `render_cursor_col` is a single-byte cell (per state-shape inspection). `ex_buffer`'s length byte is 1..64 (bounded by AC2's buffer-full check). `1 + length` is at most 65 < SCREEN_COLS (80). The clamp inside `render_emit_goto` is therefore a no-op on the COMMAND-mode path; no edge case here.

**AC12 — Headless tests for `:q` / `:q!` exercise the full path under iz-cpm.**

**Given** four new headless tests under `test/cases/`:
  - `exline_q-clean-buffer.asm`
  - `exline_q-dirty-buffer.asm`
  - `exline_q-bang-force.asm`
  - `exline_unknown-command.asm`
**When** `make test` runs
**Then** all four cases pass under iz-cpm with the standard TH1 sentinel-byte protocol. Existing tests continue to pass; live baseline becomes at least **27 pass / 1 fail** (23 pre-2.1 + 4 new + the deliberate `harness_fail`).

**Test details:**

  - **`exline_q-clean-buffer.asm`:** sets `buffer_dirty = 0`, pre-loads `ex_buffer` to length 1 byte 'q', calls `exline_dispatch`. Defines a LOCAL `init_teardown:` stub that sets a `init_teardown_called` sentinel byte and RETs (so the test does not actually warm-boot iz-cpm). Asserts: sentinel set; `ex_buffer` length byte 0 (cleared by cmd_quit's path); `mode_byte = MODE_NORMAL` (cleared on the way out); status_dirty set. Local stubs for `MBB_SET_USR_INT` and `BIOS_CONOUT` (capture-stub from test_bios_conout_capture.inc, used by render_init transitively if cmd_quit's path reaches teardown) — but the local `init_teardown` stub doesn't call render_init, so the capture stub is optional.

  - **`exline_q-dirty-buffer.asm`:** sets `buffer_dirty = 1`, pre-loads `ex_buffer` to length 1 byte 'q', calls `exline_dispatch`. Asserts: `init_teardown` sentinel NOT set; `ex_buffer` length 0; `mode_byte = MODE_NORMAL`; `status_dirty` set; `status_buffer` opening bytes match `"no write since last change"` (the test reads status_buffer[0..25] and compares against msg_no_write).

  - **`exline_q-bang-force.asm`:** sets `buffer_dirty = 1` (intentionally dirty to verify the bypass), pre-loads `ex_buffer` to length 2 bytes 'q' '!', calls `exline_dispatch`. Local `init_teardown` stub sets sentinel + RET. Asserts: sentinel set; (mode_byte / ex_buffer state irrelevant — teardown owns the cleanup, and on a real run it warm-boots so post-teardown state is undefined).

  - **`exline_unknown-command.asm`:** pre-loads `ex_buffer` to length 3 bytes 'f' 'o' 'o' (unknown), calls `exline_dispatch`. Asserts: `init_teardown` sentinel NOT set; `ex_buffer` length 0; `mode_byte = MODE_NORMAL`; `status_dirty` set; `status_buffer` opening bytes match `"not an editor command"`.

**Each test INCLUDEs the production code under test in AR25 order** (statusln.asm + render.asm + dispatch.asm + parser.asm + exline.asm), plus `test_input_loop_stub.inc` for the bdos_error_funnel forward-reference symbol, plus a LOCAL `init_teardown:` stub (cmd_quit's tail-JP target). state.inc lands LAST per the standard AR25-final positioning.

**Test harness override needs:** the production `cmd_quit` / `cmd_quit_force` paths reach `init_teardown` via tail-JP. For the tests, the LOCAL stub MUST share the symbol name `init_teardown` (so the production exline.asm's JP resolves to it). This is the same pattern Story 1.12's `init_cold_start-state-shape` test used for `input_loop`.

**AC13 — Hardware UAT smoke confirms the new exit paths.**

**Given** UAT on hardware (Feersum MicroBeast)
**When** I:
  1. SLIDE-push (`make push`) and launch `vibe` from CCP
  2. Press `:` and observe the status row: clears to a single ':' at col 0; cursor sits at col 1
  3. Type 'q' (status row reads `:q`; cursor at col 2); press Backspace (status row reads `:`; cursor at col 1)
  4. Press 'q' again, press 'q' again (status row reads `:qq`); press Esc and observe the status row blank, mode returned to NORMAL, cursor back at the file's offset
  5. Press `:`, type `q`, press Enter; observe screen clear + return to CCP prompt (clean buffer path — AC6)
  6. Relaunch `vibe`; press `i` (enter INSERT — buffer_dirty is still 0 since insert literal-append isn't wired until Story 2.8, so AC7's "dirty buffer refuses" can't yet be exercised from real keystrokes — see Note below)
  7. Press Esc; press `:`, type `q`, type `!`, press Enter; observe screen clear + return to CCP (force path — AC8)
  8. Relaunch `vibe`; press `:`, type `f` 'o' 'o', press Enter; observe status row reads "not an editor command", mode returned to NORMAL, cursor back in the buffer area, editor continues
**Then** all eight steps behave as specified, no terminal corruption, no warm-boot from any non-quit step.

**Note on AC7 hardware UAT:** Until Story 2.8 lands the real INSERT-mode literal-append path, the user cannot organically dirty the buffer from the keyboard — INSERT mode's `unbound_insert` is still the Story-1.9 silent no-op. Story 2.1's AC7 hardware UAT therefore has two options:
  - (a) **Synthetic dirty marker:** add a temporary CALL site somewhere (e.g. in `exline_begin`) that sets `buffer_dirty = 1` for UAT purposes only, removed once Story 2.8 lands. This is what the spec proposes (epics.md line 894).
  - (b) **Defer AC7 hardware UAT to Story 2.8** and rely on the headless `exline_q-dirty-buffer.asm` test for Story 2.1 coverage.

Pick (b) — the headless test is deterministic and exercises the same code path; the synthetic-marker hack adds complexity and a "remove me later" footnote that's easy to leave behind. Document the deferral in the Story 2.1 Completion Notes and the Story 2.8 Dev Notes so 2.8 picks up the hardware-side AC7 confirmation.

**AC14 — Build invariants and AR enforcement.**

**Given** Story 2.1's source changes
**When** `make clean && make` runs twice consecutively
**Then**:
  - Both runs succeed (NFR14: sjasmplus 1.23.0 pinned via Makefile's `check-toolchain`)
  - The two resulting `vibe.com` files are byte-identical (NFR18 reproducibility). Capture both SHAs in Debug Log References.
  - `make sizes` reports the new code-section size (NFR9 ~3 KB budget). Capture verbatim. Expected growth: ~150-250 bytes over Story 1.12's ~1947 B baseline.

**AR enforcement sweeps (grep against `src/`):**
  - `grep -rnE 'BIOS_CONOUT' src/ | grep -v 'render.asm'` — zero matches (AR13: render owns every BIOS_CONOUT call site)
  - `grep -nE 'gapbuf_(insert|delete|move_gap|load)' src/exline.asm` — zero matches (AR14: exline doesn't mutate the gap buffer; cmd_quit's path goes through teardown, not edits)
  - `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/exline.asm` — zero matches (AR15: no raw BDOS calls; the BDOS gateway macro is the only path)
  - `grep -nE 'BDOS_CALL' src/exline.asm` — zero matches (exline doesn't directly call BDOS; cmd_quit / cmd_quit_force tail-JP to init_teardown, which is the only BDOS_CALL site outside the macro definition)
  - `grep -nE 'BDOS_CALL|CALL[ \t]+BDOS_ENTRY|CALL[ \t]+0x0005' src/dispatch.asm` — zero matches (the Story-1.12 `BDOS_CALL BDOS_EXIT` inside mode_debug_quit is GONE; dispatch.asm becomes AR15-clean)
  - `grep -nE 'ex_buffer\s*\+\s*1' src/*.asm test/cases/exline_*.asm | grep -v 'state.inc'` — zero matches (AC10: every read site uses `ex_buffer_text`, not raw `ex_buffer + 1`)

## Tasks / Subtasks

- [x] **Task 1: Create `src/exline.asm` (AC1-AC8)**
  - [x] Sub 1.1: AR23 header block — Module / Purpose / Public list / State owned / State read-only / Register conventions per entry point / Dependencies.
  - [x] Sub 1.2: Public entry `exline_begin` — write mode_byte = MODE_COMMAND; zero `ex_buffer` length byte; CALL `exline_compose_status`; RET.
  - [x] Sub 1.3: Public entry `exline_append_literal` (the dispatch_command unbound-prefix target) — printable-filter (CP 0x20 / RET C; CP 0x7F / RET NC); buffer-full check (LD A, (ex_buffer) ; CP EX_COMMAND_BUFFER ; RET Z); append byte; increment length; CALL `exline_compose_status`; RET.
  - [x] Sub 1.4: Public entry `exline_backspace` — read length; if zero RET; decrement; CALL `exline_compose_status`; RET.
  - [x] Sub 1.5: Public entry `exline_dispatch` — walk `exline_command_table`; for each entry compare ex_buffer length + ex_buffer_text bytes against the entry's null-terminated key string; on match tail-JP to handler; on miss (table terminator reached) set msg_not_editor_command via status_set_message then JP exline_cancel_core.
  - [x] Sub 1.6: Public entry `exline_cancel` — call exline_cancel_core; set msg_mode_normal via status_set_message; RET. (The split lets exline_dispatch's no-match path skip the banner write so its error message survives — see AC5 Note.)
  - [x] Sub 1.7: Internal helper `exline_cancel_core` — zero ex_buffer length; LD A, MODE_NORMAL ; LD (mode_byte), A; LD A, 1 ; LD (status_dirty), A. (The status_dirty write is needed because the no-match callers haven't gone through status_set_message — see Dev Notes.)
  - [x] Sub 1.8: Internal helper `exline_compose_status` — build ":\<ex_buffer payload\>\0" in a 66-byte file-local scratch (`exline_status_scratch`), then `LD HL, exline_status_scratch ; XOR A ; CALL status_set_message`. Scratch is module-local (DEFS 66 between routines, per render.asm's pattern). Cell index walk: scratch[0] = ':'; for i in 0..length-1: scratch[1 + i] = ex_buffer_text[i]; scratch[1 + length] = 0.
  - [x] Sub 1.9: Public entry `cmd_quit` — LD A, (buffer_dirty); OR A; JR NZ, .dirty; JP init_teardown; .dirty: LD HL, msg_no_write ; XOR A ; CALL status_set_message ; JP exline_cancel_core (no msg_mode_normal write — preserves the error banner).
  - [x] Sub 1.10: Public entry `cmd_quit_force` — JP init_teardown unconditionally.
  - [x] Sub 1.11: Data — `exline_command_table`:
    ```
    exline_command_table:
        DEFB "q", 0       ; entry 0: key "q" (length 1)
        DEFW cmd_quit
        DEFB "q!", 0      ; entry 1: key "q!" (length 2)
        DEFW cmd_quit_force
        DEFB 0            ; terminator (zero-length key)
    ```
    Future stories (2.2 `:e`, 2.4 `:w` / `:wq`) extend by inserting entries before the terminator.
  - [x] Sub 1.12: Data — `exline_status_scratch: DEFS 66, 0` (1 colon + 64 max ex_buffer payload + 1 null = 66 B). Per render.asm's precedent, module-local scratch lives in the code segment between routines.

- [x] **Task 2: Modify `src/dispatch.asm` (AC1, AC9, AC14)**
  - [x] Sub 2.1: Remove `mode_debug_quit` handler body (lines 326-344 currently) and its 4-line description comment block.
  - [x] Sub 2.2: Remove `enter_command_mode` handler body (lines 245-262 currently) and its description comment block.
  - [x] Sub 2.3: Remove `unbound_command` handler body (lines 410-422 currently) and its description comment block.
  - [x] Sub 2.4: Remove the `0x11` entry from `dispatch_normal` (the `DEFB 0x11 / DEFW mode_debug_quit` pair plus its `ASSERT 0x11 > 0x0C` line). Replace the following `ASSERT '/' > 0x11` with `ASSERT '/' > 0x0C` (the entry above 0x11 in the ascending chain is now 0x0C).
  - [x] Sub 2.5: Re-point `dispatch_normal`'s `':'` entry from `enter_command_mode` to `exline_begin`. Adjacent ASSERTs unchanged.
  - [x] Sub 2.6: Replace `dispatch_command`'s entry list. New shape:
    ```
    dispatch_command:
        DEFW    exline_append_literal       ; unbound-prefix → literal append path
    .entries:
        DEFB    0x08                        ; Backspace
        DEFW    exline_backspace
        ASSERT  0x0D > 0x08
        DEFB    0x0D                        ; Enter / CR
        DEFW    exline_dispatch
        ASSERT  0x1B > 0x0D
        DEFB    0x1B                        ; Esc — cancel
        DEFW    exline_cancel
    DISPATCH_COMMAND_COUNT EQU ($ - .entries) / 3
    ```
    (Was: a single Esc-only entry pointing at `enter_normal_mode`, with `unbound_command` as the unbound-prefix. New count: 3 entries, prefix is exline_append_literal.)
  - [x] Sub 2.7: Header sweep — remove `mode_debug_quit` / `enter_command_mode` / `unbound_command` from the Public list. Drop `inc/bdos.inc` from Dependencies (dispatch.asm no longer references the BDOS_CALL macro). Drop the "Story 1.12 — init_teardown for mode_debug_quit's screen-clear-on-exit path" note from Dependencies on `src/init.asm`. (dispatch.asm still has zero direct calls to init.asm now — the indirection goes through exline.asm's cmd_quit.) Update the `Purpose:` paragraph to describe the new shape (no more "the single BDOS use site is BDOS_CALL BDOS_EXIT in mode_debug_quit" line — dispatch.asm is now AR15-clean).
  - [x] Sub 2.8: Header sweep — the "Mode-state coupling captured here" paragraph (currently describes the visual_submode invariant) — leave intact; Story 2.1 doesn't change visual coupling.

- [x] **Task 3: Modify `src/statusln.asm` (AC5, AC9)**
  - [x] Sub 3.1: Remove `msg_mode_command: DEFB "-- command --", 0` from the string block (lines 172 currently). No consumer remains after Task 2's enter_command_mode removal.
  - [x] Sub 3.2: Add `msg_not_editor_command: DEFB "not an editor command", 0` to the string block (AR16 conventions: all lowercase, no trailing period, 21 chars payload). Position near `msg_no_write` since both are ex-line refusal banners.
  - [x] Sub 3.3: Update the header `Public:` list — remove `msg_mode_command`, add `msg_not_editor_command`. Update the Story-numbering comment in the message-block section divider to mention Story 2.1.

- [x] **Task 4: Modify `src/render.asm` (AC11)**
  - [x] Sub 4.1: In `render_diff` (the tail-cursor-emit step, lines 384-389 currently), insert a mode-check block between the `dirty_rows` clear and the `LD A, (render_cursor_col)`. New shape:
    ```
        ;; Clear dirty_rows.
        XOR     A
        LD      (dirty_rows), A
        LD      (dirty_rows + 1), A
        LD      (dirty_rows + 2), A

        ;; --- AC11 mode-aware cursor target ---
        ;; In MODE_COMMAND the cursor sits on the status row at
        ;; col (1 + ex_buffer length), with the ':' glyph at col 0.
        ;; Override render_cursor_row / col before the trailing
        ;; RI4 emit so the ESC Y goes to the right place.
        LD      A, (mode_byte)
        CP      MODE_COMMAND
        JR      NZ, .cursor_emit
        LD      A, STATUS_ROW
        LD      (render_cursor_row), A
        LD      A, (ex_buffer)              ; length byte
        INC     A                           ; +1 for the ':' prefix
        LD      (render_cursor_col), A

    .cursor_emit:
        ;; Final cursor reposition (RI4). emit_goto clamps both
        ;; coordinates before adding the VT52 bias.
        LD      A, (render_cursor_col)
        LD      C, A                        ; C = col
        LD      A, (render_cursor_row)      ; A = row
        JP      render_emit_goto            ; tail-JP
    ```
  - [x] Sub 4.2: Update render.asm's `Dependencies:` block — add `inc/modes.inc` (for `MODE_COMMAND`) and add `ex_buffer` to the state-symbol list (alongside the existing cursor_offset / gap_start / gap_end / etc.). Add `mode_byte` to the same list (currently absent — render had zero mode awareness pre-Story 2.1).
  - [x] Sub 4.3: Update render.asm's `render_diff` AR23 contract block — add a one-line `Reads:` note for `mode_byte` and `ex_buffer` (the existing block lists `top_line_offset`, `cursor_offset`, etc.; add the two new reads).
  - [x] Sub 4.4: Update the render module header `Purpose:` paragraph — add one sentence about the AC11 override.

- [x] **Task 5: Modify `src/vibe.asm` (AC1)**
  - [x] Sub 5.1: Insert `INCLUDE "exline.asm"` after the `parser.asm` INCLUDE (between parser.asm and the input_loop body), with an AR25-style comment block above it noting Story 2.1.
  - [x] Sub 5.2: Update the file header `Dependencies:` line — add `src/exline.asm (Story 2.1)`.
  - [x] Sub 5.3: Update the input_loop body's comment block — the existing comment says "the only exit is via `mode_debug_quit` -> `init_teardown` -> warm-boot (or, in a future story, `:q` / `:q!` arriving in Story 2.1)". Rewrite to: "the only exits are via cmd_quit / cmd_quit_force (src/exline.asm) -> init_teardown -> warm-boot".

- [x] **Task 6: Modify `inc/state.inc` (AC10)**
  - [x] Sub 6.1: Insert `ex_buffer_text EQU ex_buffer + 1` immediately after the `ex_buffer` declaration (under the existing `static_off = static_off + 1 + EX_COMMAND_BUFFER` line that reserves the storage). This is a pure positional EQU — no `static_off` advance, no bytes emitted.
  - [x] Sub 6.2: Add a comment above the new EQU noting the resolution of the Story-1.3 deferral (the comment can be a single line: "Resolves Story-1.3 deferral on ex_buffer length-byte naming convention (deferred-work.md)"). Optionally, also mention that `search_pattern_text` lands in Story 3.1 when search consumers arrive.
  - [x] Sub 6.3: Update state.inc's header `Public:` block — add `ex_buffer_text` to the Buffers list.

- [x] **Task 7: Modify `src/init.asm` (AC9 — header sweep only)**
  - [x] Sub 7.1: Sweep header comments for `mode_debug_quit` references and reword to point at exline.asm's `cmd_quit` / `cmd_quit_force`. Affected blocks: lines 19-21 (Purpose), 50-55 (Public init_teardown contract), 103-114 (init_teardown register conventions), 186 (Stage 0 race-window narrative — the "even a previous vibe.com run that crashed out of mode_debug_quit's tail-JP" line), 331-333 (init_teardown narrative), 364-365 (defensive-RET note), 370 (init_teardown In: line).
  - [x] Sub 7.2: No code changes — init.asm's bodies are unaffected by Story 2.1. The `JP init_teardown` callers shift from dispatch.asm's mode_debug_quit to exline.asm's cmd_quit / cmd_quit_force, but init_teardown itself doesn't need a re-export.

- [x] **Task 8: Create the four headless tests (AC12)**
  - [x] Sub 8.1: `test/cases/exline_q-clean-buffer.asm` — AR23 header, pre-ORG production EQU INCLUDEs (equates, bios, bdos, modes, vt52), test_prologue, test body (pre-zero state, set buffer_dirty=0, pre-load ex_buffer length=1 byte 'q', CALL exline_dispatch, assert sentinel), test_epilogue, production-code INCLUDEs in AR25 order (statusln + render + dispatch + parser + exline), `init_teardown:` LOCAL stub that sets a `init_teardown_called` flag byte and RETs, test_input_loop_stub, state.inc LAST.
  - [x] Sub 8.2: `test/cases/exline_q-dirty-buffer.asm` — same scaffolding; buffer_dirty=1; assert sentinel NOT set, ex_buffer length 0, mode_byte MODE_NORMAL, status_dirty set, status_buffer opening bytes match "no write since last change".
  - [x] Sub 8.3: `test/cases/exline_q-bang-force.asm` — same scaffolding; buffer_dirty=1; ex_buffer length=2 bytes 'q' '!'; assert sentinel set.
  - [x] Sub 8.4: `test/cases/exline_unknown-command.asm` — same scaffolding; ex_buffer length=3 bytes 'f' 'o' 'o'; assert sentinel NOT set, ex_buffer length 0, mode_byte MODE_NORMAL, status_dirty set, status_buffer opening bytes match "not an editor command".
  - [x] Sub 8.5: All four tests need a LOCAL `init_teardown:` stub — DO NOT include src/init.asm. The stub form:
    ```
    init_teardown:
        LD      A, 1
        LD      (init_teardown_called), A
        RET
    init_teardown_called:    DEFB 0
    ```
  - [x] Sub 8.6: Each test should use TH1 sentinel-fail codes in the 0xE0..0xEF range (per the Story 1.10 pattern), with B holding a diagnostic context byte. Document the code → assertion mapping in the test's header.

- [x] **Task 9: Update `_bmad-output/implementation-artifacts/deferred-work.md` (AC10)**
  - [x] Sub 9.1: Find the Story-1.3 deferral entry on the `search_pattern` / `ex_buffer` length-byte convention (around line 16). Add a "Resolved (partial) by Story 2.1" sub-bullet noting that `ex_buffer_text EQU ex_buffer + 1` lands in inc/state.inc; the `search_pattern_text` half stays deferred to Story 3.1.

- [x] **Task 10: Build + headless test verification (AC12, AC14)**
  - [x] Sub 10.1: `make clean && make` succeeds; capture SHA256 of vibe.com.
  - [x] Sub 10.2: Repeat `make clean && make`; verify byte-identical SHA (NFR18).
  - [x] Sub 10.3: `make sizes` reports the new code-section size. Capture verbatim. Note delta vs Story 1.12's 1947 B.
  - [x] Sub 10.4: AR grep sweeps per AC14 — all pass.
  - [x] Sub 10.5: `make test` from project root — all 27+ test cases pass (the 23 pre-2.1 + 4 new + the deliberate harness_fail).

- [ ] **Task 11: Hardware UAT (AC13)** — *deferred to user review (cannot push from this dev environment)*
  - [ ] Sub 11.1: `make push` — SLIDE transfer to the MicroBeast.
  - [ ] Sub 11.2: Step through AC13's 8 hardware UAT steps; record observations in Debug Log References. Note AC7's hardware coverage is intentionally deferred to Story 2.8 (the dirty-buffer path covered by `exline_q-dirty-buffer.asm` headless).
  - [ ] Sub 11.3: If any step surfaces a regression (esp. cursor positioning in COMMAND mode after BIOS_CONOUT register-clobber — same class of regression as Story 1.11's `render_emit_goto` D/E preservation bug), capture the symptom in Completion Notes and assess whether AC11's mode-check needs an analogous defensive scratch.

### Review Findings

Code review run on 2026-05-13 via `bmad-code-review` (Blind Hunter + Edge Case Hunter + Acceptance Auditor). Acceptance Auditor: all 14 ACs MET (AC13 NOT-VERIFIABLE-IN-DIFF, hardware UAT pending). No DEVIATION findings. Raw counts: 1 decision_needed (→ promoted to patch P5), 5 patches applied, 7 deferred, 17 dismissed as noise / false positive / matches spec.

**Decision needed (0):**

Resolved during triage:
- D1 (Empty `:<Enter>` produces "not an editor command") → promoted to patch P5: add length==0 short-circuit at top of `exline_dispatch` so bare-Enter cancels silently per vi convention.

**Patches (5) — all applied 2026-05-13:**

- [x] [Review][Patch] Fix incorrect doc comment on `status_dirty` in `src/exline.asm` header [src/exline.asm:75-83] — Rewrote the comment to acknowledge that `exline_cancel_core`'s `status_dirty` write is load-bearing for `exline_cancel` (which calls core BEFORE the funnel) and defensive belt-and-braces for the no-match / dirty-refusal paths (which have already entered `status_set_message`, which sets `status_dirty=1` on its own). (Source: Blind Hunter.)
- [x] [Review][Patch] Added `ASSERT EX_COMMAND_BUFFER < 256` near the EQU [inc/equates.inc:38] — locks the 8-bit length-byte invariant the `CP EX_COMMAND_BUFFER` check depends on. (Source: Blind Hunter.)
- [x] [Review][Patch] Tightened `exline_append_literal` buffer-full check from `RET Z` to `RET NC` [src/exline.asm:242] — defensive against `ex_buffer` length-byte values >64 from any unforeseen writer-side path. (Source: Edge Case Hunter.)
- [x] [Review][Patch] Added `ASSERT $ - exline_status_scratch >= 1 + EX_COMMAND_BUFFER + 1` [src/exline.asm:560] — locks the writer invariant; a future `EX_COMMAND_BUFFER` bump now trips a build-time guard rather than silently overflowing the scratch. (Source: Blind Hunter + Edge Case Hunter.)
- [x] [Review][Patch] Added length==0 short-circuit to `exline_dispatch` [src/exline.asm:308-314] — Bare `:<Enter>` now `JP exline_cancel` (silent vi-style exit) instead of falling into the no-match path that surfaced `"not an editor command"`. New headless test `test/cases/exline_bare-enter.asm` pins the behavior. Promoted from decision-needed D1 by user. (Source: Edge Case Hunter.)

**Post-patch build verification (2026-05-13):**

- `make clean && make` succeeds; SHA256 `da4a7396078091c37fc7a6daba94b0e1012dc5fe62e9ec0b85eeb2213112bbe4`.
- Second `make clean && make`: same SHA — byte-identical (NFR18 holds).
- `make sizes`: `code_section: 2243 bytes (~73% of NFR9 ~3 KB budget)`. Delta vs pre-patch 2236 B: **+7 B** for the bare-Enter short-circuit (`LD A,(ex_buffer); OR A; JP Z,exline_cancel` = 7 B). ASSERTs are compile-time; zero runtime cost.
- `make test`: **28 pass / 1 deliberate fail** (was 27/1 pre-patch; new `exline_bare-enter` test passes).
- AR enforcement sweeps re-run (AC14): all clean — matches are comments-only, no symbol declarations or call sites.

**Deferred (7):**

- [x] [Review][Defer] Refactor 4 test cases' duplicate `init_teardown` stub into a shared `test/inc/exline_teardown_stub.inc` — deferred, pre-existing pattern (four-way drift risk; cosmetic, not load-bearing). (Source: Blind Hunter.)
- [x] [Review][Defer] Add ASSERTs validating `exline_command_table` structure (key-length sanity, null+DEFW pairing) [src/exline.asm:531-536] — deferred until Stories 2.2 / 2.4 / 3.1 grow the table; today's 2 entries are hand-auditable. (Source: Blind Hunter + Edge Case Hunter.)
- [x] [Review][Defer] `init_teardown` is publicly callable; any module can bypass `:q`'s dirty check by JPing directly [src/init.asm] — deferred, architectural surface concern; no current bypass site. (Source: Blind Hunter.)
- [x] [Review][Defer] No end-to-end headless test exercises `exline_begin` → `exline_append_literal` → `exline_backspace` → `exline_dispatch` via the production input path [test/cases/exline_*.asm] — deferred; AR enforcement greps cover static surface, and hardware UAT exercises the live path. Pointer-arithmetic regressions in `exline_append_literal` could slip through pre-UAT. (Source: Blind Hunter.)
- [x] [Review][Defer] Tests don't pin "ex_buffer length is source of truth" — stale payload bytes past the length boundary aren't asserted inaccessible [test/cases/exline_*.asm] — deferred; invariant holds by construction, but no regression net. (Source: Blind Hunter.)
- [x] [Review][Defer] `exline_dispatch`'s `.count_key` uses 8-bit `B` with no overflow guard [src/exline.asm:317] — deferred; current keys are 1-2 bytes, fileio's longest will be 2 bytes (`wq`). Re-evaluate if a long help command ever lands. (Source: Blind Hunter + Edge Case Hunter.)
- [x] [Review][Defer] No vi-style escalation prompt on repeated `:q` of dirty buffer — same banner each time, no "use !" guidance [src/exline.asm:455-459] — deferred, UX nicety outside spec scope. (Source: Edge Case Hunter.)

**Dismissed as noise (17):**

- Blind: dispatch table walk on non-prefix byte-mismatch — verified: `.advance_to_null` correctly finds the entry's terminator regardless of mid-key HL position.
- Blind: malformed-table read-past-end — too speculative.
- Blind: 0x7F filter doc-vs-code drift — header comment "control bytes and KEY_ARROW_*" covers DEL by implication.
- Blind: STATUS_LINE_WIDTH respect — `status_set_message` owns padding/truncation.
- Blind: .copy → .terminate fall-through undocumented — intentional and obvious.
- Blind: cursor-override col=1+length without explicit clamp — bounded by length ≤ 64; emit_goto clamps; bounded < SCREEN_COLS.
- Blind: `exline_status_scratch` in code segment wastes 66 bytes — explicit design choice per Dev Notes "render.asm precedent for module-local scratch".
- Blind: `LD H,0; LD L,A` vs `LD D,0; LD E,A` style nit — trivial.
- Blind: `exline_compose_status` state-preservation comment — trivial.
- Blind: `STATUS_ROW` undocumented dep in render.asm — false positive; already listed at src/render.asm:151 via inc/equates.inc.
- Blind: AR25 forward-promise speculation about future module ordering — not actionable.
- Blind: ex_buffer+1 grep doesn't sweep src/exline.asm — false positive; `src/*.asm` glob covers it.
- Edge: render cursor col >78 unreachable (length ≤ 64).
- Edge: KEY_ARROW / DEL / Tab silent drop — per spec AC2.
- Edge: zero-length-key entry in table treated as terminator — design choice.
- Edge: buffer_dirty non-1 nonzero treated as dirty — `OR A; JR NZ` is the documented convention.
- Edge: ISR concurrency with `ex_buffer` — Story 1.12 ISR scope does not touch `ex_buffer`.
- Edge: NUL key (0x00) in COMMAND mode — routes through unbound→append_literal→`CP 0x20` drop. Consistent with spec.
- Edge: `exline_begin` re-entry not reachable today — speculative.

## Dev Notes

### Architecture compliance

This story lands Architecture's **Implementation Sequence** step 9 partial (`exline.asm`) and resolves the carve-out from Story 1.12 ("the temporary debug-quit key from story 1.12 can be removed" — epics line 856). The wider architecture mapping:

- **FR3 (User can quit VIBE, returning control to the CCP).** First production realisation — Story 1.12's Ctrl-Q debug-quit was a bring-up affordance, not the FR3 surface. After 2.1, FR3 is satisfied by `:q` (clean buffer) and `:q!` (force).
- **FR8 (User can quit without saving, abandoning unsaved changes — `:q!`).** Lands in `cmd_quit_force`.
- **FR14 (ex-line dispatch).** This story's main contribution — the `:` command-line UI, the `ex_buffer` editing surface, and the `exline_command_table` dispatch shape that Stories 2.2 / 2.4 / 3.1 extend.
- **FR50 (No-op on unsupported commands).** AC5's no-match path — "not an editor command" status + return to NORMAL. Matches FR50's "no-op with status feedback" contract.
- **FR52 / NFR6 (No silent data loss).** AC7's dirty-quit refusal — buffer stays dirty until either `:w` (Story 2.4) succeeds or `:q!` explicitly abandons.
- **AR12 (Single status-message funnel — `status_set_message`).** `exline.asm` enters the funnel three times: `exline_compose_status` (per-keystroke prompt redraw), `exline_dispatch`'s no-match path (msg_not_editor_command), `cmd_quit`'s dirty path (msg_no_write), `exline_cancel`'s banner (msg_mode_normal). All via the single AR12 entry point. NO direct writes to status_buffer / status_dirty from exline.asm — the scratch buffer is built locally and handed off via the HL pointer.
- **AR13 (Single screen-emission path — render.asm only).** `exline.asm` has zero `BIOS_CONOUT` references. Per-keystroke screen update flows: exline → status_set_message (sets status_dirty) → render_diff (next loop iteration) emits the status row. RI2's "render runs after each input-loop iteration" holds.
- **AR14 (Single buffer-mutation owner — `gapbuf.asm`).** `exline.asm` does NOT invoke `gapbuf_insert / gapbuf_delete / gapbuf_move_gap`. The ex-line buffer (`ex_buffer`) is separate from the editing buffer (the gap buffer). cmd_quit's path goes through `init_teardown`, not through edits.
- **AR15 (Single BDOS gateway — `BDOS_CALL` macro).** `exline.asm` has zero direct BDOS calls; the only BDOS_CALL site is in `init_teardown`'s body (BDOS function 0 = warm-boot), unchanged from Story 1.12. dispatch.asm becomes AR15-clean for the first time (the Story-1.12 `BDOS_CALL BDOS_EXIT` inside `mode_debug_quit` was its lone macro use site; that line is gone).
- **AR16 (Status-message string-table convention).** `msg_not_editor_command` lands lowercase, no trailing period, 21 chars (under the 30-char target). `msg_no_write` (existing) is reused for the dirty-refusal path. `msg_mode_command` is removed (no consumer).
- **AR22 (Naming).** New public symbols: `exline_begin`, `exline_append_literal`, `exline_backspace`, `exline_cancel`, `exline_cancel_core`, `exline_dispatch`, `cmd_quit`, `cmd_quit_force`. All `module_action` lowercase_with_underscores. Internal labels (`.search`, `.match`, `.no_match`) dotted-locals. Equates / macros (none new in exline.asm) UPPER_SNAKE.
- **AR23 (File structure and routine contracts).** `src/exline.asm` starts with the standard header block (Module / Purpose / Public / State owned / State read-only / Register conventions / Dependencies). Every public routine begins with the four-line `In:` / `Out:` / `Trashes:` / `Calls:` contract.
- **AR24 (Format).** 4-space indentation, UPPERCASE mnemonics, `;` line / `;;` section comments, no trailing periods. `ex_buffer` is length-prefixed (per the SR-level convention pinned at architecture line 179 and state.inc's existing layout); `exline_status_scratch` is null-terminated (consumed by `status_set_message`, which walks-until-null).
- **AR25 (Module include order).** `exline.asm` lands AFTER `parser.asm` in `src/vibe.asm`'s INCLUDE chain — the architecture's order has `... parser → motions → edits → visual → search → exline → fileio → undo`. With motions/edits/visual/search not yet present, exline slots in immediately after parser. When Story 2.5+ adds motions etc, they'll INCLUDE between parser and exline.

### Library / framework requirements

**sjasmplus 1.23.0:**
- Already pinned by Makefile's `check-toolchain` (Story 1.1).
- **Forward references resolve on second pass.** exline.asm's `JP init_teardown` (in cmd_quit / cmd_quit_force), `CALL status_set_message`, `LD HL, msg_no_write` / `msg_mode_normal` / `msg_not_editor_command` are all forward references at first pass (exline.asm INCLUDEs AFTER statusln.asm and AFTER init.asm in vibe.asm's chain, so init_teardown is BACKWARD-referenced, but the message symbols are also backward — statusln.asm precedes exline.asm). Wait — re-check: AR25 order in vibe.asm is `init → input → statusln → gapbuf → render → dispatch → parser → exline`. So when exline.asm assembles, init_teardown / status_set_message / msg_no_write etc. are all already-defined symbols. NO forward references in exline.asm's call sites except `cmd_quit` and `cmd_quit_force` if dispatch_command's table references them — but dispatch.asm INCLUDEs BEFORE exline.asm in the chain. dispatch_command's DEFW exline_begin / exline_dispatch / exline_backspace / exline_cancel / exline_append_literal are all FORWARD references at first pass. sjasmplus's two-pass model handles this — same pattern as Story 1.10's parser_handle_digit / parser_handle_operator forward references from dispatch_normal.
- **`exline_command_table` walk via DEFB/DEFW byte-string scan.** No special sjasmplus features required; the table is a hand-laid sequence of (null-terminated bytes, 2-byte handler addr) pairs, terminated by a single 0x00 byte. The scan code reads bytes until it hits a NUL, advances 2 (handler addr), and loops. On finding a 0 at the start of an entry (the terminator), the no-match path fires.
- **String compare loop.** exline_dispatch compares the length-prefixed ex_buffer payload against each null-terminated table key. The loop: (1) read entry's first byte; if 0, terminator → no-match; (2) walk both strings byte-by-byte until either differs (next entry) or both hit their terminator (length match required: ex_buffer length AND null-terminated key length must agree). A simple byte-counter form is ~30-40 bytes; the alternative (CPDR-based) is shorter but less readable. Recommend the byte-counter form for clarity at this scale.

**iz-cpm:**
- Used for all four new headless tests under `test/cases/exline_*.asm`.
- **Local `init_teardown` stub pattern.** The four tests need to intercept cmd_quit / cmd_quit_force's tail-JP to init_teardown — otherwise the test would warm-boot iz-cpm before the assertions run. The standard intercept: DO NOT include src/init.asm; define a local `init_teardown:` that sets `init_teardown_called = 1` and RETs. This makes init_teardown a defined symbol in the test's link unit, satisfying exline.asm's `JP init_teardown` resolution. Same pattern as Story 1.12's `init_cold_start-state-shape.asm`, which defined a local `input_loop:` to intercept init_cold_start's fall-through.
- **5-second timeout per test.** The tests are fast — no rendering, no buffer walks, just direct CALLs to exline entries and post-CALL state inspection. Each test runs in ~1 ms; the 5 s timeout is generously over-provisioned.
- **Test cannot exercise the input_get_key / dispatch_key flow end-to-end.** The headless tests skip the input layer entirely (pre-populate ex_buffer and call exline_dispatch directly). The full path — keystrokes → input_get_key → dispatch_key → exline_append_literal → exline_compose_status → status_set_message → render_diff → emit — is exercised on hardware (AC13 UAT). Headless coverage is sufficient for the dispatch-table logic and the cmd_quit / cmd_quit_force / no-match branches.

**CP/M 2.2 BDOS / MicroBeast BIOS:**
- No new BDOS or BIOS surface in Story 2.1. The cmd_quit / cmd_quit_force paths reuse Story 1.12's `init_teardown`, which already invokes `MBB_SET_USR_INT` (uninstall) and `BDOS_CALL BDOS_EXIT` (warm-boot). NFR15 holds (CP/M 2.2 BDOS only).

### Recommended skeleton for `exline_dispatch` and the cancel split (AC5 Note)

```asm
; ----------------------------------------------------------------
; exline_dispatch (Enter handler — dispatch_command[0x0D])
; Walk exline_command_table comparing ex_buffer's length-prefixed
; payload against each null-terminated key string. On match, tail-
; JP to the entry's handler. On no match, set msg_not_editor_command
; and tail-JP to exline_cancel_core (the variant that does NOT
; clobber status_buffer with the empty msg_mode_normal banner).
;
; In:      A = 0x0D (MC4, ignored — state comes from ex_buffer)
; Out:     control transferred to handler or to cleanup path.
; Trashes: A, BC, DE, HL, F (handlers may trash more).
; Calls:   matched handler (cmd_quit / cmd_quit_force / ...),
;          status_set_message, exline_cancel_core.
; ----------------------------------------------------------------
exline_dispatch:
    LD      HL, exline_command_table
.next_entry:
    LD      A, (HL)
    OR      A
    JR      Z, .no_match                ; terminator → no match
    ;; Count key length until null.
    PUSH    HL                          ; save entry key start
    LD      B, 0
.count_key:
    LD      A, (HL)
    OR      A
    JR      Z, .key_counted
    INC     HL
    INC     B
    JR      .count_key
.key_counted:
    ;; B = key length; HL now at the entry's null.
    LD      A, (ex_buffer)
    CP      B
    POP     HL                          ; HL = entry key start
    JR      NZ, .skip_entry
    ;; Lengths match: compare bytes.
    LD      DE, ex_buffer_text
    LD      C, B                        ; C = remaining bytes
.compare:
    LD      A, C
    OR      A
    JR      Z, .match
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .skip_entry
    INC     HL
    INC     DE
    DEC     C
    JR      .compare
.skip_entry:
    ;; Walk HL past the entry's null + 2-byte handler addr.
    XOR     A
.advance_to_null:
    CP      (HL)
    INC     HL
    JR      NZ, .advance_to_null        ; skip key bytes + null
    INC     HL
    INC     HL                          ; skip handler addr (2 bytes)
    JR      .next_entry

.match:
    ;; HL now at the null after the key; the handler addr follows.
    INC     HL                          ; HL past null → handler addr lo
    LD      E, (HL)
    INC     HL
    LD      D, (HL)
    EX      DE, HL                      ; HL = handler addr
    JP      (HL)                        ; tail-JP

.no_match:
    LD      HL, msg_not_editor_command
    XOR     A
    CALL    status_set_message
    JP      exline_cancel_core          ; clean ex_buffer + mode, KEEP banner
```

```asm
; ----------------------------------------------------------------
; exline_cancel  (Esc handler — dispatch_command[0x1B])
; Full cancel path: clear ex_buffer, return to NORMAL, AND clear
; the status row to the empty banner via msg_mode_normal.
;
; exline_cancel_core is the "internal" variant used by callers
; (exline_dispatch's no-match path, cmd_quit's dirty-refusal path)
; that have ALREADY written a status banner they want preserved.
; The core path sets status_dirty = 1 explicitly (since it doesn't
; go through status_set_message which would set it as a side
; effect).
; ----------------------------------------------------------------
exline_cancel:
    CALL    exline_cancel_core
    LD      HL, msg_mode_normal
    XOR     A
    CALL    status_set_message
    RET

exline_cancel_core:
    XOR     A
    LD      (ex_buffer), A              ; length = 0
    LD      A, MODE_NORMAL
    LD      (mode_byte), A
    LD      A, 1
    LD      (status_dirty), A           ; ensure status row redrawn
    RET
```

### Previous story intelligence

**From Story 1.12 (most relevant — set up the substrate this story builds on):**
- `init_teardown` already exists with the correct shape (uninstall user ISR via MBB_SET_USR_INT, clear screen via render_init, BDOS_CALL BDOS_EXIT, defensive RET). Story 2.1's cmd_quit / cmd_quit_force callers `JP` to it; no changes needed to init_teardown's body.
- `mode_debug_quit` was the Story-1.12 placeholder bound to Ctrl-Q (0x11). Story 2.1 retires it (the placeholder was always temporary — see Story 1.12 AC6 / dispatch.asm:326-344). The replacement is `:q` (clean) / `:q!` (force) flowing through exline_dispatch → cmd_quit / cmd_quit_force → init_teardown.
- The `bdos_error_funnel` (statusln.asm) JPs to `input_loop`. After Story 2.1's changes, dispatch_command[0x1B]'s Esc handler is `exline_cancel` (not `enter_normal_mode`), and the input loop's mode dispatch routes the next keystroke through dispatch_normal — clean.
- Code budget remains at ~63% (1947 B / 3072 B) post-1.12. Story 2.1 adds ~150-250 B (exline.asm body + new statusln message + render mode-check) minus ~30 B (mode_debug_quit + enter_command_mode + unbound_command + msg_mode_command removed). Net add: ~120-220 B. Expected post-2.1: ~2070-2170 B / 3072 B ≈ 67-71% of NFR9 budget.
- The Story-1.12 `render_emit_goto` D/E preservation patch (using `render_goto_row` / `render_goto_col` scratch cells) is the precedent for "BIOS may trash any register at will" defensive scratch. Story 2.1 does NOT add a new render_emit_goto site, so no new analogous defensive scratch is required. The existing emit_goto path handles all cursor positioning, including the COMMAND-mode override.

**From Story 1.11 (render pipeline — Story 2.1's render-modification target):**
- `render_diff` is the entry point Story 2.1's AC11 modifies. The four sub-step structure (`render_refresh_caches` → `render_scroll_adjust` → `render_emit_editable_rows` → `render_emit_status_row` → clear dirty_rows → final cursor emit) is the architecture Story 2.1 builds on. The mode-check lands between "clear dirty_rows" and "final cursor emit" — the smallest insertion site that doesn't perturb the existing diff logic.
- `render_cursor_row` and `render_cursor_col` are module-local DEFB cells (file-private in render.asm). Story 2.1's mode-check writes to them directly — which is legal because they're not in state.inc (per render.asm:1226-1232's "module-local scratch may live in the module's code segment" policy). External access from exline.asm would be a layering violation; instead, render.asm reads `ex_buffer`'s length byte directly via `LD A, (ex_buffer)`. This is a new state-symbol read for render but it's read-only (and exline owns the write path through the AR12 funnel via status_set_message, plus its own direct length-byte writes).
- The `render_emit_status_row` routine (lines 1041-1143) is the precedent for the contiguous-run shadow-diff against the bottom row of the screen. Story 2.1 does NOT modify this routine — it relies on the existing diff to render the ":" + ex_buffer content that `exline_compose_status` writes to status_buffer.

**From Story 1.10 (parser — adjacent to Story 2.1 conceptually but no direct shared code):**
- The dispatch_command table is currently just an Esc entry plus the unbound stub (parser doesn't have COMMAND-mode entries). Story 2.1 extends this table to three real entries (Backspace, Enter, Esc) and re-purposes the unbound-prefix as the literal-append path — mirroring how INSERT mode is destined to use unbound_insert as its literal-insert path in Story 2.8.
- Parser-state-clear policy on mode transitions (the Story 1.10 deferral, lines 86-93 of deferred-work.md): Story 2.1 does NOT pin this policy. Entering COMMAND mode via `:` does NOT clear count_accumulator / pending_operator / pending_motion_prefix today; that's the deferred behavior that lands in Story 2.5+ when real motion handlers make the count semantics observable. For 2.1's surface (`:q`, `:q!`, `:foo`), no motion handler is in the call graph, so the stale parser-state is invisible to the user. Re-affirm the Story-2.5+ deferral; do NOT add a parser_clear call to exline_begin.

**From Story 1.9 (dispatch — Story 2.1's primary structural modification target):**
- The four mode tables (dispatch_normal, dispatch_insert, dispatch_command, dispatch_visual) each consist of a 2-byte unbound-prefix + N ascending-by-ASCII entries. Story 2.1 modifies dispatch_normal (remove Ctrl-Q entry, re-point ':' entry) and dispatch_command (add 0x08, 0x0D, 0x1B entries with new handlers; re-point unbound-prefix).
- The `ASSERT key_n > key_n-1` chain between every adjacent pair of entries catches a swap-typo at build time. Re-stitch the chain in dispatch_normal when removing the 0x11 entry: the prior `ASSERT 0x11 > 0x0C` becomes `ASSERT '/' > 0x0C` (skipping the now-gone 0x11 slot).
- The `DISPATCH_COMMAND_COUNT` equate (currently 1) becomes 3 after Story 2.1 — the formula `($ - .entries) / 3` re-resolves at assembly time, no manual update needed.

**From Story 1.5 (statusln — Story 2.1's status-message funnel partner):**
- `status_set_message` is the AR12 single-WRITE-path entry. exline_compose_status, exline_dispatch's no-match path, cmd_quit's dirty path, and exline_cancel's banner all enter through this funnel.
- `msg_no_write` already exists ("no write since last change"). Reused by cmd_quit's dirty-buffer refusal path — no new string needed for that surface.
- `msg_mode_command` ("-- command --") is REMOVED — the ex-line `:` prompt replaces the indicator (and is much more useful: shows the in-flight command-being-typed).
- The Story-1.5 `bdos_error_funnel` JPs to `input_loop` — unaffected by Story 2.1.

**From Story 1.3 (state.inc — Story 2.1 partially resolves a Story-1.3 deferral):**
- `ex_buffer` is declared as a 1-byte length prefix + EX_COMMAND_BUFFER (64) bytes of raw payload. Story 1.3's deferred-work entry (deferred-work.md line 16) flagged the lack of a named offset symbol — a consumer that reads the buffer at `ex_buffer` instead of `ex_buffer + 1` reads the length byte as data with no build-time signal. Story 2.1 adds `ex_buffer_text EQU ex_buffer + 1` to inc/state.inc and uses it at every read site. The sibling `search_pattern_text` stays deferred to Story 3.1.

### Git intelligence

Twelve commits on `main` after the project skeleton (most-recent first per `git log`):

- `0ef09de` — story 1.12: Wired init/teardown, the main input loop, and the first on-hardware smoke test.
- `dc2dd0d` — story 1.11: Wrote the screen renderer: dirty-row diff, scroll, Ctrl-L full redraw, status row.
- `e9f291a` — story 1.10: Wrote the command parser: counts, pending operators, and the gg motion-prefix.
- `6084103` — story 1.9: Wrote the key dispatcher: binary-searches a per-mode table to find the handler.
- `5f5577e` — story 1.8: Wrote the input layer; tells Esc from arrows in ~40ms, with putback.

Conventions visible in the tree (preserve in Story 2.1):
- 4-space indentation, UPPERCASE mnemonics, `;` line / `;;` section comments (AR24).
- AR23 header blocks on every `.asm` and `.inc` file. The new `src/exline.asm` follows the same shape.
- Every public routine has the `In:` / `Out:` / `Trashes:` / `Calls:` four-line contract (AR23).
- One story per commit; short imperative subject + colon-separated context. Match the user's plain-English style.

Suggested commit message for Story 2.1 (when the dev finishes): `story 2.1: Wrote the ex command-line; :q quits, :q! force-quits, Backspace and Esc behave.` Match the prior stories' "Wrote the gap buffer" / "binary-searches a per-mode table" / "Wired init/teardown" plain-English style.

### Testing requirements

Story 2.1's testing requirements split into four categories:

**Build-time / static:**

1. `make` from project root succeeds (NFR14 / AC14).
2. `make clean && make` produces byte-identical `vibe.com` across two consecutive runs (NFR18 / AC14). Capture both SHAs in Debug Log References.
3. `make sizes` reports the code-section size (NFR9 baseline / AC14). Capture verbatim; note delta vs Story 1.12's 1947 B.
4. AR grep sweeps (AC14):
   - `grep -rnE 'BIOS_CONOUT' src/ | grep -v 'render.asm'` — zero matches (AR13)
   - `grep -nE 'gapbuf_(insert|delete|move_gap|load)' src/exline.asm` — zero matches (AR14)
   - `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/exline.asm` — zero matches (AR15)
   - `grep -nE 'BDOS_CALL' src/exline.asm` — zero matches
   - `grep -nE 'BDOS_CALL|CALL[ \t]+BDOS_ENTRY|CALL[ \t]+0x0005' src/dispatch.asm` — zero matches (dispatch.asm becomes AR15-clean)
   - `grep -nE 'ex_buffer\s*\+\s*1' src/*.asm test/cases/exline_*.asm | grep -v 'state.inc'` — zero matches (AC10: every read site uses ex_buffer_text)
   - `grep -nE 'mode_debug_quit|enter_command_mode|unbound_command|msg_mode_command' src/ inc/` — zero matches (AC9: all four symbols removed)

**Headless test cases:**

5. `exline_q-clean-buffer.asm` — `:q` on clean buffer → cmd_quit → init_teardown (stubbed). Sentinel set, ex_buffer cleared, mode NORMAL.
6. `exline_q-dirty-buffer.asm` — `:q` on dirty buffer → cmd_quit dirty path → msg_no_write + exline_cancel_core. Sentinel NOT set, ex_buffer cleared, mode NORMAL, status banner "no write since last change".
7. `exline_q-bang-force.asm` — `:q!` regardless of dirty state → cmd_quit_force → init_teardown (stubbed). Sentinel set.
8. `exline_unknown-command.asm` — `:foo` → exline_dispatch no-match → msg_not_editor_command + exline_cancel_core. Sentinel NOT set, ex_buffer cleared, mode NORMAL, status banner "not an editor command".
9. **Live baseline becomes at least 27 pass / 1 fail** (23 pre-2.1 + 4 new + the deliberate `harness_fail`). Larger if the dev writes additional tests (e.g. `exline_compose-status.asm` exercising the `:` prompt redraw across a sequence of appends and a backspace).

**Hardware UAT (AC13):**

10. SLIDE-push and launch from CCP.
11. `:` keypress → status row shows `:`, cursor at row 23 col 1.
12. Type `q` (status `:q`, cursor col 2), Backspace (status `:`, cursor col 1), `q` again, `q` again (status `:qq`), Esc → status blank, mode NORMAL, cursor returned to buffer.
13. `:q` Enter → clean exit to CCP prompt (AC6).
14. Relaunch, `:q!` Enter → force exit (AC8). Note AC7 (dirty-buffer refusal) cannot be exercised from real keystrokes until Story 2.8 lands real insert-mode literal-append; the headless test (test 6) covers this surface for Story 2.1.
15. `:foo` Enter → status "not an editor command", mode NORMAL, editor continues (AC5 no-match).

**Regression watch:**

16. Existing 23 headless tests continue to pass (no Story 1.x regressions from dispatch.asm's table changes or render.asm's mode-check insertion).
17. The Story-1.12 hardware-UAT'd flows (Ctrl-L full refresh, mode banners for INSERT / VISUAL, Esc-back-to-NORMAL from any mode, sustained typing) remain green on a 30-second sustained-typing UAT after Story 2.1.

### Project Structure Notes

After Story 2.1 the source tree is:

```
src/
├── vibe.asm          # Top-level — Story 2.1 adds INCLUDE "exline.asm" after parser
├── init.asm          # Story 1.12 — header comments swept of mode_debug_quit refs
├── input.asm         # Story 1.8 (unchanged by 2.1)
├── statusln.asm      # Story 1.5 / 1.9 / 2.1 — msg_mode_command removed, msg_not_editor_command added
├── gapbuf.asm        # Story 1.7 (unchanged by 2.1)
├── render.asm        # Story 1.11 / 2.1 — render_diff gains COMMAND-mode cursor override (AC11)
├── dispatch.asm      # Story 1.9 / 2.1 — Ctrl-Q entry + mode_debug_quit + enter_command_mode + unbound_command REMOVED;
│                     #   dispatch_command table extended to 3 entries; ':' re-pointed to exline_begin
├── parser.asm        # Story 1.10 (unchanged by 2.1)
└── exline.asm        # Story 2.1 — NEW (ex-line UI + command table + cmd_quit + cmd_quit_force)

inc/
├── equates.inc       # Story 1.2 (unchanged by 2.1)
├── bios.inc          # Story 1.4 / 1.12 (unchanged by 2.1)
├── bdos.inc          # Story 1.4 (unchanged by 2.1)
├── modes.inc         # Story 1.2 (unchanged by 2.1)
├── vt52.inc          # Story 1.2 / 1.12 (unchanged by 2.1)
└── state.inc         # Story 1.3 / 1.12 / 2.1 — ex_buffer_text positional EQU added (AC10)

test/
├── README.md
├── Makefile          # (unchanged by 2.1)
├── inc/              # (unchanged by 2.1)
└── cases/
    ├── ... (existing 23 cases unchanged)
    ├── exline_q-clean-buffer.asm        # Story 2.1 — NEW
    ├── exline_q-dirty-buffer.asm        # Story 2.1 — NEW
    ├── exline_q-bang-force.asm          # Story 2.1 — NEW
    └── exline_unknown-command.asm       # Story 2.1 — NEW
```

Architecture's reference layout (architecture.md lines 1278-1340) anticipates `src/exline.asm` between `src/search.asm` and `src/fileio.asm` per AR25; Story 2.1 lands exline.asm immediately after parser.asm (the AR25-ordered modules between parser and exline — motions/edits/visual/search — are not yet present). Future stories (2.5 motions, 2.7 counted, 2.8 insert, 2.9-2.13 edits, 3.x search/visual) will slot in between parser.asm and exline.asm as they land.

### Files created and modified by this story

**Files created:**
- `src/exline.asm` (new — primary deliverable).
- `test/cases/exline_q-clean-buffer.asm` (new).
- `test/cases/exline_q-dirty-buffer.asm` (new).
- `test/cases/exline_q-bang-force.asm` (new).
- `test/cases/exline_unknown-command.asm` (new).

**Files modified:**
- `src/vibe.asm` — INCLUDE exline.asm after parser per AR25; header Dependencies + input_loop comment swept.
- `src/dispatch.asm` — remove mode_debug_quit / enter_command_mode / unbound_command bodies; remove 0x11 entry from dispatch_normal; re-point ':' to exline_begin; rebuild dispatch_command table (3 entries: 0x08, 0x0D, 0x1B + new unbound-prefix); header swept (Dependencies drops inc/bdos.inc).
- `src/render.asm` — render_diff gains mode-aware cursor override before the final emit_goto; header gains inc/modes.inc + mode_byte + ex_buffer reads.
- `src/statusln.asm` — remove msg_mode_command; add msg_not_editor_command; header Public list updated.
- `src/init.asm` — header comments swept of mode_debug_quit references (point at exline.asm's cmd_quit / cmd_quit_force instead). Body unchanged.
- `inc/state.inc` — add `ex_buffer_text EQU ex_buffer + 1`; header Public list gains ex_buffer_text.
- `_bmad-output/implementation-artifacts/deferred-work.md` — mark Story-1.3 deferral on ex_buffer length-byte naming as resolved (partial — search_pattern_text half stays deferred to Story 3.1).

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md] lines 852-901
- Previous story (init/teardown + on-hardware smoke test, Story 1.12 — structural prior art for AR enforcement, header conventions, deferred-work resolution, hardware UAT planning): [Source: _bmad-output/implementation-artifacts/1-12-init-teardown-on-hardware-smoke-test.md]
- Adjacent story (file load via :e filename, Story 2.2 — next; extends exline_command_table with `e` / `e!` entries and adds src/fileio.asm): [Source: _bmad-output/planning-artifacts/epics.md] lines 902-951
- Adjacent story (launch with filename argument, Story 2.3 — same Epic; reads CP/M default FCB at 0x005C, calls into the Story-2.2 fileio_load): [Source: _bmad-output/planning-artifacts/epics.md] lines 953-989
- Adjacent story (file save, Story 2.4 — same Epic; extends exline_command_table with `w` / `w filename` / `wq` entries): [Source: _bmad-output/planning-artifacts/epics.md] lines 991-1044
- Adjacent story (forward literal search, Story 3.1 — Epic 3; sibling of Story 2.1 in that it lands the `/` prompt UI using the same ex-line input pattern; also resolves the `search_pattern_text` half of Story 1.3's deferral): [Source: _bmad-output/planning-artifacts/epics.md] lines 1486-1524
- Adjacent story (insert mode i/a/o/O, Story 2.8 — same Epic; lands the real insert-mode literal-append path that completes AC7's hardware UAT coverage): [Source: _bmad-output/planning-artifacts/epics.md] lines 1198-1252
- FR1-FR3 (editor lifecycle — :q is FR3's first production realisation): [Source: _bmad-output/planning-artifacts/epics.md] lines 20-22
- FR8 (`:q!` quit without saving): [Source: _bmad-output/planning-artifacts/epics.md] line 30
- FR14 (ex-line dispatch): [Source: _bmad-output/planning-artifacts/epics.md] line 39
- FR16 (Esc returns to NORMAL — Esc handler in COMMAND mode points at exline_cancel for AC4 atomicity): [Source: _bmad-output/planning-artifacts/epics.md] line 41
- FR50 (No-op on unsupported commands — exline_dispatch's no-match path): [Source: _bmad-output/planning-artifacts/epics.md] line 99
- FR52 (No silent data loss — cmd_quit's dirty refusal path): [Source: _bmad-output/planning-artifacts/epics.md] line 101
- NFR6 (No silent data loss — same surface as FR52): [Source: _bmad-output/planning-artifacts/epics.md] line 115
- NFR9 (code budget — make sizes baseline): [Source: _bmad-output/planning-artifacts/epics.md] line 121
- NFR11 (single .COM artifact): [Source: _bmad-output/planning-artifacts/epics.md] line 123
- NFR14 (sjasmplus 1.23.0): [Source: _bmad-output/planning-artifacts/epics.md] line 129
- NFR15 (CP/M 2.2 BDOS only): [Source: _bmad-output/planning-artifacts/epics.md] line 130
- NFR16 (knob centralization — EX_COMMAND_BUFFER = 64 lives in equates.inc): [Source: _bmad-output/planning-artifacts/epics.md] line 134
- NFR18 (reproducible build): [Source: _bmad-output/planning-artifacts/epics.md] line 136
- AR12 (status-message funnel — `status_set_message`): [Source: _bmad-output/planning-artifacts/epics.md] line 161
- AR13 (single screen-emission path — render.asm only; exline.asm doesn't emit): [Source: _bmad-output/planning-artifacts/epics.md] line 162
- AR14 (single buffer-mutation owner — gapbuf.asm only; exline.asm doesn't touch the gap buffer): [Source: _bmad-output/planning-artifacts/epics.md] line 163
- AR15 (single BDOS gateway — BDOS_CALL macro; dispatch.asm becomes AR15-clean): [Source: _bmad-output/planning-artifacts/epics.md] line 164
- AR16 (status-message string-table convention): [Source: _bmad-output/planning-artifacts/epics.md] line 165
- AR22 (naming): [Source: _bmad-output/planning-artifacts/epics.md] line 177
- AR23 (file structure and routine contracts): [Source: _bmad-output/planning-artifacts/epics.md] line 178
- AR24 (format conventions; length-prefixed buffer convention for ex_buffer): [Source: _bmad-output/planning-artifacts/epics.md] line 179
- AR25 (module include order — exline lands between search and fileio): [Source: _bmad-output/planning-artifacts/epics.md] line 180; [Source: _bmad-output/planning-artifacts/architecture.md] lines 940-956
- MC4 (handler signature: A = key, accumulator state in fixed addresses): [Source: _bmad-output/planning-artifacts/architecture.md] lines 529-533
- MC5 (status-message funnel — `status_set_message`): [Source: _bmad-output/planning-artifacts/architecture.md] lines 535-541
- MC6 (checked-BDOS-call macro — `BDOS_CALL`; relevant for cmd_quit's tail-JP to init_teardown's macro use): [Source: _bmad-output/planning-artifacts/architecture.md] lines 543-548
- MC7 (static memory map via state.inc; ex_buffer_text positional EQU lands here): [Source: _bmad-output/planning-artifacts/architecture.md] lines 550-555
- RI2 (render runs after each input-loop iteration; per-keystroke ex-line UI relies on this): [Source: _bmad-output/planning-artifacts/architecture.md] lines 567-569
- RI4 (cursor-positioning emission last in every render pass — AC11's mode-aware override slots in here): [Source: _bmad-output/planning-artifacts/architecture.md] lines 575-579
- RI6 (single input_get_key → dispatch loop): [Source: _bmad-output/planning-artifacts/architecture.md] lines 621-624
- BH5 (`:q` with unsaved changes — refuse with message; `:q!` abandons): [Source: _bmad-output/planning-artifacts/architecture.md] lines 699-702
- Data Flow (Keystroke Lifecycle — step 5 handler may CALL status_set_message; step 6 render_diff fires after handler returns): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1468-1505
- FR↔Module mapping (FR4-FR8 file ops — exline.asm parses, fileio.asm executes; FR3 quit — exline.asm's cmd_quit path): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1515-1516
- External Boundaries (Termination = BDOS function 0 = warm boot, owned by init.asm + exline.asm — Story 2.1 makes the exline.asm side real): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1457-1463
- Implementation Sequence (exline.asm bring-up step 9): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1576-1578
- Status-Line Message Format conventions (AR16 follow-up — generic refusal "no write since last change" vi-canon match): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1003-1037
- Static Memory Map (ex_buffer declaration; ex_buffer_text positional EQU joins this block): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1341-1399
- Deferred-from-1.3 (search_pattern / ex_buffer length-byte convention — partially resolved by AC10): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 16
- Deferred-from-1.10 (mode-transition / unbound-key parser-state-clear — stays deferred to Story 2.5+; not pinned by Story 2.1): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 86-93
- Deferred-from-1.12 (count_accumulator unbounded growth — stays deferred to Story 2.5+; Story 2.1 doesn't add a motion handler, so count semantics remain user-invisible): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 97
- inc/state.inc layout (ex_buffer at static_data_base + offset, length-prefixed): [Source: inc/state.inc] line 100
- inc/equates.inc (EX_COMMAND_BUFFER = 64): [Source: inc/equates.inc] line 33
- inc/modes.inc (MODE_COMMAND = 2; MODE_NORMAL = 0): [Source: inc/modes.inc] lines 23, 25
- inc/vt52.inc (no Story 2.1 reference; render.asm's emit_goto chain handles VT52 emission): [Source: inc/vt52.inc]
- src/vibe.asm (input_loop's per-mode demultiplex routes COMMAND keystrokes to dispatch_command; AR25 INCLUDE chain): [Source: src/vibe.asm] lines 134-180, 67-119
- src/dispatch.asm (mode_debug_quit body lines 326-344, enter_command_mode lines 245-262, unbound_command lines 410-422, dispatch_normal 0x11 entry lines 449-451, dispatch_normal ':' entry lines 485-487, dispatch_command table lines 530-535): [Source: src/dispatch.asm]
- src/statusln.asm (msg_no_write line 162, msg_mode_command line 172, msg_mode_normal line 170): [Source: src/statusln.asm]
- src/render.asm (render_diff lines 370-389, render_emit_goto lines 1189-1213, module-local scratch lines 1236-1250): [Source: src/render.asm]
- src/init.asm (init_teardown — cmd_quit / cmd_quit_force's tail-JP target; lines 379-396): [Source: src/init.asm]
- Story 1.12 (init/teardown — primary prior-art reference): [Source: _bmad-output/implementation-artifacts/1-12-init-teardown-on-hardware-smoke-test.md]
- Story 1.11 (render pipeline — render_diff is Story 2.1's modification target): [Source: _bmad-output/implementation-artifacts/1-11-render-pipeline-with-dirty-rows-scroll-ctrl-l.md]
- Story 1.10 (parser — parser-state-clear deferral relevant to mode transitions; pinned in 2.5+): [Source: _bmad-output/implementation-artifacts/1-10-command-parser-count-pending-operator-motion-prefix.md]
- Story 1.9 (dispatch — Story 2.1's primary modification target): [Source: _bmad-output/implementation-artifacts/1-9-mode-dispatch-with-sparse-table-binary-search.md]
- Story 1.5 (statusln — AR12 funnel + msg_no_write source): [Source: _bmad-output/implementation-artifacts/1-5-status-line-module-with-single-message-funnel.md]
- Story 1.3 (state.inc — ex_buffer declaration; Story-1.3 deferral resolved by AC10): [Source: _bmad-output/implementation-artifacts/1-3-static-memory-map-state-inc.md]

## Dev Agent Record

### Agent Model Used

Claude Opus 4.7 (claude-opus-4-7[1m]), invoked via the BMAD dev-story workflow on 2026-05-13.

### Debug Log References

- **Build 1 of 2 (NFR18 reproducibility):** `make clean && make` succeeded; `sha256sum vibe.com` → `622f47f5e274f3880cca1f2be5498d6344b0ef3aebf4a7689df2eedfc8fdc305`.
- **Build 2 of 2:** Same SHA: `622f47f5e274f3880cca1f2be5498d6344b0ef3aebf4a7689df2eedfc8fdc305` — byte-identical (NFR18 holds).
- **`make sizes`:** `code_section: 2236 bytes (~72% of NFR9 ~3 KB budget)`. Delta vs Story 1.12 (1947 B): **+289 B** — slightly over the Dev Notes envelope of "~120–220 B net add", largely because `exline_status_scratch` is a 66-byte `DEFS` block in the code segment (per AR23 + render.asm precedent for module-local scratch). Net composition: +exline.asm body (~245 B including the 66 B scratch) + render.asm AC11 override (~20 B) + msg_not_editor_command (+22 B) − removed handlers / msg_mode_command (~30 B) − removed Ctrl-Q entry / unbound_command (~10 B). Budget headroom for Stories 2.2–2.13: ~28%.
- **AR enforcement sweeps (AC14):**
  - `grep -rnE 'BIOS_CONOUT' src/ | grep -v 'render.asm'` → only matches in `src/exline.asm:19` (header comment) and `src/bios_1_7.inc:65` (vendor BIOS jump-table header). No call sites outside render.asm — AR13 clean.
  - `grep -nE 'gapbuf_(insert|delete|move_gap|load)' src/exline.asm` → zero matches (AR14 clean).
  - `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY|BDOS_CALL' src/exline.asm` → only match is `src/exline.asm:29` (header comment) — no call sites (AR15 clean).
  - `grep -nE 'BDOS_CALL|CALL[ \t]+BDOS_ENTRY|CALL[ \t]+0x0005' src/dispatch.asm` → only match is `src/dispatch.asm:12` (header comment) — dispatch.asm is AR15-clean for the first time (the Story-1.12 `mode_debug_quit` carve-out is gone).
  - `grep -nE 'ex_buffer[ \t]*\+[ \t]*1' src/*.asm test/cases/exline_*.asm | grep -v 'inc/state.inc'` → zero matches (AC10: every read site uses `ex_buffer_text`).
  - `grep -nE 'mode_debug_quit|enter_command_mode|unbound_command|msg_mode_command' src/ inc/` → matches in comments only (historical references in `src/init.asm`, `src/statusln.asm`, `src/dispatch.asm`, `src/vibe.asm`, `src/exline.asm`). No symbol declarations or usages remain — AC9 clean.
- **`make test`:** 27 pass (23 pre-2.1 + 4 new) + 1 deliberate `harness_fail` — matches AC12's expected baseline. The four new tests:
  - `exline_q-clean-buffer` pass (AC6 — clean `:q` → `init_teardown` stubbed)
  - `exline_q-dirty-buffer` pass (AC7 — dirty `:q` → msg_no_write + cancel-core)
  - `exline_q-bang-force` pass (AC8 — `:q!` unconditional warm-boot)
  - `exline_unknown-command` pass (AC5 — `:foo` → msg_not_editor_command + cancel-core)

### Completion Notes List

- **Production binary:** `vibe.com`, SHA256 `622f47f5e274f3880cca1f2be5498d6344b0ef3aebf4a7689df2eedfc8fdc305`, 2236 bytes (72% of NFR9 ~3 KB budget). Two consecutive `make clean && make` runs are byte-identical (NFR18).
- **All headless AR enforcement sweeps from AC14 pass cleanly.** dispatch.asm is now AR15-clean (no `BDOS_CALL` site remains) — first time since Story 1.12's bring-up shim. The lone `BDOS_CALL BDOS_EXIT` site sits inside `init_teardown` (src/init.asm), reached only via `cmd_quit` / `cmd_quit_force`'s tail-JPs from src/exline.asm.
- **Story-1.3 ex_buffer half resolved (AC10).** `ex_buffer_text EQU ex_buffer + 1` lands in `inc/state.inc` immediately after the `ex_buffer` declaration; every read site (src/exline.asm, the four new tests) uses the symbol. `deferred-work.md` updated with a "Resolved (partial) by Story 2.1" sub-bullet. The `search_pattern_text` half stays deferred to Story 3.1 (no consumer yet).
- **Cancel/banner split landed as recommended option (a) in AC5 Note.** `exline_cancel_core` clears `ex_buffer` / `mode_byte` / `status_dirty` without touching `status_buffer`; `exline_cancel` calls the core then writes `msg_mode_normal`. The no-match path in `exline_dispatch` and the dirty-refusal path in `cmd_quit` both call `exline_cancel_core` directly so their just-set banner survives.
- **`exline_dispatch` walk implementation matches the Dev Notes skeleton.** Length-prefixed `ex_buffer` compared against NUL-terminated table keys; on match `JP (HL)` tail-jumps to handler; on terminator `msg_not_editor_command` + `JP exline_cancel_core`. The `.advance_to_null` block uses `XOR A` / `CP (HL)` / `INC HL` / `JR NZ` to walk past the key (INC HL doesn't disturb flags, so the JR NZ reads the CP).
- **AC11 cursor override is single-sited in `render_diff`.** A mode-check between the `dirty_rows` clear and the trailing RI4 emit overrides `render_cursor_row` / `render_cursor_col` when `mode_byte == MODE_COMMAND`. Inert in every other mode. No new BIOS_CONOUT call site, so the Story-1.11 `render_emit_goto` D/E preservation scratch fully covers the COMMAND-mode emit path (no analogous defensive scratch needed; AC11 Note's clamp is a no-op).
- **AC7 hardware UAT intentionally deferred to Story 2.8 (per spec, option (b)).** Real INSERT-mode literal-append (which sets `buffer_dirty`) lands in 2.8; until then a hardware user cannot organically dirty the buffer to exercise the `:q` refusal. The deterministic `exline_q-dirty-buffer.asm` headless test covers AC7's code path; the synthetic-marker hack (option (a)) is explicitly rejected. Story 2.8's Dev Notes should pick up the hardware-side AC7 confirmation.
- **AC13 hardware UAT (the 8-step on-MicroBeast smoke) is pending user execution.** I cannot `make push` from this dev environment. The expected behavior is documented in AC13 and Task 11 carries the open checkboxes — the reviewer should run through the 8 steps before closing the story. Particular regressions to watch for: COMMAND-mode cursor positioning after BIOS_CONOUT register-clobber (Story 1.11's `render_emit_goto` D/E bug class). The current change does NOT add a new emit_goto call site, so the existing defensive scratch should fully cover the COMMAND-mode path — but hardware confirmation is needed.
- **Parser-state-clear on COMMAND entry stays deferred to Story 2.5+ (per Dev Notes).** `exline_begin` does NOT call any parser-state clear; the stale `count_accumulator` / `pending_operator` / `pending_motion_prefix` is invisible to the user pre-2.5.
- **dispatch_command table growth: 1 → 3 entries.** Backspace 0x08, Enter 0x0D, Esc 0x1B, sorted ascending; unbound-prefix re-pointed from `unbound_command` (now gone) to `exline_append_literal`. `DISPATCH_COMMAND_COUNT` re-resolves to 3 via the existing `($ - .entries) / 3` formula — no manual update needed.

### File List

**Created:**

- `src/exline.asm` — primary Story 2.1 deliverable (~340 lines including AR23 header). Public entry points: `exline_begin`, `exline_append_literal`, `exline_backspace`, `exline_dispatch`, `exline_cancel`, `exline_cancel_core`, `cmd_quit`, `cmd_quit_force`. Data: `exline_command_table`, `exline_status_scratch` (66-byte file-local scratch).
- `test/cases/exline_q-clean-buffer.asm` — AC6 / AC12.
- `test/cases/exline_q-dirty-buffer.asm` — AC7 / AC12.
- `test/cases/exline_q-bang-force.asm` — AC8 / AC12.
- `test/cases/exline_unknown-command.asm` — AC5 / AC12.

**Modified:**

- `src/vibe.asm` — added `INCLUDE "exline.asm"` after `parser.asm` per AR25; updated header `Dependencies:` and the input_loop comment to point at `cmd_quit` / `cmd_quit_force` instead of the retired `mode_debug_quit`; updated the dispatch.asm INCLUDE-site comment block.
- `src/dispatch.asm` — removed `mode_debug_quit`, `enter_command_mode`, `unbound_command` handler bodies; removed the 0x11 entry from `dispatch_normal` and re-stitched the adjacent-pair ASSERT chain (`ASSERT '/' > 0x0C` replaces the former `ASSERT 0x11 > 0x0C` / `ASSERT '/' > 0x11` pair); re-pointed `dispatch_normal`'s `':'` entry to `exline_begin`; rebuilt `dispatch_command` from a single Esc-only entry into three entries (Backspace 0x08 → `exline_backspace`, Enter 0x0D → `exline_dispatch`, Esc 0x1B → `exline_cancel`) with the unbound-prefix re-pointed to `exline_append_literal`; swept the header `Public:` list and Dependencies block; updated the AR15 narrative to reflect the new clean state.
- `src/statusln.asm` — removed `msg_mode_command` (no consumer); added `msg_not_editor_command: DEFB "not an editor command", 0` (AR16 conventions); updated header `Public:` list and the message-block section comment to mention Story 2.1.
- `src/render.asm` — added the AC11 mode-aware cursor-target override in `render_diff` (between the `dirty_rows` clear and the trailing RI4 emit); updated module header `Purpose:` paragraph and `Dependencies:` block to add `inc/modes.inc` + `mode_byte` + `ex_buffer`; updated the `render_diff` contract block with a `Reads (Story 2.1):` line.
- `src/init.asm` — header-only changes (no body change). Reworded references to `mode_debug_quit` in the module Purpose, the `init_teardown` Public entry block, the register conventions, the Stage-0 race-window narrative, and the `init_teardown` contract block to point at `cmd_quit` / `cmd_quit_force` (src/exline.asm) instead.
- `inc/state.inc` — added `ex_buffer_text EQU ex_buffer + 1` (positional only — no `static_off` advance, no bytes emitted) with a one-line comment noting the Story-1.3 deferral resolution; updated the header `Public:` Buffers list to include `ex_buffer_text`.
- `_bmad-output/implementation-artifacts/deferred-work.md` — added a "Resolved (partial) by Story 2.1" sub-bullet under the Story-1.3 `search_pattern` / `ex_buffer` length-byte convention entry; the `search_pattern_text` half stays deferred to Story 3.1.

### Change Log

- **2026-05-13 — Story 2.1 implementation (Status: ready-for-dev → review).**
  - Added `src/exline.asm` (FR14 ex-line surface, FR3 / FR8 / BH5 quit handlers, AR12 / AR13 / AR14 / AR15 compliant).
  - Retired `mode_debug_quit` / `enter_command_mode` / `unbound_command` / `msg_mode_command` (Stories 1.9 / 1.12 placeholders); dispatch.asm becomes AR15-clean.
  - Added `msg_not_editor_command` to statusln.asm (AR16 conventions).
  - Added AC11 COMMAND-mode cursor override to `render_diff` (`mode_byte` + `ex_buffer` reads).
  - Added `ex_buffer_text EQU ex_buffer + 1` to inc/state.inc — partial-resolves Story-1.3 deferral.
  - Added four headless tests under `test/cases/exline_*.asm` (AC5, AC6, AC7, AC8 coverage via AC12).
  - Build: byte-identical reproducible SHA256 `622f47f5e274f3880cca1f2be5498d6344b0ef3aebf4a7689df2eedfc8fdc305`; size 2236 B / 72% NFR9; 27 / 1 headless test baseline (the 1 is the deliberate `harness_fail`).
  - Hardware UAT (AC13) pending user execution — `make push` from this dev environment is not possible. AC7's hardware coverage intentionally deferred to Story 2.8 per spec.
