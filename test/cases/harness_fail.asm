; ============================================================
; Module: test/cases/harness_fail.asm
; Purpose: Demo case — always fails with a specific code so
;          the harness's fail-detection path is exercised
;          (TH1 sentinel != 0, stdout contains "FAIL").
; ============================================================
    INCLUDE "../inc/test_prologue.inc"

    ; Body: load fail-code 0xE1 ("demo failure") and context
    ; byte 0xC0 ("constant"), then jump to the fail branch.
    LD      A, 0xE1
    LD      B, 0xC0
    JP      test_fail

    INCLUDE "../inc/test_epilogue.inc"
