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
;   bdos_error_funnel    ; abort path entered from BDOS_CALL on JP M
;   status_render        ; render stub (Story 1.11 lands the real body)
;
;   Message strings (AR16 — co-located here, all modules read by symbol):
;     msg_buffer_modified, msg_file_too_large, msg_pattern_not_found,
;     msg_search_wrapped, msg_undo_too_large, msg_nothing_to_undo,
;     msg_not_implemented, msg_no_write, msg_bdos_error
;
; State owned (read/write):
;   status_buffer        ; 80-byte row buffer; writer = this module only (AR12)
;   status_dirty         ; nonzero = needs render; writer = this module only (AR12)
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
;   status_render:       In: (none)
;                        Out: status_dirty cleared
;                        Trashes: A, F
;                        Calls: (none)
;
; Dependencies:
;   inc/equates.inc  (STATUS_LINE_WIDTH)
;   inc/state.inc    (status_buffer, status_dirty)
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
; bdos_error_funnel
; Entry from BDOS_CALL macro's `JP M, bdos_error_funnel` after a
; sign-bit BDOS rc (typically 0xFF from FCB ops). This is the
; abort path Story 1.4 forward-referenced; Story 2.x's fileio
; layer is the first production caller via the macro.
;
; In:      A = sign-bit BDOS rc (caller-side meaning: the BDOS
;              function failed)
;          C = preserved BDOS fn-number (assumption: iz-cpm and
;              typical CP/M BIOSes preserve C through BDOS;
;              real-MicroBeast confirmation lands in Story 1.12
;              W1). For Story 1.5 we do not actually inspect C
;              — per-fn dispatch is deferred (see Note below).
; Out:     (does not return — control transfers to input_loop)
; Trashes: A, BC, DE, HL, F (matches status_set_message)
; Calls:   status_set_message
;
; Note: per-fn message dispatch is deferred to fileio.asm
; (Story 2.x), which will set a context-rich message via
; status_set_message BEFORE its BDOS call. When the BDOS call
; then fails into this funnel, the prior message remains the
; visible status — and the funnel's own write of msg_bdos_error
; gets superseded by fileio's pre-call message at most paths.
; The funnel writes msg_bdos_error as a safety net for unexpected
; entries (fileio bugs, future BDOS users without context-aware
; pre-call messages) so the user never sees a blank-but-aborted
; editor (NFR5).
; ----------------------------------------------------------------
bdos_error_funnel:
    LD      HL, msg_bdos_error
    XOR     A                       ; non-error-code arg (reserved)
    CALL    status_set_message
    JP      input_loop              ; abort current operation:
                                    ; Story 1.5 stub warm-boots;
                                    ; Story 1.8 lands the real loop

; ----------------------------------------------------------------
; status_render
; Render the status row to the screen if status_dirty is set.
;
; STORY 1.5 STUB: clears status_dirty and returns. No VT52 emit,
; no BIOS_CONOUT, no shadow_buffer touch. Story 1.11 (render
; pipeline) replaces this body with the real diff'd VT52 emit
; mirroring the main render path (architecture lines 1495-1499).
;
; In:      (none)
; Out:     status_dirty = 0
; Trashes: A, F
; Calls:   (none)
; ----------------------------------------------------------------
status_render:
    XOR     A
    LD      (status_dirty), A
    RET

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
msg_bdos_error:         DEFB "bdos error", 0
