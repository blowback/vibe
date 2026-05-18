; ============================================================
; Module: test/cases/edits_dd-empty-buffer.asm
; Purpose: AC2 no-op path — empty buffer (file_length=0), cursor=0.
;          Pre-seed yank_kind=0xEE / yank_length=0xCAFE / buffer_dirty=0
;          so we can prove the no-op path doesn't touch them. CALL
;          op_dd. Assert: buffer still empty; cursor=0; buffer_dirty
;          UNCHANGED; yank_kind UNCHANGED (== 0xEE); yank_length
;          UNCHANGED (== 0xCAFE); parser_clear ran.
;
; AC reference: AC2 / AC3 no-op shape (total_bytes=0 guard at
;          op_dd's top → JP parser_clear; matches the Story 2.9
;          no-op pattern).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor != 0
;   0x81 — buffer not empty
;   0x82 — buffer_dirty was modified
;   0x83 — yank_kind was modified
;   0x84 — yank_length was modified
;   0x85 — parser state not cleared
;   0x86 — status_dirty was modified (no-op path must be silent)
;
; Code review patch (2026-05-16): the original test pre-zeroed
; parser-state fields, making the "parser_clear ran" assertion
; vacuous (a regression replacing parser_clear with RET would
; have passed). Pre-seed pending_operator='d', pending_motion_prefix
; ='g', count_accumulator=5 so the post-call zero assertion is
; load-bearing; also pre-seed status_dirty=0x80 and assert it is
; UNCHANGED post-call (the 0-byte no-op path must be silent — it
; does NOT surface a status message).
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (buffer_dirty), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; Pre-seed parser-state fields to non-zero so the post-call
    ;; zero assertion is load-bearing (not vacuous).
    LD      A, 'd'
    LD      (pending_operator), A
    LD      A, 'g'
    LD      (pending_motion_prefix), A
    LD      HL, 5
    LD      (count_accumulator), HL

    ;; Pre-seed status_dirty=0x80 sentinel; the 0-byte no-op path
    ;; must be SILENT (does not surface a status message), so this
    ;; sentinel must persist UNCHANGED post-call.
    LD      A, 0x80
    LD      (status_dirty), A

    LD      A, 0xEE
    LD      (yank_kind), A
    LD      HL, 0xCAFE
    LD      (yank_length), HL

    CALL    gapbuf_init                 ; empty buffer

    CALL    op_dd

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_cursor:

    LD      HL, 0
    CALL    motion_byte_at_logical
    JR      C, .ok_empty
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_empty:

    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_dirty:

    LD      A, (yank_kind)
    CP      0xEE
    JR      Z, .ok_kind
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_kind:

    LD      HL, (yank_length)
    LD      DE, 0xCAFE
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_length
    LD      HL, (yank_length)
    LD      B, L
    LD      A, 0x84
    JP      test_fail
.ok_length:

    LD      A, (pending_operator)
    OR      A
    JR      NZ, .parser_fail
    LD      A, (pending_motion_prefix)
    OR      A
    JR      NZ, .parser_fail
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .parser_ok
.parser_fail:
    LD      A, 0x85
    JP      test_fail
.parser_ok:

    ;; status_dirty must still be 0x80 (no-op path is silent).
    LD      A, (status_dirty)
    CP      0x80
    JR      Z, .ok_status
    LD      B, A
    LD      A, 0x86
    JP      test_fail
.ok_status:

    JP      test_pass

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
