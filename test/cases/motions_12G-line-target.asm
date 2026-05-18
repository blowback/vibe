; ============================================================
; Module: test/cases/motions_12G-line-target.asm
; Purpose: AC5 — `12G` jumps to start of line 12. 20-line buffer
;          ("line01\n...\nline20", no trailing LF) = 139 bytes;
;          each "lineNN" = 6 chars + 1 LF = 7 bytes per slot
;          (line 20 has no trailing LF). Line N starts at offset
;          7*(N-1). Cursor pre-set to offset 0; count=12;
;          motion_G should land cursor at 7*11 = 77 (start of
;          line 12). Count cleared via parser_clear tail-JP.
;
; AC reference: AC5 with-count (story 2.7 Sub 3.1).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 77 (start of line 12)
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
    LD      BC, 139
    LDIR
    LD      HL, GAP_BUFFER_BASE + 139
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL
    LD      HL, 12
    LD      (count_accumulator), HL

    LD      A, 'G'
    CALL    motion_G

    LD      HL, (cursor_offset)
    LD      DE, 77                      ; start of line 12
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
    DEFB    "line01", 0x0A, "line02", 0x0A, "line03", 0x0A, "line04", 0x0A
    DEFB    "line05", 0x0A, "line06", 0x0A, "line07", 0x0A, "line08", 0x0A
    DEFB    "line09", 0x0A, "line10", 0x0A, "line11", 0x0A, "line12", 0x0A
    DEFB    "line13", 0x0A, "line14", 0x0A, "line15", 0x0A, "line16", 0x0A
    DEFB    "line17", 0x0A, "line18", 0x0A, "line19", 0x0A, "line20"

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
