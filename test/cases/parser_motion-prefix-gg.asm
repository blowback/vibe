; ============================================================
; Module: test/cases/parser_motion-prefix-gg.asm
; Purpose: AC7, AC8 — verify parser_handle_motion_prefix:
;            - First 'g' (no prior prefix) sets
;              pending_motion_prefix = 'g'. count_accumulator
;              and pending_operator unchanged. No handler fires.
;            - Second 'g' (pending_motion_prefix already 'g')
;              dispatches motion_gg (Story 2.6 — replaced the
;              parser_gg_motion_stub). motion_gg with no count
;              moves cursor to 0 and tail-JPs parser_clear:
;              all three parser-state fields are 0 afterward,
;              cursor_offset == 0.
;            - Count carries across the prefix: '5g' leaves
;              count_accumulator = 5 AND pending_motion_prefix
;              = 'g'; the subsequent 'g' (doubled) fires
;              motion_gg with count=5 → cursor to start of
;              line 5 (clamped to last line for our buffer);
;              count goes back to 0.
;
; AC reference: AC7, AC8, AC12 (story 1.10) + Story 2.6 AC7.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — first 'g' did not set pending_motion_prefix = 'g'
;   0xE2 — first 'g' set status_dirty (it must NOT — no handler)
;   0xE3 — first 'g' modified count_accumulator
;   0xE4 — second 'g' did not move cursor to 0 (motion_gg did not fire)
;   0xE5 — second 'g' left pending_motion_prefix nonzero
;   0xE6 — second 'g' left count_accumulator nonzero
;   0xE7 — second 'g' left pending_operator nonzero
;   0xE8 — Subtest 3: after '5' '5g' sequence, count != 5
;          (the prefix-press must not clobber count)
;   0xE9 — Subtest 3: after the final 'g', count != 0 (parser_clear
;          on doubled-prefix did not run)
;   B    — diagnostic byte
; ============================================================

;; --- Pre-ORG production headers (pure EQU; safe before ORG) ---
    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----

    ;; Pre-zero parser state and status_dirty. Pre-seed gap/cursor
    ;; for motion_gg's reads in Subtest 2.
    LD      HL, 0
    LD      (count_accumulator), HL
    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (status_dirty), A

    ;; Pre-seed gap_start so motion_gg's no-count path can compute
    ;; cursor=0 sanely (it doesn't actually read gap_start in the
    ;; no-count branch, but the with-count branch in Subtest 3 does
    ;; via motion_byte_at_logical → file_length math).
    CALL    gapbuf_init                 ; gap covers entire buffer (empty)
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 11
    LDIR
    LD      HL, GAP_BUFFER_BASE + 11
    LD      (gap_start), HL             ; 11-byte payload "line1\nline2"

    LD      HL, 8
    LD      (cursor_offset), HL         ; cursor mid-line2

    ;; Subtest 1: first 'g' sets pending_motion_prefix.
    LD      A, 'g'
    CALL    parser_handle_motion_prefix

    LD      A, (pending_motion_prefix)
    CP      'g'
    JR      Z, .ok1a
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok1a:
    LD      A, (status_dirty)
    OR      A
    JR      Z, .ok1b
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok1b:
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok1c
    LD      B, L
    LD      A, 0xE3
    JP      test_fail
.ok1c:

    ;; Subtest 2: second 'g' fires motion_gg (Story 2.6).
    ;; (pending_motion_prefix already 'g' from Subtest 1;
    ;; count_accumulator == 0 from Subtest 1 → no-count branch
    ;; → cursor moves to 0.)
    LD      A, 'g'
    CALL    parser_handle_motion_prefix

    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok2a
    LD      A, L
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok2a:
    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok2b
    LD      B, A
    LD      A, 0xE5
    JP      test_fail
.ok2b:
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok2c
    LD      B, L
    LD      A, 0xE6
    JP      test_fail
.ok2c:
    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok2d
    LD      B, A
    LD      A, 0xE7
    JP      test_fail
.ok2d:

    ;; Subtest 3: count survives across 'g' but is cleared by
    ;; the doubled-prefix dispatch.
    LD      HL, 0
    LD      (count_accumulator), HL
    XOR     A
    LD      (pending_motion_prefix), A
    LD      (status_dirty), A

    LD      A, '5'
    CALL    parser_handle_digit         ; count_accumulator = 5
    LD      A, 'g'
    CALL    parser_handle_motion_prefix ; pending_motion_prefix = 'g'

    ;; Count must still be 5 here (prefix-press must not clobber count).
    LD      HL, (count_accumulator)
    LD      A, H
    OR      A
    JR      NZ, .fail3_mid
    LD      A, L
    CP      5
    JR      Z, .ok3_mid
.fail3_mid:
    LD      B, L
    LD      A, 0xE8
    JP      test_fail
.ok3_mid:

    LD      A, 'g'
    CALL    parser_handle_motion_prefix ; doubled-g → stub + parser_clear

    ;; Count must be 0 again post-dispatch.
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok3_end
    LD      B, L
    LD      A, 0xE9
    JP      test_fail
.ok3_end:

    JP      test_pass

.payload:
    DEFB    "line1", 0x0A, "line2"      ; 11 bytes; LF at offset 5

;; ----- LOCAL init_teardown stub (Story 2.3) -----
    INCLUDE "../inc/test_teardown_stub.inc"
;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"     ; Story 2.5: dispatch_normal forward-references motion_h/j/k/l
    INCLUDE "../../src/edits.asm"     ; Story 2.8: dispatch_normal forward-references edits_*, dispatch_insert table grows, unbound_insert tail-JPs edits_insert_literal
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

;; ----- input_loop stub (resolves bdos_error_funnel symbol) -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST (positional anchor: static_data_base = $) -----
    INCLUDE "../../inc/state.inc"
