; ============================================================
; Module: test/cases/edits_p-after-dd.asm
; Purpose: AC10 canonical-2 — paste after `dd`. Pre-load `"def\n"`
;          (4 B; what's left after `dd` of line 1 from "abc\ndef\n"),
;          cursor=0. Pre-seed yank: KIND_LINE, len=4, "abc\n"
;          (the deleted line). CALL op_paste. Assert: buffer =
;          "def\nabc\n" (8 B — restored line lands BELOW current);
;          cursor=4 (start of pasted line); buffer_dirty=1;
;          parser cleared.
;
;          Pins: `dd p` is the canonical delete/restore loop —
;          deleted line is pasted below cursor, NOT at the
;          original position (vi-faithful).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x90 — cursor_offset != 4
;   0x91 — buffer content != "def\nabc\n" (B = mismatch index)
;   0x92 — buffer_dirty != 1
;   0x95 — parser state not cleared
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

    LD      A, KIND_LINE
    LD      (yank_kind), A
    LD      HL, 4
    LD      (yank_length), HL
    LD      HL, .yank_content
    LD      DE, yank_buffer
    LD      BC, 4
    LDIR

    CALL    op_paste

    LD      HL, (cursor_offset)
    LD      DE, 4
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x90
    JP      test_fail
.ok_cursor:

    LD      HL, 0
    LD      DE, .expected
    LD      B, 8
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
    LD      A, 8
    SUB     B
    LD      B, A
    LD      A, 0x91
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x92
    JP      test_fail
.ok_dirty:

    LD      A, (pending_operator)
    OR      A
    JR      NZ, .parser_fail
    LD      A, (pending_motion_prefix)
    OR      A
    JR      NZ, .parser_fail
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .parser_ok
.parser_fail:
    LD      A, 0x95
    JP      test_fail
.parser_ok:

    JP      test_pass

.payload:
    DEFB    "def", 0x0A
.yank_content:
    DEFB    "abc", 0x0A
.expected:
    DEFB    "def", 0x0A, "abc", 0x0A

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
