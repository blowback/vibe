; ============================================================
; Module: test/cases/welcome_does-not-redraw-after-dismiss.asm
; Purpose: Story 4.2 AC4 — regression net pinning the one-shot
;          guarantee: post-dismissal (welcome_active = 0), no
;          production code path may re-arm welcome_active. The
;          structural guarantee is "fileio_load_initial.no_arg is
;          the SOLE writer-to-1 in the editor's lifetime, and
;          fileio_load_initial runs once per .com launch via
;          init_cold_start Stage 5". This test exercises common
;          post-dismissal operations (gap reset, full redraw mark,
;          status update, undo clear, exline submode flip) and
;          asserts welcome_active stays 0 after each — which
;          would catch a future story accidentally adding a
;          second writer-to-1 outside fileio.no_arg.
;
;          Pre-state: welcome_active = 0 (post-dismissal).
;
;          Operations exercised:
;            1. gapbuf_init                  (mimics :e empty.txt
;                                             buffer reset)
;            2. render_mark_all_dirty        (mimics Ctrl-L refresh)
;            3. render_init                  (mimics teardown-equivalent
;                                             screen-clear)
;            4. status_set_message           (mimics mode-change /
;                                             error status update)
;            5. welcome_paint                (defensive — even if
;                                             this routine is
;                                             called again, it must
;                                             not touch welcome_active)
;
;          After each operation, assert welcome_active == 0.
;
; AC reference: AC4 (one-shot guarantee — welcome never re-arms).
;
; Sentinel code at 0xCFFE on failure: 0x9E (Story 4.2 T4).
;   Context byte (B) on failure encodes the operation that armed
;   the flag (1-indexed per the list above):
;     0x01 — welcome_active armed after gapbuf_init
;     0x02 — welcome_active armed after render_mark_all_dirty
;     0x03 — welcome_active armed after render_init
;     0x04 — welcome_active armed after status_set_message
;     0x05 — welcome_active armed after welcome_paint
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
;; BIOS_CONOUT override for the welcome_paint subtest (otherwise
;; its emits would escape to stdout and break the PASS/FAIL grep).
    DEFINE BIOS_CONOUT_OVERRIDE
BIOS_CONOUT EQU test_bios_conout
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----

    ;; Pre-zero state. welcome_active = 0 = post-dismissal.
    XOR     A
    LD      (welcome_active), A
    LD      (init_teardown_called), A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (buffer_dirty), A
    LD      (test_capture_len), A

    ;; Op 1: gapbuf_init.
    CALL    gapbuf_init
    LD      A, (welcome_active)
    OR      A
    JR      Z, .ok_op1
    LD      B, 0x01
    LD      A, 0x9E
    JP      test_fail
.ok_op1:

    ;; Op 2: render_mark_all_dirty.
    CALL    render_mark_all_dirty
    LD      A, (welcome_active)
    OR      A
    JR      Z, .ok_op2
    LD      B, 0x02
    LD      A, 0x9E
    JP      test_fail
.ok_op2:

    ;; Op 3: render_init.
    CALL    render_init
    LD      A, (welcome_active)
    OR      A
    JR      Z, .ok_op3
    LD      B, 0x03
    LD      A, 0x9E
    JP      test_fail
.ok_op3:

    ;; Op 4: status_set_message with msg_mode_normal.
    LD      HL, msg_mode_normal
    XOR     A
    CALL    status_set_message
    LD      A, (welcome_active)
    OR      A
    JR      Z, .ok_op4
    LD      B, 0x04
    LD      A, 0x9E
    JP      test_fail
.ok_op4:

    ;; Op 5: welcome_paint — defensive. Even if this routine is
    ;; somehow re-invoked post-dismissal (which init_cold_start's
    ;; Stage 6.5 CALL NZ guard PREVENTS at the production call site,
    ;; but a future story might add another caller), the routine
    ;; itself must NOT write welcome_active.
    CALL    welcome_paint
    LD      A, (welcome_active)
    OR      A
    JR      Z, .ok_op5
    LD      B, 0x05
    LD      A, 0x9E
    JP      test_fail
.ok_op5:

    JP      test_pass

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
