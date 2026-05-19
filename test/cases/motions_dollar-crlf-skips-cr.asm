; ============================================================
; Module: test/cases/motions_dollar-crlf-skips-cr.asm
; Purpose: Story 4.4 AC3 — motion_dollar on a CRLF-terminated
;          line walks back past the trailing CR so cursor lands
;          on the last PRINTABLE byte, not on the CR byte itself.
;
;          Subtest 1: buffer "abc\r\ndef" (8 bytes); cursor=0.
;          Expected: cursor=2 ('c'), NOT 3 (the CR position).
;
;          Subtest 2: empty CRLF line "\r\nxyz" (5 bytes); cursor=0.
;          Expected: cursor=0 (empty-line clamp — the HL==0 guard
;          fires; cursor must NOT underflow).
;
; AC reference: AC3 (Story 4.4) — motion_dollar trailing-CR
;               walkback; closes deferred-work.md L266.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — subtest 1 cursor_offset != 2 (CR walkback didn't fire)
;   0x81 — subtest 1 count_accumulator not cleared
;   0x82 — subtest 2 cursor_offset != 0 (empty-CRLF underflow!)
;   0x83 — subtest 2 count_accumulator not cleared
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    ;; ----- Subtest 1: "abc\r\ndef", cursor=0, $ → cursor=2 -----
    XOR     A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    CALL    gapbuf_init
    LD      HL, .payload_1
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 8
    LDIR
    LD      HL, GAP_BUFFER_BASE + 8
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, '$'
    CALL    motion_dollar

    LD      HL, (cursor_offset)
    LD      A, H
    OR      A
    JR      NZ, .fail_cursor_1
    LD      A, L
    CP      2
    JR      Z, .ok_cursor_1
.fail_cursor_1:
    LD      A, 0x80
    JP      test_fail
.ok_cursor_1:

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count_1
    LD      A, 0x81
    JP      test_fail
.ok_count_1:

    ;; ----- Subtest 2: "\r\nxyz", cursor=0, $ → cursor=0 (HL==0 guard) -----
    XOR     A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    CALL    gapbuf_init
    LD      HL, .payload_2
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 5
    LDIR
    LD      HL, GAP_BUFFER_BASE + 5
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, '$'
    CALL    motion_dollar

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor_2
    LD      A, 0x82
    JP      test_fail
.ok_cursor_2:

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count_2
    LD      A, 0x83
    JP      test_fail
.ok_count_2:

    JP      test_pass

.payload_1:
    DEFB    "abc", 0x0D, 0x0A, "def"
.payload_2:
    DEFB    0x0D, 0x0A, "xyz"

    INCLUDE "../inc/test_epilogue.inc"

    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
