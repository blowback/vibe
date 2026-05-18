; ============================================================
; Module: test/cases/edits_dd-only-line.asm
; Purpose: AC2 last-line-no-LF + S==0 case — `"hello"` (5 B;
;          single line, no LF), cursor=0. CALL op_dd. Per AC2:
;          delete range = [0, file_length) = [0, 5). Assert:
;          buffer empty (file_length=0); cursor=0; buffer_dirty=1;
;          yank_kind=KIND_LINE; yank_length=5 ("hello");
;          gap_start = GAP_BUFFER_BASE (empty before-gap);
;          gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX (empty
;          buffer = fully gap).
;
; AC reference: AC2 single-line buffer case ("If S == 0 [...] the
;          delete range is [0, file_length)").
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor != 0
;   0x81 — file not empty (motion_byte_at_logical(0) did not return CF=1)
;   0x82 — buffer_dirty != 1
;   0x83 — yank_kind != KIND_LINE
;   0x84 — yank_length != 5
;   0x85 — yank_buffer mismatch (B = index)
;   0x86 — gap_start != GAP_BUFFER_BASE OR gap_end != base + MAX
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
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

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

    LD      HL, yank_buffer
    LD      DE, .yank_expected
    LD      B, 5
.ycmp:
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
    DJNZ    .ycmp

    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      NZ, .gap_fail
    LD      HL, (gap_end)
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .gap_ok
.gap_fail:
    LD      A, 0x86
    JP      test_fail
.gap_ok:

    JP      test_pass

.payload:
    DEFB    "hello"
.yank_expected:
    DEFB    "hello"

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
