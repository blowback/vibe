; ============================================================
; Module: test/cases/search_n-no-prior-pattern.asm
; Purpose: Story 3.2 AC8 canonical-4 — `n` with no prior pattern
;          (cold-start search_pattern[0] == 0). Buffer "main foo"
;          (8 B); cursor pre-set to 0; search_pattern length byte
;          explicitly zeroed. CALL search_next.
;          search_next reads search_pattern[0] = 0; takes the
;          no-prior arm; skips search_run entirely; surfaces
;          msg_no_previous_pattern; tail-JPs parser_clear.
;          Expect cursor UNCHANGED at 0, status_buffer starts
;          with "no previous pattern" (19 chars), mode_byte =
;          MODE_NORMAL.
;
; Sentinel 0xAE at 0xCFFE; context byte:
;   0 — cursor_offset != 0
;   1 — status_buffer != "no previous pattern..." (B = mismatch idx)
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
    LD      (search_pattern), A         ; cold-start: length = 0

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 8
    LDIR
    LD      HL, GAP_BUFFER_BASE + 8
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    search_next

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xAE
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
    LD      A, 0xAE
    JP      test_fail
.ok_status:

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0xAE
    JP      test_fail
.ok_mode:

    JP      test_pass

.payload:
    DEFB    "main foo"
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
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
