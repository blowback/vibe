; ============================================================
; Module: test/cases/visual_shift-left.asm
; Purpose: Story 3.7 AC2 / AC4 / AC5 — VIS_LINE `<` happy path on
;          a pre-indented buffer. visual_apply_shift with A='<'
;          dedents both selected lines, records UNDO_KIND_DEDENT_WALK,
;          places cursor at promoted_start.
;
;          Buffer " abc\n def\nghi" (13 B; LFs at 4, 9). Pre-seed
;          mode=VISUAL, submode=VIS_LINE, anchor=0, cursor=5
;          (line 2 line-start). CALL with A='<'.
;
;          Expected:
;            mode_byte         = MODE_NORMAL
;            cursor_offset     = 0
;            buffer first 11 B = "abc\ndef\nghi" (2 leading spaces
;                                                  removed)
;            undo_kind         = UNDO_KIND_DEDENT_WALK
;            undo_position     = 0
;            undo_length       = 8 (pre-walk 10 - 2 deletes; Q6
;                                   Option B post-walk end)
;            buffer_dirty      = 1
;
; Sentinel 0xD8 — context byte:
;   0 — mode_byte != MODE_NORMAL
;   1 — cursor_offset != 0
;   2 — buffer first 11 B != "abc\ndef\nghi"
;   3 — undo_kind != UNDO_KIND_DEDENT_WALK
;   4 — undo_position != 0
;   5 — undo_length != 8
;   6 — buffer_dirty != 1
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
    LD      (undo_kind), A
    LD      (yank_kind), A
    LD      (buffer_dirty), A
    LD      HL, 0
    LD      (undo_position), HL
    LD      (undo_length), HL

    ;; Populate " abc\n def\nghi" (13 B; LFs at 4, 9).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 13
    LDIR
    LD      HL, GAP_BUFFER_BASE + 13
    LD      (gap_start), HL

    LD      HL, 5
    LD      (cursor_offset), HL
    LD      HL, 0
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
    LD      A, 0xD8
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0xD8
    LD      B, 1
    JP      test_fail
.ok_cursor:
    LD      HL, 0
    LD      DE, .expect_buf
    LD      B, 11
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
    LD      A, 0xD8
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (undo_kind)
    CP      UNDO_KIND_DEDENT_WALK
    JR      Z, .ok_uk
    LD      A, 0xD8
    LD      B, 3
    JP      test_fail
.ok_uk:
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_up
    LD      A, 0xD8
    LD      B, 4
    JP      test_fail
.ok_up:
    LD      HL, (undo_length)
    LD      DE, 8
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_ul
    LD      A, 0xD8
    LD      B, 5
    JP      test_fail
.ok_ul:
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      A, 0xD8
    LD      B, 6
    JP      test_fail
.ok_dirty:
    JP      test_pass

.payload:
    DEFB    " abc", 0x0A, " def", 0x0A, "ghi"
.expect_buf:
    DEFB    "abc", 0x0A, "def", 0x0A, "ghi"

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
