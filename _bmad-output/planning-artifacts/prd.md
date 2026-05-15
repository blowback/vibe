---
stepsCompleted: ['step-01-init', 'step-02-discovery', 'step-02b-vision', 'step-02c-executive-summary', 'step-03-success', 'step-04-journeys', 'step-05-domain', 'step-06-innovation-skipped', 'step-07-project-type', 'step-08-scoping', 'step-09-functional', 'step-10-nonfunctional', 'step-11-polish', 'step-12-complete']
releaseMode: phased
inputDocuments: ['docs/brief.md']
documentCounts:
  briefs: 1
  research: 0
  brainstorming: 0
  projectDocs: 0
classification:
  projectType: cli_tool
  domain: general
  complexity: medium
  projectContext: greenfield
workflowType: 'prd'
---

# Product Requirements Document - vibe

**Author:** Ant
**Date:** 2026-05-08

## Executive Summary

VIBE is a vi-spirited modal text editor written in Z80 assembly for the Feersum
MicroBeast running CP/M 2.2, output to a VT52 terminal. It exists to make
authoring software *natively on the MicroBeast* a real workflow rather than a
theoretical one — currently impossible because the MicroBeast has no resident
editor and cannot be reached over a network. VIBE is the missing editor in a
self-hosted Z80 development stack alongside AntForth (an ANS-compatible Z80
Forth), enabling on-machine authoring of small programs — initially, simple
games — without an external host in the loop.

The audience is deliberately narrow: the author and the MicroBeast retrocomputing
community. There is no incumbent to displace; VIBE fills a vacuum.

The success bar is workflow: VIBE must be usable for sustained editing of
source files (e.g. AntForth) or other text files on the MicroBeast, run or
consumed by whatever on-machine program needs them, without leaving the
machine. Editing VIBE's own source on-device is a plausible side effect, not
the goal.

### What Makes This Special

- **Self-hosted by necessity, not nostalgia.** The MicroBeast is a Z80 with
  64K RAM and no network — there is no remote-edit path. VIBE is the only
  way native development becomes a normal activity, not a stunt.
- **vi spirit, not vi fidelity.** A curated subset of vi (modes, core motions,
  essential edits, single-level undo, ex commands, literal search) chosen so
  muscle memory transfers approximately, while features that don't earn their
  weight on a 64K Z80 are dropped without apology.
- **System completion, not standalone tool.** VIBE earns its keep by composing
  with whatever on-machine program consumes a file — currently AntForth, but
  the editor is consumer-agnostic. Editor plus runtime/assembler/interpreter
  equals a development environment that lives entirely on the machine.
- **Minimalism as craft.** A tentative ~3KB code budget — not a hard
  constraint but a design intuition — keeps the implementation honest and the
  scope aligned with what a single Z80 .COM file should be.

## Project Classification

- **Project Type:** CLI/terminal tool (TUI text editor)
- **Domain:** General — retrocomputing hobbyist tooling, no regulatory context
- **Complexity:** Medium — the problem domain is well-understood, but Z80
  assembly under tight memory plus the no-crashes mandate add real
  engineering complexity
- **Project Context:** Greenfield

## Success Criteria

### User Success

- **Primary user job done**: Author source files (e.g. AntForth) or other text
  files on the MicroBeast and feed them to whatever on-machine program consumes
  them, without leaving the machine. The "aha" moment is editing and running
  entirely on-device, host laptop closed.
- **Muscle memory transfers**: A vi user can use VIBE without consulting docs
  for the supported subset. Brief-listed motions and edits behave as expected.
- **No data loss**: Saving, opening, and single-level undo work. The user never
  loses unsaved work to a crash, because crashes do not happen.
- **Slow but usable**: Editing remains comfortable for sustained sessions —
  the VT52's bandwidth is the floor, not VIBE's overhead. Screen updates are
  diff-based; the editor never gratuitously redraws.

### Business Success

VIBE is a personal/hobbyist project with no revenue or growth metrics. "Business
success" reduces to:

- **Bragging rights**: VIBE exists and runs on real MicroBeast hardware as part
  of a self-hosted Z80 stack alongside AntForth.
- **Self-utility**: The author uses it for something concrete — e.g., writing
  a small AntForth game on the MicroBeast.
- **Adoption (incidental)**: Other MicroBeast users may try it. Not measured,
  not pursued.

### Technical Success

These are the goal-level technical commitments. Each is formalized as a
specific contract in [Non-Functional Requirements](#non-functional-requirements).

- **Stability is mandatory**: VIBE does not crash. An unreliable editor
  cannot be used at all — non-negotiable. (NFR5–NFR8)
- **Footprint discipline**: code stays close to the tentative ~3 KB
  budget; overruns trigger redesign, not budget inflation. (NFR9–NFR12)
- **Diff-based rendering**: required for editor responsiveness on
  serial-attached terminals. (NFR1, FR47)
- **Toolchain purity**: pure Z80 + sjasmplus 1.23.0 + Make — no C glue,
  no hidden runtime. (NFR14, NFR18)
- **CP/M 2.2 fidelity**: standard BDOS only; file I/O via FCB; no
  extended-CP/M assumptions. (NFR15, [Platform Constraints](#platform-constraints))

### Measurable Outcomes

- VIBE assembles to a single CP/M `.COM` file, code budget close to ~3KB plus
  the gap buffer.
- VIBE successfully opens, edits, and saves a source file (e.g. AntForth) or
  other text file on the MicroBeast.
- An author-written AntForth game (a few KB of Forth) is composed start-to-
  finish using VIBE on the MicroBeast.
- Zero observed crashes during the author's day-to-day editing sessions.
- All commands listed in the brief's "Initial vi feature set" function as
  specified.

## Product Scope

### MVP - Minimum Viable Product

The full feature set listed in `docs/brief.md` is the MVP contract:

- Modes: normal, insert, command (`:`), visual (line / character / block)
- Motions: `h j k l w b 0 $ G gg`
- Edits: `i a o O x dd dw yy p u` (single-level undo)
- Ex commands: `:w :q :wq :w filename :e filename`
- Counts: two-stage operator/motion structure with command counts
- Search: literal `/pattern` and `n` (no regex)
- Visual-mode operators: `d y c > < ~`

Plus the cross-cutting requirements:

- Diff-based VT52 redraw (no whole-screen redraws)
- Status line
- Stable file open/save via CP/M FCB
- No crashes

There is no smaller "must-have" subset; the brief *is* the contract. Items can
be dropped only if they prove disproportionately expensive in implementation.

### Growth Features (Post-MVP)

Driven by the author's day-to-day use and "big brother nvim" envy. Likely
candidates, added as the author starts missing them:

- VT100 output mode (flagged in brief as a future option)
- Multi-level undo
- Search-and-replace (`:s/old/new/`)
- Marks and jumps (`m`, `'`, `` ` ``)
- Macros (`q`)
- Additional motions: `f`/`F`/`t`/`T`, `%`, paragraph/section motions
- Multiple buffers
- Configurable keymap

There is no fixed cutoff — VIBE evolves continuously as long as the author
keeps editing on the MicroBeast.

### Vision (Future)

- **VideoBeast GPU integration** (when available): richer rendering, 80-column
  color, possibly syntax highlighting for Forth and Z80 assembly.
- **Direct AntForth integration**: `:!` escape to the Forth interpreter,
  possibly running the file under cursor.
- **Editor-assisted Forth debugging**: highlight current word, breakpoints,
  inspecting Forth's stack from inside VIBE.

## User Journeys

### Persona: Ant, MicroBeast resident developer

Ant has a Feersum MicroBeast on the desk — a Z80 with 64K RAM, a serial line
to a VT52-capable terminal, and CP/M 2.2. He has tools that *run* programs on
the MicroBeast (AntForth being the present example, but the workflow is
indifferent — any CP/M program that reads a file qualifies). What he lacks is
a way to *write* and *iterate on* those files without sitting at a host
machine.

VIBE is for him.

### Journey 1a — Compose from scratch

**Opening.** Ant boots the MicroBeast and decides he wants to write a small
Forth game. Blank slate. Until now, this required composing the file on a host
laptop, then transferring it across — workflow friction sufficient that the
game just doesn't get written.

**Rising action.** He types `vibe game.fs`. VIBE comes up with an empty buffer
in normal mode, status line at the bottom. He hits `i`, drops into insert
mode, and starts typing Forth: `: hello ." hi" ;`. Newline. More words. He
realizes he wants to rename `hello` to `greet` — `Esc`, `0`, then `cw` after
positioning, types `greet`. Continues.

**Climax.** A few minutes in, he saves with `:w`. The file is on the
MicroBeast's disk. He quits with `:q`, runs the file through AntForth, sees
output. The thing he just wrote ran on the same machine he wrote it on. No
serial transfer, no host laptop.

**Resolution.** Composing new files on the MicroBeast becomes a normal
activity. Ideas that previously got abandoned because of host-friction now
get attempted.

**Capabilities revealed:** new file creation, insert mode, basic motions and
edits, `:w`/`:q`, status line, `Esc` discipline, predictable response on
unsupported commands (no crash, no undefined behavior).

### Journey 1b — Iterative edit/run loop

**Opening.** `game.fs` exists. Ant runs it through AntForth and sees
`stack underflow` from line 12.

**Rising action.** `vibe game.fs`. The file loads. He uses `12G` to jump to
the line — counted `G` works, good. He sees the suspect word. Uses `/dup` to
find the call site, `n` to find the next. Realizes he forgot a `drop`. `A`,
types ` drop`, `Esc`. `:w`.

**Climax.** `:q`. Re-runs. Output now correct. Total round-trip ~20 seconds,
all on-machine. The loop is tight enough that debugging-by-experiment is
practical, not painful.

**Resolution.** The edit/run cycle becomes the primary workflow. The
MicroBeast is no longer "a thing that runs programs you write elsewhere" —
it's a place where programs are *developed*.

**Capabilities revealed:** `:e file` (or invocation-time file load), counted
motions (`12G`), search (`/`, `n`), append (`A`), single-level undo (`u`) for
when the change went wrong, fast `:w :q` round-trip, diff-based redraw so the
serial line doesn't bottleneck the iteration.

### Journey 2 — Error and recovery edge cases

**Opening.** Mid-session, things go sideways. This journey is about what
*doesn't* happen as much as what does.

**Scenarios:**

- **Typo recovery.** Ant deletes the wrong line (`dd` on line 7 instead of 8).
  Hits `u`. Line is back. Single-level undo is enough because he noticed
  immediately — but if he made a *second* mistake before noticing the first,
  he's out of luck. Acceptable trade-off given the size budget; documented as
  a limitation.

- **Unsupported command.** Tries `f x` (find character). VIBE doesn't support
  it. Status line shows a brief beep/message; the editor stays in normal
  mode, cursor unmoved. No crash, no garbled state. Ant works around with `0`
  and manual movement.

- **`:e` on a missing file.** Opens an empty buffer with the new filename
  bound. `:w` will create the file. No error, no surprise.

- **`:w` to a write-protected disk.** CP/M returns a write error. VIBE shows
  the error in the status line, leaves the buffer dirty, returns to normal
  mode. User can `:w foo.bak` to a different name, or `:q!` to abandon (if
  supported) — at minimum, no data loss without acknowledgement.

- **What MUST NOT happen.** VIBE crashes. The screen state desyncs and stays
  desynced. The file gets silently truncated. The buffer reports saved but
  nothing was written. Any of these makes the editor untrustworthy and
  therefore unusable.

**Capabilities revealed:** `u` undo, graceful no-op on unsupported commands,
status-line error reporting, FCB-level error handling for save/open, refusal
to silently lose data, robust screen-state tracking that recovers from
unexpected input without redraw.

### Journey Requirements Summary

VIBE has effectively one human persona (the author / single MicroBeast user).
There is no admin layer, no support role, no API consumer, and no multi-user
interaction. The "downstream consumer" of VIBE's output is whatever CP/M
program takes a file (currently AntForth, but the editor is consumer-agnostic
— treat that interaction surface as `file system + CP/M FCB I/O`, not a
persona).

Capabilities required across the three journeys above:

1. **Buffer & file lifecycle**: open new (`:e`), open existing, save (`:w`),
   save-as (`:w filename`), quit (`:q`), abandon (`:q!`), invocation-time
   file argument.
2. **Modal editing core**: normal/insert/visual/command modes with reliable
   `Esc` transitions; status line reflects current mode.
3. **Motions and edits**: as enumerated in the brief, including counts.
4. **Search**: `/pattern` and `n` with literal matching.
5. **Undo**: single level; visible enough that the user knows when they've
   exhausted it.
6. **Error handling**: status-line errors for I/O failures; no-op on
   unsupported commands; never silently lose data; never crash.
7. **Rendering**: diff-based VT52 redraw to keep the serial line responsive
   even on slow hardware; recover screen state from unexpected output.
8. **CP/M integration**: file I/O via FCB, robust against missing files,
   write-protect, and disk-full conditions.

## Platform Constraints

VIBE assumes a specific runtime environment: a Feersum MicroBeast running
CP/M 2.2, with a VT52-capable terminal attached over a serial line. These
assumptions shape architectural decisions and are not portability targets —
where this document says "assume", read "the design relies on this and
porting requires re-evaluation".

### Hardware & Memory

- **CPU:** Z80, interrupts enabled. Two interrupt sources are relevant: a
  keyboard scanner and a 50 Hz timer tick. VIBE may opportunistically use the
  50 Hz tick (e.g., for cursor blink, Esc-key disambiguation timeout) but
  must not require it for correctness.
- **Memory layout:**
  - `0x0000..0x00FF` — CP/M zero page (warm-boot vector, default FCB at
    `0x005C`, default DMA at `0x0080`, etc.). VIBE follows standard CP/M
    conventions; nothing exotic here.
  - `0x0100..0xD7FF` — TPA, ~54 KB total. VIBE code, data, screen shadow,
    and gap buffer all live here.
  - `0xD800+` — CCP / BDOS / BIOS. VIBE must not stomp this region; warm
    boot on `:q` returns control to the CCP cleanly.
- **Memory budget intuition (not contract):**
  - Code: ~3 KB tentative
  - Screen shadow (80×24): 1920 bytes
  - Editor state (cursor, mode, status, command line): ~256 bytes
  - Gap buffer: everything left over — ~48 KB realistic working space
  - This is comfortable. Memory is not the binding constraint; code size
    discipline is the binding constraint.

### Display & Terminal

- **Geometry:** 80 columns × 24 rows, fixed. No need to query, no resize
  events. Status line occupies row 24; editable area is rows 1..23.
- **Terminal:** Classic VT52, full command set assumed. Cursor positioning
  via `ESC Y row col` (rows/cols offset by `0x20`). Screen clear, line
  clear, cursor home all available. No advanced features (no color, no
  underline/bold, no scroll regions, no graphic char set).
- **Serial bandwidth:** Treated as the floor on perceived editing speed.
  Diff-based redraw is mandatory; whole-screen redraws happen only on
  explicit refresh (e.g., `Ctrl-L` if implemented) or initial draw.
- **Output path:** Every screen-bound byte goes through `BIOS_CONOUT`. No
  memory-mapped video, no fast-path bypass.

### Input & Keyboard

- **Input path:** BIOS direct — `BIOS_CONINST` for "is a byte ready?",
  `BIOS_CONIN` for blocking read. BDOS console functions are deliberately
  bypassed to avoid CCP-style Ctrl-C handling and to keep latency low.
- **Arrow keys & Esc disambiguation:** VT52 arrow keys arrive as `ESC A`,
  `ESC B`, `ESC C`, `ESC D`. VIBE must distinguish a bare `Esc` (mode exit)
  from `Esc + something` (arrow key or future escape sequence). The
  conventional approach — a short timeout after `Esc` — pairs naturally
  with the 50 Hz tick.
- **Control characters:** With BDOS bypassed, all control characters arrive
  raw. VIBE owns Ctrl-C / Ctrl-Z / etc. semantics for itself.

### Filesystem

- **Drives:** Multiple drives present. A: is read-only by default. VIBE's
  default drive is B: (the RAM disk) — bare filenames in both `:w` and
  `:e` resolve to `B:filename.ext` unless an explicit drive letter is
  given. There is no fallback search across drives. Files saved to B: live
  only as long as the RAM disk does — users are responsible for promoting
  durable work to a persistent drive.
- **Persisting B: to flash.** The MicroBeast ships with a built-in
  `WRITE.COM` utility that persists the RAM disk to flash. It is
  interactive, so VIBE cannot invoke it programmatically — the user's
  end-of-session ritual is `:wq` from VIBE, then run `WRITE` from CCP
  before powering off. VIBE may eventually offer a quit-and-prompt-for-
  WRITE convenience (Vision tier), but for MVP the ritual is manual.
- **User numbers:** Not used. VIBE operates on whatever user number CCP
  was running under.
- **Filenames:** 8.3 — eight-character base, three-character extension,
  uppercase. VIBE normalizes lowercase user input.
- **File I/O:** Standard CP/M FCB-based BDOS calls. 128-byte sector
  granularity. End-of-file in text files marked with `0x1A` (Ctrl-Z); VIBE
  reads up to first `0x1A` on load and writes a `0x1A` plus padding on
  save.
- **Failure modes to handle gracefully:** disk full, write-protected disk
  (notably A:), file not found on `:e`, drive offline. Each surfaces in the
  status line; none cause a crash or silent data loss.

### Build & Transfer

- **Assembler:** sjasmplus 1.23.0 (specifically — newer versions are not a
  portability target).
- **Build system:** Make.
- **Host:** Linux (assumed; sjasmplus runs cross-platform but the dev loop
  is Linux-side).
- **Transfer to MicroBeast:** SLIDE utility (the author's tool). The
  Makefile may include a target that builds and pushes in one step; this
  is dev-loop ergonomics, not a product requirement.
- **Output artifact:** Single CP/M `.COM` file. No accompanying data files,
  no install step, no helper utilities.

### Non-portability (explicit)

VIBE is **not** a portable editor. These are the things it deliberately
does not handle, and which would require redesign — not parameter changes
— to support:

- Other Z80 platforms with non-VT52 terminals (a VT100/ANSI mode is flagged
  in the brief as future work, but is a meaningful redesign, not a config
  flag)
- Different screen geometries (80×25, 64×24, etc.)
- CP/M 3.x, MP/M, or non-CP/M Z80 OSes
- Memory-banked configurations (the 54 KB TPA assumption is hard)
- Non-serial console paths

## Internal Architecture

These are architectural commitments — pinned now to avoid mid-implementation
churn. They follow from the platform constraints, the journey requirements,
and the brief's feature set. Single-author project; the PRD is the contract
the author keeps with future-self.

### Memory Allocation Strategy

VIBE's TPA layout, from low to high:

```
0x0100  ┌─ Code (~3 KB tentative)
        ├─ Static data (mode byte, cursor state, status line buffer,
        │   command-line buffer, search-pattern buffer, screen shadow,
        │   undo buffer, etc.)
        ├─ Gap buffer  (capped — see below)
        ├─ Reserved pool  (everything between gap-buffer-top and BDOS)
0xD7FF  └─ (BDOS / CCP / BIOS above)
```

- **Gap buffer cap:** A single source equate (`GAP_BUFFER_MAX`) sets the
  ceiling. Initial value: ~32 KB, comfortably larger than any plausible
  hand-written Forth or assembly source. Files exceeding the cap are
  refused at load time with a status-line error; they cannot be opened.
- **Reserved pool:** The TPA region between gap-buffer-top and BDOS is
  deliberately uncommitted. Future features (paste registers, search
  history, multi-level undo, macro recording, multi-buffer support) carve
  from this pool. MVP touches none of it.
- **Static data is fixed-size at assembly time.** No dynamic allocation
  inside VIBE — everything that grows is the gap buffer or future-reserved.

### Gap Buffer

- **Position:** floats in TPA between end-of-static-data and the reserved
  pool. Linker-determined start address, fixed size = `GAP_BUFFER_MAX`.
- **Gap behavior:** the gap (the unused middle region) tracks the cursor;
  edits move the gap to the cursor before insertion/deletion.
- **No grow / no shrink:** size is fixed at startup. The gap moves; the
  buffer doesn't resize.
- **Two-halves invariant:** `[before_gap][gap][after_gap]`. File I/O walks
  the two non-gap halves in order.

### Undo (Single Level)

- **Storage:** fixed 256-byte undo buffer in static data. Holds one
  inverse-operation entry per user-visible edit.
- **Operation kinds:**
  - `INSERTION` — undone by deleting `(position, length)`
  - `DELETION` — undone by re-inserting `(position, saved_text)` from the
    undo buffer
  - `REPLACEMENT` (`cw`, `~`, etc.) — recorded as composed delete + insert,
    undone by replaying both
- **Capacity policy:** if the operation's saved text exceeds the undo
  buffer, undo is *unavailable* for that operation. Status line shows
  "undo not possible — too large". The user knows immediately, before
  they try.
- **Undo of undo (`u u`):** not in MVP; flagged for later reconsideration.

### Mode State Machine

- **Modes:** `NORMAL`, `INSERT`, `COMMAND` (`:`), `VISUAL`. One byte at a
  fixed address holds the current mode.
- **Dispatch:** table-driven. One key→handler table per mode. Lookup is a
  flat 256-entry table per mode (or a small switch-equivalent if the
  table sparsity makes it cheaper — implementation decision).
- **Mode transitions:** explicit assignments to the mode byte; per-mode
  enter/exit hooks update the status line and any mode-specific state.
- **Visual sub-modes** (line / character / block): a separate byte stores
  the visual sub-mode when `VISUAL` is active. Same dispatch model.
- **Rejected:** state-machine generators, fancy transition guards,
  hierarchical state machines. Keep it boring.

### Command Parser

vi's classic two-stage operator/motion structure, with explicit accumulator
state:

- **Count accumulator** (16-bit): leading digits in normal mode append to
  it (`5dd`, `12G`); cleared on command dispatch. A leading `0` is the
  motion `0`, not a count digit.
- **Pending operator** (byte): set on `d`, `y`, `c`, `>`, `<`. Cleared on
  command dispatch. Doubled-operator commands (`dd`, `yy`) detected when
  the same operator is pending and pressed again.
- **Dispatch:** when a motion or doubled-operator completes the pending
  command, execute and clear all accumulator state.
- **Ex command line:** separate fixed-size buffer (~64 bytes) for the
  text after `:`. Parsed on `Enter`. Editing within the command line
  supports backspace and `Esc` (cancel) at minimum.
- **Search prompt:** structurally identical to ex command line, but
  triggered by `/` and dispatched to search instead of ex.

### Render Pipeline

- **Shadow buffer:** 1920 bytes (80 × 24), one byte per cell. Holds the
  character currently *on screen*. No attribute storage (VT52 has no
  attributes worth tracking at this level).
- **Render step:**
  1. For each cell in the visible region (rows 1..23), compute the target
     character from the gap buffer.
  2. Compare to shadow. If different, mark for emit.
  3. Walk the marked cells; for each contiguous horizontal run, emit one
     `ESC Y row col` cursor positioning followed by the run of characters.
  4. Update shadow with the emitted cells.
- **Status line (row 24):** rendered separately by the same diff approach.
- **Whole-screen redraw:** only on initial draw, on `Ctrl-L` (refresh),
  and after returning from sub-shell-style operations (none in MVP).
- **Cursor positioning:** after a render step, cursor moves to the logical
  cursor position with one final `ESC Y row col`.

### Search

- **Algorithm:** literal byte-for-byte substring match. No regex.
- **Direction:** forward only in MVP. `?` (backward) is Growth tier.
- **Start position:** one character past the current cursor (so `n`
  advances even if the cursor is sitting on a previous match).
- **Wrap:** searches that reach end-of-buffer wrap to start. Status line
  shows "search wrapped" on the wrap. If still no match after wrapping
  back to the original start, status line shows "pattern not found".
- **Pattern buffer:** ~64 bytes, separate from the ex command line buffer.
  Last pattern persists for `n`.
- **Case sensitivity:** case-sensitive (matches vi default).

### File I/O

- **Read (`:e`, invocation-time argument):**
  - Standard BDOS open + sequential-read.
  - Each 128-byte sector reads into the default DMA at `0x0080`.
  - Sector contents copied into the gap buffer's before-gap region.
  - Read until BDOS EOF or first `0x1A` (Ctrl-Z text terminator).
  - Initial gap position: end of file content (cursor lands at start of
    file, gap at end — common vi default).
  - File-too-large case: refused at load with a status-line error; gap
    buffer untouched.
- **Write (`:w`, `:wq`, `:w filename`):**
  - Open for write (BDOS function 19/22 as appropriate).
  - Walk gap buffer in two halves: before-gap, then after-gap.
  - Fill DMA in 128-byte chunks; BDOS write each sector.
  - Append `0x1A` plus padding to the next 128-byte boundary.
  - Close.
- **Atomicity:** **direct (unsafe) write** — no temp file, no rename
  dance. CP/M lacks atomic rename, the user is single-tasking, and the
  complexity-for-safety trade isn't worth paying on MVP. A crashed write
  may leave a half-written file. Documented limitation.
- **Default drive:** B:, per platform constraints.

### Source Equates Worth Naming

A handful of compile-time constants define the size envelope. Naming them
explicitly so they're easy to find, audit, and bump:

- `GAP_BUFFER_MAX` — gap buffer ceiling (initial: ~32 KB)
- `UNDO_BUFFER_SIZE` — undo storage (initial: 256 bytes)
- `STATUS_LINE_WIDTH` — 80
- `EX_COMMAND_BUFFER` — ex/search command-line length (initial: 64 bytes)
- `SEARCH_PATTERN_BUFFER` — last-search storage (initial: 64 bytes)
- `SCREEN_ROWS` — 24
- `SCREEN_COLS` — 80
- `EDITABLE_ROWS` — 23 (rows 1..23; row 24 is status line)

## Project Scoping & Risk Analysis

The complete scope and phasing model is documented in
[Product Scope](#product-scope) above (MVP, Growth, Vision tiers).
This section adds the strategic framing — *why* the MVP boundary is
where it is — and the risks that could derail delivery.

### MVP Strategy & Philosophy

**Approach:** problem-solving MVP. The MVP isn't about validating product-
market fit (no market), demoing investment potential (no investors), or
maximizing reusability (single author, single platform). It's about
*solving one specific problem*: making native on-MicroBeast editing a
real, sustained workflow.

**MVP boundary rationale:** the brief's feature list is the MVP. Cutting
below that produces an editor that is technically a "vi clone" but
practically not enough to live in. Specifically:

- **Without `:w` / `:q` / `:e`** — VIBE is a toy, not a tool.
- **Without modes** — it's not vi.
- **Without basic motions and edits** — typing speed is bottlenecked by
  cursor jiggling.
- **Without single-level undo** — every typo is permanent until reload,
  which makes editing terrifying.
- **Without diff-based redraw** — the serial line bottlenecks the editor
  and slow becomes painful.
- **Without crash safety** — see [Technical Success](#technical-success).

**Resource model:** one author, no deadline. Implementation cadence is
governed by author availability and discovered complexity. There is no
external commitment to ship by date X.

### Risks

Ranked by likelihood × consequence. For a hobbyist single-author project,
"risk" mostly means "things that quietly stall the project" rather than
"things that crash a launch".

#### Technical Risks

1. **Esc / arrow-key disambiguation timing.** The 50 Hz tick gives a 20 ms
   resolution; arrow-key sequences `ESC A`/`B`/`C`/`D` need to be detected
   reliably without making bare `Esc` feel sluggish. Getting the timeout
   wrong makes the editor feel either lethargic (too long) or broken
   (too short — bare Esc misinterprets as start of a sequence).
   - **Mitigation:** prototype the input layer first, in isolation, with
     a synthetic test harness. Tune the timeout against real hardware
     latency before any other feature is built.

2. **Gap buffer correctness under all edits.** Off-by-one bugs in
   gap-move, gap-shrink, two-half iteration, etc. are easy to make and
   hard to debug on Z80 without a debugger.
   - **Mitigation:** unit test the gap buffer logic in a host-side
     simulator (sjasmplus → Z80 emulator → assertions). Don't rely on
     manual testing on the MicroBeast for this layer.

3. **Diff renderer drift.** If the shadow buffer disagrees with the
   actual screen state (e.g., due to terminal noise, missed escape
   sequence, partial output), every subsequent diff is wrong and the
   screen is corrupt.
   - **Mitigation:** `Ctrl-L` (forced full redraw) as an explicit user
     escape hatch. Defensive: re-emit cursor position before every
     diff-based render so cursor desync alone doesn't compound.

4. **Crash safety vs. size budget tension.** "Never crash" means
   defensive checks; defensive checks cost bytes. The ~3 KB budget is
   tentative, but real assembly will pressure it.
   - **Mitigation:** budget is tentative — accept overruns rather than
     skipping safety checks. Code-size discipline lives in non-safety
     paths (motion implementations, ex command parsing, etc.).

5. **CP/M file I/O edge cases.** Disk full mid-write, write to a closed
   file, BDOS returning unexpected codes — all of these can leak
   inconsistent state if not caught.
   - **Mitigation:** every BDOS call has a return-value check. Any
     unexpected return surfaces in the status line and aborts the
     current operation cleanly.

#### Project Risks

1. **Plateau-at-90%.** The biggest risk is that VIBE gets to "mostly
   works" and stalls there — single-author projects without external
   pressure often die at this stage.
   - **Mitigation:** the native-workflow goal is self-enforcing; if VIBE
     is unusable, the author can't use it for the games-and-Forth work
     it was built for. The pain is the forcing function.

2. **Feature creep during implementation.** "Adding new phases
   continuously" (per brief intent) is a feature, not a bug — but it
   can derail MVP delivery if it starts before MVP is solid.
   - **Mitigation:** explicit MVP gate. Growth-tier features are
     forbidden until every MVP feature works on real hardware.

3. **Esc-key-induced abandonment.** If the input layer feels bad in
   week one, the project loses momentum.
   - **Mitigation:** see Technical Risk #1. Build input first, tune it,
     prove it feels good before investing in features that depend on it.

#### Non-Risks

Several risks that the framework asks about don't apply:

- **Market risk:** N/A. No market.
- **Adoption risk:** N/A. Audience of one (plus any incidental
  retrocomputing user).
- **Compliance / regulatory risk:** N/A. Hobbyist tool, no domain.
- **Team scaling:** N/A. Single author.
- **Funding / runway:** N/A.

## Functional Requirements

These are the capabilities VIBE provides. Each is testable. Each is
implementation-agnostic. Anything missing from this list will not exist
in the MVP.

### Editor Lifecycle

- **FR1:** User can launch VIBE with no arguments and begin editing an
  empty buffer.
- **FR2:** User can launch VIBE with a filename argument and begin
  editing the contents of that file.
- **FR3:** User can quit VIBE, returning control to the CCP.

### File Operations

- **FR4:** User can save the current buffer to its current filename
  (`:w`).
- **FR5:** User can save the current buffer to a different filename
  (`:w filename`).
- **FR6:** User can open a different file, replacing the current buffer
  (`:e filename`).
- **FR7:** User can save and quit in one step (`:wq`).
- **FR8:** User can quit without saving, abandoning unsaved changes
  (`:q!`).
- **FR9:** VIBE resolves bare filenames (no drive prefix) to drive B:.
- **FR10:** VIBE accepts explicit drive-letter prefixes in filenames
  (e.g. `A:foo.fs`).
- **FR11:** VIBE refuses to load files exceeding the gap buffer
  capacity, surfacing the refusal in the status line without modifying
  the current buffer.

### Modal Editing

- **FR12:** VIBE starts in normal mode.
- **FR13:** User can enter insert mode from normal mode.
- **FR14:** User can enter command mode (ex-line entry) from normal
  mode via `:`.
- **FR15:** User can enter visual mode from normal mode.
- **FR16:** User can return to normal mode from any other mode via
  `Esc`.
- **FR17:** VIBE displays the current mode in the status line.

### Cursor Motion

- **FR18:** User can move the cursor one character left or right
  (`h`, `l`).
- **FR19:** User can move the cursor one line up or down (`k`, `j`).
- **FR20:** User can move to the next or previous word (`w`, `b`).
- **FR21:** User can move to the start or end of the current line
  (`0`, `$`).
- **FR22:** User can move to the first or last line of the buffer
  (`gg`, `G`).
- **FR23:** User can prefix any motion with a count for repetition
  (e.g. `5j`, `12G`, `3w`).

### Text Editing

- **FR24:** User can insert text before the cursor (`i`).
- **FR25:** User can insert text after the cursor (`a`).
- **FR26:** User can open a new line below the current line and enter
  insert mode (`o`).
- **FR27:** User can open a new line above the current line and enter
  insert mode (`O`).
- **FR28:** User can delete the character under the cursor (`x`).
- **FR29:** User can delete the current line (`dd`).
- **FR30:** User can delete a word (`dw`).
- **FR31:** User can yank (copy) the current line (`yy`).
- **FR32:** User can paste yanked or deleted text (`p`).

### Visual Mode

- **FR33:** User can select text by character (visual character mode).
- **FR34:** User can select whole lines (visual line mode).
- **FR35:** User can select rectangular blocks (visual block mode).
- **FR36:** User can apply delete, yank, and change operators to a
  visual selection (`d`, `y`, `c`).
- **FR37:** User can shift a visual selection right or left (`>`, `<`).
- **FR38:** User can toggle case of a visual selection (`~`).

### Operator + Motion Composition

- **FR39:** User can compose any operator with any motion to apply the
  operator over the motion's range (e.g. `dw`, `d$`, `c5w`, `y3j`).
- **FR40:** User can prefix composed operator/motion commands with a
  count (e.g. `5dd`, `2dw`, `3yy`).

### Search

- **FR41:** User can initiate a forward literal search (`/pattern`).
- **FR42:** User can repeat the most recent search (`n`).
- **FR43:** Search wraps from end-of-buffer to start; VIBE reports the
  wrap in the status line.
- **FR44:** VIBE reports "pattern not found" in the status line when
  no match exists in the buffer.

### Undo

- **FR45:** User can undo the most recent edit (`u`).
- **FR46:** VIBE reports in the status line when undo is unavailable
  (e.g., operation exceeded undo buffer).

### Display & Feedback

- **FR47:** VIBE renders only changed regions of the screen during
  normal editing (full-screen redraws happen only on initial draw or
  explicit refresh).
- **FR48:** User can force a full-screen refresh (`Ctrl-L`).
- **FR49:** VIBE displays a status line on row 24 reflecting current
  mode, filename, and the most recent message or error.

### Error Handling & Robustness

- **FR50:** VIBE responds to unsupported commands as a no-op, with
  audible/visual feedback in the status line (or beep), leaving editor
  state unchanged.
- **FR51:** VIBE surfaces every CP/M file-I/O failure (disk full,
  write-protect, file not found, drive offline) in the status line
  without entering an inconsistent state.
- **FR52:** VIBE never silently truncates or discards user data on
  save (errors are reported; the buffer remains dirty until either a
  successful save or an explicit `:q!`).

## Non-Functional Requirements

These are quality attributes — *how well* VIBE must behave, distinct from
*what* it does (the FRs). Only categories relevant to VIBE are documented;
others are explicitly listed as not applicable.

### Performance

- **NFR1: Incremental rendering.** During normal editing, VIBE emits to
  the terminal only the cells whose content has changed since the
  previous frame. Full-screen redraws are reserved for initial draw and
  explicit `Ctrl-L` refresh.
- **NFR2: Sustained typing throughput.** VIBE absorbs continuous
  insert-mode typing at typical human speeds (≥10 chars/sec) without
  dropping or coalescing keystrokes. The serial bandwidth and terminal
  latency are the floor on perceived responsiveness, not VIBE's input
  loop.
- **NFR3: Predictable cursor-motion latency.** Single-character motion
  commands (`h`, `j`, `k`, `l`, `w`, `b`) complete within one input-loop
  iteration. Counted motions (`5j`, `12G`) and large-range operators
  (`d$`, `dG`) may take proportionally longer but remain interactive
  (no perceptible freeze).
- **NFR4: Esc disambiguation budget.** The bare-`Esc` vs. arrow-key
  timeout uses the 50 Hz tick. Target: 1–2 ticks (20–40 ms). Tunable
  via a source equate; chosen value is empirically validated against
  real hardware before release.

### Reliability

- **NFR5: No crashes.** VIBE never enters a state requiring a CP/M warm
  reboot for the user to recover. Any unexpected condition is caught,
  reported in the status line, and editor state remains consistent.
- **NFR6: No silent data loss.** Every save either succeeds completely
  or surfaces an explicit error in the status line, leaving the buffer
  marked dirty. The user is never under the impression that their work
  was saved when it wasn't.
- **NFR7: Screen state recoverability.** If the shadow buffer ever
  desyncs from actual terminal state, `Ctrl-L` (full redraw) restores
  consistency. No accumulated drift survives a refresh.
- **NFR8: BDOS error handling completeness.** Every BDOS file-I/O call
  checks its return value; no return code is ignored. Unexpected codes
  abort the current operation cleanly with a status-line message.

### Resource Consumption

- **NFR9: Code size budget.** Ceiling: 5120 bytes (5 KB) of Z80 code
  (amended 2026-05-15 from the original 3072 B / ~3 KB target after
  Stories 2.2-2.5 fileio + motions footprint showed the 3 KB target
  was set pre-fileio and pre-motions implementation). The amended
  ceiling preserves the original spirit (small editor fits MicroBeast's
  tight TPA pressure) while accommodating realistic per-feature
  footprint. Stories 2.6-2.13 monitor against this ceiling; further
  amends require an explicit retro review. Safety paths (NFR5-NFR8,
  FR51 oversize-refusal, FR52 buffer-dirty preservation, BH2 clamps)
  are exempt from byte-shaving pressure — accept overruns rather
  than skip safety.
- **NFR10: TPA fit.** Total static footprint (code + data + screen
  shadow + undo buffer + gap buffer) fits within the TPA
  (`0x0100..0xD7FF`, ~54 KB).
- **NFR11: Single artifact.** VIBE ships as exactly one CP/M `.COM`
  file. No data files, no helper utilities, no install step.
- **NFR12: Static allocation only.** No runtime allocator. All buffers
  are sized at assembly time via the equates listed in
  [Internal Architecture](#source-equates-worth-naming).

### Compatibility & Portability

VIBE is **deliberately non-portable**. The compatibility NFRs here are
narrowing constraints, not broadening targets.

- **NFR13: Single platform target.** Feersum MicroBeast running CP/M 2.2
  with a VT52-capable terminal at 80×24. Other Z80 platforms, other CP/M
  versions, other terminals, and other geometries are out of scope —
  see [Non-portability](#non-portability-explicit).
- **NFR14: Fixed toolchain.** Builds with sjasmplus 1.23.0 on a Linux
  host. Other assemblers or sjasmplus versions are not supported.
- **NFR15: Standard CP/M 2.2 BDOS only.** No use of CP/M 3.x extensions,
  no MicroBeast-specific BDOS calls. The console path uses BIOS direct
  (`BIOS_CONIN/CONINST/CONOUT`); this is a deliberate exception to
  "BDOS only" justified in [Input & Keyboard](#input--keyboard).

### Maintainability

- **NFR16: Knob centralization.** All compile-time tunables (buffer
  sizes, screen dimensions, timeout counts, etc.) are defined as named
  equates in one place. No magic numbers buried in motion handlers.
- **NFR17: Mode/operator decoupling.** The dispatch tables for modes
  and the operator+motion composition layer are decoupled enough that
  adding a Growth-tier feature (new motion, new ex command, new visual
  operator) does not require restructuring existing code.
- **NFR18: Build reproducibility.** `make` from a clean tree produces a
  byte-identical `vibe.com`. No timestamps, no host-path leakage, no
  randomness in the output.

### Not Applicable

The following NFR categories are explicitly out of scope for VIBE:

- **Security:** single-user CP/M, no network, no sensitive data, no
  authentication concept.
- **Scalability:** audience of one, fixed 64 KB RAM, no growth path.
- **Accessibility:** retrocomputing tool on a vintage-grade terminal;
  no public audience and no regulatory framework applies.
- **Integration:** the only "external" surface is the CP/M filesystem
  via FCB I/O, which is covered as a platform constraint, not an
  integration NFR.
- **Internationalization:** ASCII-only, English-only. Non-goal.
