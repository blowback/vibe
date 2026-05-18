; ============================================================
; Module: test/cases/edits_dd-yank-too-large.asm
; Purpose: AC2 over-capacity — `dd` on a 1025-byte single-line
;          buffer (no LF; 1025 printable bytes). cursor=0. Pre-seed
;          yank_kind=0xEE / yank_length=0xCAFE so any accidental
;          write surfaces. CALL op_dd. Assert: buffer shrunk to
;          empty (file_length=0); buffer_dirty=1 (deletion still
;          proceeds); yank_kind / yank_length UNCHANGED from
;          pre-seed (yank register preserved per SR6); status_buffer
;          contains "yank too large" prefix; status_dirty=1.
;
; AC reference: AC2 (over-capacity arm "deletion still proceeds";
;          yank register UNCHANGED); AC11 (msg_yank_too_large);
;          AC12 canonical-4 (epic spec line 1335).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — file_length != 0 post-dd (deletion did NOT proceed)
;   0x81 — buffer_dirty != 1
;   0x82 — yank_kind != 0xEE (it was modified — must stay pre-seed)
;   0x83 — yank_length != 0xCAFE (modified — must stay pre-seed)
;   0x84 — status_dirty != 1
;   0x85 — status_buffer prefix != "yank too large" (B = mismatch idx)
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

    ;; Pre-seed yank register with distinctive non-KIND_LINE non-zero
    ;; sentinels so any accidental write surfaces.
    LD      A, 0xEE
    LD      (yank_kind), A
    LD      HL, 0xCAFE
    LD      (yank_length), HL

    ;; Pre-load 1025 'X' bytes (single line, no trailing LF — file_length
    ;; > YANK_BUFFER_SIZE = 1024). Use a small payload + LDIR-propagate.
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

    CALL    op_dd

    ;; file_length = (gap_start - GAP_BUFFER_BASE) +
    ;;               (GAP_BUFFER_BASE + GAP_BUFFER_MAX - gap_end).
    ;; Simplest: walk first byte — past-EOF means file_length=0.
    LD      HL, 0
    CALL    motion_byte_at_logical
    JR      C, .ok_fileempty
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.ok_fileempty:

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
    JR      Z, .ok_status
    LD      B, A
    LD      A, 0x84
    JP      test_fail
.ok_status:

    ;; Status buffer prefix = "yank too large" (14 bytes).
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
