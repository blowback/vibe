; ============================================================
; Module: test/cases/motions_count-j-sticky-column.asm
; Purpose: AC10 — Option B vi-faithful sticky-column across
;          counted j. Buffer "hello\nab\nworld" (14 bytes,
;          line starts: 0 / 6 / 9). Cursor=4 (col 4 of line 1 =
;          'o'); count=2; motion_j should land cursor at
;          offset 13 (col 4 of line 3 = 'd' of "world").
;
;          By-hand trace under Option B (motions_col saved once
;          at entry):
;            Entry: motions_col = 4.
;            Step 1: clamp_col on line 2 ("ab", length 2) = 1;
;                    new_col = min(4, 1) = 1; cursor = 6+1 = 7
;                    ('b' of "ab").
;            Step 2: motions_col STILL = 4 (entry value, not
;                    re-derived); clamp_col on line 3 ("world",
;                    length 5) = 4; new_col = min(4, 4) = 4;
;                    cursor = 9+4 = 13 ('d' of "world").
;
;          Note: spec sub-bullet 3.6 quoted Option B target as
;          cursor=12, but col 4 of "world" is 'd' at offset 13
;          (col 3 is 'l' at 12). Test pins the arithmetically
;          correct value derived from first principles; the
;          spec bug is documented in Completion Notes.
;
; AC reference: AC10 / AC12 (story 2.7 Sub 3.6).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 13 ('d' of "world", col 4 of line 3)
;   0x81 — count_accumulator not cleared
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

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 14
    LDIR
    LD      HL, GAP_BUFFER_BASE + 14
    LD      (gap_start), HL

    LD      HL, 4                       ; col 4 of line 1 ('o' of "hello")
    LD      (cursor_offset), HL
    LD      HL, 2
    LD      (count_accumulator), HL

    LD      A, 'j'
    CALL    motion_j

    LD      HL, (cursor_offset)
    LD      DE, 13                      ; col 4 of line 3 ('d' of "world")
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

    JP      test_pass

.payload:
    DEFB    "hello", 0x0A, "ab", 0x0A, "world"

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
