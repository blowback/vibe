; ============================================================
; Module: motions.asm
; Purpose: Cursor-motion primitives (FR18-FR23). Lands the
;          h / j / k / l intra-line and inter-line motions in
;          Story 2.5; w / b / 0 / $ / gg / G arrive in Story 2.6;
;          counted-motion end-to-end verification is Story 2.7.
;          BH1 word-boundary classifier and BH2 clamp policy
;          realised here. Pure-read module against the gap buffer
;          (AR14 — no gapbuf_insert / gapbuf_delete / gapbuf_move_gap
;          writes); no screen emission (AR13); no BDOS (AR15 — clean).
;
;          motions.asm is the "clean module" archetype: zero
;          carve-outs, three architectural boundary rules (AR13,
;          AR14, AR15) all met cleanly. Compare fileio.asm's
;          three documented carve-outs (AR14 linear-fill, AR15
;          launch, AR15 save).
;
;          AC16 helper-placement decision (Story 2.5): the SR3
;          logical-byte read lives here as a motions.asm-private
;          helper (motion_byte_at_logical). Path A per the spec —
;          chosen because gapbuf.asm did not previously expose a
;          public read primitive and adding one is a wider AR14
;          surface change than this story should land. Story 2.6's
;          word-motion classifier will reuse this private helper;
;          if Story 3.1's search.asm needs the same read, the
;          decision can be revisited (extract to gapbuf.asm as a
;          public gapbuf_byte_at_logical, share with three callers).
;
;          BC-preservation invariant across helpers: motion_h /
;          motion_j / motion_k / motion_l keep the remaining step
;          count in BC across all helper calls. motion_byte_at_logical,
;          motion_find_line_start, motion_find_line_end, and
;          motion_apply_count all preserve BC (the byte-read helper
;          uses HL/DE-only math; the line-walk helpers don't touch
;          BC themselves and only call the byte-read helper which
;          preserves it). Without this invariant, every step would
;          need to save/restore count to a cell — wasted cycles in
;          the hot motion path.
;
; Public:
;   motion_h   ; cursor_offset -= 1 (BOF + line-start clamp)
;   motion_j   ; cursor moves down one line (column-preserving)
;   motion_k   ; cursor moves up one line (column-preserving)
;   motion_l   ; cursor_offset += 1 (EOL + EOF clamp)
;   ; Story 2.6 will add: motion_w, motion_b, motion_0,
;   ; motion_dollar, motion_G, motion_gg
;
; State owned (read/write):
;   cursor_offset   ; the sole writer surface for this story;
;                     in concert with gapbuf.asm + fileio.asm
;                     which write under different invariants.
;   motions_col     ; module-local scratch — saved column across
;                     a single j/k step (DEFW; 2 B).
;   motions_target_start ; module-local scratch — saved line_start
;                     of the destination line across a j/k step.
;
; State read-only:
;   gap_start, gap_end             ; SR2 / SR3 source data for the
;                                    byte-read helper.
;   count_accumulator              ; FR23 — count_apply reads.
;   pending_operator               ; only for parser_clear semantics
;                                    via the tail-JP (motion handlers
;                                    do NOT branch on operator state
;                                    in Story 2.5; Story 2.11 lands
;                                    that branching).
;   pending_motion_prefix          ; same as pending_operator above.
;
; Register conventions (across public entry points):
;   motion_h:   In:  A = key just consumed ('h' = 0x68).
;               Out: cursor_offset updated (or unchanged on
;                    immediate BOF / line-start clamp); parser
;                    state cleared (count_accumulator = 0,
;                    pending_operator = 0, pending_motion_prefix
;                    = 0) via parser_clear tail-JP.
;               Trashes: A, BC, DE, HL, F.
;               Calls: motion_apply_count, motion_byte_at_logical,
;                      parser_clear (tail-JP).
;   motion_l:   Same shape as motion_h. Key = 'l' (0x6C).
;   motion_j:   Same shape. Key = 'j' (0x6A). Calls also
;               motion_find_line_start, motion_find_line_end.
;   motion_k:   Same shape. Key = 'k' (0x6B). Calls also
;               motion_find_line_start, motion_find_line_end.
;
;   motion_byte_at_logical (internal): see contract block at routine.
;   motion_find_line_start (internal): see contract block at routine.
;   motion_find_line_end   (internal): see contract block at routine.
;   motion_apply_count     (internal): see contract block at routine.
;
; Architectural enforcement here:
;   AR13 — no screen emission. motions.asm contains zero
;          BIOS_CONOUT references; the post-motion cursor
;          reposition is driven by render.asm's RI4 invariant on
;          the next render_diff frame (cursor_offset is the sole
;          surface motions touch; render reads it).
;   AR14 — no buffer mutation. motions.asm reads gap_start /
;          gap_end via state.inc symbols; never writes them. The
;          SR3 math is logical->physical address compute only.
;   AR15 — no BDOS. motions.asm contains zero BDOS_CALL macro
;          invocations and zero raw CALL 0x0005 / CALL BDOS_ENTRY
;          sites. Pure-memory module.
;
;   Story 2.5 is the FIRST source module in src/ that lands with
;   all three boundary rules met cleanly and no carve-outs to
;   declare. Future modules (Story 2.6 motions extensions; Story
;   3.1 search) should aspire to the same shape; carve-outs in
;   fileio.asm are exceptions, not the norm.
;
; Dependencies:
;   inc/equates.inc  (GAP_BUFFER_MAX)
;   inc/state.inc    (GAP_BUFFER_BASE, gap_start, gap_end,
;                     cursor_offset, count_accumulator)
;   src/parser.asm   (parser_clear — tail-JP from every motion
;                     handler; resolved forward by sjasmplus's
;                     two-pass model since parser.asm INCLUDEs
;                     before motions.asm in vibe.asm's AR25 chain)
; ============================================================

;; ============================================================
;; --- Public entry: motion_h (FR18; AC2, AC7) ---
;; ============================================================

; ----------------------------------------------------------------
; motion_h
; Cursor moves left one byte per step, up to (effective count)
; steps. Two clamps end the walk early:
;   - BOF: cursor_offset == 0 → stop (we're at offset 0; can't
;     decrement).
;   - Intra-line: byte at cursor_offset - 1 is 0x0A → stop without
;     stepping. Vibe's h does NOT cross the prior newline (epics
;     line 1061). This produces the same observable behaviour as
;     real vi's "stop at first non-newline of current line" for any
;     line that begins at column 0 (the only case pre-tab MVP).
;
; In:      A = 'h' (MC4; ignored — handler reads count_accumulator
;               via motion_apply_count instead of via A).
; Out:     cursor_offset updated (or unchanged on immediate clamp);
;          parser state cleared via parser_clear tail-JP.
; Trashes: A, BC, DE, HL, F.
; Calls:   motion_apply_count, motion_byte_at_logical, parser_clear
;          (tail-JP).
; ----------------------------------------------------------------
motion_h:
    CALL    motion_apply_count          ; BC = effective count
    LD      HL, (cursor_offset)
.step:
    LD      A, H
    OR      L
    JR      Z, .done                    ; BOF clamp (cursor == 0)
    DEC     HL                          ; HL = cursor - 1 (candidate)
    CALL    motion_byte_at_logical      ; A = byte at HL; HL preserved
    CP      0x0A
    JR      Z, .clamp_undo              ; intra-line clamp: undo dec
    DEC     BC
    LD      A, B
    OR      C
    JR      NZ, .step
.done:
    LD      (cursor_offset), HL
    JP      parser_clear

.clamp_undo:
    ;; The DEC HL above was speculative; the byte at HL-1 turned out
    ;; to be 0x0A so the step doesn't commit. Restore HL to the
    ;; pre-DEC value before saving.
    INC     HL
    JR      .done


;; ============================================================
;; --- Public entry: motion_l (FR18; AC3, AC7) ---
;; ============================================================

; ----------------------------------------------------------------
; motion_l
; Cursor moves right one byte per step, up to (effective count)
; steps. Two clamps + one defensive guard end the walk early:
;   - EOF: cursor_offset >= file_length (motion_byte_at_logical
;     returns CF=1) → stop. (file_length = gap_start + GAP_BUFFER_MAX
;     - gap_end.)
;   - Defensive cursor-on-LF: byte at cursor_offset is 0x0A. This
;     can happen only if a prior motion (j to an empty line) put
;     the cursor on a lone newline byte. From that position l is a
;     no-op (epics line 1067 — l does not cross newlines).
;   - Intra-line EOL: byte at cursor_offset + 1 is 0x0A → stop.
;     Cursor can never LAND on the newline byte itself; the
;     rightmost reachable position on an N-character line is
;     column N-1 (the last printable byte).
;
; The "peek the destination" check is necessary because the
; clamp invariant the spec calls for is "cursor never lands on
; an LF as a result of l". The plain "byte-at-cursor LF stop"
; check (post-step) alone would allow l from cursor=N-1 to step
; onto LF at N, then stop NEXT iteration — wrong for the
; single-step l case (motions_l-clamps-at-eol test pins this).
;
; In:      A = 'l' (MC4; ignored).
; Out:     cursor_offset updated (or unchanged on immediate clamp).
; Trashes: A, BC, DE, HL, F.
; Calls:   motion_apply_count, motion_byte_at_logical, parser_clear
;          (tail-JP).
; ----------------------------------------------------------------
motion_l:
    CALL    motion_apply_count          ; BC = count
    LD      HL, (cursor_offset)
.step:
    ;; Check current cursor: past EOF or on LF? Either way, can't
    ;; move (defensive against the j-to-empty-line case + EOF
    ;; cursor sentinel).
    CALL    motion_byte_at_logical      ; A = byte at HL; CF=1 if HL >= file_length
    JR      C, .done                    ; cursor at or past EOF
    CP      0x0A
    JR      Z, .done                    ; cursor on LF (empty-line edge)
    ;; Peek the destination: byte at HL + 1.
    INC     HL
    CALL    motion_byte_at_logical      ; A = byte at HL+1; CF=1 if past EOF
    JR      C, .clamp_undo              ; destination past EOF → stop
    CP      0x0A
    JR      Z, .clamp_undo              ; destination is LF → stop (don't land on LF)
    ;; OK to advance — HL is already at cursor+1.
    DEC     BC
    LD      A, B
    OR      C
    JR      NZ, .step
.done:
    LD      (cursor_offset), HL
    JP      parser_clear

.clamp_undo:
    ;; The INC HL above was speculative; the destination would have
    ;; been LF or past EOF. Restore HL before saving.
    DEC     HL
    JR      .done


;; ============================================================
;; --- Public entry: motion_j (FR19; AC4, AC7) ---
;; ============================================================

; ----------------------------------------------------------------
; motion_j
; Cursor moves down one line per step (up to effective count
; steps), preserving the saved column where the next line has
; enough characters; clamping to the line's rightmost printable
; byte where it doesn't (vi's column-preserving j with
; shorter-line clamp — epics line 1071).
;
; Per-step algorithm:
;   1. col = cursor - line_start(cursor)        [save in motions_col]
;   2. current_eol = line_end(cursor)
;   3. If current_eol is past EOF (no LF before EOF), stop — no
;      next line (BH2 last-line clamp).
;   4. next_line_start = current_eol + 1.       [save in motions_target_start]
;   5. next_eol = line_end(next_line_start)
;   6. next_line_length = next_eol - next_line_start
;   7. clamp_col = (next_line_length > 0) ? next_line_length - 1
;                                          : 0
;      (The "-1" because cursor must not land on the LF byte itself;
;       the rightmost valid column in an N-char line is N-1. An
;       empty line — length 0 — has only one valid position, the
;       LF/EOF at line_start itself.)
;   8. new_col = min(col, clamp_col)
;   9. cursor = next_line_start + new_col       [commit]
;
; In:      A = 'j' (MC4; ignored).
; Out:     cursor_offset updated (or unchanged on no-next-line clamp).
; Trashes: A, BC, DE, HL, F (motions_col / motions_target_start
;          scratch cells written).
; Calls:   motion_apply_count, motion_find_line_start,
;          motion_find_line_end, motion_byte_at_logical,
;          parser_clear (tail-JP).
; ----------------------------------------------------------------
motion_j:
    CALL    motion_apply_count          ; BC = count
.step:
    ;; --- col = cursor - line_start(cursor) ---
    LD      HL, (cursor_offset)
    PUSH    HL                          ; [cursor]
    CALL    motion_find_line_start      ; HL = current_line_start
    POP     DE                          ; DE = cursor; ()
    EX      DE, HL                      ; HL = cursor, DE = current_line_start
    OR      A
    SBC     HL, DE                      ; HL = col
    LD      (motions_col), HL

    ;; --- current_eol = line_end(cursor) ---
    LD      HL, (cursor_offset)
    CALL    motion_find_line_end        ; HL = current_eol (LF pos) or file_length

    ;; --- Past EOF (no LF before EOF)? motion_byte_at_logical sets CF=1 ---
    CALL    motion_byte_at_logical      ; A = byte at HL; CF=1 if HL >= file_length
    JR      C, .done                    ; last line — no next line, cursor unchanged

    ;; --- next_line_start = current_eol + 1 ---
    INC     HL
    LD      (motions_target_start), HL

    ;; --- next_eol; next_line_length = next_eol - next_line_start ---
    CALL    motion_find_line_end        ; HL = next_eol
    LD      DE, (motions_target_start)
    OR      A
    SBC     HL, DE                      ; HL = next_line_length

    ;; --- clamp_col = (length > 0) ? length - 1 : 0 ---
    LD      A, H
    OR      L
    JR      Z, .clamp_zero
    DEC     HL                          ; HL = length - 1
.clamp_zero:

    ;; --- new_col = min(col, clamp_col); HL holds clamp_col, motions_col holds col ---
    LD      DE, (motions_col)
    PUSH    HL
    OR      A
    SBC     HL, DE                      ; CF=1 iff clamp_col < col → use clamp_col
    POP     HL
    JR      NC, .use_col                ; clamp_col >= col → use col
    ;; HL stays as clamp_col (the smaller of the two)
    JR      .commit
.use_col:
    EX      DE, HL                      ; HL = col

.commit:
    ;; HL = new_col; cursor = motions_target_start + new_col.
    LD      DE, (motions_target_start)
    ADD     HL, DE
    LD      (cursor_offset), HL

    DEC     BC
    LD      A, B
    OR      C
    JR      NZ, .step
.done:
    JP      parser_clear


;; ============================================================
;; --- Public entry: motion_k (FR19; AC5, AC7) ---
;; ============================================================

; ----------------------------------------------------------------
; motion_k
; Cursor moves up one line per step (up to effective count
; steps), preserving column with shorter-line clamp. Symmetric
; with motion_j.
;
; Per-step algorithm:
;   1. col = cursor - line_start(cursor)              [save in motions_col]
;   2. current_line_start = line_start(cursor)
;   3. If current_line_start == 0, stop (already on line 0 —
;      BH2 first-line clamp).
;   4. prev_line_start = line_start(current_line_start - 1)
;      (Walks from the LF that BEGINS the current line — the byte
;       at offset current_line_start - 1 — back to the byte just
;       past the prior LF, or to offset 0 at BOF.)
;   5. prev_line_length = (current_line_start - 1) - prev_line_start
;      (Subtract 1 for the LF byte itself.)
;   6. clamp_col = (prev_line_length > 0) ? prev_line_length - 1 : 0
;   7. new_col = min(col, clamp_col)
;   8. cursor = prev_line_start + new_col              [commit]
;
; In:      A = 'k' (MC4; ignored).
; Out:     cursor_offset updated (or unchanged on line-0 clamp).
; Trashes: A, BC, DE, HL, F.
; Calls:   motion_apply_count, motion_find_line_start, parser_clear
;          (tail-JP).
; ----------------------------------------------------------------
motion_k:
    CALL    motion_apply_count          ; BC = count
.step:
    ;; --- col = cursor - line_start(cursor) ---
    LD      HL, (cursor_offset)
    PUSH    HL                          ; [cursor]
    CALL    motion_find_line_start      ; HL = current_line_start
    POP     DE                          ; DE = cursor; ()
    EX      DE, HL                      ; HL = cursor, DE = current_line_start
    OR      A
    SBC     HL, DE                      ; HL = col
    LD      (motions_col), HL

    ;; --- At line 0? current_line_start == 0? ---
    LD      A, D
    OR      E
    JR      Z, .done                    ; can't go up; cursor unchanged

    ;; --- prev_line_start = line_start(current_line_start - 1) ---
    PUSH    DE                          ; [current_line_start]
    EX      DE, HL                      ; HL = current_line_start
    DEC     HL                          ; HL = current_line_start - 1 (LF of prev line)
    CALL    motion_find_line_start      ; HL = prev_line_start
    LD      (motions_target_start), HL

    ;; --- prev_line_length = (current_line_start - 1) - prev_line_start ---
    POP     DE                          ; DE = current_line_start; ()
    EX      DE, HL                      ; HL = current_line_start, DE = prev_line_start
    OR      A
    SBC     HL, DE                      ; HL = current_line_start - prev_line_start
    DEC     HL                          ; HL = prev_line_length (subtract the LF byte)

    ;; --- clamp_col = (length > 0) ? length - 1 : 0 ---
    LD      A, H
    OR      L
    JR      Z, .clamp_zero_k
    DEC     HL                          ; HL = length - 1
.clamp_zero_k:

    ;; --- new_col = min(col, clamp_col) ---
    LD      DE, (motions_col)
    PUSH    HL
    OR      A
    SBC     HL, DE                      ; CF=1 iff clamp_col < col
    POP     HL
    JR      NC, .use_col_k
    JR      .commit_k
.use_col_k:
    EX      DE, HL                      ; HL = col

.commit_k:
    ;; cursor = motions_target_start + new_col
    LD      DE, (motions_target_start)
    ADD     HL, DE
    LD      (cursor_offset), HL

    DEC     BC
    LD      A, B
    OR      C
    JR      NZ, .step
.done:
    JP      parser_clear


;; ============================================================
;; --- Internal helper: motion_byte_at_logical (SR3 byte-read) ---
;; ============================================================

; ----------------------------------------------------------------
; motion_byte_at_logical
; Translate a 16-bit logical offset (HL) into the physical byte
; the gap buffer holds at that offset. Pure-read against
; gap_start / gap_end (no caching — motions run between render
; frames; the render module's cached version is per-frame-fresh
; and not usable here).
;
; SR3 math:
;     file_length     = gap_start + GAP_BUFFER_MAX - gap_end
;     gap_log         = gap_start - GAP_BUFFER_BASE
;     if HL < gap_log:  physical = GAP_BUFFER_BASE + HL
;     else:             physical = gap_end + (HL - gap_log)
;
; The routine uses HL and DE only (no BC), so callers can keep
; the motion step count in BC across the call.
;
; In:      HL = logical offset.
; Out:     A  = byte at logical offset; CF = 0 in-file.
;            OR
;          CF = 1 (A undefined) if HL >= file_length (past-EOF).
;          HL preserved on every path.
; Trashes: A, DE, F.
; Calls:   (none).
; ----------------------------------------------------------------
motion_byte_at_logical:
    PUSH    HL                          ; save caller's logical; [logical]

    ;; --- Past-EOF check: logical >= file_length? ---
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_MAX
    ADD     HL, DE                      ; HL = gap_start + GAP_BUFFER_MAX
    LD      DE, (gap_end)
    OR      A
    SBC     HL, DE                      ; HL = file_length
    EX      DE, HL                      ; DE = file_length
    POP     HL                          ; HL = logical; ()
    PUSH    HL                          ; [logical] (re-saved for end-of-routine HL restore)
    OR      A
    SBC     HL, DE                      ; CF = 1 iff logical < file_length
    JR      NC, .past_eof

    ;; --- In-file. Compute gap_log; branch before-gap vs after-gap. ---
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE                      ; HL = gap_log
    EX      DE, HL                      ; DE = gap_log
    POP     HL                          ; HL = logical; ()
    PUSH    HL                          ; [logical]
    OR      A
    SBC     HL, DE                      ; HL = logical - gap_log; CF = 1 iff before-gap
    JR      NC, .after_gap

.before_gap:
    POP     HL                          ; HL = logical; ()
    PUSH    HL                          ; [logical]
    LD      DE, GAP_BUFFER_BASE
    ADD     HL, DE                      ; HL = physical
    LD      A, (HL)
    POP     HL                          ; restore caller's logical; ()
    OR      A                           ; clear CF
    RET

.after_gap:
    ;; HL = logical - gap_log (offset into after-gap region)
    LD      DE, (gap_end)
    ADD     HL, DE                      ; HL = physical
    LD      A, (HL)
    POP     HL                          ; restore caller's logical; ()
    OR      A                           ; clear CF
    RET

.past_eof:
    POP     HL                          ; restore caller's logical; ()
    SCF
    RET


;; ============================================================
;; --- Internal helper: motion_find_line_start ---
;; ============================================================

; ----------------------------------------------------------------
; motion_find_line_start
; Walk backward from HL through the buffer; return the offset of
; the byte just past the previous 0x0A, or 0 if no previous LF
; (i.e., HL was on line 0). HL=0 input returns HL=0.
;
; Algorithm: while HL > 0, inspect the byte at HL - 1. If that
; byte is 0x0A, return HL (which is the byte just past the LF —
; the start of the current line). Otherwise decrement HL and
; continue. When HL reaches 0, return 0.
;
; BC is preserved (the only callee, motion_byte_at_logical,
; preserves BC; this routine does not touch BC).
;
; In:      HL = logical offset.
; Out:     HL = offset of byte just after previous 0x0A, or 0.
; Trashes: A, DE, F. BC, IX, IY preserved.
; Calls:   motion_byte_at_logical.
; ----------------------------------------------------------------
motion_find_line_start:
.loop:
    LD      A, H
    OR      L
    RET     Z                           ; HL == 0 → line starts at 0
    DEC     HL                          ; HL = candidate predecessor offset
    CALL    motion_byte_at_logical      ; A = byte at HL
    CP      0x0A
    JR      NZ, .loop                   ; not LF, keep walking back
    ;; Byte at (HL_pre - 1) is 0x0A; the line starts at HL_pre = HL + 1.
    INC     HL
    RET


;; ============================================================
;; --- Internal helper: motion_find_line_end ---
;; ============================================================

; ----------------------------------------------------------------
; motion_find_line_end
; Walk forward from HL through the buffer; return the offset of
; the next 0x0A (the LF byte itself, not the byte past it), or
; the file_length if no LF before EOF.
;
; The "file_length on no LF" semantic comes naturally from
; motion_byte_at_logical: when HL reaches the file_length the
; helper sets CF=1, the routine RET Cs, and HL is preserved (==
; file_length).
;
; In:      HL = logical offset (start of walk).
; Out:     HL = offset of next 0x0A, or file_length if none.
; Trashes: A, DE, F. BC, IX, IY preserved.
; Calls:   motion_byte_at_logical.
; ----------------------------------------------------------------
motion_find_line_end:
.loop:
    CALL    motion_byte_at_logical      ; A = byte at HL; CF=1 if past EOF
    RET     C                           ; HL = file_length, return
    CP      0x0A
    RET     Z                           ; found LF → HL = LF position
    INC     HL
    JR      .loop


;; ============================================================
;; --- Internal helper: motion_apply_count ---
;; ============================================================

; ----------------------------------------------------------------
; motion_apply_count
; Read count_accumulator into BC; if the value is zero apply the
; vi "no count means 1" default. Centralised so each motion
; handler doesn't repeat the BC-loaded-with-defaulted-count
; preamble.
;
; In:      (none — reads count_accumulator).
; Out:     BC = effective step count (1..65535; never 0).
; Trashes: A, F.
; Calls:   (none).
; ----------------------------------------------------------------
motion_apply_count:
    LD      BC, (count_accumulator)
    LD      A, B
    OR      C
    RET     NZ
    LD      BC, 1
    RET


;; ============================================================
;; --- Module-local scratch cells ---
;; ============================================================
; Both cells are written exclusively inside motion_j / motion_k
; step bodies; helper routines do not touch them. The cells live
; in the code section (TPA) per the module-local-data convention
; (matches render.asm's render_gap_log / render_after_gap_base /
; render_file_length placement); state.inc is reserved for
; cross-module state.

motions_col:           DEFW 0    ; saved column across a j/k step
motions_target_start:  DEFW 0    ; saved destination line_start across a j/k step
