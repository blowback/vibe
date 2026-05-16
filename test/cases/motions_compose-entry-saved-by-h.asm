; ============================================================
; Module: test/cases/motions_compose-entry-saved-by-h.asm
; Purpose: Pin AC1's unconditional-prologue invariant — every motion
;          handler writes motions_compose_entry on entry, even for the
;          bare-motion path (pending_operator=0).
;
; Pre-seed motions_compose_entry=0xFFFF (sentinel). "abc", cursor=2,
; pending_operator=0 (bare motion). CALL motion_h. The prologue must
; have written cursor_offset (= 2) into motions_compose_entry BEFORE
; the body moved cursor.
;
; Assert: motions_compose_entry == 2 (prologue wrote it); cursor == 1
;         (motion_h stepped left once); pending_operator still 0
;         (bare motion → edits_compose_or_clear fell through to
;         parser_clear).
;
; Sentinel codes:
;   0x80 — motions_compose_entry != 2 (prologue did not write it)
;   0x81 — cursor != 1
;   0x82 — pending_operator != 0 (bare motion leaked state)
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
    LD      (pending_motion_inclusive), A
    LD      (buffer_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 0xFFFF
    LD      (motions_compose_entry), HL  ; sentinel

    LD      HL, 2
    LD      (cursor_offset), HL

    CALL    motion_h

    LD      HL, (motions_compose_entry)
    LD      DE, 2
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_entry
    LD      HL, (motions_compose_entry)
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_entry:

    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0x81
    JP      test_fail
.ok_cursor:

    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok_op
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_op:

    JP      test_pass

.payload:
    DEFB    "abc"

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

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
