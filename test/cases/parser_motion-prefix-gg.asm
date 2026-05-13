; ============================================================
; Module: test/cases/parser_motion-prefix-gg.asm
; Purpose: AC7, AC8 — verify parser_handle_motion_prefix:
;            - First 'g' (no prior prefix) sets
;              pending_motion_prefix = 'g'. count_accumulator
;              and pending_operator unchanged. No stub fires.
;            - Second 'g' (pending_motion_prefix already 'g')
;              dispatches parser_gg_motion_stub, which tail-JPs
;              to parser_clear: all three parser-state fields
;              are 0 afterward, status_dirty is set.
;            - Count carries across the prefix: '5g' leaves
;              count_accumulator = 5 AND pending_motion_prefix
;              = 'g'; the subsequent 'g' (doubled) fires the
;              stub + parser_clear and count goes back to 0.
;
; AC reference: AC7, AC8, AC12 (story 1.10).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — first 'g' did not set pending_motion_prefix = 'g'
;   0xE2 — first 'g' set status_dirty (it must NOT — no stub)
;   0xE3 — first 'g' modified count_accumulator
;   0xE4 — second 'g' did not set status_dirty (stub did not fire)
;   0xE5 — second 'g' left pending_motion_prefix nonzero
;   0xE6 — second 'g' left count_accumulator nonzero
;   0xE7 — second 'g' left pending_operator nonzero
;   0xE8 — Subtest 3: after '5' '5g' sequence, count != 5
;          (the prefix-press must not clobber count)
;   0xE9 — Subtest 3: after the final 'g', count != 0 (parser_clear
;          on doubled-prefix did not run)
;   B    — diagnostic byte
; ============================================================

;; --- Pre-ORG production headers (pure EQU; safe before ORG) ---
    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----

    ;; Pre-zero parser state and status_dirty.
    LD      HL, 0
    LD      (count_accumulator), HL
    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (status_dirty), A

    ;; Subtest 1: first 'g' sets pending_motion_prefix.
    LD      A, 'g'
    CALL    parser_handle_motion_prefix

    LD      A, (pending_motion_prefix)
    CP      'g'
    JR      Z, .ok1a
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok1a:
    LD      A, (status_dirty)
    OR      A
    JR      Z, .ok1b
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok1b:
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok1c
    LD      B, L
    LD      A, 0xE3
    JP      test_fail
.ok1c:

    ;; Subtest 2: second 'g' fires gg-motion stub.
    ;; (pending_motion_prefix already 'g' from Subtest 1.)
    LD      A, 'g'
    CALL    parser_handle_motion_prefix

    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok2a
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok2a:
    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok2b
    LD      B, A
    LD      A, 0xE5
    JP      test_fail
.ok2b:
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok2c
    LD      B, L
    LD      A, 0xE6
    JP      test_fail
.ok2c:
    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok2d
    LD      B, A
    LD      A, 0xE7
    JP      test_fail
.ok2d:

    ;; Subtest 3: count survives across 'g' but is cleared by
    ;; the doubled-prefix dispatch.
    LD      HL, 0
    LD      (count_accumulator), HL
    XOR     A
    LD      (pending_motion_prefix), A
    LD      (status_dirty), A

    LD      A, '5'
    CALL    parser_handle_digit         ; count_accumulator = 5
    LD      A, 'g'
    CALL    parser_handle_motion_prefix ; pending_motion_prefix = 'g'

    ;; Count must still be 5 here (prefix-press must not clobber count).
    LD      HL, (count_accumulator)
    LD      A, H
    OR      A
    JR      NZ, .fail3_mid
    LD      A, L
    CP      5
    JR      Z, .ok3_mid
.fail3_mid:
    LD      B, L
    LD      A, 0xE8
    JP      test_fail
.ok3_mid:

    LD      A, 'g'
    CALL    parser_handle_motion_prefix ; doubled-g → stub + parser_clear

    ;; Count must be 0 again post-dispatch.
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok3_end
    LD      B, L
    LD      A, 0xE9
    JP      test_fail
.ok3_end:

    JP      test_pass

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"

;; ----- input_loop stub (resolves bdos_error_funnel symbol) -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST (positional anchor: static_data_base = $) -----
    INCLUDE "../../inc/state.inc"
