; ============================================================
; Module: test/cases/visual_tilde-toggles.asm
; Purpose: Story 3.8 AC2 / AC3 / AC6 VIS_CHAR `~` happy path
;          (EPIC MINIMUM). Buffer "Hello World" (11 B; no LF);
;          pre-set mode=VISUAL, submode=VIS_CHAR, visual_anchor=0,
;          cursor=10 (= 'd', last byte). CALL visual_apply_case_toggle
;          with A='~'. Verify every alphabetic byte toggled in
;          place, range_start cursor placement, single-region
;          UNDO_KIND_CASE_TOGGLE recorded.
;
;          Buffer post-call: "hELLO wORLD" — 'H'→'h'; 'e'→'E';
;          'l'→'L'; 'l'→'L'; 'o'→'O'; space (0x20) unchanged;
;          'W'→'w'; 'o'→'O'; 'r'→'R'; 'l'→'L'; 'd'→'D'.
;
; Sentinel 0xDF — context byte:
;   0 — mode_byte != MODE_NORMAL
;   1 — cursor_offset != 0
;   2 — buffer first 11 B != "hELLO wORLD"
;   3 — undo_kind != UNDO_KIND_CASE_TOGGLE
;   4 — undo_position != 0
;   5 — undo_length != 11
;   6 — buffer_dirty != 1
;   7 — yank_kind clobbered (!= 0xEE sentinel)
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
    LD      (buffer_dirty), A
    LD      HL, 0
    LD      (undo_position), HL
    LD      (undo_length), HL

    ;; Sentinel yank_kind to verify visual_apply_case_toggle doesn't touch yank.
    LD      A, 0xEE
    LD      (yank_kind), A

    ;; Populate "Hello World" (11 B; no LF).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 11
    LDIR
    LD      HL, GAP_BUFFER_BASE + 11
    LD      (gap_start), HL

    LD      HL, 10
    LD      (cursor_offset), HL
    LD      HL, 0
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A

    ;; --- Execute: visual_apply_case_toggle with A='~' ---
    LD      A, '~'
    CALL    visual_apply_case_toggle

    ;; --- Assertions ---
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xDF
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0xDF
    LD      B, 1
    JP      test_fail
.ok_cursor:
    ;; Buffer first 11 bytes == "hELLO wORLD"
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
    LD      A, 0xDF
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (undo_kind)
    CP      UNDO_KIND_CASE_TOGGLE
    JR      Z, .ok_uk
    LD      A, 0xDF
    LD      B, 3
    JP      test_fail
.ok_uk:
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_up
    LD      A, 0xDF
    LD      B, 4
    JP      test_fail
.ok_up:
    LD      HL, (undo_length)
    LD      DE, 11
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_ul
    LD      A, 0xDF
    LD      B, 5
    JP      test_fail
.ok_ul:
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      A, 0xDF
    LD      B, 6
    JP      test_fail
.ok_dirty:
    LD      A, (yank_kind)
    CP      0xEE
    JR      Z, .ok_yk
    LD      A, 0xDF
    LD      B, 7
    JP      test_fail
.ok_yk:
    JP      test_pass

.payload:
    DEFB    "Hello World"
.expect_buf:
    DEFB    "hELLO wORLD"

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
