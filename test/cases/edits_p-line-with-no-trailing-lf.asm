; ============================================================
; Module: test/cases/edits_p-line-with-no-trailing-lf.asm
; Purpose: AC10 additional — KIND_LINE paste with cursor on a
;          last-line-no-LF buffer (past-EOF LF-insert path).
;          Pre-load `"abc"` (3 B, no LF), cursor=1 (on 'b').
;          Pre-seed yank: KIND_LINE, len=4, content="xyz\n".
;          CALL op_paste. Trace: KIND_LINE branch; entry_cursor=1;
;          motion_find_line_end(1) walks to no-LF → returns
;          HL=file_length=3, CF=1; LD (cursor),HL → cursor=3;
;          motion_byte_at_logical(3) → past EOF, CF=1 →
;          .pl_past_eof. Insert explicit LF at cursor=3 → cursor=4.
;          motion_apply_count → BC=1. Count loop iter 1: insert
;          "xyz\n" at cursor=4 → cursor=8. POP entry_cursor=1;
;          motion_find_line_end(1) walks to LF (now at 3, the
;          explicit-LF we inserted); HL=3; INC → 4; cursor=4.
;
;          Assert: buffer="abc\nxyz\n" (8 B — current line
;          terminated with LF, then yank content as new line below);
;          cursor=4 (start of inserted "xyz" line); buffer_dirty=1.
;
;          Pins: AC5 past-EOF LF-insert path (Q4 Option A —
;          always-insert-LF).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x90 — cursor_offset != 4
;   0x91 — buffer content != "abc\nxyz\n" (B = mismatch index)
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

    LD      HL, 1
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
    DEFB    "abc"
.yank_content:
    DEFB    "xyz", 0x0A
.expected:
    DEFB    "abc", 0x0A, "xyz", 0x0A

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
