; ============================================================
; Module: test/cases/visual_tilde-no-alpha.asm
; Purpose: Story 3.8 AC3 / AC6 no-op walk (selection with no
;          alphabetic bytes) — Q3 Option A pin: PRESERVE prior
;          undo register on no-op walks. Buffer "12345\n67890"
;          (11 B; LF at 5). Pre-set mode=VISUAL, submode=VIS_CHAR,
;          visual_anchor=0, cursor=10. Pre-seed undo_kind=
;          UNDO_KIND_INSERT, undo_position=0x1234, undo_length=5
;          (hypothetical prior undo entry from an earlier insert).
;          CALL visual_apply_case_toggle with A='~'.
;
;          gapbuf_case_toggle_range walks the bytes but does
;          nothing (alpha test rejects all digits + LF); returns
;          Z=1 (no-op walk). CHAR finalise's no-op path leaves
;          undo at PRIOR STATE per Q3 Option A; cursor at
;          range_start; tail-JP enter_normal_mode.
;
;          Distinct from Story 2.11 / 3.7 indent/dedent precedent
;          which PRE-clears via undo_clear before the walk.
;
; Sentinel 0xFA — context byte:
;   0 — mode_byte != MODE_NORMAL
;   1 — cursor_offset != 0 (range_start)
;   2 — buffer first 11 B != "12345\n67890" (UNCHANGED)
;   3 — undo_kind != UNDO_KIND_INSERT (Q3 Option A — must PRESERVE)
;   4 — undo_position != 0x1234 (UNCHANGED)
;   5 — undo_length != 5 (UNCHANGED)
;   6 — buffer_dirty != 0 (UNCHANGED from pre-seed; no toggle = no dirty)
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
    LD      (buffer_dirty), A             ; pre-seed buffer_dirty = 0

    ;; Pre-seed prior undo entry — must survive the no-op walk
    ;; (Q3 Option A pin from Task 0).
    LD      A, UNDO_KIND_INSERT
    LD      (undo_kind), A
    LD      HL, 0x1234
    LD      (undo_position), HL
    LD      HL, 5
    LD      (undo_length), HL

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

    LD      A, '~'
    CALL    visual_apply_case_toggle

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xFA
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0xFA
    LD      B, 1
    JP      test_fail
.ok_cursor:
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
    LD      A, 0xFA
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (undo_kind)
    CP      UNDO_KIND_INSERT
    JR      Z, .ok_uk
    LD      A, 0xFA
    LD      B, 3
    JP      test_fail
.ok_uk:
    LD      HL, (undo_position)
    LD      DE, 0x1234
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_up
    LD      A, 0xFA
    LD      B, 4
    JP      test_fail
.ok_up:
    LD      HL, (undo_length)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_ul
    LD      A, 0xFA
    LD      B, 5
    JP      test_fail
.ok_ul:
    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      A, 0xFA
    LD      B, 6
    JP      test_fail
.ok_dirty:
    JP      test_pass

.payload:
    DEFB    "12345", 0x0A, "67890"
.expect_buf:
    DEFB    "12345", 0x0A, "67890"

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
