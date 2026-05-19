; ============================================================
; Module: gapbuf.asm
; Purpose: Gap-buffer primitives. Owns the SR2 two-halves
;          invariant and is the single buffer-mutation owner
;          (AR14): all edits to the gap buffer enter through
;          gapbuf_insert / gapbuf_delete / gapbuf_move_gap /
;          gapbuf_case_toggle_range.
;          Pure-memory module — no BDOS, no console emit
;          (AR15: gapbuf does not invoke the BDOS entry vector
;          or the BDOS macro; AC11 grep enforces).
;          Story 3.8 — gapbuf_case_toggle_range lands as the
;          fifth public mutator; preserves AR14 (gapbuf remains
;          the sole buffer-mutation owner) by introducing an
;          in-place per-byte mutator that uses gapbuf_move_gap
;          to relocate the gap to the range start, then walks
;          the now-contiguous bytes at gap_end onwards toggling
;          alphabetic case bits in place. Net file_length
;          UNCHANGED; gap_start / gap_end UNCHANGED net (the
;          move_gap side-effect is internal to the call —
;          caller observes invariant gap pointers). Mirrors
;          visual.asm's call site visual_apply_case_toggle
;          (Story 3.8 — FR38).
;
; Public:
;   gapbuf_init              - reset to empty buffer
;   gapbuf_insert            - insert byte at cursor (gap-tracks-cursor)
;   gapbuf_delete            - delete byte before cursor
;   gapbuf_move_gap          - relocate gap to a target logical offset
;   gapbuf_case_toggle_range - in-place case-toggle over [HL, HL+BC) (Story 3.8)
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

; ----------------------------------------------------------------
; gapbuf_case_toggle_range
; In-place per-byte alphabetic case toggle (Story 3.8). For each
; byte in [HL, HL+BC) that is 'A'..'Z' or 'a'..'z', flips bit 5
; (XOR 0x20). Non-alphabetic bytes (LF / space / digits /
; punctuation) pass through unchanged. Net file_length is
; UNCHANGED — the gap is internally relocated to the range start
; via gapbuf_move_gap so the target bytes become physically
; contiguous at gap_end onwards, then the walk mutates them in
; place. AR14 preserves: gapbuf remains the sole buffer-mutation
; owner. The fifth public mutator after init / insert / delete /
; move_gap.
;
; In:      HL = range_start (logical offset; 0 <= HL <= file_length - BC)
;          BC = byte count (range_end - range_start; may be 0)
; Out:     Bytes in [HL, HL+BC) have alpha case toggled in place;
;          non-alpha bytes unchanged.
;          gap_start / gap_end UNCHANGED net (gapbuf_move_gap
;          relocated the gap as a side-effect but no NET
;          file_length change).
;          cursor_offset PRESERVED across the call.
;          Z flag = 1 iff no alpha byte was toggled (no-op walk;
;          selection had no alphabetic content); Z = 0 iff at
;          least one byte was toggled.
; Trashes: A, BC, DE, HL, F.
; Calls:   gapbuf_move_gap (× 1; relocates gap to range_start so
;          the toggle region becomes physically contiguous at
;          gap_end onwards).
; ----------------------------------------------------------------
gapbuf_case_toggle_range:
    ;; 0-byte defensive guard. Empty BC -> Z=1 return (no toggles).
    LD      A, B
    OR      C
    RET     Z

    ;; Move the gap to the range start. After this, bytes
    ;; [HL, HL+BC) are physically contiguous at gap_end..gap_end+BC.
    PUSH    BC
    CALL    gapbuf_move_gap             ; gap relocated; cursor UNCHANGED
    POP     BC

    ;; Walk bytes from gap_end. HL repurposed as physical pointer.
    LD      HL, (gap_end)
    LD      D, 0                        ; D = dirty flag (0 = clean)

.ct_loop:
    LD      A, (HL)
    ;; --- Alpha test (inline) ---
    CP      'A'
    JR      C, .ct_advance              ; A < 'A' -> not alpha
    CP      'Z' + 1
    JR      C, .ct_toggle               ; 'A'..'Z' -> toggle
    CP      'a'
    JR      C, .ct_advance              ; '['..'`' -> not alpha
    CP      'z' + 1
    JR      NC, .ct_advance             ; A > 'z' -> not alpha

.ct_toggle:
    XOR     0x20                        ; flip case bit
    LD      (HL), A
    LD      D, 1                        ; dirty

.ct_advance:
    INC     HL
    DEC     BC
    LD      A, B
    OR      C
    JR      NZ, .ct_loop

    ;; Set Z=0 iff dirty (D=1); Z=1 iff clean (D=0).
    LD      A, D
    OR      A
    RET

;; ============================================================
;; --- Internal helpers ---
;; ============================================================
; (none — the five primitives above are flat enough not to need
;  helpers. Reserve this section for future growth.)
