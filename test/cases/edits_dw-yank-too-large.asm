; ============================================================
; Module: test/cases/edits_dw-yank-too-large.asm
; Purpose: `dw` on a 1025-byte single-word buffer (no LF; 1025
;          printable 'X' bytes), cursor=0, pending_operator='d'.
;          CALL motion_w. motion_w from cursor=0 walks the word
;          and lands past-EOF at offset 1025; range=[0, 1025)
;          = 1025 bytes > YANK_BUFFER_SIZE = 1024 → over-capacity.
;          op_compose_d's yank-refused arm surfaces
;          msg_yank_too_large; DELETION STILL PROCEEDS.
;
; Pre-seed yank_kind=0xEE / yank_length=0xCAFE.
;
; Assert: file_length=0 (deletion happened); buffer_dirty=1;
;         yank_kind UNCHANGED (0xEE); yank_length UNCHANGED (0xCAFE);
;         status_dirty=1; status_buffer prefix = "yank too large".
;
; Sentinel codes:
;   0x80 — file_length != 0
;   0x81 — buffer_dirty != 1
;   0x82 — yank_kind != 0xEE (modified — should be preserved)
;   0x83 — yank_length != 0xCAFE (modified)
;   0x84 — status_dirty != 1
;   0x85 — status_buffer prefix mismatch
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (status_dirty), A
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A
    LD      (buffer_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      A, 'd'
    LD      (pending_operator), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    LD      A, 0xEE
    LD      (yank_kind), A
    LD      HL, 0xCAFE
    LD      (yank_length), HL

    ;; Pre-load 1025 'X' bytes (single line, no LF).
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

    CALL    motion_w

    LD      HL, 0
    CALL    motion_byte_at_logical
    JR      C, .ok_empty
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.ok_empty:

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x81
    JP      test_fail
.ok_dirty:

    LD      A, (yank_kind)
    CP      0xEE
    JR      Z, .ok_kind
    LD      B, A
    LD      A, 0x82
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
    LD      A, 0x83
    JP      test_fail
.ok_length:

    LD      A, (status_dirty)
    CP      1
    JR      Z, .ok_status_dirty
    LD      B, A
    LD      A, 0x84
    JP      test_fail
.ok_status_dirty:

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
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
