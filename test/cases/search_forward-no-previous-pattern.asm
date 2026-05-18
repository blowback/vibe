; ============================================================
; Module: test/cases/search_forward-no-previous-pattern.asm
; Purpose: AC7 additional — cold-start `/<Enter>` with no prior
;          search_pattern surfaces msg_no_previous_pattern. Buffer
;          "abc" (3 B), cursor=0. search_pattern[0] = 0 explicitly
;          (cold-start LDIR zero-fill simulator). ex_buffer empty.
;          CALL search_commit. AC4's no-prior-pattern arm runs:
;          status = "no previous pattern"; cursor unchanged; mode
;          → NORMAL via exline_cancel_core.
;
; Sentinel 0xA6 at 0xCFFE; context byte:
;   0 — cursor_offset != 0
;   1 — status_buffer != "no previous pattern..." (B = mismatch idx)
;   2 — mode_byte != MODE_NORMAL
;   3 — command_submode != CMD_SUB_EX
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
    LD      (search_pattern), A         ; explicit cold-start: no prior pattern
    LD      (ex_buffer), A              ; bare Enter

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

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
    LD      A, 0xA6
    JP      test_fail
.ok_cursor:

    LD      HL, status_buffer
    LD      DE, .expected_status
    LD      B, 19
.cmp_status:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .status_fail
    INC     HL
    INC     DE
    DJNZ    .cmp_status
    JR      .ok_status
.status_fail:
    LD      A, 19
    SUB     B
    LD      B, A
    LD      A, 0xA6
    JP      test_fail
.ok_status:

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, 2
    LD      A, 0xA6
    JP      test_fail
.ok_mode:

    LD      A, (command_submode)
    OR      A
    JR      Z, .ok_submode
    LD      B, 3
    LD      A, 0xA6
    JP      test_fail
.ok_submode:

    JP      test_pass

.payload:
    DEFB    "abc"
.expected_status:
    DEFB    "no previous pattern"

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
