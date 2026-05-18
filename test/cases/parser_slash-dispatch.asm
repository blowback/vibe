; ============================================================
; Module: test/cases/parser_slash-dispatch.asm
; Purpose: AC7 parser-dispatch coverage — verify dispatch_normal['/']
;          routes to search_begin (NOT to the retired
;          mode_search_prompt_stub). Drive `/` through dispatch_key
;          with the dispatch_normal table; assert mode_byte =
;          MODE_COMMAND, command_submode = CMD_SUB_SEARCH,
;          ex_buffer[0] = 0, status_buffer starts with '/'.
;
;          This test is the structural pin against a regression
;          that re-wired '/' to the stub or to any other handler:
;          mode_search_prompt_stub's body would surface
;          "not yet implemented" — the status_buffer check catches
;          that.
;
; Sentinel 0xE9 at 0xCFFE; context byte:
;   0 — mode_byte != MODE_COMMAND
;   1 — command_submode != CMD_SUB_SEARCH
;   2 — ex_buffer[0] != 0
;   3 — status_buffer[0] != '/' (regression: stub still bound, or
;       compose_status didn't pick '/' prefix on SEARCH submode)
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
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; Drive '/' through the dispatcher (NORMAL-mode table).
    LD      A, '/'
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key

    LD      A, (mode_byte)
    CP      MODE_COMMAND
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0xE9
    JP      test_fail
.ok_mode:

    LD      A, (command_submode)
    CP      CMD_SUB_SEARCH
    JR      Z, .ok_submode
    LD      B, A
    LD      A, 0xE9
    JP      test_fail
.ok_submode:

    LD      A, (ex_buffer)
    OR      A
    JR      Z, .ok_exclr
    LD      B, A
    LD      A, 0xE9
    JP      test_fail
.ok_exclr:

    LD      A, (status_buffer)
    CP      '/'
    JR      Z, .ok_status
    LD      B, A
    LD      A, 0xE9
    JP      test_fail
.ok_status:

    JP      test_pass

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
