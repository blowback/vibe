; ============================================================
; Module: test/cases/visual_c-line-enters-insert.asm
; Purpose: Story 3.6 AC4 / AC6 / AC7 — verify visual_apply_operator
;          with A='c' on a VIS_LINE selection: deletes the
;          line-bounded range (including trailing LFs), yanks
;          KIND_LINE, records UNDO_KIND_DELETE (phase 1; phase 2
;          REPLACE upgrade fires at INSERT-exit which this unit
;          test doesn't exercise), places cursor at range_start,
;          and transitions mode_byte to MODE_INSERT.
;
;          Buffer "first line\nsecond line\nthird line" (33 B;
;          LFs at 10, 22). Cursor=15 (line 2, col 4 = 'n' in
;          "second"). Pre-set mode_byte = MODE_VISUAL,
;          visual_submode = VIS_LINE, visual_anchor = 0 (line 1
;          start). Selection covers lines 1 + 2; range = [0, 23)
;          = 23 bytes "first line\nsecond line\n".
;
; Sentinel 0xD6 — context byte:
;   0  — mode_byte != MODE_INSERT
;   1  — cursor_offset != 0
;   2  — buffer first 10 B != "third line"
;   3  — yank_kind != KIND_LINE
;   4  — yank_length != 23
;   5  — yank_buffer[0..22] != "first line\nsecond line\n"
;   6  — undo_kind != UNDO_KIND_DELETE
;   7  — status_buffer[0..11] != "-- insert --"
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

    ;; Populate fixture (33 B).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 33
    LDIR
    LD      HL, GAP_BUFFER_BASE + 33
    LD      (gap_start), HL

    LD      HL, 15
    LD      (cursor_offset), HL
    LD      HL, 0
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_LINE
    LD      (visual_submode), A

    ;; --- Execute ---
    LD      A, 'c'
    CALL    visual_apply_operator

    ;; --- Assertions ---
    LD      A, (mode_byte)
    CP      MODE_INSERT
    JR      Z, .ok_mode
    LD      A, 0xD6
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0xD6
    LD      B, 1
    JP      test_fail
.ok_cursor:
    ;; Buffer first 10 bytes (logical) = "third line"
    LD      HL, 0
    LD      DE, .expect_buf
    LD      B, 10
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
    LD      A, 0xD6
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (yank_kind)
    CP      KIND_LINE
    JR      Z, .ok_yk
    LD      A, 0xD6
    LD      B, 3
    JP      test_fail
.ok_yk:
    LD      HL, (yank_length)
    LD      DE, 23
    OR      A
    SBC     HL, DE
    JR      Z, .ok_yl
    LD      A, 0xD6
    LD      B, 4
    JP      test_fail
.ok_yl:
    LD      HL, yank_buffer
    LD      DE, .payload
    LD      B, 23
.ycmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 0xD6
    LD      B, 5
    JP      test_fail
.ycmp_next:
    INC     HL
    INC     DE
    DJNZ    .ycmp

    LD      A, (undo_kind)
    CP      UNDO_KIND_DELETE
    JR      Z, .ok_undo
    LD      A, 0xD6
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
    LD      A, 0xD6
    LD      B, 7
    JP      test_fail
.scmp_next:
    INC     HL
    INC     DE
    DJNZ    .scmp

    JP      test_pass

.payload:
    DEFB    "first line", 0x0A, "second line", 0x0A, "third line"
.expect_buf:
    DEFB    "third line"
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
