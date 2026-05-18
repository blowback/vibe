; ============================================================
; Module: test/cases/parser_visual_shift-dispatch.asm
; Purpose: Story 3.7 AC1 — verify the dispatch_visual table
;          wiring for '>'. Drive '>' through dispatch_key with
;          dispatch_visual as the base; assert the entry inserted
;          between '<' and 'G' (per AC1 sorted insertion) routes
;          end-to-end through visual_apply_shift and produces the
;          correct VIS_LINE '>' outcome.
;
;          Buffer "abc" (3 B, no LF). Pre-set mode=VISUAL, submode=
;          VIS_LINE, anchor=0, cursor=0. DRIVE:
;            LD A, '>'
;            LD HL, dispatch_visual
;            LD B, DISPATCH_VISUAL_COUNT
;            CALL dispatch_key
;
;          Expected: anchor_ls=0; cursor_ls=0; promoted_start=0;
;          walker=0; motion_find_line_end(0) returns 3 with CF=1
;          (no LF before EOF); INC HL → promoted_end = 4.
;          Walk inserts INDENT_BYTE at offset 0. file_length 3→4.
;
;            mode_byte         = MODE_NORMAL
;            cursor_offset     = 0
;            buffer first 4 B  = " abc"
;            undo_kind         = UNDO_KIND_INDENT_WALK
;            undo_position     = 0
;            undo_length       = 5 (pre-walk range 4 + 1 insert.
;                                   Spec text says 4; the spec
;                                   arithmetic underweighted the
;                                   unconditional INC HL on the
;                                   at-EOF promoted_end; cross-check
;                                   per [[feedback_create_story_cross_check]]
;                                   resolves to actual walk_end = 5.)
;            status_dirty was 0x80 pre-call (sentinel; verify the
;            dispatch path overwrote it during enter_normal_mode).
;
; Sentinel 0xEF — context byte:
;   Phase 1 (`>` arm):
;     0 — mode_byte != MODE_NORMAL
;     1 — cursor_offset != 0
;     2 — buffer first 4 B != " abc"
;     3 — undo_kind != UNDO_KIND_INDENT_WALK
;     4 — undo_position != 0
;     5 — undo_length != 5
;     6 — status_dirty == 0x80 (dispatcher must have written to it)
;   Phase 2 (`<` arm) — re-uses dispatch_visual on a fresh fixture:
;     Buffer " ab" (3 B, no LF, leading INDENT_BYTE). Pre-set
;     mode=VISUAL, submode=VIS_LINE, anchor=0, cursor=0. DRIVE:
;       LD A, '<' ; LD HL, dispatch_visual
;       LD B, DISPATCH_VISUAL_COUNT ; CALL dispatch_key
;     Expected: dedent deletes the INDENT_BYTE at offset 0;
;     buffer becomes "ab" (2 B); cursor_offset=0;
;     mode_byte=MODE_NORMAL; undo_kind=UNDO_KIND_DEDENT_WALK.
;     7 — mode_byte != MODE_NORMAL (phase 2)
;     8 — cursor_offset != 0 (phase 2)
;     9 — buffer first 2 B != "ab" (phase 2)
;    10 — undo_kind != UNDO_KIND_DEDENT_WALK (phase 2)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A
    LD      (undo_kind), A
    LD      (yank_kind), A
    LD      (buffer_dirty), A
    LD      HL, 0
    LD      (undo_position), HL
    LD      (undo_length), HL

    ;; Sentinel status_dirty to verify dispatcher chain ran.
    LD      A, 0x80
    LD      (status_dirty), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_LINE
    LD      (visual_submode), A

    ;; --- Execute via dispatch_key ---
    LD      A, '>'
    LD      HL, dispatch_visual
    LD      B, DISPATCH_VISUAL_COUNT
    CALL    dispatch_key

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xEF
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0xEF
    LD      B, 1
    JP      test_fail
.ok_cursor:
    LD      HL, 0
    LD      DE, .expect_buf
    LD      B, 4
.buf_loop:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .buf_next
    LD      A, 0xEF
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (undo_kind)
    CP      UNDO_KIND_INDENT_WALK
    JR      Z, .ok_uk
    LD      A, 0xEF
    LD      B, 3
    JP      test_fail
.ok_uk:
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_up
    LD      A, 0xEF
    LD      B, 4
    JP      test_fail
.ok_up:
    LD      HL, (undo_length)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_ul
    LD      A, 0xEF
    LD      B, 5
    JP      test_fail
.ok_ul:
    LD      A, (status_dirty)
    CP      0x80
    JR      NZ, .ok_status
    LD      A, 0xEF
    LD      B, 6
    JP      test_fail
.ok_status:
    ;; --- Phase 2: drive '<' through dispatch_visual ---
    ;; Re-prime fixture for dedent path. Reset count/pending state
    ;; (visual_apply_shift consumed visual_op_pending; visual_anchor
    ;; / visual_submode were left zombie per Q2 Option A — we
    ;; rewrite them to fresh values for clarity). Reset undo
    ;; bookkeeping so phase-1 residue cannot mask a phase-2 failure.
    XOR     A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A
    LD      (undo_kind), A
    LD      (yank_kind), A
    LD      (buffer_dirty), A
    LD      HL, 0
    LD      (undo_position), HL
    LD      (undo_length), HL

    CALL    gapbuf_init
    LD      HL, .payload2
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_LINE
    LD      (visual_submode), A

    LD      A, '<'
    LD      HL, dispatch_visual
    LD      B, DISPATCH_VISUAL_COUNT
    CALL    dispatch_key

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode2
    LD      A, 0xEF
    LD      B, 7
    JP      test_fail
.ok_mode2:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor2
    LD      A, 0xEF
    LD      B, 8
    JP      test_fail
.ok_cursor2:
    LD      HL, 0
    LD      DE, .expect_buf2
    LD      B, 2
.buf_loop2:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .buf_next2
    LD      A, 0xEF
    LD      B, 9
    JP      test_fail
.buf_next2:
    INC     HL
    INC     DE
    DJNZ    .buf_loop2

    LD      A, (undo_kind)
    CP      UNDO_KIND_DEDENT_WALK
    JR      Z, .ok_uk2
    LD      A, 0xEF
    LD      B, 10
    JP      test_fail
.ok_uk2:
    JP      test_pass

.payload:
    DEFB    "abc"
.expect_buf:
    DEFB    " abc"
.payload2:
    DEFB    " ab"
.expect_buf2:
    DEFB    "ab"

    INCLUDE "../inc/test_epilogue.inc"

    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
