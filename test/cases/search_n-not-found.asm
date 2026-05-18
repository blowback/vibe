; ============================================================
; Module: test/cases/search_n-not-found.asm
; Purpose: Story 3.2 AC8 canonical-3 — `n` both passes miss.
;          Buffer "foo bar baz" (11 B); cursor pre-set to 0;
;          search_pattern pre-seeded to "xyz" (no match anywhere
;          in the buffer). CALL search_next.
;          First pass walks [1, 11) — no "xyz"; CF=1. Wrap pass
;          walks [0, 1) — no "xyz"; CF=1.
;          Expect cursor UNCHANGED at 0 (vi convention: failed
;          search leaves cursor in place), status_buffer starts
;          with "pattern not found" (17 chars), mode_byte =
;          MODE_NORMAL.
;
; Sentinel 0xAD at 0xCFFE; context byte:
;   0 — cursor_offset != 0
;   1 — status_buffer != "pattern not found..." (B = mismatch idx)
;   2 — mode_byte != MODE_NORMAL
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
    LD      (command_submode), A
    LD      (ex_buffer), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 11
    LDIR
    LD      HL, GAP_BUFFER_BASE + 11
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, 3
    LD      (search_pattern), A
    LD      HL, .pattern
    LD      DE, search_pattern_text
    LD      BC, 3
    LDIR

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    search_next

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xAD
    JP      test_fail
.ok_cursor:

    LD      HL, status_buffer
    LD      DE, .expected_status
    LD      B, 17
.cmp_status:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .status_fail
    INC     HL
    INC     DE
    DJNZ    .cmp_status
    JR      .ok_status
.status_fail:
    LD      A, 17
    SUB     B
    LD      B, A
    LD      A, 0xAD
    JP      test_fail
.ok_status:

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0xAD
    JP      test_fail
.ok_mode:

    JP      test_pass

.payload:
    DEFB    "foo bar baz"
.pattern:
    DEFB    "xyz"
.expected_status:
    DEFB    "pattern not found"

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
