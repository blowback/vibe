; ============================================================
; Module: test/cases/edits_dd-deletes-last-line-keeps-lf.asm
; Purpose: AC2 case-3 cursor placement reached via the
;          `.normal_done` arm (LF-terminated buffer where dd
;          deletes the last line). Pre-load `"a\nb\n"` (4 B,
;          two LF-terminated lines), cursor=2 (on 'b').
;
;          Algorithmic trace:
;            S = motion_find_line_start(2) = 2 (byte at 1 is LF,
;            INC → 2).
;            walk_step iter 1: motion_find_line_end(2) finds LF
;            at 3 with CF=0. BC=1 (count default), DEC BC=0 →
;            .normal_done. INC HL=4 = delete_end. total_bytes
;            = 4 - 2 = 2. Range = [2, 4) = "b\n".
;            edits_range_delete: cursor pre-stage 4 → loop 2x
;            gapbuf_delete → cursor=2. file_length now 2 ("a\n").
;            Post-delete probe: motion_byte_at_logical(2) →
;            past-EOF (CF=1), HL=2 != 0 → CASE 3. DEC HL=1.
;            motion_find_line_start(1): byte at 0='a' (not LF),
;            DEC HL=0 → RET Z. Cursor=0.
;
;          Assert: buffer = "a\n" (2 B); cursor=0; buffer_dirty
;          =1; yank_kind=KIND_LINE; yank_length=2; yank_buffer
;          = "b\n".
;
; AC reference: AC2 case-3 post-delete cursor placement via
;          `.normal_done`. Closes the coverage gap surfaced in
;          code review (only `.at_eof`+S>0 currently exercises
;          case 3, via edits_dd-last-line-no-trailing-lf.asm).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor != 0
;   0x81 — buffer != "a\n" (B = index)
;   0x82 — buffer_dirty != 1
;   0x83 — yank_kind != KIND_LINE
;   0x84 — yank_length != 2
;   0x85 — yank_buffer contents != "b\n" (B = index)
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
    LD      BC, 4
    LDIR
    LD      HL, GAP_BUFFER_BASE + 4
    LD      (gap_start), HL

    LD      HL, 2
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
    LD      B, 2
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
    LD      A, 2
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
    LD      DE, 2
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
    LD      DE, .expected_yank
    LD      B, 2
.ycmp_loop:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 2
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
    DEFB    "a", 0x0A, "b", 0x0A
.expected:
    DEFB    "a", 0x0A
.expected_yank:
    DEFB    "b", 0x0A

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
