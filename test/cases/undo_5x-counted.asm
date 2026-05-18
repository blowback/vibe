; ============================================================
; Module: test/cases/undo_5x-counted.asm
; Purpose: AC11 — counted `5x` deletes 5 bytes from "abcdef"
;          (cursor=0); deletes_done captured per-iter so the
;          DELETE entry's payload = "abcde" / undo_length = 5.
;          Subsequent `u` restores full "abcdef" at cursor=0.
;          Pre-seed count_accumulator=5 (low+high bytes via
;          16-bit LD), mode=NORMAL, undo_kind=EMPTY.
;          CALL edits_delete_char; assert buffer="f"; cursor=0;
;          undo_kind=DELETE; undo_position=0; undo_length=5;
;          undo_buffer[0..4]="abcde". THEN CALL op_undo; assert
;          buffer="abcdef"; cursor=0 (replay restores).
;
; AC reference: AC11 (counted x → u round-trip); FR45 (per-iter
;          deletes_done capture for counted edits_delete_char).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xCA — post-x state mismatch (B = sub-code: 0=buffer,
;          1=cursor, 2=undo_kind, 3=undo_position, 4=undo_length,
;          5=payload[B-5]=undo_buffer[idx] mismatch)
;   0xCB — post-u state mismatch (B = sub-code: 0=buffer,
;          1=cursor)
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
    LD      (undo_kind), A              ; UNDO_KIND_EMPTY

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 6
    LDIR
    LD      HL, GAP_BUFFER_BASE + 6
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; Pre-seed count_accumulator=5 (both bytes via 16-bit write).
    LD      HL, 5
    LD      (count_accumulator), HL

    CALL    edits_delete_char

    ;; --- Post-x assertions ---
    ;; Buffer = "f" (1 byte; offset 0 = 'f', offset 1 = past EOF).
    LD      HL, 0
    CALL    motion_byte_at_logical
    CP      'f'
    JR      Z, .ok_post_x_b0
    LD      B, 0
    LD      A, 0xCA
    JP      test_fail
.ok_post_x_b0:
    LD      HL, 1
    CALL    motion_byte_at_logical
    JR      C, .ok_post_x_eof
    LD      B, 0
    LD      A, 0xCA
    JP      test_fail
.ok_post_x_eof:

    ;; cursor = 0
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_post_x_cursor
    LD      B, 1
    LD      A, 0xCA
    JP      test_fail
.ok_post_x_cursor:

    ;; undo_kind = UNDO_KIND_DELETE
    LD      A, (undo_kind)
    CP      UNDO_KIND_DELETE
    JR      Z, .ok_post_x_kind
    LD      B, 2
    LD      A, 0xCA
    JP      test_fail
.ok_post_x_kind:

    ;; undo_position = 0
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_post_x_pos
    LD      B, 3
    LD      A, 0xCA
    JP      test_fail
.ok_post_x_pos:

    ;; undo_length = 5
    LD      HL, (undo_length)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_post_x_len
    LD      B, 4
    LD      A, 0xCA
    JP      test_fail
.ok_post_x_len:

    ;; undo_buffer[0..4] = "abcde" — byte-by-byte via LD A,(undo_buffer+N).
    LD      A, (undo_buffer + 0)
    CP      'a'
    JR      Z, .ok_payload0
    LD      B, 5
    LD      A, 0xCA
    JP      test_fail
.ok_payload0:
    LD      A, (undo_buffer + 1)
    CP      'b'
    JR      Z, .ok_payload1
    LD      B, 6
    LD      A, 0xCA
    JP      test_fail
.ok_payload1:
    LD      A, (undo_buffer + 2)
    CP      'c'
    JR      Z, .ok_payload2
    LD      B, 7
    LD      A, 0xCA
    JP      test_fail
.ok_payload2:
    LD      A, (undo_buffer + 3)
    CP      'd'
    JR      Z, .ok_payload3
    LD      B, 8
    LD      A, 0xCA
    JP      test_fail
.ok_payload3:
    LD      A, (undo_buffer + 4)
    CP      'e'
    JR      Z, .ok_payload4
    LD      B, 9
    LD      A, 0xCA
    JP      test_fail
.ok_payload4:

    ;; --- Now invoke op_undo ---
    CALL    op_undo

    ;; --- Post-u assertions ---
    ;; Buffer = "abcdef" (6 bytes).
    LD      HL, 0
    LD      DE, .payload
    LD      B, 6
.bcmp_u:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .bcmp_u_next
    LD      B, 0
    LD      A, 0xCB
    JP      test_fail
.bcmp_u_next:
    INC     HL
    INC     DE
    DJNZ    .bcmp_u

    ;; cursor = 0
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_post_u_cursor
    LD      B, 1
    LD      A, 0xCB
    JP      test_fail
.ok_post_u_cursor:

    JP      test_pass

.payload:
    DEFB    "abcdef"

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
