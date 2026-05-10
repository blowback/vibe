# Story 1.7: Gap buffer primitives + headless tests

Status: done

<!-- Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As the VIBE author,
I want `src/gapbuf.asm` exposing `gapbuf_init`, `gapbuf_insert`, `gapbuf_delete`, `gapbuf_move_gap`, and a stub `gapbuf_load`, with a comprehensive headless test suite under `test/cases/gapbuf_*.asm`,
so that PRD risk-rank-2 (gap-buffer correctness) is closed before any motion or edit handler depends on it, the SR2 two-halves invariant is mechanically validated, and AR14 (`gapbuf.asm` is the single buffer-mutation owner) is realised in code.

## Acceptance Criteria

1. **AC1 — `src/gapbuf.asm` exists with the project-standard module header.**
   Given `src/gapbuf.asm`,
   When I inspect it,
   Then it carries an AR23-conformant header block listing `Public: gapbuf_init, gapbuf_insert, gapbuf_delete, gapbuf_move_gap, gapbuf_load`, `State owned: gap_start, gap_end, cursor_offset` (per architecture line 870), register conventions, and `Dependencies: inc/equates.inc, inc/state.inc, src/statusln.asm`,
   And every public routine begins with the four-line `In:` / `Out:` / `Trashes:` / `Calls:` contract per AR23.

2. **AC2 — `gapbuf_init` lands the empty-buffer invariant.**
   Given a freshly-built test program that calls `gapbuf_init`,
   When the call returns,
   Then `(gap_start) == GAP_BUFFER_BASE`,
   And `(gap_end) == GAP_BUFFER_BASE + GAP_BUFFER_MAX`,
   And `(cursor_offset) == 0`,
   And the implied file length (per SR2: `(GAP_BUFFER_BASE + GAP_BUFFER_MAX) - gap_end + gap_start - GAP_BUFFER_BASE`) is `0`.

3. **AC3 — `gapbuf_insert` writes a byte and advances both gap and cursor on success.**
   Given a freshly-`gapbuf_init`-ed buffer and `(cursor_offset) == 0`,
   When `gapbuf_insert` is called with `A = 'X'`,
   Then `CF == 0` on return,
   And the byte at the original `gap_start` address holds `'X'`,
   And `(gap_start) == GAP_BUFFER_BASE + 1`,
   And `(gap_end) == GAP_BUFFER_BASE + GAP_BUFFER_MAX` (unchanged),
   And `(cursor_offset) == 1` (cursor follows the inserted byte; gap-tracks-cursor invariant preserved post-mutation),
   And a two-halves walk of the file (logical offsets 0..length-1) produces the single byte `'X'`.

4. **AC4 — `gapbuf_insert` refuses on buffer-full and leaves state untouched.**
   Given a buffer set up so that `(gap_start) == (gap_end)` (gap fully consumed) and `(cursor_offset)` matches the gap's logical position,
   When `gapbuf_insert` is called with any byte,
   Then `CF == 1` on return,
   And `(gap_start)`, `(gap_end)`, `(cursor_offset)` are byte-for-byte unchanged from the call site,
   And `status_set_message` was called with `HL = msg_file_too_large` (verified by reading the first bytes of `status_buffer` post-call against `"file too large"`),
   And `(status_dirty) != 0` (the funnel set the dirty flag).

5. **AC5 — `gapbuf_delete` refuses at BOF.**
   Given a freshly-`gapbuf_init`-ed buffer with `(cursor_offset) == 0`,
   When `gapbuf_delete` is called,
   Then `CF == 1` on return,
   And `(gap_start)`, `(gap_end)`, `(cursor_offset)` are unchanged,
   And no `status_set_message` call is required at this primitive layer (the caller decides whether to surface a message — vi `x` at BOF is a beep, not an error message).

6. **AC6 — `gapbuf_delete` mid-buffer extends the gap leftward and decrements the cursor.**
   Given a buffer with content (e.g., insert "ABC" then move cursor to logical offset 2 — i.e., between 'B' and 'C'),
   When `gapbuf_delete` is called,
   Then `CF == 0` on return,
   And the byte logically before the cursor (`'B'`) is consumed by extending the gap leftward — `(gap_start)` decrements by 1,
   And `(cursor_offset)` decrements by 1 (cursor follows the deletion; gap-tracks-cursor invariant preserved post-mutation),
   And a two-halves walk of the file produces `"AC"` (length 2).

7. **AC7 — `gapbuf_move_gap` relocates the gap and preserves file content.**
   Given a buffer with content (e.g., "ABCDEF" inserted, gap currently at logical offset 6 — EOF),
   When `gapbuf_move_gap` is called with `HL = 2` (target logical offset),
   Then on return, `(gap_start) == GAP_BUFFER_BASE + 2`,
   And `(gap_end) == (GAP_BUFFER_BASE + GAP_BUFFER_MAX) - 4` (4 bytes 'C','D','E','F' moved into the after-gap half),
   And `(cursor_offset)` is unchanged (move_gap is a primitive — it does not touch cursor_offset; the caller manages the cursor),
   And a two-halves walk of the file still produces `"ABCDEF"` byte-for-byte.

8. **AC8 — `gapbuf_move_gap` is a roundtrip identity for file content.**
   Given any non-empty buffer at any cursor offset,
   When `gapbuf_move_gap` is called with `HL = X` and then `HL = Y` for any `0 ≤ X, Y ≤ file_length`,
   Then a two-halves walk of the file produces the same byte sequence after each move (file content is invariant under gap relocation).

9. **AC9 — `gapbuf_load` is a stub returning CF=1 with a "not yet implemented" status message.**
   Given `gapbuf_load` exists in the public list (per AC1's header block),
   When I inspect its body for this story,
   Then it issues a `status_set_message` call with a message routed via the project's status-message string-table convention (AR16), the message text reads `"not yet implemented"` (lowercase, no trailing period, under 30 chars),
   And it sets CF and returns,
   And a `;` comment immediately above the routine reads `; TODO Story 2.2: replace this stub with the real FCB-based load. See architecture lines 911-927.`,
   And a future `:e` test in Story 2.2 will see the stub message if invoked from Story 2.2's pre-implementation harness.

10. **AC10 — `gapbuf.asm` is integrated into `src/vibe.asm` per AR25.**
    Given `src/vibe.asm`,
    When I inspect its INCLUDE order,
    Then `INCLUDE "gapbuf.asm"` appears after `INCLUDE "statusln.asm"` and before `INCLUDE "../inc/state.inc"` — matching architecture line 940's "statusln (load early — depended on by everything) → gapbuf" ordering,
    And `make` from a clean tree builds `vibe.com` cleanly,
    And the NFR10 ASSERT in `inc/state.inc` (`yank_end <= 0xD800`) still passes (no TPA overflow from the added code).

11. **AC11 — AR15 holds: no raw BDOS calls in `gapbuf.asm`.**
    Given `src/gapbuf.asm`,
    When I run `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY|BDOS_CALL' src/gapbuf.asm`,
    Then there are zero matches — gap buffer is pure-memory, does not touch BDOS, and does not invoke the BDOS_CALL macro,
    And the only `CALL` instructions in `gapbuf.asm` target intra-module helpers and `status_set_message` (the funnel for the buffer-full path).

12. **AC12 — `test/cases/gapbuf_insert-empty.asm` passes under `make test`.**
    Given the test file at `test/cases/gapbuf_insert-empty.asm`,
    When `make test` runs,
    Then the harness reports `pass     gapbuf_insert-empty`,
    And the body verifies AC2 + AC3: post-`gapbuf_init`, `gap_start` / `gap_end` / `cursor_offset` invariants; then `gapbuf_insert('X')` and verify CF=0, `(GAP_BUFFER_BASE) == 'X'`, `(gap_start) == GAP_BUFFER_BASE + 1`, `(cursor_offset) == 1`.

13. **AC13 — `test/cases/gapbuf_insert-fills-buffer.asm` passes under `make test`.**
    Given the test file at `test/cases/gapbuf_insert-fills-buffer.asm`,
    When `make test` runs,
    Then the harness reports `pass     gapbuf_insert-fills-buffer`,
    And the body verifies AC4: forces the buffer to its full state (e.g., post-`gapbuf_init`, directly set `(gap_start) := (gap_end) - 1` and `(cursor_offset)` to match, then call `gapbuf_insert` once to consume the last byte and verify CF=0; then call `gapbuf_insert` again and verify CF=1 + state unchanged + `status_buffer` starts with `"file too large"` + `(status_dirty) != 0`),
    And the test does NOT actually loop 32768 inserts (this would assemble fine but take ~50ms under iz-cpm; the direct-state-poke approach is cheaper and isolates the buffer-full path).

14. **AC14 — `test/cases/gapbuf_delete-at-bof.asm` passes under `make test`.**
    Given the test file at `test/cases/gapbuf_delete-at-bof.asm`,
    When `make test` runs,
    Then the harness reports `pass     gapbuf_delete-at-bof`,
    And the body verifies AC5: post-`gapbuf_init`, `gapbuf_delete` returns CF=1 with all three of `gap_start`, `gap_end`, `cursor_offset` unchanged (snapshot before, compare after).

15. **AC15 — `test/cases/gapbuf_move-roundtrip.asm` passes under `make test`.**
    Given the test file at `test/cases/gapbuf_move-roundtrip.asm`,
    When `make test` runs,
    Then the harness reports `pass     gapbuf_move-roundtrip`,
    And the body verifies AC7 + AC8: insert a small fixture (e.g., "ABCDEF"), capture a checksum of the two-halves walk, call `gapbuf_move_gap` to a different offset (e.g., HL=2), recompute the checksum and verify it matches, call `gapbuf_move_gap` back to original (HL=6 or wherever), recompute and verify still matches. Distinct fail-codes for each of the three checksum mismatches so the FAIL line surfaces which step broke.

16. **AC16 — `test/cases/gapbuf_random-ops.asm` passes under `make test`.**
    Given the test file at `test/cases/gapbuf_random-ops.asm`,
    When `make test` runs,
    Then the harness reports `pass     gapbuf_random-ops`,
    And the body runs a 100-iteration loop driving a deterministic PRNG (LCG with documented seed and constants) that selects randomly among `gapbuf_insert(random byte)`, `gapbuf_delete`, `gapbuf_move_gap(random target ≤ current file length)`,
    And after each op, walks the buffer in two halves to compute a running checksum (e.g. `xor` fold) and compares against an incrementally-maintained expected checksum (insert: xor in the inserted byte; delete: xor out the deleted byte read pre-delete; move: no checksum change),
    And on any mismatch, `JP test_fail` with `A = 0xE0 + iteration_low_byte` and `B = op_code` so the FAIL line surfaces both the iteration and the failing op,
    And the test runs to completion within the harness's `timeout 5` budget.

17. **AC17 — Reproducibility (NFR18) holds for the new test artifacts.**
    Given two consecutive `make test` runs on the same checkout,
    When I `sha256sum test/cases/gapbuf_*.com` after each run,
    Then all five SHAs match across runs (sjasmplus is deterministic on identical input; no timestamps embedded).

18. **AC18 — Project-root `make` still produces a byte-identical `vibe.com` across rebuilds.**
    Given the post-Story-1.7 `vibe.com` (now containing the gapbuf module),
    When I run `make clean && make` twice,
    Then both `vibe.com` outputs hash identically (NFR18; gapbuf adds bytes, but the bytes are deterministic).

## Tasks / Subtasks

- [x] **Task 1 — Create `src/gapbuf.asm` with the AR23 module header block** (AC: 1, 11)
  - [x] Header block per architecture lines 858-880 (the architecture's reference `gapbuf.asm` header is the canonical template — adopt it verbatim with cosmetic variation only):
    ```asm
    ; ============================================================
    ; Module: gapbuf.asm
    ; Purpose: Gap-buffer primitives. Owns the SR2 two-halves
    ;          invariant and is the single buffer-mutation owner
    ;          (AR14): all edits to the gap buffer enter through
    ;          gapbuf_insert / gapbuf_delete / gapbuf_move_gap.
    ;          Pure-memory module — no BDOS, no BIOS_CONOUT
    ;          (AR15: grep CALL 0x0005 returns zero hits).
    ;
    ; Public:
    ;   gapbuf_init      - reset to empty buffer
    ;   gapbuf_insert    - insert byte at cursor (gap-tracks-cursor)
    ;   gapbuf_delete    - delete byte before cursor
    ;   gapbuf_move_gap  - relocate gap to a target logical offset
    ;   gapbuf_load      - Story 1.7 STUB (Story 2.2 lands real impl)
    ;
    ; State owned (read/write):
    ;   gap_start, gap_end, cursor_offset
    ;
    ; Register conventions (across public entry points):
    ;   HL = working / address scratch (cursor offset, target offset)
    ;   DE = working / second address scratch
    ;   BC = byte count for LDIR / LDDR
    ;   A  = working byte (input/output for insert)
    ;
    ; Dependencies:
    ;   inc/equates.inc  (GAP_BUFFER_MAX)
    ;   inc/state.inc    (GAP_BUFFER_BASE, gap_start, gap_end,
    ;                     cursor_offset)
    ;   src/statusln.asm (status_set_message — buffer-full path,
    ;                     gapbuf_load stub)
    ; ============================================================
    ```
  - [x] Section dividers via `;;` per AR24 (`;; --- Public entry points ---`, `;; --- Internal helpers ---`).
  - [x] **NO `BDOS_CALL` invocations.** AC11 enforces this. Gap buffer is pure-memory.
  - [x] **NO direct writes to `status_buffer` / `status_dirty`** — call `status_set_message` only. AR12 (single status funnel — statusln is the only writer) applies.

- [x] **Task 2 — Implement `gapbuf_init`** (AC: 2)
  - [x] Four-line contract per AR23:
    ```asm
    ; ----------------------------------------------------------------
    ; gapbuf_init
    ; Reset to empty buffer. Establishes the SR2 two-halves invariant
    ; with the gap covering the full GAP_BUFFER_MAX extent and the
    ; cursor at logical offset 0.
    ;
    ; In:      (none)
    ; Out:     gap_start = GAP_BUFFER_BASE
    ;          gap_end   = GAP_BUFFER_BASE + GAP_BUFFER_MAX
    ;          cursor_offset = 0
    ; Trashes: A, HL, F
    ; Calls:   (none)
    ; ----------------------------------------------------------------
    ```
  - [x] Body: load the three constants and store. `LD HL, GAP_BUFFER_BASE; LD (gap_start), HL; LD HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX; LD (gap_end), HL; LD HL, 0; LD (cursor_offset), HL; RET`. (sjasmplus computes `GAP_BUFFER_BASE + GAP_BUFFER_MAX` as a single 16-bit immediate at assembly time.)
  - [x] **Do not zero the buffer payload.** The gap covers it entirely; bytes inside the gap are read-as-undefined and never visible through the two-halves walk. Saving the zero-init avoids 32768 writes at startup.
  - [x] **Do not zero `cursor_offset` independently of `gap_start`** — the empty-buffer invariant is `gap_start - GAP_BUFFER_BASE == cursor_offset` (both zero). If you ever decouple these, the gap-tracks-cursor contract breaks.

- [x] **Task 3 — Implement `gapbuf_insert`** (AC: 3, 4)
  - [x] Four-line contract per AR23 (mirrors architecture's reference at line 891-899):
    ```asm
    ; ----------------------------------------------------------------
    ; gapbuf_insert
    ; Insert byte A at cursor_offset. Calls gapbuf_move_gap if the
    ; gap is not already at the cursor, then writes A to (gap_start),
    ; advances gap_start by 1, advances cursor_offset by 1. The
    ; gap-tracks-cursor invariant is preserved post-mutation.
    ;
    ; In:      A = byte to insert
    ; Out:     CF = 0 on success; CF = 1 on buffer-full (state
    ;          unchanged, status_set_message called with
    ;          msg_file_too_large)
    ; Trashes: A, BC, DE, HL, F
    ; Calls:   gapbuf_move_gap (if gap not already at cursor),
    ;          status_set_message (on overflow)
    ; ----------------------------------------------------------------
    ```
  - [x] Implementation outline:
    1. **Gap-at-cursor check.** Compute `gap_start - GAP_BUFFER_BASE` (current gap logical offset); compare against `(cursor_offset)`. If not equal, push A (preserve the byte to insert), `LD HL, (cursor_offset)`, `CALL gapbuf_move_gap`, pop A.
    2. **Buffer-full check.** Load `(gap_start)` and `(gap_end)` into HL and DE; `OR A : SBC HL, DE` — if Z (HL == DE), gap is empty (full).
       - On full: `LD HL, msg_file_too_large; XOR A; CALL status_set_message; SCF; RET`. State is untouched (no writes happened yet).
    3. **Insert.** Restore (gap_start) into HL; `LD (HL), A` (write byte); `INC HL; LD (gap_start), HL` (advance gap_start). Then `LD HL, (cursor_offset); INC HL; LD (cursor_offset), HL` (advance cursor). `OR A` (clear CF) `RET`.
  - [x] **Buffer-full check timing.** AC4 demands "state unchanged" on full — the rc check MUST happen BEFORE any write to (gap_start) or (cursor_offset). If the order is flipped, a buffer-full insert silently corrupts state. Trace the pre-write check carefully.
  - [x] **`SBC HL, DE` clears CF before subtracting.** `SBC` reads CF; precede with `OR A` to clear CF deterministically. (Same trap as bdos_error_funnel's `OR A`.)
  - [x] **`gap_start == gap_end` is the buffer-full sentinel.** No "≥" check needed: by SR2 invariant, gap_start ≤ gap_end always; equality is the only full state.
  - [x] **Status message argument convention.** `status_set_message` takes `HL = ptr, A = code` (statusln.asm line 53-58). Pass `XOR A` for non-error code (it's reserved/ignored today; matches the convention from statusln_smoke.asm Phase 4).
  - [x] **`SCF` sets CF; `OR A` (or `AND A`) clears CF.** Don't forget to clear CF on the success path — caller's `JR C, .fail` branches on CF.

- [x] **Task 4 — Implement `gapbuf_delete`** (AC: 5, 6)
  - [x] Four-line contract per AR23:
    ```asm
    ; ----------------------------------------------------------------
    ; gapbuf_delete
    ; Delete the byte logically before the cursor. Calls
    ; gapbuf_move_gap if the gap is not already at the cursor,
    ; then decrements gap_start (consuming the byte just past the
    ; before-gap half), decrements cursor_offset. The gap-tracks-
    ; cursor invariant is preserved post-mutation.
    ;
    ; In:      (none — operates at cursor_offset)
    ; Out:     CF = 0 on success; CF = 1 at BOF (cursor_offset == 0,
    ;          no byte before cursor — state unchanged, no status
    ;          message — caller decides surface)
    ; Trashes: A, BC, DE, HL, F
    ; Calls:   gapbuf_move_gap (if gap not already at cursor)
    ; ----------------------------------------------------------------
    ```
  - [x] Implementation outline:
    1. **BOF check.** `LD HL, (cursor_offset); LD A, H; OR L` — if Z (HL == 0), at BOF. `SCF; RET`.
    2. **Gap-at-cursor check.** Same as insert — if `gap_start - GAP_BUFFER_BASE != cursor_offset`, `LD HL, (cursor_offset); CALL gapbuf_move_gap`.
    3. **Decrement gap_start.** `LD HL, (gap_start); DEC HL; LD (gap_start), HL`.
    4. **Decrement cursor.** `LD HL, (cursor_offset); DEC HL; LD (cursor_offset), HL`.
    5. **Clear CF and return.** `OR A; RET`.
  - [x] **No BOF status message at this layer.** AC5 explicitly carves this out. `vi`'s `x` at BOF beeps via the unbound-key handler (FR50); composition happens in `edits.asm` (Story 2.9 onwards), not here.
  - [x] **State-unchanged guarantee on BOF.** AC5's snapshot-before-snapshot-after check requires that the BOF path returns immediately — no move_gap call, no decrement. Order matters: BOF check FIRST, then move_gap, then decrement.

- [x] **Task 5 — Implement `gapbuf_move_gap`** (AC: 7, 8)
  - [x] Four-line contract per AR23:
    ```asm
    ; ----------------------------------------------------------------
    ; gapbuf_move_gap
    ; Relocate the gap to a target logical offset by copying bytes
    ; between the two halves (LDIR for right-shift, LDDR for left-
    ; shift). Does NOT modify cursor_offset — caller manages the
    ; cursor. File content (the two-halves walk byte sequence) is
    ; invariant under this call.
    ;
    ; In:      HL = target logical offset (0 ≤ HL ≤ file_length)
    ; Out:     gap_start, gap_end relocated; cursor_offset unchanged
    ; Trashes: A, BC, DE, HL, F
    ; Calls:   (none — pure memory move)
    ; ----------------------------------------------------------------
    ```
  - [x] Implementation outline:
    1. **Compute current gap logical offset.** `LD DE, (gap_start); LD A, GAP_BUFFER_BASE & 0xFF; SUB E; LD E, A; LD A, GAP_BUFFER_BASE >> 8; SBC A, D; LD D, A` (DE := gap_start - GAP_BUFFER_BASE). Or simpler: `LD HL, (gap_start); LD DE, GAP_BUFFER_BASE; OR A; SBC HL, DE` and use HL — but HL is the input arg, save it first. **Use the stack or DE for the computation; preserve HL = target.**
    2. **Compare target (HL) to current (DE).**
       - If HL == DE: nothing to do, `RET`.
       - If HL > DE: gap moves RIGHT — copy `target - current` bytes from `(gap_end) → (gap_start)` using LDIR, then `gap_start += (target - current)`, `gap_end += (target - current)`.
       - If HL < DE: gap moves LEFT — copy `current - target` bytes from `(gap_start - 1) → (gap_end - 1)` using LDDR (reverse direction), then `gap_start -= (current - target)`, `gap_end -= (current - target)`.
    3. **LDIR setup (right-shift).** `BC = target - current` (byte count); `HL = (gap_end)` (source: first byte of after-gap half); `DE = (gap_start)` (dest: first free slot in before-gap half). `LDIR`. After: `gap_start += BC`, `gap_end += BC`. (LDIR auto-increments HL/DE and decrements BC, so post-LDIR HL = gap_end + BC = new gap_end, DE = gap_start + BC = new gap_start. Just `LD (gap_start), DE; LD (gap_end), HL` — clever, but verify with a single-step trace before relying on it.)
    4. **LDDR setup (left-shift).** `BC = current - target`; `HL = (gap_start) - 1` (source: last byte of before-gap half); `DE = (gap_end) - 1` (dest: last position before after-gap half). `LDDR`. After: `gap_start -= BC`, `gap_end -= BC`. (LDDR auto-decrements; post-LDDR HL = gap_start - 1 - BC, DE = gap_end - 1 - BC. Then `INC HL; INC DE; LD (gap_start), HL; LD (gap_end), DE`.)
  - [x] **`OR A` before `SBC HL, DE` (signed/unsigned comparison).** Same trap as story 1.4: SBC reads CF; clear it first. The comparison `HL ?= DE` is unsigned, so use `JR Z, .equal`; for direction, after the SBC, CF is set if HL < DE (unsigned), clear if HL ≥ DE.
  - [x] **No cursor_offset update.** AC7 explicitly: move_gap is a primitive. Insert/delete update cursor; move_gap does not.
  - [x] **Out-of-range target is undefined.** Spec doesn't pin a behavior for `HL > file_length`. The dev's choice: ASSERT in debug build, or document as "caller must ensure 0 ≤ HL ≤ file_length". Document the choice in the routine header comment. (The internal callers from insert/delete pass `(cursor_offset)`, which is always valid by construction; external test callers in AC15 / AC16 pass valid offsets too. Defensive clamp is a future-story call.)
  - [x] **LDIR/LDDR are non-interruptible-safe on iz-cpm.** Both instructions block interrupts during the loop on real Z80. iz-cpm emulates this faithfully. No special handling needed.

- [x] **Task 6 — Implement `gapbuf_load` stub** (AC: 9)
  - [x] Reference layout:
    ```asm
    ; ----------------------------------------------------------------
    ; gapbuf_load
    ; Load file contents into the gap buffer.
    ;
    ; STORY 1.7 STUB: returns CF=1 with msg_not_implemented status.
    ; Real implementation lands in Story 2.2 (file load via :e
    ; filename, FR2/FR6/FR11 — architecture lines 911-927). The
    ; stub exists so gapbuf.asm's public list is complete from
    ; Story 1.7; consumers (Story 2.2's fileio.asm) will see CF=1
    ; until the stub is replaced.
    ;
    ; In:      DE = FCB pointer (Story 2.2 contract; ignored by stub)
    ; Out:     CF = 1 (always — stub)
    ; Trashes: A, BC, DE, HL, F
    ; Calls:   status_set_message
    ; ----------------------------------------------------------------
    ; TODO Story 2.2: replace this stub with the real FCB-based load.
    ;                See architecture lines 911-927.
    gapbuf_load:
        LD      HL, msg_not_implemented
        XOR     A
        CALL    status_set_message
        SCF
        RET
    ```
  - [x] **`msg_not_implemented` placement.** Architecture line 1021 says messages live in a dedicated section near end-of-code (currently in `src/statusln.asm` lines 167-174, the project-wide convention). **Add `msg_not_implemented: DEFB "not yet implemented", 0` to `src/statusln.asm`'s message block** alongside `msg_buffer_modified`, `msg_file_too_large`, etc. Lowercase, no trailing period, 19 chars (under the 30-char target). This keeps AR16 enforced (all status-message strings co-located).
  - [x] **Alternative: define `msg_not_implemented` locally in `gapbuf.asm`** with a TODO note for relocation when Story 2.2 deletes the stub. **Pick one approach and document it in the routine header comment.** Recommended: add it to `statusln.asm`'s table — that's the AR16-canonical location, and Story 2.2 can leave the symbol intact even after deleting the stub (other future "not yet implemented" stubs may want it). Either choice is defensible; recording the choice prevents drift.
  - [x] **Stub does not need DE to be a valid FCB.** It ignores the input. Documenting `In: DE = FCB` matches Story 2.2's contract early so callers (none today; fileio in Story 2.2) can be written against the final shape from day one.

- [x] **Task 7 — Wire `gapbuf.asm` into `src/vibe.asm` per AR25** (AC: 10)
  - [x] Edit `src/vibe.asm`: add `INCLUDE "gapbuf.asm"` immediately after the existing `INCLUDE "statusln.asm"` line (currently line 46). Per AR25 module include order (architecture line 939-940): `statusln.asm` (early — depended on by everything) → `gapbuf.asm`.
  - [x] **Do NOT move the `INCLUDE "../inc/state.inc"` line.** state.inc must remain the LAST include in vibe.asm — the positional anchor for `static_data_base EQU $`. Inserting gapbuf BEFORE state.inc keeps the layout intact: `code (statusln + gapbuf) → static block → gap buffer → reserved pool`.
  - [x] **Do NOT add a top-level `CALL gapbuf_init` to vibe.asm.** The `RET` stub at 0x0100 stays in place until Story 1.12 (init/teardown) wires real bring-up. gapbuf_init is called from tests in this story; production callers arrive in 1.12.
  - [x] **Verify the build is byte-deterministic across rebuilds (AC18).** `make clean && make && sha256sum vibe.com`, then again — both SHAs should match. sjasmplus is deterministic on identical input; no `--date` flag is in the invocation. If the SHAs differ, look for an accidentally-introduced `DEFS $-prev` pattern or a per-run macro expansion.
  - [x] **Update `src/vibe.asm`'s header block.** Add `; State owned (read/write):` should still note state.inc; the `; Public:` list still has only `input_loop` (no public symbol from gapbuf is exposed at the vibe.asm level — gapbuf's symbols are referenced internally by future modules). The `; Dependencies:` line should add `src/gapbuf.asm (Story 1.7)`. Mirror the formatting Story 1.5 used when adding statusln to this header.

- [x] **Task 8 — Add `msg_not_implemented` to `src/statusln.asm`** (AC: 9, supports Task 6)
  - [x] Edit `src/statusln.asm`: add the new message string to the existing message block (lines 167-174) alongside the existing seven plus `msg_bdos_error`. Place it in alphabetical order or grouped by category — a reasonable insertion is between `msg_nothing_to_undo` and `msg_no_write` (alphabetical by suffix `not_implemented` vs `no_write`). Cosmetic; the dev decides exact ordering.
    ```asm
    msg_not_implemented:    DEFB "not yet implemented", 0
    ```
  - [x] **AR16 conformance check.** Lowercase ✅, no trailing period ✅, 19 chars under the 30-char target ✅, null-terminated per AR24 default ✅.
  - [x] **Update `src/statusln.asm`'s module header `; Public:` block.** Add `msg_not_implemented` to the list of message strings (or note the category if the Public list groups them). The AR23 contract says public symbols are documented; message strings ARE public when other modules `LD HL, msg_*`.

- [x] **Task 9 — Create `test/cases/gapbuf_insert-empty.asm`** (AC: 12)
  - [x] Use the test-case structure described in the Dev Notes section "Test file structure pattern" (below). Three sections: pre-ORG production headers → INCLUDE prologue → test body → INCLUDE epilogue → INCLUDE production sources → input_loop stub → INCLUDE state.inc (last).
  - [x] Body outline:
    ```asm
        ; AC12: gapbuf_init invariants + first insert advances state correctly.
        CALL    gapbuf_init

        ; Verify gap_start == GAP_BUFFER_BASE
        LD      HL, (gap_start)
        LD      DE, GAP_BUFFER_BASE
        OR      A
        SBC     HL, DE
        JR      Z, .gs_ok
        LD      A, 0xE1
        LD      B, 0
        JP      test_fail
    .gs_ok:
        ; Verify gap_end == GAP_BUFFER_BASE + GAP_BUFFER_MAX
        LD      HL, (gap_end)
        LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX
        OR      A
        SBC     HL, DE
        JR      Z, .ge_ok
        LD      A, 0xE2
        LD      B, 0
        JP      test_fail
    .ge_ok:
        ; Verify cursor_offset == 0
        LD      HL, (cursor_offset)
        LD      A, H
        OR      L
        JR      Z, .co_ok
        LD      A, 0xE3
        LD      B, 0
        JP      test_fail
    .co_ok:
        ; Insert 'X' on empty buffer.
        LD      A, 'X'
        CALL    gapbuf_insert
        JR      NC, .ins_ok
        LD      A, 0xE4
        LD      B, 0
        JP      test_fail
    .ins_ok:
        ; Verify byte landed at GAP_BUFFER_BASE
        LD      A, (GAP_BUFFER_BASE)
        CP      'X'
        JR      Z, .b_ok
        LD      A, 0xE5
        LD      B, 0
        JP      test_fail
    .b_ok:
        ; Verify gap_start == GAP_BUFFER_BASE + 1
        LD      HL, (gap_start)
        LD      DE, GAP_BUFFER_BASE + 1
        OR      A
        SBC     HL, DE
        JR      Z, .gs2_ok
        LD      A, 0xE6
        LD      B, 0
        JP      test_fail
    .gs2_ok:
        ; Verify cursor_offset == 1
        LD      HL, (cursor_offset)
        LD      DE, 1
        OR      A
        SBC     HL, DE
        JR      Z, .co2_ok
        LD      A, 0xE7
        LD      B, 0
        JP      test_fail
    .co2_ok:
        JP      test_pass
    ```
  - [x] **Distinct fail-codes (0xE1..0xE7).** Each check has its own code so the FAIL line surfaces which assertion broke. Document in a leading `;` comment block per the smoke-test pattern.

- [x] **Task 10 — Create `test/cases/gapbuf_insert-fills-buffer.asm`** (AC: 13)
  - [x] Body outline:
    1. `CALL gapbuf_init`.
    2. **Force buffer to one-byte-left state.** `LD HL, (gap_end); DEC HL; LD (gap_start), HL` (puts gap_start one byte before gap_end). Then `LD HL, GAP_BUFFER_MAX - 1; LD (cursor_offset), HL` (cursor at logical offset matching the gap position — `gap_start - GAP_BUFFER_BASE == cursor_offset` invariant holds).
    3. **One last successful insert.** `LD A, 'L'; CALL gapbuf_insert`. Verify CF==0; verify `(gap_start) == (gap_end)` (now full).
    4. **Buffer-full insert.** Snapshot `(gap_start)`, `(gap_end)`, `(cursor_offset)` to scratch RAM. `LD A, 'F'; CALL gapbuf_insert`. Verify CF==1.
    5. **State-unchanged check.** Compare each of the three snapshots to the post-call values; FAIL on any mismatch with distinct codes.
    6. **Status-message check.** `LD A, (status_buffer); CP 'f'` (first byte of "file too large"). `LD A, (status_buffer + 13); CP 'e'` (last byte of payload). `LD A, (status_buffer + 14); CP ' '` (first pad byte). FAIL on mismatch with distinct codes.
    7. **`status_dirty` check.** `LD A, (status_dirty); OR A; JR Z, .fail_dirty`.
  - [x] **Direct state poke is OK at this primitive layer.** Test cases have full RAM access; setting `(gap_start) := (gap_end) - 1` directly is the cheapest way to reach the buffer-full edge. The 32768-iteration insert loop would also work and would test the boundary differently, but the direct-poke variant isolates the buffer-full *primitive* from the insert *path*. Either is correct; the direct-poke is faster and AC4-aligned.
  - [x] **Snapshot RAM convention.** Reserve a short DEFS block in the test case (e.g., `snap_gs: DEFS 2; snap_ge: DEFS 2; snap_co: DEFS 2`) for the pre-call snapshot. Store after the test body / before INCLUDEing production sources, OR in the unused `0xCFE0..0xCFFD` scratch range above the sentinel pair. Document choice.

- [x] **Task 11 — Create `test/cases/gapbuf_delete-at-bof.asm`** (AC: 14)
  - [x] Body outline:
    1. `CALL gapbuf_init`.
    2. **Snapshot state.** Capture `(gap_start)`, `(gap_end)`, `(cursor_offset)` to scratch.
    3. **Delete attempt.** `CALL gapbuf_delete`. Verify CF==1 (FAIL with distinct code if not).
    4. **State-unchanged check.** Compare each snapshot — FAIL with distinct codes on any mismatch.
    5. `JP test_pass`.
  - [x] **No status-message check at BOF.** AC5 says no message is required at this layer. If the implementation inadvertently calls `status_set_message`, the test passes (msg-set is not a contract violation), but the dev should NOT add a `status_set_message` call for BOF — caller composition (Story 2.9 onwards) decides surface.

- [x] **Task 12 — Create `test/cases/gapbuf_move-roundtrip.asm`** (AC: 15)
  - [x] Body outline:
    1. `CALL gapbuf_init`.
    2. **Insert a fixture.** "ABCDEF" via 6 calls to `gapbuf_insert`. Verify each CF==0 (sanity).
    3. **Compute checksum #1** (current state — gap is at logical offset 6 / EOF). Two-halves walk: read each logical offset 0..5 via SR3 mapping, XOR each into a running total. Save as `chk1`.
    4. **Move gap to offset 2.** `LD HL, 2; CALL gapbuf_move_gap`. Verify gap pointers updated correctly: `(gap_start) == GAP_BUFFER_BASE + 2`, `(gap_end) == GAP_BUFFER_BASE + GAP_BUFFER_MAX - 4`.
    5. **Compute checksum #2.** Walk file content; verify equals `chk1`. FAIL with distinct code if not.
    6. **Move gap back to offset 6.** `LD HL, 6; CALL gapbuf_move_gap`. Verify gap pointers reset.
    7. **Compute checksum #3.** Verify equals `chk1`. FAIL with distinct code if not.
    8. **Cursor invariance.** Compare `(cursor_offset)` to its pre-move value (it should NOT have changed — move_gap doesn't touch cursor per AC7). FAIL with distinct code if not.
    9. `JP test_pass`.
  - [x] **Two-halves walk helper.** Define a local helper `walk_xor_checksum` that reads the file content via the SR3 mapping (architecture line 441-445) and XORs each byte into a running total in A:
    ```asm
    ; Compute XOR-fold checksum of file content.
    ; In:  (gap_start), (gap_end) describe current buffer state.
    ; Out: A = XOR of all file bytes, length 0..file_length-1.
    ; Trashes: A, BC, DE, HL, F.
    walk_xor_checksum:
        LD      A, 0                  ; running checksum
        ; Walk before-gap half: GAP_BUFFER_BASE .. (gap_start - 1)
        LD      HL, GAP_BUFFER_BASE
        LD      DE, (gap_start)
    .pre_loop:
        OR      A
        SBC     HL, DE
        ADD     HL, DE                ; restore HL (compare nondestructively)
        JR      Z, .post_setup
        ; Read byte, XOR
        ...
    ```
    (Sketch only — the dev fills in. The walk is identical for every gapbuf test, so it's worth factoring into a helper that all four content-checking tests share. Possible location: `test/inc/test_gapbuf_helpers.inc` — INCLUDE it after the production sources but before state.inc. Keep this optional; if simpler-per-case is more legible, do that instead.)

- [x] **Task 13 — Create `test/cases/gapbuf_random-ops.asm`** (AC: 16)
  - [x] Body outline:
    1. `CALL gapbuf_init`.
    2. **Initialise PRNG state.** A simple LCG suffices: `state := state * 1103515245 + 12345` (mod 2^32, take low 16 bits as the result). For Z80 a common choice is XOR-shift or a Lehmer LCG with 16-bit state (`state := state * 25173 + 13849`, mod 2^16). Pick deterministic constants and seed (e.g. seed = 0x4321). **Document the constants and seed in a comment block** so a future failure can be reproduced bit-for-bit.
    3. **Initialise expected-checksum.** `expected_chk := 0`. Stored at a scratch RAM address (e.g. `0xCFE0`).
    4. **Loop 100 iterations.**
       ```
       FOR i = 0..99:
         draw r = next_random()
         op = r mod 3
         CASE op:
           0: insert
              draw byte = next_random() mod 256
              CALL gapbuf_insert with A = byte
              IF CF==0:  expected_chk ^= byte
              (IF CF==1: buffer-full — skip this iteration; should not happen with 100 iterations on a 32K buffer, but defensive)
           1: delete
              IF cursor_offset > 0:
                 read byte logically before cursor (use SR3 mapping to find physical addr at offset cursor-1)
                 expected_chk ^= byte
                 CALL gapbuf_delete
                 IF CF != 0: FAIL (unexpected CF=1 mid-buffer)
              ELSE:
                 (BOF — delete returns CF=1; checksum unchanged; continue)
                 CALL gapbuf_delete  (still call so the BOF path is exercised)
           2: move
              draw target = next_random() mod (file_length + 1)
              LD HL, target
              CALL gapbuf_move_gap
              (no checksum change)
         POST: walk_xor_checksum → actual
               IF actual != expected_chk:
                  LD A, 0xE0 + i (low byte)
                  LD B, op
                  JP test_fail
       END FOR
       JP test_pass
       ```
    5. **Helper subroutines** the test needs:
       - `prng_next` (returns random in HL or A, advances state)
       - `walk_xor_checksum` (per Task 12)
       - `read_byte_before_cursor` (SR3 mapping at logical offset cursor-1; returns byte in A)
       - `compute_file_length` (returns HL = `(gap_end - gap_start)`-bias; specifically `(GAP_BUFFER_BASE + GAP_BUFFER_MAX) - (gap_end) + (gap_start) - GAP_BUFFER_BASE` — simplify algebraically: `GAP_BUFFER_MAX - (gap_end - gap_start)`. Computable as `LD HL, GAP_BUFFER_MAX; LD DE, (gap_end); OR A; SBC HL, DE; LD DE, (gap_start); ADD HL, DE; LD DE, GAP_BUFFER_BASE; OR A; SBC HL, DE` — simplify in the actual code).
    6. **Iteration-i fail code encoding.** AC16 says `A = 0xE0 + iteration_low_byte` and `B = op_code`. With i ∈ 0..99, iteration_low_byte = i (since i < 256 always for 100 iters). So fail-code = 0xE0..0xE0+99 = 0xE0..0x143 — wait, 0xE0+99 = 0x143 which exceeds 1 byte. Adjust: clamp to `A = 0xE0 + (i & 0x1F)` (low 5 bits, wraps every 32 iters), or just emit `A = i` (raw iteration number) and `B = 0xC0 + op_code`. **Pick a scheme and document.** Recommend: `A = 0xC0 + op_code` (op_code is 0/1/2 → 0xC0, 0xC1, 0xC2 — three distinct values for the three failure surfaces), `B = i mod 256` (raw iteration). The FAIL line then reads e.g. `FAIL C1 0F` — op_code 1 (delete), iteration 15.
    7. **Buffer-full guard for inserts.** With 100 iterations and a 32K buffer, the buffer can't fill. But defensive: if `gapbuf_insert` returns CF==1 unexpectedly, FAIL with a special code (e.g., A=0xCF, B=i). Same for `gapbuf_delete` returning CF==1 mid-buffer when `cursor_offset > 0`.
    8. **Mod operations on 16-bit values.** `r mod 3`, `r mod 256`, `r mod (file_length + 1)`. mod 3 via a small helper (subtract 3 in a loop until below 3, or mask + branch). mod 256 = `LD A, L` (low byte). mod (n+1) for arbitrary n requires a divide; for small n, subtract-loop. Keep it simple — these helpers are short.
  - [x] **Determinism is the point.** A failure that the dev can reproduce by re-running `make test` is a debuggable failure. A failure under a non-deterministic seed is a flaky test. AC16's "deterministic PRNG with documented seed and constants" is the contract.

- [x] **Task 14 — Reproducibility check (NFR18)** (AC: 17, 18)
  - [x] **Test artifact reproducibility.** Run `make -C test clean && make test`, capture `sha256sum test/cases/gapbuf_*.com` per run. Two consecutive runs should produce identical SHAs (per file). Same as Story 1.6 Task 8.
  - [x] **Production binary reproducibility.** Run `make clean && make`, capture `sha256sum vibe.com` per run. Two consecutive runs should produce identical SHAs.
  - [x] **Embed both into Debug Log References (this story file)** — record the SHAs once at completion as evidence.

- [x] **Task 15 — Confirm `make test` passes overall** (AC: 12, 13, 14, 15, 16)
  - [x] After Tasks 1-13, `make test` from project root should report:
    ```
      pass     gapbuf_delete-at-bof
      pass     gapbuf_insert-empty
      pass     gapbuf_insert-fills-buffer
      pass     gapbuf_move-roundtrip
      pass     gapbuf_random-ops
      fail     harness_fail  (rc=0, output: FAIL E1 C0)
      pass     harness_pass

      6 pass, 1 fail
    ```
    (Order may vary depending on how Make's wildcard expansion sorts; verify the five gapbuf tests are all `pass`.)
  - [x] **The deliberate `harness_fail` is expected to fail** — that's by design from Story 1.6 (AC4). Overall `make test` exits non-zero because of `harness_fail`. The five gapbuf tests are the ones that must pass.
  - [x] **If a gapbuf test fails:** the FAIL line includes the per-case fail-code (and context byte). Read the fail-code against the test's `; ----- failure paths` comment block to identify which assertion broke. Trace the implementation against the AC to find the bug.

### Review Findings

Code review on 2026-05-10 (3 layers: Blind Hunter, Edge Case Hunter, Acceptance Auditor). 9 dismissed as noise / spec-issue / cosmetic. 4 patches applied; 1 deferral promoted to a patch (mid-delete dedicated test); 1 deferral remaining (move_gap defensive ASSERT — needs project-wide debug-build infrastructure that doesn't exist yet).

- [x] [Review][Patch] random-ops walk-mismatch fail code wraps past 0x00 at iter ≥ 32 [test/cases/gapbuf_random-ops.asm:118-126] — `ADD A, 0xE0` with iter=32 yields A=0x00 (CF discarded). At iter=32, fail-code 0x00 is the same byte as the pass sentinel; iters 33..99 emit 0x01..0x43. Fixed by switching to `A = 0xC0 + op_code, B = iter` per Task 13 step 6 recommendation. FAIL line now reads e.g. `FAIL C1 20` — op 1 (delete), iter 32, unambiguous; iter byte never aliases the pass sentinel.
- [x] [Review][Patch] `modn1_hl` runtime claim "max ~330 iters" wrong when file_length==0 [test/cases/gapbuf_random-ops.asm:189-198] — when `compute_file_length` returns 0, M=1 and the loop runs up to ~HL iterations (~65535). Comment rewritten to state the real worst-case and confirm the iz-cpm 5-second budget still holds.
- [x] [Review][Patch] `input_loop` stub copy-pasted across all 5 test cases — hoisted into `test/inc/test_input_loop_stub.inc`. All six gapbuf test cases now `INCLUDE "../inc/test_input_loop_stub.inc"`. SHA-verified the refactor is byte-equivalent for the three tests whose only change was this INCLUDE swap (gapbuf_insert-empty.com, gapbuf_insert-fills-buffer.com, gapbuf_move-roundtrip.com all hash identically before/after).
- [x] [Review][Patch] BOF-delete test does not assert "no status side-effect" [test/cases/gapbuf_delete-at-bof.asm] — added a 0xE5 fail-code that seeds `status_dirty := 0` pre-call and asserts it is still 0 post-call. AC5's "no status_set_message at this layer" is now mechanically enforced; a regression that added a status write to the BOF path would now fail the test rather than passing silently.
- [x] [Review][Defer→Patch] AC6 (mid-buffer delete) had no dedicated deterministic test file — promoted from defer to patch. Created `test/cases/gapbuf_delete-mid.asm` (AC6 specifically): inserts "ABC", direct-pokes `cursor_offset := 2` (vi-`h` motion stand-in), calls `gapbuf_delete`, asserts CF=0 + `gap_start = BASE+1` + `gap_end = BASE+MAX-1` + `cursor_offset = 1` + walk-XOR-fold checksum = `'A' XOR 'C'`. Pins the LDDR-shift and gap_start decrement that AC6 specifies. Test passes; .com SHA `d09ef9efd324ecc796bf55e09a39e1908dd39175b6bb75f122d5a180dca100f8` (reproducible across rebuilds).
- [x] [Review][Defer] `gapbuf_move_gap` has no debug-build ASSERT for out-of-range targets or `gap_size==0` precondition [src/gapbuf.asm:240-301] — deferred, pre-existing — sjasmplus `ASSERT` is build-time only (operates on assembly-time constants); a runtime debug check requires choosing what happens on assert failure (status_set_message? halt? trap a sentinel byte?) and a project-wide `IFDEF DEBUG` build flag, neither of which exist yet. Revisit when a project-wide `ASSERT_DEBUG` macro and debug-build mode land (architectural choice, not a Story 1.7 fix).

Dismissed (recorded for audit; not actionable):
- `gapbuf_init` Trashes contract (HL, F) is wider than body needs — code preserves F. Conservative-loose, not wrong.
- `gapbuf_load` stub Trashes contract (A,BC,DE,HL,F) wider than the stub body — same conservative-loose pattern; defensible.
- Redundant `OR A` idiom repeated in three sites in gapbuf.asm — style; fold into a helper if a fourth site appears.
- `.equal` branch of `gapbuf_move_gap` — comment "restore stack" reads as misleading; values are discarded, not restored. Cosmetic.
- `prng_next` lacks defensive comment about LFSR zero-state lockup — non-zero seed is documented; speculative.
- `mod3_a` distribution slightly biased (0/1 ops draw 86×, op 2 draws 84× per byte domain) — informational only.
- `status_set_message` IX/IY clobber concerns — speculative future-proofing; status_set_message body in scope of this review does not touch IX/IY.
- AC9 TODO comment line-broken across two lines vs spec single-line — content matches verbatim; cosmetic.
- AC16 says "LCG" but implementation uses Galois LFSR — spec-text issue; LFSR satisfies the load-bearing "deterministic + documented" requirement.

## Dev Notes

### Why this story exists

Story 1.7 closes **PRD risk-rank-2** (gap-buffer correctness — architecture lines 65-66 + 748-750) by landing the gap-buffer module *with comprehensive tests*. The architecture's implementation sequence (lines 1568-1569) explicitly calls this out: "PRD risk-rank-2 demands tests ship with implementation". This is the first story where production *behaviour* (not just scaffolding) is mechanically validated by the headless harness Story 1.6 created.

Beyond closing risk-rank-2, this story:

- **Concretely realises AR14** (single buffer-mutation owner): `gapbuf.asm` is the only module that can call `gapbuf_insert/delete/move_gap`. Future modules (motions, edits, visual, fileio, undo) read the buffer freely but mutate only via these three entry points.
- **Concretely realises SR2** (gap-buffer two-halves invariant): every public entry point preserves `gap_start ≤ gap_end ≤ GAP_BUFFER_END` and the file-length formula `length = GAP_BUFFER_MAX - (gap_end - gap_start)`.
- **Concretely realises SR3** (cursor-to-buffer mapping): the test cases that walk the file (move-roundtrip, random-ops) implement the cursor → physical address mapping from architecture line 441-445.
- **Establishes the gap-tracks-cursor invariant** as a *post-mutation* invariant (architecture line 102): cursor motions don't move the gap, but every mutation re-aligns gap to cursor before mutating, so post-mutation `gap_start - GAP_BUFFER_BASE == cursor_offset`.
- **Prepares the path for Story 2.2** (file load): `gapbuf_load` is exposed as a stub now so Story 2.2's fileio.asm can be written against the final public-symbol shape from day one. Story 2.2 deletes the stub and lands the FCB-based body.

After Story 1.7, the architecture's "gap buffer" subsystem is implementation-complete: every later story that touches the buffer (motions, edits, visual, search, fileio, undo) reads/writes through these primitives, never directly.

### Critical guardrails for the dev agent

**🛑 The buffer-full check in `gapbuf_insert` MUST happen BEFORE any state write.** AC4 demands "state unchanged on full". If the implementation writes the byte to (gap_start), then advances gap_start, then realises the buffer was full and rolls back — that's a partial mutation that's hard to roll back correctly. The clean structure: check first (`SBC HL, DE` on gap_start vs gap_end → `JR Z, .full`), only then mutate. If gap-not-at-cursor, the move_gap call happens BEFORE the full-check, but that's a separate pure-memory move that doesn't change the buffer-fullness condition (move_gap shifts bytes between halves; gap size invariant). So the order is: move_gap (if needed) → full check → write+advance.

**🛑 The BOF check in `gapbuf_delete` MUST happen BEFORE the move_gap call.** Same shape as the insert full-check. AC5 demands "state unchanged on BOF". A move_gap call that fires before the BOF check would not change state (move with `HL = 0` and gap already at 0 is a no-op), but it costs cycles. Cleaner: check `cursor_offset == 0` first, return CF=1 immediately if so.

**🛑 `OR A` before `SBC HL, DE` is non-negotiable.** SBC reads the carry flag; if you don't clear it first, the subtraction borrows a phantom 1 and the comparison silently lies. Story 1.4's bdos_error_funnel hit this exact trap. Pre-clear with `OR A` (or `AND A`) every time. Story 1.3's GAP_BUFFER_MAX comment also flags this: "bounds compares against cursor offsets MUST be unsigned".

**🛑 Bounds compares are unsigned.** `GAP_BUFFER_MAX = 0x8000` (high bit set as a 16-bit value). `JP M` / `JP P` against bounds compares treat the high bit as sign — wrong. Use `SBC HL, DE` + `JR C` / `JR NC` / `JR Z` for unsigned compares. Equates.inc lines 38-39 documents this trap explicitly.

**🛑 LDIR and LDDR auto-increment (or auto-decrement) HL, DE, and decrement BC.** After LDIR, HL = source_start + count, DE = dest_start + count, BC = 0. After LDDR, HL = source_start - count, DE = dest_start - count, BC = 0. The test that cleverly uses post-LDIR HL/DE as the new gap_start / gap_end (Task 5 step 3) is correct but requires single-step verification — use iz-cpm's `--cpu-trace` flag if the move_gap test fails and you need to trace. **Recommend writing the boring version first** (compute new gap_start / gap_end via explicit `ADD HL, BC` after the loop) and clever-optimising later if NFR9 budget pressure demands.

**🛑 LDDR's source / dest pointers are the LAST byte of each region, not the first.** A common bug: setting LDDR with `HL = (gap_start)` and `DE = (gap_end)` instead of `HL = (gap_start) - 1` and `DE = (gap_end) - 1`. The off-by-one writes one byte past the end of the dest region (corrupts memory) and copies one byte past the source region's start (reads garbage). Trace the LDDR setup carefully — pre-decrement HL and DE before LDDR.

**🛑 `gapbuf.asm` is production code — AR15 applies.** Raw `CALL 0x0005` is forbidden. The `BDOS_CALL` macro is the only legal BDOS gateway. Gap buffer doesn't actually call BDOS at all (it's pure-memory), so neither raw nor macro should appear. AC11 enforces this via grep. The test scaffold's AR15 carve-out (Story 1.6 epilogue) does NOT extend to production code under `src/`.

**🛑 `gapbuf_move_gap` does NOT update `cursor_offset`.** This is a primitive — it relocates the gap. The cursor is the user's position in logical file space; cursor moves are separate (motions.asm in Story 2.5+). Insert and delete update cursor_offset because they change file length; move_gap doesn't change file length. AC7 / AC15 step 8 explicitly verify this.

**🛑 `cursor_offset` advancement is on-success only.** If `gapbuf_insert` returns CF=1 (buffer-full), `cursor_offset` MUST NOT advance. Same for `gapbuf_delete` on BOF. AC4 / AC5's "state unchanged" requires this. Trace the success vs. failure paths separately to confirm.

**🛑 Test cases that exercise buffer-full need direct state poke, not 32K inserts.** The 32K-iteration loop would assemble fine and run in ~50ms under iz-cpm, but it's wasteful and burns harness time. AC13's direct-poke (`(gap_start) := (gap_end) - 1`) is the spec-licensed approach. Use it.

**🛑 Test files that INCLUDE production sources need `input_loop` as a local stub.** `src/statusln.asm`'s `bdos_error_funnel` ends with `JP input_loop`. `input_loop` is defined in `src/vibe.asm`, which tests do NOT INCLUDE. Provide a local stub (per the smoke-test pattern from Story 1.5):
```asm
input_loop:
    LD      C, BDOS_EXIT
    CALL    BDOS_ENTRY
    RET
```
**This stub is unreached in normal gapbuf tests** (gapbuf doesn't call BDOS_CALL), but the symbol must resolve at link time. The smoke-test convention from `test/smoke/statusln_smoke.asm` is the prior art.

**🛑 `state.inc` MUST be the LAST INCLUDE in every test file.** It's positional — `static_data_base EQU $` resolves to "first address past code". If state.inc is INCLUDEd before `INCLUDE "../../src/gapbuf.asm"`, then static_data_base is wrong (somewhere in the middle of code). The test won't crash but state symbols will alias the gapbuf module's body — silent corruption. Story 1.3's design explicitly documented this (state.inc lines 36-40 ASSERT static_data_base >= 0x0101, but does not catch the "INCLUDEd between source files" case).

**🛑 Do NOT INCLUDE `src/vibe.asm` in test files.** vibe.asm has its own `ORG 0x0100` and `INCLUDE` chain — INCLUDEing it from a test produces double-ORG and duplicated includes. Test files INCLUDE individual `src/*.asm` modules á la carte (statusln, gapbuf), which is exactly the dependency graph the smoke tests already use.

**🛑 PRNG seed/constants must be documented in the test file** (AC16). A reproducible failure is a debuggable failure. If the dev's first PRNG choice produces a sequence that happens to never trigger an interesting case, a future story can change the seed — but it must be a deliberate change, not a silent drift.

**🛑 The deliberate `harness_fail` test is expected to fail.** Story 1.6 Task 3 introduced it as a perpetual smoke for the harness's fail-detection path. After Story 1.7, the harness reports `5 pass, 1 fail` (5 gapbuf + 1 harness_pass = 6 pass; 1 harness_fail = 1 fail). Total exit code is non-zero because of the deliberate fail — this is correct. Don't "fix" `harness_fail.asm`.

### Architecture compliance — what AR* / SR* / NFR* / TH* rules this story locks in

| Rule | Story 1.7 obligation |
|---|---|
| AR12 | Single status-message funnel: `gapbuf_insert`'s buffer-full path calls `status_set_message` only — no direct write to `status_buffer`. |
| AR14 | Single buffer-mutation owner: `gapbuf.asm` owns `gap_start`, `gap_end`, `cursor_offset` and is the only module with public `gapbuf_insert/delete/move_gap` entry points. Future stories' modules read the buffer (motions, render, search) but never mutate it directly. |
| AR15 | Single BDOS gateway: `gapbuf.asm` does not invoke `BDOS_CALL`, does not contain raw `CALL 0x0005`. AC11 grep enforces. |
| AR16 | Status-message string-table convention: `msg_not_implemented` lands in `src/statusln.asm`'s message block (AR16 location, lowercase, no period, under 30 chars). |
| AR22 | Naming: `gapbuf_init`, `gapbuf_insert`, `gapbuf_delete`, `gapbuf_move_gap`, `gapbuf_load` are `module_action` lowercase; internal labels use dotted-locals (`.full`, `.ok`, `.move_left`, etc.). |
| AR23 | Module header block + four-line `In:` / `Out:` / `Trashes:` / `Calls:` per public routine. AC1 enforces. |
| AR24 | UPPERCASE mnemonics + registers; 4-space indent; `;` line / `;;` section comments; no trailing periods. |
| AR25 | `INCLUDE "gapbuf.asm"` appears in `src/vibe.asm` after `INCLUDE "statusln.asm"` and before `INCLUDE "../inc/state.inc"`. |
| SR2 | Gap-buffer two-halves invariant: `gap_start` = first free byte; `gap_end` = first occupied byte after gap; `length = GAP_BUFFER_MAX - (gap_end - gap_start)`. AC2 / AC3 / AC4 / AC6 / AC7 / AC8 / AC15 / AC16 verify this is preserved across all four primitives. |
| SR3 | Cursor-to-buffer mapping: `cursor_offset` is logical; physical = `cursor < (gap_start - GAP_BUFFER_BASE) ? GAP_BUFFER_BASE + cursor : gap_end + (cursor - (gap_start - GAP_BUFFER_BASE))`. The `walk_xor_checksum` helper in test cases (Tasks 12, 13) is the canonical implementation of this mapping for read-side. |
| MC4 | Handler signature: register-passed parameters (A for byte to insert, HL for target offset). No state writes from this module beyond owned state. Caller-saved everywhere; callers preserve what they need across the call. |
| TH1 | Sentinel pair at 0xCFFE / 0xCFFF — used by tests via `JP test_pass` / `JP test_fail` (Story 1.6 epilogue). |
| TH2 | Test naming: `gapbuf_<scenario>.asm` (architecture line 1045-1047 shows the expected forms). |
| NFR9 | Code-size budget: gap buffer is one of the larger modules. Estimated 200-350 bytes for the four entry points. Track via `make sizes` (stub today; Story 1.11 wires the real version). Stay well within the ~3 KB envelope. |
| NFR10 | TPA fit: state.inc's `ASSERT yank_end <= 0xD800` covers the full code-plus-static-plus-gap-plus-yank envelope. Adding gapbuf's ~250 bytes leaves comfortable headroom (yank_end was around 0x90xx before this story). |
| NFR16 | Knob centralization: gap buffer references `GAP_BUFFER_BASE` and `GAP_BUFFER_MAX` from inc/equates.inc + inc/state.inc by symbol; no `LD HL, 0x8000` or similar magic numbers. |
| NFR18 | Reproducibility: `vibe.com` byte-identical across rebuilds (AC18); `test/cases/gapbuf_*.com` byte-identical across rebuilds (AC17). sjasmplus is deterministic on identical input — this is automatic provided no `--date` flag sneaks into the invocation. |

### Existing files — current state and what this story changes

**`src/gapbuf.asm`** *(does not exist):*
- Current: not present.
- This story: create per Tasks 1-6.

**`src/vibe.asm`** *(70 lines, ends with `INCLUDE "../inc/state.inc"`):*
- Current: includes equates/bios/bdos/vt52/modes pre-ORG, then `ORG 0x0100`, then `RET` stub, then `INCLUDE "statusln.asm"`, then `input_loop` stub, then `INCLUDE "../inc/state.inc"`.
- This story: insert `INCLUDE "gapbuf.asm"` between `INCLUDE "statusln.asm"` and `input_loop` (so gapbuf's emitted code lands after statusln's, before the input_loop stub). Update header block dependencies list to reflect the new module.

**`src/statusln.asm`** *(175 lines, message block at lines 167-174):*
- Current: defines `msg_buffer_modified`, `msg_file_too_large`, `msg_pattern_not_found`, `msg_search_wrapped`, `msg_undo_too_large`, `msg_nothing_to_undo`, `msg_no_write`, `msg_bdos_error`.
- This story: add `msg_not_implemented: DEFB "not yet implemented", 0`. Update header block's Public list. Body code unchanged.

**`test/cases/`** *(currently contains harness_pass.asm, harness_fail.asm + their .com files):*
- Current: two demo cases from Story 1.6.
- This story: add five new `.asm` files: `gapbuf_insert-empty.asm`, `gapbuf_insert-fills-buffer.asm`, `gapbuf_delete-at-bof.asm`, `gapbuf_move-roundtrip.asm`, `gapbuf_random-ops.asm`. Their `.com` files build under `make test` and are gitignored via `*.com`.

**`test/inc/`** *(currently contains test_prologue.inc, test_epilogue.inc):*
- Current: prologue + epilogue from Story 1.6.
- This story: **OPTIONAL** — if the dev factors a `walk_xor_checksum` / `prng_next` / `read_byte_before_cursor` helper used by multiple gapbuf tests, place it in `test/inc/test_gapbuf_helpers.inc` (or similar). Per-case INCLUDE instead of duplicating across files. **Optional** — if simpler to inline per case, do that.

**Files NOT touched by this story (do not edit):**
- `inc/equates.inc`, `inc/state.inc`, `inc/bios.inc`, `inc/bdos.inc`, `inc/modes.inc`, `inc/vt52.inc` — all cross-module headers stay as-is.
- `Makefile`, `test/Makefile` — build infrastructure unchanged.
- `test/cases/harness_pass.asm`, `test/cases/harness_fail.asm` — Story 1.6 demos remain in place.
- `test/inc/test_prologue.inc`, `test/inc/test_epilogue.inc` — Story 1.6 scaffold unchanged.
- `test/fixtures/hello.txt` — unchanged.
- `test/smoke/*.asm` — Story 1.4 / 1.5 smokes carve-out per Story 1.6 AC9; not relocated by this story.
- `README.md`, `test/README.md` — documentation already covers the harness; no story-1.7-specific updates required.

**Files created by this story:**
- `src/gapbuf.asm` (new — primary deliverable)
- `test/cases/gapbuf_insert-empty.asm`
- `test/cases/gapbuf_insert-fills-buffer.asm`
- `test/cases/gapbuf_delete-at-bof.asm`
- `test/cases/gapbuf_move-roundtrip.asm`
- `test/cases/gapbuf_random-ops.asm`
- *(optional)* `test/inc/test_gapbuf_helpers.inc` — shared test helpers if factored.

**Files modified by this story:**
- `src/vibe.asm` — add INCLUDE for gapbuf.asm; update header.
- `src/statusln.asm` — add `msg_not_implemented` to message block; update header Public list.

### Library / framework requirements

**sjasmplus 1.23.0:**
- Already pinned by the production `Makefile` via `check-toolchain` (Story 1.1). Test cases use the same flag set as Story 1.6's harness (`--nologo --msg=err --raw=$@ $<`). No story-1.7-specific toolchain change.
- **Macro / EQU resolution.** sjasmplus uses multi-pass assembly; forward references (e.g. `LD HL, msg_file_too_large` in gapbuf.asm referencing a label in statusln.asm) resolve on later passes. The INCLUDE order is what matters: `statusln.asm` (defines `msg_file_too_large`) before `gapbuf.asm` in vibe.asm. In test files, the order is symmetric.
- **`LDIR` / `LDDR`.** Standard Z80 instructions; sjasmplus assembles them as `0xED 0xB0` and `0xED 0xB8` respectively. No special syntax needed.

**iz-cpm:**
- Same harness as Story 1.6 — runs under `timeout --kill-after=1 5 iz-cpm -a fixtures -b fixtures <case>.com`. No new flags required.
- **Trace flags for debugging.** If a gapbuf test fails and the stdout fail-code isn't enough to localise: `iz-cpm -t cases/gapbuf_random-ops.com` traces every BDOS call (gapbuf doesn't call BDOS, so this is mostly silent — useful to confirm AR15 is held). `iz-cpm --cpu-trace cases/gapbuf_move-roundtrip.com` traces every Z80 instruction (verbose; useful for LDIR/LDDR setup verification).
- **Memory inspection post-run.** iz-cpm has no `--ram-dump` flag. The harness's pass-fail signal is stdout (per Story 1.6's TH1 reading). Tests that need to surface a value to the dev for debugging use `LD A, value; LD B, context; JP test_fail` — the FAIL line emits both bytes as hex.

**CP/M 2.2 BDOS function 9 / 0:**
- Used only by `test/inc/test_epilogue.inc` for PASS/FAIL emission and exit (per Story 1.6's AR15 carve-out). gapbuf.asm itself does NOT use BDOS.

### Test file structure pattern

Every `test/cases/gapbuf_*.asm` file follows this layout. Adopt it verbatim with cosmetic variation only — the contracts (include order, ORG placement, state.inc-last) are non-negotiable.

```asm
; ============================================================
; Module: test/cases/gapbuf_<scenario>.asm
; Purpose: <one-line scenario description>.
;
; AC reference: AC<N> (epic story 1.7 + this story file).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — <first assertion description>
;   0xE2 — <second assertion description>
;   ...
; ============================================================

; Pre-ORG: pure-EQU production headers (must come before
; test_prologue.inc's ORG so production constants resolve).
    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"

; ORG 0x0100, sentinel pre-zero, test_start label.
    INCLUDE "../inc/test_prologue.inc"

; ----- Test body -----
    ; <body — calls into gapbuf, checks state, JP test_pass / test_fail>

; ----- test_pass / test_fail labels + hex-print helpers -----
    INCLUDE "../inc/test_epilogue.inc"

; ----- Production code under test -----
; statusln.asm provides status_set_message + msg_file_too_large
; (referenced by gapbuf_insert's buffer-full path) and
; msg_not_implemented (referenced by gapbuf_load stub).
; gapbuf.asm is the module under test.
; INCLUDE order matches vibe.asm's AR25 dependency order.
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"

; ----- input_loop stub -----
; statusln.asm's bdos_error_funnel JPs to input_loop on a
; sign-bit BDOS rc. Gap buffer never triggers that path
; (no BDOS calls — AR15), but the symbol must resolve at link
; time. Local stub mirrors the smoke-test pattern from Story 1.5.
input_loop:
    LD      C, BDOS_EXIT
    CALL    BDOS_ENTRY
    RET

; ----- state.inc LAST -----
; Positional EQU anchor: static_data_base = $ at INCLUDE site,
; so it lands first address past all emitted code. Moving this
; INCLUDE earlier silently corrupts the static memory map.
    INCLUDE "../../inc/state.inc"
```

The smoke test `test/smoke/statusln_smoke.asm` (lines 39-225) is the prior-art reference for this pattern. The notable differences for harness-driven tests (vs. smokes):
- **Use the prologue + epilogue** (Story 1.6 scaffold) instead of writing a manual `ORG 0x0100` + `BDOS_EXIT` epilogue.
- **`JP test_fail` with A = fail-code, B = context**, instead of writing a per-fail `LD (0xCFFE), A; JR exit`. The epilogue handles the stdout emission and BDOS exit.

### Previous story intelligence (Stories 1.1–1.6)

**From Story 1.1:**
- `make` from project root produces `vibe.com` deterministically. `make clean` removes it. NFR18 baseline established. Story 1.7 inherits the toolchain pin and the byte-identical-rebuild property — adding gapbuf.asm changes the SHA but the new SHA is stable across rebuilds.

**From Story 1.2:**
- `inc/equates.inc` defines `GAP_BUFFER_MAX EQU 32768` (= 0x8000, high bit set as a 16-bit value). The comment block at equates.inc lines 37-39 explicitly warns: "Bounds compares against cursor offsets MUST be unsigned (SBC HL,DE + carry, or BIT 7,H — never JP M / JP P, which treat it as negative)." Story 1.7's `gapbuf_insert` and `gapbuf_move_gap` are the first production consumers of this rule; the unsigned-compare convention applies to every bounds check in the new code.

**From Story 1.3:**
- `inc/state.inc` declares `gap_start`, `gap_end`, `cursor_offset` as positional EQUs at fixed addresses past the static block. `GAP_BUFFER_BASE EQU static_end` is also defined here (not in equates.inc — its value is positional, not a knob; equates.inc lines 56-64 explicitly explain why). The ASSERT at state.inc line 121 (`yank_end <= 0xD800`) is the NFR10 TPA-fit guardrail — Story 1.7's gapbuf module's added bytes plus existing static block + 32K gap + 1K yank must fit.
- **gap-buffer-base is the first address past static data, computed at assembly time.** No runtime computation of GAP_BUFFER_BASE; the symbol is a constant the linker resolves.

**From Story 1.4:**
- `BDOS_CALL` macro is the project-wide BDOS gateway (AR15). Gap buffer doesn't use it — pure-memory module. The bdos.inc include guard (`IFNDEF BIOS_INC_LOADED`) means tests can INCLUDE bdos.inc without double-including bios.inc.
- The smoke test pattern at `test/smoke/bdos_call_smoke.asm` is one prior-art reference for "test exercises a production module standalone": INCLUDE production headers, define ORG, exercise the entry point, write a sentinel byte on the success/fail paths, exit via BDOS. Story 1.7's tests evolve this by routing pass/fail via the Story 1.6 harness instead of standalone sentinels.

**From Story 1.5:**
- `src/statusln.asm` defines `status_set_message` (the MC5 funnel), `bdos_error_funnel` (BDOS abort path), `status_render` (Story 1.5 stub; Story 1.11 lands real body). The message block at lines 167-174 holds eight strings; Story 1.7 adds `msg_not_implemented` here to keep AR16 enforced (all message strings co-located).
- **`status_set_message` argument convention.** `In: HL = ptr, A = code` (statusln.asm lines 53-58). The `A = code` argument is reserved/ignored today; pass `XOR A` for non-error use. This is the calling convention `gapbuf_insert`'s buffer-full path uses.
- **`status_set_message` does NOT call BDOS.** It's pure memory writes (status_buffer + status_dirty). Calling it from gapbuf does not violate AR15.
- **`bdos_error_funnel` JPs to `input_loop`** (statusln.asm line 126). Tests that INCLUDE statusln.asm need a local input_loop stub. The statusln_smoke test (test/smoke/statusln_smoke.asm lines 185-221) is the canonical prior-art for this stub pattern.

**From Story 1.6:**
- `make test` from project root runs the harness; per-case `pass`/`fail`/`unknown`/`timeout` reporting; non-zero exit on any non-pass. `harness_fail.asm` is a deliberate fail; `harness_pass.asm` is a trivial pass. Story 1.7's gapbuf tests are the first production-path validation through the harness.
- **`test/inc/test_prologue.inc`** declares TEST_RESULT/TEST_CONTEXT, places ORG 0x0100, defines `test_start:` with the sentinel pre-zero. INCLUDE this in every gapbuf test case.
- **`test/inc/test_epilogue.inc`** provides `test_pass:` and `test_fail:` labels. `test_fail` takes A = fail-code, B = context (epilogue lines 55-75). The hex-print helpers emit `FAIL <fc> <ctx>$` to stdout.
- **`test/Makefile`** uses `grep -qE '\bPASS\b'` / `'\bFAIL\b'` for word-bounded match. Tests must NOT emit "PASS" or "FAIL" from any path other than the epilogue (the Story 1.6 README warning).
- **iz-cpm flags.** `-a fixtures -b fixtures` mounts `test/fixtures/` as both A: and B:. Gap buffer tests don't touch the filesystem (pure memory), so the mount is unused — but harmless.

### Git intelligence

Six commits on `main` after Story 1.0:

- `b561c9e` — Story 1.1: Makefile pins sjasmplus 1.23.0, produces vibe.com.
- `eac5ba3` — Story 1.2: Named every constant the editor needs, in three .inc headers, wired in.
- `a298547` — Story 1.3: Laid out the editor's full memory map at fixed addresses, build-time guarded.
- `b7ca9a8` — Story 1.4: every BDOS call now goes through a macro that catches errors.
- *(commit message reflects 1.5)* — Story 1.5: every status message now goes through one funnel.
- `42af237` — Story 1.6: make test builds, runs, and grades every test case off stdout.

Conventions visible in the tree (preserve in Story 1.7):
- 4-space indentation, UPPERCASE mnemonics, `;` line / `;;` section comments (AR24).
- AR23 header blocks on every `.asm` and `.inc` file. The new `src/gapbuf.asm` follows the same shape.
- Every public routine has the `In:` / `Out:` / `Trashes:` / `Calls:` four-line contract (AR23).
- One story per commit; short imperative subject + colon-separated context. Match the user's plain-English style.

Suggested commit message for Story 1.7 (when the dev finishes): `story 1.7: gap-buffer primitives land, with five headless tests proving the two-halves invariant.`

### Testing requirements

Story 1.7's testing requirements are AC12–AC16 (five gapbuf tests pass under `make test`) plus AC17 / AC18 (NFR18 reproducibility). Specifically:

1. `make test` from project root reports `pass     gapbuf_insert-empty`, `pass     gapbuf_insert-fills-buffer`, `pass     gapbuf_delete-at-bof`, `pass     gapbuf_move-roundtrip`, `pass     gapbuf_random-ops`. Plus the existing `pass     harness_pass` and `fail     harness_fail` from Story 1.6.
2. Total `make test` exit code is non-zero (because of the deliberate `harness_fail` carry-over from Story 1.6 — this is correct).
3. Two consecutive `make -C test clean && make test` runs produce byte-identical `test/cases/gapbuf_*.com` SHAs.
4. Two consecutive `make clean && make` runs produce byte-identical `vibe.com` SHA (with gapbuf.asm now in the build).
5. The new `vibe.com` (post-Story-1.7) is a different SHA from the pre-Story-1.7 `vibe.com` — deliberate, because the new module adds bytes.

Once Story 1.8 lands (input layer with Esc/arrow disambiguation), the input layer is the second production-path validation through the harness — but Esc timing is UAT-only (AR21 carve-out for "Esc/arrow timing"), so its tests are simpler than the gap-buffer suite.

### Project Structure Notes

After Story 1.7 the source tree is:

```
src/
├── vibe.asm        # Top-level (now INCLUDEs gapbuf.asm + statusln.asm)
├── statusln.asm    # Story 1.5 — adds msg_not_implemented in this story
└── gapbuf.asm      # Story 1.7 — new

test/
├── README.md
├── Makefile
├── inc/
│   ├── test_prologue.inc
│   ├── test_epilogue.inc
│   └── (optional) test_gapbuf_helpers.inc   # if factored
├── cases/
│   ├── harness_pass.asm
│   ├── harness_fail.asm
│   ├── gapbuf_insert-empty.asm              # NEW
│   ├── gapbuf_insert-fills-buffer.asm       # NEW
│   ├── gapbuf_delete-at-bof.asm             # NEW
│   ├── gapbuf_move-roundtrip.asm            # NEW
│   └── gapbuf_random-ops.asm                # NEW
├── fixtures/
│   └── hello.txt
└── smoke/
    ├── bdos_call_smoke.asm
    └── statusln_smoke.asm
```

Architecture's reference layout (lines 1317-1331) anticipates exactly this. Stories 1.8 onwards continue the pattern: each new module under `src/` lands alongside one or more `test/cases/<module>_*.asm` cases. Story 1.7 is the first multi-test-case story; the harness-per-case scaling cost is one additional `.asm` file plus a build step — effectively zero.

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md] lines 501-554
- Risk-rank-2 (gap-buffer correctness ships with tests): [Source: _bmad-output/planning-artifacts/architecture.md] lines 65-66, 748-750, 1568-1569
- SR2 (gap-buffer two-halves invariant): [Source: _bmad-output/planning-artifacts/architecture.md] lines 433-439
- SR3 (cursor-to-buffer mapping): [Source: _bmad-output/planning-artifacts/architecture.md] lines 441-445
- AR14 (single buffer-mutation owner): [Source: _bmad-output/planning-artifacts/epics.md] line 163
- AR15 (single BDOS gateway — gapbuf is pure-memory, no BDOS): [Source: _bmad-output/planning-artifacts/epics.md] line 164, [Source: _bmad-output/planning-artifacts/architecture.md] lines 543-548
- AR23 (file structure and routine contracts): [Source: _bmad-output/planning-artifacts/epics.md] line 178
- AR25 (module include order — statusln → gapbuf): [Source: _bmad-output/planning-artifacts/epics.md] line 180, [Source: _bmad-output/planning-artifacts/architecture.md] lines 939-940
- gapbuf.asm reference module header: [Source: _bmad-output/planning-artifacts/architecture.md] lines 858-880
- gapbuf_insert reference contract: [Source: _bmad-output/planning-artifacts/architecture.md] lines 891-901
- Module dependency graph (gapbuf is the single mutation owner): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1401-1448
- Static memory map (gap_start, gap_end, cursor_offset locations): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1341-1399
- inc/state.inc current state: [Source: inc/state.inc] (lines 60-101)
- inc/equates.inc (GAP_BUFFER_MAX = 32768; bounds-compare unsigned warning): [Source: inc/equates.inc] lines 31, 37-39
- src/vibe.asm current INCLUDE order: [Source: src/vibe.asm] lines 28-69
- src/statusln.asm message block: [Source: src/statusln.asm] lines 167-174
- src/statusln.asm status_set_message contract: [Source: src/statusln.asm] lines 47-58
- Test harness (Story 1.6): [Source: _bmad-output/implementation-artifacts/1-6-headless-test-harness-scaffold.md]
- Test prologue / epilogue (Story 1.6): [Source: test/inc/test_prologue.inc, test/inc/test_epilogue.inc]
- Smoke test pattern (statusln_smoke.asm — INCLUDE production source + local input_loop stub): [Source: test/smoke/statusln_smoke.asm] lines 39-225
- Smoke test pattern (bdos_call_smoke.asm — sentinel byte for diagnosis): [Source: test/smoke/bdos_call_smoke.asm] lines 16-66
- Test file naming convention (TH2): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1041-1054
- Test conventions overview (TH1, TH2, TH3): [Source: _bmad-output/planning-artifacts/architecture.md] lines 708-728
- iz-cpm flag reference: [Source: test/README.md] lines 69-78
- Implementation sequence (gap buffer is step 5 — depends on statusln, blocks input/dispatch): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1557-1577 + 740-760
- LDIR / LDDR Z80 reference: standard Zilog instruction set; encoded as `0xED 0xB0` (LDIR) and `0xED 0xB8` (LDDR)
- Story 2.2 (consumer of gapbuf_load — full FCB-based body): [Source: _bmad-output/planning-artifacts/epics.md] lines 902-951

## Dev Agent Record

### Agent Model Used

claude-opus-4-7 (1M context) — Claude Code dev-story workflow.

### Debug Log References

NFR18 reproducibility — two consecutive `make clean && make` runs:

```
vibe.com  d80e950c9e28a02e1df921622b2ed257da9f848263515dbe50b6b8a7ca97f62c   (run 1)
vibe.com  d80e950c9e28a02e1df921622b2ed257da9f848263515dbe50b6b8a7ca97f62c   (run 2)
```

NFR18 reproducibility — two consecutive `make -C test clean && make -C test test` runs:

```
test/cases/gapbuf_delete-at-bof.com         a857464053e1e174247a47c7baa3dadb046c460f3509ad4364b71ddf87b72198
test/cases/gapbuf_insert-empty.com          cdf822da1f7158936d26789ccc29e1dc65fb0cac9cb113a10b13f5b5885c0dbe
test/cases/gapbuf_insert-fills-buffer.com   7d2852411b9cbaac279c2efe59999792f09a85efe13d761c0644fd11d5f84c3e
test/cases/gapbuf_move-roundtrip.com        513a14aa07bac3746cc1aed373f89257d6331fa168c123bd7025cc531efa3f35
test/cases/gapbuf_random-ops.com            bad2953538926bc8170eb77e92d021e6a71f11a266c54886a41f84a98faf34fc
```

Per-file SHAs identical across both runs (AC17, AC18 satisfied).

AC11 grep — `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY|BDOS_CALL' src/gapbuf.asm` returns no matches (exit 1). The four `CALL` sites in `gapbuf.asm` resolve to `gapbuf_move_gap` (intra-module, two sites) and `status_set_message` (the funnel for the buffer-full path and `gapbuf_load` stub).

`make test` final report (Story 1.6's deliberate `harness_fail` is the only fail — by design):

```
  pass     gapbuf_delete-at-bof
  pass     gapbuf_insert-empty
  pass     gapbuf_insert-fills-buffer
  pass     gapbuf_move-roundtrip
  pass     gapbuf_random-ops
  fail     harness_fail  (rc=0, output: FAIL E1 C0)
  pass     harness_pass

  6 pass, 1 fail
```

### Completion Notes List

- `src/gapbuf.asm` lands the four primitives (`gapbuf_init`, `gapbuf_insert`, `gapbuf_delete`, `gapbuf_move_gap`) and the `gapbuf_load` stub. Module is pure-memory: no BDOS, no BIOS_CONOUT (AR15 / AC11). Status surface for the buffer-full path and the load stub goes through `status_set_message` only (AR12).
- `gapbuf_insert` performs the gap-at-cursor relocation, then the buffer-full check, then the byte write. The full-check happens BEFORE any state mutation so AC4's "state unchanged on full" holds. `gapbuf_delete` checks BOF FIRST (AC5 state-unchanged carve-out), then optionally relocates the gap before decrementing.
- `gapbuf_move_gap` uses LDIR for right-shift and LDDR for left-shift. The "boring" version (explicit byte-count + post-LDIR pointer fixups) was chosen over clever optimisation per the story's NFR9-budget guidance. cursor_offset is never touched (AC7).
- `msg_not_implemented` lives in `src/statusln.asm`'s message block (AR16); the AR16 Public list in the statusln header was extended to enumerate the message strings.
- `src/vibe.asm` now INCLUDEs `gapbuf.asm` between `statusln.asm` and the `input_loop` stub (AR25 ordering: `statusln` → `gapbuf`, with `state.inc` strictly last). The Story 1.5 RET stub at 0x0100 stays in place — production callers of `gapbuf_init` arrive in Story 1.12.
- Five test cases under `test/cases/gapbuf_*.asm` cover: AC2/AC3 init+insert invariants (`gapbuf_insert-empty`); AC4 buffer-full via direct-poke (`gapbuf_insert-fills-buffer`); AC5 BOF refuse (`gapbuf_delete-at-bof`); AC7/AC8 move-roundtrip via XOR-fold checksum (`gapbuf_move-roundtrip`); AC2-AC8 fuzz via 100-iter deterministic LFSR with running checksum (`gapbuf_random-ops`). All five pass under `make test`.
- PRNG choice for `gapbuf_random-ops`: 16-bit Galois LFSR, polynomial 0xB400, seed 0xACE1. Period 65535. Documented in the test header so any failure is reproducible.

### File List

Created:
- `src/gapbuf.asm`
- `test/cases/gapbuf_insert-empty.asm`
- `test/cases/gapbuf_insert-fills-buffer.asm`
- `test/cases/gapbuf_delete-at-bof.asm`
- `test/cases/gapbuf_move-roundtrip.asm`
- `test/cases/gapbuf_random-ops.asm`
- `test/cases/gapbuf_delete-mid.asm` — *added during 2026-05-10 code review (AC6 deterministic coverage)*
- `test/inc/test_input_loop_stub.inc` — *added during 2026-05-10 code review (hoisted from 5 inline copies)*

Modified:
- `src/vibe.asm` — INCLUDE `gapbuf.asm` between `statusln.asm` and `input_loop`; header dependencies extended.
- `src/statusln.asm` — added `msg_not_implemented` to the AR16 message block; header Public list now enumerates the message strings.
- `test/cases/gapbuf_*.asm` (all six) — replaced inline `input_loop` stub with `INCLUDE "../inc/test_input_loop_stub.inc"` (2026-05-10 code review).
- `test/cases/gapbuf_random-ops.asm` — fail-code encoding switched from `A=0xE0+iter / B=op` to `A=0xC0+op / B=iter` (no overflow wrap); `modn1_hl` worst-case comment corrected (2026-05-10 code review).
- `test/cases/gapbuf_delete-at-bof.asm` — added 0xE5 fail-code asserting `status_dirty == 0` post-call (mechanically enforces AC5; 2026-05-10 code review).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — story status `ready-for-dev` → `in-progress` → `review` → `done`.

### Change Log

| Date | Author | Change |
|------|--------|--------|
| 2026-05-09 | Amelia (dev) | Story 1.7 implemented. `src/gapbuf.asm` lands the four primitives + `gapbuf_load` stub; `src/statusln.asm` gains `msg_not_implemented`; `src/vibe.asm` INCLUDEs gapbuf per AR25. Five test cases (`gapbuf_insert-empty`, `gapbuf_insert-fills-buffer`, `gapbuf_delete-at-bof`, `gapbuf_move-roundtrip`, `gapbuf_random-ops`) all pass under `make test`. NFR18 reproducibility verified: vibe.com SHA stable across rebuilds; per-case .com SHAs stable. AR15 grep clean (AC11). All 18 ACs satisfied; status moved to "review". |
| 2026-05-09 | Story author | Initial story context — creates `src/gapbuf.asm` with `gapbuf_init`, `gapbuf_insert`, `gapbuf_delete`, `gapbuf_move_gap`, and a stub `gapbuf_load`. Establishes the gap-buffer two-halves invariant (SR2), cursor-to-buffer mapping (SR3), gap-tracks-cursor post-mutation invariant (architecture line 102), and AR14 single-buffer-mutation-owner property. Wires the new module into `src/vibe.asm` per AR25. Adds `msg_not_implemented` to `src/statusln.asm`'s message block (AR16 location). Lands five headless test cases under `test/cases/gapbuf_*.asm`: `gapbuf_insert-empty.asm` (init invariants + first insert advances state), `gapbuf_insert-fills-buffer.asm` (buffer-full path: CF=1, state unchanged, msg_file_too_large), `gapbuf_delete-at-bof.asm` (BOF path: CF=1, state unchanged), `gapbuf_move-roundtrip.asm` (move_gap roundtrip preserves file content), `gapbuf_random-ops.asm` (100-iteration deterministic-PRNG random insert/delete/move with checksum-fold invariant check). Closes PRD risk-rank-2 (gap-buffer correctness), unblocks every later story that depends on the buffer (motions, edits, visual, search, fileio, undo). Reproducibility verified per NFR18 (vibe.com + per-case .com SHAs stable across rebuilds). |
