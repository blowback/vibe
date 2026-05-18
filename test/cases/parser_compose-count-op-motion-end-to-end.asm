; ============================================================
; Module: test/cases/parser_compose-count-op-motion-end-to-end.asm
; Purpose: AC12 canonical-6 — drive the full keystroke sequence
;          `2dw` on "foo bar baz" (11 B), cursor=0.
;          Sequence:
;            parser_handle_digit('2')  → count = 2
;            parser_handle_operator('d') → pending_operator = 'd'
;            motion_w                   → motion_w's prologue +
;                                          compose tail → op_compose_d
;
; Assert: buffer="baz" (3 B); cursor=0; yank_kind=KIND_CHAR;
;         yank_length=8 ("foo bar "); buffer_dirty=1; parser cleared.
;
; Sentinel codes:
;   0x80 — buffer mismatch
;   0x81 — cursor != 0
;   0x82 — yank_kind != KIND_CHAR
;   0x83 — yank_length != 8
;   0x84 — yank_buffer mismatch
;   0x85 — buffer_dirty != 1
;   0x86 — parser state not cleared (count_accumulator non-zero)
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
    LD      BC, 11
    LDIR
    LD      HL, GAP_BUFFER_BASE + 11
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    ;; Drive the parser chain.
    LD      A, '2'
    CALL    parser_handle_digit
    LD      A, 'd'
    CALL    parser_handle_operator
    CALL    motion_w

    LD      HL, 0
    LD      DE, .expected
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

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, L
    LD      A, 0x81
    JP      test_fail
.ok_cursor:

    LD      A, (yank_kind)
    CP      KIND_CHAR
    JR      Z, .ok_kind
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_kind:

    LD      HL, (yank_length)
    LD      DE, 8
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_length
    LD      HL, (yank_length)
    LD      B, L
    LD      A, 0x83
    JP      test_fail
.ok_length:

    LD      HL, yank_buffer
    LD      DE, .yank_expected
    LD      B, 8
.ycmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 8
    SUB     B
    LD      B, A
    LD      A, 0x84
    JP      test_fail
.ycmp_next:
    INC     HL
    INC     DE
    DJNZ    .ycmp

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x85
    JP      test_fail
.ok_dirty:

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_parser
    LD      B, L
    LD      A, 0x86
    JP      test_fail
.ok_parser:

    JP      test_pass

.payload:
    DEFB    "foo bar baz"
.expected:
    DEFB    "baz"
.yank_expected:
    DEFB    "foo bar "

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
