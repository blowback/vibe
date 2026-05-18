; ============================================================
; Module: test/cases/visual_V-anchor-snaps-to-line-start.asm
; Purpose: Story 3.4 AC2 / AC10 — verify visual_enter_line sets
;          mode_byte = MODE_VISUAL, visual_submode = VIS_LINE,
;          visual_anchor = motion_find_line_start(cursor_offset)
;          (line-start of the cursor's line, NOT the cursor
;          itself — the line-mode anchor lives in line-start
;          space; AC2 invariant), composes "-- visual line -- 1"
;          into status_buffer (entry line count = 1; AC7), leaves
;          cursor_offset UNCHANGED (V does not move the cursor),
;          and zeroes parser state via parser_clear.
;
;          Buffer "abc\nfoo\nbar" (11 B; LFs at 3, 7). Pre-set
;          cursor_offset = 5 (line 2 col 1 = the 'o' in "foo"),
;          mode_byte = MODE_NORMAL, visual_submode = VIS_CHAR
;          (sentinel — confirms the VIS_LINE writer overwrites).
;          CALL visual_enter_line (A = 'V' per MC4, ignored).
;
; Sentinel 0xB5 — context byte:
;   0 — mode_byte != MODE_VISUAL post-call
;   1 — visual_submode != VIS_LINE post-call
;   2 — visual_anchor != 4 (line-start of line 2, NOT cursor=5;
;       AC2 — anchor snaps to line-start)
;   3 — cursor_offset != 5 (V does NOT move cursor on entry)
;   4 — status_buffer[0..18] != "-- visual line -- 1" (18 prefix
;       chars + '1' = 19; we compare the first 19 bytes)
;   5 — count_accumulator != 0 (parser_clear ran via tail-JP)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    ;; Pre-zero parser + mode + status state. Then set
    ;; visual_submode = VIS_CHAR as a sentinel — confirms the
    ;; VIS_LINE writer flips it.
    XOR     A
    LD      (status_dirty), A
    LD      (mode_byte), A                  ; MODE_NORMAL = 0
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A             ; sentinel — should become VIS_LINE

    ;; Pre-write an anchor sentinel so the post-call check proves
    ;; visual_enter_line re-pinned it.
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
    ;; should snap back to 4 = line-start of line 2.
    LD      HL, 5
    LD      (cursor_offset), HL

    ;; Drive visual_enter_line directly (parser_V-dispatch.asm
    ;; covers the dispatch_normal['V'] → visual_enter_line wiring
    ;; end-to-end).
    LD      A, 'V'
    CALL    visual_enter_line

    ;; Check 1: mode_byte == MODE_VISUAL.
    LD      A, (mode_byte)
    CP      MODE_VISUAL
    JR      Z, .ok_mode
    LD      A, 0xB5
    LD      B, 0
    JP      test_fail

.ok_mode:
    ;; Check 2: visual_submode == VIS_LINE.
    LD      A, (visual_submode)
    CP      VIS_LINE
    JR      Z, .ok_submode
    LD      A, 0xB5
    LD      B, 1
    JP      test_fail

.ok_submode:
    ;; Check 3: visual_anchor == 4 (line-start of line 2, NOT 5).
    LD      HL, (visual_anchor)
    LD      DE, 4
    OR      A
    SBC     HL, DE
    JR      Z, .ok_anchor
    LD      A, 0xB5
    LD      B, 2
    JP      test_fail

.ok_anchor:
    ;; Check 4: cursor_offset still 5 (V does NOT move cursor).
    LD      HL, (cursor_offset)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor
    LD      A, 0xB5
    LD      B, 3
    JP      test_fail

.ok_cursor:
    ;; Check 5: status_buffer[0..18] == "-- visual line -- 1" (19).
    LD      HL, status_buffer
    LD      DE, .expect_status
    LD      B, 19
.cmp_loop:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_status
    INC     HL
    INC     DE
    DJNZ    .cmp_loop
    JR      .ok_status

.fail_status:
    LD      A, 0xB5
    LD      B, 4
    JP      test_fail

.ok_status:
    ;; Check 6: count_accumulator == 0 (parser_clear ran).
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_parser
    LD      A, 0xB5
    LD      B, 5
    JP      test_fail

.ok_parser:
    JP      test_pass

.payload:
    DEFB    "abc", 0x0A, "foo", 0x0A, "bar"
.expect_status:
    DEFB    "-- visual line -- 1"

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
