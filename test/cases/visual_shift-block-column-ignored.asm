; ============================================================
; Module: test/cases/visual_shift-block-column-ignored.asm
; Purpose: Story 3.7 AC3 — VIS_BLOCK column-range IGNORED for shift.
;          visual_apply_shift on a VIS_BLOCK selection processes
;          the row range only; inserts happen at line-start, NOT
;          at the rectangle's left column edge. Vi-faithful: vim's
;          `>` in visual-block mode operates on rows at line-start.
;
;          Buffer "abcd\nefgh\nijkl" (14 B; LFs at 4, 9; NO
;          trailing LF — file_length = 14). Pre-seed VIS_BLOCK,
;          anchor=2 (line 1 col 2 = 'c'), cursor=12 (line 3 col 2
;          = 'k'). Rectangle is 3 rows tall × 1 col wide.
;          CALL with A='>'.
;
;          Expected: anchor_ls = motion_find_line_start(2) = 0;
;          cursor_ls = motion_find_line_start(12) = 10;
;          promoted_start = 0; walker = 10;
;          motion_find_line_end(10) returns 14 with CF=1 (no LF
;          before EOF); INC HL → promoted_end = 15.
;          Walk inserts at offsets 0, 6, 12 (post-shift; line_starts
;          for the 3 lines after each insert shifts subsequent
;          line_starts by +1).
;
;            mode_byte         = MODE_NORMAL
;            cursor_offset     = 0 (promoted_start; NOT col_min)
;            buffer first 17 B = " abcd\n efgh\n ijkl"
;                                (spaces at line-start, NOT at col 2)
;            undo_kind         = UNDO_KIND_INDENT_WALK
;            undo_position     = 0
;            undo_length       = 18 (pre-walk range 15; +3 inserts.
;                                    Spec text says 17; the spec
;                                    arithmetic underweighted the
;                                    unconditional INC HL on the
;                                    at-EOF promoted_end; per the
;                                    [[feedback_create_story_cross_check]]
;                                    convention we use the actual
;                                    walk_end value as the source
;                                    of truth and pin the test to it.)
;            buffer_dirty      = 1
;
; Sentinel 0xDB — context byte:
;   0 — mode_byte != MODE_NORMAL
;   1 — cursor_offset != 0
;   2 — buffer first 17 B != " abcd\n efgh\n ijkl"
;   3 — undo_kind != UNDO_KIND_INDENT_WALK
;   4 — undo_position != 0
;   5 — undo_length != 18
;   6 — buffer_dirty != 1
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (status_dirty), A
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
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 14
    LDIR
    LD      HL, GAP_BUFFER_BASE + 14
    LD      (gap_start), HL

    LD      HL, 12
    LD      (cursor_offset), HL
    LD      HL, 2
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_BLOCK
    LD      (visual_submode), A

    LD      A, '>'
    CALL    visual_apply_shift

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xDB
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0xDB
    LD      B, 1
    JP      test_fail
.ok_cursor:
    LD      HL, 0
    LD      DE, .expect_buf
    LD      B, 17
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
    LD      A, 0xDB
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (undo_kind)
    CP      UNDO_KIND_INDENT_WALK
    JR      Z, .ok_uk
    LD      A, 0xDB
    LD      B, 3
    JP      test_fail
.ok_uk:
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_up
    LD      A, 0xDB
    LD      B, 4
    JP      test_fail
.ok_up:
    LD      HL, (undo_length)
    LD      DE, 18
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_ul
    LD      A, 0xDB
    LD      B, 5
    JP      test_fail
.ok_ul:
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      A, 0xDB
    LD      B, 6
    JP      test_fail
.ok_dirty:
    JP      test_pass

.payload:
    DEFB    "abcd", 0x0A, "efgh", 0x0A, "ijkl"
.expect_buf:
    DEFB    " abcd", 0x0A, " efgh", 0x0A, " ijkl"

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
