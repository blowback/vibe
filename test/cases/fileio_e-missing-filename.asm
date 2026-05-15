; ============================================================
; Module: test/cases/fileio_e-missing-filename.asm
; Purpose: AC3, AC13 — verify that `:e` with no filename argument
;          surfaces msg_missing_filename and does not invoke
;          fileio_load. The cmd_edit handler's
;          fileio_strip_leading_spaces returns A=0 on a bare 'e'
;          (or 'e' followed by spaces only); cmd_edit then routes
;          msg_missing_filename through status_set_message and
;          tail-JPs to exline_cancel_core.
;
;          This test does NOT exercise the BDOS layer — the
;          missing-filename branch returns before fileio_load is
;          reached.
;
; AC reference: AC3 (no filename -> msg_missing_filename),
;               AC13 (headless coverage of the cmd_edit branches).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE0 — ex_buffer length != 0 after cleanup
;   0xE1 — mode_byte != MODE_NORMAL
;   0xE2 — status_buffer[0..15] != "missing filename" (B = offending index)
;   0xE3 — filename_buffer[0] != 0 (parse_filename was wrongly invoked)
;   0xE4 — status_dirty == 0 (cleanup path skipped the set)
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
    LD      (buffer_dirty), A
    LD      (filename_buffer), A            ; pre-zero so wrongly-invoked parse surfaces

    ;; Pre-load ex_buffer = "e" (length 1).
    LD      A, 1
    LD      (ex_buffer), A
    LD      A, 'e'
    LD      (ex_buffer_text), A

    ;; Drive the dispatch — exline_dispatch tokenises -> matches 'e'
    ;; -> cmd_edit gets HL = arg-ptr, A = 0 (no arg region) -> bails
    ;; via the missing-filename path.
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

    ;; --- Subtest 3: status_buffer[0..15] == "missing filename" ---
    LD      HL, .expected_missing
    LD      DE, status_buffer
    LD      B, 16
    LD      C, 0
.cmp_missing:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_missing
    INC     HL
    INC     DE
    INC     C
    DJNZ    .cmp_missing
    JR      .ok_missing
.fail_missing:
    LD      B, C
    LD      A, 0xE2
    JP      test_fail
.ok_missing:

    ;; --- Subtest 4: filename_buffer untouched (parse not invoked) ---
    LD      A, (filename_buffer)
    OR      A
    JR      Z, .ok_filename
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok_filename:

    ;; --- Subtest 5: status_dirty set by cleanup ---
    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok_dirty
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok_dirty:

    JP      test_pass

.expected_missing:
    DEFB    "missing filename"

;; ----- LOCAL init_teardown stub -----
    INCLUDE "../inc/test_teardown_stub.inc"
;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
;; gapbuf.asm is INCLUDEd because fileio.asm forward-references
;; gapbuf_init and gapbuf_move_gap; AR25 order is statusln ->
;; gapbuf -> render -> dispatch -> parser -> exline -> fileio.
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

;; ----- input_loop stub (resolves bdos_error_funnel symbol) -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
