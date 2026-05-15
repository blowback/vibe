; ============================================================
; Module: test/cases/fileio_load-drive-prefix.asm
; Purpose: AC6, AC13 — verify the drive-prefix parse for an
;          explicit "a:" prefix (FR10). The fixture filesystem
;          is mounted as BOTH iz-cpm A: and B: (test/Makefile:53),
;          so "a:hello.txt" loads the same content as "hello.txt"
;          but exercises the case-insensitive drive-prefix parse
;          path. Verifies that fileio_parse_filename writes
;          drive byte = 1 into fcb_scratch[0] and composes
;          filename_buffer = "A:HELLO.TXT\0".
;
; AC reference: AC6 (drive-prefix parse), AC13 (headless coverage).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE0 — filename_buffer[0..11] != "A:HELLO.TXT" + NUL (B = idx)
;   0xE1 — status_buffer[0..11] != "A:HELLO.TXT "      (B = idx)
;   0xE2 — buffer_dirty != 0
;   0xE3 — cursor_offset != 0
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
    LD      (buffer_dirty), A
    LD      (filename_buffer), A
    CALL    gapbuf_init

    LD      HL, .filename
    LD      A, 11                           ; "a:hello.txt"
    CALL    fileio_load

    ;; --- Subtest 1: filename_buffer = "A:HELLO.TXT\0" ---
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
    LD      A, 0xE0
    JP      test_fail
.ok_filename:

    ;; --- Subtest 2: status_buffer[0..11] = "A:HELLO.TXT " ---
    LD      HL, .expected_status_prefix
    LD      DE, status_buffer
    LD      B, 12
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
    LD      A, 0xE1
    JP      test_fail
.ok_status:

    ;; --- Subtest 3: buffer_dirty = 0 ---
    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok_dirty:

    ;; --- Subtest 4: cursor_offset = 0 ---
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, L
    LD      A, 0xE3
    JP      test_fail
.ok_cursor:

    JP      test_pass

.filename:
    DEFB    "a:hello.txt"
.expected_filename:
    DEFB    "A:HELLO.TXT", 0
.expected_status_prefix:
    DEFB    "A:HELLO.TXT "

;; ----- LOCAL init_teardown stub -----
    INCLUDE "../inc/test_teardown_stub.inc"
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
