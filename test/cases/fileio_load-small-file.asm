; ============================================================
; Module: test/cases/fileio_load-small-file.asm
; Purpose: AC5, AC13 — verify the small-file load orchestration.
;          Call fileio_load directly with HL = "hello.txt", A = 9.
;          The fixture (test/fixtures/hello.txt — 13 bytes,
;          "hello world\r\n") is mounted as iz-cpm's B: drive
;          (test/Makefile:53). Bare filename, so the parse
;          defaults to drive 2 (B: per FR9). Post-load state:
;            - cursor_offset = 0
;            - gap_start    = GAP_BUFFER_BASE (after move_gap(0))
;            - buffer_dirty = 0
;            - filename_buffer = "B:HELLO.TXT\0"
;            - status_buffer prefix = "B:HELLO.TXT "
;            - bytes at [gap_end, gap_end+13) = "hello world\r\n"
;
;          The exact loaded byte count (N) depends on iz-cpm's
;          partial-sector fill behaviour: CP/M 2.2 conventionally
;          pads with 0x1A, in which case N = 13; if not, N = 128
;          (the next BDOS_READ_SEQ returns A=1 / EOF instead). Both
;          scenarios leave the FILE bytes at the start of the
;          after-gap region; the test checks that prefix regardless
;          of which N applies.
;
; AC reference: AC5 (load orchestration), AC13 (headless coverage).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE0 — cursor_offset != 0
;   0xE1 — gap_start != GAP_BUFFER_BASE
;   0xE2 — buffer_dirty != 0
;   0xE3 — filename_buffer[0..11] != "B:HELLO.TXT" + NUL (B = idx)
;   0xE4 — status_buffer[0..11] != "B:HELLO.TXT " (B = idx)
;   0xE5 — after-gap[0..12] != "hello world\r\n" (B = idx)
;   0xE6 — status_dirty == 0
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
    LD      (filename_buffer), A
    ;; Initialise gap state via gapbuf_init — fileio_load also
    ;; calls it, but we want a known starting point.
    CALL    gapbuf_init

    ;; Call fileio_load directly: HL = "hello.txt", A = 9.
    LD      HL, .filename
    LD      A, 9
    CALL    fileio_load

    ;; --- Subtest 1: cursor_offset = 0 ---
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, L
    LD      A, 0xE0
    JP      test_fail
.ok_cursor:

    ;; --- Subtest 2: gap_start = GAP_BUFFER_BASE ---
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE
    JR      Z, .ok_gap_start
    LD      B, L
    LD      A, 0xE1
    JP      test_fail
.ok_gap_start:

    ;; --- Subtest 3: buffer_dirty = 0 ---
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
    LD      B, 12                           ; 11 chars + NUL
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

    ;; --- Subtest 5: status_buffer[0..11] == "B:HELLO.TXT " ---
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
    LD      A, 0xE4
    JP      test_fail
.ok_status:

    ;; --- Subtest 6: bytes at gap_end[0..12] == "hello world\r\n" ---
    LD      HL, .expected_content
    LD      DE, (gap_end)
    LD      B, 13
    LD      C, 0
.cmp_content:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_content
    INC     HL
    INC     DE
    INC     C
    DJNZ    .cmp_content
    JR      .ok_content
.fail_content:
    LD      B, C
    LD      A, 0xE5
    JP      test_fail
.ok_content:

    ;; --- Subtest 7: status_dirty set ---
    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok_status_dirty
    LD      B, A
    LD      A, 0xE6
    JP      test_fail
.ok_status_dirty:

    JP      test_pass

.filename:
    DEFB    "hello.txt"
.expected_filename:
    DEFB    "B:HELLO.TXT", 0
.expected_status_prefix:
    DEFB    "B:HELLO.TXT "
.expected_content:
    DEFB    "hello world", 0x0D, 0x0A

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
