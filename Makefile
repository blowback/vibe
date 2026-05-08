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
#   sizes             — listing-file size audit (stub until later
#                       story wires it, per BA3).
#
# sjasmplus invocation is pinned by BA2 — do NOT add --date,
# --export, host-path-embedding flags, etc. NFR18 (byte-identical
# rebuilds) requires the binary be a pure function of source.
# ============================================================

SJASMPLUS := sjasmplus
SJASMPLUS_FLAGS := --nologo --msg=err
SJASMPLUS_REQUIRED_VERSION := v1.23.0

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

sizes:
	@echo "make sizes: listing-file size audit deferred to a later story (BA3)."
