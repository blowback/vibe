; ============================================================
; Module: test/inc/test_epilogue.inc
; Purpose: Standard exit boilerplate for a headless test case.
;          Provides `test_pass:` and `test_fail:` labels that
;          emit a recognisable line on stdout (consumed by
;          test/Makefile to determine pass/fail per case) and
;          terminate the program via BDOS function 0.
;
; Public:
;   test_pass    ; jump here when the test body succeeded
;   test_fail    ; jump here with A = fail-code, B = context
;
; Stdout contract (consumed by test/Makefile's grep):
;   pass: "PASS"            (exact, terminated by $ for BDOS fn 9)
;   fail: "FAIL <fc> <ctx>"  (FAIL token, then space, then the
;                             fail-code as 2 hex chars, then space,
;                             then context byte as 2 hex chars,
;                             terminated by $).
;   The harness greps for the "FAIL" / "PASS" tokens; the trailing
;   hex codes surface the TH1 sentinel pair via stdout (iz-cpm has
;   no RAM-dump flag — stdout is the only post-run channel from
;   the test to the host).
;
; AR15 carve-out:
;   The test scaffold uses raw `CALL 0x0005` / `JP 0x0005`
;   rather than the production `BDOS_CALL` macro. Two reasons:
;     (1) tests do not link the production `BDOS_CALL` macro
;         body (which references `bdos_error_funnel`, a symbol
;         in src/statusln.asm — pulling that into every test
;         case is excess scope);
;     (2) CP/M BDOS function 9 (print-$-terminated-string) is
;         used here to emit the PASS / FAIL line, and function
;         9 is deliberately excluded from the production NFR15
;         function-number enumeration in inc/bdos.inc (the
;         editor uses BIOS-direct console for emission).
;   AR15 applies to src/* and inc/* (production code). Tests
;   under test/cases/ and test/inc/ are explicitly exempt.
;
; Dependencies:
;   inc/test_prologue.inc  (TEST_RESULT, TEST_CONTEXT)
; ============================================================

test_pass:
    XOR     A
    LD      (TEST_RESULT), A           ; sentinel = 0 (pass)
    LD      (TEST_CONTEXT), A          ; clear context too (post-mortem invariant: pass = both bytes 0)
    LD      DE, .pass_msg
    LD      C, 9                       ; BDOS print-string
    CALL    0x0005
    LD      C, 0                       ; BDOS exit
    JP      0x0005
.pass_msg:
    DEFB    "PASS$"

; Caller convention: A = fail-code, B = context.
; Order matters — store A to (TEST_RESULT) BEFORE LD A, B
; overwrites it; only then move B into A and store to (TEST_CONTEXT).
test_fail:
    LD      (TEST_RESULT), A           ; A = fail-code
    LD      A, B
    LD      (TEST_CONTEXT), A          ; B = context

    ; Patch hex codes into .fail_msg before emitting it.
    LD      A, (TEST_RESULT)
    LD      HL, .fail_buf_fc
    CALL    .write_hex_byte
    LD      A, (TEST_CONTEXT)
    LD      HL, .fail_buf_ctx
    CALL    .write_hex_byte

    LD      DE, .fail_msg
    LD      C, 9                       ; BDOS print-string
    CALL    0x0005
    LD      C, 0                       ; BDOS exit
    JP      0x0005

; A = byte to convert; HL = destination (2 bytes written).
; Trashes A, F, HL.
.write_hex_byte:
    PUSH    AF
    RRCA
    RRCA
    RRCA
    RRCA
    AND     0x0F
    CALL    .nibble_to_char
    LD      (HL), A
    INC     HL
    POP     AF
    AND     0x0F
    CALL    .nibble_to_char
    LD      (HL), A
    RET

; A (low nibble) -> ASCII '0'-'9' or 'A'-'F'. Trashes A, F.
.nibble_to_char:
    CP      10
    JR      C, .nc_digit
    ADD     A, 'A' - 10 - '0'
.nc_digit:
    ADD     A, '0'
    RET

.fail_msg:
    DEFB    "FAIL "
.fail_buf_fc:
    DEFB    "00 "
.fail_buf_ctx:
    DEFB    "00$"
