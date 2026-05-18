; ============================================================
; Module: test/cases/visual_backward-extends.asm
; Purpose: Story 3.3 AC6 / AC7 / AC10 — verify the abs-value
;          branch of visual_extend's count math. Buffer "abcdef".
;          Pre-seed mode_byte = MODE_VISUAL, visual_submode =
;          VIS_CHAR, visual_anchor = 4 (fixed), cursor_offset = 4.
;          CALL motion_h to decrement cursor; visual_extend
;          recomputes count = |3 - 4| + 1 = 2, status =
;          "-- visual -- 2". CALL motion_h again; count = |2-4|+1 =
;          3, status = "-- visual -- 3".
;
; Sentinel 0xB3 — context byte:
;   0 — after 1st motion_h: cursor_offset != 3
;   1 — after 1st motion_h: status_buffer mismatch ("-- visual -- 2")
;   2 — after 2nd motion_h: cursor_offset != 2
;   3 — after 2nd motion_h: status_buffer mismatch ("-- visual -- 3")
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

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 6
    LDIR
    LD      HL, GAP_BUFFER_BASE + 6
    LD      (gap_start), HL

    ;; Pre-seed VISUAL with cursor=4, anchor=4.
    LD      HL, 4
    LD      (cursor_offset), HL
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A

    ;; --- 1st motion_h ---
    LD      A, 'h'
    CALL    motion_h

    LD      HL, (cursor_offset)
    LD      DE, 3
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c1
    LD      A, 0xB3
    LD      B, 0
    JP      test_fail
.ok_c1:
    LD      HL, status_buffer
    LD      DE, .status_2
    CALL    .cmp_14
    JR      Z, .ok_s1
    LD      A, 0xB3
    LD      B, 1
    JP      test_fail
.ok_s1:

    ;; --- 2nd motion_h ---
    LD      A, 'h'
    CALL    motion_h

    LD      HL, (cursor_offset)
    LD      DE, 2
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c2
    LD      A, 0xB3
    LD      B, 2
    JP      test_fail
.ok_c2:
    LD      HL, status_buffer
    LD      DE, .status_3
    CALL    .cmp_14
    JR      Z, .ok_s2
    LD      A, 0xB3
    LD      B, 3
    JP      test_fail
.ok_s2:

    JP      test_pass

.cmp_14:
    LD      B, 14
.cmp_loop:
    LD      A, (DE)
    CP      (HL)
    RET     NZ
    INC     HL
    INC     DE
    DJNZ    .cmp_loop
    XOR     A
    RET

.payload:
    DEFB    "abcdef"
.status_2:
    DEFB    "-- visual -- 2"
.status_3:
    DEFB    "-- visual -- 3"

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
