; ============================================================
; Module: vt52.inc
; Purpose: VT52 escape-sequence equates and macros — cursor
;          addressing, clear-to-EOL, reverse video. Single source
;          of truth for the VT52 command surface VIBE uses.
;          Populated in Story 1.2.
;
; Public:
;   VT52_ESC, VT52_CURSOR_HOME, VT52_CLEAR_SCREEN,
;   VT52_ERASE_TO_EOL, VT52_GOTO, VT52_COORD_BIAS
;
; State owned (read/write):
;   (none)
;
; Register conventions (across public entry points):
;   (n/a)
;
; Dependencies:
;   inc/equates.inc
; ============================================================

;; --- VT52 control codes ---
VT52_ESC          EQU 0x1B
VT52_CURSOR_HOME  EQU 'H'   ; ESC H
VT52_CLEAR_SCREEN EQU 'J'   ; ESC J
VT52_ERASE_TO_EOL EQU 'K'   ; ESC K
VT52_GOTO         EQU 'Y'   ; ESC Y row+VT52_COORD_BIAS col+VT52_COORD_BIAS

;; --- VT52 coordinate bias ---
; ESC Y addresses the cursor with row and col bytes biased by 0x20
; ('SPACE') so the bytes land in the printable ASCII range. Render
; sites add this to a 0-based row/col before emitting the sequence.
VT52_COORD_BIAS   EQU 0x20
