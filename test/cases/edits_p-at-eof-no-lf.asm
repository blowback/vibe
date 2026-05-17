; ============================================================
; Module: test/cases/edits_p-at-eof-no-lf.asm
; Purpose: AC10 additional — KIND_CHAR paste with cursor on last
;          printable byte of a no-trailing-LF buffer. Pre-load
;          `"abc"` (3 B, no LF), cursor=2 (on 'c'). Pre-seed yank:
;          KIND_CHAR, len=2, content="XY". CALL op_paste. Trace:
;          pre-paste motion_byte_at_logical(2)='c' (CF=0, not LF) →
;          advance cursor 2 → 3; insert "XY" at cursor=3 → cursor=5
;          post-insert; DEC cursor → 4. Assert: buffer="abcXY"
;          (5 B); cursor=4 (on 'Y' — last inserted byte); buffer_dirty=1.
;
;          Pins: AC4 cursor-advance branch when cursor is on a
;          printable byte; cursor advances past EOF into the
;          freshly-inserted-content region.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x90 — cursor_offset != 4
;   0x91 — buffer content != "abcXY" (B = mismatch index)
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
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 2
    LD      (cursor_offset), HL

    LD      A, KIND_CHAR
    LD      (yank_kind), A
    LD      HL, 2
    LD      (yank_length), HL
    LD      HL, .yank_content
    LD      DE, yank_buffer
    LD      BC, 2
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
    LD      B, 5
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
    LD      A, 5
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
    DEFB    "abc"
.yank_content:
    DEFB    "XY"
.expected:
    DEFB    "abcXY"

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
