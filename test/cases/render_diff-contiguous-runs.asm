; ============================================================
; Module: test/cases/render_diff-contiguous-runs.asm
; Purpose: AC4 + AC16 (render_diff-contiguous-runs case) — verify
;          that two non-adjacent differing-cell ranges in one row
;          produce TWO separate ESC Y sequences, not one merged
;          range. Mid-row cells that already match shadow MUST
;          NOT be re-emitted; the diff render is contiguous-run
;          (FR47 / NFR1), not whole-row.
;
;          Setup:
;            - gap buffer = "ab" (cols 0..1), then 8 spaces
;              (cols 2..9), then "xy" (cols 10..11) — 12 bytes
;              at logical [0..11]. No newline.
;              gap_start = GAP_BUFFER_BASE + 12;
;              gap_end   = GAP_BUFFER_BASE + GAP_BUFFER_MAX.
;            - top_line_offset = 0; cursor_offset = 12 (col 12).
;            - shadow_buffer = all 0x20 (cols 2..9 already match
;              their targets — those cells must NOT emit).
;            - dirty_rows[0] = 0x01.
;            - status_dirty = 0.
;
;          Expected emit (16 bytes, three ESC Y sequences):
;            ESC 'Y' (0+bias) (0+bias)  -- run 1 at col 0
;            'a' 'b'
;            ESC 'Y' (0+bias) (10+bias) -- run 2 at col 10
;            'x' 'y'
;            ESC 'Y' (0+bias) (12+bias) -- RI4 cursor reposition
;
;          Verification strategy: count VT52_ESC bytes in the
;          capture buffer. Three ESC bytes = two run opens +
;          one cursor reposition. One merged ESC Y would yield
;          only two ESC bytes (one run + cursor); a malformed
;          render that emitted ESC Y for every column would
;          yield far more.
;
; AC reference: AC4 (step 2 contiguous-run rule), AC16, FR47,
;               NFR1.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — VT52_ESC byte count in capture != 3
;   0xE2 — shadow_buffer[0] != 'a' (run 1 not written)
;   0xE3 — shadow_buffer[10] != 'x' (run 2 not written)
;   0xE4 — shadow_buffer[5] != 0x20 (mid-row cell corrupted by
;          spurious overwrite)
;   0xE5 — capture[2] != 0+VT52_COORD_BIAS (run 1 row wrong)
;   0xE6 — capture[3] != 0+VT52_COORD_BIAS (run 1 col wrong)
;   0xE7 — dirty_rows[0] != 0 (dirty not cleared)
;   B    — diagnostic byte (e.g. the actual ESC-count value)
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

    ;; top_line_offset = 0; cursor_offset = 12.
    LD      HL, 0
    LD      (top_line_offset), HL
    LD      HL, 12
    LD      (cursor_offset), HL

    ;; Gap state: 12 bytes before gap.
    LD      HL, GAP_BUFFER_BASE + 12
    LD      (gap_start), HL
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      (gap_end), HL

    ;; Write "ab        xy" (12 bytes) to GAP_BUFFER_BASE.
    LD      HL, .src
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 12
    LDIR

    ;; shadow_buffer = all 0x20.
    LD      HL, shadow_buffer
    LD      (HL), 0x20
    LD      DE, shadow_buffer + 1
    LD      BC, SCREEN_ROWS * SCREEN_COLS - 1
    LDIR

    ;; dirty_rows: only row 0.
    LD      A, 0x01
    LD      (dirty_rows), A
    XOR     A
    LD      (dirty_rows + 1), A
    LD      (dirty_rows + 2), A

    ;; --- Call under test ---
    CALL    render_diff

    ;; --- Count VT52_ESC bytes in the capture buffer ---
    ;; Walk capture[0..test_capture_len-1]; tally bytes equal to
    ;; VT52_ESC. Expected: 3 (two run opens + RI4 cursor).
    LD      A, (test_capture_len)
    LD      B, A                        ; B = remaining byte count
    LD      HL, test_capture_buffer
    LD      C, 0                        ; C = ESC count
.scan_loop:
    LD      A, B
    OR      A
    JR      Z, .scan_done
    LD      A, (HL)
    CP      VT52_ESC
    JR      NZ, .scan_next
    INC     C
.scan_next:
    INC     HL
    DEC     B
    JR      .scan_loop
.scan_done:
    LD      A, C
    CP      3
    JR      Z, .ok_esc_count
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok_esc_count:

    ;; --- Verify shadow_buffer[0] == 'a' (first run wrote) ---
    LD      A, (shadow_buffer)
    CP      'a'
    JR      Z, .ok_sh0
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok_sh0:

    ;; --- Verify shadow_buffer[10] == 'x' (second run wrote) ---
    LD      A, (shadow_buffer + 10)
    CP      'x'
    JR      Z, .ok_sh10
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok_sh10:

    ;; --- Verify shadow_buffer[5] still 0x20 (mid-cell sanity) ---
    LD      A, (shadow_buffer + 5)
    CP      0x20
    JR      Z, .ok_sh5
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok_sh5:

    ;; --- Verify capture[2] / capture[3] = run-1 row/col ---
    LD      A, (test_capture_buffer + 2)
    CP      VT52_COORD_BIAS
    JR      Z, .ok_r1row
    LD      B, A
    LD      A, 0xE5
    JP      test_fail
.ok_r1row:

    LD      A, (test_capture_buffer + 3)
    CP      VT52_COORD_BIAS
    JR      Z, .ok_r1col
    LD      B, A
    LD      A, 0xE6
    JP      test_fail
.ok_r1col:

    ;; --- Verify dirty_rows[0] cleared ---
    LD      A, (dirty_rows)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xE7
    JP      test_fail
.ok_dirty:

    JP      test_pass

;; ----- Test-local data -----
.src:    DEFB "ab        xy"        ; 12 bytes: "ab" + 8 spaces + "xy"

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
