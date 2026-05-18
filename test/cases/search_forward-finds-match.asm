; ============================================================
; Module: test/cases/search_forward-finds-match.asm
; Purpose: AC7 canonical-1 — happy-path forward match. Buffer
;          "abc main xyz" (12 B), cursor=0. Type "main" into
;          ex_buffer; command_submode = CMD_SUB_SEARCH; CALL
;          search_commit. Expect cursor = 4 (offset of 'm' in
;          "main"), search_pattern committed ("main", len 4),
;          mode_byte = MODE_NORMAL post-cleanup, command_submode
;          = CMD_SUB_EX post-cleanup, ex_buffer[0] = 0,
;          status_buffer[0] = ' ' (cleared per AC3).
;
; Sentinel 0xA0 at 0xCFFE; context byte distinguishes failure mode:
;   0 — cursor_offset != 4
;   1 — search_pattern not committed (length / payload mismatch)
;   2 — mode_byte != MODE_NORMAL
;   3 — command_submode != CMD_SUB_EX
;   4 — ex_buffer[0] != 0
;   5 — status_buffer[0] != ' ' (status not cleared)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    ;; --- Zero the state cells we read post-action ---
    XOR     A
    LD      (status_dirty), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (buffer_dirty), A

    ;; --- Seed gap buffer with payload "abc main xyz" ---
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 12
    LDIR
    LD      HL, GAP_BUFFER_BASE + 12
    LD      (gap_start), HL

    ;; --- Cursor at offset 0 ---
    LD      HL, 0
    LD      (cursor_offset), HL

    ;; --- search_pattern zeroed (no prior pattern to reuse path) ---
    XOR     A
    LD      (search_pattern), A

    ;; --- Pre-seed ex_buffer with "main" (the user-typed pattern) ---
    LD      A, 4
    LD      (ex_buffer), A
    LD      HL, .typed
    LD      DE, ex_buffer_text
    LD      BC, 4
    LDIR

    ;; --- Submode + mode set as if /<typed><Enter> arrived ---
    LD      A, CMD_SUB_SEARCH
    LD      (command_submode), A
    LD      A, MODE_COMMAND
    LD      (mode_byte), A

    CALL    search_commit

    ;; --- cursor_offset must be 4 (start of "main") ---
    LD      HL, (cursor_offset)
    LD      DE, 4
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, 0
    LD      A, 0xA0
    JP      test_fail
.ok_cursor:

    ;; --- search_pattern[0] = 4 AND search_pattern_text = "main" ---
    LD      A, (search_pattern)
    CP      4
    JR      NZ, .commit_fail
    LD      HL, search_pattern_text
    LD      DE, .typed
    LD      B, 4
.cmp_pattern:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .commit_fail
    INC     HL
    INC     DE
    DJNZ    .cmp_pattern
    JR      .ok_pattern
.commit_fail:
    LD      B, 1
    LD      A, 0xA0
    JP      test_fail
.ok_pattern:

    ;; --- mode_byte must be MODE_NORMAL post-cleanup ---
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, 2
    LD      A, 0xA0
    JP      test_fail
.ok_mode:

    ;; --- command_submode must be CMD_SUB_EX (0) post-cleanup ---
    LD      A, (command_submode)
    CP      CMD_SUB_EX
    JR      Z, .ok_submode
    LD      B, 3
    LD      A, 0xA0
    JP      test_fail
.ok_submode:

    ;; --- ex_buffer[0] must be 0 post-cleanup ---
    LD      A, (ex_buffer)
    OR      A
    JR      Z, .ok_exclr
    LD      B, 4
    LD      A, 0xA0
    JP      test_fail
.ok_exclr:

    ;; --- status_buffer[0] must be ' ' (msg_mode_normal pad) ---
    LD      A, (status_buffer)
    CP      ' '
    JR      Z, .ok_status
    LD      B, 5
    LD      A, 0xA0
    JP      test_fail
.ok_status:

    JP      test_pass

.payload:
    DEFB    "abc main xyz"
.typed:
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
