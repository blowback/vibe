; ============================================================
; Module: test/cases/visual_tilde-block-jagged.asm
; Purpose: Story 3.8 AC6 / AC7 VIS_BLOCK `~` with BH3 jagged-line
;          clipping. Buffer "ABCDE\nFG\nHIJKL" (14 B; LFs at 5, 8;
;          line 1 = 5 chars; line 2 = 2 chars SHORT; line 3 = 5
;          chars). Pre-set mode=VISUAL, submode=VIS_BLOCK,
;          visual_anchor=0 (col 0), cursor=12 (line 3 col 3 = 'K';
;          line 3 starts at offset 9). Rectangle nominally 3 rows
;          × 4 cols (col_min=0, col_max=3). Per-row toggle:
;            Row 1 (line_length=5) cols [0,4) = "ABCD" → "abcd"
;            Row 2 (line_length=2; BH3 CLIPPED) cols [0, min(4,2))
;                                          = [0,2) = "FG" → "fg"
;            Row 3 (line_length=5) cols [0,4) = "HIJK" → "hijk"
;
;          Buffer post-call: "abcdE\nfg\nhijkL". Pins BH3 per-row
;          clipping for case toggle — distinguishes from any
;          naive "whole-rectangle" toggle that would have toggled
;          non-existent bytes past line 2's EOL.
;
; Sentinel 0xF9 — context byte:
;   0 — mode_byte != MODE_NORMAL
;   1 — cursor_offset != 0
;   2 — buffer first 14 B != "abcdE\nfg\nhijkL"
;   3 — undo_kind != UNDO_KIND_TOO_LARGE
;   4 — buffer_dirty != 1
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
    LD      BC, 14
    LDIR
    LD      HL, GAP_BUFFER_BASE + 14
    LD      (gap_start), HL

    LD      HL, 12
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
    LD      A, 0xF9
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0xF9
    LD      B, 1
    JP      test_fail
.ok_cursor:
    LD      HL, 0
    LD      DE, .expect_buf
    LD      B, 14
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
    LD      A, 0xF9
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (undo_kind)
    CP      UNDO_KIND_TOO_LARGE
    JR      Z, .ok_uk
    LD      A, 0xF9
    LD      B, 3
    JP      test_fail
.ok_uk:
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      A, 0xF9
    LD      B, 4
    JP      test_fail
.ok_dirty:
    JP      test_pass

.payload:
    DEFB    "ABCDE", 0x0A, "FG", 0x0A, "HIJKL"
.expect_buf:
    DEFB    "abcdE", 0x0A, "fg", 0x0A, "hijkL"

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
