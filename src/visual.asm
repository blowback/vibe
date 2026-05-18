; ============================================================
; Module: visual.asm
; Purpose: Visual-mode entry / extent / status helpers (FR15, FR33,
;          FR34, FR35). Story 3.3 lands the VIS_CHAR surface; Story
;          3.4 lands the VIS_LINE surface; Story 3.5 lands the
;          VIS_BLOCK surface: `Ctrl-V` (0x16) from NORMAL pins
;          `visual_anchor` at the entry cursor OFFSET (NOT the
;          line-start — VIS_BLOCK anchor lives in offset space and
;          the column is derived on-demand as
;          `visual_anchor - motion_find_line_start(visual_anchor)`;
;          this is the KEY semantic distinction from VIS_LINE which
;          snaps the anchor to a line-start). Subsequent mode-
;          agnostic motions land at edits_compose_or_clear's
;          MODE_VISUAL arm and call visual_extend, which dispatches
;          on visual_submode: VIS_CHAR → existing `|cursor - anchor|
;          + 1` path; VIS_LINE → walk LFs in [min, max) where min =
;          min(line-start(cursor), anchor) and max = the other, line
;          count = LFs + 1; VIS_BLOCK → visual_count_block_dims
;          projects BOTH anchor and cursor to (row, col) via
;          motion_find_line_start, walks LFs in the same [min, max)
;          line-start interval for rows, then computes cols as
;          `|cursor_col - anchor_col| + 1`. Status row reports
;          "-- visual -- N" (CHAR), "-- visual line -- N" (LINE) or
;          "-- visual block -- RxC" (BLOCK). Esc returns to NORMAL
;          via the existing src/dispatch.asm:enter_normal_mode — no
;          separate visual_cancel symbol needed (Q7 pin from Story 3.3).
;
;          BH3 jagged-line semantic (Story 3.5): the VIS_BLOCK
;          rectangle is *virtual* — short lines are NOT padded in
;          the buffer; rows whose line is shorter than the column
;          range are simply reported in the bounding RxC dimensions
;          but no gap-buffer write occurs. Per-row clipping ("delete
;          only up to EOL on short lines") is the OPERATOR's job
;          (Stories 3.6+ visual_apply_operator marshals per-row
;          ranges from this story's rectangle).
;
;          Pure reader of buffer state — AR13 (no BIOS console),
;          AR14 (no gap-buffer writes), AR15 (no raw BDOS) all
;          clean. The only side effects are writes to mode_byte /
;          visual_submode / visual_anchor (Story 3.3 / 3.4 / 3.5
;          LANDS — VIS_CHAR / VIS_LINE / VIS_BLOCK writers all live
;          here now; submode-writer triad complete after Story 3.5)
;          and to status_buffer / status_dirty via the AR12 funnel
;          status_set_message, plus the 5 module-local DEFW
;          projection scratch cells written by visual_count_block_dims
;          (visual_block_anchor_ls / _anchor_col / _cursor_ls /
;          _cursor_col / _temp_rows — see Module-local data block
;          below). Motion handlers (motions.asm) keep full
;          responsibility for the cursor_offset write.
;
; Public:
;   visual_enter_char     ; LANDS Story 3.3 — `v` entry, VIS_CHAR
;   visual_enter_line     ; LANDS Story 3.4 — `V` entry, VIS_LINE
;   visual_enter_block    ; LANDS Story 3.5 — `Ctrl-V` entry, VIS_BLOCK
;   visual_extend         ; LANDS Story 3.3 — per-motion extent refresh
;                         ; (Story 3.4: submode-dispatch prologue
;                         ; routes VIS_CHAR vs VIS_LINE arms; Story
;                         ; 3.5 extends the prologue to a 3-way
;                         ; cascade with a .block_arm for VIS_BLOCK)
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
;                         ; VIS_LINE, anchor = line-start of cursor)
;                         ; AND by visual_enter_block (Story 3.5 —
;                         ; VIS_BLOCK, anchor = cursor offset; SAME
;                         ; offset-space as VIS_CHAR — NOT line-start;
;                         ; column is derived on-demand from
;                         ; `visual_anchor - motion_find_line_start
;                         ; (visual_anchor)` by visual_count_block_dims).
;                         ; Frozen for the lifetime of the visual
;                         ; session — extend NEVER re-pins it; vi
;                         ; convention. READ by visual_extend (count
;                         ; math, all three arms) and by future
;                         ; visual_apply_operator (range marshalling).
;   visual_submode        ; 1-byte; WRITTEN by visual_enter_char
;                         ; (VIS_CHAR, Story 3.3) AND by
;                         ; visual_enter_line (VIS_LINE, Story 3.4)
;                         ; AND by visual_enter_block (VIS_BLOCK,
;                         ; Story 3.5). Submode-writer triad
;                         ; complete. NOT cleared on VISUAL→NORMAL
;                         ; exit — zombie state until the next
;                         ; visual entry overwrites it; meaningless
;                         ; when mode_byte != MODE_VISUAL (SR4
;                         ; invariant).
;
;   Module-local DEFW projection scratch (Story 3.5 — NOT in state.inc):
;     visual_block_anchor_ls   ; anchor's line-start (offset)
;     visual_block_anchor_col  ; anchor's column = anchor - anchor_ls
;     visual_block_cursor_ls   ; cursor's line-start (offset)
;     visual_block_cursor_col  ; cursor's column = cursor - cursor_ls
;     visual_block_temp_rows   ; rows result stashed across cols compute
;   Lifecycle: cleared and re-written by visual_count_block_dims at
;   every call; values valid ONLY between the helper's entry and
;   its RET — caller does NOT read them. Module-local; never
;   exported via inc/state.inc.
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
;   visual_enter_block:
;       In:      A = 0x16 (Ctrl-V; MC4 — ignored after dispatch)
;       Out:     mode_byte = MODE_VISUAL; visual_submode = VIS_BLOCK;
;                visual_anchor = cursor_offset (offset space — NOT
;                line-start; vi-faithful BLOCK anchor; column
;                derived on-demand by visual_count_block_dims as
;                `visual_anchor - motion_find_line_start(visual_anchor)`).
;                cursor_offset UNCHANGED. status_buffer = "-- visual
;                block -- 1x1"; status_dirty = 1. Parser state zeroed.
;       Trashes: A, BC, DE, HL, F
;       Calls:   visual_compose_status_block (CALL); parser_clear
;                (tail-JP).
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
;                                              line-starts)
;                "-- visual block -- <rows>x<cols>"  (VIS_BLOCK;
;                                              rows = LFs in
;                                              [min(anchor_ls,
;                                              cursor_ls), max) + 1;
;                                              cols = |cursor_col -
;                                              anchor_col| + 1).
;                Count clamped to 1..65535. status_dirty = 1; mode_byte
;                / visual_submode / visual_anchor / cursor_offset
;                UNCHANGED; parser state zeroed.
;       Trashes: A, BC, DE, HL, F
;       Calls:   visual_compose_status (CALL — CHAR arm);
;                visual_count_lines + visual_compose_status_line
;                (LINE arm); visual_count_block_dims +
;                visual_compose_status_block (BLOCK arm);
;                parser_clear (tail-JP all three arms).
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
;                     count emit; called twice by
;                     visual_compose_status_block for the rows + cols
;                     numeric pair); msg_mode_visual_prefix (CHAR
;                     submode prefix); msg_mode_visual_line_prefix
;                     (Story 3.4 — LINE submode prefix);
;                     msg_mode_visual_block_prefix (Story 3.5 —
;                     BLOCK submode prefix, "-- visual block -- ").
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
;; --- Public entry: visual_enter_block (Story 3.5 — `Ctrl-V`) ---
;; ============================================================

; ----------------------------------------------------------------
; visual_enter_block
; Entry from dispatch_normal[0x16] (Ctrl-V; src/dispatch.asm).
; Pins the entry cursor OFFSET as the visual anchor (NOT the
; line-start — VIS_BLOCK's anchor lives in offset space; the
; anchor column is derived on-demand by visual_count_block_dims
; as `visual_anchor - motion_find_line_start(visual_anchor)`).
; Sets MODE_VISUAL / VIS_BLOCK, composes the "-- visual block --
; 1x1" entry banner, drops any stale parser state via parser_clear.
;
; The entry rectangle is 1x1: anchor == cursor at this point so
; rows = LFs in [anchor_ls, anchor_ls) + 1 = 1 and cols =
; |anchor_col - anchor_col| + 1 = 1. visual_compose_status_block
; loads HL = 1 (rows) and BC = 1 (cols) inline — no need to call
; visual_count_block_dims's compute arm.
;
; AR23 contract — see module-header Register conventions block.
; ----------------------------------------------------------------
visual_enter_block:
    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_BLOCK
    LD      (visual_submode), A
    LD      HL, (cursor_offset)
    LD      (visual_anchor), HL         ; pin anchor at the cursor offset (frozen)
    LD      HL, 1                       ; entry rows = 1
    LD      BC, 1                       ; entry cols = 1
    CALL    visual_compose_status_block
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
; math), the LINE arm (visual_count_lines + LINE-prefix status),
; or — after Story 3.5 — the BLOCK arm (visual_count_block_dims +
; BLOCK-prefix status). VIS_CHAR is value 0 and serves as the
; defensive fall-through default for any unknown submode value.
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
; Count math (BLOCK arm): delegated to visual_count_block_dims —
; projects both anchor and cursor to (row, col) and returns
; HL = rows (LFs in [min(anchor_ls, cursor_ls), max) + 1) and
; BC = cols (|cursor_col - anchor_col| + 1). Any future submodes
; would extend the cascade further.
;
; AR23 contract — see module-header Register conventions block.
; ----------------------------------------------------------------
visual_extend:
    LD      A, (visual_submode)
    CP      VIS_BLOCK
    JR      Z, .block_arm               ; VIS_BLOCK → rectangle compute
    CP      VIS_LINE
    JR      Z, .line_arm                ; VIS_LINE → walk LF count
    ;; fall through into the CHAR arm (VIS_CHAR is value 0; also
    ;; the defensive default for any unknown submode value).
    ASSERT VIS_CHAR == 0    ; equate-ordering invariant the fall-through depends on
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
.block_arm:
    ;; BH3 jagged-line semantic — the bounding rectangle is virtual.
    ;; Status banner reports `RxC` of the bounding box. Per-row
    ;; clipping (short lines processed only up to EOL) is the
    ;; OPERATOR's responsibility (Story 3.6+ — visual_apply_operator
    ;; marshals per-row ranges from this rectangle). Story 3.5
    ;; lands the rectangle and the dimension display; NO mutation
    ;; of the buffer occurs in this path (AR14 invariant pinned).
    CALL    visual_count_block_dims     ; HL = rows; BC = cols
    CALL    visual_compose_status_block ; format "RxC"
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
;; --- Internal helper: visual_count_block_dims (Story 3.5) ---
;; ============================================================

; ----------------------------------------------------------------
; visual_count_block_dims
; Compute the bounding rows × cols of the active VIS_BLOCK
; rectangle. Projects visual_anchor (an offset) and cursor_offset
; to (row, col) via motion_find_line_start; rows are the LF count
; in [min(anchor_ls, cursor_ls), max(...)) plus 1 (same shape as
; visual_count_lines but the anchor is NOT assumed to be a line-
; start the way VIS_LINE assumes); cols are |cursor_col -
; anchor_col| + 1 (pure byte arithmetic, no LF walk).
;
; The five module-local DEFW cells (visual_block_anchor_ls /
; _anchor_col / _cursor_ls / _cursor_col / _temp_rows) act as
; projection scratch. The cells are written once per call and
; valid only between this helper's entry and its RET — no caller
; reads them.
;
; **CRITICAL AR14 invariant** — NO buffer mutation. The rectangle
; is virtual (BH3); the helper reads cursor_offset / visual_anchor
; and walks the buffer via motion_byte_at_logical / motion_find_
; line_start. NO gapbuf_insert / gapbuf_delete / gapbuf_move_gap
; calls and NO writes to gap_start / gap_end. Short lines in the
; vertical extent are NOT padded.
;
; In:      (none — reads cursor_offset, visual_anchor from state.inc)
; Out:     HL = rows (1..65535); BC = cols (1..65535);
;          cursor_offset / visual_anchor UNCHANGED; module-local
;          DEFW cells clobbered.
; Trashes: A, BC, DE, HL, F
; Calls:   motion_find_line_start (CALL — twice — for anchor and
;          cursor; preserves BC, trashes A/DE/F per its AR23 contract);
;          motion_byte_at_logical (CALL — inner LF-walk loop;
;          PUSH/POP DE around the call per the Story-3.4 DE-trash
;          gotcha; preserves BC and HL, trashes A/DE/F).
; ----------------------------------------------------------------
visual_count_block_dims:
    ;; --- Project anchor offset → (anchor_ls, anchor_col) ---
    LD      HL, (visual_anchor)
    PUSH    HL                              ; save anchor offset across motion_find_line_start
    CALL    motion_find_line_start          ; HL = anchor's line-start (anchor_ls)
    LD      (visual_block_anchor_ls), HL
    POP     DE                              ; DE = anchor offset (saved)
    EX      DE, HL                          ; HL = anchor offset; DE = anchor_ls
    OR      A                               ; clear CF for SBC
    SBC     HL, DE                          ; HL = anchor_offset - anchor_ls = anchor_col
    LD      (visual_block_anchor_col), HL

    ;; --- Project cursor offset → (cursor_ls, cursor_col) ---
    LD      HL, (cursor_offset)
    PUSH    HL                              ; save cursor offset across motion_find_line_start
    CALL    motion_find_line_start          ; HL = cursor's line-start (cursor_ls)
    LD      (visual_block_cursor_ls), HL
    POP     DE                              ; DE = cursor offset (saved)
    EX      DE, HL                          ; HL = cursor offset; DE = cursor_ls
    OR      A                               ; clear CF for SBC
    SBC     HL, DE                          ; HL = cursor_offset - cursor_ls = cursor_col
    LD      (visual_block_cursor_col), HL

    ;; --- Compute rows via LF walk over [min(anchor_ls, cursor_ls), max) ---
    ;; Reuses the SBC-and-swap pattern from visual_count_lines —
    ;; the math identity is the same (LFs in [min, max) + 1) but
    ;; the anchor is NOT guaranteed to be a line-start here, so
    ;; we walk between the two derived line-starts instead.
    LD      HL, (visual_block_cursor_ls)
    LD      DE, (visual_block_anchor_ls)
    OR      A                               ; clear CF for SBC
    SBC     HL, DE                          ; HL = cursor_ls - anchor_ls (signed)
    JR      Z, .single_row                  ; same line-start → rows = 1
    JR      NC, .rows_forward               ; cursor_ls > anchor_ls
    ;; Backward: HL = neg diff. ADD HL,DE recovers cursor_ls into
    ;; HL with DE still = anchor_ls; cursor_ls (min) < anchor_ls (max).
    ADD     HL, DE                          ; HL = cursor_ls (min); DE = anchor_ls (max)
    JR      .rows_walk
.rows_forward:
    ;; Forward: HL = positive diff. ADD HL,DE recovers cursor_ls into HL,
    ;; then EX swaps so HL = anchor_ls (min); DE = cursor_ls (max).
    ADD     HL, DE                          ; HL = cursor_ls (max); DE = anchor_ls (min)
    EX      DE, HL                          ; HL = anchor_ls (min); DE = cursor_ls (max)
.rows_walk:
    LD      BC, 0                           ; LF count accumulator
.rows_loop:
    LD      A, H
    CP      D
    JR      NZ, .rows_scan
    LD      A, L
    CP      E
    JR      Z, .rows_done                   ; HL == DE → walked the half-open range
.rows_scan:
    PUSH    DE                              ; motion_byte_at_logical trashes DE
    CALL    motion_byte_at_logical          ; A = byte at HL; CF=0 in-file
    POP     DE
    CP      0x0A
    JR      NZ, .rows_next
    INC     BC                              ; LF count++
.rows_next:
    INC     HL
    JR      .rows_loop
.rows_done:
    LD      H, B
    LD      L, C
    INC     HL                              ; rows = LFs + 1
    LD      (visual_block_temp_rows), HL    ; stash rows across cols compute
    JR      .compute_cols
.single_row:
    LD      HL, 1
    LD      (visual_block_temp_rows), HL    ; stash rows = 1

.compute_cols:
    ;; cols = |cursor_col - anchor_col| + 1. Pure byte arithmetic;
    ;; same SBC-and-swap pattern as visual_extend.char_arm.
    LD      HL, (visual_block_cursor_col)
    LD      DE, (visual_block_anchor_col)
    OR      A                               ; clear CF for SBC
    SBC     HL, DE                          ; HL = cursor_col - anchor_col (signed)
    JR      NC, .cols_have_abs              ; forward / equal — HL already positive
    EX      DE, HL                          ; DE = (cursor_col - anchor_col) negative
    LD      HL, 0
    OR      A                               ; clear CF
    SBC     HL, DE                          ; HL = -(cursor_col - anchor_col) = |delta|
.cols_have_abs:
    INC     HL                              ; cols = |delta| + 1
    LD      B, H
    LD      C, L                            ; BC = cols
    LD      HL, (visual_block_temp_rows)    ; recover rows into HL
    RET


;; ============================================================
;; --- Internal helpers: visual_compose_status / _status_line / _status_block ---
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
; visual_compose_status_block  (Story 3.5 — BLOCK submode banner)
; Standalone body — does NOT share _visual_compose_finish with the
; CHAR / LINE entries. The block format emits TWO numeric params
; (rows + cols) separated by a literal 'x'; the CHAR/LINE shared
; tail (HL = single count) cannot cleanly host this without IX-
; parametrization or a stateful "second number?" flag (~+15 B for
; ~+5 B saved), so the standalone body is cheaper and clearer.
;
; In:      HL = rows (1..65535); BC = cols (1..65535)
; Out:     status_buffer pre-padded with "-- visual block -- <rows>x<cols>";
;          status_dirty = 1
; Trashes: A, BC, DE, HL, F
; Calls:   status_u16_to_dec (CALL — twice, once per number);
;          status_set_message (tail-JP — AR12 funnel).
; Depends: status_u16_to_dec must advance DE past the emitted digits.
;          The literal 'x' write and the NUL terminator both rely on
;          DE pointing one-past-the-last-digit on return.
visual_compose_status_block:
    PUSH    BC                                  ; save cols across prefix LDIR + rows emit
    PUSH    HL                                  ; save rows across prefix LDIR
    LD      HL, msg_mode_visual_block_prefix
    LD      BC, MSG_MODE_VISUAL_BLOCK_PREFIX_LEN ; 19 bytes
    LD      DE, status_compose_scratch
    LDIR                                        ; DE -> first byte past prefix
    POP     HL                                  ; restore rows
    CALL    status_u16_to_dec                   ; emits 1..5 rows digits at (DE); advances DE
    LD      A, 'x'
    LD      (DE), A
    INC     DE
    POP     HL                                  ; restore cols
    CALL    status_u16_to_dec                   ; emits 1..5 cols digits at (DE); advances DE
    XOR     A
    LD      (DE), A                             ; NUL terminator for status_set_message
    LD      HL, status_compose_scratch
    XOR     A                                   ; non-error code arg (AR16)
    JP      status_set_message                  ; tail-JP — AR12 funnel
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
; Length of the "-- visual block -- " prefix copied by
; visual_compose_status_block (19 bytes: same shape as the LINE
; prefix with "block " replacing "line "). NOT including the NUL
; — rows digits land at offset 19, then a literal 'x', then the
; cols digits, then visual_compose_status_block writes the NUL
; terminator for status_set_message.
MSG_MODE_VISUAL_BLOCK_PREFIX_LEN EQU 19
; Worst-case banner: prefix (19) + 5 rows digits + 'x' + 5 cols digits + NUL = 31 B.
; Pin the status_compose_scratch capacity so a future shrink fails the build.
    ASSERT MSG_MODE_VISUAL_BLOCK_PREFIX_LEN + 5 + 1 + 5 + 1 <= 48   ; status_compose_scratch size


;; ============================================================
;; --- Module-local data (Story 3.5 — visual_count_block_dims
;;     projection scratch) ---
;; ============================================================
; Five 16-bit cells used by visual_count_block_dims as projection
; scratch — anchor_ls / anchor_col / cursor_ls / cursor_col and
; the temp_rows stash that carries the row count across the cols
; compute. Cells are clobbered on every call; values are valid
; ONLY between the helper's entry and its RET — no caller reads
; them. Module-local; NOT exported via inc/state.inc. Mirrors the
; status_dec_dest pattern in src/statusln.asm (module-local DEFW
; scratch for inter-helper marshalling).
;
; NOTE: visual_apply_operator (Stories 3.6+) is declared in the
; Public block above as a forward reference for future dispatchers;
; no body lands yet. Adding an empty EQU stub would shadow the
; future symbol and break sjasmplus's two-pass resolution.
visual_block_anchor_ls:   DEFW 0
visual_block_anchor_col:  DEFW 0
visual_block_cursor_ls:   DEFW 0
visual_block_cursor_col:  DEFW 0
visual_block_temp_rows:   DEFW 0
