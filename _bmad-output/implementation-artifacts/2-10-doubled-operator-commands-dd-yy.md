# Story 2.10: Doubled-operator commands (dd, yy)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `dd` to delete the current line (with the deleted text captured in the yank register) and `yy` to yank (copy) the current line into the yank register,
so that FR29 + FR31 are realized as the first **line-granularity** edit operations — wiring the parser's already-built doubled-operator detection ([[story-1-10-parser]]) to the SR6 yank-register protocol for the very first time, and laying the line-bounds + yank-copy + range-delete infrastructure that Story 2.11 (composed `dw` / `d$` / `c5w` / `y3j`) and Story 2.12 (`p` paste-back) build on.

## Acceptance Criteria

**AC1 — Parser-side `parser_doubled_operator_stub` is replaced by a real dispatcher.**

The Story-1.10 stub `parser_doubled_operator_stub` (currently surfaces `msg_not_implemented` then tail-JPs `parser_clear`) is **replaced** with a real dispatcher routine. The replacement either keeps the existing public symbol name (rewriting the body in-place; preferred for AR25 INCLUDE-chain stability) OR renames it to `parser_doubled_operator` and adds a one-line back-compat note in the parser.asm module header — implementation choice with the chosen path documented in the dev pass.

The replacement reads `pending_operator` (the byte stashed by the first `parser_handle_operator` call — see src/parser.asm:317-338) and branches:

- `'d'` → JP `op_dd`
- `'y'` → JP `op_yy`
- `'c'` / `'>'` / `'<'` → JP `msg_not_implemented` surface (existing pre-2.10 shape — Story 2.11 lands `>>` / `<<` real; `cc` is out of MVP scope per [[story-2-13-undo]] / PRD §V4-B2)

**Critical state-read-before-clear discipline** (per deferred-work.md:93-94 heads-up flagged on the Story-1.10 review): `op_dd` and `op_yy` MUST read `count_accumulator` (via `motion_apply_count`) AND `pending_operator` (already in scope from the dispatch chain) BEFORE any tail-JP to `parser_clear`. A consistency-cleanup that "factored the clear into a common prelude" would silently break `5dd` (count would be 0 by the time the handler tried to use it) — same shape as the Story 2.6 `motion_gg` resolution. Document the constraint at each handler's contract block per AR23.

**AC2 — `op_dd` (delete-line) — single-line case.**

**Given** I'm in NORMAL mode with cursor at logical offset C, `count_accumulator == 0` (or 1 after `motion_apply_count` defaulting), and the buffer contains a representative multi-line file (e.g. `"abc\ndef\nghi"` 11 B with cursor in line 1 — between 0 and 2 inclusive)
**When** the doubled-operator dispatch routes to `op_dd`
**Then** the line-bounds for the cursor's current line are computed:
- `S = motion_find_line_start(C)` — offset of first byte of current line (byte just past prior LF, or 0).
- `E = motion_find_line_end(C)` — offset of next LF, or `file_length` if no LF before EOF.
- **Standard case** (`E < file_length`; line has a trailing LF): the delete range is `[S, E + 1)` — that's the line content + its trailing LF. Total bytes = `(E + 1) - S`.
- **Last-line-no-trailing-LF case** (`E == file_length`):
  - If `S > 0`: the delete range is `[S - 1, file_length)` — that's the *prior* line's LF + the current line. Total bytes = `file_length - S + 1`. (vi convention: dd on the last line consumes the LF that joined it to the previous line so the line count truly drops by 1.)
  - If `S == 0` (single-line buffer, no LF): the delete range is `[0, file_length)`. Total bytes = `file_length`. Buffer becomes empty.

**And** the deleted bytes are copied into the yank register at `yank_buffer` BEFORE the delete (so the source bytes are still in the gap buffer at their pre-delete positions — see AC8 for the order rationale):
- `yank_kind := KIND_LINE` (the new equate from AC10).
- `yank_length := total_bytes` (the byte count from the range computation above).
- The `total_bytes` are copied verbatim into `yank_buffer` (the SR6 reserved-pool address declared at `state.inc:132` as `GAP_BUFFER_BASE + GAP_BUFFER_MAX`).
- **If `total_bytes > YANK_BUFFER_SIZE` (1024)**: yank register is **NOT** updated (`yank_kind`, `yank_length`, `yank_buffer` all unchanged from their prior values — earlier yank preserved per SR6 "predictable failure mode > silent truncation"). `status_set_message` surfaces `msg_yank_too_large` (the new string from AC10). **The deletion still proceeds** (per epic AC: "dd still proceeds with the deletion" on yank refusal). The user loses the line content but is told immediately via the status line. For NFR9 economy the over-capacity check is a single `LD HL, total_bytes; LD DE, YANK_BUFFER_SIZE + 1; SBC HL, DE; JR NC, .yank_skip` shape (~9 B).

**And** the bytes in `[delete_start, delete_end)` are removed from the gap buffer (see AC8 for the multi-byte range-delete shape).

**And** post-delete cursor placement (per epic AC: "the cursor lands on the start of what is now the line at the same logical position (or last line if the deleted line was last)"):
- If new `file_length == 0` (buffer empty): cursor at 0.
- Else if `delete_start < new_file_length`: cursor at `delete_start` (the position that, post-shift, is the start of what used to be the next line — now occupying the deleted line's slot). For the standard `[S, E+1)` case `delete_start = S` and the next line's first byte slides into offset S.
- Else (deleted to file end, no following line, AND there's still content above): cursor at `motion_find_line_start(new_file_length - 1)` — the start of the new last line. This case happens when last-line dd was performed on a buffer with prior lines.

**And** `buffer_dirty := 1` (idempotent — write 1 regardless of prior value, matching Story 2.8 / 2.9 simpler-is-cleaner rationale).
**And** `render_mark_all_dirty` is called (conservative shape — a line delete shifts every subsequent row's content; mark-all is correct and ~5 B cheaper than fine-grained marking).
**And** parser state is zeroed via the tail-JP `parser_clear` (count + pending_operator + pending_motion_prefix all 0).

**AC3 — `op_dd` (delete-line) — counted form `Ndd` (e.g. `3dd`, `5dd`, `100dd`).**

**Given** I'm in NORMAL mode with `count_accumulator = N` (N >= 1 after motion_apply_count defaulting; the first 'd' arrives and the second 'd' triggers the doubled-op dispatch — `count_accumulator` is still set because parser_handle_operator preserves count across the operator press per src/parser.asm:334-337's `.first_operator` arm)
**When** the doubled-operator dispatch routes to `op_dd`
**Then** the line-bounds for N consecutive lines starting at the cursor's current line are computed:
- `S = motion_find_line_start(C)` — start of current line.
- Walk forward N line-ends:
  - Initialise `walker = S`.
  - For `k = 1..N`:
    - `E_k = motion_find_line_end(walker)`.
    - If `E_k == file_length` (this is the LAST line; no trailing LF; BH2-clamp triggers): exit the walk with `lines_walked = k`, `last_line_end = file_length`, `last_line_was_eof = true`.
    - Else (E_k < file_length): set `walker = E_k + 1` (advance past the LF to the next line's first byte); record `last_line_end = E_k`. Continue.
  - At loop exit: `lines_walked` ∈ [1, N], `last_line_end` ∈ [E_1, file_length].
- **Delete range:**
  - If `last_line_was_eof == true` (we hit the no-trailing-LF last line during the walk):
    - If `S > 0`: range is `[S - 1, file_length)` — consume the leading LF + all N (or fewer) lines.
    - Else (S == 0): range is `[0, file_length)`. Buffer becomes empty.
  - Else (full N lines walked, each ended in LF): range is `[S, last_line_end + 1)` — the N lines + their N trailing LFs.
- Total bytes = `delete_end - delete_start`.

**And** the same yank-copy + capacity-refusal logic from AC2 applies — copy `total_bytes` to `yank_buffer` with `yank_kind = KIND_LINE`, `yank_length = total_bytes`. If `total_bytes > 1024`, yank refused + status set + deletion still proceeds.

**And** the multi-byte range-delete is executed (see AC8).

**And** post-delete cursor placement: same shape as AC2 — `delete_start` if it's < new file_length; else start of new last line; else 0 on empty buffer.

**And** `buffer_dirty := 1`; render_mark_all_dirty; parser_clear.

**Trace `3dd` on `"a\nb\nc\nd\ne"` (9 B), cursor=0:**
- S = 0; walker=0. Iter 1: E_1 = motion_find_line_end(0) = 1 (LF at offset 1). walker = 2; last_line_end = 1. Iter 2: E_2 = motion_find_line_end(2) = 3. walker = 4; last_line_end = 3. Iter 3: E_3 = motion_find_line_end(4) = 5. walker = 6; last_line_end = 5. lines_walked = 3; last_line_was_eof = false. Delete range = [0, 5 + 1) = [0, 6). Total bytes = 6 ("a\nb\nc\n").
- yank: KIND_LINE, length 6, content "a\nb\nc\n". Within capacity.
- Post-delete buffer: "d\ne" (3 B). Cursor: delete_start=0 < new_file_length=3 → cursor=0.

**Trace `5dd` on `"a\nb\nc"` (5 B; LAST line "c" has no trailing LF), cursor=0:**
- S = 0; walker=0. Iter 1: E_1 = 1. walker=2; last_line_end=1. Iter 2: E_2 = 3. walker=4; last_line_end=3. Iter 3: E_3 = motion_find_line_end(4) = 5 (file_length — no LF). last_line_was_eof = true; lines_walked = 3. Walk exits early (count 5 not exhausted).
- Last-line-no-LF + S=0 case: delete range = [0, 5). Total bytes = 5 ("a\nb\nc"). yank within capacity.
- Post-delete buffer: empty. Cursor=0.

**Trace `3dd` on `"a\nb\nc"` (5 B), cursor=2 (line 2, on 'b'):**
- S = motion_find_line_start(2) = 2 (after first LF). walker=2. Iter 1: E_1 = 3. walker=4; last_line_end=3. Iter 2: E_2 = 5 (file_length). last_line_was_eof = true; lines_walked = 2.
- last_line_was_eof + S > 0: delete range = [S - 1, file_length) = [1, 5). Total bytes = 4 ("\nb\nc"). yank length = 4, KIND_LINE.
- Post-delete buffer: "a" (1 B). Cursor: delete_start = 1; new_file_length = 1; 1 < 1 is false → fall to "find start of new last line": motion_find_line_start(0) = 0. Cursor = 0.

**AC4 — `op_yy` (yank-line) — single-line case.**

**Given** I'm in NORMAL mode with cursor at offset C, `count_accumulator == 0` (defaults to 1)
**When** the doubled-operator dispatch routes to `op_yy`
**Then** the line-bounds for the cursor's current line are computed identically to AC2 (`S`, `E`, and the last-line-no-LF adjustment). The yank-target range is the SAME range that `op_dd` would delete (so `dd` then `p` and `yy` then `p` produce identical paste content — vi muscle memory invariant).
**And** yank-copy is attempted with the same capacity-refusal protocol:
- If `total_bytes <= YANK_BUFFER_SIZE`: `yank_kind := KIND_LINE`; `yank_length := total_bytes`; bytes copied to `yank_buffer`. Status unchanged (silent success — yy is a read-only op).
- If `total_bytes > YANK_BUFFER_SIZE`: yank register **NOT** updated (yank_kind / yank_length / yank_buffer unchanged); `status_set_message msg_yank_too_large`. **Buffer is NOT modified** (yy is a read-only op; no deletion to "still proceed" with). The user gets the status banner; the prior yank is preserved.
**And** `buffer_dirty` is **NOT** touched (yy never mutates the buffer).
**And** dirty rows are **NOT** marked (no visible change).
**And** parser state is zeroed via tail-JP `parser_clear`.

**AC5 — `op_yy` (yank-line) — counted form `Nyy` (e.g. `3yy`, `5yy`).**

Same shape as AC3's `Ndd` line-bounds walk for finding the N-line range, but the operation is yank-only (no deletion):
- Compute the same `[delete_start, delete_end)` range that `Ndd` would compute.
- Attempt yank-copy with capacity refusal (per AC4).
- Buffer + cursor + buffer_dirty all UNCHANGED on both success and refusal paths.
- Parser state zeroed.

**Trace `3yy` on `"a\nb\nc\nd"` (7 B; last line no LF), cursor=0:**
- S = 0. Walk: iter 1: E_1=1; iter 2: E_2=3; iter 3: E_3 = motion_find_line_end(4) = 5. walker=6 (no last_line_was_eof — E_3=5 < file_length=7). Hmm wait, "c\nd" — let me recompute. Buffer `"a\nb\nc\nd"` = bytes [a, \n, b, \n, c, \n, d]; file_length = 7. motion_find_line_end(0) walks for LF: finds LF at offset 1 (E_1=1). motion_find_line_end(2): LF at offset 3 (E_2=3). motion_find_line_end(4): LF at offset 5 (E_3=5). walker=6; last_line_end=5; lines_walked=3.
- Wait — iter 3 finds LF at 5; walker advances to 6 (start of "d"); count exhausted at iter 3. last_line_was_eof = false.
- Range = [S, last_line_end + 1) = [0, 6). Total bytes = 6 ("a\nb\nc\n").
- yank: KIND_LINE, length 6, content "a\nb\nc\n". Buffer unchanged.
- Cursor unchanged (=0). buffer_dirty unchanged.

**Trace `5yy` on `"a"` (1 B; single line no LF), cursor=0:**
- S=0; walker=0. Iter 1: E_1 = motion_find_line_end(0) = 1 (file_length — no LF). last_line_was_eof=true. lines_walked=1.
- Range: last_line_was_eof + S=0 → [0, 1). Total bytes = 1.
- yank: KIND_LINE, length 1, content "a". Buffer unchanged. (vi: yy on a single-char no-LF line yanks just that char as a "line" — the kind is LINE for paste semantics, even though content has no LF.)

**AC6 — Undo recording is a STUB for Story 2.10 (full impl in [[story-2-13-undo]]).**

Per epic spec line 1321-1323: "dd records an inverse (re-insert) entry in `undo_buffer` (subject to undo capacity refusal in 2.13); yy does not record".

For Story 2.10 the recording is a **STUB**:
- `op_dd` does NOT write to `undo_buffer`. The hook site for Story 2.13 is at `op_dd`'s "post yank-copy, pre-range-delete" position — Story 2.13 will insert an `undo_record(KIND_DELETE, delete_start, total_bytes, deleted_bytes_ptr)` call there (matching the shape Story 2.13 will introduce). The hook position MUST be documented in `op_dd`'s contract block per AR23 + in deferred-work.md (Task 7 housekeeping below).
- `op_yy` does NOT and will NEVER record undo (yank-only; no buffer mutation = nothing to undo).
- `u` post-`dd` reports `msg_nothing_to_undo` via the existing capacity-refusal path (statusln.asm region near `msg_nothing_to_undo`). Same shape as Story 2.8 INSERT-Esc and Story 2.9 `x` deferrals.

This matches the established stub-pattern from [[story-2-8-insert-mode]] (B2) and [[story-2-9-single-character-delete-x]] (FR45). Document the stub explicitly in the change log AND in deferred-work.md so Story 2.13's dev knows the hook site.

**AC7 — Hardware UAT on real MicroBeast (deferred to user; same pattern as Stories 2.1-2.9).**

The dev MUST NOT mark this story `done` without confirmed hardware UAT by Ant. The dev pass produces `:wq`-ready code; the user (Ant) runs `make push` and steps through the UAT script.

Hardware UAT script (13 steps):

1. **Pre-state:** boot fresh, no prior `vibe` invocation this session.
2. **`vibe newgame.fs`** with the file from Story 2.9 step 12 if it survived (otherwise any pre-existing multi-line file). Status confirms `loaded` count, mode `-- normal --`, cursor at offset 0.
3. **Navigate to a line you don't mind losing.** Press `j j j` (or whatever count puts you on line 4 of the file). Confirm cursor is on a representative source line (visible printable content).
4. **Press `dd`** — that line vanishes; the line that was below it slides up into the deleted line's row position; cursor lands at the start of that newly-arrived line. On-screen: rows from cursor row down shift up by 1; the bottom of the screen either pulls in a previously-off-screen line OR shows a `~` empty-line marker (if the file shrank into the visible region). Status confirms no error.
5. **Press `dd` again** — same shape; another line vanishes. Confirm cursor still at start of the now-top-of-cursor-row line.
6. **Press `3dd`** — three more lines deleted in one keystroke. Confirm cursor lands sensibly; status confirms no error.
7. **Press `o`** (Story 2.8) to open a NEW empty line below cursor; press Esc; press `yy` — the empty line is yanked. Confirm no visible buffer change. Status unchanged (silent yank success).
8. **Press `j` to move down one line, then `dd`** — confirm normal-line dd still works after a yy.
9. **Press `:w`** — file saves; status confirms bytes written and `buffer_dirty := 0`.
10. **Press `:q`** — clean quit (no refusal — buffer was just saved).
11. **`vibe newgame.fs`** — re-launches; confirm the deletions persisted to disk (file content matches what was on screen pre-`:w`).
12. **Edge case: dd on the last line of a file.** Navigate to the last line of the file (use `G` from Story 2.6 — `5G` or however many lines; or just `j` repeatedly). Press `dd`. The line vanishes; cursor lands on the new last line (which was previously the second-to-last). Confirm no `~` marker at the cursor row (cursor on real content, not an empty line marker).
13. **Edge case: dd on the only line of a single-line buffer.** Use `o`-then-Esc-then-many-`dd` pattern (or `:e somesingleline.txt` if a fixture is handy) to get to a single-line state, then `dd`. Buffer becomes empty; the editable area shows a `~` marker at row 0; cursor at offset 0. Confirm no crash, no garbled state. Press `i` (Story 2.8); type "hello"; Esc; `:w newfile.fs`; `:q`. Relaunch `vibe newfile.fs`; confirm "hello" persisted (i.e. the post-empty-buffer state was recoverable into a normal edit-and-save flow).

The hardware UAT also looks for regressions against earlier stories: motion in NORMAL still works (Stories 2.5-2.7); ex-line `:w` / `:q` / `:e` still work (2.1 / 2.2 / 2.4); INSERT-mode i/a/o/O + literal typing + Backspace + Enter + Esc still work (2.8); single-character delete `x` + counted `Nx` still work (2.9).

**AC8 — Implementation: multi-byte range-delete via N-iteration `gapbuf_delete` (matches the [[story-2-9-single-character-delete-x]] cursor-bounce trade-off).**

The architecture's "delete a contiguous range of N bytes" primitive does not yet exist as a public gapbuf entry. Three options, with the trade-off analysis the dev pass MUST consider:

**Option A (chosen): N-iteration `gapbuf_delete` loop with pre-staged cursor.**
1. Pre-stage the cursor at `delete_end` (the first byte AFTER the last byte we want to delete).
2. Loop: for k = 1..total_bytes: CALL `gapbuf_delete` (consumes byte at logical offset `cursor - 1`, decrements cursor). gapbuf_delete trashes BC, so PUSH/POP BC around each call (same shape as Story 2.9's `5x` loop body).
3. Post-loop: cursor sits at `delete_start` (gapbuf_delete has decremented it `total_bytes` times). This is the same offset AC2/AC3 want as the post-delete cursor position (the "delete_start if it's < new_file_length" case from AC2). No separate cursor-set instruction needed for that case.

This is the **AR14-clean cursor-bounce shape** from Story 2.9, generalised to N iterations. Cost: ~5 B at the call site for the cursor pre-stage + ~5 B per iter (LD HL, cursor; CALL gapbuf_delete; PUSH/POP BC). For a 100-byte delete that's ~500 B of CALL overhead — but gapbuf_delete's internal LDIR-shift is amortised: the first call moves the gap to `delete_end`; subsequent calls find the gap already in place and just decrement gap_start (~10 T-states each). Net cost on a 100-byte delete: ~10000 T-states ≈ 2.5 ms at 4 MHz — well within NFR3.

**Option B: New `gapbuf_delete_range(start, length)` primitive.**
Adds a new public entry to gapbuf.asm: pre-check, move_gap to `start + length` (the byte just past the range), then `gap_start := start` (direct write — internal to gapbuf, AR14-compliant). Cleaner semantics but ~50 B of new gapbuf surface (entry contract + body + AR23 docstring update) + dispatch ripple in modules that may want to use it later (Story 2.11 `dw` / `d$`; Story 2.12 doesn't need delete; Story 2.13's undo-replay-of-delete may want it). Saves bytes in op_dd's body (~30-40 B saved) at the cost of ~50 B in gapbuf.asm — net ~10 B saved across the project IF and only if two other modules use it.

**Option C: Direct `gap_start := delete_start; gap_end := delete_end + (gap_end - gap_start)` write from edits.asm.**
Fast (constant-time delete regardless of size) but an AR14 violation if done from edits.asm. Rejected — same rationale as Story 2.9 AC8 (no AR14 carve-outs from the "near-clean module" archetype).

**Recommendation: Option A.** Smaller blast radius (op_dd / op_yy body changes only; no gapbuf.asm patch; no AR23 ripple beyond edits.asm); the per-iter overhead is real but amortised by gapbuf_delete's gap-stays-in-place behaviour after the first call; the ~30-40 B byte-cost premium in op_dd's body is acceptable given the 540 B NFR9 headroom. **If profiling on hardware later shows `100dd`-class operations are observably slow** (unlikely — 2.5 ms is sub-perceptible) **revisit and consider Option B.** Document the decision (Option A chosen; Option B fallback documented) in op_dd's contract block.

**Order of operations** (critical for the yank-copy to read pre-delete bytes):
1. Compute `S`, `E`, `delete_start`, `delete_end`, `total_bytes` (line-bounds; pure read of gap buffer).
2. Yank-capacity check + yank-copy (read pre-delete bytes from logical offsets `delete_start..delete_end` via `motion_byte_at_logical` in a tight loop, write to `yank_buffer`). The bytes are still in the gap buffer at their original logical positions.
3. Status set (if yank refused).
4. Range-delete (Option A: pre-stage cursor at delete_end; loop gapbuf_delete total_bytes times).
5. Post-delete cursor placement.
6. `buffer_dirty := 1` (via shared `edits_dirty_and_redraw` helper).
7. Tail-JP `parser_clear`.

For `op_yy`: steps 1, 2, 3 only. Skip 4/5/6 (no mutation). Tail-JP parser_clear directly.

**AC9 — Architecture compliance — `edits.asm` extended (no new module).**

`op_dd` and `op_yy` live in the existing `src/edits.asm`, NOT a new module. AR boundary properties match Story 2.9:

- **AR13 (no screen emission):** zero `BIOS_CONOUT_*` references. Sweep `grep -n 'BIOS_CONOUT' src/edits.asm` — no new code refs (only the existing doc-comment header references). The yank-copy loop walks logical offsets via `motion_byte_at_logical` (read primitive); the range-delete loop calls `gapbuf_delete` (gapbuf primitive). Neither path emits to screen.
- **AR14 (no direct buffer mutation):** zero `LD (gap_start), DE` / `LD (gap_end), DE` writes. All mutation through `gapbuf_delete` in the iter-loop. Sweep `grep -nE 'LD \((gap_start|gap_end)\),' src/edits.asm` — no code refs.
- **AR15 (no raw BDOS):** zero `BDOS_CALL` / `CALL BDOS_ENTRY` / `CALL 0x0005` references. Sweep `grep -nE 'BDOS_CALL|CALL BDOS_ENTRY|CALL 0x0005' src/edits.asm` — no code refs.
- **AR12 (status via funnel):** `op_dd` and `op_yy` MAY surface `msg_yank_too_large` via `status_set_message` (AR12-compliant — single-funnel error path). `msg_yank_too_large` is the only new status string from this story. Goes in `statusln.asm`'s message block (AR12 — "Add new messages in this block, not inline within a module's code." per architecture.md:1037).
- **AR23 (module header docstring):** the existing `src/edits.asm` module-header block MUST be extended to:
  - Add `op_dd` and `op_yy` to the Public list.
  - Add per-entry contract blocks for `op_dd` and `op_yy` per AR23 (In/Out/Trashes/Calls).
  - Add doc-comments documenting the new internal helpers introduced (see below).
  - Extend the State owned (read/write) block to note: cursor_offset (written by op_dd's range-delete via gapbuf_delete's cursor-bounce; restored to final position by AC2 placement rule); yank_kind, yank_length, yank_buffer (written by AC2's yank-copy on success path; UNCHANGED on capacity-refusal path); buffer_dirty (written on op_dd success; never written by op_yy).
  - Extend the Dependencies block to add: motion_find_line_start (line-bounds left edge), motion_find_line_end (right edge), motion_byte_at_logical (yank-copy source byte read), motion_apply_count (count default), edits_dirty_and_redraw (success tail), parser_clear (tail-JP both paths). statusln.asm's status_set_message (for msg_yank_too_large surface).
- **AR25 (INCLUDE chain):** unchanged. `src/vibe.asm`'s INCLUDE order keeps `edits.asm` between `motions.asm` and `exline.asm`.

**parser.asm patch** (AC1): the `parser_doubled_operator_stub` body is replaced (or the routine is renamed and a new dispatcher added — see AC1 implementation-choice). The Story 1.10 module-header docstring is updated:
- Replace "Plus one Epic-1 placeholder stub..." paragraph with "Plus the doubled-operator dispatcher (parser_doubled_operator — Story 2.10 promoted this from stub to real). The dispatcher reads pending_operator and branches to op_dd / op_yy / msg_not_implemented for c/>/<."
- Update the Public list to drop `parser_doubled_operator_stub` OR rename to `parser_doubled_operator` (per chosen path).
- Update the Stub-handler contract block to a real-handler contract block (In: pending_operator already set; Out: op_dd / op_yy / msg_not_implemented invoked; tail-JP to parser_clear from each handler).

**AC10 — Equates: `KIND_LINE`, `KIND_CHAR`, `KIND_BLOCK` introduced.**

The SR6 yank-kind discriminator constants don't exist in the codebase yet. Story 2.10 introduces them. Placement: `inc/equates.inc` — they're compile-time constants and fit the existing `;; --- Editing knobs ---` section (or a new `;; --- Yank register kinds ---` block — implementation choice, with the chosen path documented in equates.inc's header comment per NFR16).

Suggested values (encoded as 1-byte EQUs):
- `KIND_CHAR  EQU 0x00`  ; default — character-wise yank (Story 2.11 dw / d$ / c5w / y3j will use this)
- `KIND_LINE  EQU 0x01`  ; line-wise yank (Story 2.10 dd / yy — THIS STORY introduces this)
- `KIND_BLOCK EQU 0x02`  ; block-wise yank (Epic 3 visual-block; reserved)

Rationale for 0x00 default: `init_cold_start`'s LDIR zero-fill (per state.inc:121 + init.asm:202-206) leaves `yank_kind` at 0 pre-first-yank. KIND_CHAR == 0 means an uninitialised yank register reads as CHAR-kind. Story 2.12 `p` will guard against `yank_length == 0` (the real "no prior yank" signal); the kind byte being 0 is incidental. The 0x00 / 0x01 / 0x02 allocation matches the natural sjasmplus DEFB output and is the smallest possible 3-value space.

Alternative: KIND_LINE = 'L', KIND_CHAR = 'C', KIND_BLOCK = 'B' (ASCII letters; aids debugging when inspecting yank_kind in a hex dump). Slightly bigger (no boolean tricks possible) but more human-readable. **Implementation choice — pick one and document the rationale in equates.inc.** Both choices satisfy SR6's "1 byte" requirement.

**AC11 — `msg_yank_too_large` status message added.**

New status string in `src/statusln.asm`'s message block (the section near line 218 — adjacent to msg_file_too_large / msg_undo_too_large / msg_no_write).

Suggested text (~16 B incl. trailing 0): `msg_yank_too_large:  DEFB "yank too large", 0` — matches the SR6 wording at architecture.md:460 ("status line shows 'yank too large'"). Lowercase, no trailing period, under 30 chars per architecture.md:1008-1013 status-line format conventions.

The string is referenced by `op_dd` (AC2 over-capacity path) and `op_yy` (AC4 over-capacity path) via `LD HL, msg_yank_too_large; XOR A; CALL status_set_message` — the standard AR12 surface.

Update `src/statusln.asm`'s module-header Public list note to include `msg_yank_too_large` in the strings enumeration.

**AC12 — Headless tests (all under `test/cases/edits_*.asm` + `test/cases/parser_*.asm`).**

**Canonical (epic spec line 1335):**

- `edits_dd-deletes-line.asm` — pre-load `"abc\ndef\nghi"` (11 B) with mode_byte=MODE_NORMAL, cursor=0 on line 1, count_accumulator=0, pending_operator='d' (pre-staged to simulate having just dispatched first 'd'); CALL `op_dd` directly (not through dispatch — test pins the handler logic, not the parser chain). Assert: buffer = `"def\nghi"` (7 B); cursor=0 (start of what was line 2); buffer_dirty=1; yank_kind=KIND_LINE; yank_length=4 ("abc\n" = 4 B); yank_buffer[0..3] = "abc\n"; parser_clear ran (count_accumulator=0, pending_operator=0, pending_motion_prefix=0).

- `edits_yy-copies-line.asm` — pre-load `"abc\ndef"` (7 B), cursor=4 (on 'd', line 2); CALL `op_yy`. Assert: buffer = `"abc\ndef"` (unchanged); cursor=4 (unchanged); buffer_dirty=0 (unchanged from init); yank_kind=KIND_LINE; yank_length=3 ("def" — last line no LF, range [4, 7), 3 B); yank_buffer[0..2] = "def"; parser_clear ran.

- `edits_dd-counted-3lines.asm` — pre-load `"a\nb\nc\nd\ne"` (9 B), cursor=0, count_accumulator=3, pending_operator='d'; CALL `op_dd` (or via parser_dispatch shape — see below). Assert: buffer = `"d\ne"` (3 B); cursor=0; buffer_dirty=1; yank_kind=KIND_LINE; yank_length=6 ("a\nb\nc\n"); count_accumulator=0 (cleared).

- `edits_dd-yank-too-large.asm` — pre-load a buffer with a line > 1024 B. Use a 1026-byte line (1025 printable bytes + 1 LF, OR just 1025 printable bytes with no LF for the no-LF case — pick one for cleaner sentinels). cursor=0; CALL `op_dd`. Assert: buffer is shrunk by the deleted line (`new_file_length = old_file_length - 1026`); buffer_dirty=1; yank_length and yank_kind UNCHANGED from pre-call state (test pre-seeds yank_kind=0xEE, yank_length=0xCAFE so we can verify they didn't change); status_buffer contains "yank too large" prefix; status_dirty=1.

**Additional (full AC + edge coverage):**

- `edits_dd-last-line-no-trailing-lf.asm` — pre-load `"a\nb\nc"` (5 B; last line "c" no LF), cursor=4 (on 'c'); CALL `op_dd`. Assert: buffer = `"a\nb"` (3 B — vi: dd on the no-trailing-LF last line consumes the prior LF + the line); cursor = motion_find_line_start(2) = 2 (start of "b" — the new last line); buffer_dirty=1; yank_kind=KIND_LINE; yank_length=2 ("\nc" — the prior LF + the line; OR alternative: 1 if the spec author wants yank to NOT include the cross-line LF — see below); yank_buffer[0..1] = matches yank_length bytes.

  **NB:** the yank content for the "last-line-no-LF, S>0" case (`[S-1, file_length)` range) starts with an LF byte (the prior line's LF that we consumed). Paste-back semantics for KIND_LINE in [[story-2-12-paste]] should treat this as: "the line content is `yank_buffer[1..]`; the leading byte is the cross-line LF marker." OR Story 2.12 ignores leading LFs in KIND_LINE pastes. Either way, Story 2.10's job is to capture the deleted bytes verbatim. **The exact paste semantics are Story 2.12's concern; Story 2.10's spec is: yank holds the deleted bytes verbatim.**

- `edits_dd-only-line.asm` — pre-load `"hello"` (5 B; single line, no LF), cursor=0; CALL `op_dd`. Assert: buffer empty (file_length=0); cursor=0; buffer_dirty=1; yank_kind=KIND_LINE; yank_length=5 ("hello"); gap_start = GAP_BUFFER_BASE; gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX (empty gap-buffer state).

- `edits_dd-empty-buffer.asm` — pre-load empty buffer (file_length=0), cursor=0; CALL `op_dd`. Assert: buffer still empty; cursor=0; buffer_dirty UNCHANGED (no-op path — no line to delete); yank_kind / yank_length UNCHANGED; parser_clear ran. This is the "S==0 AND E==file_length==0" edge — total_bytes=0; the AC2 / AC3 yank-copy + delete paths are skipped via a 0-byte guard. **The exact no-op shape is implementation choice** — either (a) early-RET-with-parser_clear on total_bytes=0 like Story 2.9's no-op path, or (b) execute the yank-copy + delete loops 0 times (both are no-ops with 0 byte counts). Option (a) is cheaper and matches the Story 2.9 pattern. Document the chosen shape.

- `edits_yy-yank-too-large.asm` — pre-load buffer with line > 1024 B; cursor=0; CALL `op_yy`. Assert: buffer UNCHANGED; cursor UNCHANGED; buffer_dirty UNCHANGED; yank_kind / yank_length UNCHANGED from pre-call seed; status_buffer contains "yank too large".

- `edits_dd-counted-clamps-at-eof.asm` — pre-load `"a\nb\nc"` (5 B), cursor=0, count_accumulator=100; CALL `op_dd`. Assert: buffer empty; cursor=0; buffer_dirty=1; yank_length=5; yank_kind=KIND_LINE. (BH2-equivalent: 100dd on a 3-line file deletes all 3 lines; the walk early-exits on hitting last_line_was_eof at iter 3.)

- `edits_dd-yank-kind-line.asm` — explicit pin: pre-seed yank_kind = 0xFF (any non-LINE value); pre-load `"abc\n"` (4 B), cursor=0; CALL `op_dd`. Assert: yank_kind = KIND_LINE post-call (proves the assignment happens; a regression that mistakenly assigned KIND_CHAR would fail here).

- `edits_yy-yank-kind-line.asm` — same shape; pre-seed yank_kind=0xFF; CALL `op_yy`; assert yank_kind = KIND_LINE.

- `edits_dd-clears-parser-state.asm` — pre-seed count_accumulator=5, pending_operator='d', pending_motion_prefix='g' (these would never co-exist in practice but the test verifies the handler's tail-JP parser_clear zeros all three fields atomically); pre-load `"abc\n"`, cursor=0; CALL `op_dd`. Assert: all three parser-state fields zeroed post-call.

- `edits_yy-clears-parser-state.asm` — same shape for op_yy. (Critical: op_yy is read-only but MUST still tail-JP parser_clear to honor the FR50 / Story 2.5 AC13 hygiene rule that every dispatched key clears parser state.)

- `parser_doubled-operator-routes-to-dd.asm` — drive the full parser chain: pre-load `"abc\n"`, mode=MODE_NORMAL, cursor=0; CALL `parser_handle_operator` with A='d' (first 'd' — stores pending_operator='d', RETs); CALL `parser_handle_operator` again with A='d' (second 'd' — doubled detected; JPs parser_doubled_operator_stub OR parser_doubled_operator per AC1 chosen name; dispatcher routes to op_dd). Assert: buffer post-call = empty; yank_kind=KIND_LINE; yank_length=4 ("abc\n"); parser cleared. This test pins the AC1 parser-chain wiring end-to-end.

- `parser_doubled-operator-routes-to-yy.asm` — same shape with 'y' twice; assert buffer unchanged; yank_kind=KIND_LINE; yank_length matches; parser cleared.

- `parser_doubled-operator-routes-to-not-implemented.asm` — drive parser_handle_operator twice with 'c' (cc — not in MVP scope); assert status_buffer contains "not yet implemented"; parser cleared. Pins the AC1 fall-through to the existing msg_not_implemented surface. (Same shape works for '>' and '<' if the dev wants belt-and-braces coverage; one test for the c/>/< fall-through arm is sufficient.)

- `parser_5dd-counted-via-parser-handle-operator.asm` — drive the full counted sequence: pre-load `"a\nb\nc\nd\ne"` (9 B), cursor=0; pre-set count_accumulator=5 (simulating prior `parser_handle_digit` runs for '5'); CALL `parser_handle_operator` with A='d' (first 'd' — stores pending_operator, count_accumulator preserved per src/parser.asm:336-337); CALL `parser_handle_operator` with A='d' (doubled — dispatches to op_dd with count=5 still in count_accumulator). Assert: buffer empty (5 lines but only 5 in file → all deleted); yank_length=9 ("a\nb\nc\nd\ne"); count_accumulator=0 post-call. This test pins the cross-cut "count survives operator, doubled-op reads count, clears after dispatch" invariant flagged in deferred-work.md:93-94.

- `edits_dd-cursor-on-middle-line.asm` — pre-load `"a\nb\nc"` (5 B), cursor=2 (on 'b', line 2); CALL `op_dd`. Assert: buffer = `"a\nc"` (3 B); cursor = 2 (start of new line 2 = "c"); buffer_dirty=1; yank_kind=KIND_LINE; yank_length=2 ("b\n"); yank_buffer = "b\n".

- `edits_dd-cursor-mid-line.asm` — pre-load `"abc\ndef\nghi"` (11 B), cursor=5 (mid-"def", line 2 col 1); CALL `op_dd`. Assert: cursor lands at motion_find_line_start position of the new line at offset 4 (which is now "ghi" — the deleted "def\n" range was [4, 8); post-delete buffer = "abc\nghi" 7 B; cursor=4 (start of "ghi")); yank_length=4 ("def\n"); yank_kind=KIND_LINE. This test pins: (a) line-start is computed from cursor's logical line, not from cursor itself; (b) post-delete cursor lands at line-start of the new line, not at the original mid-line offset.

Test count target: 4 canonical + ~12 additional = ~16 new tests. Sentinel allocation per test follows the Story 2.5 / 2.6 / 2.7 / 2.8 / 2.9 convention (0x80..0x87 envelope per test).

**AC13 — Build invariants (NFR9, NFR18, AR sweeps).**

- `make all` followed by `make clean && make all` produces a byte-identical `vibe.com` (NFR18).
- `make test` from a fresh `make clean && make test` is green (the 118 pass / 1 deliberate-fail post-2.9 baseline grows by ~16 to ~134 pass / 1 fail).
- AR13 / AR14 / AR15 grep sweeps against `src/edits.asm` and `src/parser.asm` are all clean. **New sweep:** `grep -n 'msg_yank_too_large' src/edits.asm` shows 2 code refs (op_dd over-capacity arm + op_yy over-capacity arm) + the doc-comment refs.
- AR25 INCLUDE chain in `src/vibe.asm` is unchanged (`statusln → gapbuf → render → dispatch → parser → motions → edits → exline → fileio`).
- `dispatch_normal` count UNCHANGED at 33 entries (Story 2.10 does NOT add new bound keys — 'd' and 'y' already bound to parser_handle_operator since Story 1.10).
- `dispatch_insert` / `dispatch_command` / `dispatch_visual` unchanged.

- **NFR9 projection:** post-2.9 footprint = 4580 B (~89.45% of 5120 B / ~540 B headroom). Story 2.10 adds:
  - **op_dd body** (~120-160 B): motion_apply_count, line-bounds walk loop (~30 B), yank-capacity check + yank-copy loop (~40 B), range-delete loop (~20 B), post-delete cursor placement (~20-30 B), edits_dirty_and_redraw tail (~3 B).
  - **op_yy body** (~50-80 B): line-bounds walk (shared helper if factored — saves ~30 B; otherwise duplicated), yank-capacity check + yank-copy loop (shared helper saves ~25 B), parser_clear tail (~3 B).
  - **Shared internal helpers** (~40-70 B if factored — recommended): `edits_line_range_for_count(N)` (line-bounds walk) returning `delete_start` / `delete_end` / `total_bytes`; `edits_copy_to_yank(start, length)` returning CF=1 on over-capacity. Factoring saves ~50-80 B net across op_dd / op_yy.
  - **parser_doubled_operator dispatcher** (~25-40 B): reads pending_operator, 3-way branch (d / y / else).
  - **msg_yank_too_large string** (~16 B).
  - **KIND_* equates** (0 B — compile-time).
  - **Net delta projection: ~250-350 B.** Post-2.10 footprint: 4830-4930 B = ~94-96% of 5120 B = ~190-290 B headroom.
  - **Verdict: tight but feasible.** Stories 2.11 (dw/d$/c5w/y3j — operator+motion composer; the architecturally significant cross-cut) and 2.12 (paste) will be the real squeeze. If the dev pass observes the upper end of the projection (>~350 B delta), consider deferring one of the additional tests OR factoring helpers more aggressively (e.g. `edits_doubled_operator_prelude` shared across op_dd / op_yy reading count + computing line range — ~20 B more savings). If the lower end (~250 B), no action needed.

- **`buffer_dirty` write count:** Story 2.10 adds 1 site writing `buffer_dirty := 1` (in `op_dd`'s success-tail path via `edits_dirty_and_redraw`; SAME helper as Story 2.8 / 2.9). `op_yy` does NOT write buffer_dirty. The no-op paths (empty buffer; counted form where line-bounds yield 0 bytes) NEVER write buffer_dirty.

## Tasks / Subtasks

- [x] **Task 1: Add yank-kind equates and yank-too-large status string** (AC10, AC11).
  - [x] Sub 1.1: In `inc/equates.inc`, add `KIND_CHAR`, `KIND_LINE`, `KIND_BLOCK` constants. Pick the 0x00/0x01/0x02 numeric form OR the 'C'/'L'/'B' ASCII form (with one-line rationale comment). Update equates.inc's module-header Public list. The constants go in a new `;; --- Yank register kinds ---` block adjacent to the existing `;; --- Editing knobs ---` block.
  - [x] Sub 1.2: In `src/statusln.asm`, add `msg_yank_too_large: DEFB "yank too large", 0` to the strings block (near msg_file_too_large / msg_undo_too_large / msg_no_write — alphabetical OR insertion-order; matches existing convention). Update statusln.asm's module-header Public list to include the new symbol.
  - [x] Sub 1.3: Verify NFR18 byte-identical rebuild after Sub 1.1 + 1.2 with two consecutive `make clean && make all` (the equate-only change should be 0-byte-delta; the new string adds ~16 B to the strings region but no other addresses shift since strings live at end-of-code).

- [x] **Task 2: Implement shared internal helpers** (AC2, AC3, AC4, AC5, AC8 — factoring decision per AC13 NFR9 economy).
  - [x] Sub 2.1: Implement `edits_line_range_for_count` (or inline if factoring deferred) — given current cursor and `count_accumulator`, compute `delete_start` / `delete_end` / `total_bytes` per AC2 / AC3 rules. Returns these in a documented register convention (e.g., HL=delete_start, DE=delete_end, BC=total_bytes — explicit per AR23 contract block). Handles the last-line-no-LF + S>0 / S==0 / counted form / count-clamp-at-eof cases.
  - [x] Sub 2.2: Implement `edits_copy_to_yank` (or inline) — given `delete_start` and `total_bytes`, copy bytes from logical offsets to `yank_buffer`. Pre-check `total_bytes <= YANK_BUFFER_SIZE`; on over-capacity, return CF=1 + call `status_set_message msg_yank_too_large` (or signal via CF=1 and have the caller surface the status — implementation choice with rationale). On success, write `yank_kind := KIND_LINE` and `yank_length := total_bytes`. Use `motion_byte_at_logical` in a tight loop for source reads (preserves BC; HL pointer to yank_buffer write target).
  - [x] Sub 2.3: Implement `edits_range_delete` (or inline) — given `delete_start` and `total_bytes`, pre-stage `cursor_offset := delete_start + total_bytes`, then loop `total_bytes` times calling `gapbuf_delete` (each iter PUSH/POP BC around the call per Story 2.9 pattern). Post-loop cursor sits at `delete_start`.
  - [x] Sub 2.4: AR23 contract blocks for each new helper (In / Out / Trashes / Calls).
  - [ ] **NB on factoring:** the dev pass MUST decide whether to factor 2.1 / 2.2 / 2.3 as separate helpers vs inline the bodies into op_dd / op_yy. **Recommendation: factor.** Both op_dd and op_yy use 2.1 + 2.2; op_dd additionally uses 2.3. Factoring saves ~50-80 B net. The dev pass should commit to the factoring decision before writing op_dd / op_yy.

- [x] **Task 3: Implement `op_dd`** (AC2, AC3, AC6, AC8).
  - [x] Sub 3.1: Per-entry contract block per AR23 — In: A = 'd' (MC4; ignored — the dispatch chain consumed both 'd' bytes already; A holds the second 'd'). count_accumulator read via motion_apply_count. pending_operator already 'd' (set by first parser_handle_operator). Out: success — line(s) deleted; bytes copied to yank register (yank_kind=KIND_LINE, yank_length=total_bytes) OR yank refused with status surface; buffer_dirty=1; all rows dirty; cursor at post-delete line start; parser state zeroed. no-op (empty buffer / 0-byte line) — buffer + cursor + buffer_dirty unchanged; parser cleared. Trashes: A, BC, DE, HL, F. Calls: motion_apply_count, edits_line_range_for_count (or inline equivalent), edits_copy_to_yank (or inline), status_set_message (on yank refusal), edits_range_delete (or inline), edits_dirty_and_redraw, parser_clear (tail-JP).
  - [x] Sub 3.2: Body composition — call motion_apply_count to get BC=count; call edits_line_range_for_count to get the range; 0-byte guard (HL=BC, total_bytes==0 → JP .noop_clear); call edits_copy_to_yank (CF=1 → JR .yank_refused which calls status_set_message msg_yank_too_large, falls through to delete); call edits_range_delete; post-delete cursor placement (the AC2 "delete_start if < new_file_length, else find new last line start, else 0" three-way decision — ~15 B); CALL edits_dirty_and_redraw; JP parser_clear. `.noop_clear:` JP parser_clear.
  - [x] Sub 3.3: FR45 undo recording stub — NO write to undo_buffer. Document the hook site for Story 2.13 in the per-entry contract block AND in deferred-work.md (Task 7 housekeeping below). Hook position: AFTER edits_copy_to_yank returns success (the deleted bytes have been captured to yank_buffer, where Story 2.13 will read them for the undo entry) AND BEFORE edits_range_delete (Story 2.13's undo_record needs the pre-delete byte positions). Cleaner alternative: Story 2.13 reads from yank_buffer (which holds the same bytes) AFTER the delete — but that couples undo recording to yank capacity, which is wrong (an undo-refusal-on-yank-too-large would be a regression: undo should still record if the bytes fit in undo_buffer even when yank didn't fit). **Hook site recommendation: BEFORE edits_copy_to_yank** (so undo records from the original gap buffer positions, independent of yank capacity).

- [x] **Task 4: Implement `op_yy`** (AC4, AC5).
  - [x] Sub 4.1: Per-entry contract block per AR23 — In: A = 'y' (MC4; ignored). count_accumulator read via motion_apply_count. pending_operator already 'y'. Out: success — bytes copied to yank register; buffer + cursor + buffer_dirty all UNCHANGED. yank refusal (over capacity) — status surface; buffer + yank register + cursor + buffer_dirty all UNCHANGED. no-op (0-byte line) — same as yank refusal shape, status NOT surfaced (silent — there's no error, just nothing to yank). Parser state zeroed on every path. Trashes: A, BC, DE, HL, F. Calls: motion_apply_count, edits_line_range_for_count, edits_copy_to_yank, status_set_message (on capacity refusal), parser_clear (tail-JP).
  - [x] Sub 4.2: Body composition — call motion_apply_count; call edits_line_range_for_count; 0-byte guard (silent → JP parser_clear); call edits_copy_to_yank (CF=1 → call status_set_message msg_yank_too_large, fall through to parser_clear); JP parser_clear. No buffer_dirty write; no render mark; no edits_range_delete.
  - [x] Sub 4.3: NO undo recording (yank-only — nothing to undo). Document this in the contract block.

- [x] **Task 5: Replace `parser_doubled_operator_stub` with real dispatcher** (AC1, AC9).
  - [x] Sub 5.1: In `src/parser.asm`, rewrite the body of `parser_doubled_operator_stub` (keep name OR rename to `parser_doubled_operator` and update callers / module header — pick one path with rationale). The new body: read `pending_operator` byte; CP 'd' → JP op_dd; CP 'y' → JP op_yy; else (c/>/<) → JP msg_not_implemented surface (preserve the existing `LD HL, msg_not_implemented; XOR A; CALL status_set_message; JP parser_clear` shape for the fall-through arm).
  - [x] Sub 5.2: Update parser.asm module-header docstring per AR23 — replace the "Plus one Epic-1 placeholder stub..." paragraph with the new dispatcher description; update the Public list; update the per-entry contract block from the stub-handler to a real-handler contract.
  - [x] Sub 5.3: Sanity-check: parser_handle_operator's `.first_operator` arm (src/parser.asm:334-337) still stores pending_operator without modification. parser_doubled_operator does NOT need to clear pending_operator before JP'ing — op_dd / op_yy's tail-JP parser_clear zeroes it.

- [x] **Task 6: Update src/edits.asm module-header docstring** (AC9, AR23).
  - [x] Sub 6.1: Added `op_dd` and `op_yy` to the Public list (after `edits_delete_char`).
  - [x] Sub 6.2: Added per-entry contract blocks for `op_dd` and `op_yy` per AR23 (In / Out / Trashes / Calls) — content from Sub 3.1 and Sub 4.1.
  - [x] Sub 6.3: Updated Purpose block — closing parenthetical mentions Story 2.10 lands `dd` (FR29) and `yy` (FR31); the FR list grows from "FR24-FR28" to "FR24-FR29 + FR31".
  - [x] Sub 6.4: Updated State owned (read/write) block — added sentence noting op_dd writes yank_kind / yank_length / yank_buffer (success path) and cursor_offset (via the cursor-bounce N-iter shape); op_yy writes yank_kind / yank_length / yank_buffer (success path only) and NOTHING else.
  - [x] Sub 6.5: Updated Dependencies block — appended motion_find_line_start + motion_find_line_end (line-bounds) + motion_byte_at_logical (yank-copy source reads) as the helpers used by Story 2.10. New cross-module dependency: statusln.asm's msg_yank_too_large.

- [x] **Task 7: Headless tests** (AC12).
  - [x] Sub 7.1: 4 canonical tests landed (epics line 1335): `edits_dd-deletes-line.asm`, `edits_yy-copies-line.asm`, `edits_dd-counted-3lines.asm`, `edits_dd-yank-too-large.asm`. All pass.
  - [x] Sub 7.2: ~12 additional tests landed (per AC12 enumeration). The dev pass MAY drop 1-2 tests if their coverage is fully subsumed by sibling tests (document any drops + rationale per the Story 2.9 pattern).
  - [x] Sub 7.3: Sentinel allocation per landed test — follow the Story 2.5..2.9 0x80..0x87 envelope convention. Each test enumerates its sentinels in a header comment.
  - [x] Sub 7.4: All tests get the full INCLUDE chain (test_prologue.inc / test body / test_epilogue.inc / production sources / test_teardown_stub.inc + test_input_loop_stub.inc / state.inc).
  - [x] Sub 7.5: For the parser_*.asm tests (the dispatch-chain-coverage tests in AC12), pre-set pending_operator and count_accumulator from `test_prologue`-region code BEFORE driving parser_handle_operator. This matches the Story 1.10 parser-test convention.

- [x] **Task 8: NFR9 + NFR18 + AR sweeps** (AC13).
  - [x] Sub 8.1: Two consecutive `make clean && make all` produce byte-identical `vibe.com` — capture SHA.
  - [x] Sub 8.2: AR enforcement sweeps clean — `BIOS_CONOUT` / `LD (gap_start|gap_end), ...` / `BDOS_CALL` greps return only doc-comment refs in `src/edits.asm` and `src/parser.asm`; zero new code refs. `CALL gapbuf_delete` count in edits.asm grows: was 2 code sites (edits_insert_backspace + edits_delete_char); becomes 3 code sites (+ edits_range_delete loop site). All inside the AR14 envelope (gapbuf primitive is the AR14-compliant mutation surface).
  - [x] Sub 8.3: `vibe.com` size: 4580 → ~4830-4930 B (Δ+250-350 B per AC13 projection). Report exact post-build size + percentage of 5120 B + headroom. If size > 4980 B (>97%), flag in completion notes for review.
  - [x] Sub 8.4: `DISPATCH_NORMAL_COUNT` confirmed unchanged at 33 (no new dispatch_normal entries).
  - [x] Sub 8.5: Test pass count: 118 → ~134 pass / 1 deliberate-fail (16 new tests).

- [x] **Task 9: deferred-work.md housekeeping.**
  - [x] Sub 9.1: FR45 undo recording stub for `dd` documented in deferred-work.md (`Deferred from: dev of story-2-10-...` section) — `op_dd` does NOT write to `undo_buffer`; Story 2.13's hook site is the position BEFORE edits_copy_to_yank (the gap-buffer bytes are still in place at their pre-delete logical offsets there; undo_record needs to read from those positions; this is INDEPENDENT of yank capacity).
  - [x] Sub 9.2: Document the AC8 Option-A-vs-B trade-off (cursor-bounce N-iter vs new gapbuf_delete_range primitive). Revisit trigger: if any future story has a deletion surface that consistently exceeds ~50 bytes per call AND profiling shows the iter-overhead is observable on hardware.
  - [x] Sub 9.3: Document the AC2 last-line-no-LF cross-line yank-includes-leading-LF semantic. Note that Story 2.12's paste handler MUST decide how to interpret KIND_LINE yank content with a leading LF byte. The simplest interpretation: KIND_LINE paste re-inserts the yank_buffer bytes verbatim at the post-paste position; the leading LF (if present) creates a new empty line above the paste target — which is vi-faithful for the "p" of a deleted last line (it ends up below the cursor, with the consumed prior LF now separating it from the line above). Document the decision pointer for Story 2.12.
  - [x] Sub 9.4: Document the KIND_CHAR / KIND_LINE / KIND_BLOCK equate-format choice (0x00/0x01/0x02 vs 'C'/'L'/'B'). Note that Story 2.11 (dw / d$ / c5w / y3j) will introduce KIND_CHAR usage and Story 3.5 (visual block) will introduce KIND_BLOCK; the current 1-byte form supports up to 256 kinds — plenty of room for future register-kind extensions.
  - [x] Sub 9.5: If the dev pass observes test-coverage gaps (e.g., counted dd starting at non-line-start cursor; over-capacity yank that also happens to be a partial-line range — n/a for line-granularity ops but worth noting; etc.), document them as Story-2.11-or-later candidates.

- [x] **Task 10:  <!-- Hardware UAT confirmed by Ant 2026-05-16 — all 13 steps functionally pass; spec-narrative error on `~` empty-line marker logged to deferred-work.md (VIBE renders past-EOF rows as blank spaces, by design — never had a `~` marker). -->
 Hardware UAT** (AC7) — confirmed by Ant.
  - [x] Sub 10.1: `make push` SLIDE transfer to real MicroBeast.
  - [x] Sub 10.2: Ant steps through the 13-step AC7 UAT script on real MicroBeast.
  - [x] Sub 10.3: Story stays at `review` pending code-review pass (per workflow convention — review → done flip happens after code-review applies any patches).

## Dev Notes

### Architecture compliance

- **AR13 (no screen emission from edits / parser).** `op_dd`, `op_yy`, and the rewritten `parser_doubled_operator` do not call `BIOS_CONOUT_*`. The yank-copy + range-delete + line-bounds-walk loops are pure memory ops. Status surface (msg_yank_too_large) goes through `status_set_message` (the AR12 funnel). Render-side reflection of the line delete happens via `render_mark_all_dirty` (already paid for by Story 2.8 / 2.9) + `render_diff` on the next frame.
- **AR14 (no direct buffer mutation outside gapbuf primitives).** `op_dd`'s range-delete mutates the buffer ONLY through repeated `gapbuf_delete` calls — same AR14-compliant cursor-bounce shape as Story 2.9's counted `5x` body. The yank-copy reads logical offsets via `motion_byte_at_logical` (read primitive — AR14 "reads OK" envelope). No `LD (gap_start), DE` / `LD (gap_end), DE` writes anywhere in op_dd / op_yy / parser_doubled_operator / the new helpers.
- **AR15 (no raw BDOS).** Pure-memory ops. The yank_buffer write target is at `GAP_BUFFER_BASE + GAP_BUFFER_MAX` (a static EQU; not a BDOS call).
- **AR12 (status messages via funnel).** `op_dd` and `op_yy` surface `msg_yank_too_large` via `status_set_message` only. The c/>/< fall-through in `parser_doubled_operator` preserves the existing `msg_not_implemented` surface (no semantic change for those operator-doubled-keys until Story 2.11 lands `>>` / `<<`).
- **AR23 (module header documentation).** edits.asm + parser.asm + statusln.asm + equates.inc all grow header entries per the AC9 / AC10 / AC11 patches. No new module is added; AR25 INCLUDE chain unchanged.
- **AR25 (INCLUDE chain).** `src/vibe.asm`'s INCLUDE order keeps `statusln → gapbuf → render → dispatch → parser → motions → edits → exline → fileio`. parser.asm includes BEFORE edits.asm, so the parser_doubled_operator → op_dd / op_yy JPs are forward references resolved by sjasmplus's two-pass model (same shape as parser_handle_motion_prefix → motion_gg in Story 2.6).
- **MC3 (binary-search dispatch).** `dispatch_normal` count UNCHANGED at 33 entries. 'd' and 'y' have been bound to parser_handle_operator since Story 1.10. Binary-search worst case stays at 6 iterations.
- **MC4 (handler signature — A=key on entry; state via state.inc symbols).** op_dd and op_yy receive A = the doubled operator byte (which they ignore — the dispatch chain already consumed and stashed it via pending_operator). count_accumulator read via motion_apply_count. pending_operator read directly by parser_doubled_operator before the d/y/else branch.
- **SR6 (yank register).** Story 2.10 is the FIRST story to write the yank register. The protocol:
  - On success: yank_kind := KIND_LINE; yank_length := byte_count; bytes copied to yank_buffer (at GAP_BUFFER_BASE + GAP_BUFFER_MAX per state.inc:132).
  - On over-capacity: yank register UNCHANGED (predictable failure mode per SR6); status_buffer := "yank too large"; the prior yank's content + kind + length are preserved.
  - yank_kind / yank_length are at fixed state.inc offsets (state.inc:54, state.inc:76); yank_buffer is in the reserved pool (state.inc:132).
  - No new state cells added — all 3 yank-register fields are already declared in state.inc (resolved by the Story 1.3 static memory map pass).
- **BH2 (counted-motion clamps — silent at boundary).** Counted `Ndd` and `Nyy` walk N line-ends but EARLY-EXIT on hitting last_line_was_eof (per AC3). This is the line-granularity BH2 — analogous to Story 2.7's `100j` clamping at last line. Silent (no status surface) — the user gets "as many lines as could be deleted" without an error.
- **FR29 / FR31 (the load-bearing FRs for this story).** dd deletes the current line; yy yanks the current line. End-to-end verified via the canonical 4 tests in AC12 + AC7 hardware UAT.
- **FR40 (doubled-operator detection).** Story 1.10 wired the detection; Story 2.10 wires the **dispatch** to real handlers (replacing the stub).
- **FR45 / FR46 (undo coverage — Story 2.13).** dd's inverse-op recording is a STUB for 2.10; full impl in 2.13. Hook site documented in deferred-work.md (Sub 9.1).
- **NFR1 / NFR2 / NFR3 (interactive feedback / sustained typing / cursor-motion latency).** Each `dd` keystroke: motion_apply_count (~5 T-states); line-bounds walk (2× motion_find_line_end + 1× motion_find_line_start — each is a bounded scan through the gap buffer); yank-copy loop (bounded by yank_length ≤ 1024 — at ~30 T-states per byte that's ~30000 T-states = 7.5 ms at 4 MHz for a maxed yank; sub-perceptible); range-delete loop (bounded by total_bytes; gapbuf_delete after the first call is O(1) per byte since gap stays in place — ~10 T-states per byte = 10000 T-states for 1000-byte delete = 2.5 ms). Aggregate: a worst-case 1024-byte dd is ~10-15 ms — fits within NFR3's interactive budget.
- **NFR9 (code size).** Footprint projected post-2.10: 4830-4930 B / ~94-96% / ~190-290 B headroom. Tighter than 2.9; Stories 2.11-2.13 will be the squeeze.
- **NFR18 (byte-identical rebuild).** Verify in Sub 8.1.

### Doubled-operator dispatch — replacing the stub

The Story 1.10 stub `parser_doubled_operator_stub` was deliberately atomic: it surfaced "not yet implemented" + cleared parser state in one shot, so its caller (`parser_handle_operator`) could JP into it without worrying about state coherence. Story 2.10's real dispatcher MUST preserve that atomicity from the caller's perspective:

- Entry: pending_operator is already set to the operator byte; count_accumulator MAY be non-zero (e.g., `5dd`); pending_motion_prefix is 0 (cleared on first parser_handle_operator entry by the AC11 clear-on-entry path).
- Body: read pending_operator; branch to op_dd / op_yy / msg_not_implemented.
- Tail (in each branch): op_dd / op_yy read count_accumulator FIRST (via motion_apply_count); execute; tail-JP parser_clear (which zeroes count, op, prefix). The msg_not_implemented branch keeps the existing "status set + parser_clear" shape.

**Critical state-discipline:** count_accumulator MUST be read BEFORE parser_clear runs. parser_clear's `LD HL, 0; LD (count_accumulator), HL` zeroes the count — if op_dd called parser_clear before motion_apply_count, `5dd` would deliver count=0 to op_dd which defaults to 1, silently breaking `5dd`. The motion_apply_count call sits AT THE TOP of op_dd / op_yy's body, well before the tail-JP parser_clear at the bottom. This matches the Story 2.6 motion_gg resolution (deferred-work.md:95).

A future "consistency cleanup" that factored parser_clear into a common prelude / "entry-clear" pattern would silently break `5dd` / `5yy` / `5dw` (Story 2.11 dependency). Document the constraint at op_dd / op_yy's contract block + at the dispatcher's contract block.

### Line-bounds — shared helpers and the no-trailing-LF edge

`motion_find_line_start` (src/motions.asm:601) and `motion_find_line_end` (src/motions.asm:637) are the existing primitives. Both preserve BC (so the yank-copy loop's byte-counter survives across them). `motion_find_line_end` returns `file_length` if no LF before EOF — this is the "last line, no trailing LF" signal that AC2's edge-case branch keys off of.

The line-bounds walk for counted dd/yy is a tight loop over `motion_find_line_end`:

```
;; Pseudocode for edits_line_range_for_count
;; In:  BC = N (count from motion_apply_count, defaulted to 1+)
;;      cursor_offset = C (current cursor)
;; Out: HL = delete_start, DE = delete_end, BC = total_bytes
;;      A != 0 if last_line_was_eof (so caller can apply the S-1 / S=0 adjustment)
edits_line_range_for_count:
    PUSH BC                          ; [N]
    LD HL, (cursor_offset)
    CALL motion_find_line_start      ; HL = S
    PUSH HL                          ; [N] [S]
    LD HL, (cursor_offset)
    ;; Walk N line-ends from cursor (or actually from S — let's walk from S to be canonical)
    LD HL, (start_of_walk)           ; pseudocode; reload from saved S
.walk:
    CALL motion_find_line_end        ; HL = E_k (may equal file_length)
    ;; Test for last_line_was_eof: motion_find_line_end returned HL=file_length AND
    ;; the byte at file_length (which doesn't exist) was not found as LF; the routine
    ;; gives CF=0 + HL=file_length on this case. Distinguishable from "found LF at offset
    ;; == file_length-1 happens to look like file_length"... actually motion_find_line_end
    ;; RETs early on CF=1 (past EOF) with HL=file_length. If it RETs on Z=1 (LF found), HL
    ;; points to the LF position. We can distinguish by re-checking the byte at HL after
    ;; the call, OR by saving the file_length and comparing HL to it.
    ;; ... implementation detail; the dev pass picks the cleanest shape.
    POP DE                           ; reload S; need to keep saved...
    ;; (full body omitted — this is sketch-level pseudocode)
```

The implementation detail of "how to detect motion_find_line_end's no-LF-found return shape" is the main subtlety. Three options:

1. **Save file_length once at entry; compare HL to file_length after each motion_find_line_end** (~5 B per iter overhead). Robust; no dependency on flags.
2. **Read motion_find_line_end's CF state** (per src/motions.asm:640 — `RET C` exits with CF=1 on past-EOF). But motion_find_line_end RETs without preserving CF on the LF-found path. So CF=1 means "past EOF, HL=file_length"; CF=0 means "LF found, HL=LF position". This is the natural shape; ~2 B per iter overhead (JR C, .eof_branch).
3. **Re-read the byte at HL with motion_byte_at_logical** (~5 T-states + ~2 B per iter; LF at HL means LF was found; CF=1 means past-EOF). Equivalent to (2) functionally but spends more cycles.

**Recommendation: option 2.** motion_find_line_end's CF-on-past-EOF return shape is already documented at src/motions.asm:625-636. The walk body keys off CF in a JR C / JR NZ pair — natural Z80 idiom.

### Yank-copy loop — reading pre-delete bytes

The yank-copy reads `total_bytes` bytes from logical offsets `[delete_start, delete_end)` via `motion_byte_at_logical` in a tight loop. The destination is the `yank_buffer` static address.

```
;; Pseudocode for edits_copy_to_yank
;; In:  HL = delete_start (logical), BC = total_bytes
;; Out: yank_kind := KIND_LINE, yank_length := total_bytes, yank_buffer[0..total_bytes-1] = bytes
;;      CF=0 on success; CF=1 on over-capacity (yank register UNCHANGED)
edits_copy_to_yank:
    ;; Capacity check: BC <= YANK_BUFFER_SIZE (1024)
    LD A, B
    CP HIGH(YANK_BUFFER_SIZE + 1)
    JR C, .within
    JR NZ, .over
    LD A, C
    CP LOW(YANK_BUFFER_SIZE + 1)
    JR NC, .over
.within:
    ;; Save BC (loop counter); set up DE = yank_buffer write pointer
    LD DE, yank_buffer
    PUSH BC                          ; [total_bytes]
    ;; Loop: read byte at logical HL, write to (DE), advance both
.copy_loop:
    PUSH BC                          ; gapbuf-internal calls trash BC (defensive — actually motion_byte_at_logical preserves BC per its contract; but yank-copy loop is the first new caller, doc-discipline pin)
    CALL motion_byte_at_logical      ; A = byte at logical HL; HL preserved
    POP BC
    LD (DE), A
    INC DE
    INC HL                           ; advance source logical offset
    DEC BC
    LD A, B
    OR C
    JR NZ, .copy_loop
    POP BC                           ; [total_bytes] = total_bytes (restored)
    LD (yank_length), BC
    LD A, KIND_LINE
    LD (yank_kind), A
    OR A                             ; clear CF
    RET
.over:
    SCF                              ; CF=1 = refused
    RET
```

(Pseudocode; the dev pass adapts to actual register conventions + shaves bytes where possible. Note: motion_byte_at_logical preserves BC per its existing contract at src/motions.asm:511-512, so the PUSH/POP BC inside the loop body is defensive doc-discipline; the dev pass MAY drop it after verifying the BC-preservation contract still holds in the final assembled code. Saves ~3 B per iter × 1024 worst case = wasteful only at the assembly level, but the per-iter PUSH/POP adds ~20 T-states × 1024 = 20000 T-states = 5 ms — pushing the 1024-byte yank past 10 ms. **Drop the PUSH/POP BC inside the loop in the final implementation;** doc-comment the contract dependency at the call site.)

### Range-delete loop

```
;; Pseudocode for edits_range_delete (Option A from AC8)
;; In:  HL = delete_start, BC = total_bytes
;; Out: cursor_offset = delete_start; total_bytes bytes removed; gapbuf state consistent
edits_range_delete:
    ;; Pre-stage cursor: cursor := delete_start + total_bytes
    LD DE, HL
    ADD HL, BC                       ; HL = delete_end
    LD (cursor_offset), HL
    ;; Loop: total_bytes iterations of gapbuf_delete
.del_loop:
    PUSH BC                          ; gapbuf_delete trashes BC
    CALL gapbuf_delete               ; consumes byte at logical (cursor - 1); decrements cursor
    POP BC
    DEC BC
    LD A, B
    OR C
    JR NZ, .del_loop
    ;; Post-loop: cursor_offset has been decremented total_bytes times by gapbuf_delete
    ;; → cursor is now at delete_start (the original entry HL). No explicit set needed.
    RET
```

The yank-copy reads happen BEFORE the range-delete (per AC8 order of operations) so the source bytes are still in the gap buffer at their original logical positions when motion_byte_at_logical reads them.

### Post-delete cursor placement

After `edits_range_delete`, cursor sits at `delete_start`. The AC2 / AC3 placement rule:

1. If `new_file_length == 0`: cursor = 0 (buffer empty). [Implicit: delete_start was 0 if buffer is now empty; no special handling needed.]
2. If `delete_start < new_file_length`: cursor = delete_start (the "what was the next line" position). [Already true after edits_range_delete.]
3. Else (`delete_start >= new_file_length`; we deleted to file end AND there's still content above): cursor = motion_find_line_start(new_file_length - 1). [Need to compute.]

Case 3 is the "dd on the last line of a multi-line file" case. After edits_range_delete, cursor = delete_start = old line's S - 1 (if S>0; AC2's last-line-no-LF + S>0 branch) = new file's last LF position. Going to motion_find_line_start(new_file_length - 1) walks back from the byte before the new EOF (the last printable byte of the new last line) to its line start.

```
;; Pseudocode post-delete:
LD HL, (cursor_offset)           ; HL = delete_start (set by edits_range_delete)
;; Compute new file_length from gap state
;; file_length = (gap_start - GAP_BUFFER_BASE) + (GAP_BUFFER_BASE + GAP_BUFFER_MAX - gap_end)
;; Or equivalently: file_length = GAP_BUFFER_MAX - (gap_end - gap_start)
;; Or: read motion_byte_at_logical(cursor); if CF=1, cursor >= file_length, fall to case 3.
CALL motion_byte_at_logical      ; A = byte at cursor; CF=1 if past EOF
JR NC, .commit                   ; cursor < file_length (case 2) — done
;; Case 1 or 3: cursor >= new_file_length. Check if buffer is empty.
LD HL, 0
LD (cursor_offset), HL           ; default to 0 for case 1
;; Now check case 3: if file_length > 0, walk back to find new last line start
;; (motion_byte_at_logical(0); if CF=1, file is empty → cursor=0 is correct (case 1))
CALL motion_byte_at_logical      ; A = byte at 0; CF=1 if buffer empty
JR C, .commit                    ; case 1: buffer empty, cursor=0
;; Case 3: file has content; cursor = motion_find_line_start(file_length - 1)
;; ... (full case-3 handling; ~10-15 B)
.commit:
    ;; cursor_offset is now the correct post-delete position
```

The dev pass can refactor / shrink this; the bones are the same.

### Counted dd vs counted yy — symmetry

op_dd and op_yy share the line-bounds walk + the yank-capacity check + the yank-copy step. Only op_dd additionally does the range-delete + cursor reposition + dirty-mark. **Factor the shared body into helpers.** The Sub 2.1 / 2.2 helpers (edits_line_range_for_count + edits_copy_to_yank) ARE that factoring. After helpers exist, op_dd's body shrinks to ~50-70 B and op_yy's body shrinks to ~30-50 B.

### Library / framework requirements

- **No new library / framework.** Story 2.10 is sjasmplus + iz-cpm only, like every story in this epic.
- **No new sjasmplus idioms.** Existing patterns suffice (DEFB / DEFW / ASSERT / EQU / INCLUDE / LDIR / `$` for current address; the `HIGH()` / `LOW()` macros from inc/equates.inc for the YANK_BUFFER_SIZE high-byte / low-byte split in the capacity check).
- **No new module.** op_dd / op_yy / helpers live in the existing `src/edits.asm`. parser_doubled_operator stays in `src/parser.asm` (rewritten in-place). msg_yank_too_large goes in `src/statusln.asm`. KIND_* equates go in `inc/equates.inc`.

### Filename and module placement choices

- **op_dd and op_yy live in `src/edits.asm`** alongside x / i / a / o / O / Backspace / literal / Enter. AR25 INCLUDE chain unchanged.
- **No new public symbols outside `op_dd`, `op_yy`, and the optional internal helpers `edits_line_range_for_count` / `edits_copy_to_yank` / `edits_range_delete`.** The helpers MAY be implementation-detail private (prefix with `.` or live inside an `IFDEF` block; sjasmplus syntax-dependent) OR public (preferred — the AR23 contract block makes them part of the module's documented surface, and Story 2.11 may want to call them).
- **Test naming convention.** Files under `test/cases/edits_dd-*.asm`, `test/cases/edits_yy-*.asm`, `test/cases/parser_doubled-operator-*.asm`. Matches Story 2.5..2.9 per-handler-grouped pattern.
- **Test sentinel allocation.** Continue Story 2.5 / 2.6 / 2.7 / 2.8 / 2.9 sentinel range 0x80..0x87 per test.

### Previous story intelligence

**From [[story-2-9-single-character-delete-x]] (single-character delete; the immediate predecessor — the deletion-class pattern):**
- `edits.asm` is the established home for edit handlers (lines 1-180 module header established Story 2.8, extended by 2.9). Extending the Public list + adding per-entry contract blocks per AR23 is the documented pattern.
- The `edits_dirty_and_redraw` shared helper (edits.asm:500) is reusable: `LD A, 1; LD (buffer_dirty), A; JP render_mark_all_dirty`. Story 2.10's op_dd success-tail uses this.
- The `parser_clear` tail-JP shape (every motion / edit handler ends with `JP parser_clear`) is established; op_dd / op_yy follow it.
- **Cursor-bounce gapbuf_delete pattern** (Story 2.9 AC8) — generalised in Story 2.10's edits_range_delete helper (Option A from AC8). The same PUSH/POP BC bracketing per iter handles the count counter.
- **BH2 stop-at-LF for counted x** (Story 2.9 AC4) — Story 2.10's counted dd has a DIFFERENT semantic: dd CROSSES line boundaries (deleting whole lines), so the line-bounds walk explicitly traverses LFs. The Story 2.9 BH2 doesn't apply at the byte level; the line-granularity BH2 (stop at last line) applies at the line level. Per-op divergence is the documented pattern (Story 2.9 deferred-work.md:305-307).
- **`5x` ↔ counted dd**: Story 2.9's `5x` from BOL on a 3-char line stops at LF (cursor on LF — invariant violation, accepted as vi-faithful). Story 2.10's `5dd` on a 3-line file deletes all 3 lines and stops (BH2-line-level clamp). NO cursor-on-LF issue because dd consumes the LF as part of the line.

**From [[story-2-8-insert-mode]] (INSERT mode; established the edits.asm module pattern):**
- `edits.asm` module header pattern + per-entry contract blocks per AR23.
- Tail-JP `parser_clear` from every edit handler.
- `edits_dirty_and_redraw` shared helper.

**From [[story-2-7-counted-motions]] (counted motions; verified end-to-end):**
- `motion_apply_count` is the count-default helper (BC=count, default 1 if 0). Used by every counted-form handler. Story 2.10's op_dd / op_yy use it.
- Sticky-column hoist is not applicable here (line-granularity ops don't have a column concept).
- **Test fixture lesson** — when designing tests to pin "deleted N lines" or "yanked N lines", make sure the by-1 outcome differs from the by-N outcome (per Story 2.7 code-review patch P1). E.g., `edits_dd-counted-3lines.asm` uses count=3 on a 5-line file → buffer becomes 2 lines (clearly distinguishable from count=1 → 4 lines).

**From [[story-2-6-word-line-buffer-motions]] (helpers and the motion-prefix dispatch):**
- `motion_find_line_start` and `motion_find_line_end` are the line-bounds primitives. Both preserve BC. Story 2.10's edits_line_range_for_count uses both.
- **The motion_gg state-read-before-clear resolution** (deferred-work.md:95) — Story 2.6 demonstrated the pattern. Story 2.10 follows it: op_dd / op_yy read count_accumulator FIRST, then execute, then tail-JP parser_clear.
- `motion_byte_at_logical` is the BC-preserving byte-read primitive. Story 2.10's yank-copy loop uses it (with the PUSH/POP BC drop noted above as a future shave).

**From [[story-2-5-basic-motions]] (basic motions + AC13 parser_clear hygiene):**
- The "every dispatch path clears parser state" invariant (AC13). op_dd / op_yy / parser_doubled_operator's c/>/< fall-through arm all uphold this.

**From [[story-2-4-file-save]] / [[story-2-2-file-load]] / [[story-2-1-ex-command-line]] (the ex-line + file-IO infrastructure):**
- `:w` / `:q` / `:e` continue to work unchanged. Story 2.10 doesn't touch fileio.asm or exline.asm.
- `buffer_dirty` is the source-of-truth flag. op_dd sets it (1 new write site); op_yy does NOT touch it.

**From [[story-1-10-parser]] (parser — the doubled-operator detection that this story finally exercises):**
- `parser_handle_operator` detects doubled-operator at src/parser.asm:325-332. Stores pending_operator on first press; JPs to `parser_doubled_operator_stub` on second press. Story 2.10 replaces the stub body.
- `parser_dispatch`'s tail-JP `parser_clear` shape is the precedent. op_dd / op_yy are NOT dispatched via parser_dispatch (no operator+motion compose here — that's Story 2.11). They're JP'd directly from the dispatcher. So the parser_clear tail-JP is the handler's own responsibility (not handled by a parser_dispatch trampoline).
- `pending_operator` survives the first→second operator press only when both are the same character (the doubled case). Mixed operators (e.g., 'd' then 'y') go through `.first_operator` arm (last-operator-wins per src/parser.asm:303-306). So when parser_doubled_operator runs, pending_operator IS the operator we want.

**From [[story-1-9-mode-dispatch]] (dispatch tables):**
- `dispatch_normal`'s 'd' / 'y' / 'c' / '>' / '<' all route to `parser_handle_operator` (src/dispatch.asm:500-555). Story 2.10 doesn't add new dispatch entries — the existing operator-bind shape suffices.

**From [[story-1-7-gap-buffer]] (gap buffer primitives):**
- `gapbuf_delete` is the AR14 mutation surface. Story 2.10's range-delete loop calls it N times. The cursor-bounce shape from Story 2.9 generalises naturally.
- `gapbuf_move_gap` is internal to gapbuf primitives. The range-delete loop's first iter relocates the gap to delete_end (transparently called by gapbuf_delete); subsequent iters find the gap in place.

**From [[story-1-5-status-line]] / statusln.asm conventions:**
- `status_set_message` is the AR12 funnel. msg_yank_too_large lives in the strings block; called with `LD HL, msg_yank_too_large; XOR A; CALL status_set_message`. Standard pattern.

**From [[story-1-3-static-memory-map]]:**
- yank_kind (state.inc:54), yank_length (state.inc:76), yank_buffer (state.inc:132) all declared. No state.inc patches needed.

**From [[story-1-2-compile-time-constants]] / [[story-1-1-project-skeleton]]:**
- equates.inc is the home for compile-time knobs (NFR16). KIND_CHAR / KIND_LINE / KIND_BLOCK go here.

### Git intelligence

Recent commits (post-Story 2.7):

- `94b4f16 story 2.9: x deletes char under cursor; counted Nx with EOL/EOF clamp` — Story 2.9 dev pass (single-character delete; the immediate predecessor).
- `fdd2d10 social media preview image` — Non-dev cosmetic commit.
- `57325ff story 2.8: INSERT mode lands; i/a/o/O, typing, backspace, Enter→LF, Esc` — Story 2.8 dev pass (the i/a/o/O + INSERT-mode infrastructure that op_dd / op_yy don't directly use but inherit edits.asm patterns from).
- `425bc2e code review changes` — Story 2.7 code review.
- `be63514 story 2.7: counted motions verified end-to-end; sticky-column j/k landed` — Story 2.7 dev pass (counted motions; motion_apply_count established here).

Patterns to follow:
- Single dev-commit per story containing the production code + tests + spec + sprint-status flips (the Story 2.5 / 2.6 / 2.7 / 2.8 / 2.9 model).
- Separate code-review commit (`425bc2e`) applying review patches.
- Sentinel byte at `0xCFFE` per TH1 (test/inc/test_prologue.inc).
- INCLUDE chain in test cases: pre-ORG headers (equates/bios/bdos/modes/vt52), then `test_prologue.inc`, test body, `test_epilogue.inc`, production sources (statusln/gapbuf/render/dispatch/parser/motions/edits/exline/fileio), `test_teardown_stub.inc` + `test_input_loop_stub.inc`, finally `inc/state.inc`.
- Gap-buffer fixture pattern: `CALL gapbuf_init` → LDIR from `.payload` into `GAP_BUFFER_BASE` → set `gap_start := GAP_BUFFER_BASE + N`. Mode pre-set via `LD A, MODE_NORMAL ; LD (mode_byte), A` for op_dd / op_yy tests (NORMAL-mode handlers).
- Yank-register pre-seed for "verify nothing changed on refusal" tests: `LD A, 0xEE ; LD (yank_kind), A ; LD HL, 0xCAFE ; LD (yank_length), HL` — distinctive non-KIND_LINE non-zero values so any accidental write surfaces in the post-test sentinel check.

### Testing requirements

- All ~16 new tests under `test/cases/edits_dd-*.asm` / `test/cases/edits_yy-*.asm` / `test/cases/parser_doubled-operator-*.asm`. Each test must build under `make -C test`, run under iz-cpm with the 5-second timeout, and report PASS via TH1 / TH2.
- The dispatch-chain tests (parser_doubled-operator-routes-to-dd / -to-yy / -to-not-implemented) need `mode_byte = MODE_NORMAL` and pre-seed `pending_operator` to mid-state (simulating that the first operator press already happened) OR drive `parser_handle_operator` twice in sequence within the test body (cleaner — pins the full chain). The two-press approach is preferred (matches the Story 1.10 parser-test convention).
- Tests that drive directly via `CALL op_dd` / `CALL op_yy` exercise the handler body in isolation (no parser-chain coverage; pins the AC2-AC5 semantics). These are the bulk of AC12.
- Tests that drive via the parser chain (parser_doubled-operator-routes-to-*) pin the AC1 wiring end-to-end.
- One test (parser_5dd-counted-via-parser-handle-operator) drives the FULL count-then-operator-twice chain — pins the "count survives operator, doubled-op reads count, clears after" cross-cut from deferred-work.md:93-94.
- Tests that pin yank capacity refusal pre-seed `yank_kind` and `yank_length` to non-KIND_LINE / non-matching values; assert these are UNCHANGED post-call.
- Tests for the no-LF last-line edge use specifically-crafted fixtures (`"a"` for single-char buffer; `"a\nb\nc"` for multi-line + no-trailing-LF; etc.).
- Sentinel allocation per test per the Story 2.5..2.9 convention.

### Project Structure Notes

- **No new source files.** Story 2.10 extends `src/edits.asm`, `src/parser.asm`, `src/statusln.asm`, `inc/equates.inc` only.
- **No new inc/*.inc files.** All constants in `equates.inc`; all state cells already declared in `state.inc`.
- **Two new public symbols:** `op_dd`, `op_yy` (added to src/edits.asm). Optionally `edits_line_range_for_count` / `edits_copy_to_yank` / `edits_range_delete` if factored — implementation choice with rationale.
- **One renamed (or in-place rewritten) symbol:** `parser_doubled_operator_stub` becomes a real dispatcher. If renamed to `parser_doubled_operator`, update the call site at src/parser.asm:332 (`JP parser_doubled_operator_stub`) accordingly.
- **dispatch_normal UNCHANGED** at 33 entries.
- **dispatch_insert / dispatch_command / dispatch_visual** unchanged.
- **`state.inc` UNCHANGED.** All needed cells (`yank_kind`, `yank_length`, `yank_buffer`, `pending_operator`, `count_accumulator`, `cursor_offset`, `buffer_dirty`) already declared.
- **`src/vibe.asm` INCLUDE chain unchanged.**
- **~16 new test files** under `test/cases/edits_dd*.asm` + `test/cases/edits_yy*.asm` + `test/cases/parser_doubled-operator-*.asm`.

### Source tree paths touched

```
.
├── src/
│   ├── edits.asm             # UPDATE — add `op_dd`, `op_yy` public entries; optional internal helpers; module-header docstring extended
│   ├── parser.asm            # UPDATE — replace `parser_doubled_operator_stub` body with real dispatcher (or rename + add new symbol)
│   └── statusln.asm          # UPDATE — add `msg_yank_too_large` string + Public list update
├── inc/
│   └── equates.inc           # UPDATE — add KIND_CHAR / KIND_LINE / KIND_BLOCK constants
├── _bmad-output/
│   ├── planning-artifacts/   # UNCHANGED
│   └── implementation-artifacts/
│       ├── 2-10-doubled-operator-commands-dd-yy.md   # THIS FILE
│       ├── deferred-work.md                          # UPDATE (Task 9)
│       └── sprint-status.yaml                        # UPDATE (status flips backlog → ready-for-dev → in-progress → review → done)
└── test/
    └── cases/
        ├── edits_dd-deletes-line.asm                                  # NEW (canonical)
        ├── edits_yy-copies-line.asm                                   # NEW (canonical)
        ├── edits_dd-counted-3lines.asm                                # NEW (canonical)
        ├── edits_dd-yank-too-large.asm                                # NEW (canonical)
        ├── edits_dd-last-line-no-trailing-lf.asm                      # NEW
        ├── edits_dd-only-line.asm                                     # NEW
        ├── edits_dd-empty-buffer.asm                                  # NEW
        ├── edits_yy-yank-too-large.asm                                # NEW
        ├── edits_dd-counted-clamps-at-eof.asm                         # NEW
        ├── edits_dd-yank-kind-line.asm                                # NEW
        ├── edits_yy-yank-kind-line.asm                                # NEW
        ├── edits_dd-clears-parser-state.asm                           # NEW
        ├── edits_yy-clears-parser-state.asm                           # NEW
        ├── parser_doubled-operator-routes-to-dd.asm                   # NEW
        ├── parser_doubled-operator-routes-to-yy.asm                   # NEW
        ├── parser_doubled-operator-routes-to-not-implemented.asm      # NEW
        ├── parser_5dd-counted-via-parser-handle-operator.asm          # NEW
        ├── edits_dd-cursor-on-middle-line.asm                         # NEW
        └── edits_dd-cursor-mid-line.asm                               # NEW
```

(19 test slots; the dev pass MAY drop 1-3 if their coverage is fully subsumed by sibling tests — document drops + rationale per the Story 2.9 pattern.)

### Files to be created and modified by this story

**New:**
- `test/cases/edits_dd-deletes-line.asm` (canonical)
- `test/cases/edits_yy-copies-line.asm` (canonical)
- `test/cases/edits_dd-counted-3lines.asm` (canonical)
- `test/cases/edits_dd-yank-too-large.asm` (canonical)
- ~12-15 additional test files per AC12 / Source tree paths above

**Modified:**
- `src/edits.asm` — `op_dd` + `op_yy` public entries added (~120-160 B + ~50-80 B); optional internal helpers; module-header Public list + per-entry contract blocks extended per AR23; Purpose / State owned / Dependencies blocks updated.
- `src/parser.asm` — `parser_doubled_operator_stub` body replaced with real dispatcher (~25-40 B); module-header docstring updated to drop the stub-handler description.
- `src/statusln.asm` — `msg_yank_too_large` string added (~16 B); Public list updated.
- `inc/equates.inc` — `KIND_CHAR` / `KIND_LINE` / `KIND_BLOCK` constants added (~0 B at runtime; compile-time only); Public list updated.
- `_bmad-output/implementation-artifacts/deferred-work.md` — Story 2.10 deferred entries per Task 9.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — 2-10 status flips (backlog → ready-for-dev → in-progress → review → done).
- `_bmad-output/implementation-artifacts/2-10-doubled-operator-commands-dd-yy.md` — this file (Tasks checkboxes, Dev Agent Record, File List, Change Log, Status).

### References

- FR29 (the primary load-bearing FR — dd deletes the current line): [Source: _bmad-output/planning-artifacts/prd.md] line 745
- FR31 (the secondary load-bearing FR — yy yanks the current line): [Source: _bmad-output/planning-artifacts/prd.md] line 747
- FR40 (doubled-operator dispatch — wired by Story 1.10; this story replaces the stub with real handlers): [Source: _bmad-output/planning-artifacts/prd.md / architecture.md doubled-operator section]
- FR45 (undo coverage — STUB in 2.10, full impl in 2.13): [Source: _bmad-output/planning-artifacts/prd.md] line 778
- FR46 (undo unavailability surfacing): [Source: _bmad-output/planning-artifacts/prd.md] line 779
- FR50 (unsupported commands as no-op — c/>/< doubled forms surface msg_not_implemented): [Source: _bmad-output/planning-artifacts/prd.md] line 793
- FR52 (no silent data loss — dd deletion is intentional, not a silent loss; user can `:q` to abandon): [Source: _bmad-output/planning-artifacts/prd.md] lines 799-801
- SR6 (yank register — protocol; predictable failure on over-capacity; this story is the FIRST writer): [Source: _bmad-output/planning-artifacts/architecture.md] lines 456-461
- NFR1 / NFR2 / NFR3 (interactive feedback; sustained typing; cursor-motion latency): [Source: _bmad-output/planning-artifacts/prd.md] line 108 + 820-824
- NFR9 (code size budget — 5120 B ceiling): [Source: _bmad-output/planning-artifacts/prd.md] lines 848-858
- NFR16 (compile-time knobs in equates.inc; KIND_* equates added here): [Source: _bmad-output/planning-artifacts/architecture.md] line 1088
- NFR18 (byte-identical rebuild): verified by `make clean && make all`
- BH2 (counted-motion clamps — line-level analog for counted dd / yy stop-at-eof): [Source: _bmad-output/planning-artifacts/prd.md / architecture.md] BH2 boundary handling section
- MC3 (binary-search dispatch — unchanged at 33 entries): [Source: _bmad-output/planning-artifacts/architecture.md] lines 485-527
- MC4 (handler signature — A=key on entry; state via state.inc symbols): [Source: _bmad-output/planning-artifacts/architecture.md] line 1502+
- AR12 / AR13 / AR14 / AR15 (architectural boundaries; edits.asm extends with two more clean handlers + parser.asm extends with one): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1434-1463
- AR23 (module header contracts): [Source: src/edits.asm:1-233 + src/motions.asm:1-146 + src/parser.asm:1-147 header blocks as exemplars]
- AR25 (INCLUDE chain in vibe.asm): [Source: src/vibe.asm + architecture.md:918-956]
- [[story-2-9-single-character-delete-x]] (the immediate predecessor — single-character delete shape; counted-form pattern; cursor-bounce shape; FR45 stub pattern): [Source: _bmad-output/implementation-artifacts/2-9-single-character-delete-x.md]
- [[story-2-8-insert-mode]] (edits.asm module pattern; edits_dirty_and_redraw shared helper; B2 stub pattern): [Source: _bmad-output/implementation-artifacts/2-8-insert-mode-i-a-o-o.md]
- [[story-2-7-counted-motions]] (motion_apply_count; counted-form regression patterns): [Source: _bmad-output/implementation-artifacts/2-7-counted-motions.md]
- [[story-2-6-word-line-buffer-motions]] (motion_find_line_start / motion_find_line_end / motion_byte_at_logical helpers; motion_gg state-read-before-clear precedent): [Source: _bmad-output/implementation-artifacts/2-6-word-line-buffer-motions-w-b-0-gg-g.md]
- [[story-2-5-basic-motions]] (basic motions + AC13 parser_clear hygiene patches): [Source: _bmad-output/implementation-artifacts/2-5-basic-motions-h-j-k-l.md]
- [[story-2-4-file-save]] (buffer_dirty source-of-truth flag): [Source: _bmad-output/implementation-artifacts/2-4-file-save-w-w-filename-wq.md]
- [[story-2-2-file-load]] (gap-buffer init from disk; first-edit-after-load gap relocation): [Source: _bmad-output/implementation-artifacts/2-2-file-load-via-e-filename-incl-e.md]
- [[story-2-1-ex-command-line-q-q]] (ex-line `:q` / `:q!` — used in AC7 hardware UAT steps 9-10): [Source: _bmad-output/implementation-artifacts/2-1-ex-command-line-infrastructure-q-q.md]
- [[story-1-10-parser]] (parser_handle_operator + parser_doubled_operator_stub the body of which Story 2.10 replaces; deferred-work.md:93-94 heads-up on state-read-before-clear): [Source: src/parser.asm:1-147 + 317-465 + _bmad-output/implementation-artifacts/deferred-work.md lines 93-95]
- [[story-1-9-mode-dispatch]] (dispatch_normal table — 'd' / 'y' / 'c' / '>' / '<' bound to parser_handle_operator since 1.9 / 1.10): [Source: src/dispatch.asm:455-556]
- [[story-1-7-gap-buffer]] (gapbuf_delete BOF guard; cursor-bounce shape from Story 2.9; gap-stays-in-place after first delete): [Source: src/gapbuf.asm:131-180]
- [[story-1-5-status-line]] (status_set_message AR12 funnel; msg_yank_too_large added per AC11): [Source: src/statusln.asm]
- [[story-1-3-static-memory-map]] (yank_kind / yank_length / yank_buffer / yank_end already declared): [Source: inc/state.inc:54 + 76 + 132-133]
- [[story-1-2-compile-time-constants]] (YANK_BUFFER_SIZE = 1024 already declared; KIND_* equates added per AC10): [Source: inc/equates.inc:40]
- deferred-work.md line 93-95 ("Stubs tail-JP parser_clear before count/operator can be captured by future real handlers" + RESOLVED-FOR-GG-BY-2.6 + "Doubled-operator arm remains pending for Story 2.10"): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 93-98
- deferred-work.md line 305-307 (BH2 stop-at-LF semantic for counted x — note for Stories 2.10 / 2.11 to document per-op divergence): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 305-307
- Epic 2 spec — Story 2.10 ACs and the cross-story context (2.11 dw/d$/c5w/y3j + 2.12 paste(p) + 2.13 undo(u) all depend on this story's yank-register-protocol + line-bounds infrastructure): [Source: _bmad-output/planning-artifacts/epics.md] lines 1291-1480

## Dev Agent Record

### Agent Model Used

claude-opus-4-7[1m]

### Debug Log References

- Initial implementation of `edits_copy_to_yank` had a register-clobber bug: `motion_byte_at_logical` is documented as trashing DE (it loads `DE = GAP_BUFFER_BASE` on the `.before_gap` return path), but the loop used DE as the destination pointer. Fixed by adding PUSH/POP DE bracketing across each `motion_byte_at_logical` call inside `.copy_loop`. Caught by `edits_dd-deletes-line.asm` (the first canonical test); fix verified by re-running.
- Initial epic test description for `edits_yy-copies-line.asm` (epic line 1335) claimed `yank_length=3` ("def") for `yy` on `"abc\ndef"` cursor=4. That contradicts AC4 body ("the yank-target range is the SAME range that `op_dd` would delete") plus AC12 footnote (yank holds the deleted bytes verbatim, including the cross-line LF). Followed the AC4 body (load-bearing): yy's range matches dd's range = [3, 7) = "\ndef" = 4 bytes. Test updated to assert `yank_length=4`; rationale documented in test header + deferred-work.md.

### Completion Notes List

- All 13 ACs satisfied per the dev pass; hardware UAT (AC7) deferred to Ant per the Story 2.5..2.9 pattern.
- Build size: 4580 → 4793 B (Δ+213 B / 93.6% of 5120 B / 327 B headroom). Came in BELOW the spec projection of +250-350 B thanks to the shared-helper factoring decision (Sub 2.4 chose to factor `edits_line_range_for_count` / `edits_copy_to_yank` / `edits_range_delete` rather than inline — saved ~50-80 B as projected).
- NFR18 byte-identical rebuild confirmed: two consecutive `make clean && make all` produced SHA `e8d38610c0a7eeaf3777e1998ecdaee6`.
- AR sweeps clean: zero `BIOS_CONOUT` / direct `gap_start`/`gap_end` write / `BDOS_CALL` code refs in `src/edits.asm` + `src/parser.asm` (only doc-comment refs in the module-header blocks). `CALL gapbuf_delete` code-ref count in edits.asm grew from 2 → 3 (edits_insert_backspace + edits_delete_char + edits_range_delete). `msg_yank_too_large` code refs: 2 (op_dd's yank-refused arm + op_yy's yank-refused arm) + doc-comment refs.
- `DISPATCH_NORMAL_COUNT` confirmed unchanged at 33 (build/vibe.lst: `LD B, DISPATCH_NORMAL_COUNT` → `06 21`).
- Test pass count: 118 → 134 pass / 1 deliberate-fail. 16 new tests landed (4 canonical from epics line 1335 + 12 additional). 3 tests dropped from the AC12 enumeration as fully subsumed (per AC12 footnote): `edits_dd-yank-kind-line.asm` (subsumed by `edits_dd-deletes-line.asm`), `edits_yy-yank-kind-line.asm` (subsumed by `edits_yy-copies-line.asm`), `edits_yy-clears-parser-state.asm` (subsumed by `edits_dd-clears-parser-state.asm` + `parser_doubled-operator-routes-to-yy.asm`).
- Existing `parser_doubled-operator-dd.asm` test (Story 1.10) updated, not replaced: Subtest 2 / 3 / 5 status_dirty=1 assertions dropped (the Story 1.10 stub set status_dirty when surfacing `msg_not_implemented`; the new dispatcher routes those branches to op_dd / op_yy on the empty-buffer state, which JP parser_clear silently). Gap-buffer init added to prevent uninitialised-memory walk. Parser-state-cleared assertions are unchanged — load-bearing for the doubled-op contract.
- FR45 undo recording for op_dd is a STUB; hook site documented in deferred-work.md (BEFORE edits_copy_to_yank, so undo records from original gap-buffer positions independent of yank capacity).
- AC1 implementation choice: kept symbol name `parser_doubled_operator_stub` (rewrote body in place) for AR25 INCLUDE-chain stability — no caller-site update at parser_handle_operator's `JP parser_doubled_operator_stub` line.
- AC10 implementation choice: KIND_CHAR=0x00, KIND_LINE=0x01, KIND_BLOCK=0x02 (numeric form). Rationale: KIND_CHAR=0 matches the natural init_cold_start zero-fill state; an uninitialised yank register reads as the natural default character-wise kind. Rationale documented in inc/equates.inc.
- AC8 implementation choice: Option A (cursor-bounce N-iter `gapbuf_delete` loop) chosen over Option B (new `gapbuf_delete_range` primitive). AR14-clean; per-iter cost amortises after first call. Trade-off documented in deferred-work.md.
- State-read-before-clear discipline (deferred-work.md:93-94 / Story 2.6 motion_gg precedent) honoured: op_dd / op_yy both read count_accumulator (via motion_apply_count, transitively inside edits_line_range_for_count) BEFORE the tail-JP parser_clear at their respective ends. Tested end-to-end by `parser_5dd-counted-via-parser-handle-operator.asm` — a regression that factored parser_clear into a common prelude would deliver count=0 (defaulted to 1) and that test would catch the yank_length mismatch (1 line yanked instead of 5).

### File List

**New:**
- `test/cases/edits_dd-deletes-line.asm` (canonical AC2)
- `test/cases/edits_yy-copies-line.asm` (canonical AC4; yank_length corrected to 4 per AC4 body)
- `test/cases/edits_dd-counted-3lines.asm` (canonical AC3)
- `test/cases/edits_dd-yank-too-large.asm` (canonical AC2 over-capacity)
- `test/cases/edits_dd-last-line-no-trailing-lf.asm` (AC2 S>0 + last-line-no-LF)
- `test/cases/edits_dd-only-line.asm` (AC2 single-line buffer)
- `test/cases/edits_dd-empty-buffer.asm` (AC2 no-op path)
- `test/cases/edits_yy-yank-too-large.asm` (AC4 over-capacity)
- `test/cases/edits_dd-counted-clamps-at-eof.asm` (AC3 BH2-line clamp)
- `test/cases/edits_dd-clears-parser-state.asm` (AC1 parser_clear hygiene)
- `test/cases/edits_dd-cursor-on-middle-line.asm` (AC2 middle-line case)
- `test/cases/edits_dd-cursor-mid-line.asm` (AC2 mid-column cursor)
- `test/cases/parser_doubled-operator-routes-to-dd.asm` (AC1 end-to-end dd routing)
- `test/cases/parser_doubled-operator-routes-to-yy.asm` (AC1 end-to-end yy routing)
- `test/cases/parser_doubled-operator-routes-to-not-implemented.asm` (AC1 c/>/< fall-through)
- `test/cases/parser_5dd-counted-via-parser-handle-operator.asm` (AC1 + AC3 5dd state-read-before-clear)

**Modified:**
- `src/edits.asm` — added `op_dd` (FR29) + `op_yy` (FR31) public entries; added internal helpers `edits_line_range_for_count` / `edits_copy_to_yank` / `edits_range_delete`; module-header docstring extended (Purpose / Public / State owned / Architectural enforcement / Dependencies blocks updated for Story 2.10).
- `src/parser.asm` — rewrote `parser_doubled_operator_stub` body as a real dispatcher (kept symbol name for AR25 INCLUDE-chain stability); module-header docstring updated (stub-handler description replaced; dispatcher contract block; statusln + edits dependencies noted).
- `src/statusln.asm` — added `msg_yank_too_large: DEFB "yank too large", 0` to the strings block; module-header Public list updated.
- `inc/equates.inc` — added `KIND_CHAR` / `KIND_LINE` / `KIND_BLOCK` 1-byte numeric equates with rationale block; module-header Public list updated.
- `test/cases/parser_doubled-operator-dd.asm` — updated for Story 2.10 dispatcher (Subtest 2 / 3 / 5 status_dirty=1 assertions dropped; gap-buffer init added). Parser-state-cleared assertions unchanged.
- `_bmad-output/implementation-artifacts/deferred-work.md` — added Story 2.10 entries (FR45 undo hook; AC8 Option A/B trade-off; AC2 last-line-no-LF + S>0 yank semantic + Story 2.12 paste handler note; KIND_* encoding choice; 3 dropped tests rationale; parser_doubled-operator-dd test update rationale).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — 2-10 status flipped ready-for-dev → in-progress → review.
- `_bmad-output/implementation-artifacts/2-10-doubled-operator-commands-dd-yy.md` — this file (Tasks/Subtasks checked; Dev Agent Record / File List / Change Log filled; Status flipped to `review`).

### Change Log

| Date       | Change | Notes |
|------------|--------|-------|
| 2026-05-16 | Story 2.10 created from epics line 1291 | Initial draft; status `ready-for-dev`. 13 ACs, 10 tasks, ~16-19 headless tests + 13-step hardware UAT. New public entries `op_dd` and `op_yy` land in existing `src/edits.asm` (no new module). `parser_doubled_operator_stub` body replaced with real dispatcher in `src/parser.asm` (Story 1.10 stub promoted to real). Three new compile-time constants (`KIND_CHAR` / `KIND_LINE` / `KIND_BLOCK`) added to `inc/equates.inc`. One new status string (`msg_yank_too_large`) added to `src/statusln.asm`. AC8 (range-delete via N-iteration cursor-bounce gapbuf_delete loop) chosen over the new-gapbuf-primitive option for AR14-cleanliness + edits.asm-local-blast-radius + the cost-amortisation argument (gapbuf stays in place after first call). AC3 (counted dd line-bounds walk with last-line-no-LF + S>0 / S==0 BH2-line-level clamp) is the most algorithmically interesting AC. AC6 (FR45 undo recording) is a STUB for 2.10; full impl in 2.13 — hook site documented (BEFORE edits_copy_to_yank, so undo records from original gap-buffer positions independent of yank capacity). NFR9 projected post-2.10 4830-4930 B / ~94-96% of 5120 B / ~190-290 B headroom — tight but feasible; Story 2.11 will be the real squeeze. Doubled-operator dispatcher (parser_doubled_operator) reads pending_operator + count BEFORE tail-JP parser_clear per the deferred-work.md:93-94 / Story 2.6 motion_gg precedent — the state-read-before-clear discipline. |
| 2026-05-16 | Hardware UAT confirmed by Ant — story stays at `review` pending code-review pass | All 13 AC7 steps functionally pass on real MicroBeast (`dd` / `3dd` / `yy` / dd-on-last-line / dd-on-only-line + persistence via `:w` + reload). One spec-narrative error surfaced (NOT a functional bug): AC7 steps 4 / 12 / 13 describe rows showing a `~` empty-line marker for past-EOF rows. Ant confirms no `~` marker has ever appeared in any VIBE session — by design. `src/render.asm`'s `render_byte_at_logical.past_eof` (line 537-540) returns `A = 0x20` (space) for past-EOF cells; there is no tilde-marker code path. No planning artifact requires a `~` marker — the borrowed-from-vim convention in the AC7 narrative was unfounded. Functional UAT behavior was correct (empty buffer / cursor at 0 / no crash / recoverable via i-type-save-quit-relaunch); only the rendered-marker prediction was wrong. Resolution logged to deferred-work.md as future-story-creation guidance ("don't borrow vim's `~` convention in narratives; use 'blank row' / 'row of spaces' instead"). |
| 2026-05-16 | Story 2.10 dev pass landed; status → review | All ACs satisfied except AC7 (hardware UAT — deferred to Ant). Final size 4793 B / 93.6% of 5120 B / 327 B headroom (BELOW spec projection of 4830-4930 — shared-helper factoring saved ~50-80 B as projected). NFR18 byte-identical rebuild SHA `e8d38610c0a7eeaf3777e1998ecdaee6` over two clean builds. AR13 / AR14 / AR15 sweeps in src/edits.asm + src/parser.asm clean (only doc-comment refs). `CALL gapbuf_delete` code refs grew 2 → 3 (added `edits_range_delete`). `msg_yank_too_large` code refs = 2 (op_dd refused-arm + op_yy refused-arm) plus doc refs. `DISPATCH_NORMAL_COUNT` unchanged at 33 (no new dispatch_normal entries — `d` / `y` already bound to parser_handle_operator since Story 1.10). Test pass count 118 → 134 pass / 1 deliberate-fail. 16 new tests landed (4 canonical + 12 additional); 3 tests dropped per AC12 footnote (subsumed). Pre-existing `parser_doubled-operator-dd.asm` test updated (Subtests 2/3/5 status_dirty assertions dropped; gap-buffer init added — Story 1.10 stub semantics retired). Implementation choices: KIND_* numeric (0x00/0x01/0x02 — KIND_CHAR=0 matches init zero-fill default); AC8 Option A (cursor-bounce N-iter loop — AR14-clean, ~2.5 ms at 4 MHz for 100-byte delete); kept symbol name `parser_doubled_operator_stub` (in-place rewrite — no caller-site update at parser_handle_operator). Test discovery: epic spec test description for `edits_yy-copies-line.asm` (`yank_length=3` claim) was inconsistent with AC4 body ("same range as op_dd"); followed AC4 (load-bearing) — yy on last-line-no-LF + S>0 yanks "\ndef" (4 bytes incl. cross-line LF) like dd. Documented in test header + deferred-work.md for Story 2.12 paste-handler decision. Bug-found-during-dev: edits_copy_to_yank's destination DE was being clobbered by motion_byte_at_logical (which trashes DE per its contract); fixed with PUSH/POP DE bracketing around the call. 5 new deferred-work.md entries logged (FR45 hook; AC8 trade-off; AC2 last-line yank semantic for Story 2.12; KIND_* choice; 3 dropped tests + parser_doubled-operator-dd update). Hardware UAT (AC7, 13 steps) deferred to Ant — story stays at `review` until confirmed. |

### Review Findings

Code review run 2026-05-16 — 3 layers (Blind Hunter, Edge Case Hunter, Acceptance Auditor). All 13 ACs MET per the Acceptance Auditor; no BLOCKER / HIGH findings against production code. Blind Hunter's two flagged BLOCKER/HIGH candidates (motion_find_line_end CF semantics, walker advancement in edits_line_range_for_count) were verified false against `src/motions.asm:637-644` (RET C on past-EOF with HL=file_length is the documented contract) and `src/edits.asm:786-798` (HL IS the walker; motion_find_line_end takes HL as input per its contract). Remaining findings are test-coverage strengthenings (patches) and out-of-scope items (defers).

- [x] [Review][Patch] Add test for case-3 post-delete cursor bounce via `.normal_done` arm (LF-terminated new last line) [test/cases/edits_dd-deletes-last-line-keeps-lf.asm new] — `dd` on `"a\nb\n"` cursor=2 (on 'b'): range=[2,4)="b\n"; post-delete "a\n" (2 B), cursor=2=file_length → case 3 → motion_find_line_start(1)=0. PASS. Closed the coverage gap — only `.at_eof`+S>0 previously exercised case 3.
- [x] [Review][Patch] Add test for counted `Ndd` arriving at `.at_eof` with S>0 mid-walk [test/cases/edits_dd-counted-into-eof-from-mid.asm new] — `3dd` on `"a\nb\nc"` cursor=2: iter 1 LF at 3, iter 2 `.at_eof` with S=2>0, delete_start=1, total_bytes=4 ("\nb\nc"). Post-delete "a" (1 B), cursor=1=file_length → case 3 → cursor=0. PASS.
- [x] [Review][Patch] Add test for yank-too-large with non-trivial post-delete cursor placement [test/cases/edits_dd-yank-too-large-multi-line.asm new] — 2-line buffer "X"*1024+LF+"Y" (1026 B), cursor=0, `dd`: line 1 = 1025 B → refused, deletion proceeds, leaves "Y" (1 B), cursor=0 → case 2. yank register UNCHANGED, status="yank too large", buffer_dirty=1. PASS. Materially exercises the refused-arm PUSH/POP HL/BC bracketing at src/edits.asm:1003-1009 (HL/BC need to survive status_set_message for the subsequent range-delete + post-delete cursor probe).
- [x] [Review][Patch] Strengthen `parser_5dd-counted-via-parser-handle-operator.asm` with `buffer_dirty=1` and `yank_kind=KIND_LINE` assertions [test/cases/parser_5dd-counted-via-parser-handle-operator.asm] — added sentinels 0x83 (buffer_dirty != 1) + 0x84 (yank_kind != KIND_LINE). PASS.
- [x] [Review][Patch] Strengthen `edits_dd-empty-buffer.asm` with non-zero pre-seed for parser-state fields [test/cases/edits_dd-empty-buffer.asm] — pre-seeded `pending_operator='d'`, `pending_motion_prefix='g'`, `count_accumulator=5`, `status_dirty=0x80`; assert parser fields zero post-call (load-bearing now), status_dirty UNCHANGED (no-op path silent). Added sentinel 0x86. PASS.
- [x] [Review][Patch] Add yank_buffer byte-content assertions to counted-dd tests [test/cases/edits_dd-counted-3lines.asm, test/cases/edits_dd-counted-clamps-at-eof.asm] — counted-3lines pins yank_buffer="a\nb\nc\n" (6 B, sentinel 0x86); counted-clamps-at-eof pins yank_buffer="a\nb\nc" (5 B, sentinel 0x85). Both PASS.
- [x] [Review][Patch] Add test for `total_bytes == YANK_BUFFER_SIZE` (1024) boundary acceptance [test/cases/edits_dd-yank-at-capacity.asm new] — fixture 1023 'X' + 1 LF = 1024 B. `dd` accepts (capacity check is strict-greater-than per edits.asm:875). yank_length=1024, yank_kind=KIND_LINE, buffer empty, status_dirty UNCHANGED at pre-seed 0x80 (silent — within capacity). PASS.
- [x] [Review][Defer] Sequential yank overwrite (two yy in a row) untested [test/cases/edits_yy*.asm] — deferred, Story 2.12 paste pass will need overwrite-semantics tests anyway; not a 2.10 regression risk (the unconditional write of yank_kind/yank_length on success-path is straightforward).
- [x] [Review][Defer] INSERT/COMMAND mode-gating regression test for `d` / `y` keys [test/cases/edits_dd-mode-gated.asm new] — deferred, same shape as Story 2.9 deferred INSERT-mode-x test (deferred-work.md). Defense-in-depth; current `dispatch_normal`-only binding makes the regression unreachable from production code paths.
- [x] [Review][Defer] Negative test for `undo_buffer` not written by op_dd [test/cases/edits_dd-no-undo-recorded.asm new] — deferred, Story 2.13 will land real undo recording and dedicated tests; the 2.10 STUB has nothing meaningful to assert against (undo_buffer state is whatever init left it; no production code touches it on the op_dd path).
- [x] [Review][Defer] `motion_find_line_start` past-EOF defensive behavior [src/motions.asm:601-612] — deferred, pre-existing in motions.asm (Story 2.6); not introduced or aggravated by Story 2.10. By construction, op_dd's case-3 caller passes `cursor-1` where cursor was just past-EOF, so `cursor-1` is the byte just past the last valid byte, which is the LF of the new last line OR the printable byte itself — both safe inputs. The latent past-EOF concern would only matter if cursor were further past file_length, which the gap-buffer invariants prevent.

**Review summary:** 0 decision-needed · 7 patches (all test-coverage strengthenings; no production-code defects found) · 4 defers · ~30 dismissed as false alarms / verified-safe / out-of-scope. Material verifications: motion_find_line_end CF=1 on past-EOF (motions.asm:625-640), walker IS HL in edits_line_range_for_count (edits.asm:786-798), PUSH/POP HL/BC bracketing around status_set_message preserves operands across the yank-refused arm (edits.asm:1003-1009), edits_copy_to_yank capacity check is strict-greater-than (SBC HL,BC where HL=YANK_BUFFER_SIZE → CF=1 iff BC>SIZE, so BC=1024 accepted and BC=1025 refused — correct per AC2/AC4).

**Patches applied 2026-05-16:** All 7 patches landed (test-only; production code untouched). Build verification: `vibe.com` unchanged at 4793 B / SHA `e8d38610c0a7eeaf3777e1998ecdaee6` (byte-identical to dev-pass record). Test count: 134 → 138 pass (+4 new tests) / 1 deliberate-fail (`harness_fail`). 4 modified tests (`edits_dd-empty-buffer`, `parser_5dd-counted-via-parser-handle-operator`, `edits_dd-counted-3lines`, `edits_dd-counted-clamps-at-eof`) all still pass post-strengthening. 4 new tests (`edits_dd-deletes-last-line-keeps-lf`, `edits_dd-counted-into-eof-from-mid`, `edits_dd-yank-at-capacity`, `edits_dd-yank-too-large-multi-line`) all pass on first run.
