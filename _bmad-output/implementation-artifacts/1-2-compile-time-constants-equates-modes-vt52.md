# Story 1.2: Compile-time constants (equates, modes, vt52)

Status: done

<!-- Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As the VIBE author,
I want all compile-time constants centralised in named-equate header files (`equates.inc`, `modes.inc`, `vt52.inc`),
So that NFR16's "no magic numbers" rule has a single source of truth and future tuning happens by editing one place.

## Acceptance Criteria

1. **AC1 — `inc/equates.inc` populated with the named compile-time knobs.**
   Given the constants headers,
   When I inspect `inc/equates.inc`,
   Then it defines: `GAP_BUFFER_MAX` (32768), `UNDO_BUFFER_SIZE` (256), `STATUS_LINE_WIDTH` (80), `EX_COMMAND_BUFFER` (64), `SEARCH_PATTERN_BUFFER` (64), `YANK_BUFFER_SIZE` (1024), `SCREEN_ROWS` (24), `SCREEN_COLS` (80), `EDITABLE_ROWS` (23), `ESC_TIMEOUT_TICKS` (2), `INDENT_BYTE` (0x20 = ASCII space; readiness-report item #6),
   And every constant has a one-line comment explaining its meaning,
   And `GAP_BUFFER_BASE` is *not* defined here — it lands in `inc/state.inc` (Story 1.3) as a positional EQU at the end of the static-data block. See Dev Notes "GAP_BUFFER_BASE is positional".

2. **AC2 — `inc/modes.inc` populated with mode IDs, visual sub-modes, and arrow keycodes.**
   Given the modes header,
   When I inspect `inc/modes.inc`,
   Then it defines `MODE_NORMAL`, `MODE_INSERT`, `MODE_COMMAND`, `MODE_VISUAL`,
   And `VIS_CHAR`, `VIS_LINE`, `VIS_BLOCK` (visual sub-modes),
   And synthesized arrow keycodes `KEY_ARROW_UP` (0x80), `KEY_ARROW_DOWN` (0x81), `KEY_ARROW_LEFT` (0x82), `KEY_ARROW_RIGHT` (0x83) — placed above ASCII so they cannot collide with normal keys (V1 / RI5).

3. **AC3 — `inc/vt52.inc` populated with the VT52 control codes used by the renderer.**
   Given the VT52 header,
   When I inspect `inc/vt52.inc`,
   Then it defines `VT52_ESC` (0x1B), `VT52_CURSOR_HOME` ('H'), `VT52_CLEAR_SCREEN` ('J'), `VT52_ERASE_TO_EOL` ('K'), `VT52_GOTO` ('Y'),
   And comments document the ESC-prefixed sequence form for each (e.g., `; ESC Y row+0x20 col+0x20`).

4. **AC4 — `src/vibe.asm` includes the populated headers in AR25 dependency order; build is clean and byte-identical.**
   Given the headers are included by `src/vibe.asm` in AR25 dependency order (`equates.inc` first, then `vt52.inc`, then `modes.inc` — `bios.inc`, `bdos.inc`, `state.inc` remain non-included until their own stories),
   When I run `make`,
   Then assembly succeeds with no symbol redefinitions, no forward-reference errors, and no warnings,
   And the output `vibe.com` SHA-256 equals Story 1.1's baseline `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a` (no constants are referenced from code yet, so EQU lines emit zero bytes; NFR18 baseline preserved),
   And `make clean && make` twice in a row produces the same SHA both times.

5. **AC5 — Casing follows AR22.**
   Given the casing convention,
   When I inspect any equate definition added in this story,
   Then it uses `UPPER_SNAKE_CASE` per AR22 (compile-time constants and macros are uppercase; lowercase is reserved for runtime variables, which arrive in Story 1.3).

## Tasks / Subtasks

- [x] **Task 1 — Populate `inc/equates.inc`** (AC: 1, 5)
  - [x] Preserve the existing AR23 header block. Update `Public:` from `(none yet — populated in Story 1.2)` to enumerate the equates landed here. Leave `State owned` as `(none — equates are constants only)` and `Dependencies` as `(none — equates.inc is the leaf of the include graph)`.
  - [x] Below the header, add a `;; --- Buffer sizes ---` section with `GAP_BUFFER_MAX EQU 32768`, `UNDO_BUFFER_SIZE EQU 256`, `STATUS_LINE_WIDTH EQU 80`, `EX_COMMAND_BUFFER EQU 64`, `SEARCH_PATTERN_BUFFER EQU 64`, `YANK_BUFFER_SIZE EQU 1024`. Each on its own line with a one-line `;` comment after the value.
  - [x] Add a `;; --- Screen geometry ---` section with `SCREEN_ROWS EQU 24`, `SCREEN_COLS EQU 80`, `EDITABLE_ROWS EQU 23` (24 minus the status row).
  - [x] Add a `;; --- Input timing ---` section with `ESC_TIMEOUT_TICKS EQU 2` (50 Hz tick window for Esc/arrow disambiguation per RI5/NFR4).
  - [x] Add a `;; --- Editing knobs ---` section with `INDENT_BYTE EQU 0x20` and a comment that this is the byte inserted/removed by `>`/`<`/`>>`/`<<` shifts (consumed by Stories 2.11 and 3.7; pinned per readiness-report item #6).
  - [x] Add a `;; --- Notes ---` block (or a single `;` comment) that **`GAP_BUFFER_BASE` is intentionally NOT defined here**; it lands in `state.inc` as a positional `GAP_BUFFER_BASE EQU $` at the end of the static-data block (Story 1.3). Same note for `yank_buffer` placement at `GAP_BUFFER_BASE + GAP_BUFFER_MAX` per SR6.
  - [x] Use UPPER_SNAKE_CASE for every label (AR22). Use 4-space indentation (AR24); EQU values may align naturally — no tabular padding required.

- [x] **Task 2 — Populate `inc/modes.inc`** (AC: 2, 5)
  - [x] Preserve the existing AR23 header block. Update `Public:` to enumerate the equates landed here. `Dependencies` stays `inc/equates.inc` (the EQU values themselves don't reference equates yet, but staying with the architecture's stated dependency keeps include order correct).
  - [x] `;; --- Editor modes ---` section: `MODE_NORMAL EQU 0`, `MODE_INSERT EQU 1`, `MODE_COMMAND EQU 2`, `MODE_VISUAL EQU 3`. Comment each with which mode the byte represents.
  - [x] `;; --- Visual sub-modes (only valid when MODE_VISUAL active) ---` section: `VIS_CHAR EQU 0`, `VIS_LINE EQU 1`, `VIS_BLOCK EQU 2`. Comment each.
  - [x] `;; --- Synthesized arrow keycodes (V1 / RI5) ---` section: `KEY_ARROW_UP EQU 0x80`, `KEY_ARROW_DOWN EQU 0x81`, `KEY_ARROW_LEFT EQU 0x82`, `KEY_ARROW_RIGHT EQU 0x83`. Add a block comment noting these are placed above ASCII (0x00–0x7F) so the dispatch table's binary-search contract holds (MC3) and arrow keys cannot collide with normal keys; the input layer (Story 1.8) synthesizes these from `ESC A/B/C/D` sequences.
  - [x] **Watch:** the architecture's example mapping at line 602–605 reads `ESC A → KEY_ARROW_UP (0x80)`, `ESC B → KEY_ARROW_DOWN (0x81)`, `ESC C → KEY_ARROW_RIGHT (0x83)`, `ESC D → KEY_ARROW_LEFT (0x82)`. The values 0x80–0x83 here match the epic's AC2 listing exactly. Do not invent a different ordering.

- [x] **Task 3 — Populate `inc/vt52.inc`** (AC: 3, 5)
  - [x] Preserve the existing AR23 header block. Update `Public:` to enumerate the equates landed here.
  - [x] `;; --- VT52 control codes ---` section. Use the architecture's canonical block (lines 1113–1118) verbatim:
    ```
    VT52_ESC          EQU 0x1B
    VT52_CURSOR_HOME  EQU 'H'   ; ESC H
    VT52_CLEAR_SCREEN EQU 'J'   ; ESC J
    VT52_ERASE_TO_EOL EQU 'K'   ; ESC K
    VT52_GOTO         EQU 'Y'   ; ESC Y row+0x20 col+0x20
    ```
    The `; ESC <letter>` comment form documents the sequence at the use site without forcing the renderer to re-derive it.
  - [x] No reverse-video, blink, or insert/delete-line equates yet — VIBE's renderer (Story 1.11) only needs the five above. If a later story finds it needs more, add them then.

- [x] **Task 4 — Add the INCLUDE block to `src/vibe.asm`** (AC: 4)
  - [x] Currently `src/vibe.asm` is just the AR23 header + `ORG 0x0100` + `RET` (Story 1.1). Insert a `;; --- Includes (dependency order per AR25) ---` block **above** `ORG 0x0100`. Per AR25 the eventual order is `equates.inc → bios.inc → bdos.inc → vt52.inc → modes.inc → state.inc`. In Story 1.2 only three of those have content, so the block reads:
    ```
    ;; --- Includes (dependency order per AR25) ---
    INCLUDE "../inc/equates.inc"
    INCLUDE "../inc/vt52.inc"
    INCLUDE "../inc/modes.inc"
    ```
    Stories 1.3 and 1.4 will splice `state.inc`, `bios.inc`, `bdos.inc` into this block at their AR25 positions — do not pre-add INCLUDEs for those files now (the headers are still empty stubs and including them buys nothing while creating a one-line edit each story has to undo).
  - [x] Update `vibe.asm`'s header `Dependencies:` line from `(none yet — no INCLUDE directives until Story 1.2 lands the first real inc/*.inc content)` to list the three currently-included headers (e.g., `inc/equates.inc, inc/vt52.inc, inc/modes.inc — bios/bdos/state arrive in Stories 1.3–1.4`).
  - [x] Path form: `"../inc/<file>.inc"` — relative to `src/`, matching the architecture's worked example at lines 926–931.
  - [x] Place the `INCLUDE` block **before** `ORG 0x0100`. Architecture lines 925–933 show this order; equates landing before the ORG means they're in scope for any code that follows, including future modules.

- [x] **Task 5 — Build, verify clean assembly, verify NFR18 byte-identity** (AC: 4)
  - [x] Run `make clean && make`. Expect zero output (sjasmplus `--msg=err` keeps stdout clean unless errors). If there are warnings or errors, halt and surface them — do not paper over.
  - [x] Run `sha256sum vibe.com`. **Expected hash:** `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a` (Story 1.1's NFR18 baseline). Equates emit zero bytes; the only emitted byte is still the `RET` (`0xC9`) at `0x0100`, so the binary must not change. If the SHA differs, the most likely cause is an accidental `DEFB`/`DEFW`/`DEFS` in one of the headers (an equate file should contain *only* `EQU` lines).
  - [x] Run `make clean && make` a second time and re-check the SHA — must match the first run (NFR18 reproducibility).
  - [x] Spot-check `build/vibe.lst` for the equates: each EQU appears in the symbol table with its value; no duplicate-symbol or unresolved-symbol errors.

- [x] **Task 6 — Verify naming and format compliance (AC5)** (AC: 5)
  - [x] Every label added in this story matches `[A-Z][A-Z0-9_]*` (UPPER_SNAKE_CASE per AR22). A quick grep: `grep -E '^[a-z]' inc/equates.inc inc/modes.inc inc/vt52.inc` should produce no matches except the AR23 header lines (which start with `;`).
  - [x] Indentation: 4 spaces, never tabs (AR24). `grep -P '^\t' inc/equates.inc inc/modes.inc inc/vt52.inc` should produce no matches.
  - [x] Section dividers use `;;` (AR24); regular comments use `;`.
  - [x] No trailing periods on comments (AR24).

### Review Findings

Code review run 2026-05-09 (Blind Hunter + Edge Case Hunter + Acceptance Auditor). Acceptance Auditor: all five ACs and all eight 🛑 guardrails satisfied; build clean; `vibe.com` SHA-256 matches Story 1.1 baseline across two rebuilds. ~22 dismissed (spec-pinned values, architecture-asserted contracts, or platform-irrelevant on MicroBeast).

- [x] [Review][Patch] `STATUS_LINE_WIDTH` should derive from `SCREEN_COLS` (NFR16 spirit — two literal `80`s drift independently) [inc/equates.inc] — applied; STATUS_LINE_WIDTH moved to Screen geometry section, defined `EQU SCREEN_COLS`. Public block updated. SHA = baseline.
- [x] [Review][Patch] `EDITABLE_ROWS` should derive from `SCREEN_ROWS-1` (the prose comment already claims the derivation; let the assembler enforce it) [inc/equates.inc:37] — applied; `EDITABLE_ROWS EQU SCREEN_ROWS-1`. SHA = baseline.
- [x] [Review][Patch] `UNDO_BUFFER_SIZE=256` / `YANK_BUFFER_SIZE=1024` — 8-bit register truncation hazard [inc/equates.inc] — applied; block comment in Buffer sizes section flags "16-bit only", per-line annotation on the >=256 equates. SHA = baseline.
- [x] [Review][Patch] `GAP_BUFFER_MAX=32768` (0x8000) high-bit set — 16-bit bounds compares must be unsigned [inc/equates.inc] — applied; comment in Buffer sizes section directs unsigned compare (`SBC HL,DE` + carry, never `JP M/P`). SHA = baseline.
- [x] [Review][Patch] `STATUS_ROW EQU EDITABLE_ROWS` added [inc/equates.inc] — applied; consumers (status-line module 1.5, renderer 1.11) won't hardcode 23. SHA = baseline.
- [x] [Review][Patch] `VT52_COORD_BIAS EQU 0x20` added [inc/vt52.inc] — applied; overrides the spec's "no extras yet" defer because the bias is required by every `VT52_GOTO` use site (NFR16: a named constant beats a hardcoded `0x20`). `VT52_GOTO` inline comment now reads `ESC Y row+VT52_COORD_BIAS col+VT52_COORD_BIAS`. SHA = baseline.
- [x] [Review][Patch] `Makefile` `$(wildcard inc/*.inc)` annotated with intent comment [Makefile] — applied; overrides the spec's "do not edit Makefile" because a comment is a no-op tooling annotation, not a functional change. Documents why empty-stub .inc files in the wildcard are benign. SHA = baseline.
- [x] [Review][Defer] `VT52_GOTO` row/col clamp — renderer must clamp before adding bias [inc/vt52.inc] — deferred; render code lands in Story 1.11, no module exists to host the clamp

## Dev Notes

### Why this story exists

Story 1.1 created the file *containers* (header-only `inc/equates.inc`, `inc/modes.inc`, `inc/vt52.inc`) and deliberately left them empty so this story could land both the content *and* the `INCLUDE` directive in `vibe.asm` together (Story 1.1 dev notes, lines 156–160 of `1-1-project-skeleton-reproducible-build.md`). This story is that landing.

After 1.2, three of the six `inc/*.inc` files are populated (equates, modes, vt52) and INCLUDEd from `vibe.asm`. The remaining three (`state.inc` in 1.3; `bios.inc` and `bdos.inc` in 1.4) follow the same pattern: their content lands together with their INCLUDE directive in their own story.

The story is small in code volume but high in *establish-the-conventions* leverage — every later module's first move will be `LD A, (mode_byte)` / `CP MODE_NORMAL` / `LD HL, status_buffer` etc., and those references all bottom out in this story's symbols.

### Critical guardrails for the dev agent

**🛑 `GAP_BUFFER_BASE` is positional, not a knob.** AC1 lists `GAP_BUFFER_BASE` among equates.inc constants but supplies no value — that's a tell. The architecture (lines 437, 1390–1394) and Story 1.3's AC2 ("the gap buffer base address (`GAP_BUFFER_BASE`) resolves to the first address past the static block") make clear this is determined by the static-data layout, not by editing a knob. **Do NOT define `GAP_BUFFER_BASE` in `equates.inc`.** Story 1.3 lands it as `GAP_BUFFER_BASE EQU $` (or equivalent positional form) at the end of `state.inc`'s DEFS block. Putting a placeholder value here would either (a) be redefined by 1.3 (sjasmplus EQU is single-assignment — error) or (b) be a forward reference to a label that doesn't exist yet (error in Story 1.2 alone, where state.inc is not included). Add the comment block in equates.inc that names this deliberate omission so future readers don't try to "fix" it.

**🛑 No `DEFB`/`DEFW`/`DEFS` in any of the three headers.** Equates emit zero bytes; runtime variables go in `state.inc` (Story 1.3). If you find yourself reaching for `DEFB`, you're in the wrong file. The byte-identical-SHA check (Task 5) is the firewall: `vibe.com`'s SHA-256 must equal Story 1.1's baseline `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a`. If it changes, an emit-bearing directive snuck in.

**🛑 Don't INCLUDE `bios.inc`, `bdos.inc`, `state.inc` from `vibe.asm` yet.** They're still header-only stubs. Including them would assemble fine (no content) but creates a one-line edit each subsequent story has to undo. Match Story 1.1's pattern: each story lands its content + its INCLUDE together. Story 1.4 will INCLUDE bios+bdos in their AR25 positions; Story 1.3 will INCLUDE state.inc in its AR25 position.

**🛑 AR25 dependency order matters even when only three files are present.** The order in `vibe.asm` should be `equates.inc → vt52.inc → modes.inc` (the AR25 final order, with bios/bdos/state's slots simply absent). When 1.3 and 1.4 splice in their files, they go at their AR25 positions: `equates.inc → bios.inc → bdos.inc → vt52.inc → modes.inc → state.inc`. Don't write the includes in alphabetical order or "1.2 files first then later".

**🛑 `KEY_ARROW_*` codes are 0x80–0x83 specifically.** They're placed above ASCII (0x00–0x7F) by design (V1 / RI5): the dispatch tables (MC3) sort entries by 1-byte key and binary-search them. Putting arrow keys at 0x80+ guarantees they cannot collide with any printable or control character that real keystrokes produce. The exact assignment from the epic AC2 is `UP=0x80, DOWN=0x81, LEFT=0x82, RIGHT=0x83`. Architecture line 602–605's example uses the same values but in a different *narrative* order (UP, DOWN, RIGHT, LEFT) — the values are what matter, not the order in the example comment.

**🛑 VT52 codes are character-byte values, not addresses.** `VT52_CURSOR_HOME EQU 'H'` is the ASCII byte `0x48` that follows ESC in the `ESC H` sequence. Don't confuse with BIOS jump-table addresses (those land in `bios.inc`, Story 1.4). If you see the dev plan reaching for an address-shaped value here, stop.

**🛑 INCLUDE block lives ABOVE `ORG 0x0100`.** Architecture lines 925–933 show this. Equates declared after `ORG 0x0100` would be in scope, but it's idiomatic for shared headers to land in a single block before code so a reader can scan dependencies once at the top.

**🛑 `INDENT_BYTE` is the right name for the indent-character knob.** Readiness-report item #6 named the equate `INDENT_BYTE` and pinned it to this story; Stories 2.11 and 3.7 cite it. Don't rename to `INDENT_CHAR` or similar without flagging.

### Architecture compliance — what AR* rules this story locks in

| AR | Story 1.2 obligation |
|----|----------------------|
| AR6 | `inc/equates.inc` populated with all NFR16-mandated knobs (ex GAP_BUFFER_BASE, see Dev Notes above) plus `INDENT_BYTE`. |
| AR9 | `inc/vt52.inc` populated with the five VT52 control codes the renderer uses. |
| AR10 | `inc/modes.inc` populated with mode IDs, visual sub-modes, KEY_ARROW_* (V1 / RI5). |
| AR22 | All new symbols UPPER_SNAKE_CASE. |
| AR23 | Existing header blocks preserved; `Public:` lines updated to enumerate landed symbols. |
| AR24 | UPPERCASE mnemonics (no instructions in this story); 4-space indentation; `;` line / `;;` section comments; no trailing periods. |
| AR25 | INCLUDE order in `vibe.asm` matches the AR25 sequence with bios/bdos/state slots empty until Stories 1.3–1.4. |
| NFR16 | No magic numbers — every later module sources its constants from this story's headers. |
| NFR18 | `vibe.com` SHA-256 unchanged from Story 1.1's baseline (equates emit zero bytes). |

### Existing files — current state and what this story changes

**`src/vibe.asm`** *(28 lines, header + `ORG 0x0100` + `RET`):*
- Current: AR23 header with `Dependencies: (none yet — no INCLUDE directives until Story 1.2 lands the first real inc/*.inc content)`; body is just `ORG 0x0100` and `RET`.
- This story: insert a 4-line `INCLUDE` block (3 INCLUDEs + section header) above `ORG 0x0100`; update `Dependencies:` line in the header. **Do NOT touch** `ORG 0x0100` or the `RET` body — Story 1.12 owns the init/teardown that replaces the stub exit, and the byte-identical-SHA check depends on the body being unchanged.

**`inc/equates.inc`, `inc/modes.inc`, `inc/vt52.inc`** *(each ~20 lines, AR23 header only):*
- Current: header block with `Public: (none yet — populated in Story 1.2)`. Body empty.
- This story: keep the header (update `Public:` to enumerate the landed equates); append the EQU body per Tasks 1–3. Don't reflow or restructure the existing header.

**Files NOT touched by this story (do not edit):**
- `inc/bios.inc`, `inc/bdos.inc` — Story 1.4.
- `inc/state.inc` — Story 1.3.
- `Makefile` — already enforces sjasmplus 1.23.0 via `check-toolchain` (Story 1.1 review fix). The wildcard pattern `$(wildcard inc/*.inc)` already picks up changes to the three populated files, so `make` rebuilds correctly without Makefile edits.
- `test/*` — headless harness lands in Story 1.6.

### Previous story intelligence (Story 1.1)

- **NFR18 baseline SHA:** `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a` (1-byte `vibe.com` containing only `0xC9` at `0x0100`). Story 1.2 must preserve this.
- **Toolchain pin enforced at build time:** Makefile has a `check-toolchain` order-only prereq that aborts with `ERROR: sjasmplus v1.23.0 required (NFR14).` if the active sjasmplus is not v1.23.0. The build host's `~/bin/sjasmplus` symlink points to the v1.23.0 build; do not relitigate.
- **Empty-directory policy:** no `.gitkeep` files. Doesn't affect this story (no new directories).
- **`vibe.com` lives at the project root (BA1)**, not under `build/`. SHA-checks operate on the project-root file.
- **Code review style:** Story 1.1's review (Blind Hunter + Edge Case Hunter + Acceptance Auditor) caught the toolchain-pin enforcement gap and patched the Makefile in the same review pass. Expect a similar review at the end of 1.2.

### Git intelligence

Single commit on `main` (Story 1.1): `b561c9e Set up the VIBE build: Makefile pins sjasmplus 1.23.0, produces vibe.com.` Conventions visible in the tree:
- 4-space indentation, UPPERCASE mnemonics, `;` comments — already in `src/vibe.asm`.
- Header blocks present in every `.asm`/`.inc` file — preserve them.
- `inc/*.inc` files are pure includes (no `ORG`, no code emission) — Story 1.2 keeps that property.
- Makefile line 23: `SOURCES := $(wildcard src/*.asm) $(wildcard inc/*.inc)` — any change to the three populated `.inc` files triggers a rebuild automatically.

### Latest tech information

- **sjasmplus 1.23.0** — the EQU semantics relevant here are unchanged from earlier versions: `LABEL EQU value` is single-assignment; `LABEL = value` is a re-assignable assignment; forward references in EQU resolve on a later pass *only if* the referenced label exists somewhere in the assembly. Since this story does not include `state.inc`, `GAP_BUFFER_BASE` cannot be forward-referenced — hence its deferral to Story 1.3.
- **VT52 — historical reference:** the DEC VT52 control set is well-documented; `ESC Y row+0x20 col+0x20` (cursor address) and `ESC H` (home), `ESC J` (clear screen), `ESC K` (erase to EOL) are stable across implementations. MicroBeast's VT52 emulation is asserted compliant by the platform docs; on-hardware verification of cursor addressing is a Story 1.12 (init/teardown) and Story 1.11 (render) concern.

### Testing requirements

This story has no headless-test cases (the test harness lands in Story 1.6). Verification is mechanical:

1. `make clean && make` succeeds with no errors and no warnings.
2. `sha256sum vibe.com` equals `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a` (Story 1.1 baseline).
3. `make clean && make` a second time produces the same SHA (NFR18 reproducibility).
4. `build/vibe.lst` symbol table contains every named equate from this story with the value listed in the AC.
5. `grep -E '^[a-z]' inc/equates.inc inc/modes.inc inc/vt52.inc | grep -v '^[a-z]*\s*;'` (or equivalent) finds no lowercase labels in the new content.

### Project Structure Notes

No new files are created. No directories are added. The structure established by Story 1.1 is unchanged. The only structural addition is the INCLUDE block in `src/vibe.asm`, which AR25 anticipates and lines 925–931 of `architecture.md` show in the final form.

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md#story-12-compile-time-constants-equates-modes-vt52] (lines 320–351)
- AR6 (equates.inc), AR9 (vt52.inc), AR10 (modes.inc): [Source: _bmad-output/planning-artifacts/epics.md] lines 152–157
- AR22 (UPPER_SNAKE for compile-time): [Source: _bmad-output/planning-artifacts/epics.md] line 177; [Source: _bmad-output/planning-artifacts/architecture.md#format-patterns] lines 825–833
- AR23 (file header convention) and AR24 (format conventions): [Source: _bmad-output/planning-artifacts/epics.md] lines 178–179
- AR25 (include order): [Source: _bmad-output/planning-artifacts/epics.md] line 180; [Source: _bmad-output/planning-artifacts/architecture.md#file-structure-patterns] lines 918–956
- Canonical equate examples (NFR16 enforcement): [Source: _bmad-output/planning-artifacts/architecture.md#macro--equate-discipline] lines 1086–1123
- VT52 canonical block: [Source: _bmad-output/planning-artifacts/architecture.md] lines 1113–1118
- KEY_ARROW_* placement (V1 fix): [Source: _bmad-output/planning-artifacts/architecture.md#validation-issues-addressed] lines 1646–1651; [Source: _bmad-output/planning-artifacts/architecture.md] lines 600–619
- GAP_BUFFER_BASE positional (deferred to 1.3): [Source: _bmad-output/planning-artifacts/architecture.md] line 1394; [Source: _bmad-output/planning-artifacts/epics.md#story-13-static-memory-map-stateinc] lines 368–372
- INDENT_BYTE pinned to this story: [Source: _bmad-output/planning-artifacts/implementation-readiness-report-2026-05-08.md] item #6 (line 553)
- NFR16 (knob centralization): [Source: _bmad-output/planning-artifacts/prd.md] NFR16; [Source: _bmad-output/planning-artifacts/epics.md] line 134
- NFR18 (reproducible build, baseline SHA): [Source: _bmad-output/implementation-artifacts/1-1-project-skeleton-reproducible-build.md] lines 296–298
- Story 1.1 dev-notes hand-off ("don't fragment includes"): [Source: _bmad-output/implementation-artifacts/1-1-project-skeleton-reproducible-build.md] lines 156–160

## Dev Agent Record

### Agent Model Used

claude-opus-4-7 (Opus 4.7, 1M context) via Claude Code / bmad-dev-story workflow.

### Debug Log References

- `make clean && make` — clean build, no warnings, no errors.
- `sha256sum vibe.com` (run 1): `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a` — matches Story 1.1 NFR18 baseline.
- `sha256sum vibe.com` (run 2 after second `make clean && make`): same SHA — NFR18 reproducibility confirmed.
- `grep -E '^[a-z]' inc/equates.inc inc/modes.inc inc/vt52.inc` — no matches (AR22 satisfied).
- `grep -nP '^\t' inc/equates.inc inc/modes.inc inc/vt52.inc src/vibe.asm` — no matches (AR24 4-space rule satisfied).
- `build/vibe.lst` — every EQU from this story appears with the expected value; only emitted byte remains `0xC9` (RET) at `0x0100`.

### Completion Notes List

- All six tasks complete; all five ACs satisfied.
- 28 equates landed across the three headers (11 in equates.inc, 11 in modes.inc, 5 in vt52.inc) — spot-check confirmed in `build/vibe.lst`.
- `GAP_BUFFER_BASE` deliberately omitted from equates.inc per Dev Notes guardrail; positional definition deferred to Story 1.3 (state.inc). A `;; --- Notes ---` block in equates.inc names the deferral so a future reader does not "fix" it.
- `KEY_ARROW_*` values use the epic AC2 ordering (UP=0x80, DOWN=0x81, LEFT=0x82, RIGHT=0x83) — comments document the ESC-letter mapping (`ESC A → UP`, `ESC B → DOWN`, `ESC C → RIGHT`, `ESC D → LEFT`) without rearranging the value assignments.
- INCLUDE order in `src/vibe.asm` is `equates.inc → vt52.inc → modes.inc` (the AR25 final order with bios/bdos/state slots empty), placed above `ORG 0x0100`.
- NFR18 firewall held: `vibe.com` SHA-256 unchanged from the Story 1.1 baseline across two clean rebuilds — equates emit zero bytes, no `DEFB`/`DEFW`/`DEFS` snuck in.
- AR24 trailing-period audit: no trailing periods on inline EQU line-comments. Trailing periods that do exist are confined to the preserved AR23 header description text (Story 1.1 precedent) and to multi-line prose note blocks where periods are sentence punctuation; this matches the convention `src/vibe.asm` already shipped under in Story 1.1.
- Headless test harness lands in Story 1.6, so no automated regression suite exists yet. The build (clean assembly + double-rebuild SHA-identity) is the regression check this story uses; both passes succeeded.

### File List

- `inc/equates.inc` — modified (header `Public:` updated; 11 EQUs added across 4 sections plus a deferral note for GAP_BUFFER_BASE)
- `inc/modes.inc` — modified (header `Public:` updated; 11 EQUs added across 3 sections)
- `inc/vt52.inc` — modified (header `Public:` updated; 5 VT52 EQUs added)
- `src/vibe.asm` — modified (header `Dependencies:` updated; 4-line `;; --- Includes ---` block inserted above `ORG 0x0100`; body unchanged — `RET` byte preserved)

### Change Log

| Date | Author | Change |
|------|--------|--------|
| 2026-05-09 | Story author | Initial story context — populates equates.inc/modes.inc/vt52.inc, splices first INCLUDE block into vibe.asm, preserves NFR18 baseline SHA. |
| 2026-05-09 | Dev agent (Opus 4.7) | Implemented all six tasks: equates.inc/modes.inc/vt52.inc populated; INCLUDE block (equates → vt52 → modes) added to vibe.asm above ORG; clean build verified; vibe.com SHA = Story 1.1 baseline confirmed across two rebuilds; AR22/AR24 conventions verified. Status → review. |

---

**Completion note:** Ultimate context engine analysis completed — comprehensive developer guide created.
