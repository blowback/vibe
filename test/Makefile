# ============================================================
# VIBE — test/Makefile
#
# Headless test harness. Iterates test/cases/*.asm, assembles
# each to a .com via sjasmplus 1.23.0, runs each under iz-cpm
# with a 5-second timeout, parses the test program's stdout
# for PASS / FAIL, reports per-case pass / fail / timeout.
#
# Pass: stdout contains "PASS" -> harness reports `pass`.
# Fail: stdout contains "FAIL" -> harness reports `fail` and
#       exits non-zero.
# Timeout: timeout(1) returns 124 -> harness reports `timeout`
#          and exits non-zero.
# Other: anything else -> harness reports `unknown` and exits
#        non-zero.
#
# test/smoke/*.asm is intentionally outside the cases/*.asm
# glob — those one-off smokes from earlier stories run
# manually, not through this harness.
#
# Architecture references:
#   TH1: sentinel bytes at 0xCFFE / 0xCFFF
#        (architecture.md § Test harness — pass/fail signal).
#   TH3: fixture filesystem mounted as iz-cpm B: drive
#        (architecture.md § Test harness — fixture filesystem).
#        Mounted as A: too so simple tests do not have to think
#        about drives.
# ============================================================

SJASMPLUS         := sjasmplus
SJASMPLUS_FLAGS   := --nologo --msg=err
IZ_CPM            := iz-cpm
IZ_CPM_FIXTURES   := fixtures
TIMEOUT_SECS      := 5

CASES := $(wildcard cases/*.asm)
COMS  := $(CASES:.asm=.com)

# Epic-2 retro action A1: rebuild every test case whenever any
# production source or include header changes. The Story-2.1 /
# 2.2 incident pattern was that bulk-INCLUDE edits to test cases
# left some cases assembled against stale src/, masking 14 real
# breakages. Conservative coarse-grained dep: $(wildcard ...) is
# evaluated once at Make-parse time so a build run sees a
# consistent dependency snapshot. Story 3.1 lands this fix.
PROD_SRC := $(wildcard ../src/*.asm)
PROD_INC := $(wildcard ../inc/*.inc)

# Story 2.2 fixtures — generated at test-build time so the binaries
# don't have to be committed. big.bin is matched by the repo-root
# *.bin .gitignore rule; eof1a.txt is regenerated each `make test`
# and gitignored explicitly below.
FIXTURES := fixtures/eof1a.txt fixtures/big.bin fixtures/EMPTY.TXT

.PHONY: all test clean

all: test

cases/%.com: cases/%.asm inc/test_prologue.inc inc/test_epilogue.inc $(PROD_SRC) $(PROD_INC)
	$(SJASMPLUS) $(SJASMPLUS_FLAGS) --raw=$@ $<

# Story 2.2: small file with text + 0x1A EOF marker + trailing
# garbage that the load loop must discard. The 0x1A is written
# via the octal escape \032 so POSIX printf (e.g. dash, which
# Make invokes under Ubuntu) interprets it correctly — the \x1a
# hex escape is a GNU printf extension that dash does not honour.
fixtures/eof1a.txt:
	printf 'abc\032xyz' > $@

# Story 2.2: 33-KB file that exceeds GAP_BUFFER_MAX (32768). 264
# sectors of 128 bytes = 33792 bytes; the load loop's pre-read
# budget check fires after sector 256 and aborts with
# msg_file_too_large.
fixtures/big.bin:
	dd if=/dev/zero of=$@ bs=128 count=264 2>/dev/null

# Story 4.3: 1-sector empty file for the :e empty.txt round-trip
# test (test/cases/welcome_active-survives-e-empty-txt.asm). Byte
# 0 = 0x1A (CP/M soft-EOF), bytes 1..127 = 0x20 (sector padding).
# Matches the on-disk shape that fileio_save would write for a
# 0-byte buffer per Story 2.4 AC12. The 0x1A is written via the
# octal escape \032 so POSIX printf (dash, which Make invokes
# under Ubuntu) interprets it correctly — the \x1a hex escape is
# a GNU printf extension that dash does not honour. EMPTY.TXT is
# also rm'd by the clean: rule (it's the save-test's output file
# too); the FIXTURES dependency rebuilds it before any cases/*.com
# runs.
fixtures/EMPTY.TXT:
	printf '\032' > $@
	printf '%127s' '' >> $@

# Build then run: shell loop reports per-case; exits 1 on any
# non-pass. We build all cases first (fail fast on a build break),
# then run all cases (one bad runtime does not skip the rest).
test: $(COMS) $(FIXTURES)
	@pass=0; fail=0; \
	for com in $(COMS); do \
	  case=$$(basename $$com .com); \
	  out=$$(timeout --kill-after=1 $(TIMEOUT_SECS) $(IZ_CPM) -a $(IZ_CPM_FIXTURES) -b $(IZ_CPM_FIXTURES) $$com 2>&1); \
	  rc=$$?; \
	  if [ $$rc -eq 124 ]; then \
	    echo "  timeout  $$case"; \
	    fail=$$((fail+1)); \
	  elif echo "$$out" | grep -qE '\bPASS\b'; then \
	    echo "  pass     $$case"; \
	    pass=$$((pass+1)); \
	  elif echo "$$out" | grep -qE '\bFAIL\b'; then \
	    echo "  fail     $$case  (rc=$$rc, output: $$out)"; \
	    fail=$$((fail+1)); \
	  else \
	    echo "  unknown  $$case  (rc=$$rc, output: $$out)"; \
	    fail=$$((fail+1)); \
	  fi; \
	done; \
	if [ $$((pass+fail)) -eq 0 ]; then \
	  echo "  no test cases ran (cases/*.asm is empty)"; \
	  exit 1; \
	fi; \
	echo; \
	echo "  $$pass pass, $$fail fail"; \
	[ $$fail -eq 0 ]

clean:
	rm -f cases/*.com $(FIXTURES) fixtures/OUT.TXT fixtures/PAD100.TXT fixtures/RO.TXT
