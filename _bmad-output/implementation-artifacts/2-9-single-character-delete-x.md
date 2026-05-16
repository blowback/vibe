# Story 2.9: Single-character delete (x)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `x` in NORMAL mode to delete the character under the cursor (with count support like `5x`),
so that FR28 lands as the simplest deletion primitive — the first NORMAL-mode mutating operator and the last brick before the doubled-operator (`dd`/`yy`) and operator+motion (`dw`/`d$`/etc.) work in Stories 2.10-2.11.

## Acceptance Criteria

**AC1 — `x` deletes the byte under the cursor; cursor stays put unless the deleted byte was the last on the line.**

**Given** I'm in NORMAL mode with cursor on a non-empty line at `cursor_offset = C` and the byte at C is NOT `0x0A` (LF)
**When** I press `x`
**Then** the byte at offset C is removed via `gapbuf_delete` (operating "forward" — see AC8 implementation note), `buffer_dirty := 1`, all rows marked dirty (conservative shape, matching Story 2.8 — `render_mark_all_dirty`), parser state zeroed.
**And** if the deleted byte was NOT the last printable on its line (the byte at the new `cursor_offset = C` is still a non-LF, non-past-EOF byte), `cursor_offset` stays at C.
**And** if the deleted byte WAS the last printable on its line (the byte at the new `cursor_offset = C` is now `0x0A` OR past EOF), `cursor_offset` clamps back by 1 to land on the new last printable byte of the line — UNLESS `C == 0` (no room to clamp; cursor stays at 0 on the now-LF or empty buffer).

**AC2 — `x` at end of file consumes the last byte; cursor adjusts to new EOF.**

**Given** I'm in NORMAL mode with `cursor_offset = file_length - 1` (cursor on the last printable byte of a no-trailing-LF file)
**When** I press `x`
**Then** the last byte is consumed; new `file_length := file_length - 1`; cursor clamps back to `file_length - 1` (the new last printable byte), or stays at `0` if the buffer is now empty.

**AC3 — `x` on an empty line is a documented no-op.**

**Given** I'm in NORMAL mode with cursor on the LF byte of an empty line (`cursor_offset = C`, byte at C is `0x0A`) — defensively, the Story 2.5 invariant says cursor shouldn't be there, but if it is, `x` MUST NOT join lines per the AC
**When** I press `x`
**Then** no buffer mutation; no `buffer_dirty` write; no render mark; parser state IS zeroed via `parser_clear` (per the FR50 / Story 2.8 AC11 hygiene shape — every dispatched key clears the parser-state accumulator regardless of whether the handler did anything).

Same shape applies to `x` at past-EOF cursor (`cursor_offset >= file_length`): silent no-op, parser cleared.

**AC4 — Counted `x` (e.g. `5x`) deletes N characters with EOL clamping per BH2.**

**Given** I'm in NORMAL mode with `count_accumulator = N` (where N >= 1), cursor on a non-LF byte
**When** I press `x` (parser dispatches via `parser_dispatch`-shape; `motion_apply_count` reads N into BC)
**Then** the handler iterates up to N delete operations:
- Each iteration reads the byte at the current `cursor_offset`. If past EOF (CF=1) or `0x0A`, the loop BREAKS (BH2 clamp — counted operation stops at boundary; behaves as if N had been the partial count).
- Otherwise, the byte is deleted via the gapbuf primitive (see AC8) and the iteration count decrements.
- After the loop exits (either count exhausted OR boundary hit), the post-loop clamp from AC1 applies once: if cursor is now on `0x0A` or past EOF AND `cursor_offset > 0`, decrement cursor by 1.

Trace `5x` on `"abcde"` (5 B), cursor=0: iter 1-5 each delete; post-loop cursor=0 with byte_at=CF=1 (empty buffer); cursor stays at 0 (clamp guarded). Final: empty buffer, cursor=0. AC4 + AC1 empty-buffer corner.

Trace `5x` on `"abc\ndef"` (7 B), cursor=0: iter 1 deletes 'a'; iter 2 deletes 'b'; iter 3 deletes 'c'; iter 4 sees `0x0A`, BREAK; post-loop cursor=0 with byte_at=`0x0A`; cursor stays at 0 (clamp guarded). Final: `"\ndef"` (4 B), cursor=0 on LF. AC4 + BH2 stop-at-boundary.

Trace `5x` on `"abc"` (3 B), cursor=0: iter 1-3 delete; iter 4 sees CF=1 (empty buffer), BREAK; post-loop cursor=0 stays at 0. Final: empty, cursor=0.

Trace `2x` on `"abc"` (3 B), cursor=2 (on 'c'): iter 1 deletes 'c' (cursor=2, INC→3, gapbuf_delete consumes 'c', cursor returns to 2); iter 2 sees byte_at(2)=CF=1 (file_length now 2), BREAK; post-loop cursor=2 with CF=1; cursor=2 != 0, dec → 1 ('b'). Final: `"ab"` cursor=1. AC4 + AC1 EOL-clamp.

**AC5 — `buffer_dirty` set; affected rows dirty; conservative dirty-row marking.**

**Given** an `x` invocation that successfully deleted at least one byte
**When** the handler completes
**Then** `buffer_dirty := 1` (idempotent — re-writing 1 over an already-1 value is fine; see Story 2.8 AC9 for the "simpler-is-cleaner" rationale) **AND** `render_mark_all_dirty` is called (conservative shape — a delete at any position can shift LF positions OR cause a content-shift visible across the cursor row at minimum; mark-all is correct and ~5 B cheaper than the fine-grained "inspect deleted byte, mark cursor row only if non-LF" branch). Fine-grained marking is a Growth-tier optimisation deferred (already logged for Story 2.8 in deferred-work.md; this story inherits the same shape).

**Given** an `x` invocation that hit the no-op path (AC3 — cursor on LF or past EOF, OR AC4 zero-deletes-then-break-immediately on counted x)
**When** the handler completes
**Then** `buffer_dirty` is NOT touched (retains its prior value); `render_mark_all_dirty` is NOT called (no buffer mutation, no shadow-vs-buffer divergence to surface). Parser state IS still cleared (every dispatched key clears, mutation or not).

**AC6 — Undo recording is a STUB for Story 2.9 (full impl in Story 2.13).**

`x` mutates the buffer (FR45 says undo covers the most recent edit), so per the architecture's "Records inverse ops to undo buffer" line at architecture.md:1303, this story's `x` SHOULD record an inverse-op (insert N bytes at position) entry in `undo_buffer`.

For Story 2.9 the recording is a **STUB** — no entry is written to `undo_buffer`. `u` post-`x` reports `msg_nothing_to_undo` via the existing capacity-refusal path (statusln.asm:222 region). Full inverse-op recording lands in Story 2.13. The hook site in `x`'s handler is documented in the Dev Notes section so 2.13's dev knows where to wire in.

This matches Story 2.8's B2 stub shape (insert-session undo deferred to 2.13). Document the stub explicitly in the change log AND in deferred-work.md.

**AC7 — Hardware UAT on real MicroBeast (deferred to user; same pattern as Stories 1.11 / 1.12 / 2.1-2.8).**

The dev MUST NOT mark this story `done` without confirmed hardware UAT by Ant. The dev pass produces `:wq`-ready code; the user (Ant) runs `make push` and steps through the UAT script.

Hardware UAT script (12 steps):

1. **Pre-state:** boot fresh, no prior `vibe` invocation this session.
2. **`vibe newgame.fs`** with the file from Story 2.8 step 14 if it survived (`"line 0\nHello world\nline 2"` 25 B), or any pre-existing multi-line file. Status confirms `loaded` count, mode `-- normal --`, cursor at offset 0.
3. **Press `j` then `l l l`** — cursor moves down one line and right 3 (Story 2.5 / 2.7 regression net). Confirm cursor lands inside line 2 mid-content.
4. **Press `x`** — character under cursor disappears; cursor stays at the same logical offset (or clamps back if you happened to land on the last printable of the line). On-screen: the row redraws with one fewer character; cells to the right of the deletion point shift left.
5. **Press `x x x`** — three more individual deletes. Confirm each removes exactly one character.
6. **Press `0`** to return to BOL. Press `5x` — five characters from BOL deleted; cursor at offset 0 of the now-shorter line. (If the line had < 5 printable chars, the BH2 clamp kicks in at the LF and stops; cursor stays at 0.) Confirm row redraws correctly.
7. **Press `$`** to land on the new last printable byte of the current line. Press `x` — that last byte is deleted; cursor clamps back by 1 to land on the new last printable. (If the line had only 1 char, cursor lands at offset 0 of the now-empty-but-LF-terminated line.) AC1 EOL-clamp.
8. **Press `:w`** — file saves; status confirms bytes written and `buffer_dirty := 0`.
9. **Press `:q`** — clean quit (no refusal — buffer was just saved).
10. **`vibe newgame.fs`** — re-launches; confirm the deletions persisted to disk (file content matches what was on screen pre-`:w`).
11. **Edge case: x on an empty line.** Use `o` (Story 2.8) to create a new empty line below; press Esc; press `x` — no-op (no byte to delete on an empty line). Status unchanged. Buffer unchanged. AC3.
12. **Sustained x regression** — `vibe newgame.fs`, navigate to a long line, hold `x` (or rapidly press `x`-repeated) for ~30+ presses. Confirm no dropped keystrokes, no terminal corruption, render keeps up (NFR1 / NFR2 / NFR3 still hold under deletion load). The buffer shrinks predictably; cursor clamps cleanly when the line empties.

The hardware UAT also looks for regressions against earlier stories: motion in NORMAL still works (Stories 2.5-2.7); ex-line `:w` / `:q` / `:e` still work (2.1 / 2.2 / 2.4); INSERT-mode i/a/o/O + literal typing + Backspace + Enter + Esc still work (2.8); counted motions in NORMAL still respect their counts (2.7).

**AC8 — Implementation: forward-delete via `INC cursor; CALL gapbuf_delete` ("cursor-bounce" shape).**

The epic spec hints at "implementation may use `gapbuf_move_gap` to position then delete leading byte of after-gap half." That option requires a direct write to `gap_end` — an AR14 violation if done from edits.asm. The chosen implementation uses the cursor-bounce shape:

1. INC `cursor_offset` by 1 (cursor logically advances past the byte to delete).
2. CALL `gapbuf_delete` — gapbuf_delete moves the gap to the new cursor position (if needed), decrements `gap_start` (consuming the byte that was at the original cursor — now logically the byte just before the new cursor), decrements `cursor_offset` (back to the original position).
3. Net effect: the byte at the original cursor position is removed; cursor returns to where it started.

Trace cursor=3 in `"abcdef"`:
- INC: cursor=4
- gapbuf_delete: not BOF (4 != 0); move gap to cursor 4; dec gap_start (consumes 'd' at logical offset 3); dec cursor → 3.
- Result: buffer `"abcef"` (5 B), cursor=3.

This shape is AR14-clean (only public gapbuf primitives used; no direct writes to `gap_start` / `gap_end`). Cost: ~3 B per delete vs adding a new gapbuf primitive (`gapbuf_delete_forward` or similar, which would cost ~30-40 B of new public surface in gapbuf.asm + an AR23 contract block).

Spec note arithmetic: per `gapbuf_delete`'s AC5 contract (state unchanged on BOF — cursor==0 with CF=1 return), the cursor-bounce shape never reaches the BOF path because the pre-check (AC1 / AC3) ensures we only enter the loop when there's a byte to delete; INC takes us to a positive cursor offset; gapbuf_delete then succeeds.

**AC9 — Architecture compliance — `edits.asm` extended (no new module).**

`x` lives in the existing `src/edits.asm`, NOT a new module. AR boundary properties unchanged from Story 2.8:
- **AR13 (no screen emission):** zero `BIOS_CONOUT_*` references. Sweep `grep -n 'BIOS_CONOUT' src/edits.asm` — no new code refs (only the existing doc-comment header references at lines 130 + 477 region, plus any new doc-comment references this story adds for `edits_delete_char`).
- **AR14 (no direct buffer mutation):** zero `LD (gap_start), DE` / `LD (gap_end), DE` writes. All mutation through `gapbuf_delete`. Sweep `grep -nE 'LD \((gap_start|gap_end)\),' src/edits.asm` — no code refs.
- **AR15 (no raw BDOS):** zero `BDOS_CALL` / `CALL BDOS_ENTRY` / `CALL 0x0005` references. Sweep `grep -nE 'BDOS_CALL|CALL BDOS_ENTRY|CALL 0x0005' src/edits.asm` — no code refs.
- **AR12 (status via funnel):** edits.asm does NOT directly write status bytes. `x` has no error surface (the no-op path is silent per AC3; gapbuf_delete on the cursor-bounce shape never returns CF=1 because of the pre-check guard).
- **AR23 (module header docstring):** the existing module-header block in `src/edits.asm` MUST be extended to add `edits_delete_char` to the Public list (line 29-35 region) AND to add a per-entry contract block for `edits_delete_char` (between lines 51-130 region — In/Out/Trashes/Calls per AR23 — paralleling the existing `edits_insert_literal` block).
- **AR25 (INCLUDE chain):** unchanged. `src/vibe.asm`'s INCLUDE order keeps `edits.asm` between `motions.asm` and `exline.asm`.

**AC10 — `dispatch_normal` table grows by 1 entry (`'x'`).**

`dispatch_normal` (binary-search MC3 table; Story 2.8 left it at 32 entries) gains one entry for `'x'` (0x78), inserted between the existing `'w'` (0x77 → motion_w) and `'y'` (0x79 → parser_handle_operator) entries. New `DISPATCH_NORMAL_COUNT = 33`. Binary-search worst case `ceil(log2(33)) = 6` iterations (was 5 at 32 entries; NFR3 unchanged — well inside frame budget). The adjacent-pair ASSERT shape `ASSERT 'x' > 'w'` and `ASSERT 'y' > 'x'` MUST be added to keep the build-time sort-order check intact.

The new dispatch_normal entry routes to `edits_delete_char` (the new public symbol added to edits.asm).

**AC11 — Headless tests (all under `test/cases/edits_*.asm`).**

**Canonical (epics spec line 1289):**
- `edits_x-mid-line.asm` — pre-load `"abcdef"` (6 B); cursor=3 ('d'); CALL `edits_delete_char`; assert cursor=3 (unchanged, mid-line); buffer post-walk = `"abcef"` (5 B); `buffer_dirty == 1`.
- `edits_x-at-eof.asm` — pre-load `"hello"` (5 B, no trailing LF); cursor=4 (last printable 'o'); CALL `edits_delete_char`; assert cursor=3 (clamped back per AC2 — new file_length=4, cursor was at 4, dec to 3 ('l')); buffer = `"hell"` (4 B); `buffer_dirty == 1`.
- `edits_5x-counted.asm` — pre-load `"abcdef"` (6 B); cursor=0; pre-set `count_accumulator := 5`; CALL `parser_dispatch` with HL = `edits_delete_char` (the parser-driven path the real dispatch uses for counted operations); assert cursor=0 (mid-line clamp doesn't fire since byte_at(0) = 'f' is still printable); buffer = `"f"` (1 B); `buffer_dirty == 1`; `count_accumulator == 0` post-dispatch (parser_clear via parser_dispatch's tail).

**Additional (full AC + edge coverage):**
- `edits_x-at-eol-clamp.asm` — pre-load `"abc\ndef"` (7 B); cursor=2 (on 'c', last printable of line 1); CALL `edits_delete_char`; assert cursor=1 (clamped back from 2 to 1 because byte_at(2) post-delete is `0x0A`); buffer = `"ab\ndef"` (6 B); `buffer_dirty == 1`. AC1 EOL-clamp.
- `edits_x-on-empty-line.asm` — pre-load `"\ndef"` (4 B); cursor=0 (on the LF of empty line 0); CALL `edits_delete_char`; assert cursor=0 (unchanged); buffer = `"\ndef"` (unchanged); `buffer_dirty == 0` (NOT touched per AC5); `pending_operator == 0`, `pending_motion_prefix == 0`, `count_accumulator == 0` (parser cleared per AC3 hygiene). AC3.
- `edits_x-past-eof.asm` — pre-load `"abc"` (3 B); cursor=3 (one past last byte; defensive — Story 2.5 invariant says cursor shouldn't be there but this test pins the no-op shape); CALL `edits_delete_char`; assert cursor=3 (unchanged); buffer = `"abc"` (unchanged); `buffer_dirty == 0`. AC3 past-EOF corner.
- `edits_x-empty-buffer.asm` — empty buffer (file_length=0); cursor=0; CALL `edits_delete_char`; assert cursor=0; buffer empty; `buffer_dirty == 0`. AC3 empty-buffer corner.
- `edits_x-deletes-last-char.asm` — pre-load `"a"` (1 B); cursor=0; CALL `edits_delete_char`; assert cursor=0 (post-delete buffer is empty; clamp guarded at cursor=0); file_length=0; `buffer_dirty == 1`. AC2 + clamp guard.
- `edits_5x-clamps-at-eol.asm` — pre-load `"abc\ndef"` (7 B); cursor=0; `count_accumulator := 5`; CALL `parser_dispatch` with HL = `edits_delete_char`; assert cursor=0 (line shrank to empty-but-with-LF; clamp guarded at 0); buffer = `"\ndef"` (4 B); `buffer_dirty == 1`. AC4 BH2 stop-at-boundary.
- `edits_5x-clamps-at-eof.asm` — pre-load `"ab"` (2 B); cursor=0; `count_accumulator := 5`; CALL `parser_dispatch` with HL = `edits_delete_char`; assert cursor=0 (post-delete buffer empty); file_length=0; `buffer_dirty == 1`. AC4 + AC2 over-count corner.
- `edits_x-clears-parser-state.asm` — pre-set `count_accumulator := 5`, `pending_operator := 'd'`, `pending_motion_prefix := 'g'`; pre-load `"abcdef"` cursor=0; CALL `parser_dispatch` with HL = `edits_delete_char`; assert all three parser-state fields zeroed post-dispatch. AC3 / AC5 hygiene + Story 1.10 parser_dispatch tail-JP regression net.
- `edits_x-dispatch-normal-routes.asm` — pre-load `"abcdef"` cursor=2; mode_byte = MODE_NORMAL; drive `'x'` (0x78) through `dispatch_key` against `dispatch_normal`; assert cursor=2 (mid-line, unchanged); buffer = `"abdef"` (5 B); `buffer_dirty == 1`. Pins the AC10 dispatch_normal entry-routing wiring (the same pattern as Story 2.8's `edits_dispatch-insert-routes-backspace.asm`).

10 new tests total (3 canonical + 7 additional). Sentinel range 0x80..0x86 per test (continuing the Story 2.5 / 2.6 / 2.7 / 2.8 convention; within the 0x80..0x87 allocation).

**AC12 — Build invariants (NFR9, NFR18, AR sweeps).**

- `make all` followed by `make clean && make all` produces a byte-identical `vibe.com` (NFR18).
- `make test` from a fresh `make clean && make test` is green (the 108 pass / 1 deliberate-fail post-2.8 baseline grows by 10 to ~118 pass / 1 fail).
- AR13 / AR14 / AR15 grep sweeps against `src/edits.asm` are all clean (per AC9).
- AR25 INCLUDE chain in `src/vibe.asm` is unchanged (`statusln → gapbuf → render → dispatch → parser → motions → edits → exline → fileio`).
- `dispatch_normal` grows from 32 entries to 33 — AC10. The slot count change is the only structural delta in dispatch.asm.
- `dispatch_insert` and `dispatch_command` and `dispatch_visual` are unchanged.
- **NFR9 projection:** post-2.8 footprint = 4513 B (post-code-review). Story 2.9 adds (a) `edits_delete_char` ~50-65 B (delete-loop body + pre-check + post-clamp + per-iter byte-read; estimate based on `motion_w`'s ~70 B for a similar walk-with-condition pattern, minus the word-class branch); (b) dispatch_normal entry: +3 B for the new entry slot (DEFB byte + DEFW handler) + 0 B for the ASSERT (compile-time only); (c) module-header docstring update: 0 B (comment-only). Projected post-2.9: 4566-4581 B = 89.2-89.5% of 5120 B = ~539-554 B headroom. **Well within NFR9.** Stories 2.10-2.13 (dd/yy/dw/p/u) are the next significant deltas; the headroom remains tight but no NFR9 amend required.
- **`buffer_dirty` write count:** Story 2.9 adds 1 site writing `buffer_dirty := 1` (in `edits_delete_char`'s success-tail path; reuses the existing shared `edits_dirty_and_redraw` helper for ~7 B of factoring savings). The no-op paths (AC3 empty-line, past-EOF, empty-buffer) NEVER write `buffer_dirty` so it retains its prior value.

## Tasks / Subtasks

- [x] **Task 1: Implement `edits_delete_char`** (AC1, AC2, AC3, AC4, AC5, AC8).
  - [x] Sub 1.1: Document the per-entry contract block in the `src/edits.asm` module header per AR23 — In: A = 'x' (MC4; ignored), `count_accumulator` read via `motion_apply_count`. Out: success — N bytes deleted, cursor clamped per AC1, `buffer_dirty = 1`, all rows dirty. no-op — buffer unchanged, `buffer_dirty` unchanged. Trashes: A, BC, DE, HL, F. Calls: `motion_apply_count`, `motion_byte_at_logical`, `gapbuf_delete`, `render_mark_all_dirty` (success tail-JP via `edits_dirty_and_redraw`), `parser_clear` (no-op tail-JP).
  - [x] Sub 1.2: Pre-check (AC1 / AC3) — implemented as the iter-top check inside the count loop (same check shape; the iter-top check IS the pre-check on iter 1). On CF=1 (past EOF) or A == 0x0A on iter 1, BC == N at exit; the `SBC HL,BC` deltas-done check at `.exit_loop` is 0, branches to `.noop_clear` (`JP parser_clear`) — silent no-op, buffer + cursor + buffer_dirty unchanged.
  - [x] Sub 1.3: Count-driven loop body (AC4 + AC8) — at each iteration: re-check byte at current cursor (CF=1 or LF → BREAK to `.exit_loop`); INC HL → cursor advances; `LD (cursor_offset), HL`; `PUSH BC; CALL gapbuf_delete; POP BC` (cursor-bounce shape per AC8); `DEC BC; LD A,B; OR C; JR NZ, .loop`. Loop exits via count exhaustion OR boundary BREAK.
  - [x] Sub 1.4: BC-preservation across `gapbuf_delete` — PUSH BC / POP BC bracketing each call site (1 byte each + 3 byte CALL = 5 B per iter; ~25 B for a 5-iter `5x`).
  - [x] Sub 1.5: Post-loop clamp (AC1 / AC2 / AC4 BH2-clamp) — at `.exit_loop`: POP HL = N (saved at entry); `OR A; SBC HL, BC` gives deltas-done; if 0, JP `.noop_clear` (skip dirty + clamp). Otherwise reload `LD HL, (cursor_offset)`; if cursor==0, JR `.commit` (skip clamp, guarded). Else `CALL motion_byte_at_logical`; on CF=1 OR A == 0x0A: `DEC HL; LD (cursor_offset), HL`. Then `CALL edits_dirty_and_redraw` for buffer_dirty := 1 + render_mark_all_dirty.
  - [x] Sub 1.6: Tail-JP — success path uses `CALL edits_dirty_and_redraw; JP parser_clear` (CALL because we need parser_clear after; edits_dirty_and_redraw internally tail-JPs render_mark_all_dirty which RETs back to us, then JP parser_clear). No-op path skips edits_dirty_and_redraw and `JP parser_clear` directly via `.noop_clear:`.

  **Dispatch-path note:** dispatch_normal routes `'x'` directly to `edits_delete_char`; the handler's own tail-JP `parser_clear` clears state. The counted route via `parser_dispatch` calls the handler then auto-tail-JPs parser_clear AGAIN — the second call is a safe no-op (idempotent — fields already zeroed by the handler's tail).

  - [x] Sub 1.7: Optional shared-tail factoring — Story 2.9 has one success-tail site; CALL edits_dirty_and_redraw + JP parser_clear is open-coded. No new helper introduced.

- [x] **Task 2: Patch dispatch.asm** (AC10).
  - [x] Sub 2.1: Inserted new `dispatch_normal` entry between `'w'` and `'y'` with `ASSERT 'x' > 'w'` + `DEFB 'x'` + `DEFW edits_delete_char`.
  - [x] Sub 2.2: Updated the existing `ASSERT 'y' > 'w'` to `ASSERT 'y' > 'x'`.
  - [x] Sub 2.3: `DISPATCH_NORMAL_COUNT` confirmed = 33 — `build/vibe.lst` shows `LD B, DISPATCH_NORMAL_COUNT` resolved to `06 21` (0x21 = 33 decimal).
  - [x] Sub 2.4: Updated `dispatch.asm` module-header `src/edits.asm` dependency comment block — added Story 2.9 sentence noting `edits_delete_char` as the new dispatch_normal `'x'` entry; slot count 32 → 33.

- [x] **Task 3: Update src/edits.asm module-header docstring** (AC9, AR23).
  - [x] Sub 3.1: Added `edits_delete_char` to the Public list (after `edits_insert_newline`).
  - [x] Sub 3.2: Added per-entry contract block for `edits_delete_char` in the Register conventions section per AR23 (In / Out / Trashes / Calls).
  - [x] Sub 3.3: Updated Purpose block — closing parenthetical mentions Story 2.9 lands `x` (FR28); FR list extended from "FR24-FR27" to "FR24-FR28".
  - [x] Sub 3.4: Updated State owned (read/write) block — added sentence noting `edits_delete_char` uses the cursor-bounce shape (gapbuf_delete dec's cursor; post-loop clamp may dec it again).
  - [x] Sub 3.5: Updated Dependencies block — appended `motion_apply_count` as the count-default helper used by Story 2.9; noted BC-preservation matters now that edits.asm iterates a count loop.

- [x] **Task 4: Headless tests** (AC11).
  - [x] Sub 4.1: 3 canonical tests landed (epics line 1289): `edits_x-mid-line.asm`, `edits_x-at-eof.asm`, `edits_5x-counted.asm`. All pass.
  - [x] Sub 4.2: 7 additional tests landed: `edits_x-at-eol-clamp.asm`, `edits_x-on-empty-line.asm`, `edits_x-empty-buffer.asm`, `edits_x-deletes-last-char.asm`, `edits_5x-clamps-at-eol.asm`, `edits_x-clears-parser-state.asm`, `edits_x-dispatch-normal-routes.asm`. (Optional `edits_x-past-eof.asm` and `edits_5x-clamps-at-eof.asm` dropped — the empty-buffer / deletes-last-char / 5x-clamps-at-eol tests collectively pin the same BREAK + clamp shapes.)
  - [x] Sub 4.3: Sentinel allocation per landed test:
    - `edits_x-mid-line.asm` → 0x80 (cursor=3), 0x81 (gap content), 0x82 (buffer_dirty).
    - `edits_x-at-eof.asm` → 0x80 (cursor clamped 4→3), 0x81 (gap content), 0x82 (buffer_dirty).
    - `edits_5x-counted.asm` → 0x80 (cursor=0), 0x81 (gap content / EOF), 0x82 (buffer_dirty), 0x83 (count_accumulator=0).
    - `edits_x-at-eol-clamp.asm` → 0x80 (cursor=1), 0x81 (gap content).
    - `edits_x-on-empty-line.asm` → 0x80 (cursor=0), 0x81 (gap unchanged), 0x82 (buffer_dirty unchanged), 0x83 (count=0), 0x84 (op=0), 0x85 (prefix=0).
    - `edits_x-empty-buffer.asm` → 0x80 (cursor=0), 0x81 (file_length=0), 0x82 (buffer_dirty=0).
    - `edits_x-deletes-last-char.asm` → 0x80 (cursor=0), 0x81 (file_length=0), 0x82 (buffer_dirty=1).
    - `edits_5x-clamps-at-eol.asm` → 0x80 (cursor=0), 0x81 (gap content), 0x82 (buffer_dirty).
    - `edits_x-clears-parser-state.asm` → 0x80 (count_accumulator=0), 0x81 (pending_operator=0), 0x82 (pending_motion_prefix=0).
    - `edits_x-dispatch-normal-routes.asm` → 0x80 (cursor=2), 0x81 (gap content), 0x82 (buffer_dirty).
  - [x] Sub 4.4: All tests get the full INCLUDE chain — equates / bios / bdos / modes / vt52 / test_prologue / test body / test_epilogue / production sources / test_teardown_stub + test_input_loop_stub / state.inc. No fan-out patches needed (no new `src/` module).

- [x] **Task 5: NFR9 + NFR18 + AR sweeps** (AC12).
  - [x] Sub 5.1: Two consecutive `make clean && make all` produce byte-identical `vibe.com` — SHA `4703450f67b841c31d35bae3ecff5dd2` (NFR18).
  - [x] Sub 5.2: AR enforcement sweeps clean — `BIOS_CONOUT` / `LD (gap_start|gap_end), ...` / `BDOS_CALL` greps return only the existing 2 doc-comment refs per pattern in `src/edits.asm`; zero new code refs. `CALL gapbuf_delete` matches: 2 code sites (edits_insert_backspace + edits_delete_char) + 2 doc-comment refs = 4 grep matches total (spec expected 2 code sites — confirmed).
  - [x] Sub 5.3: `vibe.com` size: 4513 → 4580 B (Δ+67 B, within 50-65 B body + 3 B dispatch slot projection). 89.45% of 5120 B ceiling; ~540 B headroom. No NFR9 retro flag needed.
  - [x] Sub 5.4: `DISPATCH_NORMAL_COUNT` = 33 confirmed (`LD B, DISPATCH_NORMAL_COUNT` resolves to `06 21` in build/vibe.lst). Binary-search worst case 6 iterations (was 5).
  - [x] Sub 5.5: Test pass count: 108 → 118 pass / 1 deliberate-fail (10 new tests, all passing).

- [x] **Task 6: deferred-work.md housekeeping.**
  - [x] Sub 6.1: FR45 undo recording stub for `x` documented in deferred-work.md (`Deferred from: dev of story-2-9-...` section) — `edits_delete_char` does NOT write to `undo_buffer`; Story 2.13's hook site is the `CALL edits_dirty_and_redraw` instruction's predecessor position.
  - [x] Sub 6.2: Cursor-bounce vs new-primitive trade-off documented in deferred-work.md — ~5 B per call-site framing + PUSH/POP BC vs ~30-40 B for a new `gapbuf_delete_forward`. Revisit trigger documented (composed-op story + profiling pressure).
  - [x] Sub 6.3: BH2 stop-at-EOL semantic for counted `x` documented in deferred-work.md including the known invariant violation (cursor on LF after `5x` from BOL on a line shorter than the count). Stories 2.10 / 2.11 may diverge per-op; per-handler documentation noted as the preferred pattern.

- [x] **Task 7: Hardware UAT** (AC7) — confirmed by Ant on 2026-05-16.
  - [x] Sub 7.1: `make push` SLIDE transfer to real MicroBeast confirmed by Ant.
  - [x] Sub 7.2: Ant stepped through the 12-step AC7 UAT script on real MicroBeast — all steps pass; no regressions, no fix iterations needed.
  - [x] Sub 7.3: Story stays at `review` pending code-review pass (per workflow convention — review → done flip happens after code-review applies any patches).

## Dev Notes

### Architecture compliance

- **AR13 (no screen emission from edits).** `edits_delete_char` does not call `BIOS_CONOUT_*`. Cursor reposition + row redraw happen via `render_mark_all_dirty` + `render_diff` on the next frame (per `input_loop` step 4 — render_diff runs after every handler). Story 2.8 established this for INSERT-mode edits; Story 2.9 inherits.
- **AR14 (no buffer mutation outside gapbuf primitives).** `edits_delete_char` mutates the buffer ONLY through `gapbuf_delete` (the AC8 cursor-bounce shape). The `motion_byte_at_logical` helper is a READ primitive — used for the AC1 / AC3 LF / EOF pre-check and the AC1 post-clamp — and falls under AR14's "reads OK, writes forbidden" boundary. The `motion_apply_count` helper is also pure-read.
- **AR15 (no raw BDOS).** `edits_delete_char` does not call BDOS. (gapbuf_delete is a pure-memory operation; no BDOS surface.)
- **AR12 (status messages via funnel).** `edits_delete_char` has no error surface. The no-op path (AC3) is silent — no status message. The success path (AC1 / AC2 / AC4) does not surface any status. Future Story 2.13's `u` will surface `msg_nothing_to_undo` if undo is invoked post-`x`-without-recording — that surface lives in undo.asm (Story 2.13), not here.
- **AR23 (module header documentation).** The existing `src/edits.asm` module-header block grows by one Public entry + one per-entry contract block per AR23.
- **AR25 (INCLUDE chain).** Unchanged. `src/vibe.asm` keeps `edits.asm` between `motions.asm` and `exline.asm`.
- **MC3 (binary-search dispatch).** `dispatch_normal` count grows from 32 to 33 entries (worst case 5 → 6 iterations — `ceil(log2(33)) = 6`). Well inside NFR3 frame budget.
- **MC4 (handler signature — A=key on entry; state via state.inc symbols).** `edits_delete_char` accepts A as the consumed key (ignored after dispatch). No register-passed args. count_accumulator read via `motion_apply_count`.
- **BH2 (counted-motion clamps — silent at boundary).** `edits_delete_char`'s counted form (AC4) follows BH2's "clamp at boundary" — the count loop BREAKs on LF or past-EOF rather than crossing the line / consuming non-existent bytes. Cursor stays at the boundary (or clamps back per AC1 if a delete completed and left cursor on LF).
- **NFR1 / NFR2 (interactive feedback / sustained typing).** `x` adds a deletion surface to the responsiveness story. Each `x` keystroke: pre-check (motion_byte_at_logical, ~50-100 T-states) + cursor-bounce delete (gapbuf_delete, including possible gap relocation LDIR — bounded by GAP_BUFFER_MAX = 32 KB / 4 MHz) + render_mark_all_dirty (cheap, 3-byte bitmap set) + render_diff (per-frame; bounded by SCREEN_ROWS × SCREEN_COLS at worst). For typical edits, well within NFR3's ~16 ms target. AC7 step 12's sustained-x regression validates qualitatively on hardware.
- **NFR9 (code size).** Footprint projected 4565-4580 B / ~89% of 5120 B / ~540-555 B headroom. Story 2.10 (dd/yy) is the next big delta; Stories 2.11 / 2.12 (dw/p/cw) will further consume headroom.
- **NFR18 (byte-identical rebuild).** Verified in Sub 5.1.
- **FR28 (the load-bearing FR for this story).** End-to-end verification via the 9-10 headless tests in AC11 + hardware UAT in AC7.
- **FR45 / FR46 (undo coverage — Story 2.13).** `x`'s inverse-op recording is a STUB for 2.9; full impl in 2.13. Hook site documented in deferred-work.md (Sub 6.1).

### Forward-delete implementation: cursor-bounce vs new gapbuf primitive

The epic spec (line 1264) hints: "implementation may use `gapbuf_move_gap` to position then delete leading byte of after-gap half." That option requires a direct write to `gap_end` (incrementing it by 1 to absorb the byte just past the gap) — an AR14 violation if performed in edits.asm.

Two options:

**Option A (chosen): cursor-bounce.** `INC cursor_offset; CALL gapbuf_delete`. gapbuf_delete moves the gap to the new (advanced) cursor, decrements gap_start (consuming the byte that was at the original cursor), decrements cursor (back to original position). AR14-clean — only existing public gapbuf primitives used.
- **Cost per delete:** ~5 B at the call site (LD HL, (cursor_offset); INC HL; LD (cursor_offset), HL; CALL gapbuf_delete) + the gapbuf_delete body's existing ~50 B (already paid for by Backspace).
- **Trace verified:** see AC1 / AC8 traces above. All edge cases (BOF guard, gap-not-at-cursor LDIR shift) handled by gapbuf_delete's existing implementation.

**Option B: new gapbuf primitive `gapbuf_delete_forward`.** Adds a new public entry to gapbuf.asm: pre-check, move_gap to cursor, INC gap_end (direct write — internal to gapbuf so AR14-compliant). Cleaner semantics but ~30-40 B of new gapbuf surface (entry contract + body + AR23 docstring update).

**Recommendation: Option A.** Smaller footprint, no new public surface, no AR23 update beyond edits.asm. The ~5 B per call site is amortised across the count loop (paid once per iteration; for `5x` that's ~5 calls × ~5 B = 25 B inline cost vs ~30-40 B for the new primitive — even on a 5-count case, Option A wins). If profiling on real hardware later shows the cursor-bounce overhead is observable for high-count operations (e.g., `100x` deleting 100 bytes), revisit and consider Option B at that point.

### Counted-x edge cases — known sharp edges

- **`5x` on a single-char buffer (`"a"` cursor=0).** Pre-check passes (byte='a'). Iter 1: INC→1, delete, cursor=0. Iter 2-5: byte_at(0) = CF=1 (empty buffer), BREAK. Post-clamp: cursor=0, skip dec (guard). Final: empty buffer, cursor=0, buffer_dirty=1. AC4 + AC1 empty-buffer corner.
- **`5x` on `"abc\ndef"` cursor=0.** Pre-check passes (byte='a'). Iter 1-3: delete 'a','b','c'. Iter 4: byte_at(0) = 0x0A, BREAK. Post-clamp: cursor=0, byte_at=0x0A, but cursor=0 so skip dec. Final: `"\ndef"`, cursor=0 on LF. **Cursor on LF is a Story 2.5 invariant violation** — but matches vi-faithful "x doesn't join lines" semantic. Fixing requires either (a) moving cursor to start of next line (would join lines, AC3 forbids) OR (b) special-case post-clamp to detect "previous line is empty after delete" and... do what? This case is documented as a known invariant violation. The next motion (h/j/k/l) will re-establish the invariant on the next user keystroke.
- **`5x` at last printable of last line (`"abc"` cursor=2 on 'c').** Pre-check passes. Iter 1: INC→3, delete 'c', cursor=2. Iter 2: byte_at(2) = CF=1 (file_length now 2), BREAK. Post-clamp: cursor=2 != 0, byte_at = CF=1, dec → 1 ('b'). Final: `"ab"`, cursor=1, buffer_dirty=1. AC4 + AC2 EOL/EOF clamp.
- **`x` at past-EOF cursor (defensive).** Pre-check sees CF=1, JP parser_clear (silent no-op). buffer + cursor + buffer_dirty all unchanged. parser cleared. Story 2.5 says cursor shouldn't be there, but the no-op shape is safe. AC3 past-EOF corner.
- **BC preservation in the loop body.** `gapbuf_delete` trashes BC (per gapbuf.asm:142). The loop counter MUST be PUSH/POP'd around each call (Sub 1.4). Alternative is to use IX/IY to hold the counter — but IX/IY usage is a project-wide footprint cost (no other handler uses IX/IY for routine state). PUSH/POP BC is the conventional shape.

### `motion_apply_count` for `x`

`x` consumes `count_accumulator` like a motion handler does (Story 2.5 pattern). The `motion_apply_count` helper:
- Reads count_accumulator into BC.
- If 0, defaults to BC=1 (vi convention: "no count = once").
- Trashes A, F. Preserves BC's caller-saved value if BC was set externally (irrelevant here — first call).

So `x` reads `count_accumulator` indirectly via `motion_apply_count` and gets a guaranteed-non-zero step count. After the handler runs, `parser_dispatch`'s tail-JP `parser_clear` (counted route) OR the handler's own tail-JP `parser_clear` (direct dispatch_normal route) zeroes `count_accumulator` along with `pending_operator` and `pending_motion_prefix`.

### Render integration

`render.asm` reads `cursor_offset` once per frame in `render_diff`'s cursor-reposition step. `x`'s writes to `cursor_offset` (via gapbuf_delete + post-clamp) happen synchronously in the handler; one frame per handler — the deletion + cursor reposition shows in a single render frame.

**Dirty-row marking:** conservative `render_mark_all_dirty` (matching Story 2.8). Fine-grained `render_mark_row_dirty(cursor row)` is a Growth-tier optimisation deferred (per Story 2.8 deferred-work). For `x` specifically, a non-LF delete only changes the cursor's row content — but the cursor's row may already be dirty from a prior keystroke, and render_diff's per-row shadow-diff makes the all-dirty marker cheap-enough.

### Undo stub (FR45 — full impl in 2.13)

Story 2.9 ships `x` WITHOUT recording an undo entry. Rationale (matches Story 2.8's B2 stub):
- Single-level undo (per PRD §V4-B2) records inverse operations: a delete's inverse is "insert N bytes at position".
- The recording mechanism (write to `undo_buffer`, with `msg_undo_too_large` refusal if the bytes exceed UNDO_BUFFER_SIZE = 256) is a Story 2.13 deliverable.
- Story 2.9's `edits_delete_char` success path is the documented hook site — Story 2.13 will insert an `undo_record` call BEFORE the `JP edits_dirty_and_redraw` tail.
- For 2.9, `u` after `x` reports `msg_nothing_to_undo` (the existing "no entry recorded" path — statusln.asm region near msg_nothing_to_undo).

This stub is acceptable for the journey-2 (edit-and-save) flow — undo for `x` is "nice to have" for the deletion journey, not load-bearing for the AC. Document the stub explicitly in the change log AND in deferred-work.md so 2.13's dev knows the hook site.

### Library / framework requirements

- **No new library / framework.** Story 2.9 is sjasmplus + iz-cpm only, like every story in this epic.
- **No new sjasmplus idioms.** Existing patterns suffice (DEFB / DEFW / ASSERT / EQU / INCLUDE / LDIR / LDDR / `$` for current address).
- **No new module.** `x` lives in the existing `src/edits.asm` (the AR25 INCLUDE slot established by Story 2.8). One new public entry; no new internal helpers (reuses the existing shared `edits_dirty_and_redraw` tail from Story 2.8).

### Filename and module placement choices

- **`x` lives in `src/edits.asm`** alongside the i/a/o/O + Backspace + literal/Enter handlers from Story 2.8. The AR25 INCLUDE chain stays unchanged (`statusln → gapbuf → render → dispatch → parser → motions → edits → exline → fileio`).
- **No new public symbols outside `edits_delete_char`.** Reuses the existing shared `edits_dirty_and_redraw` helper from Story 2.8 for the success-path tail.
- **Test naming convention.** Files under `test/cases/edits_x-*.asm` — matches the Story 2.5/2.6/2.7/2.8 per-handler-grouped pattern.
- **Test sentinel allocation.** Continue the Story 2.5 / 2.6 / 2.7 / 2.8 sentinel range 0x80..0x87 per test (per-subtest sentinels enumerated in AC11 / Sub 4.3).

### The `x` keystroke path

```
keystroke 'x' arrives → input_loop checks mode_byte = MODE_NORMAL → dispatch_key against dispatch_normal
                          ├─ binary search dispatch_normal for 'x' (0x78) — found at new entry
                          └─ JP edits_delete_char
                                                 ├─ CALL motion_apply_count (BC := count, default 1)
                                                 ├─ pre-check: byte_at(cursor)
                                                 │     ├─ CF=1 → JP parser_clear (silent no-op)
                                                 │     └─ A == 0x0A → JP parser_clear (silent no-op)
                                                 ├─ delete loop:
                                                 │     ├─ INC cursor_offset
                                                 │     ├─ PUSH BC  (preserve count across gapbuf_delete)
                                                 │     ├─ CALL gapbuf_delete  (cursor-bounce shape; AR14-clean)
                                                 │     ├─ POP BC
                                                 │     ├─ DEC BC
                                                 │     ├─ if BC == 0: exit loop
                                                 │     ├─ byte_at(cursor)
                                                 │     ├─ CF=1 OR A == 0x0A: exit loop (BH2 clamp)
                                                 │     └─ continue
                                                 ├─ post-clamp:
                                                 │     ├─ if cursor == 0: skip clamp
                                                 │     ├─ byte_at(cursor)
                                                 │     ├─ CF=1 OR A == 0x0A: DEC cursor
                                                 │     └─ commit cursor
                                                 ├─ buffer_dirty := 1
                                                 ├─ CALL render_mark_all_dirty
                                                 │     (via shared edits_dirty_and_redraw tail)
                                                 └─ JP parser_clear  (state hygiene)
                                                                                              ; RET to input_loop
                                                                                              ; render_diff runs next iter
                          ; FR45 undo recording stub: Story 2.13 will instrument
                          ; the success-path tail BEFORE edits_dirty_and_redraw
```

### Previous story intelligence

**From Story 2.8 (insert mode i/a/o/O + Backspace + literal + Enter + Esc):**
- `edits.asm` is the established home for edit handlers (lines 1-180 module header established Story 2.8). Extending the Public list + adding a per-entry contract block per AR23 is the documented pattern.
- The `edits_dirty_and_redraw` shared helper (edits.asm:447) is reusable: `LD A, 1; LD (buffer_dirty), A; JP render_mark_all_dirty`. Story 2.9 reuses this for the `x` success-tail.
- The `parser_clear` tail-JP shape (every motion / edit handler ends with `JP parser_clear`) is established; `edits_delete_char` follows the same shape.
- **Backspace's BC handling** (gapbuf_delete trashes BC, but Backspace doesn't loop so BC isn't a concern). `x`'s counted form needs BC across gapbuf_delete — PUSH/POP per iteration. This is novel for edits.asm; motions.asm has the analogous pattern (motion_h / motion_l save BC across gapbuf calls — but motion_h / motion_l don't actually call gapbuf primitives, they only call motion_byte_at_logical which preserves BC). So `x` is the FIRST handler in edits.asm or motions.asm that loops a gapbuf-mutating call.
- **AC11 / D1 review patch in 2.8:** the INSERT-mode literal filter rejects 0x7F + 0x80+ to close the buffer-corruption hazard from synthesised arrow keycodes. Not directly applicable to `x` (NORMAL-mode dispatch_normal keys are bounded), but a related precedent: defensively check for invariant-violating cursor positions.
- **Hardware UAT step 9 lesson from 2.8** — `i` from cursor=0 inserts AT BOF (before existing content), not at the user's mental "cursor on first char" model. Test scripts (and AC traces) must be precise about cursor offsets and the resulting buffer state. Apply the same rigor to AC7 step 6's `5x` from BOL — trace exactly what happens.

**From Story 2.7 (counted motions; verification-heavy):**
- Sticky-column hoist in motions.asm preserves cursor column across counted j/k. Not directly applicable to `x` (no column concept; cursor offset is the only state).
- `motion_apply_count` defaults BC=1 on count==0 — `x` reuses this exact helper.
- **Test fixture lesson:** when designing tests to pin "moved-by-N" or "deleted N bytes", make sure the by-1 outcome differs from the by-N outcome. Apply to `edits_5x-counted.asm`: the cursor + buffer state must be distinguishable between count=1 (deleted 1 byte) and count=5 (deleted 5).
- **Code-review patch P1 in 2.7:** `motions_count-cleared-post-dispatch.asm` had a fixture that collided moved-by-1 with moved-by-5 via the BOF clamp. Apply the lesson — `edits_5x-counted.asm`'s pre-state `"abcdef"` cursor=0 produces clearly distinguishable outcomes (deleted 5 bytes → buffer `"f"` (1 B); deleted 1 byte would → `"bcdef"` (5 B)).

**From Story 2.6 (word/line/buffer motions; helpers):**
- `motion_byte_at_logical` is the BC-preserving byte-read primitive. `x`'s pre-check + post-clamp both use it.
- `motion_find_line_start` / `motion_find_line_end` are NOT used by `x` (no line-bounds math needed; AC3's "no-op on empty line" detected via byte == 0x0A directly, not via line-start/end).
- The "vacuous count_accumulator==0 assertion" lesson — when designing tests that check parser_clear ran, pre-seed the parser-state fields to NONZERO values so the assertion is meaningful. Apply to `edits_x-clears-parser-state.asm`.

**From Story 2.5 (basic motions h/j/k/l; first dedicated motion module):**
- AC13 patches (`JP parser_clear` on every motion handler exit) — the established convention. `edits_delete_char` follows the same shape.
- Helper contracts (BC preservation across `motion_byte_at_logical`) — used here.
- The `enter_normal_mode` / `enter_insert_mode` / `unbound_normal` / `unbound_visual` tail-JP `parser_clear` patches established the "every dispatch path clears parser state" invariant — `x` upholds this.

**From Story 2.4 (file save / `:w` / `:wq`):**
- `buffer_dirty` is the source-of-truth flag. Story 2.8 added the FIRST setters from edit handlers (i/a/o/O / literal / Backspace / Enter); Story 2.9 adds `x` as the next setter.
- `cmd_write` / `cmd_write_quit` clear `buffer_dirty` on success — unchanged by Story 2.9.
- The FR52 invariant ("VIBE never silently truncates or discards user data") — `x` mutates the buffer; the deletion is intentional (user pressed `x`) so no FR52 surface (no rollback needed). However, the user CAN press `:q` post-`x` to lose the deletion — that's covered by the existing `cmd_quit` `buffer_dirty` refusal (Story 2.2 / 2.4).

**From Story 2.2 (file load / `:e`):**
- Buffer-load semantics: post-load, gap-at-0 with all bytes after-gap. First `x` after `:e` may trigger a `gapbuf_move_gap(cursor)` call internal to `gapbuf_delete` (since gap is not at cursor when cursor != 0 post-load). One LDIR shift on the first delete; subsequent deletes at successive cursors are O(1).

**From Story 1.7 (gap buffer primitives):**
- `gapbuf_delete` returns CF=1 at BOF (cursor==0); state UNCHANGED. The cursor-bounce shape (Sub 1.3) ensures we never reach the BOF path because INC takes cursor to a positive offset before the call.
- `gapbuf_delete` trashes A/BC/DE/HL/F. Loop counter MUST be PUSH/POP'd around the call (Sub 1.4).
- `gapbuf_move_gap` is internal to insert/delete (transparently called when gap isn't at cursor). `x` doesn't call it directly.

**From Story 1.10 (parser):**
- `parser_dispatch` (HL = motion / edit handler): the counted-route path. `parser_dispatch` auto-tail-JPs `parser_clear` after the handler RETs. So when `x` is dispatched via the parser (counted), parser_clear runs once (at parser_dispatch's tail).
- `parser_clear` zeros all three parser-state fields. `x` calls it explicitly (handler tail-JP `parser_clear`) so the dispatch_normal direct-route also clears state. Double-call (counted route runs parser_clear twice) is safe — second call is idempotent.

**From Story 1.9 (mode dispatch):**
- `dispatch_normal` is the binary-search MC3 table. Adding `'x'` between `'w'` and `'y'` keeps ASCII sort order; ASSERT pairs catch swap typos at build time.
- `unbound_normal` is the silent fall-through for keys not in dispatch_normal. Pre-Story-2.9, `'x'` fell to `unbound_normal` (silent RET — but per deferred-work line 90, unbound_normal does NOT clear parser state; that's a known issue). Story 2.9 makes `'x'` a bound entry, so the parser-state-not-cleared issue from unbound_normal doesn't apply here.

**From Story 1.5 (status line / single-message funnel):**
- `status_set_message` is the AR12 status writer. `x` does not call it (no error surface). The `msg_nothing_to_undo` surface for post-`x` `u` lives in undo.asm (Story 2.13).

### Git intelligence

Recent commits (post-Story 2.5):

- `57325ff story 2.8: INSERT mode lands; i/a/o/O, typing, backspace, Enter→LF, Esc` — Story 2.8 dev pass.
- `425bc2e code review changes` — Story 2.7 code review (1 P1 + 2 P2 + 4 P3, all small).
- `be63514 story 2.7: counted motions verified end-to-end; sticky-column j/k landed` — Story 2.7 dev pass.
- `dd21ada code review fixes` — Story 2.6 code review.
- `1da2bf1 story 2.6: Wired word/line/buffer motions; w/b/0/$/gg/G with counts; parser stubs retired for motion-0 and gg` — Story 2.6 dev pass.

Patterns to follow:
- Single dev-commit per story containing the production code + tests + spec + sprint-status flips (the Story 2.5 / 2.6 / 2.7 / 2.8 model).
- Separate code-review commit (e.g. `425bc2e`) applying review patches.
- Sentinel byte at `0xCFFE` per TH1 (test/inc/test_prologue.inc).
- INCLUDE chain in test cases: pre-ORG headers (equates/bios/bdos/modes/vt52), then `test_prologue.inc`, test body, `test_epilogue.inc`, production sources (statusln/gapbuf/render/dispatch/parser/motions/edits/exline/fileio), `test_teardown_stub.inc` + `test_input_loop_stub.inc`, finally `inc/state.inc`.
- Gap-buffer fixture pattern: `CALL gapbuf_init` → LDIR from `.payload` into `GAP_BUFFER_BASE` → set `gap_start := GAP_BUFFER_BASE + N`. Mode pre-set via `LD A, MODE_NORMAL ; LD (mode_byte), A` for `x` tests (NORMAL-mode handler).

### Testing requirements

- All 9-10 new tests under `test/cases/edits_x*.asm` and `test/cases/edits_5x*.asm`. Each test must build under `make -C test`, run under iz-cpm with the 5-second timeout, and report PASS via TH1 / TH2.
- The dispatch_normal-driven test (`edits_x-dispatch-normal-routes.asm`) needs `mode_byte = MODE_NORMAL` and the full INCLUDE chain.
- Tests that use `parser_dispatch` for the counted form pre-set `count_accumulator` (e.g. `LD HL, 5; LD (count_accumulator), HL`) and call `parser_dispatch` with HL = `edits_delete_char`. This exercises the real production dispatch path for counted operations.
- Tests that drive directly via `CALL edits_delete_char` exercise the non-counted (count=1 default) path. Both forms are valid; both pin different invariants.
- Sentinel allocation per test detailed in Sub 4.3.

### Project Structure Notes

- **No new source files.** Story 2.9 extends `src/edits.asm` only.
- **No new inc/*.inc files.** All constants (MODE_NORMAL, GAP_BUFFER_MAX, etc.) already declared in modes.inc / equates.inc / state.inc.
- **One new public symbol:** `edits_delete_char` (added to src/edits.asm).
- **dispatch_normal** grows by 1 entry (`'x'` → `edits_delete_char`); slot count 32 → 33.
- **dispatch_insert / dispatch_command / dispatch_visual** unchanged.
- **`state.inc` unchanged.** All needed cells (`mode_byte`, `cursor_offset`, `gap_start`, `gap_end`, `buffer_dirty`, `count_accumulator`) already declared.
- **`src/vibe.asm` INCLUDE chain unchanged.**
- **9-10 new test files under `test/cases/edits_x*.asm` + `test/cases/edits_5x*.asm`.**

### Source tree paths touched

```
.
├── src/
│   ├── edits.asm             # UPDATE — add `edits_delete_char` public entry; module-header docstring extended
│   └── dispatch.asm          # UPDATE — `dispatch_normal` grows by 1 entry (`'x'`)
├── inc/                      # UNCHANGED
├── _bmad-output/
│   ├── planning-artifacts/   # UNCHANGED
│   └── implementation-artifacts/
│       ├── 2-9-single-character-delete-x.md   # THIS FILE
│       ├── deferred-work.md                   # UPDATE (Task 6)
│       └── sprint-status.yaml                 # UPDATE (status flips backlog → ready-for-dev → in-progress → review → done)
└── test/
    └── cases/
        ├── edits_x-mid-line.asm                              # NEW
        ├── edits_x-at-eof.asm                                # NEW
        ├── edits_5x-counted.asm                              # NEW
        ├── edits_x-at-eol-clamp.asm                          # NEW
        ├── edits_x-on-empty-line.asm                         # NEW
        ├── edits_x-past-eof.asm                              # NEW (optional)
        ├── edits_x-empty-buffer.asm                          # NEW
        ├── edits_x-deletes-last-char.asm                     # NEW
        ├── edits_5x-clamps-at-eol.asm                        # NEW
        ├── edits_5x-clamps-at-eof.asm                        # NEW (optional)
        ├── edits_x-clears-parser-state.asm                   # NEW
        └── edits_x-dispatch-normal-routes.asm                # NEW
```

### Files created and modified by this story

**New:**
- `test/cases/edits_x-mid-line.asm`
- `test/cases/edits_x-at-eof.asm`
- `test/cases/edits_5x-counted.asm`
- `test/cases/edits_x-at-eol-clamp.asm`
- `test/cases/edits_x-on-empty-line.asm`
- `test/cases/edits_x-past-eof.asm` (optional)
- `test/cases/edits_x-empty-buffer.asm`
- `test/cases/edits_x-deletes-last-char.asm`
- `test/cases/edits_5x-clamps-at-eol.asm`
- `test/cases/edits_5x-clamps-at-eof.asm` (optional)
- `test/cases/edits_x-clears-parser-state.asm`
- `test/cases/edits_x-dispatch-normal-routes.asm`

**Modified:**
- `src/edits.asm` — `edits_delete_char` public entry added (~50-65 B body); module-header Public list + per-entry contract block extended; Purpose / Dependencies blocks extended.
- `src/dispatch.asm` — `dispatch_normal` grows 32 → 33 entries (new `'x'` entry between `'w'` and `'y'`); `ASSERT 'x' > 'w'` + `ASSERT 'y' > 'x'` re-stitched; module-header comment block (if it enumerates entry counts or bound keys) updated.
- `_bmad-output/implementation-artifacts/deferred-work.md` — Story 2.9 deferred entries (FR45 undo stub for `x`; cursor-bounce-vs-primitive note; BH2 stop-at-EOL semantic note for future composed-op stories).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — 2-9 status flips (backlog → ready-for-dev → in-progress → review → done).
- `_bmad-output/implementation-artifacts/2-9-single-character-delete-x.md` — this file (Tasks checkboxes, Dev Agent Record, File List, Change Log, Status).

### References

- FR28 (the load-bearing FR for this story — delete the character under cursor with `x`): [Source: _bmad-output/planning-artifacts/prd.md] line 744
- FR45 (undo coverage — STUB in 2.9, full impl in 2.13): [Source: _bmad-output/planning-artifacts/prd.md] line 778
- FR46 (undo unavailability surfacing): [Source: _bmad-output/planning-artifacts/prd.md] line 779
- FR50 (unsupported commands as no-op — `x` on empty line / past EOF): [Source: _bmad-output/planning-artifacts/prd.md] line 793-795 region
- FR52 (no silent data loss — `x` deletion is intentional, not a silent loss; user can `:q` to abandon): [Source: _bmad-output/planning-artifacts/prd.md] lines 799-801
- NFR1 (interactive feedback): [Source: _bmad-output/planning-artifacts/prd.md]
- NFR2 (sustained typing throughput ≥10 chars/sec — applies to `x`-repeated): [Source: _bmad-output/planning-artifacts/prd.md] line 108
- NFR3 (predictable cursor-motion latency): [Source: _bmad-output/planning-artifacts/prd.md] lines 820-824
- NFR9 (code size budget — 5120 B ceiling): [Source: _bmad-output/planning-artifacts/prd.md] lines 848-858
- NFR18 (byte-identical rebuild): verified by `make clean && make all`
- BH2 (counted-motion clamps — silent at boundary; applies to counted `x`): [Source: _bmad-output/planning-artifacts/prd.md / architecture.md] BH2 boundary handling section
- MC3 (binary-search dispatch — `dispatch_normal` grows from 32 to 33 entries): [Source: _bmad-output/planning-artifacts/architecture.md] lines 732-738
- MC4 (handler signature — A=key on entry; state via state.inc symbols): [Source: _bmad-output/planning-artifacts/architecture.md] line 1502+
- AR12 / AR13 / AR14 / AR15 (architectural boundaries; edits.asm extends with one more clean handler): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1434-1463
- AR23 (module header contracts): [Source: src/motions.asm:1-146 + src/edits.asm:1-180 header blocks as exemplars]
- AR25 (INCLUDE chain in vibe.asm): [Source: src/vibe.asm:120-160 comment block]
- Story 2.8 (insert mode + edits.asm module + edits_dirty_and_redraw shared helper — direct precedent): [Source: _bmad-output/implementation-artifacts/2-8-insert-mode-i-a-o-o.md]
- Story 2.7 (counted motions; motion_apply_count usage; sticky-column / count-loop patterns): [Source: _bmad-output/implementation-artifacts/2-7-counted-motions.md]
- Story 2.6 (word/line/buffer motions; helpers BC-preservation contracts): [Source: _bmad-output/implementation-artifacts/2-6-word-line-buffer-motions-w-b-0-gg-g.md]
- Story 2.5 (basic motions + AC13 parser_clear hygiene patches; first counted-handler archetype): [Source: _bmad-output/implementation-artifacts/2-5-basic-motions-h-j-k-l.md]
- Story 2.4 (file save; buffer_dirty clear path): [Source: _bmad-output/implementation-artifacts/2-4-file-save-w-w-filename-wq.md]
- Story 2.2 (file load; gap-buffer init from disk; first-delete-after-load gap relocation): [Source: _bmad-output/implementation-artifacts/2-2-file-load-via-e-filename-incl-e.md]
- Story 1.10 (parser — `parser_dispatch` / `parser_clear` / parser_handle_digit count accumulator): [Source: src/parser.asm:32-51 + parser_dispatch body]
- Story 1.9 (mode dispatch — `dispatch_normal` MC3 table; binary-search worst-case bound): [Source: src/dispatch.asm:451-549]
- Story 1.7 (gap buffer primitives — `gapbuf_delete` BOF guard + state-unchanged-on-CF=1 contract): [Source: src/gapbuf.asm:131-180]
- Story 1.5 (status line — `status_set_message`): [Source: src/statusln.asm]
- Architecture: edits.asm module spec extends to FR28: [Source: _bmad-output/planning-artifacts/architecture.md] line 245 + 1302
- Architecture: undo.asm planned for FR45-46 — `x`'s inverse-op recording hook deferred to Story 2.13: [Source: _bmad-output/planning-artifacts/architecture.md] line 1314 + 1540
- deferred-work.md line 90 ("Unbound key in NORMAL doesn't clear parser state") — `'x'` was previously unbound; Story 2.9 binds it so the unbound_normal hygiene gap doesn't apply: [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 90
- Epic 2 spec — Story 2.9 ACs and the cross-story context (2.10 dd/yy + 2.11 dw/d$/c5w as the next composed-edit deliverables that depend on `x`'s deletion shape): [Source: _bmad-output/planning-artifacts/epics.md] lines 1254-1290

## Dev Agent Record

### Agent Model Used

claude-opus-4-7[1m]

### Debug Log References

- AR sweep results: `BIOS_CONOUT` / `LD (gap_start|gap_end), ...` / `BDOS_CALL` greps each show 2 doc-comment matches; zero new code refs. `CALL gapbuf_delete` shows 4 total — 2 code (lines 560, 673) + 2 doc-comment.
- `DISPATCH_NORMAL_COUNT` resolved value: `06 21` in build/vibe.lst (= 33 decimal). Binary-search worst case 6 iterations.
- Two consecutive `make clean && make all` builds: identical MD5 `4703450f67b841c31d35bae3ecff5dd2`, both 4580 B.

### Completion Notes List

- **Handler body size: 64 B** (assembled extent 0x0BB9..0x0BF9). Within the spec's 50-65 B projection. Dispatch entry adds 3 B (DEFB + DEFW). Total Story 2.9 footprint delta: +67 B.
- **Implementation shape:** single loop with iter-top byte check (CF=1 / LF → BREAK to `.exit_loop`). Pre-check + iter-1 check unified — the iter-top check IS the pre-check on iter 1. The no-op vs ≥1-delete distinction is detected at `.exit_loop` via `POP HL=N; SBC HL,BC` (deltas-done == 0 → noop_clear; else commit). This was the simplest correct way to honor AC5's "buffer_dirty NOT touched on no-op path" while sharing one byte-check site between pre-check and loop iter top.
- **PUSH/POP BC bracketing each gapbuf_delete call** preserves the loop counter (gapbuf_delete trashes BC per gapbuf.asm:142). ~2 B per iter overhead.
- **Tail composition:** success path `CALL edits_dirty_and_redraw; JP parser_clear`. The CALL (not JP) is intentional — edits_dirty_and_redraw tail-JPs render_mark_all_dirty which RETs back to us, then the JP parser_clear runs. No-op path skips edits_dirty_and_redraw and `JP parser_clear` directly via `.noop_clear:`.
- **`5x`-from-BOL-on-short-line edge:** counted `5x` from cursor=0 on `"abc\ndef"` (7 B) deletes 'a','b','c' then BREAKs on LF at iter 4. Post-clamp guard at cursor==0 → skip dec. Final: `"\ndef"`, cursor=0 ON the LF — documented Story 2.5 invariant violation, accepted as vi-faithful "x doesn't join lines"; next motion re-establishes invariant. Pinned by `edits_5x-clamps-at-eol.asm`.
- **FR45 undo recording: STUB.** No `undo_buffer` write from `edits_delete_char`. Story 2.13 hook site is the `CALL edits_dirty_and_redraw` instruction's predecessor in the success-path tail (after `.do_clamp:` / `.commit:` merge, before the CALL). Story 2.9 + Story 2.8 share the deferred-undo pattern; both stubs documented in deferred-work.md.
- **Test pass count: 108 → 118 pass / 1 deliberate-fail.** 10 new tests landed:
  - 3 canonical (epics line 1289): `edits_x-mid-line`, `edits_x-at-eof`, `edits_5x-counted`.
  - 7 additional: `edits_x-at-eol-clamp`, `edits_x-on-empty-line`, `edits_x-empty-buffer`, `edits_x-deletes-last-char`, `edits_5x-clamps-at-eol`, `edits_x-clears-parser-state`, `edits_x-dispatch-normal-routes`.
  - Optionals dropped: `edits_x-past-eof` (subsumed by empty-buffer + EOL-clamp shapes), `edits_5x-clamps-at-eof` (subsumed by deletes-last-char + 5x-clamps-at-eol).
- **Hardware UAT (AC7) deferred to user** per spec — story stays at `review` until Ant runs the 12-step UAT script on real MicroBeast.

### File List

**New (10 test files):**
- `test/cases/edits_x-mid-line.asm`
- `test/cases/edits_x-at-eof.asm`
- `test/cases/edits_5x-counted.asm`
- `test/cases/edits_x-at-eol-clamp.asm`
- `test/cases/edits_x-on-empty-line.asm`
- `test/cases/edits_x-empty-buffer.asm`
- `test/cases/edits_x-deletes-last-char.asm`
- `test/cases/edits_5x-clamps-at-eol.asm`
- `test/cases/edits_x-clears-parser-state.asm`
- `test/cases/edits_x-dispatch-normal-routes.asm`

**Modified:**
- `src/edits.asm` — `edits_delete_char` public entry added (64 B body); module-header Public list + per-entry contract block extended; Purpose / State owned / Dependencies blocks updated per AR23.
- `src/dispatch.asm` — `dispatch_normal` grows 32 → 33 entries (new `'x'` entry between `'w'` and `'y'`); `ASSERT 'y' > 'w'` re-stitched to `ASSERT 'y' > 'x'` + new `ASSERT 'x' > 'w'`; module-header `src/edits.asm` dependency block updated with Story 2.9 sentence.
- `_bmad-output/implementation-artifacts/deferred-work.md` — Story 2.9 deferred entries (FR45 undo stub for `x`; cursor-bounce vs new-primitive trade-off; BH2 stop-at-EOL semantic note).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — 2-9 status: ready-for-dev → in-progress → review.
- `_bmad-output/implementation-artifacts/2-9-single-character-delete-x.md` — this file (Tasks/Subtasks checkboxes, Dev Agent Record, File List, Change Log, Status).

### Change Log

| Date       | Change | Notes |
|------------|--------|-------|
| 2026-05-16 | Story 2.9 dev pass complete; `x` lands as the first NORMAL-mode mutating operator (FR28). | `edits_delete_char` body 64 B; AR13/AR14/AR15 sweeps clean; NFR18 byte-identical rebuild; `vibe.com` 4513 → 4580 B (89.45% of 5120 B ceiling); 10 new tests land (118 pass / 1 deliberate-fail). FR45 undo recording is a STUB matching Story 2.8 B2 pattern; documented hook site for Story 2.13 in deferred-work.md. Hardware UAT (AC7) deferred to user. |
| 2026-05-16 | Hardware UAT (AC7) CONFIRMED by Ant on real MicroBeast — all 12 steps pass first iteration. | No regressions against Stories 2.1-2.8; mid-line `x` / counted `x` / EOL-clamp / `x` on empty line (AC3 no-op) / sustained-`x` regression all behave per spec. Code-review pass is the next gate before `done`. |
| 2026-05-16 | Code review applied 3 P3 patches (test-coverage + doc-precision; zero code-logic changes) + 2 defers + ~40 dismissed. Status: review → done. | (P3a, Blind) `edits_x-at-eol-clamp.asm` gained sentinel 0x82 (`buffer_dirty == 1`) assertion — closes coverage gap where a regression dropping `CALL edits_dirty_and_redraw` on the EOL-clamp arm would have passed silently. (P3b, Blind) `edits_x-clears-parser-state.asm` rewired from `CALL parser_dispatch` to direct `CALL edits_delete_char` — pins the handler's OWN tail-JP `parser_clear` independent of parser_dispatch's own tail-JP (verified at src/parser.asm:428-430). (P3c, Edge) `src/edits.asm` module-header + per-entry contract-block FR45 undo hook-site comments tightened to specify the `.commit:` label position (AFTER the SBC HL,BC == 0 deltas-done check, BEFORE `CALL edits_dirty_and_redraw`) — matches deferred-work.md:303 precisely; doc-only, zero byte impact. 2 defers logged to deferred-work.md ("counted x mid-line crossing into LF clamp from non-zero start" coverage gap; "INSERT-mode `x` literal-insert" regression test). ~40 dismissed as noise / verified-safe (HL-preservation contract verified at motions.asm:522-573; BC=0 infinite-loop risk verified safe at motions.asm:663-669; gapbuf_delete CF-skip is spec-conformant per AC8; etc.). Build SHA `4703450f67b841c31d35bae3ecff5dd2` byte-identical x2 (NFR18). Size unchanged 4580 B / 89.45% of 5120 B / 540 B headroom. Test count unchanged 118 pass / 1 deliberate-fail. Acceptance Auditor: 10/12 ACs MET; AC7 + AC12 user-attested per workflow. |
| 2026-05-16 | Story 2.9 created from epics line 1254 | Initial draft; status `ready-for-dev`. 12 ACs, 7 tasks, 9-10 headless tests + 12-step hardware UAT. New public entry `edits_delete_char` lands in existing `src/edits.asm` (no new module). dispatch_normal grows 32 → 33 entries (new `'x'` entry between `'w'` and `'y'`). AC8 (forward-delete via cursor-bounce + gapbuf_delete) chosen over the new-gapbuf-primitive option for AR14-cleanliness + footprint savings. AC4 (counted `x` with BH2 EOL/EOF clamp) is the most algorithmically interesting AC — the loop body uses PUSH/POP BC across each gapbuf_delete to preserve the count. AC6 (FR45 undo recording) is a STUB for 2.9; full impl in 2.13 — hook site documented. NFR9 projected post-2.9 4565-4580 B / ~89% of 5120 B / ~540-555 B headroom — well within. |

### Review Findings

Adversarial code review run 2026-05-16 (Blind Hunter + Edge Case Hunter + Acceptance Auditor parallel layers). All 12 ACs verified MET (AC7 + AC12 not-verifiable-in-diff are user-attested per workflow). 3 patches recommended (all test-coverage / doc-precision; zero code-logic patches), 2 deferred, ~40 dismissed.

- [x] [Review][Patch] `edits_x-at-eol-clamp.asm` does not assert `buffer_dirty == 1` on the success path [test/cases/edits_x-at-eol-clamp.asm]. Peer x-tests use sentinel 0x82 to pin buffer_dirty; this test only checks cursor (0x80) and buffer content (0x81). A regression that drops `CALL edits_dirty_and_redraw` on the EOL-clamp arm of the post-loop clamp would pass silently. Add a sentinel 0x82 assertion at the test tail. (Source: Blind Hunter.) — **APPLIED 2026-05-16:** sentinel 0x82 assertion added; test passes.

- [x] [Review][Patch] `edits_x-clears-parser-state.asm` cannot pin the handler's own `JP parser_clear` [test/cases/edits_x-clears-parser-state.asm]. Test drives via `parser_dispatch`, which independently tail-JPs `parser_clear` (verified at src/parser.asm:428-430). If the handler's tail `JP parser_clear` were replaced by a `RET`, this test would still pass via parser_dispatch's clear. Either modify this test to `CALL edits_delete_char` directly with pre-seeded parser-state, or add a sibling `edits_x-clears-parser-state-direct.asm`. (Source: Blind Hunter.) — **APPLIED 2026-05-16:** rewired to `CALL edits_delete_char` directly (Story 1.10 parser_dispatch tail-JP coverage retained by the other counted-form tests); header comment updated to document the direct-call intent; test passes.

- [x] [Review][Patch] Module-header comment about the FR45 undo hook site is imprecise [src/edits.asm header block]. The comment says the Story 2.13 hook is "just before `CALL edits_dirty_and_redraw`"; the actual position the user wants pinned is "after the `SBC HL,BC == 0` deltas-done check so the no-op path doesn't spuriously emit an empty undo entry" (already correctly documented in `_bmad-output/implementation-artifacts/deferred-work.md:299-301`). Tighten the header comment to match. Doc-only, zero byte impact. (Source: Edge Case Hunter F10.) — **APPLIED 2026-05-16:** both header docstring locations (module-header public-list block + per-entry contract block) tightened to specify the `.commit:` label position (AFTER the SBC HL,BC == 0 check; BEFORE the CALL edits_dirty_and_redraw); NFR18 byte-identical rebuild confirms zero-byte impact.

- [x] [Review][Defer] No headless test for counted form mid-line crossing into LF clamp from non-zero start cursor — deferred, marginal coverage gap. Existing tests cover cursor==0 (LF guard skip) + cursor!=0 with count=1 (LF clamp dec) but not their intersection (e.g., `2x` on `"abc\ndef"` cursor=1 → delete 'b','c', BREAK on LF, post-clamp dec from 1 to 0). The branch shape IS exercised piecewise; the exact intersection isn't. (Source: Blind Hunter.)

- [x] [Review][Defer] No regression test that `'x'` in INSERT mode literally inserts the byte — deferred, broader test-coverage scope. The dispatch_normal vs dispatch_insert gating is exercised by existing INSERT-mode literal-insert tests but no test pins `'x'` specifically in that role. (Source: Edge Case Hunter F11.)

#### Dismissed findings (verified safe / spec-conformant / out-of-scope)

- **HL-preservation contract risk in post-clamp `DEC HL`** (Blind Hunter critical) — DISMISSED. Verified at `src/motions.asm:522-573`: `motion_byte_at_logical` preserves HL on all three exit paths (`.before_gap`, `.after_gap`, `.past_eof`) via PUSH HL / POP HL bracketing. The "HL preserved on every path" contract claim is honored.
- **BC=0 infinite-loop risk in count loop** (Blind Hunter) — DISMISSED. Verified at `src/motions.asm:663-669`: `motion_apply_count` guarantees BC ∈ [1, 65535] (defaults BC=1 when count_accumulator is zero). No defensive guard needed at the handler entry.
- **Cursor lands on LF byte after `5x` from BOL on short line** (Blind Hunter + Edge Case Hunter) — DISMISSED. Spec-accepted vi-faithful behavior; documented in deferred-work.md and pinned by `edits_5x-clamps-at-eol.asm`.
- **No CF check after `gapbuf_delete`** (Blind Hunter) — DISMISSED. AC8 spec explicitly states the cursor-bounce shape never reaches gapbuf_delete's BOF path because the iter-top byte_at pre-check ensures a byte exists to delete.
- **`motion_byte_at_logical` BC-preservation contract latent** (Blind Hunter) — DISMISSED. Verified at `src/motions.asm:511-512`: the routine uses HL+DE only, never touches BC.
- **Patch paths break `git apply -p1`; patch contains duplicate file content** (Blind Hunter) — DISMISSED. Artifact of the `/tmp/story_2_9_full_diff.patch` builder used for the review (absolute paths from a `git diff --no-index /dev/null /home/ant/...` fallback loop). Not a code issue; the committed change applies fine via normal git.
- **Dispatch routing test cannot detect duplicate-`'x'` entries** (Blind Hunter) — DISMISSED. `DISPATCH_NORMAL_COUNT EQU ($ - .entries) / 3` auto-tracks the table; a duplicate entry would break the binary-search sort-order ASSERTs.
- **No mode_byte sanity check at handler entry** (Blind Hunter) — DISMISSED. Other handlers don't do this either; dispatch_normal mode-gates at the dispatch_key call site.
- **`edits_x-deletes-last-char.asm` only checks gap_start half** (Blind Hunter) — DISMISSED. For a single-byte buffer post-delete, the suffix region was empty pre-call; the check is sufficient for this fixture.
- **Sentinel diagnostics capture cursor low byte only** (Blind Hunter) — DISMISSED. Already tracked under Story 2.5's deferred entry; this story inherits the pattern across 10 more sites but does not add a new bug.
- **AC9 FR45 undo stub has no test pinning absence** (Blind Hunter ×2) — DISMISSED. Intentional per AC6; the stub is documented in deferred-work.md:299-301 with the Story 2.13 hook site.
- **Counted form does 2× byte_at probes per iter** (Blind Hunter, Edge Case Hunter F1) — DISMISSED. Defensive-by-design; the iter-top check IS the LF/EOF boundary detector. Acceptable per-iter overhead on a Z80.
- **`OR A; SBC HL,BC` flag idiom future-fragile** (Blind Hunter) — DISMISSED. Standard correct pattern; no current bug.
- **`PUSH BC` discipline future-fragile** (Blind Hunter) — DISMISSED. Currently balanced; future-maintainer hypothesis.
- **`motion_apply_count` side-effects on no-op path** (Blind Hunter) — DISMISSED. The primitive has no side effects beyond reading count_accumulator (verified at `src/motions.asm:663-669`).
- **`edits_5x-clamps-at-eol` doesn't assert past-EOF byte** (Blind Hunter) — DISMISSED. Buffer-length check is implicit via the `cmp_loop` count; redundant with sibling tests.
- **Post-clamp re-reads cursor_offset trusting `gapbuf_delete`** (Blind Hunter) — DISMISSED. Contract-by-design; documented at AC8.
- **`edits_x-empty-buffer.asm` doesn't pre-zero `gap_end`** (Blind Hunter) — DISMISSED. `gapbuf_init` does this.
- **Header docstring uses unicode (em-dash, →)** (Blind Hunter) — DISMISSED. sjasmplus tolerates these in comments; matches the project's existing module-header style.
- **Edge F2 cursor==0 comment incomplete; F3 past-EOF cursor not re-clamped; F5 test-style inconsistency; F6/F7 indirect coverage adequate; F8 was actually tested; F9 `99999x` ~1s worst-case** — all DISMISSED as nits / spec-accepted / verified covered.
- **Acceptance Auditor's F4 (`edits_x-empty-buffer.asm` doesn't assert parser-state cleared)** — DISMISSED. Indirect coverage by `edits_x-on-empty-line.asm` (same `.noop_clear` branch).
- **All 10 Acceptance Auditor spec-deviation findings** — VERIFIED CLEAN. No patches needed: Sub-task claims (1.x through 7.x) all match diff/file evidence; AC4 BH2 invariant-violation pin is genuine; AC6 STUB is clean with no spurious undo recording; sentinel ranges within 0x80..0x87 envelope; dispatch.asm module-header comment updated correctly; no new internal helpers introduced beyond `edits_delete_char`.
