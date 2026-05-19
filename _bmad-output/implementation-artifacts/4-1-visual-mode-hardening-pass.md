# Story 4.1: Visual-mode hardening pass

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As the VIBE author,
I want the four caller-bound correctness gaps inherited from Epic 3 closed alongside the unit-test coverage gaps that Story 3.8 surfaced and the long-overdue `motion_byte_at_logical` DE-trash docstring,
So that Epic 3's "land features fast" pattern doesn't accrue silent edge-case correctness debt and the next walker author doesn't re-hit the same footgun.

## Acceptance Criteria

**AC1 — `gapbuf_case_toggle_range` empty-buffer short-circuit (closes Story 3.8 caller-bound findings 1 + 2)**

**Given** the `gapbuf_case_toggle_range` primitive at `src/gapbuf.asm:302`
**When** called with `file_length = 0` (empty buffer: `gap_start == GAP_BUFFER_BASE && gap_end == GAP_BUFFER_BASE + GAP_BUFFER_MAX`)
**Then** the primitive short-circuits at entry — after the existing `LD A,B / OR C / RET Z` BC=0 guard at lines 303-306, a NEW `file_length == 0` guard returns Z=1 (no-op) WITHOUT calling `gapbuf_move_gap` and WITHOUT walking the gap region (closes Story 3.8 caller-bound finding 1: CHAR arm passing BC=1 on empty buffer would otherwise XOR-toggle the byte at `gap_end` which on an empty buffer is `GAP_BUFFER_BASE + GAP_BUFFER_MAX = yank_buffer[0]`)
**And** the guard also transitively closes Story 3.8 caller-bound finding 2 (past-EOF offsets in the BLOCK walker when `top_ls >= file_length` — since `top_ls < file_length` is structurally impossible in a non-empty buffer, the only way `top_ls >= file_length` reaches the primitive is via the `file_length == 0` case, which the new guard rejects)

**Size note:** epics.md AC1 narrative says "~5 B" — actual cost is ~10 B (`LD HL,(gap_end)` 3 B + `LD DE,GAP_BUFFER_BASE+GAP_BUFFER_MAX` 3 B + `OR A` 1 B + `SBC HL,DE` 2 B + `RET Z` 1 B), since `file_length` is computed not cached. Spec drift caught at create-story per [[feedback_create_story_cross_check]].

**AC2 — BLOCK jagged-top cursor clamp uses a loop, not a single-step `DEC HL` (closes Story 3.8 caller-bound finding 3)**

**Given** the BLOCK jagged-top cursor clamp at TWO duplicated sites — Story 3.6's `_visual_op_block_arm.b_have_cursor` at `src/visual.asm:1080-1090` AND Story 3.8's `_visual_op_case_block_arm.b_cursor_clamp` at `src/visual.asm:1782-1796`
**When** the projected cursor offset (`top_ls + col_min`) overshoots the top row's EOL by more than 1 byte (reachable when anchor is on a short row, cursor is on a long row, and `col_min` lands past the short row's EOL — e.g. buffer `"a\nbbbbb"`, anchor at offset 0 col 0, cursor at offset 6 col 4 → after BLOCK projection `top_ls=0`, `col_min=0`, `cursor_offset` lands at `top_ls + col_min = 0` which is fine; but with anchor offset 0 col 0 and cursor offset 6 col 4 swapped so `top_ls=2 col_min=0`... see Sub 6.4 fixture for the actual reproducing case)
**Then** the single-step `DEC HL` at both `.b_cursor_clamp` callsites is REPLACED with a `motion_byte_at_logical`-driven loop that walks `HL` back one byte at a time, re-tests via `motion_byte_at_logical` (preserves HL; sets CF=1 if past EOF; returns A=byte if in-file), and stops when the byte at HL is NOT an LF (0x0A) AND CF=0
**And** the loop terminates safely if it walks back to `HL = 0` (guard against underflow — see Q3 pin)
**And** both arms' clamps must use the SAME implementation — either inline at both sites OR (recommended) factored into a shared private helper `_visual_op_block_cursor_clamp` placed near `_visual_op_block_row_bytes` (line 1125) to amortize the body cost across both callsites per the Story 3.8 retro shared-helper-extraction precedent

**Reproducing fixture (anchor short row, cursor long row, high column):** `"abc\nxxxxxxxxxx"` (3 B + LF + 10 B; 14 B total). Place anchor at offset 11 (col 7 of long row, `top_ls=4` for the long row), enter VIS_BLOCK, motion `k` then `0` to land cursor at offset 0 (line-start of short row). After BLOCK projection: `anchor_ls=4 anchor_col=7`, `cursor_ls=0 cursor_col=0`. `col_min=0 col_max=7 top_ls=0` (the top is the short row). The proposed cursor offset is `top_ls + col_min = 0` — but with `col_max=7` the rectangle's top-row-rightmost cell is at offset 0+7 = 7, which is past the short row's EOL at offset 3 (the LF). The clamp must walk cursor back from offset 7 to offset 2 (last printable byte of the short row 'c'). Single-step `DEC HL` only walks back to offset 6 (still on the LF or past). See `test/cases/visual_block-clamp-loop-walks-back-multibyte.asm` (Sub 6.4).

**AC3 — `OR L ; JR Z` shortcut at BLOCK clamp is removed or guarded (closes Story 3.8 caller-bound finding 4)**

**Given** the `LD A,H / OR L / JR Z, .b_have_cursor` shortcut at BOTH BLOCK clamp callsites — `src/visual.asm:1080-1082` (Story 3.6 BLOCK arm) AND `src/visual.asm:1786-1788` (Story 3.8 case-toggle BLOCK arm)
**When** `cursor_offset == 0` AND the buffer starts with `0x0A` (LF) — i.e. the first row is empty
**Then** the shortcut is REMOVED (Option A — recommended; saves 6 B across both sites and lets the unified clamp logic from AC2 handle the case correctly) OR guarded (Option B — add a `CP 0x0A / JR NZ, .b_have_cursor` check INSIDE the shortcut to confirm the byte at HL=0 is not an LF before skipping the clamp; adds ~3 B per site = +6 B total)
**And** with the shortcut removed (Option A), the case `cursor_offset == 0` + leading LF flows into the new AC2 loop clamp, which walks back from offset 0 → the loop must early-terminate on `HL == 0` per the Q3 underflow guard, and the resulting cursor position is `0` (the LF byte — but the top row is degenerate-empty so `0` is the only valid placement); OR the BLOCK arm decides this is a no-op (`bytes_per_row == 0`) and skips the cursor write entirely (Q4 — recommended: leave cursor at 0)

**AC4 — DE-trash invariant documented in `src/motions.asm` header AND `motion_byte_at_logical` AR23 docstring (closes Epic-3 retro A2)**

**Given** a reader opens `src/motions.asm`
**When** they read the module-header `BC-preservation invariant` block at lines 35-44 AND the `motion_byte_at_logical` AR23 contract docstring at lines 532-555
**Then** the DE-trash invariant is documented verbatim in BOTH locations as a parallel callout to the BC-preservation invariant — specifically:
- Module header (after the BC-preservation block ending line 44): a NEW sibling block documenting that `motion_byte_at_logical` **TRASHES DE** (writes `gap_start`, `GAP_BUFFER_MAX`, `gap_end`, and intermediate compute results into DE across its body), and that callers in a walker pattern (BLOCK arms, `visual_count_lines`, `visual_count_block_dims`, the new AC2 clamp loop, `motion_dollar`, `motion_find_line_n`) **MUST `PUSH DE` / `POP DE`** to bracket the call if they need DE preserved across the call. Reference the 4+ instances where this footgun bit: Story 2.6 ×2 (`motion_dollar` and `motion_find_line_n`), Story 3.4 (`visual_count_lines` — +8 B drift over spec for the bracketing), Story 3.5 (`visual_count_block_dims` — third instance), Story 3.8 (`gapbuf_case_toggle_range` walker via `motion_find_line_end` → does not call `motion_byte_at_logical` directly; the new AC2 clamp loop will be the FIFTH instance).
- AR23 contract docstring at line 554: extend the existing `Trashes: A, DE, F.` line into a callout block: `Trashes: A, DE, F. *** DE-TRASH IS LOAD-BEARING: callers in a walker that need DE preserved MUST PUSH DE / POP DE around the CALL ***`.

**And** the change is **comment-only** — 0 B net effect on `vibe.com` size (NFR9 budget unaffected); verified by NFR18 byte-identical rebuild post-edit.

**AC5 — Ten new headless tests under `test/cases/` (closes Story 3.8 retro unit-test gaps T1-T10)**

**Given** the test harness under `test/cases/` and the existing AR25 INCLUDE chain (gapbuf.asm + visual.asm + undo.asm all in chain since Stories 1.7 / 3.3 / 2.13 respectively)
**When** `make test` runs
**Then** the following ten new test cases must exist AND PASS (one per Story 3.8 unit-test gap from retro; sentinel band per Q6 pin):

| # | Test file | Gap |
|---|---|---|
| T1 | `visual_char_toggle-backward-path.asm` | CHAR arm with `cursor < anchor` — the SBC-and-swap min/max pin |
| T2 | `visual_char_toggle-boundary-at-file-length.asm` | CHAR arm: anchor and cursor both at `file_length - 1` (BC=1 boundary case) |
| T3 | `visual_line_toggle-last-line-no-lf.asm` | LINE arm: `.at_eof` CF=1 branch (last line has no trailing LF) |
| T4 | `visual_line_toggle-one-line-selection.asm` | LINE arm: single-line selection (anchor and cursor on same line) |
| T5 | `visual_block_toggle-one-by-one.asm` | BLOCK 1×1 rectangle (anchor == cursor) |
| T6 | `visual_block_toggle-top-ls-at-file-length.asm` | BLOCK `top_ls >= file_length` (covered transitively by AC1 fix; test pins the regression net) |
| T7 | `gapbuf_case_toggle_range-crosses-gap.asm` | Range straddles `gap_start` / `gap_end` — exercises the `gapbuf_move_gap` relocation path |
| T8 | `undo_replay-noop-roundtrip.asm` | No-op undo (Q3 Option A "preserve prior undo on no-op walk") preserved through `op_undo` replay round-trip |
| T9 | `visual_block_toggle-all-digits-clobber-preserve.asm` | BLOCK no-op all-digit case doesn't clobber prior undo with TOO_LARGE (Q3 Option A divergence pin) |
| T10 | `undo_replay-interleaved-mutations.asm` | Replay correctness under interleaved mutations — multi-region undo replay path validation |

**And** each test follows the established sentinel + context-byte pattern (one fail sentinel per test file with multiple context bytes for distinct failure modes; see `test/cases/visual_tilde-toggles.asm:1-23` for the canonical format).

**AC6 — NFR9 size budget honored**

**Given** `make sizes` after the hardening pass lands
**When** the listing is read
**Then** `vibe.com` sits within the NFR9 10240 B ceiling with at least 1500 B residual headroom (projection: ~8270-8400 B = +90-220 B for the four code fixes against the 8179 B baseline at Story 3.8 close; **drift cushion per [[project_nfr9_cliff_edge]] memory: BLOCK-arm-touching stories pad +50-100 B over mid-estimate**)
**And** the listing is captured in the Dev Agent Record / Completion Notes List with the actual size and percentage delta against the new 10240 B ceiling

**AC7 — Hardware UAT on real MicroBeast**

**Given** UAT on hardware
**When** the dev runs (a) `vibe` on an empty buffer + `V~` (exercises AC1 empty-buffer guard end-to-end; status should show `-- normal --`, buffer remains empty, no yank-buffer corruption), (b) `vibe foo.fs` with the AC2 reproducing fixture (jagged BLOCK selection whose top-row `col_min` overshoots EOL by >1) + `Ctrl-V` + motions + `~` (exercises the AC2 loop clamp end-to-end), and (c) a buffer with a leading blank line + `Ctrl-V` from `cursor == 0` + `~` (exercises AC3 OR L JR Z shortcut removal)
**Then** all three scenarios behave per the AC above without hangs, crashes, or status-line silence; the status line carries `-- normal --` (or `msg_yank_too_large` / `msg_undo_too_large` where applicable per the surviving Story 3.6 contract) and `:q` exits cleanly with `vibe.com` returning to CCP

**See "Hardware UAT script" section near the end of this story for the full AC7 walk-through (paste inline at dev-handoff per [[feedback_uat_inline_at_dev_handoff]]).**

**AC8 — NFR18 byte-identical rebuild held**

**Given** NFR18 byte-identical rebuild
**When** the tree is built clean twice after the hardening pass (`make clean && make all` × 2)
**Then** both `vibe.com` SHA-256 digests match (no host-path or timestamp leakage introduced)
**And** the SHA is recorded in the Dev Agent Record / Completion Notes List for future regression reference

## Tasks / Subtasks

- [x] **Task 0 — Cross-check + Q-pin resolution (per retro A4 / [[feedback_create_story_cross_check]])**
  - [x] 0.1 Verify post-3.8 baseline: `make sizes` reports `vibe.com = 8179 B / 79.87% of 10240 B / 2061 B headroom`; if drift, recompute the AC6 projection
  - [x] 0.2 Re-derive the file_length-compute byte count by reading the actual `motion_byte_at_logical` body (lines 557-608) and confirm the AC1 guard cost (~10 B not ~5 B as epics.md projected)
  - [x] 0.3 Confirm the AC2 reproducing fixture (the `"abc\nxxxxxxxxxx"` + anchor-cursor positioning) actually exercises the failure mode — assemble a minimal headless test that drives the current (unfixed) code path and asserts the resulting `cursor_offset` is wrong; this becomes a regression-pin for the fix
  - [x] 0.4 Verify sentinel-band assignment doesn't collide with existing tests by spot-greping the chosen bytes (see Q6 pin below)
  - [x] 0.5 Resolve Q1-Q8 via `AskUserQuestion` with Ant; recommended pins all **Option A** per Epic-3 precedent
  - [x] 0.6 If any Q lands Option B, update the per-task subtasks below before starting Task 1

- [x] **Task 1 — AC1: Patch `gapbuf_case_toggle_range` with empty-buffer guard** (`src/gapbuf.asm`)
  - [x] 1.1 INSERT after the BC=0 guard at lines 303-306 and before `PUSH BC` at line 310:
    ```asm
    ;; file_length=0 short-circuit (Story 4.1 finding 1+2 closure).
    ;; Empty buffer: gap_end == GAP_BUFFER_BASE + GAP_BUFFER_MAX.
    LD      HL, (gap_end)
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    OR      A
    SBC     HL, DE
    RET     Z                   ; file_length=0 → Z=1 (no-op) return
    ```
    Cost: ~10 B (NOT the ~5 B epics.md projected — `file_length` is computed not cached).
  - [x] 1.2 EXTEND the AR23 docstring at lines 273-301 with a `Guards:` line documenting the empty-buffer short-circuit and the Story 4.1 finding closure
  - [x] 1.3 EXTEND the module-header `Public:` block to note the empty-buffer guard semantic
  - [x] 1.4 Verify `cursor_offset` is still PRESERVED on the early-return path (no `gapbuf_move_gap` call → cursor untouched; doc claim in line 293 holds)

- [x] **Task 2 — AC2 + AC3: Replace single-step `DEC HL` clamp with motion-walker loop at BOTH BLOCK callsites** (`src/visual.asm`)
  - [x] 2.1 (Q2 + Q4 dependent) Choose factor-out vs inline (recommended: factor — saves ~30 B amortized over two callsites)
  - [x] 2.2 If factoring: ADD NEW private helper `_visual_op_block_cursor_clamp` near `_visual_op_block_row_bytes` at line 1125. Body:
    ```asm
    ;; In:  HL = proposed cursor_offset (= top_ls + col_min)
    ;; Out: HL = clamped cursor; (cursor_offset) written
    ;; AR23: Trashes A, DE, F. Preserves BC.
    ;; CALLS motion_byte_at_logical — PUSH/POP nothing
    ;; (BC not needed in this body; DE trashed by callee; HL preserved by callee).
    _visual_op_block_cursor_clamp:
    .loop:
        LD      A, H
        OR      L
        JR      Z, .done                ; HL = 0 underflow guard
        CALL    motion_byte_at_logical  ; HL preserved; CF=1 past EOF; A=byte if in-file
        JR      C, .step_back           ; past EOF → clamp back
        CP      0x0A
        JR      NZ, .done               ; real byte → leave
    .step_back:
        DEC     HL
        JR      .loop
    .done:
        LD      (cursor_offset), HL
        RET
    ```
    Estimated size: ~25-30 B.
  - [x] 2.3 (AC3 Option A — recommended) REPLACE the inline clamp at `src/visual.asm:1080-1090` (Story 3.6 `.b_have_cursor`) with `CALL _visual_op_block_cursor_clamp` (HL is already loaded with `top_ls + col_min` per the preceding lines; HL must be re-loaded from the stash if it was clobbered between projection and clamp — verify against current code)
  - [x] 2.4 (AC3 Option A — recommended) REPLACE the inline clamp at `src/visual.asm:1782-1796` (Story 3.8 `.b_cursor_clamp`) with `CALL _visual_op_block_cursor_clamp` similarly
  - [x] 2.5 The `OR L ; JR Z` shortcut at lines 1080-1082 + 1786-1788 is naturally subsumed by the helper's `HL == 0` underflow guard at `.loop` entry; document the consolidation in a comment at both callsites
  - [x] 2.6 If NOT factoring (inline both sites): apply the loop body verbatim at both sites; flag the duplication in deferred-work.md for a future factor-out
  - [x] 2.7 Verify the AR23 contract block on `_visual_op_block_arm` / `_visual_op_case_block_arm` reflects the new helper call (one more `Calls:` entry per arm)

- [x] **Task 3 — AC4: DE-trash invariant docstring** (`src/motions.asm` — comment-only, 0 B)
  - [x] 3.1 ADD a sibling block after the BC-preservation block (after line 44, before the `Public:` block at line 46):
    ```
    ;          **DE-TRASH invariant — the FOOTGUN-PINNING parallel:**
    ;          motion_byte_at_logical **TRASHES DE** across its body
    ;          (writes gap_start, GAP_BUFFER_MAX, gap_end, and
    ;          intermediate compute results into DE). Callers in a
    ;          walker pattern that need DE preserved across the call
    ;          MUST bracket the CALL with PUSH DE / POP DE. Five+
    ;          instances of this footgun bit during development:
    ;            - Story 2.6: motion_dollar (PUSH/POP DE bracket).
    ;            - Story 2.6: motion_find_line_n (PUSH/POP DE bracket).
    ;            - Story 3.4: visual_count_lines (+8 B over spec for
    ;                         the bracketing).
    ;            - Story 3.5: visual_count_block_dims (third instance).
    ;            - Story 4.1: _visual_op_block_cursor_clamp does NOT
    ;                         need bracketing (no DE preserve required
    ;                         in that body — pure HL walker), but the
    ;                         pattern is documented here for the next
    ;                         walker author.
    ;          Origin: Epic 3 retrospective action A2 (2026-05-19).
    ```
  - [x] 3.2 EXTEND the `motion_byte_at_logical` AR23 docstring at line 554. REPLACE:
    ```
    ; Trashes: A, DE, F.
    ```
    WITH:
    ```
    ; Trashes: A, DE, F.
    ;          *** DE-TRASH IS LOAD-BEARING: callers in a walker
    ;          that need DE preserved across this CALL MUST PUSH DE /
    ;          POP DE around the call site. See module header
    ;          DE-TRASH-invariant block for the 5+ instance history. ***
    ```
  - [x] 3.3 Verify NFR18 byte-identical post-edit (comments strip cleanly; SHA must match pre-edit)

- [x] **Task 4 — AC5: Author 10 new headless tests under `test/cases/`**
  - [x] 4.1 (Q6 pin) Decide sentinel-band assignment for the 10 tests — recommended: claim 0x89..0x8F (7 bytes) + 0x98..0x9A (3 bytes) = 10 bytes from the un-allocated middle bands per cross-check (T1-T10 mapping in AC5 table)
  - [x] 4.2 Author `visual_char_toggle-backward-path.asm` (T1 — sentinel 0x89): buffer `"abcDEF"`, mode=VISUAL/CHAR, anchor=5, cursor=0 (anchor > cursor — the SBC-and-swap min/max pin); `visual_apply_case_toggle` with A='~'; assert buffer becomes `"ABCdef"` and `cursor_offset` lands at range_start (= 0); single-region UNDO_KIND_CASE_TOGGLE with `undo_position=0, undo_length=6`
  - [x] 4.3 Author `visual_char_toggle-boundary-at-file-length.asm` (T2 — sentinel 0x8A): buffer `"abc"` (3 B, no LF), mode=VISUAL/CHAR, anchor=2, cursor=2 (BC=1 boundary at `file_length - 1 = 2`); assert byte at offset 2 toggles ('c' → 'C') and no past-EOF read; pinned post-AC1 (NOT empty buffer, but boundary case)
  - [x] 4.4 Author `visual_line_toggle-last-line-no-lf.asm` (T3 — sentinel 0x8B): buffer `"abc\ndef"` (7 B; last line `"def"` has no trailing LF), mode=VISUAL/LINE, anchor=4 (line-start of line 2), cursor=6 (last byte of line 2); assert `motion_find_line_end` returns CF=1 for last line, range_end is `HL` (NOT `HL+1`), bytes 4..6 case-toggle to `"DEF"`, file_length unchanged at 7
  - [x] 4.5 Author `visual_line_toggle-one-line-selection.asm` (T4 — sentinel 0x8C): buffer `"abcdef\nghi"` (10 B), mode=VISUAL/LINE, anchor=0, cursor=3 (anchor and cursor both on line 1); assert range_start=0, range_end=6 (LF inclusive — CF=0 path), bytes 0..5 toggle to `"ABCDEF"`, LF at offset 6 unchanged, line 2 `"ghi"` unchanged
  - [x] 4.6 Author `visual_block_toggle-one-by-one.asm` (T5 — sentinel 0x8D): buffer `"abc"`, mode=VISUAL/BLOCK, anchor=1 (col 1), cursor=1 (col 1) — 1×1 rectangle; assert ONE byte toggled ('b' → 'B'), `visual_op_block_rows=1`, `visual_op_block_col_min=col_max=1`; tests the BLOCK arm degenerate case
  - [x] 4.7 Author `visual_block_toggle-top-ls-at-file-length.asm` (T6 — sentinel 0x8E): pre-fix this would have triggered finding 2; post-AC1 fix the empty-buffer guard rejects. Buffer = empty (file_length=0), mode=VISUAL/BLOCK, anchor=0, cursor=0; assert `gapbuf_case_toggle_range` returns Z=1 (no-op) and yank_buffer head is UNTOUCHED (use a sentinel byte in yank_buffer to verify no pollution); regression-pin for AC1
  - [x] 4.8 Author `gapbuf_case_toggle_range-crosses-gap.asm` (T7 — sentinel 0x8F): pre-populate gap buffer with content `"abc"` at offsets 0..2, then `"def"` at offsets 3..5, with `gap_start` somewhere in the middle (say gap_start=2, gap_end=GAP_BUFFER_BASE+GAP_BUFFER_MAX-3, simulating a buffer of length 5 with the gap between offset 2 and offset 3). Call `gapbuf_case_toggle_range` with HL=0, BC=5 (range crosses the gap). Assert all 5 bytes toggle correctly post-call (the primitive's internal `gapbuf_move_gap` relocates the gap to offset 0 making the bytes physically contiguous at gap_end onwards)
  - [x] 4.9 Author `undo_replay-noop-roundtrip.asm` (T8 — sentinel 0x98): pre-populate `undo_kind=UNDO_KIND_INSERT`, `undo_position=5`, `undo_length=3` (some prior INSERT undo entry). Then drive `visual_apply_case_toggle` over a selection with NO alphabetic content (e.g. buffer `"12345"` + VISUAL/CHAR 0..4); verify `undo_kind` STILL == `UNDO_KIND_INSERT` (Q3 Option A "preserve prior undo on no-op walk"); then `CALL op_undo`; verify the INSERT undo replays correctly (case-toggle did NOT clobber the prior undo)
  - [x] 4.10 Author `visual_block_toggle-all-digits-clobber-preserve.asm` (T9 — sentinel 0x99): same shape as T8 but BLOCK arm — pre-populate prior INSERT undo, drive VISUAL/BLOCK over digit-only rectangle, verify prior INSERT undo PRESERVED (BLOCK arm's TOO_LARGE write should be conditional on dirty walks — verify the no-op all-digit path doesn't write TOO_LARGE; if it does, the test FAILS and surfaces the BLOCK no-op clobber bug)
  - [x] 4.11 Author `undo_replay-interleaved-mutations.asm` (T10 — sentinel 0x9A): drive a sequence: INSERT 'X' at offset 5 → DELETE 'Y' at offset 8 → REPLACE bytes [10..12] → op_undo. Verify the most recent (REPLACE) replays via `undo_replay_replace`, the earlier mutations DON'T replay (single-level undo per Story 2.13); pins replay correctness under interleaved buffer history
  - [x] 4.12 Add the 10 new test files to `test/Makefile` if it requires explicit registration (check current Makefile structure — Story 3.8 added 7 tests without Makefile edits suggesting auto-discovery via glob)

- [x] **Task 5 — AC6: NFR9 size verification**
  - [x] 5.1 `make sizes` after Tasks 1-4 land; capture the listing
  - [x] 5.2 Confirm `vibe.com` is within `8270..8400 B` projected range with at least 1500 B residual headroom under 10240 B ceiling
  - [x] 5.3 If actual size exceeds 8500 B (= +100 B drift over upper projection), apply one of the shrink-down levers from [[project_nfr9_cliff_edge]] before commit: CHAR-arm SBC-swap factor-out (~15-20 B); LINE-arm line-promote factor-out (~15-20 B); tail-JP `status_set_message` pattern across undo.asm / edits.asm / exline.asm (~10-30 B); `edits_indent_undo_end` dead-store cleanup (~25 B across 5 callsites)

- [x] **Task 6 — AC7: Hardware UAT on real MicroBeast** (paste UAT script inline per [[feedback_uat_inline_at_dev_handoff]] — see section "Hardware UAT script" near end of this story)

- [x] **Task 7 — AC8: NFR18 byte-identical rebuild**
  - [x] 7.1 `make clean && make all` × 2; capture `vibe.com` SHA-256 both times
  - [x] 7.2 Verify SHAs match (NFR18); record in Completion Notes List

- [x] **Task 8 — Commit + close** (Q7 pin — recommended Option A: single commit covering all 4 code fixes + docstring + 10 new tests, matching Epic-3 single-commit pattern)
  - [x] 8.1 Stage all modified files: `src/gapbuf.asm`, `src/visual.asm`, `src/motions.asm`, 10 new test files under `test/cases/`
  - [x] 8.2 Commit with message `Story 4.1: visual-mode hardening pass — 4 caller-bound fixes + DE-trash docstring + 10 unit-test gaps` (matches Epic-3 commit style)
  - [x] 8.3 Update `_bmad-output/implementation-artifacts/deferred-work.md`: mark "Caller-side bound hardening across CHAR/LINE/BLOCK arms (4 inherited findings)" as **CLOSED by Story 4.1**; mark "Unit-test coverage gaps (T1-T10) from Story 3.8" as **CLOSED by Story 4.1**; mark "DE-trash invariant docstring on motions.asm header" (Epic-3 retro A2) as **CLOSED by Story 4.1**
  - [x] 8.4 Update `_bmad-output/implementation-artifacts/sprint-status.yaml` status `4-1-visual-mode-hardening-pass: review` after dev pass; flip to `done` after Ant confirms hardware UAT

## Dev Notes

### Architecture compliance

**AR boundaries — Story 4.1 does NOT touch AR12 / AR13 / AR15 surfaces. AR14 surface gains ONE new guarded entry path (the file_length=0 short-circuit at `gapbuf_case_toggle_range` entry) but no NEW gap_start / gap_end writers in any module.**

- **AR12 (status funnel):** zero new direct call sites — Story 4.1 introduces no new `status_set_message` callers. The motions.asm docstring edits are comment-only. The visual.asm clamp helper does not surface status.
- **AR13 (BIOS_CONOUT):** zero direct call sites — Story 4.1 modifies no screen-emission paths.
- **AR14 (gap_start / gap_end WRITES):** unchanged ownership — `gapbuf.asm` remains the sole owner of `LD (gap_start), ...` and `LD (gap_end), ...` writes. The AC1 guard at `gapbuf_case_toggle_range` entry is a READ-ONLY short-circuit (no writes) that protects against caller-bound contract violation. Grep `LD (gap_start),\|LD (gap_end),` against `src/visual.asm` post-Story-4.1 still returns zero matches; against `src/gapbuf.asm` the writes are limited to `gapbuf_init` / `gapbuf_insert` / `gapbuf_delete` / `gapbuf_move_gap` (unchanged from Story 3.8).
- **AR15 (BDOS_CALL):** zero call sites — Story 4.1 introduces no BDOS surface.

**AR23 (per-module header convention)** — Story 4.1 EXTENDS three AR23 docstrings:
1. `gapbuf_case_toggle_range` at `src/gapbuf.asm:273-301` — add `Guards:` line documenting the file_length=0 short-circuit
2. `motion_byte_at_logical` at `src/motions.asm:532-555` — DE-trash invariant callout per AC4
3. `_visual_op_block_arm` + `_visual_op_case_block_arm` — both arms' `Calls:` lines extended with the new `_visual_op_block_cursor_clamp` helper (if Q2 Option A factoring chosen)

Plus a NEW AR23 docstring on the new private helper `_visual_op_block_cursor_clamp` (Task 2.2) following the standard In/Out/Trashes/Calls format.

**AR25 (INCLUDE order)** — Story 4.1 adds NO new INCLUDEs to `src/vibe.asm`. The existing AR25 chain (unchanged from Story 3.8) is:
1. statusln.asm → 2. gapbuf.asm → 3. motions.asm → 4. edits.asm → 5. parser.asm → 6. dispatch.asm → 7. exline.asm → 8. fileio.asm → 9. search.asm → 10. visual.asm → 11. undo.asm

The new `_visual_op_block_cursor_clamp` helper lives in `visual.asm` (10) which INCLUDEs AFTER `motions.asm` (3) — so `motion_byte_at_logical` is BACKWARD-resolved (already defined when visual.asm is parsed). No new forward-ref challenges.

**MC4 register convention** — `_visual_op_block_cursor_clamp` accepts HL = proposed `cursor_offset`. Trashes A, DE, F. Preserves BC (per the BC-preservation invariant documented in AC4 — even though the BLOCK arm callers don't currently need BC preserved, future callers might).

**MC7 knob centralization** — Story 4.1 introduces no new equates. The `GAP_BUFFER_BASE + GAP_BUFFER_MAX` expression in the AC1 guard is evaluated at assembly time; no new constants are needed.

**SR3 byte-read invariant** — Story 4.1's AC2 loop clamp is the FIFTH consumer of `motion_byte_at_logical` outside motions.asm (after `visual_count_lines`, `visual_count_block_dims`, the BLOCK walker via `_visual_op_block_row_bytes`, and other transitive consumers). The clamp loop does NOT need PUSH/POP DE bracketing because the loop body uses only HL (preserved by the callee) and tests CF + A (also preserved by the callee in the documented sense). The DE-trash invariant is honored without explicit bracketing because the body never reads DE.

### Files this story modifies (and what to preserve)

**`src/gapbuf.asm`** (currently 351 lines post-Story-3.8):
- MODIFY `gapbuf_case_toggle_range` at lines 302-345: INSERT the file_length=0 guard between lines 306 and 310. Per Task 1.
- MODIFY the AR23 docstring at lines 273-301 to add a `Guards:` entry. Per Task 1.2.
- MODIFY the module-header `Public:` block to note the empty-buffer guard. Per Task 1.3.
- PRESERVE: `gapbuf_init` body UNCHANGED; `gapbuf_insert` body UNCHANGED; `gapbuf_delete` body UNCHANGED; `gapbuf_move_gap` body UNCHANGED (including .equal / .right / .left arms); the existing BC=0 guard at lines 303-306 UNCHANGED; the alpha-test loop body at lines 318-340 UNCHANGED; the dirty-flag accumulator + Z-flag return semantics UNCHANGED; the AR sweep status (no new BIOS / BDOS surfaces).

**`src/visual.asm`** (currently ~2181 lines post-Story-3.8):
- MODIFY `_visual_op_block_arm.b_have_cursor` at lines 1080-1090 (Story 3.6 BLOCK arm): replace the inline clamp with `CALL _visual_op_block_cursor_clamp`. Per Task 2.3.
- MODIFY `_visual_op_case_block_arm.b_cursor_clamp` at lines 1782-1796 (Story 3.8 case-toggle BLOCK arm): replace the inline clamp with `CALL _visual_op_block_cursor_clamp`. Per Task 2.4.
- ADD `_visual_op_block_cursor_clamp` private helper near line 1125 (after `_visual_op_block_row_bytes`). Per Task 2.2.
- MODIFY module-header lines 1-547 if needed: extend `Public:` and `State owned` and `Register conventions` blocks for the new private helper. Per Task 2.7.
- PRESERVE: `visual_enter_char` body (UNCHANGED); `visual_enter_line` body (UNCHANGED); `visual_enter_block` body (UNCHANGED); `visual_extend` body (UNCHANGED — all three arms preserved); `visual_apply_operator` body + `_visual_op_char_arm` / `_visual_op_line_arm` bodies (UNCHANGED); `_visual_op_block_arm`'s BODY (UNCHANGED EXCEPT the .b_have_cursor inline-clamp replacement); `_visual_op_block_row_bytes` body (UNCHANGED); `_visual_op_block_project_rect` body (UNCHANGED — shared helper from Story 3.8 stays); `_visual_op_delete_yank_or_change` body (UNCHANGED); `visual_apply_shift` body (UNCHANGED); `visual_apply_case_toggle` body + CHAR/LINE arms + shared finalise + BLOCK body (UNCHANGED EXCEPT the .b_cursor_clamp inline-clamp replacement); `visual_count_lines` / `visual_count_block_dims` / `visual_compose_status*` bodies (UNCHANGED); all module-local DEFW/DEFB cells (UNCHANGED — no new cells); all module-header constants (UNCHANGED).

**`src/motions.asm`** (currently 1166 lines post-Story-2.6/2.7):
- MODIFY module-header at lines 35-44: INSERT new sibling block after line 44 documenting the DE-trash invariant. Per Task 3.1. **Comment-only — 0 B net.**
- MODIFY `motion_byte_at_logical` AR23 docstring at line 554: extend the `Trashes:` line with the DE-TRASH-IS-LOAD-BEARING callout. Per Task 3.2. **Comment-only — 0 B net.**
- PRESERVE: All motion handlers UNCHANGED (motion_h / motion_j / motion_k / motion_l / motion_w / motion_b / motion_0 / motion_dollar / motion_G / motion_gg). All internal helpers UNCHANGED (motion_byte_at_logical body / motion_find_line_start / motion_find_line_end / motion_apply_count / motion_find_line_n / is_word_char). All module-local DEFW cells UNCHANGED. All module-header dependency blocks UNCHANGED (the new DE-trash callout sits ABOVE the `Public:` block, not in the Dependencies block).

**Test files (`test/cases/*.asm`):**
- ADD 10 new test files per Task 4 (T1-T10).
- NO bulk patch needed — the AR25 INCLUDE chain extension for gapbuf.asm + visual.asm + undo.asm is all in place since Stories 1.7 / 3.3 / 2.13.
- PRESERVE: All existing test bodies (Story 3.8's `visual_tilde-*.asm` tests + all 256 other tests UNCHANGED and still PASS post-Story-4.1).

**NO CHANGES to:**
- `src/dispatch.asm` — Story 4.1 introduces no new dispatch entries (the `~` binding from Story 3.8 is unchanged).
- `src/undo.asm` — Story 4.1 introduces no new undo kinds (T8/T9/T10 tests exercise existing replay paths without adding new kinds).
- `src/edits.asm` / `src/render.asm` / `src/parser.asm` / `src/fileio.asm` / `src/search.asm` / `src/exline.asm` / `src/init.asm` / `src/vibe.asm` / `src/input.asm` / `src/statusln.asm`.
- `inc/equates.inc` / `inc/state.inc` / `inc/modes.inc` / `inc/bdos.inc` / `inc/bios.inc` / `inc/vt52.inc`.
- `Makefile` / `test/Makefile` (assuming auto-discovery glob; verify per Task 4.12).

### Implementation choices and trade-offs

**Choice 1 (AC1): file_length=0 guard checks `gap_end == GAP_BUFFER_BASE + GAP_BUFFER_MAX` (not `gap_start == GAP_BUFFER_BASE`).**
- Both conditions hold iff file_length=0, but `gap_start == GAP_BUFFER_BASE` ALSO holds when cursor is at offset 0 in a non-empty buffer — checking only `gap_start` would false-positive and reject legitimate calls.
- Checking `gap_end` against the post-empty constant is the unique-distinguisher for empty buffer.
- Alternative: compute file_length explicitly (gap_start + GAP_BUFFER_MAX - gap_end) and check Z. Same byte cost, marginally more arithmetic. The `gap_end` direct compare is simpler.

**Choice 2 (AC2): Factor the BLOCK cursor clamp into a shared helper rather than inline at both sites.**
- Inline at both sites: ~25-30 B body × 2 = +50-60 B; clear regression-pin but high cost.
- Factored helper: ~25-30 B body + 2 × 3 B CALL = +31-36 B; saves ~15-25 B vs inline.
- Behavior-preservation across both arms: both arms currently use IDENTICAL clamp logic (modulo .b_have_cursor / .b_cursor_clamp label naming) — refactoring is mechanical and Story 3.8's `_visual_op_block_project_rect` extraction precedent shows the pattern works without test regression.
- Recommended: factor (Q2 Option A).

**Choice 3 (AC2): Loop clamp walks ONE BYTE AT A TIME via motion_byte_at_logical, not a precomputed line-length scan.**
- The slower per-byte walk is correct in all cases (LF detection + past-EOF detection + HL=0 underflow guard all handled by the same loop).
- Faster alternative (compute line_length up-front, clamp HL to `top_ls + line_length - 1`): adds branching on whether top row is at EOF (CF=1 from motion_find_line_end) + arithmetic, comparable byte cost, less obvious correctness. The per-byte walk is the conservative choice.

**Choice 4 (AC3): Remove the `OR L ; JR Z` shortcut entirely (Option A) rather than guarding it (Option B).**
- The shortcut was a 3-byte optimization for `cursor_offset == 0`. After AC2 factor-out, the unified loop handles `HL == 0` via its underflow guard at `.loop` entry — the shortcut becomes redundant.
- Removing saves 6 B total (3 B × 2 sites). Guarding adds 6 B total.
- Recommended: remove (Q4 Option A).

**Choice 5 (AC4): DE-trash docstring lands in TWO places (module header + per-routine AR23), not one.**
- Module header is the first thing a reader sees on opening the file. The per-routine AR23 is the second.
- Both must mention the invariant because four+ Story authors hit the footgun across 2.6 / 3.4 / 3.5 + the implicit Story 3.6 BLOCK arm. Single-location documentation hasn't stopped the recurrence.
- Recommended: redundant documentation is justified for load-bearing invariants per Epic-3 retro A2.

**Choice 6 (AC5 T1-T10): Tests are pure-unit (drive the helper functions directly), not end-to-end through `dispatch_key`.**
- The dispatch path (Ctrl-V → `dispatch_key` → `visual_enter_block` → motions → `~` → `dispatch_visual` → `visual_apply_case_toggle`) is already exercised by Story 3.8's `parser_visual_tilde-dispatch.asm` test.
- The new T1-T10 tests target SPECIFIC code paths (CHAR backward, LINE at-EOF, BLOCK 1×1, gap-crossing primitive, etc.) — drive the helper/primitive directly with prepared state.
- Matches Epic 3 unit-test convention.

**Choice 7 (AC8 + Q7): Single commit covering all 4 code fixes + docstring + 10 tests, NOT split commits.**
- Matches Epic-3 single-commit pattern across Stories 3.1-3.8.
- The 4 fixes are LOGICALLY one story (caller-bound hardening sweep); the 10 tests are LOGICALLY one story (Story 3.8 retro carry-forwards).
- Split-commit alternative: 1 commit per AC × 8 commits — more granular but breaks the Epic precedent and adds bisect-noise without test-correlation benefit (each AC is independently testable).

### Previous story intelligence

**From Story 3.8 (most recent — visual case toggle):**
- `gapbuf_case_toggle_range` primitive at `src/gapbuf.asm:302-345` is the AC1 patch target. Story 3.8 landed it as the 5th public gapbuf mutator. The BC=0 guard at lines 303-306 is the EXISTING pattern that AC1's file_length=0 guard mirrors structurally.
- The BLOCK arm at `src/visual.asm:1728-1798` (`_visual_op_case_block_arm`) is the AC2/AC3 patch target #2. The `.b_cursor_clamp` block at lines 1782-1796 is inherited VERBATIM from Story 3.6's `_visual_op_block_arm.b_have_cursor` — same bug, two locations.
- Story 3.8 retro flagged the 4 caller-bound findings + 10 unit-test gaps as deferred. Story 4.1 is the closing-out story.
- NFR9 baseline post-3.8: 8179 B; per [[project_nfr9_cliff_edge]] the amend to 10240 B (2026-05-19) means Story 4.1 has 2061 B of headroom — comfortable but not unlimited.
- The Story 3.8 spec drift pattern: spec mid-estimate +310 B, actual +324 B (+14 B drift). Story 3.8's BLOCK arm landed +72 B over spec estimate; the same drift signature could apply to Story 4.1's clamp helper.

**From Story 3.7 (visual shift `>` / `<`):**
- The line-class submode-agnostic approach Story 3.7 used would NOT apply here — the clamp is per-row geometry, not line-class.
- Story 3.7's `edits_indent_walk_end` cell + `edits_indent_walk` walker pattern is unrelated to Story 4.1's clamp work.

**From Story 3.6 (visual operators `d` / `y` / `c`):**
- `_visual_op_block_arm.b_have_cursor` at `src/visual.asm:1080-1090` is the AC2/AC3 patch target #1. Story 3.6's BLOCK arm is the ORIGINAL location of the `OR L ; JR Z` shortcut + single-step `DEC HL` clamp. Story 3.8 inherited it verbatim into `.b_cursor_clamp`.
- Story 3.6's deferred-work entry "BLOCK arm cursor-clamp gap on jagged-top selections (+17 B patch)" is the EARLIER attempt at this fix — code review patch landed +17 B for a partial fix. Story 4.1 supersedes that patch (verify the +17 B was actually applied to Story 3.6's body and the loop fix subsumes it).
- The shared-helper-extraction precedent from Story 3.8 dev pass (`_visual_op_block_project_rect` saved 64 B across two BLOCK arms) is a structural template for Task 2.2 factoring.

**From Story 3.5 (visual block mode Ctrl-V):**
- `visual_count_block_dims` at `src/visual.asm:1914+` is the third instance of the DE-trash gotcha (Story 3.5 retro flagged the +13 B drift over spec's 87 B mid-estimate due to PUSH/POP DE bracketing).
- Story 4.1's AC4 docstring update is a comment-only memorial of this footgun pattern.

**From Story 3.4 (visual line mode `V`):**
- `visual_count_lines` at `src/visual.asm:1829+` is the SECOND instance of the DE-trash gotcha (Story 3.4 retro flagged +8 B drift over spec's 55 B mid-estimate).

**From Story 2.6 (word/line/buffer motions w/b/0/gg/G/$):**
- `motion_dollar` and `motion_find_line_n` are the FIRST two instances of the DE-trash gotcha. Story 2.6 retro item became Epic-2 retro carry-forward #1 (documented but not closed); Story 4.1 AC4 finally closes it.

**From Story 2.13 (single-level undo `u`):**
- `op_undo` dispatch + `undo_replay_*` bodies are the test targets for T8/T9/T10. All replay bodies + the `undo_clear` semantics are unchanged from Story 2.13.

**From Story 1.7 (gap buffer primitives):**
- `gapbuf_move_gap` is the load-bearing primitive that `gapbuf_case_toggle_range` calls internally. Story 4.1's AC1 guard short-circuits BEFORE the `gapbuf_move_gap` call, so the move-gap relocation is skipped on empty-buffer entry (Verify: `cursor_offset` PRESERVED on the early-return path per Task 1.4).

### Git intelligence

**Recent commits (last 8; for context — Story 4.1 inaugurates Epic 4):**
- `35c5651 Story 3.8: visual case toggle ~` — direct precursor; landed the case-toggle surface + cliff-edge NFR9 close at 8179 B + 7 new tests. Story 4.1 fixes its 4 caller-bound findings + 10 unit-test gaps.
- `aca5097 Story 3.7: visual shift > and <` — established the line-class submode-agnostic precedent (unrelated to Story 4.1 scope).
- `da662d0 Story 3.6: visual operators d/y/c land; FR36 closes` — established the 3-arm CHAR/LINE/BLOCK pattern and the ORIGINAL `_visual_op_block_arm.b_have_cursor` clamp location.
- `cd105bf Story 3.5: visual block mode Ctrl-V lands` — established VIS_BLOCK + BH3 jagged-line semantic.
- `517bef1 Story 3.4: visual line mode V lands` — established VIS_LINE submode and the SECOND DE-trash gotcha instance.
- `a1ce47d Story 3.3: visual character mode lands` — established the visual.asm module.
- `c0761fd Story 3.2: repeat last search` — Epic 3 search-related; unrelated to Story 4.1 scope.
- `231ce3f Story 3.1: forward literal search /pattern lands` — Epic 3 entry; NFR9 amend from 6400 → 8192 B (the prior amend before Epic 4's 8192 → 10240 B).

**Pattern:** every Epic-3 story has been single-commit, 4-10 new headless tests, NFR18 byte-identical rebuild required. Story 4.1 follows the same shape: 10 new tests, single commit (Q7 Option A), NFR18 verified.

**Insight from Epic 3 spec-drift pattern:** the cross-check memory caught drift in 5/8 Epic 3 stories. Story 4.1's AC1 size claim ("~5 B") is ALREADY caught at create-story per [[feedback_create_story_cross_check]] — corrected to ~10 B in this spec. Dev pass MUST re-verify each AC's size projection against actual implementation at Task 5 (NFR9 check).

### Implementation Questions (resolve with Ant before dev starts)

See **Task 0** for the Q1-Q8 pin list. Recommended pins are all **Option A** matching the Story 3.x precedent. Surface to Ant via `AskUserQuestion` at Task 0.5:

- **Q1: AC1 guard placement — at `gapbuf_case_toggle_range` entry (Option A — recommended) or at CHAR-arm caller (Option B)?** Option A is the centralized fix (one site protects all callers — current AND future); Option B narrows the fix to the only known violator (CHAR arm) but leaves the primitive's contract under-defended. Recommend A.

- **Q2: AC2 clamp factoring — shared helper `_visual_op_block_cursor_clamp` (Option A — recommended) or inline at both sites (Option B)?** Option A saves ~15-25 B and consolidates the regression-pin; Option B is clearer at each site but duplicates the body. Recommend A.

- **Q3: AC2 underflow guard — `HL == 0` early-terminate (Option A — recommended) or unsigned-wrap detection via `DEC HL` then test (Option B)?** Option A is the explicit guard at loop entry; Option B relies on a separate post-DEC check. Option A is structurally clearer. Recommend A.

- **Q4: AC3 shortcut handling — REMOVE the `OR L ; JR Z` shortcut entirely (Option A — recommended) or GUARD it with a `CP 0x0A` LF check (Option B)?** Option A saves 6 B (3 B × 2 sites); Option B adds 6 B but preserves the cursor==0 fast path. Recommend A — the loop's HL==0 underflow guard subsumes the shortcut's intent.

- **Q5: Per-row PUSH/POP DE bracketing in the new clamp helper — yes (Option A — defensive) or no (Option B — recommended)?** Option B is correct (the helper body uses only HL — DE-trash by `motion_byte_at_logical` callee doesn't leak DE state across the call to break this helper's contract). Option A is the defensive over-document. **Divergence from typical**: recommend B here — the cross-check memory says "be careful of size projections", and unnecessary PUSH/POP costs 2 B per pair. Confirm with Ant.

- **Q6: Sentinel-band assignment for the 10 new tests (T1-T10) — claim 0x89..0x8F + 0x98..0x9A (Option A — recommended; 10 bytes from un-allocated middle bands per cross-check) or consume the 0xFE..0xFF defensive slack + 0x89..0x8F (Option B)?** Option A keeps the defensive slack reserved for review-patch sentinels; Option B is more aggressive on slack consumption. Recommend A.

- **Q7: Commit strategy — single commit covering all 4 code fixes + docstring + 10 tests (Option A — recommended) or split per AC (Option B)?** Matches Epic-3 single-commit pattern. Recommend A.

- **Q8: Story 4.1 vs 4.2 sequence — confirm 4.1 (hardening) lands BEFORE 4.2 (welcome screen) (Option A — recommended) or in parallel (Option B)?** Per Epic 4 narrative + Epic-3 retro A3 — hardening should land first to close carry-forward debt before any new feature surface. Recommend A.

### NFR9 budget arithmetic (worked example)

Pre-4.1 footprint: **8179 B / 79.87% of 10240 B / 2061 B headroom** (post-Story-3.8 close; current `vibe.com` on disk; SHA `60dfbf7a19ff4ca7a7bdd2eb03fc521e866a7d7aa9b493113bdcbb6a354646a2` per Story 3.8 Dev Agent Record).

Story 4.1 projected deltas (positive = grows footprint; negative = shrinks):

- **AC1** — `gapbuf_case_toggle_range` file_length=0 guard: **+10 B** (NOT +5 B as epics.md projected; cross-check correction per [[feedback_create_story_cross_check]] — `file_length` is computed not cached)
- **AC2** — `_visual_op_block_cursor_clamp` helper (Q2 Option A factored):
  - Helper body: ~25-30 B (HL-test + motion_byte_at_logical + CP 0x0A + DEC HL + JR loop)
  - Two CALL replacements at lines 1080-1090 and 1782-1796: each replaces ~11 B of inline clamp with 3 B CALL = net -16 B saved across both sites
  - Net AC2 delta: ~+30 B helper − 16 B inline savings = **+14 B**
- **AC3** — `OR L ; JR Z` shortcut removal (Q4 Option A):
  - Each shortcut is 3 bytes (LD A,H + OR L + JR Z) — 2 sites = **-6 B** saved
- **AC4** — DE-trash docstring (Task 3): **+0 B** (comments)

Subtotal code growth: **+10 + +14 + (-6) + 0 = ~+18 B** (clean-factor mid-estimate)

**Per [[project_nfr9_cliff_edge]] memory: pad BLOCK-arm mid-estimates by +50-100 B for spec drift.** Adjusted projection: **+18 + 50..100 = +68..118 B**

**Projected post-4.1 footprint: 8179 + 68..118 = 8247..8297 B / ~80.5..81.0% of 10240 B / 1943..1993 B headroom.** Well within ceiling — no NFR9 amend needed.

**Drift triggers (revisit at Task 5.3):**
- **Green:** actual < 8400 B (= +220 B over baseline) → ship as-is, generous Epic-4 runway preserved.
- **Yellow:** 8400..8500 B → ship as-is but flag for Story 4.2 byte-tracking.
- **Red:** > 8500 B (= +320 B over baseline; +200 B over mid-estimate + drift pad) → apply one of the shrink-down levers from [[project_nfr9_cliff_edge]] before commit. Available levers (estimated savings):
  1. CHAR-arm SBC-and-swap factor-out: ~15-20 B
  2. LINE-arm line-promote factor-out: ~15-20 B
  3. Tail-JP `status_set_message` pattern across undo.asm/edits.asm/exline.asm: ~10-30 B (carry-forward #2)
  4. `edits_indent_undo_end` dead-store cleanup across 5 callsites: ~25 B (carry-forward #5)

State growth: **+0 B** (no new state cells, no new equates beyond what's compile-time constant in the AC1 guard).

### Test count target

256 (post-3.8 with Story 3.8's 7 new tests) → **266 PASS** (+10 new from Story 4.1: T1-T10 per AC5) / 1 deliberate-fail (`harness_fail` sentinel) unchanged.

### Project Structure Notes

- `src/visual.asm` grows from ~2181 lines to ~2210 lines (+~30 B in code for the new helper, plus ~15 lines of AR23 docstring comments).
- `src/gapbuf.asm` grows from 351 lines to ~365 lines (+~10 B in code for the AC1 guard, plus ~5 lines of `Guards:` docstring comment).
- `src/motions.asm` grows from 1166 lines to ~1195 lines (+0 B in code — comment-only AC4 changes; ~25 lines of new docstring text).
- Sentinel band allocation for Story 4.1 (per Q6 pin):
  - **0x89..0x8F + 0x98..0x9A — Story 4.1 (THIS STORY: 10 unit-test gaps T1-T10)**
- Cumulative sentinel allocation through Story 4.1 (Epic-3 + 4.1 only):
  - 0x80..0x88 — Epic 1/2 (motions / edits tests; no "Sentinel" comment header convention)
  - **0x89..0x8F — Story 4.1 (T1-T7)**
  - 0x90..0x97 — Epic 1/2 (motions / edits tests)
  - **0x98..0x9A — Story 4.1 (T8-T10)**
  - 0x9B..0x9F — defensive slack
  - 0xA0..0xAA + 0xE9 — Story 3.1
  - 0xAB..0xAF + 0xEA — Story 3.2
  - 0xB0..0xB4 + 0xEB — Story 3.3
  - 0xB5..0xB9 + 0xEC — Story 3.4
  - 0xBA..0xBD + 0xED — Story 3.5
  - 0xBE — reserved by `harness_fail` infra
  - 0xBF — Story 3.5 Review patch
  - 0xC0..0xCF — Story 2.13 (undo)
  - 0xD0..0xD6 + 0xEE — Story 3.6
  - 0xD7..0xDC + 0xEF — Story 3.7 (+0xDD..0xDE Review patches)
  - 0xDF + 0xF4 + 0xF8..0xFD — Story 3.8
  - 0xE0..0xE8 + 0xF0..0xF3 — Epic 1/2 parser_* + tests
  - 0xF5..0xF7 — Epic 1/2 dispatch_* tests
  - **0xFE..0xFF — reserved as defensive slack** (NOT consumed by Story 4.1 per Q6 Option A)
- Per [[feedback_create_story_cross_check]]: cross-checked the AC narrative against actual render/edit semantics:
  - **AC1 size correction**: epics.md says "~5 B"; actual is ~10 B (`file_length` is computed not cached). Corrected in this spec.
  - **AC2 reproducing fixture math**: verified — short row at `top_ls=0` (3 B "abc"), long row at `top_ls=4` (10 B "xxxxxxxxxx"), `col_min=0 col_max=7`, projected cursor `top_ls + col_min = 0` IS valid (offset 0 is 'a') — but wait, the actual failure mode needs cursor to land PAST EOL of short row, not at offset 0. Re-derive: anchor at offset 11 (col 7 of long row), cursor at offset 0 (col 0 of short row); `anchor_ls=4 anchor_col=7 cursor_ls=0 cursor_col=0`; `col_min=0 col_max=7 top_ls=0` (short row is top). Top-row width = 3 B (positions 0-2). Top-row col_max=7 lands at offset 0+7 = 7, past EOL at position 3. The clamp needs to walk back from offset 7 to offset 2 ('c'). Single-step DEC HL only walks 7→6 (still in long row's '\n' position past the short row). Loop walks 7→6→5→4 (LF of short row at offset 3) → 3 (LF) → 2 ('c', not LF, in-file) → stop. **Correct — 4-step walk-back needed.** Pinned by T-fixture at Sub 6.4.
  - **No `~` past-EOF marker** ([[project_no_tilde_marker]]) — Story 4.1's UAT script + tests do NOT predict any `~` marker on past-EOF rows; the operator '~' is bound only in VISUAL mode (per Story 3.8 AC1) and renders are spaces (per `render_byte_at_logical.past_eof`).
  - **Cursor lands at offset 0 post-`:e`** ([[feedback_uat_trace_cursor]]) — verified: AC7 UAT scenario (a) `vibe` on empty buffer then `V~` — `V` from cursor=0 in empty buffer is degenerate (anchor=line-start=0; cursor=0); `~` on empty selection should be a no-op per AC1 guard. UAT script step uses `V~` not `i~` (which would be wrong — `i` enters INSERT and types '~' as a literal); pinned.
  - **DE-trash invariant** — explicit AC4 documentation; the new clamp helper does NOT need PUSH/POP DE per Q5 Option B (helper body uses only HL).
  - **NFR9 projection** — explicit at AC6 + budget arithmetic block. Story 4.1 is COMFORTABLY within the new 10240 B ceiling (~80% post-4.1 projected); no NFR9 amendment risk.
  - **CR/CRLF and sjasmplus-hostile filenames** — not relevant to Story 4.1 (hardening pass touches no file I/O).
  - **DISPATCH_VISUAL_COUNT** — unchanged at 0x1A (26) per Story 3.8 close. Story 4.1 introduces no new dispatch entries. Cross-check at dev pass: verify `build/vibe.lst` shows `LD B, DISPATCH_VISUAL_COUNT` emits as `06 1A` post-4.1 (should be identical to post-3.8 since no dispatch changes).
  - **Backward-selection symmetry** — T1 explicitly tests CHAR backward (`cursor < anchor`) — the SBC-and-swap pattern from Story 3.8's `_visual_op_case_char_arm` is the target.

### References

- **Epic 4 narrative:** `_bmad-output/planning-artifacts/epics.md:279-287` (Epic 4 header + module-touched list).
- **Story 4.1 epic AC source:** `_bmad-output/planning-artifacts/epics.md:1770-1818` (the 8-AC narrative).
- **Epic 3 retrospective (driving document for Story 4.1):** `_bmad-output/implementation-artifacts/epic-3-retro-2026-05-19.md` — actions A1 (NFR9 amend, ALREADY SHIPPED), A2 (DE-trash docstring — closed by AC4), A3 (visual-mode hardening pass = THIS STORY), A4 (cross-check as Task 0 — applied via Task 0).
- **Story 3.8 Review Findings (source of the 4 caller-bound findings + 10 unit-test gaps):** `_bmad-output/implementation-artifacts/3-8-visual-case-toggle.md:371-378`.
- **PRD NFR9 (10240 B ceiling, amended 2026-05-19):** `_bmad-output/planning-artifacts/prd.md:855-873`.
- **PRD NFR5 (no crashes), NFR17 (mode/operator decoupling), NFR18 (build reproducibility):** `_bmad-output/planning-artifacts/prd.md:839-841, 904-907, 908-910`.
- **Architecture FR33-FR38 (visual mode → visual.asm) + NFR9 enforcement location:** `_bmad-output/planning-artifacts/architecture.md:1537, 1560`.
- **Existing `gapbuf_case_toggle_range` body (AC1 patch target):** `src/gapbuf.asm:273-345` (AR23 docstring at 273-301; existing BC=0 guard at 303-306; gapbuf_move_gap call at 311; walk loop at 318-340).
- **Existing `_visual_op_block_arm.b_have_cursor` (AC2/AC3 patch target #1, Story 3.6):** `src/visual.asm:1080-1090`.
- **Existing `_visual_op_case_block_arm.b_cursor_clamp` (AC2/AC3 patch target #2, Story 3.8):** `src/visual.asm:1782-1796`.
- **Existing `_visual_op_block_row_bytes` (insertion-point neighbour for new helper):** `src/visual.asm:1125-1141`.
- **Existing `_visual_op_block_project_rect` (Story 3.8 shared-helper precedent for Task 2.2 factoring):** `src/visual.asm:1145-1199`.
- **Existing `motion_byte_at_logical` AR23 docstring (AC4 patch target #2):** `src/motions.asm:529-555` (the `Trashes: A, DE, F.` line at 554 is the specific edit point).
- **Existing motions.asm module header (AC4 patch target #1):** `src/motions.asm:1-167` (the BC-preservation block at 35-44 is the sibling-insertion point).
- **Existing visual.asm AR sweep (zero gap_start/gap_end direct writes — must remain true post-4.1):** `src/visual.asm` — grep `LD (gap_start),\|LD (gap_end),` returns zero matches at Story 3.8 close.
- **Story 3.8 retrospective intelligence (Q-pin pattern + dev-pass shrink-down precedent):** `_bmad-output/implementation-artifacts/3-8-visual-case-toggle.md` (especially the "NFR9 budget arithmetic" section + "Per-arm shrink-down options" + "Debug Log References" recording the live cliff-edge resolution).
- **Story 3.6 retrospective intelligence (the +17 B BLOCK clamp Review patch + the original clamp logic):** `_bmad-output/implementation-artifacts/3-6-visual-operators-d-y-c.md`.
- **Story 2.13 retrospective (undo replay path + UNDO_KIND constants):** `_bmad-output/implementation-artifacts/2-13-single-level-undo-u.md`.
- **deferred-work.md** (current backlog; Story 4.1 closes three entries):
  - "Caller-side bound hardening across CHAR/LINE/BLOCK arms (4 inherited findings)" — CLOSED by AC1/AC2/AC3.
  - "Unit-test coverage gaps (T1-T10) from Story 3.8 retro" — CLOSED by AC5.
  - "DE-trash invariant docstring on motions.asm header" — CLOSED by AC4.
  - Three duplicated SBC-and-swap min/max projection sites (NFR9-relevant refactor candidate) — STAYS deferred; not in Story 4.1 scope.
- **Memory entries consulted:**
  - [[project_nfr9_cliff_edge]] — NFR9 baseline 8179 B / new 10240 B ceiling / BLOCK-arm drift +50-100 B pad.
  - [[feedback_create_story_cross_check]] — applied at Task 0; corrected AC1 "~5 B" → ~10 B.
  - [[feedback_uat_trace_cursor]] — applied at AC7 UAT script (use `$a` not `i` at EOF; use `V~` not `i~` on empty buffer).
  - [[feedback_uat_inline_at_dev_handoff]] — applied: UAT script pasted inline in "Hardware UAT script" section below.
  - [[project_no_tilde_marker]] — applied: UAT script doesn't predict `~` markers on past-EOF rows.
  - [[feedback_enter_normal_mode_clobbers_status]] — APPLICABILITY: Story 4.1 doesn't change any mode-exit paths; the existing `JP enter_normal_mode` and manual `LD A,MODE_NORMAL ; LD (mode_byte),A ; JP parser_clear` patterns in visual.asm BLOCK arms are PRESERVED unchanged. Listed as informational reference only.

## Hardware UAT script (AC7 — paste into chat at dev-handoff per [[feedback_uat_inline_at_dev_handoff]])

**Pre-requisites:** Story 4.1 built and `vibe.com` transferred to MicroBeast B: drive. Sentinel files: `empty.txt` (0 bytes), `jagged.fs` (14 B: `"abc\nxxxxxxxxxx"` — note NO trailing LF on long row), `leadinglf.txt` (5 B: `"\nabcd"`).

| # | Step | Expected behavior |
|---|------|---------------------|
| 1 | `B>vibe empty.txt` | Editor opens; buffer empty; status `[empty.txt][No Name]` `-- normal --`; cursor at offset 0 |
| 2 | Press `V` | Status `-- visual line -- 1`; visual_anchor pinned at line-start (= 0 in empty buffer); cursor stays at 0 |
| 3 | Press `~` | **AC1 guard fires:** `gapbuf_case_toggle_range` returns Z=1 no-op; buffer stays empty; status returns to `-- normal --`; cursor at 0; **NO `~` rendered anywhere** (per [[project_no_tilde_marker]] — past-EOF rows are spaces, the operator `~` is consumed by `dispatch_visual['~']`); yank_buffer head unchanged (verify via `:!stat` style if a debug surface is available, otherwise trust the headless test T6) |
| 4 | Type `:q` Enter | Editor exits cleanly; CCP prompt returns |
| 5 | `B>vibe jagged.fs` | Editor opens; buffer shows two rows: row 1 `abc` (3 B), row 2 `xxxxxxxxxx` (10 B; no trailing LF); cursor at offset 0; status `-- normal --` |
| 6 | Press `G$a` to append at EOF | `G` → cursor at offset 4 (start of last/row 2); `$` → cursor at offset 13 (last printable byte of row 2, the rightmost 'x'); `a` → insert position advances to offset 14 = file_length; status `-- insert --`. NB: `$a` alone (without leading `G`) would land at EOL of the CURRENT line (= offset 2 'c' on row 1), then insert at offset 3 (the LF position) — splitting row 1 mid-buffer. For multi-line files, `$a` only appends at EOF when cursor is already on the last line. |
| 7 | Press `Esc` | Status returns to `-- normal --`; cursor at offset 13 |
| 8 | Press `gg` to go to BOF | Cursor at offset 0 (start of row 1); status `-- normal --` |
| 9 | Press `$` to go to EOL of row 1 | Cursor at offset 2 (the 'c' — last printable byte of row 1); status `-- normal --` |
| 10 | Press `j` to go down to row 2 | Cursor at offset 6 (col 2 of row 2 — column-preserving motion per FR19); status `-- normal --` |
| 11 | Press `Ctrl-V` (block visual entry) | Status `-- visual block -- 1x1`; visual_anchor=6 (cursor's offset, NOT line-start per VIS_BLOCK semantics); cursor at 6 |
| 12 | Press `k` (extend up one row) | Status `-- visual block -- 2xN` where N is some column count; the projection should clamp to row 1's geometry — **AC2 fires here**: top_ls=0, col_min=2, col_max=2 (anchor was col 2; cursor moves to row 1 col 2 = offset 2). With AC2 loop clamp, cursor should land at offset 2 (the 'c'). **Pre-fix this would have landed at a wrong offset (one-step DEC HL insufficient if the projection overshoots)** |
| 13 | Press `~` | **AC2 + AC3 fire end-to-end:** rectangle is 2 rows × 1 col at column 2 of each row. Row 1 col 2 = 'c' → 'C'. Row 2 col 2 = 'x' → 'X'. **Status returns to `-- normal --`** (per BLOCK arm's `enter_normal_mode` tail-JP for `~`). Buffer becomes `"abC\nxXxxxxxxx"`. **Cursor lands at offset 2** (top_ls + col_min = 0 + 2 = 2; AC2 loop clamp confirms 'C' is in-file and not an LF, no walk-back needed in this case) |
| 14 | Press `u` (single-level undo) | Per Story 3.6 BLOCK undo TOO_LARGE semantic: status surfaces `msg_undo_too_large`; buffer/cursor UNCHANGED. **AC2/AC3 fixes do not regress this contract.** |
| 15 | Type `:q!` Enter (discard, exit) | Editor exits; file on disk UNCHANGED (per AR14 — visual.asm doesn't write to file; `:q!` skips fileio_save) |
| 16 | `B>vibe leadinglf.txt` | Editor opens; buffer 5 B: LF at offset 0, then `"abcd"` at offsets 1..4; cursor at offset 0 (the LF byte); status `-- normal --`. Render: row 1 EMPTY (the LF terminates it), row 2 `"abcd"` |
| 17 | Press `Ctrl-V` (block visual entry from cursor==0) | Status `-- visual block -- 1x1`; visual_anchor=0; cursor=0. **AC3 fires here on entry to BLOCK** — pre-fix the `OR L ; JR Z .b_have_cursor` shortcut would have skipped the clamp entirely; post-fix the unified loop handles `HL == 0` via the underflow guard. Cursor stays at 0 |
| 18 | Press `~` (no motion — degenerate 1×1 rectangle at offset 0) | Rectangle is 1 row × 1 col at column 0 of row 1 (the empty row). bytes_per_row = 0 (the top row is empty). Walk loop should find zero bytes to toggle (or the AC1 guard could fire if file_length=0 — but file_length=5 here, NOT empty). Behavior: AC1 guard does NOT fire (non-empty buffer); the BLOCK walker's `bytes_per_row=0` short-circuit fires (or the gapbuf primitive's BC=0 guard fires for the row). Result: status returns to `-- normal --`; buffer unchanged; cursor at 0. **Validates AC3 end-to-end on leading-LF case.** |
| 19 | Type `:q` Enter | Editor exits; file on disk UNCHANGED |
| 20 | Confirm overall result | **All 19 steps pass on real MicroBeast.** No hangs, no crashes, no status-line silence, no buffer corruption, no yank-buffer pollution, no cursor-position drift. AC7 closes. |

## Dev Agent Record

### Agent Model Used

Amelia (bmad-dev-story) running Opus 4.7 (1M context).

### Debug Log References

- **AC1 spec drift caught at dev pass:** the create-story spec's Choice 1 recommended checking `gap_end == GAP_BUFFER_BASE + GAP_BUFFER_MAX` as the unique distinguisher for an empty buffer. That check FALSE-POSITIVES when cursor is at EOF in a non-empty buffer — gap-tracks-cursor places the gap at the cursor, so cursor-at-EOF puts `gap_end` at the top of the buffer. First AC1 attempt with the `gap_end`-only check broke 6 existing `visual_tilde-*` tests (their setup leaves `gap_end` at the post-init constant). Fixed by computing `file_length = gap_start + GAP_BUFFER_MAX - gap_end` explicitly (the alternative the spec mentioned). Cost: ~17 B not ~10 B as spec projected. Pattern reference for next [[feedback_create_story_cross_check]] cycle: the spec's "both conditions hold iff file_length=0" claim was wrong — `gap_end == GAP_BUFFER_BASE + GAP_BUFFER_MAX` holds whenever cursor is at EOF, not only when buffer is empty.
- **T9 design ambiguity surfaced:** spec's T9 narrative said "verify prior INSERT undo PRESERVED" with caveat "if it does, the test FAILS and surfaces the BLOCK no-op clobber bug". The BLOCK arm UNCONDITIONALLY clobbers prior undo with UNDO_KIND_TOO_LARGE per the documented design (multi-region undo deferred per Q1 Option A; mirrors Story 3.6 BLOCK arm precedent). T9 was authored to pin the documented divergence — UNDO_KIND_TOO_LARGE recorded regardless of dirty walks. Future story can flip the assertion if the BLOCK arm gains "preserve prior undo on no-op" semantics.

### Completion Notes List

- **Q1-Q8 pin resolutions:** all Option A except Q5 (Option B — no PUSH/POP DE in `_visual_op_block_cursor_clamp` body) per recommendations.
- **AC1 (`gapbuf_case_toggle_range` file_length=0 guard):** +17 B (spec mid-estimate +10 B + PUSH/POP HL preservation + explicit `file_length` compute per debug-log entry above). Guard fires before `gapbuf_move_gap`; `cursor_offset` PRESERVED on early-return path per Task 1.4.
- **AC2/AC3 (`_visual_op_block_cursor_clamp` helper + shortcut removal):** **net −14 B** (helper body 20 B + 2 × 3 B CALL inline = 26 B vs 2 × 17 B inline = 34 B prior). The `OR L; JR Z` shortcut subsumed by the helper's HL==0 underflow guard at `.loop` entry (Q4 Option A). HL is re-loaded from the `top_ls + col_min` projection just before the CALL at both sites.
- **AC4 (DE-trash invariant docstring):** comment-only (0 B); two sites: `src/motions.asm` module header (new sibling block after BC-preservation invariant) + `motion_byte_at_logical` AR23 docstring (extended `Trashes:` line).
- **AC5 (10 new headless tests T1-T10):** all pass. Sentinel bands 0x89..0x8F + 0x98..0x9A (per Q6 Option A).
- **AC6 (NFR9):** `vibe.com` actual **8182 B / 79.9% of 10240 B / 2058 B headroom**. Story-4.1 cumulative delta **+3 B** (AC1 +17 B, AC2/AC3 −14 B, AC4 0 B). GREEN — comfortably within projection (mid-estimate was +18 B; actual undershot). No shrink-down levers needed.
- **AC7 (hardware UAT):** UAT script pasted inline at dev-handoff per [[feedback_uat_inline_at_dev_handoff]] memory (see end-of-pass chat message).
- **AC8 (NFR18 byte-identical rebuild):** verified via `make clean && make all` × 2. Both SHA-256: `d791eea13ff782aa4818aad7f87a3667992c89402a103a50211b4091ca109543`.
- **Test count:** 257 pass (pre-Story 4.1) → 267 pass (+10 new from T1-T10); 1 deliberate-fail (`harness_fail`) unchanged.
- **AR23 contract updates:** added `Calls:` blocks to `_visual_op_block_arm` and `_visual_op_case_block_arm` mentioning the new `_visual_op_block_cursor_clamp` helper; extended `gapbuf_case_toggle_range` AR23 with a `Guards:` line documenting AC1's empty-buffer short-circuit; extended `gapbuf.asm` module-header `Public:` entry for `gapbuf_case_toggle_range` with the Story-4.1 guard note.

### File List

- `src/gapbuf.asm` — modified: AC1 file_length=0 guard + AR23 / module-header docstring updates
- `src/visual.asm` — modified: `_visual_op_block_cursor_clamp` helper added near line 1144; both BLOCK callsites (`_visual_op_block_arm.b_have_cursor` and `_visual_op_case_block_arm.b_cursor_clamp`) replaced with `CALL`; AR23 prose updated on both BLOCK arms
- `src/motions.asm` — modified: AC4 DE-trash docstring (module header + `motion_byte_at_logical` AR23 `Trashes:` line); comment-only, 0 B
- `test/cases/visual_char_toggle-backward-path.asm` — new (T1, sentinel 0x89)
- `test/cases/visual_char_toggle-boundary-at-file-length.asm` — new (T2, sentinel 0x8A)
- `test/cases/visual_line_toggle-last-line-no-lf.asm` — new (T3, sentinel 0x8B)
- `test/cases/visual_line_toggle-one-line-selection.asm` — new (T4, sentinel 0x8C)
- `test/cases/visual_block_toggle-one-by-one.asm` — new (T5, sentinel 0x8D)
- `test/cases/visual_block_toggle-top-ls-at-file-length.asm` — new (T6, sentinel 0x8E)
- `test/cases/gapbuf_case_toggle_range-crosses-gap.asm` — new (T7, sentinel 0x8F)
- `test/cases/undo_replay-noop-roundtrip.asm` — new (T8, sentinel 0x98)
- `test/cases/visual_block_toggle-all-digits-clobber-preserve.asm` — new (T9, sentinel 0x99)
- `test/cases/undo_replay-interleaved-mutations.asm` — new (T10, sentinel 0x9A)
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — updated: 4-1 status to in-progress, then review
- `_bmad-output/implementation-artifacts/4-1-visual-mode-hardening-pass.md` — updated: this story file (Status, Dev Agent Record, File List, Change Log)

## Change Log

| Date | Note | Author |
|---|---|---|
| 2026-05-19 | Hardware UAT confirmed on real MicroBeast (Ant). AC7 closes. Status → done. UAT step 6 corrected post-commit `a2658c4`: original used `$a` on a two-line buffer and predicted cursor-at-EOF, but `$` is per-LINE not per-file (`$a` lands at EOL of current line; for multi-line EOF append, use `G$a`). Story file step 6 amended; `[[feedback_uat_trace_cursor]]` memory amended to clarify per-line vs per-file `$` semantics. | bmad-dev-story (Claude Opus 4.7 1M) + Ant |
| 2026-05-19 | Story 4.1 dev pass complete; status → review. AC1 +17 B (corrected from spec's +10 B; the `gap_end`-only check false-positives at cursor-at-EOF — switched to explicit `file_length = gap_start + GAP_BUFFER_MAX - gap_end` per the spec's mentioned alternative). AC2/AC3 net −14 B via shared `_visual_op_block_cursor_clamp` helper. AC4 0 B (comment-only). Story-4.1 cumulative **+3 B** (8179 → 8182 B); NFR9 79.9% / 2058 B headroom — GREEN. NFR18 SHA `d791eea1...` × 2 (byte-identical). 257 → 267 pass (+10 new T1-T10 tests, sentinels 0x89..0x8F + 0x98..0x9A). All Q1-Q8 pins resolved Option A except Q5 Option B (per recommendations). T9 authored to pin the BLOCK arm's documented Q3 Option A divergence (records UNDO_KIND_TOO_LARGE unconditionally; future story can flip if BLOCK gains "preserve prior undo" semantics). | bmad-dev-story (Claude Opus 4.7 1M) |
| 2026-05-19 | Story 4.1 ready-for-dev. Inaugurates Epic 4: visual-mode hardening + welcome screen. Closes Epic-3 retro action items A2 (DE-trash docstring — AC4), A3 (visual-mode hardening = whole story), A4 (cross-check as Task 0 — applied during spec authoring; corrected AC1 size "~5 B" → ~10 B per [[feedback_create_story_cross_check]]). 8 ACs spanning: AC1 file_length=0 guard at gapbuf_case_toggle_range entry (closes Story 3.8 caller-bound findings 1+2); AC2 motion-walker loop clamp replacing single-step DEC HL at BOTH BLOCK callsites (closes finding 3); AC3 OR L JR Z shortcut removal (closes finding 4); AC4 DE-trash docstring in motions.asm header + motion_byte_at_logical AR23 (closes Epic-3 retro A2, the 4-instance footgun across Stories 2.6 ×2 / 3.4 / 3.5); AC5 ten new headless tests T1-T10 (closes Story 3.8 retro unit-test gaps); AC6 NFR9 verification at new 10240 B ceiling (~80% projected; 1500+ B residual headroom); AC7 hardware UAT 20 steps inline; AC8 NFR18 byte-identical rebuild. NFR9 mid-estimate +18 B; with [[project_nfr9_cliff_edge]] drift pad +50-100 B → projected +68-118 B → post-4.1 ~8247-8297 B / ~80.5-81.0% / 1943-1993 B headroom — comfortable. Sentinel allocation: 0x89..0x8F + 0x98..0x9A (10 bytes from un-allocated middle bands per cross-check Q6 Option A). All Q1-Q8 pins recommended Option A except Q5 (no defensive PUSH/POP DE in new clamp helper — body uses only HL). Single commit per Q7. Reviewed against [[feedback_create_story_cross_check]] / [[project_no_tilde_marker]] / [[feedback_uat_trace_cursor]] / [[feedback_uat_inline_at_dev_handoff]] / [[feedback_enter_normal_mode_clobbers_status]] memories. | bmad-create-story (Claude Opus 4.7 1M) |
