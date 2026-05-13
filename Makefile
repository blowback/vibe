# ============================================================
# VIBE — top-level Makefile
#
# Targets:
#   all     (default) — assemble src/vibe.asm into vibe.com at
#                       project root (BA1).
#   clean             — remove vibe.com and the build/ directory.
#   test              — recurse into test/ (stub until Story 1.6).
#   push              — upload vibe.com to MicroBeast via SLIDE
#                       (stub until first real push, per BA4).
#   sizes             — per-section size from the listing —
#                       implements NFR9 audit baseline; see
#                       Story 1.12.
#
# sjasmplus invocation is pinned by BA2 — do NOT add --date,
# --export, host-path-embedding flags, etc. NFR18 (byte-identical
# rebuilds) requires the binary be a pure function of source.
# ============================================================

SJASMPLUS := sjasmplus
SJASMPLUS_FLAGS := --nologo --msg=err
SJASMPLUS_REQUIRED_VERSION := v1.23.0

# Wildcard inclusion is intentional: any .inc file in inc/ triggers a
# rebuild even if vibe.asm doesn't yet INCLUDE it. Empty stubs (e.g.
# bios.inc, bdos.inc, state.inc before Stories 1.3/1.4) cost nothing,
# and once their content + INCLUDE land together the dependency is
# already correctly tracked. Editing a populated-but-not-INCLUDEd .inc
# rebuilds vibe.com to the same bytes — benign.
SOURCES := $(wildcard src/*.asm) $(wildcard inc/*.inc)

.PHONY: all clean test push sizes check-toolchain

all: vibe.com

vibe.com: $(SOURCES) | build check-toolchain
	$(SJASMPLUS) $(SJASMPLUS_FLAGS) --raw=vibe.com --lst=build/vibe.lst --sld=build/vibe.sld src/vibe.asm

# NFR14 enforcement: refuse to build with anything other than the
# pinned sjasmplus version. Order-only prereq of vibe.com so the
# check runs once per build but does not perturb timestamps.
check-toolchain:
	@$(SJASMPLUS) --version 2>&1 | grep -q '$(SJASMPLUS_REQUIRED_VERSION)' || \
	  (echo "ERROR: sjasmplus $(SJASMPLUS_REQUIRED_VERSION) required (NFR14)."; \
	   echo "       got: $$($(SJASMPLUS) --version 2>&1 | head -1)"; \
	   exit 1)

build:
	mkdir -p build

clean:
	rm -f vibe.com
	rm -rf build

test:
	$(MAKE) -C test test

push:
	@echo "make push: SLIDE invocation deferred until first real push (BA4)."
	@echo "          Story 1.1 ships the target as a stub."

sizes: build/vibe.lst
	@awk '$$3 == "static_data_base" && $$4 == "EQU" { \
	        size = strtonum("0x" $$2) - 256; \
	        printf "code_section: %d bytes (~%d%% of NFR9 ~3 KB budget)\n", \
	               size, size * 100 / 3072; \
	        found = 1; \
	        exit } \
	    END { if (!found) { \
	            print "make sizes: ERROR — static_data_base not found in build/vibe.lst (sjasmplus listing format changed?)" > "/dev/stderr"; \
	            exit 1 } }' build/vibe.lst
