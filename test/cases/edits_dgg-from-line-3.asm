; ============================================================
; Module: test/cases/edits_dgg-from-line-3.asm
; Purpose: `dgg` on "a\nb\nc" (5 B), cursor=4 (on 'c', line 3),
;          pending_operator='d', count=0 (no count → gg = line 1).
;          CALL motion_gg. Exercises:
;            - motion_gg's compose prologue writes motions_compose_entry.
;            - backward motion → swap in edits_compose_range.
;            - line-class motion treated as CHAR-class per epic AC5.
;
; motion_gg lands cursor at offset 0. motions_compose_entry=4.
; Backward → swap. Range [0, 4) = "a\nb\n".
;
; Assert: buffer="c" (1 B); cursor=0; yank_kind=KIND_CHAR;
;         yank_length=4 ("a\nb\n"); buffer_dirty=1.
;
; Sentinel codes:
;   0x80 — cursor != 0
;   0x81 — buffer mismatch
;   0x82 — buffer_dirty != 1
;   0x83 — yank_kind != KIND_CHAR
;   0x84 — yank_length != 4
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
    LD      A, 'd'
    LD      (pending_operator), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 5
    LDIR
    LD      HL, GAP_BUFFER_BASE + 5
    LD      (gap_start), HL

    LD      HL, 4
    LD      (cursor_offset), HL

    CALL    motion_gg

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_cursor:

    LD      HL, 0
    CALL    motion_byte_at_logical
    CP      'c'
    JR      Z, .ok_buf
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_buf:

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
    LD      DE, 4
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
    LD      B, 4
.ycmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 4
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
    DEFB    "a", 0x0A, "b", 0x0A, "c"
.yank_expected:
    DEFB    "a", 0x0A, "b", 0x0A

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
