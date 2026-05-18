; ============================================================
; Module: test/cases/visual_ctrlV-enters-block-mode.asm
; Purpose: Story 3.5 AC2 / AC12 — verify visual_enter_block sets
;          mode_byte = MODE_VISUAL, visual_submode = VIS_BLOCK,
;          visual_anchor = cursor_offset (the entry cursor OFFSET,
;          NOT the line-start — this is the KEY semantic
;          distinction from VIS_LINE's anchor-snaps-to-line-start;
;          AC2), composes "-- visual block -- 1x1" into
;          status_buffer (entry rows=1 cols=1; AC2 + AC8), leaves
;          cursor_offset UNCHANGED (Ctrl-V does not move the
;          cursor), and zeroes parser state via parser_clear.
;
;          Buffer "abc\nfoo\nbar" (11 B; LFs at 3, 7). Pre-set
;          cursor_offset = 5 (line 2 col 1 = the 'o' in "foo"),
;          mode_byte = MODE_NORMAL, visual_submode = VIS_LINE
;          (sentinel — confirms the VIS_BLOCK writer overwrites).
;          CALL visual_enter_block (A = 0x16 per MC4, ignored).
;
; Sentinel 0xBA — context byte:
;   0 — mode_byte != MODE_VISUAL post-call
;   1 — visual_submode != VIS_BLOCK post-call
;   2 — visual_anchor != 5 (entry cursor offset; NOT 4 = line-start;
;       AC2 — BLOCK anchor lives in offset space)
;   3 — cursor_offset != 5 (Ctrl-V does NOT move cursor on entry)
;   4 — status_buffer[0..21] != "-- visual block -- 1x1" (22 chars:
;       19 prefix + '1' + 'x' + '1')
;   5 — count_accumulator != 0 (parser_clear ran via tail-JP)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    ;; Pre-zero parser + mode + status state. Then set
    ;; visual_submode = VIS_LINE as a sentinel — confirms the
    ;; VIS_BLOCK writer flips it.
    XOR     A
    LD      (status_dirty), A
    LD      (mode_byte), A                  ; MODE_NORMAL = 0
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A
    LD      A, VIS_LINE
    LD      (visual_submode), A             ; sentinel — should become VIS_BLOCK

    ;; Pre-write an anchor sentinel so the post-call check proves
    ;; visual_enter_block re-pinned it.
    LD      HL, 0xBEEF
    LD      (visual_anchor), HL

    ;; Populate gap-buffer with "abc\nfoo\nbar" (11 B; no trailing LF).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 11
    LDIR
    LD      HL, GAP_BUFFER_BASE + 11
    LD      (gap_start), HL

    ;; Cursor at offset 5 = 'o' (mid-line on line 2). Anchor
    ;; should land at offset 5 (NOT 4 = line-start of line 2 —
    ;; this is the AC2 semantic that distinguishes BLOCK from LINE).
    LD      HL, 5
    LD      (cursor_offset), HL

    ;; Drive visual_enter_block directly (parser_ctrlV-dispatch.asm
    ;; covers the dispatch_normal[0x16] → visual_enter_block wiring
    ;; end-to-end).
    LD      A, 0x16
    CALL    visual_enter_block

    ;; Check 1: mode_byte == MODE_VISUAL.
    LD      A, (mode_byte)
    CP      MODE_VISUAL
    JR      Z, .ok_mode
    LD      A, 0xBA
    LD      B, 0
    JP      test_fail

.ok_mode:
    ;; Check 2: visual_submode == VIS_BLOCK.
    LD      A, (visual_submode)
    CP      VIS_BLOCK
    JR      Z, .ok_submode
    LD      A, 0xBA
    LD      B, 1
    JP      test_fail

.ok_submode:
    ;; Check 3: visual_anchor == 5 (entry cursor offset; NOT 4 =
    ;; line-start of line 2; KEY AC2 distinction from VIS_LINE).
    LD      HL, (visual_anchor)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    JR      Z, .ok_anchor
    LD      A, 0xBA
    LD      B, 2
    JP      test_fail

.ok_anchor:
    ;; Check 4: cursor_offset still 5 (Ctrl-V does NOT move cursor).
    LD      HL, (cursor_offset)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor
    LD      A, 0xBA
    LD      B, 3
    JP      test_fail

.ok_cursor:
    ;; Check 5: status_buffer[0..21] == "-- visual block -- 1x1" (22).
    LD      HL, status_buffer
    LD      DE, .expect_status
    LD      B, 22
.cmp_loop:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_status
    INC     HL
    INC     DE
    DJNZ    .cmp_loop
    JR      .ok_status

.fail_status:
    LD      A, 0xBA
    LD      B, 4
    JP      test_fail

.ok_status:
    ;; Check 6: count_accumulator == 0 (parser_clear ran).
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_parser
    LD      A, 0xBA
    LD      B, 5
    JP      test_fail

.ok_parser:
    JP      test_pass

.payload:
    DEFB    "abc", 0x0A, "foo", 0x0A, "bar"
.expect_status:
    DEFB    "-- visual block -- 1x1"

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
