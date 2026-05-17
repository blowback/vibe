; ============================================================
; Module: test/cases/undo_x-restores-byte.asm
; Purpose: AC11 canonical-1 — `x` records DELETE entry; subsequent
;          `u` replays it (re-inserts deleted byte at original
;          position). Pre-load "abc" (3 B), cursor=1 ('b'),
;          buffer_dirty=0, undo_kind=EMPTY. CALL edits_delete_char;
;          assert buffer="ac" + undo_kind=DELETE + payload="b".
;          THEN CALL op_undo; assert buffer="abc" + cursor=1 +
;          buffer_dirty=1 + undo_kind=EMPTY (consumed).
;
; AC reference: AC4 (op_undo); AC6 (cursor placement); AC7 hook 1
;          (edits_delete_char). Canonical journey-2 typo-recovery.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xC0 — post-x state mismatch (B = sub-code: 0=buffer, 1=cursor,
;          2=undo_kind, 3=undo_position, 4=undo_length, 5=payload)
;   0xC1 — post-u state mismatch (B = sub-code: 0=buffer, 1=cursor,
;          2=undo_kind, 3=buffer_dirty)
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
    LD      (undo_kind), A              ; UNDO_KIND_EMPTY

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 1                       ; cursor on 'b'
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    edits_delete_char

    ;; --- Post-x assertions ---
    LD      A, (undo_kind)
    CP      UNDO_KIND_DELETE
    JR      Z, .ok_post_x_kind
    LD      B, 2
    LD      A, 0xC0
    JP      test_fail
.ok_post_x_kind:
    LD      HL, (undo_position)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_post_x_pos
    LD      B, 3
    LD      A, 0xC0
    JP      test_fail
.ok_post_x_pos:
    LD      HL, (undo_length)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_post_x_len
    LD      B, 4
    LD      A, 0xC0
    JP      test_fail
.ok_post_x_len:
    LD      A, (undo_buffer)
    CP      'b'
    JR      Z, .ok_post_x_payload
    LD      B, 5
    LD      A, 0xC0
    JP      test_fail
.ok_post_x_payload:

    ;; Buffer should be "ac" (2 B). Spot-check via motion_byte_at_logical.
    LD      HL, 0
    CALL    motion_byte_at_logical
    CP      'a'
    JR      Z, .ok_post_x_b0
    LD      B, 0
    LD      A, 0xC0
    JP      test_fail
.ok_post_x_b0:
    LD      HL, 1
    CALL    motion_byte_at_logical
    CP      'c'
    JR      Z, .ok_post_x_b1
    LD      B, 0
    LD      A, 0xC0
    JP      test_fail
.ok_post_x_b1:

    ;; --- Now invoke op_undo ---
    CALL    op_undo

    ;; --- Post-u assertions ---
    LD      A, (undo_kind)
    OR      A                           ; UNDO_KIND_EMPTY = 0
    JR      Z, .ok_post_u_kind
    LD      B, 2
    LD      A, 0xC1
    JP      test_fail
.ok_post_u_kind:

    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_post_u_cursor
    LD      B, 1
    LD      A, 0xC1
    JP      test_fail
.ok_post_u_cursor:

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_post_u_dirty
    LD      B, 3
    LD      A, 0xC1
    JP      test_fail
.ok_post_u_dirty:

    ;; Buffer should be back to "abc".
    LD      HL, 0
    LD      DE, .payload
    LD      B, 3
.cmp_loop:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .cmp_next
    LD      B, 0
    LD      A, 0xC1
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    JP      test_pass

.payload:
    DEFB    "abc"

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
