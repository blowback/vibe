; ============================================================
; Module: render.asm
; Purpose: Render pipeline (RI1-RI4). Exposes the diff-render
;          (`render_diff`) and full-redraw (`render_full`) entry
;          points the input loop and Ctrl-L handler call after
;          each frame; owns the 24-bit dirty-row bitmap, the
;          shadow buffer, and the V2 scroll mechanism anchored
;          at `top_line_offset`. The diff path emits ONLY the
;          contiguous runs of cells that differ between the
;          gap buffer's two-halves view and the shadow buffer;
;          idle frames touch the wire only for the RI4
;          defensive cursor reposition (~4 bytes).
;
;          render.asm is the SOLE BIOS_CONOUT call site in
;          production code (AR13). The earlier architecture
;          carve-out for init.asm's initial clear-screen was
;          retired by Story 1.11: `render_init` absorbs the
;          ESC J clear, so init.asm (Story 1.12) calls
;          render_init and never touches BIOS_CONOUT directly.
;
;          Page-alignment decision for shadow_buffer (Story 1.3
;          deferral resolved): NOT page-aligned in state.inc.
;          Indexing uses `row * SCREEN_COLS + col` via shift-add
;          (HL doubled four times = ×16, plus two more doublings
;          and an add for ×80). Sub-perceptible cost; alignment
;          fast-path deferred to a future profiling-driven story
;          when one is justified.
;
;          VT52_GOTO row/col clamp (Story 1.2 deferral resolved):
;          every `ESC Y` emit site in this module routes through
;          `render_emit_goto`, which clamps row to
;          [0, SCREEN_ROWS-1] and col to [0, SCREEN_COLS-1]
;          BEFORE adding VT52_COORD_BIAS. The clamp is single-
;          sited; no other emit path can compose an unclamped
;          GOTO sequence.
;
;          COMMAND-mode cursor target (Story 2.1 / AC11): the
;          trailing RI4 cursor emit in `render_diff` reads
;          mode_byte; on MODE_COMMAND the cursor row/col is
;          overridden to (STATUS_ROW, 1 + ex_buffer length) so
;          the ESC Y lands on the status row after the ':' prompt
;          glyph. The override is single-sited (here only) and
;          decays to a no-op outside COMMAND.
;
; Public:
;   render_init             ; clear screen, seed shadow, zero
;                           ; dirty_rows / top_line_offset,
;                           ; home cursor (Story 1.12 calls)
;   render_diff             ; per-row dirty diff + scroll +
;                           ; status emit + cursor reposition
;                           ; (called once per input-loop iter)
;   render_full             ; mark-all-dirty then diff (Ctrl-L,
;                           ; FR48 / NFR7)
;   render_mark_row_dirty   ; A = row (0..23); set the bit
;   render_mark_all_dirty   ; set all 24 row bits
;
; State owned (read/write):
;   shadow_buffer           ; 1920 bytes, mirror of last-emitted
;                           ; screen content. Writer: render_init
;                           ; seeds with 0x20; render_diff updates
;                           ; per-cell in lock-step with each emit.
;   dirty_rows              ; 3-byte bitmap, bit r in byte r/8.
;                           ; Writers: render_init zeroes;
;                           ; render_mark_row_dirty / _all_dirty
;                           ; set bits; render_diff clears after
;                           ; the row-emit pass.
;   top_line_offset         ; 16-bit logical offset of the row 0
;                           ; start. Writers: render_init zeroes;
;                           ; render_diff scroll-adjust may
;                           ; advance/retreat.
;
; State read-only (with one read-then-clear side-effect):
;   status_buffer           ; READ to compose the status-row emit
;                           ; (statusln.asm owns the WRITE path
;                           ; via status_set_message — AR12).
;   status_dirty            ; READ to gate the status emit; cleared
;                           ; after the row is reconciled. The
;                           ; AR12 funnel still owns the SET path
;                           ; (status_set_message); render is the
;                           ; sole CLEAR site (the read consumes).
;   cursor_offset, gap_start, gap_end
;                           ; READ for the SR3 two-halves walk
;                           ; (cell content lookup). Never WRITTEN
;                           ; (AR14 — only gapbuf.asm mutates).
;   mode_byte               ; READ by render_diff for the AC11
;                           ; COMMAND-mode cursor-target override
;                           ; (Story 2.1).
;   ex_buffer               ; READ (length byte only) by render_diff
;                           ; to compute the COMMAND-mode cursor
;                           ; column = 1 + length (Story 2.1).
;
; Register conventions (across public entry points):
;   render_init:            In:  (none)
;                           Out: screen cleared via ESC H + ESC J
;                                (full clear with cursor home —
;                                see Story-1.12 hardware-UAT
;                                patch); shadow seeded to 0x20;
;                                dirty_rows zeroed;
;                                top_line_offset zeroed; cursor
;                                left at row 0/col 0 by the ESC H
;                                (no trailing ESC Y needed).
;                                status_dirty NOT cleared (a
;                                pre-init status_set_message
;                                remains visible on the first
;                                render_diff).
;                           Trashes: A, BC, DE, HL, F.
;                           Calls:   render_emit_byte (4 times —
;                                    ESC, H, ESC, J).
;
;   render_diff:            In:  (none — parameters are state.inc
;                                fields).
;                           Out: dirty rows re-emitted (cell-by-
;                                cell shadow diff, contiguous runs);
;                                status row emitted if status_dirty;
;                                shadow synced; dirty_rows cleared;
;                                status_dirty cleared if it was set;
;                                cursor repositioned (RI4
;                                defensive).
;                           Trashes: A, BC, DE, HL, F.
;                           Calls:   render_emit_byte,
;                                    render_emit_goto (and module-
;                                    private helpers).
;
;   render_full:            In:  (none)
;                           Out: every cell reconciled to its
;                                buffer-derived target; dirty_rows
;                                cleared; cursor repositioned.
;                           Trashes: A, BC, DE, HL, F.
;                           Calls:   render_mark_all_dirty,
;                                    render_diff (tail-JP).
;
;   render_mark_row_dirty:  In:  A = row (0..23; A >= SCREEN_ROWS
;                                returns without writing —
;                                defensive clamp).
;                           Out: bit (1 << (A mod 8)) set in
;                                dirty_rows[A / 8]; existing bits
;                                preserved (OR-merge).
;                           Trashes: A, BC, HL, F.
;                           Calls:   (none).
;
;   render_mark_all_dirty:  In:  (none)
;                           Out: dirty_rows = 0xFF, 0xFF, 0xFF
;                                (bits 24..31 of byte 2 are inert
;                                — the row-walk only iterates
;                                rows 0..23).
;                           Trashes: A, F.
;                           Calls:   (none).
;
; Dependencies:
;   inc/equates.inc  (SCREEN_ROWS, SCREEN_COLS, EDITABLE_ROWS,
;                     STATUS_ROW, STATUS_LINE_WIDTH,
;                     DIRTY_ROWS_BITMAP_BYTES, GAP_BUFFER_MAX)
;   inc/state.inc    (shadow_buffer, dirty_rows, top_line_offset,
;                     cursor_offset, gap_start, gap_end,
;                     status_buffer, status_dirty, GAP_BUFFER_BASE,
;                     mode_byte, ex_buffer — last two added by
;                     Story 2.1 for the AC11 cursor override)
;   inc/bios.inc     (BIOS_CONOUT — the one BIOS entry point this
;                     module touches)
;   inc/vt52.inc     (VT52_ESC, VT52_CURSOR_HOME, VT52_ERASE_TO_EOS,
;                     VT52_GOTO, VT52_COORD_BIAS)
;   inc/modes.inc    (MODE_COMMAND — Story 2.1 / AC11)
;   src/statusln.asm (state collaborator only — render reads
;                     status_buffer / status_dirty by state.inc
;                     symbol; no function-call dependency)
; ============================================================


;; ============================================================
;; --- render_init (AC2) ---
;; ============================================================

; ----------------------------------------------------------------
; render_init
; Initial-state setup called by init.asm's cold-start path
; (Story 1.12). Emits one ESC J to clear the physical screen,
; seeds shadow_buffer with ASCII space so the first render_diff
; treats every non-space byte as a diff, zeroes dirty_rows and
; top_line_offset so the first frame starts from a known datum,
; and emits one ESC Y to home the cursor.
;
; Boot-time cost: the 1920-byte LDIR space-fill costs roughly
; 1920 * 21 = 40,320 T-states ~= 10 ms at 4 MHz. NFR3 governs
; frame-rate cost, not boot-time, so this is acceptable.
;
; status_dirty is INTENTIONALLY NOT cleared: a pre-init
; status_set_message call (e.g. the cold-start mode-indicator
; "-- normal --") must remain visible on the first render_diff
; pass. The asymmetry "init clears dirty_rows but not
; status_dirty" mirrors statusln.asm's AR12 ownership of the
; status_dirty WRITE path.
;
; In:      (none)
; Out:     screen cleared via ESC H + ESC J (full clear, cursor
;          left at row 0 / col 0 by ESC H — see "On VT52 ESC J
;          alone..." note below); shadow_buffer filled with
;          0x20; dirty_rows = 0; top_line_offset = 0.
;          status_dirty unchanged.
; Trashes: A, BC, DE, HL, F.
; Calls:   render_emit_byte (4 times).
; ----------------------------------------------------------------
render_init:
    ;; Cursor home + erase-to-end-of-screen = full clear.
    ;;
    ;; On VT52 ESC J alone is "erase from cursor to end of
    ;; screen", NOT a whole-screen clear (Story-1.12 hardware
    ;; UAT surfaced this: emitting bare ESC J at .com entry
    ;; leaves every row above the CCP-positioned cursor
    ;; untouched). The whole-screen clear requires ESC H
    ;; (home cursor) followed by ESC J (erase from home onward).
    ;; After this 4-byte sequence the screen is blank AND the
    ;; cursor is at row 0, col 0 — so no trailing ESC Y home
    ;; is needed.
    LD      A, VT52_ESC
    CALL    render_emit_byte
    LD      A, VT52_CURSOR_HOME
    CALL    render_emit_byte
    LD      A, VT52_ESC
    CALL    render_emit_byte
    LD      A, VT52_ERASE_TO_EOS
    CALL    render_emit_byte

    ;; Fill shadow_buffer with 0x20 (ASCII space). LDIR-fill idiom:
    ;; seed the first byte, source = HL, dest = HL+1, count =
    ;; (length - 1). The single seed byte propagates through the
    ;; entire span as LDIR walks forward.
    LD      HL, shadow_buffer
    LD      (HL), 0x20
    LD      DE, shadow_buffer + 1
    LD      BC, SCREEN_ROWS * SCREEN_COLS - 1
    LDIR

    ;; Zero dirty_rows (3 bytes). Direct stores beat a 3-byte
    ;; LDIR (LDIR setup costs more than three LD (nn), A pairs).
    XOR     A
    LD      (dirty_rows), A
    LD      (dirty_rows + 1), A
    LD      (dirty_rows + 2), A

    ;; Zero top_line_offset (2 bytes).
    LD      HL, 0
    LD      (top_line_offset), HL

    ;; Cursor is already at row 0 / col 0 from the ESC H above.
    RET


;; ============================================================
;; --- render_mark_row_dirty / render_mark_all_dirty (AC6, AC7) ---
;; ============================================================

; ----------------------------------------------------------------
; render_mark_row_dirty
; Set bit (1 << (A mod 8)) in dirty_rows[A / 8]. Defensive
; clamp: A >= SCREEN_ROWS returns without writing (no silent
; corruption of bytes adjacent to dirty_rows in the static
; map). Caller-saved per MC1; pure memory operation — no BIOS
; / BDOS / status side effects (RI1's "mark dirty is the cheap
; hint" contract).
;
; In:      A = row (0..23). A >= SCREEN_ROWS is a no-op.
; Out:     dirty_rows[A / 8] |= (1 << (A mod 8)).
; Trashes: A, BC, HL, F.
; Calls:   (none).
; ----------------------------------------------------------------
render_mark_row_dirty:
    CP      SCREEN_ROWS
    RET     NC                          ; defensive clamp: A >= 24 returns

    ;; Split A into byte_idx (A / 8) and bit_idx (A mod 8).
    ;; Save bit_idx in B before we shift A right.
    LD      B, A                        ; B = full row (bit_idx is its low 3 bits)
    SRL     A
    SRL     A
    SRL     A                           ; A = row / 8 (= byte_idx, 0..2 for rows 0..23)
    LD      C, A                        ; C = byte_idx; B (still) = full row

    ;; Build mask = 1 << (B mod 8). Shift-loop variant:
    ;;   B mod 8 by AND 0x07, then loop-shift A=1 left B times.
    LD      A, B
    AND     0x07                        ; A = bit_idx 0..7
    LD      B, A                        ; B = shift count
    LD      A, 1
    INC     B                           ; pre-decrement: B=0 -> mask=1 after one DJNZ iter
    JR      .shift_test
.shift_loop:
    ADD     A, A                        ; shift left by 1
.shift_test:
    DJNZ    .shift_loop                 ; loops bit_idx times; falls through with A = mask

    ;; OR-merge mask into dirty_rows[byte_idx].
    LD      HL, dirty_rows
    LD      B, 0                        ; BC = byte_idx (high byte clear)
    ADD     HL, BC                      ; HL = dirty_rows + byte_idx
    OR      (HL)                        ; A = old | mask
    LD      (HL), A
    RET

; ----------------------------------------------------------------
; render_mark_all_dirty
; Set all 24 row bits in dirty_rows. Bits 24..31 of byte 2 are
; inert (the row-walk only iterates rows 0..23) — storing 0xFF
; into all three bytes is one byte shorter than masking byte 2
; to 0x00FFFF.
;
; In:      (none)
; Out:     dirty_rows = 0xFF, 0xFF, 0xFF.
; Trashes: A, F.
; Calls:   (none).
; ----------------------------------------------------------------
render_mark_all_dirty:
    LD      A, 0xFF
    LD      (dirty_rows), A
    LD      (dirty_rows + 1), A
    LD      (dirty_rows + 2), A
    RET


;; ============================================================
;; --- render_full (AC3) ---
;; ============================================================

; ----------------------------------------------------------------
; render_full
; Full-redraw path bound to Ctrl-L (FR48, NFR7). Marks every
; editable row dirty, then runs the diff path — which, finding
; every row dirty and shadow already in lock-step with the
; emitted content, walks the entire screen and re-emits any
; cell whose buffer-derived target differs from shadow. After
; render_full returns, dirty_rows is zero, shadow matches what
; is now on screen, and the cursor has been re-emitted.
;
; Tail-JP idiom: render_diff's terminal RET returns directly to
; render_full's caller. Three bytes total (CALL + JP), and the
; transitive trash matches render_diff's.
;
; In:      (none)
; Out:     every visible cell reconciled; dirty_rows = 0;
;          cursor repositioned.
; Trashes: A, BC, DE, HL, F.
; Calls:   render_mark_all_dirty, render_diff (tail-JP).
; ----------------------------------------------------------------
render_full:
    CALL    render_mark_all_dirty
    JP      render_diff


;; ============================================================
;; --- render_diff (AC4, AC5 — the main render entry) ---
;; ============================================================

; ----------------------------------------------------------------
; render_diff
; The normal-frame render path. Stages, in order:
;
;   1. Cache the gap-buffer mapping (gap_log, after_gap_base,
;      file_length) for this frame. The mapping is invariant
;      across the frame, so it is computed once and the inner
;      cell-read helper consults the cache.
;   2. Scroll adjust (V2). Compute the cursor's logical row by
;      counting 0x0A bytes from top_line_offset to cursor_offset.
;      If the cursor lands outside [0, EDITABLE_ROWS-1], advance
;      (or retreat) top_line_offset until it falls back in range,
;      and mark every editable row dirty so the post-scroll
;      content re-emits.
;   3. Editable-row emit (FR47 + NFR1). For each row r in
;      0..EDITABLE_ROWS-1 whose dirty_rows bit is set, walk the
;      row's cells, compare to shadow, emit contiguous runs of
;      differing cells. Shadow updates in lock-step with each
;      emitted byte.
;   4. Status-row emit (FR49). If status_dirty is nonzero, emit
;      the status_buffer row (same contiguous-run diff against
;      shadow's row 23 slice) and clear status_dirty.
;   5. Clear dirty_rows (all three bytes zeroed).
;   6. Cursor reposition (RI4 defensive). Emit one ESC Y at the
;      cursor's row/col as the LAST bytes of the frame — even if
;      no cells changed. Cursor desync alone never compounds.
;      Story 2.1 / AC11: in MODE_COMMAND the row/col cached by
;      step 2 is overridden to (STATUS_ROW, 1 + ex_buffer length)
;      before the emit so the cursor lands at the trailing edge
;      of the ':' prompt + typed content.
;
; Reads (Story 2.1): mode_byte, ex_buffer (length byte) — for
;          the AC11 COMMAND-mode cursor-target override above.
;
; In:      (none — every input is a state.inc field)
; Out:     screen updated; shadow_buffer synced; dirty_rows = 0;
;          status_dirty cleared if it was set; top_line_offset
;          may have advanced/retreated; cursor positioned.
; Trashes: A, BC, DE, HL, F.
; Calls:   render_emit_byte, render_emit_goto (and the module-
;          private helpers below).
; ----------------------------------------------------------------
render_diff:
    CALL    render_refresh_caches       ; gap_log, after_gap_base, file_length
    CALL    render_scroll_adjust        ; sets render_cursor_row, render_cursor_col,
                                        ; may advance/retreat (top_line_offset) and
                                        ; mark rows 0..EDITABLE_ROWS-1 dirty
    CALL    render_emit_editable_rows
    CALL    render_emit_status_row

    ;; Clear dirty_rows.
    XOR     A
    LD      (dirty_rows), A
    LD      (dirty_rows + 1), A
    LD      (dirty_rows + 2), A

    ;; --- Story 2.1 / AC11: mode-aware cursor target ---
    ;; In MODE_COMMAND the cursor sits on the status row at
    ;; col (1 + ex_buffer length), with the ':' glyph at col 0.
    ;; Override render_cursor_row / col before the trailing
    ;; RI4 emit so the ESC Y goes to the right place. The
    ;; override is a no-op in every other mode (the values set
    ;; by render_scroll_adjust survive).
    LD      A, (mode_byte)
    CP      MODE_COMMAND
    JR      NZ, .cursor_emit
    LD      A, STATUS_ROW
    LD      (render_cursor_row), A
    LD      A, (ex_buffer)              ; length byte
    INC     A                           ; +1 for the ':' prefix
    LD      (render_cursor_col), A

.cursor_emit:
    ;; Final cursor reposition (RI4). emit_goto clamps both
    ;; coordinates before adding the VT52 bias.
    LD      A, (render_cursor_col)
    LD      C, A                        ; C = col
    LD      A, (render_cursor_row)      ; A = row
    JP      render_emit_goto            ; tail-JP


;; ============================================================
;; --- Internal helpers ---
;; ============================================================

; ----------------------------------------------------------------
; render_refresh_caches
; Compute the per-frame gap-mapping cache so render_byte_at_logical
; can dispatch with a single SBC HL,DE per cell. The mapping is
; invariant for the duration of one render_diff invocation —
; gapbuf is the only writer of gap_start / gap_end (AR14), and
; render_diff runs to completion between input-loop iterations.
;
;   gap_log         = gap_start - GAP_BUFFER_BASE
;                     (logical size of the before-gap half)
;   after_gap_base  = gap_end - gap_log
;                     (so physical = after_gap_base + logical
;                      for any after-gap logical offset)
;   file_length     = gap_start + GAP_BUFFER_MAX - gap_end
;                     (total logical bytes the buffer holds)
;
; In:      (none — reads gap_start, gap_end)
; Out:     (none — writes render_gap_log, render_after_gap_base,
;           render_file_length)
; Trashes: A, BC, DE, HL, F.
; Calls:   (none)
; ----------------------------------------------------------------
render_refresh_caches:
    ;; gap_log = gap_start - GAP_BUFFER_BASE
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE
    LD      (render_gap_log), HL        ; save gap_log

    ;; after_gap_base = gap_end - gap_log
    LD      DE, (gap_end)
    EX      DE, HL                      ; HL = gap_end, DE = gap_log
    OR      A
    SBC     HL, DE
    LD      (render_after_gap_base), HL

    ;; file_length = gap_start + GAP_BUFFER_MAX - gap_end
    ;; Equivalent: (GAP_BUFFER_BASE + GAP_BUFFER_MAX) - after_gap_base.
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      DE, (render_after_gap_base)
    OR      A
    SBC     HL, DE
    LD      (render_file_length), HL
    RET

; ----------------------------------------------------------------
; render_byte_at_logical
; The SR3 two-halves cell-read primitive: translate a 16-bit
; logical offset (HL) into the physical byte the buffer holds
; at that offset. Reads the cached gap mapping (render_gap_log
; / render_after_gap_base / render_file_length) so the per-cell
; cost is two SBCs and one ADD plus the load.
;
; HL is preserved across the call so the caller's row-walk can
; advance via INC HL.
;
; In:      HL = logical offset
; Out:     A  = byte at logical offset; CF = 0
;             OR
;          A  = 0x20, CF = 1 if logical >= file_length (past-EOF)
;          HL preserved on every path.
; Trashes: A, DE, F.
; Calls:   (none).
; ----------------------------------------------------------------
render_byte_at_logical:
    ;; Past-EOF check: logical >= file_length ?
    LD      DE, (render_file_length)
    PUSH    HL
    OR      A
    SBC     HL, DE                      ; CF = 1 iff logical < file_length
    POP     HL
    JR      NC, .past_eof

    ;; In-file. Branch on logical < gap_log (before-gap) vs >= (after-gap).
    LD      DE, (render_gap_log)
    PUSH    HL
    OR      A
    SBC     HL, DE                      ; CF = 1 iff logical < gap_log
    POP     HL
    JR      NC, .after_gap

.before_gap:
    PUSH    HL
    LD      DE, GAP_BUFFER_BASE
    ADD     HL, DE                      ; HL = GAP_BUFFER_BASE + logical
    LD      A, (HL)
    POP     HL                          ; restore caller's HL
    OR      A                           ; clear CF
    RET

.after_gap:
    PUSH    HL
    LD      DE, (render_after_gap_base)
    ADD     HL, DE                      ; HL = after_gap_base + logical
    LD      A, (HL)
    POP     HL
    OR      A
    RET

.past_eof:
    LD      A, 0x20                     ; render as space past EOF
    SCF
    RET

; ----------------------------------------------------------------
; render_scroll_adjust
; V2 scroll mechanism. Computes the cursor's logical row relative
; to top_line_offset, then:
;
;   - If cursor_offset < top_line_offset: retreat top_line_offset
;     backwards to the start of cursor's containing line; cursor
;     lands at row 0. Mark every editable row dirty.
;
;   - If cursor_row >= EDITABLE_ROWS (cursor below visible):
;     iteratively advance top_line_offset by 1 line-break at a
;     time, re-counting cursor's row from the new top. Stop when
;     cursor_row < EDITABLE_ROWS. Cursor lands at row
;     EDITABLE_ROWS-1 (on a 1-row scroll) or higher. Mark every
;     editable row dirty.
;
;   - Otherwise: no scroll; cursor_row is in range.
;
; The cursor>=top branch is iterative because render_count_rows
; caps its row count at EDITABLE_ROWS (to honour W2's byte-scan
; budget and avoid 8-bit wrap on deep files). Each iteration's
; scan is bounded; the iteration count is bounded by how many
; rows below visible the cursor sits. For typical 1-row scrolls
; this is one iteration. For pathological far-jumps (epic 2's
; G / gg motions on large files) the per-iteration recount adds
; up — addressed by a ring-buffer rewrite when those motions land.
;
; The scroll-induced "mark all editable dirty" sets every bit
; 0..EDITABLE_ROWS-1 (rows 0..22). Bit 23 (the status row in the
; bitmap, though render gates status emission on status_dirty,
; not bit 23) is left untouched.
;
; After this routine, render_cursor_row and render_cursor_col
; hold the cursor's final on-screen position (clamped to
; [0, EDITABLE_ROWS-1] for row and [0, SCREEN_COLS-1] for col).
;
; In:      (none — reads top_line_offset, cursor_offset)
; Out:     render_cursor_row / render_cursor_col set; possibly
;          top_line_offset updated; possibly editable-row dirty
;          bits set.
; Trashes: A, BC, DE, HL, F.
; Calls:   render_byte_at_logical (transitively).
; ----------------------------------------------------------------
render_scroll_adjust:
    ;; Branch on cursor_offset vs top_line_offset.
    LD      HL, (cursor_offset)
    LD      DE, (top_line_offset)
    OR      A
    SBC     HL, DE                      ; CF = 1 iff cursor < top
    JR      C, .retreat

    ;; cursor >= top branch. Iteratively advance top by 1 LF until
    ;; cursor_row < EDITABLE_ROWS.
    XOR     A
    LD      (render_scroll_did_advance), A
.advance_loop:
    CALL    render_count_rows_to_cursor
    ;; A = cursor_row (0..EDITABLE_ROWS, capped); HL = row_start; DE = cursor_offset.
    CP      EDITABLE_ROWS
    JR      C, .advance_done            ; A < EDITABLE_ROWS → cursor in range
    ;; A == EDITABLE_ROWS: cursor below visible. Advance top by 1 LF.
    LD      A, 1
    LD      (render_scroll_did_advance), A
    LD      HL, (top_line_offset)
    LD      B, 1
    CALL    render_advance_lines
    LD      (top_line_offset), HL
    JR      .advance_loop

.advance_done:
    ;; A = cursor_row (0..EDITABLE_ROWS-1); HL = row_start; DE = cursor_offset.
    LD      (render_cursor_row), A
    ;; cursor_col = cursor_offset - row_start (16-bit).
    EX      DE, HL                      ; HL = cursor_offset, DE = row_start
    OR      A
    SBC     HL, DE                      ; HL = cursor_col
    LD      A, H
    OR      A
    JR      NZ, .col_clamp_max          ; H ≠ 0 → col > 255, clamp
    LD      A, L
    CP      SCREEN_COLS
    JR      C, .col_ok
.col_clamp_max:
    LD      A, SCREEN_COLS - 1
.col_ok:
    LD      (render_cursor_col), A
    ;; If we advanced (forward scroll happened), mark all editable dirty.
    LD      A, (render_scroll_did_advance)
    OR      A
    RET     Z
    JP      .mark_all_editable

.retreat:
    ;; cursor < top. Retreat top_line_offset to the start of cursor's line.
    ;; Strategy: walk backwards from cursor_offset finding the byte
    ;; just after the last 0x0A. That is the start of cursor's row.
    LD      HL, (cursor_offset)
    CALL    render_find_line_start      ; HL = start of cursor's line
    LD      (top_line_offset), HL
    ;; cursor now sits on row 0 of the visible window.
    XOR     A
    LD      (render_cursor_row), A
    ;; cursor_col = cursor - row_start (16-bit).
    LD      DE, (cursor_offset)
    EX      DE, HL                      ; HL = cursor, DE = row_start
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      A
    JR      NZ, .ret_col_clamp_max      ; H ≠ 0 → col > 255, clamp
    LD      A, L
    CP      SCREEN_COLS
    JR      C, .ret_col_ok
.ret_col_clamp_max:
    LD      A, SCREEN_COLS - 1
.ret_col_ok:
    LD      (render_cursor_col), A
    ;; Fall through to mark_all_editable.

.mark_all_editable:
    ;; Set bits 0..EDITABLE_ROWS-1 (= 0..22) in dirty_rows.
    ;; That is bytes 0 and 1 fully (= 0xFF) and bit 6 of byte 2
    ;; (covers rows 16..22; bit 7 = row 23 is the status row).
    ;; Combined byte-2 mask: 0x7F.
    ;; Use OR-merge so any caller-set bits (e.g. the implicit
    ;; status-row bit, were one ever set) are preserved.
    LD      A, 0xFF
    LD      (dirty_rows), A
    LD      (dirty_rows + 1), A
    LD      A, (dirty_rows + 2)
    OR      0x7F                        ; bits 0..6 of byte 2 = rows 16..22
    LD      (dirty_rows + 2), A
    RET

; ----------------------------------------------------------------
; render_count_rows_to_cursor
; Walk forward from top_line_offset, counting 0x0A bytes
; encountered before reaching cursor_offset. Returns the row
; the cursor sits on and the logical offset of that row's
; first byte.
;
; The row count is capped at EDITABLE_ROWS: as soon as the
; walk has seen EDITABLE_ROWS line breaks, the cursor is known
; to be at or below the bottom of the visible window and the
; walk stops early. Caller (render_scroll_adjust) treats
; A == EDITABLE_ROWS as the "advance top by 1 LF and re-count"
; signal. The cap honours W2's per-frame byte-scan budget and
; keeps the 8-bit B register from wrapping on deep files
; (without it, files with >255 LFs above cursor produced a
; silently-wrapped row count and broken scroll arithmetic).
;
; The walk is also bounded by file_length (past-EOF returns
; immediately even if the caller's cursor_offset is invalid,
; though SR1 guarantees cursor_offset <= file_length).
;
; In:      (reads top_line_offset, cursor_offset)
; Out:     A  = cursor_row (0..EDITABLE_ROWS, capped)
;          HL = row_start_logical (logical offset of the start
;               of the cursor's row — top_line_offset if no LF
;               in [top, cursor], otherwise one past the last LF
;               that we counted)
;          DE = cursor_offset (preserved for caller's col math)
; Trashes: A, BC, DE, HL, F.
; Calls:   render_byte_at_logical.
; ----------------------------------------------------------------
render_count_rows_to_cursor:
    LD      HL, (top_line_offset)       ; HL = current logical offset
    LD      B, 0                        ; B = row count (capped at EDITABLE_ROWS)
    LD      (render_walk_rowstart), HL  ; row_start starts at top
.loop:
    ;; Reload DE every iteration — render_byte_at_logical trashes
    ;; DE (it reads render_file_length / render_gap_log into DE
    ;; internally), so we cannot carry cursor_offset in DE across
    ;; the read.
    LD      DE, (cursor_offset)
    PUSH    HL
    OR      A
    SBC     HL, DE                      ; CF = 1 iff HL < DE
    POP     HL
    JR      NC, .done
    ;; Read byte at HL.
    CALL    render_byte_at_logical
    JR      C, .done                    ; past-EOF: stop (cursor on this row)
    CP      0x0A
    JR      NZ, .next
    ;; Newline: row count += 1; row_start = HL + 1.
    INC     B
    INC     HL
    LD      (render_walk_rowstart), HL
    LD      A, B
    CP      EDITABLE_ROWS
    JR      NC, .done                   ; B reached cap → cursor below visible
    JR      .loop
.next:
    INC     HL
    JR      .loop
.done:
    LD      A, B
    LD      HL, (render_walk_rowstart)
    LD      DE, (cursor_offset)
    RET

; ----------------------------------------------------------------
; render_find_line_start
; Given a logical offset (HL), walk backwards until we either
; hit logical 0 (start of buffer) or find the byte just after
; a 0x0A. Returns that offset in HL. Used by the retreat-scroll
; path to put the cursor on row 0 of the visible window.
;
; In:      HL = logical offset to walk back from
; Out:     HL = start of the line that contains the input offset
; Trashes: A, BC, DE, F.
; Calls:   render_byte_at_logical.
; ----------------------------------------------------------------
render_find_line_start:
    LD      A, H
    OR      L
    RET     Z                           ; already at logical 0
.loop:
    DEC     HL
    CALL    render_byte_at_logical
    JR      C, .step                    ; past-EOF (won't normally happen here)
    CP      0x0A
    JR      Z, .found_lf
.step:
    LD      A, H
    OR      L
    JR      NZ, .loop                   ; keep walking back unless at 0
    RET                                 ; HL = 0
.found_lf:
    INC     HL                          ; one past the LF = line start
    RET

; ----------------------------------------------------------------
; render_advance_lines
; Walk forward through the buffer from HL, counting 0x0A bytes
; consumed. After consuming B line-breaks (i.e. the byte just
; past the Bth 0x0A becomes the answer), return. Past-EOF
; terminates the walk with the answer pinned at the EOF position.
;
; In:      HL = starting logical offset
;          B  = number of line breaks to skip (>= 1; B == 0 is a
;               caller error but is treated as "return immediately")
; Out:     HL = logical offset just past the Bth 0x0A (or
;               file_length if EOF intervened)
; Trashes: A, B, DE, F.
; Calls:   render_byte_at_logical.
; ----------------------------------------------------------------
render_advance_lines:
    LD      A, B
    OR      A
    RET     Z
.loop:
    CALL    render_byte_at_logical
    JR      C, .eof_stop                ; past-EOF: pin HL here
    INC     HL                          ; consume the byte
    CP      0x0A
    JR      NZ, .loop
    DJNZ    .loop
    RET
.eof_stop:
    RET

; ----------------------------------------------------------------
; render_emit_editable_rows
; The per-row dirty walk. For each row r in 0..EDITABLE_ROWS-1:
;   - Track the logical offset of the row's first byte
;     (advancing past the prior row's content + the terminating
;     0x0A, if any).
;   - If the row's dirty bit is set, walk cells 0..SCREEN_COLS-1
;     and emit contiguous runs of cells that differ from shadow.
;   - Always advance past the row's content even if not dirty,
;     so the next row's start is known.
;
; In:      (reads top_line_offset, dirty_rows, shadow_buffer)
; Out:     dirty rows reconciled to buffer content; shadow synced
;          for every emitted cell; cells unchanged from shadow
;          are NOT emitted (NFR1 idle-no-emission).
; Trashes: A, BC, DE, HL, F.
; Calls:   render_byte_at_logical, render_emit_byte,
;          render_emit_goto.
; ----------------------------------------------------------------
render_emit_editable_rows:
    LD      HL, (top_line_offset)
    LD      (render_read_pos), HL       ; current logical offset of the row's first byte
    XOR     A
    LD      (render_row), A             ; r = 0
.row_loop:
    LD      A, (render_row)
    CP      EDITABLE_ROWS
    RET     NC                          ; finished all editable rows

    ;; Test bit (r mod 8) in dirty_rows[r / 8]. If clear, skip
    ;; the emit but still walk the row content so we know where
    ;; the next row starts.
    CALL    render_row_is_dirty         ; CF = 1 if dirty, 0 otherwise; A = row preserved
    JR      NC, .skip_emit

    ;; Dirty: emit per-cell diff for this row.
    CALL    render_emit_one_row
    JR      .row_done

.skip_emit:
    ;; Not dirty: walk the row content silently to advance render_read_pos.
    CALL    render_skip_one_row

.row_done:
    LD      A, (render_row)
    INC     A
    LD      (render_row), A
    JR      .row_loop

; ----------------------------------------------------------------
; render_row_is_dirty
; Test bit (A mod 8) in dirty_rows[A / 8].
;
; In:      A = row index (0..SCREEN_ROWS-1)
; Out:     CF = 1 if the row's bit is set in dirty_rows;
;          CF = 0 otherwise. A preserved on exit.
; Trashes: BC, DE, HL, F.
; Calls:   (none).
; ----------------------------------------------------------------
render_row_is_dirty:
    LD      C, A                        ; C = row (preserved across the mask compute)
    SRL     A
    SRL     A
    SRL     A                           ; A = row / 8 = byte_idx
    LD      L, A
    LD      H, 0                        ; HL = byte_idx
    PUSH    HL                          ; save byte_idx across mask shift loop
    LD      A, C
    AND     0x07                        ; A = bit_idx (0..7)
    LD      B, A
    LD      A, 1
    INC     B                           ; pre-decrement so DJNZ ends after bit_idx shifts
    JR      .test
.shift:
    ADD     A, A
.test:
    DJNZ    .shift                      ; A = (1 << bit_idx)
    POP     HL                          ; HL = byte_idx
    LD      DE, dirty_rows
    ADD     HL, DE                      ; HL = dirty_rows + byte_idx
    AND     (HL)                        ; A = mask & dirty_rows[byte_idx]; Z reflects result
    LD      A, C                        ; A = row (restore caller invariant)
    JR      Z, .not_dirty
    SCF
    RET
.not_dirty:
    OR      A                           ; clear CF
    RET

; ----------------------------------------------------------------
; render_skip_one_row
; Walk forward through the buffer from render_read_pos, advancing
; past either SCREEN_COLS bytes or up to and including the next
; 0x0A or to EOF. Updates render_read_pos to the next row's
; first byte.
;
; The "or past SCREEN_COLS" half is for long-line rows: a 200-
; character logical line that is not 0x0A-terminated within the
; first 80 bytes still needs the next row's start to point at
; byte 80 (or past — see "wrap" decision below). For Story 1.11
; MVP, long lines truncate visually at column 79; the row-end
; (and so the next row's start) sits at the next 0x0A or EOF,
; not at column 80. This matches the "if past EOL space-pad"
; behavior in AC4 step 2.
;
; In:      (reads render_read_pos)
; Out:     render_read_pos advanced past the row's content and
;          its terminating 0x0A (if any).
; Trashes: A, BC, DE, HL, F.
; Calls:   render_byte_at_logical.
; ----------------------------------------------------------------
render_skip_one_row:
    LD      HL, (render_read_pos)
.loop:
    CALL    render_byte_at_logical
    JR      C, .eof                     ; past EOF
    INC     HL
    CP      0x0A
    JR      NZ, .loop
.eof:
    LD      (render_read_pos), HL
    RET

; ----------------------------------------------------------------
; render_emit_one_row
; Emit the per-cell diff for one row. For col 0..SCREEN_COLS-1:
;   - compute target byte (buffer byte at read_pos if still in-line;
;     0x20 otherwise);
;   - compare to shadow_buffer[row*SCREEN_COLS + col];
;   - if different and not in a run: emit ESC Y row col, mark
;     in_run = true;
;   - if different: emit target byte, update shadow byte;
;   - if same: close the run (in_run = false).
;
; After cell 79 the routine advances read_pos past any remaining
; bytes in the logical line (so the next row's start is correct).
;
; In:      render_row = r; render_read_pos = logical offset of
;          row r's first byte.
; Out:     row r's screen content reconciled; shadow row r synced;
;          render_read_pos advanced past the next line break (or
;          to EOF).
; Trashes: A, BC, DE, HL, F.
; Calls:   render_byte_at_logical, render_emit_byte,
;          render_emit_goto.
; ----------------------------------------------------------------
render_emit_one_row:
    ;; Compute shadow row pointer: shadow_buffer + r * SCREEN_COLS.
    LD      A, (render_row)
    LD      H, 0
    LD      L, A                        ; HL = r
    ADD     HL, HL                      ; r * 2
    ADD     HL, HL                      ; r * 4
    ADD     HL, HL                      ; r * 8
    ADD     HL, HL                      ; r * 16
    LD      D, H
    LD      E, L                        ; DE = r * 16
    ADD     HL, HL                      ; r * 32
    ADD     HL, HL                      ; r * 64
    ADD     HL, DE                      ; r * 80
    LD      DE, shadow_buffer
    ADD     HL, DE                      ; HL = shadow_buffer + r*80
    LD      (render_shadow_ptr), HL

    ;; Initialise per-row walk state.
    XOR     A
    LD      (render_past_eol), A
    LD      (render_in_run), A
    LD      (render_col), A             ; col = 0

.cell_loop:
    LD      A, (render_col)
    CP      SCREEN_COLS
    JR      NC, .row_emit_done

    ;; Compute target byte for this cell.
    LD      A, (render_past_eol)
    OR      A
    JR      NZ, .target_is_space

    LD      HL, (render_read_pos)
    CALL    render_byte_at_logical      ; A = byte, CF = 1 if past EOF
    JR      C, .hit_eof
    CP      0x0A
    JR      Z, .hit_lf

    ;; target = A; advance read_pos.
    INC     HL
    LD      (render_read_pos), HL
    JR      .have_target

.hit_lf:
    ;; Consume the LF and mark past-EOL; this column renders as space.
    INC     HL
    LD      (render_read_pos), HL
    LD      A, 1
    LD      (render_past_eol), A
    JR      .target_is_space

.hit_eof:
    ;; Past EOF: mark past-EOL (do NOT advance read_pos past EOF).
    LD      A, 1
    LD      (render_past_eol), A
    ;; fall through to target_is_space

.target_is_space:
    LD      A, 0x20

.have_target:
    ;; A = target byte. Compare to shadow at this cell.
    LD      B, A                        ; B = target (saved across compare + emits)
    LD      A, (render_col)
    LD      E, A
    LD      D, 0                        ; DE = col
    LD      HL, (render_shadow_ptr)
    ADD     HL, DE                      ; HL = shadow_buffer + r*80 + col
    LD      A, (HL)                     ; A = shadow byte
    CP      B
    JR      Z, .cell_match

    ;; Differ. Open a run if not already inside one.
    LD      A, (render_in_run)
    OR      A
    JR      NZ, .have_run

    PUSH    BC                          ; save B = target
    PUSH    HL                          ; save shadow cell ptr
    LD      A, (render_col)
    LD      C, A                        ; C = col
    LD      A, (render_row)             ; A = row
    CALL    render_emit_goto
    POP     HL
    POP     BC
    LD      A, 1
    LD      (render_in_run), A

.have_run:
    ;; Emit target byte and update shadow cell.
    PUSH    BC                          ; save B = target
    PUSH    HL                          ; save shadow cell ptr
    LD      A, B
    CALL    render_emit_byte
    POP     HL
    POP     BC
    LD      (HL), B                     ; shadow[r*80+col] = target
    JR      .cell_advance

.cell_match:
    ;; Cell matches shadow — close any open run.
    XOR     A
    LD      (render_in_run), A

.cell_advance:
    LD      A, (render_col)
    INC     A
    LD      (render_col), A
    JR      .cell_loop

.row_emit_done:
    ;; Drain the rest of the logical line so the next row's start
    ;; is correct. Skip until 0x0A consumed or EOF reached.
    LD      A, (render_past_eol)
    OR      A
    RET     NZ                          ; already past EOL; read_pos sits at next row

    LD      HL, (render_read_pos)
.drain:
    CALL    render_byte_at_logical
    JR      C, .drain_done
    INC     HL
    CP      0x0A
    JR      NZ, .drain
.drain_done:
    LD      (render_read_pos), HL
    RET

; ----------------------------------------------------------------
; render_emit_status_row
; Gated by status_dirty. Walks status_buffer (80 bytes) and
; diffs against shadow_buffer[STATUS_ROW * SCREEN_COLS + col]
; via the same contiguous-run discipline as the editable rows.
; Clears status_dirty when done — even if no bytes were emitted
; (the dirty flag means "buffer changed since last emit" and we
; have now reconciled the row).
;
; In:      (reads status_dirty, status_buffer)
; Out:     status row reconciled; shadow row 23 synced;
;          status_dirty = 0.
; Trashes: A, BC, DE, HL, F.
; Calls:   render_emit_byte, render_emit_goto.
; ----------------------------------------------------------------
render_emit_status_row:
    LD      A, (status_dirty)
    OR      A
    RET     Z                           ; not dirty: skip

    ;; Compute shadow row pointer for STATUS_ROW.
    LD      A, STATUS_ROW
    LD      H, 0
    LD      L, A
    ADD     HL, HL                      ; row*2
    ADD     HL, HL                      ; row*4
    ADD     HL, HL                      ; row*8
    ADD     HL, HL                      ; row*16
    LD      D, H
    LD      E, L
    ADD     HL, HL                      ; row*32
    ADD     HL, HL                      ; row*64
    ADD     HL, DE                      ; row*80
    LD      DE, shadow_buffer
    ADD     HL, DE
    LD      (render_shadow_ptr), HL

    XOR     A
    LD      (render_in_run), A
    LD      (render_col), A

.cell:
    LD      A, (render_col)
    CP      SCREEN_COLS
    JR      NC, .clear_dirty

    ;; Read status_buffer[col].
    LD      H, 0
    LD      L, A
    LD      DE, status_buffer
    ADD     HL, DE
    LD      B, (HL)                     ; B = target byte

    ;; Read shadow[STATUS_ROW*80 + col].
    LD      A, (render_col)
    LD      H, 0
    LD      L, A
    LD      DE, (render_shadow_ptr)
    ADD     HL, DE                      ; HL = shadow ptr + col
    LD      A, (HL)
    CP      B
    JR      Z, .stat_match

    ;; Differ: emit run-start (if needed), then byte, update shadow.
    LD      A, (render_in_run)
    OR      A
    JR      NZ, .stat_have_run

    PUSH    BC                          ; save target
    PUSH    HL                          ; save shadow ptr
    LD      A, (render_col)
    LD      C, A
    LD      A, STATUS_ROW
    CALL    render_emit_goto
    POP     HL
    POP     BC
    LD      A, 1
    LD      (render_in_run), A

.stat_have_run:
    PUSH    BC
    PUSH    HL
    LD      A, B
    CALL    render_emit_byte
    POP     HL
    POP     BC
    LD      (HL), B

    JR      .stat_advance

.stat_match:
    XOR     A
    LD      (render_in_run), A

.stat_advance:
    LD      A, (render_col)
    INC     A
    LD      (render_col), A
    JR      .cell

.clear_dirty:
    XOR     A
    LD      (status_dirty), A
    RET

; ----------------------------------------------------------------
; render_emit_byte
; The single, central wrapper around `LD C, A / CALL BIOS_CONOUT`.
; Every emit site in render.asm routes through here, which makes
; AR13 enforcement a one-line grep: BIOS_CONOUT must appear only
; in this routine (and any direct callers — emit_goto goes
; through emit_byte rather than calling BIOS_CONOUT itself for
; the same reason).
;
; In:      A = byte to emit
; Out:     byte sent to BIOS_CONOUT.
; Trashes: A, BC, F (BIOS may trash more; caller-saved per MC1).
; Calls:   BIOS_CONOUT.
; ----------------------------------------------------------------
render_emit_byte:
    LD      C, A
    CALL    BIOS_CONOUT
    RET

; ----------------------------------------------------------------
; render_emit_goto
; Compose `ESC Y row+bias col+bias` with the AC14 clamp. Clamps
; row to [0, SCREEN_ROWS-1] and col to [0, SCREEN_COLS-1] BEFORE
; adding VT52_COORD_BIAS. Resolution of the Story 1.2 deferral on
; VT52_GOTO clamping: every ESC Y emit in render.asm goes through
; here; no other code path can compose an unclamped GOTO.
;
; In:      A = row (raw, may exceed SCREEN_ROWS — clamped),
;          C = col (raw, may exceed SCREEN_COLS — clamped)
; Out:     4 bytes emitted (ESC, 'Y', row+bias, col+bias).
; Trashes: A, BC, F (D/E preserved by writing biased row/col
;          through module-local scratch — see Notes).
; Calls:   render_emit_byte (4 times).
; Notes:   An earlier version held biased row/col in D/E across
;          the four emit_byte calls. Story-1.12 hardware UAT
;          surfaced symptoms consistent with the MicroBeast
;          BIOS_CONOUT trashing D and/or E — ESC Y sequences
;          arrived at the terminal with garbage row/col bytes,
;          scattering each render run to random screen
;          positions. Resolution (the Story-1.11 deferral
;          promoted to a patch here): hold biased row/col in
;          two file-local scratch cells across the calls. The
;          BIOS may now trash any register at will.
; ----------------------------------------------------------------
render_emit_goto:
    ;; Clamp row.
    CP      SCREEN_ROWS
    JR      C, .row_ok
    LD      A, SCREEN_ROWS - 1
.row_ok:
    ADD     A, VT52_COORD_BIAS
    LD      (render_goto_row), A
    ;; Clamp col (was in C on entry).
    LD      A, C
    CP      SCREEN_COLS
    JR      C, .col_ok
    LD      A, SCREEN_COLS - 1
.col_ok:
    ADD     A, VT52_COORD_BIAS
    LD      (render_goto_col), A
    ;; Emit ESC, 'Y', biased row, biased col.
    LD      A, VT52_ESC
    CALL    render_emit_byte
    LD      A, VT52_GOTO
    CALL    render_emit_byte
    LD      A, (render_goto_row)
    CALL    render_emit_byte
    LD      A, (render_goto_col)
    JP      render_emit_byte            ; tail-JP


;; ============================================================
;; --- Module-local scratch (file-private; not in state.inc) ---
;; ============================================================
; Per-frame caches and walk state. Lives in the code segment as
; DEFB / DEFW so the initial bytes are deterministic at .com load
; time (whatever the DEFB says); every routine that consumes them
; writes before reading within a single render_diff invocation.
; These are NOT module-public state — no other source file
; references these labels.
;
; Policy: module-private scratch may live in the module's code
; segment (DEFB / DEFW between routines, written-before-read
; within each public-entry-point invocation). Story 1.3's MC7
; ("every shared writable byte in state.inc") applies to state
; that crosses module boundaries; module-local scratch that
; never escapes the module stays here so state.inc doesn't
; accumulate fields that only one module ever touches.
;
; Total: 13 bytes.

render_gap_log:               DEFW 0    ; gap_start - GAP_BUFFER_BASE
render_after_gap_base:        DEFW 0    ; gap_end - gap_log
render_file_length:           DEFW 0    ; total logical bytes
render_read_pos:              DEFW 0    ; current logical offset during row walks
render_shadow_ptr:            DEFW 0    ; shadow_buffer + r*SCREEN_COLS
render_walk_rowstart:         DEFW 0    ; row-start logical offset during row count
render_cursor_row:            DEFB 0    ; final on-screen cursor row
render_cursor_col:            DEFB 0    ; final on-screen cursor col
render_row:                   DEFB 0    ; current row index in editable-row loop
render_col:                   DEFB 0    ; current col index in cell loop
render_past_eol:              DEFB 0    ; nonzero once row content exhausted
render_in_run:                DEFB 0    ; nonzero while inside a contiguous diff run
render_scroll_did_advance:    DEFB 0    ; nonzero if scroll_adjust advanced top this frame
render_goto_row:              DEFB 0    ; biased row held across the 4 emit_byte calls in render_emit_goto
                                        ;   (defensive against BIOS_CONOUT D/E clobber — Story 1.12)
render_goto_col:              DEFB 0    ; biased col, same pattern
