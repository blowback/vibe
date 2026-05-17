; ============================================================
; Module: test/cases/edits_buffer-dirty-set-on-first-insert.asm
; Purpose: AC9 — buffer_dirty becomes 1 on the first successful
;          insert. Pre-state: empty buffer, cursor=0, mode=INSERT,
;          buffer_dirty=0 (the post-:e or post-launch clean state).
;          CALL edits_insert_literal with A='A'. Assert
;          buffer_dirty=1.
;
; AC reference: AC9 (buffer_dirty set on first insert).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — buffer_dirty != 1 post-insert
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
    LD      (buffer_dirty), A            ; explicitly clean

    CALL    gapbuf_init

    LD      A, MODE_INSERT
    LD      (mode_byte), A

    LD      A, 'A'
    CALL    edits_insert_literal

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.ok:

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
