; ============================================================
; Module: test/cases/edits_5x-clamps-at-eol.asm
; Purpose: AC4 BH2 stop-at-LF — `5x` from cursor=0 on
;          "abc\ndef" (7 B) deletes 'a','b','c' then BREAKs on
;          LF at iter 4. Post-clamp: cursor=0 on LF (cursor==0
;          guard skips dec). Buffer becomes "\ndef" (4 B).
;
;          The remaining 2 counts of N=5 are silently absorbed
;          per BH2 (counted operations clamp at boundary).
;
;          Documented invariant violation: cursor on LF after
;          this operation. Story 2.9 spec accepts this as
;          vi-faithful "x doesn't join lines"; the next motion
;          (h/j/k/l) re-establishes the cursor-not-on-LF
;          invariant.
;
; AC reference: AC4 BH2 stop-at-boundary.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 0
;   0x81 — buffer content != "\ndef" (B = mismatch index)
;   0x82 — buffer_dirty != 1
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (status_dirty), A
    LD      (buffer_dirty), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 7
    LDIR
    LD      HL, GAP_BUFFER_BASE + 7
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      HL, 5
    LD      (count_accumulator), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    LD      HL, edits_delete_char
    CALL    parser_dispatch

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_cursor:

    LD      HL, 0
    LD      DE, .expected
    LD      B, 4
.cmp_loop:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .cmp_next
    LD      A, 4
    SUB     B
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_dirty:

    JP      test_pass

.payload:
    DEFB    "abc", 0x0A, "def"
.expected:
    DEFB    0x0A, "def"

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
