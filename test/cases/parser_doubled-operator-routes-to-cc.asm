; ============================================================
; Module: test/cases/parser_doubled-operator-routes-to-cc.asm
; Purpose: Pin the `cc` doubled-form out-of-MVP-scope semantic.
;          Drive parser_handle_operator('c') twice. Expect
;          parser_doubled_operator_stub's fall-through arm:
;          msg_not_implemented surfaced; buffer UNCHANGED;
;          parser cleared.
;
; Assert: buffer UNCHANGED; status_dirty=1; status_buffer prefix =
;         "not yet implemented" (matches msg_not_implemented).
;
; Sentinel codes:
;   0x80 — buffer modified
;   0x81 — status_dirty != 1
;   0x82 — status_buffer prefix mismatch
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
    LD      (pending_motion_inclusive), A
    LD      (buffer_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, 'c'
    CALL    parser_handle_operator
    LD      A, 'c'
    CALL    parser_handle_operator

    LD      HL, 0
    LD      DE, .payload
    LD      B, 3
.cmp_loop:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .cmp_next
    LD      A, 3
    SUB     B
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      A, (status_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_dirty:

    LD      HL, status_buffer
    LD      DE, .nyi_msg
    LD      B, 19
.scmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .scmp_next
    LD      A, 19
    SUB     B
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.scmp_next:
    INC     HL
    INC     DE
    DJNZ    .scmp

    JP      test_pass

.payload:
    DEFB    "foo"
.nyi_msg:
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
