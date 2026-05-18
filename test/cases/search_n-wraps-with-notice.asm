; ============================================================
; Module: test/cases/search_n-wraps-with-notice.asm
; Purpose: Story 3.2 AC8 canonical-2 — `n` first-pass misses then
;          wrap finds. Buffer "main\nfoo\nbar" (12 B; positions
;          0=m 1=a 2=i 3=n 4=LF 5=f 6=o 7=o 8=LF 9=b 10=a 11=r);
;          cursor pre-set to 5 (the 'f' in "foo"); search_pattern
;          pre-seeded to "main". CALL search_next.
;          First pass walks [6, 12) — no "main" match; CF=1.
;          Wrap pass walks [0, 6) — finds "main" at offset 0.
;          Expect cursor = 0, status_buffer starts with
;          "search wrapped" (14 chars), mode_byte = MODE_NORMAL.
;
; Sentinel 0xAC at 0xCFFE; context byte:
;   0 — cursor_offset != 0
;   1 — status_buffer != "search wrapped..." (B = mismatch index)
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
    LD      BC, 12
    LDIR
    LD      HL, GAP_BUFFER_BASE + 12
    LD      (gap_start), HL

    LD      HL, 5
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
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xAC
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
    LD      A, 0xAC
    JP      test_fail
.ok_status:

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0xAC
    JP      test_fail
.ok_mode:

    JP      test_pass

.payload:
    DEFB    "main"
    DEFB    0x0A
    DEFB    "foo"
    DEFB    0x0A
    DEFB    "bar"
.pattern:
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
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
