; ============================================================
; Module: test/cases/edits_dedent-no-op-no-leading-space.asm
; Purpose: `<<` on "abc" (3 B), cursor=0, pending_operator='<'.
;          Exercises dedent's silent-no-op shape: line has no leading
;          INDENT_BYTE → no buffer change, buffer_dirty UNCHANGED.
;
; Assert: buffer UNCHANGED ("abc"); buffer_dirty UNCHANGED (0).
;
; Sentinel codes:
;   0x80 — buffer modified (B = mismatch index)
;   0x81 — buffer_dirty changed
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
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      A, '<'
    LD      (pending_operator), A
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

    CALL    parser_doubled_operator_stub

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
    LD      A, 0x80
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      A, (buffer_dirty)
    OR      A
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
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
