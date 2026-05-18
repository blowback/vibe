; ============================================================
; Module: test/cases/parser_3p-dispatch.asm
; Purpose: AC10 additional — drive `3` `p` through the full
;          parser-then-dispatch chain. Pre-load `"a"` (1 B),
;          cursor=0, mode=NORMAL. Pre-seed yank: KIND_CHAR, len=1,
;          "b". CALL parser_handle_digit with A='3' (accumulates
;          count → 3); CALL dispatch_key with A='p' (routes to
;          op_paste). op_paste reads count=3 via motion_apply_count
;          BEFORE its tail-JP parser_clear (the state-read-before-
;          clear discipline). KIND_CHAR insertion: advance cursor
;          0 → 1; insert 'b' three times; cursor 1 → 2 → 3 → 4;
;          DEC cursor → 3.
;
;          Assert: buffer="abbb" (4 B); cursor=3 (on last 'b');
;          count_accumulator=0 (cleared by op_paste's tail-JP
;          parser_clear); buffer_dirty=1; parser cleared.
;
;          Pins: counted `Np` end-to-end through parser_handle_digit
;          + dispatch_key + op_paste; state-read-before-clear
;          invariant (a regression that called parser_clear before
;          motion_apply_count would deliver count=0 → defaulted to
;          1 → only 1 'b' inserted; test catches via buffer + cursor
;          mismatch).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — post-'3': count_accumulator != 3
;   0xE2 — post-'p': cursor_offset != 3
;   0xE3 — post-'p': buffer content != "abbb" (B = mismatch index)
;   0xE4 — post-'p': count_accumulator != 0 (parser_clear didn't run)
;   0xE5 — post-'p': buffer_dirty != 1
;   0xE6 — post-'p': pending_operator or pending_motion_prefix
;          not cleared (parser_clear didn't run completely)
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
    LD      BC, 1
    LDIR
    LD      HL, GAP_BUFFER_BASE + 1
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

    ;; Subtest 1: drive '3' through parser_handle_digit; assert count=3.
    LD      A, '3'
    CALL    parser_handle_digit

    LD      HL, (count_accumulator)
    LD      DE, 3
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_count_pre
    LD      HL, (count_accumulator)
    LD      B, L
    LD      A, 0xE1
    JP      test_fail
.ok_count_pre:

    ;; Subtest 2: drive 'p' through dispatch_key; assert paste-with-count.
    LD      A, 'p'
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key

    LD      HL, (cursor_offset)
    LD      DE, 3
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xE2
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
    LD      A, 0xE3
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count_post
    LD      B, L
    LD      A, 0xE4
    JP      test_fail
.ok_count_post:

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xE5
    JP      test_fail
.ok_dirty:

    ;; Additional parser-cleared assertions (P7 — code review
    ;; 2026-05-17). Existing 0xE4 covers count_accumulator only;
    ;; this strengthening pins all three parser fields so a
    ;; regression that cleared only the count would still fail.
    LD      A, (pending_operator)
    OR      A
    JR      NZ, .parser_fail
    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .parser_ok
.parser_fail:
    LD      B, A
    LD      A, 0xE6
    JP      test_fail
.parser_ok:

    JP      test_pass

.payload:
    DEFB    "a"
.yank_content:
    DEFB    "b"
.expected:
    DEFB    "abbb"

    INCLUDE "../inc/test_teardown_stub.inc"
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

    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
