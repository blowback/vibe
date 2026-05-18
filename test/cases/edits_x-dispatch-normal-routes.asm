; ============================================================
; Module: test/cases/edits_x-dispatch-normal-routes.asm
; Purpose: AC10 regression net — 'x' (0x78) routes through
;          dispatch_normal's binary search to edits_delete_char.
;          Pre-state: "abcdef" (6 B), cursor=2 ('c'),
;          mode=NORMAL, buffer_dirty=0. Drive 'x' via
;          dispatch_key against dispatch_normal. Path: binary
;          search finds 'x' between 'w' and 'y' → edits_delete_char
;          → gapbuf_delete consumes 'c' → cursor=2 (mid-line,
;          unchanged); buffer = "abdef" (5 B); buffer_dirty=1.
;
;          Pins the AC10 dispatch_normal entry-routing wiring —
;          a future re-stitch (wrong ASSERT, wrong handler addr)
;          can't silently break it.
;
; AC reference: AC10 (dispatch_normal entry growth).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 2 (binary search miss / wrong handler)
;   0x81 — buffer content != "abdef" (B = mismatch index)
;   0x82 — buffer_dirty != 1
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

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 6
    LDIR
    LD      HL, GAP_BUFFER_BASE + 6
    LD      (gap_start), HL

    LD      HL, 2
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; Drive 'x' (0x78) through dispatch_normal.
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    LD      A, 'x'
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
    LD      B, 5
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
    LD      A, 5
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

    JP      test_pass

.payload:
    DEFB    "abcdef"
.expected:
    DEFB    "abdef"

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
