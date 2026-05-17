; ============================================================
; Module: test/cases/edits_dd-yank-too-large-multi-line.asm
; Purpose: AC2 / AC11 — yank-too-large refusal with non-trivial
;          post-delete cursor placement. The existing edits_dd-
;          yank-too-large.asm exercises the single-line case
;          where post-delete buffer is empty (cursor=0 trivially).
;          This test pins the multi-line variant: refusal arm
;          PUSH/POP HL/BC bracketing around status_set_message
;          (edits.asm:1003-1009) is materially exercised because
;          HL/BC need to survive for the subsequent edits_range_
;          delete call AND the post-delete cursor placement
;          probe.
;
;          Fixture: 1024 'X' bytes + LF + "Y" = 1026 B (two lines:
;          line 1 "X"*1024 with trailing LF; line 2 "Y" no LF).
;          cursor=0; count=0 (defaults to 1).
;
;          Algorithmic trace:
;            S=0. motion_find_line_end(0) finds LF at 1024 with
;            CF=0. DEC BC=0 → .normal_done. delete_end=1025;
;            total_bytes=1025. Range = [0, 1025) = "X"*1024 + LF.
;          edits_copy_to_yank: 1025 > 1024 → CF=1 (REFUSED).
;            yank_kind / yank_length / yank_buffer UNCHANGED.
;          op_dd refused arm: PUSH HL / PUSH BC; status_set_message
;            (msg_yank_too_large); POP BC / POP HL. HL=0=delete_
;            start, BC=1025=total_bytes restored.
;          edits_range_delete: cursor pre-stage 1025 → loop 1025x
;            → cursor=0. file_length now 1 ("Y").
;          Post-delete probe: motion_byte_at_logical(0) = 'Y'
;            with CF=0 → JR NC, .post_commit → CASE 2 (cursor
;            stays at delete_start=0).
;          edits_dirty_and_redraw → buffer_dirty=1. parser_clear.
;
;          Assert: buffer = "Y" (1 B); cursor=0; buffer_dirty=1;
;          yank_kind=0xEE (UNCHANGED from pre-seed); yank_length
;          =0xCAFE (UNCHANGED); status="yank too large"; status_
;          dirty=1.
;
; AC reference: AC2 over-capacity refusal "deletion still proceeds";
;          AC11 msg_yank_too_large surface; case-2 post-delete
;          cursor placement composed with refusal arm.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — buffer != "Y" at offset 0
;   0x81 — buffer_dirty != 1
;   0x82 — yank_kind != 0xEE (was modified — must stay pre-seed)
;   0x83 — yank_length != 0xCAFE (modified — must stay pre-seed)
;   0x84 — cursor != 0 (case 2 placement)
;   0x85 — status_dirty != 1
;   0x86 — status_buffer prefix != "yank too large" (B = idx)
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

    ;; Pre-load 1024 'X' + LF + 'Y' = 1026 B.
    CALL    gapbuf_init
    LD      A, 'X'
    LD      (GAP_BUFFER_BASE), A
    LD      HL, GAP_BUFFER_BASE
    LD      DE, GAP_BUFFER_BASE + 1
    LD      BC, 1023
    LDIR
    LD      A, 0x0A
    LD      (GAP_BUFFER_BASE + 1024), A
    LD      A, 'Y'
    LD      (GAP_BUFFER_BASE + 1025), A
    LD      HL, GAP_BUFFER_BASE + 1026
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    CALL    op_dd

    ;; Buffer byte 0 should be 'Y'; byte 1 should be past-EOF.
    LD      HL, 0
    CALL    motion_byte_at_logical
    JR      C, .buf_fail
    CP      'Y'
    JR      Z, .ok_buf0
.buf_fail:
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.ok_buf0:
    LD      HL, 1
    CALL    motion_byte_at_logical
    JR      C, .ok_buf_size
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.ok_buf_size:

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

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, L
    LD      A, 0x84
    JP      test_fail
.ok_cursor:

    LD      A, (status_dirty)
    CP      1
    JR      Z, .ok_status
    LD      B, A
    LD      A, 0x85
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
    LD      A, 0x86
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
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
