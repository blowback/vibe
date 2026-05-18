; ============================================================
; Module: test/cases/edits_esc-from-insert-clears-parser-state.asm
; Purpose: AC7 + Story 2.5 AC13 regression net — Esc from INSERT
;          via dispatch_insert[0x1B] routes to enter_normal_mode
;          which tail-JPs parser_clear. Pre-seed count_accumulator
;          = 5, pending_operator='d', pending_motion_prefix='g',
;          mode=INSERT (a stale-state shape that could not occur
;          naturally but pins the parser_clear invariant). Drive
;          Esc through dispatch_key. Assert all three parser-state
;          fields zeroed; mode=NORMAL.
;
; AC reference: AC7 (Esc returns to NORMAL); Story 2.5 AC13
;               (mode-change tail-JP parser_clear).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — count_accumulator != 0 post-Esc
;   0x81 — pending_operator != 0 post-Esc
;   0x82 — pending_motion_prefix != 0 post-Esc
;   0x83 — mode_byte != MODE_NORMAL post-Esc
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (status_dirty), A
    LD      (buffer_dirty), A

    CALL    gapbuf_init

    LD      HL, 5
    LD      (count_accumulator), HL
    LD      A, 'd'
    LD      (pending_operator), A
    LD      A, 'g'
    LD      (pending_motion_prefix), A

    LD      A, MODE_INSERT
    LD      (mode_byte), A

    ;; Drive 0x1B (Esc) via dispatch_key against dispatch_insert.
    LD      HL, dispatch_insert
    LD      B, DISPATCH_INSERT_COUNT
    LD      A, 0x1B
    CALL    dispatch_key

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_count:

    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok_op
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_op:

    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok_prefix
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_prefix:

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_mode:

    JP      test_pass

    INCLUDE "../inc/test_epilogue.inc"

    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
