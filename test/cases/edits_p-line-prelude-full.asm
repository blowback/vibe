; ============================================================
; Module: test/cases/edits_p-line-prelude-full.asm
; Purpose: Code-review test P4 (2026-05-17) — KIND_LINE paste
;          where the explicit-LF prelude itself fails on
;          buffer-full (`.pl_overflow_no_content`). Pre-load
;          GAP_BUFFER_MAX bytes of 'A' (no LF anywhere — every
;          line is the "last line no LF"); gap_start ==
;          gap_end == base + max (completely full). cursor=5.
;          Pre-seed yank: KIND_LINE, len=3, "X\nY".
;
;          Trace: PUSH entry_cursor=5; motion_find_line_end(5)
;          walks forward — no LF, returns HL=file_length=
;          GAP_BUFFER_MAX, CF=1; LD (cursor_offset),HL → cursor
;          temporarily moved to file_length. motion_byte_at_logical
;          (file_length) → CF=1 past EOF → JR C, .pl_past_eof.
;          LD A,0x0A; CALL gapbuf_insert → CF=1 (buffer full;
;          msg_file_too_large set); JR C, .pl_overflow_no_content.
;          POP HL = entry_cursor=5; LD (cursor_offset),HL → cursor
;          RESTORED to 5; JP parser_clear.
;
;          Assert: cursor=5 (RESTORED from entry_cursor, NOT left
;          at file_length=GAP_BUFFER_MAX); buffer_dirty=0
;          (.commit bypassed); status_dirty=1 (msg_file_too_large
;          surfaced); parser cleared.
;
;          Pins the P1 fix: cursor is restored to entry_cursor on
;          the prelude-overflow path. WITHOUT the fix cursor would
;          jump to GAP_BUFFER_MAX — visible jump-to-EOF on a paste
;          that inserted nothing.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xA4 — cursor_offset != 5 (entry_cursor not restored)
;   0xA5 — buffer_dirty != 0 (.commit was not bypassed)
;   0xA6 — status_dirty == 0 (msg_file_too_large NOT set)
;   0xA7 — parser state not cleared
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

    ;; Fill buffer entirely with 'A' — no LF anywhere
    ;; (last-line-no-LF case for every position).
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

    LD      A, KIND_LINE
    LD      (yank_kind), A
    LD      HL, 3
    LD      (yank_length), HL
    LD      HL, .yank_content
    LD      DE, yank_buffer
    LD      BC, 3
    LDIR

    CALL    op_paste

    ;; cursor must be restored to 5 (NOT left at file_length).
    LD      HL, (cursor_offset)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xA4
    JP      test_fail
.ok_cursor:

    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xA5
    JP      test_fail
.ok_dirty:

    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok_status_dirty
    LD      A, 0xA6
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
    LD      A, 0xA7
    JP      test_fail
.parser_ok:

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
