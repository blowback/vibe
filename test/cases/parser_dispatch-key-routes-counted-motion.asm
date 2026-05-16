; ============================================================
; Module: test/cases/parser_dispatch-key-routes-counted-motion.asm
; Purpose: AC11 — full dispatch_key path under counted motion.
;          Drives '5' then 'j' through dispatch_key against the
;          production dispatch_normal (MODE_NORMAL). Verifies:
;            - '5' routes to parser_handle_digit → count = 5.
;            - 'j' routes to motion_j → cursor advanced 5 lines;
;              count cleared via parser_clear tail-JP.
;          Pins that count survives across the two dispatch_key
;          calls (separate input_loop iterations in production);
;          no intermediate handler trashes count_accumulator.
;
;          Buffer: same 10-line fixture as parser_5j-dispatches-
;          with-count-5 (39 bytes, no trailing LF). Line N starts
;          at offset 4*(N-1). Cursor pre-set to offset 0; after
;          '5' '+' 'j' sequence cursor must land at offset 20
;          (start of line 6).
;
; AC reference: AC11 (story 2.7 Sub 3.7).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — post-'5': count_accumulator != 5
;   0xE2 — post-'j': cursor_offset != 20 (start of line 6)
;   0xE3 — post-'j': count_accumulator != 0
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

    ;; Pre-zero parser state; pre-set MODE_NORMAL.
    XOR     A
    LD      (status_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; Populate gap-buffer with 10-line fixture (39 bytes).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 39
    LDIR
    LD      HL, GAP_BUFFER_BASE + 39
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    ;; Subtest 1: drive '5' through dispatch_key; assert count=5.
    LD      A, '5'
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key

    LD      HL, (count_accumulator)
    LD      A, H
    OR      A
    JR      NZ, .fail_count_pre
    LD      A, L
    CP      5
    JR      Z, .ok_count_pre
.fail_count_pre:
    LD      B, L
    LD      A, 0xE1
    JP      test_fail
.ok_count_pre:

    ;; Subtest 2: drive 'j' through dispatch_key; assert cursor moved.
    LD      A, 'j'
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key

    LD      HL, (cursor_offset)
    LD      DE, 20
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor
    LD      A, (cursor_offset)
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok_cursor:

    ;; Subtest 3: count cleared post-motion.
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count_post
    LD      B, L
    LD      A, 0xE3
    JP      test_fail
.ok_count_post:

    JP      test_pass

.payload:
    DEFB    "L01", 0x0A, "L02", 0x0A, "L03", 0x0A, "L04", 0x0A
    DEFB    "L05", 0x0A, "L06", 0x0A, "L07", 0x0A, "L08", 0x0A
    DEFB    "L09", 0x0A, "L10"

;; ----- LOCAL init_teardown stub -----
    INCLUDE "../inc/test_teardown_stub.inc"
;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST (positional anchor: static_data_base = $) -----
    INCLUDE "../../inc/state.inc"
