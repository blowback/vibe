; ============================================================
; Module: test/cases/search_forward-multiple-matches-finds-first.asm
; Purpose: AC7 additional — first-pass returns FIRST match past
;          cursor+1, not last. Buffer "main\nmain\nmain" (14 B),
;          cursor=0. Type "main"; CALL search_commit. First pass
;          start_1 = 1; positions 1..4 don't match (a,i,n,\n);
;          position 5 matches (the 2nd "main"). Expect cursor = 5,
;          status cleared.
;
; Pin: AC1 cursor+1 start semantics — searching from cursor=0 for
; the SAME pattern that exists at offset 0 (the cursor's current
; position) must advance to the NEXT occurrence, not "find itself".
;
; Sentinel 0xAA at 0xCFFE; context byte:
;   0 — cursor_offset != 5 (wrong match; off-by-one in start_1?)
;   1 — status_buffer[0] != ' ' (status not cleared on first-pass hit)
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
    LD      (search_pattern), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 14
    LDIR
    LD      HL, GAP_BUFFER_BASE + 14
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, 4
    LD      (ex_buffer), A
    LD      HL, .typed
    LD      DE, ex_buffer_text
    LD      BC, 4
    LDIR

    LD      A, CMD_SUB_SEARCH
    LD      (command_submode), A
    LD      A, MODE_COMMAND
    LD      (mode_byte), A

    CALL    search_commit

    LD      HL, (cursor_offset)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xAA
    JP      test_fail
.ok_cursor:

    LD      A, (status_buffer)
    CP      ' '
    JR      Z, .ok_status
    LD      B, 1
    LD      A, 0xAA
    JP      test_fail
.ok_status:

    JP      test_pass

.payload:
    DEFB    "main"
    DEFB    0x0A
    DEFB    "main"
    DEFB    0x0A
    DEFB    "main"
.typed:
    DEFB    "main"

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
