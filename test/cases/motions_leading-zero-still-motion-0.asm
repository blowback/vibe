; ============================================================
; Module: test/cases/motions_leading-zero-still-motion-0.asm
; Purpose: AC8 — leading '0' with no count dispatches motion_0
;          (FR21). Story 2.6 retired parser_motion_zero_stub;
;          parser_handle_digit's leading-zero arm now JP motion_0.
;          Buffer "hello\nworld" (11 bytes). Cursor=8 (col 2 of
;          line 2 = 'r'); count=0 pre-set. Drive A='0' through
;          parser_handle_digit. Expected: motion_0 lands cursor
;          at start of line 2 (offset 6), count remains 0
;          (parser_clear zeroes a value already zero).
;
; AC reference: AC8 (story 2.7 Sub 3.5).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 6 (start of line 2)
;   0x81 — count_accumulator != 0
;   0x82 — pending_motion_prefix not cleared (motion_0's tail-JP
;          parser_clear didn't fire). Pre-seeded to 'g' (0x67) so
;          the count==0 assertion (vacuous when count was already 0)
;          is supplemented by a genuine parser_clear chain check.
;          Added by code review 2026-05-16 patch P2.
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
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A

    LD      A, 'g'                      ; pre-seed nonzero so the
    LD      (pending_motion_prefix), A  ; parser_clear chain check is genuine

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 11
    LDIR
    LD      HL, GAP_BUFFER_BASE + 11
    LD      (gap_start), HL

    LD      HL, 8                       ; col 2 of line 2 ('r')
    LD      (cursor_offset), HL

    LD      A, '0'
    CALL    parser_handle_digit

    LD      HL, (cursor_offset)
    LD      DE, 6                       ; start of line 2
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor
    LD      A, (cursor_offset)
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.ok_cursor:

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x81
    JP      test_fail
.ok_count:

    ;; Subtest 3: pending_motion_prefix cleared (genuine parser_clear
    ;; chain check — the count assertion above is vacuous when count
    ;; was already 0 entering, but pending_motion_prefix='g' on entry
    ;; only zeroes if motion_0's tail-JP parser_clear actually ran).
    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok_prefix
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_prefix:

    JP      test_pass

.payload:
    DEFB    "hello", 0x0A, "world"

    INCLUDE "../inc/test_epilogue.inc"

    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
