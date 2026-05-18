; ============================================================
; Module: test/cases/edits_dd-cursor-on-middle-line.asm
; Purpose: AC2 middle-line case — `dd` on `"a\nb\nc"` (5 B),
;          cursor=2 (on 'b', line 2). CALL op_dd. Standard case:
;          range = [2, 4) = "b\n". Assert: buffer = "a\nc" (3 B);
;          cursor=2 (start of new line 2 = "c"); buffer_dirty=1;
;          yank_kind=KIND_LINE; yank_length=2 ("b\n").
;
; AC reference: AC2 standard case (E < file_length; line has
;          trailing LF).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor != 2
;   0x81 — buffer != "a\nc" (B = index)
;   0x82 — buffer_dirty != 1
;   0x83 — yank_length != 2
;   0x84 — yank_buffer mismatch (B = index)
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
    LD      BC, 5
    LDIR
    LD      HL, GAP_BUFFER_BASE + 5
    LD      (gap_start), HL

    LD      HL, 2
    LD      (cursor_offset), HL

    CALL    op_dd

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

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_dirty:

    LD      HL, (yank_length)
    LD      DE, 2
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
    LD      B, 2
.ycmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 2
    SUB     B
    LD      B, A
    LD      A, 0x84
    JP      test_fail
.ycmp_next:
    INC     HL
    INC     DE
    DJNZ    .ycmp

    JP      test_pass

.payload:
    DEFB    "a", 0x0A, "b", 0x0A, "c"
.expected:
    DEFB    "a", 0x0A, "c"
.yank_expected:
    DEFB    "b", 0x0A

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
