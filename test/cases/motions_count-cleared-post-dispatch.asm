; ============================================================
; Module: test/cases/motions_count-cleared-post-dispatch.asm
; Purpose: AC6 — counted motion's tail-JP parser_clear zeroes
;          count, and the next unprefixed motion moves by 1 (not
;          by the prior count). Buffer "abcdefg" (7 bytes, no LF).
;          Sequence:
;            Subtest 1: cursor=6, count=5; motion_h → cursor=1
;                       (walks 5 steps left within single line).
;            Subtest 2: count_accumulator == 0 after Subtest 1.
;            Subtest 3: cursor=1, count=0 (state from Subtest 1);
;                       motion_h → cursor=0 (moved by 1, NOT by
;                       prior 5; motion_apply_count's count==0
;                       default-to-1 path is the load-bearing
;                       branch).
;
; AC reference: AC6 (story 2.7 Sub 3.3).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — Subtest 1: cursor_offset != 1
;   0x81 — Subtest 2: count_accumulator not cleared
;   0x82 — Subtest 3: cursor_offset != 0 (second motion_h moved by 0 or by 5)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 7
    LDIR
    LD      HL, GAP_BUFFER_BASE + 7
    LD      (gap_start), HL

    LD      HL, 6
    LD      (cursor_offset), HL
    LD      HL, 5
    LD      (count_accumulator), HL

    ;; Subtest 1: counted motion_h with count=5.
    LD      A, 'h'
    CALL    motion_h

    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor1
    LD      A, (cursor_offset)
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.ok_cursor1:

    ;; Subtest 2: count cleared.
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x81
    JP      test_fail
.ok_count:

    ;; Subtest 3: second motion_h (with count=0) must move by 1.
    LD      A, 'h'
    CALL    motion_h

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor2
    LD      A, L
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_cursor2:

    JP      test_pass

.payload:
    DEFB    "abcdefg"

    INCLUDE "../inc/test_epilogue.inc"

    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
