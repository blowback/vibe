; ============================================================
; Module: test/cases/edits_O-on-empty-buffer.asm
; Purpose: AC4 empty-file corner — `O` on an empty buffer inserts
;          an LF at offset 0; cursor stays at 0 (post-DEC).
;          Pre-state: gapbuf_init (file_length=0, cursor=0).
;          CALL edits_open_above. Trace:
;          motion_find_line_start(0) → HL=0 (immediate RET);
;          insert LF at 0 → buffer "\n" (1 B), cursor → 1; DEC →
;          cursor=0. Mode → INSERT.
;
; AC reference: AC4 (O on empty file).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor_offset != 0 post-handler
;   0x81 — byte at offset 0 != 0x0A
;   0x82 — file_length != 1
;   0x83 — mode_byte != MODE_INSERT (fall-through to enter_insert_mode broken)
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
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (buffer_dirty), A

    CALL    gapbuf_init                  ; file_length=0, cursor=0

    LD      A, 'O'
    CALL    edits_open_above

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
    CALL    motion_byte_at_logical
    JR      C, .fail_byte
    CP      0x0A
    JR      Z, .ok_byte
.fail_byte:
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_byte:

    ;; file_length = gap_start + GAP_BUFFER_MAX - gap_end
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_MAX
    ADD     HL, DE
    LD      DE, (gap_end)
    OR      A
    SBC     HL, DE                       ; HL = file_length
    LD      DE, 1
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_len
    LD      HL, (gap_start)
    LD      B, L
    LD      A, 0x82
    JP      test_fail
.ok_len:

    LD      A, (mode_byte)
    CP      MODE_INSERT
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_mode:

    JP      test_pass

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
