; ============================================================
; Module: test/cases/undo_dw-restores-word.asm
; Purpose: AC11 — `dw` records a DELETE entry; subsequent `u`
;          restores the deleted word at the original position.
;          Pre-load "hello world" (11 B), cursor=0. Simulate `dw`
;          by pre-seeding pending_operator='d',
;          motions_compose_entry=0 (compose entry cursor),
;          cursor_offset=6 (landing on 'w' after the w-motion),
;          pending_motion_inclusive=0; CALL op_compose_d.
;          Assert post-dw: buffer="world" (5 B); undo_kind=DELETE;
;          undo_length=6; undo_buffer[0..5]="hello ".
;          THEN CALL op_undo. Assert: buffer="hello world";
;          cursor=0.
;
; Pins:
;   - dw → u (canonical compose-d + u).
;   - compose-d hook site records DELETE BEFORE the yank-copy.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xC6 — post-dw or post-u state mismatch
;       sub-codes (B): 0=buffer (B = index ranged), 1=cursor,
;                      2=undo_kind, 3=undo_position, 4=undo_length,
;                      5=undo_buffer payload (B = index)
;   0xC7 — post-u state mismatch
;       sub-codes same as above
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
    LD      (undo_kind), A              ; UNDO_KIND_EMPTY

    LD      A, 'd'
    LD      (pending_operator), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 11
    LDIR
    LD      HL, GAP_BUFFER_BASE + 11
    LD      (gap_start), HL

    LD      HL, 0
    LD      (motions_compose_entry), HL ; compose entry cursor = 0
    LD      HL, 6                       ; landing on 'w' post-w-motion
    LD      (cursor_offset), HL

    CALL    op_compose_d

    ;; --- Post-dw assertions ---
    LD      A, (undo_kind)
    CP      UNDO_KIND_DELETE
    JR      Z, .ok_post_kind
    LD      B, 2
    LD      A, 0xC6
    JP      test_fail
.ok_post_kind:
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_post_pos
    LD      B, 3
    LD      A, 0xC6
    JP      test_fail
.ok_post_pos:
    LD      HL, (undo_length)
    LD      DE, 6
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_post_len
    LD      B, 4
    LD      A, 0xC6
    JP      test_fail
.ok_post_len:

    ;; undo_buffer[0..5] = "hello "
    LD      HL, undo_buffer
    LD      DE, .saved_word
    LD      B, 6
.ucmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ucmp_next
    LD      A, 6
    SUB     B
    LD      B, A
    LD      A, 0xC6
    JP      test_fail
.ucmp_next:
    INC     HL
    INC     DE
    DJNZ    .ucmp

    ;; buffer = "world" (5 B)
    LD      HL, 0
    LD      DE, .after_dw
    LD      B, 5
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
    LD      A, 5
    SUB     B
    LD      B, A
    LD      A, 0xC6
    JP      test_fail
.bcmp_next:
    INC     HL
    INC     DE
    DJNZ    .bcmp

    ;; --- Now invoke op_undo ---
    CALL    op_undo

    ;; --- Post-u assertions ---
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_post_u_cursor
    LD      B, 1
    LD      A, 0xC7
    JP      test_fail
.ok_post_u_cursor:

    ;; Buffer should be back to "hello world".
    LD      HL, 0
    LD      DE, .payload
    LD      B, 11
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
    LD      A, 11
    SUB     B
    LD      B, A
    LD      A, 0xC7
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    JP      test_pass

.payload:
    DEFB    "hello world"
.after_dw:
    DEFB    "world"
.saved_word:
    DEFB    "hello "

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
