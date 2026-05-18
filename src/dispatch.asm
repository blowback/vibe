; ============================================================
; Module: dispatch.asm
; Purpose: Mode-keyed dispatcher (MC3). dispatch_key binary-
;          searches a per-mode sparse sorted (key, handler_addr)
;          table and transfers control to the matching handler;
;          on miss it falls through to the per-mode unbound-
;          key handler. Owns the four mode tables, the four
;          mode-change handlers, and the four unbound handlers.
;          Pure metadata module — no buffer mutation (AR14),
;          no screen emission (AR13), no raw BDOS (AR15: clean
;          — Story 2.1 retired the Story-1.12 mode_debug_quit
;          BDOS_CALL BDOS_EXIT carve-out when :q / :q! arrived
;          via exline.asm).
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
;   unbound_visual
;   enter_normal_mode             ; mode-change handlers (FR12-16)
;   enter_insert_mode
;   enter_visual_mode
;   mode_full_refresh_stub        ; Ctrl-L  — Story 1.11 lands real
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
;                      Calls: status_set_message (most).
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
;   src/exline.asm   (Story 2.1 — exline_begin (':' entry),
;                     exline_append_literal (unbound-prefix in
;                     dispatch_command), exline_backspace,
;                     exline_dispatch, exline_cancel; all
;                     forward-referenced via sjasmplus two-pass)
;   src/motions.asm  (Story 2.5 — motion_h / motion_j / motion_k
;                     / motion_l forward-referenced from
;                     dispatch_normal; parser_clear tail-JPs from
;                     mode-change and unbound handlers per AC13.
;                     Story 2.6 — motion_dollar / motion_G /
;                     motion_b / motion_w added as four new
;                     dispatch_normal entries; motion_0 / motion_gg
;                     are NOT direct dispatch entries — they
;                     dispatch from parser.asm's leading-zero and
;                     doubled-g arms)
;   src/parser.asm   (Story 2.5 — parser_clear is the AC13
;                     tail-JP target of every mode-change and
;                     unbound handler; was already a dependency
;                     for dispatch_normal's digit / operator /
;                     motion-prefix entries)
;   src/edits.asm    (Story 2.8 — edits_enter_insert_after /
;                     edits_open_below / edits_open_above replace
;                     the Epic-1 enter_insert_mode stubs at
;                     dispatch_normal's 'a' / 'o' / 'O' entries
;                     ('i' stays on enter_insert_mode);
;                     edits_insert_backspace + edits_insert_newline
;                     forward-referenced from the grown
;                     dispatch_insert table; edits_insert_literal
;                     forward-referenced from unbound_insert's
;                     swapped body. All resolved by sjasmplus's
;                     two-pass model because edits.asm INCLUDEs
;                     after dispatch.asm in vibe.asm's AR25 chain.
;                     Story 2.9 — edits_delete_char added as the
;                     new dispatch_normal 'x' entry (FR28; the
;                     first NORMAL-mode mutating operator); slot
;                     count grows 32 → 33.
;                     Story 2.12 — op_paste added as the new
;                     dispatch_normal 'p' entry (FR32; paste from
;                     yank register — KIND_CHAR / KIND_LINE /
;                     KIND_BLOCK-reserved discrimination; second
;                     non-trivial reader of the SR6 yank register);
;                     slot count grows 33 → 34. Inserted between
;                     'o' (open-below) and 'v' (enter-visual) at
;                     the sorted-ascending key position.)
;   src/search.asm   (Story 3.1 — search_begin replaces the retired
;                     mode_search_prompt_stub at dispatch_normal's
;                     '/' entry; FR41. The stub body is gone — the
;                     entry now points directly at search_begin in
;                     src/search.asm. Forward-referenced via
;                     sjasmplus two-pass since search.asm INCLUDEs
;                     after dispatch.asm in vibe.asm's AR25 chain.)
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
; Tail-JPs parser_clear (Story 2.5 AC13) so any pending count /
; operator / motion-prefix from a previous NORMAL-mode keystroke
; doesn't leak across the Esc-to-NORMAL transition. Vi-spirit:
; Esc cancels the in-progress command; stale parser state goes
; with it.
;
; In:      A = key just consumed (MC4; usually VT52_ESC = 0x1B)
; Out:     mode_byte = MODE_NORMAL; status_buffer cleared;
;          status_dirty set; count_accumulator = 0;
;          pending_operator = 0; pending_motion_prefix = 0.
; Trashes: A, BC, DE, HL, F (via status_set_message + parser_clear)
; Calls:   status_set_message; parser_clear (tail-JP)
; ----------------------------------------------------------------
enter_normal_mode:
    ;; Story 2.13 INSERT-session exit hook (B2 — insert sessions undo
    ;; as a single unit; FR45). If mode_byte was MODE_INSERT, this is
    ;; the Esc-from-INSERT exit point — invoke the exit recorder BEFORE
    ;; the MODE_NORMAL write (the recorder reads cursor_offset and
    ;; insert_session_entry_cursor to compute the session delta; it
    ;; does NOT touch mode_byte). Esc-from-COMMAND and Esc-from-VISUAL
    ;; arrive here too (via dispatch_command / dispatch_visual entries);
    ;; the CP MODE_INSERT guard ensures the hook only fires on the
    ;; INSERT exit path.
    LD      A, (mode_byte)
    CP      MODE_INSERT
    CALL    Z, undo_insert_exit_record
    LD      A, MODE_NORMAL
    LD      (mode_byte), A
    LD      HL, msg_mode_normal
    XOR     A                   ; non-error code arg (AR16 convention)
    CALL    status_set_message
    JP      parser_clear

; ----------------------------------------------------------------
; enter_insert_mode
; Entry from i / a / o / O in normal mode (FR13; Epic 1 stubs
; for FR25-FR27 also route here). Writes MODE_INSERT to
; mode_byte and shows "-- insert --" in the status line (FR17).
;
; Tail-JPs parser_clear (Story 2.5 AC13) so any count / operator
; from before the mode change doesn't bleed into the INSERT
; session. Vibe doesn't support "5i = insert 5 times" (the count
; semantics would be Story 2.8+'s decision); for Story 2.5 the
; pending state is dead weight and is dropped.
;
; In:      A = key just consumed (MC4; one of i/a/o/O)
; Out:     mode_byte = MODE_INSERT; status indicator shown;
;          parser state zeroed.
; Trashes: A, BC, DE, HL, F
; Calls:   status_set_message; parser_clear (tail-JP)
; ----------------------------------------------------------------
enter_insert_mode:
    ;; Story 2.13 INSERT-session entry hook (B2; FR45). Save the entry
    ;; cursor BEFORE the mode write so the exit hook in enter_normal_mode
    ;; / edits_overflow_to_normal can compute the session delta. Covers
    ;; all five user-visible INSERT entry paths: `i` (this binding) +
    ;; `a` (edits_enter_insert_after's tail-JP) + `o` / `O`
    ;; (edits_open_below / _above tail-JP via edits_open_success_tail) +
    ;; `c`+motion (op_compose_c tail-JP). For the c+motion case, phase 1
    ;; of the REPLACE protocol has already written UNDO_KIND_DELETE +
    ;; saved the old content to undo_buffer; the exit hook reads that
    ;; kind and upgrades to UNDO_KIND_REPLACE.
    LD      HL, (cursor_offset)
    LD      (insert_session_entry_cursor), HL
    LD      A, MODE_INSERT
    LD      (mode_byte), A
    LD      HL, msg_mode_insert
    XOR     A
    CALL    status_set_message
    JP      parser_clear

; ----------------------------------------------------------------
; enter_visual_mode
; Entry from 'v' in normal mode (FR15). Sets visual_submode to
; VIS_CHAR per AC7 ("update mode_byte and visual_submode if
; entering visual"); concrete visual handlers land in Story 3.3.
;
; Tail-JPs parser_clear (Story 2.5 AC13) — same rationale as
; enter_insert_mode.
;
; In:      A = 'v' (MC4)
; Out:     mode_byte = MODE_VISUAL; visual_submode = VIS_CHAR;
;          status indicator shown; parser state zeroed.
; Trashes: A, BC, DE, HL, F
; Calls:   status_set_message; parser_clear (tail-JP)
; ----------------------------------------------------------------
enter_visual_mode:
    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A
    LD      HL, msg_mode_visual
    XOR     A
    CALL    status_set_message
    JP      parser_clear


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

;; ============================================================
;; --- Per-mode unbound-key handlers (FR50) ---
;; ============================================================

; ----------------------------------------------------------------
; unbound_normal
; Entered from dispatch_key when the key is not in dispatch_normal.
; Surfaces a status-line "unbound key" message — the Epic-1
; surrogate for a beep. Does NOT call the BIOS console-out
; vector — only render.asm + init.asm emit screen bytes (AR13).
;
; Tail-JPs parser_clear (Story 2.5 AC13) so a stale count or
; operator doesn't survive an unbound keystroke. Story 1.10's
; deferred entry called this out: `5 g x` (x unbound) leaving
; count=5 and prefix='g' pending would make the NEXT 'g' fire
; the gg-stub spuriously. The tail-JP closes that.
;
; The AC4-preserves-state guarantee from Story 1.9 is updated
; here: mode_byte / cursor_offset / visual_anchor are still
; unchanged, but the three parser-state fields are intentionally
; zeroed.
;
; In:      A = key just consumed (MC4)
; Out:     status line = "unbound key"; parser state zeroed.
; Trashes: A, BC, DE, HL, F
; Calls:   status_set_message; parser_clear (tail-JP)
; ----------------------------------------------------------------
unbound_normal:
    LD      HL, msg_unbound_key
    XOR     A
    CALL    status_set_message
    JP      parser_clear

; ----------------------------------------------------------------
; unbound_visual
; Symmetric with unbound_normal (architecture line 520 treats
; normal/visual unbound the same way for Epic 1). Tail-JPs
; parser_clear for the same reason (Story 2.5 AC13).
;
; In:      A = key just consumed (MC4)
; Out:     status line = "unbound key"; parser state zeroed.
; Trashes: A, BC, DE, HL, F
; Calls:   status_set_message; parser_clear (tail-JP)
; ----------------------------------------------------------------
unbound_visual:
    LD      HL, msg_unbound_key
    XOR     A
    CALL    status_set_message
    JP      parser_clear

; ----------------------------------------------------------------
; unbound_insert
; Entered from dispatch_key when the key is not in dispatch_insert
; (post-Story-2.8: anything other than Backspace 0x08, Enter 0x0D,
; Esc 0x1B — printable letters, high-bit bytes, KEY_ARROW_*
; synthesized codes, control bytes not bound above). Story 2.8
; replaced the 1.9 silent-RET stub body with a tail-JP into
; edits_insert_literal — the literal-byte insertion path that
; Epic 2 needs. The control-byte filter (A < 0x20) lives inside
; edits_insert_literal; bytes that fail the filter still surface
; as the silent no-op the 1.9 stub provided, just one level deeper.
;
; This handler MUST NOT crash on any A — Esc is the only key
; that ever escapes INSERT mode (FR16), so a crash here would
; trap the user in INSERT permanently. edits_insert_literal's
; overflow path exits INSERT cleanly (msg_file_too_large +
; mode -> NORMAL) without crashing.
;
; In:      A = key just consumed (MC4).
; Out:     control transferred to edits_insert_literal. On the
;          filter-rejected path (A < 0x20 or A >= 0x7F) A is
;          preserved as the silent no-op returns; on the
;          success path gapbuf_insert clobbers A. Caller MUST
;          NOT rely on A across this call.
; Trashes: A, BC, DE, HL, F (transitively via edits_insert_literal
;          → gapbuf_insert + render_mark_all_dirty).
; Calls:   edits_insert_literal (tail-JP).
; ----------------------------------------------------------------
unbound_insert:
    JP      edits_insert_literal


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
    ASSERT  '$' > 0x0C
    DEFB    '$'                         ; '$'     — motion to line-end (FR21, Story 2.6)
    DEFW    motion_dollar
    ASSERT  '/' > '$'
    DEFB    '/'                         ; '/'     — search prompt (FR41, Story 3.1)
    DEFW    search_begin
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
    DEFB    ':'                         ; ':'     — exline_begin (FR14, Story 2.1)
    DEFW    exline_begin
    ASSERT  '<' > ':'
    DEFB    '<'                         ; '<'     — operator (FR39)
    DEFW    parser_handle_operator
    ASSERT  '>' > '<'
    DEFB    '>'                         ; '>'     — operator (FR39)
    DEFW    parser_handle_operator
    ASSERT  'G' > '>'
    DEFB    'G'                         ; 'G'     — motion to last line (FR22, Story 2.6)
    DEFW    motion_G
    ASSERT  'O' > 'G'
    DEFB    'O'                         ; 'O'     — open line above (FR27, Story 2.8)
    DEFW    edits_open_above
    ASSERT  'a' > 'O'
    DEFB    'a'                         ; 'a'     — append after cursor (FR25, Story 2.8)
    DEFW    edits_enter_insert_after
    ASSERT  'b' > 'a'
    DEFB    'b'                         ; 'b'     — motion back-word (FR20, Story 2.6)
    DEFW    motion_b
    ASSERT  'c' > 'b'
    DEFB    'c'                         ; 'c'     — operator (FR39)
    DEFW    parser_handle_operator
    ASSERT  'd' > 'c'
    DEFB    'd'                         ; 'd'     — operator (FR39, FR40)
    DEFW    parser_handle_operator
    ASSERT  'g' > 'd'
    DEFB    'g'                         ; 'g'     — motion prefix (FR22)
    DEFW    parser_handle_motion_prefix
    ASSERT  'h' > 'g'
    DEFB    'h'                         ; 'h'     — cursor left (FR18, Story 2.5)
    DEFW    motion_h
    ASSERT  'i' > 'h'
    DEFB    'i'                         ; 'i'     — enter insert (FR13)
    DEFW    enter_insert_mode
    ASSERT  'j' > 'i'
    DEFB    'j'                         ; 'j'     — cursor down (FR19, Story 2.5)
    DEFW    motion_j
    ASSERT  'k' > 'j'
    DEFB    'k'                         ; 'k'     — cursor up (FR19, Story 2.5)
    DEFW    motion_k
    ASSERT  'l' > 'k'
    DEFB    'l'                         ; 'l'     — cursor right (FR18, Story 2.5)
    DEFW    motion_l
    ASSERT  'o' > 'l'
    DEFB    'o'                         ; 'o'     — open line below (FR26, Story 2.8)
    DEFW    edits_open_below
    ASSERT  'p' > 'o'
    DEFB    'p'                         ; 'p'     — paste from yank register (FR32, Story 2.12)
    DEFW    op_paste
    ASSERT  'u' > 'p'
    DEFB    'u'                         ; 'u'     — single-level undo (FR45, Story 2.13)
    DEFW    op_undo
    ASSERT  'v' > 'u'
    DEFB    'v'                         ; 'v'     — enter visual (FR15)
    DEFW    enter_visual_mode
    ASSERT  'w' > 'v'
    DEFB    'w'                         ; 'w'     — motion forward-word (FR20, Story 2.6)
    DEFW    motion_w
    ASSERT  'x' > 'w'
    DEFB    'x'                         ; 'x'     — single-character delete (FR28, Story 2.9)
    DEFW    edits_delete_char
    ASSERT  'y' > 'x'
    DEFB    'y'                         ; 'y'     — operator (FR39, FR40)
    DEFW    parser_handle_operator
DISPATCH_NORMAL_COUNT EQU ($ - .entries) / 3

dispatch_insert:
    DEFW    unbound_insert
.entries:
    DEFB    0x08                        ; Backspace — delete byte before cursor (Story 2.8 AC6)
    DEFW    edits_insert_backspace
    ASSERT  0x0D > 0x08
    DEFB    0x0D                        ; Enter — translate 0x0D → 0x0A LF (Story 2.8 AC10)
    DEFW    edits_insert_newline
    ASSERT  0x1B > 0x0D
    DEFB    0x1B                        ; Esc — return to NORMAL (FR16)
    DEFW    enter_normal_mode
DISPATCH_INSERT_COUNT EQU ($ - .entries) / 3

dispatch_command:
    DEFW    exline_append_literal       ; unbound-prefix -> literal append (Story 2.1)
.entries:
    DEFB    0x08                        ; Backspace — exline_backspace
    DEFW    exline_backspace
    ASSERT  0x0D > 0x08
    DEFB    0x0D                        ; Enter — exline_dispatch (Story 2.1)
    DEFW    exline_dispatch
    ASSERT  0x1B > 0x0D
    DEFB    0x1B                        ; Esc — cancel (FR16, Story 2.1)
    DEFW    exline_cancel
DISPATCH_COMMAND_COUNT EQU ($ - .entries) / 3

dispatch_visual:
    DEFW    unbound_visual
.entries:
    DEFB    0x1B                        ; Esc — return to NORMAL (FR16)
    DEFW    enter_normal_mode
DISPATCH_VISUAL_COUNT EQU ($ - .entries) / 3
