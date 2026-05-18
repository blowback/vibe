; ============================================================
; Module: test/cases/motions_3w-three-words-forward.asm
; Purpose: AC4 — `3w` advances 3 word boundaries. Buffer
;          "one two three four" (18 bytes, no LF). cursor=0,
;          count=3. By-hand walk:
;            step 1: 'o' (word) → land on 't' of "two"   (offset 4)
;            step 2: 't' (word) → land on 't' of "three" (offset 8)
;            step 3: 't' (word) → land on 'f' of "four"  (offset 14)
;          Count cleared via parser_clear tail-JP.
;
; AC reference: AC4 / AC12 canonical-4 (story 2.7 Sub 2.4).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 14 ('f' of "four")
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
    LD      BC, 18
    LDIR
    LD      HL, GAP_BUFFER_BASE + 18
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL
    LD      HL, 3
    LD      (count_accumulator), HL

    LD      A, 'w'
    CALL    motion_w

    LD      HL, (cursor_offset)
    LD      DE, 14                      ; 'f' of "four"
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
    DEFB    "one two three four"

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
