; ============================================================
; Module: test/cases/parser_motion-prefix-cleared-on-other-key.asm
; Purpose: AC11 — verify the asymmetric clear-on-entry protocol
;          for pending_motion_prefix:
;            - parser_handle_digit clears pending_motion_prefix
;              on entry (a digit arriving discards a stale 'g').
;            - parser_handle_operator clears pending_motion_prefix
;              on entry (an operator arriving discards stale 'g').
;            - parser_handle_motion_prefix does NOT clear
;              pending_motion_prefix on entry (the doubled-prefix
;              branch must test the prior value).
;
;          This test guards against an "always clear on entry"
;          regression that would silently break gg-detection.
;
; AC reference: AC11, AC12 (story 1.10).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — 'g' then '5' left pending_motion_prefix nonzero
;          (parser_handle_digit failed to clear on entry)
;   0xE2 — 'g' then '5' did not yield count_accumulator = 5
;   0xE3 — 'g' then 'd' left pending_motion_prefix nonzero
;          (parser_handle_operator failed to clear on entry)
;   0xE4 — 'g' then 'd' did not leave pending_operator = 'd'
;   0xE5 — 'g' alone left pending_motion_prefix != 'g'
;          (the prefix MUST persist until a non-prefix-aware key
;          arrives; otherwise gg detection is impossible)
;   0xE6 — 'g' then '5' disturbed pending_operator (AC11 requires
;          the digit handler to leave pending_operator unchanged)
;   0xE7 — 'g' then '0' left pending_motion_prefix nonzero (the
;          leading-zero arm of parser_handle_digit must also clear
;          the prefix — guards against a refactor that moves the
;          XOR A clear below the JP parser_motion_zero_stub branch)
;   0xE8 — 'g' then '0' did not fire parser_motion_zero_stub
;          (status_dirty stayed 0 — the leading-zero motion path
;          should have set it via status_set_message)
;   0xE9 — 'g' then '0' modified count_accumulator (the leading-
;          zero stub must not touch count, which was 0 here)
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

    ;; Pre-zero parser state.
    LD      HL, 0
    LD      (count_accumulator), HL
    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    ;; Subtest 1: 'g' then '5' — digit clears prefix.
    LD      A, 'g'
    CALL    parser_handle_motion_prefix
    LD      A, '5'
    CALL    parser_handle_digit

    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok1a
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok1a:
    LD      HL, (count_accumulator)
    LD      A, H
    OR      A
    JR      NZ, .fail1b
    LD      A, L
    CP      5
    JR      Z, .ok1b
.fail1b:
    LD      B, L
    LD      A, 0xE2
    JP      test_fail
.ok1b:
    ;; AC11 also requires the digit handler to leave pending_operator
    ;; alone — guards against a regression that accidentally zeros it.
    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok1c
    LD      B, A
    LD      A, 0xE6
    JP      test_fail
.ok1c:

    ;; Subtest 2: 'g' then 'd' — operator clears prefix.
    LD      HL, 0
    LD      (count_accumulator), HL
    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    LD      A, 'g'
    CALL    parser_handle_motion_prefix
    LD      A, 'd'
    CALL    parser_handle_operator

    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok2a
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok2a:
    LD      A, (pending_operator)
    CP      'd'
    JR      Z, .ok2b
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok2b:

    ;; Subtest 3: 'g' alone leaves prefix set (no auto-clear).
    LD      HL, 0
    LD      (count_accumulator), HL
    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    LD      A, 'g'
    CALL    parser_handle_motion_prefix

    LD      A, (pending_motion_prefix)
    CP      'g'
    JR      Z, .ok3
    LD      B, A
    LD      A, 0xE5
    JP      test_fail
.ok3:

    ;; Subtest 4: 'g' then '0' — the leading-zero arm of
    ;; parser_handle_digit must also clear the prefix. The AC11
    ;; clear-on-entry runs BEFORE the AC3 branch decision; a
    ;; refactor that moved the XOR A below the JP parser_motion_zero_stub
    ;; would silently break gg detection after stale-g + leading-0.
    LD      HL, 0
    LD      (count_accumulator), HL
    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (status_dirty), A

    LD      A, 'g'
    CALL    parser_handle_motion_prefix
    LD      A, '0'
    CALL    parser_handle_digit

    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok4a
    LD      B, A
    LD      A, 0xE7
    JP      test_fail
.ok4a:
    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok4b
    LD      B, A
    LD      A, 0xE8
    JP      test_fail
.ok4b:
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok4c
    LD      B, L
    LD      A, 0xE9
    JP      test_fail
.ok4c:

    JP      test_pass

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
