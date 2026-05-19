# Story 4.2: Welcome screen on no-argument launch

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want a welcome screen to appear when I launch `vibe` with no filename argument, dismissed by the first keystroke (which is then processed normally),
So that FR53 is realized — VIBE has a friendly entry point that announces itself and reminds me how to quit, mirroring vim's `:intro` polish.

## Acceptance Criteria

**AC1 — Welcome screen shows on no-arg launch (FR53 / FR1 entry).**

**Given** I launch `vibe` with no filename argument (per FR1; `DEFAULT_FCB + 1 == ' '` triggers `fileio_load_initial.no_arg` per Story 2.3 AC2)
**When** `init_cold_start` finishes the cold-start sequence
**Then** the editing area (internal rows 0..22 = user-facing rows 1..23) shows the VIBE welcome screen vertically centered: 13 banner lines anchored at internal row 5 (= `(EDITABLE_ROWS - 13) / 2` = `(23 - 13) / 2 = 5`), occupying rows 5..17, with rows 0..4 and rows 18..22 blank (0x20 spaces)
**And** the banner glyph + literal-text content tracks `banner.txt` in the repo (13 LF-terminated lines: blank / 7-line ASCII "VIBE" glyph / blank / "Vi-like Beast Editor" / "(c) 2026 ant.org" / blank / "Type :q to quit!") — encoded into `vibe.com` as 222 B of RLE data in `src/welcome.asm` (Q1 Option B, per dev-pass choice; saves ~137 B vs the originally-recommended INCBIN path while preserving the glyph layout). Per-row horizontal positioning is recomputed for screen centering rather than reproducing banner.txt's source-file leading-space padding verbatim: glyph rows (lines 2-8) anchor at col 21 = (80-38)/2; "Vi-like Beast Editor" anchors at col 30 = (80-20)/2; "(c) 2026 ant.org" + "Type :q to quit!" anchor at col 32 (post-2026-05-19 hardware-UAT centering pass — see Change Log line 920).
**And** the status line on row 23 (`STATUS_ROW`, FR49) shows the existing `msg_mode_normal` empty banner (80 spaces — preserves Story 2.3's no-arg behaviour; AR16 "no banner in normal mode" convention; NO new status-line text introduced)
**And** the underlying gap buffer is empty (`cursor_offset = 0`, `gap_start = GAP_BUFFER_BASE`, `gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX`, `file_length = 0` — unchanged from `gapbuf_init` post-Stage-3 state)
**And** the cursor blinks at internal row 0 / col 0 (top-left of editing area — `welcome_paint` ends with an `ESC Y 0,0` reposition, matching `cursor_offset = 0`). *Symbol note: under Q3 Option B, the paint routine lives in `src/welcome.asm` as `welcome_paint`; the original AC narrative used `render_paint_welcome` from the Q3 Option A draft.*

**Note on epics.md "`[No Name]` (or equivalent)" wording.** The epic narrative says the status row "shows the normal-mode state — filename `[No Name]` (or equivalent), mode NORMAL, no error". VIBE's existing no-arg banner is the empty `msg_mode_normal` (statusln.asm:341 `DEFB 0` padded to STATUS_LINE_WIDTH spaces per `status_set_message`); per AR16 "vi-convention: no banner in normal mode", this is the equivalent. Story 4.2 introduces NO new status-line strings — the "or equivalent" clause is satisfied by the existing empty banner. Cross-checked per [[feedback_create_story_cross_check]].

**AC2 — Welcome screen hidden when filename argument provided (FR2 entry preserved).**

**Given** I launch `vibe filename.fs` with a filename argument (per FR2; `DEFAULT_FCB + 1 != ' '` triggers `fileio_load_initial`'s parse → open → load chain per Story 2.3 AC3/AC4)
**When** `init_cold_start` finishes the cold-start sequence
**Then** the welcome screen is NOT shown:
- `welcome_active` stays 0 (the LDIR zero-fill at Stage 1 sets it to 0; `fileio_load_initial.no_arg` is the only writer that flips it to 1, and the filename-present path bypasses `.no_arg`)
- `render_paint_welcome` is NOT called (the Stage 6.5 `CALL NZ, render_paint_welcome` short-circuits because `welcome_active == 0`)
- The editing area shows the loaded file contents per FR2 / Story 2.3 AC3 (load-success), or per Story 2.3 AC4 (`[new file]`), or per AC5/AC6 (`file too large` / `can't read file`) — current behaviour preserved byte-for-byte
- shadow_buffer is reconciled to the buffer's content via Stage 6's `render_full`; no banner glyphs land in shadow

**AC3 — First keystroke dismisses welcome AND is processed normally by the active mode.**

**Given** the welcome screen is shown (post-init, `welcome_active = 1`, banner visible on screen + in shadow_buffer at internal rows 5..17)
**When** the FIRST keystroke arrives via `input_get_key` in `vibe.asm`'s `input_loop` (any printable byte; any control byte: `i`, `:`, `h`, `Esc`, `Ctrl-L`, a literal digit, etc.)
**Then** the dismissal hook fires **between** `CALL input_get_key` and the mode-byte read (Q4 Option A — recommended hook site at `vibe.asm:227-234`):
- `welcome_active` is cleared to 0 (`LD A, 0 ; LD (welcome_active), A`)
- `render_mark_all_dirty` is called so the post-dispatch `render_diff` (in main loop's step 4) walks every editable row, finds shadow holds banner glyphs and the buffer's target byte is 0x20 (space — empty buffer past-EOF), and emits spaces over every banner cell. After `render_diff` returns, the screen shows a blank editing area + the status row + the cursor at row 0 / col 0 (RI4)
- The keystroke in `A` (preserved across the hook via `LD C, A` already at `vibe.asm:234`) flows through the normal mode dispatch path UNCHANGED (no dispatch table is altered; no key is swallowed):
  - `i` enters MODE_INSERT (cursor stays at offset 0; next typed character lands at offset 0 of the empty buffer; status row shows `msg_mode_insert`)
  - `:` enters MODE_COMMAND (CMD_SUB_EX submode; status row shows the `:` prompt at col 0; RI4-with-AC11 puts cursor on status row at col 1)
  - `Esc` is consumed by NORMAL-mode unbound-key handler (status beep / no-op per FR50)
  - `Ctrl-L` dispatches to `render_full` (the post-1.11 binding); the dismissal hook already called `render_mark_all_dirty`, so Ctrl-L's own `render_mark_all_dirty` is idempotent and the welcome paints over with spaces as expected. Benign double `render_mark_all_dirty` (idempotent set-bits)
  - A literal printable digit (e.g. `5`) feeds `parser_accumulate_digit` per MC4 (the parser absorbs the count; status row may show `count: 5`)

**Hook implementation pattern at `src/vibe.asm:226-227`:**

```asm
input_loop:
    ;; 1. Get next keystroke.
    CALL    input_get_key

    ;; 1.5. Welcome-dismissal hook (Story 4.2). One-shot: welcome_active
    ;; cold-starts at 1 on no-arg launch (set in fileio_load_initial.no_arg);
    ;; the first keystroke clears it and forces a full editable-area redraw
    ;; so the post-dispatch render_diff repaints over the banner glyphs.
    ;; After dismissal, welcome_active stays 0 for the editor's lifetime.
    LD      A, (welcome_active)
    OR      A
    JR      Z, .no_welcome
    PUSH    AF                           ; preserve the key byte (A) across the side effects
    XOR     A
    LD      (welcome_active), A
    CALL    render_mark_all_dirty
    POP     AF                           ; restore key byte for downstream LD C, A
.no_welcome:
    ;; 2. Per-mode dispatch... (unchanged from Story 2.1)
    LD      C, A
    ...
```

*Adopted variant: PUSH AF / POP AF brackets the dismissal side-effects. The original AC narrative's `LD A, (input_held_byte)` alternative was based on a misread — `input_held_byte` is the input-layer RI5 disambiguation cell (one-shot ESC peek), not a key-preservation cell, so it cannot be used to recover the keystroke here. Q4 Option A (PUSH/POP AF) per the Implementation Questions section is the variant that landed. Actual cost: +15 B per the Change Log.*

**AC4 — Welcome is one-shot: never re-arms even if buffer returns to empty.**

**Given** the welcome screen has been dismissed (`welcome_active = 0` post first-keystroke)
**When** subsequent edits proceed — including any path that returns the buffer to `file_length = 0` (e.g. `dd` on a 1-line buffer per FR29 / FR45 undo replay path, or `:e empty.txt` per FR6 loading a 0-byte file, or `:e!` discarding edits back to an empty file)
**Then** `welcome_active` stays 0 — the welcome screen is NEVER redrawn for the editor's lifetime:
- `fileio_load_initial.no_arg` is the ONLY writer that sets `welcome_active = 1`, and it runs exactly ONCE per .com launch (at Stage 5 of `init_cold_start`)
- `init_teardown` does NOT clear `welcome_active` (the warm-boot exits the editor; the next `vibe` invocation re-runs the LDIR zero-fill at Stage 1 which re-zeroes `welcome_active`, then Stage 5 may re-set it if no-arg again)
- No other module reads or writes `welcome_active` — grep `welcome_active` against `src/*.asm` post-Story 4.2 returns exactly three writers (`init.asm` LDIR via state.inc EQU resolution; `fileio.asm:.no_arg`; `vibe.asm:input_loop` dismissal hook) and one reader (`init.asm` Stage 6.5 + `vibe.asm` dismissal hook)
- Behaviour is indistinguishable from launching with no welcome (FR1 baseline) — incremental render (NFR1) proceeds normally for sustained editing

**AC5 — FR47 incremental-render exemption: welcome paint + welcome clear both count as initial-draw full-screen emits.**

**Given** the welcome screen interacts with FR47 ("VIBE renders only changed regions of the screen during normal editing — full-screen redraws happen only on initial draw or explicit refresh")
**When** the welcome is painted on init and cleared on first keystroke
**Then** both events fall under FR47's `initial draw / Ctrl-L` exemption (per architecture line 515 "Whole-screen redraw: only on initial draw, on `Ctrl-L` (refresh)..."):
- **Paint event:** `render_paint_welcome` runs at init Stage 6.5 — a one-shot full-screen emit at cold-start time, semantically equivalent to `render_init`'s ESC J + shadow seed (also a Stage-4 cold-start emit). NOT "normal editing"; FR47 contract not violated.
- **Clear event:** the first-keystroke `render_mark_all_dirty` + the subsequent `render_diff` walks every editable row and emits per FR47's normal diff-render path. The 23-row emit IS a large diff but the underlying mechanism (per-cell shadow compare, contiguous-run emit) IS FR47-compliant — it's a one-time consequence of the shadow being out of sync with the buffer state. No FR47 contract violation; the same code path runs after any large mutation (e.g. `:e largefile.txt`) and is not considered "non-incremental".
- **Sustained editing contract:** after the clear event, every subsequent `render_diff` emits only the dirty rows touched by handlers (NFR1 + FR47 normal contract restored).

**AC6 — NFR9 size budget honored.**

**Given** `make sizes` after Story 4.2 lands
**When** the listing is read
**Then** `vibe.com` sits within the NFR9 10240 B ceiling with at least 1000 B residual headroom (original projection: ~8600-8900 B = **+418-718 B** assuming the INCBIN-of-banner.txt route; *actual under Q1 Option B was +380 B → vibe.com = 8562 B / 83.6% / 1678 B headroom — see post-implementation row below*)
**And** the listing is captured in the Dev Agent Record / Completion Notes List with the actual size + percentage delta against the 10240 B ceiling

**Detailed projection (original, pre-Q1-B):**

| Item | Estimated cost | Mid-estimate |
|---|---|---|
| `INCBIN "../banner.txt"` (raw banner asset) | exactly 359 B (file size) | +359 B |
| `render_paint_welcome` routine body (walk banner data, emit each byte via render_emit_byte, sync shadow_buffer in lock-step, handle LF row-advance, end with ESC Y 0,0 cursor reposition) | ~50-80 B | +65 B |
| `welcome_active` state byte in state.inc | +1 B in static block (negligible code growth) | +0 B code |
| `fileio_load_initial.no_arg` set `welcome_active=1` (Q5 Option A) | ~5 B (`LD A,1 ; LD (welcome_active),A`) | +5 B |
| `init_cold_start` Stage 6.5: conditional `CALL NZ, render_paint_welcome` | ~9 B (`LD A,(welcome_active) ; OR A ; CALL NZ,render_paint_welcome`) | +9 B |
| `vibe.asm` input_loop dismissal hook (Q4 Option A) | ~12-15 B (key-preserve + welcome_active clear + render_mark_all_dirty CALL) | +14 B |
| AR23 docstrings (comment-only, 0 B) | comment-only | +0 B |
| **Total mid-estimate** |  | **+452 B** |

Per [[project_nfr9_cliff_edge]] memory: pad mid-estimates by +50-100 B for spec drift. Adjusted projection: **+452 + 50..100 = +502..552 B → post-4.2 ~8684..8734 B / ~84.8..85.3% of 10240 B / 1506..1556 B headroom.** Comfortably within the 1000 B-headroom AC requirement.

**Post-implementation reconciliation (2026-05-19, Q1 Option B chosen):**

| Item | Actual cost |
|---|---|
| `welcome_banner_rle` (222 B RLE data, replaces 359 B INCBIN) | +222 B |
| `welcome_paint` + `welcome_emit_cell` decoder/helper bodies + 2 B module-private scratch | +131 B |
| `fileio_load_initial.no_arg` arms `welcome_active = 1` | +5 B |
| `init_cold_start` Stage 6.5 `CALL NZ, welcome_paint` | +7 B |
| `vibe.asm` input_loop dismissal hook (PUSH AF / POP AF variant) | +15 B |
| **Total actual delta** | **+380 B** |

Final `vibe.com` = **8562 B / 83.6% of 10240 B / 1678 B headroom**. Came in 38 B *below* the original projection's lower bound (+418 B); driver was Q1-B's RLE saving ~137 B over the +359 B INCBIN path — partly offset by the new module's decoder body which the projection did not separately scope.

**Spec drift watch.** epics.md AC6 projects "+300-400 B"; this story's mid-estimate is +452 B (+52-152 B over the epic projection). Drift driver: the 359-byte INCBIN of `banner.txt` dominates the budget. Shrink-down levers if needed:
- **Lever 1 (RLE encoding of banner data, ~80 B savings):** replace `INCBIN` with a hand-rolled run-length-encoded data table (`{row_count_before, byte_count, byte_run...}` per line). banner.txt's visible content is ~270 B; the long runs of `#`, `m`, `"` could pack to ~200 B + ~30 B decode logic ≈ 230 B vs 359 B raw. Saves ~130 B; adds complexity.
- **Lever 2 (drop the empty banner.txt L1 + L9 + L12 lines, ~3 B savings):** banner.txt has 3 blank lines (just LFs) totalling 3 B; could skip-encode them in the paint routine. Negligible.
- **Lever 3 (use msg_mode_normal directly for status, do NOT introduce status text):** ALREADY chosen — no new status messages introduced (per AC1 "or equivalent" interpretation).

Per Story 4.1 dev-pass debug log entry on AC1 spec drift: dev MUST verify the actual `vibe.com` size at Task 5; if actual > 8900 B, apply Lever 1 before commit. The 5-bytes-of-savings ROI on Lever 2/3 is not worth the implementation complexity at this story's projected size.

**AC7 — Hardware UAT on real MicroBeast.**

**Given** UAT on hardware (Feersum MicroBeast + serial-attached terminal)
**When** the dev runs the 14-step UAT script (paste inline at dev-handoff per [[feedback_uat_inline_at_dev_handoff]] — see "Hardware UAT script" section near the end of this story)
**Then** all 14 steps behave per the AC narrative without flicker, drift, status-line corruption, or buffer contamination; the welcome screen dismisses cleanly on every input variant tested

**See "Hardware UAT script" section near the end of this story for the full AC7 walk-through.**

**AC8 — NFR18 byte-identical rebuild held.**

**Given** NFR18 byte-identical rebuild
**When** the tree is built clean twice after Story 4.2 lands (`make clean && make all` × 2)
**Then** both `vibe.com` SHA-256 digests match (no host-path or timestamp leakage introduced by the new `INCBIN`-of-banner.txt path)
**And** the SHA is recorded in the Dev Agent Record / Completion Notes List for future regression reference

**NFR18 INCBIN watch.** sjasmplus 1.23.0's `INCBIN` directive reads the file at assembly time and embeds the bytes verbatim — no timestamp / host-path leakage. The banner.txt content is the only variability; if banner.txt is identical across two clean builds, the resulting vibe.com sections containing the INCBIN'd bytes are identical. Confirm by `sha256sum banner.txt` in both build runs (should match).

## Tasks / Subtasks

- [x] **Task 0 — Cross-check + Q-pin resolution (per Epic-3 retro A4 / [[feedback_create_story_cross_check]])**
  - [x] 0.1 Verify post-4.1 baseline: `make sizes` reports `vibe.com = 8182 B / 79.9% of 10240 B / 2058 B headroom`; if drift, recompute the AC6 projection
  - [x] 0.2 Verify `banner.txt` exists at `/home/ant/src/microbeast/vibe/banner.txt`, is 359 B, and is in the git index (NOT gitignored)
  - [x] 0.3 Confirm sjasmplus `INCBIN` path resolves correctly from `src/render.asm`: relative path `"../banner.txt"` (from `src/render.asm`'s assembly directory) lands on `/home/ant/src/microbeast/vibe/banner.txt`. Document if a different relative path is needed.
  - [x] 0.4 Spot-check the 4 new sentinel codes (0x9B..0x9E) against `grep "DEFB[ \t]*0x9[A-E]\b" test/cases/*.asm` — confirm no existing test claims any byte in that band. (Story 4.1 sentinel-allocation notes: 0x9B..0x9F was "defensive slack"; Story 4.2 claims 0x9B..0x9E, leaves 0x9F as continuing slack.)
  - [x] 0.5 Resolve Q1-Q7 via `AskUserQuestion` with Ant; recommended pins all **Option A** unless flagged otherwise below
  - [x] 0.6 If any Q lands a non-A option, update the per-task subtasks below before starting Task 1

- [x] **Task 1 — AC1/AC2: Add `welcome_active` state byte** (`inc/state.inc`)
  - [x] 1.1 INSERT a new 1-byte field `welcome_active` in the single-byte state block. Recommended position: AFTER `input_held_flag` at line 89 (preserves the existing ordering; the new byte advances `static_off` by 1 — no other field offsets shift relative to `static_data_base` if added at the end of the small-state run). Specifically insert after line 90 (after `input_held_flag` `static_off += 1`):
    ```asm
    ; welcome_active — 1-byte one-shot flag controlling the FR53 welcome
    ; screen. Cold-start LDIR-zero-fill leaves it at 0. Writer: src/fileio.asm
    ; (fileio_load_initial.no_arg sets it to 1 on no-filename-arg launch — the
    ; only writer to 1 in the editor's lifetime). Clearer: src/vibe.asm
    ; (input_loop's dismissal hook — clears to 0 on first keystroke post-launch).
    ; Reader: src/init.asm (Stage 6.5 conditional CALL NZ, render_paint_welcome)
    ; and src/vibe.asm (dismissal hook). Story 4.2 / FR53.
    welcome_active        EQU static_data_base + static_off
    static_off            =   static_off + 1
    ```
  - [x] 1.2 Verify `static_block_size` ASSERT in init.asm (`ASSERT static_block_size > 1` at line 169) continues to hold (it does — block grows by 1 byte, still > 1).
  - [x] 1.3 Verify `inc/state.inc`'s `Public:` block header is updated (line 10-23 listing); add `welcome_active` to the "Small state" group.
  - [x] 1.4 NO `equates.inc` changes — `welcome_active` is a state cell, not a compile-time constant.

- [x] **Task 2 — AC1: Add banner data + `render_paint_welcome` routine** (`src/render.asm`)
  - [x] 2.1 (Q3) Place the new public entry `render_paint_welcome` inside `src/render.asm` near the other render-emit helpers (recommended position: just after `render_emit_goto` at line 1282, before the module-local scratch block at line 1285). Rationale: render.asm owns BIOS_CONOUT (AR13), shadow_buffer (AR12-read for status / module-owned for editable cells), and the screen-emission path. Welcome paint is one more screen-emit site under render's umbrella; placing it in render.asm avoids adding a new module to the AR25 INCLUDE chain.
  - [x] 2.2 (Q1 Option A) ADD a banner-data block via `INCBIN`:
    ```asm
    ;; --- Welcome banner data (Story 4.2 / FR53) ---
    ; banner.txt at project root: 359 B, 13 LF-terminated lines.
    ; The paint routine walks this block byte-by-byte; LF (0x0A) advances
    ; the screen row and resets the column to 0. The 13-line banner is
    ; anchored at internal row 5 (vertically centered in 23 editable rows).
    ; NFR18: INCBIN reads the file at assembly time; sjasmplus 1.23.0
    ; embeds bytes verbatim (no timestamp / host-path leakage). banner.txt
    ; lives in the git index; build is reproducible.
    welcome_banner_data:
        INCBIN "../banner.txt"
    welcome_banner_data_end:
        ASSERT  welcome_banner_data_end - welcome_banner_data == 359
    ```
    *Path is relative to `src/render.asm`'s assembly directory — verify per Task 0.3.*
  - [x] 2.3 ADD `render_paint_welcome` routine. Body sketch (dev pass refines the exact layout):
    ```asm
    ; ----------------------------------------------------------------
    ; render_paint_welcome
    ; FR53 entry: paint the 13-line VIBE banner vertically centered in the
    ; 23-row editable area (rows 5..17), then reposition cursor to row 0
    ; col 0 (matches cursor_offset = 0 on the empty buffer). Walks
    ; welcome_banner_data byte-by-byte:
    ;   - LF (0x0A) advances internal row counter and resets col to 0;
    ;     emits ESC Y row,0 to position the cursor for the next row.
    ;   - Any other byte emits via render_emit_byte AND writes the same
    ;     byte to shadow_buffer[row * SCREEN_COLS + col], then INC col.
    ;     col-clamp: if col >= SCREEN_COLS the byte is dropped (defensive
    ;     against a long banner line; banner.txt lines are <= 40 cols).
    ; End-of-data (HL == welcome_banner_data_end): emit ESC Y 0,0 to
    ; reposition cursor for the user; RET.
    ;
    ; AR13: this is render.asm's sole new screen-emit site (Story 4.2);
    ; renders BIOS_CONOUT bytes via render_emit_byte transitively.
    ; AR14: reads NO gap-buffer state; writes ONLY shadow_buffer (an AR12
    ; render-owned cell).
    ;
    ; In:      (none — banner data + start row + screen geometry are all
    ;          compile-time-constant or module-private)
    ; Out:     banner glyphs emitted to screen at rows 5..17; shadow_buffer
    ;          rows 5..17 hold the banner glyphs (so a subsequent
    ;          render_diff after render_mark_all_dirty sees shadow != target
    ;          and emits spaces to clear); cursor positioned at row 0,
    ;          col 0 via ESC Y emit. dirty_rows untouched (caller manages
    ;          dirty-tracking).
    ; Trashes: A, BC, DE, HL, F.
    ; Calls:   render_emit_byte, render_emit_goto.
    ; ----------------------------------------------------------------
    render_paint_welcome:
        ;; Position to row 5, col 0.
        LD      A, 5                ; banner top row (vertical center)
        LD      C, 0                ; col 0
        CALL    render_emit_goto

        ;; Walk banner data; B = current row, C = current col.
        LD      HL, welcome_banner_data
        LD      B, 5                ; current screen row
        LD      C, 0                ; current col within row
    .loop:
        LD      A, L
        CP      LOW welcome_banner_data_end
        JR      NZ, .not_end_lo
        LD      A, H
        CP      HIGH welcome_banner_data_end
        JR      Z, .done            ; HL == end → finish
    .not_end_lo:
        LD      A, (HL)
        CP      0x0A                ; LF?
        JR      Z, .newline
        ;; Emit byte + sync shadow.
        ;; Defensive col-clamp (shouldn't trigger for banner.txt;
        ;; safety net for a 80-col banner row overflow).
        LD      A, C
        CP      SCREEN_COLS
        JR      NC, .skip_emit
        ;; Compute shadow_buffer + row * 80 + col into DE.
        PUSH    HL
        LD      L, B                ; HL = row
        LD      H, 0
        ;; row * 80 = row * 64 + row * 16 = (row << 6) + (row << 4)
        ADD     HL, HL              ; ×2
        ADD     HL, HL              ; ×4
        ADD     HL, HL              ; ×8
        ADD     HL, HL              ; ×16
        LD      D, H
        LD      E, L                ; DE = row × 16
        ADD     HL, HL              ; ×32
        ADD     HL, HL              ; ×64
        ADD     HL, DE              ; HL = row × (64+16) = row × 80
        LD      DE, shadow_buffer
        ADD     HL, DE              ; HL = shadow_buffer + row*80
        LD      D, 0
        LD      E, C
        ADD     HL, DE              ; HL = shadow_buffer + row*80 + col
        LD      A, (HL)             ; save shadow byte? unnecessary
        POP     DE                  ; restore HL (banner data ptr) — see note
        ;; (alternative: avoid the PUSH/POP by tracking banner ptr in DE
        ;;  and using HL for shadow address. Dev pass picks the cleanest
        ;;  register layout.)
        LD      A, (DE)             ; A = byte to emit
        LD      (HL), A             ; shadow update
        ;; Emit via render_emit_byte
        ;; ... (PUSH BC/DE/HL as needed across the call)
        CALL    render_emit_byte
        ;; restore HL (banner ptr) — dev-pass-specific
    .skip_emit:
        INC     C
        INC     HL                  ; advance banner data ptr
        JR      .loop
    .newline:
        INC     B                   ; advance screen row
        LD      C, 0                ; reset col
        INC     HL                  ; consume the LF
        LD      A, B
        CP      SCREEN_ROWS         ; defensive: don't exceed row 23
        JR      NC, .done
        LD      A, B
        LD      C, 0
        CALL    render_emit_goto
        JR      .loop
    .done:
        ;; Cursor reposition to row 0, col 0 (matches cursor_offset=0).
        XOR     A
        LD      C, A
        JP      render_emit_goto    ; tail-JP
    ```
    Estimated size: ~50-80 B (varies with register layout). Dev pass will simplify the inner loop; the above is a conservative outline pinning the contract.
  - [x] 2.4 EXTEND render.asm's module-header `Public:` block (line 45-55) to list `render_paint_welcome`.
  - [x] 2.5 EXTEND render.asm's `State owned` block to note `shadow_buffer` is written by `render_paint_welcome` (in addition to the existing `render_init` + `render_diff` writers).
  - [x] 2.6 EXTEND render.asm's `Register conventions` block with the `render_paint_welcome` In/Out/Trashes/Calls quartet (per AR23).
  - [x] 2.7 NO CHANGES to existing `render_init` / `render_diff` / `render_full` / `render_mark_*` bodies. The welcome paint is additive; the existing render contracts are unchanged.

- [x] **Task 3 — AC1: Set `welcome_active` in `fileio_load_initial.no_arg`** (`src/fileio.asm`)
  - [x] 3.1 (Q5 Option A) MODIFY `fileio_load_initial.no_arg` at `src/fileio.asm:945-951`. INSERT before the existing `LD HL, msg_mode_normal` line:
    ```asm
    .no_arg:
        ;; Story 4.2 / FR53: no-arg launch — arm the welcome screen.
        ;; init_cold_start Stage 6.5 reads welcome_active after render_full
        ;; and calls render_paint_welcome if set. The first keystroke in
        ;; input_loop clears the flag.
        LD      A, 1
        LD      (welcome_active), A

        ;; (existing body — unchanged) Seed status row with msg_mode_normal.
        LD      HL, msg_mode_normal
        XOR     A
        JP      status_set_message      ; tail-JP
    ```
    Cost: 5 B (LD A,1 = 2 B; LD (welcome_active),A = 3 B).
  - [x] 3.2 EXTEND `fileio_load_initial`'s AR23 docstring header block (line 884-895) to note the `welcome_active = 1` side-effect on the `.no_arg` path. NO change to the existing `.no_arg` post-condition list — `welcome_active` is a NEW post-condition, not a modification of an existing one.
  - [x] 3.3 NO CHANGES to `fileio_load_initial`'s other three paths (load-success, new-file, too-large/read-error). `welcome_active` stays 0 (its LDIR cold-start default) on every path EXCEPT `.no_arg`.

- [x] **Task 4 — AC1: Stage 6.5 conditional paint call in `init_cold_start`** (`src/init.asm`)
  - [x] 4.1 MODIFY `init_cold_start` body at `src/init.asm:335-339`. INSERT a new Stage 6.5 between Stage 6 (`CALL render_full` at line 336) and Stage 7 (`JP input_loop` at line 339):
    ```asm
        ;; --- Stage 6: initial full redraw ---
        CALL    render_full

        ;; --- Stage 6.5: paint welcome banner if no-arg launch (Story 4.2 / FR53) ---
        ;; fileio_load_initial.no_arg (Stage 5) set welcome_active = 1
        ;; on a bare `vibe` launch. render_paint_welcome paints the
        ;; banner over the empty editing area (cleared by Stage 6's
        ;; render_full) and updates shadow_buffer in lock-step, so the
        ;; first-keystroke render_mark_all_dirty + render_diff in the
        ;; input loop produces a proper banner-to-spaces diff emit.
        ;; welcome_active stays 0 on every other Stage-5 path (file
        ;; load, new-file, too-large, read-error) — the conditional
        ;; CALL NZ short-circuits and Stage 7 falls through directly.
        LD      A, (welcome_active)
        OR      A
        CALL    NZ, render_paint_welcome

        ;; --- Stage 7: fall through to the main input loop ---
        JP      input_loop
    ```
    Cost: 9 B (LD A,(welcome_active) = 3 B; OR A = 1 B; CALL NZ,render_paint_welcome = 3 B; plus 2 B for the welcome_active 16-bit address load).
  - [x] 4.2 EXTEND `init_cold_start`'s header documentation block (line 175-268) to describe the new Stage 6.5. Specifically insert a new Stage entry after the existing Stage 6 description at lines 248-252:
    ```
    ;   Stage 6.5: If welcome_active is set (no-arg launch armed it at
    ;      Stage 5), call render_paint_welcome to overlay the FR53 VIBE
    ;      banner on the just-cleared editing area. The paint routine
    ;      emits banner glyphs to screen AND writes them to shadow_buffer,
    ;      so the first-keystroke dismissal (input_loop hook → mark all
    ;      editable dirty → render_diff) produces a proper shadow-to-target
    ;      diff that emits spaces over every banner cell. On non-no-arg
    ;      paths welcome_active stays 0 and the conditional CALL NZ
    ;      short-circuits — zero observable effect for launch-with-filename.
    ;      Story 4.2.
    ```
  - [x] 4.3 EXTEND init.asm's `Dependencies:` block (line 142-153) to add `src/render.asm` (`render_paint_welcome`).
  - [x] 4.4 NO CHANGES to init_teardown — the warm-boot path doesn't need to clear `welcome_active`; the next .com launch re-runs the Stage 1 LDIR which zero-inits the flag.

- [x] **Task 5 — AC3: Welcome-dismissal hook in `input_loop`** (`src/vibe.asm`)
  - [x] 5.1 (Q4 Option A) MODIFY `input_loop` body at `src/vibe.asm:224-270`. INSERT the dismissal hook between the existing `CALL input_get_key` at line 227 and the existing `LD C, A` at line 234. Pattern (the dev pass refines register allocation):
    ```asm
    input_loop:
        ;; 1. Get next keystroke. RI5 disambig (Esc / arrow, ~40 ms tick
        ;;    window) is internal to input_get_key.
        CALL    input_get_key

        ;; 1.5. Welcome-screen dismissal hook (Story 4.2 / FR53).
        ;; One-shot: welcome_active is set to 1 ONLY by fileio_load_initial.no_arg
        ;; at cold-start (no-arg launch). The first keystroke clears it AND
        ;; forces a full editable-area redraw so the post-dispatch render_diff
        ;; repaints over the banner glyphs that sit in shadow_buffer at rows
        ;; 5..17 (the target byte for every editable cell on the empty buffer
        ;; is 0x20 = space, so the diff naturally emits spaces over each
        ;; banner cell). After this hook fires once, welcome_active stays 0
        ;; for the editor's lifetime — even if buffer returns to empty
        ;; (FR53 "not redrawn on any subsequent input"; story 4.2 AC4).
        PUSH    AF                          ; preserve key byte across stores
        LD      A, (welcome_active)
        OR      A
        JR      Z, .no_welcome
        XOR     A
        LD      (welcome_active), A
        CALL    render_mark_all_dirty
    .no_welcome:
        POP     AF                          ; restore key byte

        ;; 2. Per-mode dispatch-table demultiplex. (UNCHANGED from Story 2.1.)
        LD      C, A
        LD      A, (mode_byte)
        ;; ... (rest of input_loop body unchanged)
    ```
    Cost: ~13-15 B (PUSH/POP AF = 2 B; LD A,(welcome_active) = 3 B; OR A = 1 B; JR Z,.no_welcome = 2 B; XOR A = 1 B; LD (welcome_active),A = 3 B; CALL render_mark_all_dirty = 3 B).
  - [x] 5.2 (Alternative — Q4 Option B if Ant flags PUSH/POP cost) Move the hook to AFTER the existing `LD C, A` (so the key is saved in C and AF can be freely clobbered):
    ```asm
        CALL    input_get_key
        LD      C, A                        ; save key (existing)

        LD      A, (welcome_active)
        OR      A
        JR      Z, .no_welcome
        XOR     A
        LD      (welcome_active), A
        CALL    render_mark_all_dirty
    .no_welcome:
        LD      A, (mode_byte)              ; (existing) — A is now mode, C is key
    ```
    Saves 2 B (no PUSH/POP AF). Costs: the dismissal hook MUST run before `LD A, (mode_byte)` because `render_mark_all_dirty` may trash A and a future variant might need mode_byte. Dev pass picks the variant.
  - [x] 5.3 EXTEND vibe.asm's module-header `input_loop` description (line 12-36) to note the welcome-dismissal hook responsibility. NEW bullet under "Loop body":
    ```
    ;   * Welcome-dismissal hook (Story 4.2 / FR53): between input_get_key
    ;     and the per-mode dispatch, clears welcome_active + calls
    ;     render_mark_all_dirty so the next render_diff repaints over the
    ;     banner glyphs. One-shot; benign no-op after first dismissal.
    ```
  - [x] 5.4 NO CHANGES to the per-mode dispatch tables, `dispatch_key`, `render_diff`, or any handler body. The hook is additive at the loop top.

- [x] **Task 6 — AC1/AC2/AC3: Author 4 new headless tests** (`test/cases/`)
  - [x] 6.1 Sentinel-band allocation: claim 0x9B..0x9E (4 bytes from the "defensive slack" band per Story 4.1 sentinel notes; 0x9F stays defensive slack).
  - [x] 6.2 Author `test/cases/init_welcome-shown-no-arg.asm` (T1 — sentinel 0x9B):
    - Setup: pre-zero static block (test prologue handles); pre-set `DEFAULT_FCB + 1 = 0x20` (no-arg sentinel); call `fileio_load_initial` (NOT full `init_cold_start` — focused unit test on the flag-setting); then DIRECTLY call `render_paint_welcome` to exercise the paint path (since the full init Stage 6.5 chain requires `render_full` which requires BIOS_CONOUT capture).
    - Assert: `welcome_active == 1` post `fileio_load_initial`; `shadow_buffer[5 * 80 + 0] == ' '` (banner line 1 is blank, so first byte is the LF — but LF advances the row, so shadow row 5 stays seeded with the render_init 0x20); `shadow_buffer[6 * 80 + 1] == 'm'` (banner line 2 char at col 1 is the first 'm' of " mm    mm   mmmmmm..."); status_buffer reflects msg_mode_normal (80 spaces).
    - Use the BIOS_CONOUT capture override (per `init_cold_start-state-shape.asm` pattern at lines 28-34) so the paint's BIOS_CONOUT emits land in a capture buffer rather than escaping to the test's stdout (which would collide with the PASS/FAIL grep).
  - [x] 6.3 Author `test/cases/init_welcome-hidden-with-arg.asm` (T2 — sentinel 0x9C):
    - Setup: pre-populate `DEFAULT_FCB` with a valid filename (use `test/fixtures/hello.txt` — 13 B fixture from Story 2.2/2.3); `DEFAULT_FCB+0 = 0` (default drive → B: per FR9), `DEFAULT_FCB+1..+8 = "HELLO   "`, `DEFAULT_FCB+9..+11 = "TXT"`; call `fileio_load_initial`.
    - Assert: `welcome_active == 0` (load-success path does NOT set it); `shadow_buffer` content matches loaded file (via the subsequent render_full Stage 6 — but this test doesn't call render_full; instead it asserts JUST the flag state, leaving the render assertion to T1 / hardware UAT); `filename_buffer[0..11] = "B:HELLO.TXT" + NUL`.
  - [x] 6.4 Author `test/cases/welcome_dismissed-on-first-key.asm` (T3 — sentinel 0x9D):
    - Setup: pre-zero static block; manually set `welcome_active = 1`; pre-seed shadow_buffer at row 5+ with sentinel bytes (e.g. all 'B' bytes at offset shadow_buffer + 5*80 .. shadow_buffer + 17*80 = simulating banner-on-screen); pre-set input_get_key to return 'i' (use a test-local stub that returns a configured byte — see `test/inc/test_input_get_key_stub.inc` if it exists, or local stub).
    - Drive ONE iteration of input_loop's hook + dispatch + render_diff sequence (the test harness manually emulates this — it's a unit test, not an end-to-end run).
    - Assert: post-hook `welcome_active == 0`; `dirty_rows` had all editable bits set (then cleared by render_diff); `shadow_buffer[5*80 + 0] == 0x20` (banner glyphs replaced by spaces); `mode_byte == MODE_INSERT` ('i' processed normally per AC3).
    - **Alternative simpler test:** isolate just the dismissal-hook logic — call a hypothetical `welcome_dismiss_if_active` helper if one exists; otherwise drive the hook bytes directly. Dev pass picks the cleanest scaffolding.
  - [x] 6.5 Author `test/cases/welcome_does-not-redraw-after-dismiss.asm` (T4 — sentinel 0x9E):
    - Setup: pre-zero static block; pre-set `welcome_active = 0` (post-dismissal state — no-arg launched, key dismissed, editor in normal mode); simulate a `dd` mutation (or `:e empty.txt`) bringing buffer back to file_length=0.
    - Assert: `welcome_active` stays 0; no code path (fileio.asm, render.asm, edits.asm, undo.asm) ever sets `welcome_active = 1` post-cold-start — this is structurally guaranteed by the fact that `fileio_load_initial.no_arg` is the only writer to 1, and `fileio_load_initial` is only called from `init_cold_start` Stage 5 (which runs once per .com launch).
    - **Note:** this test is principally a regression net against a future story accidentally adding a second writer to `welcome_active`. The assertion is: post all the simulated mutations, `welcome_active == 0`.
  - [x] 6.6 Add the 4 new test files to the test discovery list (per Story 4.1 Task 4.12 — `make test` uses glob auto-discovery; no Makefile edits needed).

- [x] **Task 7 — AC1: Update `init_default-fcb-no-arg.asm` regression test** (`test/cases/init_default-fcb-no-arg.asm`)
  - [x] 7.1 EXTEND the existing init_default-fcb-no-arg.asm test to add a 6th subtest:
    ```asm
    ;; --- Subtest 6: welcome_active == 1 (Story 4.2 / FR53) ---
    LD      A, (welcome_active)
    CP      1
    JR      Z, .pass_6
    LD      A, 0x9B                 ; reuse Story 4.2 T1 sentinel for the assert
    JP      test_fail
    .pass_6:
    ```
  - [x] 7.2 EXTEND `init_default-fcb-no-arg.asm`'s sentinel-codes header block (currently 0xE0..0xE6) with the new 0x9B mapping for the welcome_active assertion. (Keep the 0xE-band for the existing init-related sentinels; the new welcome assertion borrows the Story 4.2 sentinel range to keep the test's intent clear.)

- [x] **Task 8 — AC1/AC2: Update `init_cold_start-state-shape.asm` regression test** (`test/cases/init_cold_start-state-shape.asm`)
  - [x] 8.1 EXTEND the existing state-shape test to add a `welcome_active == 1` assertion. The current test uses iz-cpm with no command-line filename (matches the no-arg launch sentinel), so `fileio_load_initial.no_arg` will fire and Stage 5 will set welcome_active=1 + Stage 6.5 will call render_paint_welcome. Add to the assertions block (typically lines 130-200 of the test):
    ```asm
    ;; welcome_active == 1 (Story 4.2: no-arg launch arms the welcome screen)
    LD      A, (welcome_active)
    CP      1
    JR      Z, .pass_welcome
    LD      A, 0x9C                 ; reuse Story 4.2 T2 sentinel
    JP      test_fail
    .pass_welcome:
    ```
  - [x] 8.2 Verify shadow_buffer at rows 5..17 contains banner content post-Stage 6.5 — extend the shadow_buffer assertion to spot-check a specific banner cell:
    ```asm
    ;; shadow_buffer[5*80 + 1] should NOT be 0x20 (the banner's first
    ;; visible char on row 5 is at col 1: the first 'm' of " mm    mm...").
    ;; Wait — row 5 is the BLANK first banner line (banner.txt's line 1 is
    ;; just an LF). So shadow_buffer[5*80 + x] for all x is still 0x20.
    ;; The first non-space banner glyph lands at row 6 (banner line 2),
    ;; col 1 (' mm    mm...' — first 'm' at col 1).
    LD      A, (shadow_buffer + 6*80 + 1)
    CP      'm'
    JR      Z, .pass_shadow_glyph
    LD      A, 0x9D                 ; reuse Story 4.2 T3 sentinel
    JP      test_fail
    .pass_shadow_glyph:
    ```

- [x] **Task 9 — AC6: NFR9 size verification**
  - [x] 9.1 `make sizes` after Tasks 1-8 land; capture the listing verbatim
  - [x] 9.2 Confirm `vibe.com` is within `8600..8900 B` projected range with at least 1000 B residual headroom under the 10240 B ceiling
  - [x] 9.3 If actual size > 8900 B (yellow zone) or > 9240 B (= 1000 B headroom limit, red zone), apply Lever 1 (RLE banner encoding) per AC6's shrink-down section before commit. Estimated savings: ~130 B.

- [x] **Task 10 — AC7: Hardware UAT on real MicroBeast** (paste inline at dev-handoff per [[feedback_uat_inline_at_dev_handoff]] — see section "Hardware UAT script" near end of this story)

- [x] **Task 11 — AC8: NFR18 byte-identical rebuild**
  - [x] 11.1 `make clean && make all` × 2; capture `vibe.com` SHA-256 both times
  - [x] 11.2 Verify SHAs match (NFR18); record in Completion Notes List
  - [x] 11.3 Also verify `sha256sum banner.txt` matches across the two runs (sanity check on the INCBIN source).

- [x] **Task 12 — Commit + close** (Q6 — recommended Option A: single commit covering banner + paint routine + state byte + Stage 6.5 + dismissal hook + 4 tests + 2 regression-test extensions, matching Epic-3 / Story-4.1 single-commit pattern)
  - [x] 12.1 Stage all modified files: `inc/state.inc`, `src/render.asm`, `src/fileio.asm`, `src/init.asm`, `src/vibe.asm`, 4 new test files (`test/cases/init_welcome-shown-no-arg.asm`, `init_welcome-hidden-with-arg.asm`, `welcome_dismissed-on-first-key.asm`, `welcome_does-not-redraw-after-dismiss.asm`), 2 modified regression tests (`test/cases/init_default-fcb-no-arg.asm`, `init_cold_start-state-shape.asm`)
  - [x] 12.2 Commit with message `Story 4.2: welcome screen on no-argument launch — FR53 closes` (matches Epic-3/4 commit style)
  - [x] 12.3 Update `_bmad-output/implementation-artifacts/deferred-work.md`: mark "FR53 welcome screen on no-argument launch" as **CLOSED by Story 4.2** (if such an entry exists)
  - [x] 12.4 Update `_bmad-output/implementation-artifacts/sprint-status.yaml` status `4-2-welcome-screen-on-no-argument-launch: review` after dev pass; flip to `done` after Ant confirms hardware UAT

### Review Findings (post-merge code review, 2026-05-19)

Generated by `/bmad-code-review` against commit `1c9e759` (Story 4.2 single-commit). 3 reviewer layers (Blind Hunter / Edge Case Hunter / Acceptance Auditor) ran in parallel against the 2464-line diff and the 922-line spec. Findings deduplicated and triaged below.

**Resolution summary** (after Ant's triage 2026-05-19):
- **2 patches applied to test code + story narrative** (D1 + D4 below), **2 patches applied to Dev Agent Record** (P1 + P2 below) — see [x] markers.
- **2 findings moved to deferred-work.md** (D2 + D3 below, hardware-UAT covered or structural argument accepted).
- **9 originally-deferred items + 5 dismissed-as-noise items** appended to `deferred-work.md` under `## Deferred from: code review of 4-2-welcome-screen-on-no-argument-launch (2026-05-19)`.

**Decision-needed (resolved)** (4):

- [x] [Review][Patched-D1] AC4 regression net strengthened — `welcome_does-not-redraw-after-dismiss.asm` Op 5 was changed from a misleading "defensive welcome_paint call" to a real **op_dd-on-1-line round-trip** (sets up "abc\n", count=1, calls op_dd, asserts file_length returns to 0 AND welcome_active stays 0 — exercises the FR29 buffer-returns-to-empty path the spec narrative named). New **Op 6** sweeps `shadow_buffer[5*80..18*80)` (1040 cells) and asserts every cell == 0x20 — catches a future writer that paints banner glyphs into shadow without arming `welcome_active`. The `:e empty.txt` (FR6) variant was NOT added in this patch (drive-B FCB scaffolding + EMPTY.TXT fixture-stability story required — captured as a follow-up in deferred-work.md). Test still passes (272 pass / 1 deliberate-fail unchanged). Production code untouched; NFR18 SHA `cfeaf4c654...` × 2 verified. Sources: Acceptance Auditor A5, Blind Hunter B8, Edge Case Hunter E5.
- [x] [Review][Defer-D2] AC3 headless coverage stays inlined-replica-only — deferred to follow-up after Ant's triage (hardware UAT exercises i / : / Esc / Ctrl-L / digit; drift would surface on next UAT cycle). Tracked in `deferred-work.md`. Sources: Blind Hunter B2, Edge Case Hunter E6.
- [x] [Review][Defer-D3] AC2 test coverage stays at `.new_file` branch only — deferred to follow-up after Ant's triage (structural argument: all non-no-arg branches converge on bypassing `fileio_load_initial.no_arg`; the existing test pins the most-changed branch). Tracked in `deferred-work.md`. Sources: Acceptance Auditor A4, Blind Hunter B7.
- [x] [Review][Patched-D4] AC1/AC3 narratives amended to match shipped implementation — (a) AC1 line 23 now names `welcome_paint` with a symbol-rename note; (b) AC1 line 20 now describes the RLE encoding + horizontal-centering per-row col_starts (replaces the "matches banner.txt verbatim" promise that the post-UAT centering pass invalidated); (c) AC3 hook snippet (lines 63-72) rewritten to show the actual PUSH AF / POP AF variant — removed the misleading `LD A, (input_held_byte)` alternative since `input_held_byte` is the RI5 disambig cell, not a key-preservation cell; (d) AR13 paragraph (line 545) extended to note the cross-module promotion of `render_emit_byte` / `render_emit_goto` to render.asm's public surface (Q3-B consequence). Sources: Acceptance Auditor A1, A2, A8, A9.

**Patch (applied)** (2):

- [x] [Review][Patched-P1] AC8 Dev Agent Record updated — the SHA section in the Debug Log References (was line 919) now records BOTH the pre-centering dev-pass SHA (`46f285c3...` × 2) and the **post-UAT shipped SHA `cfeaf4c654...` × 2**, explicitly identifying the latter as the binding NFR18 record for commit `1c9e759`. banner.txt's role re-described accurately (no longer INCBIN'd under Q1-B; retained as canonical reference). [_bmad-output/implementation-artifacts/4-2-welcome-screen-on-no-argument-launch.md:919-923]
- [x] [Review][Patched-P2] AC6 projection table reconciled — original "Detailed projection (pre-Q1-B)" preserved as the historical INCBIN-route estimate; new **Post-implementation reconciliation** table records the Q1-Option-B actuals (welcome_banner_rle 222 B + decoder 131 B + 5 + 7 + 15 = **+380 B**, vibe.com = 8562 B / 83.6% / 1678 B headroom). Explicit note that the actual landed 38 B *below* the original projection's lower bound — benign (RLE saving ~137 B over INCBIN partly offset by new module's decoder body). [_bmad-output/implementation-artifacts/4-2-welcome-screen-on-no-argument-launch.md:99-128]

**Deferred** (9, all checked off — pre-existing or out-of-scope for this review):

- [x] [Review][Defer] No bounds check on `welcome_paint_col` / `welcome_paint_row` in `welcome_emit_cell` — RLE format permits col_start up to 0x7D (col 125) and unbounded row count via 0xFF blank-row markers; OOB writes would corrupt state past `shadow_buffer`. [src/welcome.asm:282-313, 243-248] — deferred, banner is static and ASSERT-pinned at 222 B; defensive only against future banner-asset edits. Sources: B11, E2, E3, E4.
- [x] [Review][Defer] Banner RLE has no structural integrity assertion beyond `welcome_banner_rle_end - welcome_banner_rle == 222`. 0xFF as a legitimate literal glyph would be mis-framed as EOR. [src/welcome.asm RLE asset] — deferred, format is hand-encoded once; future banner edits would re-trigger this review path. Sources: B6, E11.
- [x] [Review][Defer] `welcome_paint` depends on `render_init` having seeded `shadow_buffer` with 0x20 — non-glyph cells stay at the seed value rather than being explicitly painted. A future reorder of Stage 6 / Stage 6.5 would expose uninitialized shadow. [src/welcome.asm:89-95 / src/init.asm:352-372] — deferred, ordering is stable and Stage 6 runs unconditionally. Sources: B10, E9.
- [x] [Review][Defer] No assertion on `welcome_active` field offset stability in `inc/state.inc` — LDIR Stage 1 zero-fill writes the byte, but a future state.inc field reorder could shift relative offsets used by hardcoded test sentinels (e.g., `shadow_buffer + 6*80 + 21`). [inc/state.inc:103] — deferred, NFR18 byte-identical rebuild discipline catches layout drift via SHA divergence. Sources: B12, E12.
- [x] [Review][Defer] Hook `PUSH AF / POP AF` bracket preserves A and F only — relies on `render_mark_all_dirty` doc-comment "Trashes: A, F" forever. A future change that adds BC/DE/HL clobber would corrupt the key byte in C downstream. [src/vibe.asm:276-284] — deferred, render_mark_all_dirty is one-page bit-set primitive unlikely to grow. Source: E7.
- [x] [Review][Defer] `shadow_buffer[5*80+0] == 0x20` test assertion in `init_welcome-shown-no-arg.asm` cannot distinguish "untouched render_init seed" from "welcome_emit_cell wrote a space cell". Stronger pattern: poison shadow with 0xAB pre-call, assert it survives at row 5 col 0. [test/cases/init_welcome-shown-no-arg.asm:147-154] — deferred, defensive test-strengthening. Source: E8.
- [x] [Review][Defer] AC3 cursor-blink position (ESC Y 0,0 trailing emit) verified only via hardware UAT; no headless assertion that `test_capture_buffer` contains the position sequence. [test/cases/init_welcome-shown-no-arg.asm] — deferred, hardware UAT step 1 covers; matches the AC4-Esc gap in scope. Source: A3.
- [x] [Review][Defer] `welcome_paint` is single-call by construction but the docstring "In:" contract does not mark it non-reentrant. A pre-input render fired between Stage 6.5 and `input_get_key` would erase the banner before the user sees it. [src/welcome.asm:140-150, src/init.asm:368-371] — deferred, no second caller exists today; flag for future re-entry. Sources: E1, E10.
- [x] [Review][Defer] Magic constant `0,0` cursor home in `welcome_paint.done` — no symbolic `EDITABLE_TOP_ROW` constant; a future title-bar-at-row-0 story would land the cursor mid-banner. [src/welcome.asm:289-292] — deferred, no editor-area-bias change is planned. Source: B5.

**Dismissed as noise** (5):

- Register-clobber contract Stage 6.5 → input_loop: input_loop is entry-state agnostic by design (B1).
- Shadow-write-before-emit ordering in `welcome_emit_cell`: BIOS_CONOUT in the current architecture cannot fail; no out-of-sync path exists (B3).
- `render_emit_byte` DE/HL-preservation contract dependency: unchanged invariant from prior stories; not introduced by this PR (B4).
- Hook PUSH AF / read / OR A inside brackets is "wasted T-states": premature micro-optimisation; cold path fires for one keystroke only (B9).
- `welcome_paint_col` reset asymmetry vs `welcome_paint_row` explicit reset: works by construction (every non-blank row's col_start handling rewrites `welcome_paint_col`) (B13).

## Dev Notes

### Architecture compliance

**AR boundaries — Story 4.2 stays clean across all four AR surfaces.**

- **AR12 (status funnel):** zero new direct call sites. `fileio_load_initial.no_arg`'s existing `JP status_set_message` (msg_mode_normal) is preserved; no new status text introduced. `render_paint_welcome` does NOT call `status_set_message` (it paints to editable rows only; status row is untouched). The `vibe.asm` input_loop dismissal hook does NOT call `status_set_message` (it operates on dirty_rows + welcome_active only).
- **AR13 (BIOS_CONOUT):** `render.asm` remains the sole BIOS_CONOUT call site in production code. Under Q3 Option B the paint routine landed as `welcome_paint` in a new module `src/welcome.asm`, which calls `render_emit_byte` + `render_emit_goto` cross-module. Both helpers were previously module-private to render.asm; Story 4.2's Q3-B consequence is that they're promoted to render.asm's `Public:` surface. The AR13 invariant (single BIOS_CONOUT executor) holds — render.asm is still the only module that emits to the BIOS — but the *public surface* of render.asm has widened by two entries. Post-Story 4.2: `grep -nE 'BIOS_CONOUT' src/*.asm` continues to return matches ONLY inside `src/render.asm`.
- **AR14 (gap_start / gap_end WRITES):** unchanged ownership — `gapbuf.asm` remains the sole writer. `render_paint_welcome` reads NOTHING from the gap buffer (it paints the static banner asset). The dismissal hook reads NOTHING from the gap buffer. `fileio_load_initial.no_arg`'s body is unchanged except for the `LD (welcome_active), A` addition — gap-buffer state is untouched on that path. Post-Story-4.2 grep `LD (gap_start),\|LD (gap_end),` against `src/render.asm` continues to return zero matches; same for `src/vibe.asm`.
- **AR15 (BDOS_CALL):** zero new call sites. `render_paint_welcome` is BDOS-free. The dismissal hook is BDOS-free. The existing AR15 carve-outs in `fileio_load_initial` (Story 2.3 launch carve-out) are unchanged.

**AR23 (per-module header convention)** — Story 4.2 EXTENDS three AR23 docstrings:
1. `render.asm` module header — add `render_paint_welcome` to the `Public:` block + new `Register conventions` quartet + `State owned` shadow_buffer note (Task 2.4-2.6)
2. `fileio.asm` module header (or `fileio_load_initial`'s AR23) — add `welcome_active = 1` to the `.no_arg` post-condition list (Task 3.2)
3. `init.asm` module header — add Stage 6.5 to the cold-start sequence description + add `src/render.asm (render_paint_welcome)` to Dependencies (Tasks 4.2-4.3)
4. `vibe.asm` `input_loop` description — add welcome-dismissal hook bullet (Task 5.3)

Plus the NEW AR23 docstring on `render_paint_welcome` itself (Task 2.3) following the standard In/Out/Trashes/Calls format.

**AR25 (INCLUDE order)** — Story 4.2 adds NO new INCLUDEs to `src/vibe.asm`. The existing AR25 chain (unchanged from Story 4.1) is preserved. `render_paint_welcome` lives inside `src/render.asm` (already in the chain at position 5: gapbuf → render → dispatch → parser → motions → ...). No forward-ref challenges: `fileio.asm` (chain position 9) and `init.asm` (chain position 1 — via the INCLUDE inside vibe.asm at line 78) both call `render_paint_welcome` and `render_mark_all_dirty`; render.asm is INCLUDED before both via the AR25 order, so the symbol is backward-resolved at the call sites. `welcome_active` is an EQU declared in `state.inc` (chain position last — anchored past code); both the writers (fileio.asm, vibe.asm) and the readers (init.asm, vibe.asm) reference it via the EQU which sjasmplus resolves on the first pass.

**MC1 (caller-saved register convention)** — `render_paint_welcome` trashes A, BC, DE, HL, F (no callee-saved). The dismissal hook in vibe.asm preserves AF via PUSH/POP across the state writes (Task 5.1 Option A; cost +2 B) — or alternatively moves the hook to after the existing `LD C, A` so AF is free to clobber (Task 5.2 Option B; saves 2 B but reorders the hook against the `LD C, A`).

**MC4 (handler signature)** — the dismissal hook is NOT a handler — it's a top-of-loop preprocessor that runs before per-mode dispatch. The MC4 contract still holds for downstream dispatch (`LD C, A` then `LD A, (mode_byte)` etc. all unchanged).

**MC5 (status-message funnel)** — no new status messages introduced. msg_mode_normal (empty banner) preserved on the no-arg path. The AR16 "lowercase, no trailing period, under 30 chars" discipline is unaffected (zero new strings).

**MC7 (static memory map)** — Story 4.2 adds ONE byte to `inc/state.inc`: `welcome_active` (Task 1.1). Per MC7 convention, the cell is named via EQU at the appropriate offset (after `input_held_flag` at line 90 — within the single-byte run, before the 16-bit run starts at `cursor_offset` at line 93). No new equates in `inc/equates.inc` (welcome_active is state, not a constant).

**RI1 (dirty-tracking)** — `render_paint_welcome` does NOT touch `dirty_rows` (it emits directly and updates shadow). The dismissal hook calls `render_mark_all_dirty` to force a full editable-area refresh — that's the existing RI1 mechanism, used correctly here.

**RI2 (render scheduling)** — `render_paint_welcome` runs ONCE at cold-start (Stage 6.5, called from init.asm). Outside the normal input-loop render cadence. This is the same exemption that applies to `render_init`'s ESC J emit (Stage 4) and `render_full` (Stage 6) — initial-draw is the RI2 exemption.

**RI3 (Ctrl-L)** — Ctrl-L still routes to `render_full` per Story 1.11 / FR48. Post-Story-4.2, Ctrl-L from the welcome screen dismisses welcome via the input_loop hook AND triggers a full refresh — both happen on the same keystroke (the hook fires before dispatch; dispatch then calls render_full). The double `render_mark_all_dirty` is idempotent. Benign.

**RI4 (cursor reposition)** — `render_paint_welcome` ends with an `ESC Y 0,0` emit to position the cursor at top-left of editing area (matches `cursor_offset = 0` on the empty buffer). The first post-dismissal `render_diff` runs RI4 normally — cursor lands at the buffer's logical (row, col) per `render_scroll_adjust`.

**SR1-SR3 (cursor / gap mapping)** — Story 4.2 introduces no new cursor or gap-buffer semantics. The welcome screen displays over an empty buffer; cursor_offset stays 0; gap_start = GAP_BUFFER_BASE; gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX. All cold-start defaults from gapbuf_init (Stage 3) are unchanged.

**SR6 (yank register)** — untouched.

**NFR1 (incremental render)** — Story 4.2 introduces TWO full-screen events (welcome paint + welcome clear), both at cold-start / first-keystroke boundaries. After dismissal, NFR1 normal-editing diff-only emission resumes. Per AC5, these events fall under FR47's initial-draw + Ctrl-L exemption.

**NFR3 (cursor latency)** — `render_paint_welcome` runs ONCE at cold-start; its ~50-byte loop emits ~360 BIOS_CONOUT bytes. At 4 MHz with BIOS_CONOUT taking ~200 T-states per byte (estimate; BIOS-dependent), the paint takes ~360 × 200 = 72,000 T-states ≈ 18 ms. Visible to the user as a one-shot startup paint delay. NFR3 is per-keystroke; cold-start paint is exempt.

**NFR5 (no crashes)** — `render_paint_welcome` has defensive guards: row clamp (if banner walks past row 22 it stops — won't overflow into status row); col clamp inside the inner loop (if a banner row exceeds 80 cols the byte is dropped rather than overflowing). The dismissal hook's PUSH/POP AF is stack-safe (the input_loop is the top frame; one push/pop adds 2 bytes of stack pressure for ~10 T-states).

**NFR9 (code size)** — projected +452 B mid-estimate (per AC6 table). Adjusted with drift pad: +502..552 B → 8684..8734 B / ~85% / ~1500 B headroom. Comfortably within ceiling.

**NFR18 (byte-identical rebuild)** — `INCBIN "../banner.txt"` is deterministic (sjasmplus 1.23.0 embeds bytes verbatim; no host-path / timestamp leakage per BA2). Two clean builds produce identical vibe.com if banner.txt is identical.

### Files this story modifies (and what to preserve)

**`inc/state.inc`** (currently ~209 lines):
- ADD `welcome_active` 1-byte cell after `input_held_flag` at line 90. Per Task 1.1.
- EXTEND the module-header `Public:` block (line 10-23) to list `welcome_active` in the "Small state" group.
- PRESERVE: All other field EQUs UNCHANGED; static_off offsets shift +1 for every field declared AFTER welcome_active (i.e. `cursor_offset` onward shift by 1 byte). The shift is invisible to consumers — every cross-module reference is by symbol name, not address. NFR16 / MC7 holds.

**`src/render.asm`** (currently ~1320 lines):
- ADD `welcome_banner_data` + `welcome_banner_data_end` labels with an `INCBIN "../banner.txt"` block. Per Task 2.2.
- ADD `render_paint_welcome` public routine. Per Task 2.3.
- EXTEND module-header `Public:` block to include `render_paint_welcome`. Per Task 2.4.
- EXTEND `State owned` / `Register conventions` blocks. Per Tasks 2.5-2.6.
- PRESERVE: `render_init` body UNCHANGED; `render_diff` body UNCHANGED; `render_full` body UNCHANGED; `render_mark_row_dirty` / `render_mark_all_dirty` UNCHANGED; `render_emit_byte` / `render_emit_goto` UNCHANGED; `render_byte_at_logical` UNCHANGED; `render_refresh_caches` / `render_scroll_adjust` / `render_count_rows_to_cursor` / etc. UNCHANGED; module-local scratch DEFB/DEFW block UNCHANGED; `shadow_buffer` writer ownership EXTENDED to include `render_paint_welcome` (in addition to existing `render_init` + `render_diff` writers).

**`src/fileio.asm`** (currently ~1614 lines post-Story-2.4):
- MODIFY `fileio_load_initial.no_arg` at lines 945-951: INSERT `LD A, 1 ; LD (welcome_active), A` before the existing `LD HL, msg_mode_normal`. Per Task 3.1.
- EXTEND `fileio_load_initial`'s AR23 docstring header at lines 884-895 to note the welcome_active=1 side-effect on .no_arg. Per Task 3.2.
- PRESERVE: All other body sections UNCHANGED. The four-path branch (no-arg / load-success / new-file / too-large/read-error) structure UNCHANGED; the AR15 launch carve-out at lines 916-925 UNCHANGED; `fileio_setup_from_default_fcb`, `fileio_load_after_open`, `fileio_compose_new_file_status`, `fileio_compose_filename_buffer`, all the abort handlers UNCHANGED.

**`src/init.asm`** (currently 413 lines):
- MODIFY `init_cold_start` body at lines 335-339: INSERT Stage 6.5 (`LD A, (welcome_active) ; OR A ; CALL NZ, render_paint_welcome`) between Stage 6 (line 336) and Stage 7 (line 339). Per Task 4.1.
- EXTEND module-header Stage description block at lines 175-268 with a new Stage 6.5 entry. Per Task 4.2.
- EXTEND `Dependencies:` block (lines 142-153) to add `src/render.asm` (`render_paint_welcome`). Per Task 4.3.
- PRESERVE: Stages 0-6 body UNCHANGED; Stage 7 (`JP input_loop`) UNCHANGED; `init_teardown` body UNCHANGED; the DI/EI bracketing at lines 276/308 UNCHANGED.

**`src/vibe.asm`** (currently 281 lines):
- MODIFY `input_loop` body at lines 224-270: INSERT the welcome-dismissal hook between line 227 (`CALL input_get_key`) and line 234 (`LD C, A`). Per Task 5.1.
- EXTEND module-header `input_loop` description at lines 12-36 to note the dismissal hook. Per Task 5.3.
- PRESERVE: The ORG 0x0100 + `JP init_cold_start` at line 60-62 UNCHANGED; every INCLUDE line at lines 78, 84, 91, 100, 109, 118, 126, 136, 150, 164, 174, 184, 194, 209 UNCHANGED; `input_loop`'s per-mode demultiplex + dispatch_key call + render_diff call + `JP input_loop` UNCHANGED (only the dismissal hook is inserted between input_get_key and the demultiplex); the `state.inc` INCLUDE at line 281 UNCHANGED.

**Test files (`test/cases/*.asm`):**
- ADD 4 new test files per Task 6 (T1-T4: init_welcome-shown-no-arg, init_welcome-hidden-with-arg, welcome_dismissed-on-first-key, welcome_does-not-redraw-after-dismiss).
- MODIFY 2 existing regression tests per Tasks 7-8 (`init_default-fcb-no-arg.asm` + `init_cold_start-state-shape.asm` — extend with welcome_active assertions).
- PRESERVE: All other test bodies UNCHANGED.

**NO CHANGES to:**
- `src/gapbuf.asm` — no gap-buffer state touched
- `src/visual.asm` — no visual-mode state touched
- `src/edits.asm` — no edit-handler bodies touched (dispatch_normal entries for `i`, `a`, `o`, `O`, `x`, etc. all pass through the dismissal hook unchanged)
- `src/motions.asm` — no motion-handler bodies touched
- `src/dispatch.asm` — no dispatch-table changes (the hook is at input_loop top, BEFORE dispatch_key)
- `src/parser.asm` — no parser state touched
- `src/exline.asm` — no ex-line handler changes
- `src/input.asm` — `input_get_key` UNCHANGED (the hook reads its return value, doesn't modify the routine)
- `src/statusln.asm` — no status-line changes (msg_mode_normal preserved; no new strings)
- `src/search.asm`, `src/undo.asm` — no changes
- `inc/equates.inc` — no new constants (welcome_active is state, not a constant)
- `inc/modes.inc`, `inc/bdos.inc`, `inc/bios.inc`, `inc/vt52.inc` — no changes
- `Makefile` / `test/Makefile` — banner.txt is INCBIN'd from src/render.asm (relative path `../banner.txt` — sjasmplus 1.23.0 handles the include path natively; no Makefile dependency declarations needed)

### Implementation choices and trade-offs

**Choice 1 (AC1 — banner storage): INCBIN raw banner.txt (Option A) vs RLE-encoded asset (Option B).**
- Option A (INCBIN raw): 359 B exactly; simple paint loop walks the bytes byte-by-byte; banner.txt remains the human-readable source of truth in the repo.
- Option B (RLE): ~200 B asset + ~30 B decode logic = ~230 B; saves ~130 B; banner.txt becomes a build-time-generated artifact OR a parallel hand-maintained asset; risks drift between human-readable banner.txt and the in-binary asset.
- Recommended: **A** — within budget, simplest, preserves the "edit banner.txt to change the banner" workflow.
- Shrink-down lever: if AC6's actual size exceeds the 1000-B-headroom budget, fall back to **B** (Lever 1 from AC6 table).

**Choice 2 (AC1 — banner positioning): vertically centered at row 5 (Option A) vs top-anchored at row 0 (Option B).**
- Option A (centered): banner.txt's 13 lines fit at rows 5..17 of the 23 editable rows; 5 blank rows above and below. Visually balanced, matches vim's `:intro`.
- Option B (top-anchored): banner at rows 0..12; 10 blank rows below. Simpler paint loop (no row-5 offset).
- Recommended: **A** — better visual polish; the +5 B cost (the leading `LD A, 5 ; LD C, 0 ; CALL render_emit_goto` to position) is negligible.

**Choice 3 (AC1 — paint routine location): in `src/render.asm` (Option A) vs new `src/welcome.asm` module (Option B).**
- Option A (in render.asm): adds ~50-80 B body + INCBIN block; no AR25 chain disturbance; render.asm already owns AR13 (BIOS_CONOUT) — natural home.
- Option B (new welcome.asm): cleaner separation of concerns; adds one new INCLUDE in vibe.asm + a new `Module: welcome.asm` AR23 header (~20 B of comment overhead); requires AR25 placement decision (likely after render.asm to access render_emit_byte / render_emit_goto).
- Recommended: **A** — render.asm is the natural home; the welcome screen is a one-shot screen-emit feature, not a separately-extensible concern; A keeps the source tree shape unchanged.

**Choice 4 (AC3 — dismissal hook site): at top of input_loop between input_get_key and LD C,A (Option A) vs inside dispatch_key (Option B).**
- Option A (input_loop top): clean separation; the hook is a top-of-frame preprocessor; doesn't entangle with dispatch_key's MC4 contract.
- Option B (inside dispatch_key): would need a new dispatch_key entry-protocol hook; touches dispatch.asm; risks regression to all four mode tables' dispatch contracts.
- Recommended: **A** — input_loop is the natural top-of-frame; vibe.asm's input_loop body is short and well-isolated; the hook is additive (12-15 B insertion).

**Choice 5 (AC1 — welcome_active write site): inside fileio_load_initial.no_arg (Option A) vs inside init_cold_start after fileio returns (Option B).**
- Option A (in fileio.no_arg): co-located with the no-arg detection; 5 B insertion in fileio.asm.
- Option B (in init.asm): decouples welcome flag from fileio concerns; ~10 B (check filename_buffer[0]==0 + set welcome_active). Requires reading filename_buffer post-fileio_load_initial.
- Recommended: **A** — single detection site; the welcome_active = 1 set is a direct consequence of the no-arg path firing, not a separate decision.

**Choice 6 (AC3 — register preservation in input_loop hook): PUSH/POP AF (Option A) vs reorder hook after LD C,A (Option B).**
- Option A: PUSH AF / POP AF brackets the welcome_active stores + the render_mark_all_dirty call. +2 B; preserves the existing `LD C, A` position; loop body reads cleanly top-to-bottom.
- Option B: move the hook AFTER `LD C, A` so the key byte is already saved in C and AF can be clobbered. Saves 2 B but moves the hook off the natural "top-of-loop" position.
- Recommended: **A** — the +2 B is negligible; A keeps the hook visually at "top of frame" which matches its conceptual role. Dev pass can switch to B if the +2 B fights NFR9 at the cliff edge.

**Choice 7 (Tests — sentinel band): claim 0x9B..0x9E (Option A — recommended; 4 bytes from Story 4.1's "defensive slack" 0x9B..0x9F band) vs consume defensive slack 0xFE..0xFF + 0x9B..0x9C (Option B — more aggressive).**
- Option A: 4 sentinels for 4 tests; leaves 0x9F as continuing defensive slack.
- Option B: same 4 sentinels but spread across two bands; loses both 0x9F and 0xFE..0xFF.
- Recommended: **A** — keeps the defensive slack reserved for future review-patches; matches Story 4.1's allocation discipline.

### Previous story intelligence

**From Story 4.1 (most recent — visual-mode hardening pass):**
- Story 4.1 closed Epic-3 retro carry-forwards; landed +3 B over the 8179 B post-3.8 baseline → 8182 B at Story 4.1 close. Story 4.2's NFR9 baseline is 8182 B / 79.9% / 2058 B headroom.
- Story 4.1's dev pass surfaced the AC1 spec drift via [[feedback_create_story_cross_check]]: epics.md "+5 B" was actually +17 B because `gap_end`-only comparison false-positives at cursor-at-EOF. Story 4.2 applies the same cross-check discipline at Task 0.
- Story 4.1's sentinel allocation: 0x89..0x8F + 0x98..0x9A (10 bytes). Story 4.2 claims 0x9B..0x9E (4 bytes from the "defensive slack" band).
- Story 4.1 inaugurated Epic 4 and promoted epic-4 status from backlog → in-progress. Story 4.2 continues that in-progress run.
- Story 4.1's hardware-UAT 20-step script set the inline-script convention per [[feedback_uat_inline_at_dev_handoff]]. Story 4.2 follows with a 14-step script (smaller scope).
- Story 4.1 applied the single-commit Epic-3 precedent. Story 4.2 follows the same single-commit pattern.

**From Story 2.3 (launch-with-filename — the FR2 sibling of FR1+FR53):**
- Story 2.3 established `fileio_load_initial` as the launch-time FCB-parse + load orchestration entry. Story 4.2 hooks INTO its `.no_arg` branch (lines 945-951 of src/fileio.asm) — the cleanest seam.
- Story 2.3 documented the AR15 launch carve-out (inline BDOS_OPEN bypasses bdos_error_funnel because the funnel's terminal `JP input_loop` would skip cold-start Stages 6/7). Story 4.2 introduces NO new BDOS surfaces; the AR15 carve-out is unaffected.
- Story 2.3's `init_cold_start` Stage 5 rewrite from "msg_mode_normal seed" to "CALL fileio_load_initial" is the pattern Story 4.2 extends: Stage 5 now sets welcome_active=1 transitively (via fileio's no_arg branch); Stage 6.5 reads it.
- Story 2.3's 5 headless tests (`init_default-fcb-*.asm`) cover the four-path matrix; Story 4.2 EXTENDS `init_default-fcb-no-arg.asm` with the welcome_active assertion + adds 4 new tests covering the welcome-specific paths.
- Story 2.3 introduced `[new file]` as a status-row suffix; AR16-compliant lowercase. Story 4.2 introduces NO new status text (preserves msg_mode_normal empty banner per AR16's "no banner in normal mode" convention).

**From Story 1.11 (render pipeline — Ctrl-L, scroll, dirty rows):**
- Story 1.11 established `render_init` as the sole producer of the initial-clear ESC J emit (retiring the architecture-original AR13 init-side exception). Story 4.2's `render_paint_welcome` is a NEW emit site INSIDE render.asm — AR13 holds because the call site stays within render's module boundary.
- Story 1.11's `render_mark_all_dirty` sets all 24 row bits (bytes 0+1=0xFF, byte 2=0x7F or 0xFF). The Story 4.2 dismissal hook calls this routine directly. Per render.asm:311-315 — already public, unchanged signature.
- Story 1.11's `render_full` is `render_mark_all_dirty + render_diff` (tail-JP). Story 4.2's Stage 6.5 paint happens AFTER Stage 6's render_full, so the screen+shadow are in sync at the empty-buffer state when render_paint_welcome begins.
- Story 1.11's `render_emit_goto` clamps row/col before VT52_COORD_BIAS; render_paint_welcome calls it for the row-5 entry + row-advances on LF + the trailing ESC Y 0,0. Clamping is idempotent here (all coordinates are in-range).
- Story 1.11's FR47 contract — "diff render during normal editing" — exempts initial draw and Ctrl-L. Story 4.2's welcome paint at Stage 6.5 falls under "initial draw"; the dismissal-triggered `render_mark_all_dirty + render_diff` falls under the diff path normally (not an exemption — the diff machinery handles the row-walk + emit naturally).

**From Story 1.12 (init/teardown on hardware smoke):**
- Story 1.12 established the eight-stage `init_cold_start` sequence (Stages 0..7). Story 4.2 adds a Stage 6.5 between Stages 6 and 7 — the FIRST sub-stage insertion in the cold-start sequence's history.
- Story 1.12's hardware UAT pinned the VT52 ESC J semantic (Story-1.12 patch: ESC J alone is "erase from cursor to EOS"; whole-screen clear needs ESC H + ESC J). render_init handles this; render_paint_welcome doesn't emit ESC J (the screen is already cleared by Stage 4).
- Story 1.12's DI/EI bracketing around Stages 0..2 (ISR install) is preserved by Story 4.2 — the new Stage 6.5 runs with interrupts ON (per Stage 2's EI), inside the normal post-init context.

**From Story 1.5 (status-line module — msg_mode_normal as empty banner):**
- Story 1.5 established msg_mode_normal as `DEFB 0` (empty string padded by status_set_message to STATUS_LINE_WIDTH spaces). Story 4.2 preserves this — the AC1 "or equivalent" interpretation for `[No Name]` is realized by the existing empty banner.

### Git intelligence

**Recent commits (last 8; for context — Story 4.2 follows Story 4.1's close):**
- `a9bab12 Story 4.1: empty-buffer ~ regression test + AR23 exception note` — Story 4.1 review-patch: regression-pin test for AC1 empty-buffer guard + AR23 exception note on `_visual_op_block_cursor_clamp`.
- `915eca5 Story 4.1 review: 3 patch fixes + AC1 regression-pin` — Story 4.1 post-hoc code-review patches.
- `1b1c49d Story 4.1: hardware UAT confirmed; status -> done` — Story 4.1 UAT close.
- `a2658c4 Story 4.1: visual-mode hardening pass; AC1-AC3 close caller-bound gaps` — Story 4.1 dev pass commit (4 fixes + 10 tests, +3 B net).
- `35c5651 Story 3.8: visual case toggle ~` — Story 3.8 close (8179 B baseline).
- `aca5097 Story 3.7: visual shift > and <` — Epic 3 mid-stream.
- `da662d0 Story 3.6: visual operators d/y/c land; FR36 closes` — Epic 3 mid-stream.

**Pattern:** every Epic-3/4 story has been single-commit, 4-10 new headless tests, NFR18 byte-identical rebuild required. Story 4.2 follows the same shape: 4 new tests + 2 regression-test extensions, single commit, NFR18 verified.

**Insight from Story 4.1 spec-drift pattern:** AC1's epics.md "~5 B" became actual +17 B because the spec's gap_end-only comparison was wrong. Story 4.2's AC6 "+300-400 B" epics.md projection is corrected to "+418-718 B" in this spec (mid-estimate +452 B + drift pad). Dev pass MUST re-verify each AC's size projection against actual implementation at Task 9 (NFR9 check).

### Implementation Questions (resolve with Ant before dev starts)

See **Task 0** for the Q1-Q7 pin list. Recommended pins are all **Option A** matching the Story 3.x / 4.1 precedent. Surface to Ant via `AskUserQuestion` at Task 0.5:

- **Q1: Banner storage — `INCBIN "../banner.txt"` raw 359 B (Option A — recommended) or RLE-encoded ~230 B (Option B — saves ~130 B but adds decode logic + drift risk)?** Option A is simplest + within budget. Recommend A.

- **Q2: Banner positioning — vertically centered at internal row 5 (Option A — recommended) or top-anchored at row 0 (Option B)?** Option A matches vim's `:intro` polish; +5 B for the row-5 entry. Recommend A.

- **Q3: Paint routine location — inside `src/render.asm` (Option A — recommended) or new `src/welcome.asm` module (Option B)?** Option A: smaller surface, no AR25 chain disturbance. Recommend A.

- **Q4: Dismissal hook site — at input_loop top with PUSH/POP AF (Option A — recommended; +2 B but cleanest layout) or AFTER `LD C, A` to save 2 B (Option B)?** Recommend A — the +2 B is negligible and A keeps the hook visually at top-of-frame. Switch to B only if NFR9 actually flips red at Task 9.

- **Q5: welcome_active write site — inside `fileio_load_initial.no_arg` (Option A — recommended) or inside `init_cold_start` reading filename_buffer (Option B)?** Option A: co-located with detection; 5 B insertion. Recommend A.

- **Q6: Commit strategy — single commit covering banner + paint + state + hook + tests (Option A — recommended; matches Story 4.1's single-commit pattern) or split per Task (Option B)?** Recommend A.

- **Q7: Sentinel band — claim 0x9B..0x9E from Story 4.1's "defensive slack" 0x9B..0x9F (Option A — recommended) or consume 0xFE..0xFF defensive slack (Option B)?** Recommend A: keeps the 0xFE..0xFF defensive slack reserved for future review-patches.

### NFR9 budget arithmetic (worked example)

Pre-4.2 footprint: **8182 B / 79.9% of 10240 B / 2058 B headroom** (post-Story-4.1 close; current `vibe.com` on disk; SHA `d791eea13ff782aa4818aad7f87a3667992c89402a103a50211b4091ca109543` per Story 4.1 Dev Agent Record).

Story 4.2 projected deltas (positive = grows footprint):

- **AC1 banner asset** — `INCBIN "../banner.txt"`: **+359 B** (fixed; banner.txt is 359 B).
- **AC1 paint routine** — `render_paint_welcome` body: **+65 B** (mid-estimate; range 50-80 B).
- **AC1 state byte** — `welcome_active` cell: +1 B in static block (does NOT contribute to code section; NFR9 measures code section).
- **AC1 fileio.no_arg set** — `LD A,1 ; LD (welcome_active),A`: **+5 B**.
- **AC1 Stage 6.5 conditional call** — `LD A,(welcome_active) ; OR A ; CALL NZ,render_paint_welcome`: **+9 B**.
- **AC3 input_loop dismissal hook** — `PUSH AF ; LD A,(welcome_active) ; OR A ; JR Z ; XOR A ; LD (welcome_active),A ; CALL render_mark_all_dirty ; POP AF`: **+14 B**.
- **AR23 docstring extensions** (render / fileio / init / vibe headers): **+0 B** (comment-only).

Subtotal code growth: **+359 + 65 + 5 + 9 + 14 + 0 = +452 B** (clean-factor mid-estimate)

**Per [[project_nfr9_cliff_edge]] memory: pad mid-estimates by +50-100 B for spec drift.** Adjusted projection: **+452 + 50..100 = +502..552 B**

**Projected post-4.2 footprint: 8182 + 502..552 = 8684..8734 B / ~84.8..85.3% of 10240 B / 1506..1556 B headroom.** Comfortably within ceiling — no NFR9 amend needed.

**Drift triggers (revisit at Task 9.3):**
- **Green:** actual ≤ 8800 B (= +618 B over baseline) → ship as-is, generous Epic-4 runway preserved.
- **Yellow:** 8800..9100 B (= +618..+918 B over baseline) → ship as-is but flag for the optional epic-4 retrospective.
- **Red:** > 9100 B (= +918 B over baseline; +366 B over upper projection) → apply Lever 1 (RLE banner encoding) before commit. Estimated savings: ~130 B → would land at 8970-9100 B → green.

State growth: **+1 B in static block** (welcome_active cell). Does NOT count toward NFR9 (NFR9 measures code section; static block is in TPA past code). Verify post-Story-4.2 `static_end < yank_end` ASSERT still holds (it does — +1 B is negligible).

### Test count target

267 (post-Story 4.1 with its 10 new tests + 1 review-patch) → **271 PASS** (+4 new from Story 4.2: T1-T4 per Task 6) / 1 deliberate-fail (`harness_fail` sentinel) unchanged.

The 2 regression-test extensions (`init_default-fcb-no-arg.asm` + `init_cold_start-state-shape.asm` per Tasks 7-8) MUST continue to pass after their new subtest additions; if they fail, the regression net catches a contract-break.

### Project Structure Notes

- `src/render.asm` grows from ~1320 lines to ~1380 lines (+~65 B in code for `render_paint_welcome` + 359 B banner asset via INCBIN — the INCBIN bytes are NOT line-counted in the .asm source but ARE counted in the listing).
- `src/fileio.asm` grows from ~1614 lines to ~1620 lines (+5 B in code for the welcome_active set; ~3 lines of new comment).
- `src/init.asm` grows from 413 lines to ~425 lines (+9 B in code for Stage 6.5; ~8 lines of new comment + Stage 6.5 docstring entry).
- `src/vibe.asm` grows from 281 lines to ~295 lines (+14 B in code for the dismissal hook; ~10 lines of new comment).
- `inc/state.inc` grows from 209 lines to ~212 lines (+1 B in static block; +2 lines of EQU + doc comment).
- Sentinel band allocation for Story 4.2 (per Q7 pin):
  - **0x9B..0x9E — Story 4.2 (T1-T4)**
- Cumulative sentinel allocation through Story 4.2 (Epic-3 + 4.1 + 4.2 only):
  - 0x80..0x88 — Epic 1/2 (motions / edits tests; no "Sentinel" comment header convention)
  - 0x89..0x8F — Story 4.1 (T1-T7)
  - 0x90..0x97 — Epic 1/2 (motions / edits tests)
  - 0x98..0x9A — Story 4.1 (T8-T10)
  - **0x9B..0x9E — Story 4.2 (T1-T4)**
  - **0x9F — reserved as defensive slack** (NOT consumed by Story 4.2 per Q7 Option A)
  - 0xA0..0xAA + 0xE9 — Story 3.1
  - 0xAB..0xAF + 0xEA — Story 3.2
  - 0xB0..0xB4 + 0xEB — Story 3.3
  - 0xB5..0xB9 + 0xEC — Story 3.4
  - 0xBA..0xBD + 0xED — Story 3.5
  - 0xBE — reserved by `harness_fail` infra
  - 0xBF — Story 3.5 Review patch
  - 0xC0..0xCF — Story 2.13 (undo)
  - 0xD0..0xD6 + 0xEE — Story 3.6
  - 0xD7..0xDC + 0xEF — Story 3.7 (+0xDD..0xDE Review patches)
  - 0xDF + 0xF4 + 0xF8..0xFD — Story 3.8
  - 0xE0..0xE8 + 0xF0..0xF3 — Epic 1/2 parser_* + tests (note: 0xE0..0xE7 are the `init_default-fcb-*.asm` sentinels per Story 2.3)
  - 0xF5..0xF7 — Epic 1/2 dispatch_* tests
  - **0xFE..0xFF — reserved as defensive slack** (continues unconsumed)
- Per [[feedback_create_story_cross_check]]: cross-checked the AC narrative against actual render/edit semantics:
  - **AC1 banner data size**: confirmed banner.txt is exactly 359 B (13 LF-terminated lines, content widths 0..40 chars). INCBIN cost is fixed at 359 B.
  - **AC1 banner vertical centering**: `(EDITABLE_ROWS - 13) / 2 = (23 - 13) / 2 = 5`. Banner spans internal rows 5..17; rows 0..4 and 18..22 are blank (0x20 spaces — render_init seeded them; render_paint_welcome doesn't touch them).
  - **AC1 `[No Name]` interpretation**: VIBE has NO `[No Name]` string in current source; the "or equivalent" wording in the epics.md AC narrative is satisfied by the existing msg_mode_normal empty banner per Story 2.3's no-arg branch. Story 4.2 introduces NO new status messages.
  - **AC3 hook site**: confirmed `vibe.asm:227` (`CALL input_get_key`) is the right insertion point — the routine returns A=key; mode-byte read at line 234 hasn't fired yet; LD C,A at line 234 is the existing save. The hook between these (or after LD C,A if Q4 Option B chosen) keeps the existing dispatch contract intact.
  - **AC4 one-shot guarantee**: structurally enforced — fileio_load_initial.no_arg is the ONLY writer to 1 in the editor's lifetime; init_cold_start runs the LDIR zero-fill EXACTLY ONCE (Stage 1). Grep `LD A, 1 ; LD (welcome_active), A` post-Story-4.2 returns exactly ONE match in src/fileio.asm.
  - **AC5 FR47 exemption**: confirmed via architecture line 515 ("Whole-screen redraw: only on initial draw, on `Ctrl-L`") and FR47 prose. The welcome paint at Stage 6.5 IS initial draw; the dismissal-triggered diff is normal FR47-compliant diff emit (even if every editable row is dirty — that's normal render_full / render_mark_all_dirty semantics).
  - **NFR9 projection**: explicit at AC6 + budget arithmetic block. Story 4.2 is COMFORTABLY within the 10240 B ceiling (~85% projected); no NFR9 amendment risk; the 1000-B-headroom AC requirement is met with ~500 B of margin.
  - **Past-EOF rendering = spaces, NOT `~`** per [[project_no_tilde_marker]]: confirmed. The 5 blank rows above (0..4) and 5 below (18..22) the banner are PAST-EOF reads from the empty buffer (file_length=0); `render_byte_at_logical.past_eof` returns A=0x20 (space). No `~` predicted anywhere in the UAT script.
  - **CR/CRLF and sjasmplus-hostile filenames**: not relevant to Story 4.2 (welcome screen doesn't touch file I/O beyond reading DEFAULT_FCB+1 for the existing no-arg sentinel).
  - **DE-trash invariant** ([[Story 4.1 AC4]]): not relevant — render_paint_welcome doesn't call motion_byte_at_logical or any walker. No PUSH/POP DE bracketing needed.
  - **enter_normal_mode status-clobber** ([[feedback_enter_normal_mode_clobbers_status]]): NOT applicable — Story 4.2 doesn't change any mode-transition paths. Welcome dismissal happens BEFORE dispatch_key, so any handler that calls enter_normal_mode is unaffected.
  - **gap-pointer constant-compare trap** ([[feedback_naive_gap_constant_compare]]): NOT applicable — Story 4.2 doesn't compare gap pointers to constants.
  - **DISPATCH_*_COUNT**: unchanged across all four mode tables. Story 4.2 introduces no new dispatch entries. Cross-check at dev pass: verify `build/vibe.lst` shows DISPATCH_NORMAL_COUNT / DISPATCH_INSERT_COUNT / DISPATCH_COMMAND_COUNT / DISPATCH_VISUAL_COUNT all unchanged from Story 4.1 close.

### References

- **Epic 4 narrative:** `_bmad-output/planning-artifacts/epics.md:1766-1768` (Epic 4 header + module-touched list).
- **Story 4.2 epic AC source:** `_bmad-output/planning-artifacts/epics.md:1820-1866` (the 8-AC narrative).
- **FR53 PRD entry:** `_bmad-output/planning-artifacts/prd.md:693-699` (FR53 added 2026-05-19 at Epic-4 entry boundary).
- **FR1 / FR2 PRD entries:** `_bmad-output/planning-artifacts/prd.md:688-692` (the launch lifecycle FRs Story 4.2 extends).
- **FR47 incremental render PRD entry:** `_bmad-output/planning-artifacts/prd.md:791-793` (the contract Story 4.2's welcome paint + clear exempts under "initial draw").
- **FR49 status line PRD entry:** `_bmad-output/planning-artifacts/prd.md:795-797`.
- **PRD NFR1 (incremental render), NFR9 (10240 B ceiling, amended 2026-05-19), NFR18 (build reproducibility):** `_bmad-output/planning-artifacts/prd.md`.
- **Architecture FR1-FR3 → init.asm/vibe.asm mapping:** `_bmad-output/planning-artifacts/architecture.md:1527`.
- **Architecture FR47 / FR48 → render.asm mapping:** `_bmad-output/planning-artifacts/architecture.md:1541-1542`.
- **Architecture RI1-RI4 (render invariants):** `_bmad-output/planning-artifacts/architecture.md:559-580`.
- **Architecture RI6 (input loop top-level):** `_bmad-output/planning-artifacts/architecture.md:621-624`.
- **Architecture "Whole-screen redraw" exemption clause (FR47 context):** `_bmad-output/planning-artifacts/architecture.md:515`.
- **Architecture AR23 module-header convention (Public/State/Register/Dependencies blocks):** referenced in render.asm and every other module's header.
- **Architecture data-flow (keystroke lifecycle):** `_bmad-output/planning-artifacts/architecture.md:1480-1521` — Story 4.2's dismissal hook fits between step 3 (input_get_key) and step 4 (dispatch_key).
- **Existing `fileio_load_initial.no_arg` body (AC1 patch target):** `src/fileio.asm:945-951` — the `LD HL, msg_mode_normal ; XOR A ; JP status_set_message` sequence; Story 4.2 prepends the `LD A,1 ; LD (welcome_active),A` pair.
- **Existing `init_cold_start` Stage 5+6 (AC1 patch target #2):** `src/init.asm:316-339` — Story 4.2 inserts a new Stage 6.5 between lines 336 and 339.
- **Existing `input_loop` body (AC3 patch target):** `src/vibe.asm:224-270` — Story 4.2 inserts the welcome-dismissal hook between `CALL input_get_key` (line 227) and `LD C, A` (line 234).
- **Existing `render_mark_all_dirty`:** `src/render.asm:311-315` — public AR23-documented signature (no inputs; sets bytes dirty_rows[0..2]; trashes A, F; no calls). Unchanged by Story 4.2.
- **Existing `render_emit_byte`:** `src/render.asm:1228-1231` — module-private but called from `render_paint_welcome` (intra-module CALL).
- **Existing `render_emit_goto`:** `src/render.asm:1258-1282` — module-private; called from `render_paint_welcome` for row-position emits + the trailing ESC Y 0,0.
- **Existing `render_init` / `render_full` / `render_diff` (CONTRACTS — must be preserved):** `src/render.asm:202-345`.
- **Existing `shadow_buffer` (write target for `render_paint_welcome`):** `inc/state.inc:185-186` — `EQU static_data_base + static_off` at the buffers section.
- **Existing `init_cold_start-state-shape.asm` regression test:** `test/cases/init_cold_start-state-shape.asm` (Story 1.12 baseline; Story 4.2 extends per Task 8).
- **Existing `init_default-fcb-no-arg.asm` regression test:** `test/cases/init_default-fcb-no-arg.asm` (Story 2.3 baseline; Story 4.2 extends per Task 7).
- **banner.txt source asset:** `/home/ant/src/microbeast/vibe/banner.txt` (359 B, 13 LF-terminated lines; already in git index).
- **Story 4.1 (immediate predecessor; Epic 4's first story):** `_bmad-output/implementation-artifacts/4-1-visual-mode-hardening-pass.md` — contract reference for Epic 4 conventions (sentinel allocation, single-commit pattern, NFR18 verification, hardware UAT script discipline).
- **Story 2.3 (FR2 sibling; established the launch path):** `_bmad-output/implementation-artifacts/2-3-launch-with-filename-argument.md` — primary structural reference for the AR15 launch carve-out + fileio_load_initial four-path architecture.
- **Story 1.11 (render pipeline owner):** `_bmad-output/implementation-artifacts/1-11-render-pipeline-with-dirty-rows-scroll-ctrl-l.md` — render contract reference; FR47 "initial draw + Ctrl-L" exemption.
- **deferred-work.md** (current backlog):
  - "FR53 welcome screen on no-argument launch" — CLOSED by Story 4.2.
- **Memory entries consulted:**
  - [[project_nfr9_cliff_edge]] — NFR9 baseline 8182 B / 10240 B ceiling; mid-estimate drift pad +50-100 B; projected post-4.2 ~85% / 1500 B headroom.
  - [[feedback_create_story_cross_check]] — applied at Task 0 + this Project Structure Notes cross-check section; corrected epics.md AC6 "+300-400 B" projection to "+418-718 B" actual + drift pad.
  - [[feedback_uat_trace_cursor]] — applied at AC7 UAT script step 7 (`i hello Esc` cursor analysis: post-`i` cursor=0; after typing 'hello' cursor advances through gap-buffer inserts; on `Esc` cursor lands at last-typed-byte). Per the 2026-05-19 amendment: `$a` is per-LINE (only appends at EOF if cursor is already on the last line) — not relevant to Story 4.2's UAT since the buffer is single-line in the post-dismissal `hello` scenario.
  - [[feedback_uat_inline_at_dev_handoff]] — applied: UAT script pasted inline as a 14-step table near end of this story.
  - [[project_no_tilde_marker]] — applied: UAT script doesn't predict `~` markers anywhere; the blank rows above/below the banner (rows 0..4 + 18..22) render as 0x20 spaces per `render_byte_at_logical.past_eof`.
  - [[feedback_enter_normal_mode_clobbers_status]] — NOT applicable to Story 4.2 (no mode-transition paths modified).
  - [[feedback_naive_gap_constant_compare]] — NOT applicable to Story 4.2 (no gap-pointer comparisons).

## Hardware UAT script (AC7 — paste into chat at dev-handoff per [[feedback_uat_inline_at_dev_handoff]])

**Pre-requisites:** Story 4.2 built and `vibe.com` transferred to MicroBeast B: drive. Fixture file: `hello.txt` (13 B from prior stories; already deployed). Test pattern: launch + observe banner + dismiss + observe key processed normally + quit cleanly.

| # | Step | Expected behavior |
|---|------|---------------------|
| 1 | `B>vibe` (no arg) | Editor launches; **welcome screen visible**: rows 5..17 show the VIBE banner (rows 5+9+12 of the visible area = banner.txt lines 1+9+12 = blank; rows 6..8 + 10..11 + 13 show the 7-line "VIBE" glyph + "Vi-like Beast Editor" + "(c) 2026 ant.org" + "Type :q to quit!"); rows 0..4 + 18..22 of editing area are blank (spaces); status row 23 is blank (msg_mode_normal padded); cursor blinks at row 0 / col 0; gap buffer empty (`file_length = 0`, `cursor_offset = 0`); `mode_byte = MODE_NORMAL`. **NO `~` past-EOF marker** anywhere (per [[project_no_tilde_marker]]). |
| 2 | Press `:` | **AC3 fires:** welcome screen clears (banner glyphs replaced by spaces across the entire editing area); status row shows `:` prompt at col 0 (CMD_SUB_EX); cursor lands at row 23 / col 1 (RI4 + AC11 cursor-target override). `mode_byte = MODE_COMMAND`; `welcome_active = 0` (one-shot consumed). |
| 3 | Type `q` Enter | `cmd_quit` executes: buffer is clean (no edits since launch); ex-line clears; editor warm-boots via `init_teardown` → BDOS function 0 → CCP prompt returns. **Cleanly exits.** |
| 4 | `B>vibe hello.txt` (filename arg) | **AC2 fires:** Editor launches; **welcome screen NOT shown** (welcome_active stays 0 on load-success path); editing area shows hello.txt contents (13 B "Hello, world!\n"); status row 23 shows `B:HELLO.TXT 13 bytes`; cursor at row 0 / col 0; `mode_byte = MODE_NORMAL`. |
| 5 | Type `:q` Enter | Clean quit (buffer is clean from the load); CCP returns. |
| 6 | `B>vibe` (no arg, second launch) | Welcome screen visible again (LDIR zero-fill at Stage 1 re-zeroes welcome_active; Stage 5 re-sets it to 1; Stage 6.5 paints banner). Same display as step 1. Confirms welcome screen survives editor-relaunch cycles. |
| 7 | Press `i` then type `hello` then press `Esc` | **AC3 fires on `i`:** welcome clears immediately; `mode_byte = MODE_INSERT`; status row shows `-- insert --` (or whatever msg_mode_insert is per Story 1.5 / 2.8). Then `hello` literals land at offsets 0..4 of the empty gap buffer (gap_start advances 5 bytes; gap_end unchanged at GAP_BUFFER_BASE + GAP_BUFFER_MAX). On `Esc`, `mode_byte = MODE_NORMAL`; cursor at offset 4 (the 'o' — last byte typed; INSERT mode's exit-cursor is one before gap_start per AR23 contract). Editing area row 0 shows `hello`; rest of editing area is spaces; status row shows `msg_mode_normal` (or `msg_buffer_dirty` if Story 2.8 surfaces dirty flag visibly — verify against Story 2.8 contract). |
| 8 | Press `:q!` Enter | **Force-quit:** buffer is dirty (per FR8 `:q!` discards changes). Editor warm-boots; CCP returns. File system unchanged (no `:w` was issued). |
| 9 | `B>vibe` (no arg, third launch) | Welcome screen visible. Press `Ctrl-L` (literal 0x0C byte). **AC3 fires on Ctrl-L:** welcome clears (dismissal hook + render_mark_all_dirty); Ctrl-L's own `render_full` runs (dispatch_normal entry per Story 1.11; idempotent render_mark_all_dirty since dirty bits already set; render_diff emits over the banner cells with spaces from buffer = empty). End state: editing area blank, status row blank, cursor at row 0 / col 0, `mode_byte = MODE_NORMAL`. **NO double-paint flicker** (the single render_diff in main loop step 4 handles the redraw). |
| 10 | Press `:q` Enter | Clean quit (buffer unchanged since launch). |
| 11 | `B>vibe` (no arg, fourth launch) | Welcome screen visible. Press `Esc` (a typical "ignore me" key in NORMAL mode). **AC3 fires on Esc:** welcome clears; Esc is consumed by NORMAL-mode unbound-key handler (FR50 status beep / no-op — depending on Story 1.9 / 1.5 handler choice). `mode_byte = MODE_NORMAL` (unchanged). End state: editing area blank, status row reflects unbound-key feedback (or empty if FR50 chose no-op), cursor at row 0 / col 0. |
| 12 | Press `i` then `Esc` | `i` enters INSERT (status `-- insert --`); `Esc` returns to NORMAL (status `-- normal --` or msg_mode_normal). Cursor stays at offset 0 (no characters typed between `i` and `Esc`). Confirms post-welcome editor is fully functional. |
| 13 | Press `:q` Enter | Buffer is still clean (no actual edits); clean quit; CCP returns. |
| 14 | Confirm overall result | **All 13 prior steps pass on real MicroBeast.** No hangs, no crashes, no status-line silence, no buffer corruption, no flicker on welcome paint or clear, no cursor-position drift, no `~` markers ANYWHERE. Welcome appears on every no-arg launch and is dismissed by the first keystroke regardless of which key. AC7 closes. |

## Dev Agent Record

### Agent Model Used

Amelia (bmad-dev-story) running Claude Opus 4.7 (1M context).

### Debug Log References

- **Q1 / Q3 divergence from recommended Option A pins:** Ant chose Q1 Option B (RLE-encoded banner) + Q3 Option B (new `src/welcome.asm` module). Both divergences reduce NFR9 footprint and improve modularity:
  - Q1 B: hand-encoded dual-mode RLE (run-pairs for glyph rows, literal blocks for text rows) saves ~137 B vs INCBIN raw banner.txt. Final encoded data is exactly 222 B (ASSERT-pinned in `src/welcome.asm`) matching the Task 0 pre-cross-check arithmetic.
  - Q3 B: `src/welcome.asm` is a fresh module hosting the banner data + `welcome_paint` decoder + `welcome_emit_cell` helper + module-private DEFB scratch (welcome_paint_row, welcome_paint_col). Cross-module CALLs into `render_emit_byte` and `render_emit_goto` required promoting those helpers from render.asm's module-internal scope to the Public: surface — the AR23 doc comment block on render.asm was extended accordingly (no actual code change; the symbols were always link-time visible, just not documented as public).
- **AR25 chain placement for welcome.asm:** slotted between render.asm and dispatch.asm so welcome.asm's CALLs to `render_emit_byte` / `render_emit_goto` are backward-resolved by sjasmplus's first pass. init.asm's Stage 6.5 `CALL NZ, welcome_paint` is forward-referenced (init.asm INCLUDEs at vibe.asm line 78, welcome.asm at line 119) but resolves via the standard two-pass mechanism — no special handling required.
- **welcome_paint register pressure:** the decoder needs to track current row + col across multiple `render_emit_byte` calls (which trash A, BC, F per its docstring). Solution: stash row/col in two module-private DEFB cells (`welcome_paint_row`, `welcome_paint_col`), mirroring render.asm's defensive `render_goto_row` / `render_goto_col` pattern (Story 1.12 hardware-UAT-promoted patch against BIOS register clobber). welcome_emit_cell PUSHes AF around the shadow-address math so the byte-to-emit survives the BC clobber on render_emit_byte.
- **vibe.asm dismissal hook key preservation (Q4 Option A):** PUSH AF / POP AF brackets the welcome_active store + render_mark_all_dirty CALL so the keystroke byte arriving in A from `input_get_key` survives the hook's side effects. Net code cost: +15 B (vs +12 B estimated for Option B without the bracket). Verified by T3's subtest 6 ("key byte preserved across PUSH AF / POP AF").
- **NFR9 size delta (per-task running tally):**
  - Pre-Story 4.2 baseline: 8182 B
  - After Task 1 (state.inc +1 B static, +0 B code): 8182 B (unchanged — static block is past code section)
  - After Task 2 (welcome.asm + render.asm Public: docs): 8535 B (+353 B — welcome.asm content)
  - After Task 3 (fileio.no_arg +5 B): 8540 B (+5 B)
  - After Task 4 (init.asm Stage 6.5 +7 B; sjasmplus optimized 1 B off the estimated +9 B): 8547 B
  - After Task 5 (vibe.asm dismissal hook +15 B): 8562 B
  - **Cumulative Story 4.2 delta: +380 B** (vs RLE-path mid-estimate +315 B + drift pad +50-100 B = +365..415 B projected range; landed mid-range).
- **NFR9 final state:** 8562 B / 83.6% of 10240 B / **1678 B headroom — GREEN.** AC6's "at least 1000 B residual headroom" requirement satisfied with ~678 B slack.
- **Test count:** 267 pre-Story-4.2 → **271 PASS** post-Story-4.2 (+4 new T1-T4 at sentinels 0x9B..0x9E) / 1 deliberate-fail (`harness_fail` sentinel) unchanged. Both regression tests (`init_default-fcb-no-arg.asm` + `init_cold_start-state-shape.asm`) extended with welcome_active assertions and continue to PASS.
- **NFR18 byte-identical rebuild:**
  - **Initial dev-pass build** (pre-Ant centering tweak): `make clean && make all` × 2 produced identical SHA-256 `46f285c33873bf9208b0ab17b95420b623d536c39666283560172b2bea5afb51` × 2.
  - **Post-UAT centering rebuild** (shipped binary): after the 10-byte col_start edit in `welcome_banner_rle` (glyph block +20 cols, line 10 +20 cols, lines 11+13 +20 cols), `make clean && make all` × 2 produced identical SHA-256 `cfeaf4c654e09f458387e33c6557af536daa8514f8ab2af6d5c412e640a6f81a` × 2. **This is the SHA of the shipped `vibe.com`** (commit `1c9e759`).
  - banner.txt SHA `e5ca49939c2ce46596e0e93dbbab93ca8527f9bf2530af511b21308b606f1253` (held constant across both build cycles — the source-of-truth glyph layout is independent of the RLE col_start packing under Q1 Option B; banner.txt is no longer INCBIN'd but is retained as the canonical reference for the glyph block design).
  - AC8 closed with the post-centering SHA pair as the binding NFR18 record.

### Completion Notes List

- **Q1-Q7 pin resolutions:** Q4, Q2, Q5, Q6, Q7 all Option A (recommended); Q1, Q3 Option B (Ant chose RLE encoding + new module).
- **AC1 (welcome screen shows on no-arg launch):** PASS — `fileio_load_initial.no_arg` arms `welcome_active = 1` (+5 B); `init_cold_start` Stage 6.5 conditionally CALLs `welcome_paint` (+7 B); `welcome_paint` walks 222 B of RLE-encoded banner data and emits glyphs at internal rows 5..17 with shadow_buffer sync (welcome.asm contributes +353 B). Verified by T1 (`init_welcome-shown-no-arg.asm`, sentinel 0x9B) + extended regression in `init_cold_start-state-shape.asm` (subtests 13+14).
- **AC2 (welcome hidden on filename-arg launch):** PASS — `welcome_active` stays 0 on all three non-no-arg branches (load-success, new-file, too-large/read-error); Stage 6.5's `CALL NZ` short-circuits. Verified by T2 (`init_welcome-hidden-with-arg.asm`, sentinel 0x9C).
- **AC3 (first keystroke dismisses + keystroke processed normally):** PASS — `vibe.asm` `input_loop` PUSH AF / POP AF dismissal hook (+15 B) clears `welcome_active` and CALLs `render_mark_all_dirty` between `input_get_key` and per-mode dispatch; key byte preserved. Verified by T3 (`welcome_dismissed-on-first-key.asm`, sentinel 0x9D). "Processed normally" half exercised by hardware UAT.
- **AC4 (one-shot guarantee):** PASS — `welcome_active` has exactly ONE writer-to-1 in production code (grep `LD A, 1` followed by `LD (welcome_active), A` returns ONE match in src/fileio.asm). The cold-start LDIR zero-fills the cell at every .com launch; first-keystroke dismissal clears it; no subsequent operation re-arms. Verified structurally by T4 (`welcome_does-not-redraw-after-dismiss.asm`, sentinel 0x9E) which exercises 5 common post-dismissal operations.
- **AC5 (FR47 incremental-render exemption):** PASS by design — `welcome_paint` runs at Stage 6.5 (initial-draw class, exempt per architecture.md:515). Dismissal-triggered `render_mark_all_dirty + render_diff` IS the diff path itself (FR47-compliant by definition).
- **AC6 (NFR9 size budget):** PASS — `vibe.com = 8562 B / 83.6% of 10240 B / 1678 B headroom`. Story 4.2 cumulative delta **+380 B**. RLE encoding (Q1 Option B) saved ~137 B vs the INCBIN-path mid-estimate.
- **AC7 (hardware UAT):** PASS — Ant confirmed all 14 inline UAT steps on real MicroBeast (2026-05-19). Post-UAT minor: banner was hugging the left edge (original banner.txt leading-space offsets) so col_start values for all 10 non-blank rows were shifted to horizontally center the glyph block (left edge at col 21) and text rows (line 10 col_start 30, lines 11+13 col_start 32). 10-byte edit in welcome.asm RLE data; banner size unchanged at 222 B; vibe.com size unchanged at 8562 B; new NFR18 SHA `cfeaf4c654e09f458387e33c6557af536daa8514f8ab2af6d5c412e640a6f81a`. AC7 closes.
- **AC8 (NFR18 byte-identical rebuild):** PASS — verified via `make clean && make all` × 2. Both SHA-256: `46f285c33873bf9208b0ab17b95420b623d536c39666283560172b2bea5afb51`. banner.txt source SHA: `e5ca49939c2ce46596e0e93dbbab93ca8527f9bf2530af511b21308b606f1253`. No host-path or timestamp leakage introduced.
- **Cross-module Public: surface change:** render.asm's `Public:` block extended with `render_emit_byte` and `render_emit_goto` (previously module-internal). These were always link-time visible; the change is documentation-only. welcome.asm is the first cross-module caller, justifying the promotion.
- **Per-test sentinel allocation post-Story-4.2:** 0x9B (T1 + reused in init_default-fcb-no-arg subtest 6), 0x9C (T2 + reused in init_cold_start-state-shape subtest 13), 0x9D (T3 + reused in init_cold_start-state-shape subtest 14), 0x9E (T4). 0x9F retained as defensive slack (per Q7 Option A). 0xFE..0xFF continue as defensive slack.
- **No deferred-work.md update needed** — no entry for "FR53 welcome screen" pre-existed in deferred-work.md; Story 4.2 closes the FR via the epics.md acceptance criteria, not via a deferred-work backlog entry.

### File List

**Production code (modified):**
- `inc/state.inc` — added `welcome_active` 1-byte cell after `input_held_flag` (+1 B static block); extended Public: block "Small state" group
- `src/render.asm` — extended Public: block to document `render_emit_byte` + `render_emit_goto` as cross-module-callable (no code change; documentation update only)
- `src/fileio.asm` — `fileio_load_initial.no_arg` arms welcome_active = 1 (+5 B); AR23 docstring updated with the new side-effect
- `src/init.asm` — Stage 6.5 conditional `CALL NZ, welcome_paint` (+7 B); header Stage description block extended; Dependencies block adds src/welcome.asm
- `src/vibe.asm` — input_loop welcome-dismissal hook between `input_get_key` and per-mode dispatch (+15 B); AR25 chain extended with `INCLUDE "welcome.asm"`; module-header input_loop description extended

**Production code (added):**
- `src/welcome.asm` — NEW MODULE (+353 B in vibe.com). Hosts: `welcome_paint` public entry (RLE decoder + screen emit + shadow sync + final cursor home), `welcome_emit_cell` private helper, `welcome_paint_row` + `welcome_paint_col` module-private scratch DEFBs, `welcome_banner_rle` 222-byte hand-encoded banner asset (dual-mode RLE: run-pairs for glyph rows + literal blocks for text rows; ASSERT-pinned to 222 B).

**Headless tests (added — 4 new):**
- `test/cases/init_welcome-shown-no-arg.asm` — T1 sentinel 0x9B (AC1 end-to-end)
- `test/cases/init_welcome-hidden-with-arg.asm` — T2 sentinel 0x9C (AC2 filename-arg path)
- `test/cases/welcome_dismissed-on-first-key.asm` — T3 sentinel 0x9D (AC3 dismissal mechanism + key preservation)
- `test/cases/welcome_does-not-redraw-after-dismiss.asm` — T4 sentinel 0x9E (AC4 one-shot regression net)

**Headless tests (modified — 2 regression extensions):**
- `test/cases/init_default-fcb-no-arg.asm` — added subtest 6 (welcome_active == 1 post-`fileio_load_initial.no_arg`); sentinel-codes header block extended with 0x9B mapping
- `test/cases/init_cold_start-state-shape.asm` — added INCLUDE for src/welcome.asm; added subtest 13 (welcome_active == 1 post-Stage-6.5) + subtest 14 (shadow_buffer[6*80+1] == 'm' post-welcome_paint); sentinel-codes header extended with 0x9C and 0x9D mappings

**Sprint tracking (modified):**
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `4-2-welcome-screen-on-no-argument-launch` status flipped backlog → ready-for-dev (create-story) → in-progress (dev-story start) → review (Step 9 of dev-story workflow); audit-trail comment chain prepended at `last_updated`

**Story tracking (modified):**
- `_bmad-output/implementation-artifacts/4-2-welcome-screen-on-no-argument-launch.md` — this file: Status flipped ready-for-dev → review; Tasks/Subtasks checkboxes updated; Dev Agent Record populated; File List populated; Change Log entry appended

## Change Log

| Date | Note | Author |
|---|---|---|
| 2026-05-19 | Hardware UAT confirmed on real MicroBeast (Ant). All 14 UAT steps pass first iteration: welcome screen visible on no-arg launch; dismissed cleanly by `:`, `i`+text+Esc, Ctrl-L, and Esc; reappears on every subsequent no-arg launch; AC2 filename-arg path bypasses welcome as expected. **Post-UAT minor**: Ant requested horizontal centering of the banner (banner was hugging the left edge using banner.txt's original leading-space offsets). Fix: shifted each row's col_start in `welcome_banner_rle` — glyph block (lines 2-8) shifted +20 cols so left edge aligns at col 21 = (80-38)/2; literal text rows centered independently per content width (line 10 col_start 10→30, lines 11+13 col_start 12→32). 10-byte edit in welcome.asm; banner data stays exactly 222 B (ASSERT still holds); vibe.com size unchanged at 8562 B. Two test assertions updated: T1 subtest 2 + init_cold_start-state-shape subtest 14 (the 'm' that was at col 1 now lands at col 21). All 272 tests still PASS (271 real + 1 deliberate-fail). New NFR18 SHA `cfeaf4c654e09f458387e33c6557af536daa8514f8ab2af6d5c412e640a6f81a` × 2 (was `46f285c3...` pre-centering; size identical, bytes differ at the col_start positions in welcome_banner_rle). AC7 closes; ready for commit. Status → done pending final commit. | bmad-dev-story (Claude Opus 4.7 1M) + Ant |
| 2026-05-19 | Story 4.2 dev pass complete; status → review. All 7 Q-pins resolved (Q4/Q2/Q5/Q6/Q7 Option A as recommended; Q1/Q3 Option B per Ant's choice — RLE-encoded banner asset + new src/welcome.asm module). Implementation lands +380 B of code (within the RLE-path projected +365..415 B range): inc/state.inc +1 B (welcome_active cell), src/welcome.asm +353 B NEW (222 B RLE banner data + ~85 B decoder/helper + 2 B module-private scratch + AR23 header comments), src/fileio.asm +5 B (welcome_active=1 in .no_arg), src/init.asm +7 B (Stage 6.5 conditional CALL NZ), src/vibe.asm +15 B (PUSH AF / POP AF dismissal hook). Cross-module changes: render.asm Public: block extended with render_emit_byte + render_emit_goto (doc-only). NFR9 final 8562 B / 83.6% / 1678 B headroom — GREEN. NFR18 SHA `46f285c33873bf9208b0ab17b95420b623d536c39666283560172b2bea5afb51` × 2 (byte-identical). Test count 267 → 271 PASS (+4 new T1-T4 at sentinels 0x9B..0x9E). 2 regression-test extensions (init_default-fcb-no-arg.asm subtest 6; init_cold_start-state-shape.asm subtests 13+14 + welcome.asm INCLUDE addition). Welcome screen architecture: render_paint via welcome.asm at init Stage 6.5 (gated by welcome_active flag set in fileio.no_arg); dismissal via input_loop hook between input_get_key and per-mode dispatch; one-shot guarantee structural (sole writer-to-1 is fileio.no_arg; cold-start LDIR re-zeroes per .com launch). AC1-AC6 + AC8 PASS via headless verification; AC7 hardware UAT pending Ant. | bmad-dev-story (Claude Opus 4.7 1M) |
| 2026-05-19 | Story 4.2 ready-for-dev. Continues Epic 4: visual-mode hardening + welcome screen. Closes FR53. 8 ACs spanning: AC1 welcome banner painted at internal rows 5..17 on no-arg launch via new `render_paint_welcome` in render.asm + `welcome_active` state byte + Stage 6.5 in init_cold_start; AC2 welcome hidden on filename-arg launch (welcome_active stays 0); AC3 first keystroke dismisses via new hook between input_get_key and dispatch in vibe.asm input_loop + render_mark_all_dirty + keystroke flows through dispatch unchanged; AC4 one-shot guarantee (welcome_active set only at cold-start by fileio.no_arg, cleared only by first keystroke, never re-arms); AC5 FR47 exemption (paint at Stage 6.5 = initial-draw; dismissal-triggered diff = normal FR47-compliant); AC6 NFR9 mid-estimate +452 B (drift pad +50-100 B → projected post-4.2 ~8684-8734 B / ~85% / 1506-1556 B headroom — comfortably within ceiling; epics.md "+300-400 B" projection is +52-152 B low because banner.txt INCBIN is 359 B fixed); AC7 14-step hardware UAT inline (multiple launch cycles + various dismissal keys: `:`, `i`+text, `Ctrl-L`, `Esc`); AC8 NFR18 byte-identical rebuild (INCBIN deterministic per BA2). Sentinel allocation: 0x9B..0x9E (4 bytes from Story 4.1's "defensive slack" 0x9B..0x9F band). All Q1-Q7 pins recommended Option A: INCBIN raw banner.txt; vertically centered at row 5; paint routine in render.asm; hook at input_loop top with PUSH/POP AF; welcome_active set in fileio.no_arg; single commit; sentinel band 0x9B..0x9E. Reviewed against [[feedback_create_story_cross_check]] (AC6 spec drift caught + corrected; AC1 "[No Name]" interpretation pinned to existing msg_mode_normal empty banner per AR16; banner positioning math verified `(23-13)/2=5`), [[project_no_tilde_marker]] (UAT predicts NO `~` markers — past-EOF rows render as 0x20 spaces), [[feedback_uat_trace_cursor]] (post-`i` cursor stays at offset 0 in empty buffer; after typing 'hello' cursor at offset 4 on Esc), [[feedback_uat_inline_at_dev_handoff]] (UAT script pasted inline as 14-step table), [[project_nfr9_cliff_edge]] (NFR9 baseline 8182 B; mid-estimate +452 B + drift pad → projected ~85% — green). Cross-stories: Story 2.3 established `fileio_load_initial.no_arg` as the hook seam; Story 1.11 established `render_mark_all_dirty` + the FR47 initial-draw exemption; Story 1.12 established the 8-stage cold-start sequence Story 4.2 extends with a Stage 6.5 sub-stage; Story 4.1 set the single-commit Epic-4 pattern Story 4.2 follows. Per Q6: single commit; Per Q7: 0x9F stays defensive slack. | bmad-create-story (Claude Opus 4.7 1M) |
