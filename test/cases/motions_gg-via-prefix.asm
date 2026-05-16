; ============================================================
; Module: test/cases/motions_gg-via-prefix.asm
; Purpose: AC7 — motion_gg dispatched via parser_handle_motion_prefix's
;          doubled-g arm. Buffer "line1\nline2" (11 bytes);
;          cursor=8 (mid-line2). Drive parser end-to-end with two
;          'g' calls. Expect cursor=0; parser state cleared.
;          (Replaces the pre-Story-2.6 parser_motion-prefix-gg
;          subtest 2 "stub fired" assertion with a real motion_gg
;          observation.)
;
; Sentinel codes:
;   0x80 — cursor_offset != 0
;   0x81 — count_accumulator not cleared
;   0x82 — pending_motion_prefix not cleared
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
    LD      BC, 11
    LDIR
    LD      HL, GAP_BUFFER_BASE + 11
    LD      (gap_start), HL

    LD      HL, 8
    LD      (cursor_offset), HL

    ;; First 'g' sets prefix.
    LD      A, 'g'
    CALL    parser_handle_motion_prefix
    ;; Second 'g' dispatches motion_gg with no-count → cursor=0.
    LD      A, 'g'
    CALL    parser_handle_motion_prefix

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, L
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

    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok_prefix
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_prefix:

    JP      test_pass

.payload:
    DEFB    "line1", 0x0A, "line2"

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
