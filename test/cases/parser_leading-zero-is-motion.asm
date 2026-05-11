; ============================================================
; Module: test/cases/parser_leading-zero-is-motion.asm
; Purpose: AC3 — verify parser_handle_digit, when invoked with
;          A = '0' AND count_accumulator == 0, does NOT
;          accumulate but instead transfers control to
;          parser_motion_zero_stub (the Epic 1 placeholder for
;          the line-start motion-0 — FR21). Observable side
;          effect: status_dirty becomes nonzero (the stub's
;          status_set_message call). count_accumulator stays 0.
;
; AC reference: AC3, AC12 (story 1.10).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — first '0' left count_accumulator != 0 (it must stay 0
;          — the stub does not modify count)
;   0xE2 — first '0' did not set status_dirty (stub did not fire)
;   0xE3 — second '0' (with state reset between) left
;          count_accumulator != 0
;   0xE4 — second '0' did not set status_dirty (stub did not fire
;          on the repeat call)
;   B    — diagnostic byte at point of failure
; ============================================================

;; --- Pre-ORG production headers (pure EQU; safe before ORG) ---
    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----

    ;; Pre-zero all parser state and status_dirty.
    LD      HL, 0
    LD      (count_accumulator), HL
    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (status_dirty), A

    ;; Subtest 1: leading '0' fires motion-zero stub.
    LD      A, '0'
    CALL    parser_handle_digit

    ;; (a) count_accumulator must still be 0.
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok1_count
    LD      B, L
    LD      A, 0xE1
    JP      test_fail
.ok1_count:

    ;; (b) status_dirty must be nonzero (stub called status_set_message).
    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok1_dirty
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok1_dirty:

    ;; Subtest 2: second '0' (state reset between) ALSO fires stub.
    LD      HL, 0
    LD      (count_accumulator), HL
    XOR     A
    LD      (status_dirty), A
    LD      A, '0'
    CALL    parser_handle_digit

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok2_count
    LD      B, L
    LD      A, 0xE3
    JP      test_fail
.ok2_count:

    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok2_dirty
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok2_dirty:

    JP      test_pass

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"

;; ----- input_loop stub (resolves bdos_error_funnel symbol) -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST (positional anchor: static_data_base = $) -----
    INCLUDE "../../inc/state.inc"
