; ============================================================
; Module: test/cases/edits_d$-to-end-of-line.asm
; Purpose: AC4 / AC12 canonical-2 — `d$` on "abc def\nghi" (11 B),
;          cursor=2 (on 'c'), pending_operator='d'. CALL motion_dollar.
;          Exercises the pending_motion_inclusive flag (motion_dollar
;          sets it; op_compose_d's inclusive bump extends the range
;          by 1 byte) + the post-delete x-style clamp.
;
; Assert: buffer = "ab\nghi" (6 B); cursor=1 (clamped onto 'b' — last
;         printable byte of new line 1 since byte at 2 is now LF);
;         yank_kind=KIND_CHAR; yank_length=5 ("c def"); buffer_dirty=1;
;         pending_motion_inclusive cleared (parser_clear cleaned up).
;
; Sentinel codes:
;   0x80 — cursor != 1
;   0x81 — buffer content mismatch (B = mismatch index)
;   0x82 — buffer_dirty != 1
;   0x83 — yank_kind != KIND_CHAR
;   0x84 — yank_length != 5
;   0x85 — yank_buffer[i] mismatch
;   0x86 — pending_motion_inclusive not cleared
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
    LD      A, 'd'
    LD      (pending_operator), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 11
    LDIR
    LD      HL, GAP_BUFFER_BASE + 11
    LD      (gap_start), HL

    LD      HL, 2
    LD      (cursor_offset), HL

    CALL    motion_dollar

    LD      HL, (cursor_offset)
    LD      DE, 1
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
    LD      DE, .expected
    LD      B, 6
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
    LD      A, 6
    SUB     B
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      A, (buffer_dirty)
    CP      1
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
    LD      DE, 5
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
    LD      B, 5
.ycmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 5
    SUB     B
    LD      B, A
    LD      A, 0x85
    JP      test_fail
.ycmp_next:
    INC     HL
    INC     DE
    DJNZ    .ycmp

    LD      A, (pending_motion_inclusive)
    OR      A
    JR      Z, .ok_inclusive
    LD      B, A
    LD      A, 0x86
    JP      test_fail
.ok_inclusive:

    JP      test_pass

.payload:
    DEFB    "abc def", 0x0A, "ghi"
.expected:
    DEFB    "ab", 0x0A, "ghi"
.yank_expected:
    DEFB    "c def"

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
