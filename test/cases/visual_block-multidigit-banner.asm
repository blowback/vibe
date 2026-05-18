; ============================================================
; Module: test/cases/visual_block-multidigit-banner.asm
; Purpose: Story 3.5 AC6 / AC8 / AC12 (review patch P1) — exercise
;          the dual-`status_u16_to_dec` call pattern in
;          visual_compose_status_block at multi-digit row and
;          column counts. The pre-Story-3.5 banner tests only
;          assert single-digit RxC ("1x1".."3x3"); a regression
;          in status_dec_dest marshalling between the two emits
;          (e.g. emit-flag failing to reset across calls, or
;          leading-zero suppression breaking on the cols arm)
;          would not be caught by them.
;
;          Buffer: 12 lines of 12 chars each, LF-separated, no
;          trailing LF. Line content = "0123456789AB" repeated.
;          Total: 12 × 12 + 11 LFs = 155 B.
;          Line starts: 0, 13, 26, 39, 52, 65, 78, 91, 104, 117,
;          130, 143.
;
;          Set mode_byte = MODE_VISUAL, visual_submode = VIS_BLOCK,
;          visual_anchor = 0 (line 1 col 0). Drive visual_extend
;          three times with the cursor at different offsets:
;            cursor=11   → 1x12   "-- visual block -- 1x12"  (23 B)
;            cursor=143  → 12x1   "-- visual block -- 12x1"  (23 B)
;            cursor=154  → 12x12  "-- visual block -- 12x12" (24 B)
;
;          Each check compares status_buffer[0..N] against the
;          expected literal AND asserts status_buffer[N] is the
;          space-pad byte (0x20). status_set_message strips the
;          NUL from the compose-scratch and space-pads the rest
;          of status_buffer up to STATUS_LINE_WIDTH — so the
;          first space-byte at status_buffer[N] proves the
;          banner ended at exactly N bytes (catching too-long
;          regressions in the cols emit).
;
; Sentinel 0xBF — context byte:
;   0 — 1x12 status mismatch
;   1 — 1x12 status_buffer[23] != ' ' (banner overran)
;   2 — 12x1 status mismatch
;   3 — 12x1 status_buffer[23] != ' ' (banner overran)
;   4 — 12x12 status mismatch
;   5 — 12x12 status_buffer[24] != ' ' (banner overran)
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

    ;; Populate 12 × 12-char lines, LF-separated, no trailing LF.
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 155
    LDIR
    LD      HL, GAP_BUFFER_BASE + 155
    LD      (gap_start), HL

    LD      HL, 0
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_BLOCK
    LD      (visual_submode), A

    ;; --- Case 1: cursor=11 → "1x12" (multi-digit cols only) ---
    LD      HL, 11
    LD      (cursor_offset), HL
    CALL    visual_extend

    LD      HL, status_buffer
    LD      DE, .status_1x12
    LD      B, 23
    CALL    .cmp_n
    JR      Z, .ok_s1
    LD      A, 0xBF
    LD      B, 0
    JP      test_fail
.ok_s1:
    LD      A, (status_buffer + 23)
    CP      ' '
    JR      Z, .ok_n1
    LD      A, 0xBF
    LD      B, 1
    JP      test_fail
.ok_n1:

    ;; --- Case 2: cursor=143 → "12x1" (multi-digit rows only) ---
    LD      HL, 143
    LD      (cursor_offset), HL
    CALL    visual_extend

    LD      HL, status_buffer
    LD      DE, .status_12x1
    LD      B, 23
    CALL    .cmp_n
    JR      Z, .ok_s2
    LD      A, 0xBF
    LD      B, 2
    JP      test_fail
.ok_s2:
    LD      A, (status_buffer + 23)
    CP      ' '
    JR      Z, .ok_n2
    LD      A, 0xBF
    LD      B, 3
    JP      test_fail
.ok_n2:

    ;; --- Case 3: cursor=154 → "12x12" (multi-digit rows AND cols) ---
    LD      HL, 154
    LD      (cursor_offset), HL
    CALL    visual_extend

    LD      HL, status_buffer
    LD      DE, .status_12x12
    LD      B, 24
    CALL    .cmp_n
    JR      Z, .ok_s3
    LD      A, 0xBF
    LD      B, 4
    JP      test_fail
.ok_s3:
    LD      A, (status_buffer + 24)
    CP      ' '
    JR      Z, .ok_n3
    LD      A, 0xBF
    LD      B, 5
    JP      test_fail
.ok_n3:

    JP      test_pass

; HL = lhs; DE = rhs; B = byte count. Returns Z if all match.
; Trashes A, B, DE, HL, F.
.cmp_n:
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
    DEFB    "0123456789AB", 0x0A     ; line 1  (offsets   0..12)
    DEFB    "0123456789AB", 0x0A     ; line 2  (offsets  13..25)
    DEFB    "0123456789AB", 0x0A     ; line 3  (offsets  26..38)
    DEFB    "0123456789AB", 0x0A     ; line 4  (offsets  39..51)
    DEFB    "0123456789AB", 0x0A     ; line 5  (offsets  52..64)
    DEFB    "0123456789AB", 0x0A     ; line 6  (offsets  65..77)
    DEFB    "0123456789AB", 0x0A     ; line 7  (offsets  78..90)
    DEFB    "0123456789AB", 0x0A     ; line 8  (offsets  91..103)
    DEFB    "0123456789AB", 0x0A     ; line 9  (offsets 104..116)
    DEFB    "0123456789AB", 0x0A     ; line 10 (offsets 117..129)
    DEFB    "0123456789AB", 0x0A     ; line 11 (offsets 130..142)
    DEFB    "0123456789AB"           ; line 12 (offsets 143..154; no trailing LF)
.status_1x12:
    DEFB    "-- visual block -- 1x12"
.status_12x1:
    DEFB    "-- visual block -- 12x1"
.status_12x12:
    DEFB    "-- visual block -- 12x12"

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
