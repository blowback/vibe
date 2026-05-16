; ============================================================
; Module: test/cases/motions_dollar-on-empty-line.asm
; Purpose: AC5 — motion_dollar on an empty line is a no-op
;          (eol == cursor on entry). Buffer "a\n\nb" (4 bytes);
;          cursor=2 (the LF of the empty middle line).
;          Expect cursor=2 (no move).
;
; Sentinel codes:
;   0x80 — cursor_offset != 2
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
    LD      BC, 4
    LDIR
    LD      HL, GAP_BUFFER_BASE + 4
    LD      (gap_start), HL

    LD      HL, 2
    LD      (cursor_offset), HL

    LD      A, '$'
    CALL    motion_dollar

    LD      HL, (cursor_offset)
    LD      A, H
    OR      A
    JR      NZ, .fail_cursor
    LD      A, L
    CP      2
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
    DEFB    "a", 0x0A, 0x0A, "b"

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
