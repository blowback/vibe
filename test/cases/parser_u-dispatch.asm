; ============================================================
; Module: test/cases/parser_u-dispatch.asm
; Purpose: AC11 additional — drive `u` through the production
;          dispatch_key chain. Simulates a post-`x` state: buffer
;          "ac" (2 B), cursor=1, with the undo register pre-seeded
;          as if x had just deleted 'b' from "abc" at offset 1
;          (kind=DELETE, position=1, length=1, payload="b").
;
;          CALL dispatch_key with A='u', HL=dispatch_normal,
;          B=DISPATCH_NORMAL_COUNT. The dispatcher binary-searches
;          to the 'u' entry; routes to op_undo. op_undo reads
;          undo_kind=DELETE, replays via gapbuf_insert (per-byte
;          loop) — restoring 'b' at offset 1, cursor at 1.
;
;          Assert: buffer="abc" (3 B); cursor=1; buffer_dirty=1;
;          undo_kind=EMPTY (consumed); parser state cleared.
;
;          Pins: AC8 dispatch wiring — the 'u' entry routes
;          correctly through dispatch_key's binary-search; the
;          handler signature (A=key=ASCII 'u' on entry, ignored
;          per MC4) matches op_undo's contract; AC4 success path
;          through the dispatcher.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE7 — failure (B = sub-code: 0=buffer, 1=cursor,
;          2=buffer_dirty, 3=undo_kind, 4=parser-not-cleared)
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
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; Buffer: "ac" (post-x state).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 2
    LDIR
    LD      HL, GAP_BUFFER_BASE + 2
    LD      (gap_start), HL

    LD      HL, 1                       ; cursor where x left it
    LD      (cursor_offset), HL

    ;; Pre-seed undo register as if x had just deleted 'b'.
    LD      A, UNDO_KIND_DELETE
    LD      (undo_kind), A
    LD      HL, 1
    LD      (undo_position), HL
    LD      HL, 1
    LD      (undo_length), HL
    LD      A, 'b'
    LD      (undo_buffer), A

    ;; Drive 'u' through the production dispatcher.
    LD      A, 'u'
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key

    ;; --- Assertions ---
    ;; Buffer = "abc" (3 B).
    LD      HL, 0
    LD      DE, .expected
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
    LD      B, 0
    LD      A, 0xE7
    JP      test_fail
.cmp_next:
    INC     HL
    INC     DE
    DJNZ    .cmp_loop

    ;; cursor = 1
    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, 1
    LD      A, 0xE7
    JP      test_fail
.ok_cursor:

    ;; buffer_dirty = 1
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, 2
    LD      A, 0xE7
    JP      test_fail
.ok_dirty:

    ;; undo_kind = EMPTY (consumed)
    LD      A, (undo_kind)
    OR      A
    JR      Z, .ok_undo_kind
    LD      B, 3
    LD      A, 0xE7
    JP      test_fail
.ok_undo_kind:

    ;; Parser cleared: pending_operator=0, pending_motion_prefix=0,
    ;; pending_motion_inclusive=0, count_accumulator=0 (both bytes).
    LD      A, (pending_operator)
    OR      A
    JR      NZ, .parser_fail
    LD      A, (pending_motion_prefix)
    OR      A
    JR      NZ, .parser_fail
    LD      A, (pending_motion_inclusive)
    OR      A
    JR      NZ, .parser_fail
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .parser_ok
.parser_fail:
    LD      B, 4
    LD      A, 0xE7
    JP      test_fail
.parser_ok:

    JP      test_pass

.payload:
    DEFB    "ac"
.expected:
    DEFB    "abc"

    INCLUDE "../inc/test_epilogue.inc"
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"
    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
