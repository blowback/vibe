; ============================================================
; Module: test/cases/edits_p-char-first-byte-full.asm
; Purpose: Code-review test P5 (2026-05-17) — KIND_CHAR partial
;          paste with ZERO bytes inserted (first gapbuf_insert
;          fails on buffer-full). Pre-load GAP_BUFFER_MAX bytes
;          of 'A' (completely full buffer; gap_start ==
;          gap_end == GAP_BUFFER_BASE + GAP_BUFFER_MAX); cursor=5
;          (middle of buffer, not LF, not past EOF). Pre-seed
;          yank: KIND_CHAR, len=3, "XYZ". CALL op_paste.
;
;          Trace: PUSH raw_entry=5; motion_byte_at_logical →
;          A='A' CF=0 → not LF → INC HL → cursor=6 (advanced);
;          PUSH pre_cursor=6; .pc_count_loop iter 1: PUSH BC=1;
;          CALL edits_paste_yank_bytes → LD BC=3, LD HL=0,
;          LD A,(DE)='X', CALL gapbuf_insert → CF=1 (buffer full;
;          msg_file_too_large set); RET C with HL=0. POP BC, JR
;          C, .pc_partial. POP DE=6; LD HL,(cursor_offset)=6;
;          SBC HL,DE=0; OR L → Z; JR NZ → not taken; POP HL =
;          raw_entry=5; LD (cursor_offset),HL → cursor=5;
;          JP parser_clear.
;
;          Assert: cursor=5 (RESTORED from raw_entry, NOT left
;          at 6); buffer_dirty=0 (.commit bypassed); status_dirty=1
;          (msg_file_too_large was surfaced); parser cleared.
;
;          Pins the P2 fix: pre-paste advance is reverted on
;          0-bytes-landed Z-branch. WITHOUT the fix cursor would
;          land at 6 — visible side effect on a paste that
;          inserted nothing.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xA0 — cursor_offset != 5 (advance not reverted)
;   0xA1 — buffer_dirty != 0 (.commit was not bypassed)
;   0xA2 — status_dirty == 0 (msg_file_too_large NOT set)
;   0xA3 — parser state not cleared
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

    ;; Fill the entire buffer with 'A' (GAP_BUFFER_MAX bytes;
    ;; gap_start == gap_end == base + max → completely full).
    CALL    gapbuf_init
    LD      A, 'A'
    LD      (GAP_BUFFER_BASE), A
    LD      HL, GAP_BUFFER_BASE
    LD      DE, GAP_BUFFER_BASE + 1
    LD      BC, GAP_BUFFER_MAX - 1
    LDIR
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      (gap_start), HL

    LD      HL, 5
    LD      (cursor_offset), HL

    LD      A, KIND_CHAR
    LD      (yank_kind), A
    LD      HL, 3
    LD      (yank_length), HL
    LD      HL, .yank_content
    LD      DE, yank_buffer
    LD      BC, 3
    LDIR

    CALL    op_paste

    ;; cursor must be restored to 5 (NOT left at 6).
    LD      HL, (cursor_offset)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xA0
    JP      test_fail
.ok_cursor:

    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xA1
    JP      test_fail
.ok_dirty:

    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok_status_dirty
    LD      A, 0xA2
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
    LD      A, 0xA3
    JP      test_fail
.parser_ok:

    JP      test_pass

.yank_content:
    DEFB    "XYZ"

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
