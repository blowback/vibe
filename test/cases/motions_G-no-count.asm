; ============================================================
; Module: test/cases/motions_G-no-count.asm
; Purpose: AC6 — motion_G with no count lands at start of last
;          line. Buffer "line1\nline2\nline3" (17 bytes, no
;          trailing LF); cursor=0; count_accumulator=0.
;          Expect cursor=12 (start of "line3").
;
; Sentinel codes:
;   0x80 — cursor_offset != 12
;   0x81 — count_accumulator not cleared
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 17
    LDIR
    LD      HL, GAP_BUFFER_BASE + 17
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, 'G'
    CALL    motion_G

    LD      HL, (cursor_offset)
    LD      A, H
    OR      A
    JR      NZ, .fail_cursor
    LD      A, L
    CP      12
    JR      Z, .ok_cursor
.fail_cursor:
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_cursor:

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x81
    JP      test_fail
.ok_count:

    JP      test_pass

.payload:
    DEFB    "line1", 0x0A, "line2", 0x0A, "line3"

    INCLUDE "../inc/test_epilogue.inc"

    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
