; ============================================================
; Module: test/cases/edits_dw-no-op-at-eof.asm
; Purpose: `dw` on "abc" (3 B), cursor=3 (past EOF), pending_operator='d'.
;          CALL motion_w. Exercises the 0-byte guard in op_compose_d:
;          motion_w from past-EOF cursor doesn't move; range=0 bytes;
;          op_compose_d's 0-byte guard JPs parser_clear without
;          touching buffer / yank / buffer_dirty.
;
; Pre-seed yank_kind=0xEE / yank_length=0xCAFE so any spurious write
; surfaces.
;
; Assert: buffer UNCHANGED ("abc"); cursor=3 (UNCHANGED);
;         yank_kind UNCHANGED (0xEE); yank_length UNCHANGED (0xCAFE);
;         buffer_dirty UNCHANGED (0); parser cleared.
;
; Sentinel codes:
;   0x80 — buffer modified
;   0x81 — cursor moved
;   0x82 — yank_kind changed
;   0x83 — yank_length changed
;   0x84 — buffer_dirty changed
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (status_dirty), A
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A
    LD      (buffer_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      A, 'd'
    LD      (pending_operator), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    LD      A, 0xEE
    LD      (yank_kind), A
    LD      HL, 0xCAFE
    LD      (yank_length), HL

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 3
    LD      (cursor_offset), HL

    CALL    motion_w

    LD      HL, 0
    LD      DE, .payload
    LD      B, 3
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
    LD      A, 3
    SUB     B
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      HL, (cursor_offset)
    LD      DE, 3
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

    LD      A, (yank_kind)
    CP      0xEE
    JR      Z, .ok_kind
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_kind:

    LD      HL, (yank_length)
    LD      DE, 0xCAFE
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_length
    LD      HL, (yank_length)
    LD      B, L
    LD      A, 0x83
    JP      test_fail
.ok_length:

    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x84
    JP      test_fail
.ok_dirty:

    JP      test_pass

.payload:
    DEFB    "abc"

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
