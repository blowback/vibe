; ============================================================
; Module: test/cases/render_full-marks-all-dirty.asm
; Purpose: AC3, AC7, AC16 (render_full-marks-all-dirty case) —
;          verify the AR3 full-redraw path:
;            1. render_mark_all_dirty sets every byte of the
;               dirty_rows bitmap to 0xFF.
;            2. render_full first marks every row dirty, then
;               runs render_diff, which (a) emits diffs and
;               (b) clears dirty_rows on completion.
;            3. With one non-space byte in the buffer ('x' at
;               logical 0), shadow[0] is written to 'x' after
;               render_full returns.
;
;          Setup:
;            - Subtest A standalone: dirty_rows = 0, then call
;              render_mark_all_dirty alone. Verify all 3 bytes
;              == 0xFF.
;            - Subtest B integrated: gap buffer = "x" (1 byte at
;              logical 0); shadow_buffer = all 0x20; dirty_rows
;              reset to 0; status_dirty = 0; cursor_offset = 1
;              (col 1, row 0). Call render_full. Verify
;              dirty_rows == 0 (cleared by render_diff) AND
;              shadow_buffer[0] == 'x'.
;
; AC reference: AC3 (render_full contract), AC7 (mark_all_dirty
;               contract), AC16 (full-marks-all-dirty case),
;               FR48, NFR7.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — After render_mark_all_dirty: dirty_rows[0] != 0xFF
;   0xE2 — After render_mark_all_dirty: dirty_rows[1] != 0xFF
;   0xE3 — After render_mark_all_dirty: dirty_rows[2] != 0xFF
;   0xE4 — After render_full: dirty_rows[0] != 0 (not cleared)
;   0xE5 — After render_full: dirty_rows[1] != 0
;   0xE6 — After render_full: dirty_rows[2] != 0
;   0xE7 — After render_full: shadow_buffer[0] != 'x'
;   0xE8 — After render_full: shadow_buffer[1] != 0x20 (over-emit)
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

    ;; --- Subtest A: render_mark_all_dirty in isolation ---
    XOR     A
    LD      (dirty_rows), A
    LD      (dirty_rows + 1), A
    LD      (dirty_rows + 2), A

    CALL    render_mark_all_dirty

    LD      A, (dirty_rows)
    CP      0xFF
    JR      Z, .ok_d0
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok_d0:
    LD      A, (dirty_rows + 1)
    CP      0xFF
    JR      Z, .ok_d1
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok_d1:
    LD      A, (dirty_rows + 2)
    CP      0xFF
    JR      Z, .ok_d2
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok_d2:

    ;; --- Subtest B: render_full end-to-end ---
    XOR     A
    LD      (test_capture_len), A
    LD      (status_dirty), A

    LD      HL, 0
    LD      (top_line_offset), HL
    LD      HL, 1
    LD      (cursor_offset), HL

    ;; Gap state: one byte before gap.
    LD      HL, GAP_BUFFER_BASE + 1
    LD      (gap_start), HL
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      (gap_end), HL

    ;; Write 'x' at GAP_BUFFER_BASE.
    LD      A, 'x'
    LD      (GAP_BUFFER_BASE), A

    ;; shadow_buffer = all 0x20.
    LD      HL, shadow_buffer
    LD      (HL), 0x20
    LD      DE, shadow_buffer + 1
    LD      BC, SCREEN_ROWS * SCREEN_COLS - 1
    LDIR

    ;; Reset dirty_rows so we observe render_full setting AND
    ;; clearing them.
    XOR     A
    LD      (dirty_rows), A
    LD      (dirty_rows + 1), A
    LD      (dirty_rows + 2), A

    CALL    render_full

    ;; --- Verify dirty_rows cleared after render_full ---
    LD      A, (dirty_rows)
    OR      A
    JR      Z, .ok_post_d0
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok_post_d0:
    LD      A, (dirty_rows + 1)
    OR      A
    JR      Z, .ok_post_d1
    LD      B, A
    LD      A, 0xE5
    JP      test_fail
.ok_post_d1:
    LD      A, (dirty_rows + 2)
    OR      A
    JR      Z, .ok_post_d2
    LD      B, A
    LD      A, 0xE6
    JP      test_fail
.ok_post_d2:

    ;; --- Verify shadow[0] == 'x' (the one diff cell emitted) ---
    LD      A, (shadow_buffer)
    CP      'x'
    JR      Z, .ok_sh0
    LD      B, A
    LD      A, 0xE7
    JP      test_fail
.ok_sh0:

    ;; --- Verify shadow[1] still 0x20 (past-EOL cell unchanged) ---
    LD      A, (shadow_buffer + 1)
    CP      0x20
    JR      Z, .ok_sh1
    LD      B, A
    LD      A, 0xE8
    JP      test_fail
.ok_sh1:

    JP      test_pass

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
