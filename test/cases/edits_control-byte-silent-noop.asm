; ============================================================
; Module: test/cases/edits_control-byte-silent-noop.asm
; Purpose: AC11 — control bytes (< 0x20, NOT Esc / Backspace /
;          Enter) in INSERT mode are silent no-ops. Pre-load
;          "abc", cursor=1, mode=INSERT, buffer_dirty=0. Drive
;          0x05 (ENQ — NOT in dispatch_insert table) via
;          dispatch_key. Path: dispatch_insert miss → unbound_insert
;          → JP edits_insert_literal → CP 0x20 / RET C — silent.
;          Assert cursor=1 (no advance), buffer unchanged,
;          buffer_dirty=0.
;
; AC reference: AC11 (control bytes silent no-op).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset changed from 1
;   0x81 — buffer content changed (B = mismatch index)
;   0x82 — buffer_dirty changed from 0
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

    LD      HL, 1
    LD      (cursor_offset), HL

    LD      A, MODE_INSERT
    LD      (mode_byte), A

    ;; Drive 0x05 (ENQ) through dispatch_insert (will miss → unbound_insert → edits_insert_literal → silent).
    LD      HL, dispatch_insert
    LD      B, DISPATCH_INSERT_COUNT
    LD      A, 0x05
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

    LD      HL, 0
    LD      DE, .payload
    LD      B, 3
.cmp_loop:
    PUSH    DE
    CALL    motion_byte_at_logical
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .cmp_next
    LD      A, 3
    SUB     B
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x82
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
