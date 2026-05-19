# Story 4.6: Comprehensive user documentation in README.md

Status: ready-for-dev

<!-- Provenance: Ad-hoc scoping by Ant 2026-05-19 to follow up the implementation
     completion of Epics 1-3 + Epic 4 (4.1/4.2) + 4.3/4.4/4.5 in flight. README.md
     today (line 3) explicitly says "This is a dev-loop README, not user
     documentation. End-user documentation is a separate post-MVP artifact." That
     post-MVP artifact is this story.

     Story type: TECH-WRITER (doc-only). Recommended execution agent:
     bmad-agent-tech-writer (Paige). NO production code touched; NO new tests;
     NFR9 / NFR18 unchanged. -->

## Story

As a developer who clones VIBE for the first time or returns to it after a gap and needs
to know what commands work, what's deliberately missing vs. vi, and how the modal model
maps to keystrokes,
I want the README to be a comprehensive User Guide (modes, motions, edits, visual ops,
composed operators, ex commands, search, undo, status semantics) plus a vi-deviation
section that names everything VIBE omits or diverges from vi on,
So that I can drive VIBE confidently from the keyboard reference alone without spelunking
the PRD or epics — and so the existing dev-loop content (build / test / push / repo
layout) is preserved as a "Hacking" section for contributors.

## Acceptance Criteria

**Story type note.** This is a **tech-writer / doc-only** story. There is NO production
code change, NO new tests, NO NFR9 budget impact, NO NFR18 SHA change, and NO hardware
UAT. The acceptance signals are content-quality + structural — see AC8 for the binding
review process.

**AC1 — README.md restructured into User Guide + Hacking sections.**

**Given** the current README.md (48 lines) explicitly disclaims user-facing content
("This is a dev-loop README, not user documentation") and contains only Prerequisites /
Build / Test / Transfer / Repo-layout sections
**When** Story 4.6 lands
**Then** README.md is restructured into the following top-level shape:

```
# VIBE

<one-paragraph user-facing pitch: what VIBE is, who it's for, what platform>

## Quick start
  - Launching (vibe / vibe filename.fs / welcome-screen FR53 dismissal)
  - The 5-minute orientation (modes, save, quit)

## Modes
  - NORMAL / INSERT / COMMAND (ex) / VISUAL (char / line / block)
  - Mode transitions table
  - Status-line interpretation

## Commands
### Motions (with counts)
### Edits
### Visual-mode operations
### Composed operators (operator + motion)
### Search
### Undo
### Ex commands (:q, :w, :e, etc.)

## Vi deviations and omissions

## Limits

## Hacking
  - Prerequisites
  - Build
  - Test
  - Transfer
  - Repo layout
  - (link to architecture.md for the deep-dive)
```

The pre-existing dev-loop content (Prerequisites, Build, Test, Transfer, Repo layout)
moves verbatim under `## Hacking` as a final section. The disclaimer line 3 ("This is a
dev-loop README, not user documentation") is **removed** because the README is no longer
just dev-loop content.

**AC2 — Commands section enumerates every implemented command from FR12 through FR52 (and
the FR53 welcome).**

**Given** the PRD enumerates 80 Functional Requirements (FR1-FR53 + post-MVP); FR1-FR8
cover launch / file ops, FR12-FR17 cover modes, FR18-FR23 cover motions, FR24-FR32 cover
edits, FR33-FR38 cover visual ops, FR39-FR40 cover composed operators, FR41-FR44 cover
search, FR45-FR46 cover undo, FR47-FR48 cover render, FR49-FR52 cover status / error /
no-op semantics, FR53 covers welcome
**When** Story 4.6 lands
**Then** every implemented FR (per `sprint-status.yaml` `done` status — FR1-FR53 less any
deferred) is reflected in the Commands section, organized by user-task not FR number, with
a parenthetical FR anchor for traceability:

| User task | Keystroke | FR |
|---|---|---|
| Move cursor left one character | `h` | FR18 |
| Move cursor right one character | `l` | FR18 |
| Move cursor down one line | `j` | FR19 |
| ... | ... | ... |

Tables MUST be the primary presentation — each motion / edit / visual op / ex command gets
one row. Free-text prose around tables is for orientation only (one paragraph per
subsection, max).

**Source-of-truth grounding.** Every command entry MUST cite the FR ID. If a command is
present in the code but absent from the PRD's FR list (defensive shouldn't-happen case),
flag it to Ant before documenting — likely indicates either a code-side accident or a
spec drift that needs PRD reconciliation.

**AC3 — Modes section covers transitions + status-line semantics.**

**Given** VIBE has 4 modes (NORMAL / INSERT / COMMAND / VISUAL) with sub-modes inside
VISUAL (char / line / block) and COMMAND (ex submodes for `:` and `/` per Story 2.1 /
3.1)
**When** Story 4.6 lands
**Then** the Modes section contains:

1. **What each mode does** — one paragraph per top-level mode + sub-mode bullets
2. **Mode-transitions diagram or table** — every documented transition with the keystroke
   that triggers it. E.g. NORMAL → INSERT via `i` / `a` / `o` / `O` (FR13, FR24-FR27);
   INSERT → NORMAL via Esc (FR16); NORMAL → COMMAND via `:` or `/` (FR14, FR41); etc.
3. **Status-line interpretation** — what appears on row 24:
   - Empty banner (msg_mode_normal) in NORMAL mode per AR16 convention
   - `-- INSERT --` (or VIBE's equivalent — verify against `src/statusln.asm`) in INSERT
     mode
   - `:` or `/` prompt + typed bytes in COMMAND mode
   - `-- visual --` / `-- visual line --` / `-- visual block -- NxM` in VISUAL mode (per
     Story 3.5+ tracking)
   - Error messages (e.g. `file too large`, `can't read file`, `pattern not found`) and
     when they appear / when they clear

**Tech-writer's verification step.** Each status-line claim must be cross-checked against
the actual emitted strings in `src/statusln.asm` (search for `msg_*:` labels) — these are
the authoritative source of truth for what VIBE actually displays. If the PRD or epics
say one thing and statusln.asm says another, **statusln.asm wins** and Ant gets a flag.

**AC4 — Vi deviations and omissions section names every divergence.**

**Given** VIBE is "vi-spirited" but deliberately not a vi clone — many vi features are
out of scope for the 10240 B NFR9 ceiling
**When** Story 4.6 lands
**Then** a section titled `## Vi deviations and omissions` documents (organized by
category):

**Omissions — vi features NOT implemented.** Examples to investigate and document:
- Multi-level undo (VIBE has single-level via FR45; vi has unlimited)
- Repeat-last-edit (`.`)
- Marks (`m{a-z}` / `'{a-z}` / `` `{a-z} ``)
- Named registers (`"{a-zA-Z}p`)
- Macros (`q{a-z}` recording)
- `f` / `F` / `t` / `T` character-find motions
- `e` / `ge` word-end motions
- `%` matching-paren motion
- `H` / `M` / `L` viewport motions
- `Ctrl-D` / `Ctrl-U` half-page scroll
- `r` single-char replace, `R` overwrite mode
- `s` substitute character, `S` substitute line
- `c` change in NORMAL mode (only composed `c<motion>` per FR39; standalone `c` behaviour
  needs verification)
- `:s` substitute, `:g` global, `:r` read, `:!` shell-escape — entire `:` command family
  beyond `:q` / `:w` / `:e`
- Search-backward `?pattern`
- Counted-`n` for repeated search (deferred per `deferred-work-triage` Theme B)
- Counted operators on VISUAL selections (deferred per Theme B)
- TAB-aware rendering (per Story 4.4 AC4 — TAB renders as space)
- `~` toggle-case on a single character in NORMAL mode (only on visual selection per
  FR38; verify whether NORMAL-mode `~` is supported or no-op)

**Deviations — vi features implemented differently.** Examples to investigate:
- Empty-line marker: vi shows `~` in column 0; VIBE shows blank (0x20 space). Per
  [[project_no_tilde_marker]] memory.
- CR/CRLF rendering policy: VIBE renders CR / NUL / high-bit bytes as space; preserves
  CRLF round-trip on save (per Story 4.4 AC4 / AC5 — Option A).
- Cursor positioning on CRLF lines: motion_h / motion_l / motion_dollar treat CR as line
  boundary like LF (Story 4.4 AC1-AC3).
- Welcome screen: shown on no-arg launch, dismissed by ANY first keystroke which is then
  processed normally by the active mode (Story 4.2 / FR53). Vi has `:intro` polish but
  not first-keystroke dismissal in the same way.
- File size limit: 32 KB hard cap per FR11 (gap buffer size). Vi has no such limit on
  modern systems.
- Single buffer: VIBE has exactly one buffer; no `:bnext` / `:bprev` / split-window. Vi /
  vim has multi-buffer.
- Single-level undo: per FR45.
- BDOS-error handling: every BDOS failure surfaces in status line per FR51; vi has its
  own error vocabulary.

**Each omission and each deviation MUST cite either** (a) an FR number that limits scope,
(b) a deferred-work entry that captures it as future work, (c) a memory entry that
records the policy decision, or (d) a triage doc entry. **Naked claims with no
provenance are not acceptable** — every deviation either traces back to a deliberate
design call or it's a bug.

**Tech-writer's grep target list:**
- `_bmad-output/planning-artifacts/prd.md` (FR list)
- `_bmad-output/implementation-artifacts/deferred-work.md` (deferred features)
- `_bmad-output/implementation-artifacts/deferred-work-triage-2026-05-19.md` (Theme B
  park-able backlog — counted operators on visual, counted-n)
- Story files for any "vi-faithful" / "vi convention" / "vi-divergence" claims in their
  AC narratives
- `~/.claude/projects/-home-ant-src-microbeast-vibe/memory/MEMORY.md` (project memory —
  `[[project_no_tilde_marker]]` in particular)

**AC5 — Limits section names the hard caps.**

**Given** VIBE has several user-visible limits that affect real workflow choices
**When** Story 4.6 lands
**Then** a `## Limits` section names each:
- File size: 32 KB (32768 bytes) — files over this are rejected with `file too large`
  (FR11). Pre-existing files over the cap can't be opened.
- Line length: ?? — verify from architecture / code whether there's an explicit cap or
  whether 32 KB / line is the effective cap.
- Single buffer: editing one file at a time.
- Single-level undo: only the most recent mutating op is reversible (FR45).
- Yank-register capacity: ?? — verify from `inc/equates.inc` (YANK_BUFFER_SIZE) and
  Story 3.6 yank-too-large semantics.
- Search-pattern length: ?? — verify (SEARCH_PATTERN_MAX or similar).
- Ex-line length: ?? — verify (EX_LINE_BUFFER_SIZE or similar).
- Platform: Feersum MicroBeast + CP/M 2.2 only (NFR13, NFR15).

The `??` markers are dev-pass investigation targets — the tech writer SHOULD grep
`inc/equates.inc` and verify the actual numeric caps before writing the section, NOT
hand-wave them.

**AC6 — Quick-start section gets a new user from CCP prompt to "I edited a file" in <2
minutes.**

**Given** a new VIBE user landing on the README
**When** they read the Quick-start section
**Then** by the end of it they can:
1. Launch VIBE (`vibe` for empty buffer + welcome; `vibe filename.fs` for editing a file)
2. Dismiss the welcome screen (any keystroke)
3. Enter INSERT mode (`i`), type a few characters, return to NORMAL mode (`Esc`)
4. Save the file (`:w` or `:w filename.fs`)
5. Quit (`:q` or `:wq` to save + quit; `:q!` to abandon changes)

Quick-start is a numbered walkthrough, not a reference table. ~10-15 lines of prose with
inline keystrokes; designed to be read top-to-bottom.

**AC7 — Hacking section preserves existing dev-loop content verbatim.**

**Given** the existing README sections (Prerequisites / Build / Test / Transfer / Repo
layout) are accurate dev-loop instructions that contributors rely on
**When** Story 4.6 lands
**Then** the existing content moves under `## Hacking` AS-IS (no content deletion, no
re-wording without reason). Acceptable amendments:
- Remove the "Stubbed until Story 1.6" / "Stubbed until BA4" language now that test and
  transfer are wired up. Replace with the actual current state.
- Update line 11's mention of `iz-cpm` to note it's now actively used by `make test`.
- Add a `make sizes` mention if not already present (used by every dev story for NFR9
  verification).
- Link to architecture.md preserved (currently line 5 and line 48).

The dev-loop sections should stay near the end of the README. New users care about the
User Guide; contributors who want the dev loop will scroll past.

**AC8 — Review process: round-trip with Ant + spot-check against actual VIBE behaviour.**

**Given** documentation accuracy is the load-bearing acceptance signal (more than length,
formatting, or any size metric)
**When** the tech writer's first draft is complete
**Then** the dev pass follows this review process before commit:

1. **Self-grep verification.** For every claim that names a specific FR / keystroke /
   status message, the tech writer runs the grep against the asserted source-of-truth
   (PRD FR list / `src/statusln.asm` strings / `inc/equates.inc` caps) and confirms the
   claim before writing it. Document any discrepancies found in the Dev Agent Record.
2. **Round-trip with Ant.** Present the first draft (the new README.md) to Ant for
   review. Expect feedback on tone, scope, omissions, style. Iterate.
3. **Behavioural spot-check.** Pick 3-5 specific keystroke claims from the new README
   (e.g. "`gg` moves to first line", "`:wq` saves and quits", "`Ctrl-L` refreshes
   screen") and verify them against actual VIBE behaviour via `make test` test-case names
   or by running `vibe` on the host with `iz-cpm` and trying the keystroke. Flag any
   mismatch.
4. **Vi-omission audit.** Pick 3-5 vi features the new README claims are NOT in VIBE.
   Verify by `grep` against `src/*.asm` that no implementation snuck in. If grep finds
   something, escalate — either the docs are wrong or there's an undocumented feature.

The story is `review` after step 1; `done` after Ant accepts step 2 + any iteration.

**AC9 — sprint-status.yaml updated to `done` after Ant's acceptance.**

**Given** sprint-status.yaml tracks per-story status
**When** Story 4.6 lands
**Then** `4-6-comprehensive-user-docs-readme` is updated through the standard sequence:
`ready-for-dev` → `review` (after tech-writer's first draft + self-grep verification) →
`done` (after Ant's acceptance per AC8 step 2).

No deferred-work.md annotations required (Story 4.6 doesn't close any deferred entry —
it's a new piece of work).

## Tasks / Subtasks

- [ ] **Task 0 — Tech-writer onboarding + source-of-truth survey**
  - [ ] 0.1 Read `_bmad-output/planning-artifacts/prd.md` end-to-end with focus on the
    FR list (lines 680-900+). The 53 implemented FRs are the load-bearing content of the
    User Guide.
  - [ ] 0.2 Read `src/statusln.asm` for every `msg_*:` label — these are the exact
    strings VIBE displays on the status line. Catalogue them; they go into AC3's status
    interpretation table.
  - [ ] 0.3 Read `inc/equates.inc` for every `*_MAX` / `*_SIZE` / `*_BUFFER_SIZE`
    constant — these are the numeric limits for AC5. Catalogue them.
  - [ ] 0.4 Read `_bmad-output/implementation-artifacts/deferred-work-triage-2026-05-19.md`
    Theme B (lines 211-213) for park-able backlog — those are the FUTURE vi-features
    that go in AC4's deviations section as "not yet" entries.
  - [ ] 0.5 Read `~/.claude/projects/-home-ant-src-microbeast-vibe/memory/MEMORY.md` for
    project-level deviation memory ([[project_no_tilde_marker]] in particular). Each
    project memory entry is potentially a documentation source.
  - [ ] 0.6 Read the current `README.md` (48 lines) — note what's preserved (per AC7) vs
    what's replaced (per AC1's restructuring).

- [ ] **Task 1 — Draft User Guide skeleton + Quick-start (AC: #1, #6)**
  - [ ] 1.1 Create the new `README.md` skeleton with the top-level shape from AC1.
  - [ ] 1.2 Write the one-paragraph user-facing pitch at the top — replaces the current
    dev-loop disclaimer. Suggested shape: "VIBE is a vi-spirited modal text editor for
    the Feersum MicroBeast (Z80, CP/M 2.2). Single-buffer, single-level-undo, optimized
    for serial-terminal use. Modal editing with motions, edits, visual selection,
    composed operator+motion, ex commands, and forward search. Fits in 10 KB of TPA."
  - [ ] 1.3 Write the Quick-start walkthrough per AC6. 5 numbered steps, ~10-15 lines.
    Inline keystrokes (no big tables yet).

- [ ] **Task 2 — Modes section (AC: #3)**
  - [ ] 2.1 Paragraph + sub-paragraph structure: NORMAL (default; motions + edits),
    INSERT (text entry until Esc), COMMAND (ex-line `:` and search `/`), VISUAL (char /
    line / block selection).
  - [ ] 2.2 Mode-transitions table — every documented transition. Source FR12-FR17 from
    PRD; cross-check against `src/dispatch.asm` for the actual dispatch entry points.
  - [ ] 2.3 Status-line interpretation per AC3 step 3. Catalogue from Task 0.2 grep of
    `src/statusln.asm`.

- [ ] **Task 3 — Commands section (AC: #2)**
  - [ ] 3.1 Motions table (h/j/k/l/w/b/0/$/gg/G + counts, per FR18-FR23).
  - [ ] 3.2 Edits table (i/a/o/O/x/dd/dw/yy/p, per FR24-FR32).
  - [ ] 3.3 Visual-mode operations table (Ctrl-V/v/V for entry; d/y/c on selection per
    FR36; >/< per FR37; ~ per FR38).
  - [ ] 3.4 Composed operators table (dw/d$/c5w/y3j/c3l per FR39-FR40 — the operator ×
    motion product space).
  - [ ] 3.5 Search table (/pattern, n, FR41-FR44).
  - [ ] 3.6 Undo (u — single level — FR45-FR46).
  - [ ] 3.7 Ex commands table (:q, :q!, :w, :w filename, :wq, :e filename, :e! per
    FR3-FR8).
  - [ ] 3.8 Other commands — Ctrl-L (FR48), counts in NORMAL mode (FR23), etc.

- [ ] **Task 4 — Vi deviations and omissions section (AC: #4)**
  - [ ] 4.1 Omissions list — start from the suggested list in AC4 and verify each via
    `grep` against `src/*.asm`. Anything NOT in src/ goes in the omissions table.
  - [ ] 4.2 Deviations list — every place VIBE deliberately differs from vi:
    - No `~` empty-line marker (memory: `[[project_no_tilde_marker]]`)
    - CR/CRLF rendering policy (Story 4.4)
    - Welcome-screen first-keystroke dismissal (Story 4.2)
    - 32 KB file cap (FR11)
    - Single-buffer (PRD architectural limit)
    - Single-level undo (FR45)
    - BDOS-error handling vocabulary (FR51)
  - [ ] 4.3 Park-able backlog list (theme B) — counted-`n`, counted operators on
    visual, etc. — these are "not yet" omissions (different from "never").
  - [ ] 4.4 Each entry MUST have an FR / deferred-work / memory / triage citation per
    AC4's provenance requirement.

- [ ] **Task 5 — Limits section (AC: #5)**
  - [ ] 5.1 Populate the limits table from Task 0.3's catalogue of equates. Replace
    every `??` marker in AC5's bullet list with the verified value.
  - [ ] 5.2 Add a sentence on graceful-failure semantics — what happens when a limit is
    hit (e.g. file too large surfaces FR11 status; yank too large surfaces FR-equivalent
    visual-op status per Story 3.6).

- [ ] **Task 6 — Hacking section (AC: #7)**
  - [ ] 6.1 Move the existing 5 sections (Prerequisites / Build / Test / Transfer /
    Repo layout) under a new `## Hacking` heading, verbatim.
  - [ ] 6.2 Update "Stubbed until Story 1.6" → "Runs the headless test harness;
    requires iz-cpm on PATH" or similar. Same for "Stubbed until BA4" / Transfer
    section.
  - [ ] 6.3 Optionally add a `make sizes` mention (used by every story for NFR9
    verification) — verify the target exists and what it prints.
  - [ ] 6.4 Preserve the architecture.md link.

- [ ] **Task 7 — Self-grep verification pass (AC: #8 step 1)**
  - [ ] 7.1 For every FR-cited claim in the new README, grep the PRD to verify the FR
    number and the keystroke match. Flag any drift.
  - [ ] 7.2 For every status-line message claim, grep `src/statusln.asm` for the
    `msg_*:` label and confirm the string matches the documented one.
  - [ ] 7.3 For every limit / cap, grep `inc/equates.inc` for the constant and confirm
    the number.
  - [ ] 7.4 For every vi-omission claim, grep `src/*.asm` for the unsupported feature's
    keystroke (or, for the feature-without-keystroke cases like `.` repeat, grep for the
    presence of any handler). If a grep hit appears, escalate — the omission claim is
    wrong.
  - [ ] 7.5 Document all discrepancies + resolutions in the Dev Agent Record.

- [ ] **Task 8 — First-draft handoff to Ant (AC: #8 step 2)**
  - [ ] 8.1 Update sprint-status.yaml: status `ready-for-dev` → `review`.
  - [ ] 8.2 Present the new README.md to Ant in the chat (or via PR if working
    out-of-band). Frame the handoff with: "First draft; please flag any tone, scope, or
    accuracy concerns. Self-grep done per AC8 step 1 — Task 7 results in Dev Agent
    Record."
  - [ ] 8.3 Iterate on feedback. Document each Ant-requested change as a sub-task here
    (8.3.1, 8.3.2, etc.) with status indicators.

- [ ] **Task 9 — Behavioural spot-check (AC: #8 step 3)**
  - [ ] 9.1 Pick 3-5 keystroke claims from the README. Suggestions: `gg` (first line),
    `G` (last line), `:wq` (save + quit), `Ctrl-L` (refresh), `dd` (delete line).
  - [ ] 9.2 For each, find the corresponding `test/cases/*.asm` test that pins the
    behaviour. Confirm the test name matches the documented behaviour. If no test
    exists, optionally run the keystroke on the host via `iz-cpm` to verify.
  - [ ] 9.3 Document each spot-check in the Dev Agent Record.

- [ ] **Task 10 — Vi-omission audit (AC: #8 step 4)**
  - [ ] 10.1 Pick 3-5 documented vi-omissions. Suggestions: `.` repeat, `f`/`t`
    character-find, marks (`m{a-z}`), search-backward (`?pattern`), multi-level undo.
  - [ ] 10.2 For each, grep `src/*.asm` and `src/dispatch.asm` for the keystroke /
    handler name. Confirm ZERO matches. If a match appears, escalate.
  - [ ] 10.3 Document each audit in the Dev Agent Record.

- [ ] **Task 11 — Commit + close (AC: #9)**
  - [ ] 11.1 Stage:
    - `README.md` (the rewrite)
    - `_bmad-output/implementation-artifacts/4-6-comprehensive-user-docs-readme.md` (this
      file — Dev Agent Record filled in with self-grep results, Ant-feedback iteration
      log, spot-check + omission-audit results)
    - `_bmad-output/implementation-artifacts/sprint-status.yaml` (status `review` →
      `done` after Ant's acceptance)
  - [ ] 11.2 Commit message: `Story 4.6: comprehensive user docs in README.md`. Optional
    longer body listing the major sections added (Modes / Commands / Vi deviations /
    Limits / Quick-start) for the git-log reader.
  - [ ] 11.3 Update sprint-status.yaml: `4-6-comprehensive-user-docs-readme: done` after
    Ant's final acceptance.

## Dev Notes

### Architecture compliance

**Story 4.6 touches NO production code.** AR12 / AR13 / AR14 / AR15 / AR23 / AR25 / MC1 /
MC4 / MC5 / MC7 / RI1-RI4 / NFR1 / NFR3 / NFR5 / NFR9 / NFR18 are all trivially preserved
because no `src/*.asm` or `inc/*.inc` file is edited.

### Files this story modifies

**`README.md`** — restructured from 48-line dev-loop note into a User Guide + Hacking
document. Expected size: 250-400 lines depending on table density. The growth is
acceptable — README is the canonical user-facing entry point and length is not a quality
metric.

**`_bmad-output/implementation-artifacts/sprint-status.yaml`** — single-line status
update.

**`_bmad-output/implementation-artifacts/4-6-comprehensive-user-docs-readme.md`** — this
file, filled in with Dev Agent Record + verification logs.

**NEW FILES:** none (README.md exists already).

### Implementation choices and trade-offs

**Choice 1: Single README.md vs split user-docs/ + hacking/.**
- **Adopted: single README.md** with two top-level sections. Single-file simplicity wins;
  contributors and users land at the same URL. Splitting would force a navigation
  decision the user shouldn't have to make.
- Alternative (rejected): separate `USER_GUIDE.md` + `HACKING.md`. Adds discoverability
  cost.

**Choice 2: Tables vs prose-only.**
- **Adopted: tables for every command-list AC**, prose-only for orientation paragraphs.
  Tables are scannable and grep-friendly; prose is for the "why" not the "what".
- Alternative (rejected): big prose paragraphs cataloguing all motions. Hard to scan;
  hard to update.

**Choice 3: FR-anchor every command vs only deviations.**
- **Adopted: every command** gets an FR anchor. Costs a column in each table; gains
  traceability when a future PRD update lands and we need to find what documentation
  needs to change.
- Alternative (rejected): only flag deviations with FR / deferred-work anchors. Cheaper
  but loses the PRD ↔ docs link.

**Choice 4: Verbatim move of existing dev-loop content vs rewrite.**
- **Adopted: verbatim move** with the AC7-listed minor amendments (de-stub the Test /
  Transfer sections). The existing content is correct and concise; rewriting risks
  regressions.

**Choice 5: Welcome-screen documentation under "Quick start" vs under "Modes".**
- **Adopted: Quick start.** The welcome screen is the first thing a new user sees on
  no-arg launch; documenting it under Modes buries it. Quick-start step 1 ("Launching")
  surfaces the welcome + first-keystroke dismissal.

### Implementation Questions

**Q1: Should the README include a one-page keystroke cheatsheet at the very top (before
Quick-start) for users who already know vi and just want the reference card?**
- **Recommended default:** YES — a compact "Cheatsheet" section immediately after the
  one-paragraph pitch, before Quick-start. ~20 lines of dense tables (motions / edits /
  visual / search / ex). The full Commands section later in the README is the canonical
  reference; the cheatsheet is for the experienced vi user who wants a quick map.
- If Ant prefers a leaner README, drop the cheatsheet and rely on the Commands section
  alone.

**Q2: Should the README include screenshots of VIBE running?**
- **Recommended default:** NO. VIBE runs on a serial-terminal-attached MicroBeast;
  "screenshot" would be a terminal-capture which is hard to keep in sync and adds
  binary asset weight. Text descriptions of the welcome screen + status line are
  sufficient.

**Q3: Should vi-omissions be documented BEFORE or AFTER the supported-commands section?**
- **Recommended default:** AFTER. Users come for what VIBE does; what it doesn't do is
  the secondary context. Putting omissions first creates a "wall of can't" impression
  that's wrong (VIBE has substantial coverage of the vi keystroke vocabulary).
- Alternative: put omissions immediately after Modes section so users calibrate
  expectations before the long command tables. Marginal preference.

**Q4: Should the README link to the PRD / architecture.md / individual story files?**
- **Recommended default:** Link to architecture.md (already present at line 5 / 48 of
  current README — preserve). Do NOT link to individual story files (too transient).
  Link to deferred-work.md in the "what's not yet" omission cases is reasonable but not
  required.

### NFR9 / NFR18 / test-count

**NFR9:** 0 B impact (no production code).
**NFR18:** unchanged SHA (no production code).
**Test count:** unchanged (no tests added or removed).

### Project Structure Notes

- The README rewrite is in-file (existing `README.md` at repo root); no new files.
- The README is **markdown rendered by GitHub** — keep the existing GitHub-flavored
  markdown conventions (fenced code blocks, tables, link format). The current README
  validates against GitHub's renderer; the new one should too.
- Line length: no hard cap, but lean toward soft-wrapping at ~100 chars for readability
  in narrow terminal viewers (matches the planning-artifacts style).
- No images / binary assets — text-only per Q2.

### References

- Source FR list: `_bmad-output/planning-artifacts/prd.md` lines 680-900+ (53 FRs).
- Architecture rules: `_bmad-output/planning-artifacts/architecture.md` (linked from the
  README).
- Sprint status: `_bmad-output/implementation-artifacts/sprint-status.yaml` — confirms
  which stories are `done` (their FRs are documented as supported) vs `backlog` /
  `optional` (their FRs may need "not yet" framing).
- Deferred-work backlog: `_bmad-output/implementation-artifacts/deferred-work.md` +
  `deferred-work-triage-2026-05-19.md` Theme B (park-able backlog) — the "not yet"
  omissions for AC4.
- Memory:
  - `[[project_no_tilde_marker]]` — VIBE shows blank past-EOF rows, not `~`.
  - `[[feedback_uat_trace_cursor]]` — `$` is per-LINE; `$a` only appends at EOF if cursor
    is on the last line. May or may not need to surface in user docs depending on Ant's
    preference; flag as Q5 if uncertain.
- Status messages (canonical source): `src/statusln.asm`.
- Limits (canonical source): `inc/equates.inc`.

### Memory hooks (from [[memory]])

- **[[project_no_tilde_marker]]** — load-bearing for AC4 vi-deviations. VIBE does NOT
  show `~` past EOF; this is a deliberate choice + a recurring tripping point. Document
  prominently in the deviations section.
- **[[feedback_uat_trace_cursor]]** — cursor positioning details that matter for the
  Commands section (especially around `$` and `a`).
- **[[feedback_create_story_cross_check]]** — applies recursively here: cross-check
  every AC narrative claim against actual VIBE behaviour. Self-grep verification in
  Task 7 implements this.

## Hardware UAT script (AC8 — NOT required for this story)

**Story 4.6 is a doc-only story with no production code changes.** Hardware UAT is not
required. The functional equivalent is AC8's behavioural spot-check (Task 9) — running
a small number of documented keystrokes against the existing `make test` evidence chain
to confirm the docs match reality.

If the spot-check (Task 9) flags a mismatch between documentation and behaviour, the
escalation is to fix the docs OR file a bug against the production code — NOT to invoke
hardware UAT.

## Dev Agent Record

### Agent Model Used

Recommended: **bmad-agent-tech-writer (Paige)** — this is a tech-writer story per the
story-type note at the top of the AC block. If executing via `dev-story`, the standard
dev agent (Amelia / bmad-agent-dev) can also run it; the work is mechanical
research + writing, not code.

(Fill in actual agent model used by dev pass.)

### Debug Log References

(To be filled in by dev pass.)

### Completion Notes List

(To be filled in by dev pass; required entries:)
- Self-grep verification log (Task 7) — any FR / status-message / limit / omission
  discrepancies found + resolutions.
- Ant-feedback iteration log (Task 8) — each requested change + how it was addressed.
- Behavioural spot-check log (Task 9) — the 3-5 keystrokes verified + the test-case
  evidence chain.
- Vi-omission audit log (Task 10) — the 3-5 features audited + the grep confirmation.
- Final README.md line count (no quality threshold, just a metric for the record).

### File List

(To be filled in by dev pass; expected fileset per Task 11.1.)

## Change Log

| Date       | Author | Change                                                                       |
|------------|--------|------------------------------------------------------------------------------|
| 2026-05-19 | Amelia | Story 4.6 scoped ad-hoc by Ant. Tech-writer story (recommended agent: Paige). Restructures the 48-line dev-loop README.md into a User Guide (modes / commands / vi deviations / limits / quick-start) + a preserved Hacking section. 0 B production-code impact; AC8 review process is round-trip with Ant after self-grep verification. Ready for dev. |
