; ============================================================
; Module: test/cases/visual_shift-backward.asm
; Purpose: Story 3.7 AC3 — backward-selection min/max symmetry.
;          visual_apply_shift's SBC-and-swap picks promoted_start =
;          min(anchor_ls, cursor_ls), NOT visual_anchor unconditionally.
;          If a future regression reverted to "promoted_start =
;          visual_anchor", this test would fail at the cursor and
;          buffer-content assertions.
;
;          Buffer "abc\ndef\nghi" (11 B; LFs at 3, 7). Pre-seed
;          VIS_LINE, anchor=4 (line 2 line-start), cursor=0 (line
;          1 — cursor BELOW anchor in offset but VISUALLY ABOVE,
;          aka "backward selection"). CALL with A='>'.
;
;          Expected: anchor_ls = motion_find_line_start(4) = 4;
;          cursor_ls = motion_find_line_start(0) = 0; SBC: 0-4 =
;          negative; backward branch picks promoted_start = cursor_ls
;          = 0 (the MIN, NOT visual_anchor); walker = anchor_ls = 4;
;          motion_find_line_end(4) = 7; promoted_end = 8.
;          Walk processes lines 1+2 (same range as visual_shift-right;
;          the test pins that the backward-direction SBC arm reaches
;          identical end-state).
;
;            mode_byte         = MODE_NORMAL
;            cursor_offset     = 0 (promoted_start = MIN, NOT anchor=4)
;            buffer first 13 B = " abc\n def\nghi"
;            undo_kind         = UNDO_KIND_INDENT_WALK
;            undo_position     = 0
;            undo_length       = 10
;            buffer_dirty      = 1
;
; Sentinel 0xDC — context byte:
;   0 — mode_byte != MODE_NORMAL
;   1 — cursor_offset != 0 (regression risk: 4 if anchor used as start)
;   2 — buffer first 13 B != " abc\n def\nghi"
;   3 — undo_kind != UNDO_KIND_INDENT_WALK
;   4 — undo_position != 0
;   5 — undo_length != 10
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

    LD      HL, 0
    LD      (cursor_offset), HL
    LD      HL, 4
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_LINE
    LD      (visual_submode), A

    LD      A, '>'
    CALL    visual_apply_shift

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xDC
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0xDC
    LD      B, 1
    JP      test_fail
.ok_cursor:
    LD      HL, 0
    LD      DE, .expect_buf
    LD      B, 13
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
    LD      A, 0xDC
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (undo_kind)
    CP      UNDO_KIND_INDENT_WALK
    JR      Z, .ok_uk
    LD      A, 0xDC
    LD      B, 3
    JP      test_fail
.ok_uk:
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_up
    LD      A, 0xDC
    LD      B, 4
    JP      test_fail
.ok_up:
    LD      HL, (undo_length)
    LD      DE, 10
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_ul
    LD      A, 0xDC
    LD      B, 5
    JP      test_fail
.ok_ul:
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      A, 0xDC
    LD      B, 6
    JP      test_fail
.ok_dirty:
    JP      test_pass

.payload:
    DEFB    "abc", 0x0A, "def", 0x0A, "ghi"
.expect_buf:
    DEFB    " abc", 0x0A, " def", 0x0A, "ghi"

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
