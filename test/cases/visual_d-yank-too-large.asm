; ============================================================
; Module: test/cases/visual_d-yank-too-large.asm
; Purpose: Story 3.6 AC7 — verify the SR6 "predictable failure
;          mode" for visual_apply_operator d: when the selection
;          exceeds YANK_BUFFER_SIZE (1024 B), the prior yank
;          register is PRESERVED (yank_kind / yank_length /
;          yank_buffer all unchanged) AND the deletion STILL
;          PROCEEDS (buffer mutated, mode transitions to NORMAL).
;          Status surfaces msg_yank_too_large.
;
;          Buffer of 1025 'A' bytes; cursor=0; pre-set
;          mode_byte = MODE_VISUAL, visual_submode = VIS_CHAR,
;          visual_anchor = 0, cursor_offset = 1024. Range =
;          [0, 1025) = 1025 bytes (exceeds YANK_BUFFER_SIZE=1024).
;          Pre-seed yank_kind=KIND_LINE, yank_length=5,
;          yank_buffer[0..4]="PREV1" — sentinel for register
;          preservation. CALL visual_apply_operator with A='d'.
;
; Sentinel 0xD4 — context byte:
;   0  — mode_byte != MODE_NORMAL
;   1  — yank_kind != KIND_LINE (must be preserved)
;   2  — yank_length != 5
;   3  — yank_buffer[0..4] != "PREV1"
;   4  — status_buffer[0..13] != "yank too large"
;   5  — file_length != 0 (deletion must still proceed per SR6)
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

    ;; Pre-seed yank register with sentinel
    LD      A, KIND_LINE
    LD      (yank_kind), A
    LD      HL, 5
    LD      (yank_length), HL
    LD      HL, .prev_yank
    LD      DE, yank_buffer
    LD      BC, 5
    LDIR

    ;; Populate 1025 'A' bytes via fill loop.
    CALL    gapbuf_init
    LD      HL, GAP_BUFFER_BASE
    LD      BC, 1025
    LD      A, 'A'
.fill_loop:
    LD      (HL), A
    INC     HL
    DEC     BC
    PUSH    AF
    LD      A, B
    OR      C
    JR      Z, .fill_done
    POP     AF
    JR      .fill_loop
.fill_done:
    POP     AF
    LD      HL, GAP_BUFFER_BASE + 1025
    LD      (gap_start), HL

    LD      HL, 1024
    LD      (cursor_offset), HL
    LD      HL, 0
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A

    ;; --- Execute ---
    LD      A, 'd'
    CALL    visual_apply_operator

    ;; --- Assertions ---
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xD4
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      A, (yank_kind)
    CP      KIND_LINE
    JR      Z, .ok_yk
    LD      A, 0xD4
    LD      B, 1
    JP      test_fail
.ok_yk:
    LD      HL, (yank_length)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    JR      Z, .ok_yl
    LD      A, 0xD4
    LD      B, 2
    JP      test_fail
.ok_yl:
    LD      HL, yank_buffer
    LD      DE, .prev_yank
    LD      B, 5
.ycmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 0xD4
    LD      B, 3
    JP      test_fail
.ycmp_next:
    INC     HL
    INC     DE
    DJNZ    .ycmp

    ;; status_buffer starts with "yank too large"
    LD      HL, status_buffer
    LD      DE, .msg_yank
    LD      B, 14
.scmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .scmp_next
    LD      A, 0xD4
    LD      B, 4
    JP      test_fail
.scmp_next:
    INC     HL
    INC     DE
    DJNZ    .scmp

    ;; SR6 deletion-still-proceeds check: post-call buffer must be
    ;; empty (all 1025 bytes deleted despite yank-refusal).
    LD      HL, 0
    CALL    motion_byte_at_logical
    JR      C, .ok_empty                    ; CF=1 → offset 0 past EOF → empty
    LD      A, 0xD4
    LD      B, 5
    JP      test_fail
.ok_empty:
    JP      test_pass

.prev_yank:
    DEFB    "PREV1"
.msg_yank:
    DEFB    "yank too large"

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
