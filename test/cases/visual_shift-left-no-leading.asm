; ============================================================
; Module: test/cases/visual_shift-left-no-leading.asm
; Purpose: Story 3.7 AC4 / AC5 — `<` on a line whose first byte
;          is NOT INDENT_BYTE: per-line silent no-op via
;          edits_indent_walk's .iw_dedent CP INDENT_BYTE skip
;          guard. visual_apply_shift sees dirty=0 → skips record
;          and dirty_and_redraw; undo stays EMPTY from pre-walk
;          undo_clear (Q3 Option A).
;
;          Buffer "abc\ndef" (7 B; LF at 3). Pre-seed VIS_LINE,
;          anchor=0, cursor=0 (single-line selection of line 1).
;          CALL with A='<'.
;
;          Expected:
;            mode_byte    = MODE_NORMAL
;            cursor_offset = 0
;            buffer       UNCHANGED (7 B "abc\ndef")
;            undo_kind    = UNDO_KIND_EMPTY (no-op walk; undo_clear
;                           pre-walk left it EMPTY)
;            buffer_dirty UNCHANGED from pre-seed (0)
;
; Sentinel 0xD9 — context byte:
;   0 — mode_byte != MODE_NORMAL
;   1 — cursor_offset != 0
;   2 — buffer first 7 B != "abc\ndef"
;   3 — undo_kind != UNDO_KIND_EMPTY
;   4 — buffer_dirty != 0
;   5 — gap_start moved (regression: gap pointer drifted on no-op walk)
;   6 — gap_end moved (regression: gap pointer drifted on no-op walk)
;   7 — undo_position != 0 (regression: no-op walk wrote to undo record)
;   8 — undo_length != 0 (regression: no-op walk wrote to undo record)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (status_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A
    LD      (yank_kind), A
    LD      (buffer_dirty), A
    LD      HL, 0
    LD      (undo_position), HL
    LD      (undo_length), HL

    ;; Pre-seed undo with a non-empty kind sentinel — we want to
    ;; verify visual_apply_shift's undo_clear pre-walk fires and
    ;; the no-op walk leaves it EMPTY (not the pre-seed value).
    LD      A, UNDO_KIND_DELETE
    LD      (undo_kind), A

    ;; Populate "abc\ndef" (7 B; LF at 3).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 7
    LDIR
    LD      HL, GAP_BUFFER_BASE + 7
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_LINE
    LD      (visual_submode), A

    ;; --- Execute: visual_apply_shift with A='<' ---
    LD      A, '<'
    CALL    visual_apply_shift

    ;; --- Assertions ---
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xD9
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0xD9
    LD      B, 1
    JP      test_fail
.ok_cursor:
    LD      HL, 0
    LD      DE, .payload
    LD      B, 7
.buf_loop:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .buf_next
    LD      A, 0xD9
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (undo_kind)
    CP      UNDO_KIND_EMPTY
    JR      Z, .ok_uk
    LD      A, 0xD9
    LD      B, 3
    JP      test_fail
.ok_uk:
    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      A, 0xD9
    LD      B, 4
    JP      test_fail
.ok_dirty:
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE + 7
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_gap_start
    LD      A, 0xD9
    LD      B, 5
    JP      test_fail
.ok_gap_start:
    LD      HL, (gap_end)
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_gap_end
    LD      A, 0xD9
    LD      B, 6
    JP      test_fail
.ok_gap_end:
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_up
    LD      A, 0xD9
    LD      B, 7
    JP      test_fail
.ok_up:
    LD      HL, (undo_length)
    LD      A, H
    OR      L
    JR      Z, .ok_ul
    LD      A, 0xD9
    LD      B, 8
    JP      test_fail
.ok_ul:
    JP      test_pass

.payload:
    DEFB    "abc", 0x0A, "def"

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
