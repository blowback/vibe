; ============================================================
; Module: edits.asm
; Purpose: Buffer-edit primitives (FR24-FR29 + FR31 + FR39 + FR40).
;          Lands the a / o / O entry handlers and the INSERT-mode
;          literal-insert / Backspace / Enter handlers in Story 2.8 —
;          VIBE's first true edit-and-save round-trip surface.
;          Story 2.9 adds edits_delete_char (FR28) — the first
;          NORMAL-mode mutating operator and the foundation for
;          Stories 2.10-2.11's doubled-operator (dd/yy) and
;          operator+motion (dw/d$/c5w) work. Story 2.10 adds
;          op_dd (FR29) + op_yy (FR31) — the first line-granularity
;          edit operations and the FIRST writers of the SR6 yank
;          register (yank_kind / yank_length / yank_buffer).
;          Story 2.11 lands the FR39 + FR40 operator+motion compose
;          layer: any operator (d/y/c/>/<) composed with any motion
;          (h/l/j/k/w/b/0/$/gg/G), counted variants, and the
;          doubled-operator line forms `>>` / `<<`. Compose mechanism:
;          a per-motion entry prologue saves the cursor into
;          motions_compose_entry; every motion's tail JP routes to
;          edits_compose_or_clear which examines pending_operator
;          and dispatches to one of 5 per-operator bodies (or falls
;          through to parser_clear for bare motion). Range derivation
;          via edits_compose_range; vi-faithful `d$` / `c$` /
;          `y$` inclusive-landing via pending_motion_inclusive
;          (set by motion_dollar). FIRST writer of KIND_CHAR
;          (op_compose_d / op_compose_y / op_compose_c yank-copy).
;          FR13 (`i` enters INSERT) stays wired to enter_insert_mode
;          in dispatch.asm; FR16 (Esc-to-NORMAL) stays on
;          enter_normal_mode in dispatch.asm — neither lives here.
;          Sits between motions.asm and exline.asm in the AR25
;          INCLUDE chain (the long-planned slot per
;          src/vibe.asm:140 comment + architecture.md:945).
;
;          edits.asm is the "near-clean module" archetype: AR13
;          (no screen emission), AR14 (no direct buffer mutation
;          — all writes route through gapbuf_insert / gapbuf_delete),
;          AR15 (no raw BDOS) all met cleanly. No carve-outs.
;          Compare motions.asm's three-clean-boundary archetype
;          (zero writes anywhere); edits.asm WRITES the buffer,
;          but only through the AR14-compliant gapbuf primitives.
;
;          B2 undo recording is a STUB for Story 2.8 (no entry
;          written to undo_buffer; `u` post-INSERT-Esc reports
;          msg_nothing_to_undo). Full session-recording lands in
;          Story 2.13 — the documented hook site is
;          enter_normal_mode's Esc-from-INSERT exit point in
;          src/dispatch.asm.
;
;          FR45 undo recording for edits_delete_char is also a
;          STUB for Story 2.9 — no inverse-op entry written.
;          Story 2.13's hook site is at edits_delete_char's
;          `.commit:` label — AFTER the SBC HL,BC == 0 deltas-
;          done check (so the no-op path doesn't spuriously
;          emit an empty undo entry) and BEFORE the CALL
;          edits_dirty_and_redraw.
;
;          FR45 undo recording for op_dd is ALSO a STUB for
;          Story 2.10. Story 2.13's hook site is INSIDE op_dd,
;          BEFORE the CALL edits_copy_to_yank — the gap-buffer
;          bytes are still at their pre-delete logical positions,
;          and undo recording is independent of yank capacity
;          (so a yank-too-large refusal does NOT also block
;          undo). op_yy NEVER records undo (read-only op;
;          nothing to undo).
;
;          FR45 undo recording for the Story 2.11 compose layer is
;          STUBBED in the same shape:
;            - op_compose_d / op_compose_c: hook site = BEFORE the
;              yank-copy (gap-buffer bytes still at pre-delete
;              logical positions).
;            - op_compose_indent / op_compose_dedent /
;              op_indent_line / op_dedent_line: hook site = BEFORE
;              the first per-line insert/delete (the line-walk's
;              first call).
;            - op_compose_y: NEVER records undo (yank-only).
;
; Public:
;   edits_enter_insert_after  ; 'a' — advance cursor 0/1 per EOL rule, enter INSERT
;   edits_open_below          ; 'o' — reach EOL, insert LF, enter INSERT on new line below
;   edits_open_above          ; 'O' — reach BOL, insert LF, DEC cursor, enter INSERT on new line above
;   edits_insert_literal      ; INSERT-mode literal-byte insert (replaces 1.9 unbound_insert stub)
;   edits_insert_backspace    ; INSERT-mode Backspace (delete byte before cursor; silent at BOF)
;   edits_insert_newline      ; INSERT-mode Enter — translates 0x0D → 0x0A (AC10 explicit bind)
;   edits_delete_char         ; NORMAL-mode `x` — delete byte under cursor (Story 2.9; FR28; counted with BH2 clamp)
;   op_dd                     ; NORMAL-mode `dd` / `Ndd` — delete current line(s); yank-register write (Story 2.10; FR29)
;   op_yy                     ; NORMAL-mode `yy` / `Nyy` — yank current line(s); read-only (Story 2.10; FR31)
;   edits_compose_or_clear    ; Story 2.11 shared compose tail — JP target of every motion's exit (routes by pending_operator)
;   op_compose_d              ; Story 2.11 — d + motion (dw/d$/db/d3j/dgg/dG) (FR39, FR40)
;   op_compose_y              ; Story 2.11 — y + motion (yw/y$/y3j) — read-only (FR39, FR40)
;   op_compose_c              ; Story 2.11 — c + motion (cw/c$/c5w) → tail-JP enter_insert_mode (FR39, FR40)
;   op_compose_indent         ; Story 2.11 — > + motion — line-promoted (FR39, FR40)
;   op_compose_dedent         ; Story 2.11 — < + motion — line-promoted (FR39, FR40)
;   op_indent_line            ; Story 2.11 — >> / N>> — doubled-form line indent (FR40)
;   op_dedent_line            ; Story 2.11 — << / N<< — doubled-form line dedent (FR40)
;   ; Internal helpers (also documented per AR23 at each contract block):
;   ; edits_line_range_for_count, edits_copy_to_yank, edits_range_delete,
;   ; edits_compose_range (Story 2.11), edits_indent_walk (Story 2.11)
;
; State owned (read/write):
;   cursor_offset   ; the o / O / a handlers re-position the cursor;
;                     gapbuf_insert / gapbuf_delete advance/retreat
;                     it transitively. edits_delete_char uses the
;                     cursor-bounce shape (INC cursor; gapbuf_delete
;                     dec's back) so the cursor returns to its
;                     starting offset on each iter — except when the
;                     post-loop AC1/AC2 clamp dec's it onto the new
;                     last-printable byte. op_dd uses edits_range_delete's
;                     N-iter cursor-bounce (pre-stage cursor at
;                     delete_end; gapbuf_delete dec's total_bytes
;                     times → final cursor = delete_start) plus the
;                     AC2 three-way post-delete placement
;                     (delete_start / start-of-new-last-line / 0).
;                     mode_byte is written via enter_insert_mode on
;                     success paths and via direct MODE_NORMAL write
;                     on the literal-insert overflow exit. buffer_dirty
;                     is set on every successful mutation path
;                     (including op_dd's success path; op_yy NEVER
;                     writes buffer_dirty). yank_kind / yank_length /
;                     yank_buffer are written by op_dd's and op_yy's
;                     success paths only — UNCHANGED on the over-
;                     capacity refusal path per SR6 "predictable
;                     failure mode".
;                     Story 2.11: op_compose_d / op_compose_y /
;                     op_compose_c success paths also write
;                     yank_kind=KIND_CHAR / yank_length / yank_buffer;
;                     UNCHANGED on capacity-refusal (same shape as
;                     op_dd / op_yy). op_compose_d / op_compose_c /
;                     op_compose_indent / op_compose_dedent /
;                     op_indent_line / op_dedent_line each write
;                     buffer_dirty=1 on success (via the shared
;                     edits_dirty_and_redraw funnel); op_compose_y +
;                     op_compose_indent/dedent's no-op path leave it
;                     UNCHANGED. cursor_offset written by all
;                     op_compose_* (range_start for d/c after the
;                     range-delete; restored to motions_compose_entry
;                     for y / indent / dedent). mode_byte written by
;                     op_compose_c transitively via enter_insert_mode.
;                     pending_motion_inclusive read by all five
;                     per-operator bodies; cleared centrally by
;                     parser_clear.
;
; State read-only:
;   gap_start, gap_end             ; SR2 / SR3 read by motion_byte_at_logical
;                                    (transitive via the helper) — never
;                                    written here.
;
; Register conventions (across public entry points):
;   edits_enter_insert_after:
;                  In:  A = 'a' (MC4; ignored). cursor_offset read.
;                  Out: cursor_offset advanced 0 or 1 per AC2 rule;
;                       mode_byte = MODE_INSERT; status indicator;
;                       parser state zeroed (via enter_insert_mode
;                       tail-JP to parser_clear).
;                  Trashes: A, BC, DE, HL, F.
;                  Calls: motion_byte_at_logical (EOL/EOF inspect);
;                         enter_insert_mode (tail-JP — handles
;                         mode + status + parser_clear).
;
;   edits_open_below:
;                  In:  A = 'o' (MC4; ignored). cursor_offset read.
;                  Out: success — cursor positioned at start of new
;                       (empty) line below; mode = MODE_INSERT;
;                       buffer_dirty = 1; all dirty rows marked.
;                       overflow (gapbuf full) — cursor restored to
;                       entry position; mode stays NORMAL;
;                       msg_file_too_large surfaced (via gapbuf_insert);
;                       parser state zeroed.
;                  Trashes: A, BC, DE, HL, F.
;                  Calls: motion_find_line_end (reach EOL);
;                         gapbuf_insert (LF);
;                         render_mark_all_dirty (success);
;                         enter_insert_mode (success tail-JP);
;                         parser_clear (overflow tail-JP).
;
;   edits_open_above:
;                  In:  A = 'O' (MC4; ignored). cursor_offset read.
;                  Out: success — cursor positioned ON the just-
;                       inserted LF (= new empty line above original);
;                       mode = MODE_INSERT; buffer_dirty = 1; all
;                       dirty rows marked. overflow — same shape as
;                       edits_open_below.
;                  Trashes: A, BC, DE, HL, F.
;                  Calls: motion_find_line_start (reach BOL);
;                         gapbuf_insert (LF);
;                         render_mark_all_dirty (success);
;                         enter_insert_mode (success tail-JP);
;                         parser_clear (overflow tail-JP).
;
;   edits_insert_literal:
;                  In:  A = byte to insert (MC4). cursor_offset read.
;                  Out: success — byte inserted at cursor; cursor
;                       advanced; buffer_dirty = 1; cursor's row +
;                       all rows marked dirty (conservative shape).
;                       overflow — mode_byte := MODE_NORMAL (INSERT
;                       session exits); cursor unchanged; partial
;                       text BEFORE the failing byte preserved;
;                       msg_file_too_large surfaced; parser state
;                       zeroed.
;                       control-byte (A < 0x20) — silent no-op.
;                  Trashes: A, BC, DE, HL, F.
;                  Calls: gapbuf_insert; render_mark_all_dirty (success
;                         tail-JP); parser_clear (overflow tail-JP).
;
;   edits_insert_backspace:
;                  In:  A = 0x08 (MC4; ignored). cursor_offset read.
;                  Out: success — byte before cursor deleted;
;                       cursor decremented; buffer_dirty = 1;
;                       all rows marked dirty (conservative —
;                       a deleted LF shifts every row below up).
;                       BOF (cursor == 0) — silent no-op; buffer +
;                       cursor + buffer_dirty all unchanged.
;                  Trashes: A, BC, DE, HL, F.
;                  Calls: gapbuf_delete; render_mark_all_dirty (success
;                         tail-JP).
;
;   edits_insert_newline:
;                  In:  A = 0x0D (MC4; ignored). cursor_offset read.
;                  Out: success — 0x0A inserted at cursor (Enter →
;                       LF translation); cursor advanced; buffer_dirty
;                       = 1; all rows marked dirty (LF shifts rows
;                       below). overflow — mode = NORMAL (INSERT
;                       session exits via the same shape as
;                       edits_insert_literal's overflow path).
;                  Trashes: A, BC, DE, HL, F.
;                  Calls: gapbuf_insert; render_mark_all_dirty (success
;                         tail-JP); parser_clear (overflow tail-JP).
;
;   edits_delete_char:
;                  In:  A = 'x' (MC4; ignored). cursor_offset read;
;                       count_accumulator read via motion_apply_count.
;                  Out: success — up to N bytes deleted starting at
;                       cursor (N = effective count, default 1), with
;                       BH2 clamp at LF / EOF (loop BREAKs mid-count
;                       if the cursor would step onto a non-printable
;                       boundary). Cursor stays at the original offset
;                       unless the post-delete byte at that offset is
;                       LF or past EOF AND cursor > 0 — in which case
;                       cursor decrements by 1 (AC1 EOL-clamp;
;                       AC2 EOF-clamp). buffer_dirty = 1; all rows
;                       dirty (LF positions may shift across the
;                       deletion).
;                       no-op — cursor on LF / past EOF at entry, OR
;                       counted form where the first iter-top check
;                       fires immediately. buffer + cursor +
;                       buffer_dirty all unchanged.
;                       Parser state zeroed on every path
;                       (tail-JP parser_clear).
;                  Trashes: A, BC, DE, HL, F.
;                  Calls: motion_apply_count; motion_byte_at_logical
;                         (pre-check + iter-top + post-clamp);
;                         gapbuf_delete (cursor-bounce shape per AC8 —
;                         INC cursor; gapbuf_delete consumes byte at
;                         original cursor and decrements cursor back);
;                         edits_dirty_and_redraw (success tail);
;                         parser_clear (tail-JP both paths).
;
; Architectural enforcement here:
;   AR13 — no screen emission. edits.asm contains zero BIOS_CONOUT
;          references; the post-edit cursor reposition and row
;          re-render are driven by render.asm's RI4 invariant on
;          the next render_diff frame (cursor_offset + dirty_rows
;          are the only surfaces edits touches).
;   AR14 — no direct buffer mutation. edits.asm WRITES the buffer
;          but only through gapbuf_insert / gapbuf_delete, the
;          AR14-compliant mutation surface. No `LD (gap_start), DE`
;          or `LD (gap_end), DE` sites. The motion_byte_at_logical
;          helper called from edits_enter_insert_after is a READ
;          primitive and lives within AR14's "reads OK" envelope.
;   AR15 — no BDOS. edits.asm contains zero BDOS_CALL macro
;          invocations and zero raw CALL 0x0005 / CALL BDOS_ENTRY
;          sites. Pure-memory module.
;   AR12 — status messages via funnel. edits.asm never writes
;          status bytes directly. msg_file_too_large surfaces via
;          gapbuf_insert's internal status_set_message call on
;          overflow; msg_mode_insert / msg_mode_normal surface via
;          enter_insert_mode / enter_normal_mode transitively;
;          msg_yank_too_large (Story 2.10) surfaces via the
;          status_set_message funnel from op_dd's yank-refused arm
;          and op_yy's yank-refused arm.
;          Story 2.11: op_compose_d / op_compose_y / op_compose_c
;          surface msg_yank_too_large via the same funnel on capacity
;          refusal. No new status strings introduced.
;
; Dependencies:
;   inc/state.inc    (cursor_offset, mode_byte, buffer_dirty —
;                     all written here; gap_start / gap_end —
;                     read transitively via motion_byte_at_logical;
;                     pending_motion_inclusive — Story 2.11; read by
;                     all five op_compose_* bodies; cleared by
;                     parser_clear)
;   inc/equates.inc  (INDENT_BYTE — Story 2.11 first reader; KIND_CHAR /
;                     KIND_LINE — yank-kind discriminators; YANK_BUFFER_SIZE
;                     — over-capacity threshold)
;   inc/modes.inc    (MODE_NORMAL — written on edits_insert_literal /
;                     edits_insert_newline overflow exit)
;   src/gapbuf.asm   (gapbuf_insert, gapbuf_delete — the AR14
;                     mutation surface)
;   src/motions.asm  (motion_byte_at_logical, motion_find_line_start,
;                     motion_find_line_end — read primitives for
;                     EOL / EOF inspect and line-start / line-end
;                     positioning. All preserve BC. Story 2.9 adds
;                     a transitive dependency on motion_apply_count —
;                     edits_delete_char reads count_accumulator
;                     through it, defaulting to 1, and iterates a
;                     count loop where BC's BC-preservation across
;                     motion_byte_at_logical matters. The
;                     gapbuf_delete inside the loop trashes BC, so
;                     the loop saves it via PUSH/POP across each
;                     call. Story 2.10 extends the dependency:
;                     edits_line_range_for_count walks N line-ends
;                     via motion_find_line_end, edits_copy_to_yank
;                     reads source bytes via motion_byte_at_logical,
;                     op_dd's post-delete cursor placement re-probes
;                     via motion_byte_at_logical and walks back to
;                     motion_find_line_start for case 3 (delete-to-
;                     EOF with content above).)
;   src/statusln.asm (status_set_message + msg_yank_too_large —
;                     surfaced by op_dd / op_yy on yank-register
;                     over-capacity refusal per SR6.)
;   src/render.asm   (render_mark_all_dirty — conservative dirty-row
;                     mark on every successful mutation; the
;                     fine-grained render_mark_row_dirty variant is
;                     a Growth-tier optimisation deferred to a
;                     future story per deferred-work.md)
;   src/dispatch.asm (enter_insert_mode — tail-JP target for o / O / a
;                     success paths; handles mode + status + parser_clear.
;                     edits.asm is INCLUDEd AFTER motions.asm and
;                     BEFORE exline.asm in vibe.asm's AR25 chain;
;                     dispatch.asm is INCLUDEd earlier so the
;                     forward-references resolve via sjasmplus's
;                     two-pass model.)
;   src/parser.asm   (parser_clear — tail-JP target on overflow paths)
; ============================================================

;; ============================================================
;; --- Public entry: edits_enter_insert_after (FR25; AC2) ---
;; ============================================================

; ----------------------------------------------------------------
; edits_enter_insert_after
; Implements `a` — advance cursor by 0 or 1 per the AC2 EOL rule,
; then enter INSERT mode. Cursor stays put if:
;   - cursor_offset >= file_length (motion_byte_at_logical returns
;     CF=1; past-EOF cursor, no byte to "skip past"); OR
;   - the byte at cursor is 0x0A (defensive — Story 2.5's invariant
;     says cursor shouldn't be there, but `a` must never advance
;     past the EOL marker into the next line).
; Otherwise cursor advances by 1.
;
; The mode + status + parser_clear work is done by enter_insert_mode
; via tail-JP — saves ~9 B vs duplicating the body.
;
; In:      A = 'a' (MC4; ignored).
; Out:     cursor_offset advanced 0 or 1; mode = INSERT; status
;          shows "-- insert --"; parser state zeroed.
; Trashes: A, BC, DE, HL, F.
; Calls:   motion_byte_at_logical, enter_insert_mode (tail-JP).
; ----------------------------------------------------------------
edits_enter_insert_after:
    LD      HL, (cursor_offset)
    CALL    motion_byte_at_logical      ; A = byte at cursor; CF=1 past EOF; HL preserved
    JR      C, .skip                    ; past EOF — no advance
    CP      0x0A
    JR      Z, .skip                    ; cursor on LF — no advance
    INC     HL
    LD      (cursor_offset), HL
.skip:
    JP      enter_insert_mode


;; ============================================================
;; --- Public entry: edits_open_below (FR26; AC3) ---
;; ============================================================

; ----------------------------------------------------------------
; edits_open_below
; Implements `o` — open a new line below the current line.
;   1. Save entry cursor on stack (rollback target for the overflow
;      path).
;   2. Move cursor to end-of-line (motion_find_line_end — LF
;      position or file_length if no LF before EOF).
;   3. Insert 0x0A at the new cursor position. gapbuf_insert
;      advances cursor by 1 on success — landing it at the start
;      of the new (empty) line below the original.
;   4. On success: set buffer_dirty = 1; mark all rows dirty (LF
;      shifted every row below); tail-JP enter_insert_mode for the
;      mode + status + parser_clear work.
;   5. On gapbuf_insert overflow (CF=1; buffer at GAP_BUFFER_MAX):
;      restore entry cursor (FR52 "no silent data loss" — the user
;      pressed `o` expecting a new line; if it couldn't happen,
;      cursor goes back where it was so the user knows nothing
;      changed); leave mode at NORMAL; let gapbuf_insert's pre-
;      existing msg_file_too_large surface the failure; tail-JP
;      parser_clear so any pending count / operator doesn't bleed.
;
; In:      A = 'o' (MC4; ignored).
; Out:     success — cursor at start of new empty line below; mode
;          = INSERT; buffer_dirty = 1; all rows dirty.
;          overflow — cursor unchanged from entry; mode unchanged;
;          msg_file_too_large in status_buffer; parser state zeroed.
; Trashes: A, BC, DE, HL, F.
; Calls:   motion_find_line_end, gapbuf_insert, render_mark_all_dirty,
;          enter_insert_mode (success tail-JP), parser_clear
;          (overflow tail-JP).
; ----------------------------------------------------------------
edits_open_below:
    LD      HL, (cursor_offset)
    PUSH    HL                          ; [entry_cursor]
    CALL    motion_find_line_end        ; HL = LF pos or file_length
    LD      (cursor_offset), HL
    LD      A, 0x0A
    CALL    gapbuf_insert               ; CF=1 if buffer full; state unchanged on full
    JR      C, edits_open_overflow
    JR      edits_open_success_tail


;; ============================================================
;; --- Public entry: edits_open_above (FR27; AC4) ---
;; ============================================================

; ----------------------------------------------------------------
; edits_open_above
; Implements `O` — open a new line above the current line.
;   1. Save entry cursor on stack (rollback target).
;   2. Move cursor to start-of-line (motion_find_line_start —
;      offset past previous LF, or 0 at line 1 / empty buffer).
;   3. Insert 0x0A. gapbuf_insert advances cursor by 1.
;   4. DEC cursor — it now sits ON the just-inserted LF, which IS
;      the new empty line above the original. Trace with
;      "hello\nworld" cursor=8 ('r'): find_line_start gives BOL=6;
;      insert LF at 6 → buffer "hello\n\nworld" (12 B), cursor
;      advances to 7; DEC → cursor=6 (on the new empty line's LF).
;   5. On success: set buffer_dirty; mark rows dirty; enter INSERT.
;   6. On overflow: same shape as edits_open_below — restore entry
;      cursor, mode stays NORMAL, parser cleared.
;
; In:      A = 'O' (MC4; ignored).
; Out:     success — cursor on the just-inserted LF (new empty line
;          above original); mode = INSERT; buffer_dirty = 1; all
;          rows dirty.
;          overflow — same shape as edits_open_below.
; Trashes: A, BC, DE, HL, F.
; Calls:   motion_find_line_start, gapbuf_insert, render_mark_all_dirty,
;          enter_insert_mode (success tail-JP), parser_clear
;          (overflow tail-JP).
; ----------------------------------------------------------------
edits_open_above:
    LD      HL, (cursor_offset)
    PUSH    HL                          ; [entry_cursor]
    CALL    motion_find_line_start      ; HL = BOL (offset past prev LF, or 0)
    LD      (cursor_offset), HL
    LD      A, 0x0A
    CALL    gapbuf_insert               ; CF=1 if buffer full
    JR      C, edits_open_overflow
    LD      HL, (cursor_offset)
    DEC     HL                          ; cursor lands ON the just-inserted LF
    LD      (cursor_offset), HL
    ;; Fall through to edits_open_success_tail.


;; ============================================================
;; --- Internal helper: edits_open_success_tail ---
;; ============================================================

; ----------------------------------------------------------------
; edits_open_success_tail
; Shared success-path tail for o / O: set buffer_dirty, mark all
; rows dirty, balance the saved-entry-cursor PUSH, and tail-JP
; enter_insert_mode for the mode + status + parser_clear work.
; Saves ~9 B per call site vs open-coding both o and O.
;
; Stack precondition: top of stack holds the entry_cursor PUSH
; from edits_open_below / edits_open_above. The POP BC consumes
; it (BC discarded as scratch).
;
; In:      (entry from o / O success paths only; cursor_offset
;          already at the desired post-insert position).
; Out:     buffer_dirty = 1; all rows dirty; mode = INSERT;
;          parser cleared (via enter_insert_mode → parser_clear).
; Trashes: A, BC, DE, F, HL (transitively via render_mark_all_dirty
;          and enter_insert_mode — enter_insert_mode trashes DE
;          via its status_set_message + parser_clear chain).
; Calls:   render_mark_all_dirty, enter_insert_mode (tail-JP).
; ----------------------------------------------------------------
edits_open_success_tail:
    LD      A, 1
    LD      (buffer_dirty), A
    CALL    render_mark_all_dirty
    POP     BC                          ; discard saved entry_cursor
    JP      enter_insert_mode


;; ============================================================
;; --- Internal helper: edits_open_overflow ---
;; ============================================================

; ----------------------------------------------------------------
; edits_open_overflow
; Shared overflow-path tail for o / O: restore the entry cursor
; (FR52), leave mode at NORMAL, tail-JP parser_clear.
; gapbuf_insert has already called status_set_message with
; msg_file_too_large per its AC4 contract — no re-call needed.
;
; Stack precondition: top of stack holds the entry_cursor PUSH.
; The POP HL recovers it; LD (cursor_offset), HL restores cursor.
;
; In:      (entry from o / O overflow paths only).
; Out:     cursor_offset = entry_cursor; mode_byte unchanged
;          (stays NORMAL); status_buffer = msg_file_too_large
;          (already set by gapbuf_insert); parser state zeroed.
; Trashes: A, HL, F (transitively via parser_clear).
; Calls:   parser_clear (tail-JP).
; ----------------------------------------------------------------
edits_open_overflow:
    POP     HL
    LD      (cursor_offset), HL
    JP      parser_clear


;; ============================================================
;; --- Public entry: edits_insert_literal (FR24; AC5, AC8, AC11) ---
;; ============================================================

; ----------------------------------------------------------------
; edits_insert_literal
; The INSERT-mode literal-byte fall-through. Replaces the Story-1.9
; unbound_insert silent-RET stub via the dispatch.asm patch
; (`unbound_insert: JP edits_insert_literal`). Reached for any
; INSERT-mode key not bound in the dispatch_insert table (which
; post-Story-2.8 holds Backspace 0x08, Enter 0x0D, Esc 0x1B —
; everything else falls through here).
;
; AC11 filter: accept printable ASCII only (0x20..0x7E). Reject
; A < 0x20 (control bytes) AND A >= 0x7F (DEL + 0x80..0xFF
; synthesised arrow keycodes KEY_ARROW_UP/DOWN/LEFT/RIGHT and
; C1 control range). Rationale: control bytes and unmapped high-
; bit codes render raw, desyncing shadow vs physical screen
; (deferred-work.md "TAB/CR/NUL/high-bit rendering desync"); a
; stray arrow keystroke mid-INSERT would otherwise commit 0x80+
; into the gap buffer and onto disk via :w (FR52 corruption
; hazard). FR50 says unsupported keys are no-ops; swallowing is
; the simplest safe shape.
;
; AC8 overflow exit-to-NORMAL: on gapbuf_insert CF=1 (buffer full;
; gap_start == gap_end), exit INSERT mode by setting MODE_NORMAL
; and tail-JP parser_clear. msg_file_too_large is already in
; status_buffer (gapbuf_insert set it). Partial text BEFORE the
; failing byte is preserved (gapbuf_insert leaves state unchanged
; on overflow per its AC4 contract); the user CAN press `:w` from
; NORMAL to save the partial content (FR52).
;
; AC9 buffer_dirty: every successful insert writes buffer_dirty=1
; (idempotent — the simpler-is-cleaner choice over a "first-insert-
; only" branch which would save ~3 B but obscure the invariant).
;
; Dirty-row strategy: conservative render_mark_all_dirty on every
; successful insert. Fine-grained render_mark_row_dirty(cursor row)
; is a Growth-tier optimisation deferred (see deferred-work.md).
; The architecture's render_diff per-row shadow-diff makes all-
; dirty cheap — render_diff emits only the cells that actually
; changed (it compares shadow vs freshly-rendered row content).
;
; In:      A = byte to insert (MC4).
; Out:     success — byte inserted; cursor advanced; buffer_dirty = 1;
;          all rows marked dirty.
;          overflow — mode = NORMAL; status = msg_file_too_large;
;          partial text preserved; parser cleared.
;          out-of-range (A < 0x20 or A >= 0x7F) — silent no-op.
; Trashes: A, BC, DE, HL, F.
; Calls:   gapbuf_insert; render_mark_all_dirty (success tail-JP);
;          parser_clear (overflow tail-JP).
; ----------------------------------------------------------------
edits_insert_literal:
    CP      0x20
    RET     C                           ; silent no-op on control bytes (AC11)
    CP      0x7F
    RET     NC                          ; silent no-op on DEL + 0x80+ (AC11)
    CALL    gapbuf_insert               ; A=byte; CF=1 if full (msg already set)
    JR      C, edits_overflow_to_normal
    ;; Fall through to edits_dirty_and_redraw.


;; ============================================================
;; --- Internal helper: edits_dirty_and_redraw ---
;; ============================================================

; ----------------------------------------------------------------
; edits_dirty_and_redraw
; Shared post-successful-mutation tail for the INSERT-mode handlers
; whose mode_byte stays at MODE_INSERT (literal / newline /
; backspace). Sets buffer_dirty = 1 then tail-JPs
; render_mark_all_dirty. ~7 B per call site saved vs open-coding.
;
; In:      (entry from edits_insert_literal / edits_insert_newline /
;          edits_insert_backspace success paths).
; Out:     buffer_dirty = 1; all rows marked dirty.
; Trashes: A, F.
; Calls:   render_mark_all_dirty (tail-JP).
; ----------------------------------------------------------------
edits_dirty_and_redraw:
    LD      A, 1
    LD      (buffer_dirty), A
    JP      render_mark_all_dirty


;; ============================================================
;; --- Internal helper: edits_overflow_to_normal ---
;; ============================================================

; ----------------------------------------------------------------
; edits_overflow_to_normal
; Shared overflow-path tail for the INSERT-mode handlers
; (literal / newline). Exits INSERT mode by setting MODE_NORMAL,
; then tail-JPs parser_clear. msg_file_too_large is already in
; status_buffer (gapbuf_insert set it). Partial text BEFORE the
; failing byte is preserved per FR52.
;
; In:      (entry from edits_insert_literal / edits_insert_newline
;          overflow paths only).
; Out:     mode_byte = MODE_NORMAL; status_buffer unchanged (already
;          msg_file_too_large); parser state zeroed.
; Trashes: A, HL, F.
; Calls:   parser_clear (tail-JP).
; ----------------------------------------------------------------
edits_overflow_to_normal:
    LD      A, MODE_NORMAL
    LD      (mode_byte), A
    JP      parser_clear


;; ============================================================
;; --- Public entry: edits_insert_backspace (AC6) ---
;; ============================================================

; ----------------------------------------------------------------
; edits_insert_backspace
; Backspace in INSERT mode — delete the byte logically before the
; cursor. gapbuf_delete returns CF=1 at BOF (cursor_offset == 0)
; with state unchanged; this handler short-circuits with RET on
; that CF=1, producing a silent BOF no-op (consistent with vi-
; faithful "silent at BOF" — beep would require BIOS_CONOUT which
; is AR13-forbidden outside render/init).
;
; On success: set buffer_dirty = 1 and tail-JP render_mark_all_dirty.
; Conservative shape — a deleted LF shifts every row below up, so
; mark-all is the correct safe behaviour. The fine-grained
; "inspect byte before delete, branch on LF" variant could mark
; only the affected rows but the all-dirty path is ~5 B cheaper
; and render_diff's shadow-diff makes it cheap-enough.
;
; mode_byte stays at MODE_INSERT (Backspace does NOT exit INSERT).
;
; In:      A = 0x08 (MC4; ignored).
; Out:     success — byte before cursor deleted; cursor decremented;
;          buffer_dirty = 1; all rows dirty.
;          BOF — silent no-op; buffer + cursor + buffer_dirty
;          unchanged.
; Trashes: A, BC, DE, HL, F.
; Calls:   gapbuf_delete; render_mark_all_dirty (tail-JP via
;          edits_dirty_and_redraw).
; ----------------------------------------------------------------
edits_insert_backspace:
    CALL    gapbuf_delete               ; CF=1 silent at BOF; state unchanged on BOF
    RET     C
    JP      edits_dirty_and_redraw


;; ============================================================
;; --- Public entry: edits_insert_newline (AC10) ---
;; ============================================================

; ----------------------------------------------------------------
; edits_insert_newline
; Enter (0x0D) in INSERT mode — insert 0x0A (LF; VIBE's line
; separator) at cursor. Bound explicitly via dispatch_insert
; (AC10's recommended bind-explicitly choice) so the translation
; lives at the dispatcher level rather than inside
; edits_insert_literal's branch — cleaner semantically, and a
; future Story 3.x search prompt can give 0x0D different semantics
; in its own dispatch table.
;
; On overflow: same exit-to-NORMAL shape as edits_insert_literal.
; The user's Enter keystroke produces an INSERT-mode exit if the
; buffer was full, which matches the AC8 invariant.
;
; In:      A = 0x0D (MC4; ignored).
; Out:     success — 0x0A inserted at cursor; cursor advanced;
;          buffer_dirty = 1; all rows dirty.
;          overflow — same shape as edits_insert_literal's overflow.
; Trashes: A, BC, DE, HL, F.
; Calls:   gapbuf_insert; render_mark_all_dirty (success tail-JP
;          via edits_dirty_and_redraw); parser_clear (overflow tail-JP
;          via edits_overflow_to_normal).
; ----------------------------------------------------------------
edits_insert_newline:
    LD      A, 0x0A
    CALL    gapbuf_insert
    JR      C, edits_overflow_to_normal
    JP      edits_dirty_and_redraw


;; ============================================================
;; --- Public entry: edits_delete_char (FR28; Story 2.9) ---
;; ============================================================

; ----------------------------------------------------------------
; edits_delete_char
; NORMAL-mode `x` — delete the byte under the cursor. With a
; pending count, delete up to N bytes (clamping at LF / EOF per
; BH2). After the loop, if the cursor landed on LF or past EOF,
; clamp back by 1 (unless cursor == 0, in which case the now-
; empty / now-on-LF line keeps cursor at 0 — the only valid
; position).
;
; Forward-delete implementation per AC8 ("cursor-bounce"):
;   INC cursor_offset; CALL gapbuf_delete. gapbuf_delete moves
;   the gap to the new cursor, decrements gap_start (consuming
;   the byte that was at the original cursor position), and
;   decrements cursor_offset back to the original. Net: byte
;   at original cursor is removed; cursor stays put. AR14-clean
;   — only the existing public gapbuf primitive is touched.
;
; Counted-form algorithm (AC4):
;   1. BC := count_accumulator (defaulted to 1 by motion_apply_count).
;   2. Save N on stack so we can detect "0 deletes happened" at
;      the end (no-op path semantics — AC5 forbids touching
;      buffer_dirty on the no-op path).
;   3. Loop:
;      - Iter top: byte_at(cursor). CF=1 (past EOF) or LF → BREAK
;        to post-clamp. This same check is the AC1/AC3 pre-check
;        on iter 1: if the cursor was already on LF / past EOF
;        before any deletes, BC == N at exit and the post-clamp
;        skips into the no-op branch (no buffer_dirty write).
;      - INC cursor; commit; PUSH BC (gapbuf_delete trashes BC);
;        CALL gapbuf_delete; POP BC.
;      - DEC BC; if 0 → exit loop (count exhausted).
;      - Otherwise continue.
;   4. Exit: HL := N (POP); HL - BC = deletes done. If zero, JP
;      parser_clear directly (no buffer_dirty, no render mark).
;   5. Otherwise post-clamp: if cursor == 0 skip; else
;      byte_at(cursor); if LF or past EOF, DEC cursor.
;   6. CALL edits_dirty_and_redraw (buffer_dirty := 1 +
;      render_mark_all_dirty); JP parser_clear.
;
; FR45 undo recording: STUB for Story 2.9. The hook site for
; Story 2.13 is at the `.commit:` label — AFTER the SBC HL,BC
; == 0 deltas-done check at `.exit_loop` (so the no-op path
; that branches to `.noop_clear` doesn't spuriously emit an
; empty undo entry) and BEFORE the CALL edits_dirty_and_redraw.
; `u` post-`x` reports msg_nothing_to_undo via the existing
; no-entry path.
;
; In:      A = 'x' (MC4; ignored). count_accumulator read via
;          motion_apply_count.
; Out:     success — N bytes deleted (1 <= N <= count, clamped
;          at LF / EOF); cursor at original position or clamped
;          back by 1 per AC1; buffer_dirty = 1; all rows dirty;
;          parser state cleared.
;          no-op — cursor already on LF / past EOF; buffer +
;          cursor + buffer_dirty unchanged; parser cleared.
; Trashes: A, BC, DE, HL, F.
; Calls:   motion_apply_count, motion_byte_at_logical,
;          gapbuf_delete, edits_dirty_and_redraw (success tail),
;          parser_clear (tail-JP both paths).
; ----------------------------------------------------------------
edits_delete_char:
    CALL    motion_apply_count          ; BC = N (default 1)
    PUSH    BC                          ; [N]  — for did-delete detection
.loop:
    LD      HL, (cursor_offset)
    CALL    motion_byte_at_logical      ; A = byte at cursor; CF=1 past EOF; HL preserved
    JR      C, .exit_loop               ; past EOF (or pre-check past-EOF on iter 1) → BREAK
    CP      0x0A
    JR      Z, .exit_loop               ; on LF (or pre-check LF on iter 1) → BREAK
    INC     HL
    LD      (cursor_offset), HL         ; cursor-bounce: cursor advances past the byte
    PUSH    BC                          ; [N] [BC] — gapbuf_delete trashes BC
    CALL    gapbuf_delete               ; consumes byte at original cursor; cursor returns
    POP     BC                          ; [N] — restore loop counter
    DEC     BC
    LD      A, B
    OR      C
    JR      NZ, .loop                   ; more deletes to attempt
.exit_loop:
    POP     HL                          ; HL = N; () — paired with entry PUSH BC
    OR      A
    SBC     HL, BC                      ; HL = N - BC = deletes_done
    LD      A, H
    OR      L
    JR      Z, .noop_clear              ; 0 deletes — skip dirty + clamp
    ;; --- Post-clamp (AC1 / AC2 / AC4 EOL-clamp) ---
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .commit                  ; cursor == 0 — clamp guarded (now-empty buf / LF at 0)
    CALL    motion_byte_at_logical      ; HL preserved
    JR      C, .do_clamp                ; cursor now past EOF (e.g. deleted last byte of file)
    CP      0x0A
    JR      NZ, .commit                 ; cursor on a real byte — leave it
.do_clamp:
    DEC     HL                          ; clamp back onto the new last printable byte
    LD      (cursor_offset), HL
.commit:
    CALL    edits_dirty_and_redraw      ; buffer_dirty=1 + render_mark_all_dirty
.noop_clear:
    JP      parser_clear


;; ============================================================
;; --- Internal helper: edits_line_range_for_count (Story 2.10) ---
;; ============================================================

; ----------------------------------------------------------------
; edits_line_range_for_count
; Compute the line-bounded byte range for `Ndd` / `Nyy` starting at
; the current cursor's line. Walks N line-ends from the cursor's
; line-start, applying the BH2-line-level clamp when the walk hits
; the no-trailing-LF last line.
;
; Algorithm (per AC2 / AC3):
;   1. BC := motion_apply_count (N, defaulted to 1+).
;   2. S  := motion_find_line_start(cursor). Push S.
;   3. walker := S. Loop:
;        - HL := walker. CALL motion_find_line_end.
;          - CF=1 (past EOF; no LF found): last_line_was_eof — branch
;            to .at_eof with HL = file_length, DE trashed.
;          - CF=0: LF found at HL. DEC BC; if 0 → .normal_done with
;            HL = LF position of the N-th line. Else walker := HL+1;
;            continue.
;   4. .normal_done: range = [S, HL+1).
;   5. .at_eof:
;        - S > 0  → range = [S-1, file_length) (consume leading LF).
;        - S == 0 → range = [0, file_length).
;
; In:      (none — reads cursor_offset, count_accumulator).
; Out:     HL = delete_start (logical offset).
;          BC = total_bytes (0 iff buffer is empty / no-op).
;          DE = trashed.
; Trashes: A, BC, DE, HL, F.
; Calls:   motion_apply_count, motion_find_line_start,
;          motion_find_line_end (which transitively calls
;          motion_byte_at_logical — both preserve BC).
; ----------------------------------------------------------------
edits_line_range_for_count:
    CALL    motion_apply_count          ; BC = N (defaulted)
    LD      HL, (cursor_offset)
    CALL    motion_find_line_start      ; HL = S (line start of cursor's line)
    PUSH    HL                          ; [S]
.walk_step:
    CALL    motion_find_line_end        ; HL = LF pos OR file_length; CF=1 iff no LF
    JR      C, .at_eof
    ;; LF found at HL. Step decrements count; loop or finalise.
    DEC     BC
    LD      A, B
    OR      C
    JR      Z, .normal_done             ; N exhausted at this LF
    INC     HL                          ; walker = LF + 1 (next line's first byte)
    JR      .walk_step

.normal_done:
    ;; HL = N-th line's LF position. Regular case: range = [S, HL+1).
    INC     HL                          ; HL = delete_end (= LF + 1)
    POP     DE                          ; DE = S = delete_start; ()
    PUSH    DE                          ; [S]
    OR      A
    SBC     HL, DE                      ; HL = total_bytes = delete_end - S
    LD      B, H
    LD      C, L                        ; BC = total_bytes
    POP     HL                          ; HL = S = delete_start; ()
    RET

.at_eof:
    ;; HL = file_length; last_line_was_eof = true.
    EX      DE, HL                      ; DE = file_length
    POP     HL                          ; HL = S; ()
    LD      A, H
    OR      L
    JR      Z, .eof_s_zero
    ;; S > 0: delete_start = S - 1; total_bytes = file_length - (S-1).
    DEC     HL                          ; HL = S - 1 = delete_start
    PUSH    HL                          ; [delete_start]
    EX      DE, HL                      ; HL = file_length, DE = delete_start
    OR      A
    SBC     HL, DE                      ; HL = file_length - delete_start = total_bytes
    LD      B, H
    LD      C, L                        ; BC = total_bytes
    POP     HL                          ; HL = delete_start
    RET

.eof_s_zero:
    ;; S = 0: delete_start = 0; total_bytes = file_length.
    LD      B, D
    LD      C, E                        ; BC = file_length
    RET                                 ; HL = 0 = delete_start


;; ============================================================
;; --- Internal helper: edits_copy_to_yank (Story 2.10) ---
;; ============================================================

; ----------------------------------------------------------------
; edits_copy_to_yank
; Copy `total_bytes` from logical offsets [delete_start,
; delete_start + total_bytes) into yank_buffer; on success write
; yank_kind := A (caller-supplied kind) and yank_length := total_bytes.
; On over-capacity (total_bytes > YANK_BUFFER_SIZE), the yank register
; is UNCHANGED (per SR6 "predictable failure mode") and CF=1 is
; returned so the caller can surface msg_yank_too_large.
;
; Story 2.11 patched the kind from a hardcoded `LD A, KIND_LINE`
; (Story 2.10) to a caller-supplied parameter via register A. The
; supported kinds are KIND_CHAR (Story 2.11 dw/d$/c5w/y3j) and
; KIND_LINE (Story 2.10 dd/yy); KIND_BLOCK is reserved for Epic 3
; visual-block. Existing Story-2.10 callers (op_dd / op_yy) load
; A=KIND_LINE before the CALL — invariant-preserving from the test's
; perspective.
;
; Uses motion_byte_at_logical for source reads — the source range
; may straddle the gap (no LDIR fastpath available without a
; pre-relocation of the gap). The per-byte loop runs ~30 T-states/B;
; a maxed 1024-byte yank costs ~7.5 ms at 4 MHz (NFR3 budget).
; motion_byte_at_logical's contract preserves BC (see motions.asm:
; 511-512), so the loop counter survives without PUSH/POP bracketing.
; The helper DOES trash DE, however (it loads DE = GAP_BUFFER_BASE
; on the .before_gap return path), so the destination pointer is
; bracketed with PUSH/POP DE across each call.
;
; In:      HL = delete_start (logical offset).
;          BC = total_bytes (must be > 0 — caller guards 0-byte case).
;          A  = kind (KIND_CHAR | KIND_LINE; Story 2.11 parameterisation).
; Out:     CF=0 on success: yank_kind := A; yank_length := BC;
;          BC bytes copied to yank_buffer.
;          CF=1 on over-capacity: yank_kind / yank_length / yank_buffer
;          all UNCHANGED.
; Trashes: A, BC, DE, HL, F.
; Calls:   motion_byte_at_logical (preserves BC).
; ----------------------------------------------------------------
edits_copy_to_yank:
    ;; Capacity check: BC > YANK_BUFFER_SIZE?
    ;; LD HL, YANK_BUFFER_SIZE; SBC HL, BC: CF=1 iff BC > YANK_BUFFER_SIZE.
    PUSH    HL                          ; [src]
    LD      HL, YANK_BUFFER_SIZE
    OR      A
    SBC     HL, BC                      ; HL = SIZE - BC; CF=1 iff BC > SIZE
    POP     HL                          ; restore src; flags preserved
    RET     C                           ; over-capacity — yank UNCHANGED, CF=1
    ;; Within capacity. Save the kind (A) for the success tail (the
    ;; copy loop trashes A); copy BC bytes from logical HL to yank_buffer.
    PUSH    AF                          ; [kind, F]
    LD      DE, yank_buffer
    PUSH    BC                          ; [kind][total_bytes]
.copy_loop:
    PUSH    DE                          ; motion_byte_at_logical trashes DE
    CALL    motion_byte_at_logical      ; A = byte; HL preserved; BC preserved
    POP     DE
    LD      (DE), A
    INC     HL
    INC     DE
    DEC     BC
    LD      A, B
    OR      C
    JR      NZ, .copy_loop
    POP     BC                          ; [kind] → BC = total_bytes
    LD      (yank_length), BC
    POP     AF                          ; restore caller-supplied kind
    LD      (yank_kind), A
    OR      A                           ; CF = 0 (success)
    RET


;; ============================================================
;; --- Internal helper: edits_range_delete (Story 2.10) ---
;; ============================================================

; ----------------------------------------------------------------
; edits_range_delete
; Remove `total_bytes` contiguous bytes from logical offsets
; [delete_start, delete_start + total_bytes). Pre-stages
; cursor_offset at delete_end, then loops gapbuf_delete `total_bytes`
; times — each call consumes the byte at (cursor-1) and decrements
; cursor. Post-loop, cursor sits at delete_start.
;
; AR14-clean: the only buffer-mutation surface is the AR14-compliant
; gapbuf_delete primitive. Per-iter cost amortises: the first call
; relocates the gap to delete_end; subsequent calls find the gap in
; place and just decrement gap_start (~10 T-states each). Net cost
; on a 100-byte delete: ~2.5 ms at 4 MHz — sub-perceptible.
;
; In:      HL = delete_start (logical offset).
;          BC = total_bytes (must be > 0 — caller guards 0-byte case).
; Out:     cursor_offset = delete_start; total_bytes bytes removed
;          from the gap buffer; gap_start / gap_end consistent.
; Trashes: A, BC, DE, HL, F.
; Calls:   gapbuf_delete (BC trashed per call, restored via PUSH/POP).
; ----------------------------------------------------------------
edits_range_delete:
    ADD     HL, BC                      ; HL = delete_end = delete_start + total_bytes
    LD      (cursor_offset), HL         ; pre-stage cursor at delete_end
.del_loop:
    PUSH    BC                          ; [count] — gapbuf_delete trashes BC
    CALL    gapbuf_delete               ; consumes byte at cursor-1; decrements cursor
    POP     BC                          ; restore loop counter
    DEC     BC
    LD      A, B
    OR      C
    JR      NZ, .del_loop
    RET                                 ; cursor_offset = delete_start


;; ============================================================
;; --- Public entry: op_dd (FR29; Story 2.10) ---
;; ============================================================

; ----------------------------------------------------------------
; op_dd
; NORMAL-mode `dd` / `Ndd` — delete the current line (or N lines
; from the current). Captures the deleted bytes in the yank
; register (yank_kind := KIND_LINE) UNLESS total_bytes >
; YANK_BUFFER_SIZE (1024), in which case the yank register is
; preserved and msg_yank_too_large surfaces — the deletion STILL
; PROCEEDS (per epic AC: user loses content but is told via status).
;
; Post-delete cursor placement (AC2 / AC3):
;   1. If new file_length == 0 (buffer empty): cursor = 0.
;   2. If delete_start < new_file_length: cursor = delete_start
;      (already there after edits_range_delete).
;   3. Else (deleted to file end; still content above): cursor =
;      motion_find_line_start(new_file_length - 1) — start of new
;      last line.
;
; FR45 undo recording: STUB for Story 2.10. The hook site for
; Story 2.13 is BEFORE the CALL edits_copy_to_yank (the gap-buffer
; bytes are still in place at their pre-delete logical offsets, AND
; undo recording is independent of yank capacity — a yank-too-large
; refusal does NOT also block undo).
;
; In:      A = 'd' (MC4; ignored — dispatch chain consumed both
;          'd' bytes). count_accumulator read via motion_apply_count
;          (transitively, inside edits_line_range_for_count).
;          pending_operator already 'd' (set by first
;          parser_handle_operator).
; Out:     success — N lines deleted; yank register updated
;          (KIND_LINE) OR yank refused (status surface + register
;          preserved); buffer_dirty = 1; all rows dirty; cursor
;          placed per the three-way rule above; parser state
;          zeroed.
;          no-op (empty buffer / 0-byte line range) — buffer +
;          cursor + buffer_dirty unchanged; parser cleared.
; Trashes: A, BC, DE, HL, F.
; Calls:   edits_line_range_for_count, edits_copy_to_yank,
;          status_set_message (on yank refusal),
;          edits_range_delete, motion_byte_at_logical (post-delete
;          probe), motion_find_line_start (case-3 placement),
;          edits_dirty_and_redraw, parser_clear (tail-JP both paths).
; ----------------------------------------------------------------
op_dd:
    CALL    edits_line_range_for_count  ; HL=delete_start, BC=total_bytes
    ;; 0-byte guard (empty buffer / no-op).
    LD      A, B
    OR      C
    JP      Z, parser_clear

    ;; Attempt yank-copy. Preserve HL/BC for the subsequent delete.
    ;; (Story 2.13 FR45 undo hook site: HERE — before edits_copy_to_yank.
    ;;  The gap-buffer bytes are still at their pre-delete logical
    ;;  positions, and undo recording is independent of yank capacity.)
    PUSH    HL                          ; [delete_start]
    PUSH    BC                          ; [delete_start][total_bytes]
    LD      A, KIND_LINE                ; Story 2.11: parameterised yank kind
    CALL    edits_copy_to_yank          ; CF=1 on over-capacity
    POP     BC                          ; restore total_bytes
    POP     HL                          ; restore delete_start
    JR      NC, .yank_ok
    ;; Yank refused: surface status; deletion STILL proceeds.
    PUSH    HL                          ; [delete_start]
    PUSH    BC                          ; [delete_start][total_bytes]
    LD      HL, msg_yank_too_large
    XOR     A
    CALL    status_set_message
    POP     BC
    POP     HL
.yank_ok:
    CALL    edits_range_delete          ; cursor := delete_start; bytes removed

    ;; Post-delete cursor placement (AC2 / AC3 three-way decision).
    LD      HL, (cursor_offset)         ; HL = delete_start
    CALL    motion_byte_at_logical      ; A = byte at cursor; CF=1 if past EOF
    JR      NC, .post_commit            ; cursor < new_file_length → case 2 done
    ;; CF=1: cursor >= file_length. Either empty buffer (case 1) OR
    ;; deleted-to-EOF with content above (case 3).
    LD      A, H
    OR      L
    JR      Z, .post_commit             ; cursor == 0 → empty buffer or BOF; done
    ;; Case 3: cursor = motion_find_line_start(cursor - 1).
    DEC     HL                          ; cursor - 1 = last byte of new file
    CALL    motion_find_line_start      ; HL = start of new last line
    LD      (cursor_offset), HL
.post_commit:
    CALL    edits_dirty_and_redraw      ; buffer_dirty=1 + render_mark_all_dirty
    JP      parser_clear


;; ============================================================
;; --- Public entry: op_yy (FR31; Story 2.10) ---
;; ============================================================

; ----------------------------------------------------------------
; op_yy
; NORMAL-mode `yy` / `Nyy` — yank the current line (or N lines)
; into the yank register (yank_kind := KIND_LINE). Read-only op;
; buffer + cursor + buffer_dirty all UNCHANGED on every path.
;
; Same line-bounds computation as op_dd (so `dd` then `p` and
; `yy` then `p` produce identical paste content — vi muscle
; memory invariant). Capacity refusal same shape: yank register
; preserved, msg_yank_too_large surfaced. No deletion to "still
; proceed" with — yy is read-only.
;
; In:      A = 'y' (MC4; ignored — dispatch chain consumed both
;          'y' bytes). count_accumulator read via motion_apply_count
;          (transitively, inside edits_line_range_for_count).
; Out:     success — yank register updated (KIND_LINE); buffer +
;          cursor + buffer_dirty UNCHANGED; parser cleared.
;          refusal — status = msg_yank_too_large; yank register
;          preserved; buffer + cursor + buffer_dirty UNCHANGED;
;          parser cleared.
;          no-op (0-byte range) — silent (no status); state
;          UNCHANGED; parser cleared.
; Trashes: A, BC, DE, HL, F.
; Calls:   edits_line_range_for_count, edits_copy_to_yank,
;          status_set_message (on capacity refusal), parser_clear
;          (tail-JP every path).
; ----------------------------------------------------------------
op_yy:
    CALL    edits_line_range_for_count  ; HL=delete_start, BC=total_bytes
    ;; 0-byte guard (empty buffer / no-op; silent — yy is read-only).
    LD      A, B
    OR      C
    JP      Z, parser_clear

    LD      A, KIND_LINE                ; Story 2.11: parameterised yank kind
    CALL    edits_copy_to_yank          ; CF=1 on over-capacity
    JP      NC, parser_clear            ; success — silent
    ;; Refused: surface status; no buffer mutation; clear parser.
    LD      HL, msg_yank_too_large
    XOR     A
    CALL    status_set_message
    JP      parser_clear


;; ============================================================
;; --- Story 2.11 compose layer (operator+motion + >>/<<) ---
;; ============================================================
;;
;; Architectural overview:
;;
;; The compose layer wires NORMAL-mode operators ('d', 'y', 'c', '>',
;; '<') with NORMAL-mode motions ('h', 'l', 'j', 'k', 'w', 'b', '0',
;; '$', 'gg', 'G') via co-operation between two pieces of shared state:
;;
;;   1. `motions_compose_entry` (motions.asm DEFW) — entry cursor saved
;;      by every motion handler's prologue.
;;   2. `pending_motion_inclusive` (state.inc cell) — flag set by
;;      motion_dollar's prologue; consumed + cleared by op_compose_*
;;      via parser_clear's centralised cleanup.
;;
;; Each motion handler ends with `JP edits_compose_or_clear` (Story
;; 2.11 patched ALL motion-tail JP parser_clear sites). The shared
;; tail reads pending_operator and either:
;;   - routes to one of the 5 per-operator bodies (d/y/c/>/<), OR
;;   - falls through to parser_clear (bare motion path — zero
;;     behaviour change for operator-less motions).
;;
;; Range derivation via `edits_compose_range` (HL=range_start,
;; BC=total_bytes, DE=range_end). Range is half-open [start, end).
;; Backward motions (db / dgg / dh / dk / d0) swap so range_start is
;; always the smaller offset.
;;
;; pending_motion_inclusive extends the range by +1 byte for vi-
;; faithful `d$` / `c$` / `y$` (motion_dollar lands cursor on the
;; LAST printable byte; half-open math excludes it; the bump
;; re-includes it).
;;
;; State-discipline pin (same shape as Story 2.10's op_dd / op_yy):
;; edits_compose_or_clear MUST read pending_operator BEFORE any tail-
;; JP parser_clear. Per-operator bodies read motions_compose_entry +
;; pending_motion_inclusive + count_accumulator BEFORE their tail-JP
;; parser_clear. A future "consistency cleanup" that hoisted
;; parser_clear into a common prelude HERE would silently break the
;; compose layer.
;;
;; FR45 undo recording: STUB for Story 2.11. Hook sites:
;;   - op_compose_d / op_compose_c: BEFORE the yank-copy (gap-buffer
;;     bytes still at pre-delete logical positions; undo independent
;;     of yank capacity).
;;   - op_compose_indent / op_compose_dedent / op_indent_line /
;;     op_dedent_line: BEFORE the first per-line insert/delete
;;     (the line-walk's first call).
;;   - op_compose_y: NEVER (yank-only).


;; ============================================================
;; --- Public entry: edits_compose_or_clear (Story 2.11; AC2) ---
;; ============================================================

; ----------------------------------------------------------------
; edits_compose_or_clear
; Shared compose tail. Reads pending_operator and routes to the
; per-operator body (or parser_clear for bare motion). Tail-JP
; target of every motion handler's exit point.
;
; State-discipline (critical): reads pending_operator BEFORE any
; tail-JP parser_clear. Per-operator bodies also read
; motions_compose_entry + pending_motion_inclusive + count_accumulator
; BEFORE their (eventual) tail-JP parser_clear. The defensive 'else'
; arm (JP parser_clear) shouldn't fire — only the 5 chars 'd' / 'y' /
; 'c' / '>' / '<' ever land in pending_operator via parser_handle_operator
; — but is kept as the silent fall-through per AC2.
;
; In:      pending_operator already set by parser_handle_operator
;          (or 0 for the bare-motion path); cursor_offset = motion's
;          landing offset; motions_compose_entry = entry cursor.
; Out:     control transferred to per-operator body OR JP parser_clear
;          for bare motion. Per-operator bodies tail-JP parser_clear
;          themselves (op_compose_c tail-JPs enter_insert_mode which
;          itself tail-JPs parser_clear).
; Trashes: A, F (+ per-operator body trashes).
; Calls:   op_compose_d / op_compose_y / op_compose_c / op_compose_indent
;          / op_compose_dedent (JP); parser_clear (JP — bare motion +
;          defensive 'else' arm).
; ----------------------------------------------------------------
edits_compose_or_clear:
    LD      A, (pending_operator)
    OR      A
    JP      Z, parser_clear             ; bare motion — zero behaviour change
    CP      'd'
    JP      Z, op_compose_d
    CP      'y'
    JP      Z, op_compose_y
    CP      'c'
    JP      Z, op_compose_c
    CP      '>'
    JP      Z, op_compose_indent
    CP      '<'
    JP      Z, op_compose_dedent
    JP      parser_clear                ; defensive fall-through (unreachable)


;; ============================================================
;; --- Internal helper: edits_compose_range (Story 2.11; AC3) ---
;; ============================================================

; ----------------------------------------------------------------
; edits_compose_range
; Derive the half-open [range_start, range_end) byte range from the
; motion's landing offset (cursor_offset) and the entry cursor
; (motions_compose_entry). Backward motions (landing < entry) swap
; so range_start is always the smaller offset.
;
; Caller responsibilities (NOT in this helper):
;   - 0-byte guard (caller branches on BC == 0).
;   - Inclusive bump (caller adds 1 to BC iff pending_motion_inclusive).
;
; In:      cursor_offset = motion's landing offset (state).
;          motions_compose_entry = entry cursor (state).
; Out:     HL = range_start (smaller of landing / entry).
;          BC = total_bytes  (= |landing - entry|; may be 0 for no-move).
;          DE = range_end   (= HL + BC; larger of landing / entry).
; Trashes: A, BC, DE, HL, F.
; Calls:   (none — pure math).
; ----------------------------------------------------------------
edits_compose_range:
    LD      HL, (cursor_offset)         ; HL = landing
    LD      DE, (motions_compose_entry) ; DE = entry
    OR      A
    SBC     HL, DE                      ; HL = landing - entry; CF=1 iff landing < entry
    JR      NC, .forward_or_zero
    ;; Backward motion: landing < entry. range_start = landing;
    ;; range_end = entry; total_bytes = entry - landing.
    LD      HL, (motions_compose_entry)
    LD      DE, (cursor_offset)
    OR      A
    SBC     HL, DE                      ; HL = entry - landing = total_bytes
    LD      B, H
    LD      C, L                        ; BC = total_bytes
    LD      HL, (cursor_offset)         ; HL = range_start = landing
    LD      DE, (motions_compose_entry) ; DE = range_end = entry
    RET
.forward_or_zero:
    ;; Forward (or no-move): landing >= entry. HL holds landing - entry.
    LD      B, H
    LD      C, L                        ; BC = total_bytes
    LD      HL, (motions_compose_entry) ; HL = range_start = entry
    LD      DE, (cursor_offset)         ; DE = range_end = landing
    RET


;; ============================================================
;; --- Public entry: op_compose_d (Story 2.11; AC4 — FR39 d+motion)
;; ============================================================

; ----------------------------------------------------------------
; op_compose_d
; NORMAL-mode `d` + motion (`dw`, `d$`, `db`, `d3j`, `dgg`, `dG`, …).
; Algorithm:
;   1. CALL edits_compose_range — HL=start, BC=bytes, DE=end.
;   2. 0-byte guard: BC == 0 → JP parser_clear (no-move motion).
;   3. Apply pending_motion_inclusive: if set, INC BC (vi-faithful
;      d$ / c$ inclusive-landing semantic).
;   4. Yank-copy with A=KIND_CHAR. CF=1 → surface msg_yank_too_large;
;      deletion STILL proceeds (matches Story 2.10's op_dd semantic).
;   5. Range-delete via edits_range_delete (cursor := range_start).
;   6. Post-delete cursor clamp (x-style — Story 2.9 AC1/AC2 shape):
;      if cursor > 0 AND (byte at cursor is past-EOF OR LF), DEC cursor.
;      Different from op_dd's case-3 (which walks to LINE-start); op_dd
;      operates at line granularity, op_compose_d at character granularity.
;   7. CALL edits_dirty_and_redraw; JP parser_clear.
;
; FR45 undo recording: STUB. Hook site = BEFORE the yank-copy.
;
; In:      (state) pending_operator='d', cursor_offset=landing,
;          motions_compose_entry=entry cursor, pending_motion_inclusive
;          may be 0 or 1.
; Out:     success — N bytes deleted; yank register (KIND_CHAR) updated
;          OR refused (status surface, register preserved); buffer_dirty=1;
;          cursor at range_start (or clamped back by 1); parser cleared.
;          no-op — buffer + cursor + buffer_dirty UNCHANGED; parser cleared.
; Trashes: A, BC, DE, HL, F.
; Calls:   edits_compose_range, edits_copy_to_yank (A=KIND_CHAR),
;          status_set_message (on refusal), edits_range_delete,
;          motion_byte_at_logical (post-delete EOF probe),
;          edits_dirty_and_redraw, parser_clear (tail-JP both paths).
; ----------------------------------------------------------------
op_compose_d:
    CALL    edits_compose_range         ; HL=start, BC=bytes, DE=end
    ;; 0-byte guard.
    LD      A, B
    OR      C
    JP      Z, parser_clear
    ;; Inclusive bump (motion_dollar sets pending_motion_inclusive=1).
    LD      A, (pending_motion_inclusive)
    OR      A
    JR      Z, .cd_no_bump
    INC     BC
.cd_no_bump:
    ;; Yank-copy attempt (Story 2.13 FR45 undo hook site: HERE —
    ;; gap-buffer bytes still at pre-delete logical positions).
    PUSH    HL                          ; [start]
    PUSH    BC                          ; [start][bytes]
    LD      A, KIND_CHAR                ; Story 2.11 first writer of KIND_CHAR
    CALL    edits_copy_to_yank
    POP     BC
    POP     HL
    JR      NC, .cd_yank_ok
    ;; Refused: surface msg_yank_too_large; deletion still proceeds.
    PUSH    HL
    PUSH    BC
    LD      HL, msg_yank_too_large
    XOR     A
    CALL    status_set_message
    POP     BC
    POP     HL
.cd_yank_ok:
    CALL    edits_range_delete          ; cursor := range_start
    ;; Post-delete cursor clamp (Story 2.9 x-style EOL/EOF shape).
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .cd_commit               ; cursor == 0 — no clamp possible
    CALL    motion_byte_at_logical      ; HL preserved
    JR      C, .cd_do_clamp             ; cursor past EOF → clamp
    CP      0x0A
    JR      NZ, .cd_commit              ; cursor on a real byte → leave
.cd_do_clamp:
    DEC     HL
    LD      (cursor_offset), HL
.cd_commit:
    CALL    edits_dirty_and_redraw
    JP      parser_clear


;; ============================================================
;; --- Public entry: op_compose_y (Story 2.11; AC6 — FR39 y+motion)
;; ============================================================

; ----------------------------------------------------------------
; op_compose_y
; NORMAL-mode `y` + motion (`yw`, `y$`, `y3j`, `ygg`, `yG`, …).
; Read-only: buffer + buffer_dirty UNCHANGED on every path.
;
; Cursor handling (subtle — pin in test): vi's `yw` leaves cursor at
; the ORIGINAL position (yank consumes the motion's landing; cursor
; doesn't move). Implementation: restore cursor_offset :=
; motions_compose_entry immediately after edits_compose_range (which
; reads the CURRENT cursor as the landing).
;
; In:      (state) pending_operator='y', cursor_offset=landing,
;          motions_compose_entry=entry cursor.
; Out:     success — yank register (KIND_CHAR) updated; cursor RESTORED
;          to entry; buffer + buffer_dirty UNCHANGED; parser cleared.
;          refusal — status = msg_yank_too_large; yank register
;          preserved; cursor RESTORED; buffer + buffer_dirty UNCHANGED;
;          parser cleared.
;          no-op (0-byte) — silent; cursor RESTORED; parser cleared.
; Trashes: A, BC, DE, HL, F.
; Calls:   edits_compose_range, edits_copy_to_yank (A=KIND_CHAR),
;          status_set_message (on refusal), parser_clear (tail-JP).
; ----------------------------------------------------------------
op_compose_y:
    CALL    edits_compose_range         ; HL=start, BC=bytes (DE unused)
    ;; Restore cursor to entry on EVERY path (vi convention: yank
    ;; does NOT advance cursor). Done AFTER edits_compose_range
    ;; because that helper reads cursor_offset as the landing.
    PUSH    HL                          ; [start] preserved across restore
    LD      HL, (motions_compose_entry)
    LD      (cursor_offset), HL
    POP     HL
    ;; 0-byte guard.
    LD      A, B
    OR      C
    JP      Z, parser_clear
    ;; Inclusive bump.
    LD      A, (pending_motion_inclusive)
    OR      A
    JR      Z, .cy_no_bump
    INC     BC
.cy_no_bump:
    LD      A, KIND_CHAR
    CALL    edits_copy_to_yank
    JP      NC, parser_clear            ; success — silent
    ;; Refused: surface status; no buffer mutation; cursor already
    ;; restored above.
    LD      HL, msg_yank_too_large
    XOR     A
    CALL    status_set_message
    JP      parser_clear


;; ============================================================
;; --- Public entry: op_compose_c (Story 2.11; AC8 — FR39 c+motion)
;; ============================================================

; ----------------------------------------------------------------
; op_compose_c
; NORMAL-mode `c` + motion (`cw`, `c$`, `c5w`, …). Same shape as
; op_compose_d through range-delete, but skips the x-style EOF clamp
; (cursor must stay at range_start so INSERT mode opens at the right
; position), then tail-JPs enter_insert_mode (which sets MODE_INSERT,
; surfaces "-- insert --", and tail-JPs parser_clear).
;
; `cc` (change-line doubled) is OUT of MVP scope (epic spec); the
; doubled-`c` arm of parser_doubled_operator_stub still surfaces
; msg_not_implemented (unchanged from Story 2.10).
;
; In:      (state) pending_operator='c', cursor_offset=landing,
;          motions_compose_entry=entry cursor.
; Out:     success — N bytes deleted; yank (KIND_CHAR) updated OR
;          refused; cursor at range_start; mode = MODE_INSERT;
;          status = "-- insert --"; parser cleared (via
;          enter_insert_mode's tail-JP).
;          no-op (0-byte) — silent; parser cleared.
; Trashes: A, BC, DE, HL, F.
; Calls:   edits_compose_range, edits_copy_to_yank (A=KIND_CHAR),
;          status_set_message (on refusal), edits_range_delete,
;          edits_dirty_and_redraw, enter_insert_mode (tail-JP),
;          parser_clear (no-op tail-JP).
; ----------------------------------------------------------------
op_compose_c:
    CALL    edits_compose_range
    LD      A, B
    OR      C
    JP      Z, parser_clear
    LD      A, (pending_motion_inclusive)
    OR      A
    JR      Z, .cc_no_bump
    INC     BC
.cc_no_bump:
    PUSH    HL
    PUSH    BC
    LD      A, KIND_CHAR
    CALL    edits_copy_to_yank
    POP     BC
    POP     HL
    JR      NC, .cc_yank_ok
    PUSH    HL
    PUSH    BC
    LD      HL, msg_yank_too_large
    XOR     A
    CALL    status_set_message
    POP     BC
    POP     HL
.cc_yank_ok:
    CALL    edits_range_delete          ; cursor := range_start
    CALL    edits_dirty_and_redraw
    JP      enter_insert_mode           ; tail-JP — sets MODE_INSERT + status + parser_clear


;; ============================================================
;; --- Public entry: op_compose_indent (Story 2.11; AC9 — > + motion)
;; ============================================================

; ----------------------------------------------------------------
; op_compose_indent
; NORMAL-mode `>` + motion (`>j`, `>k`, `>w`, `>$`, …). Line-class:
; the motion's character range is line-promoted (extended to whole
; lines that the range overlaps). Each promoted line gets an
; INDENT_BYTE (0x20 = space) inserted at its line-start.
;
; Cursor post-position (per AC9 Implementation Q4 — "simple"): restore
; to entry cursor. Vi's "first non-whitespace of line" polish is
; post-MVP (deferred-work.md).
;
; BC == 0 (no-move motion → `>0`, `>l` at EOL, `>$` on empty line):
; promote both bounds to motions_compose_entry's line — vi-faithful
; "operator on the current line".
;
; In:      (state) pending_operator='>', cursor_offset=landing,
;          motions_compose_entry=entry cursor.
; Out:     each line in the promoted range gets INDENT_BYTE prepended;
;          cursor restored to entry; buffer_dirty=1 (iff any change);
;          parser cleared.
;          gapbuf full mid-walk → partial indent persists;
;          msg_file_too_large surfaced (via gapbuf_insert); parser
;          cleared.
; Trashes: A, BC, DE, HL, F.
; Calls:   edits_compose_range, motion_find_line_start (line-promote),
;          motion_find_line_end (line-promote), edits_indent_walk,
;          edits_dirty_and_redraw, parser_clear (tail-JP).
; ----------------------------------------------------------------
op_compose_indent:
    CALL    edits_compose_range
    LD      A, B
    OR      C
    JR      NZ, .ci_have_range
    ;; BC=0: promote to current line (use motions_compose_entry).
    LD      HL, (motions_compose_entry)
    CALL    motion_find_line_start      ; HL = line_start
    PUSH    HL                          ; [line_start]
    LD      HL, (motions_compose_entry)
    CALL    motion_find_line_end        ; HL = line_end (LF pos or file_length)
    INC     HL                          ; promoted_end = past the LF (or past EOF — safe)
    EX      DE, HL                      ; DE = promoted_end
    POP     HL                          ; HL = promoted_start
    JR      .ci_walk
.ci_have_range:
    ;; Line-promote: HL = line_start(range_start); DE = line_end(range_end-1) + 1.
    PUSH    DE                          ; [range_end]
    CALL    motion_find_line_start      ; HL = promoted_start
    POP     DE
    PUSH    HL                          ; [promoted_start]
    EX      DE, HL                      ; HL = range_end
    DEC     HL                          ; HL = last byte in range
    CALL    motion_find_line_end        ; HL = line_end of that
    INC     HL                          ; promoted_end = past LF
    EX      DE, HL                      ; DE = promoted_end
    POP     HL                          ; HL = promoted_start
.ci_walk:
    XOR     A                           ; A=0 → indent mode (insert INDENT_BYTE)
    CALL    edits_indent_walk
    ;; Restore cursor to entry.
    LD      HL, (motions_compose_entry)
    LD      (cursor_offset), HL
    ;; Mark dirty iff at least one line changed.
    LD      A, (edits_indent_walk_dirty)
    OR      A
    JP      Z, parser_clear             ; no change — silent (matches dedent-no-op spec)
    CALL    edits_dirty_and_redraw
    JP      parser_clear


;; ============================================================
;; --- Public entry: op_compose_dedent (Story 2.11; AC9 — < + motion)
;; ============================================================

; ----------------------------------------------------------------
; op_compose_dedent
; Symmetric to op_compose_indent. Each promoted line has its leading
; INDENT_BYTE removed; lines whose first byte is NOT INDENT_BYTE are
; silently no-ops (vi convention).
;
; In:      (state) pending_operator='<', cursor_offset=landing,
;          motions_compose_entry=entry cursor.
; Out:     each line in the promoted range with leading INDENT_BYTE
;          has it removed; lines without leading INDENT_BYTE unchanged.
;          cursor restored to entry; buffer_dirty=1 iff any change;
;          parser cleared.
; Trashes: A, BC, DE, HL, F.
; Calls:   edits_compose_range, motion_find_line_start, motion_find_line_end,
;          edits_indent_walk, edits_dirty_and_redraw, parser_clear (tail-JP).
; ----------------------------------------------------------------
op_compose_dedent:
    CALL    edits_compose_range
    LD      A, B
    OR      C
    JR      NZ, .cdd_have_range
    LD      HL, (motions_compose_entry)
    CALL    motion_find_line_start
    PUSH    HL
    LD      HL, (motions_compose_entry)
    CALL    motion_find_line_end
    INC     HL
    EX      DE, HL
    POP     HL
    JR      .cdd_walk
.cdd_have_range:
    PUSH    DE
    CALL    motion_find_line_start
    POP     DE
    PUSH    HL
    EX      DE, HL
    DEC     HL
    CALL    motion_find_line_end
    INC     HL
    EX      DE, HL
    POP     HL
.cdd_walk:
    LD      A, 1                        ; A=1 → dedent mode
    CALL    edits_indent_walk
    LD      HL, (motions_compose_entry)
    LD      (cursor_offset), HL
    LD      A, (edits_indent_walk_dirty)
    OR      A
    JP      Z, parser_clear
    CALL    edits_dirty_and_redraw
    JP      parser_clear


;; ============================================================
;; --- Public entry: op_indent_line (Story 2.11; AC10 — >>)
;; ============================================================

; ----------------------------------------------------------------
; op_indent_line
; NORMAL-mode `>>` / `N>>`. Indent the current line (or N consecutive
; lines starting at cursor's line). Thin wrapper around the same
; edits_indent_walk used by op_compose_indent: reuses Story 2.10's
; edits_line_range_for_count helper for the line-range computation.
;
; Cursor: restored to entry (saved on stack at top of routine).
; Tail: JP parser_clear (op_indent_line does NOT enter INSERT).
;
; In:      (state) pending_operator='>', count_accumulator may be N>=1.
;          cursor_offset = NORMAL-mode cursor (no compose prologue
;          ran since this path comes from parser_doubled_operator_stub,
;          not from a motion handler).
; Out:     N consecutive lines indented; cursor restored to entry;
;          buffer_dirty=1 iff any change; parser cleared.
;          empty buffer / 0-byte range — silent no-op; parser cleared.
; Trashes: A, BC, DE, HL, F.
; Calls:   edits_line_range_for_count, edits_indent_walk,
;          edits_dirty_and_redraw, parser_clear (tail-JP).
; ----------------------------------------------------------------
op_indent_line:
    LD      HL, (cursor_offset)
    PUSH    HL                          ; [entry_cursor]
    CALL    edits_line_range_for_count  ; HL=line_start, BC=total_bytes
    LD      A, B
    OR      C
    JR      Z, .il_empty
    ;; promoted_end = HL + BC.
    PUSH    HL                          ; [entry_cursor][line_start]
    ADD     HL, BC
    EX      DE, HL                      ; DE = promoted_end
    POP     HL                          ; HL = line_start
    XOR     A                           ; indent mode
    CALL    edits_indent_walk
    POP     HL                          ; [entry_cursor] → HL
    LD      (cursor_offset), HL
    LD      A, (edits_indent_walk_dirty)
    OR      A
    JP      Z, parser_clear
    CALL    edits_dirty_and_redraw
    JP      parser_clear
.il_empty:
    POP     HL
    LD      (cursor_offset), HL
    JP      parser_clear


;; ============================================================
;; --- Public entry: op_dedent_line (Story 2.11; AC10 — <<)
;; ============================================================

; ----------------------------------------------------------------
; op_dedent_line
; NORMAL-mode `<<` / `N<<`. Symmetric to op_indent_line.
;
; In:      pending_operator='<', count may be N>=1.
; Out:     N consecutive lines dedented (lines without leading
;          INDENT_BYTE are silent no-ops); cursor restored to entry;
;          buffer_dirty=1 iff any change; parser cleared.
; Trashes: A, BC, DE, HL, F.
; Calls:   edits_line_range_for_count, edits_indent_walk,
;          edits_dirty_and_redraw, parser_clear (tail-JP).
; ----------------------------------------------------------------
op_dedent_line:
    LD      HL, (cursor_offset)
    PUSH    HL
    CALL    edits_line_range_for_count
    LD      A, B
    OR      C
    JR      Z, .dl_empty
    PUSH    HL
    ADD     HL, BC
    EX      DE, HL
    POP     HL
    LD      A, 1                        ; dedent mode
    CALL    edits_indent_walk
    POP     HL
    LD      (cursor_offset), HL
    LD      A, (edits_indent_walk_dirty)
    OR      A
    JP      Z, parser_clear
    CALL    edits_dirty_and_redraw
    JP      parser_clear
.dl_empty:
    POP     HL
    LD      (cursor_offset), HL
    JP      parser_clear


;; ============================================================
;; --- Internal helper: edits_indent_walk (Story 2.11)
;; ============================================================

; ----------------------------------------------------------------
; edits_indent_walk
; Walk every line whose start is in [promoted_start, promoted_end);
; for each line, apply the per-line op (insert INDENT_BYTE for
; indent mode, conditional-delete-INDENT_BYTE for dedent mode).
;
; The helper is parameterised on the mode via a module-local byte
; (edits_indent_walk_mode), set at entry from register A. Z80 has
; no clean callback shape; the flag-byte approach saves ~30-40 B
; vs duplicating the body for indent/dedent. The "any change?" flag
; (edits_indent_walk_dirty) is written by each successful op and
; read by the caller to decide whether to mark buffer_dirty.
;
; Loop termination conditions:
;   - HL >= promoted_end → done (normal exit).
;   - gapbuf_insert returns CF=1 (buffer full) — indent path halts;
;     msg_file_too_large already surfaced by gapbuf_insert.
;   - motion_byte_at_logical past EOF after the per-line op +
;     advance — done.
;
; In:      HL = promoted_start, DE = promoted_end, A = mode
;          (0 = indent, 1 = dedent).
; Out:     buffer mutations applied; edits_indent_walk_dirty := 1 iff
;          at least one byte inserted/deleted.
;          cursor_offset = unspecified (caller restores).
; Trashes: A, BC, DE, HL, F.
; Calls:   gapbuf_insert (indent), gapbuf_delete (dedent),
;          motion_byte_at_logical (both), motion_find_line_end (advance).
; ----------------------------------------------------------------
edits_indent_walk:
    LD      (edits_indent_walk_mode), A
    XOR     A
    LD      (edits_indent_walk_dirty), A
.iw_step:
    ;; Done if HL >= DE.
    PUSH    HL
    OR      A
    SBC     HL, DE                      ; CF=1 iff HL < DE → keep going
    POP     HL
    RET     NC                          ; HL >= DE → done
    ;; Pre-stage cursor at line_start.
    LD      (cursor_offset), HL
    LD      A, (edits_indent_walk_mode)
    OR      A
    JR      NZ, .iw_dedent
    ;; INDENT: insert INDENT_BYTE at cursor.
    LD      A, INDENT_BYTE
    PUSH    DE
    CALL    gapbuf_insert               ; CF=1 on full; cursor advanced by 1 on success
    POP     DE
    RET     C                           ; full — halt walk; msg_file_too_large surfaced
    INC     DE                          ; promoted_end shifts by +1
    LD      A, 1
    LD      (edits_indent_walk_dirty), A
    JR      .iw_advance
.iw_dedent:
    ;; DEDENT: byte at cursor == INDENT_BYTE? If yes, delete; else skip.
    PUSH    DE
    CALL    motion_byte_at_logical      ; A = byte at HL; CF=1 if past EOF
    POP     DE
    RET     C                           ; past EOF (defensive)
    CP      INDENT_BYTE
    JR      NZ, .iw_advance             ; no leading INDENT_BYTE — silent skip
    ;; Cursor-bounce delete: position cursor at HL+1, gapbuf_delete consumes
    ;; byte at HL and returns cursor to HL.
    INC     HL
    LD      (cursor_offset), HL
    PUSH    DE
    CALL    gapbuf_delete
    POP     DE
    DEC     DE                          ; promoted_end shifts by -1
    LD      A, 1
    LD      (edits_indent_walk_dirty), A
.iw_advance:
    ;; Walk forward to next line_start: motion_find_line_end then INC.
    LD      HL, (cursor_offset)
    PUSH    DE
    CALL    motion_find_line_end        ; HL = LF pos or file_length
    POP     DE
    PUSH    HL
    PUSH    DE
    CALL    motion_byte_at_logical      ; CF=1 iff HL >= file_length
    POP     DE
    POP     HL
    RET     C                           ; past EOF — done
    INC     HL                          ; next line_start
    JR      .iw_step


;; ============================================================
;; --- Module-local scratch (Story 2.11 compose layer) ---
;; ============================================================
; Both cells written by edits_indent_walk. mode is set on entry from A;
; dirty is reset at entry and set by each successful insert/delete.
; Caller reads dirty to decide whether to invoke edits_dirty_and_redraw.
edits_indent_walk_mode:    DEFB 0
edits_indent_walk_dirty:   DEFB 0
