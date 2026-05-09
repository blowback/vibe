; ============================================================
; Module: test/cases/harness_pass.asm
; Purpose: Demo case — always passes. Smoke-tests the
;          harness's pass-detection path (TH1 sentinel = 0,
;          stdout contains "PASS").
; ============================================================
    INCLUDE "../inc/test_prologue.inc"

    ; Body: trivially fall through to the pass branch.
    JP      test_pass

    INCLUDE "../inc/test_epilogue.inc"
