; ============================================================
; Module: test/cases/parser_doubled-operator-routes-to-yy.asm
; Purpose: AC1 dispatcher routing — drive the full parser chain
;          for `yy` end-to-end. Pre-load `"abc\n"` (4 B), cursor=0;
;          two 'y' presses through parser_handle_operator. Assert:
;          buffer UNCHANGED (yy is read-only); yank_kind=KIND_LINE;
;          yank_length=4 ("abc\n"); parser cleared.
;
; AC reference: AC1 (parser-side dispatcher); AC4 (op_yy handler).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — buffer modified (B = mismatch index)
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

    LD      A, 'y'
    CALL    parser_handle_operator
    LD      A, 'y'
    CALL    parser_handle_operator

    ;; Buffer unchanged.
    LD      HL, 0
    LD      DE, .payload
    LD      B, 4
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
    LD      A, 4
    SUB     B
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

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
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
