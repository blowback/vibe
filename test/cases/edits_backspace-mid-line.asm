; ============================================================
; Module: test/cases/edits_backspace-mid-line.asm
; Purpose: AC6 — Backspace mid-line deletes byte before cursor.
;          Pre-load "abcdef" (6 B), cursor=3, mode=INSERT. CALL
;          edits_insert_backspace. Assert buffer="abdef" (5 B),
;          cursor=2, buffer_dirty=1, mode unchanged.
;
; AC reference: AC6 (Backspace deletes byte before cursor).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 2 post-backspace
;   0x81 — buffer content != "abdef" (B = mismatch index)
;   0x82 — buffer_dirty != 1
;   0x83 — mode_byte not preserved at MODE_INSERT
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

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 6
    LDIR
    LD      HL, GAP_BUFFER_BASE + 6
    LD      (gap_start), HL

    LD      HL, 3
    LD      (cursor_offset), HL

    LD      A, MODE_INSERT
    LD      (mode_byte), A

    CALL    edits_insert_backspace

    LD      HL, (cursor_offset)
    LD      DE, 2
    OR      A
    SBC     HL, DE
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
    LD      B, 5
.cmp_loop:
    PUSH    DE
    CALL    motion_byte_at_logical
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .cmp_next
    LD      A, 5
    SUB     B
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_dirty:

    LD      A, (mode_byte)
    CP      MODE_INSERT
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_mode:

    JP      test_pass

.payload:
    DEFB    "abcdef"
.expected:
    DEFB    "abdef"

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
