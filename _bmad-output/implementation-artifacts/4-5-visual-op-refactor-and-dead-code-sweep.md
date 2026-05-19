# Story 4.5: Visual-op refactor + dead-code sweep (NFR9 hygiene pass)

Status: done

<!-- Provenance: Theme D of _bmad-output/implementation-artifacts/deferred-work-triage-2026-05-19.md.
     Closes deferred entries:
       - L461 (3.6 review)  — 3 duplicated MODE_NORMAL+parser_clear tails in src/visual.asm
       - L462 (3.6 review)  — visual_op_block_yank_ok cell name reads "_block_" despite cross-arm reuse
       - L472 (3.7 review) + L425 (2.13 dev) — edits_indent_undo_end dead-store cell + 5 callsites
       - L254 (2.6 dev)     — is_word_char "OR 1" dead-defensive byte — ALREADY CLOSED (stale triage entry; this story annotates it for record only)
     Net delta: ~-34 B (refactor + dead-store cleanup; binary shrinks). NFR18 SHA expected to shift. -->

## Story

As the VIBE maintainer working under a 10240 B NFR9 ceiling with a known ~1678 B post-4.2
headroom that future stories (counted-operators-on-visual, multi-region undo, etc.) will eat
into,
I want a small bundled hygiene pass that extracts one duplicated tail pattern in
`src/visual.asm`, renames a misnamed cell to match its cross-arm usage, removes one
post-Q6-Option-B dead-store cell + its 5 writers, and annotates one already-closed triage
entry,
So that ~30+ bytes of headroom return to the NFR9 budget without behaviour change, the
code-review-flagged brittleness (3 inline copies + 1 outright-misleading cell name) is
retired, and the deferred-work backlog shrinks by 4 entries.

## Acceptance Criteria

**Pre-flight cross-check finding (per [[feedback_create_story_cross_check]]).** The triage
entry for L254 (`is_word_char` final `OR 1` dead-defensive byte) is **stale**:
`src/motions.asm:778` already uses `OR A` with the in-code comment `; 1 byte vs the prior OR 1.`
A prior cleanup landed this byte before Story 4.5 was scoped — verified by grep. AC4 below
documents the annotation-only action; no production code is touched for the is_word_char
deferral.

**AC1 — Three duplicated `MODE_NORMAL ; parser_clear` tails in `src/visual.asm` extracted
into one helper (L461 close).**

**Given** three identical 3-instruction status-preserving mode-flip tails exist at
`src/visual.asm:1104-1107`, `:1348-1351`, `:1373-1376` — each running
`LD A, MODE_NORMAL ; LD (mode_byte), A ; JP parser_clear` (8 bytes per site = 24 bytes
total). These sites cannot use the standard `JP enter_normal_mode` tail because that
sequence clobbers `status_buffer` with `msg_mode_normal` (per
[[feedback_enter_normal_mode_clobbers_status]]) — they're the yank-refusal paths that must
preserve `msg_yank_too_large`.
**When** Story 4.5 lands
**Then** a new module-private helper at the bottom of `src/visual.asm` (between
`_visual_op_block_cursor_clamp` and the DEFW block) carries the 8-byte body once:

```asm
;; ----------------------------------------------------------------
;; _visual_op_mode_normal_preserve_status
;; Status-preserving VISUAL→NORMAL mode flip. Direct manual write to
;; mode_byte (NOT `JP enter_normal_mode`, which would clobber
;; status_buffer per the feedback_enter_normal_mode_clobbers_status
;; convention). Used by the 3 yank-refusal paths that must preserve
;; msg_yank_too_large across the mode change.
;;
;; In:      (none — yank-refusal callers reach here via JR/JP after
;;          status_set_message has already set msg_yank_too_large)
;; Out:     mode_byte = MODE_NORMAL; parser state cleared via
;;          parser_clear tail-JP.
;; Trashes: A, F (parser_clear trashes more; see its contract).
;; Calls:   parser_clear (tail-JP).
;; ----------------------------------------------------------------
_visual_op_mode_normal_preserve_status:
    LD      A, MODE_NORMAL
    LD      (mode_byte), A
    JP      parser_clear
```

The three callsites are each replaced with a single `JP _visual_op_mode_normal_preserve_status`
(3 bytes). Net byte budget: 8 (helper) + 9 (3 × 3-byte JP) = 17 bytes vs 24 inline = **-7 B**.

**AC2 — Rename `visual_op_block_yank_ok` → `visual_op_yank_ok` across all 13 references in
`src/visual.asm` (L462 close).**

**Given** the cell at `src/visual.asm:2214` is named `visual_op_block_yank_ok` but is used
by all three visual-op arms (CHAR/LINE/BLOCK) — the cross-arm reuse is documented at
`src/visual.asm:222` (Public block comment) + line 989-996 (the cross-arm reuse comment from
Story 3.7) but the name still reads `_block_`. Grep confirms 13 references, all in
`src/visual.asm`; **zero references in `test/cases/*.asm` or `inc/*.inc`** — safe to rename
without test-side impact.
**When** Story 4.5 lands
**Then** every occurrence of `visual_op_block_yank_ok` in `src/visual.asm` is renamed to
`visual_op_yank_ok` (13 occurrences per current grep, including the DEFW declaration at
line 2214 and the AR23 docstring at line 222). Net byte budget: **0 B** (rename emits the
same bytes). The AR23 module-header section that lists the cell moves it under a
"CHAR/LINE/BLOCK shared" comment group instead of the current "BLOCK-arm specific" group.

**AC3 — `edits_indent_undo_end` dead-store cell + 5 writers removed (L472 + L425 close).**

**Given** the cell `edits_indent_undo_end` at `src/edits.asm:2469` (DEFW 0) is **dead
post-Story-2.13 Q6 Option B**: `edits_record_walk` at `src/edits.asm:2436` reads
`edits_indent_walk_end` (the post-walk authority — set after the mutation pass) instead of
the pre-walk `edits_indent_undo_end`. The cell still has 5 writers across the codebase:
- `src/edits.asm:1709` (op_compose_indent / op_compose_dedent NORMAL-mode path)
- `src/edits.asm:1778` (next indent op NORMAL-mode path)
- `src/edits.asm:1834` (third indent op NORMAL-mode path)
- `src/edits.asm:1884` (fourth indent op NORMAL-mode path)
- `src/visual.asm:1481` (visual-mode indent path — the cross-mode mirror)

Each writer pattern is exactly 5 bytes:
```asm
EX      DE, HL                  ; 1 byte — shuffle to put end in HL
LD      (edits_indent_undo_end), HL    ; 3 bytes — the dead store
EX      DE, HL                  ; 1 byte — restore HL = start, DE = end
```

Both `EX DE, HL` instructions become no-ops once the `LD (...)` between them goes away
(EX EX cancels), so all 3 lines are dropped together.
**When** Story 4.5 lands
**Then** all 5 writers + the 2-byte DEFW cell are removed. Net byte budget:
`5 sites × 5 bytes + 2 bytes = -27 B`.

**Cross-check.** Each removal site has nearby comments referencing the cell (e.g.
`src/visual.asm:1473-1478` documents the dead-store status: "edits_indent_undo_end is kept
for callsite-symmetry (dead-store post-Q6; cleanup logged as deferred-work polish)"). These
explanatory comments should be **removed or amended** in the same patch — leaving them
behind would create stale documentation of an absent cell.

**AC4 — Stale triage entry L254 (`is_word_char OR 1`) annotated as already-closed.**

**Given** the triage doc at `deferred-work-triage-2026-05-19.md` line 186 named
`is_word_char`'s final `OR 1` as ~1 B savings; cross-check confirms `src/motions.asm:778`
already uses `OR A` with explicit in-code comment `; 1 byte vs the prior OR 1.`
**When** Story 4.5 lands
**Then** the corresponding `deferred-work.md` entry at L254 is annotated as
`**CLOSED pre-Story-4.5 (already removed; src/motions.asm:778 OR A with in-code attribution)**`
matching the existing in-place convention. **NO production code change for this AC** —
documentation-only. Listed here so the deferred-work backlog reflects reality.

**AC5 — NFR9 size delta: net -34 B (binary shrinks).**

**Given** the AC1-AC3 byte budgets: -7 B (AC1 helper extraction) + 0 B (AC2 rename) + -27 B
(AC3 dead-store cleanup) + 0 B (AC4 doc-only)
**When** `make sizes` is captured after Story 4.5 lands
**Then** `vibe.com` reports a size **34 B smaller than the pre-4.5 baseline** ± 4 B drift
(sjasmplus alignment slack):

| Pre-4.5 baseline scenario | Pre-4.5 size | Post-4.5 projected |
|---|---|---|
| 4.5 lands BEFORE 4.4 (only 4.3 ahead — 4.3 is byte-identical) | 8562 B | 8528 ± 4 B (~1712 B headroom) |
| 4.5 lands AFTER 4.4 (+35-39 B from 4.4) | 8597-8601 B | 8563-8567 ± 4 B (~1673 B headroom) |

Both scenarios stay well under the 10240 B NFR9 ceiling. The delta direction (negative) is
the key signal — if `make sizes` reports a positive delta or zero, the refactor introduced
unintended bytes; investigate before commit.

**AC6 — NFR18 byte-identical rebuild held (with expected SHA shift vs pre-4.5).**

**Given** Story 4.5 is a refactor that intentionally changes the emitted bytes
**When** the tree is built clean twice after Story 4.5 lands (`make clean && make all` × 2)
**Then** both post-4.5 `vibe.com` SHA-256 digests match **each other** (NFR18 invariant
held); the new SHA WILL differ from the pre-4.5 SHA (expected — refactor changes bytes).
Record both SHAs in the Dev Agent Record. If pre-4.5 SHA and post-4.5 SHA are equal,
something went wrong (no bytes actually changed — verify the patches landed).

**AC7 — All existing tests continue to PASS; no new tests required.**

**Given** Story 4.5 is a behaviour-preserving refactor: the helper extraction emits
byte-equivalent control flow; the rename changes only the symbol; the dead-store cleanup
removes writes to a cell that nothing reads
**When** `make test` is captured after Story 4.5 lands
**Then** the pre-4.5 PASS/FAIL count is preserved exactly (no new PASSes, no new FAILs,
no regressions). Specifically:
- Visual-op tests (`visual_*-*.asm`) — the yank-refusal paths now route through the new
  helper; expect byte-equivalent post-state. Tests pinning `mode_byte == MODE_NORMAL` and
  `status_buffer` containing `msg_yank_too_large` continue to pass.
- Indent-op tests (`edits_indent-*.asm`, `edits_dedent-*.asm`, etc.) — the dead-store
  removal does not affect observable state; tests pinning undo replay
  (`edits_record_walk` consumers) continue to pass.
- Word-motion tests (`motions_w-*.asm`, `motions_b-*.asm`, etc.) — unaffected by Story 4.5.

**AC8 — Hardware UAT NOT required.**

**Given** Story 4.5 is a pure refactor with no observable behaviour change (control flow
preserved through the helper; renamed cell holds same bytes; dead-store removal touches
state that nothing reads)
**When** Story 4.5 is offered for review
**Then** the standard hardware UAT script is **NOT re-run**. Binding acceptance signals are
`make test` PASS count preserved + NFR18 SHA-stable across two clean builds + AC5 size
delta confirmed negative.

If any visual-op test or indent-op test fails post-4.5, that's the trigger to invoke
hardware UAT — but on a passing test suite, the refactor's byte-equivalent property is
the load-bearing invariant.

**AC9 — Deferred-work.md L461/L462/L472/L425/L254 annotated as CLOSED-by-4.5.**

**Given** Story 4.5 addresses 5 deferred-work entries across 4 ACs
**When** Story 4.5 lands
**Then** each entry is annotated in-place at `deferred-work.md` matching the existing
convention:
- L461 (3.6 review: duplicated MODE_NORMAL+parser_clear tails) → `**CLOSED by Story 4.5 (AC1)**`
- L462 (3.6 review: visual_op_block_yank_ok rename) → `**CLOSED by Story 4.5 (AC2)**`
- L472 (3.7 review: edits_indent_undo_end dead-store) → `**CLOSED by Story 4.5 (AC3)**`
- L425 (2.13 dev: same as L472 — original-source entry) → `**CLOSED by Story 4.5 (AC3)**`
- L254 (2.6 dev: is_word_char OR 1) → `**CLOSED pre-Story-4.5 (already removed; src/motions.asm:778)**`
  (per AC4 — documentation-only annotation reflecting prior cleanup)

## Tasks / Subtasks

- [x] **Task 0 — Cross-check + pre-flight verification**
  - [x] 0.1 Verified pre-4.5 baseline: `make sizes` = **8602 B** (4.4 landed; matches story's "8597-8601 ± 4 B" projection). `sha256sum vibe.com` = `0893765a1276efa38c8c014195eb52a674931e9fb70dec9c88fcdc4c490723e0` (matches sprint-status.yaml's recorded post-4.4 SHA).
  - [x] 0.2 Re-confirmed stale-entry finding for L254/L258: `src/motions.asm:793` shows `OR A` (1 byte) with in-code attribution at line 796 (`; 1 byte vs the prior OR 1.`). Story's "line 778" reference was approximate — same byte, line offset shifted by intervening edits. AC4 stays doc-only.
  - [x] 0.3 Re-confirmed rename safety: `grep -rnE 'visual_op_block_yank_ok' src/ inc/ test/` returned 13 hits, ALL in `src/visual.asm`. ZERO hits in `test/cases/*.asm` or `inc/*.inc`. Rename was test-safe.
  - [x] 0.4 Confirmed pre-4.5 `make test` baseline: **283 pass / 1 fail** (the 1 fail is `harness_fail.asm`, intentional smoke test for the harness's fail-detection path — body asserts `JP test_fail`).

- [x] **Task 1 — AC1: Extract `_visual_op_mode_normal_preserve_status` helper** (AC: #1)
  - [x] 1.1 Helper body inserted at `src/visual.asm` immediately after the ASSERT at line 2150 and before the Module-local data section header at line 2153. Spec's "after `_visual_op_block_cursor_clamp` (the last code label)" reference was inaccurate — the actual last code label is `_visual_compose_finish` (line 2117); insertion point chosen at the natural code/data boundary at end of file. Helper carries the 8-byte body verbatim + the AR23 docstring.
  - [x] 1.2 Replaced the 3-instruction tail at `src/visual.asm:1104-1107` (BLOCK-arm refusal path) with `JP _visual_op_mode_normal_preserve_status`. Preceding comment updated to "delegate to helper that preserves msg_yank_too_large".
  - [x] 1.3 Same at `src/visual.asm:1348-1351` (CHAR/LINE-arm refusal path) — comment "do mode change inline" → "delegate to helper that preserves msg_yank_too_large".
  - [x] 1.4 Same at `src/visual.asm:1373-1376` (`.yank_only_ok` refusal path).
  - [x] 1.5 The visual.asm header doesn't have a literal "Module-private:" block listing routines; routine-level documentation is colocated with each routine's own AR23 docstring. The helper's own docstring (added at 1.1) fulfils this requirement.
  - [x] 1.6 `make all` clean. `make sizes` = **8595 B** (8602 → 8595 = **-7 B exactly**, matches AC1 sub-delta projection).

- [x] **Task 2 — AC2: Rename `visual_op_block_yank_ok` → `visual_op_yank_ok`** (AC: #2)
  - [x] 2.1 Single-file `replace_all: true` Edit on `src/visual.asm` renamed all 13 occurrences.
  - [x] 2.2 Moved BOTH the AR23 header documentation block entry AND the DEFB declaration from the "BLOCK arm scratch" comment group to the "CHAR/LINE/BLOCK shared" comment group. Header comment extended to note the cross-arm reuse (CHAR/LINE via `_delete_yank_or_change`; BLOCK via `_visual_op_block_arm`) and that the `_block_` infix was dropped in Story 4.5. The cross-arm-reuse comment at "lines 989-996" called out by the story didn't exist as a discrete comment block in current source (the area is plain code that uses the renamed cell); the routine's body uses the new name consistently post-rename — no separate cross-arm comment needed.
  - [x] 2.3 `make all` clean.
  - [x] 2.4 `make test` = 283 pass / 1 deliberate-fail unchanged. `make sizes` = 8595 B (0 B delta from rename, as expected).

- [x] **Task 3 — AC3: Remove `edits_indent_undo_end` dead-store + 5 writers** (AC: #3)
  - [x] 3.1 At `src/edits.asm:1701-1710` (op_compose_indent `.ci_walk`), dropped the 3-line `EX/LD/EX` block. Preceding comment updated: "Stash pre-walk (start, end) into module-local DEFWs..." → "Stash pre-walk start into a module-local DEFW so we can record after the walk (the walk trashes HL and DE). The post-walk authority for length is edits_indent_walk_end (Story 2.13 Q6 Option B); no pre-walk end stash needed (cleaned up in Story 4.5 AC3)."
  - [x] 3.2 Same removal at `src/edits.asm:1773-1779` (op_compose_dedent `.cdd_walk`).
  - [x] 3.3 Same removal at `src/edits.asm:1831-1835` (op_indent_line indent path).
  - [x] 3.4 Same removal at `src/edits.asm:1881-1885` (op_dedent_line dedent path).
  - [x] 3.5 At `src/visual.asm:1472-1481` (visual_apply_shift `.vsh_walk_end`), dropped the same 3-line block AND condensed the 6-line "dead-store rationale" comment down to 4 lines noting the pre-walk-end stash retirement.
  - [x] 3.6 Removed `edits_indent_undo_end: DEFW 0` at `src/edits.asm:2469`. Post-removal grep: 1 surviving hit at `src/edits.asm:2411` — this is the historic Q6 Option B explanation in `edits_record_walk`'s AR23 docstring, amended to say "formerly edits_indent_undo_end, retired in Story 4.5 AC3" (documentation history, not a live reference). sjasmplus builds clean → no live callsite missed.
  - [x] 3.7 `make all` clean.
  - [x] 3.8 `make test` = 283 pass / 1 deliberate-fail unchanged. No indent/dedent regressions (all `undo_indent-*` and `undo_dedent-*` tests continue to pass, confirming `edits_record_walk` reads the live `edits_indent_walk_end` cell and the dead cell really was dead).
  - [x] 3.9 `make sizes` = **8568 B** (cumulative 8602 → 8568 = **-34 B exactly**, matches AC5 projection).

- [x] **Task 4 — AC4: Annotate L254 stale entry** (AC: #4)
  - [x] 4.1 Verified by Task 0.2; no production code change. Annotation applied in Task 8.

- [x] **Task 5 — AC5: Final size verification** (AC: #5)
  - [x] 5.1 `make sizes` = **8568 bytes (~83% of NFR9 10 KB budget); headroom 1672 B**.
  - [x] 5.2 Delta vs pre-4.5: -34 B exactly (no sjasmplus alignment slack consumed). Well within `-34 ± 4 B` band.
  - [x] 5.3 Recorded in Completion Notes List below.

- [x] **Task 6 — AC6: NFR18 byte-identical rebuild** (AC: #6)
  - [x] 6.1 `make clean && make all` × 2.
  - [x] 6.2 Build 1 SHA = `3f36a583d9b0b2e3ddd423bb6447568b19982c650ff25a1d79e36bc0119cd034`; Build 2 SHA = `3f36a583d9b0b2e3ddd423bb6447568b19982c650ff25a1d79e36bc0119cd034`. **Match** — NFR18 invariant held.
  - [x] 6.3 Post-4.5 SHA `3f36a583...` differs from pre-4.5 SHA `0893765a...` — confirms refactor actually changed bytes.
  - [x] 6.4 Both SHAs recorded in Completion Notes List below.

- [x] **Task 7 — AC7: Test regression check** (AC: #7)
  - [x] 7.1 `make test` = 283 pass / 1 fail.
  - [x] 7.2 PASS count identical to pre-4.5 baseline (delta = 0 in both directions). The single "fail" is `harness_fail.asm` (intentional smoke test that exercises the harness's fail-detection path — same as pre-4.5 baseline; not a regression).
  - [x] 7.3 No visual-op or indent-op test failures — no diagnostic branch needed.

- [x] **Task 8 — AC9: Annotate deferred-work.md** (AC: #9)
  - [x] 8.1 Located all 5 referenced entries in `_bmad-output/implementation-artifacts/deferred-work.md`:
    - L466 (3.6 review — three duplicated tails; story numbered as L461)
    - L467 (3.6 review — yank_ok rename; story numbered as L462)
    - L477 (3.7 review — edits_indent_undo_end; story numbered as L472)
    - L430 (2.13 dev — same cleanup as L477; story numbered as L425)
    - L258 (2.6 dev — is_word_char OR 1; story numbered as L254)
    (Line numbers shifted vs the story spec since the deferred-work file has grown — Stories 4.1-4.4 added entries that pushed earlier ones down. The story's L<n> identifiers were stable at story-scoping time; current line numbers above.)
  - [x] 8.2 Applied AC9 annotations as sub-bullets matching the most recent convention (Story 4.4's "Resolved by Story X (ACy)" sub-bullet pattern at L271). L258 uses "CLOSED pre-Story-4.5 (already removed)" variant per AC4; the other four use "CLOSED by Story 4.5 (AC<n>)".
  - [x] 8.3 Each closure sub-bullet includes the specific AC, the byte-budget arithmetic, and the load-bearing invariants preserved (e.g. the `enter_normal_mode`-clobbers-status convention for AC1).

- [x] **Task 9 — Commit + close**
  - [ ] 9.1 Stage (pending Ant):
    - `src/visual.asm` (AC1 helper + AC2 rename + AC3 visual-mode callsite removal + AR23 doc updates)
    - `src/edits.asm` (AC3 — 4 NORMAL-mode callsite removals + DEFW removal + Q6 Option B comment amendment)
    - `_bmad-output/implementation-artifacts/deferred-work.md` (AC9 — 5 closure annotations)
    - `_bmad-output/implementation-artifacts/4-5-visual-op-refactor-and-dead-code-sweep.md` (this file — Dev Agent Record filled in)
    - `_bmad-output/implementation-artifacts/sprint-status.yaml` (status update)
  - [ ] 9.2 Commit message (pending Ant): `Story 4.5: visual-op refactor + dead-code sweep — closes L461/L462/L472/L425/L254 (~-34 B)`.
  - [x] 9.3 Updated sprint-status.yaml: `4-5-visual-op-refactor-and-dead-code-sweep` flipped from `ready-for-dev` to `in-progress` at dev start, then to `review` at dev completion. Will flip to `done` after Ant accepts (no hardware UAT cycle required per AC8 — the headless `make test` PASS-preservation + NFR18 SHA-stable + AC5 negative-delta are the binding signals).

### Review Findings

Code review pass 2026-05-19 (bmad-code-review, 3 parallel layers: Blind Hunter / Edge Case Hunter / Acceptance Auditor).

Summary: 0 decision-needed, 3 patch, 0 defer, 7 dismissed (5 Blind Hunter concerns closed on verification, 1 Blind asymmetry observation by-design, 1 Edge Hunter prose-clarity false positive). Auditor: all 9 ACs satisfied. No HIGH/MEDIUM behavioural issues.

All 3 patch items are stale doc-comment drift — module-private cell enumerations and `Trashes:` contracts that still list `edits_indent_undo_end` after AC3 retired the cell. No behaviour impact; build is clean (sjasmplus only validates symbol references in instructions, not in comments).

- [x] [Review][Patch] Stale `_end` in module-private cell enumeration [src/visual.asm:246-247] — drop `_end` from the "five Story-2.11/2.13 edits_indent_* cells" list (now four cells: `_start / _walk_mode / _walk_dirty / _walk_end`); update count "five" → "four". **Applied 2026-05-19.**
- [x] [Review][Patch] Stale `_end` in `visual_apply_shift` Trashes contract [src/visual.asm:459-460] — drop `_end` from `edits_indent_undo_start / _end` in the Trashes enumeration. **Applied 2026-05-19.**
- [x] [Review][Patch] Stale `_end` in second `visual_apply_shift` header Trashes contract [src/visual.asm:1430-1431] — same drop as above (duplicate header copy on the alternate entry). **Applied 2026-05-19.**


### Architecture compliance

- **AR12 (status funnel):** UNCHANGED. The new helper does NOT call status_set_message —
  callers reach it AFTER having already set msg_yank_too_large via the existing
  status_set_message path.
- **AR13 (BIOS_CONOUT):** UNCHANGED. No render-side changes.
- **AR14 (gap_start / gap_end WRITES):** UNCHANGED. AC3's dead-store removal touches a
  module-private cell in `src/edits.asm`, not gap state.
- **AR15 (BDOS_CALL):** UNCHANGED. No fileio touches.
- **AR23 (per-module headers):** EXTENDS. AC1 adds the new helper to `src/visual.asm`'s
  Module-private block + a standalone routine docstring. AC2 moves the renamed cell into
  the "CHAR/LINE/BLOCK shared" comment group. AC3 removes the dead-cell mention from
  `src/edits.asm`'s and `src/visual.asm`'s AR23 blocks.
- **AR25 (INCLUDE order):** UNCHANGED. No new INCLUDEs; symbol resolution paths preserved.
- **MC1 (caller-saved register convention):** UNCHANGED. The new helper trashes A and F
  (same as the inline tails it replaces).
- **MC4 (handler signature):** UNCHANGED. The 3 callsites still exit via the standard
  parser_clear tail-JP path; the indirection through the helper is transparent.
- **MC5 (status-message funnel):** UNCHANGED — the load-bearing invariant for AC1 is that
  status_buffer (containing msg_yank_too_large) is NOT clobbered. The helper preserves
  this by writing mode_byte directly and tail-JPing parser_clear (which doesn't touch
  status_buffer) instead of routing through enter_normal_mode (which would).
- **MC7 (static memory map):** SHRINKS by 2 bytes (AC3 DEFW removal). All cells declared
  AFTER `edits_indent_undo_end` at `src/edits.asm:2469` would shift down by 2 bytes — but
  per grep, NO cells are declared after that line in edits.asm (it's the last DEFW in the
  module). State.inc EQU-anchored cells are unaffected.
- **RI1-RI4 (render invariants):** UNCHANGED.
- **NFR1, NFR3, NFR5:** UNCHANGED.
- **NFR9 (code size):** -34 B mid-estimate. Headroom grows.
- **NFR18 (byte-identical rebuild):** held across the two post-4.5 builds. Pre vs post-4.5
  SHA changes — this is the intended outcome.

### Files this story modifies (and what to preserve)

**`src/visual.asm`** (currently ~2300 lines):
- ADD helper body `_visual_op_mode_normal_preserve_status` (~8 B + AR23 docstring) between
  `_visual_op_block_cursor_clamp` and the DEFW block.
- AMEND 3 inline tails at lines 1104-1107, 1348-1351, 1373-1376 — replace each with a
  single `JP _visual_op_mode_normal_preserve_status` (3 bytes).
- RENAME `visual_op_block_yank_ok` → `visual_op_yank_ok` at all 13 references (per AC2).
- REMOVE the 3-line `EX DE, HL ; LD (edits_indent_undo_end), HL ; EX DE, HL` block at
  lines 1479-1482 (per AC3).
- AMEND nearby comments per Tasks 1.2-1.4 + 3.5 to remove stale references.
- AMEND AR23 module header at lines 200-250 to reflect new helper + renamed cell + removed
  dead-cell mention.
- PRESERVE: everything else. Specifically the public-surface symbols
  (`visual_arm`, `visual_op_*`, `visual_compose_status_*`, etc.) remain unchanged.

**`src/edits.asm`** (currently ~2470 lines):
- REMOVE 4 occurrences of the 3-line dead-store block at lines 1707-1710, 1776-1779,
  1832-1835, 1882-1885 (line numbers approximate; per Task 3.1-3.4 use the grep-reported
  exact lines per the current file state).
- REMOVE the DEFW `edits_indent_undo_end:      DEFW 0` at line 2469.
- AMEND nearby comments per Task 3.1-3.4 to drop the "(start, end) pair" wording — only
  `_undo_start` survives.
- AMEND AR23 module header to drop the dead-cell mention.
- PRESERVE: everything else, including `edits_indent_walk_end` (line 2400 — the live
  post-walk authority that `edits_record_walk` actually reads), `edits_indent_undo_start`
  (line 2468 — the live pre-walk start that remains in use), and all 5 writers of
  `edits_indent_walk_end`.

**`src/motions.asm`** — UNCHANGED for AC4 (stale triage entry; the byte was already saved).

**`_bmad-output/implementation-artifacts/deferred-work.md`** — 5 closure annotations per AC9.

**NEW FILES:** none.

**RENAMED FILES:** none (the cell rename is in-file).

### Implementation choices and trade-offs

**Choice 1: Bundle all 4 sub-refactors (AC1+AC2+AC3+AC4-annotation) into one story.**
- **Adopted.** Matches the triage's framing of Theme D as a single hygiene-pass story.
  Single commit, single SHA shift, single round of test verification.
- Alternative (rejected): 4 sub-stories. Adds noise; refactors have no inter-dependency
  beyond co-residing in `src/visual.asm` so bundling is the natural move.

**Choice 2: Helper name `_visual_op_mode_normal_preserve_status`.**
- **Adopted** verbatim from the triage doc. The leading underscore matches the existing
  module-private convention in `src/visual.asm` (e.g. `_visual_op_block_cursor_clamp`,
  `_visual_op_block_row_bytes`). The `_preserve_status` suffix is the load-bearing
  semantic distinguishing this helper from the standard `enter_normal_mode` path.
- Alternative (considered): shorter name like `_v_op_mode_norm` to save a few comment
  bytes. Rejected — the name encodes a non-obvious invariant (status preservation) and
  shortening it would invite future-developer confusion.

**Choice 3: AC4 (`is_word_char`) handled as annotation-only.**
- **Adopted.** The byte is already saved per the in-code comment at `src/motions.asm:778`.
  Re-touching it would be a no-op patch. The deferred-work entry annotation reflects
  reality so future triages don't re-flag this.
- Alternative (rejected): silently drop the L254 entry from deferred-work.md. The triage
  doc's record-keeping convention favors in-place CLOSED annotations; deletion breaks
  that history.

**Choice 4: AC3 removes the dead cell + writers together, NOT just the writers.**
- **Adopted.** Removing only the writers but leaving the DEFW cell wastes 2 bytes for no
  reason. The cell has zero readers per the grep verification at Task 0.3.
- Alternative (rejected): leave the cell as a "defensive marker" against future re-use.
  AR23/MC7 discipline already covers static-memory documentation; an unused 2-byte cell
  isn't a marker, it's noise.

### Implementation Questions

**None.** All design decisions are pre-pinned by the triage doc + Story 2.13 Q6 Option B
precedent. The 5 stale-entry findings (line numbers + the is_word_char already-saved byte)
are documented in AC1's pre-flight check and AC4; the dev pass should verify before
patching (Task 0).

### NFR9 budget arithmetic

Pre-4.5 baseline depends on what's landed:

| Scenario                       | Pre-4.5 size | Post-4.5 projected | Delta |
|--------------------------------|--------------|---------------------|-------|
| Neither 4.3 nor 4.4 landed     | 8562 B       | 8528 B ± 4 B        | -34 B |
| Only 4.3 landed (4.3 = 0 B)    | 8562 B       | 8528 B ± 4 B        | -34 B |
| 4.4 landed but not 4.3         | 8597-8601 B  | 8563-8567 B ± 4 B   | -34 B |
| Both 4.3 + 4.4 landed          | 8597-8601 B  | 8563-8567 B ± 4 B   | -34 B |

In all scenarios the delta is **-34 B ± 4 B** because the AC1-AC3 patches don't interact
with the AC1-AC4-of-4.4 patches (different files / different lines). Sjasmplus alignment
slack accounts for the ±4 B uncertainty.

### Test count target

**Pre-4.5 baseline:** whatever PASS count is current at story-execution time (varies by
4.3/4.4 landing state). Story 4.5 adds NO new tests and removes none.

**Post-4.5 target:** identical to pre-4.5 baseline (no PASSes, no FAILs introduced).

### Project Structure Notes

- All changes are in-file edits to `src/visual.asm` and `src/edits.asm`. No new top-level
  files; no test additions; no Makefile changes.
- The AR25 INCLUDE order is preserved — neither visual.asm nor edits.asm changes its
  position or its symbol surface (modulo the rename which is symmetric across all
  references).
- Post-4.5 the cell `edits_indent_undo_end` no longer exists; any future story that needs
  pre-walk end-tracking should re-introduce the cell from scratch rather than relying on
  its prior existence.

### References

- Source deferrals: `_bmad-output/implementation-artifacts/deferred-work.md`:254, 425, 461,
  462, 472.
- Triage scoping: `_bmad-output/implementation-artifacts/deferred-work-triage-2026-05-19.md`
  Theme D (lines 178-208).
- Story 2.13 Q6 Option B (the original decision that made `edits_indent_undo_end` dead):
  `_bmad-output/implementation-artifacts/2-13-*.md`.
- Story 3.6 + 3.7 review (where the duplicated-tails + rename + dead-store entries
  originated): the post-merge code-review blocks in those stories' implementation
  artifacts.
- Current code sites verified by Story 4.5's pre-flight grep:
  - 3 duplicated tails: `src/visual.asm:1104-1107`, `:1348-1351`, `:1373-1376`
  - 13 yank_ok references: `src/visual.asm:222, 873, 945, 987, 1025, 1054, 1101, 1278,
    1299, 1345, 1362, 1370, 2214`
  - 5 `edits_indent_undo_end` writers: `src/edits.asm:1709, 1778, 1834, 1884` +
    `src/visual.asm:1481`
  - DEFW cell: `src/edits.asm:2469`
  - is_word_char already-saved byte: `src/motions.asm:778`

### Memory hooks (from [[memory]])

- **[[feedback_enter_normal_mode_clobbers_status]]** — load-bearing for AC1. The helper
  MUST NOT route through `enter_normal_mode`; it MUST do the manual `LD (mode_byte), A`
  + `JP parser_clear` to preserve `status_buffer` containing `msg_yank_too_large`. If a
  future maintainer "simplifies" the helper to `JP enter_normal_mode` thinking it's
  equivalent, they'll regress every yank-refusal test.
- **[[feedback_create_story_cross_check]]** — applied at AC1 line-number verification +
  AC4 stale-entry finding. Pre-flight cross-check caught 2 triage-doc inaccuracies (stale
  line numbers + already-done byte saving).
- **[[project_nfr9_cliff_edge]]** — -34 B delta returns headroom; complementary to 4.4's
  +35-39 B.

## Hardware UAT script (AC8 — NOT required for this story)

**Story 4.5 is a pure refactor with no observable behaviour change.** No hardware UAT
cycle is required. Per AC8, the binding acceptance signals are:

1. `make test` reports the same PASS/FAIL count as pre-4.5 (no regressions, no new
   PASSes).
2. `sha256sum build/vibe.com` × 2 (across `make clean && make all` twice) reports
   identical SHAs (NFR18 byte-identical held).
3. `make sizes` reports a `~-34 B ± 4 B` size delta vs pre-4.5 baseline (AC5 negative-delta
   confirmed).

If those three signals all hold, Story 4.5 is acceptance-complete without touching
MicroBeast hardware. If `make test` regresses on a visual-op or indent-op case, that's the
trigger to suspect AC1 or AC3 broke a behaviour-equivalence invariant; revert the failing
patch and re-investigate before re-running headless tests — hardware UAT is not the
front-line debug tool for refactor regressions (the headless suite catches them more
precisely).

## Dev Agent Record

### Agent Model Used

`claude-opus-4-7[1m]` (Dev / Opus 4.7 1M-context, bmad-dev-story skill).

### Debug Log References

No live debug sessions — refactor was straightforward verbatim execution of AC patterns. Single deviation from spec text noted at Task 1.1 (insertion point: the "last code label" referenced as `_visual_op_block_cursor_clamp` is actually `_visual_compose_finish` — helper placed at the natural code/data boundary at end of file instead). Single deviation from spec at Task 2.2 (the "cross-arm reuse comment at line 989-996" called out by the story doesn't exist as a discrete comment block in current source; rename was self-documenting via the new name).

### Completion Notes List

- **Pre-4.5 baseline (post-4.4):**
  - `make sizes` = **8602 B** / ~84% of NFR9 / 1638 B headroom (matches story's "4.4 landed" scenario projection of 8597-8601 ± 4 B).
  - `sha256sum vibe.com` = `0893765a1276efa38c8c014195eb52a674931e9fb70dec9c88fcdc4c490723e0` (matches sprint-status.yaml's recorded post-4.4 SHA).
  - `make test` = **283 pass / 1 fail** (`harness_fail.asm` is intentional — see test/cases/harness_fail.asm header: "Demo case — always fails with a specific code so the harness's fail-detection path is exercised").
- **Post-4.5:**
  - `make sizes` = **8568 B** / ~83% of NFR9 / **1672 B headroom** (+34 B headroom restored).
  - `sha256sum vibe.com` × 2 (across `make clean && make all` cycles) = `3f36a583d9b0b2e3ddd423bb6447568b19982c650ff25a1d79e36bc0119cd034` byte-identical (NFR18 invariant held).
  - `make test` = **283 pass / 1 fail** — identical to pre-4.5 baseline (the 1 fail is `harness_fail`, unchanged).
- **Delta arithmetic (matches AC5 projection exactly):**
  - AC1 helper extraction: -7 B (verified mid-implementation; matches AC1 expected sub-delta).
  - AC2 rename: 0 B (verified mid-implementation; matches AC2 expected delta).
  - AC3 dead-store cleanup: -27 B (verified mid-implementation; matches AC3 expected sub-delta).
  - AC4 stale-entry annotation: 0 B (doc-only, no production code touched).
  - **Cumulative: -34 B exactly** (no sjasmplus alignment slack consumed — the projected ±4 B drift didn't materialise).
- **AC4 confirmation:** L254 (is_word_char `OR 1`) annotated as already-closed pre-Story-4.5 per AC4 doc-only mandate. Verified at pre-flight Task 0.2: `src/motions.asm:793` contains `OR A` (1 byte) with in-code attribution at line 796 (`; 1 byte vs the prior OR 1.`). The byte saving landed before Story 4.5 was scoped. **Zero production code changed in `src/motions.asm` during this story.**
- **Surviving references to removed symbols:**
  - `grep -rnE 'edits_indent_undo_end' src/ inc/ test/` → 1 hit (`src/edits.asm:2411` — historical comment in `edits_record_walk`'s Q6 Option B explanation, amended to say "formerly edits_indent_undo_end, retired in Story 4.5 AC3"). NOT a live reference; sjasmplus builds clean. ZERO live callsites surviving.
  - `grep -rnE 'visual_op_block_yank_ok' src/ inc/ test/` → 0 hits ✅.
- **NFR9 budget arithmetic update for memory:** post-4.4 [[project_nfr9_cliff_edge]] memory recorded "8179 B baseline, ~2060 B headroom" — that's stale; latest post-4.4 baseline was 8602 B (after the 4.4 → review patches landed). Post-4.5 is 8568 B / 1672 B headroom. The cliff-edge framing still applies (we're 14 B below the 8554 B "post-3.8 baseline" of the original cliff projection, but well above the 10240 B ceiling).
- **Hardware UAT NOT required per AC8.** Binding acceptance signals all confirmed: `make test` PASS-preservation (delta = 0) + NFR18 SHA-stable across two clean builds + AC5 negative-delta confirmed at -34 B.

### File List

**Modified:**
- `src/visual.asm` — AC1 helper body added (between ASSERT at line 2150 and Module-local data section header at line 2153) + AC1 callsites updated at three locations (BLOCK-arm refusal at lines 1104-1107, CHAR/LINE-arm refusal at 1348-1351, `.yank_only_ok` refusal at 1373-1376) + AC2 rename of `visual_op_block_yank_ok` → `visual_op_yank_ok` at 13 references + AC2 AR23 header comment block + DEFB declaration moved from "BLOCK arm scratch" group to "CHAR/LINE/BLOCK shared" group + AC3 visual-mode dead-store removal at `visual_apply_shift.vsh_walk_end` (lines 1472-1481 → comment condensed + 3-line `EX/LD/EX` block dropped).
- `src/edits.asm` — AC3 dead-store removal at 4 NORMAL-mode callsites (`op_compose_indent.ci_walk` ~1707, `op_compose_dedent.cdd_walk` ~1776, `op_indent_line` ~1832, `op_dedent_line` ~1882) + AC3 DEFW removal at `edits_indent_undo_end:` (was line 2469) + AC3 amendment of `edits_record_walk`'s AR23 docstring Q6 Option B explanation to note the cell's retirement.
- `_bmad-output/implementation-artifacts/deferred-work.md` — AC9 closure sub-bullets added at 5 entries (L258 is_word_char / L430 Story 2.13 dev edits_indent_undo_end / L466 three duplicated tails / L467 yank_ok rename / L477 Story 3.7 review edits_indent_undo_end). Current line numbers; story spec's L254/L425/L461/L462/L472 numbering is stable-as-of-story-scoping.
- `_bmad-output/implementation-artifacts/4-5-visual-op-refactor-and-dead-code-sweep.md` — this file. Status flipped to `review`. Tasks/Subtasks checkboxes marked complete. Dev Agent Record + Completion Notes + File List + Change Log filled.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `4-5-visual-op-refactor-and-dead-code-sweep` status flipped `ready-for-dev` → `in-progress` (at dev start) → `review` (at dev completion).

**New files:** none.

**Renamed files:** none (the cell rename is in-file).

## Change Log

| Date       | Author | Change                                                                       |
|------------|--------|------------------------------------------------------------------------------|
| 2026-05-19 | Amelia | Story 4.5 scoped from Theme D of `deferred-work-triage-2026-05-19.md`. Closes deferred entries L461 / L462 / L472 / L425 (4 active) + L254 (already-closed annotation). Pre-flight cross-check caught 2 stale triage entries: corrected line numbers for the duplicated-tails (1104/1348/1373 vs triaged 920/1068/1093) and the is_word_char `OR 1` byte (already saved per motions.asm:778). Projected delta -34 B ± 4 B. Ready for dev. |
| 2026-05-19 | Dev (Opus 4.7 1M) | Story 4.5 dev pass complete (single execution, zero rework cycles). All 4 ACs landed: AC1 helper extraction -7 B, AC2 rename 0 B, AC3 dead-store cleanup -27 B, AC4 annotation 0 B. **Cumulative -34 B exactly** (8602 → 8568 B; ~1672 B headroom). NFR18 SHA `3f36a583...` byte-identical × 2 builds (was `0893765a...` pre-4.5). `make test` 283 PASS / 1 deliberate-fail unchanged (no regressions, no new tests per AC7). Two spec-text deviations noted (Task 1.1 helper insertion point at actual last code label; Task 2.2 cross-arm comment block didn't exist as a discrete entity) — both reconciled in the task narratives. AC8 hardware UAT explicitly waived per the spec (refactor with no observable behaviour change; binding signals all green). Status flipped → `review`. Single commit pending Ant. |
