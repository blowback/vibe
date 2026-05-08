---
stepsCompleted: ['step-01-validate-prerequisites', 'step-02-design-epics', 'step-03-create-stories', 'step-04-final-validation']
inputDocuments:
  - _bmad-output/planning-artifacts/prd.md
  - _bmad-output/planning-artifacts/architecture.md
---

# vibe - Epic Breakdown

## Overview

This document provides the complete epic and story breakdown for vibe, decomposing the requirements from the PRD and Architecture into implementable stories. There is no separate UX Design document — VIBE is a TUI on a VT52 and UX-equivalent commitments live in PRD FRs 47–49 and the Architecture render decisions.

## Requirements Inventory

### Functional Requirements

**Editor Lifecycle**

- FR1: User can launch VIBE with no arguments and begin editing an empty buffer.
- FR2: User can launch VIBE with a filename argument and begin editing the contents of that file.
- FR3: User can quit VIBE, returning control to the CCP.

**File Operations**

- FR4: User can save the current buffer to its current filename (`:w`).
- FR5: User can save the current buffer to a different filename (`:w filename`).
- FR6: User can open a different file, replacing the current buffer (`:e filename`).
- FR7: User can save and quit in one step (`:wq`).
- FR8: User can quit without saving, abandoning unsaved changes (`:q!`).
- FR9: VIBE resolves bare filenames (no drive prefix) to drive B:.
- FR10: VIBE accepts explicit drive-letter prefixes in filenames (e.g. `A:foo.fs`).
- FR11: VIBE refuses to load files exceeding the gap buffer capacity, surfacing the refusal in the status line without modifying the current buffer.

**Modal Editing**

- FR12: VIBE starts in normal mode.
- FR13: User can enter insert mode from normal mode.
- FR14: User can enter command mode (ex-line entry) from normal mode via `:`.
- FR15: User can enter visual mode from normal mode.
- FR16: User can return to normal mode from any other mode via `Esc`.
- FR17: VIBE displays the current mode in the status line.

**Cursor Motion**

- FR18: User can move the cursor one character left or right (`h`, `l`).
- FR19: User can move the cursor one line up or down (`k`, `j`).
- FR20: User can move to the next or previous word (`w`, `b`).
- FR21: User can move to the start or end of the current line (`0`, `$`).
- FR22: User can move to the first or last line of the buffer (`gg`, `G`).
- FR23: User can prefix any motion with a count for repetition (e.g. `5j`, `12G`, `3w`).

**Text Editing**

- FR24: User can insert text before the cursor (`i`).
- FR25: User can insert text after the cursor (`a`).
- FR26: User can open a new line below the current line and enter insert mode (`o`).
- FR27: User can open a new line above the current line and enter insert mode (`O`).
- FR28: User can delete the character under the cursor (`x`).
- FR29: User can delete the current line (`dd`).
- FR30: User can delete a word (`dw`).
- FR31: User can yank (copy) the current line (`yy`).
- FR32: User can paste yanked or deleted text (`p`).

**Visual Mode**

- FR33: User can select text by character (visual character mode).
- FR34: User can select whole lines (visual line mode).
- FR35: User can select rectangular blocks (visual block mode).
- FR36: User can apply delete, yank, and change operators to a visual selection (`d`, `y`, `c`).
- FR37: User can shift a visual selection right or left (`>`, `<`).
- FR38: User can toggle case of a visual selection (`~`).

**Operator + Motion Composition**

- FR39: User can compose any operator with any motion to apply the operator over the motion's range (e.g. `dw`, `d$`, `c5w`, `y3j`).
- FR40: User can prefix composed operator/motion commands with a count (e.g. `5dd`, `2dw`, `3yy`).

**Search**

- FR41: User can initiate a forward literal search (`/pattern`).
- FR42: User can repeat the most recent search (`n`).
- FR43: Search wraps from end-of-buffer to start; VIBE reports the wrap in the status line.
- FR44: VIBE reports "pattern not found" in the status line when no match exists in the buffer.

**Undo**

- FR45: User can undo the most recent edit (`u`).
- FR46: VIBE reports in the status line when undo is unavailable (e.g., operation exceeded undo buffer).

**Display & Feedback**

- FR47: VIBE renders only changed regions of the screen during normal editing (full-screen redraws happen only on initial draw or explicit refresh).
- FR48: User can force a full-screen refresh (`Ctrl-L`).
- FR49: VIBE displays a status line on row 24 reflecting current mode, filename, and the most recent message or error.

**Error Handling & Robustness**

- FR50: VIBE responds to unsupported commands as a no-op, with audible/visual feedback in the status line (or beep), leaving editor state unchanged.
- FR51: VIBE surfaces every CP/M file-I/O failure (disk full, write-protect, file not found, drive offline) in the status line without entering an inconsistent state.
- FR52: VIBE never silently truncates or discards user data on save (errors are reported; the buffer remains dirty until either a successful save or an explicit `:q!`).

### NonFunctional Requirements

**Performance**

- NFR1: Incremental rendering. During normal editing, VIBE emits to the terminal only the cells whose content has changed since the previous frame. Full-screen redraws are reserved for initial draw and explicit `Ctrl-L` refresh.
- NFR2: Sustained typing throughput. VIBE absorbs continuous insert-mode typing at typical human speeds (≥10 chars/sec) without dropping or coalescing keystrokes.
- NFR3: Predictable cursor-motion latency. Single-character motion commands complete within one input-loop iteration. Counted motions and large-range operators remain interactive.
- NFR4: Esc disambiguation budget. Bare-Esc vs. arrow-key timeout uses the 50 Hz tick; target 1–2 ticks (20–40 ms), tunable via source equate, empirically validated on real hardware.

**Reliability**

- NFR5: No crashes. VIBE never enters a state requiring a CP/M warm reboot for the user to recover.
- NFR6: No silent data loss. Every save either succeeds completely or surfaces an explicit error in the status line; the buffer stays dirty.
- NFR7: Screen state recoverability. If the shadow buffer desyncs from the actual terminal, `Ctrl-L` (full redraw) restores consistency.
- NFR8: BDOS error handling completeness. Every BDOS file-I/O call checks its return value; unexpected codes abort cleanly with a status-line message.

**Resource Consumption**

- NFR9: Code size budget. Tentative ceiling ~3 KB of Z80 code; significant overruns trigger redesign rather than budget inflation; safety paths exempt.
- NFR10: TPA fit. Total static footprint fits within the TPA (`0x0100..0xD7FF`, ~54 KB).
- NFR11: Single artifact. VIBE ships as exactly one CP/M `.COM` file.
- NFR12: Static allocation only. No runtime allocator; all buffers sized at assembly time.

**Compatibility & Portability**

- NFR13: Single platform target. Feersum MicroBeast running CP/M 2.2 with VT52-capable terminal at 80×24.
- NFR14: Fixed toolchain. sjasmplus 1.23.0 on a Linux host.
- NFR15: Standard CP/M 2.2 BDOS only. No 3.x extensions, no MicroBeast-specific BDOS calls. Console path uses BIOS direct (deliberate exception).

**Maintainability**

- NFR16: Knob centralization. All compile-time tunables live as named equates in `inc/equates.inc`; no magic numbers in handlers.
- NFR17: Mode/operator decoupling. Mode-dispatch tables and operator+motion composition are decoupled enough that adding Growth-tier features doesn't require restructuring.
- NFR18: Build reproducibility. `make` from a clean tree produces a byte-identical `vibe.com`.

### Additional Requirements

These are technical/structural requirements lifted from the Architecture document that go beyond the PRD's FR/NFR set and shape epic and story decomposition.

**Skeleton & Build (greenfield)**

- AR1: Bespoke project skeleton (no starter template). Story 1.1 is "Project skeleton" — directory tree (`src/`, `inc/`, `test/`, `build/`) with stub `src/vibe.asm` (`ORG 0x0100` + `RET`), Makefile assembling under sjasmplus 1.23.0, and a verifiable byte-identical rebuild (NFR18 baseline).
- AR2: sjasmplus invocation flags pinned in Makefile: `--nologo --msg=err --raw=vibe.com --lst=build/vibe.lst --sld=build/vibe.sld src/vibe.asm`. No timestamps, no host-path embedding.
- AR3: Make targets: `all` (default), `test` (recurses into `test/Makefile`), `push` (SLIDE transfer to MicroBeast), `clean`, `sizes` (per-section size from listing).
- AR4: `.gitignore` excludes build artifacts (`*.com`, `*.lst`, `*.sld`, `build/`, swap files).
- AR5: README.md is dev-loop oriented (build, test, transfer, link to architecture.md), not user manual.

**Shared Headers (single source of truth)**

- AR6: `inc/equates.inc` — all compile-time knobs (GAP_BUFFER_BASE, GAP_BUFFER_MAX, UNDO_BUFFER_SIZE, STATUS_LINE_WIDTH, EX_COMMAND_BUFFER, SEARCH_PATTERN_BUFFER, YANK_BUFFER_SIZE, SCREEN_ROWS, SCREEN_COLS, EDITABLE_ROWS, ESC_TIMEOUT_TICKS).
- AR7: `inc/bios.inc` — MicroBeast BIOS jump-table addresses (CONIN, CONINST, CONOUT, tick counter). Concrete addresses populated when wiring `init.asm` (Watchpoint W1 in architecture).
- AR8: `inc/bdos.inc` — CP/M 2.2 BDOS function numbers + the `BDOS_CALL` checked-call macro (MC6) enforcing NFR8 at every call site.
- AR9: `inc/vt52.inc` — VT52 control codes (ESC, CURSOR_HOME, CLEAR_SCREEN, ERASE_TO_EOL, GOTO).
- AR10: `inc/modes.inc` — mode and visual sub-mode equates plus synthesized arrow keycodes (KEY_ARROW_UP/DOWN/LEFT/RIGHT = 0x80–0x83, RI5/V1).
- AR11: `inc/state.inc` — single static memory map for all cross-module state (mode_byte, cursor_offset, gap_start/end, visual_anchor, count_accumulator, pending_operator, pending_motion_prefix, yank_kind/length, status_dirty, top_line_offset, status_buffer, search_pattern, ex_buffer, filename_buffer, shadow_buffer, dirty_rows, undo_buffer). Accessed by symbol only — no inline addresses.

**Cross-Cutting Funnels**

- AR12: Single status-message funnel — `status_set_message` (statusln.asm). Every error and informational path routes through this entry point.
- AR13: Single screen-emission path — `render.asm` owns all `BIOS_CONOUT` writes (init's initial clear is the only declared exception).
- AR14: Single buffer-mutation owner — `gapbuf.asm` is the only module that calls `gapbuf_insert/delete/move_gap` to mutate the gap buffer; all other modules are read-only against it.
- AR15: Single BDOS gateway — `BDOS_CALL` macro. Raw `CALL 0x0005` is forbidden by convention (enforces NFR8).
- AR16: Status-message string-table convention — all messages lowercase, no trailing period, target under 30 chars; live in a dedicated near-end-of-code block.

**Test Harness**

- AR17: Headless test harness using iz-cpm on the Linux build host. Each test in `test/cases/<module>_<scenario>.asm` assembles to a `.COM`, runs to completion, signals pass/fail via sentinel byte at `0xCFFE` (TH1).
- AR18: Test prologue/epilogue includes (`test/inc/test_prologue.inc`, `test/inc/test_epilogue.inc`) provide standard entry boilerplate and `test_pass`/`test_fail` exits.
- AR19: `test/Makefile` builds every case, runs each under iz-cpm with a 5-second timeout, exits non-zero on any failure.
- AR20: Fixture filesystem at `test/fixtures/` mounted as iz-cpm B: drive for FCB-level tests (load, save, write-protect).
- AR21: Headless coverage scope: gap buffer, command parser, search, undo, file I/O, render math (shadow-buffer diff against synthetic frames). Excluded (UAT only): Esc/arrow timing, full-screen drift recovery, sustained-typing throughput, end-to-end editing journeys, interactive ex-command-line editing.

**Architectural Conventions (review-enforced)**

- AR22: Naming — public symbols `module_action` lowercase_with_underscores; internal labels dotted-locals (`.loop`, `.done`); equates and macros UPPER_SNAKE_CASE; runtime variables lowercase.
- AR23: File structure — every `.asm`/`.inc` file begins with a header block (Module / Purpose / Public / State owned / Register conventions / Dependencies); every public routine begins with a four-line contract (`In:` / `Out:` / `Trashes:` / `Calls:`).
- AR24: Format — UPPERCASE mnemonics and registers; 4-space indentation, never tabs; `;` for line comments, `;;` for section dividers, no trailing periods; null-terminated strings except length-prefixed buffers (search_pattern, ex_buffer).
- AR25: Module include order in `vibe.asm` — `equates.inc` → `bios.inc` → `bdos.inc` → `vt52.inc` → `modes.inc` → `state.inc` → `ORG 0x0100` → `init` → `input` → `statusln` (early — depended on by everything) → `gapbuf` → `render` → `dispatch` → `parser` → `motions` → `edits` → `visual` → `search` → `exline` → `fileio` → `undo`.

**Deferred / Reserved**

- AR26: Reserved-pool earmarked between gap-buffer-top and BDOS for post-MVP features (multi-level undo, marks/jumps, macros, multi-buffer). MVP does not allocate from this region.

### UX Design Requirements

Not applicable — VIBE has no separate UX Design document. UX-equivalent commitments live in PRD FRs 47–49 (diff render, Ctrl-L refresh, status line) and Architecture render/status decisions (RI1–RI4, MC5, AR16).

### FR Coverage Map

| FR | Epic | Brief Description |
|---|---|---|
| FR1 | 2 | Launch with no arguments — empty buffer |
| FR2 | 2 | Launch with filename argument — load file |
| FR3 | 2 | Quit (`:q`) returns control to CCP |
| FR4 | 2 | Save (`:w`) to current filename |
| FR5 | 2 | Save-as (`:w filename`) |
| FR6 | 2 | Open different file (`:e filename`); `:e!` to force |
| FR7 | 2 | Save and quit (`:wq`) |
| FR8 | 2 | Quit without saving (`:q!`) |
| FR9 | 2 | Bare filename resolves to drive B: |
| FR10 | 2 | Drive-letter prefix accepted |
| FR11 | 2 | Refuse oversize file at load with status message |
| FR12 | 1 | Start in normal mode |
| FR13 | 1 / 2 | Mode transition (Epic 1) / insert behavior (Epic 2) |
| FR14 | 1 / 2 | Mode transition (Epic 1) / ex-line dispatch (Epic 2) |
| FR15 | 1 / 3 | Mode transition (Epic 1) / visual behavior (Epic 3) |
| FR16 | 1 | Esc returns to normal mode from any other mode |
| FR17 | 1 | Status line displays current mode |
| FR18 | 2 | `h` / `l` cursor motion |
| FR19 | 2 | `j` / `k` cursor motion |
| FR20 | 2 | `w` / `b` word motion |
| FR21 | 2 | `0` / `$` line-start / line-end motion |
| FR22 | 2 | `gg` / `G` first / last line motion |
| FR23 | 2 | Counted motions (`5j`, `12G`, `3w`) |
| FR24 | 2 | `i` insert before cursor |
| FR25 | 2 | `a` insert after cursor |
| FR26 | 2 | `o` open new line below |
| FR27 | 2 | `O` open new line above |
| FR28 | 2 | `x` delete character |
| FR29 | 2 | `dd` delete line |
| FR30 | 2 | `dw` delete word |
| FR31 | 2 | `yy` yank line |
| FR32 | 2 | `p` paste |
| FR33 | 3 | Visual character mode |
| FR34 | 3 | Visual line mode |
| FR35 | 3 | Visual block mode |
| FR36 | 3 | Visual `d` / `y` / `c` operators |
| FR37 | 3 | Visual `>` / `<` shift |
| FR38 | 3 | Visual `~` case toggle |
| FR39 | 2 | Operator+motion composition (`dw`, `d$`, `c5w`, `y3j`) |
| FR40 | 2 | Counted operator+motion (`5dd`, `2dw`, `3yy`) |
| FR41 | 3 | Forward literal search (`/pattern`) |
| FR42 | 3 | `n` repeat last search |
| FR43 | 3 | Search wrap with status notice |
| FR44 | 3 | "pattern not found" status |
| FR45 | 2 | `u` undo most recent edit |
| FR46 | 2 | Undo capacity-refusal status |
| FR47 | 1 | Diff-based incremental render |
| FR48 | 1 | `Ctrl-L` full refresh |
| FR49 | 1 | Status line on row 24 |
| FR50 | 1 | No-op on unsupported commands (status feedback) |
| FR51 | 2 | I/O failure surfaces in status line |
| FR52 | 2 | No silent data loss; buffer stays dirty on save error |

## Epic List

### Epic 1: Editor Foundations & On-Hardware Bring-Up

VIBE assembles cleanly, launches on real MicroBeast hardware, displays an empty buffer with a status line, transitions between modes via `Esc`, refuses unbound keys with a beep, redraws via diff, recovers from drift via `Ctrl-L`, and exits cleanly to CCP. The smoke-test foundation: nothing edits yet, but the bones are visibly correct on hardware. Closes the two PRD-named technical risks (Esc/arrow disambiguation, gap-buffer correctness) before any feature work depends on them.

**FRs covered:** FR12, FR13 (mode transition only), FR14 (mode transition only), FR15 (mode transition only), FR16, FR17, FR47, FR48, FR49, FR50.

**Primary NFRs addressed:** NFR1 (incremental render), NFR3 (cursor latency), NFR4 (Esc disambig 1–2 tick window), NFR5 (no crashes), NFR7 (screen-state recoverability), NFR8 (BDOS rc check), NFR9 (code budget), NFR10 (TPA fit), NFR11 (single .COM), NFR12 (static alloc), NFR13 (single platform), NFR14 (sjasmplus 1.23.0), NFR15 (CP/M 2.2 BDOS only), NFR16 (knob centralization), NFR17 (mode/operator decoupling), NFR18 (reproducible build).

**Architectural deliverables:** AR1–AR5 (skeleton + build), AR6–AR11 (shared headers), AR12–AR16 (cross-cutting funnels: status, render, gap-buffer mutation, BDOS gateway, message-string convention), AR17–AR21 (test harness scaffold), AR22–AR25 (naming, file structure, format, include order).

### Epic 2: Native Authoring Workflow (Compose, Edit, Save)

PRD Journey 1a complete. Author can launch `vibe game.fs`, compose source in insert mode, navigate with motions (counted), edit with operator+motion composition, undo a typo, yank/paste, save with `:w` (or `:wq`), quit with `:q`, force-quit with `:q!`, save-as with `:w filename`, and reopen a different file with `:e filename` (or `:e!` to force). File-I/O errors surface in the status line; the buffer stays dirty until either a successful save or explicit `:q!` — no silent data loss.

**FRs covered:** FR1, FR2, FR3, FR4, FR5, FR6, FR7, FR8, FR9, FR10, FR11, FR13 (insert-mode behavior), FR14 (ex-command parsing & dispatch), FR18, FR19, FR20, FR21, FR22, FR23, FR24, FR25, FR26, FR27, FR28, FR29, FR30, FR31, FR32, FR39, FR40, FR45, FR46, FR51, FR52.

**Modules touched:** `motions.asm`, `edits.asm`, `undo.asm`, `exline.asm`, `fileio.asm`, `parser.asm` (operator+motion composition glue).

**NFRs primarily addressed:** NFR2 (sustained typing), NFR6 (no silent data loss), NFR8 (BDOS rc check at every fileio call site).

### Epic 3: Iterate, Search & Region Operations

PRD Journey 1b (search-driven debug iteration) and Journey 2 (visual region edits) become practical. User can `/dup` to find, `n` to advance with end-of-buffer wrap notice, "pattern not found" status when there's no match. Visual character/line/block selection with `d`/`y`/`c`/`>`/`<`/`~` operators applied to selections.

**FRs covered:** FR15 (visual-mode behavior), FR33, FR34, FR35, FR36, FR37, FR38, FR41, FR42, FR43, FR44.

**Modules touched:** `search.asm`, `visual.asm`.

## Epic 1: Editor Foundations & On-Hardware Bring-Up

VIBE assembles cleanly, launches on real MicroBeast hardware, displays an empty buffer with a status line, transitions between modes via `Esc`, refuses unbound keys with a beep, redraws via diff, recovers from drift via `Ctrl-L`, and exits cleanly to CCP. Closes the two PRD-named technical risks (Esc/arrow disambiguation, gap-buffer correctness) before any feature work depends on them.

### Story 1.1: Project skeleton & reproducible build

As the VIBE author,
I want a project skeleton that assembles cleanly under sjasmplus 1.23.0 with a reproducible build,
So that every subsequent module has a working build target and NFR18's byte-identical-rebuild floor is established from day one.

**Acceptance Criteria:**

**Given** a clean checkout of the repo
**When** I run `make`
**Then** sjasmplus 1.23.0 assembles `src/vibe.asm` and produces `vibe.com` in the project root
**And** the .com file's first byte sits at `ORG 0x0100` (verifiable by sjasmplus listing)

**Given** the skeleton is committed
**When** I inspect the repo
**Then** `src/vibe.asm` contains `ORG 0x0100` followed by a minimal stub (e.g., BDOS function 0 exit)
**And** the directory tree matches the architecture's "Complete Project Directory Structure": `src/`, `inc/`, `test/`, `build/`, top-level `Makefile`, `README.md`, `.gitignore`
**And** `inc/` contains placeholder files for `equates.inc`, `bios.inc`, `bdos.inc`, `vt52.inc`, `modes.inc`, `state.inc` (empty or minimal — populated in subsequent stories)

**Given** `vibe.com` has been built
**When** I run `make clean && make` from the same checkout twice
**Then** both `vibe.com` outputs have the same SHA-256 hash (NFR18 baseline)
**And** no `--date` or host-path-embedding flags appear in the sjasmplus invocation

**Given** the Makefile exists
**When** I inspect its targets
**Then** at minimum `all` (default → `vibe.com`), `clean`, and a stub `test` are defined
**And** sjasmplus is invoked as `sjasmplus --nologo --msg=err --raw=vibe.com --lst=build/vibe.lst --sld=build/vibe.sld src/vibe.asm` (BA2)

**Given** the `.gitignore` is in place
**When** I run `git status` after `make`
**Then** `vibe.com`, `build/`, `*.lst`, `*.sld`, `*.bin`, swap files are excluded
**And** only source files appear as tracked

**Given** the `README.md` exists
**When** I open it
**Then** it documents prerequisites (sjasmplus 1.23.0, Make, iz-cpm), build commands (`make`, `make test`), transfer command (`make push`), and links to `architecture.md`
**And** it explicitly states this is a dev-loop README, not user documentation

### Story 1.2: Compile-time constants (equates, modes, vt52)

As the VIBE author,
I want all compile-time constants centralised in named-equate header files,
So that NFR16's "no magic numbers" rule has a single source of truth and future tuning happens by editing one place.

**Acceptance Criteria:**

**Given** the constants headers
**When** I inspect `inc/equates.inc`
**Then** it defines: `GAP_BUFFER_BASE`, `GAP_BUFFER_MAX` (initial 32768), `UNDO_BUFFER_SIZE` (256), `STATUS_LINE_WIDTH` (80), `EX_COMMAND_BUFFER` (64), `SEARCH_PATTERN_BUFFER` (64), `YANK_BUFFER_SIZE` (1024), `SCREEN_ROWS` (24), `SCREEN_COLS` (80), `EDITABLE_ROWS` (23), `ESC_TIMEOUT_TICKS` (2)
**And** every constant has a one-line comment explaining its meaning

**Given** the modes header
**When** I inspect `inc/modes.inc`
**Then** it defines `MODE_NORMAL`, `MODE_INSERT`, `MODE_COMMAND`, `MODE_VISUAL`
**And** `VIS_CHAR`, `VIS_LINE`, `VIS_BLOCK` (visual sub-modes)
**And** synthesized arrow keycodes `KEY_ARROW_UP` (0x80), `KEY_ARROW_DOWN` (0x81), `KEY_ARROW_LEFT` (0x82), `KEY_ARROW_RIGHT` (0x83) — placed above ASCII so they cannot collide with normal keys (V1)

**Given** the VT52 header
**When** I inspect `inc/vt52.inc`
**Then** it defines `VT52_ESC` (0x1B), `VT52_CURSOR_HOME` ('H'), `VT52_CLEAR_SCREEN` ('J'), `VT52_ERASE_TO_EOL` ('K'), `VT52_GOTO` ('Y') and any other VT52 control bytes used by the renderer
**And** comments document the ESC-prefixed sequence form (e.g., `; ESC Y row+0x20 col+0x20`)

**Given** the headers are included by `src/vibe.asm` in dependency order
**When** I run `make`
**Then** assembly succeeds with no symbol redefinitions or forward-reference errors
**And** the output `vibe.com` remains byte-identical to the previous story's stub (no constants are referenced yet)

**Given** the casing convention (UPPER_SNAKE for compile-time)
**When** I inspect any equate definition
**Then** it uses UPPER_SNAKE_CASE per AR22

### Story 1.3: Static memory map (state.inc)

As the VIBE author,
I want all cross-module runtime state declared in a single `inc/state.inc` memory map,
So that MC7's "no inline addresses" rule holds, every module reads/writes shared state by symbolic name, and the static footprint is auditable in one place.

**Acceptance Criteria:**

**Given** `inc/state.inc`
**When** I inspect the static-data block
**Then** it declares the single-byte / small state at fixed labels: `mode_byte`, `visual_submode`, `buffer_dirty`, `pending_operator`, `pending_motion_prefix`, `yank_kind`, `status_dirty`
**And** declares the 16-bit state: `cursor_offset`, `gap_start`, `gap_end`, `visual_anchor`, `count_accumulator`, `yank_length`, `top_line_offset`
**And** declares the buffers: `status_buffer` (`STATUS_LINE_WIDTH` bytes), `search_pattern` (1 length byte + `SEARCH_PATTERN_BUFFER` bytes), `ex_buffer` (1 length byte + `EX_COMMAND_BUFFER` bytes), `filename_buffer` (16 bytes), `shadow_buffer` (`SCREEN_ROWS * SCREEN_COLS` = 1920 bytes), `dirty_rows` (3 bytes for 24-row bitmap), `undo_buffer` (`UNDO_BUFFER_SIZE` bytes)
**And** every label uses lowercase per AR22

**Given** the memory map is included
**When** assembly completes
**Then** the listing file shows the static-data block placed after code and before the gap buffer
**And** the gap buffer base address (`GAP_BUFFER_BASE`) resolves to the first address past the static block, not earlier

**Given** the yank register address policy (SR6)
**When** I inspect where `yank_buffer` is placed
**Then** it is defined as an EQU at `GAP_BUFFER_BASE + GAP_BUFFER_MAX` (in the reserved pool) — not in `state.inc`'s DEFS block
**And** a comment in `state.inc` documents this placement and points at the yank-buffer EQU

**Given** placeholder values
**When** the .com is built
**Then** the .com remains byte-identical to the previous story (no code reads state yet) — verifiable by SHA-256

**Given** the layout
**When** I inspect the listing file post-build
**Then** the final symbol address (end of static data + gap buffer + yank register) is below 0xD800 (NFR10 TPA fit verifiable)

### Story 1.4: BIOS/BDOS shims with BDOS_CALL macro

As the VIBE author,
I want BIOS jump-table addresses and BDOS function numbers in named-equate headers, plus a `BDOS_CALL` macro that checks every return code,
So that NFR8 (BDOS rc check completeness) and NFR15 (CP/M 2.2 BDOS only) are enforced at every call site by convention.

**Acceptance Criteria:**

**Given** `inc/bios.inc`
**When** I inspect it
**Then** it defines `BIOS_CONIN`, `BIOS_CONINST`, `BIOS_CONOUT`, `BDOS_ENTRY` (0x0005), `DEFAULT_FCB` (0x005C), `DEFAULT_DMA` (0x0080), and a tick-counter address symbol
**And** the BIOS jump-table addresses are documented as placeholders to be confirmed against MicroBeast BIOS docs in story 1.12 (Watchpoint W1)
**And** a comment header explains these must be sourced from the MicroBeast BIOS jump table, not invented

**Given** `inc/bdos.inc`
**When** I inspect it
**Then** it defines exactly the CP/M 2.2 BDOS function numbers VIBE will use: `BDOS_CONOUT` (2), `BDOS_OPEN` (15), `BDOS_CLOSE` (16), `BDOS_DELETE` (19), `BDOS_READ_SEQ` (20), `BDOS_WRITE_SEQ` (21), `BDOS_MAKE` (22), and any other 2.2-only functions used
**And** no CP/M 3.x or MicroBeast-specific BDOS calls are present (NFR15)

**Given** the `BDOS_CALL` macro definition (in `inc/bdos.inc`)
**When** I expand it with a sample function number `fn`
**Then** the macro expands to: `LD C, fn` + `CALL BDOS_ENTRY` + return-value check that routes any error code into a single `bdos_error_funnel` label
**And** the funnel calls `status_set_message` with an appropriate error string and aborts the current operation cleanly (returns to the input loop, not crash)
**And** the macro is documented as the only allowed entry point to BDOS — raw `CALL 0x0005` is forbidden by convention (AR15)

**Given** the macro is in place
**When** I write a smoke test that issues `BDOS_CALL BDOS_OPEN` against a non-existent FCB and observe behavior under iz-cpm
**Then** the BDOS error code is detected, the funnel is entered, and the test program exits cleanly (does not crash, does not loop)

**Given** the headers are included by `src/vibe.asm` in dependency order before any code module
**When** `make` runs
**Then** assembly succeeds; `vibe.com` remains byte-identical (no code uses BDOS yet from the stub)

**Given** the casing rules
**When** I inspect the macro definition
**Then** `BDOS_CALL` uses UPPER_SNAKE_CASE per AR22 (macros are compile-time)

### Story 1.5: Status-line module with single-message funnel

As the VIBE author,
I want `src/statusln.asm` exposing `status_set_message` as the single error/info funnel, plus the message-string convention table,
So that MC5 (single status funnel) holds for every later module and AR16 (lowercase, no period, under 30 chars) is established with concrete examples.

**Acceptance Criteria:**

**Given** `src/statusln.asm`
**When** I inspect its module header
**Then** it documents Module/Purpose/Public (`status_set_message`, `status_render`)/State owned (`status_buffer`, `status_dirty`)/register conventions/dependencies

**Given** the public entry `status_set_message`
**When** I inspect its routine contract
**Then** it specifies `In: HL = pointer to null-terminated message string, A = optional error code (zero for non-error)`, `Out: (none — side effect: status_buffer populated, status_dirty set)`, `Trashes: A, BC, DE, HL`, `Calls: (none)`
**And** the implementation copies up to `STATUS_LINE_WIDTH` bytes from `(HL)` into `status_buffer`, pads with spaces to width, and sets `status_dirty` to nonzero

**Given** the message-string table near end-of-code
**When** I inspect it
**Then** it defines at minimum: `msg_buffer_modified`, `msg_file_too_large`, `msg_pattern_not_found`, `msg_search_wrapped`, `msg_undo_too_large`, `msg_nothing_to_undo`, `msg_no_write`
**And** every message conforms to AR16: all lowercase, no trailing period, target under 30 characters
**And** every string is null-terminated (per AR24 default)

**Given** a headless test under iz-cpm calls `status_set_message` with a sample string
**When** the test inspects `status_buffer` and `status_dirty` after the call
**Then** `status_buffer` contains the message bytes (truncated/padded to 80)
**And** `status_dirty` is nonzero
**And** the sentinel byte at `0xCFFE` is set to pass

**Given** the no-direct-write rule (AR12)
**When** I grep the source tree for writes to `status_buffer`
**Then** the only writer is `statusln.asm`'s `status_set_message`

**Given** `status_render` (preliminary stub)
**When** I inspect it
**Then** it has a routine contract documenting it will (in story 1.11) emit the status row via the same diff path used by main render — for now it's a stub that simply clears `status_dirty` after a no-op

### Story 1.6: Headless test harness scaffold

As the VIBE author,
I want a working `make test` target that builds every `test/cases/*.asm` to a `.com` and runs each under iz-cpm with a 5-second timeout, signalling pass/fail via the sentinel byte at 0xCFFE,
So that every later headless-testable layer has a mechanical CI-style harness and the architecture's TH1/TH2/TH3 conventions are concretely realised.

**Acceptance Criteria:**

**Given** `test/Makefile`
**When** I inspect it
**Then** it iterates over `test/cases/*.asm`, assembles each to a `.com` (sjasmplus 1.23.0 with the same flags as the main build), runs each under iz-cpm with a 5-second per-case timeout, reports per-case pass/fail
**And** any case timing out or returning a non-zero sentinel byte counts as fail
**And** the top-level `make test` recurses into `test/Makefile` and exits non-zero on any failure

**Given** `test/inc/test_prologue.inc`
**When** I inspect it
**Then** it defines `ORG 0x0100`, `TEST_RESULT EQU 0xCFFE`, and a `test_start:` entry that zeros both bytes at 0xCFFE/0xCFFF
**And** test cases `INCLUDE` it as their entry boilerplate

**Given** `test/inc/test_epilogue.inc`
**When** I inspect it
**Then** it defines `test_pass:` (zero sentinel + BDOS function 0 exit) and `test_fail:` (write A as fail code to 0xCFFE, B as context to 0xCFFF, BDOS function 0 exit)

**Given** at least two demo test cases (`test/cases/harness_pass.asm` and `test/cases/harness_fail.asm`) wired through the harness
**When** I run `make test`
**Then** the pass case shows green, the fail case shows red with the fail code visible in the report
**And** the harness's sentinel-byte detection is confirmed both ways

**Given** `test/fixtures/`
**When** I inspect the directory
**Then** at least one stub fixture file is present and the iz-cpm B: drive mount mechanism is documented in `test/README.md`
**And** the README explains how to add new fixture files for FCB-level tests (referenced by stories 2.2 and 2.4)

**Given** `test/cases/<module>_<scenario>.asm` naming (TH2)
**When** I inspect demo cases
**Then** they follow the pattern (lowercase, hyphenated scenario)

**Given** `make test` is run twice on the same checkout
**When** I compare per-case `.com` SHA-256 hashes
**Then** they match (test-case builds reproducible per NFR18)

### Story 1.7: Gap buffer primitives + headless tests

As the VIBE author,
I want `src/gapbuf.asm` exposing `gapbuf_init`, `gapbuf_insert`, `gapbuf_delete`, `gapbuf_move_gap`, with comprehensive headless tests under iz-cpm,
So that PRD risk-rank-2 (gap buffer correctness) is closed before any motion/edit handler depends on it, and the two-halves invariant is mechanically validated.

**Acceptance Criteria:**

**Given** `src/gapbuf.asm` module header
**When** I inspect it
**Then** it documents `Public: gapbuf_init, gapbuf_insert, gapbuf_delete, gapbuf_move_gap, gapbuf_load`, `State owned: gap_start, gap_end, cursor_offset`, register conventions, dependencies on `equates.inc` and `state.inc`

**Given** `gapbuf_init`
**When** I call it
**Then** `gap_start = GAP_BUFFER_BASE`, `gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX`, `cursor_offset = 0`
**And** post-init the buffer contains an empty file (gap = full size)

**Given** `gapbuf_insert` (`In: A = byte to insert`, `Out: CF = 0 success / CF = 1 buffer-full`)
**When** I call it with byte 'X' on an empty buffer at `cursor_offset 0`
**Then** `gap_start` advances by 1, the byte 'X' lands at the original `gap_start` address, CF = 0
**And** subsequent reads through the two-halves walk produce "X" as the file contents

**Given** `gapbuf_insert` when the gap is full (`gap_start == gap_end`)
**When** I call it with any byte
**Then** CF = 1
**And** `status_set_message` is called with `msg_file_too_large` or equivalent
**And** buffer state is unchanged (no partial write, no pointer corruption)

**Given** `gapbuf_delete` (operates at cursor)
**When** I call it at `cursor_offset 0` (BOF)
**Then** CF = 1, no state change

**Given** `gapbuf_delete` mid-buffer
**When** I call it
**Then** the byte logically before the cursor is consumed by extending the gap leftward (`gap_start` decrements)
**And** subsequent file-content walk reflects the deletion

**Given** `gapbuf_move_gap` (`In: HL = target logical offset`)
**When** I call it
**Then** the gap is moved to the target offset by copying bytes between the two halves (memcpy direction depends on whether target is before or after current gap)
**And** the two-halves invariant holds post-move (file content unchanged; only gap position differs)

**Given** test cases under `test/cases/gapbuf_*.asm`
**When** I run `make test`
**Then** the following pass: `gapbuf_insert-empty.asm`, `gapbuf_insert-fills-buffer.asm`, `gapbuf_delete-at-bof.asm`, `gapbuf_move-roundtrip.asm`, `gapbuf_random-ops.asm` (100-iteration random insert/delete/move sequence with two-halves invariant checked after each op via a checksum helper)

**Given** the architecture's "every BDOS call via BDOS_CALL" rule (AR15)
**When** I grep `gapbuf.asm` for `CALL 0x0005`
**Then** there are no raw BDOS calls — gap buffer is pure-memory and does not touch BDOS

**Given** `gapbuf_load` is referenced in the public list
**When** I inspect it for this story
**Then** it is a stub returning CF=1 with a "not yet implemented" status message — full implementation lands in story 2.2
**And** the stub is marked TODO with a reference to story 2.2

### Story 1.8: Input layer with Esc/arrow disambiguation

As the VIBE author,
I want `src/input.asm` exposing `input_get_key` that polls `BIOS_CONIN`, performs the 1–2 tick Esc/arrow disambiguation per RI5, and synthesizes single-byte keycodes for arrow keys,
So that PRD risk-rank-1 is closed and the dispatch layer's binary-search contract holds (single-byte key in A, no register-passed composites).

**Acceptance Criteria:**

**Given** `src/input.asm` module header
**When** I inspect it
**Then** it documents `Public: input_get_key`, `State owned: (none — reads BIOS tick counter)`, register conventions, dependencies on `bios.inc`, `equates.inc` (`ESC_TIMEOUT_TICKS`), `modes.inc` (`KEY_ARROW_*`)

**Given** `input_get_key` (`In: (none)`, `Out: A = single-byte keycode (ASCII or KEY_ARROW_*)`)
**When** I press a printable key (e.g., 'a')
**Then** A = 0x61 is returned within one input-loop iteration

**Given** I press a control character (e.g., Ctrl-L = 0x0C)
**When** `input_get_key` is invoked
**Then** A = 0x0C is returned (control bytes pass through; with BDOS bypassed, all controls arrive raw per platform constraints)

**Given** I press bare Esc with no follow-up byte within `ESC_TIMEOUT_TICKS` 50 Hz ticks (default 2 ticks, ~40 ms)
**When** `input_get_key` is invoked
**Then** A = 0x1B (bare-Esc treatment)

**Given** I press Esc followed quickly by 'A' (VT52 cursor-up sequence)
**When** `input_get_key` is invoked
**Then** A = `KEY_ARROW_UP` (0x80) is returned
**And** similarly: ESC B → `KEY_ARROW_DOWN` (0x81); ESC D → `KEY_ARROW_LEFT` (0x82); ESC C → `KEY_ARROW_RIGHT` (0x83)

**Given** I press Esc followed by an unrecognized byte
**When** `input_get_key` is invoked
**Then** the routine treats it as bare Esc and returns A = 0x1B; the follow-up byte is queued for the next call (or returned directly — implementation-documented)

**Given** the tick-poll loop
**When** I inspect it
**Then** it uses `BIOS_CONINST` (non-blocking query) inside a tick-counted wait, blocking on the 50 Hz tick variable
**And** worst-case bare-Esc latency is bounded by `ESC_TIMEOUT_TICKS × 20 ms` ≈ 40 ms (NFR4)

**Given** sustained typing (NFR2)
**When** dispatch drains keys via `input_get_key` in a tight loop
**Then** no keystrokes are dropped at typical human speeds (≥10 chars/sec)
**And** input does not internally buffer beyond what BIOS provides

**Given** UAT on real MicroBeast hardware
**When** the author exercises typing, bare-Esc, and arrow keys with `ESC_TIMEOUT_TICKS` at the source default
**Then** bare-Esc feels responsive (no perceptible lag)
**And** arrow keys are recognized reliably (no false bare-Esc)
**And** if the timeout feels off, the chosen value is tuned in `equates.inc` and committed back

**Given** no automated test for Esc timing (per architecture: deferred to UAT)
**When** I review the test plan
**Then** the headless harness does not attempt to validate Esc/arrow timing — UAT is the gate

### Story 1.9: Mode dispatch with sparse-table binary search

As the VIBE author,
I want `src/dispatch.asm` exposing `dispatch_key`, plus per-mode sparse sorted (key, handler_addr) tables and per-mode unbound-key fall-through handlers,
So that MC3's binary-search dispatch contract holds, FR12/FR16/FR50 are realized, and the ~1.8 KB code-budget reclamation vs flat 256-entry tables is achieved.

**Acceptance Criteria:**

**Given** `src/dispatch.asm` module header
**When** I inspect it
**Then** it documents `Public: dispatch_key`, four per-mode tables (`dispatch_normal`, `dispatch_insert`, `dispatch_command`, `dispatch_visual`), four unbound-key handlers, and entry-count equates per table

**Given** `dispatch_key` (`In: A = key, HL = base of mode table, B = entry count`, `Out: jumps to handler or unbound fall-through`)
**When** I call it with a key present in the table
**Then** binary search locates the entry in ≤ 6 iterations and jumps to the handler address from the table entry

**Given** `dispatch_key` is called with a key not in the table
**When** binary search exhausts (lo == hi)
**Then** control transfers to the per-mode unbound-key handler

**Given** the unbound handler for `MODE_NORMAL` (and `MODE_VISUAL`)
**When** invoked
**Then** it calls `status_set_message` with a beep/no-op message (or emits a beep byte), leaves all editor state unchanged, returns to the input loop (FR50)

**Given** the unbound handler for `MODE_INSERT`
**When** invoked
**Then** it treats the key as a literal-byte insertion stub (full insert in story 2.8 — for Epic 1 it's a no-op or a "insert mode (stub)" status)
**And** does not crash on any input

**Given** Epic 1's per-mode tables with stub entries for mode-transition keys
**When** I inspect `dispatch_normal`
**Then** it contains entries for `i` (enter insert), `a` (enter insert at next), `o`/`O` (stubs), `:` (enter command mode), `v` (enter visual), `/` (search prompt stub), `Ctrl-L` (full refresh), and a temporary debug-quit key (e.g., Ctrl-Q) that exits via BDOS function 0
**And** all stub entries route to mode-change handlers that update `mode_byte` (and `visual_submode` if entering visual) and call `status_set_message` to refresh the mode indicator
**And** Esc handler in INSERT/COMMAND/VISUAL tables sets `mode_byte = MODE_NORMAL`

**Given** `dispatch_command` and `dispatch_visual` in Epic 1
**When** I inspect them
**Then** they contain only Esc → return to normal (FR16) — concrete handlers land in 2.1 / 3.3

**Given** sparse sorted dispatch tables
**When** I inspect each
**Then** entries are sorted ascending by key (hand-ordered in source per MC3)
**And** each entry is exactly 3 bytes (1-byte key + 2-byte handler address)
**And** total dispatch table footprint across all four modes is under 256 bytes

**Given** headless tests under `test/cases/dispatch_*.asm`
**When** I run `make test`
**Then** the following pass: `dispatch_binary-search-finds-key.asm`, `dispatch_binary-search-misses.asm`, `dispatch_mode-transition.asm`

**Given** the calling convention (MC1, MC4)
**When** I inspect handler entries
**Then** each handler is a `RET`-terminating routine that operates on global state (no register-passed parameters) and is caller-saved

### Story 1.10: Command parser (count + pending operator + motion-prefix)

As the VIBE author,
I want `src/parser.asm` implementing the count accumulator, pending-operator byte, and motion-prefix byte state machines, with headless tests against stub motion handlers,
So that MC4's classic vi two-stage operator/motion structure is in place before any real motion or edit handler lands in Epic 2.

**Acceptance Criteria:**

**Given** `src/parser.asm` module header
**When** I inspect it
**Then** it documents `Public: parser_handle_digit, parser_handle_operator, parser_handle_motion_prefix, parser_dispatch, parser_clear`, `State owned: count_accumulator, pending_operator, pending_motion_prefix`, dependencies

**Given** `parser_handle_digit` (`In: A = '0'..'9'`)
**When** invoked with a non-zero digit (e.g., '5')
**Then** `count_accumulator = count_accumulator * 10 + 5` (16-bit math)
**And** subsequent calls accumulate digits

**Given** `parser_handle_digit` called with '0' as the first digit (no count yet)
**When** invoked
**Then** the parser does NOT accumulate — '0' is the motion `0` (line-start), not a count digit
**And** control falls through to the motion handler for '0'

**Given** `parser_handle_digit` called with '0' when count > 0
**When** invoked
**Then** count becomes count*10 (e.g., '1','0' → 10)

**Given** `parser_handle_operator` (`In: A = operator byte 'd'/'y'/'c'/'>'/'<'`)
**When** invoked with no pending operator
**Then** `pending_operator = A`

**Given** `parser_handle_operator` called when `pending_operator == A` (doubled-operator detection)
**When** invoked
**Then** the parser dispatches the doubled-operator command (calls a stub `op_handle_doubled` that records the dispatch via a sentinel for tests)
**And** clears `pending_operator` and `count_accumulator` post-dispatch

**Given** `parser_handle_motion_prefix` (`In: A = prefix byte, currently 'g'`)
**When** invoked
**Then** `pending_motion_prefix = A`

**Given** a motion key arrives while `pending_motion_prefix == 'g'`
**When** the parser dispatches
**Then** if the motion is also 'g', the `gg` motion is dispatched (V3); otherwise the prefix is cleared and the key re-dispatched through normal mode

**Given** `parser_dispatch` (entry called when a motion completes the pending command)
**When** invoked with a motion handler address
**Then** it calls the motion handler with `count_accumulator` available
**And** post-dispatch, `count_accumulator`, `pending_operator`, `pending_motion_prefix` are all cleared (`parser_clear`)

**Given** `parser_clear`
**When** invoked (e.g., on Esc)
**Then** all three accumulator-state bytes are zeroed

**Given** headless tests under `test/cases/parser_*.asm` against stub motion handlers
**When** I run `make test`
**Then** the following pass: `parser_count-accumulator.asm`, `parser_leading-zero-is-motion.asm`, `parser_zero-after-digit.asm`, `parser_doubled-operator-dd.asm`, `parser_compose-count-op-motion.asm`, `parser_motion-prefix-gg.asm`, `parser_motion-prefix-cleared-on-other-key.asm`

**Given** the parser is stateless w.r.t. modes (it operates only when invoked from normal-mode dispatch)
**When** I inspect dispatch.asm's normal-mode table
**Then** digits ('0'..'9'), operators ('d', 'y', 'c', '>', '<'), motion-prefix ('g') route to the corresponding parser entry points

### Story 1.11: Render pipeline with dirty rows, scroll, Ctrl-L

As the VIBE author,
I want `src/render.asm` exposing `render_diff` (per-row dirty bitmap + cell-by-cell shadow compare) and `render_full` (Ctrl-L), plus scroll behavior anchored at `top_line_offset`,
So that NFR1, NFR3, NFR7, FR47, FR48, and V2 are realized.

**Acceptance Criteria:**

**Given** `src/render.asm` module header
**When** I inspect it
**Then** it documents `Public: render_init, render_diff, render_full, render_mark_row_dirty, render_mark_all_dirty`, `State owned: shadow_buffer, dirty_rows, top_line_offset`, dependencies

**Given** `render_init`
**When** invoked at startup
**Then** the screen is cleared (single `ESC J` emitted via `BIOS_CONOUT`), `shadow_buffer` is filled with spaces, `dirty_rows` is zeroed, `top_line_offset` is zeroed

**Given** `render_full` (Ctrl-L path)
**When** invoked
**Then** all 24 row-dirty bits are set, `render_diff` is called, the full screen is re-emitted from buffer state
**And** `shadow_buffer` is fully reconciled with emitted content
**And** the cursor is repositioned to `cursor_offset`'s row/col after the diff completes (RI4)

**Given** `render_diff` (the normal-frame path)
**When** invoked with some dirty rows set
**Then** scroll-adjustment runs first: if `cursor_offset` maps to a row outside rows 0..22, `top_line_offset` advances or retreats by walking line breaks until the cursor is back in range, and all editable rows are marked dirty (V2)
**And** for each dirty row, the renderer walks cells 0..79, compares against `shadow_buffer`, emits one `ESC Y row col` followed by the run of changed characters per contiguous run
**And** `shadow_buffer` is updated with emitted bytes
**And** `dirty_rows` is cleared after the pass
**And** `status_render` is called if `status_dirty` is set, emitting the status row via the same diff approach
**And** the cursor is repositioned via one final `ESC Y row col` emitted last (RI4)

**Given** the cursor-row-recompute path
**When** the renderer walks line breaks from `top_line_offset`
**Then** the cost is bounded by visible-region size (~1920-byte scan worst case) per W2 — sub-perceptible

**Given** `render_mark_row_dirty` (`In: A = row 0..23`)
**When** invoked
**Then** the corresponding bit in the 3-byte `dirty_rows` bitmap is set

**Given** `render_mark_all_dirty`
**When** invoked
**Then** all 24 row bits are set

**Given** Ctrl-L from the user
**When** dispatched
**Then** `render_full` is invoked and the screen fully re-drawn (FR48, NFR7)

**Given** headless tests under `test/cases/render_*.asm` exercising diff math against synthetic frames
**When** I run `make test`
**Then** the following pass: `render_diff-no-changes.asm`, `render_diff-single-row-change.asm`, `render_diff-contiguous-runs.asm`, `render_full-marks-all-dirty.asm`, `render_scroll-cursor-below-visible.asm`

**Given** the architecture rule: only `render.asm` calls `BIOS_CONOUT` (AR13)
**When** I grep the source tree for `BIOS_CONOUT`
**Then** the only references are in `render.asm` (and `init.asm`'s declared exception for the initial clear)

**Given** the diff-only emission rule (NFR1)
**When** an idle frame is rendered
**Then** zero content bytes are emitted (apart from the trailing cursor-position re-emit ≈ 4 bytes — acceptable per RI4 defensive policy)

### Story 1.12: Init/teardown + on-hardware smoke test

As a MicroBeast resident developer,
I want a working `vibe.com` that I can SLIDE-push and run on real hardware, displaying an empty buffer with a status line, switching modes via `Esc`, refusing unbound keys with a beep, redrawing on `Ctrl-L`, and exiting cleanly via a temporary debug-quit key,
So that the foundation layer is end-to-end validated on the only platform that matters and Epic 2's feature work can begin against a known-good base.

**Acceptance Criteria:**

**Given** `src/init.asm` module header
**When** I inspect it
**Then** it documents `Public: init_cold_start, init_teardown`, dependencies on every other Epic-1 module

**Given** `init_cold_start`
**When** invoked at .com entry (from `src/vibe.asm`'s `ORG 0x0100 + JP main`)
**Then** it confirms the `BIOS_*` jump-table addresses against the running MicroBeast BIOS (filling Watchpoint W1)
**And** initialises `mode_byte = MODE_NORMAL`, all parser state zeroed, `cursor_offset = 0`, `gap_start/gap_end` via `gapbuf_init`, `top_line_offset = 0`
**And** stub-parses the default FCB at 0x005C — for Epic 1 the filename is ignored (full FCB parsing in story 2.3); the buffer always starts empty
**And** calls `render_init` then immediately `render_full` to draw the empty buffer + status line ("NORMAL")

**Given** `init_teardown`
**When** invoked (via the temporary debug-quit key)
**Then** it emits `ESC J` (clear screen) + cursor home, exits via BDOS function 0 (warm boot)
**And** control returns to CCP cleanly — no garbled state, no stuck cursor

**Given** `src/vibe.asm`'s main loop
**When** the editor is running
**Then** the loop is `input_get_key` → `dispatch_key` (current mode's table) → handler → `render_diff` → repeat
**And** no periodic timer-driven render is invoked (idle = no emission, RI2)

**Given** I run `make` and SLIDE-push `vibe.com` to the MicroBeast
**When** I launch `vibe` from CCP
**Then** the screen clears and shows an empty 23-row editing area with a status line on row 24 displaying mode ("NORMAL"), filename (empty or `[no name]`), and a blank message area

**Given** the editor is at the prompt
**When** I press 'i'
**Then** `mode_byte` becomes `MODE_INSERT`, status updates to "INSERT" within one render frame
**And** any subsequent literal keystroke is no-op'd by the insert-mode unbound-key stub — no crash, no garbled state

**Given** I'm in INSERT mode
**When** I press Esc
**Then** within `ESC_TIMEOUT_TICKS` ticks, `mode_byte` returns to `MODE_NORMAL`, status shows "NORMAL"

**Given** I'm in NORMAL mode
**When** I press an unbound key (e.g., '!' or 'q')
**Then** the unbound-key handler emits a beep or status message; no state change; remain in NORMAL (FR50 validated on hardware)

**Given** I press Ctrl-L
**When** dispatched
**Then** `render_full` runs and the screen re-draws from buffer state

**Given** I press the temporary debug-quit key (e.g., Ctrl-Q — to be removed in story 2.1)
**When** dispatched
**Then** `init_teardown` runs and I'm at CCP with no terminal corruption

**Given** the `:` and `v` and `/` keys arrive at dispatch in NORMAL mode
**When** I press each
**Then** mode transitions to MODE_COMMAND / MODE_VISUAL / search-prompt-stub respectively, status updates, Esc returns to NORMAL — handlers within those modes are stubs until Epic 2/3

**Given** sustained typing of arbitrary keys for 30 seconds
**When** I observe the editor
**Then** no crashes, no terminal corruption, no stuck cursor, no mode confusion (NFR5 preliminary)
**And** Ctrl-L always restores a clean screen

**Given** the build artifact
**When** `make sizes` runs after this story
**Then** the per-section size report shows current code section size (NFR9 audit baseline) — early visibility into how much of the ~3 KB budget Epic 1 has consumed

## Epic 2: Native Authoring Workflow (Compose, Edit, Save)

PRD Journey 1a complete. Author can launch `vibe game.fs`, compose source in insert mode, navigate with motions (counted), edit with operator+motion composition, undo a typo, yank/paste, save with `:w` (or `:wq`), quit with `:q`, force-quit with `:q!`, save-as with `:w filename`, and reopen a different file with `:e filename` (or `:e!` to force). File-I/O errors surface in the status line; the buffer stays dirty until either a successful save or explicit `:q!` — no silent data loss.

### Story 2.1: Ex command-line infrastructure + :q / :q!

As a MicroBeast resident developer,
I want a working `:` command-line where I can type `:q` to quit (refused if unsaved) or `:q!` to force-quit,
So that I can exit VIBE through the proper vi mechanism and the temporary debug-quit key from story 1.12 can be removed.

**Acceptance Criteria:**

**Given** I'm in NORMAL mode and press `:`
**When** dispatched
**Then** `mode_byte = MODE_COMMAND`, the status row clears and shows ':' at column 0 with the cursor positioned immediately after, ready to accept characters
**And** `ex_buffer` (length-prefixed in state.inc) is reset to length 0

**Given** I'm in MODE_COMMAND typing characters
**When** each character arrives
**Then** it appends to `ex_buffer`, is echoed in the status row, the cursor advances
**And** Backspace deletes the previous character (and the rendered echo)
**And** Esc cancels: clears `ex_buffer`, sets `mode_byte = MODE_NORMAL`, clears the ex-line from the status row

**Given** I'm in MODE_COMMAND and press Enter
**When** dispatched
**Then** `exline.asm`'s parser dispatches the buffer contents through a small command table: `q` → `cmd_quit`, `q!` → `cmd_quit_force`, (more added by 2.2/2.4)
**And** unknown commands route to a "not an editor command" status message and return to NORMAL mode without crashing

**Given** I type `:q` and press Enter when `buffer_dirty == 0`
**When** dispatched
**Then** `init_teardown` runs and I'm back at CCP

**Given** I type `:q` and press Enter when `buffer_dirty != 0`
**When** dispatched
**Then** the quit is refused: `status_set_message` shows `msg_no_write` ("no write since last change"), mode returns to NORMAL, editor continues (BH5)

**Given** I type `:q!` and press Enter
**When** dispatched
**Then** `init_teardown` runs unconditionally — work is abandoned, control returns to CCP (FR8)

**Given** the temporary debug-quit key from story 1.12
**When** I inspect `dispatch_normal` post-2.1
**Then** the temporary key is removed; only `:q`/`:q!` exit paths exist
**And** no orphan handlers remain

**Given** UAT on hardware
**When** I launch vibe, press `:q`, observe quit; relaunch, press 'i', type a character (insert-mode literal stub from 1.12, will be replaced in 2.8 — for 2.1 the UAT step uses an existing dirty-marker shortcut: optionally a synthetic test entry that sets `buffer_dirty=1` for UAT purposes), `:q`, observe refusal; type `:q!`, observe quit
**Then** all three paths behave as specified, with no terminal corruption
**Note:** Full UAT for `:q` refusal depends on insert mode (story 2.8); a test-only path setting `buffer_dirty` is acceptable for 2.1's UAT, removed once 2.8 lands

**Given** headless tests under `test/cases/exline_*.asm`
**When** `make test` runs
**Then** the following pass: `exline_q-clean-buffer.asm`, `exline_q-dirty-buffer.asm`, `exline_q-bang-force.asm`, `exline_unknown-command.asm`

### Story 2.2: File load via :e filename (incl. :e!)

As a MicroBeast resident developer,
I want `:e filename` to load a file into the buffer (or `:e!` to force-load discarding changes), with errors surfaced in the status line and oversize files refused without modifying the buffer,
So that I can reopen files within a session (Journey 1b iteration) and FR6/FR9/FR10/FR11 hold under all error paths.

**Acceptance Criteria:**

**Given** I'm in NORMAL mode and the buffer is clean
**When** I type `:e foo.fs` and press Enter
**Then** the ex-parser invokes `cmd_edit` with the filename argument
**And** `fileio_load` is called: filename normalised to uppercase 8.3, drive prefix parsed (bare → drive B: per FR9; `A:foo.fs` → drive A: per FR10), an FCB is constructed, BDOS_OPEN issued via `BDOS_CALL`

**Given** the file exists and fits in the gap buffer
**When** sequential reads pull 128-byte sectors into `DEFAULT_DMA` (0x0080)
**Then** each sector is copied into the gap buffer's before-gap region; reading stops at BDOS EOF or first 0x1A
**And** post-load: `cursor_offset = 0`, gap is at end of file content, `buffer_dirty = 0`, `filename_buffer` holds the loaded name, all editable rows marked dirty
**And** the status row shows the filename + byte count (e.g., `foo.fs 134 bytes`)

**Given** the file does not exist (BDOS_OPEN returns error)
**When** the BDOS_CALL macro detects the error
**Then** `status_set_message` shows `can't open <filename>` (AR16 format), the existing buffer is NOT modified, mode returns to NORMAL (FR51 partial)

**Given** the file exceeds GAP_BUFFER_MAX
**When** load detects the size during sector read
**Then** the load is aborted, the gap buffer is reset to empty (or its prior state — implementation choice with rationale documented), `status_set_message` shows `msg_file_too_large`, the buffer presented is consistent — FR11

**Given** a write-protected drive or unreadable sector
**When** BDOS returns an unexpected error mid-read
**Then** the BDOS_CALL macro routes to the error funnel, partial buffer state is discarded with status indicating the failure, editor state is consistent

**Given** I type `:e foo.fs` while `buffer_dirty != 0`
**When** dispatched
**Then** the load is refused with `msg_no_write`, the existing buffer is preserved, mode returns to NORMAL (BH6)

**Given** I type `:e! foo.fs` while dirty
**When** dispatched
**Then** the load proceeds unconditionally — current changes are abandoned (BH6)

**Given** I type `:e` with no filename argument
**When** dispatched
**Then** `status_set_message` shows `missing filename` or similar; no load attempted

**Given** headless tests under `test/cases/fileio_*.asm` against fixtures in `test/fixtures/`
**When** `make test` runs
**Then** the following pass: `fileio_load-small-file.asm`, `fileio_load-with-1A-eof.asm`, `fileio_load-not-found.asm`, `fileio_load-too-large.asm`, `fileio_load-drive-prefix.asm`

**Given** UAT on hardware
**When** I launch vibe, type `:e bdos.txt` to load an existing file
**Then** screen renders the file, status row shows filename + byte count, mode is NORMAL, cursor at offset 0

### Story 2.3: Launch with filename argument

As a MicroBeast resident developer,
I want `vibe foo.fs` from CCP to launch directly into the loaded file,
So that the journey-1a workflow ("vibe game.fs and start typing") is realized in one keystroke from CCP.

**Acceptance Criteria:**

**Given** `init_cold_start` (extended from story 1.12)
**When** invoked at .com entry
**Then** it parses the default FCB at 0x005C: if the FCB drive byte and filename bytes are non-zero, treat as a filename argument and call `fileio_load` (same path as `:e`)
**And** if the FCB filename bytes are all spaces (no argument), the buffer remains empty (Epic 1 behavior preserved)

**Given** `vibe foo.fs` from CCP where `foo.fs` exists on drive B:
**When** the launch flow runs
**Then** the file is loaded, `cursor_offset = 0`, status shows `foo.fs` + byte count, screen is rendered with file content visible

**Given** `vibe a:bar.txt` from CCP
**When** launched
**Then** drive A: is targeted, file loaded, otherwise identical behavior

**Given** `vibe missing.fs` where the file doesn't exist
**When** launched
**Then** the editor still launches (does not abort), buffer is empty, `filename_buffer` holds `missing.fs`, `buffer_dirty = 0`, status shows `missing.fs [new file]` or equivalent (`:w` will create the file)

**Given** `vibe huge.fs` where the file exceeds `GAP_BUFFER_MAX`
**When** launched
**Then** the editor still launches, `status_set_message` shows `msg_file_too_large`, buffer is empty, `filename_buffer` is cleared
**And** no half-loaded buffer state survives

**Given** UAT on hardware
**When** I run `vibe foo.fs` from CCP for an existing file
**Then** the editor opens with the file loaded; pressing `:q` returns to CCP; relaunching loads the same content again

**Given** headless tests
**When** `make test` runs
**Then** added cases extend `fileio_*` with FCB-path coverage (a test that constructs a default FCB with a filename, calls the init logic, verifies load occurred)

### Story 2.4: File save (:w, :w filename, :wq)

As a MicroBeast resident developer,
I want `:w` (save), `:w filename` (save-as), and `:wq` (save and quit), with all CP/M write errors surfaced in the status line and the buffer staying dirty on failure,
So that the journey-1a workflow's save half closes (FR4/FR5/FR7) and no-silent-data-loss (NFR6, FR52) holds.

**Acceptance Criteria:**

**Given** I'm in NORMAL mode with `filename_buffer` populated and `buffer_dirty != 0`
**When** I type `:w` and press Enter
**Then** `cmd_write` is invoked with no argument; `fileio_save` writes to `filename_buffer`'s current name
**And** the save flow: BDOS_DELETE existing file (or BDOS_MAKE replaces — implementation choice with rationale documented), BDOS_MAKE new file, walk gap-buffer in two halves filling DMA in 128-byte chunks, BDOS_WRITE_SEQ each sector, append `0x1A` + space-pad to next 128-byte boundary, BDOS_CLOSE
**And** every BDOS call uses `BDOS_CALL`
**And** on success, `buffer_dirty = 0`, status shows `<filename> N bytes written` or similar

**Given** I type `:w newname.fs`
**When** dispatched
**Then** `cmd_write` is invoked with the argument; the same flow runs against `newname.fs`
**And** post-save, `filename_buffer` is updated to `newname.fs` (subsequent `:w` saves there) per FR5
**And** `buffer_dirty = 0`

**Given** I type `:wq`
**When** dispatched
**Then** the save runs first; if it succeeds, `init_teardown` runs and I return to CCP
**And** if the save fails, `init_teardown` does NOT run, status shows the error, buffer remains dirty, mode returns to NORMAL (FR52)

**Given** the destination drive is write-protected (e.g., A:)
**When** save attempts BDOS_MAKE
**Then** the BDOS error is detected by BDOS_CALL, status shows `can't write <filename>`, `buffer_dirty` remains nonzero, no partial file is left behind (or status indicates partial write) — FR51, FR52, NFR6

**Given** the disk fills mid-write
**When** BDOS_WRITE_SEQ returns an error
**Then** status indicates disk full, `buffer_dirty` stays nonzero, BDOS_CLOSE is still attempted to flush partial state, user is informed the save failed

**Given** I type `:w` with no `filename_buffer` (launched without arg, never `:e`'d)
**When** dispatched
**Then** status shows `no filename` or similar; no save attempted; mode returns to NORMAL

**Given** save completes and I read the file back
**When** I `:e <samename>` after the save
**Then** content matches what was in the buffer pre-save (no truncation, no padding artifacts visible)

**Given** FR1 final coverage (launch with no args, save creates file)
**When** I run `vibe`, type `:w foo.txt`, observe success
**Then** the empty file exists on B: drive and `:e foo.txt` reloads an empty buffer

**Given** headless tests
**When** `make test` runs
**Then** the following pass: `fileio_save-roundtrip.asm`, `fileio_save-write-protect.asm`, `fileio_save-empty-buffer.asm`, `fileio_save-1A-padding.asm`

**Given** UAT on hardware (full save UAT depends on insert mode in story 2.8)
**When** I `vibe foo.fs`, edit (after 2.8), `:w`, observe success; relaunch and verify content
**Then** round-trip works
**Note:** UAT for save-with-edits is gated on 2.8; UAT for save-empty-buffer is achievable in this story alone

### Story 2.5: Basic motions (h, j, k, l)

As a MicroBeast resident developer,
I want `h`, `j`, `k`, `l` to move the cursor by one character left, down, up, right respectively,
So that I can navigate within a buffer using vi muscle memory (FR18, FR19) and subsequent motion stories build on the cursor primitive.

**Acceptance Criteria:**

**Given** `src/motions.asm` module header
**When** I inspect it
**Then** it documents `Public: motion_h, motion_j, motion_k, motion_l` (and word/line/buffer entries to be added in 2.6), dependencies on `gapbuf.asm`, `state.inc`, register conventions

**Given** `motion_h`
**When** invoked
**Then** `cursor_offset` decreases by 1 (or `count_accumulator` if non-zero per BH2 clamp policy)
**And** if the move would cross a newline (logical previous line), it does NOT — `h` is intra-line per vi convention; clamps at line start
**And** if cursor is already at line start, no-op

**Given** `motion_l`
**When** invoked
**Then** `cursor_offset` increases by 1 (or count) per BH2
**And** clamps at end-of-line (does not cross newlines)

**Given** `motion_j` (down by one line)
**When** invoked
**Then** the cursor moves to the same column on the next line; if next line is shorter, clamps at that line's end; if there's no next line (at EOF), cursor stays put per BH2

**Given** `motion_k` (up by one line)
**When** invoked
**Then** symmetric behavior to `motion_j`; clamps at line 0

**Given** the line-walk for j/k
**When** invoked
**Then** the implementation walks the gap buffer to find the target line (no line-position cache per SR7)

**Given** counted motions integration (full coverage in 2.7)
**When** motion handlers are invoked from the parser with a count
**Then** the handler reads `count_accumulator` (defaulting to 1 if zero) and respects the count
**Note:** This AC is structural; story 2.7 verifies count integration end-to-end

**Given** dispatch_normal in 2.5 includes h/j/k/l entries
**When** I press `h` in NORMAL mode
**Then** the cursor visibly moves left within one render frame (NFR3)

**Given** UAT on hardware after this story
**When** I launch with a multi-line file and press h/j/k/l
**Then** the cursor moves as expected; clamping works at all four edges; no garbled state

**Given** headless tests under `test/cases/motions_*.asm`
**When** `make test` runs
**Then** the following pass: `motions_h-clamps-at-bof.asm`, `motions_l-clamps-at-eol.asm`, `motions_j-shorter-next-line.asm`, `motions_k-from-line-0.asm`

### Story 2.6: Word/line/buffer motions (w, b, 0, $, gg, G)

As a MicroBeast resident developer,
I want `w` and `b` (word forward/back), `0` and `$` (line start/end), `gg` and `G` (buffer start/end),
So that vi muscle memory transfers for the broader motion vocabulary (FR20, FR21, FR22) and BH1's word-boundary rules + BH2's clamp policy are realized.

**Acceptance Criteria:**

**Given** `motion_w` (next word)
**When** invoked
**Then** the cursor advances to the start of the next word per BH1: a "word" is a maximal run of either (a) alphanumerics-plus-underscore or (b) non-whitespace-non-(a); whitespace separates but is not a word
**And** `motion_w` clamps at EOF per BH2

**Given** `motion_b` (previous word start)
**When** invoked
**Then** the cursor moves to the start of the current word if not already there; otherwise to the start of the previous word per BH1
**And** clamps at BOF

**Given** `motion_0` (line start)
**When** invoked
**Then** the cursor moves to column 0 of the current line (offset of byte after the most recent newline, or offset 0)

**Given** `motion_dollar` (line end)
**When** invoked
**Then** the cursor moves to the last non-newline byte of the current line

**Given** `motion_G` (buffer end)
**When** invoked with no count
**Then** the cursor moves to the start of the last line; with count C, moves to the start of line C

**Given** `motion_gg` — dispatched via the motion-prefix mechanism from story 1.10
**When** dispatched after a 'g' prefix
**Then** the cursor moves to offset 0

**Given** the BH1 word-boundary classifier (`is_word_char` helper)
**When** I inspect motions.asm
**Then** there's a single `is_word_char` routine used by both `motion_w` and `motion_b`, returning Z if the char is "word" (alnum + underscore), NZ otherwise
**And** whitespace is treated as a separator distinct from both classes

**Given** dispatch_normal entries for w/b/0/$/G are added; 'g' is handled via parser_handle_motion_prefix from story 1.10
**When** I press the keys in NORMAL mode
**Then** the cursor moves as specified within one render frame

**Given** UAT on hardware
**When** I exercise w/b/0/$/gg/G on a representative source file
**Then** all motions feel right (vi muscle memory transfers); clamping is invisible at boundaries

**Given** headless tests
**When** `make test` runs
**Then** the following pass: `motions_w-skips-whitespace.asm`, `motions_w-non-alnum-class.asm`, `motions_b-from-mid-word.asm`, `motions_0-on-blank-line.asm`, `motions_dollar-on-empty-line.asm`, `motions_G-no-count.asm`, `motions_G-with-count.asm`, `motions_gg-via-prefix.asm`

### Story 2.7: Counted motions

As a MicroBeast resident developer,
I want any motion prefixed with a count to repeat the motion that many times (with BH2 clamping),
So that `5j`, `12G`, `3w` work per FR23 and the parser's count-accumulator handoff to motion handlers is end-to-end verified.

**Acceptance Criteria:**

**Given** the parser's `count_accumulator` (story 1.10) and motion handlers (stories 2.5/2.6)
**When** I press digits followed by a motion key (e.g., '5' 'j')
**Then** the parser accumulates count = 5, dispatches `motion_j` with count=5, and `motion_j` invokes the per-iteration step 5 times (or computes the target offset directly when efficient — e.g., `motion_l` does `cursor_offset += 5` after clamp, rather than a loop)

**Given** `5h` at offset 3
**When** dispatched
**Then** cursor clamps at 0 per BH2

**Given** `100j` at line 5 of a 10-line file
**When** dispatched
**Then** cursor moves to line 10 (clamped)

**Given** `3w` from start of "one two three four"
**When** dispatched
**Then** cursor lands on 'f' of "four"

**Given** `12G`
**When** dispatched
**Then** cursor moves to line 12 (or last line if shorter)

**Given** the count-clearing rule (story 1.10)
**When** any motion or operator dispatches
**Then** `count_accumulator` is cleared post-dispatch
**And** subsequent unprefixed motions move by 1

**Given** `3` followed by Esc
**When** Esc cancels
**Then** `count_accumulator` cleared via `parser_clear`; mode unchanged (NORMAL); no motion dispatched

**Given** dispatch_normal has digit handlers '0'..'9' routing to `parser_handle_digit`
**When** I press '0' as the first digit
**Then** `motion_0` dispatches (line start), count remains 0

**Given** UAT on hardware
**When** I exercise 5j, 12G, 3w, 4h on real content
**Then** all motions step the expected number of times; clamping is silent

**Given** headless tests
**When** `make test` runs
**Then** the following pass: `parser_5j-dispatches-with-count-5.asm`, `motions_5h-clamps.asm`, `motions_100j-clamps-at-eof.asm`, `motions_3w-three-words-forward.asm`

### Story 2.8: Insert mode (i, a, o, O)

As a MicroBeast resident developer,
I want `i`/`a`/`o`/`O` to enter insert mode at the appropriate position, with literal-byte typing inserting at the cursor and Esc returning to NORMAL,
So that FR13 behavior + FR24/FR25/FR26/FR27 are realized and journey-1a "compose from scratch" becomes testable end-to-end.

**Acceptance Criteria:**

**Given** I'm in NORMAL mode and press `i`
**When** dispatched
**Then** `mode_byte = MODE_INSERT`, status shows "INSERT", cursor unchanged

**Given** I'm in NORMAL mode and press `a`
**When** dispatched
**Then** `mode_byte = MODE_INSERT`, cursor advances by 1 (or stays at EOL if at end-of-line — not past), status shows "INSERT"

**Given** I'm in NORMAL mode and press `o`
**When** dispatched
**Then** the cursor moves to end of current line; a newline (`0x0A` — implementation chooses; documented in module header) is inserted via `gapbuf_insert`; `mode_byte = MODE_INSERT`; cursor positioned at start of the new empty line

**Given** I'm in NORMAL mode and press `O`
**When** dispatched
**Then** the cursor moves to start of current line; a newline is inserted before that position; `mode_byte = MODE_INSERT`; cursor on the newly empty line above the original

**Given** I'm in INSERT mode and press a literal byte
**When** dispatched (via the insert-mode unbound-key fall-through, replacing the stub from story 1.9)
**Then** `gapbuf_insert` inserts the byte at cursor, cursor advances, the row(s) affected are marked dirty
**And** subsequent typing accumulates into the buffer at the gap

**Given** I'm in INSERT mode and press Backspace (0x08)
**When** dispatched
**Then** if cursor > 0, `gapbuf_delete` consumes the byte before the cursor, cursor decrements, affected rows dirty
**And** if cursor == 0, no-op (or beep — documented choice)

**Given** I'm in INSERT mode and press Esc
**When** dispatched
**Then** `mode_byte = MODE_NORMAL`; the insert session is recorded as a single undo entry per B2 (full coverage in story 2.13; for 2.8 the entry recording is a stub or minimal)
**And** cursor stays where the last insert left it

**Given** an insert session that exceeds GAP_BUFFER_MAX
**When** `gapbuf_insert` returns CF=1
**Then** insertion stops; status shows `msg_file_too_large`; mode returns to NORMAL; partial typing prior to the failure is preserved

**Given** the buffer becomes dirty after any insert
**When** I observe `buffer_dirty`
**Then** it's set on the first byte inserted in a session
**And** stays set until a successful `:w` clears it

**Given** UAT on hardware
**When** I `vibe foo.fs`, press `i`, type "Hello", Esc, `:w`, `:q`, `vibe foo.fs`
**Then** the file contains "Hello"; round-trip works; PRD journey 1a's first concrete success on real hardware

**Given** headless tests under `test/cases/edits_*.asm`
**When** `make test` runs
**Then** the following pass: `edits_i-and-type.asm`, `edits_a-at-eol.asm`, `edits_o-creates-newline.asm`, `edits_O-creates-newline-above.asm`, `edits_insert-fills-buffer.asm`

### Story 2.9: Single-character delete (x)

As a MicroBeast resident developer,
I want `x` in NORMAL mode to delete the character under the cursor,
So that FR28 is realized as the simplest deletion primitive.

**Acceptance Criteria:**

**Given** I'm in NORMAL mode with cursor on a non-empty line
**When** I press `x`
**Then** the byte under the cursor is removed via `gapbuf_delete` (operating "forward" — implementation may use `gapbuf_move_gap` to position then delete leading byte of after-gap half)
**And** the cursor stays at the same logical offset; if the deleted byte was the last on the line, cursor clamps to the new EOL

**Given** I press `x` at end of file
**When** dispatched
**Then** the last byte is consumed; cursor adjusts to the new EOF; if the buffer is empty, cursor at offset 0

**Given** I press `x` on an empty line
**When** dispatched
**Then** no-op (documented behavior — `x` does not join lines in VIBE)

**Given** counted x (e.g., `5x`)
**When** dispatched with count=5
**Then** five characters are deleted from cursor (clamping at EOL per BH2)

**Given** an `x` that deletes a character
**When** I observe state
**Then** `buffer_dirty` is set; affected row(s) dirty; the deleted byte is recorded in the undo buffer (stub for 2.9, full coverage in 2.13)

**Given** UAT on hardware
**When** I press `x` repeatedly
**Then** characters disappear, render updates; no crash, no garbled state

**Given** headless tests
**When** `make test` runs
**Then** the following pass: `edits_x-mid-line.asm`, `edits_x-at-eof.asm`, `edits_5x-counted.asm`

### Story 2.10: Doubled-operator commands (dd, yy)

As a MicroBeast resident developer,
I want `dd` to delete the current line and `yy` to yank (copy) the current line into the yank register,
So that FR29 and FR31 are realized via the parser's doubled-operator detection and the yank-register protocol (SR6).

**Acceptance Criteria:**

**Given** the parser detects the doubled-operator (story 1.10)
**When** dispatched (e.g., 'd' 'd')
**Then** the doubled-operator handler `op_dd` is invoked

**Given** `op_dd` (delete-line)
**When** invoked
**Then** the cursor's current line bounds (start-of-line offset, end-of-next-line offset including the newline) are computed; the entire range is removed via `gapbuf_delete` (or `gapbuf_move_gap` + multi-byte gap extension)
**And** `buffer_dirty` is set; affected rows shift; all editable rows marked dirty
**And** the cursor lands on the start of what is now the line at the same logical position (or last line if the deleted line was last)
**And** the deleted content is copied into the yank register at `yank_buffer`: `yank_kind = KIND_LINE`, `yank_length = N`, content copied verbatim
**And** if line content exceeds `YANK_BUFFER_SIZE` (1024), the yank register is NOT updated (predictable failure per SR6) — status shows `yank too large`; the deletion still proceeds

**Given** `op_yy` (yank-line)
**When** invoked
**Then** the same line bounds are computed; content copied to yank register with `yank_kind = KIND_LINE`; buffer unchanged
**And** if line content exceeds `YANK_BUFFER_SIZE`, status shows yank too large; yank register unchanged; buffer unchanged

**Given** counted dd/yy (e.g., `3dd`, `5yy`)
**When** dispatched
**Then** N consecutive lines are operated on
**And** the yank register holds the multi-line content; total bytes vs YANK_BUFFER_SIZE governs the over-capacity refusal

**Given** an undo recording
**When** dd or yy completes
**Then** dd records an inverse (re-insert) entry in undo_buffer (subject to undo capacity refusal in 2.13); yy does not record

**Given** dispatch_normal includes 'd' and 'y' as `parser_handle_operator` entries
**When** I press 'd' followed by 'd'
**Then** the parser detects the doubled-operator and dispatches `op_dd`

**Given** UAT on hardware
**When** I `dd` on a representative source line; `u` (after 2.13) restores it; `yy` on another line; `p` (after 2.12) pastes
**Then** all behaviors match vi muscle memory

**Given** headless tests
**When** `make test` runs
**Then** the following pass: `edits_dd-deletes-line.asm`, `edits_yy-copies-line.asm`, `edits_dd-counted-3lines.asm`, `edits_dd-yank-too-large.asm`

### Story 2.11: Composed operator+motion (dw, d$, c5w, y3j, …)

As a MicroBeast resident developer,
I want any operator (`d`, `y`, `c`, `>`, `<`) composed with any motion to apply the operator over the motion's range,
So that FR39 and FR40 are realized — the architecturally significant cross-cut.

**Acceptance Criteria:**

**Given** parser state with `pending_operator` set (e.g., 'd') and a motion key arrives (e.g., 'w')
**When** `parser_dispatch` is invoked
**Then** the motion is computed in "preview" mode — start offset = current cursor, end offset = where the motion would land (without actually moving the cursor)
**And** the operator is applied to the (start, end) range:
- 'd' (delete): `gapbuf_delete` the range; yank register holds deleted content with `yank_kind = KIND_CHAR`
- 'y' (yank): copy range to yank register; buffer unchanged
- 'c' (change): delete range, then enter INSERT mode at the start offset
- '>': indent each line in range by inserting one space at line start (or tab — module header documents the choice); cursor returns to original
- '<': dedent symmetrically (remove leading space if present; no-op if line has no leading whitespace)
**And** post-operation, `pending_operator` and `count_accumulator` are cleared

**Given** `dw` from "foo bar"
**When** dispatched
**Then** "foo " (foo plus the trailing space — vi convention) is deleted; cursor on 'b' of "bar"; yank register holds "foo " with `yank_kind = KIND_CHAR`

**Given** `d$` from mid-line
**When** dispatched
**Then** content from cursor to end-of-line is deleted; yank holds it; cursor at new EOL

**Given** `c5w` (change next 5 words)
**When** dispatched (count=5, op='c', motion='w')
**Then** range covers 5 words; content deleted; INSERT mode entered at deletion start; subsequent typing inserts there

**Given** `y3j` (yank 3 lines down's worth)
**When** dispatched (count=3, op='y', motion='j')
**Then** the range from current cursor through the position 3 lines down (same column) is copied to yank with `yank_kind = KIND_CHAR`; buffer unchanged

**Given** `>>` and `<<` as doubled `>`/`<`
**When** dispatched (parser doubled-operator detection)
**Then** `>>` indents the current line; `<<` dedents — same as visual-line indent on a single line

**Given** undo recording
**When** any composed-op dispatches
**Then** the inverse op is recorded in undo_buffer (subject to capacity refusal in 2.13)

**Given** UAT on hardware
**When** I exercise dw, d$, dG, c5w, y3j on representative content
**Then** behavior matches vi muscle memory

**Given** headless tests
**When** `make test` runs
**Then** the following pass: `edits_dw-deletes-word.asm`, `edits_d$-to-end-of-line.asm`, `edits_c-enters-insert.asm`, `edits_y3w-yanks-without-modifying.asm`, `edits_indent-shift.asm`, `parser_compose-count-op-motion-end-to-end.asm`

### Story 2.12: Paste (p)

As a MicroBeast resident developer,
I want `p` to insert the content of the yank register at the appropriate position based on `yank_kind`,
So that FR32 is realized and the yank/delete → paste loop closes.

**Acceptance Criteria:**

**Given** the yank register holds content with `yank_kind`, `yank_length`, and bytes at `yank_buffer`
**When** I press `p` in NORMAL mode
**Then** the paste action depends on `yank_kind`:
- `KIND_CHAR`: insert content after the cursor; cursor lands on the last byte of the inserted range
- `KIND_LINE`: insert content as a new line below the current line; cursor at start of the inserted line
- `KIND_BLOCK`: insert content as a column starting at the cursor's column on the current line, propagating down (BH3 jagged-line semantics for shorter lines)

**Given** the yank register is empty (`yank_length == 0`)
**When** `p` is invoked
**Then** no-op; status shows `nothing to paste` (or silent — documented choice)

**Given** counted `p` (e.g., `3p`)
**When** dispatched
**Then** the yank content is inserted N times

**Given** the inserted content fits in the gap buffer
**When** insertion proceeds
**Then** all bytes are inserted via `gapbuf_insert`; `buffer_dirty` is set; affected rows dirty

**Given** the insertion would exceed gap buffer capacity
**When** `gapbuf_insert` returns CF=1 partway through
**Then** insertion stops at the failure point; status shows `msg_file_too_large`; partial paste content is in the buffer; buffer is consistent (truncated at the failure point)
**And** undo recording captures what actually got pasted

**Given** undo recording
**When** paste completes (or partially completes)
**Then** an inverse (delete) entry is recorded in undo_buffer (story 2.13)

**Given** UAT on hardware
**When** I yy a line, p three times, observe duplicates; dd a line, p once, observe restoration; dw a word, p, observe paste at cursor
**Then** all paste flavors behave as expected

**Given** headless tests
**When** `make test` runs
**Then** the following pass: `edits_p-after-yy.asm`, `edits_p-after-dd.asm`, `edits_p-after-dw.asm`, `edits_p-empty-yank.asm`, `edits_3p-counted.asm`, `edits_p-fills-buffer.asm`

### Story 2.13: Single-level undo (u)

As a MicroBeast resident developer,
I want `u` in NORMAL mode to undo the most recent edit (insert session, delete, paste, change, indent),
So that FR45 and FR46 are realized, B2 (insert sessions undo as a unit) holds, and typo recovery is one keystroke per the journey-2 error edge cases.

**Acceptance Criteria:**

**Given** every mutating handler in stories 2.8–2.12 (insert mode session, x, dd, dw/d*/cw, p, indent shift, ~ via 3.8)
**When** the operation completes (or insert session exits via Esc)
**Then** an inverse-operation entry is written to `undo_buffer` (256 bytes, single-slot, overwriting previous):
- Insertion: inverse = delete (position, length)
- Deletion: inverse = insert (position, saved_text)
- Replacement (cw, ~): inverse = composed delete + insert
**And** if the inverse-op data exceeds `UNDO_BUFFER_SIZE`, the entry is marked "too large" and `u` reports unavailability (FR46)

**Given** B2: insert-session unit
**When** I enter insert mode (i/a/o/O/c*), type N characters, then Esc
**Then** a single undo entry captures the entire session as one unit (mode-entry cursor, mode-exit cursor, inserted-text length — bytes can be reconstructed from the buffer)

**Given** I press `u` in NORMAL mode
**When** dispatched
**Then** the recorded inverse-op replays:
- Insertion's inverse: bytes at (position, length) are removed
- Deletion's inverse: saved_text inserted at position
- Replacement: replay both phases in inverse order
**And** the cursor returns to a sensible position (typically the operation's start offset)
**And** affected rows are marked dirty
**And** `buffer_dirty` is recomputed (if undo restores the buffer to its last-saved state, dirty becomes 0; otherwise stays nonzero)

**Given** the undo entry is empty or marked "too large"
**When** I press `u`
**Then** status shows `msg_nothing_to_undo` or `msg_undo_too_large` (FR46)
**And** no buffer change

**Given** undo of undo (`u u`)
**When** dispatched
**Then** per architecture: not in MVP — second `u` is a no-op or shows `nothing to undo` (entry consumed by first `u`)
**And** a comment in `undo.asm` documents this is Growth-tier

**Given** UAT on hardware
**When** I exercise: i + type + Esc + u (text disappears); x + u (char restored); dd + u (line restored); dw + u (word restored); p + u (paste removed); cw + type + Esc + u (original word restored)
**Then** all paths work; PRD journey 2 typo-recovery is realized

**Given** headless tests under `test/cases/undo_*.asm`
**When** `make test` runs
**Then** the following pass: `undo_x-restores-byte.asm`, `undo_dd-restores-line.asm`, `undo_insert-session-as-unit.asm`, `undo_capacity-refusal.asm`, `undo_nothing-to-undo.asm`, `undo_buffer-dirty-recomputes.asm`

## Epic 3: Iterate, Search & Region Operations

PRD Journey 1b (search-driven debug iteration) and Journey 2 (visual region edits) become practical. User can `/dup` to find, `n` to advance with end-of-buffer wrap notice, "pattern not found" status when there's no match. Visual character/line/block selection with `d`/`y`/`c`/`>`/`<`/`~` operators applied to selections.

**Note on visual highlighting:** Classic VT52 has no character attributes (no inverse video, bold, underline, color). Visual mode does not paint a highlighted region on screen — the selection is logical (anchor + cursor define the extent), and the status line shows the extent count (chars, lines, or rows×cols depending on sub-mode). Operators apply over the (anchor, cursor) range. This is a constraint-driven decision flowing from the platform and is documented in `visual.asm` and `render.asm`.

### Story 3.1: Forward literal search (/pattern)

As a MicroBeast resident developer,
I want `/pattern` to initiate a forward literal search and move the cursor to the first match,
So that FR41 is realized — the journey-1b "find a word and jump to it" workflow becomes practical.

**Acceptance Criteria:**

**Given** I'm in NORMAL mode and press `/`
**When** dispatched
**Then** `mode_byte = MODE_COMMAND` (or a sub-state distinguishing search from ex-line — implementation choice; structurally identical to ex-line per architecture), the status row clears and shows '/' at column 0 with cursor immediately after
**And** the underlying buffer is `search_pattern` (length-prefixed, separate from `ex_buffer`)

**Given** I type pattern characters
**When** each arrives
**Then** they append to `search_pattern`, are echoed in the status row
**And** Backspace deletes the previous character; Esc cancels (clears search_pattern, mode → NORMAL, status cleared)

**Given** I press Enter on a non-empty pattern
**When** dispatched
**Then** `search_forward_from(cursor + 1)` is invoked: walk gap buffer from cursor+1 forward, byte-for-byte literal match against `search_pattern` (no regex, case-sensitive)
**And** if a match is found, `cursor_offset = match_start`, affected rows marked dirty (likely scroll required), status shows the matched pattern (or stays blank — implementation choice)
**And** if no match found between cursor+1 and EOF, the search wraps (full coverage in 3.2)

**Given** I press Enter on an empty pattern
**When** dispatched
**Then** if `search_pattern` previously held a pattern, it's reused (vi convention — `/<Enter>` repeats); otherwise no-op with status `no previous pattern`

**Given** the wrap path
**When** search reaches EOF without a match
**Then** it continues from offset 0 to original cursor; if found, status shows `msg_search_wrapped`; if not found across the wrap, status shows `msg_pattern_not_found`; cursor unchanged in not-found case

**Given** UAT on hardware
**When** I `vibe foo.fs`, `/main`, observe cursor jump to first "main"
**Then** match works; pressing `/` again with new pattern works; Esc cancels search prompt

**Given** headless tests under `test/cases/search_*.asm`
**When** `make test` runs
**Then** the following pass: `search_forward-finds-match.asm`, `search_forward-no-match-pre-wrap.asm`, `search_forward-empty-pattern-reuses.asm`, `search_forward-pattern-too-long.asm`

### Story 3.2: Repeat last search (n) with wrap

As a MicroBeast resident developer,
I want `n` to repeat the most recent search forward, with end-of-buffer wrap and a "search wrapped" notice on wrap, and "pattern not found" if no match,
So that FR42, FR43, FR44, BH4 are realized — the iterative debug loop ("`/dup` then `n` to find next caller") becomes practical.

**Acceptance Criteria:**

**Given** `search_pattern` is non-empty (from a prior `/pattern`)
**When** I press `n` in NORMAL mode
**Then** `search_forward_from(cursor + 1)` is invoked (BH4: one byte past current cursor)
**And** if a match is found between cursor+1 and EOF, cursor moves to the match; status clears (no message)
**And** if no match found before EOF, search wraps from offset 0; if found before original cursor, cursor moves to that match, status shows `msg_search_wrapped`
**And** if still no match after the wrap, cursor unchanged, status shows `msg_pattern_not_found`

**Given** `search_pattern` is empty
**When** I press `n`
**Then** status shows `no previous pattern`; no search executed

**Given** the buffer was edited between searches
**When** I press `n`
**Then** the search re-walks from one byte past current cursor (BH4 — no last-match cache); behaves correctly even if buffer changed

**Given** UAT on hardware
**When** I `/dup`, n, n, n, observing each find advances; eventually wrap notice; eventually not-found
**Then** all three states display correctly

**Given** headless tests
**When** `make test` runs
**Then** the following pass: `search_n-advances.asm`, `search_n-wraps-with-notice.asm`, `search_n-not-found.asm`, `search_n-no-prior-pattern.asm`

### Story 3.3: Visual character mode

As a MicroBeast resident developer,
I want `v` in NORMAL mode to enter visual character mode, with motions extending the selection from a fixed anchor and Esc cancelling,
So that FR15 behavior + FR33 are realized as the foundation for visual line/block (3.4/3.5) and the visual operators (3.6/3.7/3.8).

**Acceptance Criteria:**

**Given** `src/visual.asm` module header
**When** I inspect it
**Then** it documents `Public: visual_enter_char, visual_enter_line, visual_enter_block, visual_extend, visual_cancel, visual_apply_operator`, `State owned: visual_anchor, visual_submode`, dependencies

**Given** I'm in NORMAL mode and press `v`
**When** dispatched
**Then** `mode_byte = MODE_VISUAL`, `visual_submode = VIS_CHAR`, `visual_anchor = current cursor_offset`, status shows "VISUAL" + a character count (computed as |cursor - anchor| + 1)

**Given** the visual-mode dispatch table (`dispatch_visual`)
**When** I press a motion key in MODE_VISUAL
**Then** the same motion handlers from stories 2.5/2.6/2.7 are routed via `dispatch_visual` (motions are mode-agnostic; they update cursor, and visual-mode ranged-operator handlers consume (anchor, cursor) on operator dispatch)
**And** post-motion, status updates with new character count

**Given** I press Esc in MODE_VISUAL
**When** dispatched
**Then** `mode_byte = MODE_NORMAL`, cursor stays at extent, status shows "NORMAL"
**And** `visual_anchor` is no longer used until the next visual-mode entry

**Given** I press a non-motion non-operator key in MODE_VISUAL (e.g., 'i')
**When** dispatched (no entry in `dispatch_visual` for 'i')
**Then** the unbound-key fall-through fires: status beep/no-op; selection preserved; no state change

**Given** the renderer in MODE_VISUAL
**When** rendering
**Then** no special highlighting is applied (VT52 has no attributes per platform constraint); the user sees the cursor and the status line shows mode + character count
**And** comments in `visual.asm` and `render.asm` document this constraint with reference to platform-constraints

**Given** UAT on hardware
**When** I press 'v', move cursor with motions, observe status updating (character count changes), press Esc, observe NORMAL mode return
**Then** behavior is consistent; no garbled state

**Given** headless tests under `test/cases/visual_*.asm`
**When** `make test` runs
**Then** the following pass: `visual_v-enters-mode.asm`, `visual_motions-extend-selection.asm`, `visual_esc-cancels.asm`

### Story 3.4: Visual line mode

As a MicroBeast resident developer,
I want `V` (capital V) to enter visual line mode, where the selection extends in whole-line units regardless of cursor column,
So that FR34 is realized for line-oriented region operations.

**Acceptance Criteria:**

**Given** I press `V` in NORMAL mode
**When** dispatched
**Then** `mode_byte = MODE_VISUAL`, `visual_submode = VIS_LINE`, `visual_anchor = start of current line`, status shows "V-LINE" + line count

**Given** I'm in VIS_LINE and motion changes the cursor's line
**When** dispatched
**Then** cursor_offset moves; the logical selection extent is (anchor's line-start, cursor's line-end) regardless of column
**And** status updates with new line count

**Given** I press Esc in VIS_LINE
**When** dispatched
**Then** `mode_byte = MODE_NORMAL`; behavior identical to character-mode cancel

**Given** UAT on hardware
**When** I press V + motion + Esc on a multi-line file
**Then** behavior is consistent with vi muscle memory

**Given** headless tests
**When** `make test` runs
**Then** the following pass: `visual_V-enters-line-mode.asm`, `visual_V-line-extent.asm`

### Story 3.5: Visual block mode

As a MicroBeast resident developer,
I want `Ctrl-V` to enter visual block mode, with selection as a virtual rectangle (anchor row/col, cursor row/col), and BH3 jagged-line semantics,
So that FR35 + BH3 are realized for column-based region edits.

**Acceptance Criteria:**

**Given** I press Ctrl-V (0x16) in NORMAL mode
**When** dispatched
**Then** `mode_byte = MODE_VISUAL`, `visual_submode = VIS_BLOCK`, `visual_anchor` records the anchor offset (and the column is recomputed from the anchor's line scan), status shows "V-BLOCK" + block dimensions (rows × cols)

**Given** I'm in VIS_BLOCK with motions
**When** the cursor moves
**Then** the selection rectangle is computed from (anchor_row, anchor_col, cursor_row, cursor_col) — normalized so the rectangle has well-defined top-left and bottom-right corners regardless of motion direction
**And** status updates with new dimensions

**Given** BH3 jagged-line semantics
**When** the rectangle extends past EOL of some rows
**Then** those rows' selection extent is clipped at their EOL — the buffer is NOT modified to extend short lines; the rectangle is virtual

**Given** I press Esc in VIS_BLOCK
**When** dispatched
**Then** `mode_byte = MODE_NORMAL`

**Given** UAT on hardware
**When** I Ctrl-V on a multi-line file, motion to extend, observe status showing rectangle dimensions; Esc cancels
**Then** behavior is consistent

**Given** headless tests
**When** `make test` runs
**Then** the following pass: `visual_block-enters-mode.asm`, `visual_block-jagged-clamp.asm`

### Story 3.6: Visual operators (d, y, c)

As a MicroBeast resident developer,
I want `d`, `y`, `c` in VISUAL mode (any sub-mode) to apply the operator over the current selection,
So that FR36 is realized — region edits become possible.

**Acceptance Criteria:**

**Given** I'm in MODE_VISUAL with a non-empty selection (any sub-mode)
**When** I press 'd'
**Then** the selection's range (computed per sub-mode: char = byte range; line = line range; block = per-row clipped ranges per BH3) is deleted via `gapbuf_delete` (multiple calls for block sub-mode)
**And** content is copied to yank register with appropriate `yank_kind` (`KIND_CHAR` / `KIND_LINE` / `KIND_BLOCK`)
**And** mode returns to MODE_NORMAL; cursor lands at deletion start
**And** undo entry recorded (multi-region for block — implementation must handle or refuse with `msg_undo_too_large`)
**And** affected rows dirty

**Given** I press 'y' in VISUAL
**When** dispatched
**Then** the selection content is copied to yank register; buffer unchanged; mode returns to NORMAL; cursor at original position (or anchor — implementation choice, vi default is cursor-at-anchor after yank)

**Given** I press 'c' in VISUAL
**When** dispatched
**Then** the selection is deleted (same as 'd'); INSERT mode is entered at deletion start; subsequent typing inserts there
**And** for VIS_BLOCK per BH3: insertion happens line-by-line at the column-or-EOL position

**Given** the yank register oversize case (selection > YANK_BUFFER_SIZE)
**When** dispatched
**Then** per SR6: yank register NOT updated; deletion still proceeds (for d/c); status shows `yank too large`

**Given** UAT on hardware
**When** I exercise visual char d, line d, block d, y, c
**Then** all behaviors match vi muscle memory

**Given** headless tests
**When** `make test` runs
**Then** the following pass: `visual_d-char.asm`, `visual_y-line.asm`, `visual_c-char-enters-insert.asm`, `visual_d-block-jagged.asm`

### Story 3.7: Visual shift (>, <)

As a MicroBeast resident developer,
I want `>` and `<` in VISUAL mode to shift the selected lines right or left (one space, or tab — implementation choice with documented rationale) per line,
So that FR37 is realized for code-style indent/dedent over a region.

**Acceptance Criteria:**

**Given** I'm in MODE_VISUAL (any sub-mode) with a multi-line selection
**When** I press '>'
**Then** for each line in the selection's row range, one space (or tab — module header documents the choice) is inserted at line start
**And** cursor returns to anchor's line after the operation
**And** mode returns to MODE_NORMAL
**And** undo entry recorded

**Given** I press '<' on a line that has no leading whitespace
**When** dispatched
**Then** that line is unchanged (silent no-op for that line; other lines in selection still process)

**Given** I press '<' on a line with leading whitespace
**When** dispatched
**Then** one space (or tab — consistent with '>') is removed from line start

**Given** UAT on hardware
**When** I exercise V + motion + > on a Forth source block, observe indentation
**Then** behavior matches expectation

**Given** headless tests
**When** `make test` runs
**Then** the following pass: `visual_shift-right.asm`, `visual_shift-left.asm`, `visual_shift-left-no-leading.asm`

### Story 3.8: Visual case toggle (~)

As a MicroBeast resident developer,
I want `~` in VISUAL mode to toggle the case of every alphabetic character in the selection,
So that FR38 is realized — region case-flipping for retypos.

**Acceptance Criteria:**

**Given** I'm in MODE_VISUAL with a selection
**When** I press '~'
**Then** every byte in the selection range is processed: lowercase 'a'..'z' becomes 'A'..'Z'; uppercase 'A'..'Z' becomes 'a'..'z'; other bytes unchanged
**And** for VIS_BLOCK, the per-row clipping rule applies (short lines processed only up to their EOL per BH3)
**And** mode returns to MODE_NORMAL; cursor at anchor or original position
**And** undo entry recorded
**And** affected rows dirty

**Given** UAT on hardware
**When** I select "Hello World" + ~, observe "hELLO wORLD"
**Then** behavior matches expectation

**Given** headless tests
**When** `make test` runs
**Then** the following pass: `visual_tilde-toggles.asm`, `visual_tilde-block.asm`
