; ============================================================
; Module: test/cases/motions_k-shorter-prev-line.asm
; Purpose: AC11 — verify motion_k clamps the column when the
;          previous line is shorter. Symmetric with
;          motions_j-shorter-next-line.
;
;          Gap: "hi\nhello" (8 bytes); cursor at 7 ('o' on line
;          1, col 4). Expected: cursor at 1 (the 'i' on line 0 —
;          last char of the 2-byte line, clamped from col 4).
;
; AC reference: AC11 (Story 2.5 Sub 7.12).
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
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 8
    LDIR
    LD      HL, GAP_BUFFER_BASE + 8
    LD      (gap_start), HL

    LD      HL, 7
    LD      (cursor_offset), HL

    LD      A, 'k'
    CALL    motion_k

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
    DEFB    "hi", 0x0A, "hello"

    INCLUDE "../inc/test_epilogue.inc"

    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
