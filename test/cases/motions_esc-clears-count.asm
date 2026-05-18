; ============================================================
; Module: test/cases/motions_esc-clears-count.asm
; Purpose: AC7 — Esc at NORMAL with a partial count cancels the
;          count without dispatching a motion. Esc is NOT bound
;          in dispatch_normal → falls through to unbound_normal,
;          which tail-JPs parser_clear (Story 2.5 AC13 patch).
;          Buffer "abc"; pre-set cursor=1, count=3, mode_byte=
;          MODE_NORMAL. Drive A=0x1B (Esc) through dispatch_key.
;          Post: count=0, mode_byte unchanged, cursor unchanged.
;
; AC reference: AC7 (story 2.7 Sub 3.4). Companion to the
;               existing motions_parser-clear-on-unbound.asm
;               (Story 2.5 AC13) but specifically pins the
;               count-only-no-motion + Esc path through
;               dispatch_key, exercising the AR3 sparse-table
;               fall-through convention.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — count_accumulator != 0 post-Esc
;   0x81 — mode_byte != MODE_NORMAL (Esc must not transition modes)
;   0x82 — cursor_offset != 1 (Esc must not move cursor)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    LD      A, MODE_NORMAL
    LD      (mode_byte), A
    XOR     A
    LD      (status_dirty), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 1
    LD      (cursor_offset), HL
    LD      HL, 3
    LD      (count_accumulator), HL

    ;; Drive Esc through dispatch_key against dispatch_normal.
    LD      A, 0x1B                     ; Esc
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_count:

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_mode:

    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor
    LD      A, (cursor_offset)
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_cursor:

    JP      test_pass

.payload:
    DEFB    "abc"

    INCLUDE "../inc/test_epilogue.inc"

    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
