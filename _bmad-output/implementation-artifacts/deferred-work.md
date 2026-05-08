# Deferred Work

Work items raised during reviews that are real but not actionable in the originating story.

## Deferred from: code review of story-1.1 (2026-05-08)

- **`make clean` doesn't recurse into `test/build/`** — `.gitignore` already reserves `test/build/`; once Story 1.6 lands the iz-cpm harness with build artifacts, top-level `make clean` will leave them stale. Address as part of Story 1.6 by adding `$(MAKE) -C test clean` to the top-level `clean` recipe and a matching `clean:` target in `test/Makefile`. (Sources: Acceptance Auditor + Blind Hunter.)
