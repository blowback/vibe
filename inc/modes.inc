; ============================================================
; Module: modes.inc
; Purpose: Editor mode IDs (NORMAL, INSERT, COMMAND, VISUAL_*)
;          and any mode-related compile-time constants used by
;          dispatch / parser / render. Populated in Story 1.2.
;
; Public:
;   Editor modes:     MODE_NORMAL, MODE_INSERT, MODE_COMMAND, MODE_VISUAL
;   Visual sub-modes: VIS_CHAR, VIS_LINE, VIS_BLOCK
;   Synth keycodes:   KEY_ARROW_UP, KEY_ARROW_DOWN, KEY_ARROW_LEFT, KEY_ARROW_RIGHT
;
; State owned (read/write):
;   (none — mode IDs are constants; current_mode lives in state.inc)
;
; Register conventions (across public entry points):
;   (n/a)
;
; Dependencies:
;   inc/equates.inc
; ============================================================

;; --- Editor modes ---
MODE_NORMAL    EQU 0       ; Default — motions and operators
MODE_INSERT    EQU 1       ; Text entry — keys append to gap buffer
MODE_COMMAND   EQU 2       ; Ex command line — ':' typed in normal mode
MODE_VISUAL    EQU 3       ; Selection active — sub-mode in vis_submode

;; --- Visual sub-modes (only valid when MODE_VISUAL active) ---
VIS_CHAR       EQU 0       ; Character-wise selection
VIS_LINE       EQU 1       ; Line-wise selection
VIS_BLOCK      EQU 2       ; Block (rectangular) selection

;; --- Synthesized arrow keycodes (V1 / RI5) ---
; Arrow keys are synthesized by the input layer (Story 1.8) from
; ESC A / ESC B / ESC C / ESC D sequences. Codes are placed above
; ASCII (0x00..0x7F) so the mode-dispatch tables (MC3) can binary-
; search 1-byte keys without arrow keys colliding with any printable
; or control character that real keystrokes can produce.
KEY_ARROW_UP    EQU 0x80   ; ESC A
KEY_ARROW_DOWN  EQU 0x81   ; ESC B
KEY_ARROW_LEFT  EQU 0x82   ; ESC D
KEY_ARROW_RIGHT EQU 0x83   ; ESC C
