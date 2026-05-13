; ============================================================
; Module: test/cases/exline_q-clean-buffer.asm
; Purpose: AC6, AC12 — verify that `:q` on a clean buffer
;          (buffer_dirty == 0) routes exline_dispatch -> cmd_quit
;          -> init_teardown (stubbed locally so the test does
;          not actually warm-boot iz-cpm). After cmd_quit's
;          tail-JP to init_teardown, the local stub sets a
;          sentinel byte and RETs back to the test body.
;
;          Note on post-teardown state: a real run warm-boots
;          before cmd_quit's clean path inspects any further
;          state. The test mirrors the production tail-JP shape
;          (cmd_quit ends in `JP init_teardown` — no further
;          cleanup), so post-stub state is intentionally NOT
;          asserted beyond the sentinel.
;
; AC reference: AC6 (clean :q -> warm-boot), AC12 (headless
;               coverage of the exline path).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE0 — init_teardown stub was NOT called (sentinel still 0)
;   B   — diagnostic context (the observed sentinel value, for
;         the 0xE0 path B = 0; reserved for future subtests)
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

    ;; Pre-zero the local stub sentinel and the editor state
    ;; this test inspects. CP/M does NOT zero TPA, so any field
    ;; that init_cold_start would have cleared must be cleared
    ;; here explicitly (this test does NOT call init_cold_start
    ;; — it goes straight at exline_dispatch).
    XOR     A
    LD      (init_teardown_called), A
    LD      (buffer_dirty), A
    LD      (mode_byte), A              ; MODE_NORMAL = 0
    LD      (status_dirty), A

    ;; Pre-load ex_buffer = length 1, byte 'q' at ex_buffer_text.
    LD      A, 1
    LD      (ex_buffer), A
    LD      A, 'q'
    LD      (ex_buffer_text), A

    ;; Drive the dispatch. A = 0x0D (the Enter that would arrive
    ;; in production) — exline_dispatch ignores it, so the value
    ;; is illustrative.
    LD      A, 0x0D
    CALL    exline_dispatch

    ;; --- Subtest 1: init_teardown_called == 1 (clean path
    ;; reached cmd_quit's tail-JP to init_teardown) ---
    LD      A, (init_teardown_called)
    OR      A
    JR      NZ, .ok_called
    LD      B, A                        ; observed sentinel (0)
    LD      A, 0xE0
    JP      test_fail
.ok_called:

    JP      test_pass

;; ----- LOCAL init_teardown stub -----
; cmd_quit / cmd_quit_force tail-JP here in production; the test
; replaces the real init_teardown (which would warm-boot iz-cpm
; out from under the test) with this no-op-that-sets-a-flag.
; The symbol MUST be named `init_teardown` so the production
; src/exline.asm's `JP init_teardown` resolves to this stub.
; Same intercept pattern as Story 1.12's
; `init_cold_start-state-shape.asm`'s `input_loop` stub.
init_teardown:
    LD      A, 1
    LD      (init_teardown_called), A
    RET
init_teardown_called:    DEFB 0

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
; init.asm is deliberately NOT INCLUDEd — the local init_teardown
; stub above replaces it. Including init.asm would (a) re-declare
; init_teardown and break, and (b) drag in the BDOS warm-boot
; macro expansion we are explicitly trying to avoid in tests.
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/exline.asm"
    ;; Story 2.2 / 2.3 pull-forward: exline.asm now references
    ;; fileio_load + fileio_strip_leading_spaces (cmd_edit / cmd_edit_force);
    ;; INCLUDE fileio.asm to resolve those forward references at build time.
    INCLUDE "../../src/fileio.asm"

;; ----- input_loop stub (resolves bdos_error_funnel symbol) -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST (positional anchor: static_data_base = $) -----
    INCLUDE "../../inc/state.inc"
