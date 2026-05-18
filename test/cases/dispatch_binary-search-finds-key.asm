; ============================================================
; Module: test/cases/dispatch_binary-search-finds-key.asm
; Purpose: AC11 — verify dispatch_key's binary-search HIT path.
;          Builds a synthetic 5-entry sorted (key, handler_addr)
;          table inside the test file, dispatches every key in
;          the table, and verifies that the matching sentinel
;          handler ran (each sentinel writes a unique byte to
;          (TEST_CONTEXT)).
;
;          Edge cases covered: leftmost ('A', requires 3
;          iterations from mid='M'), middle ('M', 1 iteration),
;          rightmost ('Z', 2 iterations), plus the two
;          remaining entries 'C' and 'X' to fill the search
;          tree. The synthetic table mirrors the production
;          layout: 2-byte unbound prefix + DEFB key : DEFW addr
;          entries sorted ascending by ASCII key byte.
;
; AC reference: AC2, AC11 (story 1.9).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — dispatch 'A' did not run sentinel A (leftmost)
;   0xE2 — dispatch 'C' did not run sentinel C
;   0xE3 — dispatch 'M' did not run sentinel M (middle)
;   0xE4 — dispatch 'X' did not run sentinel X
;   0xE5 — dispatch 'Z' did not run sentinel Z (rightmost)
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

    ;; Subtest 1: leftmost 'A' → sentinel 0x11 (3 iterations)
    XOR     A
    LD      (TEST_CONTEXT), A
    LD      A, 'A'
    LD      HL, dispatch_test_table
    LD      B, TEST_TABLE_COUNT
    CALL    dispatch_key
    LD      A, (TEST_CONTEXT)
    CP      0x11
    JR      Z, .ok_a
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok_a:

    ;; Subtest 2: 'C' → sentinel 0x22 (2 iterations)
    XOR     A
    LD      (TEST_CONTEXT), A
    LD      A, 'C'
    LD      HL, dispatch_test_table
    LD      B, TEST_TABLE_COUNT
    CALL    dispatch_key
    LD      A, (TEST_CONTEXT)
    CP      0x22
    JR      Z, .ok_c
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok_c:

    ;; Subtest 3: middle 'M' → sentinel 0x33 (1 iteration)
    XOR     A
    LD      (TEST_CONTEXT), A
    LD      A, 'M'
    LD      HL, dispatch_test_table
    LD      B, TEST_TABLE_COUNT
    CALL    dispatch_key
    LD      A, (TEST_CONTEXT)
    CP      0x33
    JR      Z, .ok_m
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok_m:

    ;; Subtest 4: 'X' → sentinel 0x44 (3 iterations: M→Z→X)
    XOR     A
    LD      (TEST_CONTEXT), A
    LD      A, 'X'
    LD      HL, dispatch_test_table
    LD      B, TEST_TABLE_COUNT
    CALL    dispatch_key
    LD      A, (TEST_CONTEXT)
    CP      0x44
    JR      Z, .ok_x
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok_x:

    ;; Subtest 5: rightmost 'Z' → sentinel 0x55 (2 iterations)
    XOR     A
    LD      (TEST_CONTEXT), A
    LD      A, 'Z'
    LD      HL, dispatch_test_table
    LD      B, TEST_TABLE_COUNT
    CALL    dispatch_key
    LD      A, (TEST_CONTEXT)
    CP      0x55
    JR      Z, .ok_z
    LD      B, A
    LD      A, 0xE5
    JP      test_fail
.ok_z:

    JP      test_pass

;; ----- Synthetic dispatch table + sentinel handlers -----
;; Each handler writes a unique byte to (TEST_CONTEXT) and RETs.
;; The unbound entry should NEVER be reached in this test (every
;; key dispatched is in the table); a 0x66 sighting indicates a
;; binary-search miss-bug.

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
    LD      A, 0x66
    LD      (TEST_CONTEXT), A
    RET

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"     ; Story 2.5: dispatch_normal forward-references motion_h/j/k/l
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/search.asm"     ; Story 2.8: dispatch_normal forward-references edits_*, dispatch_insert table grows, unbound_insert tail-JPs edits_insert_literal
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"
    INCLUDE "../../src/render.asm"

;; ----- input_loop stub (resolves bdos_error_funnel symbol) -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST (positional anchor: static_data_base = $) -----
    INCLUDE "../../inc/state.inc"
