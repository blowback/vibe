# Story 2.7: Counted motions

Status: review

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want any motion key prefixed with a count (e.g. `5j`, `12G`, `3w`, `4h`) to repeat the motion that many times under BH2 clamping,
So that FR23's "user can prefix any motion with a count for repetition" lands with end-to-end verified parser → motion handoff and vi muscle memory transfers for counted navigation.

## Acceptance Criteria

**AC1 — End-to-end count consumption (canonical case).**

**Given** the parser's `count_accumulator` (Story 1.10) and the ten motion handlers landed in Stories 2.5 / 2.6 (motion_h / motion_j / motion_k / motion_l / motion_w / motion_b / motion_0 / motion_dollar / motion_G / motion_gg)
**When** I press digits followed by a motion key (e.g. `'5' 'j'`) so the parser accumulates count = 5 and `motion_j` is dispatched via `dispatch_normal`
**Then** `motion_j` consumes `count_accumulator = 5`, the per-step loop runs 5 times (or clamps before then per BH2), and `parser_clear` zeroes all three parser-state fields on completion
**And** the count read in `motion_j` happens via `motion_apply_count` (already wired in Story 2.5; this AC asserts the consumption is observable end-to-end, NOT that new plumbing lands)

**AC2 — `5h` BOF clamp.**

**Given** `cursor_offset = 3` on a single line and `count_accumulator = 5` (via `'5'` through `parser_handle_digit`)
**When** `motion_h` runs
**Then** `cursor_offset` clamps at 0 (BH2 BOF), the walk stops silently at the clamp (no status banner), and `count_accumulator = 0` post-motion via the `parser_clear` tail-JP

**AC3 — `100j` EOF clamp.**

**Given** a multi-line buffer of N lines (N < 100), cursor on line 5, and `count_accumulator = 100` (via `'1' '0' '0'` through `parser_handle_digit` three times)
**When** `motion_j` runs
**Then** `cursor_offset` clamps at the start of line N (BH2 last-line clamp; the `j` no-next-line guard fires at line N's `motion_find_line_end` past-EOF return), the walk stops silently, and `count_accumulator = 0` post-motion
**And** if the buffer's last line ends in LF, the cursor does NOT land on the phantom past-LF position (the Story 2.5 P5 trailing-LF clamp in `motion_j` is load-bearing here for counted-j as it is for single-step j)

**AC4 — `3w` word-count.**

**Given** the buffer `"one two three four"` (18 bytes, no trailing LF), cursor at offset 0, and `count_accumulator = 3`
**When** `motion_w` runs
**Then** `cursor_offset = 14` (start of `"four"` — the `'f'`), and `count_accumulator = 0` post-motion
**And** with `count_accumulator = 100` on the same buffer, `motion_w` clamps silently at `cursor_offset = file_length = 18` (the EOF sentinel position; the BH2 EOF clamp fires via `motion_byte_at_logical`'s CF=1 return inside the per-step loop)

**AC5 — `12G` line-target with count.**

**Given** a 20-line buffer and `count_accumulator = 12` (via `'1' '2'` through `parser_handle_digit`)
**When** `motion_G` runs
**Then** `cursor_offset` is the start of line 12 (1-indexed; the byte just past the 11th LF), and `count_accumulator = 0` post-motion
**And** with `count_accumulator = 100` on the same 20-line buffer, `motion_G` clamps at the start of line 20 (BH2 last-line clamp via `motion_find_line_n`'s past-EOF / trailing-LF guards)

**AC6 — Count cleared post-dispatch; unprefixed motion moves by 1.**

**Given** any counted motion has just dispatched (e.g. `5j` ran and the cursor moved 5 lines down)
**When** the user presses an unprefixed motion key (`j` alone)
**Then** that follow-up motion moves by 1 step, NOT by the prior count (the `parser_clear` tail-JP at the end of every motion handler is the load-bearing path; verified by pinning the post-dispatch `count_accumulator == 0` invariant in every counted-motion test)

**AC7 — Esc cancels accumulated count without dispatching a motion.**

**Given** the user has typed digits (e.g. `'3'`) so `count_accumulator = 3` but no motion key has arrived
**When** the user presses Esc
**Then** Esc routes to `unbound_normal` (Esc is NOT bound in `dispatch_normal` — falls through to the unbound handler per the AR3 sparse table convention), `unbound_normal` tail-JPs `parser_clear` per the Story 2.5 AC13 patch, and `count_accumulator = 0` post-Esc
**And** `mode_byte = MODE_NORMAL` (unchanged), no motion has fired, and a subsequent unprefixed motion moves by 1
**Note:** This AC verifies the Story 2.5 AC13 hygiene patch covers the count-only case (the original Story 2.5 hardware UAT scenario was `5 : Esc h` exercising the `exline_cancel_core` patch site; AC7 here exercises the `unbound_normal` patch site under the count-only-no-motion path).

**AC8 — Leading `'0'` with no count still dispatches `motion_0`.**

**Given** `count_accumulator = 0` (no digits typed yet) and the user presses `'0'`
**When** `parser_handle_digit` fires from `dispatch_normal['0']`
**Then** the leading-zero arm transfers control via `JP motion_0` (Story 2.6 retired the placeholder stub), the cursor moves to the start of the current line per FR21, and `count_accumulator` remains 0 (preserved across the dispatch because `motion_0`'s tail-JP `parser_clear` zeroes a value that was already zero)
**Note:** The `'0'` key in `dispatch_normal` routes to `parser_handle_digit` (not directly to `motion_0`) precisely so this disambiguation against `'10'` / `'20'` etc. happens centrally in the parser — see `parser.asm`'s AC3-vs-AC4 disambiguation block (line 232+).

**AC9 — Counted-motion mechanics across the motion family.**

The Story 2.5 / 2.6 implementations already wire count consumption per handler. AC9 enumerates the per-handler behaviour under count and pins it via tests:

| Handler | Count source | Count semantics |
|---|---|---|
| `motion_h` | `motion_apply_count` (BC = max(1, count)) | Per-step `cursor_offset -= 1`; BH2 BOF + intra-line LF clamp ends walk early. |
| `motion_l` | `motion_apply_count` | Per-step `cursor_offset += 1`; BH2 EOL + EOF clamp ends walk early. |
| `motion_j` | `motion_apply_count` | Per-step "down one line, column-preserving with shorter-line clamp"; BH2 last-line clamp ends walk early. |
| `motion_k` | `motion_apply_count` | Per-step "up one line, column-preserving"; BH2 first-line clamp ends walk early. |
| `motion_w` | `motion_apply_count` | Per-step "advance to start of next word" (BH1 word class); BH2 EOF clamp ends walk early. |
| `motion_b` | `motion_apply_count` | Per-step "retreat to start of previous word" (BH1); BH2 BOF clamp ends walk early. |
| `motion_0` | (count ignored) | Leading-`'0'` arm precondition: count == 0. Cursor → line_start; no per-step loop. |
| `motion_dollar` | (count ignored) | `5$` semantics ("EOL of line 5 down") deferred per Story 2.6 dev note; `motion_dollar` is "EOL of current line" regardless of count. |
| `motion_G` | direct read of `count_accumulator` | No count → start of last line. With count C → start of line C; BH2 last-line clamp inside `motion_find_line_n`. |
| `motion_gg` | direct read of `count_accumulator` | No count → offset 0. With count C → start of line C (same semantics as `motion_G`'s with-count arm). |

**AC10 — Sticky-column across counted `j` / `k` (decision needed; see Sub 4 below).**

**Given** a 3-line buffer where line 1 has 5 chars, line 2 has 2 chars, line 3 has 5 chars (`"hello\nab\nworld"`), cursor at offset 4 (col 4 of line 1, the `'o'` of `"hello"`)
**When** `motion_j` runs with `count_accumulator = 2`
**Then** the question is whether the cursor lands at col 1 of line 3 (the `'b'` — current motion_j behaviour: col is re-derived per step, so the step-1 clamp to col 1 on line 2's 2-char line propagates to step 2) OR at col 4 of line 3 (the `'l'` — vi-faithful "sticky column" semantics: original col 4 from line 1 is preserved across step 2's wider line)

**Decision required:**
- **Option A (no-fix, document semantics):** Add `motions_count-j-sticky-column.asm` pinning the CURRENT behaviour (cursor lands on `'b'` at col 1). Update the `motion_j` / `motion_k` per-step header comments to note "column is re-derived per step; intermediate shorter-line clamps shrink the running column" and log a Growth-tier entry for vi-faithful sticky-column. Zero code change. **Recommended if NFR9 budget is tight or if the dev wants the smallest delta against Story 2.6's 4376 B.**
- **Option B (fix sticky-column):** Add a per-call (not per-step) saved-column cell in `motions_col` semantics: load `motions_col` from `cursor_offset - line_start(cursor)` ONCE at `motion_j` / `motion_k` entry (before `.step:` loop), and re-use that value at every step's "new_col = min(saved_col, clamp_col)". Add `motions_count-j-sticky-column.asm` pinning the new vi-faithful behaviour. Code delta ~+10..15 B per handler × 2 handlers = ~+20..30 B. **Recommended if vi-faithful muscle memory is the primary calibration (consistent with the Story 2.6 BH1 calibration rationale: "spend where muscle memory matters").**

The Story 2.5 review deferral (deferred-work.md line 216) says: "Add a `motions_count-j-sticky-column.asm` test under Story 2.7 to pin intended semantics — and implement sticky-column if vi-faithfulness is the call." The Story 2.7 dev MUST make this call as part of the story and document the decision in the change log.

**AC11 — Dispatch chain integrity under count.**

**Given** the input loop's keystroke-to-motion path (`input_get_key` → `dispatch_key` → handler → `render_diff`)
**When** the user types `'5' 'j'` on a 10-line buffer
**Then** the count `5` survives across the two `input_loop` iterations (one per keystroke; `count_accumulator` is global state.inc-resident per architecture line 1367), `dispatch_key` routes `'5'` → `parser_handle_digit` then `'j'` → `motion_j`, and the second iteration's `render_diff` reflects the new cursor position
**And** no intermediate handler trashes `count_accumulator` between keystrokes — verified by inspection (between `parser_handle_digit`'s RET and `motion_j`'s read, only `render_diff` runs, and render reads `count_accumulator` nowhere)

**AC12 — Headless tests (all under `test/cases/motions_*.asm` and `test/cases/parser_*.asm`).**

The following tests must pass; the four named in the epic spec are the canonical four. The dev MUST add the additional tests listed to land full AC coverage:

**Canonical (epics spec line 1196):**
- `parser_5j-dispatches-with-count-5.asm` — drives `'5'` through `parser_handle_digit` then `'j'` through `motion_j` (via direct CALL — see Sub 6.4 for the dispatch_key-driven variant); asserts pre-motion `count_accumulator == 5`, motion observed count=5, post-motion cursor advanced 5 lines, parser state cleared. AC1.
- `motions_5h-clamps.asm` — `cursor=3`, `count_accumulator=5`, CALL `motion_h`; assert `cursor=0`, count cleared. AC2.
- `motions_100j-clamps-at-eof.asm` — multi-line buffer with N<100 lines, cursor on line 5, `count_accumulator=100`, CALL `motion_j`; assert cursor at start of last line, count cleared. AC3.
- `motions_3w-three-words-forward.asm` — buffer `"one two three four"`, cursor=0, `count_accumulator=3`, CALL `motion_w`; assert `cursor=14` (the `'f'` of `"four"`), count cleared. AC4.

**Additional (full AC coverage):**
- `motions_12G-line-target.asm` — 20-line buffer (`"line01\nline02\n...\nline20"`), `count_accumulator=12`, CALL `motion_G`; assert cursor at start of line 12, count cleared. AC5.
- `motions_100G-clamps.asm` — 20-line buffer (same as 12G), `count_accumulator=100`, CALL `motion_G`; assert cursor at start of line 20 (BH2 clamp), count cleared. AC5.
- `motions_count-cleared-post-dispatch.asm` — pre-set `count_accumulator=5`, CALL `motion_h` (cursor moves); then `count_accumulator` is now 0; CALL `motion_h` again on the new cursor; assert second call moved cursor by 1 (NOT by 5; "unprefixed motion after counted motion moves by 1"). AC6.
- `motions_esc-clears-count.asm` — pre-set `count_accumulator=3`, drive an Esc keystroke through `dispatch_key` with `dispatch_normal` (Esc is not bound → routes to `unbound_normal`); assert `count_accumulator=0` post-Esc, `mode_byte=MODE_NORMAL` unchanged, `cursor_offset` unchanged. AC7.
- `motions_leading-zero-still-motion-0.asm` — pre-zero parser state, drive `'0'` through `parser_handle_digit` (or `dispatch_normal['0']`); assert `cursor_offset = motion_find_line_start(prior cursor)`, `count_accumulator=0` (preserved), parser state cleared. AC8.
- `motions_count-j-sticky-column.asm` — `"hello\nab\nworld"`, cursor=4, count=2, CALL `motion_j`; assertion target depends on AC10 decision (Option A: cursor at line 3's `'b'` offset = 9; Option B: cursor at line 3's `'l'` offset = 12). AC10.
- `parser_dispatch-key-routes-counted-motion.asm` — pre-zero parser state + minimal gap-buffer fixture, set `mode_byte=MODE_NORMAL`, drive `dispatch_key` with `A='5'` then `A='j'` (using `HL=dispatch_normal`, `B=DISPATCH_NORMAL_COUNT`); assert post-second-call `cursor_offset` advanced + `count_accumulator=0`. AC11.

12 new test files total: 4 canonical + 8 additional. Each test follows the Story-2.5 / 2.6 pattern (pre-zero state, populate gap-buffer via LDIR from `.payload`, pre-set `cursor_offset` + `count_accumulator`, CALL motion, assert via per-test sentinel byte at 0xCFFE; TH1 / TH2 conventions).

**AC13 — Hardware UAT on real MicroBeast (deferred to user; same pattern as Stories 1.11 / 1.12 / 2.1 / 2.2 / 2.3 / 2.4 / 2.5 / 2.6).**

The dev MUST NOT mark this story `done` without confirmed hardware UAT by Ant. The dev pass produces `:wq`-ready code; the user (Ant) runs `make push` and steps through the UAT script.

Hardware UAT script (15 steps):

1. **Pre-state:** boot fresh, no prior `vibe` invocation this session.
2. **`vibe vibe.asm`** (or any multi-screen-tall file) — confirm launches at line 1 / col 0 / cursor at top-left.
3. **`5j`** — cursor moves down 5 lines visibly within ~1 render frame; no banner; status row unchanged. (FR23 + AC1; NFR3 single-frame budget.)
4. **`j`** (no count this time) — cursor moves down ONE line (AC6: post-counted-motion unprefixed motion moves by 1).
5. **`12G`** — cursor jumps to start of line 12; status row unchanged. (AC5.)
6. **`100G`** — cursor jumps to start of LAST line (BH2 clamp, silent — no banner). (AC5.)
7. **`gg`** (no count) — cursor jumps to start of line 1 / offset 0.
8. **`5gg`** — cursor jumps to start of line 5 (AC9 motion_gg with-count arm).
9. **`3w`** — cursor advances 3 words forward; verify on real comment / punctuation content (BH1 word-class transitions hold under count).
10. **`5b`** — cursor retreats 5 words; BH2 BOF clamp on small file.
11. **`5h`** at start of line — silent clamp (AC2; cursor doesn't move past line-start).
12. **`5l`** at end of line — silent clamp (cursor doesn't move past last printable byte; BH2 EOL clamp under count).
13. **`3` then Esc** — count accumulates (no visible feedback per vi tradition), Esc clears count, subsequent unprefixed motion moves by 1. (AC7; exercises `unbound_normal` parser_clear hygiene.)
14. **Mode-transition smoke `5 : Esc j`** — `'5'` accumulates count=5, `':'` enters COMMAND mode, Esc cancels back to NORMAL, count must be cleared, `j` moves by 1 (the Story 2.5 AC13 `exline_cancel_core` patch ground truth; regression net under counted-motion observability).
15. **Sustained-typing regression** — type a counted-motion stream rapidly (e.g. `5j 3w 12G 100j 5h 5l gg G`) over 10 seconds; no dropped keystrokes, no terminal corruption, cursor lands where expected at each motion, no parser-state staleness.

The hardware UAT also looks for regressions against Stories 2.5 / 2.6: w/b/0/$/h/j/k/l basic motions still work after the count tests; CRLF rendering still works (the Story 2.5 UAT-iteration-2 patch); the editor stays interactive (NFR5 — no crashes).

**AC14 — NFR9 monitoring; no architectural amend required for this story.**

The pre-Story-2.7 footprint is 4375 B (post-2.6 code-review SHA `1d9888b0...`) / ~85% of the amended 5120 B ceiling. Story 2.7 is primarily a verification story (12 new test files; production-code additions limited to AC10's sticky-column decision = ~+0 B Option A or ~+20..30 B Option B). The post-2.7 projected footprint is 4375..4405 B / 84..86% of the 5120 B ceiling. **No NFR9 amend required.** Continue the Story-2.6 cadence of monitoring NFR9 against the 5120 B ceiling; flag any unexpected delta (>50 B) for retro review per the PRD amend conditions.

**AC15 — Build invariants (NFR18 byte-identical rebuild; AR enforcement).**

- `make all` followed by `make clean && make all` produces a byte-identical `vibe.com` (NFR18).
- `make test` from a fresh `make clean && make test` tree is green (no stale `.com` files masking failures; the Story 2.5 / 2.6 test/Makefile dependency-hygiene gap remains deferred — see Sub 6.2).
- AR13 / AR14 / AR15 grep sweeps against `src/motions.asm`, `src/parser.asm`, `src/dispatch.asm` remain clean (zero `BIOS_CONOUT_*` / `gapbuf_insert` / `gapbuf_delete` / `gapbuf_move_gap` / `CALL BDOS_ENTRY` / `CALL 0x0005` references). The motions module remains the "clean module" archetype.
- `JP parser_clear` count in `src/motions.asm` is unchanged at 10 sites (1 per handler × 10 handlers; Story 2.7 does not add or remove handlers).
- `parser_motion_zero_stub` / `parser_gg_motion_stub` remain absent (Story 2.6 retired both — no regression).

## Tasks / Subtasks

- [x] **Task 1: AC10 sticky-column decision** (AC10).
  - [x] Sub 1.1: Read deferred-work.md line 216 in full and the Story 2.5 review note context.
  - [x] Sub 1.2: Decide Option A (no-fix, document) or Option B (implement sticky-column). → **Option B** chosen.
  - [x] Sub 1.3: Record the decision and rationale in `## Dev Agent Record → Completion Notes List` of this story file BEFORE writing any code. The choice is load-bearing for Task 4's test assertion target.

- [x] **Task 2: Add the 4 canonical headless tests** (AC1 / AC2 / AC3 / AC4; epics line 1196 verbatim names).
  - [x] Sub 2.1: `test/cases/parser_5j-dispatches-with-count-5.asm` — see AC12 for shape. Pre-zero parser state; populate a 10+ line gap-buffer fixture (e.g. `"line01\nline02\n...\nline10"` = 70 bytes); pre-set `cursor_offset=0`; CALL `parser_handle_digit` with `A='5'`; assert `count_accumulator==5` (Subtest 1 sentinel); CALL `motion_j`; assert `cursor_offset = start of line 6` (Subtest 2 sentinel); assert `count_accumulator==0` (Subtest 3 sentinel). **Implemented with `"L01\n...\nL10"` (39 B; 4-byte slots; line 6 starts at offset 20).**
  - [x] Sub 2.2: `test/cases/motions_5h-clamps.asm` — buffer `"abcdef"` (6 bytes); cursor=3; count=5; CALL `motion_h`; assert cursor=0; assert count cleared. Single-line BOF-clamp under count.
  - [x] Sub 2.3: `test/cases/motions_100j-clamps-at-eof.asm` — buffer of 10 lines (suggested: `"L01\nL02\n...\nL10"` = 39 bytes; NO trailing LF on the last line so the P5 phantom-past-LF case is exercised separately by an existing Story 2.5 test); cursor at start of line 5 (offset 16); count=100; CALL `motion_j`; assert cursor at start of line 10 (offset 36); assert count cleared.
  - [x] Sub 2.4: `test/cases/motions_3w-three-words-forward.asm` — buffer `"one two three four"` (18 bytes); cursor=0; count=3; CALL `motion_w`; assert `cursor=14` (the `'f'` of `"four"`); assert count cleared. Verify by hand: step 1 lands on `'t'` of `"two"` (offset 4); step 2 lands on `'t'` of `"three"` (offset 8); step 3 lands on `'f'` of `"four"` (offset 14). ✓.

- [x] **Task 3: Add the additional AC-coverage headless tests** (AC5 / AC6 / AC7 / AC8 / AC10 / AC11).
  - [x] Sub 3.1: `test/cases/motions_12G-line-target.asm` — 20-line buffer (`"line01\nline02\n...\nline20"`; each line `"lineNN"` is 6 chars + 1 LF = 7 bytes × 20 - 1 LF = 139 bytes if no trailing LF); cursor=0; count=12; CALL `motion_G`; assert cursor = start of line 12 (offset = 7×11 = 77). Count cleared.
  - [x] Sub 3.2: `test/cases/motions_100G-clamps.asm` — same 20-line fixture; count=100; CALL `motion_G`; assert cursor at start of line 20 (offset = 7×19 = 133); count cleared.
  - [x] Sub 3.3: `test/cases/motions_count-cleared-post-dispatch.asm` — buffer `"abcdefg"` (7 bytes); cursor=6; count=5; CALL `motion_h` → cursor=1 (BH2 BOF-region clamp from the .step's intra-line LF check — note: actually for `"abcdefg"` no LFs, so motion_h walks freely; cursor=6, count=5 → step decrements to 1 — but no LF, so count is exhausted normally). After first CALL, count should be 0. Pre-set cursor=6, count=5 directly (no second pre-set); CALL `motion_h`; assert cursor=1; assert count=0. Pre-condition for Subtest 2: cursor=1, count=0 (state from Subtest 1). CALL `motion_h` again; assert cursor=0 (moved by 1, BH2 BOF clamp; the "unprefixed motion moves by 1" invariant). AC6.
  - [x] Sub 3.4: `test/cases/motions_esc-clears-count.asm` — buffer `"abc"`; cursor=1; pre-set `count_accumulator=3`, `mode_byte=MODE_NORMAL`; drive Esc (`A=0x1B`) through `dispatch_key` with `HL=dispatch_normal`, `B=DISPATCH_NORMAL_COUNT`; Esc is not bound → falls to `unbound_normal` → tail-JP `parser_clear`; assert `count_accumulator=0`, `mode_byte=MODE_NORMAL` (unchanged), `cursor_offset=1` (unchanged — Esc didn't move cursor). AC7.
  - [x] Sub 3.5: `test/cases/motions_leading-zero-still-motion-0.asm` — buffer `"hello\nworld"`; cursor=8 (col 2 of line 2 = `'r'`); count=0; CALL `parser_handle_digit` with `A='0'`; the leading-zero arm tail-JPs `motion_0` which JP's `parser_clear`; assert `cursor_offset=6` (start of line 2); assert `count_accumulator=0` (preserved; was 0). AC8.
  - [x] Sub 3.6: `test/cases/motions_count-j-sticky-column.asm` — buffer `"hello\nab\nworld"` (14 bytes); cursor=4 (col 4 of line 1, the `'o'`); count=2; CALL `motion_j`. **Option B** chosen — assertion pins `cursor=13` (col 4 of line 3 = `'d'` of `"world"`; the spec's `cursor=12` projection was an arithmetic bug — col 4 of line 3 starting at offset 9 is `'d'` at offset 13, not `'l'` at 12). Count cleared. AC10.
  - [x] Sub 3.7: `test/cases/parser_dispatch-key-routes-counted-motion.asm` — pre-zero parser state + buffer + `mode_byte=MODE_NORMAL`. Populate a 10-line fixture. Drive `dispatch_key` with `A='5'`, `HL=dispatch_normal`, `B=DISPATCH_NORMAL_COUNT`; assert `count_accumulator=5` post-call (the `'5'` entry routes to `parser_handle_digit`). Drive `dispatch_key` again with `A='j'`; assert `cursor_offset = start of line 6`, `count_accumulator=0` (the `'j'` entry routes to `motion_j` which tail-JPs `parser_clear`). AC11.

- [x] **Task 4: AC10 production code (conditional on Task 1 decision = Option B).** Option B implemented.
  - [x] Sub 4.1: If Option A: skip this task; the `motions_count-j-sticky-column.asm` test pins current behaviour and no source changes are needed. → N/A (Option B chosen).
  - [x] Sub 4.2: If Option B: extract the col-compute block out of `motion_j`'s `.step:` loop body into a one-shot pre-loop block. The current per-step code does `LD HL, (cursor_offset) ; PUSH HL ; CALL motion_find_line_start ; POP DE ; EX DE, HL ; OR A ; SBC HL, DE ; LD (motions_col), HL`. Move this block ONCE before `.step:` so `motions_col` holds the entry-time column. Then in the per-step body, the clamp logic still reads `motions_col` and computes `new_col = min(motions_col, clamp_col)` — but `motions_col` is no longer overwritten per step. → Done (src/motions.asm:305-329).
  - [x] Sub 4.3: Symmetrically for `motion_k`. → Done (src/motions.asm:408-432); at-line-0 check refactored from `LD A,D / OR E` (DE-based) to `LD A,H / OR L` (HL-based, since hoist no longer leaves DE = current_line_start at the check), and one EX DE,HL eliminated in the prev_line_start fetch.
  - [x] Sub 4.4: Verify the AR23 Trashes contract for `motion_j` / `motion_k` is unchanged (still A, BC, DE, HL, F). → Confirmed; motion_find_line_start preserves BC per its AR23 contract.
  - [x] Sub 4.5: Verify existing Story 2.5 tests `motions_j-same-column.asm` / `motions_k-same-column.asm` / `motions_j-shorter-next-line.asm` / `motions_k-shorter-prev-line.asm` still pass — the single-step behaviour is unchanged because the pre-loop block does the same compute the per-step block used to do, just once. → All four pass (single-step behaviour byte-equivalent to pre-hoist).
  - [x] Sub 4.6: Verify the new `motions_count-j-sticky-column.asm` test asserts the Option B cursor=12 target. → Test pins `cursor=13`; the spec's cursor=12 was an arithmetic bug (see Completion Notes).
  - [x] Sub 4.7: Document the choice + size delta in the change log and update the `motion_j` / `motion_k` module comments to reflect the saved-column-across-counted-steps invariant. → STICKY COLUMN INVARIANT block added to both header docstrings; +5 B total delta logged in Change Log.

- [x] **Task 5: NFR3 sanity check** (AC1, AC11).
  - [x] Sub 5.1: Confirm the per-step motion path on a representative counted motion (e.g. `100j` on a 10-line file) completes well inside one render frame. The architecture's NFR3 envelope (NFR3 line 820: "Counted motions (`5j`, `12G`) and large-range operators (`d$`, `dG`) may take proportionally longer but remain interactive (no perceptible freeze)") permits proportional time; this story confirms the existing implementation meets the spirit. No code change expected; if a measurement reveals a stutter on hardware UAT (AC13 step 15 sustained-typing), log to deferred-work and surface for review. → Option B hoist is actually a per-step optimisation for counted j/k (one fewer `motion_find_line_start` call per step in motion_j; same count saved per motion_k step's at-line-0 path). Net per-step T-state cost decreased; NFR3 envelope respected. Sustained-typing UAT step 15 is the qualitative validator.

- [x] **Task 6: Build hygiene + AR sweeps** (AC15).
  - [x] Sub 6.1: `make clean && make all && make test` from a fresh tree must succeed. Confirm `vibe.com` SHA is byte-identical across two consecutive `make clean && make all` (NFR18). → Both builds SHA `e72d102815342b2a5333d4f31314cd1a032998d90515ceaf5bc597429a9b1d62`; size 4380 B / ~85.5% of 5120 B / 740 B headroom.
  - [x] Sub 6.2: The Story 2.5 / 2.6 test/Makefile dependency-hygiene gap (deferred-work line 236 + 255) remains deferred — if it bites during dev (stale `.com` files mask failures), call out in dev notes but do not in-scope a Makefile rework for this story. → Did not bite this story (worked from a `make -C test clean` baseline before the test run); gap remains deferred.
  - [x] Sub 6.3: AR enforcement grep sweeps against `src/motions.asm` / `src/parser.asm` / `src/dispatch.asm`:
    - `grep -n 'BIOS_CONOUT' …` — only doc-comment match in motions.asm header (no code references). ✓
    - `grep -nE 'gapbuf_(insert|delete|move_gap)' …` — only doc-comment match in motions.asm header. ✓
    - `grep -nE 'BDOS_CALL|CALL BDOS_ENTRY|CALL 0x0005' …` — only doc-comment matches (dispatch.asm history, motions.asm "no BDOS" sweep). Zero code references. ✓
    - `grep -c 'JP\s\+parser_clear' src/motions.asm` = **10** (one per public handler × 10). ✓
  - [x] Sub 6.4: Confirm `parser_motion_zero_stub` / `parser_gg_motion_stub` are absent from `src/parser.asm` (Story 2.6 retired both). → Zero matches. ✓
  - [x] Sub 6.5: 81 (pre-2.7 post-review pass count) + 12 new = expected ≥93 pass / 1 deliberate fail. Sub 4 changes (Option B) keep this number; the existing Story-2.5 / 2.6 motion tests still pass under sticky-column because they're single-step. → **92 pass + 1 deliberate fail** (81 + 11; one fewer than spec-projected 12-new because Sub 7.3's optional `parser_motion-prefix-gg.asm` Subtest 3 patch was explicitly out of scope per the story, leaving 11 new test files).

- [x] **Task 7: deferred-work.md housekeeping** (AC10 + Optional).
  - [x] Sub 7.1: Mark deferred-work line 210 (`Story 2.7's count-respected end-to-end test still owed`) as RESOLVED by this story. → Done.
  - [x] Sub 7.2: Mark deferred-work line 216 (`Sticky-column across counted j/k not preserved`) as either RESOLVED (Option B) or REVISED to "documented; vi-faithful sticky-column deferred to Growth tier" (Option A). → Marked RESOLVED (Option B chosen).
  - [x] Sub 7.3: Mark deferred-work line 264 (`parser_motion-prefix-gg.asm Subtest 3 verifies only count==0; doesn't assert cursor landing`) — out of scope; leave as-is unless the dev opts to land the patch alongside other Story 2.6 review deferrals. Document the call in the change log. → Left as-is per spec instruction; Story 2.7 was a verification story for counted motions, not a code-review follow-up pass. Logged in Change Log.
  - [x] Sub 7.4: Add a new "Deferred from: dev of story-2-7-..." section if non-trivial follow-ups surface. Likely candidates: NFR3 sustained-typing measurement methodology; Esc-from-NORMAL formal binding (currently relies on unbound_normal fall-through); CR-byte clamp on motion_h / motion_l (deferred-work line 218 — out of scope here). → No new non-trivial follow-ups surfaced. Spec-arithmetic bug in Sub 3.6 (cursor=12 → actually 13) noted in Completion Notes; doesn't warrant a deferred-work entry.

- [x] **Task 8: Hardware UAT** (AC13). **CONFIRMED by Ant 2026-05-16** — all 15 AC13 steps pass on real MicroBeast first iteration; no regressions, no fix iterations needed.
  - [x] Sub 8.1: Confirm `make push` runs cleanly from the dev environment (SLIDE transfer hook). → Done.
  - [x] Sub 8.2: Step through the 15-step AC13 UAT script with Ant on real MicroBeast. Capture any regression / new failure modes in the change log. → All 15 steps clean; counted j/k/h/l/w/b/G/gg behave per spec under count + BH2 clamps; sticky-column hoist (Option B) holds on hardware; mode-transition `5:Esc j` count-clear (the Story 2.5 AC13 patch on `exline_cancel_core`) regression net holds; sustained-typing across counted-motion stream shows no dropped keystrokes, no terminal corruption, no parser-state staleness. No regressions against Stories 2.5 / 2.6 (basic motions + CRLF rendering + editor interactivity).
  - [x] Sub 8.3: Story is NOT `done` until AC13 confirmed. → AC13 confirmed; dev pass complete inclusive of hardware UAT; ready for code review pass.

## Dev Notes

### Architecture compliance

- **AR13 (no screen emission from motions).** Story 2.7 is verification-only; no `BIOS_CONOUT` additions to `src/motions.asm`. The cursor reposition under counted motion is driven by `render.asm`'s RI4 invariant on the next `render_diff` frame (per `input_loop` step 4: `render_diff` runs after every handler).
- **AR14 (no buffer mutation from motions).** Counted motions only read `gap_start` / `gap_end` via SR3 math in `motion_byte_at_logical`. No `gapbuf_insert` / `gapbuf_delete` / `gapbuf_move_gap` calls — the motions module remains the "clean module" archetype.
- **AR15 (no raw BDOS from motions / parser / dispatch).** Zero `BDOS_CALL` / `CALL BDOS_ENTRY` / `CALL 0x0005` references. Sub 6.3 enforces this via grep sweep.
- **AR12 (status messages via funnel).** Counted motions do NOT surface "X moves clamped to Y" banners (BH2 says clamps are silent). The parser's `parser_doubled_operator_stub` is the only status-line emitter in the parser module and is unchanged by Story 2.7.
- **AR23 (module header documentation).** If Task 4 (Option B) lands, update the `motion_j` / `motion_k` header comments to reflect the saved-column-across-counted-steps invariant; otherwise leave headers unchanged. Either way, the `is_word_char` / `motion_apply_count` / `motion_find_line_n` / `motion_find_line_start` / `motion_find_line_end` / `motion_byte_at_logical` helper contracts are unchanged.
- **AR25 (INCLUDE chain).** `src/vibe.asm`'s INCLUDE order (statusln → gapbuf → render → dispatch → parser → motions → exline → fileio) is unchanged. Story 2.7 adds no new src/*.asm files.
- **MC3 (binary-search dispatch).** Unchanged. `dispatch_normal` count remains 32 entries (Story 2.6 final); worst-case binary-search iterations = 5 (`ceil(log2(32)) = 5`). NFR3 unaffected.
- **MC4 (handler signature — A=key on entry; state from fixed addresses).** Motion handlers read `count_accumulator` via state.inc symbols (no register-passed count). Unchanged.
- **BH1 (word-boundary classifier).** Unchanged from Story 2.6; `is_word_char` is the single classifier used by `motion_w` / `motion_b` under count.
- **BH2 (counted-motion clamps).** Story 2.7 verifies that every counted motion clamps silently at the BOF / EOF / line-start / line-end boundaries per its handler's per-step logic. No new clamp paths are added — Story 2.5 / 2.6 already wired them; Story 2.7 pins them via test.
- **NFR3 (predictable cursor-motion latency).** Counted motions are explicitly allowed to take proportionally longer (PRD line 820-823); the AC13 sustained-typing UAT confirms no perceptible freeze. No measurement instrumentation is added — the freeze threshold is qualitative.
- **NFR9 (code size).** Footprint projected 4375..4405 B / 84..86% of the 5120 B ceiling. No amend needed.
- **NFR18 (byte-identical rebuild).** Verified in Sub 6.1.
- **FR23 (counted motions — the load-bearing FR for this story).** End-to-end verification via the 12 headless tests in AC12 plus hardware UAT in AC13.

### The count-handoff state graph

The parser → motion handoff is implemented as global state passing via `state.inc`. Reproduced here so the dev can trust the state shape:

```
keystroke '5' arrives → dispatch_normal['5'] → parser_handle_digit
                                                 ├─ XOR A ; LD (pending_motion_prefix), A   ; clear prefix
                                                 ├─ LD HL, (count_accumulator)              ; HL = 0 (first digit)
                                                 ├─ ... HL := HL*10 + digit                 ; HL = 5
                                                 └─ LD (count_accumulator), HL              ; cell = 5
                                                                                              ; RET to input_loop

keystroke 'j' arrives → dispatch_normal['j'] → motion_j
                                                 ├─ CALL motion_apply_count                 ; reads count_accumulator
                                                 │     ├─ LD BC, (count_accumulator)        ; BC = 5
                                                 │     ├─ A=B|C ; if zero set BC=1; here BC stays 5
                                                 │     └─ RET                                ; BC = 5 at .step entry
                                                 ├─ .step (5 iterations):
                                                 │     ├─ compute col, find next line, clamp
                                                 │     └─ DEC BC ; loop while non-zero
                                                 ├─ JP parser_clear
                                                 │     ├─ XOR A ; LD (pending_operator), A
                                                 │     ├─ LD (pending_motion_prefix), A
                                                 │     └─ LD HL, 0 ; LD (count_accumulator), HL    ; cell = 0
                                                                                              ; RET to input_loop
```

The key invariants the dev should keep in mind:

1. **`count_accumulator` is global state.inc storage** at a fixed address (`static_data_base + 0x11`, computed at assembly time). Both the parser writer and the motion reader address it by symbol — no register-passed handoff.
2. **`parser_handle_digit` clears `pending_motion_prefix` on entry** (line 224-226 of `parser.asm`). This is critical for the `5gg` case: after `'5'` arrives, any stale `'g'` from a prior keystroke is dropped. Otherwise `5gg` could mis-compose if the prior 'g' state survived.
3. **`motion_apply_count` defaults to 1 on count==0** (`motions.asm` line 648-654). Vi tradition: `j` = `1j`. This is why `motion_G` and `motion_gg` read `count_accumulator` DIRECTLY (not via `motion_apply_count`) — their no-count semantic is "last line" / "line 1", NOT "line 1" / "line 1".
4. **Every motion handler tail-JPs `parser_clear`.** Counted or not. This zeroes all three parser-state fields atomically. After `5j`, the next keystroke sees count=0; this is the AC6 invariant.
5. **The 16-bit zero test idiom** for `count_accumulator` is `LD A, H ; OR L` (sets Z iff both bytes are zero). A low-byte-only test would mis-classify counts whose low byte is zero (e.g. 256) as zero — `parser.asm` line 240-242 + `motions.asm` line 1023-1024 + 1062-1063 all use this idiom correctly.

### Library / framework requirements

- **No new library / framework.** Story 2.7 is sjasmplus + iz-cpm only, like every story in this epic. The headless tests use the established Story 2.5 / 2.6 pattern (INCLUDE production sources in the test `.com`, populate gap-buffer fixture via LDIR, drive motion handler, assert via sentinel byte at 0xCFFE).
- **No new sjasmplus idioms.** Existing patterns suffice. The "drive `dispatch_key` end-to-end" pattern in `parser_dispatch-key-routes-counted-motion.asm` follows the Story 1.9 / 1.10 `dispatch_*.asm` test convention (caller pushes return frame via the CALL; `dispatch_key` does its RET-to-pushed dance internally).

### Filename and module placement choices

- **Test naming convention.** Files under `test/cases/motions_*.asm` exercise motion handlers directly; files under `test/cases/parser_*.asm` exercise the parser path (with or without motion follow-up). Story 2.7's `parser_5j-dispatches-with-count-5.asm` lives under `parser_*` per spec line 1196 even though it CALLs `motion_j`; the canonical name from the epic stands.
- **Test sentinel allocation.** Continue the Story 2.5 / 2.6 0x80..0x87 range. Each test allocates its own sentinel byte per the established convention (the test header `Sentinel codes at 0xCFFE on failure (TH1)` block enumerates per-subtest codes).

### Counted-motion semantics — known sharp edges

- **`100j` over a 5-line file ending in LF.** Story 2.5's P5 trailing-LF clamp in `motion_j` (line 330-336) handles this for single-step j; counted j uses the same per-step path, so the clamp fires on the step that would otherwise advance past the trailing LF. AC3's test fixture should NOT have a trailing LF (to keep the clamp behaviour simple); a separate Story-2.5 test (`motions_j-past-trailing-lf.asm`) covers the trailing-LF case.
- **`12G` on a 5-line file.** `motion_G`'s with-count arm calls `motion_find_line_n` with `DE=12`. The helper walks forward, finds 4 LFs, and on the 5th iteration `motion_byte_at_logical` returns CF=1 (past EOF) → `.clamp` returns the prior candidate (start of line 5). AC5's `motions_100G-clamps.asm` test pins this.
- **`5$` is "EOL of current line" (count ignored).** The Story 2.6 dev note (deferred-work.md line 110-111 region) documents this: vi traditionally treats `5$` as "EOL of line 5 down", but VIBE defers that semantic. AC9 enumerates this. No test in Story 2.7 covers `5$` because the behaviour is "count ignored" — the existing Story-2.6 `motions_dollar-*` tests are sufficient.
- **`0` after a digit is part of the count.** `parser_handle_digit`'s AC3-vs-AC4 disambiguation: `'1' '0'` = count 10, not "count 1 then motion to line-start". `parser.asm` line 232-242 implements this via the 16-bit zero test idiom. AC8 verifies the leading-zero case (no prior digit); the `'1' '0'` non-leading case is verified indirectly by `parser_count-accumulator.asm` (Subtest 2 from Story 1.10) which uses `'1' '2'` — the same code path. No new test needed for `'1' '0'`.
- **Count `0` arriving as the first digit is `motion_0` only when `pending_motion_prefix` is also 0.** If the user types `g 0`, the `'0'` arrives with `pending_motion_prefix='g'`. `parser_handle_digit` clears `pending_motion_prefix` on entry (line 224-226), THEN does the leading-zero check. So `g 0` clears the 'g', then dispatches `motion_0`. This is the documented behaviour (parser asymmetric-clear protocol). No test in Story 2.7 covers `g 0` specifically; the `parser_motion-prefix-cleared-on-other-key.asm` test (Story 1.10) covers the clear-on-digit-entry path.

### Sticky-column decision context (AC10)

The Story 2.5 review surfaced this as a deferral; the Story 2.6 dev did not in-scope it. Story 2.7 owns the decision.

**Arguments for Option A (no-fix):**
- The Story 2.6 footprint sits at 4376 B / 85% of NFR9 ceiling. Option A keeps the budget at 4375 B.
- The AC4 step list reads "Cache col across the step" (singular) — the implementation is spec-faithful as-is.
- Real vi's sticky-column is a quality-of-life feature, not a correctness invariant. A user typing `5j` on jagged-line content will not be confused if the cursor settles at a shorter column.
- The Growth-tier `gj` / `gk` display-line motions would need a richer sticky-column design anyway (display columns vs logical columns).

**Arguments for Option B (vi-faithful sticky-column):**
- The Story 2.5 / 2.6 BH1 / BH2 calibration philosophy is "spend where muscle memory matters" (architecture line 671-674). A vi user types `5j` expecting column preservation across all 5 steps; current behaviour shrinks the column over short-line intermediates.
- The implementation is ~20-30 B per handler × 2 handlers (`motion_j`, `motion_k`) = ~+40-60 B; well within the 744 B NFR9 headroom.
- The user (Ant) is a vi-fluent author whose journey docs (PRD §journey-1a) imply sticky-column expectations.

**Recommendation:** Option B if the dev judges the user's vi-fluency calibration is the primary driver; Option A if NFR9 monitoring discipline + spec-text-faithful reading is the primary driver. **Both are defensible — the dev MUST document the rationale.**

### Render integration — no changes required

`render.asm` reads `cursor_offset` once per frame in `render_diff`'s cursor-reposition step (line ~end of render_diff). Counted motions update `cursor_offset` to its final destination in a single handler invocation (one `input_loop` iteration). The render path sees ONE frame per handler — counted motions do not produce intermediate cursor positions on screen. This is the correct vi behaviour (no flicker as the cursor walks through intermediate positions) and emerges naturally from the architecture's "render after handler" loop shape.

### Previous story intelligence

**From Story 2.5 (h/j/k/l basic motions):**
- `motion_apply_count` is the centralized count-defaulting helper. BC=max(1, count_accumulator). All h/j/k/l/w/b motions use it.
- The Story 2.5 P5 trailing-LF clamp in `motion_j` is load-bearing under counted-j; the same clamp fires per step.
- The Story 2.5 AC13 patches (RET → JP parser_clear on `enter_normal_mode` / `enter_insert_mode` / `enter_visual_mode` / `unbound_normal` / `unbound_visual`) are the foundation for AC7 (Esc-clears-count) — the count is cleared via `unbound_normal`'s tail-JP `parser_clear`, NOT via a dedicated Esc handler.
- The Story 2.5 review patch `exline_cancel_core` → `JP parser_clear` is the foundation for AC13 step 14 (`5 : Esc j`).

**From Story 2.6 (w/b/0/$/gg/G motions):**
- `motion_G` / `motion_gg` read `count_accumulator` DIRECTLY (not via `motion_apply_count`) because their no-count semantic differs from `motion_apply_count`'s "0 → 1" default.
- `motion_find_line_n` is the shared "walk to line N" helper. With DE=0xFFFF it walks to the last reachable line (used by `motion_G`'s no-count arm).
- `motion_dollar` ignores count per the Story 2.6 dev note.
- `motion_0` ignores count by precondition (only reached when count_accumulator=0).
- The Story 2.6 review left `parser_motion-prefix-gg.asm` Subtest 3 with only a count-cleared check (no cursor-landing check). Story 2.7 can optionally patch this — see Sub 7.3.

**From the long line of deferred-work items spanning Stories 1.10 / 2.5 / 2.6:**
- Mode-state protocol documentation (Story 1.3 deferral) is partially captured in the parser.asm asymmetric-clear protocol block. The count_accumulator's lifecycle (set by parser_handle_digit; cleared by parser_clear) is now well-documented in code and in this story's "count-handoff state graph" section.
- `count_accumulator` overflow (`count*10 + digit` wraps at 65536) is vi-tradition silent wrap per `parser_count-accumulator.asm` Subtest 5 (sentinel 0xE5). No Story 2.7 test exercises overflow under motion dispatch.

### Git intelligence

The last 5 commits represent the Story 2.5 → 2.6 transition (basic motions → word/line/buffer motions → code review). Story 2.7 lands as the next commit (post-code-review of 2.6). Test patterns to follow:
- Sentinel byte at `0xCFFE` per TH1 (test/inc/test_prologue.inc).
- INCLUDE chain in test cases: pre-ORG headers (equates/bios/bdos/modes/vt52), then `test_prologue.inc` (ORG 0x0100 + sentinel zero + test_start), test body, `test_epilogue.inc`, production sources (statusln/gapbuf/render/dispatch/parser/motions/exline/fileio), `test_teardown_stub.inc` + `test_input_loop_stub.inc`, finally `inc/state.inc`.
- Gap-buffer fixture pattern: `CALL gapbuf_init` → LDIR from `.payload` into `GAP_BUFFER_BASE` → `LD HL, GAP_BUFFER_BASE + N ; LD (gap_start), HL`. This populates the before-gap region with `N` bytes; `gap_end` remains at `GAP_BUFFER_BASE + GAP_BUFFER_MAX` from `gapbuf_init`.

### Testing requirements

- All 12 new tests under `test/cases/`. Each test must build under `make -C test`, run under iz-cpm with a 5-second timeout, and report PASS via TH1 / TH2.
- The dispatch_key-driven test (`parser_dispatch-key-routes-counted-motion.asm`) needs `mode_byte = MODE_NORMAL` and the full INCLUDE chain so `dispatch_normal` is in the test binary; the established Story 2.5 `motions_parser-clear-on-unbound.asm` test is a structural reference.
- Per-test sentinel allocation (suggested):
  - `parser_5j-dispatches-with-count-5.asm` → 0x80 (count pre-motion), 0x81 (cursor post-motion), 0x82 (count post-motion).
  - `motions_5h-clamps.asm` → 0x80 (cursor), 0x81 (count).
  - `motions_100j-clamps-at-eof.asm` → 0x80, 0x81.
  - `motions_3w-three-words-forward.asm` → 0x80, 0x81.
  - `motions_12G-line-target.asm` → 0x80, 0x81.
  - `motions_100G-clamps.asm` → 0x80, 0x81.
  - `motions_count-cleared-post-dispatch.asm` → 0x80 (cursor1), 0x81 (count1), 0x82 (cursor2 — must be moved-by-1 not moved-by-5).
  - `motions_esc-clears-count.asm` → 0x80 (count), 0x81 (mode_byte), 0x82 (cursor unchanged).
  - `motions_leading-zero-still-motion-0.asm` → 0x80 (cursor), 0x81 (count).
  - `motions_count-j-sticky-column.asm` → 0x80 (cursor — assertion depends on AC10 choice), 0x81 (count).
  - `parser_dispatch-key-routes-counted-motion.asm` → 0xE1 (count post-'5'), 0xE2 (cursor post-'j'), 0xE3 (count post-'j').
- The "count cleared post-motion" assertion (sentinel 0x81 in many tests) is now genuinely covered (per the Story 2.6 review note that no-count tests with sentinel 0x81 are vacuous — Story 2.7's tests pre-seed `count_accumulator` to a nonzero value, so the post-call zero assertion is real coverage).
- Update `test/Makefile` `clean` target to enumerate all 12 new `.com` files (if Story 2.5 / 2.6 dependency-hygiene gap hasn't been fixed by the time this story lands; it remains deferred per Sub 6.2).

### Project Structure Notes

- **No new src/*.asm or inc/*.inc files.** Story 2.7 is verification-heavy; production-code additions limited to AC10 Option B (in-place modification of `motion_j` / `motion_k` in `src/motions.asm`).
- **No new public symbols.** Existing motion handlers consume `count_accumulator`; no new entries land.
- **No `dispatch_normal` table changes.** All keys the story exercises are already wired (Stories 1.9 / 2.5 / 2.6).
- **No `state.inc` changes.** `count_accumulator` already declared; no new cells required.
- **12 new test files under `test/cases/`.** Naming follows the `motions_*.asm` / `parser_*.asm` convention.

### Source tree paths touched

```
.
├── src/
│   ├── motions.asm            # UPDATE (only if AC10 Option B chosen — Sub 4.2/4.3)
│   ├── parser.asm             # UNCHANGED
│   └── dispatch.asm           # UNCHANGED
├── inc/
│   └── state.inc              # UNCHANGED
├── _bmad-output/
│   ├── planning-artifacts/
│   │   ├── prd.md             # UNCHANGED
│   │   ├── architecture.md    # UNCHANGED
│   │   └── epics.md           # UNCHANGED
│   └── implementation-artifacts/
│       ├── 2-7-counted-motions.md   # THIS FILE
│       ├── deferred-work.md         # UPDATE (Task 7)
│       └── sprint-status.yaml       # UPDATE (final task — flip 2-7 to ready-for-dev → in-progress → review)
└── test/
    └── cases/
        ├── parser_5j-dispatches-with-count-5.asm         # NEW
        ├── parser_dispatch-key-routes-counted-motion.asm # NEW
        ├── motions_5h-clamps.asm                         # NEW
        ├── motions_100j-clamps-at-eof.asm                # NEW
        ├── motions_3w-three-words-forward.asm            # NEW
        ├── motions_12G-line-target.asm                   # NEW
        ├── motions_100G-clamps.asm                       # NEW
        ├── motions_count-cleared-post-dispatch.asm       # NEW
        ├── motions_esc-clears-count.asm                  # NEW
        ├── motions_leading-zero-still-motion-0.asm       # NEW
        ├── motions_count-j-sticky-column.asm             # NEW (AC10)
        └── parser_motion-prefix-gg.asm                   # OPTIONAL UPDATE (Sub 7.3 — Subtest 3 patch)
```

### Files created and modified by this story

**New:**
- `test/cases/parser_5j-dispatches-with-count-5.asm`
- `test/cases/parser_dispatch-key-routes-counted-motion.asm`
- `test/cases/motions_5h-clamps.asm`
- `test/cases/motions_100j-clamps-at-eof.asm`
- `test/cases/motions_3w-three-words-forward.asm`
- `test/cases/motions_12G-line-target.asm`
- `test/cases/motions_100G-clamps.asm`
- `test/cases/motions_count-cleared-post-dispatch.asm`
- `test/cases/motions_esc-clears-count.asm`
- `test/cases/motions_leading-zero-still-motion-0.asm`
- `test/cases/motions_count-j-sticky-column.asm`

**Modified:**
- `src/motions.asm` — only if AC10 Option B (sticky-column fix); otherwise unchanged.
- `_bmad-output/implementation-artifacts/deferred-work.md` — Task 7 housekeeping.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — final status flips.

**Optionally Modified:**
- `test/cases/parser_motion-prefix-gg.asm` — Sub 7.3, add cursor-landing assertion to Subtest 3.
- `test/Makefile` — Sub 6.2, extend `clean` target for the 11-12 new `.com` files (mechanical).

### References

- FR23 (counted motions — primary FR for this story): [Source: _bmad-output/planning-artifacts/prd.md] lines 733-734
- FR18-FR22 (motion vocabulary — counts compose with each): [Source: _bmad-output/planning-artifacts/prd.md] lines 725-732
- BH1 (word-boundary classifier — `motion_w` / `motion_b` under count): [Source: _bmad-output/planning-artifacts/architecture.md] lines 668-675
- BH2 (counted-motion bounds — clamp at BOF/EOF for all counted motions): [Source: _bmad-output/planning-artifacts/architecture.md] lines 677-680
- NFR3 (predictable cursor-motion latency — counted motions explicitly allowed to take proportionally longer): [Source: _bmad-output/planning-artifacts/prd.md] lines 820-824
- NFR9 (code size budget — 5120 B ceiling; Story 2.7 stays well within): [Source: _bmad-output/planning-artifacts/prd.md] lines 848-858
- NFR18 (byte-identical rebuild): verified by `make clean && make all` per Sub 6.1
- MC3 (binary-search dispatch table — `dispatch_normal` already lex-sorted at 32 entries): [Source: _bmad-output/planning-artifacts/architecture.md] lines 732-738
- MC4 (handler signature — A=key on entry; count via state.inc): [Source: _bmad-output/planning-artifacts/architecture.md] line 1502+
- AR12/AR13/AR14/AR15 (architectural boundaries — motions.asm "clean module" archetype): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1434-1463
- AR23 (module header contracts): [Source: src/motions.asm:1-146 header block]
- AR25 (INCLUDE chain in vibe.asm): [Source: src/vibe.asm:160-217]
- Story 2.5 (basic motions h/j/k/l — `motion_apply_count` introduction; AC13 parser_clear hygiene patches): [Source: _bmad-output/implementation-artifacts/2-5-basic-motions-h-j-k-l.md]
- Story 2.6 (word/line/buffer motions — direct count read in `motion_G` / `motion_gg`; `motion_find_line_n` helper): [Source: _bmad-output/implementation-artifacts/2-6-word-line-buffer-motions-w-b-0-gg-g.md]
- Story 1.10 (parser — `parser_handle_digit`, `parser_handle_operator`, `parser_handle_motion_prefix`, `parser_dispatch`, `parser_clear`): [Source: src/parser.asm:1-465]
- Story 1.9 (mode-dispatch — `dispatch_key`, `dispatch_normal`, `unbound_normal`): [Source: src/dispatch.asm:1-555]
- Story 1.12 (init / teardown — `count_accumulator` first cleared by cold-start LDIR fill): [Source: src/init.asm:178-339]
- Deferred-work entry for Story 2.7's count-respected end-to-end test (RESOLVED by this story): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 210
- Deferred-work entry for sticky-column across counted j/k (DECIDED in AC10 / Task 1): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 216
- Deferred-work entry for `parser_motion-prefix-gg.asm` Subtest 3 (OPTIONAL Sub 7.3): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 264
- src/motions.asm (10 public handlers, 6 internal helpers, 2 module-local scratch cells; AC16 Path A — motion_byte_at_logical lives here): [Source: src/motions.asm]
- src/parser.asm (3 public handlers + parser_dispatch + parser_clear + parser_doubled_operator_stub; asymmetric-clear protocol): [Source: src/parser.asm:32-51]
- src/dispatch.asm (`dispatch_normal` 32-entry sparse sorted table; binary-search dispatcher): [Source: src/dispatch.asm:430-528]
- src/vibe.asm (`input_loop` — `input_get_key` → per-mode demultiplex → `dispatch_key` → `render_diff` → repeat): [Source: src/vibe.asm:171-217]
- inc/state.inc (`count_accumulator` 16-bit cell; `pending_operator` / `pending_motion_prefix` 1-byte cells): [Source: inc/state.inc:52-75]
- test/inc/test_prologue.inc + test_epilogue.inc + test_teardown_stub.inc + test_input_loop_stub.inc (test scaffolding — INCLUDE chain template): [Source: test/inc/]
- Hardware UAT script for Story 2.6 (similar 17-step format; Story 2.7's 15-step builds on the same conventions): [Source: _bmad-output/implementation-artifacts/2-6-word-line-buffer-motions-w-b-0-gg-g.md AC13 section]

## Dev Agent Record

### Agent Model Used

claude-opus-4-7[1m]

### Debug Log References

### Completion Notes List

- **AC10 sticky-column decision (Task 1): Option B — implement vi-faithful sticky-column** across counted `j` / `k`. Decided 2026-05-15 BEFORE any code or test lands. Rationale: (1) vi-fluency calibration is the primary driver per the Story 2.5 / 2.6 BH1 / BH2 philosophy "spend where muscle memory matters" (architecture line 671-674); (2) NFR9 headroom is comfortable — projected delta ~+20-30 B against the 745 B headroom (post-2.6 was 4375 B / 85% of 5120 B); (3) the user (Ant) is a vi-fluent author whose journey-1a flow implies sticky-column expectations across counted `j` / `k`; (4) deferred-work.md line 216 explicitly framed the call as "implement sticky-column if vi-faithfulness is the call." Test `motions_count-j-sticky-column.asm` pins the Option B target.
- **Spec arithmetic bug noted in Sub 3.6.** The story's "Option A: cursor=9 (col 1 of line 3 = 'b')" and "Option B: cursor=12 (col 4 of line 3 = 'l')" are wrong. The buffer `"hello\nab\nworld"` has line 3 starting at offset 9 (`'w'`), so col 1 = `'o'` (offset 10) and col 4 = `'d'` (offset 13). The Option B test target is `cursor=13`, not 12. Documenting here; the test pins the correct value derived from first principles.
- **Option B size delta: +5 B net** (post-2.6 4375 B → post-2.7 4380 B), well under the ~+20-30 B spec projection. motion_j: net 0 B (the 15-byte col-compute block moved out of `.step:` and back in once at entry; equal). motion_k: +5 B (the col-compute hoist itself is 0 B; the at-line-0 check refactor from DE-based to HL-based and the prev_line_start fetch lost an EX DE,HL for a small net gain on shape, but offset by extra `LD HL, (cursor_offset) ; CALL motion_find_line_start` re-entry into the .step body to re-derive current_line_start each step).
- **Sub 7.3 decision (parser_motion-prefix-gg.asm Subtest 3 cursor-landing assertion):** left as-is per spec instruction. Story 2.7 is a verification story for counted motions, not a code-review follow-up pass; the existing `motions_gg-with-count.asm` test already pins motion_gg's with-count cursor landing (offset 6 = start of line 2 on a 2-line buffer with count clamping at the last line). The optional patch can land in a future Story 2.6 review-follow-up pass.
- **All 16 ACs:** AC1-AC11 + AC12 covered by the 11 new tests + sticky-column hoist; AC13 hardware UAT pending (Task 8); AC14 NFR9 monitoring (post-2.7 4380 B / ~85.5% of 5120 B / 740 B headroom — no amend needed); AC15 build invariants verified (NFR18 byte-identical SHA `e72d1028…1b9b1d62`; AR sweeps clean; `JP parser_clear` count = 10; stubs absent).

### File List

**New (test/cases/):**
- `test/cases/parser_5j-dispatches-with-count-5.asm`
- `test/cases/motions_5h-clamps.asm`
- `test/cases/motions_100j-clamps-at-eof.asm`
- `test/cases/motions_3w-three-words-forward.asm`
- `test/cases/motions_12G-line-target.asm`
- `test/cases/motions_100G-clamps.asm`
- `test/cases/motions_count-cleared-post-dispatch.asm`
- `test/cases/motions_esc-clears-count.asm`
- `test/cases/motions_leading-zero-still-motion-0.asm`
- `test/cases/motions_count-j-sticky-column.asm`
- `test/cases/parser_dispatch-key-routes-counted-motion.asm`

**Modified:**
- `src/motions.asm` — Option B sticky-column hoist in `motion_j` (lines ~305-329; col-compute block hoisted out of `.step:` into one-shot pre-loop block) and `motion_k` (lines ~408-432; hoist + at-line-0 check refactor from DE-based to HL-based + EX-elim in prev_line_start fetch). Header docstrings for both updated with STICKY COLUMN INVARIANT block. +5 B net.
- `_bmad-output/implementation-artifacts/deferred-work.md` — line 210 marked RESOLVED (count-respected end-to-end test); line 216 marked RESOLVED (sticky-column, Option B).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — 2-7 status flips (ready-for-dev → in-progress → review on dev-pass complete).
- `_bmad-output/implementation-artifacts/2-7-counted-motions.md` — this file (Tasks checkboxes, Completion Notes, File List, Change Log, Status).

### Change Log

| Date       | Change                                                                  | Notes |
|------------|-------------------------------------------------------------------------|-------|
| 2026-05-16 | Story 2.7 dev-pass: counted motions verified end-to-end                 | 11 new headless tests (4 canonical + 7 additional). |
| 2026-05-16 | AC10: Option B vi-faithful sticky-column implemented in motion_j / motion_k | `motions_col` captured once at entry, reused across counted steps. Pinned by `motions_count-j-sticky-column.asm` (cursor=13 target). +5 B net (NFR9: 4380 B / 85.5% / 740 B headroom). |
| 2026-05-16 | Header docstrings for motion_j and motion_k updated                     | STICKY COLUMN INVARIANT block added; per-step algorithm description updated to drop step 1 ("col = cursor - line_start") since col is now entry-once. |
| 2026-05-16 | Build SHA byte-identical across two consecutive `make clean && make all` (NFR18) | `e72d102815342b2a5333d4f31314cd1a032998d90515ceaf5bc597429a9b1d62`. |
| 2026-05-16 | Test count: 92 pass / 1 deliberate fail (was 81 / 1 post-2.6 review)    | 81 + 11 new = 92 total. |
| 2026-05-16 | deferred-work.md: line 210 + line 216 marked RESOLVED                   | Sub 7.1 + Sub 7.2 closed. |
| 2026-05-16 | deferred-work.md: line 264 (parser_motion-prefix-gg Subtest 3 patch) left as-is | Sub 7.3 explicitly out of scope per spec. |
| 2026-05-16 | Spec arithmetic bug noted in Sub 3.6                                    | Option B test target should be cursor=13 (col 4 of line 3 = 'd'), not the spec's cursor=12; test pins the correct value. |
| 2026-05-16 | Story status: ready-for-dev → in-progress → review                      | Status flip via sprint-status.yaml; AC13 hardware UAT pending. |
| 2026-05-16 | AC13 hardware UAT CONFIRMED by Ant on real MicroBeast                   | All 15 steps pass first iteration; no regressions; sticky-column Option B holds on hardware; mode-transition `5:Esc j` regression net holds; sustained-typing clean. Dev pass complete inclusive of hardware UAT; ready for code review pass (different LLM recommended). |
