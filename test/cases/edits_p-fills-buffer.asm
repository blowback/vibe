; ============================================================
; Module: test/cases/edits_p-fills-buffer.asm
; Purpose: AC10 canonical-6 — partial paste on buffer overflow.
;          Pre-load near-full buffer (GAP_BUFFER_MAX - 2 = 32766 B
;          of payload 'A'); cursor=0. Pre-seed yank: KIND_CHAR,
;          len=10, content="XXXXXXXXXX". CALL op_paste. Trace:
;          pre-paste advance moves cursor 0 → 1; outer loop iter 1
;          calls edits_paste_yank_bytes which inserts 2 X bytes
;          (cursor advances 1 → 2 → 3) before the 3rd gapbuf_insert
;          returns CF=1 (buffer full at GAP_BUFFER_MAX). Helper
;          returns CF=1 with HL=2. Op_paste's .pc_partial branch:
;          cursor (3) - pre_cursor (1) = 2 ≠ 0 → DEC cursor → 2;
;          .commit sets buffer_dirty=1 + render_mark_all_dirty.
;
;          Assert: cursor=2 (last successfully-inserted X — at
;          logical position 2; original 'A' is at 0, first X at 1,
;          second X at 2, payload bytes 1..32765 shifted to 3..32767);
;          buffer_dirty=1; status_dirty=1 (msg_file_too_large was
;          set by gapbuf_insert); parser cleared. We don't verify
;          full buffer content (32768 B compare would be wasteful);
;          verify cursor-adjacent bytes (positions 0, 1, 2, 3).
;
;          Pins: AC8 partial-paste; FR52 no silent data loss;
;          KIND_CHAR partial cursor DEC per Q5 pin.
;
;          NOTE on spec narrative: AC10's `edits_p-fills-buffer`
;          description claims "cursor=1" — this is off by one
;          (the spec narrative counts the pre-paste advance as
;          part of the insert sequence; the actual semantic places
;          cursor on the last inserted byte at position 2). Test
;          asserts cursor=2 per actual semantic.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x90 — cursor_offset != 2
;   0x91 — buffer byte at pos 0 != 'A' (payload preserved)
;   0x92 — buffer byte at pos 1 != 'X' (first X inserted)
;   0x93 — buffer byte at pos 2 != 'X' (second X inserted)
;   0x94 — buffer byte at pos 3 != 'A' (payload shifted; this is
;          the byte that was at position 1 pre-paste)
;   0x96 — buffer_dirty != 1
;   0x97 — status_dirty != 1
;   0x95 — parser state not cleared
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

    ;; Pre-load GAP_BUFFER_MAX - 2 = 32766 bytes of 'A' via seed+LDIR-propagate.
    CALL    gapbuf_init
    LD      A, 'A'
    LD      (GAP_BUFFER_BASE), A
    LD      HL, GAP_BUFFER_BASE
    LD      DE, GAP_BUFFER_BASE + 1
    LD      BC, GAP_BUFFER_MAX - 3      ; 32766 - 1 = 32765 copies (initial 'A' counts as the source)
    LDIR
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX - 2
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, KIND_CHAR
    LD      (yank_kind), A
    LD      HL, 10
    LD      (yank_length), HL
    LD      HL, .yank_content
    LD      DE, yank_buffer
    LD      BC, 10
    LDIR

    CALL    op_paste

    ;; Cursor must land at 2 (last successfully-inserted X).
    LD      HL, (cursor_offset)
    LD      DE, 2
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x90
    JP      test_fail
.ok_cursor:

    ;; Verify buffer byte at logical position 0 is 'A'.
    LD      HL, 0
    CALL    motion_byte_at_logical
    CP      'A'
    JR      Z, .ok_pos0
    LD      B, A
    LD      A, 0x91
    JP      test_fail
.ok_pos0:

    ;; Verify byte at position 1 is 'X' (first X inserted).
    LD      HL, 1
    CALL    motion_byte_at_logical
    CP      'X'
    JR      Z, .ok_pos1
    LD      B, A
    LD      A, 0x92
    JP      test_fail
.ok_pos1:

    ;; Verify byte at position 2 is 'X' (second X inserted).
    LD      HL, 2
    CALL    motion_byte_at_logical
    CP      'X'
    JR      Z, .ok_pos2
    LD      B, A
    LD      A, 0x93
    JP      test_fail
.ok_pos2:

    ;; Verify byte at position 3 is 'A' (originally at position 1, shifted).
    LD      HL, 3
    CALL    motion_byte_at_logical
    CP      'A'
    JR      Z, .ok_pos3
    LD      B, A
    LD      A, 0x94
    JP      test_fail
.ok_pos3:

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x96
    JP      test_fail
.ok_dirty:

    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok_status_dirty
    LD      B, A
    LD      A, 0x97
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
    LD      A, 0x95
    JP      test_fail
.parser_ok:

    JP      test_pass

.yank_content:
    DEFB    "XXXXXXXXXX"

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
