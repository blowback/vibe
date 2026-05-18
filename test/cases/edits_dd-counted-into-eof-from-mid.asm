; ============================================================
; Module: test/cases/edits_dd-counted-into-eof-from-mid.asm
; Purpose: AC3 counted walk that arrives at `.at_eof` mid-N
;          with S>0 — the algorithmically interesting walk
;          shape per the spec's third trace. Pre-load
;          `"a\nb\nc"` (5 B; 3 lines; last line "c" no LF),
;          cursor=2 (on 'b'), count=3.
;
;          Algorithmic trace:
;            S = motion_find_line_start(2) = 2. Walker=HL=2; BC=3.
;            iter 1: motion_find_line_end(2): byte at 2='b' (not
;            LF), INC HL=3, byte at 3=LF → RET HL=3 CF=0. DEC BC=2
;            (not zero), INC HL=4 → walk_step.
;            iter 2: motion_find_line_end(4): byte at 4='c' (not
;            LF), INC HL=5, byte at 5 past-EOF (CF=1) → RET HL=5
;            =file_length. JR C → .at_eof. EX DE,HL: DE=5. POP HL
;            =S=2. S>0 → DEC HL=1=delete_start. PUSH HL. EX DE,HL:
;            HL=5, DE=1. SBC HL,DE=4=total_bytes. BC=4. POP HL=1.
;            Range = [1, 5) = "\nb\nc" (4 bytes incl. cross-line LF).
;            edits_range_delete: cursor pre-stage 5 → loop 4x →
;            cursor=1. file_length now 1 ("a").
;            Post-delete probe: motion_byte_at_logical(1) → past-
;            EOF (CF=1), HL=1 != 0 → CASE 3. DEC HL=0.
;            motion_find_line_start(0): HL=0 → RET Z. Cursor=0.
;
;          Assert: buffer = "a" (1 B); cursor=0; buffer_dirty=1;
;          yank_kind=KIND_LINE; yank_length=4; yank_buffer
;          = "\nb\nc".
;
; AC reference: AC3 (counted form + last-line-no-LF + S>0 +
;          mid-walk `.at_eof`). Closes the coverage gap surfaced
;          in code review — the `.at_eof`+S>0 branch is reached
;          only via cursor=0 / S=0 in edits_dd-counted-clamps-at-
;          eof.asm; the mid-N + S>0 combination is unique to this
;          test.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor != 0
;   0x81 — buffer != "a" (B = index)
;   0x82 — buffer_dirty != 1
;   0x83 — yank_kind != KIND_LINE
;   0x84 — yank_length != 4
;   0x85 — yank_buffer contents != "\nb\nc" (B = index)
;   0x86 — count_accumulator != 0 post-call
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
    LD      BC, 5
    LDIR
    LD      HL, GAP_BUFFER_BASE + 5
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
    CALL    motion_byte_at_logical
    JR      C, .buf_fail_size       ; CF=1 here means file empty — fail
    CP      'a'
    JR      Z, .ok_buf0
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.buf_fail_size:
    LD      B, 0
    LD      A, 0x81
    JP      test_fail
.ok_buf0:
    ;; Confirm file_length == 1: motion_byte_at_logical(1) past-EOF.
    LD      HL, 1
    CALL    motion_byte_at_logical
    JR      C, .ok_buf_size
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_buf_size:

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
    LD      DE, 4
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
    LD      B, 4
.ycmp_loop:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 4
    SUB     B
    LD      B, A
    LD      A, 0x85
    JP      test_fail
.ycmp_next:
    INC     HL
    INC     DE
    DJNZ    .ycmp_loop

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x86
    JP      test_fail
.ok_count:

    JP      test_pass

.payload:
    DEFB    "a", 0x0A, "b", 0x0A, "c"
.expected_yank:
    DEFB    0x0A, "b", 0x0A, "c"

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
