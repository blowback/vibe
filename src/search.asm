; ============================================================
; Module: search.asm
; Purpose: Forward literal search (FR41). Owns the `/` prompt
;          entry from dispatch_normal, the commit-and-walk path
;          entered from exline_dispatch's SEARCH submode arm,
;          and the public search_forward_from helper that Story
;          3.2's `n` consumes verbatim. Pure-read against the
;          gap buffer via motions.asm's motion_byte_at_logical
;          (Q3 Path A pin — no gapbuf_byte_at_logical extraction);
;          writes only cursor_offset on a match and only
;          search_pattern on a non-empty commit. Status surfaces
;          enter via the AR12 status_set_message funnel.
;
;          Submode discipline: search_begin sets command_submode
;          = CMD_SUB_SEARCH; every successful return path tail-
;          JPs exline_cancel_core which clears the submode back
;          to CMD_SUB_EX. The bdos_error_funnel defensive clear
;          in statusln.asm covers the BDOS-during-search edge.
;
;          AR sweep (Story 3.1 pin):
;            AR13 — no BIOS_CONOUT call sites. status writes flow
;                   through status_set_message; cursor moves flow
;                   through cursor_offset + the next render_diff
;                   frame's render_scroll_adjust.
;            AR14 — no gap_start / gap_end WRITES. Reads only,
;                   via motion_byte_at_logical (HL = logical
;                   offset; preserves HL; trashes A, DE, F) and
;                   the inline search_compute_file_length helper.
;            AR15 — no BDOS_CALL invocations and no raw CALL
;                   0x0005 sites. Pure-memory module.
;
; Public:
;   search_begin              ; entry from dispatch_normal['/'] —
;                             ; flips mode_byte → MODE_COMMAND,
;                             ; command_submode → CMD_SUB_SEARCH,
;                             ; clears ex_buffer, recomposes the
;                             ; status row with the '/' prefix via
;                             ; exline_compose_status tail-JP
;                             ; (which branches on command_submode).
;   search_commit             ; entry from exline_dispatch when
;                             ; command_submode == CMD_SUB_SEARCH;
;                             ; commits the typed pattern (LDIR
;                             ; ex_buffer_text → search_pattern_text)
;                             ; or reuses the prior search_pattern
;                             ; on bare-Enter; surfaces
;                             ; msg_no_previous_pattern when both
;                             ; buffers are empty; otherwise runs
;                             ; the two-pass walk via search_run.
;   search_forward_from       ; PUBLIC helper. Walks logical bytes
;                             ; comparing pattern[0..plen) byte-
;                             ; for-byte; returns the first match
;                             ; start in HL (CF=0) or CF=1 on miss.
;                             ; Caller stages start_offset in HL
;                             ; and the (exclusive) upper bound in
;                             ; (search_upper_bound). Story 3.2's
;                             ; `n` reuses this directly.
;
; State owned (read/write):
;   search_pattern            ; length-prefixed (1B length + 64B
;                             ; payload). Writer: search_commit
;                             ; (on non-empty ex_buffer Enter —
;                             ; commit happens UNCONDITIONALLY,
;                             ; before the walk, per Q5 pin so
;                             ; failed `/notfound<Enter>` still
;                             ; overwrites; matches vi). Reader:
;                             ; search_forward_from's inner byte-
;                             ; compare loop + the AC4-reuse arm
;                             ; of search_commit.
;   command_submode           ; written via search_begin (=
;                             ; CMD_SUB_SEARCH); cleared by
;                             ; exline_cancel_core on every COMMAND
;                             ; → NORMAL return that this module
;                             ; tail-JPs.
;   cursor_offset             ; written on every match (first-pass
;                             ; or wrap-pass). Unchanged on
;                             ; pattern-not-found (vi convention).
;   mode_byte                 ; written by search_begin to
;                             ; MODE_COMMAND; cleared back to
;                             ; MODE_NORMAL via exline_cancel_core.
;   ex_buffer                 ; length cleared on search_begin
;                             ; (zero-length entry); LDIR'd FROM
;                             ; on commit; cleared again by
;                             ; exline_cancel_core on return.
;
; Module-local data:
;   search_upper_bound        ; 1 DEFW. Exclusive upper bound for
;                             ; the next search_forward_from call.
;                             ; Writers: search_run (sets file_length
;                             ; for the first pass and original
;                             ; cursor + 1 for the wrap pass).
;                             ; Reader: search_forward_from. Not in
;                             ; state.inc — caller-staged contract,
;                             ; not cross-module shared state.
;
; Register conventions (across public entry points):
;   search_begin:        In:  A = '/' (MC4 — ignored).
;                        Out: mode_byte = MODE_COMMAND;
;                             command_submode = CMD_SUB_SEARCH;
;                             ex_buffer length = 0; status row
;                             composed as '/' via the AR12 funnel;
;                             status_dirty set.
;                        Trashes: A, BC, DE, HL, F.
;                        Calls: exline_compose_status (tail-JP).
;                        Note: DE NOT preserved across any tail-JP
;                             that hits motion_byte_at_logical (this
;                             entry does not call it, but flagged
;                             here for parity with the rest of the
;                             module per Epic-2 retro carry-forward).
;
;   search_commit:       In:  A = 0x0D (MC4 — ignored; state comes
;                             from ex_buffer + search_pattern).
;                        Out: ex_buffer[0] > 0: commit (LDIR
;                             ex_buffer_text → search_pattern_text;
;                             search_pattern[0] := ex_buffer[0])
;                             then walk. ex_buffer[0] == 0: reuse
;                             prior search_pattern if non-empty;
;                             else msg_no_previous_pattern banner
;                             + tail-JP exline_cancel_core. Walk
;                             path runs search_run.
;                        Trashes: A, BC, DE, HL, F.
;                        Calls: search_run, status_set_message,
;                             exline_cancel_core (tail-JP).
;                        Note: DE NOT preserved across the LDIR
;                             commit OR across motion_byte_at_logical
;                             reached via search_run; ABI is
;                             trash-everything per MC1.
;
;   search_forward_from: In:  HL = start_offset (logical, 16-bit
;                             unsigned).
;                             (search_upper_bound) = exclusive
;                             upper bound for match-start positions
;                             (logical, 16-bit unsigned).
;                             search_pattern populated (length-
;                             prefixed; length > 0 required —
;                             caller's responsibility; the defensive
;                             length==0 guard returns CF=1 immediately).
;                        Out: CF = 0, HL = match_start on hit.
;                             CF = 1 on miss (HL undefined).
;                        Trashes: A, BC, DE, HL, F.
;                        Calls: motion_byte_at_logical (inner
;                             byte-fetch; preserves HL; trashes
;                             A, DE, F; signals past-EOF via CF=1).
;                        Note: DE NOT preserved across the inner
;                             byte-fetch loop — pattern pointer is
;                             saved on the stack across every
;                             motion_byte_at_logical call. The pos
;                             counter walks in HL (preserved by the
;                             helper). BC is preserved by
;                             motion_byte_at_logical so B = pattern
;                             length serves as the inner DJNZ
;                             counter directly.
;
; Dependencies:
;   inc/equates.inc       (MODE_COMMAND via inc/modes.inc transitively;
;                          CMD_SUB_SEARCH; GAP_BUFFER_MAX)
;   inc/modes.inc         (MODE_COMMAND)
;   inc/state.inc         (mode_byte, command_submode, cursor_offset,
;                          ex_buffer, ex_buffer_text, search_pattern,
;                          search_pattern_text, gap_start, gap_end)
;   src/motions.asm       (motion_byte_at_logical — Q3 Path A; same-
;                          module-private symbol resolved via AR25
;                          INCLUDE ordering: motions.asm precedes
;                          search.asm in vibe.asm's chain so the
;                          forward-reference is irrelevant here, but
;                          the symbol IS visible to sjasmplus's flat
;                          namespace.)
;   src/statusln.asm      (status_set_message;
;                          msg_no_previous_pattern (new this story),
;                          msg_pattern_not_found, msg_search_wrapped,
;                          msg_mode_normal (the empty-banner string,
;                          used to CLEAR the status row on a
;                          first-pass match per AC3))
;   src/exline.asm        (exline_compose_status — tail-JP target
;                          from search_begin; exline_cancel_core —
;                          tail-JP target from every search_commit
;                          terminus and from search_run's match /
;                          no-match arms)
; ============================================================

;; ============================================================
;; --- Public entry: search_begin ('/' from dispatch_normal) ---
;; ============================================================

; ----------------------------------------------------------------
; search_begin
; Entered from dispatch_normal['/']. Flips into COMMAND mode +
; SEARCH submode, empties ex_buffer (the shared edit surface per
; Q2), and composes the '/' prompt into the status row via the
; AR12 funnel.
;
; AC1 — `/` enters the search prompt (COMMAND mode + SEARCH submode).
; AC2 — The `command_submode` set here drives exline_compose_status's
;       prefix branch and exline_dispatch's Enter routing.
;
; search_pattern is NOT zeroed here — it persists across sessions
; and is consumed by AC4's `/<Enter>` reuse path.
;
; In:      A = '/' (MC4 — ignored).
; Out:     mode_byte = MODE_COMMAND; command_submode = CMD_SUB_SEARCH;
;          ex_buffer length = 0; status row composed as '/'
;          (exline_compose_status reads command_submode to pick the
;          prefix); status_dirty set by status_set_message.
; Trashes: A, BC, DE, HL, F.
; Calls:   exline_compose_status (tail-JP).
; ----------------------------------------------------------------
search_begin:
    LD      A, MODE_COMMAND
    LD      (mode_byte), A
    LD      A, CMD_SUB_SEARCH
    LD      (command_submode), A
    XOR     A
    LD      (ex_buffer), A              ; ex_buffer length = 0
    JP      exline_compose_status       ; tail-JP — picks '/' prefix per submode


;; ============================================================
;; --- Public entry: search_commit (from exline_dispatch) ---
;; ============================================================

; ----------------------------------------------------------------
; search_commit
; Entered via JP from exline_dispatch's command_submode ==
; CMD_SUB_SEARCH arm (Task 3.3 in Story 3.1). Implements AC3 /
; AC4 / AC5 sequence:
;
;   - Non-empty ex_buffer (AC3): LDIR ex_buffer_text →
;     search_pattern_text with BC = ex_buffer[0]; set
;     search_pattern[0] := ex_buffer[0] (commits the new pattern;
;     replaces any prior — happens BEFORE the walk per Q5 pin,
;     so `/notfound<Enter>` still overwrites). Fall through to
;     search_run.
;
;   - Empty ex_buffer (AC4): if search_pattern[0] > 0, reuse the
;     prior commit by falling through to search_run; else surface
;     msg_no_previous_pattern + JP exline_cancel_core.
;
; In:      A = 0x0D (MC4 — ignored; state comes from ex_buffer +
;          search_pattern).
; Out:     Commit path: search_pattern updated; cursor moves on
;          match; status row reflects result (clear / wrapped /
;          not-found); mode → NORMAL via exline_cancel_core.
;          Reuse path: same as commit minus the LDIR/length write.
;          No-prior-pattern path: msg_no_previous_pattern banner;
;          cursor unchanged; mode → NORMAL.
; Trashes: A, BC, DE, HL, F.
; Calls:   search_run (fall-through), status_set_message,
;          exline_cancel_core (tail-JP).
; ----------------------------------------------------------------
search_commit:
    LD      A, (ex_buffer)
    OR      A
    JR      Z, .check_prior             ; bare-Enter: reuse path

    ;; --- Non-empty ex_buffer: commit (Q5 — unconditional) ------
    ;; A holds the new length. Write length first, then LDIR the
    ;; text payload. (Order doesn't matter for correctness — both
    ;; cells are module-private — but write-length-first matches
    ;; exline_append_literal's idiom.)
    LD      (search_pattern), A         ; search_pattern[0] = new length
    LD      C, A
    LD      B, 0                        ; BC = new length
    LD      HL, ex_buffer_text
    LD      DE, search_pattern_text
    LDIR
    JR      search_run                  ; fall through to walk

.check_prior:
    ;; --- AC4: bare-Enter; reuse prior search_pattern if any ---
    LD      A, (search_pattern)
    OR      A
    JR      NZ, search_run              ; have prior pattern; reuse

    ;; --- No prior pattern; surface msg_no_previous_pattern ---
    LD      HL, msg_no_previous_pattern
    XOR     A
    CALL    status_set_message
    JP      exline_cancel_core


;; ============================================================
;; --- Internal: search_run (the two-pass walk + status) ---
;; ============================================================

; ----------------------------------------------------------------
; search_run
; AC3 + AC4 + AC5 walk orchestration. Called from search_commit
; after search_pattern is known populated (length > 0).
;
; Pass 1: search_forward_from(cursor + 1, file_length).
; Pass 2 (wrap, AC5): search_forward_from(0, original_cursor + 1).
; The wrap upper-bound = original_cursor + 1 is the Q4 pin —
; two-pass union covers `[0, file_length) \ {trivial-no-advance}`.
;
; Status outcomes:
;   - First-pass match: cursor moves; status row CLEARED
;     (msg_mode_normal — the empty-banner string; status_set_message
;     pads with spaces). vi convention: no "found" message.
;   - Wrap-pass match: cursor moves; status row = msg_search_wrapped.
;   - Both passes miss: cursor UNCHANGED (vi convention); status =
;     msg_pattern_not_found.
;
; Every exit tail-JPs exline_cancel_core, which clears ex_buffer
; and command_submode and flips mode_byte back to MODE_NORMAL
; without clobbering the status banner just set.
;
; In:      (none — reads cursor_offset, search_pattern, gap state)
; Out:     cursor_offset possibly updated; status row composed;
;          mode_byte = MODE_NORMAL; ex_buffer cleared;
;          command_submode = CMD_SUB_EX.
; Trashes: A, BC, DE, HL, F.
; Calls:   search_compute_file_length, search_forward_from,
;          status_set_message, exline_cancel_core (tail-JP).
; ----------------------------------------------------------------
search_run:
    ;; --- Compute start_1 = cursor_offset + 1 ---
    LD      HL, (cursor_offset)
    INC     HL                          ; HL = start_1

    ;; --- First pass: upper_bound = file_length, start = start_1 ---
    PUSH    HL                          ; [start_1] (used as wrap bound on miss)
    CALL    search_compute_file_length  ; HL = file_length
    LD      (search_upper_bound), HL    ; bound for pass 1
    POP     HL                          ; HL = start_1; ()
    PUSH    HL                          ; [start_1] (re-saved for wrap path)
    CALL    search_forward_from
    JR      NC, .first_pass_match       ; CF=0 -> hit

    ;; --- First pass miss; wrap path ---
    POP     HL                          ; HL = start_1 = original_cursor + 1
    LD      (search_upper_bound), HL    ; Q4 pin: wrap bound = original_cursor + 1
    LD      HL, 0                       ; start at BOF
    CALL    search_forward_from
    JR      NC, .wrap_match             ; CF=0 -> hit

    ;; --- Both passes missed; pattern not found, cursor unchanged ---
    LD      HL, msg_pattern_not_found
    XOR     A
    CALL    status_set_message
    JP      exline_cancel_core

.first_pass_match:
    ;; HL = match_start. Stack still holds the saved start_1; drop it.
    LD      (cursor_offset), HL
    POP     DE                          ; discard saved start_1; ()
    LD      HL, msg_mode_normal         ; clear status (vi convention)
    XOR     A
    CALL    status_set_message
    JP      exline_cancel_core

.wrap_match:
    ;; HL = match_start. Stack already balanced (start_1 was POPped
    ;; before the wrap CALL).
    LD      (cursor_offset), HL
    LD      HL, msg_search_wrapped
    XOR     A
    CALL    status_set_message
    JP      exline_cancel_core


;; ============================================================
;; --- Public: search_forward_from (Story 3.2 hand-off) ---
;; ============================================================

; ----------------------------------------------------------------
; search_forward_from
; Naive O(N x M) forward walk: for each candidate position
; pos in [start_offset, search_upper_bound), byte-compare
; search_pattern_text[0..plen) against buffer[pos..pos+plen).
; Returns the first match start, or CF=1 if none.
;
; The walk's "match start position must satisfy pos < upper_bound"
; semantics (NOT pos+plen <= upper_bound) is load-bearing for the
; wrap path's Q4 pin: with upper_bound = original_cursor + 1, a
; pattern starting at original_cursor is reachable and surfaces
; as "search wrapped" (AC5 — user sitting on a match position).
; Pattern bytes that extend past upper_bound are still read; the
; motion_byte_at_logical CF=1 guard short-circuits past file_length.
;
; In:      HL = start_offset (logical, 16-bit unsigned)
;          (search_upper_bound) = exclusive upper bound (16-bit
;                                 unsigned) for match-start
;                                 positions.
;          search_pattern[0] = pattern length (caller's invariant:
;                              > 0; defensive guard returns CF=1
;                              on 0 to avoid an infinite no-op
;                              loop).
; Out:     CF = 0, HL = match_start on hit.
;          CF = 1 on miss (HL undefined).
; Trashes: A, BC, DE, HL, F.
; Calls:   motion_byte_at_logical.
; ----------------------------------------------------------------
search_forward_from:
    ;; --- Defensive: zero-length pattern -> nothing to match. ---
    LD      A, (search_pattern)
    OR      A
    JR      Z, .not_found

.outer_loop:
    ;; --- Bounds: stop iff pos >= upper_bound ---
    PUSH    HL                          ; [pos] (preserve across SBC)
    LD      DE, (search_upper_bound)
    OR      A
    SBC     HL, DE                      ; CF=1 iff HL < DE
    POP     HL                          ; HL = pos
    JR      NC, .not_found              ; pos >= upper_bound: done

    ;; --- Inner byte-compare loop ---
    PUSH    HL                          ; [pos] — restored on miss / return
    LD      A, (search_pattern)
    LD      B, A                        ; B = pattern length (DJNZ counter)
    LD      DE, search_pattern_text     ; DE = pattern ptr
.inner_loop:
    PUSH    DE                          ; save pattern ptr (motion trashes DE)
    CALL    motion_byte_at_logical      ; A = buffer[HL]; HL preserved; CF=1 past EOF
    POP     DE
    JR      C, .pos_mismatch            ; past EOF for this pos -> next
    LD      C, A                        ; C = buffer byte (B = counter; BC preserved by motion)
    LD      A, (DE)                     ; A = pattern byte
    CP      C
    JR      NZ, .pos_mismatch
    INC     DE
    INC     HL
    DJNZ    .inner_loop

    ;; --- All pattern bytes matched; pos is on the stack. ---
    POP     HL                          ; HL = match_start
    OR      A                           ; clear CF (hit)
    RET

.pos_mismatch:
    POP     HL                          ; restore pos
    INC     HL                          ; advance to next candidate
    JR      .outer_loop

.not_found:
    SCF
    RET


;; ============================================================
;; --- Internal helper: search_compute_file_length ---
;; ============================================================

; ----------------------------------------------------------------
; search_compute_file_length
; SR3-derived file_length = gap_start + GAP_BUFFER_MAX - gap_end.
; Same arithmetic motions.asm inlines inside motion_byte_at_logical;
; here as a local helper so search_run reads file_length once per
; invocation rather than implicitly via the helper's EOF guard.
;
; In:      (none)
; Out:     HL = file_length
; Trashes: A, DE, F. (HL is the output; BC preserved.)
; Calls:   (none)
; ----------------------------------------------------------------
search_compute_file_length:
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_MAX
    ADD     HL, DE                      ; HL = gap_start + GAP_BUFFER_MAX
    LD      DE, (gap_end)
    OR      A
    SBC     HL, DE                      ; HL = file_length
    RET


;; ============================================================
;; --- Data: search_upper_bound ---
;; ============================================================
; Module-local 16-bit cell holding the exclusive upper bound for
; the next search_forward_from candidate-position walk. Writers:
; search_run (sets file_length pre-pass-1; original_cursor + 1
; pre-pass-2). Reader: search_forward_from's outer-loop bounds
; check. Lives in the code segment per render.asm / exline.asm
; precedent for module-local scratch (NOT declared in state.inc).

search_upper_bound:
    DEFW    0
