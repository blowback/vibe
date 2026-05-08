# Story 1.1: Project skeleton & reproducible build

Status: done

<!-- Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As the VIBE author,
I want a project skeleton that assembles cleanly under sjasmplus 1.23.0 with a reproducible build,
So that every subsequent module has a working build target and NFR18's byte-identical-rebuild floor is established from day one.

## Acceptance Criteria

1. **AC1 — Clean checkout produces vibe.com at project root.**
   Given a clean checkout of the repo,
   When `make` is run,
   Then sjasmplus 1.23.0 assembles `src/vibe.asm` and produces `vibe.com` in the project root,
   And the .com file's first byte sits at `ORG 0x0100` (verifiable in `build/vibe.lst`).

2. **AC2 — Skeleton matches the architecture's directory tree.**
   Given the skeleton is committed,
   When the repo is inspected,
   Then `src/vibe.asm` contains `ORG 0x0100` followed by a minimal stub (RET to warm-boot vector at `0x0000` is acceptable per Architecture line 1781),
   And the directory tree matches Architecture §"Complete Project Directory Structure": `src/`, `inc/`, `test/`, `build/`, top-level `Makefile`, `README.md`, `.gitignore`,
   And `inc/` contains placeholder files for `equates.inc`, `bios.inc`, `bdos.inc`, `vt52.inc`, `modes.inc`, `state.inc` (empty or minimal — populated in subsequent stories).

3. **AC3 — Build is byte-identical from a clean tree (NFR18 baseline).**
   Given `vibe.com` has been built,
   When `make clean && make` is run from the same checkout twice,
   Then both `vibe.com` outputs have the same SHA-256 hash,
   And no `--date` or host-path-embedding flags appear in the sjasmplus invocation.

4. **AC4 — Makefile targets and sjasmplus invocation match the architecture.**
   Given the Makefile exists,
   When its targets are inspected,
   Then at minimum `all` (default → `vibe.com`), `clean`, and a stub `test` target are defined,
   And sjasmplus is invoked exactly as `sjasmplus --nologo --msg=err --raw=vibe.com --lst=build/vibe.lst --sld=build/vibe.sld src/vibe.asm` (BA2).

5. **AC5 — `.gitignore` excludes all build artifacts.**
   Given `.gitignore` is in place,
   When `git status` is run after `make`,
   Then `vibe.com`, `build/`, `*.lst`, `*.sld`, `*.bin`, swap files are excluded,
   And only source files appear as tracked / untracked-source.

6. **AC6 — README is dev-loop-oriented.**
   Given `README.md` exists,
   When it is opened,
   Then it documents prerequisites (sjasmplus 1.23.0, Make, iz-cpm), build commands (`make`, `make test`), transfer command (`make push`), and links to `architecture.md`,
   And it explicitly states this is a dev-loop README, not user documentation.

## Tasks / Subtasks

- [x] **Task 1 — Verify toolchain prerequisites** (AC: 1, 3)
  - [x] Confirm `sjasmplus --version` reports `1.23.0`. **Current state on this host:** system `/usr/local/bin/sjasmplus` is `1.22.0`, vendored `/home/ant/src/microbeast/sjasmplus` is `1.21.0`. Upgrade is required before AC1/AC3 can pass — sjasmplus 1.23.0 was released 2026-04-23.
  - [x] Confirm `make --version` (GNU Make 4.x is fine).
  - [x] Confirm `iz-cpm` is on PATH (`/home/ant/.local/bin/iz-cpm` is already present).
  - [x] Halt and ask the user if 1.23.0 is not available — do not silently fall back to a different sjasmplus version (NFR14 forbids it).

- [x] **Task 2 — Create the directory tree** (AC: 2)
  - [x] Create `src/`, `inc/`, `test/`, `test/inc/`, `test/cases/`, `test/fixtures/`, `build/` (build/ will be gitignored but must exist for sjasmplus's `--lst` / `--sld` to write into; the Makefile creates it on demand via `mkdir -p`).
  - [x] Architecture line 1241–1339 has the full canonical tree. Story 1.1's job is the *skeleton* — only files explicitly listed in this story are created. Module `.asm` files (init, input, statusln, gapbuf, render, dispatch, parser, motions, edits, visual, search, exline, fileio, undo) are NOT created here — they arrive in subsequent stories per Architecture §Implementation Sequence.

- [x] **Task 3 — Create `src/vibe.asm` (top-level entry, stub)** (AC: 1, 2)
  - [x] Begin file with the standard header block (AR23 — module name, purpose, public symbols, state owned, register conventions, dependencies). Note in the header that include block grows as modules arrive in later stories.
  - [x] Body: `ORG 0x0100` followed by `RET`. (Architecture line 1781: "stub `src/vibe.asm` (just `ORG 0x0100 + RET`) yielding a valid (~10-byte) `vibe.com`". `RET` returns to the address pushed by CCP — `0x0000`, the warm-boot vector — which exits to CCP. Story 1.12 replaces this with the proper init/teardown.)
  - [x] Do NOT add `INCLUDE` directives for the `inc/*.inc` files yet — none of them have content. Adding empty includes would assemble fine but creates churn for Story 1.2 (which lands the first real `INCLUDE`).
  - [x] Do NOT use raw `CALL 0x0005` for exit — Architecture forbids it (AR15 / NFR8). The `BDOS_CALL` macro lands in Story 1.4. `RET` is the explicitly-blessed stub-era exit per Architecture line 1781.

- [x] **Task 4 — Create `inc/*.inc` placeholders** (AC: 2)
  - [x] One file each: `equates.inc`, `bios.inc`, `bdos.inc`, `vt52.inc`, `modes.inc`, `state.inc`.
  - [x] Each file: just the standard header block per AR23 (Module / Purpose / Public / State owned / Dependencies). Body empty. Note in Purpose which subsequent story populates it (1.2 for equates+modes+vt52, 1.3 for state, 1.4 for bios+bdos).
  - [x] These are NOT `INCLUDE`d from `vibe.asm` yet — see Task 3.

- [x] **Task 5 — Create the top-level `Makefile`** (AC: 1, 3, 4)
  - [x] Targets: `all` (default → `vibe.com`), `clean`, `test` (stub — recurses into `test/Makefile`), `push` (stub — SLIDE invocation deferred per BA4), `sizes` (stub — listing-file size audit, fully wired in a later story per BA3).
  - [x] sjasmplus invocation MUST match BA2 character-for-character: `sjasmplus --nologo --msg=err --raw=vibe.com --lst=build/vibe.lst --sld=build/vibe.sld src/vibe.asm`. Do NOT add `--date`, `--export`, or any flag that embeds host paths or timestamps into the output.
  - [x] Make rule depends on `src/*.asm` and `inc/*.inc` so any future change rebuilds. Use a `wildcard` pattern.
  - [x] Make rule creates `build/` via order-only prerequisite (`| build`) before invocation, so `--lst=build/...` always succeeds.
  - [x] `clean` removes `vibe.com` and the entire `build/` directory.
  - [x] `.PHONY` declares `all clean test push sizes`.
  - [x] Use 4-space indentation in recipes? **No** — Make requires hard tabs at the start of recipe lines. Indentation rule (4 spaces, no tabs, AR24) is for `.asm` source files only; the Makefile follows Make's syntax.

- [x] **Task 6 — Create `test/Makefile` (stub)** (AC: 4)
  - [x] Stub `all` and `test` targets that print "test harness not yet wired — see Story 1.6" and exit 0. Real harness lands in Story 1.6 (Headless test harness scaffold).
  - [x] Story 1.1's job is to make sure `make test` from the top-level doesn't error — not to implement the harness.

- [x] **Task 7 — Create `test/README.md` (stub)** (no direct AC, supports overall structure per Architecture line 1318)
  - [x] One paragraph: "Headless test harness scaffold lands in Story 1.6 (iz-cpm + sentinel-byte protocol per TH1–TH3). UAT-only items deferred to real MicroBeast hardware."

- [x] **Task 8 — Create `.gitignore`** (AC: 5)
  - [x] Use Architecture's lines 1130–1142 verbatim:
    ```
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
  - [x] AC line 312 lists a subset (`vibe.com`, `build/`, `*.lst`, `*.sld`, `*.bin`, swap files); the architecture's superset satisfies that and is what the architecture actually mandates.

- [x] **Task 9 — Create `README.md`** (AC: 6)
  - [x] First sentence MUST state: this is a dev-loop README, not user documentation (AC6 explicit requirement, AR5).
  - [x] Sections (in order): Prerequisites, Build, Test, Transfer, Repo layout / pointer to `architecture.md`.
  - [x] **Prerequisites:** sjasmplus 1.23.0 (exact version pinned by NFR14), GNU Make, iz-cpm (for `make test` once the harness lands).
  - [x] **Build:** `make` produces `vibe.com` at the project root (BA1).
  - [x] **Test:** `make test` runs the headless test harness (stubbed until Story 1.6).
  - [x] **Transfer:** `make push` invokes SLIDE to upload to MicroBeast (concrete invocation deferred until first real push, per BA4).
  - [x] **Repo layout:** one-paragraph orientation pointing to `architecture.md` for full design rationale and `_bmad-output/planning-artifacts/` for PRD + epics.
  - [x] Link form: `[architecture](_bmad-output/planning-artifacts/architecture.md)` (relative path, since the README lives at project root).

- [x] **Task 10 — Verify reproducibility (AC3)** (AC: 3)
  - [x] Run `make clean && make`, capture `sha256sum vibe.com`.
  - [x] Run `make clean && make` again, capture `sha256sum vibe.com`.
  - [x] The two hashes MUST match. If they don't, do not paper over it — diagnose. Likely culprits: stray flag injecting timestamp, sjasmplus version mismatch, host-path embedding in `--sld`/`--lst` (those are gitignored so OK) leaking into `vibe.com` (which would be a bug).
  - [x] Document the SHA-256 of the stub `vibe.com` in the Dev Agent Record below — this is the NFR18 baseline value future stories regression-test against.

- [x] **Task 11 — Verify `git status` cleanliness (AC5)** (AC: 5)
  - [x] After `make`, run `git status`. Output should show only source files in tracked/untracked positions: `Makefile`, `README.md`, `.gitignore`, `src/vibe.asm`, `inc/*.inc`, `test/Makefile`, `test/README.md`. NOT `vibe.com`, `build/`, `build/vibe.lst`, `build/vibe.sld`.

- [x] **Task 12 — Run smoke checks against the artifact** (AC: 1, 2)
  - [x] `ls -l vibe.com` — file exists at project root, not in `build/`.
  - [x] `head -c 1 vibe.com | xxd` — first byte is whatever sjasmplus emitted for `RET` opcode (`0xC9`), confirming ORG 0x0100 is the entry point's first byte.
  - [x] `wc -c vibe.com` — small (likely 1–10 bytes for a single `RET`; sjasmplus may pad).
  - [x] Inspect `build/vibe.lst` to confirm the listing reports `0100` as the address of the first emitted byte.

## Dev Notes

### Why this story exists

**Greenfield bring-up.** Outside of `_bmad/`, `_bmad-output/`, `.claude/`, and `docs/`, the repo is empty (no commits, no source, no tooling). This story creates the development *floor* every subsequent module sits on:

- A working `make` that produces `vibe.com`.
- A reproducible build (NFR18) so later stories can spot when a change unintentionally perturbs binary layout.
- The directory tree's full shape so subsequent stories drop modules into their correct slots without having to invent placement.
- Pinned conventions (file headers, naming, indentation, .gitignore) as concrete artifacts the dev agent reads once and follows everywhere.

This is *Story 0* in spirit. Architecture line 1778 names it explicitly: "First implementation priority: Story 0 — Project skeleton."

### Critical guardrails for the dev agent

**🛑 Toolchain pin is hard, not soft.** sjasmplus 1.23.0 is mandated by NFR14 / PRD §Build & Transfer. **Do not** silently fall back to whatever's on PATH if 1.23.0 isn't available. The pre-existing system install on this host is 1.22.0 and the vendored copy at `/home/ant/src/microbeast/sjasmplus` is 1.21.0 — neither satisfies the pin. sjasmplus 1.23.0 was released 2026-04-23 and must be built or downloaded fresh. If 1.23.0 isn't in place, surface the gap and ask Ant before continuing. Half a story with the wrong assembler is worse than a halt.

**🛑 sjasmplus invocation flags are pinned.** BA2 names the exact form: `sjasmplus --nologo --msg=err --raw=vibe.com --lst=build/vibe.lst --sld=build/vibe.sld src/vibe.asm`. NFR18 (byte-identical rebuilds) requires no `--date` and no flag that embeds host paths into the binary. `--lst` and `--sld` write paths into *those files* (which are gitignored), but those files are not included in `vibe.com`'s bytes — so they don't affect reproducibility. Don't add `-i` include paths, `--export`, or `--zxnext` etc. — there's no need.

**🛑 `vibe.com` lives at the project root, not in `build/`.** BA1 — chosen for SLIDE-push and CP/M-transfer ergonomics. `make clean` removes it; `.gitignore` excludes it.

**🛑 The stub exit is `RET`, not BDOS function 0.** Architecture line 1781 explicitly names `ORG 0x0100 + RET` as the canonical Story 1.1 stub. `BDOS_CALL` macro is the project-wide BDOS gateway (AR15/MC6/NFR8) but it doesn't exist yet — it's defined in `inc/bdos.inc` and lands in Story 1.4. Using raw `CALL 0x0005` to exit would violate AR15. `RET` cleanly returns to the warm-boot vector at `0x0000` which CCP installed on the stack before `JP 0x0100`'d into the .COM. Standard CP/M idiom.

**🛑 Don't pre-populate `INCLUDE` directives in `vibe.asm`.** The architecture's eventual include block (lines 920–951) shows what `vibe.asm` looks like fully wired. In Story 1.1, it's just the header + `ORG 0x0100` + `RET`. Pre-adding `INCLUDE "../inc/equates.inc"` for an empty file works but creates noise: Story 1.2 will land both the equates *and* the include directive in one go. Don't fragment that work across stories.

**🛑 Don't pre-create module `.asm` files (init, input, gapbuf, …).** Architecture §Implementation Sequence (lines 1557–1577) and Story 1.1 AC2 (line 297–298) limit this story's surface to the directory tree, top-level files, and `inc/` placeholders. Stub module files would be deletable noise.

**🛑 Indentation in `Makefile` uses tabs.** Make requires hard tabs at the start of recipe lines. AR24's "4 spaces, never tabs" rule applies to `.asm`/`.inc` source only; Makefiles follow GNU Make syntax.

**🛑 `make test` must succeed even though there are no tests.** Story 1.1 establishes the recursion (`$(MAKE) -C test`); Story 1.6 lands the actual harness. The `test/Makefile` stub prints a "not yet wired" message and exits 0 — `make test` from the top-level should not error.

### File header convention (AR23) — apply to every file you create

Every `.asm` and `.inc` begins with this block:

```
; ============================================================
; Module: <filename>
; Purpose: <one-paragraph what & why>
;
; Public:
;   <symbol> - <one-line description>
;   ...
;
; State owned (read/write):
;   <variable from state.inc> ...
;
; Register conventions (across public entry points):
;   <register usage if any>
;
; Dependencies:
;   <other inc/*.inc or src/*.asm dependencies>
; ============================================================
```

For Story 1.1's placeholder `inc/*.inc` files, "Public", "State owned", and "Register conventions" can be `(none yet — populated in Story X.Y)`.

### Architecture compliance — what AR* rules this story locks in

| AR | Story 1.1 obligation |
|----|----------------------|
| AR1 | Bespoke skeleton; `src/vibe.asm` ORG 0x0100 + RET; Makefile assembles under sjasmplus 1.23.0; reproducible. |
| AR2 | Makefile uses exact BA2 invocation flags. |
| AR3 | Make targets `all` (default), `test` (recurses), `push` (stub), `clean`, `sizes` (stub) defined. |
| AR4 | `.gitignore` excludes `*.com`, `*.lst`, `*.sld`, `build/`, swap files (architecture line 1130–1142 is the source of truth). |
| AR5 | `README.md` is dev-loop oriented (build/test/transfer + architecture link), not user manual. |
| AR23 | Every `.asm`/`.inc` file begins with the standard header block. |
| AR25 | (Reference only — `vibe.asm` will eventually have the full module include order; Story 1.1 leaves it stubbed.) |

### What this story does NOT do (out-of-scope, defer to other stories)

- ❌ Populate `equates.inc` content → **Story 1.2**
- ❌ Populate `state.inc` content → **Story 1.3**
- ❌ Populate `bios.inc` / `bdos.inc` / `BDOS_CALL` macro → **Story 1.4**
- ❌ Build the status-line module → **Story 1.5**
- ❌ Wire the headless test harness → **Story 1.6**
- ❌ Implement gap buffer → **Story 1.7**
- ❌ Wire `make push` to a concrete SLIDE invocation → deferred per BA4 (later, when first real push happens)
- ❌ Wire `make sizes` to actually parse the listing file → deferred per BA3

### File structure — what to create vs not

**Files to CREATE (NEW):**

```
vibe/
├── Makefile                      ← NEW (top-level, full)
├── README.md                     ← NEW (full)
├── .gitignore                    ← NEW (full)
├── src/
│   └── vibe.asm                  ← NEW (header + ORG 0x0100 + RET)
├── inc/
│   ├── equates.inc               ← NEW (header only)
│   ├── bios.inc                  ← NEW (header only)
│   ├── bdos.inc                  ← NEW (header only)
│   ├── vt52.inc                  ← NEW (header only)
│   ├── modes.inc                 ← NEW (header only)
│   └── state.inc                 ← NEW (header only)
├── test/
│   ├── README.md                 ← NEW (one-paragraph stub)
│   ├── Makefile                  ← NEW (stub)
│   ├── inc/                      ← NEW (empty dir; harness lands in 1.6)
│   ├── cases/                    ← NEW (empty dir; harness lands in 1.6)
│   └── fixtures/                 ← NEW (empty dir; FCB tests in later epics)
└── build/                        ← NOT committed (gitignored); created by Makefile
```

**Files NOT created in this story** (deliberate — they belong to later stories):
- `src/init.asm`, `src/input.asm`, `src/dispatch.asm`, `src/parser.asm`, `src/motions.asm`, `src/edits.asm`, `src/visual.asm`, `src/gapbuf.asm`, `src/render.asm`, `src/statusln.asm`, `src/search.asm`, `src/exline.asm`, `src/fileio.asm`, `src/undo.asm` (one per subsequent story per Architecture §Implementation Sequence)
- `test/cases/*.asm` (Story 1.6 onward)
- `test/inc/test_prologue.inc`, `test/inc/test_epilogue.inc` (Story 1.6)

**Empty-directory tracking note:** Git doesn't track empty directories. For `build/` it's irrelevant (gitignored, created by Make). For `test/inc/`, `test/cases/`, `test/fixtures/`: either commit a `.gitkeep` placeholder in each, or accept that the directories don't exist in fresh checkouts until populated. **Decision: skip `.gitkeep` files** — the directories are referenced by name from later stories' Makefiles, and we'd rather have those stories create the dirs as they need them than carry placeholder files now. (Ant: push back if you want explicit `.gitkeep`s.)

### Testing requirements

Story 1.1's "tests" are the AC verification steps in Tasks 10–12. There is no `test/cases/*.asm` content yet — the headless test harness is Story 1.6.

**What success looks like:**
1. `make` from a clean clone produces `vibe.com` at project root.
2. `make clean && make` twice in a row produces byte-identical `vibe.com` (compare via `sha256sum`).
3. `make test` exits 0 with the stub message.
4. `make clean` removes `vibe.com` and `build/`.
5. `git status` after `make` shows no build artifacts.
6. `cat build/vibe.lst` confirms ORG 0x0100 is the first emitted byte's address.

### Latest tech information

- **sjasmplus 1.23.0** released 2026-04-23. New since 1.22.0: `SIZEOF` operator, `$$$label`/`$$$$label` device/page operators, refactored device/page numbering (errors changed from `-1` to `0x7F00+` in `get_page_at`), and small bug fixes (negative-block edge case, `_` glue, SLD export of EQU). CI does weekly binary-reproducibility testing — relevant to NFR18.
- None of these new features are used in Story 1.1; the version pin is for *forward* alignment with the rest of the project, not because 1.1 depends on a 1.23-specific feature.
- Source: <https://z00m128.github.io/sjasmplus/documentation.html> (1.23.0 docs, 2026-04-23) and the project's CHANGELOG.md on GitHub.
- **iz-cpm** (already on host at `/home/ant/.local/bin/iz-cpm`) — Story 1.1 doesn't invoke it; Story 1.6 does.
- **SLIDE** (vendored at `/home/ant/src/microbeast/SLIDE`) — Story 1.1 doesn't invoke it; the `make push` target is a stub here.

### Project Structure Notes

- This story creates the structure; from this point forward, "alignment with project structure" means: anything that doesn't fit the file tree in Architecture lines 1241–1339 needs an explicit deviation note.
- Architecture's eventual `INCLUDE` block in `vibe.asm` (lines 920–951) uses paths like `"../inc/equates.inc"` — relative to `src/`. That convention applies once the includes start landing in Story 1.2; Story 1.1 has no `INCLUDE` directives.
- No conflicts or variances expected. If the dev agent finds one, halt and surface it.

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md#story-11-project-skeleton--reproducible-build]
- Bespoke skeleton rationale: [Source: _bmad-output/planning-artifacts/architecture.md#selected-starter-none--bespoke-skeleton]
- Build & artifact layout (BA1–BA4): [Source: _bmad-output/planning-artifacts/architecture.md#build--artifact-layout]
- Complete directory structure: [Source: _bmad-output/planning-artifacts/architecture.md#complete-project-directory-structure]
- File-structure conventions (AR22–AR25, header block, format): [Source: _bmad-output/planning-artifacts/architecture.md#file-structure-patterns]
- `.gitignore` canonical content: [Source: _bmad-output/planning-artifacts/architecture.md#repository--build-hygiene]
- README convention: [Source: _bmad-output/planning-artifacts/architecture.md#repository--build-hygiene] (line 1144) and [Source: _bmad-output/planning-artifacts/epics.md] AR5
- NFR14 (toolchain pin): [Source: _bmad-output/planning-artifacts/prd.md#build--transfer] and [Source: _bmad-output/planning-artifacts/prd.md] NFR14 line 870–871
- NFR18 (reproducible build): [Source: _bmad-output/planning-artifacts/prd.md] NFR18 line 886–887
- Implementation sequence: [Source: _bmad-output/planning-artifacts/architecture.md#implementation-sequence-re-stated-from-step-4]
- First implementation priority statement: [Source: _bmad-output/planning-artifacts/architecture.md#implementation-handoff] line 1778–1782

## Dev Agent Record

### Agent Model Used

claude-opus-4-7 (Opus 4.7, 1M context) via Claude Code

### Debug Log References

- Toolchain check: `sjasmplus --version` → `SjASMPlus Z80 Cross-Assembler v1.23.0`; `make --version` → `GNU Make 4.3`; `which iz-cpm` → `/home/ant/.local/bin/iz-cpm`.
- First clean build: `make clean && make` → `vibe.com` 1 byte, `sha256sum` = `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a`.
- Second clean build (NFR18 reproducibility check): same SHA-256.
- Smoke: `head -c 1 vibe.com | xxd` → `c9` (RET opcode); `build/vibe.lst` line 26 shows `0100 C9` (RET emitted at 0x0100).
- `make test` recurses into `test/` and prints the stub message; exits 0.
- `git check-ignore -v` confirms `vibe/vibe.com` matched by `*.com`, `vibe/build/` matched by `build/`. Untracked-source list under `vibe/` shows only the seven source files this story creates plus pre-existing planning/skill artifacts; no `vibe.com`, `build/`, `*.lst`, `*.sld`.

### Completion Notes List

- **Toolchain ready (resolved 2026-05-08):** sjasmplus 1.23.0 was built from `/home/ant/src/microbeast/sjasmplus` (checkout of upstream tag `v1.23.0`) and symlinked at `~/bin/sjasmplus`. Since `~/bin` precedes `/usr/local/bin` on PATH, `sjasmplus --version` now reports `v1.23.0`. The system install at `/usr/local/bin/sjasmplus` (still 1.22.0) is shadowed but untouched. Task 1's version check passed.
- **Empty-directory policy confirmed (resolved 2026-05-08):** No `.gitkeep` files for `test/inc/`, `test/cases/`, `test/fixtures/` — those directories arrive when their first content lands. The directories were created on disk to satisfy Task 2 but git won't track them empty.
- **NFR18 baseline SHA-256 of the stub `vibe.com`:** `4fb733bedb74fec8d65bedf056b935189a289e928b3302bec38a281814de523a` (1 byte; emitted as a single `0xC9` RET at ORG 0x0100). Reproducibility verified across two `make clean && make` cycles. This is the regression-test baseline future stories check against until the binary content legitimately changes.
- **Stub binary size:** sjasmplus emitted exactly 1 byte (no padding), confirming the `--raw` output is a pure function of source. Architecture line 1781 anticipated "~10-byte"; the actual figure is 1 because the file body is just `RET`.
- **`vibe.com` placement:** at project root (`/home/ant/src/microbeast/vibe/vibe.com`), not under `build/` — matches BA1.
- **Repo layout note:** the git toplevel for this checkout is `/home/ant/src/microbeast/`, not `/home/ant/src/microbeast/vibe/`. The `vibe/.gitignore` correctly applies its rules within `vibe/` regardless. `git check-ignore` confirms `vibe.com` and `build/` are excluded. Task 11's spirit — no build artifacts appearing as source — is satisfied.

### File List

New files (10):
- `Makefile`
- `README.md`
- `.gitignore`
- `src/vibe.asm`
- `inc/equates.inc`
- `inc/bios.inc`
- `inc/bdos.inc`
- `inc/vt52.inc`
- `inc/modes.inc`
- `inc/state.inc`
- `test/Makefile`
- `test/README.md`

New directories (5): `src/`, `inc/`, `test/inc/`, `test/cases/`, `test/fixtures/`. (`build/` is created on demand by `make` and is gitignored.)

Modified files (2):
- `_bmad-output/implementation-artifacts/sprint-status.yaml` (status transitions: ready-for-dev → in-progress → review)
- `_bmad-output/implementation-artifacts/1-1-project-skeleton-reproducible-build.md` (this story file)

### Change Log

| Date | Author | Change |
|------|--------|--------|
| 2026-05-08 | Dev agent (Opus 4.7) | Initial implementation: skeleton, Makefile, .gitignore, README, stub `src/vibe.asm`, six `inc/*.inc` placeholders, `test/Makefile` + `test/README.md` stubs. NFR18 baseline established. |
| 2026-05-08 | Code review (Opus 4.7) | Added Makefile `check-toolchain` recipe enforcing NFR14 sjasmplus 1.23.0 pin at build time, wired as order-only prereq of `vibe.com`. NFR18 baseline preserved. |

---

**Completion note:** Ultimate context engine analysis completed — comprehensive developer guide created.

### Review Findings

Code review run 2026-05-08 (Blind Hunter + Edge Case Hunter + Acceptance Auditor). 1 decision-needed, 0 patch, 1 deferred, ~35 dismissed as noise / forward-looking / stub-era / spec-pinned.

- [x] [Review][Patch] Toolchain version-pin enforcement at build time [Makefile:21,28,32-37] — Resolved 2026-05-08. Added `SJASMPLUS_REQUIRED_VERSION := v1.23.0`, a `.PHONY: check-toolchain` target that greps `sjasmplus --version` for the required version (loud error + `exit 1` on mismatch), and wired it as an order-only prereq of `vibe.com` (`| build check-toolchain`). Verified: NFR18 baseline SHA `4fb733be…523a` preserved across two clean rebuilds; a stub `sjasmplus` printing `v1.22.0` on PATH causes `make` to abort with `ERROR: sjasmplus v1.23.0 required (NFR14).` and the actual version printed.
- [x] [Review][Defer] `make clean` doesn't recurse into `test/build/` [Makefile:34-36] — deferred, pre-existing. `.gitignore:9` reserves `test/build/`; once Story 1.6 lands the iz-cpm harness, top-level `make clean` will leave stale test artifacts. Naturally addressed when Story 1.6's `test/Makefile` grows real recipes.
