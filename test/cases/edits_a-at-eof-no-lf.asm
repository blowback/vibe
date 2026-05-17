; ============================================================
; Module: test/cases/edits_a-at-eof-no-lf.asm
; Purpose: AC2 — `a` on the last printable byte of a file with no
;          trailing LF advances cursor to file_length. Pre-load
;          "hello" (5 B, no LF), cursor=4 ('o'). CALL
;          edits_enter_insert_after; assert cursor=5 (file_length).
;          Then drive literal 'X'; assert buffer "helloX" (6 B),
;          cursor=6 (file_length+1).
;
; AC reference: AC2 (a EOF rule), AC5 (literal insert).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 5 after `a`
;   0x81 — cursor_offset != 6 after 'X' insert
;   0x82 — buffer content != "helloX" (B = mismatch index)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (buffer_dirty), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 5
    LDIR
    LD      HL, GAP_BUFFER_BASE + 5
    LD      (gap_start), HL

    LD      HL, 4
    LD      (cursor_offset), HL

    LD      A, 'a'
    CALL    edits_enter_insert_after

    LD      HL, (cursor_offset)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor_a
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_cursor_a:

    LD      A, 'X'
    CALL    edits_insert_literal

    LD      HL, (cursor_offset)
    LD      DE, 6
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor_X
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x81
    JP      test_fail
.ok_cursor_X:

    LD      HL, 0
    LD      DE, .expected
    LD      B, 6
.cmp_loop:
    PUSH    DE
    CALL    motion_byte_at_logical
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .cmp_next
    LD      A, 6
    SUB     B
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    JP      test_pass

.payload:
    DEFB    "hello"
.expected:
    DEFB    "helloX"

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
