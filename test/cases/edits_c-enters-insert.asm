; ============================================================
; Module: test/cases/edits_c-enters-insert.asm
; Purpose: AC8 / AC12 canonical-3 — `cw` on "foo bar" (7 B),
;          cursor=0, pending_operator='c'. CALL motion_w. Exercises
;          op_compose_c's tail-JP to enter_insert_mode.
;
; Assert: buffer="bar" (3 B); cursor=0; mode_byte=MODE_INSERT;
;         yank_kind=KIND_CHAR; yank_length=4 ("foo "); buffer_dirty=1.
;
; Sentinel codes:
;   0x80 — cursor != 0
;   0x81 — buffer content mismatch
;   0x82 — mode_byte != MODE_INSERT
;   0x83 — yank_kind != KIND_CHAR
;   0x84 — yank_length != 4
;   0x85 — buffer_dirty != 1
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
    LD      A, 'c'
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
    LD      A, 0x81
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      A, (mode_byte)
    CP      MODE_INSERT
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_mode:

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

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x85
    JP      test_fail
.ok_dirty:

    JP      test_pass

.payload:
    DEFB    "foo bar"
.expected:
    DEFB    "bar"

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
