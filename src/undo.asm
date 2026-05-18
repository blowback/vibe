; ============================================================
; Module: undo.asm
; Purpose: Single-level undo register and replay (FR45 / FR46).
;          Story 2.13 — the AR25-final production module per
;          architecture.md:945. Owns the SR-style undo register
;          (header + 256-byte payload at undo_buffer), the
;          shared record helpers invoked from every mutating
;          handler in src/edits.asm and from the INSERT-session
;          exit hooks in src/dispatch.asm + src/edits.asm, and
;          the `u` NORMAL-mode replay handler op_undo bound in
;          dispatch_normal.
;
;          Q6 pin (Ant — diverges from spec-recommended Q6 Option
;          C): full indent/dedent undo coverage via dedicated
;          UNDO_KIND_INDENT_WALK / UNDO_KIND_DEDENT_WALK kinds.
;          Replay reuses edits_indent_walk with the mode flipped
;          — indent undo dedents the post-walk range; dedent
;          undo indents the post-walk range. Documented vi-
;          divergence: dedent-undo of a line that had no leading
;          INDENT_BYTE pre-dedent (a no-op line in the original
;          walk) inserts an INDENT_BYTE on replay — visible as
;          one extra leading space. Recoverable with manual <<.
;
;          Q5 pin: buffer_dirty stays 1 after a successful undo
;          (no last-saved-state recompute — saves ~40-60 B).
;          Documented divergence from vi: undoing back to the
;          last-saved buffer state still leaves buffer_dirty
;          set; user can :w idempotently.
;
;          Q4 pin: UNDO_KIND_TOO_LARGE keeps its kind after the
;          msg_undo_too_large surface (a second `u` re-surfaces;
;          informative). Cleared only by the next mutation
;          (which writes a fresh entry).
;
;          Pure-memory module: AR13 clean (no BIOS_CONOUT — replay
;          dirties via edits_dirty_and_redraw → render_mark_all_dirty);
;          AR14 clean (replay mutates the gap buffer EXCLUSIVELY
;          via gapbuf_insert / gapbuf_delete primitives — no raw
;          gap_start / gap_end writes); AR15 clean (no BDOS).
;          All five AR sweep grep targets land zero matches.
;
; Public:
;   op_undo                    ; NORMAL-mode `u` handler (FR45 replay; bound in dispatch_normal)
;   undo_record_insert         ; record an inverse-delete entry (insert session, paste)
;   undo_record_delete         ; record an inverse-insert entry with saved bytes (x, dd, dw, indent)
;   undo_record_replace        ; record a composed delete+insert entry (cw two-phase upgrade)
;   undo_record_indent_walk    ; record an inverse-dedent-walk entry (>> / N>> / >+motion)
;   undo_record_dedent_walk    ; record an inverse-indent-walk entry (<< / N<< / <+motion)
;   undo_clear                 ; mark entry empty (post-replay; pre-mutation defensive)
;   undo_write_header          ; direct kind+position+length write (Story 3.6 promoted from
;                              ; internal helper to public — used by visual_apply_operator's
;                              ; VIS_BLOCK arm to record UNDO_KIND_TOO_LARGE directly,
;                              ; bypassing undo_record_delete's payload-copy path because
;                              ; the block delete is fundamentally non-contiguous and
;                              ; multi-region undo is deferred per Story 3.6 Q2 Option A)
;   undo_insert_exit_record    ; INSERT → NORMAL exit hook (enter_normal_mode + edits_overflow_to_normal)
;   insert_session_entry_cursor ; DEFW — entry cursor saved by enter_insert_mode for the exit hook
;
; State owned (read/write):
;   undo_kind (state.inc)      ; writer: all undo_record_* + undo_clear + op_undo (post-replay clear).
;                              ; reader: op_undo, undo_insert_exit_record.
;   undo_position (state.inc)  ; writer: all undo_record_*. reader: op_undo replay bodies + the
;                              ; exit-record upgrade path.
;   undo_length (state.inc)    ; writer: all undo_record_*. reader: op_undo replay bodies + the
;                              ; exit-record REPLACE upgrade.
;   undo_aux_length (state.inc); writer: undo_record_replace (set in upgrade path). reader:
;                              ; undo_replay_replace.
;   undo_buffer (state.inc:128); writer: undo_record_delete (bytes copied via motion_byte_at_logical
;                              ; loop on capacity-OK path). reader: undo_replay_delete +
;                              ; undo_replay_replace's phase 2.
;   insert_session_entry_cursor ; writer: enter_insert_mode patch. reader: undo_insert_exit_record.
;                              ; Module-local DEFW (NOT state.inc — same pattern as
;                              ; motions_compose_entry, edits_indent_walk_dirty, etc.).
;
; State read-only:
;   cursor_offset              ; read by undo_insert_exit_record (delta compute);
;                              ; written by replay bodies (set to undo_position post-replay).
;   mode_byte                  ; read by enter_normal_mode's guard (CP MODE_INSERT) BEFORE the
;                              ; mode write — the guard lives in enter_normal_mode itself, not here.
;
; Register conventions (across public entry points):
;   op_undo:
;       In:  A = 'u' (MC4; ignored — read undo_kind from state).
;       Out: success — undo entry replayed; cursor at undo_position;
;            buffer_dirty=1; all rows dirty; undo_kind=UNDO_KIND_EMPTY
;            (consumed); parser cleared.
;            empty / too-large — status surface; buffer + cursor +
;            buffer_dirty UNCHANGED; parser cleared.
;            overflow during replay (DELETE/REPLACE inverse-insert
;            hits gapbuf_insert CF=1; buffer at GAP_BUFFER_MAX) —
;            partial replay; status = msg_file_too_large (set by
;            gapbuf_insert); buffer_dirty=1; parser cleared.
;       Trashes: A, BC, DE, HL, F.
;       Calls: status_set_message (empty / too-large); edits_range_delete
;              (INSERT replay + REPLACE phase 1); gapbuf_insert (DELETE
;              + REPLACE phase 2); motion_byte_at_logical (transitively
;              via record_delete copy loop; not direct from op_undo);
;              edits_indent_walk (INDENT_WALK / DEDENT_WALK replay);
;              edits_dirty_and_redraw (success); undo_clear (success
;              tail); parser_clear (tail-JP every path).
;
;   undo_record_insert:
;       In:  HL = insertion-start logical offset; BC = bytes inserted.
;       Out: undo_kind=UNDO_KIND_INSERT; undo_position=HL; undo_length=BC.
;            BC == 0 → undo_kind=UNDO_KIND_EMPTY (defensive — caller
;            should guard the no-op path before calling).
;       Trashes: A, F.
;
;   undo_record_delete:
;       In:  HL = delete-start logical offset; BC = bytes that will be
;            removed by the upcoming mutation.
;       Out: On BC <= UNDO_PAYLOAD_SIZE:
;              undo_kind=UNDO_KIND_DELETE; undo_position=HL; undo_length=BC;
;              BC bytes copied from logical [HL, HL+BC) into undo_buffer.
;            On BC > UNDO_PAYLOAD_SIZE:
;              undo_kind=UNDO_KIND_TOO_LARGE; undo_position=HL;
;              undo_length=BC (recorded for diagnostics); NO bytes
;              copied (avoid partial-state).
;            On BC == 0 → undo_kind=UNDO_KIND_EMPTY (defensive).
;       Trashes: A, BC, DE, HL, F.
;       Calls: motion_byte_at_logical (source bytes may straddle the
;              gap; same per-byte loop shape as edits_copy_to_yank).
;
;   undo_record_replace:
;       In:  HL = op-start logical offset; BC = bytes-to-delete on
;            replay (the new-content range); DE = bytes-to-reinsert
;            on replay (the old-content range; must already be in
;            undo_buffer via a prior undo_record_delete call).
;       Out: On DE <= UNDO_PAYLOAD_SIZE:
;              undo_kind=UNDO_KIND_REPLACE; undo_position=HL;
;              undo_length=BC; undo_aux_length=DE.
;            On DE > UNDO_PAYLOAD_SIZE:
;              undo_kind=UNDO_KIND_TOO_LARGE (consistent surface);
;              other cells written for diagnostics.
;       Trashes: A, F. (HL, BC, DE all preserved-as-input — these
;              are written to state and not used further.)
;
;   undo_record_indent_walk / undo_record_dedent_walk:
;       In:  HL = promoted_start (pre-walk); BC = pre-walk range size
;            (DE - HL in the caller's edits_indent_walk parameters).
;       Out: undo_kind = UNDO_KIND_INDENT_WALK or UNDO_KIND_DEDENT_WALK;
;            undo_position=HL; undo_length=BC. No payload (replay
;            re-derives via edits_indent_walk with the mode flipped).
;       Trashes: A, F.
;
;   undo_clear:
;       In:  (none).
;       Out: undo_kind := UNDO_KIND_EMPTY. Other cells UNCHANGED
;            (they are by-construction unread on the EMPTY path).
;       Trashes: A, F.
;
;   undo_insert_exit_record:
;       In:  mode_byte = MODE_INSERT (caller-guarded); cursor_offset
;            = INSERT exit cursor; insert_session_entry_cursor =
;            INSERT entry cursor; undo_kind may be UNDO_KIND_EMPTY
;            (pure INSERT session) OR UNDO_KIND_DELETE (cw + motion
;            phase 1) OR UNDO_KIND_TOO_LARGE (defensive; phase 1
;            overflowed).
;       Out: Depending on undo_kind on entry and the cursor delta:
;            - kind=EMPTY (pure INSERT) + delta>0 → record INSERT.
;            - kind=EMPTY (pure INSERT) + delta<=0 → undo_clear
;              (Q2 Option A pin: net-deleted / net-zero INSERT
;              sessions are unrecoverable).
;            - kind=DELETE (cw+motion phase 1) + delta>0 → upgrade
;              to UNDO_KIND_REPLACE (Q3 Option A two-phase pin);
;              undo_length := new_len; undo_aux_length := old_len.
;            - kind=DELETE + delta<=0 → leave DELETE intact (the
;              original old-content restore still works for cw Esc
;              with 0 chars typed).
;            - kind=TOO_LARGE → leave intact (phase 1 overflowed;
;              REPLACE upgrade is impossible without the payload).
;       Trashes: A, BC, DE, HL, F.
;       Calls: undo_record_insert, undo_clear (both as tail-JPs
;              from the pure-INSERT arms).
;
; Dependencies:
;   inc/equates.inc    (UNDO_KIND_*, UNDO_PAYLOAD_SIZE, UNDO_BUFFER_SIZE,
;                       INDENT_BYTE indirectly via edits_indent_walk)
;   inc/state.inc      (undo_kind, undo_position, undo_length,
;                       undo_aux_length, undo_buffer, cursor_offset)
;   src/statusln.asm   (status_set_message, msg_undo_too_large,
;                       msg_nothing_to_undo — all pre-existing)
;   src/gapbuf.asm     (gapbuf_insert, gapbuf_delete — replay primitives)
;   src/motions.asm    (motion_byte_at_logical — source-byte read for
;                       record_delete payload copy)
;   src/edits.asm      (edits_range_delete — reused for INSERT replay
;                       + REPLACE phase 1; edits_indent_walk — reused
;                       for INDENT_WALK / DEDENT_WALK replay with mode
;                       flipped; edits_dirty_and_redraw — success tail)
;   src/parser.asm     (parser_clear — tail-JP from every op_undo path)
; ============================================================


;; ============================================================
;; --- Public entry: op_undo (FR45 / FR46 — NORMAL-mode `u`) ---
;; ============================================================

; ----------------------------------------------------------------
; op_undo
; NORMAL-mode `u`. Reads undo_kind and branches to the per-kind
; replay body (or surfaces msg_nothing_to_undo / msg_undo_too_large
; for the non-replayable kinds). Counts are ignored — a `5u` from
; the parser arrives the same way as bare `u`; parser_clear at the
; handler tail consumes any pending count_accumulator.
;
; Single-level: a successful replay calls undo_clear so a second `u`
; reports "nothing to undo" (Q4-via-AC5 cleared-after-consume pin
; per epic AC line 1467-1470). u-of-u Growth-tier (PRD §Undo).
;
; TOO_LARGE entries are NOT cleared by surfacing (Q4 Option A pin):
; a second `u` re-surfaces the same message — informative; user can
; mentally model "this entry is permanently unrecoverable until I
; do another edit".
;
; In:      A = 'u' (MC4; ignored).
; Out:     success — undo entry replayed; cursor at undo_position;
;          buffer_dirty=1; all rows dirty; undo_kind=UNDO_KIND_EMPTY;
;          parser cleared.
;          empty / too-large — status set; buffer + cursor +
;          buffer_dirty UNCHANGED; parser cleared.
; Trashes: A, BC, DE, HL, F.
; Calls:   status_set_message (empty / too-large surfaces);
;          undo_replay_insert / _delete / _replace / _indent_walk /
;          _dedent_walk (JP per kind);
;          parser_clear (tail-JP every path).
; ----------------------------------------------------------------
op_undo:
    LD      A, (undo_kind)
    CP      UNDO_KIND_INSERT
    JP      Z, undo_replay_insert
    CP      UNDO_KIND_DELETE
    JP      Z, undo_replay_delete
    CP      UNDO_KIND_REPLACE
    JP      Z, undo_replay_replace
    CP      UNDO_KIND_INDENT_WALK
    JP      Z, undo_replay_indent_walk
    CP      UNDO_KIND_DEDENT_WALK
    JP      Z, undo_replay_dedent_walk
    CP      UNDO_KIND_TOO_LARGE
    JR      Z, .too_large
    ;; UNDO_KIND_EMPTY (or any defensive other value) — nothing to undo.
    LD      HL, msg_nothing_to_undo
    JR      .surface
.too_large:
    LD      HL, msg_undo_too_large
.surface:
    XOR     A                           ; non-error-code arg (AR16)
    CALL    status_set_message
    JP      parser_clear


;; ============================================================
;; --- Internal helper: undo_replay_success_tail ---
;; ============================================================
; Shared tail for every successful replay path (INSERT / DELETE /
; REPLACE / INDENT_WALK / DEDENT_WALK). Sets cursor to undo_position
; (matches epic AC: "cursor returns to a sensible position, typically
; the operation's start offset"), clears the consumed entry, dirties
; the buffer + redraws, and tail-JPs parser_clear. ~9 B saved per
; replay body via the factor-out.
;
; In:      (entry from any replay body that completed without overflow
;          or with the partial-replay-acceptable-per-FR52 path).
; Out:     cursor_offset := undo_position; undo_kind := UNDO_KIND_EMPTY;
;          buffer_dirty := 1 (via edits_dirty_and_redraw); all rows
;          dirty; parser cleared.
; Trashes: A, BC, DE, HL, F.
; Calls:   undo_clear, edits_dirty_and_redraw, parser_clear (tail-JP).
; ----------------------------------------------------------------
undo_replay_success_tail:
    LD      HL, (undo_position)
    LD      (cursor_offset), HL
    CALL    undo_clear
    CALL    edits_dirty_and_redraw
    JP      parser_clear


;; ============================================================
;; --- Internal: undo_replay_insert (inverse of an INSERT entry) ---
;; ============================================================
; Inverse-op = DELETE undo_length bytes at undo_position. Reuses
; edits_range_delete (Story 2.10's cursor-bounce shape).
;
; In:      (state) undo_kind = UNDO_KIND_INSERT; undo_position;
;          undo_length.
; Out:     undo_length bytes removed from [undo_position,
;          undo_position+undo_length); cursor_offset := undo_position
;          (via undo_replay_success_tail).
; Trashes: A, BC, DE, HL, F.
; Calls:   edits_range_delete (cursor-bounce gapbuf_delete loop);
;          undo_replay_success_tail.
; ----------------------------------------------------------------
undo_replay_insert:
    LD      BC, (undo_length)
    LD      A, B
    OR      C
    JR      Z, undo_replay_success_tail ; defensive: 0-length (shouldn't happen)
    LD      HL, (undo_position)
    CALL    edits_range_delete          ; cursor := undo_position; bytes removed
    JR      undo_replay_success_tail


;; ============================================================
;; --- Internal: undo_replay_delete (inverse of a DELETE entry) ---
;; ============================================================
; Inverse-op = INSERT undo_length bytes from undo_buffer at
; undo_position. Per-byte gapbuf_insert loop; on overflow mid-loop,
; partial restore is accepted (FR52 — same shape as op_paste's
; partial-paste path; documented vi-divergence — vi's undo is
; infallible).
;
; Post-loop cursor: undo_replay_success_tail forces cursor to
; undo_position (overriding gapbuf_insert's per-byte advance) per
; AC6 "cursor returns to the operation's start".
;
; In:      (state) undo_kind = UNDO_KIND_DELETE; undo_position;
;          undo_length; undo_buffer holds the saved bytes.
; Out:     undo_length bytes inserted from undo_buffer starting at
;          undo_position. Partial on overflow.
; Trashes: A, BC, DE, HL, F.
; Calls:   gapbuf_insert (per-byte; CF=1 on full → partial).
; ----------------------------------------------------------------
undo_replay_delete:
    LD      HL, (undo_position)
    LD      (cursor_offset), HL
    LD      BC, (undo_length)
    LD      DE, undo_buffer
.loop:
    LD      A, B
    OR      C
    JR      Z, .done
    LD      A, (DE)                     ; A = next byte to restore
    PUSH    BC                          ; gapbuf_insert trashes BC
    PUSH    DE                          ; gapbuf_insert trashes DE
    CALL    gapbuf_insert
    POP     DE
    POP     BC
    JR      C, .done                    ; partial restore — accepted per FR52
    INC     DE
    DEC     BC
    JR      .loop
.done:
    JP      undo_replay_success_tail


;; ============================================================
;; --- Internal: undo_replay_replace (inverse of a REPLACE entry) -
;; ============================================================
; Inverse-op = (1) DELETE undo_length bytes at undo_position (the
; new-content range) + (2) INSERT undo_aux_length bytes from
; undo_buffer at undo_position (the old-content range).
;
; Phase 1 reuses edits_range_delete. Phase 2 is a per-byte
; gapbuf_insert loop (same shape as undo_replay_delete).
;
; In:      (state) undo_kind = UNDO_KIND_REPLACE; undo_position;
;          undo_length (new-content size); undo_aux_length (old-
;          content size); undo_buffer holds old-content bytes.
; Out:     New content removed; old content re-inserted; cursor :=
;          undo_position. Partial on overflow during phase 2.
; Trashes: A, BC, DE, HL, F.
; Calls:   edits_range_delete (phase 1); gapbuf_insert (phase 2 per-byte).
; ----------------------------------------------------------------
undo_replay_replace:
    ;; Phase 1: delete new-content bytes at undo_position.
    LD      BC, (undo_length)
    LD      A, B
    OR      C
    JR      Z, .skip_delete             ; defensive: 0 new bytes
    LD      HL, (undo_position)
    CALL    edits_range_delete          ; cursor := undo_position
.skip_delete:
    ;; Phase 2: re-insert undo_aux_length bytes from undo_buffer.
    LD      HL, (undo_position)
    LD      (cursor_offset), HL
    LD      BC, (undo_aux_length)
    LD      DE, undo_buffer
.loop:
    LD      A, B
    OR      C
    JR      Z, .done
    LD      A, (DE)
    PUSH    BC
    PUSH    DE
    CALL    gapbuf_insert
    POP     DE
    POP     BC
    JR      C, .done                    ; partial — accepted per FR52
    INC     DE
    DEC     BC
    JR      .loop
.done:
    JP      undo_replay_success_tail


;; ============================================================
;; --- Internal: undo_replay_indent_walk / _dedent_walk ---
;; ============================================================
; Q6 Option B replay bodies. Reuse edits_indent_walk with the mode
; FLIPPED — the indent-walk's inverse is a dedent over the same post-
; walk range; the dedent-walk's inverse is an indent. edits_indent_walk
; dynamically adjusts the DE bound as it walks (each insert shifts +1,
; each delete shifts -1), so passing the PRE-walk range is sufficient
; for the replay to cover the right lines.
;
; Documented vi-divergence (DEDENT_WALK undo): replay re-indents
; every line in the range, including lines that had NO leading
; INDENT_BYTE pre-dedent (no-op lines in the original walk). Those
; lines gain an extra leading space on undo. Recoverable with manual
; <<. Pinned in Story 2.13 Q6 Option B + deferred-work.md.
;
; In:      (state) undo_kind = UNDO_KIND_INDENT_WALK or _DEDENT_WALK;
;          undo_position = pre-walk promoted_start; undo_length =
;          pre-walk (promoted_end - promoted_start).
; Out:     edits_indent_walk applied with flipped mode; cursor :=
;          undo_position (via success tail).
; Trashes: A, BC, DE, HL, F.
; Calls:   edits_indent_walk (with A=1 for indent-undo / A=0 for
;          dedent-undo), undo_replay_success_tail.
; ----------------------------------------------------------------
undo_replay_indent_walk:
    LD      HL, (undo_position)
    LD      BC, (undo_length)
    ADD     HL, BC                      ; HL = promoted_end
    EX      DE, HL                      ; DE = promoted_end
    LD      HL, (undo_position)         ; HL = promoted_start
    LD      A, 1                        ; flipped: dedent mode
    CALL    edits_indent_walk
    JP      undo_replay_success_tail

undo_replay_dedent_walk:
    LD      HL, (undo_position)
    LD      BC, (undo_length)
    ADD     HL, BC
    EX      DE, HL
    LD      HL, (undo_position)
    XOR     A                           ; flipped: indent mode
    CALL    edits_indent_walk
    JP      undo_replay_success_tail


;; ============================================================
;; --- Public: undo_record_insert ---
;; ============================================================
undo_record_insert:
    ;; Defensive 0-byte guard: BC == 0 → record EMPTY.
    LD      A, B
    OR      C
    JR      Z, undo_clear
    LD      A, UNDO_KIND_INSERT
    JP      undo_write_header           ; tail-JP — writes kind/position/length


;; ============================================================
;; --- Public: undo_record_delete ---
;; ============================================================
; Capacity check; if within UNDO_PAYLOAD_SIZE, copy the bytes from
; logical [HL, HL+BC) into undo_buffer via motion_byte_at_logical
; (source may straddle the gap — same loop shape as edits_copy_to_yank).
; On over-capacity, write TOO_LARGE WITHOUT touching the payload
; (caller's mutation still proceeds; user finds out at u-time).
;
; In:      HL = delete-start; BC = bytes-to-delete.
; Out:     See module-header per-entry contract.
; Trashes: A, BC, DE, HL, F.
; Calls:   motion_byte_at_logical (per-byte; BC-preserving).
; ----------------------------------------------------------------
undo_record_delete:
    ;; 0-byte defensive guard.
    LD      A, B
    OR      C
    JR      Z, undo_clear

    ;; Capacity check: BC > UNDO_PAYLOAD_SIZE?
    ;; LD DE, UNDO_PAYLOAD_SIZE; SBC HL,DE / re-borrow: simpler via
    ;; HL=SIZE - BC carry test (same shape as edits_copy_to_yank).
    PUSH    HL                          ; [delete_start]
    PUSH    BC                          ; [delete_start][bytes]
    LD      HL, UNDO_PAYLOAD_SIZE
    OR      A
    SBC     HL, BC                      ; HL = SIZE - BC; CF=1 iff BC > SIZE
    POP     BC                          ; [delete_start]
    POP     HL                          ; ()
    JR      C, .too_large

    ;; Within capacity. Write header THEN copy bytes (header first
    ;; so a hypothetical halfway-failed copy still leaves a coherent
    ;; UNDO_KIND_DELETE entry — but the loop has no failure mode
    ;; since motion_byte_at_logical only fails past-EOF, and the
    ;; caller has already guaranteed HL+BC <= file_length).
    PUSH    HL                          ; [src]
    PUSH    BC                          ; [src][count]
    LD      A, UNDO_KIND_DELETE
    CALL    undo_write_header
    POP     BC                          ; [src]
    POP     HL                          ; ()
    ;; Copy BC bytes from logical HL to undo_buffer.
    LD      DE, undo_buffer
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
    RET

.too_large:
    ;; Record TOO_LARGE: header written; payload untouched (avoid partial).
    LD      A, UNDO_KIND_TOO_LARGE
    JP      undo_write_header           ; tail-JP


;; ============================================================
;; --- Public: undo_record_replace ---
;; ============================================================
; Caller-supplied (HL, BC, DE) where HL=position, BC=new-content len
; (to delete on replay), DE=old-content len (must already be in
; undo_buffer via a prior undo_record_delete call). Capacity check
; is against DE (the payload size).
;
; State-discipline: caller MUST have called undo_record_delete with
; (HL=position, BC=DE bytes) BEFORE the c+motion's range-delete
; mutation, so the payload bytes are already in undo_buffer. We
; just upgrade the header kind + write the aux_length cell.
;
; In:      HL = op-start; BC = new-content bytes; DE = old-content bytes.
; Out:     See module-header per-entry contract.
; Trashes: A, F. (HL, BC, DE preserved — they are written to state and
;          not used further.)
; ----------------------------------------------------------------
undo_record_replace:
    ;; Capacity check on DE.
    PUSH    HL                          ; [pos]
    PUSH    BC                          ; [pos][new_len]
    PUSH    DE                          ; [pos][new_len][old_len]
    LD      HL, UNDO_PAYLOAD_SIZE
    OR      A
    SBC     HL, DE
    POP     DE                          ; [pos][new_len]
    POP     BC                          ; [pos]
    POP     HL                          ; ()
    JR      C, .too_large

    ;; Write aux_length first (so a header-write-then-aux ordering
    ;; doesn't briefly expose a stale aux on a partial). Doesn't
    ;; matter for single-threaded code but keeps the contract clean.
    LD      (undo_aux_length), DE
    LD      A, UNDO_KIND_REPLACE
    JP      undo_write_header           ; tail-JP — writes kind/position/length

.too_large:
    LD      A, UNDO_KIND_TOO_LARGE
    JP      undo_write_header


;; ============================================================
;; --- Public: undo_record_indent_walk / _dedent_walk ---
;; ============================================================
; Q6 Option B record helpers. The payload is just (start, length) —
; no per-line capture (replay re-derives via edits_indent_walk).
; No capacity check needed (we don't touch undo_buffer).
;
; Callers (op_compose_indent / op_compose_dedent / op_indent_line /
; op_dedent_line) pre-clear via undo_clear, then call this AFTER
; edits_indent_walk if edits_indent_walk_dirty==1 (no record on
; no-op walks).
;
; In:      HL = pre-walk promoted_start; BC = pre-walk range size
;          (promoted_end - promoted_start).
; Out:     undo_kind = INDENT_WALK or DEDENT_WALK; position=HL;
;          length=BC.
; Trashes: A, F.
; ----------------------------------------------------------------
undo_record_indent_walk:
    LD      A, UNDO_KIND_INDENT_WALK
    JP      undo_write_header

undo_record_dedent_walk:
    LD      A, UNDO_KIND_DEDENT_WALK
    JP      undo_write_header


;; ============================================================
;; --- Public: undo_clear ---
;; ============================================================
; Mark the undo entry empty. Other cells left as-is (cheaper than
; full zero-fill; reads on the EMPTY path are by-construction
; skipped — op_undo's kind dispatch branches at the kind read).
;
; In:      (none).
; Out:     undo_kind := UNDO_KIND_EMPTY.
; Trashes: A, F.
; ----------------------------------------------------------------
undo_clear:
    XOR     A                           ; UNDO_KIND_EMPTY = 0x00
    LD      (undo_kind), A
    RET


;; ============================================================
;; --- Public: undo_write_header (shared per Q1 Option D) ---
;; ============================================================
; Shared 11-byte body that writes the 5-byte header trio (kind,
; position, length). Called from every undo_record_* helper, plus
; Story 3.6's visual_apply_operator VIS_BLOCK arm which uses it
; to record UNDO_KIND_TOO_LARGE directly without a payload copy
; (multi-region block-delete undo is deferred per Q2 Option A;
; logged in deferred-work.md as a future polish story).
; Saves ~6 B per call site vs inlining the 3 LD-to-memory writes
; (3-byte CALL + RET-via-tail-JP, helper body amortised across 7+
; callers post-Story-3.6).
;
; In:      A = kind; HL = position; BC = length.
; Out:     undo_kind := A; undo_position := HL; undo_length := BC.
; Trashes: A, F. (HL preserved; BC preserved via the LD H,B / LD L,C
;          shuffle — actually clobbered. Caller-supplied HL is
;          consumed during the position write; not used downstream.)
; ----------------------------------------------------------------
undo_write_header:
    LD      (undo_kind), A
    LD      (undo_position), HL
    LD      H, B
    LD      L, C
    LD      (undo_length), HL
    RET


;; ============================================================
;; --- Public: undo_insert_exit_record (INSERT → NORMAL exit hook) -
;; ============================================================
; Called from enter_normal_mode (via CALL Z guarded on mode_byte ==
; MODE_INSERT) AND from edits_overflow_to_normal (unconditional —
; mode_byte is definitely MODE_INSERT on that path). Closes the
; B2 insert-session-as-a-single-undo-entry invariant.
;
; Three on-entry cases (kind/delta interaction — Q3 Option A two-
; phase REPLACE upgrade per dev pin):
;
; A. kind == EMPTY (pure INSERT session — i/a/o/O entry):
;    - delta > 0 (net-inserted): record UNDO_KIND_INSERT with
;      (insert_session_entry_cursor, delta).
;    - delta <= 0 (net-deleted via Backspace OR net-zero):
;      undo_clear (Q2 Option A pin — documented vi-divergence;
;      user loses 'undo my Backspaces'; simpler than capturing
;      pre-INSERT bytes at session entry).
;
; B. kind == DELETE (c+motion phase 1 happened pre-INSERT):
;    - delta > 0 (user typed new content): UPGRADE to REPLACE.
;      undo_kind := UNDO_KIND_REPLACE; undo_position unchanged
;      (= range_start = entry_cursor for cw); undo_aux_length :=
;      original undo_length (the old-content byte count); undo_length
;      := delta (the new-content byte count). Payload bytes (old
;      content) already in undo_buffer from phase 1's
;      undo_record_delete.
;    - delta <= 0 (cw Esc with 0 chars typed, OR weird net-deleted
;      session in cw context): leave DELETE intact. `u` restores
;      the original content (the cw deletion). Correct.
;
; C. kind == TOO_LARGE (c+motion phase 1 overflowed):
;    - Leave intact. REPLACE upgrade would be wrong (no payload
;      bytes saved for the old content). `u` will report
;      msg_undo_too_large — matches the original phase-1 record
;      semantic.
;
; Defensive: any other kind on entry (INSERT / REPLACE / INDENT_WALK
; / DEDENT_WALK) — shouldn't happen since we just exited INSERT —
; leave intact.
;
; In:      (state) mode_byte = MODE_INSERT (caller-guarded);
;          cursor_offset = INSERT exit cursor; insert_session_entry_cursor
;          = INSERT entry cursor; undo_kind on entry per above.
; Out:     See per-case description.
; Trashes: A, BC, DE, HL, F.
; Calls:   undo_record_insert (case A delta>0), undo_clear (case A
;          delta<=0), undo_write_header (case B upgrade).
; ----------------------------------------------------------------
undo_insert_exit_record:
    LD      A, (undo_kind)
    CP      UNDO_KIND_DELETE
    JR      Z, .from_delete
    CP      UNDO_KIND_TOO_LARGE
    RET     Z                           ; case C — leave intact
    ;; Other kinds (EMPTY canonical; INSERT/REPLACE/WALK defensive):
    ;; treat as case A (pure INSERT session — clear or record).
    JR      .pure_insert

.from_delete:
    ;; Case B: cw + motion phase 1. Compute delta.
    LD      HL, (cursor_offset)
    LD      DE, (insert_session_entry_cursor)
    OR      A
    SBC     HL, DE                      ; HL = delta; CF=1 iff cursor < entry
    RET     C                           ; net-deleted — keep DELETE intact
    LD      A, H
    OR      L
    RET     Z                           ; net-zero (cw Esc) — keep DELETE intact
    ;; Net > 0: upgrade DELETE → REPLACE.
    ;; New layout: kind=REPLACE; position UNCHANGED; length=new_len(=delta);
    ;;             aux_length=old_len(=original undo_length).
    PUSH    HL                          ; [delta]
    LD      HL, (undo_length)
    LD      (undo_aux_length), HL       ; aux := original old-content len
    POP     HL                          ; HL = delta (new-content len)
    LD      (undo_length), HL
    LD      A, UNDO_KIND_REPLACE
    LD      (undo_kind), A
    RET

.pure_insert:
    ;; Case A: pure INSERT session. Compute delta; branch on sign.
    LD      HL, (cursor_offset)
    LD      DE, (insert_session_entry_cursor)
    OR      A
    SBC     HL, DE                      ; HL = delta
    JR      C, undo_clear               ; net-deleted (Q2 Option A) → clear
    LD      A, H
    OR      L
    JR      Z, undo_clear               ; net-zero — also clear
    ;; Net > 0: record INSERT with (entry_cursor, delta).
    LD      B, H
    LD      C, L                        ; BC = delta = bytes inserted
    LD      HL, (insert_session_entry_cursor)
    JP      undo_record_insert          ; tail-JP


;; ============================================================
;; --- Module-local state cells ---
;; ============================================================
; insert_session_entry_cursor — saved at enter_insert_mode entry
; (BEFORE the mode write), consumed by undo_insert_exit_record's
; delta compute. Module-local DEFW (not state.inc) — same pattern
; as motions_compose_entry (motions.asm), edits_indent_walk_dirty
; / _mode (edits.asm). Cold-start init: this cell is NOT inside
; the static_data block, so init_cold_start's LDIR fill does NOT
; zero it. That's OK because:
;   - enter_insert_mode ALWAYS writes it before any INSERT session.
;   - The exit hook only reads it AFTER an INSERT session (which
;     wrote it via the entry hook).
; A user-visible read-before-write of this cell would require
; pressing Esc-from-NORMAL (which currently no-ops the CP MODE_INSERT
; guard in enter_normal_mode → no call to the exit hook → no read
; of this cell).
insert_session_entry_cursor:    DEFW 0
