; ============================================================
; Module: test/cases/undo_buffer-dirty-recomputes.asm
; Purpose: Q5 Option A MVP pin — buffer_dirty STAYS 1 after a
;          successful undo (no last-saved-state recompute).
;          Pre-load "abc", cursor=1, buffer_dirty=0,
;          undo_kind=EMPTY, mode=NORMAL. CALL edits_delete_char
;          (the `x`); assert buffer_dirty=1. CALL op_undo; assert
;          buffer_dirty STAYS 1 (NOT 0 — MVP does NOT compare to
;          last-saved-state). Spot-check buffer="abc" restored
;          and cursor=1.
;
; AC reference: Q5 Option A MVP pin (architecture.md §Undo —
;          documented vi-divergence: undo back to last-saved
;          buffer leaves buffer_dirty=1; user can :w idempotently).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xC5 — state mismatch
;       sub-codes (B): 0=buffer (B = index ranged), 1=cursor,
;                      2=buffer_dirty-post-x,
;                      3=buffer_dirty-post-u (the MVP pin)
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
    LD      (buffer_dirty), A            ; explicitly clean
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (undo_kind), A               ; UNDO_KIND_EMPTY

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL

    LD      HL, 1                        ; cursor on 'b'
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; --- The `x` ---
    CALL    edits_delete_char

    ;; Post-x: buffer_dirty must be 1.
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_post_x_dirty
    LD      B, 2
    LD      A, 0xC5
    JP      test_fail
.ok_post_x_dirty:

    ;; --- Replay ---
    CALL    op_undo

    ;; Post-u: buffer_dirty STAYS 1 (Q5 Option A MVP pin).
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_post_u_dirty
    LD      B, 3
    LD      A, 0xC5
    JP      test_fail
.ok_post_u_dirty:

    ;; Cursor back at 1.
    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_post_u_cursor
    LD      B, 1
    LD      A, 0xC5
    JP      test_fail
.ok_post_u_cursor:

    ;; Buffer = "abc" again.
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
    LD      A, 0xC5
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
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
