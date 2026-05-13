; ============================================================
; Module: test/cases/fileio_e-bang-force-dirty.asm
; Purpose: AC4, AC13 — verify that `:e! hello.txt` on a DIRTY
;          buffer bypasses the dirty refusal (BH6: the '!' is
;          the user's explicit consent) and proceeds with the
;          load. Post-load: buffer_dirty = 0 (the load resets
;          it), filename_buffer = "B:HELLO.TXT\0",
;          status_buffer prefix = "B:HELLO.TXT ".
;
; AC reference: AC4 (cmd_edit_force skips dirty check),
;               AC13 (headless coverage).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE0 — ex_buffer length != 0 after cleanup
;   0xE1 — mode_byte != MODE_NORMAL
;   0xE2 — buffer_dirty != 0 (load failed to reset it)
;   0xE3 — filename_buffer[0..11] != "B:HELLO.TXT" + NUL (B = idx)
;   0xE4 — status_buffer[0..19] != "B:HELLO.TXT 13 bytes" (B = idx)
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
    LD      (filename_buffer), A
    CALL    gapbuf_init

    ;; Mark the buffer dirty.
    LD      A, 1
    LD      (buffer_dirty), A

    ;; Pre-load ex_buffer = "e! hello.txt" (length 12).
    LD      A, 12
    LD      (ex_buffer), A
    LD      HL, .ex_payload
    LD      DE, ex_buffer_text
    LD      BC, 12
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

    ;; --- Subtest 3: buffer_dirty reset to 0 (load succeeded) ---
    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok_dirty:

    ;; --- Subtest 4: filename_buffer = "B:HELLO.TXT\0" ---
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
    JR      .ok_filename
.fail_filename:
    LD      B, C
    LD      A, 0xE3
    JP      test_fail
.ok_filename:

    ;; --- Subtest 5: status_buffer[0..19] = "B:HELLO.TXT 13 bytes" ---
    LD      HL, .expected_status_prefix
    LD      DE, status_buffer
    LD      B, 20
    LD      C, 0
.cmp_status:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_status
    INC     HL
    INC     DE
    INC     C
    DJNZ    .cmp_status
    JR      .ok_status
.fail_status:
    LD      B, C
    LD      A, 0xE4
    JP      test_fail
.ok_status:

    JP      test_pass

.ex_payload:
    DEFB    "e! hello.txt"
.expected_filename:
    DEFB    "B:HELLO.TXT", 0
.expected_status_prefix:
    DEFB    "B:HELLO.TXT 13 bytes"

;; ----- LOCAL init_teardown stub -----
init_teardown:
    LD      A, 1
    LD      (init_teardown_called), A
    RET
init_teardown_called:    DEFB 0

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
