; ============================================================
; Module: test/cases/edits_dedent-removes-leading-space.asm
; Purpose: `<<` on " abc" (4 B; leading space), cursor=1 ('a'),
;          pending_operator='<'. Exercises dedent's successful delete:
;          line has leading INDENT_BYTE; gapbuf_delete removes it.
;
; Implementation choice (per AC9 / story spec): cursor restored to
; entry value AS-IS (= 1). After deletion of leading byte, the byte
; originally at offset 1 ('a') is now at offset 0, and offset 1 holds
; what was at offset 2 ('b'). The "stays-at-1" semantic means cursor
; logically points to 'b' post-dedent.
;
; Assert: buffer="abc" (3 B); buffer_dirty=1; cursor=1.
;
; Sentinel codes:
;   0x80 — buffer mismatch
;   0x81 — buffer_dirty != 1
;   0x82 — cursor != 1
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
    LD      BC, 4
    LDIR
    LD      HL, GAP_BUFFER_BASE + 4
    LD      (gap_start), HL

    LD      HL, 1
    LD      (cursor_offset), HL

    CALL    parser_doubled_operator_stub

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

    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x82
    JP      test_fail
.ok_cursor:

    JP      test_pass

.payload:
    DEFB    " abc"
.expected:
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

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
