; ============================================================
; Module: test/cases/visual_shift-overflow.asm
; Purpose: Story 3.7 AC10 / Q1 Option A — pin the
;          enter_normal_mode status-clobber on partial-overflow
;          indent walk. With gap buffer at (GAP_BUFFER_MAX - 1)
;          bytes (1 byte free), a 2-line VIS_LINE `>` selection
;          inserts INDENT_BYTE successfully on line 1
;          (consuming the last free byte), then gapbuf_insert
;          returns CF=1 on line 2 — gapbuf_insert sets
;          msg_file_too_large into status_buffer (statusln.asm:124).
;          visual_apply_shift sees dirty=1, records the partial
;          UNDO_KIND_INDENT_WALK entry, then tail-JPs
;          enter_normal_mode which calls status_set_message
;          (msg_mode_normal) — msg_mode_normal is `DEFB 0`
;          (statusln.asm:341), so status_buffer[0] flips from
;          'f' (0x66) to 0x00.
;
;          Q1 Option A pin: accept the clobber (matches
;          NORMAL-mode op_compose_indent precedent). This test
;          is a regression sentinel — if a future change tries
;          to preserve msg_file_too_large via flag-based mode
;          flip, status_buffer[0] would still be 'f' here and
;          the test fires.
;
;          Fixture layout (post-seed, pre-call):
;            gap_buffer[0..MAX-4] = 'A'           (line 1 body)
;            gap_buffer[MAX-3]     = 0x0A         (LF — line 1 end)
;            gap_buffer[MAX-2]     = 'B'          (line 2 body)
;            gap_start             = BASE+MAX-1   (file_length = MAX-1)
;            gap_end               = BASE+MAX     (free space = 1)
;          Logical view: "AAAA...A\nB" — 2 lines.
;          anchor = 0 (line 1 start), cursor = MAX-2 (line 2 start).
;
;          Expected post-call:
;            mode_byte             = MODE_NORMAL
;            cursor_offset         = 0           (promoted_start)
;            buffer_dirty          = 1           (partial insert)
;            gap_start == gap_end                (buffer full —
;                                                 free space consumed
;                                                 by the 1 successful
;                                                 insert; precise
;                                                 gap location depends
;                                                 on the failed iter-2
;                                                 gap-move target)
;            buffer[0]             = INDENT_BYTE (line 1 indent landed)
;            undo_kind             = UNDO_KIND_INDENT_WALK
;            status_buffer[0]      = ' ' (0x20)  (msg_mode_normal —
;                                                 msg_file_too_large
;                                                 'f' was clobbered.
;                                                 msg_mode_normal is
;                                                 `DEFB 0`, so
;                                                 status_set_message
;                                                 hits the null on
;                                                 byte 0 and pads the
;                                                 full STATUS_LINE_WIDTH
;                                                 with spaces — status
;                                                 _buffer[0] is the
;                                                 first pad byte 0x20.)
;
; Sentinel 0xDD — context byte:
;   0 — mode_byte != MODE_NORMAL
;   1 — cursor_offset != 0
;   2 — buffer_dirty != 1
;   3 — gap_start != gap_end (buffer not full — 1st insert
;       didn't happen, or 2nd insert succeeded — either way
;       the partial-overflow path didn't fire as designed)
;   4 — buffer[0] != INDENT_BYTE
;   5 — undo_kind != UNDO_KIND_INDENT_WALK
;   6 — status_buffer[0] != ' ' (msg_mode_normal pad was not the
;       last status_set_message write — either msg_file_too_large
;       'f' (0x66) survived, or some other status string is in
;       the buffer; Q1 Option A pin violated either way)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (status_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A
    LD      (undo_kind), A
    LD      (yank_kind), A
    LD      (buffer_dirty), A
    LD      HL, 0
    LD      (undo_position), HL
    LD      (undo_length), HL

    CALL    gapbuf_init

    ;; Fill pre-gap with 'A' bytes via self-copy LDIR idiom.
    ;; Seed byte 0, then LDIR src=BASE → dst=BASE+1 with
    ;; BC = GAP_BUFFER_MAX - 2 propagates 'A' across
    ;; bytes 1..GAP_BUFFER_MAX-2 (one byte at a time).
    LD      HL, GAP_BUFFER_BASE
    LD      (HL), 'A'
    LD      DE, GAP_BUFFER_BASE + 1
    LD      BC, GAP_BUFFER_MAX - 2
    LDIR

    ;; Inject LF at offset (MAX-3): separates line 1 from line 2.
    LD      A, 0x0A
    LD      (GAP_BUFFER_BASE + GAP_BUFFER_MAX - 3), A

    ;; Inject 'B' at offset (MAX-2): line 2's only content byte.
    LD      A, 'B'
    LD      (GAP_BUFFER_BASE + GAP_BUFFER_MAX - 2), A

    ;; Adjust gap pointers: file_length = MAX-1, free space = 1.
    ;; (gap_end stays at BASE+MAX from gapbuf_init.)
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX - 1
    LD      (gap_start), HL

    ;; anchor = 0 (line 1 start), cursor = MAX-2 (line 2 start).
    LD      HL, 0
    LD      (visual_anchor), HL
    LD      HL, GAP_BUFFER_MAX - 2
    LD      (cursor_offset), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_LINE
    LD      (visual_submode), A

    ;; --- Execute: visual_apply_shift with A='>' ---
    LD      A, '>'
    CALL    visual_apply_shift

    ;; --- Assertions ---
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xDD
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0xDD
    LD      B, 1
    JP      test_fail
.ok_cursor:
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      A, 0xDD
    LD      B, 2
    JP      test_fail
.ok_dirty:
    LD      HL, (gap_start)
    LD      DE, (gap_end)
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_gap
    LD      A, 0xDD
    LD      B, 3
    JP      test_fail
.ok_gap:
    LD      HL, 0
    CALL    motion_byte_at_logical
    CP      INDENT_BYTE
    JR      Z, .ok_byte0
    LD      A, 0xDD
    LD      B, 4
    JP      test_fail
.ok_byte0:
    LD      A, (undo_kind)
    CP      UNDO_KIND_INDENT_WALK
    JR      Z, .ok_uk
    LD      A, 0xDD
    LD      B, 5
    JP      test_fail
.ok_uk:
    LD      A, (status_buffer)
    CP      ' '
    JR      Z, .ok_status
    LD      A, 0xDD
    LD      B, 6
    JP      test_fail
.ok_status:
    JP      test_pass

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
