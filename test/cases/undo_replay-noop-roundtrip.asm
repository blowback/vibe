; ============================================================
; Module: test/cases/undo_replay-noop-roundtrip.asm
; Purpose: Story 4.1 AC5 T8 — Q3 Option A "preserve prior undo on
;          no-op walk" round-trip via op_undo. Set up a prior
;          UNDO_KIND_INSERT entry (position=5, length=3) describing
;          an earlier insertion. Buffer "12345XYZ" (8 B) — the
;          "XYZ" at offsets 5..7 represents the bytes the prior
;          insert added. Then drive visual_apply_case_toggle CHAR
;          over the digit-only prefix "12345" (anchor=0, cursor=4)
;          — no alpha bytes → gapbuf_case_toggle_range returns Z=1
;          → finalise's .restore_cursor path PRESERVES the prior
;          undo (Q3 Option A from Story 3.8).
;
;          Then CALL op_undo: replays UNDO_KIND_INSERT by deleting
;          3 bytes at offset 5..7. Buffer becomes "12345" (5 B).
;          undo_kind → UNDO_KIND_EMPTY.
;
;          Pins: case-toggle no-op did NOT clobber the prior undo,
;          AND the prior undo still replays correctly post-no-op.
;
; Sentinel 0x98 — context byte:
;   Phase 1 (post-toggle):
;     0 — undo_kind != UNDO_KIND_INSERT (Q3 Option A clobber bug)
;     1 — undo_position != 5
;     2 — undo_length != 3
;     3 — buffer first 8 B != "12345XYZ" (toggle should NOT mutate)
;   Phase 2 (post-undo):
;     4 — undo_kind != UNDO_KIND_EMPTY (replay should consume)
;     5 — buffer first 5 B != "12345" (replay should remove XYZ)
;     6 — file_length != 5 (gap_start + GAP_BUFFER_MAX - gap_end)
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
    LD      (yank_kind), A
    LD      (buffer_dirty), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 8
    LDIR
    LD      HL, GAP_BUFFER_BASE + 8
    LD      (gap_start), HL

    LD      HL, 4
    LD      (cursor_offset), HL
    LD      HL, 0
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A

    ;; Pre-set prior UNDO_KIND_INSERT entry: position=5, length=3.
    LD      A, UNDO_KIND_INSERT
    LD      (undo_kind), A
    LD      HL, 5
    LD      (undo_position), HL
    LD      HL, 3
    LD      (undo_length), HL

    ;; --- Phase 1: case-toggle over digit-only "12345" prefix ---
    LD      A, '~'
    CALL    visual_apply_case_toggle

    LD      A, (undo_kind)
    CP      UNDO_KIND_INSERT
    JR      Z, .p1_ok_uk
    LD      A, 0x98
    LD      B, 0
    JP      test_fail
.p1_ok_uk:
    LD      HL, (undo_position)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .p1_ok_up
    LD      A, 0x98
    LD      B, 1
    JP      test_fail
.p1_ok_up:
    LD      HL, (undo_length)
    LD      DE, 3
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .p1_ok_ul
    LD      A, 0x98
    LD      B, 2
    JP      test_fail
.p1_ok_ul:
    LD      HL, 0
    LD      DE, .payload
    LD      B, 8
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
    LD      A, 0x98
    LD      B, 3
    JP      test_fail
.p1_buf_next:
    INC     HL
    INC     DE
    DJNZ    .p1_buf_loop

    ;; --- Phase 2: op_undo replays the prior INSERT ---
    LD      A, 'u'
    CALL    op_undo

    LD      A, (undo_kind)
    CP      UNDO_KIND_EMPTY
    JR      Z, .p2_ok_uk
    LD      A, 0x98
    LD      B, 4
    JP      test_fail
.p2_ok_uk:
    LD      HL, 0
    LD      DE, .expect_after_undo
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
    LD      A, 0x98
    LD      B, 5
    JP      test_fail
.p2_buf_next:
    INC     HL
    INC     DE
    DJNZ    .p2_buf_loop

    ;; file_length now 5 (gap_start + GAP_BUFFER_MAX - gap_end).
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_MAX
    ADD     HL, DE
    LD      DE, (gap_end)
    OR      A
    SBC     HL, DE
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .p2_ok_flen
    LD      A, 0x98
    LD      B, 6
    JP      test_fail
.p2_ok_flen:
    JP      test_pass

.payload:
    DEFB    "12345XYZ"
.expect_after_undo:
    DEFB    "12345"

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
