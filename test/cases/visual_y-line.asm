; ============================================================
; Module: test/cases/visual_y-line.asm
; Purpose: Story 3.6 AC4 / AC6 — verify that visual_apply_operator
;          with A='y' on a VIS_LINE selection yanks the line's
;          full byte range (KIND_LINE; includes trailing LF),
;          leaves the buffer UNCHANGED, restores cursor to
;          range_start, and transitions mode_byte to MODE_NORMAL.
;          Also confirms NO undo entry is recorded (yank-only;
;          inherits the op_yy invariant).
;
;          Buffer "abcde\nfghij\nklmno" (17 B; LFs at 5, 11).
;          Cursor=8 (line 2 col 2). Pre-set mode_byte =
;          MODE_VISUAL, visual_submode = VIS_LINE, visual_anchor
;          = 6 (line 2's start, per Story 3.4 AC2 invariant).
;          Selection covers line 2 only: range = [6, 12) =
;          "fghij\n" = 6 bytes. CALL visual_apply_operator with
;          A='y'.
;
; Sentinel 0xD1 — context byte:
;   0 — mode_byte != MODE_NORMAL
;   1 — cursor_offset != 6 (range_start)
;   2 — buffer first 17 B != "abcde\nfghij\nklmno" (mutated by y)
;   3 — yank_kind != KIND_LINE
;   4 — yank_length != 6
;   5 — yank_buffer[0..5] != "fghij\n"
;   6 — undo_kind != UNDO_KIND_EMPTY (y must not record undo)
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
    LD      (undo_kind), A          ; UNDO_KIND_EMPTY = 0
    LD      (yank_kind), A
    LD      HL, 0
    LD      (yank_length), HL

    ;; Populate "abcde\nfghij\nklmno" (17 B; LFs at 5, 11).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 17
    LDIR
    LD      HL, GAP_BUFFER_BASE + 17
    LD      (gap_start), HL

    LD      HL, 8
    LD      (cursor_offset), HL
    LD      HL, 6
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_LINE
    LD      (visual_submode), A

    ;; --- Execute ---
    LD      A, 'y'
    CALL    visual_apply_operator

    ;; --- Assertions ---
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xD1
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      DE, 6
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor
    LD      A, 0xD1
    LD      B, 1
    JP      test_fail
.ok_cursor:
    ;; Buffer unchanged: logical bytes 0..16 == .payload
    LD      HL, 0
    LD      DE, .payload
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
    LD      A, 0xD1
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (yank_kind)
    CP      KIND_LINE
    JR      Z, .ok_yk
    LD      A, 0xD1
    LD      B, 3
    JP      test_fail
.ok_yk:
    LD      HL, (yank_length)
    LD      DE, 6
    OR      A
    SBC     HL, DE
    JR      Z, .ok_yl
    LD      A, 0xD1
    LD      B, 4
    JP      test_fail
.ok_yl:
    LD      HL, yank_buffer
    LD      DE, .yank_expected
    LD      B, 6
.ycmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 0xD1
    LD      B, 5
    JP      test_fail
.ycmp_next:
    INC     HL
    INC     DE
    DJNZ    .ycmp

    LD      A, (undo_kind)
    CP      UNDO_KIND_EMPTY
    JR      Z, .ok_undo
    LD      A, 0xD1
    LD      B, 6
    JP      test_fail
.ok_undo:
    JP      test_pass

.payload:
    DEFB    "abcde", 0x0A, "fghij", 0x0A, "klmno"
.yank_expected:
    DEFB    "fghij", 0x0A

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
