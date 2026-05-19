; ============================================================
; Module: test/cases/visual_block_toggle-top-ls-at-file-length.asm
; Purpose: Story 4.1 AC5 T6 — AC1 regression-pin via VIS_BLOCK on
;          empty buffer. Pre-fix, finding 2 said top_ls >= file_length
;          could pass past-EOF offsets to gapbuf_case_toggle_range;
;          the only realistic trigger is file_length=0. Post-AC1
;          the file_length=0 guard at primitive entry returns Z=1
;          no-op, leaving the buffer empty and the yank_buffer head
;          UNTOUCHED.
;
;          Test: buffer empty (gapbuf_init only), mode=VISUAL,
;          submode=VIS_BLOCK, visual_anchor=0, cursor=0. Pre-set
;          yank_buffer[0] = 'A' (alphabetic sentinel — pre-AC1 the
;          XOR-toggle would have flipped it to 'a'). CALL
;          visual_apply_case_toggle A='~'. Assert: mode=NORMAL,
;          buffer empty (file_length=0), yank_buffer[0] still 'A'
;          (no pollution).
;
; Sentinel 0x8E — context byte:
;   0 — mode_byte != MODE_NORMAL
;   1 — gap_start != GAP_BUFFER_BASE (buffer mutated)
;   2 — gap_end != GAP_BUFFER_BASE + GAP_BUFFER_MAX (buffer mutated)
;   3 — yank_buffer[0] != 'A' (POLLUTION — pre-AC1 bug regression)
;   4 — cursor_offset != 0
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

    ;; Empty buffer.
    CALL    gapbuf_init

    ;; Pre-pollute yank_buffer[0] with alphabetic sentinel 'A'.
    ;; Pre-AC1, a BC>0 walk on empty buffer would land at gap_end
    ;; (= yank_buffer[0]) and XOR-toggle 'A' to 'a'. Post-AC1, the
    ;; file_length=0 guard short-circuits before the walk.
    LD      A, 'A'
    LD      (yank_buffer), A

    LD      HL, 0
    LD      (cursor_offset), HL
    LD      HL, 0
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_BLOCK
    LD      (visual_submode), A

    LD      A, '~'
    CALL    visual_apply_case_toggle

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0x8E
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_gs
    LD      A, 0x8E
    LD      B, 1
    JP      test_fail
.ok_gs:
    LD      HL, (gap_end)
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_ge
    LD      A, 0x8E
    LD      B, 2
    JP      test_fail
.ok_ge:
    LD      A, (yank_buffer)
    CP      'A'
    JR      Z, .ok_yank
    LD      A, 0x8E
    LD      B, 3
    JP      test_fail
.ok_yank:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0x8E
    LD      B, 4
    JP      test_fail
.ok_cursor:
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
