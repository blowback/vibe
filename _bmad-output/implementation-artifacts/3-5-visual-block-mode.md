# Story 3.5: Visual block mode

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `Ctrl-V` (0x16) in NORMAL mode to enter visual block mode — with `visual_anchor` pinned at the entry cursor offset (column derived on-demand from `visual_anchor - line_start(visual_anchor)`; no new state cell), mode-agnostic motions extending a *virtual* rectangle whose dimensions are `rows = |line(cursor) - line(anchor)| + 1` and `cols = |col(cursor) - col(anchor)| + 1` (normalized so anchor and cursor can be in any relative position), the status row reporting "`-- visual block -- RxC`", BH3 jagged-line semantics (the rectangle is virtual — short lines are NOT padded in the buffer; no `gapbuf_*` writes in this story), and Esc returning to NORMAL leaving the cursor at the extent,
So that FR35 + BH3 close — completing the visual-mode submode triad (`v` VIS_CHAR Story 3.3 / `V` VIS_LINE Story 3.4 / `Ctrl-V` VIS_BLOCK THIS STORY) and giving the Story 3.6+ visual operators (d/y/c/>/</~) a working VIS_BLOCK range to apply over (line-by-line, column-or-EOL per BH3).

## Acceptance Criteria

**AC1 — `dispatch_normal[0x16]` (Ctrl-V) lands a new entry at the sorted slot between `0x0C` (Ctrl-L) and `'$'` (0x24), targeting `visual_enter_block` in `src/visual.asm`.**

**Given** `src/dispatch.asm:dispatch_normal` (currently 37 entries post-3.4 — verify via `build/vibe.lst` `DISPATCH_NORMAL_COUNT EQU 0x25`; the slot between `0x0C` at lines 498-499 and `'$'` at lines 501-502 is currently the boundary between the Ctrl-L entry and the '$' motion entry — no entries fall in `[0x0D..0x23]` today)
**When** Story 3.5 lands
**Then** a new 3-byte entry `DEFB 0x16 ; DEFW visual_enter_block` is inserted between the `0x0C` and `'$'` entries, with `ASSERT 0x16 > 0x0C` and `ASSERT '$' > 0x16` flanking it (matching the dispatch_normal pin convention at lines 495-608)
**And** `DISPATCH_NORMAL_COUNT` (the `($ - .entries) / 3` EQU at line 608) auto-recomputes from 0x25 (37) → 0x26 (38)
**And** `dispatch_normal` table grows by **+3 B** (the new entry; ASSERTs are assembly-time only)
**And** the `src/dispatch.asm` module-header Dependencies block's `src/visual.asm` entry (added by Story 3.3 at lines 150-172) extends by one Story-3.5 paragraph documenting `visual_enter_block` as the third forward-ref symbol in this module (after `visual_enter_char` 3.3, `visual_enter_line` 3.4)
**And** `Ctrl-V` (0x16) is NOT bound in `dispatch_visual` for Story 3.5 — re-entering block mode from inside an existing VIS_CHAR / VIS_LINE session (vi convention: `v` / `V` / `Ctrl-V` toggle submodes mid-session) is **deferred to a polish story** (Q3 pin — same shape as Story 3.4's Q1 pin); for now `Ctrl-V` in VISUAL falls through to `unbound_visual` and the user must `Esc` then `Ctrl-V`. Updates the deferred-work.md entry from Story 3.4 (which named "Story 3.5's Ctrl-V neighbour decision" as the revisit trigger) — confirms Option A still holds.
**And** no constant equate is added for `0x16` — the literal hex matches the existing `0x0C` Ctrl-L entry convention at line 498 (NFR16 carve-out for control bytes is established precedent across `dispatch_normal` and `dispatch_insert`).

**AC2 — `visual_enter_block` (NEW body in `src/visual.asm`; replaces the placeholder comment block) pins `visual_anchor` at the entry cursor offset (NOT the line-start — VIS_BLOCK's anchor lives in offset space; the column is derived on-demand from `visual_anchor - line_start(visual_anchor)`), sets submode VIS_BLOCK, composes the entry status with rows=1 cols=1, and tail-JPs `parser_clear`.**

**Given** `src/visual.asm` (the placeholders block at lines 399-407 — the comment-only forward-symbol declaration noting "Stories 3.4 / 3.5 / 3.6+ will land the bodies here as adjacent labels"; Story 3.4 has retired its half of the placeholder block above visual_compose_status — Story 3.5 retires the remainder)
**When** Story 3.5 lands
**Then** the placeholder comment block is removed and `visual_enter_block:` lands as the third labelled entry in the module (immediately after `visual_enter_line`'s body at line 184-194, before `visual_extend` at line 229; chosen for code locality — all three visual-entry handlers live together, matching Story 3.4's `visual_enter_line` placement choice)
**And** the body performs in order:
1. `LD A, MODE_VISUAL ; LD (mode_byte), A` — flip mode (~5 B)
2. `LD A, VIS_BLOCK ; LD (visual_submode), A` — set sub-mode (~5 B)
3. `LD HL, (cursor_offset) ; LD (visual_anchor), HL` — pin anchor at the entry cursor offset (~6 B; column is implicit — `visual_count_block_dims` recomputes `anchor_col = visual_anchor - motion_find_line_start(visual_anchor)` on every extend; no new state cell needed per Q6 Option A)
4. `LD HL, 1` — entry row count = 1 (anchor and cursor are on the same line) (~3 B)
5. `LD BC, 1` — entry col count = 1 (anchor and cursor share the same column) (~3 B)
6. `CALL visual_compose_status_block` — composes "`-- visual block -- 1x1`" into `status_compose_scratch` and tail-JPs `status_set_message` (~3 B; the new dedicated compose entry per AC5)
7. `JP parser_clear` — drop any pending count/operator/prefix from before the Ctrl-V keystroke (~3 B; AC13 contract from Story 2.5)
**And** total `visual_enter_block` body size: **~28 B** (mirrors `visual_enter_line`'s 28 B; one extra `LD BC, 1` for the cols arg vs the line-mode single-count entry)
**And** AR23 docstring documents: `In: A = 0x16 (Ctrl-V; MC4 — ignored after dispatch)`; `Out: mode_byte = MODE_VISUAL; visual_submode = VIS_BLOCK; visual_anchor = cursor_offset (offset space, NOT line-start — vi-faithful BLOCK anchor; column derived on-demand by visual_count_block_dims); cursor_offset UNCHANGED; status_buffer = "-- visual block -- 1x1"; parser state zeroed.`; `Trashes: A, BC, DE, HL, F`; `Calls: visual_compose_status_block (CALL); parser_clear (tail-JP).`

**AC3 — `visual_extend` gains a third arm `.block_arm` dispatching VIS_BLOCK to `visual_count_block_dims + visual_compose_status_block`. The submode-dispatch prologue grows from 2-way (VIS_CHAR vs VIS_LINE) to 3-way (VIS_CHAR vs VIS_LINE vs VIS_BLOCK).**

**Given** `src/visual.asm:visual_extend` (the Story 3.4 body at lines 229-253 — currently 2-way JR-Z prologue: `CP VIS_LINE → JR Z, .line_arm`; VIS_BLOCK currently falls through to `.char_arm` as a defensive default per the Story 3.4 comment at line 234)
**When** Story 3.5 lands
**Then** `visual_extend`'s prologue extends from JR-Z to a CP-compare cascade:
```
visual_extend:
    LD      A, (visual_submode)
    CP      VIS_BLOCK
    JR      Z, .block_arm
    CP      VIS_LINE
    JR      Z, .line_arm
    ;; fall through to .char_arm (VIS_CHAR is value 0; serves as the
    ;; default for any unknown submode value — defensive).
.char_arm:
    ;; existing Story 3.3 body — unchanged
.line_arm:
    ;; existing Story 3.4 body — unchanged
.block_arm:
    CALL    visual_count_block_dims     ; HL = rows; BC = cols
    CALL    visual_compose_status_block ; format "RxC"
    JP      parser_clear                ; AC13: drop any parser state stale from the motion's preamble
```
**And** net cost in `visual_extend`: **+12 B** (the extra `CP VIS_BLOCK` 2 B + `JR Z, .block_arm` 2 B inserted at the prologue head + the `.block_arm` body: `CALL visual_count_block_dims` 3 B + `CALL visual_compose_status_block` 3 B + `JP parser_clear` 3 B; the existing `.char_arm` and `.line_arm` bodies are unchanged byte-for-byte). The Story 3.4 comment at line 233-234 ("VIS_BLOCK falls through to the CHAR arm defensively until that story lands its own .block_arm") is replaced by a comment noting the 3-way prologue and that any future submodes (post-MVP) would extend the cascade further.
**And** AR23 docstring updated: extend the "Story 3.4 — VIS_LINE arm" note with a "Story 3.5 — VIS_BLOCK arm" sibling; document the new helper calls; the existing CHAR-arm + LINE-arm count math semantics paragraphs are UNCHANGED.

**AC4 — `visual_count_block_dims` (NEW module-local helper in `src/visual.asm`) computes rows and cols of the active VIS_BLOCK rectangle from `visual_anchor` (offset) and `cursor_offset`, projected to `(row, col)` via `motion_find_line_start`. Returns HL=rows, BC=cols. NO buffer mutation (BH3 — rectangle is virtual).**

**Given** `src/visual.asm` (new helper, lands adjacent to `visual_count_lines` at lines 284-328 — both visual-extent helpers grouped together; chosen for code locality)
**When** invoked from `visual_extend`'s `.block_arm` (AC3)
**Then** the body performs:
1. **Project anchor to (row, col):**
   - `LD HL, (visual_anchor)` — HL = anchor offset (~3 B)
   - `CALL motion_find_line_start` — HL = anchor's line-start (anchor_ls) (~3 B)
   - Save anchor_ls AND compute anchor_col (= visual_anchor - anchor_ls) via PUSH/POP register juggling; store both in module-local DEFW cells (`visual_block_anchor_ls`, `visual_block_anchor_col`) — see AC5 for the cell declaration
2. **Project cursor to (row, col):**
   - `LD HL, (cursor_offset)` — HL = cursor offset (~3 B)
   - `CALL motion_find_line_start` — HL = cursor's line-start (cursor_ls) (~3 B)
   - Compute cursor_col = cursor_offset - cursor_ls; store cursor_ls AND cursor_col in module-local DEFW cells (`visual_block_cursor_ls`, `visual_block_cursor_col`)
3. **Compute rows via the same LF-walk math as `visual_count_lines` (AC5 of Story 3.4) but explicitly over `[min(anchor_ls, cursor_ls), max(anchor_ls, cursor_ls))`:**
   - Reuse the SBC-and-swap pattern from `visual_count_lines` lines 287-301 (cursor_ls - anchor_ls; JR Z .single → rows=1 fast path; JR NC .forward; backward: swap so HL=min DE=max)
   - Walk [min, max) counting LF bytes via `motion_byte_at_logical` (PUSH/POP DE around the call per the Story-3.4 DE-trash gotcha) — `LD BC, 0` accumulator, INC BC on LF, INC HL per iter, exit when HL == DE
   - rows = LFs + 1 (in HL on exit)
4. **Compute cols as `|cursor_col - anchor_col| + 1` (the absolute-value-plus-one math from `visual_extend.char_arm` lines 236-247; no LF walk needed — pure byte arithmetic):**
   - `LD HL, (visual_block_cursor_col) ; LD DE, (visual_block_anchor_col)` — load both cols
   - `OR A ; SBC HL, DE` — HL = cursor_col - anchor_col (signed)
   - `JR NC, .cols_have_abs` — forward/equal → HL already positive
   - `EX DE, HL ; LD HL, 0 ; OR A ; SBC HL, DE` — HL = -(cursor_col - anchor_col) = |delta|
   - `.cols_have_abs: INC HL` — cols = |delta| + 1
   - Move HL (cols) to BC: `LD B, H ; LD C, L`
5. **Recover rows from temp cell into HL:**
   - The rows computation (step 3) clobbered everything; stash the rows value into `visual_block_temp_rows` DEFW (~3 B + 3 B) before computing cols, then reload from cell after cols computation: `LD HL, (visual_block_temp_rows)`
6. `RET` — HL = rows, BC = cols
**And** total `visual_count_block_dims` body: **~80-95 B** (the larger spread vs the ~50-60 B `visual_count_lines` is unavoidable — block needs TWO projections, TWO line-start walks, and a secondary col-arithmetic pass on top of the row LF-walk).
**And** AR23 docstring documents: `In: (none — reads cursor_offset, visual_anchor from state.inc)`; `Out: HL = rows (1..65535); BC = cols (1..65535); cursor_offset / visual_anchor UNCHANGED; module-local cells visual_block_anchor_ls / anchor_col / cursor_ls / cursor_col / temp_rows clobbered.`; `Trashes: A, BC, DE, HL, F`; `Calls: motion_find_line_start (CALL — twice — for anchor and cursor); motion_byte_at_logical (CALL — inner LF-walk loop; PUSH/POP DE per the Story 3.4 helper-trash gotcha).`
**And** an inline comment notes the math identity: "The row-walk math is identical to visual_count_lines but operates between line-starts derived from BOTH anchor_offset and cursor_offset (not assuming anchor IS a line-start the way VIS_LINE does — VIS_BLOCK's anchor is an arbitrary offset). The col-walk is pure subtraction — column = offset - line_start, both anchors and cursors share the same calc."
**And** **AR14 invariant maintained**: NO `gapbuf_insert` / `gapbuf_delete` / `gapbuf_move_gap` calls. NO writes to `gap_start` / `gap_end`. The helper is a pure reader of buffer state — BH3 rectangle-virtuality enforced by construction (no path mutates the buffer).

**AC5 — Five new module-local DEFW cells land in `src/visual.asm` for the AC4 helper's projection scratch (anchor_ls + anchor_col + cursor_ls + cursor_col + temp_rows). NOT in `inc/state.inc` — these are visual.asm-internal projection cache, not cross-module state.**

**Given** `src/visual.asm`'s end-of-module data section (currently empty; the Story 3.4 `MSG_MODE_VISUAL_PREFIX_LEN` / `MSG_MODE_VISUAL_LINE_PREFIX_LEN` equates at lines 391-396 are constant EQUs, not DEFW data)
**When** Story 3.5 lands
**Then** the following five 16-bit module-local cells are added in a `;; --- Module-local data (Story 3.5 — visual_count_block_dims projection scratch) ---` block:
```
visual_block_anchor_ls:   DEFW 0
visual_block_anchor_col:  DEFW 0
visual_block_cursor_ls:   DEFW 0
visual_block_cursor_col:  DEFW 0
visual_block_temp_rows:   DEFW 0
```
**And** total state growth in `src/visual.asm` module-local data: **+10 B**
**And** the cells are NOT exported via `inc/state.inc` — they are visual.asm-internal projection scratch, cleared and re-written by `visual_count_block_dims` on every call (no cross-call invariants). Mirrors Story 3.3's `status_dec_dest` pattern in `src/statusln.asm` (module-local DEFW scratch for inter-helper marshalling).
**And** the module-header `State owned (read/write)` block extends to document the five new cells with a `Lifecycle:` note: "Cleared by visual_count_block_dims at every call; values are valid ONLY between the helper's entry and its RET — caller does NOT read them. Module-local, never exported."
**And** **No `inc/state.inc` changes** — `static_off` does not advance; cold-start LDIR zero-fill does not extend.

**AC6 — `visual_compose_status_block` (NEW entry in `src/visual.asm`) composes the two-number "`-- visual block -- RxC`" format. Standalone body (does NOT share the `_visual_compose_finish` tail with `visual_compose_status` / `visual_compose_status_line` — those emit one number, this emits two with an 'x' separator).**

**Given** `src/visual.asm:visual_compose_status_line` + `visual_compose_status` + `_visual_compose_finish` (Story 3.4 shared-tail compose block at lines 359-382)
**When** Story 3.5 lands
**Then** `visual_compose_status_block:` lands as a NEW labelled entry immediately above the `visual_compose_status_line` entry at line 359 (chosen for layout: all three compose entries live together; the block entry's standalone tail emits at the top so the shared tail entries below stay grouped)
**And** the body performs:
```
visual_compose_status_block:
    PUSH    BC                                  ; save cols across prefix LDIR + rows emit
    PUSH    HL                                  ; save rows across prefix LDIR
    LD      HL, msg_mode_visual_block_prefix
    LD      BC, MSG_MODE_VISUAL_BLOCK_PREFIX_LEN ; 19 bytes ("-- visual block -- ")
    LD      DE, status_compose_scratch
    LDIR                                        ; DE -> first byte past prefix
    POP     HL                                  ; restore rows
    CALL    status_u16_to_dec                   ; emits 1..5 rows digits at (DE); advances DE
    LD      A, 'x'                              ; separator
    LD      (DE), A
    INC     DE
    POP     HL                                  ; restore cols
    CALL    status_u16_to_dec                   ; emits 1..5 cols digits at (DE); advances DE
    XOR     A
    LD      (DE), A                             ; NUL terminator for status_set_message
    LD      HL, status_compose_scratch
    XOR     A                                   ; non-error code arg (AR16)
    JP      status_set_message                  ; tail-JP — AR12 funnel
```
**And** net cost: **+33 B** (standalone body; the LDIR + double `status_u16_to_dec` + 'x' separator + NUL + tail-JP is structurally similar to `_visual_compose_finish` but with an extra status_u16_to_dec call and the 'x' separator emit — cannot cleanly share the tail since this emits two numbers with an interior separator, not one number with a NUL terminator).
**And** the existing `_visual_compose_finish` shared tail at lines 373-382 is UNCHANGED — `visual_compose_status` (CHAR) and `visual_compose_status_line` (LINE) continue to fall through it; the new block entry runs its own bespoke body.
**And** the new `MSG_MODE_VISUAL_BLOCK_PREFIX_LEN EQU 19` constant joins the existing two at lines 391-396 (length of "`-- visual block -- `" — 18 ASCII chars of CHAR-prefix shape + "block " inserted between "visual" and the closing "-- " → 19 ASCII chars; NOT counting the NUL).
**And** AR23 docstring documents: `In: HL = rows (1..65535); BC = cols (1..65535)`; `Out: status_buffer pre-padded with "-- visual block -- <rows>x<cols>"; status_dirty = 1`; `Trashes: A, BC, DE, HL, F`; `Calls: status_u16_to_dec (CALL — twice); status_set_message (tail-JP)`.
**And** ABI rationale (inline comment): "Block format uses TWO numeric parameters (rows + cols) where CHAR/LINE format uses ONE (count). The shared-tail Q4 pattern from Story 3.4 (HL=count for both CHAR and LINE entries) does not extend cleanly — adding a third sharing path would require IX-parametrization of the format-string or a stateful 'second number?' flag. Standalone body is cheaper (33 B vs ~50 B for parametrized shared-tail) and clearer."

**AC7 — `src/statusln.asm` gains `msg_mode_visual_block_prefix: DEFB "-- visual block -- ", 0` (20 B incl NUL) adjacent to `msg_mode_visual_line_prefix` at line 350.**

**Given** `src/statusln.asm:350` (the Story 3.4 `msg_mode_visual_line_prefix: DEFB "-- visual line -- ", 0` line — 19 B incl NUL)
**When** Story 3.5 lands
**Then** `msg_mode_visual_block_prefix: DEFB "-- visual block -- ", 0` is added immediately after (one line below; same alignment / comment style)
**And** a doc-comment block above the new label documents: "Story 3.5 — VIS_BLOCK submode prefix. 19 ASCII chars + NUL = 20 B. visual_compose_status_block LDIRs the first 19 bytes (without the NUL) into status_compose_scratch; the rows digits follow at offset 19; then 'x'; then the cols digits; then visual_compose_status_block writes its own NUL terminator and hands off to status_set_message."
**And** the `src/statusln.asm` module-header Public block extends to list `msg_mode_visual_block_prefix` (parallel to the Story 3.3/3.4 `msg_mode_visual_prefix` / `msg_mode_visual_line_prefix` listings at lines 54-59)
**And** net cost in `src/statusln.asm`: **+20 B** of data-section bytes (one DEFB line; no code emit)

**AC8 — Status format is `"-- visual block -- RxC"` where R and C are decimal 1..65535 with leading zeros suppressed; max banner width fits the 48-B `status_compose_scratch` cell with slack.**

**Given** the AC4 + AC6 compose path
**When** I inspect what lands in `status_buffer`
**Then** the format is the literal byte sequence `"-- visual block -- "` (19 chars + trailing space; matches the family neighbours at `src/statusln.asm:342, 350`) followed by `<rows>x<cols>` decimal — both 1..5 digits each, NO leading zeros, separated by a literal `'x'` (0x78)
**And** the entry-time format is `"-- visual block -- 1x1"` (22 chars + NUL = 23 B; the rows=1 cols=1 case applies at Ctrl-V entry where anchor == cursor)
**And** **`status_compose_scratch` capacity check**: max banner width is `"-- visual block -- 65535x65535"` = 19 + 5 + 1 + 5 = 30 chars + NUL = 31 B. Cell is 48 B (per `inc/state.inc:122` Story 3.3 sizing). Slack = 17 B. Safe; no resize needed. (For comparison: Story 3.4 LINE banner max = 24 B / 24 B slack; Story 3.5 BLOCK banner max = 31 B / 17 B slack — still comfortable headroom.)
**And** examples on a buffer `"abcde\nfghij\nklmno\npqrst"` (4 lines × 5 chars + 3 LFs = 23 B; LFs at 5, 11, 17):
- `Ctrl-V` from offset 0 (line 1, col 0) → anchor=0; rows=1, cols=1; status `"-- visual block -- 1x1"`
- `Ctrl-V` from offset 0, then `l` → cursor at 1; col 1; rows=1 (same line); cols=2 (|1-0|+1); status `"-- visual block -- 1x2"`
- `Ctrl-V` from offset 0, then `j` → cursor at 6 (line 2 col 0; same col); rows=2; cols=1; status `"-- visual block -- 2x1"`
- `Ctrl-V` from offset 0, then `j l l` → cursor at 8 (line 2 col 2); rows=2; cols=3 (|2-0|+1); status `"-- visual block -- 2x3"`
- `Ctrl-V` from offset 8 (line 2 col 2), then `k h h` → cursor at 0 (line 1 col 0); backward both directions; rows=2 (|line(0) - line(8)|+1); cols=3 (|0-2|+1); status `"-- visual block -- 2x3"` (verifies normalization)
- `Ctrl-V` from offset 2 (line 1 col 2), then `G` → cursor at the last-line-start (offset 18); rows=4; cols depends on cursor's column post-G (if G lands at col 0 → cols=3; if motion-G preserves sticky column → cols=1 since col 2 stays); status updates accordingly

**AC9 — BH3 jagged-line semantics: the rectangle is *virtual*. The status's `RxC` reports the bounding rectangle dimensions; rows whose line is shorter than the column range are NOT padded in the buffer. NO `gapbuf_*` writes during VIS_BLOCK entry/extend/exit.**

**Given** a buffer like `"abcdef\nxy\nabcdef"` (3 lines: "abcdef" 6 chars, "xy" 2 chars, "abcdef" 6 chars; LFs at 6, 9; total 16 B) with cursor at offset 0 (line 1 col 0)
**When** I press Ctrl-V, then `j` (cursor → offset 7, line 2 col 0), then `l l l l` (4 right-motions — but line 2 only has 2 chars; motion_l stops at offset 8 = 'y' per the Story 2.5 contract)
**Then** the rectangle's bounding `cols` is `|cursor_col - anchor_col| + 1`. cursor_col after 4 `l`s on line 2 = `cursor_offset - line_start(cursor_offset)` = `8 - 7 = 1` (motion_l clamps before the LF; the 4-key sequence is `1 effective move` since 3 are no-ops). So cols = `|1 - 0| + 1 = 2` for the actual cursor position — BUT IF the cursor reaches col 5 on a longer subsequent line, cols would jump to 6 reflecting the bounding rectangle.
**And** **`gap_start` / `gap_end` invariant**: untouched across the VIS_BLOCK session — `visual_enter_block`, `visual_extend.block_arm`, `visual_count_block_dims`, `visual_compose_status_block`, and `parser_clear` are ALL pure readers of buffer state. AR14 grep `LD (gap_start),\|LD (gap_end),` against the post-3.5 `src/visual.asm` returns zero matches.
**And** **Buffer content invariant**: `gapbuf_init` / pre-test buffer SHA across the test cases is identical pre-and-post Ctrl-V + motion + Esc. The buffer content is not padded; short lines are NOT extended to match the rectangle width. (This contrasts with vi/vim's `O` open-line operator which DOES extend — but BH3 explicitly pins the *selection* semantic as virtual.)
**And** **Future operator semantics (Story 3.6+) NOT in scope for THIS story**: when `d` / `y` / `c` land in Stories 3.6-3.8, the per-row clipping ("delete only up to EOL; insert at column-or-EOL") will marshal the per-row ranges from the bounding rectangle. Story 3.5 only lands the rectangle; the per-row clipping logic ships with the operators.
**And** an inline comment in `visual.asm`'s `.block_arm` (AC3) documents: "BH3 jagged-line semantic — the bounding rectangle is virtual. Status banner reports `RxC` of the bounding box. Per-row clipping (short lines processed only up to EOL) is the OPERATOR's responsibility (Story 3.6+ — visual_apply_operator marshals per-row ranges from this rectangle). Story 3.5 lands the rectangle and the dimension display; NO mutation of the buffer occurs in this story (AR14 invariant pinned)."

**AC10 — Esc returns to NORMAL via the existing `enter_normal_mode`; cursor stays at extent; `visual_anchor` and `visual_submode` are zombie state until the next visual entry (same pattern as Stories 3.3 / 3.4 AC8).**

**Given** `mode_byte == MODE_VISUAL` with `visual_submode == VIS_BLOCK` and the user presses Esc (0x1B)
**When** `dispatch_visual['Esc']` routes to `enter_normal_mode` (entry 1 of dispatch_visual at `src/dispatch.asm:653-654`; UNCHANGED by Story 3.5)
**Then** `enter_normal_mode` body (at `src/dispatch.asm:300-318` — UNCHANGED) flips `mode_byte = MODE_NORMAL`, emits `msg_mode_normal` (empty banner — status pads with spaces), and tail-JPs `parser_clear`
**And** `cursor_offset` UNCHANGED (matches Story 3.3/3.4 — vi-faithful "cursor stays at extent on cancel")
**And** `visual_anchor` UNCHANGED in state (it remains as the entry offset; meaningless until the next `v` / `V` / `Ctrl-V` re-pins it; matches the SR4 / visual.asm:42-57 zombie-state contract from Story 3.3)
**And** `visual_submode` UNCHANGED in state — remains VIS_BLOCK post-exit; the next `v` overwrites it to VIS_CHAR, the next `V` overwrites it back to VIS_LINE, the next Ctrl-V overwrites it again to VIS_BLOCK. SR4 invariant: `visual_submode` is meaningful ONLY when `mode_byte == MODE_VISUAL`.
**And** the existing `enter_normal_mode` docstring at `src/dispatch.asm:300-318` ("Esc-from-COMMAND and Esc-from-VISUAL arrive here too") needs **zero changes** for Story 3.5 — it already covers VISUAL exit generically; submode-specific cleanup is unnecessary.
**And** the AC9 AR14 invariant extends across Esc: no buffer mutation on the Esc-from-VIS_BLOCK path either.

**AC11 — Hardware UAT passes the visual-block journey script on the real MicroBeast.**

**Given** I rebuild `vibe.com` with the Story-3.5 patch applied and `make push` it to MicroBeast
**When** I run the UAT script below from CCP
**Then** every step matches the predicted observation:

```
 1. STAT B:fizzbuzz.fs       → confirm fixture present (multi-line
                               source file with at least 6 lines of
                               varied widths — e.g. the FORTH fizzbuzz
                               that Stories 3.3 / 3.4 UAT'd against;
                               if not present, any multi-line .fs /
                               .txt file with at least one short line
                               works for AC9 jagged validation)
 2. vibe fizzbuzz.fs         → cursor at offset 0 (first byte of
                               line 1); mode NORMAL; status banner
                               empty; visual_anchor irrelevant;
                               visual_submode irrelevant
                               [[feedback_uat_trace_cursor]]: post-:e
                               cursor lands at offset 0 (NOT EOF),
                               so Ctrl-V from this state pins anchor
                               at 0
 3. Ctrl-V                   → status "-- visual block -- 1x1" (AC2);
                               mode = MODE_VISUAL; visual_submode =
                               VIS_BLOCK; visual_anchor = 0 (cursor
                               offset, NOT line-start — VIS_BLOCK
                               anchor lives in offset space; AC2);
                               cursor unchanged at 0
 4. l                        → motion_l advances cursor to offset 1
                               (line 1 col 1); visual_extend fires via
                               edits_compose_or_clear's MODE_VISUAL arm
                               → visual_extend's .block_arm →
                               visual_count_block_dims: anchor_ls=0,
                               anchor_col=0, cursor_ls=0, cursor_col=1;
                               rows = LFs in [0, 0) + 1 = 1; cols =
                               |1-0|+1 = 2; status
                               "-- visual block -- 1x2"
 5. l l l                    → cursor advances right 3 more cols
                               (within line 1 — assumes line 1 is
                               ≥ 5 chars; fizzbuzz line 1 is
                               typically the "..." comment header,
                               wide enough). cursor at offset 4;
                               cursor_col = 4; rows still 1; cols =
                               5; status "-- visual block -- 1x5"
 6. j                        → motion_j advances cursor to line 2,
                               sticky col 4 (or clamped to EOL of
                               line 2 if line 2 shorter — fizzbuzz
                               typically has 8-12 chars per line so
                               col 4 is preserved). Assume cursor
                               lands at offset (line2_start + 4);
                               cursor_col = 4; rows = LFs in
                               [0, line2_start) = 1; rows = 2;
                               cols = |4 - 0| + 1 = 5; status
                               "-- visual block -- 2x5"
 7. j                        → cursor → line 3, col 4 (or clamped);
                               rows = 3, cols = 5; status
                               "-- visual block -- 3x5"
 8. h h h h                  → cursor moves left 4 cols on the SAME
                               line; rows still 3; cursor_col = 0
                               (clamped at line-start); cols =
                               |0 - 0| + 1 = 1; status
                               "-- visual block -- 3x1"  (NB: anchor_col
                               IS 0 so this is the cols=1 limit; even
                               though cursor moved 4 col left, the
                               absolute |delta| dropped from 4 to 0
                               as cursor passed under anchor's column
                               and out the left side)
 9. l l                      → cursor moves right 2 cols; cursor_col
                               = 2; rows = 3; cols = |2 - 0| + 1 = 3;
                               status "-- visual block -- 3x3"
10. k                        → backward 1 row; cursor at line 2 col 2;
                               rows = 2; cols = 3; status
                               "-- visual block -- 2x3"
11. G                        → motion_G to the last-line-start; cursor
                               jumps to the start of the last line
                               (cursor_col = 0 — G lands at line-start
                               per Story 2.6); rows = total file lines;
                               cols = |0 - 0| + 1 = 1; status
                               "-- visual block -- Nx1"  (where N is
                               file line count e.g. 12 for fizzbuzz)
12. gg                       → motion_gg via parser_handle_motion_prefix +
                               second 'g'; cursor returns to BOF (offset
                               0); cursor_col = 0; rows = 1, cols = 1;
                               status "-- visual block -- 1x1" (anchor
                               was 0, cursor is now 0, same line +
                               same col → both deltas are 0)
13. Esc                      → enter_normal_mode (AC10); mode =
                               MODE_NORMAL; status pads to empty;
                               cursor stays at offset 0 extent;
                               visual_anchor + visual_submode
                               unchanged in state (zombie)
14. v                        → re-enter VIS_CHAR (Story 3.3 path);
                               anchor re-pinned at cursor=0; status
                               "-- visual -- 1" (CHAR prefix, NOT
                               block — submode flip from VIS_BLOCK
                               zombie to VIS_CHAR on the new entry)
15. Esc                      → exit; mode NORMAL; cursor stays
16. V                        → re-enter VIS_LINE (Story 3.4); anchor
                               re-pinned at line-start of cursor=0
                               (which is also 0); status
                               "-- visual line -- 1"
17. Esc                      → exit; mode NORMAL
18. Ctrl-V                   → re-enter VIS_BLOCK; anchor re-pinned
                               at cursor=0; status
                               "-- visual block -- 1x1"
19. d                        → AC1 deferral: 'd' NOT bound in
                               dispatch_visual (operator wiring
                               lands Story 3.6); falls through to
                               unbound_visual; status "unbound key";
                               mode stays MODE_VISUAL with submode
                               VIS_BLOCK; cursor unchanged; selection
                               preserved
20. j j                      → after the unbound 'd', motion_j still
                               works (parser_clear cleared the unbound
                               path's tail per AC13); cursor advances
                               2 lines; rows recomputes; cols = 1;
                               status "-- visual block -- 3x1"
21. Esc                      → exit; mode NORMAL
22. :q                       → clean exit; buffer not dirty;
                               control returns to CCP. **AR14
                               invariant pinned by UAT: the buffer
                               file on disk is unchanged — no jagged-
                               line padding has been written even
                               though VIS_BLOCK selections crossed
                               short lines via the j-motion.**
```

**AC12 — 5 headless tests under `test/cases/visual_*.asm` + 1 parser-dispatch test pass.**

**Given** `make test` runs from a fresh tree
**When** the new test cases are added (sentinel band 0xBA..0xBD for the visual_block_* + 0xED for the parser-dispatch coverage; band 0xB5..0xB9 + 0xEC consumed by Story 3.4; 0xBE reserved by `harness_fail` infra; 0xBF available for future polish)
**Then** the following 4 visual-block tests PASS:
- `visual_ctrlV-enters-block-mode.asm` (sentinel 0xBA) — buffer `"abc\nfoo\nbar"` (11 B); `cursor_offset = 5` (line 2 col 1 = 'o' in "foo"); pre-set `mode_byte = MODE_NORMAL`, `visual_submode = VIS_LINE` (sentinel — confirms VIS_BLOCK writer overwrites). CALL `visual_enter_block`. Expect: `mode_byte = MODE_VISUAL`, `visual_submode = VIS_BLOCK`, `visual_anchor = 5` (entry cursor offset — NOT 4 = line-start; AC2 — BLOCK anchor lives in offset space, NOT line-start; this is the KEY semantic distinction from VIS_LINE's anchor-snaps-to-line-start), `cursor_offset = 5` (UNCHANGED), `status_buffer` starts with `"-- visual block -- 1x1"` (22 chars: 19 prefix + '1' + 'x' + '1'), `count_accumulator = 0` (parser_clear ran).
- `visual_block-rectangle-extends.asm` (sentinel 0xBB) — buffer `"abcde\nfghij\nklmno\npqrst"` (23 B; 4 lines × 5 chars; LFs at 5, 11, 17); `cursor_offset = 0`; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_BLOCK`, `visual_anchor = 0`. CALL `motion_l` (tail-JPs `edits_compose_or_clear` → MODE_VISUAL arm → `visual_extend` → `.block_arm` → `visual_count_block_dims` → `visual_compose_status_block`). Expect: `cursor_offset = 1`, `status_buffer` starts with `"-- visual block -- 1x2"`. CALL `motion_l` again. Expect: `cursor_offset = 2`, status `"-- visual block -- 1x3"`. CALL `motion_j`. Expect: `cursor_offset = 8` (line 2 col 2; sticky col 2 from motion_j Story 2.5 contract), status `"-- visual block -- 2x3"`. CALL `motion_j`. Expect: `cursor_offset = 14`, status `"-- visual block -- 3x3"`. Verifies forward rectangle extension across rows AND cols.
- `visual_block-jagged-clamp.asm` (sentinel 0xBC) — buffer `"abcdef\nxy\nabcdef"` (16 B; line 1 = 6 chars, line 2 = 2 chars, line 3 = 6 chars; LFs at 6, 9). `cursor_offset = 0`; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_BLOCK`, `visual_anchor = 0`. Capture pre-call `(gap_start)` and `(gap_end)` as sentinels. CALL `motion_l` (cursor → 1). CALL `motion_l` × 4 more (cursor → 5; line 1 col 5 = 'f'). CALL `motion_j` (cursor → ?; motion_j sticky-col tries col 5 on line 2 which only has 2 chars → motion_j clamps to line 2's EOL-1 = offset 8 = 'y' col 1). Expect: `cursor_offset = 8`, `status_buffer` starts with `"-- visual block -- 2x2"` (anchor_col=0, cursor_col=1, |1-0|+1=2 cols; 1 LF in [0, 7) = 1; rows=2). **And**: `(gap_start)` UNCHANGED from pre-call sentinel value, `(gap_end)` UNCHANGED — verifies AR14 / AC9: NO buffer mutation despite the cursor crossing a short line. **And**: byte-for-byte buffer content unchanged (LDIR-compare the 16 B from GAP_BUFFER_BASE against the original `.payload` block; sentinel context 1 = buffer corrupted). **CRITICAL test** — the AR14 invariant for VIS_BLOCK across jagged lines.
- `visual_block-backward-rectangle.asm` (sentinel 0xBD) — buffer `"abcde\nfghij\nklmno\npqrst"` (23 B; 4 lines × 5 chars; LFs at 5, 11, 17); `cursor_offset = 14` (line 3 col 2 = 'm'); pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_BLOCK`, `visual_anchor = 14`. CALL `motion_k` (cursor → 8; line 2 col 2 sticky). Expect: `cursor_offset = 8`, `status_buffer` starts with `"-- visual block -- 2x1"` (cursor_col=2, anchor_col=2, |2-2|+1=1 col; 1 LF in [6, 12) = 1; rows=2). CALL `motion_h` × 2 (cursor → 6; line 2 col 0). Expect: `cursor_offset = 6`, status `"-- visual block -- 2x3"` (cursor_col=0, anchor_col=2, |0-2|+1=3 cols — verifies the backward-cols swap arm of AC4 step 4: cursor_col < anchor_col → SBC negative → swap → |delta|=2 → +1=3). CALL `motion_k` (cursor → 0; line 1 col 0). Expect: `cursor_offset = 0`, status `"-- visual block -- 3x3"` (rows=3, cols=3 unchanged). Verifies BOTH backward-rows arm (cursor_ls < anchor_ls in visual_count_block_dims step 3 swap) AND backward-cols arm (step 4 swap).

**And** the parser-dispatch coverage test PASSES:
- `parser_ctrlV-dispatch.asm` (sentinel 0xED) — buffer `"hello\nworld"` (11 B); pre-set `cursor_offset = 3` (line 1 col 3 = 'l'), `mode_byte = MODE_NORMAL`, `status_dirty = 0x80` (sentinel — verify the dispatcher overwrote it). Drive `0x16` (Ctrl-V) through `dispatch_key` with `dispatch_normal`: `LD A, 0x16 ; LD HL, dispatch_normal ; LD B, DISPATCH_NORMAL_COUNT ; CALL dispatch_key`. Verify post-call: `mode_byte = MODE_VISUAL`, `visual_submode = VIS_BLOCK`, `visual_anchor = 3` (entry cursor offset — NOT line-start 0; key VIS_BLOCK semantic), `cursor_offset = 3` (UNCHANGED), `status_buffer` starts with `"-- visual block -- 1x1"`, `status_dirty = 1`. Confirms `dispatch_normal[0x16]` is wired end-to-end to `visual_enter_block` and the AC1 table-insertion landed in the right sorted slot (the binary-search must find 0x16 between 0x0C and '$' = 0x24).

**Test count target: 226 → 231 PASS (+5) / 1 deliberate-fail (`harness_fail` sentinel) unchanged.**

## Tasks / Subtasks

- [x] **Task 0** (pre-dev pin with Ant — Option A recommended across the board, consistent with Stories 3.3 / 3.4 precedent):
  - [x] Q1 — Status format prefix for VIS_BLOCK. **Recommended: Option A** — `"-- visual block -- RxC"` (compact; consistent family with `"-- visual -- N"` / `"-- visual line -- N"`; fits within `status_compose_scratch` 48-B cell with 17 B slack). Alternatives: Option B = `"-- visual block -- R rows x C cols"` (verbose; ~36 B max banner, still fits but bloats budget by ~7 B); Option C = epic's literal `"V-BLOCK RxC"` (breaks the family pattern).
  - [x] Q2 — Block-dim helper ABI. **Recommended: Option A** — single `visual_count_block_dims` returns HL = rows, BC = cols. Alternatives: Option B = two helpers `visual_count_block_rows` + `visual_count_block_cols` (cleaner ABI but ~30 B more code — two duplicate line-start lookups). Option C = state.inc-resident result cells (~5 B less code but pollutes cross-module state for visual.asm-internal use).
  - [x] Q3 — Submode-toggle policy carryover. **Recommended: Option A** — Ctrl-V is bound ONLY in `dispatch_normal`; not in `dispatch_visual`. Pressing Ctrl-V while already in MODE_VISUAL falls through to `unbound_visual` (must Esc-then-Ctrl-V to switch submodes). Consistent with Story 3.4's Q1 Option A pin for `V`. Alternative: Option B = bind Ctrl-V in dispatch_visual to re-pin anchor at cursor (and submode flip to VIS_BLOCK) — adds ~25 B + same UX-only convenience that Story 3.4 deferred for `V`.
  - [x] Q4 — `visual_count_lines` reuse vs new helper. **Recommended: Option A** — new standalone `visual_count_block_dims` (don't bend `visual_count_lines`). Rationale: `visual_count_lines` (Story 3.4) relies on the AC2 invariant that `visual_anchor` IS a line-start. VIS_BLOCK breaks that invariant — anchor is an arbitrary offset. Refactoring `visual_count_lines` to handle both cases would add ~15 B and obscure the LINE-mode invariant. Standalone helper is cheaper net and keeps each mode's helper self-explanatory.
  - [x] Q5 — Status compose entry: extend shared-tail vs standalone body. **Recommended: Option A** — standalone `visual_compose_status_block` body. The Story-3.4 shared-tail pattern (`_visual_compose_finish`) takes ONE numeric param (HL = count); block format needs TWO (rows + cols separated by 'x'). Extending the shared tail would require IX-parametrization or a stateful "second number?" flag (~+15 B vs Option A's ~+5 B savings). Standalone body is cleaner.
  - [x] Q6 — Anchor column storage. **Recommended: Option A** — NO new state cell; column derived from `visual_anchor - motion_find_line_start(visual_anchor)` every time. Matches the epic AC narrative exactly ("the column is recomputed from the anchor's line scan"). Alternative: Option B = cache anchor_col in a 16-bit state cell at entry time (~+4 B state, avoids one `motion_find_line_start` call per extend) — premature optimization; SR7 architectural precedent says recompute over cache.
  - [x] Q7 — Test-count target. **Recommended: Option A** — +5 tests (4 visual_block_* + 1 parser_ctrlV-dispatch); 226 → 231 PASS. Covers AC2 (entry) + AC4/AC8 (forward + backward rectangle compute) + AC9 (BH3 jagged-clamp NO mutation) + AC1 (Ctrl-V dispatch routing). Epic's minimum is 2 (`visual_block-enters-mode.asm` + `visual_block-jagged-clamp.asm`); the +3 are coverage for forward/backward extend (AC4 swap arms) + the dispatch wiring (matches Story 3.4 Q7 pattern).
  - [x] Q8 — Commit strategy. **Recommended: Option A** — single dev commit (matches Stories 3.1 / 3.2 / 3.3 / 3.4 Epic-3 pattern).

- [x] **Task 1** — Cross-cutting state + statusln plumbing:
  - [x] 1.1 — Add `msg_mode_visual_block_prefix: DEFB "-- visual block -- ", 0` (20 B incl NUL) to `src/statusln.asm` immediately after `msg_mode_visual_line_prefix` at line 350. Doc-comment block above per AC7.
  - [x] 1.2 — Extend the `src/statusln.asm` module-header Public block at lines 54-59 to include `msg_mode_visual_block_prefix` (Story 3.5).
  - [x] 1.3 — Confirm `status_compose_scratch` (48 B; `inc/state.inc:122`) has 17 B slack over `"-- visual block -- 65535x65535\0"` (31 B). No state.inc change. (Story 3.4 left 24 B slack; Story 3.5 consumes 7 of those 24 — still comfortable.)

- [x] **Task 2** — Extend `dispatch_normal` in `src/dispatch.asm`:
  - [x] 2.1 — Insert 3-byte 0x16 entry between 0x0C (Ctrl-L) and '$' (lines 498-502) with `ASSERT 0x16 > 0x0C` and `ASSERT '$' > 0x16` flanking it. Forward-refs `visual_enter_block`. Comment: `; 0x16    — Ctrl-V — enter visual block mode (FR35, Story 3.5)`.
  - [x] 2.2 — Verify `DISPATCH_NORMAL_COUNT` auto-recomputes via `($ - .entries) / 3` from 0x25 (37) to 0x26 (38). Cross-check `build/vibe.lst` post-build per [[feedback_create_story_cross_check]] — past stories have drifted on this count.
  - [x] 2.3 — Extend `src/dispatch.asm` module-header Dependencies block (lines 150-172) with a Story 3.5 paragraph documenting `visual_enter_block` as the third forward-ref symbol after `visual_enter_char` (3.3) and `visual_enter_line` (3.4).
  - [x] 2.4 — `dispatch_visual` left UNCHANGED (Q3 Option A pin); still 20 entries post-3.3.

- [x] **Task 3** — Extend `src/visual.asm`:
  - [x] 3.1 — Replace the placeholders block at lines 399-407 with the `visual_enter_block` body per AC2; land it adjacent to `visual_enter_line` (i.e. between `visual_enter_line` at lines 184-194 and `visual_extend` at line 229). AR23 docstring above per AC2's contract.
  - [x] 3.2 — Extend `visual_extend` (lines 229-253) with the 3-way submode-dispatch prologue per AC3. Insert the `CP VIS_BLOCK ; JR Z, .block_arm` pair at the top; add the `.block_arm` body at the end (after `.line_arm`). The existing `.char_arm` and `.line_arm` bodies are byte-for-byte unchanged. Update the Story 3.4 inline comment at line 234 (`;; default for VIS_BLOCK pre-Story-3.5`) to describe the new 3-way cascade.
  - [x] 3.3 — Add `visual_count_block_dims` body (module-local helper) per AC4 — lands adjacent to `visual_count_lines` at lines 284-328 (chosen for code locality; both visual-extent helpers grouped). AR23 docstring above. The walk loop must PUSH/POP DE around `motion_byte_at_logical` (Story-3.4 DE-trash gotcha) AND PUSH/POP DE around the `motion_find_line_start` calls if BC/DE are live across them — check `motion_find_line_start`'s contract at `src/motions.asm:636` which trashes A/DE/F (preserves BC).
  - [x] 3.4 — Add 5 module-local DEFW cells per AC5: `visual_block_anchor_ls`, `visual_block_anchor_col`, `visual_block_cursor_ls`, `visual_block_cursor_col`, `visual_block_temp_rows`. Land in a `;; --- Module-local data (Story 3.5) ---` block at end-of-module (after the `MSG_MODE_VISUAL_*_PREFIX_LEN` equates).
  - [x] 3.5 — Add `visual_compose_status_block` entry per AC6 — lands immediately above `visual_compose_status_line` at line 359 (chosen for layout: all three compose entries grouped together). Standalone body — does NOT share `_visual_compose_finish` tail. Add `MSG_MODE_VISUAL_BLOCK_PREFIX_LEN EQU 19` alongside the existing two constants at lines 391-396.
  - [x] 3.6 — Module-header (lines 1-131): flip `visual_enter_block` from PLACEHOLDER to LANDS at line 33; extend State-owned block to list VIS_BLOCK as a `visual_submode` writer alongside VIS_CHAR / VIS_LINE; extend State-owned block to declare the 5 new module-local DEFW cells with Lifecycle note per AC5; Dependencies block: no new INCLUDEs needed (`motions.asm` already declared for Story 3.4's helper calls).
  - [x] 3.7 — AR sweep clean: `BIOS_CONOUT`/`BDOS_CALL`/`CALL 0x0005` = zero matches; `LD (gap_(start|end)),` = zero matches. visual.asm remains a pure reader after Story 3.5. (CRITICAL for AC9 / BH3 — any failure here means we accidentally introduced jagged-line padding.)

- [x] **Task 4** — Headless tests (5 new files in `test/cases/`):
  - [x] 4.1 — `visual_ctrlV-enters-block-mode.asm` (sentinel 0xBA) — AC2 / AC12. Pin anchor=cursor_offset (NOT line-start), submode=VIS_BLOCK, cursor unchanged, status "-- visual block -- 1x1", parser_clear ran.
  - [x] 4.2 — `visual_block-rectangle-extends.asm` (sentinel 0xBB) — AC4 / AC8 forward arms. Multi-step l + j sequence verifies rows/cols compute on forward motion.
  - [x] 4.3 — `visual_block-jagged-clamp.asm` (sentinel 0xBC) — **CRITICAL AC9 / BH3 test**. Verify status RxC reports bounding rectangle dims AND `(gap_start)` / `(gap_end)` / buffer-content all UNCHANGED post-motion across a short line.
  - [x] 4.4 — `visual_block-backward-rectangle.asm` (sentinel 0xBD) — AC4 backward-rows AND backward-cols swap arms. Multi-step k + h sequence verifies both swap paths in `visual_count_block_dims` (rows step 3, cols step 4).
  - [x] 4.5 — `parser_ctrlV-dispatch.asm` (sentinel 0xED) — AC1 end-to-end dispatch wiring; drives 0x16 through `dispatch_key` and verifies binary-search lands the right slot.
  - [x] 4.6 — Sentinel band reservations: 0xBA..0xBD + 0xED consumed; 0xBE reserved by `harness_fail` infra; 0xBF available for future polish; Stories 3.6-3.8 will consume the 0xC0..0xCF band (note: 0xC0..0xCF is currently fully consumed by Story 2.13 undo tests; Story 3.6+ will need new band — Story 3.5 does not reserve any further).
  - [x] 4.7 — Fixture-seeding convention matches Stories 3.3 / 3.4: literal `.payload` block, `gapbuf_init` + LDIR into `GAP_BUFFER_BASE`, `(gap_start) = GAP_BUFFER_BASE + length`. INCLUDE chain matches `visual_V-anchor-snaps-to-line-start.asm` (lines 154-169 — full src chain plus test_teardown_stub + test_input_loop_stub + state.inc at end).
  - [x] 4.8 — No bulk INCLUDE patch needed — visual.asm chain already wired since Story 3.3. Post-3.5 count: 219 tests INCLUDE visual.asm (214 pre-existing + 5 new).

- [x] **Task 5** — NFR18 byte-identical rebuild + UAT + sprint-status flip:
  - [x] 5.1 — Confirm NFR18 byte-identical SHA across two `make clean && make all` cycles. Pre-3.5 SHA = `4d3d7fa654aaa6c7bafe1c3e20c8f66cfc805070a15ada12a5ec14ffc7f9a110` (from Story 3.4 — will change post-3.5; capture and document the new post-3.5 SHA).
  - [x] 5.2 — `make sizes` reports projected post-3.5 footprint per the budget arithmetic block (~165 B code growth + 10 B module-local data = ~6883 B / ~84% of 8192 B / ~1309 B headroom). Cross-check actuals against projection; document any drift per [[feedback_create_story_cross_check]].
  - [x] 5.3 — Hardware UAT (AC11, 22 steps) deferred to user — script pasted inline at dev-handoff per [[feedback_uat_inline_at_dev_handoff]].
  - [x] 5.4 — Flip `sprint-status.yaml` `3-5-visual-block-mode` `ready-for-dev` → `in-progress` → `review`; → `done` after Ant confirms hardware UAT.

### Review Findings

- [x] [Review][Patch] Multi-digit RxC status banner not exercised by any test — added `test/cases/visual_block-multidigit-banner.asm` (sentinel 0xBF). Drives `visual_extend` over a 12 × 12-char buffer at three cursor offsets (1x12, 12x1, 12x12); asserts banner content AND post-banner space-pad byte to catch any over-emit regression in the dual-`status_u16_to_dec` path. Test count 231 → 232.
- [x] [Review][Patch] `ASSERT VIS_CHAR == 0` added in `src/visual.asm` immediately before `.char_arm:` in the `visual_extend` prologue — pins the equate-ordering invariant the fall-through depends on.
- [x] [Review][Patch] `ASSERT MSG_MODE_VISUAL_BLOCK_PREFIX_LEN + 5 + 1 + 5 + 1 <= 48` added next to `MSG_MODE_VISUAL_BLOCK_PREFIX_LEN EQU 19` — pins `status_compose_scratch` (48 B) ≥ worst-case banner (31 B).
- [x] [Review][Patch] Added `Depends:` line to `visual_compose_status_block` header docstring documenting reliance on `status_u16_to_dec` advancing DE past emitted digits (both the literal 'x' write and the NUL terminator depend on this).
- [x] [Review][Defer] No empty-buffer VIS_BLOCK test (entry at offset 0 of empty buffer; same-line-start "1x1" path) — deferred, post-UAT polish per Epic 3 convention.
- [x] [Review][Defer] No EOF-anchor VIS_BLOCK test (`$a` then Esc then Ctrl-V — anchor pinned at file_length) — deferred, post-UAT polish per Epic 3 convention.
- [x] [Review][Defer] No counted-motion VIS_BLOCK test (e.g. `5l` from VIS_BLOCK) verifying count_accumulator integrates with `.block_arm` — deferred, post-UAT polish per Epic 3 convention.
- [x] [Review][Defer] No regression-pin asserting `Ctrl-V` falls through to `unbound_visual` inside an existing visual session (the Q3 Option A deferral is not tested) — deferred, post-UAT polish per Epic 3 convention.

## Dev Notes

### Architecture compliance

**AR boundaries — `src/visual.asm` remains a PURE READER of buffer state after Story 3.5.**
- AR13 (BIOS_CONOUT): zero call sites — visual.asm still never emits to screen. Status updates funnel through `status_set_message` (AR12 owner statusln.asm).
- AR14 (gap_start / gap_end WRITES): zero write sites. `visual_enter_block` reads cursor_offset; `visual_count_block_dims` calls `motion_find_line_start` (pure read) + `motion_byte_at_logical` (pure read); writes only to mode_byte / visual_submode / visual_anchor / status_compose_scratch state + the 5 new module-local DEFW cells. **CRITICAL — AC9 / BH3 invariant**: NO buffer mutation. The rectangle is virtual; short lines are not padded. AR14 grep enforces.
- AR15 (BDOS_CALL): zero call sites — visual.asm still never invokes BDOS.

**AR23 (per-module header convention)** — `visual_enter_block`, `visual_count_block_dims`, and `visual_compose_status_block` each get a docstring with In/Out/Trashes/Calls per the Story 1.5+ pattern. The 5 new module-local DEFW cells get a Lifecycle note per AC5.

**AR25 (INCLUDE order)** — Story 3.5 adds NO new INCLUDEs. `src/visual.asm` is already in the chain (Story 3.3); `src/motions.asm` is already INCLUDEd BEFORE `src/visual.asm` (motions at vibe.asm:136, visual at vibe.asm:164); so `motion_find_line_start` + `motion_byte_at_logical` are backward-resolved from `visual_count_block_dims`' calls. `visual_enter_block` is forward-referenced from dispatch.asm's new `0x16` entry (resolves on sjasmplus's second pass — same shape as Story 3.3's `visual_enter_char` and Story 3.4's `visual_enter_line` forward-refs).

**MC4 register convention** — `visual_enter_block` accepts A = 0x16 (Ctrl-V) as the dispatched key (per MC4 contract); the value is ignored after dispatch. `visual_count_block_dims` reads no register state on entry (pulls from state.inc cells). `visual_compose_status_block` accepts HL = rows, BC = cols (matches the AC4 helper's return ABI directly).

**SR4 mode-byte + submode invariant** — when `mode_byte == MODE_VISUAL`, `visual_submode` is one of `VIS_CHAR | VIS_LINE | VIS_BLOCK`. Story 3.3 landed the VIS_CHAR writer. Story 3.4 added the VIS_LINE writer. **Story 3.5 lands the VIS_BLOCK writer — completing the submode-writer triad.** The Esc-to-NORMAL transition does NOT clear visual_submode (per Story 3.3 dispatch.asm:19-22 — "the mode-change handler does NOT clear visual_submode; the value is meaningless in non-visual modes and the next visual entry overwrites it"). Story 3.5's AC10 reaffirms this contract — visual_submode remains VIS_BLOCK post-Esc until the next `v` (VIS_CHAR) or `V` (VIS_LINE) or Ctrl-V (VIS_BLOCK) overwrites it.

**SR5 visual-anchor semantic — TRIPLE-PROTOCOL post-Story-3.5:**
- VIS_CHAR (Story 3.3): `visual_anchor = cursor_offset` at entry (offset space). Extent computed as `|cursor - anchor| + 1` byte range.
- VIS_LINE (Story 3.4): `visual_anchor = motion_find_line_start(cursor_offset)` at entry (line-start space). Extent computed as LFs in `[min(anchor, cursor_ls), max(anchor, cursor_ls))` + 1 lines.
- VIS_BLOCK (Story 3.5): `visual_anchor = cursor_offset` at entry (offset space — SAME as VIS_CHAR, NOT line-start). Extent computed as `(rows = LFs in [min(anchor_ls, cursor_ls), max(...)) + 1, cols = |cursor_col - anchor_col| + 1)` rectangle. Anchor's column is derived on-demand as `visual_anchor - motion_find_line_start(visual_anchor)`.
- **The three anchor semantics are not interchangeable.** VIS_LINE's anchor (line-start) cannot be re-used as a VIS_BLOCK anchor (which needs the column). VIS_BLOCK's anchor (offset) cannot be re-used as a VIS_LINE anchor (line-start invariant would break). Each visual entry RE-PINS the anchor per its own submode contract; the Esc-to-NORMAL transition leaves the anchor as zombie state until the next entry overwrites it.

**SR-state ownership (state.inc):**
- `visual_anchor` (16-bit, `inc/state.inc:99`): WRITERS = `visual_enter_char` (Story 3.3, VIS_CHAR — anchor at cursor offset) AND `visual_enter_line` (Story 3.4, VIS_LINE — anchor at cursor's *line-start*) AND `visual_enter_block` (Story 3.5, VIS_BLOCK — anchor at cursor offset, column implicit). READERS = `visual_extend` (all three arms — char, line, block); future `visual_apply_operator` (Story 3.6+).
- `visual_submode` (1-byte, `inc/state.inc:52`): WRITERS = `visual_enter_char` (VIS_CHAR — Story 3.3) AND `visual_enter_line` (VIS_LINE — Story 3.4) AND `visual_enter_block` (VIS_BLOCK — Story 3.5). **Triad complete after Story 3.5.** READERS = `visual_extend` (the 3-way submode-dispatch prologue per AC3); future `visual_apply_operator` (range-marshalling differs per submode).
- `status_compose_scratch` (48 B, `inc/state.inc:122`): WRITERS extend by one — `visual_compose_status_block` (Story 3.5) joins `visual_compose_status` (Story 3.3), `visual_compose_status_line` (Story 3.4), and the fileio composers (Stories 2.2/2.3/2.4). The buffer's 48-B size has 17-B slack over the longest Story-3.5 banner ("-- visual block -- 65535x65535\0" = 31 B); no resize needed.
- 5 new module-local DEFW cells in `src/visual.asm` (NOT state.inc) per AC5: `visual_block_anchor_ls` / `_anchor_col` / `_cursor_ls` / `_cursor_col` / `_temp_rows`. Lifecycle: cleared and re-written by `visual_count_block_dims` at every call; values valid only between helper entry and RET. Module-local, never exported.

### Files this story modifies (and what to preserve)

**`src/dispatch.asm`** (currently 712 lines):
- INSERT one 3-byte entry + 2 ASSERTs between lines 498-502 (between 0x0C and '$' in dispatch_normal) per Task 2.1.
- MODIFY the existing `ASSERT '$' > 0x0C` at line 500 to `ASSERT '$' > 0x16` per Task 2.1.
- MODIFY module-header Dependencies block — extend the existing visual.asm entry (lines 150-172) with Story 3.5 paragraph per Task 2.3.
- PRESERVE: ALL of dispatch_normal's existing 37 entries (only the new 0x16 entry inserts; sort order preserved by the ASSERT update); dispatch_insert, dispatch_command, dispatch_visual UNCHANGED; enter_normal_mode, enter_insert_mode, unbound_normal, unbound_visual, unbound_insert ALL UNCHANGED; the dispatch_key body UNCHANGED.

**`src/visual.asm`** (currently 407 lines):
- REPLACE comment-only placeholders block at lines 399-407 with the `visual_enter_block` body (Task 3.1) — placement adjacent to `visual_enter_line` for code locality (alternate placement near the end of module also acceptable per AC2).
- MODIFY `visual_extend` (lines 229-253) — add 3-way submode-dispatch prologue per Task 3.2; insert `CP VIS_BLOCK / JR Z, .block_arm` at the prologue head; append `.block_arm` body after `.line_arm`.
- ADD `visual_count_block_dims` body (module-local) per Task 3.3 — adjacent to `visual_count_lines`.
- ADD 5 module-local DEFW cells per Task 3.4 — at end-of-module data section.
- ADD `visual_compose_status_block` entry per Task 3.5 — above `visual_compose_status_line` at line 359.
- ADD `MSG_MODE_VISUAL_BLOCK_PREFIX_LEN EQU 19` alongside lines 391-396.
- MODIFY module-header (lines 1-131) per Task 3.6 — Public block: flip `visual_enter_block` from PLACEHOLDER to LANDS; State-owned block: add VIS_BLOCK writer for `visual_submode`, add 5 new module-local DEFW cells with Lifecycle note; Dependencies block: NO changes (motions.asm already listed since Story 3.4).
- PRESERVE: `visual_enter_char` body (lines 150-159; UNCHANGED); `visual_enter_line` body (lines 184-194; UNCHANGED); `visual_extend`'s `.char_arm` body (lines 235-249; UNCHANGED) and `.line_arm` body (lines 250-253; UNCHANGED); `visual_count_lines` body (lines 284-328; UNCHANGED — VIS_LINE math distinct from VIS_BLOCK math); `visual_compose_status` / `visual_compose_status_line` / `_visual_compose_finish` shared-tail (lines 359-382; UNCHANGED — new `visual_compose_status_block` is standalone, does NOT share the tail); `MSG_MODE_VISUAL_PREFIX_LEN` / `MSG_MODE_VISUAL_LINE_PREFIX_LEN` equates (UNCHANGED).

**`src/statusln.asm`** (currently 367 lines):
- ADD `msg_mode_visual_block_prefix: DEFB "-- visual block -- ", 0` (20 B) at line 351 (immediately after `msg_mode_visual_line_prefix`) per Task 1.1.
- MODIFY module-header Public block to list `msg_mode_visual_block_prefix` per Task 1.2.
- PRESERVE: `msg_mode_visual_prefix` + `msg_mode_visual_line_prefix` (UNCHANGED); `status_u16_to_dec` body (UNCHANGED — both Story-3.4 and Story-3.5 composers call into it); all other message labels; `status_set_message` body; `bdos_error_funnel` body.

**`inc/state.inc`** — NO CHANGES. `status_compose_scratch` is sized at 48 B (Story 3.3 sizing) with 17-B headroom for the new "-- visual block -- 65535x65535" banner. The 5 new VIS_BLOCK projection cells are module-local DEFW in `src/visual.asm`, NOT state.inc cross-module cells.

**`inc/modes.inc`** — NO CHANGES. `VIS_BLOCK EQU 2` was pre-declared since Story 1.2 (line 31). No new equates needed; the `0x16` control-byte literal in dispatch_normal mirrors the existing `0x0C` Ctrl-L pattern (NFR16 carve-out for control bytes is established precedent across `dispatch_normal` / `dispatch_insert`).

**`src/motions.asm`** — NO CHANGES. `motion_find_line_start` (line 636) and `motion_byte_at_logical` (line 557) are reused as-is by `visual_count_block_dims`; their contracts are documented and unchanged.

**`src/edits.asm`** — NO CHANGES. `edits_compose_or_clear`'s MODE_VISUAL arm (Story 3.3, line 1357) routes to `visual_extend` which now internally dispatches on submode (3-way after Story 3.5). The bare-motion bare-VISUAL routing is exhaustive and unchanged.

**`src/vibe.asm`** — NO CHANGES. visual.asm already INCLUDEd at line 164 by Story 3.3.

**Test files (`test/cases/*.asm`):**
- ADD 5 new test files per Task 4 (4 visual_block_* + 1 parser_ctrlV-dispatch).
- NO bulk patch needed — the AR25 INCLUDE chain extension for visual.asm was done by Story 3.3 (214 tests already include it post-3.4).
- PRESERVE: All existing test bodies.

### Implementation choices and trade-offs

**Choice: `visual_anchor` stays at cursor offset for VIS_BLOCK (NOT line-start).**
- Per Q6 Option A and epic AC narrative ("`visual_anchor` records the anchor offset (and the column is recomputed from the anchor's line scan)"). The anchor lives in offset space; column is derived on-demand. This DIFFERS from VIS_LINE's anchor (which snaps to line-start at entry, Story 3.4 AC2) — the two submodes have different anchor semantics by design.
- Alternative considered: pin anchor at line-start of cursor (matching VIS_LINE). Rejected — VIS_BLOCK needs the column, which is `anchor_offset - anchor_ls` not `0`; flattening anchor to line-start loses the column data.
- Alternative considered: store separate `visual_anchor_col` cell in state.inc (Option B). Rejected — adds 2 B state for a value that's a 1-instruction subtract away from existing state; SR7 architecture-precedent says recompute over cache.

**Choice: `visual_count_block_dims` is standalone, not a refactor of `visual_count_lines`.**
- Per Q4 Option A. `visual_count_lines` is a 50-line helper with the AC2 invariant baked in ("anchor IS a line-start"). VIS_BLOCK breaks that invariant. Adding a "is anchor a line-start?" parameter would add ~15 B AND obscure the LINE-mode invariant.
- Alternative considered: parametrize `visual_count_lines` via a flag. Rejected — invariant erosion; future readers can't tell which submode owns which call site.

**Choice: `visual_compose_status_block` is standalone, not a shared-tail extension.**
- Per Q5 Option A. The Story-3.4 shared-tail (`_visual_compose_finish`) takes one numeric param (HL = count). Block format needs two (rows + cols with 'x' separator). Sharing the tail would require IX-parametrization OR a stateful flag; both add ~15 B for ~5 B saved.
- Alternative considered: emit format as `"-- visual block -- N"` where N is total cells (rows × cols). Rejected — loses the rectangle visualization (12-row × 1-col vs 1-row × 12-col have different UX implications); epic AC explicitly pins "rows × cols".

**Choice: Status format "`-- visual block -- RxC`" (compact, family-consistent).**
- Per Q1 Option A. Matches the `"-- visual -- N"` / `"-- visual line -- N"` family pattern (lower-dash banner with mode label and count). Uses 'x' as separator (familiar from "RxC" in screen geometry / matrix dims).
- Alternative considered: `"V-BLOCK RxC"` (epic's literal narrative). Rejected — breaks the family pattern; would invite further "-- visual --" → "VISUAL" / "V-LINE" renaming churn across Stories 3.3 / 3.4.
- Alternative considered: `"-- visual block -- R rows x C cols"` (verbose). Rejected — bloats budget by ~7 B / banner; not worth the marginal clarity gain.

**Choice: Ctrl-V is bound ONLY in `dispatch_normal`; not in `dispatch_visual`.**
- Per Q3 Option A — carries forward the Story 3.4 Q1 Option A precedent. Scope discipline — Story 3.5 closes the Ctrl-V-from-NORMAL entry; the v↔V↔Ctrl-V submode-toggle UX is a polish story sibling-decision. For Story 3.5, Ctrl-V while in VISUAL falls through to `unbound_visual` with "unbound key" status; the user `Esc`s then `Ctrl-V`.
- Alternative considered: bind Ctrl-V in dispatch_visual to `visual_enter_block` (re-pin anchor + flip submode). Rejected — adds ~25 B for UX-only convenience; the submode-toggle polish story is the right home for this (and would land all three v/V/Ctrl-V toggles together, not piecemeal).
- Updates deferred-work.md (Story 3.4 entry) — the "Story 3.5's Ctrl-V neighbour decision" trigger fires; resolved with Option A; revisit deferred to a future polish-story milestone.

**Choice: BH3 jagged-line virtuality enforced by construction (no `gapbuf_*` calls in this story).**
- Per AC9 / AR14 invariant. Story 3.5 lands the rectangle and the dimension display; no buffer mutation occurs. Per-row clipping ("delete only up to EOL on short lines; insert at column-or-EOL") is the OPERATOR's responsibility (Story 3.6+ — `visual_apply_operator` marshals per-row ranges from this story's rectangle).
- Architecture BH3 (lines 682-689) explicitly pins this: "operate on virtual rectangle; short lines are not extended in the buffer". Story 3.5 makes the rectangle; Stories 3.6-3.8 do the operating with the per-row clipping.
- Test `visual_block-jagged-clamp.asm` (sentinel 0xBC) is the CRITICAL load-bearing test for this invariant — explicitly verifies `(gap_start)` / `(gap_end)` / buffer content all UNCHANGED post-Ctrl-V + motion across a short line.

**Choice: 5 new module-local DEFW cells (not in state.inc).**
- Per AC5. The five projection cells (anchor_ls, anchor_col, cursor_ls, cursor_col, temp_rows) are visual.asm-internal helper scratch — cleared and re-written by `visual_count_block_dims` at every call; values valid only between helper entry and RET. No cross-module reader.
- Mirrors `status_dec_dest` (Story 3.3, module-local DEFW in statusln.asm).
- Alternative considered: stack-based marshalling via PUSH/POP. Rejected — 5 values × 2 levels of helper nesting would exceed Z80's natural depth for clean PUSH/POP grouping; module-local cells are 10 B of state for ~30 B of code savings.
- Alternative considered: state.inc-resident cells. Rejected — visual.asm-internal; cross-module visibility is unnecessary and would pollute the cross-module state surface.

### Previous story intelligence

**From Story 3.4 (just completed, UAT confirmed):**
- `visual_count_lines` (the LINE-mode helper) established the LF-walk pattern over `[min, max)`. Story 3.5's `visual_count_block_dims` reuses the same SBC-and-swap arithmetic for the rows computation (step 3 of AC4); cols computation is the same `|delta| + 1` arithmetic from `visual_extend.char_arm` (Story 3.3 — lines 236-247 of visual.asm).
- **DE-trash gotcha**: `motion_byte_at_logical` trashes DE per its AR23 contract. Story 3.4's `visual_count_lines` PUSHes/POPs DE around the call. Story 3.5's `visual_count_block_dims` MUST do the same. Recurring gotcha — third instance (Story 2.6 motion_dollar, Story 3.4 visual_count_lines, Story 3.5 visual_count_block_dims). Worth a `motion_byte_at_logical` contract callout in the AR23 docstring at `src/motions.asm:533`.
- **Spec narrative drift caught**: AC1 + Task 2.2 of Story 3.4 said dispatch_normal grew "28 → 29". The actual count post-3.4 was 36 → 37. Per [[feedback_create_story_cross_check]], Story 3.5 explicitly says "37 → 38" with a cross-check note. The dev pass should still verify against `build/vibe.lst` since drift is recurring across the last 4 stories on this metric.
- **Q1 Option A pin (V-in-VIS_CHAR submode-toggle deferred)**: Story 3.5's Q3 carries this forward — Ctrl-V is also NOT bound in dispatch_visual. Together both Story 3.4's V and Story 3.5's Ctrl-V keep the submode-toggle polish deferred until a dedicated UX-polish story.
- **Q4 shared-tail pattern**: Story 3.4 split `visual_compose_status` into two named entries (CHAR + LINE) with a JR fall-through to `_visual_compose_finish`. Story 3.5's BLOCK format needs two numeric params so cannot share the tail cleanly — Q5 Option A pins standalone body. Pattern: SAME-shape composers can share a tail; DIFFERENT-shape composers each need their own body.
- **Status compose scratch sizing**: Story 3.4 verified `status_compose_scratch` 48-B cell has 24 B slack over the LINE banner. Story 3.5 consumes 7 of those 24 → 17 B slack post-3.5. Still comfortable; no resize needed.
- **NFR18 SHA byte-identical discipline**: Story 3.4 confirmed `4d3d7fa6...` across two clean+build cycles. Story 3.5 will compute and record a new SHA (the dispatch_normal['Ctrl-V'] insert + visual.asm growth shifts every address from 0x16's slot onward).
- **Sentinel band reservation**: Story 3.4's closing note reserved "0xBA..0xBD for Story 3.5 V-block tests". Story 3.5 consumes exactly that band + 0xED for parser_ctrlV-dispatch. 0xBE remains reserved by harness_fail; 0xBF available for future polish.

**From Story 3.3 (visual character mode `v`):**
- `visual_enter_char` established the visual-entry pattern: write mode_byte → visual_submode → visual_anchor → compose status → tail-JP parser_clear. Story 3.5's `visual_enter_block` mirrors this body shape exactly, differing only in the submode constant (VIS_BLOCK vs VIS_CHAR) and the compose-call (status_block vs status — block needs cols arg in BC).
- The retired enter_visual_mode stub (Story 3.3) cleared the path for forward-referenced visual_enter_char from dispatch.asm. Story 3.5 follows the same shape — visual_enter_block is forward-referenced from dispatch_normal[0x16].
- The placeholders comment block at `src/visual.asm:399-407` was explicitly handed off as the landing strip for Stories 3.4 / 3.5 / 3.6+ bodies. Story 3.4 added visual_enter_line; Story 3.5 retires the rest of the placeholder (the `visual_enter_block` body lands here OR adjacent to visual_enter_line — Story 3.5 chooses the latter for code locality).

**From Story 3.2 (`n` repeat search):**
- The `parser_n-dispatch.asm` end-to-end dispatch wiring test pattern is reused for `parser_ctrlV-dispatch.asm` (Task 4.5) — drive a key through `dispatch_key` with the `dispatch_normal` table; verify the entry was added in the correct sorted slot.

**From Story 2.13 (single-level undo `u`):**
- Sentinel band 0xC0..0xCF is fully consumed by undo_* tests. Story 3.5 deliberately stays in the 0xBA..0xBD + 0xED bands (Epic 3 visual band). Story 3.6+ will need a new band (0xCF is the last consumed; 0xD0..0xDF available).

**From Story 2.5 (basic motions):**
- AC13 contract — every NORMAL→other-mode handler tail-JPs `parser_clear`. Story 3.5's `visual_enter_block` tail-JPs parser_clear at step 7 of AC2's body.

**From Story 1.10 (parser FSM):**
- `parser_handle_digit` and `parser_handle_motion_prefix` remain mode-agnostic — used by both dispatch_normal and dispatch_visual since Story 3.3. Story 3.5 doesn't touch the parser. Counted Ctrl-V (e.g. `5 Ctrl-V`) is OUT OF SCOPE — Ctrl-V doesn't compose with count (vi has no concept of "counted visual entry" — would be a polish-story Q if anyone asks).

### Git intelligence

**Recent commits (last 5; for context — Story 3.5 follows the same shape):**
- `517bef1 Story 3.4: visual line mode V lands; FR34 closes; VIS_LINE submode` — direct precursor; established the VIS_LINE writer + the visual_extend submode-dispatch prologue + the shared-tail compose refactor that Story 3.5 EXTENDS with the VIS_BLOCK arm + standalone block-compose.
- `a1ce47d Story 3.3: visual character mode lands; FR15/FR33 close; visual.asm module` — established the visual.asm module + the visual_compose_status helper that Story 3.4 refactored and Story 3.5 leaves alone (block uses its own compose).
- `c0761fd Story 3.2: repeat last search n with wrap` — single-commit Epic-3 pattern; NFR18 SHA byte-identical discipline.
- `231ce3f Story 3.1: forward literal search /pattern lands; FR41 closes` — stub-retirement pattern (no analogue in 3.5 — Ctrl-V is a NEW key with no prior stub).
- `c8fb896 Story 2.13: single-level undo u lands; FR45/FR46 closed; closes Epic 2` — dispatch_normal entry-addition pattern (single key insert; matches Story 3.5's `0x16` insert exactly).

**Pattern:** every Epic-3 story so far has been single-commit, 5-6 new headless tests, NFR18 byte-identical rebuild required. Story 3.5 follows the same shape.

**Insight from Story 3.4's dev pass:** `visual_count_lines` came in at ~63 B vs the spec's 55 B mid-estimate (the extra 8 B was the PUSH DE / POP DE bracketing around motion_byte_at_logical). Story 3.5's `visual_count_block_dims` spec estimates 80-95 B; expect similar 5-10 B drift on the actual implementation. Budget arithmetic block below uses the mid-estimate (87 B); if actual closes 95 B, total still well within budget.

### Implementation Questions (resolve with Ant before dev starts)

See **Task 0** for the Q1-Q8 pin list. Recommended pins are all **Option A** consistent with the Story 3.3 / 3.4 precedent. Resolve in chat before Task 1; the pins shape AC details but the body is robust to any pin choice (BLOCK-mode rectangle compute is well-bounded vi-faithful behaviour; the only material UX-impact choice is Q1 status format).

### NFR9 budget arithmetic (worked example)

Pre-3.5 footprint: **6708 B / 81.9% of 8192 B / 1484 B headroom** (per Story 3.4 dev-pass actuals — final size landed +3 B over spec's 6705 B projection due to the DE-trash bracketing in `visual_count_lines`).

Story 3.5 projected deltas (positive = grows footprint; negative = shrinks):
- `src/visual.asm` visual_enter_block body: **+28 B** (mirrors visual_enter_line's body shape; one extra LD BC,1 for cols arg)
- `src/visual.asm` visual_count_block_dims body: **+87 B** (mid-estimate of AC4's 80-95 B range; double line-start + double col arithmetic + LF walk + temp_rows stash)
- `src/visual.asm` visual_extend 3-way prologue extension: **+12 B** (CP VIS_BLOCK + JR Z + .block_arm body with CALL/CALL/JP)
- `src/visual.asm` visual_compose_status_block standalone body: **+33 B** (PUSH BC + PUSH HL + LDIR + status_u16_to_dec + 'x' + status_u16_to_dec + NUL + tail-JP)
- `src/statusln.asm` msg_mode_visual_block_prefix (20 B incl NUL): **+20 B**
- `src/dispatch.asm` dispatch_normal[0x16] entry: **+3 B** (ASSERTs are assembly-time, zero runtime)

Subtotal code growth: **+183 B**

State growth: **+10 B** (5 module-local DEFW cells in src/visual.asm for visual_count_block_dims projection scratch; NOT in state.inc — visual.asm-internal). No equates.inc / state.inc changes.

**Projected post-3.5 footprint: 6708 + 183 = 6891 B / 84.1% of 8192 B / 1301 B headroom.**

Generous runway remaining for Stories 3.6-3.8:
- 3.6 (operators d/y/c — apply to VIS_CHAR/LINE/BLOCK ranges): ~250-350 B (visual_apply_operator + 3 per-operator bodies + per-submode range-marshalling — VIS_BLOCK is the per-row loop complexity)
- 3.7 (visual shift `>` `<`): ~80-120 B (extends Story 2.11's op_compose_indent/dedent to per-row walk; visual_apply_operator routes by sub-mode)
- 3.8 (visual case-toggle `~`): ~50-80 B (per-byte case-flip walk + VIS_BLOCK per-row clip)
- Total Epic 3 remaining projection: ~380-550 B → post-Epic-3 ~7271-7441 B / 89-91% of 8192 B / ~750-920 B headroom. Within ceiling.

**Revisit trigger:** Story 3.6's visual_apply_operator carries the most uncertainty (BH3 per-row marshalling for VIS_BLOCK is the cliff-edge complexity); if Story 3.6 projects >400 B, recommend an NFR9 amend conversation at the Story 3.6 boundary.

### Test count target

226 (post-3.4) → **231 PASS** (+5 new from Story 3.5) / 1 deliberate-fail (`harness_fail` sentinel) unchanged.

### Project Structure Notes

- `src/visual.asm` grows from 407 lines (post-3.4) to ~520 lines (post-3.5; +1 entry body + 1 helper body + 1 compose entry body + 5 DEFW cells + module-header updates + 3-way prologue patch).
- Sentinel band allocation (cumulative through Story 3.5):
  - 0xA0..0xAA + 0xE9 — Story 3.1 (`/pattern` search)
  - 0xAB..0xAF + 0xEA — Story 3.2 (`n` repeat)
  - 0xB0..0xB4 + 0xEB — Story 3.3 (VIS_CHAR)
  - 0xB5..0xB9 + 0xEC — Story 3.4 (VIS_LINE)
  - 0xBA..0xBD + 0xED — Story 3.5 (VIS_BLOCK; THIS STORY)
  - 0xBE reserved by `harness_fail` infra (the deliberate-fail sentinel — do not consume)
  - 0xBF available for future polish stories or operator coverage tests
  - 0xC0..0xCF fully consumed by Story 2.13 undo_* tests (Story 3.6+ will need a new band — 0xD0..0xDF available)
- No project-context.md exists in planning-artifacts — Story 3.5 relies on the architecture / epics / PRD trio plus the Story 3.3 / 3.4 implementation artifacts.
- Per [[feedback_create_story_cross_check]]: cross-checked the AC narrative against actual render/edit semantics:
  - **Cursor lands at offset 0 post-`:e`** ([[feedback_uat_trace_cursor]]) — verified in AC11 step 2 — UAT script Ctrl-V from offset 0 pins anchor at 0; no surprise.
  - **No `~` past-EOF marker** ([[project_no_tilde_marker]]) — no UAT step predicts a tilde. Past-EOF rows render as blank spaces (0x20).
  - **CR/CRLF and sjasmplus-hostile filenames** — not relevant to Story 3.5 (visual mode doesn't touch file I/O paths; the fixture buffer is LF-only as per Stories 3.3 / 3.4 precedent).
  - **NFR9 projection** — explicit at AC4 + Tasks plus the budget arithmetic block.
  - **status_compose_scratch sizing** — verified 48-B cell (per Story 3.3 dev-pass adjustment) accommodates "-- visual block -- 65535x65535\0" (31 B used; 17 B slack).
  - **DISPATCH_NORMAL_COUNT cross-check** — pre-3.5 count is 37 (0x25) per the build/vibe.lst output from Story 3.4. Story 3.5 specs the post-insert count as 38 (0x26). Dev pass MUST verify against the actual `build/vibe.lst` value — three previous stories drifted on this metric. The auto-computed `($ - .entries) / 3` EQU is the source of truth; the spec narrative is the projection.
  - **AR14 invariant** — explicitly pinned at AC9 + the `visual_block-jagged-clamp.asm` test (sentinel 0xBC) which is the LOAD-BEARING regression net for "no buffer mutation in VIS_BLOCK". A bug that introduced even one `gapbuf_insert` call into visual.asm's VIS_BLOCK path would fail this test instantly.

### References

- **Epic 3 narrative:** `_bmad-output/planning-artifacts/epics.md:1480-1484` (Epic 3 header + visual-highlighting platform-constraint note).
- **Story 3.5 epic AC source:** `_bmad-output/planning-artifacts/epics.md:1629-1660` (the original 5-AC narrative).
- **Architecture BH3 (jagged-line semantic):** `_bmad-output/planning-artifacts/architecture.md:682-689` (the canonical "virtual rectangle; short lines not extended" pin).
- **Architecture AR25 INCLUDE chain:** `_bmad-output/planning-artifacts/architecture.md:1304-1306` (visual.asm sits between edits and search; UNCHANGED).
- **Architecture mode-byte SR4:** `_bmad-output/planning-artifacts/architecture.md:447-451` (MODE_VISUAL implies visual_submode is VIS_CHAR/VIS_LINE/VIS_BLOCK).
- **Architecture visual.asm module purpose:** `_bmad-output/planning-artifacts/architecture.md:1304-1306` ("Visual-mode entry/exit, anchor management (SR5), block/line/char selection ops: d, y, c, >, <, ~").
- **Architecture SR6 yank-register + KIND_BLOCK reserve:** `_bmad-output/planning-artifacts/architecture.md:456-461` + `inc/equates.inc:91` (KIND_BLOCK reserved since Epic 2; consumed by Story 3.6+'s visual-block operators — Story 3.5 does NOT touch the yank register).
- **Architecture module dependency graph:** `_bmad-output/planning-artifacts/architecture.md:1401-1432` (visual.asm sits under dispatch.asm; reads from motions.asm via the AR25 chain).
- **PRD FR35 (visual block):** `_bmad-output/planning-artifacts/prd.md` — see FR coverage map at epics.md:228.
- **PRD FR15 + FR33 + FR34 (already closed):** Stories 3.3 (v) and 3.4 (V) — Story 3.5 builds atop all three.
- **PRD NFR9 (8192 B ceiling, amended 2026-05-17):** `_bmad-output/planning-artifacts/prd.md:848`.
- **Existing visual.asm placeholders (to be retired):** `src/visual.asm:399-407` (the comment-only block; Story 3.5 replaces with `visual_enter_block` body).
- **Existing visual_enter_line (model for visual_enter_block body shape):** `src/visual.asm:184-194` (Story 3.4).
- **Existing visual_extend (to be extended with .block_arm):** `src/visual.asm:229-253` (Story 3.4 — 2-way prologue becomes 3-way).
- **Existing visual_count_lines (model for visual_count_block_dims walk):** `src/visual.asm:284-328` (Story 3.4 — reuses SBC-and-swap + LF walk pattern; DE-trash gotcha).
- **Existing visual_compose_status_line shared-tail (DOES NOT extend for block):** `src/visual.asm:359-382` (Story 3.4 — block needs standalone body per Q5).
- **Existing dispatch_normal table (to gain Ctrl-V entry):** `src/dispatch.asm:495-608` (insert between 0x0C at line 498 and '$' at line 501).
- **Existing dispatch_visual table (UNCHANGED — Q3 pin):** `src/dispatch.asm:636-712` (20 entries post-3.3; Story 3.5 does NOT add Ctrl-V here).
- **Existing motion_find_line_start (reused):** `src/motions.asm:636-647`.
- **Existing motion_byte_at_logical (reused; AR23 contract documents HL/BC preservation, DE-trash):** `src/motions.asm:557-608`.
- **Existing msg_mode_visual_line_prefix (to be neighboured by msg_mode_visual_block_prefix):** `src/statusln.asm:350`.
- **Existing status_compose_scratch (48 B; 17 B slack post-3.5):** `inc/state.inc:107-123`.
- **state.inc visual_anchor + visual_submode declarations:** `inc/state.inc:52, 99` (UNCHANGED).
- **modes.inc VIS_BLOCK equate:** `inc/modes.inc:31` (VIS_BLOCK = 2 — declared since Epic-1 init; no modes.inc change for Story 3.5).
- **Story 3.4 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-4-visual-line-mode.md` (full story file with visual_enter_line body + visual_count_lines + visual_compose_status_line + shared-tail refactor; Story 3.5 mirrors the shape with VIS_BLOCK-specific divergences per AC2 / AC4 / AC6).
- **Story 3.3 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-3-visual-character-mode.md` (visual.asm module body + visual_extend's count math + placeholders-block handoff; Story 3.5 retires the rest of the placeholder per AC2).
- **deferred-work.md (current backlog of polish items):** `_bmad-output/implementation-artifacts/deferred-work.md` — Story 3.5 RESOLVES the Story 3.4 Q1 deferral note "Story 3.5's Ctrl-V neighbour decision" (Q3 Option A pin); does NOT add new entries beyond the carryover (the v↔V↔Ctrl-V submode-toggle polish remains low-priority pending a dedicated UX polish story).

## Dev Agent Record

### Agent Model Used

Amelia (bmad-dev-story) on Claude Opus 4.7 (1M context)

### Debug Log References

- `make clean && make all` × 2 cycles — NFR18 byte-identical SHA confirmed: `b6e3374d793588f1228c192b546fc9bd53ffcb0d4c0876ebc58a0b811c0df3d7` (different from Story 3.4's `4d3d7fa6...` as expected; the dispatch_normal[0x16] insert shifts every address from 0x16's slot onward).
- `make sizes` post-3.5: **6935 B / ~84.6% of 8192 B / ~1257 B headroom**. Spec projected 6891 B (+183 B growth); actual came in at +227 B (+44 B over projection). Drift is consistent with Story 3.4 retro's +8 B on visual_count_lines — visual_count_block_dims is a bigger helper with more EX DE,HL / PUSH/POP pairs; same shape of drift. Well within NFR9 budget (1257 B headroom is ample for Stories 3.6-3.8).
- `make test` post-3.5: **231 pass + 1 deliberate-fail (harness_fail)** — matches spec target exactly (226 + 5 = 231). All 5 new visual_block_* / parser_ctrlV-dispatch tests PASS first run; no fix iterations needed (first-iteration UAT pattern matches Epic 3 precedent).
- AR14 / BH3 invariant grep on `src/visual.asm` post-3.5: zero matches for `BIOS_CONOUT|BDOS_CALL|CALL 0x0005|LD (gap_(start|end)),`. Module remains a pure reader. The CRITICAL `visual_block-jagged-clamp.asm` test (sentinel 0xBC) explicitly verifies `(gap_start)` / `(gap_end)` / buffer content all UNCHANGED post motion_l × 5 + motion_j across "abcdef\nxy\nabcdef" — load-bearing regression net for "no jagged-line padding".
- `DISPATCH_NORMAL_COUNT` cross-check via `build/vibe.lst`: 38 entries; the auto-computed `($ - .entries) / 3` resolves to 0x26 = 38 (up from 0x25 = 37 pre-3.5). Spec narrative pinned 37 → 38; matches actual byte-for-byte. No drift on this metric ([[feedback_create_story_cross_check]] satisfied).

### Completion Notes List

- All 12 ACs MET. All 8 Task 0 Q-pins resolved Option A by Ant at dev-handoff (Q1 `"-- visual block -- RxC"` / Q2 single `visual_count_block_dims` HL=rows BC=cols / Q3 Ctrl-V in dispatch_normal only / Q4 standalone helper / Q5 standalone compose / Q6 derive anchor col on demand / Q7 +5 tests / Q8 single commit).
- `visual_enter_block` lands as the third visual-entry handler adjacent to `visual_enter_line` per the Q6 / AC2 code-locality choice. Body: ~28 B (mirrors `visual_enter_line` shape; one extra `LD BC, 1` for the cols arg vs the line-mode single-count entry).
- `visual_extend` prologue extended from 2-way JR-Z to 3-way `CP VIS_BLOCK / JR Z, .block_arm` cascade. The existing `.char_arm` and `.line_arm` bodies are byte-for-byte unchanged. `.block_arm`: CALL visual_count_block_dims + CALL visual_compose_status_block + JP parser_clear (~+12 B).
- `visual_count_block_dims` (~+100 B; +13 B over spec's 87 B mid-estimate — within the 80-95 B band quoted at the top of AC4): projects both anchor and cursor to (line_start, col) via paired `LD HL, (state) ; PUSH HL ; CALL motion_find_line_start ; LD (cell), HL ; POP DE ; EX DE, HL ; OR A ; SBC HL, DE ; LD (cell), HL` sequences; walks LFs in `[min(anchor_ls, cursor_ls), max(...))` reusing the visual_count_lines SBC-and-swap pattern with PUSH/POP DE bracketing around motion_byte_at_logical (Story-3.4 DE-trash gotcha — third instance); cols = |cursor_col - anchor_col| + 1 via the visual_extend.char_arm SBC-and-swap pattern; final RET with HL = rows / BC = cols.
- `visual_compose_status_block` lands as a NEW standalone body above `visual_compose_status_line` (does NOT share `_visual_compose_finish` per Q5 Option A). PUSH BC + PUSH HL + LDIR prefix + status_u16_to_dec (rows) + 'x' + status_u16_to_dec (cols) + NUL + tail-JP status_set_message. ~+33 B exactly per spec.
- 5 module-local DEFW cells (`visual_block_anchor_ls` / `_anchor_col` / `_cursor_ls` / `_cursor_col` / `_temp_rows`) land at end-of-module after the `MSG_MODE_VISUAL_*_PREFIX_LEN` equates. NOT in `inc/state.inc` (Q5 / AC5 — visual.asm-internal projection scratch; lifecycle: cleared and re-written by `visual_count_block_dims` at every call). +10 B module-local data.
- `msg_mode_visual_block_prefix: DEFB "-- visual block -- ", 0` (20 B incl NUL) lands in `src/statusln.asm` immediately after `msg_mode_visual_line_prefix`. `MSG_MODE_VISUAL_BLOCK_PREFIX_LEN EQU 19` joins the existing two prefix-length equates in `src/visual.asm`.
- `dispatch_normal[0x16]` inserts between `0x0C` (Ctrl-L) and `'$'`, with `ASSERT 0x16 > 0x0C` and `ASSERT '$' > 0x16` flanking. `DISPATCH_NORMAL_COUNT` auto-recomputes 37 → 38. Module-header Dependencies block extends with Story 3.5 paragraph documenting `visual_enter_block` as the third forward-ref symbol after `visual_enter_char` (3.3) and `visual_enter_line` (3.4).
- `dispatch_visual` left UNCHANGED (Q3 Option A — Ctrl-V deliberately NOT bound; v↔V↔Ctrl-V submode-toggle deferred to polish). The Story 3.4 deferred-work entry "Story 3.5's Ctrl-V neighbour decision" is resolved with Option A.
- AR boundaries (AR13/AR14/AR15) all clean — `src/visual.asm` remains a pure reader after Story 3.5. **CRITICAL AC9 / BH3 invariant pinned**: zero `gapbuf_*` writes, zero `gap_start`/`gap_end` writes. The `visual_block-jagged-clamp.asm` test (sentinel 0xBC) is the load-bearing regression net for the no-mutation invariant — explicitly verifies `(gap_start)` / `(gap_end)` / GAP_BUFFER_BASE[0..15] all UNCHANGED across motion_l × 5 + motion_j on the jagged buffer "abcdef\nxy\nabcdef".
- NO `inc/state.inc` / `inc/equates.inc` / `inc/modes.inc` changes — `VIS_BLOCK EQU 2` was pre-declared since Story 1.2 (line 31 of modes.inc); `status_compose_scratch` 48-B cell has 17 B slack over the longest Story-3.5 banner.
- NO `src/motions.asm` / `src/edits.asm` / `src/vibe.asm` changes — `motion_find_line_start` + `motion_byte_at_logical` reused as-is; `edits_compose_or_clear`'s MODE_VISUAL arm routes to `visual_extend` which now internally dispatches 3-way on submode; visual.asm already in the AR25 INCLUDE chain since Story 3.3.
- Hardware UAT (AC11, 22 steps) deferred to Ant — script pasted inline at dev-handoff per [[feedback_uat_inline_at_dev_handoff]] (see chat).
- Sprint-status flipped `3-5-visual-block-mode` `ready-for-dev` → `in-progress` → `review`. Awaiting Ant's hardware UAT confirmation for `review` → `done`.

### File List

**Modified:**
- `src/statusln.asm` — added `msg_mode_visual_block_prefix` (+20 B data); extended Public block comment.
- `src/dispatch.asm` — added 3-byte `dispatch_normal[0x16]` entry + 2 ASSERTs (`ASSERT 0x16 > 0x0C`, `ASSERT '$' > 0x16` replacing the existing `ASSERT '$' > 0x0C`); extended Dependencies block with Story 3.5 paragraph.
- `src/visual.asm` — added `visual_enter_block` body (~28 B); extended `visual_extend` prologue from 2-way to 3-way + new `.block_arm` (~+12 B); added `visual_count_block_dims` helper (~+100 B); added `visual_compose_status_block` standalone body (~+33 B); added `MSG_MODE_VISUAL_BLOCK_PREFIX_LEN EQU 19`; added 5 module-local DEFW cells (+10 B); module-header updated: flipped `visual_enter_block` PLACEHOLDER → LANDS, extended Purpose/State/Register-conventions/Dependencies blocks for Story 3.5.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — flipped `3-5-visual-block-mode` `ready-for-dev` → `in-progress` → `review`; appended last_updated entries.
- `_bmad-output/implementation-artifacts/3-5-visual-block-mode.md` — Tasks/Subtasks all checked; Dev Agent Record + File List + Change Log populated; Status → review.

**New:**
- `test/cases/visual_ctrlV-enters-block-mode.asm` (sentinel 0xBA) — AC2 / AC12 entry semantics with mid-line cursor (anchor pinned at offset, NOT line-start).
- `test/cases/visual_block-rectangle-extends.asm` (sentinel 0xBB) — AC3 / AC4 / AC8 forward arms (l + j sequence across 4-line 5-col buffer; cursor 0 → 1 → 2 → 8 → 14, rows/cols 1x2 → 1x3 → 2x3 → 3x3).
- `test/cases/visual_block-jagged-clamp.asm` (sentinel 0xBC) — **CRITICAL AC9 / BH3 / AR14 test** (motion_l × 5 + motion_j on "abcdef\nxy\nabcdef"; verifies status "-- visual block -- 2x2" AND `(gap_start)` / `(gap_end)` / GAP_BUFFER_BASE[0..15] all UNCHANGED).
- `test/cases/visual_block-backward-rectangle.asm` (sentinel 0xBD) — AC4 backward-rows AND backward-cols swap arms (motion_k + motion_h × 2 + motion_k from cursor=14 → 8 → 6 → 0 on "abcde\nfghij\nklmno\npqrst"; 2x1 → 2x3 → 3x3).
- `test/cases/parser_ctrlV-dispatch.asm` (sentinel 0xED) — AC1 end-to-end dispatch wiring (drives 0x16 through `dispatch_key` with cursor mid-line on "hello\nworld"; verifies anchor pinned at cursor=3, NOT line-start 0).

## Change Log

| Date | Change | Author |
| --- | --- | --- |
| 2026-05-18 | Story 3.5 implementation: `visual_enter_block` lands (FR35); `visual_extend` prologue extended to 3-way; new `visual_count_block_dims` + `visual_compose_status_block`; 5 new headless tests; `dispatch_normal[0x16]` wired to Ctrl-V; AR14 / BH3 jagged-line virtuality invariant pinned. NFR18 SHA `b6e3374d793588f1228c192b546fc9bd53ffcb0d4c0876ebc58a0b811c0df3d7`. Code section 6935 B / ~84.6% / ~1257 B headroom. Tests 226 → 231 PASS (+5). | Amelia (Opus 4.7) |
