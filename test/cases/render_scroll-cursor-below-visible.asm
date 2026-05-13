; ============================================================
; Module: test/cases/render_scroll-cursor-below-visible.asm
; Purpose: AC4 step 1 + AC16 (render_scroll-cursor-below-visible
;          case) — verify the V2 scroll mechanism: when the
;          cursor's logical row lands outside [0, EDITABLE_ROWS-1],
;          render_diff advances top_line_offset forward by
;          (cursor_row - (EDITABLE_ROWS-1)) line breaks so the
;          cursor falls back to row EDITABLE_ROWS-1 (the last
;          editable row).
;
;          Setup:
;            - Buffer contains 30 line-feed bytes (30 empty
;              lines). gap_start = GAP_BUFFER_BASE + 30;
;              gap_end   = GAP_BUFFER_BASE + GAP_BUFFER_MAX.
;            - top_line_offset = 0.
;            - cursor_offset = 25 (the byte just after the 25th
;              LF — i.e. the start of logical line 25, row 25
;              relative to top).
;            - dirty_rows = 0; status_dirty = 0; shadow all 0x20.
;
;          Expected post-render_diff:
;            - top_line_offset advanced to 3 (= 25 - 22, the
;              "minimal advance" policy that puts cursor at row
;              EDITABLE_ROWS-1 = 22).
;            - dirty_rows = 0 (post-pass cleared by render_diff).
;            - Last 4 bytes of capture buffer = ESC, 'Y',
;              22+VT52_COORD_BIAS (= 0x36), 0+VT52_COORD_BIAS
;              (= 0x20) — the trailing cursor reposition lands
;              at row 22 col 0.
;
; AC reference: AC4 (step 1 scroll-adjust), AC16, V2.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — top_line_offset != 3
;   0xE2 — dirty_rows[0] != 0 (or dirty_rows[1]/[2] != 0)
;   0xE3 — capture trailing-4 byte 0 != VT52_ESC
;   0xE4 — capture trailing-4 byte 1 != VT52_GOTO
;   0xE5 — capture trailing-4 byte 2 != 22+VT52_COORD_BIAS
;          (cursor row not at EDITABLE_ROWS-1)
;   0xE6 — capture trailing-4 byte 3 != 0+VT52_COORD_BIAS
;          (cursor col not at 0)
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

    ;; top_line_offset = 0; cursor_offset = 25.
    LD      HL, 0
    LD      (top_line_offset), HL
    LD      HL, 25
    LD      (cursor_offset), HL

    ;; Gap state: 30 bytes before gap.
    LD      HL, GAP_BUFFER_BASE + 30
    LD      (gap_start), HL
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      (gap_end), HL

    ;; Write 30 0x0A bytes to GAP_BUFFER_BASE..+29 via LDIR-fill.
    LD      HL, GAP_BUFFER_BASE
    LD      (HL), 0x0A
    LD      DE, GAP_BUFFER_BASE + 1
    LD      BC, 29
    LDIR

    ;; shadow_buffer = all 0x20.
    LD      HL, shadow_buffer
    LD      (HL), 0x20
    LD      DE, shadow_buffer + 1
    LD      BC, SCREEN_ROWS * SCREEN_COLS - 1
    LDIR

    ;; dirty_rows = 0 (let scroll_adjust set them).
    XOR     A
    LD      (dirty_rows), A
    LD      (dirty_rows + 1), A
    LD      (dirty_rows + 2), A

    ;; --- Call under test ---
    CALL    render_diff

    ;; --- Verify top_line_offset == 3 ---
    LD      HL, (top_line_offset)
    LD      A, H
    OR      A
    JR      NZ, .fail_top
    LD      A, L
    CP      3
    JR      Z, .ok_top
.fail_top:
    LD      A, L
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok_top:

    ;; --- Verify dirty_rows all cleared ---
    LD      A, (dirty_rows)
    OR      A
    JR      NZ, .fail_dirty
    LD      A, (dirty_rows + 1)
    OR      A
    JR      NZ, .fail_dirty
    LD      A, (dirty_rows + 2)
    OR      A
    JR      Z, .ok_dirty
.fail_dirty:
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok_dirty:

    ;; --- Verify the trailing 4 bytes of capture are
    ;;     ESC 'Y' (22+bias) (0+bias) ---
    LD      A, (test_capture_len)
    SUB     4
    LD      L, A
    LD      H, 0
    LD      DE, test_capture_buffer
    ADD     HL, DE                      ; HL = capture + (len-4) = trailing-4 base

    LD      A, (HL)
    CP      VT52_ESC
    JR      Z, .ok_t0
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok_t0:
    INC     HL
    LD      A, (HL)
    CP      VT52_GOTO
    JR      Z, .ok_t1
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok_t1:
    INC     HL
    LD      A, (HL)
    CP      22 + VT52_COORD_BIAS
    JR      Z, .ok_t2
    LD      B, A
    LD      A, 0xE5
    JP      test_fail
.ok_t2:
    INC     HL
    LD      A, (HL)
    CP      VT52_COORD_BIAS
    JR      Z, .ok_t3
    LD      B, A
    LD      A, 0xE6
    JP      test_fail
.ok_t3:

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
