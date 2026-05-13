; ============================================================
; Module: test/cases/parser_zero-after-digit.asm
; Purpose: AC4 — verify parser_handle_digit, when invoked with
;          A = '0' AND count_accumulator > 0, accumulates the
;          '0' as count*10 (NOT the leading-zero-is-motion
;          branch). The leading-zero stub must NOT fire here:
;          status_dirty stays 0 across the sequence.
;
; AC reference: AC4, AC12 (story 1.10).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — '1' did not yield count_accumulator = 1 (precondition
;          for the '0'-after-digit branch — count must be > 0)
;   0xE2 — '1' then '0' did not yield count_accumulator = 10
;   0xE3 — status_dirty became nonzero (the leading-zero stub
;          was incorrectly taken on the '0' that followed '1')
;   0xE4 — '1' '0' '0' did not yield count_accumulator = 100
;   B    — observed L byte / status_dirty
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

    ;; Subtest 1: '1' → count_accumulator = 1
    LD      A, '1'
    CALL    parser_handle_digit
    LD      HL, (count_accumulator)
    LD      A, H
    OR      A
    JR      NZ, .fail_mid
    LD      A, L
    CP      1
    JR      Z, .ok_mid
.fail_mid:
    LD      B, L
    LD      A, 0xE1
    JP      test_fail
.ok_mid:

    ;; Subtest 2: '0' → count_accumulator = 10 (NOT motion stub)
    LD      A, '0'
    CALL    parser_handle_digit
    LD      HL, (count_accumulator)
    LD      A, H
    OR      A
    JR      NZ, .fail_ten
    LD      A, L
    CP      10
    JR      Z, .ok_ten
.fail_ten:
    LD      B, L
    LD      A, 0xE2
    JP      test_fail
.ok_ten:

    ;; Subtest 2b: status_dirty must still be 0 — the '0' after a
    ;; nonzero count must NOT trigger parser_motion_zero_stub.
    LD      A, (status_dirty)
    OR      A
    JR      Z, .ok_clean
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok_clean:

    ;; Subtest 3: '1' '0' '0' → count_accumulator = 100 (0x64)
    LD      HL, 0
    LD      (count_accumulator), HL
    XOR     A
    LD      (status_dirty), A
    LD      A, '1'
    CALL    parser_handle_digit
    LD      A, '0'
    CALL    parser_handle_digit
    LD      A, '0'
    CALL    parser_handle_digit
    LD      HL, (count_accumulator)
    LD      A, H
    OR      A
    JR      NZ, .fail_hundred
    LD      A, L
    CP      100
    JR      Z, .ok_hundred
.fail_hundred:
    LD      B, L
    LD      A, 0xE4
    JP      test_fail
.ok_hundred:

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
