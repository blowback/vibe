; ============================================================
; Module: test/cases/parser_count-accumulator.asm
; Purpose: AC2 — verify parser_handle_digit accumulates digits
;          into count_accumulator via count*10 + (digit-'0').
;          Exercises single-digit, two-digit, three-digit, and
;          large-count (9999) cases.
;
; AC reference: AC2, AC12 (story 1.10).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — single '5' did not yield count_accumulator = 5
;   0xE2 — '1' then '2' did not yield count_accumulator = 12
;   0xE3 — '1' '2' '3' did not yield count_accumulator = 123
;   0xE4 — '9' '9' '9' '9' did not yield count_accumulator = 9999
;   0xE5 — overflow wrap from 6553 + '9' did not yield 3
;          (documented wrap: 6553 * 10 + 9 = 65539 ≡ 3 mod 65536).
;          Locks in the "no clamp, vi-tradition silent wrap" contract
;          so a future saturation refactor cannot pass undetected.
;   B    — observed L byte of count_accumulator (low byte; H byte
;          is checked separately and folded into the same sentinel)
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
    LD      (pending_motion_prefix), A
    LD      (pending_operator), A

    ;; Subtest 1: single '5' → count_accumulator = 5
    LD      A, '5'
    CALL    parser_handle_digit
    LD      HL, (count_accumulator)
    LD      A, H
    OR      A
    JR      NZ, .fail1
    LD      A, L
    CP      5
    JR      Z, .ok1
.fail1:
    LD      B, L
    LD      A, 0xE1
    JP      test_fail
.ok1:

    ;; Subtest 2: '1' '2' → count_accumulator = 12
    ;; (state carries over from Subtest 1, so reset first)
    LD      HL, 0
    LD      (count_accumulator), HL
    LD      A, '1'
    CALL    parser_handle_digit
    LD      A, '2'
    CALL    parser_handle_digit
    LD      HL, (count_accumulator)
    LD      A, H
    OR      A
    JR      NZ, .fail2
    LD      A, L
    CP      12
    JR      Z, .ok2
.fail2:
    LD      B, L
    LD      A, 0xE2
    JP      test_fail
.ok2:

    ;; Subtest 3: '1' '2' '3' → count_accumulator = 123 (= 0x7B)
    LD      HL, 0
    LD      (count_accumulator), HL
    LD      A, '1'
    CALL    parser_handle_digit
    LD      A, '2'
    CALL    parser_handle_digit
    LD      A, '3'
    CALL    parser_handle_digit
    LD      HL, (count_accumulator)
    LD      A, H
    OR      A
    JR      NZ, .fail3
    LD      A, L
    CP      123
    JR      Z, .ok3
.fail3:
    LD      B, L
    LD      A, 0xE3
    JP      test_fail
.ok3:

    ;; Subtest 4: '9' '9' '9' '9' → count_accumulator = 9999 (= 0x270F)
    LD      HL, 0
    LD      (count_accumulator), HL
    LD      A, '9'
    CALL    parser_handle_digit
    LD      A, '9'
    CALL    parser_handle_digit
    LD      A, '9'
    CALL    parser_handle_digit
    LD      A, '9'
    CALL    parser_handle_digit
    LD      HL, (count_accumulator)
    LD      A, H
    CP      0x27
    JR      NZ, .fail4
    LD      A, L
    CP      0x0F
    JR      Z, .ok4
.fail4:
    LD      B, L
    LD      A, 0xE4
    JP      test_fail
.ok4:

    ;; Subtest 5: overflow wrap. Pre-load count_accumulator = 6553
    ;; (= 0x1999), then send '9'. Expected: 6553 * 10 + 9 = 65539,
    ;; which wraps modulo 65536 to 3 (= 0x0003). Dev Notes pin this
    ;; as a known sharp edge (vi tradition: no clamp). This subtest
    ;; locks the behaviour in so a future "add saturation" or
    ;; "add overflow guard" refactor is caught at test time.
    LD      HL, 6553
    LD      (count_accumulator), HL
    LD      A, '9'
    CALL    parser_handle_digit
    LD      HL, (count_accumulator)
    LD      A, H
    OR      A
    JR      NZ, .fail5
    LD      A, L
    CP      3
    JR      Z, .ok5
.fail5:
    LD      B, L
    LD      A, 0xE5
    JP      test_fail
.ok5:

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
    INCLUDE "../../src/undo.asm"

;; ----- input_loop stub (resolves bdos_error_funnel symbol) -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST (positional anchor: static_data_base = $) -----
    INCLUDE "../../inc/state.inc"
