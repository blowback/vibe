; ============================================================
; Module: test/cases/visual_line-counted-motion.asm
; Purpose: Story 3.4 AC3 / AC5 / AC10 — verify counted motion in
;          VIS_LINE submode: count_accumulator = 3 + CALL motion_j
;          on a 5-line file advances cursor 3 lines down and the
;          line count becomes 4 (= 3 LFs crossed + 1). parser_clear
;          drops count_accumulator to 0 after the motion's tail-JP
;          via visual_extend.
;
;          Buffer "a\nb\nc\nd\ne" (9 B; 5 lines; LFs at 1, 3, 5,
;          7). Pre-set mode_byte = MODE_VISUAL, visual_submode =
;          VIS_LINE, visual_anchor = 0, cursor_offset = 0,
;          count_accumulator = 3. CALL motion_j once.
;
; Sentinel 0xB8 — context byte:
;   0 — cursor_offset != 6 (line 4 col 0; j × 3 lands on line 4)
;   1 — status_buffer mismatch ("-- visual line -- 4")
;   2 — count_accumulator != 0 (parser_clear ran)
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

    ;; Populate buffer "a\nb\nc\nd\ne" (9 B; LFs at 1, 3, 5, 7).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 9
    LDIR
    LD      HL, GAP_BUFFER_BASE + 9
    LD      (gap_start), HL

    ;; Pre-seed VIS_LINE at cursor=0, anchor=0.
    LD      HL, 0
    LD      (cursor_offset), HL
    LD      (visual_anchor), HL

    ;; Pre-seed count_accumulator = 3 (16-bit).
    LD      HL, 3
    LD      (count_accumulator), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_LINE
    LD      (visual_submode), A

    LD      A, 'j'
    CALL    motion_j

    ;; Check 1: cursor_offset == 6 (line 4 start; LF at 5 → start
    ;; of next line = 6).
    LD      HL, (cursor_offset)
    LD      DE, 6
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c
    LD      A, 0xB8
    LD      B, 0
    JP      test_fail

.ok_c:
    ;; Check 2: status_buffer starts "-- visual line -- 4".
    LD      HL, status_buffer
    LD      DE, .expect_status
    LD      B, 19
.cmp_loop:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_s
    INC     HL
    INC     DE
    DJNZ    .cmp_loop
    JR      .ok_s

.fail_s:
    LD      A, 0xB8
    LD      B, 1
    JP      test_fail

.ok_s:
    ;; Check 3: count_accumulator == 0 (parser_clear ran).
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      A, 0xB8
    LD      B, 2
    JP      test_fail

.ok_count:
    JP      test_pass

.payload:
    DEFB    "a", 0x0A, "b", 0x0A, "c", 0x0A, "d", 0x0A, "e"
.expect_status:
    DEFB    "-- visual line -- 4"

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
