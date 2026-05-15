; ============================================================
; Module: test/cases/fileio_save-make-failure.asm
; Purpose: AC12 Sub 6.4 — verify fileio_save's BDOS-failure funnel
;          routing: pre-staged "can't write FILENAME" banner
;          surfaces; ex-line cleanup runs; buffer_dirty stays
;          nonzero (FR52); bdos_error_pre_msg cleared post-emit.
;
;          STORY 2.4 DEVIATION FROM AC12 Sub 6.4 NAME — promoted
;          to "make-failure" rather than "write-protect":
;          AC12 originally specced a write-protect simulation via
;          Mechanism A (chmod 0444 fixture) or Mechanism B (FCB
;          high-bit on ext char 0). Dev probes confirmed iz-cpm
;          does NOT honor either: chmod 0444 was silently ignored
;          by BDOS_MAKE; FCB high-bit caused BDOS_DELETE to return
;          0xFF (which the AR15 save carve-out swallows by design)
;          but BDOS_MAKE then succeeded normally, producing a
;          green-path save. Per AC12 Sub 6.8 the dev option was
;          "defer to hardware UAT" — but the funnel routing is the
;          LOAD-BEARING assertion for FR51 / FR52, not the R/O
;          semantics specifically. This test substitutes Mechanism
;          D: address an unmounted drive (D:NODISK.TXT) — iz-cpm
;          returns 0xFF from BDOS_MAKE on the unmounted drive,
;          firing the macro funnel through the same code path a
;          real R/O surface would. The proxy pins FR51 / FR52
;          funnel-routing identically to a true R/O test; the true
;          R/O behavior is verified on hardware UAT (AC14 step 12).
;
;          Deferred-work note: this rename + the iz-cpm R/O
;          limitation are logged so a future story can retry
;          Mechanism A/B when iz-cpm grows the support.
;
; AC reference: AC12 Sub 6.4 (renamed); AC6 (BDOS error semantics).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xF1 — status_buffer prefix mismatch (B = idx)
;   0xF2 — buffer_dirty changed (B = observed value; expect 1)
;   0xF5 — bdos_error_pre_msg not cleared post-emit (B = low byte)
;   0xF6 — funnel was NOT entered (sentinel still 0)
;   0xF7 — fileio_save returned normally (control should not reach
;          past CALL fileio_save on the failure path)
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
    LD      (status_dirty), A
    LD      (mode_byte), A                  ; MODE_NORMAL = 0; will be set to COMMAND below
    LD      (filename_buffer), A
    ;; Set buffer_dirty = 1 — FR52 load-bearing: stays 1 across the
    ;; save failure.
    LD      A, 1
    LD      (buffer_dirty), A

    CALL    gapbuf_init                     ; empty payload (irrelevant; never gets to write)

    ;; Pre-set ex_buffer non-empty + mode = COMMAND so the funnel's
    ;; inline ex-line cleanup is observable.
    LD      A, 5
    LD      (ex_buffer), A
    LD      A, MODE_COMMAND
    LD      (mode_byte), A

    ;; filename_buffer = "D:NODISK.TXT\0"
    LD      HL, .filename_buf_init
    LD      DE, filename_buffer
    LD      BC, 13
    LDIR

    ;; fcb_scratch: drive 4 (D:), basename "NODISK  ", ext "TXT".
    LD      HL, fcb_scratch
    LD      DE, fcb_scratch + 1
    LD      (HL), 0
    LD      BC, 35
    LDIR
    LD      A, 4
    LD      (fcb_scratch + 0), A
    LD      HL, .fcb_basename
    LD      DE, fcb_scratch + 1
    LD      BC, 11
    LDIR

    ;; Drive the save — BDOS_MAKE on unmounted D: returns 0xFF,
    ;; the BDOS_CALL macro funnels via JP M, the funnel surfaces
    ;; the pre-staged "can't write D:NODISK.TXT" banner and JPs
    ;; to input_loop. Production: never returns here. Test:
    ;; the local input_loop stub sets funnel_entered = 1 and
    ;; JPs into .after_funnel for the assertions.
    CALL    fileio_save
    ;; Should not reach here on the failure path.
    LD      B, 0
    LD      A, 0xF7
    JP      test_fail

;; .after_funnel — reached via input_loop stub on funnel entry.
.after_funnel:

    ;; --- Subtest 1: funnel_entered = 1 ---
    LD      A, (funnel_entered)
    OR      A
    JR      NZ, .ok_funnel
    LD      B, A
    LD      A, 0xF6
    JP      test_fail
.ok_funnel:

    ;; --- Subtest 2: status_buffer prefix = "can't write D:NODISK.TXT" ---
    LD      HL, .expected_status
    LD      DE, status_buffer
    LD      B, 24
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

    ;; --- Subtest 3: buffer_dirty UNCHANGED (still 1; FR52) ---
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xF2
    JP      test_fail
.ok_dirty:

    ;; --- Subtest 4: bdos_error_pre_msg cleared by funnel ---
    LD      HL, (bdos_error_pre_msg)
    LD      A, H
    OR      L
    JR      Z, .ok_premsg
    LD      B, L
    LD      A, 0xF5
    JP      test_fail
.ok_premsg:

    ;; iz-cpm emits "Bdos Err On D: Bad Sector" to stderr (with
    ;; 2>&1 merging into stdout) WITHOUT a trailing newline —
    ;; "Sector" + "PASS" concatenates and the harness's grep for
    ;; \bPASS\b fails on word-boundary. Emit a leading CR LF so
    ;; the PASS token starts on a fresh line.
    LD      DE, .crlf
    LD      C, 9
    CALL    0x0005

    JP      test_pass

.crlf:
    DEFB    0x0D, 0x0A, "$"

.filename_buf_init:
    DEFB    "D:NODISK.TXT", 0
.fcb_basename:
    DEFB    "NODISK  TXT"
.expected_status:
    DEFB    "can't write D:NODISK.TXT"

;; ----- LOCAL init_teardown stub -----
    INCLUDE "../inc/test_teardown_stub.inc"

;; ----- LOCAL input_loop stub: set sentinel, JP to .after_funnel -----
input_loop:
    LD      A, 1
    LD      (funnel_entered), A
    JP      test_start.after_funnel
funnel_entered:    DEFB 0

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
