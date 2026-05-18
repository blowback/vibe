; ============================================================
; Module: test/cases/visual_counted-motion.asm
; Purpose: Story 3.3 AC4 / AC10 — verify counted-motion semantic
;          in VISUAL. dispatch_visual['0'..'9'] route to
;          parser_handle_digit; the count accumulates in
;          count_accumulator and is consumed by the next motion's
;          motion_apply_count prologue. visual_extend recomputes
;          the new char count and updates the status row;
;          count_accumulator is cleared by the motion's tail-JP
;          parser_clear (chained via edits_compose_or_clear's
;          MODE_VISUAL arm → visual_extend → parser_clear).
;
;          Buffer "abcdefghij" (10 B). Pre-seed cursor_offset = 0,
;          visual_anchor = 0, mode_byte = MODE_VISUAL, and
;          count_accumulator = 3 (simulating the user having
;          pressed '3' before 'l'). CALL motion_l directly —
;          consumes the count, advances cursor by 3.
;
; Sentinel 0xB4 — context byte:
;   0 — post-motion cursor_offset != 3
;   1 — post-motion status_buffer != "-- visual -- 4"
;   2 — post-motion count_accumulator != 0 (parser_clear ran)
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
    LD      (pending_motion_inclusive), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 10
    LDIR
    LD      HL, GAP_BUFFER_BASE + 10
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL
    LD      (visual_anchor), HL

    ;; Simulate the user having pressed '3' before 'l'.
    LD      HL, 3
    LD      (count_accumulator), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A

    LD      A, 'l'
    CALL    motion_l

    ;; Check 1: cursor_offset == 3.
    LD      HL, (cursor_offset)
    LD      DE, 3
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor
    LD      A, 0xB4
    LD      B, 0
    JP      test_fail

.ok_cursor:
    ;; Check 2: status_buffer == "-- visual -- 4".
    LD      HL, status_buffer
    LD      DE, .status_4
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
    LD      A, 0xB4
    LD      B, 1
    JP      test_fail

.ok_status:
    ;; Check 3: count_accumulator == 0 (parser_clear ran via the
    ;; MODE_VISUAL arm → visual_extend → parser_clear chain).
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      A, 0xB4
    LD      B, 2
    JP      test_fail

.ok_count:
    JP      test_pass

.payload:
    DEFB    "abcdefghij"
.status_4:
    DEFB    "-- visual -- 4"

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
