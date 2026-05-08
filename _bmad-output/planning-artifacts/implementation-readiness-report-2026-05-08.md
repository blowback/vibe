---
project: vibe
date: 2026-05-08
stepsCompleted: [step-01-document-discovery, step-02-prd-analysis, step-03-epic-coverage-validation, step-04-ux-alignment, step-05-epic-quality-review, step-06-final-assessment]
overallStatus: READY
issuesCount:
  critical: 0
  major: 0
  minor: 11
assessor: Implementation Readiness workflow (bmad-check-implementation-readiness)
filesIncluded:
  - _bmad-output/planning-artifacts/prd.md
  - _bmad-output/planning-artifacts/architecture.md
  - _bmad-output/planning-artifacts/epics.md
filesMissing:
  - ux-design (no separate UX document; UX assumed embedded in PRD/architecture per user confirmation; UX alignment assessed in Step 4)
totalFRs: 52
totalNFRs: 18
frCoverage: 52/52
nfrCoverage: 18/18
coveragePercent: 100
---

# Implementation Readiness Assessment Report

**Date:** 2026-05-08
**Project:** vibe

## Step 1 — Document Discovery

### Inventory

| Type         | Format | Path                                                       | Size  | Modified         |
|--------------|--------|------------------------------------------------------------|-------|------------------|
| PRD          | whole  | `_bmad-output/planning-artifacts/prd.md`                   | 41 KB | 2026-05-08 20:37 |
| Architecture | whole  | `_bmad-output/planning-artifacts/architecture.md`          | 76 KB | 2026-05-08 22:16 |
| Epics        | whole  | `_bmad-output/planning-artifacts/epics.md`                 |100 KB | 2026-05-08 23:00 |
| UX           | —      | not present                                                | —     | —                |

- No sharded variants found.
- No duplicates requiring resolution.
- No standalone `stories/` directory; stories are expected inline in `epics.md`.

### User-confirmed scope
- Proceed without a separate UX document; rely on PRD/architecture for UX coverage.
- `epics.md` is the canonical source for epics + stories.

## Step 2 — PRD Analysis

### Functional Requirements

#### Editor Lifecycle
- **FR1:** User can launch VIBE with no arguments and begin editing an empty buffer.
- **FR2:** User can launch VIBE with a filename argument and begin editing the contents of that file.
- **FR3:** User can quit VIBE, returning control to the CCP.

#### File Operations
- **FR4:** User can save the current buffer to its current filename (`:w`).
- **FR5:** User can save the current buffer to a different filename (`:w filename`).
- **FR6:** User can open a different file, replacing the current buffer (`:e filename`).
- **FR7:** User can save and quit in one step (`:wq`).
- **FR8:** User can quit without saving, abandoning unsaved changes (`:q!`).
- **FR9:** VIBE resolves bare filenames (no drive prefix) to drive B:.
- **FR10:** VIBE accepts explicit drive-letter prefixes in filenames (e.g. `A:foo.fs`).
- **FR11:** VIBE refuses to load files exceeding the gap buffer capacity, surfacing the refusal in the status line without modifying the current buffer.

#### Modal Editing
- **FR12:** VIBE starts in normal mode.
- **FR13:** User can enter insert mode from normal mode.
- **FR14:** User can enter command mode (ex-line entry) from normal mode via `:`.
- **FR15:** User can enter visual mode from normal mode.
- **FR16:** User can return to normal mode from any other mode via `Esc`.
- **FR17:** VIBE displays the current mode in the status line.

#### Cursor Motion
- **FR18:** User can move the cursor one character left or right (`h`, `l`).
- **FR19:** User can move the cursor one line up or down (`k`, `j`).
- **FR20:** User can move to the next or previous word (`w`, `b`).
- **FR21:** User can move to the start or end of the current line (`0`, `$`).
- **FR22:** User can move to the first or last line of the buffer (`gg`, `G`).
- **FR23:** User can prefix any motion with a count for repetition (e.g. `5j`, `12G`, `3w`).

#### Text Editing
- **FR24:** User can insert text before the cursor (`i`).
- **FR25:** User can insert text after the cursor (`a`).
- **FR26:** User can open a new line below the current line and enter insert mode (`o`).
- **FR27:** User can open a new line above the current line and enter insert mode (`O`).
- **FR28:** User can delete the character under the cursor (`x`).
- **FR29:** User can delete the current line (`dd`).
- **FR30:** User can delete a word (`dw`).
- **FR31:** User can yank (copy) the current line (`yy`).
- **FR32:** User can paste yanked or deleted text (`p`).

#### Visual Mode
- **FR33:** User can select text by character (visual character mode).
- **FR34:** User can select whole lines (visual line mode).
- **FR35:** User can select rectangular blocks (visual block mode).
- **FR36:** User can apply delete, yank, and change operators to a visual selection (`d`, `y`, `c`).
- **FR37:** User can shift a visual selection right or left (`>`, `<`).
- **FR38:** User can toggle case of a visual selection (`~`).

#### Operator + Motion Composition
- **FR39:** User can compose any operator with any motion to apply the operator over the motion's range (e.g. `dw`, `d$`, `c5w`, `y3j`).
- **FR40:** User can prefix composed operator/motion commands with a count (e.g. `5dd`, `2dw`, `3yy`).

#### Search
- **FR41:** User can initiate a forward literal search (`/pattern`).
- **FR42:** User can repeat the most recent search (`n`).
- **FR43:** Search wraps from end-of-buffer to start; VIBE reports the wrap in the status line.
- **FR44:** VIBE reports "pattern not found" in the status line when no match exists in the buffer.

#### Undo
- **FR45:** User can undo the most recent edit (`u`).
- **FR46:** VIBE reports in the status line when undo is unavailable (e.g., operation exceeded undo buffer).

#### Display & Feedback
- **FR47:** VIBE renders only changed regions of the screen during normal editing (full-screen redraws happen only on initial draw or explicit refresh).
- **FR48:** User can force a full-screen refresh (`Ctrl-L`).
- **FR49:** VIBE displays a status line on row 24 reflecting current mode, filename, and the most recent message or error.

#### Error Handling & Robustness
- **FR50:** VIBE responds to unsupported commands as a no-op, with audible/visual feedback in the status line (or beep), leaving editor state unchanged.
- **FR51:** VIBE surfaces every CP/M file-I/O failure (disk full, write-protect, file not found, drive offline) in the status line without entering an inconsistent state.
- **FR52:** VIBE never silently truncates or discards user data on save (errors are reported; the buffer remains dirty until either a successful save or an explicit `:q!`).

**Total FRs: 52**

### Non-Functional Requirements

#### Performance
- **NFR1:** Incremental rendering. During normal editing, VIBE emits to the terminal only the cells whose content has changed since the previous frame. Full-screen redraws are reserved for initial draw and explicit `Ctrl-L` refresh.
- **NFR2:** Sustained typing throughput. VIBE absorbs continuous insert-mode typing at typical human speeds (≥10 chars/sec) without dropping or coalescing keystrokes. The serial bandwidth and terminal latency are the floor on perceived responsiveness, not VIBE's input loop.
- **NFR3:** Predictable cursor-motion latency. Single-character motion commands (`h`, `j`, `k`, `l`, `w`, `b`) complete within one input-loop iteration. Counted motions (`5j`, `12G`) and large-range operators (`d$`, `dG`) may take proportionally longer but remain interactive (no perceptible freeze).
- **NFR4:** Esc disambiguation budget. The bare-`Esc` vs. arrow-key timeout uses the 50 Hz tick. Target: 1–2 ticks (20–40 ms). Tunable via a source equate; chosen value is empirically validated against real hardware before release.

#### Reliability
- **NFR5:** No crashes. VIBE never enters a state requiring a CP/M warm reboot for the user to recover. Any unexpected condition is caught, reported in the status line, and editor state remains consistent.
- **NFR6:** No silent data loss. Every save either succeeds completely or surfaces an explicit error in the status line, leaving the buffer marked dirty. The user is never under the impression that their work was saved when it wasn't.
- **NFR7:** Screen state recoverability. If the shadow buffer ever desyncs from actual terminal state, `Ctrl-L` (full redraw) restores consistency. No accumulated drift survives a refresh.
- **NFR8:** BDOS error handling completeness. Every BDOS file-I/O call checks its return value; no return code is ignored. Unexpected codes abort the current operation cleanly with a status-line message.

#### Resource Consumption
- **NFR9:** Code size budget. Tentative ceiling: ~3 KB of Z80 code. Significant overruns (≥ ~25%) trigger redesign rather than budget inflation; safety paths (NFR5–NFR8) are exempt — accept overruns rather than skip safety.
- **NFR10:** TPA fit. Total static footprint (code + data + screen shadow + undo buffer + gap buffer) fits within the TPA (`0x0100..0xD7FF`, ~54 KB).
- **NFR11:** Single artifact. VIBE ships as exactly one CP/M `.COM` file. No data files, no helper utilities, no install step.
- **NFR12:** Static allocation only. No runtime allocator. All buffers are sized at assembly time via the named source equates.

#### Compatibility & Portability
- **NFR13:** Single platform target. Feersum MicroBeast running CP/M 2.2 with a VT52-capable terminal at 80×24. Other Z80 platforms, other CP/M versions, other terminals, and other geometries are out of scope.
- **NFR14:** Fixed toolchain. Builds with sjasmplus 1.23.0 on a Linux host. Other assemblers or sjasmplus versions are not supported.
- **NFR15:** Standard CP/M 2.2 BDOS only. No use of CP/M 3.x extensions, no MicroBeast-specific BDOS calls. The console path uses BIOS direct (`BIOS_CONIN/CONINST/CONOUT`); this is a deliberate exception to "BDOS only".

#### Maintainability
- **NFR16:** Knob centralization. All compile-time tunables (buffer sizes, screen dimensions, timeout counts, etc.) are defined as named equates in one place. No magic numbers buried in motion handlers.
- **NFR17:** Mode/operator decoupling. The dispatch tables for modes and the operator+motion composition layer are decoupled enough that adding a Growth-tier feature (new motion, new ex command, new visual operator) does not require restructuring existing code.
- **NFR18:** Build reproducibility. `make` from a clean tree produces a byte-identical `vibe.com`. No timestamps, no host-path leakage, no randomness in the output.

#### Explicitly Not Applicable (PRD-declared)
- Security, Scalability, Accessibility, Integration (beyond CP/M FCB I/O which is a platform constraint), Internationalization.

**Total NFRs: 18**

### Additional Requirements (constraints, architectural commitments, named equates)

#### Platform constraints (from `## Platform Constraints` — these gate implementation correctness)
- **PC1:** Z80 with interrupts enabled; keyboard scanner + 50 Hz timer tick. VIBE may opportunistically use the tick (cursor blink, Esc disambiguation) but must not require it for correctness.
- **PC2:** Memory layout — zero page (`0x0000..0x00FF`) follows CP/M conventions; TPA is `0x0100..0xD7FF` (~54 KB); CCP/BDOS/BIOS at `0xD800+` must not be stomped; warm boot on `:q` returns control to CCP cleanly.
- **PC3:** Display fixed at 80×24; status line is row 24, editable area rows 1..23. No resize events.
- **PC4:** Terminal is classic VT52, full command set; cursor positioning via `ESC Y row col` (offset by `0x20`); no color/bold/underline/scroll regions.
- **PC5:** Every screen-bound byte goes through `BIOS_CONOUT`; no memory-mapped video.
- **PC6:** Input via BIOS direct (`BIOS_CONINST`, `BIOS_CONIN`); BDOS console functions deliberately bypassed to own Ctrl-C/Ctrl-Z semantics and reduce latency.
- **PC7:** VT52 arrow keys arrive as `ESC A/B/C/D`; bare `Esc` distinguished by timeout (NFR4).
- **PC8:** Default drive is B: (RAM disk); A: read-only by default; no fallback search across drives; user is responsible for promoting durable work via the interactive `WRITE.COM` utility (not invocable by VIBE).
- **PC9:** Filenames are 8.3 uppercase; VIBE normalizes lowercase user input.
- **PC10:** File I/O is FCB-based BDOS; 128-byte sectors; text EOF marker `0x1A` (Ctrl-Z) — read up to first `0x1A` on load, write `0x1A` plus padding on save.
- **PC11:** User numbers not used; VIBE operates on whatever user number CCP runs under.
- **PC12:** Assembler is sjasmplus 1.23.0; build system is Make; host is Linux; output is single `.COM` file; transfer via SLIDE utility (dev-loop ergonomics, not a product requirement).
- **PC13:** Non-portability is explicit — other Z80 platforms, non-VT52 terminals, other geometries, CP/M 3.x/MP/M, banked memory, non-serial console paths are out of scope.

#### Internal architecture commitments (from `## Internal Architecture` — pinned design decisions)
- **AC1:** TPA layout from low to high: code (~3 KB tentative) → static data → gap buffer (capped) → reserved pool → BDOS at `0xD7FF+`.
- **AC2:** `GAP_BUFFER_MAX` is a single source equate (initial ~32 KB); files exceeding the cap are refused at load time (FR11).
- **AC3:** Reserved pool between gap-buffer-top and BDOS is uncommitted; future features (paste registers, search history, multi-level undo, macro recording, multi-buffer) carve from this. MVP touches none.
- **AC4:** Static data is fixed-size at assembly time; no dynamic allocation inside VIBE.
- **AC5:** Gap buffer floats between end-of-static-data and reserved pool; gap tracks cursor; size fixed at startup; no grow/shrink; invariant `[before_gap][gap][after_gap]`.
- **AC6:** Single-level undo: fixed 256-byte undo buffer; operation kinds INSERTION / DELETION / REPLACEMENT (composed); operations exceeding the buffer report "undo not possible — too large" (FR46); `u u` (undo of undo) deferred.
- **AC7:** Mode state machine: one byte at fixed address; modes NORMAL/INSERT/COMMAND/VISUAL; visual sub-mode in a separate byte; table-driven dispatch (one key→handler table per mode, 256 entries or sparse switch); explicit per-mode enter/exit hooks update status line. Rejected: state-machine generators, fancy guards, hierarchical state machines.
- **AC8:** Command parser uses vi's two-stage operator/motion structure; 16-bit count accumulator (leading `0` is motion, not count); pending-operator byte; doubled-operator detection (`dd`, `yy`); ex command line in a fixed ~64-byte buffer; search prompt structurally identical (separate dispatch).
- **AC9:** Render pipeline: 1920-byte shadow buffer (80×24, one byte per cell, no attributes); per-cell diff against gap-buffer-derived target; emit contiguous horizontal runs prefixed by one `ESC Y row col`; status line rendered separately by same diff approach; whole-screen redraw only on initial draw, `Ctrl-L`, or sub-shell-style returns (none in MVP); cursor repositioned after each render step.
- **AC10:** Search algorithm is literal byte-for-byte substring match (no regex); forward-only in MVP (`?` is Growth tier); start position is one past cursor; wrap end-to-start with status-line "search wrapped"; "pattern not found" if still no match; pattern buffer ~64 bytes; case-sensitive (vi default).
- **AC11:** File I/O — read uses BDOS open + sequential-read into DMA at `0x0080`, copies to before-gap region, reads to BDOS EOF or first `0x1A`; initial cursor at start of file, gap at end; write opens BDOS 19/22, walks gap buffer in two halves, fills DMA in 128-byte chunks, appends `0x1A` plus padding to next 128-byte boundary, closes; **direct (unsafe) write — no temp file, no rename dance** (documented limitation: a crashed write may leave a half-written file); default drive is B:.

#### Source equates worth naming (from `## Source Equates Worth Naming` — must exist in code as named constants)
- `GAP_BUFFER_MAX` — gap buffer ceiling (initial ~32 KB)
- `UNDO_BUFFER_SIZE` — undo storage (initial 256 bytes)
- `STATUS_LINE_WIDTH` — 80
- `EX_COMMAND_BUFFER` — ex/search command-line length (initial 64 bytes)
- `SEARCH_PATTERN_BUFFER` — last-search storage (initial 64 bytes)
- `SCREEN_ROWS` — 24
- `SCREEN_COLS` — 80
- `EDITABLE_ROWS` — 23

#### Risk-driven implementation requirements (from `## Risks` — mitigations are constraints on plan)
- **R1 (Esc/arrow-key timing):** Prototype the input layer first, in isolation, with a synthetic test harness; tune the timeout against real hardware latency before any other feature is built.
- **R2 (Gap buffer correctness):** Unit test gap buffer logic in a host-side simulator (sjasmplus → Z80 emulator → assertions); do not rely on manual on-device testing for this layer.
- **R3 (Diff renderer drift):** `Ctrl-L` is the explicit user escape hatch (FR48); defensively re-emit cursor position before every diff-based render to keep cursor desync from compounding.
- **R4 (Crash safety vs. size budget):** Budget is tentative; accept overruns rather than skip safety checks. Size discipline lives in non-safety paths.
- **R5 (CP/M file I/O edge cases):** Every BDOS call has a return-value check; any unexpected return surfaces in the status line and aborts the current operation cleanly.
- **R6 (Plateau-at-90%):** No formal mitigation beyond the native-workflow goal being self-enforcing. Surveillance, not a planned task.
- **R7 (Feature creep):** Explicit MVP gate — Growth-tier features forbidden until every MVP feature works on real hardware.
- **R8 (Esc-key UX abandonment):** Build input first, tune it, prove it feels good before investing in features that depend on it. (Reinforces R1.)

#### Scope tiers (informational — implementation scope is MVP-only)
- **MVP:** the brief's full feature set is the contract; no smaller subset is acceptable. Items can be dropped only if they prove disproportionately expensive.
- **Growth (post-MVP, not in this plan):** VT100 output mode; multi-level undo; `:s/old/new/`; marks/jumps (`m`, `'`, `` ` ``); macros (`q`); motions `f/F/t/T`, `%`, paragraph/section; multiple buffers; configurable keymap.
- **Vision (future):** VideoBeast GPU integration; direct AntForth integration (`:!`); editor-assisted Forth debugging.

### PRD Completeness Assessment

**Strengths:**
- Requirements are numbered, atomic, and testable (FR1–FR52, NFR1–NFR18).
- Architecture is pinned in the PRD itself (TPA layout, gap-buffer model, mode dispatch, render pipeline, file I/O contract) — avoids the usual gap between PRD and architecture drift.
- Named source equates list is concrete and traceable to NFR16 (knob centralization).
- Scope tiers (MVP/Growth/Vision) are explicit; MVP gate is named (R7) preventing creep.
- Non-applicable NFR categories are explicitly listed (Security, Scalability, Accessibility, Integration, i18n) — reduces ambiguity in coverage assessment.
- Direct (unsafe) write is acknowledged as a documented limitation rather than handwaved.

**Potential gaps to verify in epic coverage (Step 3+):**
- **Initial draw / startup sequence:** FR12 says "VIBE starts in normal mode" but no explicit FR covers the initial full-screen draw, status-line initialization, or terminal-mode setup (entering VT52 mode, clearing the screen) — captured in AC9 ("whole-screen redraw on initial draw") but not as a numbered FR.
- **`Esc` disambiguation correctness:** NFR4 sets the budget; AC7/AC8 assume the dispatch resolves it; but no explicit FR states "bare `Esc` returns to normal mode without delay perceptible to the user" beyond FR16.
- **Status line content composition:** FR49 says the status line reflects "current mode, filename, and most recent message or error" but does not specify dirty-buffer indicator, cursor position, line count, or what fields take precedence on collision. May be intentional minimalism — flag for confirmation when checking epic coverage.
- **Visual-mode entry sub-modes:** FR15 covers "enter visual mode" but FR33–FR35 implicitly require three separate entry triggers (typically `v` / `V` / `Ctrl-V`); the PRD does not name the triggering keys for character/line/block visual sub-modes.
- **Counts in visual mode:** FR40 covers counts on composed operator/motion in normal mode, but visual-mode operator application (FR36) does not explicitly state whether counts apply.
- **`p` paste semantics:** FR32 "paste yanked or deleted text" — does not specify before-cursor vs. after-cursor placement, or whole-line vs. character paste behavior (vi's `p`/`P` distinction). The PRD lists only `p`, not `P`.
- **Character classes for `w`/`b`:** FR20 names word motion but does not define what constitutes a word boundary (whitespace-delimited vs. vi's punctuation-aware boundaries). Implementation choice will materially affect user expectations.
- **Buffer dirty tracking:** FR8 (`:q!`) and FR52 imply dirty tracking but no FR explicitly mandates that `:q` (without `!`) refuses to quit on a dirty buffer.
- **Single-step parsing of `:e <file>` while dirty:** No FR specifies whether `:e` on a dirty buffer prompts, refuses, or silently abandons changes.
- **`Esc` from command/search prompt:** AC8 says "Editing within the command line supports backspace and `Esc` (cancel) at minimum" — implied but not promoted to an FR.
- **Counts on `u`:** FR45 covers undo; per single-level semantics (AC6), `5u` is undefined. Worth confirming whether epics handle this.
- **`Ctrl-L` from any mode:** FR48 implies normal-mode invocation; behavior in insert/visual/command modes is not specified.

**Verdict:** The PRD is unusually thorough for a hobbyist project — most "completeness" gaps above are minor specification-tightening items, not missing capabilities. Coverage assessment proceeds.

## Step 3 — Epic Coverage Validation

### Epic structure

The epics document (`epics.md`) is decomposed into **3 epics, 33 stories**:

- **Epic 1 — Editor Foundations & On-Hardware Bring-Up** (12 stories, 1.1–1.12): build skeleton, all shared headers (`equates.inc`, `bios.inc`, `bdos.inc`, `vt52.inc`, `modes.inc`, `state.inc`), BDOS_CALL macro + status funnel, test harness, gap buffer, input/Esc disambiguation, mode dispatch (binary search), command parser, render pipeline, init/teardown + on-hardware smoke test.
- **Epic 2 — Native Authoring Workflow** (13 stories, 2.1–2.13): ex command-line + `:q`/`:q!`, `:e` load, launch-with-filename, `:w`/`:w filename`/`:wq`, basic motions (h/j/k/l), word/line/buffer motions (w/b/0/$/gg/G), counted motions, insert mode (i/a/o/O), `x` delete, `dd`/`yy`, composed operator+motion, `p` paste, `u` undo.
- **Epic 3 — Iterate, Search & Region Operations** (8 stories, 3.1–3.8): `/pattern`, `n` repeat with wrap, visual character/line/block modes, visual operators (d/y/c), visual shift (>/<), visual case toggle (~).

Epics doc also carries an explicit **FR Coverage Map** (lines 192–245) and an **Additional Requirements** section (AR1–AR26) capturing architectural commitments lifted from `architecture.md`.

### Coverage matrix (FR-by-FR cross-check)

Each row was verified against the relevant story's acceptance criteria — not just the document's own coverage map.

| FR | PRD Requirement (verbatim head) | Epic / Story | AC Verified | Status |
|---|---|---|---|---|
| FR1 | Launch with no args, empty buffer | Epic 1 (1.12) + Epic 2 (2.4 final-coverage AC) | 1.12 stub launch path; 2.4 AC "FR1 final coverage (launch with no args, save creates file)" | ✓ Covered |
| FR2 | Launch with filename argument | Epic 2 (2.3) | 2.3 AC: `vibe foo.fs` parses default FCB, calls `fileio_load` | ✓ Covered |
| FR3 | Quit, return to CCP | Epic 2 (2.1) | 2.1 AC: `:q` runs `init_teardown` when clean | ✓ Covered |
| FR4 | `:w` save to current filename | Epic 2 (2.4) | 2.4 AC: `cmd_write` no-arg path | ✓ Covered |
| FR5 | `:w filename` save-as | Epic 2 (2.4) | 2.4 AC: `cmd_write` with arg, updates `filename_buffer` | ✓ Covered |
| FR6 | `:e filename` open different file | Epic 2 (2.2) | 2.2 AC: `cmd_edit` clean & dirty paths, `:e!` force | ✓ Covered |
| FR7 | `:wq` save and quit | Epic 2 (2.4) | 2.4 AC: save runs first, `init_teardown` only on success | ✓ Covered |
| FR8 | `:q!` force quit | Epic 2 (2.1) | 2.1 AC: unconditional `init_teardown` | ✓ Covered |
| FR9 | Bare filename → drive B: | Epic 2 (2.2, 2.3) | 2.2 AC: filename normalised, bare → B: | ✓ Covered |
| FR10 | Drive-letter prefix accepted | Epic 2 (2.2, 2.3) | 2.2 AC: `A:foo.fs` → drive A:; 2.3 AC: `vibe a:bar.txt` | ✓ Covered |
| FR11 | Refuse oversize file at load | Epic 2 (2.2, 2.3) | 2.2 AC: file-too-large path → `msg_file_too_large`, buffer untouched | ✓ Covered |
| FR12 | Start in normal mode | Epic 1 (1.12) | 1.12 AC: `init_cold_start` sets `mode_byte = MODE_NORMAL` | ✓ Covered |
| FR13 | Enter insert from normal | Epic 1 (1.9 transition) + Epic 2 (2.8 behavior) | 1.9: `i` mode-change handler; 2.8: full insert behavior | ✓ Covered |
| FR14 | Enter command (`:`) from normal | Epic 1 (1.9 transition) + Epic 2 (2.1 ex-line) | 1.9: `:` mode-change; 2.1: full `ex_buffer` infra | ✓ Covered |
| FR15 | Enter visual from normal | Epic 1 (1.9 transition) + Epic 3 (3.3 char / 3.4 line / 3.5 block) | 1.9: `v` mode-change; 3.3–3.5: full visual sub-modes | ✓ Covered |
| FR16 | Esc returns to normal from any mode | Epic 1 (1.9) | 1.9 AC: Esc handler in INSERT/COMMAND/VISUAL tables sets `MODE_NORMAL` | ✓ Covered |
| FR17 | Status line displays current mode | Epic 1 (1.5, 1.11, 1.12) | 1.5 status_set_message; 1.11 status_render; 1.12 AC: status shows "NORMAL"/"INSERT" | ✓ Covered |
| FR18 | `h` / `l` cursor motion | Epic 2 (2.5) | 2.5 AC: `motion_h`/`motion_l` with intra-line clamp | ✓ Covered |
| FR19 | `j` / `k` cursor motion | Epic 2 (2.5) | 2.5 AC: `motion_j`/`motion_k` with same-column + clamp | ✓ Covered |
| FR20 | `w` / `b` word motion | Epic 2 (2.6) | 2.6 AC: `motion_w`/`motion_b` with BH1 word-boundary classifier | ✓ Covered |
| FR21 | `0` / `$` line-start / line-end | Epic 2 (2.6) | 2.6 AC: `motion_0`/`motion_dollar` | ✓ Covered |
| FR22 | `gg` / `G` first / last line | Epic 2 (2.6) | 2.6 AC: `motion_G` (with optional count) + `motion_gg` via prefix | ✓ Covered |
| FR23 | Counted motions | Epic 2 (2.7) | 2.7 AC: count_accumulator handoff to all motion handlers; clamp tests | ✓ Covered |
| FR24 | `i` insert before cursor | Epic 2 (2.8) | 2.8 AC: `i` enters INSERT, cursor unchanged | ✓ Covered |
| FR25 | `a` insert after cursor | Epic 2 (2.8) | 2.8 AC: `a` advances cursor by 1, enters INSERT | ✓ Covered |
| FR26 | `o` open new line below | Epic 2 (2.8) | 2.8 AC: cursor → EOL, newline inserted, INSERT entered | ✓ Covered |
| FR27 | `O` open new line above | Epic 2 (2.8) | 2.8 AC: cursor → BOL, newline inserted before, INSERT entered | ✓ Covered |
| FR28 | `x` delete character | Epic 2 (2.9) | 2.9 AC: byte under cursor removed; counted variant | ✓ Covered |
| FR29 | `dd` delete line | Epic 2 (2.10) | 2.10 AC: doubled-operator detection → `op_dd` | ✓ Covered |
| FR30 | `dw` delete word | Epic 2 (2.11) | 2.11 AC: composed `dw` deletes word range, yank holds it | ✓ Covered |
| FR31 | `yy` yank line | Epic 2 (2.10) | 2.10 AC: `op_yy` copies line to yank register | ✓ Covered |
| FR32 | `p` paste | Epic 2 (2.12) | 2.12 AC: branches on `yank_kind` (CHAR/LINE/BLOCK); counted `3p` | ✓ Covered |
| FR33 | Visual character mode | Epic 3 (3.3) | 3.3 AC: `v` enters MODE_VISUAL with VIS_CHAR | ✓ Covered |
| FR34 | Visual line mode | Epic 3 (3.4) | 3.4 AC: `V` enters with VIS_LINE; line-extent semantics | ✓ Covered |
| FR35 | Visual block mode | Epic 3 (3.5) | 3.5 AC: `Ctrl-V` enters with VIS_BLOCK; BH3 jagged-line clamp | ✓ Covered |
| FR36 | Visual `d`/`y`/`c` operators | Epic 3 (3.6) | 3.6 AC: per-sub-mode range computation; yank kind set | ✓ Covered |
| FR37 | Visual `>`/`<` shift | Epic 3 (3.7) | 3.7 AC: per-line indent/dedent over selection range | ✓ Covered |
| FR38 | Visual `~` case toggle | Epic 3 (3.8) | 3.8 AC: alphabetic case flip across selection; BH3 for block | ✓ Covered |
| FR39 | Operator+motion composition | Epic 2 (2.11) | 2.11 AC: pending-op + motion-preview applies op to range; covers d/y/c/>/< | ✓ Covered |
| FR40 | Counted operator+motion | Epic 2 (2.11) + (2.10 for dd/yy counted) | 2.11 AC: c5w, y3j; 2.10 AC: 3dd, 5yy | ✓ Covered |
| FR41 | Forward literal search `/pattern` | Epic 3 (3.1) | 3.1 AC: `/` prompt, search_pattern, search_forward_from(cursor+1) | ✓ Covered |
| FR42 | `n` repeat search | Epic 3 (3.2) | 3.2 AC: `n` re-walks from cursor+1 with wrap | ✓ Covered |
| FR43 | Search wrap with status notice | Epic 3 (3.1, 3.2) | 3.2 AC: `msg_search_wrapped` on wrap-then-found | ✓ Covered |
| FR44 | "pattern not found" status | Epic 3 (3.1, 3.2) | 3.2 AC: `msg_pattern_not_found` if no match after wrap | ✓ Covered |
| FR45 | `u` undo most recent edit | Epic 2 (2.13) | 2.13 AC: replay inverse-op for INSERTION/DELETION/REPLACEMENT | ✓ Covered |
| FR46 | Undo unavailable status | Epic 2 (2.13) | 2.13 AC: `msg_nothing_to_undo` / `msg_undo_too_large` | ✓ Covered |
| FR47 | Diff-based incremental render | Epic 1 (1.11) | 1.11 AC: per-row dirty bitmap + cell-diff against shadow_buffer | ✓ Covered |
| FR48 | `Ctrl-L` full refresh | Epic 1 (1.11, 1.12) | 1.11 AC: `render_full` marks all dirty + emits; 1.12 UAT | ✓ Covered |
| FR49 | Status line on row 24 | Epic 1 (1.5, 1.11) | 1.5 status module + STATUS_LINE_WIDTH=80; 1.11 status_render at row 24 | ✓ Covered |
| FR50 | No-op on unsupported commands | Epic 1 (1.9, 1.12) | 1.9 AC: per-mode unbound-key handlers beep/no-op; 1.12 UAT | ✓ Covered |
| FR51 | I/O failures surface in status | Epic 2 (2.2, 2.4) | BDOS_CALL macro funnel established 1.4; 2.2/2.4 ACs verify all I/O paths | ✓ Covered |
| FR52 | No silent data loss | Epic 2 (2.4) | 2.4 AC: write-protect/disk-full leaves `buffer_dirty != 0`, status indicates failure | ✓ Covered |

### NFR coverage cross-check

| NFR | Verified location | Status |
|---|---|---|
| NFR1 incremental render | Story 1.11 (`render_diff`); idle-frame test "zero content bytes emitted" | ✓ Covered |
| NFR2 sustained typing ≥10 cps | Story 1.8 ("no keystrokes dropped at typical human speeds"); Story 2.8 implicit via insert path | ✓ Covered |
| NFR3 cursor latency single-frame | Story 1.11 + 2.5 + 2.6 ("within one render frame") | ✓ Covered |
| NFR4 Esc disambig 20–40 ms | Story 1.8 (`ESC_TIMEOUT_TICKS` default 2 ticks); UAT-tunable | ✓ Covered |
| NFR5 no crashes | Stories 1.9, 1.12 ("no crashes, no terminal corruption"); BDOS_CALL macro 1.4 pervasive | ✓ Covered |
| NFR6 no silent data loss | Story 2.4 (write paths) + FR52 ACs | ✓ Covered |
| NFR7 screen recoverability via Ctrl-L | Stories 1.11 + 1.12 | ✓ Covered |
| NFR8 BDOS rc check completeness | Story 1.4 BDOS_CALL macro; AR15 single-gateway funnel reviewed across stories | ✓ Covered |
| NFR9 code budget ~3 KB | Story 1.12 baseline `make sizes`; AR3 target | ✓ Covered (continuous monitoring) |
| NFR10 TPA fit | Story 1.3 listing-file verification | ✓ Covered |
| NFR11 single .COM artifact | Story 1.1 build target | ✓ Covered |
| NFR12 static allocation only | Story 1.3 single static-data block | ✓ Covered |
| NFR13 single platform target | Story 1.1 toolchain pinning + UAT-on-hardware throughout | ✓ Covered |
| NFR14 sjasmplus 1.23.0 | Story 1.1 AR2 invocation flags pinned | ✓ Covered |
| NFR15 CP/M 2.2 BDOS only | Story 1.4 `bdos.inc` enumerates only 2.2 functions | ✓ Covered |
| NFR16 knob centralization | Story 1.2 `inc/equates.inc` | ✓ Covered |
| NFR17 mode/operator decoupling | Stories 1.9 (sparse tables) + 1.10 (parser) + 2.11 (composition) | ✓ Covered (structural; review-enforced) |
| NFR18 build reproducibility | Story 1.1 SHA-256 byte-identical rebuild AC | ✓ Covered |

### Coverage Statistics

- **Total PRD FRs:** 52
- **FRs covered in epics:** 52
- **FR coverage:** 100%
- **Total PRD NFRs:** 18
- **NFRs covered in epics:** 18
- **NFR coverage:** 100%
- **Architectural requirements lifted from architecture.md (AR1–AR26):** 26, all assigned to Epic 1 stories 1.1–1.6 (skeleton, headers, funnels, test harness, conventions).

### Missing Requirements

**No FR is uncovered.** Every numbered FR1–FR52 maps to at least one story whose acceptance criteria materially realize the requirement. Likewise every NFR1–NFR18 is addressed.

### Minor specification-tightening flags carried forward

These are not missing FRs — they are PRD ambiguities that the epics also do not pin down. Implementation will need to make a call; flagging now so the call is made deliberately, not by accident:

1. **Status-line dirty-buffer indicator (cosmetic):** Story 2.1 refuses `:q` on dirty (correct) and stories 2.4/2.8 set/clear `buffer_dirty`, but no AC specifies whether the dirty state is **visible** in the status line at idle (e.g., a `[+]` marker). FR49 text ("current mode, filename, and the most recent message") is silent. **Recommend:** explicit decision before story 1.11 lands, since it touches status_render. Acceptable to defer to "no marker — user discovers via `:q` refusal" if intentional.
2. **Counts in visual-mode operators (e.g., `5d` in VISUAL):** Stories 3.6/3.7/3.8 do not specify whether a count prefix has any effect — vi convention is that operator-on-selection ignores count, but it is not stated. **Recommend:** add a one-line AC to story 3.6 documenting the chosen behavior.
3. **`P` (paste-before):** PRD lists only `p`; Story 2.12 does not include `P`. Consistent across docs but worth confirming `P` is intentionally Growth-tier and not an oversight.
4. **Counts on `u` (e.g., `5u`):** Single-level undo (AC6/2.13) makes `5u` semantically degenerate. Story 2.13 does not address it. **Recommend:** explicit no-op (treat count as 1) documented in 2.13.
5. **`Ctrl-L` from non-NORMAL modes:** Story 1.11 implies `render_full` is callable; story 1.9 places `Ctrl-L` in `dispatch_normal` only. Stories 2.1 (dispatch_command), 3.3 (dispatch_visual) don't add it; in MODE_INSERT, 0x0C is consumed by the literal-byte fall-through (story 2.8). **Behavior is currently:** Ctrl-L works only in NORMAL/VISUAL. **Recommend:** confirm intent — if Ctrl-L should also work from INSERT/COMMAND, add explicit dispatch entries.
6. **Indent character choice (`>`/`<` and `>>`/`<<`):** Stories 2.11 and 3.7 say "one space (or tab — module header documents the choice)" — the choice itself is deferred. **Recommend:** pin the choice in `equates.inc` (e.g., `INDENT_BYTE EQU 0x20`) before story 2.11 lands; otherwise visual shift and composed shift may diverge.

**Verdict:** Epic coverage is complete with respect to PRD FRs and NFRs. No critical gaps. Six minor specification-tightening items carried forward — none blocking, all deserving a deliberate implementation decision before the affected story is implemented.

## Step 4 — UX Alignment

### UX Document Status

**Not Found.** Searched `{planning_artifacts}/*ux*.md` and `{planning_artifacts}/*ux*/index.md` — no separate UX design document exists. User confirmed in Step 1 that UX is intentionally folded into the PRD and architecture rather than authored as its own artifact.

### Is UX Implied?

**Yes — VIBE is a TUI editor on a 32/80-column VT52 terminal, so user-experience choices are unavoidable.** The PRD and epics treat UX as embedded:

- **PRD-side UX surface:**
  - Persona, three User Journeys, and "Journey Requirements Summary" (PRD §"User Journeys") cover the human-facing flow.
  - **FR47** (diff render), **FR48** (`Ctrl-L` refresh), **FR49** (status line on row 24 — mode, filename, message), **FR50** (no-op + status feedback for unsupported commands) are the explicit UX-equivalent FRs.
  - "What MUST NOT happen" list in Journey 2 (no crashes, no screen desync, no silent truncation, no false-saved reports) is a UX contract framed as reliability.
  - **NFR2** (typing throughput ≥10 cps), **NFR3** (single-frame cursor latency), **NFR4** (Esc disambiguation 20–40 ms) are the experiential performance contracts.

- **Architecture-side UX surface:**
  - Render pipeline (`render.asm`, AC9) realizes FR47/FR48 with concrete diff-emission rules and the cursor-reposition discipline (RI4).
  - Status-line module (`statusln.asm`, AR12) gives FR49 a single funnel.
  - Message-string convention AR16 (lowercase, no trailing period, under 30 chars) is a written UX style guide for status-line copy.
  - Visual-mode rendering decision (epics Epic 3 preamble): "Classic VT52 has no character attributes... visual mode does not paint a highlighted region; the selection is logical (anchor + cursor); the status line shows the extent count" — a deliberate UX call driven by platform constraint, documented in code.

The **epics doc explicitly addresses** the missing-UX situation (epics.md line 12 + lines 187–188): "There is no separate UX Design document — VIBE is a TUI on a VT52 and UX-equivalent commitments live in PRD FRs 47–49 and the Architecture render decisions."

### UX ↔ PRD Alignment

Aligned. Every PRD User-Journey capability has an FR and a corresponding story:

| Journey capability | PRD FR(s) | Epic story |
|---|---|---|
| Buffer/file lifecycle | FR1–FR8 | 2.1, 2.2, 2.3, 2.4 |
| Modal editing core | FR12–FR17 | 1.9, 1.12, 2.1, 2.8, 3.3–3.5 |
| Motions and edits | FR18–FR32 | 2.5–2.13 |
| Search | FR41–FR44 | 3.1–3.2 |
| Single-level undo | FR45–FR46 | 2.13 |
| Error handling (status feedback, no-op, no silent loss) | FR50–FR52 | 1.9, 2.4, BDOS_CALL macro 1.4 |
| Diff render + recovery via Ctrl-L | FR47–FR48 | 1.11 |
| FCB integration (drives, missing files, write-protect) | FR9–FR11, FR51 | 2.2, 2.4 |

### UX ↔ Architecture Alignment

Aligned. Architecture choices visibly enforce UX commitments:

- **Diff-emission discipline (FR47, NFR1)** → `render.asm` cell-diff (AC9, story 1.11); shadow buffer at 1920 bytes; idle-frame test "zero content bytes emitted".
- **Single-frame cursor latency (NFR3)** → render pipeline architecture has bounded cost ("cursor-row-recompute bounded by visible-region size, ~1920-byte scan worst case", story 1.11 W2).
- **Esc disambiguation (NFR4)** → `input.asm` (story 1.8) implements 1–2 tick window, tunable via `ESC_TIMEOUT_TICKS`, UAT-validated.
- **Status line as the one user-feedback channel (FR49, FR50, FR51, FR52)** → AR12 single status-message funnel + AR16 style guide.
- **Recovery escape hatch (FR48, NFR7)** → `Ctrl-L` → `render_full` (story 1.11), defensively re-emit cursor before each diff frame (R3 mitigation).
- **No-crash mandate (NFR5)** → BDOS_CALL macro (story 1.4) makes every BDOS return code visible and routed through the funnel; per-mode unbound handlers (story 1.9) make every keystroke survivable.
- **Visual-mode no-highlight UX call** → architecturally documented in `visual.asm` and `render.asm` headers; status-line shows extent count instead.

### Alignment Issues

**None blocking.** Two minor surfaces worth noting (these duplicate items already flagged in Step 3 — re-cited here as UX issues so the implementation pass owns them):

1. **Status-line content composition (cosmetic UX call):** FR49 enumerates "current mode, filename, and the most recent message or error" — but no AC mandates a dirty-buffer indicator (`[+]` or similar) on the status row. Vi convention varies. **UX risk:** the user only learns the buffer is dirty when `:q` refuses, which is functional but not discoverable. **Recommend:** an explicit UX call before story 1.11 — either add a dirty marker (cheap, vi-canonical) or document the silent-dirty choice in `statusln.asm`.
2. **Indent character (`>`/`<` UX consistency):** Stories 2.11 and 3.7 leave the choice ("space or tab") to the implementer with the constraint "module header documents the choice". **UX risk:** if visual `>` and composed `>>` end up using different indent bytes, region indents and single-line indents look inconsistent. **Recommend:** pin via `INDENT_BYTE` equate (centralized per NFR16) before the first of these stories ships.

### Warnings

**No critical warnings.** The decision to omit a separate UX document is reasoned, documented in the epics, and adequately substituted by FRs 47–49, NFRs 1–4, AR12/AR16, the platform-constraint-driven visual-mode decision, and the explicit User Journeys section in the PRD. For a single-author TUI on a fixed terminal geometry with no public audience and no accessibility framework, a standalone UX document would be ceremony, not value.

## Step 5 — Epic Quality Review

Reviewed against `bmad-create-epics-and-stories` standards: user-value focus, epic independence, no forward dependencies, story sizing, AC quality, and greenfield setup expectations. Findings stratified by severity.

### Compliance checklist (per epic)

| Check | Epic 1 | Epic 2 | Epic 3 |
|---|---|---|---|
| Epic delivers user value | ⚠️ partial (foundation epic with on-hardware UAT in story 1.12) | ✅ Journey 1a complete | ✅ Journey 1b + region edits |
| Epic can function independently | ✅ (Epic 1 stands alone — runnable on hardware after 1.12) | ✅ (depends on Epic 1, no dependency on Epic 3) | ✅ (depends on Epic 1+2, no forward deps) |
| Stories appropriately sized | ✅ (12 stories, each scoped to one module/concept) | ✅ (13 stories, motion-by-motion + edit-by-edit) | ✅ (8 stories, search + visual sub-modes) |
| No forward dependencies | ⚠️ (stub-undo pattern: 2.8–2.12 reference 2.13 for full undo recording) | — | — |
| State/equate creation when needed | ⚠️ structural (state.inc declares all state upfront in story 1.3 — defensible per NFR12 static-allocation contract) | — | — |
| Clear acceptance criteria | ✅ (Given/When/Then; concrete; measurable) | ✅ | ✅ |
| Traceability to FRs maintained | ✅ (every story names the FRs it realises) | ✅ | ✅ |

### 🔴 Critical Violations

**None.**

### 🟠 Major Issues

**None.**

### 🟡 Minor Concerns

#### MC1 — Epic 1 is foundation-shaped

**Observation:** Of Epic 1's 12 stories, 1.1–1.4 are pure infrastructure (build skeleton, equates header, state map, BDOS shims) — no end-user-visible behavior. Stories 1.5–1.7 are partly invisible (status-message funnel, test harness, gap buffer with headless tests). Only 1.8 onward and decisively story 1.12 (on-hardware smoke test) produce user-observable output. A strict BMM reading of "every epic must deliver user value" would prefer the infrastructure to be absorbed into the first feature epic.

**Why it's defensible (and flagged minor, not major):**
- Single-author hobbyist project; no external "ship value early" pressure.
- Epic 1 explicitly closes the two PRD-named technical risks (Esc/arrow disambiguation, gap-buffer correctness) before any feature work depends on them — risk-driven phasing is a stronger justification than the framework's default user-value-per-epic heuristic.
- Story 1.12's UAT *is* a user-observable demonstration (mode switching, Ctrl-L recovery, beep on unbound key, clean exit) — the epic does close on a runnable artifact, just one that doesn't yet edit text.
- Architecture constraints make foundations harder to absorb: NFR12 (static allocation only) means `state.inc` must declare the whole memory map at assembly time — story 1.3 is genuinely a single, indivisible deliverable, not a "pre-built all the models" anti-pattern.

**Recommendation:** No restructuring required. Document the risk-driven phasing rationale in `epics.md` Overview (already present). No action.

#### MC2 — Stub-undo pattern across stories 2.8–2.12 → 2.13

**Observation:** Stories 2.8 (insert mode), 2.9 (`x`), 2.10 (`dd`/`yy`), 2.11 (composed op+motion), and 2.12 (`p`) each include an AC that mentions undo recording, but explicitly defers full implementation to story 2.13. Concretely:
- Story 2.8 AC: "the insert session is recorded as a single undo entry per B2 (full coverage in story 2.13; for 2.8 the entry recording is a stub or minimal)"
- Story 2.9 AC: "the deleted byte is recorded in the undo buffer (stub for 2.9, full coverage in 2.13)"

Strictly, 2.13 retroactively completes earlier stories. This is a **fan-in pattern** — defensible but worth recognizing because it means stories 2.8–2.12 are not literally "done done" until 2.13 lands.

**Why it's defensible:**
- Each mutating handler must commit to a representation of its inverse op. Landing undo first would force a global decision on the inverse-op encoding before any mutator exists. The chosen order lets each mutator's recording be designed alongside the mutator itself.
- Each affected story explicitly flags the deferral; the docs are not silent on this.

**Alternative ordering (not recommended, but for the record):** Land 2.13 (undo infrastructure + entry-writing protocol) first; each mutator story (2.8–2.12) then records its own ops as a normal AC. This would make each mutator story self-contained but commits the undo encoding decision earlier. Tradeoff is real; current order is fine.

**Recommendation:** Acknowledge the pattern explicitly in story 2.13's "definition of done" — say "this story closes the undo-recording AC across stories 2.8–2.12; review those stories' acceptance test runs after 2.13 lands to confirm undo works for each." Then 2.13's UAT becomes the integration test for the whole fan-in.

#### MC3 — Save (2.4) lands before Insert (2.8); cannot be fully UAT'd until 2.8

**Observation:** Story 2.4 (`:w` / `:w filename` / `:wq`) is explicitly numbered before story 2.8 (insert mode). Story 2.4's UAT note says: "Full UAT for save-with-edits is gated on 2.8; UAT for save-empty-buffer is achievable in this story alone." So 2.4 ships with partial on-hardware UAT (save an empty buffer to a new filename); the round-trip "edit + save + reload" demonstration only becomes possible after 2.8.

**Why the chosen order makes sense:**
- 2.4 builds on `:e` (story 2.2) and motions (2.5–2.7) — landing save earlier exercises FCB write paths against fixtures (the headless tests are full-coverage).
- The author may want save to be hardened before users can produce dirty buffers via insert mode.

**Alternative ordering:** 2.5 → 2.6 → 2.7 → 2.8 → 2.4 (motions, insert, then save) would let 2.4 demonstrate the full edit/save cycle on first land.

**Recommendation:** Either accept current order (with the partial-UAT caveat already documented) or swap 2.4 and 2.8 if author wants 2.4's UAT to be complete on first ship. Non-blocking either way.

#### MC4 — Test gap: motion-prefix rejection re-dispatch in story 1.10

**Observation:** Story 1.10's parser AC for `parser_handle_motion_prefix` says: "if the motion is also 'g', the `gg` motion is dispatched (V3); otherwise the prefix is cleared and the key re-dispatched through normal mode." The story's enumerated headless test cases include `parser_motion-prefix-gg.asm` and `parser_motion-prefix-cleared-on-other-key.asm` — but only the second case asserts the prefix is cleared, not that the follow-up key is re-dispatched correctly. A test like `parser_motion-prefix-then-j-acts-like-j.asm` (or similar) would close the loop by verifying `gj` does the same thing as plain `j`.

**Recommendation:** Add one test case to story 1.10's headless coverage exercising the re-dispatch path. Trivial addition.

#### MC5 — `BDOS_DELETE existing file (or BDOS_MAKE replaces — implementation choice with rationale documented)` in story 2.4

**Observation:** Story 2.4's flow leaves a binary architectural decision unresolved: "BDOS_DELETE existing file (or BDOS_MAKE replaces — implementation choice with rationale documented)". The two paths have different failure modes (delete-then-make leaves a window of zero file if make fails; make-replaces depends on BDOS 2.2 semantics for re-MAKE). Architecture document would be the natural home for this decision, not the story's AC.

**Recommendation:** Decide before story 2.4 implementation begins. Document the chosen approach in `architecture.md`'s File I/O section (currently in PRD's AC11 / architecture's equivalent) so the rationale is durable, not buried in a comment.

### 🟢 Strengths Worth Naming

- Every story names the FRs and NFRs it realizes. Traceability is bidirectional (FR Coverage Map at top of `epics.md` + per-story FR enumeration).
- Module-level contracts are concrete: every story specifies the module's `Public:` symbols, owned `State:`, register conventions, and dependencies — these become the file headers AR23 demands.
- Headless test cases are enumerated by filename per story; story 1.6 (test harness) lands early and the iz-cpm-driven harness is consistent across all later stories.
- Stories that depend on a UAT-only signal (Esc timing, sustained-typing throughput) explicitly flag UAT as the gate and **do not** pretend to test it headlessly — story 1.8 is the model.
- Stub-and-fill-in-later patterns (story 1.7's `gapbuf_load`, dispatch table stubs in 1.9, undo recording stubs in 2.8–2.12) are *all explicitly marked TODO with forward references*, not buried.
- Story 1.1 establishes byte-identical rebuild (NFR18) on day one — the discipline catches accidental host-leakage early when the build is still trivial. Strong move.
- Architecture's review-enforced conventions (AR22–AR25) are referenced in stories' ACs by code, so the review cadence is built into story sign-off.

### Summary

- **Critical:** 0
- **Major:** 0
- **Minor:** 5 (1 epic-shape observation, 1 fan-in dependency pattern, 1 ordering tradeoff, 1 test-gap, 1 deferred design decision)
- **Strengths:** Substantial — traceability, contracts, harness, UAT discipline, reproducibility-from-day-one.

Quality bar is high. None of the minor items block implementation start.

## Summary and Recommendations

### Overall Readiness Status

**READY for implementation.**

### Findings rollup

| Severity | Count | Source step(s) |
|---|---:|---|
| 🔴 Critical | 0 | — |
| 🟠 Major | 0 | — |
| 🟡 Minor | 11 | Step 2 (6 PRD ambiguities), Step 3 (6 spec-tightening — overlap with Step 2), Step 5 (5 epic-quality observations); deduplicated total = 11 |

### Critical Issues Requiring Immediate Action

**None.** No issue found is severe enough to block implementation start.

### Minor Issues — Triage Cheat Sheet

Each item has a recommended owning story (where the decision must be made before coding) so you can resolve them in-flight rather than batch-up front:

| # | Item | Owning story | Recommended action |
|---|---|---|---|
| 1 | Status-line dirty-buffer indicator (`[+]` or silent) | Story 1.5 / 1.11 (status_render) | One-line decision; if "no marker", document in `statusln.asm` header |
| 2 | Counts in visual-mode operators (e.g. `5d`) | Story 3.6 | Add one AC line declaring the chosen behavior (vi default: count is implicit in selection size) |
| 3 | `P` (paste-before) — confirm intentionally Growth-tier | PRD/epics author note | Already consistent across docs; just add an explicit "P deferred to Growth" line if you want airtight closure |
| 4 | Counts on `u` (e.g. `5u`) — degenerate under single-level undo | Story 2.13 | Add AC: "count is ignored; effective count is always 1" |
| 5 | `Ctrl-L` from non-NORMAL modes (INSERT consumes 0x0C as literal) | Story 1.9 / 1.11 | Decide: extend dispatch_command + dispatch_visual to include Ctrl-L? In INSERT, leave as literal? Document in 1.11 header |
| 6 | Indent character (`>`/`<`/`>>`/`<<` — space vs tab) | Story 2.11 / 3.7 | Pin via `INDENT_BYTE` equate in `equates.inc` (story 1.2); cite in stories 2.11 and 3.7 |
| 7 | Epic 1 foundation-shape (rationale review) | Already documented | No action; rationale is durable in `epics.md` Overview |
| 8 | Stub-undo fan-in across 2.8–2.12 → 2.13 | Story 2.13 | Add AC noting 2.13 closes undo-recording for stories 2.8–2.12; treat 2.13 UAT as the integration test |
| 9 | Save (2.4) precedes Insert (2.8) — partial UAT | Story 2.4 (or reorder) | Either accept the partial-UAT caveat (already documented in 2.4) or swap 2.4 ↔ 2.8 if a fully end-to-end UAT for 2.4 on first ship is wanted |
| 10 | Test gap: motion-prefix re-dispatch in story 1.10 | Story 1.10 | Add one headless test case (e.g. `parser_motion-prefix-then-j-acts-like-j.asm`) |
| 11 | Save flow: `BDOS_DELETE` then `MAKE` vs. `MAKE`-replaces | Story 2.4 | Pick one, document the rationale in `architecture.md`'s File I/O section before 2.4 starts |

### Recommended Next Steps

1. **Decide the six in-flight design calls** (items 1, 2, 4, 5, 6, 11 in the table above) — these are all one-line decisions, none requires architectural rework. Best handled as a single 30-minute pass through the affected stories' headers/ACs before starting Story 1.1.
2. **Begin Epic 1 implementation at Story 1.1** (project skeleton + reproducible build). The byte-identical-rebuild discipline will catch host-leakage early when the build is still trivial — a strong foundation for NFR18.
3. **Defer ordering review of Story 2.4 vs. 2.8 (item 9) until after Epic 1 lands.** By then the author will have on-hardware feel for whether they want save's UAT to be fully end-to-end on first ship or to keep the current order.
4. **Add the missing test case for story 1.10 (item 10)** when implementing the parser — trivial, do it inline.

### Final Note

This assessment identified 11 issues across 5 categories — **all minor specification-tightening items**, no critical or major blockers. Address the listed items in-flight (most are one-line decisions made at the affected story's start) rather than as a separate gating pass. The PRD is unusually thorough, the architecture is pinned, the epics are 100% FR-traceable, and the test harness lands early in Epic 1. Implementation can proceed.

---

**Assessment date:** 2026-05-08
**Assessor:** Implementation Readiness workflow (bmad-check-implementation-readiness)
**Project:** vibe — vi-spirited Z80 modal editor for the Feersum MicroBeast under CP/M 2.2
**Artifacts assessed:** `prd.md` (41 KB), `architecture.md` (76 KB), `epics.md` (100 KB)
**Coverage:** 52/52 FRs (100%), 18/18 NFRs (100%), 26 architectural requirements (AR1–AR26) all assigned to Epic 1
**Verdict:** READY for implementation.
