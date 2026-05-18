; ============================================================
; Module: test/cases/edits_p-counted-line.asm
; Purpose: AC10 additional — counted KIND_LINE paste. Pre-load
;          `"a\n"` (2 B), cursor=0. Pre-seed yank: KIND_LINE,
;          len=2, content="b\n". Pre-seed count_accumulator=2.
;          CALL op_paste. Trace: KIND_LINE; entry_cursor=0;
;          motion_find_line_end(0) → LF at 1; LD (cursor),HL=1;
;          motion_byte_at_logical(1)=0x0A (CF=0); INC → 2; cursor=2.
;          motion_apply_count → BC=2. Iter 1: insert "b\n" at 2 →
;          cursor=4. Iter 2: insert "b\n" at 4 → cursor=6. POP
;          entry_cursor=0; motion_find_line_end(0) walks to LF at
;          1 (the original LF); HL=1; INC → 2; cursor=2.
;
;          Assert: buffer="a\nb\nb\n" (6 B — 2 copies of "b\n"
;          below "a\n"); cursor=2 (start of FIRST inserted "b\n"
;          line — vi-faithful for `2p` of a line-yank);
;          buffer_dirty=1; count_accumulator=0 post-call; parser cleared.
;
;          Pins: AC7 counted line paste; cursor placement at start
;          of FIRST inserted line, not last.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x90 — cursor_offset != 2
;   0x91 — buffer content != "a\nb\nb\n" (B = mismatch index)
;   0x92 — buffer_dirty != 1
;   0x95 — parser state not cleared (count_accumulator or pending)
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
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 2
    LDIR
    LD      HL, GAP_BUFFER_BASE + 2
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, KIND_LINE
    LD      (yank_kind), A
    LD      HL, 2
    LD      (yank_length), HL
    LD      HL, .yank_content
    LD      DE, yank_buffer
    LD      BC, 2
    LDIR

    LD      HL, 2
    LD      (count_accumulator), HL

    CALL    op_paste

    LD      HL, (cursor_offset)
    LD      DE, 2
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
    LD      B, 6
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
    LD      A, 6
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
    DEFB    "a", 0x0A
.yank_content:
    DEFB    "b", 0x0A
.expected:
    DEFB    "a", 0x0A, "b", 0x0A, "b", 0x0A

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
