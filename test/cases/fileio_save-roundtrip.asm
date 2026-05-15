; ============================================================
; Module: test/cases/fileio_save-roundtrip.asm
; Purpose: AC12 — verify fileio_save's full round-trip: write 13
;          bytes of "hello world\r\n" through fileio_save, then
;          call fileio_load on the same name and assert the
;          after-gap region matches byte-for-byte. Also pin the
;          post-save status banner, buffer_dirty clear, and the
;          gap-state-unchanged invariant.
;
;          The test populates the gap by directly writing into
;          the before-gap region (tests are AR-exempt) so we
;          don't depend on gapbuf_insert's per-call mechanics.
;          Gap layout for the save:
;            - 13 bytes in before-gap [BASE, BASE+13)
;            - gap_start = BASE + 13
;            - gap_end   = BASE + GAP_BUFFER_MAX
;            - cursor    = 13
;          fileio_save reads both halves (after-gap is empty here),
;          writes one sector containing 13 + 1 (0x1A) + 114 spaces.
;
;          The roundtrip's fileio_load then reads the file back;
;          per fileio_load's contract the loaded content lands in
;          the after-gap region starting at gap_end (gapbuf_move_gap(0)
;          flips it from the linear-fill phase's before-gap region).
;
; AC reference: AC12 Sub 6.1.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xF0 — gap_start mismatch after save (gap was mutated)
;   0xF1 — status_buffer prefix mismatch (B = idx)
;   0xF2 — buffer_dirty != 0 (B = observed value)
;   0xF3 — after-gap content mismatch post-load (B = idx)
;   0xF5 — bdos_error_pre_msg != 0 post-save (hygiene)
;   0xF6 — funnel was entered (should NOT be on green path)
;   B    — diagnostic context
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----

    XOR     A
    LD      (funnel_entered), A
    LD      (init_teardown_called), A
    LD      (mode_byte), A                  ; MODE_NORMAL = 0
    LD      (status_dirty), A
    LD      (buffer_dirty), A

    ;; Reset gap to SR2-empty, then directly stage the payload in
    ;; before-gap (tests are AR-exempt — we write gap memory).
    CALL    gapbuf_init                     ; gap_start = BASE; gap_end = BASE+MAX

    ;; Copy 13 bytes "hello world\r\n" into [BASE, BASE+13).
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 13
    LDIR

    ;; Advance gap_start by 13, set cursor = 13.
    LD      HL, GAP_BUFFER_BASE + 13
    LD      (gap_start), HL
    LD      HL, 13
    LD      (cursor_offset), HL

    ;; Pre-populate filename_buffer and fcb_scratch for "B:OUT.TXT".
    ;; filename_buffer = "B:OUT.TXT\0" (9 chars + NUL).
    LD      HL, .filename_buf_init
    LD      DE, filename_buffer
    LD      BC, 10
    LDIR

    ;; fcb_scratch: drive=2, basename "OUT     ", ext "TXT", zero else.
    LD      HL, fcb_scratch
    LD      DE, fcb_scratch + 1
    LD      (HL), 0
    LD      BC, 35
    LDIR
    LD      A, 2
    LD      (fcb_scratch + 0), A
    LD      A, 'O'
    LD      (fcb_scratch + 1), A
    LD      A, 'U'
    LD      (fcb_scratch + 2), A
    LD      A, 'T'
    LD      (fcb_scratch + 3), A
    LD      A, ' '
    LD      (fcb_scratch + 4), A
    LD      (fcb_scratch + 5), A
    LD      (fcb_scratch + 6), A
    LD      (fcb_scratch + 7), A
    LD      (fcb_scratch + 8), A
    LD      A, 'T'
    LD      (fcb_scratch + 9), A
    LD      A, 'X'
    LD      (fcb_scratch + 10), A
    LD      A, 'T'
    LD      (fcb_scratch + 11), A

    ;; Drive the save.
    CALL    fileio_save

    ;; --- Subtest 1: gap_start unchanged (still BASE + 13) ---
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE + 13
    OR      A
    SBC     HL, DE
    JR      Z, .ok_gap_start
    LD      B, L
    LD      A, 0xF0
    JP      test_fail
.ok_gap_start:

    ;; --- Subtest 2: status_buffer[0..25] = "B:OUT.TXT 13 bytes written" ---
    LD      HL, .expected_status
    LD      DE, status_buffer
    LD      B, 26
    LD      C, 0
.cmp_status:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_status
    INC     HL
    INC     DE
    INC     C
    DJNZ    .cmp_status
    JR      .ok_status
.fail_status:
    LD      B, C
    LD      A, 0xF1
    JP      test_fail
.ok_status:

    ;; --- Subtest 3: buffer_dirty = 0 ---
    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xF2
    JP      test_fail
.ok_dirty:

    ;; --- Subtest 4: bdos_error_pre_msg cleared ---
    LD      HL, (bdos_error_pre_msg)
    LD      A, H
    OR      L
    JR      Z, .ok_premsg
    LD      B, L
    LD      A, 0xF5
    JP      test_fail
.ok_premsg:

    ;; --- Subtest 5: funnel_entered = 0 (clean save path) ---
    LD      A, (funnel_entered)
    OR      A
    JR      Z, .ok_funnel
    LD      B, A
    LD      A, 0xF6
    JP      test_fail
.ok_funnel:

    ;; --- Subtest 6: roundtrip — fileio_load and verify content ---
    CALL    gapbuf_init                     ; reset gap
    LD      HL, .filename_text
    LD      A, 9                            ; "B:OUT.TXT"
    CALL    fileio_load

    ;; Verify [gap_end, gap_end+13) = "hello world\r\n".
    LD      HL, .payload
    LD      DE, (gap_end)
    LD      B, 13
    LD      C, 0
.cmp_content:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_content
    INC     HL
    INC     DE
    INC     C
    DJNZ    .cmp_content
    JR      .ok_content
.fail_content:
    LD      B, C
    LD      A, 0xF3
    JP      test_fail
.ok_content:

    JP      test_pass

.payload:
    DEFB    "hello world", 0x0D, 0x0A
.filename_buf_init:
    DEFB    "B:OUT.TXT", 0
.filename_text:
    DEFB    "B:OUT.TXT"
.expected_status:
    DEFB    "B:OUT.TXT 13 bytes written"

;; ----- LOCAL init_teardown stub (Story 2.4 — shared via INCLUDE) -----
    INCLUDE "../inc/test_teardown_stub.inc"

;; ----- LOCAL input_loop stub: set sentinel on funnel entry -----
; The save path under green test should never reach the funnel; if
; it does, .after_funnel surfaces a sentinel-flipped fail (0xF6).
input_loop:
    LD      A, 1
    LD      (funnel_entered), A
    LD      C, BDOS_EXIT
    CALL    BDOS_ENTRY
    RET
funnel_entered:    DEFB 0

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
