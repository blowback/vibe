; ============================================================
; Module: test/cases/parser_doubled-operator-dd.asm
; Purpose: AC5, AC6 (Story 1.10) — verify parser_handle_operator
;          first-press / doubled-press / last-wins semantics.
;
;          STORY 2.10 UPDATE: the Story-1.10 stub
;          parser_doubled_operator_stub was rewritten as a real
;          dispatcher routing to op_dd / op_yy / msg_not_implemented
;          (c/>/<). With an INITIALISED empty gap buffer, op_dd /
;          op_yy hit the 0-byte guard and JP parser_clear silently
;          — so the doubled-press path no longer SETS status_dirty
;          (it used to, when the stub surfaced msg_not_implemented).
;          The Subtest 2 / 3 / 5 assertions on status_dirty are
;          dropped accordingly. The parser-state-cleared assertions
;          (pending_operator / count_accumulator /
;          pending_motion_prefix all 0 post-dispatch) are unchanged —
;          op_dd / op_yy tail-JP parser_clear, which is the load-
;          bearing post-dispatch invariant. The c/>/< fall-through
;          surfaces "not yet implemented" via a separate test
;          (parser_doubled-operator-routes-to-not-implemented.asm).
;
; AC reference: AC5, AC6, AC12 (story 1.10); AC1 (story 2.10).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — first 'd' did not set pending_operator = 'd'
;   0xE2 — first 'd' modified count_accumulator (must stay 0)
;   0xE3 — first 'd' set status_dirty (it must NOT — no dispatch)
;   0xE5 — second 'd' left pending_operator nonzero
;   0xE6 — second 'd' left count_accumulator nonzero
;   0xE7 — second 'd' left pending_motion_prefix nonzero
;   0xE8 — 'yy' did not zero pending_operator
;   0xE9 — 'd' then 'y' did not leave pending_operator = 'y'
;          (last-operator-wins; doubled-detection saw d != y)
;   0xEA — 'd' then 'y' set status_dirty (it must NOT)
;   0xEC — 'yy' left pending_motion_prefix nonzero (parser_clear
;          did not run after the dispatch)
;   0xEE — 'dyy' left pending_operator nonzero (parser_clear must
;          have run after the yy dispatch)
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

    ;; Pre-zero parser state and status_dirty.
    LD      HL, 0
    LD      (count_accumulator), HL
    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (status_dirty), A
    LD      (buffer_dirty), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; Initialise gap buffer to empty (Story 2.10 — op_dd / op_yy
    ;; need real gap-buffer state; without this the doubled-op
    ;; dispatch walks uninitialised memory looking for an LF and
    ;; would trigger a 32 KB yank-too-large false positive).
    CALL    gapbuf_init

    ;; Subtest 1: first 'd' sets pending_operator.
    LD      A, 'd'
    CALL    parser_handle_operator

    LD      A, (pending_operator)
    CP      'd'
    JR      Z, .ok1a
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok1a:
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok1b
    LD      B, L
    LD      A, 0xE2
    JP      test_fail
.ok1b:
    LD      A, (status_dirty)
    OR      A
    JR      Z, .ok1c
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok1c:

    ;; Subtest 2: second 'd' routes through the dispatcher to
    ;; op_dd. With the gap buffer empty, op_dd's 0-byte guard
    ;; fires and JPs parser_clear silently (no status surface).
    ;; (pending_operator is already 'd' from Subtest 1.)
    LD      A, 'd'
    CALL    parser_handle_operator

    LD      A, (pending_operator)
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
    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok2d
    LD      B, A
    LD      A, 0xE7
    JP      test_fail
.ok2d:

    ;; Subtest 3: 'yy' variant — second 'y' routes through the
    ;; dispatcher to op_yy. With the gap buffer empty, op_yy's
    ;; 0-byte guard fires and JPs parser_clear silently.
    ;; Verify two post-conditions: pending_operator cleared and
    ;; pending_motion_prefix cleared (parser_clear ran completely,
    ;; not just on pending_operator).
    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (status_dirty), A
    LD      A, 'y'
    CALL    parser_handle_operator
    LD      A, 'y'
    CALL    parser_handle_operator
    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok3a
    LD      B, A
    LD      A, 0xE8
    JP      test_fail
.ok3a:
    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok3c
    LD      B, A
    LD      A, 0xEC
    JP      test_fail
.ok3c:

    ;; Subtest 4: 'd' then 'y' is NOT doubled (last-operator-wins).
    XOR     A
    LD      (pending_operator), A
    LD      (status_dirty), A
    LD      A, 'd'
    CALL    parser_handle_operator
    LD      A, 'y'
    CALL    parser_handle_operator
    LD      A, (pending_operator)
    CP      'y'
    JR      Z, .ok4a
    LD      B, A
    LD      A, 0xE9
    JP      test_fail
.ok4a:
    LD      A, (status_dirty)
    OR      A
    JR      Z, .ok4b
    LD      B, A
    LD      A, 0xEA
    JP      test_fail
.ok4b:

    ;; Subtest 5: 'dyy' — last-operator-wins makes 'd' then 'y'
    ;; store 'y' (Subtest 4 already verified that); the second 'y'
    ;; then matches pending_operator='y' and dispatches op_yy via
    ;; the doubled path. This locks in the documented "stale-
    ;; pending-operator → last-operator-wins → doubled triggers on
    ;; the LATEST operator" sharp edge. A regression that made
    ;; first-operator-sticks would leave pending_operator='d' and
    ;; the second 'y' would mismatch (storing 'y' on the first-
    ;; operator path), so pending_operator would still equal 'y'
    ;; (parser_clear would NOT run; 0xEE would catch it).
    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (status_dirty), A
    LD      A, 'd'
    CALL    parser_handle_operator
    LD      A, 'y'
    CALL    parser_handle_operator
    LD      A, 'y'
    CALL    parser_handle_operator
    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok5b
    LD      B, A
    LD      A, 0xEE
    JP      test_fail
.ok5b:

    JP      test_pass

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
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"     ; Story 2.8: dispatch_normal forward-references edits_*, dispatch_insert table grows, unbound_insert tail-JPs edits_insert_literal
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

;; ----- input_loop stub (resolves bdos_error_funnel symbol) -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST (positional anchor: static_data_base = $) -----
    INCLUDE "../../inc/state.inc"
