; ============================================================
; Module: test/cases/edits_x-clears-parser-state.asm
; Purpose: AC3 / AC5 parser hygiene — every dispatched key clears
;          parser state regardless of whether the handler did
;          anything. Pre-seed count_accumulator=5,
;          pending_operator='d', pending_motion_prefix='g'.
;          Pre-load "abcdef", cursor=0. Drive via DIRECT
;          `CALL edits_delete_char` (NOT parser_dispatch) so the
;          handler's OWN tail-JP parser_clear is the only mechanism
;          that could zero parser state — pins the handler's tail
;          contract independent of parser_dispatch's own tail-JP
;          (parser_dispatch at src/parser.asm:428-430 independently
;          tail-JPs parser_clear; without this direct-call test, a
;          regression replacing the handler's `JP parser_clear`
;          with `RET` would still pass via parser_dispatch's clear).
;          Assert all three parser-state fields = 0.
;
; AC reference: AC3 / AC5 hygiene; pins edits_delete_char's own
;          tail-JP parser_clear (the success-path tail after
;          CALL edits_dirty_and_redraw).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — count_accumulator != 0
;   0x81 — pending_operator != 0
;   0x82 — pending_motion_prefix != 0
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (status_dirty), A
    LD      (buffer_dirty), A

    ;; Pre-seed parser state to NONZERO (Story 2.6 lesson).
    LD      HL, 5
    LD      (count_accumulator), HL
    LD      A, 'd'
    LD      (pending_operator), A
    LD      A, 'g'
    LD      (pending_motion_prefix), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 6
    LDIR
    LD      HL, GAP_BUFFER_BASE + 6
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    edits_delete_char

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_count:

    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok_op
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_op:

    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok_prefix
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_prefix:

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
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
