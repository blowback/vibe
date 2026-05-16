; ============================================================
; Module: test/cases/parser_doubled-operator-dd.asm
; Purpose: AC5, AC6 — verify parser_handle_operator:
;            - First operator (no prior pending) stores in
;              pending_operator and preserves count_accumulator.
;              No stub fires (status_dirty stays 0).
;            - Doubled operator (same operator twice in a row)
;              dispatches parser_doubled_operator_stub, which
;              tail-JPs to parser_clear: count_accumulator,
;              pending_operator, pending_motion_prefix all 0
;              and status_dirty set by the stub.
;            - Different operators ('d' then 'y') are not
;              doubled: last-operator-wins, no stub fires.
;
; AC reference: AC5, AC6, AC12 (story 1.10).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — first 'd' did not set pending_operator = 'd'
;   0xE2 — first 'd' modified count_accumulator (must stay 0)
;   0xE3 — first 'd' set status_dirty (it must NOT — no stub)
;   0xE4 — second 'd' did not set status_dirty (stub did not fire)
;   0xE5 — second 'd' left pending_operator nonzero
;   0xE6 — second 'd' left count_accumulator nonzero
;   0xE7 — second 'd' left pending_motion_prefix nonzero
;   0xE8 — 'yy' did not zero pending_operator (yy variant of AC6)
;   0xE9 — 'd' then 'y' did not leave pending_operator = 'y'
;          (last-operator-wins; doubled-detection saw d != y)
;   0xEA — 'd' then 'y' set status_dirty (it must NOT)
;   0xEB — 'yy' did not set status_dirty (stub did not actually fire)
;   0xEC — 'yy' left pending_motion_prefix nonzero (parser_clear
;          did not run after the stub)
;   0xED — 'dyy' did not fire yy stub (last-operator-wins: 'd' then
;          'y' stores y; second 'y' must match and fire stub)
;   0xEE — 'dyy' left pending_operator nonzero (parser_clear must
;          have run after the yy stub)
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

    ;; Subtest 1: first 'd' sets pending_operator.
    LD      A, 'd'
    CALL    parser_handle_operator

    LD      A, (pending_operator)
    CP      'd'
    JR      Z, .ok1a
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok1a:
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok1b
    LD      B, L
    LD      A, 0xE2
    JP      test_fail
.ok1b:
    LD      A, (status_dirty)
    OR      A
    JR      Z, .ok1c
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok1c:

    ;; Subtest 2: second 'd' fires doubled-operator stub.
    ;; (pending_operator is already 'd' from Subtest 1.)
    LD      A, 'd'
    CALL    parser_handle_operator

    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok2a
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok2a:
    LD      A, (pending_operator)
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
    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok2d
    LD      B, A
    LD      A, 0xE7
    JP      test_fail
.ok2d:

    ;; Subtest 3: 'yy' variant — second 'y' fires stub + clear.
    ;; Verify three post-conditions: pending_operator cleared,
    ;; status_dirty set (stub fired), pending_motion_prefix cleared
    ;; (parser_clear ran completely, not just on pending_operator).
    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (status_dirty), A
    LD      A, 'y'
    CALL    parser_handle_operator
    LD      A, 'y'
    CALL    parser_handle_operator
    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok3a
    LD      B, A
    LD      A, 0xE8
    JP      test_fail
.ok3a:
    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok3b
    LD      B, A
    LD      A, 0xEB
    JP      test_fail
.ok3b:
    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok3c
    LD      B, A
    LD      A, 0xEC
    JP      test_fail
.ok3c:

    ;; Subtest 4: 'd' then 'y' is NOT doubled (last-operator-wins).
    XOR     A
    LD      (pending_operator), A
    LD      (status_dirty), A
    LD      A, 'd'
    CALL    parser_handle_operator
    LD      A, 'y'
    CALL    parser_handle_operator
    LD      A, (pending_operator)
    CP      'y'
    JR      Z, .ok4a
    LD      B, A
    LD      A, 0xE9
    JP      test_fail
.ok4a:
    LD      A, (status_dirty)
    OR      A
    JR      Z, .ok4b
    LD      B, A
    LD      A, 0xEA
    JP      test_fail
.ok4b:

    ;; Subtest 5: 'dyy' — last-operator-wins makes 'd' then 'y'
    ;; store 'y' (Subtest 4 already verified that); the second 'y'
    ;; then matches pending_operator='y' and fires the yy stub.
    ;; This locks in the documented "stale-pending-operator → last-
    ;; operator-wins → doubled triggers on the LATEST operator"
    ;; sharp edge. A regression that made first-operator-sticks
    ;; would leave pending_operator='d' and the second 'y' would
    ;; mismatch (storing 'y' on the first-operator path), so
    ;; status_dirty would stay 0.
    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (status_dirty), A
    LD      A, 'd'
    CALL    parser_handle_operator
    LD      A, 'y'
    CALL    parser_handle_operator
    LD      A, 'y'
    CALL    parser_handle_operator
    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok5a
    LD      B, A
    LD      A, 0xED
    JP      test_fail
.ok5a:
    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok5b
    LD      B, A
    LD      A, 0xEE
    JP      test_fail
.ok5b:

    JP      test_pass

;; ----- LOCAL init_teardown stub (Story 2.3) -----
    INCLUDE "../inc/test_teardown_stub.inc"
;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"     ; Story 2.5: dispatch_normal forward-references motion_h/j/k/l
    INCLUDE "../../src/edits.asm"     ; Story 2.8: dispatch_normal forward-references edits_*, dispatch_insert table grows, unbound_insert tail-JPs edits_insert_literal
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

;; ----- input_loop stub (resolves bdos_error_funnel symbol) -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST (positional anchor: static_data_base = $) -----
    INCLUDE "../../inc/state.inc"
