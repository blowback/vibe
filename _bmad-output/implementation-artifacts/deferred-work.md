# Deferred Work

Work items raised during reviews that are real but not actionable in the originating story.

## Deferred from: code review of story-1.1 (2026-05-08)

- **`make clean` doesn't recurse into `test/build/`** — `.gitignore` already reserves `test/build/`; once Story 1.6 lands the iz-cpm harness with build artifacts, top-level `make clean` will leave them stale. Address as part of Story 1.6 by adding `$(MAKE) -C test clean` to the top-level `clean` recipe and a matching `clean:` target in `test/Makefile`. (Sources: Acceptance Auditor + Blind Hunter.)

## Deferred from: code review of story-1.2 (2026-05-09)

- **`VT52_GOTO` row/col clamp must land in render path.** Out-of-range coordinates (row ≥ `SCREEN_ROWS`, col ≥ `SCREEN_COLS`) emit garbage bytes after the bias and corrupt the VT52 state machine. Story 1.11 (render pipeline) must clamp `row ∈ [0, SCREEN_ROWS-1]`, `col ∈ [0, SCREEN_COLS-1]` before composing `ESC Y (row+VT52_COORD_BIAS) (col+VT52_COORD_BIAS)`. (Source: Edge Case Hunter.)
