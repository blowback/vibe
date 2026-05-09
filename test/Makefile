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

.PHONY: all test clean

all: test

cases/%.com: cases/%.asm inc/test_prologue.inc inc/test_epilogue.inc
	$(SJASMPLUS) $(SJASMPLUS_FLAGS) --raw=$@ $<

# Build then run: shell loop reports per-case; exits 1 on any
# non-pass. We build all cases first (fail fast on a build break),
# then run all cases (one bad runtime does not skip the rest).
test: $(COMS)
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
	rm -f cases/*.com
