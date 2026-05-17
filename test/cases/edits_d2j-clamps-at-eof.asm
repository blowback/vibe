; ============================================================
; Module: test/cases/edits_d2j-clamps-at-eof.asm
; Purpose: `d2j` on "abc\ndef" (7 B), cursor=1 (mid line 1),
;          count_accumulator=2, pending_operator='d'. CALL motion_j.
;          Exercises BH2 clamp in motion_j (line 2 past-EOF on iter 2,
;          clamp keeps cursor at line 1's column 1 = offset 5).
;
; motion_j step 1: line_end(1)=3 (LF). next_line_start=4. next_eol=7
; (file_length, no LF). next_line_length=3. clamp_col=2. col=1.
; new_col=1. cursor=5. Step 2: line_end(5)=7 (past EOF) → done.
; Cursor lands at 5.
;
; compose entry=1. landing=5. forward. range [1, 5) = "bc\nd" (4 B).
;
; Assert: buffer="aef" (3 B); cursor=1; yank_length=4; yank "bc\nd";
;         buffer_dirty=1.
;
; Sentinel codes:
;   0x80 — cursor != 1
;   0x81 — buffer mismatch
;   0x82 — buffer_dirty != 1
;   0x83 — yank_length != 4
;   0x84 — yank_buffer mismatch
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (status_dirty), A
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A
    LD      (buffer_dirty), A
    LD      A, 'd'
    LD      (pending_operator), A
    LD      HL, 2
    LD      (count_accumulator), HL
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 7
    LDIR
    LD      HL, GAP_BUFFER_BASE + 7
    LD      (gap_start), HL

    LD      HL, 1
    LD      (cursor_offset), HL

    CALL    motion_j

    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
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
    LD      B, 3
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
    LD      A, 3
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

    LD      HL, (yank_length)
    LD      DE, 4
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_length
    LD      HL, (yank_length)
    LD      B, L
    LD      A, 0x83
    JP      test_fail
.ok_length:

    LD      HL, yank_buffer
    LD      DE, .yank_expected
    LD      B, 4
.ycmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ycmp_next
    LD      A, 4
    SUB     B
    LD      B, A
    LD      A, 0x84
    JP      test_fail
.ycmp_next:
    INC     HL
    INC     DE
    DJNZ    .ycmp

    JP      test_pass

.payload:
    DEFB    "abc", 0x0A, "def"
.expected:
    DEFB    "aef"
.yank_expected:
    DEFB    "bc", 0x0A, "d"

    INCLUDE "../inc/test_epilogue.inc"

    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
