# Deferred-Work Triage — 2026-05-19

Triage pass over `deferred-work.md` (507 lines, 40 sections, Stories 1.1 → 4.2). Goal: clear the backlog by separating **already-closed entries** (just need archival), **junk** (won't ever do, delete), and **real dev work** (ready to scope as stories).

Authored after `bmad-code-review` was reframed as a backlog triage; line numbers below reference `deferred-work.md` at HEAD = `1c9e759` + the uncommitted 4.2-review block appended at the end.

---

## 1. Already closed — archive these

These entries already have explicit `**RESOLVED by Story X.Y**` annotations in-place. They can be moved to a "Closed" section, deleted outright, or left as historical context. No follow-up dev work owed:

| Source story / line | Subject | Closed by |
|---|---|---|
| 1.2 / L11-12 | `VT52_GOTO` row/col clamp | Story 1.11 |
| 1.3 / L16-18 | `search_pattern` / `ex_buffer` length-byte EQU | Story 2.1 + 3.1 |
| 1.3 / L19-20 | Static state zero-init | Story 1.12 |
| 1.3 / L21-22 | `shadow_buffer` page alignment | Story 1.11 (no alignment) |
| 1.4 / L30-37 | `BIOS_TICK_ADDR` placeholder overlap | Story 1.12 |
| 1.8 / L68-69 | `input_held_*` uninitialised at boot | Story 1.12 |
| 1.8 / L71 | `tick_wait_one` hangs without ISR | Story 1.12 (ISR install) |
| 1.10 / L88-90 | Mode transitions don't clear parser state | Story 2.5 |
| 1.10 / L91-93 | Unbound key in NORMAL doesn't clear parser state | Story 2.5 |
| 1.10 / L94-96 | gg-stub real handler hook-site | Story 2.6 (gg arm) + 2.10 (doubled-op arm) |
| 1.11 / L79-80 | `render_emit_goto` D/E save | Story 1.12 (hardware found exactly this) |
| 2.1 / L109-110 | `init_teardown` stub refactor | Story 2.4 (`test_teardown_stub.inc`) |
| 2.2 dev / L122 | NFR9 overshoot 3106 B / 101 % | NFR9 amend chain (6.6 → 10240) |
| 2.2 dev / L125-126 | Test stub duplication | Story 2.4 |
| 2.2 review / L130 | NFR9 amend to 5120 B | Story 2.6 |
| 2.3 / L152-153 | `fileio.asm` AR carve-out doc | Story 2.6 (architecture.md update) |
| 2.5 dev / L207 | AC15 architecture.md AR carve-out doc | Story 2.6 |
| 2.5 dev / L208-210 | AC16 helper-placement | Story 3.1 re-confirmed |
| 2.5 dev / L212 | Story 2.7 count-respected E2E test | Story 2.7 |
| 2.5 review / L218 | Sticky-column across counted j/k | Story 2.7 |
| 2.6 dev / L245 | `motion_find_line_end` / `motion_byte_at_logical` DE-trash invariant | Story 4.1 AC4 |
| 2.6 dev / L248 | AC15 doc bundle | Story 2.6 |
| 2.8 dev / L284 | B2 INSERT-session undo recording stub | Story 2.13 |
| 2.9 dev / L304 | FR45 `edits_delete_char` undo stub | Story 2.13 |
| 2.10 dev / L318 | FR45 `op_dd` undo stub | Story 2.13 |
| 2.10 review / L342 | `undo_buffer` not written by `op_dd` | Story 2.13 (moot) |
| 2.11 dev / L354-357 | FR45 compose-op undo stubs | Story 2.13 |
| 2.12 dev / L380 | NFR9 amend to 5760 B | Story 2.13 (subsequent amend) |
| 2.12 dev / L388 | FR45 `op_paste` undo stub | Story 2.13 |
| 2.13 dev / L411 | NFR9 amend to 6400 B | Story 3.1 (subsequent amend to 8192) |
| 3.2 dev / L432 | `search_run` RET-based refactor | Story 3.2 (the refactor itself) |
| 3.8 review / L480 | Visual `~` unit-test gaps T1-T10 | Story 4.1 AC5 |
| 3.8 review / L481 | Caller-side bound hardening (4 findings) | Story 4.1 AC1/AC2/AC3 |
| 4.1 review / L492 | AC1 file_length=0 regression-pin gap | Resolved 2026-05-19 in-session (`visual_tilde-empty-buffer.asm`) |

**Action:** PM either deletes these entries outright or moves them to a `## Closed Deferrals` section at the bottom of `deferred-work.md`.

---

## 2. Junk — delete

Speculative, defensive-only, or "won't ever do" entries with no concrete trigger. Recommend deleting:

### Stale recurring re-flags

- **`test/Makefile` doesn't track `src/*.asm`** — re-flagged 4× (Story 2.5 L238; 2.6 L258; 2.8 dev L292; 2.8 review L300). **STALE — already FIXED:** `test/Makefile:46-59` has `PROD_SRC := $(wildcard ../src/*.asm)` and the `cases/%.com` rule lists it. Delete all 4 re-flags.

### Story 1.3 — project-cosmetic doc concerns

- L23 mode-state protocol undocumented (de facto pinned across many stories now)
- L24 no `IFDEF` re-include guard (sjasmplus catches dup-symbol already)
- L25 per-section sentinel ASSERTs (defensive, never tripped)
- L26 `.inc` filename convention (cosmetic)

### Story 1.5 — header with no body

- L41 — header says "no outstanding deferrals". Delete the empty section.

### Story 1.6 — 16 operational/speculative chaff entries (L45-60)

Multi-line iz-cpm stderr cosmetic; TEST_RESULT < BDOS_BASE compile guard; `clean` removes only `.com`; whitespace-in-filenames; clock-skew rebuild; iz-cpm-not-on-PATH; missing-timeout(1); sentinel-in-stack; sentinel-vs-production-map; Emacs lock symlinks; missing-`cases/` cryptic error; check-toolchain duplication; wild jump into `test_fail`; sjasmplus local-label scope leak; fixture missing 0x1A; hex-print 30 unused bytes. Harness has worked across 30+ stories — archive the lot.

### Story 1.7 / 1.8 / 1.10 / 1.11 / 1.12 — defensive / speculative

- 1.7 L64 — `gapbuf_move_gap` debug ASSERT (depends on hypothetical `ASSERT_DEBUG` macro)
- 1.8 L70 — queued-Esc bypasses Esc disambiguation (real-keyboard rare)
- 1.8 L72-73 — `tick_wait_one` IFF preservation (explicitly "evaluated and still deferred")
- 1.10 L97 — `parser_dispatch` IX safety (essentially moot by 2.5 / 2.11)
- 1.10 L99 — `dispatch_visual` digits/operators binding (superseded by Stories 3.3-3.8 + Theme B "visual operators single-level" entry below)
- 1.11 L78 sloppy `top_line_offset`; L81 `render_in_run` reset; L82 per-cell `shadow_ptr` reload (all defensive/perf with no observed pressure)
- 1.12 L103 `MBB_SET_USR_INT` ignored; L105 no `LD SP` (both defensive; survived 30+ stories)

### Story 2.1 / 2.2 / 2.4 — defensive

- 2.1 L114 `init_teardown` public bypass; L117 8-bit B overflow; L118 vi-style `:q` escalation prompt
- 2.2 dev L124 BDOS_CLOSE not surfaced
- 2.2 review L135 W1 (32768-byte file rejection — own text says real-world impact zero); L136 W2 (out of CP/M 2.2 scope); L139 W4 / L142 W7 (defensive zero-fill / NUL-only invariant)
- 2.4 review L177 FCB +12..15 zeroing; L179 FCB+9 restore; L183 lex-order (intentional); L185 redundant re-stage; L189 fileio_save-roundtrip cross-call; L195 gap-half SBC underflow (depends on SR2 violation upstream)

### Story 2.5 / 2.6 / 2.10 — doc / perf / latent

- 2.5 review L224 POP/PUSH HL pairs; L226 `motion_apply_count` count=0/1; L232 CF-check defensive; L234 contract attribution; L236 AC10 scope-creep doc
- 2.6 dev L254 — `is_word_char` `OR 1` actually IS removable (~1 B savings); rest is doc
- 2.10 review L344 — `motion_find_line_start` past-EOF CF defensive (latent, pre-existing)

### Story 3.2 / 3.6 / 3.7 / 4.1 / 4.2 — defensive

- 3.2 review L449 `search_commit` fall-through; L450 `search_run` POP DE ASSERT (both "pre-existing in 3.1")
- 3.6 review L465 empty-buffer `_visual_op_char_arm` (likely closed by 4.1 AC1); L466 BLOCK `rows == 0` defensive
- 4.1 review L488 sprint-status audit-trail; L489 BC-preservation transitive; L490 LF-at-0 corner; L491 cross-gap test constructor
- 4.2 review L499 RLE bounds-check; L500 RLE structural integrity; L501 render_init seed dep; L502 welcome_active offset assertion; L503 PUSH AF/POP AF preserves A/F; L506 welcome_paint single-call; L507 magic 0,0 cursor home (all defensive-only on a static, ASSERT-pinned banner)

**Action:** PM deletes these.

---

## 3. Real dev work — ready-to-scope

Three themes recommended for new stories under Epic 4 (currently has 4.1 + 4.2 closed; epic-4-retrospective marked `optional`). Themes B / E / F / G captured below as park-able backlog.

### Theme A — CR/CRLF cursor + render handling (cross-cutting design call)

**Goal:** Decide and implement the policy for CR (0x0D) and CRLF byte handling. Three deferrals converge on the same underlying design call.

**Source deferrals:**
- 1.11 review L77 — "TAB / CR / NUL / high-bit bytes render raw, desyncing shadow vs physical screen" (the original design call).
- 2.5 review L220 — `motion_h` / `motion_l` can land cursor on CR byte; editing before CR leaves CR as phantom invisible byte on save (re-flag in CRLF-imported file context).
- 2.6 review L266 — `motion_dollar` lands cursor on CR byte in CRLF-terminated lines.

**Scope decisions needed** (surface to Ant via Implementation Questions):

- **Q-A1:** Policy — filter at render emit (Option A — recommended; CR rendered as space which is current Story 2.5 UAT-iteration-2 behaviour, extend to motions), canonicalize at load (Option B — strip CR from CRLF on `fileio_load`), or vi-style `^X` notation (Option C — full visible control-char display, biggest change).
- **Q-A2:** Cursor landing — should `motion_h` / `motion_l` / `motion_dollar` treat CR as a line boundary like LF, or skip past it transparently?
- **Q-A3:** Save semantics — preserve CRLF on save if loaded as CRLF (round-trip fidelity), or always save LF-only?

**Files touched:**
- `src/motions.asm` — extend `motion_h` / `motion_l` LF clamp to also clamp on CR (narrow fix), AND post-DEC walkback in `motion_dollar` skipping whitespace (line-ending CR specifically).
- `src/render.asm` — possibly tighten the existing `render_emit_one_row` CR-filter scope.
- (Option B only) `src/fileio.asm` — canonicalize-on-load.

**Size projection:** ~30-80 B depending on chosen policy. Option A narrow fix is cheapest (~10-15 B per motion).

**Tests required:**
- `motions_dollar-crlf-skips-cr.asm` (suggested in source deferral).
- `motions_l-clamps-at-cr-byte.asm` (h/l symmetric pair).
- `fileio_load-crlf-roundtrip.asm` if Option B chosen.

**Hardware UAT:**
- Test with a CRLF-imported `vibe.asm` fixture (PC-edit + transfer to MicroBeast SD). Confirm `l` past last printable byte doesn't land on phantom CR.

**NFR considerations:**
- NFR9: ~30-80 B against ~2060 B post-4.2 headroom — comfortable.
- NFR18: byte-identical rebuild required.

---

### Theme C — Story 4.2 test-coverage hardening (3 test additions)

**Goal:** Close the three test-coverage gaps deferred in Story 4.2's code review.

**Source deferrals** (all under "## Deferred from: code review of 4-2-welcome-screen-on-no-argument-launch (2026-05-19)"):

- L496 — **AC3 inlined-replica-only.** Test exists for `'i'` dismissal only; `Esc` / `Ctrl-L` / `:` / digit are hardware-UAT-only. Cheap follow-up: 4 more replicas covering Esc / Ctrl-L / `:` / digit, each rebinding the test's input byte. Each replica mirrors `test/cases/welcome_dismissed-on-first-key.asm:82-97`.
- L497 — **AC2 coverage limited to `.new_file` branch.** Add 3 sibling tests for load-success / file-too-large / read-error branches OR pre-poison `welcome_active=0xAA` and assert survival across the existing test. Test template: `test/cases/init_welcome-hidden-with-arg.asm:62-106`.
- L498 — **AC4 `:e empty.txt` FR6 round-trip.** Drive-B FCB scaffolding (template: `test/cases/fileio_save-empty-buffer.asm`) + fixture-stability for `test/fixtures/EMPTY.TXT` (git-tracked but `make clean`-rm'd — fresh clone needs `git checkout test/fixtures/EMPTY.TXT` before test run; OR rework the test Makefile to not clean tracked fixtures).

**Files touched:**
- Add 4-8 new files under `test/cases/` (no production-code changes).
- Possibly `test/Makefile` for the EMPTY.TXT fixture-stability fix.

**Size projection:** **0 B production-code delta.** Test-only story.

**Sentinel band:** continuation of Story 4.2's allocation; PM picks next free band.

**NFR considerations:**
- NFR9: not applicable (test-only).
- NFR18: byte-identical rebuild trivially held (no production changes).

**Note:** L498's deferral text already says "bundle with the AC2-branch-coverage additions above into a single Story 4.2 test-coverage hardening mini-story if/when it matters." This story IS that bundle.

---

### Theme D — Visual-op refactor + dead-code sweep (NFR9 hygiene pass)

**Goal:** Small code-shrink + naming cleanup. Saves ~25-40 B and tidies 3-4 known smells.

**Source deferrals:**

- 3.6 review L461 — **Three duplicated `MODE_NORMAL ; parser_clear` tails** at `src/visual.asm:920-923, 1068-1071, 1093-1096`. Refactor into `_visual_op_mode_normal_preserve_status` helper. Saves ~6-12 B. Closes brittleness flag from F-17.
- 3.6 review L462 — **Rename `visual_op_block_yank_ok` → `visual_op_yank_ok`** and move under "CHAR/LINE/BLOCK shared" group in AC11. Comment at `src/visual.asm:989-996` already justifies the cross-arm reuse; the name still reads `_block_`.
- 3.7 review L472 + 2.13 dev L425 — **`edits_indent_undo_end` dead-store cleanup.** Q6 Option B pin from Story 2.13 left this cell semantically dead (`edits_record_walk` reads `edits_indent_walk_end`, the post-walk authority, instead). 4 NORMAL-mode callsites in `src/edits.asm:1707-1711` + 1 VISUAL-mode callsite in `src/visual.asm:309-312` still write `_undo_end` for symmetry. ~5 B per site × 5 = ~25 B total + the dead DEFW cell.
- 2.6 dev L254 — **`is_word_char` final `OR 1` dead-defensive byte.** For A > 'z' the `CP 'z' + 1` already sets the needed flag (Z=0 from the failed CP test). The `OR 1` is dead. ~1 B saved.

**Files touched:**
- `src/visual.asm` — extract helper; replace 3 inline `MODE_NORMAL ; parser_clear` tails with `JP _visual_op_mode_normal_preserve_status`; rename `visual_op_block_yank_ok` → `visual_op_yank_ok` across all references; drop the `edits_indent_undo_end` write.
- `src/edits.asm` — drop the 4 NORMAL-mode `LD (edits_indent_undo_end), HL` stores + the `edits_indent_undo_end` DEFW cell.
- `src/motions.asm` — drop the `OR 1` in `is_word_char` final fall-through.
- Test renames if the yank-ok cell name is asserted by any test (grep first).

**Size projection:** **~−25 to −40 B** (negative = shrink). Healthy against NFR9 headroom.

**Tests required:**
- No new tests. Existing visual-op tests must continue passing byte-equivalent. NFR18 byte-identical rebuild confirms the dead-store cleanup didn't shift any other addressing.

**Hardware UAT:**
- None required (pure refactor; existing visual-op tests cover behaviour).

**NFR considerations:**
- NFR9: NEGATIVE delta — frees ~25-40 B for future work.
- NFR18: byte-identical rebuild required after refactor (any byte-level change should pin to the exact instructions removed/renamed).

**Caveat:** rename of `visual_op_block_yank_ok` cell could touch test cases that read it. PM should grep `grep -nE 'visual_op_block_yank_ok' src/ test/` before starting to scope the test-side impact.

---

## 4. Park-able backlog (for later epics)

**Theme B — Counted operators on visual + counted-`n`** (vi-divergence; ~30-50 B + tests). Sources: 3.2 dev L434 (counted-`n`); 3.7 review L474 (`n>` / `n<` / `nd` / `ny` / `nc` / `n~` ignored). Bundle as "operators take counts" mini-story when motivation arises.

**Theme E — Test gaps with concrete shapes** (one test-only mini-story per epic). Sources: 2.5 review L230; 2.7 review L276 + L278; 2.8 review L296 + L298; 2.9 review L312 + L314; 2.10 review L340; 2.12 review L404 + L406; 3.2 review L442-448; 3.5 review L454-457; 3.6 review L463; 4.1 review L485; 4.2 review L497-498. **Theme C above is the first slice of Theme E.**

**Theme F — Architectural follow-ups (low urgency, no current pressure).**
- W8 family — `bdos_error_pre_msg` stale-pointer invariant (2.2 review L143; 2.4 dev L164; 2.4 review L181).
- `fileio_save_walk_bytes` PUSH HL/BC stack leak across funnel-trap (2.4 review L191).
- `undo_record_delete` silent UNDO_KIND_TOO_LARGE for 257..1024 B in visual context (3.6 review L464).
- VIS_BLOCK `c` multi-region undo (3.6 review L468) — blocked on multi-region undo land.
- Iterative `render_scroll_adjust` O(N × 1840) far-jump (1.11 review L84) — real perf at large N once `G`/`gg` press it on big files.

**Theme G — Doc / spec amends.** Single batch doc-pass when convenient. Sources: 2.5 review L228 (`motions_col` zombie invariant comment); 2.6 review L272 (`motion_find_line_n` 0xFFFF sentinel doc); 2.12 review L400 + L402 (op_paste contract docs); 3.6 review L467 (AC10 spec); 4.1 review L486 + L487 (AC2/AC1 narrative); 4.2 review L505 (AC3 cursor-blink hardware-only verified). Low priority unless someone trips on one.

---

## Handoff

Themes **A**, **C**, **D** ready for `bmad-create-story`. Recommended pick order: **C first** (test-only, 0 B production-code delta, low risk), **D second** (NFR9-friendly hygiene, frees ~25-40 B), **A third** (cross-cutting design call needs Q-pin resolution).

Once stories land, archive the corresponding deferred-work entries with `**CLOSED by Story 4.x**` annotations in-place (matching existing convention).
