# Story 3.2: Repeat last search (n) with wrap

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `n` in NORMAL mode to repeat the most recent forward search — advancing to the next match, surfacing a wrap notice on end-of-buffer rollover, and surfacing "pattern not found" when no match exists,
So that FR42 / FR43 / FR44 / BH4 are realized — PRD Journey 1b's "`/dup` then `n` to find the next caller" iterative debug loop becomes practical on real MicroBeast hardware.

## Acceptance Criteria

**AC1 — `n` is wired as a NORMAL-mode dispatch entry pointing to `search_next`.**

**Given** `src/dispatch.asm:dispatch_normal` (ascending-sorted (key, handler_addr) table at lines 476-583)
**When** I inspect the table
**Then** a new entry exists for `'n'` (0x6E) between the existing `'l'` (0x6C, motion_l) at line 559-561 and `'o'` (0x6F, edits_open_below) at line 562-564 — preserving the strict-ascending sort that the binary search relies on; the `ASSERT 'n' > 'l'` and `ASSERT 'o' > 'n'` bracketing siblings the existing assertions; `DISPATCH_NORMAL_COUNT` (computed `($ - .entries) / 3` at line 583) grows from 34 to 35 automatically
**And** the entry's 16-bit handler address is `search_next` (forward-referenced via sjasmplus's two-pass model since search.asm INCLUDEs after dispatch.asm in vibe.asm's AR25 chain — same forward-reference shape as Story 3.1's `search_begin` entry at line 486)
**And** the dispatch.asm module header `Dependencies:` block (lines 135-141) is extended to mention Story 3.2's `search_next` entry alongside the existing Story-3.1 search_begin note

**AC2 — `search_next` lives in `src/search.asm` as a new public entry.**

**Given** `src/search.asm` (the module Story 3.1 created)
**When** I inspect it
**Then** a new public entry `search_next` is added between `search_commit` and the existing `search_run` internal helper (so the public surface block at the top of the file reads `search_begin` → `search_commit` → `search_next` → `search_forward_from`, with `search_run` and `search_compute_file_length` remaining internal)
**And** the module-header `Public:` block (lines 32-56 in 3.1's landed file) is extended with a `search_next` entry documenting: entry from `dispatch_normal['n']`; reads `search_pattern` (no commit; never writes); reuses `search_run` for the two-pass wrap orchestration; surfaces `msg_no_previous_pattern` when `search_pattern[0] == 0`; tail-JPs `parser_clear` so any pending NORMAL-mode count / operator / motion-prefix from before the `n` keystroke is dropped (sibling to every other dispatch_normal handler's AC13 tail-JP per Story 2.5)
**And** the module-header `State owned` block notes that `search_next` is a pure reader of `search_pattern` (no LDIR; no commit; the AC4-style failed-search-commit semantics of Story 3.1's `/<Enter>` do NOT apply — `n` never overwrites the pattern slot)
**And** the existing search.asm AR sweep pins (AR13 / AR14 / AR15 clean — zero BIOS_CONOUT, zero gap_start / gap_end writes, zero BDOS_CALL sites) extend to `search_next` without exception

**AC3 — `n` with a non-empty `search_pattern` runs `search_forward_from(cursor + 1, file_length)`; on first-pass match the cursor moves and the status row CLEARS.**

**Given** `search_pattern[0] > 0` (from a prior `/pattern<Enter>` commit; or — Q5-pin from Story 3.1 — even a prior failed `/notfound<Enter>` since the commit happens unconditionally before the walk)
**When** I press `n` in NORMAL mode and `dispatch_normal['n']` routes to `search_next`
**Then** `search_next` reads `search_pattern[0]`; finds it non-zero; falls through (or `CALL`s) into `search_run` — exactly the same orchestration Story 3.1's `search_commit` non-empty-buffer arm uses
**And** `search_run` computes `start_1 = cursor_offset + 1` and `upper_bound = file_length`, calls `search_forward_from`, and on CF=0 sets `cursor_offset := HL` and surfaces `msg_mode_normal` (the empty banner — `status_set_message` pads with spaces; vi convention: no "found" message)
**And** the next `render_diff` frame's `render_scroll_adjust` (driven by the cursor_offset change) brings the match into view if a scroll is required — same mechanism that 3.1's first-pass match relies on (per architecture.md RI4)

**AC4 — On first-pass miss, the wrap path fires; on wrap-pass match, cursor moves and status = `msg_search_wrapped`.**

**Given** `search_forward_from(cursor + 1, file_length)` returns CF=1 (no match between cursor+1 and EOF)
**When** the wrap arm fires inside `search_run`
**Then** `search_run` invokes `search_forward_from(0, original_cursor + 1)` — the Q4-pin from Story 3.1 (wrap upper bound = `original_cursor + 1`; the two-pass union is `[0, file_length) \ {trivial-no-advance}` — a pattern that starts at `original_cursor` is reachable and surfaces "search wrapped", informing the user they're back where they started)
**And** on CF=0 from the wrap pass: `cursor_offset := HL` (the wrap-match start) and status = `msg_search_wrapped` ("search wrapped" — existing string at `src/statusln.asm:225` — Story 2.10's AR16 string-block; identical reuse to 3.1's wrap-pass arm in `search_run`)
**And** on CF=1 from the wrap pass (both passes miss): `cursor_offset` UNCHANGED (vi convention; mirrors 3.1 AC5's "failed search leaves cursor in place"); status = `msg_pattern_not_found` ("pattern not found" — existing string at `src/statusln.asm:224`)

**AC5 — `n` with an empty `search_pattern` (no prior commit) surfaces `msg_no_previous_pattern`; cursor unchanged.**

**Given** `search_pattern[0] == 0` (cold-start state — `init_cold_start`'s LDIR zero-fill leaves the length byte at 0; reachable in two cases: (a) the user opens VIBE and immediately presses `n` without any prior `/pattern`; (b) the user issues `:e other.fs` — `:e` does NOT clear `search_pattern` per Story 3.1's persistent-slot design, but if the previous session was also cold-start then the slot is still 0)
**When** I press `n` in NORMAL mode and `dispatch_normal['n']` routes to `search_next`
**Then** `search_next` reads `search_pattern[0]`; finds it zero; skips `search_run` entirely (no walk; no cursor write; no scratch state touched)
**And** status row = `msg_no_previous_pattern` ("no previous pattern" — existing string at `src/statusln.asm:235`, added by Story 3.1's Task 1.4 for the `/<Enter>` AC4-reuse-with-no-prior arm — reused verbatim here)
**And** `cursor_offset` UNCHANGED
**And** tail-JP `parser_clear` so any pending count / operator / motion-prefix is dropped (the AC13 contract from Story 2.5; same shape every NORMAL-mode handler follows)

**AC6 — `n` does NOT consume a NORMAL-mode count prefix; any pending count is silently dropped.**

**Given** a user types `5n` (digit `5` accumulates into `count_accumulator` via `parser_handle_digit`; then `n` arrives and dispatches to `search_next`)
**When** `search_next` runs
**Then** the search runs exactly ONCE — no `5×n` repeat loop — because the AC narrative scoped FR42 to single-step `n` only (vim's `Nn` = repeat-N-times is post-MVP; epic line 1535 says "I press `n`", no count clause)
**And** on every exit path of `search_next` (no-prior, first-pass match, wrap match, both-passes miss), the routine tail-JPs `parser_clear` so the stale count `5` is zeroed before control returns to `input_loop`
**And** the implementation is `LD A, (search_pattern) ; OR A` → branch; the routine NEVER reads `count_accumulator` (counted-`n` would require a CALL-loop wrapping `search_forward_from`; that's a future polish story under FR42-extended)

**AC7 — UAT on hardware passes the journey-1b iterative-search script.**

**Given** I rebuild `vibe.com` with the Story-3.2 patch applied and `make push` it to MicroBeast
**When** I run the UAT script below from CCP
**Then** every step matches the predicted observation:

```
 1. STAT B:fizzbuzz.fs       → confirm fixture present (multi-line file
                               with multiple "main" occurrences across
                               the buffer)
 2. vibe fizzbuzz.fs         → cursor at offset 0, line 1, column 0;
                               status banner empty (msg_mode_normal pad);
                               search_pattern still empty (cold-start)
 3. n                        → status "no previous pattern" (AC5);
                               cursor unchanged at offset 0; remains in
                               NORMAL mode
 4. /main<Enter>             → cursor jumps to first "main" (3.1 AC3,
                               first-pass match); status clears;
                               search_pattern committed = "main"
 5. n                        → cursor advances to second "main"
                               (3.2 AC3, first-pass match from cursor+1);
                               status clears
 6. n                        → cursor advances to third "main"; status
                               clears
 7. n                        → cursor advances to fourth "main" (if the
                               fixture has 4); status clears.
                               (If the fixture has only 3 "main"s, this
                               step is the wrap step — adjust observation
                               to match step 8.)
 8. n                        → after the last "main" is reached, the
                               next n finds no match between cursor+1
                               and EOF; wrap pass finds the first "main"
                               from offset 0; cursor lands on the first
                               "main" again; status = "search wrapped"
                               (3.2 AC4)
 9. /xyz<Enter>              → status = "pattern not found" (3.1 AC5 +
                               Q5-pin: "xyz" still commits and overwrites
                               the persistent slot; search_pattern = "xyz");
                               cursor UNCHANGED from step 8 position
10. n                        → status = "pattern not found" (3.2 AC4
                               both-passes-miss); cursor UNCHANGED; same
                               "xyz" pattern still in the persistent slot
11. /main<Enter>             → search_pattern overwritten back to "main";
                               cursor jumps to next "main" past current
                               position (or wraps with notice if past
                               last "main"); behaviour identical to step 4
                               or step 8 depending on cursor position
12. 5n                       → AC6 — count "5" accumulates; n fires
                               exactly ONCE (single-step semantics);
                               cursor advances to next "main" only;
                               parser_clear at exit drops the pending
                               count (verified post-step by pressing j —
                               cursor moves down ONE line, not five)
13. G                        → cursor to first character of last line
                               (motion_G from Story 2.6); confirm normal
                               motions work after search; status clears
14. n                        → first pass searches [cursor+1,
                               file_length); if no "main" past current
                               position in the last line, wrap pass
                               finds the first "main" from BOF; cursor
                               lands there; status = "search wrapped".
                               (If the fixture has a "main" after the
                               cursor in the last line, this is a
                               first-pass match instead; status clears
                               — either outcome confirms n works
                               post-G; pick the fixture so the wrap
                               case fires for the more interesting
                               observation.)
15. :q                       → clean exit (buffer not dirty);
                               control returns to CCP
```

**AC8 — Headless tests under `test/cases/search_n-*.asm` pass.**

**Given** `make test` runs from a fresh tree (with the Story-3.1 test/Makefile dep-hygiene fix already in place per A1)
**When** the new test cases are added (sentinel band 0xAB..0xAF reserved by Story 3.1 for Story 3.2's `n` tests; 0xEA for parser-dispatch coverage)
**Then** the following 4 epic-canonical tests PASS:
- `search_n-advances.asm` (sentinel 0xAB) — `search_pattern` pre-seeded to "main"; buffer "main\nfoo\nmain\n"; cursor=0 (first "main" start); `CALL search_next` → cursor=8 (start of second "main"); status[0] = ' ' (cleared per AC3)
- `search_n-wraps-with-notice.asm` (sentinel 0xAC) — buffer "main\nfoo\nbar"; cursor=4 (past first "main"); search_pattern = "main"; `CALL search_next` → first pass [5, 11) misses; wrap pass [0, 5) finds match at 0; cursor=0; status = msg_search_wrapped ("search wrapped")
- `search_n-not-found.asm` (sentinel 0xAD) — buffer "foo bar baz"; cursor=0; search_pattern = "xyz"; `CALL search_next` → both passes miss; cursor UNCHANGED at 0; status = msg_pattern_not_found ("pattern not found")
- `search_n-no-prior-pattern.asm` (sentinel 0xAE) — buffer "main foo"; cursor=0; search_pattern[0] = 0 (cold-start zero-fill); `CALL search_next` → no walk; cursor UNCHANGED at 0; status = msg_no_previous_pattern ("no previous pattern")

**And** the following 1 additional coverage test PASSES (fills the last 3.1-reserved slot in the 0xAB..0xAF band):
- `search_n-cursor-on-match.asm` (sentinel 0xAF) — BH4 semantics: buffer "main\nmain"; cursor=0 (sitting EXACTLY on the first "main"); search_pattern = "main"; `CALL search_next` → first pass [1, 9) finds match at offset 5 (the second "main"); cursor=5; status[0] = ' ' (cleared). Validates BH4: `n` walks from `cursor + 1`, NOT `cursor`, so a user sitting on a match advances PAST it on `n`.

**And** the parser-dispatch coverage test PASSES:
- `parser_n-dispatch.asm` (sentinel 0xEA) — pre-seed search_pattern = "x" (length 1) + buffer "abcdex" so the walk doesn't take the no-prior arm; pre-seed cursor_offset = 0 and mode_byte = MODE_NORMAL; drive 'n' through the dispatcher exactly as `parser_slash-dispatch.asm` (sentinel 0xE9) drives '/': `LD A, 'n' ; LD HL, dispatch_normal ; LD B, DISPATCH_NORMAL_COUNT ; CALL dispatch_key`. Verify dispatch lands in `search_next` (post-call effect: cursor_offset = 5, the offset of 'x' in "abcdex"; status_buffer[0] = ' ' — cleared per AC3's first-pass match). Confirms `dispatch_normal['n']` is wired (NOT falling through to `unbound_normal`'s msg_unbound_key path).

Test count target: 208 → 214 PASS (+6) / 1 deliberate-fail unchanged.

## Tasks / Subtasks

- [x] **Task 0** (pre-dev pin with Ant — resolve BEFORE writing code):
  - [x] Q1 — `search_run` refactor strategy: RET-based shared helper (recommended) vs duplicated inline walk in `search_next` — **Option A pinned (recommended).** Refactor landed; converted to tail-JP `status_set_message` (an extra win — saves 3 B vs straight RET conversion).
  - [x] Q2 — Counted-`n` (`5n` semantics) — defer to a future polish story (recommended) vs land in 3.2 — **Option A pinned (recommended).** `search_next` ignores `count_accumulator`; `parser_clear` tail-JP at every exit drops stale counts.
  - [x] Q3 — Code review: separate commit (Story 2.10 pattern) or single commit (Stories 2.11/2.12/2.13/3.1 pattern; recommended) — **Option A pinned (recommended).** Single dev commit per the 3.1 precedent.
- [x] **Task 1** — Refactor `src/search.asm:search_run` to RET-based (foundation for `search_next` reuse):
  - [x] 1.1 — `.first_pass_match`'s `JP exline_cancel_core` → tail-JP `status_set_message` (the `CALL status_set_message ; JP exline_cancel_core` collapsed cleanly into a single tail-JP since `status_set_message` already RETs; saves 1 B per site vs straight RET conversion).
  - [x] 1.2 — `.wrap_match` exit converted to tail-JP `status_set_message`.
  - [x] 1.3 — Both-passes-miss arm converted to tail-JP `status_set_message`.
  - [x] 1.4 — `search_run` contract block rewritten: `Out:` documents that mode / ex_buffer / command_submode are caller's responsibility; `Calls:` no longer lists `exline_cancel_core`.
  - [x] 1.5 — `search_commit`'s commit arm: `JR search_run` (fall-through) replaced with `JR .run`. New `.run` label hosts the shared `CALL search_run ; JP exline_cancel_core` exit.
  - [x] 1.6 — `search_commit`'s `.check_prior` reuse arm: `JR NZ, search_run` → `JR NZ, .run` (lands on the same shared exit).
  - [x] 1.7 — All 12 Story-3.1 search + parser tests STILL PASS after the refactor (208 pass / 1 deliberate-fail unchanged from baseline). Regression net held.
- [x] **Task 2** — Add `src/search.asm:search_next` public entry:
  - [x] 2.1 — Positioned between `search_commit`'s `.run` shared-exit label and `search_run`. AR23-compliant section banner comment landed.
  - [x] 2.2 — Body matches the projected skeleton:
    ```
    search_next:
        LD      A, (search_pattern)
        OR      A
        JR      Z, .no_prior
        CALL    search_run
        JP      parser_clear            ; tail-JP — drop stale count
    .no_prior:
        LD      HL, msg_no_previous_pattern
        XOR     A
        CALL    status_set_message
        JP      parser_clear            ; tail-JP — same
    ```
  - [x] 2.3 — Full AR23 docstring landed above `search_next:` per the contract.
  - [x] 2.4 — Module-header `Public:` block extended with `search_next` entry; pure-reader-of-search_pattern note included.
  - [x] 2.5 — Module-header `Dependencies:` block extended with `src/parser.asm` (the `parser_clear` tail-JP target) and rewritten `src/exline.asm` block to reflect the refactor.
  - [x] 2.6 — AR sweep clean: `grep -n BIOS_CONOUT src/search.asm` returns only doc-comments (zero call sites); zero `gap_start` / `gap_end` writes; zero `BDOS_CALL` invocations and zero raw `CALL 0x0005` sites.
- [x] **Task 3** — Wire `n` into `src/dispatch.asm`:
  - [x] 3.1 — `src/dispatch.asm:dispatch_normal` (lines 476-583): inserted new (key, handler_addr) entry for `'n'` (0x6E) between `'l'` and `'o'`. Three new lines:
    ```
        ASSERT  'n' > 'l'
        DEFB    'n'                         ; 'n'     — repeat last search (FR42, Story 3.2)
        DEFW    search_next
        ASSERT  'o' > 'n'                   ; (relocated from the existing 'o' > 'l' assert above)
    ```
    The existing `ASSERT 'o' > 'l'` line (currently between the `l` and `o` entries) must be REPLACED by the new `ASSERT 'n' > 'l'` (positioned before the new 'n' entry) and `ASSERT 'o' > 'n'` (positioned before the existing 'o' entry). Both assertions are assembly-time and reduce to zero runtime bytes.
  - [x] 3.2 — `DISPATCH_NORMAL_COUNT` recomputes to **0x24 = 36** (story spec said 34 → 35 — story spec drift; actual pre-3.2 count was 35 = 0x23, post-3.2 = 36 = 0x24; pre-existing `'u'` from Story 2.13 was already in the table when 3.1 landed). Auto-computed via `($ - .entries) / 3`; no explicit edit needed.
  - [x] 3.3 — Module-header `src/search.asm` Dependencies block in `src/dispatch.asm` extended with Story 3.2's `search_next` note + the search_run RET-refactor cross-reference.
- [x] **Task 4** — Tests (6 new files in `test/cases/`):
  - [x] 4.1 — 4 epic-canonical: `search_n-advances` (0xAB), `search_n-wraps-with-notice` (0xAC), `search_n-not-found` (0xAD), `search_n-no-prior-pattern` (0xAE) — all PASS on first run.
  - [x] 4.2 — 1 additional coverage: `search_n-cursor-on-match` (0xAF) — PASS first run; BH4 semantic verified (n walks from cursor+1).
  - [x] 4.3 — 1 parser-dispatch: `parser_n-dispatch` (0xEA) — PASS first run; dispatch_normal['n'] confirmed wired (NOT falling through to unbound_normal).
  - [x] 4.4 — `make test` reports **214 PASS / 1 deliberate-fail** — exact match to spec target.
  - [x] 4.5 — Fixture-seeding pattern matches Story 3.1 conventions; tests pre-seed `search_pattern` length + LDIR `search_pattern_text`; mode_byte = MODE_NORMAL (NOT MODE_COMMAND); cursor pre-set explicitly.
- [x] **Task 5** — NFR18 byte-identical rebuild + UAT:
  - [x] 5.1 — Two `make clean && make all` cycles confirmed byte-identical. SHA `f049865df1da78a9d165817ec3f45f9d26496d66c1d95ddbbb4daaf311e7b705` across both cycles.
  - [x] 5.2 — `make sizes` reports **6503 B / 79.4% of 8192 B / 1689 B headroom**. Net +22 B over 3.1's 6481 B baseline (4 B under spec's ~26 B projection — the tail-JP `status_set_message` optimization in the refactor saved bytes the spec didn't anticipate).
  - [x] 5.3 — Hardware UAT on MicroBeast CONFIRMED by Ant 2026-05-18 — "everything checks out". All 15 AC7 steps pass first iteration; no fix iterations needed.
  - [x] 5.4 — sprint-status `3-2-...` flipped `review` → `done` (2026-05-18). Epic-3 stays in-progress (Stories 3.3-3.8 remain backlog: visual mode + operators + case-toggle).

### Review Findings

Code review run 2026-05-18 against the uncommitted working tree (src/dispatch.asm, src/search.asm, 6 new test/cases/*.asm). Three parallel layers: Blind Hunter (diff-only adversarial), Edge Case Hunter (diff + project read), Acceptance Auditor (diff + spec). Acceptance Auditor verdict: **all 8 ACs MET**. No `decision-needed` findings.

- [x] [Review][Patch] dispatch.asm header comment "slot count grows 34 → 35" should read "35 → 36" [src/dispatch.asm:144] — APPLIED 2026-05-18; comment-only fix, NFR18 SHA `f049865d...` byte-identical post-patch (production binary unchanged).
- [x] [Review][Patch] AC6 parser-state clear is unasserted by any test [test/cases/search_n-advances.asm] — APPLIED 2026-05-18; pre-seeds `count_accumulator=5`, `pending_operator='d'`, `pending_motion_prefix='g'`, `pending_motion_inclusive=1` before CALL search_next and asserts all four are zeroed post-call (context bytes 4-7). Test passes; AC6 now load-bearing-test-pinned.
- [x] [Review][Patch] AC2 "pure reader" claim is unasserted for `command_submode` [test/cases/search_n-advances.asm] — APPLIED 2026-05-18; pre-seeds `command_submode = 0xCC` (sentinel byte) and asserts it's unchanged post-call (context byte 8). Test passes; AC2 pure-reader claim now load-bearing-test-pinned against the search_commit copy-paste hazard.

- [x] [Review][Defer] No test exercises cursor == file_length-1 (degenerate first pass) [test/cases/] — deferred, test-coverage gap; degenerate-pass-1 path verified by inspection (Edge Case Hunter walked the SBC arithmetic; `[file_length, file_length)` short-circuits via NC).
- [x] [Review][Defer] No test exercises empty buffer (file_length == 0) with non-empty search_pattern [test/cases/] — deferred, test-coverage gap; correctness verified by inspection (wrap upper-bound = 1 forces exactly one pos=0 iteration which the EOF guard rejects).
- [x] [Review][Defer] No test exercises cursor on a lone match (Q4 wrap-pin: cursor stays put, status flashes "search wrapped") [test/cases/] — deferred, AC4 Q4-pin invariant — silent regression if wrap upper-bound is ever shifted from `original_cursor+1` to `original_cursor`.
- [x] [Review][Defer] No test exercises 64-byte (SEARCH_PATTERN_BUFFER max) pattern [test/cases/] — deferred, max-bound coverage; would catch DJNZ B=0-on-overflow class regressions.
- [x] [Review][Defer] No test exercises pattern longer than file (sub-pattern-length boundary) [test/cases/] — deferred, EOF-guard short-circuit verified by inspection.
- [x] [Review][Defer] dispatch-→-no-prior path is uncovered by parser_n-dispatch.asm [test/cases/parser_n-dispatch.asm] — deferred, current test seeds search_pattern length 1 so only the match arm of dispatch wiring is exercised; the cold-start `n` path is reached only via direct CALL in search_n-no-prior-pattern.asm.
- [x] [Review][Defer] search_pattern_text payload preservation not asserted [test/cases/search_n-advances.asm] — deferred, only `search_pattern[0]` is checked; payload bytes at `search_pattern_text` are unverified.
- [x] [Review][Defer] search_commit `.check_prior` fall-through fragility — `.run:` reachable by fall-through if a future edit drops the `JP exline_cancel_core` [src/search.asm:262] — deferred, pre-existing 3.1 layout; not introduced by 3.2; consider explicit RET barrier or label relocation in a future cleanup pass.
- [x] [Review][Defer] search_run `POP DE` without defensive SP ASSERT [src/search.asm:236] — deferred, pre-existing 3.1 layout; the matching PUSH lives outside 3.2's diff hunks.

**Dismissed (~17):** Blind Hunter's two BLOCKER flags (tests-at-absolute-path + duplicate-diff-entries) — both bundling artifacts from the diff-construction script, not real working-tree issues; verified `ls test/cases/` shows each file present exactly once at the correct relative path. Other dismissals: AC6's count-ignore is the explicit spec deferral (BH-M1); dispatch_key's docstring at dispatch.asm:184 explicitly licenses handlers to trash all registers (BH-M2); status_buffer layout verified plain-text starting at offset 0 per statusln.asm:106-127 (BH-M3); dispatch_key prefix-skip verified by reading lines 188-196 (BH-M4); status_set_message ends in RET so tail-JPs are safe (BH-L2); parser_clear doesn't touch status_dirty so the no-prior banner survives (EH-8); AC2 / AC8 doc-block-placement and fixture-byte drifts are semantic no-ops (AA-AC2, AA-AC8).

## Dev Notes

### Architecture compliance

**AR13 (single screen-emit path):** `search_next` makes ZERO `BIOS_CONOUT` calls. All status surfaces enter via `status_set_message` (MC5 funnel); cursor repositioning is driven by `render.asm`'s RI4 invariant on the next `render_diff` frame after `cursor_offset` is updated by `search_run`. Same shape as Story 3.1's other public search entries.

**AR14 (single buffer-mutation path):** `search_next` makes ZERO writes to `gap_start` / `gap_end`; never invokes `gapbuf_insert` / `gapbuf_delete` / `gapbuf_move_gap`. Pure-read against the buffer via the inherited `search_run` → `search_forward_from` → `motion_byte_at_logical` chain (Story 2.5's SR3 helper). Search-next is a READER, not a mutator. The single state surface it writes is `cursor_offset` (transitively via `search_run`'s match arms; allowed by SR1).

**AR15 (single BDOS path via `BDOS_CALL` macro):** `search_next` makes ZERO `BDOS_CALL` invocations and ZERO raw `CALL 0x0005` / `CALL BDOS_ENTRY` sites. Pure-memory entry.

**AR23 (module header docstring conventions):** the `search.asm` header extends with a `search_next` entry in the `Public:` block; the routine body lands an AR23-compliant docstring above `search_next:` documenting Purpose / Public surface / In / Out / Trashes / Calls — same shape as `search_begin` / `search_commit` / `search_forward_from`. The "DE NOT preserved across `motion_byte_at_logical`" caveat applies transitively through `search_run` → `search_forward_from`; `search_next` itself does not call `motion_byte_at_logical` directly so the caveat is inherited, not new.

**AR25 (INCLUDE chain order):** `search.asm` already slots between `edits.asm` and `exline.asm` in `src/vibe.asm`'s AR25 chain (Story 3.1 landing). No chain edits in Story 3.2. The new `parser_clear` tail-JP target from `search_next` is a backward reference — `parser.asm` INCLUDEs BEFORE `search.asm` in the chain — so the symbol is already known to sjasmplus on pass 1 by the time `search_next`'s body is assembled.

**MC4 (handler register convention):** `search_next` receives A = 'n' (0x6E) from dispatch_key; ignores it (the routine's behaviour depends only on `search_pattern` state). No MC4 deviation.

**MC5 (single status funnel):** Every status surface in `search_next` uses `status_set_message` with HL = msg ptr, A = 0 (non-error code). Two direct sites (the no-prior arm's `msg_no_previous_pattern`) and three transitive sites (via `search_run`: `msg_mode_normal` on first-pass match, `msg_search_wrapped` on wrap match, `msg_pattern_not_found` on both-passes miss).

**MC7 (state.inc cross-module state):** Story 3.2 adds NO new state. `command_submode` (added by 3.1) is irrelevant to `search_next` — `n` runs from NORMAL mode and never touches the submode. `search_pattern` and `cursor_offset` are existing state surfaces with established read/write protocols.

**B2 (insert-session-as-unit, FR45):** N/A. `n` does NOT mutate the buffer; no undo entry is generated. `op_undo` semantics unchanged across an `n` invocation — pressing `u` after `/main<Enter> n n n` undoes whatever mutation preceded the search session. This matches vim.

**SR1 (cursor_offset range):** `search_next` writes `cursor_offset` only via `search_run`'s match arms. Match offsets are bounded `0 <= match_start < file_length` by the walker's bounds check (inherited from Story 3.1's invariant), so SR1 (0..file_length) is preserved.

**BH4 ("n" after edits re-searches from one byte past current cursor):** Story 3.2 implements BH4 verbatim. `search_next` does NOT cache the last match offset; every invocation re-walks from `cursor_offset + 1` via `search_run`'s `start_1` computation. If the buffer was edited between searches, `n` finds the next match from one byte past wherever the cursor sits now. The `search_n-cursor-on-match` test (AC8) validates the "one byte past" semantic.

### Files this story modifies (and what to preserve)

**NEW FILE:** none. Story 3.2 extends `src/search.asm` rather than creating a new module.

**EDITED FILES:**

| File | Lines / Symbols Changed | What's preserved |
|---|---|---|
| `src/search.asm` | (1) `search_run` exits refactored: 3 × `JP exline_cancel_core` → 3 × `RET` (Task 1.1-1.3; lines 339, 348, 357 in 3.1's landed file). (2) `search_commit`'s commit arm + reuse arm now `CALL search_run ; JP exline_cancel_core` (Task 1.5-1.6; lines 265 + 271). (3) New `search_next` public entry between `search_commit` and `search_run` (Task 2; ~25 B). (4) Module-header `Public:` block extended with `search_next`; `Dependencies:` block extended with `parser.asm`; `State owned` block notes `search_next` is a pure reader of `search_pattern` | `search_begin` body (every byte unchanged); `search_commit`'s commit / reuse logic unchanged in semantics (only the exit transfer is restructured); `search_forward_from` body (every byte unchanged); `search_compute_file_length` body (every byte unchanged); `search_upper_bound` DEFW; the AR13/AR14/AR15 cleanliness invariants |
| `src/dispatch.asm` | (1) `dispatch_normal` table: insert new `'n'` (0x6E) entry between `'l'` (0x6C) and `'o'` (0x6F); 3 B (DEFB key + DEFW handler) plus the two ASSERT lines (assembly-time, zero runtime bytes) (Task 3.1). (2) `DISPATCH_NORMAL_COUNT` recomputes automatically (34 → 35) (Task 3.2). (3) Module-header `Dependencies:` block extended (Task 3.3) | All 34 existing `dispatch_normal` entries (every key / handler / assertion); `enter_insert_mode` / `enter_normal_mode` / `enter_visual_mode` bodies; `dispatch_insert` / `dispatch_command` / `dispatch_visual` tables; the binary-search `dispatch_key` body; the per-mode unbound handlers |
| `_bmad-output/planning-artifacts/architecture.md` | None — NFR9 ceiling is already 8192 B post-3.1; Story 3.2's ~25 B addition stays comfortably under | Every section |
| `_bmad-output/planning-artifacts/prd.md` | None — FR42 / FR43 / FR44 already documented; NFR9 already amended | Every section |
| `_bmad-output/implementation-artifacts/sprint-status.yaml` | `3-2-...`: backlog → ready-for-dev → in-progress → review → done. `last_updated` chain | `epic-3` status (stays in-progress); every other epic/story entry |
| `_bmad-output/implementation-artifacts/deferred-work.md` | Append "Deferred from: dev of story-3-2-repeat-last-search-n-with-wrap (2026-05-XX)" block with Q1-Q3 pins + closure notes; mention counted-`n` (`5n` / `Nn`) as future-polish defer | All existing deferred / resolved entries |

### Implementation choices and trade-offs

**Choice 1: Refactor `search_run` to RET-based and share it between `search_commit` and `search_next`.**

The alternative is to duplicate the two-pass walk inline in `search_next`. Q1 below pins this. The recommended choice (refactor) is mechanical and low-risk:
- Each `search_run` exit changes from `JP exline_cancel_core` (3 B) to `RET` (1 B) — saves 6 B across three exits.
- `search_commit` gains one `CALL search_run ; JP exline_cancel_core` pair (6 B) replacing the current `JR search_run` fall-through (2 B) — costs 4 B; net saving from the refactor alone is ~2 B.
- `search_next` then consumes `search_run` with a single `CALL` (3 B) + tail-`JP parser_clear` (3 B) — its body is ~25 B versus ~50-55 B for the inline-duplication alternative.
- Total saving from the refactor + share, versus duplicate-inline: ~25-30 B. Material on this scale (3.2's whole budget is ~25 B of new code).
- Regression risk is contained because every existing 3.1 test exercises the refactored search_run via search_commit; if any of the 11 search tests + 1 parser-dispatch test fail post-refactor, the regression surfaces immediately. Task 1.7 makes this the load-bearing gate.

The decision aligns with the Story 3.1 hand-off contract: "`search_forward_from` is the Story 3.2 hand-off surface" (search.asm header line 49-56). Story 3.1 also explicitly anticipated a parallel `search_next` per architecture.md:1191's reference shape — the refactor extends that anticipation cleanly.

**Choice 2: `n` does NOT consume a count.**

Q2 pins this. Recommended: defer counted-`n` (`5n` = repeat 5 times) to a future polish story. Rationale:
- Epic AC scopes FR42 to "I press `n`" — no count clause.
- Vim's `Nn` semantic is convenience, not a load-bearing journey-1b primitive. The user can press `n n n n n` to achieve the same outcome with 5 keystrokes.
- Implementing counted-`n` adds ~15-20 B (a counter loop wrapping `search_run`) and edge cases (count > number of matches: do we stop at last match or wrap with notice?). Out-of-scope churn for a story whose value is the single-step path.
- `search_next` STILL tail-JPs `parser_clear` to drop any stale count, so the user pressing `5n` gets exactly one search and a clean parser state. The count is silently absorbed; no error surface.

The polish story (call it 3.2.1 or wherever in Epic-4 cleanup) would add a `LD HL, (count_accumulator)` read at the top of `search_next`, a `CALL search_run` inside a DJNZ loop, and handling for count-overflow vs match-shortage. Not a 3.2 obligation.

**Choice 3: `n` from NORMAL stays in NORMAL.**

No mode transitions. `search_next` does NOT touch `mode_byte`. Contrast with `search_begin` which writes `MODE_COMMAND`. This means `n` is invisible to the mode-state subsystem — no enter_normal_mode equivalent, no status-line mode indicator change. The status line shows search outcomes (clear / wrapped / not-found / no-prior) but the mode_byte read elsewhere stays MODE_NORMAL throughout.

**Choice 4: `parser_clear` at exit (sibling to other NORMAL-mode handlers).**

Every dispatch_normal handler that completes within a single keystroke tail-JPs `parser_clear` per Story 2.5's AC13 contract (`motion_h` / `motion_l` / `enter_insert_mode` / `enter_visual_mode` / `edits_delete_char` / `op_paste` / `op_undo` — all of them). `search_next` follows the same pattern.

The transitive parser_clear via `exline_cancel_core` from Story 3.1's `search_commit` → `search_run` would also reach `parser_clear` (exline_cancel_core tail-JPs parser_clear at exline.asm:614). But invoking `exline_cancel_core` from a NORMAL-mode handler is misleading naming — the routine's purpose is COMMAND → NORMAL transition, not NORMAL → NORMAL housekeeping. The refactor (Choice 1) untangles this: `search_run` becomes mode-agnostic; callers wrap with their own cleanup.

### Previous story intelligence

**From [[story-3-1-forward-literal-search-pattern]] (the immediate predecessor):**
- **`search_forward_from` is the Story 3.2 hand-off surface** (search.asm header lines 49-56). Public; documented contract: `In: HL = start_offset; (search_upper_bound) = exclusive upper bound; Out: CF = 0, HL = match_start on hit; CF = 1 on miss; Trashes: A, BC, DE, HL, F`. Story 3.2 consumes this VERBATIM via `search_run`'s existing two-pass orchestration. No new contract surface.
- **`search_run` orchestrates the two-pass wrap walk** (search.asm lines 314-357). First pass: `[cursor + 1, file_length)`. Wrap pass: `[0, original_cursor + 1)` (Q4-pin: upper bound includes `original_cursor` so a user sitting on a match surfaces "search wrapped"). The wrap-pass narrative + Q4 pin apply identically to `n` — Story 3.2 inherits the semantic without re-deciding.
- **`msg_no_previous_pattern` already exists** in `src/statusln.asm:235`, added by Story 3.1's Task 1.4 for the `/<Enter>` AC4-reuse arm. Story 3.2's AC5 (`n` with empty search_pattern) reuses this string verbatim — no new statusln string needed.
- **Sentinel band 0xAB..0xAF reserved** for Story 3.2's `n` tests per Story 3.1's spec (test count target line: "0xA0..0xAA: search.asm unit tests (11 of 16 reserved slots used; 0xAB..0xAF reserve for Stories 3.2's `n` tests)"). 5 slots — exactly 4 canonical + 1 additional (cursor-on-match). The parser-dispatch slot 0xEA continues the band Story 3.1 ended at 0xE9.
- **NFR9 ceiling is 8192 B post-3.1**, with 1711 B headroom (3.1 final = 6481 B / 79.1%). Story 3.2's ~25 B addition lands at ~6506 B / 79.4% — comfortable. No NFR9 amend needed.
- **NFR18 SHA `0ff58bdc23a89a14292a3c2fa413661acc0328066ab58b2b117313b2ef10c258`** for `vibe.com` post-3.1 — the baseline Story 3.2 starts from. Two `make clean && make all` cycles post-3.2 should produce a NEW SHA (the binary changes), but the same SHA across the two cycles (NFR18 reproducibility).
- **Test/Makefile dep-hygiene fix landed in 3.1** (action A1 from the Epic-2 retro). Story 3.2's test additions don't need to revisit this — the `cases/%.com` rule already depends on `$(wildcard ../src/*.asm) $(wildcard ../inc/*.inc)`, so any change to `src/search.asm` or `src/dispatch.asm` rebuilds all test cases on the next `make test`.
- **The `bulk-INCLUDE-search.asm`-into-tests patch was completed in 3.1** (184 test files). Story 3.2's new test files inherit the existing INCLUDE chain template (test_prologue → body → test_epilogue → statusln/gapbuf/render/dispatch/parser/motions/edits/**search**/exline/fileio/undo → test_teardown_stub → test_input_loop_stub → state.inc). No bulk patch needed.

**From [[story-2-5-basic-motions-h-j-k-l]] (the AC13 parser_clear protocol origin):**
- **Every dispatch_normal handler tail-JPs `parser_clear`** to drop any stale count / operator / motion-prefix from before the keystroke. Story 3.2's `search_next` follows this verbatim. The `parser_clear` body (parser.asm:228-235) zeroes `pending_operator` + `pending_motion_prefix` + `pending_motion_inclusive` + `count_accumulator` (4 cells, 5 bytes total).

**From [[story-2-13-single-level-undo-u]]:**
- **Single dev-commit per story** (Stories 2.11/2.12/2.13/3.1 pattern). Story 3.2 follows the same — production code + tests + sprint-status flips in one commit (Q3 pin).

**From [[story-1-12-init-teardown-on-hardware-smoke-test]]:**
- **`init_cold_start`'s LDIR zero-fill** zeroes `search_pattern[0]` (the length byte) along with the rest of the static block on cold-start. So the first `n` after boot (with no prior `/pattern`) reads `search_pattern[0] == 0` and takes the AC5 no-prior arm correctly. UAT step 3 in AC7 validates this on hardware.

**From [[feedback_create_story_cross_check]] memory:**
- **CR/CRLF handling**: N/A for Story 3.2 — `search_next` doesn't add any new pattern-matching semantics. The existing byte-for-byte literal walk in `search_forward_from` handles CR/LF transparently (a pattern containing neither still matches across CR/LF boundaries by virtue of being a substring; a pattern *containing* CR or LF is impossible because `exline_append_literal`'s 0x20-0x7E filter blocks them from ever entering ex_buffer — the persistent slot can therefore never contain CR or LF either, since it's exclusively LDIR'd from ex_buffer).
- **sjasmplus-hostile filenames**: all proposed test filenames use only `a-z`, `0-9`, `-`, `_` — safe. No `$` collisions like Story 2.11's edits_d$ rename.
- **Cursor arithmetic**: post-`:e` cursor at offset 0 per [[feedback_uat_trace_cursor]]; UAT step 3 (`n` immediately after boot, before any `/`) tests the no-prior arm cleanly without needing cursor movement.
- **NFR9 projections**: explicit headroom calculation above; 8192 B ceiling already amended.
- **No `~` empty-line marker**: `search_next` doesn't paint UI. Past-EOF rows still render as 0x20 spaces per [[project_no_tilde_marker]]. UAT script avoids `~` predictions.

**From [[feedback_uat_inline_at_dev_handoff]] memory:**
- Dev handoff message MUST paste the AC7 15-step UAT script verbatim, NOT just point at this file.

### Git intelligence

Recent commits (post-Story-3.1; direct lineage to 3.2):

- `231ce3f Story 3.1: forward literal search /pattern lands; FR41 closes` — Story 3.1 dev + UAT + done flip (6481 B / 79.1% NFR9 / 1711 B headroom; Epic-3 in-progress; FR41 closed).
- `c8fb896 Story 2.13: single-level undo u lands; FR45/FR46 closed; closes Epic 2` — Epic 2 closure baseline.
- `0756610 story 2.12: paste p / Np lands (KIND_CHAR + KIND_LINE; KIND_BLOCK reserved)` — yank-register reader pattern; `search_next` follows a similar pure-reader shape but against search_pattern, not yank_register.
- `84dd7d4 story 2.11: operator+motion compose (dw/d$/c5w/y3j) + >> / << landed` — compose layer.
- `94b4f16 story 2.9: x deletes char under cursor; counted Nx with EOL/EOF clamp` — counted-handler precedent (Story 3.2 explicitly does NOT replicate this; Q2 pins the deferral).

**Story 3.1 is the immediate predecessor.** Story 3.2 starts from the 3.1 baseline (6481 B / 1711 B headroom / Epic 3 in-progress / FR41 closed / FR42-FR44 pending — closed by this story).

**Patterns to follow** (consolidated from Stories 2.5-3.1):

- Single dev-commit per story containing production code + tests + sprint-status flips (Story 2.13 + 3.1 pattern; Q3 pin).
- Sentinel byte at `0xCFFE` per TH1; unique sentinel per test; disjoint band per module. Story 3.2's `n` band: 0xAB..0xAF (5 slots, all 5 used).
- INCLUDE chain in test cases: pre-ORG headers, `test_prologue.inc`, test body, `test_epilogue.inc`, production sources (in AR25 order, search.asm slotted between edits.asm and exline.asm per 3.1's landing), `test_teardown_stub.inc`, `test_input_loop_stub.inc`, finally `inc/state.inc`. **No chain changes for Story 3.2.**
- Gap-buffer fixture pattern: `CALL gapbuf_init` → LDIR payload → set `gap_start := GAP_BUFFER_BASE + N`. Cursor pre-set via `LD HL, N ; LD (cursor_offset), HL`. Mode pre-set via `LD A, MODE_NORMAL ; LD (mode_byte), A` for `n` tests (NORMAL, not COMMAND).
- **Search-pattern pre-seed for `n` tests:**
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
- **Direct `CALL search_next` for `n` test bodies** — there's no `ex_buffer` pre-seeding (no editing surface; `n` runs from NORMAL with whatever's already in `search_pattern`).
- **Direct dispatch invocation for parser-dispatch coverage test** (mirrors `parser_slash-dispatch.asm` from Story 3.1): mode_byte = MODE_NORMAL; pattern + buffer pre-seeded; `LD A, 'n' ; LD HL, dispatch_normal ; LD B, DISPATCH_NORMAL_COUNT ; CALL dispatch_key` (HL is the table base — the unbound prefix — NOT `dispatch_normal + 2`; dispatch_key skips the prefix internally). Verifies the dispatch wiring (NOT falling through to unbound_normal).
- **NFR18 verification pattern**: post-dev pass, `make clean && make all` twice; sha256sum prefix matches across both cycles. Expect a NEW SHA versus 3.1's `0ff58bdc...` baseline (binary changes), but the same SHA across the two 3.2 cycles.

### Implementation Questions (resolve with Ant before dev starts)

**Q1 — `search_run` refactor strategy.** Story 3.1's `search_run` currently tail-JPs `exline_cancel_core` at every exit (3 sites). `search_next` (called from NORMAL mode) would need either (a) the same code path with `exline_cancel_core`'s NORMAL→NORMAL no-op writes harmless, or (b) `search_run` refactored to RET-based with caller-side cleanup.

- **Option A (recommended)**: Refactor `search_run` to RET-based. `search_commit` becomes `CALL search_run ; JP exline_cancel_core` (replacing the current `JR search_run` fall-through and `JR NZ, search_run` reuse-arm jumps). `search_next` becomes `CALL search_run ; JP parser_clear`. Net byte saving from sharing search_run between the two callers: ~25-30 B over the duplicate-inline alternative. Regression risk: contained by 3.1's existing 12-test net (Task 1.7).
- **Option B**: Leave `search_run` untouched. Duplicate ~30 B of two-pass walk logic into `search_next`. Trade-off: +25-30 B over Option A; no perturbation of 3.1's well-tested code; but creates a parallel walk that future maintainers must keep in sync.
- **Option C**: Have `search_next` JP `search_run` and accept that `exline_cancel_core` is invoked from a NORMAL-mode handler. Trade-off: 0 perturbation of 3.1; ~3 B saved over Option A (no separate `parser_clear` tail-JP because exline_cancel_core's terminal `JP parser_clear` covers it); but the routine name is misleading and `exline_cancel_core` writes `mode_byte = MODE_NORMAL` / `ex_buffer = 0` / `command_submode = 0` redundantly (3 cells, all already at the target value in NORMAL mode — wasted bytes at runtime but not functional bugs).

Recommended decision: **Option A** — clean shape; minimal byte cost; one-time refactor that pays off across the rest of Epic 3's search-state additions (none currently anticipated, but the refactor is the right shape).

**Q2 — Counted-`n` (`5n` = repeat 5 times) — defer to a future polish story (recommended) vs land in 3.2.**

- **Option A (recommended)**: Defer. Epic AC scopes FR42 to single-step `n` only. `search_next` tail-JPs `parser_clear` so a `5n` keystroke sequence still produces exactly one search and a clean parser state; the count is silently absorbed. The user can achieve `5n` by pressing `n n n n n` (5 keystrokes; ~50 ms each on a 4 MHz Z80 = ~250 ms of physical typing for the same outcome).
- **Option B**: Land counted-`n` in 3.2. Adds ~15-20 B (`LD HL, (count_accumulator) ; LD A, H ; OR L ; JR Z, .single ; ...DJNZ loop...`). Edge cases: count > number of matches (stop at last match or wrap with notice?); count = 0 (silently treat as 1, matching `2dd` precedent? or treat as "do nothing"?). The edge-case decisions multiply test obligations by ~3-4×.
- **Option C**: Land counted-`n` AND counted-`?n` and `N` (reverse repeat) and `?pattern` (reverse search) in one bigger story. Trade-off: scope creep; breaks Epic-3 cadence; no FR exists for `?` or `N` in MVP scope.

Recommended decision: **Option A** — defer. The polish story (Epic-4 cleanup or wherever) inherits a clean Story 3.2 to extend.

**Q3 — Separate code-review commit (Story 2.10 pattern) or single dev commit (Stories 2.11/2.12/2.13/3.1 pattern)?**

Story 3.2's scope is small: ~25 B of new code + 6 new tests + a small dispatch.asm edit. Story 3.1's similar-shape decision was Option A (single commit).

- **Option A (recommended)**: Single dev commit. Matches recent precedent.
- **Option B**: Separate code-review commit (Story 2.10 style). Heavier than 3.2's scope warrants.

Recommended decision: **Option A** — consistent with the four most recent stories.

### NFR9 budget arithmetic (worked example)

Assuming Q1 Option A (refactor + share) + Q2 Option A (no counted-`n`):

| Component | Estimated bytes |
|---|---|
| `src/search.asm` — `search_run` refactor (3 × `JP exline_cancel_core` → 3 × `RET`) | **net -6 B** |
| `src/search.asm` — `search_commit` exit restructure (gains `CALL search_run ; JP exline_cancel_core` at one shared label; loses the existing `JR search_run` fall-through and `JR NZ, search_run`) | **net +4 B** |
| `src/search.asm` — `search_next` body (~25 B per Task 2.2 sketch) | **+25 B** |
| `src/dispatch.asm` — new `dispatch_normal` entry for `'n'` (DEFB key + DEFW handler) | **+3 B** |
| `src/search.asm` — module header docstring growth (search_next entry in Public block; parser.asm in Dependencies block) | **0 B (comments)** |
| `src/dispatch.asm` — module header `src/search.asm` block extension | **0 B (comments)** |
| ASSERT lines (`'n' > 'l'`, `'o' > 'n'`) | **0 B (assembly-time)** |
| `DISPATCH_NORMAL_COUNT` recompute (34 → 35) | **0 B (computed EQU)** |
| **Total** | **~+26 B code** |

Post-3.2 projection: 6481 + ~26 = **~6507 B / 79.4% of 8192 B / ~1685 B headroom**.

This headroom comfortably supports the remaining 6 Epic-3 stories (visual mode + visual operators) projected at ~600-800 B per the Story 3.1 budget arithmetic. Final Epic-3 close expected to land 7100-7400 B / 87-90% / 800-1100 B residual headroom.

### Test count target

6 new tests:
- 4 epic-canonical (AC8): `search_n-advances`, `search_n-wraps-with-notice`, `search_n-not-found`, `search_n-no-prior-pattern` (sentinels 0xAB-0xAE)
- 1 additional coverage (AC8): `search_n-cursor-on-match` (sentinel 0xAF; BH4-specific)
- 1 parser-dispatch coverage (AC8): `parser_n-dispatch` (sentinel 0xEA)

Pre-existing test count post-3.1: 208 PASS + 1 deliberate-fail = 209 cases / 208 passing. Post-3.2 target: **214 PASS / 1 deliberate-fail = 215 cases**.

**Sentinel band allocation (updated):**

| Band | Module | Slots used | Source |
|---|---|---|---|
| 0x80..0x88 | motions | 9 | Stories 2.5-2.7 |
| 0x90..0x97 | paste (edits) | 8 | Story 2.12 |
| 0xA0..0xAA | search (`/`) | 11 | Story 3.1 |
| 0xAB..0xAF | search (`n`) | **5** (NEW) | **Story 3.2** |
| 0xC0..0xCF | undo | 16 | Story 2.13 |
| 0xE0..0xE9 | parser-dispatch (Stories 1.10 / 2.1 / 2.13 / 3.1) | 10 | various |
| 0xEA..0xEA | parser-dispatch (Story 3.2 `n`) | **1** (NEW) | **Story 3.2** |
| 0xF0..0xFF | harness internals | various | Story 1.6 |

No collisions with existing bands.

### Project Structure Notes

- **No conflicts.** Story 3.2 fits cleanly in the existing project structure:
  - Extends `src/search.asm` with one new public entry (`search_next`); no new module.
  - Extends `src/dispatch.asm`'s existing `dispatch_normal` table with one new entry; preserves the binary-search sorted-ascending invariant.
  - No state.inc / equates.inc / statusln.asm changes (all needed strings + state cells landed in 3.1).
  - No render.asm changes (`n` doesn't change rendering semantics; the existing render_diff frame consumes the post-search cursor_offset just like motions do).
  - No exline.asm changes (`n` bypasses COMMAND mode entirely).
  - New tests at `test/cases/search_n-*.asm` (matches AR21 + TH2 naming; clusters next to the existing 3.1 `search_forward-*.asm` files alphabetically).

- **Forward-reference resolution:** `dispatch_normal['n']` → `search_next` resolves on sjasmplus's pass 2 (search.asm INCLUDEs after dispatch.asm in vibe.asm's AR25 chain). Same shape as Story 3.1's `search_begin` forward reference at dispatch.asm:486.

- **The `search_run` refactor is the only Story-3.1 behaviour-touching change.** Every other 3.2 change is additive (new public entry; new dispatch entry; new tests). The refactor itself is mechanical and validated by the 12 existing 3.1 tests; Task 1.7 makes the regression check explicit.

### References

- **PRD** (`_bmad-output/planning-artifacts/prd.md`):
  - FR42 (line 770) — Story 3.2 functional requirement (`n` repeats last search).
  - FR43 (line 771-772) — wrap notice ("VIBE reports the wrap").
  - FR44 (line 773-774) — pattern-not-found surface.
  - §Search (line 520-531) — overall search semantics; literal/forward/wrap/pattern-buffer/case-sensitive pins (inherited from 3.1).
  - §NFR9 (line 848-862) — 8192 B ceiling (post-3.1 amend); audit-trail block.

- **Architecture** (`_bmad-output/planning-artifacts/architecture.md`):
  - AR23 (module header conventions) — `search_next` AR23 docstring shape.
  - AR25 (INCLUDE chain order) — `search.asm` already slotted (Story 3.1); no chain change.
  - Line 691-697 — BH4 ("`n` after edits re-searches from one byte past current cursor"). Story 3.2 implements this verbatim via `search_run`'s `start_1 = cursor_offset + 1` arithmetic.
  - Line 1186-1196 — module header REFERENCE shape (`search_prompt + search_next`). Story 3.1 implemented `search_prompt` as `search_begin`; Story 3.2 lands `search_next`.
  - Line 1192 — `search_next` documented: "n: re-search from cursor with last pattern".
  - Line 1201-1221 — sample `search_next` skeleton (informational). Story 3.2's actual implementation is leaner (no last-match offset cached; reuses `search_run` directly).
  - Line 1539 (FR-to-module mapping) — FR41-FR44 → `search.asm` with `exline + gapbuf + statusln` support. Story 3.2 adds `parser.asm` to the dependency set (the new `parser_clear` tail-JP target).

- **Epics** (`_bmad-output/planning-artifacts/epics.md`):
  - Lines 1526-1555 — Story 3.2 epic spec (3 AC clauses + UAT clause + 4 canonical tests).
  - Lines 1480-1485 — Epic 3 overview + visual-highlighting platform-constraint note (Story 3.2 doesn't touch visual rendering; no constraint).
  - Lines 1486-1525 — Story 3.1 epic spec (immediate predecessor; defines the `search_forward_from` helper Story 3.2 inherits).

- **Previous stories** (all under `_bmad-output/implementation-artifacts/`):
  - `3-1-forward-literal-search-pattern.md` — `search_forward_from` hand-off contract; `search_run` orchestration; sentinel band reservation; NFR9 amend baseline.
  - `2-13-single-level-undo-u.md` — single-commit story pattern; bulk-test-patch precedent (no bulk patch needed for 3.2).
  - `2-5-basic-motions-h-j-k-l.md` — AC13 parser_clear tail-JP protocol for NORMAL-mode handlers.
  - `2-9-single-character-delete-x.md` — `x` is the prior FR42-style "single key, mutating in NORMAL" handler; same dispatch_normal slot shape that Story 3.2's `n` follows.

- **Source files** (all under `src/`):
  - `dispatch.asm` (lines 476-583 `dispatch_normal` table; line 559-564 the `l` / `o` boundary where `n` slots in; lines 135-141 module header `src/search.asm` dependency block to extend).
  - `search.asm` (line 206-213 `search_begin`; line 249-277 `search_commit`; line 314-357 `search_run` to refactor; line 392-437 `search_forward_from`; line 456-463 `search_compute_file_length`; line 476-477 `search_upper_bound`).
  - `parser.asm` (line 228-235 `parser_clear` — the new tail-JP target from `search_next`).
  - `statusln.asm` (line 224-225 `msg_pattern_not_found` / `msg_search_wrapped` — reused via search_run; line 235 `msg_no_previous_pattern` — reused directly by `search_next`'s no-prior arm).
  - `motions.asm` (line 557 `motion_byte_at_logical` — reached transitively through `search_run` → `search_forward_from`; DE-trash contract still applies but inherited, not new).

- **Memory pins applied** (from MEMORY.md):
  - [[feedback_uat_trace_cursor]] — UAT script starts with cursor at offset 0 post-`vibe fizzbuzz.fs`; AC7 step 2 explicitly confirms this.
  - [[feedback_uat_inline_at_dev_handoff]] — dev handoff message pastes AC7 15-step UAT script inline.
  - [[project_no_tilde_marker]] — no `~` empty-line marker references anywhere in this story; past-EOF rows render as spaces.
  - [[feedback_create_story_cross_check]] — CR/CRLF / sjasmplus filenames / cursor arithmetic / NFR9 / render-semantics cross-checks applied above.

- **Deferred work** (`_bmad-output/implementation-artifacts/deferred-work.md`):
  - Line 210 — `gapbuf_byte_at_logical` extraction (Story 2.5 AC16 Path B). Story 3.1 chose Path A; Story 3.2 inherits Path A (no extraction). Stays open as future polish; `search_next` doesn't add a new consumer beyond what 3.1 already wired.
  - Line 245 — `motion_byte_at_logical` "trashes DE" contract. Story 3.1's `search.asm` header explicitly notes this; Story 3.2's `search_next` doesn't call `motion_byte_at_logical` directly (the call is transitive through `search_run` → `search_forward_from`), so the DE-trash concern is inherited and already addressed by 3.1's save/restore pattern in `search_forward_from`'s inner loop.

## Dev Agent Record

### Agent Model Used

Claude Opus 4.7 (`claude-opus-4-7[1m]`, 1M-context variant) via Claude Code.

### Debug Log References

(No debug rabbit-holes worth a separate log — the dev pass landed clean on the first build: Q1-Q3 pinned via AskUserQuestion → all 3 recommendations accepted; `search.asm` refactor assembled clean on the first sjasmplus pass and held 208 PASS / 1 deliberate-fail; `search_next` body + dispatch_normal `'n'` entry assembled clean; all 6 new tests PASSED on first run; full test sweep landed at 214 PASS / 1 deliberate-fail = exactly the spec target.)

### Completion Notes List

- **Q1-Q3 pins (Task 0):** All three recommendations accepted by Ant via AskUserQuestion. Q1 = refactor `search_run` to RET-based + share; Q2 = defer counted-`n` (`5n` semantics) to a future polish story; Q3 = single dev commit.
- **`search_run` refactor (Task 1):** Three exit arms collapsed from `CALL status_set_message ; JP exline_cancel_core` to single tail-JP `status_set_message` (the routine already RETs cleanly). Saves 3 B across the three exits beyond the straight RET-conversion the spec projected. `search_commit` restructured around a new shared `.run` label that hosts `CALL search_run ; JP exline_cancel_core`; the commit arm (`JR search_run` → `JR .run`) and the reuse arm (`JR NZ, search_run` → `JR NZ, .run`) both land there. The no-prior arm of `search_commit` is unchanged. All 12 Story-3.1 search + parser tests held (208 PASS / 1 deliberate-fail unchanged from baseline) — Task 1.7's regression net validated the refactor bit-for-bit.
- **`search_next` (Task 2):** ~22 B body (1 B tighter than the projected ~25 B). Implements AC3 (CALL `search_run` on non-empty `search_pattern`) / AC4 (status outcomes inherited from `search_run`) / AC5 (no-prior arm surfaces `msg_no_previous_pattern`) / AC6 (every exit tail-JPs `parser_clear` so any stale count / operator / motion-prefix is dropped). Full AR23 docstring including the BH4 note ("walks from cursor+1, NOT cursor"). Module-header `Public:` block extended with the entry; `Dependencies:` block extended with `src/parser.asm` (the new `parser_clear` tail-JP target — backward reference since parser.asm INCLUDEs before search.asm in the AR25 chain) and rewritten `src/exline.asm` block to reflect the refactor (search_run no longer tail-JPs exline_cancel_core itself).
- **dispatch_normal wiring (Task 3):** 3-byte entry inserted between `'l'` (0x6C) and `'o'` (0x6F). Two new `ASSERT` siblings: `'n' > 'l'` and `'o' > 'n'` (replaced the prior `'o' > 'l'`). `DISPATCH_NORMAL_COUNT` auto-grew from 0x23 (35) to 0x24 (36). Module-header `src/search.asm` Dependencies block in dispatch.asm extended with Story 3.2's note + the search_run refactor cross-reference. **Story-spec note:** the spec said "slot count grows 34 → 35" — the spec's pre-3.2 count was off by 1 (pre-3.2 was 35, not 34; pre-3.1 was 34). Auto-computed value is correct; narrative drift only.
- **NFR9 final: 6503 B / 79.4% of 8192 B / 1689 B headroom.** Came in 4 B UNDER the spec's projected ~6507 B because the search_run refactor's tail-JP `status_set_message` optimization saved 3 B beyond the straight RET conversion the spec anticipated. Net +22 B over Story 3.1's 6481 B baseline.
- **NFR18: byte-identical rebuild confirmed.** Two `make clean && make all` cycles produced the same `vibe.com` SHA-256 `f049865df1da78a9d165817ec3f45f9d26496d66c1d95ddbbb4daaf311e7b705`. (New SHA versus 3.1's `0ff58bdc...` baseline as expected — the binary changed; reproducibility held across rebuild cycles.)
- **Test count: 214 PASS / 1 deliberate-fail** (was 208/1 post-3.1; +6 new — exactly matching the spec's 4 canonical + 1 BH4 coverage + 1 parser-dispatch target). All 6 new tests passed on the FIRST run; no fix iterations.
- **AR sweep clean:** `src/search.asm` continues to have zero `BIOS_CONOUT` call sites, zero direct writes to `gap_start` or `gap_end`, zero `BDOS_CALL` invocations, and zero raw `CALL 0x0005` sites. The `search_next` addition does not introduce any new AR carve-outs. Same archetype as motions.asm.
- **DE-trash invariant:** `search_next` does NOT call `motion_byte_at_logical` directly (the call chain is `search_next` → `search_run` → `search_forward_from` → `motion_byte_at_logical`), so the DE-trash concern is inherited from 3.1's `search_forward_from` inner-loop stack save. No new caveat surface.
- **Sentinel band hygiene:** 0xAB..0xAF reserved by Story 3.1 are now fully used (5 slots; 5 tests). 0xEA is the next slot in the parser-band after 3.1's 0xE9 (parser_slash-dispatch). No collisions with motions (0x80..0x88), paste (0x90..0x97), search-/ (0xA0..0xAA), undo (0xC0..0xCF), parser (0xE0..0xE9), harness (0xF0+).
- **Q2 single-step `n` validated by hand:** the test scaffolding for `search_n-advances` and `parser_n-dispatch` does not pre-set `count_accumulator`. If `search_next` had been wired to consume the count (Q2 Option B), the dispatched call from `parser_n-dispatch` would have read whatever garbage was at `count_accumulator` and either short-circuited or looped — instead the test PASSes cleanly, confirming counted-`n` was correctly NOT implemented. Future polish story can wrap `search_run` in a count-loop without touching the existing scaffolding.
- **Hardware UAT (AC7):** the 15-step UAT script is delivered INLINE in the dev handoff chat message per [[feedback_uat_inline_at_dev_handoff]] — Ant runs it on real MicroBeast; on confirm the sprint-status flips `review` → `done`.

### File List

**MODIFIED (production):**
- `src/search.asm` — (1) `search_run` exits refactored: 3 × `CALL status_set_message ; JP exline_cancel_core` → 3 × tail-JP `status_set_message`. (2) `search_commit` restructured around a new shared `.run` label (`CALL search_run ; JP exline_cancel_core`); the commit arm + reuse arm both land there. (3) NEW `search_next` public entry (~22 B) between `search_commit` and `search_run`. (4) Module-header `Public:` block extended with `search_next`; `Dependencies:` block extended with `src/parser.asm`; `src/exline.asm` block rewritten to reflect the refactor. (5) Module-header `Story 3.2 Q1 refactor` note added to `search_run`'s contract block.
- `src/dispatch.asm` — (1) NEW `dispatch_normal` entry for `'n'` (0x6E) between `'l'` (0x6C) and `'o'` (0x6F): `ASSERT 'n' > 'l'` + `DEFB 'n'` + `DEFW search_next` + `ASSERT 'o' > 'n'` (replaced the prior `'o' > 'l'`). (2) Module-header `src/search.asm` Dependencies block extended with Story 3.2's `search_next` note and the search_run RET-refactor cross-reference. `DISPATCH_NORMAL_COUNT` auto-recomputes 0x23 → 0x24 (35 → 36).

**NEW (tests):**
- `test/cases/search_n-advances.asm` (sentinel 0xAB) — happy-path first-pass match; buffer "main\nfoo\nmain\n"; cursor=0; expect cursor=9, status cleared.
- `test/cases/search_n-wraps-with-notice.asm` (sentinel 0xAC) — first pass miss + wrap match; buffer "main\nfoo\nbar"; cursor=5; expect cursor=0, status starts with "search wrapped".
- `test/cases/search_n-not-found.asm` (sentinel 0xAD) — both passes miss; buffer "foo bar baz"; pattern="xyz"; expect cursor UNCHANGED, status starts with "pattern not found".
- `test/cases/search_n-no-prior-pattern.asm` (sentinel 0xAE) — search_pattern[0]=0 (cold-start); expect cursor UNCHANGED, status starts with "no previous pattern".
- `test/cases/search_n-cursor-on-match.asm` (sentinel 0xAF) — BH4 semantic; cursor on first "main"; expect cursor advances to second "main" at offset 5 (NOT 0).
- `test/cases/parser_n-dispatch.asm` (sentinel 0xEA) — drives `'n'` through `dispatch_key` with `HL = dispatch_normal`; expect cursor moves to the 'x' match (proves dispatch lands in search_next, NOT unbound_normal).

**MODIFIED (planning artifacts):**
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `3-2-...` flipped backlog → ready-for-dev → in-progress → review with `last_updated` chain. Epic-3 unchanged at in-progress.
- `_bmad-output/implementation-artifacts/3-2-repeat-last-search-n-with-wrap.md` — this file: Status → `review`; all Tasks 0-5 marked `[x]` (5.3 + 5.4 pending hardware UAT); Dev Agent Record + File List + Change Log populated.

**NOT MODIFIED (verified unchanged):**
- `inc/state.inc` — no state additions (all needed cells landed in 3.1).
- `inc/equates.inc` — no new equates.
- `src/statusln.asm` — no new strings (msg_no_previous_pattern already added in 3.1; msg_pattern_not_found / msg_search_wrapped pre-existing).
- `src/parser.asm` — read-only consumer of `parser_clear` (unchanged).
- `src/motions.asm` — no changes (motion_byte_at_logical reached transitively, not directly).
- `src/render.asm` — no changes (`n` doesn't alter render semantics).
- `src/exline.asm` — no changes (`n` bypasses COMMAND mode entirely; exline_cancel_core still consumed by search_commit's shared `.run` arm).
- `src/vibe.asm` — no AR25 INCLUDE chain changes.
- `Makefile` / `test/Makefile` — no changes.
- `_bmad-output/planning-artifacts/prd.md` / `architecture.md` — no NFR9 amend (8192 B ceiling already in place from 3.1).

### Change Log

- 2026-05-18 — Story 3.2 dev pass complete; Status `ready-for-dev` → `in-progress` → `review`. Q1-Q3 pins resolved via AskUserQuestion (all three recommendations accepted). `search_run` refactored to RET-based with tail-JP `status_set_message` optimization (Task 1). New `search_next` public entry in `src/search.asm` (~22 B; AR23-compliant docstring; tail-JPs `parser_clear` per AC13 protocol). `dispatch_normal['n']` wired between `'l'` and `'o'` (Task 3). 6 new headless tests landed under `test/cases/` (sentinels 0xAB-0xAF + 0xEA — band reserved by 3.1; no collisions). NFR18 SHA `f049865df1da78a9d165817ec3f45f9d26496d66c1d95ddbbb4daaf311e7b705` byte-identical across two `make clean && make all` cycles. Test count 208 → 214 PASS / 1 deliberate-fail (+6 new; all PASSED on first run). Code size 6481 → 6503 B (+22 B; 4 B under spec's ~26 B projection thanks to the tail-JP optimization). FR42 / FR43 / FR44 / BH4 all closed end-to-end. Hardware UAT (AC7, 15 steps) deferred to user — script pasted inline at dev-handoff per [[feedback_uat_inline_at_dev_handoff]].
