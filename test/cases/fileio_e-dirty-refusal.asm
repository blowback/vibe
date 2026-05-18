; ============================================================
; Module: test/cases/fileio_e-dirty-refusal.asm
; Purpose: AC3, AC13 — verify that `:e foo.fs` on a DIRTY buffer
;          (buffer_dirty != 0) is refused: cmd_edit writes
;          msg_no_write via status_set_message and tail-JPs to
;          exline_cancel_core, leaving the buffer + filename
;          state untouched (no fileio_load call).
;
; AC reference: AC3 (dirty :e refuses with msg_no_write — BH6),
;               AC13 (headless coverage of the cmd_edit branches).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE0 — ex_buffer length != 0 after refusal
;   0xE1 — mode_byte != MODE_NORMAL
;   0xE2 — status_buffer[0..25] != "no write since last change"
;          (B = offending index)
;   0xE3 — filename_buffer[0] != 0 (parse_filename was wrongly invoked)
;   0xE4 — buffer_dirty cleared (load wrongly proceeded and reset it)
;   B    — diagnostic context (varies)
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
    LD      (filename_buffer), A

    ;; Mark buffer dirty.
    LD      A, 1
    LD      (buffer_dirty), A

    ;; Pre-load ex_buffer = "e foo.fs" (length 8).
    LD      A, 8
    LD      (ex_buffer), A
    LD      HL, .ex_payload
    LD      DE, ex_buffer_text
    LD      BC, 8
    LDIR

    ;; Drive the dispatch.
    LD      A, 0x0D
    CALL    exline_dispatch

    ;; --- Subtest 1: ex_buffer length cleared ---
    LD      A, (ex_buffer)
    OR      A
    JR      Z, .ok_exlen
    LD      B, A
    LD      A, 0xE0
    JP      test_fail
.ok_exlen:

    ;; --- Subtest 2: mode_byte = MODE_NORMAL ---
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok_mode:

    ;; --- Subtest 3: status_buffer[0..25] == "no write since last change" ---
    LD      HL, .expected_no_write
    LD      DE, status_buffer
    LD      B, 26
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
    LD      A, 0xE2
    JP      test_fail
.ok_msg:

    ;; --- Subtest 4: filename_buffer untouched (load NOT invoked) ---
    LD      A, (filename_buffer)
    OR      A
    JR      Z, .ok_filename
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok_filename:

    ;; --- Subtest 5: buffer_dirty still 1 (refusal does not clear it) ---
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok_dirty:

    JP      test_pass

.ex_payload:
    DEFB    "e foo.fs"
.expected_no_write:
    DEFB    "no write since last change"

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
    INCLUDE "../../src/search.asm"     ; Story 2.8: dispatch_normal forward-references edits_*, dispatch_insert table grows, unbound_insert tail-JPs edits_insert_literal
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
