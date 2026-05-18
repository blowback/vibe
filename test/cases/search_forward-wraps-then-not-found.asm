; ============================================================
; Module: test/cases/search_forward-wraps-then-not-found.asm
; Purpose: AC7 additional — neither pass finds the pattern. Buffer
;          "abcdef" (6 B), cursor=0. Type "xyz" into ex_buffer.
;          CALL search_commit. First pass [1, 6): no match. Wrap
;          pass [0, 1): no match. Expect cursor unchanged (0),
;          status_buffer starts with "pattern not found",
;          search_pattern STILL committed to "xyz" (Q5 pin —
;          failed-search Enter commits the typed pattern; matches
;          vi: the persistent slot reflects the LAST INTENT, not
;          the last successful match).
;
; Sentinel 0xA4 at 0xCFFE; context byte:
;   0 — cursor_offset != 0 (cursor moved on a no-match)
;   1 — status_buffer != "pattern not found..." (B = mismatch index)
;   2 — search_pattern not committed to "xyz" (Q5 violation)
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
    LD      BC, 6
    LDIR
    LD      HL, GAP_BUFFER_BASE + 6
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, 3
    LD      (ex_buffer), A
    LD      HL, .typed
    LD      DE, ex_buffer_text
    LD      BC, 3
    LDIR

    LD      A, CMD_SUB_SEARCH
    LD      (command_submode), A
    LD      A, MODE_COMMAND
    LD      (mode_byte), A

    CALL    search_commit

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xA4
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
    LD      A, 0xA4
    JP      test_fail
.ok_status:

    LD      A, (search_pattern)
    CP      3
    JR      NZ, .commit_fail
    LD      HL, search_pattern_text
    LD      DE, .typed
    LD      B, 3
.cmp_pattern:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .commit_fail
    INC     HL
    INC     DE
    DJNZ    .cmp_pattern
    JR      .ok_pattern
.commit_fail:
    LD      B, 2
    LD      A, 0xA4
    JP      test_fail
.ok_pattern:

    JP      test_pass

.payload:
    DEFB    "abcdef"
.typed:
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
