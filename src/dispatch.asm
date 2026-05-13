; ============================================================
; Module: dispatch.asm
; Purpose: Mode-keyed dispatcher (MC3). dispatch_key binary-
;          searches a per-mode sparse sorted (key, handler_addr)
;          table and transfers control to the matching handler;
;          on miss it falls through to the per-mode unbound-
;          key handler. Owns the four mode tables, the four
;          mode-change handlers, and the four unbound handlers.
;          Pure metadata module — no buffer mutation (AR14),
;          no screen emission (AR13), no raw BDOS (AR15: the
;          single BDOS use site is BDOS_CALL BDOS_EXIT in
;          mode_debug_quit).
;
;          Mode-state coupling captured here (one third of the
;          deferred state.inc protocol, Story 1.3 deferral): a
;          MODE_VISUAL value in mode_byte ALWAYS implies
;          visual_submode is one of VIS_CHAR / VIS_LINE /
;          VIS_BLOCK; on every Esc-to-NORMAL transition the
;          mode-change handler does NOT clear visual_submode
;          (the value is meaningless in non-visual modes and
;          the next visual entry overwrites it).
;
;          Table layout convention: each per-mode table starts
;          with a 2-byte unbound-handler address, followed by
;          DISPATCH_*_COUNT entries of (1-byte key, 2-byte
;          handler addr) sorted ascending by key (ASCII byte
;          order — UPPERCASE letters sort BEFORE lowercase).
;
; Public:
;   dispatch_key                  ; binary-search dispatcher
;   dispatch_normal               ; mode tables (head = unbound prefix + entries)
;   dispatch_insert
;   dispatch_command
;   dispatch_visual
;   unbound_normal                ; per-mode unbound-key handlers
;   unbound_insert
;   unbound_command
;   unbound_visual
;   enter_normal_mode             ; mode-change handlers (FR12-16)
;   enter_insert_mode
;   enter_command_mode
;   enter_visual_mode
;   mode_full_refresh_stub        ; Ctrl-L  — Story 1.11 lands real
;   mode_search_prompt_stub       ; /       — Story 3.1 lands real
;   mode_debug_quit               ; Ctrl-Q  — tail-JP to init_teardown
;   DISPATCH_NORMAL_COUNT         ; per-table entry-count equates
;   DISPATCH_INSERT_COUNT
;   DISPATCH_COMMAND_COUNT
;   DISPATCH_VISUAL_COUNT
;
; State owned (read/write):
;   (none — dispatch is stateless. Mode-change handlers WRITE
;    mode_byte and visual_submode; no module-local statics.)
;
; Register conventions (across public entry points):
;   dispatch_key:      In:  A = key, HL = mode-table base
;                           (= unbound prefix), B = entry count.
;                      Out: control transfers (RET-to-pushed) to
;                           the matched handler or to the per-
;                           mode unbound handler. A = key on
;                           handler entry (MC4).
;                      Trashes: A, BC, DE, HL, IX, F (caller-
;                           saved per MC1; the handler is
;                           transitively responsible for any
;                           further clobbers — status_set_message
;                           trashes A, BC, DE, HL, F).
;                      Calls: target handler or unbound (via RET
;                             to pushed address).
;
;   Mode-change / stub / unbound handlers:
;                      In:  A = key just consumed (MC4); not all
;                           handlers inspect it.
;                      Out: side effects on mode_byte /
;                           visual_submode and/or status-line
;                           (via status_set_message). RET to
;                           dispatch_key's caller.
;                      Trashes: A, BC, DE, HL, F (status_set_message).
;                      Calls: status_set_message (most), or
;                             init_teardown via tail-JP
;                             (mode_debug_quit — see src/init.asm).
;
; Dependencies:
;   inc/modes.inc    (MODE_NORMAL/INSERT/COMMAND/VISUAL, VIS_CHAR)
;   inc/state.inc    (mode_byte, visual_submode)
;   src/statusln.asm (status_set_message + msg_mode_*,
;                     msg_unbound_key, msg_not_implemented)
;   src/parser.asm   (Story 1.10 — parser_handle_digit,
;                     parser_handle_operator,
;                     parser_handle_motion_prefix; referenced
;                     by dispatch_normal's '0'..'9', operators,
;                     and 'g' entries — forward-referenced via
;                     sjasmplus two-pass assembly)
;   src/render.asm   (Story 1.11 — render_full, the real Ctrl-L
;                     full-redraw target; replaces the Story 1.5
;                     stub body of mode_full_refresh_stub)
;   src/init.asm     (Story 1.12 — init_teardown, for
;                     mode_debug_quit's screen-clear-on-exit path)
; ============================================================

;; ============================================================
;; --- Public entry: dispatch_key (MC3 binary search) ---
;; ============================================================

; ----------------------------------------------------------------
; dispatch_key
; Binary-search a per-mode sparse sorted (key, handler_addr)
; table for the supplied key. On hit, transfer control to the
; matched handler with A = key (MC4). On miss, transfer control
; to the per-mode unbound-key handler (whose 2-byte address
; lives in the table's leading prefix), again with A = key.
;
; Worst case: ceil(log2(B)) + 1 iterations. Epic 1's largest
; table is dispatch_normal at 9 entries → 4 iterations; the
; architecture envelope (B = 64) yields 6 iterations.
;
; Stack discipline: on entry the unbound handler address is
; pushed onto the stack as the RET-on-miss target (Z80
; "RET-to-pushed-address" idiom). On hit, the unbound is
; POPped-and-discarded and the handler addr is PUSHed in its
; place, again landed via RET-to-pushed. Both paths end with
; the stack restored to caller's frame and control transferred
; with A = key.
;
; In:      A  = key (1 byte: ASCII 0x00..0x7F or KEY_ARROW_*
;               0x80..0x83)
;          HL = base of the per-mode dispatch table (i.e. the
;               address of the 2-byte unbound prefix)
;          B  = entry count (NOT including the unbound prefix);
;               equals DISPATCH_*_COUNT for the matching table
; Out:     control transferred (no normal return); A = key on
;          handler entry; the called handler RETs to
;          dispatch_key's caller.
; Trashes: A, BC, DE, HL, IX, F (handler may trash more)
; Calls:   target handler / per-mode unbound handler (via RET
;          to a pushed address).
; ----------------------------------------------------------------
dispatch_key:
    LD      C, A                ; C = key (preserved through search loop)
    LD      E, (HL)
    INC     HL
    LD      D, (HL)
    INC     HL                  ; DE = unbound addr; HL = first entry
    PUSH    DE                  ; unbound on stack — RET-on-miss target
    PUSH    HL
    POP     IX                  ; IX = entries base (cached for offset compute)
    LD      D, 0                ; D = lo (inclusive)
    LD      E, B                ; E = hi (exclusive) = entry count
.search:
    LD      A, E
    SUB     D                   ; A = hi - lo (no underflow: lo <= hi always)
    JR      Z, .miss            ; lo == hi → not found, fall through to unbound
    SRL     A                   ; A = (hi - lo) / 2
    ADD     A, D                ; A = mid = lo + (hi - lo) / 2
    LD      B, A                ; B = mid (saved across compare for hi/lo update)

    ;; --- Compute HL = base + mid*3 (entry pointer) ---
    PUSH    DE                  ; save lo/hi
    LD      H, 0
    LD      L, A                ; HL = mid
    LD      D, H
    LD      E, L                ; DE = mid
    ADD     HL, HL              ; HL = mid * 2
    ADD     HL, DE              ; HL = mid * 3
    POP     DE                  ; restore lo/hi
    PUSH    BC                  ; save mid (B) and key (C)
    PUSH    IX
    POP     BC                  ; BC = base
    ADD     HL, BC              ; HL = base + mid*3 = entry pointer
    POP     BC                  ; restore mid (B), key (C)

    ;; --- Compare entry-key vs search-key ---
    LD      A, (HL)             ; A = entry-key at mid
    CP      C                   ; flags only: Z = match; CF = A<C; NC = A>=C
    JR      Z, .found
    JR      C, .key_higher      ; entry-key < search-key → search right
    ;; entry-key > search-key → search left: hi := mid
    LD      E, B
    JR      .search

.key_higher:
    LD      A, B
    INC     A                   ; lo := mid + 1
    LD      D, A
    JR      .search

.found:
    INC     HL                  ; HL → addr-low byte of entry
    LD      E, (HL)
    INC     HL
    LD      D, (HL)             ; DE = handler addr (little-endian)
    POP     HL                  ; discard pushed unbound
    PUSH    DE                  ; handler addr on stack — RET-to-pushed target
    LD      A, C                ; restore A = key (MC4)
    RET                         ; "RET to handler" — Z80 idiom

.miss:
    LD      A, C                ; restore A = key (MC4)
    RET                         ; "RET to unbound" — pops the entry-time PUSH


;; ============================================================
;; --- Mode-change handlers (FR12-FR16) ---
;; ============================================================

; ----------------------------------------------------------------
; enter_normal_mode
; Entry from Esc in INSERT / COMMAND / VISUAL (FR16). Writes
; MODE_NORMAL to mode_byte and clears the mode indicator (the
; empty msg_mode_normal pads status_buffer with spaces — vi
; convention is "no banner in normal mode").
;
; In:      A = key just consumed (MC4; usually VT52_ESC = 0x1B)
; Out:     mode_byte = MODE_NORMAL; status_buffer cleared;
;          status_dirty set
; Trashes: A, BC, DE, HL, F (via status_set_message)
; Calls:   status_set_message
; ----------------------------------------------------------------
enter_normal_mode:
    LD      A, MODE_NORMAL
    LD      (mode_byte), A
    LD      HL, msg_mode_normal
    XOR     A                   ; non-error code arg (AR16 convention)
    CALL    status_set_message
    RET

; ----------------------------------------------------------------
; enter_insert_mode
; Entry from i / a / o / O in normal mode (FR13; Epic 1 stubs
; for FR25-FR27 also route here). Writes MODE_INSERT to
; mode_byte and shows "-- insert --" in the status line (FR17).
;
; In:      A = key just consumed (MC4; one of i/a/o/O)
; Out:     mode_byte = MODE_INSERT; status indicator shown
; Trashes: A, BC, DE, HL, F
; Calls:   status_set_message
; ----------------------------------------------------------------
enter_insert_mode:
    LD      A, MODE_INSERT
    LD      (mode_byte), A
    LD      HL, msg_mode_insert
    XOR     A
    CALL    status_set_message
    RET

; ----------------------------------------------------------------
; enter_command_mode
; Entry from ':' in normal mode (FR14). Concrete ':'-line edit
; handlers land in Story 2.1; this handler only flips mode and
; surfaces the "-- command --" indicator.
;
; In:      A = ':' (MC4)
; Out:     mode_byte = MODE_COMMAND; status indicator shown
; Trashes: A, BC, DE, HL, F
; Calls:   status_set_message
; ----------------------------------------------------------------
enter_command_mode:
    LD      A, MODE_COMMAND
    LD      (mode_byte), A
    LD      HL, msg_mode_command
    XOR     A
    CALL    status_set_message
    RET

; ----------------------------------------------------------------
; enter_visual_mode
; Entry from 'v' in normal mode (FR15). Sets visual_submode to
; VIS_CHAR per AC7 ("update mode_byte and visual_submode if
; entering visual"); concrete visual handlers land in Story 3.3.
;
; In:      A = 'v' (MC4)
; Out:     mode_byte = MODE_VISUAL; visual_submode = VIS_CHAR;
;          status indicator shown
; Trashes: A, BC, DE, HL, F
; Calls:   status_set_message
; ----------------------------------------------------------------
enter_visual_mode:
    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A
    LD      HL, msg_mode_visual
    XOR     A
    CALL    status_set_message
    RET


;; ============================================================
;; --- Epic-1 stub handlers ---
;; ============================================================

; ----------------------------------------------------------------
; mode_full_refresh_stub
; Ctrl-L full-redraw handler (FR48, NFR7). Bound to 0x0C in
; dispatch_normal. The Story 1.5 stub body (msg_not_implemented)
; was replaced by Story 1.11 with a tail-JP into render_full;
; see src/render.asm. The `_stub` suffix is retained so the
; dispatch_normal table entry need not move.
;
; In:      A = 0x0C (MC4)
; Out:     screen fully redrawn from buffer state (FR48, NFR7);
;          shadow_buffer synced; dirty_rows cleared; cursor
;          repositioned (RI4).
; Trashes: A, BC, DE, HL, IX, F (render_full's transitive clobber)
; Calls:   render_full (tail-JP)
; ----------------------------------------------------------------
mode_full_refresh_stub:
    JP      render_full

; ----------------------------------------------------------------
; mode_search_prompt_stub
; Bound to '/' in dispatch_normal. Story 3.1 replaces with the
; real forward-search prompt path.
;
; In:      A = '/' (MC4)
; Out:     status line = "not yet implemented"
; Trashes: A, BC, DE, HL, F
; Calls:   status_set_message
; ----------------------------------------------------------------
mode_search_prompt_stub:
    LD      HL, msg_not_implemented
    XOR     A
    CALL    status_set_message
    RET

; ----------------------------------------------------------------
; mode_debug_quit
; TEMPORARY exit handler — bound to Ctrl-Q (0x11) for the
; Story 1.12 hardware bring-up. Tail-JPs to `init_teardown`
; (src/init.asm), which clears the screen + warm-boots to CCP.
; Removed in Story 2.1 when `:q` / `:q!` arrive as the proper
; vi exit mechanism.
;
; In:      A = 0x11 (MC4)
; Out:     does not return on a real CP/M host (init_teardown
;          warm-boots via BDOS function 0; defensive RET in
;          init_teardown returns here only on a misconfigured
;          BIOS — then RETs to dispatch_key's caller back into
;          the input loop, preserving NFR5).
; Trashes: A, BC, DE, HL, F (init_teardown's chain)
; Calls:   init_teardown (tail-JP — handles screen-clear +
;          warm-boot; see src/init.asm)
; ----------------------------------------------------------------
mode_debug_quit:
    JP      init_teardown


;; ============================================================
;; --- Per-mode unbound-key handlers (FR50) ---
;; ============================================================

; ----------------------------------------------------------------
; unbound_normal
; Entered from dispatch_key when the key is not in dispatch_normal.
; Per AC4: leaves all editor state unchanged (mode_byte,
; cursor_offset, visual_anchor, count_accumulator,
; pending_operator, pending_motion_prefix all unchanged) and
; surfaces a status-line "unbound key" message — the Epic-1
; surrogate for a beep. Does NOT call the BIOS console-out
; vector — only render.asm + init.asm emit screen bytes (AR13).
;
; In:      A = key just consumed (MC4)
; Out:     status line = "unbound key"
; Trashes: A, BC, DE, HL, F
; Calls:   status_set_message
; ----------------------------------------------------------------
unbound_normal:
    LD      HL, msg_unbound_key
    XOR     A
    CALL    status_set_message
    RET

; ----------------------------------------------------------------
; unbound_visual
; Symmetric with unbound_normal (architecture line 520 treats
; normal/visual unbound the same way for Epic 1).
;
; In:      A = key just consumed (MC4)
; Out:     status line = "unbound key"
; Trashes: A, BC, DE, HL, F
; Calls:   status_set_message
; ----------------------------------------------------------------
unbound_visual:
    LD      HL, msg_unbound_key
    XOR     A
    CALL    status_set_message
    RET

; ----------------------------------------------------------------
; unbound_insert
; Entered from dispatch_key when the key is not in dispatch_insert
; (i.e. anything other than Esc — printable letters, control
; bytes, KEY_ARROW_* synthesized codes). Story 1.9 stubs this as
; a silent no-op; Story 2.8 lands the literal-byte insertion
; path that Epic 2 needs.
;
; This handler MUST NOT crash on any A — Esc is the only key
; that ever escapes INSERT mode (FR16), so a crash here would
; trap the user in INSERT permanently.
;
; In:      A = key just consumed (MC4) — ignored by this stub
; Out:     (none)
; Trashes: F (RET only — no status write to keep the keystroke
;          silent and avoid filling the status line on every
;          keypress in INSERT mode pre-2.8)
; Calls:   (none)
; ----------------------------------------------------------------
unbound_insert:
    RET

; ----------------------------------------------------------------
; unbound_command
; Entered from dispatch_key when the key is not in dispatch_command
; (i.e. anything other than Esc). Story 2.1 lands the real
; ex-line edit path; Story 1.9 stubs as a silent no-op.
;
; In:      A = key just consumed (MC4) — ignored by this stub
; Out:     (none)
; Trashes: F
; Calls:   (none)
; ----------------------------------------------------------------
unbound_command:
    RET


;; ============================================================
;; --- Per-mode dispatch tables (MC3) ---
;; ============================================================
; Layout (each table):
;   DEFW unbound_handler            ; 2-byte unbound prefix
;   DEFB key0  : DEFW handler0      ; entries sorted ascending
;   DEFB key1  : DEFW handler1      ; by ASCII key byte
;   ...
; DISPATCH_*_COUNT EQU (entries-end - entries-start) / 3
;
; ASCII-byte sort note: UPPERCASE letters sort BEFORE lowercase.
; e.g. 'O' (0x4F) < 'a' (0x61). The binary search uses byte
; ordering, NOT alphabet-as-humans-see-it. The inline ASSERT
; between consecutive entries catches a swap-typo at build time
; (a swap of e.g. 'i' and 'a' would otherwise compile cleanly
; since both route to enter_insert_mode — invisible at run time
; until a user pressed a key that landed on the wrong side of
; the bad pair).

dispatch_normal:
    DEFW    unbound_normal
.entries:
    DEFB    0x0C                        ; Ctrl-L  — full refresh stub (FR48)
    DEFW    mode_full_refresh_stub
    ASSERT  0x11 > 0x0C
    DEFB    0x11                        ; Ctrl-Q  — debug-quit (temporary)
    DEFW    mode_debug_quit
    ASSERT  '/' > 0x11
    DEFB    '/'                         ; '/'     — search prompt stub (3.1)
    DEFW    mode_search_prompt_stub
    ASSERT  '0' > '/'
    DEFB    '0'                         ; '0'     — leading-zero handled
    DEFW    parser_handle_digit         ;            inside the parser (FR21)
    ASSERT  '1' > '0'
    DEFB    '1'                         ; '1'..'9' — count accumulator (FR23)
    DEFW    parser_handle_digit
    ASSERT  '2' > '1'
    DEFB    '2'
    DEFW    parser_handle_digit
    ASSERT  '3' > '2'
    DEFB    '3'
    DEFW    parser_handle_digit
    ASSERT  '4' > '3'
    DEFB    '4'
    DEFW    parser_handle_digit
    ASSERT  '5' > '4'
    DEFB    '5'
    DEFW    parser_handle_digit
    ASSERT  '6' > '5'
    DEFB    '6'
    DEFW    parser_handle_digit
    ASSERT  '7' > '6'
    DEFB    '7'
    DEFW    parser_handle_digit
    ASSERT  '8' > '7'
    DEFB    '8'
    DEFW    parser_handle_digit
    ASSERT  '9' > '8'
    DEFB    '9'
    DEFW    parser_handle_digit
    ASSERT  ':' > '9'
    DEFB    ':'                         ; ':'     — enter command (FR14)
    DEFW    enter_command_mode
    ASSERT  '<' > ':'
    DEFB    '<'                         ; '<'     — operator (FR39)
    DEFW    parser_handle_operator
    ASSERT  '>' > '<'
    DEFB    '>'                         ; '>'     — operator (FR39)
    DEFW    parser_handle_operator
    ASSERT  'O' > '>'
    DEFB    'O'                         ; 'O'     — Epic 1 stub for FR27
    DEFW    enter_insert_mode
    ASSERT  'a' > 'O'
    DEFB    'a'                         ; 'a'     — Epic 1 stub for FR25
    DEFW    enter_insert_mode
    ASSERT  'c' > 'a'
    DEFB    'c'                         ; 'c'     — operator (FR39)
    DEFW    parser_handle_operator
    ASSERT  'd' > 'c'
    DEFB    'd'                         ; 'd'     — operator (FR39, FR40)
    DEFW    parser_handle_operator
    ASSERT  'g' > 'd'
    DEFB    'g'                         ; 'g'     — motion prefix (FR22)
    DEFW    parser_handle_motion_prefix
    ASSERT  'i' > 'g'
    DEFB    'i'                         ; 'i'     — enter insert (FR13)
    DEFW    enter_insert_mode
    ASSERT  'o' > 'i'
    DEFB    'o'                         ; 'o'     — Epic 1 stub for FR26
    DEFW    enter_insert_mode
    ASSERT  'v' > 'o'
    DEFB    'v'                         ; 'v'     — enter visual (FR15)
    DEFW    enter_visual_mode
    ASSERT  'y' > 'v'
    DEFB    'y'                         ; 'y'     — operator (FR39, FR40)
    DEFW    parser_handle_operator
DISPATCH_NORMAL_COUNT EQU ($ - .entries) / 3

dispatch_insert:
    DEFW    unbound_insert
.entries:
    DEFB    0x1B                        ; Esc — return to NORMAL (FR16)
    DEFW    enter_normal_mode
DISPATCH_INSERT_COUNT EQU ($ - .entries) / 3

dispatch_command:
    DEFW    unbound_command
.entries:
    DEFB    0x1B                        ; Esc — return to NORMAL (FR16)
    DEFW    enter_normal_mode
DISPATCH_COMMAND_COUNT EQU ($ - .entries) / 3

dispatch_visual:
    DEFW    unbound_visual
.entries:
    DEFB    0x1B                        ; Esc — return to NORMAL (FR16)
    DEFW    enter_normal_mode
DISPATCH_VISUAL_COUNT EQU ($ - .entries) / 3
