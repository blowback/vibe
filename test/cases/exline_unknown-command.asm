; ============================================================
; Module: test/cases/exline_unknown-command.asm
; Purpose: AC5, AC12 — verify that a `:foo` (unknown command)
;          dispatch walks exline_command_table to the terminator,
;          surfaces msg_not_editor_command via status_set_message,
;          and tail-JPs to exline_cancel_core (which clears
;          ex_buffer + mode = NORMAL + sets status_dirty WITHOUT
;          touching status_buffer — so the error banner survives).
;
;          The "f" "o" "o" sequence exercises three properties:
;            - the table walk does not false-match a 1-byte prefix
;              of an entry (e.g. 'f' alone does not become anything),
;            - the length-mismatch path is taken (no entry has
;              length 3 at Story 2.1 baseline),
;            - the byte-compare path is taken (any future 3-letter
;              entry whose first byte is not 'f' must mismatch in
;              the byte-compare loop, not the length compare).
;
; AC reference: AC5 (unknown command -> msg + cancel-core),
;               AC12 (headless coverage).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE0 — init_teardown was wrongly called (sentinel != 0)
;   0xE1 — ex_buffer length != 0 after the cleanup
;   0xE2 — mode_byte != MODE_NORMAL
;   0xE3 — status_dirty == 0 (cancel-core's set step was skipped)
;   0xE4 — status_buffer[0..20] != "not an editor command"
;          (B = offending index of the first mismatch)
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
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (buffer_dirty), A           ; irrelevant to unknown-cmd path

    ;; Pre-load ex_buffer = length 3, bytes 'f' 'o' 'o'.
    LD      A, 3
    LD      (ex_buffer), A
    LD      A, 'f'
    LD      (ex_buffer_text), A
    LD      A, 'o'
    LD      (ex_buffer_text + 1), A
    LD      A, 'o'
    LD      (ex_buffer_text + 2), A

    ;; Drive the dispatch.
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

    ;; --- Subtest 2: ex_buffer length == 0 ---
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

    ;; --- Subtest 5: status_buffer[0..20] == "not an editor command" ---
    LD      HL, .expected_msg
    LD      DE, status_buffer
    LD      B, 21
    LD      C, 0
.cmp_msg:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_msg
    INC     HL
    INC     DE
    INC     C
    DJNZ    .cmp_msg
    JR      .ok_msg
.fail_msg:
    LD      B, C
    LD      A, 0xE4
    JP      test_fail
.ok_msg:

    JP      test_pass

.expected_msg:
    DEFB    "not an editor command"

;; ----- LOCAL init_teardown stub -----
init_teardown:
    LD      A, 1
    LD      (init_teardown_called), A
    RET
init_teardown_called:    DEFB 0

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
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
