; ============================================================
; Module: test/cases/edits_dispatch-insert-routes-backspace.asm
; Purpose: AC12 regression net — verify 0x08 (Backspace) routes
;          through dispatch_insert's binary search to
;          edits_insert_backspace. Pre-2.8 dispatch_insert held
;          1 entry (Esc → enter_normal_mode); 2.8 grew it to 3
;          (BS / Enter / Esc). The existing edits_backspace-*
;          tests CALL edits_insert_backspace directly; this
;          test pins the dispatch route so a future re-stitch
;          (wrong adjacent ASSERT, wrong handler address) can't
;          silently break it.
;
;          Pre-state: "abc", cursor=2, mode=INSERT, buffer_dirty=0.
;          Drive 0x08 via dispatch_key against dispatch_insert.
;          Path: binary search finds 0x08 → edits_insert_backspace
;          → gapbuf_delete → cursor=1; edits_dirty_and_redraw →
;          buffer_dirty=1.
;
; AC reference: AC12 (dispatch_insert table growth).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 1 (binary search miss / wrong handler)
;   0x81 — buffer_dirty != 1
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (status_dirty), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (buffer_dirty), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 2
    LD      (cursor_offset), HL

    LD      A, MODE_INSERT
    LD      (mode_byte), A

    ;; Drive 0x08 (Backspace) through dispatch_insert.
    LD      HL, dispatch_insert
    LD      B, DISPATCH_INSERT_COUNT
    LD      A, 0x08
    CALL    dispatch_key

    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_cursor:

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_dirty:

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
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
