; ============================================================
; Module: test/cases/render_emits-nonprintable-as-space.asm
; Purpose: Story 4.4 AC4 — render_emit_one_row substitutes 0x20
;          for non-printable bytes (NUL, C0 controls < 0x20 except
;          LF, DEL 0x7F, and all high-bit bytes 0x80..0xFF). The
;          shadow buffer must hold 0x20 at those positions AND the
;          captured BIOS_CONOUT byte stream must show 0x20 emitted
;          at each substituted cell (per-cell shadow vs physical-
;          screen invariant RI4). Closes deferred-work.md L77.
;
;          Setup buffer (14 bytes at logical [0..13]):
;            offset 0:  'a'    (printable)
;            offset 1:  0x00   (NUL — must render as 0x20)
;            offset 2:  'b'    (printable)
;            offset 3:  0x09   (TAB — must render as 0x20, AC4
;                              "TAB scope" intentional trade-off)
;            offset 4:  'c'    (printable)
;            offset 5:  0x0D   (CR — must render as 0x20, the
;                              Story 2.5 UAT step 11 fix now lives
;                              in the merged .hit_cr path)
;            offset 6:  'd'    (printable)
;            offset 7:  0x7F   (DEL — Story 4.4 review pin, closes
;                              the C0/C1 boundary gap between the
;                              <0x20 filter and the BIT 7 filter)
;            offset 8:  'e'    (printable)
;            offset 9:  0x80   (high-bit — must render as 0x20)
;            offset 10: 'f'    (printable)
;            offset 11: 0xFF   (high-bit — must render as 0x20)
;            offset 12: 'g'    (printable)
;            offset 13: 0x0A   (LF — line terminator, hits .hit_lf)
;
;          Pre-render shadow row 0 cells 0..13 = 0xFF (force every
;          cell to differ so each one emits and shows up in the
;          capture stream). Other shadow cells stay 0x20 to match
;          the past-EOL target so rows 1..22 emit nothing.
;
;          Post-render assertions:
;            (1) shadow row 0 cells 0..13 reflect substitution
;                pattern: 'a', 0x20, 'b', 0x20, 'c', 0x20, 'd',
;                0x20, 'e', 0x20, 'f', 0x20, 'g', 0x20.
;            (2) capture_buffer[4..17] holds the same 14-byte
;                content sequence (after the leading ESC Y 0 0
;                run-open at indices 0..3). Asserts the physical
;                stream actually emitted 0x20 at the substituted
;                positions — not just the shadow.
;
; AC reference: AC4 + AC9 (Story 4.4).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE0..0xED — shadow row 0 cell N mismatch (N = sentinel - 0xE0)
;   0xF0 — capture_buffer leading ESC byte != 0x1B
;   0xF1 — capture_buffer[1] != 'Y'
;   0xF2..0xFF — capture_buffer[4+N] content mismatch at cell N
;                (N = sentinel - 0xF2)
;   B    — diagnostic byte (actual value at failure site)
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

    ;; top_line_offset = 0; cursor_offset = 0 (on the 'a').
    LD      HL, 0
    LD      (top_line_offset), HL
    LD      HL, 0
    LD      (cursor_offset), HL

    ;; Gap state: 14 bytes in the before-gap half.
    LD      HL, GAP_BUFFER_BASE + 14
    LD      (gap_start), HL
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      (gap_end), HL

    ;; Write payload to GAP_BUFFER_BASE..+13 via LDIR.
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 14
    LDIR

    ;; shadow_buffer = all 0x20 (past-EOL match for rows 1..22 and
    ;; row 0 cells 14..79 — no emit there).
    LD      HL, shadow_buffer
    LD      (HL), 0x20
    LD      DE, shadow_buffer + 1
    LD      BC, SCREEN_ROWS * SCREEN_COLS - 1
    LDIR

    ;; Force row 0 cells 0..13 to differ — set sentinel 0xFF so
    ;; every cell in the substitution window forces an emit and
    ;; the capture stream contains the actual physical bytes.
    LD      HL, shadow_buffer
    LD      B, 14
.fill_sentinel:
    LD      (HL), 0xFF
    INC     HL
    DJNZ    .fill_sentinel

    ;; --- Call under test ---
    CALL    render_full

    ;; --- Verify shadow row 0 cells 0..13 (lock-step half) ---
    LD      HL, shadow_buffer
    LD      DE, .expected_shadow
    LD      B, 14
    LD      C, 0
.cmp_shadow:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .shadow_ok
    LD      B, A                        ; B = expected (diagnostic)
    LD      A, 0xE0
    ADD     A, C
    JP      test_fail
.shadow_ok:
    INC     HL
    INC     DE
    INC     C
    DJNZ    .cmp_shadow

    ;; --- Verify capture stream (physical-screen half) ---
    ;; Render-full's editable-row emit opens one run at row=0
    ;; col=0 because every cell 0..13 differs from sentinel
    ;; shadow. Capture layout:
    ;;   [0..3]  = ESC 'Y' 0x20 0x20    (run open, row=col=0)
    ;;   [4..17] = 14 content bytes per .expected_shadow
    ;;   [18..21]= ESC 'Y' cursor-row+0x20 cursor-col+0x20
    ;;             (final cursor reposition; cursor_offset=0 →
    ;;             row=0 col=0, so 0x1B 'Y' 0x20 0x20)
    LD      A, (test_capture_buffer + 0)
    CP      0x1B
    JR      Z, .esc_ok
    LD      B, A
    LD      A, 0xF0
    JP      test_fail
.esc_ok:
    LD      A, (test_capture_buffer + 1)
    CP      'Y'
    JR      Z, .y_ok
    LD      B, A
    LD      A, 0xF1
    JP      test_fail
.y_ok:

    LD      HL, test_capture_buffer + 4
    LD      DE, .expected_shadow
    LD      B, 14
    LD      C, 0
.cmp_capture:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .capture_ok
    LD      B, A                        ; diagnostic = expected
    LD      A, 0xF2
    ADD     A, C
    JP      test_fail
.capture_ok:
    INC     HL
    INC     DE
    INC     C
    DJNZ    .cmp_capture

    JP      test_pass

;; ----- Test-local data -----
.payload:
    DEFB    'a', 0x00, 'b', 0x09, 'c', 0x0D, 'd', 0x7F
    DEFB    'e', 0x80, 'f', 0xFF, 'g', 0x0A

;; Expected post-filter substitution for row 0 cells 0..13 — also
;; used as the content portion of the capture stream comparison
;; (run-open prefix lives at capture_buffer[0..3]).
.expected_shadow:
    DEFB    'a', 0x20, 'b', 0x20, 'c', 0x20, 'd', 0x20
    DEFB    'e', 0x20, 'f', 0x20, 'g', 0x20

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
