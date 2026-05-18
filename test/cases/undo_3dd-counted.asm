; ============================================================
; Module: test/cases/undo_3dd-counted.asm
; Purpose: Story 2.13 — `3dd` records UNDO_KIND_DELETE with
;          the full 6-byte deleted range; subsequent `u`
;          restores all three lines. Pre-load "a\nb\nc\nd\n"
;          (8 B), cursor=0, count_accumulator=3. CALL op_dd;
;          assert buffer="d\n" (2 B; offset 2 = past EOF),
;          undo_kind=DELETE, undo_length=6, undo_buffer[0..5]
;          = "a", 0x0A, "b", 0x0A, "c", 0x0A. CALL op_undo;
;          assert buffer restored to "a\nb\nc\nd\n" (8 B) +
;          cursor=0.
;
;          Pins: Ndd → u multi-line restoration.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xCB — post-3dd state mismatch (B = sub-code:
;          0=buffer (B-index = mismatch offset; 0xFF = offset 2
;          not past-EOF as expected),
;          1=undo_kind, 2=undo_length, 3=undo_buffer payload
;          (B = mismatch index))
;   0xCC — post-u state mismatch (B = sub-code:
;          0=buffer (B-index = mismatch offset), 1=cursor)
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

    LD      HL, 3
    LD      (count_accumulator), HL

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

    ;; --- Post-3dd: buffer = "d\n" (offsets 0='d', 1=0x0A, 2 past EOF) ---
    LD      HL, 0
    CALL    motion_byte_at_logical
    JR      C, .buf0_fail
    CP      'd'
    JR      Z, .ok_buf0
.buf0_fail:
    LD      B, 0
    LD      A, 0xCB
    JP      test_fail
.ok_buf0:
    LD      HL, 1
    CALL    motion_byte_at_logical
    JR      C, .buf1_fail
    CP      0x0A
    JR      Z, .ok_buf1
.buf1_fail:
    LD      B, 1
    LD      A, 0xCB
    JP      test_fail
.ok_buf1:
    LD      HL, 2
    CALL    motion_byte_at_logical
    JR      C, .ok_past_eof             ; CF=1 expected (past EOF)
    LD      B, 0xFF
    LD      A, 0xCB
    JP      test_fail
.ok_past_eof:

    LD      A, (undo_kind)
    CP      UNDO_KIND_DELETE
    JR      Z, .ok_kind
    LD      B, 1
    LD      A, 0xCB
    JP      test_fail
.ok_kind:

    LD      HL, (undo_length)
    LD      DE, 6
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_len
    LD      B, 2
    LD      A, 0xCB
    JP      test_fail
.ok_len:

    ;; undo_buffer[0..5] = "a", 0x0A, "b", 0x0A, "c", 0x0A
    LD      HL, undo_buffer
    LD      DE, .expected_undo
    LD      B, 6
.ubuf_loop:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .ubuf_next
    LD      A, 6
    SUB     B                           ; A = mismatch index (0..5)
    LD      B, A                        ; B = mismatch index for context
    LD      A, 0xCB
    JP      test_fail
.ubuf_next:
    INC     HL
    INC     DE
    DJNZ    .ubuf_loop

    ;; --- Now invoke op_undo ---
    CALL    op_undo

    ;; --- Post-u: buffer = "a\nb\nc\nd\n" (8 B), cursor=0 ---
    LD      HL, 0
    LD      DE, .payload
    LD      B, 8
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
    LD      A, 8
    SUB     B
    LD      B, A
    LD      A, 0xCC
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, 1
    LD      A, 0xCC
    JP      test_fail
.ok_cursor:

    JP      test_pass

.payload:
    DEFB    "a", 0x0A, "b", 0x0A, "c", 0x0A, "d", 0x0A
.expected_undo:
    DEFB    "a", 0x0A, "b", 0x0A, "c", 0x0A

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
