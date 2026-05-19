; ============================================================
; Module: test/cases/welcome_active-survives-e-empty-txt.asm
; Purpose: Story 4.3 AC3 — pin the `:e empty.txt` round-trip
;          end-to-end at the headless layer. Story 4.2 AC4 names
;          three production paths that return file_length to 0:
;          `dd` on a 1-line buffer (FR29), `:e empty.txt` (FR6),
;          `:e!`. The existing welcome_does-not-redraw-after-
;          dismiss.asm exercises only the `dd` path (Op 5). This
;          file pins the `:e empty.txt` BDOS round-trip end-to-end:
;          fileio_load parses "empty.txt", BDOS_OPEN succeeds
;          against B:EMPTY.TXT (the 128-byte fixture: byte 0 =
;          0x1A, bytes 1..127 = 0x20), BDOS_READ_SEQ returns the
;          sector, fileio_ingest_sector terminates at the leading
;          0x1A so 0 real bytes are loaded, and the post-load
;          state matches gapbuf_init's full-empty shape.
;
;          The point of the test is the welcome_active poison:
;          per the AC4 structural invariant 'only fileio_load_
;          initial.no_arg writes welcome_active', no production
;          code in fileio_load OR fileio_load_after_open OR the
;          status-emit path may touch the flag. The 0xAA poison
;          disambiguates 'no writer touched the flag' from
;          'a writer wrote 0' (the latter would be a structural-
;          invariant violation hidden by a == 0 assertion).
;
;          Pre-state:
;            - welcome_active      = 0xAA (POISON)
;            - mode_byte           = 0
;            - init_teardown_called = 0
;            - status_dirty        = 0
;            - buffer_dirty        = 0
;            - filename_buffer     = 0 (cleared; fileio_load
;                                       parses HL/A into it)
;            - gapbuf_init applied
;
;          Body: CALL fileio_load with HL = "empty.txt", A = 9.
;          Drive defaults to B: (FR9 — bare filename, no drive
;          prefix). The fixture is mounted as iz-cpm's B: drive
;          (test/Makefile:33).
;
;          Post-state (after fileio_load):
;            - welcome_active      == 0xAA (poison survived — no
;                                           writer in fileio_load
;                                           OR fileio_load_after_open
;                                           OR status_set_message
;                                           touched the flag)
;            - gap_start           == GAP_BUFFER_BASE (file_length=0)
;            - gap_end             == GAP_BUFFER_BASE + GAP_BUFFER_MAX
;                                       (gap is full-empty — identical
;                                       to gapbuf_init post-state and
;                                       to the existing AC4 dd-on-
;                                       1-line test's Op 5 post-state)
;            - status_buffer[0..11] == "B:EMPTY.TXT " (the 12-char
;                                       load-success banner prefix;
;                                       the byte-count portion is
;                                       "0 bytes" per Story 2.2 banner
;                                       format — we check just the
;                                       prefix to keep the assertion
;                                       robust against banner-format
;                                       detail changes)
;
; AC reference: Story 4.3 AC3 (`:e empty.txt` FR6 round-trip).
;
; Sentinel code at 0xCFFE on failure: 0x9E (reused from Story 4.2
;   T4 per the Story 4.3 sentinel-reuse rule — semantic match:
;   "welcome_active survives a buffer-empty operation").
;   Context byte (B) on failure encodes the subtest, picked above
;   the existing T4 subtests (0x01-0x07) to avoid collision when
;   both files report failures in the same test run:
;     0x10 — welcome_active != 0xAA (`:e empty.txt` path TOUCHED
;            the flag; structural-invariant violation)
;     0x11 — gap shape != full-empty (gap_start != GAP_BUFFER_BASE
;            OR gap_end != GAP_BUFFER_BASE + GAP_BUFFER_MAX —
;            the load did not return file_length to 0; B = low
;            byte of the offending value)
;     0x12 — status_buffer[0..11] != "B:EMPTY.TXT " (B = index of
;            first mismatch — load-success banner format drifted
;            OR a path that takes .abort_too_large /
;            .abort_read_error fired despite the well-formed
;            fixture). The buffer is pre-poisoned with 0xAB so this
;            subtest catches a path that never wrote the banner at
;            all (TPA residue would otherwise match spuriously).
;     0x13 — test_capture_len != 0 (a BIOS_CONOUT emit fired during
;            the :e empty.txt path; today the load-success path is
;            BIOS-quiet, so any emit means either a future writer
;            was added OR the bdos_error_funnel fired on a sign-bit
;            error — both should fail the test loud rather than
;            silently corrupt the harness PASS/FAIL grep)
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
;; BIOS_CONOUT override: fileio_load doesn't emit to BIOS on the
;; empty-file load path today, but status_set_message at success
;; may trigger a render path under future stories. Defensively
;; override (mirrors welcome_does-not-redraw-after-dismiss.asm
;; lines 95-97). The DEFINE BIOS_CONOUT_OVERRIDE MUST come BEFORE
;; INCLUDE "../../inc/bios.inc" — otherwise emits escape to
;; stdout and break the harness PASS/FAIL grep.
    DEFINE BIOS_CONOUT_OVERRIDE
BIOS_CONOUT EQU test_bios_conout
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----

    XOR     A
    LD      (init_teardown_called), A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (buffer_dirty), A
    LD      (filename_buffer), A
    LD      (test_capture_len), A
    LD      A, 0xAA                       ; poison welcome_active so any
    LD      (welcome_active), A           ; writer (0 OR 1) is detected
    CALL    gapbuf_init

    ;; Poison status_buffer with 0xAB so subtest 0x12 catches a path
    ;; that takes the load but never writes the success banner (TPA
    ;; residue could otherwise contain "B:EMPTY.TXT " and pass spuriously).
    LD      HL, status_buffer
    LD      DE, status_buffer + 1
    LD      BC, 15                        ; 16-byte fill covers the 12-char prefix + slack
    LD      (HL), 0xAB
    LDIR

    ;; Call fileio_load directly: HL = filename literal, A = 9 (length
    ;; in bytes of the literal "empty.txt"; fileio_load Step 1 invokes
    ;; fileio_parse_filename which reads HL/A as a counted string and
    ;; populates filename_buffer + fcb_scratch). The bare filename
    ;; parses to drive 2 (B: per FR9 default); BDOS_OPEN against
    ;; B:EMPTY.TXT succeeds against the 128-byte fixture (byte 0 =
    ;; 0x1A → fileio_ingest_sector terminates immediately → 0 real
    ;; bytes loaded → gap stays full-empty).
    LD      HL, .filename
    LD      A, 9                          ; length of "empty.txt"
    CALL    fileio_load

    ;; --- Subtest 0x10: welcome_active == 0xAA (poison survived
    ;;     — no writer in the :e empty.txt path touched the flag) ---
    LD      A, (welcome_active)
    CP      0xAA
    JR      Z, .ok_active_poison_survived
    LD      B, 0x10
    LD      A, 0x9E
    JP      test_fail
.ok_active_poison_survived:

    ;; --- Subtest 0x11: gap shape == full-empty
    ;;     (gap_start == GAP_BUFFER_BASE AND
    ;;      gap_end   == GAP_BUFFER_BASE + GAP_BUFFER_MAX) ---
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      NZ, .fail_gap_shape
    LD      HL, (gap_end)
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_gap_shape
.fail_gap_shape:
    LD      B, 0x11
    LD      A, 0x9E
    JP      test_fail
.ok_gap_shape:

    ;; --- Subtest 0x12: status_buffer[0..11] == "B:EMPTY.TXT " ---
    LD      HL, .expected_status_prefix
    LD      DE, status_buffer
    LD      B, 12
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
    LD      B, C                          ; B = index of first mismatch
    LD      A, 0x9E
    JP      test_fail
.ok_status:

    ;; --- Subtest 0x13: test_capture_len == 0 (no BIOS emit fired
    ;;     during the :e empty.txt path — defensive against a future
    ;;     writer OR bdos_error_funnel firing on a sign-bit BDOS error) ---
    LD      A, (test_capture_len)
    OR      A
    JR      Z, .ok_no_bios_emit
    LD      B, 0x13
    LD      A, 0x9E
    JP      test_fail
.ok_no_bios_emit:

    JP      test_pass

.filename:
    DEFB    "empty.txt"
.expected_status_prefix:
    DEFB    "B:EMPTY.TXT "

;; ----- LOCAL stubs -----

;; --- BIOS_CONOUT capture buffer ---
    INCLUDE "../inc/test_bios_conout_capture.inc"

;; --- init_teardown stub ---
    INCLUDE "../inc/test_teardown_stub.inc"

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/welcome.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
