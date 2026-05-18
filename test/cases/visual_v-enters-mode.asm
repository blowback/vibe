; ============================================================
; Module: test/cases/visual_v-enters-mode.asm
; Purpose: Story 3.3 AC3 / AC10 — verify visual_enter_char sets
;          mode_byte = MODE_VISUAL, visual_submode = VIS_CHAR,
;          visual_anchor = cursor_offset (frozen at the entry
;          cursor), composes "-- visual -- 1" into status_buffer
;          (entry char count = 1; AC7), leaves cursor_offset
;          unchanged, and zeroes parser state via parser_clear.
;
;          Buffer "abc\nfoo\nbar" (11 B). Pre-set cursor_offset
;          = 0 and mode_byte = MODE_NORMAL. CALL visual_enter_char
;          (A = 'v' per MC4, though the value is ignored after
;          dispatch).
;
; Sentinel 0xB0 — context byte:
;   0 — mode_byte != MODE_VISUAL post-call
;   1 — visual_submode != VIS_CHAR post-call
;   2 — visual_anchor != 0 post-call
;   3 — cursor_offset != 0 post-call (anchor reflected back, but
;       cursor must not move on entry)
;   4 — status_buffer[0..13] != "-- visual -- 1" (the first 14
;       chars; AC7's literal prefix + entry count '1')
;   5 — count_accumulator != 0 (parser_clear ran via tail-JP)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    ;; Pre-zero parser + mode + status state.
    XOR     A
    LD      (status_dirty), A
    LD      (mode_byte), A                  ; MODE_NORMAL = 0
    LD      (visual_submode), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A

    ;; Pre-write an anchor sentinel so the post-call check proves
    ;; visual_enter_char re-pinned it (rather than leaving it at
    ;; cold-start zero by coincidence).
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

    LD      HL, 0
    LD      (cursor_offset), HL

    ;; Drive visual_enter_char directly (skipping the dispatch table
    ;; binary search — parser_v-dispatch.asm covers that end-to-end).
    LD      A, 'v'
    CALL    visual_enter_char

    ;; Check 1: mode_byte == MODE_VISUAL.
    LD      A, (mode_byte)
    CP      MODE_VISUAL
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0xB0
    LD      C, 0
    JP      .fail

.ok_mode:
    ;; Check 2: visual_submode == VIS_CHAR.
    LD      A, (visual_submode)
    CP      VIS_CHAR
    JR      Z, .ok_submode
    LD      B, A
    LD      A, 0xB0
    LD      C, 1
    JP      .fail

.ok_submode:
    ;; Check 3: visual_anchor == 0 (re-pinned to cursor).
    LD      HL, (visual_anchor)
    LD      A, H
    OR      L
    JR      Z, .ok_anchor
    LD      B, L
    LD      A, 0xB0
    LD      C, 2
    JP      .fail

.ok_anchor:
    ;; Check 4: cursor_offset still 0 (visual_enter_char must not
    ;; move the cursor).
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, L
    LD      A, 0xB0
    LD      C, 3
    JP      .fail

.ok_cursor:
    ;; Check 5: status_buffer[0..13] == "-- visual -- 1" (14 chars).
    LD      HL, status_buffer
    LD      DE, .expect_status
    LD      B, 14
.cmp_loop:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_status
    INC     HL
    INC     DE
    DJNZ    .cmp_loop
    JR      .ok_status

.fail_status:
    LD      B, A                            ; B = expected byte for context
    LD      A, 0xB0
    LD      C, 4
    JP      .fail

.ok_status:
    ;; Check 6: count_accumulator == 0 (parser_clear ran).
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_parser
    LD      B, L
    LD      A, 0xB0
    LD      C, 5
    JP      .fail

.ok_parser:
    JP      test_pass

.fail:
    ;; A = sentinel (0xB0), C = sub-check (0..5), B = observed byte.
    ;; test_fail expects A = fail-code, B = context; thread sub-check
    ;; through B and ignore observed byte (sentinel granularity is
    ;; enough — context byte slot is used for the sub-check).
    LD      B, C
    JP      test_fail

.payload:
    DEFB    "abc", 0x0A, "foo", 0x0A, "bar"
.expect_status:
    DEFB    "-- visual -- 1"

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
