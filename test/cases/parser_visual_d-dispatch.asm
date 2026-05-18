; ============================================================
; Module: test/cases/parser_visual_d-dispatch.asm
; Purpose: Story 3.6 AC1 — verify the dispatch_visual table
;          wiring for 'd'. Drive 'd' through dispatch_key with
;          dispatch_visual as the base; assert that the entry
;          inserted between 'c' and 'g' (per AC1 sorted insertion)
;          routes end-to-end through visual_apply_operator and
;          produces the correct VIS_CHAR 'd' outcome.
;
;          Buffer "abc" (3 B). Pre-set mode_byte = MODE_VISUAL,
;          visual_submode = VIS_CHAR, visual_anchor = 0,
;          cursor_offset = 2 (so range = [0, 3) = 3 bytes).
;          DRIVE: LD A, 'd' ; LD HL, dispatch_visual ; LD B,
;          DISPATCH_VISUAL_COUNT ; CALL dispatch_key.
;
;          Expected post-call:
;            mode_byte         = MODE_NORMAL
;            cursor_offset     = 0
;            buffer empty (gap_start reflects 0-byte file)
;            yank_kind         = KIND_CHAR
;            yank_length       = 3
;            yank_buffer[0..2] = "abc"
;
;          status_dirty was 0x80 pre-call (sentinel; verify the
;          dispatch path overwrote it).
;
; Sentinel 0xEE — context byte:
;   0 — mode_byte != MODE_NORMAL
;   1 — cursor_offset != 0
;   2 — file_length != 0 (buffer should be empty)
;   3 — yank_kind != KIND_CHAR
;   4 — yank_length != 3
;   5 — yank_buffer[0..2] != "abc"
;   6 — status_dirty == 0x80 (sentinel; dispatcher must have
;       written to it during the operator's terminal
;       enter_normal_mode tail-JP via status_set_message)
;   7 — undo_kind != UNDO_KIND_DELETE (CHAR `d` records undo
;       via undo_record_delete in the shared finalisation)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A
    LD      (undo_kind), A
    LD      (yank_kind), A
    LD      HL, 0
    LD      (yank_length), HL

    ;; Sentinel status_dirty value to verify dispatcher chain ran
    LD      A, 0x80
    LD      (status_dirty), A

    ;; Populate "abc" (3 B).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 2
    LD      (cursor_offset), HL
    LD      HL, 0
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A

    ;; --- Execute via dispatch_key ---
    LD      A, 'd'
    LD      HL, dispatch_visual
    LD      B, DISPATCH_VISUAL_COUNT
    CALL    dispatch_key

    ;; --- Assertions ---
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0xEE
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0xEE
    LD      B, 1
    JP      test_fail
.ok_cursor:
    ;; file_length should be 0 (all 3 bytes deleted).
    ;; file_length = gap_start + GAP_BUFFER_MAX - gap_end.
    ;; motion_byte_at_logical at offset 0 should return CF=1.
    LD      HL, 0
    CALL    motion_byte_at_logical
    JR      C, .ok_empty
    LD      A, 0xEE
    LD      B, 2
    JP      test_fail
.ok_empty:
    LD      A, (yank_kind)
    CP      KIND_CHAR
    JR      Z, .ok_yk
    LD      A, 0xEE
    LD      B, 3
    JP      test_fail
.ok_yk:
    LD      HL, (yank_length)
    LD      DE, 3
    OR      A
    SBC     HL, DE
    JR      Z, .ok_yl
    LD      A, 0xEE
    LD      B, 4
    JP      test_fail
.ok_yl:
    LD      HL, yank_buffer
    LD      DE, .payload
    LD      B, 3
.ycmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 0xEE
    LD      B, 5
    JP      test_fail
.ycmp_next:
    INC     HL
    INC     DE
    DJNZ    .ycmp

    LD      A, (status_dirty)
    CP      0x80
    JR      NZ, .ok_status
    LD      A, 0xEE
    LD      B, 6
    JP      test_fail
.ok_status:
    LD      A, (undo_kind)
    CP      UNDO_KIND_DELETE
    JR      Z, .ok_undo
    LD      A, 0xEE
    LD      B, 7
    JP      test_fail
.ok_undo:
    JP      test_pass

.payload:
    DEFB    "abc"

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
