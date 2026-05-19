; ============================================================
; Module: test/cases/init_default-fcb-no-arg.asm
; Purpose: Story 2.3 AC2 + AC16 — verify the no-arg short-circuit
;          in fileio_load_initial. CCP space-pads the basename
;          when no filename argument is on the command tail;
;          DEFAULT_FCB + 1 == 0x20 is the canonical "no arg"
;          sentinel. Pre-poisons DEFAULT_FCB[0..11] with 0xAA so
;          a regression where the short-circuit accidentally
;          copies the FCB into fcb_scratch before the check
;          surfaces as a non-zero filename_buffer.
;
;          Pre-state:
;            - DEFAULT_FCB[0..11] = 0xAA (poison)
;            - DEFAULT_FCB + 1    = 0x20 (no-arg sentinel)
;            - gapbuf_init        (gap_start = GAP_BUFFER_BASE,
;                                  gap_end   = GAP_BUFFER_BASE + GAP_BUFFER_MAX)
;            - status_dirty       = 0
;            - filename_buffer[0] = 0
;
;          Post-state (after fileio_load_initial):
;            - filename_buffer[0] = 0    (untouched — short-circuit
;                                         returns before any FCB copy)
;            - gap_start          = GAP_BUFFER_BASE
;            - gap_end            = GAP_BUFFER_BASE + GAP_BUFFER_MAX
;            - status_dirty       = 1    (status_set_message fired)
;            - status_buffer[0]   = ' '  (msg_mode_normal is empty;
;                                         status_set_message pads
;                                         STATUS_LINE_WIDTH spaces)
;
; AC reference: AC2 (no-arg short-circuit), AC16 (headless coverage).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE0 — filename_buffer[0] != 0 (short-circuit didn't fire,
;                                   or FCB leaked into the parse)
;   0xE2 — gap_start != GAP_BUFFER_BASE
;   0xE3 — gap_end != GAP_BUFFER_BASE + GAP_BUFFER_MAX
;   0xE5 — status_buffer[0] != ' ' (msg_mode_normal didn't fire,
;                                   or status_set_message broken)
;   0xE6 — status_dirty != 1
;   0x9B — welcome_active != 1 (Story 4.2 AC1 — the no-arg path
;                               must arm the FR53 welcome flag;
;                               reuses T1's sentinel since the
;                               assertion semantic is identical)
;   B    — diagnostic byte (value where applicable)
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
    ;; Initialise gap state via gapbuf_init so the post-call
    ;; assertions have a known baseline (the short-circuit must
    ;; leave this state untouched).
    CALL    gapbuf_init

    ;; Pre-poison DEFAULT_FCB[0..11] with 0xAA. If the short-circuit
    ;; accidentally calls fileio_setup_from_default_fcb, the 0xAA
    ;; bytes would be copied into fcb_scratch and surface as
    ;; gibberish in filename_buffer (high-bit characters that don't
    ;; match the expected NUL terminator at [0]).
    LD      HL, DEFAULT_FCB
    LD      (HL), 0xAA
    LD      DE, DEFAULT_FCB + 1
    LD      BC, 11
    LDIR

    ;; Now write the canonical no-arg sentinel: DEFAULT_FCB + 1 = ' '.
    LD      A, ' '
    LD      (DEFAULT_FCB + 1), A

    ;; Call fileio_load_initial.
    CALL    fileio_load_initial

    ;; --- Subtest 1: filename_buffer[0] == 0 (short-circuit fired) ---
    LD      A, (filename_buffer)
    OR      A
    JR      Z, .ok_filename
    LD      B, A
    LD      A, 0xE0
    JP      test_fail
.ok_filename:

    ;; --- Subtest 2: gap_start == GAP_BUFFER_BASE ---
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

    ;; --- Subtest 3: gap_end == GAP_BUFFER_BASE + GAP_BUFFER_MAX ---
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

    ;; --- Subtest 4: status_buffer[0] == ' ' (msg_mode_normal pad) ---
    LD      A, (status_buffer)
    CP      ' '
    JR      Z, .ok_status
    LD      B, A
    LD      A, 0xE5
    JP      test_fail
.ok_status:

    ;; --- Subtest 5: status_dirty == 1 ---
    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok_dirty
    LD      B, A
    LD      A, 0xE6
    JP      test_fail
.ok_dirty:

    ;; --- Subtest 6: welcome_active == 1 (Story 4.2 AC1) ---
    ;; The no-arg short-circuit now arms the FR53 welcome flag
    ;; alongside the msg_mode_normal status seed. Verify the
    ;; flag survived fileio_load_initial's RET.
    LD      A, (welcome_active)
    CP      1
    JR      Z, .ok_welcome
    LD      B, A
    LD      A, 0x9B
    JP      test_fail
.ok_welcome:

    JP      test_pass

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
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"     ; Story 2.8: dispatch_normal forward-references edits_*, dispatch_insert table grows, unbound_insert tail-JPs edits_insert_literal
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
