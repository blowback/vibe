; ============================================================
; Module: test/cases/visual_motions-extend-selection.asm
; Purpose: Story 3.3 AC5 / AC6 / AC10 — verify that mode-agnostic
;          motions in MODE_VISUAL flow through edits_compose_or_clear's
;          new MODE_VISUAL arm into visual_extend, which recomputes
;          the char count and refreshes the status row.
;
;          Buffer "abcdef" (6 B). Pre-set mode_byte = MODE_VISUAL,
;          visual_submode = VIS_CHAR, visual_anchor = 0,
;          cursor_offset = 0. CALL motion_l three times (one byte
;          forward per CALL); each call's tail-JP edits_compose_or_clear
;          hits the MODE_VISUAL arm, which JPs visual_extend; the
;          status row updates after each motion.
;
;          Expected progression:
;            after 1st motion_l: cursor=1, count=|1-0|+1=2, status="-- visual -- 2"
;            after 2nd motion_l: cursor=2, count=3, status="-- visual -- 3"
;            after 3rd motion_l: cursor=3, count=4, status="-- visual -- 4"
;
; Sentinel 0xB1 — context byte:
;   0 — after 1st motion_l: cursor_offset != 1
;   1 — after 1st motion_l: status_buffer mismatch
;   2 — after 2nd motion_l: cursor_offset != 2
;   3 — after 2nd motion_l: status_buffer mismatch
;   4 — after 3rd motion_l: cursor_offset != 3
;   5 — after 3rd motion_l: status_buffer mismatch
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    ;; Pre-zero parser + status.
    XOR     A
    LD      (status_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A

    ;; Populate buffer "abcdef" (6 B).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 6
    LDIR
    LD      HL, GAP_BUFFER_BASE + 6
    LD      (gap_start), HL

    ;; Pre-seed VISUAL session at cursor=0, anchor=0.
    LD      HL, 0
    LD      (cursor_offset), HL
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A

    ;; --- 1st motion_l ---
    LD      A, 'l'
    CALL    motion_l

    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c1
    LD      A, 0xB1
    LD      B, 0
    JP      test_fail
.ok_c1:
    LD      HL, status_buffer
    LD      DE, .status_2
    CALL    .cmp_14
    JR      Z, .ok_s1
    LD      A, 0xB1
    LD      B, 1
    JP      test_fail
.ok_s1:

    ;; --- 2nd motion_l ---
    LD      A, 'l'
    CALL    motion_l

    LD      HL, (cursor_offset)
    LD      DE, 2
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c2
    LD      A, 0xB1
    LD      B, 2
    JP      test_fail
.ok_c2:
    LD      HL, status_buffer
    LD      DE, .status_3
    CALL    .cmp_14
    JR      Z, .ok_s2
    LD      A, 0xB1
    LD      B, 3
    JP      test_fail
.ok_s2:

    ;; --- 3rd motion_l ---
    LD      A, 'l'
    CALL    motion_l

    LD      HL, (cursor_offset)
    LD      DE, 3
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c3
    LD      A, 0xB1
    LD      B, 4
    JP      test_fail
.ok_c3:
    LD      HL, status_buffer
    LD      DE, .status_4
    CALL    .cmp_14
    JR      Z, .ok_s3
    LD      A, 0xB1
    LD      B, 5
    JP      test_fail
.ok_s3:

    JP      test_pass

; HL = lhs (status_buffer); DE = rhs (expected 14-byte string).
; Returns Z if first 14 bytes match; NZ otherwise. Trashes A, BC, DE, HL, F.
.cmp_14:
    LD      B, 14
.cmp_loop:
    LD      A, (DE)
    CP      (HL)
    RET     NZ
    INC     HL
    INC     DE
    DJNZ    .cmp_loop
    XOR     A                               ; CP succeeded; Z set
    RET

.payload:
    DEFB    "abcdef"
.status_2:
    DEFB    "-- visual -- 2"
.status_3:
    DEFB    "-- visual -- 3"
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
