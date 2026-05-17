; ============================================================
; Module: test/cases/edits_dd-counted-clamps-at-eof.asm
; Purpose: AC3 BH2-line-level clamp — `100dd` on `"a\nb\nc"`
;          (5 B; 3 lines), cursor=0. Per AC3 walk: iter 1 LF at 1;
;          iter 2 LF at 3; iter 3 hits last-line-no-LF (file_length=5).
;          With S=0 and last_line_was_eof, delete range = [0, 5).
;          Assert: buffer empty; cursor=0; buffer_dirty=1;
;          yank_length=5; yank_kind=KIND_LINE.
;
; AC reference: AC3 (counted form with BH2-line-level clamp at EOF).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor != 0
;   0x81 — buffer not empty
;   0x82 — buffer_dirty != 1
;   0x83 — yank_kind != KIND_LINE
;   0x84 — yank_length != 5
;   0x85 — yank_buffer contents != "a\nb\nc" (B = index)
;
; Code review patch (2026-05-16): added yank_buffer byte-content
; assertion. The original test pinned yank_length=5 and yank_kind
; but not the actual bytes copied — a regression that wrote zeros
; or read from the wrong source range would have passed.
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

    LD      HL, 100
    LD      (count_accumulator), HL

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 5
    LDIR
    LD      HL, GAP_BUFFER_BASE + 5
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    CALL    op_dd

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_cursor:

    LD      HL, 0
    CALL    motion_byte_at_logical
    JR      C, .ok_empty
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_empty:

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_dirty:

    LD      A, (yank_kind)
    CP      KIND_LINE
    JR      Z, .ok_kind
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_kind:

    LD      HL, (yank_length)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_length
    LD      HL, (yank_length)
    LD      B, L
    LD      A, 0x84
    JP      test_fail
.ok_length:

    ;; Pin yank_buffer contents = "a\nb\nc" (5 bytes; last line has no LF).
    LD      HL, yank_buffer
    LD      DE, .expected_yank
    LD      B, 5
.ycmp_loop:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 5
    SUB     B
    LD      B, A
    LD      A, 0x85
    JP      test_fail
.ycmp_next:
    INC     HL
    INC     DE
    DJNZ    .ycmp_loop

    JP      test_pass

.payload:
    DEFB    "a", 0x0A, "b", 0x0A, "c"
.expected_yank:
    DEFB    "a", 0x0A, "b", 0x0A, "c"

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
