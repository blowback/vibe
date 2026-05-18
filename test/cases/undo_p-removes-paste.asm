; ============================================================
; Module: test/cases/undo_p-removes-paste.asm
; Purpose: Story 2.13 — `p` records UNDO_KIND_INSERT entry,
;          subsequent `u` removes the pasted bytes. Pre-load
;          "abc" (3 B), cursor=0; pre-seed KIND_CHAR yank with
;          "XY" (2 B). CALL op_paste; assert buffer="aXYbc"
;          (5 B), cursor=2 (last byte of inserted range per
;          KIND_CHAR rule: insertion_start=1, length=2,
;          cursor=1+2-1=2), undo_kind=INSERT, undo_position=1,
;          undo_length=2. Then CALL op_undo; assert buffer
;          restored to "abc", cursor=1 (= undo_position),
;          buffer_dirty=1.
;
;          Pins: paste → u; KIND_CHAR replay removes the bytes.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xC7 — post-paste state mismatch (B = sub-code:
;          0=buffer, 1=cursor, 2=undo_kind, 3=undo_position,
;          4=undo_length)
;   0xC8 — post-u state mismatch (B = sub-code:
;          0=buffer, 1=cursor, 2=buffer_dirty)
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

    LD      HL, 0                       ; cursor on 'a'
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; --- Pre-seed yank: KIND_CHAR, len=2, "XY" ---
    LD      A, KIND_CHAR
    LD      (yank_kind), A
    LD      HL, 2
    LD      (yank_length), HL
    LD      HL, .yank_content
    LD      DE, yank_buffer
    LD      BC, 2
    LDIR

    CALL    op_paste

    ;; --- Post-paste assertions ---
    ;; Buffer = "aXYbc" via motion_byte_at_logical at 0..4.
    LD      HL, 0
    LD      DE, .expected_after_paste
    LD      B, 5
.cmp_paste_loop:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .cmp_paste_next
    LD      B, 0
    LD      A, 0xC7
    JP      test_fail
.cmp_paste_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_paste_loop

    ;; cursor=2 (last byte of inserted range).
    LD      HL, (cursor_offset)
    LD      DE, 2
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_post_paste_cursor
    LD      B, 1
    LD      A, 0xC7
    JP      test_fail
.ok_post_paste_cursor:

    LD      A, (undo_kind)
    CP      UNDO_KIND_INSERT
    JR      Z, .ok_post_paste_kind
    LD      B, 2
    LD      A, 0xC7
    JP      test_fail
.ok_post_paste_kind:

    LD      HL, (undo_position)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_post_paste_pos
    LD      B, 3
    LD      A, 0xC7
    JP      test_fail
.ok_post_paste_pos:

    LD      HL, (undo_length)
    LD      DE, 2
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_post_paste_len
    LD      B, 4
    LD      A, 0xC7
    JP      test_fail
.ok_post_paste_len:

    ;; --- Now invoke op_undo ---
    CALL    op_undo

    ;; --- Post-u assertions ---
    ;; Buffer back to "abc".
    LD      HL, 0
    LD      DE, .payload
    LD      B, 3
.cmp_undo_loop:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .cmp_undo_next
    LD      B, 0
    LD      A, 0xC8
    JP      test_fail
.cmp_undo_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_undo_loop

    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_post_u_cursor
    LD      B, 1
    LD      A, 0xC8
    JP      test_fail
.ok_post_u_cursor:

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_post_u_dirty
    LD      B, 2
    LD      A, 0xC8
    JP      test_fail
.ok_post_u_dirty:

    JP      test_pass

.payload:
    DEFB    "abc"
.yank_content:
    DEFB    "XY"
.expected_after_paste:
    DEFB    "aXYbc"

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
