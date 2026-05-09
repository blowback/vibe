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
;   (declared in inc/state.inc; not yet read or written by code)
;
; Register conventions (across public entry points):
;   (none yet — entry from CCP at 0x0100 with default CP/M state)
;
; Dependencies:
;   inc/equates.inc, inc/bios.inc, inc/bdos.inc, inc/vt52.inc,
;   inc/modes.inc, inc/state.inc
; ============================================================

;; --- Compile-time-constant includes (dependency order per AR25) ---
; Pure-EQU headers that do NOT use $; safe to place before ORG.
; (state.inc is also EQU-only but DOES use $ to anchor the static
; map past code, so it is INCLUDEd after the RET, below.)
    INCLUDE "../inc/equates.inc"
    INCLUDE "../inc/bios.inc"
    INCLUDE "../inc/bdos.inc"
    INCLUDE "../inc/vt52.inc"
    INCLUDE "../inc/modes.inc"

    ORG 0x0100

    RET                     ; Stub exit: returns to warm-boot
                            ; vector at 0x0000 pushed by CCP.
                            ; Replaced by proper init/teardown
                            ; in Story 1.12.

;; --- Static memory map (positional; anchors past code) ---
; state.inc is the AR25-final include; positioned here (not in the
; pre-ORG block) so that `static_data_base EQU $` resolves to the
; first address past code, not 0x0000. EQU-only — no bytes emit.
;
; state.inc MUST be the last source emitted from vibe.asm. Anything
; below this INCLUDE would either emit bytes past static_data_base
; (overlapping declared statics with no build-time error) or land
; outside the ASSERT yank_end <= 0xD800 guard inside state.inc.
    INCLUDE "../inc/state.inc"
