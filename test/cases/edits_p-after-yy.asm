; ============================================================
; Module: test/cases/edits_p-after-yy.asm
; Purpose: AC10 canonical-1 (epic spec line 1430) — paste after
;          a line-yank. Pre-load `"abc\ndef\n"` (8 B), cursor=0
;          (on 'a', line 1). Pre-seed yank: KIND_LINE, len=4,
;          content="abc\n" (simulates prior `yy` of line 1).
;          CALL op_paste. Assert: buffer="abc\nabc\ndef\n"
;          (12 B — line 1 duplicated below); cursor=4 (start of
;          inserted line — duplicated "abc\n"); buffer_dirty=1;
;          yank register UNCHANGED (paste is read-only on yank);
;          parser cleared.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x90 — cursor_offset != 4 post-paste
;   0x91 — buffer content != "abc\nabc\ndef\n" (B = mismatch index)
;   0x92 — buffer_dirty != 1
;   0x93 — yank_kind changed (must stay KIND_LINE)
;   0x94 — yank_length changed (must stay 4)
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

    ;; Pre-load buffer "abc\ndef\n" (8 B).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 8
    LDIR
    LD      HL, GAP_BUFFER_BASE + 8
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    ;; Pre-seed yank: KIND_LINE, len=4, "abc\n".
    LD      A, KIND_LINE
    LD      (yank_kind), A
    LD      HL, 4
    LD      (yank_length), HL
    LD      HL, .yank_content
    LD      DE, yank_buffer
    LD      BC, 4
    LDIR

    CALL    op_paste

    ;; Cursor must land at 4 (start of inserted duplicate line).
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

    ;; Buffer content = "abc\nabc\ndef\n" (12 B).
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

    LD      A, (yank_kind)
    CP      KIND_LINE
    JR      Z, .ok_kind
    LD      B, A
    LD      A, 0x93
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
    LD      A, 0x94
    JP      test_fail
.ok_length:

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
    DEFB    "abc", 0x0A, "def", 0x0A
.yank_content:
    DEFB    "abc", 0x0A
.expected:
    DEFB    "abc", 0x0A, "abc", 0x0A, "def", 0x0A

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
