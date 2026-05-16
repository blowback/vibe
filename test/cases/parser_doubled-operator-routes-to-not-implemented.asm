; ============================================================
; Module: test/cases/parser_doubled-operator-routes-to-not-implemented.asm
; Purpose: AC1 dispatcher c/>/< fall-through arm — drive two 'c'
;          presses through parser_handle_operator. The new
;          dispatcher reads pending_operator='c'; neither 'd' nor
;          'y' matches; falls through to the msg_not_implemented
;          surface and tail-JPs parser_clear. Assert: status_buffer
;          contains "not yet implemented" prefix; status_dirty=1;
;          parser cleared.
;
;          One test for the c/>/< arm is sufficient (per AC12 note
;          "Same shape works for '>' and '<' if the dev wants belt-
;          and-braces coverage; one test for the c/>/< fall-through
;          arm is sufficient").
;
; AC reference: AC1 fall-through arm (msg_not_implemented surface
;          preserved from Story 1.10).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — status_dirty != 1
;   0x81 — status_buffer prefix wrong (B = mismatch index)
;   0x82 — pending_operator != 0 (parser_clear not run)
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

    LD      A, 'c'
    CALL    parser_handle_operator
    LD      A, 'c'
    CALL    parser_handle_operator

    LD      A, (status_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.ok_dirty:

    LD      HL, status_buffer
    LD      DE, .ni_msg
    LD      B, 19
.scmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .scmp_next
    LD      A, 19
    SUB     B
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.scmp_next:
    INC     HL
    INC     DE
    DJNZ    .scmp

    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok_op
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_op:

    JP      test_pass

.ni_msg:
    DEFB    "not yet implemented"

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
