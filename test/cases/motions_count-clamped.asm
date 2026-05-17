; ============================================================
; Module: test/cases/motions_count-clamped.asm
; Purpose: AC11 — verify a count larger than available steps
;          clamps silently (BH2: counted-motion bounds with no
;          status banner).
;
;          Gap: "abc" (3 bytes); cursor at 1; count = 100.
;          CALL motion_h. Expected: cursor at 0 (clamped from
;          attempted 100 steps); count cleared.
;
; AC reference: AC11 (Story 2.5 Sub 7.14).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 0
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
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    CALL    gapbuf_init
    LD      HL, GAP_BUFFER_BASE
    LD      (HL), 'a'
    INC     HL
    LD      (HL), 'b'
    INC     HL
    LD      (HL), 'c'
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 1
    LD      (cursor_offset), HL

    LD      HL, 100
    LD      (count_accumulator), HL

    LD      A, 'h'
    CALL    motion_h

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
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
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
