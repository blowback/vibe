; ============================================================
; Module: test/inc/test_teardown_stub.inc
; Purpose: Local `init_teardown` symbol for headless test cases
;          that INCLUDE production modules referencing it
;          (src/exline.asm's cmd_quit / cmd_quit_force / cmd_write_quit
;          tail-JP to init_teardown; src/fileio.asm's abort and
;          load paths transitively bring exline.asm in via the
;          AR25 include chain). The production teardown lives in
;          src/init.asm which tests do NOT INCLUDE (init.asm has
;          its own ORG 0x0100 + INCLUDE chain), so the symbol must
;          resolve locally.
;
;          The stub records reach with init_teardown_called = 1
;          (initial 0), then RETs back to whatever code tail-JPed
;          here. Tests that want to assert a clean :q / :wq path
;          observed the teardown can read init_teardown_called.
;
;          Story 2.4 promoted this stub from ~21 inline duplicate
;          blocks (per deferred-work.md line 118) into this single
;          shared INCLUDE.
;
; Dependencies:
;   (none — pure assembly; the test file ORG places this at the
;    address sjasmplus computes from the surrounding test layout)
; ============================================================

init_teardown:
    LD      A, 1
    LD      (init_teardown_called), A
    RET
init_teardown_called:
    DEFB    0
