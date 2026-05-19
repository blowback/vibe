; ============================================================
; Module: test/cases/visual_line_toggle-last-line-no-lf.asm
; Purpose: Story 4.1 AC5 T3 — VIS_LINE `~` against last line that
;          has no trailing LF. Exercises the `.at_eof` CF=1 branch
;          of motion_find_line_end (range_end is HL, NOT HL+1).
;          Buffer "abc\ndef" (7 B; line 1 "abc" ends at LF[3];
;          line 2 "def" has NO trailing LF). Pre-set mode=VISUAL,
;          submode=VIS_LINE, visual_anchor=4 (line 2 line-start),
;          cursor=6 (last byte of line 2). CALL visual_apply_case_toggle
;          A='~'. The LINE arm promotes the selection to whole line 2:
;          range_start=4, motion_find_line_end(4)→CF=1 HL=7 (=
;          file_length per the no-LF contract), range_end=HL=7 (not
;          HL+1 — CF=1 path skips the INC HL that would consume an
;          LF), BC = range_end - range_start = 3, bytes 4..6 toggle
;          "def"→"DEF". file_length unchanged at 7. cursor at 4.
;
; Sentinel 0x8B — context byte:
;   0 — mode_byte != MODE_NORMAL
;   1 — cursor_offset != 4 (range_start = line 2 line-start)
;   2 — buffer first 7 B != "abc\nDEF"
;   3 — undo_kind != UNDO_KIND_CASE_TOGGLE
;   4 — undo_position != 4
;   5 — undo_length != 3 (BC; last-line no-LF case = end exclusive without LF)
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
    LD      BC, 7
    LDIR
    LD      HL, GAP_BUFFER_BASE + 7
    LD      (gap_start), HL

    LD      HL, 6
    LD      (cursor_offset), HL
    LD      HL, 4
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_LINE
    LD      (visual_submode), A

    LD      A, '~'
    CALL    visual_apply_case_toggle

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0x8B
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      DE, 4
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0x8B
    LD      B, 1
    JP      test_fail
.ok_cursor:
    LD      HL, 0
    LD      DE, .expect_buf
    LD      B, 7
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
    LD      A, 0x8B
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (undo_kind)
    CP      UNDO_KIND_CASE_TOGGLE
    JR      Z, .ok_uk
    LD      A, 0x8B
    LD      B, 3
    JP      test_fail
.ok_uk:
    LD      HL, (undo_position)
    LD      DE, 4
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_up
    LD      A, 0x8B
    LD      B, 4
    JP      test_fail
.ok_up:
    LD      HL, (undo_length)
    LD      DE, 3
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_ul
    LD      A, 0x8B
    LD      B, 5
    JP      test_fail
.ok_ul:
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      A, 0x8B
    LD      B, 6
    JP      test_fail
.ok_dirty:
    JP      test_pass

.payload:
    DEFB    "abc", 0x0A, "def"
.expect_buf:
    DEFB    "abc", 0x0A, "DEF"

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
