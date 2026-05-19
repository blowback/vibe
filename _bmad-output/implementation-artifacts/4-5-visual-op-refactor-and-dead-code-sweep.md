# Story 4.5: Visual-op refactor + dead-code sweep (NFR9 hygiene pass)

Status: ready-for-dev

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

- [ ] **Task 0 — Cross-check + pre-flight verification**
  - [ ] 0.1 Verify pre-4.5 baseline: `make sizes` reports the binding size; `sha256sum
    build/vibe.com` recorded as the pre-4.5 reference SHA. If 4.4 has landed, expect
    ~8597-8601 B; if only 4.3 has landed (byte-identical to 4.2), expect 8562 B; if
    neither, expect 8562 B.
  - [ ] 0.2 Re-confirm the stale-entry finding for L254: read `src/motions.asm:778` and
    verify it shows `OR A` (1 byte) with the in-code attribution comment. If for any
    reason the byte is still `OR 1`, escalate to Ant — the cross-check finding was wrong
    and AC4 needs to switch from doc-only to a real production-code patch.
  - [ ] 0.3 Re-confirm rename safety for AC2: `grep -rnE 'visual_op_block_yank_ok' src/ inc/ test/ _bmad-output/`
    — expect ALL hits inside `src/visual.asm` (13 lines per current state); hits in
    `_bmad-output/` (story docs, deferred-work entries) are documentation references and
    do not block the rename. ZERO hits in `test/cases/*.asm` or `inc/*.inc` is the
    rename-safe signal.
  - [ ] 0.4 Confirm pre-4.5 `make test` baseline; record the PASS count (varies by which
    of 4.3 / 4.4 has landed).

- [ ] **Task 1 — AC1: Extract `_visual_op_mode_normal_preserve_status` helper** (AC: #1)
  - [ ] 1.1 Add the helper body at the bottom of `src/visual.asm` (between
    `_visual_op_block_cursor_clamp` — the last code label — and the DEFW block starting
    around line 2200). Use the AC1 hook pattern verbatim, including the AR23 docstring.
  - [ ] 1.2 At `src/visual.asm:1104-1107` (the BLOCK-arm refusal path), replace the
    3-instruction inline tail with `JP _visual_op_mode_normal_preserve_status`. Update
    the immediately-preceding comment at line 1104 from "do mode-write inline" to
    "delegate to helper".
  - [ ] 1.3 Same at `src/visual.asm:1348-1351` (CHAR/LINE-arm refusal path).
  - [ ] 1.4 Same at `src/visual.asm:1373-1376` (third arm — confirm which by reading the
    surrounding code, but the pattern is identical).
  - [ ] 1.5 Add the helper to the AR23 `Module-private:` block in the file header
    (around line 200-250 — same area as the cell list).
  - [ ] 1.6 `make all` → verify clean assembly. `make sizes` → expect ~-7 B delta vs
    pre-4.5 baseline (the AC5 expected sub-delta; sjasmplus alignment may shift by ±2 B).

- [ ] **Task 2 — AC2: Rename `visual_op_block_yank_ok` → `visual_op_yank_ok`** (AC: #2)
  - [ ] 2.1 In `src/visual.asm`, replace every `visual_op_block_yank_ok` with
    `visual_op_yank_ok`. Use a single-file Edit with `replace_all: true` to be safe; the
    name is distinctive enough to not collide.
  - [ ] 2.2 Update the AR23 `Module-private:` block (around line 222) — move the cell from
    its current "BLOCK-arm specific" comment group to a "CHAR/LINE/BLOCK shared" group.
    The existing cross-arm reuse comment at line 989-996 should be lightly amended to
    name the new cell.
  - [ ] 2.3 `make all` → verify clean assembly with the renamed cell.
  - [ ] 2.4 `make test` → verify NO test failures (confirms no test/cases/ file
    references the old name via assertion).

- [ ] **Task 3 — AC3: Remove `edits_indent_undo_end` dead-store + 5 writers** (AC: #3)
  - [ ] 3.1 At `src/edits.asm:1707-1710`, remove the 3-line block
    (`EX DE, HL ; LD (edits_indent_undo_end), HL ; EX DE, HL`). The `LD (edits_indent_undo_start), HL`
    at line 1707 stays; the 3 lines that follow it (1708-1710) are dropped together.
    Update the preceding comment at line 1705-1706 to remove the "(start, end) pair" wording —
    only `_undo_start` survives.
  - [ ] 3.2 Same removal pattern at `src/edits.asm:1778` (next indent op).
  - [ ] 3.3 Same removal pattern at `src/edits.asm:1834` (third indent op).
  - [ ] 3.4 Same removal pattern at `src/edits.asm:1884` (fourth indent op).
  - [ ] 3.5 At `src/visual.asm:1479-1482`, remove the same 3-line block (the visual-mode
    mirror). Update the surrounding comment at `src/visual.asm:1473-1478` to drop the
    "edits_indent_undo_end is kept for callsite-symmetry" sentence; replace with a one-line
    note that the cell was removed in Story 4.5.
  - [ ] 3.6 At `src/edits.asm:2469`, remove the DEFW declaration
    `edits_indent_undo_end:      DEFW 0`. Confirm via grep that no other reference to the
    symbol survives (`grep -rnE 'edits_indent_undo_end' src/ inc/ test/`) — expect ZERO
    hits post-removal. If non-zero, a callsite was missed.
  - [ ] 3.7 `make all` → verify clean assembly (sjasmplus would error on an undefined
    symbol if any callsite was missed).
  - [ ] 3.8 `make test` → verify NO test failures (the dead-store removal must not
    surface a previously-masked bug in `edits_record_walk` — if it does, escalate
    immediately because that would mean the cell wasn't actually dead).
  - [ ] 3.9 `make sizes` → expect cumulative delta vs pre-4.5 of ~-34 B (AC1 -7 + AC3 -27).

- [ ] **Task 4 — AC4: Annotate L254 stale entry** (AC: #4)
  - [ ] 4.1 Verified by Task 0.2; no production code change.

- [ ] **Task 5 — AC5: Final size verification** (AC: #5)
  - [ ] 5.1 `make sizes` → capture final `vibe.com` size + percentage + headroom.
  - [ ] 5.2 Confirm delta vs pre-4.5 baseline is within `-34 ± 4 B` (negative, with
    sjasmplus alignment slack). If positive or smaller absolute delta than -30 B,
    investigate before commit.
  - [ ] 5.3 Record in Dev Agent Record / Completion Notes List.

- [ ] **Task 6 — AC6: NFR18 byte-identical rebuild** (AC: #6)
  - [ ] 6.1 `make clean && make all` × 2; capture `vibe.com` SHA-256 both times.
  - [ ] 6.2 Verify the two post-4.5 SHAs match each other.
  - [ ] 6.3 Verify the post-4.5 SHA DIFFERS from the pre-4.5 baseline SHA (confirms the
    refactor actually changed bytes — if equal, no patches landed).
  - [ ] 6.4 Record both pre and post SHAs in Completion Notes for regression reference.

- [ ] **Task 7 — AC7: Test regression check** (AC: #7)
  - [ ] 7.1 `make test` → capture per-case PASS/FAIL summary.
  - [ ] 7.2 Confirm PASS count is identical to pre-4.5 baseline (delta = 0 in both
    directions).
  - [ ] 7.3 If any visual-op or indent-op test fails, diagnose:
    - Visual-op fail → AC1 helper extraction broken. Check that the helper body matches
      the original 3-instruction sequence exactly (`LD A, MODE_NORMAL ; LD (mode_byte),
      A ; JP parser_clear`) and that each `JP _visual_op_mode_normal_preserve_status`
      replaces the full 3-instruction tail (not partial).
    - Indent-op fail → AC3 dead-store removal accidentally hit a live store. Re-grep
      `edits_indent_undo_end` against the source tree to ensure ZERO surviving references;
      if there was a reader somewhere not previously identified, the cell wasn't actually
      dead — escalate and revert AC3.
    - Yank-refusal fail (status_buffer == msg_mode_normal post-yank-too-large) → AC1
      helper accidentally calls `enter_normal_mode` instead of doing the manual write +
      `JP parser_clear`. Per [[feedback_enter_normal_mode_clobbers_status]], this is the
      classic trap.

- [ ] **Task 8 — AC9: Annotate deferred-work.md** (AC: #9)
  - [ ] 8.1 In `_bmad-output/implementation-artifacts/deferred-work.md`, locate the 5
    referenced entries:
    - L461 (3.6 review — duplicated tails)
    - L462 (3.6 review — yank_ok rename)
    - L472 (3.7 review — edits_indent_undo_end)
    - L425 (2.13 dev — same as L472)
    - L254 (2.6 dev — is_word_char OR 1)
  - [ ] 8.2 Apply the AC9 annotations matching the existing in-place convention. L254
    uses the "CLOSED pre-Story-4.5" variant per AC4; the other four use "CLOSED by
    Story 4.5 (AC<n>)".
  - [ ] 8.3 Single-line shape per closure: `**CLOSED by Story 4.5 (AC<n>)**: net ~-34 B
    delta from helper extraction + dead-store cleanup. 0 B production-code change for L254
    (already removed pre-4.5).`

- [ ] **Task 9 — Commit + close**
  - [ ] 9.1 Stage:
    - `src/visual.asm` (AC1 helper + AC2 rename + AC3 visual-mode callsite removal + AR23 doc updates)
    - `src/edits.asm` (AC3 — 4 NORMAL-mode callsite removals + DEFW removal)
    - `_bmad-output/implementation-artifacts/deferred-work.md` (AC9 — 5 closure annotations)
    - `_bmad-output/implementation-artifacts/4-5-visual-op-refactor-and-dead-code-sweep.md` (this file — Dev Agent Record filled in)
    - `_bmad-output/implementation-artifacts/sprint-status.yaml` (status update)
  - [ ] 9.2 Commit message: `Story 4.5: visual-op refactor + dead-code sweep — closes
    L461/L462/L472/L425/L254 (~-34 B)`.
  - [ ] 9.3 Update sprint-status.yaml: `4-5-visual-op-refactor-and-dead-code-sweep` from
    `ready-for-dev` to `review` post-dev; to `done` after Ant accepts (no hardware UAT
    cycle required per AC8 — the headless `make test` PASS-preservation + NFR18 SHA-stable
    + AC5 negative-delta are the binding signals).

## Dev Notes

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

(to be filled in by dev pass — e.g. `claude-opus-4-7[1m]`)

### Debug Log References

(to be filled in by dev pass)

### Completion Notes List

(to be filled in by dev pass; required entries:)
- Pre-4.5 `vibe.com` SHA-256 (the reference SHA the post-4.5 SHA WILL differ from)
- Post-4.5 `vibe.com` SHA-256 × 2 (must match each other — NFR18 invariant)
- `make sizes` pre and post (expected delta: -34 B ± 4 B)
- `make test` PASS/FAIL count pre and post (expected delta: 0 in both directions)
- Confirmation that AC4 was annotation-only (no production code touched for L254)
- Surviving references to removed symbols — should be ZERO:
  - `grep -rnE 'edits_indent_undo_end' src/ inc/ test/` → 0 hits
  - `grep -rnE 'visual_op_block_yank_ok' src/ inc/ test/` → 0 hits

### File List

(to be filled in by dev pass; expected fileset per Task 9.1)

## Change Log

| Date       | Author | Change                                                                       |
|------------|--------|------------------------------------------------------------------------------|
| 2026-05-19 | Amelia | Story 4.5 scoped from Theme D of `deferred-work-triage-2026-05-19.md`. Closes deferred entries L461 / L462 / L472 / L425 (4 active) + L254 (already-closed annotation). Pre-flight cross-check caught 2 stale triage entries: corrected line numbers for the duplicated-tails (1104/1348/1373 vs triaged 920/1068/1093) and the is_word_char `OR 1` byte (already saved per motions.asm:778). Projected delta -34 B ± 4 B. Ready for dev. |
