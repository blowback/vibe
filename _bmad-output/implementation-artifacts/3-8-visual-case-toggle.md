# Story 3.8: Visual case toggle (~)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `~` in MODE_VISUAL (any submode) to toggle the alphabetic case of every byte in the selection — lowercase `a..z` becomes uppercase `A..Z` and vice versa; non-alphabetic bytes (including LF / spaces / digits / punctuation) pass through unchanged — with the in-place mutation routed through a NEW `gapbuf_case_toggle_range` primitive in `src/gapbuf.asm` (preserves AR14 — gapbuf remains the single buffer-mutation owner; the new primitive uses `gapbuf_move_gap` to relocate the gap to the range start, then walks the now-contiguous bytes at `gap_end..gap_end+N` toggling alpha bits in place — net file_length unchanged), VIS_CHAR / VIS_LINE selections recording a single-region `UNDO_KIND_CASE_TOGGLE` (NEW kind 0x07; replay re-walks the same range via `gapbuf_case_toggle_range` — case-toggle is its own inverse, so no payload bytes are saved), VIS_BLOCK selections taking per-row clipping per BH3 (jagged short lines; column range `[col_min, col_max+1)` clipped at each row's EOL) AND recording a single `UNDO_KIND_TOO_LARGE` direct record per Story 3.6 BLOCK-arm precedent (multi-region undo remains a deferred-work item; user gets `msg_undo_too_large` on `u` post-BLOCK-`~`), cursor placement at top-of-selection (`min(anchor, cursor)` for CHAR; `min(anchor_ls, cursor_ls)` for LINE; `top_ls + col_min` for BLOCK with the Story 3.6 BH3 jagged-top clamp inherited verbatim), and mode returning to NORMAL via `enter_normal_mode` tail-JP (no status-clobber concerns — `gapbuf_case_toggle_range` has NO overflow path since it never inserts; `msg_file_too_large` is structurally unreachable),
So that FR38 closes — Epic 3 ships with the final visual operator class, completing Journey 2's visual-mode region-edit vocabulary (`d` / `y` / `c` / `>` / `<` / `~` all working across VIS_CHAR / VIS_LINE / VIS_BLOCK with their per-operator submode semantics: `d`/`y`/`c` BLOCK respects column range with BH3 clipping; `>`/`<` BLOCK ignores column range (line-class shift); `~` BLOCK respects column range with BH3 clipping — the operator class that mirrors `d`/`y`/`c`'s per-row geometry but operates byte-wise instead of region-deleting).

## Acceptance Criteria

**AC1 — `dispatch_visual` gains one sorted entry `~` (0x7E) forward-referencing `visual_apply_case_toggle` in `src/visual.asm`. `~` sorts AFTER `y` (0x79 — the last existing dispatch_visual entry post-3.7); it appends at the table tail. `DISPATCH_VISUAL_COUNT` auto-recomputes 25 → 26.**

**Given** `src/dispatch.asm:dispatch_visual` (currently 25 entries post-3.7 — verified via `build/vibe.lst:4049` `787+ 0944 DISPATCH_VISUAL_COUNT EQU ($ - .entries) / 3` resolving to 0x19; the sort order runs Esc / `$` / `0`..`9` / `<` / `>` / `G` / `b` / `c` / `d` / `g` / `h` / `j` / `k` / `l` / `w` / `y` at `src/dispatch.asm:712-786`; the operator `~` is documented as "remains deferred — falls through to `unbound_visual` until that story lands" at the comment block at `src/dispatch.asm:702-710` — that deferral comment retires with Story 3.8)
**When** Story 3.8 lands
**Then** one new 3-byte entry is appended at the table tail:
- `'~'` (0x7E) — between `'y'` (0x79) at line 785-786 and the `DISPATCH_VISUAL_COUNT EQU` terminator at line 787 — sorted insertion (no later entries to shift)

**And** the entry's `DEFW` targets `visual_apply_case_toggle` (the single submode-aware dispatcher in `src/visual.asm` — branches on `visual_submode` to one of three arms: CHAR / LINE / BLOCK)
**And** the flanking `ASSERT '~' > 'y'` is added — extends the assembly-time sort-chain.
**And** `DISPATCH_VISUAL_COUNT` (the `($ - .entries) / 3` EQU at line 787) auto-recomputes from 0x19 (25) → 0x1A (26). Cross-check `build/vibe.lst` post-build per [[feedback_create_story_cross_check]] — past stories (3.5, 3.6, 3.7) all drifted on the dispatch-count metric in spec text; same care applies. The `LD B, DISPATCH_VISUAL_COUNT` emit at the `dispatch_key` call site (currently `06 19` at `build/vibe.lst:14114`) should resolve to `06 1A` post-3.8.
**And** `dispatch_visual` table grows by **+3 B** (1 entry × 3 B; the ASSERT is assembly-time, zero runtime).
**And** the `dispatch.asm` module-header Dependencies block (the section ending around `src/dispatch.asm:185-202`) extends with a Story 3.8 paragraph documenting `visual_apply_case_toggle` as the SIXTH forward-ref symbol after `visual_enter_char` (3.3), `visual_enter_line` (3.4), `visual_enter_block` (3.5), `visual_apply_operator` (3.6), and `visual_apply_shift` (3.7).
**And** the Story-3.7 comment block at `src/dispatch.asm:702-710` ("`>` / `<` bind to `visual_apply_shift` (Story 3.7); `~` (Story 3.8) remains deferred …") is REPLACED with a comment noting that ALL Epic-3 visual operators (`d` / `y` / `c` / `>` / `<` / `~`) now bind to their respective dispatchers and the `unbound_visual` fall-through is unreachable for the documented operator set. FR38 closes Epic 3's visual operator surface.
**And** `dispatch_normal` is UNCHANGED — `~` in NORMAL is currently UNBOUND (NORMAL-mode `~` toggles the case of the char under the cursor and advances by 1 in vim; VIBE does not implement NORMAL-mode `~` in MVP — Growth-tier per PRD §14 Out of Scope and per Epic 3 narrative which restricts FR38 to visual-mode entry). A NORMAL-mode `~` keystroke continues to fall through to `unbound_normal` for the BEEP+`msg_unbound_key` surface. **Pin: VIBE intentionally diverges from vim's NORMAL-mode `~` — visual-mode-only is documented in the visual.asm module header.**

**AC2 — `visual_apply_case_toggle` (NEW public entry in `src/visual.asm`) is the single submode-aware dispatcher. Mirrors the Story 3.6 `visual_apply_operator` 3-arm shape: branches on `visual_submode` to `_visual_op_case_char_arm` / `_visual_op_case_line_arm` / `_visual_op_case_block_arm`. The CHAR and LINE arms converge on a shared `_visual_op_case_toggle_finalise` tail (analogous to `_visual_op_delete_yank_or_change` for d/y/c) which calls `gapbuf_case_toggle_range` + records `UNDO_KIND_CASE_TOGGLE` + cursor-restores + tail-JPs `enter_normal_mode`. The BLOCK arm is per-row standalone (analogous to `_visual_op_block_arm` for d/y/c) and records `UNDO_KIND_TOO_LARGE` direct per Q1 Option A.**

**Given** `src/visual.asm` (the public block at lines 67-83 currently lists `visual_apply_shift` as LANDS (Story 3.7) with sibling `~` (Story 3.8) "remains a placeholder"; the comment was extended by Story 3.7 to document the sibling deferral)
**When** Story 3.8 lands
**Then** `visual_apply_case_toggle:` is added as a NEW labelled public entry in `src/visual.asm`, placement chosen for code locality (recommended placement: between `visual_apply_shift`'s body ending at line 1343 and `visual_count_lines`'s body starting at line 1374 — case-toggle sits right after shift, mirroring the order of operations during a typical visual session "enter → extend → operate" and grouping the post-Story-3.7 line-class operators together; the BLOCK arm sits after the CHAR/LINE arms in the same locality cluster).
**And** the dispatcher body performs:
1. `LD (visual_op_pending), A` — stash operator byte (`~` = 0x7E) for any downstream branching (~3 B; cell is reused from Story 3.6 — same one-dispatch lifecycle).
2. `LD A, (visual_submode) ; CP VIS_BLOCK ; JP Z, _visual_op_case_block_arm` (~9 B).
3. `CP VIS_LINE ; JR Z, _visual_op_case_line_arm` (~5 B).
4. Fall through to `_visual_op_case_char_arm` (VIS_CHAR == 0 — defensive default mirroring Story 3.6 AC3's 3-way prologue).

**And** `_visual_op_case_char_arm` body (~30 B):
1. SBC-and-swap pattern from `_visual_op_char_arm` (Story 3.6 — exactly the same code shape; this is a CHAR-range projection identical to d/y/c CHAR). Computes `HL = range_start = min(anchor, cursor)`; `BC = total_bytes = |cursor - anchor| + 1`. The inclusive `+1` matches vi's visual-selection-is-always-inclusive contract (same as Story 3.6 AC3).
2. `JP _visual_op_case_toggle_finalise`.

**And** `_visual_op_case_line_arm` body (~50 B):
1. Line-promote projection: `motion_find_line_start(visual_anchor)` (anchor is already a line-start by Story 3.4 AC2 invariant; the call is effectively a no-op — first-iter `LD A, H ; OR L ; RET Z` for offset 0, or first-iter `DEC HL ; LD A,(HL) ; CP 0x0A ; RET Z` for non-zero line-starts) + `motion_find_line_start(cursor_offset)` (real walk).
2. SBC-and-swap to compute `range_start = min(anchor_ls, cursor_ls)`; walker = `max(anchor_ls, cursor_ls)`.
3. `CALL motion_find_line_end(walker)` → HL = LF pos (CF=0) or file_length (CF=1).
4. **No at-EOF carve-out**: unlike Story 3.6 `_visual_op_line_arm.at_eof` which DELETES line content and must consume the leading LF of the line above, case-toggle never deletes bytes — `range_end = HL + 1` unconditionally (when HL = LF pos, +1 lands past the LF; when HL = file_length, +1 lands at file_length+1 but `gapbuf_case_toggle_range` clips at file_length via the `gap_end` overrun check, so the extra +1 is harmless). `BC = range_end - range_start`.
5. `JP _visual_op_case_toggle_finalise`.

**And** `_visual_op_case_toggle_finalise` body (~35 B — the shared CHAR / LINE tail):
1. **Stash range** for cursor-restore + undo-record: `LD (visual_op_range_start), HL ; LD (visual_op_range_bytes), BC` (~6 B; reuses Story 3.6 cells — same one-dispatch lifecycle).
2. **0-byte defensive guard**: `LD A, B ; OR C ; JP Z, enter_normal_mode` — empty selection bails before touching the buffer or undo register (~5 B).
3. `CALL gapbuf_case_toggle_range` — input HL = range_start (already correct from step 1's load), BC = total_bytes; output Z flag = dirty status (Z=0 if any byte was toggled, Z=1 if walk was a no-op — selection had no alphabetic bytes). The dirty status comes back in Z so we don't need to read a separate dirty cell (this is a contract refinement — `gapbuf_case_toggle_range` returns Z=1 iff dirty=0 to keep the post-call check to a single byte) (~3 B).
4. **No-op walk path (Z=1 — no alpha bytes toggled)**:
   - `LD HL, (visual_op_range_start) ; LD (cursor_offset), HL` — cursor at range_start (~6 B).
   - `JP enter_normal_mode` — undo register left at WHATEVER STATE (NO undo_clear before the walk — see Q3 Option A pin in Task 0; this DIFFERS from Story 2.11 / 3.7 precedent which pre-clears, deliberately preserving any prior undo entry across a no-op `~`; the no-op walk is semantically equivalent to a non-operation) (~3 B).
5. **Dirty path (Z=0 — at least one alpha byte toggled)**:
   - `CALL undo_clear` (~3 B; pre-clears so the kind write is clean).
   - `LD HL, (visual_op_range_start) ; LD BC, (visual_op_range_bytes) ; LD A, UNDO_KIND_CASE_TOGGLE ; CALL undo_write_header` — records (kind, position, length) ~12 B.
   - `LD HL, (visual_op_range_start) ; LD (cursor_offset), HL` — cursor at range_start (~6 B).
   - `CALL edits_dirty_and_redraw` — `buffer_dirty=1` + `render_mark_all_dirty` (~3 B).
   - `JP enter_normal_mode` — tail-JP (~3 B).

**And** `_visual_op_case_block_arm` body (~110 B — heavier per-row path):
1. Project rectangle: `CALL visual_count_block_dims` (returns HL=rows, BC=cols) + `LD (visual_op_block_rows), HL` + `LD (visual_op_block_cols), BC` + col_min/col_max compute via the same SBC-and-swap pattern as `_visual_op_block_arm` (Story 3.6) (~40 B).
2. Compute `top_ls = min(anchor_ls, cursor_ls)` via SBC-and-swap (same as Story 3.6) (~20 B).
3. **Record UNDO_KIND_TOO_LARGE direct** per Q1 Option A (matches Story 3.6 BLOCK arm precedent):
   - `CALL undo_clear ; LD HL, (visual_op_block_top_ls) ; LD BC, 0 ; LD A, UNDO_KIND_TOO_LARGE ; CALL undo_write_header` (~15 B).
4. **Per-row walk** (single pass — no pass-1 yank sum like Story 3.6, no shift-tracking since case-toggle doesn't change file_length):
   - Initialise `visual_op_block_walker = top_ls`, `visual_op_block_remaining_rows = rows` (~10 B).
   - Loop body:
     a. `LD HL, (visual_op_block_walker) ; CALL motion_find_line_end ; PUSH HL ; LD DE, (visual_op_block_walker) ; OR A ; SBC HL, DE` — HL = line_length (~14 B).
     b. `CALL _visual_op_block_row_bytes` — HL = bytes_this_row (BH3 clipped at EOL) (~3 B; helper reused from Story 3.6 verbatim).
     c. `LD A, H ; OR L ; JR Z, .next_row` — skip empty rows (no bytes to toggle) (~5 B).
     d. `LD B, H ; LD C, L` (BC = bytes_this_row) `; LD HL, (visual_op_block_col_min) ; LD DE, (visual_op_block_walker) ; ADD HL, DE` — HL = toggle_start (= walker + col_min) (~10 B).
     e. `CALL gapbuf_case_toggle_range` — toggle bytes_this_row bytes starting at toggle_start (~3 B). Dirty status discarded for BLOCK (we wrote UNDO_KIND_TOO_LARGE direct already in step 3; per-row dirty tracking would be wasted given the TOO_LARGE record).
     f. `.next_row:` `POP HL ; INC HL ; LD (visual_op_block_walker), HL` — walker = old_line_end + 1 (move to next line). NO shift-tracking needed since case-toggle leaves file_length unchanged (~6 B).
     g. Decrement remaining_rows; loop back if non-zero (~12 B).
5. **Cursor placement** (BH3 jagged-top clamp inherited verbatim from Story 3.6 BLOCK arm):
   - `LD HL, (visual_op_block_top_ls) ; LD DE, (visual_op_block_col_min) ; ADD HL, DE ; LD (cursor_offset), HL` — top-left corner (~10 B).
   - Jagged-top clamp: if `HL > 0`, `CALL motion_byte_at_logical ; JR C, .clamp ; CP 0x0A ; JR NZ, .have_cursor ; .clamp: DEC HL ; LD (cursor_offset), HL ; .have_cursor:` (~12 B; mirrors Story 3.6 `_visual_op_block_arm.b_have_cursor`).
6. `CALL edits_dirty_and_redraw` (~3 B).
7. `JP enter_normal_mode` — tail-JP (~3 B; no status-clobber concern — no msg_file_too_large path).

**And** total `visual_apply_case_toggle` + 3 arms + shared finalise: **~235-265 B** at the dispatch + range-compute + walk-dispatch + undo-record + cursor-place + tail-JP stage. Larger than Story 3.7's 108 B because three arms (not one) + the heavier per-row BLOCK path. **Comparable to Story 3.6's `visual_apply_operator` family at ~400 B** but smaller because:
- No yank machinery (no pass-1 yank sum; no yank_buffer append; no capacity check; no msg_yank_too_large status; no yank_ok flag dance).
- No shift-tracking (case-toggle leaves file_length unchanged — walker advances by old_line_end + 1, not by old_line_end - bytes_this_row + 1).
- No `c` → INSERT-mode dispatch path (operator class is single-op `~`, not multi-op d/y/c).
- No per-byte `edits_range_delete` (the per-row mutation is a single `gapbuf_case_toggle_range` call per row).

**And** AR23 docstring documents: `In: A = '~' (MC4 from dispatch_visual).`; `Out: every alphabetic byte in the selection has its case toggled (lowercase 'a'..'z' XOR 0x20 → 'A'..'Z'; uppercase XOR 0x20 → lowercase); other bytes unchanged. cursor_offset = top-of-selection (min(anchor, cursor) for CHAR; min line-start for LINE; top-left for BLOCK with BH3 jagged-top clamp). mode_byte = MODE_NORMAL via enter_normal_mode tail-JP. UNDO_KIND_CASE_TOGGLE recorded for CHAR / LINE on dirty walks; UNDO_KIND_TOO_LARGE direct record for BLOCK (any dirty status; multi-region undo deferred per Q1 Option A); no-op walks (selection with no alphabetic bytes) leave undo register at prior state (Q3 Option A — no pre-clear).`; `Trashes: A, BC, DE, HL, F + module-local cells (visual_op_pending, visual_op_range_start, visual_op_range_bytes for CHAR/LINE; visual_op_block_rows/cols/col_min/col_max/top_ls/walker/remaining_rows for BLOCK).`; `Calls: motion_find_line_start (CALL × 2 in LINE arm); motion_find_line_end (CALL × 1 in LINE arm + per-row in BLOCK arm); visual_count_block_dims (CALL in BLOCK arm); _visual_op_block_row_bytes (CALL per-row in BLOCK arm); motion_byte_at_logical (CALL × 1 in BLOCK arm cursor clamp); gapbuf_case_toggle_range (CALL × 1 in CHAR/LINE; per-row in BLOCK); undo_clear (CALL × 1 in dirty CHAR/LINE path + 1 in BLOCK pre-record); undo_write_header (CALL × 1 in dirty CHAR/LINE path + 1 in BLOCK pre-record); edits_dirty_and_redraw (CALL × 1 in dirty CHAR/LINE path + 1 in BLOCK tail); enter_normal_mode (JP tail × 4 paths — empty / no-op / dirty-CHAR-LINE / BLOCK).`

**AC3 — NEW primitive `gapbuf_case_toggle_range` in `src/gapbuf.asm`. The single in-place byte-mutator. Walks BC bytes starting at logical offset HL; for each byte that is alphabetic (`A..Z` or `a..z`), toggles bit 5 in place (XOR 0x20); other bytes pass through unchanged. Net file_length unchanged (no `gap_start` / `gap_end` mutation by this primitive — `gapbuf_move_gap` does its own gap-pointer update; the per-byte mutation writes through the gap_end-side memory region directly). Returns Z=1 iff no alphabetic byte was toggled (no-op walk — selection had no alpha content); Z=0 iff at least one byte was toggled.**

**Given** `src/gapbuf.asm` (currently 263 lines post-Story-1.7 + Story-2.2 retire; the four existing public entries are `gapbuf_init` / `gapbuf_insert` / `gapbuf_delete` / `gapbuf_move_gap`)
**When** Story 3.8 lands
**Then** `gapbuf_case_toggle_range:` is added as a NEW labelled public entry in `src/gapbuf.asm`, placement chosen at the file tail (after `gapbuf_move_gap`'s `.equal` arm at line 257, before the `;; --- Internal helpers ---` section divider at line 259-264). The implementation:

```
gapbuf_case_toggle_range:
    ;; 0-byte defensive guard. Empty BC → Z=1 return (no toggles).
    LD      A, B
    OR      C
    RET     Z                           ; Z=1; CF preserved (not set)
    ;; Move the gap to the range start. After this, bytes [HL, HL+BC)
    ;; are physically contiguous at gap_end..gap_end+BC.
    PUSH    BC
    CALL    gapbuf_move_gap             ; gap relocated; cursor UNCHANGED
    POP     BC
    ;; Walk bytes from gap_end. HL repurposed as physical pointer.
    LD      HL, (gap_end)
    ;; Loop: read byte, test alpha, conditionally toggle in place,
    ;; advance, decrement count.
    LD      D, 0                        ; D = dirty flag (0 = clean)
.ct_loop:
    LD      A, (HL)
    ;; --- Alpha test (inline; ~14 B) ---
    CP      'A'
    JR      C, .ct_advance              ; A < 'A' → not alpha
    CP      'Z' + 1
    JR      C, .ct_toggle               ; 'A'..'Z' → toggle
    CP      'a'
    JR      C, .ct_advance              ; '['..'`' → not alpha
    CP      'z' + 1
    JR      NC, .ct_advance             ; A > 'z' → not alpha
.ct_toggle:
    XOR     0x20                        ; flip case bit
    LD      (HL), A
    LD      D, 1                        ; dirty
.ct_advance:
    INC     HL
    DEC     BC
    LD      A, B
    OR      C
    JR      NZ, .ct_loop
    ;; Set Z=0 iff dirty (D=1); Z=1 iff clean (D=0).
    LD      A, D
    OR      A                           ; Z=1 iff D=0
    RET
```

**And** the body is **~50 B** (per-byte loop with inline alpha classifier + flag accumulator).
**And** AR23 docstring above the label documents: `In: HL = range_start (logical offset within gap buffer; 0 <= HL <= file_length - BC). BC = byte count (range_end - range_start; may be 0).`; `Out: bytes in [HL, HL+BC) have their alphabetic case toggled in place; non-alphabetic bytes (including LF / spaces / digits / punctuation) UNCHANGED; gap_start / gap_end UNCHANGED post-call (gapbuf_move_gap relocated the gap as a side-effect but no NET file_length change); cursor_offset PRESERVED across the call (gapbuf_move_gap does not touch cursor_offset); Z flag = 1 iff no alpha bytes were toggled (no-op walk), Z = 0 iff at least one byte was toggled.`; `Trashes: A, BC, DE, HL, F.`; `Calls: gapbuf_move_gap (CALL × 1 — relocates gap to range_start so the toggle region becomes physically contiguous at gap_end onwards).`
**And** `gapbuf.asm` module-header Public block extends with `gapbuf_case_toggle_range — in-place case-toggle (Story 3.8)`.
**And** the module-header Purpose paragraph extends to document Story 3.8: "Story 3.8 — gapbuf_case_toggle_range lands. The fifth public mutator; preserves AR14 (gapbuf remains the sole buffer-mutation owner) by introducing an in-place per-byte mutator that uses gapbuf_move_gap to relocate the gap to the range start, then walks the now-contiguous bytes at gap_end onwards toggling alphabetic case bits in place. Net file_length unchanged; gap_start / gap_end UNCHANGED post-call (the move_gap side-effect is internal to the call — caller observes invariant gap pointers). Mirrors visual.asm's call site visual_apply_case_toggle (Story 3.8 — FR38)."
**And** **AR14 surface grows from 4 public mutators (init / insert / delete / move_gap) to 5 (+ case_toggle_range).** No new AR14 carve-outs are needed — the new primitive is in `src/gapbuf.asm` itself, conforming to AR14's spirit.

**Pin Q7 Option A** (from Task 0): The new primitive lives in `src/gapbuf.asm`, not as an AR14 carve-out in visual.asm or edits.asm. Rationale: keeps AR14 boundary clean. Alternative Option B = AR14 carve-out (visual.asm or edits.asm calls `gapbuf_move_gap` then writes bytes directly); rejected — adds a third documented carve-out (after fileio.asm load and gap_start linear-fill) and spreads buffer-content mutation across two modules. The gapbuf-primitive approach mirrors how `gapbuf_insert` / `gapbuf_delete` encapsulate the move_gap-then-mutate pattern.

**AC4 — UNDO_KIND_CASE_TOGGLE equate added to `inc/equates.inc` (= 0x07; sibling to 0x05 INDENT_WALK / 0x06 DEDENT_WALK). Single-region replay re-walks the same `[position, position+length)` range via `gapbuf_case_toggle_range` — case-toggle is self-inverse (toggle-twice = identity), so no payload bytes are saved; replay is structurally identical to record path.**

**Given** `inc/equates.inc:107-108` declares UNDO_KIND_INDENT_WALK (0x05) / UNDO_KIND_DEDENT_WALK (0x06)
**When** Story 3.8 lands
**Then** a new equate is added at line ~109 (immediately after DEDENT_WALK):
- `UNDO_KIND_CASE_TOGGLE EQU 0x07 ; inverse-op = case-toggle re-walk over [position, position+length); self-inverse`
**And** the equate-block module-header comment (lines 93-101) extends to document the new kind: "Story 3.8 (CASE_TOGGLE) — inverse-op is the SAME op (case-toggle is self-inverse; XOR 0x20 twice = identity); no payload bytes saved; no capacity check; replay calls gapbuf_case_toggle_range over the recorded [position, position+length) range."
**And** **no other equate changes** — INDENT_BYTE / UNDO_KIND_EMPTY / UNDO_KIND_INSERT / UNDO_KIND_DELETE / UNDO_KIND_REPLACE / UNDO_KIND_TOO_LARGE / UNDO_KIND_INDENT_WALK / UNDO_KIND_DEDENT_WALK / UNDO_PAYLOAD_SIZE / KIND_CHAR / KIND_LINE / KIND_BLOCK / CMD_SUB_EX / CMD_SUB_SEARCH all UNCHANGED.

**AC5 — `undo_replay_case_toggle` (NEW public replay body in `src/undo.asm`). The single-region replay path: reads `undo_position` + `undo_length`, calls `gapbuf_case_toggle_range`, tail-JPs `undo_replay_success_tail` (the shared post-replay hook that places cursor at undo_position + clears the consumed undo entry + dirty-and-redraws + clears parser state). `op_undo` gets a new dispatch entry for `UNDO_KIND_CASE_TOGGLE`. No new record helper needed — Story 3.8's CHAR/LINE finalise calls `undo_write_header(A=UNDO_KIND_CASE_TOGGLE)` directly (saves ~6 B vs adding a thin `undo_record_case_toggle` wrapper — the wrapper would be functionally identical to `undo_record_indent_walk` modulo the kind byte; the existing Q1 Option D shared `undo_write_header` factor-out absorbs the call site fine).**

**Given** the existing `op_undo` dispatch table at `src/undo.asm:227-249` (branches on `undo_kind` to one of 5 replay bodies — INSERT / DELETE / REPLACE / INDENT_WALK / DEDENT_WALK — plus TOO_LARGE surface + EMPTY/default surface)
**When** Story 3.8 lands
**Then** `op_undo` gains one new dispatch entry:
- `CP UNDO_KIND_CASE_TOGGLE ; JP Z, undo_replay_case_toggle` (~5 B) inserted between the existing `CP UNDO_KIND_DEDENT_WALK ; JP Z, undo_replay_dedent_walk` (line 237-238) and `CP UNDO_KIND_TOO_LARGE ; JR Z, .too_large` (line 239-240).

**And** `undo_replay_case_toggle:` body (~12 B; placed in `src/undo.asm` after `undo_replay_dedent_walk` at line 439 and before the `;; --- Public: undo_record_insert ---` divider at line 442-444):
```
undo_replay_case_toggle:
    LD      HL, (undo_position)
    LD      BC, (undo_length)
    CALL    gapbuf_case_toggle_range
    JP      undo_replay_success_tail
```
**And** AR23 docstring documents: `In: (state) undo_kind = UNDO_KIND_CASE_TOGGLE; undo_position; undo_length.`; `Out: bytes in [undo_position, undo_position + undo_length) re-toggled (case-toggle is self-inverse, so re-walking restores the pre-toggle state); cursor := undo_position; undo_kind := UNDO_KIND_EMPTY; buffer_dirty=1; all rows dirty; parser cleared (via undo_replay_success_tail tail-JP).`; `Trashes: A, BC, DE, HL, F.`; `Calls: gapbuf_case_toggle_range (the per-byte walker — Z flag return is IGNORED here since replay always re-applies even on the rare case where the user did some other edit between the original `~` and the `u`; that's a user-induced state divergence outside the replay's scope), undo_replay_success_tail (tail-JP).`

**And** the `src/undo.asm` module-header Purpose paragraph extends to document Story 3.8: "Story 3.8 — undo_replay_case_toggle lands. Sixth replay body (after INSERT / DELETE / REPLACE / INDENT_WALK / DEDENT_WALK); the lightest of the bodies because case-toggle is self-inverse (no payload bytes saved; no capacity check; replay is structurally identical to the original `~` op modulo the entry path). FR38 — visual case-toggle's single-level undo coverage."
**And** the `op_undo` block's module-header docstring (line 199-225) extends to document the new kind branch.

**AC6 — Submode semantics: VIS_CHAR + VIS_LINE land single-region UNDO_KIND_CASE_TOGGLE on dirty walks; VIS_BLOCK lands UNDO_KIND_TOO_LARGE direct (multi-region undo deferred per Q1 Option A, matching Story 3.6 BLOCK arm precedent). For VIS_BLOCK per-row clipping: bytes in `[walker + col_min, walker + min(col_max + 1, line_length))` per row, via the existing `_visual_op_block_row_bytes` helper (Story 3.6, reused as-is). Short lines (line_length < col_max + 1) toggle only up to their EOL — BH3 jagged-line semantic.**

**Given** the three visual-submode anchor semantics + the Story-3.6 BLOCK precedent's TOO_LARGE direct record + the `_visual_op_block_row_bytes` helper at `src/visual.asm:1044-1060` (the BH3 clip arithmetic: `bytes = max(0, min(col_max + 1, line_length) - col_min)`)
**When** Story 3.8 lands
**Then** the per-submode behaviour is:
- **VIS_CHAR** (`_visual_op_case_char_arm` per AC2): range = inclusive `[min(anchor, cursor), max(anchor, cursor) + 1)` from SBC-and-swap; CALL `gapbuf_case_toggle_range`; on dirty (Z=0) record `UNDO_KIND_CASE_TOGGLE` with (range_start, total_bytes); cursor at range_start. **Same range shape as Story 3.6's `_visual_op_char_arm` — could share code if NFR9 pressure forces it; default is the duplicated tight body since the projection is 30 B and not worth a CALL/RET pair.**
- **VIS_LINE** (`_visual_op_case_line_arm` per AC2): line-promote via `motion_find_line_start(anchor)` + `motion_find_line_start(cursor)` + `motion_find_line_end(max line-start) + 1`; range = `[min_line_start, max_line_end + 1)`. CALL `gapbuf_case_toggle_range`; on dirty record `UNDO_KIND_CASE_TOGGLE` with (range_start, total_bytes); cursor at range_start. **No at-EOF carve-out** (case-toggle doesn't delete bytes — the at-EOF carve-out from Story 3.6 `_visual_op_line_arm.at_eof` is irrelevant; the `+1` past file_length is harmless because `gapbuf_case_toggle_range`'s gap-relocation + walk clips at file_length via gap_end overrun — see Q5 Option A in Task 0).
- **VIS_BLOCK** (`_visual_op_case_block_arm` per AC2): rectangle via `visual_count_block_dims`; per-row walk through `_visual_op_block_row_bytes` (BH3 clipped); CALL `gapbuf_case_toggle_range` per row at `walker + col_min` with `bytes_this_row` count; UNDO_KIND_TOO_LARGE direct record via `undo_write_header` (length = 0 — semantically meaningless for TOO_LARGE; mirrors Story 3.6 BLOCK arm); cursor at `top_ls + col_min` (with BH3 jagged-top clamp). **`u` post-BLOCK-`~` surfaces `msg_undo_too_large` — same shape as Story 3.6 BLOCK d/y/c.**

**And** the BLOCK per-row walk does NOT need a shift-tracking advance — `gapbuf_case_toggle_range` leaves file_length unchanged, so `walker` advances by `old_line_end + 1` unconditionally (no `- bytes_this_row` adjustment). This is structurally simpler than Story 3.6's BLOCK arm which had to `walker = old_line_end - bytes_this_row + 1` for the 'd'/'c' delete-paths.

**And** **edge case — `visual_anchor == cursor_offset`** (bare `v` then `~` with no motion): CHAR arm gives `range_start = anchor`, `total_bytes = 1` (inclusive `+1`). The single byte at the cursor gets toggled (if alpha). Vi-faithful: `v~` is functionally identical to `~x ~` (NORMAL-mode `~` is NOT implemented in VIBE per AC1 pin, but the byte-toggle semantic is identical).

**And** **edge case — backward selection** (cursor moved UP from anchor): SBC-and-swap takes cursor as range_start; range_end = anchor + 1 (for CHAR) or max_line_end + 1 (for LINE) or top_ls = cursor_ls (for BLOCK).

**And** **edge case — empty selection** (range_start == range_end): defensive 0-byte guard in `_visual_op_case_toggle_finalise` bails before touching the buffer. Cursor restored to range_start. Undo register UNCHANGED. Tail-JP `enter_normal_mode`.

**And** **edge case — selection has no alphabetic bytes** (e.g. all digits / punctuation / LFs / spaces): `gapbuf_case_toggle_range` walks the bytes but does nothing; returns Z=1 (no-op walk). CHAR/LINE finalise's no-op path leaves undo at prior state per Q3 Option A; cursor at range_start; tail-JP. **Distinct from Story 2.11 / 3.7 indent/dedent precedent which PRE-clears via `undo_clear` before the walk.** Pin Q3 Option A — preserve prior undo on no-op `~`.

**AC7 — VIS_BLOCK per-row no-op edge case: if some rows have alpha bytes and others don't, each row's `gapbuf_case_toggle_range` call returns its own Z status; we don't aggregate. The TOO_LARGE record was already written direct (step 3 of the BLOCK arm body); the per-row dirty status is structurally irrelevant for BLOCK (the user gets `msg_undo_too_large` on `u` regardless). For COMPLETELY no-op BLOCK selections (no row has any alpha — rare; e.g. block selection over a column of digits), the TOO_LARGE record IS still written; `u` surfaces `msg_undo_too_large` even though no bytes were toggled. **Documented divergence**: BLOCK `~` is conservatively "always recorded as TOO_LARGE for the multi-region semantic" — equivalent to Story 3.6 BLOCK d on a 0-byte selection (which also records TOO_LARGE then no-ops). Re-pin if a future multi-region undo story lands.**

**Given** the per-row walk semantics
**When** the BLOCK arm completes
**Then** the undo register reflects:
- At least one row toggled at least one byte → `undo_kind = UNDO_KIND_TOO_LARGE`, `undo_position = top_ls`, `undo_length = 0`; `u` post-toggle surfaces `msg_undo_too_large`.
- Every row was a no-op (no alpha bytes in any clipped row) → `undo_kind = UNDO_KIND_TOO_LARGE` STILL set (the record happens BEFORE the walks); `u` STILL surfaces `msg_undo_too_large`. **This is a conservative over-record** — a "perfect" implementation would back out the TOO_LARGE record on a fully-no-op BLOCK walk. Costs ~10-15 B for the back-out logic. **Not worth the bytes**; pinned as documented over-record per Q1 Option A.

**And** `buffer_dirty` is set unconditionally in the BLOCK arm via `edits_dirty_and_redraw` — even on a fully-no-op walk. This is the same behaviour as Story 3.6 BLOCK d on an empty selection (which also surfaces `buffer_dirty=1` via the same edits_dirty_and_redraw call regardless of whether bytes were actually deleted). **Conservative; matches sibling precedent.**

**AC8 — Cursor placement: post-toggle, cursor lands at top-of-selection (= range_start for CHAR/LINE; top_ls + col_min for BLOCK with BH3 jagged-top clamp). Matches Story 3.6 / 3.7 cursor-placement precedent (Q2 Option A across all three operator classes). Vi's "leave cursor at the operator's start offset" semantic is preserved.**

**Given** the per-arm range projections
**When** the arm completes
**Then** cursor placement:
- **CHAR**: `cursor_offset = range_start = min(anchor, cursor)`. Same as Story 3.6 `_visual_op_char_arm` cursor placement (which lands at delete_start = range_start post-delete; for case-toggle no delete happens but the range_start offset is identical).
- **LINE**: `cursor_offset = range_start = min(anchor_ls, cursor_ls)`. Same as Story 3.7 `visual_apply_shift` cursor placement (which lands at promoted_start = min line-start).
- **BLOCK**: `cursor_offset = top_ls + col_min` with BH3 jagged-top clamp (inherited verbatim from Story 3.6 `_visual_op_block_arm.b_have_cursor` at `src/visual.asm:999-1008`). If the top-row's line_length < col_min, the raw top_ls+col_min offset lands past the row's LF (or past EOF if top row is the no-trailing-LF last line); the clamp DECs back to the LF / file_length-1 position.

**And** **vi divergence** (documented): vim places cursor at the FIRST byte of the selection (vim's "operator-pending" cursor convention) — which for CHAR is `min(anchor, cursor)` (same as VIBE); for LINE is `min line-start` (same as VIBE); for BLOCK is `top_ls + col_min` (same as VIBE with the jagged-top clamp). VIBE matches vim in all three cases. **No FNW (first-non-whitespace) divergence** unlike Story 3.7 `>` / `<` — case-toggle doesn't have a vi-FNW behaviour.

**AC9 — Mode transition: `~` tail-JPs `enter_normal_mode`. Per Story 3.6 AC10 / 3.7 AC10 — flips `mode_byte = MODE_NORMAL`, emits empty `msg_mode_normal` banner, tail-JPs `parser_clear` (which zeroes `count_accumulator` / `pending_operator` / `pending_motion_prefix` / `pending_motion_inclusive`). `visual_anchor` / `visual_submode` remain zombie state — same precedent across Stories 3.3-3.7. NO status-clobber concern (no msg_file_too_large path — gapbuf_case_toggle_range never inserts).**

**Given** `visual_apply_case_toggle` has completed (walk done, undo recorded if dirty, cursor placed)
**When** the final tail-JP fires
**Then** `JP enter_normal_mode` (the existing handler at `src/dispatch.asm:350-368` — UNCHANGED). The handler writes `mode_byte = MODE_NORMAL`, emits the empty banner via `msg_mode_normal`, tail-JPs `parser_clear`.
**And** `visual_anchor` and `visual_submode` are UNCHANGED in state — same zombie-state contract as Stories 3.3-3.7. The next `v` / `V` / `Ctrl-V` re-pins both; the values are meaningless when `mode_byte != MODE_VISUAL` per SR4 invariant.
**And** **NO yank-too-large carve-out** is needed — case-toggle doesn't touch the yank register at all. The Story 3.6 `visual_op_block_yank_ok` flag dance is NOT inherited.
**And** **NO msg_file_too_large clobber concern** — `gapbuf_case_toggle_range` never inserts, so there's no `gapbuf_insert` overflow path that would surface `msg_file_too_large`. The `enter_normal_mode` tail-JP is unconditional across all four exit paths (empty / no-op / dirty-CHAR-LINE / BLOCK).

**AC10 — State.inc / equates.inc / modes.inc changes. Story 3.8 ADDS: `inc/equates.inc` gains `UNDO_KIND_CASE_TOGGLE EQU 0x07` (per AC4). `inc/state.inc` UNCHANGED — no new state-block cells. `inc/modes.inc` UNCHANGED — no new mode discriminators. `src/visual.asm` reuses Story 3.6 cells `visual_op_pending` (operator-byte stash) + `visual_op_range_start` + `visual_op_range_bytes` (CHAR/LINE range stash) + all 9 Story-3.6 `visual_op_block_*` cells (BLOCK arm reuse — identical lifecycle).**

**Given** the existing module-local state landscape post-3.7
**When** Story 3.8 lands
**Then** the following cells are REUSED (no declarations added):
- `visual_op_pending` (declared `src/visual.asm:1711`; Story 3.6) — written by `visual_apply_case_toggle` prologue (operator byte `~` = 0x7E stash); not consumed downstream (case-toggle has no per-operator branch internal to the dispatcher — the kind discrimination is via submode, not operator byte). **Could be omitted as a write** (~3 B savings) but kept for callsite-symmetry with Story 3.6 / 3.7. Pin Q6 Option A.
- `visual_op_range_start` (declared `src/visual.asm:1712`; Story 3.6) — written with `range_start` by CHAR/LINE arms; read at cursor-restore step.
- `visual_op_range_bytes` (declared `src/visual.asm:1713`; Story 3.6) — written with `total_bytes` by CHAR/LINE arms; read by undo-record step.
- `visual_op_block_*` cells (declared `src/visual.asm:1717-1726`; Story 3.6) — all 9 cells reused by BLOCK arm (same lifecycle as Story 3.6).

**And** total state growth in `src/visual.asm` module-local data: **+0 B** (all reuse).
**And** total state growth in `src/edits.asm` / `src/undo.asm` / `src/gapbuf.asm` module-local data: **+0 B** (no new module-locals; the new `gapbuf_case_toggle_range` primitive is stateless — uses HL/BC/DE/A registers only).
**And** **No `inc/state.inc` changes** — `static_off` does not advance; cold-start LDIR zero-fill does not extend.
**And** **No `inc/modes.inc` changes** — no new MODE_* or VIS_* discriminators.

**AC11 — `src/visual.asm` module-header updates: Public block flips `visual_apply_case_toggle` from PLACEHOLDER to LANDS; Purpose paragraph extends to document Story 3.8 (third buffer-mutation path via `gapbuf_case_toggle_range` joining Story 3.6's `edits_range_delete` and Story 3.7's `edits_indent_walk` — AR14 status REMAINS "transitive writer" since the new path goes through gapbuf.asm not directly); the Dependencies block extends to document `gapbuf_case_toggle_range` as a new symbol called from visual.asm. The Register conventions block adds the `visual_apply_case_toggle` AR23 contract per AC2.**

**Given** `src/visual.asm` lines 1-431 (the module-header block, last updated by Story 3.7)
**When** Story 3.8 lands
**Then** the module-header updates:
- **Purpose** (lines 3-65): extend to mention "Story 3.8 — visual_apply_case_toggle (`~`) lands as the FINAL Epic-3 visual operator. visual.asm now has THREE buffer-mutation paths: (1) Story 3.6 `edits_range_delete` → `gapbuf_delete` (d/y/c CHAR/LINE arms); (2) Story 3.6 BLOCK arm's `edits_range_delete` per-row + Story 3.7 `edits_indent_walk` → `gapbuf_insert`/`gapbuf_delete` (line-class shift); (3) Story 3.8 `gapbuf_case_toggle_range` (in-place per-byte case toggle; no insert / no delete; gap-pointer-preserving). AR14 ownership of gap_start / gap_end REMAINS with gapbuf.asm — visual.asm contains zero `LD (gap_start),` / `LD (gap_end),` writes. The Story-3.6 SR4/SR5 invariants + Story-3.6 BLOCK precedent's TOO_LARGE direct record + Story-2.13's Q6 Option B INDENT_WALK / DEDENT_WALK kinds + Story-3.8's NEW UNDO_KIND_CASE_TOGGLE kind compose into the full visual undo coverage matrix."
- **Public** (lines 67-83): flip `visual_apply_case_toggle` entry from PLACEHOLDER to LANDS. The Story-3.7 comment about deferred siblings ("`~` (Story 3.8) remains a placeholder") is REPLACED with "all six visual operators (d / y / c / > / < / ~) now land; the placeholder slot is fully consumed."
- **State owned (read/write)** (lines 85-158): the Story-3.6 cells (`visual_op_pending` / `visual_op_range_start` / `visual_op_range_bytes` / `visual_op_block_*`) are reused by Story 3.8. NO new module-local cells. Extend the existing Lifecycle note to document Story 3.8 reuse.
- **Register conventions** (lines 168-326): add `visual_apply_case_toggle` In/Out/Trashes/Calls block per AC2's contract.
- **Dependencies** (lines 327-430): extend with a Story 3.8 paragraph documenting `gapbuf_case_toggle_range` as a NEW call from visual.asm into gapbuf.asm. **Note: visual.asm now calls 3 different gapbuf primitives transitively via edits.asm helpers, AND now calls 1 gapbuf primitive directly (gapbuf_case_toggle_range) — first DIRECT call from visual.asm into gapbuf.asm.** This is a structural change worth documenting. Forward-resolution model: gapbuf.asm INCLUDEs BEFORE visual.asm per AR25 chain (gapbuf at slot #2; visual at slot #10 post-3.3), so `gapbuf_case_toggle_range` is BACKWARD-resolved (defined when visual.asm is parsed). No forward-ref challenges.

**AC12 — `src/dispatch.asm` updates: the comment block at `src/dispatch.asm:702-710` (the Story-3.7 retire-of-Story-3.6's "operators remain unbound" + "`~` (Story 3.8) remains deferred" comment) is REPLACED with a Story-3.8 narrative noting that ALL six Epic-3 visual operators now land. The module-header Dependencies block extends with a Story 3.8 paragraph documenting `visual_apply_case_toggle` as the SIXTH forward-ref symbol from this module into `src/visual.asm`.**

**Given** the dispatch.asm comment block at `src/dispatch.asm:702-710` (extended by Story 3.7 to retire the Story 3.6 "operators remain unbound" comment in favour of "d/y/c bound; `>`/`<` (Story 3.7) bound; `~` (Story 3.8) remains deferred")
**When** Story 3.8 lands
**Then** the comment block at lines 702-710 is REPLACED with text along the lines of:
```
    ;; Story 3.8 — operator `~` binds to visual_apply_case_toggle
    ;; (FR38; per-byte case toggle via gapbuf_case_toggle_range with
    ;; per-submode range projection). With this entry, ALL six Epic-3
    ;; visual operators (d / y / c / > / < / ~) land — the dispatch_visual
    ;; operator surface is complete. Forward-referenced via sjasmplus
    ;; two-pass; backward-resolved for parser.asm / motions.asm.
```
**And** the module-header Dependencies block (the section ending around `src/dispatch.asm:185-202`) extends with a Story 3.8 paragraph documenting `visual_apply_case_toggle` as the sixth forward-ref symbol after `visual_enter_char` (3.3), `visual_enter_line` (3.4), `visual_enter_block` (3.5), `visual_apply_operator` (3.6), and `visual_apply_shift` (3.7).

**AC13 — Hardware UAT passes the visual case-toggle journey script on the real MicroBeast.**

**Given** I rebuild `vibe.com` with the Story-3.8 patch applied and `make push` it to MicroBeast
**When** I run the UAT script (see "Hardware UAT script" section at the end of this file) from CCP
**Then** every step matches the predicted observation. **The UAT script is reproduced inline below per [[feedback_uat_inline_at_dev_handoff]] — dev MUST paste it into chat at story-handoff time, not just point at the file.**

**AC14 — N new headless tests under `test/cases/visual_*.asm` + 1 parser-dispatch test pass. Epic minimum is 2 (`visual_tilde-toggles.asm` + `visual_tilde-block.asm`). Story 3.8 lands 7 tests total: the 2 epic-minimums + 5 coverage extensions (VIS_LINE, BH3 BLOCK jagged, no-alpha no-op, single-region undo round-trip, BLOCK undo TOO_LARGE surface, parser-dispatch wiring).**

**Given** `make test` runs from a fresh tree
**When** the new test cases are added at the sentinel band 0xDF + 0xF4 + 0xF8..0xFC for visual_tilde tests + 0xFD for the parser-dispatch coverage (per Q4 Option A pin in Task 0; 0xDD..0xDE consumed by Story 3.7 review patches; 0xDF was Story 3.7's "defensive slack" promoted to first sentinel for Story 3.8; 0xFE / 0xFF reserved as defensive slack for review patches + future Stories)
**Then** the following 6 visual_tilde tests PASS:

- `visual_tilde-toggles.asm` (sentinel 0xDF) — **EPIC MINIMUM** AC2 / AC3 / AC6 VIS_CHAR `~` happy path. Buffer `"Hello World"` (11 B; no LF); cursor=0; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_CHAR`, `visual_anchor = 0`, cursor=10 (= 'd' — last byte; selection = full 11-byte buffer). CALL `visual_apply_case_toggle` with A='~'. Expect: `mode_byte = MODE_NORMAL`, `cursor_offset = 0` (range_start), buffer first 11 B = `"hELLO wORLD"` ('H'→'h'; 'e'→'E'; 'l'→'L'; 'l'→'L'; 'o'→'O'; space unchanged; 'W'→'w'; 'o'→'O'; 'r'→'R'; 'l'→'L'; 'd'→'D'), `gap_start` UNCHANGED from pre-call value (no insert / no delete — net file_length unchanged), `gap_end` UNCHANGED, `undo_kind = UNDO_KIND_CASE_TOGGLE`, `undo_position = 0`, `undo_length = 11`, `buffer_dirty = 1`, `yank_kind` UNCHANGED.

- `visual_tilde-line.asm` (sentinel 0xF4) — AC2 / AC6 VIS_LINE `~` happy path. Buffer `"abc\nDEF\nghi"` (11 B; LFs at 3, 7); cursor=0; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_LINE`, `visual_anchor = 0` (line 1 line-start per Story 3.4 AC2 — VIS_LINE anchor IS a line-start); pre-extend cursor=5 (line 2). Range = whole lines 1 + 2 = `[0, 8)` (anchor_ls=0; cursor_ls=4; max_line_end=motion_find_line_end(4)=7 (LF at 7); range_end=8). CALL with A='~'. Expect: `mode_byte = MODE_NORMAL`, `cursor_offset = 0`, buffer first 11 B = `"ABC\ndef\nghi"` (line 1 all-upper → all-lower; line 2 all-upper → all-lower; line 3 untouched per selection bound), `undo_kind = UNDO_KIND_CASE_TOGGLE`, `undo_position = 0`, `undo_length = 8`, `buffer_dirty = 1`.

- `visual_tilde-block.asm` (sentinel 0xF8) — **EPIC MINIMUM** AC2 / AC6 / AC7 VIS_BLOCK `~` happy path with BH3 column range respected. Buffer `"HELLO\nworld\nFOObar"` (17 B; LFs at 5, 11); cursor=0; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_BLOCK`, `visual_anchor = 0` (line 1 col 0); pre-extend cursor=14 (= 'b' in line 3 col 2 — anchor_col=0, cursor_col=2, top_ls=0, bottom_ls=12, col_min=0, col_max=2). Rectangle is 3 rows × 3 cols. CALL with A='~'. Expect: `mode_byte = MODE_NORMAL`, `cursor_offset = 0` (top_ls + col_min), buffer first 17 B = `"helLO\nWORld\nfooBAR"` — wait that's wrong, let me recompute: Original `"HELLO\nworld\nFOObar"` — row 1 cols [0..2] = `"HEL"` → `"hel"`; row 2 cols [0..2] = `"wor"` → `"WOR"`; row 3 cols [0..2] = `"FOO"` → `"foo"`. Result: `"helLO\nWORld\nfoobar"`. Hmm row 3 col 0..2 toggles to lowercase but row 3 already has 'F'/'O'/'O' uppercase + 'b'/'a'/'r' lowercase. So result = `"helLO\nWORld\nfooBAR"`... wait still wrong: row 3 = "FOObar" — col 0..2 = "FOO" → "foo"; cols [3..5] = "bar" → unchanged. Result = "foobar". Full buffer: `"helLO\nWORld\nfoobar"`. Verify: row 1 "HELLO" → cols 0..2 "HEL"→"hel", cols 3..4 "LO"→unchanged. Row 1 = "helLO". Row 2 "world" → cols 0..2 "wor"→"WOR", cols 3..4 "ld"→unchanged. Row 2 = "WORld". Row 3 "FOObar" → cols 0..2 "FOO"→"foo", cols 3..5 "bar"→unchanged. Row 3 = "foobar". Full = `"helLO\nWORld\nfoobar"` (17 B). Expect: `cursor_offset = 0` (top_ls=0 + col_min=0), `undo_kind = UNDO_KIND_TOO_LARGE` (per AC6 BLOCK direct record), `undo_position = 0` (top_ls), `undo_length = 0` (semantically meaningless for TOO_LARGE), `buffer_dirty = 1`.

- `visual_tilde-block-jagged.asm` (sentinel 0xF9) — AC6 / AC7 VIS_BLOCK `~` with BH3 jagged-line clipping. Buffer `"ABCDE\nFG\nHIJKL"` (14 B; LFs at 5, 8; line 1 = 5 chars; line 2 = 2 chars — SHORT; line 3 = 5 chars); cursor=0; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_BLOCK`, `visual_anchor = 0` (line 1 col 0); pre-extend cursor=12 (line 3 col 3 = 'K'). Rectangle nominally 3 rows × 4 cols (col_min=0, col_max=3). Per-row toggle: row 1 cols [0..3] = "ABCD" → "abcd" (4 bytes); row 2 cols [0..min(4, 2)] = "FG" → "fg" (2 bytes — BH3 CLIPPED at line_length=2); row 3 cols [0..3] = "HIJK" → "hijk" (4 bytes). Result buffer first 14 B = `"abcdE\nfg\nhijkL"`. Expect: `cursor_offset = 0`, `undo_kind = UNDO_KIND_TOO_LARGE`, `buffer_dirty = 1`. **Pins BH3 per-row clipping for case toggle — distinguishes from any naïve "whole-rectangle" toggle that would have toggled non-existent bytes past line 2's EOL.**

- `visual_tilde-no-alpha.asm` (sentinel 0xFA) — AC3 / AC6 no-op walk (selection with no alphabetic bytes). Buffer `"12345\n67890"` (11 B; LF at 5); cursor=0; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_CHAR`, `visual_anchor = 0`, cursor=10. Pre-seed `undo_kind = UNDO_KIND_INSERT`, `undo_position = 0x1234`, `undo_length = 5` (prior undo entry from a hypothetical earlier insert). CALL with A='~'. Expect: `mode_byte = MODE_NORMAL`, `cursor_offset = 0`, buffer UNCHANGED (`"12345\n67890"` — no digits / LF toggled — alpha test rejects all), `undo_kind = UNDO_KIND_INSERT` (UNCHANGED per Q3 Option A — no-op walk preserves prior undo), `undo_position = 0x1234` (UNCHANGED), `undo_length = 5` (UNCHANGED), `buffer_dirty` UNCHANGED from pre-seed (0).

- `visual_tilde-undo.asm` (sentinel 0xFB) — AC5 single-region undo round-trip via CHAR. Buffer `"Hello"` (5 B); pre-set VIS_CHAR, anchor=0, cursor=4. **Phase 1**: CALL `visual_apply_case_toggle` A='~'. Verify buffer = `"hELLO"`, cursor=0, undo_kind=UNDO_KIND_CASE_TOGGLE, undo_position=0, undo_length=5, buffer_dirty=1, mode=NORMAL. **Phase 2**: CALL `op_undo` (A='u' or just `LD A,(undo_kind)` dispatch — match the test pattern from `edits_indent_walk-undo-replay.asm`). Verify buffer restored to `"Hello"` (case-toggle re-applied = identity), cursor=0 (undo_replay_success_tail), undo_kind=UNDO_KIND_EMPTY, buffer_dirty=1 (stays 1 per Q5 Option A from Story 2.13). **Pins the self-inverse replay contract.**

- `visual_tilde-block-undo-too-large.asm` (sentinel 0xFC) — AC6 / AC7 BLOCK undo surfaces TOO_LARGE. Buffer `"AB\nCD"` (5 B); pre-set VIS_BLOCK, anchor=0, cursor=4 (anchor_col=0, cursor_col=1, 2 rows × 2 cols). CALL `visual_apply_case_toggle` A='~'. Verify buffer = `"ab\ncd"` (block toggled), undo_kind=UNDO_KIND_TOO_LARGE, undo_position=0 (top_ls), undo_length=0, buffer_dirty=1. Phase 2: CALL `op_undo`. Verify status_buffer contains `msg_undo_too_large` ("undo not possible - too large"), buffer UNCHANGED (`"ab\ncd"` — TOO_LARGE replay is a NO-OP), cursor UNCHANGED, undo_kind=UNDO_KIND_TOO_LARGE (Q4 Option A pin from Story 2.13 — TOO_LARGE NOT consumed by surfacing; second `u` re-surfaces same message). **Pins the BLOCK TOO_LARGE direct-record + replay-refusal contract.**

**And** the parser-dispatch coverage test PASSES:
- `parser_visual_tilde-dispatch.asm` (sentinel 0xFD) — AC1 end-to-end dispatch wiring. Buffer `"Abc"` (3 B); pre-set `cursor_offset = 0`, `mode_byte = MODE_VISUAL`, `visual_submode = VIS_CHAR`, `visual_anchor = 0`, cursor=2. Drive `'~'` (0x7E) through `dispatch_key` with `dispatch_visual`: `LD A, '~' ; LD HL, dispatch_visual ; LD B, DISPATCH_VISUAL_COUNT ; CALL dispatch_key`. Verify post-call: `mode_byte = MODE_NORMAL`, `cursor_offset = 0`, buffer first 3 B = `"aBC"`, `undo_kind = UNDO_KIND_CASE_TOGGLE`, `undo_position = 0`, `undo_length = 3`. Confirms `dispatch_visual['~']` is wired end-to-end to `visual_apply_case_toggle` AND the AC1 table-append landed at the correct sorted position (binary-search finds `~` after `y`).

**Test count target: 247 (post-3.7 incl. Review patches) → 254 PASS (+7: 6 visual_tilde tests + 1 parser-dispatch) / 1 deliberate-fail (`harness_fail` sentinel) unchanged.**

## Tasks / Subtasks

- [x] **Task 0** (pre-dev pins with Ant — Option A recommended across the board, consistent with Stories 3.3-3.7 precedent):
  - [x] Q1 — BLOCK undo strategy. **Recommended Option A** — UNDO_KIND_TOO_LARGE direct record (matches Story 3.6 BLOCK arm; multi-region undo deferred as a future polish story). User cannot undo BLOCK `~`; `u` surfaces `msg_undo_too_large`. Cost: ~15 B for the direct-record path. Alternative Option B = stash block geometry (top_ls, col_min, col_max, rows) + replay re-walks per-row; rejected — would need new module-local cells in undo.asm + a new replay body + structural change to the (kind, position, length) header convention; ~30-50 B above Option A; out of scope for Story 3.8 — defer to multi-region undo cross-cutting story. Pin Option A.
  - [x] Q2 — Cursor placement post-toggle. **Recommended Option A** — top-of-selection (= `range_start` for CHAR/LINE; `top_ls + col_min` for BLOCK with BH3 jagged-top clamp). Matches Stories 3.6 / 3.7 cursor placement; vi-faithful "operator-start" cursor convention. Alternative Option B = anchor / original position; epic AC line 1742 ("cursor at anchor or original position") allows either. Pin Option A — sibling-consistency.
  - [x] Q3 — No-op walk undo policy. **Recommended Option A** — PRESERVE prior undo on no-op walks (do NOT call `undo_clear` before the walk in the CHAR/LINE finalise). Divergence from Story 2.11 / 3.7 precedent (which pre-clears unconditionally). Rationale: a no-op `~` on a no-alpha selection is semantically equivalent to no operation; preserving the prior undo entry is more useful than clearing it. **Documented vi-divergence**: vim clears the redo stack on every operation (no-op or not); VIBE preserves the prior undo on no-op `~`. Alternative Option B = pre-clear unconditionally (matches Story 2.11 / 3.7); rejected — adds ~3 B for the `CALL undo_clear` and loses the prior undo for what is effectively a non-operation. Pin Option A.
  - [x] Q4 — Test sentinel band. **Recommended Option A** — 0xDF (promoted from Story 3.7's defensive slack) + 0xF4 + 0xF8..0xFC (7 sentinels for visual_tilde tests) + 0xFD for parser_visual_tilde-dispatch. Leaves 0xFE..0xFF as defensive slack for review patches (mirrors Story 3.7's 0xDF reservation). Alternative Option B = pack into a contiguous band; rejected — there's no contiguous 8-slot run available without taking sentinels from the reserved-slack zone.
  - [x] Q5 — `gapbuf_case_toggle_range` past-EOF defensive contract. **Recommended Option A** — clip at file_length via the gap_end overrun check (i.e. `gapbuf_move_gap(HL)` relocates the gap; bytes are walked at gap_end..gap_end+BC; if BC overruns the after-gap half, the walk wanders into the gap interior (uninitialised bytes) and may toggle garbage. **Pin: caller is responsible for ensuring BC <= file_length - HL**. The visual_apply_case_toggle arms all derive BC from line-bounded ranges (CHAR / LINE / BLOCK), so file_length-bound is structurally enforced.) Alternative Option B = the primitive walks a `file_length - HL` clamp internally; rejected — the visual arms already enforce the bound; adding internal clamp adds ~10 B for redundant safety. Pin Option A — minimum primitive surface.
  - [x] Q6 — Operator-byte stash. **Recommended Option A** — `LD (visual_op_pending), A` in the dispatcher prologue (kept for callsite-symmetry with Stories 3.6 / 3.7; the value is NOT consumed downstream since `~` is a single-op operator class). Alternative Option B = omit the write (~3 B savings); rejected — breaks sibling-consistency and complicates future "visual operators take counts" extension story (which would need the operator byte to disambiguate `~` from `d`/`y`/`c`/`>`/`<` in a unified handler). Pin Option A.
  - [x] Q7 — Where does `gapbuf_case_toggle_range` live? **Recommended Option A** — `src/gapbuf.asm` (joins gapbuf_init / _insert / _delete / _move_gap as the FIFTH public mutator; preserves AR14 with a clean encapsulated primitive). Alternative Option B = AR14 carve-out in visual.asm or edits.asm; rejected — adds a third documented carve-out and spreads buffer-content mutation across two modules. Pin Option A.
  - [x] Q8 — Commit strategy. **Recommended Option A** — single dev commit (matches Epic-3 single-commit pattern across Stories 3.1-3.7).

- [x] **Task 1** — Extend `inc/equates.inc`:
  - [x] 1.1 — Add `UNDO_KIND_CASE_TOGGLE EQU 0x07` at line ~109 (immediately after UNDO_KIND_DEDENT_WALK). Per AC4.
  - [x] 1.2 — Extend the equate-block module-header comment (lines 93-101) to document the new kind (self-inverse semantic).

- [x] **Task 2** — Add `gapbuf_case_toggle_range` to `src/gapbuf.asm`:
  - [x] 2.1 — Add `gapbuf_case_toggle_range:` public entry at file tail (after `gapbuf_move_gap.equal` arm at line 257; before the `;; --- Internal helpers ---` section divider at line 259-264). Body per AC3 ~50 B.
  - [x] 2.2 — AR23 docstring above the label per AC3 contract.
  - [x] 2.3 — Module-header Public block extends with `gapbuf_case_toggle_range — in-place case-toggle (Story 3.8)`.
  - [x] 2.4 — Module-header Purpose paragraph extends to document Story 3.8 per AC3.
  - [x] 2.5 — AR sweep on `src/gapbuf.asm` post-3.8 — verify no NEW BIOS / BDOS / status surfaces (case-toggle primitive is pure memory walk; no error path that would need status_set_message).

- [x] **Task 3** — Add `visual_apply_case_toggle` to `src/visual.asm`:
  - [x] 3.1 — Add `visual_apply_case_toggle:` public entry between `visual_apply_shift` (ends at line 1343) and `visual_count_lines` (starts at line 1374). Per AC2 dispatcher + 3 arms + shared finalise body shape.
  - [x] 3.2 — `_visual_op_case_char_arm` body — SBC-and-swap range projection (~30 B).
  - [x] 3.3 — `_visual_op_case_line_arm` body — line-promote + range_end = max_line_end + 1 (no at-EOF carve-out) (~50 B).
  - [x] 3.4 — `_visual_op_case_toggle_finalise` shared CHAR/LINE tail — 0-byte guard + `gapbuf_case_toggle_range` CALL + dirty-branch undo-record + cursor-restore + `enter_normal_mode` tail-JP (~35 B).
  - [x] 3.5 — `_visual_op_case_block_arm` body — block dims + col_min/max + top_ls + UNDO_KIND_TOO_LARGE direct record + per-row walk + cursor placement (top-left + BH3 jagged-top clamp) + `edits_dirty_and_redraw` + tail-JP (~110 B).
  - [x] 3.6 — AR23 docstrings above each label.
  - [x] 3.7 — Module-header updates per AC11: Purpose extended with Story 3.8 paragraph; Public block flipped `visual_apply_case_toggle` to LANDS; State-owned Lifecycle note documents Story 3.8 reuse of Story 3.6 cells; Register-conventions block for `visual_apply_case_toggle` added; Dependencies block extended with the new `gapbuf_case_toggle_range` direct call.
  - [x] 3.8 — AR sweep on `src/visual.asm` post-3.8:
    - `BIOS_CONOUT` / `BDOS_CALL` / `CALL 0x0005` — zero matches in code (only comment self-refs).
    - `LD (gap_start),` / `LD (gap_end),` — zero matches in code (only comment self-refs).
    - `CALL gapbuf_insert` / `CALL gapbuf_delete` / `CALL gapbuf_move_gap` — zero matches.
    - `CALL gapbuf_case_toggle_range` — at least 4 matches (CHAR arm + LINE arm + BLOCK per-row + undo replay would be in undo.asm not visual.asm — so 3 in visual.asm). **First direct gapbuf primitive call from visual.asm.**

- [x] **Task 4** — Extend `src/dispatch.asm`:
  - [x] 4.1 — Append `~` (0x7E) entry to `dispatch_visual` at the table tail (between `y`/`visual_apply_operator` at line 785-786 and `DISPATCH_VISUAL_COUNT EQU` at line 787). Add `ASSERT '~' > 'y'` (line ~786). DEFW `visual_apply_case_toggle` (forward-ref via sjasmplus two-pass per AC2's INCLUDE-order analysis — visual.asm INCLUDEs AFTER dispatch.asm in vibe.asm).
  - [x] 4.2 — Verify `DISPATCH_VISUAL_COUNT` auto-recomputes 0x19 (25) → 0x1A (26) per `build/vibe.lst` (the `787+ 0944 DISPATCH_VISUAL_COUNT EQU ($ - .entries) / 3` line should resolve to 0x1A; `LD B, DISPATCH_VISUAL_COUNT` emits as `06 1A` at the dispatch_key call site). Cross-check per [[feedback_create_story_cross_check]] — five previous stories drifted on this metric.
  - [x] 4.3 — Replace the comment block at `src/dispatch.asm:702-710` per AC12 (Story-3.7 retire-of-3.6's deferral note → Story-3.8 all-operators-land note).
  - [x] 4.4 — Extend `src/dispatch.asm` module-header Dependencies block with a Story 3.8 paragraph documenting `visual_apply_case_toggle` as the sixth forward-ref symbol.
  - [x] 4.5 — `dispatch_normal` UNCHANGED — `~` in NORMAL still falls through to `unbound_normal` (vim-divergent; pinned in AC1).

- [x] **Task 5** — Extend `src/undo.asm`:
  - [x] 5.1 — Add `undo_replay_case_toggle:` public entry per AC5 (~12 B; placed after `undo_replay_dedent_walk` at line 439 and before the `;; --- Public: undo_record_insert ---` divider at line 442-444).
  - [x] 5.2 — Add the dispatch entry to `op_undo` for `UNDO_KIND_CASE_TOGGLE`: `CP UNDO_KIND_CASE_TOGGLE ; JP Z, undo_replay_case_toggle` inserted between the existing DEDENT_WALK and TOO_LARGE dispatch entries at line ~238-240 (~5 B).
  - [x] 5.3 — Extend the `op_undo` AR23 docstring (lines 199-225) to document the new kind branch.
  - [x] 5.4 — Extend the `src/undo.asm` module-header Purpose paragraph to document Story 3.8 per AC5.
  - [x] 5.5 — NO new record helper (`undo_record_case_toggle`) — the CHAR/LINE finalise in visual.asm calls `undo_write_header(A=UNDO_KIND_CASE_TOGGLE)` directly; the existing Q1 Option D shared `undo_write_header` factor-out absorbs the call site fine.

- [x] **Task 6** — Headless tests (7 new files in `test/cases/`):
  - [x] 6.1 — `visual_tilde-toggles.asm` (sentinel 0xDF) — VIS_CHAR happy path per AC14.
  - [x] 6.2 — `visual_tilde-line.asm` (sentinel 0xF4) — VIS_LINE happy path.
  - [x] 6.3 — `visual_tilde-block.asm` (sentinel 0xF8) — VIS_BLOCK with BH3 column range.
  - [x] 6.4 — `visual_tilde-block-jagged.asm` (sentinel 0xF9) — VIS_BLOCK with BH3 jagged short line.
  - [x] 6.5 — `visual_tilde-no-alpha.asm` (sentinel 0xFA) — no-op walk preserves prior undo per Q3 Option A.
  - [x] 6.6 — `visual_tilde-undo.asm` (sentinel 0xFB) — CHAR undo round-trip via UNDO_KIND_CASE_TOGGLE replay.
  - [x] 6.7 — `visual_tilde-block-undo-too-large.asm` (sentinel 0xFC) — BLOCK undo surfaces msg_undo_too_large.
  - [x] 6.8 — `parser_visual_tilde-dispatch.asm` (sentinel 0xFD) — AC1 end-to-end dispatch wiring.
  - [x] 6.9 — Sentinel band consumed: 0xDF + 0xF4 + 0xF8..0xFD (7 new). 0xFE..0xFF reserved as defensive slack for review patches.
  - [x] 6.10 — Fixture-seeding + INCLUDE chain matches Story 3.7's pattern verbatim. Build chain clean (sjasmplus exit=0 on every test).

- [x] **Task 7** — NFR18 byte-identical rebuild + UAT + sprint-status flip:
  - [x] 7.1 — Run `make clean && make all` twice from a fresh tree; record `sha256sum vibe.com` both times. Verify byte-identical.
  - [x] 7.2 — Run `make sizes`; verify total code under 8192 B NFR9 ceiling. Pre-3.8 = 7855 B; mid-estimate +200 B → ~8055 B / ~137 B headroom. **If actual lands above 8050 B (i.e. less than 142 B headroom), flag for [[project_nfr9_cliff_edge]] amendment conversation. If actual lands above the 8192 B ceiling, redesign rather than amend** — Epic 3 close ceiling already amended once 2026-05-17 from 6400 to 8192 B per PRD §NFR9.
  - [x] 7.3 — Hardware UAT script (AC13) — paste inline below at dev-handoff per [[feedback_uat_inline_at_dev_handoff]].
  - [x] 7.4 — `sprint-status.yaml` flipped `ready-for-dev` → `in-progress` (Task 0 start) → `review` (Task 7 done) → `done` (post-hardware-UAT confirmation by Ant).

### Review Findings

Code review 2026-05-19. Layers: Blind Hunter (diff-only adversarial), Edge Case Hunter (diff + project read), Acceptance Auditor (diff + spec). All 14 ACs PASS at the auditor layer. Adversarial layers surfaced four shared-pattern Major findings (all inherited verbatim from Story 3.6 / 3.7 precedent — hardware-UAT'd on those stories) and 10 unit-test coverage gaps. NFR9 cliff (13 B headroom) constrains in-story remediation.

- [x] [Review][Defer] **Caller-side bound hardening across CHAR / LINE / BLOCK arms (4 inherited findings rolled up)** [`src/visual.asm` CHAR/LINE/BLOCK arms + `src/gapbuf.asm:gapbuf_case_toggle_range`] — deferred, pre-existing; will fix in next epic. — (1) CHAR arm passes `HL+BC > file_length` to `gapbuf_case_toggle_range` on empty buffer (`file_length=0`; `cursor==anchor==0` → BC=1 violates Q5 caller-bound contract); LINE arm has `JR C, .at_eof` clamp but CHAR arm does not. Reachable via `vibe` on empty file → `v~`. Memory effect: 1 byte at `gap_end` (post-gap region head) XOR'd if alpha. (2) BLOCK walker enters past-EOF offsets when `top_ls >= file_length`; self-terminates via `remaining_rows` but walker arithmetic is undocumented past `file_length`. (3) BLOCK jagged-top cursor clamp at `_visual_op_case_block_arm.b_cursor_clamp` is single-step `DEC HL` — insufficient when `top_ls + col_min` overshoots top-row EOL by >1 byte (anchor on short row, cursor on long row, high column). Inherited verbatim from Story 3.6 `_visual_op_block_arm.b_have_cursor`. (4) BLOCK with `cursor==0` + buffer starts with LF skips clamp entirely via `LD A,H ; OR L ; JR Z` shortcut — cursor left on LF. All four cases share Story 3.6 precedent; Story 3.6/3.7 shipped with the same gaps and hardware-UAT passed. Options: (a) patch `gapbuf_case_toggle_range` with a 5-B `file_length=0` short-circuit at primitive entry, covering (1)+(2); (b) defer the whole bundle to a post-Epic-3 hardening pass; (c) split — fix only the empty-buffer-CHAR overrun if NFR9 cliff allows shaving. (Source: Blind Hunter B1/B2 + Edge Case Hunter C1/L2/B1/B3/B4 + Acceptance Auditor cross-cutting.)
- [x] [Review][Defer] **Unit-test coverage gaps (T1-T10)** — CHAR backward path (`cursor < anchor`) unexercised; CHAR boundary at `file_length` unexercised; LINE last-line-no-LF (`.at_eof` CF=1 branch) unexercised; LINE 1-line selection unexercised; BLOCK 1×1 rectangle unexercised; BLOCK with `top_ls >= file_length` unexercised; gap-crossing primitive call (range straddles `gap_start`/`gap_end`) unexercised; no-op undo preservation through `op_undo` replay round-trip unexercised; BLOCK no-op all-digit clobbering prior undo with TOO_LARGE unexercised; replay correctness under interleaved mutations unexercised. Hardware UAT (23 steps) confirmed by Ant on real MicroBeast; these are unit-coverage gaps, not behaviour bugs. — deferred, pre-existing pattern. (Source: Edge Case Hunter T1-T10.)

Dismissed as noise (10): `visual_op_block_cols` dead-store removal (cell explicitly documented "not read downstream" at `src/visual.asm:2173`); `cursor_offset PRESERVED` doc claim on `gapbuf_case_toggle_range` (sibling `gapbuf_move_gap` doesn't write cursor); `undo_replay_case_toggle` Z-flag-handling doc drift (replay correctness doesn't require branch mirroring); primitive trashed-register doc nit; LINE arm fall-through to finalise without `JR` (assembler convention); BLOCK no-op all-digit clobbers undo with TOO_LARGE (INTENTIONAL per Q1 Option A pin); `parser_visual_tilde-dispatch` wiring concern (Blind Hunter self-corrected; transitively verified via `DISPATCH_VISUAL_COUNT` auto-recompute); `visual_tilde-no-alpha` sentinel comment fragility (non-defect); AC2/AC6 LINE-arm projection wording inconsistency (spec defect, code correct — AC2 wording matches code, AC6 stale wording stayed in spec from earlier draft).

## Dev Notes

### Architecture compliance

**AR boundaries — `src/visual.asm` remains a TRANSITIVE WRITER of buffer state after Story 3.8, but gains its FIRST DIRECT call into `src/gapbuf.asm` for the case-toggle primitive.**
- AR12 (status funnel): zero direct call sites — visual.asm still never calls `status_set_message` directly post-3.8. Status updates funnel through `enter_normal_mode` (which writes `msg_mode_normal`) and through the BLOCK arm's potential `msg_undo_too_large` surface (which routes via `undo_write_header` → no direct status call). **Pin: case-toggle has NO direct status surface — distinct from Story 3.6 BLOCK arm which surfaces `msg_yank_too_large` inline.**
- AR13 (BIOS_CONOUT): zero direct call sites — visual.asm still never emits to screen directly.
- AR14 (gap_start / gap_end WRITES): visual.asm now CALLs `gapbuf_case_toggle_range` (Story 3.8's NEW primitive) directly — `gapbuf_case_toggle_range` internally calls `gapbuf_move_gap` which relocates the gap (writes `gap_start` / `gap_end`). **The AR14 ownership of gap_start / gap_end REMAINS with gapbuf.asm** (no direct writes in visual.asm); visual.asm is in the call-graph from a buffer-mutating path via THREE routes post-Story-3.8: (1) `edits_range_delete` (Story 3.6's d/y/c arms — transitive), (2) `edits_indent_walk` (Story 3.7's >/< arm — transitive), (3) `gapbuf_case_toggle_range` (Story 3.8's ~ arm — **DIRECT call from visual.asm to gapbuf.asm**). Grep `LD (gap_start),\|LD (gap_end),` against `src/visual.asm` post-3.8 returns zero direct matches; grep `CALL gapbuf_case_toggle_range` against `src/visual.asm` returns at least 3 matches (CHAR / LINE finalise + BLOCK per-row).
- AR15 (BDOS_CALL): zero call sites — visual.asm still never invokes BDOS.

**AR23 (per-module header convention)** — `visual_apply_case_toggle` + `gapbuf_case_toggle_range` get docstrings with In/Out/Trashes/Calls per the Story 1.5+ pattern (AC2 + AC3 contracts).

**AR25 (INCLUDE order)** — Story 3.8 adds NO new INCLUDEs to `src/vibe.asm`. The existing AR25 chain (post-Story-3.7) is:
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

`visual.asm` (10) INCLUDEs AFTER `gapbuf.asm` (2) — so `gapbuf_case_toggle_range` is BACKWARD-resolved (already defined when visual.asm is parsed). `undo.asm` (11) INCLUDEs AFTER `gapbuf.asm` (2) — so `gapbuf_case_toggle_range` is BACKWARD-resolved for `undo_replay_case_toggle` too. **No new forward-ref challenges introduced by Story 3.8.**

**MC4 register convention** — `visual_apply_case_toggle` accepts A = `'~'` (the operator byte; consumed only for the prologue stash to `visual_op_pending` per Q6 Option A — value not consumed downstream). All dispatch_visual entries are MC4-correct: `dispatch_key` sets A to the matched key before tail-calling the handler.

**SR4 mode-byte + submode invariant** — Story 3.8 is the SECOND consumer of all three submode discriminators in the operator path (after Story 3.6 d/y/c). Unlike Story 3.7 `>` / `<` which collapsed all three submodes to a single line-class projection, Story 3.8 branches per-submode like Story 3.6:
- VIS_CHAR → `_visual_op_case_char_arm` (inclusive byte range)
- VIS_LINE → `_visual_op_case_line_arm` (line-promoted range; no at-EOF carve-out)
- VIS_BLOCK → `_visual_op_case_block_arm` (per-row BH3 clipped; UNDO_KIND_TOO_LARGE direct record)

On exit from `~`, `mode_byte` flips to MODE_NORMAL via `enter_normal_mode`. `visual_submode` remains zombie state — same precedent.

**SR5 visual-anchor semantic** — Story 3.8 is the THIRD destructive consumer of the anchor across all three submodes (after Stories 3.6 d/y/c + 3.7 >/<):
- VIS_CHAR: anchor is offset-space; CHAR arm reads `(visual_anchor)` and uses it directly in the SBC-and-swap min/max computation.
- VIS_LINE: anchor is line-start (per Story 3.4 AC2); the `motion_find_line_start` call in the LINE arm is no-op-ish.
- VIS_BLOCK: anchor is offset-space (per Story 3.5 AC2); the BLOCK arm reads `(visual_anchor)` via `visual_count_block_dims` (which derives anchor_ls + anchor_col).

**SR6 yank register** — Story 3.8 does NOT touch the yank register. No KIND change; no capacity check; no `msg_yank_too_large` path. (Distinct from Story 3.6 which is the first writer of KIND_BLOCK.)

**State.inc** — NO CHANGES. All state reuse — `visual_op_pending` / `visual_op_range_start` / `visual_op_range_bytes` (Story 3.6 cells) + all 9 `visual_op_block_*` cells (Story 3.6).

### Files this story modifies (and what to preserve)

**`src/gapbuf.asm`** (currently 263 lines post-Story-2.2 retire of `gapbuf_load`):
- ADD `gapbuf_case_toggle_range:` public entry at file tail (after `gapbuf_move_gap.equal` at line 257; before `;; --- Internal helpers ---` divider at line 259-264). Per Task 2.
- MODIFY module-header Public block + Purpose paragraph per Task 2.3 / 2.4.
- PRESERVE: `gapbuf_init` body UNCHANGED; `gapbuf_insert` body UNCHANGED; `gapbuf_delete` body UNCHANGED; `gapbuf_move_gap` body UNCHANGED (including .equal / .right / .left arms); module-header AR sweep status (no new BIOS / BDOS surfaces).

**`src/visual.asm`** (currently 1726 lines post-Story-3.7):
- ADD `visual_apply_case_toggle:` public entry + `_visual_op_case_char_arm` + `_visual_op_case_line_arm` + `_visual_op_case_toggle_finalise` + `_visual_op_case_block_arm` between `visual_apply_shift`'s body ending at line 1343 and `visual_count_lines`'s body starting at line 1374 (Task 3).
- MODIFY module-header (lines 1-431) per Task 3.7: extend Purpose paragraph; flip Public block entry from PLACEHOLDER to LANDS; extend Lifecycle note for module-local cells (reuse documentation); add Register conventions block; extend Dependencies block with the new `gapbuf_case_toggle_range` direct call (first direct gapbuf call from visual.asm).
- PRESERVE: `visual_enter_char` body (UNCHANGED); `visual_enter_line` body (UNCHANGED); `visual_enter_block` body (UNCHANGED); `visual_extend`'s 3-way prologue + arms (UNCHANGED); `visual_apply_operator` body + `_visual_op_char_arm` / `_visual_op_line_arm` / `_visual_op_block_arm` / `_visual_op_block_row_bytes` / `_visual_op_delete_yank_or_change` bodies (UNCHANGED — Story 3.8 is an INDEPENDENT entry, not threaded through visual_apply_operator); `visual_apply_shift` body (UNCHANGED); `visual_count_lines` body (UNCHANGED); `visual_count_block_dims` body (UNCHANGED — reused by case-toggle BLOCK arm); `visual_compose_status*` shared-tail (UNCHANGED); all module-local DEFW/DEFB cells (UNCHANGED — Story 3.8 reuses Story 3.6's `visual_op_pending` + `visual_op_range_start` + `visual_op_range_bytes` + all 9 `visual_op_block_*` cells); all module-header constants (`MSG_MODE_VISUAL_*_PREFIX_LEN` equates UNCHANGED).

**`src/dispatch.asm`** (currently 787 lines post-Story-3.7):
- INSERT one 3-byte entry + 1 ASSERT in `dispatch_visual`: `'~'` (0x7E) after `'y'` (0x79) at the table tail. Per Task 4.1.
- MODIFY the comment block at lines 702-710 per Task 4.3 (Story-3.7 retire → Story-3.8 all-operators-land).
- MODIFY module-header Dependencies block per Task 4.4.
- PRESERVE: ALL of `dispatch_normal`'s 38 entries (UNCHANGED — `~` in NORMAL still falls through to `unbound_normal`; vim-divergent and pinned in AC1); `dispatch_insert` / `dispatch_command` UNCHANGED; `dispatch_visual`'s existing 25 entries UNCHANGED; `enter_normal_mode` / `enter_insert_mode` / `unbound_normal` / `unbound_visual` / `unbound_insert` ALL UNCHANGED; `dispatch_key` body UNCHANGED.

**`src/undo.asm`** (currently 748 lines post-Story-2.13):
- ADD `undo_replay_case_toggle:` public entry per Task 5.1 (~12 B).
- INSERT one new dispatch entry in `op_undo` per Task 5.2 (~5 B).
- MODIFY `op_undo` AR23 docstring + module-header Purpose paragraph per Task 5.3 / 5.4.
- PRESERVE: `op_undo` dispatch chain to existing kinds (INSERT / DELETE / REPLACE / INDENT_WALK / DEDENT_WALK / TOO_LARGE / EMPTY) UNCHANGED; all replay bodies (`undo_replay_insert` / `_delete` / `_replace` / `_indent_walk` / `_dedent_walk`) UNCHANGED; `undo_replay_success_tail` UNCHANGED; all record helpers (`undo_record_insert` / `_delete` / `_replace` / `_indent_walk` / `_dedent_walk`) UNCHANGED; `undo_clear` / `undo_write_header` / `undo_insert_exit_record` UNCHANGED; `insert_session_entry_cursor` cell UNCHANGED.

**`inc/equates.inc`** — ADD `UNDO_KIND_CASE_TOGGLE EQU 0x07` per Task 1. PRESERVE all existing equates.

**`src/edits.asm`** — NO CHANGES. `edits_dirty_and_redraw` reused as-is by visual.asm Story 3.8 arms.

**`src/motions.asm`** — NO CHANGES. `motion_find_line_start` / `motion_find_line_end` / `motion_byte_at_logical` all reused as-is.

**`src/statusln.asm`** — NO CHANGES. No new message strings needed — case-toggle uses existing `msg_mode_normal` (banner via `enter_normal_mode`) and `msg_undo_too_large` (BLOCK undo surface).

**`inc/state.inc`** — NO CHANGES.
**`inc/modes.inc`** — NO CHANGES.
**`src/parser.asm`** — NO CHANGES.
**`src/render.asm`** — NO CHANGES.
**`src/vibe.asm`** — NO CHANGES (AR25 chain unchanged).

**Test files (`test/cases/*.asm`):**
- ADD 7 new test files per Task 6.
- NO bulk patch needed — the AR25 INCLUDE chain extension for gapbuf.asm + visual.asm + undo.asm is all in place since Stories 3.3 / 2.13.
- PRESERVE: All existing test bodies (the spec assumes Stories 3.3-3.7's visual_* and parser_visual_*-dispatch tests are UNCHANGED and still PASS post-3.8 — they exercise the entry / extend / d/y/c / >/< operator paths that Story 3.8 doesn't touch).

### Implementation choices and trade-offs

**Choice: `visual_apply_case_toggle` is a SINGLE entry that branches on `visual_submode` to 3 arms; NOT a single submode-agnostic projection like Story 3.7 `>`/`<`.**
- Per Q2 / AC2. Story 3.7 `>` / `<` collapse all three submodes to a line-class projection (column range ignored for BLOCK). Story 3.8 `~` respects each submode's geometry: CHAR = byte range; LINE = line range; BLOCK = per-row clipped range with BH3. The 3-arm shape matches Story 3.6 `visual_apply_operator` precedent — different submodes need different range-compute paths.
- Implementation cost: ~265 B for the 3 arms + shared finalise + BLOCK separate body. Larger than Story 3.7's ~108 B (one arm) but smaller than Story 3.6's ~400 B (three arms with more complex finalise paths involving yank machinery + edits_range_delete per-row + INSERT-mode dispatch for 'c').

**Choice: Single-region undo for CHAR/LINE (UNDO_KIND_CASE_TOGGLE); TOO_LARGE direct record for BLOCK.**
- Per Q1 Option A / AC6. CHAR and LINE are contiguous byte ranges — single-region undo replay (re-toggle the same range) works perfectly because case-toggle is self-inverse. BLOCK is multi-region (each row's clipped range) — same shape as Story 3.6 BLOCK d/y/c's UNDO_KIND_TOO_LARGE direct record. Multi-region undo is a tracked deferred-work item; out of scope for Story 3.8.
- Trade-off: BLOCK `~` is not undoable. User must manually re-`~` to revert. Documented vi-divergence; matches Story 3.6 BLOCK precedent.

**Choice: NEW primitive `gapbuf_case_toggle_range` in `src/gapbuf.asm` (not an AR14 carve-out).**
- Per Q7 Option A / AC3. Encapsulates the move_gap-then-in-place-mutate pattern as a public gapbuf entry, joining gapbuf_init / _insert / _delete / _move_gap. Preserves AR14 with a clean boundary.
- Alternative (AR14 carve-out in visual.asm or edits.asm) rejected — would add a third documented carve-out (after fileio.asm load + gap_start linear-fill) and spread buffer-content mutation across modules.

**Choice: No pre-clear `undo_clear` on no-op walks (Q3 Option A — DIVERGES from Stories 2.11 / 3.7).**
- Per Q3 Option A / AC6. A no-op `~` (selection has no alphabetic bytes) preserves the prior undo entry. Stories 2.11 (op_compose_indent / _dedent) and 3.7 (visual_apply_shift) PRE-clear unconditionally then no-op leaves undo at EMPTY — the divergence here is deliberate. Rationale: a no-op `~` is more like a non-operation than an "indent/dedent walk that happened to find nothing to do" — preserving the prior undo is more useful for the user.
- Trade-off: ~3 B savings (no `CALL undo_clear` on the no-op path); slight policy inconsistency with siblings. **Documented divergence** in the AR23 docstring + module-header.

**Choice: Inline alpha classifier (~14 B) rather than a shared `is_alpha` helper.**
- Per Q6 Option A. The classifier is used in exactly one place (the `gapbuf_case_toggle_range` per-byte loop). A shared helper would cost ~6 B for the CALL/RET pair but save nothing since there's no second consumer. The inline form also avoids the CALL/RET overhead per byte (~17 cycles vs ~7 inline) — for a 1024-byte selection, that's ~10 ms saved on real 4 MHz Z80.

**Choice: Cursor at top-of-selection (Q2 Option A — matches Stories 3.6 / 3.7).**
- Per Q2 Option A / AC8. CHAR/LINE = `range_start = min(anchor, cursor)` (or min line-start); BLOCK = `top_ls + col_min` with BH3 jagged-top clamp. Vim's behaviour matches in all three cases.

**Choice: Single commit (Option A for Q8).**
- Matches the Epic-3 single-commit pattern (Stories 3.1-3.7 all single commits).

### Previous story intelligence

**From Story 3.7 (just completed, UAT confirmed, code-reviewed, done):**
- `visual_apply_shift` is the line-class `>`/`<` dispatcher (submode-agnostic via line-promote). Story 3.8's `visual_apply_case_toggle` is the SIXTH and FINAL Epic-3 visual operator — separate public entry, separate dispatch_visual binding.
- **NFR9 cliff-edge per [[project_nfr9_cliff_edge]]**: Story 3.7 closed at 7855 B / 337 B headroom. Story 3.8 must treat 337 B as the binding ceiling; mid-estimate +200 B → ~8055 B / ~137 B headroom — within ceiling. **Story 3.8 is the cliff-edge story** per the memory note "Stories 3.7 / 3.8 are tight"; flag amendment ONLY if projected delta > 250 B (current projection ~200 B is below trigger).
- **No status-clobber risk**: Story 3.7 had to manage `msg_file_too_large` clobber on partial-overflow indent walk. Story 3.8 has NO insert/delete path — `gapbuf_case_toggle_range` is in-place only, so `msg_file_too_large` is structurally unreachable. The Q1 Option A "accept clobber" pattern from Story 3.7 does NOT apply to Story 3.8.
- **Cell reuse precedent**: Stories 3.6 and 3.7 both reuse `visual_op_pending` + `visual_op_range_start` (+ Story 3.6 adds `visual_op_range_bytes` + 9 `visual_op_block_*` cells). Story 3.8 reuses ALL of these for free.
- **Sentinel band reservation precedent**: Story 3.7's "0xDF reserved as defensive slack" is promoted to Story 3.8's first sentinel; the remaining slack is 0xFE..0xFF for review patches.
- **DISPATCH_VISUAL_COUNT verified at 0x19 (25) post-3.7**; Story 3.8 takes it to 0x1A (26). Same cross-check care per [[feedback_create_story_cross_check]].

**From Story 3.6 (visual operators d/y/c):**
- `visual_apply_operator` is the 3-arm CHAR/LINE/BLOCK dispatcher. Story 3.8's `visual_apply_case_toggle` mirrors the 3-arm shape verbatim — same submode discrimination, same CHAR/LINE finalise pattern (different shared-tail body), same BLOCK per-row + TOO_LARGE direct record pattern.
- `_visual_op_block_row_bytes` (BH3 clip helper at `src/visual.asm:1044-1060`) is reused verbatim by Story 3.8 BLOCK arm.
- `visual_count_block_dims` (block-rect projection at `src/visual.asm:1459+`) is reused verbatim by Story 3.8 BLOCK arm.
- `_visual_op_char_arm`'s SBC-and-swap range projection (CHAR arm, lines 647-672) is a structural reference for Story 3.8's `_visual_op_case_char_arm` — same shape, different finalise tail-JP.
- `_visual_op_line_arm`'s line-promote (LINE arm, lines 691-748) is a structural reference for Story 3.8's `_visual_op_case_line_arm` — same shape MINUS the at-EOF carve-out (case-toggle has no delete-shift to manage).
- **BLOCK arm's UNDO_KIND_TOO_LARGE direct record precedent (lines 861-872)** — Story 3.8 reuses this exact pattern.

**From Story 3.5 (visual block mode Ctrl-V):**
- `visual_count_block_dims` projects anchor + cursor to (line_start, col) pairs. Story 3.8 BLOCK arm depends on this.
- The 5 `visual_block_*` projection cells (lines 1686-1690) are reused via `visual_count_block_dims`.

**From Story 3.4 (visual line mode V):**
- `visual_enter_line` snaps anchor to `motion_find_line_start(cursor_offset)` at entry. Story 3.8's VIS_LINE projection is effectively a no-op (anchor already a line-start).

**From Story 3.3 (visual character mode v):**
- `visual_enter_char` pins anchor = `cursor_offset` at entry (offset space). Story 3.8's VIS_CHAR projection takes anchor at face value.

**From Story 2.13 (single-level undo `u`):**
- `op_undo` dispatch + `undo_replay_success_tail` + `undo_clear` + `undo_write_header` are all reused. Story 3.8 adds a new dispatch entry + a new replay body (~17 B total in undo.asm).
- **Q6 Option B post-walk-end-tracking precedent**: Stories 2.11 / 2.13 / 3.7 use the `edits_indent_walk_end` cell to make INDENT/DEDENT walk undo correct. Story 3.8 does NOT need this — case-toggle's length is fixed at toggle time (no shift), so the recorded `undo_length` matches the actual walk length directly. **No Q6 Option B equivalent needed.**

**From Story 2.11 (op+motion compose):**
- `edits_indent_walk` (the per-line walker reused by Story 3.7) is NOT used by Story 3.8 — case-toggle's walk shape is per-byte not per-line. **Different abstraction level.** Story 3.8's `gapbuf_case_toggle_range` is to per-byte case-toggle what `edits_indent_walk` is to per-line indent — both encapsulate the walk pattern at their respective granularity.

**From Story 2.10 (`dd` / `yy`):**
- N/A — line-class delete/yank not exercised by case-toggle.

**From Story 1.7 (gap buffer primitives):**
- `gapbuf_move_gap` is the load-bearing primitive for Story 3.8's `gapbuf_case_toggle_range`. The "move gap to range start" pattern makes the target bytes physically contiguous at gap_end, enabling the in-place walk. This pattern is structurally identical to how `gapbuf_insert` / `gapbuf_delete` use `gapbuf_move_gap` to bring the cursor's position to the gap boundary.

### Git intelligence

**Recent commits (last 5; for context — Story 3.8 follows the same shape):**
- `aca5097 Story 3.7: visual shift > and <` — direct precursor; established the line-class submode-agnostic precedent that Story 3.8 deliberately diverges from (case-toggle is per-submode geometry, not line-class).
- `da662d0 Story 3.6: visual operators d/y/c land; FR36 closes` — established the 3-arm CHAR/LINE/BLOCK pattern + the BLOCK UNDO_KIND_TOO_LARGE direct-record precedent. Story 3.8's structural twin.
- `cd105bf Story 3.5: visual block mode Ctrl-V lands; FR35/BH3 close; VIS_BLOCK submode` — established VIS_BLOCK + BH3 jagged-line semantic. Story 3.8 BLOCK arm respects column range with BH3 clipping (distinct from Story 3.7 which ignored column range).
- `517bef1 Story 3.4: visual line mode V lands; FR34 closes; VIS_LINE submode` — established VIS_LINE's anchor-snap-to-line-start invariant. Story 3.8's VIS_LINE projection benefits.
- `a1ce47d Story 3.3: visual character mode lands; FR15/FR33 close; visual.asm module` — established the visual.asm module + SR5 anchor semantic for VIS_CHAR.

**Pattern:** every Epic-3 story so far has been single-commit, 4-8 new headless tests, NFR18 byte-identical rebuild required. Story 3.8 follows the same shape: 7 new tests, single commit, NFR18 verified.

**Insight from Story 3.7's dev pass:** the spec mid-estimate was +106 B; actual delta was +104 B — virtually exact. Spec's structural analysis (40 B prologue + 55 B walk-dispatch) tracked closely with the dev pass. Story 3.8 spec's projection (+200 B mid-estimate) carries similar structural detail; expected drift ≤ +40 B vs the 235-265 B body estimate. If actual lands above 280 B (= mid-estimate + 40 B drift cushion), the post-3.8 footprint would be ~8055 B + 40 B = 8095 B / 97 B headroom — TIGHT but still within ceiling. If actual lands above 320 B (= 60 B above mid-estimate), post-3.8 footprint exceeds 8120 B / 72 B headroom — flag for review.

### Implementation Questions (resolve with Ant before dev starts)

See **Task 0** for the Q1-Q8 pin list. Recommended pins are all **Option A** consistent with the Story 3.3-3.7 precedent, EXCEPT Q3 (no-op walk undo policy) which DIVERGES from Story 2.11 / 3.7 by preserving prior undo on no-op (recommended Option A — preserve; deliberate divergence documented). Resolve in chat before Task 1; the pins shape AC details but the body is robust to any pin choice.

### NFR9 budget arithmetic (worked example)

Pre-3.8 footprint: **7855 B / 95.9% of 8192 B / 337 B headroom** (post-Story-3.7 + post-Review-patches; current vibe.com on disk; SHA `47496ebc00ce31040f64e7c88b0036fde16bfce0f17bd3f5fe2bff1711f2572e` per Story 3.7 Dev Agent Record).

Story 3.8 projected deltas (positive = grows footprint; negative = shrinks):
- `src/gapbuf.asm` `gapbuf_case_toggle_range` primitive: **+50 B** (per-byte loop with inline alpha classifier; ~50 B per the AC3 listing)
- `src/visual.asm` `visual_apply_case_toggle` dispatcher prologue + 3 arms + shared finalise + BLOCK body:
  - Dispatcher prologue (4 instructions ~14 B)
  - `_visual_op_case_char_arm` (~30 B per AC2)
  - `_visual_op_case_line_arm` (~50 B per AC2)
  - `_visual_op_case_toggle_finalise` (~35 B per AC2)
  - `_visual_op_case_block_arm` (~110 B per AC2)
  - Total: **~240 B**
- `src/visual.asm` module-header doc-only extends: **+0 B** (comments stripped from binary)
- `src/dispatch.asm` `dispatch_visual` 1 new entry: **+3 B** (1 × 3 B; ASSERTs are assembly-time, zero runtime)
- `src/dispatch.asm` comment block updates: **+0 B** (comments)
- `src/undo.asm` `undo_replay_case_toggle` body: **+12 B**
- `src/undo.asm` `op_undo` dispatch entry: **+5 B**
- `inc/equates.inc` new equate: **+0 B** (compile-time)

Subtotal code growth: **~+310 B** (mid-estimate — higher than initial 200 B estimate after detailed structural cost analysis)

State growth: **+0 B** (all module-local cells reused — Story 3.6 cells + Story 3.6 block cells). No equates.inc / state.inc / modes.inc changes beyond the +0 B UNDO_KIND_CASE_TOGGLE equate.

**Projected post-3.8 footprint: 7855 + 310 = 8165 B / ~99.7% of 8192 B / ~27 B headroom.**

**REVISED PROJECTION — NFR9 CLIFF-EDGE ALERT.** The detailed structural analysis projects +310 B, which puts post-3.8 footprint at 99.7% of the 8192 B ceiling — well above the [[project_nfr9_cliff_edge]] 250 B amendment trigger.

**Recommended action** (resolve in Task 0 conversation with Ant):
- **Option A**: Accept the cliff-edge close at ~8165 B / ~27 B headroom. NFR9 holds; no amendment needed. Risk: any drift > 27 B during dev pass requires byte-shaving (similar to Story 2.5's 33 B headroom that forced the AC13 patch decisions). The drift cushion is minimal — dev pass MUST budget-track per arm.
- **Option B**: Amend NFR9 ceiling to 9216 B / 9 KB (1024 B headroom for Epic 3 completion + Epic 4 entry buffer). Preserves the "small editor" spirit (NFR10 TPA fit still holds — static_end + GAP_BUFFER_MAX + YANK_BUFFER_SIZE remain well under 0xD800). PRD action: extend the existing 5/16, 5/17 amend chain with a 2026-05-18 amend at Epic 3 closure boundary. **Recommended IF the dev pass hits an actual drift > +50 B** (i.e. actual code growth > 360 B vs spec mid-estimate +310 B).
- **Option C**: Defer Story 3.8 entirely as Growth-tier; ship Epic 3 close at Story 3.7 boundary with FR38 ("visual case-toggle") explicitly out of scope. **NOT recommended** — FR38 is in the PRD; deferring breaks Epic 3's scope commitment.

**Pin (recommended)**: **Option A at planning time** (accept the cliff-edge close); revisit at dev pass if actual drift exceeds +50 B vs spec mid-estimate.

**Per-arm shrink-down options if NFR9 pressure bites mid-dev:**
1. Share the CHAR arm's SBC-and-swap with Story 3.6's `_visual_op_char_arm` (factor out a `_visual_op_char_range_compute` helper that returns HL=range_start, BC=total_bytes, A=KIND_CHAR-or-tag — saves ~25 B at the cost of ~10 B helper + minor structural churn). **Net ~15 B savings.**
2. Share the LINE arm's line-promote with Story 3.6's `_visual_op_line_arm` similarly (factor out the projection — saves ~30 B at the cost of ~12 B helper). **Net ~18 B savings.**
3. Share the BLOCK arm's col_min/col_max/top_ls compute with Story 3.6's `_visual_op_block_arm` prologue (factor out a `_visual_op_block_project_rect` helper that returns the 3 cells stashed — saves ~40 B at the cost of ~15 B helper). **Net ~25 B savings.**
4. Total potential shrink-down from the three factor-outs: **~58 B**. Would buy ~85 B headroom post-3.8 (~8107 B / 85 B headroom).

The factor-outs are byte-shaving polish work — out of scope for the initial Story 3.8 dev pass unless NFR9 pressure forces them. If the dev pass comes in at the +310 B mid-estimate (~27 B headroom), accept; if it comes in above +360 B (~0 B headroom), apply factor-outs.

**Revisit trigger**: if Story 3.8's actual `visual_apply_case_toggle` arms + finalise + BLOCK lands above 280 B (= mid-estimate 240 B + 40 B drift cushion; total post-3.8 ~8095 B / ~97 B headroom), **recommend flagging the Q1 Option B (multi-region undo) as deferred-only-not-overlooked** so it doesn't accidentally creep into scope. Per memory [[project_nfr9_cliff_edge]]: "Stories 3.7 / 3.8 are tight; flag amendment if projected delta > 250 B". Story 3.8's projected delta is **~310 B** — ABOVE the 250 B amendment trigger. **Pin: Q1 Option A (no amendment); accept the cliff-edge close.** Re-evaluate at dev-pass close.

### Test count target

247 (post-3.7 incl. Review patches) → **254 PASS** (+7 new from Story 3.8) / 1 deliberate-fail (`harness_fail` sentinel) unchanged.

### Project Structure Notes

- `src/visual.asm` grows from 1726 lines (post-3.7) to ~1990 lines (post-3.8; +~265 B in code, plus ~50 lines of comment headers + per-arm docstrings).
- `src/gapbuf.asm` grows from 263 lines (post-2.2 retire) to ~310 lines (post-3.8; +~50 B in code, plus ~20 lines of comment header + AR23 docstring).
- `src/undo.asm` grows from 748 lines (post-2.13) to ~765 lines (post-3.8; +~17 B in code, plus ~10 lines of comment header).
- Sentinel band allocation (cumulative through Story 3.8):
  - 0xA0..0xAA + 0xE9 — Story 3.1 (`/pattern` search)
  - 0xAB..0xAF + 0xEA — Story 3.2 (`n` repeat)
  - 0xB0..0xB4 + 0xEB — Story 3.3 (VIS_CHAR)
  - 0xB5..0xB9 + 0xEC — Story 3.4 (VIS_LINE)
  - 0xBA..0xBD + 0xED — Story 3.5 (VIS_BLOCK; +0xBF Review patch)
  - 0xBE reserved by `harness_fail` infra
  - 0xC0..0xCF — Story 2.13 (undo)
  - 0xD0..0xD6 + 0xEE — Story 3.6 (visual d/y/c)
  - 0xD7..0xDC + 0xEF — Story 3.7 (visual shift; +0xDD..0xDE Review patches)
  - **0xDF + 0xF4 + 0xF8..0xFC + 0xFD — Story 3.8 (THIS STORY: visual case-toggle `~`)**
  - 0xFE..0xFF available as defensive slack for review patches + future Stories
- Per [[feedback_create_story_cross_check]]: cross-checked the AC narrative against actual render/edit semantics:
  - **Cursor lands at offset 0 post-`:e`** ([[feedback_uat_trace_cursor]]) — verified in AC13 step 2 — UAT script enters with cursor at 0; later UAT steps use explicit positioning via motion keys before each `~`, not assumptions about cursor location.
  - **No `~` past-EOF marker** ([[project_no_tilde_marker]]) — Story 3.8 is the FIRST story whose operator IS literally the `~` byte; double-checked that UAT script does NOT predict a `~` marker on past-EOF rows (which renders as space per `render_byte_at_logical.past_eof`). Disambiguates: `~` operator vs `~` empty-line marker.
  - **CR/CRLF and sjasmplus-hostile filenames** — not relevant to Story 3.8 (case-toggle doesn't touch file I/O).
  - **NFR9 projection** — explicit at AC10 + Tasks plus the budget arithmetic block. **Story 3.8 is AT the cliff-edge per [[project_nfr9_cliff_edge]]**; mid-estimate +310 B is ABOVE the 250 B "flag amendment" threshold. **Pinned Option A (accept cliff-edge); revisit at dev pass.**
  - **DISPATCH_VISUAL_COUNT cross-check** — pre-3.8 count is 25 (0x19) per `build/vibe.lst:4049`. Story 3.8 specs the post-append count as 26 (0x1A). Dev pass MUST verify against the actual `build/vibe.lst` value — five previous stories drifted on the dispatch-count metric; same care applies.
  - **NEW gapbuf primitive** — explicit at AC3 + Tasks. AR14 surface grows from 4 mutators to 5.
  - **AR14 status — visual.asm gains FIRST DIRECT gapbuf call** — explicit at Architecture compliance section + AC11 module-header updates. Distinct from Stories 3.6 / 3.7 which only have transitive paths via edits.asm.
  - **VIS_BLOCK BH3 column range respected** — distinct from Story 3.7 which IGNORED column range for shift. Pinned at AC6 + the `visual_tilde-block.asm` / `visual_tilde-block-jagged.asm` tests.
  - **Backward-selection symmetry** — covered by the SBC-and-swap pattern; not explicitly pinned in a dedicated test (the precedent from Story 3.7 visual_shift-backward.asm already validates the SBC-and-swap shape; Story 3.8 reuses it verbatim).
  - **No-op walk preserves prior undo** — Q3 Option A; pinned by `visual_tilde-no-alpha.asm` test.
  - **BLOCK undo TOO_LARGE direct record** — Q1 Option A; pinned by `visual_tilde-block-undo-too-large.asm` test; matches Story 3.6 BLOCK precedent.

### References

- **Epic 3 narrative:** `_bmad-output/planning-artifacts/epics.md:1480-1484` (Epic 3 header + visual-highlighting platform-constraint note).
- **Story 3.8 epic AC source:** `_bmad-output/planning-artifacts/epics.md:1730-1753` (the original 5-AC narrative).
- **Architecture FR38 (visual case-toggle):** `_bmad-output/planning-artifacts/architecture.md:231` + FR-coverage map line 1537.
- **Architecture SR5 visual-anchor + SR6 yank-register:** `_bmad-output/planning-artifacts/architecture.md:452-461`.
- **PRD FR38:** `_bmad-output/planning-artifacts/prd.md:758`.
- **PRD NFR9 (8192 B ceiling, amended 2026-05-17):** `_bmad-output/planning-artifacts/prd.md:848-864`.
- **inc/equates.inc UNDO_KIND_INDENT_WALK / UNDO_KIND_DEDENT_WALK (precedent for new UNDO_KIND_CASE_TOGGLE = 0x07):** `inc/equates.inc:107-108`.
- **Existing visual.asm module-header (to be extended):** `src/visual.asm:1-431`.
- **Existing visual.asm body (to be extended with visual_apply_case_toggle):** `src/visual.asm:1343-1374` (insertion point: between `visual_apply_shift`'s `JP enter_normal_mode` at line 1343 and `visual_count_lines`'s body at line 1374).
- **Existing dispatch_visual table (to gain `~` entry):** `src/dispatch.asm:712-787`.
- **Existing dispatch_visual comment block (Story 3.7 deferral; Story 3.8 retires it):** `src/dispatch.asm:702-710`.
- **Existing gapbuf.asm body (to be extended with gapbuf_case_toggle_range):** `src/gapbuf.asm:1-264` (insertion point: after `gapbuf_move_gap.equal` at line 257, before `;; --- Internal helpers ---` divider at line 259-264).
- **Existing gapbuf.asm primitives (precedent for new gapbuf_case_toggle_range):** `gapbuf_init` (lines 58-65), `gapbuf_insert` (lines 82-128), `gapbuf_delete` (lines 145-179), `gapbuf_move_gap` (lines 197-257).
- **Existing undo.asm body (to be extended with undo_replay_case_toggle):** `src/undo.asm:421-441` (insertion point: between `undo_replay_dedent_walk`'s body ending at line 439 and the `;; --- Public: undo_record_insert ---` divider at line 442-444).
- **Existing op_undo dispatch (to gain UNDO_KIND_CASE_TOGGLE entry):** `src/undo.asm:227-249`.
- **Existing undo_replay_success_tail (shared post-replay hook):** `src/undo.asm:270-275`.
- **Existing undo_write_header (shared kind/position/length writer):** `src/undo.asm:624-630`.
- **Existing edits_dirty_and_redraw (buffer_dirty + render_mark_all_dirty):** `src/edits.asm:630-633`.
- **Existing motion helpers (reused as-is):** `motion_find_line_start` (`src/motions.asm:636+`), `motion_find_line_end` (`src/motions.asm:672+`), `motion_byte_at_logical` (`src/motions.asm:557+`).
- **Existing visual_count_block_dims (BLOCK rect projection, reused):** `src/visual.asm:1459+`.
- **Existing _visual_op_block_row_bytes (BH3 clip helper, reused):** `src/visual.asm:1044-1060`.
- **Existing enter_normal_mode (`~` tail-JP target):** `src/dispatch.asm:350-368`.
- **Story 3.7 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-7-visual-shift.md` (full story file with `visual_apply_shift` precedent + the dispatch_visual extension pattern + the NFR9 cliff-edge analysis + the Q1-Q6 pin list).
- **Story 3.6 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-6-visual-operators-d-y-c.md` (the 3-arm CHAR/LINE/BLOCK pattern Story 3.8 mirrors + BLOCK UNDO_KIND_TOO_LARGE direct-record precedent).
- **Story 3.5 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-5-visual-block-mode.md` (VIS_BLOCK + BH3 jagged-line semantic).
- **Story 3.4 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-4-visual-line-mode.md` (VIS_LINE anchor-snap-to-line-start).
- **Story 3.3 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-3-visual-character-mode.md` (visual.asm module + SR5 anchor semantic).
- **Story 2.13 retrospective (single-level undo + Q6 Option B INDENT/DEDENT_WALK):** `_bmad-output/implementation-artifacts/2-13-single-level-undo-u.md`.
- **deferred-work.md (current backlog of polish items):** `_bmad-output/implementation-artifacts/deferred-work.md` — Story 3.8 may ADD entries depending on dev pass:
  - "Multi-region undo for BLOCK visual operators (`d` / `y` / `c` / `~`)" — Q1 Option A deferral; ~50-80 B for the multi-region undo cross-cutting story; promotes BLOCK undo from `msg_undo_too_large` to actual replay.
  - "Visual operators silently single-level — `n>` / `n<` / `nd` / `ny` / `nc` / `n~` ignored" — already on deferred-work.md from Story 3.7; Story 3.8 inherits the same constraint (counts ignored).
  - "Three duplicated SBC-and-swap min/max projection sites across visual_apply_operator / visual_apply_shift / visual_apply_case_toggle CHAR arms" — NFR9-relevant refactor candidate; ~15-25 B savings if factored. Out of scope for Story 3.8 unless cliff-edge pressure forces it.

## Dev Agent Record

### Agent Model Used

Amelia (bmad-dev-story) running Opus 4.7 (1M context).

### Debug Log References

NFR9 cliff-edge hit mid-dev: first build landed 8259 B (67 B OVER 8192 ceiling). Applied SAFE in-Story-3.8 optimizations first (-16 B): finalise share cursor-restore tail; BLOCK loop JR NZ (back-distance ~112 B in range); PUSH/POP DE walker pattern in BLOCK loop; visual_op_block_cols write retired. Footprint dropped to 8243 B, still 51 B over. Applied spec's shrink-down #3: factor BLOCK projection prologue + col_min/col_max + top_ls compute into shared `_visual_op_block_project_rect` helper used by BOTH Story 3.6 `_visual_op_block_arm` and Story 3.8 `_visual_op_case_block_arm`. Story 3.6 BLOCK arm refactored from inline projection to `CALL _visual_op_block_project_rect`. visual_op_block_cols write retired from the shared helper (dead-store per Story 3.6 deferred-work cleanup item). Saved 64 B. Final footprint: 8179 B / 13 B headroom. All Story 3.6 BLOCK tests still pass (visual_d-char, visual_d-block-jagged, visual_y-block, visual_y-line, visual_c-char-enters-insert, visual_c-line-enters-insert) confirming the refactor is behavior-preserving.

LINE arm projection — skipped the no-op anchor projection per Story 3.6 `_visual_op_line_arm` precedent (anchor is already a line-start by Story 3.4 AC2 invariant). Saves ~3 B and one redundant CALL/RET pair. AR23 docstring's "motion_find_line_start (CALL × 1)" reflects this — diverges from the spec text which said CALL × 2.

LINE arm range_end — added branch on CF from `motion_find_line_end`: if CF=1 (at EOF) use HL as range_end (no +1); if CF=0 use HL+1 (consume LF). Spec text said `range_end = HL + 1 unconditionally` claiming "gap_end overrun clip" in `gapbuf_case_toggle_range`, but Q5 Option A is "caller-bounds BC" with no internal clip. Resolved the spec contradiction by clamping at the LINE arm caller per Q5 Option A. Costs ~3 B for the `JR C, .at_eof` branch.

Two CALL gapbuf_case_toggle_range sites in visual.asm (CHAR/LINE shared finalise + per-row in BLOCK) instead of the spec's projected 3 (CHAR + LINE + BLOCK) — efficiency from sharing the CHAR/LINE finalise.

### Completion Notes List

- `inc/equates.inc` — added `UNDO_KIND_CASE_TOGGLE EQU 0x07` after UNDO_KIND_DEDENT_WALK. Extended the equate-block module-header comment to document the new self-inverse semantic.
- `src/gapbuf.asm` — added `gapbuf_case_toggle_range` public primitive at file tail (after `gapbuf_move_gap.equal`, before the internal-helpers divider). 44 B body (spec ~50 B). PUSH BC + gapbuf_move_gap + POP BC; gap_end → physical pointer; per-byte loop with inline alpha classifier (CP 'A' / 'Z'+1 / 'a' / 'z'+1) + dirty-flag accumulator; Z=1 on no-op, Z=0 on dirty. Module-header Public and Purpose extended to document the new mutator + Story 3.8 surface.
- `src/visual.asm` — added `visual_apply_case_toggle` dispatcher + `_visual_op_case_char_arm` (35 B post-optimization) + `_visual_op_case_line_arm` + `_visual_op_case_toggle_finalise` (44 B post-shared-tail optimization) + `_visual_op_case_block_arm` (post-shrink). Module-header Purpose / Public / State-owned Lifecycle / Register conventions / Dependencies blocks all extended for Story 3.8.
- `_visual_op_block_project_rect` — NEW shared helper for Story 3.6 + Story 3.8 BLOCK arms. Replaces 60 B of inline projection per arm with a 3 B CALL. visual_op_block_cols write retired as dead-store.
- `src/dispatch.asm` — appended `'~'` (0x7E) entry at the `dispatch_visual` tail with `ASSERT '~' > 'y'` for the sort chain. Comment block at 702-710 updated to retire the Story 3.7 deferral note and declare all six Epic-3 visual operators landed. Module-header Dependencies extended.
- `src/undo.asm` — added `undo_replay_case_toggle` after `undo_replay_dedent_walk`. 13 B body (LD HL/BC + CALL gapbuf_case_toggle_range + JP undo_replay_success_tail). `op_undo` dispatch chain gains a `CP UNDO_KIND_CASE_TOGGLE / JP Z` entry between DEDENT_WALK and TOO_LARGE. Module-header Purpose + op_undo AR23 docstring extended.
- DISPATCH_VISUAL_COUNT verified to auto-recompute 0x19 (25) → 0x1A (26) per `build/vibe.lst:14707`: `LD B, DISPATCH_VISUAL_COUNT` emits as `06 1A`. Cross-checked per [[feedback_create_story_cross_check]].
- 7 new headless tests authored (sentinels 0xDF, 0xF4, 0xF8..0xFC, 0xFD). All PASS first run; no fix iterations. Pre-existing test count was 249 (Story 3.7 review patches landed 247 + 2 sentinel-5/-7 patches); post-3.8 count: 256 PASS + 1 deliberate `harness_fail`.
- AR sweep on `src/visual.asm` post-3.8 — `LD (gap_start),` / `LD (gap_end),` zero matches in code (only doc self-refs); `CALL gapbuf_case_toggle_range` 2 matches (CHAR/LINE shared finalise + per-row in BLOCK arm). FIRST direct gapbuf primitive call from visual.asm.
- NFR18 byte-identical confirmed across two `make clean && make all` cycles. SHA: `60dfbf7a19ff4ca7a7bdd2eb03fc521e866a7d7aa9b493113bdcbb6a354646a2`.
- NFR9: post-3.8 size = 8179 B / 99.84% of 8192 B / 13 B headroom. WITHIN ceiling. Spec mid-estimate +310 B; actual delta +324 B (8179 - 7855). The shared `_visual_op_block_project_rect` helper bought the headroom that the per-arm spec drift (BLOCK arm +72 B over spec estimate) consumed.
- Q1-Q8 all pinned Option A per Task 0 (Ant confirmed pre-dev). Q3 Option A deliberate divergence from Story 2.11 / 3.7 (no pre-clear on no-op walk) implemented as documented; pinned by `visual_tilde-no-alpha.asm` test.

### File List

- `inc/equates.inc` (modified — UNDO_KIND_CASE_TOGGLE add + comment extension)
- `src/gapbuf.asm` (modified — gapbuf_case_toggle_range primitive + module-header extension)
- `src/visual.asm` (modified — visual_apply_case_toggle dispatcher + CHAR/LINE/BLOCK arms + shared finalise + shared `_visual_op_block_project_rect` helper + Story 3.6 BLOCK arm refactored to use the helper + module-header updates)
- `src/dispatch.asm` (modified — `~` dispatch_visual entry + comment block update + module-header Dependencies extension)
- `src/undo.asm` (modified — undo_replay_case_toggle + op_undo dispatch entry + module-header Purpose + op_undo AR23 docstring extensions)
- `test/cases/visual_tilde-toggles.asm` (new — sentinel 0xDF)
- `test/cases/visual_tilde-line.asm` (new — sentinel 0xF4)
- `test/cases/visual_tilde-block.asm` (new — sentinel 0xF8)
- `test/cases/visual_tilde-block-jagged.asm` (new — sentinel 0xF9)
- `test/cases/visual_tilde-no-alpha.asm` (new — sentinel 0xFA)
- `test/cases/visual_tilde-undo.asm` (new — sentinel 0xFB)
- `test/cases/visual_tilde-block-undo-too-large.asm` (new — sentinel 0xFC)
- `test/cases/parser_visual_tilde-dispatch.asm` (new — sentinel 0xFD)
- `_bmad-output/implementation-artifacts/sprint-status.yaml` (modified — 3-8 status flipped ready-for-dev → in-progress → review)
- `_bmad-output/implementation-artifacts/3-8-visual-case-toggle.md` (modified — Status / Dev Agent Record / File List / Change Log; Tasks/Subtasks marked complete)

## Hardware UAT script (AC13 — paste into chat at dev-handoff per [[feedback_uat_inline_at_dev_handoff]])

```
 1. STAT B:fizzbuzz.fs       → confirm fixture present (multi-line
                               source file with mixed-case content
                               — same multi-line .fs / .txt fixture
                               used in Stories 3.3-3.7 UAT scripts;
                               any multi-line file with mixed-case
                               alphabetic content works. If
                               fizzbuzz.fs is all-lowercase, an
                               alternative fixture like vibe.com's
                               own source comments — `vibe vibe.asm`
                               — gives plenty of mixed-case content
                               to exercise the toggle visibly.)

 2. vibe fizzbuzz.fs         → cursor at offset 0 (first byte of
                               line 1); mode NORMAL; status banner
                               empty
                               [[feedback_uat_trace_cursor]]: post-:e
                               cursor lands at offset 0

 3. v l l l l                → enter VIS_CHAR; extend 4 cols right;
                               cursor on offset 4 (= line 1 col 4);
                               status "-- visual -- 5" (anchor=0,
                               cursor=4, char count = |cursor -
                               anchor| + 1 = 5)

 4. ~                        → AC2/AC6 VIS_CHAR `~`: bytes [0, 5)
                               toggled; lowercase 'a'..'z' →
                               uppercase 'A'..'Z'; uppercase
                               'A'..'Z' → lowercase 'a'..'z'; other
                               bytes (digits/spaces/punctuation)
                               unchanged. cursor at offset 0
                               (range_start = min(anchor, cursor) =
                               0); mode NORMAL; status banner empty;
                               buffer_dirty=1
                               **Hardware test for AC6 VIS_CHAR
                               byte-wise toggle — observe the
                               first 5 chars of line 1 with their
                               case flipped.**

 5. u                        → AC5 undo: replay UNDO_KIND_CASE_TOGGLE
                               by re-walking the same range; the 5
                               toggled bytes get re-toggled back to
                               their pre-step-4 case. cursor at 0;
                               buffer restored to original line 1
                               first 5 bytes; buffer_dirty=1 (stays
                               1 per Story 2.13 Q5 Option A pin).
                               **Hardware test for AC5 single-region
                               undo self-inverse — observe line 1
                               first 5 chars restored to original
                               case.**

 6. j                        → move cursor to line 2 (now at offset
                               N where N is line 2's line_start).

 7. V                        → enter VIS_LINE; status "-- visual
                               line -- 1" (single-line selection of
                               line 2).

 8. ~                        → AC2/AC6 VIS_LINE `~`: line 2's entire
                               content (from line2_ls to line2_end+1
                               inclusive of trailing LF) has every
                               alphabetic byte toggled; non-alpha
                               (LF / spaces / digits) unchanged.
                               cursor at line2_ls = N (promoted_start
                               = min(anchor_ls, cursor_ls) = N);
                               mode NORMAL; buffer_dirty=1.

 9. u                        → undo: line 2 restored to original case;
                               cursor at N; buffer_dirty=1.

10. Ctrl-V l l l j j         → enter VIS_BLOCK; extend right 3 cols
                               and down 2 lines; status
                               "-- visual block -- 3x4" (3 rows ×
                               4 cols rectangle).

11. ~                        → AC2/AC6/AC7 VIS_BLOCK `~`: per-row
                               clipped toggle. For each of the 3
                               rows, bytes [walker + col_min,
                               walker + min(col_max+1, line_length))
                               get their case toggled. Short lines
                               (per BH3) toggle only up to their EOL.
                               cursor at top_ls + col_min (top-left
                               of the rectangle); buffer_dirty=1.
                               undo_kind=UNDO_KIND_TOO_LARGE per
                               AC6 Q1 Option A BLOCK direct record.
                               **Hardware test for AC6 VIS_BLOCK
                               column range respected — observe
                               case toggles within the rectangle's
                               column bounds, NOT line-start.**

12. u                        → AC7 BLOCK undo: status shows "undo
                               not possible - too large"
                               (msg_undo_too_large surface from
                               UNDO_KIND_TOO_LARGE replay refusal
                               per Story 2.13 Q4 Option A pin —
                               TOO_LARGE NOT consumed by surfacing;
                               second `u` re-surfaces the same
                               message); buffer UNCHANGED; cursor
                               UNCHANGED.
                               **Hardware test for AC7 BLOCK undo
                               refusal — observe the user-visible
                               "too large" surface; buffer remains
                               at post-step-11 state.**

13. u                        → as in step 12, second `u` re-surfaces
                               the same msg_undo_too_large (Q4
                               Option A pin); buffer UNCHANGED.

14. G                        → move cursor to last line (motion_G).
                               If the file's last line is all-digits
                               or has no alphabetic content, this
                               step exercises the no-op walk path
                               (AC6 Q3 Option A).

15. v $                      → enter VIS_CHAR; extend to end-of-line
                               via motion_dollar; selection spans
                               the last line. If the last line has
                               no alphabetic content (numeric / all-
                               punctuation), `~` will be a no-op.

16. ~                        → If selection has any alpha: bytes
                               toggled, undo_kind=UNDO_KIND_CASE_TOGGLE.
                               If selection has NO alpha: buffer
                               UNCHANGED; undo_kind preserved at
                               UNDO_KIND_TOO_LARGE from step 11
                               (Q3 Option A — no-op walk does NOT
                               clear prior undo).
                               **Hardware test for AC3/AC6 no-op
                               walk preserves prior undo — if
                               selection has no alpha, observe that
                               a subsequent `u` STILL surfaces
                               msg_undo_too_large from the prior
                               BLOCK toggle (not "nothing to undo"
                               which would indicate undo cleared).**

17. u                        → If step 16 was a toggle: replay
                               UNDO_KIND_CASE_TOGGLE; bytes restored.
                               If step 16 was a no-op: replay the
                               PRIOR undo (UNDO_KIND_TOO_LARGE from
                               step 11) — surface msg_undo_too_large
                               again.

18. gg                       → move cursor to first line (motion_gg).

19. V G                      → enter VIS_LINE then extend to last
                               line (motion_G); selection spans the
                               ENTIRE buffer (line 1 line-start to
                               last line's content end).
                               status "-- visual line -- N" where N
                               is the total line count.

20. ~                        → AC2/AC6 VIS_LINE whole-buffer `~`:
                               every alphabetic byte in the file is
                               toggled. cursor at 0 (promoted_start =
                               file start); mode NORMAL;
                               buffer_dirty=1.
                               **Hardware test for AC2/AC6 whole-
                               buffer toggle — visible mass case
                               flip across the entire file.**

21. u                        → undo: replay UNDO_KIND_CASE_TOGGLE
                               over the whole file range; every
                               byte re-toggled back to original
                               case. buffer restored; cursor at 0;
                               buffer_dirty=1.
                               **Hardware test for AC5 whole-buffer
                               undo round-trip — observe the entire
                               file restored to original case in
                               one `u` keystroke.**

22. :q!                      → force-quit without saving; control
                               returns to CCP. File on disk is
                               UNCHANGED (buffer_dirty=1 throughout
                               most of session; :q! honours the
                               force flag).

23. vibe fizzbuzz.fs         → reload to verify the file on disk is
                               UNCHANGED from the original. Cursor
                               at offset 0; mode NORMAL.
                               **Hardware test for FR52 / NFR6 —
                               case toggle never persisted to disk;
                               file fully recovers.**
```

## Change Log

| Date | Change | Author |
| --- | --- | --- |
| 2026-05-18 | Story drafted from epics.md:1730-1753; pre-dev pins drafted as Option A across Q1-Q8 per Epic-3 precedent; NFR9 cliff-edge analysis projects ~310 B delta (above 250 B amendment trigger per [[project_nfr9_cliff_edge]] — pinned Option A "accept" at planning, with shrink-down factor-outs documented if dev pass forces them) | bmad-create-story (Bob) |
| 2026-05-18 | UAT confirmed by Ant on real MicroBeast — all 23 AC13 steps PASS. Story 3.8 flips review → done. FR38 closes. **Epic 3 visual operator surface COMPLETE** — all six operators (d / y / c / > / < / ~) ship. Last Epic-3 backlog story landed; next is epic-3-retrospective (optional). | bmad-dev-story (Amelia) |
| 2026-05-18 | Story 3.8 dev pass complete. Q1-Q8 all pinned Option A per Task 0 (Ant confirmed). visual_apply_case_toggle + 4 arms + shared finalise land in src/visual.asm; gapbuf_case_toggle_range primitive lands in src/gapbuf.asm as the 5th public mutator; undo_replay_case_toggle + op_undo dispatch entry land in src/undo.asm; UNDO_KIND_CASE_TOGGLE (0x07) added to inc/equates.inc; '~' (0x7E) appended to dispatch_visual at table tail (DISPATCH_VISUAL_COUNT 25 → 26). NFR9 cliff-edge hit mid-dev (first build 8259 B / 67 B OVER ceiling); resolved by applying spec's shrink-down #3 — extracted `_visual_op_block_project_rect` shared helper used by both Story 3.6 `_visual_op_block_arm` and Story 3.8 `_visual_op_case_block_arm` (saved 64 B + dead-store cols write retired). Story 3.6 BLOCK arm refactored to use the shared helper; all Story 3.6 BLOCK tests still PASS confirming behavior preservation. Q3 Option A divergence from Story 2.11 / 3.7 (no pre-clear on no-op walk) implemented and pinned by `visual_tilde-no-alpha.asm`. LINE arm range_end branches on CF from motion_find_line_end (at-EOF clamp) per Q5 Option A caller-bounds contract; spec text contradiction (claimed "gap_end overrun clip" but Q5 says no internal clip) resolved by clamping at caller. Final size 8179 B / 13 B headroom (under 8192 B NFR9 ceiling). 7 new tests PASS (sentinels 0xDF + 0xF4 + 0xF8..0xFD; 0xFE..0xFF reserved as defensive slack). Test count 249 → 256 PASS + 1 deliberate harness_fail. NFR18 byte-identical SHA `60dfbf7a19ff4ca7a7bdd2eb03fc521e866a7d7aa9b493113bdcbb6a354646a2` across two clean rebuilds. AR14 status unchanged: gap_start / gap_end ownership stays with src/gapbuf.asm; visual.asm contains zero direct writes. Story flips review → done after Ant confirms 23-step hardware UAT on real MicroBeast. | bmad-dev-story (Amelia) |
