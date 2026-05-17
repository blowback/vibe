; ============================================================
; Module: test/cases/parser_5u-dispatch.asm
; Purpose: AC11 + AC9 — drive `5u` through the production
;          dispatch_key chain. The '5' arrives first, gets routed
;          to parser_handle_digit (count_accumulator := 5). Then
;          'u' arrives, gets routed to op_undo. Per AC9, the count
;          is IGNORED — undo is single-level; counted `Nu` is
;          equivalent to bare `u`, and parser_clear at the tail
;          discards the pending count.
;
;          Pre-state mirrors parser_u-dispatch (post-x simulation):
;          buffer "ac" (2 B), cursor=1, undo register pre-seeded
;          with kind=DELETE, position=1, length=1, payload="b".
;
;          First dispatch: A='5'. Routes to parser_handle_digit;
;          count_accumulator := 5. Buffer/cursor/undo unchanged.
;          Second dispatch: A='u'. Routes to op_undo; replays
;          DELETE — buffer back to "abc", cursor=1, undo cleared,
;          count_accumulator consumed.
;
;          Assert: post-5 — count_accumulator = 5.
;          Assert: post-u — buffer="abc"; cursor=1; buffer_dirty=1;
;          undo_kind=EMPTY; count_accumulator=0 (consumed per AC9).
;
;          Pins: AC9 — counted `u` is single-level; count discarded
;          via parser_clear; no second/third replay happens.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE8 — failure (B = sub-code: 0=count_accumulator post-5,
;          1=buffer, 2=cursor, 3=buffer_dirty, 4=undo_kind,
;          5=count_accumulator post-u)
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

    ;; --- First dispatch: '5' ---
    LD      A, '5'
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key

    ;; Verify count_accumulator = 5 (16-bit).
    LD      HL, (count_accumulator)
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_count_5
    LD      B, 0
    LD      A, 0xE8
    JP      test_fail
.ok_count_5:

    ;; --- Second dispatch: 'u' ---
    LD      A, 'u'
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key

    ;; --- Post-u assertions ---
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
    LD      B, 1
    LD      A, 0xE8
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
    LD      B, 2
    LD      A, 0xE8
    JP      test_fail
.ok_cursor:

    ;; buffer_dirty = 1
    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, 3
    LD      A, 0xE8
    JP      test_fail
.ok_dirty:

    ;; undo_kind = EMPTY (consumed)
    LD      A, (undo_kind)
    OR      A
    JR      Z, .ok_undo_kind
    LD      B, 4
    LD      A, 0xE8
    JP      test_fail
.ok_undo_kind:

    ;; count_accumulator = 0 (consumed per AC9 — counted u ignored,
    ;; parser_clear discards the pending count).
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count_consumed
    LD      B, 5
    LD      A, 0xE8
    JP      test_fail
.ok_count_consumed:

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
