; ============================================================
; Module: statusln.asm
; Purpose: Single status / error funnel (MC5). Owns the bottom
;          screen-row buffer; lands the bdos_error_funnel body
;          that Story 1.4's BDOS_CALL macro forward-referenced.
;          Every later module's error/info path enters here via
;          status_set_message — direct writes to status_buffer
;          / status_dirty are forbidden by AR12.
;
; Public:
;   status_set_message   ; MC5 funnel: HL = msg ptr, A = optional code
;   status_u16_to_dec    ; Story 3.3 (Q2 Option A): emit HL as 1..5
;                        ; decimal digits at (DE); leading zeros
;                        ; suppressed except for the units digit
;                        ; (so 0 -> "0", not ""). Relocated from
;                        ; src/fileio.asm where it was a module-
;                        ; local helper for filename+count banners;
;                        ; lives here now as the AR12 home for all
;                        ; status-line numeric composition. Callers
;                        ; today: fileio_compose_filename_count_suffix
;                        ; (Story 2.4); visual_compose_status
;                        ; (Story 3.3 — visual extent count).
;   bdos_error_funnel    ; abort path entered from BDOS_CALL on JP M.
;                        ; Story 2.2 widened the funnel: if
;                        ; `bdos_error_pre_msg` is non-zero, the
;                        ; funnel surfaces the pointed-to string in
;                        ; place of msg_bdos_error. Callers (fileio_load)
;                        ; pre-stage a context-rich message before
;                        ; their BDOS_CALL; the funnel honours it on
;                        ; failure and clears the override on its
;                        ; way to input_loop. The funnel also inlines
;                        ; the ex-line cleanup (clear ex_buffer length,
;                        ; mode = MODE_NORMAL, status_dirty = 1) so a
;                        ; mid-:e BDOS abort leaves the user in NORMAL
;                        ; mode rather than stranded in COMMAND.
;   ; (Story 1.5's status_render stub was retired in Story 1.11 —
;   ; the READ/EMIT path for status_buffer / status_dirty lives in
;   ; src/render.asm now; this module owns the WRITE path only.)
;
;   Message strings (AR16 — co-located here, all modules read by symbol):
;     msg_buffer_modified, msg_file_too_large, msg_pattern_not_found,
;     msg_search_wrapped, msg_undo_too_large, msg_nothing_to_undo,
;     msg_not_implemented, msg_no_write, msg_bdos_error,
;     msg_missing_filename (Story 2.2 — :e with no arg),
;     msg_read_error (Story 2.2 — mid-read BDOS rc >= 2),
;     msg_mode_normal, msg_mode_insert,
;     msg_unbound_key (Story 1.9 — mode/unbound; Story 2.1
;     retired msg_mode_command — the ':' prompt in ex_buffer
;     is the COMMAND-mode indicator now),
;     msg_not_editor_command (Story 2.1 — ex-line no-match),
;     msg_yank_too_large (Story 2.10 — SR6 over-capacity refusal),
;     msg_no_previous_pattern (Story 3.1 — `/<Enter>` with empty
;     search_pattern at cold-start),
;     msg_mode_visual_prefix (Story 3.3 — "-- visual -- " with
;     trailing space; the bare msg_mode_visual at this slot was
;     retired when src/dispatch.asm's enter_visual_mode stub left),
;     msg_mode_visual_line_prefix (Story 3.4 — "-- visual line -- "
;     with trailing space; LINE submode banner read by
;     src/visual.asm's visual_compose_status_line entry),
;     msg_mode_visual_block_prefix (Story 3.5 — "-- visual block -- "
;     with trailing space; BLOCK submode banner read by
;     src/visual.asm's visual_compose_status_block entry — rows-x-cols
;     format requires two numeric params with an 'x' separator,
;     hence a dedicated standalone compose body rather than the
;     CHAR/LINE shared tail)
;
; State owned (read/write):
;   status_buffer        ; 80-byte row buffer; writer = this module only (AR12)
;   status_dirty         ; nonzero = needs render; writer = this module only (AR12)
;   status_dec_dest      ; Story 3.3 — module-local 16-bit scratch
;                        ; for status_u16_to_dec's output-pointer
;                        ; marshalling across the per-digit emit.
;                        ; Renamed from fileio_dec_dest when the
;                        ; helper relocated here (Q2 Option A).
;   bdos_error_pre_msg   ; Story 2.2 — module-local 16-bit cell;
;                        ; non-zero = pointer to caller-supplied
;                        ; NUL-terminated string the funnel uses in
;                        ; place of msg_bdos_error. Writers: callers
;                        ; (currently src/fileio.asm only); funnel
;                        ; zeroes after use. NOT in state.inc — this
;                        ; is an error-funnel internal handshake, not
;                        ; cross-module shared state.
;
; Register conventions (across public entry points):
;   status_set_message:  In: HL = ptr, A = code
;                        Out: (side effects only)
;                        Trashes: A, BC, DE, HL, F
;                        Calls: (none)
;   bdos_error_funnel:   In: A = sign-bit BDOS rc, C = preserved BDOS fn
;                        Out: (does not return; JP input_loop)
;                        Trashes: A, BC, DE, HL, F
;                        Calls: status_set_message
;
; Dependencies:
;   inc/equates.inc  (STATUS_LINE_WIDTH, EX_COMMAND_BUFFER — Story 2.2)
;   inc/modes.inc    (MODE_NORMAL — Story 2.2 funnel ex-line cleanup)
;   inc/state.inc    (status_buffer, status_dirty; Story 2.2 also reads
;                     ex_buffer length + writes mode_byte in the funnel's
;                     inline ex-line cleanup)
;   inc/bdos.inc     (BDOS_CALL, BDOS_EXIT — used by callers; not by this module)
;   inc/bios.inc     (BDOS_ENTRY via BDOS_CALL macro chain)
;   src/vibe.asm     (input_loop — abort target JPed to by bdos_error_funnel;
;                     Story 1.5 stub, Story 1.8 lands the real loop)
; ============================================================

;; ============================================================
;; --- Public entry points ---
;; ============================================================

; ----------------------------------------------------------------
; status_set_message
; Single status-message funnel (MC5). Copy a null-terminated
; message into status_buffer, padding with spaces to the full
; STATUS_LINE_WIDTH, and set status_dirty so the next render pass
; emits the row.
;
; In:      HL = pointer to null-terminated message string
;          A  = optional error code (zero for non-error;
;               reserved for future routing — currently ignored)
; Out:     (none — side effect: status_buffer populated,
;          status_dirty set nonzero)
; Trashes: A, BC, DE, HL, F
; Calls:   (none)
;
; Behaviour:
;   - Copies bytes from (HL) into status_buffer until either the
;     null terminator is hit OR STATUS_LINE_WIDTH bytes have been
;     copied (truncation; no overflow into status_buffer + 80).
;   - On null hit, pads the remainder with 0x20 (ASCII space).
;   - On 80-byte truncation, no padding (buffer is already full).
;   - Sets status_dirty to 1 unconditionally.
; ----------------------------------------------------------------
status_set_message:
    LD      DE, status_buffer
    LD      B, STATUS_LINE_WIDTH    ; max bytes left to copy
.copy_loop:
    LD      A, (HL)
    OR      A                       ; null terminator?
    JR      Z, .pad_loop
    LD      (DE), A
    INC     HL
    INC     DE
    DJNZ    .copy_loop
    JR      .set_dirty              ; reached width; no pad needed

.pad_loop:
    LD      A, ' '                  ; space pad (NFR16: literal char)
    LD      (DE), A
    INC     DE
    DJNZ    .pad_loop

.set_dirty:
    LD      A, 1
    LD      (status_dirty), A
    RET

; ----------------------------------------------------------------
; status_u16_to_dec
; Emit HL as 1..5 decimal digits at (DE); leading zeros suppressed
; except for the units digit (so 0 -> "0", not "").
;
; Relocated from src/fileio.asm (Story 3.3 Q2 pin Option A) — the
; helper lives here now as the AR12 home for all status-line numeric
; composition. Behaviour and calling contract unchanged from the
; Story-2.4 implementation; the module-local marshalling cell was
; renamed from fileio_dec_dest -> status_dec_dest at the same time.
;
; In:      HL = unsigned 16-bit value, DE = dest ptr
; Out:     DE = first byte past last emitted digit
; Trashes: A, BC, HL, F. Also reads/writes module-local
;          `status_dec_dest` (dest-ptr marshalling between digits).
;
; Strategy: trial-subtract each power of 10 (10000, 1000, 100, 10)
; with PUSH/POP HL so an underflowing subtract is reverted; emit
; the resulting digit, suppressing leading zeros via a flag in B.
; The final 1s digit is HL itself (HL is < 10 by then).
; ----------------------------------------------------------------
status_u16_to_dec:
    LD      (status_dec_dest), DE
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
    LD      DE, (status_dec_dest)
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
    LD      HL, (status_dec_dest)
    LD      (HL), A
    INC     HL
    LD      (status_dec_dest), HL
    POP     HL
    RET

; ----------------------------------------------------------------
; bdos_error_funnel
; Entry from BDOS_CALL macro's `JP M, bdos_error_funnel` after a
; sign-bit BDOS rc (typically 0xFF from FCB ops). Story 1.5 landed
; the bare body; Story 2.2 widened it with the `bdos_error_pre_msg`
; override + inline ex-line cleanup (see below).
;
; Override mechanism (Story 2.2):
;   Callers that want a context-rich banner on BDOS failure can
;   pre-stage a pointer to a NUL-terminated string in the module-
;   local `bdos_error_pre_msg` cell BEFORE invoking BDOS_CALL. On
;   failure, the funnel reads the cell; if non-zero it surfaces the
;   pointed-to string instead of msg_bdos_error. It then ZEROES the
;   cell (so a subsequent unrelated BDOS error doesn't inherit a
;   stale pointer) before JPing to input_loop. Callers that
;   succeed are responsible for clearing the cell themselves
;   (fileio_load does this immediately after a successful BDOS_OPEN).
;
; Inline ex-line cleanup (Story 2.2):
;   The funnel JPs directly to input_loop, bypassing any in-flight
;   exline handler's `JP exline_cancel_core` cleanup. To prevent the
;   user being stranded in MODE_COMMAND with the failed ':e foo.fs'
;   text dangling, the funnel inlines three writes mirroring
;   exline_cancel_core (clear ex_buffer length, mode_byte =
;   MODE_NORMAL, status_dirty = 1) on its way out. Layering note:
;   we chose this over JPing to exline_cancel_core itself because
;   statusln.asm INCLUDEs BEFORE exline.asm in vibe.asm's chain;
;   the duplication is 9 bytes and keeps the include order acyclic.
;
; In:      A = sign-bit BDOS rc (caller-side meaning: the BDOS
;              function failed)
;          C = preserved BDOS fn-number (assumption: iz-cpm and
;              typical CP/M BIOSes preserve C through BDOS;
;              real-MicroBeast confirmation lands in Story 1.12
;              W1). The funnel does not inspect C — per-fn dispatch
;              is unnecessary now that callers pre-stage messages
;              via `bdos_error_pre_msg`.
; Out:     (does not return — control transfers to input_loop)
; Trashes: A, BC, DE, HL, F (matches status_set_message)
; Calls:   status_set_message
; ----------------------------------------------------------------
bdos_error_funnel:
    ;; Override check: if (bdos_error_pre_msg) != 0, use it as the
    ;; status message; else fall back to msg_bdos_error.
    LD      HL, (bdos_error_pre_msg)
    LD      A, H
    OR      L
    JR      NZ, .emit_status
    LD      HL, msg_bdos_error
.emit_status:                       ; common emit path (override or fallback)
    XOR     A                       ; non-error-code arg (reserved)
    CALL    status_set_message

    ;; Clear the override so a future unrelated BDOS error does
    ;; NOT pick up our stale pointer.
    LD      HL, 0
    LD      (bdos_error_pre_msg), HL

    ;; Inline ex-line cleanup (mirrors exline_cancel_core, kept
    ;; out-of-line to avoid statusln -> exline layering inversion).
    XOR     A
    LD      (ex_buffer), A          ; ex-line length = 0
    LD      (command_submode), A    ; Story 3.1: clear SEARCH submode if a
                                    ; BDOS error fires from a /-search edit
    LD      A, MODE_NORMAL
    LD      (mode_byte), A
    LD      A, 1
    LD      (status_dirty), A       ; defensive (status_set_message set it; pin it)

    JP      input_loop              ; abort current operation:
                                    ; Story 1.5 stub warm-boots;
                                    ; Story 1.8 lands the real loop

;; ============================================================
;; --- Internal helpers ---
;; ============================================================
; (none for Story 1.5 — the public entry points above are flat
;  enough not to need helpers; reserve this section for future
;  growth such as a per-fn message-dispatch table.)

;; ============================================================
;; --- Status-line message strings (AR16 conventions) ---
;; ============================================================
; All strings: lowercase ASCII, no trailing period, under 30
; characters of payload (count excluding the terminating 0x00).
; Null-terminated per AR24 default; the length-prefix convention
; is reserved for search_pattern and ex_buffer.
;
; The seven enumerated by epics line 444 plus msg_bdos_error
; (the safety-net message used by bdos_error_funnel itself) and
; msg_not_implemented (Story 1.7 — stub-routine surface; co-located
; here per AR16 so future stubs can share it).

msg_buffer_modified:    DEFB "buffer modified", 0
msg_file_too_large:     DEFB "file too large", 0
msg_pattern_not_found:  DEFB "pattern not found", 0
msg_search_wrapped:     DEFB "search wrapped", 0
msg_undo_too_large:     DEFB "undo not possible - too large", 0
msg_nothing_to_undo:    DEFB "nothing to undo", 0
msg_not_implemented:    DEFB "not yet implemented", 0
msg_no_write:           DEFB "no write since last change", 0
msg_missing_filename:   DEFB "missing filename", 0
msg_not_editor_command: DEFB "not an editor command", 0
msg_bdos_error:         DEFB "bdos error", 0
msg_read_error:         DEFB "can't read file", 0
msg_yank_too_large:     DEFB "yank too large", 0
msg_no_previous_pattern: DEFB "no previous pattern", 0

;; --- Story 1.9 / 2.1: mode-indicator + unbound-key strings (AR16) ---
; msg_mode_normal is the empty string: status_set_message hits the
; null terminator on byte 0 and pads the full STATUS_LINE_WIDTH with
; spaces — i.e. on entering normal mode the indicator is cleared,
; matching vi's "no banner in normal mode" convention. Story 2.1
; retired msg_mode_command — the ':' prompt in ex_buffer (rendered
; into status_buffer by exline_compose_status) is the COMMAND-mode
; indicator.
msg_mode_normal:        DEFB 0
msg_mode_insert:        DEFB "-- insert --", 0
; Story 3.3: the bare msg_mode_visual ("-- visual --", 0) was the
; only string the retired src/dispatch.asm enter_visual_mode stub
; emitted. visual_enter_char + visual_extend now compose
; "-- visual -- <count>" dynamically via visual_compose_status
; using this prefix (13 ASCII chars + trailing space + NUL).
msg_mode_visual_prefix: DEFB "-- visual -- ", 0
; Story 3.4 — VIS_LINE submode prefix. 18 ASCII chars + NUL = 19 B.
; visual_compose_status_line LDIRs the first 18 bytes (without the
; NUL) into status_compose_scratch; the digits follow at offset 18;
; then visual_compose_status_line writes its own NUL terminator and
; hands off to status_set_message. Parallels msg_mode_visual_prefix
; one line above — same family, explicit unit. Read by the new
; visual_compose_status_line entry in src/visual.asm.
msg_mode_visual_line_prefix: DEFB "-- visual line -- ", 0
; Story 3.5 — VIS_BLOCK submode prefix. 19 ASCII chars + NUL = 20 B.
; visual_compose_status_block LDIRs the first 19 bytes (without the
; NUL) into status_compose_scratch; the rows digits follow at
; offset 19; then a literal 'x' separator; then the cols digits;
; then visual_compose_status_block writes its own NUL terminator
; and hands off to status_set_message. Parallels
; msg_mode_visual_line_prefix two lines above — same family, one
; extra word ("block") between "visual" and the closing "-- ".
msg_mode_visual_block_prefix: DEFB "-- visual block -- ", 0
msg_unbound_key:        DEFB "unbound key", 0

;; --- Story 2.2: bdos_error_funnel override pointer ---
; 16-bit pointer-or-zero. Zero = use msg_bdos_error (default); non-
; zero = use pointed-to NUL-terminated string. See the funnel's
; contract comment above. Module-local — NOT exported via state.inc.
; Writers: callers (currently src/fileio.asm only); the funnel zeroes
; on its way to input_loop so a stale value cannot leak across
; unrelated BDOS errors.
bdos_error_pre_msg:     DEFW 0

;; --- Story 3.3: status_u16_to_dec dest-pointer marshalling ---
; 16-bit scratch used by status_u16_to_dec's trial-subtract loop to
; carry the dest pointer across each digit's PUSH/POP HL. Relocated
; (and renamed) from fileio.asm's fileio_dec_dest when the helper
; moved here under Q2 Option A. Module-local — not in state.inc.
status_dec_dest:        DEFW 0
