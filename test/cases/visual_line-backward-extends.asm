; ============================================================
; Module: test/cases/visual_line-backward-extends.asm
; Purpose: Story 3.4 AC5 / AC10 — verify the backward-swap arm of
;          visual_count_lines: cursor_ls < anchor → swap so HL=
;          cursor_ls (min), DE=anchor (max), then walk [min, max)
;          counting LFs. The status_compose_status_line tail
;          surfaces "-- visual line -- N".
;
;          Buffer "abc\nfoo\nbar\nxyz" (15 B; 4 lines; LFs at 3,
;          7, 11). Pre-set mode_byte = MODE_VISUAL, visual_submode
;          = VIS_LINE, visual_anchor = 12 (line 4 start),
;          cursor_offset = 12. Two CALL motion_k.
;
;          Expected progression:
;            after 1st motion_k: cursor=8 (line 3 col 0); anchor=12;
;                                walk [8, 12): byte 11 is LF → 1
;                                LF; line count = 2; status
;                                "-- visual line -- 2"
;            after 2nd motion_k: cursor=4; anchor=12; walk [4, 12):
;                                LFs at 7, 11 → 2 LFs; line count
;                                = 3; status "-- visual line -- 3"
;
; Sentinel 0xB7 — context byte:
;   0 — after 1st motion_k: cursor_offset != 8
;   1 — after 1st motion_k: status_buffer mismatch ("-- visual line -- 2")
;   2 — after 2nd motion_k: cursor_offset != 4
;   3 — after 2nd motion_k: status_buffer mismatch ("-- visual line -- 3")
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

    ;; Populate buffer "abc\nfoo\nbar\nxyz" (15 B).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 15
    LDIR
    LD      HL, GAP_BUFFER_BASE + 15
    LD      (gap_start), HL

    ;; Pre-seed VIS_LINE session at cursor=12 (line 4 start),
    ;; anchor=12 (also line 4 start).
    LD      HL, 12
    LD      (cursor_offset), HL
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_LINE
    LD      (visual_submode), A

    ;; --- 1st motion_k: cursor 12 → 8, count = 2 ---
    LD      A, 'k'
    CALL    motion_k

    LD      HL, (cursor_offset)
    LD      DE, 8
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c1
    LD      A, 0xB7
    LD      B, 0
    JP      test_fail
.ok_c1:
    LD      HL, status_buffer
    LD      DE, .status_2
    CALL    .cmp_19
    JR      Z, .ok_s1
    LD      A, 0xB7
    LD      B, 1
    JP      test_fail
.ok_s1:

    ;; --- 2nd motion_k: cursor 8 → 4, count = 3 ---
    LD      A, 'k'
    CALL    motion_k

    LD      HL, (cursor_offset)
    LD      DE, 4
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c2
    LD      A, 0xB7
    LD      B, 2
    JP      test_fail
.ok_c2:
    LD      HL, status_buffer
    LD      DE, .status_3
    CALL    .cmp_19
    JR      Z, .ok_s2
    LD      A, 0xB7
    LD      B, 3
    JP      test_fail
.ok_s2:

    JP      test_pass

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
