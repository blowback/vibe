; ============================================================
; Module: test/cases/search_forward-pattern-too-long.asm
; Purpose: AC7 canonical-4 — buffer-full silent drop. Type 64 'a's
;          then 1 'b' (65th byte) via exline_append_literal in the
;          search-edit context. Verify ex_buffer[0] caps at 64 and
;          the 65th byte is dropped (no 'b' visible in
;          ex_buffer_text or — after commit — in search_pattern_text).
;          Then CALL search_commit with a buffer containing 64 'a's
;          to demonstrate the 64-byte pattern still walks normally.
;          Expect: ex_buffer length caps at 64 mid-typing;
;          search_pattern length = 64 after commit; cursor found at
;          the wrap match (0).
;
; Sentinel 0xA3 at 0xCFFE; context byte:
;   0 — ex_buffer[0] != 64 after the over-typing burst
;   1 — search_pattern length != 64 after commit
;   2 — search_pattern_text[63] != 'a' (the 'b' leaked in)
;   3 — cursor_offset != 0 (wrap-match expected)
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
    LD      (ex_buffer), A
    LD      (search_pattern), A

    LD      A, CMD_SUB_SEARCH
    LD      (command_submode), A
    LD      A, MODE_COMMAND
    LD      (mode_byte), A

    ;; Seed gap buffer with 64 'a's.
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 64
    LDIR
    LD      HL, GAP_BUFFER_BASE + 64
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    ;; --- Type 64 'a's via exline_append_literal ---
    LD      B, 64
.type_aa:
    LD      A, 'a'
    PUSH    BC
    CALL    exline_append_literal
    POP     BC
    DJNZ    .type_aa

    ;; --- 65th byte: 'b' — must be dropped silently ---
    LD      A, 'b'
    CALL    exline_append_literal

    ;; --- Pre-commit: verify ex_buffer[0] == 64 ---
    LD      A, (ex_buffer)
    CP      64
    JR      Z, .ok_caplen
    LD      B, A
    LD      A, 0xA3
    JP      test_fail
.ok_caplen:

    ;; --- Commit: CALL search_commit ---
    CALL    search_commit

    ;; --- Verify search_pattern length == 64 ---
    LD      A, (search_pattern)
    CP      64
    JR      Z, .ok_plen
    LD      B, A
    LD      A, 0xA3
    JP      test_fail
.ok_plen:

    ;; --- Verify search_pattern_text[63] == 'a' (the 'b' was dropped) ---
    LD      A, (search_pattern_text + 63)
    CP      'a'
    JR      Z, .ok_lastbyte
    LD      B, A
    LD      A, 0xA3
    JP      test_fail
.ok_lastbyte:

    ;; --- Verify cursor wrapped to offset 0 ---
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xA3
    JP      test_fail
.ok_cursor:

    JP      test_pass

.payload:
    DEFS    64, 'a'

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
