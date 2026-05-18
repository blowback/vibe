; ============================================================
; Module: test/cases/edits_3p-counted.asm
; Purpose: AC10 canonical-5 — counted KIND_CHAR paste. Pre-load
;          `"a"` (1 B), cursor=0. Pre-seed yank: KIND_CHAR, len=1,
;          content="b". Pre-seed count_accumulator=3 (simulating
;          prior `3` parse). CALL op_paste. Assert: buffer="abbb"
;          (4 B — 3 copies of "b" inserted after 'a'); cursor=3
;          (on last 'b' — last byte of FULL inserted range);
;          buffer_dirty=1; count_accumulator=0 (cleared by tail
;          parser_clear); parser cleared.
;
;          Pins: counted paste runs N inner copies of yank content;
;          cursor on LAST byte of FULL inserted range (not last byte
;          of single copy). State-read-before-clear discipline:
;          motion_apply_count reads count BEFORE tail-JP parser_clear.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x90 — cursor_offset != 3
;   0x91 — buffer content != "abbb" (B = mismatch index)
;   0x92 — buffer_dirty != 1
;   0x95 — parser state not cleared (count_accumulator or pending)
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
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 1
    LDIR
    LD      HL, GAP_BUFFER_BASE + 1
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, KIND_CHAR
    LD      (yank_kind), A
    LD      HL, 1
    LD      (yank_length), HL
    LD      HL, .yank_content
    LD      DE, yank_buffer
    LD      BC, 1
    LDIR

    ;; Pre-seed count_accumulator=3.
    LD      HL, 3
    LD      (count_accumulator), HL

    CALL    op_paste

    LD      HL, (cursor_offset)
    LD      DE, 3
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
    LD      B, 4
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
    LD      A, 4
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

.payload:
    DEFB    "a"
.yank_content:
    DEFB    "b"
.expected:
    DEFB    "abbb"

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
