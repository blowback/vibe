; ============================================================
; Module: edits.asm
; Purpose: Buffer-edit primitives (FR24-FR27). Lands the a / o / O
;          entry handlers and the INSERT-mode literal-insert /
;          Backspace / Enter handlers in Story 2.8 — VIBE's first
;          true edit-and-save round-trip surface. FR13 (`i` enters
;          INSERT) stays wired to enter_insert_mode in dispatch.asm;
;          FR16 (Esc-to-NORMAL) stays on enter_normal_mode in
;          dispatch.asm — neither lives here. Sits between
;          motions.asm and exline.asm in the AR25 INCLUDE chain
;          (the long-planned slot per src/vibe.asm:140 comment +
;          architecture.md:945).
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
; Public:
;   edits_enter_insert_after  ; 'a' — advance cursor 0/1 per EOL rule, enter INSERT
;   edits_open_below          ; 'o' — reach EOL, insert LF, enter INSERT on new line below
;   edits_open_above          ; 'O' — reach BOL, insert LF, DEC cursor, enter INSERT on new line above
;   edits_insert_literal      ; INSERT-mode literal-byte insert (replaces 1.9 unbound_insert stub)
;   edits_insert_backspace    ; INSERT-mode Backspace (delete byte before cursor; silent at BOF)
;   edits_insert_newline      ; INSERT-mode Enter — translates 0x0D → 0x0A (AC10 explicit bind)
;
; State owned (read/write):
;   cursor_offset   ; the o / O / a handlers re-position the cursor;
;                     gapbuf_insert / gapbuf_delete advance/retreat
;                     it transitively. mode_byte is written via
;                     enter_insert_mode on success paths and via
;                     direct MODE_NORMAL write on the literal-insert
;                     overflow exit. buffer_dirty is set on every
;                     successful mutation path.
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
;          enter_insert_mode / enter_normal_mode transitively.
;
; Dependencies:
;   inc/state.inc    (cursor_offset, mode_byte, buffer_dirty —
;                     all written here; gap_start / gap_end —
;                     read transitively via motion_byte_at_logical)
;   inc/modes.inc    (MODE_NORMAL — written on edits_insert_literal /
;                     edits_insert_newline overflow exit)
;   src/gapbuf.asm   (gapbuf_insert, gapbuf_delete — the AR14
;                     mutation surface)
;   src/motions.asm  (motion_byte_at_logical, motion_find_line_start,
;                     motion_find_line_end — read primitives for
;                     EOL / EOF inspect and line-start / line-end
;                     positioning. All preserve BC; edits doesn't
;                     rely on that here since none of the edit
;                     handlers iterate a count.)
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
