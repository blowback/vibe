; ============================================================
; Module: test/cases/visual_y-block.asm
; Purpose: Story 3.6 AC5 / AC9 — verify the KIND_BLOCK yank
;          format on a uniform rectangle (no jagged-line clipping).
;          Visual block 'y' yanks the per-row content joined by
;          LF separators (no trailing LF) into yank_buffer; buffer
;          is UNCHANGED (yank-only); cursor restored to top-left.
;
;          Buffer "abcd\nefgh\nijkl" (14 B; 3 lines × 4 chars;
;          LFs at 4, 9). Pre-set mode_byte = MODE_VISUAL,
;          visual_submode = VIS_BLOCK, visual_anchor = 0,
;          cursor_offset = 12 (line 3, col 2).
;          Rectangle: rows=3, cols=3 (anchor_col=0, cursor_col=2).
;          Per-row content: row 0 = "abc" (3 B); row 1 = "efg"
;          (3 B); row 2 = "ijk" (3 B). Total yank = 3+1+3+1+3 =
;          11 B = "abc\nefg\nijk".
;
; Sentinel 0xD5 — context byte:
;   0  — mode_byte != MODE_NORMAL
;   1  — cursor_offset != 0 (top-left)
;   2  — buffer first 14 B != "abcd\nefgh\nijkl" (yank-only must not mutate)
;   3  — yank_kind != KIND_BLOCK
;   4  — yank_length != 11
;   5  — yank_buffer[0..10] != "abc\nefg\nijk"
;   6  — undo_kind != UNDO_KIND_EMPTY (y must not record undo)
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
    LD      HL, 0
    LD      (yank_length), HL

    ;; Populate "abcd\nefgh\nijkl" (14 B).
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

    ;; --- Execute ---
    LD      A, 'y'
    CALL    visual_apply_operator

    ;; --- Assertions ---
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xD5
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0xD5
    LD      B, 1
    JP      test_fail
.ok_cursor:
    ;; Buffer unchanged
    LD      HL, 0
    LD      DE, .payload
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
    LD      A, 0xD5
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (yank_kind)
    CP      KIND_BLOCK
    JR      Z, .ok_yk
    LD      A, 0xD5
    LD      B, 3
    JP      test_fail
.ok_yk:
    LD      HL, (yank_length)
    LD      DE, 11
    OR      A
    SBC     HL, DE
    JR      Z, .ok_yl
    LD      A, 0xD5
    LD      B, 4
    JP      test_fail
.ok_yl:
    LD      HL, yank_buffer
    LD      DE, .yank_expected
    LD      B, 11
.ycmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 0xD5
    LD      B, 5
    JP      test_fail
.ycmp_next:
    INC     HL
    INC     DE
    DJNZ    .ycmp

    LD      A, (undo_kind)
    CP      UNDO_KIND_EMPTY
    JR      Z, .ok_undo
    LD      A, 0xD5
    LD      B, 6
    JP      test_fail
.ok_undo:
    JP      test_pass

.payload:
    DEFB    "abcd", 0x0A, "efgh", 0x0A, "ijkl"
.yank_expected:
    DEFB    "abc", 0x0A, "efg", 0x0A, "ijk"

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
