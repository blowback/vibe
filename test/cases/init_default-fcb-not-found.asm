; ============================================================
; Module: test/cases/init_default-fcb-not-found.asm
; Purpose: Story 2.3 AC4 + AC16 — verify the NEW-FILE branch of
;          fileio_load_initial. Pre-populates DEFAULT_FCB with
;          a filename absent from the fixture B: drive
;          ("NOSUCH.FS"); fileio_load_initial's BDOS_OPEN returns
;          0xFF, the inline AR15 launch carve-out catches the
;          JP M and routes to .new_file (NOT through the funnel).
;
;          Pre-state:
;            - DEFAULT_FCB[0]      = 0 (default drive → B:)
;            - DEFAULT_FCB[1..8]   = "NOSUCH  "
;            - DEFAULT_FCB[9..11]  = "FS "
;            - input_loop stub primed with a "funnel was entered"
;              sentinel so we can detect a regression that
;              accidentally routes the open-fail through the
;              BDOS error funnel.
;
;          Post-state (after fileio_load_initial):
;            - filename_buffer    = "B:NOSUCH.FS\0" (PRESERVED —
;                                   key divergence from :e missing.fs)
;            - gap_start          = GAP_BUFFER_BASE
;            - gap_end            = GAP_BUFFER_BASE + GAP_BUFFER_MAX
;            - buffer_dirty       = 0
;            - status_buffer prefix = "B:NOSUCH.FS [new file]"
;            - funnel_entered     = 0 (carve-out worked; funnel bypassed)
;
; AC reference: AC4 (new-file path), AC7 (AR15 launch carve-out),
;               AC16 (headless coverage).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — filename_buffer mismatch (B = index)
;   0xE2 — gap_start != GAP_BUFFER_BASE
;   0xE3 — gap_end != GAP_BUFFER_BASE + GAP_BUFFER_MAX
;   0xE4 — buffer_dirty != 0
;   0xE5 — status_buffer prefix mismatch (B = index)
;   0xE7 — funnel was entered (regression: open-fail leaked
;          through bdos_error_funnel; the launch path's AR15
;          carve-out must keep us out of the funnel)
;   B    — diagnostic byte where applicable
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
    LD      (init_teardown_called), A
    LD      (funnel_entered), A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (buffer_dirty), A
    LD      (filename_buffer), A
    CALL    gapbuf_init

    ;; Pre-populate DEFAULT_FCB: drive=0 (B: default), NOSUCH.FS.
    LD      A, 0
    LD      (DEFAULT_FCB + 0), A
    LD      HL, .fcb_basename
    LD      DE, DEFAULT_FCB + 1
    LD      BC, 11
    LDIR
    XOR     A
    LD      HL, DEFAULT_FCB + 12
    LD      (HL), A
    LD      DE, DEFAULT_FCB + 13
    LD      BC, 23
    LDIR

    CALL    fileio_load_initial

    ;; --- Subtest 1: funnel was NOT entered (carve-out worked) ---
    LD      A, (funnel_entered)
    OR      A
    JR      Z, .ok_no_funnel
    LD      B, A
    LD      A, 0xE7
    JP      test_fail
.ok_no_funnel:

    ;; --- Subtest 2: filename_buffer = "B:NOSUCH.FS\0" (PRESERVED) ---
    LD      HL, .expected_filename
    LD      DE, filename_buffer
    LD      B, 12
    LD      C, 0
.cmp_filename:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_filename
    INC     HL
    INC     DE
    INC     C
    DJNZ    .cmp_filename
    JR      .ok_filename
.fail_filename:
    LD      B, C
    LD      A, 0xE1
    JP      test_fail
.ok_filename:

    ;; --- Subtest 3: gap_start = GAP_BUFFER_BASE (buffer empty) ---
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_gap_start
    LD      B, L
    LD      A, 0xE2
    JP      test_fail
.ok_gap_start:

    ;; --- Subtest 4: gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX ---
    LD      HL, (gap_end)
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_gap_end
    LD      B, L
    LD      A, 0xE3
    JP      test_fail
.ok_gap_end:

    ;; --- Subtest 5: buffer_dirty = 0 ---
    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok_dirty:

    ;; --- Subtest 6: status_buffer prefix = "B:NOSUCH.FS [new file]" ---
    LD      HL, .expected_status_prefix
    LD      DE, status_buffer
    LD      B, 22                           ; "B:NOSUCH.FS [new file]" = 22 chars
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
    LD      A, 0xE5
    JP      test_fail
.ok_status:

    JP      test_pass

.fcb_basename:
    DEFB    "NOSUCH  "
    DEFB    "FS "
.expected_filename:
    DEFB    "B:NOSUCH.FS", 0                ; 11 + NUL
.expected_status_prefix:
    DEFB    "B:NOSUCH.FS [new file]"        ; 22 chars

;; ----- Funnel-entered sentinel + override -----
; If the launch path's AR15 carve-out fails and open-fail goes
; through bdos_error_funnel, the funnel's JP input_loop lands on
; the input_loop label below. The override records the entry in
; funnel_entered (1) and gives a deterministic post-funnel exit
; (warm-boot via BDOS function 0) so the test surfaces as a fail
; rather than a timeout.
;
; On a green run this stub is NOT reached — fileio_load_initial's
; .new_file branch is the correct landing.
input_loop:
    LD      A, 1
    LD      (funnel_entered), A
    LD      C, BDOS_EXIT
    CALL    BDOS_ENTRY
    RET
funnel_entered:    DEFB 0

;; ----- LOCAL init_teardown stub -----
    INCLUDE "../inc/test_teardown_stub.inc"
;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"     ; Story 2.5: dispatch_normal forward-references motion_h/j/k/l
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
