; ============================================================
; Module: test/cases/parser_leading-zero-is-motion.asm
; Purpose: AC3 — verify parser_handle_digit, when invoked with
;          A = '0' AND count_accumulator == 0, does NOT
;          accumulate but instead transfers control to motion_0
;          (Story 2.6 — replaced parser_motion_zero_stub).
;          Observable side effect: cursor_offset moves to the
;          start of the current line. count_accumulator stays 0.
;
; AC reference: AC3, AC12 (story 1.10) + Story 2.6 AC4.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — first '0' left count_accumulator != 0 (it must stay 0
;          — motion_0 does not modify count)
;   0xE2 — first '0' did not move cursor to 0 (motion_0 did not fire)
;   0xE3 — second '0' (with state reset between) left
;          count_accumulator != 0
;   0xE4 — second '0' did not move cursor to 0 (motion_0 did not
;          fire on the repeat call)
;   B    — diagnostic byte at point of failure
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

    ;; Pre-seed a single-line buffer "hello" with cursor=3 so we
    ;; can observe motion_0 firing (cursor → 0).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 5
    LDIR
    LD      HL, GAP_BUFFER_BASE + 5
    LD      (gap_start), HL

    ;; Pre-zero all parser state and status_dirty.
    LD      HL, 0
    LD      (count_accumulator), HL
    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (status_dirty), A

    ;; Subtest 1: leading '0' fires motion_0.
    LD      HL, 3
    LD      (cursor_offset), HL

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

    ;; (b) cursor_offset must be 0 (motion_0 fired).
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok1_cursor
    LD      A, L
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok1_cursor:

    ;; Subtest 2: second '0' (state reset between) ALSO fires motion_0.
    LD      HL, 4
    LD      (cursor_offset), HL
    LD      HL, 0
    LD      (count_accumulator), HL
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

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok2_cursor
    LD      A, L
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok2_cursor:

    JP      test_pass

.payload:
    DEFB    "hello"

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
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"     ; Story 2.8: dispatch_normal forward-references edits_*, dispatch_insert table grows, unbound_insert tail-JPs edits_insert_literal
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

;; ----- input_loop stub (resolves bdos_error_funnel symbol) -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST (positional anchor: static_data_base = $) -----
    INCLUDE "../../inc/state.inc"
