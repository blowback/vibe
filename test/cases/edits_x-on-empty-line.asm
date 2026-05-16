; ============================================================
; Module: test/cases/edits_x-on-empty-line.asm
; Purpose: AC3 — `x` on the LF byte of an empty line is a silent
;          no-op (buffer unchanged, buffer_dirty unchanged, parser
;          state cleared per AC3 hygiene). Pre-load "\ndef" (4 B),
;          cursor=0 (on the LF). Pre-seed buffer_dirty=0,
;          pending_operator/pending_motion_prefix/count to
;          NONZERO so the parser_clear assertion is meaningful.
;          CALL edits_delete_char. Assert cursor=0, buffer
;          unchanged, buffer_dirty=0, parser state all 0.
;
; AC reference: AC3 (empty-line no-op + AC5 buffer_dirty
;          unchanged on no-op path).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 0
;   0x81 — buffer content changed (B = mismatch index)
;   0x82 — buffer_dirty changed (not 0)
;   0x83 — count_accumulator != 0
;   0x84 — pending_operator != 0
;   0x85 — pending_motion_prefix != 0
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

    ;; Pre-seed parser state to NONZERO so parser_clear is
    ;; demonstrably effective (Story 2.6 lesson re vacuous
    ;; count==0 assertions).
    LD      HL, 7
    LD      (count_accumulator), HL
    LD      A, 'd'
    LD      (pending_operator), A
    LD      A, 'g'
    LD      (pending_motion_prefix), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 4
    LDIR
    LD      HL, GAP_BUFFER_BASE + 4
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    edits_delete_char

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x80
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

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x83
    JP      test_fail
.ok_count:

    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok_op
    LD      B, A
    LD      A, 0x84
    JP      test_fail
.ok_op:

    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok_prefix
    LD      B, A
    LD      A, 0x85
    JP      test_fail
.ok_prefix:

    JP      test_pass

.payload:
    DEFB    0x0A, "def"
.expected:
    DEFB    0x0A, "def"

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
