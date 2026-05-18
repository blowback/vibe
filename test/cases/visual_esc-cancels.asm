; ============================================================
; Module: test/cases/visual_esc-cancels.asm
; Purpose: Story 3.3 AC8 / AC10 — verify Esc from VISUAL via the
;          existing enter_normal_mode (dispatch_visual['Esc']
;          entry — UNCHANGED from Story 1.9) returns to NORMAL
;          while leaving cursor_offset AT THE EXTENT (no rewind
;          to anchor — vi-faithful) and visual_anchor untouched
;          in state (zombie until the next visual entry).
;
;          Buffer "abcdef". Pre-seed mode_byte = MODE_VISUAL,
;          visual_submode = VIS_CHAR, visual_anchor = 1,
;          cursor_offset = 3. CALL enter_normal_mode.
;
; Sentinel 0xB2 — context byte:
;   0 — mode_byte != MODE_NORMAL post-call
;   1 — cursor_offset != 3 (cursor must stay at the extent)
;   2 — visual_anchor != 1 (must not be cleared; AC8 zombie state)
;   3 — status_buffer[0] != ' ' (msg_mode_normal is empty; the
;       pad path should leave space as the first byte)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    ;; Pre-zero parser; intentionally leave count_accumulator zero
    ;; so we can verify parser_clear ran via tail-JP (post-call
    ;; check is implicit — we're testing AC8 not AC13 here).
    XOR     A
    LD      (status_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A

    ;; Populate buffer.
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 6
    LDIR
    LD      HL, GAP_BUFFER_BASE + 6
    LD      (gap_start), HL

    ;; Pre-seed VISUAL session mid-extent.
    LD      HL, 3
    LD      (cursor_offset), HL
    LD      HL, 1
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A

    ;; Drive Esc → enter_normal_mode (the dispatch_visual['Esc'] target).
    LD      A, 0x1B
    CALL    enter_normal_mode

    ;; Check 1: mode_byte == MODE_NORMAL.
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xB2
    LD      B, 0
    JP      test_fail

.ok_mode:
    ;; Check 2: cursor_offset still 3 (AC8: cursor stays at extent).
    LD      HL, (cursor_offset)
    LD      DE, 3
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor
    LD      A, 0xB2
    LD      B, 1
    JP      test_fail

.ok_cursor:
    ;; Check 3: visual_anchor still 1 (AC8: zombie state).
    LD      HL, (visual_anchor)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    JR      Z, .ok_anchor
    LD      A, 0xB2
    LD      B, 2
    JP      test_fail

.ok_anchor:
    ;; Check 4: status_buffer[0] == ' ' (msg_mode_normal is the
    ;; empty string; status_set_message pads to space).
    LD      A, (status_buffer)
    CP      ' '
    JR      Z, .ok_status
    LD      A, 0xB2
    LD      B, 3
    JP      test_fail

.ok_status:
    JP      test_pass

.payload:
    DEFB    "abcdef"

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
