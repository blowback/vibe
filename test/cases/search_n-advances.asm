; ============================================================
; Module: test/cases/search_n-advances.asm
; Purpose: Story 3.2 AC8 canonical-1 — happy-path n advance from
;          NORMAL mode. Buffer "main\nfoo\nmain\n" (14 B); cursor
;          pre-set to 0 (start of first "main"); search_pattern
;          pre-seeded to "main" (len 4). CALL search_next.
;          Expect cursor = 9 (start of second "main"; positions:
;          0=m 1=a 2=i 3=n 4=LF 5=f 6=o 7=o 8=LF 9=m 10=a 11=i
;          12=n 13=LF), status_buffer[0] = ' ' (msg_mode_normal
;          pad — first-pass match clears status), mode_byte =
;          MODE_NORMAL (unchanged across `n`).
;
; Sentinel 0xAB at 0xCFFE; context byte:
;   0 — cursor_offset != 9
;   1 — status_buffer[0] != ' '
;   2 — mode_byte != MODE_NORMAL
;   3 — search_pattern length corrupted (must remain 4)
;   4 — count_accumulator not zeroed by parser_clear (AC6)
;   5 — pending_operator not zeroed by parser_clear (AC6)
;   6 — pending_motion_prefix not zeroed by parser_clear (AC6)
;   7 — pending_motion_inclusive not zeroed by parser_clear (AC6)
;   8 — command_submode mutated (AC2 — search_next is a pure reader)
;
; Patches 2 + 3 from code review of Story 3.2 (2026-05-18):
;   - Pre-seeds parser state (count=5, op='d', prefix='g', inclusive=1)
;     to verify the JP parser_clear tail-JP at search_next's exit
;     actually fires; previously no test exercised this AC6 promise.
;   - Pre-seeds command_submode to sentinel byte 0xCC to verify
;     search_next does NOT write it (copy-paste hazard vs
;     search_commit which DOES end at exline_cancel_core).
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
    LD      (ex_buffer), A

    ;; AC6 — pre-seed parser state with non-zero values so the
    ;;       JP parser_clear tail-JP at search_next's exit has
    ;;       observable work to do.
    LD      HL, 5
    LD      (count_accumulator), HL
    LD      A, 'd'
    LD      (pending_operator), A
    LD      A, 'g'
    LD      (pending_motion_prefix), A
    LD      A, 1
    LD      (pending_motion_inclusive), A

    ;; AC2 — pre-seed command_submode with sentinel byte 0xCC so a
    ;;       stray write inside search_next (or its callees) is
    ;;       detectable. search_next is a pure reader of
    ;;       search_pattern; it must not touch command_submode.
    LD      A, 0xCC
    LD      (command_submode), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 14
    LDIR
    LD      HL, GAP_BUFFER_BASE + 14
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
    LD      DE, 9
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xAB
    JP      test_fail
.ok_cursor:

    LD      A, (status_buffer)
    CP      ' '
    JR      Z, .ok_status
    LD      B, A
    LD      A, 0xAB
    JP      test_fail
.ok_status:

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0xAB
    JP      test_fail
.ok_mode:

    LD      A, (search_pattern)
    CP      4
    JR      Z, .ok_pattern
    LD      B, A
    LD      A, 0xAB
    JP      test_fail
.ok_pattern:

    ;; AC6 — count_accumulator must be zeroed by parser_clear.
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0xAB
    JP      test_fail
.ok_count:

    ;; AC6 — pending_operator must be zeroed by parser_clear.
    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok_pending_op
    LD      B, A
    LD      A, 0xAB
    JP      test_fail
.ok_pending_op:

    ;; AC6 — pending_motion_prefix must be zeroed by parser_clear.
    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok_motion_prefix
    LD      B, A
    LD      A, 0xAB
    JP      test_fail
.ok_motion_prefix:

    ;; AC6 — pending_motion_inclusive must be zeroed by parser_clear.
    LD      A, (pending_motion_inclusive)
    OR      A
    JR      Z, .ok_motion_inclusive
    LD      B, A
    LD      A, 0xAB
    JP      test_fail
.ok_motion_inclusive:

    ;; AC2 — command_submode must remain at the sentinel byte.
    LD      A, (command_submode)
    CP      0xCC
    JR      Z, .ok_submode
    LD      B, A
    LD      A, 0xAB
    JP      test_fail
.ok_submode:

    JP      test_pass

.payload:
    DEFB    "main"
    DEFB    0x0A
    DEFB    "foo"
    DEFB    0x0A
    DEFB    "main"
    DEFB    0x0A
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
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
