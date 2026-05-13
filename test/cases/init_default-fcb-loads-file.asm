; ============================================================
; Module: test/cases/init_default-fcb-loads-file.asm
; Purpose: Story 2.3 AC3 + AC16 — verify the launch-load success
;          path through fileio_load_initial. Pre-populates
;          DEFAULT_FCB with the FCB encoding of `hello.txt`
;          (drive=0 default → FR9 translates to B:, basename
;          = "HELLO   ", extension = "TXT") then calls
;          fileio_load_initial. The fixture test/fixtures/hello.txt
;          is mounted as both A: and B: by test/Makefile.
;
;          Pre-state:
;            - DEFAULT_FCB[0]      = 0   (default drive — FR9 → B:)
;            - DEFAULT_FCB[1..8]   = "HELLO   " (CP/M space-pad)
;            - DEFAULT_FCB[9..11]  = "TXT"
;            - DEFAULT_FCB[12..35] = 0
;            - gapbuf_init applied
;
;          Post-state (after fileio_load_initial):
;            - cursor_offset      = 0
;            - gap_start          = GAP_BUFFER_BASE (post move_gap(0))
;            - buffer_dirty       = 0
;            - filename_buffer    = "B:HELLO.TXT\0"
;            - status_buffer[0..11] prefix = "B:HELLO.TXT "
;            - after-gap content prefix    = "hello world\r\n"
;
;          The exact byte-count digit in the status row depends on
;          iz-cpm's partial-sector fill: if the unread tail of the
;          sector contains 0x1A (CP/M convention) the load stops
;          at N = 13; otherwise the next BDOS_READ_SEQ returns
;          A=1 / EOF and N = 13 (the loaded prefix). Both yield
;          the same observable: the first 11 status chars are
;          "B:HELLO.TXT" and the 12th is space.
;
; AC reference: AC3 (load-success path), AC16 (headless coverage).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE0 — cursor_offset != 0
;   0xE1 — filename_buffer mismatch (B = index)
;   0xE2 — gap_start != GAP_BUFFER_BASE
;   0xE4 — buffer_dirty != 0
;   0xE5 — status_buffer prefix mismatch (B = index)
;   0xE6 — after-gap content mismatch (B = index)
;   B    — diagnostic byte where applicable
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

    ;; Pre-populate DEFAULT_FCB with the parsed form of `hello.txt`.
    ;; CCP space-pads the basename and extension; drive=0 means
    ;; "default drive" (FR9 will translate to B:).
    LD      A, 0
    LD      (DEFAULT_FCB + 0), A            ; drive = 0 (FR9 default → B:)
    LD      HL, .fcb_basename
    LD      DE, DEFAULT_FCB + 1
    LD      BC, 11                          ; 8 basename + 3 ext
    LDIR
    XOR     A
    LD      HL, DEFAULT_FCB + 12
    LD      (HL), A
    LD      DE, DEFAULT_FCB + 13
    LD      BC, 23
    LDIR                                    ; zero +12..+35

    ;; Call fileio_load_initial — should take the load-success path.
    CALL    fileio_load_initial

    ;; --- Subtest 1: cursor_offset = 0 ---
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, L
    LD      A, 0xE0
    JP      test_fail
.ok_cursor:

    ;; --- Subtest 2: filename_buffer = "B:HELLO.TXT\0" ---
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
    LD      A, 0xE1
    JP      test_fail
.ok_filename:

    ;; --- Subtest 3: gap_start = GAP_BUFFER_BASE (post move_gap(0)) ---
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_gap_start
    LD      B, L
    LD      A, 0xE2
    JP      test_fail
.ok_gap_start:

    ;; --- Subtest 4: buffer_dirty = 0 ---
    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok_dirty:

    ;; --- Subtest 5: status_buffer[0..11] = "B:HELLO.TXT " ---
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
    LD      A, 0xE5
    JP      test_fail
.ok_status:

    ;; --- Subtest 6: after-gap[0..12] = "hello world\r\n" ---
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
    LD      A, 0xE6
    JP      test_fail
.ok_content:

    JP      test_pass

.fcb_basename:
    DEFB    "HELLO   "                      ; 8 chars (5 + 3 spaces)
    DEFB    "TXT"                           ; 3 chars
.expected_filename:
    DEFB    "B:HELLO.TXT", 0                ; 11 + NUL = 12 bytes
.expected_status_prefix:
    DEFB    "B:HELLO.TXT "                  ; 11 + space
.expected_content:
    DEFB    "hello world", 0x0D, 0x0A       ; 13 bytes

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
