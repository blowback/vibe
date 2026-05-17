; ============================================================
; Module: test/cases/edits_x-empty-buffer.asm
; Purpose: AC3 empty-buffer corner — `x` on cursor=0 of an empty
;          buffer (file_length=0) is a silent no-op. CALL
;          edits_delete_char. Assert cursor=0, file_length=0,
;          buffer_dirty=0 (NOT touched per AC5).
;
; AC reference: AC3 (empty-buffer no-op).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 0
;   0x81 — file_length != 0 (gap_start != GAP_BUFFER_BASE)
;   0x82 — buffer_dirty != 0
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
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A

    CALL    gapbuf_init                  ; empty buffer; gap_start=base, gap_end=base+MAX

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    edits_delete_char

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_cursor:

    ;; file_length == gap_start - GAP_BUFFER_BASE == 0 → gap_start == GAP_BUFFER_BASE.
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_empty
    LD      B, L
    LD      A, 0x81
    JP      test_fail
.ok_empty:

    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_dirty:

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
