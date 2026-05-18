; ============================================================
; Module: test/cases/visual_c-char-enters-insert.asm
; Purpose: Story 3.6 AC3 / AC6 / AC7 / AC8 — verify that
;          visual_apply_operator with A='c' on a VIS_CHAR
;          selection deletes the inclusive range, yanks the
;          deleted bytes (KIND_CHAR), records UNDO_KIND_DELETE
;          (phase-1 of the two-phase REPLACE — phase-2 fires at
;          INSERT exit via undo_insert_exit_record, NOT exercised
;          here), places cursor at range_start, transitions
;          mode_byte to MODE_INSERT, and sets the "-- insert --"
;          status banner.
;
;          Buffer "abcdef" (6 B). Cursor=4 ('e'). Pre-set
;          mode_byte = MODE_VISUAL, visual_submode = VIS_CHAR,
;          visual_anchor = 2 ('c'). Selection = "cde" = 3 bytes
;          (range [2, 5) per AC3 inclusive bump). CALL
;          visual_apply_operator with A='c'.
;
; Sentinel 0xD2 — context byte:
;   0 — mode_byte != MODE_INSERT
;   1 — cursor_offset != 2
;   2 — buffer first 3 B != "abf"
;   3 — yank_kind != KIND_CHAR
;   4 — yank_length != 3
;   5 — yank_buffer[0..2] != "cde"
;   6 — undo_kind != UNDO_KIND_DELETE (phase 1)
;   7 — status_buffer[0..11] != "-- insert --"
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

    ;; Populate "abcdef" (6 B).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 6
    LDIR
    LD      HL, GAP_BUFFER_BASE + 6
    LD      (gap_start), HL

    LD      HL, 4
    LD      (cursor_offset), HL
    LD      HL, 2
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A

    ;; --- Execute ---
    LD      A, 'c'
    CALL    visual_apply_operator

    ;; --- Assertions ---
    LD      A, (mode_byte)
    CP      MODE_INSERT
    JR      Z, .ok_mode
    LD      A, 0xD2
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      DE, 2
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor
    LD      A, 0xD2
    LD      B, 1
    JP      test_fail
.ok_cursor:
    ;; Buffer first 3 bytes (logical) should be "abf"
    LD      HL, 0
    LD      DE, .expect_buf
    LD      B, 3
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
    LD      A, 0xD2
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (yank_kind)
    CP      KIND_CHAR
    JR      Z, .ok_yk
    LD      A, 0xD2
    LD      B, 3
    JP      test_fail
.ok_yk:
    LD      HL, (yank_length)
    LD      DE, 3
    OR      A
    SBC     HL, DE
    JR      Z, .ok_yl
    LD      A, 0xD2
    LD      B, 4
    JP      test_fail
.ok_yl:
    LD      HL, yank_buffer
    LD      DE, .yank_expected
    LD      B, 3
.ycmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 0xD2
    LD      B, 5
    JP      test_fail
.ycmp_next:
    INC     HL
    INC     DE
    DJNZ    .ycmp

    LD      A, (undo_kind)
    CP      UNDO_KIND_DELETE
    JR      Z, .ok_undo
    LD      A, 0xD2
    LD      B, 6
    JP      test_fail
.ok_undo:
    ;; status_buffer starts with "-- insert --"
    LD      HL, status_buffer
    LD      DE, .insert_banner
    LD      B, 12
.scmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .scmp_next
    LD      A, 0xD2
    LD      B, 7
    JP      test_fail
.scmp_next:
    INC     HL
    INC     DE
    DJNZ    .scmp

    JP      test_pass

.payload:
    DEFB    "abcdef"
.expect_buf:
    DEFB    "abf"
.yank_expected:
    DEFB    "cde"
.insert_banner:
    DEFB    "-- insert --"

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
