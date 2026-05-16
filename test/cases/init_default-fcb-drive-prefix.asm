; ============================================================
; Module: test/cases/init_default-fcb-drive-prefix.asm
; Purpose: Story 2.3 AC3 + AC16 — verify FR10 explicit drive
;          prefix pass-through in fileio_setup_from_default_fcb.
;          Pre-populates DEFAULT_FCB with drive=1 (A:) and
;          basename/ext for hello.txt; the fixture is mounted as
;          BOTH A: and B: in test/Makefile, so the load succeeds.
;
;          Pre-state:
;            - DEFAULT_FCB[0]      = 1   (A: — explicit prefix, FR10)
;            - DEFAULT_FCB[1..8]   = "HELLO   "
;            - DEFAULT_FCB[9..11]  = "TXT"
;            - gapbuf_init applied
;
;          Post-state (after fileio_load_initial):
;            - filename_buffer    = "A:HELLO.TXT\0" (NOT translated to B:)
;            - status_buffer prefix = "A:HELLO.TXT "
;
;          This pins the FR9 / FR10 boundary: drive byte 0 (no
;          prefix) gets the B: override; drive byte 1+ (explicit
;          prefix) passes through unchanged.
;
; AC reference: AC3 (load-success), AC11 (FR10 pass-through),
;               AC16 (headless coverage).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — filename_buffer mismatch (B = index)
;   0xE5 — status_buffer prefix mismatch (B = index)
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
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (buffer_dirty), A
    LD      (filename_buffer), A
    CALL    gapbuf_init

    ;; Pre-populate DEFAULT_FCB: drive=1 (A:), basename HELLO + TXT.
    LD      A, 1
    LD      (DEFAULT_FCB + 0), A            ; drive = 1 (A: — FR10 explicit)
    LD      HL, .fcb_basename
    LD      DE, DEFAULT_FCB + 1
    LD      BC, 11                          ; 8 basename + 3 ext
    LDIR
    XOR     A
    LD      HL, DEFAULT_FCB + 12
    LD      (HL), A
    LD      DE, DEFAULT_FCB + 13
    LD      BC, 23
    LDIR

    CALL    fileio_load_initial

    ;; --- Subtest 1: filename_buffer = "A:HELLO.TXT\0" (NOT B:) ---
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

    ;; --- Subtest 2: status_buffer[0..11] = "A:HELLO.TXT " ---
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
    LD      B, C
    LD      A, 0xE5
    JP      test_fail
.ok_status:

    JP      test_pass

.fcb_basename:
    DEFB    "HELLO   "
    DEFB    "TXT"
.expected_filename:
    DEFB    "A:HELLO.TXT", 0
.expected_status_prefix:
    DEFB    "A:HELLO.TXT "

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
    INCLUDE "../../src/edits.asm"     ; Story 2.8: dispatch_normal forward-references edits_*, dispatch_insert table grows, unbound_insert tail-JPs edits_insert_literal
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
