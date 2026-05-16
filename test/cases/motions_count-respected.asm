; ============================================================
; Module: test/cases/motions_count-respected.asm
; Purpose: AC11 / AC6 — verify count_accumulator drives multi-
;          step move and is cleared by the post-motion
;          parser_clear tail-JP.
;
;          Gap: "abcde" (5 bytes); cursor at 4; count = 3.
;          CALL motion_h. Expected: cursor at 1; count cleared.
;
; AC reference: AC11 (Story 2.5 Sub 7.13); AC6 mechanism.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 1
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
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 5
    LDIR
    LD      HL, GAP_BUFFER_BASE + 5
    LD      (gap_start), HL

    LD      HL, 4
    LD      (cursor_offset), HL

    ;; Pre-set count_accumulator = 3 (test pre-loads — Story 2.7
    ;; will drive the digit -> parser_handle_digit chain end-to-end).
    LD      HL, 3
    LD      (count_accumulator), HL

    LD      A, 'h'
    CALL    motion_h

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

.payload:
    DEFB    "abcde"

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
