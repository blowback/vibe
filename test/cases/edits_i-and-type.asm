; ============================================================
; Module: test/cases/edits_i-and-type.asm
; Purpose: Canonical Story 2.8 test 1 — `i` enters INSERT mode,
;          5 literal bytes type as "Hello", Esc returns to NORMAL.
;          Empty-buffer start; cursor advances per insert; mode
;          flips on i and Esc; buffer_dirty becomes 1 on first
;          insert and stays 1.
;
; AC reference: AC1 (i enters INSERT), AC5 (literal byte insert),
;               AC7 (Esc returns to NORMAL), AC9 (buffer_dirty).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — mode_byte != MODE_INSERT after CALL enter_insert_mode
;   0x81 — cursor_offset != 5 after typing "Hello"
;   0x82 — buffer_dirty != 1 after typing
;   0x83 — gap content != "Hello" (B = byte index of first mismatch)
;   0x84 — mode_byte != MODE_NORMAL after CALL enter_normal_mode
;   0x85 — cursor_offset changed by Esc
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

    CALL    gapbuf_init                  ; empty buffer; cursor=0

    ;; --- Subtest 1: 'i' → enter_insert_mode → MODE_INSERT ---
    LD      A, 'i'
    CALL    enter_insert_mode
    LD      A, (mode_byte)
    CP      MODE_INSERT
    JR      Z, .ok_i
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.ok_i:

    ;; --- Subtest 2: type "Hello" — 5 literal-byte inserts ---
    LD      A, 'H'
    CALL    edits_insert_literal
    LD      A, 'e'
    CALL    edits_insert_literal
    LD      A, 'l'
    CALL    edits_insert_literal
    LD      A, 'l'
    CALL    edits_insert_literal
    LD      A, 'o'
    CALL    edits_insert_literal

    LD      HL, (cursor_offset)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x81
    JP      test_fail
.ok_cursor:

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_dirty:

    ;; --- Subtest 3: gap content = "Hello" (5 bytes via byte-walk) ---
    LD      HL, 0
    LD      DE, .expected
    LD      B, 5
.cmp_loop:
    PUSH    DE
    CALL    motion_byte_at_logical       ; A = byte at logical HL; HL, BC preserved
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .cmp_next
    LD      A, 5
    SUB     B                             ; A = byte index processed so far
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    ;; --- Subtest 4: Esc → enter_normal_mode → MODE_NORMAL ---
    LD      A, 0x1B
    CALL    enter_normal_mode
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_normal
    LD      B, A
    LD      A, 0x84
    JP      test_fail
.ok_normal:

    LD      HL, (cursor_offset)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_esc_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x85
    JP      test_fail
.ok_esc_cursor:

    JP      test_pass

.expected:
    DEFB    "Hello"

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
