; ============================================================
; Module: test/cases/motions_100j-clamps-at-eof.asm
; Purpose: AC3 — `100j` clamps silently at the last line. Buffer
;          is 10 lines (no trailing LF, so the P5 phantom-past-LF
;          case is exercised separately by motions_j-past-trailing-lf).
;          Cursor at start of line 5 (offset 16), count=100;
;          motion_j walks 5 lines down (line 5→6→7→8→9→10) then
;          the next-line guard fires (no next line past line 10)
;          → cursor at offset 36 (start of line 10). Count cleared
;          via parser_clear.
;
;          Fixture: "L01\nL02\n...\nL10" (39 bytes). Line N starts
;          at offset 4*(N-1).
;
; AC reference: AC3 / AC12 canonical-3 (story 2.7 Sub 2.3).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 36 (start of line 10)
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
    LD      BC, 39
    LDIR
    LD      HL, GAP_BUFFER_BASE + 39
    LD      (gap_start), HL

    LD      HL, 16                      ; start of line 5
    LD      (cursor_offset), HL
    LD      HL, 100
    LD      (count_accumulator), HL

    LD      A, 'j'
    CALL    motion_j

    LD      HL, (cursor_offset)
    LD      DE, 36                      ; start of line 10
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
    DEFB    "L01", 0x0A, "L02", 0x0A, "L03", 0x0A, "L04", 0x0A
    DEFB    "L05", 0x0A, "L06", 0x0A, "L07", 0x0A, "L08", 0x0A
    DEFB    "L09", 0x0A, "L10"

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
