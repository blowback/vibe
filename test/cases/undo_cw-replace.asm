; ============================================================
; Module: test/cases/undo_cw-replace.asm
; Purpose: Story 2.13 Q3 Option A two-phase REPLACE — `cw` records
;          UNDO_KIND_DELETE on phase 1 (op_compose_c) with the old
;          content saved in undo_buffer; the subsequent INSERT
;          session at Esc upgrades to UNDO_KIND_REPLACE with
;          undo_length=new-content-bytes and undo_aux_length=old-
;          content-bytes (undo_buffer still holds the old content).
;          Pre-load "hello world" (11 B), cursor=0, mode=NORMAL.
;          Simulate `cw`: pending_operator='c',
;          motions_compose_entry=0, cursor_offset=6 (post-w-motion
;          landing), pending_motion_inclusive=0. CALL op_compose_c.
;          Assert: buffer="world" (5 B); mode=MODE_INSERT (tail-JP
;          to enter_insert_mode); undo_kind=UNDO_KIND_DELETE;
;          undo_position=0; undo_length=6; undo_buffer[0..5]="hello ".
;          Then simulate typing "BIG " via 4x edits_insert_literal
;          ('B','I','G',' '): buffer="BIG world" (9 B); cursor=4.
;          CALL enter_normal_mode (Esc → undo_insert_exit_record).
;          Assert: undo_kind=UNDO_KIND_REPLACE; undo_position=0;
;          undo_length=4 (new-content "BIG " bytes); undo_aux_length=6
;          (old-content "hello " bytes); undo_buffer[0..5] still
;          = "hello ". CALL op_undo. Assert: buffer="hello world",
;          cursor=0, undo_kind=UNDO_KIND_EMPTY.
;
; Pins:    Q3 Option A two-phase REPLACE upgrade (cw → typing → Esc
;          collapses to one UNDO_KIND_REPLACE entry).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xC8 — state mismatch
;       sub-codes (B): 0=phase1-buffer (B = index ranged),
;                      1=phase1-mode, 2=phase1-undo_kind,
;                      3=phase1-undo_position, 4=phase1-undo_length,
;                      5=phase1-undo_buffer payload (B = index)
;                      0x10..0x14=phase3 (post-Esc) — same offsets +0x10:
;                                  0x12=undo_kind, 0x13=undo_position,
;                                  0x14=undo_length, 0x15=undo_aux_length,
;                                  0x16=undo_buffer payload (B = index)
;                      0x20=phase4-buffer (B = index), 0x21=phase4-cursor,
;                      0x22=phase4-undo_kind
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

    LD      A, 'c'
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

    ;; --- Step 1: op_compose_c (phase 1 records DELETE; tail-JPs
    ;; enter_insert_mode which sets MODE_INSERT + saves entry cursor=0).
    CALL    op_compose_c

    ;; --- Phase 1 assertions ---
    LD      A, (mode_byte)
    CP      MODE_INSERT
    JR      Z, .ok_p1_mode
    LD      B, 1
    LD      A, 0xC8
    JP      test_fail
.ok_p1_mode:
    LD      A, (undo_kind)
    CP      UNDO_KIND_DELETE
    JR      Z, .ok_p1_kind
    LD      B, 2
    LD      A, 0xC8
    JP      test_fail
.ok_p1_kind:
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_p1_pos
    LD      B, 3
    LD      A, 0xC8
    JP      test_fail
.ok_p1_pos:
    LD      HL, (undo_length)
    LD      DE, 6
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_p1_len
    LD      B, 4
    LD      A, 0xC8
    JP      test_fail
.ok_p1_len:

    ;; undo_buffer[0..5] = "hello "
    LD      HL, undo_buffer
    LD      DE, .saved_word
    LD      B, 6
.p1_ucmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .p1_ucmp_next
    LD      A, 6
    SUB     B
    LD      B, A
    LD      A, 0xC8
    JP      test_fail
.p1_ucmp_next:
    INC     HL
    INC     DE
    DJNZ    .p1_ucmp

    ;; buffer = "world" (5 B)
    LD      HL, 0
    LD      DE, .after_cw
    LD      B, 5
.p1_bcmp:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .p1_bcmp_next
    LD      A, 5
    SUB     B
    LD      B, A
    LD      A, 0xC8
    JP      test_fail
.p1_bcmp_next:
    INC     HL
    INC     DE
    DJNZ    .p1_bcmp

    ;; --- Step 2: type "BIG " (4 literal inserts). ---
    LD      A, 'B'
    CALL    edits_insert_literal
    LD      A, 'I'
    CALL    edits_insert_literal
    LD      A, 'G'
    CALL    edits_insert_literal
    LD      A, ' '
    CALL    edits_insert_literal

    ;; --- Step 3: Esc — exit hook upgrades DELETE → REPLACE. ---
    CALL    enter_normal_mode

    ;; --- Phase 3 assertions ---
    LD      A, (undo_kind)
    CP      UNDO_KIND_REPLACE
    JR      Z, .ok_p3_kind
    LD      B, 0x12
    LD      A, 0xC8
    JP      test_fail
.ok_p3_kind:
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_p3_pos
    LD      B, 0x13
    LD      A, 0xC8
    JP      test_fail
.ok_p3_pos:
    LD      HL, (undo_length)
    LD      DE, 4                       ; "BIG " new content
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_p3_len
    LD      B, 0x14
    LD      A, 0xC8
    JP      test_fail
.ok_p3_len:
    LD      HL, (undo_aux_length)
    LD      DE, 6                       ; "hello " old content
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_p3_aux
    LD      B, 0x15
    LD      A, 0xC8
    JP      test_fail
.ok_p3_aux:

    ;; undo_buffer[0..5] still = "hello "
    LD      HL, undo_buffer
    LD      DE, .saved_word
    LD      B, 6
.p3_ucmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .p3_ucmp_next
    LD      A, 6
    SUB     B
    LD      B, A
    ADD     A, 0x16 - 0
    LD      B, A
    LD      A, 0xC8
    JP      test_fail
.p3_ucmp_next:
    INC     HL
    INC     DE
    DJNZ    .p3_ucmp

    ;; --- Step 4: op_undo replays REPLACE (delete new + insert old). ---
    CALL    op_undo

    ;; Buffer = "hello world" (11 B).
    LD      HL, 0
    LD      DE, .payload
    LD      B, 11
.p4_bcmp:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .p4_bcmp_next
    LD      A, 11
    SUB     B
    LD      B, A
    LD      A, 0xC8
    JP      test_fail
.p4_bcmp_next:
    INC     HL
    INC     DE
    DJNZ    .p4_bcmp

    ;; Cursor = 0.
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_p4_cursor
    LD      B, 0x21
    LD      A, 0xC8
    JP      test_fail
.ok_p4_cursor:

    ;; undo_kind = EMPTY (consumed).
    LD      A, (undo_kind)
    OR      A
    JR      Z, .ok_p4_kind
    LD      B, 0x22
    LD      A, 0xC8
    JP      test_fail
.ok_p4_kind:

    JP      test_pass

.payload:
    DEFB    "hello world"
.after_cw:
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
