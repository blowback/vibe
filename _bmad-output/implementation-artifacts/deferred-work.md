# Deferred Work

Work items raised during reviews that are real but not actionable in the originating story.

## Deferred from: code review of story-1.1 (2026-05-08)

- **`make clean` doesn't recurse into `test/build/`** — `.gitignore` already reserves `test/build/`; once Story 1.6 lands the iz-cpm harness with build artifacts, top-level `make clean` will leave them stale. Address as part of Story 1.6 by adding `$(MAKE) -C test clean` to the top-level `clean` recipe and a matching `clean:` target in `test/Makefile`. (Sources: Acceptance Auditor + Blind Hunter.)

## Deferred from: code review of story-1.2 (2026-05-09)

- **`VT52_GOTO` row/col clamp must land in render path.** Out-of-range coordinates (row ≥ `SCREEN_ROWS`, col ≥ `SCREEN_COLS`) emit garbage bytes after the bias and corrupt the VT52 state machine. Story 1.11 (render pipeline) must clamp `row ∈ [0, SCREEN_ROWS-1]`, `col ∈ [0, SCREEN_COLS-1]` before composing `ESC Y (row+VT52_COORD_BIAS) (col+VT52_COORD_BIAS)`. (Source: Edge Case Hunter.)

## Deferred from: code review of story-1.3 (2026-05-09)

- **`search_pattern` / `ex_buffer` length-byte convention has no compile-time consumer enforcement.** Buffers reserve `1 + N` bytes (1 length prefix + N payload), documented in comments only. A consumer that reads `SEARCH_PATTERN_BUFFER` bytes from `search_pattern` instead of `search_pattern + 1` reads the length byte as data with no build-time signal. Belongs in ex/search consumer stories (2.1, 3.1) — add a named offset symbol (`search_pattern_text EQU search_pattern + 1`) when those stories first read the buffer. (Source: Blind Hunter.)
- **Static state has no zero-initialization story.** CP/M `.com` files do not zero TPA; `mode_byte`, `gap_start`, `cursor_offset`, `buffer_dirty`, etc. start as whatever garbage the previous program left. The current `RET`-stub doesn't read state, so it's inert today, but Story 1.4+ that reads any byte before writing reads stale RAM. Story 1.12 (init/teardown) must zero the static block on entry. (Source: Blind Hunter.)
- **No alignment / page-crossing consideration for `shadow_buffer`.** A page-aligned `shadow_buffer` enables an `H = row + base_high` render fast-path; the current layout makes no attempt to pad. Whether the win justifies the slack belongs to the render pipeline story (1.11) where indexing strategy is decided. (Source: Blind Hunter.)
- **Mode-state protocol undocumented.** The semantic relationship between `pending_operator`, `pending_motion_prefix`, `visual_submode`, and `count_accumulator` is not pinned in code or comments — whether they're orthogonal axes, mutually exclusive states, or sub-states of a state machine requires reading multiple stories' worth of context. Document in mode-dispatch / command-parser stories (1.9, 1.10) where the protocol is first implemented. (Source: Blind Hunter.)
- **`inc/state.inc` has no `IFDEF`-style re-include guard.** sjasmplus's natural EQU single-assignment catches accidental double-include with a duplicate-symbol error, but a defensive guard convention across all headers would catch it earlier and produce a more diagnostic message. Project-wide convention question — defer to a future structural-cleanup pass. (Source: Blind Hunter + Edge Case Hunter.)
- **No per-section sentinels with ASSERTs catching a missed `static_off` advance.** A forgotten `static_off = static_off + N` line silently aliases two adjacent fields with no build-time error. Adding `small_state_end`, `word_state_end`, `buffer_block_end` sentinels with `ASSERT` checks on their offsets would catch this. Defer until the layout grows further or a near-miss occurs. (Source: Blind Hunter + Edge Case Hunter.)
- **No file-naming or comment convention to distinguish EQU-only vs positional `.inc` headers.** state.inc must INCLUDE post-`ORG` (uses `$`); equates.inc / vt52.inc / modes.inc are safe pre-`ORG`. The distinction is documented only in two scattered comments. A naming convention (e.g., `*.eq.inc` vs `*.pos.inc`) or an explicit Header attribute in the AR23 block would make the rule structural. Project-wide question. (Source: Blind Hunter.)
