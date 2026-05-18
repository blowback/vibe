; ============================================================
; Module: test/cases/visual_d-block-jagged.asm
; Purpose: Story 3.6 AC5 / AC8 / AC9 — CRITICAL BH3 test. Verify
;          that visual_apply_operator with A='d' on a VIS_BLOCK
;          rectangle correctly clips per-row at each line's EOL
;          (short lines contribute their available bytes only;
;          they are NOT padded); writes the deleted content to
;          yank_buffer in KIND_BLOCK format (rows joined by LF,
;          NO trailing LF, empty rows still get separator LFs);
;          records UNDO_KIND_TOO_LARGE (multi-region undo
;          deferred per Q2 Option A); places cursor at top-left
;          of the bounding rectangle; mode transitions to NORMAL.
;
;          Fixture: "abcdef\nxy\nabcdef" (16 B; LFs at 6, 9).
;          Line 1 = 6 chars, line 2 = 2 chars, line 3 = 6 chars.
;          Pre-set mode_byte = MODE_VISUAL, visual_submode =
;          VIS_BLOCK, visual_anchor = 0, cursor_offset = 12
;          (line 3, col 2). Bounding rectangle: rows=3, cols=3
;          (col_min=0, col_max=2).
;
;          Expected per-row clipped slices:
;            row 0 (line 1, len 6): col_min=0, col_max=2 →
;                  bytes_this_row = 3 ("abc")
;            row 1 (line 2, len 2): col_min=0, col_max=2 →
;                  min(col_max+1, line_length) - col_min
;                  = min(3, 2) - 0 = 2 ("xy")
;            row 2 (line 3, len 6): same as row 0, "abc" (3 B)
;
;          Post-delete buffer: "def\n\ndef" (8 B).
;          KIND_BLOCK yank format: "abc\nxy\nabc" (10 B; rows
;          joined by LF separators, NO trailing LF —
;          3 + 1 LF + 2 + 1 LF + 3 = 10).
;
; Sentinel 0xD3 — context byte:
;   0  — mode_byte != MODE_NORMAL
;   1  — cursor_offset != 0 (top-left)
;   2  — buffer logical[0..7] != "def\n\ndef"
;   3  — yank_kind != KIND_BLOCK
;   4  — yank_length != 10
;   5  — yank_buffer[0..9] != "abc\nxy\nabc"
;   6  — undo_kind != UNDO_KIND_TOO_LARGE
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

    ;; Populate "abcdef\nxy\nabcdef" (16 B; LFs at 6, 9).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 16
    LDIR
    LD      HL, GAP_BUFFER_BASE + 16
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
    LD      A, 'd'
    CALL    visual_apply_operator

    ;; --- Assertions ---
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xD3
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0xD3
    LD      B, 1
    JP      test_fail
.ok_cursor:
    ;; Buffer logical[0..7] should be "def\n\ndef"
    LD      HL, 0
    LD      DE, .expect_buf
    LD      B, 8
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
    LD      A, 0xD3
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (yank_kind)
    CP      KIND_BLOCK
    JR      Z, .ok_yk
    LD      A, 0xD3
    LD      B, 3
    JP      test_fail
.ok_yk:
    LD      HL, (yank_length)
    LD      DE, 10
    OR      A
    SBC     HL, DE
    JR      Z, .ok_yl
    LD      A, 0xD3
    LD      B, 4
    JP      test_fail
.ok_yl:
    LD      HL, yank_buffer
    LD      DE, .yank_expected
    LD      B, 10
.ycmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 0xD3
    LD      B, 5
    JP      test_fail
.ycmp_next:
    INC     HL
    INC     DE
    DJNZ    .ycmp

    LD      A, (undo_kind)
    CP      UNDO_KIND_TOO_LARGE
    JR      Z, .ok_undo
    LD      A, 0xD3
    LD      B, 6
    JP      test_fail
.ok_undo:
    JP      test_pass

.payload:
    DEFB    "abcdef", 0x0A, "xy", 0x0A, "abcdef"
.expect_buf:
    DEFB    "def", 0x0A, 0x0A, "def"
.yank_expected:
    DEFB    "abc", 0x0A, "xy", 0x0A, "abc"

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
