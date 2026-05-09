; ============================================================
; Module: equates.inc
; Purpose: Compile-time constants — buffer sizes, screen geometry,
;          mode IDs, key codes, magic numbers. Single source of
;          truth for any value used across modules.
;          Populated in Story 1.2.
;
; Public:
;   Buffer sizes:    GAP_BUFFER_MAX, UNDO_BUFFER_SIZE,
;                    EX_COMMAND_BUFFER, SEARCH_PATTERN_BUFFER,
;                    YANK_BUFFER_SIZE
;   Screen geometry: SCREEN_ROWS, SCREEN_COLS, EDITABLE_ROWS,
;                    STATUS_ROW, STATUS_LINE_WIDTH
;   Input timing:    ESC_TIMEOUT_TICKS
;   Editing knobs:   INDENT_BYTE
;
; State owned (read/write):
;   (none — equates are constants only)
;
; Register conventions (across public entry points):
;   (n/a)
;
; Dependencies:
;   (none — equates.inc is the leaf of the include graph)
; ============================================================

;; --- Buffer sizes ---
; Sizes >= 256 do not fit in an 8-bit register. Consumers MUST use
; 16-bit math (HL/BC/DE) — e.g. LDIR with BC, SBC HL,DE for bounds.
; A stray LD B,UNDO_BUFFER_SIZE will silently truncate (256 -> 0).
GAP_BUFFER_MAX        EQU 32768   ; Max editable text payload (bytes) — 0x8000, see note below
UNDO_BUFFER_SIZE      EQU 256     ; Single-level undo journal (bytes) — 16-bit only
EX_COMMAND_BUFFER     EQU 64      ; Ex (:) command-line buffer (bytes)
SEARCH_PATTERN_BUFFER EQU 64      ; Last-search pattern buffer (bytes)
YANK_BUFFER_SIZE      EQU 1024    ; Yank/put register (bytes) — 16-bit only
FILENAME_BUFFER_SIZE  EQU 16      ; CP/M filename text form: drive:8.3 + NUL + slack
; GAP_BUFFER_MAX = 0x8000: high bit set in 16-bit form. Bounds compares
; against cursor offsets MUST be unsigned (SBC HL,DE + carry, or
; BIT 7,H — never JP M / JP P, which treat it as negative).

;; --- Screen geometry ---
SCREEN_ROWS           EQU 24              ; Total VT52 rows
SCREEN_COLS           EQU 80              ; Total VT52 cols
EDITABLE_ROWS         EQU SCREEN_ROWS-1   ; Text rows (status row consumes the last row)
STATUS_ROW            EQU EDITABLE_ROWS   ; Row index (0-based) of the status row
STATUS_LINE_WIDTH     EQU SCREEN_COLS     ; Status row spans the full screen width
DIRTY_ROWS_BITMAP_BYTES EQU (SCREEN_ROWS + 7) / 8  ; ceil(rows/8); auto-resizes if SCREEN_ROWS grows

;; --- Input timing ---
ESC_TIMEOUT_TICKS     EQU 2       ; 50 Hz tick window for Esc/arrow disambiguation (RI5/NFR4)

;; --- Editing knobs ---
INDENT_BYTE           EQU 0x20    ; ASCII space — byte inserted/removed by >, <, >>, << (Stories 2.11, 3.7; readiness item #6)

;; --- Notes ---
; GAP_BUFFER_BASE is intentionally NOT defined here. It is positional,
; not a knob: Story 1.3 lands it in inc/state.inc as
;   GAP_BUFFER_BASE EQU static_end
; where static_end is the first address past the EQU-only static-data
; block. The yank buffer placement at GAP_BUFFER_BASE + GAP_BUFFER_MAX
; (per SR6) follows the same pattern. Defining a placeholder here
; would either collide with state.inc's single-assignment EQU or be a
; forward reference to a label that does not yet exist. Do not "fix"
; this omission.
