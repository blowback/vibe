; ============================================================
; Module: test/cases/motions_h-decrement.asm
; Purpose: AC11 — verify basic motion_h decrements cursor_offset
;          by 1 and tail-JPs parser_clear.
;
;          Setup: gap pre-populated with "abc" via direct write
;          (AR-exempt in tests); cursor at 2; count = 0.
;          Expected: cursor lands at 1; count_accumulator cleared
;          by parser_clear; gap_start / gap_end unchanged.
;
; AC reference: AC11 (Story 2.5 Sub 7.1).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 1 (B = actual lo byte)
;   0x81 — count_accumulator not cleared
;   0x82 — pending_operator not cleared
;   0x83 — pending_motion_prefix not cleared
;   0x84 — gap_start mutated (AR14 violation)
;   0x85 — gap_end mutated (AR14 violation)
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----

    ;; Pre-zero relevant state for determinism.
    XOR     A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    ;; Reset gap, then directly write "abc" into the before-gap
    ;; region (tests are AR-exempt — per test_epilogue.inc lines
    ;; 24-37 — so direct gap-region writes are fine).
    CALL    gapbuf_init                 ; gap_start=BASE; gap_end=BASE+MAX; cursor=0
    LD      HL, GAP_BUFFER_BASE
    LD      (HL), 'a'
    INC     HL
    LD      (HL), 'b'
    INC     HL
    LD      (HL), 'c'
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    ;; Pre-set cursor_offset = 2.
    LD      HL, 2
    LD      (cursor_offset), HL

    ;; Drive motion_h.
    LD      A, 'h'
    CALL    motion_h

    ;; --- Subtest 1: cursor_offset == 1 ---
    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor
    LD      A, (cursor_offset)
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.ok_cursor:

    ;; --- Subtest 2: count_accumulator cleared by parser_clear ---
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x81
    JP      test_fail
.ok_count:

    ;; --- Subtest 3: pending_operator cleared ---
    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok_op
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_op:

    ;; --- Subtest 4: pending_motion_prefix cleared ---
    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok_prefix
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_prefix:

    ;; --- Subtest 5: gap_start unchanged (AR14) ---
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE + 3
    OR      A
    SBC     HL, DE
    JR      Z, .ok_gs
    LD      B, L
    LD      A, 0x84
    JP      test_fail
.ok_gs:

    ;; --- Subtest 6: gap_end unchanged (AR14) ---
    LD      HL, (gap_end)
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    OR      A
    SBC     HL, DE
    JR      Z, .ok_ge
    LD      B, L
    LD      A, 0x85
    JP      test_fail
.ok_ge:

    JP      test_pass

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

;; ----- init_teardown stub -----
    INCLUDE "../inc/test_teardown_stub.inc"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST (positional anchor) -----
    INCLUDE "../../inc/state.inc"
