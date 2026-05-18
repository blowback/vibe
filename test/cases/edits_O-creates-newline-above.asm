; ============================================================
; Module: test/cases/edits_O-creates-newline-above.asm
; Purpose: Canonical Story 2.8 test 4 — `O` opens a new line above.
;          Pre-load "hello\nworld" (11 B); cursor=8 ('r' of
;          "world", mid-line 2); CALL edits_open_above. Trace:
;          motion_find_line_start(8) → HL=6 (BOL of line 2);
;          insert LF at 6 → buffer "hello\n\nworld" (12 B);
;          gapbuf_insert advances cursor to 7; DEC → cursor=6
;          (ON the just-inserted LF; new empty line above
;          original line 2). Mode → INSERT.
;
; AC reference: AC4 (O opens line above), AC9 (buffer_dirty).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 6 post-handler
;   0x81 — mode_byte != MODE_INSERT post-handler
;   0x82 — buffer content != "hello\n\nworld" (B = mismatch index)
;   0x83 — buffer_dirty != 1
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
    LD      BC, 11
    LDIR
    LD      HL, GAP_BUFFER_BASE + 11
    LD      (gap_start), HL

    LD      HL, 8
    LD      (cursor_offset), HL

    LD      A, 'O'
    CALL    edits_open_above

    LD      HL, (cursor_offset)
    LD      DE, 6
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

    LD      A, (mode_byte)
    CP      MODE_INSERT
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_mode:

    LD      HL, 0
    LD      DE, .expected
    LD      B, 12
.cmp_loop:
    PUSH    DE
    CALL    motion_byte_at_logical
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .cmp_next
    LD      A, 12
    SUB     B
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_dirty:

    JP      test_pass

.payload:
    DEFB    "hello",0x0A,"world"
.expected:
    DEFB    "hello",0x0A,0x0A,"world"

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
