; ============================================================
; Module: state.inc
; Purpose: Static memory map — every mutable byte and word the
;          editor owns, declared via DS at fixed offsets. The
;          single layout that all modules read/write through.
;          Populated in Story 1.3.
;
; Public:
;   (none yet — populated in Story 1.3; will declare gap_start,
;    gap_end, cursor_offset, current_mode, count_register, etc.)
;
; State owned (read/write):
;   (this file IS the state — all editor mutable state declared
;    here once content lands)
;
; Register conventions (across public entry points):
;   (n/a)
;
; Dependencies:
;   inc/equates.inc  (sizes / addresses come from equates)
; ============================================================
