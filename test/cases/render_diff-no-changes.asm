; ============================================================
; Module: test/cases/render_diff-no-changes.asm
; Purpose: AC16, AC4 step 5 (RI4 cursor reposition) — verify
;          that render_diff on an idle frame emits ONLY the
;          trailing cursor-reposition (4 bytes: ESC 'Y' 0x20
;          0x20). No dirty rows, empty buffer, status not dirty
;          — the NFR1 idle-no-emission contract holds modulo
;          RI4's defensive cursor re-emit.
;
;          Setup:
;            - gap buffer empty: gap_start = GAP_BUFFER_BASE,
;              gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX.
;            - cursor_offset = 0, top_line_offset = 0.
;            - shadow_buffer = all 0x20 (matches the buffer's
;              "all space" target).
;            - dirty_rows = 0, status_dirty = 0.
;
;          Expected post-render_diff:
;            - test_capture_len = 4
;            - test_capture_buffer[0..3] = ESC, 'Y', 0x20, 0x20
;            - shadow_buffer[0] still 0x20 (no overwrite)
;            - dirty_rows = 0 (no rows became dirty)
;            - status_dirty still 0
;
; AC reference: AC4 (step 5 — trailing cursor reposition),
;               AC16 (render_diff-no-changes case), NFR1.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — test_capture_len != 4
;   0xE2 — test_capture_buffer[0] != VT52_ESC
;   0xE3 — test_capture_buffer[1] != VT52_GOTO ('Y')
;   0xE4 — test_capture_buffer[2] != VT52_COORD_BIAS (row 0 biased)
;   0xE5 — test_capture_buffer[3] != VT52_COORD_BIAS (col 0 biased)
;   0xE6 — shadow_buffer[0] != 0x20 (shadow corrupted)
;   0xE7 — dirty_rows nonzero post-call (bits leaked in)
;   0xE8 — status_dirty nonzero post-call
;   B    — diagnostic byte (the offending value where applicable)
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
;; BIOS_CONOUT override: redirect render emits into a test-local
;; capture buffer rather than letting them escape to iz-cpm stdout
;; (where they would collide with the PASS/FAIL grep). bios.inc
;; wraps its production EQU in IFNDEF BIOS_CONOUT_OVERRIDE
;; (Story 1.11 / AC17); setting that marker plus the EQU below
;; redirects render.asm's CALL BIOS_CONOUT to the capture stub.
    DEFINE BIOS_CONOUT_OVERRIDE
BIOS_CONOUT EQU test_bios_conout
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----

    ;; Reset the capture buffer and state fields render reads.
    XOR     A
    LD      (test_capture_len), A
    LD      (status_dirty), A

    ;; top_line_offset = 0, cursor_offset = 0.
    LD      HL, 0
    LD      (top_line_offset), HL
    LD      (cursor_offset), HL

    ;; Empty gap buffer: gap covers the entire payload.
    LD      HL, GAP_BUFFER_BASE
    LD      (gap_start), HL
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      (gap_end), HL

    ;; Zero dirty_rows (3 bytes).
    XOR     A
    LD      (dirty_rows), A
    LD      (dirty_rows + 1), A
    LD      (dirty_rows + 2), A

    ;; shadow_buffer = all 0x20 (LDIR-fill, same idiom render_init uses).
    LD      HL, shadow_buffer
    LD      (HL), 0x20
    LD      DE, shadow_buffer + 1
    LD      BC, SCREEN_ROWS * SCREEN_COLS - 1
    LDIR

    ;; --- Call under test ---
    CALL    render_diff

    ;; --- Verify emit count == 4 ---
    LD      A, (test_capture_len)
    CP      4
    JR      Z, .ok_len
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok_len:

    ;; --- Verify byte 0 == VT52_ESC ---
    LD      A, (test_capture_buffer)
    CP      VT52_ESC
    JR      Z, .ok_b0
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok_b0:

    ;; --- Verify byte 1 == VT52_GOTO ('Y') ---
    LD      A, (test_capture_buffer + 1)
    CP      VT52_GOTO
    JR      Z, .ok_b1
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok_b1:

    ;; --- Verify byte 2 == 0 + VT52_COORD_BIAS (row 0 biased) ---
    LD      A, (test_capture_buffer + 2)
    CP      VT52_COORD_BIAS
    JR      Z, .ok_b2
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok_b2:

    ;; --- Verify byte 3 == 0 + VT52_COORD_BIAS (col 0 biased) ---
    LD      A, (test_capture_buffer + 3)
    CP      VT52_COORD_BIAS
    JR      Z, .ok_b3
    LD      B, A
    LD      A, 0xE5
    JP      test_fail
.ok_b3:

    ;; --- Verify shadow_buffer[0] unchanged (no overwrite path fired) ---
    LD      A, (shadow_buffer)
    CP      0x20
    JR      Z, .ok_shadow
    LD      B, A
    LD      A, 0xE6
    JP      test_fail
.ok_shadow:

    ;; --- Verify dirty_rows all zero ---
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
    LD      A, 0xE7
    JP      test_fail
.ok_dirty:

    ;; --- Verify status_dirty still zero ---
    LD      A, (status_dirty)
    OR      A
    JR      Z, .ok_status
    LD      B, A
    LD      A, 0xE8
    JP      test_fail
.ok_status:

    JP      test_pass

;; ----- Capture stub + buffer + length -----
    INCLUDE "../inc/test_bios_conout_capture.inc"

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"

;; ----- input_loop stub (resolves bdos_error_funnel symbol) -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST (positional anchor: static_data_base = $) -----
    INCLUDE "../../inc/state.inc"
