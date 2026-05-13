; ============================================================
; Module: test/cases/gapbuf_delete-mid.asm
; Purpose: Deterministic coverage of AC6 — mid-buffer
;          gapbuf_delete: gap relocates to cursor, gap_start
;          decrements (consuming the byte logically before
;          the cursor), cursor_offset decrements, file content
;          loses the deleted byte and nothing else.
;
; AC reference: AC6 (story 1.7); deterministic companion to the
; fuzz coverage in gapbuf_random-ops.asm. The fuzz harness
; exercises AC6 across many positions, but a focused test
; pins the exact post-state of one mid-buffer delete with
; named fail-codes per assertion — easier to debug a regression.
;
; Strategy:
;   1. CALL gapbuf_init.
;   2. Insert "ABC" — cursor=3, gap_offset=3, before-gap="ABC".
;   3. Direct-poke cursor_offset := 2 (simulates a vi `h` motion
;      — Story 2.5 lands real motions; until then the test owns
;      cursor placement, same precedent as gapbuf_insert-fills-
;      buffer.asm's direct state poke).
;   4. CALL gapbuf_delete — expected: detects gap_offset != cursor,
;      calls gapbuf_move_gap(2) (LDDR-shifts 'C' into the after-gap
;      half), then decrements gap_start (consuming 'B') and
;      decrements cursor.
;   5. Verify post-state:
;        CF == 0
;        gap_start     == GAP_BUFFER_BASE + 1
;        gap_end       == GAP_BUFFER_BASE + GAP_BUFFER_MAX - 1
;        cursor_offset == 1
;        walk-XOR-fold checksum == 'A' XOR 'C' (= 0x42)
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — gapbuf_insert returned CF=1 during fixture setup
;   0xE2 — gapbuf_delete returned CF=1 mid-buffer (expected CF=0)
;   0xE3 — gap_start != GAP_BUFFER_BASE + 1 post-delete
;   0xE4 — gap_end   != GAP_BUFFER_BASE + GAP_BUFFER_MAX - 1 post-delete
;   0xE5 — cursor_offset != 1 post-delete
;   0xE6 — XOR-fold checksum != 'A' XOR 'C' post-delete
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

    ;; Insert "ABC".
    LD      A, 'A'
    CALL    gapbuf_insert
    JR      C, .ins_fail
    LD      A, 'B'
    CALL    gapbuf_insert
    JR      C, .ins_fail
    LD      A, 'C'
    CALL    gapbuf_insert
    JR      NC, .ins_done
.ins_fail:
    LD      A, 0xE1
    LD      B, 0
    JP      test_fail
.ins_done:

    ;; Poke cursor_offset := 2 (vi `h` motion stand-in; Story 2.5
    ;; lands real motions). gap_offset remains 3 — gap_at_cursor
    ;; check inside gapbuf_delete must therefore call move_gap(2).
    LD      HL, 2
    LD      (cursor_offset), HL

    ;; Mid-buffer delete: removes the byte logically before
    ;; cursor — that's 'B' (offset 1).
    CALL    gapbuf_delete
    JR      NC, .del_ok
    LD      A, 0xE2
    LD      B, 0
    JP      test_fail
.del_ok:

    ;; gap_start == GAP_BUFFER_BASE + 1 (one byte 'A' before gap).
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE + 1
    OR      A
    SBC     HL, DE
    JR      Z, .gs_ok
    LD      A, 0xE3
    LD      B, 0
    JP      test_fail
.gs_ok:

    ;; gap_end == GAP_BUFFER_BASE + GAP_BUFFER_MAX - 1 (one byte
    ;; 'C' at the top of the buffer, in the after-gap half;
    ;; LDDR(count=1) inside move_gap(2) shifted it there from
    ;; the before-gap half before the delete decrement).
    LD      HL, (gap_end)
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX - 1
    OR      A
    SBC     HL, DE
    JR      Z, .ge_ok
    LD      A, 0xE4
    LD      B, 0
    JP      test_fail
.ge_ok:

    ;; cursor_offset == 1.
    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    JR      Z, .co_ok
    LD      A, 0xE5
    LD      B, 0
    JP      test_fail
.co_ok:

    ;; Walk-XOR-fold checksum: file is "AC" (length 2).
    ;; Expected = 'A' XOR 'C' = 0x41 XOR 0x43 = 0x02.
    CALL    walk_xor_checksum
    CP      'A' ^ 'C'
    JR      Z, .chk_ok
    LD      A, 0xE6
    LD      B, 0
    JP      test_fail
.chk_ok:

    JP      test_pass

;; ----------------------------------------------------------------
;; walk_xor_checksum
;; XOR-fold every byte of file content (two-halves walk per SR3).
;; Identical to the helper in gapbuf_move-roundtrip.asm; inlined
;; here to keep the test self-contained (per the spec dev-notes:
;; "if simpler-per-case is more legible, do that").
;;
;; In:      (gap_start), (gap_end) describe current buffer state.
;; Out:     A = XOR of all file bytes (length 0..file_length-1).
;; Trashes: A, BC, DE, HL, F.
;; ----------------------------------------------------------------
walk_xor_checksum:
    LD      C, 0                        ; checksum accumulator

    LD      HL, GAP_BUFFER_BASE
.pre:
    LD      DE, (gap_start)
    LD      A, L
    CP      E
    JR      NZ, .pre_more
    LD      A, H
    CP      D
    JR      Z, .post_setup
.pre_more:
    LD      A, (HL)
    XOR     C
    LD      C, A
    INC     HL
    JR      .pre

.post_setup:
    LD      HL, (gap_end)
.post:
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      A, L
    CP      E
    JR      NZ, .post_more
    LD      A, H
    CP      D
    JR      Z, .done
.post_more:
    LD      A, (HL)
    XOR     C
    LD      C, A
    INC     HL
    JR      .post

.done:
    LD      A, C
    RET

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
