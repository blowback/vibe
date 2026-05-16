; ============================================================
; Module: test/cases/parser_5dd-counted-via-parser-handle-operator.asm
; Purpose: AC3 + AC1 — drive `5dd` via the full count-then-op-twice
;          chain. Pre-load `"a\nb\nc\nd\ne"` (9 B), cursor=0; pre-
;          set count_accumulator=5 (simulating prior digit accumulation
;          for '5'); two 'd' presses. The first 'd' stores
;          pending_operator while count_accumulator is preserved
;          (parser.asm:336-337). The second 'd' routes through
;          parser_doubled_operator_stub → op_dd, which reads count=5
;          via motion_apply_count BEFORE tail-JP parser_clear (the
;          state-read-before-clear discipline flagged in
;          deferred-work.md:93-94 / Story 2.6 motion_gg precedent).
;
;          Assert: buffer empty (5dd on a 5-line file → all 5 lines
;          deleted via the BH2 EOF clamp); yank_length=9
;          ("a\nb\nc\nd\ne"); count_accumulator=0 post-call.
;
;          A regression that factored parser_clear into a common
;          prelude BEFORE op_dd would deliver count=0 → defaulted to
;          1 → only the first line deleted; this test would catch
;          that regression at the yank_length / buffer-state checks.
;
; AC reference: AC1 (dispatcher) + AC3 (counted form + BH2 EOF
;          clamp) + the cross-cut state-read-before-clear invariant.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — buffer not empty (count was dropped — only 1 line deleted)
;   0x81 — yank_length != 9
;   0x82 — count_accumulator != 0
;   0x83 — buffer_dirty != 1 (5dd is a mutation; edits_dirty_and_redraw must run)
;   0x84 — yank_kind != KIND_LINE
;
; Code review patch (2026-05-16): added buffer_dirty + yank_kind
; assertions. A regression that skipped edits_dirty_and_redraw or
; wrote yank_kind=KIND_CHAR (e.g., forgot the KIND_LINE assignment
; in edits_copy_to_yank) would otherwise pass the original 3 sentinels.
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
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 9
    LDIR
    LD      HL, GAP_BUFFER_BASE + 9
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    ;; Pre-seed count_accumulator = 5 (simulating prior parser_handle_digit).
    LD      HL, 5
    LD      (count_accumulator), HL

    ;; Two 'd' presses through parser_handle_operator.
    LD      A, 'd'
    CALL    parser_handle_operator
    LD      A, 'd'
    CALL    parser_handle_operator

    LD      HL, 0
    CALL    motion_byte_at_logical
    JR      C, .ok_empty
    LD      B, A
    LD      A, 0x80
    JP      test_fail
.ok_empty:

    LD      HL, (yank_length)
    LD      DE, 9
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_length
    LD      HL, (yank_length)
    LD      B, L
    LD      A, 0x81
    JP      test_fail
.ok_length:

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0x82
    JP      test_fail
.ok_count:

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0x83
    JP      test_fail
.ok_dirty:

    LD      A, (yank_kind)
    CP      KIND_LINE
    JR      Z, .ok_kind
    LD      B, A
    LD      A, 0x84
    JP      test_fail
.ok_kind:

    JP      test_pass

.payload:
    DEFB    "a", 0x0A, "b", 0x0A, "c", 0x0A, "d", 0x0A, "e"

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

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
