; ============================================================
; Module: test/cases/parser_n-dispatch.asm
; Purpose: Story 3.2 AC8 parser-dispatch coverage — verify
;          dispatch_normal['n'] routes to search_next (NOT
;          falling through to unbound_normal's msg_unbound_key
;          path). Mirrors the shape of Story 3.1's
;          parser_slash-dispatch.asm.
;
;          Pre-seed: search_pattern = "x" (length 1) + buffer
;          "abcdex" (6 B) so the dispatched call exercises the
;          full search_next path (non-empty pattern → CALL
;          search_run → first-pass match at offset 5). mode_byte
;          = MODE_NORMAL; cursor_offset = 0. Drive 'n' through
;          dispatch_key with HL = dispatch_normal (the unbound
;          prefix base — NOT dispatch_normal + 2; dispatch_key
;          skips the prefix internally) and B = DISPATCH_NORMAL_COUNT.
;
;          Effect: dispatch lands in search_next → search_run →
;          first-pass walk finds 'x' at offset 5. Post-call:
;          cursor_offset = 5 (proves dispatch reached search_next,
;          NOT unbound_normal which would have written
;          msg_unbound_key without moving the cursor), and
;          status_buffer[0] = ' ' (proves the first-pass-match
;          arm cleared status via msg_mode_normal, NOT the
;          "unbound key" banner that would have left a non-space
;          first byte).
;
; Sentinel 0xEA at 0xCFFE; context byte:
;   0 — cursor_offset != 5 (dispatch failed to reach search_next
;       OR search_next failed to walk)
;   1 — status_buffer[0] != ' ' (likely "unbound key" surfaced
;       OR a search-failure banner)
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
    LD      BC, 6
    LDIR
    LD      HL, GAP_BUFFER_BASE + 6
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, 1
    LD      (search_pattern), A
    LD      HL, .pattern
    LD      DE, search_pattern_text
    LD      BC, 1
    LDIR

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; Drive 'n' through the dispatcher (NORMAL-mode table).
    LD      A, 'n'
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key

    LD      HL, (cursor_offset)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xEA
    JP      test_fail
.ok_cursor:

    LD      A, (status_buffer)
    CP      ' '
    JR      Z, .ok_status
    LD      B, A
    LD      A, 0xEA
    JP      test_fail
.ok_status:

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0xEA
    JP      test_fail
.ok_mode:

    JP      test_pass

.payload:
    DEFB    "abcdex"
.pattern:
    DEFB    "x"

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
