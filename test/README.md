# VIBE — headless test harness

`make test` builds every `test/cases/*.asm` to a sibling `.com` via sjasmplus 1.23.0, runs each under iz-cpm with a 5-second timeout, and grades pass/fail by grepping the test program's stdout for `PASS` or `FAIL`. Per-case status prints to the terminal; any non-pass case fails the build.

## How to run

From the project root:

```sh
make test
```

Equivalently:

```sh
cd test && make test
```

`make -C test clean` removes the per-case `.com` artifacts.

## Adding a test case

1. Drop a file into `test/cases/<module>_<scenario>.asm`.
2. INCLUDE the prologue, write the body, INCLUDE the epilogue.
3. Run `make test`.

Minimal pass case:

```asm
    INCLUDE "../inc/test_prologue.inc"
    JP      test_pass
    INCLUDE "../inc/test_epilogue.inc"
```

Minimal fail case (with diagnostic codes):

```asm
    INCLUDE "../inc/test_prologue.inc"
    LD      A, 0xE1                 ; fail-code
    LD      B, 0xC0                 ; context byte
    JP      test_fail
    INCLUDE "../inc/test_epilogue.inc"
```

> **Always end the body with `JP test_pass` or `JP test_fail`.** The epilogue's first label is `test_pass:`, so a body that drops off the end falls into the pass branch and is silently reported as `pass` — usually not what you want. The `harness_pass.asm` demo's "empty body falls through to pass" is the *only* spec-licensed use of fall-through; everything else should jump explicitly.

## TH1 — sentinel byte pair

The prologue defines `TEST_RESULT EQU 0xCFFE` (pass code, 0 = pass) and `TEST_CONTEXT EQU 0xCFFF` (optional context). `test_start:` zeroes both at boot. `test_fail:` writes the caller's `A` to `(TEST_RESULT)` and `B` to `(TEST_CONTEXT)`.

The harness's primary signal is the stdout `PASS` / `FAIL` line. The sentinel bytes are belt-and-braces — they exist for post-mortem inspection (a debugger on real hardware in Story 1.12, or a future tool that reads RAM after exit). iz-cpm has no RAM-dump flag, so the harness surfaces the sentinel codes via stdout: `test_fail` emits `FAIL <fc> <ctx>` (hex), and the per-case echo line includes the full output.

## TH2 — naming convention

`<module>_<scenario>.asm` — lowercase module name, single underscore, lowercase hyphen-separated scenario, `.asm` extension. Architecture's reference examples (`architecture.md` § Test file naming):

- `gapbuf_insert-empty.asm`
- `gapbuf_insert-shift.asm`
- `parser_count-then-motion.asm`
- `parser_pending-operator.asm`
- `fileio_load-with-1A.asm`
- `fileio_save-write-protect.asm`
- `motion_w-empty-line.asm`
- `motion_b-line-start.asm`
- `undo_after-paste.asm`

The Story 1.6 demo cases (`harness_pass.asm`, `harness_fail.asm`) use `harness` as the implicit module — they exercise the harness itself.

## TH3 — fixture filesystem

The harness mounts `test/fixtures/` as iz-cpm drive **A:** AND drive **B:** via `iz-cpm -a fixtures -b fixtures`. Drive A: covers tests that don't think about drives (FCB drive byte = 0 = "current default"); drive B: is the architecture's canonical fixture mount per architecture lines 725-728, used by Stories 2.2 / 2.4's fileio tests.

To add a fixture:

1. Drop a file into `test/fixtures/`. The host filename can be lowercase; the FCB the test program builds is uppercase per CP/M's 8.3 rule (Story 2.2 lands the encoding pattern).
2. Reference it from your test case's FCB. Story 2.2 will land the full FCB encoding pattern.

`test/fixtures/hello.txt` is a stub fixture (CP/M-style `hello world\r\n`) — replace or augment as needed.

## test/smoke/ carve-out

`test/smoke/bdos_call_smoke.asm` (Story 1.4) and `test/smoke/statusln_smoke.asm` (Story 1.5) are pre-existing one-off smokes from earlier stories. The harness does **not** assemble or run them (the `cases/*.asm` glob excludes `smoke/`). They run manually:

```sh
cd test/smoke && sjasmplus --nologo --msg=err --raw=bdos_call_smoke.com bdos_call_smoke.asm
iz-cpm bdos_call_smoke.com
```

Future stories may relocate them into `test/cases/<module>_<scenario>.asm` form once the relevant module's test plan is detailed.

## Failure modes

- **timeout**: the `timeout 5` wrapper fired (test program hung or looped). Harness reports `timeout`.
- **build break**: sjasmplus errored out. Harness fails the build before the run loop starts.
- **fail**: stdout contained `FAIL`. The per-case echo includes the output (and thus the hex-encoded fail-code and context byte).
- **unknown**: test program emitted neither `PASS` nor `FAIL` and exited within timeout. Usually a corrupt epilogue, an early exit before the epilogue runs, or a test body that crashes iz-cpm.

Test bodies must NOT call BDOS function 9 themselves — the only `PASS` / `FAIL` text on stdout comes from `test_pass` / `test_fail`. If a test body needs to emit debug output, use a non-`PASS`/`FAIL` literal so it doesn't accidentally trip the harness's grep.

## Build host

Linux only. The harness uses GNU coreutils' `timeout(1)` (returns 124 on timeout fire). On macOS / BSD, replace with `gtimeout` (Homebrew coreutils). Out-of-Linux support is out of scope for Story 1.6.
