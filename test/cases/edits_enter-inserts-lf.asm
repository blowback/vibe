; ============================================================
; Module: test/cases/edits_enter-inserts-lf.asm
; Purpose: AC10 — Enter (0x0D) in INSERT inserts LF (0x0A) via
;          dispatch_insert's explicit 0x0D entry routing to
;          edits_insert_newline. Pre-load "abc" (3 B), cursor=1,
;          mode=INSERT. Drive 0x0D through dispatch_key against
;          dispatch_insert. Assert buffer "a\nbc" (4 B), cursor=2,
;          buffer_dirty=1, mode unchanged.
;
; AC reference: AC10 (0x0D → 0x0A translation), AC12
;               (dispatch_insert table grown to include 0x0D).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 2 post-Enter
;   0x81 — buffer content != "a\nbc" (B = mismatch index)
;   0x82 — buffer_dirty != 1
;   0x83 — mode_byte not preserved at MODE_INSERT
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

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 1
    LD      (cursor_offset), HL

    LD      A, MODE_INSERT
    LD      (mode_byte), A

    ;; Drive 0x0D via dispatch_key against dispatch_insert table.
    LD      HL, dispatch_insert
    LD      B, DISPATCH_INSERT_COUNT
    LD      A, 0x0D
    CALL    dispatch_key

    LD      HL, (cursor_offset)
    LD      DE, 2
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_cursor:

    LD      HL, 0
    LD      DE, .expected
    LD      B, 4
.cmp_loop:
    PUSH    DE
    CALL    motion_byte_at_logical
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .cmp_next
    LD      A, 4
    SUB     B
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_dirty:

    LD      A, (mode_byte)
    CP      MODE_INSERT
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_mode:

    JP      test_pass

.payload:
    DEFB    "abc"
.expected:
    DEFB    "a",0x0A,"bc"

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
