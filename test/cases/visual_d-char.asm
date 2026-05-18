; ============================================================
; Module: test/cases/visual_d-char.asm
; Purpose: Story 3.6 AC3 / AC6 / AC8 — verify that
;          visual_apply_operator with A='d' on a VIS_CHAR
;          selection deletes the inclusive range, yanks the
;          deleted bytes (KIND_CHAR), records UNDO_KIND_DELETE
;          with the payload, places cursor at range_start, and
;          transitions mode_byte to MODE_NORMAL.
;
;          Buffer "abcde\nfghij" (11 B; LF at 5). Pre-seed
;          mode_byte = MODE_VISUAL, visual_submode = VIS_CHAR,
;          visual_anchor = 0, cursor_offset = 3 (so selection
;          spans 4 bytes: "abcd", inclusive of both endpoints
;          per AC3 +1 inclusive bump). CALL visual_apply_operator
;          with A='d'.
;
;          Expected:
;            mode_byte         = MODE_NORMAL
;            cursor_offset     = 0 (range_start)
;            buffer first 7 B  = "e\nfghij" (4-byte shift up)
;            yank_kind         = KIND_CHAR
;            yank_length       = 4
;            yank_buffer[0..3] = "abcd"
;            undo_kind         = UNDO_KIND_DELETE
;            undo_position     = 0
;            undo_length       = 4
;            undo_buffer[0..3] = "abcd"
;
; Sentinel 0xD0 — context byte:
;   0 — mode_byte != MODE_NORMAL
;   1 — cursor_offset != 0
;   2 — buffer first 7 B != "e\nfghij"
;   3 — yank_kind != KIND_CHAR
;   4 — yank_length != 4
;   5 — yank_buffer[0..3] != "abcd"
;   6 — undo_kind != UNDO_KIND_DELETE
;   7 — undo_position != 0
;   8 — undo_length != 4
;   9 — undo_buffer[0..3] != "abcd"
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
    LD      (undo_position), HL
    LD      (undo_length), HL

    ;; Populate "abcde\nfghij" (11 B; LF at 5).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 11
    LDIR
    LD      HL, GAP_BUFFER_BASE + 11
    LD      (gap_start), HL

    LD      HL, 3
    LD      (cursor_offset), HL
    LD      HL, 0
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A

    ;; --- Execute: visual_apply_operator with A='d' ---
    LD      A, 'd'
    CALL    visual_apply_operator

    ;; --- Assertions ---
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xD0
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0xD0
    LD      B, 1
    JP      test_fail
.ok_cursor:
    ;; buffer first 7 bytes (logical) should be "e\nfghij"
    LD      HL, 0
    LD      DE, .expect_buf
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
    LD      A, 0xD0
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop
    LD      A, (yank_kind)
    CP      KIND_CHAR
    JR      Z, .ok_yk
    LD      A, 0xD0
    LD      B, 3
    JP      test_fail
.ok_yk:
    LD      HL, (yank_length)
    LD      DE, 4
    OR      A
    SBC     HL, DE
    JR      Z, .ok_yl
    LD      A, 0xD0
    LD      B, 4
    JP      test_fail
.ok_yl:
    LD      HL, yank_buffer
    LD      DE, .payload
    LD      B, 4
    CALL    .cmp_block
    JR      Z, .ok_yb
    LD      A, 0xD0
    LD      B, 5
    JP      test_fail
.ok_yb:
    LD      A, (undo_kind)
    CP      UNDO_KIND_DELETE
    JR      Z, .ok_uk
    LD      A, 0xD0
    LD      B, 6
    JP      test_fail
.ok_uk:
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_up
    LD      A, 0xD0
    LD      B, 7
    JP      test_fail
.ok_up:
    LD      HL, (undo_length)
    LD      DE, 4
    OR      A
    SBC     HL, DE
    JR      Z, .ok_ul
    LD      A, 0xD0
    LD      B, 8
    JP      test_fail
.ok_ul:
    LD      HL, undo_buffer
    LD      DE, .payload
    LD      B, 4
    CALL    .cmp_block
    JR      Z, .ok_ub
    LD      A, 0xD0
    LD      B, 9
    JP      test_fail
.ok_ub:
    JP      test_pass

; HL = lhs, DE = rhs, B = byte count.
; Returns Z on match. Trashes A, B, DE, HL, F.
.cmp_block:
    LD      A, (DE)
    CP      (HL)
    RET     NZ
    INC     HL
    INC     DE
    DJNZ    .cmp_block
    XOR     A
    RET

.payload:
    DEFB    "abcde", 0x0A, "fghij"
.expect_buf:
    DEFB    "e", 0x0A, "fghij"

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
