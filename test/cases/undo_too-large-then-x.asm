; ============================================================
; Module: test/cases/undo_too-large-then-x.asm
; Purpose: Story 2.13 single-slot semantics — `dd` on a 301-byte
;          file records UNDO_KIND_TOO_LARGE; a subsequent `x` then
;          OVERWRITES that entry with UNDO_KIND_DELETE for the
;          single character. `u` after the second mutation replays
;          the `x` (re-inserts the byte) — the prior TOO_LARGE has
;          been discarded.
;
;          Construct a 301-byte payload (DEFS 300, 'A' + DEFB 0x0A).
;          Pre-load. cursor=0, mode=NORMAL, undo_kind=EMPTY.
;          CALL op_dd. Assert: undo_kind=UNDO_KIND_TOO_LARGE.
;          Re-init the gap buffer: CALL gapbuf_init; LDIR "abc" (3
;          bytes) into GAP_BUFFER_BASE; gap_start=GAP_BUFFER_BASE+3;
;          cursor_offset=1. CALL edits_delete_char (x on 'b').
;          Assert: undo_kind=UNDO_KIND_DELETE (TOO_LARGE overwritten).
;          CALL op_undo. Assert: buffer="abc" (x-undo replays).
;
; Pins:    AC11 — undo state is single-slot; the second mutation
;          REPLACES the prior entry regardless of kind.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xCC — state mismatch
;       sub-codes (B): 0=post-dd undo_kind != TOO_LARGE,
;                      1=post-x undo_kind != DELETE,
;                      2=post-u buffer mismatch (B = index)
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
    LD      HL, .big_payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 301
    LDIR
    LD      HL, GAP_BUFFER_BASE + 301
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; --- Step 1: dd on 301-byte file → UNDO_KIND_TOO_LARGE. ---
    CALL    op_dd

    LD      A, (undo_kind)
    CP      UNDO_KIND_TOO_LARGE
    JR      Z, .ok_post_dd_kind
    LD      B, 0
    LD      A, 0xCC
    JP      test_fail
.ok_post_dd_kind:

    ;; --- Step 2: re-init gap buffer with "abc"; cursor=1 (on 'b'). ---
    CALL    gapbuf_init
    LD      HL, .small_payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 3
    LDIR
    LD      HL, GAP_BUFFER_BASE + 3
    LD      (gap_start), HL
    LD      HL, 1
    LD      (cursor_offset), HL

    ;; --- Step 3: x on 'b' → UNDO_KIND_DELETE (overwrites TOO_LARGE). ---
    CALL    edits_delete_char

    LD      A, (undo_kind)
    CP      UNDO_KIND_DELETE
    JR      Z, .ok_post_x_kind
    LD      B, 1
    LD      A, 0xCC
    JP      test_fail
.ok_post_x_kind:

    ;; --- Step 4: u replays the x — buffer back to "abc". ---
    CALL    op_undo

    LD      HL, 0
    LD      DE, .small_payload
    LD      B, 3
.bcmp:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .bcmp_next
    LD      A, 3
    SUB     B
    LD      B, A
    LD      A, 0xCC
    JP      test_fail
.bcmp_next:
    INC     HL
    INC     DE
    DJNZ    .bcmp

    JP      test_pass

.big_payload:
    DEFS    300, 'A'
    DEFB    0x0A
.small_payload:
    DEFB    "abc"

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
