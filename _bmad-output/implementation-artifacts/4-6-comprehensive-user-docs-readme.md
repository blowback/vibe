# Story 4.6: Comprehensive user documentation in README.md

Status: done

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

- [x] **Task 0 — Tech-writer onboarding + source-of-truth survey**
  - [x] 0.1 Read `_bmad-output/planning-artifacts/prd.md` end-to-end with focus on the
    FR list (lines 680-900+). The 53 implemented FRs are the load-bearing content of the
    User Guide.
  - [x] 0.2 Read `src/statusln.asm` for every `msg_*:` label — these are the exact
    strings VIBE displays on the status line. Catalogue them; they go into AC3's status
    interpretation table.
  - [x] 0.3 Read `inc/equates.inc` for every `*_MAX` / `*_SIZE` / `*_BUFFER_SIZE`
    constant — these are the numeric limits for AC5. Catalogue them.
  - [x] 0.4 Read `_bmad-output/implementation-artifacts/deferred-work-triage-2026-05-19.md`
    Theme B (lines 211-213) for park-able backlog — those are the FUTURE vi-features
    that go in AC4's deviations section as "not yet" entries.
  - [x] 0.5 Read `~/.claude/projects/-home-ant-src-microbeast-vibe/memory/MEMORY.md` for
    project-level deviation memory ([[project_no_tilde_marker]] in particular). Each
    project memory entry is potentially a documentation source.
  - [x] 0.6 Read the current `README.md` (48 lines) — note what's preserved (per AC7) vs
    what's replaced (per AC1's restructuring).

- [x] **Task 1 — Draft User Guide skeleton + Quick-start (AC: #1, #6)**
  - [x] 1.1 Create the new `README.md` skeleton with the top-level shape from AC1.
  - [x] 1.2 Write the one-paragraph user-facing pitch at the top — replaces the current
    dev-loop disclaimer. Suggested shape: "VIBE is a vi-spirited modal text editor for
    the Feersum MicroBeast (Z80, CP/M 2.2). Single-buffer, single-level-undo, optimized
    for serial-terminal use. Modal editing with motions, edits, visual selection,
    composed operator+motion, ex commands, and forward search. Fits in 10 KB of TPA."
  - [x] 1.3 Write the Quick-start walkthrough per AC6. 5 numbered steps, ~10-15 lines.
    Inline keystrokes (no big tables yet).

- [x] **Task 2 — Modes section (AC: #3)**
  - [x] 2.1 Paragraph + sub-paragraph structure: NORMAL (default; motions + edits),
    INSERT (text entry until Esc), COMMAND (ex-line `:` and search `/`), VISUAL (char /
    line / block selection).
  - [x] 2.2 Mode-transitions table — every documented transition. Source FR12-FR17 from
    PRD; cross-check against `src/dispatch.asm` for the actual dispatch entry points.
  - [x] 2.3 Status-line interpretation per AC3 step 3. Catalogue from Task 0.2 grep of
    `src/statusln.asm`.

- [x] **Task 3 — Commands section (AC: #2)**
  - [x] 3.1 Motions table (h/j/k/l/w/b/0/$/gg/G + counts, per FR18-FR23).
  - [x] 3.2 Edits table (i/a/o/O/x/dd/dw/yy/p, per FR24-FR32).
  - [x] 3.3 Visual-mode operations table (Ctrl-V/v/V for entry; d/y/c on selection per
    FR36; >/< per FR37; ~ per FR38).
  - [x] 3.4 Composed operators table (dw/d$/c5w/y3j/c3l per FR39-FR40 — the operator ×
    motion product space).
  - [x] 3.5 Search table (/pattern, n, FR41-FR44).
  - [x] 3.6 Undo (u — single level — FR45-FR46).
  - [x] 3.7 Ex commands table (:q, :q!, :w, :w filename, :wq, :e filename, :e! per
    FR3-FR8).
  - [x] 3.8 Other commands — Ctrl-L (FR48), counts in NORMAL mode (FR23), etc.

- [x] **Task 4 — Vi deviations and omissions section (AC: #4)**
  - [x] 4.1 Omissions list — start from the suggested list in AC4 and verify each via
    `grep` against `src/*.asm`. Anything NOT in src/ goes in the omissions table.
  - [x] 4.2 Deviations list — every place VIBE deliberately differs from vi:
    - No `~` empty-line marker (memory: `[[project_no_tilde_marker]]`)
    - CR/CRLF rendering policy (Story 4.4)
    - Welcome-screen first-keystroke dismissal (Story 4.2)
    - 32 KB file cap (FR11)
    - Single-buffer (PRD architectural limit)
    - Single-level undo (FR45)
    - BDOS-error handling vocabulary (FR51)
  - [x] 4.3 Park-able backlog list (theme B) — counted-`n`, counted operators on
    visual, etc. — these are "not yet" omissions (different from "never").
  - [x] 4.4 Each entry MUST have an FR / deferred-work / memory / triage citation per
    AC4's provenance requirement.

- [x] **Task 5 — Limits section (AC: #5)**
  - [x] 5.1 Populate the limits table from Task 0.3's catalogue of equates. Replace
    every `??` marker in AC5's bullet list with the verified value.
  - [x] 5.2 Add a sentence on graceful-failure semantics — what happens when a limit is
    hit (e.g. file too large surfaces FR11 status; yank too large surfaces FR-equivalent
    visual-op status per Story 3.6).

- [x] **Task 6 — Hacking section (AC: #7)**
  - [x] 6.1 Move the existing 5 sections (Prerequisites / Build / Test / Transfer /
    Repo layout) under a new `## Hacking` heading, verbatim.
  - [x] 6.2 Update "Stubbed until Story 1.6" → "Runs the headless test harness;
    requires iz-cpm on PATH" or similar. Same for "Stubbed until BA4" / Transfer
    section.
  - [x] 6.3 Optionally add a `make sizes` mention (used by every story for NFR9
    verification) — verify the target exists and what it prints.
  - [x] 6.4 Preserve the architecture.md link.

- [x] **Task 7 — Self-grep verification pass (AC: #8 step 1)**
  - [x] 7.1 For every FR-cited claim in the new README, grep the PRD to verify the FR
    number and the keystroke match. Flag any drift.
  - [x] 7.2 For every status-line message claim, grep `src/statusln.asm` for the
    `msg_*:` label and confirm the string matches the documented one.
  - [x] 7.3 For every limit / cap, grep `inc/equates.inc` for the constant and confirm
    the number.
  - [x] 7.4 For every vi-omission claim, grep `src/*.asm` for the unsupported feature's
    keystroke (or, for the feature-without-keystroke cases like `.` repeat, grep for the
    presence of any handler). If a grep hit appears, escalate — the omission claim is
    wrong.
  - [x] 7.5 Document all discrepancies + resolutions in the Dev Agent Record.

- [ ] **Task 8 — First-draft handoff to Ant (AC: #8 step 2)**
  - [x] 8.1 Update sprint-status.yaml: status `ready-for-dev` → `review`.
  - [ ] 8.2 Present the new README.md to Ant in the chat (or via PR if working
    out-of-band). Frame the handoff with: "First draft; please flag any tone, scope, or
    accuracy concerns. Self-grep done per AC8 step 1 — Task 7 results in Dev Agent
    Record."
  - [ ] 8.3 Iterate on feedback. Document each Ant-requested change as a sub-task here
    (8.3.1, 8.3.2, etc.) with status indicators.

- [x] **Task 9 — Behavioural spot-check (AC: #8 step 3)**
  - [x] 9.1 Pick 3-5 keystroke claims from the README. Suggestions: `gg` (first line),
    `G` (last line), `:wq` (save + quit), `Ctrl-L` (refresh), `dd` (delete line).
  - [x] 9.2 For each, find the corresponding `test/cases/*.asm` test that pins the
    behaviour. Confirm the test name matches the documented behaviour. If no test
    exists, optionally run the keystroke on the host via `iz-cpm` to verify.
  - [x] 9.3 Document each spot-check in the Dev Agent Record.

- [x] **Task 10 — Vi-omission audit (AC: #8 step 4)**
  - [x] 10.1 Pick 3-5 documented vi-omissions. Suggestions: `.` repeat, `f`/`t`
    character-find, marks (`m{a-z}`), search-backward (`?pattern`), multi-level undo.
  - [x] 10.2 For each, grep `src/*.asm` and `src/dispatch.asm` for the keystroke /
    handler name. Confirm ZERO matches. If a match appears, escalate.
  - [x] 10.3 Document each audit in the Dev Agent Record.

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
  - [x] 11.3 Update sprint-status.yaml: `4-6-comprehensive-user-docs-readme: done` after
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

Executed by **dev-story (Amelia / Claude Opus 4.7, 1M context)** rather than the recommended Paige tech-writer agent. The work is mechanical (PRD/source grep → table population) and within the dev agent's remit.

### Debug Log References

No production code touched. No build / test runs required. All verification done via grep against the canonical sources listed in AC8 step 1.

### Completion Notes List

**Self-grep verification log (Task 7 / AC8 step 1).** Cross-checked every claim in the new README against canonical sources:

- **FR-anchor verification (Task 7.1):** All 22 FR citations in the Commands section (FR3-FR8, FR9-FR11, FR13, FR16, FR18-FR48) cross-checked against `_bmad-output/planning-artifacts/prd.md` lines 688-808. All match.
- **Status-message verification (Task 7.2):** All 14 active status messages cross-checked against `src/statusln.asm:318-366`. All strings match verbatim. **Discrepancy found and resolved:** initial draft claimed `buffer modified` appears when `:q` is refused. Grep confirmed `msg_buffer_modified` (defined at `src/statusln.asm:318`) has ZERO consumer call-sites across `src/` — it's a defined-but-unused label. The actual `:q` refusal message is `no write since last change` (`msg_no_write`), per `src/exline.asm:74,77,229,250,282`. README updated to remove the wrong row and surface only the live message. **Flagging for Ant:** `msg_buffer_modified` is dead code (29 B incl. terminator); a small-batch cleanup story could remove it for NFR9 hygiene, but that's out of scope for this doc story.
- **Limits verification (Task 7.3):** Every numeric cap in the Limits table cross-checked against `inc/equates.inc`:
  - `GAP_BUFFER_MAX = 32768` (line 33) ✓
  - `UNDO_BUFFER_SIZE = 256` (line 34) ✓
  - `EX_COMMAND_BUFFER = 64` (line 35) ✓
  - `SEARCH_PATTERN_BUFFER = 64` (line 41) ✓
  - `YANK_BUFFER_SIZE = 1024` (line 48) ✓
  - `FILENAME_BUFFER_SIZE = 16` (line 49) ✓
  - `SCREEN_ROWS = 24 / SCREEN_COLS = 80 / EDITABLE_ROWS = 23` (lines 55-57) ✓
- **Vi-omission audit (Task 7.4 / Task 10 / AC8 step 4):** grep against `src/dispatch.asm` for every claimed-not-implemented keystroke returned ZERO matches:
  - `.` (repeat) — no DEFB `'.'` in dispatch
  - `f` / `F` / `t` / `T` (char-find) — no DEFB for any
  - `e` (word-end) — no DEFB `'e'` in dispatch_normal
  - `%` (matching paren) — no DEFB `'%'`
  - `H` / `M` / `L` (viewport motions) — no DEFB for any
  - `Ctrl-D` (0x04) / `Ctrl-U` (0x15) — no DEFB
  - `r` / `R` / `s` / `S` (replace / overwrite / substitute) — no DEFB for any
  - `m` (mark set) — no DEFB `'m'`
  - `q` (macro record) — no DEFB `'q'`
  - `?` (search-backward prompt) — no DEFB `'?'`
  - NORMAL-mode `~` — `'~'` appears ONLY in `dispatch_visual` at line 816, bound to `visual_apply_case_toggle`; NOT in `dispatch_normal`. README correctly states NORMAL `~` is unbound.

**Behavioural spot-check log (Task 9 / AC8 step 3).** Picked 5 keystroke claims and located test/cases/*.asm pinning each:

| Claim | Pinning test(s) |
|---|---|
| `gg` moves to first line | `motions_gg-via-prefix.asm`, `motions_gg-with-count.asm` |
| `dd` deletes the current line | `edits_dd-deletes-line.asm` (+ 7 sibling tests covering counted / mid-line / EOF / empty-buffer cases) |
| `Ctrl-L` triggers full refresh | `welcome_dismissed-on-first-key-ctrl-l.asm` (exercises Ctrl-L through the dispatch hook); full-refresh path also exercised by `render_full-marks-all-dirty.asm` |
| `:q` refused on dirty buffer / `:q!` forces quit | `exline_q-clean-buffer.asm`, `exline_q-dirty-buffer.asm`, `exline_q-bang-force.asm` |
| `:w filename` round-trip save | `fileio_save-roundtrip.asm`, `fileio_save-crlf-roundtrip.asm` |

All tests passing per `sprint-status.yaml` history (most recent run: 283 PASS / 1 deliberate-fail at Story 4.5 close). No regressions introduced by this story (doc-only, 0 B production-code delta).

**Final README.md line count.** 234 lines post-iteration-1 (originally 379; trimmed per Ant's "keep it light, keep it pithy" directive). Below the Dev Notes' 250-400 band, which is fine — the band was advisory, not a floor.

**Q-pin decisions (resolved during draft; deferred to Ant for review per AC8 step 2):**

- **Q1 (cheatsheet at top):** ADOPTED YES — `## Cheatsheet` section immediately after the pitch, before Quick-start. ~30 lines of compact ASCII-aligned reference for the experienced vi user.
- **Q2 (screenshots):** ADOPTED NO. Text descriptions of welcome + status line are sufficient.
- **Q3 (omissions before/after Commands):** ADOPTED AFTER. Users come for what VIBE does; what it doesn't is secondary context.
- **Q4 (link to PRD/arch/stories):** ADOPTED architecture.md only. No links to individual story files (too transient). PRD not linked. `deferred-work-triage-2026-05-19.md` referenced inline in the "Not yet" subsection for traceability, not linked (path is in-prose).
- **Implicit Q5 (`$a` per-line nuance from `[[feedback_uat_trace_cursor]]`):** Surfaced briefly in the Edits prose ("`a` only places the cursor past end-of-line if the cursor was already on the last line at end-of-line; on intermediate lines, `$a` places the cursor at the LF") AND as a Deviations row. Both placements keep the warning discoverable for users hitting the footgun.

**Ant-feedback iteration log (Task 8).**

*Iteration 2 acceptance (2026-05-19):* Ant: "that is absolutely perfect!" — final acceptance after one iteration. Story Status flipped review → done.

*Iteration 1 (2026-05-19):* Ant: "great start! remember it's a user-facing doc. please remove all references to 'design rationale', 'layered architecture', 'implementation sequence', architecture links, FRs, MVPs, any reference to source (*.asm) files. Keep it light. Keep it pithy. People just want a quick ref for how to edit stuff without having to read War and Peace."

Response: README rewritten end-to-end. 379 → 234 lines. Changes:
- Pitch trimmed to one sentence; dropped the architecture-link paragraph.
- Dropped the FR column from every Commands / Modes table. Examples in prose dropped FR citations.
- Dropped source-provenance column from the Vi deviations / Limits tables.
- Dropped all NFR / AR / BA citations from the Hacking section.
- Dropped the Repo layout subsection entirely — redundant for a user-facing doc.
- Rewrote "Out of scope for MVP" omissions into a single prose paragraph naming the keys / commands — much denser.
- Merged "Park-able backlog" into the prose list rather than calling out a separate section; user doesn't care whether it's "never" or "not yet".
- Collapsed the verbose mode paragraphs into a 4-bullet description + transitions table + status-line table.
- Hacking section reduced to a single code block of make targets + a one-line prerequisites paragraph.
- Verification: grep shows ZERO matches for `FR[0-9]|NFR[0-9]|MVP|architecture\.md|AR[0-9]|BA[0-9]|src/.*\.asm|inc/.*\.inc` across the new README.

**Note on AC7 deviation:** AC7 originally specified "Link to architecture.md preserved (currently line 5 and line 48)". Ant's iteration-1 directive explicitly overrides this — architecture.md link removed per user intent ("remove ... architecture links"). Recording the deviation for traceability.

### File List

- `README.md` (rewrite — 48 → 379 lines)
- `_bmad-output/implementation-artifacts/4-6-comprehensive-user-docs-readme.md` (this file — task checkboxes, Dev Agent Record, File List, Change Log, Status flipped ready-for-dev → review)
- `_bmad-output/implementation-artifacts/sprint-status.yaml` (story status flip + last_updated journal entry)

## Change Log

| Date       | Author | Change                                                                       |
|------------|--------|------------------------------------------------------------------------------|
| 2026-05-19 | Amelia | Story 4.6 scoped ad-hoc by Ant. Tech-writer story (recommended agent: Paige). Restructures the 48-line dev-loop README.md into a User Guide (modes / commands / vi deviations / limits / quick-start) + a preserved Hacking section. 0 B production-code impact; AC8 review process is round-trip with Ant after self-grep verification. Ready for dev. |
| 2026-05-19 | Amelia | Story 4.6 dev pass complete (executed via dev-story rather than Paige; doc work is mechanical). README rewritten in one pass — 48 → 379 lines. Self-grep verification (Task 7) caught one discrepancy: initial draft claimed `:q` refusal surfaces `buffer modified`; grep confirmed `msg_buffer_modified` is dead code (0 consumers across src/) and the actual refusal message is `no write since last change` (`msg_no_write`). README corrected. Vi-omission audit (Task 10) returned ZERO matches for `.` / `f` / `F` / `t` / `T` / `e` / `%` / `H` / `M` / `L` / `r` / `R` / `s` / `S` / `m` / `q` / `?` / Ctrl-D / Ctrl-U in dispatch.asm — all documented omissions confirmed absent. NORMAL-mode `~` confirmed unbound (`~` appears only in dispatch_visual:816). Behavioural spot-check (Task 9) pinned 5 keystroke claims to existing test/cases/*.asm. Status ready-for-dev → review; awaiting Ant per AC8 step 2. **Findings for Ant:** `msg_buffer_modified` is a defined-but-unused label in `src/statusln.asm:318` (29 B incl. terminator) — candidate for a future NFR9 hygiene sweep, out of scope here. |
| 2026-05-19 | Amelia | Ant accepted iteration 1 verbatim: "that is absolutely perfect!" Story Status flipped review → done; sprint-status.yaml flipped to done; commit pending Ant per the project's "single commit pending Ant" convention. |
| 2026-05-19 | Amelia | Iteration 1 per Ant: "user-facing doc, remove design-rationale / layered-architecture / implementation-sequence / architecture-link / FR / MVP / src-asm-file references. Keep it light and pithy." README rewritten 379 → 234 lines. Every FR column dropped from Commands and Modes tables; provenance columns dropped from Vi deviations and Limits tables; NFR/AR/BA citations dropped from Hacking; Repo-layout subsection dropped; "Out of scope for MVP" rephrased to a single prose paragraph naming each unsupported key/command; park-able backlog merged into omissions prose. Architecture.md link removed (deviates from AC7's "Link to architecture.md preserved" — user directive overrides; recorded in Dev Agent Record). Grep verification: zero matches for `FR[0-9]\|NFR[0-9]\|MVP\|architecture\.md\|AR[0-9]\|BA[0-9]\|src/.*\.asm\|inc/.*\.inc` across the rewritten README. Status stays `review`; awaiting Ant's next pass. |
