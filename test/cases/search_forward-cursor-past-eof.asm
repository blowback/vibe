; ============================================================
; Module: test/cases/search_forward-cursor-past-eof.asm
; Purpose: AC7 additional — cursor at file_length (the past-EOF
;          sentinel from `$a<Esc>` etc.). Buffer "main" (4 B),
;          file_length = 4, cursor = 4. /main<Enter> first pass:
;          start_1 = 5, upper_bound = 4 → bounds trip immediately
;          (5 >= 4). Wrap pass: bound = 5 (original_cursor + 1 =
;          4 + 1 per Q4 pin), start = 0 → finds "main" at offset 0.
;          Expect cursor = 0, status_buffer starts with
;          "search wrapped".
;
; Sentinel 0xA8 at 0xCFFE; context byte:
;   0 — cursor_offset != 0
;   1 — status_buffer != "search wrapped..." (B = mismatch idx)
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
    LD      BC, 4
    LDIR
    LD      HL, GAP_BUFFER_BASE + 4
    LD      (gap_start), HL

    LD      HL, 4                       ; past-EOF sentinel
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
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xA8
    JP      test_fail
.ok_cursor:

    LD      HL, status_buffer
    LD      DE, .expected_status
    LD      B, 14
.cmp_status:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .status_fail
    INC     HL
    INC     DE
    DJNZ    .cmp_status
    JR      .ok_status
.status_fail:
    LD      A, 14
    SUB     B
    LD      B, A
    LD      A, 0xA8
    JP      test_fail
.ok_status:

    JP      test_pass

.payload:
    DEFB    "main"
.typed:
    DEFB    "main"
.expected_status:
    DEFB    "search wrapped"

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
