; ============================================================
; Module: test/cases/undo_dd-restores-line.asm
; Purpose: AC11 canonical — `dd` on `"abc\ndef\n"` (8 B), cursor=0,
;          CALL op_dd. Assert: buffer="def\n" (4 B remaining);
;          cursor=0; undo_kind=DELETE; undo_position=0;
;          undo_length=4; undo_buffer[0..3]="abc\n". THEN CALL
;          op_undo; assert buffer="abc\ndef\n" (8 B); cursor=0;
;          buffer_dirty=1; undo_kind=EMPTY (consumed).
;          Pins: dd → u round-trip; line-granularity.
;
; AC reference: AC4 (op_undo); AC11 canonical (dd round-trip);
;          FR45 (op_dd records DELETE before yank-copy).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xC0 — post-dd state mismatch (B = sub-code: 0=buffer,
;          1=cursor, 2=undo_kind, 3=undo_position, 4=undo_length,
;          5=payload)
;   0xC1 — post-u state mismatch (B = sub-code: 0=buffer,
;          1=cursor, 2=undo_kind, 3=buffer_dirty)
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
    LD      BC, 8
    LDIR
    LD      HL, GAP_BUFFER_BASE + 8
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    op_dd

    ;; --- Post-dd assertions ---
    ;; cursor=0
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_post_dd_cursor
    LD      B, 1
    LD      A, 0xC0
    JP      test_fail
.ok_post_dd_cursor:

    ;; undo_kind=UNDO_KIND_DELETE
    LD      A, (undo_kind)
    CP      UNDO_KIND_DELETE
    JR      Z, .ok_post_dd_kind
    LD      B, 2
    LD      A, 0xC0
    JP      test_fail
.ok_post_dd_kind:

    ;; undo_position=0
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_post_dd_pos
    LD      B, 3
    LD      A, 0xC0
    JP      test_fail
.ok_post_dd_pos:

    ;; undo_length=4
    LD      HL, (undo_length)
    LD      DE, 4
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_post_dd_len
    LD      B, 4
    LD      A, 0xC0
    JP      test_fail
.ok_post_dd_len:

    ;; undo_buffer[0..3] = "abc\n"
    LD      HL, undo_buffer
    LD      DE, .payload                ; first 4 bytes are "abc\n"
    LD      B, 4
.pld_cmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .pld_next
    LD      B, 5
    LD      A, 0xC0
    JP      test_fail
.pld_next:
    INC     HL
    INC     DE
    DJNZ    .pld_cmp

    ;; Buffer = "def\n" (4 B remaining).
    LD      HL, 0
    LD      DE, .expected_post_dd
    LD      B, 4
.bcmp_dd:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .bcmp_dd_next
    LD      B, 0
    LD      A, 0xC0
    JP      test_fail
.bcmp_dd_next:
    INC     HL
    INC     DE
    DJNZ    .bcmp_dd

    ;; --- Now invoke op_undo ---
    CALL    op_undo

    ;; --- Post-u assertions ---
    ;; undo_kind = EMPTY (consumed)
    LD      A, (undo_kind)
    OR      A
    JR      Z, .ok_post_u_kind
    LD      B, 2
    LD      A, 0xC1
    JP      test_fail
.ok_post_u_kind:

    ;; cursor=0
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_post_u_cursor
    LD      B, 1
    LD      A, 0xC1
    JP      test_fail
.ok_post_u_cursor:

    ;; buffer_dirty=1
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_post_u_dirty
    LD      B, 3
    LD      A, 0xC1
    JP      test_fail
.ok_post_u_dirty:

    ;; Buffer = "abc\ndef\n" (8 B).
    LD      HL, 0
    LD      DE, .payload
    LD      B, 8
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
    LD      A, 0xC1
    JP      test_fail
.bcmp_u_next:
    INC     HL
    INC     DE
    DJNZ    .bcmp_u

    JP      test_pass

.payload:
    DEFB    "abc", 0x0A, "def", 0x0A
.expected_post_dd:
    DEFB    "def", 0x0A

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
