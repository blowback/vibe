; ============================================================
; Module: test/cases/init_welcome-hidden-load-success.asm
; Purpose: Story 4.3 AC2 — load-success sibling of
;          init_welcome-hidden-with-arg.asm. Drives the
;          fileio_load_initial parse → BDOS_OPEN-success →
;          fileio_load_after_open → status_set_message branch
;          (the load-success path) and asserts the 0xAA poison on
;          welcome_active survives the entire path.
;
;          Story 4.2 AC2 names four non-no-arg branches of
;          fileio_load_initial: .new_file, load-success,
;          file-too-large, can't-read-file. The original test
;          covered only .new_file via NOSUCH.FS. This file pins
;          the load-success branch via B:HELLO.TXT (13-byte
;          fixture present in test/fixtures/).
;
;          Pre-state:
;            - Static block zeroed (gapbuf_init runs).
;            - DEFAULT_FCB[0]      = 0    (FR9 default -> B:)
;            - DEFAULT_FCB[1..8]   = "HELLO   "
;            - DEFAULT_FCB[9..11]  = "TXT"
;            - welcome_active      = 0xAA (POISON — any writer
;                                          touching the flag during
;                                          the load-success path
;                                          breaks the test)
;
;          Post-state (after fileio_load_initial):
;            - welcome_active      == 0xAA (load-success path does
;                                           NOT touch welcome_active —
;                                           poison survives)
;            - filename_buffer[0]  != 0   (load-success populates
;                                          filename_buffer with
;                                          "B:HELLO.TXT\0" so a
;                                          subsequent :w writes back
;                                          to the same file —
;                                          Story 2.3 AC4 regression-pin)
;
; AC reference: Story 4.3 AC2 (load-success sibling test).
;
; Sentinel code at 0xCFFE on failure: 0x9C (reused from Story 4.2
;   T2 per the Story 4.3 sentinel-reuse rule — assertion shape is
;   identical to init_welcome-hidden-with-arg.asm, distinguished
;   only by filename + which fileio branch fires).
;   Context byte (B) on failure encodes the subtest:
;     0x01 — welcome_active != 0xAA (load-success path TOUCHED the
;            flag — a writer wrote 0 OR a different value; the
;            structural invariant 'only .no_arg writes welcome_active'
;            is broken)
;     0x02 — filename_buffer[0] == 0 (load-success failed to populate
;            filename_buffer — Story 2.3 AC4 regression)
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
;; BIOS_CONOUT override: the load-success branch does not emit to
;; BIOS today, but bdos_error_funnel emits via render_emit_byte →
;; BIOS_CONOUT on any sign-bit BDOS error. Defensively override so
;; a future BDOS regression cannot corrupt the harness PASS/FAIL
;; grep with terminal escapes. The DEFINE BIOS_CONOUT_OVERRIDE
;; MUST come BEFORE INCLUDE "../../inc/bios.inc".
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
    LD      (test_capture_len), A         ; clear BIOS capture buffer
    LD      A, 0xAA                       ; poison welcome_active so any
    LD      (welcome_active), A           ; writer (0 OR 1) is detected
    CALL    gapbuf_init

    ;; Pre-populate DEFAULT_FCB with the load-success filename
    ;; HELLO.TXT (CCP-format: 8-byte basename space-padded, 3-byte
    ;; ext space-padded). Drive byte 0 -> FR9 default -> B:.
    XOR     A
    LD      (DEFAULT_FCB + 0), A          ; drive byte 0
    LD      A, 'H'
    LD      (DEFAULT_FCB + 1), A
    LD      A, 'E'
    LD      (DEFAULT_FCB + 2), A
    LD      A, 'L'
    LD      (DEFAULT_FCB + 3), A
    LD      A, 'L'
    LD      (DEFAULT_FCB + 4), A
    LD      A, 'O'
    LD      (DEFAULT_FCB + 5), A
    LD      A, ' '
    LD      (DEFAULT_FCB + 6), A
    LD      (DEFAULT_FCB + 7), A
    LD      (DEFAULT_FCB + 8), A
    LD      A, 'T'
    LD      (DEFAULT_FCB + 9), A
    LD      A, 'X'
    LD      (DEFAULT_FCB + 10), A
    LD      A, 'T'
    LD      (DEFAULT_FCB + 11), A

    ;; Call fileio_load_initial. Takes parse → BDOS_OPEN-success
    ;; → fileio_load_after_open → status_set_message (load-success
    ;; branch on the 13-byte hello.txt fixture).
    CALL    fileio_load_initial

    ;; --- Subtest 1: welcome_active == 0xAA (poison survived — no writer
    ;;     touched the flag on the load-success path) ---
    LD      A, (welcome_active)
    CP      0xAA
    JR      Z, .ok_active_poison_survived
    LD      B, 0x01
    LD      A, 0x9C
    JP      test_fail
.ok_active_poison_survived:

    ;; --- Subtest 2: filename_buffer[0..11] == "B:HELLO.TXT\0" (12 bytes
    ;;     — tightened from filename_buffer[0]!=0 to catch partial
    ;;     corruption: an off-by-one writer that puts 'X' at byte 0 but
    ;;     leaves the rest empty would have passed the old assertion) ---
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
    JR      .ok_filename_preserved
.fail_filename:
    LD      B, C                          ; B = byte index of first mismatch
    LD      A, 0x9C
    JP      test_fail
.ok_filename_preserved:

    JP      test_pass

.expected_filename:
    DEFB    "B:HELLO.TXT", 0              ; 12 bytes

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
