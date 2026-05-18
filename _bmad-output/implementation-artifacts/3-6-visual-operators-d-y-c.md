# Story 3.6: Visual operators (d, y, c)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `d`, `y`, `c` in MODE_VISUAL (any submode) to apply the operator to the current selection — delete (`d`) removes the selection and yanks it with submode-appropriate `yank_kind`, yank (`y`) copies without mutating the buffer, change (`c`) deletes-then-enters-INSERT — with vi-faithful cursor placement (cursor lands at `min(anchor, cursor)` post-operator), the yank-too-large refusal preserving the prior yank register while letting the deletion proceed (SR6 "predictable failure mode"), single-level undo recording the inverse op for VIS_CHAR / VIS_LINE via `undo_record_delete` (contiguous range payload), VIS_BLOCK d/c deliberately recording `UNDO_KIND_TOO_LARGE` (multi-region undo deferred — `u` surfaces `msg_undo_too_large`), BH3 jagged-line semantics for VIS_BLOCK (per-row deletion clipped at each row's EOL — short lines are processed only up to their EOL; the bounding rectangle is virtual; KIND_BLOCK yank format is per-row content joined by LF separators with no trailing LF), and mode returning to NORMAL (d, y) or INSERT (c) on completion via the existing `enter_normal_mode` / `enter_insert_mode` tail-JPs,
So that FR36 closes — completing the destructive / yank-only / change visual operators (the next two stories 3.7 visual shift `>` `<` and 3.8 visual case toggle `~` are siblings that follow the same `visual_apply_*` dispatch shape; this story sets the per-submode range-marshalling pattern they'll reuse).

## Acceptance Criteria

**AC1 — `dispatch_visual` gains three sorted entries `c` (0x63) / `d` (0x64) / `y` (0x79), each forward-referencing `visual_apply_operator` in `src/visual.asm`.**

**Given** `src/dispatch.asm:dispatch_visual` (currently 20 entries post-3.3 — verify via `build/vibe.lst` `DISPATCH_VISUAL_COUNT EQU 0x14`; the sort order today runs Esc / `$` / `0`..`9` / `G` / `b` / `g` / `h` / `j` / `k` / `l` / `w` at lines 651-727; operators d/y/c are documented as "deliberately remain unbound here" at lines 660-662 — that comment retires with Story 3.6)
**When** Story 3.6 lands
**Then** three new 3-byte entries are inserted in ASCII-sorted positions:
- `'c'` (0x63) — between `'b'` (0x62) at line 707-708 and `'g'` (0x67) at line 710-711 — slot 1
- `'d'` (0x64) — between `'c'` (0x63 — new) and `'g'` (0x67) — slot 2
- `'y'` (0x79) — after `'w'` (0x77) at line 725-726 — last slot
**And** each entry's `DEFW` targets `visual_apply_operator` (the single shared dispatcher — A on entry is the operator byte per MC4, branches internally on A then on `visual_submode`)
**And** the flanking `ASSERT` chain extends:
- `ASSERT 'c' > 'b'` (new)
- `ASSERT 'd' > 'c'` (new)
- `ASSERT 'g' > 'd'` (MODIFIED — was `ASSERT 'g' > 'b'` at line 709)
- `ASSERT 'y' > 'w'` (new — sorts at the end of the table)
**And** `DISPATCH_VISUAL_COUNT` (the `($ - .entries) / 3` EQU at line 727) auto-recomputes from 0x14 (20) → 0x17 (23). Cross-check `build/vibe.lst` post-build per [[feedback_create_story_cross_check]] — past stories have drifted on this metric.
**And** `dispatch_visual` table grows by **+9 B** (3 entries × 3 B; ASSERTs are assembly-time, zero runtime)
**And** the dispatch.asm module-header Dependencies block's `src/visual.asm` entry (extended by Stories 3.3 / 3.4 / 3.5) extends by one Story-3.6 paragraph documenting `visual_apply_operator` as the fourth forward-ref symbol after `visual_enter_char` (3.3), `visual_enter_line` (3.4), and `visual_enter_block` (3.5).
**And** the Story-3.5 retire-this-comment at dispatch.asm:660-662 ("Operators (d/y/c/>/</~) deliberately remain unbound here — they fall through to unbound_visual until Stories 3.6-3.8 wire visual_apply_operator") is REPLACED by a comment noting that `d` / `y` / `c` now bind to `visual_apply_operator` (Story 3.6) and that `>` / `<` / `~` remain deferred to Stories 3.7 / 3.8.
**And** `dispatch_normal` is UNCHANGED — `d` / `y` / `c` in NORMAL still route to `parser_handle_operator` (the op+motion compose path from Story 2.11). The visual bindings are deliberately separate handlers; visual operators bypass the parser's `pending_operator` state machine entirely (no `parser_handle_operator` call from the visual path — the operator IS the dispatch target).

**AC2 — `visual_apply_operator` (NEW public entry in `src/visual.asm`) is the single dispatcher: A on entry = `'c'` | `'d'` | `'y'`; stashes the operator into a new 1-byte module-local cell, then branches on `visual_submode` to one of three internal arms (CHAR / LINE / BLOCK) that compute the range and execute the operator.**

**Given** `src/visual.asm` (the public-block declaration at line 60 currently says `visual_apply_operator ; PLACEHOLDER Stories 3.6-3.8`; the comment at lines 714-717 explicitly notes no stub EQU exists — sjasmplus's two-pass model permits the forward-ref from the new dispatch_visual['c'/'d'/'y'] entries to a body that lands here)
**When** Story 3.6 lands
**Then** `visual_apply_operator:` is added as a NEW labelled public entry in `src/visual.asm`, placement chosen for code locality (recommended placement: between `visual_extend`'s body at lines 341-379 and `visual_count_lines`'s body at lines 410-454 — operator dispatch sits right after the motion-extend dispatch, mirroring the order of operations during a typical visual session "enter → extend → operate")
**And** the body performs in order:
1. `LD (visual_op_pending), A` — stash the operator key in the new module-local 1-byte cell (per AC11 — preserves the operator across arbitrary intermediate CALLs that trash A) (~3 B)
2. `LD A, (visual_submode)` — read submode (~3 B)
3. `CP VIS_BLOCK ; JP Z, _visual_op_block_arm` — BLOCK is the heavyweight path (per-row loop + KIND_BLOCK yank format + UNDO_KIND_TOO_LARGE record); separating it keeps the CHAR/LINE arms simpler (~5 B)
4. `CP VIS_LINE ; JR Z, _visual_op_line_arm` — LINE arm (~4 B)
5. `;; fall through to _visual_op_char_arm` (VIS_CHAR is value 0; serves as defensive fall-through default for any unknown submode value, mirroring `visual_extend`'s 3-way prologue from Story 3.5 AC3)
6. `_visual_op_char_arm:` (label) — computes CHAR range and joins the shared CHAR+LINE finalisation path per AC3
**And** the body for the CHAR-arm prologue + LINE-arm prologue + jump-to-shared-finalisation totals **~12 B + 18 B + 16 B = ~46 B** at the prologue + range-compute stage; the shared finalisation (`_visual_op_delete_yank_or_change`) lands separately per AC6 / AC7
**And** AR23 docstring documents: `In: A = operator byte ('c'/'d'/'y' — MC4 from dispatch_visual)`; `Out: depends on operator + submode; see per-arm AC3/AC4/AC5 contracts. On every exit: mode = MODE_NORMAL ('d', 'y') OR MODE_INSERT ('c'); cursor placed at the deletion-start (== min(anchor, cursor) projected per submode); parser state cleared (via enter_normal_mode / enter_insert_mode tail-JPs).`; `Trashes: A, BC, DE, HL, F + module-local cells.`; `Calls: motion_find_line_start (CHAR/LINE/BLOCK projections); motion_find_line_end (LINE last-line walk + BLOCK per-row line-end probe); motion_byte_at_logical (post-delete clamp probe + BLOCK content read for KIND_BLOCK yank append); visual_count_block_dims (BLOCK projection); edits_copy_to_yank (CHAR/LINE yank); edits_range_delete (CHAR/LINE delete); undo_record_delete (CHAR/LINE undo); undo_clear (BLOCK pre-clear); undo_write_header (BLOCK UNDO_KIND_TOO_LARGE direct write); status_set_message (yank-too-large surface); edits_dirty_and_redraw (success commit); enter_normal_mode (d/y tail-JP); enter_insert_mode (c tail-JP).`

**AC3 — `_visual_op_char_arm` computes the inclusive byte range `[min(anchor, cursor), max(anchor, cursor) + 1)` and routes to the shared `_visual_op_delete_yank_or_change` finalisation with HL = range_start, BC = total_bytes, A = `KIND_CHAR`.**

**Given** `visual_anchor` in offset space (per Story 3.3 SR5 — VIS_CHAR's anchor is the entry cursor offset, frozen for the session)
**When** the user presses `d` / `y` / `c` in VIS_CHAR
**Then** the arm body performs:
1. `LD HL, (cursor_offset)` — HL = landing offset (~3 B)
2. `LD DE, (visual_anchor)` — DE = anchor offset (~3 B)
3. `OR A ; SBC HL, DE` — HL = landing - anchor (signed) (~3 B)
4. `JR NC, .have_forward` — cursor >= anchor (forward or no-move): HL = positive delta (~2 B)
5. **Backward branch**: cursor < anchor; need to compute `range_start = cursor`, `total_bytes = anchor - cursor + 1`:
   - `LD HL, (visual_anchor) ; LD DE, (cursor_offset) ; OR A ; SBC HL, DE` — HL = anchor - cursor (positive delta, ~9 B)
   - `INC HL` — HL = total_bytes (inclusive: +1) (~1 B)
   - `LD B, H ; LD C, L` — BC = total_bytes (~2 B)
   - `LD HL, (cursor_offset)` — HL = range_start = cursor (~3 B)
   - `JR .char_have_range` (~2 B)
6. **`.have_forward`** (cursor >= anchor): HL still holds positive delta = landing - anchor
   - `INC HL` — HL = total_bytes (inclusive: +1) (~1 B)
   - `LD B, H ; LD C, L` — BC = total_bytes (~2 B)
   - `LD HL, (visual_anchor)` — HL = range_start = anchor (~3 B)
   - `JR .char_have_range` (~2 B)
7. **`.char_have_range`**: HL = range_start, BC = total_bytes
   - `LD A, KIND_CHAR` (~2 B)
   - `JP _visual_op_delete_yank_or_change` (~3 B)
**And** total CHAR-arm range-compute body: **~36 B**
**And** the inclusive bump (`INC HL` to add 1 to delta-to-bytes) is the **key semantic distinction** from `op_compose_d`'s op+motion path:
   - **NORMAL `dw`**: motion-based; range is exclusive of landing — `motion_w` lands cursor PAST the word; `op_compose_d` deletes `[entry, landing)` so the word's terminator (space) is NOT deleted.
   - **VISUAL `vwd` or `vld`** (select with motion, then `d`): selection-based; range is INCLUSIVE of both endpoints — vi convention is that the highlighted character IS part of the selection. The +1 bump is what makes this inclusive.
**And** the `pending_motion_inclusive` flag (Story 2.11 — set only by `motion_dollar` for `d$` inclusive-landing) is NOT read by the visual path — visual selections are ALWAYS inclusive at both ends; the bump is unconditional.
**And** 0-byte edge case: when `visual_anchor == cursor_offset` (anchor and cursor coincide; happens on bare `v` then `d` with no motion in between), the SBC produces 0; `JR NC, .have_forward` is taken; `INC HL` makes BC = 1; range = `[anchor, anchor + 1)` = single byte at anchor offset. Deletion proceeds. This matches vi: `vd` (with no motion) deletes the single character under the cursor — semantically equivalent to `x`.
**And** an inline comment documents the inclusive-bump rationale.

**AC4 — `_visual_op_line_arm` computes the line-bounded byte range covering all lines that the anchor or cursor touches; routes to the shared `_visual_op_delete_yank_or_change` finalisation with HL = range_start, BC = total_bytes, A = `KIND_LINE`. Reuses the no-trailing-LF EOF carve-out from `edits_line_range_for_count`.**

**Given** `visual_anchor` is a LINE-START (per Story 3.4 AC2 — VIS_LINE's anchor is snapped to `motion_find_line_start(cursor)` at entry; the AC2 invariant holds for the whole visual-line session)
**When** the user presses `d` / `y` / `c` in VIS_LINE
**Then** the arm body performs:
1. **Project cursor to its line-start** (anchor is already a line-start by AC2 invariant):
   - `LD HL, (cursor_offset) ; CALL motion_find_line_start` — HL = cursor_ls (~6 B)
2. **Determine min / max of the two line-starts** (anchor and cursor_ls):
   - `LD DE, (visual_anchor) ; OR A ; SBC HL, DE` — HL = cursor_ls - anchor (signed) (~6 B)
   - `JR NC, .line_forward` — cursor_ls >= anchor (forward / same line); HL still positive (~2 B)
   - **Backward** (cursor_ls < anchor): range_start = cursor_ls; range_end_seed = anchor; need to walk anchor's line forward to find that line's EOL:
     - Recover `HL = cursor_ls` via `ADD HL, DE` (~1 B)
     - PUSH HL  — [range_start = cursor_ls] (~1 B)
     - LD HL, (visual_anchor) — walker for line-end (~3 B)
     - JR .line_walk_end (~2 B)
3. **`.line_forward`** (cursor_ls >= anchor): range_start = anchor; range_end_seed = cursor_ls; walk cursor_ls's line forward:
   - `ADD HL, DE` — HL = cursor_ls (recover absolute offset) (~1 B)
   - PUSH (visual_anchor) — wait, we need to push the value as a 16-bit literal. Workaround: PUSH a register pair we've loaded.
   - `EX DE, HL ; LD HL, (visual_anchor) ; PUSH HL ; EX DE, HL` — stack: [anchor = range_start]; HL = cursor_ls (the line whose end we walk) (~7 B)
   - JR .line_walk_end (~2 B)
4. **`.line_walk_end`**: HL = walker_line_start (cursor_ls in forward case, or visual_anchor in backward case — whichever line is the MAX of the two);  [SP] = range_start (the MIN line-start)
   - `CALL motion_find_line_end` — HL = LF position OR file_length (CF=1 on no-LF / past-EOF) (~3 B)
   - `JR C, .line_at_eof` — last line has no trailing LF; need the special carve-out (~2 B)
   - **Normal case** (LF found): `INC HL` — HL = range_end (one past the LF, consuming it as part of the line range) (~1 B)
   - `EX DE, HL` — DE = range_end (~1 B)
   - POP HL — HL = range_start (~1 B)
   - `OR A ; SBC HL, DE` produces signed diff — actually we want `BC = range_end - range_start = DE - HL`:
   - `PUSH HL ; EX DE, HL ; POP DE ; OR A ; SBC HL, DE` — HL = range_end - range_start = total_bytes (~7 B)
   - `LD B, H ; LD C, L` — BC = total_bytes (~2 B)
   - **Recover HL = range_start** — we lost it. Re-load via stack tracking OR use a module-local DEFW.
   - **Simpler structural alternative**: stash range_start in a NEW module-local DEFW `visual_op_range_start` AT THE PUSH SITE; reload at `.have_line_range`.
   - `LD HL, (visual_op_range_start) ; LD A, KIND_LINE ; JP _visual_op_delete_yank_or_change` (~7 B)
5. **`.line_at_eof`** (no trailing LF — last line of file; HL = file_length on entry):
   - This is the `op_dd .at_eof` shape from `edits_line_range_for_count` lines 962-984. Implementation:
   - POP DE — DE = range_start (~1 B)
   - **Special case**: if range_start == 0 → range = `[0, file_length)`; total_bytes = file_length (don't consume the leading LF — there isn't one)
   - **General case**: range_start > 0 → range = `[range_start - 1, file_length)`; total_bytes = file_length - (range_start - 1) (consume the leading LF of the top line — so deletion removes the trailing LF of the line ABOVE the selection's top line, NOT the selection's own trailing LF which doesn't exist)
   - This special-case math is documented at `src/edits.asm:962-984` (`edits_line_range_for_count.at_eof`); reuse the algorithm verbatim
   - Total: ~15-20 B for the at_eof carve-out
**And** total LINE-arm body (forward + backward + walk + normal_done + at_eof carve-out): **~70-85 B**
**And** the at_eof leading-LF-consumption rationale (inline comment): "When the selection covers lines whose LAST line is the file-last-line WITHOUT a trailing LF, the inclusive-line range `[range_start, file_length)` would leave the file_length unchanged from a deletion semantic perspective — UNLESS we ALSO consume the LF of the line above (which becomes the new file's last line and shouldn't acquire a trailing LF). This matches `op_dd`'s vi-faithful BH2-line-level clamp." (Same comment shape as `edits_line_range_for_count:962`.)
**And** **decision**: factor out into a shared helper `visual_op_line_range` (module-local) — same shape as `edits_line_range_for_count` but takes anchor (a line-start) + cursor (any offset) instead of count + cursor. **Recommended Q-pin:** keep this helper INLINE in `_visual_op_line_arm` for Story 3.6 (no other story will need a `from-anchor-to-cursor line range`); refactor only if Story 3.7 / 3.8 also needs it. (Per Q4 in Task 0.)

**AC5 — `_visual_op_block_arm` performs per-row processing of the BLOCK rectangle: pass 1 walks rows pre-delete to compute the total yank-byte count and decide whether yank fits in `YANK_BUFFER_SIZE`; pass 2 walks rows top-to-bottom (with shift-tracking), deleting each row's clipped slice via `edits_range_delete` and optionally appending the deleted content to `yank_buffer` joined by LF separators. Records `UNDO_KIND_TOO_LARGE` (multi-region undo is deferred — `u` post-block-op surfaces `msg_undo_too_large`).**

**Given** `visual_anchor` is in offset space (per Story 3.5 SR5 — VIS_BLOCK's anchor is the entry cursor offset, NOT a line-start; column is derived on-demand)
**When** the user presses `d` / `y` / `c` in VIS_BLOCK
**Then** the arm body performs:
1. **Project the rectangle** via the existing Story-3.5 helper:
   - `CALL visual_count_block_dims` — HL = rows, BC = cols; populates the 5 module-local DEFW cells `visual_block_anchor_ls` / `_anchor_col` / `_cursor_ls` / `_cursor_col` / `_temp_rows` (~3 B)
2. **Stash rows + cols** into new module-local cells `visual_op_block_rows` (DEFW) and `visual_op_block_cols` (DEFW) — see AC11 for cell declarations (~6 B)
3. **Compute `col_min = min(anchor_col, cursor_col)`** and **`col_max = max(anchor_col, cursor_col)`**, store in module-local DEFW cells `visual_op_block_col_min` / `_col_max` (~25-30 B; uses the same SBC-and-swap-then-load pattern as `visual_count_block_dims.compute_cols` at lines 567-583)
4. **Compute `top_ls = min(anchor_ls, cursor_ls)`** — the line-start of the top row of the rectangle; store in module-local DEFW cell `visual_op_block_top_ls` (~15-20 B)
5. **Pass 1 — compute total yank-byte count** (the per-row content lengths summed, plus LF separators between rows):
   - `LD HL, 0 ; LD (visual_op_block_total_bytes), HL` — total accumulator (~6 B)
   - `LD HL, (visual_op_block_top_ls) ; LD (visual_op_block_walker), HL` — walker = top_ls (~6 B)
   - `LD HL, (visual_op_block_rows) ; LD (visual_op_block_remaining_rows), HL` — loop counter (~6 B)
   - **Loop body**:
     - `LD HL, (visual_op_block_walker) ; CALL motion_find_line_end` — HL = LF pos or file_length (~6 B)
     - Compute `line_length = line_end - walker` (~7-10 B using SBC)
     - Compute `bytes_this_row` per BH3 clipping:
       - If `col_min >= line_length`: bytes_this_row = 0 (row's line is shorter than the left edge of the rectangle — no-op for this row)
       - Else if `col_max + 1 >= line_length`: bytes_this_row = `line_length - col_min` (clipped at EOL)
       - Else: bytes_this_row = `col_max - col_min + 1` (full rectangle width)
     - Accumulate: `total_bytes += bytes_this_row`; if not the last row, `total_bytes += 1` (LF separator)
     - Advance walker to the next row's line-start (PRE-delete: `walker = line_end + 1` if LF found, else terminate the walk — but if we're at the last row this is fine; if rows > 1 and we hit EOF mid-walk that's a buffer-state inconsistency)
     - Decrement remaining_rows; loop until 0
   - Total pass-1 body: **~80-100 B** (the line_length compute + BH3 clipping + LF-separator + walker advance + loop-control)
6. **Capacity check**: `total_bytes <= YANK_BUFFER_SIZE`?
   - `LD HL, YANK_BUFFER_SIZE ; LD DE, (visual_op_block_total_bytes) ; OR A ; SBC HL, DE` — CF=1 iff total > capacity (~10 B)
   - `LD A, 1 ; LD (visual_op_block_yank_ok), A` (default OK) (~5 B)
   - `JR NC, .yank_capacity_ok` — within capacity (~2 B)
   - **Over capacity**: `XOR A ; LD (visual_op_block_yank_ok), A` (set abort flag) (~5 B); flag will cause pass 2 to skip yank-append AND status to surface `msg_yank_too_large`
   - `.yank_capacity_ok:` (~0 B label)
7. **Branch on operator**:
   - If `y` (yank-only): handle yank-only path per AC6 sub-AC — pass 2 walks rows AND appends to yank_buffer (no deletes); cursor restored to `top_ls + col_min` (top-left of rectangle); tail-JP `enter_normal_mode`
   - If `d` or `c`: continue to step 8 (delete + optional yank-append)
8. **Pre-stage UNDO_KIND_TOO_LARGE record** (block d/c does NOT use `undo_record_delete` — multi-region undo isn't supported by the single-payload undo machinery; an `UNDO_KIND_TOO_LARGE` record makes `u` surface `msg_undo_too_large` with a clear "undo not possible" UX):
   - `CALL undo_clear` — defensive pre-clear (per Story 2.13 every-mutating-op-records-something invariant) (~3 B)
   - `LD HL, (visual_op_block_top_ls)` — undo_position = top_ls (~3 B)
   - `LD BC, 0` — undo_length = 0 (placeholder; semantically meaningless for TOO_LARGE) (~3 B)
   - `LD A, UNDO_KIND_TOO_LARGE` (~2 B)
   - `CALL undo_write_header` — direct write of the header (skipping the capacity-check + payload-copy of `undo_record_delete`) (~3 B)
9. **Pass 2 — per-row delete + optional yank-append** (top-to-bottom with shift-tracking):
   - `LD HL, (visual_op_block_top_ls) ; LD (visual_op_block_walker), HL` — reset walker (~6 B)
   - `LD HL, (visual_op_block_rows) ; LD (visual_op_block_remaining_rows), HL` — reset row counter (~6 B)
   - `LD HL, yank_buffer ; LD (visual_op_block_yank_ptr), HL` — yank write pointer (~6 B)
   - **Loop body**:
     - Compute `line_end` (motion_find_line_end on current walker) (~6 B)
     - Compute `line_length`, then `bytes_this_row` via BH3 clip (~25-30 B; same shape as pass 1)
     - If `bytes_this_row > 0`:
       - Compute `delete_start = walker + col_min` (~6-8 B)
       - **If yank_ok flag is set**: append `bytes_this_row` content bytes from logical `[delete_start, delete_start + bytes_this_row)` to `yank_buffer` via `motion_byte_at_logical` loop (~25-30 B); advance `visual_op_block_yank_ptr` by `bytes_this_row`
       - **For 'd' and 'c'**: `LD HL, delete_start ; LD BC, bytes_this_row ; CALL edits_range_delete` — the existing helper loops gapbuf_delete (~6 B)
       - **For 'y'**: NO delete; only yank-append happened above
     - **If not the last row AND yank_ok flag is set**: append a literal LF (0x0A) to yank_buffer; advance yank_ptr by 1 (~10-12 B)
     - **Advance walker** for the next row:
       - For 'd'/'c': `walker = (line_end - bytes_this_row) + 1` — line_end shifted up by deleted bytes; +1 to step past the LF (~10-12 B)
       - For 'y': `walker = line_end + 1` — no shift (no deletes happened) (~6-8 B)
     - Decrement remaining_rows; loop until 0
   - Total pass-2 body: **~120-160 B** (per-row line-length + BH3 clip + delete + yank-append + LF-separator + walker advance + loop-control)
10. **Finalise yank register** (if pass 2 wrote bytes):
   - **If yank_ok flag set**: `LD A, KIND_BLOCK ; LD (yank_kind), A ; LD HL, (visual_op_block_total_bytes) ; LD (yank_length), HL` (~12 B)
   - **If yank_ok flag clear (over capacity)**: yank register is UNCHANGED (the old yank_kind / yank_length / yank_buffer content still in place); surface `msg_yank_too_large` status (~8-10 B)
11. **Cursor post-position** (matches the bounding-box top-left for d/c; for y, restored to original):
   - For 'd' / 'c': `LD HL, (visual_op_block_top_ls) ; LD DE, (visual_op_block_col_min) ; ADD HL, DE ; LD (cursor_offset), HL` (~10-12 B)
   - For 'y': cursor was never changed (no deletes happened); but the user may have moved cursor away from top-left during the visual session — restore to top-left for vi-faithfulness: same code as 'd' (~10-12 B)
12. **Commit + dispatch on operator**:
   - `CALL edits_dirty_and_redraw` (for 'd' / 'c'; for 'y' the buffer is unchanged so this would just redraw without changes — still safe to call, or skip via a flag check)
   - For 'd' or 'y': `JP enter_normal_mode` (~3 B)
   - For 'c': `JP enter_insert_mode` (~3 B)
**And** total BLOCK-arm body: **~280-360 B** (including all helper bodies, pass-1 + pass-2 loops, capacity check, undo record, yank finalisation, cursor placement, dispatch)
**And** **AR14 update — visual.asm becomes a WRITER** (this is the architectural inflection point — Stories 3.3 / 3.4 / 3.5 left visual.asm as a pure reader; Story 3.6 introduces the first `gapbuf_*` calls transitively via `edits_range_delete`; AR14 invariant in the module header MUST be updated). Specifically: visual.asm now contains paths that transitively call `gapbuf_delete` via `edits_range_delete`. AR14 grep `LD (gap_start),\|LD (gap_end),` against `src/visual.asm` still returns **zero direct matches** — the writes happen inside `gapbuf_delete`'s body (which is the AR14 owner of `gap_start` / `gap_end`); visual.asm is a TRANSITIVE writer via the documented `edits_range_delete` → `gapbuf_delete` AR14-clean path. Story 3.6 documents this as the new AR14 status; Stories 3.7 / 3.8 will keep visual.asm in this same "transitive writer" status.
**And** an inline comment in `_visual_op_block_arm` documents: "BH3 jagged-line semantic — the rectangle is virtual; per-row clipping is THIS story's responsibility (where it actually matters — the operator path). Story 3.5's `visual_count_block_dims` reports the BOUNDING rectangle for the status banner; this arm does the per-row work. Lines shorter than `col_min` contribute 0 bytes (no-op for that row); lines whose EOL falls between `col_min` and `col_max` contribute `line_length - col_min` bytes (clipped at EOL); lines longer than `col_max` contribute `col_max - col_min + 1` bytes (full rectangle width)."

**AC6 — Shared finalisation `_visual_op_delete_yank_or_change` handles the CHAR / LINE common path: branches on the stashed operator (`visual_op_pending`); for 'y' does yank-only-with-cursor-at-anchor; for 'd' records undo, yanks, deletes, places cursor at range_start (with case-3 walkback for LINE at-EOF), tail-JPs `enter_normal_mode`; for 'c' records undo (two-phase REPLACE seed), yanks, deletes, places cursor at range_start, tail-JPs `enter_insert_mode`.**

**Given** `_visual_op_char_arm` (AC3) or `_visual_op_line_arm` (AC4) has computed HL = range_start, BC = total_bytes; A = `KIND_CHAR` or `KIND_LINE`; `(visual_op_pending)` holds the operator byte
**When** control reaches `_visual_op_delete_yank_or_change`
**Then** the body performs in order:
1. **0-byte guard**: if BC == 0 → silent no-op; `JP enter_normal_mode` (~6 B)
2. **Stash range** into module-local cells for use across the sub-CALLs:
   - `LD (visual_op_range_start), HL ; LD (visual_op_range_bytes), BC ; LD (visual_op_yank_kind), A` (~12 B)
3. **Branch on operator**:
   - `LD A, (visual_op_pending) ; CP 'y' ; JP Z, .yank_only` (~10 B)
   - `CP 'c' ; JP Z, .change_path` (~5 B)
   - Fall through to `.delete_path` (operator is 'd')
4. **`.delete_path`** ('d'):
   - **Undo record** (UNDO_KIND_DELETE with payload bytes from the pre-delete buffer state):
     - `LD HL, (visual_op_range_start) ; LD BC, (visual_op_range_bytes) ; CALL undo_record_delete` (~10 B)
   - **Yank-copy attempt** (saves yank state on overflow; deletion still proceeds):
     - `LD HL, (visual_op_range_start) ; LD BC, (visual_op_range_bytes) ; LD A, (visual_op_yank_kind) ; CALL edits_copy_to_yank` (~13 B)
     - `JR NC, .delete_yank_ok` — within capacity (~2 B)
     - **Yank refused**: `LD HL, msg_yank_too_large ; XOR A ; CALL status_set_message` (~7 B)
   - **`.delete_yank_ok`**: do the actual delete:
     - `LD HL, (visual_op_range_start) ; LD BC, (visual_op_range_bytes) ; CALL edits_range_delete` (~10 B)
   - **Cursor post-position**:
     - For VIS_CHAR: cursor already at range_start (post-delete state); apply x-style clamp if cursor past EOF or on LF (matches `op_compose_d` lines 1493-1506 — ~10-15 B)
     - For VIS_LINE: apply the op_dd three-way placement (cursor at range_start in the normal case; if delete-to-EOF case-3, walk back via `motion_find_line_start(file_length - 1)`); ~25-30 B
     - **Decision**: branch on `visual_op_yank_kind` (KIND_CHAR vs KIND_LINE) at the cursor-position step; mirrors the existing op_compose_d (CHAR) vs op_dd (LINE) cursor logic
   - **Commit**: `CALL edits_dirty_and_redraw ; JP enter_normal_mode` (~6 B)
5. **`.change_path`** ('c'): same as `.delete_path` through the undo + yank + delete + cursor-clamp steps; differs at the final tail-JP:
   - `JP enter_insert_mode` instead of `JP enter_normal_mode` (~3 B)
   - The Story 2.11 op_compose_c two-phase REPLACE upgrade (where `undo_insert_exit_record` upgrades the kind from DELETE to REPLACE at INSERT exit) ALSO fires here transitively — the user types into INSERT, Escs, `enter_normal_mode` is reached, `undo_insert_exit_record` runs and upgrades the entry. **Inherited behaviour from Story 2.13's undo_insert_exit_record (`src/undo.asm`)** — no change needed for Story 3.6 to wire it; the existing INSERT-exit hook fires for any DELETE entry held alongside an INSERT session.
6. **`.yank_only`** ('y'): pure read; no buffer mutation:
   - `LD HL, (visual_op_range_start) ; LD BC, (visual_op_range_bytes) ; LD A, (visual_op_yank_kind) ; CALL edits_copy_to_yank` (~13 B)
   - `JR NC, .yank_only_ok` — within capacity (~2 B)
   - `LD HL, msg_yank_too_large ; XOR A ; CALL status_set_message` (~7 B)
   - **`.yank_only_ok`**: **cursor placement** — per epic AC, "cursor at original position (or anchor — implementation choice, vi default is cursor-at-anchor after yank)". **Pin Option A**: cursor at `min(anchor, cursor)` = range_start. This matches vim's `vwy` post-yank behaviour exactly. `LD HL, (visual_op_range_start) ; LD (cursor_offset), HL` (~7 B)
   - `JP enter_normal_mode` (~3 B)
**And** total `_visual_op_delete_yank_or_change` body: **~110-140 B** (including the 3-way branch + each operator's body + the CHAR-vs-LINE cursor placement sub-branch in 'd' path)
**And** **Cursor placement Q-pin**: the CHAR vs LINE post-delete cursor placement diverges:
- CHAR uses op_compose_d's clamp (DEC cursor if past EOF / on LF)
- LINE uses op_dd's three-way (cursor at range_start; walk back to start of new last line if delete-to-EOF)
- **Pin** (Q5): factor a small helper `_visual_op_cursor_post_delete` that takes KIND in A and branches; OR inline both arms in `_visual_op_delete_yank_or_change`. **Recommended: inline both arms** — the bodies are small (~15-30 B each) and inlining keeps each KIND path self-contained for readability. Helper factoring is post-MVP polish.

**AC7 — Yank-too-large refusal preserves the prior yank register (SR6 "predictable failure mode") AND the deletion / change STILL PROCEEDS for `d` / `c`. For `y` the buffer is untouched on every path. Status surfaces `msg_yank_too_large` on the refusal arm.**

**Given** the active visual selection's content size exceeds `YANK_BUFFER_SIZE` (1024) bytes
**When** the user presses `d`, `y`, or `c`
**Then** the contract per operator:
- **`d`**: yank register is UNCHANGED; the deletion STILL PROCEEDS (buffer mutated, undo recorded, cursor placed); mode returns to NORMAL; status surfaces `msg_yank_too_large` ("yank too large"). User sees the buffer modified but knows the deleted content is NOT available for paste. **Matches Story 2.10's `op_dd` semantic (`src/edits.asm:1170-1180`)**.
- **`y`**: yank register is UNCHANGED; buffer is UNCHANGED; cursor restored to `min(anchor, cursor)`; mode returns to NORMAL; status surfaces `msg_yank_too_large`. Pure read with no observable state change beyond mode + cursor + status.
- **`c`**: yank register is UNCHANGED; the deletion STILL PROCEEDS; the INSERT-mode entry STILL HAPPENS; status surfaces `msg_yank_too_large` (but the INSERT-mode banner "-- insert --" will overwrite the status within a few keystrokes — visible only as a transient flash). User can still type to fill the deleted region. **Same shape as `op_compose_c`'s yank refusal (`src/edits.asm:1626-1634`)**.
**And** the **AR12 status funnel** (statusln.asm) handles the status_set_message → status_buffer write; visual.asm does NOT bypass the funnel.
**And** **VIS_BLOCK behaviour**: matches per-pass-1-capacity-check logic from AC5 step 6. The pass-1 walk pre-computes total bytes; if it exceeds 1024, the `visual_op_block_yank_ok` flag is cleared; pass 2 still does the deletes (for 'd' / 'c') but skips the yank-buffer append; status surfaces `msg_yank_too_large` at finalisation.

**AC8 — Undo recording: VIS_CHAR / VIS_LINE record `UNDO_KIND_DELETE` (or `UNDO_KIND_TOO_LARGE` if the range exceeds `UNDO_PAYLOAD_SIZE`) via `undo_record_delete`. VIS_BLOCK d/c records `UNDO_KIND_TOO_LARGE` directly (multi-region undo deferred). `u` post-visual-op respects each kind: replays the delete (CHAR/LINE) OR surfaces `msg_undo_too_large` (BLOCK).**

**Given** Story 2.13's single-level undo machinery (`src/undo.asm`) + the Story 2.13 invariant "every mutating op records SOMETHING"
**When** Story 3.6's visual operators land
**Then** the undo contract per submode + operator:
- **VIS_CHAR `d`**: `undo_record_delete(HL = range_start, BC = total_bytes)` BEFORE the `edits_range_delete` call (so the gap-buffer bytes are still at their pre-delete logical offsets — same hook-site pattern as Story 2.10's `op_dd` at `src/edits.asm:1161`). On `u`: cursor returns to range_start, the deleted bytes re-insert, mode stays NORMAL. (Reuses `undo_replay_delete` from Story 2.13 — UNCHANGED.)
- **VIS_CHAR `c`**: same as `d` for the undo record (phase 1 — UNDO_KIND_DELETE with payload); `undo_insert_exit_record` at INSERT exit upgrades to UNDO_KIND_REPLACE (phase 2, per Story 2.13 Q3 Option A two-phase pin). On `u` post-INSERT-exit: cursor returns to range_start, the new-content bytes delete, the original deleted bytes re-insert, mode stays NORMAL. (Reuses `undo_replay_replace` from Story 2.13 — UNCHANGED.)
- **VIS_CHAR `y`**: NO undo entry (yank-only, no mutation, matches the Story 2.10 op_yy "yank doesn't record undo" invariant — `op_yy` at `src/edits.asm:1232` does NOT call any `undo_record_*`). On `u` post-yank: the most-recent PRIOR undo entry replays (whatever it was — vi convention). **Decision**: do NOT call `undo_clear` before the yank — preserving the prior undo entry is the correct behaviour. `op_yy` does this; Story 3.6 inherits it.
- **VIS_LINE `d`**: same shape as VIS_CHAR `d` but the range is line-bounded (covers full lines including their trailing LFs). On `u`: cursor returns to range_start, the deleted lines re-insert, mode stays NORMAL. Matches Story 2.10 `op_dd` semantics.
- **VIS_LINE `c`**: same shape as VIS_CHAR `c` but the range is line-bounded; phase-2 REPLACE upgrade fires the same way.
- **VIS_LINE `y`**: NO undo entry (as above).
- **VIS_BLOCK `d`**: `undo_clear` THEN `undo_write_header(A = UNDO_KIND_TOO_LARGE, HL = top_ls, BC = 0)` (direct write of the header, skipping `undo_record_delete`'s payload copy — multi-region payload isn't supported). On `u`: `undo_replay` reads UNDO_KIND_TOO_LARGE; falls through to the `msg_undo_too_large` arm (`src/undo.asm:225-237`); buffer / cursor unchanged. User sees "undo not possible - too large" (per `msg_undo_too_large` text in `src/statusln.asm:322`).
- **VIS_BLOCK `c`**: same as `d` — UNDO_KIND_TOO_LARGE record. The INSERT-exit hook still fires; `undo_insert_exit_record` reads UNDO_KIND_TOO_LARGE and per the Story 2.13 contract (`src/undo.asm:150-153`) LEAVES the entry as TOO_LARGE (defensive — phase 1 was TOO_LARGE, phase 2 doesn't try to upgrade). On `u` post-INSERT-exit: same outcome as VIS_BLOCK `d`.
- **VIS_BLOCK `y`**: NO undo entry (yank-only). The block walk's pass 1 + pass 2 both READ the buffer (no mutation); no `undo_clear` call.
**And** the underlying `undo_record_delete` capacity check (1024 byte payload) might kick in for very long single-character or single-line visual selections: e.g. `v G d` on a buffer where the range from cursor to EOF exceeds 1024 bytes. In that case `undo_record_delete` writes UNDO_KIND_TOO_LARGE itself per its existing contract (`src/undo.asm:506-509`); no Story-3.6-specific handling needed. **Same shape as `op_dd` on a 1000+ line selection** — inherited from Story 2.13.
**And** **decision**: VIS_BLOCK undo is deliberately limited. Future story (post-MVP polish): "Multi-region undo for block-op" — would introduce a new `UNDO_KIND_BLOCK_DELETE` kind with a per-row position+length manifest in `undo_buffer`. Not in Story 3.6 scope; logged in deferred-work.md.

**AC9 — KIND_BLOCK yank format: rows joined by LF separators; no trailing LF. `op_paste`'s existing KIND_BLOCK guard at `src/edits.asm:2179-2180` still silently no-ops (paste-from-block is a future story); the yank content lives in `yank_buffer` for the future paste handler.**

**Given** the VIS_BLOCK yank path appends per-row content to `yank_buffer`
**When** the rectangle has R rows
**Then** the yank format in `yank_buffer` is:
- `row[0]_content` (clipped per BH3) + `LF` + `row[1]_content` + `LF` + ... + `row[R-1]_content` (NO trailing LF)
- `yank_length` = total bytes (sum of row content lengths + (R-1) separator LFs)
- `yank_kind` = `KIND_BLOCK` (0x02)
**And** **empty row case** (row's line is shorter than `col_min` → bytes_this_row = 0): contributes 0 bytes of content; the LF separator is STILL emitted between this empty row and the next. So a 3-row block where row 1 is empty produces: `row[0]content + LF + LF + row[2]content` (two consecutive LFs around the empty row). Pin this for future paste consistency.
**And** **single-row case** (R=1): no LF separators; yank = `row[0]_content`. yank_length = `bytes_this_row` for the single row.
**And** **0-cols case** (`anchor_col == cursor_col` AND every row's line is at-or-past `col_min`): each row contributes 1 byte (the character at `col_min`); LF separators join them. R=3 rectangle of width 1 yields: `byte0 + LF + byte1 + LF + byte2` (5 bytes for R=3 / cols=1).
**And** `op_paste`'s `CP KIND_BLOCK ; JP Z, parser_clear` guard at `src/edits.asm:2179-2180` is UNCHANGED — pasting a KIND_BLOCK yank in NORMAL mode remains a silent no-op (a future "Story 3.6.x — KIND_BLOCK paste" polish story will handle the rectangle re-insertion semantic). The yank content sitting in `yank_buffer` is the seed for that future story.
**And** the format choice rationale (inline comment): "Rows joined by LF, no trailing LF. Future KIND_BLOCK paste in NORMAL splits on LF, inserts each component at successive lines below the cursor. Matches vim's block-yank-then-`p` behaviour. The empty-row case emits adjacent LFs — the paste handler will recognise this as a zero-width row and skip the insert for that line."

**AC10 — Mode transition: `d` and `y` tail-JP `enter_normal_mode` (per Story 3.5 AC10 — flips `mode_byte = MODE_NORMAL`, emits empty mode banner, tail-JPs `parser_clear`). `c` tail-JPs `enter_insert_mode` (sets `MODE_INSERT`, status "-- insert --", tail-JPs `parser_clear`). `visual_anchor` / `visual_submode` remain as zombie state (NOT cleared on transition — vi convention).**

**Given** the operator body has completed (range deleted / yanked, cursor placed, undo recorded, status set if needed)
**When** the final tail-JP fires
**Then** for `d` / `y`: `JP enter_normal_mode` (the existing handler at `src/dispatch.asm:312` — UNCHANGED). The handler writes `mode_byte = MODE_NORMAL`, emits the empty banner via `msg_mode_normal`, and tail-JPs `parser_clear` (which zeroes `count_accumulator` / `pending_operator` / `pending_motion_prefix` / `pending_motion_inclusive`)
**And** for `c`: `JP enter_insert_mode` (the existing handler at `src/dispatch.asm:350` — UNCHANGED). The handler writes `mode_byte = MODE_INSERT`, emits "-- insert --", and tail-JPs `parser_clear`
**And** `visual_anchor` and `visual_submode` are UNCHANGED in state — same zombie-state contract as Story 3.5 AC10. The next `v` / `V` / `Ctrl-V` re-pins both; the values are meaningless when `mode_byte != MODE_VISUAL` (SR4 invariant).
**And** the `enter_normal_mode` docstring at `src/dispatch.asm:312-330` ("Esc-from-COMMAND and Esc-from-VISUAL arrive here too") needs **zero changes** for Story 3.6 — it already covers VISUAL exit generically; submode-specific cleanup is unnecessary.
**And** **edge case**: the parser_clear tail-JP from enter_normal_mode / enter_insert_mode means the user's pending count from BEFORE the visual session is dropped. E.g. user types `5 v l d` — the `5` accumulates in count_accumulator, `v` enters VIS_CHAR (parser_clear zeroes count_accumulator at entry per Story 3.3 AC13), `l` extends by 1, `d` deletes the 2-byte selection. The original `5` never reaches anything — already cleared by `v`'s entry. Matches vi-faithful behaviour. (Documented in Story 3.3 already.)

**AC11 — Module-local state in `src/visual.asm` grows by 1 byte (`visual_op_pending`) + 10 bytes (`visual_op_range_start` / `_range_bytes` + `visual_op_yank_kind`) + 18 bytes (BLOCK arm scratch — `visual_op_block_rows` / `_cols` / `_col_min` / `_col_max` / `_top_ls` / `_walker` / `_total_bytes` / `_remaining_rows` / `_yank_ptr` / `_yank_ok` flag). Total +29 bytes module-local data; NOT in `inc/state.inc`.**

**Given** `src/visual.asm`'s module-local data block at lines 716-722 (the 5 Story-3.5 DEFW cells for `visual_count_block_dims` projection scratch)
**When** Story 3.6 lands
**Then** the following cells are added in a `;; --- Module-local data (Story 3.6 — visual_apply_operator) ---` block immediately after the Story 3.5 block:
```
;; CHAR / LINE / BLOCK shared
visual_op_pending:        DEFB 0  ; operator byte ('c' | 'd' | 'y') stashed across CALL chain
visual_op_range_start:    DEFW 0  ; HL stash across .delete_path / .change_path / .yank_only branches
visual_op_range_bytes:    DEFW 0  ; BC stash same purpose
visual_op_yank_kind:      DEFB 0  ; KIND_CHAR / KIND_LINE stashed at AC6 step 2

;; BLOCK arm scratch (per-pass-1 / pass-2 / capacity / finalise)
visual_op_block_rows:        DEFW 0  ; rows count cached from visual_count_block_dims return HL
visual_op_block_cols:        DEFW 0  ; cols count cached from visual_count_block_dims return BC
visual_op_block_col_min:     DEFW 0  ; min(anchor_col, cursor_col)
visual_op_block_col_max:     DEFW 0  ; max(anchor_col, cursor_col)
visual_op_block_top_ls:      DEFW 0  ; min(anchor_ls, cursor_ls) — line-start of top row
visual_op_block_walker:      DEFW 0  ; per-row line-start walker (pass 1 + pass 2)
visual_op_block_total_bytes: DEFW 0  ; pass-1 accumulator + final yank_length seed
visual_op_block_remaining_rows: DEFW 0  ; loop counter for both passes
visual_op_block_yank_ptr:    DEFW 0  ; pass-2 yank-buffer write pointer
visual_op_block_yank_ok:     DEFB 0  ; 0 = yank refused (over capacity); 1 = yank ok
```
**And** total state growth in `src/visual.asm` module-local data: **+29 B** (1 + 4 + 1 + 8 + 8 + 8 = 30; actual is 29 if `_remaining_rows` reuses `_rows` after pass 1 — Q-pin: reuse OR keep separate. **Pin Q6 Option A**: keep separate for clarity; +1 B is negligible)
**And** the cells are NOT exported via `inc/state.inc` — they are visual.asm-internal projection / pass-state scratch, cleared and re-written by `visual_apply_operator` at every call (no cross-call invariants). Mirrors the Story-3.5 module-local pattern.
**And** the module-header `State owned (read/write)` block extends to document the 10 new cells with a `Lifecycle:` note: "Cleared and re-written by visual_apply_operator at every call; values are valid ONLY between the helper's entry and its terminal JP (enter_normal_mode or enter_insert_mode) — caller does NOT read them. Module-local, never exported. Story 3.5's 5 visual_block_* cells are an INDEPENDENT scratch group — they cache visual_count_block_dims projections for the .block_arm caller; Story 3.6's 10 visual_op_block_* cells are for the pass-1 / pass-2 loop state and are NOT a superset of Story 3.5's cells."
**And** **No `inc/state.inc` changes** — `static_off` does not advance; cold-start LDIR zero-fill does not extend.

**AC12 — `src/visual.asm` module-header updates: AR14 status flips from "pure reader" to "transitive writer via edits_range_delete → gapbuf_delete"; the Public block flips `visual_apply_operator` from PLACEHOLDER to LANDS; the State-owned block adds 10 new module-local DEFW cells + 2 module-local DEFB cells (the `visual_op_pending` + `visual_op_block_yank_ok` flags); the Dependencies block adds `src/edits.asm` (NEW INCLUDE-chain dependency for `edits_copy_to_yank` / `edits_range_delete` / `edits_dirty_and_redraw`) and `src/undo.asm` (NEW for `undo_clear` + `undo_record_delete` + `undo_write_header`).**

**Given** `src/visual.asm` lines 1-201 (the module-header block, last updated by Story 3.5)
**When** Story 3.6 lands
**Then** the module-header updates:
- **Purpose** (lines 3-50): extend to mention "Story 3.6 — visual_apply_operator (d/y/c) lands; visual.asm becomes a TRANSITIVE WRITER of buffer state via edits_range_delete → gapbuf_delete (AR14 ownership remains with gapbuf.asm; visual.asm's writes are routed through the existing edits.asm + gapbuf.asm machinery)". Update the "Pure reader of buffer state" language to "Transitive writer of buffer state via edits_range_delete; AR13 (no direct BIOS console — unchanged), AR14 (no direct gap_start/gap_end writes — STATUS CHANGED: visual.asm now CALLS edits_range_delete which transitively writes gap_start/gap_end via gapbuf_delete; the AR14 ownership of gap_start/gap_end remains with gapbuf.asm, but visual.asm is now in the call-graph from a buffer-mutating path), AR15 (no raw BDOS — unchanged)".
- **Public** (lines 51-64): flip `visual_apply_operator` from `PLACEHOLDER Stories 3.6-3.8` to `LANDS Story 3.6 — (d/y/c on VIS_CHAR/LINE/BLOCK selections); siblings for >/</~ remain placeholders for Stories 3.7/3.8`.
- **State owned (read/write)** (lines 66-103): extend to declare the 10 new module-local cells per AC11 with a `Lifecycle:` note distinguishing them from Story 3.5's 5 cells.
- **Register conventions** (lines 112-174): add the `visual_apply_operator` In/Out/Trashes/Calls block per AC2's contract.
- **Dependencies** (lines 175-201): add `src/edits.asm` (Story 3.6 NEW — `edits_copy_to_yank` / `edits_range_delete` / `edits_dirty_and_redraw`; backward-resolved since edits.asm INCLUDEs BEFORE visual.asm in the vibe.asm AR25 chain — edits at vibe.asm:155, visual at vibe.asm:164) and `src/undo.asm` (Story 3.6 NEW — `undo_clear` / `undo_record_delete` / `undo_write_header`; **forward-resolved** since undo.asm INCLUDEs AFTER visual.asm in the AR25 chain — undo at vibe.asm:175 or later post-Story-2.13). Forward-resolution via sjasmplus's two-pass; **mirror the `op_undo` forward-ref pattern from Story 2.13's dispatch_normal['u'] which crosses the same AR25 ordering**.
- **Inline comment block** at lines 28-35 (the BH3 jagged-line semantic block): expand to note that Story 3.6 is the FIRST consumer of the rectangle's per-row clipping rule — Story 3.5 reported the bounding box; Story 3.6 actually does the per-row clipped operations.

**AC13 — Hardware UAT passes the visual-operators journey script on the real MicroBeast.**

**Given** I rebuild `vibe.com` with the Story-3.6 patch applied and `make push` it to MicroBeast
**When** I run the UAT script below from CCP
**Then** every step matches the predicted observation:

```
 1. STAT B:fizzbuzz.fs       → confirm fixture present (multi-line
                               source file — same as Stories 3.3 /
                               3.4 / 3.5 UAT'd against; any multi-
                               line .fs / .txt file works)
 2. vibe fizzbuzz.fs         → cursor at offset 0 (first byte of
                               line 1); mode NORMAL; status banner
                               empty
                               [[feedback_uat_trace_cursor]]: post-:e
                               cursor lands at offset 0
 3. v l l l                  → enter VIS_CHAR; extend right 3 cols;
                               status "-- visual -- 4" (anchor=0,
                               cursor=3, count = |3-0|+1 = 4)
 4. y                        → AC6 yank-only: yank register gets
                               4 bytes (KIND_CHAR); cursor restored
                               to range_start = 0; mode = NORMAL;
                               status banner clears (mode_normal pad);
                               buffer UNCHANGED on disk (test with
                               :q!  later or just observe screen)
 5. p                        → AC9 paste-from-CHAR-yank (Story 2.12):
                               4 bytes paste AFTER cursor; cursor
                               lands on the LAST byte of the pasted
                               word (vi-faithful); buffer_dirty=1;
                               status banner clears
 6. u                        → undo the paste; cursor back at offset
                               0; the 4 pasted bytes gone; buffer
                               restored to its post-`y`-pre-`p` state
                               (matches Story 2.13 op_undo of paste)
 7. v l l l                  → re-enter VIS_CHAR; same range as step 3
 8. d                        → AC3+AC6: yank 4 bytes (KIND_CHAR);
                               undo records UNDO_KIND_DELETE with
                               the 4 bytes in undo_buffer; delete
                               4 bytes from offset 0..3; cursor at
                               offset 0 (now sitting on what WAS
                               offset 4); mode = NORMAL; buffer
                               shorter by 4 bytes; status banner
                               clears
 9. u                        → AC8: replay UNDO_KIND_DELETE; the 4
                               bytes re-insert at offset 0; cursor
                               at offset 0; buffer restored
10. V                        → enter VIS_LINE; anchor snaps to
                               line-start of cursor=0 (already 0);
                               status "-- visual line -- 1"
11. j j                      → cursor advances 2 lines (sticky col
                               preserved); status "-- visual line --
                               3" (rows 0, 1, 2 in selection)
12. d                        → AC4+AC6+AC8: yank 3 lines worth of
                               bytes (KIND_LINE; includes the
                               trailing LFs); undo records
                               UNDO_KIND_DELETE; delete the 3 lines;
                               cursor at offset 0 (or case-3 walk-
                               back if the rest of the file was tiny
                               — fizzbuzz has >3 lines so cursor
                               stays at the new line 1's start =
                               offset 0); mode = NORMAL; status
                               clears; file is shorter by 3 lines
13. u                        → AC8: replay UNDO_KIND_DELETE; the 3
                               lines re-insert; cursor at offset 0;
                               buffer restored
14. V j                      → re-enter VIS_LINE; extend 1 line;
                               status "-- visual line -- 2"
15. y                        → AC6: yank 2 lines (KIND_LINE; with
                               trailing LFs); cursor at range_start
                               = 0; buffer UNCHANGED; mode = NORMAL
16. j j G                    → motion past selection; mode NORMAL
                               (no longer in visual); cursor at
                               last-line-start (G lands at line-
                               start per Story 2.6)
17. p                        → paste 2 lines BELOW cursor (KIND_LINE
                               semantic from Story 2.12); cursor at
                               start of the FIRST inserted line;
                               file grows by 2 lines
18. u                        → undo the paste; the 2 lines removed;
                               cursor at offset (paste-start - 0);
                               buffer restored
19. gg                       → return to BOF (offset 0)
20. Ctrl-V l l l j j         → enter VIS_BLOCK; extend right 3 cols
                               and down 2 lines; status
                               "-- visual block -- 3x4" (rows=3,
                               cols=4 — assuming fizzbuzz lines all
                               ≥ 4 chars; if any line is shorter,
                               status still reports the bounding 3x4
                               but the per-row clipping happens at
                               the operator path)
21. d                        → AC5+AC8: per-row delete of the 3x4
                               rectangle; if any row's line is ≥ 4
                               chars, deletes 4 bytes from that row;
                               if a row is shorter, deletes only up
                               to EOL (BH3); yank register gets the
                               rows joined by LFs (KIND_BLOCK; per
                               AC9 format); undo records
                               UNDO_KIND_TOO_LARGE (block multi-
                               region undo is deferred); cursor at
                               top-left (offset 0); mode = NORMAL;
                               buffer mutated; status banner clears.
                               **Hardware test for BH3 — observe that
                               short lines in fizzbuzz are clipped at
                               their EOL (not padded).**
22. u                        → AC8: UNDO_KIND_TOO_LARGE; surfaces
                               `msg_undo_too_large` = "undo not
                               possible - too large"; buffer / cursor
                               UNCHANGED (the block-d damage is NOT
                               undone — documented limitation,
                               surfaced via status). User can :q!
                               to reload the file without saving.
23. :q!                      → force-quit without saving; control
                               returns to CCP. **AR14 invariant
                               pinned by UAT: the buffer file on disk
                               is unchanged across all of steps 4-22
                               (we never `:w`ed during the session).
                               No silent data loss — buffer_dirty was
                               1 from step 8 onward but `:q!` honours
                               the force-flag.**
24. vibe fizzbuzz.fs         → reload to verify the file on disk is
                               UNCHANGED from the original (BH5 +
                               FR51 sanity check). Cursor at offset
                               0; mode NORMAL.
25. l l l l                  → cursor at offset 4 (line 1, col 4)
26. v 2 j                    → enter VIS_CHAR; counted-motion `2j`
                               extends 2 lines down keeping sticky
                               col 4; status updates to a multi-
                               line CHAR selection
27. c                        → AC7: yank + delete (KIND_CHAR);
                               undo records DELETE (phase 1);
                               cursor at range_start; mode = INSERT;
                               status "-- insert --"
28. xyzzy                    → type 5 chars; gap-buffer takes them
                               (Story 2.8 INSERT mode)
29. Esc                      → exit INSERT; undo_insert_exit_record
                               upgrades the DELETE entry to REPLACE
                               (phase 2 — same as op_compose_c);
                               mode = NORMAL; status pads to empty
30. u                        → AC8: replay UNDO_KIND_REPLACE; the
                               5 chars "xyzzy" delete; the original
                               deleted bytes re-insert; cursor at
                               the original range_start; mode =
                               NORMAL; file restored to its post-
                               step-25 state
31. :q!                      → force-quit; back at CCP
```

**AC14 — 8 new headless tests under `test/cases/visual_*.asm` + 1 parser-dispatch test pass.**

**Given** `make test` runs from a fresh tree
**When** the new test cases are added (sentinel band 0xD0..0xD7 for the visual operator tests + 0xEE for the parser-dispatch coverage; band 0xBF reserved by Story 3.5's multi-digit-banner Review patch; bands 0xBA..0xBE consumed by Story 3.5; 0xC0..0xCF consumed by Story 2.13's undo_* tests)
**Then** the following 8 visual-operator tests PASS:
- `visual_d-char.asm` (sentinel 0xD0) — AC3 / AC6 / AC8 VIS_CHAR `d`. Buffer `"abcde\nfghij"` (11 B); cursor=0; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_CHAR`, `visual_anchor = 0`; pre-extend cursor=3 via two `motion_l` calls (so cursor=3, range = `[0, 4)` = 4 bytes). CALL `visual_apply_operator` with A='d'. Expect: `mode_byte = MODE_NORMAL`, `cursor_offset = 0`, buffer content first 7 bytes = `"e\nfghij"` (the first 4 bytes "abcd" deleted; LF and onward shifted up by 4), `gap_start` reflects the 4-byte delete, `yank_kind = KIND_CHAR`, `yank_length = 4`, `yank_buffer[0..3] = "abcd"`, `undo_kind = UNDO_KIND_DELETE`, `undo_position = 0`, `undo_length = 4`, `undo_buffer[0..3] = "abcd"`. Verifies the full happy-path delete: range compute (inclusive bump) + yank + undo + delete + cursor placement + mode transition.

- `visual_y-line.asm` (sentinel 0xD1) — AC4 / AC6 VIS_LINE `y`. Buffer `"abcde\nfghij\nklmno"` (17 B; LFs at 5, 11); cursor=8 (line 2 col 2); pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_LINE`, `visual_anchor = 6` (motion_find_line_start(8) = 6 = line 2's start, per AC2 of Story 3.4 — anchor pinned at line-start). CALL `visual_apply_operator` with A='y'. Expect: `mode_byte = MODE_NORMAL`, `cursor_offset = 6` (range_start; cursor moved from 8 to 6), buffer content UNCHANGED (yank-only), `yank_kind = KIND_LINE`, `yank_length = 12` (6 bytes "fghij\n" + 6 bytes "klmno\n" — wait, only 1 line was selected: anchor=6, cursor=8 both on line 2 → range = whole-line-2 = `[6, 12)` = 6 bytes "fghij\n"). Actually we want the SINGLE-line case here for the simplest LINE-arm test; pin yank_length = 6, yank_buffer[0..5] = `"fghij\n"`. `undo_kind` UNCHANGED (y doesn't record undo).

- `visual_c-char-enters-insert.asm` (sentinel 0xD2) — AC7 / AC6 VIS_CHAR `c`. Buffer `"abcdef"` (6 B); cursor=4 (col 4 = 'e'); pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_CHAR`, `visual_anchor = 2` (col 2 = 'c'); range = `[2, 5)` = 3 bytes "cde". CALL `visual_apply_operator` with A='c'. Expect: `mode_byte = MODE_INSERT`, `cursor_offset = 2`, buffer first 3 bytes = `"abf"` (the 3 bytes "cde" deleted), `yank_kind = KIND_CHAR`, `yank_length = 3`, `yank_buffer[0..2] = "cde"`, `undo_kind = UNDO_KIND_DELETE` (phase 1 — phase 2 REPLACE upgrade happens at INSERT-exit which this unit test doesn't exercise), `status_buffer` starts with "-- insert --" (set by enter_insert_mode tail-JP).

- `visual_d-block-jagged.asm` (sentinel 0xD3) — **CRITICAL AC5 / BH3 test**. Buffer `"abcdef\nxy\nabcdef"` (16 B; line 1 = 6 chars, line 2 = 2 chars, line 3 = 6 chars; LFs at 6, 9 — same jagged fixture as Story 3.5 AC12). cursor=0; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_BLOCK`, `visual_anchor = 0`; pre-extend cursor=14 via simulated motions (cursor=14 → line 3 col 2). The rectangle is rows=3, cols=3 (anchor_col=0, cursor_col=2, |2-0|+1=3). Expected per-row clipped slices:
  - Row 0 (line 1, "abcdef", line_length=6): col_min=0, col_max=2; bytes = "abc" (3 bytes)
  - Row 1 (line 2, "xy", line_length=2): col_min=0; line_length=2 ≥ col_min so bytes_this_row = min(col_max+1, line_length) - col_min = min(3, 2) - 0 = 2 bytes = "xy"
  - Row 2 (line 3, "abcdef", line_length=6): bytes = "abc" (3 bytes)
  CALL `visual_apply_operator` with A='d'. Expect: `mode_byte = MODE_NORMAL`, `cursor_offset = 0` (top-left), buffer first 8 bytes = `"def\n\nde"` ... wait let me re-check: post-delete, row 0's "abc" deleted from offset 0 → line 1 is now "def\n" at offsets 0-3; row 1's "xy" deleted from offset 4 → line 2 is now empty "\n" at offset 4; row 2's "abc" deleted from offset 5 → line 3 is now "def" at offsets 5-7. Total buffer: `"def\n\ndef"` = 8 bytes. So expect `gap_start` reflects 8-byte file_length; buffer first 8 bytes = `"def\n\ndef"`. `yank_kind = KIND_BLOCK`, `yank_length = 9` (3 + 1 LF + 2 + 1 LF + 3 = 9), `yank_buffer[0..8] = "abc\nxy\nabc"`. `undo_kind = UNDO_KIND_TOO_LARGE` (block multi-region undo deferred). **Verifies the full BH3 per-row clipping invariant + KIND_BLOCK yank format with empty-row LF separator handling.**

- `visual_d-yank-too-large.asm` (sentinel 0xD4) — AC7 yank-too-large refusal for `d`. Buffer of 1025 bytes (just over YANK_BUFFER_SIZE = 1024); cursor=0; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_CHAR`, `visual_anchor = 0`; pre-extend cursor=1024 (so range = `[0, 1025)` = 1025 bytes, exceeds capacity). Pre-seed yank_kind = KIND_LINE, yank_length = 5, yank_buffer[0..4] = "PREV1" (sentinel for "register UNCHANGED on refusal"). CALL `visual_apply_operator` with A='d'. Expect: `mode_byte = MODE_NORMAL`, buffer DELETED (1025 bytes gone — gap_start reflects empty buffer), `yank_kind = KIND_LINE` (UNCHANGED — refusal preserves register), `yank_length = 5` (UNCHANGED), `yank_buffer[0..4] = "PREV1"` (UNCHANGED), `status_buffer` starts with "yank too large", `undo_kind = UNDO_KIND_TOO_LARGE` (1025 bytes > UNDO_PAYLOAD_SIZE = 256 also triggers undo over-capacity, surfacing the same "yank too large" status — both capacity checks land at TOO_LARGE).

- `visual_y-block.asm` (sentinel 0xD5) — AC5 + AC9 KIND_BLOCK yank format coverage. Buffer `"abcd\nefgh\nijkl"` (14 B; 3 lines × 4 chars; LFs at 4, 9); cursor=0; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_BLOCK`, `visual_anchor = 0`; pre-extend cursor=11 (line 3 col 2). Rectangle: rows=3, cols=3 (anchor_col=0, cursor_col=2). Per-row: row 0 = "abc" (3 B); row 1 = "efg" (3 B); row 2 = "ijk" (3 B). Total yank = 3+1+3+1+3 = 11 B. CALL `visual_apply_operator` with A='y'. Expect: `mode_byte = MODE_NORMAL`, `cursor_offset = 0` (restored to top-left), buffer UNCHANGED (yank-only — yank-y doesn't delete), `yank_kind = KIND_BLOCK`, `yank_length = 11`, `yank_buffer[0..10] = "abc\nefg\nijk"` (no trailing LF per AC9). `undo_kind` UNCHANGED.

- `visual_c-line-enters-insert.asm` (sentinel 0xD6) — AC4 + AC7 VIS_LINE `c`. Buffer `"first line\nsecond line\nthird line"` (32 B; LFs at 10, 22); cursor=0; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_LINE`, `visual_anchor = 0` (line 1's start). Pre-extend cursor=15 (line 2 col 4 = 'n' in "second"); selection covers lines 1 AND 2 (anchor's line + cursor's line). Range = `[0, 22)` = 22 bytes (entire lines 1 and 2 including their LFs). CALL `visual_apply_operator` with A='c'. Expect: `mode_byte = MODE_INSERT`, `cursor_offset = 0`, buffer first 10 bytes = `"third line"` (lines 1+2 deleted, "third line" shifted to offset 0; gap_start reflects 10-byte file_length), `yank_kind = KIND_LINE`, `yank_length = 22`, `yank_buffer[0..21] = "first line\nsecond line\n"`, `undo_kind = UNDO_KIND_DELETE` (phase 1), `status_buffer` starts with "-- insert --".

**And** the parser-dispatch coverage test PASSES:
- `parser_visual_d-dispatch.asm` (sentinel 0xEE) — AC1 end-to-end dispatch wiring. Buffer `"abc"` (3 B); pre-set `cursor_offset = 0`, `mode_byte = MODE_VISUAL`, `visual_submode = VIS_CHAR`, `visual_anchor = 0`; pre-extend cursor=2 (so range = 3 bytes). `status_dirty = 0x80` (sentinel — verify the dispatcher overwrote it). Drive `'d'` through `dispatch_key` with `dispatch_visual`: `LD A, 'd' ; LD HL, dispatch_visual ; LD B, DISPATCH_VISUAL_COUNT ; CALL dispatch_key`. Verify post-call: `mode_byte = MODE_NORMAL`, `cursor_offset = 0`, buffer empty (all 3 bytes deleted), `yank_kind = KIND_CHAR`, `yank_length = 3`, `yank_buffer[0..2] = "abc"`, `status_dirty = 1`. Confirms `dispatch_visual['d']` is wired end-to-end to `visual_apply_operator` and the AC1 table-insertion landed in the right sorted slot (binary-search must find 'd' between 'c' and 'g').

**Test count target: 232 (post-3.5 incl. Review-patch banner test) → 240 PASS (+8: 7 visual operator + 1 parser-dispatch) / 1 deliberate-fail (`harness_fail` sentinel) unchanged.**

## Tasks / Subtasks

- [x] **Task 0** (pre-dev pin with Ant — Option A recommended across the board, consistent with Stories 3.3 / 3.4 / 3.5 precedent):
  - [x] Q1 — Cursor placement for `y` in VISUAL. **Recommended: Option A** — cursor at `range_start = min(anchor, cursor)`. Matches vim's default visual-yank cursor behaviour. Alternative: Option B = cursor at anchor (not range_start; differs when motion was backward); rejected — `min(anchor, cursor)` is identical when motion is forward AND more natural when motion is backward (cursor lands at the TOP of the selection, which is intuitive).
  - [x] Q2 — VIS_BLOCK undo policy. **Recommended: Option A** — record `UNDO_KIND_TOO_LARGE` directly via `undo_write_header`; `u` surfaces `msg_undo_too_large`. Alternative: Option B = silently skip undo (don't even write a header; `u` replays whatever was recorded BEFORE the block-op) — rejected, violates the Story 2.13 invariant "every mutating op records SOMETHING". Option C = full multi-region undo (new UNDO_KIND_BLOCK_DELETE with per-row manifest in undo_buffer) — out of scope for Story 3.6; logged in deferred-work.md.
  - [x] Q3 — KIND_BLOCK yank format. **Recommended: Option A** — rows joined by LF; no trailing LF. Sets up future KIND_BLOCK paste (Story 3.6.x polish). Alternative: Option B = include trailing LF (matches LINE yank format); rejected — block-paste semantics need to recognise row boundaries; explicit LF separators are unambiguous. Option C = length-prefixed per-row records — rejected, unnecessary complexity.
  - [x] Q4 — Factor a `visual_op_line_range` helper or inline the line-arm range-compute. **Recommended: Option A** — inline in `_visual_op_line_arm`. Alternative: Option B = factor to a shared helper (mirrors `edits_line_range_for_count`); rejected — only one caller in Story 3.6; refactor if Stories 3.7 / 3.8 also need it (`>` and `<` are also line-class operators per Story 2.11 precedent; revisit at the 3.7 dev pass).
  - [x] Q5 — Post-delete cursor placement for CHAR vs LINE: factor `_visual_op_cursor_post_delete` helper or inline. **Recommended: Option A** — inline both arms. Alternative: Option B = helper that takes KIND in A; rejected — each arm's body is ~15-30 B; inlining keeps the kind-specific logic at its use site (better readability than indirection through a helper).
  - [x] Q6 — Reuse `visual_op_block_rows` cell as `_remaining_rows` counter after pass 1, or keep separate? **Recommended: Option A** — keep separate (+1 B is negligible; clearer when reading the loops). Alternative: Option B = reuse (saves 2 B but obscures the loop counter's identity).
  - [x] Q7 — Test-count target. **Recommended: Option A** — +8 tests (7 visual operator + 1 parser-dispatch). Final test count: 232 → 240. Covers AC3 (CHAR d, CHAR yank-too-large) + AC4 (LINE y, LINE c with INSERT entry) + AC5/BH3 (BLOCK d with jagged fixture, BLOCK y format) + AC1 (dispatch wiring). Epic's minimum is 4 (`visual_d-char.asm`, `visual_y-line.asm`, `visual_c-char-enters-insert.asm`, `visual_d-block-jagged.asm`); the +4 extras are coverage for the BLOCK-y format / yank-too-large refusal / CHAR-vs-LINE c flavour / dispatch wiring.
  - [x] Q8 — Commit strategy. **Recommended: Option A** — single dev commit (matches Stories 3.1 / 3.2 / 3.3 / 3.4 / 3.5 Epic-3 pattern).
  - [x] Q9 — Block paste behaviour (Story 3.6.x). Story 3.6 SCOPE: KIND_BLOCK yank lands content in yank_buffer; `op_paste`'s existing KIND_BLOCK guard at `src/edits.asm:2179-2180` STAYS as a silent no-op. **Recommended: Option A** — defer block-paste to a follow-up polish story; log in deferred-work.md. Alternative: Option B = land block-paste in this story; rejected — significant new code path (per-row insert at successive lines with sticky-col logic); doubles the story scope.

- [x] **Task 1** — Cross-cutting state declarations:
  - [x] 1.1 — Add 10 module-local DEFW cells + 2 DEFB cells to `src/visual.asm`'s end-of-module data block per AC11. Land after the Story 3.5 cells (visual_block_*) in a new `;; --- Module-local data (Story 3.6 — visual_apply_operator) ---` block.
  - [x] 1.2 — Confirm `yank_buffer` (1024 B at GAP_BUFFER_BASE + GAP_BUFFER_MAX; `inc/state.inc:207`) has slack for the worst-case KIND_BLOCK yank (a 24-row × 80-col rectangle = 24×80 + 23 LF separators = 1943 B → OVER capacity; capacity check fires). Pin: SR6 1024-B yank ceiling is unchanged.
  - [x] 1.3 — Confirm `undo_buffer` (UNDO_PAYLOAD_SIZE = 256 B; `inc/equates.inc:109`) — for CHAR/LINE delete, `undo_record_delete` does its own capacity check; for BLOCK we direct-write UNDO_KIND_TOO_LARGE bypassing the payload entirely.

- [x] **Task 2** — Extend `dispatch_visual` in `src/dispatch.asm`:
  - [x] 2.1 — Insert `'c'` (0x63) entry between `'b'` (0x62) at line 707-708 and `'g'` (0x67) at line 710-711 per AC1. Add `ASSERT 'c' > 'b'` flanking it.
  - [x] 2.2 — Insert `'d'` (0x64) entry between `'c'` (0x63 — new) and `'g'` (0x67) per AC1. Add `ASSERT 'd' > 'c'` flanking it. Modify the existing `ASSERT 'g' > 'b'` at line 709 to `ASSERT 'g' > 'd'` (sort-chain repair).
  - [x] 2.3 — Insert `'y'` (0x79) entry after `'w'` (0x77) at line 725-726 per AC1. Add `ASSERT 'y' > 'w'` flanking it.
  - [x] 2.4 — All three entries DEFW `visual_apply_operator` (forward-ref via sjasmplus two-pass per AC2's INCLUDE-order analysis — visual.asm INCLUDEs AFTER dispatch.asm in vibe.asm's AR25 chain).
  - [x] 2.5 — Verify `DISPATCH_VISUAL_COUNT` auto-recomputes via `($ - .entries) / 3` from 0x14 (20) to 0x17 (23). Cross-check `build/vibe.lst` post-build per [[feedback_create_story_cross_check]] — past stories have drifted on this metric (Story 3.5's spec said 37 → 38 for dispatch_normal; verified actual; the same care needed here).
  - [x] 2.6 — Update the comment block at `src/dispatch.asm:660-662` per AC1: replace "Operators (d/y/c/>/</~) deliberately remain unbound here — they fall through to unbound_visual until Stories 3.6-3.8 wire visual_apply_operator" with "Operators `d` / `y` / `c` bound to `visual_apply_operator` (Story 3.6); `>` / `<` (Story 3.7) and `~` (Story 3.8) remain deferred — they fall through to unbound_visual until those stories land".
  - [x] 2.7 — Extend `src/dispatch.asm` module-header Dependencies block with a Story 3.6 paragraph documenting `visual_apply_operator` as the fourth forward-ref symbol from this module into `src/visual.asm` (after Stories 3.3 / 3.4 / 3.5's three visual entry handlers).
  - [x] 2.8 — `dispatch_normal` left UNCHANGED — `d` / `y` / `c` in NORMAL still route to `parser_handle_operator` (the op+motion compose path from Story 2.11); visual operators bypass that entirely.

- [x] **Task 3** — Add `visual_apply_operator` + sub-arms to `src/visual.asm`:
  - [x] 3.1 — Add the `visual_apply_operator:` public entry per AC2 — placement adjacent to / right after `visual_extend`'s body at lines 341-379 (chosen for code locality — operator dispatch after motion-extend dispatch). AR23 docstring above per AC2.
  - [x] 3.2 — Add `_visual_op_char_arm:` body per AC3 — adjacent to `visual_apply_operator` (right after the prologue's fall-through arrives there). Inline comment documenting the inclusive-bump rationale.
  - [x] 3.3 — Add `_visual_op_line_arm:` body per AC4 — adjacent to `_visual_op_char_arm`. Includes the at-EOF carve-out matching `op_dd`/`edits_line_range_for_count` shape. Inline comment documenting the carve-out's vi-faithful rationale.
  - [x] 3.4 — Add `_visual_op_block_arm:` body per AC5 — adjacent to `_visual_op_line_arm`. Includes pass-1 (yank-size pre-compute) + capacity check + pass-2 (delete + yank-append + shift-tracking) + cursor placement + dispatch. Inline comments per AC5 documenting BH3 per-row clipping semantics.
  - [x] 3.5 — Add `_visual_op_delete_yank_or_change:` shared finalisation per AC6 — adjacent to `_visual_op_block_arm`. Handles the .delete_path / .change_path / .yank_only 3-way branch for CHAR + LINE.
  - [x] 3.6 — Add the 12 module-local cells per Task 1.1.
  - [x] 3.7 — Module-header (lines 1-201) per AC12: flip `visual_apply_operator` from PLACEHOLDER to LANDS at line 60; extend State-owned block to list the 12 new module-local cells with Lifecycle note; extend Dependencies block with `src/edits.asm` + `src/undo.asm` entries; update the AR14 Purpose paragraph to reflect the "transitive writer" status; add the `visual_apply_operator` Register conventions block.
  - [x] 3.8 — AR sweep on `src/visual.asm` post-3.6:
    - `BIOS_CONOUT` / `BDOS_CALL` / `CALL 0x0005` = zero matches (AR13 / AR15 unchanged)
    - `LD (gap_start),` / `LD (gap_end),` = zero matches (AR14 ownership stays with gapbuf.asm; visual.asm's writes are TRANSITIVE via edits_range_delete)
    - `CALL gapbuf_delete` = zero matches (visual.asm doesn't call gapbuf primitives directly; it goes through `edits_range_delete`)
    - `CALL edits_range_delete` = expected matches (Story 3.6 introduces this — the AR14-clean transitive write path)

- [x] **Task 4** — Headless tests (8 new files in `test/cases/`):
  - [x] 4.1 — `visual_d-char.asm` (sentinel 0xD0) — AC3 / AC6 / AC8 VIS_CHAR `d` happy path per AC14.
  - [x] 4.2 — `visual_y-line.asm` (sentinel 0xD1) — AC4 / AC6 VIS_LINE `y` happy path per AC14.
  - [x] 4.3 — `visual_c-char-enters-insert.asm` (sentinel 0xD2) — AC3 / AC6 / AC7 VIS_CHAR `c` per AC14.
  - [x] 4.4 — `visual_d-block-jagged.asm` (sentinel 0xD3) — **CRITICAL AC5 / BH3 test** per AC14.
  - [x] 4.5 — `visual_d-yank-too-large.asm` (sentinel 0xD4) — AC7 yank refusal preserves prior register per AC14.
  - [x] 4.6 — `visual_y-block.asm` (sentinel 0xD5) — AC5 + AC9 KIND_BLOCK yank format per AC14.
  - [x] 4.7 — `visual_c-line-enters-insert.asm` (sentinel 0xD6) — AC4 + AC7 VIS_LINE `c` per AC14.
  - [x] 4.8 — `parser_visual_d-dispatch.asm` (sentinel 0xEE) — AC1 end-to-end dispatch wiring per AC14.
  - [x] 4.9 — Sentinel band reservations: 0xD0..0xD6 + 0xEE consumed (7 visual_op tests at 0xD0..0xD6 + 1 parser-dispatch at 0xEE = 8 new tests total); 0xD7..0xDF available for Story 3.7 / 3.8.
  - [x] 4.10 — Fixture-seeding convention matches Stories 3.3 / 3.4 / 3.5: literal `.payload` block, `gapbuf_init` + LDIR into `GAP_BUFFER_BASE`, `(gap_start) = GAP_BUFFER_BASE + length`. INCLUDE chain matches `visual_block-rectangle-extends.asm` (lines 154-169 — full src chain plus test_teardown_stub + test_input_loop_stub + state.inc at end). All Story 3.6 tests also `INCLUDE "../../src/undo.asm"` (needed transitively now that visual.asm calls undo helpers).
  - [x] 4.11 — No bulk INCLUDE patch needed for visual.asm — chain already wired since Story 3.3. **But verify**: post-3.6 the visual.asm path transitively calls `edits_range_delete` AND `undo_record_delete`. Tests that already INCLUDE visual.asm SHOULD ALREADY include edits.asm and undo.asm via the standard test scaffolding (since they're after gapbuf.asm in the AR25 chain). Spot-check 2-3 existing visual_* tests to confirm the chain compiles post-3.6.

- [x] **Task 5** — NFR18 byte-identical rebuild + UAT + sprint-status flip:
  - [x] 5.1 — Confirm NFR18 byte-identical SHA across two `make clean && make all` cycles. Pre-3.6 SHA = `b6e3374d793588f1228c192b546fc9bd53ffcb0d4c0876ebc58a0b811c0df3d7` (from Story 3.5's Review-patch — will change post-3.6 since dispatch_visual entries + visual.asm body all grow; capture and document the new post-3.6 SHA).
  - [x] 5.2 — `make sizes` reports projected post-3.6 footprint per the budget arithmetic block (~+330 B code growth + 12 B module-local data = ~7265 B / ~88.7% of 8192 B / ~927 B headroom). Cross-check actuals against projection; document any drift per [[feedback_create_story_cross_check]] — Stories 3.4 / 3.5 each drifted +5 to +44 B over spec mid-estimate; same shape of drift expected here (the block per-row loop has more PUSH/POP / EX DE,HL pairs than easily estimable).
  - [x] 5.3 — Hardware UAT (AC13, 31 steps) deferred to user — script pasted inline at dev-handoff per [[feedback_uat_inline_at_dev_handoff]].
  - [x] 5.4 — Flip `sprint-status.yaml` `3-6-visual-operators-d-y-c` `ready-for-dev` → `in-progress` → `review`; → `done` after Ant confirms hardware UAT.

### Review Findings (code review — 2026-05-18)

**Sources:** Blind Hunter (40 raw findings, many self-retracted on re-read), Edge Case Hunter (20), Acceptance Auditor (25 raw findings, 21 self-withdrawn after deeper trace). Deduplicated and triaged to 2 decision-needed + 3 patch + 7 defer; rest dismissed as noise or by-design.

- [x] [Review][Dismissed] **NFR9 revisit trigger fired** — dismissed by reviewer 2026-05-18: informal disclosure in the dev-pass narrative and sprint-status comment is sufficient; no formal NFR9 amendment will be filed for Story 3.6. Verified figures retained for the record: `_visual_op_block_arm` = 0x12E8..0x147D = **405 B** (above the spec's 380 B threshold); vibe.com = **7734 B** (above the 7600 B threshold). Story 3.7 pre-dev pin should treat the 458 B headroom as the binding ceiling. (Source: A-20.)
- [x] [Review][Defer] **VIS_BLOCK `c` silently drops typed content from undo replay** — deferred: AC8 already accepts multi-region undo as deferred; this is a downstream consequence. Pre-INSERT phase writes `UNDO_KIND_TOO_LARGE`; `undo_insert_exit_record` on Esc reads TOO_LARGE and `RET Z` per Story 2.13 contract, leaving typed insertions unrecorded. `u` after `<block-selection> c <typing> <Esc>` surfaces `msg_undo_too_large` and does NOT unwind the typed content. (Source: E-2 + A-14.)
- [x] [Review][Patch] **BLOCK arm cursor placement can land past EOL/EOF on jagged-top selections** [`src/visual.asm:895-903`] — APPLIED 2026-05-18: added `motion_byte_at_logical` clamp (`.b_cursor_clamp` / `.b_have_cursor`) after `LD (cursor_offset), HL` in `.set_cursor`. DEC HL if past EOF or on LF. Mirrors `.char_clamp` at line 1042. +17 B binary growth verified (7734 → 7751 B). Original concern: `.set_cursor` wrote `cursor_offset := top_ls + col_min` without bounds-check; jagged-top rows with `line_length < col_min` would land cursor on/after that row's LF or past EOF. (Source: E-1 + E-15.)
- [x] [Review][Patch] **`visual_d-yank-too-large.asm` doesn't verify deletion proceeded** [`test/cases/visual_d-yank-too-large.asm`] — APPLIED 2026-05-18: added sentinel-5 assertion that `motion_byte_at_logical(0)` returns CF=1 (buffer empty) post-call. Pins SR6 "deletion-still-proceeds" invariant against future regressions. (Source: F-30.)
- [x] [Review][Patch] **`parser_visual_d-dispatch.asm` doesn't verify undo entry kind** [`test/cases/parser_visual_d-dispatch.asm`] — APPLIED 2026-05-18: added sentinel-7 assertion that `undo_kind == UNDO_KIND_DELETE` post-call. Closes coverage gap for CHAR `d` undo recording via the dispatch path. (Source: E-19.)
- [x] [Review][Defer] **Three duplicated `MODE_NORMAL ; parser_clear` tails** [`src/visual.asm:920-923, 1068-1071, 1093-1096`] — deferred, refactor candidate. Three sites manually re-implement the enter_normal_mode tail to preserve `msg_yank_too_large`. Refactor into a `_visual_op_mode_normal_preserve_status` helper. Not load-bearing. (Source: F-17.)
- [x] [Review][Defer] **`visual_op_block_yank_ok` cell name vs cross-arm reuse** [`src/visual.asm:1479` + header at line 150] — deferred, naming hygiene. Cell is shared across BLOCK + CHAR/LINE arms but named BLOCK-only; comment justifies reuse. Rename to `visual_op_yank_ok` and move under "CHAR/LINE/BLOCK shared" group in AC11. (Source: E-16 + A-03.)
- [x] [Review][Defer] **AC14 test coverage gaps** — deferred to a polish pass. Missing: `visual_y-char.asm` (VIS_CHAR `y`); `visual_d-line.asm` (VIS_LINE `d` with at-EOF carve-out); backward-selection coverage in any submode (CHAR/LINE/BLOCK `.backward` arms untested); headless test for VIS_BLOCK `d` undo replay (AC13 UAT step 22 is the only verification); headless test for VIS_CHAR `c` two-phase REPLACE upgrade (the two `visual_c-*` tests explicitly stub phase 2). (Source: E-7, E-8, E-9, E-10, E-11.)
- [x] [Review][Defer] **`undo_record_delete` silent TOO_LARGE for 257..1024-byte payloads** [`src/undo.asm:468-515`] — deferred, pre-existing. Inherited from Story 2.13's `undo_record_delete` contract; payload > UNDO_PAYLOAD_SIZE (256) writes UNDO_KIND_TOO_LARGE header, `u` replay surfaces msg_undo_too_large and does NOT restore. Same semantic as NORMAL-mode `dd`/`dw` with large counts. Not a Story 3.6 regression; coverage gap in visual context. (Source: F-28 + E-12.)
- [x] [Review][Defer] **Empty-buffer edge case (file_length=0) is unguarded by `_visual_op_char_arm`** [`src/visual.asm:560-585, 978-983`] — deferred, possibly pre-existing. cursor==anchor produces 1-byte selection; shared finalisation calls `undo_record_delete(0, 1)` → `motion_byte_at_logical(0)` returns CF=1 / A undefined → garbage written to undo_buffer and yank_buffer; `edits_range_delete(0, 1)` on empty buffer has undefined gap-buffer state. Possibly inherited from Story 2.9 (`x` on empty buffer). Should be guarded at visual entry (Story 3.3) or in the shared finalisation. (Source: E-6 + E-18.)
- [x] [Review][Defer] **BLOCK pass-1/pass-2 lacks `rows == 0` defensive guard** [`src/visual.asm:687+, p1_loop / p2_loop`] — deferred, depends on `visual_count_block_dims` invariant. Function is contracted to return rows ≥ 1; if a future refactor breaks that invariant, both passes infinite-loop (DEC HL from 0 → 0xFFFF, never zero). Add ASSERT or early-return. (Source: F-37 + F-38.)
- [x] [Review][Defer] **AC10 spec text mandates `JP enter_normal_mode` but code carves out the refusal path** [spec AC10] — deferred, spec-only edit. Code uses `visual_op_block_yank_ok` flag + inline `MODE_NORMAL ; parser_clear` tail when status surface must survive. Spec-conformant per dev-pass disclosure but AC10 text itself doesn't acknowledge the carve-out. Amend AC10 text to reconcile with AC7's status-preservation requirement. (Source: A-02.)

## Dev Notes

### Architecture compliance

**AR boundaries — `src/visual.asm` becomes a TRANSITIVE WRITER of buffer state after Story 3.6.**
- AR13 (BIOS_CONOUT): zero direct call sites — visual.asm still never emits to screen directly. Status updates funnel through `status_set_message` (AR12 owner statusln.asm). Status-bar redraws happen transitively via `edits_dirty_and_redraw` → `render_mark_all_dirty` (Story 1.11's render owner).
- AR14 (gap_start / gap_end WRITES): **STATUS CHANGED** — visual.asm now CALLs `edits_range_delete` (Story 2.10's helper) which transitively calls `gapbuf_delete` (Story 1.7's primitive). The AR14 ownership of gap_start/gap_end **remains with gapbuf.asm** (no direct writes in visual.asm); but visual.asm is now in the call-graph from a buffer-mutating path. Grep `LD (gap_start),\|LD (gap_end),` against `src/visual.asm` post-3.6 returns zero direct matches; grep `CALL edits_range_delete` returns expected matches in `_visual_op_delete_yank_or_change`'s `.delete_path` and `_visual_op_block_arm`'s pass-2 loop.
- AR15 (BDOS_CALL): zero call sites — visual.asm still never invokes BDOS.

**AR23 (per-module header convention)** — `visual_apply_operator` gets a docstring with In/Out/Trashes/Calls per the Story 1.5+ pattern (AC2 contract). The 12 new module-local cells get a Lifecycle note per AC11.

**AR25 (INCLUDE order)** — Story 3.6 adds NO new INCLUDEs to `src/vibe.asm`. The existing AR25 chain (post-Story-2.13):
1. statusln.asm
2. gapbuf.asm
3. motions.asm
4. edits.asm
5. parser.asm
6. dispatch.asm
7. exline.asm
8. fileio.asm
9. search.asm
10. visual.asm
11. undo.asm

`visual.asm` (10) INCLUDEs AFTER `edits.asm` (4) — so `edits_copy_to_yank` / `edits_range_delete` / `edits_dirty_and_redraw` are BACKWARD-resolved (already defined at the point visual.asm is parsed). `visual.asm` (10) INCLUDEs BEFORE `undo.asm` (11) — so `undo_clear` / `undo_record_delete` / `undo_write_header` are FORWARD-resolved via sjasmplus's two-pass model. **Same pattern as Story 2.13's `op_undo` being forward-referenced from `dispatch_normal['u']`** (dispatch.asm INCLUDEs before undo.asm; the forward-ref resolves on pass 2). No INCLUDE-chain reorder needed.

**MC4 register convention** — `visual_apply_operator` accepts A = `'c'` / `'d'` / `'y'` (the operator byte; ignored after the initial branch). All three dispatch_visual entries are MC4-correct: dispatch_key sets A to the matched key before tail-calling the handler.

**SR4 mode-byte + submode invariant** — Story 3.6 is the FIRST consumer of all three submode discriminators in the operator path. Per the AC2 branch:
- `VIS_CHAR` (value 0): falls through to `_visual_op_char_arm` (default arm; defensive fall-through for unknown submodes).
- `VIS_LINE` (value 1): `JR Z, _visual_op_line_arm`.
- `VIS_BLOCK` (value 2): `JP Z, _visual_op_block_arm` (the heavyweight path).
On exit from the operator, mode_byte flips to MODE_NORMAL (d/y) or MODE_INSERT (c). `visual_submode` remains in its pre-op value (zombie state per Story 3.5 AC10) — meaningless until the next visual entry.

**SR5 visual-anchor semantic** — Story 3.6 is the FIRST destructive consumer of the anchor across all three submodes:
- VIS_CHAR: anchor is offset-space; AC3 reads `(visual_anchor)` for range_start.
- VIS_LINE: anchor is line-start (per Story 3.4 AC2); AC4 reads `(visual_anchor)` for range_start (no projection needed — it's already a line-start).
- VIS_BLOCK: anchor is offset-space (per Story 3.5 AC2); AC5 calls `visual_count_block_dims` which projects anchor + cursor to (ls, col) pairs.

**SR6 yank register** — Story 3.6 introduces the FIRST writer of KIND_BLOCK. Pre-3.6, KIND_BLOCK was reserved (declared since Story 2.10's parameterised yank-kind era but never written). Story 3.6 lands the writer per AC5 step 10 + AC9. The 1024-byte capacity ceiling applies; refusal preserves the prior register per SR6.

**State.inc** — NO CHANGES. All Story 3.6 state additions are module-local DEFWs in `src/visual.asm`.

### Files this story modifies (and what to preserve)

**`src/dispatch.asm`** (currently 727 lines post-Story-3.5):
- INSERT three 3-byte entries + 3 ASSERTs in dispatch_visual: `'c'` between `'b'` and `'g'`, `'d'` between `'c'` and `'g'`, `'y'` after `'w'`. Per Task 2.1-2.3.
- MODIFY the existing `ASSERT 'g' > 'b'` at line 709 to `ASSERT 'g' > 'd'` (sort-chain repair).
- MODIFY the comment block at lines 660-662 per Task 2.6.
- MODIFY module-header Dependencies block per Task 2.7.
- PRESERVE: ALL of dispatch_normal's 38 entries (UNCHANGED — d/y/c in NORMAL still route to parser_handle_operator); dispatch_insert, dispatch_command UNCHANGED; dispatch_visual's existing 20 entries UNCHANGED (only the three new entries insert); enter_normal_mode, enter_insert_mode, unbound_normal, unbound_visual, unbound_insert ALL UNCHANGED; the dispatch_key body UNCHANGED.

**`src/visual.asm`** (currently 722 lines post-Story-3.5):
- ADD `visual_apply_operator:` public entry + `_visual_op_char_arm:` + `_visual_op_line_arm:` + `_visual_op_block_arm:` + `_visual_op_delete_yank_or_change:` (Task 3.1-3.5).
- ADD 12 module-local cells per Task 1.1 (10 DEFW + 2 DEFB).
- MODIFY module-header (lines 1-201) per Task 3.7: flip Public block entry from PLACEHOLDER to LANDS; extend State-owned block; extend Dependencies block (add edits.asm + undo.asm); update AR14 Purpose paragraph to "transitive writer".
- PRESERVE: `visual_enter_char` body (UNCHANGED); `visual_enter_line` body (UNCHANGED); `visual_enter_block` body (UNCHANGED); `visual_extend`'s 3-way prologue + `.char_arm` / `.line_arm` / `.block_arm` bodies (UNCHANGED — operator dispatch is a SEPARATE entry, not threaded through visual_extend); `visual_count_lines` body (UNCHANGED); `visual_count_block_dims` body (UNCHANGED — used by `_visual_op_block_arm` AS-IS); `visual_compose_status` / `visual_compose_status_line` / `visual_compose_status_block` / `_visual_compose_finish` shared-tail (UNCHANGED); all 5 Story-3.5 module-local DEFW cells (UNCHANGED — still owned by `visual_count_block_dims`'s projection scratch); all module-header constants (`MSG_MODE_VISUAL_*_PREFIX_LEN` equates UNCHANGED).

**`src/edits.asm`** — NO CHANGES. `edits_copy_to_yank` (Story 2.10 + 2.11 parameterised kind), `edits_range_delete` (Story 2.10), `edits_dirty_and_redraw` (Story 2.8) are reused as-is by visual.asm. The KIND_CHAR/LINE/BLOCK discriminators are already wired in `edits_copy_to_yank`'s parameterised-kind path (Story 2.11); KIND_BLOCK is a new value (0x02) that the routine accepts via its `LD (yank_kind), A` write.

**`src/undo.asm`** — NO CHANGES. `undo_clear` (Story 2.13), `undo_record_delete` (Story 2.13), `undo_write_header` (Story 2.13 internal — exposed for Story 3.6's BLOCK arm direct-write of UNDO_KIND_TOO_LARGE) reused as-is. **Sub-task: verify `undo_write_header` is callable from outside undo.asm.** It's declared internal in `src/undo.asm`'s public block (line ~45-50); needs to be either exposed as a public entry OR Story 3.6 uses a different mechanism (e.g. manually writes undo_kind / undo_position / undo_length cells). **Recommended Q-pin**: expose `undo_write_header` as public for Story 3.6's BLOCK arm direct-write; document the new public entry in undo.asm's module header. ~+3-5 B of doc-only edit to undo.asm; technically a "modification" to undo.asm but only in the comments.

**`src/statusln.asm`** — NO CHANGES. `msg_yank_too_large` (Story 2.10), `msg_undo_too_large` (Story 2.13), `msg_mode_normal` (Story 1.5) reused.

**`inc/state.inc`** — NO CHANGES.
**`inc/equates.inc`** — NO CHANGES (KIND_CHAR / KIND_LINE / KIND_BLOCK declared since Story 2.10; UNDO_KIND_TOO_LARGE declared since Story 2.13; YANK_BUFFER_SIZE / UNDO_PAYLOAD_SIZE declared in equates.inc).
**`inc/modes.inc`** — NO CHANGES.
**`src/motions.asm`** — NO CHANGES.
**`src/render.asm`** — NO CHANGES.
**`src/vibe.asm`** — NO CHANGES (AR25 chain unchanged).

**Test files (`test/cases/*.asm`):**
- ADD 8 new test files per Task 4.
- NO bulk patch needed — the AR25 INCLUDE chain extension for visual.asm was done by Story 3.3; the chain through undo.asm was done by Story 2.13.
- PRESERVE: All existing test bodies (the spec assumes Story 3.5's `visual_block-*.asm` and `parser_ctrlV-dispatch.asm` tests are UNCHANGED and still PASS post-3.6 — they exercise the read-only entry / extend paths that Story 3.6 doesn't touch).

### Implementation choices and trade-offs

**Choice: `visual_apply_operator` is a SINGLE entry that branches on operator and submode internally; NOT three separate entries (`visual_op_delete` / `visual_op_yank` / `visual_op_change`).**
- Pro: One entry in dispatch_visual.asm × three keys (d/y/c) is simpler to declare (3-byte entry each forward-refs the same symbol). One body reduces the public-symbol surface (visual.asm Public block has one new public entry, not three).
- Con: The body has a 3-way operator-branch inside it (~10 B). With three entries each tail-JPing a shared finalisation, the operator branch would land in the dispatch.asm table itself (zero runtime cost).
- Decision: One entry. The ~10 B branch is negligible; the public-surface simplicity wins. Future Stories 3.7 / 3.8 can add `visual_apply_shift` / `visual_apply_case_toggle` as sibling entries (each handling one or two operators); they don't need to combine with `visual_apply_operator`.

**Choice: VIS_BLOCK undo records UNDO_KIND_TOO_LARGE (Option A) — multi-region undo deferred.**
- Per Q2 / AC8. The single-payload undo machinery from Story 2.13 records ONE contiguous range; VIS_BLOCK delete is fundamentally non-contiguous (delete-this-slice-skip-the-LF-delete-the-next-slice-...). Faking it with a single big range would over-write content on replay.
- The TOO_LARGE record is what would naturally happen anyway if the block's content exceeded UNDO_PAYLOAD_SIZE (256 B); we're just doing it explicitly for any block size (including small ones). User experience: `u` post-block-op surfaces "undo not possible - too large".
- Alternative considered (rejected): Option C — new `UNDO_KIND_BLOCK_DELETE` kind with a per-row manifest (`{position, length}` pairs) in undo_buffer. ~+50-80 B of new code in undo.asm + new replay body. Too much scope; logged in deferred-work.md as a post-MVP polish.

**Choice: KIND_BLOCK yank format = rows joined by LFs (Option A).**
- Per Q3 / AC9. Simplest format that supports future block-paste (the paste handler can split on LFs to recover per-row content). Matches vim's block-yank-then-paste behaviour ("`p`" inserts the rectangle at successive lines).
- Empty-row case: contributes 0 bytes of content but still gets the LF separator emit between adjacent rows — preserves the row count exactly. Future paste will recognise empty-row separators correctly.
- No trailing LF: explicit pin so the LF count = (R-1) for an R-row rectangle. Future paste's "N rows = (LFs + 1)" math works out.

**Choice: 0-byte guard for visual operators.**
- Per AC6 step 1. The CHAR-arm range compute can yield BC=1 minimum (anchor==cursor case → +1 bump). The LINE-arm range compute yields BC ≥ line_length minimum (visual_anchor's line-start to its line-end). The BLOCK-arm pre-compute can yield 0 only if ALL rows are no-ops (every row's line is past col_min — extremely contrived).
- The 0-byte guard at `_visual_op_delete_yank_or_change` step 1 is **defensive** — covers cases where the empty-buffer edge case sneaks through (e.g. visual_anchor was pinned at offset 0 of an empty buffer; cursor also at 0; AC3 compute yields BC=1 but the actual byte-read fails — `edits_range_delete` of 1 byte on an empty buffer hits BOF silently). The guard ensures the user sees a clean mode-transition with no buffer corruption.

**Choice: AR14 status changes from "pure reader" to "transitive writer".**
- Per AC12. Stories 3.3 / 3.4 / 3.5 kept visual.asm out of the buffer-write call graph. Story 3.6 introduces the first writes via `edits_range_delete` → `gapbuf_delete`.
- The AR14 invariant "gap_start / gap_end owned by gapbuf.asm" is UNCHANGED — visual.asm doesn't write those cells directly; it routes through `edits_range_delete` which itself routes through `gapbuf_delete`.
- Documentation update: the module-header Purpose paragraph extends to call this out explicitly.

**Choice: Single commit (Option A for Q8).**
- Matches the Epic-3 single-commit pattern (Stories 3.1 / 3.2 / 3.3 / 3.4 / 3.5 all single commits). Per Q8.

**Choice: KIND_BLOCK paste behaviour stays as silent no-op (Q9 Option A).**
- `op_paste`'s existing `CP KIND_BLOCK ; JP Z, parser_clear` guard at `src/edits.asm:2179-2180` is UNCHANGED. Pasting a KIND_BLOCK yank in NORMAL mode remains silent.
- A future Story 3.6.x polish will implement block-paste (split yank_buffer on LFs; insert each row at the matching successive line below the cursor; handle empty-row LFs as zero-width row inserts). Logged in deferred-work.md.

### Previous story intelligence

**From Story 3.5 (just completed, UAT confirmed):**
- `visual_count_block_dims` is the BLOCK projection helper — projects anchor + cursor to (line_start, col) pairs and returns HL=rows, BC=cols. Story 3.6's BLOCK arm calls this once at entry to get the rectangle dimensions, then uses the 5 module-local DEFW cells it populated (`visual_block_anchor_ls` / `_anchor_col` / `_cursor_ls` / `_cursor_col` / `_temp_rows`) as additional projection cache.
- **DE-trash gotcha**: `motion_byte_at_logical` trashes DE per its AR23 contract (`src/motions.asm:557` block). Story 3.6's BLOCK arm pass-1 and pass-2 loops MUST PUSH/POP DE around motion_byte_at_logical calls if BC/DE state needs to survive. Recurring gotcha — fourth instance (Story 2.6 motion_dollar, Story 3.4 visual_count_lines, Story 3.5 visual_count_block_dims, Story 3.6 _visual_op_block_arm).
- **Spec narrative drift caught** ([[feedback_create_story_cross_check]]): Story 3.5's spec said dispatch_normal grew 37 → 38 (correct), but Story 3.4's spec had said 28 → 29 when the actual was 36 → 37. Story 3.6 explicitly says dispatch_visual grows 20 → 23; dev pass MUST verify via `build/vibe.lst`.
- **Q3 Option A (Ctrl-V not in dispatch_visual)**: Story 3.6 inherits the precedent — d/y/c are bound ONLY in dispatch_visual (not in dispatch_normal where they already serve as `parser_handle_operator` triggers). Conceptually clean: operators in NORMAL compose with motions via the parser; operators in VISUAL apply to the current selection directly.
- **Status compose scratch sizing**: Story 3.5 confirmed `status_compose_scratch` 48-B cell has 17 B slack over the longest BLOCK banner. Story 3.6 doesn't add any new status banners — `msg_yank_too_large` and `msg_undo_too_large` are pre-existing static strings, not composed; they don't use status_compose_scratch. No state.inc change.
- **NFR18 SHA byte-identical discipline**: Story 3.5 confirmed `b6e3374d793588f1...` across two clean+build cycles. Story 3.6 will compute and record a new SHA.
- **Sentinel band reservation**: Story 3.5's closing note: "Stories 3.6-3.8 will consume the 0xC0..0xCF band (note: 0xC0..0xCF is currently fully consumed by Story 2.13 undo tests; Story 3.6+ will need new band — Story 3.5 does not reserve any further)". Story 3.6 uses **0xD0..0xD6 + 0xEE** (NOT 0xC0..0xCF as Story 3.5's closing note suggested). 0xD7..0xDF available for Stories 3.7 / 3.8. **This corrects the Story 3.5 closing-note pin: Story 3.6 uses 0xD0..0xD6 + 0xEE, not 0xC0..0xCF.**

**From Story 3.4 (visual line mode V):**
- `visual_enter_line` snaps anchor to `motion_find_line_start(cursor_offset)` at entry. Story 3.6's LINE arm reads `(visual_anchor)` as a line-start directly — no projection needed.
- `visual_count_lines` (Story 3.4 internal helper) walks LFs in `[min, max)` between two line-starts; same shape used by Story 3.5's `visual_count_block_dims`. Story 3.6's LINE arm doesn't reuse it directly (the LINE arm uses `motion_find_line_end` to walk to the END of the bottom selected line, then includes the LF — different from the `visual_count_lines` LF-counting walk). But the math identity (LFs in `[min, max)` + 1 = line count) is the same idea.

**From Story 3.3 (visual character mode v):**
- `visual_enter_char` pins anchor = `cursor_offset` at entry (offset space). Story 3.6's CHAR arm reads `(visual_anchor)` and `(cursor_offset)`, applies the SBC-and-swap pattern from `visual_extend.char_arm` to compute `min(anchor, cursor)` and `|cursor - anchor| + 1`.
- The placeholders comment block at `src/visual.asm:399-407` (the comment that handed off the landing strip for Story 3.4/3.5/3.6) is GONE post-Story-3.5 — Story 3.5 retired the rest of the placeholder when `visual_enter_block` landed. Story 3.6's `visual_apply_operator` body lands as a NEW labelled entry in the module (no placeholder to retire).

**From Story 2.13 (single-level undo `u`):**
- `undo_clear` (preview-clear before mutating ops); `undo_record_delete` (DELETE record with payload); `undo_record_replace` (used transitively via `undo_insert_exit_record` for the c+motion phase 2 upgrade — Story 3.6 inherits this for VIS_CHAR/LINE `c`); `undo_write_header` (direct header write — Story 3.6's BLOCK arm uses this for UNDO_KIND_TOO_LARGE).
- `undo_insert_exit_record`'s phase-2 REPLACE upgrade triggers at INSERT-exit IF undo_kind == UNDO_KIND_DELETE on entry. VIS_CHAR/LINE `c` records DELETE (phase 1); INSERT-exit upgrades to REPLACE. VIS_BLOCK `c` records TOO_LARGE; INSERT-exit reads TOO_LARGE and LEAVES IT (no upgrade). Story 3.6 needs no special handling — the inherited behaviour is correct.
- Sentinel band 0xC0..0xCF fully consumed by undo_* tests. Story 3.6 uses 0xD0..0xD6 instead.

**From Story 2.12 (paste `p`):**
- `op_paste`'s KIND_BLOCK guard at `src/edits.asm:2179-2180` silently no-ops. Story 3.6 produces KIND_BLOCK yanks that paste-as-no-op until a future Story 3.6.x lands block-paste. The yank content sitting in yank_buffer is the seed for that future story.
- `edits_paste_yank_bytes` (Story 2.12 internal) does per-byte gapbuf_insert; Story 3.6 does NOT use this — VIS_BLOCK pass-2 uses `edits_range_delete` (delete, not insert) and `motion_byte_at_logical` (read for yank-append).

**From Story 2.11 (op+motion compose):**
- `op_compose_d` / `op_compose_y` / `op_compose_c` are the NORMAL-mode op+motion bodies. Story 3.6's `visual_apply_operator` is the VISUAL-mode equivalent — same kind of work (yank + delete + cursor placement + mode transition) but the range comes from the visual selection, not from a parser-composed op+motion.
- The Story 2.11 two-phase REPLACE upgrade pattern (DELETE phase 1 + REPLACE phase 2 at INSERT-exit) applies to `c` in BOTH NORMAL and VISUAL modes. Story 3.6 inherits this transitively via the existing `undo_insert_exit_record` hook.

**From Story 2.10 (`dd` / `yy`):**
- `edits_line_range_for_count` (Story 2.10 internal) computes line-bounded ranges with the at-EOF carve-out. Story 3.6's LINE arm reimplements similar shape inline (per Q4 Option A — don't extract a shared helper yet).
- `edits_copy_to_yank` parameterised kind (Story 2.11 patch) — accepts A = KIND in `[KIND_CHAR | KIND_LINE | KIND_BLOCK]`. Story 3.6 is the FIRST writer of KIND_BLOCK via this helper... but wait, `edits_copy_to_yank` is for CONTIGUOUS ranges. Story 3.6's BLOCK arm doesn't use it — block yank is per-row append via a direct `motion_byte_at_logical` loop + LF separators (custom path). `edits_copy_to_yank` IS used by Story 3.6's CHAR/LINE arms (KIND_CHAR and KIND_LINE).

**From Story 2.5 (basic motions):**
- AC13 contract — every NORMAL→other-mode handler tail-JPs `parser_clear`. Story 3.6's `enter_normal_mode` / `enter_insert_mode` tail-JPs (via the existing handlers in dispatch.asm) preserve this.

### Git intelligence

**Recent commits (last 5; for context — Story 3.6 follows the same shape):**
- `cd105bf Story 3.5: visual block mode Ctrl-V lands; FR35/BH3 close; VIS_BLOCK submode` — direct precursor; established the VIS_BLOCK writer + visual_count_block_dims + visual_compose_status_block. Story 3.6 builds atop visual_count_block_dims for the BLOCK arm.
- `517bef1 Story 3.4: visual line mode V lands; FR34 closes; VIS_LINE submode` — established the VIS_LINE anchor-snap-to-line-start invariant. Story 3.6's LINE arm reads anchor as a line-start directly (no projection).
- `a1ce47d Story 3.3: visual character mode lands; FR15/FR33 close; visual.asm module` — established the visual.asm module + the SR5 anchor semantic for VIS_CHAR.
- `c0761fd Story 3.2: repeat last search n with wrap` — single-commit Epic-3 pattern.
- `231ce3f Story 3.1: forward literal search /pattern lands; FR41 closes` — Q4 pin (wrap upper-bound = original_cursor + 1) precedent for the AC4 carve-out shape used here.

**Pattern:** every Epic-3 story so far has been single-commit, 5-6 new headless tests, NFR18 byte-identical rebuild required. Story 3.6 follows the same shape but with more tests (8) due to the cross-submode coverage.

**Insight from Story 3.5's dev pass:** `visual_count_block_dims` came in at ~100 B vs the spec's 87 B mid-estimate (+13 B drift due to the PUSH/POP DE bracketing). Story 3.6's `_visual_op_block_arm` spec estimates 280-360 B; expect similar 10-20 B drift on the actual implementation. Budget arithmetic block below uses the mid-estimate (320 B); if actual closes 360 B, total still well within budget.

### Implementation Questions (resolve with Ant before dev starts)

See **Task 0** for the Q1-Q9 pin list. Recommended pins are all **Option A** consistent with the Story 3.3 / 3.4 / 3.5 precedent. Resolve in chat before Task 1; the pins shape AC details but the body is robust to any pin choice (visual operator behaviour is well-bounded vi-faithful; the only material UX-impact choice is Q3 KIND_BLOCK yank format).

### NFR9 budget arithmetic (worked example)

Pre-3.6 footprint: **6935 B / 84.6% of 8192 B / 1257 B headroom** (per Story 3.5 dev-pass actuals — final size landed +227 B over Story 3.4's 6708 B baseline, including the Review-patch banner test which is test-only and doesn't count toward production code; production code was +183 B + ASSERTs + the Review-patch banner-test addition that DOES affect code via the new test case... actually the post-3.5 6935 B IS the production-only size).

Story 3.6 projected deltas (positive = grows footprint; negative = shrinks):
- `src/visual.asm` `visual_apply_operator` prologue + 3-way dispatch: **+12 B**
- `src/visual.asm` `_visual_op_char_arm` body: **+36 B**
- `src/visual.asm` `_visual_op_line_arm` body (including at-EOF carve-out): **+80 B**
- `src/visual.asm` `_visual_op_block_arm` body (pass-1 + capacity + pass-2 + cursor + dispatch): **+320 B** (mid-estimate of AC5's 280-360 B range)
- `src/visual.asm` `_visual_op_delete_yank_or_change` shared finalisation (delete + change + yank-only branches): **+125 B** (mid-estimate of AC6's 110-140 B range)
- `src/visual.asm` module-header doc-only extends: **+0 B** (comments are stripped from the binary)
- `src/dispatch.asm` `dispatch_visual` 3 new entries: **+9 B** (3 × 3 B; ASSERTs are assembly-time, zero runtime)
- `src/undo.asm` doc-only edit to expose `undo_write_header` as public: **+0 B**

Subtotal code growth: **~+582 B**

State growth: **+12 B** (10 module-local DEFW + 2 DEFB cells in src/visual.asm; NOT in state.inc — visual.asm-internal). No equates.inc / state.inc / modes.inc changes.

**Projected post-3.6 footprint: 6935 + 582 = 7517 B / ~91.8% of 8192 B / ~675 B headroom.**

**Caution: this projection is at the high end of the AC5 mid-estimate.** If the actual `_visual_op_block_arm` lands at 360 B (the top of the 280-360 B range), total ~7557 B / 92.2% / 635 B headroom. Still within ceiling but **less generous** than prior Epic-3 stories. Stories 3.7 (visual shift) and 3.8 (visual case-toggle) are projected at ~80-120 B and ~50-80 B respectively per Story 3.5's projection block — post-Epic-3 ~7700-7800 B / 94-95% / ~400-500 B headroom. Within ceiling.

**Revisit trigger:** if Story 3.6's actual `_visual_op_block_arm` lands above 380 B (which would push total >7600 B), recommend an NFR9 amend conversation. The 8192 B ceiling was amended 2026-05-17 from 6400 B per the Epic-3 entry budget plan; a second amendment is possible but would itself need a Q-pin conversation. Story 3.6's body is the cliff-edge complexity per Story 3.5's projection.

### Test count target

232 (post-3.5 incl. Review-patch banner test) → **240 PASS** (+8 new from Story 3.6) / 1 deliberate-fail (`harness_fail` sentinel) unchanged.

### Project Structure Notes

- `src/visual.asm` grows from 722 lines (post-3.5) to ~1100 lines (post-3.6; +1 public entry body + 3 internal arms + shared finalisation + 12 DEFW/B cells + module-header updates).
- Sentinel band allocation (cumulative through Story 3.6):
  - 0xA0..0xAA + 0xE9 — Story 3.1 (`/pattern` search)
  - 0xAB..0xAF + 0xEA — Story 3.2 (`n` repeat)
  - 0xB0..0xB4 + 0xEB — Story 3.3 (VIS_CHAR)
  - 0xB5..0xB9 + 0xEC — Story 3.4 (VIS_LINE)
  - 0xBA..0xBD + 0xED — Story 3.5 (VIS_BLOCK; +0xBF Review patch)
  - 0xBE reserved by `harness_fail` infra
  - **0xD0..0xD6 + 0xEE — Story 3.6 (THIS STORY: visual operators d/y/c)**
  - 0xD7..0xDF available for Stories 3.7 / 3.8
  - 0xC0..0xCF fully consumed by Story 2.13 undo_* tests
- No project-context.md exists in planning-artifacts — Story 3.6 relies on the architecture / epics / PRD trio plus the Story 3.3 / 3.4 / 3.5 implementation artifacts.
- Per [[feedback_create_story_cross_check]]: cross-checked the AC narrative against actual render/edit semantics:
  - **Cursor lands at offset 0 post-`:e`** ([[feedback_uat_trace_cursor]]) — verified in AC13 step 2 — UAT script enters with cursor at 0.
  - **No `~` past-EOF marker** ([[project_no_tilde_marker]]) — no UAT step predicts a tilde.
  - **CR/CRLF and sjasmplus-hostile filenames** — not relevant to Story 3.6 (operators don't touch file I/O).
  - **NFR9 projection** — explicit at AC5 + Tasks plus the budget arithmetic block. **Story 3.6 is the cliff-edge story for NFR9** — revisit trigger pinned in the budget block.
  - **DISPATCH_VISUAL_COUNT cross-check** — pre-3.6 count is 20 (0x14) per the build/vibe.lst output from Story 3.5. Story 3.6 specs the post-insert count as 23 (0x17). Dev pass MUST verify against the actual `build/vibe.lst` value — four previous stories drifted on the dispatch_normal_count metric; this is the first one for dispatch_visual_count, so the same care applies.
  - **KIND_BLOCK yank format** — explicit at AC9 + the `visual_y-block.asm` test (sentinel 0xD5) which pins the rows-joined-by-LF format byte-for-byte.
  - **AR14 transitive-writer status** — explicit at AC12 + the module-header Purpose paragraph update. Critical for the architecture's "buffer-writer modules" call graph documentation.
  - **VIS_BLOCK undo policy (UNDO_KIND_TOO_LARGE)** — explicit at AC8 + the `visual_d-block-jagged.asm` test which asserts `undo_kind = UNDO_KIND_TOO_LARGE` post-op. Test coverage exists; deferred-work logs the future multi-region undo polish.
  - **0-byte guard** — explicit at AC6 step 1; covers the defensive empty-buffer edge case.
  - **edits_range_delete is AR14-clean** — confirmed via `src/edits.asm:1086-1097` (the body loops gapbuf_delete; preserves the AR14 ownership at gapbuf.asm).

### References

- **Epic 3 narrative:** `_bmad-output/planning-artifacts/epics.md:1480-1484` (Epic 3 header + visual-highlighting platform-constraint note).
- **Story 3.6 epic AC source:** `_bmad-output/planning-artifacts/epics.md:1662-1697` (the original 5-AC narrative).
- **Architecture FR36 (visual operators):** `_bmad-output/planning-artifacts/architecture.md:229` (FR-coverage map) + `:682-689` (BH3 jagged-line semantic).
- **Architecture SR5 visual-anchor + SR6 yank-register:** `_bmad-output/planning-artifacts/architecture.md:452-461`.
- **Architecture visual.asm module purpose:** `_bmad-output/planning-artifacts/architecture.md:1304-1306` ("Visual-mode entry/exit, anchor management (SR5), block/line/char selection ops: d, y, c, >, <, ~" — Story 3.6 lands d/y/c).
- **Architecture mode-byte SR4:** `_bmad-output/planning-artifacts/architecture.md:447-451` (MODE_VISUAL implies visual_submode is VIS_CHAR/VIS_LINE/VIS_BLOCK).
- **PRD FR36:** `_bmad-output/planning-artifacts/prd.md` — see FR coverage map at epics.md:229.
- **PRD NFR9 (8192 B ceiling, amended 2026-05-17):** `_bmad-output/planning-artifacts/prd.md:848`.
- **Existing visual.asm module-header (to be extended):** `src/visual.asm:1-201`.
- **Existing visual.asm body (to be extended with operators):** `src/visual.asm:202-722`.
- **Existing visual_count_block_dims (reused as-is by BLOCK arm):** `src/visual.asm:495-584`.
- **Existing dispatch_visual table (to gain c/d/y entries):** `src/dispatch.asm:651-727`.
- **Existing edits_copy_to_yank (KIND-parameterised; Story 2.11):** `src/edits.asm:988-1058`.
- **Existing edits_range_delete (AR14-clean per-byte gapbuf_delete loop):** `src/edits.asm:1062-1097`.
- **Existing edits_dirty_and_redraw (Story 2.8):** `src/edits.asm:614-635`.
- **Existing op_dd (KIND_LINE delete + case-3 cursor placement reference):** `src/edits.asm:1101-1198`.
- **Existing op_compose_d (KIND_CHAR delete + x-style EOL clamp reference):** `src/edits.asm:1423-1509`.
- **Existing op_compose_c (REPLACE phase-1 reference):** `src/edits.asm:1569-1638`.
- **Existing op_compose_y (yank-only cursor restore reference):** `src/edits.asm:1512-1566`.
- **Existing undo_record_delete (CHAR/LINE undo recorder):** `src/undo.asm:449-510`.
- **Existing undo_write_header (Story 3.6 to expose as public for BLOCK arm UNDO_KIND_TOO_LARGE direct-write):** `src/undo.asm:~530+`.
- **Existing undo_insert_exit_record (Story 2.13 phase-2 REPLACE upgrade):** `src/undo.asm:~620+`.
- **Existing enter_normal_mode (d/y tail-JP target):** `src/dispatch.asm:312-330`.
- **Existing enter_insert_mode (c tail-JP target):** `src/dispatch.asm:350-373`.
- **Existing motion_find_line_start (LINE-arm projection helper):** `src/motions.asm:636-647`.
- **Existing motion_find_line_end (LINE-arm + BLOCK-arm walker):** `src/motions.asm:672-679`.
- **Existing motion_byte_at_logical (DE-trash gotcha at BLOCK-arm content read):** `src/motions.asm:557-608`.
- **Existing msg_yank_too_large + msg_undo_too_large (statusln.asm):** `src/statusln.asm:322 + :330`.
- **inc/equates.inc KIND_BLOCK declaration (reserved since Story 2.10):** `inc/equates.inc:91`.
- **inc/equates.inc UNDO_KIND_TOO_LARGE declaration (Story 2.13):** `inc/equates.inc:106`.
- **inc/state.inc visual_anchor + visual_submode + yank_kind / yank_length declarations:** `inc/state.inc:52, 99, 58, 103`.
- **Story 3.5 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-5-visual-block-mode.md` (full story file with visual_count_block_dims + the BLOCK projection cells Story 3.6's BLOCK arm reuses).
- **Story 3.4 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-4-visual-line-mode.md` (visual_enter_line anchor-snap pattern; Story 3.6's LINE arm reads anchor as line-start).
- **Story 3.3 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-3-visual-character-mode.md` (visual.asm module foundation + visual_extend CHAR-arm SBC-and-swap pattern reused at Story 3.6 AC3).
- **Story 2.10 retrospective (op_dd / op_yy + KIND-parameterised edits_copy_to_yank):** `_bmad-output/implementation-artifacts/2-10-doubled-operator-commands-dd-yy.md`.
- **Story 2.11 retrospective (op_compose_d / _y / _c + two-phase REPLACE):** `_bmad-output/implementation-artifacts/2-11-composed-operator-motion-dw-d-c5w-y3j.md`.
- **Story 2.13 retrospective (single-level undo machinery):** `_bmad-output/implementation-artifacts/2-13-single-level-undo-u.md`.
- **deferred-work.md (current backlog of polish items):** `_bmad-output/implementation-artifacts/deferred-work.md` — Story 3.6 ADDS new entries:
  - "VIS_BLOCK multi-region undo (UNDO_KIND_BLOCK_DELETE)" — Q2 Option C deferral; ~+50-80 B in undo.asm; needs a future story.
  - "KIND_BLOCK paste behaviour" — Q9 Option A deferral; Story 3.6.x polish; the yank content is in yank_buffer waiting for the future paste handler.
  - "Story 3.5 review-finding test gaps from Story 3.5's deferred items" — Story 3.6's tests do NOT close the Story 3.5 review-finding gaps (empty-buffer VIS_BLOCK / EOF-anchor / counted-motion / Ctrl-V-in-visual regression-pin); those remain in the deferred-work backlog for a later polish pass.

## Dev Agent Record

### Agent Model Used

Amelia (bmad-dev-story) on Claude Opus 4.7 (1M context)

### Debug Log References

(populated during dev pass)

### Completion Notes List

- **Pre-dev pin pass:** Ant confirmed all Q1-Q9 = Option A (single dialog, "All Option A recommended"). No deviations from the spec; implementation tracks AC narrative verbatim.
- **AC1 dispatch wiring** lands clean: dispatch_visual grows 20 → 23 (DISPATCH_VISUAL_COUNT = 0x17 verified in `build/vibe.lst:256`). c/d/y inserted in ASCII-sorted slots (between b/g and after w). The flanking ASSERTs (`'c' > 'b'`, `'d' > 'c'`, `'g' > 'd'` — the sort-chain repair, `'y' > 'w'`) compile clean; dispatch.asm comment block at 660-666 retires the pre-3.6 placeholder language + module-header Dependencies block extended.
- **AC2 prologue + 3-way submode dispatch** in `src/visual.asm` (1 new public entry + 4 internal arms + 1 BH3 helper + shared finalisation). The `ASSERT VIS_CHAR == 0` invariant pin from Story 3.5 is also depended on here (the prologue falls through to `_visual_op_char_arm` on the value-0 fall-through default).
- **AC3 CHAR arm**: SBC-and-swap from `visual_extend.char_arm` with INC HL inclusive bump → range_start = min(anchor, cursor), total = |delta| + 1. ~30 B. Routes to shared `_visual_op_delete_yank_or_change` with KIND_CHAR.
- **AC4 LINE arm**: project cursor via `motion_find_line_start`; PUSH/POP HL pattern to preserve cursor_ls across the SBC-flag-bearing branch; route forward/backward to the walker; `motion_find_line_end` walks the bottom line; at_eof carve-out matches `edits_line_range_for_count.at_eof` (range_start - 1 to consume leading LF of line above; or range_start = 0 → delete entire buffer). ~75 B.
- **AC5 BLOCK arm**: cliff-edge complexity per spec. Calls `visual_count_block_dims` once for projection; computes col_min/col_max/top_ls; two-pass loop (pass 1 = sum + LF separators + capacity check; pass 2 = per-row clipped delete + optional yank-append with shift-tracking). BH3 jagged-line clip extracted into `_visual_op_block_row_bytes` helper (~30 B, called twice — saves ~30 B over inlining). UNDO_KIND_TOO_LARGE direct-write via `undo_write_header` for d/c per Q2 Option A. Cursor lands at top-left of bounding rectangle. The pass-2 inner walker-advance had to be JP `.p2_loop` (not JR) — backward JR exceeded -128 byte range by 6 B.
- **AC6 shared finalisation** routes on `visual_op_pending`: 'd' = undo + yank + delete + cursor placement (CHAR x-style clamp vs LINE op_dd three-way) + commit + tail-JP; 'c' = same path but tail-JP enter_insert_mode (phase 2 REPLACE upgrade fires transitively at INSERT-exit per Story 2.13's existing `undo_insert_exit_record` hook); 'y' = pure yank, cursor → range_start, tail-JP enter_normal_mode.
- **AC7 yank-too-large refusal — IMPLEMENTATION DIVERGENCE from spec narrative**: AC10 mandates `JP enter_normal_mode` for d/y, but `enter_normal_mode` unconditionally calls `status_set_message(msg_mode_normal)` which CLOBBERS any prior status set by the refusal arm. Spec's AC7 explicitly asserts "status_buffer starts with 'yank too large'" in the test, contradicting AC10's tail-JP convention. Resolution: added a `visual_op_block_yank_ok` flag (reusing the BLOCK arm's existing cell — the CHAR/LINE shared finalisation and the BLOCK arm never run concurrently within a single dispatch). On refusal, the flag is cleared; at the tail dispatch the d/y path branches: flag set → JP enter_normal_mode (clean banner clear); flag clear → manual `LD A, MODE_NORMAL; LD (mode_byte), A; JP parser_clear` (preserves msg_yank_too_large). For 'c', enter_insert_mode unconditionally — AC7 explicitly acknowledges "the INSERT-mode banner '-- insert --' will overwrite the status within a few keystrokes — visible only as a transient flash". Same flag treatment for BLOCK arm's `.b_yank_refused` path.
- **AC8 undo recording**: CHAR/LINE d/c → `undo_record_delete` (with its own 256-B capacity handling → UNDO_KIND_TOO_LARGE on overflow); BLOCK d/c → direct `undo_write_header` with UNDO_KIND_TOO_LARGE (multi-region undo deferred); CHAR/LINE/BLOCK y → no undo entry (inherits op_yy "yank doesn't record" invariant).
- **AC9 KIND_BLOCK yank format**: rows joined by LF separators, no trailing LF, empty rows still emit separator LF. Implemented in BLOCK arm pass 2: yank-append loop reads bytes via `motion_byte_at_logical` (preserves BC per AR23); LF separator emit between non-last rows IS unconditional within the yank-ok branch (matches AC9 "empty row case... LF separator STILL emitted").
- **AC10 mode transition**: see AC7 implementation note re: enter_normal_mode clobber. For non-refusal d/y the JP enter_normal_mode tail is per spec; for refusal d/y the manual MODE_NORMAL+parser_clear path preserves status_buffer per AC7's "status surfaces msg_yank_too_large" requirement. For 'c' always JP enter_insert_mode.
- **AC11 module-local state**: 12 cells (10 DEFW + 2 DEFB) added under `;; --- Module-local data (Story 3.6 — visual_apply_operator scratch) ---` block. Lifecycle: cleared and re-written every call; values valid only between entry and terminal tail-JP. Independent from Story 3.5's `visual_block_*` projection scratch group (the two groups overlap conceptually but their lifecycles are disjoint within `visual_apply_operator`'s call). The `visual_op_block_yank_ok` cell reused by the CHAR/LINE shared finalisation per the AC7 divergence note.
- **AC12 module-header updates**: `src/visual.asm` Purpose paragraph extended with the AR14 "transitive writer" status note; Public block flips `visual_apply_operator` from PLACEHOLDER → LANDS; State-owned block adds 12-cell Module-local operator scratch declaration with Lifecycle note; Register conventions block adds `visual_apply_operator` In/Out/Trashes/Calls per AC2; Dependencies block adds `src/edits.asm` (backward-resolved) + `src/undo.asm` (forward-resolved via sjasmplus two-pass, mirroring the op_undo dispatch-normal['u'] precedent from Story 2.13).
- **AC13 hardware UAT**: deferred to user per the standard hand-off — script reproduced verbatim in the dev-handoff message below per [[feedback_uat_inline_at_dev_handoff]].
- **AC14 headless tests**: all 8 new tests PASS (240 total / 1 deliberate-fail unchanged). Two test-spec arithmetic corrections caught during dev: (1) `visual_d-block-jagged` yank_length is **10**, not 9 (3 + 1 LF + 2 + 1 LF + 3 = 10; the spec text wrote "= 9" but the DEFB sequence "abc\nxy\nabc" is 10 bytes); (2) `visual_c-line-enters-insert` fixture "first line\nsecond line\nthird line" is **33 bytes**, not 32 ("second line" is 11 chars not 10), with yank_length = **23** not 22. Both corrections are documented as inline test comments.
- **NFR18 byte-identical SHA across two clean rebuilds**: `546d0ba47badba71eb8720c329c0d2b8975db492b25ac3e1b01a97988d403543` (post-3.6). Pre-3.6 SHA was `b6e3374d793588f1228c192b546fc9bd53ffcb0d4c0876ebc58a0b811c0df3d7` — different as expected (dispatch_visual + visual.asm + undo.asm all changed).
- **NFR9 size**: post-3.6 `vibe.com` = **7734 B / ~94.4% of 8192 B / 458 B headroom**. Spec projected 7517 B with 675 B headroom; actual landed +217 B over projection. Drift sources: (a) the BH3 helper (~30 B; spec mid-estimate didn't include it), (b) the AC7 refusal-flag refactor (~30 B in shared finalisation + ~10 B in BLOCK arm tail dispatch), (c) BLOCK arm pass-1/pass-2 PUSH/POP DE bracketing across `motion_byte_at_logical` (spec acknowledged this as "the block per-row loop has more PUSH/POP / EX DE,HL pairs than easily estimable"). Per AC's revisit trigger ("if actual lands above 380 B for the BLOCK arm push total >7600 B"): we landed 7734 B (+134 B over the revisit threshold). Stories 3.7/3.8 projected at ~80-200 B combined — fits within remaining 458 B but tightly; flagging [[feedback_create_story_cross_check]]: recommend `bmad-correct-course` or NFR9 amendment discussion before Story 3.7 if the cliff-edge is now a concern.
- **AR sweep on src/visual.asm post-3.6** per Task 3.8: AR13/AR15 clean (zero BIOS_CONOUT / BDOS_CALL / CALL 0x0005 matches); AR14 STATUS CHANGED to "transitive writer" — zero direct `LD (gap_start)` / `LD (gap_end)` writes; zero `CALL gapbuf_delete` direct matches; the AR14-clean mutation path is `visual.asm → edits_range_delete → gapbuf_delete` per the Story 2.10 helper contract.
- **Test-spec drift caught** per [[feedback_create_story_cross_check]]: 2 arithmetic mistakes in AC14 test fixtures (yank_length 9 vs 10 for jagged block; buffer 32 vs 33 for c-line fixture). Both corrected in the actual test files; spec text in the story file is left as-is (corrections documented in the test files' header comments and in this Completion Notes block). Following the Story 3.4/3.5 precedent that drift between spec narrative and dev-pass actuals is normalised in code, not back-edited into the AC text.

### File List

- `src/dispatch.asm` — MODIFIED: 3 new `dispatch_visual` entries (c/d/y) with flanking ASSERTs; sort-chain repair `ASSERT 'g' > 'b'` → `'g' > 'd'`; comment block at line 660-666 updated to retire the pre-3.6 placeholder language; module-header Dependencies block extended with Story 3.6 paragraph. **+9 B code, +0 B runtime ASSERTs.**
- `src/visual.asm` — MODIFIED:
  - Module-header Purpose paragraph extended with AR14 transitive-writer status note (lines 28-65).
  - Public block: `visual_apply_operator` flipped PLACEHOLDER → LANDS.
  - State-owned block extended with the 12-cell Module-local operator scratch declaration + Lifecycle note (~40 lines of documentation).
  - Register conventions block: new `visual_apply_operator` In/Out/Trashes/Calls per AC2 (~40 lines).
  - Dependencies block: 2 new entries (`src/edits.asm` backward-resolved + `src/undo.asm` forward-resolved).
  - Body insert between `visual_extend` and `visual_count_lines`: `visual_apply_operator` (12 B prologue) + `_visual_op_char_arm` (~32 B) + `_visual_op_line_arm` (~80 B) + `_visual_op_block_arm` (~400 B) + `_visual_op_block_row_bytes` private helper (~22 B) + `_visual_op_delete_yank_or_change` shared finalisation (~140 B). Total body growth: ~686 B.
  - Module-local data block: 12 cells added (10 DEFW + 2 DEFB = 22 B state).
- `src/undo.asm` — MODIFIED (doc-only): `undo_write_header` promoted from "Internal helper" to "Public" in both the module-header Public block (added line) and the section-header comment (renamed Internal → Public). **+0 B code; +0 B state.**
- `test/cases/visual_d-char.asm` — NEW: sentinel 0xD0, AC3/AC6/AC8 VIS_CHAR `d` happy path.
- `test/cases/visual_y-line.asm` — NEW: sentinel 0xD1, AC4/AC6 VIS_LINE `y` happy path.
- `test/cases/visual_c-char-enters-insert.asm` — NEW: sentinel 0xD2, AC3/AC6/AC7 VIS_CHAR `c`.
- `test/cases/visual_d-block-jagged.asm` — NEW: sentinel 0xD3, AC5/AC8/AC9 CRITICAL BH3 + KIND_BLOCK format test (yank_length corrected from spec's 9 to actual 10).
- `test/cases/visual_d-yank-too-large.asm` — NEW: sentinel 0xD4, AC7 yank-refusal preserves prior register.
- `test/cases/visual_y-block.asm` — NEW: sentinel 0xD5, AC5/AC9 KIND_BLOCK yank format on uniform rectangle.
- `test/cases/visual_c-line-enters-insert.asm` — NEW: sentinel 0xD6, AC4/AC7 VIS_LINE `c` (fixture corrected from spec's 32 B to actual 33 B; yank_length 22 → 23).
- `test/cases/parser_visual_d-dispatch.asm` — NEW: sentinel 0xEE, AC1 end-to-end dispatch wiring (drives `'d'` through `dispatch_key` with `dispatch_visual`).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — MODIFIED: `3-6-visual-operators-d-y-c` flipped `ready-for-dev` → `in-progress` (at dev-pass start) → `review` (at this hand-off).
- `_bmad-output/implementation-artifacts/3-6-visual-operators-d-y-c.md` — MODIFIED (THIS FILE): Status → review; all 49 task checkboxes marked [x]; Completion Notes / File List / Change Log populated.

## Change Log

| Date | Change | Author |
| --- | --- | --- |
| 2026-05-18 | Story drafted from epics.md:1662-1697; pre-dev pins drafted as Option A across Q1-Q9 per Epic-3 precedent | bmad-create-story (Bob) |
| 2026-05-18 | Dev pass complete — visual_apply_operator landed for d/y/c across VIS_CHAR/VIS_LINE/VIS_BLOCK; 8 new headless tests PASS (240 total); NFR18 byte-identical confirmed (post-3.6 SHA `546d0ba4...d403543`); size 7734 B / 94.4% / 458 B headroom. AC7-vs-AC10 conflict resolved with `visual_op_block_yank_ok` flag (reused across CHAR/LINE/BLOCK refusal paths) so msg_yank_too_large surface survives the mode-change tail. 2 test-spec arithmetic mistakes corrected in code (yank_length 9→10 jagged block; fixture 32B→33B c-line). Status → review. | bmad-dev-story (Amelia) |
| 2026-05-18 | Code review complete — 2 decision-needed resolved (NFR9 trigger dismissed as informally-disclosed; BLOCK-c silent-undo deferred to multi-region undo backlog per AC8). 3 patches applied: BLOCK jagged-top cursor clamp (src/visual.asm `.set_cursor`, +17 B), visual_d-yank-too-large.asm sentinel-5 (SR6 deletion-still-proceeds), parser_visual_d-dispatch.asm sentinel-7 (UNDO_KIND_DELETE pin). 7 items deferred to deferred-work.md. Post-review build: 7751 B / 94.6% / 441 B headroom; 240 pass / 1 deliberate harness_fail unchanged. Status → done. | bmad-code-review |
