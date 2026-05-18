; ============================================================
; Module: test/cases/undo_consumed-then-u-again.asm
; Purpose: Story 2.13 AC5 — second `u` after a consumed entry
;          surfaces "nothing to undo". Pre-load "abc" (3 B),
;          cursor=1, undo_kind=EMPTY. CALL edits_delete_char
;          (records DELETE; buffer becomes "ac"). CALL op_undo
;          (buffer back to "abc"; undo_kind cleared to EMPTY).
;          CALL op_undo AGAIN; assert buffer unchanged and
;          status_buffer prefix = "nothing to undo" (15 chars).
;
;          Pins: u-of-u — second u shows nothing-to-undo per
;          AC5 cleared-after-consume.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xCD — post-second-u state mismatch (B = sub-code:
;          0=buffer (B-index = mismatch offset),
;          1=status_buffer prefix mismatch (B = index))
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

    LD      HL, 1                       ; cursor on 'b'
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; --- First mutation + first undo (state setup) ---
    CALL    edits_delete_char           ; buffer -> "ac"; undo_kind=DELETE
    CALL    op_undo                     ; buffer -> "abc"; undo_kind=EMPTY

    ;; --- Second op_undo — should surface nothing-to-undo ---
    CALL    op_undo

    ;; --- Buffer still "abc" ---
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
    LD      A, 3
    SUB     B
    LD      B, A
    LD      A, 0xCD
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    ;; --- status_buffer prefix = "nothing to undo" (15 chars) ---
    LD      HL, status_buffer
    LD      DE, .expected_msg
    LD      B, 15
.msg_loop:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .msg_next
    LD      A, 15
    SUB     B                           ; A = mismatch index (0..14)
    LD      B, A                        ; B = mismatch index for context
    LD      A, 0xCD
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
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
