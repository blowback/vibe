; ============================================================
; Module: gapbuf.asm
; Purpose: Gap-buffer primitives. Owns the SR2 two-halves
;          invariant and is the single buffer-mutation owner
;          (AR14): all edits to the gap buffer enter through
;          gapbuf_insert / gapbuf_delete / gapbuf_move_gap.
;          Pure-memory module — no BDOS, no console emit
;          (AR15: gapbuf does not invoke the BDOS entry vector
;          or the BDOS macro; AC11 grep enforces).
;
; Public:
;   gapbuf_init      - reset to empty buffer
;   gapbuf_insert    - insert byte at cursor (gap-tracks-cursor)
;   gapbuf_delete    - delete byte before cursor
;   gapbuf_move_gap  - relocate gap to a target logical offset
;   ; gapbuf_load stub retired by Story 2.2 — the load orchestration
;   ; lives in src/fileio.asm; its linear-fill phase takes a
;   ; documented AR14 carve-out (writes `gap_start` directly) and
;   ; the post-load gapbuf_move_gap(0) returns to gapbuf's
;   ; invariant-maintaining surface.
;
; State owned (read/write):
;   gap_start, gap_end, cursor_offset
;
; Register conventions (across public entry points):
;   HL = working / address scratch (cursor offset, target offset)
;   DE = working / second address scratch
;   BC = byte count for LDIR / LDDR
;   A  = working byte (input/output for insert)
;
; Dependencies:
;   inc/equates.inc  (GAP_BUFFER_MAX)
;   inc/state.inc    (GAP_BUFFER_BASE, gap_start, gap_end,
;                     cursor_offset)
;   src/statusln.asm (status_set_message — buffer-full path;
;                     msg_file_too_large)
; ============================================================

;; ============================================================
;; --- Public entry points ---
;; ============================================================

; ----------------------------------------------------------------
; gapbuf_init
; Reset to empty buffer. Establishes the SR2 two-halves invariant
; with the gap covering the full GAP_BUFFER_MAX extent and the
; cursor at logical offset 0. The buffer payload is NOT zeroed;
; bytes inside the gap are read-as-undefined and never visible
; through the two-halves walk.
;
; In:      (none)
; Out:     gap_start = GAP_BUFFER_BASE
;          gap_end   = GAP_BUFFER_BASE + GAP_BUFFER_MAX
;          cursor_offset = 0
; Trashes: HL, F
; Calls:   (none)
; ----------------------------------------------------------------
gapbuf_init:
    LD      HL, GAP_BUFFER_BASE
    LD      (gap_start), HL
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      (gap_end), HL
    LD      HL, 0
    LD      (cursor_offset), HL
    RET

; ----------------------------------------------------------------
; gapbuf_insert
; Insert byte A at cursor_offset. Calls gapbuf_move_gap if the
; gap is not already at the cursor, then writes A to (gap_start),
; advances gap_start by 1, advances cursor_offset by 1. The
; gap-tracks-cursor invariant is preserved post-mutation.
;
; In:      A = byte to insert
; Out:     CF = 0 on success; CF = 1 on buffer-full (state
;          unchanged, status_set_message called with
;          msg_file_too_large)
; Trashes: A, BC, DE, HL, F
; Calls:   gapbuf_move_gap (if gap not already at cursor),
;          status_set_message (on overflow)
; ----------------------------------------------------------------
gapbuf_insert:
    PUSH    AF                          ; preserve byte to insert across move_gap

    ;; Gap-at-cursor check: current_gap_offset ?= cursor_offset.
    ;; current_gap_offset = gap_start - GAP_BUFFER_BASE.
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE                      ; HL = current gap logical offset
    LD      DE, (cursor_offset)
    OR      A
    SBC     HL, DE                      ; HL = current - cursor_offset
    JR      Z, .gap_at_cursor
    ;; Not at cursor: relocate gap to cursor first.
    LD      HL, (cursor_offset)
    CALL    gapbuf_move_gap

.gap_at_cursor:
    ;; Buffer-full check: gap_start ?= gap_end.
    ;; SR2 invariant: gap_start <= gap_end always; equality is full.
    ;; This check MUST happen BEFORE any state write (AC4: state
    ;; unchanged on full).
    LD      HL, (gap_start)
    LD      DE, (gap_end)
    OR      A
    SBC     HL, DE
    JR      Z, .full

    ;; Insert: write byte, advance gap_start, advance cursor.
    POP     AF                          ; restore byte to insert
    LD      HL, (gap_start)
    LD      (HL), A                     ; write byte at gap_start
    INC     HL
    LD      (gap_start), HL             ; advance gap_start by 1
    LD      HL, (cursor_offset)
    INC     HL
    LD      (cursor_offset), HL         ; advance cursor by 1
    OR      A                           ; clear CF (success)
    RET

.full:
    POP     AF                          ; discard saved byte
    LD      HL, msg_file_too_large
    XOR     A                           ; non-error-code arg (AR16 convention)
    CALL    status_set_message
    SCF
    RET

; ----------------------------------------------------------------
; gapbuf_delete
; Delete the byte logically before the cursor. Calls
; gapbuf_move_gap if the gap is not already at the cursor,
; then decrements gap_start (consuming the byte just past the
; before-gap half), decrements cursor_offset. The gap-tracks-
; cursor invariant is preserved post-mutation.
;
; In:      (none — operates at cursor_offset)
; Out:     CF = 0 on success; CF = 1 at BOF (cursor_offset == 0,
;          no byte before cursor — state unchanged, no status
;          message — caller decides surface)
; Trashes: A, BC, DE, HL, F
; Calls:   gapbuf_move_gap (if gap not already at cursor)
; ----------------------------------------------------------------
gapbuf_delete:
    ;; BOF check FIRST: AC5 demands state unchanged on BOF, no
    ;; move_gap call, no decrement.
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      NZ, .not_bof
    SCF
    RET

.not_bof:
    ;; Gap-at-cursor check: current_gap_offset ?= cursor_offset.
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE                      ; HL = current gap logical offset
    LD      DE, (cursor_offset)
    OR      A
    SBC     HL, DE
    JR      Z, .gap_at_cursor
    LD      HL, (cursor_offset)
    CALL    gapbuf_move_gap

.gap_at_cursor:
    ;; Decrement gap_start (consume the byte just past the
    ;; before-gap half — the byte logically before the cursor).
    LD      HL, (gap_start)
    DEC     HL
    LD      (gap_start), HL
    ;; Decrement cursor.
    LD      HL, (cursor_offset)
    DEC     HL
    LD      (cursor_offset), HL
    OR      A                           ; clear CF (success)
    RET

; ----------------------------------------------------------------
; gapbuf_move_gap
; Relocate the gap to a target logical offset by copying bytes
; between the two halves (LDIR for right-shift, LDDR for left-
; shift). Does NOT modify cursor_offset — caller manages the
; cursor. File content (the two-halves walk byte sequence) is
; invariant under this call.
;
; In:      HL = target logical offset (0 <= HL <= file_length;
;               out-of-range targets are caller's responsibility
;               — internal callers from insert/delete pass
;               (cursor_offset), always valid by construction)
; Out:     gap_start, gap_end relocated; cursor_offset unchanged
; Trashes: A, BC, DE, HL, F
; Calls:   (none — pure memory move)
; ----------------------------------------------------------------
gapbuf_move_gap:
    ;; Compute current gap logical offset into DE.
    PUSH    HL                          ; save target
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE                      ; HL = current gap logical offset
    EX      DE, HL                      ; DE = current
    POP     HL                          ; HL = target

    ;; Compare target (HL) vs current (DE). SBC HL,DE destroys HL,
    ;; so save both for the post-branch byte-count math.
    PUSH    HL                          ; save target
    PUSH    DE                          ; save current
    OR      A
    SBC     HL, DE
    JR      Z, .equal
    JR      C, .left

;; --- Right shift: target > current ---
;; HL already holds (target - current) = byte count.
.right:
    LD      B, H
    LD      C, L                        ; BC = count
    POP     DE                          ; discard saved current
    POP     HL                          ; discard saved target
    LD      HL, (gap_end)               ; source = first byte of after-gap half
    LD      DE, (gap_start)             ; dest = first free in before-gap half
    LDIR
    ;; Post-LDIR: HL = old gap_end + count = new gap_end,
    ;;            DE = old gap_start + count = new gap_start.
    LD      (gap_start), DE
    LD      (gap_end), HL
    RET

;; --- Left shift: target < current ---
.left:
    POP     DE                          ; DE = current
    POP     HL                          ; HL = target
    EX      DE, HL                      ; HL = current, DE = target
    OR      A
    SBC     HL, DE                      ; HL = current - target = count
    LD      B, H
    LD      C, L                        ; BC = count
    LD      HL, (gap_start)
    DEC     HL                          ; source = last byte of before-gap half
    LD      DE, (gap_end)
    DEC     DE                          ; dest = last position before after-gap half
    LDDR
    ;; Post-LDDR: HL = (old gap_start - 1) - count = new gap_start - 1,
    ;;            DE = (old gap_end   - 1) - count = new gap_end   - 1.
    INC     HL
    INC     DE
    LD      (gap_start), HL
    LD      (gap_end), DE
    RET

.equal:
    POP     DE                          ; restore stack
    POP     HL
    RET

;; ============================================================
;; --- Internal helpers ---
;; ============================================================
; (none — the four primitives above are flat enough not to need
;  helpers. Reserve this section for future growth.)
