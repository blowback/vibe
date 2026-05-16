; ============================================================
; Module: test/cases/edits_dd-clears-parser-state.asm
; Purpose: Pin op_dd's tail-JP parser_clear hygiene. Pre-seed
;          count_accumulator=5, pending_operator='d',
;          pending_motion_prefix='g' (these would never co-exist
;          in practice but the test verifies that parser_clear
;          zeroes all three fields atomically). Pre-load "abc\n"
;          (4 B), cursor=0. CALL op_dd. Assert: all three parser-
;          state fields zeroed post-call.
;
;          Direct CALL (not via parser_dispatch) — pins op_dd's
;          OWN tail-JP parser_clear independent of parser_dispatch's
;          tail-JP (Story 2.9 code-review patch P3b pattern).
;
; AC reference: AC1 (state-read-before-clear discipline) + AC2
;          (parser state zeroed via tail-JP parser_clear).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — pending_operator != 0 post-dd
;   0x81 — pending_motion_prefix != 0 post-dd
;   0x82 — count_accumulator != 0 post-dd
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
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; Pre-seed parser-state fields to non-zero distinctive values.
    LD      A, 'd'
    LD      (pending_operator), A
    LD      A, 'g'
    LD      (pending_motion_prefix), A
    LD      HL, 5
    LD      (count_accumulator), HL

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 4
    LDIR
    LD      HL, GAP_BUFFER_BASE + 4
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    CALL    op_dd

    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok_op
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.ok_op:

    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok_prefix
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_prefix:

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x82
    JP      test_fail
.ok_count:

    JP      test_pass

.payload:
    DEFB    "abc", 0x0A

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
