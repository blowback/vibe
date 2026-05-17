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
;                   pending_motion_prefix, pending_motion_inclusive,
;                   input_held_byte, input_held_flag
;   16-bit state:   cursor_offset, gap_start, gap_end,
;                   visual_anchor, count_accumulator,
;                   yank_length, top_line_offset,
;                   input_tick_counter
;   Buffers:        status_buffer, search_pattern, ex_buffer,
;                   ex_buffer_text, filename_buffer, shadow_buffer,
;                   dirty_rows, undo_buffer
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
; pending_motion_inclusive — 1-byte flag set by motion handlers whose
; landing offset is INCLUSIVE (cursor lands ON the last byte of the
; range, not one-past-the-last). Story 2.11: only motion_dollar writes
; A=1 here (its landing is the last printable byte of the line). Read
; and cleared by op_compose_d / op_compose_y / op_compose_c via the
; parser_clear tail (parser_clear zeroes this cell alongside the other
; pending_* fields — cleared centrally so the cleanup is shared across
; all five per-operator bodies). Future inclusive motions (e, f, t, %)
; will set the flag the same way. KIND_BLOCK / line-class operators do
; NOT touch it.
pending_motion_inclusive EQU static_data_base + static_off
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
; input_tick_counter — 16-bit counter incremented by the user ISR
; installed in src/init.asm at cold-start (resolves the Story 1.4 W1
; tick-counter deferral via MBB_SET_USR_INT; see inc/bios.inc).
; Writer: src/input.asm's input_tick_isr (every 1/60 s).
; Reader: src/input.asm's tick_wait_one (Esc / arrow disambig).
; Cleared to zero by init.asm's cold-start LDIR fill; uninstalled by
; init_teardown before warm-boot. Wraps 0xFFFF -> 0x0000 every
; ~18 min at 60 Hz — tick_wait_one uses unsigned SBC HL,DE delta so
; the wrap is transparent.
input_tick_counter    EQU static_data_base + static_off
static_off            =   static_off + 2

;; --- Undo register header (Story 2.13; FR45 / FR46) ---
; 7 bytes of header for the single-level undo entry. The 256-byte
; payload slot (undo_buffer) is declared further down with the
; other buffers — physically separate, deliberately so static_off
; growth (this header) is small. Cold-start undo_kind = 0
; (UNDO_KIND_EMPTY) via init_cold_start's LDIR zero-fill, so the
; first u after boot reports msg_nothing_to_undo (FR46). See
; src/undo.asm for per-kind layout semantics:
;   undo_kind: UNDO_KIND_EMPTY / _INSERT / _DELETE / _REPLACE /
;              _TOO_LARGE / _INDENT_WALK / _DEDENT_WALK.
;   undo_position: 16-bit logical offset where the inverse op acts.
;   undo_length: 16-bit byte count — meaning per kind (INSERT: bytes
;                to remove on replay; DELETE: bytes to re-insert from
;                payload; REPLACE: new-content bytes to remove; INDENT/
;                DEDENT_WALK: span of [position, position+length) the
;                inverse walk iterates).
;   undo_aux_length: 16-bit; REPLACE-only — bytes to re-insert (old
;                    content saved in undo_buffer).
undo_kind             EQU static_data_base + static_off
static_off            =   static_off + 1
undo_position         EQU static_data_base + static_off
static_off            =   static_off + 2
undo_length           EQU static_data_base + static_off
static_off            =   static_off + 2
undo_aux_length       EQU static_data_base + static_off
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
; Resolves Story-1.3 deferral on ex_buffer length-byte naming
; convention (deferred-work.md). Positional EQU only — no
; static_off advance, no bytes emitted. The sibling
; search_pattern_text lands in Story 3.1 when search consumers
; arrive (deliberately deferred to avoid an unused symbol now).
ex_buffer_text        EQU ex_buffer + 1
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
