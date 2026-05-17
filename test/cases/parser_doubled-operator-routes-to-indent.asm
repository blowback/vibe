; ============================================================
; Module: test/cases/parser_doubled-operator-routes-to-indent.asm
; Purpose: Drive the full parser chain: pre-load "abc", cursor=0,
;          mode=NORMAL. CALL parser_handle_operator('>') twice:
;          - First: stores pending_operator='>'.
;          - Second: detects doubled → JP parser_doubled_operator_stub
;            → CP '>' matches → JP op_indent_line.
;          Exercises AC10's parser_doubled_operator_stub extension.
;
; Assert: buffer=" abc" (4 B); buffer_dirty=1; parser cleared.
;
; Sentinel codes:
;   0x80 — buffer mismatch
;   0x81 — buffer_dirty != 1
;   0x82 — parser state not cleared (pending_operator non-zero)
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

    LD      A, '>'
    CALL    parser_handle_operator      ; first '>' — stores pending_operator
    LD      A, '>'
    CALL    parser_handle_operator      ; second '>' — doubled → op_indent_line

    LD      HL, 0
    LD      DE, .expected
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

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_dirty:

    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok_parser
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_parser:

    JP      test_pass

.payload:
    DEFB    "abc"
.expected:
    DEFB    " abc"

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
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
