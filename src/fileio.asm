; ============================================================
; Module: fileio.asm
; Purpose: FCB-based file load AND save over the CP/M 2.2 BDOS
;          surface (FR4 / FR5 / FR6 / FR7 / FR9 / FR10 / FR11 /
;          FR51 / FR52). Story 2.2 landed the first production
;          caller of the BDOS_CALL macro for the load side:
;          BDOS_OPEN (15) / BDOS_SET_DMA (26) / BDOS_READ_SEQ (20)
;          / BDOS_CLOSE (16). Story 2.4 lands the save side:
;          fileio_save orchestrates BDOS_DELETE (19) / BDOS_MAKE
;          (22) / BDOS_WRITE_SEQ (21) / BDOS_CLOSE with a second
;          AR15 carve-out for the benign DELETE-of-nonexistent
;          file. Owns the canonical FCB scratch and the dynamic
;          status-string composition for "can't open FILENAME",
;          "can't write FILENAME", "FILENAME N bytes",
;          "FILENAME N bytes written", and "FILENAME [new file]".
;
;          Entry surface for the ex-line (full post-2.4 shape):
;              cmd_edit / cmd_edit_force   (in src/exline.asm)
;                      |
;                      v
;              fileio_load -> fileio_load_after_open (shared body)
;              fileio_load_initial (Story 2.3 — launch path)
;                      |
;                      v
;              BDOS_OPEN -> SET_DMA -> READ_SEQ loop -> CLOSE
;
;              cmd_write / cmd_write_quit   (in src/exline.asm — Story 2.4)
;                      |
;                      v
;              fileio_save
;                      |
;                      v
;              BDOS_SET_DMA -> BDOS_SEARCH_FIRST (R/O pre-check) ->
;              BDOS_DELETE -> BDOS_MAKE -> BDOS_WRITE_SEQ loop ->
;              BDOS_CLOSE
;
;          Architectural enforcement here:
;            AR12 — every status-row write enters through
;                   status_set_message. Both the success banner
;                   ("FILENAME N bytes") and the open-fail banner
;                   ("can't open FILENAME") are composed in a
;                   file-local 48-byte scratch and handed to
;                   the funnel via HL; the failure path additionally
;                   pre-stages the scratch pointer in
;                   `bdos_error_pre_msg` so the BDOS error funnel
;                   surfaces the context-rich message rather than
;                   its generic msg_bdos_error default.
;            AR13 — zero BIOS_CONOUT call sites. The load's screen
;                   update flows: fileio_load -> render_mark_all_dirty
;                   (sets dirty_rows to all-ones) -> render_diff
;                   (next input-loop iteration) emits every editable
;                   row from the now-loaded gap buffer.
;            AR14 — single buffer-mutation owner is gapbuf.asm.
;                   *CARVE-OUT documented here:* fileio_load writes
;                   `gap_start` directly during the linear-fill
;                   read loop (per sector: LDIR into [gap_start,
;                   gap_start + N); advance gap_start by N). Through
;                   this entire phase SR2's two-halves invariant
;                   holds — content lives in [GAP_BUFFER_BASE,
;                   gap_start), the after-gap region is unused,
;                   cursor_offset is 0. The final `gapbuf_move_gap`
;                   with HL = 0 returns us to gapbuf's invariant-
;                   maintaining surface; SR2 holds at every step.
;                   Alternative design (a `gapbuf_bulk_append`
;                   primitive that hides the writes) is deferred —
;                   the carve-out is 50 bytes smaller and one
;                   CALL per sector cheaper, and the SR2 walk-through
;                   above shows the seam is harmless.
;            AR15 — every BDOS call in this module uses the
;                   BDOS_CALL macro EXCEPT THREE documented carve-outs:
;
;                   (1) LAUNCH CARVE-OUT (Story 2.3):
;                   `fileio_load_initial`'s BDOS_OPEN is inlined
;                   (LD C / CALL BDOS_ENTRY / OR A / JP M) so the
;                   bdos_error_funnel's terminal JP-to-input_loop
;                   does NOT fire on open-fail. The launch path
;                   needs to surface a "[new file]" banner and RET
;                   back to init_cold_start so Stages 6/7
;                   (render_full + fall-through to input_loop)
;                   complete; the funnel would skip those stages.
;
;                   (2) SAVE-PRECHECK CARVE-OUT (Story 2.4 hardware
;                   UAT step 12 fix): `fileio_save`'s Step 0 BDOS_
;                   SEARCH_FIRST is inlined so the funnel does NOT
;                   falsely surface "can't write FILENAME" on the
;                   0xFF "no matching R/O entry" return — the
;                   NORMAL case for any save target that is R/W
;                   or not-yet-on-disk. The pre-check exists
;                   because CP/M 2.2 BDOS warm-boots on R/O-file
;                   writes BEFORE the caller sees the failure;
;                   without this carve-out we'd lose unsaved data
;                   to BDOS's intercept on the subsequent WRITE_SEQ.
;
;                   (3) SAVE CARVE-OUT (Story 2.4):
;                   `fileio_save`'s BDOS_DELETE is inlined (LD C /
;                   CALL BDOS_ENTRY; A return code discarded) so
;                   the funnel does NOT falsely surface "can't
;                   write FILENAME" on the 0xFF return that simply
;                   means "no prior file to delete" — the NORMAL
;                   first-save case for a not-yet-on-disk filename.
;                   The DELETE's only purpose is to clear any stale
;                   directory entry of the same name before MAKE;
;                   either return code (0..3 = deleted, 0xFF = no
;                   matching file) lets MAKE proceed.
;
;                   All three carve-outs are single-site,
;                   inline-annotated (`; AR15 launch carve-out` /
;                   `; AR15 save-precheck carve-out` / `; AR15
;                   save carve-out`), and otherwise byte-identical
;                   to the macro expansion. The macro's `JP M`
;                   still catches sign-bit returns at every other
;                   site; positive failure codes (BDOS_READ_SEQ
;                   A >= 2; BDOS_WRITE_SEQ A = 1..127 = disk-full
;                   / extent-exhausted class) have bit 7 clear
;                   and are inspected per-call by the caller.
;            AR16 — message strings are lowercase, no trailing
;                   period. The dynamic "FILENAME N bytes" includes
;                   the uppercase-stored filename — AR16's "all
;                   lowercase" rule applies to fixed message text;
;                   filenames pass through as the FCB stores them
;                   (CP/M-canonical uppercase).
;
; Public:
;   fileio_load                 ; HL = filename ptr, A = length
;                               ; (1..63). Refills the gap buffer
;                               ; from a BDOS-opened FCB. Caller
;                               ; (cmd_edit / cmd_edit_force) has
;                               ; already enforced the dirty-buffer
;                               ; policy and stripped leading
;                               ; spaces; this entry assumes the
;                               ; filename text is the head of a
;                               ; valid non-empty run.
;   fileio_load_initial         ; Story 2.3 — launch-with-filename
;                               ; entry called from init_cold_start
;                               ; Stage 5. Reads CCP-populated
;                               ; DEFAULT_FCB (0x005C); no-arg
;                               ; (basename[0]==' ') short-circuits
;                               ; to msg_mode_normal; non-empty
;                               ; runs the load via fileio_load_after_open
;                               ; (shared post-open body) on open
;                               ; success, OR composes "FILENAME
;                               ; [new file]" with filename_buffer
;                               ; PRESERVED on open fail. RET on
;                               ; every terminal path (no funnel
;                               ; routing — see AR15 carve-out).
;   fileio_save                 ; Story 2.4 — serialise the gap-buffer
;                               ; payload to disk through DELETE /
;                               ; MAKE / SET_DMA / WRITE_SEQ-loop /
;                               ; CLOSE. RET on success with
;                               ; buffer_dirty cleared and the
;                               ; "<FILENAME> N bytes written" banner
;                               ; emitted; failure routes the funnel
;                               ; with the pre-staged "can't write
;                               ; FILENAME" banner — never returns.
;                               ; fcb_scratch + filename_buffer must
;                               ; be populated by the caller
;                               ; (cmd_write / cmd_write_quit
;                               ; re-parse filename_buffer through
;                               ; fileio_parse_filename for state-
;                               ; decoupled FCB construction).
;   fileio_strip_leading_spaces ; HL = ptr, A = length -> HL' =
;                               ; first non-space, A' = remaining
;                               ; length. Used by cmd_edit /
;                               ; cmd_edit_force / cmd_write /
;                               ; cmd_write_quit before passing
;                               ; the arg region down here.
;
; State owned (read/write):
;   fcb_scratch                 ; 36-byte CP/M 2.2 FCB. Reset to
;                               ; zero at every fileio_load entry;
;                               ; drive + basename + extension
;                               ; overwritten by parse_filename.
;                               ; Story 2.4 cmd_write / cmd_write_quit
;                               ; re-parse filename_buffer through
;                               ; parse_filename to rebuild fcb_scratch
;                               ; for the save (state-decoupled from
;                               ; the prior load's :e history).
;   fileio_status_scratch       ; 48-byte holding area for the
;                               ; dynamic status strings.
;   fileio_dec_dest             ; 2-byte scratch for u16_to_dec
;                               ; output-pointer marshalling.
;   fileio_write_count          ; Story 2.4 — 2-byte total payload
;                               ; cached at fileio_save Step 5,
;                               ; consumed at Step 11 to seed
;                               ; fileio_compose_written_status.
;   fileio_save_dma_ptr         ; Story 2.4 — 2-byte DMA write
;                               ; pointer threaded through the
;                               ; gap-walk and EOF-pad phases.
;   fileio_save_dma_remain      ; Story 2.4 — 1-byte slot count
;                               ; (1..128) of free DMA space.
;   gap_start                   ; AR14 CARVE-OUT — written during
;                               ; the linear-fill read loop only.
;                               ; All other writes go through
;                               ; gapbuf.asm's primitives. Story 2.4
;                               ; fileio_save is READ-ONLY against
;                               ; the gap regions — no new AR14
;                               ; carve-out needed.
;   bdos_error_pre_msg          ; module-local in statusln.asm.
;                               ; TWO writer sites in this module:
;                               ; (1) fileio_load Step 3 — pre-stages
;                               ; "can't open FILENAME"; cleared at
;                               ; Step 5 after success.
;                               ; (2) fileio_save Step 1 — pre-stages
;                               ; "can't write FILENAME"; cleared at
;                               ; Step 9 after the full MAKE / WRITE_SEQ
;                               ; loop / CLOSE sequence succeeds.
;                               ; The funnel zeroes the cell post-emit
;                               ; on any failure path so a stale value
;                               ; cannot leak across unrelated errors.
;   filename_buffer             ; written by fileio_parse_filename
;                               ; (canonical display name);
;                               ; read by compose helpers;
;                               ; zeroed (byte 0) by the abort
;                               ; paths so :w refuses post-abort.
;
; State read-only:
;   gap_end                     ; read by the budget check.
;
; Register conventions (across public entry points):
;   fileio_load:                 In:  HL = filename ptr (within
;                                     ex_buffer), A = length 1..63
;                                Out: gap buffer populated; cursor
;                                     at 0; filename_buffer
;                                     populated; status row reflects
;                                     load outcome. RET on every
;                                     terminal path (success / oversize
;                                     / read-error). The open-fail
;                                     path does NOT RET — the BDOS
;                                     funnel takes control to
;                                     input_loop after surfacing the
;                                     pre-staged "can't open" banner.
;                                Trashes: A, BC, DE, HL, F.
;                                Calls: gapbuf_init, gapbuf_move_gap,
;                                     status_set_message,
;                                     render_mark_all_dirty,
;                                     BDOS_CALL (BDOS_OPEN /
;                                     BDOS_SET_DMA / BDOS_READ_SEQ /
;                                     BDOS_CLOSE).
;
;   fileio_strip_leading_spaces: In:  HL = ptr, A = length
;                                Out: HL = first non-space ptr,
;                                     A = remaining length
;                                Trashes: B, F.
;
;   fileio_load_initial:         In:  (none — reads DEFAULT_FCB)
;                                Out: One of four terminal states:
;                                     no-arg (msg_mode_normal seeded,
;                                     filename_buffer untouched),
;                                     load-success (status =
;                                     "FILENAME N bytes"; cursor=0),
;                                     new-file (status = "FILENAME
;                                     [new file]"; filename_buffer
;                                     PRESERVED; buffer empty), or
;                                     too-large / read-error (filename
;                                     CLEARED; buffer empty). RET on
;                                     every path.
;                                Trashes: A, BC, DE, HL, F.
;                                Calls: fileio_setup_from_default_fcb,
;                                     gapbuf_init, BDOS_ENTRY (inline
;                                     AR15 launch carve-out),
;                                     fileio_load_after_open (fall-
;                                     through on open success),
;                                     fileio_compose_new_file_status,
;                                     render_mark_all_dirty,
;                                     status_set_message.
;
;   fileio_save:                 In:  fcb_scratch populated (drive +
;                                     basename + ext at +0..+11; zeros
;                                     +12..+35); filename_buffer
;                                     populated (NUL-terminated; first
;                                     byte != 0); gap_start / gap_end
;                                     defining the payload halves.
;                                Out: Success: file written; buffer_dirty
;                                     = 0; gap state unchanged; status =
;                                     "FILENAME N bytes written"; RET.
;                                     R/O refusal (Step 0 pre-check
;                                     detects R/O target): status =
;                                     "can't write FILENAME"; gap +
;                                     buffer_dirty preserved (FR52); RET.
;                                     Failure (MAKE / WRITE_SEQ /
;                                     CLOSE): no return — funnel
;                                     surfaces "can't write FILENAME"
;                                     and JPs to input_loop;
;                                     buffer_dirty stays nonzero (FR52).
;                                Trashes: A, BC, DE, HL, F.
;                                Calls: fileio_compose_cant_write,
;                                     BDOS_ENTRY (inline AR15 save-
;                                     precheck carve-out for SEARCH_FIRST;
;                                     inline AR15 save carve-out for
;                                     DELETE), BDOS_CALL (SET_DMA / MAKE
;                                     / WRITE_SEQ / CLOSE),
;                                     fileio_save_walk_bytes,
;                                     fileio_save_flush_sector,
;                                     fileio_compose_written_status,
;                                     status_set_message.
;
; Dependencies:
;   inc/equates.inc  (GAP_BUFFER_MAX)
;   inc/bios.inc     (DEFAULT_DMA; DEFAULT_FCB — Story 2.3 launch path;
;                     BDOS_ENTRY — Story 2.3 launch AR15 carve-out +
;                     Story 2.4 save AR15 carve-out)
;   inc/bdos.inc     (BDOS_CALL, BDOS_OPEN, BDOS_SET_DMA,
;                     BDOS_READ_SEQ, BDOS_CLOSE; Story 2.4 adds
;                     BDOS_DELETE, BDOS_MAKE, BDOS_WRITE_SEQ,
;                     BDOS_SEARCH_FIRST — the last for fileio_save's
;                     Step 0 R/O pre-check)
;   inc/state.inc    (gap_start, gap_end, cursor_offset,
;                     buffer_dirty, filename_buffer)
;   src/gapbuf.asm   (gapbuf_init, gapbuf_move_gap)
;   src/render.asm   (render_mark_all_dirty)
;   src/statusln.asm (status_set_message, msg_file_too_large,
;                     msg_read_error, msg_mode_normal;
;                     bdos_error_pre_msg override + bdos_error_funnel)
; ============================================================

;; ============================================================
;; --- Public entry: fileio_load ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_load
; Orchestrates the file load. See AC5 in the story spec for the
; numbered step list this routine pins. Caller has already
; stripped leading spaces and verified A > 0.
;
; In:      HL = filename ptr, A = length (1..63).
; Out:     RET on success / oversize / read-error. Open-fail path
;          never returns (BDOS funnel takes over).
; Trashes: A, BC, DE, HL, F.
; Calls:   fileio_parse_filename, gapbuf_init, fileio_compose_cant_open,
;          BDOS_CALL (OPEN / SET_DMA / READ_SEQ / CLOSE),
;          fileio_abort_too_large, fileio_abort_read_error,
;          gapbuf_move_gap, render_mark_all_dirty,
;          fileio_compose_loaded_status, status_set_message.
; ----------------------------------------------------------------
fileio_load:
    ;; Step 1: parse filename into fcb_scratch + filename_buffer.
    CALL    fileio_parse_filename

    ;; Step 2: reset gap buffer to empty (FR11 invariant: buffer
    ;; presented is consistent on failure — by the time we read
    ;; the first sector, the prior content is unconditionally gone).
    CALL    gapbuf_init

    ;; Step 3: pre-stage the "can't open FILENAME" banner in
    ;; case BDOS_OPEN fails into the funnel. statusln's funnel
    ;; reads `bdos_error_pre_msg` and uses it in place of
    ;; msg_bdos_error.
    CALL    fileio_compose_cant_open
    LD      HL, fileio_status_scratch
    LD      (bdos_error_pre_msg), HL

    ;; Step 4: BDOS_OPEN. On 0xFF the macro JPs the funnel which
    ;; surfaces our pre-staged banner and never returns here.
    LD      DE, fcb_scratch
    BDOS_CALL BDOS_OPEN

    ;; Step 5: open succeeded (A = 0..3). Clear the override so a
    ;; subsequent unrelated BDOS error doesn't inherit our stale
    ;; "can't open" pointer.
    LD      HL, 0
    LD      (bdos_error_pre_msg), HL

    ;; Fall through to fileio_load_after_open — shared with
    ;; fileio_load_initial (Story 2.3). Both open paths converge
    ;; here once the OPEN has succeeded (A = 0..3); the body
    ;; below is the load's Steps 6-12.

;; ----------------------------------------------------------------
; fileio_load_after_open
; Shared post-open body — runs the read loop, post-load gap shift,
; cursor/dirty reset, and status emit. Reached by FALL-THROUGH
; (no JR / no CALL) from two upstream open paths:
;   - fileio_load        (Story 2.2 — :e via the BDOS_CALL macro +
;                         bdos_error_pre_msg funnel routing on fail)
;   - fileio_load_initial (Story 2.3 — vibe FILENAME launch via the
;                         AR15 launch carve-out's inline open)
;
; Behavioural-equivalence guarantee: this block is byte-identical
; in observable post-state to Story 2.2's original Steps 6-12. The
; existing Story-2.2 tests (fileio_load-*, fileio_e-*) are the
; regression net.
;
; In:      A = 0..3 (the BDOS_OPEN success result; not inspected here).
;          fcb_scratch populated with the FCB the open succeeded on.
;          filename_buffer populated with the canonical display form.
;          gap buffer at SR2-empty (the caller has CALLed gapbuf_init).
; Out:     gap buffer holds the loaded content; cursor_offset = 0;
;          buffer_dirty = 0; all editable rows marked dirty;
;          status row = "<FILENAME> N bytes". RET unwinds to the
;          caller's caller (cmd_edit / init_cold_start, etc.).
; Trashes: A, BC, DE, HL, F.
; Calls:   BDOS_CALL (SET_DMA / READ_SEQ / CLOSE), fileio_ingest_sector,
;          gapbuf_move_gap, render_mark_all_dirty,
;          fileio_compose_loaded_status, status_set_message,
;          fileio_abort_too_large, fileio_abort_read_error.
; ----------------------------------------------------------------
fileio_load_after_open:
    ;; Step 6: defensive DMA reset to CP/M default 0x0080. CCP
    ;; loads .com files with DMA at 0x0080; we re-set in case a
    ;; future story's :w path has shifted it.
    LD      DE, DEFAULT_DMA
    BDOS_CALL BDOS_SET_DMA

    ;; Step 7: read loop. The byte-count tally is derived from
    ;; gap_start at post-load time (gap_start - GAP_BUFFER_BASE),
    ;; captured BEFORE gapbuf_move_gap(0) rearranges the halves.
.read_loop:
    ;; Pre-read budget check: (gap_end - gap_start) >= 128?
    LD      HL, (gap_end)
    LD      DE, (gap_start)
    OR      A
    SBC     HL, DE                  ; HL = free bytes in gap
    LD      DE, 128
    OR      A
    SBC     HL, DE                  ; HL = free - 128
    JR      C, .abort_too_large     ; free < 128 -> oversize

    LD      DE, fcb_scratch
    BDOS_CALL BDOS_READ_SEQ
    OR      A
    JR      Z, .got_sector          ; A = 0 -> success
    CP      1
    JR      Z, .post_load           ; A = 1 -> EOF (clean stop)
    JR      .abort_read_error       ; A >= 2 -> read error

.got_sector:
    CALL    fileio_ingest_sector    ; CF=1 if 0x1A found in sector
    JR      C, .post_load
    JR      .read_loop

.abort_too_large:
    JP      fileio_abort_too_large          ; tail-JP (status_set_message's RET goes to fileio_load's caller)

.abort_read_error:
    JP      fileio_abort_read_error

.post_load:
    ;; Capture loaded byte count = gap_start - GAP_BUFFER_BASE
    ;; BEFORE gapbuf_move_gap rearranges the halves.
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE
    PUSH    HL                              ; save count on stack

    ;; Step 8: close the file.
    LD      DE, fcb_scratch
    BDOS_CALL BDOS_CLOSE

    ;; Step 9: gapbuf_move_gap(0) -> flip loaded bytes from
    ;; before-gap to after-gap; gap moves to offset 0; SR2 holds.
    LD      HL, 0
    CALL    gapbuf_move_gap

    ;; Step 10: post-load state.
    LD      HL, 0
    LD      (cursor_offset), HL
    XOR     A
    LD      (buffer_dirty), A

    ;; Step 11: mark every editable row dirty so render_diff repaints.
    CALL    render_mark_all_dirty

    ;; Step 12: compose + emit success banner.
    POP     BC                              ; BC = byte count
    CALL    fileio_compose_loaded_status    ; HL = scratch
    XOR     A                               ; non-error code (AR16)
    CALL    status_set_message
    RET


;; ============================================================
;; --- Public entry: fileio_save (Story 2.4) ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_save
; Story 2.4: serialise the gap-buffer contents to disk through
; BDOS_DELETE -> BDOS_MAKE -> BDOS_SET_DMA -> BDOS_WRITE_SEQ-loop
; -> BDOS_CLOSE. The walk visits the two gap halves in logical
; order (before-gap then after-gap) byte-by-byte into the 128-byte
; DMA buffer at DEFAULT_DMA, flushing one sector per fill. A
; trailing EOF sector containing 0x1A + spaces ALWAYS terminates
; the file — including the 0-byte empty-buffer case (one sector
; of 0x1A + 127 spaces) and the exact-multiple-of-128 case (the
; walk's final flush + a separate EOF sector).
;
; AR15 SAVE CARVE-OUT: the Step-2 BDOS_DELETE is inlined (not via
; the BDOS_CALL macro) because 0xFF (file-not-matched) is the
; NORMAL first-save case for a not-yet-on-disk filename; routing
; through the funnel would falsely surface "can't write FILENAME"
; on every first save. The macro is used for MAKE / SET_DMA /
; WRITE_SEQ / CLOSE — sign-bit returns from those genuinely are
; error conditions, and the funnel's terminal JP-input_loop +
; pre-staged "can't write FILENAME" banner is the right response.
;
; AR14 status: this routine writes nothing to the gap buffer.
; The walk's LDIR-style per-byte read from [GAP_BUFFER_BASE,
; gap_start) and [gap_end, GAP_BUFFER_BASE + GAP_BUFFER_MAX) is
; read-only; the gap halves and cursor_offset survive unchanged.
; No new AR14 carve-out needed.
;
; In:      fcb_scratch populated (drive byte +0; 8-char space-
;          padded uppercase basename +1..+8; 3-char space-padded
;          uppercase extension +9..+11; zeros +12..+35).
;          filename_buffer populated (NUL-terminated canonical
;          display form; first byte != 0).
;          gap_start / gap_end / GAP_BUFFER_BASE / GAP_BUFFER_MAX
;          defining the two-halves payload.
; Out:     Success: file written to disk; buffer_dirty = 0;
;          filename_buffer + gap state unchanged; status row =
;          "<FILENAME> N bytes written". RET.
;          Failure (Step 0 R/O refusal / MAKE 0xFF / WRITE_SEQ
;          non-zero / CLOSE 0xFF): no return — bdos_error_funnel
;          surfaces "can't write FILENAME" then JPs to input_loop.
;          buffer_dirty stays nonzero (FR52); filename_buffer + gap
;          preserved; ex_buffer + mode cleared by the funnel. The
;          funnel route is load-bearing: cmd_write_quit's tail-JP
;          to init_teardown MUST be bypassed on every failure or
;          :wq on a failing save warm-boots and discards the buffer.
; Trashes: A, BC, DE, HL, F.
; Calls:   fileio_compose_cant_write (pre-stage banner),
;          BDOS_ENTRY (inline AR15 save carve-out for DELETE),
;          BDOS_CALL (BDOS_MAKE / BDOS_SET_DMA / BDOS_WRITE_SEQ /
;          BDOS_CLOSE), fileio_save_walk_bytes, fileio_save_flush_sector,
;          fileio_compose_written_status, status_set_message.
; ----------------------------------------------------------------
fileio_save:
    ;; Step 0: R/O PRE-CHECK (AR15 SAVE-PRECHECK CARVE-OUT).
    ;;
    ;; CP/M 2.2 BDOS detects R/O-file writes at the BDOS level
    ;; and warm-boots ("Bdos Err On <d>: File R/O") BEFORE
    ;; returning to the caller. Our macro funnel's terminal
    ;; JP-to-input_loop never runs because BDOS doesn't return —
    ;; the pre-staged "can't write FILENAME" banner is unreachable
    ;; on that path, and any unsaved buffer content is lost to the
    ;; warm-boot. To honor FR52 / NFR6 ("no silent data loss") for
    ;; STAT-marked R/O files we MUST detect the R/O attribute
    ;; BEFORE issuing the destructive BDOS_DELETE / BDOS_MAKE.
    ;;
    ;; The probe: SEARCH_FIRST with the FCB ext-char-0 high bit
    ;; SET — under CP/M 2.2 that search query matches only R/O
    ;; directory entries; A = 0..3 means a R/O entry exists at
    ;; this filename. The matched entry returns into the DMA
    ;; buffer; its byte +9 high bit confirms (defends against an
    ;; iz-cpm-style lenient BDOS that doesn't filter on attribute
    ;; bits — iz-cpm strips the high bit in both the search match
    ;; AND the returned directory data, so its DMA inspection
    ;; passes through harmlessly).
    ;;
    ;; AR15 carve-out: SEARCH_FIRST is inlined because the macro
    ;; funnel would falsely surface "can't write FILENAME" on
    ;; A = 0xFF (no matching R/O entry), which is the NORMAL case
    ;; for any save target that is either R/W or not-yet-on-disk.
    LD      DE, DEFAULT_DMA
    BDOS_CALL BDOS_SET_DMA                  ; SEARCH_FIRST writes the directory record here
    LD      A, (fcb_scratch + 9)
    OR      0x80                            ; set R/O bit in search query
    LD      (fcb_scratch + 9), A
    LD      C, BDOS_SEARCH_FIRST
    LD      DE, fcb_scratch
    CALL    BDOS_ENTRY                      ; AR15 save-precheck carve-out
    LD      B, A                            ; save SEARCH rc across FCB restore
    LD      A, (fcb_scratch + 9)
    AND     0x7F                            ; restore canonical FCB
    LD      (fcb_scratch + 9), A
    LD      A, B
    CP      0xFF
    JR      Z, .precheck_done               ; no R/O entry → proceed
    CP      4
    JR      NC, .precheck_done              ; defensive: A>=4 → out-of-spec BDOS rc → treat as no match
    ;; A = 0..3, directory entry at DMA + A * 32. Inspect ext
    ;; char 0 (offset +9 within the entry) high bit to confirm
    ;; R/O — guards against the iz-cpm-lenient case where SEARCH
    ;; matched an R/W entry despite the attribute-bit query.
    ADD     A, A
    ADD     A, A
    ADD     A, A
    ADD     A, A
    ADD     A, A                            ; A = entry_index * 32
    LD      E, A
    LD      D, 0
    LD      HL, DEFAULT_DMA + 9
    ADD     HL, DE                          ; HL -> entry.ext_char_0
    BIT     7, (HL)
    JR      Z, .precheck_done               ; high bit clear → not R/O → proceed
    ;; R/O CONFIRMED — refuse via bdos_error_funnel so the funnel's
    ;; terminal JP-to-input_loop bypasses cmd_write_quit's tail-JP
    ;; to init_teardown. Mirrors fileio_save_flush_sector's
    ;; .write_abort pattern. A normal RET here would leak control
    ;; back to cmd_write_quit which would warm-boot and discard the
    ;; buffer — defeating the FR52 protection this pre-check exists
    ;; to enforce. buffer_dirty / filename_buffer / gap state all
    ;; preserved; user can STAT $R/W and retry.
    CALL    fileio_compose_cant_write       ; HL = fileio_status_scratch
    LD      (bdos_error_pre_msg), HL
    JP      bdos_error_funnel               ; terminal JP input_loop
.precheck_done:

    ;; Step 1: pre-stage "can't write <filename>" banner so the
    ;; BDOS_CALL macro's funnel surfaces it on any non-DELETE
    ;; sign-bit failure (MAKE / WRITE_SEQ / CLOSE).
    CALL    fileio_compose_cant_write       ; HL = fileio_status_scratch
    LD      (bdos_error_pre_msg), HL

    ;; Step 2: AR15 SAVE CARVE-OUT — inline BDOS_DELETE.
    ;; bdos_error_funnel would falsely surface "can't write
    ;; FILENAME" on the 0xFF return that simply means "no prior
    ;; file to delete" — the NORMAL first-save case. A's return
    ;; code is ignored: 0..3 = file existed and was deleted,
    ;; 0xFF = no matching file. Either result lets MAKE proceed.
    LD      C, BDOS_DELETE
    LD      DE, fcb_scratch
    CALL    BDOS_ENTRY                      ; AR15 save carve-out

    ;; Step 3: BDOS_MAKE. Macro routing applies on 0xFF (directory
    ;; full / drive offline / etc.) — funnel surfaces the
    ;; pre-staged banner; buffer_dirty stays nonzero (FR52). The
    ;; R/O case was already filtered by the Step 0 pre-check.
    LD      DE, fcb_scratch
    BDOS_CALL BDOS_MAKE

    ;; Step 4: defensive DMA reset. Redundant against Step 0's
    ;; SET_DMA on the green path (no DMA-changing call between
    ;; them) but kept as the canonical write-loop entry — cheap
    ;; insurance against a future intervening BDOS call.
    LD      DE, DEFAULT_DMA
    BDOS_CALL BDOS_SET_DMA

    ;; Step 5: compute total payload = H1 + H2 (sum of the two
    ;; gap halves), cache in fileio_write_count for Step 11.
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE                          ; HL = H1 (before-gap)
    PUSH    HL                              ; save H1
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      DE, (gap_end)
    OR      A
    SBC     HL, DE                          ; HL = H2 (after-gap)
    POP     DE                              ; DE = H1
    ADD     HL, DE                          ; HL = total payload
    LD      (fileio_write_count), HL

    ;; Init walk state: dma_ptr = DEFAULT_DMA, dma_remain = 128.
    LD      HL, DEFAULT_DMA
    LD      (fileio_save_dma_ptr), HL
    LD      A, 128
    LD      (fileio_save_dma_remain), A

    ;; Step 6a: walk before-gap half [GAP_BUFFER_BASE, gap_start).
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE                          ; HL = H1 length
    LD      B, H
    LD      C, L                            ; BC = H1
    LD      HL, GAP_BUFFER_BASE             ; HL = src ptr
    CALL    fileio_save_walk_bytes

    ;; Step 6b: walk after-gap half [gap_end, GAP_BUFFER_BASE + GAP_BUFFER_MAX).
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      DE, (gap_end)
    OR      A
    SBC     HL, DE                          ; HL = H2 length
    LD      B, H
    LD      C, L                            ; BC = H2
    LD      HL, (gap_end)                   ; HL = src ptr
    CALL    fileio_save_walk_bytes

    ;; Step 7: EOF-pad. Fill the remaining dma_remain slots with
    ;; 0x1A then spaces; write the final sector. Invariant on
    ;; entry: fileio_save_dma_remain ∈ [1, 128] — fileio_save_walk_bytes'
    ;; flush guarantees this (a byte that would have left
    ;; dma_remain == 0 triggers flush + reset to 128 inside the
    ;; walk, before the walk returns). The empty-buffer case
    ;; (0 payload bytes) lands here with dma_remain = 128 untouched.
    LD      HL, (fileio_save_dma_ptr)
    LD      A, (fileio_save_dma_remain)
    LD      B, A                            ; B = slots to fill (1..128)
    LD      A, 0x1A                         ; first slot = EOF marker
.eof_fill:
    LD      (HL), A
    INC     HL
    LD      A, ' '                          ; subsequent slots = spaces
    DJNZ    .eof_fill

    ;; Write the EOF sector. The flush resets dma state (unused
    ;; from here onward — about to close).
    CALL    fileio_save_flush_sector

    ;; Step 8: BDOS_CLOSE. Macro routing applies on 0xFF (rare —
    ;; FCB corruption or BIOS post-write disk error).
    LD      DE, fcb_scratch
    BDOS_CALL BDOS_CLOSE

    ;; Step 9: clear the pre-staged banner pointer so a future
    ;; unrelated BDOS error doesn't inherit this stale value.
    ;; CRITICAL: only runs AFTER all BDOS calls succeed — any
    ;; earlier failure JPs through the funnel and never reaches
    ;; here, but the pre-stage stays correctly aimed for that
    ;; failure path.
    LD      HL, 0
    LD      (bdos_error_pre_msg), HL

    ;; Step 10: clear dirty flag. cursor_offset / gap_start /
    ;; gap_end / filename_buffer are unchanged (the walk was
    ;; read-only against the gap halves).
    XOR     A
    LD      (buffer_dirty), A

    ;; Step 11: compose + emit "<FILENAME> N bytes written".
    LD      BC, (fileio_write_count)
    CALL    fileio_compose_written_status   ; HL = fileio_status_scratch
    XOR     A                               ; non-error code (AR16)
    JP      status_set_message              ; tail-JP


;; ============================================================
;; --- Internal helper: fileio_save_walk_bytes (Story 2.4) ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_save_walk_bytes
; Walk one gap half (src ptr, byte count) into the 128-byte DMA
; buffer; flush a sector via fileio_save_flush_sector each time
; the DMA fills. The dma_ptr / dma_remain cells track DMA state
; across calls so the caller can compose multiple halves into
; the same sector seamlessly.
;
; In:      HL = src ptr, BC = bytes remaining in this half
;          (0..GAP_BUFFER_MAX — handles the empty-half case
;          cleanly via the BC == 0 early RET).
; Out:     dma state advanced past bytes copied; flushes triggered
;          inline. RET.
; Trashes: A, BC, DE, HL, F.
; Calls:   fileio_save_flush_sector.
; ----------------------------------------------------------------
fileio_save_walk_bytes:
.walk_loop:
    LD      A, B
    OR      C
    RET     Z                               ; this half done
    LD      A, (HL)
    LD      DE, (fileio_save_dma_ptr)
    LD      (DE), A
    INC     DE
    LD      (fileio_save_dma_ptr), DE
    INC     HL
    DEC     BC
    LD      A, (fileio_save_dma_remain)
    DEC     A
    LD      (fileio_save_dma_remain), A
    JR      NZ, .walk_loop                  ; DMA still has room
    ;; DMA full — flush sector and continue. flush_sector resets
    ;; dma_ptr / dma_remain to (DEFAULT_DMA, 128).
    PUSH    HL
    PUSH    BC
    CALL    fileio_save_flush_sector
    POP     BC
    POP     HL
    JR      .walk_loop


;; ============================================================
;; --- Internal helper: fileio_save_flush_sector (Story 2.4) ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_save_flush_sector
; Issue one BDOS_WRITE_SEQ and reset DMA state for the next sector.
;
; Failure-routing per AC6:
;   - Sign-bit return (0xFF — rare; disk catastrophe class): the
;     BDOS_CALL macro's JP M routes to bdos_error_funnel which
;     surfaces the pre-staged "can't write FILENAME" banner.
;   - Positive non-zero return (A = 1..127 — documented CP/M 2.2
;     WRITE_SEQ errors: disk full, extent exhausted, write-protect
;     surfacing mid-sequence): bit 7 clear, macro's JP M does
;     NOT fire — we inspect A here and route to .write_abort,
;     which re-stages bdos_error_pre_msg defensively and JPs
;     to bdos_error_funnel.
;
; In:      (none — DMA buffer is full; fcb_scratch holds the FCB)
; Out:     Success: dma_ptr / dma_remain reset to (DEFAULT_DMA, 128);
;          RET.
;          Failure: no return — JPs through bdos_error_funnel.
; Trashes: A, BC, DE, HL, F.
; Calls:   BDOS_CALL (BDOS_WRITE_SEQ), bdos_error_funnel (abort).
; ----------------------------------------------------------------
fileio_save_flush_sector:
    LD      DE, fcb_scratch
    BDOS_CALL BDOS_WRITE_SEQ                ; sign-bit -> funnel via macro
    OR      A
    JR      NZ, .write_abort                ; A = 1..127 -> non-sign-bit error
    LD      HL, DEFAULT_DMA
    LD      (fileio_save_dma_ptr), HL
    LD      A, 128
    LD      (fileio_save_dma_remain), A
    RET
.write_abort:
    ;; Re-stage pre_msg defensively (it should still be set from
    ;; fileio_save's Step 1; the re-stage is paranoid) and route
    ;; to the funnel.
    LD      HL, fileio_status_scratch
    LD      (bdos_error_pre_msg), HL
    JP      bdos_error_funnel


;; ============================================================
;; --- Public entry: fileio_strip_leading_spaces ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_strip_leading_spaces
; Walk past any 0x20 bytes at the head of an ex-line argument
; region. Used by cmd_edit / cmd_edit_force on the arg region
; that exline_dispatch handed them (HL = first byte past the
; command token, typically the space separator).
;
; In:      HL = ptr, A = length
; Out:     HL = first non-space ptr, A = remaining length
; Trashes: A, B, F. (A is an in/out param; B is scratch.)
; ----------------------------------------------------------------
fileio_strip_leading_spaces:
    LD      B, A
.loop:
    LD      A, B
    OR      A
    JR      Z, .done
    LD      A, (HL)
    CP      ' '
    JR      NZ, .done
    INC     HL
    DEC     B
    JR      .loop
.done:
    LD      A, B
    RET


;; ============================================================
;; --- Public entry: fileio_load_initial (Story 2.3) ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_load_initial
; Story 2.3: launch-with-filename. Parses the CCP-populated default
; FCB at DEFAULT_FCB (0x005C); branches by FCB content into one of
; four terminal paths (all RET via tail-JP through status_set_message,
; so init_cold_start's Stages 6/7 can run after this returns):
;
;   - no-arg     (DEFAULT_FCB + 1 == ' '):
;                 seed status with msg_mode_normal — preserves
;                 Story-1.12's Stage-5 banner; buffer untouched.
;   - load-success:
;                 fall through to fileio_load_after_open (shared
;                 with :e); status = "<FILENAME> N bytes"; cursor=0.
;   - new-file   (BDOS_OPEN returns 0xFF):
;                 status = "<FILENAME> [new file]"; gap stays empty;
;                 buffer_dirty=0; filename_buffer PRESERVED so
;                 Story 2.4's :w has a save target.
;   - too-large / read-error (during the shared read loop):
;                 fileio_abort_too_large / _read_error fire (Story
;                 2.2 paths, unchanged); filename_buffer CLEARED.
;
; Open-fail DIVERGENCE from fileio_load (the :e entry): :e routes
; open-fail through bdos_error_funnel which surfaces "can't open
; FILENAME" via bdos_error_pre_msg and then JPs terminally to
; input_loop, leaving the user back at NORMAL with an empty buffer.
; vibe FILENAME instead KEEPS filename_buffer set so the next :w
; saves into a not-yet-on-disk file (FR1 / FR52 / NFR6 — no silent
; data loss when the user types content into a new-file buffer).
;
; AR15 LAUNCH CARVE-OUT: the BDOS_OPEN below is inlined (no macro)
; because the bdos_error_funnel's terminal JP-to-input_loop would
; bypass init_cold_start's Stages 6/7 (render_full + JP input_loop).
; The launch path must RET to init_cold_start regardless of OPEN
; success or failure. See the module-header "Architectural
; enforcement here" block for the full carve-out documentation.
;
; In:      (none — reads DEFAULT_FCB at 0x005C; the gap-buffer state
;          established by init_cold_start's Stage 3 gapbuf_init)
; Out:     RET on every terminal path. State per the four branches
;          above. status_set_message has been called; status_dirty
;          set; status_buffer holds the appropriate banner.
; Trashes: A, BC, DE, HL, F.
; Calls:   fileio_setup_from_default_fcb, gapbuf_init,
;          BDOS_ENTRY (inline AR15 launch carve-out, NOT the macro),
;          fileio_load_after_open (fall-through on open success),
;          fileio_compose_new_file_status (on .new_file),
;          render_mark_all_dirty, status_set_message (tail-JP from
;          .new_file and .no_arg).
; ----------------------------------------------------------------
fileio_load_initial:
    ;; Step 1: no-arg short-circuit. CCP space-pads the basename
    ;; when no filename argument is on the command tail; first
    ;; basename byte at DEFAULT_FCB + 1 == ' ' is the canonical
    ;; "no arg" sentinel.
    LD      A, (DEFAULT_FCB + 1)
    CP      ' '
    JR      Z, .no_arg

    ;; Step 2: copy + translate DEFAULT_FCB into fcb_scratch and
    ;; compose canonical filename_buffer display name.
    CALL    fileio_setup_from_default_fcb

    ;; Step 3: reset gap buffer to SR2-empty. Idempotent against
    ;; init_cold_start Stage 3's gapbuf_init, but keeps the AR14
    ;; discipline of routing every SR2 establishment through
    ;; gapbuf_init at every load entry.
    CALL    gapbuf_init

    ;; Step 4: AR15 launch carve-out — inline BDOS_OPEN check.
    ;; The BDOS_CALL macro's bdos_error_funnel routes terminally
    ;; via JP input_loop on open-fail, which would bypass
    ;; init_cold_start Stages 6/7. We inline the BDOS sequence
    ;; here and branch the failure locally to .new_file.
    LD      C, BDOS_OPEN
    LD      DE, fcb_scratch
    CALL    BDOS_ENTRY                  ; AR15 launch carve-out
    OR      A
    JP      M, .new_file                ; A bit 7 = 1 -> not found

    ;; Step 5: open succeeded (A = 0..3). Jump to the shared
    ;; post-open body — same path as :e from here. JP (not JR)
    ;; because the three Story-2.3 helpers between this site and
    ;; fileio_load_after_open push the target out of JR range.
    JP      fileio_load_after_open

.new_file:
    ;; Open failed. filename_buffer is PRESERVED (Story 2.3 AC4);
    ;; gap stays empty (Step 3); compose "<FILENAME> [new file]"
    ;; status banner. RET via status_set_message's tail-JP.
    CALL    fileio_compose_new_file_status   ; HL = scratch
    XOR     A
    LD      (buffer_dirty), A
    CALL    render_mark_all_dirty
    LD      HL, fileio_status_scratch
    XOR     A                           ; non-error-code arg (AR16)
    JP      status_set_message          ; tail-JP

.no_arg:
    ;; No filename argument — seed status row with msg_mode_normal
    ;; (empty banner, padded to STATUS_LINE_WIDTH). Buffer empty
    ;; from init Stage 3; filename_buffer zero from Stage 1 LDIR.
    LD      HL, msg_mode_normal
    XOR     A
    JP      status_set_message          ; tail-JP


;; ============================================================
;; --- Internal helper: fileio_setup_from_default_fcb (Story 2.3) ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_setup_from_default_fcb
; Copies DEFAULT_FCB[0..11] (drive byte + 8.3 basename/ext) into
; fcb_scratch[0..11], zero-fills fcb_scratch[12..35] (extent / S1
; / S2 / record-count / allocation-map / current-record must be
; zero for a fresh BDOS_OPEN per CP/M 2.2 convention), applies
; FR9 default-drive translation (CCP sentinel 0 -> 2 / B:), and
; composes the canonical display form into filename_buffer via
; the shared fileio_compose_filename_buffer helper.
;
; FR9 rationale: CCP encodes "no drive prefix on the command tail"
; as drive byte 0 (the currently-selected drive at command time).
; VIBE's FR9 overrides this to always-B: for bare filenames,
; matching :e's text-form parse behaviour (fileio_parse_filename's
; .no_drive path also sets B:). A user on A: typing `vibe foo.fs`
; will see B:FOO.FS in the status row — intentional and AR16-spec.
;
; FR10 pass-through: drive byte > 0 from CCP is used as-is;
; A:foo -> drive 1, B:foo -> drive 2, etc.
;
; In:      (none — reads DEFAULT_FCB at 0x005C)
; Out:     fcb_scratch populated (drive + basename + ext at +0..+11;
;          zero at +12..+35); filename_buffer populated with the
;          canonical display name (e.g. "B:HELLO.TXT\0").
; Trashes: A, BC, DE, HL, F.
; Calls:   fileio_compose_filename_buffer (via tail-JP).
; ----------------------------------------------------------------
fileio_setup_from_default_fcb:
    ;; Step 1: copy DEFAULT_FCB[0..11] -> fcb_scratch[0..11].
    LD      HL, DEFAULT_FCB
    LD      DE, fcb_scratch
    LD      BC, 12
    LDIR

    ;; Step 2: zero fcb_scratch[12..35] (24 bytes). Prior state
    ;; may be residue from a previous :e load's parse.
    LD      HL, fcb_scratch + 12
    XOR     A
    LD      (HL), A
    LD      DE, fcb_scratch + 13
    LD      BC, 23
    LDIR

    ;; Step 3: FR9 translation — drive 0 (CCP sentinel) -> 2 (B:).
    LD      A, (fcb_scratch)
    OR      A
    JR      NZ, .skip_fr9
    LD      A, 2
    LD      (fcb_scratch), A
.skip_fr9:

    ;; Step 4: compose canonical display name into filename_buffer.
    JP      fileio_compose_filename_buffer  ; tail-JP


;; ============================================================
;; --- Internal helper: fileio_compose_new_file_status (Story 2.3) ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_compose_new_file_status
; Build "<filename> [new file]\0" in fileio_status_scratch from
; the NUL-terminated filename_buffer + the static suffix
; fileio_msg_new_file_suffix (" [new file]\0"). Used by the
; launch path on BDOS_OPEN failure (AC4) to surface the vi-canonical
; "[new file]" banner.
;
; Capacity: filename_buffer (max 15 chars excl NUL) + suffix
; (11 chars) + NUL = 27 bytes. Well within the existing 48-byte
; fileio_status_scratch ceiling.
;
; In:      (none — reads filename_buffer + fileio_msg_new_file_suffix)
; Out:     fileio_status_scratch contains the composed banner;
;          HL = fileio_status_scratch (ready for status_set_message).
; Trashes: A, DE, HL, F.
; ----------------------------------------------------------------
fileio_compose_new_file_status:
    LD      HL, filename_buffer
    LD      DE, fileio_status_scratch
.copy_filename:
    LD      A, (HL)
    OR      A
    JR      Z, .filename_done
    LD      (DE), A
    INC     HL
    INC     DE
    JR      .copy_filename
.filename_done:
    ;; Copy suffix " [new file]\0" through the NUL terminator.
    LD      HL, fileio_msg_new_file_suffix
.copy_suffix:
    LD      A, (HL)
    LD      (DE), A
    OR      A
    JR      Z, .done
    INC     HL
    INC     DE
    JR      .copy_suffix
.done:
    LD      HL, fileio_status_scratch
    RET


;; ============================================================
;; --- Internal helper: fileio_parse_filename ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_parse_filename
; Normalise the filename text into:
;   - fcb_scratch (36 bytes) — CP/M 2.2 FCB shape, with drive byte
;     (1=A:, 2=B:), 8-byte uppercase space-padded basename, 3-byte
;     uppercase space-padded extension, zeros for the rest.
;   - filename_buffer (16 bytes in state.inc) — canonical display
;     form "<drive>:<basename>[.<ext>]\0" (trailing spaces trimmed).
;
; Drive resolution: explicit `<letter>:` prefix (case-insensitive)
; sets the drive byte; bare filenames default to drive 2 (B: per
; FR9). Overflow (basename > 8 or extension > 3) is silently
; truncated — CP/M's filesystem behaves the same way.
;
; In:      HL = filename text ptr, A = length (1..63)
; Out:     fcb_scratch and filename_buffer populated.
; Trashes: A, BC, DE, HL, F.
; ----------------------------------------------------------------
fileio_parse_filename:
    ;; Zero fcb_scratch (36 bytes).
    PUSH    HL                              ; save text ptr
    PUSH    AF                              ; save length
    LD      HL, fcb_scratch
    LD      DE, fcb_scratch + 1
    LD      (HL), 0
    LD      BC, 35
    LDIR
    ;; Space-fill basename + extension slots (offsets 1..11).
    LD      HL, fcb_scratch + 1
    LD      DE, fcb_scratch + 2
    LD      (HL), ' '
    LD      BC, 10
    LDIR
    POP     AF
    POP     HL

    ;; B = remaining input length.
    LD      B, A

    ;; --- Drive prefix? need at least 2 bytes ("X:") ---
    CP      2
    JR      C, .no_drive

    ;; Peek at HL[1] for ':'
    INC     HL
    LD      A, (HL)
    DEC     HL
    CP      ':'
    JR      NZ, .no_drive

    ;; HL[0] must be [A-Za-z]
    LD      A, (HL)
    CP      'A'
    JR      C, .no_drive
    CP      'z' + 1
    JR      NC, .no_drive
    ;; Allow A-Z, skip {[\]^_` (0x5B..0x60)
    CP      'a'
    JR      C, .drv_upper
    SUB     'a' - 'A'                       ; uppercase
.drv_upper:
    CP      'Z' + 1
    JR      NC, .no_drive                   ; was in 0x5B..0x60
    SUB     'A' - 1                         ; 'A'->1, 'B'->2, ...
    LD      (fcb_scratch), A
    INC     HL
    INC     HL
    DEC     B
    DEC     B
    JR      .parse_basename

.no_drive:
    LD      A, 2                            ; FR9 default: drive B
    LD      (fcb_scratch), A

.parse_basename:
    LD      DE, fcb_scratch + 1
    LD      C, 8                            ; max basename bytes
.base_loop:
    LD      A, B
    OR      A
    JR      Z, .done_parse                  ; input exhausted
    LD      A, (HL)
    CP      '.'
    JR      Z, .ext_start                   ; extension delimiter
    ;; Have a byte. Slot still open?
    LD      A, C
    OR      A
    JR      Z, .base_skip                   ; basename full; just advance
    LD      A, (HL)
    ;; Uppercase a-z -> A-Z.
    CP      'a'
    JR      C, .base_store
    CP      'z' + 1
    JR      NC, .base_store
    SUB     'a' - 'A'
.base_store:
    LD      (DE), A
    INC     DE
    DEC     C
.base_skip:
    INC     HL
    DEC     B
    JR      .base_loop

.ext_start:
    INC     HL                              ; skip '.'
    DEC     B
    JR      Z, .done_parse
    LD      DE, fcb_scratch + 9
    LD      C, 3                            ; max ext bytes
.ext_loop:
    LD      A, B
    OR      A
    JR      Z, .done_parse
    LD      A, C
    OR      A
    JR      Z, .ext_skip
    LD      A, (HL)
    CP      'a'
    JR      C, .ext_store
    CP      'z' + 1
    JR      NC, .ext_store
    SUB     'a' - 'A'
.ext_store:
    LD      (DE), A
    INC     DE
    DEC     C
.ext_skip:
    INC     HL
    DEC     B
    JR      .ext_loop


;; ============================================================
;; --- Internal helper: fileio_compose_filename_buffer ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_compose_filename_buffer
; Compose the canonical display form ("<drive>:<basename>[.<ext>]\0")
; into filename_buffer from the FCB-form bytes already laid down in
; fcb_scratch — drive byte at +0 (1=A:, 2=B:, ...); 8-char space-
; padded uppercase basename at +1..+8; 3-char space-padded uppercase
; extension at +9..+11. Trims trailing spaces from both basename
; and extension; omits the '.' delimiter when the extension is
; empty (all spaces). NUL-terminates the result.
;
; Story 2.2 inlined this composition at the tail of
; fileio_parse_filename (label `.done_parse`). Story 2.3 extracts
; it as a named entry so fileio_load_initial — which already has
; the FCB-form bytes in fcb_scratch from the CCP-populated
; DEFAULT_FCB — can compose the display form without going through
; the text-form parse.
;
; Layout note: `.done_parse:` (the Story-2.2 local-label entry from
; fileio_parse_filename) and `fileio_compose_filename_buffer:` (the
; Story-2.3 named entry) sit on consecutive lines — both labels
; resolve to the same address, both routes are byte-identical.
; The dotted-local references from inside fileio_parse_filename's
; body (`JR Z, .done_parse`) still target the same address.
;
; In:      (none — reads fcb_scratch)
; Out:     filename_buffer populated (NUL-terminated).
; Trashes: A, BC, DE, HL, F.
; Calls:   (none)
; ----------------------------------------------------------------
.done_parse:                            ; fileio_parse_filename's Story-2.2 tail label
fileio_compose_filename_buffer:         ; Story-2.3 named entry — same address
    ;; Compose canonical display form into filename_buffer.
    LD      A, (fcb_scratch)
    ADD     A, 'A' - 1                      ; drive byte -> letter
    LD      DE, filename_buffer
    LD      (DE), A
    INC     DE
    LD      A, ':'
    LD      (DE), A
    INC     DE
    ;; Basename (trim trailing spaces).
    LD      HL, fcb_scratch + 1
    LD      B, 8
.dn_base:
    LD      A, (HL)
    CP      ' '
    JR      Z, .dn_base_done
    LD      (DE), A
    INC     DE
    INC     HL
    DJNZ    .dn_base
.dn_base_done:
    ;; Extension (if non-empty).
    LD      A, (fcb_scratch + 9)
    CP      ' '
    JR      Z, .dn_nul
    LD      A, '.'
    LD      (DE), A
    INC     DE
    LD      HL, fcb_scratch + 9
    LD      B, 3
.dn_ext:
    LD      A, (HL)
    CP      ' '
    JR      Z, .dn_nul
    LD      (DE), A
    INC     DE
    INC     HL
    DJNZ    .dn_ext
.dn_nul:
    XOR     A
    LD      (DE), A                         ; NUL-terminate display name
    RET


;; ============================================================
;; --- Internal helper: fileio_ingest_sector ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_ingest_sector
; Scan the 128-byte sector at DEFAULT_DMA for the CP/M 0x1A EOF
; marker, copy the prefix bytes [0, N) into the gap buffer at
; gap_start, advance gap_start by N. If 0x1A was not found, copy
; the full 128 bytes and signal "continue reading". The total
; loaded-byte count is derived from gap_start at post-load time
; (gap_start - GAP_BUFFER_BASE), so no tally is maintained here.
;
; AR14 CARVE-OUT: this routine writes `gap_start` directly. SR2
; invariant verification: cursor_offset = 0 throughout the load;
; content lives in [GAP_BUFFER_BASE, gap_start); after-gap region
; is unused. The post-load gapbuf_move_gap(0) re-establishes the
; invariant maintained by gapbuf primitives.
;
; In:      (none — reads DEFAULT_DMA, gap_start)
; Out:     CF = 1 if 0x1A was found in this sector (caller stops);
;          CF = 0 otherwise. gap_start advanced by N (bytes copied).
; Trashes: A, BC, DE, HL, F.
; ----------------------------------------------------------------
fileio_ingest_sector:
    ;; Scan for 0x1A in 128 bytes.
    LD      HL, DEFAULT_DMA
    LD      B, 128
.scan:
    LD      A, (HL)
    CP      0x1A
    JR      Z, .found_eof
    INC     HL
    DJNZ    .scan
    ;; Not found — copy full 128 bytes.
    LD      HL, DEFAULT_DMA
    LD      DE, (gap_start)
    LD      BC, 128
    LDIR
    LD      (gap_start), DE                 ; AR14 carve-out: fileio_load linear-fill phase
    OR      A                               ; CF = 0
    RET

.found_eof:
    ;; N = 128 - B (B is the post-decrement counter at hit).
    LD      A, 128
    SUB     B
    JR      Z, .eof_no_copy                 ; N = 0 -> skip LDIR
    LD      C, A
    LD      B, 0                            ; BC = N
    LD      HL, DEFAULT_DMA
    LD      DE, (gap_start)
    LDIR
    LD      (gap_start), DE                 ; AR14 carve-out: fileio_load linear-fill phase
.eof_no_copy:
    SCF                                     ; CF = 1
    RET


;; ============================================================
;; --- Internal helper: fileio_compose_cant_open ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_compose_cant_open
; Build "can't open <filename>\0" in fileio_status_scratch.
; Called BEFORE BDOS_OPEN, so on failure the BDOS funnel can
; surface the context-rich banner via the bdos_error_pre_msg
; override.
;
; In:      (none — reads fileio_msg_cant_open_prefix + filename_buffer)
; Out:     fileio_status_scratch contains the composed banner.
; Trashes: A, BC, DE, HL, F.
; ----------------------------------------------------------------
fileio_compose_cant_open:
    LD      HL, fileio_msg_cant_open_prefix
    LD      DE, fileio_status_scratch
.copy_prefix:
    LD      A, (HL)
    OR      A
    JR      Z, .copy_filename
    LD      (DE), A
    INC     HL
    INC     DE
    JR      .copy_prefix
.copy_filename:
    LD      HL, filename_buffer
.cf_loop:
    LD      A, (HL)
    LD      (DE), A
    OR      A
    RET     Z                               ; copied NUL terminator
    INC     HL
    INC     DE
    JR      .cf_loop


;; ============================================================
;; --- Internal helper: fileio_compose_cant_write (Story 2.4) ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_compose_cant_write
; Build "can't write <filename>\0" in fileio_status_scratch.
; Called BEFORE the BDOS write sequence (MAKE / WRITE_SEQ / CLOSE),
; so on failure the funnel can surface the context-rich banner
; via the bdos_error_pre_msg override.
;
; Structure mirrors fileio_compose_cant_open exactly — only the
; prefix DEFB differs. AR16: "can't write " is 12 chars + NUL.
; Max composed length 12 + 15 + 1 = 28 bytes; within the existing
; 48-byte fileio_status_scratch budget.
;
; In:      (none — reads fileio_msg_cant_write_prefix + filename_buffer)
; Out:     fileio_status_scratch contains the composed banner;
;          HL = fileio_status_scratch (ready to load into
;          bdos_error_pre_msg).
; Trashes: A, BC, DE, HL, F.
; ----------------------------------------------------------------
fileio_compose_cant_write:
    LD      HL, fileio_msg_cant_write_prefix
    LD      DE, fileio_status_scratch
.copy_prefix:
    LD      A, (HL)
    OR      A
    JR      Z, .copy_filename
    LD      (DE), A
    INC     HL
    INC     DE
    JR      .copy_prefix
.copy_filename:
    LD      HL, filename_buffer
.cf_loop:
    LD      A, (HL)
    LD      (DE), A
    OR      A
    JR      Z, .done                        ; copied NUL terminator
    INC     HL
    INC     DE
    JR      .cf_loop
.done:
    LD      HL, fileio_status_scratch       ; HL = pre-stage pointer for caller
    RET


;; ============================================================
;; --- Internal helper: fileio_compose_loaded_status ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_compose_loaded_status
; Build "<filename> <count> bytes\0" in fileio_status_scratch.
;
; Story 2.4 refactor: this entry now loads its private suffix DEFB
; into DE and JPs into the shared body fileio_compose_filename_count_suffix
; (below), which Story 2.4's fileio_compose_written_status also
; routes through with a " bytes written" suffix. The composed
; output is byte-identical to the pre-refactor implementation —
; Story 2.2's fileio_load tests are the regression net.
;
; In:      BC = byte count (16-bit, 0..GAP_BUFFER_MAX)
; Out:     HL = fileio_status_scratch (ready for status_set_message)
; Trashes: A, BC, DE, HL, F.
; ----------------------------------------------------------------
fileio_compose_loaded_status:
    LD      DE, fileio_msg_bytes_suffix
    JP      fileio_compose_filename_count_suffix


; ----------------------------------------------------------------
; fileio_compose_written_status (Story 2.4)
; Build "<filename> <count> bytes written\0" in fileio_status_scratch.
;
; Routes through the shared body fileio_compose_filename_count_suffix
; (below) with the " bytes written" suffix.
;
; In:      BC = byte count (16-bit, 0..GAP_BUFFER_MAX)
; Out:     HL = fileio_status_scratch (ready for status_set_message)
; Trashes: A, BC, DE, HL, F.
; ----------------------------------------------------------------
fileio_compose_written_status:
    LD      DE, fileio_msg_bytes_written_suffix
    JP      fileio_compose_filename_count_suffix


; ----------------------------------------------------------------
; fileio_compose_filename_count_suffix
; Shared body for fileio_compose_loaded_status and the Story-2.4
; fileio_compose_written_status. Composes
; "<filename> <count><suffix>" in fileio_status_scratch, where
; <suffix> is a caller-supplied NUL-terminated string passed in
; DE (typically " bytes\0" or " bytes written\0").
;
; Capacity: filename (max 15) + space (1) + 5 decimal digits + 14
; (" bytes written") + NUL (1) = 36 bytes max. Within the 48-byte
; fileio_status_scratch budget.
;
; In:      BC = byte count, DE = NUL-terminated suffix ptr
; Out:     HL = fileio_status_scratch (ready for status_set_message)
; Trashes: A, BC, DE, HL, F.
; ----------------------------------------------------------------
fileio_compose_filename_count_suffix:
    PUSH    BC                              ; save byte count
    PUSH    DE                              ; save suffix ptr
    LD      HL, filename_buffer
    LD      DE, fileio_status_scratch
.copy_filename:
    LD      A, (HL)
    OR      A
    JR      Z, .filename_done
    LD      (DE), A
    INC     HL
    INC     DE
    JR      .copy_filename
.filename_done:
    LD      A, ' '
    LD      (DE), A
    INC     DE
    POP     HL                              ; HL = suffix ptr (saved)
    EX      (SP), HL                        ; stack top = suffix ptr; HL = byte count
    CALL    fileio_u16_to_dec               ; advances DE past digits
    POP     HL                              ; HL = suffix ptr
.copy_suffix:
    LD      A, (HL)
    LD      (DE), A
    OR      A
    JR      Z, .done
    INC     HL
    INC     DE
    JR      .copy_suffix
.done:
    LD      HL, fileio_status_scratch
    RET


;; ============================================================
;; --- Internal helper: fileio_u16_to_dec ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_u16_to_dec
; Emit HL as 1..5 decimal digits at (DE); leading zeros suppressed
; except for the units digit (so 0 -> "0", not "").
;
; In:      HL = unsigned 16-bit value, DE = dest ptr
; Out:     DE = first byte past last emitted digit
; Trashes: A, BC, HL, F. Also reads/writes module-local
;          `fileio_dec_dest` (dest-ptr marshalling between digits).
;
; Strategy: trial-subtract each power of 10 (10000, 1000, 100, 10)
; with PUSH/POP HL so an underflowing subtract is reverted; emit
; the resulting digit, suppressing leading zeros via a flag in B.
; The final 1s digit is HL itself (HL is < 10 by then).
; ----------------------------------------------------------------
fileio_u16_to_dec:
    LD      (fileio_dec_dest), DE
    LD      B, 0                            ; emit-flag (0 = suppress leading zero)

    LD      DE, 10000
    CALL    .ts_emit
    LD      DE, 1000
    CALL    .ts_emit
    LD      DE, 100
    CALL    .ts_emit
    LD      DE, 10
    CALL    .ts_emit

    ;; Final 1s digit — always emit.
    LD      A, L
    ADD     A, '0'
    LD      DE, (fileio_dec_dest)
    LD      (DE), A
    INC     DE
    RET

.ts_emit:
    LD      C, 0                            ; digit accumulator
.ts_sub:
    PUSH    HL
    OR      A                               ; clear CF
    SBC     HL, DE
    JR      C, .ts_underflow
    POP     AF                              ; discard saved HL (1 byte vs 2× INC SP)
    INC     C
    JR      .ts_sub
.ts_underflow:
    POP     HL                              ; restore HL (pre-SBC value)
    LD      A, B
    OR      C                               ; A = emit-flag | digit
    RET     Z                               ; both 0 -> still suppressing
    LD      A, C                            ; A = digit (0..9)
    LD      B, 1                            ; flip emit-flag on
    ADD     A, '0'
    PUSH    HL
    LD      HL, (fileio_dec_dest)
    LD      (HL), A
    INC     HL
    LD      (fileio_dec_dest), HL
    POP     HL
    RET


;; ============================================================
;; --- Internal helpers: fileio_abort_too_large / _read_error ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_abort_too_large
; fileio_abort_read_error
; Shared abort sequence (close + buffer reset + filename zero +
; render-mark-all + status emit) factored to a single body. The
; two entry points differ only in the message they surface.
; Used by fileio_load's pre-read budget check (too-large) and by
; the mid-read BDOS_READ_SEQ A>=2 path (read-error).
;
; In:      (none)
; Out:     buffer empty; cursor_offset = 0; buffer_dirty = 0;
;          filename_buffer[0] = 0; status row = msg.
; Trashes: A, BC, DE, HL, F.
; ----------------------------------------------------------------
fileio_abort_too_large:
    LD      HL, msg_file_too_large
    JR      fileio_abort_common
fileio_abort_read_error:
    LD      HL, msg_read_error
fileio_abort_common:
    PUSH    HL                              ; save message ptr across cleanup
    LD      DE, fcb_scratch
    BDOS_CALL BDOS_CLOSE
    CALL    gapbuf_init                     ; reset buffer to empty
    XOR     A
    LD      (buffer_dirty), A
    LD      (filename_buffer), A            ; zero display name so :w refuses
    CALL    render_mark_all_dirty
    POP     HL
    XOR     A
    JP      status_set_message              ; tail-JP


;; ============================================================
;; --- Module-local data ---
;; ============================================================

; CP/M 2.2 FCB layout (36 bytes): drive(1) + name(8) + ext(3) +
; extent(1) + S1(1) + S2(1) + record_count(1) + alloc_map(16) +
; current_record(1) + random_record(3). parse_filename overwrites
; the front 12 bytes; the rest stays zero (set at every load entry).
fcb_scratch:
    DEFS    36, 0

; 48-byte holding area for dynamic status banners. Capacity check
; (Story 2.4 refresh — the written-status banner is now the largest):
;   "<filename> N bytes written" = 15 + 1 + 5 + 14 + NUL = 36 bytes
;   "can't write <filename>"     = 12 + 15 + NUL          = 28 bytes
;   "<filename> N bytes"         = 15 + 1 + 5 + 6 + NUL   = 28 bytes
;   "can't open <filename>"      = 11 + 15 + NUL          = 27 bytes
;   "<filename> [new file]"      = 15 + 11 + NUL          = 27 bytes
; 48 stays generous (max needed = 36); the ASSERT pins the lower
; bound so a future banner stretch surfaces at build time.
fileio_status_scratch:
    DEFS    48, 0
    ASSERT  $ - fileio_status_scratch >= 48

fileio_msg_cant_open_prefix:
    DEFB    "can't open ", 0                ; 11 chars + NUL (AR16)

; Story 2.4: "can't write " prefix used by fileio_compose_cant_write
; to compose "can't write <filename>" into fileio_status_scratch.
; Pre-staged in bdos_error_pre_msg before BDOS_MAKE / BDOS_WRITE_SEQ
; / BDOS_CLOSE so the funnel can surface the context-rich banner.
fileio_msg_cant_write_prefix:
    DEFB    "can't write ", 0               ; 12 chars + NUL (AR16)

; Story 2.3: " [new file]" suffix appended to filename_buffer when
; vibe FILENAME launches with a not-yet-on-disk name. Composed
; dynamically by fileio_compose_new_file_status into
; fileio_status_scratch and emitted via status_set_message.
fileio_msg_new_file_suffix:
    DEFB    " [new file]", 0                ; 11 chars + NUL (AR16)

; Story 2.4: suffixes consumed by fileio_compose_filename_count_suffix
; (the shared body shared between fileio_compose_loaded_status and
; fileio_compose_written_status). The decimal byte count is emitted
; directly before the suffix; the suffix's leading space separates
; the count from the trailing word.
fileio_msg_bytes_suffix:
    DEFB    " bytes", 0                     ; 6 chars + NUL (AR16)
fileio_msg_bytes_written_suffix:
    DEFB    " bytes written", 0             ; 14 chars + NUL (AR16)

; 16-bit scratch for fileio_u16_to_dec output-pointer marshalling.
; The trial-subtract loop uses DE for the divisor, so the dest
; pointer rides in this cell across the per-digit emit.
fileio_dec_dest:
    DEFW    0

; Story 2.4: total payload byte count computed at fileio_save's
; Step 5 and consumed at Step 11 to seed fileio_compose_written_status.
; Module-local — NOT in state.inc (internal save scratch).
fileio_write_count:
    DEFW    0

; Story 2.4: DMA buffer write pointer and remaining-slot count
; tracked across fileio_save_walk_bytes calls and BDOS_WRITE_SEQ
; flushes. Init (DEFAULT_DMA, 128) at fileio_save entry; reset
; same after every flush; left at the EOF-pad end-state when
; fileio_save returns (subsequent fileio_save call re-inits).
fileio_save_dma_ptr:
    DEFW    0
fileio_save_dma_remain:
    DEFB    0
