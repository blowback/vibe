; ============================================================
; Module: test/cases/exline_q-bang-force.asm
; Purpose: AC8, AC12 — verify that `:q!` unconditionally warm-
;          boots regardless of buffer_dirty state. The test
;          intentionally sets buffer_dirty = 1 so a defective
;          cmd_quit_force that re-checked buffer_dirty (vs.
;          cmd_quit's careful split into the unconditional
;          warm-boot path) would surface as a sentinel miss.
;
;          As with the clean-buffer test, post-stub state
;          (mode_byte / ex_buffer) is intentionally NOT asserted
;          — production warm-boots before any further state
;          inspection would matter.
;
; AC reference: AC8 (:q! force-quit), AC12 (headless coverage).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE0 — init_teardown stub was NOT called (sentinel still 0)
;   B   — diagnostic context (observed sentinel value)
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

    ;; buffer_dirty = 1 — intentionally dirty so a regression
    ;; that added a dirty check to cmd_quit_force would surface.
    LD      A, 1
    LD      (buffer_dirty), A

    ;; Pre-load ex_buffer = length 2, bytes 'q' '!'.
    LD      A, 2
    LD      (ex_buffer), A
    LD      A, 'q'
    LD      (ex_buffer_text), A
    LD      A, '!'
    LD      (ex_buffer_text + 1), A

    ;; Drive the dispatch.
    LD      A, 0x0D
    CALL    exline_dispatch

    ;; --- Subtest 1: init_teardown_called == 1 ---
    LD      A, (init_teardown_called)
    OR      A
    JR      NZ, .ok_called
    LD      B, A
    LD      A, 0xE0
    JP      test_fail
.ok_called:

    JP      test_pass

;; ----- LOCAL init_teardown stub -----
    INCLUDE "../inc/test_teardown_stub.inc"
;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"     ; Story 2.5: dispatch_normal forward-references motion_h/j/k/l
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/exline.asm"
    ;; Story 2.2 / 2.3 pull-forward: exline.asm now references
    ;; fileio_load + fileio_strip_leading_spaces (cmd_edit / cmd_edit_force);
    ;; INCLUDE fileio.asm to resolve those forward references at build time.
    INCLUDE "../../src/fileio.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
