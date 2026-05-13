; ============================================================
; Module: test/cases/gapbuf_move-roundtrip.asm
; Purpose: AC15 — verify gapbuf_move_gap relocates the gap and
;          preserves file content under XOR-fold checksum;
;          gap pointers update correctly; cursor_offset is
;          unchanged across moves.
;
; AC reference: AC15 (story 1.7); covers contracts AC7 + AC8.
;
; Strategy: insert "ABCDEF" (6 bytes), capture chk1; move gap
; to logical offset 2 (left-shift, 4-byte LDDR), recompute,
; compare; move gap back to 6 (right-shift, 4-byte LDIR),
; recompute, compare. Distinct fail-codes per assertion.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — gapbuf_insert returned CF=1 during fixture setup
;   0xE2 — gap_start != GAP_BUFFER_BASE + 2 after move-to-2
;   0xE3 — gap_end != GAP_BUFFER_BASE + GAP_BUFFER_MAX - 4 after move-to-2
;   0xE4 — checksum mismatch after move-to-2
;   0xE5 — gap_start != GAP_BUFFER_BASE + 6 after move-back-to-6
;   0xE6 — gap_end != GAP_BUFFER_BASE + GAP_BUFFER_MAX after move-back-to-6
;   0xE7 — checksum mismatch after move-back-to-6
;   0xE8 — cursor_offset changed across move_gap calls
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----
    CALL    gapbuf_init

    ;; Insert "ABCDEF" — 6 calls, verify each CF=0.
    LD      A, 'A'
    CALL    gapbuf_insert
    JR      C, .ins_fail
    LD      A, 'B'
    CALL    gapbuf_insert
    JR      C, .ins_fail
    LD      A, 'C'
    CALL    gapbuf_insert
    JR      C, .ins_fail
    LD      A, 'D'
    CALL    gapbuf_insert
    JR      C, .ins_fail
    LD      A, 'E'
    CALL    gapbuf_insert
    JR      C, .ins_fail
    LD      A, 'F'
    CALL    gapbuf_insert
    JR      NC, .ins_done
.ins_fail:
    LD      A, 0xE1
    LD      B, 0
    JP      test_fail
.ins_done:

    ;; Snapshot cursor_offset (should == 6 here; the test only
    ;; cares that it does not change across move_gap calls — AC7).
    LD      HL, (cursor_offset)
    LD      (snap_co), HL

    ;; Compute chk1 (gap is at logical offset 6 / EOF).
    CALL    walk_xor_checksum
    LD      (chk1), A

    ;; Move gap to logical offset 2 (left-shift; LDDR path).
    LD      HL, 2
    CALL    gapbuf_move_gap

    ;; Verify gap_start == GAP_BUFFER_BASE + 2.
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE + 2
    OR      A
    SBC     HL, DE
    JR      Z, .gs2_ok
    LD      A, 0xE2
    LD      B, 0
    JP      test_fail
.gs2_ok:
    ;; Verify gap_end == GAP_BUFFER_BASE + GAP_BUFFER_MAX - 4.
    LD      HL, (gap_end)
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX - 4
    OR      A
    SBC     HL, DE
    JR      Z, .ge2_ok
    LD      A, 0xE3
    LD      B, 0
    JP      test_fail
.ge2_ok:

    ;; Recompute checksum, compare to chk1.
    CALL    walk_xor_checksum
    LD      HL, chk1
    CP      (HL)
    JR      Z, .chk2_ok
    LD      A, 0xE4
    LD      B, 0
    JP      test_fail
.chk2_ok:

    ;; Move gap back to logical offset 6 (right-shift; LDIR path).
    LD      HL, 6
    CALL    gapbuf_move_gap

    ;; Verify gap_start == GAP_BUFFER_BASE + 6.
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE + 6
    OR      A
    SBC     HL, DE
    JR      Z, .gs6_ok
    LD      A, 0xE5
    LD      B, 0
    JP      test_fail
.gs6_ok:
    ;; Verify gap_end == GAP_BUFFER_BASE + GAP_BUFFER_MAX.
    LD      HL, (gap_end)
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    OR      A
    SBC     HL, DE
    JR      Z, .ge6_ok
    LD      A, 0xE6
    LD      B, 0
    JP      test_fail
.ge6_ok:

    ;; Recompute checksum, compare to chk1.
    CALL    walk_xor_checksum
    LD      HL, chk1
    CP      (HL)
    JR      Z, .chk3_ok
    LD      A, 0xE7
    LD      B, 0
    JP      test_fail
.chk3_ok:

    ;; cursor_offset unchanged across move_gap calls (AC7 / AC15-step-8).
    LD      HL, (cursor_offset)
    LD      DE, (snap_co)
    OR      A
    SBC     HL, DE
    JR      Z, .co_ok
    LD      A, 0xE8
    LD      B, 0
    JP      test_fail
.co_ok:

    JP      test_pass

;; ----------------------------------------------------------------
;; walk_xor_checksum
;; XOR-fold every byte of file content (two-halves walk per SR3).
;;
;; In:      (gap_start), (gap_end) describe current buffer state.
;; Out:     A = XOR of all file bytes (length 0..file_length-1).
;; Trashes: A, BC, DE, HL, F.
;; ----------------------------------------------------------------
walk_xor_checksum:
    LD      C, 0                        ; checksum accumulator

    ;; Walk before-gap half: HL = GAP_BUFFER_BASE; stop when HL == gap_start.
    LD      HL, GAP_BUFFER_BASE
.pre:
    LD      DE, (gap_start)
    LD      A, L
    CP      E
    JR      NZ, .pre_more
    LD      A, H
    CP      D
    JR      Z, .post_setup              ; HL == gap_start: pre-half done
.pre_more:
    LD      A, (HL)
    XOR     C
    LD      C, A
    INC     HL
    JR      .pre

.post_setup:
    ;; Walk after-gap half: HL = gap_end; stop when HL == GAP_BUFFER_BASE + GAP_BUFFER_MAX.
    LD      HL, (gap_end)
.post:
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      A, L
    CP      E
    JR      NZ, .post_more
    LD      A, H
    CP      D
    JR      Z, .done                    ; HL == top: post-half done
.post_more:
    LD      A, (HL)
    XOR     C
    LD      C, A
    INC     HL
    JR      .post

.done:
    LD      A, C
    RET

;; ----- Per-test scratch -----
chk1:       DEFB 0
snap_co:    DEFW 0

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
