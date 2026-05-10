; ============================================================
; Module: state.inc
; Purpose: Static memory map — every mutable byte and word the
;          editor owns, declared as positional EQUs at fixed
;          addresses. The single layout that all modules
;          read/write through. Populated in Story 1.3.
;
; Public:
;   Anchors:        static_data_base, static_end, GAP_BUFFER_BASE
;   Small state:    mode_byte, visual_submode, buffer_dirty,
;                   pending_operator, yank_kind, status_dirty,
;                   pending_motion_prefix, input_held_byte,
;                   input_held_flag
;   16-bit state:   cursor_offset, gap_start, gap_end,
;                   visual_anchor, count_accumulator,
;                   yank_length, top_line_offset
;   Buffers:        status_buffer, search_pattern, ex_buffer,
;                   filename_buffer, shadow_buffer, dirty_rows,
;                   undo_buffer
;   Reserved pool:  yank_buffer, yank_end
;
; State owned (read/write):
;   (this file IS the static memory map; every cross-module
;    variable is declared here)
;
; Register conventions (across public entry points):
;   (n/a)
;
; Dependencies:
;   inc/equates.inc  (sizes come from equates)
; ============================================================

;; --- Layout anchor ---
; Capture the program counter at the INCLUDE site. With EQU-only
; declarations below, $ does NOT advance, so static_data_base is
; the first address past the preceding code.
static_data_base      EQU $
; Tripwire: if this file is INCLUDEd before ORG 0x0100 (e.g. moved
; into the pre-ORG header block), $ is 0x0000 and statics overlay
; the CP/M zero page. Catch that at build time, not on hardware.
    ASSERT static_data_base >= 0x0101
static_off            =   0         ; running offset, advanced per declaration

;; --- Single-byte / small state ---
mode_byte             EQU static_data_base + static_off
static_off            =   static_off + 1
visual_submode        EQU static_data_base + static_off
static_off            =   static_off + 1
buffer_dirty          EQU static_data_base + static_off
static_off            =   static_off + 1
pending_operator      EQU static_data_base + static_off
static_off            =   static_off + 1
yank_kind             EQU static_data_base + static_off
static_off            =   static_off + 1
status_dirty          EQU static_data_base + static_off
static_off            =   static_off + 1
pending_motion_prefix EQU static_data_base + static_off
static_off            =   static_off + 1
input_held_byte       EQU static_data_base + static_off
static_off            =   static_off + 1
input_held_flag       EQU static_data_base + static_off
static_off            =   static_off + 1

;; --- 16-bit state ---
cursor_offset         EQU static_data_base + static_off
static_off            =   static_off + 2
gap_start             EQU static_data_base + static_off
static_off            =   static_off + 2
gap_end               EQU static_data_base + static_off
static_off            =   static_off + 2
visual_anchor         EQU static_data_base + static_off
static_off            =   static_off + 2
count_accumulator     EQU static_data_base + static_off
static_off            =   static_off + 2
yank_length           EQU static_data_base + static_off
static_off            =   static_off + 2
top_line_offset       EQU static_data_base + static_off
static_off            =   static_off + 2

;; --- Buffers ---
; Each size sourced from inc/equates.inc per NFR16 (no magic
; numbers here). search_pattern and ex_buffer reserve 1 length
; byte + raw payload bytes (architecture lines 1375-1378).
status_buffer         EQU static_data_base + static_off
static_off            =   static_off + STATUS_LINE_WIDTH
search_pattern        EQU static_data_base + static_off
static_off            =   static_off + 1 + SEARCH_PATTERN_BUFFER
ex_buffer             EQU static_data_base + static_off
static_off            =   static_off + 1 + EX_COMMAND_BUFFER
filename_buffer       EQU static_data_base + static_off
static_off            =   static_off + FILENAME_BUFFER_SIZE
shadow_buffer         EQU static_data_base + static_off
static_off            =   static_off + SCREEN_ROWS * SCREEN_COLS
dirty_rows            EQU static_data_base + static_off
static_off            =   static_off + DIRTY_ROWS_BITMAP_BYTES
undo_buffer           EQU static_data_base + static_off
static_off            =   static_off + UNDO_BUFFER_SIZE

;; --- Sentinel: end of static block ---
static_end            EQU static_data_base + static_off

;; --- Gap buffer base (positional; SR2) ---
; First address past the static block. Declared here (not in
; equates.inc) because its value is a function of static_off,
; which only exists in this file.
GAP_BUFFER_BASE       EQU static_end

;; --- Yank register (reserved pool, SR6) ---
; YANK_BUFFER_SIZE (1024) bytes reserved at this address for the
; yank register. Lives past the gap buffer in the reserved pool;
; not part of the static block accounting. yank_end is the named
; past-the-end address — use it for any future "highest VIBE-owned
; address" checks rather than re-deriving yank_buffer + size.
yank_buffer           EQU GAP_BUFFER_BASE + GAP_BUFFER_MAX
yank_end              EQU yank_buffer + YANK_BUFFER_SIZE

;; --- NFR10 TPA-fit guardrail ---
; All VIBE-owned state MUST be declared ABOVE this line. The ASSERT
; covers everything from static_data_base to yank_end. Future fields
; go above this divider — never below — so the guard always covers
; the highest address.
;
; CCP/BDOS sits at 0xD800 (PC2: TPA = 0x0100..0xD7FF). If a future
; story grows code or the static block past this line, the build
; fails here, not at runtime on hardware.
    ASSERT yank_end <= 0xD800
