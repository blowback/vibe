; ============================================================
; Module: test/cases/search_forward-empty-pattern-reuses.asm
; Purpose: AC7 canonical-3 — bare-Enter on `/` reuses the prior
;          search_pattern. Buffer "main aa main" (12 B), cursor=0.
;          Pre-seed search_pattern = "main" (length 4). ex_buffer
;          empty. command_submode = CMD_SUB_SEARCH. CALL
;          search_commit. AC4 reuse arm runs: walks from cursor+1=1
;          looking for "main"; finds the second "main" at offset 8.
;          Expect cursor=8, search_pattern unchanged ("main"),
;          status cleared (msg_mode_normal pad).
;
; Sentinel 0xA2 at 0xCFFE; context byte:
;   0 — cursor_offset != 8
;   1 — search_pattern length or content mismatch
;   2 — status_buffer[0] != ' '
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
    LD      BC, 12
    LDIR
    LD      HL, GAP_BUFFER_BASE + 12
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    ;; Pre-seed search_pattern = "main" (the prior commit).
    LD      A, 4
    LD      (search_pattern), A
    LD      HL, .prior
    LD      DE, search_pattern_text
    LD      BC, 4
    LDIR

    ;; ex_buffer is empty (bare Enter).
    XOR     A
    LD      (ex_buffer), A

    LD      A, CMD_SUB_SEARCH
    LD      (command_submode), A
    LD      A, MODE_COMMAND
    LD      (mode_byte), A

    CALL    search_commit

    LD      HL, (cursor_offset)
    LD      DE, 8
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xA2
    JP      test_fail
.ok_cursor:

    LD      A, (search_pattern)
    CP      4
    JR      NZ, .pattern_fail
    LD      HL, search_pattern_text
    LD      DE, .prior
    LD      B, 4
.cmp_pattern:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .pattern_fail
    INC     HL
    INC     DE
    DJNZ    .cmp_pattern
    JR      .ok_pattern
.pattern_fail:
    LD      B, 1
    LD      A, 0xA2
    JP      test_fail
.ok_pattern:

    LD      A, (status_buffer)
    CP      ' '
    JR      Z, .ok_status
    LD      B, A
    LD      A, 0xA2
    JP      test_fail
.ok_status:

    JP      test_pass

.payload:
    DEFB    "main aa main"
.prior:
    DEFB    "main"

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
