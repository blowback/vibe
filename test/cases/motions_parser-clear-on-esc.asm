; ============================================================
; Module: test/cases/motions_parser-clear-on-esc.asm
; Purpose: AC13 — verify enter_normal_mode clears the three
;          parser-state fields (count_accumulator,
;          pending_operator, pending_motion_prefix). Resolves
;          the deferred-work line 87-90 concern that Esc-to-NORMAL
;          leaves stale parser state.
;
;          Pre-set count=5, operator='d', prefix='g'; CALL
;          enter_normal_mode; assert all three zeroed; assert
;          mode_byte became MODE_NORMAL.
;
; AC reference: AC13 (Story 2.5 Sub 7.15).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x81 — count_accumulator not cleared
;   0x82 — pending_operator not cleared
;   0x83 — pending_motion_prefix not cleared
;   0x86 — mode_byte != MODE_NORMAL post-call
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    ;; Pre-state: in INSERT, with stale parser state.
    LD      A, MODE_INSERT
    LD      (mode_byte), A
    LD      A, 0
    LD      (status_dirty), A
    LD      HL, 5
    LD      (count_accumulator), HL
    LD      A, 'd'
    LD      (pending_operator), A
    LD      A, 'g'
    LD      (pending_motion_prefix), A

    ;; Drive Esc-to-NORMAL.
    LD      A, 0x1B
    CALL    enter_normal_mode

    ;; --- mode_byte == MODE_NORMAL ---
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0x86
    JP      test_fail
.ok_mode:

    ;; --- count_accumulator == 0 ---
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x81
    JP      test_fail
.ok_count:

    ;; --- pending_operator == 0 ---
    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok_op
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_op:

    ;; --- pending_motion_prefix == 0 ---
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
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
