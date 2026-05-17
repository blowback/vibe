; ============================================================
; Module: test/cases/edits_x-at-eof.asm
; Purpose: AC2 canonical — `x` at last printable byte of file
;          consumes that byte; cursor clamps back to new EOF-1.
;          Pre-load "hello" (5 B, no trailing LF), cursor=4
;          (on 'o', the last printable byte). CALL edits_delete_char.
;          Assert buffer="hell" (4 B), cursor=3 ('l'), buffer_dirty=1.
;
; AC reference: AC2 (EOF clamp); AC11 canonical-2 (epics line 1289).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 3 (clamp from 4 → 3)
;   0x81 — buffer content != "hell" (B = mismatch index)
;   0x82 — buffer_dirty != 1
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

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 5
    LDIR
    LD      HL, GAP_BUFFER_BASE + 5
    LD      (gap_start), HL

    LD      HL, 4
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    edits_delete_char

    ;; Cursor must clamp from 4 → 3 (file_length now 4; was on
    ;; the last printable byte; post-delete the cursor is past
    ;; EOF so the AC2 clamp dec's it back onto 'l').
    LD      HL, (cursor_offset)
    LD      DE, 3
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
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_dirty:

    JP      test_pass

.payload:
    DEFB    "hello"
.expected:
    DEFB    "hell"

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
