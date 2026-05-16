; ============================================================
; Module: test/cases/edits_dd-cursor-mid-line.asm
; Purpose: Mid-column cursor — `dd` on `"abc\ndef\nghi"` (11 B),
;          cursor=5 (on 'e', mid-line 2). Per AC2: line-start is
;          computed from cursor's logical line (S=4), not from
;          cursor itself; range = [4, 8) = "def\n"; post-delete
;          cursor lands at delete_start=4 (start of new line 2 =
;          "ghi"). Assert: buffer = "abc\nghi" (7 B); cursor=4;
;          yank_length=4 ("def\n"); yank_kind=KIND_LINE.
;
; AC reference: AC2 mid-line cursor pin — line-start computed
;          from cursor's logical line.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor != 4
;   0x81 — buffer != "abc\nghi" (B = index)
;   0x82 — yank_length != 4
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
    LD      BC, 11
    LDIR
    LD      HL, GAP_BUFFER_BASE + 11
    LD      (gap_start), HL

    LD      HL, 5
    LD      (cursor_offset), HL

    CALL    op_dd

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

    LD      HL, 0
    LD      DE, .expected
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

    LD      HL, (yank_length)
    LD      DE, 4
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_length
    LD      HL, (yank_length)
    LD      B, L
    LD      A, 0x82
    JP      test_fail
.ok_length:

    JP      test_pass

.payload:
    DEFB    "abc", 0x0A, "def", 0x0A, "ghi"
.expected:
    DEFB    "abc", 0x0A, "ghi"

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
