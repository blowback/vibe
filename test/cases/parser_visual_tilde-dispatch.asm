; ============================================================
; Module: test/cases/parser_visual_tilde-dispatch.asm
; Purpose: Story 3.8 AC1 end-to-end dispatch wiring. Drive '~'
;          (0x7E) through dispatch_key with dispatch_visual as
;          the base; verify the entry appended at the table tail
;          routes end-to-end through visual_apply_case_toggle and
;          produces the correct VIS_CHAR `~` outcome. Confirms:
;          dispatch_visual['~'] is wired AND the AC1 sorted
;          append landed at the right position (binary-search
;          finds '~' after 'y'). Cross-pins per
;          [[feedback_create_story_cross_check]] —
;          DISPATCH_VISUAL_COUNT must auto-recompute 25→26 (0x19→0x1A).
;
;          Buffer "Abc" (3 B; no LF). Pre-set mode=VISUAL,
;          submode=VIS_CHAR, visual_anchor=0, cursor=2. DRIVE:
;            LD A, '~'
;            LD HL, dispatch_visual
;            LD B, DISPATCH_VISUAL_COUNT
;            CALL dispatch_key
;
;          Expected: 'A'→'a'; 'b'→'B'; 'c'→'C'.
;            mode_byte = MODE_NORMAL
;            cursor_offset = 0
;            buffer first 3 B = "aBC"
;            undo_kind = UNDO_KIND_CASE_TOGGLE
;            undo_position = 0
;            undo_length = 3
;
; Sentinel 0xFD — context byte:
;   0 — mode_byte != MODE_NORMAL
;   1 — cursor_offset != 0
;   2 — buffer first 3 B != "aBC"
;   3 — undo_kind != UNDO_KIND_CASE_TOGGLE
;   4 — undo_position != 0
;   5 — undo_length != 3
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
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 2
    LD      (cursor_offset), HL
    LD      HL, 0
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A

    ;; --- Execute via dispatch_key ---
    LD      A, '~'
    LD      HL, dispatch_visual
    LD      B, DISPATCH_VISUAL_COUNT
    CALL    dispatch_key

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xFD
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0xFD
    LD      B, 1
    JP      test_fail
.ok_cursor:
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
    LD      A, 0xFD
    LD      B, 2
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (undo_kind)
    CP      UNDO_KIND_CASE_TOGGLE
    JR      Z, .ok_uk
    LD      A, 0xFD
    LD      B, 3
    JP      test_fail
.ok_uk:
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_up
    LD      A, 0xFD
    LD      B, 4
    JP      test_fail
.ok_up:
    LD      HL, (undo_length)
    LD      DE, 3
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_ul
    LD      A, 0xFD
    LD      B, 5
    JP      test_fail
.ok_ul:
    JP      test_pass

.payload:
    DEFB    "Abc"
.expect_buf:
    DEFB    "aBC"

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
