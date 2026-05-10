; ============================================================
; Module: test/inc/test_input_loop_stub.inc
; Purpose: Local `input_loop` symbol for headless test cases
;          that INCLUDE `src/statusln.asm`. statusln's
;          `bdos_error_funnel` ends with `JP input_loop`, which
;          is defined in `src/vibe.asm`; tests do not INCLUDE
;          vibe.asm (it has its own ORG 0x0100 + INCLUDE chain),
;          so the symbol must resolve locally.
;
;          The stub is unreached on a green run for any pure-
;          memory module under test (gap buffer is AR15-clean —
;          it never invokes BDOS_CALL, so bdos_error_funnel is
;          never entered). It exists purely so the linker
;          resolves the symbol. If a regression caused control
;          to reach this stub, the test would silently warm-boot
;          back to CCP — the `unknown` harness path would surface
;          it (no PASS/FAIL token on stdout).
;
;          Pattern mirrors `test/smoke/statusln_smoke.asm` lines
;          185-221, hoisted here to prevent drift across the five
;          gapbuf test cases.
;
; Dependencies:
;   inc/bdos.inc  (BDOS_EXIT, BDOS_ENTRY)
; ============================================================

input_loop:
    LD      C, BDOS_EXIT
    CALL    BDOS_ENTRY
    RET
