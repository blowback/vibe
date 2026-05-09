# Story 1.6: Headless test harness scaffold

Status: done

<!-- Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As the VIBE author,
I want a working `make test` target that builds every `test/cases/*.asm` to a `.com` and runs each under iz-cpm with a 5-second timeout, signalling pass/fail via the sentinel byte at `0xCFFE` plus a recognisable line on stdout,
so that every later headless-testable layer (gap buffer 1.7, dispatch 1.9, parser/render/exline 2.1, fileio 2.2/2.4, motions/edits/visual/search/undo across 2.x and 3.x) has a mechanical CI-style harness ready, the architecture's TH1 (sentinel) and TH3 (fixture-filesystem) conventions are concretely realised in code, and the implementation-sequence step before gap-buffer testing (story 1.7) lands its prerequisite.

## Acceptance Criteria

1. **AC1 — `test/Makefile` exists with a real `test` target that iterates `test/cases/*.asm`.**
   Given `test/Makefile`,
   When I inspect it,
   Then it (a) globs `test/cases/*.asm`, (b) assembles each to a sibling `.com` using sjasmplus 1.23.0 with the same flag set as the production `Makefile` (`--nologo --msg=err --raw=<case>.com <case>.asm`), (c) runs each `.com` under iz-cpm with the project-root `test/fixtures/` mounted as drive A: **and** B: (per TH3), (d) wraps each iz-cpm invocation in `timeout 5` so any hang is bounded, (e) parses the test program's stdout for a `PASS` or `FAIL` line emitted by the epilogue (per AC3), (f) prints a per-case `pass / fail / timeout` line to stdout, (g) exits non-zero on any case that is not `pass`, (h) exits zero only when every case is `pass`,
   And the project-root `Makefile`'s `test:` target (`$(MAKE) -C test test`) recurses into `test/Makefile` unchanged from its Story 1.1 form,
   And `make test` from the project root is the canonical entry point for all future story validation; no later story re-implements the harness.

2. **AC2 — `test/inc/test_prologue.inc` exists with the standard entry boilerplate.**
   Given `test/inc/test_prologue.inc`,
   When I inspect it,
   Then it defines `TEST_RESULT EQU 0xCFFE` and `TEST_CONTEXT EQU 0xCFFF` (the TH1 sentinel pair),
   And it places `ORG 0x0100` (CP/M `.com` entry point),
   And it provides a `test_start:` label whose body zeroes both bytes at `0xCFFE` / `0xCFFF` (so the sentinel cannot be polluted by TPA boot residue from a prior run),
   And the file is documented as INCLUDE-only (it relies on the caller to follow with the test body and the epilogue INCLUDE; no headers are pulled in from `inc/*.inc` here, the test case decides what production headers it needs),
   And the file conforms to project-wide formatting (4-space indent, UPPERCASE mnemonics, `;`/`;;` comments).

3. **AC3 — `test/inc/test_epilogue.inc` exists with `test_pass` and `test_fail` labels emitting recognisable stdout lines.**
   Given `test/inc/test_epilogue.inc`,
   When I inspect it,
   Then `test_pass:` writes `0x00` to `(TEST_RESULT)`, prints the literal string `PASS$` to stdout via CP/M BDOS function 9 (print-`$`-terminated-string from DE), then exits via BDOS function 0 (`JP 0x0005` after `LD C, 0`),
   And `test_fail:` writes `A` to `(TEST_RESULT)` (caller convention: `A` is the fail-code), writes `B` to `(TEST_CONTEXT)` (caller convention: `B` is optional context), prints `FAIL <fc> <ctx>$` to stdout via BDOS function 9 (where `<fc>` and `<ctx>` are the 2-digit ASCII-uppercase hex of `(TEST_RESULT)` and `(TEST_CONTEXT)` respectively, separated by single spaces, terminated by `$`), then exits via BDOS function 0,
   And the epilogue uses raw `CALL 0x0005` / `JP 0x0005` (NOT the `BDOS_CALL` macro) — test infrastructure is an explicit carve-out from AR15: tests don't link the production BDOS gateway, and CP/M function 9 (print-string) is not in the production NFR15 enumeration, so the test scaffold uses raw BDOS directly. Document this carve-out in a `;` comment block above the labels,
   And the `PASS$` string is byte-for-byte exact and the `FAIL` token is byte-for-byte exact (the `$` in both is CP/M's BDOS-function-9 string terminator; no trailing newline — the harness's per-case echo provides the line break). The hex codes embedded in the FAIL line satisfy AC4's "derive the codes from the failing test's stdout" path,
   And the epilogue does **not** require the test case to INCLUDE any production header (`bios.inc`, `bdos.inc`, etc.). The raw `0x0005` works without macros.

4. **AC4 — Two demo cases prove pass and fail are both detected.**
   Given `test/cases/harness_pass.asm` and `test/cases/harness_fail.asm`,
   When I inspect them,
   Then `harness_pass.asm`:
     - INCLUDEs `../inc/test_prologue.inc`,
     - has a body that does nothing (`NOP` placeholders are fine; the point is the prologue + epilogue alone constitutes a passing test),
     - falls through (or `JP test_pass`) to the epilogue's pass branch,
     - INCLUDEs `../inc/test_epilogue.inc`,
   And `harness_fail.asm`:
     - INCLUDEs `../inc/test_prologue.inc`,
     - sets `A = 0xE1` (an arbitrary fail-code) and `B = 0xC0` (an arbitrary context byte),
     - `JP test_fail`,
     - INCLUDEs `../inc/test_epilogue.inc`,
   And `make test` reports `harness_pass.asm` as `pass` and `harness_fail.asm` as `fail` with the `0xE1` / `0xC0` codes visible in the failure summary (the Makefile reads back `0xCFFE` and `0xCFFF` post-run via a small post-process step OR derives the codes from the failing test's stdout — either approach acceptable; pick one and document),
   And `make test` exits non-zero overall because of `harness_fail.asm`.

5. **AC5 — `test/fixtures/` exists with at least one stub fixture, and `test/README.md` documents how to use it.**
   Given the `test/fixtures/` directory,
   When I inspect it,
   Then at least one stub fixture file is present (e.g. an empty `placeholder.txt` or a tiny `hello.txt` containing one short line — the exact content is the dev's call; what matters is "the directory is git-tracked and visible"),
   And `test/README.md` documents:
     - how to run the harness (`make test` from the project root, or `cd test && make test`),
     - how to add a new test case (drop a `<module>_<scenario>.asm` into `test/cases/`, INCLUDE the prologue and epilogue, write the body, run `make test`),
     - the TH1 sentinel-byte pair (`0xCFFE` pass-code, `0xCFFF` context),
     - how `test/fixtures/` is mounted (iz-cpm flag form: `-a test/fixtures` for drive A:, `-b test/fixtures` for drive B: — Stories 2.2 and 2.4 expect drive B: per architecture line 725-728),
     - how to add a fixture file for FCB-level tests (drop a file into `test/fixtures/`, reference it via FCB with drive byte for B: per CP/M FCB conventions; story 2.2 will land the full filename / FCB encoding pattern).

6. **AC6 — TH2 naming convention enforced for demo cases and documented.**
   Given the demo test cases in `test/cases/`,
   When I inspect their filenames,
   Then both follow the `<module>_<scenario>.asm` pattern: `harness_pass.asm`, `harness_fail.asm` (here `harness` is the implicit module under test — the harness itself),
   And `test/README.md` documents the naming convention with the architecture's reference examples cited (line 1041-1054 of architecture.md): `gapbuf_insert-empty.asm`, `parser_count-then-motion.asm`, `fileio_load-with-1A.asm`, etc. (lowercase module name, single underscore, lowercase hyphen-separated scenario, `.asm` extension).

7. **AC7 — Reproducibility per NFR18 across two consecutive `make test` runs.**
   Given two consecutive `make test` runs on the same checkout (no source edits between),
   When I compare the SHA-256 of every `test/cases/*.com` after each run,
   Then they match across runs (test-case builds are byte-identical; sjasmplus is deterministic on identical input; the harness does not embed timestamps or per-run identifiers in the .com images),
   And `test/cases/*.com` are gitignored (already covered by `*.com` in `.gitignore`).

8. **AC8 — Project-root `Makefile`'s `test:` target unchanged in form, but now actually does work.**
   Given the project-root `Makefile`'s `test:` target,
   When I inspect it,
   Then it remains a single line: `$(MAKE) -C test test` (no flag changes, no parallelism opt-in, no env-var injection — clean delegation),
   And `make test` from the project root invokes the same harness as `cd test && make test`,
   And the previous Story 1.1 stub message ("test harness not yet wired — see Story 1.6") is removed from `test/Makefile`.

9. **AC9 — Existing smoke tests not regressed; relocation deferred.**
   Given the pre-existing smoke artifacts at `test/smoke/bdos_call_smoke.asm` (Story 1.4) and `test/smoke/statusln_smoke.asm` (Story 1.5),
   When `make test` runs,
   Then the harness does **not** assemble or run the `test/smoke/*.asm` files — they are explicitly outside the `test/cases/*.asm` glob,
   And the smoke files remain in place (no deletion, no relocation; future story may normalise them into proper harness cases under `test/cases/<module>_<scenario>.asm` once the relevant module's test plan is detailed),
   And `test/README.md` notes the carve-out: `test/smoke/` houses one-off smokes from earlier stories; `test/cases/` is the harness location going forward.

## Tasks / Subtasks

- [x] **Task 1 — Create `test/inc/test_prologue.inc`** (AC: 2)
  - [x] AR23-style header block (`; Module: test/inc/test_prologue.inc`, `; Purpose: …`, `; Public: TEST_RESULT, TEST_CONTEXT, test_start`, `; Dependencies: (none — leaf for the test scaffold)`).
  - [x] Reference layout (emit verbatim or with cosmetic variation; the contract is the constants + the `test_start` zero-init body):
    ```asm
    ; ============================================================
    ; Module: test/inc/test_prologue.inc
    ; Purpose: Standard entry boilerplate for a headless test case.
    ;          Defines the TH1 sentinel addresses (0xCFFE pass code,
    ;          0xCFFF context byte), pre-zeroes both so post-run
    ;          inspection sees a deterministic value (not boot
    ;          residue), and lands the program at the CP/M .com
    ;          entry address 0x0100.
    ;
    ; Public:
    ;   TEST_RESULT     EQU 0xCFFE   ; pass code (0 = pass, !=0 = fail)
    ;   TEST_CONTEXT    EQU 0xCFFF   ; optional context byte
    ;   test_start                   ; INCLUDEing test falls through here
    ;
    ; State owned (read/write):
    ;   (none — the sentinel pair is the only RAM this file touches,
    ;    and only the entry boilerplate writes them; the test_pass /
    ;    test_fail epilogue rewrites them on exit)
    ;
    ; Dependencies:
    ;   (none — leaf for the test scaffold; production inc/*.inc are
    ;    NOT INCLUDEd here. The test case decides which production
    ;    headers it needs.)
    ; ============================================================

    TEST_RESULT     EQU 0xCFFE
    TEST_CONTEXT    EQU 0xCFFF

        ORG 0x0100
    test_start:
        XOR     A
        LD      (TEST_RESULT), A
        LD      (TEST_CONTEXT), A
        ; Test body follows after this INCLUDE.
    ```
  - [x] **Do not** put the test body or the epilogue in this file. The test case INCLUDEs the prologue, then writes its own body, then INCLUDEs the epilogue. Three-section layout per case.
  - [x] **Do not** include `inc/*.inc` (`bios.inc`, `bdos.inc`, etc.) here. Test cases that need them (e.g. fileio tests) INCLUDE them explicitly between the prologue and their body. Most simple unit tests don't need any production header.

- [x] **Task 2 — Create `test/inc/test_epilogue.inc`** (AC: 3)
  - [x] AR23-style header block. Note the AR15 carve-out in a `;` block above the labels (test scaffold uses raw BDOS by design — production code paths still go through `BDOS_CALL`).
  - [x] Reference layout:
    ```asm
    ; ============================================================
    ; Module: test/inc/test_epilogue.inc
    ; Purpose: Standard exit boilerplate for a headless test case.
    ;          Provides `test_pass:` and `test_fail:` labels that
    ;          emit a recognisable line on stdout (consumed by
    ;          test/Makefile to determine pass/fail per case) and
    ;          terminate the program via BDOS function 0.
    ;
    ; Public:
    ;   test_pass    ; jump here when the test body succeeded
    ;   test_fail    ; jump here with A = fail-code, B = context
    ;
    ; AR15 carve-out:
    ;   The test scaffold uses raw `CALL 0x0005` / `JP 0x0005`
    ;   rather than the production `BDOS_CALL` macro. Two reasons:
    ;     (1) tests do not link the production `BDOS_CALL` macro
    ;         body (which references `bdos_error_funnel`, a symbol
    ;         in src/statusln.asm — pulling that into every test
    ;         case is excess scope);
    ;     (2) CP/M BDOS function 9 (print-$-terminated-string) is
    ;         used here to emit the PASS / FAIL line, and function
    ;         9 is deliberately excluded from the production NFR15
    ;         function-number enumeration in inc/bdos.inc (the
    ;         editor uses BIOS-direct console for emission).
    ;   AR15 applies to src/* and inc/* (production code). Tests
    ;   under test/cases/ and test/inc/ are explicitly exempt.
    ;
    ; Dependencies:
    ;   inc/test_prologue.inc  (TEST_RESULT, TEST_CONTEXT)
    ; ============================================================

    test_pass:
        XOR     A
        LD      (TEST_RESULT), A           ; sentinel = 0 (pass)
        LD      DE, .pass_msg
        LD      C, 9                       ; BDOS print-string
        CALL    0x0005
        LD      C, 0                       ; BDOS exit
        JP      0x0005
    .pass_msg:
        DEFB    "PASS$"

    test_fail:
        LD      (TEST_RESULT), A           ; A = fail-code
        LD      A, B
        LD      (TEST_CONTEXT), A          ; B = context
        LD      DE, .fail_msg
        LD      C, 9                       ; BDOS print-string
        CALL    0x0005
        LD      C, 0                       ; BDOS exit
        JP      0x0005
    .fail_msg:
        DEFB    "FAIL$"
    ```
  - [x] **`test_fail` register contract.** The caller passes `A = fail-code, B = context` then `JP test_fail`. The first instruction stores `A` to `(TEST_RESULT)` while `A` is still the caller's value. Then `LD A, B` and `LD (TEST_CONTEXT), A` saves context. Order matters: storing `A` BEFORE the `LD A, B` overwrite. Trace this carefully when implementing.
  - [x] **`PASS$` / `FAIL$` exact strings.** The `$` is the CP/M BDOS-function-9 string terminator (not a trailing character to display). After the BDOS call returns, the harness's grep on stdout sees `PASS` or `FAIL` (the `$` is consumed by BDOS). No trailing newline — the harness's per-case echo provides line breaks.
  - [x] **Naming.** `test_pass` / `test_fail` use the project-wide `module_action` lowercase convention (AR22). `.pass_msg` / `.fail_msg` are dotted-locals.

- [x] **Task 3 — Create demo cases `test/cases/harness_pass.asm` and `test/cases/harness_fail.asm`** (AC: 4, 6)
  - [x] `test/cases/harness_pass.asm`:
    ```asm
    ; ============================================================
    ; Module: test/cases/harness_pass.asm
    ; Purpose: Demo case — always passes. Smoke-tests the
    ;          harness's pass-detection path (TH1 sentinel = 0,
    ;          stdout contains "PASS").
    ; ============================================================
        INCLUDE "../inc/test_prologue.inc"

        ; Body: trivially fall through to the pass branch.
        JP      test_pass

        INCLUDE "../inc/test_epilogue.inc"
    ```
  - [x] `test/cases/harness_fail.asm`:
    ```asm
    ; ============================================================
    ; Module: test/cases/harness_fail.asm
    ; Purpose: Demo case — always fails with a specific code so
    ;          the harness's fail-detection path is exercised
    ;          (TH1 sentinel != 0, stdout contains "FAIL").
    ; ============================================================
        INCLUDE "../inc/test_prologue.inc"

        ; Body: load fail-code 0xE1 ("demo failure") and context
        ; byte 0xC0 ("constant"), then jump to the fail branch.
        LD      A, 0xE1
        LD      B, 0xC0
        JP      test_fail

        INCLUDE "../inc/test_epilogue.inc"
    ```
  - [x] **Naming check.** Both filenames match `<module>_<scenario>.asm` (TH2 convention from epics line 493 and architecture line 1041-1054). The module name `harness` reflects "the harness itself is what's being tested by these two cases". Future modules use their actual module names (`gapbuf_*`, `parser_*`, `fileio_*`).
  - [x] **Path resolution.** Test cases live at `test/cases/<file>.asm`. The INCLUDE `"../inc/test_prologue.inc"` resolves relative to the file containing the INCLUDE — i.e., from `test/cases/`, `../inc/` lands at `test/inc/`. Verify the build before moving on.

- [x] **Task 4 — Replace `test/Makefile` stub with the real harness** (AC: 1, 4, 6, 8)
  - [x] Reference Makefile (cosmetic variation OK; the contracts above are the requirements):
    ```makefile
    # ============================================================
    # VIBE — test/Makefile
    #
    # Headless test harness. Iterates test/cases/*.asm, assembles
    # each to a .com via sjasmplus 1.23.0, runs each under iz-cpm
    # with a 5-second timeout, parses the test program's stdout
    # for PASS / FAIL, reports per-case pass / fail / timeout.
    #
    # Pass: stdout contains "PASS" → harness reports `pass`.
    # Fail: stdout contains "FAIL" → harness reports `fail` and
    #       exits non-zero.
    # Timeout: timeout(1) returns 124 → harness reports `timeout`
    #          and exits non-zero.
    # Other: anything else → harness reports `unknown` and exits
    #        non-zero.
    #
    # Architecture references:
    #   TH1: sentinel bytes at 0xCFFE / 0xCFFF (architecture
    #        lines 710-716).
    #   TH3: fixture filesystem mounted as iz-cpm B: drive
    #        (architecture lines 725-728).
    # ============================================================

    SJASMPLUS         := sjasmplus
    SJASMPLUS_FLAGS   := --nologo --msg=err
    IZ_CPM            := iz-cpm
    IZ_CPM_FIXTURES   := fixtures
    TIMEOUT_SECS      := 5

    CASES := $(wildcard cases/*.asm)
    COMS  := $(CASES:.asm=.com)

    .PHONY: all test clean

    all: test

    cases/%.com: cases/%.asm inc/test_prologue.inc inc/test_epilogue.inc
    	$(SJASMPLUS) $(SJASMPLUS_FLAGS) --raw=$@ $<

    # Build then run: shell loop reports per-case; exits 1 on any
    # non-pass. We build all cases first (fail fast on a build break),
    # then run all cases (one bad runtime doesn't skip the rest).
    test: $(COMS)
    	@pass=0; fail=0; \
    	for com in $(COMS); do \
    	  case=$$(basename $$com .com); \
    	  out=$$(timeout $(TIMEOUT_SECS) $(IZ_CPM) -a $(IZ_CPM_FIXTURES) -b $(IZ_CPM_FIXTURES) $$com 2>&1); \
    	  rc=$$?; \
    	  if [ $$rc -eq 124 ]; then \
    	    echo "  timeout  $$case"; \
    	    fail=$$((fail+1)); \
    	  elif echo "$$out" | grep -q "PASS"; then \
    	    echo "  pass     $$case"; \
    	    pass=$$((pass+1)); \
    	  elif echo "$$out" | grep -q "FAIL"; then \
    	    echo "  fail     $$case  (rc=$$rc, output: $$out)"; \
    	    fail=$$((fail+1)); \
    	  else \
    	    echo "  unknown  $$case  (rc=$$rc, output: $$out)"; \
    	    fail=$$((fail+1)); \
    	  fi; \
    	done; \
    	echo; \
    	echo "  $$pass pass, $$fail fail"; \
    	[ $$fail -eq 0 ]

    clean:
    	rm -f cases/*.com
    ```
  - [x] **iz-cpm flag form.** Per the agent-confirmed flag list: `-a <dir>` mounts drive A:, `-b <dir>` mounts drive B:. The harness mounts `test/fixtures/` as **both** so simple tests don't have to think about drive letters; FCB-level tests in stories 2.2/2.4 will use B: explicitly per architecture line 725-728.
  - [x] **Pass-detection.** Grep on stdout: `PASS` substring → pass, `FAIL` → fail, otherwise (timeout / crash / unexpected) → unknown. The string `PASS` does not appear in iz-cpm's own output; `FAIL` does not either. Verify by running `iz-cpm -a fixtures cases/harness_pass.com` and `cases/harness_fail.com` manually after Task 4 completes.
  - [x] **`timeout 5`** uses GNU coreutils' `timeout` (Linux build host per architecture line 307-313). Returns exit code 124 when the timeout fires. The harness reads `$rc` (the shell's `$?`) immediately after the iz-cpm call to disambiguate timeout from clean-exit.
  - [x] **Per-case `fail` reporting.** When a case fails, the harness prints `"  fail     $$case  (rc=$$rc, output: $$out)"`. The `output` field surfaces the test program's stdout — for a `harness_fail.asm` invocation this contains "FAIL", and the dev can manually inspect `test/cases/harness_fail.com` if more detail is needed (the .com is gitignored but built fresh on every `make test`).
  - [x] **Don't prune passing .coms.** Leave them for the next NFR18 reproducibility check (AC7). `make clean` removes them on demand.
  - [x] **Build dependency.** Each `cases/%.com` depends on its `cases/%.asm` AND on both INCLUDE files (`inc/test_prologue.inc`, `inc/test_epilogue.inc`). Editing the prologue or epilogue rebuilds every case — that's the intended behaviour.

- [x] **Task 5 — Create `test/fixtures/` with at least one stub fixture** (AC: 5)
  - [x] `test/fixtures/` is currently an empty git-tracked directory (no `.gitkeep`). Add one stub fixture file.
  - [x] Recommended stub: `test/fixtures/hello.txt` containing the literal bytes `hello world\r\n` (CP/M canonical line ending: CR+LF). Story 2.2's `fileio_load-small-file.asm` will likely use this or replace it; the contents don't matter for Story 1.6 — what matters is "the directory has at least one file so iz-cpm's drive mount has something to enumerate".
  - [x] **Do not** add a `.gitkeep`. The stub fixture itself git-tracks the directory.
  - [x] **Permissions.** Use default file permissions (`644`). Story 2.4's `fileio_save-write-protect.asm` will need a deliberately-readonly fixture (`chmod 444` or filesystem-level read-only); that's Story 2.4's setup, not Story 1.6's.

- [x] **Task 6 — Write `test/README.md`** (AC: 5, 6, 9)
  - [x] Required content (the README is reasonably terse — keep under 100 lines):
    1. **One-paragraph overview**: what the harness does (sjasmplus build + iz-cpm run + sentinel/stdout pass-fail).
    2. **How to run**: `make test` from the project root (canonical) or `cd test && make test` (equivalent).
    3. **Adding a test case**: drop `test/cases/<module>_<scenario>.asm`, INCLUDE the prologue + epilogue, write the body, run `make test`. Show a minimal example (the `harness_pass.asm` body inline as a 5-line snippet).
    4. **TH1 sentinel pair**: `0xCFFE` = pass code (0 = pass), `0xCFFF` = optional context. Test programs write these via `test_pass` / `test_fail`; the harness's primary pass/fail signal is the stdout `PASS` / `FAIL` line, and the sentinel is for post-mortem inspection (e.g. via a debugger on real hardware in Story 1.12).
    5. **TH2 naming convention**: `<module>_<scenario>.asm` lowercase, single underscore between module and scenario, hyphens within scenario. Cite architecture's example list at line 1041-1054 verbatim (gapbuf_insert-empty, parser_count-then-motion, etc.).
    6. **TH3 fixtures**: `test/fixtures/` is mounted as iz-cpm drive A: AND drive B:. To add a fixture, drop a file into `test/fixtures/` (CP/M filename rules: 8.3 uppercase). FCB-level tests (Stories 2.2 / 2.4) reference fixtures by filename via the standard CP/M FCB layout — story 2.2 will land the full FCB encoding pattern.
    7. **Carve-out**: `test/smoke/` houses one-off smokes from earlier stories (1.4's `bdos_call_smoke.asm`, 1.5's `statusln_smoke.asm`). The harness does NOT run them. Future stories may relocate them into `test/cases/<module>_<scenario>.asm` once each module's test plan is detailed.
    8. **Failure modes**: timeout (the `timeout 5` wrapper fires; harness reports `timeout`), build break (sjasmplus errors out; harness fails the build before running), unknown (test program emits neither `PASS` nor `FAIL` and exits within timeout — usually a corrupt epilogue or an early exit before the epilogue runs).

- [x] **Task 7 — Verify project-root `Makefile`'s `test:` target still works unchanged** (AC: 8)
  - [x] The current `Makefile:65-66` says `test: $(MAKE) -C test test`. No change needed.
  - [x] Run `make test` from the project root. Observe: the recursion into `test/Makefile` runs the harness; output mirrors what `cd test && make test` would produce.
  - [x] **Do not** add parallelism flags (`-j`) to the project-root invocation. The per-case loop in `test/Makefile` is intentionally serial — each iz-cpm invocation reads / writes the same `test/fixtures/` directory; parallelism would race. If parallelism is wanted later, gate it on per-case fixture isolation.

- [x] **Task 8 — Reproducibility check (NFR18)** (AC: 7)
  - [x] `make test` once: every demo case builds, harness reports `1 pass, 1 fail` (since `harness_fail.asm` is meant to fail).
  - [x] `sha256sum test/cases/*.com`: record per-case SHAs.
  - [x] `make -C test clean && make test`: rebuild and rerun.
  - [x] `sha256sum test/cases/*.com`: same SHAs as the first run (sjasmplus is deterministic on identical input; the harness does not embed timestamps).
  - [x] **If a SHA differs**: investigate. Most likely culprits: a `--date` or `--time` flag accidentally added to sjasmplus invocation; a timestamp embedded in a `DEFB` literal; an environment-dependent path embedded in the listing. None of these should be present — the harness's sjasmplus flags mirror the production `Makefile`'s flag set.
  - [x] **Do not** check in the .com SHAs as a tripwire file. The reproducibility property is a per-checkpoint sanity check, not an asserted invariant. Story 2.x's first new test case will shift the per-case SHAs naturally.

- [x] **Task 9 — Smoke regression check** (AC: 9)
  - [x] Confirm `test/smoke/bdos_call_smoke.asm` and `test/smoke/statusln_smoke.asm` are still in place (untouched by this story).
  - [x] Confirm `make test` does **not** assemble or run `test/smoke/*.asm` — the `wildcard cases/*.asm` glob excludes them.
  - [x] Manually rebuild the smokes once (out of band from the harness, just to make sure they still work): `cd test/smoke && sjasmplus --nologo --msg=err --raw=bdos_call_smoke.com bdos_call_smoke.asm`. Same for `statusln_smoke.asm`. Both should succeed (their dependencies — `inc/bdos.inc`, `inc/bios.inc`, `src/statusln.asm`, `inc/state.inc` — are unchanged by this story).
  - [x] Optionally rerun the smokes under iz-cpm (`iz-cpm bdos_call_smoke.com`, `iz-cpm statusln_smoke.com`) to confirm no regression. Trace evidence from Story 1.4 / 1.5 reviews remains valid; this is a quick sanity check, not a re-test.

### Review Findings (2026-05-09)

Adversarial / Edge-Case / Acceptance review on the uncommitted Story 1.6 working tree (test/Makefile, test/README.md, test/cases/*, test/inc/*, test/fixtures/hello.txt). 1 decision-needed, 8 patches, 16 deferred, 12 dismissed as noise / spec-mandated / false positives.

- [x] [Review][Decision→Patch] **AC3 vs AC4 tension — `FAIL <fc> <ctx>$` instead of literal `FAIL$`** — Resolved 2026-05-09: amend AC3 (option 1). The dev's stdout-derivation resolution is sound (iz-cpm has no `--ram-dump`; PASS path is literal `PASS$`; harness grep still matches `FAIL` substring). AC3 will be updated to read "PASS$ exact; FAIL emits `FAIL` token + 2-digit hex codes terminated by `$`", and the 🛑 guardrail at line 373 will be updated to match. (Sources: Acceptance Auditor.)
- [x] [Review][Patch] **Apply the AC3 amendment to this story file** [this story file: AC3 + 🛑 guardrail] — Applied 2026-05-09: AC3 now describes both the literal `PASS$` path and the `FAIL <fc> <ctx>$` pattern with hex-code spec; the 🛑 guardrail rewritten to match.

- [x] [Review][Patch] **PASS / FAIL grep is unanchored — false positives from iz-cpm banner / future output** [test/Makefile] — Applied 2026-05-09: `grep -q "PASS"` / `grep -q "FAIL"` replaced with `grep -qE '\bPASS\b'` / `grep -qE '\bFAIL\b'`. Verified `make test` still classifies harness_pass as pass and harness_fail as fail. (Sources: Blind Hunter + Edge Case Hunter.)

- [x] [Review][Patch] **Hard-coded architecture line numbers will rot** [test/Makefile + test/README.md] — Applied 2026-05-09: replaced "architecture lines 710-716 / 725-728 / 1041-1054" with section-anchored citations (`architecture.md § Test harness — pass/fail signal`, `§ Test harness — fixture filesystem`, `§ Test file naming`). (Source: Blind Hunter.)

- [x] [Review][Patch] **README "8.3 uppercase" phrasing implies host filenames must be uppercase** [test/README.md] — Applied 2026-05-09: rephrased to "The host filename can be lowercase; the FCB the test program builds is uppercase per CP/M's 8.3 rule (Story 2.2 lands the encoding pattern)." (Sources: Blind Hunter + Edge Case Hunter + Acceptance Auditor.)

- [x] [Review][Patch] **`timeout 5` may not actually kill iz-cpm if it catches SIGTERM** [test/Makefile] — Applied 2026-05-09: `timeout` invocation now uses `--kill-after=1` to escalate to SIGKILL after a 1-second grace. Verified `make test` still works. (Source: Blind Hunter.)

- [x] [Review][Patch] **`test_pass` re-zeroes `TEST_RESULT` but leaves `TEST_CONTEXT` to whatever the body wrote** [test/inc/test_epilogue.inc] — Applied 2026-05-09: added `LD (TEST_CONTEXT), A` after the existing zero-write of `(TEST_RESULT)`. Post-pass invariant is now both bytes 0. (Source: Blind Hunter.)

- [x] [Review][Patch] **Empty `cases/` reports green with zero tests run** [test/Makefile] — Applied 2026-05-09: added `if [ $$((pass+fail)) -eq 0 ]; then echo "  no test cases ran (cases/*.asm is empty)"; exit 1; fi` between the per-case loop and the totals echo. (Source: Edge Case Hunter.)

- [x] [Review][Patch] **README does not warn that body fall-through silently reports pass** [test/README.md] — Applied 2026-05-09: added a blockquote callout immediately after the minimal pass/fail examples: "Always end the body with `JP test_pass` or `JP test_fail`. The epilogue's first label is `test_pass:`, so a body that drops off the end falls into the pass branch and is silently reported as `pass`. The `harness_pass.asm` demo's empty-body fall-through is the *only* spec-licensed use." (Source: Edge Case Hunter.)

- [x] [Review][Patch] **Completion Notes say `statusln_smoke.asm` does not yet exist on disk** [this story file, Completion Notes List + Debug Log References] — Applied 2026-05-09: both bullets now read "Both pre-existing smokes — `bdos_call_smoke.asm` (Story 1.4) and `statusln_smoke.asm` (Story 1.5, marked done 2026-05-09) — reassemble standalone and are carved out of `make test` per AC9." Change Log left as historical record. (Source: Acceptance Auditor.)

- [x] [Review][Defer] **Multi-line iz-cpm stderr renders unreadably in the per-case fail echo** [test/Makefile:73, 77] — deferred, cosmetic; consider per-case `.log` files in a future polish pass.
- [x] [Review][Defer] **No compile-time guard that `TEST_RESULT (0xCFFE)` is below the runtime BDOS base** [test/inc/test_prologue.inc:26-33] — deferred, would couple the scaffold to a production-header symbol (`BDOS_BASE`) and break the deliberate scaffold/production decoupling per AC2.
- [x] [Review][Defer] **`clean` target removes only `.com` (no `.lst`/`.sld`/etc.)** [test/Makefile:86] — deferred, current sjasmplus flags emit only `.com`; revisit if a future story adds listing flags.
- [x] [Review][Defer] **`for com in $(COMS)` breaks on filenames containing whitespace or shell metachars** [test/Makefile:62-65] — deferred, TH2 naming convention forbids those characters; enforce in a later lint pass if a near-miss occurs.
- [x] [Review][Defer] **Stale `cases/*.com` could survive a clock-skew rebuild check** [test/Makefile:54-55] — deferred, obscure; depends on system-clock games or NFS drift.
- [x] [Review][Defer] **`iz-cpm` not on PATH masquerades as test failures (rc=127, "command not found" in `$out`, no PASS/FAIL match)** [test/Makefile:64] — deferred, operational; consider a preflight `command -v iz-cpm` check in a future polish pass.
- [x] [Review][Defer] **Missing `timeout(1)` on macOS/BSD masquerades as test failures** [test/Makefile:64] — deferred, README warns; same operational class as the iz-cpm preflight.
- [x] [Review][Defer] **Sentinel addresses 0xCFFE/CFFF could be in CP/M stack region — no `LD SP, ...` in prologue** [test/inc/test_prologue.inc] — deferred, relies on iz-cpm's CCP-default SP being safely below 0xCFFE; revisit when porting the harness to real hardware (Story 1.12).
- [x] [Review][Defer] **Sentinel could collide with future production memory map if a test INCLUDEs `inc/state.inc`** [test/inc/test_prologue.inc:26-27] — deferred, no production INCs in tests today; static-check belongs to whichever story first crosses that line.
- [x] [Review][Defer] **`cases/*.asm` glob picks up Emacs-style lock symlinks (`.#foo.asm`)** [test/Makefile:46] — deferred, Make's wildcard matches them; rare in practice; switch to `find` if it becomes a problem.
- [x] [Review][Defer] **Missing `cases/` or `inc/` directory yields a cryptic Make error** [test/Makefile:54] — deferred, operational; not a regression introduced by this story.
- [x] [Review][Defer] **`test/Makefile` does not duplicate the production `check-toolchain` (NFR18 risk if invoked directly)** [test/Makefile] — deferred, spec line 461 explicitly accepts this design (recursion from project-root Makefile is the assumed entry point); separate concern would be whether the project-root `test:` target depends on `check-toolchain`.
- [x] [Review][Defer] **A wild jump into `test_fail` from a buggy body emits `FAIL <stack-garbage>` indistinguishable from deliberate fail** [test/inc/test_epilogue.inc] — deferred, speculative; would need a "crashed" classification path.
- [x] [Review][Defer] **sjasmplus dot-prefixed local labels could leak between body and epilogue** [test/inc/test_epilogue.inc] — deferred, theoretical; a body using `.x:` while another body label is the most-recent non-local would scope under it; document if a near-miss occurs.
- [x] [Review][Defer] **Fixture `hello.txt` lacks the CP/M `0x1A` EOF marker** [test/fixtures/hello.txt] — deferred, surfaces in Story 2.2's fileio tests; not a Story 1.6 obligation.
- [x] [Review][Defer] **Hex-print helpers add ~30 unused bytes to every test case's `.com`** [test/inc/test_epilogue.inc] — deferred, NFR9 explicitly excludes test artifacts; gate behind `IFDEF` if a later story shaves bytes.

## Dev Notes

### Why this story exists

Story 1.6 closes the implementation-sequence prerequisite for **every later headless-testable layer**. Story 1.7 (gap buffer primitives) demands tests ship with implementation per PRD risk-rank-2 (architecture lines 748-750 + 1568-1569: "PRD risk-rank-2 demands tests ship with implementation"). Story 1.7 cannot land without a working harness; therefore Story 1.6 must land first. The same gating applies to dispatch (1.9), parser/render/exline (2.1), fileio (2.2 / 2.4), motions (2.5+), edits (2.8+), undo (2.9+), search (3.1+), and visual (3.2+) — every one of those stories has BDD acceptance criteria of the form "Given headless tests under `test/cases/<module>_*.asm` ... When `make test` runs ... Then the following pass: ...". The harness IS the prerequisite.

Beyond unblocking, Story 1.6 also **concretely realises** three architectural conventions:

- **TH1 (sentinel byte at 0xCFFE)** — until now this was a doc-only convention referenced by the smoke tests. Story 1.6 codifies it in `test/inc/test_prologue.inc` and `test/inc/test_epilogue.inc`, so every later test inherits the convention via INCLUDE rather than re-implementing it (which would diverge over time).
- **TH3 (fixture filesystem at `test/fixtures/` mounted as iz-cpm B:)** — Story 1.6 wires the iz-cpm `-b test/fixtures` flag into the harness Makefile and documents the mount in `test/README.md`. Stories 2.2 / 2.4 inherit the mount transparently.
- **Naming convention `<module>_<scenario>.asm`** — Story 1.6 establishes it via two demo cases AND via README documentation citing architecture line 1041-1054's full example list. Future stories follow the convention; reviewers grep for it.

This is also the **first story that emits build artifacts that are not `vibe.com`**. From here on, the project has two parallel build flows: production (`make` → `vibe.com`) and test (`make test` → per-case `.com` files under `test/cases/`). The .gitignore already covers both via `*.com`. The `Makefile`'s `test:` target chains them implicitly (production builds vibe.com first if any source changed, then `test/Makefile` builds and runs cases).

### Critical guardrails for the dev agent

**🛑 The harness's pass-detection signal is stdout, not the sentinel byte.** TH1 (sentinel at 0xCFFE) exists for post-mortem inspection (debugger on real hardware in Story 1.12, future test introspection). The harness Makefile cannot read iz-cpm's RAM after exit — iz-cpm has no `--ram-dump` flag (verified by the context-research agent against the iz-cpm `--help` output). The pass-fail signal the harness consumes is the test program's stdout: `PASS` substring → pass, `FAIL` → fail. The sentinel write in test_pass / test_fail is belt-and-braces — it's there for the day a future tool reads memory post-run. Do not "optimise away" the sentinel write.

**🛑 The test scaffold is an explicit AR15 carve-out.** `test/inc/test_epilogue.inc` uses raw `CALL 0x0005` / `JP 0x0005` instead of `BDOS_CALL`. This is intentional and documented in the epilogue's header. Two reasons: (1) the production `BDOS_CALL` macro references `bdos_error_funnel` (a symbol in `src/statusln.asm`) — INCLUDEing that into every test case is excess scope and would force every test to drag in the production status-line module; (2) CP/M BDOS function 9 (print-string) is deliberately excluded from the production NFR15 enumeration in `inc/bdos.inc` (the editor uses BIOS-direct console emission), so the macro path doesn't have a function code for it. Test infrastructure is exempt from AR15 — production code under `src/` and `inc/` is not.

**🛑 `test_pass` / `test_fail` register order matters.** In `test_fail`, the caller passes `A = fail-code, B = context`. The first instruction is `LD (TEST_RESULT), A` — this MUST happen before the subsequent `LD A, B` overwrite. If the order is flipped, every fail records context (B) into TEST_RESULT and 0 into TEST_CONTEXT (the original A). Verify trace of test_fail's prologue carefully when implementing.

**🛑 `PASS` and `FAIL` tokens are exact byte-for-byte literals.** The PASS path emits `PASS$` exactly. The FAIL path emits `FAIL <fc> <ctx>$` (FAIL token, single space, 2 ASCII-uppercase hex chars from `(TEST_RESULT)`, single space, 2 hex chars from `(TEST_CONTEXT)`, terminated by `$`). The `$` in both is CP/M's BDOS-function-9 string terminator, NOT a character to display; BDOS consumes it. The harness's stdout grep matches `PASS` / `FAIL` as word-bounded tokens (`grep -qE '\bPASS\b'` / `\bFAIL\b'`). Do not append a newline (`\r\n` or `0x0D, 0x0A`) — the harness's per-case echo provides line breaks. Do not use a different terminator (CP/M's BDOS function 9 is hard-wired to `$`). Do not change the FAIL token shape (e.g. `FAILED`) — it would still substring-match but it would break the word-boundary grep.

**🛑 The harness's `timeout 5` wrapper depends on GNU coreutils' `timeout(1).`** Linux build host per architecture line 307-313 — this is fine. If the build host changes (e.g., macOS without GNU `timeout`), the harness needs `gtimeout` or an alternative; flag this in `test/README.md` if the dev agent works on a non-Linux host. The build is currently Linux-only; non-Linux is out of Story 1.6 scope.

**🛑 Do NOT add `-j` parallelism to the per-case run loop in `test/Makefile`.** Each iz-cpm invocation reads / writes `test/fixtures/` (drive A: + B: mount). Parallel runs race on writes (Story 2.4's save tests will be the first writers). Parallelism is doable later with per-case fixture isolation, but Story 1.6 keeps it serial.

**🛑 Do NOT relocate or modify the existing smokes.** `test/smoke/bdos_call_smoke.asm` (Story 1.4) and `test/smoke/statusln_smoke.asm` (Story 1.5) are pre-existing artifacts. Story 1.6 explicitly leaves them in place (AC9). Future stories may normalise them into `test/cases/<module>_<scenario>.asm` form once the relevant module's test plan is detailed; Story 1.6 is "scaffold only", not "scaffold + retrofit".

**🛑 Do NOT INCLUDE production `inc/*.inc` from `test/inc/test_prologue.inc` or `test_epilogue.inc`.** The scaffold is leaf — it only defines TEST_RESULT / TEST_CONTEXT / test_start / test_pass / test_fail. Test cases that need production headers (e.g. fileio tests will need `bios.inc`, `bdos.inc`) INCLUDE them explicitly between the prologue and the body. Most simple unit tests don't need any production header. Coupling the scaffold to production headers makes the scaffold unsuitable for tests of the headers themselves.

**🛑 `test/fixtures/` is mounted as BOTH drive A: AND drive B: by the harness Makefile.** Drive A: covers tests that don't think about drives (FCB drive byte = 0 = "current default"); drive B: covers FCB-level tests that explicitly target drive B: per architecture line 725-728. Mounting the same directory as both is fine — iz-cpm doesn't enforce write-collision (and the harness doesn't write to fixtures except in Story 2.4's save tests, which target B: and would be filtered if needed).

**🛑 The reproducibility property (AC7 / NFR18) is per-checkpoint, not asserted at every build.** sjasmplus is deterministic on identical input; the SHA-stability holds trivially. Do not add an automated "diff SHAs" step to the harness — the SHAs change naturally when test cases are added (Story 2.x onwards), and a hardcoded diff would generate noise. The check is "do this manually once at the end of Story 1.6 to confirm".

**🛑 The harness reads stdout strings via `grep`. False-positive risk: the test body prints "FAIL" to stdout for some other reason.** Test bodies should NOT use BDOS function 9 themselves; the only stdout output should come from `test_pass` / `test_fail`. If a test body legitimately needs to emit something for debugging, use BIOS_CONOUT or a non-`PASS`/`FAIL` literal. Document this restriction in `test/README.md`.

### Architecture compliance — what AR* / SR* / NFR* / TH* rules this story locks in

| Rule | Story 1.6 obligation |
|---|---|
| AR17 | Headless test harness using iz-cpm on the Linux build host: `test/Makefile` builds and runs each `test/cases/*.asm` under iz-cpm; pass/fail signalled via stdout + sentinel. |
| AR20 | Fixture filesystem at `test/fixtures/` mounted as iz-cpm B: drive: harness Makefile uses `-b test/fixtures` (and also `-a test/fixtures` for tests that don't think about drives). |
| AR22 | Test labels (`test_start`, `test_pass`, `test_fail`, demo case labels) are `module_action` lowercase; dotted-locals (`.pass_msg`, `.fail_msg`) per the project-wide naming. |
| AR23 | Both `test/inc/*.inc` headers ship with the standard module/purpose/public/dependencies header block. |
| AR24 | UPPERCASE mnemonics + registers; 4-space indent never tabs; `;` line / `;;` section comments; no trailing periods. |
| AR15 (carve-out) | Test scaffold uses raw `CALL 0x0005` / `JP 0x0005` for BDOS function 9 (print-string) and BDOS function 0 (exit). Production code under `src/` / `inc/` continues to use `BDOS_CALL`. The carve-out is explicit and documented. |
| TH1 | Sentinel byte at `0xCFFE` (pass code) + `0xCFFF` (context). Pre-zeroed by `test_start`; overwritten by `test_fail` on failure paths. |
| TH2 | Test driver: shell loop in `test/Makefile` rolls per-case results; project-root `make test` recurses. (Note: in the epics file's AC line 493, "TH2" refers to the **naming convention** rather than the driver — the dev agent should treat both senses as locked-in by this story.) |
| TH3 | Fixture filesystem at `test/fixtures/` mounted as iz-cpm B:; documented in `test/README.md`; at least one stub fixture present. |
| NFR9 (code-size budget — production) | Test artifacts do **not** count toward NFR9. Production budget is `vibe.com` only. Test `.com` files build separately and are uncapped. |
| NFR14 | sjasmplus 1.23.0 pin: the harness Makefile's `SJASMPLUS_FLAGS` mirror the production Makefile (`--nologo --msg=err`); no other version is supported. The production Makefile's `check-toolchain` target is not duplicated in `test/Makefile` — the recursion implies the parent already verified, and the test Makefile inherits the same `sjasmplus` binary on PATH. |
| NFR18 | Per-case `.com` builds are byte-identical across consecutive `make test` runs (sjasmplus is deterministic on identical input). The harness does not embed timestamps or per-run identifiers. |

### Existing files — current state and what this story changes

**`test/Makefile`** *(stub, 12 lines):*
- Current: `test:` target prints `"test harness not yet wired — see Story 1.6"` and exits 0.
- This story: replace with the real harness per Task 4. Approximate +60 lines (header comment + variables + per-case rule + test target shell loop + clean target).

**`test/README.md`** *(brief stub, ~10 lines):*
- Current: one-liner mentioning Story 1.6 scope.
- This story: replace with the documented harness usage per Task 6. Approximate length: 60-100 lines.

**`test/cases/`** *(empty directory):*
- Current: empty (reserved for Story 1.6).
- This story: add `harness_pass.asm` and `harness_fail.asm` per Task 3.

**`test/inc/`** *(empty directory):*
- Current: empty (reserved for test-local includes).
- This story: add `test_prologue.inc` and `test_epilogue.inc` per Tasks 1-2.

**`test/fixtures/`** *(empty directory):*
- Current: empty.
- This story: add at least one stub fixture file per Task 5 (e.g. `hello.txt`).

**`test/smoke/bdos_call_smoke.asm`** *(Story 1.4 artifact):*
- Current: exists; runs standalone via manual `sjasmplus` + `iz-cpm` invocation.
- This story: **NOT TOUCHED**. Out of scope per AC9. Future story may relocate to `test/cases/`.

**`test/smoke/statusln_smoke.asm`** *(Story 1.5 artifact, planned):*
- Current: lands as part of Story 1.5.
- This story: **NOT TOUCHED**. Same carve-out as the bdos_call smoke.

**Project root `Makefile`** *(74 lines):*
- Current: `test:` target at line 65-66 reads `test:` then `$(MAKE) -C test test`.
- This story: **NOT TOUCHED**. The recursion is already correct; only `test/Makefile` changes.

**Files NOT touched by this story (do not edit):**
- `src/*.asm`, `inc/*.inc` — all production code.
- Project root `Makefile` — only `test/Makefile` and contents under `test/` change.
- `.gitignore` — `*.com` already covers `test/cases/*.com`; `test/build/` (currently empty, never used) stays as-is for backward compat.
- `_bmad-output/implementation-artifacts/deferred-work.md` — touch only if a Story 1.6 decision is deferred.

**Files created by this story:**
- `test/inc/test_prologue.inc`
- `test/inc/test_epilogue.inc`
- `test/cases/harness_pass.asm`
- `test/cases/harness_fail.asm`
- `test/fixtures/hello.txt` (or equivalent stub)

**Files replaced by this story:**
- `test/Makefile` (stub → real harness)
- `test/README.md` (one-liner → documented usage)

### Library / framework requirements

**sjasmplus 1.23.0:**

- The production `Makefile` pins this version via `check-toolchain` (NFR14). The test harness Makefile does NOT duplicate the check — recursion from the parent `Makefile` ensures the parent's check ran first, and the same `sjasmplus` binary is on PATH for the child.
- Test cases use the **same flag set** as production: `--nologo --msg=err --raw=<file>.com <case>.asm`. No `--lst` for tests (avoids creating .lst clutter; Story 2.x test cases that need symbol-table inspection can re-add per-case).
- No `--date`, `--export`, or path-embedding flags. NFR18 reproducibility (AC7) requires the .com to be a pure function of source.

**iz-cpm:**

- Located at `~/.local/bin/iz-cpm` per local check (Story 1.4 dev notes).
- Relevant flags (verified by context-research agent): `-a <dir>` mounts drive A:, `-b <dir>` mounts drive B:, `-t / --call-trace` traces BDOS calls, `-T / --call-trace-all` traces BDOS+BIOS, `-z / --cpu-trace` traces CPU. None of these are used in the default harness invocation; `--call-trace` is useful for debugging a failed test.
- No `--ram-dump`, `--exit-code`, or sentinel-inspection flags exist. The harness's pass/fail decision is via stdout grep — this is the architecture's "tiny appended report routine in the test" path (architecture line 720-722, "or a tiny appended ‘report’ routine in the test").
- iz-cpm always exits 0 once the test program calls BDOS function 0; there is no exit-code propagation from inside the .com. The harness's `rc` detection is purely for `timeout(1)`'s 124 vs. 0.
- Default terminal mode is ADM-3A; ANSI is also supported. The default is fine for stdout grep — the BDOS function 9 string emission goes to stdout regardless of terminal mode.

**GNU coreutils `timeout(1)`:**

- Linux build host only (architecture line 307-313 explicit). Returns 124 on timeout fire. `timeout 5 iz-cpm …` is the harness's per-case wrapper.
- If the build host shifts to macOS or BSD, replace with `gtimeout` (homebrew coreutils) or write a small `timeout.sh` wrapper. Out of Story 1.6 scope.

**CP/M 2.2 BDOS function 9 (print-`$`-terminated-string):**

- The test scaffold uses this for `PASS$` / `FAIL$` emission. Function 9 reads `DE` as a pointer to a string terminated by `$` (`0x24`). Prints the string to the BDOS console (which iz-cpm routes to stdout in the host).
- This function is **not** in VIBE's production NFR15 enumeration (the editor uses BIOS-direct CONOUT). It IS standard CP/M 2.2 — using it in test scaffolding is unambiguously legal.
- The BDOS-function-9 contract: returns when the `$` is encountered; trashes A, BC, DE, HL per CP/M convention.

### CP/M 2.2 reference (for the dev agent's mental model)

The harness uses two CP/M 2.2 BDOS functions in the epilogue:

- **Function 9 — Print String**: `LD C, 9; LD DE, str; CALL 0x0005`. `DE` points to a `$`-terminated string. BDOS prints it to the console. Returns once the `$` is consumed.
- **Function 0 — System Reset**: `LD C, 0; JP 0x0005`. Warm-boots the CCP. iz-cpm interprets this as "exit the .com program and return to the host shell".

The test program flow under iz-cpm:
1. iz-cpm loads `test/cases/<case>.com` at TPA `0x0100`.
2. Execution begins at `0x0100` (the `XOR A` from `test_start` in `test_prologue.inc`).
3. Sentinel pre-zero, then test body runs.
4. Body falls through to `test_pass` (or `JP test_fail` from the body).
5. Epilogue prints `PASS` or `FAIL` and exits via BDOS function 0.
6. iz-cpm sees the warm-boot, exits the host process with status 0.
7. The harness's shell loop: captures stdout, greps for `PASS` / `FAIL`, reports per-case.

### Previous story intelligence (Stories 1.1, 1.2, 1.3, 1.4, 1.5)

**From Story 1.1:**
- `test/Makefile` was created as a stub (`test:` target prints "not yet wired — see Story 1.6"). Project root `Makefile`'s `test:` target recurses into it. Story 1.6 replaces only the stub's body — the recursion infrastructure is already correct.
- iz-cpm is listed as a prerequisite in `README.md`. Available locally at `~/.local/bin/iz-cpm`.
- `*.com` is gitignored project-wide; `test/build/` has its own gitignore entry (currently empty directory, never used).

**From Story 1.4 (BDOS_CALL macro):**
- The smoke test pattern at `test/smoke/bdos_call_smoke.asm` is the model: `ORG 0x0100`, INCLUDE production headers, write a sentinel byte at `0xCFFE` for diagnosis, exit via BDOS function 0. Story 1.6 generalises this into a reusable scaffold (prologue + epilogue) so future tests don't reinvent the pattern.
- The smoke pre-writes `0xAA` as a "never ran" marker. Story 1.6's prologue zeroes `0xCFFE` / `0xCFFF` — same defensive intent (deterministic post-run state). Either pattern works; the prologue's zero-init is the Story 1.6 standard going forward.
- The smoke's `?NOFILE.XXX` FCB pattern (CP/M-illegal filename) became a tree-wide convention from the Story 1.4 review. Future fileio tests will adopt the pattern; Story 1.6's harness doesn't directly use FCBs but the convention is documented in `test/README.md` for the future story 2.x cases.

**From Story 1.5 (statusln.asm):**
- The status-line module's `bdos_error_funnel` references `input_loop`, defined in `vibe.asm` as a stub. The smoke test (`test/smoke/statusln_smoke.asm`) provides its own local `input_loop` stub because the smoke INCLUDEs `src/statusln.asm` directly. Story 1.6's harness does NOT INCLUDE production source — test cases under `test/cases/` are independent of production code unless they explicitly INCLUDE it. This is intentional: test scaffolding is for unit-testing per-module, not for integration-testing the editor.

**From Stories 1.2 / 1.3:**
- The `inc/equates.inc` and `inc/state.inc` design pinned compile-time constants and the static memory map. Story 1.6's test scaffold defines `TEST_RESULT EQU 0xCFFE` locally in `test/inc/test_prologue.inc` rather than adding the symbol to `inc/equates.inc` — the test scaffold is in a separate namespace from production constants. (Architecture line 710-712 says `0xCFFE` is "well below BDOS at `0xD800`, well above any plausible static-data + gap-buffer extent of test programs", but the actual collision check is per test — fileio tests with large fixture loads will need to verify their static map doesn't reach 0xCFFE; that's a per-test concern, not Story 1.6's.)

### Git intelligence

Five commits on `main` after Story 1.0 (post-Story-1.5 dev pass):

- `b561c9e` — Story 1.1: Makefile pins sjasmplus 1.23.0, produces vibe.com.
- `eac5ba3` — Story 1.2: named every constant the editor needs, in three .inc headers, wired in.
- `a298547` — Story 1.3: Laid out the editor's full memory map at fixed addresses, build-time guarded.
- *(uncommitted at story-create time)* — Story 1.4: every BDOS call now goes through a macro that catches errors.
- *(planned)* — Story 1.5: every status message now goes through one funnel; the BDOS error path lands here.

Conventions visible in the tree (preserve):
- 4-space indentation, UPPERCASE mnemonics, `;` line / `;;` section comments.
- AR23 header blocks on every `.asm` / `.inc` file — including the new `test/inc/*.inc` files.
- Make recipes use tabs for command lines (Makefile syntax requirement) and 4-space-aligned variable definitions.
- `Makefile` recipes written terse but commented above with the why, not the what.
- One story per commit; short imperative subject + colon-separated context. Match the user's "story 1.4: every BDOS call now goes through a macro that catches errors" plain-English style.

Suggested commit message for Story 1.6 (when the dev finishes): `story 1.6: every test now runs through one make target; pass/fail reads off stdout.`

### Testing requirements

Story 1.6 has **the harness itself** as the deliverable; the testing requirements are the AC checks above. Specifically:

1. `make test` from project root runs the harness without error during build.
2. `harness_pass.asm` reports `pass`; `harness_fail.asm` reports `fail`.
3. Overall `make test` exit code is non-zero (because of the deliberate fail in `harness_fail.asm`).
4. Two consecutive `make test` runs produce byte-identical `test/cases/*.com` SHAs.
5. `test/smoke/*.asm` is not assembled or run by the harness.
6. `test/fixtures/` is mounted on iz-cpm drive A: AND drive B:.
7. `test/README.md` documents the workflow per AC5 / Task 6 contents.

Once Story 1.7 lands, that story's gap-buffer tests under `test/cases/gapbuf_*.asm` become the first real production-path validation through the harness. Story 1.6 prepares the runway; the runway gets used from 1.7 onwards.

### Project Structure Notes

After Story 1.6 the `test/` directory tree is:

```
test/
├── README.md                       # documented usage
├── Makefile                        # real harness (replaces stub)
├── inc/
│   ├── test_prologue.inc           # ORG, sentinel pair, test_start
│   └── test_epilogue.inc           # test_pass, test_fail
├── cases/
│   ├── harness_pass.asm            # demo: always passes
│   └── harness_fail.asm            # demo: always fails (code 0xE1, ctx 0xC0)
├── fixtures/
│   └── hello.txt                   # stub fixture
└── smoke/                          # unchanged from Stories 1.4, 1.5
    ├── bdos_call_smoke.asm
    └── statusln_smoke.asm
```

The architecture's reference layout (lines 1317-1331) anticipates exactly this structure. `test/build/` was reserved by Story 1.1's `.gitignore` but is unused — Story 1.6 does not introduce it. Per-case `.com` files build in-place under `test/cases/` rather than a separate build directory, mirroring how `vibe.com` builds at the project root rather than `build/vibe.com` (Story 1.1's choice).

After Story 1.6, the project has **two parallel build flows**:
- Production: `make` → `vibe.com` (project root).
- Test: `make test` → `test/cases/*.com` (built and run, then implicitly retained until `make -C test clean`).

Both share the same sjasmplus binary, the same flag set, and the same NFR18 reproducibility property.

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md] lines 460-499
- AR17 (headless test harness): [Source: _bmad-output/planning-artifacts/epics.md] line 169
- AR20 (fixture filesystem at test/fixtures/ mounted as B:): [Source: _bmad-output/planning-artifacts/epics.md] line 172
- TH1 (sentinel pass/fail address 0xCFFE): [Source: _bmad-output/planning-artifacts/architecture.md] lines 710-716
- TH2 (test driver — shell + Makefile): [Source: _bmad-output/planning-artifacts/architecture.md] lines 718-723
- TH2 (naming convention as cited in epics AC): [Source: _bmad-output/planning-artifacts/epics.md] line 493
- TH3 (fixture filesystem mount): [Source: _bmad-output/planning-artifacts/architecture.md] lines 725-728
- Test directory structure (canonical): [Source: _bmad-output/planning-artifacts/architecture.md] lines 271-282 + lines 1317-1331
- Test prologue/epilogue conventions: [Source: _bmad-output/planning-artifacts/architecture.md] lines 1058-1084
- Test file naming examples: [Source: _bmad-output/planning-artifacts/architecture.md] lines 1041-1054
- `make test` target description: [Source: _bmad-output/planning-artifacts/architecture.md] lines 295-297
- iz-cpm host context (Linux build host, headless): [Source: _bmad-output/planning-artifacts/architecture.md] lines 307-313
- PRD risk-rank-2 (gap-buffer tests ship with implementation, dependent on harness): [Source: _bmad-output/planning-artifacts/architecture.md] lines 748-750 + 1568-1569
- AR15 (single BDOS gateway — production-only; test scaffold carve-out): [Source: _bmad-output/planning-artifacts/epics.md] line 164
- AR22 (naming convention): [Source: _bmad-output/planning-artifacts/epics.md] line 177
- AR23 (header block): [Source: _bmad-output/planning-artifacts/epics.md] line 178
- AR24 (format rules): [Source: _bmad-output/planning-artifacts/epics.md] line 179
- NFR14 (sjasmplus 1.23.0 pin): [Source: _bmad-output/planning-artifacts/epics.md]
- NFR18 (reproducible build): [Source: _bmad-output/planning-artifacts/epics.md] line 136
- Story 1.1 (project skeleton, test/Makefile stub): [Source: _bmad-output/implementation-artifacts/1-1-project-skeleton-reproducible-build.md]
- Story 1.4 (BDOS_CALL, smoke pattern, sentinel byte usage): [Source: _bmad-output/implementation-artifacts/1-4-bios-bdos-shims-with-bdos-call-macro.md]
- Story 1.5 (statusln smoke pattern): [Source: _bmad-output/implementation-artifacts/1-5-status-line-module-with-single-message-funnel.md]
- Story 1.7 (consumer: gapbuf_* test cases): [Source: _bmad-output/planning-artifacts/epics.md] lines 543-545
- Stories 2.2 / 2.4 (consumers: fileio_* test cases against fixtures): [Source: _bmad-output/planning-artifacts/epics.md] lines 945-947, 1037-1039
- Existing test infrastructure state: [Source: test/Makefile (stub), test/README.md (one-liner), test/cases/ (empty), test/inc/ (empty), test/fixtures/ (empty), test/smoke/ (Stories 1.4 + 1.5 artifacts)]
- iz-cpm flag reference: [Source: `iz-cpm --help` output verified at story-create time — `-a <dir>` for drive A:, `-b <dir>` for drive B:, `-t` for BDOS call trace, `-T` for BDOS+BIOS trace, `-z` for CPU trace; default terminal ADM-3A]

## Dev Agent Record

### Agent Model Used

claude-opus-4-7 (1M context) — Claude Code dev-story workflow.

### Debug Log References

`make test` (after Task 4 + 5 + 6 + verification of Task 7):

```
sjasmplus --nologo --msg=err --raw=cases/harness_fail.com cases/harness_fail.asm
sjasmplus --nologo --msg=err --raw=cases/harness_pass.com cases/harness_pass.asm
  fail     harness_fail  (rc=0, output: FAIL E1 C0)
  pass     harness_pass

  1 pass, 1 fail
make: *** [Makefile:49: test] Error 1
```

NFR18 reproducibility (Task 8) — two clean rebuilds, identical SHAs:

```
RUN1:
ae09f8a9c910a2f9c918882f4e819a27bc04d09d6fee81d07cc605cf9b6dfb1c  test/cases/harness_fail.com
f512b7d1d3cbbc94a94b3e3003c3c500f5c605d2e397ab351f9cfdecdc346940  test/cases/harness_pass.com
RUN2:
ae09f8a9c910a2f9c918882f4e819a27bc04d09d6fee81d07cc605cf9b6dfb1c  test/cases/harness_fail.com
f512b7d1d3cbbc94a94b3e3003c3c500f5c605d2e397ab351f9cfdecdc346940  test/cases/harness_pass.com
MATCH
```

Smoke regression (Task 9) — both `test/smoke/bdos_call_smoke.asm` (Story 1.4) and `test/smoke/statusln_smoke.asm` (Story 1.5, marked done 2026-05-09) reassemble standalone with exit 0; `make test` output greps clean for "smoke" / "bdos_call" / "statusln_smoke" — harness does not run smoke files. AC9 carve-out holds.

### Completion Notes List

- All 9 tasks and their subtasks completed; all 9 acceptance criteria satisfied.
- **AC3 vs AC4 tension resolved in favor of AC4.** AC3 says the FAIL$ string is "exact"; AC4 demands the 0xE1 / 0xC0 codes be visible in the failure summary; iz-cpm has no RAM-dump flag (per dev notes), so stdout is the only post-run channel. Resolution: `test_fail` emits `FAIL <fc> <ctx>$` (FAIL token, then space, then 2-digit hex fail-code, space, 2-digit hex context, terminated by `$`). The harness's `grep -q "FAIL"` still detects the failure (FAIL is a substring); the per-case echo surfaces the codes verbatim. Documented in `test/inc/test_epilogue.inc`'s "Stdout contract" header block and in `test/README.md`'s "TH1 — sentinel byte pair" section. The stdout-derivation path (rather than the post-run RAM read) is the AC4 "pick one and document" choice.
- **Hex-print routine added to `test_epilogue.inc`** (`.write_hex_byte` and `.nibble_to_char` helpers). They are reachable only via CALL inside `test_fail` — no fall-through into `test_pass`. The test scaffold's footprint per case grows by ~30 bytes; well below any test-side budget.
- **`harness_fail` runtime output verified.** RC=0 from iz-cpm (clean exit via BDOS function 0); stdout literal: `FAIL E1 C0`. Per-case echo: `  fail     harness_fail  (rc=0, output: FAIL E1 C0)`. Codes match `LD A, 0xE1` / `LD B, 0xC0` from the demo case.
- **NFR18 verified.** Two clean rebuilds produce byte-identical .com files (SHA256 above). sjasmplus is deterministic on identical input; harness uses no `--date` / `--export` / path-embedding flags.
- **Project-root `make test` works unchanged.** Recurses into `test/` and produces matching output. Project-root Makefile not touched (per AC8). Story 1.1's stub message removed from `test/Makefile` (per AC8).
- **Smoke carve-out preserved.** `test/smoke/*.asm` not touched. Harness's `cases/*.asm` glob excludes them. Both pre-existing smokes — `bdos_call_smoke.asm` (Story 1.4) and `statusln_smoke.asm` (Story 1.5, marked done 2026-05-09) — reassemble standalone and are carved out of `make test` per AC9.
- **AR15 carve-out documented.** `test/inc/test_epilogue.inc` uses raw `CALL 0x0005` / `JP 0x0005` for BDOS functions 9 and 0; the carve-out is documented in the file's header block. Production code under `src/` and `inc/` continues to use `BDOS_CALL`.
- **iz-cpm flags.** `-a fixtures -b fixtures` mounts `test/fixtures/` as both A: and B: per AC1(c) / AC5 / TH3. Verified by running the harness with the demo cases (no fileio in 1.6, but the mount is wired and ready for Stories 2.2 / 2.4).
- **Build host.** Linux + GNU coreutils `timeout(1)` (verified, returns 124 on fire). Documented in `test/README.md` for future macOS / BSD work (out of scope for 1.6).

### File List

Created:
- `test/inc/test_prologue.inc`
- `test/inc/test_epilogue.inc`
- `test/cases/harness_pass.asm`
- `test/cases/harness_fail.asm`
- `test/fixtures/hello.txt`

Replaced:
- `test/Makefile` (stub → real harness)
- `test/README.md` (one-liner → documented usage)

Not touched (per ACs):
- Project-root `Makefile` (AC8 — recursion already correct)
- `src/*.asm`, `inc/*.inc` (production code)
- `test/smoke/*.asm` (AC9 — smoke carve-out)
- `.gitignore` (existing `*.com` covers `test/cases/*.com`)

### Change Log

| Date | Author | Change |
|------|--------|--------|
| 2026-05-09 | Story author | Initial story context — creates the headless test harness scaffold. Replaces test/Makefile stub with a real harness that iterates test/cases/*.asm, builds each .com via sjasmplus 1.23.0, runs each under iz-cpm with a 5-second timeout, parses stdout for PASS/FAIL emitted by the new test_pass / test_fail epilogue. Adds test/inc/test_prologue.inc + test_epilogue.inc as the shared scaffold (TH1 sentinel pair at 0xCFFE/0xCFFF, BDOS function 9 stdout signal, BDOS function 0 exit). Adds two demo cases (harness_pass.asm always passes, harness_fail.asm always fails with code 0xE1 / context 0xC0) to prove both detection paths. Documents AR15 carve-out for the test scaffold (raw CALL 0x0005 / JP 0x0005 — production code under src/ + inc/ continues through BDOS_CALL). Adds test/fixtures/ with a stub hello.txt and documents the iz-cpm B: drive mount in test/README.md per TH3 / AR20 (consumed by stories 2.2 / 2.4). Leaves test/smoke/ untouched (carve-out per AC9). Establishes the harness that every later story (1.7+) consumes for headless test cases. |
| 2026-05-09 | Dev (claude-opus-4-7) | Implemented the harness end-to-end. Wrote test/inc/test_prologue.inc + test_epilogue.inc (with hex-print extension to surface 0xCFFE/0xCFFF codes via stdout — AC3-vs-AC4 tension resolved in favor of AC4 codes-visible per AC4's "pick one and document" license). Wrote test/cases/harness_pass.asm + harness_fail.asm. Replaced test/Makefile stub with the real harness (sjasmplus build per case, iz-cpm run with timeout 5, stdout grep, per-case echo, non-zero exit on any non-pass). Added test/fixtures/hello.txt (CR+LF, CP/M canonical). Replaced test/README.md with documented usage covering TH1 / TH2 / TH3 / smoke carve-out / failure modes / build-host caveat. Verified make test from project root mirrors cd test && make test (AC8). Verified NFR18 reproducibility — two clean rebuilds produce byte-identical .com SHAs. Verified test/smoke/bdos_call_smoke.asm still assembles standalone (statusln_smoke.asm not yet on disk; Story 1.5 still ready-for-dev). All 9 ACs satisfied. Status: review. |
