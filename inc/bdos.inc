; ============================================================
; Module: bdos.inc
; Purpose: BDOS function codes and the BDOS_CALL macro — the
;          project-wide gateway for every BDOS interaction
;          (AR15 / MC6 / NFR8: no raw CALL 0x0005 anywhere).
;          Populated in Story 1.4.
;
; Public:
;   (none yet — populated in Story 1.4; will export BDOS_CALL macro
;    and BDOS_* function-code equates)
;
; State owned (read/write):
;   (none)
;
; Register conventions (across public entry points):
;   (n/a — BDOS_CALL macro will document its own register contract)
;
; Dependencies:
;   inc/equates.inc  (will be required once content lands)
; ============================================================
