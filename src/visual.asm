; ============================================================
; Module: visual.asm
; Purpose: Visual-mode entry / extent / status helpers (FR15, FR33).
;          Story 3.3 lands the VIS_CHAR surface: `v` from NORMAL
;          pins `visual_anchor` at the entry cursor; subsequent
;          mode-agnostic motions land at edits_compose_or_clear's
;          MODE_VISUAL arm and call visual_extend to recompute the
;          selection extent ( |cursor - anchor| + 1 ) and refresh
;          the "-- visual -- N" status row. Esc returns to NORMAL
;          via the existing src/dispatch.asm:enter_normal_mode —
;          no separate visual_cancel symbol needed (Q7 pin).
;
;          Pure reader of buffer state — AR13 (no BIOS console),
;          AR14 (no gap-buffer writes), AR15 (no raw BDOS) all
;          clean. The only side effects are writes to mode_byte /
;          visual_submode / visual_anchor (Story 3.3 LANDS) and
;          to status_buffer / status_dirty via the AR12 funnel
;          status_set_message. Motion handlers (motions.asm) keep
;          full responsibility for the cursor_offset write.
;
; Public:
;   visual_enter_char     ; LANDS Story 3.3 — `v` entry, VIS_CHAR
;   visual_extend         ; LANDS Story 3.3 — per-motion extent refresh
;   visual_enter_line     ; PLACEHOLDER Story 3.4 (V — line-wise selection)
;   visual_enter_block    ; PLACEHOLDER Story 3.5 (Ctrl-V — rectangular selection)
;   visual_apply_operator ; PLACEHOLDER Stories 3.6-3.8 (d/y/c/>/</~ on a selection)
;
;   (visual_cancel is NOT a separate symbol per Q7 pin Option A —
;    src/dispatch.asm:enter_normal_mode handles VISUAL→NORMAL
;    cleanly and was always documented as the VISUAL exit point.)
;
; State owned (read/write):
;   visual_anchor         ; 16-bit; WRITTEN by visual_enter_char ONLY
;                         ; (and by future visual_enter_line / _block).
;                         ; Frozen for the lifetime of the visual
;                         ; session — extend NEVER re-pins it; vi
;                         ; convention. READ by visual_extend (count
;                         ; math) and by future visual_apply_operator
;                         ; (range marshalling).
;   visual_submode        ; 1-byte; WRITTEN by visual_enter_char
;                         ; (VIS_CHAR). Stories 3.4 / 3.5 add the
;                         ; VIS_LINE / VIS_BLOCK writers. NOT cleared
;                         ; on VISUAL→NORMAL exit — zombie state
;                         ; until the next visual entry overwrites
;                         ; it; meaningless when mode_byte != MODE_VISUAL.
;
; State read-only:
;   cursor_offset         ; read by visual_enter_char (anchor pin)
;                         ; and by visual_extend (count math).
;   mode_byte             ; not read in this module — the MODE_VISUAL
;                         ; check happens at src/edits.asm's
;                         ; edits_compose_or_clear bare-motion arm
;                         ; (where the routing decision belongs).
;
; Register conventions (across public entry points):
;   visual_enter_char:
;       In:      A = 'v' (MC4 — ignored after dispatch)
;       Out:     mode_byte = MODE_VISUAL; visual_submode = VIS_CHAR;
;                visual_anchor = cursor_offset (frozen — never
;                re-written by extend); status_buffer pre-padded
;                with "-- visual -- 1"; status_dirty = 1; parser
;                state zeroed (count_accumulator / pending_operator
;                / pending_motion_prefix / pending_motion_inclusive).
;       Trashes: A, BC, DE, HL, F
;       Calls:   visual_compose_status (CALL); parser_clear (tail-JP)
;
;   visual_extend:
;       In:      (none — reads cursor_offset and visual_anchor from
;                state.inc)
;       Out:     status_buffer pre-padded with "-- visual -- <count>"
;                where count = |cursor_offset - visual_anchor| + 1
;                (1..65535; gap-buffer max ~22 KB so the upper
;                reachable range is bounded well below the helper's
;                max); status_dirty = 1; mode_byte / visual_submode /
;                visual_anchor / cursor_offset UNCHANGED; parser
;                state zeroed.
;       Trashes: A, BC, DE, HL, F
;       Calls:   visual_compose_status (CALL); parser_clear (tail-JP)
;
; Dependencies:
;   inc/state.inc    (cursor_offset, visual_anchor, visual_submode,
;                     mode_byte (writer), status_compose_scratch —
;                     Story 3.3 NEW shared cell at the Q3 pin Option A;
;                     parser_clear writes count_accumulator /
;                     pending_* fields via the tail-JP).
;   inc/modes.inc    (MODE_VISUAL, VIS_CHAR equates).
;   src/statusln.asm (status_set_message (AR12 funnel — final-stage
;                     emit via visual_compose_status's tail-JP);
;                     status_u16_to_dec (Q2 pin Option A — decimal
;                     count emit); msg_mode_visual_prefix (Q4 pin
;                     Option A — "-- visual -- " glyph table head)).
;   src/parser.asm   (parser_clear — tail-JP target on both public
;                     entries per AC13 from Story 2.5).
; ============================================================

;; ============================================================
;; --- Public entry: visual_enter_char (Story 3.3 — `v` entry) ---
;; ============================================================

; ----------------------------------------------------------------
; visual_enter_char
; Entry from dispatch_normal['v'] (src/dispatch.asm). Pins the
; current cursor as the visual anchor, sets the MODE_VISUAL /
; VIS_CHAR sub-mode discriminator, composes the "-- visual -- 1"
; entry banner, and drops any stale parser state via parser_clear.
;
; The entry char count is always 1 — visual_anchor == cursor_offset
; at this point so |cursor - anchor| = 0; +1 = 1. visual_compose_status
; loads HL = 1 inline (no need to call visual_extend's compute arm).
;
; AR23 contract — see module-header Register conventions block.
; ----------------------------------------------------------------
visual_enter_char:
    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A
    LD      HL, (cursor_offset)
    LD      (visual_anchor), HL         ; pin anchor at entry cursor (frozen)
    LD      HL, 1                       ; entry char count = 1 (one byte selected)
    CALL    visual_compose_status
    JP      parser_clear                ; AC13: zero count / operator / prefix


;; ============================================================
;; --- Public entry: visual_extend (Story 3.3 — per-motion refresh) ---
;; ============================================================

; ----------------------------------------------------------------
; visual_extend
; Entry from src/edits.asm:edits_compose_or_clear's MODE_VISUAL arm
; (see AC5). Called AFTER a mode-agnostic motion handler has
; advanced cursor_offset; visual_extend recomputes the selection
; extent as |cursor - anchor| + 1 and refreshes the status row.
; The motion's normal post-motion tail-JP target (parser_clear)
; is hijacked by the MODE_VISUAL arm — visual_extend must restore
; that contract on its way out (AC13).
;
; Count math:
;   1. HL = cursor; DE = anchor; HL = HL - DE.
;   2. If CF=1 (cursor < anchor; backward motion), HL was a 16-bit
;      negative two's-complement value — negate HL by 0 - HL via
;      EX DE,HL; LD HL,0; OR A; SBC HL,DE so HL = |cursor - anchor|.
;   3. INC HL — count = abs + 1 (entry case abs=0 → count=1).
;
; AR23 contract — see module-header Register conventions block.
; ----------------------------------------------------------------
visual_extend:
    LD      HL, (cursor_offset)
    LD      DE, (visual_anchor)
    OR      A                           ; clear CF for the SBC
    SBC     HL, DE                      ; HL = cursor - anchor (signed)
    JR      NC, .have_abs               ; forward / equal — HL already positive
    ;; Backward motion — negate HL via 0 - HL.
    EX      DE, HL                      ; DE = (cursor - anchor) negative
    LD      HL, 0
    OR      A                           ; clear CF
    SBC     HL, DE                      ; HL = -(cursor - anchor) = |delta|
.have_abs:
    INC     HL                          ; count = |cursor - anchor| + 1
    CALL    visual_compose_status
    JP      parser_clear                ; AC13: drop any parser state stale from the motion's preamble


;; ============================================================
;; --- Internal helper: visual_compose_status ---
;; ============================================================

; ----------------------------------------------------------------
; visual_compose_status
; Build "-- visual -- <count>\0" in status_compose_scratch and
; hand off to status_set_message for the AR12 status-row emit.
;
; In:      HL = unsigned 16-bit char count (1..65535)
; Out:     status_buffer pre-padded; status_dirty = 1.
; Trashes: A, BC, DE, HL, F
; Calls:   status_u16_to_dec (CALL); status_set_message (tail-JP).
;
; Layout:
;   - LDIR the 13-byte "-- visual -- " prefix (no NUL) from
;     msg_mode_visual_prefix into status_compose_scratch.
;   - status_u16_to_dec writes 1..5 decimal digits at DE (advancing).
;   - Write a NUL terminator at the post-digits position so
;     status_set_message's null-aware copy_loop stops there.
;   - Load HL = status_compose_scratch, XOR A (non-error code),
;     and tail-JP status_set_message.
; ----------------------------------------------------------------
visual_compose_status:
    PUSH    HL                                 ; save count across prefix copy
    LD      HL, msg_mode_visual_prefix
    LD      DE, status_compose_scratch
    LD      BC, MSG_MODE_VISUAL_PREFIX_LEN     ; 13 bytes — see EQU below
    LDIR                                       ; DE -> first byte past prefix
    POP     HL                                 ; restore count
    CALL    status_u16_to_dec                  ; emits 1..5 digits at (DE); advances DE past
    XOR     A
    LD      (DE), A                            ; NUL terminator for status_set_message
    LD      HL, status_compose_scratch
    XOR     A                                  ; non-error code arg (AR16)
    JP      status_set_message                 ; tail-JP — AR12 funnel


;; --- Module-local constants ---
; Length of the "-- visual -- " prefix copied by visual_compose_status
; (13 bytes: two dashes, space, "visual", space, two dashes, trailing
; space — matches the byte run before the NUL in msg_mode_visual_prefix
; at src/statusln.asm). NOT including the NUL — the digits land
; immediately after the trailing space.
MSG_MODE_VISUAL_PREFIX_LEN EQU 13


;; ============================================================
;; --- Placeholders (forward references for Stories 3.4 / 3.5 / 3.6+) ---
;; ============================================================
; visual_enter_line / visual_enter_block / visual_apply_operator are
; declared in the Public block above so future-story dispatchers can
; forward-reference them. NO bodies land in Story 3.3 — adding empty
; EQU stubs would shadow the future symbols and break sjasmplus's
; two-pass resolution. Stories 3.4 / 3.5 / 3.6+ will land the bodies
; here as adjacent labels.
