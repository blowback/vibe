# Story 4.3: Welcome-screen test-coverage hardening

Status: done

<!-- Provenance: Theme C of _bmad-output/implementation-artifacts/deferred-work-triage-2026-05-19.md.
     Closes deferred entries L498-L500 from "Deferred from: code review of
     4-2-welcome-screen-on-no-argument-launch (2026-05-19)" in deferred-work.md.
     Test-only story — 0 B production-code delta. NFR18 byte-identical trivially held. -->

## Story

As a VIBE maintainer who needs the welcome-screen invariants to survive future edits without
relying solely on hardware UAT,
I want the three Story 4.2 test-coverage gaps (AC3 inlined-replica-only / AC2 `.new_file`-only /
AC4 `:e empty.txt` round-trip missing) closed under headless `make test`,
So that a future refactor that flips a `JR Z` to `JR NZ` in the dismissal hook, or that
accidentally adds a non-`.no_arg` writer to `welcome_active`, or that breaks `:e empty.txt`'s
relationship with the FR53 one-shot guarantee, surfaces at the headless layer instead of
waiting for the next hardware-UAT cycle.

## Acceptance Criteria

**AC1 — AC3 dismissal-key coverage extended from `'i'`-only to all 5 production-listed keys.**

**Given** Story 4.2 AC3 names five dismissal-key variants (`i`, `:`, `Esc`, `Ctrl-L`, a literal
digit) and the existing `test/cases/welcome_dismissed-on-first-key.asm:82-97` only exercises
`'i'` (0x69)
**When** Story 4.3 lands
**Then** four additional headless test cases pin the same post-dismissal contract for each of
the remaining 4 keys:

| Key      | Byte | Test filename                                   |
|----------|------|-------------------------------------------------|
| `Esc`    | 0x1B | `welcome_dismissed-on-first-key-esc.asm`        |
| `Ctrl-L` | 0x0C | `welcome_dismissed-on-first-key-ctrl-l.asm`     |
| `:`      | 0x3A | `welcome_dismissed-on-first-key-colon.asm`      |
| `5`      | 0x35 | `welcome_dismissed-on-first-key-digit.asm`      |

Each replica mirrors `welcome_dismissed-on-first-key.asm` exactly, rebinding only the
sentinel key byte in subtest 6's `LD A, '<key>'` preamble and the matching `CP '<key>'`
comparison. The hook's post-state assertions (welcome_active==0, dirty_rows[0..2]==0xFF,
shadow_buffer[6*80+1]=='X', key-preserved-across-PUSH/POP-AF) are identical across all 5
files — the contract is that the dismissal hook is **key-agnostic** for the welcome_active
clear + render_mark_all_dirty call, varying only in the key-preservation byte.

**Sentinel-code reuse rule (AC1 + AC2 + AC3 below):** every new test in this story reuses an
existing Story-4.2 T-sentinel where the assertion shape is identical (e.g. all 5 dismissal-key
files use 0x9D, all AC2 sibling files use 0x9C, the `:e empty.txt` survival file uses 0x9E).
This keeps the sentinel-band crowding bounded — Story 4.3 introduces ZERO new sentinel bytes.
The B-context byte distinguishes subtests within each file as before.

**AC2 — AC2 coverage broadened from `.new_file`-only to all 3 driveable non-no-arg branches
+ 0xAA-poison hardening on every AC2 test in the family.**

**Given** Story 4.2 AC2 names four non-no-arg branches of `fileio_load_initial`:
load-success, `.new_file`, file-too-large, can't-read-file; the existing
`test/cases/init_welcome-hidden-with-arg.asm:62-106` exercises only `.new_file` (via the
guaranteed-not-present `NOSUCH.FS`) and pre-clears `welcome_active=0` so the assertion cannot
distinguish "no writer touched the flag" from "a writer wrote 0"
**When** Story 4.3 lands
**Then** the AC2 family pins three of the four branches with 0xAA-poison-survives assertions:

| Branch          | Trigger                                                    | Test filename                              |
|-----------------|------------------------------------------------------------|---------------------------------------------|
| `.new_file`     | `NOSUCH.FS` (existing test, hardened)                       | `init_welcome-hidden-with-arg.asm` (modify) |
| load-success    | `HELLO.TXT` on B: (13 B per fixture)                        | `init_welcome-hidden-load-success.asm`      |
| file-too-large  | `BIG.BIN` on B: (33792 B > GAP_BUFFER_MAX=32768)            | `init_welcome-hidden-too-large.asm`         |

All three tests share the same shape: pre-poison `welcome_active = 0xAA`, populate
`DEFAULT_FCB` with the branch-triggering filename, call `fileio_load_initial`,
assert `welcome_active == 0xAA` post-call. The 0xAA poison is the disambiguator: any writer
that touches `welcome_active` (writes 0 OR 1) breaks the test, vs the prior `==0` assertion
which only catches writers-of-1. Sentinel 0x9C, B-context byte still distinguishes subtests.

**Read-error branch explicitly out of scope.** The fourth branch (`fileio_abort_read_error`,
fired on BDOS_READ_SEQ rc >= 2 mid-load) has no iz-cpm-controllable trigger from a fixture
filesystem (iz-cpm-emulated CP/M's BDOS surfaces successful reads on any fixture file; we
cannot synthesize a mid-read rc>=2). The structural argument from deferred-work.md L499
applies: all four non-no-arg branches converge on bypassing `fileio_load_initial.no_arg`, and
the three driveable branches plus the 0xAA poison are sufficient to pin the contract. The
read-error path stays under hardware-UAT coverage (real BIOS read failures) + the structural
grep-based assertion in Dev Notes (no `LD (welcome_active), A` outside `.no_arg`).

**AC3 — AC4 `:e empty.txt` FR6 round-trip pinned headlessly.**

**Given** Story 4.2 AC4 names three production paths that return `file_length` to 0:
`dd` on a 1-line buffer (FR29), `:e empty.txt` (FR6), `:e!`; the existing
`welcome_does-not-redraw-after-dismiss.asm` exercises the `dd` path (Op 5) but NOT the
`:e empty.txt` BDOS round-trip
**When** Story 4.3 lands
**Then** a new headless test `welcome_active-survives-e-empty-txt.asm` exercises the
`:e empty.txt` path end-to-end:

1. Pre-state: simulate post-dismissal by setting `welcome_active = 0xAA` (poison, NOT 0 — so
   any writer that touches the flag during `:e empty.txt` is detected, not just writers-of-1)
2. Pre-populate `filename_buffer` with `"B:EMPTY.TXT\0"` and `fcb_scratch` with drive=2 +
   "EMPTY   TXT" — same scaffolding as `test/cases/fileio_save-empty-buffer.asm:54-67`
3. Call `fileio_load` directly (NOT `fileio_load_initial` — we want the `:e`-equivalent path,
   not the launch path which routes to `.no_arg` for `DEFAULT_FCB+1==' '`)
4. Assert post-conditions:
   - `welcome_active == 0xAA` (the poison survived; no writer touched it)
   - `file_length == 0` (the empty file loaded; gap_start == GAP_BUFFER_BASE, gap_end ==
     GAP_BUFFER_BASE + GAP_BUFFER_MAX — `fileio_load_after_open` Stage 2 calls `gapbuf_init`,
     identical post-state to `dd`-on-1-line's Op 5 in the existing AC4 regression net)
   - `status_buffer` prefix == `"B:EMPTY.TXT 0 bytes"` (the load-success banner per Story 2.2
     AC9 — confirms the BDOS round-trip succeeded; this distinguishes the test from a path
     that accidentally takes `.abort_too_large` or `.abort_read_error` despite the file being
     well-formed). *Exact banner format pinned by Story 2.2 status-funnel convention; if
     `make test` reports `B:EMPTY.TXT` mismatch, recover the canonical banner from
     `fileio_save-empty-buffer.asm:194` for the 0-bytes-written variant or from the load-side
     equivalent in `fileio_load-*` tests.*

Sentinel 0x9E (reuses Story 4.2 T4 — semantic match: "welcome_active survives a buffer-empty
operation"), B-context 0x10 distinguishes this file's subtest from the existing T4 file's
subtests 0x01-0x07.

**AC4 — `test/fixtures/EMPTY.TXT` fixture made stable across `make clean && make test`.**

**Given** `test/fixtures/EMPTY.TXT` is git-tracked but `test/Makefile`'s `clean:` recipe
line 109 explicitly rm's it (because `fileio_save-empty-buffer.asm` is a save-side test that
creates EMPTY.TXT as its output; the rm ensures save-test determinism), so a fresh
clone-then-`make clean && make test` cycle leaves AC3's new load-side test without its
required fixture between the rm and the moment the save test recreates it
**When** Story 4.3 lands
**Then** `test/Makefile` is amended to add `fixtures/EMPTY.TXT` to the `$(FIXTURES)`
generated-target list with an explicit recipe that produces a deterministic 1-sector empty
file (byte 0 = 0x1A, bytes 1..127 = 0x20) BEFORE any `cases/*.com` runs. Recipe template
(mirrors the existing `fixtures/eof1a.txt` / `fixtures/big.bin` recipes' style):

```makefile
# Story 4.3: 1-sector empty file for the :e empty.txt round-trip test
# (test/cases/welcome_active-survives-e-empty-txt.asm). Byte 0 = 0x1A
# (CP/M soft-EOF), bytes 1..127 = 0x20 (sector padding). Matches the
# on-disk shape that fileio_save would write for a 0-byte buffer per
# Story 2.4 AC12.
fixtures/EMPTY.TXT:
\tprintf '\032' > $@
\tprintf '%127s' '' >> $@
```

**And** `test/Makefile`'s `clean:` recipe still rm's `fixtures/EMPTY.TXT` — the recipe at
$(FIXTURES) regenerates it on the next `make test` regardless of which test runs first.
**And** the test ordering dependency (was: save-test must run before load-test alphabetically)
is **broken**: the load-side test now depends on `$(FIXTURES)` which builds before any
`cases/%.com` per the `test: $(COMS) $(FIXTURES)` rule at `test/Makefile:80`.

**AC5 — 0 B production-code delta + NFR18 byte-identical rebuild trivially held.**

**Given** Story 4.3 is test-only by construction
**When** `make sizes` is captured before and after Story 4.3 lands
**Then** `vibe.com` size is **byte-identical** to the post-4.2 baseline of 8562 B / 83.6% /
1678 B headroom (no `src/*.asm` or `inc/*.{asm,inc}` files modified)
**And** NFR18 SHA-256 of `vibe.com` matches the post-4.2 binding SHA
`cfeaf4c654e09f458387e33c6557af536daa8514f8ab2af6d5c412e640a6f81a`. Recorded in the Dev Agent
Record / Completion Notes List for regression reference.

**AC6 — `make test` pass count grows by exactly the number of new test files (7), every new
case PASSes, no existing case regresses.**

**Given** Story 4.2's post-merge `make test` shipped 272 pass / 1 deliberate-fail
**When** Story 4.3 lands
**Then** `make test` reports `(272 + 7) = 279 pass / 1 deliberate-fail` — i.e.:
- 4 new dismissal-key replicas (AC1) all PASS
- 2 new AC2 sibling tests (AC2) both PASS
- 1 new `:e empty.txt` survival test (AC3) PASSes
- Existing `init_welcome-hidden-with-arg.asm` (modified by AC2 to use 0xAA poison) continues
  to PASS
- The 1 deliberate-fail count (from `test/cases/deliberate-fail.asm` or equivalent) is
  unchanged — Story 4.3 introduces no new deliberate-fail cases
**And** no other case's PASS/FAIL state changes. If any pre-existing case regresses, stop
and investigate before commit — Story 4.3's 0 B production-code-delta means the only thing
that COULD regress an existing case is the EMPTY.TXT recipe accidentally changing the on-disk
shape, which would surface in the save-test's verification chain. The save-test creates its
own EMPTY.TXT and verifies byte-by-byte regardless of pre-state, so this is a no-op risk in
practice, but worth checking.

**AC7 — Hardware UAT NOT required.**

**Given** Story 4.3 has 0 B production-code delta (test-only) and the welcome-screen runtime
behaviour is unchanged from Story 4.2 (which already passed hardware UAT)
**When** Story 4.3 is offered for review
**Then** the standard 14-step hardware UAT script from Story 4.2 is **NOT re-run** — there
is no production code to validate on real MicroBeast hardware. The headless `make test`
PASS-count delta + the NFR18 SHA match are the binding acceptance signals. Document in the
Dev Agent Record that hardware UAT is intentionally skipped per AC7 (mirror the no-UAT
pattern from any prior pure-refactor / pure-test stories).

**AC8 — Deferred-work.md L496-L498 marked CLOSED-by-4.3 inline.**

**Given** the three triage entries at `deferred-work.md` lines 498-500 are the source
deferrals being addressed by this story
**When** Story 4.3 lands
**Then** all three entries are annotated in-place with `**CLOSED by Story 4.3 (AC<n>)**`
matching the existing convention (compare e.g. line 488 "CLOSED by Story 4.1 (AC4...)"):
- L498 — AC3 inlined-replica-only → CLOSED by Story 4.3 (AC1)
- L499 — AC2 .new_file-only → CLOSED by Story 4.3 (AC2)
- L500 — AC4 :e empty.txt FR6 round-trip → CLOSED by Story 4.3 (AC3 + AC4)

## Tasks / Subtasks

- [x] **Task 0 — Cross-check + Q-pin resolution (per [[feedback_create_story_cross_check]])**
  - [x] 0.1 Verify post-4.2 baseline: `make sizes` reports `vibe.com = 8562 B / 83.6% / 1678 B
    headroom`; `sha256sum build/vibe.com` matches the binding SHA
    `cfeaf4c654e09f458387e33c6557af536daa8514f8ab2af6d5c412e640a6f81a`. If drift, stop and
    investigate (Story 4.3 is test-only; pre-state must be the shipped 4.2 binary).
  - [x] 0.2 Resolve open Implementation Questions Q1-Q3 (see "Implementation Questions"
    section below). All three have recommended defaults pinned by the story author; flag any
    Ant-side disagreement before authoring tests.
  - [x] 0.3 Confirm the post-4.2 `make test` baseline is 272 pass / 1 deliberate-fail — this
    is the pre-state Story 4.3's AC6 measures against.

- [x] **Task 1 — AC1: 4 dismissal-key replica tests** (AC: #1)
  - [x] 1.1 Copy `test/cases/welcome_dismissed-on-first-key.asm` to
    `welcome_dismissed-on-first-key-esc.asm`. Change the file-header comment block to
    name the Esc variant. Rebind:
    - Line 87 preamble: `LD A, 'i'` → `LD A, 0x1B   ; Esc / ASCII ESC`
    - Subtest 6 comparison: `CP 'i'` → `CP 0x1B`
    - Subtest 6 sentinel-context comment: name the new key
    - Sentinel byte stays 0x9D (reused; AC1 sentinel-reuse rule). B-context bytes 0x01-0x06
      unchanged.
  - [x] 1.2 Same pattern for `welcome_dismissed-on-first-key-ctrl-l.asm`: key byte = 0x0C.
  - [x] 1.3 Same pattern for `welcome_dismissed-on-first-key-colon.asm`: key byte = `':'`
    (0x3A).
  - [x] 1.4 Same pattern for `welcome_dismissed-on-first-key-digit.asm`: key byte = `'5'`
    (0x35). The file-header comment should call out that the parser-digit absorption itself
    is hardware-UAT-only — this test only pins the dismissal-hook key-preservation for the
    digit byte, not the post-dispatch `parser_accumulate_digit` behaviour.
  - [x] 1.5 `make test`; verify all 4 new cases PASS. If any FAIL, the most likely cause is
    a typo in the key-byte rebinding (assert the file-header comment, preamble, and CP
    comparison are all consistent).

- [x] **Task 2 — AC2: 0xAA-poison hardening + 2 new sibling tests** (AC: #2)
  - [x] 2.1 Modify `test/cases/init_welcome-hidden-with-arg.asm` to use 0xAA poison instead
    of 0 pre-clear:
    - Line 62 `LD (welcome_active), A` (writes 0 — `A` is 0 from line 56's `XOR A`) → replace
      with `LD A, 0xAA ; LD (welcome_active), A` (re-clears A to 0 afterwards with
      `XOR A` if needed by subsequent setup, OR re-orders the FCB-zero block to come first
      then the poison store last so A's value at the poison-store doesn't perturb downstream
      setup).
    - Subtest 1 (line 97-103): `OR A ; JR Z, .ok_active_zero` → `CP 0xAA ; JR Z,
      .ok_active_poison_survived`. Update the label name + the file-header subtest-0x01
      comment to read `welcome_active != 0xAA (filename-arg path TOUCHED the flag — a
      writer wrote 0 OR a different value; the structural invariant 'only .no_arg writes
      welcome_active' is broken)`. B-context byte 0x01 unchanged.
  - [x] 2.2 Create `test/cases/init_welcome-hidden-load-success.asm`. Pattern:
    - Copy `init_welcome-hidden-with-arg.asm` post-hardening (2.1).
    - Replace the `NOSUCH.FS` FCB population with `HELLO   TXT` (8-byte basename
      space-padded "HELLO   ", 3-byte ext "TXT", drive byte 0 → B:).
    - `fileio_load_initial` will take the parse → open-success → load-after-open path; on
      `fixtures/hello.txt` (13 B) the load completes successfully and `status_set_message`
      writes the `B:HELLO.TXT 13 bytes` banner.
    - Sentinel 0x9C reused. B-context 0x01 = welcome_active poison touched; B-context 0x02
      = filename_buffer not preserved (mirrors existing subtest 2 — Story 2.3 AC4
      regression-pin survives across the new branch).
  - [x] 2.3 Create `test/cases/init_welcome-hidden-too-large.asm`. Pattern:
    - Copy `init_welcome-hidden-with-arg.asm` post-hardening (2.1).
    - Replace the FCB filename with `BIG     BIN` (8-byte "BIG     ", 3-byte "BIN").
    - `fileio_load_initial` takes parse → open-success → `fileio_load_after_open` → load-loop
      `.abort_too_large` (the pre-read budget check fires after sector 256). `welcome_active`
      MUST stay at 0xAA across the entire path including the abort.
    - Add a subtest 3 that asserts `status_buffer` prefix contains `"file too large"` (the
      `msg_file_too_large` banner per `src/statusln.asm:319`) — this distinguishes the test
      from a path that accidentally succeeds OR takes a different abort branch. B-context
      0x03 = status banner mismatch.
  - [x] 2.4 `make test`; verify both new cases + the modified existing case all PASS.

- [x] **Task 3 — AC3 + AC4: `:e empty.txt` round-trip test + EMPTY.TXT fixture recipe** (AC:
  #3, #4)
  - [x] 3.1 Amend `test/Makefile` per AC4:
    - Add `fixtures/EMPTY.TXT` to the `$(FIXTURES)` list at line 53.
    - Add the recipe block immediately after the `fixtures/big.bin:` recipe at line 74-75:

      ```makefile
      # Story 4.3: 1-sector empty file for the :e empty.txt round-trip test
      # (test/cases/welcome_active-survives-e-empty-txt.asm). Byte 0 = 0x1A
      # (CP/M soft-EOF), bytes 1..127 = 0x20 (sector padding). Matches the
      # on-disk shape that fileio_save would write for a 0-byte buffer per
      # Story 2.4 AC12.
      fixtures/EMPTY.TXT:
      	printf '\032' > $@
      	printf '%127s' '' >> $@
      ```

      *Indentation: the recipe lines MUST use TABs (Make requirement). Use a TAB character,
      not 4 spaces. The story renders this with TAB-equivalent leading whitespace; copy the
      actual TAB from an existing recipe in the same Makefile to be safe.*
    - The `clean:` recipe at line 109 already rm's `fixtures/EMPTY.TXT` — leave that line
      unchanged. The `$(FIXTURES)` dependency rebuilds the fixture on the next test run.
  - [x] 3.2 Verify the new recipe works in isolation: `cd test && make clean && make
    fixtures/EMPTY.TXT && od -An -c -N4 fixtures/EMPTY.TXT` should show
    `\032          ` (byte 0 = SUB / 0x1A, bytes 1-3 = spaces). Confirm `wc -c
    fixtures/EMPTY.TXT` reports 128.
  - [x] 3.3 Create `test/cases/welcome_active-survives-e-empty-txt.asm`:
    - Template from `test/cases/fileio_save-empty-buffer.asm` (for the FCB scaffolding +
      BDOS-aware structure) merged with `welcome_does-not-redraw-after-dismiss.asm` (for the
      0xAA poison pattern).
    - Pre-state: `welcome_active = 0xAA` (poison), `mode_byte = 0`, `init_teardown_called =
      0`, `filename_buffer = "B:EMPTY.TXT\0"` (12 B via LDIR), `fcb_scratch` populated with
      drive=2 + "EMPTY   TXT" basename/ext (mirror lines 60-67 of the save test).
      `gapbuf_init` called so gap starts empty.
    - Body: `CALL fileio_load` (NOT `fileio_load_initial` — we want the `:e`-equivalent path
      that takes filename + FCB from `filename_buffer`/`fcb_scratch`, not the launch path
      that takes from `DEFAULT_FCB`).
    - Subtest 1 (0x01): `welcome_active == 0xAA` — the poison survived (fileio_load never
      touches welcome_active per the AC4 structural invariant).
    - Subtest 2 (0x02): `gap_start == GAP_BUFFER_BASE` AND `gap_end == GAP_BUFFER_BASE +
      GAP_BUFFER_MAX` — the empty file loaded cleanly; file_length=0.
    - Subtest 3 (0x03): `status_buffer` prefix matches `"B:EMPTY.TXT "` (12 chars — the
      success banner's filename prefix; the byte-count portion will be `"0"` followed by
      `" bytes"` per the Story 2.2 / 2.4 banner format; check just the prefix to keep the
      assertion robust against banner-format detail changes).
    - Sentinel 0x9E reused. B-context 0x10/0x11/0x12 for subtests 1/2/3 — picked above the
      existing 4.2 T4 subtests (0x01-0x07) to avoid collision when both files report failures
      in the same test run.
    - Include block: mirror `welcome_does-not-redraw-after-dismiss.asm`'s production-code
      INCLUDE chain + the `test_bios_conout_capture.inc` override (fileio_load doesn't emit
      to BIOS on the empty-file load path, but the status_set_message that fires at success
      writes to status_buffer and may trigger a render path under future stories;
      defensively override).
    - **CRITICAL:** the `BIOS_CONOUT_OVERRIDE` define MUST come BEFORE `INCLUDE
      "../../inc/bios.inc"` — see the welcome_does-not-redraw-after-dismiss.asm lines 95-97
      for the exact pattern. Getting the order wrong silently emits to stdout and breaks the
      PASS/FAIL grep with terminal escape junk.
  - [x] 3.4 `make test`; verify the new case PASSes. Common failure modes to check first:
    - **Harness reports "unknown" for this case (no PASS/FAIL token emitted)**: most likely
      cause is the `fixtures/EMPTY.TXT` fixture not built — BDOS_OPEN funnel fires → `JP
      input_loop` stub → `BDOS_EXIT` terminates without writing the sentinel byte. Verify with
      `ls -la test/fixtures/EMPTY.TXT` (expect 128 bytes); rebuild explicitly via
      `make fixtures/EMPTY.TXT`.
    - `0x9E B=0x10`: welcome_active touched — investigate whether a future writer was added
      to fileio_load; grep `LD (welcome_active),` against `src/*.asm` (expected 2 hits:
      `src/fileio.asm` `.no_arg`, `src/vibe.asm` `input_loop` hook).
    - `0x9E B=0x11`: gap_end / gap_start drift — likely an EMPTY.TXT shape mismatch;
      re-verify the fixture with `od -An -c fixtures/EMPTY.TXT | head -1`.
    - `0x9E B=0x12`: status_buffer prefix mismatch — could be a banner-format drift; capture
      the actual `status_buffer` first 32 bytes via a temporary assertion and adjust the
      prefix to match.
    - `0x9E B=0x13`: test_capture_len != 0 — a BIOS_CONOUT emit fired during the load path
      (either a new writer was added OR `bdos_error_funnel` fired on a sign-bit BDOS error).
      Check the captured bytes in `test_capture_buffer` to identify the emit source.

- [x] **Task 4 — AC5 + AC6: NFR9 / NFR18 / make-test regression check** (AC: #5, #6)
  - [x] 4.1 `make clean && make all`; capture `vibe.com` SHA-256 — MUST match
    `cfeaf4c654e09f458387e33c6557af536daa8514f8ab2af6d5c412e640a6f81a`. If it differs, an
    accidental edit to a `src/*.asm` or `inc/*.{asm,inc}` file slipped in; revert and
    re-verify.
  - [x] 4.2 `make sizes`; capture the listing verbatim. MUST be byte-identical to the
    post-4.2 baseline (8562 B / 83.6% / 1678 B headroom). Record in Completion Notes List.
  - [x] 4.3 `make test`; capture the per-case PASS/FAIL summary. MUST report `279 pass /
    1 fail` (272 pre-existing + 7 new). If the count is lower OR any existing case
    regresses, stop and investigate per AC6.

- [x] **Task 5 — AC8: Annotate deferred-work.md** (AC: #8)
  - [x] 5.1 In `_bmad-output/implementation-artifacts/deferred-work.md`, locate the three
    triage-referenced entries:
    - L498 (AC3 inlined-replica-only)
    - L499 (AC2 .new_file-only)
    - L500 (AC4 :e empty.txt FR6 round-trip)
    Add `**CLOSED by Story 4.3 (AC1)**` / `(AC2)` / `(AC3 + AC4)` annotations matching the
    existing convention (compare e.g. line 488's "CLOSED by Story 4.1 (AC4 — 2026-05-19)").
  - [x] 5.2 Add the closure date and a one-line shape: "fileset: 4 dismissal-key replicas
    + 2 AC2 sibling tests + 1 :e empty.txt survival test + EMPTY.TXT Makefile recipe.
    0 B production-code delta; NFR18 byte-identical."
  - [x] 5.3 If the triage doc `deferred-work-triage-2026-05-19.md` is still on the working
    tree (it's the source of this story), leave it untouched — it's the historical snapshot
    that scoped the work, not a living deferred-work record.

- [x] **Task 6 — Commit + close** (Q3-recommended Option A: single commit covering all 7
  new tests + 1 modified test + Makefile recipe + deferred-work.md annotations)
  - [x] 6.1 Stage all modified/new files for the 4.3 commit:
    - `test/cases/welcome_dismissed-on-first-key-esc.asm` (new)
    - `test/cases/welcome_dismissed-on-first-key-ctrl-l.asm` (new)
    - `test/cases/welcome_dismissed-on-first-key-colon.asm` (new)
    - `test/cases/welcome_dismissed-on-first-key-digit.asm` (new)
    - `test/cases/welcome_dismissed-on-first-key.asm` (modified — code-review F1 patch:
      stale `src/vibe.asm:228-244` → `:276-284` citation)
    - `test/cases/init_welcome-hidden-with-arg.asm` (modified — 0xAA poison)
    - `test/cases/init_welcome-hidden-load-success.asm` (new)
    - `test/cases/init_welcome-hidden-too-large.asm` (new)
    - `test/cases/welcome_active-survives-e-empty-txt.asm` (new)
    - `test/cases/welcome_does-not-redraw-after-dismiss.asm` (modified — Op 5 rewrite +
      Op 6 shadow-poison from Story 4.2 review patch D1; co-located here per the File
      List provenance note above)
    - `test/Makefile` (modified — EMPTY.TXT recipe + clean-rule dedup)
    - `_bmad-output/implementation-artifacts/deferred-work.md` (modified — 3 closure
      annotations + 5 code-review deferrals)
    - `_bmad-output/implementation-artifacts/4-3-welcome-screen-test-coverage-hardening.md`
      (the story file itself — Dev Agent Record + Completion Notes + Review Findings filled in)
    - `_bmad-output/implementation-artifacts/sprint-status.yaml` (status: ready-for-dev →
      review → done after acceptance)
    - **EXCLUDED from this commit** (split per code-review decision item 2):
      `_bmad-output/implementation-artifacts/4-2-welcome-screen-on-no-argument-launch.md`
      — see Task 6.4.
  - [x] 6.2 Commit message: `Story 4.3: welcome-screen test-coverage hardening — closes
    L498/L499/L500` (matches Story 4.2's style; mentions the deferred-work line numbers for
    grep-traceability).
  - [x] 6.3 Update sprint-status.yaml: flip `4-3-welcome-screen-test-coverage-hardening`
    from `ready-for-dev` to `review` after dev pass; flip to `done` after Ant accepts (no
    hardware UAT cycle required per AC7 — the headless make-test PASS-count + NFR18 SHA
    match are the binding signals).
  - [ ] 6.4 **After the 4.3 commit lands**, create a separate follow-up commit for the
    Story 4.2 post-merge review-pass artifacts (decision item 2 of code review 2026-05-19):
    - Stage ONLY `_bmad-output/implementation-artifacts/4-2-welcome-screen-on-no-argument-launch.md`
      (the retroactive Review Findings section + AC1/AC3/AC6/AR13 narrative amendments + SHA
      reconciliation table).
    - Commit message suggestion: `Story 4.2 review-pass: post-merge findings, AR13/AC1/AC3/AC6
      amendments, SHA reconciliation (→ tests landed in 4.3 commit <4.3-SHA>)`.
    - The 4.2 spec doc thus gets its own grep-traceable commit attribution — keeps the 4.3
      commit narrowly scoped to its declared File List + the bundled D1 patch.

## Dev Notes

### Architecture compliance

**This is a TEST-ONLY story — 0 B production-code delta. The architecture invariants below
are listed not as new commitments but as guards: any drift from them during the dev pass
means Story 4.3 has accidentally become a production-code story and the AC5 / AC6 contract
breaks.**

- **AR12-AR15, AR23, AR25 (production-code invariants):** UNCHANGED. No `src/*.asm` or
  `inc/*.{asm,inc}` file is edited by Story 4.3. Tests are AR-exempt by convention (`test/`
  is outside the AR perimeter).
- **MC1, MC4, MC5, MC7 (handler / status / state invariants):** UNCHANGED. The new tests
  drive existing production entry points (`fileio_load`, `fileio_load_initial`,
  `status_set_message`, `gapbuf_init`) and assert on existing state fields
  (`welcome_active`, `gap_start`, `gap_end`, `file_length`, `status_buffer`,
  `filename_buffer`).
- **RI1-RI4 (render invariants):** UNCHANGED — no test in Story 4.3 calls `render_diff` or
  `render_full`. The 4 dismissal-key replicas DO call `render_mark_all_dirty` (via the
  inline dismissal-hook replica in each test body), but the assertion is on `dirty_rows`
  byte values, not on emitted output. Each test overrides `BIOS_CONOUT` via
  `test_bios_conout_capture.inc` defensively (matches the welcome-family convention).
- **NFR1, NFR3, NFR5, NFR9, NFR18 (runtime / size invariants):** UNCHANGED. NFR9 has 0 B
  delta; NFR18 SHA-256 of `vibe.com` MUST match the pre-Story-4.3 binding SHA
  `cfeaf4c654e09f458387e33c6557af536daa8514f8ab2af6d5c412e640a6f81a`. NFR3 cursor latency
  is irrelevant (tests are host-time, not real-hardware T-states).
- **Test convention TH1 (sentinel-byte signal):** test_prologue.inc pre-zeros 0xCFFE;
  test_pass sets 0xCFFE=0xAA / test_fail sets 0xCFFE=A (passed-in sentinel). All new tests
  follow this convention. Story 4.3 sentinel-reuse rule (AC1): no new sentinel bytes
  introduced; 0x9C / 0x9D / 0x9E reused per the AC1/AC2/AC3 sentinel-reuse rationale.
- **Test convention TH3 (fixture filesystem):** iz-cpm mounts `test/fixtures/` as drive B:
  (also drive A:, per test/Makefile:84). All test FCBs use drive byte = 2 (B:). Fixtures
  used by Story 4.3: `HELLO.TXT` (already present, 13 B), `BIG.BIN` (already in `$(FIXTURES)`
  via existing `fixtures/big.bin:` recipe, 33792 B), `EMPTY.TXT` (added in AC4, 128 B).

### Files this story modifies (and what to preserve)

**`test/Makefile`** (currently 110 lines):
- AMEND line 53 `$(FIXTURES) := ...` to include `fixtures/EMPTY.TXT`.
- ADD a new recipe block after the `fixtures/big.bin:` recipe (after line 75) per AC4 / Task
  3.1. The recipe MUST use literal TAB characters (Make requirement), not spaces.
- PRESERVE: every other line of the Makefile. The `clean:` recipe at line 109 already rm's
  `fixtures/EMPTY.TXT` — leave that unchanged; the new `$(FIXTURES)` dependency rebuilds it
  on demand.
- PRESERVE: the `PROD_SRC := $(wildcard ../src/*.asm)` dep (line 46) — this is what makes
  the harness rebuild all tests on any src/ change; Story 4.3 doesn't touch src/ but the
  dep must remain.

**`test/cases/init_welcome-hidden-with-arg.asm`** (currently 141 lines):
- MODIFY the pre-state setup (lines 56-63) per Task 2.1 — switch from
  `welcome_active = 0` pre-clear to `welcome_active = 0xAA` poison.
- MODIFY Subtest 1 (lines 97-103) per Task 2.1 — switch from `OR A ; JR Z` to
  `CP 0xAA ; JR Z`. Update the label name + file-header comment for subtest 0x01.
- PRESERVE: every other line. The subtest 2 (filename_buffer preserved across the
  `.new_file` path) is a Story 2.3 AC4 regression-pin that must continue to work — do NOT
  change the FCB population, the `CALL fileio_load_initial`, or the subtest-2 assertion.

**`_bmad-output/implementation-artifacts/deferred-work.md`** (currently ~500 lines):
- AMEND the three entries at lines 498, 499, 500 per AC8 / Task 5. Add
  `**CLOSED by Story 4.3 (AC<n>)**` inline, matching the convention used by lines 12 / 487 /
  etc.
- PRESERVE: the rest of the file UNCHANGED.

**NEW FILES** (7 test cases):
- `test/cases/welcome_dismissed-on-first-key-esc.asm`
- `test/cases/welcome_dismissed-on-first-key-ctrl-l.asm`
- `test/cases/welcome_dismissed-on-first-key-colon.asm`
- `test/cases/welcome_dismissed-on-first-key-digit.asm`
- `test/cases/init_welcome-hidden-load-success.asm`
- `test/cases/init_welcome-hidden-too-large.asm`
- `test/cases/welcome_active-survives-e-empty-txt.asm`

Every new test file follows the standard layout enforced by the harness:
1. Pre-ORG production headers (equates.inc, bios.inc, bdos.inc, modes.inc, vt52.inc) — with
   `DEFINE BIOS_CONOUT_OVERRIDE` before bios.inc where a capture stub is needed
2. `INCLUDE "../inc/test_prologue.inc"` (ORG 0x0100, sentinel pre-zero, test_start label)
3. Test body — pre-state setup, `CALL <production_entry>`, per-subtest CP+JR Z assertions
4. `INCLUDE "../inc/test_teardown_stub.inc"` (LOCAL init_teardown stub)
5. `INCLUDE "../inc/test_input_loop_stub.inc"` (LOCAL input_loop stub — required for any
   test that doesn't define its own input_loop, otherwise sjasmplus errors on the dangling
   forward reference from src/init.asm Stage 7)
6. `INCLUDE "../inc/test_epilogue.inc"` (test_pass / test_fail labels)
7. Production INCLUDE chain in AR25 order: statusln → gapbuf → render → welcome → dispatch
   → parser → motions → edits → visual → search → exline → fileio → undo
8. `INCLUDE "../../inc/state.inc"` LAST (state.inc declares the EQUs the production code
   references; placing it last lets sjasmplus resolve forward EQU references on the second
   pass)

Cross-reference `test/cases/welcome_dismissed-on-first-key.asm` (lines 54-183) and
`test/cases/welcome_does-not-redraw-after-dismiss.asm` (lines 91-283) for the canonical
layout — every new test in Story 4.3 mirrors one or the other.

### Implementation choices and trade-offs

**Choice 1 (Q1): AC2 read-error branch — skip vs attempt vs synthetic fixture.**
- **Recommended (and adopted): skip.** No iz-cpm-controllable way to surface a mid-read
  BDOS rc >= 2 from a fixture filesystem. The structural argument (all non-no-arg branches
  bypass `.no_arg`) + the 0xAA poison on the 3 driveable branches is sufficient. Hardware
  UAT on real BIOS retains coverage of the read-error path's display behaviour.
- Alternative (rejected): write a custom iz-cpm-faulting BDOS shim. Way out of scope for a
  test-only story; tooling complexity dominates value.

**Choice 2 (Q2): AC1 4 dismissal-key replicas — 4 separate files vs 1 parameterized table.**
- **Recommended (and adopted): 4 separate files.** Matches existing convention (every
  `test/cases/*.asm` is a single-scenario test; failures surface as a clearly-named PASS/FAIL
  line). The duplication cost is real (~150 lines × 4 = ~600 lines of near-identical .asm)
  but the readability + grep-friendliness wins dominate.
- Alternative (rejected): a single `welcome_dismissed-key-table.asm` with a 5-entry table of
  (key_byte, expected_post_state) iterating through all 5 keys. Saves ~450 lines of
  duplication but a single failure surfaces only as `0x9D B=<subtest_idx>` and the dev has
  to map the index back to a key. Less ergonomic; rejected.

**Choice 3 (Q3): single commit vs split per-AC.**
- **Recommended (and adopted): single commit.** Matches Story 4.1 / 4.2's pattern (large
  bundled commit with the full story body). Test-only commits don't need per-AC bisect
  granularity (no production-code regression risk to isolate). One commit per story
  simplifies the deferred-work annotation pass too — single SHA to reference in the
  CLOSED-by line.
- Alternative (rejected): 3 commits (one per AC1/AC2/AC3+AC4). Adds noise to the git log
  without buying meaningful isolation.

### Implementation Questions (resolve with Ant before dev starts)

All three Qs have story-author-recommended defaults; flagged here for an Ant pre-pass check
in case the team's preference differs.

**Q1: AC2 read-error branch — skip per Choice 1 above?** Recommended: yes. The
deferred-work entry at L499 explicitly accepts the structural argument; Story 4.3 takes that
at face value.

**Q2: AC1 4 replicas as separate files per Choice 2 above?** Recommended: yes. If the team
prefers a single parameterized file for code-volume reasons, the trade-off is one less PASS
line in the harness output per dismissal-key variant.

**Q3: Single commit per Choice 3 above?** Recommended: yes. Matches the Epic-3/4 pattern.

### NFR9 budget arithmetic (worked example)

**N/A — Story 4.3 has 0 B production-code delta.** Pre-baseline = post-baseline = 8562 B /
83.6% / 1678 B headroom. AC5 explicitly asserts this; AC6 measures regression via NFR18 SHA
match.

### Test count target

**Pre-Story-4.3 baseline:** 272 pass / 1 deliberate-fail (from Story 4.2's commit `1c9e759`
Completion Notes).

**Post-Story-4.3 target:** 279 pass / 1 deliberate-fail. Delta = +7 PASSes (4 from AC1,
2 from AC2, 1 from AC3). Zero deletions; zero failures introduced.

If `make test` reports a different count, investigate before commit:
- Lower pass-count (e.g. 278): one of the 7 new tests is FAILing; check the FAIL line for
  sentinel + B-context byte and consult Task-3.4's known-failure-mode list.
- Higher pass-count (e.g. 280): an existing test that was FAILing pre-4.3 is now PASSing —
  highly unusual since Story 4.3 changes no production code; investigate but likely benign.
- Existing case regresses (e.g. `fileio_save-empty-buffer.asm` FAILing post-4.3): the
  EMPTY.TXT Makefile recipe is the only realistic source — verify byte 0 = 0x1A and byte
  count = 128 via `od`.

### Project Structure Notes

- All test files live under `test/cases/` per existing convention. Story 4.3 introduces
  ZERO new top-level directories or `.asm` files outside `test/cases/`.
- The `test/Makefile` glob `cases/*.asm` (line 36) picks up new tests automatically — no
  hand-curated test list to maintain.
- The `$(PROD_SRC)` / `$(PROD_INC)` deps (lines 46-47) ensure tests rebuild if any
  src/inc/ file changes. Story 4.3 doesn't change those files but the dep stays as the
  general protection.
- The `clean:` recipe (line 109) already rm's `fixtures/EMPTY.TXT` along with the other
  test-output artifacts. The new `$(FIXTURES)` dependency on `fixtures/EMPTY.TXT` ensures
  the file is rebuilt on the next `make test` regardless of which test runs first.

### References

- Source deferrals: `_bmad-output/implementation-artifacts/deferred-work.md`:498-500 (the
  "Deferred from: code review of 4-2-welcome-screen-on-no-argument-launch (2026-05-19)"
  block).
- Triage scoping: `_bmad-output/implementation-artifacts/deferred-work-triage-2026-05-19.md`
  Theme C (lines 151-173) — the recommended-first-pick story.
- Story 4.2 implementation: `_bmad-output/implementation-artifacts/4-2-welcome-screen-on-no-argument-launch.md`
  AC1/AC2/AC3/AC4 narratives + Tasks 7-8 (the existing test files Story 4.3 hardens).
- Template tests (copy + adapt):
  - `test/cases/welcome_dismissed-on-first-key.asm` (AC1 4 replicas)
  - `test/cases/init_welcome-hidden-with-arg.asm` (AC2 2 siblings + the modification target)
  - `test/cases/fileio_save-empty-buffer.asm` (AC3 — drive-B FCB scaffolding pattern)
  - `test/cases/welcome_does-not-redraw-after-dismiss.asm` (AC3 — 0xAA poison pattern + BIOS
    capture stub override pattern)
- Production entry points exercised by the new tests:
  - `src/vibe.asm:250-298` (input_loop + dismissal hook — AC1 inline replicas)
  - `src/fileio.asm:337-440` (`fileio_load`, `fileio_load_initial`, `fileio_load_after_open`,
    `.abort_too_large`, `.abort_read_error`, `.new_file`) — AC2 + AC3
  - `src/render.asm` (`render_mark_all_dirty`) — AC1 replicas
  - `inc/state.inc:103` (`welcome_active` EQU) — all new tests
- Status banner formats:
  - Load-success: `src/statusln.asm` + `src/fileio.asm` post-load status_set_message call
  - Too-large: `msg_file_too_large` at `src/statusln.asm:319`
  - Empty-load (load side): emits the same `"<filename> N bytes"` banner; for EMPTY.TXT
    the N=0 — confirm exact format from Story 2.2 status convention.

## Hardware UAT script (AC7 — NOT required for this story)

**Story 4.3 is test-only (0 B production-code delta).** No hardware UAT cycle is required.

Per AC7: the binding acceptance signals for Story 4.3 are:
1. `make test` reports `279 pass / 1 fail` on a clean tree (Story 4.2 baseline + 7 new
   PASSes).
2. `sha256sum build/vibe.com` post-4.3 matches the pre-4.3 SHA
   `cfeaf4c654e09f458387e33c6557af536daa8514f8ab2af6d5c412e640a6f81a` (NFR18
   byte-identical).
3. `make sizes` reports `8562 B / 83.6% of 10240 B / 1678 B headroom` unchanged.

If those three signals all hold, Story 4.3 is acceptance-complete without touching MicroBeast
hardware. The welcome-screen runtime behaviour is unchanged from the Story-4.2 hardware-UAT
run on 2026-05-19; this story only widens the headless test net around that already-validated
behaviour.

## Dev Agent Record

### Agent Model Used

`claude-opus-4-7[1m]` (Claude Opus 4.7, 1M context window)

### Debug Log References

None — no debug iterations were needed. All 7 new tests PASSed on first assembly + run; the
modified `init_welcome-hidden-with-arg.asm` continued to PASS after the 0xAA poison
hardening; the EMPTY.TXT fixture recipe produced the expected 128-byte shape on first
invocation. The story's Task-3.4 known-failure-mode list was consulted as a forward-looking
guard but never triggered.

### Completion Notes List

**Pre-state baselines (Task 0):**
- `sha256sum vibe.com` = `cfeaf4c654e09f458387e33c6557af536daa8514f8ab2af6d5c412e640a6f81a` ✓
  (matches the binding SHA pinned by AC5).
- `make sizes` = `code_section: 8562 bytes (~83% of NFR9 10 KB budget)` ✓ (matches the
  post-4.2 baseline).
- `make test` = 272 pass / 1 fail ✓ (matches the AC6 baseline; the 1 fail is the long-standing
  deliberate-fail case).

**Post-state regression gate (Task 4 / AC5 + AC6):**
- `make clean && make all && sha256sum vibe.com` =
  `cfeaf4c654e09f458387e33c6557af536daa8514f8ab2af6d5c412e640a6f81a` ✓ (NFR18 byte-identical
  rebuild verified — no `src/*.asm` or `inc/*.{asm,inc}` file was perturbed).
- `make sizes` = `code_section: 8562 bytes (~83% of NFR9 10 KB budget)` ✓ (byte-identical to
  pre-4.3 baseline; 0 B production-code delta confirmed).
- `make clean && make test` = **279 pass / 1 fail** ✓ (272 baseline + 7 new = 279, exactly
  the AC6 target; the cold-start run confirms the EMPTY.TXT fixture-stability fix per AC4).

**Fixture verification (Task 3.2 / AC4):**
- `wc -c fixtures/EMPTY.TXT` = 128 ✓
- `od -An -c -N4 fixtures/EMPTY.TXT` = ` 032` followed by spaces ✓ (byte 0 = 0x1A SUB =
  CP/M soft-EOF; bytes 1..127 = 0x20 spaces — matches the on-disk shape from Story 2.4 AC12).

**Implementation choices (Q1/Q2/Q3 — recommended defaults adopted as-is):**
- Q1 (read-error branch): skipped per the structural argument; no iz-cpm-controllable
  trigger exists. AC2 closes via 3 driveable branches + 0xAA poison.
- Q2 (4 replicas vs 1 parameterized): 4 separate files (matches per-scenario convention; each
  is ~180 lines, total ~720 lines of near-identical asm — readability + grep-friendliness
  wins over the duplication cost).
- Q3 (single commit): single commit recommended; staging inventory captured in File List
  below; Ant will run the commit.

**Variance from story spec (worth flagging):**
- Task 3.3 / AC3 pre-state setup: the story's spec called for pre-populating `filename_buffer`
  and `fcb_scratch` before `CALL fileio_load`. In practice `fileio_load` itself does the
  parse (Step 1 — `fileio_parse_filename`) and overwrites both, so the pre-population would
  have been wasted. The dev pass followed the existing `fileio_load-small-file.asm`
  convention: pass `HL = .filename_literal`, `A = 9` directly. The 0xAA poison on
  `welcome_active` (the story's actual assertion target) is unaffected, and the post-state
  subtests (0x10 / 0x11 / 0x12) all PASS — so the story's intent is preserved while the
  implementation matches the prevailing test pattern. Documented inline in the new test's
  header for future readers.

### File List

**New test cases (7):**
- `test/cases/welcome_dismissed-on-first-key-esc.asm`
- `test/cases/welcome_dismissed-on-first-key-ctrl-l.asm`
- `test/cases/welcome_dismissed-on-first-key-colon.asm`
- `test/cases/welcome_dismissed-on-first-key-digit.asm`
- `test/cases/init_welcome-hidden-load-success.asm`
- `test/cases/init_welcome-hidden-too-large.asm`
- `test/cases/welcome_active-survives-e-empty-txt.asm`

**Modified files (4):**
- `test/cases/init_welcome-hidden-with-arg.asm` (0xAA poison hardening — subtest 0x01
  assertion + pre-state setup + file-header docs)
- `test/cases/welcome_does-not-redraw-after-dismiss.asm` (Op 5 rewrite: prior misleading
  "defensive welcome_paint" replaced with op_dd-on-1-line + file_length post-check; new Op 6
  shadow-row 0x20 poison sweep across rows 5..17 — from Story 4.2 review patch D1, bundled
  here for AC4 path-coverage hardening since this is the natural co-location of the AC4
  invariant tests. Original 4.2 spec & code-review acknowledged the carryover.)
- `test/Makefile` (added `fixtures/EMPTY.TXT` to `$(FIXTURES)` + new recipe block after
  `fixtures/big.bin:`)
- `_bmad-output/implementation-artifacts/deferred-work.md` (annotated L498/L499/L500 with
  CLOSED-by-Story-4.3 markers per AC8)

**Story-internal (2):**
- `_bmad-output/implementation-artifacts/4-3-welcome-screen-test-coverage-hardening.md`
  (this file — task checkboxes, Dev Agent Record, Change Log filled in)
- `_bmad-output/implementation-artifacts/sprint-status.yaml` (flipped 4-3 entry from
  `ready-for-dev` to `review`; `last_updated` bumped)

**Production code (`src/*.asm` / `inc/*.{asm,inc}`):** untouched. 0 B production-code delta.
NFR18 byte-identical rebuild verified.

### Review Findings

_Code review of 2026-05-19 (Blind Hunter / Edge Case Hunter / Acceptance Auditor — parallel adversarial layers). 28 findings raised, 4 dismissed as noise/verified-false-positive; 24 remain triaged below._

**Decision-needed (3) — RESOLVED 2026-05-19:**

- [x] [Review][Decision→Patch] **Off-list scope leakage: `welcome_does-not-redraw-after-dismiss.asm`** → **Amend 4.3 File List** with provenance. Bundle stays in 4.3 commit; audit trail captured via File List annotation. See patch D1 below.
- [x] [Review][Decision→Patch] **Off-list scope leakage: `4-2-welcome-screen-on-no-argument-launch.md`** → **Split into separate 4.2 review-pass commit**. The 4.2 spec doc mutation will land as its own commit (typically AFTER the 4.3 bundle so it can reference 4.3's SHA in the "→ landed in" annotation). See patch D2 below.
- [x] [Review][Decision→Defer] **Dismissal-key replicas use inline hook copies** → **Defer to follow-up**. Current 5-test post-state coverage + hardware UAT retains the safety net. Appended to `deferred-work.md` as a 5th entry under this story's deferred-from heading.

**Patch (17):**

- [x] [Review][Patch] **Hook line-range citation is stale across all 4 new replicas + the canonical** — replicas comment `;; This mirrors src/vibe.asm:228-244 exactly` but actual hook is at `src/vibe.asm:276-284` (verified). Update the comment in all 5 dismissal-key test files. [`test/cases/welcome_dismissed-on-first-key*.asm` header comment blocks]
- [x] [Review][Patch] **Subtest 0x02 numbering gap in too-large.asm undocumented** — header documents subtests 0x01 and 0x03 but skips 0x02 (intentional: `.abort_too_large` clears filename_buffer[0]). Add `;     0x02 — (intentionally unused — abort_too_large clears filename_buffer[0]; see header)`. [`test/cases/init_welcome-hidden-too-large.asm` header]
- [x] [Review][Patch] **Op 5 calls op_dd without setting mode_byte** — Ops 1-4 don't require a specific mode; Op 5 swaps in a real production-handler call with unspecified mode-dependence. Add `LD A, MODE_NORMAL ; LD (mode_byte), A` before `CALL op_dd`. [`test/cases/welcome_does-not-redraw-after-dismiss.asm` Op 5 setup]
- [x] [Review][Patch] **Op 5 implicitly assumes gap_end preserved across Ops 2-4** — the gap-shape setup depends on `render_mark_all_dirty` / `render_init` / `status_set_message` not touching `gap_end`. Defensively re-init via `CALL gapbuf_init` OR reload `gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX` before Op 5 setup. [`test/cases/welcome_does-not-redraw-after-dismiss.asm` Op 5 setup]
- [x] [Review][Patch] **`welcome_active-survives-e-empty-txt.asm` overrides BIOS_CONOUT but never asserts on capture buffer** — dead-weight defensive override. Either add a subtest 0x13 asserting `test_capture_len == 0` to actually pin "no BIOS emit happened", or drop the override (the file is presently BIOS-quiet). [`test/cases/welcome_active-survives-e-empty-txt.asm`]
- [x] [Review][Patch] **Digit replica is 8 lines longer than its siblings but header claims "identical to canonical"** — legitimate NOTE paragraph about parser_accumulate_digit being hardware-UAT-only. Acknowledge the size delta in the header. [`test/cases/welcome_dismissed-on-first-key-digit.asm` header]
- [x] [Review][Patch] **Stale "in normal mode" qualifier on colon variant header** — comment reads `':' (0x3A — the ex-command-line trigger in normal mode)` but the test's own body comment correctly notes the hook is mode-agnostic + key-agnostic. Self-contradictory; drop the qualifier. [`test/cases/welcome_dismissed-on-first-key-colon.asm` header]
- [x] [Review][Patch] **`LD A, 9` magic number lacks inline meaning** — `A=9` is the length of `"EMPTY.TXT"` (the bare filename literal). Comment currently mixes "length" semantics with FR9 "default drive" narrative. Clarify inline. [`test/cases/welcome_active-survives-e-empty-txt.asm:1659`]
- [x] [Review][Patch] **Op 6 shadow-poison sweep B,L encoding loses offset high byte for offsets ≥256** — sweep covers 1040 cells; B alone wraps. Re-encode failure context as B=row_index (0..12) + C=col_index OR store H separately to TEST_CONTEXT. [`test/cases/welcome_does-not-redraw-after-dismiss.asm` Op 6]
- [x] [Review][Patch] **EMPTY.TXT-missing failure mode reports as harness "unknown"** — if the fixture isn't built, BDOS_OPEN funnel → JP input_loop stub → BDOS_EXIT terminates without PASS/FAIL token. Document "unknown harness output → check `fixtures/EMPTY.TXT` exists" in Task 3.4 known-failure-mode list. [spec doc Task 3.4]
- [x] [Review][Patch] **`status_buffer` not pre-poisoned before `CALL fileio_load`** — subtest 0x12 asserts prefix `"B:EMPTY.TXT "` but TPA residue could spuriously match. Pre-poison `status_buffer` with 0xAB-fill so the prefix match proves `status_set_message` ran. [`test/cases/welcome_active-survives-e-empty-txt.asm` pre-state setup]
- [x] [Review][Patch] **`init_welcome-hidden-load-success.asm` + `init_welcome-hidden-too-large.asm` missing BIOS_CONOUT_OVERRIDE** (verified) — both `INCLUDE "../../inc/bios.inc"` without the override; only the AC3 test has it. On BDOS-regression, funnel emit escapes to stdout and corrupts the harness PASS/FAIL grep. Add `DEFINE BIOS_CONOUT_OVERRIDE` + `BIOS_CONOUT EQU test_bios_conout` before the INCLUDE in both files (mirror `welcome_active-survives-e-empty-txt.asm:92-94`). [2 test files]
- [x] [Review][Patch] **load-success subtest 2 catches only total filename_buffer wipe, not partial corruption** — currently asserts `filename_buffer[0] != 0` only. Tighten to 12-byte prefix match `"B:HELLO.TXT\0"` (mirror e-empty-txt subtest 0x12 pattern). [`test/cases/init_welcome-hidden-load-success.asm` subtest 0x02]
- [x] [Review][Patch] **`CP ':'` / `CP '5'` use character literals; replicas inconsistent** — esc/ctrl-l variants use numeric `CP 0x1B` / `CP 0x0C`; colon/digit use char literals. Convert to numeric for cross-replica consistency + UTF-8-source-drift safety. [`test/cases/welcome_dismissed-on-first-key-{colon,digit}.asm` subtest 6 CP]
- [x] [Review][Patch] **Op 5 uses `count_accumulator = 0` and relies on motion_apply_count's 0→1 default** — if defaulting branch is later removed, op_dd no-ops silently and Op 5b passes spuriously. Pin explicitly: `LD HL, 1 ; LD (count_accumulator), HL`. [`test/cases/welcome_does-not-redraw-after-dismiss.asm` Op 5 setup]
- [x] [Review][Patch] **`fixtures/EMPTY.TXT` listed twice in clean: rule** (verified `test/Makefile:53` + `:124`) — `$(FIXTURES)` already covers it; drop the explicit listing. [`test/Makefile:124`]
- [x] [Review][Patch] **Spec provenance comment cites L496-L498; actual entries are L498-L500** — line 6 of this spec says "Closes deferred entries L496-L498" but AC8 + Task 5.1 + the actual annotations all say L498-L500. Cosmetic doc drift; fix the provenance comment. [this spec file line 6]
- [x] [Review][Patch] **D1 — Amend 4.3 File List with `welcome_does-not-redraw-after-dismiss.asm` provenance** (resolves decision item 1). Add the file under "Modified files" with annotation `modified — Op 5 rewrite (welcome_paint → op_dd-on-1-line + post-check) + Op 6 shadow-row 0x20 poison sweep; from Story 4.2 review patch D1; bundled here for AC4 path-coverage hardening`. [`4-3-welcome-screen-test-coverage-hardening.md` File List section]
- [x] [Review][Patch] **D2 — Amend Task 6.1 staging inventory to split `4-2-welcome-screen-on-no-argument-launch.md` into a separate commit** (resolves decision item 2). Remove the 4.2 spec file from Task 6.1's 4.3-commit staging list and add a Task 6.4 documenting the split-commit plan: 4.3 first, then a `Story 4.2 review-pass: post-merge findings + AC1/AC3/AC6/AR13 amendments + SHA reconciliation` commit referencing 4.3's SHA. [`4-3-welcome-screen-test-coverage-hardening.md` Task 6.1]

**Deferred (4) — appended to `deferred-work.md`:**

- [x] [Review][Defer] **`printf '\032'` recipe portability across non-Ubuntu shells** — works on dev tooling; deferred. [`test/Makefile` EMPTY.TXT recipe]
- [x] [Review][Defer] **`bdos_error_pre_msg` not pre-zeroed in e-empty-txt test** — defensive hardening against mid-load BDOS errors surfacing stale "can't open" banner; lower priority than F17. [`test/cases/welcome_active-survives-e-empty-txt.asm` pre-state setup]
- [x] [Review][Defer] **Save-test/load-test EMPTY.TXT alphabetic ordering creates implicit shape dependency** — `fileio_save-empty-buffer.asm` runs before `welcome_active-survives-e-empty-txt.asm`; save-test on-disk shape regression silently bleeds into load-test assertion path. Architectural; AC4 partially mitigates via `$(FIXTURES)` rebuild. [test/Makefile + test/cases ordering]
- [x] [Review][Defer] **too-large subtest 3 doesn't assert trailing terminator/pad** — checks only first 14 bytes equal `"file too large"`; banner-format regression dropping the terminator/pad goes undetected. [`test/cases/init_welcome-hidden-too-large.asm` subtest 0x03]
- [x] [Review][Defer] **Dismissal-key replicas miss production hook structural drift** (from decision item 3) — all 5 replicas embed hook bytes inline; production hook at `src/vibe.asm:276-284` can drift (JR Z→JR NZ flip, PUSH/POP reorder, key-check insertion) without breaking any replica. Mitigations: (a) meta-test driving `input_loop` via stubbed `input_get_key`, OR (b) build-time grep assertion that inline replica bytes equal production hook bytes. Hardware UAT retains coverage of this drift. [`test/cases/welcome_dismissed-on-first-key*.asm`]

## Change Log

| Date       | Author | Change                                                                       |
|------------|--------|------------------------------------------------------------------------------|
| 2026-05-19 | Amelia | Story 4.3 scoped from Theme C of `deferred-work-triage-2026-05-19.md`. Closes deferred entries L498/L499/L500. Test-only; 0 B production-code delta. Ready for dev. |
| 2026-05-19 | Dev (Opus 4.7) | Story 4.3 implemented. 7 new test cases (4 dismissal-key replicas + 2 AC2 siblings + 1 `:e empty.txt` survival) + 1 modified test (0xAA poison hardening) + `fixtures/EMPTY.TXT` Makefile recipe + 3 deferred-work.md closure annotations. `make test` 272 → 279 (+7). NFR18 SHA `cfeaf4c6...` byte-identical. `make sizes` 8562 B / 83% unchanged. AC1-AC8 all satisfied; AC7 confirms no hardware UAT required. Status → review. |
| 2026-05-19 | Reviewer (Opus 4.7) | Code review 2026-05-19 (3-layer parallel adversarial). 28 findings raised, 4 dismissed; 17 patches + 4 deferred + 3 decision-needed pending Ant. See Review Findings section above. |
| 2026-05-19 | Ant / Reviewer (Opus 4.7) | Code-review decisions resolved: D1 amend-File-List, D2 split-into-separate-4.2-commit, D3 defer hook-drift. All 19 patches applied (D1+D2 converted from decision-needed; D3 added to deferred-work). `make clean && make test` = **279 pass / 1 fail** (target met). NFR18 SHA `cfeaf4c6...` unchanged. Story flipped review → done. Task 6.4 added for the follow-up 4.2 review-pass commit. |
