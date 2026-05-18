; ============================================================
; Module: test/cases/search_n-cursor-on-match.asm
; Purpose: Story 3.2 AC8 additional coverage — BH4 "one byte past
;          current cursor" semantic. Buffer "main\nmain" (9 B;
;          positions 0=m 1=a 2=i 3=n 4=LF 5=m 6=a 7=i 8=n);
;          cursor pre-set to 0 (sitting EXACTLY on the first
;          "main"); search_pattern pre-seeded to "main". CALL
;          search_next.
;          First pass walks [1, 9) — pos 1 starts at 'a' (no
;          match), pos 2 starts at 'i' (no match), pos 3 starts
;          at 'n' (no match), pos 4 starts at LF (no match),
;          pos 5 starts at 'm'... matches "main". cursor = 5.
;          (NOT 0 — proves `n` walks from cursor+1, not cursor.)
;          Expect cursor = 5, status_buffer[0] = ' ' (first-pass
;          match clears status), mode_byte = MODE_NORMAL.
;
; Sentinel 0xAF at 0xCFFE; context byte:
;   0 — cursor_offset != 5
;   1 — status_buffer[0] != ' '
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
    LD      BC, 9
    LDIR
    LD      HL, GAP_BUFFER_BASE + 9
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, 4
    LD      (search_pattern), A
    LD      HL, .pattern
    LD      DE, search_pattern_text
    LD      BC, 4
    LDIR

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    search_next

    LD      HL, (cursor_offset)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xAF
    JP      test_fail
.ok_cursor:

    LD      A, (status_buffer)
    CP      ' '
    JR      Z, .ok_status
    LD      B, A
    LD      A, 0xAF
    JP      test_fail
.ok_status:

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0xAF
    JP      test_fail
.ok_mode:

    JP      test_pass

.payload:
    DEFB    "main"
    DEFB    0x0A
    DEFB    "main"
.pattern:
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
