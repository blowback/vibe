; ============================================================
; Module: test/cases/visual_shift-empty-buffer.asm
; Purpose: Story 3.7 — pin vim-compatible behavior of `>` and `<`
;          on an EMPTY buffer (file_length == 0). Resolved by Ant
;          2026-05-18 during code-review triage: accept current
;          behavior (matches vim's "shift on empty file adds one
;          indent"); do NOT guard with a file_length==0 early-out.
;
;          The behavior falls out of the unconditional INC HL on
;          promoted_end (visual.asm line ~299). With anchor=cursor=0
;          and motion_find_line_end(0) returning HL=0 / CF=1 on
;          past-EOF, INC HL yields promoted_end = 1; edits_indent_walk
;          enters its first iteration (HL=0 < DE=1).
;
;          Phase 1 (`>` on empty buffer):
;            Walk inserts INDENT_BYTE at offset 0 → file_length 0→1.
;            Buffer becomes " " (1 B). buffer_dirty=1. Undo records
;            UNDO_KIND_INDENT_WALK pos=0 len=2 (walk_end = 2 per
;            edits_indent_walk post-insert advance).
;
;          Phase 2 (`<` on empty buffer):
;            Walk enters but motion_byte_at_logical(0) returns CF=1
;            (past-EOF) → edits_indent_walk's .iw_dedent guard
;            (CP INDENT_BYTE on undefined A after CF=1) does NOT
;            match — silent no-op. dirty stays 0. Q3 Option A undo
;            pre-clear leaves undo_kind = UNDO_KIND_EMPTY.
;
; Sentinel 0xDE — context byte:
;   Phase 1 (`>` arm):
;     0 — mode_byte != MODE_NORMAL
;     1 — cursor_offset != 0
;     2 — gap_start != GAP_BUFFER_BASE + 1 (file_length != 1)
;     3 — buffer[0] != INDENT_BYTE
;     4 — buffer_dirty != 1
;     5 — undo_kind != UNDO_KIND_INDENT_WALK
;     6 — undo_position != 0
;     7 — undo_length != 2
;   Phase 2 (`<` arm):
;     8 — mode_byte != MODE_NORMAL (phase 2)
;     9 — cursor_offset != 0 (phase 2)
;    10 — gap_start != GAP_BUFFER_BASE (file_length != 0; phase 2
;         mutated buffer when it should have been a silent no-op)
;    11 — buffer_dirty != 0 (phase 2 wrote dirty flag)
;    12 — undo_kind != UNDO_KIND_EMPTY (phase 2 should leave undo
;         in EMPTY state per Q3 Option A pre-walk undo_clear)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    ;; --- Phase 1: `>` on empty buffer ---
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

    ;; Empty buffer — gapbuf_init alone leaves file_length = 0
    ;; (gap_start = GAP_BUFFER_BASE, gap_end = GAP_BUFFER_BASE +
    ;; GAP_BUFFER_MAX). No LDIR.
    CALL    gapbuf_init

    LD      HL, 0
    LD      (cursor_offset), HL
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_LINE
    LD      (visual_submode), A

    LD      A, '>'
    CALL    visual_apply_shift

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode1
    LD      A, 0xDE
    LD      B, 0
    JP      test_fail
.ok_mode1:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor1
    LD      A, 0xDE
    LD      B, 1
    JP      test_fail
.ok_cursor1:
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE + 1
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_gap1
    LD      A, 0xDE
    LD      B, 2
    JP      test_fail
.ok_gap1:
    LD      HL, 0
    CALL    motion_byte_at_logical
    CP      INDENT_BYTE
    JR      Z, .ok_byte1
    LD      A, 0xDE
    LD      B, 3
    JP      test_fail
.ok_byte1:
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty1
    LD      A, 0xDE
    LD      B, 4
    JP      test_fail
.ok_dirty1:
    LD      A, (undo_kind)
    CP      UNDO_KIND_INDENT_WALK
    JR      Z, .ok_uk1
    LD      A, 0xDE
    LD      B, 5
    JP      test_fail
.ok_uk1:
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_up1
    LD      A, 0xDE
    LD      B, 6
    JP      test_fail
.ok_up1:
    LD      HL, (undo_length)
    LD      DE, 2
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_ul1
    LD      A, 0xDE
    LD      B, 7
    JP      test_fail
.ok_ul1:
    ;; --- Phase 2: `<` on empty buffer ---
    ;; Re-init: empty the gap buffer (gapbuf_init also resets the
    ;; gap pointers) so phase-1 INDENT_BYTE is wiped. Re-seed all
    ;; mode/visual/undo state.
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

    LD      HL, 0
    LD      (cursor_offset), HL
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_LINE
    LD      (visual_submode), A

    LD      A, '<'
    CALL    visual_apply_shift

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode2
    LD      A, 0xDE
    LD      B, 8
    JP      test_fail
.ok_mode2:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor2
    LD      A, 0xDE
    LD      B, 9
    JP      test_fail
.ok_cursor2:
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_gap2
    LD      A, 0xDE
    LD      B, 10
    JP      test_fail
.ok_gap2:
    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty2
    LD      A, 0xDE
    LD      B, 11
    JP      test_fail
.ok_dirty2:
    LD      A, (undo_kind)
    CP      UNDO_KIND_EMPTY
    JR      Z, .ok_uk2
    LD      A, 0xDE
    LD      B, 12
    JP      test_fail
.ok_uk2:
    JP      test_pass

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
