; ============================================================
; Module: exline.asm
; Purpose: Ex command-line (the ':' surface). Owns the ex_buffer
;          edit path (begin / append-literal / backspace / cancel
;          / dispatch via exline_command_table), the cmd_quit /
;          cmd_quit_force handlers that retire Story 1.12's
;          mode_debug_quit, and the per-keystroke status-row
;          recompose (":" + ex_buffer content) through the AR12
;          status_set_message funnel. Story 2.1 lands the first
;          three real exline_command_table entries ('q', 'q!');
;          Stories 2.2 / 2.4 / 3.1 extend the table.
;
;          Architectural enforcement here:
;            AR12 — every status-row write enters via
;                   status_set_message; no direct status_buffer
;                   writes. The :-prompt recompose uses a file-
;                   local 66-byte scratch (":<payload>\0", null-
;                   terminated) handed off through HL.
;            AR13 — no BIOS_CONOUT call sites. Per-keystroke
;                   screen update flows: this module ->
;                   status_set_message (sets status_dirty) ->
;                   render_diff (next input-loop iteration) emits
;                   the status row. RI2 holds.
;            AR14 — no gap-buffer mutation. ex_buffer is separate
;                   from the editing buffer; cmd_quit tail-JPs to
;                   init_teardown, not to gapbuf mutators.
;            AR15 — no direct BDOS calls. cmd_quit / cmd_quit_force
;                   tail-JP to init_teardown, whose
;                   BDOS_CALL BDOS_EXIT (function 0 = warm-boot)
;                   is the single macro use site reached from
;                   this path.
;
; Public:
;   exline_begin               ; ':' entry from dispatch_normal
;   exline_append_literal      ; dispatch_command unbound-prefix
;                              ; (literal append; the COMMAND-mode
;                              ; equivalent of unbound_insert's
;                              ; future Story-2.8 literal-insert)
;   exline_backspace           ; dispatch_command[0x08]
;   exline_dispatch            ; dispatch_command[0x0D] (Enter)
;   exline_cancel              ; dispatch_command[0x1B] (Esc) —
;                              ; full cancel + msg_mode_normal
;                              ; banner.
;   exline_cancel_core         ; internal — clears ex_buffer +
;                              ; mode + sets status_dirty WITHOUT
;                              ; touching status_buffer. Used by
;                              ; the dispatch no-match path and
;                              ; cmd_quit's dirty refusal so the
;                              ; prior status banner survives.
;   cmd_quit                   ; ':q'  — clean: warm-boot; dirty:
;                              ; msg_no_write + cancel-core.
;   cmd_quit_force             ; ':q!' — unconditional warm-boot.
;   exline_command_table       ; ((NUL-terminated key, 2-byte
;                              ; handler) list, NUL-terminated
;                              ; by a zero-length key); extended
;                              ; in Stories 2.2 / 2.4 / 3.1.
;
; State owned (read/write):
;   ex_buffer                  ; length-prefixed (1B length + 64B
;                              ; payload). Writers: exline_begin
;                              ; (zero length), exline_append_literal
;                              ; (append + len++), exline_backspace
;                              ; (len--), exline_cancel_core (zero
;                              ; on the way back to NORMAL).
;                              ; Reader: render.asm (cursor override,
;                              ; AC11) and exline_dispatch (compare
;                              ; loop).
;
; State read-only:
;   buffer_dirty               ; READ by cmd_quit for FR52 / BH5
;                              ; dirty-buffer refusal.
;   mode_byte                  ; WRITTEN by exline_begin (=
;                              ; MODE_COMMAND) and exline_cancel_core
;                              ; (= MODE_NORMAL). No reads.
;   status_dirty               ; WRITTEN by exline_cancel_core
;                              ; (= 1). Load-bearing for exline_cancel
;                              ; (which calls core BEFORE
;                              ; status_set_message); defensive
;                              ; belt-and-braces for the no-match and
;                              ; dirty-refusal paths (which have
;                              ; already entered status_set_message,
;                              ; and that funnel already sets
;                              ; status_dirty = 1 on its own).
;
; Register conventions (across public entry points):
;   All handlers entered with A = key (MC4); not all inspect it.
;   Caller-saved (MC1): trash A, BC, DE, HL, F transitively
;   through status_set_message.
;
;   exline_begin:        In:  A = ':' (MC4 — ignored)
;                        Out: mode_byte = MODE_COMMAND; ex_buffer
;                             length = 0; status row composed as
;                             ":" via the AR12 funnel; status_dirty
;                             set by status_set_message.
;                        Trashes: A, BC, DE, HL, F.
;                        Calls: status_set_message (tail-JP via
;                             exline_compose_status).
;
;   exline_append_literal: In: A = key (MC4)
;                        Out: A < 0x20 or A >= 0x7F: dropped
;                             silently (filters control bytes and
;                             KEY_ARROW_* synthesised codes
;                             0x80..0x83). Buffer-full (length ==
;                             EX_COMMAND_BUFFER): dropped silently
;                             (vi-spirit: no beep, no banner).
;                             Else: byte appended at
;                             ex_buffer_text + old_length; length
;                             incremented; status row recomposed.
;                        Trashes: A, BC, DE, HL, F.
;                        Calls: status_set_message (tail-JP via
;                             exline_compose_status).
;
;   exline_backspace:    In:  A = 0x08 (MC4 — ignored)
;                        Out: length == 0: silent RET (no underflow,
;                             no beep). Else: length--; status row
;                             recomposed (the trailing space the
;                             diff writes over the now-gone glyph
;                             comes from status_set_message's pad).
;                        Trashes: A, BC, DE, HL, F.
;                        Calls: status_set_message (tail-JP via
;                             exline_compose_status).
;
;   exline_dispatch:     In:  A = 0x0D (MC4 — ignored)
;                        Out: matched key: tail-JP to the entry's
;                             handler (cmd_quit / cmd_quit_force
;                             at Story 2.1; e/e!/w/wq/etc. arrive
;                             in 2.2 / 2.4). No match: set
;                             msg_not_editor_command via
;                             status_set_message, then JP
;                             exline_cancel_core (which clears
;                             ex_buffer + mode = NORMAL without
;                             clobbering the just-set banner —
;                             see AC5 Note in the story spec).
;                        Trashes: A, BC, DE, HL, F (handler may
;                             trash more).
;                        Calls: matched handler, status_set_message,
;                             exline_cancel_core.
;
;   exline_cancel:       In:  A = 0x1B (MC4 — ignored)
;                        Out: ex_buffer length = 0; mode_byte =
;                             MODE_NORMAL; status row cleared via
;                             msg_mode_normal (the empty banner;
;                             status_set_message pads spaces).
;                        Trashes: A, BC, DE, HL, F.
;                        Calls: exline_cancel_core, status_set_message
;                             (tail-JP).
;
;   exline_cancel_core:  In:  (none)
;                        Out: ex_buffer length = 0; mode_byte =
;                             MODE_NORMAL; status_dirty = 1 (so
;                             render picks up whatever status_buffer
;                             content the caller has already laid
;                             down).
;                        Trashes: A, F.
;                        Calls: (none).
;
;   cmd_quit:            In:  (entered via tail-JP from
;                             exline_dispatch on ':q' match)
;                        Out: buffer_dirty == 0: tail-JP to
;                             init_teardown (uninstalls user ISR,
;                             clears screen via render_init, then
;                             warm-boots to CCP via BDOS function
;                             0; does not return on a real host).
;                             Nonzero: msg_no_write via
;                             status_set_message, then JP
;                             exline_cancel_core (the banner
;                             survives because the core path does
;                             NOT write msg_mode_normal — BH5).
;                        Trashes: A, BC, DE, HL, F.
;                        Calls: status_set_message, exline_cancel_core,
;                             init_teardown (tail-JP — see init.asm).
;
;   cmd_quit_force:      In:  (entered via tail-JP from
;                             exline_dispatch on ':q!' match)
;                        Out: tail-JP to init_teardown
;                             unconditionally (FR8 / BH5).
;                        Trashes: A, BC, DE, HL, F.
;                        Calls: init_teardown (tail-JP).
;
; Dependencies:
;   inc/equates.inc  (EX_COMMAND_BUFFER)
;   inc/modes.inc    (MODE_NORMAL, MODE_COMMAND)
;   inc/state.inc    (ex_buffer, ex_buffer_text, mode_byte,
;                     status_dirty, buffer_dirty)
;   src/statusln.asm (status_set_message; msg_no_write,
;                     msg_mode_normal, msg_not_editor_command)
;   src/init.asm     (init_teardown — cmd_quit / cmd_quit_force's
;                     tail-JP target; uninstalls the user ISR,
;                     clears the screen via render_init, and
;                     warm-boots to CCP via BDOS function 0)
; ============================================================

;; ============================================================
;; --- Public entry: exline_begin (':' from dispatch_normal) ---
;; ============================================================

; ----------------------------------------------------------------
; exline_begin
; Entered from dispatch_normal[':']. Flips into COMMAND mode,
; empties ex_buffer, and composes the ":" prompt into the status
; row via the AR12 funnel. The next render_diff sees status_dirty
; set and emits the row.
;
; In:      A = ':' (MC4 — ignored)
; Out:     mode_byte = MODE_COMMAND; ex_buffer length = 0;
;          status row composed as ":"; status_dirty set.
; Trashes: A, BC, DE, HL, F.
; Calls:   status_set_message (tail-JP via exline_compose_status).
; ----------------------------------------------------------------
exline_begin:
    LD      A, MODE_COMMAND
    LD      (mode_byte), A
    XOR     A
    LD      (ex_buffer), A              ; length = 0
    JP      exline_compose_status       ; tail-JP — sets status_dirty


;; ============================================================
;; --- Public entry: exline_append_literal (unbound prefix) ---
;; ============================================================

; ----------------------------------------------------------------
; exline_append_literal
; Entered from the dispatch_command unbound-prefix on any key not
; in the (Backspace / Enter / Esc) entries. Filters non-printable
; bytes (control + arrow synth codes), drops on buffer-full, and
; otherwise appends to ex_buffer + recomposes the status row.
;
; In:      A = key (MC4).
; Out:     A < 0x20 or A >= 0x7F: silent RET. Buffer-full
;          (length == EX_COMMAND_BUFFER): silent RET. Else
;          ex_buffer_text[old_length] = A; length++; status row
;          recomposed via the AR12 funnel.
; Trashes: A, BC, DE, HL, F.
; Calls:   status_set_message (tail-JP via exline_compose_status).
; ----------------------------------------------------------------
exline_append_literal:
    CP      0x20
    RET     C                           ; A < 0x20 -> drop
    CP      0x7F
    RET     NC                          ; A >= 0x7F -> drop (catches KEY_ARROW_*)

    LD      B, A                        ; save key across length read
    LD      A, (ex_buffer)
    CP      EX_COMMAND_BUFFER
    RET     NC                          ; full or over -> drop (defensive >=)

    ;; Append: ex_buffer_text[length] = key; length++.
    LD      C, A                        ; C = current length
    LD      H, 0
    LD      L, A
    LD      DE, ex_buffer_text
    ADD     HL, DE                      ; HL = ex_buffer_text + length
    LD      A, B                        ; restore key
    LD      (HL), A
    LD      A, C
    INC     A
    LD      (ex_buffer), A              ; length++

    JP      exline_compose_status       ; tail-JP


;; ============================================================
;; --- Public entry: exline_backspace (dispatch_command[0x08]) ---
;; ============================================================

; ----------------------------------------------------------------
; exline_backspace
; Length-1 == 0 is the silent-RET path (vi-spirit: no beep at
; an empty ex-line).
;
; In:      A = 0x08 (MC4 — ignored).
; Out:     length == 0: silent RET. Else length--; status row
;          recomposed.
; Trashes: A, BC, DE, HL, F (on the non-empty path; only A, F on
;          the silent-RET path).
; Calls:   status_set_message (tail-JP via exline_compose_status).
; ----------------------------------------------------------------
exline_backspace:
    LD      A, (ex_buffer)
    OR      A
    RET     Z                           ; length 0 -> silent
    DEC     A
    LD      (ex_buffer), A
    JP      exline_compose_status       ; tail-JP


;; ============================================================
;; --- Public entry: exline_dispatch (dispatch_command[0x0D]) ---
;; ============================================================

; ----------------------------------------------------------------
; exline_dispatch
; Walk exline_command_table comparing ex_buffer's length-prefixed
; payload against each NUL-terminated key string. On match, tail-
; JP to the entry's 2-byte handler. On no match (terminator
; reached), set msg_not_editor_command via status_set_message
; and tail-JP to exline_cancel_core — the core variant that does
; NOT clobber status_buffer with msg_mode_normal, so the error
; banner the user just earned survives the cleanup.
;
; In:      A = 0x0D (MC4 — ignored; state comes from ex_buffer).
; Out:     match: control transferred to handler (no return here).
;          no-match: msg_not_editor_command in status_buffer;
;                    ex_buffer cleared; mode = NORMAL;
;                    status_dirty set. Returns to dispatch_key's
;                    caller via exline_cancel_core's RET.
; Trashes: A, BC, DE, HL, F (handlers may trash more).
; Calls:   matched handler (cmd_quit / cmd_quit_force / ...),
;          status_set_message, exline_cancel_core (tail-JP).
; ----------------------------------------------------------------
exline_dispatch:
    ;; Bare-Enter (length 0) exits silently per vi convention — skip
    ;; the table walk that would otherwise surface 'not an editor
    ;; command' on every empty ':' (length 0 mismatches every entry).
    LD      A, (ex_buffer)
    OR      A
    JP      Z, exline_cancel            ; empty ex-line -> silent cancel

    LD      HL, exline_command_table
.next_entry:
    LD      A, (HL)
    OR      A
    JR      Z, .no_match                ; terminator -> no match

    ;; Count key length until null. HL on entry: entry key start.
    PUSH    HL                          ; save entry key start
    LD      B, 0
.count_key:
    LD      A, (HL)
    OR      A
    JR      Z, .key_counted
    INC     HL
    INC     B
    JR      .count_key
.key_counted:
    ;; B = key length; HL now points at the entry's null.
    LD      A, (ex_buffer)
    CP      B
    POP     HL                          ; HL = entry key start
    JR      NZ, .skip_entry             ; length mismatch -> next entry

    ;; Lengths match: byte-compare.
    LD      DE, ex_buffer_text
    LD      C, B                        ; C = bytes remaining
.compare:
    LD      A, C
    OR      A
    JR      Z, .match
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .skip_entry
    INC     HL
    INC     DE
    DEC     C
    JR      .compare

.skip_entry:
    ;; Walk HL past the entry's null + 2-byte handler addr.
    ;; Uses A = 0 + CP (HL) to test for the null sentinel without
    ;; disturbing the post-INC HL position. INC HL does not affect
    ;; flags, so JR NZ reads the CP's result.
    XOR     A
.advance_to_null:
    CP      (HL)
    INC     HL
    JR      NZ, .advance_to_null        ; loop until just past null
    INC     HL
    INC     HL                          ; skip 2-byte handler addr
    JR      .next_entry

.match:
    ;; HL points at the null after the key (compare loop walked
    ;; key_length bytes from key_start). Step past null to the
    ;; 2-byte handler addr, load it into HL, then JP (HL).
    INC     HL
    LD      E, (HL)
    INC     HL
    LD      D, (HL)
    EX      DE, HL                      ; HL = handler addr
    JP      (HL)                        ; tail-JP

.no_match:
    LD      HL, msg_not_editor_command
    XOR     A
    CALL    status_set_message
    JP      exline_cancel_core          ; clean ex_buffer + mode; banner survives


;; ============================================================
;; --- Public entry: exline_cancel (dispatch_command[0x1B]) ---
;; ============================================================

; ----------------------------------------------------------------
; exline_cancel
; Esc-from-COMMAND: clear ex_buffer, return to NORMAL, and clear
; the status row to the empty banner via msg_mode_normal. The
; split between exline_cancel and exline_cancel_core lets the
; no-match path of exline_dispatch and cmd_quit's dirty-refusal
; path keep their just-set status banners.
;
; In:      A = 0x1B (MC4 — ignored).
; Out:     ex_buffer length = 0; mode_byte = MODE_NORMAL; status
;          row = msg_mode_normal (empty + padded with spaces).
; Trashes: A, BC, DE, HL, F.
; Calls:   exline_cancel_core, status_set_message (tail-JP).
; ----------------------------------------------------------------
exline_cancel:
    CALL    exline_cancel_core
    LD      HL, msg_mode_normal
    XOR     A
    JP      status_set_message          ; tail-JP

; ----------------------------------------------------------------
; exline_cancel_core
; Internal: clears ex_buffer length, flips mode to NORMAL, and
; sets status_dirty. Does NOT touch status_buffer — callers that
; have already laid down a banner (exline_dispatch's no-match
; path; cmd_quit's dirty-refusal path) rely on this so the
; banner survives the cleanup.
;
; In:      (none)
; Out:     ex_buffer length = 0; mode_byte = MODE_NORMAL;
;          status_dirty = 1.
; Trashes: A, F.
; Calls:   (none).
; ----------------------------------------------------------------
exline_cancel_core:
    XOR     A
    LD      (ex_buffer), A              ; length = 0
    LD      A, MODE_NORMAL
    LD      (mode_byte), A
    LD      A, 1
    LD      (status_dirty), A           ; ensure render picks up the row
    RET


;; ============================================================
;; --- Public entry: cmd_quit (':q' handler) ---
;; ============================================================

; ----------------------------------------------------------------
; cmd_quit
; ':q' on a clean buffer: warm-boot to CCP via init_teardown.
; ':q' on a dirty buffer: refuse with msg_no_write, return to
; NORMAL via exline_cancel_core (the core path does NOT clobber
; status_buffer with msg_mode_normal, so the refusal banner the
; user needs to see survives).
;
; Entered via tail-JP from exline_dispatch on the 'q' match.
;
; In:      (none — state read from buffer_dirty)
; Out:     clean: control transfers to CCP via init_teardown
;          (no return on a real host). Dirty: ex_buffer cleared;
;          mode = NORMAL; status row = msg_no_write; status_dirty
;          set; RET (to dispatch_key's caller).
; Trashes: A, BC, DE, HL, F.
; Calls:   status_set_message, exline_cancel_core, init_teardown
;          (tail-JP).
; ----------------------------------------------------------------
cmd_quit:
    LD      A, (buffer_dirty)
    OR      A
    JR      NZ, .dirty
    JP      init_teardown               ; clean -> warm-boot
.dirty:
    LD      HL, msg_no_write
    XOR     A
    CALL    status_set_message
    JP      exline_cancel_core          ; banner survives


;; ============================================================
;; --- Public entry: cmd_quit_force (':q!' handler) ---
;; ============================================================

; ----------------------------------------------------------------
; cmd_quit_force
; ':q!' — unconditional warm-boot. The '!' is the user's explicit
; consent to abandon any unsaved changes (FR8 / BH5). No
; buffer_dirty check.
;
; Entered via tail-JP from exline_dispatch on the 'q!' match.
;
; In:      (none)
; Out:     control transfers to CCP via init_teardown (no return
;          on a real host).
; Trashes: A, BC, DE, HL, F.
; Calls:   init_teardown (tail-JP).
; ----------------------------------------------------------------
cmd_quit_force:
    JP      init_teardown


;; ============================================================
;; --- Internal helper: exline_compose_status ---
;; ============================================================

; ----------------------------------------------------------------
; exline_compose_status
; Build ":<ex_buffer payload>\0" in exline_status_scratch and
; hand it to status_set_message. Tail-JP so the funnel's RET
; returns to whoever called us.
;
; In:      (none — reads ex_buffer + ex_buffer_text)
; Out:     status_buffer populated (':' + payload + space-pad);
;          status_dirty set (by status_set_message).
; Trashes: A, BC, DE, HL, F.
; Calls:   status_set_message (tail-JP).
; ----------------------------------------------------------------
exline_compose_status:
    LD      HL, exline_status_scratch
    LD      (HL), ':'
    INC     HL
    LD      A, (ex_buffer)              ; length
    OR      A
    JR      Z, .terminate
    LD      B, A
    LD      DE, ex_buffer_text
.copy:
    LD      A, (DE)
    LD      (HL), A
    INC     DE
    INC     HL
    DJNZ    .copy
.terminate:
    XOR     A
    LD      (HL), A                     ; NUL-terminate
    LD      HL, exline_status_scratch
    XOR     A                           ; non-error code arg (AR16)
    JP      status_set_message          ; tail-JP


;; ============================================================
;; --- Data: exline_command_table ---
;; ============================================================
; Layout per entry: NUL-terminated key string, then 2-byte
; handler address (little-endian DEFW). Table terminated by a
; single zero byte (a zero-length key). Stories 2.2 / 2.4 / 3.1
; extend by inserting entries before the terminator.

exline_command_table:
    DEFB    "q", 0                      ; entry 0: ':q'  (length 1)
    DEFW    cmd_quit
    DEFB    "q!", 0                     ; entry 1: ':q!' (length 2)
    DEFW    cmd_quit_force
    DEFB    0                           ; terminator (zero-length key)


;; ============================================================
;; --- Data: exline_status_scratch ---
;; ============================================================
; Module-local scratch for exline_compose_status. 1 ':' prefix +
; up to EX_COMMAND_BUFFER (64) payload bytes + 1 NUL = 66 bytes.
; Lives in the code segment between routines per render.asm's
; precedent (module-local scratch is NOT declared in state.inc).

exline_status_scratch:
    DEFS    66, 0
    ASSERT  $ - exline_status_scratch >= 1 + EX_COMMAND_BUFFER + 1
