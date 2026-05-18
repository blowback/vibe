; ============================================================
; Module: test/cases/undo_dedent-line.asm
; Purpose: Story 2.13 Q6 Option B coverage — `<<` (op_dedent_line)
;          records UNDO_KIND_DEDENT_WALK with the pre-walk
;          promoted_start/length; subsequent `u` replays via
;          edits_indent_walk with mode flipped (indent),
;          restoring the leading INDENT_BYTE.
;
;          Pre-load `" abc\ndef\n"` (9 B with leading space on
;          line 1), cursor=0, count=0, mode=NORMAL,
;          undo_kind=EMPTY, pending_operator=0.
;          CALL op_dedent_line.
;          Assert: buffer="abc\ndef\n" (8 B; leading INDENT_BYTE
;          removed from line 1); undo_kind=UNDO_KIND_DEDENT_WALK;
;          undo_position=0; undo_length=4 (POST-walk "abc\n").
;          THEN CALL op_undo.
;          Assert: buffer=" abc\ndef\n" (9 B; leading INDENT_BYTE
;          restored); cursor=0; buffer_dirty=1;
;          undo_kind=UNDO_KIND_EMPTY (consumed).
;
;          Pins: << → u round-trip; Q6 Option B DEDENT_WALK kind.
;
; AC reference: AC4 (op_undo); AC7 hook 5 (op_dedent_line records
;          DEDENT_WALK on edits_indent_walk_dirty=1); FR45.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xCE — post-dedent state mismatch (B = sub-code: 0=buffer,
;          1=cursor, 2=undo_kind, 3=undo_position, 4=undo_length)
;   0xCF — post-undo state mismatch (B = sub-code: 0=buffer,
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
    LD      (pending_motion_inclusive), A
    LD      (buffer_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (undo_kind), A              ; UNDO_KIND_EMPTY

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 9
    LDIR
    LD      HL, GAP_BUFFER_BASE + 9
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    op_dedent_line

    ;; --- Post-dedent assertions ---
    ;; undo_kind = UNDO_KIND_DEDENT_WALK
    LD      A, (undo_kind)
    CP      UNDO_KIND_DEDENT_WALK
    JR      Z, .ok_post_dedent_kind
    LD      B, 2
    LD      A, 0xCE
    JP      test_fail
.ok_post_dedent_kind:

    ;; undo_position = 0
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_post_dedent_pos
    LD      B, 3
    LD      A, 0xCE
    JP      test_fail
.ok_post_dedent_pos:

    ;; undo_length = 4 ("abc\n" — POST-walk range; the cell holds
    ;; the effective post-walk end so the inverse indent walk
    ;; grows DE back to the pre-dedent line stride symmetrically).
    LD      HL, (undo_length)
    LD      DE, 4
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_post_dedent_len
    LD      B, 4
    LD      A, 0xCE
    JP      test_fail
.ok_post_dedent_len:

    ;; Buffer = "abc\ndef\n" (8 B).
    LD      HL, 0
    LD      DE, .expected_post_dedent
    LD      B, 8
.cmp_dedent_loop:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .cmp_dedent_next
    LD      B, 0
    LD      A, 0xCE
    JP      test_fail
.cmp_dedent_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_dedent_loop

    ;; --- Now invoke op_undo ---
    CALL    op_undo

    ;; --- Post-undo assertions ---
    ;; undo_kind = EMPTY (consumed)
    LD      A, (undo_kind)
    OR      A
    JR      Z, .ok_post_u_kind
    LD      B, 2
    LD      A, 0xCF
    JP      test_fail
.ok_post_u_kind:

    ;; cursor = 0
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_post_u_cursor
    LD      B, 1
    LD      A, 0xCF
    JP      test_fail
.ok_post_u_cursor:

    ;; buffer_dirty = 1
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_post_u_dirty
    LD      B, 3
    LD      A, 0xCF
    JP      test_fail
.ok_post_u_dirty:

    ;; Buffer = " abc\ndef\n" (9 B; back to original).
    LD      HL, 0
    LD      DE, .payload
    LD      B, 9
.cmp_u_loop:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .cmp_u_next
    ;; Mismatch — encode mismatch index in B (= 9 - B remaining).
    LD      A, 9
    SUB     B
    LD      B, A
    LD      A, 0xCF
    JP      test_fail
.cmp_u_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_u_loop

    JP      test_pass

.payload:
    DEFB    0x20, "abc", 0x0A, "def", 0x0A
.expected_post_dedent:
    DEFB    "abc", 0x0A, "def", 0x0A

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
