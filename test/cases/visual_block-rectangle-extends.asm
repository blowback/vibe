; ============================================================
; Module: test/cases/visual_block-rectangle-extends.asm
; Purpose: Story 3.5 AC3 / AC4 / AC8 / AC12 — verify that mode-
;          agnostic motions in MODE_VISUAL with submode VIS_BLOCK
;          flow through edits_compose_or_clear's MODE_VISUAL arm
;          into visual_extend's .block_arm, which calls
;          visual_count_block_dims (forward arm) and
;          visual_compose_status_block.
;
;          Buffer "abcde\nfghij\nklmno\npqrst" (23 B; 4 lines ×
;          5 chars; LFs at 5, 11, 17). Pre-set mode_byte =
;          MODE_VISUAL, visual_submode = VIS_BLOCK, visual_anchor
;          = 0, cursor_offset = 0.
;
;          Sequence:
;            motion_l → cursor=1; rows=1, cols=2; "-- visual block -- 1x2"
;            motion_l → cursor=2; rows=1, cols=3; "-- visual block -- 1x3"
;            motion_j → cursor=8 (line 2 col 2 sticky); rows=2,
;                        cols=3; "-- visual block -- 2x3"
;            motion_j → cursor=14 (line 3 col 2 sticky); rows=3,
;                        cols=3; "-- visual block -- 3x3"
;
;          Verifies BOTH the forward-rows arm (cursor_ls > anchor_ls
;          in visual_count_block_dims step 3) AND the forward-cols
;          arm (cursor_col > anchor_col in step 4).
;
; Sentinel 0xBB — context byte:
;   0 — after 1st motion_l: cursor_offset != 1
;   1 — after 1st motion_l: status mismatch ("-- visual block -- 1x2")
;   2 — after 2nd motion_l: cursor_offset != 2
;   3 — after 2nd motion_l: status mismatch ("-- visual block -- 1x3")
;   4 — after 1st motion_j: cursor_offset != 8
;   5 — after 1st motion_j: status mismatch ("-- visual block -- 2x3")
;   6 — after 2nd motion_j: cursor_offset != 14
;   7 — after 2nd motion_j: status mismatch ("-- visual block -- 3x3")
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

    LD      HL, 0
    LD      (cursor_offset), HL
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_BLOCK
    LD      (visual_submode), A

    ;; --- 1st motion_l: cursor 0 → 1; "1x2" ---
    LD      A, 'l'
    CALL    motion_l

    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c1
    LD      A, 0xBB
    LD      B, 0
    JP      test_fail
.ok_c1:
    LD      HL, status_buffer
    LD      DE, .status_1x2
    CALL    .cmp_22
    JR      Z, .ok_s1
    LD      A, 0xBB
    LD      B, 1
    JP      test_fail
.ok_s1:

    ;; --- 2nd motion_l: cursor 1 → 2; "1x3" ---
    LD      A, 'l'
    CALL    motion_l

    LD      HL, (cursor_offset)
    LD      DE, 2
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c2
    LD      A, 0xBB
    LD      B, 2
    JP      test_fail
.ok_c2:
    LD      HL, status_buffer
    LD      DE, .status_1x3
    CALL    .cmp_22
    JR      Z, .ok_s2
    LD      A, 0xBB
    LD      B, 3
    JP      test_fail
.ok_s2:

    ;; --- 1st motion_j: cursor 2 → 8 (line 2 col 2); "2x3" ---
    LD      A, 'j'
    CALL    motion_j

    LD      HL, (cursor_offset)
    LD      DE, 8
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c3
    LD      A, 0xBB
    LD      B, 4
    JP      test_fail
.ok_c3:
    LD      HL, status_buffer
    LD      DE, .status_2x3
    CALL    .cmp_22
    JR      Z, .ok_s3
    LD      A, 0xBB
    LD      B, 5
    JP      test_fail
.ok_s3:

    ;; --- 2nd motion_j: cursor 8 → 14 (line 3 col 2); "3x3" ---
    LD      A, 'j'
    CALL    motion_j

    LD      HL, (cursor_offset)
    LD      DE, 14
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c4
    LD      A, 0xBB
    LD      B, 6
    JP      test_fail
.ok_c4:
    LD      HL, status_buffer
    LD      DE, .status_3x3
    CALL    .cmp_22
    JR      Z, .ok_s4
    LD      A, 0xBB
    LD      B, 7
    JP      test_fail
.ok_s4:

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
.status_1x2:
    DEFB    "-- visual block -- 1x2"
.status_1x3:
    DEFB    "-- visual block -- 1x3"
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
