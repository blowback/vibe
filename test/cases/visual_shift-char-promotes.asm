; ============================================================
; Module: test/cases/visual_shift-char-promotes.asm
; Purpose: Story 3.7 AC3 — VIS_CHAR line-promote. visual_apply_shift
;          projects anchor and cursor through motion_find_line_start
;          so a VIS_CHAR selection (offset-space anchor) line-
;          promotes to the full line. A 4-char selection anywhere
;          on line 2 shifts ALL of line 2, not just the 4 selected
;          bytes.
;
;          Buffer "abc\ndef\nghi" (11 B; LFs at 3, 7). Pre-seed
;          VIS_CHAR, anchor=5, cursor=5 (line 2 col 1 = 'e';
;          single-point selection on line 2). CALL with A='>'.
;
;          Expected: anchor_ls = motion_find_line_start(5) = 4;
;          cursor_ls = 4; min=4=promoted_start; walker=4;
;          motion_find_line_end(4) = 7 (LF); promoted_end = 8.
;          Walk processes line 2 only.
;
;            mode_byte         = MODE_NORMAL
;            cursor_offset     = 4 (promoted_start = line 2 line-start)
;            buffer first 12 B = "abc\n def\nghi"
;            undo_kind         = UNDO_KIND_INDENT_WALK
;            undo_position     = 4
;            undo_length       = 5 (pre-walk line 2 was 4 bytes
;                                    "def\n"; +1 insert = 5)
;            buffer_dirty      = 1
;
; Sentinel 0xDA — context byte:
;   0 — mode_byte != MODE_NORMAL
;   1 — cursor_offset != 4
;   2 — buffer first 12 B != "abc\n def\nghi"
;   3 — undo_kind != UNDO_KIND_INDENT_WALK
;   4 — undo_position != 4
;   5 — undo_length != 5
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
    LD      BC, 11
    LDIR
    LD      HL, GAP_BUFFER_BASE + 11
    LD      (gap_start), HL

    LD      HL, 5
    LD      (cursor_offset), HL
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A

    LD      A, '>'
    CALL    visual_apply_shift

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xDA
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
    LD      A, 0xDA
    LD      B, 1
    JP      test_fail
.ok_cursor:
    LD      HL, 0
    LD      DE, .expect_buf
    LD      B, 12
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
    LD      A, 0xDA
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (undo_kind)
    CP      UNDO_KIND_INDENT_WALK
    JR      Z, .ok_uk
    LD      A, 0xDA
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
    LD      A, 0xDA
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
    LD      A, 0xDA
    LD      B, 5
    JP      test_fail
.ok_ul:
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      A, 0xDA
    LD      B, 6
    JP      test_fail
.ok_dirty:
    JP      test_pass

.payload:
    DEFB    "abc", 0x0A, "def", 0x0A, "ghi"
.expect_buf:
    DEFB    "abc", 0x0A, " def", 0x0A, "ghi"

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
