; ============================================================
; Module: test/cases/dispatch_binary-search-misses.asm
; Purpose: AC11 — verify dispatch_key's binary-search MISS path.
;          Builds the same synthetic 5-entry sorted table as
;          dispatch_binary-search-finds-key.asm, dispatches
;          keys NOT in the table, and verifies that control
;          falls through to the per-table unbound handler
;          (writes 0xBE — "beep" — to TEST_CONTEXT). Covers
;          three classic miss positions: below leftmost, gap
;          (between adjacent entries), above rightmost.
;
; AC reference: AC3, AC11 (story 1.9).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — '0' (below 'A') did not route to unbound
;   0xE2 — 'B' (gap: 'A' < 'B' < 'C') did not route to unbound
;   0xE3 — 'L' (gap: 'C' < 'L' < 'M') did not route to unbound
;   0xE4 — 'Y' (gap: 'X' < 'Y' < 'Z') did not route to unbound
;   0xE5 — '~' (above 'Z') did not route to unbound
;   B    — TEST_CONTEXT byte after dispatch (for diagnosis)
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

    ;; Subtest 1: '0' (0x30, below leftmost 'A' = 0x41)
    XOR     A
    LD      (TEST_CONTEXT), A
    LD      A, '0'
    LD      HL, dispatch_test_table
    LD      B, TEST_TABLE_COUNT
    CALL    dispatch_key
    LD      A, (TEST_CONTEXT)
    CP      0xBE
    JR      Z, .ok_below
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok_below:

    ;; Subtest 2: 'B' (0x42, between 'A' and 'C')
    XOR     A
    LD      (TEST_CONTEXT), A
    LD      A, 'B'
    LD      HL, dispatch_test_table
    LD      B, TEST_TABLE_COUNT
    CALL    dispatch_key
    LD      A, (TEST_CONTEXT)
    CP      0xBE
    JR      Z, .ok_b
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok_b:

    ;; Subtest 3: 'L' (0x4C, between 'C' and 'M')
    XOR     A
    LD      (TEST_CONTEXT), A
    LD      A, 'L'
    LD      HL, dispatch_test_table
    LD      B, TEST_TABLE_COUNT
    CALL    dispatch_key
    LD      A, (TEST_CONTEXT)
    CP      0xBE
    JR      Z, .ok_l
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok_l:

    ;; Subtest 4: 'Y' (0x59, between 'X' and 'Z')
    XOR     A
    LD      (TEST_CONTEXT), A
    LD      A, 'Y'
    LD      HL, dispatch_test_table
    LD      B, TEST_TABLE_COUNT
    CALL    dispatch_key
    LD      A, (TEST_CONTEXT)
    CP      0xBE
    JR      Z, .ok_y
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok_y:

    ;; Subtest 5: '~' (0x7E, above rightmost 'Z' = 0x5A)
    XOR     A
    LD      (TEST_CONTEXT), A
    LD      A, '~'
    LD      HL, dispatch_test_table
    LD      B, TEST_TABLE_COUNT
    CALL    dispatch_key
    LD      A, (TEST_CONTEXT)
    CP      0xBE
    JR      Z, .ok_above
    LD      B, A
    LD      A, 0xE5
    JP      test_fail
.ok_above:

    JP      test_pass

;; ----- Synthetic dispatch table + sentinel handlers -----
;; Same 5-entry table as the finds-key test; sentinel handlers
;; write distinct values so a buggy "found" would yield a
;; non-0xBE TEST_CONTEXT and fail noisily rather than passing
;; on accident.

dispatch_test_table:
    DEFW    test_unbound
.entries:
    DEFB    'A'
    DEFW    test_handler_A
    DEFB    'C'
    DEFW    test_handler_C
    DEFB    'M'
    DEFW    test_handler_M
    DEFB    'X'
    DEFW    test_handler_X
    DEFB    'Z'
    DEFW    test_handler_Z
TEST_TABLE_COUNT EQU ($ - .entries) / 3

test_handler_A:
    LD      A, 0x11
    LD      (TEST_CONTEXT), A
    RET
test_handler_C:
    LD      A, 0x22
    LD      (TEST_CONTEXT), A
    RET
test_handler_M:
    LD      A, 0x33
    LD      (TEST_CONTEXT), A
    RET
test_handler_X:
    LD      A, 0x44
    LD      (TEST_CONTEXT), A
    RET
test_handler_Z:
    LD      A, 0x55
    LD      (TEST_CONTEXT), A
    RET
;; ----- LOCAL init_teardown stub (Story 2.3: exline.asm references init_teardown via cmd_quit) -----
    INCLUDE "../inc/test_teardown_stub.inc"
test_unbound:
    LD      A, 0xBE
    LD      (TEST_CONTEXT), A
    RET

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"     ; Story 2.5: dispatch_normal forward-references motion_h/j/k/l
    INCLUDE "../../src/edits.asm"     ; Story 2.8: dispatch_normal forward-references edits_*, dispatch_insert table grows, unbound_insert tail-JPs edits_insert_literal
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/render.asm"

;; ----- input_loop stub (resolves bdos_error_funnel symbol) -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST (positional anchor: static_data_base = $) -----
    INCLUDE "../../inc/state.inc"
