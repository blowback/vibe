; ============================================================
; Module: test/cases/edits_p-line-zero-from-count-loop.asm
; Purpose: Code-review test P6 (2026-05-17) — KIND_LINE paste
;          via the LF-found prelude path where the very first
;          gapbuf_insert in the count loop fails on buffer-full.
;          Pins the documented-and-accepted `.pl_partial` shape
;          at edits.asm "0 bytes from count loop in LF-found
;          branch falls into .pl_partial and re-dirties
;          spuriously — accepted per AC8 'mildly wasteful but
;          correct'".
;
;          Setup: GAP_BUFFER_MAX bytes filled, with LF at
;          position 3 (so motion_find_line_end(0) returns 3,
;          NOT file_length — the LF-found branch, not past-EOF).
;          gap_start == gap_end == base + max (completely full).
;          cursor=0. Pre-seed yank: KIND_LINE, len=3, "X\nY".
;
;          Trace: PUSH entry=0; motion_find_line_end(0) finds
;          LF at 3 → HL=3, CF=0; LD (cursor_offset),HL=3.
;          motion_byte_at_logical(3) → A=0x0A, CF=0 → NOT past
;          EOF → INC HL → cursor=4 (insert-after-LF position);
;          JR .pl_count_setup. motion_apply_count → BC=1.
;          .pl_count_loop iter 1: PUSH BC; CALL
;          edits_paste_yank_bytes → gapbuf_insert(yank[0]='X')
;          → CF=1 (buffer full); helper returns CF=1 HL=0.
;          POP BC; JR C, .pl_partial. POP HL (discard entry=0);
;          LD HL,(cursor_offset)=4; motion_find_line_start
;          walks back to first byte after previous LF — LF at
;          pos 3, so line starts at 4; HL=4. LD (cursor_offset),
;          HL=4. JP .commit → buffer_dirty=1; status_dirty=1.
;
;          Assert: cursor=4 (start of would-be-inserted line);
;          buffer_dirty=1 (spurious — pins the accepted AC8
;          "mildly wasteful but correct" behaviour); status_dirty
;          =1; parser cleared; buffer content unchanged
;          (position 0='A', position 3=0x0A, position 4='A').
;
;          A regression that flipped this branch to bypass
;          .commit would break this test (good — pins the
;          accepted contract). A regression that mis-walked
;          motion_find_line_start would also break it.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xA8 — cursor_offset != 4
;   0xA9 — buffer_dirty != 1 (spurious dirty is the documented
;          accepted behaviour)
;   0xAA — status_dirty == 0 (msg_file_too_large NOT set)
;   0xAB — parser state not cleared
;   0xAC — buffer byte at pos 0 != 'A' (payload disturbed)
;   0xAD — buffer byte at pos 3 != 0x0A (LF removed/shifted)
;   0xAE — buffer byte at pos 4 != 'A' (payload disturbed)
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

    ;; Fill buffer entirely with 'A' then poke LF at position 3.
    CALL    gapbuf_init
    LD      A, 'A'
    LD      (GAP_BUFFER_BASE), A
    LD      HL, GAP_BUFFER_BASE
    LD      DE, GAP_BUFFER_BASE + 1
    LD      BC, GAP_BUFFER_MAX - 1
    LDIR
    LD      A, 0x0A
    LD      (GAP_BUFFER_BASE + 3), A
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, KIND_LINE
    LD      (yank_kind), A
    LD      HL, 3
    LD      (yank_length), HL
    LD      HL, .yank_content
    LD      DE, yank_buffer
    LD      BC, 3
    LDIR

    CALL    op_paste

    LD      HL, (cursor_offset)
    LD      DE, 4
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xA8
    JP      test_fail
.ok_cursor:

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xA9
    JP      test_fail
.ok_dirty:

    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok_status_dirty
    LD      A, 0xAA
    LD      B, 0
    JP      test_fail
.ok_status_dirty:

    LD      A, (pending_operator)
    OR      A
    JR      NZ, .parser_fail
    LD      A, (pending_motion_prefix)
    OR      A
    JR      NZ, .parser_fail
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .parser_ok
.parser_fail:
    LD      A, 0xAB
    JP      test_fail
.parser_ok:

    LD      HL, 0
    CALL    motion_byte_at_logical
    CP      'A'
    JR      Z, .ok_pos0
    LD      B, A
    LD      A, 0xAC
    JP      test_fail
.ok_pos0:

    LD      HL, 3
    CALL    motion_byte_at_logical
    CP      0x0A
    JR      Z, .ok_pos3
    LD      B, A
    LD      A, 0xAD
    JP      test_fail
.ok_pos3:

    LD      HL, 4
    CALL    motion_byte_at_logical
    CP      'A'
    JR      Z, .ok_pos4
    LD      B, A
    LD      A, 0xAE
    JP      test_fail
.ok_pos4:

    JP      test_pass

.yank_content:
    DEFB    "X", 0x0A, "Y"

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
