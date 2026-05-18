; ============================================================
; Module: test/cases/edits_dd-counted-3lines.asm
; Purpose: AC3 canonical — `3dd` on `"a\nb\nc\nd\ne"` (9 B),
;          cursor=0, count_accumulator=3. CALL op_dd. Assert:
;          buffer = "d\ne" (3 B); cursor=0; buffer_dirty=1;
;          yank_kind=KIND_LINE; yank_length=6 ("a\nb\nc\n");
;          count_accumulator=0 (cleared by parser_clear).
;
; AC reference: AC3 (counted form, regular case); AC12 canonical-3
;          (epic spec line 1335).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor != 0
;   0x81 — buffer != "d\ne" (B = index)
;   0x82 — buffer_dirty != 1
;   0x83 — yank_kind != KIND_LINE
;   0x84 — yank_length != 6
;   0x85 — count_accumulator != 0 post-call
;   0x86 — yank_buffer contents != "a\nb\nc\n" (B = index)
;
; Code review patch (2026-05-16): added yank_buffer byte-content
; assertion. The original test pinned yank_length=6 and yank_kind
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

    LD      HL, 3
    LD      (count_accumulator), HL

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 9
    LDIR
    LD      HL, GAP_BUFFER_BASE + 9
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

    LD      A, (yank_kind)
    CP      KIND_LINE
    JR      Z, .ok_kind
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_kind:

    LD      HL, (yank_length)
    LD      DE, 6
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

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x85
    JP      test_fail
.ok_count:

    ;; Pin yank_buffer contents = "a\nb\nc\n" (6 bytes).
    LD      HL, yank_buffer
    LD      DE, .expected_yank
    LD      B, 6
.ycmp_loop:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 6
    SUB     B
    LD      B, A
    LD      A, 0x86
    JP      test_fail
.ycmp_next:
    INC     HL
    INC     DE
    DJNZ    .ycmp_loop

    JP      test_pass

.payload:
    DEFB    "a", 0x0A, "b", 0x0A, "c", 0x0A, "d", 0x0A, "e"
.expected:
    DEFB    "d", 0x0A, "e"
.expected_yank:
    DEFB    "a", 0x0A, "b", 0x0A, "c", 0x0A

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
