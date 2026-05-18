; ============================================================
; Module: test/cases/search_forward-esc-preserves-pattern.asm
; Purpose: AC7 additional — Esc during /-edit must NOT clobber the
;          persistent search_pattern (AC2 contract). Pre-set
;          search_pattern = "foo" (length 3, the persistent slot
;          from a hypothetical prior commit). Press `/`, type "bar"
;          into ex_buffer mid-edit, then press Esc. Verify
;          search_pattern STILL = "foo" (the persistent slot is
;          UNTOUCHED); ex_buffer cleared; mode → NORMAL;
;          command_submode → CMD_SUB_EX.
;
; Sentinel 0xA7 at 0xCFFE; context byte:
;   0 — search_pattern length / content no longer "foo"
;   1 — ex_buffer not cleared
;   2 — mode_byte != MODE_NORMAL
;   3 — command_submode != CMD_SUB_EX
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

    CALL    gapbuf_init                 ; just to anchor state; buffer empty is fine

    ;; --- Pre-seed search_pattern = "foo" (the prior commit). ---
    LD      A, 3
    LD      (search_pattern), A
    LD      HL, .prior
    LD      DE, search_pattern_text
    LD      BC, 3
    LDIR

    ;; --- Type "bar" into ex_buffer (mid-/-edit state). ---
    LD      A, 3
    LD      (ex_buffer), A
    LD      HL, .typed
    LD      DE, ex_buffer_text
    LD      BC, 3
    LDIR

    LD      A, CMD_SUB_SEARCH
    LD      (command_submode), A
    LD      A, MODE_COMMAND
    LD      (mode_byte), A

    ;; --- Esc → exline_cancel ---
    LD      A, 0x1B
    CALL    exline_cancel

    ;; --- search_pattern STILL = "foo" (3, 'f','o','o') ---
    LD      A, (search_pattern)
    CP      3
    JR      NZ, .pattern_fail
    LD      HL, search_pattern_text
    LD      DE, .prior
    LD      B, 3
.cmp_pattern:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .pattern_fail
    INC     HL
    INC     DE
    DJNZ    .cmp_pattern
    JR      .ok_pattern
.pattern_fail:
    LD      B, 0
    LD      A, 0xA7
    JP      test_fail
.ok_pattern:

    LD      A, (ex_buffer)
    OR      A
    JR      Z, .ok_exclr
    LD      B, 1
    LD      A, 0xA7
    JP      test_fail
.ok_exclr:

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, 2
    LD      A, 0xA7
    JP      test_fail
.ok_mode:

    LD      A, (command_submode)
    OR      A
    JR      Z, .ok_submode
    LD      B, 3
    LD      A, 0xA7
    JP      test_fail
.ok_submode:

    JP      test_pass

.prior:
    DEFB    "foo"
.typed:
    DEFB    "bar"

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
