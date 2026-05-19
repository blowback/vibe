; ============================================================
; Module: test/cases/visual_tilde-block.asm
; Purpose: Story 3.8 AC2 / AC6 / AC7 VIS_BLOCK `~` happy path
;          (EPIC MINIMUM) — BH3 column range respected. Buffer
;          "HELLO\nworld\nFOObar" (17 B; LFs at 5, 11). Pre-set
;          mode=VISUAL, submode=VIS_BLOCK, visual_anchor=0 (line 1
;          col 0), cursor=14 (line 3 col 2; offsets are line 1
;          [0..4] LF[5] line 2 [6..10] LF[11] line 3 [12..17]).
;          Rectangle is 3 rows × 3 cols (anchor_col=0, cursor_col=2,
;          col_min=0, col_max=2). Per-row toggle:
;            Row 1 "HELLO" cols [0,3) = "HEL" → "hel"
;            Row 2 "world" cols [0,3) = "wor" → "WOR"
;            Row 3 "FOObar" cols [0,3) = "FOO" → "foo"
;
;          Buffer post-call: "helLO\nWORld\nfoobar".
;
;          UNDO_KIND_TOO_LARGE direct record per Q1 Option A
;          (multi-region undo deferred — `u` post-toggle surfaces
;          msg_undo_too_large). cursor_offset = top_ls + col_min = 0.
;
; Sentinel 0xF8 — context byte:
;   0 — mode_byte != MODE_NORMAL
;   1 — cursor_offset != 0
;   2 — buffer first 17 B != "helLO\nWORld\nfoobar"
;   3 — undo_kind != UNDO_KIND_TOO_LARGE
;   4 — undo_position != 0
;   5 — undo_length != 0
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

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 17
    LDIR
    LD      HL, GAP_BUFFER_BASE + 17
    LD      (gap_start), HL

    LD      HL, 14
    LD      (cursor_offset), HL
    LD      HL, 0
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_BLOCK
    LD      (visual_submode), A

    LD      A, '~'
    CALL    visual_apply_case_toggle

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xF8
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0xF8
    LD      B, 1
    JP      test_fail
.ok_cursor:
    LD      HL, 0
    LD      DE, .expect_buf
    LD      B, 17
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
    LD      A, 0xF8
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (undo_kind)
    CP      UNDO_KIND_TOO_LARGE
    JR      Z, .ok_uk
    LD      A, 0xF8
    LD      B, 3
    JP      test_fail
.ok_uk:
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_up
    LD      A, 0xF8
    LD      B, 4
    JP      test_fail
.ok_up:
    LD      HL, (undo_length)
    LD      A, H
    OR      L
    JR      Z, .ok_ul
    LD      A, 0xF8
    LD      B, 5
    JP      test_fail
.ok_ul:
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      A, 0xF8
    LD      B, 6
    JP      test_fail
.ok_dirty:
    JP      test_pass

.payload:
    DEFB    "HELLO", 0x0A, "world", 0x0A, "FOObar"
.expect_buf:
    DEFB    "helLO", 0x0A, "WORld", 0x0A, "foobar"

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
