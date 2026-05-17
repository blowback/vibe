; ============================================================
; Module: test/cases/edits_p-into-empty-buffer.asm
; Purpose: AC10 additional — KIND_CHAR paste into an empty buffer.
;          Pre-load: `gapbuf_init` only (file_length=0), cursor=0.
;          Pre-seed yank: KIND_CHAR, len=3, content="xyz". CALL
;          op_paste. Trace: pre-paste motion_byte_at_logical(0)
;          returns CF=1 (past EOF, file empty) → no advance; insert
;          "xyz" at cursor=0 → cursor=3 post-insert; DEC cursor → 2.
;          Assert: buffer="xyz" (3 B); cursor=2 (on 'z'); buffer_dirty=1.
;
;          Pins: AC4 past-EOF no-advance branch on empty buffer;
;          DEC HL post-insert safe when yank_length >= 1 (AC2
;          empty-yank guard prevents yank_length=0 from reaching).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x90 — cursor_offset != 2
;   0x91 — buffer content != "xyz" (B = mismatch index)
;   0x92 — buffer_dirty != 1
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

    ;; Empty buffer.
    CALL    gapbuf_init

    LD      A, KIND_CHAR
    LD      (yank_kind), A
    LD      HL, 3
    LD      (yank_length), HL
    LD      HL, .yank_content
    LD      DE, yank_buffer
    LD      BC, 3
    LDIR

    CALL    op_paste

    LD      HL, (cursor_offset)
    LD      DE, 2
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x90
    JP      test_fail
.ok_cursor:

    LD      HL, 0
    LD      DE, .expected
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
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x92
    JP      test_fail
.ok_dirty:

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

.yank_content:
    DEFB    "xyz"
.expected:
    DEFB    "xyz"

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
