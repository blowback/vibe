; ============================================================
; Module: test/cases/edits_yw-cursor-unchanged.asm
; Purpose: `yw` on "foo bar" (7 B), cursor=2 ('o'),
;          pending_operator='y'. CALL motion_w. Exercises
;          op_compose_y's cursor restore: motion_w moves cursor
;          from 2 to 4, but op_compose_y restores it to 2.
;
; Assert: buffer UNCHANGED; cursor=2 (RESTORED — even though motion_w
;         moved it to 4); yank_kind=KIND_CHAR; yank_length=2 ("o ");
;         buffer_dirty UNCHANGED.
;
; Sentinel codes:
;   0x80 — cursor != 2 (not restored)
;   0x81 — buffer modified
;   0x82 — buffer_dirty changed
;   0x83 — yank_kind != KIND_CHAR
;   0x84 — yank_length != 2
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
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      A, 'y'
    LD      (pending_operator), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 7
    LDIR
    LD      HL, GAP_BUFFER_BASE + 7
    LD      (gap_start), HL

    LD      HL, 2
    LD      (cursor_offset), HL

    CALL    motion_w

    LD      HL, (cursor_offset)
    LD      DE, 2
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_cursor:

    LD      HL, 0
    LD      DE, .payload
    LD      B, 7
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
    LD      A, 7
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
    LD      DE, 2
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
    LD      B, 2
.ycmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 2
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
    DEFB    "foo bar"
.yank_expected:
    DEFB    "o "

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
