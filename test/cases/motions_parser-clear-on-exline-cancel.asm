; ============================================================
; Module: test/cases/motions_parser-clear-on-exline-cancel.asm
; Purpose: AC13 hardware UAT step 14 fix — verify
;          exline_cancel_core clears parser state on the
;          :Esc round-trip.
;
;          The path `5 : Esc h` was reaching motion_h with
;          count_accumulator = 5 because exline_cancel_core
;          inlines the mode flip and never calls
;          enter_normal_mode (so the AC13 patch on
;          enter_normal_mode does NOT fire). exline_cancel_core
;          now tail-JPs parser_clear to close the seam.
;
;          Setup: count=5, operator='d', prefix='g'; ex_buffer
;          length set to a non-zero value (simulating partial
;          `:` text); CALL exline_cancel; assert all three
;          parser-state fields zeroed AND ex_buffer length = 0
;          AND mode_byte = MODE_NORMAL AND status_dirty set.
;
; AC reference: AC13 (Story 2.5 hardware UAT step 14 fix iteration).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x81 — count_accumulator not cleared
;   0x82 — pending_operator not cleared
;   0x83 — pending_motion_prefix not cleared
;   0x86 — mode_byte != MODE_NORMAL
;   0x87 — ex_buffer length != 0
;   0x88 — status_dirty not set
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    ;; Pre-state: in COMMAND mode with parser state stale.
    LD      A, MODE_COMMAND
    LD      (mode_byte), A
    LD      A, 0
    LD      (status_dirty), A
    LD      A, 3
    LD      (ex_buffer), A              ; pretend the user typed 3 chars
    LD      HL, 5
    LD      (count_accumulator), HL
    LD      A, 'd'
    LD      (pending_operator), A
    LD      A, 'g'
    LD      (pending_motion_prefix), A

    ;; Drive Esc-to-NORMAL through the COMMAND-mode path.
    LD      A, 0x1B
    CALL    exline_cancel

    ;; --- mode_byte == MODE_NORMAL ---
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0x86
    JP      test_fail
.ok_mode:

    ;; --- ex_buffer length == 0 ---
    LD      A, (ex_buffer)
    OR      A
    JR      Z, .ok_ex
    LD      B, A
    LD      A, 0x87
    JP      test_fail
.ok_ex:

    ;; --- status_dirty set (banner needs to repaint) ---
    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok_dirty
    LD      A, 0x88
    LD      B, 0
    JP      test_fail
.ok_dirty:

    ;; --- count_accumulator cleared ---
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x81
    JP      test_fail
.ok_count:

    ;; --- pending_operator cleared ---
    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok_op
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_op:

    ;; --- pending_motion_prefix cleared ---
    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok_prefix
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_prefix:

    JP      test_pass

    INCLUDE "../inc/test_epilogue.inc"

    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
