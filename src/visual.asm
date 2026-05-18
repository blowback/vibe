; ============================================================
; Module: visual.asm
; Purpose: Visual-mode entry / extent / status helpers (FR15, FR33,
;          FR34, FR35). Story 3.3 lands the VIS_CHAR surface; Story
;          3.4 lands the VIS_LINE surface; Story 3.5 lands the
;          VIS_BLOCK surface: `Ctrl-V` (0x16) from NORMAL pins
;          `visual_anchor` at the entry cursor OFFSET (NOT the
;          line-start — VIS_BLOCK anchor lives in offset space and
;          the column is derived on-demand as
;          `visual_anchor - motion_find_line_start(visual_anchor)`;
;          this is the KEY semantic distinction from VIS_LINE which
;          snaps the anchor to a line-start). Subsequent mode-
;          agnostic motions land at edits_compose_or_clear's
;          MODE_VISUAL arm and call visual_extend, which dispatches
;          on visual_submode: VIS_CHAR → existing `|cursor - anchor|
;          + 1` path; VIS_LINE → walk LFs in [min, max) where min =
;          min(line-start(cursor), anchor) and max = the other, line
;          count = LFs + 1; VIS_BLOCK → visual_count_block_dims
;          projects BOTH anchor and cursor to (row, col) via
;          motion_find_line_start, walks LFs in the same [min, max)
;          line-start interval for rows, then computes cols as
;          `|cursor_col - anchor_col| + 1`. Status row reports
;          "-- visual -- N" (CHAR), "-- visual line -- N" (LINE) or
;          "-- visual block -- RxC" (BLOCK). Esc returns to NORMAL
;          via the existing src/dispatch.asm:enter_normal_mode — no
;          separate visual_cancel symbol needed (Q7 pin from Story 3.3).
;
;          BH3 jagged-line semantic (Story 3.5): the VIS_BLOCK
;          rectangle is *virtual* — short lines are NOT padded in
;          the buffer; rows whose line is shorter than the column
;          range are simply reported in the bounding RxC dimensions
;          but no gap-buffer write occurs. Per-row clipping ("delete
;          only up to EOL on short lines") is the OPERATOR's job
;          (Stories 3.6+ visual_apply_operator marshals per-row
;          ranges from this story's rectangle).
;
;          Story 3.6 — visual_apply_operator (d / y / c) lands.
;          visual.asm transitions from a PURE READER of buffer
;          state to a TRANSITIVE WRITER via edits_range_delete →
;          gapbuf_delete. AR14 ownership of gap_start / gap_end
;          REMAINS with src/gapbuf.asm (visual.asm contains zero
;          direct writes to those cells — grep `LD (gap_start),\|
;          LD (gap_end),` against src/visual.asm returns zero
;          matches); the operator path mutates the buffer
;          exclusively through the existing AR14-clean
;          edits_range_delete helper (Story 2.10 / 2.11).
;
;          Story 3.7 — visual_apply_shift (`>` / `<`) lands.
;          visual.asm gains a second transitive-writer path via
;          edits_indent_walk → gapbuf_insert / gapbuf_delete
;          (line-class shift; INDENT_BYTE = 0x20 per
;          inc/equates.inc:75 — consistent with the four existing
;          NORMAL-mode shift entry points op_compose_indent /
;          op_compose_dedent / op_indent_line / op_dedent_line and
;          per Forth-source convention; tab support is a Growth-tier
;          knob). AR14 ownership of gap_start / gap_end REMAINS
;          with gapbuf.asm (no direct writes from visual.asm); the
;          second mutation path joins the existing Story 3.6
;          edits_range_delete → gapbuf_delete path. Per-line work
;          is inherited verbatim from Story 2.11's edits_indent_walk
;          (including the .iw_dedent CP INDENT_BYTE skip guard
;          that realises the epic-AC "silent per-line no-op for `<`
;          on lines without leading INDENT_BYTE"). Undo via the
;          Story 2.13 Q6 Option B UNDO_KIND_INDENT_WALK /
;          _DEDENT_WALK records (the shared edits_record_walk
;          reads edits_indent_walk_end as the post-walk
;          authoritative end); replay via
;          undo_replay_indent_walk / _dedent_walk (mode-flipped
;          re-walk). VIS_BLOCK's column range is IGNORED for shift
;          — vi-faithful at line-start, documented inline. Story
;          3.7's projection is submode-agnostic: both anchor and
;          cursor are projected via motion_find_line_start (no-op-ish
;          for VIS_LINE; actual walk for VIS_CHAR / VIS_BLOCK). AR13
;          (BIOS_CONOUT) + AR15 (raw BDOS) remain clean. Side
;          effects extend beyond Story 3.5's set to also include
;          writes to yank_kind / yank_length / yank_buffer (via
;          edits_copy_to_yank for CHAR / LINE arms; via direct
;          per-row append for the BLOCK arm), to undo_kind /
;          undo_position / undo_length / undo_buffer (via
;          undo_record_delete for CHAR / LINE arms; via
;          undo_write_header for the BLOCK arm UNDO_KIND_TOO_LARGE
;          direct record per Q2 Option A — multi-region undo
;          deferred), to cursor_offset (post-op placement —
;          op_compose_d x-style clamp for CHAR; op_dd three-way
;          for LINE; rectangle top-left for BLOCK), and via
;          edits_dirty_and_redraw to buffer_dirty + the render
;          dirty-rows bitmap. The 12 new module-local cells
;          (visual_op_pending + visual_op_range_start /
;          _range_bytes + visual_op_yank_kind + 9 BLOCK-arm
;          DEFW + 1 DEFB scratch cells) are written by
;          visual_apply_operator on every call; valid only
;          between entry and the terminal tail-JP.
;
; Public:
;   visual_enter_char     ; LANDS Story 3.3 — `v` entry, VIS_CHAR
;   visual_enter_line     ; LANDS Story 3.4 — `V` entry, VIS_LINE
;   visual_enter_block    ; LANDS Story 3.5 — `Ctrl-V` entry, VIS_BLOCK
;   visual_extend         ; LANDS Story 3.3 — per-motion extent refresh
;                         ; (Story 3.4: submode-dispatch prologue
;                         ; routes VIS_CHAR vs VIS_LINE arms; Story
;                         ; 3.5 extends the prologue to a 3-way
;                         ; cascade with a .block_arm for VIS_BLOCK)
;   visual_apply_operator ; LANDS Story 3.6 — (d / y / c on VIS_CHAR /
;                         ; VIS_LINE / VIS_BLOCK selections; FR36).
;   visual_apply_shift    ; LANDS Story 3.7 — (> / < on VIS_CHAR /
;                         ; VIS_LINE / VIS_BLOCK selections; FR37 —
;                         ; line-class shift via edits_indent_walk;
;                         ; VIS_BLOCK column range IGNORED).
;                         ; The sibling visual_apply_case_toggle for
;                         ; ~ (Story 3.8) remains a placeholder.
;
;   (visual_cancel is NOT a separate symbol per Q7 pin Option A —
;    src/dispatch.asm:enter_normal_mode handles VISUAL→NORMAL
;    cleanly and was always documented as the VISUAL exit point.)
;
; State owned (read/write):
;   visual_anchor         ; 16-bit; WRITTEN by visual_enter_char
;                         ; (Story 3.3 — VIS_CHAR, anchor = cursor)
;                         ; AND by visual_enter_line (Story 3.4 —
;                         ; VIS_LINE, anchor = line-start of cursor)
;                         ; AND by visual_enter_block (Story 3.5 —
;                         ; VIS_BLOCK, anchor = cursor offset; SAME
;                         ; offset-space as VIS_CHAR — NOT line-start;
;                         ; column is derived on-demand from
;                         ; `visual_anchor - motion_find_line_start
;                         ; (visual_anchor)` by visual_count_block_dims).
;                         ; Frozen for the lifetime of the visual
;                         ; session — extend NEVER re-pins it; vi
;                         ; convention. READ by visual_extend (count
;                         ; math, all three arms) and by future
;                         ; visual_apply_operator (range marshalling).
;   visual_submode        ; 1-byte; WRITTEN by visual_enter_char
;                         ; (VIS_CHAR, Story 3.3) AND by
;                         ; visual_enter_line (VIS_LINE, Story 3.4)
;                         ; AND by visual_enter_block (VIS_BLOCK,
;                         ; Story 3.5). Submode-writer triad
;                         ; complete. NOT cleared on VISUAL→NORMAL
;                         ; exit — zombie state until the next
;                         ; visual entry overwrites it; meaningless
;                         ; when mode_byte != MODE_VISUAL (SR4
;                         ; invariant).
;
;   Module-local DEFW projection scratch (Story 3.5 — NOT in state.inc):
;     visual_block_anchor_ls   ; anchor's line-start (offset)
;     visual_block_anchor_col  ; anchor's column = anchor - anchor_ls
;     visual_block_cursor_ls   ; cursor's line-start (offset)
;     visual_block_cursor_col  ; cursor's column = cursor - cursor_ls
;     visual_block_temp_rows   ; rows result stashed across cols compute
;   Lifecycle: cleared and re-written by visual_count_block_dims at
;   every call; values valid ONLY between the helper's entry and
;   its RET — caller does NOT read them. Module-local; never
;   exported via inc/state.inc.
;
;   Module-local operator scratch (Story 3.6 — NOT in state.inc):
;     visual_op_pending        ; DEFB — operator byte ('c'|'d'|'y')
;                              ; stashed by visual_apply_operator
;                              ; prologue; read by the shared
;                              ; finalisation _visual_op_delete_yank_or_change
;                              ; to branch between .delete_path /
;                              ; .change_path / .yank_only.
;     visual_op_range_start    ; DEFW — HL stash across the
;                              ; finalisation's sub-CALLs.
;     visual_op_range_bytes    ; DEFW — BC stash, same purpose.
;     visual_op_yank_kind      ; DEFB — KIND_CHAR or KIND_LINE
;                              ; from the CHAR / LINE arms (BLOCK
;                              ; arm sets yank_kind directly).
;     visual_op_block_rows     ; DEFW — rows cached from
;                              ; visual_count_block_dims (Story 3.5
;                              ; HL return).
;     visual_op_block_cols     ; DEFW — cols cached from BC return.
;     visual_op_block_col_min  ; DEFW — min(anchor_col, cursor_col).
;     visual_op_block_col_max  ; DEFW — max(anchor_col, cursor_col).
;     visual_op_block_top_ls   ; DEFW — min(anchor_ls, cursor_ls);
;                              ; line-start of the top row.
;     visual_op_block_walker   ; DEFW — per-row line-start walker
;                              ; (pass 1 + pass 2 of the BLOCK arm).
;     visual_op_block_total_bytes ; DEFW — pass-1 yank-byte accumulator
;                              ; + final yank_length seed.
;     visual_op_block_remaining_rows ; DEFW — loop counter for both passes.
;     visual_op_block_yank_ptr ; DEFW — pass-2 yank_buffer write pointer.
;     visual_op_block_yank_ok  ; DEFB — 0 = yank refused (over capacity);
;                              ; 1 = yank ok (within YANK_BUFFER_SIZE).
;   Lifecycle: cleared and re-written by visual_apply_operator at
;   every call; values valid ONLY between the helper's entry and
;   its terminal JP (enter_normal_mode for d/y; enter_insert_mode
;   for c). Module-local; never exported via inc/state.inc. The
;   Story 3.5 visual_block_* cells are an INDEPENDENT scratch group
;   reused only inside visual_count_block_dims; the Story 3.6
;   visual_op_block_* cells are for the pass-1 / pass-2 loop state.
;
;   Story 3.7 reuses two Story-3.6 cells with the same one-dispatch
;   lifecycle:
;     visual_op_pending      ; operator-byte stash ('<' | '>') across
;                            ; the body's CP branches (mode-byte +
;                            ; undo-kind selection).
;     visual_op_range_start  ; promoted_start stash across the
;                            ; edits_indent_walk CALL (which trashes
;                            ; HL/DE); read at the cursor-restore step.
;   The five Story-2.11/2.13 edits_indent_* cells declared in
;   src/edits.asm (edits_indent_undo_start / _end / _walk_mode /
;   _walk_dirty / _walk_end) are also reused by visual_apply_shift
;   via the existing edits_indent_walk + edits_record_walk helpers —
;   Story 3.7 introduces no new cells in either module.
;
; State read-only:
;   cursor_offset         ; read by visual_enter_char (anchor pin)
;                         ; and by visual_extend (count math).
;   mode_byte             ; not read in this module — the MODE_VISUAL
;                         ; check happens at src/edits.asm's
;                         ; edits_compose_or_clear bare-motion arm
;                         ; (where the routing decision belongs).
;
; Register conventions (across public entry points):
;   visual_enter_char:
;       In:      A = 'v' (MC4 — ignored after dispatch)
;       Out:     mode_byte = MODE_VISUAL; visual_submode = VIS_CHAR;
;                visual_anchor = cursor_offset (frozen — never
;                re-written by extend); status_buffer pre-padded
;                with "-- visual -- 1"; status_dirty = 1; parser
;                state zeroed (count_accumulator / pending_operator
;                / pending_motion_prefix / pending_motion_inclusive).
;       Trashes: A, BC, DE, HL, F
;       Calls:   visual_compose_status (CALL); parser_clear (tail-JP)
;
;   visual_enter_line:
;       In:      A = 'V' (MC4 — ignored after dispatch)
;       Out:     mode_byte = MODE_VISUAL; visual_submode = VIS_LINE;
;                visual_anchor = motion_find_line_start(cursor_offset)
;                — the line-start of the entry cursor, NOT the cursor
;                itself; frozen for the visual-line session.
;                cursor_offset UNCHANGED. status_buffer = "-- visual
;                line -- 1"; status_dirty = 1. Parser state zeroed.
;       Trashes: A, BC, DE, HL, F
;       Calls:   motion_find_line_start (CALL); visual_compose_status_line
;                (CALL); parser_clear (tail-JP).
;
;   visual_enter_block:
;       In:      A = 0x16 (Ctrl-V; MC4 — ignored after dispatch)
;       Out:     mode_byte = MODE_VISUAL; visual_submode = VIS_BLOCK;
;                visual_anchor = cursor_offset (offset space — NOT
;                line-start; vi-faithful BLOCK anchor; column
;                derived on-demand by visual_count_block_dims as
;                `visual_anchor - motion_find_line_start(visual_anchor)`).
;                cursor_offset UNCHANGED. status_buffer = "-- visual
;                block -- 1x1"; status_dirty = 1. Parser state zeroed.
;       Trashes: A, BC, DE, HL, F
;       Calls:   visual_compose_status_block (CALL); parser_clear
;                (tail-JP).
;
;   visual_extend:
;       In:      (none — reads cursor_offset, visual_anchor and
;                visual_submode from state.inc)
;       Out:     status_buffer pre-padded with either
;                "-- visual -- <count>"   (VIS_CHAR; count = |cursor -
;                                          anchor| + 1)
;                "-- visual line -- <count>"  (VIS_LINE; count = LFs
;                                              in [min, max) + 1 where
;                                              min/max are the two
;                                              line-starts)
;                "-- visual block -- <rows>x<cols>"  (VIS_BLOCK;
;                                              rows = LFs in
;                                              [min(anchor_ls,
;                                              cursor_ls), max) + 1;
;                                              cols = |cursor_col -
;                                              anchor_col| + 1).
;                Count clamped to 1..65535. status_dirty = 1; mode_byte
;                / visual_submode / visual_anchor / cursor_offset
;                UNCHANGED; parser state zeroed.
;       Trashes: A, BC, DE, HL, F
;       Calls:   visual_compose_status (CALL — CHAR arm);
;                visual_count_lines + visual_compose_status_line
;                (LINE arm); visual_count_block_dims +
;                visual_compose_status_block (BLOCK arm);
;                parser_clear (tail-JP all three arms).
;
;   visual_apply_operator:  (Story 3.6 — FR36)
;       In:      A = operator byte ('c' | 'd' | 'y' from MC4 via
;                dispatch_visual).
;       Out:     depends on (operator, submode) — see AC3/AC4/AC5/AC6
;                in the story spec. On every exit:
;                mode_byte = MODE_NORMAL ('d', 'y') OR MODE_INSERT ('c');
;                cursor_offset placed at the deletion-start (== the
;                projection of min(anchor, cursor) for each submode);
;                yank register written with the selection content
;                (KIND_CHAR for VIS_CHAR; KIND_LINE for VIS_LINE;
;                KIND_BLOCK for VIS_BLOCK — rows joined by LF with no
;                trailing LF per AC9) UNLESS total bytes exceed
;                YANK_BUFFER_SIZE — in which case the yank register
;                is PRESERVED (SR6 "predictable failure mode") and
;                status surfaces msg_yank_too_large; deletion still
;                proceeds for `d` / `c` ('y' is read-only by definition).
;                Undo recorded as UNDO_KIND_DELETE for VIS_CHAR / VIS_LINE
;                `d` / `c` (phase-2 REPLACE upgrade for `c` fires at
;                INSERT-exit transitively via undo_insert_exit_record —
;                inherited from Story 2.13); VIS_BLOCK `d` / `c` records
;                UNDO_KIND_TOO_LARGE directly via undo_write_header
;                (multi-region undo deferred per Q2 Option A); `y`
;                records nothing (yank-only, inherits op_yy semantics).
;                Parser state cleared (via enter_normal_mode /
;                enter_insert_mode tail-JPs). visual_submode left
;                AS-IS — zombie state on VISUAL→NORMAL exit per
;                Story 3.5 AC10.
;       Trashes: A, BC, DE, HL, F + the module-local cells listed
;                in the "State owned" Module-local operator scratch
;                block above.
;       Calls:   motion_find_line_start (LINE-arm cursor projection;
;                BLOCK-arm not used here — visual_count_block_dims
;                does its own projection internally);
;                motion_find_line_end (LINE-arm bottom-of-selection
;                walk; BLOCK-arm per-row line-end probe);
;                motion_byte_at_logical (BLOCK-arm content read for
;                KIND_BLOCK per-row yank append);
;                visual_count_block_dims (BLOCK-arm projection +
;                rows/cols compute);
;                edits_copy_to_yank (CHAR / LINE arms — CONTIGUOUS
;                range; BLOCK arm does its own per-row yank append);
;                edits_range_delete (CHAR / LINE arms; BLOCK arm
;                per-row clipped slice);
;                edits_dirty_and_redraw (success commit);
;                undo_record_delete (CHAR / LINE arms);
;                undo_clear (BLOCK arm pre-clear);
;                undo_write_header (BLOCK arm UNDO_KIND_TOO_LARGE
;                direct record);
;                status_set_message (yank-too-large surface);
;                enter_normal_mode (tail-JP for `d` / `y`);
;                enter_insert_mode (tail-JP for `c`).
;
;   visual_apply_shift:  (Story 3.7 — FR37)
;       In:      A = operator byte ('<' | '>' from MC4 via dispatch_visual).
;       Out:     every line whose start is in [promoted_start,
;                promoted_end) is shifted right ('>') or left ('<')
;                by one INDENT_BYTE (0x20); promoted_start =
;                min(motion_find_line_start(visual_anchor),
;                motion_find_line_start(cursor_offset));
;                promoted_end = motion_find_line_end(max_ls) + 1.
;                For '<', lines whose first byte is NOT INDENT_BYTE
;                are silent per-line no-ops (inherited from
;                edits_indent_walk's .iw_dedent skip guard). VIS_BLOCK's
;                column range is IGNORED — shift acts at line-start.
;                cursor_offset = promoted_start (top of selection,
;                column 0 — FNW divergence deferred). mode_byte =
;                MODE_NORMAL via enter_normal_mode tail-JP.
;                buffer_dirty = 1 + render dirty-rows marked iff
;                edits_indent_walk_dirty == 1; undo recorded as
;                UNDO_KIND_INDENT_WALK / UNDO_KIND_DEDENT_WALK via
;                edits_record_walk on the dirty path; no-op walks
;                leave undo EMPTY (pre-walk undo_clear). visual_anchor
;                and visual_submode left AS-IS (zombie state per
;                Story 3.5/3.6 precedent). yank register UNTOUCHED
;                (distinct from visual_apply_operator).
;       Trashes: A, BC, DE, HL, F + module-local cells (visual_op_pending,
;                visual_op_range_start, edits_indent_undo_start / _end,
;                edits_indent_walk_mode / _dirty / _end).
;       Calls:   motion_find_line_start (CALL × 2 — anchor + cursor
;                projection);
;                motion_find_line_end (CALL × 1 — MAX line-start →
;                its line-end);
;                undo_clear (CALL — pre-walk; FR45 invariant);
;                edits_indent_walk (CALL — Story 2.11 per-line walk);
;                edits_record_walk (CALL on dirty path — Story 2.13
;                Q6 Option B shared helper);
;                edits_dirty_and_redraw (CALL on dirty path);
;                enter_normal_mode (JP tail).
;
; Dependencies:
;   inc/state.inc    (cursor_offset, visual_anchor, visual_submode,
;                     mode_byte (writer), status_compose_scratch —
;                     Story 3.3 NEW shared cell at the Q3 pin Option A;
;                     parser_clear writes count_accumulator /
;                     pending_* fields via the tail-JP).
;   inc/modes.inc    (MODE_VISUAL, VIS_CHAR, VIS_LINE equates).
;   src/motions.asm  (Story 3.4 — motion_find_line_start, called by
;                     visual_enter_line (anchor-pin path) and by
;                     visual_count_lines (cursor's line-start);
;                     motion_byte_at_logical, called by
;                     visual_count_lines (LF-walk inner loop).
;                     Backward-resolved — motions.asm INCLUDEs
;                     before visual.asm in the vibe.asm AR25 chain).
;   src/statusln.asm (status_set_message (AR12 funnel — final-stage
;                     emit via the shared compose tail);
;                     status_u16_to_dec (Q2 pin Option A — decimal
;                     count emit; called twice by
;                     visual_compose_status_block for the rows + cols
;                     numeric pair); msg_mode_visual_prefix (CHAR
;                     submode prefix); msg_mode_visual_line_prefix
;                     (Story 3.4 — LINE submode prefix);
;                     msg_mode_visual_block_prefix (Story 3.5 —
;                     BLOCK submode prefix, "-- visual block -- ").
;   src/parser.asm   (parser_clear — tail-JP target on both public
;                     entries per AC13 from Story 2.5).
;   src/edits.asm    (Story 3.6 NEW — edits_copy_to_yank,
;                     edits_range_delete, edits_dirty_and_redraw.
;                     Story 3.7 NEW — edits_indent_walk (Story 2.11
;                     per-line shift helper) and edits_record_walk
;                     (Story 2.13 Q6 Option B shared post-walk undo
;                     record helper). Both backward-resolved by the
;                     AR25 chain (edits.asm INCLUDEs before visual.asm).
;                     Backward-resolved: edits.asm INCLUDEs at
;                     vibe.asm line 150; visual.asm INCLUDEs at
;                     vibe.asm line 164 — so edits.asm symbols are
;                     already defined by the time visual.asm is parsed.)
;   src/undo.asm     (Story 3.6 NEW — undo_clear, undo_record_delete,
;                     undo_write_header. FORWARD-resolved: undo.asm
;                     INCLUDEs at vibe.asm line 209 — AFTER visual.asm.
;                     Forward-resolution via sjasmplus's two-pass
;                     model. Same shape as op_undo's forward-ref from
;                     dispatch_normal['u'] (Story 2.13) crossing the
;                     same AR25 ordering. undo_write_header sits in
;                     undo.asm's "internal helper" comment but is a
;                     regular labelled entry with RET — callable from
;                     outside; Story 3.6 promotes it to the Public
;                     block in undo.asm's module header.)
; ============================================================

;; ============================================================
;; --- Public entry: visual_enter_char (Story 3.3 — `v` entry) ---
;; ============================================================

; ----------------------------------------------------------------
; visual_enter_char
; Entry from dispatch_normal['v'] (src/dispatch.asm). Pins the
; current cursor as the visual anchor, sets the MODE_VISUAL /
; VIS_CHAR sub-mode discriminator, composes the "-- visual -- 1"
; entry banner, and drops any stale parser state via parser_clear.
;
; The entry char count is always 1 — visual_anchor == cursor_offset
; at this point so |cursor - anchor| = 0; +1 = 1. visual_compose_status
; loads HL = 1 inline (no need to call visual_extend's compute arm).
;
; AR23 contract — see module-header Register conventions block.
; ----------------------------------------------------------------
visual_enter_char:
    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A
    LD      HL, (cursor_offset)
    LD      (visual_anchor), HL         ; pin anchor at entry cursor (frozen)
    LD      HL, 1                       ; entry char count = 1 (one byte selected)
    CALL    visual_compose_status
    JP      parser_clear                ; AC13: zero count / operator / prefix


;; ============================================================
;; --- Public entry: visual_enter_line (Story 3.4 — `V` entry) ---
;; ============================================================

; ----------------------------------------------------------------
; visual_enter_line
; Entry from dispatch_normal['V'] (src/dispatch.asm). Pins the
; *line-start* of the entry cursor as the visual anchor (NOT the
; cursor itself — vi-faithful; the line-mode anchor lives in
; line-start space because column data is meaningless and the
; visual_count_lines math relies on anchor being a line-start),
; sets the MODE_VISUAL / VIS_LINE submode discriminator, composes
; the "-- visual line -- 1" entry banner, and drops any stale
; parser state via parser_clear.
;
; The entry line count is always 1: anchor.line == cursor.line at
; this point so LFs in [anchor, line-start(cursor)) = 0; +1 = 1.
; visual_compose_status_line loads HL = 1 inline (no need to call
; visual_extend's compute arm).
;
; AR23 contract — see module-header Register conventions block.
; ----------------------------------------------------------------
visual_enter_line:
    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_LINE
    LD      (visual_submode), A
    LD      HL, (cursor_offset)
    CALL    motion_find_line_start      ; HL = line-start of cursor's line
    LD      (visual_anchor), HL         ; pin anchor at the line-start (frozen)
    LD      HL, 1                       ; entry line count = 1
    CALL    visual_compose_status_line
    JP      parser_clear                ; AC13: zero count / operator / prefix


;; ============================================================
;; --- Public entry: visual_enter_block (Story 3.5 — `Ctrl-V`) ---
;; ============================================================

; ----------------------------------------------------------------
; visual_enter_block
; Entry from dispatch_normal[0x16] (Ctrl-V; src/dispatch.asm).
; Pins the entry cursor OFFSET as the visual anchor (NOT the
; line-start — VIS_BLOCK's anchor lives in offset space; the
; anchor column is derived on-demand by visual_count_block_dims
; as `visual_anchor - motion_find_line_start(visual_anchor)`).
; Sets MODE_VISUAL / VIS_BLOCK, composes the "-- visual block --
; 1x1" entry banner, drops any stale parser state via parser_clear.
;
; The entry rectangle is 1x1: anchor == cursor at this point so
; rows = LFs in [anchor_ls, anchor_ls) + 1 = 1 and cols =
; |anchor_col - anchor_col| + 1 = 1. visual_compose_status_block
; loads HL = 1 (rows) and BC = 1 (cols) inline — no need to call
; visual_count_block_dims's compute arm.
;
; AR23 contract — see module-header Register conventions block.
; ----------------------------------------------------------------
visual_enter_block:
    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_BLOCK
    LD      (visual_submode), A
    LD      HL, (cursor_offset)
    LD      (visual_anchor), HL         ; pin anchor at the cursor offset (frozen)
    LD      HL, 1                       ; entry rows = 1
    LD      BC, 1                       ; entry cols = 1
    CALL    visual_compose_status_block
    JP      parser_clear                ; AC13: zero count / operator / prefix


;; ============================================================
;; --- Public entry: visual_extend (Story 3.3 — per-motion refresh) ---
;; ============================================================

; ----------------------------------------------------------------
; visual_extend
; Entry from src/edits.asm:edits_compose_or_clear's MODE_VISUAL arm
; (see AC5). Called AFTER a mode-agnostic motion handler has
; advanced cursor_offset; visual_extend recomputes the selection
; extent and refreshes the status row. The motion's normal post-
; motion tail-JP target (parser_clear) is hijacked by the
; MODE_VISUAL arm — visual_extend must restore that contract on
; its way out (AC13).
;
; Story 3.4 — submode-dispatch prologue: reads visual_submode and
; branches to the CHAR arm (existing `|cursor - anchor| + 1`
; math), the LINE arm (visual_count_lines + LINE-prefix status),
; or — after Story 3.5 — the BLOCK arm (visual_count_block_dims +
; BLOCK-prefix status). VIS_CHAR is value 0 and serves as the
; defensive fall-through default for any unknown submode value.
;
; Count math (CHAR arm):
;   1. HL = cursor; DE = anchor; HL = HL - DE.
;   2. If CF=1 (cursor < anchor; backward motion), HL was a 16-bit
;      negative two's-complement value — negate HL by 0 - HL via
;      EX DE,HL; LD HL,0; OR A; SBC HL,DE so HL = |cursor - anchor|.
;   3. INC HL — count = abs + 1 (entry case abs=0 → count=1).
;
; Count math (LINE arm): delegated to visual_count_lines — walks
; LFs in [min, max) where min/max are the two line-starts.
;
; Count math (BLOCK arm): delegated to visual_count_block_dims —
; projects both anchor and cursor to (row, col) and returns
; HL = rows (LFs in [min(anchor_ls, cursor_ls), max) + 1) and
; BC = cols (|cursor_col - anchor_col| + 1). Any future submodes
; would extend the cascade further.
;
; AR23 contract — see module-header Register conventions block.
; ----------------------------------------------------------------
visual_extend:
    LD      A, (visual_submode)
    CP      VIS_BLOCK
    JR      Z, .block_arm               ; VIS_BLOCK → rectangle compute
    CP      VIS_LINE
    JR      Z, .line_arm                ; VIS_LINE → walk LF count
    ;; fall through into the CHAR arm (VIS_CHAR is value 0; also
    ;; the defensive default for any unknown submode value).
    ASSERT VIS_CHAR == 0    ; equate-ordering invariant the fall-through depends on
.char_arm:
    LD      HL, (cursor_offset)
    LD      DE, (visual_anchor)
    OR      A                           ; clear CF for the SBC
    SBC     HL, DE                      ; HL = cursor - anchor (signed)
    JR      NC, .have_abs               ; forward / equal — HL already positive
    ;; Backward motion — negate HL via 0 - HL.
    EX      DE, HL                      ; DE = (cursor - anchor) negative
    LD      HL, 0
    OR      A                           ; clear CF
    SBC     HL, DE                      ; HL = -(cursor - anchor) = |delta|
.have_abs:
    INC     HL                          ; count = |cursor - anchor| + 1
    CALL    visual_compose_status
    JP      parser_clear                ; AC13: drop any parser state stale from the motion's preamble
.line_arm:
    CALL    visual_count_lines          ; HL = line count (1..65535)
    CALL    visual_compose_status_line
    JP      parser_clear                ; AC13: drop any parser state stale from the motion's preamble
.block_arm:
    ;; BH3 jagged-line semantic — the bounding rectangle is virtual.
    ;; Status banner reports `RxC` of the bounding box. Per-row
    ;; clipping (short lines processed only up to EOL) is the
    ;; OPERATOR's responsibility (Story 3.6+ — visual_apply_operator
    ;; marshals per-row ranges from this rectangle). Story 3.5
    ;; lands the rectangle and the dimension display; NO mutation
    ;; of the buffer occurs in this path (AR14 invariant pinned).
    CALL    visual_count_block_dims     ; HL = rows; BC = cols
    CALL    visual_compose_status_block ; format "RxC"
    JP      parser_clear                ; AC13: drop any parser state stale from the motion's preamble


;; ============================================================
;; --- Public entry: visual_apply_operator (Story 3.6 — FR36) ---
;; ============================================================

; ----------------------------------------------------------------
; visual_apply_operator
; Entry from dispatch_visual['c'|'d'|'y'] (src/dispatch.asm). The
; SINGLE shared dispatcher for the three visual-mode operators:
; A on entry = the operator byte (MC4). The body stashes A in
; visual_op_pending (the operator survives across every CALL
; chain in the arm bodies — A is trashed many times en route),
; then branches on visual_submode to:
;   VIS_CHAR  → _visual_op_char_arm  (range = inclusive [min, max+1) of (anchor, cursor); KIND_CHAR)
;   VIS_LINE  → _visual_op_line_arm  (range = whole-line span; KIND_LINE; op_dd at-EOF carve-out)
;   VIS_BLOCK → _visual_op_block_arm (per-row clipped deletion; KIND_BLOCK rows-joined-by-LF;
;                                     UNDO_KIND_TOO_LARGE direct record per Q2 Option A)
; CHAR / LINE share a common finalisation (_visual_op_delete_yank_or_change)
; which routes on operator: 'd' = delete + yank + cursor clamp + JP enter_normal_mode;
; 'c' = same as 'd' but JP enter_insert_mode (Story 2.11 two-phase REPLACE upgrade
; fires transitively via undo_insert_exit_record at INSERT-exit — inherited from
; Story 2.13); 'y' = yank-only with cursor restored to range_start (Q1 Option A).
; BLOCK has its own dedicated finalisation because the per-row mutation pattern
; doesn't fit the contiguous-range shape of edits_range_delete + undo_record_delete.
;
; AR23 contract — see module-header Register conventions block.
; ----------------------------------------------------------------
visual_apply_operator:
    LD      (visual_op_pending), A          ; stash operator byte ('c' | 'd' | 'y')
    LD      A, (visual_submode)
    CP      VIS_BLOCK
    JP      Z, _visual_op_block_arm
    CP      VIS_LINE
    JR      Z, _visual_op_line_arm
    ;; Fall through to CHAR arm (VIS_CHAR == 0; defensive default
    ;; for any unknown submode value — mirrors visual_extend's
    ;; 3-way prologue from Story 3.5 AC3).
    ASSERT  VIS_CHAR == 0


; ----------------------------------------------------------------
; _visual_op_char_arm
; VIS_CHAR range compute. SBC-and-swap pattern from
; visual_extend.char_arm — except the bump is +1 INCLUSIVE
; (vi convention: visual selection is inclusive at both
; endpoints; NORMAL-mode `dw` is exclusive of motion landing).
; The pending_motion_inclusive flag (motion_dollar; Story 2.11)
; is NOT read — visual selections are unconditionally inclusive.
;
; In:      visual_anchor, cursor_offset.
; Out:     HL = range_start = min(anchor, cursor);
;          BC = total_bytes = |cursor - anchor| + 1;
;          A  = KIND_CHAR; JP _visual_op_delete_yank_or_change.
; ----------------------------------------------------------------
_visual_op_char_arm:
    LD      HL, (cursor_offset)
    LD      DE, (visual_anchor)
    OR      A
    SBC     HL, DE                          ; HL = cursor - anchor (signed)
    JR      NC, .forward
    ;; Backward branch (cursor < anchor): range_start = cursor;
    ;; total_bytes = anchor - cursor + 1 (inclusive bump).
    LD      HL, (visual_anchor)
    LD      DE, (cursor_offset)
    OR      A
    SBC     HL, DE                          ; HL = anchor - cursor (positive)
    INC     HL                              ; +1 inclusive bump
    LD      B, H
    LD      C, L                            ; BC = total_bytes
    LD      HL, (cursor_offset)             ; HL = range_start = cursor (min)
    JR      .have_range
.forward:
    ;; Forward / equal (cursor >= anchor): HL holds positive delta.
    INC     HL                              ; HL = total_bytes
    LD      B, H
    LD      C, L                            ; BC = total_bytes
    LD      HL, (visual_anchor)             ; HL = range_start = anchor (min)
.have_range:
    LD      A, KIND_CHAR
    JP      _visual_op_delete_yank_or_change


; ----------------------------------------------------------------
; _visual_op_line_arm
; VIS_LINE range compute. visual_anchor is a line-start (Story 3.4
; AC2 invariant); the cursor is anywhere in its line. Project the
; cursor to its line-start, take min/max of the two line-starts,
; walk to the bottom line's end via motion_find_line_end, then
; produce a half-open [range_start, range_end) where range_end
; consumes the trailing LF. At-EOF carve-out (bottom line has no
; trailing LF) mirrors edits_line_range_for_count.at_eof in
; src/edits.asm — when range_start > 0 the leading LF of the line
; ABOVE is consumed (so the file's new last line doesn't gain a
; stray trailing LF); when range_start == 0 the whole buffer is
; the range. Per Q4 Option A — inline rather than factoring a
; visual_op_line_range helper (single caller; Stories 3.7/3.8 will
; re-evaluate if they also need a from-anchor-to-cursor line range).
; ----------------------------------------------------------------
_visual_op_line_arm:
    LD      HL, (cursor_offset)
    CALL    motion_find_line_start          ; HL = cursor_ls
    PUSH    HL                              ; [cursor_ls]
    LD      DE, (visual_anchor)             ; DE = anchor (line-start by AC2)
    OR      A
    SBC     HL, DE                          ; HL = cursor_ls - anchor (signed)
    POP     HL                              ; HL = cursor_ls; flags preserved
    JR      C, .backward
    ;; Forward / equal: range_start = anchor; walker = cursor_ls (in HL)
    LD      DE, (visual_anchor)
    LD      (visual_op_range_start), DE
    JR      .walk_end
.backward:
    ;; Backward: range_start = cursor_ls (HL); walker = anchor
    LD      (visual_op_range_start), HL
    LD      HL, (visual_anchor)
.walk_end:
    ;; HL = walker (the MAX line-start; walk forward to its line's end)
    CALL    motion_find_line_end            ; HL = LF pos OR file_length; CF=1 on no-LF
    JR      C, .at_eof
    ;; Normal: LF found at HL. range_end = HL + 1 (consume the LF).
    INC     HL
    LD      DE, (visual_op_range_start)
    OR      A
    SBC     HL, DE                          ; HL = range_end - range_start = total_bytes
    LD      B, H
    LD      C, L                            ; BC = total_bytes
    LD      HL, (visual_op_range_start)
    LD      A, KIND_LINE
    JP      _visual_op_delete_yank_or_change
.at_eof:
    ;; HL = file_length; bottom line has no trailing LF.
    ;; If range_start == 0: total = file_length; range_start unchanged.
    ;; Else: shift range_start back by 1 (consume leading LF of the
    ;; line above); total = file_length - (range_start - 1).
    EX      DE, HL                          ; DE = file_length
    LD      HL, (visual_op_range_start)
    LD      A, H
    OR      L
    JR      Z, .eof_zero
    DEC     HL                              ; HL = range_start - 1 = delete_start
    LD      (visual_op_range_start), HL
    EX      DE, HL                          ; HL = file_length; DE = delete_start
    OR      A
    SBC     HL, DE                          ; HL = total_bytes
    LD      B, H
    LD      C, L
    LD      HL, (visual_op_range_start)
    LD      A, KIND_LINE
    JP      _visual_op_delete_yank_or_change
.eof_zero:
    ;; range_start == 0: delete the entire buffer
    LD      B, D
    LD      C, E                            ; BC = file_length
    ;; HL already 0 (= range_start)
    LD      A, KIND_LINE
    JP      _visual_op_delete_yank_or_change


; ----------------------------------------------------------------
; _visual_op_block_arm  (AC5 + AC9 — the heavyweight path)
; VIS_BLOCK per-row processing. Two passes:
;   Pass 1: walk rows top-to-bottom (PRE-delete), sum
;           bytes_this_row per row (BH3-clipped at EOL) + LF
;           separator bytes between adjacent rows; capacity-check
;           against YANK_BUFFER_SIZE (sets visual_op_block_yank_ok).
;   Pass 2: walk rows top-to-bottom with shift-tracking; for each
;           row append bytes_this_row content to yank_buffer
;           (if yank_ok) joined by LF separators; for 'd'/'c'
;           edits_range_delete the clipped slice; cursor lands
;           at top-left.
; Undo: for 'd'/'c' a single UNDO_KIND_TOO_LARGE header is written
; directly (multi-region undo deferred per Q2 Option A; `u` post-op
; surfaces msg_undo_too_large). For 'y' no undo entry — yank-only.
;
; The bounding rectangle is virtual (BH3): short lines contribute
; whatever bytes their EOL allows (0 if the line is past col_min;
; clipped to (line_length - col_min) if col_min < line_length <
; col_max+1; full rect width (col_max - col_min + 1) otherwise).
; The KIND_BLOCK yank format (AC9) is rows joined by LF separators
; with no trailing LF; empty rows still emit a separator LF.
; ----------------------------------------------------------------
_visual_op_block_arm:
    ;; Project rectangle via Story-3.5 helper (also fills the 5
    ;; visual_block_* projection cells we read for col / line-start data).
    CALL    visual_count_block_dims         ; HL = rows; BC = cols
    LD      (visual_op_block_rows), HL
    LD      (visual_op_block_cols), BC

    ;; Compute col_min = min(anchor_col, cursor_col); col_max = max(...)
    LD      HL, (visual_block_anchor_col)
    LD      DE, (visual_block_cursor_col)
    OR      A
    SBC     HL, DE                          ; HL = anchor_col - cursor_col (signed)
    JR      C, .acol_lt
    ;; anchor_col >= cursor_col
    LD      HL, (visual_block_cursor_col)
    LD      (visual_op_block_col_min), HL
    LD      HL, (visual_block_anchor_col)
    LD      (visual_op_block_col_max), HL
    JR      .have_cols
.acol_lt:
    ;; anchor_col < cursor_col
    LD      HL, (visual_block_anchor_col)
    LD      (visual_op_block_col_min), HL
    LD      HL, (visual_block_cursor_col)
    LD      (visual_op_block_col_max), HL
.have_cols:

    ;; Compute top_ls = min(anchor_ls, cursor_ls)
    LD      HL, (visual_block_anchor_ls)
    LD      DE, (visual_block_cursor_ls)
    OR      A
    SBC     HL, DE                          ; HL = anchor_ls - cursor_ls (signed)
    JR      C, .anchor_above
    ;; anchor_ls >= cursor_ls: top_ls = cursor_ls
    LD      HL, (visual_block_cursor_ls)
    JR      .have_top
.anchor_above:
    LD      HL, (visual_block_anchor_ls)
.have_top:
    LD      (visual_op_block_top_ls), HL

    ;; --- Pass 1: sum yank bytes (with LF separators) ---
    LD      HL, 0
    LD      (visual_op_block_total_bytes), HL
    LD      HL, (visual_op_block_top_ls)
    LD      (visual_op_block_walker), HL
    LD      HL, (visual_op_block_rows)
    LD      (visual_op_block_remaining_rows), HL
.p1_loop:
    LD      HL, (visual_op_block_walker)
    CALL    motion_find_line_end            ; HL = old_line_end (LF pos or file_length)
    PUSH    HL                              ; [old_line_end]
    LD      DE, (visual_op_block_walker)
    OR      A
    SBC     HL, DE                          ; HL = line_length
    CALL    _visual_op_block_row_bytes      ; HL = bytes_this_row (BH3 clipped)
    LD      DE, (visual_op_block_total_bytes)
    ADD     HL, DE
    LD      (visual_op_block_total_bytes), HL
    LD      HL, (visual_op_block_remaining_rows)
    DEC     HL
    LD      (visual_op_block_remaining_rows), HL
    LD      A, H
    OR      L
    JR      Z, .p1_last
    ;; Not last row: add LF separator + advance walker (no shift in pass 1)
    LD      HL, (visual_op_block_total_bytes)
    INC     HL
    LD      (visual_op_block_total_bytes), HL
    POP     HL                              ; HL = old_line_end
    INC     HL                              ; walker = old_line_end + 1
    LD      (visual_op_block_walker), HL
    JR      .p1_loop
.p1_last:
    POP     HL                              ; discard saved old_line_end

    ;; --- Capacity check: total_bytes <= YANK_BUFFER_SIZE? ---
    LD      HL, YANK_BUFFER_SIZE
    LD      DE, (visual_op_block_total_bytes)
    OR      A
    SBC     HL, DE                          ; CF=1 iff total > capacity
    LD      A, 1
    JR      NC, .cap_ok
    XOR     A
.cap_ok:
    LD      (visual_op_block_yank_ok), A

    ;; --- For 'd' / 'c': record UNDO_KIND_TOO_LARGE direct
    ;; (multi-region undo deferred per Q2 Option A; Story 2.13
    ;; "every mutating op records SOMETHING" invariant preserved).
    LD      A, (visual_op_pending)
    CP      'y'
    JR      Z, .after_undo
    CALL    undo_clear
    LD      HL, (visual_op_block_top_ls)
    LD      BC, 0                           ; length semantically meaningless for TOO_LARGE
    LD      A, UNDO_KIND_TOO_LARGE
    CALL    undo_write_header
.after_undo:

    ;; --- Pass 2: per-row delete + optional yank-append (with shift-tracking) ---
    LD      HL, (visual_op_block_top_ls)
    LD      (visual_op_block_walker), HL
    LD      HL, (visual_op_block_rows)
    LD      (visual_op_block_remaining_rows), HL
    LD      HL, yank_buffer
    LD      (visual_op_block_yank_ptr), HL
.p2_loop:
    LD      HL, (visual_op_block_walker)
    CALL    motion_find_line_end            ; HL = old_line_end
    PUSH    HL                              ; [old_line_end] — for walker advance + last-row discard
    LD      DE, (visual_op_block_walker)
    OR      A
    SBC     HL, DE                          ; HL = line_length
    CALL    _visual_op_block_row_bytes      ; HL = bytes_this_row
    LD      (visual_op_range_bytes), HL     ; stash for walker advance + downstream ops
    LD      A, H
    OR      L
    JR      Z, .p2_after_op                 ; zero row → skip yank-append + delete

    ;; Compute delete_start = walker + col_min; stash for downstream ops
    LD      HL, (visual_op_block_col_min)
    LD      DE, (visual_op_block_walker)
    ADD     HL, DE
    LD      (visual_op_range_start), HL

    ;; If yank_ok: append bytes_this_row content bytes to yank_buffer
    LD      A, (visual_op_block_yank_ok)
    OR      A
    JR      Z, .p2_skip_append
    LD      BC, (visual_op_range_bytes)     ; BC = bytes_this_row
    LD      HL, (visual_op_range_start)     ; HL = source logical offset
    LD      DE, (visual_op_block_yank_ptr)  ; DE = yank-buffer write ptr
.p2_append_loop:
    PUSH    DE                              ; motion_byte_at_logical trashes DE
    CALL    motion_byte_at_logical          ; A = byte; HL preserved; BC preserved
    POP     DE
    LD      (DE), A
    INC     HL
    INC     DE
    DEC     BC
    LD      A, B
    OR      C
    JR      NZ, .p2_append_loop
    LD      (visual_op_block_yank_ptr), DE
.p2_skip_append:

    ;; For 'd' / 'c': delete bytes_this_row from delete_start
    LD      A, (visual_op_pending)
    CP      'y'
    JR      Z, .p2_after_op
    LD      HL, (visual_op_range_start)
    LD      BC, (visual_op_range_bytes)
    CALL    edits_range_delete              ; cursor := delete_start; bytes removed

.p2_after_op:
    ;; Decrement remaining_rows; branch on whether this was the last
    LD      HL, (visual_op_block_remaining_rows)
    DEC     HL
    LD      (visual_op_block_remaining_rows), HL
    LD      A, H
    OR      L
    JR      Z, .p2_last

    ;; Not last row: optional LF separator (empty rows STILL get LF sep per AC9)
    LD      A, (visual_op_block_yank_ok)
    OR      A
    JR      Z, .p2_skip_lf
    LD      HL, (visual_op_block_yank_ptr)
    LD      A, 0x0A
    LD      (HL), A
    INC     HL
    LD      (visual_op_block_yank_ptr), HL
.p2_skip_lf:

    ;; Advance walker.
    ;;   For 'd' / 'c': walker = old_line_end - bytes_this_row + 1 (shift-aware).
    ;;   For 'y':       walker = old_line_end + 1 (no shift).
    POP     HL                              ; HL = old_line_end (PUSHed at loop top)
    LD      A, (visual_op_pending)
    CP      'y'
    JR      Z, .p2_advance_y
    LD      DE, (visual_op_range_bytes)
    OR      A
    SBC     HL, DE                          ; HL = old_line_end - bytes_this_row
.p2_advance_y:
    INC     HL                              ; walker = (...) + 1 (past the LF)
    LD      (visual_op_block_walker), HL
    JP      .p2_loop

.p2_last:
    POP     HL                              ; discard saved old_line_end

    ;; --- Finalise yank register ---
    LD      A, (visual_op_block_yank_ok)
    OR      A
    JR      Z, .yank_refused
    LD      A, KIND_BLOCK
    LD      (yank_kind), A
    LD      HL, (visual_op_block_total_bytes)
    LD      (yank_length), HL
    JR      .set_cursor
.yank_refused:
    ;; SR6: yank register preserved on over-capacity; surface status.
    LD      HL, msg_yank_too_large
    XOR     A
    CALL    status_set_message

.set_cursor:
    ;; Cursor placement: top-left of bounding rectangle (vi-faithful
    ;; for d/c; for y we restore to top-left even though no delete
    ;; happened — the user may have moved cursor during the visual
    ;; session and vim's `vbY p`-then-`p` cursor lands at top-left).
    LD      HL, (visual_op_block_top_ls)
    LD      DE, (visual_op_block_col_min)
    ADD     HL, DE
    LD      (cursor_offset), HL

    ;; BH3 jagged-top clamp: when the top row of the bounding rectangle
    ;; is SHORTER than col_min (jagged left edge on the top row), the
    ;; raw top_ls+col_min offset lands past that row's LF (or past EOF
    ;; if the top row is also the no-trailing-LF last line). Mirror
    ;; KIND_CHAR's x-style clamp: DEC if past EOF or on a LF. Applies
    ;; to all three operators (y/d/c) — for d/c the offset post-delete
    ;; can still land on the trailing LF of a now-empty top row.
    LD      A, H
    OR      L
    JR      Z, .b_have_cursor               ; cursor == 0: no clamp possible
    CALL    motion_byte_at_logical          ; HL preserved
    JR      C, .b_cursor_clamp              ; past EOF → clamp back
    CP      0x0A
    JR      NZ, .b_have_cursor              ; real byte → leave
.b_cursor_clamp:
    DEC     HL
    LD      (cursor_offset), HL
.b_have_cursor:

    ;; Dispatch on operator
    LD      A, (visual_op_pending)
    CP      'c'
    JR      Z, .b_dispatch_c
    ;; 'y' or 'd': for 'y' no redraw needed (buffer unchanged);
    ;; for 'd' commit dirty+redraw first.
    CP      'y'
    JR      Z, .b_dispatch_dy
    CALL    edits_dirty_and_redraw          ; 'd' — buffer mutated
.b_dispatch_dy:
    ;; Branch on yank-refusal flag to preserve msg_yank_too_large
    ;; if it was surfaced; otherwise emit the empty mode banner.
    LD      A, (visual_op_block_yank_ok)
    OR      A
    JP      NZ, enter_normal_mode           ; success — clean mode change
    ;; Refusal: preserve msg_yank_too_large surface; do mode-write inline.
    LD      A, MODE_NORMAL
    LD      (mode_byte), A
    JP      parser_clear
.b_dispatch_c:
    CALL    edits_dirty_and_redraw          ; 'c' — buffer mutated
    JP      enter_insert_mode               ; AC7: insert banner overwrites status (transient flash)


; ----------------------------------------------------------------
; _visual_op_block_row_bytes  (BH3 clip helper)
; Compute bytes_this_row for the current rectangle row.
;   bytes = max(0, min(col_max + 1, line_length) - col_min)
; In:      HL = line_length (>= 0).
; Out:     HL = bytes_this_row (0 .. col_max - col_min + 1).
; Reads:   (visual_op_block_col_min), (visual_op_block_col_max).
; Trashes: A, BC, DE, HL, F.
; ----------------------------------------------------------------
_visual_op_block_row_bytes:
    LD      DE, (visual_op_block_col_max)
    INC     DE                              ; DE = col_max + 1
    PUSH    HL                              ; [line_length]
    OR      A
    SBC     HL, DE                          ; HL = line_length - (col_max + 1); CF=1 if line_length < col_max+1
    POP     HL                              ; HL = line_length; flags preserved
    JR      C, .have_end                    ; line_length < col_max + 1 → end = line_length
    LD      H, D
    LD      L, E                            ; end = col_max + 1 = DE
.have_end:
    LD      DE, (visual_op_block_col_min)
    OR      A
    SBC     HL, DE                          ; HL = end - col_min; CF=1 if end < col_min
    RET     NC                              ; HL = bytes_this_row (>= 0)
    LD      HL, 0                           ; end < col_min → bytes_this_row = 0
    RET


; ----------------------------------------------------------------
; _visual_op_delete_yank_or_change  (AC6 — CHAR / LINE shared finalisation)
; Branches on visual_op_pending to one of three paths:
;   'd' — undo_record_delete + yank-copy (with refusal) + edits_range_delete
;         + cursor placement (CHAR x-style clamp; LINE op_dd three-way) +
;         edits_dirty_and_redraw + JP enter_normal_mode.
;   'c' — same as 'd' through delete; tail-JP enter_insert_mode instead.
;         Story 2.13's undo_insert_exit_record fires at INSERT-exit and
;         upgrades the DELETE entry to REPLACE (phase 2 — inherited).
;   'y' — yank-only (no undo, no delete); cursor restored to range_start
;         (Q1 Option A — matches vim's visual-yank behaviour); JP
;         enter_normal_mode.
;
; In:      HL = range_start; BC = total_bytes; A = KIND_CHAR | KIND_LINE.
;          (visual_op_pending) = operator byte.
; Out:     mode_byte updated via the terminal tail-JP; cursor_offset
;          placed per submode + operator semantics; yank register
;          updated (or PRESERVED on over-capacity refusal); undo
;          recorded for d / c; status surfaces msg_yank_too_large
;          on refusal.
; ----------------------------------------------------------------
_visual_op_delete_yank_or_change:
    ;; 0-byte defensive guard. Stash kind across the A=B|C test.
    LD      D, A
    LD      A, B
    OR      C
    JP      Z, enter_normal_mode            ; silent no-op (mode + parser cleared)
    LD      A, D
    LD      (visual_op_range_start), HL
    LD      (visual_op_range_bytes), BC
    LD      (visual_op_yank_kind), A
    ;; Init yank-refusal flag (1 = ok; cleared on over-capacity).
    ;; Reused from BLOCK arm — module-local cell shared because the
    ;; CHAR/LINE shared finalisation never executes the BLOCK arm
    ;; concurrently (visual_apply_operator picks one arm per call).
    ;; The flag persists past the operator-tail dispatch to decide
    ;; whether enter_normal_mode (which would clobber status_buffer
    ;; via msg_mode_normal) is safe to call, or whether we have to
    ;; do a manual MODE_NORMAL write + parser_clear tail to preserve
    ;; the msg_yank_too_large surface.
    LD      A, 1
    LD      (visual_op_block_yank_ok), A

    LD      A, (visual_op_pending)
    CP      'y'
    JR      Z, .yank_only

    ;; 'd' or 'c': undo + yank + delete + cursor + dispatch.
    ;; undo_record_delete handles its own capacity check (TOO_LARGE
    ;; for payloads > UNDO_PAYLOAD_SIZE); the gap-buffer bytes are
    ;; still at pre-delete logical positions here.
    CALL    undo_record_delete

    LD      HL, (visual_op_range_start)
    LD      BC, (visual_op_range_bytes)
    LD      A, (visual_op_yank_kind)
    CALL    edits_copy_to_yank              ; CF=1 on over-capacity
    JR      NC, .yank_ok
    ;; Refused: surface status; clear refusal flag so the tail
    ;; avoids enter_normal_mode's status_buffer clobber. Deletion
    ;; STILL proceeds (SR6 "predictable failure mode").
    XOR     A
    LD      (visual_op_block_yank_ok), A
    LD      HL, msg_yank_too_large
    XOR     A
    CALL    status_set_message
.yank_ok:
    LD      HL, (visual_op_range_start)
    LD      BC, (visual_op_range_bytes)
    CALL    edits_range_delete              ; cursor := range_start; bytes removed

    ;; Post-delete cursor placement — branch on KIND.
    LD      A, (visual_op_yank_kind)
    CP      KIND_LINE
    JR      Z, .post_line_cursor
    ;; KIND_CHAR: op_compose_d's x-style EOL/EOF clamp (DEC cursor
    ;; if past EOF or on LF).
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .commit                      ; cursor == 0 — no clamp possible
    CALL    motion_byte_at_logical          ; HL preserved
    JR      C, .char_clamp                  ; past EOF → clamp
    CP      0x0A
    JR      NZ, .commit                     ; on a real byte → leave
.char_clamp:
    DEC     HL
    LD      (cursor_offset), HL
    JR      .commit
.post_line_cursor:
    ;; KIND_LINE: op_dd three-way placement.
    LD      HL, (cursor_offset)             ; cursor at range_start (post-delete)
    CALL    motion_byte_at_logical          ; HL preserved
    JR      NC, .commit                     ; cursor < new file_length → done
    LD      A, H
    OR      L
    JR      Z, .commit                      ; cursor == 0 → empty buffer / BOF
    ;; Case 3: cursor = motion_find_line_start(cursor - 1)
    DEC     HL
    CALL    motion_find_line_start
    LD      (cursor_offset), HL

.commit:
    CALL    edits_dirty_and_redraw
    LD      A, (visual_op_pending)
    CP      'c'
    JP      Z, enter_insert_mode            ; 'c': INSERT banner is per-spec (AC7 transient flash)
    ;; 'd': branch on refusal flag.
    LD      A, (visual_op_block_yank_ok)
    OR      A
    JP      NZ, enter_normal_mode           ; success — emit empty mode banner
    ;; Refusal: preserve msg_yank_too_large; do mode change inline.
    LD      A, MODE_NORMAL
    LD      (mode_byte), A
    JP      parser_clear

.yank_only:
    ;; 'y': pure read; no buffer mutation; no undo entry.
    LD      HL, (visual_op_range_start)
    LD      BC, (visual_op_range_bytes)
    LD      A, (visual_op_yank_kind)
    CALL    edits_copy_to_yank
    JR      NC, .yank_only_ok
    ;; Refused: surface status; flag refusal for tail dispatch.
    XOR     A
    LD      (visual_op_block_yank_ok), A
    LD      HL, msg_yank_too_large
    XOR     A
    CALL    status_set_message
.yank_only_ok:
    ;; Cursor at range_start (Q1 Option A — matches vim's `vwy` semantic).
    LD      HL, (visual_op_range_start)
    LD      (cursor_offset), HL
    LD      A, (visual_op_block_yank_ok)
    OR      A
    JP      NZ, enter_normal_mode           ; success
    ;; Refusal: preserve msg_yank_too_large.
    LD      A, MODE_NORMAL
    LD      (mode_byte), A
    JP      parser_clear


;; ============================================================
;; --- Public entry: visual_apply_shift (Story 3.7 — `>` / `<`) ---
;; ============================================================

; ----------------------------------------------------------------
; visual_apply_shift
; Visual-mode line-class shift. Submode-agnostic: anchor and cursor
; are both projected through motion_find_line_start (no-op-ish for
; VIS_LINE's already-aligned anchor; actual walk for VIS_CHAR /
; VIS_BLOCK), SBC-and-swap yields (promoted_start, walker), the
; walker's line-end is found, promoted_end = HL + 1 unconditionally
; (works for both LF-terminated and at-EOF cases — the per-line walk
; in edits_indent_walk operates on line_starts in [start, end), and
; bottom_line_ls < promoted_end whenever the bottom line is part of
; the range). VIS_BLOCK's column range is IGNORED — vi-faithful for
; shift (distinct from the per-row column-bounded path Story 3.6
; uses for d/y/c and Story 3.8 will use for `~`).
;
; Per-line work delegated to edits_indent_walk (Story 2.11 helper,
; mode byte 0 = indent / 1 = dedent). Undo recorded via the shared
; edits_record_walk (Story 2.13 Q6 Option B) — kind UNDO_KIND_INDENT_WALK
; for `>` or UNDO_KIND_DEDENT_WALK for `<`. The walk's dirty flag
; (edits_indent_walk_dirty) determines whether record_walk +
; edits_dirty_and_redraw fire — on no-op walks (e.g. `<` over a
; selection whose lines all lack a leading INDENT_BYTE) the undo
; register stays EMPTY from the pre-walk undo_clear (Q3 Option A;
; mirrors op_compose_indent.ci_walk precedent — every mutating op
; records SOMETHING including EMPTY).
;
; Cursor lands at promoted_start (= line-start of the topmost
; selected line) per Q2 Option A — vi-faithful "top of selection"
; column 0. The FNW (first-non-whitespace) divergence is the same
; gap Story 2.11 NORMAL-mode `>>`/`<<` carries; deferred to a polish
; story.
;
; Mode flips to NORMAL via the enter_normal_mode tail-JP. Per Q1
; Option A — accept the msg_file_too_large clobber on partial-overflow
; walks (matches op_compose_indent precedent; flag-based carve-out
; deferred).
;
; AR23 contract (also documented in module-header Register conventions).
; In:      A = operator byte ('<' | '>' — MC4 from dispatch_visual).
; Out:     every line whose start is in [min(anchor_ls, cursor_ls),
;          max_ls_line_end + 1) is shifted right ('>') or left ('<')
;          by one INDENT_BYTE; for '<' lines without leading INDENT_BYTE
;          are silent per-line no-ops via edits_indent_walk's
;          .iw_dedent CP INDENT_BYTE skip guard. cursor_offset =
;          promoted_start; mode_byte = MODE_NORMAL via enter_normal_mode
;          tail-JP. Undo recorded as UNDO_KIND_INDENT_WALK /
;          UNDO_KIND_DEDENT_WALK iff edits_indent_walk_dirty == 1
;          (no-op walks leave undo EMPTY).
; Trashes: A, BC, DE, HL, F + module-local cells (visual_op_pending,
;          visual_op_range_start, edits_indent_undo_start / _end,
;          edits_indent_walk_mode / _dirty / _end).
; Calls:   motion_find_line_start (CALL × 2 — anchor + cursor projection);
;          motion_find_line_end (CALL × 1 — MAX line-start → its line-end);
;          undo_clear (CALL);
;          edits_indent_walk (CALL);
;          edits_record_walk (CALL on dirty path);
;          edits_dirty_and_redraw (CALL on dirty path);
;          enter_normal_mode (JP tail).
; ----------------------------------------------------------------
visual_apply_shift:
    LD      (visual_op_pending), A          ; stash operator byte ('<' | '>')

    ;; Project anchor and cursor to line-starts (submode-agnostic).
    LD      HL, (visual_anchor)
    CALL    motion_find_line_start          ; HL = anchor_ls
    PUSH    HL                              ; [anchor_ls]
    LD      HL, (cursor_offset)
    CALL    motion_find_line_start          ; HL = cursor_ls
    POP     DE                              ; DE = anchor_ls; HL = cursor_ls

    ;; SBC-and-swap: pick min as promoted_start, MAX as walker.
    PUSH    HL                              ; [cursor_ls]
    OR      A
    SBC     HL, DE                          ; HL = cursor_ls - anchor_ls (signed)
    POP     HL                              ; HL = cursor_ls; flags preserved
    JR      C, .vsh_backward
    ;; Forward / equal: promoted_start = anchor_ls (DE); walker = cursor_ls (HL).
    LD      (visual_op_range_start), DE
    JR      .vsh_walk_end
.vsh_backward:
    ;; Backward (cursor_ls < anchor_ls): promoted_start = cursor_ls (HL);
    ;; walker = anchor_ls (DE).
    LD      (visual_op_range_start), HL
    EX      DE, HL                          ; HL = anchor_ls (walker)
.vsh_walk_end:
    ;; HL = walker (MAX line-start). Walk to its line-end.
    CALL    motion_find_line_end            ; HL = LF pos OR file_length (CF=1 no-LF)
    INC     HL                              ; promoted_end = HL + 1 (unconditional)
    EX      DE, HL                          ; DE = promoted_end
    LD      HL, (visual_op_range_start)     ; HL = promoted_start

    ;; Stash undo metadata mirroring op_compose_indent.ci_walk. The
    ;; cell-based start/end pair is the Story 2.11 contract; the
    ;; post-walk authority for length is edits_indent_walk_end
    ;; (Story 2.13 Q6 Option B). edits_indent_undo_end is kept for
    ;; callsite-symmetry (dead-store post-Q6; cleanup logged as
    ;; deferred-work polish).
    LD      (edits_indent_undo_start), HL
    EX      DE, HL                          ; HL = end
    LD      (edits_indent_undo_end), HL
    EX      DE, HL                          ; restore HL = start, DE = end
    CALL    undo_clear                      ; pre-walk: undo := EMPTY

    ;; Operator byte → mode byte: '>' = 0 (indent), '<' = 1 (dedent).
    ;; LD A,imm does not touch flags, so the Z from CP '<' survives
    ;; to the JR NZ check.
    LD      A, (visual_op_pending)
    CP      '<'
    LD      A, 0                            ; default = indent mode
    JR      NZ, .vsh_mode_ready
    INC     A                               ; A = 1 = dedent mode
.vsh_mode_ready:
    CALL    edits_indent_walk

    ;; Dirty check — on no-op walk (e.g. `<` across lines with no
    ;; leading INDENT_BYTE) skip record + redraw; undo stays EMPTY.
    LD      A, (edits_indent_walk_dirty)
    OR      A
    JR      Z, .vsh_no_change

    ;; Operator byte → undo kind. Same CP shape; LD A,imm preserves Z.
    LD      A, (visual_op_pending)
    CP      '<'
    LD      A, UNDO_KIND_INDENT_WALK
    JR      NZ, .vsh_have_kind
    LD      A, UNDO_KIND_DEDENT_WALK
.vsh_have_kind:
    CALL    edits_record_walk               ; reads edits_indent_walk_end (Q6 Option B)
    CALL    edits_dirty_and_redraw

.vsh_no_change:
    ;; Cursor at promoted_start (vi-faithful top-of-selection column 0;
    ;; FNW deferred).
    LD      HL, (visual_op_range_start)
    LD      (cursor_offset), HL
    JP      enter_normal_mode               ; tail-JP — flips mode, parser_clear


;; ============================================================
;; --- Internal helper: visual_count_lines (Story 3.4) ---
;; ============================================================

; ----------------------------------------------------------------
; visual_count_lines
; Compute the line count of the active VIS_LINE selection. Walks
; the gap buffer between visual_anchor (a line-start, pinned by
; visual_enter_line) and motion_find_line_start(cursor_offset),
; counting LF bytes in the half-open range [min, max). Returns
; line count = LFs + 1.
;
; Math identity: walking from one line-start to another line-start,
; the number of LFs encountered in [min, max) equals the difference
; in line indices. Therefore line_count = LFs + 1 regardless of
; where max lands within its line — the cursor doesn't have to be
; on its line-start for the math to come out right, but the anchor
; MUST be (which is the AC2 invariant pinned at visual_enter_line).
;
; In:      (none — reads cursor_offset, visual_anchor from state.inc)
; Out:     HL = line count (1..65535); cursor_offset / visual_anchor
;          UNCHANGED.
; Trashes: A, BC, DE, HL, F
; Calls:   motion_find_line_start (CALL — resolves cursor's line-
;          start; preserves BC, trashes A/DE/F);
;          motion_byte_at_logical (CALL — pure read; preserves
;          BC and HL on every path, trashes A/DE/F).
; ----------------------------------------------------------------
visual_count_lines:
    LD      HL, (cursor_offset)
    CALL    motion_find_line_start      ; HL = cursor's line-start (LS)
    LD      DE, (visual_anchor)         ; DE = anchor (also a LS)
    OR      A                           ; clear CF for SBC
    SBC     HL, DE                      ; HL = cursor_ls - anchor (signed)
    JR      Z, .single_line             ; same line-start → count = 1
    JR      NC, .forward                ; cursor_ls > anchor (forward)
    ;; Backward: cursor_ls < anchor; HL holds 2s-comp negative diff.
    ;; Recover cursor_ls into HL via ADD; DE = anchor still.
    ;; That already gives HL = cursor_ls (min), DE = anchor (max).
    ADD     HL, DE                      ; HL = cursor_ls (min); DE = anchor (max)
    JR      .walk
.forward:
    ;; HL = cursor_ls - anchor (positive); DE = anchor.
    ;; Recover cursor_ls into HL via ADD, then swap so HL=min.
    ADD     HL, DE                      ; HL = cursor_ls (max); DE = anchor (min)
    EX      DE, HL                      ; HL = anchor (min); DE = cursor_ls (max)
.walk:
    LD      BC, 0                       ; LF count
.loop:
    LD      A, H
    CP      D
    JR      NZ, .scan
    LD      A, L
    CP      E
    JR      Z, .done                    ; HL == DE → walked the half-open range
.scan:
    PUSH    DE                          ; motion_byte_at_logical trashes DE
    CALL    motion_byte_at_logical      ; A = byte at HL; CF=0 in-file
    POP     DE
    CP      0x0A
    JR      NZ, .next
    INC     BC                          ; LF count++
.next:
    INC     HL
    JR      .loop
.done:
    LD      H, B
    LD      L, C
    INC     HL                          ; line count = LFs + 1
    RET
.single_line:
    LD      HL, 1                       ; same line-start → count = 1
    RET


;; ============================================================
;; --- Internal helper: visual_count_block_dims (Story 3.5) ---
;; ============================================================

; ----------------------------------------------------------------
; visual_count_block_dims
; Compute the bounding rows × cols of the active VIS_BLOCK
; rectangle. Projects visual_anchor (an offset) and cursor_offset
; to (row, col) via motion_find_line_start; rows are the LF count
; in [min(anchor_ls, cursor_ls), max(...)) plus 1 (same shape as
; visual_count_lines but the anchor is NOT assumed to be a line-
; start the way VIS_LINE assumes); cols are |cursor_col -
; anchor_col| + 1 (pure byte arithmetic, no LF walk).
;
; The five module-local DEFW cells (visual_block_anchor_ls /
; _anchor_col / _cursor_ls / _cursor_col / _temp_rows) act as
; projection scratch. The cells are written once per call and
; valid only between this helper's entry and its RET — no caller
; reads them.
;
; **CRITICAL AR14 invariant** — NO buffer mutation. The rectangle
; is virtual (BH3); the helper reads cursor_offset / visual_anchor
; and walks the buffer via motion_byte_at_logical / motion_find_
; line_start. NO gapbuf_insert / gapbuf_delete / gapbuf_move_gap
; calls and NO writes to gap_start / gap_end. Short lines in the
; vertical extent are NOT padded.
;
; In:      (none — reads cursor_offset, visual_anchor from state.inc)
; Out:     HL = rows (1..65535); BC = cols (1..65535);
;          cursor_offset / visual_anchor UNCHANGED; module-local
;          DEFW cells clobbered.
; Trashes: A, BC, DE, HL, F
; Calls:   motion_find_line_start (CALL — twice — for anchor and
;          cursor; preserves BC, trashes A/DE/F per its AR23 contract);
;          motion_byte_at_logical (CALL — inner LF-walk loop;
;          PUSH/POP DE around the call per the Story-3.4 DE-trash
;          gotcha; preserves BC and HL, trashes A/DE/F).
; ----------------------------------------------------------------
visual_count_block_dims:
    ;; --- Project anchor offset → (anchor_ls, anchor_col) ---
    LD      HL, (visual_anchor)
    PUSH    HL                              ; save anchor offset across motion_find_line_start
    CALL    motion_find_line_start          ; HL = anchor's line-start (anchor_ls)
    LD      (visual_block_anchor_ls), HL
    POP     DE                              ; DE = anchor offset (saved)
    EX      DE, HL                          ; HL = anchor offset; DE = anchor_ls
    OR      A                               ; clear CF for SBC
    SBC     HL, DE                          ; HL = anchor_offset - anchor_ls = anchor_col
    LD      (visual_block_anchor_col), HL

    ;; --- Project cursor offset → (cursor_ls, cursor_col) ---
    LD      HL, (cursor_offset)
    PUSH    HL                              ; save cursor offset across motion_find_line_start
    CALL    motion_find_line_start          ; HL = cursor's line-start (cursor_ls)
    LD      (visual_block_cursor_ls), HL
    POP     DE                              ; DE = cursor offset (saved)
    EX      DE, HL                          ; HL = cursor offset; DE = cursor_ls
    OR      A                               ; clear CF for SBC
    SBC     HL, DE                          ; HL = cursor_offset - cursor_ls = cursor_col
    LD      (visual_block_cursor_col), HL

    ;; --- Compute rows via LF walk over [min(anchor_ls, cursor_ls), max) ---
    ;; Reuses the SBC-and-swap pattern from visual_count_lines —
    ;; the math identity is the same (LFs in [min, max) + 1) but
    ;; the anchor is NOT guaranteed to be a line-start here, so
    ;; we walk between the two derived line-starts instead.
    LD      HL, (visual_block_cursor_ls)
    LD      DE, (visual_block_anchor_ls)
    OR      A                               ; clear CF for SBC
    SBC     HL, DE                          ; HL = cursor_ls - anchor_ls (signed)
    JR      Z, .single_row                  ; same line-start → rows = 1
    JR      NC, .rows_forward               ; cursor_ls > anchor_ls
    ;; Backward: HL = neg diff. ADD HL,DE recovers cursor_ls into
    ;; HL with DE still = anchor_ls; cursor_ls (min) < anchor_ls (max).
    ADD     HL, DE                          ; HL = cursor_ls (min); DE = anchor_ls (max)
    JR      .rows_walk
.rows_forward:
    ;; Forward: HL = positive diff. ADD HL,DE recovers cursor_ls into HL,
    ;; then EX swaps so HL = anchor_ls (min); DE = cursor_ls (max).
    ADD     HL, DE                          ; HL = cursor_ls (max); DE = anchor_ls (min)
    EX      DE, HL                          ; HL = anchor_ls (min); DE = cursor_ls (max)
.rows_walk:
    LD      BC, 0                           ; LF count accumulator
.rows_loop:
    LD      A, H
    CP      D
    JR      NZ, .rows_scan
    LD      A, L
    CP      E
    JR      Z, .rows_done                   ; HL == DE → walked the half-open range
.rows_scan:
    PUSH    DE                              ; motion_byte_at_logical trashes DE
    CALL    motion_byte_at_logical          ; A = byte at HL; CF=0 in-file
    POP     DE
    CP      0x0A
    JR      NZ, .rows_next
    INC     BC                              ; LF count++
.rows_next:
    INC     HL
    JR      .rows_loop
.rows_done:
    LD      H, B
    LD      L, C
    INC     HL                              ; rows = LFs + 1
    LD      (visual_block_temp_rows), HL    ; stash rows across cols compute
    JR      .compute_cols
.single_row:
    LD      HL, 1
    LD      (visual_block_temp_rows), HL    ; stash rows = 1

.compute_cols:
    ;; cols = |cursor_col - anchor_col| + 1. Pure byte arithmetic;
    ;; same SBC-and-swap pattern as visual_extend.char_arm.
    LD      HL, (visual_block_cursor_col)
    LD      DE, (visual_block_anchor_col)
    OR      A                               ; clear CF for SBC
    SBC     HL, DE                          ; HL = cursor_col - anchor_col (signed)
    JR      NC, .cols_have_abs              ; forward / equal — HL already positive
    EX      DE, HL                          ; DE = (cursor_col - anchor_col) negative
    LD      HL, 0
    OR      A                               ; clear CF
    SBC     HL, DE                          ; HL = -(cursor_col - anchor_col) = |delta|
.cols_have_abs:
    INC     HL                              ; cols = |delta| + 1
    LD      B, H
    LD      C, L                            ; BC = cols
    LD      HL, (visual_block_temp_rows)    ; recover rows into HL
    RET


;; ============================================================
;; --- Internal helpers: visual_compose_status / _status_line / _status_block ---
;; ============================================================

; ----------------------------------------------------------------
; visual_compose_status_line  (Story 3.4 — LINE submode banner)
; visual_compose_status       (Story 3.3 — CHAR submode banner)
; Both build "<prefix><count>\0" in status_compose_scratch and hand
; off to status_set_message for the AR12 status-row emit. They
; share a common tail (_visual_compose_finish) reached by JR fall-
; through; each named entry differs only in the prefix-ptr and
; prefix-length loaded into HL/BC before the LDIR.
;
; In (both):  HL = unsigned 16-bit count (1..65535) — chars (CHAR
;             arm) or lines (LINE arm).
; Out:        status_buffer pre-padded; status_dirty = 1.
; Trashes:    A, BC, DE, HL, F
; Calls:      status_u16_to_dec (CALL); status_set_message (tail-JP).
;
; Layout:
;   - LDIR the prefix bytes (no NUL) from msg_mode_visual{,_line}_prefix
;     into status_compose_scratch.
;   - status_u16_to_dec writes 1..5 decimal digits at DE (advancing).
;   - Write a NUL terminator at the post-digits position so
;     status_set_message's null-aware copy_loop stops there.
;   - Load HL = status_compose_scratch, XOR A (non-error code),
;     and tail-JP status_set_message.
; ----------------------------------------------------------------
; visual_compose_status_block  (Story 3.5 — BLOCK submode banner)
; Standalone body — does NOT share _visual_compose_finish with the
; CHAR / LINE entries. The block format emits TWO numeric params
; (rows + cols) separated by a literal 'x'; the CHAR/LINE shared
; tail (HL = single count) cannot cleanly host this without IX-
; parametrization or a stateful "second number?" flag (~+15 B for
; ~+5 B saved), so the standalone body is cheaper and clearer.
;
; In:      HL = rows (1..65535); BC = cols (1..65535)
; Out:     status_buffer pre-padded with "-- visual block -- <rows>x<cols>";
;          status_dirty = 1
; Trashes: A, BC, DE, HL, F
; Calls:   status_u16_to_dec (CALL — twice, once per number);
;          status_set_message (tail-JP — AR12 funnel).
; Depends: status_u16_to_dec must advance DE past the emitted digits.
;          The literal 'x' write and the NUL terminator both rely on
;          DE pointing one-past-the-last-digit on return.
visual_compose_status_block:
    PUSH    BC                                  ; save cols across prefix LDIR + rows emit
    PUSH    HL                                  ; save rows across prefix LDIR
    LD      HL, msg_mode_visual_block_prefix
    LD      BC, MSG_MODE_VISUAL_BLOCK_PREFIX_LEN ; 19 bytes
    LD      DE, status_compose_scratch
    LDIR                                        ; DE -> first byte past prefix
    POP     HL                                  ; restore rows
    CALL    status_u16_to_dec                   ; emits 1..5 rows digits at (DE); advances DE
    LD      A, 'x'
    LD      (DE), A
    INC     DE
    POP     HL                                  ; restore cols
    CALL    status_u16_to_dec                   ; emits 1..5 cols digits at (DE); advances DE
    XOR     A
    LD      (DE), A                             ; NUL terminator for status_set_message
    LD      HL, status_compose_scratch
    XOR     A                                   ; non-error code arg (AR16)
    JP      status_set_message                  ; tail-JP — AR12 funnel
visual_compose_status_line:
    PUSH    HL                                 ; save count across prefix copy
    LD      HL, msg_mode_visual_line_prefix
    LD      BC, MSG_MODE_VISUAL_LINE_PREFIX_LEN ; 18 bytes
    JR      _visual_compose_finish
visual_compose_status:
    PUSH    HL                                 ; save count across prefix copy
    LD      HL, msg_mode_visual_prefix
    LD      BC, MSG_MODE_VISUAL_PREFIX_LEN     ; 13 bytes
    ;; fall through to the shared tail

; _visual_compose_finish — private label; entries fall through
; here; do NOT call directly. Expects HL = prefix ptr, BC = prefix
; length, top-of-stack = saved count.
_visual_compose_finish:
    LD      DE, status_compose_scratch
    LDIR                                       ; DE -> first byte past prefix
    POP     HL                                 ; restore count
    CALL    status_u16_to_dec                  ; emits 1..5 digits at (DE); advances DE past
    XOR     A
    LD      (DE), A                            ; NUL terminator for status_set_message
    LD      HL, status_compose_scratch
    XOR     A                                  ; non-error code arg (AR16)
    JP      status_set_message                 ; tail-JP — AR12 funnel


;; --- Module-local constants ---
; Length of the "-- visual -- " prefix copied by visual_compose_status
; (13 bytes: two dashes, space, "visual", space, two dashes, trailing
; space — matches the byte run before the NUL in msg_mode_visual_prefix
; at src/statusln.asm). NOT including the NUL — the digits land
; immediately after the trailing space.
MSG_MODE_VISUAL_PREFIX_LEN      EQU 13
; Length of the "-- visual line -- " prefix copied by
; visual_compose_status_line (18 bytes: same shape as the CHAR
; prefix with "line " inserted between "visual" and the closing
; "-- "). NOT including the NUL — digits land at offset 18.
MSG_MODE_VISUAL_LINE_PREFIX_LEN EQU 18
; Length of the "-- visual block -- " prefix copied by
; visual_compose_status_block (19 bytes: same shape as the LINE
; prefix with "block " replacing "line "). NOT including the NUL
; — rows digits land at offset 19, then a literal 'x', then the
; cols digits, then visual_compose_status_block writes the NUL
; terminator for status_set_message.
MSG_MODE_VISUAL_BLOCK_PREFIX_LEN EQU 19
; Worst-case banner: prefix (19) + 5 rows digits + 'x' + 5 cols digits + NUL = 31 B.
; Pin the status_compose_scratch capacity so a future shrink fails the build.
    ASSERT MSG_MODE_VISUAL_BLOCK_PREFIX_LEN + 5 + 1 + 5 + 1 <= 48   ; status_compose_scratch size


;; ============================================================
;; --- Module-local data (Story 3.5 — visual_count_block_dims
;;     projection scratch) ---
;; ============================================================
; Five 16-bit cells used by visual_count_block_dims as projection
; scratch — anchor_ls / anchor_col / cursor_ls / cursor_col and
; the temp_rows stash that carries the row count across the cols
; compute. Cells are clobbered on every call; values are valid
; ONLY between the helper's entry and its RET — no caller reads
; them. Module-local; NOT exported via inc/state.inc. Mirrors the
; status_dec_dest pattern in src/statusln.asm (module-local DEFW
; scratch for inter-helper marshalling).
;
; NOTE: visual_apply_operator (Story 3.6) lands above. Its body uses
; its own module-local scratch group (visual_op_* cells below) — the
; Story 3.5 visual_block_* group declared here is reused ONLY by
; visual_count_block_dims and remains valid for the duration of THAT
; helper's call (the BLOCK arm of visual_apply_operator calls
; visual_count_block_dims as its first step, then COPIES the
; projection cells it needs into the visual_op_block_* group before
; doing any further work).
visual_block_anchor_ls:   DEFW 0
visual_block_anchor_col:  DEFW 0
visual_block_cursor_ls:   DEFW 0
visual_block_cursor_col:  DEFW 0
visual_block_temp_rows:   DEFW 0


;; ============================================================
;; --- Module-local data (Story 3.6 — visual_apply_operator scratch) ---
;; ============================================================
; Twelve cells (10 DEFW + 2 DEFB) for the operator dispatch +
; CHAR / LINE shared finalisation + BLOCK arm pass-1 / pass-2 loop
; state. Cleared and re-written by visual_apply_operator at every
; call; values valid ONLY between the helper's entry and its
; terminal tail-JP (enter_normal_mode for d/y; enter_insert_mode
; for c). Module-local; never exported via inc/state.inc.
;
; The visual_block_* group above (Story 3.5) and the visual_op_*
; group below are INDEPENDENT scratch groups (not a superset
; relationship). visual_block_* is owned by visual_count_block_dims;
; visual_op_block_* is owned by _visual_op_block_arm's pass-1 +
; pass-2 loops; they overlap conceptually (both relate to BLOCK
; projection) but their lifecycles are disjoint.

;; --- CHAR / LINE / BLOCK shared ---
visual_op_pending:        DEFB 0  ; operator byte ('c' | 'd' | 'y') stashed across CALL chain
visual_op_range_start:    DEFW 0  ; HL stash across the shared-finalisation sub-CALLs
visual_op_range_bytes:    DEFW 0  ; BC stash, same purpose
visual_op_yank_kind:      DEFB 0  ; KIND_CHAR / KIND_LINE from the CHAR / LINE arms

;; --- BLOCK arm scratch (pass-1 + pass-2 + capacity + finalise) ---
visual_op_block_rows:        DEFW 0  ; rows count cached from visual_count_block_dims HL return
visual_op_block_cols:        DEFW 0  ; cols count cached from BC return (debug; not read downstream)
visual_op_block_col_min:     DEFW 0  ; min(anchor_col, cursor_col)
visual_op_block_col_max:     DEFW 0  ; max(anchor_col, cursor_col)
visual_op_block_top_ls:      DEFW 0  ; min(anchor_ls, cursor_ls) — line-start of top row
visual_op_block_walker:      DEFW 0  ; per-row line-start walker (pass 1 + pass 2)
visual_op_block_total_bytes: DEFW 0  ; pass-1 yank-byte accumulator; pass-2 yank_length seed
visual_op_block_remaining_rows: DEFW 0  ; loop counter for both passes
visual_op_block_yank_ptr:    DEFW 0  ; pass-2 yank_buffer write pointer
visual_op_block_yank_ok:     DEFB 0  ; 0 = yank refused (over capacity); 1 = yank ok
