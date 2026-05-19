; ============================================================
; Module: test/cases/init_welcome-hidden-with-arg.asm
; Purpose: Story 4.2 AC2 — verify welcome screen is NOT armed
;          when fileio_load_initial takes a non-no-arg path.
;          We use a guaranteed-not-present filename (NOSUCH.FS)
;          so the BDOS_OPEN returns 0xFF and the .new_file
;          branch fires. welcome_active must stay 0 on the
;          new-file path (and on every other non-no-arg path —
;          load-success, too-large, read-error — all of which
;          bypass the .no_arg branch where the flag is armed).
;
;          Pre-state:
;            - Static block zeroed (gapbuf_init runs).
;            - DEFAULT_FCB[0]      = 0    (default drive -> B:)
;            - DEFAULT_FCB[1..8]   = "NOSUCH  "
;            - DEFAULT_FCB[9..11]  = "FS "
;            - welcome_active      = 0    (pre-set explicitly)
;
;          Post-state (after fileio_load_initial):
;            - welcome_active      == 0   (.new_file path does
;                                          NOT touch welcome_active)
;            - filename_buffer[0]  != 0   (Story 2.3 AC4 — new-file
;                                          path PRESERVES the
;                                          parsed filename so a
;                                          subsequent :w saves
;                                          into the not-yet-on-disk
;                                          file)
;
; AC reference: AC2 (welcome hidden with arg).
;
; Sentinel code at 0xCFFE on failure: 0x9C (Story 4.2 T2).
;   Context byte (B) on failure encodes the subtest:
;     0x01 — welcome_active != 0 (filename-arg path accidentally
;            set the flag — check that LD A,1; LD (welcome_active),A
;            is ONLY in fileio.asm's .no_arg branch)
;     0x02 — filename_buffer[0] == 0 (Story 2.3 AC4 regression;
;            new-file path failed to populate filename_buffer)
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
;; No BIOS override needed — fileio_load_initial.new_file does not
;; emit to BIOS (status_set_message writes to status_buffer in
;; state.inc; render_mark_all_dirty is a pure bit-set; no
;; render_diff fires on this path).
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
    LD      (welcome_active), A           ; pre-set the flag to 0 explicitly
    CALL    gapbuf_init

    ;; Pre-populate DEFAULT_FCB with a non-existent filename
    ;; NOSUCH.FS (CCP-format: 8-byte basename space-padded, 3-byte
    ;; ext space-padded). Drive byte 0 -> FR9 default -> B:.
    XOR     A
    LD      (DEFAULT_FCB + 0), A          ; drive byte 0
    LD      A, 'N'
    LD      (DEFAULT_FCB + 1), A
    LD      A, 'O'
    LD      (DEFAULT_FCB + 2), A
    LD      A, 'S'
    LD      (DEFAULT_FCB + 3), A
    LD      A, 'U'
    LD      (DEFAULT_FCB + 4), A
    LD      A, 'C'
    LD      (DEFAULT_FCB + 5), A
    LD      A, 'H'
    LD      (DEFAULT_FCB + 6), A
    LD      A, ' '
    LD      (DEFAULT_FCB + 7), A
    LD      (DEFAULT_FCB + 8), A
    LD      A, 'F'
    LD      (DEFAULT_FCB + 9), A
    LD      A, 'S'
    LD      (DEFAULT_FCB + 10), A
    LD      A, ' '
    LD      (DEFAULT_FCB + 11), A

    ;; Call fileio_load_initial. Takes the parse-FCB path, then
    ;; .new_file branch on BDOS_OPEN failure.
    CALL    fileio_load_initial

    ;; --- Subtest 1: welcome_active == 0 (filename path did NOT arm flag) ---
    LD      A, (welcome_active)
    OR      A
    JR      Z, .ok_active_zero
    LD      B, 0x01
    LD      A, 0x9C
    JP      test_fail
.ok_active_zero:

    ;; --- Subtest 2: filename_buffer[0] != 0 (new-file preserved it) ---
    LD      A, (filename_buffer)
    OR      A
    JR      NZ, .ok_filename_preserved
    LD      B, 0x02
    LD      A, 0x9C
    JP      test_fail
.ok_filename_preserved:

    JP      test_pass

;; ----- LOCAL init_teardown stub -----
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
