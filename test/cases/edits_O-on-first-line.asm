; ============================================================
; Module: test/cases/edits_O-on-first-line.asm
; Purpose: AC4 line-1 corner — `O` on the first line inserts an LF
;          at offset 0; cursor decrements back to 0. Pre-load
;          "hello\nworld" (11 B), cursor=2. CALL edits_open_above.
;          Trace: motion_find_line_start(2) → HL=0; insert LF at 0
;          → buffer "\nhello\nworld" (12 B), cursor advances to 1;
;          DEC → cursor=0. Mode → INSERT.
;
; AC reference: AC4 (O on first line).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 0 post-handler
;   0x81 — buffer content != "\nhello\nworld" (B = mismatch index)
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

    LD      HL, 2
    LD      (cursor_offset), HL

    LD      A, 'O'
    CALL    edits_open_above

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
    LD      A, 0x81
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    JP      test_pass

.payload:
    DEFB    "hello",0x0A,"world"
.expected:
    DEFB    0x0A,"hello",0x0A,"world"

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
