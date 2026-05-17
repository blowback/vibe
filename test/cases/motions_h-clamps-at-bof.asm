; ============================================================
; Module: test/cases/motions_h-clamps-at-bof.asm
; Purpose: AC11 — verify motion_h at cursor 0 is a silent no-op
;          (BOF clamp per BH2).
;
; AC reference: AC11 (Story 2.5 Sub 7.2).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 0
;   0x81 — count_accumulator not cleared
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    ;; Gap: "abc", cursor = 0.
    CALL    gapbuf_init
    LD      HL, GAP_BUFFER_BASE
    LD      (HL), 'a'
    INC     HL
    LD      (HL), 'b'
    INC     HL
    LD      (HL), 'c'
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL
    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, 'h'
    CALL    motion_h

    ;; cursor_offset must still be 0.
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, (cursor_offset)
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.ok_cursor:

    ;; count_accumulator cleared (even on a no-op step).
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x81
    JP      test_fail
.ok_count:

    JP      test_pass

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
