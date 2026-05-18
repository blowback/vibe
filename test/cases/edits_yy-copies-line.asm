; ============================================================
; Module: test/cases/edits_yy-copies-line.asm
; Purpose: AC4 canonical — `yy` on `"abc\ndef"` (7 B), cursor=4
;          (on 'd', line 2; last line no trailing LF), CALL op_yy.
;          Assert: buffer UNCHANGED; cursor=4 (unchanged);
;          buffer_dirty=0 (unchanged); yank_kind=KIND_LINE;
;          yank_length=4 ("\ndef" — last-line-no-LF + S>0 case
;          per AC4's "SAME range that op_dd would delete"
;          contract; see AC12 footnote on the cross-line leading-
;          LF semantic); yank_buffer[0..3]="\ndef"; parser_clear
;          ran.
;
;          NOTE on yank_length=4: AC4 body says "the yank-target
;          range is the SAME range that `op_dd` would delete" —
;          so yy uses AC2's last-line-no-LF + S>0 adjustment
;          (range [S-1, file_length) = [3, 7), 4 bytes). The epic
;          test description trace ("range [4, 7), 3 B") at line
;          1335 was internally inconsistent with AC4's "same
;          range" contract; this test follows the load-bearing AC
;          body (and AC12's documented "yank holds the deleted
;          bytes verbatim, including the cross-line LF" semantic).
;
; AC reference: AC4 (single-line case; same range as op_dd);
;          AC10 (KIND_LINE write); AC12 canonical-2 (epic spec
;          line 1335 — yank_length corrected to 4 per AC4 body).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 4 post-yy
;   0x81 — buffer content changed (B = mismatch index)
;   0x82 — buffer_dirty was modified (must stay 0)
;   0x83 — yank_kind != KIND_LINE
;   0x84 — yank_length != 4
;   0x85 — yank_buffer[i] mismatch (B = index)
;   0x86 — parser state not fully cleared
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

    ;; Pre-load "abc\ndef" (7 B).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 7
    LDIR
    LD      HL, GAP_BUFFER_BASE + 7
    LD      (gap_start), HL

    LD      HL, 4
    LD      (cursor_offset), HL

    CALL    op_yy

    ;; Cursor unchanged at 4.
    LD      HL, (cursor_offset)
    LD      DE, 4
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

    ;; Buffer unchanged.
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
    CP      KIND_LINE
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
    LD      A, 0x86
    JP      test_fail
.parser_ok:

    JP      test_pass

.payload:
    DEFB    "abc", 0x0A, "def"
.yank_expected:
    DEFB    0x0A, "def"

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
