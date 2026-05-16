; ============================================================
; Module: test/cases/parser_5j-dispatches-with-count-5.asm
; Purpose: AC1 — end-to-end count consumption. Drive '5' through
;          parser_handle_digit, assert count_accumulator==5; then
;          CALL motion_j, assert cursor advanced 5 lines and the
;          parser state was cleared by motion_j's tail-JP
;          parser_clear.
;
;          Buffer: 10-line fixture "L01\nL02\n...\nL10" (no
;          trailing LF — each "Lnn" is 3 bytes, 9 LFs between
;          lines = 39 bytes total). Line N starts at offset
;          4*(N-1). Cursor pre-set to offset 0 (line 1, col 0).
;          After motion_j with count=5, cursor must land at the
;          start of line 6 = offset 20 (col 0, sticky-column
;          preserved across all 5 steps).
;
; AC reference: AC1 / AC12 canonical-1 (story 2.7 Sub 2.1).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — pre-motion count_accumulator != 5
;   0x81 — post-motion cursor_offset != 20 (start of line 6)
;   0x82 — post-motion count_accumulator != 0 (parser_clear)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    ;; Pre-zero all parser state and mode bytes.
    XOR     A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    ;; Populate gap-buffer with 10-line fixture (39 bytes, no trailing LF).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 39
    LDIR
    LD      HL, GAP_BUFFER_BASE + 39
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    ;; Subtest 1: drive '5' through parser_handle_digit; assert count=5.
    LD      A, '5'
    CALL    parser_handle_digit

    LD      HL, (count_accumulator)
    LD      A, H
    OR      A
    JR      NZ, .fail_pre_count
    LD      A, L
    CP      5
    JR      Z, .ok_pre_count
.fail_pre_count:
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_pre_count:

    ;; Subtest 2: CALL motion_j; assert cursor == 20 (line 6 start).
    LD      A, 'j'
    CALL    motion_j

    LD      HL, (cursor_offset)
    LD      DE, 20
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor
    LD      A, (cursor_offset)
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_cursor:

    ;; Subtest 3: count cleared by motion_j's tail-JP parser_clear.
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x82
    JP      test_fail
.ok_count:

    JP      test_pass

.payload:
    DEFB    "L01", 0x0A, "L02", 0x0A, "L03", 0x0A, "L04", 0x0A
    DEFB    "L05", 0x0A, "L06", 0x0A, "L07", 0x0A, "L08", 0x0A
    DEFB    "L09", 0x0A, "L10"

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
