; ============================================================
; Module: test/inc/test_prologue.inc
; Purpose: Standard entry boilerplate for a headless test case.
;          Defines the TH1 sentinel addresses (0xCFFE pass code,
;          0xCFFF context byte), pre-zeroes both so post-run
;          inspection sees a deterministic value (not boot
;          residue), and lands the program at the CP/M .com
;          entry address 0x0100.
;
; Public:
;   TEST_RESULT     EQU 0xCFFE   ; pass code (0 = pass, !=0 = fail)
;   TEST_CONTEXT    EQU 0xCFFF   ; optional context byte
;   test_start                   ; INCLUDEing test falls through here
;
; State owned (read/write):
;   (none — the sentinel pair is the only RAM this file touches,
;    and only the entry boilerplate writes them; the test_pass /
;    test_fail epilogue rewrites them on exit)
;
; Dependencies:
;   (none — leaf for the test scaffold; production inc/*.inc are
;    NOT INCLUDEd here. The test case decides which production
;    headers it needs.)
; ============================================================

TEST_RESULT     EQU 0xCFFE
TEST_CONTEXT    EQU 0xCFFF

    ORG 0x0100
test_start:
    XOR     A
    LD      (TEST_RESULT), A
    LD      (TEST_CONTEXT), A
    ; Test body follows after this INCLUDE.
