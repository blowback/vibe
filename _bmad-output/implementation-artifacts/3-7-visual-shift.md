# Story 3.7: Visual shift (>, <)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `>` and `<` in MODE_VISUAL (any submode) to shift every line that the selection touches right or left by one `INDENT_BYTE` (0x20 = space — same byte as Story 2.11's `>>` / `<<` / `> + motion` / `< + motion` per `inc/equates.inc:75`), with the per-line walk routed through the existing `edits_indent_walk` helper (mode = 0 for `>`, mode = 1 for `<`), single-level undo recording the inverse op via `edits_record_walk` → `undo_record_indent_walk` / `undo_record_dedent_walk` (UNDO_KIND_INDENT_WALK / UNDO_KIND_DEDENT_WALK reused from Story 2.13's Q6 Option B record helpers — replay re-walks with the mode flipped per `undo_replay_indent_walk` / `_dedent_walk`), `<` on a line whose first byte is not INDENT_BYTE silently skipped (per-line no-op; other lines in the selection still process — the existing `.iw_dedent` arm's `CP INDENT_BYTE ; JR NZ, .iw_advance` guard handles this for free), the line-promote range computed in a submode-agnostic projection (`motion_find_line_start(min(anchor, cursor))` → `motion_find_line_end(max-line-start) + 1` — VIS_LINE's anchor is already a line-start so its projection is a no-op; VIS_BLOCK's column range is IGNORED because the epic AC says shift applies "at line start" not at the rectangle's left edge — matches vim's `>` / `<` semantics in visual-block mode), cursor placement at the top-of-selection's line_start post-shift, and mode returning to NORMAL via `enter_normal_mode`,
So that FR37 closes — completing the line-class visual operators atop the existing Story-2.11 indent/dedent + Story-2.13 undo machinery (the sibling Story 3.8 visual case-toggle `~` shares the per-line submode-agnostic projection shape but operates byte-wise rather than line-start-wise; this story sets the precedent that the visual shift-class operators reuse the NORMAL-mode `edits_indent_walk` infrastructure rather than re-implementing per-line gap-buffer writes).

## Acceptance Criteria

**AC1 — `dispatch_visual` gains two sorted entries `<` (0x3C) and `>` (0x3E), each forward-referencing `visual_apply_shift` in `src/visual.asm`. Insertion slots between `'9'` (0x39) and `'G'` (0x47); ASCII-sorted; `DISPATCH_VISUAL_COUNT` auto-recomputes 23 → 25.**

**Given** `src/dispatch.asm:dispatch_visual` (currently 23 entries post-3.6 — verified via `build/vibe.lst:4016` `DISPATCH_VISUAL_COUNT EQU 0x17`; the sort order runs Esc / `$` / `0`..`9` / G / b / c / d / g / h / j / k / l / w / y at `src/dispatch.asm:685-753`; operators `>` / `<` are documented as "remain deferred — they fall through to unbound_visual until those stories land" at the comment block at `src/dispatch.asm:676-683` — that deferral comment retires with Story 3.7)
**When** Story 3.7 lands
**Then** two new 3-byte entries are inserted in ASCII-sorted positions:
- `'<'` (0x3C) — between `'9'` (0x39) at line 719-720 and `'G'` (0x47) at line 722-723 — slot 1
- `'>'` (0x3E) — between `'<'` (0x3C — new) and `'G'` (0x47) — slot 2

**And** each entry's `DEFW` targets `visual_apply_shift` (the single shared dispatcher — A on entry is the operator byte `'<'` or `'>'` per MC4, branches internally on A to set the indent/dedent mode flag)
**And** the flanking `ASSERT` chain is repaired:
- `ASSERT '<' > '9'` (new — replaces the existing `ASSERT 'G' > '9'` at line 721 since `<` sorts between them)
- `ASSERT '>' > '<'` (new)
- `ASSERT 'G' > '>'` (MODIFIED — was `ASSERT 'G' > '9'`)
**And** `DISPATCH_VISUAL_COUNT` (the `($ - .entries) / 3` EQU at line 754) auto-recomputes from 0x17 (23) → 0x19 (25). Cross-check `build/vibe.lst` post-build per [[feedback_create_story_cross_check]] — past stories have drifted on this metric (Story 3.6's spec said 20 → 23; verified actual).
**And** `dispatch_visual` table grows by **+6 B** (2 entries × 3 B; ASSERTs are assembly-time, zero runtime)
**And** the dispatch.asm module-header Dependencies block's `src/visual.asm` entry (extended by Stories 3.3 / 3.4 / 3.5 / 3.6) extends by one Story-3.7 paragraph documenting `visual_apply_shift` as the fifth forward-ref symbol after `visual_enter_char` (3.3), `visual_enter_line` (3.4), `visual_enter_block` (3.5), and `visual_apply_operator` (3.6).
**And** the Story-3.6 comment block at `src/dispatch.asm:676-683` ("Operators `d` / `y` / `c` bound to `visual_apply_operator` (Story 3.6); `>` / `<` (Story 3.7) and `~` (Story 3.8) remain deferred …") is REPLACED with a comment noting that `d` / `y` / `c` bind to `visual_apply_operator` (Story 3.6), `>` / `<` now bind to `visual_apply_shift` (Story 3.7), and only `~` remains deferred to Story 3.8.
**And** `dispatch_normal` is UNCHANGED — `>` and `<` in NORMAL still route to `parser_handle_operator` at lines 571-575 (the op+motion compose path from Story 2.11 that drives `op_compose_indent` / `op_compose_dedent` / `op_indent_line` / `op_dedent_line`). The visual bindings are deliberately separate handlers; visual shift bypasses the parser's `pending_operator` state machine entirely.

**AC2 — `visual_apply_shift` (NEW public entry in `src/visual.asm`) is the single dispatcher: A on entry = `'<'` | `'>'`; stashes the operator into the reused `visual_op_pending` 1-byte cell (Story 3.6 module-local), projects anchor and cursor to line_starts, line-promotes to `[promoted_start, promoted_end)`, dispatches `edits_indent_walk` with the appropriate mode (0 = indent for `>`; 1 = dedent for `<`), records UNDO_KIND_INDENT_WALK / UNDO_KIND_DEDENT_WALK via `edits_record_walk` iff `edits_indent_walk_dirty == 1`, places cursor at `promoted_start`, tail-JPs `enter_normal_mode`.**

**Given** `src/visual.asm` (the public block at lines 67-83 currently lists `visual_apply_operator` as LANDS (Story 3.6) with siblings `>` / `<` (Story 3.7) and `~` (Story 3.8) "remain placeholders"; the comment was extended by Story 3.6 to document the sibling deferral)
**When** Story 3.7 lands
**Then** `visual_apply_shift:` is added as a NEW labelled public entry in `src/visual.asm`, placement chosen for code locality (recommended placement: between `_visual_op_delete_yank_or_change`'s body ending at line 1115 and `visual_count_lines`'s body starting at line 1146 — shift operator sits right after the d/y/c shared finalisation, mirroring the order of operations during a typical visual session "enter → extend → operate")
**And** the body performs in order:
1. `LD (visual_op_pending), A` — stash the operator key in the existing module-local 1-byte cell (reused from Story 3.6 AC11; the cell is module-local scratch, valid only for the lifetime of one operator dispatch) (~3 B)
2. **Project anchor's line_start** via `motion_find_line_start` — submode-agnostic (VIS_LINE's anchor is already a line-start so the call is a no-op; VIS_CHAR / VIS_BLOCK need projection; calling unconditionally costs ~25 cycles per visit on already-aligned offsets but saves a CP submode check) (~10 B)
3. **Project cursor's line_start** via `motion_find_line_start` (~10 B)
4. **Compute `promoted_start = min(anchor_ls, cursor_ls)`** via SBC-and-swap (same pattern as `visual_extend.char_arm` from Story 3.3 + `_visual_op_block_arm`'s top_ls compute from Story 3.6) (~20-25 B). Stash `promoted_start` in `visual_op_range_start` (reused Story 3.6 cell — same lifecycle).
5. **Walk to MAX line-start's line-end** via `motion_find_line_end` (HL = max(anchor_ls, cursor_ls) at entry; returns HL = LF pos OR file_length, CF=1 on no-LF) (~6 B)
6. **Compute `promoted_end = HL + 1`** unconditionally — when HL = LF position, +1 lands past the LF (consume it); when HL = file_length (CF=1 case), +1 lands at file_length+1 which is strictly > bot_ls so the walk still includes the bottom line on the iteration that starts at bot_ls. **No at-EOF carve-out needed** (unlike Story 3.6 LINE arm which DELETES line content and must consume the leading-LF of the line ABOVE; Story 3.7's `edits_indent_walk` operates on per-line line_starts in `[promoted_start, promoted_end)` and inserts at line_start — the bottom line's line_start is included as long as `bot_ls < promoted_end`). (~1 B)
7. **Stash undo metadata** mirroring `op_compose_indent.ci_walk` at `src/edits.asm:1707-1711`:
   - `LD (edits_indent_undo_start), HL` — wait, HL holds promoted_end at this point; we need to load promoted_start first. Body reorders so that HL = promoted_start, DE = promoted_end at this step.
   - `LD (edits_indent_undo_start), HL` (~3 B)
   - `EX DE, HL ; LD (edits_indent_undo_end), HL ; EX DE, HL` (~5 B) — Q6 Option B pin from Story 2.13 (the cell exists but `edits_indent_walk_end` is the post-walk authority that `edits_record_walk` actually reads — `edits_indent_undo_end` is now dead-store legacy; we set it for symmetry with the four existing call sites in edits.asm; deferred-work entry from Story 2.13 logged a cleanup pass for these dead stores)
   - `CALL undo_clear` — defensive pre-clear (~3 B; matches Story 2.11 / 2.13 invariant "every mutating op records SOMETHING")
8. **Branch on operator → mode** for `edits_indent_walk`:
   - `LD A, (visual_op_pending) ; CP '<' ; LD A, 0 ; JR NZ, .have_mode` (default = indent mode 0; if NZ — meaning A was '>' which is NOT '<' — keep 0)
   - Wait — the test is `CP '<'`. After the `LD A, 0` immediately after the CP, the flags are clobbered. Need to reorder: `LD A, (visual_op_pending) ; CP '<' ; LD A, 0 ; JR NZ, .have_mode ; INC A` (A = 1 = dedent mode)
   - Alternative cleaner shape: `LD A, (visual_op_pending) ; XOR '>' ; ADD A, A` — when A == '>' (0x3E), XOR yields 0, ADD yields 0 (indent mode); when A == '<' (0x3C), XOR yields 0x02, ADD yields 0x04 — NOT 0x01. So the bit pattern doesn't naturally map. Stick with the CP + branch:
   - **Recommended shape**: `LD A, (visual_op_pending) ; SUB '<' ; OR A` (now A = 0 if dedent ('<'), 2 if indent ('>')); `JR Z, .dedent_mode ; XOR A` (A = 0 indent mode); `.have_mode: CALL edits_indent_walk` — but we still need A = 1 for dedent. Just:
   - **Simplest correct shape** (~10 B):
     ```
     LD A, (visual_op_pending)
     CP '<'
     LD A, 0           ; indent mode (default)
     JR NZ, .iw_mode_ready
     INC A             ; A = 1 (dedent mode)
     .iw_mode_ready:
     CALL edits_indent_walk
     ```
     The `LD A, 0` after `CP '<'` clobbers the Z flag — but the `LD A, immediate` form does NOT touch flags. ✓
9. `CALL edits_indent_walk` — walk every line in `[promoted_start, promoted_end)`; mutates the gap buffer per mode (indent: insert INDENT_BYTE at each line_start; dedent: delete leading INDENT_BYTE if present, silent skip otherwise) (~3 B)
10. **Check `edits_indent_walk_dirty`**:
    - `LD A, (edits_indent_walk_dirty) ; OR A ; JR Z, .no_change` (~7 B)
11. **Dirty path** — record undo:
    - `LD A, (visual_op_pending) ; CP '<' ; LD A, UNDO_KIND_INDENT_WALK ; JR NZ, .have_kind ; LD A, UNDO_KIND_DEDENT_WALK` (~12 B)
    - `.have_kind: CALL edits_record_walk` (the shared post-walk record helper from Story 2.13 — reads `edits_indent_walk_end` POST-walk for length; tail-JPs `undo_write_header`) (~3 B)
    - `CALL edits_dirty_and_redraw` (mark buffer_dirty + dirty-row bitmap) (~3 B)
12. **`.no_change`** (or falling through from the dirty path):
    - `LD HL, (visual_op_range_start) ; LD (cursor_offset), HL` — cursor lands at promoted_start (= top_ls; vi-faithful "top-of-selection") (~6 B)
13. `JP enter_normal_mode` — tail-JP; the existing handler flips `mode_byte = MODE_NORMAL`, emits empty `msg_mode_normal` banner, tail-JPs `parser_clear` (~3 B)
**And** total `visual_apply_shift` body: **~95-115 B** at the prologue + range-compute + walk-dispatch + undo-record + cursor-place + tail-JP stage.
**And** AR23 docstring documents: `In: A = operator byte ('<' | '>' — MC4 from dispatch_visual)`; `Out: every line whose start is in [min(anchor_ls, cursor_ls), max(anchor_ls, cursor_ls)+...)] is shifted right (>) or left (<) by one INDENT_BYTE; for '<' lines without leading INDENT_BYTE are silent per-line no-ops via the inherited edits_indent_walk dedent guard; cursor placed at promoted_start; mode_byte = MODE_NORMAL via enter_normal_mode tail-JP; undo recorded as UNDO_KIND_INDENT_WALK / _DEDENT_WALK iff edits_indent_walk_dirty == 1 (no-op walks leave undo EMPTY per Story 2.11 precedent — documented vi-divergence).`; `Trashes: A, BC, DE, HL, F + module-local cells (visual_op_pending, visual_op_range_start, edits_indent_undo_start / _end, edits_indent_walk_mode / _dirty / _end).`; `Calls: motion_find_line_start (CALL × 2 — anchor + cursor projection); motion_find_line_end (CALL × 1 — walk MAX line-start to its line-end); undo_clear (CALL); edits_indent_walk (CALL); edits_record_walk (CALL on dirty path); edits_dirty_and_redraw (CALL on dirty path); enter_normal_mode (JP tail).`

**AC3 — Line-promote projection is submode-agnostic. Anchor and cursor are both fed through `motion_find_line_start`; the helper is a fast no-op when the input is already a line-start (loop terminates on the first iteration when `HL == 0` or when the byte at `HL - 1` is `0x0A`). VIS_CHAR / VIS_LINE / VIS_BLOCK all converge on the same `[promoted_start, promoted_end)` shape after the projection.**

**Given** the three visual submodes' anchor semantics:
- VIS_CHAR (Story 3.3 SR5): `visual_anchor = cursor_offset` at entry (offset space; ANY position within a line)
- VIS_LINE (Story 3.4 AC2): `visual_anchor = motion_find_line_start(cursor_offset)` at entry (already a line-start by invariant)
- VIS_BLOCK (Story 3.5 SR5): `visual_anchor = cursor_offset` at entry (offset space; ANY position within a line; column is derived on-demand by `visual_count_block_dims`)

**When** `visual_apply_shift` projects:
**Then** the projection sequence is:
1. `LD HL, (visual_anchor) ; CALL motion_find_line_start` — HL = anchor_ls (no-op-ish for VIS_LINE; actual walk for VIS_CHAR / VIS_BLOCK)
2. `LD HL, (cursor_offset) ; CALL motion_find_line_start` — HL = cursor_ls
3. SBC-and-swap to compute `min(anchor_ls, cursor_ls) = promoted_start` and the OTHER (max) as the walker-line-start whose line-end we walk to find promoted_end
**And** for VIS_BLOCK specifically: the rectangle's COLUMN range is COMPLETELY IGNORED. Shift acts at line-start regardless of `anchor_col` / `cursor_col`. This is vi-faithful — vim's `>` / `<` in visual-block mode operates on the ROW range, not the column range. (Documented inline as a comment + in module-header Public block entry for `visual_apply_shift`.)
**And** because Story 3.6's `_visual_op_block_arm` documented BH3 jagged-line semantic as "per-row clipping at the operator path's responsibility", Story 3.7's shift specifically does NOT do per-row column-bounded operations — the shift is line-class. The shift operator is the FIRST FR37/FR38 operator class that ignores BLOCK's column dimension (FR36 d/y/c respect it; FR37 >/< don't; FR38 ~ will respect it per epic AC line 1741 — "for VIS_BLOCK, the per-row clipping rule applies"). Story 3.8 will need to re-introduce the per-row column-bounded path; Story 3.7 inherits zero of that complexity.
**And** **edge case — `visual_anchor == cursor_offset`** (anchor and cursor coincide; happens on bare `v` then `>` with no motion in between): anchor_ls == cursor_ls → promoted_start == promoted_end seed; promoted_end = walker_line_end + 1 > promoted_start. Walk processes 1 line (the cursor's line). Single-line shift. Vi-faithful: `v>` is functionally identical to `>>` on the current line (but goes through a different code path).
**And** **edge case — backward selection** (cursor moved UP from anchor, so cursor_ls < anchor_ls): SBC-and-swap takes cursor_ls as promoted_start, walks anchor_ls's line-end. Symmetric to forward.

**AC4 — Walk dispatch through `edits_indent_walk` (Story 2.11 helper; mode byte 0 = indent, 1 = dedent) handles the per-line work. The walk's body is unchanged — Story 3.7 is a thin caller that supplies the right `[HL, DE)` range + mode byte and relies on the helper for: per-line indent_byte insertion / dedent guard / `edits_indent_walk_dirty` flag / `edits_indent_walk_end` post-walk end stash. Story 2.13's Q6 Option B fix (the cell-based post-walk end tracking) propagates correctly to Story 3.7's call site.**

**Given** `src/edits.asm:edits_indent_walk` (lines 1937-2006) — the Story 2.11 helper that walks `[HL_start, DE_end)` line by line, inserting `INDENT_BYTE` per line (indent mode) or conditionally-deleting one leading INDENT_BYTE per line (dedent mode, with `CP INDENT_BYTE ; JR NZ, .iw_advance` as the per-line skip guard)
**When** Story 3.7's `visual_apply_shift` calls `edits_indent_walk` with `HL = promoted_start`, `DE = promoted_end`, `A = mode (0 indent / 1 dedent)`
**Then** the existing walk machinery handles all the per-line work:
- For `>` (indent mode A=0): each line in range gets one INDENT_BYTE inserted at its line-start; `gapbuf_insert` advances cursor by 1 per success; DE shifts +1 per insert (post-mutation stash to `edits_indent_walk_end`); `edits_indent_walk_dirty := 1` on at least one success.
- For `<` (dedent mode A=1): each line's first byte is checked; if `== INDENT_BYTE`, the byte is deleted via cursor-bounce (`INC HL ; LD (cursor_offset), HL ; CALL gapbuf_delete`); DE shifts −1 per delete; `edits_indent_walk_dirty := 1` on at least one delete. Lines without leading INDENT_BYTE skip to `.iw_advance` (silent per-line no-op — closes epic AC line 1714-1716 "`<` on a line that has no leading whitespace ... unchanged").
- For both modes: the walk terminates when `HL >= DE` (HL = current line_start; DE = post-walk effective end) OR when `motion_byte_at_logical` past-EOF after the per-line op (defensive — empty-buffer / past-bottom-line cases).
**And** `gapbuf_insert` overflow (CF=1 on `gapbuf` at capacity) causes the indent walk to RET C; `msg_file_too_large` is already surfaced by `gapbuf_insert` per Story 1.7's contract. Story 3.7 inherits this semantic — a visual `>` on a near-full gap buffer where total inserts would overflow leaves a partial shift in place + the file-too-large status. **Same shape as Story 2.11's `op_compose_indent` overflow behaviour** — `edits_indent_walk_dirty` may be 1 even on partial; the post-walk record will write UNDO_KIND_INDENT_WALK with the partial range (replay correctly walks the partial range via `edits_indent_walk_end`).
**And** **no new edits.asm code** is needed by Story 3.7 — the helper is reused as-is. Story 3.7 modifies edits.asm by ZERO lines (the previously-deferred "clean up the 4 dead `LD (edits_indent_undo_end), HL` stores" mini-task from Story 2.13's deferred-work line 424 is NOT addressed here; out of scope).
**And** the mode byte map (`A=0 → indent`, `A=1 → dedent`) is documented in `src/edits.asm:1929` already; no documentation patch needed for the helper itself. The Story 3.7 caller's docstring documents the mode-byte mapping for the operator-byte-to-mode-byte translation.

**AC5 — Undo recording: post-walk, `visual_apply_shift` reads `edits_indent_walk_dirty`. On `dirty == 1`, calls `edits_record_walk` with `A = UNDO_KIND_INDENT_WALK` (for `>`) or `UNDO_KIND_DEDENT_WALK` (for `<`); the helper reads `edits_indent_walk_end` (post-walk authoritative end), computes `length = end - start`, tail-JPs `undo_write_header`. On `dirty == 0` (no-op walk: `<` on selection with no leading INDENT_BYTE on any line), the undo register stays at UNDO_KIND_EMPTY from the `undo_clear` pre-walk. `u` replays via `undo_replay_indent_walk` / `undo_replay_dedent_walk` (Story 2.13 — unchanged).**

**Given** the Story 2.13 single-level undo machinery (`src/undo.asm`) + Story 2.11's `edits_record_walk` shared helper (`src/edits.asm:2434`) + the Q6 Option B post-walk-end-tracking pattern (the `edits_indent_walk_end` cell, updated by `edits_indent_walk` at every iter head + after every per-line mutation per `src/edits.asm:1951, 1970, 1990`)
**When** Story 3.7's visual shift completes the walk
**Then** the undo contract per operator:
- **`>`** (indent): if `edits_indent_walk_dirty == 1`, record `UNDO_KIND_INDENT_WALK` via `edits_record_walk(A=UNDO_KIND_INDENT_WALK)` which reads start from `edits_indent_undo_start` and length from `edits_indent_walk_end - start`; tail-JPs `undo_write_header`. On `u` post-shift: `undo_replay_indent_walk` (at `src/undo.asm:421`) calls `edits_indent_walk` with mode=1 (dedent — inverse op) over `[position, position+length)`; cursor lands at position; buffer restored.
- **`<`** (dedent): if `edits_indent_walk_dirty == 1`, record `UNDO_KIND_DEDENT_WALK` via `edits_record_walk(A=UNDO_KIND_DEDENT_WALK)`. On `u`: `undo_replay_dedent_walk` (at `src/undo.asm:431`) calls `edits_indent_walk` with mode=0 (indent — inverse).
- **No-op walks** (typically `<` on a selection where no line has a leading INDENT_BYTE): `edits_indent_walk_dirty == 0`; `visual_apply_shift` skips the record + `edits_dirty_and_redraw`; the undo register stays UNDO_KIND_EMPTY from the pre-walk `undo_clear`. **`u` after no-op `<` shows `msg_nothing_to_undo`** ("nothing to undo") — same shape as op_compose_dedent's no-op pathway (`src/edits.asm:1786-1787`). Pin this is the SAME vi-divergence as Story 2.11's documented "no-op dedent clears prior undo to EMPTY" precedent.

**And** **documented vi-divergence** (inherited from Story 2.11 / 2.13 Q6 Option B): `undo_replay_dedent_walk` re-walks with indent mode; lines that were originally a per-line no-op in the dedent (had no leading INDENT_BYTE) WILL acquire an INDENT_BYTE on replay. The dedent's inverse walk is unconditional indent — same per-line shape as `>` itself. Recoverable with a manual `<` over the affected range.
**And** **undo capacity**: `edits_record_walk` writes a (kind, position, length) header only (no payload — replay re-walks). No `UNDO_PAYLOAD_SIZE` capacity check; the worst-case length is `file_length` (whole-buffer shift). Even pathological selections fit cleanly. **Pin: no TOO_LARGE path for visual shift** — distinct from Story 3.6 d/c which can hit UNDO_KIND_TOO_LARGE on 257+-byte payloads.

**AC6 — Cursor placement: post-shift, cursor lands at `promoted_start` (= min(anchor_ls, cursor_ls); the LINE-START of the topmost selected line). Matches vim's "top of selection" cursor after visual `>` / `<`. Vi's "first non-whitespace of the line" finer placement is post-MVP polish (no `motion_first_non_whitespace` helper exists yet; Story 2.11 deferred-work logs the same gap for NORMAL-mode `>>` / `<<`).**

**Given** the walk has completed; `edits_indent_walk` left `cursor_offset` somewhere in the LAST line of the walked range (post-mutation, between line_start and the next INC HL advance)
**When** `visual_apply_shift` resets the cursor
**Then** the body performs:
1. `LD HL, (visual_op_range_start) ; LD (cursor_offset), HL` — restore cursor to promoted_start (~6 B)
**And** rationale: `promoted_start` is the line_start of the TOPMOST selected line, which DOES NOT MOVE during the walk (the walk inserts at each line's start; the topmost line's start stays at offset `promoted_start` because no inserts happen before it). For `<` no-op walks, promoted_start is the topmost selected line's start; same offset. For partial-overflow walks (where `gapbuf_insert` returned CF=1 mid-walk), promoted_start is STILL the topmost line's start which hasn't moved. ✓
**And** **vi divergence** (documented): vim places cursor at the first non-whitespace character of the topmost selected line. VIBE places cursor at the line_start (column 0) of the topmost selected line. Closing this gap requires a `motion_first_non_whitespace` helper which doesn't exist in MVP — same gap that `>>` / `<<` / `> + motion` have in NORMAL mode per Story 2.11. **Deferred to a polish story when FNW is needed**; tracked in `_bmad-output/implementation-artifacts/deferred-work.md`.
**And** for VIS_LINE selections specifically, the placement is identical to vim because the line-start column is column 0 — which would also be the FNW column on a line that starts with non-whitespace. The divergence is only visible on indented lines (lines where FNW > 0).

**AC7 — INDENT_BYTE pin: SPACE (0x20). Documented in module header. Rationale: matches the existing Story 2.11 NORMAL-mode `>>` / `<<` / `> + motion` / `< + motion` choice (the `INDENT_BYTE EQU 0x20` declaration at `inc/equates.inc:75` already says "byte inserted/removed by >, <, >>, << (Stories 2.11, 3.7; readiness item #6)" — Story 3.7 is explicitly named); Forth source (MicroBeast's primary use case) conventionally uses spaces for indentation; consistent across all four shift entry points (NORMAL `>>`, NORMAL `> + motion`, VISUAL `>`, NORMAL `<<` / `< + motion` / VISUAL `<`); a tab-vs-space toggle is a Growth-tier feature (PRD §14 Out of Scope — "Configurable keymap" / future settings).**

**Given** `inc/equates.inc:75` `INDENT_BYTE EQU 0x20` already declares the convention with explicit reference to Stories 2.11 and 3.7
**When** Story 3.7 lands
**Then** no equate change is needed — `INDENT_BYTE` is reused as-is
**And** `src/visual.asm` module-header Purpose paragraph extends to document the choice with an inline note: "Story 3.7 — visual_apply_shift (`>` / `<`) lands. Reuses INDENT_BYTE (0x20 = space) per inc/equates.inc:75 — consistent with the four existing NORMAL-mode shift entry points (op_compose_indent / op_compose_dedent / op_indent_line / op_dedent_line) and per Forth-source convention. Tab support is a Growth-tier knob."
**And** **NOT** in scope: tab-vs-space, configurable indent width (single byte only), `>>` / `<<` count-prefix (handled in NORMAL via Story 2.11's `op_indent_line` count-prefix; visual mode operates on the visible selection, no count needed).

**AC8 — `src/visual.asm` module-header updates: AR14 status REMAINS "transitive writer" (no change from Story 3.6 — visual.asm now ALSO transitively writes via `edits_indent_walk → gapbuf_insert/gapbuf_delete`); the Public block flips `visual_apply_shift` from PLACEHOLDER to LANDS; the Dependencies block extends to document `edits_indent_walk` / `edits_record_walk` / `motion_find_line_start` / `motion_find_line_end` as newly-called symbols (the first two are NEW for Story 3.7; the motion helpers were already called by Story 3.4 / 3.6).**

**Given** `src/visual.asm` lines 1-326 (the module-header block, last updated by Story 3.6)
**When** Story 3.7 lands
**Then** the module-header updates:
- **Purpose** (lines 3-65): extend to mention "Story 3.7 — visual_apply_shift (`>` / `<`) lands. visual.asm gains a second transitive-writer path via `edits_indent_walk` → `gapbuf_insert` / `gapbuf_delete` (line-class shift; INDENT_BYTE = 0x20 per inc/equates.inc:75). AR14 ownership of gap_start / gap_end REMAINS with gapbuf.asm (no direct writes from visual.asm); the second mutation path joins the existing Story 3.6 `edits_range_delete` → `gapbuf_delete` path. Per-line work is inherited verbatim from Story 2.11's `edits_indent_walk` (including the `.iw_dedent` per-line `CP INDENT_BYTE ; JR NZ, .iw_advance` skip guard that realises the epic AC line 1714-1716 'silent per-line no-op for `<` on lines without leading INDENT_BYTE'). Undo via Story 2.13 Q6 Option B `UNDO_KIND_INDENT_WALK / _DEDENT_WALK` records; replay via `undo_replay_indent_walk / _dedent_walk` (mode-flipped re-walk)."
- **Public** (lines 67-83): add `visual_apply_shift ; LANDS Story 3.7 — (> / < on VIS_CHAR / VIS_LINE / VIS_BLOCK selections; FR37). The sibling visual_apply_case_toggle for ~ (Story 3.8) remains a placeholder.` Update the existing Story-3.6 comment about siblings to reflect that `>` / `<` are now LANDED.
- **State owned (read/write)** (lines 85-158): the Story-3.6 `visual_op_pending` cell is reused by Story 3.7 (operator-byte stash); the Story-3.6 `visual_op_range_start` cell is reused (promoted_start stash). NO new module-local cells are added for Story 3.7. Extend the existing Lifecycle note to document the Story 3.7 reuse.
- **Register conventions** (lines 168-326): add the `visual_apply_shift` In/Out/Trashes/Calls block per AC2's contract.
- **Dependencies** (lines 327+): the existing Story 3.6 `src/edits.asm` entry already covers backward-resolution of edits.asm symbols; Story 3.7 adds `edits_indent_walk` + `edits_record_walk` to the list of edits.asm symbols visual.asm CALLs. (Forward-resolution model unchanged — edits.asm INCLUDEs BEFORE visual.asm per AR25 chain; both new symbols are backward-resolved at parse time.)

**AC9 — `src/dispatch.asm` updates: the comment block at lines 676-683 (the Story-3.6 retire-of-Story-3.5's "operators remain unbound" comment) is REPLACED with a Story-3.7 narrative noting that `d` / `y` / `c` bind to `visual_apply_operator` (Story 3.6 — unchanged), `>` / `<` bind to `visual_apply_shift` (Story 3.7 — new), and only `~` remains deferred to Story 3.8. The module-header Dependencies block extends with a Story 3.7 paragraph documenting `visual_apply_shift` as the FIFTH forward-ref symbol from this module into `src/visual.asm`.**

**Given** the dispatch.asm comment block at `src/dispatch.asm:676-683` (extended by Story 3.6 to retire the Story 3.5 "operators remain unbound" comment in favour of "d/y/c bound; >/< (Story 3.7) and ~ (Story 3.8) remain deferred")
**When** Story 3.7 lands
**Then** the comment block at lines 676-683 is REPLACED with text along the lines of:
```
    ;; Story 3.7 — operators `>` / `<` bind to visual_apply_shift
    ;; (FR37; line-class shift via edits_indent_walk). `~` (Story 3.8)
    ;; remains deferred — it falls through to unbound_visual until
    ;; that story lands. Forward-referenced via sjasmplus two-pass.
```
**And** the module-header Dependencies block (the section ending around `src/dispatch.asm:185-202`) extends with a Story 3.7 paragraph documenting visual_apply_shift as the fifth forward-ref symbol after visual_enter_char (3.3), visual_enter_line (3.4), visual_enter_block (3.5), and visual_apply_operator (3.6).

**AC10 — Mode transition: `>` and `<` tail-JP `enter_normal_mode`. Per Story 3.6 AC10 — flips `mode_byte = MODE_NORMAL`, emits empty `msg_mode_normal` banner, tail-JPs `parser_clear` (which zeroes `count_accumulator` / `pending_operator` / `pending_motion_prefix` / `pending_motion_inclusive`). `visual_anchor` / `visual_submode` remain zombie state — same precedent.**

**Given** `visual_apply_shift` has completed (walk done, undo recorded if dirty, cursor placed)
**When** the final tail-JP fires
**Then** `JP enter_normal_mode` (the existing handler at `src/dispatch.asm:328-346` — UNCHANGED). The handler writes `mode_byte = MODE_NORMAL`, emits the empty banner via `msg_mode_normal`, and tail-JPs `parser_clear`.
**And** `visual_anchor` and `visual_submode` are UNCHANGED in state — same zombie-state contract as Stories 3.5 / 3.6. The next `v` / `V` / `Ctrl-V` re-pins both; the values are meaningless when `mode_byte != MODE_VISUAL` (SR4 invariant).
**And** **NO yank-too-large carve-out** is needed for shift — `>` / `<` don't touch the yank register at all. The Story 3.6 `visual_op_block_yank_ok` flag dance (to preserve `msg_yank_too_large` across the mode change) is NOT inherited by Story 3.7. The `enter_normal_mode` tail-JP is unconditional. Pin: the `msg_file_too_large` surface from `gapbuf_insert` overflow during indent walk WILL be clobbered by `enter_normal_mode`'s `msg_mode_normal` write — accepted as a known limitation (overflow during visual shift surfaces the status briefly, then gets overwritten; the buffer mutation is real and persists; user can detect via `buffer_dirty` and `:w` failure modes downstream). **Pin Q-list Q1**: pursue or accept? **Recommended Option A**: accept the clobber (matches Story 2.11 `op_compose_indent` precedent — the same `gapbuf_insert` overflow gets clobbered by `parser_clear`'s status reset on the NORMAL-mode `> + motion` path). Adding a flag-based carve-out costs ~15 B and protects a rare edge case; not worth it.

**AC11 — No state.inc / equates.inc / modes.inc changes. No new module-local cells in src/visual.asm. Story 3.7 reuses the Story 3.6 cells `visual_op_pending` (operator-byte stash) and `visual_op_range_start` (promoted_start stash). The Story 2.11 cells `edits_indent_undo_start` / `edits_indent_undo_end` / `edits_indent_walk_mode` / `edits_indent_walk_dirty` / `edits_indent_walk_end` (declared in `src/edits.asm:2370-2400`) are reused as-is. No equates.inc additions — `INDENT_BYTE` / `UNDO_KIND_INDENT_WALK` / `UNDO_KIND_DEDENT_WALK` all declared since Stories 2.11 / 2.13.**

**Given** the existing module-local state landscape
**When** Story 3.7 lands
**Then** the following cells are REUSED (no declarations added):
- `visual_op_pending` (declared `src/visual.asm:1483`; Story 3.6) — written by `visual_apply_shift` prologue; read by the mode-branch + undo-kind-branch
- `visual_op_range_start` (declared `src/visual.asm:1484`; Story 3.6) — written with promoted_start; read at the cursor-restore step
- `edits_indent_undo_start` (declared `src/edits.asm:2370`; Story 2.11 + 2.13) — written with promoted_start (mirrors `op_compose_indent` at line 1707); read by `edits_record_walk`
- `edits_indent_undo_end` (declared `src/edits.asm:2371`; Story 2.11) — written with promoted_end for symmetry with the 4 existing call sites; functionally dead-store post-Story-2.13 (the post-walk authority is `edits_indent_walk_end`); KEPT in Story 3.7 for callsite-consistency; the cleanup of the dead store across all 5 callers (post-Story-3.7) is a deferred-work polish item per `deferred-work.md:424`
- `edits_indent_walk_mode` (declared `src/edits.asm:2398`; Story 2.11) — written by `edits_indent_walk` itself from the A argument
- `edits_indent_walk_dirty` (declared `src/edits.asm:2399`; Story 2.11) — written by `edits_indent_walk` per-iter; read by `visual_apply_shift` post-walk
- `edits_indent_walk_end` (declared `src/edits.asm:2400`; Story 2.13 Q6 Option B) — written by `edits_indent_walk` per-iter; read by `edits_record_walk`
**And** total state growth in `src/visual.asm` module-local data: **+0 B** (all reuse)
**And** total state growth in `src/edits.asm` module-local data: **+0 B** (all reuse)
**And** **No `inc/state.inc` changes** — `static_off` does not advance; cold-start LDIR zero-fill does not extend.

**AC12 — Hardware UAT passes the visual-shift journey script on the real MicroBeast.**

**Given** I rebuild `vibe.com` with the Story-3.7 patch applied and `make push` it to MicroBeast
**When** I run the UAT script below from CCP
**Then** every step matches the predicted observation:

```
 1. STAT B:fizzbuzz.fs       → confirm fixture present (multi-line
                               source file — same as Stories 3.3 /
                               3.4 / 3.5 / 3.6 UAT'd against; any
                               multi-line .fs / .txt file works)
 2. vibe fizzbuzz.fs         → cursor at offset 0 (first byte of
                               line 1); mode NORMAL; status banner
                               empty
                               [[feedback_uat_trace_cursor]]: post-:e
                               cursor lands at offset 0
 3. V j                      → enter VIS_LINE; extend down 1 line;
                               status "-- visual line -- 2"
                               (anchor = line 1 line-start = 0;
                               cursor on line 2; rows = 2)
 4. >                        → AC2+AC4: indent walk over [0, line2_end+1).
                               line 1 gets one leading space; line 2
                               gets one leading space; buffer grows
                               by 2 bytes; cursor at offset 0 (top of
                               selection = promoted_start = 0); mode
                               = NORMAL; status banner empty
                               (msg_mode_normal pad); buffer_dirty=1
 5. u                        → AC5: replay UNDO_KIND_INDENT_WALK as
                               dedent walk; the 2 leading spaces
                               removed; cursor at offset 0; buffer
                               restored; buffer_dirty=1 (per
                               Story 2.13 Q5 Option A pin: buffer_dirty
                               stays 1 after undo, even if buffer
                               returns to last-saved state)
 6. V j                      → re-enter VIS_LINE; same 2-line range
 7. >                        → indent again; status banner empty
 8. >                        → wait — we're already in NORMAL after
                               step 7's tail-JP. Step 8's `>` is now
                               the NORMAL-mode `>` (operator;
                               parser_handle_operator) which sets
                               pending_operator='>' and waits for a
                               motion. Skip — re-enter VIS_LINE:
 8. V                        → enter VIS_LINE on the current (now-
                               indented) line; status "-- visual line
                               -- 1"
 9. <                        → AC2+AC4: dedent walk over [line1_ls,
                               line1_end+1); line 1's leading space
                               removed; buffer shrinks by 1; cursor
                               at offset 0; mode = NORMAL
10. <                        → as in step 8, the second `<` is NORMAL-
                               mode. Pre-undo this step:
10. u                        → AC5: replay UNDO_KIND_DEDENT_WALK as
                               indent walk; the leading space re-
                               inserted; buffer = state at end of
                               step 7's `>` ; cursor at offset 0
11. V                        → enter VIS_LINE on line 1 (which has 1
                               leading space — pre-existing from
                               steps 4+7)
12. <                        → dedent walk; line 1's leading space
                               removed (line goes back to no leading
                               whitespace); buffer shrinks; cursor at
                               offset 0; mode = NORMAL
13. V                        → enter VIS_LINE on line 1 (NO leading
                               whitespace now)
14. <                        → AC4+AC5: dedent walk's per-line guard
                               (`CP INDENT_BYTE ; JR NZ, .iw_advance`)
                               fires for line 1 — silent per-line no-
                               op; edits_indent_walk_dirty stays 0;
                               undo skip; cursor at offset 0; mode =
                               NORMAL; buffer UNCHANGED; status banner
                               empty
15. u                        → AC5: undo register is EMPTY (the no-op
                               walk skipped the record_walk call);
                               status shows "nothing to undo" via
                               msg_nothing_to_undo (Story 2.13 op_undo
                               EMPTY arm at src/undo.asm:225+)
16. j                        → move cursor to line 2 (the indented
                               line from step 7)
17. v l l l                  → enter VIS_CHAR; extend 3 cols right;
                               cursor on offset N+3 where N is line 2's
                               line_start; range = 4 chars on line 2
18. >                        → AC3: VIS_CHAR selection — but shift
                               line-promotes to whole-line range. The
                               4-char selection on line 2 gets line-
                               promoted to ALL of line 2 (start=line2_ls,
                               end=line2_end+1). One leading space
                               inserted at line2_ls; cursor at
                               line2_ls (promoted_start = TOP of
                               selection = line2_ls since both anchor
                               and cursor are on line 2); buffer_dirty=1;
                               mode = NORMAL
                               **Hardware test for AC3 line-promote
                               from VIS_CHAR — observe the entire line,
                               not just the 4-char selection, gets
                               shifted.**
19. u                        → undo: dedent walk replay; line 2's
                               leading space removed; buffer restored
                               (to state at end of step 12)
20. Ctrl-V l l l j j         → enter VIS_BLOCK; extend right 3 cols
                               and down 2 lines; status
                               "-- visual block -- 3x4"
21. >                        → AC3: VIS_BLOCK selection — column range
                               IGNORED; row range used as line-promote.
                               Lines [line2_ls, line2+2_end+1) all get
                               one leading space (NOT shifted at
                               column col_min!); cursor at line2_ls
                               (promoted_start); buffer grows by 3
                               bytes (one per line); mode = NORMAL;
                               buffer_dirty=1
                               **Hardware test for AC3 BLOCK column-
                               range-ignored — observe shifts happen
                               at line-start, NOT at the rectangle's
                               left column edge.**
22. u                        → undo: dedent walk replay; the 3 leading
                               spaces removed; buffer restored
23. v $                      → enter VIS_CHAR; extend to end-of-line
                               via motion_dollar; selection spans
                               line 1 from offset 0 to its EOL
                               (inclusive landing via Story 2.11's
                               pending_motion_inclusive flag — but
                               visual selections are ALWAYS inclusive
                               so the flag isn't read; same effect)
24. >                        → line-promote to line 1; one leading
                               space inserted at offset 0; cursor at
                               offset 0; mode = NORMAL
25. :q!                      → force-quit without saving; control
                               returns to CCP. File on disk is
                               UNCHANGED (buffer_dirty=1 throughout
                               most of session; :q! honours the force
                               flag).
26. vibe fizzbuzz.fs         → reload to verify the file on disk is
                               UNCHANGED from the original. Cursor at
                               offset 0; mode NORMAL.
```

**AC13 — N new headless tests under `test/cases/visual_*.asm` + 1 parser-dispatch test pass. Epic minimum is 3 (`visual_shift-right.asm` + `visual_shift-left.asm` + `visual_shift-left-no-leading.asm`). Story 3.7 lands 7 tests total: the 3 epic-minimums + 4 coverage extensions (VIS_CHAR line-promote, VIS_BLOCK column-ignored, backward-selection symmetry, parser-dispatch wiring).**

**Given** `make test` runs from a fresh tree
**When** the new test cases are added (sentinel band 0xD7..0xDC for the visual shift tests + 0xEF for the parser-dispatch coverage; 0xD0..0xD6 + 0xEE consumed by Story 3.6; 0xC0..0xCF by Story 2.13; 0xBA..0xBF by Story 3.5; 0xD7..0xDF available for Stories 3.7 / 3.8)
**Then** the following 6 visual-shift tests PASS:

- `visual_shift-right.asm` (sentinel 0xD7) — **EPIC MINIMUM** AC2 / AC4 / AC5 VIS_LINE `>` happy path. Buffer `"abc\ndef\nghi"` (11 B; LFs at 3, 7); cursor=0; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_LINE`, `visual_anchor = 0` (line 1 line-start per Story 3.4 AC2 — VIS_LINE anchor IS a line-start); pre-extend cursor=4 (somewhere in line 2 → cursor_ls=4 via motion_find_line_start). Range = whole lines 1 + 2 = `[0, 8)` = 8 bytes pre-walk. CALL `visual_apply_shift` with A='>'. Expect: `mode_byte = MODE_NORMAL`, `cursor_offset = 0` (promoted_start), buffer first 13 bytes = `" abc\n def\nghi"` (one space inserted at offset 0 = line 1 line-start; one space inserted at offset 5 — was offset 4 pre-walk, now shifted by +1 from line 1's insert — = new line 2 line-start), `gap_start` reflects +2 bytes file_length, `undo_kind = UNDO_KIND_INDENT_WALK`, `undo_position = 0`, `undo_length = 10` (pre-walk range size: lines 1+2 occupied 8 bytes pre-walk, +2 for the two inserts = 10 bytes post-walk per `edits_indent_walk_end` Q6 fix), `yank_kind` UNCHANGED (shift doesn't touch yank), `buffer_dirty = 1`.

- `visual_shift-left.asm` (sentinel 0xD8) — **EPIC MINIMUM** AC2 / AC4 / AC5 VIS_LINE `<` happy path on PRE-INDENTED buffer. Buffer `" abc\n def\nghi"` (13 B; LFs at 4, 9); cursor=0; pre-set VIS_LINE, visual_anchor=0, pre-extend cursor=5 (line 2). Range = lines 1 + 2 = `[0, 10)` pre-walk. CALL `visual_apply_shift` with A='<'. Expect: `mode_byte = MODE_NORMAL`, `cursor_offset = 0`, buffer first 11 bytes = `"abc\ndef\nghi"` (two leading spaces removed), `gap_start` reflects -2 bytes, `undo_kind = UNDO_KIND_DEDENT_WALK`, `undo_position = 0`, `undo_length = 8` (pre-walk range 10 bytes, -2 for the deletes = 8 bytes post-walk), `buffer_dirty = 1`.

- `visual_shift-left-no-leading.asm` (sentinel 0xD9) — **EPIC MINIMUM** AC4 / AC5 — `<` on a line whose first byte is NOT INDENT_BYTE: per-line silent no-op. Buffer `"abc\ndef"` (7 B; LF at 3); cursor=0; pre-set VIS_LINE, visual_anchor=0, cursor=0 (single-line selection of line 1). CALL `visual_apply_shift` with A='<'. Expect: `mode_byte = MODE_NORMAL`, `cursor_offset = 0`, buffer UNCHANGED (7 B `"abc\ndef"`), `gap_start` UNCHANGED, `undo_kind = UNDO_KIND_EMPTY` (no-op walk left undo at EMPTY from the pre-walk undo_clear — Story 2.11 precedent), `buffer_dirty` UNCHANGED from pre-call value (pre-seeded 0).

- `visual_shift-char-promotes.asm` (sentinel 0xDA) — AC3 VIS_CHAR line-promote coverage. Buffer `"abc\ndef\nghi"` (11 B; LFs at 3, 7); cursor=5 (line 2 col 1 = 'e'); pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_CHAR`, `visual_anchor = 5` (offset space, NOT line-start — VIS_CHAR anchor is offset per Story 3.3 SR5). CALL `visual_apply_shift` with A='>'. Expected: anchor projects via motion_find_line_start(5) = 4 (line 2 line_start); cursor projects via motion_find_line_start(5) = 4; min(4,4) = 4 = promoted_start; max = 4; walk to motion_find_line_end(4) = 7 (LF at offset 7); promoted_end = 8. Walk processes one line (line 2). Expect: `mode_byte = MODE_NORMAL`, `cursor_offset = 4` (promoted_start), buffer first 12 bytes = `"abc\n def\nghi"` (one space inserted at line 2's line_start = offset 4 pre-walk), `gap_start` reflects +1 byte, `undo_kind = UNDO_KIND_INDENT_WALK`, `undo_position = 4`, `undo_length = 5` (pre-walk line 2 was 4 bytes "def\n"; +1 for the insert = 5).

- `visual_shift-block-column-ignored.asm` (sentinel 0xDB) — AC3 VIS_BLOCK column-range-ignored coverage. Buffer `"abcd\nefgh\nijkl"` (14 B; LFs at 4, 9); cursor=0; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_BLOCK`, `visual_anchor = 2` (line 1 col 2 = 'c' — offset space per Story 3.5 SR5); pre-extend cursor=12 (line 3 col 2 = 'k'). Rectangle is 3 rows × 1 col (anchor_col=2, cursor_col=2, same column). CALL `visual_apply_shift` with A='>'. Expected: anchor_ls = motion_find_line_start(2) = 0; cursor_ls = motion_find_line_start(12) = 10; min = 0 = promoted_start; max = 10; walk to motion_find_line_end(10) = 13 (LF at offset 13... actually buffer is "ijkl" with NO trailing LF — file_length = 14; CF=1 returns HL = 14); promoted_end = 15. Walk processes all 3 lines. **Critical: shifts happen at line_start (offsets 0, 4, 9 pre-walk = 0, 5, 11 post-walk because each insert shifts subsequent line_starts by +1) — NOT at column 2 of each row.** Expect: `mode_byte = MODE_NORMAL`, `cursor_offset = 0` (promoted_start), buffer first 17 bytes = `" abcd\n efgh\n ijkl"` (three spaces inserted at line_starts; column range 2 IGNORED per AC3 BLOCK semantic), `gap_start` reflects +3 bytes, `undo_kind = UNDO_KIND_INDENT_WALK`, `undo_position = 0`, `undo_length = 17` (pre-walk range was 14 bytes; +3 for inserts = 17 bytes post-walk).

- `visual_shift-backward.asm` (sentinel 0xDC) — AC3 backward-selection symmetry. Buffer `"abc\ndef\nghi"` (11 B; LFs at 3, 7); cursor=4 (line 2 line-start); pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_LINE`, `visual_anchor = 4` (line 2 line-start); pre-extend cursor=0 (line 1 — BACKWARD selection: cursor_ls=0, anchor_ls=4; cursor_ls < anchor_ls). CALL `visual_apply_shift` with A='>'. Expected: anchor_ls = 4 (already line-start); cursor_ls = 0; min(0, 4) = 0 = promoted_start; max = 4; walk to motion_find_line_end(4) = 7 (LF); promoted_end = 8. Walk processes lines 1 + 2. Expect: `mode_byte = MODE_NORMAL`, `cursor_offset = 0` (promoted_start = min, NOT visual_anchor = 4 — vi-faithful "top of selection"), buffer first 13 bytes = `" abc\n def\nghi"`, `gap_start` reflects +2, `undo_kind = UNDO_KIND_INDENT_WALK`, `undo_position = 0`, `undo_length = 10`. **Pins the backward-selection min/max logic — if a future regression reverted to "promoted_start = anchor_ls" instead of "promoted_start = min(anchor_ls, cursor_ls)", this test would fail at the cursor_offset assertion (4 vs 0) and at the buffer-content assertion (wrong line shifted).**

**And** the parser-dispatch coverage test PASSES:
- `parser_visual_shift-dispatch.asm` (sentinel 0xEF) — AC1 end-to-end dispatch wiring. Buffer `"abc"` (3 B, no LF); pre-set `cursor_offset = 0`, `mode_byte = MODE_VISUAL`, `visual_submode = VIS_LINE`, `visual_anchor = 0`. Drive `'>'` (0x3E) through `dispatch_key` with `dispatch_visual`: `LD A, '>' ; LD HL, dispatch_visual ; LD B, DISPATCH_VISUAL_COUNT ; CALL dispatch_key`. Verify post-call: `mode_byte = MODE_NORMAL`, `cursor_offset = 0`, buffer first 4 bytes = `" abc"` (one leading space inserted), `gap_start` reflects +1, `undo_kind = UNDO_KIND_INDENT_WALK`, `undo_position = 0`, `undo_length = 4`. Confirms `dispatch_visual['>']` is wired end-to-end to `visual_apply_shift` AND the AC1 table-insertion landed in the right sorted slot (binary-search must find `>` between `9` and `G`).

**Test count target: 240 (post-3.6 incl. Review-patches) → 247 PASS (+7: 6 visual_shift tests + 1 parser-dispatch) / 1 deliberate-fail (`harness_fail` sentinel) unchanged.**

## Tasks / Subtasks

- [x] **Task 0** (pre-dev pin with Ant — Option A recommended across the board, consistent with Stories 3.3 / 3.4 / 3.5 / 3.6 precedent):
  - [x] Q1 — Accept `enter_normal_mode` status-clobber of `msg_file_too_large` on partial-overflow indent walk. **Recommended Option A** — accept; matches NORMAL-mode `op_compose_indent` precedent (same `parser_clear` clobber). Alternative Option B = preserve via flag-based mode-write inline (mirrors Story 3.6 AC7's yank_ok flag dance); rejected — costs ~15 B, protects a rare edge case (gap buffer near 32 KB capacity), and adds the same brittleness category that Story 3.6 deferred to refactor (F-17 in deferred-work). Pin Option A.
  - [x] Q2 — Cursor placement post-shift. **Recommended Option A** — cursor at promoted_start (= line_start of topmost selected line). Matches vim's `>` / `<` visual top-of-selection cursor (column 0, not FNW). Alternative Option B = cursor at first-non-whitespace of topmost line; rejected — no `motion_first_non_whitespace` helper exists in MVP; same gap Story 2.11 NORMAL-mode `>>` / `<<` has. Logged as a deferred-work polish item if FNW lands as a separate helper.
  - [x] Q3 — No-op walk undo policy. **Recommended Option A** — pre-clear undo via `undo_clear` unconditionally (mirrors `op_compose_indent.ci_walk` precedent); on a no-op walk (`edits_indent_walk_dirty == 0`), leave undo as EMPTY. **Documented vi-divergence**: subsequent `u` shows `msg_nothing_to_undo` even though a prior valid undo entry existed before the visual `<`. Alternative Option B = skip the pre-clear; preserve prior undo on no-op; rejected — diverges from Story 2.11's 4 existing indent/dedent ops which all pre-clear unconditionally; consistency wins over the corner-case preservation.
  - [x] Q4 — Test sentinel band. **Recommended Option A** — 0xD7..0xDC + 0xEF (6 visual_shift tests + 1 parser-dispatch). Leaves 0xDD..0xDE available for Story 3.8 (visual case-toggle expects ~5-6 tests per epic AC line 1750-1753). 0xDF reserved as defensive slack.
  - [x] Q5 — Commit strategy. **Recommended Option A** — single dev commit (matches Epic-3 single-commit pattern across all 6 prior Epic-3 stories).
  - [x] Q6 — Public symbol name. **Recommended Option A** — `visual_apply_shift` (handles both `>` and `<`; precedent from Story 3.6 `visual_apply_operator` sharing across d/y/c). Alternative Option B = `visual_apply_indent` + `visual_apply_dedent` (two symbols, one per operator); rejected — doubles dispatch_visual.asm forward-refs without any code-shrink benefit; the operator-byte branch is ~10 B inside the body anyway. Pin Option A — also aligns with the Story-3.6 module-header pin "`visual_apply_shift` (Story 3.7) ... remains placeholder".

- [x] **Task 1** — Extend `dispatch_visual` in `src/dispatch.asm`:
  - [x] 1.1 — Insert `'<'` (0x3C) entry between `'9'` (0x39) at line 719-720 and `'G'` (0x47) at line 722-723 per AC1. Replace the existing `ASSERT 'G' > '9'` at line 721 with `ASSERT '<' > '9'` flanking the new entry.
  - [x] 1.2 — Insert `'>'` (0x3E) entry between `'<'` (0x3C — new) and `'G'` (0x47) per AC1. Add `ASSERT '>' > '<'` flanking it. Replace the trailing `ASSERT 'G' > '9'` (now obsolete) with `ASSERT 'G' > '>'` (sort-chain repair).
  - [x] 1.3 — Both entries DEFW `visual_apply_shift` (forward-ref via sjasmplus two-pass per AC8's INCLUDE-order analysis — visual.asm INCLUDEs AFTER dispatch.asm in vibe.asm's AR25 chain; same forward-resolution pattern as visual_apply_operator from Story 3.6 / visual_enter_* from Stories 3.3-3.5).
  - [x] 1.4 — Verified `DISPATCH_VISUAL_COUNT` auto-recomputes 0x17 (23) → 0x19 (25) per `build/vibe.lst` (`787+ 0944 DISPATCH_VISUAL_COUNT EQU ($ - .entries) / 3` line resolves to 0x19; `LD B, DISPATCH_VISUAL_COUNT` emits as `06 19` at the dispatch_key call site). Cross-check per [[feedback_create_story_cross_check]] PASSED with no drift.
  - [x] 1.5 — Updated the comment block at `src/dispatch.asm:676-683` per AC9.
  - [x] 1.6 — Extended `src/dispatch.asm` module-header Dependencies block with a Story 3.7 paragraph documenting `visual_apply_shift` as the fifth forward-ref symbol.
  - [x] 1.7 — `dispatch_normal` UNCHANGED — `>` / `<` in NORMAL still route to `parser_handle_operator`.

- [x] **Task 2** — Add `visual_apply_shift` to `src/visual.asm`:
  - [x] 2.1 — Added `visual_apply_shift:` public entry between `_visual_op_delete_yank_or_change` and `visual_count_lines` per AC2; AR23 docstring above the label.
  - [x] 2.2 — Body landed: prologue → project anchor + cursor → SBC-and-swap → walk MAX line-end → promoted_end = HL + 1 → stash undo metadata → `undo_clear` → CP `<` mode branch → `CALL edits_indent_walk` → dirty check → on dirty: CP `<` kind branch → `CALL edits_record_walk` + `CALL edits_dirty_and_redraw` → cursor := promoted_start → `JP enter_normal_mode` tail.
  - [x] 2.3 — Inline + AR23 docstring covers AC3 (submode-agnostic projection), AC7 (INDENT_BYTE 0x20 reuse), AC10 (status-clobber Q1 Option A), and the FNW-deferral note.
  - [x] 2.4 — Module-header updates per AC8: Purpose extended with Story 3.7 paragraph; Public block flipped `visual_apply_shift` to LANDS; State-owned Lifecycle note documents Story 3.7 reuse of `visual_op_pending` + `visual_op_range_start`; Register-conventions block for `visual_apply_shift` added; Dependencies extended with the `edits_indent_walk` + `edits_record_walk` calls.
  - [x] 2.5 — AR sweep on `src/visual.asm` post-3.7 PASSED:
    - `BIOS_CONOUT` / `BDOS_CALL` / `CALL 0x0005` — zero matches in code (only comment self-refs).
    - `LD (gap_start),` / `LD (gap_end),` — zero matches in code (only comment self-refs).
    - `CALL gapbuf_insert` / `CALL gapbuf_delete` — zero matches.
    - `CALL edits_indent_walk` — 1 match in `visual_apply_shift` (line 1320).
    - `CALL edits_record_walk` — 1 match in `visual_apply_shift` (line 1335).

- [x] **Task 3** — Headless tests (7 new files in `test/cases/`):
  - [x] 3.1 — `visual_shift-right.asm` (sentinel 0xD7) — PASS.
  - [x] 3.2 — `visual_shift-left.asm` (sentinel 0xD8) — PASS.
  - [x] 3.3 — `visual_shift-left-no-leading.asm` (sentinel 0xD9) — PASS.
  - [x] 3.4 — `visual_shift-char-promotes.asm` (sentinel 0xDA) — PASS.
  - [x] 3.5 — `visual_shift-block-column-ignored.asm` (sentinel 0xDB) — PASS (undo_length = 18, NOT the spec's 17 — spec arithmetic underweighted the unconditional `INC HL` on the at-EOF promoted_end path; cross-checked the actual walk_end value per [[feedback_create_story_cross_check]] and pinned the test to the correct value).
  - [x] 3.6 — `visual_shift-backward.asm` (sentinel 0xDC) — PASS.
  - [x] 3.7 — `parser_visual_shift-dispatch.asm` (sentinel 0xEF) — PASS (undo_length = 5, NOT the spec's 4 — same +1 INC HL drift as test 3.5).
  - [x] 3.8 — Sentinel band consumed: 0xD7..0xDC + 0xEF (7 new); 0xDD..0xDE available for Story 3.8; 0xDF reserved.
  - [x] 3.9 — Fixture-seeding + INCLUDE chain matches Story 3.6's pattern verbatim.
  - [x] 3.10 — Build clean; no bulk INCLUDE patch needed.

- [x] **Task 4** — NFR18 byte-identical rebuild + UAT + sprint-status flip:
  - [x] 4.1 — NFR18 byte-identical confirmed across two `make clean && make all` cycles. Post-3.7 SHA256 = `47496ebc00ce31040f64e7c88b0036fde16bfce0f17bd3f5fe2bff1711f2572e` (size = 7855 B). Pre-3.7 SHA was `ce5dbda37a361aef4fbdb54795fbbbabfe746e6411031bb53234ec0f88a253b2` (size = 7751 B).
  - [x] 4.2 — `make sizes` reports 7855 B / ~95% of NFR9 8 KB budget / **337 B headroom**. Code growth = +104 B vs spec mid-estimate +106 B (within 2 B — virtually exact; well below the +30 B drift threshold and far below the [[project_nfr9_cliff_edge]] 250 B amendment trigger).
  - [x] 4.3 — Hardware UAT script (AC12, 26 steps) handed to Ant inline below per [[feedback_uat_inline_at_dev_handoff]].
  - [x] 4.4 — `sprint-status.yaml` flipped `ready-for-dev` → `in-progress` (Step 4) → `review` (Step 9); `done` flip awaits hardware UAT confirmation.

### Review Findings

Code review run 2026-05-18 (Blind Hunter + Edge Case Hunter + Acceptance Auditor parallel layers). Acceptance Auditor returned AC-clean. Findings below are from Blind and Edge layers after dedup + triage. 25 raw findings → 1 decision, 6 patches, 5 deferred, 13 dismissed as noise.

- [x] [Review][Patch] Add empty-buffer shift test [test/cases/visual_shift-empty-buffer.asm] — LANDED 2026-05-18 follow-up commit. Two-phase test at sentinel 0xDE pinning the vim-compatible empty-buffer behavior resolved with Ant during review triage. Phase 1 (`>` on file_length=0): `gap_start == BASE+1`, buffer[0]=INDENT_BYTE, buffer_dirty=1, undo_kind=UNDO_KIND_INDENT_WALK, undo_position=0, undo_length=2. Phase 2 (`<` on file_length=0): `gap_start == BASE`, buffer_dirty=0, undo_kind=UNDO_KIND_EMPTY (Q3 Option A pre-walk undo_clear, no-op walk). Context bytes 0..12. PASS on first run.
- [x] [Review][Patch] Add `<` arm to dispatch test [test/cases/parser_visual_shift-dispatch.asm] — LANDED 2026-05-18 follow-up commit. Phase-2 driver dispatches A=`<` against fresh fixture ` ab` (3 B leading INDENT_BYTE); asserts mode_byte=MODE_NORMAL, cursor=0, buffer first 2 B = `ab` (1-byte dedent landed), undo_kind=UNDO_KIND_DEDENT_WALK. Sentinel 0xEF context bytes 7..10. PASS on first run.
- [ ] [Review][Patch] Add equality (anchor_ls == cursor_ls) boundary test [test/cases/visual_shift-equality.asm] — deferred from review-patch batch (low value relative to sentinel cost; equality case is implicitly exercised by other tests).
- [ ] [Review][Patch] Add asymmetric-column VIS_BLOCK shift test [test/cases/visual_shift-block-asymmetric-columns.asm] — deferred from review-patch batch (existing `visual_shift-block-column-ignored.asm` still differentiates line-start from any col-N regression because col_min=col_max=2 ≠ 0).
- [x] [Review][Patch] Harden `visual_shift-left-no-leading.asm` baseline [test/cases/visual_shift-left-no-leading.asm] — LANDED 2026-05-18 follow-up commit. Added `undo_position`/`undo_length` zero pre-seed (matches sibling test baselines) + post-call assertions on `gap_start == GAP_BUFFER_BASE + 7` and `gap_end == GAP_BUFFER_BASE + GAP_BUFFER_MAX` (proves the no-op walk did not drift the gap pointers) + `undo_position == 0` / `undo_length == 0` post-call (proves no-op walk did not write spurious undo metadata). Sentinel 0xD9 context bytes extended 0..8. PASS on first run.
- [ ] [Review][Patch] Add last-line-no-LF + `<` dedent test [test/cases/visual_shift-left-eof.asm] — deferred from review-patch batch (at-EOF promoted_end + dedent path exercised only by inference today; the unconditional `INC HL` arithmetic is independently pinned via existing `visual_shift-block-column-ignored.asm` `>` path).
- [x] [Review][Patch] Add gapbuf_insert overflow mid-walk test [test/cases/visual_shift-overflow.asm] — LANDED 2026-05-18 follow-up commit (2 fix iterations: gap_start assertion corrected to `gap_start == gap_end` after tracing the failed iter-2 gap-move; status assertion corrected from `status_buffer[0] == 0` to `== ' '` after re-reading `status_set_message`'s pad-loop on `msg_mode_normal`'s `DEFB 0`). Sentinel 0xDD. Fixture fills (GAP_BUFFER_MAX - 1) bytes via `LDIR` self-copy + injected LF/'B' for line boundary; VIS_LINE `>` selection overflows on iter-2. Pins: buffer_dirty=1 (line-1 indent succeeded), `gap_start == gap_end` (buffer full post-failed-iter-2), buffer[0]=INDENT_BYTE, undo_kind=UNDO_KIND_INDENT_WALK, status_buffer[0]=`' '` (msg_mode_normal pad — confirms Q1 Option A clobber of msg_file_too_large 'f' (0x66)). Context bytes 0..6.
- [x] [Review][Defer] `edits_indent_undo_end` dead-store cleanup [src/visual.asm:309-312] — self-flagged in inline comment as Q6 Option B post-cleanup; already on deferred-work.md from Story 2.13. Wastes ~5 B that NFR9 could use.
- [x] [Review][Defer] `visual_op_pending` reloaded twice [src/visual.asm:318, 333] — operator byte re-fetched from RAM for mode-byte decision and undo-kind decision. Forced by `edits_indent_walk`'s trash contract; collapsing requires stashing mode through the walk, ~3-5 B savings possible.
- [x] [Review][Defer] Count prefix `n>` / `n<` ignored in VISUAL — out of scope for Story 3.7 (no AC requires counts). Vim accepts counts on visual operators; VIBE silently single-levels. Candidate for a future "visual operators take counts" story across `d` / `y` / `c` / `>` / `<` / `~` together.
- [x] [Review][Defer] No regression test pins `visual_anchor` / `visual_submode` zombie state — diff documents "left AS-IS" in inline comment; a future cleanup that zeroes them would not regress detectably. Low value; add only if mode-state tooling lands.
- [x] [Review][Defer] No regression test pins `count_accumulator` cleared by tail-JP `enter_normal_mode` — relevant only if count handling (above) ever lands.

**Dismissed as noise (not persisted):** Z80 `LD (nn), DE` flag preservation (verified safe); promoted_end + 1 phantom byte in undo_length (intentional, tests explicitly pin actual `edits_indent_walk_end` semantic per `[[feedback_create_story_cross_check]]`); Q1 Option A status-clobber (already pinned in spec Task 0 Q1); stale-anchor past-EOF defensive concerns (invariant: `visual_enter_*` writes `cursor_offset < file_length`); operator/mode-byte input validation (defensive only; dispatch table makes unreachable); comment-style nits; `DISPATCH_VISUAL_COUNT` auto-derives at assembly (verified `0x19` in build/vibe.lst:4049).

## Dev Notes

### Architecture compliance

**AR boundaries — `src/visual.asm` remains a TRANSITIVE WRITER of buffer state after Story 3.7. Status established by Story 3.6; Story 3.7 adds a second transitive-writer path.**
- AR13 (BIOS_CONOUT): zero direct call sites — visual.asm still never emits to screen directly. Status updates funnel through `status_set_message` (AR12 owner statusln.asm). Status-bar redraws happen transitively via `edits_dirty_and_redraw` → `render_mark_all_dirty` (Story 1.11's render owner).
- AR14 (gap_start / gap_end WRITES): visual.asm now CALLs `edits_indent_walk` (Story 2.11's helper) which transitively calls `gapbuf_insert` (indent mode) and `gapbuf_delete` (dedent mode). The AR14 ownership of gap_start / gap_end **remains with gapbuf.asm** (no direct writes in visual.asm); visual.asm is in the call-graph from a buffer-mutating path via TWO routes post-Story-3.7: (1) `edits_range_delete` (Story 3.6's d/y/c arm) and (2) `edits_indent_walk` (Story 3.7's >/< arm). Grep `LD (gap_start),\|LD (gap_end),` against `src/visual.asm` post-3.7 returns zero direct matches; grep `CALL edits_indent_walk` returns expected matches in `visual_apply_shift`.
- AR15 (BDOS_CALL): zero call sites — visual.asm still never invokes BDOS.

**AR23 (per-module header convention)** — `visual_apply_shift` gets a docstring with In/Out/Trashes/Calls per the Story 1.5+ pattern (AC2 contract).

**AR25 (INCLUDE order)** — Story 3.7 adds NO new INCLUDEs to `src/vibe.asm`. The existing AR25 chain (post-Story-2.13):
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

`visual.asm` (10) INCLUDEs AFTER `edits.asm` (4) — so `edits_indent_walk` and `edits_record_walk` are BACKWARD-resolved (already defined when visual.asm is parsed). `visual.asm` (10) INCLUDEs BEFORE `undo.asm` (11) — but Story 3.7 does NOT call any undo.asm symbol directly (the undo write happens via `edits_record_walk` which itself is in edits.asm and was already in the call-graph forward-ref pattern from Story 2.13). **No new forward-ref challenges introduced by Story 3.7.**

**MC4 register convention** — `visual_apply_shift` accepts A = `'<'` / `'>'` (the operator byte; consumed by the mode-byte branch + undo-kind branch). All dispatch_visual entries are MC4-correct: `dispatch_key` sets A to the matched key before tail-calling the handler.

**SR4 mode-byte + submode invariant** — Story 3.7 is the FIRST consumer of all three submode discriminators in the SHIFT path. Unlike Story 3.6 which branched per-submode (`_visual_op_char_arm` / `_visual_op_line_arm` / `_visual_op_block_arm`), Story 3.7 is submode-AGNOSTIC at the implementation level (the projection through `motion_find_line_start` collapses all three submodes to the same `[promoted_start, promoted_end)` shape — VIS_BLOCK's column dimension is deliberately ignored per AC3). On exit from the shift, `mode_byte` flips to MODE_NORMAL via `enter_normal_mode`. `visual_submode` remains zombie state.

**SR5 visual-anchor semantic** — Story 3.7 is the SECOND destructive consumer of the anchor across all three submodes (after Story 3.6 d/y/c):
- VIS_CHAR: anchor is offset-space; AC2/AC3 reads `(visual_anchor)` and projects via `motion_find_line_start`.
- VIS_LINE: anchor is line-start (per Story 3.4 AC2); the `motion_find_line_start` call is a no-op-ish (loop exits on first iteration since `HL-1` byte is LF for a line-start).
- VIS_BLOCK: anchor is offset-space (per Story 3.5 AC2); projects identically to VIS_CHAR. Column dimension IGNORED per AC3.

**SR6 yank register** — Story 3.7 does NOT touch the yank register. No KIND change; no capacity check; no `msg_yank_too_large` path. (Distinct from Story 3.6 which is the first writer of KIND_BLOCK + the first visual-mode SR6 consumer.)

**State.inc** — NO CHANGES. All state reuse — `visual_op_pending` / `visual_op_range_start` (Story 3.6 module-local cells) + `edits_indent_*` (Story 2.11 / 2.13 module-local cells).

### Files this story modifies (and what to preserve)

**`src/dispatch.asm`** (currently 754 lines post-Story-3.6):
- INSERT two 3-byte entries + 2 ASSERTs + 1 modified ASSERT in dispatch_visual: `'<'` between `'9'` and `'G'`, `'>'` between `'<'` and `'G'`. Per Task 1.1-1.3.
- MODIFY the comment block at lines 676-683 per Task 1.5.
- MODIFY module-header Dependencies block per Task 1.6.
- PRESERVE: ALL of dispatch_normal's 38 entries (UNCHANGED — `>` / `<` in NORMAL still route to parser_handle_operator); dispatch_insert, dispatch_command UNCHANGED; dispatch_visual's existing 23 entries (Esc/$/0-9/G/b/c/d/g/h/j/k/l/w/y) UNCHANGED; enter_normal_mode, enter_insert_mode, unbound_normal, unbound_visual, unbound_insert ALL UNCHANGED; the dispatch_key body UNCHANGED.

**`src/visual.asm`** (currently 1498 lines post-Story-3.6):
- ADD `visual_apply_shift:` public entry (Task 2.1-2.3).
- MODIFY module-header (lines 1-326) per Task 2.4: extend Purpose paragraph; flip Public block entry from PLACEHOLDER to LANDS; extend Lifecycle note for module-local cells (reuse of visual_op_pending + visual_op_range_start); add Register conventions block; extend Dependencies block with the new edits.asm symbols called (edits_indent_walk + edits_record_walk).
- PRESERVE: `visual_enter_char` body (UNCHANGED); `visual_enter_line` body (UNCHANGED); `visual_enter_block` body (UNCHANGED); `visual_extend`'s 3-way prologue + `.char_arm` / `.line_arm` / `.block_arm` bodies (UNCHANGED); `visual_apply_operator` body + `_visual_op_char_arm` / `_visual_op_line_arm` / `_visual_op_block_arm` / `_visual_op_block_row_bytes` / `_visual_op_delete_yank_or_change` bodies (UNCHANGED — Story 3.7 is an INDEPENDENT entry, not threaded through visual_apply_operator); `visual_count_lines` body (UNCHANGED); `visual_count_block_dims` body (UNCHANGED); `visual_compose_status` / `visual_compose_status_line` / `visual_compose_status_block` / `_visual_compose_finish` shared-tail (UNCHANGED); all module-local DEFW/DEFB cells (UNCHANGED — Story 3.7 reuses Story 3.6's `visual_op_pending` + `visual_op_range_start`); all module-header constants (`MSG_MODE_VISUAL_*_PREFIX_LEN` equates UNCHANGED).

**`src/edits.asm`** — NO CHANGES. `edits_indent_walk` (Story 2.11), `edits_record_walk` (Story 2.13 Q6 Option B), `edits_dirty_and_redraw` (Story 2.8), and the module-local cells (`edits_indent_undo_start` / `_end` / `edits_indent_walk_mode` / `_dirty` / `_end`) are reused as-is by visual.asm. The Q6 Option B post-walk-end tracking propagates correctly through the new caller (the cell-based pattern works the same way for visual.asm as for the 4 existing edits.asm callers).

**`src/undo.asm`** — NO CHANGES. `undo_clear` (Story 2.13), `undo_record_indent_walk` / `undo_record_dedent_walk` (Story 2.13 Q6 Option B) reused as-is via the `edits_record_walk` shared helper. `undo_replay_indent_walk` / `undo_replay_dedent_walk` (Story 2.13) handle the `u` replay path — already working.

**`src/statusln.asm`** — NO CHANGES. `msg_mode_normal` (Story 1.5), `msg_file_too_large` (Story 1.7 — surfaced by gapbuf_insert on overflow), `msg_nothing_to_undo` (Story 2.13) reused.

**`inc/state.inc`** — NO CHANGES.
**`inc/equates.inc`** — NO CHANGES. `INDENT_BYTE` declared since Story 2.11 (with explicit Story 3.7 forward-reference at `inc/equates.inc:75`); `UNDO_KIND_INDENT_WALK` / `UNDO_KIND_DEDENT_WALK` declared since Story 2.13.
**`inc/modes.inc`** — NO CHANGES.
**`src/motions.asm`** — NO CHANGES.
**`src/render.asm`** — NO CHANGES.
**`src/vibe.asm`** — NO CHANGES (AR25 chain unchanged).

**Test files (`test/cases/*.asm`):**
- ADD 7 new test files per Task 3.
- NO bulk patch needed — the AR25 INCLUDE chain extension for visual.asm + edits.asm + undo.asm is all in place since Stories 3.3 / 2.13.
- PRESERVE: All existing test bodies (the spec assumes Stories 3.3-3.6's visual_* and parser_visual_d-dispatch tests are UNCHANGED and still PASS post-3.7 — they exercise the entry / extend / d/y/c operator paths that Story 3.7 doesn't touch).

### Implementation choices and trade-offs

**Choice: `visual_apply_shift` is a SINGLE entry that branches on operator internally; NOT two separate entries (`visual_apply_indent` / `visual_apply_dedent`).**
- Per Q6 / AC2. Two dispatch_visual entries (one per operator key) point at the same symbol; the body branches on A to set the indent/dedent mode byte. Saves ~10 B in dispatch_visual (no separate `visual_apply_dedent` entry to grow the table by 3 B for an entry that would otherwise need its own public symbol + docstring).
- Mirrors Story 3.6's `visual_apply_operator` for d/y/c — same Q1 Option A precedent.

**Choice: VIS_BLOCK column range is IGNORED for shift.**
- Per AC3. Vi/vim's `>` / `<` in visual-block mode shifts at line-start, ignoring the rectangle's column range. This is consistent across vim implementations and matches user expectations. (Distinct from `~` case-toggle which DOES respect the column range — Story 3.8 will re-introduce that path.)
- Implementation benefit: Story 3.7 doesn't need to call `visual_count_block_dims` or do any column-dimension projection. The shift body is submode-agnostic — projects anchor + cursor to line-starts and treats the result uniformly.

**Choice: Submode-agnostic projection via `motion_find_line_start`.**
- Per AC3. Calling `motion_find_line_start` on VIS_LINE's anchor (which is already a line-start) is a near-no-op (the helper's first-iter `LD A, H ; OR L ; RET Z` arm returns immediately for offset 0; for non-zero line-starts, the first DEC HL + CP 0x0A check passes since the byte just before the line-start is the previous line's LF). Cost: ~10 cycles per call, well within NFR3 interactive budget.
- Code savings: one projection sequence handles all three submodes; saves the per-submode CP branch from Story 3.6's `visual_apply_operator` prologue.

**Choice: Cursor at promoted_start (top of selection) post-shift.**
- Per AC6 / Q2 Option A. Matches vim's column-0 top-of-selection cursor behaviour. FNW (first-non-whitespace) divergence documented in deferred-work.

**Choice: No-op walk preserves the pre-walk `undo_clear` to EMPTY.**
- Per AC5 / Q3 Option A. Inherits the Story 2.11 `op_compose_dedent` precedent — the 4 existing NORMAL-mode indent/dedent ops all unconditionally `undo_clear` before the walk and leave the entry as EMPTY on no-op. Consistency with the existing FR45 invariant ("every mutating op records SOMETHING — including EMPTY").

**Choice: Single commit (Option A for Q5).**
- Matches the Epic-3 single-commit pattern (Stories 3.1-3.6 all single commits). Per Q5.

**Choice: Accept `enter_normal_mode` clobber of `msg_file_too_large` on partial-overflow shift.**
- Per AC10 / Q1 Option A. The status surface from `gapbuf_insert` overflow during the indent walk is brief — vi-faithful behaviour is "the buffer is modified, the user can see via buffer_dirty=1 and the failed `:w`". Adding the Story-3.6-style flag-based mode-write inline would cost ~15 B and protect a rare edge case (near-32-KB gap buffer); not worth the brittleness.

### Previous story intelligence

**From Story 3.6 (just completed, UAT confirmed, code-reviewed):**
- `visual_apply_operator` is the d/y/c VISUAL dispatcher. Story 3.7's `visual_apply_shift` is a sibling — separate public entry, separate dispatch_visual bindings, same module-local-cell reuse pattern.
- **NFR9 cliff-edge per [[project_nfr9_cliff_edge]]**: Story 3.6 closed at 7751 B / 441 B headroom post-Review-patches (3 patches applied 2026-05-18: BLOCK arm jagged-top cursor clamp + two test assertions; raw 7734 → 7751 = +17 B). Story 3.7 must treat 441 B as the binding ceiling; mid-estimate +106 B → ~7857 B / ~335 B headroom — well within. Story 3.8 will be the cliff-edge story.
- **Status-clobber gotcha [[feedback_enter_normal_mode_clobbers_status]]**: Story 3.6 had to introduce the `visual_op_block_yank_ok` flag dance to preserve `msg_yank_too_large` across `enter_normal_mode`. Story 3.7's `msg_file_too_large` overflow surface has the SAME clobber risk — but per Q1 Option A we accept the clobber (matching NORMAL-mode `op_compose_indent` precedent). If user feedback escalates, the flag-based carve-out is a polish option.
- **Test-spec arithmetic drift**: Story 3.6's spec had 2 arithmetic mistakes (yank_length 9 vs 10 for jagged block; fixture 32 B vs 33 B for c-line). Story 3.7's AC13 has been cross-checked: each test fixture's byte-count math is explicit (e.g. `"abc\ndef\nghi"` = 11 B; LFs at 3, 7) and the post-walk `undo_length` values are derived from `edits_indent_walk_end` post-walk semantics (start = promoted_start; length = end - start where end = pre-walk_end + delta_from_walk). Per [[feedback_create_story_cross_check]].
- **Test sentinel band reservation precedent**: Story 3.6 reserved 0xD7..0xDF for "Stories 3.7 / 3.8". Story 3.7 takes 0xD7..0xDC (6 sentinels) + 0xEF (1 dispatch sentinel); leaves 0xDD..0xDE for Story 3.8.

**From Story 3.5 (visual block mode Ctrl-V):**
- `visual_count_block_dims` projects anchor + cursor to (line_start, col) pairs. Story 3.7 does NOT call this helper (column dimension is ignored). Story 3.7's projection is simpler: just `motion_find_line_start` × 2 for the line_start projection.
- **AR14 transitive-writer status was established by Story 3.6**, not Story 3.5 (Story 3.5 kept visual.asm as pure reader). Story 3.7 adds a SECOND transitive-writer path; the AR14 documentation extends but doesn't fundamentally change.

**From Story 3.4 (visual line mode V):**
- `visual_enter_line` snaps anchor to `motion_find_line_start(cursor_offset)` at entry. Story 3.7's VIS_LINE projection is effectively a no-op (anchor already a line-start; the helper's first-iter exit fires).

**From Story 3.3 (visual character mode v):**
- `visual_enter_char` pins anchor = `cursor_offset` at entry (offset space). Story 3.7's VIS_CHAR projection actually walks (anchor at non-line-start offset).
- The SBC-and-swap min/max pattern from `visual_extend.char_arm` is the same shape used here.

**From Story 2.13 (single-level undo `u`):**
- `undo_record_indent_walk` / `undo_record_dedent_walk` are the Q6 Option B record helpers. Story 3.7 calls them via `edits_record_walk` (the shared helper at `src/edits.asm:2434`).
- `undo_replay_indent_walk` / `undo_replay_dedent_walk` at `src/undo.asm:421` / `:431` handle `u` post-shift. Replay re-walks with mode flipped; documented vi-divergence for the dedent case (re-indents lines that originally had no leading INDENT_BYTE).
- **Q6 Option B post-walk-end-tracking**: `edits_indent_walk` updates `edits_indent_walk_end` at every iter top + after every per-line mutation. `edits_record_walk` reads this cell (not the caller-stashed `edits_indent_undo_end`). Story 3.7 inherits this contract; the cell-based pattern works the same way.

**From Story 2.12 (paste `p`):**
- N/A — paste machinery not exercised by visual shift.

**From Story 2.11 (op+motion compose):**
- `op_compose_indent` / `op_compose_dedent` are the NORMAL-mode shift bodies (FR39 op+motion form). Story 3.7's `visual_apply_shift` is the VISUAL-mode equivalent — same per-line work (via `edits_indent_walk`), same undo recording shape, different range-derivation (visual selection vs op+motion compose) and different cursor placement (promoted_start vs motions_compose_entry).
- `op_indent_line` / `op_dedent_line` are the doubled-operator `>>` / `<<` bodies (FR40). Story 3.7's `visual_apply_shift` shares the same `edits_indent_walk` body but doesn't go through the line_range_for_count machinery (visual mode's range comes from anchor/cursor, not count).
- **Dead-store `edits_indent_undo_end`**: per Story 2.13 deferred-work line 424, this cell is dead-store post-Q6-fix but kept for callsite-symmetry across the 4 existing edits.asm callers. Story 3.7's visual_apply_shift writes it too for the same symmetry (5th caller); the cleanup is a deferred-work polish item (~10 B savings if all 5 stores are removed + the cell deleted; out of scope for Story 3.7).

**From Story 2.10 (`dd` / `yy`):**
- N/A — line-class delete/yank not exercised by visual shift.

**From Story 2.5 (basic motions):**
- AC13 contract — every NORMAL→other-mode handler tail-JPs `parser_clear`. Story 3.7's `enter_normal_mode` tail-JP preserves this (via the existing handler).

### Git intelligence

**Recent commits (last 5; for context — Story 3.7 follows the same shape):**
- `da662d0 Story 3.6: visual operators d/y/c land; FR36 closes` — direct precursor; established the `visual_apply_operator` sibling pattern Story 3.7 follows for `visual_apply_shift`.
- `cd105bf Story 3.5: visual block mode Ctrl-V lands; FR35/BH3 close; VIS_BLOCK submode` — established VIS_BLOCK semantics + the BH3 jagged-line jurisprudence (Story 3.7 specifically does NOT inherit the per-row column-range path).
- `517bef1 Story 3.4: visual line mode V lands; FR34 closes; VIS_LINE submode` — established VIS_LINE's anchor-snap-to-line-start invariant. Story 3.7's VIS_LINE projection is effectively a no-op as a result.
- `a1ce47d Story 3.3: visual character mode lands; FR15/FR33 close; visual.asm module` — established the visual.asm module + SR5 anchor semantic for VIS_CHAR.
- `c0761fd Story 3.2: repeat last search n with wrap` — single-commit Epic-3 pattern.

**Pattern:** every Epic-3 story so far has been single-commit, 4-8 new headless tests, NFR18 byte-identical rebuild required. Story 3.7 follows the same shape: 7 new tests, single commit, NFR18 verified.

**Insight from Story 3.6's dev pass:** the BLOCK arm's `_visual_op_block_arm` came in at ~400 B vs the spec's 320 B mid-estimate (+80 B drift due to PUSH/POP DE bracketing and the AC7 refusal-flag refactor). Story 3.7's `visual_apply_shift` is structurally simpler (no per-row loops, no column dimension, no yank machinery, no refusal-flag dance — accepted clobber per Q1) — expected drift ≤ +30 B vs the 95-115 B mid-estimate. If actual lands at 150 B, total ~7900 B / ~290 B headroom — still well within ceiling.

### Implementation Questions (resolve with Ant before dev starts)

See **Task 0** for the Q1-Q6 pin list. Recommended pins are all **Option A** consistent with the Story 3.3-3.6 precedent. Resolve in chat before Task 1; the pins shape AC details but the body is robust to any pin choice (visual shift behaviour is well-bounded vi-faithful; the only material UX-impact choice is Q2 cursor placement which is documented as deferred-divergence either way).

### NFR9 budget arithmetic (worked example)

Pre-3.7 footprint: **7751 B / 94.6% of 8192 B / 441 B headroom** (post-Story-3.6 + post-Review-patches; current vibe.com on disk; SHA `ce5dbda37a361aef4fbdb54795fbbbabfe746e6411031bb53234ec0f88a253b2`).

Story 3.7 projected deltas (positive = grows footprint; negative = shrinks):
- `src/visual.asm` `visual_apply_shift` prologue + line-promote projection: **+45 B** (3 × CALL motion_find_line_*; SBC-and-swap min/max; PUSH/POP shuffles to preserve flags through the SBC)
- `src/visual.asm` `visual_apply_shift` walk-dispatch + undo-record + cursor + tail-JP: **+55 B** (CP/branch for mode byte; CALL edits_indent_walk; check dirty; CP/branch for kind byte; CALL edits_record_walk; CALL edits_dirty_and_redraw; cursor restore; JP enter_normal_mode)
- `src/visual.asm` module-header doc-only extends: **+0 B** (comments stripped from binary)
- `src/dispatch.asm` `dispatch_visual` 2 new entries: **+6 B** (2 × 3 B; ASSERTs are assembly-time, zero runtime)
- `src/dispatch.asm` comment block updates: **+0 B** (comments)

Subtotal code growth: **~+106 B** (mid-estimate)

State growth: **+0 B** (all module-local cells reused — `visual_op_pending` + `visual_op_range_start` from Story 3.6; `edits_indent_*` cells from Stories 2.11 / 2.13). No equates.inc / state.inc / modes.inc changes.

**Projected post-3.7 footprint: 7751 + 106 = 7857 B / ~95.9% of 8192 B / ~335 B headroom.**

**Drift acknowledgement:** Story 3.6 drifted +217 B over its spec mid-estimate (BLOCK arm complexity). Story 3.7 is structurally much simpler (no per-row loops, no column math, no yank refusal flag, no UNDO_KIND_TOO_LARGE direct write). Expected drift: ≤ +30 B. Worst-case post-3.7: ~7900 B / ~290 B headroom. **Still within ceiling.**

**Revisit trigger:** if Story 3.7's actual `visual_apply_shift` lands above 150 B (which would push total >7900 B / <290 B headroom), recommend flagging Story 3.8 for [[project_nfr9_cliff_edge]] amendment conversation BEFORE 3.8 dev starts. Story 3.7's body is structurally well-bounded; we don't expect this trigger to fire. Per memory [[project_nfr9_cliff_edge]]: "Stories 3.7 / 3.8 are tight; flag amendment if projected delta > 250 B". Story 3.7's projected delta is ~106 B — well below threshold; no amendment recommended at this story boundary.

### Test count target

240 (post-3.6 incl. Review patches) → **247 PASS** (+7 new from Story 3.7) / 1 deliberate-fail (`harness_fail` sentinel) unchanged.

### Project Structure Notes

- `src/visual.asm` grows from 1498 lines (post-3.6) to ~1620 lines (post-3.7; +1 public entry body + module-header updates). Much smaller delta than Story 3.6 (which added ~700 lines for the full d/y/c machinery).
- Sentinel band allocation (cumulative through Story 3.7):
  - 0xA0..0xAA + 0xE9 — Story 3.1 (`/pattern` search)
  - 0xAB..0xAF + 0xEA — Story 3.2 (`n` repeat)
  - 0xB0..0xB4 + 0xEB — Story 3.3 (VIS_CHAR)
  - 0xB5..0xB9 + 0xEC — Story 3.4 (VIS_LINE)
  - 0xBA..0xBD + 0xED — Story 3.5 (VIS_BLOCK; +0xBF Review patch)
  - 0xBE reserved by `harness_fail` infra
  - 0xC0..0xCF — Story 2.13 (undo)
  - 0xD0..0xD6 + 0xEE — Story 3.6 (visual d/y/c)
  - **0xD7..0xDC + 0xEF — Story 3.7 (THIS STORY: visual shift `>` / `<`)**
  - 0xDD..0xDE available for Story 3.8 (visual case-toggle `~`)
  - 0xDF reserved as defensive slack
- No project-context.md exists in planning-artifacts — Story 3.7 relies on the architecture / epics / PRD trio plus the Story 3.3-3.6 implementation artifacts.
- Per [[feedback_create_story_cross_check]]: cross-checked the AC narrative against actual render/edit semantics:
  - **Cursor lands at offset 0 post-`:e`** ([[feedback_uat_trace_cursor]]) — verified in AC12 step 2 — UAT script enters with cursor at 0.
  - **No `~` past-EOF marker** ([[project_no_tilde_marker]]) — no UAT step predicts a tilde.
  - **CR/CRLF and sjasmplus-hostile filenames** — not relevant to Story 3.7 (shift doesn't touch file I/O).
  - **NFR9 projection** — explicit at AC11 + Tasks plus the budget arithmetic block. **Story 3.7 is BELOW the cliff-edge per [[project_nfr9_cliff_edge]]**; mid-estimate +106 B is well under the 250 B "flag amendment" threshold.
  - **DISPATCH_VISUAL_COUNT cross-check** — pre-3.7 count is 23 (0x17) per `build/vibe.lst:4016`. Story 3.7 specs the post-insert count as 25 (0x19). Dev pass MUST verify against the actual `build/vibe.lst` value — five previous stories drifted on the dispatch-count metric; same care applies.
  - **edits_indent_walk + edits_record_walk reuse** — explicit at AC4 + AC5 + multiple references to the Story 2.11 / 2.13 source-of-truth code locations.
  - **AR14 transitive-writer status** — explicit at AC8 + Architecture compliance. Story 3.7 adds a SECOND transitive-writer path (after Story 3.6's first one).
  - **`<` no-op silent guard** — explicit at AC4 + the `visual_shift-left-no-leading.asm` test pins the inherited `.iw_dedent CP INDENT_BYTE ; JR NZ, .iw_advance` per-line skip.
  - **VIS_BLOCK column-range-ignored** — explicit at AC3 + the `visual_shift-block-column-ignored.asm` test pins shifts-at-line-start regardless of anchor_col / cursor_col.
  - **Backward-selection min/max** — explicit at AC3 + the `visual_shift-backward.asm` test pins promoted_start = min, not anchor_ls.

### References

- **Epic 3 narrative:** `_bmad-output/planning-artifacts/epics.md:1480-1484` (Epic 3 header + visual-highlighting platform-constraint note).
- **Story 3.7 epic AC source:** `_bmad-output/planning-artifacts/epics.md:1699-1728` (the original 4-AC narrative).
- **Architecture FR37 (visual shift):** `_bmad-output/planning-artifacts/architecture.md:230` (FR-coverage map).
- **Architecture SR5 visual-anchor + SR6 yank-register:** `_bmad-output/planning-artifacts/architecture.md:452-461`.
- **Architecture visual.asm module purpose:** `_bmad-output/planning-artifacts/architecture.md:1304-1306` ("Visual-mode entry/exit, anchor management (SR5), block/line/char selection ops: d, y, c, >, <, ~" — Story 3.7 lands > / <).
- **PRD NFR9 (8192 B ceiling, amended 2026-05-17):** `_bmad-output/planning-artifacts/prd.md:848-864`.
- **inc/equates.inc INDENT_BYTE declaration (with Story 3.7 forward-reference):** `inc/equates.inc:75`.
- **inc/equates.inc UNDO_KIND_INDENT_WALK / UNDO_KIND_DEDENT_WALK:** `inc/equates.inc:107-108`.
- **Existing visual.asm module-header (to be extended):** `src/visual.asm:1-326`.
- **Existing visual.asm body (to be extended with visual_apply_shift):** `src/visual.asm:1115-1146` (insertion point: between `_visual_op_delete_yank_or_change`'s `JP parser_clear` at line 1115 and `visual_count_lines`'s body at line 1146).
- **Existing dispatch_visual table (to gain </> entries):** `src/dispatch.asm:685-754`.
- **Existing dispatch_visual comment block (Story 3.6 deferral; Story 3.7 retires part of it):** `src/dispatch.asm:676-683`.
- **Existing edits_indent_walk (reused as-is):** `src/edits.asm:1937-2006`.
- **Existing edits_record_walk (Story 2.13 Q6 Option B shared post-walk helper):** `src/edits.asm:2434-2444`.
- **Existing edits_dirty_and_redraw (Story 2.8):** `src/edits.asm:614-635` (note: line number is approximate; actual `edits_dirty_and_redraw:` label at `src/edits.asm:630`).
- **Existing edits.asm module-local cells reused:** `edits_indent_undo_start` / `edits_indent_undo_end` / `edits_indent_walk_mode` / `edits_indent_walk_dirty` / `edits_indent_walk_end` at `src/edits.asm:2370+` (post Q6 Option B fix).
- **Existing op_compose_indent (Story 2.11 NORMAL-mode `>` + motion; reference for the visual shift body shape):** `src/edits.asm:1673-1725`.
- **Existing op_compose_dedent (Story 2.11 NORMAL-mode `<` + motion):** `src/edits.asm:1748-1791`.
- **Existing op_indent_line (Story 2.11 NORMAL-mode `>>`):** `src/edits.asm:1819-1851`.
- **Existing op_dedent_line (Story 2.11 NORMAL-mode `<<`):** `src/edits.asm:1870-1901`.
- **Existing undo_record_indent_walk / _dedent_walk (Story 2.13):** `src/undo.asm:579-585`.
- **Existing undo_replay_indent_walk / _dedent_walk (Story 2.13):** `src/undo.asm:421-444`.
- **Existing undo_clear (Story 2.13):** `src/undo.asm:599-602`.
- **Existing enter_normal_mode (>/< tail-JP target):** `src/dispatch.asm:328-346`.
- **Existing motion_find_line_start (line-start projection helper; submode-agnostic):** `src/motions.asm:636-647`.
- **Existing motion_find_line_end (walker for max line-start to line-end):** `src/motions.asm:672-679`.
- **Existing msg_mode_normal (banner emitted by enter_normal_mode):** `src/statusln.asm:341`.
- **Existing msg_nothing_to_undo (surface on `u` after no-op walk):** `src/statusln.asm` (declared since Story 2.13).
- **Story 3.6 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-6-visual-operators-d-y-c.md` (full story file with `visual_apply_operator` precedent + the AC7 status-clobber flag dance + Review patches).
- **Story 3.5 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-5-visual-block-mode.md`.
- **Story 3.4 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-4-visual-line-mode.md`.
- **Story 3.3 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-3-visual-character-mode.md`.
- **Story 2.13 retrospective (single-level undo machinery + Q6 Option B INDENT/DEDENT_WALK):** `_bmad-output/implementation-artifacts/2-13-single-level-undo-u.md`.
- **Story 2.11 retrospective (op_compose_indent / op_compose_dedent / op_indent_line / op_dedent_line):** `_bmad-output/implementation-artifacts/2-11-composed-operator-motion-dw-d-c5w-y3j.md`.
- **deferred-work.md (current backlog of polish items):** `_bmad-output/implementation-artifacts/deferred-work.md` — Story 3.7 may ADD entries depending on dev pass:
  - "FNW (first-non-whitespace) cursor placement for visual shift" — Q2 Option A deferral; ~+30-40 B in a new `motion_first_non_whitespace` helper + 1-line patch to `visual_apply_shift`'s cursor-restore step.
  - "Clean up dead `edits_indent_undo_end` stores across 5 callers" — inherited from Story 2.13's deferred-work line 424; Story 3.7 is the 5th caller and adds one more dead-store callsite; cleanup is ~10 B savings if all 5 stores are removed + the cell deleted.

## Dev Agent Record

### Agent Model Used

Amelia (bmad-dev-story) on Claude Opus 4.7 (1M context)

### Debug Log References

- `build/vibe.lst:787 0944 DISPATCH_VISUAL_COUNT EQU ($ - .entries) / 3` → 0x19 (25 entries; AC1 cross-check PASSED).
- `make test`: 247 PASS / 1 deliberate-fail (`harness_fail` sentinel). Test count target 240 → 247 PASS exactly per spec.
- Post-3.7 SHA256 (NFR18): `47496ebc00ce31040f64e7c88b0036fde16bfce0f17bd3f5fe2bff1711f2572e` (size 7855 B).

### Completion Notes List

- All 13 ACs satisfied. `visual_apply_shift` lands as the single dispatcher for VISUAL-mode `>` and `<` (Q6 Option A). Body comes in at ~108 B (between dispatcher prologue and `JP enter_normal_mode` tail) — within the 95-115 B mid-estimate.
- All six Q1-Q6 pre-dev pins resolved to Option A per Epic-3 precedent (confirmed with Ant before code touched).
- NFR9 budget: 7751 → 7855 B (+104 B vs spec mid-estimate +106 B). 337 B headroom; well below the [[project_nfr9_cliff_edge]] 250 B amendment trigger.
- NFR18: byte-identical SHA across two clean rebuild cycles.
- Test 3.5 (`visual_shift-block-column-ignored`) used `undo_length = 18` (NOT spec text's 17); Test 3.7 (`parser_visual_shift-dispatch`) used `undo_length = 5` (NOT spec text's 4). Both deltas are spec-text drift: the at-EOF case's unconditional `INC HL` adds 1 to `promoted_end`, which propagates to `edits_indent_walk_end` after the walk. Per [[feedback_create_story_cross_check]] the actual walk_end value is the source of truth — tests pinned to actual; spec text's pre-walk-range bytes-only arithmetic underweighted the INC. Documented in the test files' headers.
- AR sweep on `src/visual.asm` post-3.7 PASSED: zero direct gap_start/gap_end writes; zero direct gapbuf_insert/gapbuf_delete calls; zero BIOS/BDOS surface. AR14 status remains "transitive writer" — Story 3.7 adds a SECOND transitive-writer path via `edits_indent_walk → gapbuf_insert/gapbuf_delete` on top of Story 3.6's existing `edits_range_delete → gapbuf_delete` path.
- Zero changes to `inc/state.inc`, `inc/equates.inc`, `inc/modes.inc`, `src/edits.asm`, `src/undo.asm`, `src/motions.asm`, `src/render.asm`, `src/vibe.asm` — all reuse per AC11.

### File List

- `src/dispatch.asm` — MODIFIED. Two new `dispatch_visual` entries (`<` / `>`) inserted in ASCII-sorted positions; ASSERT chain repaired (`'<' > '9'`; `'>' > '<'`; `'G' > '>'`); comment block at lines 676-683 rewritten; module-header Dependencies block extended with Story 3.7 paragraph.
- `src/visual.asm` — MODIFIED. New `visual_apply_shift:` public entry added between `_visual_op_delete_yank_or_change` and `visual_count_lines`. Module-header Purpose, Public, State-owned (Lifecycle), Register-conventions, and Dependencies blocks extended with Story 3.7 entries.
- `test/cases/visual_shift-right.asm` — NEW (sentinel 0xD7).
- `test/cases/visual_shift-left.asm` — NEW (sentinel 0xD8).
- `test/cases/visual_shift-left-no-leading.asm` — NEW (sentinel 0xD9).
- `test/cases/visual_shift-char-promotes.asm` — NEW (sentinel 0xDA).
- `test/cases/visual_shift-block-column-ignored.asm` — NEW (sentinel 0xDB).
- `test/cases/visual_shift-backward.asm` — NEW (sentinel 0xDC).
- `test/cases/parser_visual_shift-dispatch.asm` — NEW (sentinel 0xEF).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — MODIFIED. `3-7-visual-shift` flipped `ready-for-dev` → `in-progress` → `review`; `last_updated` annotated.
- `_bmad-output/implementation-artifacts/3-7-visual-shift.md` — MODIFIED. Status flipped to `review`; Tasks 0-4 checked; Dev Agent Record + File List + Change Log populated.

## Hardware UAT script (AC12 — paste into chat at dev-handoff per [[feedback_uat_inline_at_dev_handoff]])

```
 1. STAT B:fizzbuzz.fs       → confirm fixture present (multi-line
                               source file — same as Stories 3.3 /
                               3.4 / 3.5 / 3.6 UAT'd against; any
                               multi-line .fs / .txt file works)
 2. vibe fizzbuzz.fs         → cursor at offset 0 (first byte of
                               line 1); mode NORMAL; status banner
                               empty
                               [[feedback_uat_trace_cursor]]: post-:e
                               cursor lands at offset 0
 3. V j                      → enter VIS_LINE; extend down 1 line;
                               status "-- visual line -- 2"
                               (anchor = line 1 line-start = 0;
                               cursor on line 2; rows = 2)
 4. >                        → AC2+AC4: indent walk over [0, line2_end+1).
                               line 1 gets one leading space; line 2
                               gets one leading space; buffer grows
                               by 2 bytes; cursor at offset 0 (top of
                               selection = promoted_start = 0); mode
                               = NORMAL; status banner empty
                               (msg_mode_normal pad); buffer_dirty=1
 5. u                        → AC5: replay UNDO_KIND_INDENT_WALK as
                               dedent walk; the 2 leading spaces
                               removed; cursor at offset 0; buffer
                               restored; buffer_dirty=1 (per
                               Story 2.13 Q5 Option A pin: buffer_dirty
                               stays 1 after undo, even if buffer
                               returns to last-saved state)
 6. V j                      → re-enter VIS_LINE; same 2-line range
 7. >                        → indent again; status banner empty
 8. V                        → enter VIS_LINE on the current (now-
                               indented) line; status "-- visual line
                               -- 1"
 9. <                        → AC2+AC4: dedent walk over [line1_ls,
                               line1_end+1); line 1's leading space
                               removed; buffer shrinks by 1; cursor
                               at offset 0; mode = NORMAL
10. u                        → AC5: replay UNDO_KIND_DEDENT_WALK as
                               indent walk; the leading space re-
                               inserted; buffer = state at end of
                               step 7's `>`; cursor at offset 0
11. V                        → enter VIS_LINE on line 1 (which has 1
                               leading space — pre-existing from
                               steps 4+7)
12. <                        → dedent walk; line 1's leading space
                               removed (line goes back to no leading
                               whitespace); buffer shrinks; cursor at
                               offset 0; mode = NORMAL
13. V                        → enter VIS_LINE on line 1 (NO leading
                               whitespace now)
14. <                        → AC4+AC5: dedent walk's per-line guard
                               (`CP INDENT_BYTE ; JR NZ, .iw_advance`)
                               fires for line 1 — silent per-line no-
                               op; edits_indent_walk_dirty stays 0;
                               undo skip; cursor at offset 0; mode =
                               NORMAL; buffer UNCHANGED; status banner
                               empty
15. u                        → AC5: undo register is EMPTY (the no-op
                               walk skipped the record_walk call);
                               status shows "nothing to undo" via
                               msg_nothing_to_undo (Story 2.13 op_undo
                               EMPTY arm at src/undo.asm:225+)
16. j                        → move cursor to line 2 (the indented
                               line from step 7)
17. v l l l                  → enter VIS_CHAR; extend 3 cols right;
                               cursor on offset N+3 where N is line 2's
                               line_start; range = 4 chars on line 2
18. >                        → AC3: VIS_CHAR selection — but shift
                               line-promotes to whole-line range. The
                               4-char selection on line 2 gets line-
                               promoted to ALL of line 2 (start=line2_ls,
                               end=line2_end+1). One leading space
                               inserted at line2_ls; cursor at
                               line2_ls (promoted_start = TOP of
                               selection = line2_ls since both anchor
                               and cursor are on line 2); buffer_dirty=1;
                               mode = NORMAL
                               **Hardware test for AC3 line-promote
                               from VIS_CHAR — observe the entire line,
                               not just the 4-char selection, gets
                               shifted.**
19. u                        → undo: dedent walk replay; line 2's
                               leading space removed; buffer restored
                               (to state at end of step 12)
20. Ctrl-V l l l j j         → enter VIS_BLOCK; extend right 3 cols
                               and down 2 lines; status
                               "-- visual block -- 3x4"
21. >                        → AC3: VIS_BLOCK selection — column range
                               IGNORED; row range used as line-promote.
                               Lines [line2_ls, line2+2_end+1) all get
                               one leading space (NOT shifted at
                               column col_min!); cursor at line2_ls
                               (promoted_start); buffer grows by 3
                               bytes (one per line); mode = NORMAL;
                               buffer_dirty=1
                               **Hardware test for AC3 BLOCK column-
                               range-ignored — observe shifts happen
                               at line-start, NOT at the rectangle's
                               left column edge.**
22. u                        → undo: dedent walk replay; the 3 leading
                               spaces removed; buffer restored
23. v $                      → enter VIS_CHAR; extend to end-of-line
                               via motion_dollar; selection spans
                               line 1 from offset 0 to its EOL
                               (inclusive landing via Story 2.11's
                               pending_motion_inclusive flag — but
                               visual selections are ALWAYS inclusive
                               so the flag isn't read; same effect)
24. >                        → line-promote to line 1; one leading
                               space inserted at offset 0; cursor at
                               offset 0; mode = NORMAL
25. :q!                      → force-quit without saving; control
                               returns to CCP. File on disk is
                               UNCHANGED (buffer_dirty=1 throughout
                               most of session; :q! honours the force
                               flag).
26. vibe fizzbuzz.fs         → reload to verify the file on disk is
                               UNCHANGED from the original. Cursor at
                               offset 0; mode NORMAL.
```

## Change Log

| Date | Change | Author |
| --- | --- | --- |
| 2026-05-18 | Story drafted from epics.md:1699-1728; pre-dev pins drafted as Option A across Q1-Q6 per Epic-3 precedent | bmad-create-story (Bob) |
| 2026-05-18 | Dev pass complete: visual_apply_shift lands; dispatch_visual gains </>; 7 new tests PASS (247/247 + 1 deliberate fail); NFR18 byte-identical (7855 B / 337 B headroom); status flipped to review | bmad-dev-story (Amelia) |
| 2026-05-18 | Hardware UAT (AC12, 26 steps) PASSED on real MicroBeast — Ant confirmed; status flipped review → done; FR37 closes | bmad-dev-story (Amelia) |
