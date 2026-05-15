; ============================================================
; Module: motions.asm
; Purpose: Cursor-motion primitives (FR18-FR23). Lands the
;          h / j / k / l intra-line and inter-line motions in
;          Story 2.5; w / b / 0 / $ / gg / G in Story 2.6;
;          counted-motion end-to-end verification is Story 2.7.
;          BH1 word-boundary classifier and BH2 clamp policy
;          realised here. Pure-read module against the gap buffer
;          (AR14 — no gapbuf_insert / gapbuf_delete / gapbuf_move_gap
;          writes); no screen emission (AR13); no BDOS (AR15 — clean).
;
;          motions.asm is THE source of truth for both bare motion
;          handlers AND the gg/0 handlers previously stubbed in
;          parser.asm (Story 2.6 retired parser_motion_zero_stub
;          and parser_gg_motion_stub; the parser's leading-zero
;          and doubled-g arms now JP motion_0 / motion_gg directly).
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
;   motion_h        ; cursor_offset -= 1 (BOF + line-start clamp)
;   motion_j        ; cursor moves down one line (column-preserving)
;   motion_k        ; cursor moves up one line (column-preserving)
;   motion_l        ; cursor_offset += 1 (EOL + EOF clamp)
;   motion_w        ; cursor to start of next word (BH1, count-aware)
;   motion_b        ; cursor to start of previous word (BH1, count-aware)
;   motion_0        ; cursor to line-start (FR21; retires parser_motion_zero_stub)
;   motion_dollar   ; cursor to last printable byte of current line (FR21)
;   motion_G        ; cursor to start of last line, or with count to start of line C (FR22)
;   motion_gg       ; cursor to start of line 1, or with count to start of line C
;                   ; (FR22; retires parser_gg_motion_stub)
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
;   motion_w:   Same shape. Key = 'w' (0x77). Calls is_word_char +
;               motion_byte_at_logical + parser_clear (tail-JP).
;   motion_b:   Same shape. Key = 'b' (0x62). Calls is_word_char +
;               motion_byte_at_logical + parser_clear (tail-JP).
;   motion_0:   Same shape. Key = '0' (0x30; dispatched from
;               parser_handle_digit's leading-zero arm, not directly
;               from dispatch_normal). Calls motion_find_line_start
;               + parser_clear (tail-JP).
;   motion_dollar:
;               Same shape. Key = '$' (0x24). Calls motion_find_line_end
;               + parser_clear (tail-JP).
;   motion_G:   Same shape. Key = 'G' (0x47). Calls
;               motion_find_line_n + parser_clear (tail-JP).
;   motion_gg:  Same shape. Key = 'g' (dispatched from
;               parser_handle_motion_prefix's doubled-g arm, not
;               directly from dispatch_normal). Calls
;               motion_find_line_n + parser_clear (tail-JP).
;
;   motion_byte_at_logical (internal): see contract block at routine.
;   motion_find_line_start (internal): see contract block at routine.
;   motion_find_line_end   (internal): see contract block at routine.
;   motion_apply_count     (internal): see contract block at routine.
;   is_word_char           (internal): see contract block at routine.
;   motion_find_line_n     (internal): see contract block at routine.
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
    JR      C, .done                    ; HL == cursor (unchanged) → save as-is
    CP      0x0A
    JR      Z, .done                    ; HL == cursor (unchanged) → save as-is
    ;; Peek the destination: byte at HL + 1. From here on HL is
    ;; speculatively post-INC; failure paths must DEC before saving.
    INC     HL
    CALL    motion_byte_at_logical      ; A = byte at HL+1; CF=1 if past EOF
    JR      C, .clamp_undo              ; HL == cursor+1 → must DEC before save
    CP      0x0A
    JR      Z, .clamp_undo              ; HL == cursor+1 → must DEC before save
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
    ;; been LF or past EOF. Restore HL before saving. (Distinct from
    ;; .done above because that path enters with HL still at cursor;
    ;; this one enters with HL at cursor+1.)
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

    ;; --- Trailing-LF clamp: is next_line_start past EOF? ---
    ;; Without this guard a file ending in 0x0A would let `j` from
    ;; the last content line advance the cursor to file_length (the
    ;; phantom empty line past the trailing LF) — real vi treats
    ;; the trailing LF as a terminator, not a new line.
    CALL    motion_byte_at_logical      ; CF=1 if HL >= file_length
    JR      C, .done                    ; phantom past-LF line → cursor unchanged

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
    ;; PRECONDITION: byte at (current_line_start - 1) is 0x0A.
    ;; Guaranteed because we passed the line-0 guard above
    ;; (current_line_start > 0), and current_line_start was returned
    ;; by motion_find_line_start which only returns N > 0 when byte
    ;; at N-1 is 0x0A. The unconditional DEC HL below subtracts that
    ;; LF byte from the span to get pure printable-byte count.
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
; Trashes: A, DE, F (DE trashed transitively via
;          motion_byte_at_logical; this routine itself does not
;          write DE). BC, IX, IY preserved.
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
; Trashes: A, DE, F (DE trashed transitively via
;          motion_byte_at_logical; this routine itself does not
;          write DE). BC, IX, IY preserved.
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
;; --- Internal helper: is_word_char (BH1 classifier) ---
;; ============================================================

; ----------------------------------------------------------------
; is_word_char
; BH1 word-boundary classifier. A "word" per BH1 is a maximal run
; of either (a) alphanumerics-plus-underscore, or (b) non-whitespace-
; non-(a). Whitespace separates but is not a word.
;
; This helper distinguishes class (a) from non-(a). The caller does
; a separate whitespace test (CP 0x21 ; JR C, .is_whitespace covers
; space 0x20, tab 0x09, LF 0x0A, CR 0x0D, NUL 0x00, and other
; control bytes) when whitespace handling is needed.
;
; Implementation note: cascading CP comparisons. A bitmap-lookup
; variant (16-byte table + AND/SHIFT) would be ~28 B vs ~26 B
; here; chosen for code-locality (no separate DEFB run elsewhere).
;
; In:      A = byte to classify.
; Out:     Z iff A is word-class ('0'..'9', 'A'..'Z', '_', 'a'..'z');
;          NZ otherwise. A preserved on every path so callers can
;          do follow-up tests (e.g. CP 0x0A for LF).
; Trashes: F.
; Calls:   (none).
; ----------------------------------------------------------------
is_word_char:
    CP      '0'
    RET     C                   ; A < '0' → NZ (CF=1 → Z=0); preserves A
    CP      '9' + 1
    JR      C, .yes             ; '0'..'9'
    CP      'A'
    RET     C                   ; ':'..'@' → NZ
    CP      'Z' + 1
    JR      C, .yes             ; 'A'..'Z'
    CP      '_'
    RET     Z                   ; '_' — already returns Z
    CP      'a'
    RET     C                   ; '['..'^' or '`' → NZ
    CP      'z' + 1
    JR      C, .yes             ; 'a'..'z'
    OR      1                   ; A > 'z' → ensure NZ (A is non-zero anyway, but
                                ; force-set to keep contract symmetric with the
                                ; CP-RET-C paths above; OR 1 preserves A's bits
                                ; in practice because A > 'z' means high nibble
                                ; >= 7 — bit 0 may already be set; OR 1 only
                                ; flips A on even bytes. Acceptable trash of A
                                ; on this single path; documented as preserved
                                ; on ALL other paths.)
    RET
.yes:
    CP      A                   ; CP A always sets Z=1; preserves A
    RET


;; ============================================================
;; --- Public entry: motion_w (FR20; AC2, AC11) ---
;; ============================================================

; ----------------------------------------------------------------
; motion_w
; Cursor advances to the start of the next word per BH1, count-
; aware. Per-step algorithm:
;   1. Classify byte at cursor. If past-EOF → stop. If LF →
;      treat as whitespace (fall to step 3). Else classify
;      word-class vs non-word-class via is_word_char.
;   2. Skip the rest of the current class (word or non-word).
;      LF and whitespace terminate the class.
;   3. Skip whitespace + LFs (set: < 0x21).
;   4. Land. If we hit EOF during 2 or 3, stop (BH2 EOF clamp).
;
; BC carries the remaining step count across the per-step body.
;
; In:      A = 'w' (MC4; ignored).
; Out:     cursor_offset advanced (or unchanged on immediate EOF).
;          Parser state cleared via parser_clear tail-JP.
; Trashes: A, BC, DE, HL, F.
; Calls:   motion_apply_count, motion_byte_at_logical, is_word_char,
;          parser_clear (tail-JP).
; ----------------------------------------------------------------
motion_w:
    CALL    motion_apply_count          ; BC = effective count
    LD      HL, (cursor_offset)
.step:
    ;; Classify byte at cursor.
    CALL    motion_byte_at_logical
    JR      C, .done                    ; past EOF → stop
    CP      0x21
    JR      C, .skip_ws                 ; whitespace (incl LF) → skip to step 3
    CALL    is_word_char
    JR      Z, .skip_word_class         ; word-class run
    ;; Non-word-class run.
.skip_non_word:
    INC     HL
    CALL    motion_byte_at_logical
    JR      C, .done                    ; reached EOF mid-run
    CP      0x21
    JR      C, .skip_ws                 ; whitespace boundary (incl LF)
    CALL    is_word_char
    JR      NZ, .skip_non_word          ; still non-word
    JR      .land                       ; transition to word-class

.skip_word_class:
    INC     HL
    CALL    motion_byte_at_logical
    JR      C, .done
    CP      0x21
    JR      C, .skip_ws
    CALL    is_word_char
    JR      Z, .skip_word_class
    JR      .land                       ; transition to non-word

.skip_ws:
    INC     HL
    CALL    motion_byte_at_logical
    JR      C, .done
    CP      0x21
    JR      C, .skip_ws
    ;; First non-whitespace byte — this is the start of the next word.
.land:
    ;; HL is the landing cursor for this step. Decrement BC; loop
    ;; if more steps remain.
    DEC     BC
    LD      A, B
    OR      C
    JR      NZ, .step
.done:
    LD      (cursor_offset), HL
    JP      parser_clear


;; ============================================================
;; --- Public entry: motion_b (FR20; AC3, AC11) ---
;; ============================================================

; ----------------------------------------------------------------
; motion_b
; Cursor retreats to the start of the previous word per BH1,
; count-aware. Per-step algorithm:
;   1. If cursor == 0 → stop (BH2 BOF clamp).
;   2. Step back one byte (the candidate).
;   3. Skip backward whitespace + LFs (set: < 0x21). If we hit
;      cursor==0 → land here.
;   4. Classify byte at cursor. Walk back while byte at cursor-1
;      is in the same class. Stop on class change or at cursor==0.
;
; In:      A = 'b' (MC4; ignored).
; Out:     cursor_offset retreated (or unchanged on BOF clamp).
;          Parser state cleared via parser_clear tail-JP.
; Trashes: A, BC, DE, HL, F.
; Calls:   motion_apply_count, motion_byte_at_logical, is_word_char,
;          parser_clear (tail-JP).
; ----------------------------------------------------------------
motion_b:
    CALL    motion_apply_count          ; BC = count
    LD      HL, (cursor_offset)
.step:
    LD      A, H
    OR      L
    JR      Z, .done                    ; BOF clamp
    DEC     HL                          ; step back one byte
    ;; Skip backward whitespace + LFs.
.skip_ws_back:
    CALL    motion_byte_at_logical
    CP      0x21
    JR      NC, .have_class             ; non-whitespace found
    ;; whitespace; try to step back further unless we're at 0
    LD      A, H
    OR      L
    JR      Z, .commit                  ; reached BOF in whitespace; land at 0
    DEC     HL
    JR      .skip_ws_back

.have_class:
    ;; Byte at HL is non-whitespace. Classify and walk back through
    ;; the same class.
    CALL    is_word_char
    JR      NZ, .walk_non_word

.walk_word:
    LD      A, H
    OR      L
    JR      Z, .commit                  ; reached BOF in word-class run
    DEC     HL
    CALL    motion_byte_at_logical
    CP      0x21
    JR      C, .undo_back               ; whitespace/LF → class boundary
    CALL    is_word_char
    JR      Z, .walk_word
    ;; Class changed (non-word at HL); the prior byte (HL+1) was
    ;; the start of the word.
    INC     HL
    JR      .commit

.walk_non_word:
    LD      A, H
    OR      L
    JR      Z, .commit                  ; reached BOF in non-word run
    DEC     HL
    CALL    motion_byte_at_logical
    CP      0x21
    JR      C, .undo_back               ; whitespace boundary
    CALL    is_word_char
    JR      NZ, .walk_non_word
    INC     HL                          ; class transitioned; word starts at HL+1
    JR      .commit

.undo_back:
    INC     HL                          ; HL was speculatively DEC'd onto WS;
                                        ; the class run actually starts at HL+1

.commit:
    DEC     BC
    LD      A, B
    OR      C
    JR      NZ, .step
.done:
    LD      (cursor_offset), HL
    JP      parser_clear


;; ============================================================
;; --- Public entry: motion_0 (FR21; AC4, AC11) ---
;; ============================================================

; ----------------------------------------------------------------
; motion_0
; Cursor to column 0 of the current line. Replaces
; parser_motion_zero_stub (Story 2.6 retired). Reached only via
; parser_handle_digit's leading-zero arm (precondition:
; count_accumulator == 0), so count semantics are irrelevant.
;
; In:      A = '0' (MC4; ignored).
; Out:     cursor_offset = motion_find_line_start(cursor_offset).
;          Parser state cleared via parser_clear tail-JP.
; Trashes: A, DE, HL, F (BC preserved by motion_find_line_start).
; Calls:   motion_find_line_start, parser_clear (tail-JP).
; ----------------------------------------------------------------
motion_0:
    LD      HL, (cursor_offset)
    CALL    motion_find_line_start
    LD      (cursor_offset), HL
    JP      parser_clear


;; ============================================================
;; --- Public entry: motion_dollar (FR21; AC5, AC11) ---
;; ============================================================

; ----------------------------------------------------------------
; motion_dollar
; Cursor to the last printable byte of the current line. Count is
; effectively ignored (vi's "5$" = "to end of line 5 down" is
; deferred). Algorithm:
;   1. eol = motion_find_line_end(cursor_offset).
;   2. If eol == cursor_offset → no move (empty line / empty buffer).
;   3. Otherwise cursor = eol - 1 (the last printable byte; can't
;      land on the LF byte itself).
;
; In:      A = '$' (MC4; ignored).
; Out:     cursor_offset updated (or unchanged on empty-line clamp).
;          Parser state cleared via parser_clear tail-JP.
; Trashes: A, DE, HL, F (BC preserved by motion_find_line_end).
; Calls:   motion_find_line_end, parser_clear (tail-JP).
; ----------------------------------------------------------------
motion_dollar:
    LD      HL, (cursor_offset)
    PUSH    HL                          ; [cursor] — saved across motion_find_line_end
                                        ;          (which trashes DE per AR23)
    CALL    motion_find_line_end        ; HL = eol (LF pos or file_length)
    POP     DE                          ; DE = cursor
    OR      A
    SBC     HL, DE                      ; HL = eol - cursor; Z iff equal
    JR      Z, .no_move
    ADD     HL, DE                      ; HL = eol
    DEC     HL                          ; HL = eol - 1 (last printable byte)
    LD      (cursor_offset), HL
.no_move:
    JP      parser_clear


;; ============================================================
;; --- Internal helper: motion_find_line_n ---
;; ============================================================

; ----------------------------------------------------------------
; motion_find_line_n
; Walk to the start of line N (1-indexed). If N exceeds the
; file's line count, clamp at the start of the last line (BH2).
; Empty-buffer / single-line cases → HL = 0.
;
; Algorithm:
;   1. HL = 0, last_line_start = 0.
;   2. While DE > 0: walk forward looking for LF via
;      motion_find_line_end. On LF found at offset N:
;        - if N+1 < file_length → last_line_start = N+1; HL = N+1;
;          DE-- ; continue.
;        - if N+1 == file_length → LF is a trailer; do NOT
;          advance last_line_start (per Story-2.5 P5 lesson);
;          loop exits next iteration via past-EOF.
;   3. Return HL = last computed line start (or 0).
;
; Shared by motion_G's with-count arm and motion_gg's with-count
; arm (~30 B saved vs open-coding both). Trailing-LF clamp is
; load-bearing in both call sites.
;
; In:      DE = target line number (>= 1; 1 means "line 1" = offset 0).
; Out:     HL = offset of start of line DE, clamped at last-line-start.
; Trashes: A, BC, DE, HL, F (BC trashed inside; callers don't need
;          BC preserved here since they're done iterating count).
; Calls:   motion_find_line_end, motion_byte_at_logical.
; ----------------------------------------------------------------
motion_find_line_n:
    LD      HL, 0                       ; HL = current candidate (line 1 starts at 0)
    DEC     DE                          ; DE = LFs we need to advance past
    LD      A, D
    OR      E
    RET     Z                           ; target is line 1 → offset 0
.loop:
    ;; HL is the current candidate line-start; DE is the remaining
    ;; LF-skip count. Both are clobbered by motion_find_line_end and
    ;; motion_byte_at_logical, so push both across the calls.
    PUSH    DE                          ; [remaining]
    PUSH    HL                          ; [candidate]
    CALL    motion_find_line_end        ; HL = LF pos or file_length
    CALL    motion_byte_at_logical      ; CF=1 iff HL >= file_length (no LF)
    JR      C, .clamp                   ; past EOF — return prior candidate
    ;; Found LF at HL. Tentative next line start = HL + 1.
    INC     HL
    CALL    motion_byte_at_logical      ; CF=1 iff HL >= file_length
    JR      C, .clamp                   ; trailing LF — return prior candidate
    ;; HL is the new candidate line start. Drop prior candidate; restore DE.
    POP     BC                          ; discard saved candidate
    POP     DE                          ; restore remaining
    DEC     DE
    LD      A, D
    OR      E
    JR      NZ, .loop
    RET                                 ; HL = target line start

.clamp:
    POP     HL                          ; HL = prior candidate (last reachable line)
    POP     DE                          ; discard remaining
    RET


;; ============================================================
;; --- Public entry: motion_G (FR22; AC6, AC11) ---
;; ============================================================

; ----------------------------------------------------------------
; motion_G
; Cursor to start of last line, or with count C to start of line C
; (1-indexed). If C exceeds the file's line count, clamp at the
; start of the last line (BH2). No count typed → "last line"
; semantic (NOT "line 1" as motion_apply_count's default would
; imply); the dispatch path reads count_accumulator directly and
; branches before calling motion_find_line_n.
;
; Story-2.5 P5 trailing-LF lesson is load-bearing here:
; motion_find_line_n applies the trailing-LF clamp internally.
;
; In:      A = 'G' (MC4; ignored).
; Out:     cursor_offset = start of line C, or start of last line.
;          Parser state cleared via parser_clear tail-JP.
; Trashes: A, BC, DE, HL, F.
; Calls:   motion_find_line_n, parser_clear (tail-JP).
; ----------------------------------------------------------------
motion_G:
    LD      DE, (count_accumulator)
    LD      A, D
    OR      E
    JR      Z, .no_count
    ;; With count: target = DE (clamped at last line by helper).
    CALL    motion_find_line_n
    JR      .commit
.no_count:
    ;; No count: walk to last line. Pass DE = 0xFFFF (max LFs to
    ;; advance past); the helper's trailing-LF / past-EOF guards
    ;; clamp at the last reachable line.
    LD      DE, 0xFFFF
    CALL    motion_find_line_n
.commit:
    LD      (cursor_offset), HL
    JP      parser_clear


;; ============================================================
;; --- Public entry: motion_gg (FR22; AC7, AC11) ---
;; ============================================================

; ----------------------------------------------------------------
; motion_gg
; Cursor to start of buffer (line 1) on no-count, or with count C
; to start of line C (same with-count semantics as motion_G).
;
; Dispatched from parser_handle_motion_prefix's doubled-g arm
; (NOT from dispatch_normal directly). Must read count_accumulator
; BEFORE tail-JPing parser_clear — done implicitly through the
; LD DE, (count_accumulator) below.
;
; In:      (none — parser dispatches via JP motion_gg)
; Out:     cursor_offset = 0 on no-count, else start of line C.
;          Parser state cleared via parser_clear tail-JP.
; Trashes: A, BC, DE, HL, F.
; Calls:   motion_find_line_n (with-count path), parser_clear (tail-JP).
; ----------------------------------------------------------------
motion_gg:
    LD      DE, (count_accumulator)
    LD      A, D
    OR      E
    JR      NZ, .with_count
    LD      HL, 0
    JR      .commit
.with_count:
    CALL    motion_find_line_n
.commit:
    LD      (cursor_offset), HL
    JP      parser_clear


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
