; ============================================================
; Module: test/cases/undo_nothing-to-undo.asm
; Purpose: AC5 — bare `u` from cold-state (undo_kind=EMPTY) shows
;          msg_nothing_to_undo + leaves buffer/cursor/buffer_dirty
;          UNCHANGED + clears parser. Pre-load "abc", cursor=0,
;          undo_kind=UNDO_KIND_EMPTY (cold-start state). CALL
;          op_undo. Assert buffer unchanged + cursor=0 +
;          buffer_dirty=0 + status_buffer prefix = "nothing to undo"
;          + parser cleared.
;
; AC reference: AC5 (empty path); AC10 (msg_nothing_to_undo via
;          status_set_message). FR46 nothing-to-undo path.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xC4 — sub-code: 0=cursor moved, 1=buffer_dirty set, 2=undo_kind
;          changed, 3=status_buffer mismatch (B = byte index of
;          first mismatch in "nothing to undo"), 4=parser not cleared
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
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (undo_kind), A              ; UNDO_KIND_EMPTY (cold-start)

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 0                       ; cursor at 0
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    op_undo

    ;; Cursor unchanged at 0.
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, 0
    LD      A, 0xC4
    JP      test_fail
.ok_cursor:

    ;; buffer_dirty still 0.
    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, 1
    LD      A, 0xC4
    JP      test_fail
.ok_dirty:

    ;; undo_kind still EMPTY.
    LD      A, (undo_kind)
    OR      A
    JR      Z, .ok_kind
    LD      B, 2
    LD      A, 0xC4
    JP      test_fail
.ok_kind:

    ;; status_buffer prefix == "nothing to undo".
    LD      HL, status_buffer
    LD      DE, .expected_msg
    LD      B, 15                       ; "nothing to undo" = 15 bytes
.msg_loop:
    LD      A, (DE)
    LD      C, A
    LD      A, (HL)
    CP      C
    JR      Z, .msg_next
    LD      A, 15
    SUB     B
    LD      B, A                        ; B = byte index of mismatch
    LD      A, 0xC4
    JP      test_fail
.msg_next:
    INC     HL
    INC     DE
    DJNZ    .msg_loop

    ;; Parser cleared (pending_operator + pending_motion_prefix + count_accumulator all 0).
    LD      A, (pending_operator)
    OR      A
    JR      NZ, .parser_fail
    LD      A, (pending_motion_prefix)
    OR      A
    JR      NZ, .parser_fail
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_parser
.parser_fail:
    LD      B, 4
    LD      A, 0xC4
    JP      test_fail
.ok_parser:

    JP      test_pass

.payload:
    DEFB    "abc"
.expected_msg:
    DEFB    "nothing to undo"

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
