; ============================================================
; Module: test/cases/undo_capacity-refusal.asm
; Purpose: FR46 capacity refusal — `dd` on a 301-byte single line
;          (300 'A' + LF) overflows UNDO_BUFFER_SIZE (256). Pre-load
;          payload, cursor=0, undo_kind=EMPTY, mode=NORMAL.
;          CALL op_dd: deletion still proceeds (buffer becomes empty);
;          undo_kind=UNDO_KIND_TOO_LARGE; undo_position=0;
;          undo_length=301 (recorded for diagnostics; payload NOT
;          copied). CALL op_undo: replay refused (buffer still empty);
;          status_buffer prefix = "undo not possible - too large";
;          undo_kind STAYS UNDO_KIND_TOO_LARGE (Q4 Option A —
;          surfacing does NOT clear; second `u` would re-surface).
;
; AC reference: FR46 capacity refusal; Q4 Option A pin
;          (UNDO_KIND_TOO_LARGE persists across surface).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xC3 — post-dd state mismatch (B = sub-code: 0=undo_kind,
;          1=undo_position, 2=undo_length, 3=buffer-not-empty)
;   0xC4 — post-u state mismatch (B = sub-code: 0=buffer-not-empty,
;          1=status_buffer prefix mismatch idx, 2=undo_kind cleared)
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
    LD      BC, 301
    LDIR
    LD      HL, GAP_BUFFER_BASE + 301
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    op_dd

    ;; --- Post-dd assertions ---
    ;; undo_kind = UNDO_KIND_TOO_LARGE
    LD      A, (undo_kind)
    CP      UNDO_KIND_TOO_LARGE
    JR      Z, .ok_post_dd_kind
    LD      B, 0
    LD      A, 0xC3
    JP      test_fail
.ok_post_dd_kind:

    ;; undo_position = 0
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .ok_post_dd_pos
    LD      B, 1
    LD      A, 0xC3
    JP      test_fail
.ok_post_dd_pos:

    ;; undo_length = 301 (recorded for diagnostics)
    LD      HL, (undo_length)
    LD      DE, 301
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_post_dd_len
    LD      B, 2
    LD      A, 0xC3
    JP      test_fail
.ok_post_dd_len:

    ;; Buffer empty: motion_byte_at_logical(0) returns CF=1 (past EOF).
    LD      HL, 0
    CALL    motion_byte_at_logical
    JR      C, .ok_empty
    LD      B, 3
    LD      A, 0xC3
    JP      test_fail
.ok_empty:

    ;; --- Now invoke op_undo (replay refused) ---
    CALL    op_undo

    ;; --- Post-u assertions ---
    ;; Buffer still empty: motion_byte_at_logical(0) returns CF=1.
    LD      HL, 0
    CALL    motion_byte_at_logical
    JR      C, .ok_post_u_empty
    LD      B, 0
    LD      A, 0xC4
    JP      test_fail
.ok_post_u_empty:

    ;; status_buffer prefix = "undo not possible - too large" (29 B).
    LD      HL, status_buffer
    LD      DE, .too_large_msg
    LD      B, 29
.scmp:
    LD      A, (DE)
    CP      (HL)
    JR      Z, .scmp_next
    LD      A, 29
    SUB     B
    LD      B, A
    LD      A, 0xC4
    JP      test_fail
.scmp_next:
    INC     HL
    INC     DE
    DJNZ    .scmp

    ;; undo_kind STILL UNDO_KIND_TOO_LARGE (Q4 Option A — not cleared).
    LD      A, (undo_kind)
    CP      UNDO_KIND_TOO_LARGE
    JR      Z, .ok_post_u_kind
    LD      B, 2
    LD      A, 0xC4
    JP      test_fail
.ok_post_u_kind:

    JP      test_pass

.payload:
    DEFS    300, 'A'
    DEFB    0x0A
.too_large_msg:
    DEFB    "undo not possible - too large"

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
