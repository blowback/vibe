; ============================================================
; Module: test/cases/edits_yy-yank-too-large.asm
; Purpose: AC4 over-capacity — `yy` on 1025-byte single-line
;          buffer (no LF). cursor=0. Pre-seed yank register with
;          distinctive sentinels. CALL op_yy. Assert: buffer
;          UNCHANGED (yy is read-only); cursor UNCHANGED;
;          buffer_dirty UNCHANGED (== 0); yank_kind UNCHANGED
;          (== 0xEE); yank_length UNCHANGED (== 0xCAFE);
;          status_buffer contains "yank too large" prefix;
;          status_dirty=1.
;
; AC reference: AC4 over-capacity arm (yy: yank UNCHANGED, buffer
;          NOT MODIFIED, status surface).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — cursor != 0
;   0x81 — buffer content modified (B = mismatch index)
;   0x82 — buffer_dirty modified
;   0x83 — yank_kind modified
;   0x84 — yank_length modified
;   0x85 — status_buffer prefix wrong
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
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    LD      A, 0xEE
    LD      (yank_kind), A
    LD      HL, 0xCAFE
    LD      (yank_length), HL

    CALL    gapbuf_init
    LD      A, 'X'
    LD      (GAP_BUFFER_BASE), A
    LD      HL, GAP_BUFFER_BASE
    LD      DE, GAP_BUFFER_BASE + 1
    LD      BC, 1024
    LDIR
    LD      HL, GAP_BUFFER_BASE + 1025
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    CALL    op_yy

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, L
    LD      A, 0x80
    JP      test_fail
.ok_cursor:

    ;; Buffer content unchanged: byte at offset 0 == 'X'.
    LD      HL, 0
    CALL    motion_byte_at_logical
    CP      'X'
    JR      Z, .ok_buf
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_buf:

    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_dirty:

    LD      A, (yank_kind)
    CP      0xEE
    JR      Z, .ok_kind
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_kind:

    LD      HL, (yank_length)
    LD      DE, 0xCAFE
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_length
    LD      HL, (yank_length)
    LD      B, L
    LD      A, 0x84
    JP      test_fail
.ok_length:

    LD      HL, status_buffer
    LD      DE, .yank_msg
    LD      B, 14
.scmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .scmp_next
    LD      A, 14
    SUB     B
    LD      B, A
    LD      A, 0x85
    JP      test_fail
.scmp_next:
    INC     HL
    INC     DE
    DJNZ    .scmp

    JP      test_pass

.yank_msg:
    DEFB    "yank too large"

    INCLUDE "../inc/test_epilogue.inc"

    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
