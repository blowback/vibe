; ============================================================
; Module: test/cases/exline_q-dirty-buffer.asm
; Purpose: AC7, AC12 — verify that `:q` on a DIRTY buffer
;          (buffer_dirty != 0) is refused: cmd_quit writes
;          msg_no_write via status_set_message, then tail-JPs
;          to exline_cancel_core. The core path clears ex_buffer
;          length, flips mode to NORMAL, and sets status_dirty
;          WITHOUT touching status_buffer — so the refusal
;          banner survives.
;
;          A local init_teardown stub is present (same as the
;          clean-buffer test) so any accidental teardown call
;          surfaces via the sentinel rather than warm-booting
;          iz-cpm out from under the test. On the green path
;          the sentinel stays 0 (clean refusal, no teardown).
;
; AC reference: AC7 (dirty :q refuses with msg_no_write),
;               AC12 (headless coverage).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE0 — init_teardown_called != 0 (cmd_quit must NOT have
;          taken the warm-boot branch on a dirty buffer)
;   0xE1 — ex_buffer length != 0 after the refusal
;   0xE2 — mode_byte != MODE_NORMAL after the refusal
;   0xE3 — status_dirty == 0 (exline_cancel_core sets it; the
;          test fails if the cleanup path skipped this step)
;   0xE4 — status_buffer[0..25] != "no write since last change"
;          (B = offending index of the first mismatching byte)
;   B    — diagnostic context (varies per subtest; see above)
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

    ;; Pre-zero the sentinel + mode + status_dirty.
    XOR     A
    LD      (init_teardown_called), A
    LD      (mode_byte), A              ; MODE_NORMAL = 0
    LD      (status_dirty), A

    ;; Mark the buffer dirty. Any nonzero value works; pick 1
    ;; (the value buffer-mutation paths will set in Story 2.8+).
    LD      A, 1
    LD      (buffer_dirty), A

    ;; Pre-load ex_buffer = length 1, byte 'q' at ex_buffer_text.
    LD      A, 1
    LD      (ex_buffer), A
    LD      A, 'q'
    LD      (ex_buffer_text), A

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

    ;; --- Subtest 2: ex_buffer length cleared to 0 ---
    LD      A, (ex_buffer)
    OR      A
    JR      Z, .ok_exlen
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok_exlen:

    ;; --- Subtest 3: mode_byte = MODE_NORMAL ---
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

    ;; --- Subtest 5: status_buffer[0..25] == "no write since last change" ---
    LD      HL, .expected_no_write
    LD      DE, status_buffer
    LD      B, 26
    LD      C, 0                        ; C = running index for diagnostic
.cmp_no_write:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_no_write
    INC     HL
    INC     DE
    INC     C
    DJNZ    .cmp_no_write
    JR      .ok_msg
.fail_no_write:
    LD      B, C                        ; offending index
    LD      A, 0xE4
    JP      test_fail
.ok_msg:

    JP      test_pass

.expected_no_write:
    DEFB    "no write since last change"

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

;; ----- input_loop stub (resolves bdos_error_funnel symbol) -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
