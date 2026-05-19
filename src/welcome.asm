; ============================================================
; Module: welcome.asm
; Purpose: FR53 welcome screen. Paints the VIBE ASCII banner on
;          no-argument launch (`vibe` with no filename), centered
;          both vertically (banner spans internal rows 5..17 — 5
;          blank rows above + 5 below) AND horizontally (glyph
;          block left edge at col 21 = (80 - 38) / 2; text rows
;          centered independently per their content widths). The
;          banner is encoded as a dual-mode RLE stream (run-pairs
;          for glyph rows, literal blocks for text rows) — 222 B
;          of asset data + ~85 B of decoder, saving ~130 B vs an
;          INCBIN of the raw 359-byte `banner.txt` (Story 4.2 Q1
;          Option B). Horizontal-center col_start values are
;          encoded into the RLE data at build time; decoder is
;          unchanged.
;
;          welcome_paint is called from src/init.asm's Stage 6.5
;          conditional `CALL NZ, welcome_paint`, gated by the
;          `welcome_active` flag that src/fileio.asm's
;          `fileio_load_initial.no_arg` arms at Stage 5. The
;          first keystroke in src/vibe.asm's input_loop dismisses
;          the welcome screen (clears welcome_active and forces a
;          full editable-area redraw via render_mark_all_dirty;
;          the post-dispatch render_diff then emits spaces over
;          every banner cell since the empty gap buffer's target
;          for every cell is 0x20).
;
;          Architectural enforcement here:
;            AR13 — welcome.asm does NOT call BIOS_CONOUT directly.
;                   All screen emission routes through render.asm's
;                   render_emit_byte and render_emit_goto helpers
;                   (which were promoted to render.asm's Public:
;                   surface for Story 4.2 specifically because
;                   welcome.asm is the first cross-module caller).
;            AR14 — welcome.asm does NOT touch gap_start / gap_end.
;                   The welcome banner is a static asset; the gap
;                   buffer is read-only here (and in fact never
;                   even read — the banner content is independent
;                   of buffer state). Grep `LD (gap_start),\|
;                   LD (gap_end),` against src/welcome.asm returns
;                   zero matches.
;            AR15 — welcome.asm contains zero BDOS surfaces.
;
; Public:
;   welcome_paint           ; Render the welcome banner to the
;                           ; editing area (rows 5..17) + sync
;                           ; shadow_buffer in lock-step; end
;                           ; with ESC Y 0,0 to position the
;                           ; cursor at the empty buffer's
;                           ; cursor_offset = 0.
;
; State owned (read/write):
;   welcome_paint_row       ; 1-byte module-private scratch —
;                           ; current screen row while decoding
;                           ; the RLE stream. Lives in this
;                           ; module's code segment as a DEFB;
;                           ; written-before-read within each
;                           ; welcome_paint invocation. Not in
;                           ; state.inc because no other module
;                           ; ever references it.
;   welcome_paint_col       ; 1-byte module-private scratch —
;                           ; current screen column. Same
;                           ; lifetime / ownership as
;                           ; welcome_paint_row.
;   welcome_banner_rle      ; ~222 B of RLE-encoded banner asset.
;                           ; Read-only at runtime; written at
;                           ; assembly time only.
;
; State read-only:
;   welcome_active          ; READ implicitly — the caller
;                           ; (init.asm Stage 6.5) gates the
;                           ; CALL on this flag. welcome.asm
;                           ; itself never reads or writes
;                           ; welcome_active.
;   shadow_buffer           ; WRITE to cells at rows 5..17 in
;                           ; lock-step with each BIOS_CONOUT
;                           ; emit so the dismissal-triggered
;                           ; render_diff sees shadow != target
;                           ; and emits spaces over each
;                           ; banner glyph.
;
; Register conventions (across public entry points):
;   welcome_paint:          In:  (none — reads welcome_banner_rle
;                                + writes module-private
;                                welcome_paint_row /
;                                welcome_paint_col + writes
;                                shadow_buffer rows 5..17 cells)
;                           Out: banner glyphs emitted to the
;                                physical screen at rows 5..17;
;                                shadow_buffer rows 5..17
;                                holds the banner glyphs (cells
;                                outside the glyph columns
;                                stay at the render_init 0x20
;                                seed); cursor positioned at
;                                row 0 / col 0 via a trailing
;                                ESC Y emit (matches the empty
;                                buffer's cursor_offset = 0
;                                logical position).
;                                dirty_rows NOT touched
;                                (caller — Stage 6.5 — does
;                                not manage dirty-tracking here;
;                                the next render_diff fires
;                                only on the first-keystroke
;                                dismissal path, which calls
;                                render_mark_all_dirty
;                                explicitly).
;                           Trashes: A, BC, DE, HL, F.
;                           Calls:   render_emit_byte,
;                                    render_emit_goto.
;
; Dependencies:
;   inc/equates.inc  (SCREEN_COLS — for the shadow_buffer × 80
;                     stride computation)
;   inc/state.inc    (shadow_buffer — WRITE target for each
;                     banner cell; welcome_active is referenced
;                     by callers, not this module)
;   src/render.asm   (render_emit_byte, render_emit_goto —
;                     promoted to render.asm Public: surface
;                     in Story 4.2 specifically to host
;                     welcome.asm's cross-module emit calls)
; ============================================================


;; ============================================================
;; --- Public entry: welcome_paint ---
;; ============================================================

; ----------------------------------------------------------------
; welcome_paint
; FR53 entry: paint the 13-line VIBE banner vertically centered on
; the 23-row editable area (internal rows 5..17 — 5 blank rows
; above, 5 below). Walks the welcome_banner_rle stream below,
; decoding per-row mode flags and emitting glyphs via
; render_emit_byte while keeping shadow_buffer in lock-step so the
; dismissal-triggered render_mark_all_dirty + render_diff produces
; a correct shadow-vs-target diff that emits spaces over every
; banner cell.
;
; RLE stream format (see welcome_banner_rle below):
;
;   Per-row first byte:
;     0x00..0x4F      = col_start (RUN mode follows). Cursor is
;                       positioned at (row, col_start) via ESC Y.
;                       Then a stream of (count, byte) pairs
;                       follows, each terminating one run of N
;                       identical bytes. Counts are 1..0xFE.
;                       Byte 0xFF as count = end-of-row.
;     0x80..0xCF      = (0x80 | col_start), LITERAL mode follows.
;                       Cursor positioned same as RUN. Then a
;                       stream of literal bytes (ASCII 0x20..0x7E)
;                       follows, terminated by byte 0xFF.
;     0xFF            = blank-row marker (no col_start, no
;                       payload — the row advances by 1).
;     0xFE            = end-of-banner marker (terminates the
;                       welcome_paint walk).
;
; Decoder walks one row at a time; on EOR (0xFF count or 0xFF
; literal) it increments welcome_paint_row and resumes. On 0xFE
; it emits the trailing ESC Y 0,0 cursor reposition and returns.
;
; In:      (none)
; Out:     banner glyphs on rows 5..17 of the screen + shadow_buffer
;          cells at rows 5..17 hold the banner glyphs (cells at
;          col_start..col_last_glyph; cells outside the glyph runs
;          stay at the render_init 0x20 seed). Cursor at row 0,
;          col 0.
; Trashes: A, BC, DE, HL, F.
; Calls:   render_emit_byte, render_emit_goto.
; ----------------------------------------------------------------
welcome_paint:
    ;; Initialise row counter to banner top.
    LD      A, 5                        ; banner starts at internal row 5 (vertical center: (23-13)/2)
    LD      (welcome_paint_row), A

    ;; Walk the RLE stream. HL = current byte pointer.
    LD      HL, welcome_banner_rle

.row_loop:
    LD      A, (HL)
    INC     HL
    CP      0xFE
    JR      Z, .done                    ; end-of-banner marker
    CP      0xFF
    JR      Z, .blank_row               ; blank-row marker (no col_start, no payload)

    ;; A holds the row first byte: mode flag (bit 7) + col_start (bits 0..6).
    ;; Save the mode flag in B (bit 7) and the col_start in welcome_paint_col.
    LD      B, A                        ; B preserves the mode flag for the BIT 7 test below
    AND     0x7F
    LD      (welcome_paint_col), A      ; welcome_paint_col = col_start

    ;; Position cursor at (welcome_paint_row, col_start). render_emit_goto
    ;; needs A = row, C = col; trashes A, BC, F.
    LD      C, A                        ; C = col_start
    LD      A, (welcome_paint_row)
    PUSH    HL
    PUSH    BC                          ; preserve B (mode flag) across the goto
    CALL    render_emit_goto
    POP     BC
    POP     HL

    ;; Branch on mode: bit 7 set = LITERAL, clear = RUN.
    BIT     7, B
    JR      NZ, .literal_loop

.run_loop:
    ;; Read count byte. 0xFF = end-of-row.
    LD      A, (HL)
    CP      0xFF
    JR      Z, .next_row
    INC     HL
    LD      B, A                        ; B = count (1..0xFE — fits DJNZ)

    ;; Read the byte to repeat.
    LD      A, (HL)
    INC     HL
    LD      C, A                        ; C = byte

.run_emit:
    LD      A, C                        ; A = byte to emit
    PUSH    HL
    PUSH    BC
    CALL    welcome_emit_cell           ; emit + write shadow + advance welcome_paint_col
    POP     BC
    POP     HL
    DJNZ    .run_emit
    JR      .run_loop

.literal_loop:
    ;; Read literal byte. 0xFF = end-of-row.
    LD      A, (HL)
    CP      0xFF
    JR      Z, .next_row
    INC     HL
    PUSH    HL
    CALL    welcome_emit_cell           ; A = byte (already loaded); emit + shadow + advance col
    POP     HL
    JR      .literal_loop

.next_row:
    INC     HL                          ; consume the 0xFF EOR marker
    ;; fall through to .blank_row to advance the row counter

.blank_row:
    LD      A, (welcome_paint_row)
    INC     A
    LD      (welcome_paint_row), A
    JR      .row_loop

.done:
    ;; Trailing ESC Y 0,0 — matches the empty buffer's cursor_offset = 0
    ;; logical position, so the user sees a stationary cursor in the
    ;; top-left of the editing area while the welcome is displayed.
    XOR     A                           ; A = 0 = row
    LD      C, A                        ; C = 0 = col
    JP      render_emit_goto            ; tail-JP


;; ============================================================
;; --- Internal helper: welcome_emit_cell ---
;; ============================================================

; ----------------------------------------------------------------
; welcome_emit_cell
; Emit one byte to the screen at the current welcome_paint position
; AND write the same byte into shadow_buffer[row*80+col], then
; advance welcome_paint_col by 1. The cursor on the physical screen
; auto-advances per VT52 convention as render_emit_byte emits the
; byte; we mirror that with welcome_paint_col so the next emit
; lands at the next column.
;
; Module-private scratch reads: welcome_paint_row, welcome_paint_col.
; Module-private scratch writes: welcome_paint_col (incremented).
;
; In:      A = byte to emit + write to shadow.
; Out:     byte emitted; shadow_buffer[row*80+col] = A;
;          welcome_paint_col incremented by 1.
; Trashes: A, BC, DE, HL, F.
; Calls:   render_emit_byte.
; ----------------------------------------------------------------
welcome_emit_cell:
    PUSH    AF                          ; preserve byte across the shadow-address math

    ;; Compute shadow_buffer + row*80 + col into HL.
    ;; row*80 = row*64 + row*16 = (row<<4) + (row<<6).
    LD      A, (welcome_paint_row)
    LD      H, 0
    LD      L, A                        ; HL = row
    ADD     HL, HL                      ; ×2
    ADD     HL, HL                      ; ×4
    ADD     HL, HL                      ; ×8
    ADD     HL, HL                      ; ×16
    LD      D, H
    LD      E, L                        ; DE = row × 16
    ADD     HL, HL                      ; ×32
    ADD     HL, HL                      ; ×64
    ADD     HL, DE                      ; HL = row × 80
    LD      DE, shadow_buffer
    ADD     HL, DE                      ; HL = shadow_buffer + row × 80
    LD      A, (welcome_paint_col)
    LD      E, A
    LD      D, 0
    ADD     HL, DE                      ; HL = shadow_buffer + row × 80 + col

    POP     AF                          ; restore byte
    LD      (HL), A                     ; write byte to shadow

    CALL    render_emit_byte            ; emit byte to screen (trashes A, BC, F; preserves DE, HL — caller restores via stack if needed)

    ;; Advance welcome_paint_col by 1.
    LD      A, (welcome_paint_col)
    INC     A
    LD      (welcome_paint_col), A
    RET


;; ============================================================
;; --- Module-local scratch (DEFB; written-before-read per invoke) ---
;; ============================================================
; Policy mirrors render.asm:1295-1303 — module-private scratch that
; never escapes the module lives in the code segment as DEFB, not in
; state.inc. Two cells total.
;
; Cold-start residue: welcome_paint sets welcome_paint_row to 5 at
; entry (line 142 above), so the DEFB initial values are inert.

welcome_paint_row:    DEFB 0            ; current screen row (5..17 across one walk)
welcome_paint_col:    DEFB 0            ; current screen col (0..79 within each row)


;; ============================================================
;; --- Welcome banner asset (dual-mode RLE) ---
;; ============================================================
; 222 B of RLE-encoded banner data, hand-rolled to match banner.txt
; verbatim. Source-of-truth: /banner.txt at project root (13 lines,
; 359 B raw). RLE encoding saves ~137 B vs INCBIN raw (Story 4.2
; Q1 Option B).
;
; Encoding (per row):
;   0x00..0x4F  = col_start, RUN mode follows (pairs of count/byte
;                 until count == 0xFF EOR)
;   0x80..0xCF  = (0x80 | col_start), LITERAL mode follows (literal
;                 bytes until byte == 0xFF EOR)
;   0xFF        = blank row (no col_start, no payload)
; Banner end: 0xFE
;
; Layout (banner rows -> internal screen rows):
;   banner line  1 (blank)                                  -> row  5
;   banner line  2 (' mm    mm   mmmmmm   mmmmmm    mmmmmmmm') -> row 6
;   banner line  3 (' "##  ##"   ""##""   ##""""##  ##""""""') -> row 7
;   banner line  4 ('  ##  ##      ##     ##    ##  ##')   -> row  8
;   banner line  5 ('  ##  ##      ##     #######   #######') -> row 9
;   banner line  6 ('   ####       ##     ##    ##  ##')   -> row 10
;   banner line  7 ('   ####     mm##mm   ##mmmm##  ##mmmmmm') -> row 11
;   banner line  8 ('   """"     """"""   """""""   """"""""') -> row 12
;   banner line  9 (blank)                                  -> row 13
;   banner line 10 ('          Vi-like Beast Editor')       -> row 14
;   banner line 11 ('            (c) 2026 ant.org')         -> row 15
;   banner line 12 (blank)                                  -> row 16
;   banner line 13 ('            Type :q to quit!')         -> row 17

welcome_banner_rle:

    ;; Banner line 1 (blank row 5)
    DEFB 0xFF

    ;; Banner line 2 (row 6): col_start=21 (centered: glyph block width 38 →
    ;; (80-38)/2 = 21); 2m,4_,2m,3_,6m,3_,6m,4_,8m
    DEFB 21
    DEFB 2, 'm', 4, ' ', 2, 'm', 3, ' ', 6, 'm', 3, ' ', 6, 'm', 4, ' ', 8, 'm'
    DEFB 0xFF

    ;; Banner line 3 (row 7): col_start=21 (same shift as line 2);
    ;; 1",2#,2_,2#,1",3_,2",2#,2",3_,2#,4",2#,2_,2#,6"
    DEFB 21
    DEFB 1, '"', 2, '#', 2, ' ', 2, '#', 1, '"', 3, ' '
    DEFB 2, '"', 2, '#', 2, '"', 3, ' '
    DEFB 2, '#', 4, '"', 2, '#', 2, ' ', 2, '#', 6, '"'
    DEFB 0xFF

    ;; Banner line 4 (row 8): col_start=22 (orig 2 + glyph shift +20);
    ;; 2#,2_,2#,6_,2#,5_,2#,4_,2#,2_,2#
    DEFB 22
    DEFB 2, '#', 2, ' ', 2, '#', 6, ' ', 2, '#', 5, ' '
    DEFB 2, '#', 4, ' ', 2, '#', 2, ' ', 2, '#'
    DEFB 0xFF

    ;; Banner line 5 (row 9): col_start=22; 2#,2_,2#,6_,2#,5_,7#,3_,7#
    DEFB 22
    DEFB 2, '#', 2, ' ', 2, '#', 6, ' ', 2, '#', 5, ' '
    DEFB 7, '#', 3, ' ', 7, '#'
    DEFB 0xFF

    ;; Banner line 6 (row 10): col_start=23 (orig 3 + glyph shift +20);
    ;; 4#,7_,2#,5_,2#,4_,2#,2_,2#
    DEFB 23
    DEFB 4, '#', 7, ' ', 2, '#', 5, ' '
    DEFB 2, '#', 4, ' ', 2, '#', 2, ' ', 2, '#'
    DEFB 0xFF

    ;; Banner line 7 (row 11): col_start=23; 4#,5_,2m,2#,2m,3_,2#,4m,2#,2_,2#,6m
    DEFB 23
    DEFB 4, '#', 5, ' ', 2, 'm', 2, '#', 2, 'm', 3, ' '
    DEFB 2, '#', 4, 'm', 2, '#', 2, ' ', 2, '#', 6, 'm'
    DEFB 0xFF

    ;; Banner line 8 (row 12): col_start=23; 4",5_,6",3_,7",3_,8"
    DEFB 23
    DEFB 4, '"', 5, ' ', 6, '"', 3, ' ', 7, '"', 3, ' ', 8, '"'
    DEFB 0xFF

    ;; Banner line 9 (blank row 13)
    DEFB 0xFF

    ;; Banner line 10 (row 14): LITERAL, col_start=30 (centered: width 20 →
    ;; (80-20)/2 = 30); "Vi-like Beast Editor" (20 B)
    DEFB 0x80 | 30
    DEFB "Vi-like Beast Editor"
    DEFB 0xFF

    ;; Banner line 11 (row 15): LITERAL, col_start=32 (centered: width 16 →
    ;; (80-16)/2 = 32); "(c) 2026 ant.org" (16 B)
    DEFB 0x80 | 32
    DEFB "(c) 2026 ant.org"
    DEFB 0xFF

    ;; Banner line 12 (blank row 16)
    DEFB 0xFF

    ;; Banner line 13 (row 17): LITERAL, col_start=32; "Type :q to quit!" (16 B)
    DEFB 0x80 | 32
    DEFB "Type :q to quit!"
    DEFB 0xFF

    ;; End-of-banner marker
    DEFB 0xFE

welcome_banner_rle_end:

;; Size tripwire: 222 B mid-estimate. If the encoding drifts +/- 10 B,
;; revisit the NFR9 projection (the cliff edge is forgiving — 1500 B
;; headroom — but document any drift > 10 B in the dev log).
    ASSERT  welcome_banner_rle_end - welcome_banner_rle == 222
