; ============================================================
; Module: test/cases/parser_doubled-operator-routes-to-dd.asm
; Purpose: AC1 dispatcher routing — drive the full parser chain
;          for `dd` end-to-end. Pre-load `"abc\n"` (4 B), cursor=0;
;          CALL parser_handle_operator A='d' (first 'd' — stores
;          pending_operator); CALL parser_handle_operator A='d'
;          (second 'd' — dispatcher routes to op_dd). Assert:
;          buffer empty post-call; yank_kind=KIND_LINE;
;          yank_length=4 ("abc\n"); parser state cleared.
;
;          Pins the AC1 wiring end-to-end: parser_handle_operator
;          → parser_doubled_operator_stub (real dispatcher) →
;          op_dd → parser_clear.
;
; AC reference: AC1 (parser-side dispatcher); AC2 (op_dd handler).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — buffer not empty (B = byte at offset 0)
;   0x81 — yank_kind != KIND_LINE
;   0x82 — yank_length != 4
;   0x83 — pending_operator != 0
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
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 4
    LDIR
    LD      HL, GAP_BUFFER_BASE + 4
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    ;; Drive the full chain: two 'd' presses through
    ;; parser_handle_operator.
    LD      A, 'd'
    CALL    parser_handle_operator
    LD      A, 'd'
    CALL    parser_handle_operator

    ;; Buffer must be empty.
    LD      HL, 0
    CALL    motion_byte_at_logical
    JR      C, .ok_empty
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.ok_empty:

    LD      A, (yank_kind)
    CP      KIND_LINE
    JR      Z, .ok_kind
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_kind:

    LD      HL, (yank_length)
    LD      DE, 4
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_length
    LD      HL, (yank_length)
    LD      B, L
    LD      A, 0x82
    JP      test_fail
.ok_length:

    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok_op
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_op:

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
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
