; ============================================================
; Module: test/cases/fileio_load-with-1A-eof.asm
; Purpose: AC5, AC13 — verify that a 0x1A byte mid-sector
;          terminates the load. The fixture
;          (test/fixtures/eof1a.txt) contains 7 bytes: "abc" +
;          0x1A + "xyz". fileio_ingest_sector scans the sector,
;          finds 0x1A at offset 3, copies [0,3) = "abc" into the
;          gap buffer, and signals "stop reading".
;
;          Post-load: 3 bytes loaded; gap_end = GAP_BUFFER_BASE +
;          GAP_BUFFER_MAX - 3; after-gap[0..3] = "abc";
;          status_buffer prefix = "B:EOF1A.TXT 3 bytes".
;
; AC reference: AC5 step 5 (0x1A scan + truncated copy),
;               AC13 (headless coverage).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE0 — cursor_offset != 0
;   0xE1 — gap_start != GAP_BUFFER_BASE
;   0xE2 — gap_end != GAP_BUFFER_BASE + GAP_BUFFER_MAX - 3
;          (B = low byte of observed delta from expected)
;   0xE3 — buffer_dirty != 0
;   0xE4 — after-gap[0..2] != "abc" (B = offending idx)
;   0xE5 — status_buffer[0..18] != "B:EOF1A.TXT 3 bytes" (B = idx)
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

    ;; --- Subtest 3: gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX - 3
    ;; (i.e. 3 bytes loaded, gap takes everything else). ---
    LD      HL, (gap_end)
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX - 3
    OR      A
    SBC     HL, DE
    JR      Z, .ok_gap_end
    LD      B, L
    LD      A, 0xE2
    JP      test_fail
.ok_gap_end:

    ;; --- Subtest 4: buffer_dirty = 0 ---
    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok_dirty:

    ;; --- Subtest 5: after-gap content [gap_end..gap_end+3] = "abc" ---
    LD      HL, .expected_content
    LD      DE, (gap_end)
    LD      B, 3
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
    LD      A, 0xE4
    JP      test_fail
.ok_content:

    ;; --- Subtest 6: status_buffer[0..18] = "B:EOF1A.TXT 3 bytes" ---
    LD      HL, .expected_status
    LD      DE, status_buffer
    LD      B, 19
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

    JP      test_pass

.filename:
    DEFB    "eof1a.txt"
.expected_content:
    DEFB    "abc"
.expected_status:
    DEFB    "B:EOF1A.TXT 3 bytes"

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
    INCLUDE "../../src/motions.asm"     ; Story 2.5: dispatch_normal forward-references motion_h/j/k/l
    INCLUDE "../../src/edits.asm"     ; Story 2.8: dispatch_normal forward-references edits_*, dispatch_insert table grows, unbound_insert tail-JPs edits_insert_literal
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
