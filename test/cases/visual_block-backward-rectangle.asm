; ============================================================
; Module: test/cases/visual_block-backward-rectangle.asm
; Purpose: Story 3.5 AC4 / AC8 / AC12 — verify BOTH backward-rows
;          and backward-cols swap arms of visual_count_block_dims.
;
;          Buffer "abcde\nfghij\nklmno\npqrst" (23 B; 4 lines × 5
;          chars; LFs at 5, 11, 17). Pre-set mode_byte =
;          MODE_VISUAL, visual_submode = VIS_BLOCK, visual_anchor
;          = 14 (line 3 col 2 = 'm'), cursor_offset = 14.
;
;          Sequence:
;            motion_k → cursor=8 (line 2 col 2 sticky); rows=2,
;                        cols=1; "-- visual block -- 2x1"
;                        (cursor_ls=6 < anchor_ls=12 → backward-rows
;                        swap arm fires; cursor_col=2 == anchor_col=2
;                        so cols stays at 1)
;            motion_h × 2 → cursor=6 (line 2 col 0); rows=2, cols=3;
;                        "-- visual block -- 2x3" (cursor_col=0 <
;                        anchor_col=2 → backward-cols swap arm
;                        fires; |0-2|+1=3)
;            motion_k → cursor=0 (line 1 col 0); rows=3, cols=3;
;                        "-- visual block -- 3x3" (cursor_ls=0,
;                        anchor_ls=12 → LFs in [0,12) = 2 → rows=3;
;                        cursor_col=0 < anchor_col=2 → backward-cols
;                        swap arm fires again)
;
; Sentinel 0xBD — context byte:
;   0 — after motion_k: cursor_offset != 8
;   1 — after motion_k: status mismatch ("-- visual block -- 2x1")
;   2 — after motion_h × 2: cursor_offset != 6
;   3 — after motion_h × 2: status mismatch ("-- visual block -- 2x3")
;   4 — after motion_k: cursor_offset != 0
;   5 — after motion_k: status mismatch ("-- visual block -- 3x3")
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

    ;; Populate "abcde\nfghij\nklmno\npqrst" (23 B; LFs at 5, 11, 17).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 23
    LDIR
    LD      HL, GAP_BUFFER_BASE + 23
    LD      (gap_start), HL

    LD      HL, 14
    LD      (cursor_offset), HL
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_BLOCK
    LD      (visual_submode), A

    ;; --- motion_k: cursor 14 → 8 (line 2 col 2); "2x1" ---
    LD      A, 'k'
    CALL    motion_k

    LD      HL, (cursor_offset)
    LD      DE, 8
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c1
    LD      A, 0xBD
    LD      B, 0
    JP      test_fail
.ok_c1:
    LD      HL, status_buffer
    LD      DE, .status_2x1
    CALL    .cmp_22
    JR      Z, .ok_s1
    LD      A, 0xBD
    LD      B, 1
    JP      test_fail
.ok_s1:

    ;; --- motion_h × 2: cursor 8 → 7 → 6 (line 2 col 0); "2x3" ---
    LD      A, 'h'
    CALL    motion_h
    LD      A, 'h'
    CALL    motion_h

    LD      HL, (cursor_offset)
    LD      DE, 6
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c2
    LD      A, 0xBD
    LD      B, 2
    JP      test_fail
.ok_c2:
    LD      HL, status_buffer
    LD      DE, .status_2x3
    CALL    .cmp_22
    JR      Z, .ok_s2
    LD      A, 0xBD
    LD      B, 3
    JP      test_fail
.ok_s2:

    ;; --- motion_k: cursor 6 → 0 (line 1 col 0); "3x3" ---
    LD      A, 'k'
    CALL    motion_k

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_c3
    LD      A, 0xBD
    LD      B, 4
    JP      test_fail
.ok_c3:
    LD      HL, status_buffer
    LD      DE, .status_3x3
    CALL    .cmp_22
    JR      Z, .ok_s3
    LD      A, 0xBD
    LD      B, 5
    JP      test_fail
.ok_s3:

    JP      test_pass

; HL = lhs (status_buffer); DE = rhs (expected 22-byte string).
; Returns Z if first 22 bytes match. Trashes A, B, DE, HL, F.
.cmp_22:
    LD      B, 22
.cmp_loop:
    LD      A, (DE)
    CP      (HL)
    RET     NZ
    INC     HL
    INC     DE
    DJNZ    .cmp_loop
    XOR     A
    RET

.payload:
    DEFB    "abcde", 0x0A, "fghij", 0x0A, "klmno", 0x0A, "pqrst"
.status_2x1:
    DEFB    "-- visual block -- 2x1"
.status_2x3:
    DEFB    "-- visual block -- 2x3"
.status_3x3:
    DEFB    "-- visual block -- 3x3"

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
