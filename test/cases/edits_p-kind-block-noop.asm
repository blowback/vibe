; ============================================================
; Module: test/cases/edits_p-kind-block-noop.asm
; Purpose: AC10 additional — KIND_BLOCK silent no-op guard.
;          Pre-load `"abc"` (3 B), cursor=0. Pre-seed yank:
;          KIND_BLOCK, len=2, content="XY". CALL op_paste. The
;          AC6 KIND_BLOCK guard fires (yank_kind == KIND_BLOCK)
;          → JP parser_clear directly. Assert: buffer UNCHANGED;
;          cursor=0 (unchanged); buffer_dirty UNCHANGED from
;          pre-seed (0); status_dirty UNCHANGED (silent — per Q3
;          pin); parser cleared.
;
;          Pins: AC6 KIND_BLOCK guard. Silent path (no
;          msg_not_implemented) per Q3 pin — saves ~6 B.
;          KIND_BLOCK is reserved for Epic 3 visual-block; no
;          user-input path reaches it in MVP; the guard exists
;          to defend against corrupt state.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x90 — cursor_offset != 0
;   0x91 — buffer content changed (B = mismatch index)
;   0x92 — buffer_dirty was modified (must stay 0)
;   0x97 — status_dirty was modified (must stay 0 — silent)
;   0x95 — parser state not cleared
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
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, KIND_BLOCK
    LD      (yank_kind), A
    LD      HL, 2
    LD      (yank_length), HL
    LD      HL, .yank_content
    LD      DE, yank_buffer
    LD      BC, 2
    LDIR

    CALL    op_paste

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, L
    LD      A, 0x90
    JP      test_fail
.ok_cursor:

    LD      HL, 0
    LD      DE, .payload
    LD      B, 3
.cmp_loop:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .cmp_next
    LD      A, 3
    SUB     B
    LD      B, A
    LD      A, 0x91
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x92
    JP      test_fail
.ok_dirty:

    LD      A, (status_dirty)
    OR      A
    JR      Z, .ok_status_dirty
    LD      B, A
    LD      A, 0x97
    JP      test_fail
.ok_status_dirty:

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
    LD      A, 0x95
    JP      test_fail
.parser_ok:

    JP      test_pass

.payload:
    DEFB    "abc"
.yank_content:
    DEFB    "XY"

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
