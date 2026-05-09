; ============================================================
; Module: vibe.asm
; Purpose: Top-level entry point for VIBE. Currently a stub
;          (RET-to-warm-boot) per Story 1.1. Subsequent stories
;          land equates, state, BIOS/BDOS shims, status line,
;          input layer, render pipeline and finally init/teardown
;          (Story 1.12), at which point this file gains its full
;          INCLUDE block and CALL init.
;
; Public:
;   (none yet — populated as modules arrive in later stories)
;
; State owned (read/write):
;   (none yet — Story 1.3 introduces state.inc)
;
; Register conventions (across public entry points):
;   (none yet — entry from CCP at 0x0100 with default CP/M state)
;
; Dependencies:
;   inc/equates.inc, inc/vt52.inc, inc/modes.inc
;   (bios.inc and bdos.inc arrive in Story 1.4; state.inc in 1.3)
; ============================================================

;; --- Includes (dependency order per AR25) ---
    INCLUDE "../inc/equates.inc"
    INCLUDE "../inc/vt52.inc"
    INCLUDE "../inc/modes.inc"

    ORG 0x0100

    RET                     ; Stub exit: returns to warm-boot
                            ; vector at 0x0000 pushed by CCP.
                            ; Replaced by proper init/teardown
                            ; in Story 1.12.
