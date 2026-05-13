; ============================================================
; Module: test/cases/render_diff-single-row-change.asm
; Purpose: AC4 + AC16 (render_diff-single-row-change case) —
;          one dirty row, one contiguous run of cells differing
;          from shadow. Confirms FR47 (diff render) emits exactly
;          the differing cells in the contiguous range, preceded
;          by a single ESC Y row col, followed by the RI4
;          trailing cursor-reposition.
;
;          Setup:
;            - gap buffer = "hello" at logical [0..4]:
;              physical bytes at GAP_BUFFER_BASE+0..4 hold "hello";
;              gap_start = GAP_BUFFER_BASE + 5;
;              gap_end   = GAP_BUFFER_BASE + GAP_BUFFER_MAX.
;            - top_line_offset = 0; cursor_offset = 5 (col 5, row 0).
;            - shadow_buffer = all 0x20 (row 0 differs at cols 0..4).
;            - dirty_rows[0] |= 0x01 (row 0 dirty); rows 1..23 clean.
;            - status_dirty = 0.
;
;          Expected emit sequence (13 bytes total):
;            ESC 'Y' (0+bias) (0+bias)  -- run open at row 0 col 0
;            'h' 'e' 'l' 'l' 'o'        -- 5 content bytes
;            ESC 'Y' (0+bias) (5+bias)  -- RI4 cursor at row 0 col 5
;
;          Expected post-state:
;            - shadow_buffer[0..4]  = "hello"
;            - shadow_buffer[5..79] = 0x20 (unchanged)
;            - dirty_rows           = 0 (cleared)
;
; AC reference: AC4 (steps 2 + 5), AC16 (single-row-change),
;               FR47.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — test_capture_len != 13
;   0xE2 — capture[0] != VT52_ESC (open run start corrupt)
;   0xE3 — capture[1] != VT52_GOTO
;   0xE4 — capture[2] != 0+VT52_COORD_BIAS (row 0)
;   0xE5 — capture[3] != 0+VT52_COORD_BIAS (col 0)
;   0xE6 — capture[4] != 'h'                 (run byte 0)
;   0xE7 — capture[8] != 'o'                 (run byte 4)
;   0xE8 — capture[9] != VT52_ESC            (cursor reposition start)
;   0xE9 — capture[12] != 5+VT52_COORD_BIAS  (cursor col)
;   0xEA — shadow_buffer[0] != 'h'           (shadow not updated)
;   0xEB — shadow_buffer[5] != 0x20          (shadow over-written past run)
;   0xEC — dirty_rows[0] != 0                (dirty not cleared)
;   B    — diagnostic byte
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
    DEFINE BIOS_CONOUT_OVERRIDE
BIOS_CONOUT EQU test_bios_conout
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"

    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----

    XOR     A
    LD      (test_capture_len), A
    LD      (status_dirty), A

    ;; top_line_offset = 0; cursor_offset = 5.
    LD      HL, 0
    LD      (top_line_offset), HL
    LD      HL, 5
    LD      (cursor_offset), HL

    ;; Gap state: "hello" in the before-gap half (5 bytes).
    LD      HL, GAP_BUFFER_BASE + 5
    LD      (gap_start), HL
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      (gap_end), HL

    ;; Write "hello" to GAP_BUFFER_BASE..GAP_BUFFER_BASE+4 via LDIR.
    LD      HL, .hello_src
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 5
    LDIR

    ;; shadow_buffer = all 0x20.
    LD      HL, shadow_buffer
    LD      (HL), 0x20
    LD      DE, shadow_buffer + 1
    LD      BC, SCREEN_ROWS * SCREEN_COLS - 1
    LDIR

    ;; dirty_rows: row 0 dirty.
    LD      A, 0x01
    LD      (dirty_rows), A
    XOR     A
    LD      (dirty_rows + 1), A
    LD      (dirty_rows + 2), A

    ;; --- Call under test ---
    CALL    render_diff

    ;; --- Verify emit count == 13 ---
    LD      A, (test_capture_len)
    CP      13
    JR      Z, .ok_len
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok_len:

    ;; --- Verify capture[0] == VT52_ESC ---
    LD      A, (test_capture_buffer)
    CP      VT52_ESC
    JR      Z, .ok_b0
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok_b0:

    ;; --- Verify capture[1] == VT52_GOTO ---
    LD      A, (test_capture_buffer + 1)
    CP      VT52_GOTO
    JR      Z, .ok_b1
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok_b1:

    ;; --- Verify capture[2] == 0+bias (row 0) ---
    LD      A, (test_capture_buffer + 2)
    CP      VT52_COORD_BIAS
    JR      Z, .ok_b2
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok_b2:

    ;; --- Verify capture[3] == 0+bias (col 0) ---
    LD      A, (test_capture_buffer + 3)
    CP      VT52_COORD_BIAS
    JR      Z, .ok_b3
    LD      B, A
    LD      A, 0xE5
    JP      test_fail
.ok_b3:

    ;; --- Verify capture[4] == 'h' ---
    LD      A, (test_capture_buffer + 4)
    CP      'h'
    JR      Z, .ok_b4
    LD      B, A
    LD      A, 0xE6
    JP      test_fail
.ok_b4:

    ;; --- Verify capture[8] == 'o' ---
    LD      A, (test_capture_buffer + 8)
    CP      'o'
    JR      Z, .ok_b8
    LD      B, A
    LD      A, 0xE7
    JP      test_fail
.ok_b8:

    ;; --- Verify capture[9] == VT52_ESC (cursor-reposition open) ---
    LD      A, (test_capture_buffer + 9)
    CP      VT52_ESC
    JR      Z, .ok_b9
    LD      B, A
    LD      A, 0xE8
    JP      test_fail
.ok_b9:

    ;; --- Verify capture[12] == 5+bias (cursor col 5) ---
    LD      A, (test_capture_buffer + 12)
    CP      5 + VT52_COORD_BIAS
    JR      Z, .ok_b12
    LD      B, A
    LD      A, 0xE9
    JP      test_fail
.ok_b12:

    ;; --- Verify shadow_buffer[0] == 'h' ---
    LD      A, (shadow_buffer)
    CP      'h'
    JR      Z, .ok_shadow0
    LD      B, A
    LD      A, 0xEA
    JP      test_fail
.ok_shadow0:

    ;; --- Verify shadow_buffer[5] == 0x20 (past-run cell unchanged) ---
    LD      A, (shadow_buffer + 5)
    CP      0x20
    JR      Z, .ok_shadow5
    LD      B, A
    LD      A, 0xEB
    JP      test_fail
.ok_shadow5:

    ;; --- Verify dirty_rows[0] cleared ---
    LD      A, (dirty_rows)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xEC
    JP      test_fail
.ok_dirty:

    JP      test_pass

;; ----- Test-local data -----
.hello_src: DEFB "hello"

;; ----- Capture stub + buffer + length -----
    INCLUDE "../inc/test_bios_conout_capture.inc"

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
