# VIBE

This is a dev-loop README, not user documentation. It tells contributors how to build, test, and push VIBE — nothing more. End-user documentation is a separate post-MVP artifact.

VIBE is a vi-spirited modal text editor for the Feersum MicroBeast (Z80, CP/M 2.2). Design rationale, layered architecture rules, and the implementation sequence live in [architecture](_bmad-output/planning-artifacts/architecture.md). Product scope and acceptance criteria live alongside it in `_bmad-output/planning-artifacts/` (see `prd.md` and `epics.md`).

## Prerequisites

- **sjasmplus 1.23.0** — exact version pinned by NFR14. Earlier or later versions are not supported. Install from <https://github.com/z00m128/sjasmplus> (tag `v1.23.0`) and ensure it's first on `PATH`.
- **GNU Make** (4.x is fine).
- **iz-cpm** — for `make test` once the headless harness lands in Story 1.6.

## Build

```
make
```

Produces `vibe.com` at the project root (BA1). The build is reproducible: `make clean && make` twice in a row yields a byte-identical `vibe.com` (NFR18).

`make clean` removes `vibe.com` and the `build/` directory.

## Test

```
make test
```

Stubbed until Story 1.6. Currently prints a "not yet wired" message and exits 0 so the top-level `make test` recursion succeeds.

## Transfer

```
make push
```

Stubbed until the first real push happens (BA4). Will invoke SLIDE to upload `vibe.com` to MicroBeast over its serial bridge.

## Repo layout

- `src/vibe.asm` — top-level entry point.
- `inc/*.inc` — equates, state, BIOS/BDOS shims, VT52 codes, mode IDs.
- `test/` — headless test harness scaffold (Story 1.6 onward).
- `build/` — listing/SLD output (gitignored).
- `_bmad-output/planning-artifacts/` — PRD, architecture, epics.
- `_bmad-output/implementation-artifacts/` — story files and sprint status.

For the full directory tree and the rationale behind every architectural commitment, read [architecture](_bmad-output/planning-artifacts/architecture.md).
