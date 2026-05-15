; ============================================================
; Module: test/cases/motions_l-clamps-at-eol.asm
; Purpose: AC11 — verify motion_l at the last printable byte of
;          a non-final line does NOT cross the trailing 0x0A.
;
;          Gap: "ab\nde" (5 bytes); cursor at 1 (the 'b' — last
;          printable on line 0). Expected: cursor stays at 1.
;
; AC reference: AC11 (Story 2.5 Sub 7.5).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 1 (l crossed the newline — bug)
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
    LD      HL, GAP_BUFFER_BASE
    LD      (HL), 'a'
    INC     HL
    LD      (HL), 'b'
    INC     HL
    LD      (HL), 0x0A
    INC     HL
    LD      (HL), 'd'
    INC     HL
    LD      (HL), 'e'
    LD      HL, GAP_BUFFER_BASE + 5
    LD      (gap_start), HL

    LD      HL, 1
    LD      (cursor_offset), HL

    LD      A, 'l'
    CALL    motion_l

    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor
    LD      A, (cursor_offset)
    LD      B, A
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

    INCLUDE "../inc/test_epilogue.inc"

    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
