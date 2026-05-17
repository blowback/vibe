; ============================================================
; Module: test/cases/exline_bare-enter.asm
; Purpose: Code-review patch — verify that an Enter pressed on a
;          bare ':' prompt (ex_buffer length 0) takes the silent
;          cancel path (exline_cancel) and DOES NOT surface
;          "not an editor command" via the no-match path.
;
;          Pre-patch, exline_dispatch's table walk ran with
;          length 0, mismatched every entry on length, fell into
;          .no_match, and surfaced msg_not_editor_command. The
;          patch adds a length==0 short-circuit at entry that
;          JPs to exline_cancel — a vi-faithful silent exit.
;
; AC reference: code-review patch P5 (2026-05-13) for the
;               decision-needed item D1 (vi-fidelity on bare-Enter).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE0 — init_teardown was wrongly called (sentinel != 0)
;   0xE1 — ex_buffer length != 0 after exline_dispatch
;   0xE2 — mode_byte != MODE_NORMAL
;   0xE3 — status_dirty == 0 (cancel's set step was skipped)
;   0xE4 — status_buffer[0] looks like the "not an editor command"
;          banner (the no-match path was wrongly taken)
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
    LD      (init_teardown_called), A
    LD      (status_dirty), A
    LD      (buffer_dirty), A           ; irrelevant to bare-enter path
    LD      (ex_buffer), A              ; length = 0 (the case under test)

    ;; Pre-set mode to COMMAND so we can detect the return-to-NORMAL.
    LD      A, MODE_COMMAND
    LD      (mode_byte), A

    ;; Drive the dispatch with Enter.
    LD      A, 0x0D
    CALL    exline_dispatch

    ;; --- Subtest 1: init_teardown NOT called ---
    LD      A, (init_teardown_called)
    OR      A
    JR      Z, .ok_no_teardown
    LD      B, A
    LD      A, 0xE0
    JP      test_fail
.ok_no_teardown:

    ;; --- Subtest 2: ex_buffer length still 0 ---
    LD      A, (ex_buffer)
    OR      A
    JR      Z, .ok_exlen
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok_exlen:

    ;; --- Subtest 3: mode_byte == MODE_NORMAL ---
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok_mode:

    ;; --- Subtest 4: status_dirty set ---
    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok_dirty
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok_dirty:

    ;; --- Subtest 5: status_buffer[0] is NOT 'n' (the first byte
    ;;     of "not an editor command"). The full exline_cancel
    ;;     path writes msg_mode_normal (the empty banner — first
    ;;     byte is a space). If 'n' appears here, the no-match
    ;;     path was wrongly taken. ---
    LD      A, (status_buffer)
    CP      'n'
    JR      NZ, .ok_no_error
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok_no_error:

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
    INCLUDE "../../src/edits.asm"     ; Story 2.8: dispatch_normal forward-references edits_*, dispatch_insert table grows, unbound_insert tail-JPs edits_insert_literal
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/exline.asm"
    ;; Story 2.2 / 2.3 pull-forward: exline.asm now references
    ;; fileio_load + fileio_strip_leading_spaces (cmd_edit / cmd_edit_force);
    ;; INCLUDE fileio.asm to resolve those forward references at build time.
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
