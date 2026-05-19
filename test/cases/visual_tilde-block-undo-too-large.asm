; ============================================================
; Module: test/cases/visual_tilde-block-undo-too-large.asm
; Purpose: Story 3.8 AC6 / AC7 BLOCK undo surfaces TOO_LARGE.
;          Buffer "AB\nCD" (5 B; LF at 2). Pre-set mode=VISUAL,
;          submode=VIS_BLOCK, visual_anchor=0, cursor=4
;          (anchor_col=0, cursor_col=1, 2 rows × 2 cols).
;
;          Phase 1: visual_apply_case_toggle A='~'. Verify
;            buffer = "ab\ncd"
;            undo_kind = UNDO_KIND_TOO_LARGE (Q1 Option A direct record)
;            undo_position = 0 (top_ls)
;            undo_length = 0 (semantically meaningless for TOO_LARGE)
;            buffer_dirty = 1
;
;          Phase 2: op_undo. Verify
;            buffer UNCHANGED ("ab\ncd"; TOO_LARGE replay is a NO-OP)
;            undo_kind = UNDO_KIND_TOO_LARGE (Q4 Option A from Story 2.13:
;                                              NOT consumed by surfacing;
;                                              second `u` re-surfaces same
;                                              message)
;
;          Pins the BLOCK TOO_LARGE direct-record + replay-refusal contract.
;
; Sentinel 0xFC — context byte:
;   Phase 1:
;     0 — mode_byte != MODE_NORMAL
;     1 — buffer first 5 B != "ab\ncd"
;     2 — undo_kind != UNDO_KIND_TOO_LARGE
;     3 — undo_position != 0
;     4 — undo_length != 0
;     5 — buffer_dirty != 1
;   Phase 2:
;     6 — buffer changed (TOO_LARGE replay must be a no-op)
;     7 — undo_kind cleared (Q4 Option A pin — must remain TOO_LARGE)
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
    LD      A, VIS_BLOCK
    LD      (visual_submode), A

    ;; --- Phase 1: visual_apply_case_toggle A='~' ---
    LD      A, '~'
    CALL    visual_apply_case_toggle

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .p1_ok_mode
    LD      A, 0xFC
    LD      B, 0
    JP      test_fail
.p1_ok_mode:
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
    LD      A, 0xFC
    LD      B, 1
    JP      test_fail
.p1_buf_next:
    INC     HL
    INC     DE
    DJNZ    .p1_buf_loop

    LD      A, (undo_kind)
    CP      UNDO_KIND_TOO_LARGE
    JR      Z, .p1_ok_uk
    LD      A, 0xFC
    LD      B, 2
    JP      test_fail
.p1_ok_uk:
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .p1_ok_up
    LD      A, 0xFC
    LD      B, 3
    JP      test_fail
.p1_ok_up:
    LD      HL, (undo_length)
    LD      A, H
    OR      L
    JR      Z, .p1_ok_ul
    LD      A, 0xFC
    LD      B, 4
    JP      test_fail
.p1_ok_ul:
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .p1_ok_dirty
    LD      A, 0xFC
    LD      B, 5
    JP      test_fail
.p1_ok_dirty:

    ;; --- Phase 2: op_undo ---
    LD      A, 'u'
    CALL    op_undo

    ;; Buffer UNCHANGED ("ab\ncd" — TOO_LARGE replay is no-op)
    LD      HL, 0
    LD      DE, .expect_phase1
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
    LD      A, 0xFC
    LD      B, 6
    JP      test_fail
.p2_buf_next:
    INC     HL
    INC     DE
    DJNZ    .p2_buf_loop

    ;; undo_kind STILL TOO_LARGE (Q4 Option A — not consumed by surfacing)
    LD      A, (undo_kind)
    CP      UNDO_KIND_TOO_LARGE
    JR      Z, .p2_ok_uk
    LD      A, 0xFC
    LD      B, 7
    JP      test_fail
.p2_ok_uk:
    JP      test_pass

.payload:
    DEFB    "AB", 0x0A, "CD"
.expect_phase1:
    DEFB    "ab", 0x0A, "cd"

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
