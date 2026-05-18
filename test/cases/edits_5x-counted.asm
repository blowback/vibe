; ============================================================
; Module: test/cases/edits_5x-counted.asm
; Purpose: AC4 canonical — counted `5x` deletes 5 bytes via the
;          parser_dispatch shape used by the real dispatch path
;          for counted operations. Pre-load "abcdef" (6 B),
;          cursor=0; pre-set count_accumulator=5. CALL
;          parser_dispatch with HL=edits_delete_char. Assert
;          cursor=0, buffer="f" (1 B), buffer_dirty=1,
;          count_accumulator=0 (parser_clear ran).
;
;          Distinguishability check: with count=1 the buffer would
;          be "bcdef" (5 B); with count=5 it's "f" (1 B) — clearly
;          distinct (Story 2.7 P1 lesson on by-1 vs by-N
;          fixtures).
;
; AC reference: AC4 (counted form); AC11 canonical-3 (epics
;          line 1289).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 0
;   0x81 — buffer content != "f" (single byte)
;   0x82 — buffer_dirty != 1
;   0x83 — count_accumulator != 0 (parser_clear missed)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (status_dirty), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (buffer_dirty), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 6
    LDIR
    LD      HL, GAP_BUFFER_BASE + 6
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      HL, 5
    LD      (count_accumulator), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; parser_dispatch is the real production path for counted ops.
    LD      HL, edits_delete_char
    CALL    parser_dispatch

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_cursor:

    ;; Buffer must be "f" (1 byte) — file_length = 1.
    LD      HL, 0
    CALL    motion_byte_at_logical
    CP      'f'
    JR      Z, .ok_byte0
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_byte0:
    ;; Byte at offset 1 must be past EOF (CF=1).
    LD      HL, 1
    CALL    motion_byte_at_logical
    JR      C, .ok_eof
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_eof:

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_dirty:

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x83
    JP      test_fail
.ok_count:

    JP      test_pass

.payload:
    DEFB    "abcdef"

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
