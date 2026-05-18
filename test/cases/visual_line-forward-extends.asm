; ============================================================
; Module: test/cases/visual_line-forward-extends.asm
; Purpose: Story 3.4 AC3 / AC5 / AC10 — verify that mode-agnostic
;          motions in MODE_VISUAL with submode VIS_LINE flow
;          through edits_compose_or_clear's MODE_VISUAL arm into
;          visual_extend's .line_arm, which calls visual_count_lines
;          (forward arm of the SBC) and visual_compose_status_line.
;
;          Buffer "abc\nfoo\nbar\nxyz" (15 B; 4 lines; LFs at 3,
;          7, 11). Pre-set mode_byte = MODE_VISUAL, visual_submode
;          = VIS_LINE, visual_anchor = 0, cursor_offset = 0.
;          Three CALL motion_j; each call's tail-JP edits_compose_or_clear
;          hits the MODE_VISUAL arm → visual_extend → .line_arm →
;          visual_count_lines + visual_compose_status_line.
;
;          Expected progression:
;            after 1st motion_j: cursor=4 (line 2 start), status
;                                "-- visual line -- 2" (LF at 3
;                                between cursor_ls=4 and anchor=0)
;            after 2nd motion_j: cursor=8, status "-- visual line -- 3"
;            after 3rd motion_j: cursor=12, status "-- visual line -- 4"
;
; Sentinel 0xB6 — context byte:
;   0 — after 1st motion_j: cursor_offset != 4
;   1 — after 1st motion_j: status_buffer mismatch ("-- visual line -- 2")
;   2 — after 2nd motion_j: cursor_offset != 8
;   3 — after 2nd motion_j: status_buffer mismatch ("-- visual line -- 3")
;   4 — after 3rd motion_j: cursor_offset != 12
;   5 — after 3rd motion_j: status_buffer mismatch ("-- visual line -- 4")
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

    ;; Populate buffer "abc\nfoo\nbar\nxyz" (15 B; LFs at 3, 7, 11).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 15
    LDIR
    LD      HL, GAP_BUFFER_BASE + 15
    LD      (gap_start), HL

    ;; Pre-seed VIS_LINE session at cursor=0, anchor=0.
    LD      HL, 0
    LD      (cursor_offset), HL
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_LINE
    LD      (visual_submode), A

    ;; --- 1st motion_j: cursor 0 → 4, count = 2 ---
    LD      A, 'j'
    CALL    motion_j

    LD      HL, (cursor_offset)
    LD      DE, 4
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c1
    LD      A, 0xB6
    LD      B, 0
    JP      test_fail
.ok_c1:
    LD      HL, status_buffer
    LD      DE, .status_2
    CALL    .cmp_19
    JR      Z, .ok_s1
    LD      A, 0xB6
    LD      B, 1
    JP      test_fail
.ok_s1:

    ;; --- 2nd motion_j: cursor 4 → 8, count = 3 ---
    LD      A, 'j'
    CALL    motion_j

    LD      HL, (cursor_offset)
    LD      DE, 8
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c2
    LD      A, 0xB6
    LD      B, 2
    JP      test_fail
.ok_c2:
    LD      HL, status_buffer
    LD      DE, .status_3
    CALL    .cmp_19
    JR      Z, .ok_s2
    LD      A, 0xB6
    LD      B, 3
    JP      test_fail
.ok_s2:

    ;; --- 3rd motion_j: cursor 8 → 12, count = 4 ---
    LD      A, 'j'
    CALL    motion_j

    LD      HL, (cursor_offset)
    LD      DE, 12
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c3
    LD      A, 0xB6
    LD      B, 4
    JP      test_fail
.ok_c3:
    LD      HL, status_buffer
    LD      DE, .status_4
    CALL    .cmp_19
    JR      Z, .ok_s3
    LD      A, 0xB6
    LD      B, 5
    JP      test_fail
.ok_s3:

    JP      test_pass

; HL = lhs (status_buffer); DE = rhs (expected 19-byte string).
; Returns Z if first 19 bytes match. Trashes A, B, DE, HL, F.
.cmp_19:
    LD      B, 19
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
    DEFB    "abc", 0x0A, "foo", 0x0A, "bar", 0x0A, "xyz"
.status_2:
    DEFB    "-- visual line -- 2"
.status_3:
    DEFB    "-- visual line -- 3"
.status_4:
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
