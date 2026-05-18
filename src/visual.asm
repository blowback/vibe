; ============================================================
; Module: visual.asm
; Purpose: Visual-mode entry / extent / status helpers (FR15, FR33,
;          FR34). Story 3.3 lands the VIS_CHAR surface; Story 3.4
;          lands the VIS_LINE surface: `V` from NORMAL pins
;          `visual_anchor` at the *line-start* of the entry cursor
;          (not the cursor itself — vi-faithful frozen-line-start);
;          subsequent mode-agnostic motions land at
;          edits_compose_or_clear's MODE_VISUAL arm and call
;          visual_extend, which now dispatches on visual_submode:
;          VIS_CHAR → existing `|cursor - anchor| + 1` path; VIS_LINE
;          → walk LFs in [min, max) where min = min(line-start(cursor),
;          anchor) and max = the other, line count = LFs + 1. Status
;          row reports "-- visual -- N" (CHAR) or "-- visual line -- N"
;          (LINE). Esc returns to NORMAL via the existing
;          src/dispatch.asm:enter_normal_mode — no separate
;          visual_cancel symbol needed (Q7 pin from Story 3.3).
;
;          Pure reader of buffer state — AR13 (no BIOS console),
;          AR14 (no gap-buffer writes), AR15 (no raw BDOS) all
;          clean. The only side effects are writes to mode_byte /
;          visual_submode / visual_anchor (Story 3.3 / 3.4 LANDS)
;          and to status_buffer / status_dirty via the AR12 funnel
;          status_set_message. Motion handlers (motions.asm) keep
;          full responsibility for the cursor_offset write.
;
; Public:
;   visual_enter_char     ; LANDS Story 3.3 — `v` entry, VIS_CHAR
;   visual_enter_line     ; LANDS Story 3.4 — `V` entry, VIS_LINE
;   visual_extend         ; LANDS Story 3.3 — per-motion extent refresh
;                         ; (Story 3.4: submode-dispatch prologue
;                         ; routes VIS_CHAR vs VIS_LINE arms)
;   visual_enter_block    ; PLACEHOLDER Story 3.5 (Ctrl-V — rectangular selection)
;   visual_apply_operator ; PLACEHOLDER Stories 3.6-3.8 (d/y/c/>/</~ on a selection)
;
;   (visual_cancel is NOT a separate symbol per Q7 pin Option A —
;    src/dispatch.asm:enter_normal_mode handles VISUAL→NORMAL
;    cleanly and was always documented as the VISUAL exit point.)
;
; State owned (read/write):
;   visual_anchor         ; 16-bit; WRITTEN by visual_enter_char
;                         ; (Story 3.3 — VIS_CHAR, anchor = cursor)
;                         ; AND by visual_enter_line (Story 3.4 —
;                         ; VIS_LINE, anchor = line-start of cursor).
;                         ; Frozen for the lifetime of the visual
;                         ; session — extend NEVER re-pins it; vi
;                         ; convention. READ by visual_extend (count
;                         ; math, both arms) and by future
;                         ; visual_apply_operator (range marshalling).
;   visual_submode        ; 1-byte; WRITTEN by visual_enter_char
;                         ; (VIS_CHAR, Story 3.3) AND by
;                         ; visual_enter_line (VIS_LINE, Story 3.4).
;                         ; Story 3.5 will add the VIS_BLOCK writer.
;                         ; NOT cleared on VISUAL→NORMAL exit — zombie
;                         ; state until the next visual entry
;                         ; overwrites it; meaningless when
;                         ; mode_byte != MODE_VISUAL (SR4 invariant).
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
;   visual_enter_line:
;       In:      A = 'V' (MC4 — ignored after dispatch)
;       Out:     mode_byte = MODE_VISUAL; visual_submode = VIS_LINE;
;                visual_anchor = motion_find_line_start(cursor_offset)
;                — the line-start of the entry cursor, NOT the cursor
;                itself; frozen for the visual-line session.
;                cursor_offset UNCHANGED. status_buffer = "-- visual
;                line -- 1"; status_dirty = 1. Parser state zeroed.
;       Trashes: A, BC, DE, HL, F
;       Calls:   motion_find_line_start (CALL); visual_compose_status_line
;                (CALL); parser_clear (tail-JP).
;
;   visual_extend:
;       In:      (none — reads cursor_offset, visual_anchor and
;                visual_submode from state.inc)
;       Out:     status_buffer pre-padded with either
;                "-- visual -- <count>"   (VIS_CHAR; count = |cursor -
;                                          anchor| + 1)
;                "-- visual line -- <count>"  (VIS_LINE; count = LFs
;                                              in [min, max) + 1 where
;                                              min/max are the two
;                                              line-starts).
;                Count clamped to 1..65535. status_dirty = 1; mode_byte
;                / visual_submode / visual_anchor / cursor_offset
;                UNCHANGED; parser state zeroed.
;       Trashes: A, BC, DE, HL, F
;       Calls:   visual_compose_status (CALL — CHAR arm);
;                visual_count_lines + visual_compose_status_line
;                (LINE arm); parser_clear (tail-JP both arms).
;
; Dependencies:
;   inc/state.inc    (cursor_offset, visual_anchor, visual_submode,
;                     mode_byte (writer), status_compose_scratch —
;                     Story 3.3 NEW shared cell at the Q3 pin Option A;
;                     parser_clear writes count_accumulator /
;                     pending_* fields via the tail-JP).
;   inc/modes.inc    (MODE_VISUAL, VIS_CHAR, VIS_LINE equates).
;   src/motions.asm  (Story 3.4 — motion_find_line_start, called by
;                     visual_enter_line (anchor-pin path) and by
;                     visual_count_lines (cursor's line-start);
;                     motion_byte_at_logical, called by
;                     visual_count_lines (LF-walk inner loop).
;                     Backward-resolved — motions.asm INCLUDEs
;                     before visual.asm in the vibe.asm AR25 chain).
;   src/statusln.asm (status_set_message (AR12 funnel — final-stage
;                     emit via the shared compose tail);
;                     status_u16_to_dec (Q2 pin Option A — decimal
;                     count emit); msg_mode_visual_prefix (CHAR
;                     submode prefix); msg_mode_visual_line_prefix
;                     (Story 3.4 — LINE submode prefix)).
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
;; --- Public entry: visual_enter_line (Story 3.4 — `V` entry) ---
;; ============================================================

; ----------------------------------------------------------------
; visual_enter_line
; Entry from dispatch_normal['V'] (src/dispatch.asm). Pins the
; *line-start* of the entry cursor as the visual anchor (NOT the
; cursor itself — vi-faithful; the line-mode anchor lives in
; line-start space because column data is meaningless and the
; visual_count_lines math relies on anchor being a line-start),
; sets the MODE_VISUAL / VIS_LINE submode discriminator, composes
; the "-- visual line -- 1" entry banner, and drops any stale
; parser state via parser_clear.
;
; The entry line count is always 1: anchor.line == cursor.line at
; this point so LFs in [anchor, line-start(cursor)) = 0; +1 = 1.
; visual_compose_status_line loads HL = 1 inline (no need to call
; visual_extend's compute arm).
;
; AR23 contract — see module-header Register conventions block.
; ----------------------------------------------------------------
visual_enter_line:
    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_LINE
    LD      (visual_submode), A
    LD      HL, (cursor_offset)
    CALL    motion_find_line_start      ; HL = line-start of cursor's line
    LD      (visual_anchor), HL         ; pin anchor at the line-start (frozen)
    LD      HL, 1                       ; entry line count = 1
    CALL    visual_compose_status_line
    JP      parser_clear                ; AC13: zero count / operator / prefix


;; ============================================================
;; --- Public entry: visual_extend (Story 3.3 — per-motion refresh) ---
;; ============================================================

; ----------------------------------------------------------------
; visual_extend
; Entry from src/edits.asm:edits_compose_or_clear's MODE_VISUAL arm
; (see AC5). Called AFTER a mode-agnostic motion handler has
; advanced cursor_offset; visual_extend recomputes the selection
; extent and refreshes the status row. The motion's normal post-
; motion tail-JP target (parser_clear) is hijacked by the
; MODE_VISUAL arm — visual_extend must restore that contract on
; its way out (AC13).
;
; Story 3.4 — submode-dispatch prologue: reads visual_submode and
; branches to the CHAR arm (existing `|cursor - anchor| + 1`
; math) or the LINE arm (visual_count_lines + LINE-prefix status).
; VIS_BLOCK is reserved for Story 3.5 — falls through to the CHAR
; arm defensively until that story lands its own .block_arm.
;
; Count math (CHAR arm):
;   1. HL = cursor; DE = anchor; HL = HL - DE.
;   2. If CF=1 (cursor < anchor; backward motion), HL was a 16-bit
;      negative two's-complement value — negate HL by 0 - HL via
;      EX DE,HL; LD HL,0; OR A; SBC HL,DE so HL = |cursor - anchor|.
;   3. INC HL — count = abs + 1 (entry case abs=0 → count=1).
;
; Count math (LINE arm): delegated to visual_count_lines — walks
; LFs in [min, max) where min/max are the two line-starts.
;
; AR23 contract — see module-header Register conventions block.
; ----------------------------------------------------------------
visual_extend:
    LD      A, (visual_submode)
    CP      VIS_LINE
    JR      Z, .line_arm                ; VIS_LINE → walk LF count
    ;; fall through into the CHAR arm (VIS_CHAR; also defensive
    ;; default for VIS_BLOCK pre-Story-3.5).
.char_arm:
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
.line_arm:
    CALL    visual_count_lines          ; HL = line count (1..65535)
    CALL    visual_compose_status_line
    JP      parser_clear                ; AC13: drop any parser state stale from the motion's preamble


;; ============================================================
;; --- Internal helper: visual_count_lines (Story 3.4) ---
;; ============================================================

; ----------------------------------------------------------------
; visual_count_lines
; Compute the line count of the active VIS_LINE selection. Walks
; the gap buffer between visual_anchor (a line-start, pinned by
; visual_enter_line) and motion_find_line_start(cursor_offset),
; counting LF bytes in the half-open range [min, max). Returns
; line count = LFs + 1.
;
; Math identity: walking from one line-start to another line-start,
; the number of LFs encountered in [min, max) equals the difference
; in line indices. Therefore line_count = LFs + 1 regardless of
; where max lands within its line — the cursor doesn't have to be
; on its line-start for the math to come out right, but the anchor
; MUST be (which is the AC2 invariant pinned at visual_enter_line).
;
; In:      (none — reads cursor_offset, visual_anchor from state.inc)
; Out:     HL = line count (1..65535); cursor_offset / visual_anchor
;          UNCHANGED.
; Trashes: A, BC, DE, HL, F
; Calls:   motion_find_line_start (CALL — resolves cursor's line-
;          start; preserves BC, trashes A/DE/F);
;          motion_byte_at_logical (CALL — pure read; preserves
;          BC and HL on every path, trashes A/DE/F).
; ----------------------------------------------------------------
visual_count_lines:
    LD      HL, (cursor_offset)
    CALL    motion_find_line_start      ; HL = cursor's line-start (LS)
    LD      DE, (visual_anchor)         ; DE = anchor (also a LS)
    OR      A                           ; clear CF for SBC
    SBC     HL, DE                      ; HL = cursor_ls - anchor (signed)
    JR      Z, .single_line             ; same line-start → count = 1
    JR      NC, .forward                ; cursor_ls > anchor (forward)
    ;; Backward: cursor_ls < anchor; HL holds 2s-comp negative diff.
    ;; Recover cursor_ls into HL via ADD; DE = anchor still.
    ;; That already gives HL = cursor_ls (min), DE = anchor (max).
    ADD     HL, DE                      ; HL = cursor_ls (min); DE = anchor (max)
    JR      .walk
.forward:
    ;; HL = cursor_ls - anchor (positive); DE = anchor.
    ;; Recover cursor_ls into HL via ADD, then swap so HL=min.
    ADD     HL, DE                      ; HL = cursor_ls (max); DE = anchor (min)
    EX      DE, HL                      ; HL = anchor (min); DE = cursor_ls (max)
.walk:
    LD      BC, 0                       ; LF count
.loop:
    LD      A, H
    CP      D
    JR      NZ, .scan
    LD      A, L
    CP      E
    JR      Z, .done                    ; HL == DE → walked the half-open range
.scan:
    PUSH    DE                          ; motion_byte_at_logical trashes DE
    CALL    motion_byte_at_logical      ; A = byte at HL; CF=0 in-file
    POP     DE
    CP      0x0A
    JR      NZ, .next
    INC     BC                          ; LF count++
.next:
    INC     HL
    JR      .loop
.done:
    LD      H, B
    LD      L, C
    INC     HL                          ; line count = LFs + 1
    RET
.single_line:
    LD      HL, 1                       ; same line-start → count = 1
    RET


;; ============================================================
;; --- Internal helpers: visual_compose_status / _status_line ---
;; ============================================================

; ----------------------------------------------------------------
; visual_compose_status_line  (Story 3.4 — LINE submode banner)
; visual_compose_status       (Story 3.3 — CHAR submode banner)
; Both build "<prefix><count>\0" in status_compose_scratch and hand
; off to status_set_message for the AR12 status-row emit. They
; share a common tail (_visual_compose_finish) reached by JR fall-
; through; each named entry differs only in the prefix-ptr and
; prefix-length loaded into HL/BC before the LDIR.
;
; In (both):  HL = unsigned 16-bit count (1..65535) — chars (CHAR
;             arm) or lines (LINE arm).
; Out:        status_buffer pre-padded; status_dirty = 1.
; Trashes:    A, BC, DE, HL, F
; Calls:      status_u16_to_dec (CALL); status_set_message (tail-JP).
;
; Layout:
;   - LDIR the prefix bytes (no NUL) from msg_mode_visual{,_line}_prefix
;     into status_compose_scratch.
;   - status_u16_to_dec writes 1..5 decimal digits at DE (advancing).
;   - Write a NUL terminator at the post-digits position so
;     status_set_message's null-aware copy_loop stops there.
;   - Load HL = status_compose_scratch, XOR A (non-error code),
;     and tail-JP status_set_message.
; ----------------------------------------------------------------
visual_compose_status_line:
    PUSH    HL                                 ; save count across prefix copy
    LD      HL, msg_mode_visual_line_prefix
    LD      BC, MSG_MODE_VISUAL_LINE_PREFIX_LEN ; 18 bytes
    JR      _visual_compose_finish
visual_compose_status:
    PUSH    HL                                 ; save count across prefix copy
    LD      HL, msg_mode_visual_prefix
    LD      BC, MSG_MODE_VISUAL_PREFIX_LEN     ; 13 bytes
    ;; fall through to the shared tail

; _visual_compose_finish — private label; entries fall through
; here; do NOT call directly. Expects HL = prefix ptr, BC = prefix
; length, top-of-stack = saved count.
_visual_compose_finish:
    LD      DE, status_compose_scratch
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
MSG_MODE_VISUAL_PREFIX_LEN      EQU 13
; Length of the "-- visual line -- " prefix copied by
; visual_compose_status_line (18 bytes: same shape as the CHAR
; prefix with "line " inserted between "visual" and the closing
; "-- "). NOT including the NUL — digits land at offset 18.
MSG_MODE_VISUAL_LINE_PREFIX_LEN EQU 18


;; ============================================================
;; --- Placeholders (forward references for Stories 3.5 / 3.6+) ---
;; ============================================================
; visual_enter_block / visual_apply_operator are declared in the
; Public block above so future-story dispatchers can forward-
; reference them. NO bodies land yet — adding empty EQU stubs
; would shadow the future symbols and break sjasmplus's two-pass
; resolution. Stories 3.5 / 3.6+ will land the bodies here as
; adjacent labels.
