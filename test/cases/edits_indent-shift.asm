; ============================================================
; Module: test/cases/edits_indent-shift.asm
; Purpose: AC9 / AC12 canonical-5 — `>>` (doubled '>' form) on
;          "abc\ndef\nghi" (11 B), cursor=0, pending_operator='>'.
;          CALL parser_doubled_operator_stub. Exercises op_indent_line
;          → edits_indent_walk (indent mode).
;
; Assert: buffer=" abc\ndef\nghi" (12 B; leading space inserted on
;         line 1 only); buffer_dirty=1; cursor=0 (restored to entry);
;         yank UNCHANGED (indent doesn't touch yank).
;
; Sentinel codes:
;   0x80 — buffer mismatch
;   0x81 — buffer_dirty != 1
;   0x82 — cursor != 0
;   0x83 — yank_kind changed from pre-seed (0xEE)
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
    LD      A, '>'
    LD      (pending_operator), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    LD      A, 0xEE
    LD      (yank_kind), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 11
    LDIR
    LD      HL, GAP_BUFFER_BASE + 11
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    CALL    parser_doubled_operator_stub

    LD      HL, 0
    LD      DE, .expected
    LD      B, 12
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
    LD      A, 12
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

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, L
    LD      A, 0x82
    JP      test_fail
.ok_cursor:

    LD      A, (yank_kind)
    CP      0xEE
    JR      Z, .ok_yank
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_yank:

    JP      test_pass

.payload:
    DEFB    "abc", 0x0A, "def", 0x0A, "ghi"
.expected:
    DEFB    " abc", 0x0A, "def", 0x0A, "ghi"

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
