; ============================================================
; Module: test/cases/edits_y3w-yanks-without-modifying.asm
; Purpose: AC6 / AC12 canonical-4 — `y3w` on "a b c d e f" (11 B),
;          cursor=0, pending_operator='y', count_accumulator=3.
;          CALL motion_w. Exercises:
;          - counted compose (count=3 carries through motion_w into
;            op_compose_y).
;          - cursor restore: op_compose_y restores cursor to
;            motions_compose_entry even though motion_w moved it.
;          - read-only semantic: buffer + buffer_dirty UNCHANGED.
;
; Assert: buffer UNCHANGED ("a b c d e f", 11 B); cursor=0 (RESTORED);
;         yank_kind=KIND_CHAR; yank_length=6 ("a b c "); buffer_dirty=0.
;
; Sentinel codes:
;   0x80 — cursor != 0
;   0x81 — buffer modified (B = mismatch index)
;   0x82 — buffer_dirty changed
;   0x83 — yank_kind != KIND_CHAR
;   0x84 — yank_length != 6
;   0x85 — yank_buffer mismatch
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (status_dirty), A
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A
    LD      (buffer_dirty), A
    LD      A, 'y'
    LD      (pending_operator), A
    LD      HL, 3
    LD      (count_accumulator), HL
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

    CALL    motion_w

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_cursor:

    LD      HL, 0
    LD      DE, .payload
    LD      B, 11
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
    LD      A, 11
    SUB     B
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_dirty:

    LD      A, (yank_kind)
    CP      KIND_CHAR
    JR      Z, .ok_kind
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_kind:

    LD      HL, (yank_length)
    LD      DE, 6
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_length
    LD      HL, (yank_length)
    LD      B, L
    LD      A, 0x84
    JP      test_fail
.ok_length:

    LD      HL, yank_buffer
    LD      DE, .yank_expected
    LD      B, 6
.ycmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 6
    SUB     B
    LD      B, A
    LD      A, 0x85
    JP      test_fail
.ycmp_next:
    INC     HL
    INC     DE
    DJNZ    .ycmp

    JP      test_pass

.payload:
    DEFB    "a b c d e f"
.yank_expected:
    DEFB    "a b c "

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
