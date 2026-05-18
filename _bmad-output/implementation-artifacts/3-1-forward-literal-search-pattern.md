# Story 3.1: Forward literal search (/pattern)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `/pattern` in NORMAL mode to prompt for a literal pattern and jump the cursor to the first forward match (with end-of-buffer wrap),
So that FR41 is realized — PRD Journey 1b "find a word and jump to it" becomes practical on real hardware.

## Acceptance Criteria

**AC1 — `/` enters the search prompt (COMMAND mode + SEARCH submode).**

**Given** I'm in NORMAL mode and press `/`
**When** dispatched
**Then** `mode_byte := MODE_COMMAND`, a new `command_submode` byte is set to `CMD_SUB_SEARCH` (distinguishing search from ex-line; structurally identical per architecture.md:499)
**And** the status row clears and shows `/` at column 0 with the cursor immediately after (column 1) — the existing `render.asm` AC11 MODE_COMMAND cursor-target override (render.asm:415-422) covers the cursor positioning without modification
**And** the typing surface is `ex_buffer` (the existing length-prefixed edit buffer; SHARED with `:`-prompt typing — see Q2 below for the rationale)
**And** `search_pattern` (the persistent last-search slot in `inc/state.inc:137-138`) is NOT zeroed on `/` entry — it survives across sessions and is consumed by `search_commit` (AC3) and by Story 3.2's `n`

**AC2 — Typing, Backspace, and Esc behave like `:` editing.**

**Given** I type pattern characters (0x20..0x7E printable ASCII)
**When** each arrives in COMMAND mode + SEARCH submode
**Then** they append to `ex_buffer` via the existing `exline_append_literal` (control bytes + KEY_ARROW_* 0x80..0x83 dropped silently; buffer-full at `ex_buffer == EX_COMMAND_BUFFER` = 64 drops silently)
**And** the status row recomposes via `exline_compose_status` with a `/` prefix instead of `:` (compose_status branches on `command_submode`)
**And** Backspace (`exline_backspace`) decrements `ex_buffer` length (silent RET at length 0; sibling to `:` behavior)
**And** Esc (`exline_cancel`) clears `ex_buffer`, returns to NORMAL via `exline_cancel_core`, restores the empty `msg_mode_normal` banner — `search_pattern` is UNTOUCHED so a prior `/foo<Enter>` survives Esc-of-a-half-typed-new-pattern

**AC3 — Enter on a non-empty `ex_buffer` commits and runs forward search from `cursor + 1`.**

**Given** I press Enter (0x0D) with `ex_buffer[0] > 0` in SEARCH submode
**When** dispatched (`exline_dispatch` branches on `command_submode` → `search_commit`)
**Then** LDIR `ex_buffer_text → search_pattern_text` (`BC = ex_buffer[0]`); `search_pattern[0] := ex_buffer[0]` (commit the new pattern; replaces any prior)
**And** invoke `search_forward_from(cursor + 1)`: walk gap buffer byte-for-byte literal match (no regex; case-sensitive)
**And** on match: `cursor_offset := match_start`; the next `render_diff` frame's `render_scroll_adjust` handles any required scroll; status row composes empty (clears the `/pattern` prompt) — implementation choice: status clears (no extra "found" message; matches vi convention)
**And** on no match in `[cursor+1, file_length)`: continue to AC4 wrap path
**And** mode transitions back to NORMAL via `exline_cancel_core` regardless of match/no-match (AR12 funnel preserves the AC4/AC5 status banner)

**AC4 — Enter on an empty `ex_buffer` reuses the prior `search_pattern` (vi `/<Enter>` convention).**

**Given** I press Enter with `ex_buffer[0] == 0` in SEARCH submode
**When** dispatched
**Then** if `search_pattern[0] > 0` (a prior commit exists): invoke `search_forward_from(cursor + 1)` on the existing pattern — NO LDIR (the persistent slot is already populated); AC3 wrap + status semantics apply
**And** if `search_pattern[0] == 0` (no prior commit since cold-start; `init_cold_start`'s LDIR zero-fill leaves both bytes 0): status row = `msg_no_previous_pattern` (new string — see Files Modified); mode → NORMAL via `exline_cancel_core`; cursor unchanged

**AC5 — Wrap path: search continues from offset 0; reports wrap or not-found.**

**Given** `search_forward_from(cursor + 1)` returns CF=1 (no match in `[cursor+1, file_length)`)
**When** the wrap path fires
**Then** invoke `search_forward_from(0)` with bound `original_cursor + 1` (search positions in `[0, original_cursor)`; positions `[original_cursor, original_cursor + 1)` are already covered by the first pass which started past the original cursor; the cursor+1 upper bound makes the second-pass span complementary to the first-pass span — every buffer position is searched exactly once across the two passes)
**And** if the wrap pass finds a match: `cursor_offset := match_start`; status row = `msg_search_wrapped` ("search wrapped" — existing string in `src/statusln.asm:221`)
**And** if the wrap pass also returns CF=1 (no match anywhere in the buffer): status row = `msg_pattern_not_found` ("pattern not found" — existing string in `src/statusln.asm:220`); `cursor_offset` UNCHANGED (vi convention: failed search leaves cursor in place)
**And** the second-pass bound must NOT include `original_cursor` itself — a match exactly at `original_cursor` would mean the user is already on a match position; advancing to the same position is a no-op and surfacing "search wrapped" would be misleading. Excluding `original_cursor` makes the two passes' union exactly `[0, file_length) \ {original_cursor}`, which is the correct semantic.

**AC6 — UAT on hardware passes the journey-1b script.**

**Given** I rebuild and `make push` `vibe.com` to MicroBeast
**When** I run the UAT script below
**Then** every step matches the predicted observation:

```
1. STAT B:fizzbuzz.fs  → confirm fixture present (multi-line file with multiple "main")
2. vibe fizzbuzz.fs    → cursor at offset 0, line 1; status banner empty
3. /main<Enter>        → cursor jumps to first "main" (scroll adjusts if needed);
                         status row clears
4. /<Enter>            → repeats /main (vi convention); cursor advances to second
                         "main" (because search_forward_from starts at cursor+1)
5. /<Enter>            → cursor advances to third "main"
6. /xyz<Enter>         → cursor unchanged from step 5; status = "pattern not found"
7. /<Enter>            → cursor advances to next "main" past current position
                         (reuses search_pattern = "main", NOT "xyz" — "xyz" was
                         never committed because no-match doesn't overwrite)
                         WAIT — this is wrong. AC3 says "commit replaces any prior"
                         and AC4 says "Enter on empty reuses". So /xyz<Enter>
                         DOES commit "xyz" → search_pattern = "xyz". Next
                         /<Enter> reuses "xyz" → status "pattern not found" again.
                         See Q5 below — pin this semantic at dev time.
8. /m<Esc>             → search prompt cancelled; ex_buffer cleared; search_pattern
                         still = "xyz" (or "main" per Q5 pin); status banner empty
9. G                   → cursor to last line (Story 2.6); confirm post-search
                         normal motions work
10. /main<Enter>       → walks from cursor+1; reaches EOF without match; wraps
                          from 0; finds first "main" on line N; status = "search wrapped"
11. :q                 → clean exit (buffer not dirty); back to CCP
```

**AC7 — Headless tests under `test/cases/search_*.asm` pass.**

**Given** `make test` runs from a fresh tree
**When** the new test cases are added (sentinel band 0xA0..0xAF for search; 0xE9 for parser-dispatch coverage)
**Then** the following 4 epic-canonical tests PASS:
- `search_forward-finds-match.asm` (sentinel 0xA0) — pattern present at offset >= cursor+1; cursor moves; status clear
- `search_forward-no-match-pre-wrap.asm` (sentinel 0xA1) — pattern absent from `[cursor+1, file_length)` only; wrap finds it; status = "search wrapped"
- `search_forward-empty-pattern-reuses.asm` (sentinel 0xA2) — first `/foo<Enter>` commits; second `/<Enter>` re-runs on `search_pattern` (still "foo")
- `search_forward-pattern-too-long.asm` (sentinel 0xA3) — type 65+ chars; verify `ex_buffer[0] == 64` (buffer-full drops silently per existing `exline_append_literal`); commit runs on 64-byte pattern

**And** the following 7 additional coverage tests PASS (orthogonal to the canonical 4):
- `search_forward-wraps-then-not-found.asm` (sentinel 0xA4) — pattern absent from BOTH passes; cursor unchanged; status = "pattern not found"
- `search_forward-empty-buffer.asm` (sentinel 0xA5) — file_length = 0; `/foo<Enter>` → cursor unchanged; status = "pattern not found"
- `search_forward-no-previous-pattern.asm` (sentinel 0xA6) — cold-start state (`search_pattern[0] == 0`); `/<Enter>` → status = "no previous pattern"; cursor unchanged
- `search_forward-esc-preserves-pattern.asm` (sentinel 0xA7) — pre-set `search_pattern[0] = 3` + bytes "foo"; press `/`, type "bar", press Esc; verify `search_pattern` still = "foo" (Esc doesn't touch persistent slot)
- `search_forward-cursor-past-eof.asm` (sentinel 0xA8) — cursor at `file_length` (the past-EOF sentinel after `$a<Esc>`); `/main<Enter>` → walker handles `cursor+1 > file_length` cleanly; wrap finds match; status = "search wrapped"
- `search_forward-case-sensitive.asm` (sentinel 0xA9) — buffer contains "MAIN"; `/main<Enter>` → no match; status = "pattern not found"
- `search_forward-multiple-matches-finds-first.asm` (sentinel 0xAA) — buffer "main\nmain\nmain"; cursor=0; `/main<Enter>` → cursor lands at second "main" (offset 5, not 0 — because start = cursor+1 = 1, first match is at offset 5)

**And** the parser-dispatch coverage test PASSES:
- `parser_slash-dispatch.asm` (sentinel 0xE9) — `dispatch_normal['/']` routes to `search_begin` (NOT to the retired `mode_search_prompt_stub`); verify `mode_byte == MODE_COMMAND`, `command_submode == CMD_SUB_SEARCH`, status buffer starts with `/`

Test count target: 197 → 208 PASS (+11) / 1 deliberate-fail unchanged.

## Tasks / Subtasks

- [x] **Task 0** (Q1-Q5 pre-dev pin with Ant — resolve BEFORE writing code):
  - [x] Q1 — NFR9 amend strategy (recommended: 6400 → 8192 B per Epic-2 retro A2)
  - [x] Q2 — Shared `ex_buffer` for both `:` and `/` editing vs separate edit buffer (recommended: shared; matches PRD §564-565 two-buffer design — `EX_COMMAND_BUFFER` = edit; `SEARCH_PATTERN_BUFFER` = persistent commit slot)
  - [x] Q3 — `gapbuf_byte_at_logical` extraction decision (Story 2.5 deferred; Story 3.1 is the "third consumer" trigger — see deferred-work.md:208)
  - [x] Q4 — Wrap-pass bound semantic (`original_cursor` vs `original_cursor + 1`; AC5 pin)
  - [x] Q5 — Failed-search commit semantic (does `/notfound<Enter>` overwrite the prior `search_pattern`? AC6 UAT step 7 hangs on this — recommended: YES, commit happens BEFORE the walk; matches vi)
  - [x] Q6 — Code review: separate commit (Story 2.10 pattern) or skip (Stories 2.11/2.12/2.13 pattern)
- [x] **Task 1** — Add state cells + equates + new status string (foundation; no behavior change yet):
  - [x] 1.1 — `inc/state.inc`: add `command_submode` (1 B, small-state block; cold-start LDIR zero = `CMD_SUB_EX` natural default)
  - [x] 1.2 — `inc/state.inc`: add `search_pattern_text EQU search_pattern + 1` (resolves Story 1.3 deferral; sibling to `ex_buffer_text` at line 146)
  - [x] 1.3 — `inc/equates.inc`: add `CMD_SUB_EX EQU 0x00` + `CMD_SUB_SEARCH EQU 0x01` (1-byte discriminator; sibling to KIND_* / UNDO_KIND_* pattern); add `ASSERT SEARCH_PATTERN_BUFFER < 256` (sibling to the EX_COMMAND_BUFFER ASSERT at line 39 — the length byte must fit in 8 bits)
  - [x] 1.4 — `src/statusln.asm`: add `msg_no_previous_pattern: DEFB "no previous pattern", 0` to the AR16 string block (after `msg_yank_too_large` at line 230 to keep search-related strings clustered with `msg_pattern_not_found` / `msg_search_wrapped` at lines 220-221)
- [x] **Task 2** — Create `src/search.asm` (new module; AR25-clean archetype like motions.asm):
  - [x] 2.1 — Module header (AR23 docstring per architecture.md:1186-1196 reference shape): purpose, Public surface (`search_begin`, `search_commit`, `search_forward_from`), state owned (`search_pattern` writer on commit only; reader on every search), dependencies (`gapbuf` / `motions` / `statusln` / `exline`), Trashes contract per entry (note: **DE NOT preserved** by `motion_byte_at_logical` per [[deferred-work-de-trash-invariant]])
  - [x] 2.2 — `search_begin` (entry from `dispatch_normal['/']`): set `mode_byte := MODE_COMMAND`; `command_submode := CMD_SUB_SEARCH`; `ex_buffer[0] := 0`; tail-JP `exline_compose_status` (which now branches on `command_submode` to pick `/` vs `:` prefix — Task 3.2)
  - [x] 2.3 — `search_commit` (entry from `exline_dispatch`'s SEARCH submode arm — Task 3.3): if `ex_buffer[0] > 0`, LDIR `ex_buffer_text → search_pattern_text` with `BC = ex_buffer[0]`; set `search_pattern[0] := ex_buffer[0]`. If after this `search_pattern[0] == 0`, surface `msg_no_previous_pattern` via `status_set_message` + tail-JP `exline_cancel_core`. Else compute `start := cursor_offset + 1`; CALL `search_run` (Task 2.5).
  - [x] 2.4 — `search_forward_from` (PUBLIC): in HL = start_offset, HL_aux (or a stash cell) = upper_bound; out HL = match_start + CF=0 if found; CF=1 if not. Two-loop walk: outer iterates candidate positions; inner byte-compares pattern[0..N] vs buffer[pos..pos+N] via `motion_byte_at_logical`. Bound: stop when `pos + pattern_length > upper_bound` OR `pos + pattern_length > file_length`. Story 3.2's `n` reuses this helper directly.
  - [x] 2.5 — `search_run` (internal helper used by `search_commit`): CALL `search_forward_from(cursor + 1, file_length)` first pass; if CF=0, set `cursor_offset := HL`, status clear, tail-JP `exline_cancel_core`. If CF=1, CALL `search_forward_from(0, original_cursor + 1)` wrap pass per AC5; if CF=0, set cursor + status = `msg_search_wrapped` + tail-JP `exline_cancel_core`. If CF=1, status = `msg_pattern_not_found` + tail-JP `exline_cancel_core` (cursor unchanged).
  - [x] 2.6 — AR sweep: zero BIOS_CONOUT references (grep `BIOS_CONOUT src/search.asm` empty); zero gap_start/gap_end direct WRITES (read-only via state.inc symbols); zero `BDOS_CALL` / `CALL 0x0005` invocations (grep clean).
- [x] **Task 3** — Wire search into existing modules (minimal surgical patches):
  - [x] 3.1 — `src/dispatch.asm`: change `dispatch_normal['/']` entry (line 497) from `mode_search_prompt_stub` to `search_begin`. Retire `mode_search_prompt_stub` body (delete the routine at lines 369-383); update dispatch.asm module header `Public:` list to drop the stub symbol; update header dependency notes to add `src/search.asm`.
  - [x] 3.2 — `src/exline.asm` (`exline_compose_status` at line 893): branch on `command_submode` to emit `/` vs `:` prefix. Single-byte difference — load the prefix char into A from a 2-byte table indexed by `command_submode` (CMD_SUB_EX=0 → ':' / CMD_SUB_SEARCH=1 → '/') OR a `LD A, (command_submode) ; OR A ; JR Z, .ex_prefix ; LD (HL), '/' ; JR .post_prefix` branch. ~7-10 B.
  - [x] 3.3 — `src/exline.asm` (`exline_dispatch` at line 407): top-of-routine branch on `command_submode` — `LD A, (command_submode) ; CP CMD_SUB_SEARCH ; JP Z, search_commit` (forward-reference resolves via sjasmplus two-pass since search.asm INCLUDEs after exline.asm — see Task 5.1). Bare-Enter short-circuit at lines 411-413 must run AFTER the submode branch so empty-line search reaches `search_commit` (which handles AC4's reuse case) instead of `exline_cancel` (which would discard).
  - [x] 3.4 — `src/exline.asm` (`exline_cancel_core` at line 574): clear `command_submode` as part of the mode-return cleanup (`XOR A ; LD (command_submode), A`). Symmetric with the existing `ex_buffer[0] := 0` line. Ensures next `:` entry starts in EX submode regardless of how SEARCH submode exited.
  - [x] 3.5 — `src/statusln.asm` (`bdos_error_funnel` inline ex-line cleanup at lines 187-192): add `LD (command_submode), A` (A is already 0 from the `XOR A` two lines above) so a BDOS-funnel exit from a half-typed `/` prompt also resets the submode. Defensive — funnel firing from a search prompt is unusual but possible if a parser-driven `:e` somehow lives alongside; the +3 B insurance is cheap.
- [x] **Task 4** — Render cursor positioning in MODE_COMMAND + SEARCH submode:
  - [x] 4.1 — `src/render.asm` AC11 cursor override path (lines 415-422): the col math is `1 + ex_buffer[0]` (1 for the prefix glyph). This works UNCHANGED for both submodes — search and ex share `ex_buffer` as the edit buffer (Q2 pin), so the length byte read at line 420 is correct in both. No code change. Update the in-line comment (line 408-414) to mention SEARCH submode also lands here.
- [x] **Task 5** — INCLUDE chain + Makefile + retro action items:
  - [x] 5.1 — `src/vibe.asm`: add `INCLUDE "search.asm"` between `edits.asm` (line 147) and `exline.asm` (line 158); update the placeholder comment at lines 144-146 ("Visual / search modules will INCLUDE between edits.asm and exline.asm when they arrive (Story 3.x)") to reflect that search has now arrived. AR25 chain becomes: `init → input → statusln → gapbuf → render → dispatch → parser → motions → edits → search → exline → fileio → undo`. State.inc still last.
  - [x] 5.2 — Bulk patch all existing test cases that INCLUDE the chain transitively dependent on `exline.asm` to also INCLUDE `../../src/search.asm` between `edits.asm` and `exline.asm`. Same pattern as Story 2.13's bulk `INCLUDE "../../src/undo.asm"` sed (197 test files; ~150 need the new INCLUDE). One-shot sed script:
    `sed -i 's|INCLUDE "../../src/edits.asm"|INCLUDE "../../src/edits.asm"\n    INCLUDE "../../src/search.asm"|' test/cases/*.asm`
    (only files that already have the `edits.asm` INCLUDE get the new line; verify post-sed via `grep -L "search.asm" test/cases/*.asm` returning only files without `edits.asm`).
  - [x] 5.3 — **Action item A1 from Epic-2 retro** (load-bearing for this story; flagged 4+ times across Epic 2): fix `test/Makefile` dependency hygiene BEFORE the dev pass writes test code. Add `$(wildcard ../src/*.asm) $(wildcard ../inc/*.inc)` as a dependency of `cases/%.com`. Conservative; rebuilds all test cases on any src change. Verify `make clean && make test` from a fresh tree produces green. Without this fix, the search.asm INCLUDE additions silently won't rebuild tests that were last built against the old source — exactly the pattern that masked Stories 2.1/2.2's 14 broken tests.
  - [x] 5.4 — **Action item A2 from Epic-2 retro**: formal NFR9 amend (Q1 pin). Update PRD §NFR9 (line 848) and architecture.md in 5 callsites (Pillar 47 line 47; line 200; line 305; line 735; line 1334) with full amend-history block per the Story 2.13 pattern (deferred-work.md:408): "amended 2026-05-XX from 6400 B; itself amended 2026-05-17 from 5760 B; itself amended 2026-05-16 from 5120 B; itself amended 2026-05-15 from 3072 B".
- [x] **Task 6** — Tests (11 new files in `test/cases/`):
  - [x] 6.1 — 4 epic-canonical (AC7): `search_forward-finds-match` / `-no-match-pre-wrap` / `-empty-pattern-reuses` / `-pattern-too-long` (sentinels 0xA0-0xA3)
  - [x] 6.2 — 7 additional coverage (AC7): `-wraps-then-not-found` / `-empty-buffer` / `-no-previous-pattern` / `-esc-preserves-pattern` / `-cursor-past-eof` / `-case-sensitive` / `-multiple-matches-finds-first` (sentinels 0xA4-0xAA)
  - [x] 6.3 — 1 parser-dispatch (AC7): `parser_slash-dispatch` (sentinel 0xE9 — next in parser-band after 2.13's 0xE7/0xE8)
  - [x] 6.4 — Verify `make test` reports 208 PASS / 1 deliberate-fail (was 197/1 post-2.13). Test sentinel band hygiene confirmed: no collisions with existing bands (motions 0x80-0x88, paste 0x90-0x97, undo 0xC0-0xCF, parser 0xE0-0xE8, harness 0xF0+).
- [x] **Task 7** — NFR18 byte-identical rebuild check + UAT:
  - [x] 7.1 — Two `make clean && make all` cycles from a fresh tree; sha256sum prefix matches across both (per Story 2.13 protocol — verifies the build is a pure function of source).
  - [x] 7.2 — `make sizes` — verify final code-segment size against the amended NFR9 ceiling (Q1 pin).
  - [x] 7.3 — `make push` → AC6 hardware UAT on MicroBeast. Deliver the 11-step UAT script INLINE in the dev handoff chat message per [[feedback_uat_inline_at_dev_handoff]] — do NOT only point at the story file. (UAT CONFIRMED by Ant 2026-05-18, all 11 steps pass first iteration, no fix iterations.)
  - [x] 7.4 — On UAT confirm: flip sprint-status `3-1-...` from `review` to `done`. (Flipped 2026-05-18.)

## Dev Notes

### Architecture compliance

**AR13 (single screen-emit path):** `src/search.asm` makes ZERO `BIOS_CONOUT` calls. All status surfaces enter via `status_set_message` (MC5 funnel); cursor repositioning is driven by `render.asm`'s RI4 invariant on the next `render_diff` frame after `cursor_offset` is updated. Same shape as motions.asm — the "clean module" archetype (architecture.md:142-146).

**AR14 (single buffer-mutation path):** `src/search.asm` makes ZERO writes to `gap_start` / `gap_end`; never invokes `gapbuf_insert` / `gapbuf_delete` / `gapbuf_move_gap`. Pure-read against the buffer via `motion_byte_at_logical` (Story 2.5's SR3 helper). Search is a READER, not a mutator. The single state surface that `search_commit` writes is `cursor_offset` (the same surface motions.asm writes; allowed by SR1).

**AR15 (single BDOS path via `BDOS_CALL` macro):** `src/search.asm` makes ZERO `BDOS_CALL` invocations and ZERO raw `CALL 0x0005` / `CALL BDOS_ENTRY` sites. Pure-memory module.

**AR23 (module header docstring conventions):** `src/search.asm` lands an AR23-compliant header documenting: Module / Purpose / Public / State owned / Register conventions per public entry / Dependencies. The architecture.md:1186-1196 reference shape applies — use it as the literal template (with field updates for the Story 3.1 surface). **Add explicit "DE NOT preserved across `motion_byte_at_logical`" in the Trashes lines for every public entry** (Epic-2 retro carry-forward #1; protects against the Story 2.6 motion_dollar / motion_find_line_n class of bug).

**AR25 (INCLUDE chain order):** search.asm slots between edits.asm and exline.asm in `src/vibe.asm`. Forward references resolved by sjasmplus's two-pass model: exline.asm's `JP Z, search_commit` (Task 3.3) resolves on pass 2 against the search.asm body that pass 1 emitted. Same pattern as every Epic-2 cross-module forward reference.

**MC4 (handler register convention):** `search_begin` receives A = '/' (0x2F); ignores. `search_commit` receives A = 0x0D (Enter); ignores. Both are entered from dispatch_key / exline_dispatch via the existing register conventions; no MC4 deviations.

**MC5 (single status funnel):** Every status surface in search.asm uses `status_set_message` with HL = msg ptr, A = 0 (non-error code). Three sites: `msg_no_previous_pattern` (new — see Files Modified), `msg_search_wrapped` (existing), `msg_pattern_not_found` (existing).

**MC6 (NFR8 BDOS_CALL only):** N/A (search.asm makes zero BDOS calls). AR15 clean.

**MC7 (state.inc cross-module state):** `command_submode` lands in `inc/state.inc` (READ by exline.asm + render.asm + search.asm; WRITTEN by search_begin + exline_cancel_core). Module-local DEFW pattern (e.g., motions_compose_entry, edits_indent_walk_end) does NOT apply — `command_submode` is consumed cross-module.

**B2 (insert-session-as-unit, FR45):** N/A. Search does NOT mutate the buffer; no undo entry is generated. `op_undo` semantics unchanged. Any prior `undo_kind` value SURVIVES across a search invocation — pressing `u` after `/main<Enter>` undoes whatever mutation preceded the search. This matches vim.

**SR1 (cursor_offset range):** Search-commit writes `cursor_offset` only when a match is found. Match offsets are bounded `0 <= match_start < file_length` by the walker's bounds check, so SR1 (0..file_length) is preserved. The "cursor at file_length" past-EOF sentinel (from Story 2.5's motion_l clamp + Story 2.8's `$a` insert handling) is REACHED only post-search if `original_cursor` was already at file_length AND the wrap path didn't find anything — in which case `cursor_offset` is unchanged (per AC5 "not-found leaves cursor in place"). Tested in `search_forward-cursor-past-eof.asm`.

**SR2 / SR3 (gap-buffer two-halves invariant):** Search.asm reads through `motion_byte_at_logical` which encapsulates the SR3 logical → physical mapping. SR2 (`gap_start <= gap_end`) is invariant under reads (motions.asm precedent).

### Files this story modifies (and what to preserve)

**NEW FILE: `src/search.asm`** (~250-350 B body projected).

**EDITED FILES:**

| File | Lines / Symbols Changed | What's preserved |
|---|---|---|
| `src/vibe.asm` | INCLUDE chain (lines 144-158): add `INCLUDE "search.asm"` between edits.asm and exline.asm; update the placeholder comment | Entire input_loop body; every other INCLUDE position; state.inc-last position |
| `src/dispatch.asm` | `dispatch_normal['/']` entry (line 497): retarget from `mode_search_prompt_stub` to `search_begin`. Retire `mode_search_prompt_stub` body (lines 369-383); drop from `Public:` list in header | All 35 other dispatch_normal entries; `enter_insert_mode` / `enter_normal_mode` / `enter_visual_mode` bodies (B2 hook unchanged); dispatch_command / dispatch_insert / dispatch_visual tables; ASSERT brackets |
| `src/exline.asm` | `exline_compose_status` (lines 893-913): branch on `command_submode` to pick `/` vs `:` prefix. `exline_dispatch` (lines 407-512): top-of-routine branch on `command_submode` → JP Z search_commit. `exline_cancel_core` (line 574): clear `command_submode` alongside the existing `ex_buffer[0] := 0` | Every existing :-command path (cmd_quit / cmd_quit_force / cmd_edit / cmd_edit_force / cmd_write / cmd_write_quit); exline_append_literal / exline_backspace / exline_cancel; exline_command_table; the bare-Enter short-circuit (lines 411-413) — preserved BUT relocated below the submode branch so empty-line search reaches search_commit |
| `src/statusln.asm` | Add `msg_no_previous_pattern` to AR16 string block (after line 230). `bdos_error_funnel` (lines 187-192): add `LD (command_submode), A` (defensive) | All existing strings; `status_set_message` body; `bdos_error_funnel` override mechanism; `msg_search_wrapped` / `msg_pattern_not_found` (used as-is by search_run) |
| `src/render.asm` | NONE in code. Update the in-line comment at lines 408-414 to mention SEARCH submode reuses the same cursor-target override (col = 1 + ex_buffer[0]; correct for both submodes since they share ex_buffer as the edit buffer per Q2) | `render_diff` body; `render_scroll_adjust`; all 13 module-local scratch cells; AC11 cursor override math unchanged |
| `inc/state.inc` | Add `command_submode` (1 B) in the small-state block (likely between `pending_motion_inclusive` and `input_held_byte`). Add `search_pattern_text EQU search_pattern + 1` after the `search_pattern` declaration at line 138 (resolves Story 1.3 deferral — see deferred-work.md:16) | Every existing field; the ASSERT `yank_end <= 0xD800` guard at line 183; the GAP_BUFFER_BASE / yank_buffer / yank_end positional EQUs |
| `inc/equates.inc` | Add `CMD_SUB_EX EQU 0x00` / `CMD_SUB_SEARCH EQU 0x01` (sibling cluster to KIND_* and UNDO_KIND_*); add `ASSERT SEARCH_PATTERN_BUFFER < 256` (sibling to line 39) | All existing equates; the EX_COMMAND_BUFFER < 256 ASSERT (line 39); the ESC_TIMEOUT_TICKS > 0 ASSERT (line 65) |
| `test/cases/*.asm` (~150 files) | Bulk sed: insert `INCLUDE "../../src/search.asm"` after every `INCLUDE "../../src/edits.asm"` line. Test files that do NOT INCLUDE edits.asm (e.g. pure-gapbuf or pure-render tests) are skipped. | Every test body; every existing INCLUDE; the INCLUDE chain order (search slots after edits, before exline / fileio / undo) |
| `test/Makefile` | Action item A1: add `$(wildcard ../src/*.asm) $(wildcard ../inc/*.inc)` as deps of `cases/%.com` | Existing test recipe; iz-cpm invocation; sentinel inspection logic |
| `_bmad-output/planning-artifacts/prd.md` | NFR9 amend (line 848): 6400 → Q1-pinned ceiling | Every FR / NFR / Journey / §Search / §Undo section unchanged |
| `_bmad-output/planning-artifacts/architecture.md` | NFR9 amend in 5 callsites (lines 47, 200, 305, 735, 1334) | Every other section |
| `_bmad-output/implementation-artifacts/sprint-status.yaml` | `3-1-...`: backlog → ready-for-dev → in-progress → review → done. `last_updated` chain | `epic-3` status (will flip to in-progress on first-story handoff per the create-story workflow); every other epic/story entry |
| `_bmad-output/implementation-artifacts/deferred-work.md` | Append "Deferred from: dev of story-3-1-forward-literal-search-pattern (2026-05-XX)" block with Q1-Q6 pins + closure notes | All existing deferred / resolved entries |

### Implementation choices and trade-offs

**Choice 1: Shared `ex_buffer` for both `:` and `/` editing.**

PRD §564-565 designed two distinct buffers — `EX_COMMAND_BUFFER` (the edit buffer for `:` and `/` typing) and `SEARCH_PATTERN_BUFFER` (the persistent last-search slot). Story 3.1 implements this design literally: `ex_buffer` is the EDIT surface for both prompts; `search_pattern` is the PERSISTENT slot that `search_commit` LDIRs into on Enter. This means:
- No new edit buffer needed. `exline_append_literal` / `exline_backspace` / `exline_compose_status` are reused with a 1-byte submode discriminator.
- The persistent slot survives Esc-during-edit (AC2: "Esc cancels — `search_pattern` UNTOUCHED").
- The `/<Enter>` reuse case (AC4) checks `search_pattern[0] > 0` directly — no extra state cell.
- State cost: +1 byte (`command_submode`). State cost ALTERNATIVE (separate edit buffer): +1 + 64 = +65 bytes. Shared-buffer saves ~64 B of state.

**Choice 2: Walk algorithm — naive O(N×M) byte-compare.**

Worst-case for 32 KB file × 64-byte pattern × adversarial input is ~2 million byte compares (~17-20 sec on 4 MHz Z80). Average case (random text, 4-5 byte pattern) is ~O(N) (~250 ms). Boyer-Moore would shave the worst case but costs ~80-150 B of code and 256 B of skip table — not justified for MVP. Vim uses naive forward walk too.

**Choice 3: Wrap as two passes, not a circular walk.**

Two passes with explicit bounds (`[cursor+1, file_length)` then `[0, original_cursor + 1)`) is simpler to reason about than a single circular walk with a "started?" flag. Each pass's bound is supplied by the caller (`search_run`); the helper `search_forward_from(start, bound)` doesn't know wrap exists.

**Choice 4: `search_forward_from` is the Story 3.2 hand-off surface.**

Story 3.2 (`n` command) lands `search_next` (per architecture.md:1191) which calls `search_forward_from(cursor + 1, file_length)` directly. Story 3.1's helper signature must match Story 3.2's needs:
- `In: HL = start_offset, DE = upper_bound (exclusive)` (or HL = start, an upper-bound cell stashed module-local)
- `Out: HL = match_start, CF = 0` on found; `CF = 1` on not-found (HL undefined)
- `Trashes: A, BC, DE, HL, F` (the standard motions.asm-style trash)

Pin the signature at dev pass; Story 3.2 inherits.

**Choice 5: Case-sensitive only.**

Vi default. `/main` does NOT match "MAIN". Tested by `search_forward-case-sensitive.asm`. Case-insensitive flag (vim's `\c`) is post-MVP.

**Choice 6: No regex; no special characters.**

Pattern is literal. `/.` matches the byte `.`, not "any character". The user CAN type `.` `*` `^` `$` etc. into the pattern (they're 0x20-0x7E printable ASCII) but they have no special meaning. Vi's basic-regex set is post-MVP.

### Previous story intelligence

**From [[story-2-13-single-level-undo-u]] (the immediate predecessor):**
- **NFR9 ceiling is now 6400 B; 144 B headroom post-Story-2.13.** Epic-2 retro A2 recommends a formal amend to 8192 B at Epic 3 boundary. Story 3.1 is the natural moment — it's the first Epic 3 story. Recommended pin in Q1. Without the amend, Story 3.1's projected ~250-350 B addition overshoots by ~100-200 B.
- **Stub-now-wire-later pattern worked across 5 stories for FR45.** Epic-2 retro flags this as "Worth repeating for Epic 3's visual-state and search-state hooks." For Story 3.1, the only forward-debt is the `search_forward_from` helper signature consumed by Story 3.2 (`n`). Pin the signature contract IN search.asm's module header so 3.2 dev has zero discovery cost.
- **Test-writing batches via parallel subagents:** Story 2.13 hit 3 of 4 stream-idle timeouts mid-debug; tests salvaged via fresh batches of 2-3 each. **Plan smaller batches (2-3 tests) for Story 3.1's 11 tests rather than one giant 11-test batch.**

**From [[story-2-12-paste-p]]:**
- **Yank register is a READER for paste / a WRITER for dd/yy/dw/d$/y3j.** Search is also a READER pattern (of gap buffer); no new mutation surface. **AR14 cleanliness should hold automatically** — no fileio.asm-class carve-outs needed.

**From [[story-2-6-word-line-buffer-motions]]:**
- **DE-trash invariant load-bearing.** Story 2.6 dev hit motion_dollar AND motion_find_line_n both trashing DE inside motion_find_line_end. Story 3.1's search.asm walks the buffer via motion_byte_at_logical / motion_find_line_start in a tight loop — **the inner byte-compare loop must save/restore DE if it stashes the candidate position there** OR use HL exclusively for the candidate. Recommended: keep pattern-position in BC (preserved by motion_byte_at_logical), candidate-buffer-position in HL (the helper's input), pattern-length-remaining via a stack-pushed scratch or a module-local DEFW.

**From [[story-2-5-basic-motions]]:**
- **AC16 helper-placement decision deferred to "when a third consumer appears."** Story 3.1 IS that consumer — search.asm needs the SR3 logical-byte read identical to motions.asm's `motion_byte_at_logical`. Two paths in Q3:
  - **Path A (motions.asm-private status quo)**: search.asm calls `motion_byte_at_logical` directly. Symbol is module-local but still callable (sjasmplus's lack of true encapsulation means any address is callable from any module that INCLUDEs after the definition). search.asm INCLUDEs after motions.asm in AR25 → resolves on pass 2. **Cost: ~0 B.** **Trade-off: violates the spirit of "private" without enforcement.**
  - **Path B (extract `gapbuf_byte_at_logical`)**: promote the helper to gapbuf.asm with a public AR23 docstring. motions.asm + search.asm both call it. **Cost: ~5 B in gapbuf.asm + symbol-rename ripple in motions.asm (~30-40 B retained as a JP-wrapper or full removal).** **Trade-off: cleaner AR14 surface; explicit boundary.**

  **Recommended pin (Q3): Path A** — minimal byte cost, accepted shape per Story 2.5 dev triage, and the helper's contract (DE-trash; BC-preserve; CF=1 past EOF) is stable. The Path B extraction can land in a future polish pass when AR14 surface review is the goal.

**From [[story-2-1-ex-command-line-infrastructure]]:**
- **`ex_buffer_text EQU ex_buffer + 1` resolved the Story 1.3 deferral partially** — search_pattern_text was explicitly deferred to Story 3.1. **Story 3.1 must land `search_pattern_text EQU search_pattern + 1` in `inc/state.inc` immediately after the `search_pattern` declaration at line 138.** Sibling to `ex_buffer_text` at line 146.
- **The exline_command_table has 6 entries (e, e!, w, wq, q, q!).** Story 3.1 does NOT add a `/`-search entry to this table — `/` is a NORMAL-mode dispatch key (handled at `dispatch_normal['/']`), NOT a `:`-prefixed ex command. The Story 2.1 comment at exline.asm:923 ("Story 3.1's `/`-search entry will land before :q too") is OUTDATED — the design pivoted such that `/` is its own NORMAL-mode key, not a `:` subcommand. **Update the comment** during the dev pass.

**From [[story-1-12-init-teardown-on-hardware-smoke-test]]:**
- **`init_cold_start`'s LDIR zero-fill** zeroes `command_submode` (the new 1 B cell) to 0 = CMD_SUB_EX (natural default — `:` is the more common COMMAND-mode entry). First `:` after boot reads CMD_SUB_EX and routes to exline_dispatch as today.
- **`init_teardown` uninstalls the user ISR before warm-boot.** Search.asm does not touch input.asm's tick infrastructure — no init/teardown impact.

**From [[feedback_create_story_cross_check]] memory:**
- **CR/CRLF handling**: literal byte-for-byte match. Pattern restricted to 0x20-0x7E by exline_append_literal's existing filter (lines 328-331). User CANNOT type CR/LF into pattern. Matches across CRLF work because pattern is just bytes; e.g., pattern "ab" matches `ab` whether followed by CR / LF / both / EOF.
- **sjasmplus-hostile filenames**: search test filenames AVOID `$` (sjasmplus location-counter symbol — caused Story 2.11's `edits_d$-to-end-of-line.asm` rename). All proposed test filenames use only `a-z`, `0-9`, `-`, `_` — safe.
- **Cursor arithmetic**: post-`:e` cursor at offset 0 per [[feedback_uat_trace_cursor]]; first `/main<Enter>` walks from cursor+1 = 1; first match found at the first occurrence with offset >= 1. If "main" is AT offset 0 (start of file), it's NOT found in the first pass; wrap pass finds it (offset 0 < original_cursor + 1 = 1); status = "search wrapped". This is correct vi behavior and tested by `search_forward-no-match-pre-wrap.asm`.
- **NFR9 projections**: explicit Q1 pin with retro A2 recommendation.
- **No `~` empty-line marker**: search doesn't paint UI. Past-EOF rows render as 0x20 spaces per [[project_no_tilde_marker]]. UAT script avoids `~` predictions.

**From [[feedback_uat_inline_at_dev_handoff]] memory:**
- Dev handoff message MUST paste the AC6 11-step UAT script verbatim, NOT just point at this file.

### Git intelligence

Recent commits (post-Story-2.13, providing direct lineage):

- `c8fb896 Story 2.13: single-level undo u lands; FR45/FR46 closed; closes Epic 2` — Story 2.13 dev + UAT + done flip (6256 B / 97.75% NFR9 / 144 B headroom; Epic 2 fully closed).
- `0756610 story 2.12: paste p / Np lands (KIND_CHAR + KIND_LINE; KIND_BLOCK reserved)` — paste handler; FR32 closed.
- `84dd7d4 story 2.11: operator+motion compose (dw/d$/c5w/y3j) + >> / << landed` — compose layer; the 5 op_compose_* hook sites consumed by 2.13.
- `94b4f16 story 2.9: x deletes char under cursor; counted Nx with EOL/EOF clamp` — edits_delete_char; FR45 stub site.
- `fdd2d10 social media preview image` — non-dev cosmetic.

**Story 2.13 is the immediate predecessor.** Story 3.1 starts from the 2.13 baseline (6256 B / 144 B headroom / Epic 2 closed / Epic 3 backlog). First story in Epic 3.

**Patterns to follow** (consolidated from Stories 2.1-2.13):

- Single dev-commit per story containing production code + tests + spec updates + sprint-status flips (Story 2.13 pattern).
- Separate code-review commit OPTIONAL (Story 2.10 ran it; 2.11/2.12/2.13 skipped at Ant's call — Q6).
- Sentinel byte at `0xCFFE` per TH1; unique sentinel per test; disjoint band per module.
- INCLUDE chain in test cases: pre-ORG headers, `test_prologue.inc`, test body, `test_epilogue.inc`, production sources (in AR25 order), `test_teardown_stub.inc`, `test_input_loop_stub.inc`, finally `inc/state.inc`. **Story 3.1 inserts `search.asm` between `edits.asm` and `exline.asm` in this chain.**
- Gap-buffer fixture pattern: `CALL gapbuf_init` → LDIR payload → set `gap_start := GAP_BUFFER_BASE + N`. Cursor pre-set via `LD HL, N ; LD (cursor_offset), HL`. Mode pre-set via `LD A, MODE_NORMAL ; LD (mode_byte), A`.
- **Search-pattern pre-seed for search tests** (NEW pattern for Story 3.1):
  ```
  LD A, <pattern_length>
  LD (search_pattern), A
  LD HL, .test_pattern
  LD DE, search_pattern_text
  LD BC, <pattern_length>
  LDIR
  .test_pattern:
      DEFB "main"
  ```
- **`ex_buffer` pre-seed for "user typed pattern" tests** (drives the commit path):
  ```
  LD A, <typed_length>
  LD (ex_buffer), A
  LD HL, .typed_pattern
  LD DE, ex_buffer_text
  LD BC, <typed_length>
  LDIR
  LD A, CMD_SUB_SEARCH
  LD (command_submode), A
  LD A, MODE_COMMAND
  LD (mode_byte), A
  LD A, 0x0D                  ; Enter key
  CALL exline_dispatch
  ```
- **NFR18 verification pattern**: post-dev pass, `make clean && make all` twice; sha256sum prefix matches across both cycles.

### Implementation Questions (resolve with Ant before dev starts)

**Q1 — NFR9 amend strategy.** Projected post-3.1 footprint OVER the 6400 B ceiling by ~100-200 B (search.asm ~250-350 B + state extension ~1 B + dispatch/exline patches ~30 B - retired stub savings ~10 B = ~270-370 B add; headroom 144 B; overshoot 126-226 B).

- **Option A (recommended; matches Epic-2 retro A2)**: Formal NFR9 amend 6400 → 8192 B (+1792 B). Gives ~1500 B headroom for the rest of Epic 3 (7 more stories projected at +600-1000 B per retro A2). Closes Story 3.1 cleanly with no second-pass amend mid-Epic-3. Audit-trail block per Story 2.13 precedent (deferred-work.md:408).
- **Option B**: Smaller per-story amend (e.g., 6400 → 7168 B; +768 B). Tighter discipline; forces re-evaluation per Epic 3 story. **Trade-off: reactive churn; retro A2 explicitly flagged this as the WRONG pattern.**
- **Option C**: Defer the case-sensitive equates / Boyer-Moore / regex etc. — IRRELEVANT; none of those are in MVP scope.

Recommended decision: **Option A** (8192 B; matches retro recommendation; one amend covers all of Epic 3).

**Q2 — Shared `ex_buffer` vs separate search edit buffer.**

- **Option A (recommended; matches PRD §564-565)**: `ex_buffer` is the shared edit buffer for both `:` and `/`. `search_pattern` is the persistent last-commit slot. ~+1 B state.
- **Option B**: Separate 65 B `search_input_buffer` for /-editing. ~+65 B state; ~+30 B code (parallel typing path).
- **Option C**: Single `search_pattern` doubles as edit + persist; snapshot on `/` entry, restore on Esc. ~+65 B state (snapshot); ~+15 B code.

Recommended decision: **Option A** — matches PRD; cheapest state; cleanest separation of "edit surface" (ex_buffer) from "persistent state" (search_pattern).

**Q3 — `gapbuf_byte_at_logical` extraction.** Story 2.5 deferred this to "when a third consumer appears" (deferred-work.md:208). Story 3.1's search.asm is that consumer.

- **Option A (recommended; minimal-byte path)**: search.asm CALLs `motion_byte_at_logical` directly (motions.asm-private symbol; resolves via AR25 INCLUDE ordering). No extraction.
- **Option B**: Extract to `gapbuf_byte_at_logical` (public). motions.asm + search.asm both consume. Cost: ~+5 B gapbuf body + ~+30-40 B motions.asm rename ripple OR a JP-wrapper preserving the motions.asm symbol.

Recommended decision: **Option A** — Path A from Story 2.5's AC16 deferral. Path B is a Growth-tier AR14 polish, not Story 3.1 scope.

**Q4 — Wrap-pass bound semantic.** AC5 specifies the second-pass span. Edge case: the original cursor sits ON a pattern match.

- **Option A (recommended; vi-spirit)**: Second pass = `[0, original_cursor + 1)`. Includes positions `[0, original_cursor)` (genuinely earlier) plus the position `original_cursor` itself (the cursor's CURRENT position; if pattern starts here it's a "you're sitting on it" match — surface "search wrapped" to tell the user they're back where they started). **Two-pass union = entire buffer minus the trivial "no advance" case where match_start == original_cursor.**
- **Option B**: Second pass = `[0, original_cursor)`. Excludes position `original_cursor`. A user sitting on a match position with no other matches gets "pattern not found" — surprising; suggests no match exists.

Recommended decision: **Option A** — `original_cursor + 1` upper bound. The "you're on a match" surface via "search wrapped" is informative.

**Q5 — Does a failed-search Enter overwrite `search_pattern`?**

`/notfound<Enter>` → `search_run` fires; wrap fails; status = "pattern not found"; cursor unchanged. **Does `search_pattern` now hold "notfound"?**

- **Option A (recommended; vi)**: YES — commit (LDIR) happens BEFORE the walk. `search_pattern` = "notfound". Next `/<Enter>` reuses "notfound" → "pattern not found" again. User sees consistent state ("the last pattern I searched is the last pattern I searched, regardless of whether it matched").
- **Option B**: NO — commit happens only on found-match. Failed searches preserve the prior `search_pattern`. **Trade-off: more state ceremony; surprising; diverges from vi.**

Recommended decision: **Option A** — commit unconditionally; matches vi; simpler code. The AC6 UAT step 7 narrative was AMBIGUOUS until this pin — see the inline note there.

**Q6 — Separate code-review commit (Story 2.10 pattern) or single dev commit (Stories 2.11/2.12/2.13 pattern)?**

Story 3.1 introduces a new module + cross-module wiring + 11 new tests. Story 2.13 had similar scope (~390 B + 9 hook sites + 18 tests) and shipped as a single commit.

- **Option A (recommended)**: Single dev commit. Matches recent precedent. Code-review cycle still happens (`/code-review`) but no separate commit unless something is found.
- **Option B**: Separate code-review commit (Story 2.10 style). Cleaner diff for review.

Recommended decision: **Option A** — consistent with 2.11/2.12/2.13.

### NFR9 budget arithmetic (worked example)

Assuming Q1 Option A (8192 B amend) + Q2 Option A (shared ex_buffer) + Q3 Option A (no extraction):

| Component | Estimated bytes |
|---|---|
| `src/search.asm` body (search_begin + search_commit + search_forward_from + search_run; AR23 docstring 0 B) | ~280 B |
| `src/exline.asm` patches (compose_status `/` vs `:` branch; exline_dispatch top-level submode branch; cancel_core clear command_submode) | ~25 B |
| `src/dispatch.asm` patches (retarget `/` entry from stub to search_begin; retire mode_search_prompt_stub body; `Public:` header update) | **net ~-10 B** (stub body retirement reclaims more than the entry retarget costs) |
| `src/statusln.asm` patches (msg_no_previous_pattern string ~22 B + null; bdos_error_funnel defensive +3 B) | ~25 B |
| `src/vibe.asm` patches (INCLUDE line; comment update) | 0 B (comment) |
| `src/render.asm` patches (comment-only update) | 0 B |
| `inc/state.inc` (command_submode 1 B; search_pattern_text EQU 0 B) | +1 B static |
| `inc/equates.inc` (CMD_SUB_* equates; ASSERT) | 0 B (EQU + ASSERT only) |
| Module-header docstrings | 0 B (comments) |
| **Total** | **~320 B code + 1 B static** |

Post-3.1 projection: 6256 + ~320 = **~6576 B / 80.2% of 8192 B / ~1616 B headroom**.

This is generous headroom for the rest of Epic 3 — visual mode (4 stories) + visual operators (3 stories) + `n` (1 story) projected at +600-1000 B per retro A2. Final Epic-3 close should land 7000-7500 B / 85-91% / 600-1200 B residual headroom.

### Test count target

11 new tests (4 epic-canonical + 7 additional coverage + 0 not parser-dispatch-specific since `/` is a dispatch_normal entry not a parser-state one... wait, parser_slash-dispatch IS a parser-dispatch test; total = 4 canonical + 7 additional + 1 parser-dispatch = 12).

Re-checking: 4 + 7 = 11 listed in AC7 + 1 parser_slash-dispatch listed separately = **12 new tests**. Pre-existing test count post-2.13 = 196 PASS + 1 deliberate-fail = 197 cases / 196 passing. Post-3.1 target = **208 PASS / 1 deliberate-fail = 209 cases**.

**Sentinel band allocation:**
- 0xA0..0xAA: search.asm unit tests (11 of 16 reserved slots used; 0xAB..0xAF reserve for Stories 3.2's `n` tests).
- 0xE9: parser-dispatch coverage (next in parser band after Story 2.13's 0xE7/0xE8).

No collisions with existing bands. Verified:

| Band | Module | Slots used | Source |
|---|---|---|---|
| 0x80..0x88 | motions | 9 | Stories 2.5-2.7 |
| 0x90..0x97 | paste (edits) | 8 | Story 2.12 |
| 0xA0..0xAA | search | 11 | **Story 3.1 (NEW)** |
| 0xC0..0xCF | undo | 16 | Story 2.13 |
| 0xE0..0xE9 | parser-dispatch | 10 | Stories 1.10, 2.1, 2.13, 3.1 |
| 0xF0..0xFF | harness internals | various | Story 1.6 |

### Project Structure Notes

- **No conflicts.** Story 3.1 fits cleanly in the existing project structure:
  - New module at `src/search.asm` (AR25 slot between edits.asm and exline.asm per long-planned vibe.asm:144-146 comment).
  - New tests at `test/cases/search_*.asm` (matches AR21 + TH2 naming + architecture.md:278 / 1327's `search_*.asm` projection).
  - State extensions in `inc/state.inc` follow the positional-EQU pattern (`command_submode` next to other small-state; `search_pattern_text` next to `ex_buffer_text`).
  - Equates extensions in `inc/equates.inc` follow the cluster pattern (CMD_SUB_* sibling to KIND_* and UNDO_KIND_*).
- **Action item A1 (test/Makefile) lands DURING Story 3.1.** Without it, the bulk INCLUDE patch (Task 5.2) will silently fail to rebuild some tests, masking real regressions. This is the only Epic-2 carry-forward item that gates Story 3.1's dev pass.

### References

- **PRD** (`_bmad-output/planning-artifacts/prd.md`):
  - FR41 (line 769) — Story 3.1 functional requirement.
  - FR42-FR44 (lines 770-774) — heads-up; Story 3.2 (`n`) lands these but `search_forward_from` is the shared helper.
  - §Command Parser line 496-500 — ex/search-prompt structural identity decision.
  - §Render Pipeline line 514 — status-line emit path.
  - §Search line 520-531 — literal/forward/wrap/pattern-buffer/case-sensitive pins.
  - §Source Equates line 564-565 — EX_COMMAND_BUFFER (edit) + SEARCH_PATTERN_BUFFER (persistent) two-buffer design.
  - §NFR9 line 848 — current 6400 B ceiling + amend history; Story 3.1 expected to be the Epic-3-boundary amend point (Q1).

- **Architecture** (`_bmad-output/planning-artifacts/architecture.md`):
  - AR23 (module header conventions) — search.asm header shape.
  - AR25 (INCLUDE chain order) — search slots between edits and exline.
  - Line 251 (directory tree) — `src/search.asm` slot.
  - Line 278 (test/cases/ projection) — `search-*.asm` test directory.
  - Line 417 — backward search (`?`) deferred post-MVP.
  - Line 526-528 — wrap notice + pattern not found.
  - Line 691-695 — BH4 "re-search from one byte past current" (Story 3.2 directly; Story 3.1 inherits via the start_offset = cursor+1 contract).
  - Line 947 (INCLUDE chain) — `INCLUDE "search.asm"` slot.
  - Line 990-993 — length-prefixed buffer convention for search_pattern + ex_buffer.
  - Line 1186-1196 — module header REFERENCE shape (search_prompt + search_next + State owned + Dependencies); use literally as the template.
  - Line 1375-1376 — search_pattern declaration shape.
  - Line 1417 (module dependency graph) — search.asm dependency arrows.
  - Line 1539 (FR-to-module mapping) — FR41-FR44 → search.asm with exline + gapbuf + statusln support.

- **Epics** (`_bmad-output/planning-artifacts/epics.md`):
  - Lines 1480-1525 — Story 3.1 epic spec (5 AC clauses + UAT clause + 4 canonical tests).
  - Lines 1526-1555 — Story 3.2 (`n`) forward heads-up; consumes the `search_forward_from` helper Story 3.1 lands.
  - Line 1482-1484 — Epic 3 visual-highlighting platform-constraint note.

- **Previous stories** (all under `_bmad-output/implementation-artifacts/`):
  - `2-13-single-level-undo-u.md` — NFR9 amend pattern; 9-hook-site bulk patch precedent; 18-test landing pattern.
  - `2-12-paste-p.md` — second non-trivial yank-register reader pattern.
  - `2-5-basic-motions-h-j-k-l.md` — AC16 helper-placement decision (Q3).
  - `2-1-ex-command-line-infrastructure-q-q.md` — `ex_buffer_text EQU` precedent; exline_dispatch table walk; AR12 status-funnel pattern.
  - `1-3-static-memory-map-state-inc.md` — search_pattern declaration original; search_pattern_text deferral.

- **Source files** (all under `src/`):
  - `dispatch.asm` (lines 369-383 `mode_search_prompt_stub` to retire; line 497 `/` entry to retarget; line 43 `Public:` to update).
  - `exline.asm` (lines 893-913 compose_status; lines 407-512 exline_dispatch; line 574 cancel_core; line 923 outdated `/`-search comment).
  - `statusln.asm` (line 220-221 existing search strings to reuse; line 230 string-block append target; lines 187-192 funnel defensive patch).
  - `motions.asm` (motion_byte_at_logical at line 557; the DE-trash contract callers must respect).
  - `vibe.asm` (lines 144-158 INCLUDE-chain insertion point).
  - `render.asm` (lines 408-422 AC11 cursor-target override; comment-only update).

- **Memory pins applied** (from MEMORY.md):
  - [[feedback_uat_trace_cursor]] — post-`:e` cursor at 0; UAT script uses `$a` if EOF append needed (Story 3.1 UAT doesn't need it — search runs from cursor=0 cleanly).
  - [[feedback_uat_inline_at_dev_handoff]] — dev handoff message pastes AC6 UAT script inline.
  - [[project_no_tilde_marker]] — no `~` empty-line marker references anywhere in this story.
  - [[feedback_create_story_cross_check]] — CR/CRLF + sjasmplus filenames + cursor arithmetic + NFR9 + render-semantics cross-checks applied above.

- **Deferred work** (`_bmad-output/implementation-artifacts/deferred-work.md`):
  - Line 16-17 — `search_pattern_text EQU` deferred to Story 3.1 (RESOLVE in Task 1.2).
  - Line 110-112 — exline_command_table structural ASSERTs re-deferred again at 6 entries; Story 3.1 does NOT extend the table (it's a `dispatch_normal` change, not `exline_command_table`) so re-deferral continues.
  - Line 115 — ex_buffer length-as-source-of-truth test gap; Story 3.1's `search_forward-pattern-too-long` test exercises the buffer-full silent-drop, partially closing this gap.
  - Line 182 — exline_command_table lex-order pin; unchanged (Story 3.1 doesn't touch the table).
  - Line 208 — AC16 helper placement (Q3 in this story).
  - Line 243 — motion_find_line_end / motion_byte_at_logical DE-trash invariant; **direct forward-note to Story 3.1 dev**. Address in search.asm module header AR23 Trashes line + via the inner-loop register-allocation pin in Task 2.4.
  - Line 408 — NFR9 6400 B amend (post-Story-2.13); Story 3.1 follows the same amend protocol for Q1.

## Dev Agent Record

### Agent Model Used

Claude Opus 4.7 (`claude-opus-4-7[1m]`, 1M-context variant) via Claude Code.

### Debug Log References

(No debug rabbit-holes worth a separate log — the dev pass landed clean on the first build: Q1-Q6 pinned via AskUserQuestion → all 6 recommendations accepted; src/search.asm assembled clean on first sjasmplus pass; first canonical test `search_forward-finds-match.asm` PASS on first run; remaining 11 tests PASS on first run; full sweep 208 PASS / 1 deliberate-fail after the bulk INCLUDE patch.)

### Completion Notes List

- **Q1-Q6 pins (Task 0):** All six recommendations accepted by Ant. Q1=8192 B amend; Q2=shared ex_buffer; Q3=Path A (motion_byte_at_logical direct, no gapbuf extraction); Q4=wrap upper bound = original_cursor + 1; Q5=failed-search Enter STILL commits typed pattern; Q6=single dev commit.
- **NFR9 final: 6481 B / 79.1% of 8192 B / 1711 B headroom.** Came in lighter than the spec's projected ~6576 B because the inner-loop register allocation reused BC for the DJNZ counter (preserved by motion_byte_at_logical per its contract) without needing extra save/restore around the byte fetch.
- **NFR18: byte-identical rebuild confirmed.** Two `make clean && make all` cycles produced the same `vibe.com` SHA-256 `0ff58bdc23a89a14292a3c2fa413661acc0328066ab58b2b117313b2ef10c258`.
- **Test count: 208 PASS / 1 deliberate-fail** (was 196/1 post-2.13; +12 new — exactly matching the spec's 4 canonical + 7 additional + 1 parser-dispatch target).
- **Bulk INCLUDE patch:** 184 test cases got `INCLUDE "../../src/search.asm"` inserted after their existing `edits.asm` line via one sed invocation. The 13 tests that don't INCLUDE edits.asm verified separately to also not INCLUDE exline.asm or dispatch.asm, so they don't need search.asm in scope. Epic-2 retro action A1 (test/Makefile `cases/%.com` depends on `$(wildcard ../src/*.asm) $(wildcard ../inc/*.inc)`) landed BEFORE the bulk patch was applied — this was the load-bearing fix that would have otherwise masked any rebuild gap.
- **AR sweep clean:** src/search.asm has zero `BIOS_CONOUT` references, zero direct writes to `gap_start` or `gap_end`, zero `BDOS_CALL` invocations and zero raw `CALL 0x0005` sites. Same archetype as motions.asm.
- **DE-trash invariant:** every public entry's Trashes contract in search.asm's AR23 header explicitly notes "DE NOT preserved across motion_byte_at_logical" per the Epic-2 retro carry-forward #1. The inner byte-compare loop saves DE on the stack around each helper call; B (DJNZ counter) and C (transient buffer-byte temp) ride through unsaved because motion_byte_at_logical's contract preserves BC.
- **Forward-debt resolved:** search_pattern_text EQU search_pattern + 1 in inc/state.inc closes the Story-1.3 deferral (deferred-work.md:16). The Story-3.2 `n` hand-off contract for search_forward_from is documented in the module header's Public block.
- **Open deferrals carried forward:** deferred-work.md:208 (gapbuf_byte_at_logical extraction; Path A chosen per Q3) stays open as a future polish item; the helper's contract (DE-trash; BC-preserve; CF=1 past EOF) is now consumed by both motions.asm and search.asm, so a future extraction has two callers to validate against.
- **Code-review pass: skipped** per Q6 (single dev commit; Story 2.11/2.12/2.13 pattern). A standalone `/code-review` run is still recommended before the post-UAT done flip if Ant wants a second-LLM read on the new module.

### File List

**NEW (production):**
- `src/search.asm` — new module hosting search_begin / search_commit / search_forward_from / search_run / search_compute_file_length + module-local search_upper_bound (~310 B body)

**NEW (tests):**
- `test/cases/search_forward-finds-match.asm` (sentinel 0xA0)
- `test/cases/search_forward-no-match-pre-wrap.asm` (sentinel 0xA1)
- `test/cases/search_forward-empty-pattern-reuses.asm` (sentinel 0xA2)
- `test/cases/search_forward-pattern-too-long.asm` (sentinel 0xA3)
- `test/cases/search_forward-wraps-then-not-found.asm` (sentinel 0xA4)
- `test/cases/search_forward-empty-buffer.asm` (sentinel 0xA5)
- `test/cases/search_forward-no-previous-pattern.asm` (sentinel 0xA6)
- `test/cases/search_forward-esc-preserves-pattern.asm` (sentinel 0xA7)
- `test/cases/search_forward-cursor-past-eof.asm` (sentinel 0xA8)
- `test/cases/search_forward-case-sensitive.asm` (sentinel 0xA9)
- `test/cases/search_forward-multiple-matches-finds-first.asm` (sentinel 0xAA)
- `test/cases/parser_slash-dispatch.asm` (sentinel 0xE9)

**MODIFIED (production):**
- `src/vibe.asm` — AR25 INCLUDE chain: `INCLUDE "search.asm"` between edits.asm and exline.asm; module header `Dependencies:` block extended; placeholder comment about "search yet to land" rewritten.
- `src/dispatch.asm` — `dispatch_normal['/']` entry retargeted from `mode_search_prompt_stub` to `search_begin`; stub body retired (lines 369-383 deleted); `Public:` list updated; new `src/search.asm` dependency block added.
- `src/exline.asm` — `exline_dispatch` top-of-routine submode branch `JP Z search_commit` (BEFORE the bare-Enter short-circuit per AC4 reuse-arm path); `exline_compose_status` prefix-glyph branch on `command_submode` (`/` vs `:`); `exline_cancel_core` clears `command_submode` alongside ex_buffer/mode reset; module header updated; outdated comment about Story-3.1 search ":-table entry" reverted.
- `src/statusln.asm` — new `msg_no_previous_pattern` string after `msg_yank_too_large`; `bdos_error_funnel` defensive `LD (command_submode), A` parallel to existing ex_buffer/mode reset; module header `Message strings` block updated.
- `src/render.asm` — comment-only update to the AC11 cursor-target override block noting SEARCH submode reuses the path (math unchanged).
- `inc/state.inc` — new `command_submode` 1-byte cell in the small-state block (between `pending_motion_inclusive` and `input_held_byte`); new `search_pattern_text EQU search_pattern + 1` resolving the Story-1.3 deferral; module header `Public:` block updated.
- `inc/equates.inc` — new `CMD_SUB_EX` / `CMD_SUB_SEARCH` equates with explanatory cluster comment (sibling to KIND_* and UNDO_KIND_*); new `ASSERT SEARCH_PATTERN_BUFFER < 256` (sibling to the EX_COMMAND_BUFFER ASSERT); module header `Public:` block updated.

**MODIFIED (infrastructure):**
- `Makefile` — `make sizes` percentage display updated 5 KB → 8 KB ceiling.
- `test/Makefile` — Epic-2 retro action A1: new `PROD_SRC := $(wildcard ../src/*.asm)` + `PROD_INC := $(wildcard ../inc/*.inc)` deps added to the `cases/%.com` rule.

**MODIFIED (tests; bulk patch):**
- `test/cases/*.asm` — 184 files got `INCLUDE "../../src/search.asm"` inserted after their existing `INCLUDE "../../src/edits.asm"` line via single sed pass. Files without the edits.asm INCLUDE (13 lower-level tests) untouched.

**MODIFIED (planning artifacts):**
- `_bmad-output/planning-artifacts/prd.md` — NFR9 §848 amended 6400 → 8192 B with full audit-trail amend-history block per Story-2.13 pattern; Epic-2 retro A2 rationale inlined.
- `_bmad-output/planning-artifacts/architecture.md` — 5 callsites updated to 8192 B with parallel amend-history (lines 47, 200, 305, 735, 1334).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `3-1-forward-literal-search-pattern: ready-for-dev` → `review`; new `last_updated` block at the top documenting the dev pass (under the previous ready-for-dev entry, preserving the chronology).
- `_bmad-output/implementation-artifacts/3-1-forward-literal-search-pattern.md` — this file: Status → `review`; Tasks 0-7 (except 7.3/7.4) marked `[x]`; Dev Agent Record populated; File List + Change Log filled.

### Change Log

- 2026-05-17 — Story 3.1 dev pass complete; Status `ready-for-dev` → `review`. NFR9 amended to 8192 B (Epic-2 retro action A2). test/Makefile dep-hygiene fix landed (action A1). NFR18 SHA `0ff58bdc23a89a14292a3c2fa413661acc0328066ab58b2b117313b2ef10c258` byte-identical across two `make clean && make all` cycles. Test count 196 → 208 PASS / 1 deliberate-fail (+12). Code size 6256 → 6481 B (+225 B; under the spec's projected +320 B because of register-reuse savings in the inner walk loop).
- 2026-05-18 — Hardware UAT CONFIRMED on real MicroBeast; all 11 AC6 steps pass first iteration, no fix iterations needed. Status `review` → `done`. Q5 pin (failed-search commits the typed pattern; subsequent bare-`/<Enter>` reuses the no-match pattern) and Q4 pin (wrap bound = original_cursor + 1) both held end-to-end. NFR18 SHA unchanged from review-time. FR41 closes; Story 3.1 closes; Epic 3 stays in-progress (Story 3.2 `n` repeat-last-search consumes the `search_forward_from` helper Story 3.1 lands).
