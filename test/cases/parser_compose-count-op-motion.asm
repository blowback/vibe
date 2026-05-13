; ============================================================
; Module: test/cases/parser_compose-count-op-motion.asm
; Purpose: AC5, AC9, AC10 — verify the count + operator +
;          motion compose path through parser_dispatch:
;            - Stub motion handler is invoked with the full
;              parser state visible (count_accumulator,
;              pending_operator readable via state.inc symbols).
;            - After the motion returns, parser_clear has run:
;              count_accumulator / pending_operator /
;              pending_motion_prefix all = 0.
;          Two scenarios exercised:
;            Subtest 1: '5d' then dispatch — stub observes
;                       count=5, pending_operator='d'.
;            Subtest 2: bare dispatch (no count, no operator) —
;                       stub observes count=0, pending_operator=0.
;
; AC reference: AC5, AC9, AC10, AC12 (story 1.10).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — Subtest 1 stub never ran (test_capture_flag stayed 0)
;   0xE2 — Subtest 1: stub observed count != 5 (captured low byte
;          in test_capture_count)
;   0xE3 — Subtest 1: stub observed pending_operator != 'd'
;   0xE4 — Subtest 1: post-dispatch count_accumulator != 0
;          (parser_clear did not run after motion's RET)
;   0xE5 — Subtest 1: post-dispatch pending_operator != 0
;   0xE6 — Subtest 2 stub never ran
;   0xE7 — Subtest 2: stub observed nonzero parser state at
;          handler entry (count or pending_operator)
;   0xE8 — Subtest 1: post-dispatch pending_motion_prefix != 0
;          (AC10's third field — parser_clear must zero all three)
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

    ;; Pre-zero parser state, status_dirty, and the synthetic
    ;; capture buffer (the buffer's RAM is uninitialised on .com
    ;; load — must zero before each use).
    LD      HL, 0
    LD      (count_accumulator), HL
    LD      (test_capture_count), HL
    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (status_dirty), A
    LD      (test_capture_op), A
    LD      (test_capture_flag), A

    ;; -------------- Subtest 1: '5' 'd' <motion> --------------
    LD      A, '5'
    CALL    parser_handle_digit
    LD      A, 'd'
    CALL    parser_handle_operator

    LD      HL, test_motion_stub
    CALL    parser_dispatch

    ;; Did the stub run?
    LD      A, (test_capture_flag)
    CP      0xCA
    JR      Z, .ok1_ran
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok1_ran:

    ;; Did the stub see count == 5?
    LD      HL, (test_capture_count)
    LD      A, H
    OR      A
    JR      NZ, .fail1_count
    LD      A, L
    CP      5
    JR      Z, .ok1_count
.fail1_count:
    LD      B, L
    LD      A, 0xE2
    JP      test_fail
.ok1_count:

    ;; Did the stub see pending_operator == 'd'?
    LD      A, (test_capture_op)
    CP      'd'
    JR      Z, .ok1_op
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok1_op:

    ;; Post-dispatch: parser_clear must have zeroed state.
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok1_post_count
    LD      B, L
    LD      A, 0xE4
    JP      test_fail
.ok1_post_count:
    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok1_post_op
    LD      B, A
    LD      A, 0xE5
    JP      test_fail
.ok1_post_op:
    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok1_post_prefix
    LD      B, A
    LD      A, 0xE8
    JP      test_fail
.ok1_post_prefix:

    ;; -------------- Subtest 2: bare dispatch (no count/op) --------------
    LD      HL, 0
    LD      (test_capture_count), HL
    XOR     A
    LD      (test_capture_op), A
    LD      (test_capture_flag), A
    ;; (parser state is already 0 from parser_clear in Subtest 1)

    LD      HL, test_motion_stub
    CALL    parser_dispatch

    LD      A, (test_capture_flag)
    CP      0xCA
    JR      Z, .ok2_ran
    LD      B, A
    LD      A, 0xE6
    JP      test_fail
.ok2_ran:

    ;; Stub must have observed count == 0 AND pending_operator == 0.
    ;; Fold both into one sentinel; report the offending byte in B.
    LD      HL, (test_capture_count)
    LD      A, H
    OR      L
    JR      NZ, .fail2_state_count
    LD      A, (test_capture_op)
    OR      A
    JR      Z, .ok2_state
    LD      B, A
    JR      .fail2_state
.fail2_state_count:
    LD      B, L
.fail2_state:
    LD      A, 0xE7
    JP      test_fail
.ok2_state:

    JP      test_pass

;; ----- Synthetic motion stub + capture buffer -----
;; The stub mirrors the real-motion contract: RET-terminating,
;; reads parser state via state.inc symbols, side effects only.
test_motion_stub:
    LD      HL, (count_accumulator)
    LD      (test_capture_count), HL
    LD      A, (pending_operator)
    LD      (test_capture_op), A
    LD      A, 0xCA                     ; "stub ran" sentinel
    LD      (test_capture_flag), A
    RET

;; Test-local capture buffer. DEFB/DEFW emit bytes at this
;; address (between the test body and the production INCLUDEs);
;; the bytes are pre-zeroed at the start of each subtest because
;; CP/M does not zero this region on .com load.
test_capture_count:
    DEFW    0
test_capture_op:
    DEFB    0
test_capture_flag:
    DEFB    0

;; ----- LOCAL init_teardown stub (Story 2.3) -----
init_teardown:
    RET

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

;; ----- input_loop stub (resolves bdos_error_funnel symbol) -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST (positional anchor: static_data_base = $) -----
    INCLUDE "../../inc/state.inc"
