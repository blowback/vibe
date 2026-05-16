; ============================================================
; Module: test/cases/edits_insert-fills-buffer.asm
; Purpose: Canonical Story 2.8 test 5 — AC8 buffer-full overflow.
;          Pre-fill GAP_BUFFER_MAX - 1 = 32767 bytes of 'A';
;          cursor=32767 (file_length, just before the last free
;          slot); mode=INSERT. First literal 'X' succeeds —
;          gap_start advances to gap_end (buffer fully utilised).
;          Second literal 'Y' triggers gapbuf_insert overflow:
;          status_buffer holds msg_file_too_large; mode flips to
;          NORMAL (edits_insert_literal's overflow-to-normal exit);
;          cursor stays at 32768 (the 'X' succeeded).
;
; AC reference: AC8 (overflow exits INSERT; partial preserved).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 32768 after 'X' insert
;   0x81 — cursor_offset != 32768 after 'Y' attempt
;          (overflow must NOT advance cursor)
;   0x82 — mode_byte != MODE_NORMAL after 'Y' overflow
;   0x83 — status_buffer[0..13] != "file too large" (B = idx)
;   0x84 — buffer_dirty != 1 after the successful 'X' insert
;          (AC9 partial-text-preserved invariant — FR52)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (buffer_dirty), A

    CALL    gapbuf_init

    ;; Fill GAP_BUFFER_BASE..GAP_BUFFER_BASE+32766 with 'A'
    ;; (32767 bytes). Pattern: seed one byte then LDIR-propagate.
    LD      HL, GAP_BUFFER_BASE
    LD      (HL), 'A'
    LD      DE, GAP_BUFFER_BASE + 1
    LD      BC, 32766
    LDIR

    LD      HL, GAP_BUFFER_BASE + 32767
    LD      (gap_start), HL
    ;; gap_end stays at GAP_BUFFER_BASE + GAP_BUFFER_MAX (= base + 32768)
    ;; from gapbuf_init; gap window is 1 slot wide (about-to-fill).

    LD      HL, 32767
    LD      (cursor_offset), HL

    LD      A, MODE_INSERT
    LD      (mode_byte), A

    ;; First insert: 'X' should succeed; cursor → 32768.
    LD      A, 'X'
    CALL    edits_insert_literal

    LD      HL, (cursor_offset)
    LD      DE, 32768
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor_X
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_cursor_X:

    ;; Second insert: 'Y' must overflow — cursor stays, mode → NORMAL.
    LD      A, 'Y'
    CALL    edits_insert_literal

    LD      HL, (cursor_offset)
    LD      DE, 32768
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor_Y
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x81
    JP      test_fail
.ok_cursor_Y:

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_mode:

    ;; status_buffer prefix = "file too large" (14 bytes).
    LD      HL, .expected_status
    LD      DE, status_buffer
    LD      B, 14
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
    LD      A, 0x83
    JP      test_fail
.ok_status:

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x84
    JP      test_fail
.ok_dirty:

    JP      test_pass

.expected_status:
    DEFB    "file too large"

    INCLUDE "../inc/test_epilogue.inc"

    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
