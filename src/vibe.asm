; ============================================================
; Module: vibe.asm
; Purpose: Top-level entry point for VIBE. The RET stub at 0x0100
;          stays in place until Story 1.12 lands init/teardown;
;          the INCLUDE block grows over Stories 1.5+ as production
;          modules arrive.
;
; Public:
;   input_loop   ; Story 1.5 stub abort target — bdos_error_funnel
;                ; JPs here. Story 1.8 replaces the body with the
;                ; real input-loop top-of-frame.
;
; State owned (read/write):
;   (declared in inc/state.inc; not yet read or written by code)
;
; Register conventions (across public entry points):
;   (none yet — entry from CCP at 0x0100 with default CP/M state)
;
; Dependencies:
;   inc/equates.inc, inc/bios.inc, inc/bdos.inc, inc/vt52.inc,
;   inc/modes.inc, inc/state.inc; src/statusln.asm (Story 1.5);
;   src/gapbuf.asm (Story 1.7)
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

;; --- Status-line module (MC5; statusln.asm — Story 1.5) ---
; statusln.asm INCLUDEs here so its emitted code lands after the
; RET stub at 0x0100 and before state.inc anchors the static map
; past code. Per AR25 module include order: statusln is "early —
; depended on by everything" (architecture line 939).
    INCLUDE "statusln.asm"

;; --- Gap-buffer module (AR14; gapbuf.asm — Story 1.7) ---
; AR25 order: statusln (load early — depended on by everything)
; -> gapbuf (architecture line 940). Production callers of
; gapbuf_init arrive in Story 1.12 (init/teardown); the RET stub
; at 0x0100 stays in place until then. Tests in test/cases/gapbuf_*
; exercise the primitives standalone.
    INCLUDE "gapbuf.asm"

;; --- Input-loop abort target (Story 1.5 stub; Story 1.8 owns) ---
; bdos_error_funnel JPs here after writing its status message.
; Story 1.5: stub that warm-boots back to CCP via BDOS_EXIT — a
; clean exit when the editor cannot continue (NFR5: no crash).
; Story 1.8 replaces this body with the real input-loop top of
; frame (read a key, dispatch, render, repeat) so the editor
; recovers from a BDOS error rather than exiting.
input_loop:
    BDOS_CALL BDOS_EXIT
    RET                     ; defensive — BDOS_EXIT never returns
                            ; on a real CP/M host

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
