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
;   Yank kinds:      KIND_CHAR, KIND_LINE, KIND_BLOCK (Story 2.10)
;   COMMAND submode: CMD_SUB_EX, CMD_SUB_SEARCH (Story 3.1)
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
                                    ; Length byte is 8-bit; bumping the
                                    ; equate past 255 breaks the
                                    ; CP EX_COMMAND_BUFFER check in
                                    ; exline_append_literal (silent wrap).
    ASSERT EX_COMMAND_BUFFER < 256
SEARCH_PATTERN_BUFFER EQU 64      ; Last-search pattern buffer (bytes)
                                    ; Length byte is 8-bit; same wrap
                                    ; risk as EX_COMMAND_BUFFER if this
                                    ; were ever bumped past 255 (the
                                    ; search_commit / search_forward_from
                                    ; length reads use A).
    ASSERT SEARCH_PATTERN_BUFFER < 256
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
ESC_TIMEOUT_TICKS     EQU 2       ; 60 Hz tick window for Esc/arrow disambiguation (RI5/NFR4)
                                  ; Rate confirmed against MicroBeast BIOS 1.6+ in
                                  ; Story 1.12 (W1) — the BIOS's user-ISR hook fires
                                  ; every 1/60 s, not the 50 Hz the architecture
                                  ; originally assumed. 2 ticks ≈ 33 ms; NFR4 target
                                  ; 20-40 ms still holds.
                                  ; Must be > 0: LD B, 0 + DJNZ wraps to 256
                                  ; iterations (~4.3 s), inverting the intent of
                                  ; "skip the window" — guard at build time.
    ASSERT ESC_TIMEOUT_TICKS > 0

;; --- Editing knobs ---
INDENT_BYTE           EQU 0x20    ; ASCII space — byte inserted/removed by >, <, >>, << (Stories 2.11, 3.7; readiness item #6)

;; --- Yank register kinds (SR6 — Story 2.10) ---
; 1-byte discriminator stored in yank_kind (state.inc:54). The 0x00 /
; 0x01 / 0x02 numeric form was chosen over the 'C'/'L'/'B' ASCII form
; because: (a) init_cold_start's LDIR zero-fill leaves yank_kind = 0
; pre-first-yank, so KIND_CHAR = 0 makes an uninitialised register
; read as the natural default (character-wise, the most common kind);
; (b) the smallest 3-value space (3 byte equates, no inline constants
; for the values when paste-time-dispatch on yank_kind lands in Story
; 2.12). Story 2.10 writes KIND_LINE only (dd / yy); Story 2.11
; (dw / d$ / c5w / y3j) introduces KIND_CHAR usage; Epic 3 visual-
; block introduces KIND_BLOCK. Past 256 kinds the 1-byte form runs
; out — plenty of headroom.
KIND_CHAR             EQU 0x00    ; character-wise yank (Story 2.11 dw/d$/c5w/y3j)
KIND_LINE             EQU 0x01    ; line-wise yank (Story 2.10 dd/yy — THIS STORY introduces)
KIND_BLOCK            EQU 0x02    ; block-wise yank (Epic 3 visual-block; reserved)

;; --- Undo register kinds (FR45 — Story 2.13) ---
; 1-byte discriminator stored in undo_kind (state.inc). 5 valid kinds plus
; TOO_LARGE. See src/undo.asm for the per-kind record + replay protocols.
; Cold-start undo_kind = 0 (UNDO_KIND_EMPTY) per init.asm's LDIR zero-fill,
; so the first u after boot reports msg_nothing_to_undo. Q6 Option B
; (Story 2.13 dev pin) ships dedicated INDENT_WALK / DEDENT_WALK kinds —
; full indent/dedent undo coverage (with a documented vi-divergence for
; dedent of lines that had no leading INDENT_BYTE: replay re-indents them,
; producing an extra space; recoverable by manual dedent).
UNDO_KIND_EMPTY        EQU 0x00   ; cold-start / post-u consumed — nothing to replay
UNDO_KIND_INSERT       EQU 0x01   ; inverse-op = delete (insert sessions, paste)
UNDO_KIND_DELETE       EQU 0x02   ; inverse-op = insert (x, dd, dw, indent)
UNDO_KIND_REPLACE      EQU 0x03   ; inverse-op = delete-then-insert (cw via two-phase upgrade)
UNDO_KIND_TOO_LARGE    EQU 0x04   ; recorded but exceeds payload capacity — replay refuses
UNDO_KIND_INDENT_WALK  EQU 0x05   ; inverse-op = dedent walk over [position, position+length)
UNDO_KIND_DEDENT_WALK  EQU 0x06   ; inverse-op = indent walk over [position, position+length)
UNDO_PAYLOAD_SIZE      EQU UNDO_BUFFER_SIZE   ; alias — self-documenting payload-size refs

;; --- COMMAND-mode submode discriminator (Story 3.1) ---
; 1-byte discriminator stored in command_submode (state.inc). Sibling
; cluster to KIND_* and UNDO_KIND_*. CMD_SUB_EX = 0 is the natural
; cold-start default (init_cold_start's LDIR zero-fill leaves 0 here),
; so the first `:` after boot reads CMD_SUB_EX and routes through the
; established exline path. CMD_SUB_SEARCH = 1 is set by search_begin
; on `/` entry and cleared by exline_cancel_core on every COMMAND →
; NORMAL return. exline_compose_status branches on this to pick the
; `/` vs `:` prefix glyph; exline_dispatch branches on it to route
; Enter to search_commit instead of the ex-command table walk.
CMD_SUB_EX             EQU 0x00   ; the `:` (ex command) prompt
CMD_SUB_SEARCH         EQU 0x01   ; the `/` (search) prompt

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
