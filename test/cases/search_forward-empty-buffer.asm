; ============================================================
; Module: test/cases/search_forward-empty-buffer.asm
; Purpose: AC7 additional — empty gap buffer (file_length = 0).
;          Cursor=0, ex_buffer = "foo". CALL search_commit. First
;          pass start_1 = 1, upper_bound = 0 → bounds trip
;          immediately. Wrap pass bound = 1, start = 0 → walks
;          [0, 1) but motion_byte_at_logical CF=1 at offset 0
;          (past-EOF) → pos_mismatch → outer advances to pos=1,
;          bounds trip. Expect cursor unchanged (0), status =
;          "pattern not found".
;
; Sentinel 0xA5 at 0xCFFE; context byte:
;   0 — cursor_offset != 0
;   1 — status_buffer != "pattern not found..." (B = mismatch idx)
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

    ;; Empty buffer: gapbuf_init alone leaves file_length = 0.
    CALL    gapbuf_init

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
    LD      A, 0xA5
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
    LD      A, 0xA5
    JP      test_fail
.ok_status:

    JP      test_pass

.typed:
    DEFB    "foo"
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
