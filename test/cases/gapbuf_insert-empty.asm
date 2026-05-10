; ============================================================
; Module: test/cases/gapbuf_insert-empty.asm
; Purpose: AC12 — verify gapbuf_init invariants and that the
;          first gapbuf_insert advances state correctly.
;
; AC reference: AC12 (story 1.7).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — gap_start != GAP_BUFFER_BASE post-init
;   0xE2 — gap_end != GAP_BUFFER_BASE + GAP_BUFFER_MAX post-init
;   0xE3 — cursor_offset != 0 post-init
;   0xE4 — gapbuf_insert returned CF=1 on empty buffer
;   0xE5 — (GAP_BUFFER_BASE) != 'X' post-insert
;   0xE6 — gap_start != GAP_BUFFER_BASE + 1 post-insert
;   0xE7 — cursor_offset != 1 post-insert
; ============================================================

;; --- Pre-ORG production headers (pure EQU; safe before ORG) ---
    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----
    CALL    gapbuf_init

    ;; AC2: gap_start == GAP_BUFFER_BASE
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE
    JR      Z, .gs_ok
    LD      A, 0xE1
    LD      B, 0
    JP      test_fail
.gs_ok:

    ;; AC2: gap_end == GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      HL, (gap_end)
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    OR      A
    SBC     HL, DE
    JR      Z, .ge_ok
    LD      A, 0xE2
    LD      B, 0
    JP      test_fail
.ge_ok:

    ;; AC2: cursor_offset == 0
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .co_ok
    LD      A, 0xE3
    LD      B, 0
    JP      test_fail
.co_ok:

    ;; AC3: gapbuf_insert('X') succeeds (CF == 0)
    LD      A, 'X'
    CALL    gapbuf_insert
    JR      NC, .ins_ok
    LD      A, 0xE4
    LD      B, 0
    JP      test_fail
.ins_ok:

    ;; AC3: byte at original gap_start (== GAP_BUFFER_BASE) is 'X'
    LD      A, (GAP_BUFFER_BASE)
    CP      'X'
    JR      Z, .b_ok
    LD      A, 0xE5
    LD      B, 0
    JP      test_fail
.b_ok:

    ;; AC3: gap_start == GAP_BUFFER_BASE + 1
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE + 1
    OR      A
    SBC     HL, DE
    JR      Z, .gs2_ok
    LD      A, 0xE6
    LD      B, 0
    JP      test_fail
.gs2_ok:

    ;; AC3: cursor_offset == 1
    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    JR      Z, .co2_ok
    LD      A, 0xE7
    LD      B, 0
    JP      test_fail
.co2_ok:

    JP      test_pass

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST (positional anchor: static_data_base = $) -----
    INCLUDE "../../inc/state.inc"
