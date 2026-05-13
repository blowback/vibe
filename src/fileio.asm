; ============================================================
; Module: fileio.asm
; Purpose: FCB-based file load over the CP/M 2.2 BDOS surface
;          (FR6 / FR9 / FR10 / FR11 / FR51). Story 2.2 lands the
;          first production caller of the BDOS_CALL macro in the
;          file-I/O cluster: BDOS_OPEN (15), BDOS_SET_DMA (26),
;          BDOS_READ_SEQ (20), BDOS_CLOSE (16). Owns the canonical
;          FCB scratch and the dynamic status-string composition
;          for "can't open FILENAME" (open-fail) and
;          "FILENAME N bytes" (load-success).
;
;          Entry surface for the ex-line:
;              cmd_edit / cmd_edit_force (in src/exline.asm)
;                      |
;                      v
;              fileio_load (this module)
;                      |
;                      v
;              BDOS_OPEN -> BDOS_SET_DMA -> BDOS_READ_SEQ loop
;              -> BDOS_CLOSE -> gapbuf_move_gap(0) -> status emit
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
;                   BDOS_CALL macro (no raw `CALL 0x0005` /
;                   `CALL BDOS_ENTRY`). The macro's `JP M` catches
;                   sign-bit returns (0xFF from BDOS_OPEN's file-
;                   not-found); positive failure codes from
;                   BDOS_READ_SEQ (A >= 2) have bit 7 clear and
;                   are inspected per-call here.
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
;   fileio_strip_leading_spaces ; HL = ptr, A = length -> HL' =
;                               ; first non-space, A' = remaining
;                               ; length. Used by cmd_edit /
;                               ; cmd_edit_force before passing
;                               ; the arg region down here.
;
; State owned (read/write):
;   fcb_scratch                 ; 36-byte CP/M 2.2 FCB. Reset to
;                               ; zero at every fileio_load entry;
;                               ; drive + basename + extension
;                               ; overwritten by parse_filename.
;   fileio_status_scratch       ; 48-byte holding area for the
;                               ; dynamic status strings.
;   fileio_dec_dest             ; 2-byte scratch for u16_to_dec
;                               ; output-pointer marshalling.
;   gap_start                   ; AR14 CARVE-OUT — written during
;                               ; the linear-fill read loop only.
;                               ; All other writes go through
;                               ; gapbuf.asm's primitives.
;   bdos_error_pre_msg          ; module-local in statusln.asm.
;                               ; Pre-staged before BDOS_OPEN;
;                               ; cleared after success. The
;                               ; funnel zeroes it post-emit too.
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
; Dependencies:
;   inc/equates.inc  (GAP_BUFFER_MAX)
;   inc/bios.inc     (DEFAULT_DMA)
;   inc/bdos.inc     (BDOS_CALL, BDOS_OPEN, BDOS_SET_DMA,
;                     BDOS_READ_SEQ, BDOS_CLOSE)
;   inc/state.inc    (gap_start, gap_end, cursor_offset,
;                     buffer_dirty, filename_buffer)
;   src/gapbuf.asm   (gapbuf_init, gapbuf_move_gap)
;   src/render.asm   (render_mark_all_dirty)
;   src/statusln.asm (status_set_message, msg_file_too_large,
;                     msg_read_error; bdos_error_pre_msg override)
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

.done_parse:
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
;; --- Internal helper: fileio_compose_loaded_status ---
;; ============================================================

; ----------------------------------------------------------------
; fileio_compose_loaded_status
; Build "<filename> <count> bytes\0" in fileio_status_scratch.
;
; In:      BC = byte count (16-bit, 0..GAP_BUFFER_MAX)
; Out:     HL = fileio_status_scratch (ready for status_set_message)
; Trashes: A, BC, DE, HL, F.
; ----------------------------------------------------------------
fileio_compose_loaded_status:
    PUSH    BC                              ; save byte count
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
    POP     HL                              ; HL = byte count
    CALL    fileio_u16_to_dec               ; advances DE past digits
    LD      HL, .suffix
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
.suffix:
    DEFB    " bytes", 0


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

; 48-byte holding area for dynamic status banners. Capacity check:
; max content is filename_buffer (15) + " " (1) + 5 decimal digits
; + " bytes" (6) + NUL (1) = 28 bytes; or "can't open " (11) +
; filename (15) + NUL (1) = 27 bytes. 48 is generous; the ASSERT
; pins the lower bound so a future stretch surfaces at build time.
fileio_status_scratch:
    DEFS    48, 0
    ASSERT  $ - fileio_status_scratch >= 48

fileio_msg_cant_open_prefix:
    DEFB    "can't open ", 0                ; 11 chars + NUL (AR16)

; 16-bit scratch for fileio_u16_to_dec output-pointer marshalling.
; The trial-subtract loop uses DE for the divisor, so the dest
; pointer rides in this cell across the per-digit emit.
fileio_dec_dest:
    DEFW    0
