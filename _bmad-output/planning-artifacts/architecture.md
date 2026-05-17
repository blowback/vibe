---
stepsCompleted: [1, 2, 3, 4, 5, 6, 7, 8]
inputDocuments:
  - _bmad-output/planning-artifacts/prd.md
  - docs/brief.md
workflowType: 'architecture'
project_name: 'vibe'
user_name: 'Ant'
date: '2026-05-08'
lastStep: 8
status: 'complete'
completedAt: '2026-05-08'
---

# Architecture Decision Document

_This document builds collaboratively through step-by-step discovery. Sections are appended as we work through each architectural decision together._

## Project Context Analysis

### Requirements Overview

**Functional Requirements (52 FRs across 11 categories):**

The FRs split cleanly into editor-shaped concerns: lifecycle (FR1–FR3),
file operations (FR4–FR11), modal editing (FR12–FR17), cursor motion
(FR18–FR23), text editing (FR24–FR32), visual mode (FR33–FR38),
operator+motion composition (FR39–FR40), search (FR41–FR44), undo
(FR45–FR46), display/feedback (FR47–FR49), and error handling
(FR50–FR52). The composition layer (FR39, FR40) is the
architecturally significant cross-cut: it requires the operator,
motion, count, and visual-selection subsystems to share a uniform
dispatch contract rather than each implementing its own.

**Non-Functional Requirements (18 NFRs across 5 categories):**

The NFRs are dominated by three load-bearing contracts:

- **Reliability (NFR5–NFR8):** crash-free, no silent data loss, screen-
  state recoverable, every BDOS return code checked. These are the
  hard floor — NFR9 explicitly exempts them from the size budget.
- **Performance (NFR1–NFR4):** incremental rendering, sustained typing
  throughput, predictable cursor-motion latency, and the 1–2 tick
  Esc-disambiguation budget. Each requires specific architectural
  mechanism (shadow buffer, input-loop discipline, tick-driven
  timeout).
- **Resource Consumption (NFR9–NFR12):** 5760 B code budget (amended 2026-05-16 from the prior 5 KB; itself amended 2026-05-15 from 3 KB tentative),
  TPA fit, single .COM artifact, static allocation only. The budget is
  intuition-not-cap; safety overrides it.

Maintainability (NFR16–NFR18: knob centralization, mode/operator
decoupling, build reproducibility) shapes how the architecture is
*expressed* in source — equates over magic numbers, decoupled dispatch,
deterministic build.

Compatibility (NFR13–NFR15) is *narrowing*: VIBE targets exactly one
platform/toolchain. There is no abstraction layer between VIBE and the
MicroBeast/CP/M 2.2/VT52/sjasmplus stack.

**Scale & Complexity:**

- Primary domain: embedded / retro systems software — single .COM
  binary, single-tasking, single-user, BIOS-direct I/O, hand-managed
  register conventions.
- Complexity level: medium overall, concentrated in three layers —
  gap-buffer correctness, diff-renderer integrity, and Esc/arrow input
  disambiguation. Risk-rank-1 in the PRD names input.
- Estimated architectural components: ~10–12 source modules
  (input layer, render, gap buffer, mode dispatch, command parser, ex
  command line, search, file I/O, undo, status line, init/teardown,
  BIOS shim), all linked to a single .COM.

### Technical Constraints & Dependencies

**Platform constraints (fixed, non-portable):**

- Z80 CPU; CP/M 2.2 BDOS only (no 3.x, no MicroBeast extensions);
  VT52 terminal; 80×24 screen; 54 KB TPA (`0x0100..0xD7FF`).
- BIOS-direct console (CONIN/CONINST/CONOUT) — deliberate BDOS
  exception for latency and Ctrl-C ownership.
- 50 Hz timer tick — opportunistic use for Esc disambiguation and
  cursor blink; not required for correctness.
- Default drive is B: (RAM disk); persistence to flash is out-of-band
  via the CP/M `WRITE.COM` ritual, not VIBE's job.
- 8.3 uppercase filenames; 128-byte sectors; `0x1A` text EOF.

**Toolchain constraints:**

- sjasmplus 1.23.0 exactly (NFR14).
- Make-based build, Linux host.
- Transfer to MicroBeast via SLIDE (dev ergonomics, not product
  requirement).
- Build reproducibility: byte-identical output from clean tree
  (NFR18).

**Pre-pinned internal architecture (from PRD §Internal Architecture —
treat as decided, do not relitigate):**

- TPA layout: code → static data → gap buffer (capped via
  `GAP_BUFFER_MAX`, ~32 KB) → reserved pool → BDOS.
- Static-only allocation; no runtime allocator.
- Gap buffer: fixed-size, two-halves invariant, gap-tracks-cursor.
- Undo: 256-byte fixed buffer, single-level, refuse-on-capacity.
- Modes: one byte at fixed address; table-driven per-mode dispatch;
  visual sub-mode in a separate byte.
- Command parser: 16-bit count accumulator + pending-operator byte;
  doubled-operator detection; ex/search command lines as separate
  ~64-byte buffers.
- Render: 1920-byte shadow buffer, per-cell diff, contiguous-run
  emission with `ESC Y row col`, status line on row 24 by same
  mechanism.
- Search: literal forward only, case-sensitive, wraps once with
  status notice.
- File I/O: direct unsafe write (no temp+rename), FCB-based,
  128-byte DMA at `0x0080`, walk gap in two halves, append `0x1A`.
- Source equates: `GAP_BUFFER_MAX`, `UNDO_BUFFER_SIZE`,
  `STATUS_LINE_WIDTH`, `EX_COMMAND_BUFFER`, `SEARCH_PATTERN_BUFFER`,
  `SCREEN_ROWS`, `SCREEN_COLS`, `EDITABLE_ROWS`.

### Cross-Cutting Concerns Identified

These touch multiple modules and need uniform handling at the
architecture level rather than per-module:

1. **Error funnel to status line.** Every error source — BDOS I/O
   failures, undo-too-large, pattern-not-found, search-wrapped, gap-
   buffer-cap-exceeded, unsupported-command no-op — terminates in a
   single status-line emit path. Architecture must define the message
   buffer, format convention, and the rule that *every* error path
   reaches it.

2. **BDOS return-code discipline (NFR8).** No BDOS call may go
   unchecked. Likely realized as a checked-call macro/helper that
   wraps every BDOS function-N invocation, bails on unexpected return,
   and routes the error into the status-line funnel.

3. **Shadow-buffer integrity.** The render pipeline assumes the
   shadow accurately reflects screen state. Every byte emitted to
   `BIOS_CONOUT` for visible cells must update the shadow; any escape
   sequence emitted (cursor positioning, screen clear) must leave
   the shadow consistent or be paired with a re-sync. `Ctrl-L`
   (NFR7) is the explicit drift-recovery escape hatch.

4. **Gap-buffer invariants.** Every editing primitive (insert, delete,
   move-gap, count-aware operators, visual-region operators) must
   preserve the two-halves invariant and update cursor + gap
   coherently. Off-by-one bugs here are the PRD's risk-rank-2.

5. **Z80 register-use conventions.** Without a calling-convention
   discipline (which registers each layer owns, what callees must
   preserve, what the cursor / gap-pointer regs are), composing
   handlers from a dispatch table becomes fragile. This is an
   architectural decision pending in this workflow.

6. **Code-size discipline vs. safety.** Per NFR9, safety paths
   (NFR5–NFR8) are exempt from the budget. Architecture must mark
   which subsystems are safety-load-bearing so future-Ant doesn't
   shave bytes there.

7. **Esc / arrow timing window.** The input layer's polling pattern
   (CONINST + tick counter, 1–2 tick window) is shared by every
   keystroke, not just Esc. This is the lowest-level cross-cut: every
   higher-level mode handler depends on it being correct.

8. **Reproducible build (NFR18).** No timestamps, no host paths, no
   randomness in the binary. Affects how the Makefile and any code-
   generation steps are constructed.

## Starter Template Evaluation

### Primary Technology Domain

Z80 assembly targeting CP/M 2.2 on the Feersum MicroBeast — embedded /
retro systems software. Toolchain: sjasmplus 1.23.0 + GNU Make on a
Linux host. Output: a single `vibe.com` artifact transferred to the
MicroBeast via SLIDE.

### Starter Options Considered

None viable. The web ecosystem of "starter templates" (oclif, T3,
Next.js, Vite, etc.) is structurally inapplicable: VIBE has no
runtime, no package manager, no language ecosystem dependencies, and
no JavaScript / TypeScript / Python anywhere in the build. The
sjasmplus community publishes example programs and demos, not project
scaffolds — and adopting one would conflict with NFR14 (pinned
sjasmplus 1.23.0), NFR18 (reproducible build), and the bespoke
module decomposition this architecture needs.

### Selected Starter: None — bespoke skeleton

**Rationale for Selection:**

A from-scratch skeleton is the right answer because:

1. **NFR14 fixes the toolchain.** sjasmplus 1.23.0 + Make is the
   constraint. There is no decision space for a starter to occupy.
2. **NFR18 demands reproducible builds.** Adopting an unaudited
   skeleton risks importing timestamp / host-path leakage that would
   then need to be rooted out.
3. **The 5760 B code budget (NFR9, amended 2026-05-16 from 5 KB; itself amended 2026-05-15 from 3 KB) and crash-free contract (NFR5)
   make the project-shape itself architectural.** Where files split,
   how includes are organized, and how the Makefile drives sjasmplus
   are not generic concerns — they flow from the pre-pinned module
   set in the PRD's Internal Architecture.
4. **No language ecosystem to bootstrap.** No `package.json`, no
   `requirements.txt`, no lockfile. The skeleton is essentially a
   directory tree + a Makefile + a top-level `.asm` entry point.

**Initialization Command:**

```bash
# No CLI scaffold. Project initialization is a manual creation of
# the skeleton below. The first implementation story is "Story 0:
# Project skeleton" — produce these files such that `make` yields a
# (non-functional, ~10-byte stub) `vibe.com` successfully assembled
# by sjasmplus 1.23.0.
```

**Architectural Decisions Provided by Skeleton:**

**Language & Runtime:**

- Z80 assembly only. No C, no inline higher-level glue.
- No runtime. The .COM is loaded at `0x0100` and runs on bare CP/M.
- Source files use `.asm` extension. Include files use `.inc`.

**Source-Tree Layout:**

```
vibe/
├── Makefile                # GNU Make; sjasmplus invocation,
│                           # SLIDE-push target, clean
├── README.md               # Build + transfer instructions
├── src/
│   ├── vibe.asm            # Top-level: ORG 0x0100, entry,
│   │                       # exit-to-CCP, includes all modules in
│   │                       # link order
│   ├── init.asm            # Cold-start init + teardown
│   ├── input.asm           # CONIN/CONINST poll, Esc disambig,
│   │                       # tick-window timeout
│   ├── dispatch.asm        # Mode byte + per-mode key tables
│   ├── parser.asm          # Count accumulator, pending-operator,
│   │                       # operator+motion composition
│   ├── motions.asm         # h j k l w b 0 $ G gg, count-aware
│   ├── edits.asm           # i a o O x dd dw yy p, cw, ~
│   ├── visual.asm          # Visual line/char/block; d y c > <
│   ├── gapbuf.asm          # Gap buffer primitives + invariants
│   ├── render.asm          # Shadow buffer, diff emit, ESC Y runs
│   ├── statusln.asm        # Status line buffer + emit + error
│   │                       # funnel
│   ├── search.asm          # Literal forward, wrap, n
│   ├── exline.asm          # Ex command-line parse + dispatch
│   ├── fileio.asm          # FCB-based load/save, BDOS funnel
│   └── undo.asm            # 256B inverse-op buffer
├── inc/
│   ├── equates.inc         # All NFR16-mandated knobs:
│   │                       # GAP_BUFFER_MAX, UNDO_BUFFER_SIZE,
│   │                       # STATUS_LINE_WIDTH, EX_COMMAND_BUFFER,
│   │                       # SEARCH_PATTERN_BUFFER, SCREEN_ROWS,
│   │                       # SCREEN_COLS, EDITABLE_ROWS,
│   │                       # ESC_TIMEOUT_TICKS, etc.
│   ├── bios.inc            # Symbolic BIOS jump-table addresses:
│   │                       # BIOS_CONIN, BIOS_CONINST,
│   │                       # BIOS_CONOUT, BDOS_ENTRY, FCB,
│   │                       # DMA_DEFAULT, etc.
│   ├── bdos.inc            # BDOS function numbers + helper macros
│   │                       # (incl. checked-call macro for NFR8)
│   ├── vt52.inc            # VT52 control byte equates
│   │                       # (ESC, CURSOR_UP, ERASE_TO_EOL, etc.)
│   └── modes.inc           # MODE_NORMAL, MODE_INSERT, etc. equates
├── test/
│   ├── README.md           # How to run; what's headless vs UAT
│   ├── Makefile            # Builds each test/cases/*.asm to a .COM
│   │                       # and drives iz-cpm over them
│   ├── cases/              # Per-subsystem headless .COM tests
│   │   ├── gapbuf-*.asm    # gap-buffer invariants under random ops
│   │   ├── parser-*.asm    # count + operator + motion composition
│   │   ├── search-*.asm    # forward, wrap, no-match
│   │   ├── undo-*.asm      # capacity refusal + inverse-op replay
│   │   └── fileio-*.asm    # FCB load/save against fixture files
│   └── fixtures/           # Input files (pre-built B: drive image,
│                           # text fixtures, expected outputs)
└── .gitignore              # vibe.com, *.lst, *.sld, *.bin, etc.
```

The 1:1 mapping between the PRD's pinned subsystems and `src/*.asm`
files is intentional: each module owns one cross-cutting concern, and
`vibe.asm` is the single link-order entry point.

**Build Tooling:**

- `make` — assemble `src/vibe.asm` with sjasmplus 1.23.0; produce
  `vibe.com` in the project root (or a `build/` subdir — TBD in
  step-04).
- `make test` — assembles every program in `test/cases/` and runs
  each headless under iz-cpm with a per-case timeout. Pass/fail
  reported per case; exit non-zero on any failure.
- `make push` — invoke SLIDE to transfer `vibe.com` to the
  MicroBeast (dev ergonomics, optional target).
- `make clean` — remove all build artifacts.
- sjasmplus invocation: deterministic (no `--date`, no host-path
  embedding). Per NFR18 the build is byte-identical from a clean
  tree.
- Listing and symbol files emitted into a non-tracked location for
  size auditing against the 5760 B budget (NFR9, amended 2026-05-16 from the prior 5 KB; itself amended 2026-05-15 from 3 KB).

**Testing Framework:**

Host-side test harness uses **iz-cpm** as the Z80/CP/M 2.2 emulator
on the Linux build host. The harness runs *headless, non-interactive*
test programs only — anything requiring keyboard input or visual
verification of VT52 output defers to UAT on real MicroBeast hardware
(see "UAT" below).

**Harness shape:**

- Each test in `test/cases/` is a small `.asm` program assembled to
  a `.COM`. It includes the same `inc/*.inc` headers as VIBE, plus
  the specific subsystem(s) under test, and runs a deterministic
  exercise to completion.
- Pass/fail signal: tests use a tiny convention — write a sentinel
  byte (`0x00` = pass, non-zero = fail-code) to a known address,
  then exit via BDOS function 0. The harness driver inspects the
  byte (or iz-cpm's stdout capture, or a fixture-output diff) to
  decide.
- `make test` (top-level) recurses into `test/Makefile`, builds
  every case, runs each under iz-cpm with a hard timeout, and
  reports.
- File-I/O tests use real BDOS calls against a small fixture
  filesystem mounted by iz-cpm — no FCB stubbing, no shimming. This
  catches CP/M-isms (write-protect, EOF, sector boundary) that a
  hand-rolled mock would miss.

**What's testable headlessly (in scope for the harness):**

- Gap-buffer primitives — insert/delete/move-gap/two-half iteration
  under random and adversarial sequences. (PRD risk-rank-2.)
- Command parser — count accumulator, pending operator, doubled-op
  detection, operator+motion composition.
- Search — literal forward match, wrap behavior, "not found".
- Undo — capacity-refusal policy, inverse-op replay correctness.
- File I/O — FCB load/save round-trip, `0x1A` EOF handling,
  oversize refusal, write-protect / disk-full surface as expected
  status codes.
- Render math — shadow-buffer diff computation against synthetic
  before/after frames (no actual VT52 emission needed).

**What's NOT testable headlessly (deferred to UAT on real hardware):**

- **Esc / arrow disambiguation timing** (PRD risk-rank-1). The
  50 Hz tick window can't be meaningfully validated under iz-cpm;
  the emulator's tick model and the MicroBeast's real timing differ
  enough that a passing emulator test wouldn't prove anything.
- Full-screen render drift recovery via `Ctrl-L` against a real
  VT52.
- Sustained-typing throughput (NFR2) under serial-line bandwidth.
- End-to-end editing journeys (PRD §User Journeys).
- Interactive ex-command line editing (backspace, Esc-cancel).

**UAT:**

Interactive validation, hardware-timing-sensitive tests, and full
editing journeys run on the actual MicroBeast. Ant performs these
manually as part of the dev loop; the architecture does not assume
an automated path for them. The headless harness exists to catch
correctness regressions in the algorithmic layers *before* they
reach hardware, where debugging is much more expensive.

**Code Organization:**

- One subsystem per `.asm` file; one entry point per public symbol.
- All compile-time knobs live in `inc/equates.inc` (NFR16).
- All BIOS / BDOS magic addresses and function numbers live in
  `inc/bios.inc` and `inc/bdos.inc` — never inline (NFR16).
- `vibe.asm` is the single `ORG 0x0100` entry. It defines link order
  (code → static data → gap buffer → reserved pool implicitly via
  end-of-image label).

**Development Experience:**

- Edit / `make` / `make push` / test on MicroBeast loop for end-to-
  end; `make test` for fast inner-loop on subsystems with host-side
  unit coverage via iz-cpm.
- sjasmplus produces a listing file enabling per-module size
  accounting against the NFR9 budget.
- `.gitignore` excludes assembler output and editor swap files; the
  repo is source-only.

**Note:** Project initialization (creating this skeleton such that
`make` succeeds with a stub `vibe.asm`) is the first implementation
story.

## Core Architectural Decisions

### Decision Priority Analysis

**Critical (block implementation):**

- State representation: cursor, gap pointers, mode byte, visual anchor.
- Module calling conventions: register discipline, dispatch entry shape,
  error funnel, checked-BDOS macro.
- Input loop: Esc-disambiguation timing pattern.
- Build layout: sjasmplus invocation, output path, reproducibility flags.

**Important (shape architecture):**

- Word-boundary definition for `w`/`b`/`dw`.
- Counted-motion bounds policy.
- Yank/paste register storage.
- Visual-block semantics on jagged lines.
- Render dirty-tracking granularity.
- Test harness sentinel-byte convention.

**Deferred (post-MVP / Growth tier — explicitly out of scope):**

- Multi-level undo storage scheme. Reserved pool earmarked.
- Backward search (`?`). Forward-only in MVP.
- Marks / jumps registers (`m`, `'`). Reserved pool earmarked.
- Macro recording (`q`).
- Multi-buffer state.
- Configurable keymap.
- Capital-`W`/`B`/`E` (whitespace-only-separator) word motions.

### State Representation

**SR1: Cursor representation — 16-bit absolute buffer offset only.**
No cached line/col. Line/col is recomputed on demand by render and
status-line. Rationale: every mirrored state is a sync point and
therefore a correctness trap (PRD risk-rank-2). Bytes saved on cache
maintenance; cycles spent on recompute are well within NFR3's
"interactive" budget.

**SR2: Gap-buffer pointers — two 16-bit pointers, `gap_start` and
`gap_end`.** `gap_start` = first free byte (just past last char of
before-gap half). `gap_end` = first occupied byte of after-gap half.
Gap size = `gap_end - gap_start`. File length = `GAP_BUFFER_END -
gap_end + gap_start - GAP_BUFFER_BASE`. Two-halves invariant: any
edit moves the gap to the cursor first, then mutates only at
`gap_start`.

**SR3: Cursor-to-buffer mapping.** Cursor offset is in *logical file
space* (i.e., the buffer with the gap collapsed out). Convert to
physical address: if `cursor < (gap_start - GAP_BUFFER_BASE)`,
physical = `GAP_BUFFER_BASE + cursor`; else physical = `gap_end +
(cursor - (gap_start - GAP_BUFFER_BASE))`.

**SR4: Mode byte + visual sub-mode byte at fixed addresses in static
data.** Mode is one of `MODE_NORMAL | MODE_INSERT | MODE_COMMAND |
MODE_VISUAL`. Visual sub-mode is one of `VIS_CHAR | VIS_LINE |
VIS_BLOCK`, valid only when mode = `MODE_VISUAL`.

**SR5: Visual-mode anchor — 16-bit offset stored alongside sub-mode.**
Selection extent = (anchor, current_cursor); ordering computed
on-the-fly. No additional state.

**SR6: Yank/paste register — single global register, 1024 bytes,
located in the reserved pool.** Header: 1 byte `paste_kind`
(`KIND_CHAR | KIND_LINE | KIND_BLOCK`) + 2 bytes `paste_length`. On
yank/delete that exceeds 1024 bytes, the register is *not* updated
and status line shows "yank too large". Earlier register contents
preserved. Rationale: predictable failure mode > silent truncation.

**SR7: No line-position cache in MVP.** Motion handlers walk the gap
buffer to find line boundaries on each command. Combined with V2's
`top_line_offset` (see Validation Results), render's row/col cost is
bounded by visible-region size (~1920 byte scans worst case), not
buffer size — sub-perceptible for any plausible file. Reserved-pool
feature post-MVP if profiling ever shows latency on long files.

### Module Calling Conventions

**MC1: Caller-saved everywhere by default.** No callee-saved
discipline. Each handler is responsible for preserving anything *it*
needs across a call it makes. Rationale: push/pop pairs are 22
T-states each; multiplied across the call graph this would dominate
the budget.

**MC2: Named-purpose register conventions documented per-module.**
Each `.asm` file's header comment lists which registers it owns and
what state they hold across the module's public entry points.
Example: `gapbuf.asm` may document `HL = cursor offset`, `DE =
working`, `BC = count`. The convention is *documented*, not enforced
by tooling.

**MC3: Dispatch-table entry — sparse sorted (key, handler_addr)
tables per mode, dispatched via binary search.** Each entry is 3
bytes: 1-byte ASCII key + 2-byte handler address. Entries are
sorted ascending by key at assembly time (hand-ordered in source for
auditability — sparse maps are short enough that sorting tooling
isn't worth the build complexity). Per-mode table sizes are bounded
by the bound-key count: ~30 normal-mode keys, ~5 insert-mode special
keys (Esc, Backspace, arrows-via-sentinel), ~15 ex-line keys, ~10
visual-mode operator keys ≈ 60 entries total ≈ 180 bytes across all
four mode tables. Total dispatch overhead: ~180 B vs. the
flat-256-entry approach's 2 KB — ~1.8 KB clawed back to the code
budget.

**Dispatch routine** (single shared `dispatch_key` for all modes,
parameterized by mode-table base address):

```
; In:  A = key just consumed
;      HL = base of mode table (sorted), B = entry count
; Out: jumps to handler, or to mode's unbound-key handler
dispatch_key:
    LD D, 0                  ; lo = 0
    LD E, B                  ; hi = entry_count
.search:
    LD A, E
    SUB D
    RET Z                    ; lo == hi → not found
    SRL A                    ; A = (hi - lo) / 2
    ADD A, D                 ; A = mid index
    ; ... compute address: HL_base + mid*3, compare key, narrow ...
    ; ~6 iterations worst case for 64 entries
```

Per-mode unbound-key fall-through: each mode table is paired with a
2-byte "unbound" handler address; binary search exhaustion jumps
there. Normal/visual modes fall through to a "status beep + no-op"
handler (FR50). Insert mode falls through to the literal-character
insertion handler (the common case for insert mode is "insert this
byte into the buffer").

**Cycle cost analysis:** Worst-case 6 iterations × ~50 T-states per
iteration ≈ 300 T-states per keystroke for dispatch. At 4 MHz that's
75 µs — three orders of magnitude under perceptible. Acceptable.

**MC4: Handler signature — A=key just consumed, accumulator state
in fixed addresses, return via `RET`.** No register-passed
parameters into handlers. Operator/motion composition reads the
accumulator state (count, pending-operator) from its fixed addresses
in static data.

**MC5: Single status-message funnel — `status_set_message` (single
entry point).** Every status source — errors, informational notices
("search wrapped", "buffer modified"), capacity refusals — calls
this with `HL = pointer to null-terminated message string`,
optionally `A = error code` (zero for non-error notices). Function
copies into the 80-byte status line buffer, sets the dirty flag, and
returns. The next render pass picks up the dirty flag and emits.

**MC6: Checked-BDOS-call macro — `BDOS_CALL fn` macro.** Expansion:
`LD C,fn` + `CALL 0x0005` + `OR A : JP M, bdos_error_funnel` (where
the funnel selects message by saved fn-number and routes to
`status_set_message`). Every BDOS call site uses the macro; raw
`CALL 0x0005` is forbidden by convention. NFR8 is enforced by code
review against this rule.

**MC7: Static memory map — fixed addresses for cross-module state.**
All module-shared variables (mode byte, cursor, gap pointers, status
buffer dirty flag, etc.) live in a single static-data block declared
in `inc/state.inc` (added to the skeleton). Each variable is a named
equate over a fixed offset. Modules read/write by symbol, never by
inline address.

### Rendering & Input

**RI1: Render dirty-tracking — per-row dirty bitmap (3 bytes for 24
rows) + per-cell diff within dirty rows.** Edits mark the row(s)
they touch as dirty. A render pass walks only dirty rows; within
each dirty row, performs cell-by-cell shadow comparison and emits
contiguous-run runs. Rationale: idle rows skip the comparison loop
entirely; mid-edit redraw cost is bounded by the rows actually
changed.

**RI2: Render scheduling — render runs after each input-loop
iteration completes processing, before next blocking read.** No
periodic timer-driven render. Idle = no emission.

**RI3: `Ctrl-L` — full redraw + dirty-bitmap clear.** Every row
marked dirty; render pass therefore re-emits everything; shadow
buffer re-synced from buffer state. Drift escape hatch for NFR7.

**RI4: Cursor-positioning emission policy — emitted *last* in every
render pass.** Even if no cells changed, if logical cursor moved,
emit one `ESC Y row col`. Defensive: re-emit cursor position after
any escape sequence emitted by the diff pass (so cursor position is
never ambiguous mid-frame).

**RI5: Esc-disambiguation pattern.**

```
input_get_key:
    CALL bios_conin            ; A = first byte
    CP ESC                     ; was it Esc?
    JR NZ, .return             ; no — just return
    ; Esc seen — start tick-window poll
    LD B, ESC_TIMEOUT_TICKS    ; default 2 ticks (~40 ms)
.poll:
    CALL bios_coninst          ; nonzero if byte ready
    OR A
    JR NZ, .have_followup
    CALL tick_wait_one         ; block until next 50Hz tick
    DJNZ .poll
    ; timeout — treat as bare Esc
    LD A, ESC
    JR .return
.have_followup:
    CALL bios_conin            ; A = follow-up byte (e.g. 'A'..'D')
    ; synthesize a single-byte keycode for arrow keys:
    ;   ESC A → KEY_ARROW_UP    (0x80)
    ;   ESC B → KEY_ARROW_DOWN  (0x81)
    ;   ESC C → KEY_ARROW_RIGHT (0x83)
    ;   ESC D → KEY_ARROW_LEFT  (0x82)
    ; (small lookup or arithmetic; unrecognized seq → bare Esc)
    CALL synthesize_arrow_key  ; A = synthesized keycode, or A=ESC
.return:
    RET
```

`tick_wait_one` blocks until the 50 Hz tick variable advances by one;
this delivers the 1–2 tick window deterministically. Returning a
single-byte synthesized keycode in `A` keeps the MC4 handler-signature
contract intact (no register-passed composites). Arrow keys land in
the dispatch table at slots 0x80–0x83; unrecognized escape sequences
fall back to bare Esc. The `KEY_ARROW_*` equates live in
`inc/modes.inc`, placed above ASCII so they cannot collide with normal
keys.

**RI6: Input-loop top level — single `input_get_key` → `dispatch`
loop.** No interrupt-driven event queue. Keyboard scanner interrupt
populates a 1-byte ring (BIOS already handles this); VIBE polls via
`BIOS_CONIN/CONINST`. Predictable, matches PRD.

### Build & Artifact Layout

**BA1: Output path — `vibe.com` at the project root.** Not in a
`build/` subdir. Rationale: SLIDE-push and CP/M transfer ergonomics
are simpler when the artifact is at a stable, tooling-friendly path.
`make clean` removes it; `.gitignore` excludes it.

**BA2: sjasmplus invocation flags (deterministic, NFR18-compliant):**

```
sjasmplus --nologo --msg=err --raw=vibe.com \
          --lst=build/vibe.lst --sld=build/vibe.sld \
          src/vibe.asm
```

- `--nologo` — suppresses sjasmplus version banner from output.
- `--msg=err` — keeps stdout clean unless there's an error.
- `--raw=vibe.com` — emits a flat binary, byte-1 origin. (sjasmplus
  default for raw is the value at the first `ORG`; verify this
  still produces a valid CP/M `.COM` — first implementation story
  checks this empirically.)
- `--lst` and `--sld` go to `build/` (gitignored) for size auditing
  and possible debugger integration. Listing-file generation does
  not affect the `.com` bytes.

No `--date` or host-path-embedding flags. Rebuilds from a clean tree
produce byte-identical `vibe.com` (NFR18; verifiable by `sha256sum`).

**BA3: Make recursion — top-level `Makefile` + `test/Makefile`.**
Top-level `make` targets: `all` (default → `vibe.com`), `test`,
`push`, `clean`, `sizes` (prints per-section size from the listing
file for budget audit). `make test` recurses into `test/Makefile`,
which builds each `test/cases/*.asm` to a `.com` and drives iz-cpm
over them with timeout.

**BA4: SLIDE push — `make push` invokes the `slide` CLI directly.**
Specific command form deferred to first real push (depends on the
SLIDE invocation convention in the dev environment). Listed as a
named target so the dev loop is uniform.

### Behavior Decisions (vi-spirit-not-fidelity calibrations)

**BH1: Word boundary for `w`/`b`/`dw` — vi lowercase-`w` semantics.**
A "word" is a maximal run of either: (a) alphanumerics-plus-underscore,
or (b) non-whitespace-non-(a). Whitespace separates but is not a
word. Rationale: matches what muscle memory expects from `w` in
vim/nvi/elvis. The ~30-byte cost of character-class classification
(an `is_word_char` test) is in the "spend where muscle memory
matters" budget. Capital-`W`/`B`/`E` (whitespace-only-separator) not
in MVP — Growth tier.

**BH2: Counted-motion bounds — clamp at BOF/EOF.** `100j` at line 5
of a 10-line file moves to line 10 (clamps), not error, not wrap.
Same for `h`/`l`/`w`/`b`/`G`/`gg`. Rationale: matches vi behavior;
no status-line message needed for clamp.

**BH3: Visual-block on jagged lines — operate on virtual rectangle;
short lines are not extended in the buffer.** Delete (`d`) on a
block that extends past EOL of some rows: those rows are deleted
only up to their EOL; gap structure is not padded. Insert/change
(`c`) into a block crossing short lines: insertion happens
line-by-line at the column-or-EOL position. This matches vi/vim
behavior closely enough that muscle memory transfers; documented as
a known sharp edge.

**BH4: `n` after edits — re-searches from one byte past current
cursor every time.** Last-match offset is *not* cached. The "one
byte past" rule means `n` advances even if the cursor is currently
sitting on a previous match (matches PRD §Search). If the buffer
was edited between searches, `n` finds the next match from one
byte past wherever the cursor sits now. Rationale: simpler, no
invalidation logic needed, and matches user mental model.

**BH5: `:q` with unsaved changes — refuse with message; `:q!`
abandons.** Standard vi behavior. Unsaved-changes flag = 1 bit in
mode/state byte block. Set on every successful edit; cleared on
successful `:w`.

**BH6: `:e` with unsaved changes — same policy as `:q`.** Refuse
with "no write since last change" message. `:e!` to force is in
MVP scope (small additive).

### Test Harness Conventions

**TH1: Sentinel pass/fail address — `0xCFFE` (2 bytes).** Well below
BDOS at `0xD800`, well above any plausible static-data + gap-buffer
extent of test programs (which won't allocate the full
`GAP_BUFFER_MAX`). Convention: byte at `0xCFFE` = `0x00` on pass,
non-zero fail-code; byte at `0xCFFF` = optional fail-context byte.
Test-case prologue zeros these; epilogue exits via BDOS function 0
without modifying them on failure paths.

**TH2: Test driver — shell script per-case, top-level Makefile rolls
results.** Each case's Makefile rule: assemble → run under iz-cpm
with a 5-second timeout → on completion, dump `0xCFFE` bytes via
iz-cpm's post-mortem mechanism (or a tiny appended "report" routine
in the test) → exit 0/1 accordingly. Concrete invocation form
locked in the first test-case implementation story.

**TH3: Fixture filesystem — `test/fixtures/` mounted as iz-cpm B:
drive.** Per-test fixtures (small text files for FCB load tests,
write-protected files via filesystem permissions, etc.) live there.
iz-cpm's drive-mount mechanism is used to expose the directory.

### Decision Impact Analysis

**Code-budget reclamation from MC3.** The binary-search dispatch
choice drops total dispatch-table footprint from ~2 KB (flat
256-entry × 4 modes) to ~180 B (sparse sorted × 4 modes), reclaiming
~1.8 KB into the 5760 B code envelope (NFR9). The shared `dispatch_key`
routine adds ~30 B. Net reclamation ≈ 1.77 KB — meaningful headroom
for safety paths NFR9 already exempts, plus per-handler defensive
checks.

**Implementation sequence (architecturally enforced):**

1. **Skeleton + build (BA1–BA3)** — produces a stub `.com` that
   assembles cleanly. Foundation for everything else.
2. **State equates + static memory map (MC7, SR1–SR5)** — single
   source of truth for cross-module addresses. Every other module
   includes this.
3. **BIOS / BDOS shims (`bios.inc`, `bdos.inc`) + checked-call
   macro (MC6)** — every later module uses these.
4. **Gap buffer (gapbuf.asm, SR2–SR3)** — testable headlessly via
   iz-cpm; PRD risk-rank-2 demands it ships with tests.
5. **Input layer + Esc disambig (RI5–RI6)** — PRD risk-rank-1; must
   be UAT-validated on real MicroBeast before motion handlers are
   built.
6. **Mode dispatch + parser (MC3, MC4)** — depends on input layer.
7. **Render pipeline (RI1–RI4)** — depends on shadow buffer + gap
   buffer.
8. **Motions + edits + visual + ex-line + search + undo + file I/O**
   — once 1–7 are solid, these are largely independent in parallel.
9. **End-to-end UAT loop on hardware.**

**Cross-component dependencies:**

- Every error path → `status_set_message` (MC5).
- Every BDOS call → `BDOS_CALL` macro (MC6).
- Every editing primitive → gap-buffer module (SR2–SR3).
- Every keystroke → `input_get_key` (RI5).
- Every screen byte → `BIOS_CONOUT` via render pass (RI1) + shadow
  update.
- All compile-time knobs → `inc/equates.inc` (NFR16).
- All cross-module addresses → `inc/state.inc` (MC7).

## Implementation Patterns & Consistency Rules

### Pattern Categories Defined

VIBE has no databases, APIs, or web framework conventions to pin. The
conflict points are source-level: symbol naming, file structure,
register-contract documentation, label scoping, message format, and
test conventions. These exist because Z80 assembly has no language
server enforcing style — convention is the only mechanism preventing
drift between modules.

**Conflict points addressed:** ~12 categories (naming, file headers,
routine contracts, label scoping, instruction case, indentation,
string conventions, message format, macro/equate distinction, test
naming, include ordering, gitignore policy).

### Naming Patterns

**Public symbols (cross-module entry points):** `module_action`,
lowercase with underscores. The module name matches the `.asm`
filename. Examples:

```
gapbuf_insert       ; in src/gapbuf.asm
gapbuf_delete       ; in src/gapbuf.asm
render_full         ; in src/render.asm
render_diff         ; in src/render.asm
status_set_message    ; in src/statusln.asm
input_get_key       ; in src/input.asm
dispatch_key        ; in src/dispatch.asm
```

Rationale: `module_` prefix makes cross-module references self-
documenting (`CALL gapbuf_insert` is unambiguous about where to look).

**Internal labels (within a routine):** sjasmplus dotted-local syntax,
short and purpose-named. Use `.loop`, `.next`, `.done`, `.found`,
`.notfound`, `.error` — any label prefixed `.` is scoped to the
preceding global label. Avoid numeric labels (`1$`, `2$`) — opaque.

```
gapbuf_insert:
    ; ... setup ...
.loop:
    LD A, (HL)
    OR A
    JR Z, .done
    ; ...
    JR .loop
.done:
    RET
```

**Equates and macros — `UPPER_SNAKE_CASE`.** Distinguishes compile-
time constants and macros from runtime symbols at a glance:

```
GAP_BUFFER_MAX      EQU 32768
ESC_TIMEOUT_TICKS   EQU 2
MODE_NORMAL         EQU 0
BDOS_CALL           MACRO fn ...    ; macro name uppercase
```

**Variables in static data (read/write at runtime) — lowercase.**
Declared as labels in `inc/state.inc` (or wherever the static-data
block lives), accessed by name:

```
mode_byte:          DEFB 0
cursor_offset:      DEFW 0
gap_start:          DEFW 0
gap_end:            DEFW 0
yank_kind:          DEFB 0
yank_length:        DEFW 0
status_dirty:       DEFB 0
```

The case distinction (UPPER for compile-time, lower for runtime) is
the single rule that lets a reader instantly classify any reference.

### File Structure Patterns

**Every `.asm` and `.inc` file begins with a header block:**

```
; ============================================================
; Module: gapbuf.asm
; Purpose: Gap-buffer primitives. Owns the buffer's two-halves
;          invariant; all edits go through this module.
;
; Public:
;   gapbuf_init     - initialize empty buffer
;   gapbuf_insert   - insert byte at cursor
;   gapbuf_delete   - delete byte at cursor
;   gapbuf_move_gap - move gap to a target offset
;   gapbuf_load     - load file contents into buffer
;
; State owned (read/write):
;   gap_start, gap_end, cursor_offset
;
; Register conventions (across public entry points):
;   HL = cursor offset (caller may have it cached)
;   DE, BC = caller-saved working registers
;
; Dependencies:
;   inc/equates.inc  (GAP_BUFFER_BASE, GAP_BUFFER_MAX)
;   inc/state.inc    (gap_start, gap_end, cursor_offset)
;   src/statusln.asm (status_set_message on overflow)
; ============================================================
```

This header is the contract. Anyone modifying the module updates the
header. AI agents implementing or modifying any module read the
header first.

**Every public routine begins with a contract comment:**

```
; ----------------------------------------------------------------
; gapbuf_insert
; Insert byte A at cursor_offset. Moves the gap if needed.
;
; In:      A = byte to insert
; Out:     CF = 0 on success, CF = 1 on buffer-full
; Trashes: A, BC, DE, HL
; Calls:   gapbuf_move_gap (if gap not already at cursor),
;          status_set_message (on overflow)
; ----------------------------------------------------------------
gapbuf_insert:
```

`In:` / `Out:` / `Trashes:` / `Calls:` is the four-line standard.
Internal helpers may omit `Calls:` if trivial. Any non-RET-only exit
(e.g. tail-jumps to error) is documented.

**Section dividers within a file use `;;`:**

```
;; ============================================================
;; Initialization
;; ============================================================
```

This makes a `;;`-led line a visual jump point distinct from regular
`;` comments.

**Module include order in `vibe.asm`:**

The top-level `src/vibe.asm` includes modules in dependency order so
sjasmplus resolves all forward references on first pass and the
resulting binary layout is predictable for size auditing:

```
; Includes — dependency order, low to high
INCLUDE "../inc/equates.inc"
INCLUDE "../inc/bios.inc"
INCLUDE "../inc/bdos.inc"
INCLUDE "../inc/vt52.inc"
INCLUDE "../inc/modes.inc"
INCLUDE "../inc/state.inc"

ORG 0x0100
    JP main

; Code modules — order = link layout
INCLUDE "init.asm"
INCLUDE "input.asm"
INCLUDE "statusln.asm"     ; load early — depended on by everything
INCLUDE "gapbuf.asm"
INCLUDE "render.asm"
INCLUDE "dispatch.asm"
INCLUDE "parser.asm"
INCLUDE "motions.asm"
INCLUDE "edits.asm"
INCLUDE "visual.asm"
INCLUDE "search.asm"
INCLUDE "exline.asm"
INCLUDE "fileio.asm"
INCLUDE "undo.asm"
```

Reordering this section reorders the `.com` layout — by NFR18 the
file is the single source of truth for binary layout. Don't reorder
casually; any reorder is a deliberate decision that gets a commit
message.

### Format Patterns

**Instruction case — UPPERCASE mnemonics and UPPERCASE registers:**

```
LD A, (HL)          ; canonical
ADD HL, DE
JP NZ, .loop
```

Rationale: matches Zilog manuals, Sinclair/Spectrum ROM disassemblies,
and the dominant convention in vintage Z80 documentation. UPPERCASE
everywhere makes opcode lines visually distinct from named labels and
equates without mixing case within an instruction.

**Indentation — 4 spaces, never tabs.** sjasmplus is whitespace-
tolerant; the consistency exists for human readers. Operand columns
are not enforced — natural alignment, no tabular padding.

**Comments — `;` for line, `;;` for section dividers, no trailing
period.** Inline comments use a single space after `;`:

```
LD A, (mode_byte)   ; load current mode
CP MODE_NORMAL
JR Z, .normal
```

Inline comment column is not enforced; place where readable.

**String termination — null-terminated (`0x00`) by default.** Used
for status-line messages, error strings, and any inline literal.
Exception: the ex-command-line buffer and search-pattern buffer use
**length-prefixed** form (1 byte length + bytes), because they're
fixed-size buffers being parsed left-to-right and the length is
known up-front. Both conventions are documented at the buffer
declaration site.

```
msg_search_wrap:    DEFB "search wrapped", 0       ; null-term
msg_pattern_404:    DEFB "pattern not found", 0
ex_buffer:          DEFB 0                          ; length byte
                    DEFS EX_COMMAND_BUFFER          ; raw bytes
```

### Status-Line Message Format

All status-line messages share a format so the user reads them as a
consistent surface, not random module-author voice:

- **All lowercase.** No mid-sentence capitals, no proper nouns
  (filenames are user-provided and pass through untouched).
- **No trailing period.** Messages are status, not sentences.
- **Short — target under 30 characters.** Status line is 80 chars
  but real-world readability and right-edge filename interactions
  argue for tight messages.
- **Format conventions for common cases:**
  - I/O errors: `"can't write <filename>"`, `"can't open <filename>"`
  - Buffer-state: `"buffer modified"`, `"file too large"`
  - Search: `"pattern not found"`, `"search wrapped"`
  - Undo: `"undo not possible — too large"`, `"nothing to undo"`
  - Generic refusal: `"no write since last change"` (vi-canon match)

Messages live in a dedicated section near end-of-code (so size
audit can spot string-table growth):

```
;; ============================================================
;; Status-line message strings
;; ============================================================
msg_buffer_modified:    DEFB "buffer modified", 0
msg_file_too_large:     DEFB "file too large", 0
msg_pattern_not_found:  DEFB "pattern not found", 0
msg_search_wrapped:     DEFB "search wrapped", 0
msg_undo_too_large:     DEFB "undo not possible - too large", 0
msg_nothing_to_undo:    DEFB "nothing to undo", 0
msg_no_write:           DEFB "no write since last change", 0
```

Add new messages in this block, not inline within a module's code.

### Test Conventions

**Test file naming — `<module>_<scenario>.asm`, lowercase, hyphenated
scenario:**

```
test/cases/gapbuf_insert-empty.asm
test/cases/gapbuf_insert-fills-buffer.asm
test/cases/gapbuf_delete-at-bof.asm
test/cases/parser_count-then-motion.asm
test/cases/parser_doubled-operator.asm
test/cases/search_wrap-once.asm
test/cases/undo_capacity-refusal.asm
test/cases/fileio_load-with-1A.asm
test/cases/fileio_save-write-protect.asm
```

The pattern makes `make test` output self-describing.

**Test prologue/epilogue — fixed boilerplate via include:**

```
; test/inc/test_prologue.inc
    ORG 0x0100
test_start:
    XOR A
    LD (TEST_RESULT), A       ; 0xCFFE = pass
    LD (TEST_RESULT+1), A     ; 0xCFFF = context

; ... test body ...

; test/inc/test_epilogue.inc
test_pass:
    LD C, 0                   ; BDOS function 0 — exit
    JP 0x0005

test_fail:
    LD (TEST_RESULT), A       ; A = fail code
    LD (TEST_RESULT+1), B     ; B = optional context
    LD C, 0
    JP 0x0005

TEST_RESULT EQU 0xCFFE
```

Tests `INCLUDE` these fixtures so they all share exit conventions.

### Macro & Equate Discipline

**All compile-time knobs live in `inc/equates.inc`.** No magic
numbers in code. If you find yourself typing `LD A, 80` for the
screen width, stop and use `LD A, SCREEN_COLS`. (NFR16.)

**All BIOS / BDOS / VT52 magic addresses and codes live in their
respective `.inc` files.** Examples:

```
; inc/bios.inc
BIOS_CONIN     EQU 0xFA06   ; concrete addresses TBD per BIOS layout
BIOS_CONINST   EQU 0xFA09
BIOS_CONOUT    EQU 0xFA0C
BDOS_ENTRY     EQU 0x0005
DEFAULT_FCB    EQU 0x005C
DEFAULT_DMA    EQU 0x0080

; inc/bdos.inc
BDOS_CONOUT    EQU 2
BDOS_OPEN      EQU 15
BDOS_CLOSE     EQU 16
BDOS_DELETE    EQU 19
BDOS_READ_SEQ  EQU 20
BDOS_WRITE_SEQ EQU 21
BDOS_MAKE      EQU 22

; inc/vt52.inc
VT52_ESC          EQU 0x1B
VT52_CURSOR_HOME  EQU 'H'   ; ESC H
VT52_CLEAR_SCREEN EQU 'J'   ; ESC J
VT52_ERASE_TO_EOL EQU 'K'   ; ESC K
VT52_GOTO         EQU 'Y'   ; ESC Y row+0x20 col+0x20
```

Concrete addresses for `BIOS_CONIN/CONINST/CONOUT` come from the
MicroBeast BIOS jump table at runtime; the equates above are
placeholders to be filled when wiring up `init.asm`.

### Repository / Build Hygiene

**`.gitignore` — track source only, never artifacts:**

```
# .gitignore
*.com
*.lst
*.sld
*.bin
*.o
*.obj
build/
test/build/
.DS_Store
*.swp
*.tmp
```

**`README.md` is dev-loop-oriented, not user manual.** Sections:
prerequisites (sjasmplus 1.23.0, Make, iz-cpm), build commands,
test commands, transfer command, repo layout pointer to this
architecture doc. End-user documentation is a separate post-MVP
artifact.

**Commit messages — describe *why*, not *what*.** Standard
imperative-mood subject line, optional body for rationale. No
particular format conventions beyond that — small project, single
author.

### Enforcement Guidelines

**All implementers (AI or human) MUST:**

1. **Read this document and the PRD before touching any module.**
2. **Read the target module's header block before modifying it.**
3. **Update the module header when changing public symbols, owned
   state, or dependencies.**
4. **Use `BDOS_CALL` for every BDOS invocation. Raw `CALL 0x0005`
   is forbidden** (NFR8 enforcement; see MC6).
5. **Use `status_set_message` for every error path. Direct status-
   buffer writes from outside `statusln.asm` are forbidden** (MC5
   enforcement).
6. **Use named equates for all numeric literals that have semantic
   meaning** (NFR16). Loop counters and obvious values (0, 1, -1)
   excepted.
7. **Add a test in `test/cases/` for any subsystem-level change in
   the headlessly-testable layers** (gap buffer, parser, search,
   undo, file I/O).
8. **Keep cross-module state access mediated by the named symbols
   in `inc/state.inc`. No magic addresses in module code.**

**Pattern enforcement is by code review.** No tooling enforces these
on a Z80 asm project; the discipline is human (or LLM-mediated) and
the architecture doc is the contract.

### Pattern Examples

**Good — module header complete, contract documented, conventions
followed:**

```
; ============================================================
; Module: search.asm
; Purpose: Literal forward substring search; n repeats.
; Public:
;   search_prompt  - read pattern from /-line, then search
;   search_next    - n: re-search from cursor with last pattern
; State owned: search_pattern (length-prefixed buffer)
; Dependencies: gapbuf, statusln, exline
; ============================================================

;; ============================================================
;; Public entry points
;; ============================================================

; ----------------------------------------------------------------
; search_next
; Search forward from cursor for the most recent pattern.
;
; In:      (none)  — pattern is in search_pattern buffer
; Out:     CF = 0 if found (cursor moved), CF = 1 if not found
;          (cursor unchanged, status line set)
; Trashes: A, BC, DE, HL
; Calls:   gapbuf_*, status_set_message
; ----------------------------------------------------------------
search_next:
    LD A, (search_pattern)        ; pattern length
    OR A
    JR Z, .no_pattern
    ; ... actual search ...
.no_pattern:
    LD HL, msg_no_pattern
    CALL status_set_message
    SCF
    RET
```

**Anti-pattern — magic numbers, undocumented contract, raw BDOS:**

```
; BAD — DO NOT WRITE LIKE THIS
search_thing:
    LD C, 1                       ; what's 1?
    CALL 0x0005                   ; raw BDOS — forbidden
    LD A, (0xC4F0)                ; what address is this?
    CP 80                         ; what's 80?
    JR Z, somewhere
```

The bad version: missing module/routine header, magic numeric
operands, raw BDOS call (NFR8 violation), bare address (state.inc
violation), unscoped label name. All would fail review.

## Project Structure & Boundaries

### Complete Project Directory Structure

```
vibe/
├── Makefile                 # GNU Make: build, test, push, clean,
│                            # sizes (per-section budget audit)
├── README.md                # Dev-loop oriented (build, test, transfer,
│                            # link to architecture.md). Not user
│                            # documentation.
├── .gitignore               # *.com, *.lst, *.sld, build/, swap files
│
├── inc/                     # Shared headers (no executable code)
│   ├── equates.inc          # All compile-time knobs (NFR16):
│   │                        #   GAP_BUFFER_BASE, GAP_BUFFER_MAX,
│   │                        #   UNDO_BUFFER_SIZE, STATUS_LINE_WIDTH,
│   │                        #   EX_COMMAND_BUFFER, SEARCH_PATTERN_BUFFER,
│   │                        #   YANK_BUFFER_SIZE, SCREEN_ROWS,
│   │                        #   SCREEN_COLS, EDITABLE_ROWS,
│   │                        #   ESC_TIMEOUT_TICKS
│   ├── bios.inc             # MicroBeast BIOS jump-table addresses:
│   │                        #   BIOS_CONIN, BIOS_CONINST, BIOS_CONOUT,
│   │                        #   plus tick-counter address
│   ├── bdos.inc             # CP/M 2.2 BDOS function numbers + the
│   │                        #   BDOS_CALL checked-call macro (MC6).
│   │                        #   Only 2.2 functions used (NFR15).
│   ├── vt52.inc             # VT52 control codes: ESC, GOTO, CLEAR,
│   │                        #   ERASE_TO_EOL, etc.
│   ├── modes.inc            # MODE_NORMAL, MODE_INSERT, MODE_COMMAND,
│   │                        #   MODE_VISUAL, VIS_CHAR, VIS_LINE,
│   │                        #   VIS_BLOCK; plus synthesized keycodes
│   │                        #   KEY_ARROW_UP/DOWN/LEFT/RIGHT
│   │                        #   (0x80–0x83) for VT52 escape sequences
│   │                        #   (V1)
│   └── state.inc            # All cross-module variable declarations
│                            # (the static memory map — see below)
│
├── src/                     # Executable code, one module per concern
│   ├── vibe.asm             # ORG 0x0100 entry. Includes everything
│   │                        # in dependency order (link layout).
│   │                        # Owns: main loop.
│   ├── init.asm             # Cold-start: parse default FCB at 0x005C
│   │                        # for filename arg, init state, draw initial
│   │                        # screen. Teardown: restore terminal, return
│   │                        # to CCP via warm boot.
│   ├── input.asm            # input_get_key: BIOS_CONIN poll, Esc
│   │                        # disambiguation tick window (RI5).
│   ├── statusln.asm         # status_set_message (MC5 — single error
│   │                        # funnel), status-line render path, message
│   │                        # string table.
│   ├── gapbuf.asm           # Gap-buffer primitives. Owns gap_start,
│   │                        # gap_end, two-halves invariant. All edits
│   │                        # go through this module.
│   ├── render.asm           # Shadow buffer, dirty-row bitmap (RI1),
│   │                        # diff emit, ESC Y positioning, cursor
│   │                        # last-emit (RI4), Ctrl-L full redraw.
│   ├── dispatch.asm         # Per-mode key tables (MC3), shared
│   │                        # dispatch_key binary-search routine.
│   ├── parser.asm           # Count accumulator, pending-operator,
│   │                        # operator+motion composition (FR39, FR40).
│   ├── motions.asm          # h, j, k, l, w, b, 0, $, gg, G with count
│   │                        # support. Word-boundary classifier (BH1).
│   ├── edits.asm            # i, a, o, O, x, dd, dw, yy, p, cw, ~.
│   │                        # Records inverse ops to undo buffer.
│   ├── visual.asm           # Visual-mode entry/exit, anchor management
│   │                        # (SR5), block/line/char selection ops:
│   │                        # d, y, c, >, <, ~.
│   ├── search.asm           # search_prompt, search_next (FR41–FR44).
│   ├── exline.asm           # `:` command-line editing + dispatch.
│   │                        # `/` prompt also lives here (shared
│   │                        # input-line UI, dispatched separately).
│   ├── fileio.asm           # FCB-based load/save, drive-B-default
│   │                        # resolution, oversize refusal, EOF/0x1A
│   │                        # handling. All BDOS via BDOS_CALL macro.
│   └── undo.asm             # 256-byte single-level undo: record, replay,
│                            # capacity-refusal status.
│
├── test/                    # Headless test harness (driven by iz-cpm)
│   ├── README.md            # How to run; what's headless vs UAT
│   ├── Makefile             # Builds each cases/*.asm to .com,
│   │                        # invokes iz-cpm with timeout, reports
│   ├── inc/
│   │   ├── test_prologue.inc # Standard test entry boilerplate
│   │   └── test_epilogue.inc # test_pass / test_fail exit conventions
│   ├── cases/               # Per-subsystem .asm tests (TH2 naming)
│   │   ├── gapbuf_*.asm
│   │   ├── parser_*.asm
│   │   ├── search_*.asm
│   │   ├── undo_*.asm
│   │   └── fileio_*.asm
│   └── fixtures/            # iz-cpm B: drive contents (text files,
│                            # write-protected files, etc.)
│
├── build/                   # Generated, gitignored
│   ├── vibe.lst             # Listing — per-section size audit (NFR9; 5760 B ceiling)
│   └── vibe.sld             # Symbol/listing data for debugger
│
└── vibe.com                 # Final artifact (NFR11). Gitignored.
                             # `make push` transfers via SLIDE.
```

### Static Memory Map (`inc/state.inc`)

The single source of truth for all cross-module state addresses (MC7).
Every variable accessed by symbolic name; no inline addresses anywhere
in the source tree. Sizes total ~2 KB before the gap buffer; exact
layout is sjasmplus-determined and visible in `build/vibe.lst`.

```
;; --- Single-byte / small state ---
mode_byte:          DEFB 0     ; 1 byte: MODE_NORMAL et al.
visual_submode:     DEFB 0     ; 1 byte: VIS_CHAR / VIS_LINE / VIS_BLOCK
buffer_dirty:       DEFB 0     ; 1 byte: 0 = clean, nonzero = unsaved
pending_operator:   DEFB 0     ; 1 byte: 0 / 'd' / 'y' / 'c' / '>' /
                               ;          '<'  (parser state)
yank_kind:          DEFB 0     ; 1 byte: KIND_CHAR / KIND_LINE /
                               ;          KIND_BLOCK
status_dirty:       DEFB 0     ; 1 byte: status row needs redraw
pending_motion_prefix: DEFB 0  ; 1 byte: 0 / 'g' (V3: gg motion prefix)

;; --- 16-bit state ---
cursor_offset:      DEFW 0     ; 2 bytes: logical file-space offset
gap_start:          DEFW 0     ; 2 bytes: physical addr (first free byte)
gap_end:            DEFW 0     ; 2 bytes: physical addr (first occupied
                               ;          byte after gap)
visual_anchor:      DEFW 0     ; 2 bytes: logical offset of selection
                               ;          start
count_accumulator:  DEFW 0     ; 2 bytes: parser's pending count
yank_length:        DEFW 0     ; 2 bytes: bytes in yank register
top_line_offset:    DEFW 0     ; 2 bytes: buffer offset of first
                               ;          char of topmost editable
                               ;          row (V2: scroll anchor)

;; --- Buffers ---
status_buffer:      DEFS STATUS_LINE_WIDTH        ; 80 bytes
search_pattern:     DEFB 0                        ; 1 length byte
                    DEFS SEARCH_PATTERN_BUFFER    ; 64 bytes raw
ex_buffer:          DEFB 0                        ; 1 length byte
                    DEFS EX_COMMAND_BUFFER        ; 64 bytes raw
filename_buffer:    DEFS 16                       ; 8.3 + drive + null
shadow_buffer:      DEFS SCREEN_ROWS * SCREEN_COLS ; 1920 bytes
dirty_rows:         DEFS 3                        ; 24-bit bitmap
undo_buffer:        DEFS UNDO_BUFFER_SIZE         ; 256 bytes

;; --- BIOS-managed (read-only from VIBE) ---
; tick_counter is maintained by the MicroBeast 50Hz ISR; address
; declared in bios.inc, not here. Read via LD HL, (BIOS_TICK_ADDR).
```

**The yank register is *not* in `state.inc`.** SR6 places it in the
reserved pool at `GAP_BUFFER_BASE + GAP_BUFFER_MAX`, where the linker
positions it after the gap buffer:

```
yank_buffer  EQU  GAP_BUFFER_BASE + GAP_BUFFER_MAX  ; +1024 bytes here
```

This keeps `state.inc` to ~2 KB of small state and isolates the yank
register's bulk near the reserved-pool boundary, where future Growth-
tier additions (multi-level undo, marks, macros) will accrete.

### Module Dependency Graph

```
                      vibe.asm
                    (main loop)
                          │
                          ▼
                     input.asm ◄──── BIOS_CONIN/CONINST + tick
                          │
                          ▼
                    dispatch.asm
                          │
        ┌───────┬─────────┼──────────┬─────────┐
        ▼       ▼         ▼          ▼         ▼
   parser.asm  motions  edits     visual    exline.asm
                │       │ │ │       │           │
                │       │ │ │       │           ├──► search.asm
                │       │ │ │       │           ├──► fileio.asm ──► BDOS
                │       │ │ │       │           └──► statusln.asm
                │       │ │ │       │
                │       │ │ │       └─► gapbuf.asm
                │       │ │ └─────────► undo.asm  (records inverse ops)
                │       │ └───────────► gapbuf.asm
                │       └─────────────► gapbuf.asm
                ▼
          (state reads only — no calls)

    Every module ──► statusln.asm (status_set_message: error funnel)
    Every BDOS-using module ──► BDOS_CALL macro (bdos.inc) ──► BDOS
    Every screen byte ──► render.asm ──► BIOS_CONOUT
    render.asm ◄── statusln.asm (status row diff'd & emitted same way)
```

**Boundary properties:**

- `gapbuf.asm` is the single owner of buffer mutations. Motions,
  edits, visual, search, fileio all read; only edits/visual/fileio
  write — and only via `gapbuf_insert/delete/move_gap` entry points.
  **Documented carve-out:** `fileio.asm`'s file-load linear-fill phase
  writes `gap_start` directly to drop loaded bytes contiguously before
  the gap (Story 2.2); `gapbuf_move_gap(0)` restores the cursor-at-0
  invariant immediately after. One AR14 carve-out total.
- `statusln.asm` is the single error sink (MC5). No module emits to
  the status row directly; all error/info paths funnel through
  `status_set_message`.
- `render.asm` is the single screen-emission path. No other module
  calls `BIOS_CONOUT` directly. (Story 1.11 retired the init.asm
  initial-clear carve-out: `render_init` now emits the `ESC J`
  itself as the first step of cold-start, so `init.asm` no longer
  needs a CONOUT exception.)
- `bdos.inc`'s `BDOS_CALL` macro is the single BDOS gateway (MC6).
  Raw `CALL 0x0005` is forbidden by convention. **Documented carve-outs:**
  `fileio.asm` has three inline-BDOS sites that bypass the macro funnel
  because the funnel's terminal `JP input_loop` would skip required
  follow-up (cold-start completion in Story 2.3's launch open; the
  Story 2.4 save's benign 0xFF "no prior file" on DELETE; the Story
  2.4-fix R/O save-precheck SEARCH_FIRST). Three AR15 carve-outs total,
  all annotated in fileio.asm. `motions.asm` (Stories 2.5-2.6) is the
  first "clean module" archetype in `src/`: zero AR13 / AR14 / AR15
  carve-outs.
- `dispatch.asm` is the only module with knowledge of per-mode key
  tables; mode dispatch is invisible to handlers themselves.

### External Boundaries

The only external surfaces the architecture crosses are the platform
itself; there are no networks, services, or third-party APIs.

| Boundary | Surface | Direction | Module |
|---|---|---|---|
| Keyboard | `BIOS_CONIN` / `BIOS_CONINST` | read | `input.asm` |
| Screen | `BIOS_CONOUT` | write | `render.asm` |
| Filesystem | BDOS open/read/write/close (FCB) | read+write | `fileio.asm` |
| Tick (50Hz) | BIOS tick counter (memory address) | read | `input.asm` |
| Termination | BDOS function 0 (warm boot) | write | `init.asm`, `exline.asm` (`:q`) |

That's the entire surface. Any new external dependency (e.g. RTC,
sound) is post-MVP.

### Data Flow (Keystroke Lifecycle)

```
1. User presses key
   │
   ▼
2. BIOS keyboard ISR populates 1-byte ring
   │
   ▼
3. main loop → input_get_key:
   │  ├─ BIOS_CONIN reads first byte
   │  └─ if ESC: tick-poll up to ESC_TIMEOUT_TICKS for follow-up
   │
   ▼
4. dispatch_key:
   │  ├─ binary search current mode's key table
   │  └─ jump to handler (or per-mode unbound fall-through)
   │
   ▼
5. handler executes:
   │  ├─ may CALL gapbuf_* (which marks affected rows dirty)
   │  ├─ may CALL undo_record (for mutating ops)
   │  ├─ may CALL status_set_message
   │  └─ may update cursor_offset
   │
   ▼
6. main loop → render_diff:
   │  ├─ walk dirty_rows bitmap
   │  ├─ for each dirty row: cell-by-cell shadow compare
   │  ├─ emit ESC Y row col + chars per contiguous run
   │  ├─ emit status row separately if status_dirty
   │  ├─ update shadow_buffer
   │  ├─ clear dirty_rows
   │  └─ emit cursor position last (ESC Y for cursor_offset)
   │
   ▼
7. loop back to step 3 (blocking on next BIOS_CONIN)
```

Idle = no emission. No periodic timer-driven render. NFR1 satisfied
by step 6's diff-only emission; NFR3 satisfied because the entire
loop is bounded by gap-buffer cost (NFR9 budget governs constants).

### Functional Requirement → Module Mapping

| FR range | Category | Primary module | Supporting modules |
|---|---|---|---|
| FR1–FR3 | Editor lifecycle | `init.asm`, `vibe.asm` | `exline.asm` (`:q`) |
| FR4–FR8 | File operations | `fileio.asm` | `exline.asm` (parse), `gapbuf.asm`, `statusln.asm` |
| FR9 | Drive-B default | `fileio.asm` | — |
| FR10 | Drive-letter prefix | `fileio.asm` | — |
| FR11 | Oversize refusal | `fileio.asm` | `gapbuf.asm` (cap check), `statusln.asm` |
| FR12–FR16 | Mode transitions | `dispatch.asm` | per-mode tables |
| FR17 | Mode in status | `statusln.asm` | `dispatch.asm` (mode change hook) |
| FR18–FR22 | Cursor motions | `motions.asm` | `gapbuf.asm` (line scan) |
| FR23 | Counted motions | `parser.asm` | `motions.asm` (consumes count) |
| FR24–FR32 | Text editing | `edits.asm` | `gapbuf.asm`, `undo.asm`, yank reg |
| FR33–FR38 | Visual mode | `visual.asm` | `gapbuf.asm`, `undo.asm`, yank reg |
| FR39–FR40 | Operator+motion composition | `parser.asm` | `motions.asm`, `edits.asm` |
| FR41–FR44 | Search | `search.asm` | `exline.asm` (`/` prompt), `gapbuf.asm`, `statusln.asm` |
| FR45–FR46 | Undo | `undo.asm` | `edits.asm`, `visual.asm` (recorders), `statusln.asm` |
| FR47 | Diff render | `render.asm` | shadow + dirty bitmap |
| FR48 | Ctrl-L refresh | `render.asm` | dirty-bitmap sweep |
| FR49 | Status line | `statusln.asm` | `render.asm` |
| FR50 | Unsupported no-op | `dispatch.asm` | per-mode unbound handler, `statusln.asm` |
| FR51 | I/O failure surfacing | `fileio.asm` | `BDOS_CALL` macro, `statusln.asm` |
| FR52 | No silent data loss | `fileio.asm` | `buffer_dirty` flag |

### Non-Functional Requirement → Enforcement Location

| NFR | Concern | Where enforced |
|---|---|---|
| NFR1 | Incremental render | `render.asm` (diff-only emit) |
| NFR2 | Sustained typing | `input.asm` + `dispatch.asm` (no buffering, direct dispatch) |
| NFR3 | Cursor-motion latency | `motions.asm` (count-loop is the cap) |
| NFR4 | Esc 1–2 tick window | `input.asm` (RI5 routine) |
| NFR5 | No crashes | every module + `BDOS_CALL` macro + `status_set_message` funnel |
| NFR6 | No silent data loss | `fileio.asm` + `buffer_dirty` flag |
| NFR7 | Screen-state recoverable | `render.asm` Ctrl-L path |
| NFR8 | BDOS rc check | `bdos.inc` `BDOS_CALL` macro (MC6) |
| NFR9 | Code size | `Makefile` `sizes` target reads listing per-section |
| NFR10 | TPA fit | `vibe.asm` linker layout (final symbol < 0xD800) |
| NFR11 | Single .COM | `Makefile` output target |
| NFR12 | Static alloc only | absence of BDOS function 50/etc. |
| NFR13 | Single platform | `bios.inc` + `vt52.inc` encode platform |
| NFR14 | sjasmplus 1.23.0 | `Makefile` invocation + README |
| NFR15 | CP/M 2.2 BDOS only | `bdos.inc` lists exactly the 2.2 funcs |
| NFR16 | Knob centralization | `equates.inc` + `state.inc` (MC7) |
| NFR17 | Mode/operator decoupling | `dispatch.asm` tables ⊥ `parser.asm` |
| NFR18 | Reproducible build | `Makefile` sjasmplus flags (BA2) |

### Implementation Sequence (re-stated from step 4)

The architecture enforces a build order through dependency:

1. **Skeleton + build** — stub `.com` assembles cleanly via `make`.
2. **`equates.inc` + `state.inc` + `modes.inc`** — single source of
   truth for compile-time knobs and runtime addresses.
3. **`bios.inc` + `bdos.inc` + `vt52.inc`** — including the `BDOS_CALL`
   macro (MC6).
4. **`statusln.asm`** — even pre-render-pipeline, set up the message
   funnel so later modules can use it.
5. **`gapbuf.asm`** — testable headlessly via iz-cpm. PRD risk-rank-2
   demands tests ship with implementation.
6. **`input.asm`** — PRD risk-rank-1. Esc disambiguation is UAT-
   validated on real hardware before motions/edits depend on it.
7. **`dispatch.asm` + `parser.asm`** — depends on input.
8. **`render.asm`** — depends on shadow and gap buffer.
9. **`motions.asm` + `edits.asm` + `visual.asm` + `search.asm` +
   `exline.asm` + `undo.asm` + `fileio.asm`** — once 1–8 are solid,
   these are largely independent.
10. **End-to-end UAT loop on hardware.** PRD journeys 1a, 1b, 2.

## Architecture Validation Results

### Coherence Validation ✅ (with corrections applied)

**Decision Compatibility:**
All architectural decisions audited against each other for contract
alignment. Four coherence issues identified and resolved (see
"Validation Issues Addressed" below).

**Pattern Consistency:**
Naming conventions (UPPER_SNAKE for compile-time, lower for runtime,
`module_action` for public symbols, dotted-locals for internal),
file-header and routine-contract templates, and `BDOS_CALL` /
`status_set_message` funnels are mutually consistent and
collectively cover every cross-cutting concern from step 2.

**Structure Alignment:**
1:1 mapping between PRD-pinned subsystems and `src/*.asm` files;
state-block layout in `state.inc` matches every `SR*` decision;
module dependency graph contains no cycles; external boundaries
are exactly the four BIOS/BDOS surfaces — no unintended platform
dependencies.

### Requirements Coverage Validation ✅

**Functional Requirements:** All 52 FRs map to a primary module
plus supporting modules (step 6 FR↔module table). Spot-checks
confirm composition coverage (FR23, FR40), error paths (FR50–FR52),
and search semantics (FR41–FR44, with B1 correction below).

**Non-Functional Requirements:** All 18 NFRs map to a specific
enforcement location (step 6 NFR↔enforcement table). Reliability
NFRs (NFR5–NFR8) are concentrated in the `BDOS_CALL` macro,
`status_set_message` funnel, and `Ctrl-L` recovery path; performance
NFRs (NFR1–NFR4) in render's diff path and input's tick poll;
budget NFRs (NFR9–NFR12) verifiable via `make sizes`.

### Implementation Readiness Validation ✅ (with watchpoints)

**Decision Completeness:** Every load-bearing decision pinned —
state representation, calling conventions, dispatch shape, error
funnel, BDOS discipline, render dirty-tracking, esc-disambig
pattern, build flags, file/test layouts, source conventions.

**Structure Completeness:** Complete file tree with one-line
purpose per file; concrete state.inc memory map; module dependency
graph; FR/NFR mapping tables.

**Pattern Completeness:** Naming, file headers, routine contracts,
label scoping, instruction case, comment format, string
termination, status-message format, test naming, include ordering,
gitignore policy — all pinned with examples and a good/bad
contrast.

**Watchpoints (acceptable, not blocking):**

- **W1:** `bios.inc` jump-table addresses are placeholders. First
  implementation story (init.asm wiring) populates them from
  MicroBeast BIOS documentation.
- **W2:** Cursor row/col recompute on render costs O(visible-region)
  scan per frame, bounded by SR1 + the V2 `top_line_offset` addition
  to ~1920 byte reads worst-case. Sub-perceptible for any plausible
  file size. SR7 retains the post-MVP cache as a Growth-tier
  optimization if profiling ever shows it needed.

### Validation Issues Addressed

**V1 — Arrow-key encoding inconsistency (IMPORTANT, fixed
inline at RI5).** Input layer now synthesizes single-byte keycodes
(`KEY_ARROW_UP/DOWN/LEFT/RIGHT` = 0x80–0x83) for VT52 escape
sequences, so dispatch's binary-search contract holds. RI5 spec
updated; `inc/modes.inc` description amended to declare the keycode
equates.

**V2 — Scrolling mechanism (CRITICAL, fixed inline at state.inc).**
`top_line_offset` (2 bytes) added to the static memory map.
`render.asm` owns scroll behavior: before computing the diff, it
ensures cursor is within visible region (rows 0–22), advancing or
retreating `top_line_offset` by walking line breaks; on scroll, all
editable rows are marked dirty. SR7's cost note updated to reflect
that cursor row/col recompute is now bounded by visible-region size
rather than full-buffer size.

**V3 — `gg` as doubled motion (IMPORTANT, fixed inline at
state.inc).** `pending_motion_prefix` byte added to the static
memory map. Parser handles the `g` prefix as a separate state from
operator-pending: a second `g` completes `gg` (go to first line);
any other key clears the prefix and re-dispatches the cleared key
through normal mode. Future motion prefixes (e.g. `z` for scroll
commands, post-MVP) reuse this byte.

**V4 — `status_set_error` renamed to `status_set_message`
(NICE-TO-HAVE, fixed inline globally).** Same routine, honest name
— the same buffer carries informational notices ("search wrapped")
that aren't errors. All references (MC5, enforcement guidelines,
examples, FR/NFR mapping, module dependency graph, directory tree)
updated.

**B1 — Search start position (fixed inline at BH4).** BH4 corrected
to match PRD §Search: `n` re-searches from *one byte past* current
cursor, ensuring `n` advances even when sitting on a previous match.

**B2 — Undo scope for insert sessions (clarification).** Single-
level undo records at insert-mode-exit, not per keystroke. The
undo entry captures the entire insert session as one unit (mode-
entry cursor, mode-exit cursor, inserted-text). Applies to `i`,
`a`, `o`, `O`, `c`, `cw`, and visual `c`. When the session's
text exceeds `UNDO_BUFFER_SIZE` (256 B), the entry is marked
"too large" and `u` reports via existing capacity-refusal path.
This matches vi-canonical undo behavior: `u` after `o<text>Esc`
undoes the whole `o` session, not just the final `Esc`.

### Architecture Completeness Checklist

**Requirements Analysis**

- [x] Project context thoroughly analyzed
- [x] Scale and complexity assessed
- [x] Technical constraints identified
- [x] Cross-cutting concerns mapped

**Architectural Decisions**

- [x] Critical decisions documented with versions
- [x] Technology stack fully specified
- [x] Integration patterns defined
- [x] Performance considerations addressed

**Implementation Patterns**

- [x] Naming conventions established
- [x] Structure patterns defined
- [x] Communication patterns specified
- [x] Process patterns documented

**Project Structure**

- [x] Complete directory structure defined
- [x] Component boundaries established
- [x] Integration points mapped
- [x] Requirements to structure mapping complete

### Architecture Readiness Assessment

**Overall Status:** READY FOR IMPLEMENTATION (all 16 checklist items
satisfied; no critical gaps remain after V1–V4 / B1–B2 fixes
applied).

**Confidence Level:** High. The PRD pre-pinned most architectural
ground; this workflow's contribution was lifting those decisions
into AI-implementable form, mapping FRs/NFRs to specific
modules/enforcement locations, and resolving the four integration-
level coherence issues found in validation.

**Key Strengths:**

- Single-platform target eliminates portability ambiguity that
  often dominates architecture work.
- Pre-pinned PRD §Internal Architecture removes most decision-space
  before this workflow began.
- Sharp boundaries: one module owns buffer mutation, one owns
  status emission, one owns BDOS access, one owns screen
  emission. Cross-cutting concerns are funneled, not duplicated.
- ~1.8 KB code-budget headroom reclaimed via MC3's binary-search
  dispatch — meaningful slack against the ~3 KB tentative cap.
- Test harness (iz-cpm + sentinel-byte protocol) addresses both
  PRD risk-rank-1 (input/Esc timing — UAT'd separately on real
  hardware) and risk-rank-2 (gap buffer correctness — fully
  testable headlessly).

**Areas for Future Enhancement (Growth tier):**

- Line-position cache (SR7) — only if profiling shows render
  latency on large files.
- Multi-level undo, marks/jumps, macros, multi-buffer — reserved
  pool earmarked.
- VT100 output mode — flagged in PRD; meaningful redesign, not a
  flag.
- VideoBeast GPU integration — Vision tier.
- Capital-`W`/`B`/`E` (whitespace-only-separator) word motions.
- `:s/old/new/` search-and-replace.

### Implementation Handoff

**Implementer guidelines:**

- Read this document and the PRD before touching any module.
- Read the target module's header block before modifying it.
- Update the module header on any change to public symbols, owned
  state, or dependencies.
- All BDOS calls via `BDOS_CALL` macro. Raw `CALL 0x0005` is
  forbidden (NFR8).
- All error/info paths via `status_set_message` (MC5).
- All numeric literals with semantic meaning use named equates
  (NFR16).
- All cross-module state via symbols in `state.inc` (MC7).
- Add tests in `test/cases/` for any subsystem-level change in the
  headlessly-testable layers.

**First implementation priority:** Story 0 — Project skeleton.
Produce the directory tree from "Project Structure & Boundaries"
such that `make` succeeds with a stub `src/vibe.asm` (just `ORG
0x0100 + RET`) yielding a valid (~10-byte) `vibe.com`. Verify
byte-identical rebuild from clean tree (NFR18).

Subsequent stories follow the implementation sequence in step 4 /
step 6.
