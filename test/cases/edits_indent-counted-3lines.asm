; ============================================================
; Module: test/cases/edits_indent-counted-3lines.asm
; Purpose: `3>>` on "a\nb\nc\nd" (7 B), cursor=0, pending_operator='>',
;          count=3. CALL parser_doubled_operator_stub. Exercises
;          counted line-bounded indent.
;
; edits_line_range_for_count walks 3 LFs → range [0, 6) = "a\nb\nc\n".
; edits_indent_walk inserts INDENT_BYTE at line 1, 2, 3 starts (line 4
; untouched).
;
; Assert: buffer=" a\n b\n c\nd" (10 B); buffer_dirty=1.
;
; Sentinel codes:
;   0x80 — buffer mismatch (B = mismatch index)
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
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A
    LD      (buffer_dirty), A
    LD      A, '>'
    LD      (pending_operator), A
    LD      HL, 3
    LD      (count_accumulator), HL
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 7
    LDIR
    LD      HL, GAP_BUFFER_BASE + 7
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    CALL    parser_doubled_operator_stub

    LD      HL, 0
    LD      DE, .expected
    LD      B, 10
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
    LD      A, 10
    SUB     B
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_dirty:

    JP      test_pass

.payload:
    DEFB    "a", 0x0A, "b", 0x0A, "c", 0x0A, "d"
.expected:
    DEFB    " a", 0x0A, " b", 0x0A, " c", 0x0A, "d"

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
