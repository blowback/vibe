; ============================================================
; Module: test/cases/undo_insert-after-backspace-net-zero.asm
; Purpose: Story 2.13 Q2 Option A (vi-divergence) — a net-zero
;          INSERT session clears the undo entry (UNDO_KIND_EMPTY)
;          instead of recording an empty INSERT. Pre-load "abc"
;          (3 B), cursor=3 (at EOF), mode=NORMAL, undo_kind=EMPTY.
;          CALL enter_insert_mode (saves entry_cursor=3; mode→INSERT).
;          CALL edits_insert_literal A='X' (buffer="abcX"; cursor=4).
;          CALL edits_insert_backspace (buffer="abc"; cursor=3 — net
;          delta=0). CALL enter_normal_mode (Esc → exit hook fires).
;          Assert: undo_kind=UNDO_KIND_EMPTY (no replay recorded).
;          CALL op_undo. Assert: buffer="abc" unchanged;
;          status_buffer prefix = "nothing to undo" (15 chars).
;
; Pins:    Q2 Option A — net-zero/net-deleted INSERT session clears
;          undo to EMPTY (documented vi-divergence).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xC9 — state mismatch
;       sub-codes (B): 0=post-Esc undo_kind not EMPTY,
;                      1=post-u buffer mismatch (B = index),
;                      2=post-u status_buffer mismatch (B = index)
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
    LD      (undo_kind), A              ; UNDO_KIND_EMPTY

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 3                       ; cursor at EOF
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; Enter INSERT (saves insert_session_entry_cursor=3; mode=INSERT).
    CALL    enter_insert_mode

    ;; Type 'X' (buffer="abcX"; cursor=4).
    LD      A, 'X'
    CALL    edits_insert_literal

    ;; Backspace (buffer="abc"; cursor=3 — net delta=0).
    CALL    edits_insert_backspace

    ;; Esc → exit hook (mode_byte still MODE_INSERT; net delta=0).
    CALL    enter_normal_mode

    ;; --- Post-Esc assertion: undo_kind cleared to EMPTY. ---
    LD      A, (undo_kind)
    OR      A                           ; UNDO_KIND_EMPTY = 0
    JR      Z, .ok_post_esc_kind
    LD      B, 0
    LD      A, 0xC9
    JP      test_fail
.ok_post_esc_kind:

    ;; --- op_undo on EMPTY: no replay; status = "nothing to undo". ---
    CALL    op_undo

    ;; Buffer still = "abc".
    LD      HL, 0
    LD      DE, .payload
    LD      B, 3
.bcmp:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .bcmp_next
    LD      A, 3
    SUB     B
    LD      B, A
    LD      A, 0xC9
    JP      test_fail
.bcmp_next:
    INC     HL
    INC     DE
    DJNZ    .bcmp

    ;; status_buffer prefix == "nothing to undo" (15 bytes).
    LD      HL, status_buffer
    LD      DE, .expected_msg
    LD      B, 15
.msg_loop:
    LD      A, (DE)
    LD      C, A
    LD      A, (HL)
    CP      C
    JR      Z, .msg_next
    LD      A, 15
    SUB     B
    LD      B, A
    LD      A, 0xC9
    JP      test_fail
.msg_next:
    INC     HL
    INC     DE
    DJNZ    .msg_loop

    JP      test_pass

.payload:
    DEFB    "abc"
.expected_msg:
    DEFB    "nothing to undo"

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
