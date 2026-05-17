; ============================================================
; Module: test/cases/parser_p-dispatch.asm
; Purpose: AC10 additional — drive `p` through the production
;          dispatch_key chain. Pre-load `"abc"` (3 B), cursor=0,
;          mode=NORMAL. Pre-seed yank: KIND_CHAR, len=1, "X".
;          CALL dispatch_key with A='p', HL=dispatch_normal,
;          B=DISPATCH_NORMAL_COUNT. The dispatcher binary-searches
;          to the new 'p' entry (between 'o' and 'v'); routes to
;          op_paste. op_paste's KIND_CHAR body inserts "X" after
;          cursor=0 (advanced to 1) → cursor=2 post-insert;
;          DEC cursor → 1.
;
;          Assert: buffer="aXbc" (4 B); cursor=1 (on 'X' — last
;          inserted byte); buffer_dirty=1; parser cleared.
;
;          Pins: AC1 dispatch wiring — the new 'p' entry routes
;          correctly through dispatch_key's binary-search; the
;          handler signature (A=key=ASCII 'p' on entry, ignored
;          per MC4) matches op_paste's contract.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — cursor_offset != 1 post-dispatch
;   0xE2 — buffer content != "aXbc" (B = mismatch index)
;   0xE3 — buffer_dirty != 1
;   0xE4 — parser state not cleared
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (status_dirty), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (buffer_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, KIND_CHAR
    LD      (yank_kind), A
    LD      HL, 1
    LD      (yank_length), HL
    LD      HL, .yank_content
    LD      DE, yank_buffer
    LD      BC, 1
    LDIR

    ;; Drive 'p' through the production dispatcher.
    LD      A, 'p'
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key

    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xE1
    JP      test_fail
.ok_cursor:

    LD      HL, 0
    LD      DE, .expected
    LD      B, 4
.cmp_loop:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .cmp_next
    LD      A, 4
    SUB     B
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok_dirty:

    LD      A, (pending_operator)
    OR      A
    JR      NZ, .parser_fail
    LD      A, (pending_motion_prefix)
    OR      A
    JR      NZ, .parser_fail
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .parser_ok
.parser_fail:
    LD      A, 0xE4
    JP      test_fail
.parser_ok:

    JP      test_pass

.payload:
    DEFB    "abc"
.yank_content:
    DEFB    "X"
.expected:
    DEFB    "aXbc"

    INCLUDE "../inc/test_teardown_stub.inc"
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

    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
