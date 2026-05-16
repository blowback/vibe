; ============================================================
; Module: test/cases/edits_dd-yank-at-capacity.asm
; Purpose: AC2 / AC11 boundary acceptance — `dd` on a buffer
;          whose line contributes EXACTLY YANK_BUFFER_SIZE
;          (1024) bytes to total_bytes. Pre-load 1023 'X' bytes
;          followed by 1 LF (1024 B total; single LF-terminated
;          line). cursor=0.
;
;          edits_line_range_for_count: S=0, motion_find_line_end
;          (0) walks to LF at 1023 with CF=0. DEC BC=0 → .normal
;          _done. INC HL=1024 = delete_end. total_bytes=1024.
;          Range = [0, 1024).
;
;          edits_copy_to_yank capacity check (edits.asm:872-877):
;            LD HL, 1024; OR A; SBC HL, BC = 0 with CF=0 (BC ==
;            SIZE, not greater) → RET C does NOT fire → ACCEPTED.
;            yank_kind := KIND_LINE, yank_length := 1024, bytes
;            copied to yank_buffer.
;
;          A regression that flipped the check to `>=` (CF=1 if
;          BC >= SIZE) would refuse at 1024 here; the existing
;          edits_dd-yank-too-large.asm test (BC=1025 refusal)
;          would still pass.
;
;          Assert: buffer empty (file_length=0; deletion proceeds);
;          cursor=0; buffer_dirty=1; yank_kind=KIND_LINE;
;          yank_length=1024; status_dirty UNCHANGED at sentinel
;          0x80 (no msg_yank_too_large surfaced — within capacity).
;
; AC reference: AC2 capacity acceptance boundary (BC == 1024
;          accepted; BC == 1025 refused — pinned by
;          edits_dd-yank-too-large.asm).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — buffer not empty
;   0x81 — cursor != 0
;   0x82 — buffer_dirty != 1
;   0x83 — yank_kind != KIND_LINE
;   0x84 — yank_length != 1024
;   0x85 — status_dirty was modified (no overflow surface should fire)
;   0x86 — yank_buffer[0] != 'X' (proxy for "yank populated")
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (buffer_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; Pre-seed status_dirty = 0x80 sentinel; the within-capacity
    ;; path must NOT surface msg_yank_too_large, so this sentinel
    ;; must persist UNCHANGED.
    LD      A, 0x80
    LD      (status_dirty), A

    ;; Pre-load 1023 'X' bytes followed by 1 LF = 1024 B total.
    CALL    gapbuf_init
    LD      A, 'X'
    LD      (GAP_BUFFER_BASE), A
    LD      HL, GAP_BUFFER_BASE
    LD      DE, GAP_BUFFER_BASE + 1
    LD      BC, 1022
    LDIR
    LD      A, 0x0A
    LD      (GAP_BUFFER_BASE + 1023), A
    LD      HL, GAP_BUFFER_BASE + 1024
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    CALL    op_dd

    LD      HL, 0
    CALL    motion_byte_at_logical
    JR      C, .ok_empty
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.ok_empty:

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, L
    LD      A, 0x81
    JP      test_fail
.ok_cursor:

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x82
    JP      test_fail
.ok_dirty:

    LD      A, (yank_kind)
    CP      KIND_LINE
    JR      Z, .ok_kind
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_kind:

    LD      HL, (yank_length)
    LD      DE, 1024
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

    ;; status_dirty must still be 0x80 (within-capacity, silent).
    LD      A, (status_dirty)
    CP      0x80
    JR      Z, .ok_status
    LD      B, A
    LD      A, 0x85
    JP      test_fail
.ok_status:

    ;; yank_buffer[0] proxy — confirms a copy actually happened.
    LD      A, (yank_buffer)
    CP      'X'
    JR      Z, .ok_yank0
    LD      B, A
    LD      A, 0x86
    JP      test_fail
.ok_yank0:

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

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
