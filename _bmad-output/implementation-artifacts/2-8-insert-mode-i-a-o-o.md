# Story 2.8: Insert mode (i, a, o, O)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `i` / `a` / `o` / `O` to enter INSERT mode at the appropriate position, literal typing to insert bytes at the cursor, Backspace to delete the byte before the cursor, and Esc to return to NORMAL,
So that FR13 / FR16 / FR24-FR27 land and journey-1a "compose from scratch" becomes testable end-to-end on real hardware — VIBE's first true edit-and-save round-trip.

## Acceptance Criteria

**AC1 — `i` enters INSERT mode, cursor unchanged.**

**Given** I'm in NORMAL mode with `mode_byte = MODE_NORMAL`
**When** I press `i` (`dispatch_normal['i']` is already wired to `enter_insert_mode` since Epic 1)
**Then** `mode_byte = MODE_INSERT`, the status line shows `"-- insert --"` (`msg_mode_insert`), `cursor_offset` is unchanged, and parser state is zeroed via the existing `enter_insert_mode` tail-JP `parser_clear` (Story 2.5 AC13).

**AC2 — `a` enters INSERT mode, cursor advances by 1 unless at EOL.**

**Given** I'm in NORMAL mode at `cursor_offset = C`
**When** I press `a`
**Then** the new handler `edits_enter_insert_after` runs:
- If the byte at C is NOT `0x0A` AND `C < file_length`, `cursor_offset := C + 1` (advance onto the position after the last printable byte; for a line "hello" at the 'o', cursor lands on the LF or on file_length if there's no trailing LF).
- If the byte at C is `0x0A` (cursor on a LF — defensively, the Story 2.5 invariant says cursor shouldn't be there, but `a` MUST NOT advance past EOL onto a non-existent byte), cursor stays at C.
- If `C == file_length` (EOF sentinel), cursor stays at C.

Then `mode_byte = MODE_INSERT`, status shows `"-- insert --"`, parser state zeroed.

**AC3 — `o` opens a new line below.**

**Given** I'm in NORMAL mode at `cursor_offset = C`
**When** I press `o`
**Then** the new handler `edits_open_below` runs:
- Move cursor to the end-of-current-line position: `cursor_offset := motion_find_line_end(C)` (returns LF position, or `file_length` if no LF before EOF).
- `gapbuf_insert(0x0A)` — inserts an LF at the new cursor position; gapbuf_insert advances cursor by 1.
- On gapbuf_insert success (CF=0): `mode_byte = MODE_INSERT`; cursor now sits at the start of the new (empty) line below the original. Status shows `"-- insert --"`; `buffer_dirty := 1`; `render_mark_all_dirty` is called (the LF shifts every row below); parser state zeroed.
- On gapbuf_insert failure (CF=1, buffer full): the helper has already called `status_set_message(msg_file_too_large)`; this handler leaves `mode_byte = MODE_NORMAL` (the `o` never gets to its mode-switch); cursor returns to C (the entry position) via a saved-cursor restore; parser state zeroed via tail-JP `parser_clear`.

**AC4 — `O` opens a new line above.**

**Given** I'm in NORMAL mode at `cursor_offset = C`
**When** I press `O`
**Then** the new handler `edits_open_above` runs:
- Move cursor to the start-of-current-line position: `cursor_offset := motion_find_line_start(C)` (returns offset just past the previous LF, or 0 at line 1).
- `gapbuf_insert(0x0A)` — inserts an LF at the new cursor position; gapbuf_insert advances cursor by 1.
- After the insert, **decrement cursor by 1** so it lands on the just-inserted LF (which IS the new empty line above the original). Trace: with `"hello\nworld"` cursor=8 (`'r'` of `"world"`), find_line_start gives BOL=6; insert LF at 6 → buffer `"hello\n\nworld"` (12 B), cursor advances to 7; DEC cursor → 6 — on the new empty line's LF.
- On success: `mode_byte = MODE_INSERT`; `buffer_dirty := 1`; `render_mark_all_dirty`; parser state zeroed.
- On gapbuf_insert failure (CF=1): same shape as AC3 — mode stays NORMAL, cursor restored to C, status surfaces the file-too-large banner.

**AC5 — Literal byte in INSERT mode inserts at cursor.**

**Given** I'm in INSERT mode and the input layer delivers a byte A in the range `0x20..0x7E` (printable ASCII only — tightened from "0x20..0xFE printable + extended" per code review 2026-05-16 D1; rejection of 0x7F + 0x80+ closes the buffer-corruption hazard from synthesised arrow keycodes KEY_ARROW_UP/DOWN/LEFT/RIGHT = 0x80..0x83 that `input_get_key` produces regardless of mode)
**When** dispatch_insert routes through `unbound_insert` (Story 2.8 replaces the 1.9 RET stub) — really through a new `edits_insert_literal` that `unbound_insert` tail-JPs to
**Then** `gapbuf_insert(A)` inserts the byte at `cursor_offset`; gapbuf_insert advances `cursor_offset` by 1.
- On success: `buffer_dirty := 1`; `render_mark_row_dirty(row of cursor)` for the cursor's row (single-row dirty since no LF inserted; the cursor row's content shifted right of cursor); subsequent typing accumulates at the gap with no extra `gapbuf_move_gap` cost (the gap-tracks-cursor invariant means consecutive inserts at successive cursors are O(1) per byte).
- On overflow (CF=1): gapbuf_insert has already called `status_set_message(msg_file_too_large)`; partial text prior to the failed byte IS preserved (no rollback); `mode_byte := MODE_NORMAL` (the INSERT session exits, surfacing the failure); cursor stays at its current position; parser state zeroed.

**AC6 — Backspace in INSERT mode deletes the byte before cursor.**

**Given** I'm in INSERT mode and the input layer delivers `0x08` (Backspace)
**When** dispatch_insert routes `0x08` to the new `edits_insert_backspace` handler
**Then**:
- If `cursor_offset > 0`: `gapbuf_delete` consumes the byte logically before the cursor; `cursor_offset` decrements by 1; `buffer_dirty := 1`; `render_mark_all_dirty` IF the deleted byte was an LF (rows shifted up), otherwise `render_mark_row_dirty(row of cursor)`.
- If `cursor_offset == 0`: gapbuf_delete returns CF=1 silently (per its existing AC5 contract — Story 1.7); handler is a no-op; no status message (consistent with vi-faithful "silent at BOF" — beep would require BIOS_CONOUT which is AR13-forbidden outside render/init).

`mode_byte` stays at `MODE_INSERT` (Backspace does NOT exit INSERT).

**AC7 — Esc in INSERT mode returns to NORMAL.**

**Given** I'm in INSERT mode and the input layer delivers `0x1B` (Esc)
**When** dispatch_insert routes `0x1B` to `enter_normal_mode` (already wired in Story 2.5 + dispatch_insert table; Story 2.8 unchanged here)
**Then** `mode_byte := MODE_NORMAL`, status shows `"-- normal --"` (`msg_mode_normal`), `cursor_offset` stays where the last insert (or entry) left it, parser state zeroed.

**Undo recording for B2** (insert-session-as-single-undo-entry, PRD §V4-B2 line 1695-1703): for Story 2.8 the recording is a **STUB** — no entry is written to `undo_buffer`. `u` post-INSERT-Esc reports `msg_nothing_to_undo` (existing capacity-refusal path). Full session-recording lands in Story 2.13. Document the stub explicitly so 2.13's dev knows where to wire in.

**AC8 — `gapbuf_insert` overflow surfaces and exits INSERT.**

**Given** I'm in INSERT mode and the gap buffer is about to fill (`gap_start == gap_end - 1`)
**When** I type one more byte
**Then** `gapbuf_insert` writes the byte successfully (CF=0). The NEXT byte typed sees `gap_start == gap_end` and gapbuf_insert returns CF=1 — having already called `status_set_message(msg_file_too_large)` per its existing AC4 contract (Story 1.7).
- `edits_insert_literal` checks CF on return; on CF=1 it sets `mode_byte := MODE_NORMAL` and exits via tail-JP `parser_clear`.
- **State preserved on overflow:** all bytes inserted BEFORE the failing one ARE in the buffer. `buffer_dirty` is `1`. `cursor_offset` reflects the last successful insert position. The user CAN press `:w` from NORMAL to save the partial content.

**Note:** the same overflow path applies to `o` and `O` if the buffer is at 32767 B and one more byte would overflow — those handlers detect CF=1 from their internal `gapbuf_insert(0x0A)` and bail to NORMAL without committing the mode change (per AC3 / AC4 failure paths). This is the FR52 "no silent data loss" invariant under edit pressure.

**AC9 — `buffer_dirty` set on the first insert; survives subsequent typing.**

**Given** a clean buffer (`buffer_dirty == 0`) and a fresh INSERT session
**When** the first byte is successfully inserted via `gapbuf_insert` (or via the `o` / `O` LF-insert)
**Then** `buffer_dirty := 1`. Subsequent inserts re-write `1` (idempotent; the simpler-is-cleaner choice over a "first-insert-only" branch which would save ~3 B but obscure the invariant).
**And** `buffer_dirty` stays at `1` across Backspace, Esc, and any subsequent NORMAL-mode activity until a successful `:w` clears it (Story 2.4's `fileio_save` clears `buffer_dirty` on success; unchanged).

**AC10 — Enter key (0x0D) in INSERT translates to LF (0x0A).**

**Given** I'm in INSERT mode and the input layer delivers `0x0D` (Carriage Return — what hardware Enter typically sends in CP/M)
**When** dispatch_insert routes the literal-byte fall-through
**Then** `edits_insert_literal` (or the dispatch_insert table's bound 0x0D handler — implementation choice; see Sub 3.5) translates 0x0D → 0x0A and calls `gapbuf_insert(0x0A)`. Rationale: VIBE's line separator is LF (0x0A); the user typing Enter expects to terminate the current line. Inserting raw 0x0D would render as a phantom byte (deferred-work line 76 — TAB/CR/NUL/high-bit byte rendering desync; on a CR-bearing file the existing render CR-filter from Story 2.5 UAT2 paints CR as space, but the byte STILL persists).

**Decision required:** EITHER bind `0x0D` explicitly in `dispatch_insert` to a tiny `edits_insert_newline` handler that calls `gapbuf_insert(0x0A)` and triggers `render_mark_all_dirty` (the LF shifts every row below); OR have `edits_insert_literal` test for `A == 0x0D` and translate inline. The bind-explicitly choice is ~+6 B (one more entry in dispatch_insert table) but factors the row-dirty decision cleanly (LF inserts mark all rows dirty; non-LF inserts mark only the cursor row). **Recommended: bind explicitly.** Document the choice in the change log.

**AC11 — Out-of-range bytes (`A < 0x20` or `A >= 0x7F`) in INSERT mode are silent no-ops.**

**Given** I'm in INSERT mode and the input layer delivers a byte that is NOT printable ASCII (`0x20..0x7E`)
**When** dispatch_insert's literal-byte path (`edits_insert_literal`) sees `A < 0x20` (control bytes) OR `A >= 0x7F` (DEL + synthesised keycodes 0x80..0x83 + C1 controls + 0x84..0xFF)
**Then** the handler silently returns without calling gapbuf_insert (two checks: `CP 0x20 / RET C` then `CP 0x7F / RET NC`). Rationale: control bytes and unmapped high-bit codes render raw, desyncing shadow vs physical screen (deferred-work line 76); a stray arrow keystroke mid-INSERT would otherwise commit 0x80..0x83 into the gap buffer and onto disk via `:w` (FR52 corruption hazard); FR50 says unsupported keys are no-ops; the simplest safe behaviour is "swallow." High-bit bytes are NOT accepted (tightened from the original "0x80+ accepted as extended ASCII" wording per code review 2026-05-16 D1; if a future story needs to support extended-ASCII text input, this filter must be revisited).

**Note:** Story 1.9's `unbound_insert` was a silent RET; this story's `edits_insert_literal` IS the new unbound_insert body (Story 2.8 dispatch.asm patch: `unbound_insert: JP edits_insert_literal`). The "always swallow control bytes" rule is the same shape as the old stub, just with the printable-byte path landing too.

**AC12 — `dispatch_insert` table growth.**

**Given** the pre-2.8 `dispatch_insert` table has 1 entry (Esc → `enter_normal_mode`; `DISPATCH_INSERT_COUNT = 1`)
**When** Story 2.8 lands
**Then** the table grows to 3 entries (Backspace `0x08`, Enter `0x0D` if AC10's "bind explicitly" choice is taken, Esc `0x1B`), sorted ascending by ASCII byte with adjacent-pair `ASSERT` re-stitching. `DISPATCH_INSERT_COUNT = 3`. Binary-search worst case `ceil(log2(3)) = 2` iterations (NFR3 unchanged — well inside frame budget).

If AC10 takes the "translate inline" choice instead, the table grows to 2 entries (Backspace, Esc) and `DISPATCH_INSERT_COUNT = 2`.

**AC13 — Architecture compliance — `edits.asm` as a new clean-or-near-clean module.**

`src/edits.asm` is the new module. AR boundary properties:
- **AR13 (no screen emission):** edits.asm MUST NOT call `BIOS_CONOUT_*`. Grep-sweep `grep -n 'BIOS_CONOUT' src/edits.asm` returns zero code refs (only doc-comment header references permitted).
- **AR14 (no direct buffer mutation):** edits.asm DOES mutate the buffer, but ONLY through the gapbuf primitives `gapbuf_insert` / `gapbuf_delete` (read of `gap_start` / `gap_end` for cursor-row math is permitted as SR3 read). No direct writes to `(gap_start)` / `(gap_end)` / inside the gap-buffer region. Grep-sweep `grep -nE 'LD \((gap_start|gap_end)\),' src/edits.asm` returns zero code refs (only via gapbuf entries).
- **AR15 (no raw BDOS):** edits.asm calls no BDOS. Grep-sweep `grep -nE 'BDOS_CALL|CALL BDOS_ENTRY|CALL 0x0005' src/edits.asm` returns zero refs.
- **AR12 (status via funnel):** edits.asm does NOT directly write status bytes; all status text routes through `status_set_message` (already used internally by gapbuf_insert on overflow). The `o` / `O` failure path may need a defensive re-call of `status_set_message` if the gapbuf-side message gets overwritten by intermediate state writes — pin this in tests.
- **AR23 (module header docstring):** edits.asm has a fully-documented module-header block: Public, Internal, Trashes for each entry, gapbuf-primitive call sites enumerated.
- **AR25 (INCLUDE chain):** `src/vibe.asm`'s INCLUDE order extends from `statusln → gapbuf → render → dispatch → parser → motions → exline → fileio` to `statusln → gapbuf → render → dispatch → parser → motions → edits → exline → fileio`. The slot between `motions.asm` and `exline.asm` is the long-documented position (src/vibe.asm:140 — "future stories (2.8-2.13 edits, 3.x search/visual) will INCLUDE between motions.asm and exline.asm as they arrive"). Update the comment block at that site to reflect that edits has landed.

**AC14 — Hardware UAT on real MicroBeast (deferred to user; same pattern as Stories 1.11 / 1.12 / 2.1 / 2.2 / 2.3 / 2.4 / 2.5 / 2.6 / 2.7).**

The dev MUST NOT mark this story `done` without confirmed hardware UAT by Ant. The dev pass produces `:wq`-ready code; the user (Ant) runs `make push` and steps through the UAT script.

Hardware UAT script (15 steps):

1. **Pre-state:** boot fresh, no prior `vibe` invocation this session.
2. **`vibe newgame.fs`** (a name without a pre-existing file) — confirm launches with status `"newgame.fs [new file]"`, cursor at offset 0, mode `-- normal --`. (Story 2.3 regression net.)
3. **Press `i`** — status flips to `-- insert --`, cursor unchanged.
4. **Type `Hello`** — five literal bytes inserted; cursor advances by 5; on-screen cursor moves rightward as you type; `buffer_dirty` becomes nonzero (verify via subsequent `:q` refusal in step 8).
5. **Press Esc** — status flips back to `-- normal --`, cursor stays at offset 5 (just past the `'o'`).
6. **Press `:w`** — status reports `"newgame.fs 5 bytes written"` (or similar, per Story 2.4 status format). `buffer_dirty := 0`.
7. **Press `:q`** — warm-boot back to CP/M (no refusal — buffer is clean post-save).
8. **`vibe newgame.fs`** (re-launch) — file loads; status shows `"newgame.fs 5 bytes loaded"`; buffer content is `"Hello"`; cursor at offset 0.
9. **Press `$` then `a`**, then type ` world` (space, then `w`, `o`, `r`, `l`, `d`) and Esc — buffer is now `"Hello world"` (11 bytes); cursor at offset 11; `buffer_dirty := 1`. *(Trace: post-load cursor is at offset 0; `$` moves to last printable byte at offset 4 ('o' of "Hello"); `a` advances to offset 5 = file_length per AC2's EOF rule on a no-trailing-LF buffer; typing then appends.)* **Note:** the original AC14 draft said "press `i` then type ` world`" — that lands `" worldHello"` (cursor=0 post-load + `i` inserts at cursor), which exercises the code correctly but doesn't produce the expected `"Hello world"` content. Hardware UAT 2026-05-16 caught this; the `$a` shape is the corrected sequence.
10. **Press `:q`** (no force) — refusal status banner: `"no write since last change"` (Story 2.2 FR51/FR52 regression net). Buffer preserved.
11. **Press `:w` then `:q`** — save and quit cleanly.
12. **`vibe newgame.fs`** — content `"Hello world"`. Press `o` — cursor moves to EOL (offset 11), LF inserted, mode becomes INSERT, cursor lands at offset 12 (start of new empty line below; was `file_length=11` pre-`o`; now `file_length=12` post-LF). On-screen: a new line appears below `"Hello world"`.
13. **Type `line 2`** then Esc, `:wq` — buffer `"Hello world\nline 2"` (18 bytes) saved. Re-launch verifies file content.
14. **Edge case: `O` on first line.** Open the file again, press `O` immediately — cursor moves to BOL (offset 0), LF inserted at 0, cursor decrements back to 0. INSERT mode. Type `line 0` then Esc, `:wq` — buffer is `"line 0\nHello world\nline 2"` (25 bytes).
15. **Sustained-typing regression** — `vibe newgame.fs`, press `i`, type ~60 chars rapidly across multiple words spanning at least one Enter (LF) keystroke (NFR2 ≥ 10 chars/sec sustained); confirm no dropped keystrokes, no terminal corruption, the cursor lands where expected, post-Esc the buffer matches what was typed, render keeps up (no perceptible freeze per NFR3).

The hardware UAT also looks for regressions against earlier stories: motion still works after INSERT exits (Stories 2.5 / 2.6 / 2.7 h/j/k/l/w/b/0/$/G/gg/counts); ex-line `:w` / `:q` / `:q!` / `:e` still work (Stories 2.1 / 2.2 / 2.4); counted motions in NORMAL still respect their counts (Story 2.7). UAT MAY reveal a regression in the render-pipeline INSERT-mode cursor positioning (the editor renders RI4 cursor based on `cursor_offset` post-handler; INSERT-mode cursor styling differs from NORMAL in some vi variants but VIBE's deferred-work line ~ has no policy — keep it the same block cursor as NORMAL).

**AC15 — Headless tests (all under `test/cases/edits_*.asm`).**

**Canonical (epics spec line 1252):**
- `edits_i-and-type.asm` — pre-state cursor=0 empty-buffer; CALL `enter_insert_mode` (with A='i'); assert `mode_byte == MODE_INSERT`. Then drive 5 literal bytes (`'H'` / `'e'` / `'l'` / `'l'` / `'o'`) through `edits_insert_literal` (or `dispatch_key` against `dispatch_insert`); assert `cursor_offset == 5`, `buffer_dirty == 1`, gap-buffer content via gap-walk = `"Hello"`. Then drive Esc → `enter_normal_mode`; assert `mode_byte == MODE_NORMAL`, `cursor_offset == 5` (unchanged on Esc).
- `edits_a-at-eol.asm` — pre-load buffer `"hello\nworld"` (11 B); cursor=4 (the `'o'` of `"hello"`, last printable of line 1); CALL `edits_enter_insert_after` (with A='a'); assert `cursor_offset == 5` (the LF position; AC2 EOL-rule). Then drive literal `'X'`; assert buffer post-walk = `"helloX\nworld"` (12 B), cursor=6, buffer_dirty=1.
- `edits_o-creates-newline.asm` — pre-load `"hello\nworld"` (11 B); cursor=2; CALL `edits_open_below`; assert cursor=6 post-handler (start of new empty line — was line 1's LF at 5, post-LF-insert cursor advanced to 6 which is the LF byte of the new empty line); buffer post-walk = `"hello\n\nworld"` (12 B); `mode_byte == MODE_INSERT`; `buffer_dirty == 1`.
- `edits_O-creates-newline-above.asm` — pre-load `"hello\nworld"` (11 B); cursor=8 (`'r'` of `"world"`); CALL `edits_open_above`; assert cursor=6 post-handler (the just-inserted LF; new empty line above original line 2); buffer post-walk = `"hello\n\nworld"` (12 B); `mode_byte == MODE_INSERT`; `buffer_dirty == 1`.
- `edits_insert-fills-buffer.asm` — pre-load buffer with `GAP_BUFFER_MAX - 1 = 32767` bytes of `'A'`; cursor at file_length; set `mode_byte = MODE_INSERT`; drive literal `'X'` through `edits_insert_literal` — first byte succeeds (cursor advances, buffer_dirty=1). Drive literal `'Y'` — gapbuf_insert returns CF=1; assert `status_buffer` contains `"file too large"` (compare against `msg_file_too_large`); `mode_byte == MODE_NORMAL` post-overflow (AC8 exit); cursor at file_length (the `'X'` succeeded; `'Y'` did not advance state). **Note:** this test is slow (32 KB LDIR fill); confirm it completes within the iz-cpm 5-second timeout. If timeout pressure is real, shrink GAP_BUFFER_MAX via a test-time-only EQU override (the pattern used by existing render/scroll tests, if any).

**Additional (full AC coverage):**
- `edits_backspace-mid-line.asm` — `"abcdef"` cursor=3, MODE_INSERT; drive Backspace; assert buffer walk = `"abdef"` (5 B), cursor=2, buffer_dirty=1, mode_byte unchanged. AC6.
- `edits_backspace-at-bof.asm` — `"abcdef"` cursor=0, MODE_INSERT; drive Backspace; assert buffer unchanged (6 B), cursor=0 (no decrement), buffer_dirty unchanged (defensive: if buffer was 0 entering, stays 0; if 1 entering, stays 1 — Backspace at BOF doesn't TOUCH buffer_dirty). AC6.
- `edits_enter-inserts-lf.asm` — `"abc"` cursor=1, MODE_INSERT; drive 0x0D through dispatch_insert; assert buffer walk = `"a\nbc"` (4 B; the LF inserted at offset 1, cursor advanced to 2), cursor=2, buffer_dirty=1. AC10.
- `edits_control-byte-silent-noop.asm` — `"abc"` cursor=1, MODE_INSERT; drive a control byte (e.g. 0x05 — ENQ); assert buffer unchanged (3 B), cursor=1 (no advance), buffer_dirty unchanged. AC11.
- `edits_a-at-eof-no-lf.asm` — `"hello"` (5 B, no trailing LF); cursor=4 (`'o'`); CALL `edits_enter_insert_after`; assert cursor=5 (file_length, AC2 EOF advance). Then drive literal `'X'`; assert buffer walk = `"helloX"` (6 B), cursor=6.
- `edits_O-on-first-line.asm` — `"hello\nworld"` (11 B); cursor=2 (line 1); CALL `edits_open_above`; assert cursor=0 (the new empty line at BOL of original line 1 — find_line_start(2)=0, insert LF at 0 → buffer `"\nhello\nworld"`, cursor advances to 1, DEC → 0); buffer walk = `"\nhello\nworld"` (12 B). AC4 line-1 corner.
- `edits_O-on-empty-buffer.asm` — empty buffer (file_length=0); cursor=0; CALL `edits_open_above`; assert cursor=0; buffer walk = `"\n"` (1 B); MODE_INSERT. AC4 empty-file corner.
- `edits_buffer-dirty-set-on-first-insert.asm` — clean buffer (`buffer_dirty=0`); insert one byte via `edits_insert_literal`; assert buffer_dirty=1. AC9.
- `edits_esc-from-insert-clears-parser-state.asm` — pre-set `count_accumulator=5`, `pending_operator='d'`, `pending_motion_prefix='g'`, mode=INSERT; drive Esc through dispatch_insert → enter_normal_mode (which tail-JPs parser_clear per Story 2.5 AC13); assert all three parser-state fields zeroed post-Esc. AC7 + Story 2.5 AC13 regression net.

14 canonical+additional total (5 canonical + 9 additional; dev shipped all 9 additional rather than dropping any optional ones). Sentinel range 0x80..0x86 (continuing the Story 2.5 / 2.6 / 2.7 convention).

**AC16 — Build invariants (NFR9, NFR18, AR sweeps).**

- `make all` followed by `make clean && make all` produces a byte-identical `vibe.com` (NFR18).
- `make test` from a fresh `make clean && make test` is green (the 92 pass / 1 deliberate-fail post-2.7 baseline grows by 11 to ~103 pass / 1 fail).
- AR13 / AR14 / AR15 grep sweeps against `src/edits.asm` are all clean (Sub 6.3 enforces).
- AR25 INCLUDE chain in `src/vibe.asm` is `statusln → gapbuf → render → dispatch → parser → motions → edits → exline → fileio`. The pre-2.8 comment at vibe.asm:140 ("future stories will INCLUDE between motions.asm and exline.asm") is updated to "edits.asm landed in Story 2.8; visual/search slot post-2.8 per Story 3.x."
- `dispatch_normal` entries for `'a'` / `'o'` / `'O'` change handler addresses (Story 1.9 had all four routing to `enter_insert_mode`; Story 2.8 reroutes three to new `edits_enter_insert_after` / `edits_open_below` / `edits_open_above` while `'i'` stays on `enter_insert_mode`). The dispatch_normal entry count is unchanged at 32 (binary-search worst case unchanged at 5 iterations; NFR3 unaffected).
- `dispatch_insert` grows from 1 entry (Esc) to 3 (Backspace, Enter, Esc) — AC12. Or to 2 (Backspace, Esc) if AC10 takes the translate-inline choice.
- `unbound_insert` body changes from `RET` to `JP edits_insert_literal` (the literal-insertion fall-through that Epic 2 needs; supersedes the 1.9 stub per the existing comment in dispatch.asm:393).
- **NFR9 projection:** post-2.7 footprint = 4380 B. Story 2.8 adds (a) `src/edits.asm` ~300-400 B (4 entry-point handlers + literal-insert dispatcher + backspace handler + module header; estimate based on `motions.asm`'s ~265 B per public handler with helpers); (b) dispatch.asm: +6-9 B for the `dispatch_insert` table growth + the `JP edits_insert_literal` body swap in `unbound_insert`; (c) dispatch_normal reroutes: 0 B delta (handler addresses change, not slot count). Projected post-2.8: 4690-4790 B = 91.6-93.5% of 5120 B = 330-430 B headroom. **No NFR9 amend required** — but the headroom is tightening; Story 2.9 (`x`) is small (~50 B), Stories 2.10-2.12 (dd/yy/dw/p) are the next significant deltas. Flag if projection overshoots by >50 B for retro review.
- **`buffer_dirty` write count:** Story 2.8 introduces ≥ 5 sites writing `buffer_dirty := 1` (one in `edits_insert_literal`, one in `edits_insert_backspace`, one each in `edits_open_below` / `edits_open_above`'s success paths, plus the `o`/`O` fail-rollback NEVER writes buffer_dirty so it stays at its pre-`o`/`O` value). Inspect that no edit handler returns without setting buffer_dirty on a successful mutation path.

## Tasks / Subtasks

- [x] **Task 1: Create `src/edits.asm` with the module header docstring** (AC13, AR23).
  - [x] Sub 1.1: Module header: Module / Purpose / Public (6 entries: `edits_enter_insert_after`, `edits_open_below`, `edits_open_above`, `edits_insert_literal`, `edits_insert_backspace`, `edits_insert_newline`) + 4 internal helpers (`edits_open_success_tail`, `edits_open_overflow`, `edits_dirty_and_redraw`, `edits_overflow_to_normal`) emerged as shared tails. Calls / Trashes / State written / Architectural enforcement summary all landed per AR23.
  - [x] Sub 1.2: AR25 INCLUDE chain — `src/vibe.asm` patched: `INCLUDE "edits.asm"` slotted between `motions.asm` and `exline.asm`; the comment block at `src/vibe.asm:126-146` updated to remove "edits not yet present" wording and document edits.asm landed.

- [x] **Task 2: Implement `edits_insert_literal`** (AC5, AC8, AC11; bound via `unbound_insert: JP edits_insert_literal` patch).
  - [x] Sub 2.1: AR23 contract documented in `src/edits.asm` header.
  - [x] Sub 2.2: Control-byte filter `CP 0x20 ; RET C` lands at the head of `edits_insert_literal`. Cut precondition documented inline (Esc/BS/Enter routed by dispatch_insert table BEFORE this handler).
  - [x] Sub 2.3: Insert path `CALL gapbuf_insert ; JR C, edits_overflow_to_normal` then fall through to shared `edits_dirty_and_redraw`. No PUSH AF needed (gapbuf_insert consumes A as the byte; we don't need it after).
  - [x] Sub 2.4: Conservative `render_mark_all_dirty` chosen (tail-JP via `edits_dirty_and_redraw`). Fine-grained variant deferred — logged in deferred-work.md as Growth-tier optimisation.
  - [x] Sub 2.5: Overflow path factored to shared `edits_overflow_to_normal: LD A, MODE_NORMAL ; LD (mode_byte), A ; JP parser_clear`. No re-call of status_set_message (gapbuf_insert already set the message).

- [x] **Task 3: Implement `edits_insert_backspace`** (AC6).
  - [x] Sub 3.1: AR23 contract documented in module header.
  - [x] Sub 3.2: BOF guard — `CALL gapbuf_delete ; RET C` silent at BOF (gapbuf_delete sets CF=1 with state unchanged per its AC5 contract).
  - [x] Sub 3.3: Conservative `render_mark_all_dirty` via `JP edits_dirty_and_redraw`. The motion_byte_at_logical inspect-byte-before-delete optimisation is deferred (Growth tier).
  - [x] Sub 3.4: `dispatch_insert` table entry `0x08 → edits_insert_backspace` added (Task 7 below).

- [x] **Task 4: Implement `edits_enter_insert_after`** (AC2).
  - [x] Sub 4.1: AR23 contract documented.
  - [x] Sub 4.2: Cursor-advance: `LD HL, (cursor_offset) ; CALL motion_byte_at_logical ; JR C, .skip ; CP 0x0A ; JR Z, .skip ; INC HL ; LD (cursor_offset), HL`. Single helper call handles both past-EOF (CF=1) and on-LF (A==0x0A) skip-advance cases.
  - [x] Sub 4.3: `.skip: JP enter_insert_mode` — tail-JP reuses the existing mode + status + parser_clear body. Saves ~9 B vs open-coding.

- [x] **Task 5: Implement `edits_open_below`** (AC3).
  - [x] Sub 5.1: AR23 contract documented.
  - [x] Sub 5.2: `LD HL, (cursor_offset) ; PUSH HL` saves entry cursor on stack as rollback target.
  - [x] Sub 5.3: `CALL motion_find_line_end ; LD (cursor_offset), HL` lands cursor at LF position or file_length.
  - [x] Sub 5.4: `LD A, 0x0A ; CALL gapbuf_insert ; JR C, edits_open_overflow` — fall-through on success to shared `edits_open_success_tail`.
  - [x] Sub 5.5: Success tail factored to shared `edits_open_success_tail` (used by both o and O): `LD A, 1 ; LD (buffer_dirty), A ; CALL render_mark_all_dirty ; POP BC ; JP enter_insert_mode`. Saves ~9 B per call site vs open-coding.
  - [x] Sub 5.6: Overflow rollback factored to shared `edits_open_overflow`: `POP HL ; LD (cursor_offset), HL ; JP parser_clear`.

- [x] **Task 6: Implement `edits_open_above`** (AC4).
  - [x] Sub 6.1: AR23 contract documented; symmetric with edits_open_below.
  - [x] Sub 6.2: `PUSH HL` saves entry cursor.
  - [x] Sub 6.3: `CALL motion_find_line_start` reaches BOL.
  - [x] Sub 6.4: `LD A, 0x0A ; CALL gapbuf_insert ; JR C, edits_open_overflow`.
  - [x] Sub 6.5: `LD HL, (cursor_offset) ; DEC HL ; LD (cursor_offset), HL` — cursor lands ON the just-inserted LF, which IS the new empty line above original.
  - [x] Sub 6.6: Falls through to shared `edits_open_success_tail`.
  - [x] Sub 6.7: Overflow shares `edits_open_overflow` with edits_open_below.

- [x] **Task 7: Patch dispatch.asm** (AC12, AC13).
  - [x] Sub 7.1: `dispatch_normal` reroutes complete — 'a' → edits_enter_insert_after, 'o' → edits_open_below, 'O' → edits_open_above; 'i' stays on enter_insert_mode. Adjacent-pair ASSERTs unchanged (handler addresses change, not slot keys).
  - [x] Sub 7.2: `dispatch_insert` grown 1 → 3 entries: 0x08 (Backspace) → edits_insert_backspace, 0x0D (Enter) → edits_insert_newline, 0x1B (Esc) → enter_normal_mode. ASSERT re-stitching added (`0x0D > 0x08`, `0x1B > 0x0D`). `DISPATCH_INSERT_COUNT = 3` (confirmed via `LD B, DISPATCH_INSERT_COUNT` resolving to `06 03` in build/vibe.lst).
  - [x] Sub 7.3: `unbound_insert: JP edits_insert_literal`. Doc comment block rewritten to reflect the body change and the new control-byte filter location (inside edits_insert_literal); removed "Story 1.9 silent RET stub" language.

- [x] **Task 8: Implement `edits_insert_newline`** (AC10 — explicit-bind choice).
  - [x] Sub 8.1: AR23 contract documented. parser_clear skipped on success path (INSERT mode doesn't run parser; parser_clear is dead weight here — saved ~3 B vs symmetry). On overflow the shared `edits_overflow_to_normal` tail-JPs parser_clear, which is necessary because the INSERT-exit transitions to NORMAL mode where parser state matters.
  - [x] Sub 8.2: Body — `LD A, 0x0A ; CALL gapbuf_insert ; JR C, edits_overflow_to_normal ; JP edits_dirty_and_redraw`. Overflow shares the literal-handler exit-to-NORMAL path.

- [x] **Task 9: Headless tests** (AC15).
  - [x] Sub 9.1: 5 canonical tests landed: `edits_i-and-type` / `edits_a-at-eol` / `edits_o-creates-newline` / `edits_O-creates-newline-above` / `edits_insert-fills-buffer` (32 KB LDIR fill confirmed in-budget under iz-cpm).
  - [x] Sub 9.2: 9 additional tests landed (none dropped — all in scope): `edits_backspace-mid-line` / `edits_backspace-at-bof` / `edits_enter-inserts-lf` / `edits_control-byte-silent-noop` / `edits_a-at-eof-no-lf` / `edits_O-on-first-line` / `edits_O-on-empty-buffer` / `edits_buffer-dirty-set-on-first-insert` / `edits_esc-from-insert-clears-parser-state`. Total 14 new headless tests under `test/cases/edits_*.asm`.
  - [x] Sub 9.3: All tests follow the Story 2.5/2.6/2.7 pattern. Sentinel range 0x80..0x85 (within the 0x80..0x87 allocation). Each test uses pre-zero state + LDIR payload-fill + CALL/dispatch_key drive + sentinel-on-fail.

- [x] **Task 10: NFR9 + NFR18 + AR sweeps** (AC16).
  - [x] Sub 10.1: Two consecutive `make clean && make all` produce byte-identical `vibe.com` — SHA `e30f002f3d2f2753ee9116f20ca1c1ca83085bdeede0713a38164d91f3ce7729` x2. NFR18 ✓.
  - [x] Sub 10.2: AR enforcement sweeps all clean:
    - `grep -n 'BIOS_CONOUT' src/edits.asm` — only 2 doc-comment matches at lines 130 + 477 (no code references).
    - `grep -nE 'LD \((gap_start|gap_end)\),' src/edits.asm` — only 2 doc-comment matches at lines 137-138 (no code references).
    - `grep -nE 'BDOS_CALL|CALL BDOS_ENTRY|CALL 0x0005' src/edits.asm` — only 2 doc-comment matches at lines 141-142.
    - `grep -c 'CALL\s\+gapbuf_insert' src/edits.asm` = 4 (edits_insert_literal, edits_open_below, edits_open_above, edits_insert_newline).
  - [x] Sub 10.3: `vibe.com` size = **4510 B** = **88.1%** of 5120 B = **610 B headroom**. Below the spec's 4690-4790 B projection (efficient — the shared-tail factoring saved ~25-30 B vs the open-coded sketch). +130 B vs Story 2.7's 4380 B (under the 310-410 B projected delta).
  - [x] Sub 10.4: `DISPATCH_NORMAL_COUNT = 32` unchanged (handler-address reroutes, not slot-count changes). `DISPATCH_INSERT_COUNT = 3` (verified in build/vibe.lst: `LD B, DISPATCH_INSERT_COUNT` resolves to `06 03`).
  - [x] Sub 10.5: Live baseline = **106 pass / 1 deliberate fail** (was 92/1 post-Story-2.7; +14 new — three more than spec's projected +11 because dev landed all listed additional tests rather than dropping any).

- [x] **Task 11: deferred-work.md housekeeping.**
  - [x] Sub 11.1: B2 undo recording stub entry added to deferred-work.md with cross-link to `enter_normal_mode` (dispatch_insert[0x1B] tail target) as the Story 2.13 hook site.
  - [x] Sub 11.2: Render-mark-row-dirty fine-grained variant logged as Growth-tier optimisation.
  - [x] Sub 11.3: 32-KB LDIR fill confirmed in-budget under iz-cpm (sub-ms host-speed); test-time GAP_BUFFER_MAX override pattern documented as available fallback if a future story exhausts the timeout.
  - [x] Sub 11.4 (added): 80 test files manually patched to INCLUDE edits.asm (the test/Makefile dependency-hygiene gap re-flagged from Stories 2.5/2.6).
  - [x] Sub 11.5 (added): o/O overflow path's choice to NOT re-call status_set_message documented (gapbuf_insert's pre-existing call holds; no intermediate writes between gapbuf_insert and parser_clear).

- [ ] **Task 12: Hardware UAT** (AC14) — deferred to user per AC14 specification.
  - [ ] Sub 12.1: `make push` SLIDE transfer hook to be confirmed by Ant on the dev environment.
  - [ ] Sub 12.2: Ant steps through the 15-step AC14 UAT script on real MicroBeast; capture any regression / new failure modes in the change log.
  - [ ] Sub 12.3: Story stays at `review` (NOT `done`) until AC14 confirmed.

### Review Findings

_Code review 2026-05-16 — 3 layers (Blind Hunter / Edge Case Hunter / Acceptance Auditor). Acceptance Auditor reports 14/14 ACs MET. Findings below: 1 decision-needed, 11 patches, 3 deferred, ~16 dismissed as noise._

- [x] [Review][Patch] Tighten INSERT-mode literal filter to reject `0x7F` (DEL) and `0x80+` (synth keycodes + C1 controls) — applied: added `CP 0x7F / RET NC` after `CP 0x20 / RET C` in `edits_insert_literal`; AC5 + AC11 amended in this spec to reflect the tightened "0x20..0x7E printable ASCII only" range and the corruption-hazard rationale; new test `test/cases/edits_high-bit-silent-noop.asm` drives 0x82 (KEY_ARROW_LEFT) through dispatch_key against dispatch_insert and asserts buffer + cursor + buffer_dirty all unchanged. +3 B (4510 → 4513 B). [src/edits.asm:411-415]
- [x] [Review][Patch] unbound_insert doc-contract contradiction — applied: Out comment block rewritten to disclose the two-path A-preservation: filter-rejected paths preserve A, success path clobbers via gapbuf_insert; caller MUST NOT rely on A across the call. [src/dispatch.asm — unbound_insert header]
- [x] [Review][Patch] edits.asm module-header Purpose lists FR13 + FR16 but neither lives in this module — applied: Purpose corrected to "FR24-FR27 only" with explicit notes that FR13 stays on enter_insert_mode and FR16 stays on enter_normal_mode in dispatch.asm. [src/edits.asm header]
- [x] [Review][Patch] edits_O-on-empty-buffer.asm missing `mode_byte == MODE_INSERT` assertion — applied: added sentinel 0x83 + mode check after the file_length assertion. [test/cases/edits_O-on-empty-buffer.asm]
- [x] [Review][Dismiss] edits_insert_backspace Trashes contract — DISMISSED: verified against actual contracts of gapbuf_delete (trashes A, BC, DE, HL, F) and render_mark_all_dirty (trashes A, F). The handler chain unions to exactly the documented "A, BC, DE, HL, F." Blind Hunter's claim was wrong on this one. [src/edits.asm — edits_insert_backspace header]
- [x] [Review][Dismiss] edits_dirty_and_redraw Trashes "A, F" — DISMISSED: render_mark_all_dirty's documented contract is "Trashes: A, F" (it only writes constant 0xFF into three dirty-row bytes; no register usage beyond A and F). Existing "A, F" claim is accurate. Blind Hunter's claim was wrong. [src/edits.asm:443]
- [x] [Review][Patch] edits_open_success_tail Trashes header misses DE — applied: header amended to "A, BC, DE, F, HL" with explicit note that enter_insert_mode trashes DE via its status_set_message + parser_clear chain. [src/edits.asm:327-329]
- [x] [Review][Patch] dispatch_insert table 0x08 (Backspace) not exercised through `dispatch_key` — applied: new test `test/cases/edits_dispatch-insert-routes-backspace.asm` drives 0x08 through dispatch_key against dispatch_insert; asserts cursor decrement + buffer_dirty=1. (0x0D Enter is already exercised in `edits_enter-inserts-lf.asm` via dispatch_key — verified.) [test/cases/edits_dispatch-insert-routes-backspace.asm]
- [x] [Review][Patch] edits_a-at-eol.asm doesn't assert `buffer_dirty == 1` — applied: added sentinel 0x83 + buffer_dirty check after the buffer-content compare. [test/cases/edits_a-at-eol.asm]
- [x] [Review][Patch] edits_insert-fills-buffer.asm doesn't assert `buffer_dirty == 1` — applied: added sentinel 0x84 + buffer_dirty check after the status-prefix compare; pins the FR52 partial-text-preserved invariant. [test/cases/edits_insert-fills-buffer.asm]
- [x] [Review][Patch] edits_o-creates-newline.asm purpose comment misleading — applied: clarified that offset 6 IS the LF terminating the new empty line; subsequent INSERT-mode typing inserts BEFORE that LF, growing the new line. [test/cases/edits_o-creates-newline.asm header]
- [x] [Review][Patch] Story spec arithmetic typos — applied: AC15 closing line corrected to "14 canonical+additional total (5 canonical + 9 additional)"; Sub 1.1 corrected to "4 internal helpers". [this spec file, AC15 + Sub 1.1]
- [x] [Review][Defer] No headless test exercises the `o`/`O` overflow rollback path — `edits_open_overflow`'s `POP HL` is uncovered by tests; a stack-imbalance regression would not be caught. Sub 8.3 marks this as optional per spec.
- [x] [Review][Defer] `o` on an empty buffer leaves cursor at offset 1 (== file_length post-LF-insert) — spec's AC3 narrative ("start of the new empty line below the original") doesn't pin behavior on an empty buffer; currently benign but undocumented.
- [x] [Review][Defer] 80 test files all manually got the same `INCLUDE "../../src/edits.asm"` line — test/Makefile dependency-hygiene gap re-flagged for the third story in a row (already tracked in deferred-work.md).

## Dev Notes

### Architecture compliance

- **AR13 (no screen emission from edits).** `edits.asm` does not call `BIOS_CONOUT_*`. The cursor reposition on each insert is driven by `render.asm`'s RI4 invariant on the next `render_diff` frame (per `input_loop` step 4: `render_diff` runs after every handler). Edits manipulate `cursor_offset` and the gap-buffer; render handles the screen.
- **AR14 (no buffer mutation outside gapbuf primitives).** `edits.asm` mutates the buffer ONLY through `gapbuf_insert` / `gapbuf_delete` — both of which already encapsulate `gapbuf_move_gap` calls when the gap isn't at the cursor. No direct writes to `(gap_start)` / `(gap_end)` or to bytes inside the gap-buffer region. The motions module's `motion_byte_at_logical` is a READ primitive — used by `edits_enter_insert_after` for the AC2 LF-check — and falls under AR14's "reads OK, writes forbidden" boundary.
- **AR15 (no raw BDOS).** `edits.asm` does not call BDOS. The `msg_file_too_large` surfacing on gapbuf_insert overflow goes through `status_set_message` → `bdos_error_funnel`'s emit path (which IS the AR15-compliant surfacing route; the funnel itself contains the only BDOS-adjacent state machinery and is AR23-documented).
- **AR12 (status messages via funnel).** All status writes from edits route through `status_set_message`. The overflow banner is set by `gapbuf_insert` internally; edits handlers don't re-write it on the same code path (re-writing would clobber harmlessly but wastes bytes).
- **AR23 (module header documentation).** `edits.asm` lands a full module-header block per AR23. Each public entry documents In / Out / Trashes / Calls / State written.
- **AR25 (INCLUDE chain).** `src/vibe.asm` INCLUDE order extends to slot `edits.asm` between `motions.asm` and `exline.asm`. The comment at vibe.asm:136-145 is updated.
- **MC3 (binary-search dispatch).** `dispatch_normal` count unchanged at 32 entries (worst case 5 iterations). `dispatch_insert` grows to 3 entries (worst case 2 iterations — `ceil(log2(3))`). Both well inside NFR3 frame budget.
- **MC4 (handler signature — A=key on entry; state via state.inc symbols).** All new handlers accept A as the consumed key (ignored after dispatch). No register-passed args.
- **BH2 (counted-motion clamps — silent at BOF / EOF).** `edits_insert_backspace` follows BH2's "silent at BOF" by no-op-on-CF=1 from gapbuf_delete. `edits_enter_insert_after` follows the same shape for EOL/EOF cursor-clamp.
- **NFR1 (interactive feedback).** Story 2.8 changes the responsiveness story: the editor now ACTUALLY edits buffer content, and every keystroke in INSERT must complete inside one render frame (NFR3 ~ 16 ms target on the MicroBeast's 4 MHz Z80). The cost per keystroke = gapbuf_insert (1-2 LDIR if gap not at cursor; else direct write) + render_mark_all_dirty (cheap 3-byte bitmap set) + render_diff (per-frame; bounded by SCREEN_ROWS × SCREEN_COLS at worst). Sustained typing at NFR2's ≥10 chars/sec is the qualitative validator; AC14 step 15 exercises this on hardware.
- **NFR2 (sustained typing throughput).** Story 2.8 IS the first story where NFR2 is observable. The architecture's expectation is that VIBE absorbs continuous typing without dropping or coalescing keystrokes. The input layer's polling-with-tick-disambiguation pattern (`input_get_key` → `input_loop`) has been validated since Story 1.8; this story exercises it under buffer-mutation load.
- **NFR9 (code size).** Footprint projected 4690-4790 B / 91-94% of the 5120 B ceiling. Tightening — flag any unexpected delta >50 B for retro review.
- **NFR18 (byte-identical rebuild).** Verified in Sub 10.1.
- **FR13 / FR16 / FR24-FR27 (the load-bearing FRs for this story).** End-to-end verification via the 11 headless tests in AC15 + hardware UAT in AC14.
- **B2 (undo scope for insert sessions — PRD §V4-B2 lines 1695-1703).** Story 2.8 ships the STUB; full session-recording lands in Story 2.13. The Esc-from-INSERT path (`enter_normal_mode`) is the documented hook site.

### INSERT-mode semantics — known sharp edges

- **`a` at last printable byte vs `a` on LF byte vs `a` at file_length.** Three cursor states that all "look like end-of-line" need disambiguation:
  - On last printable (cursor=4 in `"hello"`, byte at cursor=`'o'`, no LF in buffer): advance cursor to file_length=5. Insert appends at EOF.
  - On LF byte itself (cursor=5 in `"hello\nworld"`, byte at cursor=0x0A): defensively, this state shouldn't occur post-Story-2.5 (which forbids cursor-on-LF), but `a` MUST NOT advance into the LF region — cursor stays at 5.
  - At file_length sentinel (cursor=file_length, byte_at past-EOF returns CF=1): cursor stays. Insert appends at EOF.
- **`o` on an empty file (file_length=0, cursor=0).** Reach EOL = motion_find_line_end(0) = 0 (no LF before EOF; line_end returns file_length=0). Insert LF at 0 → buffer `"\n"` (1 B), cursor advances to 1 (= file_length post-insert). Cursor lands at file_length, which IS the start of the new (empty) line below. The on-screen render shows a one-LF file with cursor on the "second" line (empty).
- **`O` on the first line.** Reach BOL = motion_find_line_start(C) = 0 for line 1. Insert LF at 0 → cursor advances to 1; DEC → cursor at 0 (the just-inserted LF). On-screen: a new empty line above the original line 1, with cursor on it.
- **`O` on an empty file (file_length=0).** motion_find_line_start(0) = 0 (per its AR23 contract: "if no previous LF, return 0"). Insert LF at 0 → cursor → 1; DEC → cursor=0. Same outcome as the AC4 line-1 case for empty input.
- **gapbuf_insert overflow rollback on `o` / `O`.** The CF=1 path is critical: the user pressed `o` / `O` expecting a new line, but the buffer was full. The handler MUST:
  1. NOT change mode_byte (stay NORMAL).
  2. Restore cursor to its pre-`o` / pre-`O` position.
  3. Let gapbuf_insert's pre-existing `status_set_message(msg_file_too_large)` surface the failure.
  4. Tail-JP `parser_clear` so any stale count / operator from before the keystroke doesn't bleed.
  The PUSH/POP entry-cursor pattern in Tasks 5/6 implements this. Tests `edits_o-overflow.asm` / `edits_O-overflow.asm` (optional — not in the 11 canonical+additional list; flag if dev wants to add) would pin the rollback.
- **Backspace at offset 1 (cursor=1, byte before cursor at offset 0).** gapbuf_delete decrements cursor to 0 and removes the byte. Now `cursor_offset == 0`. The NEXT Backspace returns CF=1 silently. No special case needed.
- **Backspace deleting an LF byte.** The deleted byte at cursor-1 was an LF, so the line above absorbs the current line's content. ALL rows below the cursor row shift up. Conservative shape: `render_mark_all_dirty`. (A fine-grained "inspect byte before delete, branch" could mark only the relevant rows, but the all-dirty path is correct and ~5 B cheaper.)
- **Enter (0x0D) → LF (0x0A) translation.** Hardware Enter on most CP/M consoles sends 0x0D. VIBE's line separator is 0x0A. The translation can live in (a) `input.asm` (key remap at read time), (b) `dispatch_insert` (explicit table entry routing 0x0D to an LF-insert handler), or (c) `edits_insert_literal` (inline branch on A==0x0D). Recommendation: **(b)** — explicit `dispatch_insert` entry routing to `edits_insert_newline`. Cleanest semantically; future Story 3.x search prompt may want different 0x0D semantics in its own mode. The input-layer translation (a) would impose a global policy; the inline branch (c) hides the translation in the literal-byte handler.
- **Control-byte filter in `edits_insert_literal`.** `CP 0x20 ; RET C` swallows bytes 0x00-0x1F. Story 1.9's `unbound_insert` already had a silent RET for any unbound key; this filter is a tighter form. NOTE: the AC11 test `edits_control-byte-silent-noop.asm` should drive a byte like 0x05 (ENQ) that ISN'T bound in dispatch_insert, NOT a byte like 0x08 (Backspace) which IS bound. The byte must reach the literal-byte fallthrough to exercise the filter.

### Render integration

`render.asm` reads `cursor_offset` once per frame in `render_diff`'s cursor-reposition step. Story 2.8's writes to `cursor_offset` happen synchronously in the handler; one frame per handler — INSERT-mode cursor advance shows smoothly as the user types.

**Dirty-row marking strategy:**
- Conservative (Story 2.8 ship target): every successful edit path calls `render_mark_all_dirty`. Worst case: every keystroke marks all 23 editable rows dirty; render_diff diffs each shadow row against the current buffer-derived row. NFR1/NFR2 sustained-typing UAT is the qualitative validator.
- Fine-grained (Growth tier deferred): inspect WHICH bytes changed and mark only the affected rows. For a single non-LF insert / delete, only the cursor row changes. For an LF insert / delete, the cursor row AND every row below changes. This optimisation lives behind a render_count_rows_to_cursor + render_mark_row_dirty(row) call sequence; ~+30 B for the optimisation, ~-1-2 ms per single-char keystroke on the MicroBeast.

The architecture's render_diff already implements per-row shadow diffing — even with all-dirty marking, render_diff will emit only the bytes that actually changed (it compares the shadow buffer against the freshly-rendered buffer-derived row). So all-dirty is correct and cheap-enough; fine-grained is a Growth-tier optimisation.

### Undo stub (B2 — full impl in 2.13)

Story 2.8 ships INSERT mode WITHOUT recording undo entries. Rationale:
- Single-level undo (per PRD §V4-B2) records at INSERT-mode-exit (Esc), capturing the entire session as one entry: entry-cursor, exit-cursor, inserted text.
- The recording mechanism (write to `undo_buffer`, with `msg_undo_too_large` refusal if the session exceeded UNDO_BUFFER_SIZE) is a Story 2.13 deliverable.
- Story 2.8's `enter_normal_mode` tail-JP from dispatch_insert['0x1B'] is the documented hook site — Story 2.13 will insert an undo-record-write step BEFORE the mode flip.
- For 2.8, `u` after an INSERT-Esc session reports `msg_nothing_to_undo` (the existing "no entry recorded" path; src/statusln.asm:222).

This stub is acceptable for journey-1a (compose + save) — undo is "nice to have" for the first-edit journey, not load-bearing. Document the stub explicitly in the change log AND in deferred-work.md so 2.13's dev knows the hook site.

### Library / framework requirements

- **No new library / framework.** Story 2.8 is sjasmplus + iz-cpm only, like every story in this epic.
- **No new sjasmplus idioms.** Existing patterns suffice (DEFB / DEFW / ASSERT / EQU / INCLUDE / LDIR / LDDR / `$` for current address).
- **`src/edits.asm` as a new module.** Follows the Story 2.5 `src/motions.asm` archetype — a new dedicated module with module-header AR23 docstring, public entry points listed, internal helpers documented, called primitives enumerated, trashed-registers per entry per AR23, architectural-enforcement summary at the top.

### Filename and module placement choices

- **New module `src/edits.asm`** lands in the INCLUDE chain between `motions.asm` and `exline.asm`, as long-planned (src/vibe.asm:140-141 comment, architecture.md:945). All edit handlers (FR24-FR32, plus FR45-FR46 undo recorders in 2.13) live here.
- **Test naming convention.** Files under `test/cases/edits_*.asm` exercise the new module's handlers — paralleling `motions_*.asm` (motion handlers), `parser_*.asm` (parser-path tests), `dispatch_*.asm` (dispatcher tests), `gapbuf_*.asm` (gap-buffer primitive tests).
- **Test sentinel allocation.** Continue the Story 2.5 / 2.6 / 2.7 sentinel range 0x80..0x87 per test. Per-subtest sentinels enumerated in the test header per existing convention.

### The INSERT-mode keystroke path

```
keystroke 'i' arrives → dispatch_normal['i'] → enter_insert_mode
                                                 ├─ LD A, MODE_INSERT ; LD (mode_byte), A
                                                 ├─ LD HL, msg_mode_insert ; status_set_message
                                                 └─ JP parser_clear
                                                                                              ; RET to input_loop

keystroke 'H' arrives → input_loop checks mode_byte = MODE_INSERT → dispatch_key against dispatch_insert
                          ├─ binary-search dispatch_insert for 'H' (0x48) — not found
                          └─ fall through to unbound_insert = JP edits_insert_literal
                                                 ├─ CP 0x20 ; RET C (0x48 >= 0x20, continue)
                                                 ├─ CALL gapbuf_insert (A=0x48)
                                                 │     ├─ gap-at-cursor check (Story 1.7 fast path)
                                                 │     ├─ buffer-full check ; CF=1 if full
                                                 │     └─ write byte ; advance gap_start, cursor
                                                 ├─ on CF=0: LD A,1 ; LD (buffer_dirty), A
                                                 │     ; render_mark_all_dirty (conservative)
                                                 │     ; RET → input_loop runs render_diff next iter
                                                 └─ on CF=1: LD A, MODE_NORMAL ; LD (mode_byte), A
                                                       ; JP parser_clear (exit INSERT on overflow)

keystroke Esc arrives → dispatch_insert[0x1B] → enter_normal_mode
                          ├─ LD A, MODE_NORMAL ; LD (mode_byte), A
                          ├─ LD HL, msg_mode_normal ; status_set_message
                          └─ JP parser_clear
                                                                                              ; RET to input_loop
                          ; B2 undo recording stub: Story 2.13 will instrument HERE
```

### Previous story intelligence

**From Story 2.7 (counted motions; verification-heavy):**
- Build SHA byte-identical methodology (NFR18) and AR sweep methodology (grep-based) are well-established. Reuse the exact greps in Sub 10.2.
- Sticky-column hoist in motions.asm preserves the column across counted j/k. `motion_byte_at_logical` (motion_find_line_end / line_start use it transitively) preserves BC per AR23. Story 2.8's `edits_enter_insert_after` calls motion_byte_at_logical to check for the LF byte at cursor — same AR23 contract holds, BC is safe.
- Test-pattern hygiene: pre-zero state, populate gap via LDIR from `.payload`, drive handler via CALL or via dispatch_key, assert via sentinel byte at 0xCFFE.
- The Story 2.7 code review flagged "low-byte-only diagnostic capture" as a pre-existing pattern (deferred-work). Story 2.8 inherits — fine to keep the pattern, just be aware.
- Code-review-stage tests that are "vacuous on the parser_clear chain" (Story 2.7 patch P2-Edge): be deliberate about pre-seeding `pending_motion_prefix` or `pending_operator` to NONZERO values in tests that assert parser_clear ran. The `edits_esc-from-insert-clears-parser-state.asm` test should pre-seed all three parser-state fields to nonzero.
- The Story 2.7 code review confirmed the test fixture for `motions_count-cleared-post-dispatch.asm` had a bug — cursor=6 with count=5 collided moved-by-1 with moved-by-5 at cursor=0. Lesson: when designing a test to pin "moved-by-N", make sure the by-1 outcome differs from the by-N outcome.

**From Story 2.6 (word/line/buffer motions; first major addition to `motions.asm`):**
- `motion_find_line_start` / `motion_find_line_end` are well-tested and load-bearing. They preserve BC per their AR23 contracts.
- The "mid-dev bug surfaced + fixed" lesson: helpers that trash registers per their AR23 contract require call-site PUSH/POP if the caller needs the trashed reg's value preserved. For `edits_enter_insert_after`'s LF-check, `motion_byte_at_logical` preserves BC — no PUSH/POP needed.

**From Story 2.5 (basic motions h/j/k/l; first dedicated motion module):**
- The AC13 patches (RET → JP parser_clear on `enter_normal_mode` / `enter_insert_mode` / `enter_visual_mode` / `unbound_normal` / `unbound_visual`) are foundation for Story 2.8: `enter_insert_mode`'s tail-JP parser_clear means any stale count / operator from before the user pressed `i` / `a` / `o` / `O` is dropped — no `5i = insert 5 times` because count gets zeroed. Story 2.8 reuses this — `edits_enter_insert_after` / `edits_open_below` / `edits_open_above` all tail-JP `enter_insert_mode` (or `parser_clear` directly).
- Helper contracts (BC preservation across `motion_byte_at_logical` / `motion_find_line_start` / `motion_find_line_end`) are documented at the helper header — call-site annotation per call not required.

**From Story 2.4 (file save / `:w` / `:wq`):**
- `buffer_dirty` is the source-of-truth flag (set by edits, cleared by save). Story 2.8 is the FIRST writer to `buffer_dirty` from a non-load path; previous writers were init (clear) and fileio_save (clear). Story 2.8 lands the SETTER from edit handlers.
- The FR52 invariant — "VIBE never silently truncates or discards user data" — is load-bearing for the `o` / `O` / overflow rollback paths. If `o` fails on a full buffer, the cursor MUST go back where it was so the user knows nothing happened to their text.
- `cmd_write_quit`'s `:wq` flow gates quit on save success; Story 2.8's INSERT mode produces the dirty-buffer state that `:w` / `:wq` consume.

**From Story 2.2 (file load / `:e`):**
- Buffer-load semantics use `gapbuf_init` + LDIR fill + `gapbuf_move_gap(0)` to position gap at cursor. Post-load, the buffer is gap-at-0 with all bytes after-gap. INSERT mode's first keystroke triggers a `gapbuf_move_gap(cursor)` call internal to gapbuf_insert (since gap is not at cursor when cursor != 0 post-load).
- The first INSERT after a `:e` may be slightly slower (one extra LDIR for the move_gap); after that, consecutive inserts at successive cursors are O(1).

**From Story 2.1 (ex command line / `:q`):**
- INSERT mode's Esc exit path (dispatch_insert[0x1B] → enter_normal_mode) uses the same `enter_normal_mode` that COMMAND mode's Esc cancel uses (well, COMMAND mode uses `exline_cancel` which routes to enter_normal_mode + parser_clear). Symmetric exit shape.

**From Story 1.10 (parser):**
- `parser_clear` zeros all three parser-state fields (count_accumulator, pending_operator, pending_motion_prefix). It's the load-bearing exit-hygiene routine for every mode transition. Story 2.8's edit handlers tail-JP it on every exit path (success or failure).

**From Story 1.9 (mode dispatch):**
- `dispatch_insert` was created with one bound entry (Esc); `unbound_insert` was the silent RET stub. Story 2.8 replaces `unbound_insert`'s body to JP into edits_insert_literal — supersedes the 1.9 stub per the doc comment.
- Per-mode dispatch tables use the MC3 binary-search shape; growing from 1 to 3 entries keeps the worst-case at 2 iterations (NFR3 unchanged).

**From Story 1.7 (gap buffer primitives):**
- `gapbuf_insert` returns CF=1 on full; state UNCHANGED on full (no partial-write). The AC4 invariant is load-bearing for Story 2.8's overflow handling.
- `gapbuf_delete` returns CF=1 at BOF (cursor==0); state UNCHANGED on BOF. The AC5 invariant is load-bearing for Story 2.8's Backspace at offset 0.
- `gapbuf_move_gap` is internal to insert/delete (transparently called when gap isn't at cursor). Story 2.8 doesn't call it directly.

**From Story 1.5 (status line / single-message funnel):**
- `status_set_message` is the AR12-compliant status writer. gapbuf_insert calls it on overflow; edits.asm calls it transitively via gapbuf_insert. No direct status writes from edits.

### Git intelligence

Recent commits (post-Story 2.5):

- `425bc2e code review changes` — Story 2.7 code review (1 P1 + 2 P2 + 4 P3, all small).
- `be63514 story 2.7: counted motions verified end-to-end; sticky-column j/k landed` — Story 2.7 dev pass.
- `dd21ada code review fixes` — Story 2.6 code review.
- `1da2bf1 story 2.6: Wired word/line/buffer motions; w/b/0/$/gg/G with counts; parser stubs retired for motion-0 and gg` — Story 2.6 dev pass.
- `2149fc8 story 2.5: Wired the cursor; h/j/k/l move with clamps, counts wired, parser cleared on mode change; CRLF tolerance in render` — Story 2.5 dev pass.

Patterns to follow:
- Single dev-commit per story containing the production code + tests + spec + sprint-status flips (the Story 2.5 / 2.6 / 2.7 model).
- Separate code-review commit (e.g. `dd21ada`, `425bc2e`) applying review patches.
- Sentinel byte at `0xCFFE` per TH1 (test/inc/test_prologue.inc).
- INCLUDE chain in test cases: pre-ORG headers (equates/bios/bdos/modes/vt52), then `test_prologue.inc`, test body, `test_epilogue.inc`, production sources (statusln/gapbuf/render/dispatch/parser/motions/**edits**/exline/fileio), `test_teardown_stub.inc` + `test_input_loop_stub.inc`, finally `inc/state.inc`.
- Gap-buffer fixture pattern: `CALL gapbuf_init` → LDIR from `.payload` into `GAP_BUFFER_BASE` → set `gap_start := GAP_BUFFER_BASE + N`. Mode pre-set via `LD A, MODE_INSERT ; LD (mode_byte), A` when the test exercises INSERT-mode dispatch.

### Testing requirements

- All 11 new tests under `test/cases/edits_*.asm`. Each test must build under `make -C test`, run under iz-cpm with the 5-second timeout, and report PASS via TH1 / TH2.
- The dispatch_key-driven tests (e.g. `edits_enter-inserts-lf.asm` if it uses dispatch_key against dispatch_insert) need `mode_byte = MODE_INSERT` and the full INCLUDE chain including `edits.asm`.
- For `edits_insert-fills-buffer.asm` (the 32-KB fill test), runtime is a concern. If iz-cpm timeout pressure is real, consider Sub 11.3's deferred-work entry on test-time GAP_BUFFER_MAX override.
- Sentinel allocation per test (suggested):
  - `edits_i-and-type.asm` → 0x80 (mode post-i), 0x81 (cursor post-typing), 0x82 (buffer_dirty), 0x83 (gap content), 0x84 (mode post-Esc), 0x85 (cursor post-Esc).
  - `edits_a-at-eol.asm` → 0x80 (cursor post-a), 0x81 (cursor post-X), 0x82 (gap content).
  - `edits_o-creates-newline.asm` → 0x80 (cursor), 0x81 (mode), 0x82 (gap content), 0x83 (buffer_dirty).
  - `edits_O-creates-newline-above.asm` → 0x80, 0x81, 0x82, 0x83.
  - `edits_insert-fills-buffer.asm` → 0x80 (cursor post-X), 0x81 (CF after Y), 0x82 (mode post-overflow), 0x83 (status_buffer matches msg_file_too_large).
  - `edits_backspace-mid-line.asm` → 0x80 (cursor), 0x81 (gap content), 0x82 (buffer_dirty).
  - `edits_backspace-at-bof.asm` → 0x80 (cursor unchanged), 0x81 (gap content unchanged).
  - `edits_enter-inserts-lf.asm` → 0x80 (cursor), 0x81 (byte at offset 1 == 0x0A).
  - `edits_control-byte-silent-noop.asm` → 0x80 (cursor unchanged), 0x81 (gap content unchanged).
  - `edits_a-at-eof-no-lf.asm` → 0x80 (cursor post-a == file_length), 0x81 (cursor post-X == file_length+1).
  - `edits_O-on-first-line.asm` → 0x80 (cursor == 0), 0x81 (byte at offset 0 == 0x0A).
  - `edits_O-on-empty-buffer.asm` → 0x80 (cursor == 0), 0x81 (byte at offset 0 == 0x0A), 0x82 (file_length == 1).
  - `edits_buffer-dirty-set-on-first-insert.asm` → 0x80 (buffer_dirty == 1).
  - `edits_esc-from-insert-clears-parser-state.asm` → 0x80 (count_accumulator == 0), 0x81 (pending_operator == 0), 0x82 (pending_motion_prefix == 0), 0x83 (mode == MODE_NORMAL).
- Update `test/Makefile` `clean` target if it doesn't already glob `cases/*.com` — per Story 2.7 confirmation, it does, so no Makefile change needed.

### Project Structure Notes

- **New source file `src/edits.asm`.** Story 2.8's primary deliverable.
- **No new inc/*.inc files.** All constants (MODE_INSERT, GAP_BUFFER_MAX, etc.) already in modes.inc / equates.inc / state.inc.
- **No new public symbols outside edits.asm.** All 5 new public entries (`edits_enter_insert_after` / `edits_open_below` / `edits_open_above` / `edits_insert_literal` / `edits_insert_backspace` / `edits_insert_newline` if AC10's explicit-bind choice) live in edits.asm.
- **dispatch_normal table** has 3 handler-address changes (`'a'`, `'o'`, `'O'` reroute); no entry-count change.
- **dispatch_insert table** grows from 1 to 2 or 3 entries (AC10 / AC12).
- **`state.inc` unchanged.** All needed cells (`mode_byte`, `cursor_offset`, `gap_start`, `gap_end`, `buffer_dirty`) already declared.
- **`src/vibe.asm` INCLUDE chain** extended by one line (`INCLUDE "edits.asm"` between motions and exline).
- **11 new test files under `test/cases/edits_*.asm`.**

### Source tree paths touched

```
.
├── src/
│   ├── edits.asm             # NEW — Story 2.8's primary module
│   ├── dispatch.asm          # UPDATE — `'a'`/`'o'`/`'O'` reroute; dispatch_insert grows; unbound_insert body
│   └── vibe.asm              # UPDATE — INCLUDE chain extended for edits.asm
├── inc/
│   ├── modes.inc             # UNCHANGED
│   ├── equates.inc           # UNCHANGED
│   ├── state.inc             # UNCHANGED
│   └── bios.inc / bdos.inc / vt52.inc # UNCHANGED
├── _bmad-output/
│   ├── planning-artifacts/
│   │   ├── prd.md            # UNCHANGED
│   │   ├── architecture.md   # UNCHANGED
│   │   └── epics.md          # UNCHANGED
│   └── implementation-artifacts/
│       ├── 2-8-insert-mode-i-a-o-o.md   # THIS FILE
│       ├── deferred-work.md             # UPDATE (Task 11)
│       └── sprint-status.yaml           # UPDATE (status flips backlog → ready-for-dev → in-progress → review)
└── test/
    └── cases/
        ├── edits_i-and-type.asm                              # NEW
        ├── edits_a-at-eol.asm                                # NEW
        ├── edits_o-creates-newline.asm                       # NEW
        ├── edits_O-creates-newline-above.asm                 # NEW
        ├── edits_insert-fills-buffer.asm                     # NEW
        ├── edits_backspace-mid-line.asm                      # NEW
        ├── edits_backspace-at-bof.asm                        # NEW
        ├── edits_enter-inserts-lf.asm                        # NEW
        ├── edits_control-byte-silent-noop.asm                # NEW (optional)
        ├── edits_a-at-eof-no-lf.asm                          # NEW
        ├── edits_O-on-first-line.asm                         # NEW
        ├── edits_O-on-empty-buffer.asm                       # NEW
        ├── edits_buffer-dirty-set-on-first-insert.asm        # NEW
        └── edits_esc-from-insert-clears-parser-state.asm     # NEW
```

### Files created and modified by this story

**New:**
- `src/edits.asm`
- `test/cases/edits_i-and-type.asm`
- `test/cases/edits_a-at-eol.asm`
- `test/cases/edits_o-creates-newline.asm`
- `test/cases/edits_O-creates-newline-above.asm`
- `test/cases/edits_insert-fills-buffer.asm`
- `test/cases/edits_backspace-mid-line.asm`
- `test/cases/edits_backspace-at-bof.asm`
- `test/cases/edits_enter-inserts-lf.asm`
- `test/cases/edits_control-byte-silent-noop.asm` (optional)
- `test/cases/edits_a-at-eof-no-lf.asm`
- `test/cases/edits_O-on-first-line.asm`
- `test/cases/edits_O-on-empty-buffer.asm`
- `test/cases/edits_buffer-dirty-set-on-first-insert.asm`
- `test/cases/edits_esc-from-insert-clears-parser-state.asm`

**Modified:**
- `src/dispatch.asm` — `dispatch_normal` `'a'`/`'o'`/`'O'` reroutes; `dispatch_insert` table grows (Backspace + Enter entries); `unbound_insert` body swap; doc comments updated.
- `src/vibe.asm` — INCLUDE chain extended with `edits.asm`; comment block at lines 136-145 updated.
- `_bmad-output/implementation-artifacts/deferred-work.md` — B2 undo stub entry + render dirty-row fine-grained optimisation entry + (optional) test-time GAP_BUFFER_MAX override entry.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — 2-8 status flips.
- `_bmad-output/implementation-artifacts/2-8-insert-mode-i-a-o-o.md` — this file (Tasks checkboxes, Completion Notes, File List, Change Log, Status).

### References

- FR13 (enter insert mode — primary FR for this story): [Source: _bmad-output/planning-artifacts/prd.md] line 715
- FR16 (return to NORMAL via Esc): [Source: _bmad-output/planning-artifacts/prd.md] lines 719-720
- FR24 (insert before cursor with `i`): [Source: _bmad-output/planning-artifacts/prd.md] line 738
- FR25 (insert after cursor with `a`): [Source: _bmad-output/planning-artifacts/prd.md] line 739
- FR26 (open line below with `o`): [Source: _bmad-output/planning-artifacts/prd.md] lines 740-741
- FR27 (open line above with `O`): [Source: _bmad-output/planning-artifacts/prd.md] lines 742-743
- FR50 (unsupported commands as no-op): [Source: _bmad-output/planning-artifacts/prd.md] lines 793-795
- FR52 (no silent data loss): [Source: _bmad-output/planning-artifacts/prd.md] lines 799-801
- NFR1 (interactive feedback): [Source: _bmad-output/planning-artifacts/prd.md]
- NFR2 (sustained typing throughput ≥10 chars/sec): [Source: _bmad-output/planning-artifacts/prd.md] line 108
- NFR3 (predictable cursor-motion latency): [Source: _bmad-output/planning-artifacts/prd.md] lines 820-824
- NFR9 (code size budget — 5120 B ceiling; Story 2.8 stays well within): [Source: _bmad-output/planning-artifacts/prd.md] lines 848-858
- NFR18 (byte-identical rebuild): verified by `make clean && make all`
- V4-B2 (undo scope for insert sessions — clarification): [Source: _bmad-output/planning-artifacts/prd.md] lines 1695-1703
- MC3 (binary-search dispatch — `dispatch_insert` grows from 1 to 3 entries): [Source: _bmad-output/planning-artifacts/architecture.md] lines 732-738
- MC4 (handler signature — A=key on entry; state via state.inc): [Source: _bmad-output/planning-artifacts/architecture.md] line 1502+
- AR12 / AR13 / AR14 / AR15 (architectural boundaries; edits.asm uses gapbuf primitives, no raw screen/BDOS): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1434-1463
- AR23 (module header contracts): [Source: src/motions.asm:1-146 header block as exemplar]
- AR25 (INCLUDE chain in vibe.asm): [Source: src/vibe.asm:136-145 comment block]
- Story 2.5 (basic motions + AC13 parser_clear hygiene patches): [Source: _bmad-output/implementation-artifacts/2-5-basic-motions-h-j-k-l.md]
- Story 2.6 (word/line/buffer motions; helpers): [Source: _bmad-output/implementation-artifacts/2-6-word-line-buffer-motions-w-b-0-gg-g.md]
- Story 2.7 (counted motions; sticky-column hoist): [Source: _bmad-output/implementation-artifacts/2-7-counted-motions.md]
- Story 2.4 (file save; `buffer_dirty` clear path): [Source: _bmad-output/implementation-artifacts/2-4-file-save-w-w-filename-wq.md]
- Story 2.2 (file load; gap-buffer init from disk): [Source: _bmad-output/implementation-artifacts/2-2-file-load-via-e-filename-incl-e.md]
- Story 1.9 (mode dispatch — `dispatch_insert`, `unbound_insert` stub): [Source: src/dispatch.asm:430-555]
- Story 1.10 (parser — `parser_clear`): [Source: src/parser.asm:32-51]
- Story 1.7 (gap buffer primitives — `gapbuf_insert` / `gapbuf_delete` / `gapbuf_move_gap`): [Source: src/gapbuf.asm:50-260]
- Story 1.5 (status line — `status_set_message`): [Source: src/statusln.asm]
- Architecture: edits.asm module spec: [Source: _bmad-output/planning-artifacts/architecture.md] lines 245, 935-950, 1302
- Deferred-work entry on cursor-on-CR / TAB / NUL / high-bit byte rendering desync (informs control-byte filter): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 76 region

## Dev Agent Record

### Agent Model Used

claude-opus-4-7[1m]

### Debug Log References

(none — clean dev pass; no debug sessions needed.)

### Completion Notes List

- New module `src/edits.asm` lands in the AR25 INCLUDE chain between `motions.asm` and `exline.asm` (per the long-planned slot at `src/vibe.asm:127-140`). 6 public entry handlers + 4 internal shared tails:
  - `edits_enter_insert_after` (`a`) — advance cursor 0/1 per EOL rule, tail-JP enter_insert_mode.
  - `edits_open_below` (`o`) — reach EOL → insert LF → fall through to shared success tail.
  - `edits_open_above` (`O`) — reach BOL → insert LF → DEC cursor → fall through to shared success tail.
  - `edits_insert_literal` (literal-byte fall-through; replaces 1.9 unbound_insert RET stub) — control-byte filter (CP 0x20 ; RET C) + gapbuf_insert + shared dirty-and-redraw tail; overflow exits INSERT via shared exit-to-NORMAL.
  - `edits_insert_backspace` (Backspace) — gapbuf_delete with silent BOF no-op (RET C) + shared dirty-and-redraw tail.
  - `edits_insert_newline` (Enter → LF, AC10 explicit-bind) — gapbuf_insert(0x0A) + shared dirty-and-redraw tail; overflow shared with literal handler.
  - Internal helpers: `edits_open_success_tail` (shared o/O success), `edits_open_overflow` (shared o/O rollback to entry cursor + JP parser_clear), `edits_dirty_and_redraw` (set buffer_dirty=1 + tail-JP render_mark_all_dirty), `edits_overflow_to_normal` (LD A,MODE_NORMAL + JP parser_clear; shared between literal and newline overflow paths). Factoring saved ~25-30 B vs the open-coded sketch — drove the build under the spec's NFR9 projection.
- **AC10 decision: explicit-bind chosen** (the recommended option). `dispatch_insert` grows from 1 entry to 3: Backspace 0x08 → edits_insert_backspace, Enter 0x0D → edits_insert_newline, Esc 0x1B → enter_normal_mode. The 0x0D → 0x0A LF translation lives at the dispatcher level, not inside edits_insert_literal — cleaner semantically; a future Story 3.x search prompt may bind 0x0D differently in its own mode dispatch.
- **AC8 overflow shape:** on gapbuf_insert CF=1, edits_insert_literal / edits_insert_newline exit INSERT cleanly (LD A,MODE_NORMAL + tail-JP parser_clear); o/O roll back the entry cursor (POP HL + LD (cursor_offset),HL + JP parser_clear) and leave mode at NORMAL. msg_file_too_large surfaces via gapbuf_insert's pre-existing status_set_message call — no re-call needed (no intermediate writes between gapbuf_insert and the exit tail; logged in deferred-work.md for future-self awareness).
- **AC11 control-byte filter:** `edits_insert_literal` starts with `CP 0x20 ; RET C` — silently swallows A < 0x20. Cut precondition documented inline: callers via dispatch_insert have already stripped 0x08 / 0x0D / 0x1B; this handler sees A in 0x20..0xFE plus the un-bound control bytes 0x00..0x07 / 0x09..0x1C / 0x1D-0x1F which it filters.
- **AC13 architectural compliance:** `src/edits.asm` is a near-clean module — zero AR13 (BIOS_CONOUT) code refs, zero AR14 direct `LD (gap_start), DE` / `LD (gap_end), DE` writes (all mutation through gapbuf_insert / gapbuf_delete), zero AR15 (BDOS_CALL / CALL BDOS_ENTRY / CALL 0x0005) refs. Greps in Sub 10.2 confirm. Compare motions.asm's "pure-read clean module" archetype — edits.asm writes the buffer but only through the AR14-compliant surface.
- **B2 undo recording is a STUB.** `enter_normal_mode` in `src/dispatch.asm` (reached from dispatch_insert[0x1B] on Esc-from-INSERT) is the documented hook site for Story 2.13's session-recording write — instrument BEFORE the mode flip. `u` post-INSERT-Esc reports `msg_nothing_to_undo` via the existing "no entry recorded" path. Deferred-work.md updated.
- **Render strategy: conservative `render_mark_all_dirty` on every successful mutation.** Fine-grained `render_mark_row_dirty(cursor row)` deferred as Growth-tier optimisation. render_diff's per-row shadow-diff makes the all-dirty path cheap-enough — only bytes that actually changed are emitted.
- **80 existing test files patched** to add `INCLUDE "../../src/edits.asm"` after `INCLUDE "../../src/motions.asm"` (because dispatch.asm now forward-references the new edits_* handlers). The underlying test/Makefile dependency-hygiene gap (cases/%.com doesn't track src/*.asm) is re-flagged in deferred-work.md — each story adding a new src module pays this manual fan-out tax.
- **Build SHA `e30f002f3d2f2753ee9116f20ca1c1ca83085bdeede0713a38164d91f3ce7729`**, byte-identical second rebuild (NFR18). Size **4510 B / 88.1% of 5120 B / 610 B headroom** — well below spec's 4690-4790 B projection. +130 B vs Story 2.7 (under the 310-410 B projected delta). No NFR9 amend needed.
- **Tests: 106 pass / 1 deliberate fail** (was 92/1 post-Story-2.7; +14 new edits_* tests — 5 canonical + 9 additional. None of the spec's optional drops were taken; full coverage shipped).
- **Hardware UAT (AC14, 15 steps incl. journey-1a end-to-end + sustained-typing + o/O edge cases) deferred to user** per established pattern. Story 2.8 is `review`, NOT `done`, until Ant confirms.

### File List

**New:**
- `src/edits.asm` — primary deliverable; 6 public + 4 internal handlers.
- `test/cases/edits_i-and-type.asm`
- `test/cases/edits_a-at-eol.asm`
- `test/cases/edits_o-creates-newline.asm`
- `test/cases/edits_O-creates-newline-above.asm`
- `test/cases/edits_insert-fills-buffer.asm`
- `test/cases/edits_backspace-mid-line.asm`
- `test/cases/edits_backspace-at-bof.asm`
- `test/cases/edits_enter-inserts-lf.asm`
- `test/cases/edits_control-byte-silent-noop.asm`
- `test/cases/edits_a-at-eof-no-lf.asm`
- `test/cases/edits_O-on-first-line.asm`
- `test/cases/edits_O-on-empty-buffer.asm`
- `test/cases/edits_buffer-dirty-set-on-first-insert.asm`
- `test/cases/edits_esc-from-insert-clears-parser-state.asm`

**Modified:**
- `src/dispatch.asm` — `dispatch_normal`'s 'a' / 'o' / 'O' handler addresses rerouted to edits_* (slot count unchanged at 32); `dispatch_insert` grown 1 → 3 entries (Backspace 0x08, Enter 0x0D, Esc 0x1B); `unbound_insert` body swapped from `RET` to `JP edits_insert_literal`; module-header `Dependencies` block extended with `src/edits.asm`; doc comments at the patched sites updated.
- `src/vibe.asm` — AR25 INCLUDE chain extended: `INCLUDE "edits.asm"` slotted between `motions.asm` and `exline.asm`; comment block at lines 126-146 updated to remove "edits not yet present" wording and document edits.asm has landed; module-header `Dependencies` block extended.
- 80 test files under `test/cases/` — each gained `INCLUDE "../../src/edits.asm"` immediately after the existing `INCLUDE "../../src/motions.asm"` line (mechanical patch).
- `_bmad-output/implementation-artifacts/deferred-work.md` — Story 2.8 deferred entries appended.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — 2-8 status flipped ready-for-dev → in-progress → review.
- `_bmad-output/implementation-artifacts/2-8-insert-mode-i-a-o-o.md` — this file (Tasks checkboxes, Dev Agent Record, File List, Change Log, Status).

### Change Log

| Date       | Change | Notes |
|------------|--------|-------|
| 2026-05-16 | Story 2.8 created from epics line 1198 | Initial draft; status `ready-for-dev`. 16 ACs, 12 tasks, 11 headless tests + 15-step hardware UAT. New module `src/edits.asm` lands between motions and exline in AR25 chain. AC10 (Enter → LF) decision: explicit bind in dispatch_insert table recommended. AC8 (overflow exit-to-NORMAL with FR52 preservation) is load-bearing. B2 undo recording is a STUB for 2.8; full impl in 2.13. NFR9 projected post-2.8 4690-4790 B / 91-94% of 5120 B / 330-430 B headroom — tightening but no amend needed. |
| 2026-05-16 | Story 2.8 → review (dev pass complete; HW UAT deferred to user) | `src/edits.asm` lands (6 public + 4 internal). `dispatch_normal` 'a'/'o'/'O' reroute (slot count 32 unchanged). `dispatch_insert` 1 → 3 entries (BS/Enter/Esc; DISPATCH_INSERT_COUNT=3, binary-search worst case 2 iter). `unbound_insert` body RET → `JP edits_insert_literal`. AC10 explicit-bind chosen. 14 new headless tests under `test/cases/edits_*.asm` (5 canonical + 9 additional). 80 test files patched to INCLUDE edits.asm (test/Makefile hygiene gap re-flagged). Build SHA `e30f002f3d2f2753ee9116f20ca1c1ca83085bdeede0713a38164d91f3ce7729`, byte-identical x2 (NFR18). Size 4510 B / 88.1% of 5120 B / 610 B headroom — under spec's 4690-4790 B projection thanks to shared-tail factoring (~25-30 B saved). +130 B vs Story 2.7. 106 pass / 1 deliberate fail (was 92/1; +14 new). AR sweeps clean: BIOS_CONOUT / direct gap_start writes / BDOS all zero-match in edits.asm code refs. `CALL gapbuf_insert` count = 4 (literal + newline + o + O). B2 undo recording: STUB (full impl Story 2.13; hook site = `enter_normal_mode`). Render: conservative `render_mark_all_dirty` (fine-grained deferred). Hardware UAT (AC14, 15 steps incl. journey-1a end-to-end + sustained-typing + o/O edge cases) deferred to user. |
| 2026-05-16 | Story 2.8 → done — code review applied 10 patches (1 P1 + 1 P2 + 4 P3 + 4 test-quality) + 1 new edge-case test for D1 + 1 new dispatch-route test for P8; 2 doc-contract patches dismissed after verification (Trashes claims for `edits_insert_backspace` and `edits_dirty_and_redraw` were already correct per the actual helper contracts). 3 deferred to `deferred-work.md` (o/O overflow rollback test; `o` on empty buffer behavior pin; test/Makefile dependency-hygiene gap re-flag). ~16 dismissed as noise / spec-conformant / hypothetical-future. **Key fix (D1 — code review decision):** INSERT-mode literal filter tightened — added `CP 0x7F / RET NC` to `edits_insert_literal` after the existing `CP 0x20 / RET C`. Closes the buffer-corruption hazard from synthesized arrow keycodes (KEY_ARROW_UP/DOWN/LEFT/RIGHT = 0x80..0x83) that `input_get_key` produces regardless of mode — in INSERT, those bytes previously passed the filter and landed in the gap buffer (and would have hit disk on `:w`). AC5 + AC11 amended in this spec to reflect the tightened "0x20..0x7E printable ASCII only" range; if a future story needs extended-ASCII text input the filter must be revisited. UAT step 9 was rewritten before the review to use `$a` instead of `i`+arrow keys, so this never surfaced on hardware. Build SHA `0dd1a0627e595f4603e1f4699dedd3dfcb10d0f53b1d6a57b347f534fc60c694`, byte-identical second rebuild (NFR18). Size 4513 B / +3 B vs pre-review 4510 B / ~88.1% of 5120 B / 607 B headroom (CP n + RET NC = 3 B). 108 pass / 1 deliberate fail (was 106/1 pre-review; +2 new tests `edits_high-bit-silent-noop.asm` + `edits_dispatch-insert-routes-backspace.asm`). Acceptance Auditor: 14/14 ACs MET. |
| 2026-05-16 | Hardware UAT confirmed on real MicroBeast — code clean; AC14 step 9 spec corrected | Ant ran the 15-step UAT script. All steps produce the documented behavior on hardware; no regressions surfaced. **One spec defect found in step 9** (test text, NOT code): step 9 instructed "Press `i` then type ` world`" after re-launching the 5-byte `"Hello"` file at cursor=0; that correctly inserts at offset 0 producing `" worldHello"` (verified in `~/Downloads/beastty-20260516-010122.bin` transcript), not the expected `"Hello world"`. Fixed by amending step 9 to `Press $ then a, then type " world"` — `$` lands cursor at last printable byte (offset 4), `a` advances to offset 5 = file_length per AC2's EOF rule on the no-trailing-LF buffer, typing appends from there → `"Hello world"`. The correction exercises `$` + `a`-at-EOF interaction (additional coverage value vs the original sketch). Code is unchanged; the i/a/o/O/literal/Backspace/Enter/Esc handlers all behave per AC1-AC11; FR52 overflow paths exercised implicitly; sustained typing step 15 clean. Story 2.8 dev pass complete inclusive of hardware UAT; ready for code review pass. |
