; ============================================================
; Module: test/cases/undo_insert-session-as-unit.asm
; Purpose: B2 — an INSERT session collapses into a single undo
;          entry. Pre-load "hello" (5 B), cursor=5 (EOF / past
;          'o'), mode=NORMAL, undo_kind=EMPTY. CALL
;          enter_insert_mode (saves insert_session_entry_cursor=5
;          + sets mode=INSERT). Drive three literal inserts ('X',
;          'Y', 'Z') via edits_insert_literal (buffer becomes
;          "helloXYZ"; cursor=8). CALL enter_normal_mode
;          (mode_byte==MODE_INSERT so undo_insert_exit_record
;          fires). Assert: undo_kind=INSERT, undo_position=5,
;          undo_length=3. CALL op_undo. Assert: buffer="hello"
;          (5 B back); cursor=5; undo_kind=EMPTY.
;
; AC reference: B2 single-undo-entry-per-INSERT-session;
;          undo_insert_exit_record pure-INSERT case A delta>0.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xC2 — post-Esc state mismatch
;       sub-codes (B): 2=undo_kind, 3=undo_position, 4=undo_length
;   0xC3 — post-u state mismatch
;       sub-codes (B): 0=buffer (B = index ranged), 1=cursor,
;                      2=undo_kind
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
    LD      BC, 5
    LDIR
    LD      HL, GAP_BUFFER_BASE + 5
    LD      (gap_start), HL

    LD      HL, 5                       ; cursor past 'o' (EOF)
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; Enter INSERT (saves insert_session_entry_cursor=5; mode=INSERT).
    CALL    enter_insert_mode

    ;; Three literal inserts: 'X', 'Y', 'Z' -> "helloXYZ"; cursor=8.
    LD      A, 'X'
    CALL    edits_insert_literal
    LD      A, 'Y'
    CALL    edits_insert_literal
    LD      A, 'Z'
    CALL    edits_insert_literal

    ;; Esc back to NORMAL — exit hook fires (mode_byte still MODE_INSERT
    ;; at hook check; delta = 8 - 5 = 3 > 0 → record INSERT).
    CALL    enter_normal_mode

    ;; --- Post-Esc assertions: session collapsed to one INSERT entry ---
    LD      A, (undo_kind)
    CP      UNDO_KIND_INSERT
    JR      Z, .ok_post_esc_kind
    LD      B, 2
    LD      A, 0xC2
    JP      test_fail
.ok_post_esc_kind:
    LD      HL, (undo_position)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_post_esc_pos
    LD      B, 3
    LD      A, 0xC2
    JP      test_fail
.ok_post_esc_pos:
    LD      HL, (undo_length)
    LD      DE, 3
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_post_esc_len
    LD      B, 4
    LD      A, 0xC2
    JP      test_fail
.ok_post_esc_len:

    ;; --- Replay ---
    CALL    op_undo

    ;; --- Post-u assertions ---
    LD      A, (undo_kind)
    OR      A                           ; UNDO_KIND_EMPTY = 0
    JR      Z, .ok_post_u_kind
    LD      B, 2
    LD      A, 0xC3
    JP      test_fail
.ok_post_u_kind:

    LD      HL, (cursor_offset)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_post_u_cursor
    LD      B, 1
    LD      A, 0xC3
    JP      test_fail
.ok_post_u_cursor:

    ;; Buffer should be back to "hello".
    LD      HL, 0
    LD      DE, .payload
    LD      B, 5
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
    LD      A, 5
    SUB     B
    LD      B, A
    LD      A, 0xC3
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    JP      test_pass

.payload:
    DEFB    "hello"

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
