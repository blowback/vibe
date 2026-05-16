; ============================================================
; Module: test/cases/motions_parser-clear-on-unbound.asm
; Purpose: AC13 — verify unbound_normal clears parser state.
;          Resolves the deferred-work line 89-90 concern that
;          unbound keys in NORMAL leave count / operator / prefix
;          stale (the `5 g x` then `g` → spurious gg-stub
;          scenario).
;
;          Pre-set count=5, operator='d', prefix='g'; CALL
;          unbound_normal; assert all three zeroed.
;
; AC reference: AC13 (Story 2.5 Sub 7.16).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x81 — count_accumulator not cleared
;   0x82 — pending_operator not cleared
;   0x83 — pending_motion_prefix not cleared
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
    LD      HL, 5
    LD      (count_accumulator), HL
    LD      A, 'd'
    LD      (pending_operator), A
    LD      A, 'g'
    LD      (pending_motion_prefix), A

    ;; Drive an unbound key.
    LD      A, 0x40                     ; '@' is unbound in NORMAL
    CALL    unbound_normal

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x81
    JP      test_fail
.ok_count:

    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok_op
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_op:

    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok_prefix
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_prefix:

    JP      test_pass

    INCLUDE "../inc/test_epilogue.inc"

    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
