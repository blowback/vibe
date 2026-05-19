; ============================================================
; Module: test/cases/visual_tilde-undo.asm
; Purpose: Story 3.8 AC5 single-region undo round-trip via CHAR.
;          Phase 1: visual_apply_case_toggle on "Hello" (VIS_CHAR,
;          anchor=0, cursor=4) records UNDO_KIND_CASE_TOGGLE,
;          toggles to "hELLO". Phase 2: op_undo replays via
;          undo_replay_case_toggle (self-inverse re-walk) and
;          restores "Hello".
;
;          Pins the self-inverse replay contract: case-toggle is
;          its own inverse (XOR 0x20 twice = identity); replay
;          structure is identical to the original `~` op.
;
; Sentinel 0xFB — context byte:
;   Phase 1:
;     0 — mode_byte != MODE_NORMAL
;     1 — cursor_offset != 0
;     2 — buffer first 5 B != "hELLO"
;     3 — undo_kind != UNDO_KIND_CASE_TOGGLE
;     4 — undo_position != 0
;     5 — undo_length != 5
;     6 — buffer_dirty != 1
;   Phase 2:
;     7 — buffer first 5 B != "Hello" (restored)
;     8 — undo_kind != UNDO_KIND_EMPTY (consumed by replay)
;     9 — cursor_offset != 0
;    10 — buffer_dirty != 1 (Q5 Option A pin — buffer_dirty stays
;         set after successful undo)
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
    LD      BC, 5
    LDIR
    LD      HL, GAP_BUFFER_BASE + 5
    LD      (gap_start), HL

    LD      HL, 4
    LD      (cursor_offset), HL
    LD      HL, 0
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A

    ;; --- Phase 1: visual_apply_case_toggle A='~' ---
    LD      A, '~'
    CALL    visual_apply_case_toggle

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .p1_ok_mode
    LD      A, 0xFB
    LD      B, 0
    JP      test_fail
.p1_ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .p1_ok_cursor
    LD      A, 0xFB
    LD      B, 1
    JP      test_fail
.p1_ok_cursor:
    LD      HL, 0
    LD      DE, .expect_phase1
    LD      B, 5
.p1_buf_loop:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .p1_buf_next
    LD      A, 0xFB
    LD      B, 2
    JP      test_fail
.p1_buf_next:
    INC     HL
    INC     DE
    DJNZ    .p1_buf_loop

    LD      A, (undo_kind)
    CP      UNDO_KIND_CASE_TOGGLE
    JR      Z, .p1_ok_uk
    LD      A, 0xFB
    LD      B, 3
    JP      test_fail
.p1_ok_uk:
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .p1_ok_up
    LD      A, 0xFB
    LD      B, 4
    JP      test_fail
.p1_ok_up:
    LD      HL, (undo_length)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .p1_ok_ul
    LD      A, 0xFB
    LD      B, 5
    JP      test_fail
.p1_ok_ul:
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .p1_ok_dirty
    LD      A, 0xFB
    LD      B, 6
    JP      test_fail
.p1_ok_dirty:

    ;; --- Phase 2: op_undo ---
    LD      A, 'u'
    CALL    op_undo

    ;; Buffer restored to "Hello"
    LD      HL, 0
    LD      DE, .payload
    LD      B, 5
.p2_buf_loop:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .p2_buf_next
    LD      A, 0xFB
    LD      B, 7
    JP      test_fail
.p2_buf_next:
    INC     HL
    INC     DE
    DJNZ    .p2_buf_loop

    LD      A, (undo_kind)
    CP      UNDO_KIND_EMPTY
    JR      Z, .p2_ok_uk
    LD      A, 0xFB
    LD      B, 8
    JP      test_fail
.p2_ok_uk:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .p2_ok_cursor
    LD      A, 0xFB
    LD      B, 9
    JP      test_fail
.p2_ok_cursor:
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .p2_ok_dirty
    LD      A, 0xFB
    LD      B, 10
    JP      test_fail
.p2_ok_dirty:
    JP      test_pass

.payload:
    DEFB    "Hello"
.expect_phase1:
    DEFB    "hELLO"

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
