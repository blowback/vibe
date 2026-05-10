# Story 1.8: Input layer with Esc/arrow disambiguation

Status: done

<!-- Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As the VIBE author,
I want `src/input.asm` exposing `input_get_key` that polls `BIOS_CONIN`, performs the 1–2 tick Esc/arrow disambiguation per RI5, synthesizes single-byte keycodes for arrow keys, and queues the unrecognized follow-up byte so it is not dropped,
so that PRD risk-rank-1 (input/Esc timing) is closed and the dispatch layer's binary-search contract holds (single-byte key in A, no register-passed composites).

## Acceptance Criteria

1. **AC1 — `src/input.asm` exists with the project-standard module header.**
   Given `src/input.asm`,
   When I inspect it,
   Then it carries an AR23-conformant header block listing `Public: input_get_key`, `State owned: input_held_byte, input_held_flag` (two new fields added to `inc/state.inc` by this story — see AC10), register conventions, and `Dependencies: inc/equates.inc (ESC_TIMEOUT_TICKS), inc/bios.inc (BIOS_CONIN, BIOS_CONINST, BIOS_TICK_ADDR), inc/vt52.inc (VT52_ESC), inc/modes.inc (KEY_ARROW_*), inc/state.inc (input_held_byte, input_held_flag)`,
   And `input_get_key` carries the four-line `In:` / `Out:` / `Trashes:` / `Calls:` contract per AR23,
   And every internal helper (e.g. `tick_wait_one`, `synthesize_arrow_key`) carries the same four-line contract.

2. **AC2 — `input_get_key` returns a single-byte ASCII key for a printable keypress.**
   Given `input_get_key` (`In: (none)`, `Out: A = single-byte keycode (ASCII or KEY_ARROW_*)`),
   When the BIOS supplies a printable byte (e.g. `'a'` = 0x61),
   Then `A = 0x61` is returned within one input-loop iteration with no Esc-disambiguation delay.

3. **AC3 — Control bytes pass through unchanged.**
   Given the BIOS supplies a control byte (e.g. Ctrl-L = 0x0C),
   When `input_get_key` is invoked,
   Then `A = 0x0C` is returned (control bytes pass through; with BDOS bypassed for the read path, all controls arrive raw per the platform constraints documented in `inc/bios.inc`).

4. **AC4 — Bare Esc returns 0x1B after the timeout window.**
   Given the BIOS supplies `0x1B` (Esc) with no follow-up byte ready within `ESC_TIMEOUT_TICKS` 50 Hz ticks (default `2`, ~40 ms),
   When `input_get_key` is invoked,
   Then `A = 0x1B` is returned (`VT52_ESC` symbol from `inc/vt52.inc`),
   And no follow-up byte is consumed from the BIOS ring,
   And `(input_held_flag) == 0` on return (no byte queued).

5. **AC5 — Esc + arrow-suffix returns the synthesized arrow keycode.**
   Given the BIOS supplies `0x1B` followed by a byte ready before the timeout expires,
   When the follow-up byte is one of `'A'` / `'B'` / `'C'` / `'D'`,
   Then `input_get_key` returns:
     - ESC `'A'` → `A = KEY_ARROW_UP`    (0x80)
     - ESC `'B'` → `A = KEY_ARROW_DOWN`  (0x81)
     - ESC `'C'` → `A = KEY_ARROW_RIGHT` (0x83)
     - ESC `'D'` → `A = KEY_ARROW_LEFT`  (0x82)
   And `(input_held_flag) == 0` on return,
   And the follow-up byte is consumed (not re-emitted on the next call).

6. **AC6 — Esc + unrecognized byte returns bare Esc and queues the follow-up.**
   Given the BIOS supplies `0x1B` followed by a byte ready before the timeout expires that is NOT one of `'A'..'D'`,
   When `input_get_key` is invoked,
   Then `A = 0x1B` is returned (bare Esc — the editor sees the cancel),
   And `(input_held_byte)` holds the unrecognized follow-up byte,
   And `(input_held_flag) != 0`,
   And the next call to `input_get_key` returns the queued byte directly (`A = held_byte`) without polling BIOS_CONIN,
   And on that next call `(input_held_flag) == 0` is reset before returning.

7. **AC7 — The tick-poll loop uses CONINST + tick-counted wait, bounded by NFR4.**
   Given the bare-Esc tick-poll loop,
   When I inspect it,
   Then `BIOS_CONINST` (non-blocking query) is the only BIOS call inside the wait loop (no spin on `BIOS_CONIN`),
   And the wait blocks per-iteration on the 50 Hz tick variable `(BIOS_TICK_ADDR)` advancing by exactly one tick (`tick_wait_one` helper or inline equivalent),
   And `B` (or equivalent counter) is initialised from `ESC_TIMEOUT_TICKS` and the loop terminates after that many tick-blocks,
   And worst-case bare-Esc latency is bounded by `ESC_TIMEOUT_TICKS × 20 ms` ≈ 40 ms (NFR4).

8. **AC8 — The 16-bit tick-counter read is non-tearing per `inc/bios.inc`'s reader contract.**
   Given the `tick_wait_one` (or equivalent) helper,
   When I inspect every `LD HL, (BIOS_TICK_ADDR)` site in `src/input.asm`,
   Then each is bracketed by `DI` ... `EI` (per the reader contract documented at `inc/bios.inc` lines 51-65; the ISR is the only writer, so `DI`/`EI` is the cheap mitigation),
   And the relative-tick comparison is unsigned-wrap-safe (uses `SBC HL, DE` after `OR A` to clear CF, branches on the carry flag — never `JP M` / `JP P` against the unsigned delta),
   And the loop exits when the tick value differs from the entry-time snapshot (NOT when an absolute target is reached — this avoids a 21.8-minute hang on the 0xFFFF→0x0000 wrap).

9. **AC9 — AR15 holds: no raw BDOS calls in `src/input.asm`.**
   Given `src/input.asm`,
   When I run `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY|BDOS_CALL' src/input.asm`,
   Then there are zero matches — the input layer is BIOS-only (CONIN/CONINST + tick counter), does not touch BDOS, and does not invoke the BDOS_CALL macro.

10. **AC10 — `inc/state.inc` gains `input_held_byte` and `input_held_flag` in the small-state section.**
    Given `inc/state.inc`,
    When I inspect it post-story,
    Then two single-byte fields are appended to the small-state block immediately after `pending_motion_prefix` (preserving ascending positional layout):
      - `input_held_byte`  EQU `static_data_base + static_off`; `static_off = static_off + 1`
      - `input_held_flag`  EQU `static_data_base + static_off`; `static_off = static_off + 1`
    And the module header `Public:` block is updated to enumerate both new symbols,
    And the `ASSERT yank_end <= 0xD800` guard at the bottom still passes (2 bytes added, comfortable headroom remains — the gate stays green).

11. **AC11 — `src/input.asm` is integrated into `src/vibe.asm` per AR25.**
    Given `src/vibe.asm`,
    When I inspect its INCLUDE order,
    Then `INCLUDE "input.asm"` appears AFTER the `RET` stub at `ORG 0x0100` and BEFORE `INCLUDE "statusln.asm"` — matching AR25's order (`ORG 0x0100 → init → input → statusln → gapbuf`; init lands in Story 1.12, so input is the first module-include after the RET stub),
    And `make` from a clean tree builds `vibe.com` without errors,
    And the `vibe.asm` header block is updated to enumerate `src/input.asm (Story 1.8)` in the `Dependencies:` list,
    And the `;; --- Input-loop abort target ---` comment block above `input_loop:` is updated to point to Story 1.12 as the owner that lands the real input-loop body (the Story 1.5 stub had predicted Story 1.8, but Story 1.8 lands `input_get_key` only; the real `input_loop` body needs `dispatch_key` + `render_diff` which arrive in Stories 1.9 / 1.11; the unified main-loop wiring is Story 1.12).

12. **AC12 — `vibe.com` rebuilds byte-deterministically (NFR18).**
    Given the post-Story-1.8 `vibe.com` (now containing the input module + the two new state.inc fields),
    When I run `make clean && make` twice,
    Then both `vibe.com` outputs hash identically (NFR18; input.asm + state.inc fields add bytes / shift the static block, but the bytes are deterministic),
    And the new `vibe.com` SHA differs from the pre-Story-1.8 `vibe.com` SHA (deliberate — new module + 2 state bytes shift the layout).

13. **AC13 — Existing `gapbuf_*` headless tests still pass under `make test`.**
    Given the pre-Story-1.8 `make test` baseline (7 pass / 1 fail — Story 1.7's review added `gapbuf_delete-mid`, so the actual current baseline is one above Story 1.7's debug-log count; the deliberate `harness_fail` is still the only fail),
    When `make test` runs after Story 1.8 lands,
    Then the same 7-pass / 1-fail count holds,
    And every `gapbuf_*.asm` test case still passes (state.inc layout shifted but tests use `gap_start` / `gap_end` / `cursor_offset` symbols, not raw addresses — invariant-by-construction).

14. **AC14 — UAT for Esc/arrow timing is deferred to Story 1.12 with the smoke harness optional in this story.**
    Given AR21's carve-out (Esc/arrow timing is UAT-only — iz-cpm cannot meaningfully validate the 50 Hz tick window) and the W1 placeholder for `BIOS_CONIN` / `BIOS_TICK_ADDR` at `0xFA0X` (which iz-cpm does not emulate),
    When I review the test plan for this story,
    Then `test/cases/input_*.asm` files are intentionally NOT created (no headless tests for input timing — UAT is the gate),
    And the production UAT loop for Story 1.8 is deferred to Story 1.12 (init / teardown / on-hardware smoke), where `init.asm` + the real `input_loop` body + `dispatch_key` + `render_diff` first compose end-to-end on real MicroBeast hardware,
    And — *optional, dev's choice* — a one-off smoke under `test/smoke/input_smoke.asm` may be added to push to MicroBeast for a manual key-print loop (recommended pattern in Dev Notes); the smoke is not required by this story but is the cheapest way to validate AC2-AC8 before Story 1.12 lands.

## Tasks / Subtasks

- [x] **Task 1 — Extend `inc/state.inc` with `input_held_byte` and `input_held_flag`** (AC: 10, supports AC1 / AC6)
  - [x] Edit `inc/state.inc`: in the `;; --- Single-byte / small state ---` block, append two new fields immediately after `pending_motion_prefix` (preserving the ascending positional layout — every field below shifts by 2 bytes, but uses the symbolic offset, not a raw address):
    ```asm
    pending_motion_prefix EQU static_data_base + static_off
    static_off            =   static_off + 1
    input_held_byte       EQU static_data_base + static_off
    static_off            =   static_off + 1
    input_held_flag       EQU static_data_base + static_off
    static_off            =   static_off + 1
    ```
  - [x] Update the `; Public:` block in the header to enumerate `input_held_byte` and `input_held_flag` under "Small state".
  - [x] **DO NOT touch the `ASSERT yank_end <= 0xD800` line.** Adding 2 bytes shifts every subsequent field by 2 — `gap_end`, `yank_end`, etc. all advance by 2. The assert still passes by a wide margin (~0x4Bxx headroom pre-shift; 2 bytes are noise). If the build breaks at the ASSERT, you've added the fields in the wrong place — they MUST land BEFORE the `ASSERT` (which lives below the yank-buffer section).
  - [x] **DO NOT add the fields elsewhere in `state.inc`.** Putting them in the 16-bit-state block, the buffers block, or after the gap-buffer section all violate the "small-state" semantics (`input_held_byte` is a single byte; `input_held_flag` is a single byte) and break AR23's section-ordering convention. The two-line append immediately after `pending_motion_prefix` is the canonical placement.
  - [x] **`input_held_byte` / `input_held_flag` are owned by `src/input.asm`.** No other module reads or writes them. AR12-style "single owner" applies. State.inc is the declaration site (MC7); ownership lives in the module.

- [x] **Task 2 — Create `src/input.asm` with the AR23 module header block** (AC: 1, 9)
  - [x] Header block (adopt the architecture-line-1285-style format used by `src/gapbuf.asm` and `src/statusln.asm`):
    ```asm
    ; ============================================================
    ; Module: input.asm
    ; Purpose: Single keystroke acquisition (RI5). Polls BIOS_CONIN
    ;          for the next byte; on Esc, opens an ESC_TIMEOUT_TICKS
    ;          tick window (CONINST + tick counter) for an arrow-
    ;          key follow-up. Synthesises single-byte keycodes
    ;          (KEY_ARROW_UP/DOWN/LEFT/RIGHT) so the MC4 dispatch
    ;          contract holds (1-byte key in A, no register-passed
    ;          composites). PRD risk-rank-1 lives here.
    ;
    ;          Pure-BIOS module — no BDOS, no BDOS_CALL macro
    ;          (AR15: grep CALL 0x0005 / BDOS_CALL returns zero
    ;          hits). Esc/arrow timing is UAT-validated on real
    ;          MicroBeast hardware (AR21 carve-out — iz-cpm cannot
    ;          meaningfully validate the 50 Hz tick window).
    ;
    ; Public:
    ;   input_get_key  - read next keystroke (RI5: Esc disambig +
    ;                    arrow synthesis + 1-byte putback queue)
    ;
    ; State owned (read/write):
    ;   input_held_byte  - 1-byte putback slot (Esc + unrecognized
    ;                       follow-up: stash the follow-up here so
    ;                       the next call returns it directly,
    ;                       avoiding a dropped key for the common
    ;                       insert-Esc-then-motion vi pattern)
    ;   input_held_flag  - nonzero iff input_held_byte is valid
    ;
    ; Register conventions (across public entry points):
    ;   A  = output keycode (ASCII or KEY_ARROW_*); also working
    ;   B  = tick countdown for ESC_TIMEOUT_TICKS poll
    ;   HL = working / tick-counter snapshot
    ;   DE = working / tick-counter compare
    ;   F  = trashed
    ;
    ; Dependencies:
    ;   inc/equates.inc  (ESC_TIMEOUT_TICKS)
    ;   inc/bios.inc     (BIOS_CONIN, BIOS_CONINST, BIOS_TICK_ADDR)
    ;   inc/vt52.inc     (VT52_ESC = 0x1B — first-byte compare)
    ;   inc/modes.inc    (KEY_ARROW_UP / DOWN / LEFT / RIGHT)
    ;   inc/state.inc    (input_held_byte, input_held_flag —
    ;                     this story added both fields)
    ; ============================================================
    ```
  - [x] Section dividers via `;;` per AR24:
    - `;; ============================================================`
    - `;; --- Public entry points ---`
    - `;; ============================================================`
    - `;; --- Internal helpers ---`
  - [x] **NO `BDOS_CALL` invocations.** AC9 enforces this. Input layer is pure-BIOS.
  - [x] **NO direct writes to `status_buffer` / `status_dirty`.** Input is purely a key-acquisition path; no error/info messages emitted from this module (Esc-timeout is not an error condition; bare Esc is a valid key). AR12 (single status funnel) is upheld by simply not touching the status surface at all.

- [x] **Task 3 — Implement `input_get_key`'s held-byte fast path** (AC: 6 — the queue branch)
  - [x] Four-line contract per AR23 immediately above the routine label:
    ```asm
    ; ----------------------------------------------------------------
    ; input_get_key
    ; Read the next keystroke from the BIOS, performing Esc/arrow
    ; disambiguation per RI5 and synthesising single-byte arrow
    ; keycodes. If a previous call queued a follow-up byte (Esc +
    ; unrecognised pattern, AC6), return that queued byte first
    ; without polling BIOS_CONIN.
    ;
    ; In:      (none)
    ; Out:     A = single-byte keycode (ASCII 0x00-0x7F or
    ;          KEY_ARROW_* 0x80-0x83). VT52_ESC (0x1B) on bare-Esc.
    ; Trashes: A, B, DE, HL, F
    ; Calls:   tick_wait_one, synthesize_arrow_key (internal)
    ; ----------------------------------------------------------------
    ```
  - [x] First instructions check the queue:
    ```asm
    input_get_key:
        LD      A, (input_held_flag)
        OR      A
        JR      Z, .no_held
        ;; --- queue path: pop and return ---
        XOR     A
        LD      (input_held_flag), A          ; clear flag first
        LD      A, (input_held_byte)
        RET                                    ; queued byte returned
    .no_held:
        ;; ... fall through into the BIOS_CONIN read path ...
    ```
  - [x] **Clear the flag BEFORE loading the byte.** `XOR A; LD (input_held_flag), A` first, then `LD A, (input_held_byte)`. If the order is flipped (byte then flag), the flag clear can clobber A on the way out (the `LD (input_held_flag), A` writes 0 to memory but A remains the byte — that ordering also works, but the XOR-then-load pattern is more obviously correct on a quick read). Either ordering is correct; the wrong order would be `LD A, (input_held_byte)` then `XOR A; LD (input_held_flag), A` which destroys A before returning. Trace carefully.
  - [x] **No defensive "byte == 0 means empty" sentinel.** The flag is the truth. A held byte of `0x00` (NUL) is theoretically possible (Ctrl-@ on some terminals) and must round-trip through the queue intact. Using `0x00` as a "no byte" sentinel would conflate it with a real keystroke.

- [x] **Task 4 — Implement the BIOS_CONIN read + Esc detection branch** (AC: 2, 3, 4)
  - [x] After the `.no_held:` label, read the first byte and dispatch:
    ```asm
    .no_held:
        CALL    BIOS_CONIN              ; A = first byte (blocking)
        CP      VT52_ESC                ; was it Esc?
        RET     NZ                      ; not Esc — printable / ctrl, return as-is (AC2/AC3)

        ;; --- Esc seen — start tick-window poll (AC4 / AC5 / AC6) ---
        LD      B, ESC_TIMEOUT_TICKS    ; default 2 ticks (~40 ms, NFR4)
    .esc_poll:
        CALL    BIOS_CONINST            ; A = nonzero iff byte ready
        OR      A
        JR      NZ, .have_followup
        CALL    tick_wait_one           ; block until next 50Hz tick
        DJNZ    .esc_poll
        ;; --- timeout: bare Esc (AC4) ---
        LD      A, VT52_ESC
        RET
    ```
  - [x] **`CALL BIOS_CONIN` is a CALL to an absolute address.** `BIOS_CONIN EQU 0xFA06` from `inc/bios.inc`; sjasmplus expands `CALL BIOS_CONIN` into `CALL 0xFA06` (i.e. `CD 06 FA`). The W1 placeholder address is wrong on real hardware — Story 1.12 confirms it against MicroBeast docs. Until then, any code that *runs* this CALL on hardware will jump to garbage; this story's UAT path therefore depends on Story 1.12's W1 fix-up landing first OR on a temporary local override (not recommended).
  - [x] **`CALL BIOS_CONINST` returns nonzero iff a byte is ready.** Per `inc/bios.inc` line 34, "nonzero in A if a byte is ready". Some BIOSes return 0xFF, others return 1; `OR A; JR NZ` handles both — never use `CP 1` or `CP 0xFF` here.
  - [x] **`RET NZ` after `CP VT52_ESC` is the printable / control-byte return path.** AC2 / AC3 collapse into this single instruction: any non-Esc byte returns immediately. Don't add a separate non-Esc-fall-through label; the Z80 conditional return is the natural shape.
  - [x] **`DJNZ .esc_poll` is the standard tick-counted loop tail.** `B` was loaded with `ESC_TIMEOUT_TICKS` before entering the loop; each iteration waits one tick (via `tick_wait_one`) and decrements `B`. On B=0 fall-through, the timeout has elapsed.
  - [x] **`CALL tick_wait_one` BEFORE `DJNZ`.** First poll happens immediately (no wait); if no byte ready, wait a tick, poll again. This gives a 1-2 tick window: a follow-up arriving immediately is caught on the first CONINST check (no wait); a follow-up arriving in the second tick is caught after one wait. Total worst case = 2 ticks ≈ 40 ms.

- [x] **Task 5 — Implement the Esc-followup branch and the held-byte queue** (AC: 5, 6)
  - [x] After `.have_followup:`, read the follow-up byte and synthesise:
    ```asm
    .have_followup:
        CALL    BIOS_CONIN              ; A = follow-up byte (consumed)
        CALL    synthesize_arrow_key    ; A = KEY_ARROW_* on hit, A unchanged on miss; CF=0 hit, CF=1 miss
        RET     NC                      ; recognised arrow — A holds synthesised code (AC5)

        ;; --- AC6: unrecognised follow-up — queue + return bare Esc ---
        LD      (input_held_byte), A    ; stash the follow-up
        LD      A, 1
        LD      (input_held_flag), A    ; mark queue valid
        LD      A, VT52_ESC             ; report bare Esc this call
        RET
    ```
  - [x] **Stash the follow-up BEFORE setting the flag.** If you set the flag first, an interrupt firing between the flag-set and the byte-store could leave the flag-set + byte-uninitialised state — `input_held_byte` would be the previous queued byte (or boot garbage if first-ever Esc). Order: byte first, then flag. (The MicroBeast ISR doesn't actually call back into `input_get_key`, so this is theoretical, but the discipline matches `gapbuf_insert`'s "buffer-full check before any write" pattern from Story 1.7.)
  - [x] **`synthesize_arrow_key` returns CF=1 on miss with A preserved**, so the queue path can stash the original follow-up byte. Don't trash A in the helper's miss path.
  - [x] **AC6's primary value is a vi-fluent UX**: the `<Esc>h` pattern (cancel insert mode then motion left) is bread-and-butter vi. Without the queue, fast-typed `<Esc>h` within the 40 ms window drops the `h`. With the queue, the Esc returns this call (cancels insert mode) and the next call returns the `h` (motion).

- [x] **Task 6 — Implement `synthesize_arrow_key` helper** (AC: 5)
  - [x] Four-line contract per AR23:
    ```asm
    ; ----------------------------------------------------------------
    ; synthesize_arrow_key
    ; Map a VT52 Esc-suffix byte to the synthesised single-byte
    ; arrow keycode (KEY_ARROW_*) per RI5/V1. Recognised: 'A'..'D'.
    ; All other bytes return CF=1 (miss) with A preserved so the
    ; caller can queue the original byte.
    ;
    ; In:      A = follow-up byte (consumed by BIOS_CONIN)
    ; Out:     CF = 0, A = KEY_ARROW_UP/DOWN/LEFT/RIGHT on hit;
    ;          CF = 1, A unchanged on miss.
    ; Trashes: F (and A on hit only)
    ; Calls:   (none)
    ; ----------------------------------------------------------------
    ```
  - [x] Implementation — 4 explicit `CP` / `JR Z` checks + a fall-through miss. Don't try to be clever with arithmetic mapping (`'A'..'D' → 0x80..0x83 - 1`) because the mapping is non-monotonic: `'C' → KEY_ARROW_RIGHT (0x83)` and `'D' → KEY_ARROW_LEFT (0x82)` are reversed vs the alphabetical ordering. A small jump table is the safest readable form:
    ```asm
    synthesize_arrow_key:
        CP      'A'
        JR      Z, .up
        CP      'B'
        JR      Z, .down
        CP      'C'
        JR      Z, .right
        CP      'D'
        JR      Z, .left
        SCF
        RET                             ; miss: CF=1, A unchanged
    .up:
        LD      A, KEY_ARROW_UP
        OR      A                       ; CF=0
        RET
    .down:
        LD      A, KEY_ARROW_DOWN
        OR      A
        RET
    .right:
        LD      A, KEY_ARROW_RIGHT
        OR      A
        RET
    .left:
        LD      A, KEY_ARROW_LEFT
        OR      A
        RET
    ```
  - [x] **`OR A` clears CF after the LD that doesn't touch CF.** `LD A, imm` does NOT modify the flags (Z80 quirk). Without the explicit `OR A` (or `AND A`), CF on the hit return is whatever the caller had at entry — and the caller's `RET NC` at the call site (Task 5) would mis-branch unpredictably. Do not omit the `OR A`.
  - [x] **`SCF` sets CF; `RET` carries CF out.** The miss path is one `SCF; RET` — A is naturally preserved (no LD).
  - [x] **Mapping table is in the architecture's RI5 reference (lines 602-605) and `inc/modes.inc` lines 39-42.** Both must agree. If you ever edit `inc/modes.inc` arrow values, this helper's `LD A, KEY_ARROW_*` lines pick up the new constants automatically — no per-byte rewrite needed.

- [x] **Task 7 — Implement `tick_wait_one` helper** (AC: 7, 8)
  - [x] Four-line contract per AR23:
    ```asm
    ; ----------------------------------------------------------------
    ; tick_wait_one
    ; Block until the BIOS-managed 50 Hz tick counter advances by
    ; at least one tick from its value at routine entry. The
    ; underlying counter is at BIOS_TICK_ADDR (per inc/bios.inc).
    ;
    ; The tick counter is 16 bits and wraps from 0xFFFF to 0x0000
    ; every ~21.8 minutes. We compare deltas via SBC HL, DE — any
    ; nonzero delta unblocks (the wrap survives because we exit on
    ; "differs", not on "reaches a target value"). Reads are
    ; bracketed by DI/EI per the inc/bios.inc reader contract
    ; (lines 51-65) — the ISR is the only writer, so DI/EI is the
    ; cheap mitigation against torn 16-bit reads.
    ;
    ; In:      (none)
    ; Out:     (none — side effect: blocks ~20 ms)
    ; Trashes: A, DE, HL, F
    ; Calls:   (none)
    ; ----------------------------------------------------------------
    ```
  - [x] Implementation outline:
    ```asm
    tick_wait_one:
        DI
        LD      DE, (BIOS_TICK_ADDR)    ; snapshot tick at entry
        EI
    .spin:
        DI
        LD      HL, (BIOS_TICK_ADDR)    ; current tick
        EI
        OR      A                       ; clear CF (SBC reads it)
        SBC     HL, DE                  ; HL = current - snapshot (wrap-safe)
        JR      Z, .spin                ; same tick — keep spinning
        RET                             ; differs — at least one tick passed
    ```
  - [x] **DI/EI bracketing is non-negotiable.** Per `inc/bios.inc` lines 51-65, the 16-bit `LD HL, (BIOS_TICK_ADDR)` is non-atomic vs the ISR; without DI/EI, the ISR can fire between the L-byte and H-byte read cycles producing a torn read off by 0x100 (~5 s at 50 Hz). The ISR is the only writer of the tick counter, so DI/EI for the duration of the read is sufficient (the alternative — read twice, retry on mismatch — costs more cycles for the same outcome).
  - [x] **`OR A` BEFORE `SBC HL, DE`.** Same trap as Story 1.4's BDOS funnel and Story 1.7's `gapbuf_insert`: `SBC` reads CF; clear it first or the result is off by 1.
  - [x] **`JR Z, .spin` exits on any nonzero delta.** Z is set when HL == DE (no tick passed). Branching on Z keeps spinning; falling through means "tick differs" — at least one tick elapsed (could be 1, could be many if spinning was preempted). Either way, the contract is "at least one tick has passed since entry", which is what the caller needs.
  - [x] **Wrap-safety of `SBC HL, DE`.** When the tick counter wraps from 0xFFFF to 0x0000, an entry-snapshot of 0xFFFE and a current of 0x0001 give `0x0001 - 0xFFFE = 0x0003` (with borrow — but we're branching on Z, not on sign or carry, so the borrow is irrelevant; `0x0003 != 0` so we exit). The "exit on differs" semantics is wrap-safe by construction. If you ever change to "exit when current >= snapshot + 1", the wrap will hang the routine for ~21.8 minutes.
  - [x] **Don't poll a global "tick happened" flag.** The MicroBeast BIOS does not maintain such a flag — only the free-running counter. Reading the counter directly is the only mechanism.
  - [x] **Scheduling note (informational, not a code change).** The DI/EI windows in this routine are tiny (4-byte LD + a couple of opcodes), so the ISR latency penalty is negligible. If a future story (e.g., serial input via a different ISR) makes this latency-sensitive, revisit; today's only ISR is the tick itself, and missing one tick during another tick's read is OK (the next read sees the increment).

- [x] **Task 8 — Wire `src/input.asm` into `src/vibe.asm` per AR25** (AC: 11)
  - [x] Edit `src/vibe.asm`: add `INCLUDE "input.asm"` AFTER the `RET` stub at `ORG 0x0100` and BEFORE `INCLUDE "statusln.asm"`. The exact insertion site lands a new section block immediately before the existing `;; --- Status-line module ---` block:
    ```asm
        ORG 0x0100

        RET                     ; Stub exit ...

    ;; --- Input layer (RI5; input.asm — Story 1.8) ---
    ; AR25 order: ORG 0x0100 -> init -> input -> statusln -> gapbuf
    ; (architecture line 180). init lands in Story 1.12; input is the
    ; first module-include after the RET stub. Production callers of
    ; input_get_key arrive in Story 1.12 (the real input_loop body
    ; ties input_get_key + dispatch_key + render_diff together).
        INCLUDE "input.asm"

    ;; --- Status-line module (MC5; statusln.asm — Story 1.5) ---
    ; (existing block continues unchanged from here)
        INCLUDE "statusln.asm"
    ```
  - [x] **AR25 ordering is `init -> input -> statusln -> gapbuf`.** init (Story 1.12) doesn't exist yet, so input becomes the first INCLUDE after `ORG 0x0100`. When init lands in Story 1.12, it slots in BEFORE input (above this new block).
  - [x] **Update `src/vibe.asm`'s header `Dependencies:` line.** Add `src/input.asm (Story 1.8)` to the list (after `src/statusln.asm (Story 1.5); src/gapbuf.asm (Story 1.7)`):
    ```
    ; Dependencies:
    ;   inc/equates.inc, inc/bios.inc, inc/bdos.inc, inc/vt52.inc,
    ;   inc/modes.inc, inc/state.inc; src/input.asm (Story 1.8);
    ;   src/statusln.asm (Story 1.5); src/gapbuf.asm (Story 1.7)
    ```
  - [x] **Update the `;; --- Input-loop abort target ---` comment block.** The Story 1.5 stub above `input_loop:` (vibe.asm lines 57-63) currently predicts "Story 1.8 replaces this body with the real input-loop top of frame". That prediction is wrong — Story 1.8 lands `input_get_key` only; the unified `input_loop` body needs `dispatch_key` (Story 1.9) + `render_diff` (Story 1.11), tied together in Story 1.12. Update the comment to point to Story 1.12 as the owner:
    ```asm
    ;; --- Input-loop abort target (Story 1.5 stub; Story 1.12 owns) ---
    ; bdos_error_funnel JPs here after writing its status message.
    ; Story 1.5: stub that warm-boots back to CCP via BDOS_EXIT — a
    ; clean exit when the editor cannot continue (NFR5: no crash).
    ; Story 1.12 (init/teardown + on-hardware smoke test) replaces
    ; this body with the real input-loop top of frame
    ; (input_get_key -> dispatch_key -> render_diff -> repeat) so
    ; the editor recovers from a BDOS error rather than exiting.
    ; Story 1.8 added input_get_key (in src/input.asm) but does NOT
    ; touch this stub — the loop wiring waits for 1.12.
    input_loop:
        BDOS_CALL BDOS_EXIT
        RET                     ; defensive — BDOS_EXIT never returns
    ```
  - [x] **Do NOT move the `INCLUDE "../inc/state.inc"` line.** state.inc must remain the LAST include in vibe.asm (the positional anchor for `static_data_base EQU $`). The new `INCLUDE "input.asm"` lands BEFORE statusln, well above state.inc.
  - [x] **Do NOT add a top-level `CALL input_get_key` to vibe.asm.** The `RET` stub at 0x0100 stays in place until Story 1.12. `input_get_key` is callable; production callers arrive in Stories 1.9 (dispatch consumes it) / 1.12 (init wires the loop).
  - [x] **Verify byte-deterministic rebuild (AC12).** `make clean && make && sha256sum vibe.com`, then again — both SHAs should match. If they differ, look for an accidentally-introduced macro that touches `$` or a per-pass forward-reference reordering.

- [x] **Task 9 — AR15 grep verification** (AC: 9)
  - [x] After Task 2-7 land, run `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY|BDOS_CALL' src/input.asm` and confirm zero matches.
  - [x] If the grep finds anything, the input layer has accidentally pulled in BDOS — likely a copy/paste from `src/statusln.asm`'s `bdos_error_funnel`. Input is BIOS-only by design (CONIN/CONINST + tick counter); BDOS has no role here. Remove the offending CALL.
  - [x] **The grep pattern matches three forms** (per Story 1.7's AC11 prior art): a literal `CALL 0x0005` (raw BDOS entry), a `CALL BDOS_ENTRY` (the EQU symbol), and any `BDOS_CALL` macro invocation. All three are forbidden in `src/input.asm`.

- [x] **Task 10 — Verify existing tests still pass and `vibe.com` rebuilds deterministically** (AC: 12, 13)
  - [x] Run `make clean && make` twice, then `sha256sum vibe.com` after each — confirm matching SHAs.
  - [x] Capture both SHAs in the Debug Log References section of this story's Dev Agent Record.
  - [x] Run `make -C test test` — confirm the same 6-pass / 1-fail result as Story 1.7's debug log (the deliberate `harness_fail` is the only fail). Capture the output verbatim in Debug Log References.
  - [x] If any `gapbuf_*` test starts failing, the most likely cause is a state.inc layout regression — check that `gap_start` / `gap_end` / `cursor_offset` symbols still resolve correctly (they should, since tests use the symbols, not addresses).

- [ ] **Task 11 — *Optional* — Add `test/smoke/input_smoke.asm` for hardware UAT** (AC: 14 — optional path)
  - [ ] If time permits and Ant wants a UAT scaffold before Story 1.12 lands, create `test/smoke/input_smoke.asm` with this shape:
    ```asm
    ; ============================================================
    ; Module: test/smoke/input_smoke.asm
    ; Purpose: One-off UAT smoke for input_get_key (Story 1.8).
    ;          Loops calling input_get_key and emitting each
    ;          returned byte as 2 hex chars + space via BIOS_CONOUT.
    ;          Quits on 'q' (or your chosen exit key). Runs ON
    ;          MICROBEAST HARDWARE ONLY — iz-cpm does not emulate
    ;          the W1 BIOS jump table at 0xFA0X (per inc/bios.inc).
    ;
    ; UAT validation against Story 1.8 ACs:
    ;   AC2: type 'a' -> screen shows "61 "
    ;   AC3: type Ctrl-L -> screen shows "0C "
    ;   AC4: tap Esc and wait -> shows "1B " after ~40 ms (NFR4)
    ;   AC5: Esc + arrow-up -> shows "80 " (no "1B" before it)
    ;   AC6: Esc + 'h' (within 40 ms) -> shows "1B 68 " (Esc THEN 'h')
    ; ============================================================
        INCLUDE "../../inc/equates.inc"
        INCLUDE "../../inc/bios.inc"
        INCLUDE "../../inc/bdos.inc"
        INCLUDE "../../inc/vt52.inc"
        INCLUDE "../../inc/modes.inc"

        ORG 0x0100
    smoke_loop:
        CALL    input_get_key            ; A = keycode
        LD      C, A
        ;; Print A as 2 hex chars via BIOS_CONOUT, then space.
        PUSH    AF
        ;; ... (high-nibble print, low-nibble print, space)
        POP     AF
        CP      'q'
        JR      NZ, smoke_loop
        LD      C, BDOS_EXIT
        CALL    BDOS_ENTRY
        RET

        INCLUDE "../../src/input.asm"
        INCLUDE "../../inc/state.inc"     ; state.inc LAST (AR25)
    ```
  - [ ] **Mirrors `test/smoke/statusln_smoke.asm`'s scaffolding pattern** (lines 39-225) — one-off smoke under `test/smoke/`, NOT under `test/cases/` (the headless harness's wildcard). The harness will not pick it up automatically.
  - [ ] **Build with `sjasmplus --nologo --msg=err --raw=test/smoke/input_smoke.com test/smoke/input_smoke.asm`** then push to MicroBeast via SLIDE (or whatever transfer mechanism is current). Run `input_smoke` from the CCP and validate AC2-AC8 by hand.
  - [ ] **This task is OPTIONAL.** Skipping it is fine — Story 1.12's hardware bring-up is the canonical UAT gate. The smoke is a convenience for early validation.
  - [ ] **Do NOT use BDOS function 9 (print-string) for the hex emit.** AR15 only allows BIOS-direct console I/O for the editor's runtime path; using BDOS in this smoke is fine for the EXIT call (function 0) but the per-byte hex emit should mirror the production path (BIOS_CONOUT) to validate it works on hardware. (BDOS function 2 / 9 also works but doesn't exercise the BIOS path.)

## Dev Notes

### Critical traps — what to watch for when implementing this story

**🛑 BIOS_CONIN / BIOS_CONINST / BIOS_TICK_ADDR are W1 placeholder addresses.** Per `inc/bios.inc` lines 24-32 and 65, the values `0xFA06` / `0xFA09` / `0xFA00` are documented placeholders — the real MicroBeast BIOS jump-table and tick-counter addresses get confirmed in Story 1.12's hardware bring-up. This means: (a) calling `input_get_key` under iz-cpm will jump to garbage at `0xFA06` (iz-cpm doesn't emulate this jump table); (b) hardware UAT for Story 1.8 depends on Story 1.12's W1 fix-up landing first OR on a temporary local override (not recommended). The story 1.8 smoke (Task 11) is therefore a "build for later" artifact unless you patch in confirmed BIOS addresses ad hoc.

**🛑 The 16-bit tick read is NON-ATOMIC.** Documented in `inc/bios.inc` lines 51-65. Without `DI`/`EI` bracketing, the ISR can fire between the L-byte and H-byte cycles, producing a torn 16-bit value off by 0x100 (~5 s at 50 Hz). The ISR is the only writer, so `DI`/`EI` for the duration of the read is sufficient (cheaper than read-twice-and-retry, which costs ~3× cycles for the same outcome). The DI/EI window in `tick_wait_one` is tiny (one `LD HL, (nn)` opcode + EI), so the ISR latency penalty is negligible.

**🛑 The tick counter wraps every ~21.8 minutes.** A reader that compares to an absolute target (`current >= entry_snapshot + 1`) hangs for 21.8 minutes when the entry snapshot is `0xFFFF`. Use the "exit on differs" pattern: `SBC HL, DE; JR Z, .spin` — Z set means "still on entry tick", anything else (even a wrap) means "tick has advanced". Wrap-safe by construction. Same trap that `inc/equates.inc` lines 37-39 flag for `GAP_BUFFER_MAX` (high-bit-set 16-bit values must be unsigned-compared) — the discipline generalises.

**🛑 `OR A` before `SBC HL, DE`.** `SBC` reads CF; without an explicit clear, CF is whatever the previous instruction left. This trap surfaces in `tick_wait_one` (Task 7) and was previously called out in Stories 1.4 (`bdos_error_funnel`) and 1.7 (`gapbuf_insert`'s buffer-full check). The fix is one byte (`OR A` = 0xB7); the omission silently inverts the comparison branch.

**🛑 `LD A, imm` does NOT modify the flags.** This is a Z80 quirk. After `LD A, KEY_ARROW_UP`, CF is whatever the call site had at entry — and the caller's `RET NC` branches on the unmodified CF, not on a "successful synthesis" signal. `synthesize_arrow_key`'s hit paths MUST end with `OR A; RET` (or `AND A; RET`) to deterministically clear CF. The miss path uses `SCF; RET` to set CF.

**🛑 The Esc/arrow synthesis mapping is NOT monotonic in 'A'..'D'.** ESC `'A'` → 0x80 (UP), ESC `'B'` → 0x81 (DOWN), ESC `'C'` → 0x83 (RIGHT — note: 0x83, not 0x82), ESC `'D'` → 0x82 (LEFT — note: 0x82, not 0x83). The C/D / RIGHT/LEFT pair is reversed vs alphabetical. Don't try to compute the keycode arithmetically; use 4 explicit `CP` / `JR Z` checks. The mapping is pinned in `inc/modes.inc` lines 39-42.

**🛑 The held-byte queue pattern: byte FIRST, then flag.** If the flag is set before the byte is stored, an interrupt firing in between (theoretical — the MicroBeast ISR doesn't call back into `input_get_key` today) leaves the flag set with stale-or-uninitialised byte data. Discipline matches `gapbuf_insert`'s "buffer-full check before any write" pattern from Story 1.7.

**🛑 `0x00` (NUL) is a valid keycode.** Don't use a sentinel value for "queue empty" — the flag byte IS the validity signal. Theoretical Ctrl-@ keystrokes (or any future handler that queues a byte programmatically) must round-trip through `input_held_byte` intact.

**🛑 `BIOS_CONINST` returns "nonzero iff byte ready" — value-agnostic.** Per `inc/bios.inc` line 34. Some BIOSes return 0xFF, some return 1, some return any nonzero. Always test with `OR A; JR NZ`; never with `CP 1` / `CP 0xFF`.

**🛑 First poll happens BEFORE the first `tick_wait_one`.** A follow-up byte that's already in the BIOS ring at the moment Esc is detected must be picked up immediately (no 20-ms wait). Loop shape: read first byte, check Esc, then for B in [ESC_TIMEOUT_TICKS..1]: CONINST → if ready, jump out; else tick_wait_one; DJNZ. The first iteration's CONINST is the immediate poll; the wait happens AFTER the check. If you flip the order (`tick_wait_one; CONINST; DJNZ`), you've added 20-40 ms of mandatory latency to every Esc-disambiguated arrow keypress.

**🛑 `state.inc` MUST remain the LAST INCLUDE in `src/vibe.asm` AND in any test file.** Adding fields to `state.inc` is fine; moving the `INCLUDE "../inc/state.inc"` line is not. The positional anchor `static_data_base EQU $` resolves to "first address past code" only when state.inc is INCLUDEd after every code-emitting source. Story 1.3's design pinned this; the `ASSERT static_data_base >= 0x0101` at state.inc line 40 catches the "before ORG" case but does NOT catch "INCLUDEd between source files" — the build would succeed and silently corrupt addresses.

**🛑 `inc/state.inc` layout shifts by 2 bytes after this story.** Every field positioned via `static_off` after `pending_motion_prefix` (i.e. `cursor_offset`, `gap_start`, `gap_end`, ..., `yank_buffer`, `yank_end`) shifts up by 2 bytes. All references are symbolic, so existing code is unaffected, but the SHA of `vibe.com` changes (deliberate, AC12). Two consecutive rebuilds still produce byte-identical output (NFR18 holds).

**🛑 The `;; --- Input-loop abort target ---` comment block in `src/vibe.asm` is wrong and must be updated.** It currently predicts that Story 1.8 replaces the `input_loop` body. That prediction was made when writing Story 1.5 — in reality, Story 1.8 only adds `input_get_key`; the unified loop body needs `dispatch_key` (Story 1.9) + `render_diff` (Story 1.11), tied together in Story 1.12. Update the comment as part of Task 8. If you leave it stale, future readers will spend time looking for the body change that doesn't exist in this story.

### Architecture compliance — what AR* / SR* / NFR* / TH* rules this story locks in

| Rule | Story 1.8 obligation |
|---|---|
| AR6  | All compile-time knobs in `inc/equates.inc`. Story 1.8 uses `ESC_TIMEOUT_TICKS` (already declared in equates.inc since Story 1.2). No new equates. |
| AR7  | BIOS jump-table addresses in `inc/bios.inc`. Story 1.8 reads `BIOS_CONIN` / `BIOS_CONINST` / `BIOS_TICK_ADDR` (all declared in bios.inc since Story 1.4). No new BIOS symbols. |
| AR10 | Mode IDs and synthesised arrow keycodes in `inc/modes.inc`. Story 1.8 reads `KEY_ARROW_UP/DOWN/LEFT/RIGHT` (declared in modes.inc since Story 1.2). No new mode/key equates. |
| AR12 | Single status-message funnel: `src/input.asm` does NOT call `status_set_message` — Esc-timeout is not an error condition; bare Esc is a valid key; no error-or-info status path enters this module. AR12 holds by virtue of the input layer not touching the status surface at all. |
| AR15 | Single BDOS gateway: `src/input.asm` does NOT invoke `BDOS_CALL`, does NOT contain raw `CALL 0x0005` or `CALL BDOS_ENTRY`. AC9 grep enforces. Input is BIOS-only (CONIN / CONINST / tick counter). |
| AR16 | Status-message string-table convention: not applicable — input.asm has no message strings. |
| AR21 | Headless coverage scope: Esc/arrow timing is explicitly carved out of the headless harness. AC14 enforces — no `test/cases/input_*.asm` files in this story. UAT is the gate. |
| AR22 | Naming: `input_get_key`, `tick_wait_one`, `synthesize_arrow_key` are `module_action` lowercase; internal labels use dotted-locals (`.no_held`, `.have_followup`, `.up`, `.spin`, etc.). The state.inc fields `input_held_byte` / `input_held_flag` are also lowercase per AR22 (runtime variables). |
| AR23 | Module header block + four-line `In:` / `Out:` / `Trashes:` / `Calls:` per public routine AND per internal helper (`tick_wait_one`, `synthesize_arrow_key`). AC1 enforces. |
| AR24 | UPPERCASE mnemonics + registers; 4-space indent; `;` line / `;;` section comments; null-terminated strings (none in input.asm — no message strings). |
| AR25 | `INCLUDE "input.asm"` in `src/vibe.asm` lands AFTER the `RET` stub at `ORG 0x0100` and BEFORE `INCLUDE "statusln.asm"` — matching architecture line 180's order (`init -> input -> statusln -> gapbuf`). When init.asm lands in Story 1.12, it slots in BEFORE this new INCLUDE. |
| MC4 | Handler signature: register-passed parameters (none for `input_get_key`'s entry; A on exit). Caller-saved everywhere; callers preserve what they need across the call. |
| MC7 | All cross-module state via symbols in `state.inc`. Story 1.8 declares `input_held_byte` and `input_held_flag` in state.inc per the convention (AC10). Module owns the read/write semantics; declaration site is state.inc. |
| RI5 | Esc-disambiguation pattern: `BIOS_CONIN` blocks for first byte → if Esc, open a `CONINST + tick_wait_one` poll loop bounded by `ESC_TIMEOUT_TICKS` → on follow-up, synthesise `KEY_ARROW_*` for `'A'..'D'` or queue + bare-Esc for unrecognised. Reference at architecture lines 583-619; Story 1.8 implements verbatim plus the held-byte queue (which the architecture's reference left as an open implementation detail per the story's own AC6 phrasing). |
| RI6 | Input-loop top level: single `input_get_key → dispatch` loop, no interrupt-driven event queue. Story 1.8 lands `input_get_key`; the actual loop body (`input_loop` in `vibe.asm`) is not touched in this story — Story 1.12 wires it. |
| NFR2 | Sustained typing throughput: ≥10 chars/sec, no dropped keys at typical human speeds. The held-byte queue (AC6) is the hedge against the `<Esc>h`-style fast vi pattern where the follow-up byte arrives within the 40 ms window but is unrecognised. Without the queue, that case drops the follow-up. |
| NFR4 | Esc disambiguation budget: bounded by `ESC_TIMEOUT_TICKS × 20 ms` ≈ 40 ms. The `tick_wait_one` helper delivers the 20 ms-per-tick block deterministically. UAT-validated on hardware. |
| NFR5 | No crashes: bounded arithmetic, no unbounded loops (the `DJNZ .esc_poll` is bounded by `ESC_TIMEOUT_TICKS`; the `JR Z, .spin` in `tick_wait_one` exits on any tick advance — bounded by ~20 ms in practice). |
| NFR9 | Code-size budget: input layer is small. Estimated 60-100 bytes for `input_get_key + tick_wait_one + synthesize_arrow_key` combined. Track via `make sizes` (still a stub today; Story 1.11 wires the real version). Stay well within the ~3 KB envelope. |
| NFR10 | TPA fit: state.inc's `ASSERT yank_end <= 0xD800` covers the full code-plus-static-plus-gap-plus-yank envelope. Adding 2 bytes to the static block + ~80 bytes of input.asm leaves comfortable headroom (yank_end was around 0x90xx after Story 1.7; 0xD800 is the ceiling). |
| NFR16 | Knob centralization: input layer references `ESC_TIMEOUT_TICKS`, `BIOS_CONIN`, `BIOS_CONINST`, `BIOS_TICK_ADDR`, `VT52_ESC`, `KEY_ARROW_*` from inc/equates.inc / inc/bios.inc / inc/vt52.inc / inc/modes.inc by symbol; no inline `LD A, 0x1B` or `CALL 0xFA06`. |
| NFR18 | Reproducibility: `vibe.com` byte-identical across rebuilds (AC12). sjasmplus is deterministic on identical input — automatic provided no `--date` flag sneaks into the invocation. |

### Existing files — current state and what this story changes

**`src/input.asm`** *(does not exist):*
- Current: not present.
- This story: create per Tasks 2-7. Single public entry `input_get_key`; two internal helpers `tick_wait_one` and `synthesize_arrow_key`.

**`src/vibe.asm`** *(79 lines, ends with `INCLUDE "../inc/state.inc"`):*
- Current: includes equates/bios/bdos/vt52/modes pre-ORG (lines 29-33), then `ORG 0x0100` (line 35), then `RET` stub (line 37), then `INCLUDE "statusln.asm"` (line 47), then `INCLUDE "gapbuf.asm"` (line 55), then `input_loop:` body (lines 64-67) which is the Story 1.5 stub `BDOS_CALL BDOS_EXIT; RET`, then `INCLUDE "../inc/state.inc"` (line 78).
- This story: insert `INCLUDE "input.asm"` between the `RET` stub and `INCLUDE "statusln.asm"` (so the INCLUDE order becomes statusln-precursor → `input.asm` → `statusln.asm` → `gapbuf.asm` → input_loop stub → state.inc, matching AR25's `init → input → statusln → gapbuf` order with init still pending in Story 1.12). Update the `;; --- Input-loop abort target ---` comment block (lines 57-63) to point to Story 1.12 as the loop-body owner (the Story 1.5 prediction that 1.8 owns this is wrong). Update header `Dependencies:` line (line 22) to add `src/input.asm (Story 1.8)`. Do NOT modify the `input_loop:` body itself.

**`inc/state.inc`** *(122 lines, small-state block at lines 43-57):*
- Current: declares `mode_byte`, `visual_submode`, `buffer_dirty`, `pending_operator`, `yank_kind`, `status_dirty`, `pending_motion_prefix` in the small-state section (single bytes via `static_off + 1` per declaration). Then the 16-bit-state block, then buffers, then anchors / NFR10 ASSERT.
- This story: append `input_held_byte` and `input_held_flag` to the small-state block immediately after `pending_motion_prefix` (lines 56-57). Each adds 1 byte; total +2 bytes. Update the `Public:` block in the header to enumerate both new symbols under "Small state". The `ASSERT yank_end <= 0xD800` at line 121 still passes (yank_end shifts up by 2 bytes; well within the ceiling).

**`src/statusln.asm`** *(183 lines):*
- Current: Story 1.5 + Story 1.7 baseline. Provides `status_set_message`, `bdos_error_funnel`, `status_render`, message-string block at lines 174-182.
- This story: NOT modified. Input layer does not need a status message; AR12 (single status funnel) is upheld by virtue of input.asm not touching the status surface at all.

**`src/gapbuf.asm`**, **`inc/equates.inc`**, **`inc/bios.inc`**, **`inc/bdos.inc`**, **`inc/modes.inc`**, **`inc/vt52.inc`**:
- All unchanged. Story 1.8 reads `ESC_TIMEOUT_TICKS` (equates), `BIOS_CONIN` / `BIOS_CONINST` / `BIOS_TICK_ADDR` (bios), `VT52_ESC` (vt52), `KEY_ARROW_*` (modes) — all already declared in their headers from prior stories.

**`Makefile`** / **`test/Makefile`** / **`test/inc/test_*.inc`**:
- All unchanged. Build infrastructure handles the new module via `wildcard src/*.asm` (top-level Makefile line 29). Test harness picks up no new cases (AC14: no `test/cases/input_*.asm`).

**`test/cases/`** *(currently 7 files: harness_pass/harness_fail + 5 gapbuf cases + gapbuf_delete-mid added during 1.7 review):*
- Current: 7 cases.
- This story: NO new test cases. AR21 carves out Esc/arrow timing from the headless harness; iz-cpm cannot meaningfully validate the 50 Hz tick window AND does not emulate the W1 BIOS jump-table addresses at 0xFA0X. The headless harness has nothing useful to say about input.asm in this story. Existing 6 pass / 1 fail count holds (AC13).

**`test/smoke/`** *(currently 2 files: bdos_call_smoke.asm + statusln_smoke.asm):*
- Current: 2 smokes from Stories 1.4 / 1.5.
- This story: OPTIONAL — Task 11 sketches `test/smoke/input_smoke.asm` for hardware UAT. Skipping is fine; Story 1.12 is the canonical UAT gate.

**Files NOT touched by this story (do not edit):**
- `inc/equates.inc`, `inc/bios.inc`, `inc/bdos.inc`, `inc/modes.inc`, `inc/vt52.inc` — all referenced by symbol; no edits needed.
- `Makefile`, `test/Makefile` — build infrastructure unchanged.
- `test/cases/*.asm` — no new headless tests; existing tests unmodified.
- `test/smoke/bdos_call_smoke.asm`, `test/smoke/statusln_smoke.asm` — prior-story smokes remain in place.
- `test/inc/test_prologue.inc`, `test/inc/test_epilogue.inc`, `test/inc/test_input_loop_stub.inc` — test scaffold unchanged.
- `test/fixtures/hello.txt` — unchanged.
- `README.md`, `test/README.md` — documentation already covers the harness; no story-1.8-specific updates required.
- `src/gapbuf.asm`, `src/statusln.asm` — production modules unchanged.

**Files created by this story:**
- `src/input.asm` (new — primary deliverable)
- *(optional)* `test/smoke/input_smoke.asm` — UAT smoke harness; one-off, hardware-only.

**Files modified by this story:**
- `src/vibe.asm` — add `INCLUDE "input.asm"` (per AR25); update `;; --- Input-loop abort target ---` comment block to point to Story 1.12 as loop-body owner; update header Dependencies list.
- `inc/state.inc` — append `input_held_byte` and `input_held_flag` to the small-state block; update header Public list.

### Library / framework requirements

**sjasmplus 1.23.0:**
- Already pinned by `Makefile`'s `check-toolchain` (Story 1.1). No new toolchain pin in this story.
- **Multi-pass assembly resolves forward references.** `src/input.asm` references `BIOS_CONIN` / `BIOS_CONINST` / `BIOS_TICK_ADDR` / `ESC_TIMEOUT_TICKS` / `VT52_ESC` / `KEY_ARROW_*` / `input_held_byte` / `input_held_flag` — all defined in `inc/*.inc` headers INCLUDEd before input.asm in `src/vibe.asm` (per the AR25 ordering pre-ORG). For test smokes, the `INCLUDE "src/input.asm"` line lands after the relevant `INCLUDE "../../inc/*"` headers per the same convention.
- **`DI` / `EI` are standard Z80 instructions.** sjasmplus assembles them as `0xF3` and `0xFB` respectively. No special syntax.

**iz-cpm:**
- NOT used for input testing in this story (AR21 + W1 placeholder addresses). The harness still runs for the existing `gapbuf_*` cases (AC13).
- The `make test` baseline (6 pass / 1 fail) holds after this story.

**CP/M 2.2 BDOS:**
- NOT called by `src/input.asm`. AC9 grep enforces. The vibe.asm `input_loop:` stub still calls `BDOS_CALL BDOS_EXIT` (Story 1.5 baseline); Story 1.8 does not modify that body.

**MicroBeast BIOS:**
- `BIOS_CONIN` (blocking byte read, returns A = byte; `inc/bios.inc` line 33), `BIOS_CONINST` (non-blocking poll, returns A = nonzero iff byte ready; line 34), `BIOS_TICK_ADDR` (16-bit 50 Hz counter address, ISR-maintained; line 65). All three are W1 placeholders; Story 1.12 confirms the addresses against MicroBeast docs/disassembly. Until then, code that runs against these addresses on real hardware will jump to the wrong place — UAT is therefore tied to Story 1.12's W1 fix-up.

### Smoke / UAT harness pattern (Task 11 — optional)

Every `test/smoke/*.asm` file follows a similar structure to the production modules — pre-ORG header includes, `ORG 0x0100`, smoke body, exit via BDOS function 0, INCLUDE the production source(s) under test, INCLUDE state.inc LAST. The pattern is documented in detail at `test/smoke/statusln_smoke.asm` lines 39-225 (the closest prior art).

Key differences for an `input_smoke` UAT harness:

1. **MUST run on MicroBeast hardware**, not under iz-cpm. iz-cpm doesn't emulate `BIOS_CONIN` / `BIOS_CONINST` / `BIOS_TICK_ADDR` at the W1 placeholder addresses. Any iz-cpm run jumps to garbage at 0xFA0X.
2. **Output goes to BIOS_CONOUT, not BDOS function 9.** AR15 says the editor uses BIOS-direct for emission; the smoke should mirror this to validate the BIOS path, not the BDOS path.
3. **Exit is via BDOS function 0** (`LD C, 0; CALL BDOS_ENTRY`). This is the AR15 carve-out for the test scaffold (test/inc/test_epilogue.inc lines 24-37) — same exemption applies to smokes.
4. **A "quit" key (e.g. `'q'`) is the recommended exit mechanism.** Hardware-only smokes can't be timed out by the host; the user must terminate manually. Pick a key that's unambiguous (avoid Esc — it interacts with the very feature under test).
5. **Hex emit per byte** lets the operator validate AC2-AC8 by reading the screen. Pattern: high nibble → `RRCA × 4; AND 0x0F`, low nibble → `AND 0x0F`, each via `nibble_to_char` (mirroring `test/inc/test_epilogue.inc` lines 79-102's `.write_hex_byte` / `.nibble_to_char`).

If you build the smoke, document the per-AC hardware test plan in the file's header block — operator runs the smoke, types the keys per the plan, verifies the screen output matches the expected hex (e.g. ESC `'A'` produces `80` on screen, not `1B 41`).

### Previous story intelligence (Stories 1.1–1.7)

**From Story 1.1:**
- `make` from project root produces `vibe.com` deterministically. Adding `src/input.asm` and the two new state.inc fields shifts the layout but preserves byte-determinism (NFR18). AC12 verifies.

**From Story 1.2:**
- `inc/equates.inc` defines `ESC_TIMEOUT_TICKS EQU 2` (line 50). The default is empirically tunable per AC's UAT — if 2 ticks (~40 ms) feels off on real hardware, edit the equate and rebuild. The user explicitly mentions tuning in the AC.
- `inc/modes.inc` defines `KEY_ARROW_UP/DOWN/LEFT/RIGHT EQU 0x80/0x81/0x82/0x83` (lines 39-42). The synthesised codes are pinned here; `src/input.asm`'s `synthesize_arrow_key` reads them by symbol.

**From Story 1.3:**
- `inc/state.inc` is the canonical static-memory map. New fields append to the small-state block (after `pending_motion_prefix` at line 56-57) per the convention. The positional `static_off` advance is mechanical; symbols below shift up by the added byte count. The `ASSERT yank_end <= 0xD800` at line 121 catches NFR10 violations at build time.
- **gap_start / gap_end / cursor_offset are positional; symbol-only access is the rule.** Tests in Story 1.7 use symbols, not addresses — so the layout shift in Story 1.8 doesn't break them (AC13).

**From Story 1.4:**
- `inc/bios.inc` lines 51-65 document the `BIOS_TICK_ADDR` reader contract: 16-bit non-atomic vs ISR; mitigate via DI/EI bracket; comparisons must be unsigned (wrap-safe). Story 1.8's `tick_wait_one` is the first consumer of this contract.
- `inc/bios.inc` lines 33-35 document `BIOS_CONIN` (blocking) / `BIOS_CONINST` (peek). Story 1.8 is the first consumer of these too.

**From Story 1.5:**
- `src/statusln.asm` is the single status funnel. Input layer does NOT call into it (AR12 holds by absence). The `bdos_error_funnel` JPs to `input_loop` in `vibe.asm` — that JP path is unchanged by Story 1.8 (`input_loop` body remains the Story 1.5 stub until Story 1.12).
- The `;; --- Input-loop abort target ---` comment block in `src/vibe.asm` (lines 57-63) was written when Story 1.5 landed; it predicts Story 1.8 lands the real loop body. That prediction was wrong — Story 1.8 lands `input_get_key` only. Update the comment to reflect the corrected ownership (Story 1.12). This is part of Task 8.

**From Story 1.6:**
- `make test` from project root runs the headless harness; per-case pass/fail/timeout/unknown reporting; non-zero exit on any non-pass. Story 1.8 adds zero new test cases (AR21 carve-out + W1 unavailability). The pre-existing 6 pass / 1 fail count holds (AC13).
- `test/Makefile` greps stdout for `\bPASS\b` / `\bFAIL\b`. Smokes (test/smoke/*.asm) are intentionally outside the cases/*.asm wildcard — the harness does not pick them up automatically. Task 11's optional input_smoke is a hardware-run artifact, not a harness case.

**From Story 1.7:**
- `src/gapbuf.asm` is the prior-art module added at the same architectural tier as `src/input.asm`. Its file structure (header block + `;;` section dividers + per-routine 4-line contracts + dotted-local labels) is the template for `src/input.asm`. The AR15 grep (Story 1.7's AC11) is the prior art for Story 1.8's AC9.
- The held-byte queue pattern (AC6) is conceptually similar to gapbuf's "before-write check" pattern: a small piece of routine-local state where order-of-operations matters. Story 1.7's careful ordering ("buffer-full check before any write") generalises to "stash byte before flag" here.
- gapbuf_*.asm test cases use only state.inc symbols (`gap_start`, `gap_end`, `cursor_offset`) — never raw addresses. State.inc layout shifts in Story 1.8 don't break them.

### Git intelligence

Seven commits on `main` after Story 1.0 (most-recent first per `git log`):

- `11a4560` — story 1.7: Wrote the gap buffer (insert, delete, move, load stub) with headless tests.
- `42af237` — story 1.6: make test builds, runs, and grades every test case off stdout
- `b7ca9a8` — story 1.4: every BDOS call now goes through a macro that catches errors
- `a298547` — story 1.3: Laid out the editor's full memory map at fixed addresses, build-time guarded.
- `eac5ba3` — story 1.2: Named every constant the editor needs, in three .inc headers, wired in.
- *(commit reflecting 1.5)* — story 1.5: every status message now goes through one funnel.
- *(earliest)* — story 1.1: Makefile pins sjasmplus 1.23.0, produces vibe.com.

Conventions visible in the tree (preserve in Story 1.8):
- 4-space indentation, UPPERCASE mnemonics, `;` line / `;;` section comments (AR24).
- AR23 header blocks on every `.asm` and `.inc` file. The new `src/input.asm` follows the same shape.
- Every public routine and internal helper has the `In:` / `Out:` / `Trashes:` / `Calls:` four-line contract (AR23).
- One story per commit; short imperative subject + colon-separated context. Match the user's plain-English style.

Suggested commit message for Story 1.8 (when the dev finishes): `story 1.8: input layer reads keys, disambiguates Esc vs arrow on a 50Hz tick window, queues an unrecognized follow-up.`

### Testing requirements

Story 1.8's testing requirements split into two categories:

**Build-time / static (verifiable in this story):**

1. `make` from project root succeeds (AC11).
2. `make clean && make` produces byte-identical `vibe.com` across two consecutive runs (AC12).
3. `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY|BDOS_CALL' src/input.asm` returns zero matches (AC9).
4. `make -C test test` reports 7 pass / 1 fail (AC13 — Story 1.7's review added `gapbuf_delete-mid`, so the live baseline is one above Story 1.7's debug-log count; only `harness_fail` is failing). Capture verbatim in Debug Log References.
5. The `ASSERT yank_end <= 0xD800` in `inc/state.inc` line 121 still passes after the +2-byte append (AC10).

**UAT (deferred to Story 1.12 hardware bring-up; optionally validated via Task 11's smoke):**

6. AC2 — typing 'a' returns 0x61.
7. AC3 — typing Ctrl-L returns 0x0C.
8. AC4 — bare Esc returns 0x1B after ~40 ms latency (NFR4).
9. AC5 — Esc + 'A'/'B'/'C'/'D' returns 0x80/0x81/0x83/0x82 (note non-monotonic C/D mapping).
10. AC6 — Esc + 'h' (within 40 ms) returns Esc this call, 'h' on the next call (the held-byte queue).
11. AC7 / AC8 — under sustained typing, no dropped keys and no perceptible Esc lag.

Once Story 1.12 lands (init/teardown + on-hardware smoke test), the production input loop runs end-to-end on real MicroBeast hardware, and the UAT ACs become validatable in production form.

### Project Structure Notes

After Story 1.8 the source tree is:

```
src/
├── vibe.asm        # Top-level (now INCLUDEs input.asm + statusln.asm + gapbuf.asm)
├── input.asm       # Story 1.8 — new (input_get_key + tick_wait_one + synthesize_arrow_key)
├── statusln.asm    # Story 1.5 (+ Story 1.7's msg_not_implemented)
└── gapbuf.asm      # Story 1.7

inc/
├── equates.inc     # Story 1.2 (unchanged)
├── bios.inc        # Story 1.4 (unchanged — input.asm reads BIOS_TICK_ADDR / CONIN / CONINST)
├── bdos.inc        # Story 1.4 (unchanged)
├── modes.inc       # Story 1.2 (unchanged — input.asm reads KEY_ARROW_*)
├── vt52.inc        # Story 1.2 (unchanged — input.asm reads VT52_ESC)
└── state.inc       # Story 1.3 (+ Story 1.8's input_held_byte / input_held_flag)

test/
├── README.md
├── Makefile
├── inc/
│   ├── test_prologue.inc
│   ├── test_epilogue.inc
│   └── test_input_loop_stub.inc
├── cases/
│   ├── harness_pass.asm
│   ├── harness_fail.asm
│   ├── gapbuf_delete-at-bof.asm
│   ├── gapbuf_delete-mid.asm
│   ├── gapbuf_insert-empty.asm
│   ├── gapbuf_insert-fills-buffer.asm
│   ├── gapbuf_move-roundtrip.asm
│   └── gapbuf_random-ops.asm
│   # NO input_*.asm — AR21 carve-out + W1 unavailability
├── fixtures/
│   └── hello.txt
└── smoke/
    ├── bdos_call_smoke.asm
    ├── statusln_smoke.asm
    └── input_smoke.asm     # Story 1.8 — OPTIONAL (Task 11; hardware-only UAT)
```

Architecture's reference layout (lines 1278-1339) anticipates exactly this — `src/input.asm` between `init.asm` (Story 1.12) and `statusln.asm` per AR25's chain. Stories 1.9 onwards continue: `dispatch.asm` next, then `parser.asm`, then `render.asm`, then `init.asm` + the unified loop wiring (1.12).

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md] lines 556-607
- PRD risk-rank-1 (input/Esc timing UAT'd separately): [Source: _bmad-output/planning-artifacts/architecture.md] lines 67, 350-353, 1570-1571, 1745
- RI5 (Esc-disambiguation pattern reference): [Source: _bmad-output/planning-artifacts/architecture.md] lines 581-619
- RI6 (input loop top-level): [Source: _bmad-output/planning-artifacts/architecture.md] lines 621-624
- AR12 (single status-message funnel): [Source: _bmad-output/planning-artifacts/epics.md] line 161
- AR15 (single BDOS gateway — input is BIOS-only, no BDOS): [Source: _bmad-output/planning-artifacts/epics.md] line 164
- AR21 (headless coverage scope, Esc/arrow timing carved out): [Source: _bmad-output/planning-artifacts/epics.md] line 173
- AR23 (file structure and routine contracts): [Source: _bmad-output/planning-artifacts/epics.md] line 178
- AR25 (module include order — `init -> input -> statusln -> gapbuf`): [Source: _bmad-output/planning-artifacts/epics.md] line 180, [Source: _bmad-output/planning-artifacts/architecture.md] lines 1280-1316
- V1 (synthesised arrow keycodes 0x80-0x83): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1646-1652
- NFR2 (sustained typing): [Source: _bmad-output/planning-artifacts/epics.md] line 108
- NFR4 (Esc disambiguation budget 1-2 ticks ≈ 40 ms): [Source: _bmad-output/planning-artifacts/epics.md] line 110
- Module dependency graph (input -> dispatch chain): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1404-1432
- External boundary (keyboard via BIOS_CONIN / BIOS_CONINST + tick): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1457-1462
- Data-flow keystroke lifecycle: [Source: _bmad-output/planning-artifacts/architecture.md] lines 1466-1502
- Implementation sequence (input is step 6, after gap buffer): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1557-1577
- inc/bios.inc reader contract for BIOS_TICK_ADDR (DI/EI + unsigned wrap): [Source: inc/bios.inc] lines 51-65
- inc/bios.inc BIOS_CONIN / BIOS_CONINST docstrings: [Source: inc/bios.inc] lines 33-34
- inc/equates.inc ESC_TIMEOUT_TICKS: [Source: inc/equates.inc] line 50
- inc/modes.inc KEY_ARROW_* equates: [Source: inc/modes.inc] lines 33-42
- inc/vt52.inc VT52_ESC: [Source: inc/vt52.inc] line 23
- inc/state.inc small-state block (where input_held_byte / input_held_flag append): [Source: inc/state.inc] lines 43-57
- inc/state.inc NFR10 ASSERT (yank_end <= 0xD800): [Source: inc/state.inc] line 121
- src/vibe.asm current INCLUDE order + input_loop stub: [Source: src/vibe.asm] lines 25-78
- src/gapbuf.asm header-block prior art: [Source: src/gapbuf.asm] lines 1-34
- src/statusln.asm message-funnel prior art (AR12): [Source: src/statusln.asm] lines 1-45
- Smoke-test pattern (statusln_smoke.asm — INCLUDE production source + local input_loop stub): [Source: test/smoke/statusln_smoke.asm] lines 39-225
- Test naming convention TH2 (input_*.asm would land in test/cases if needed): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1041-1054
- Test fixture exit pattern (BDOS function 0 / 9 carve-out): [Source: test/inc/test_epilogue.inc] lines 24-37
- Story 1.7 prior story (gap-buffer module + AR15 grep prior art for AC9): [Source: _bmad-output/implementation-artifacts/1-7-gap-buffer-primitives-headless-tests.md]
- Story 1.5 prior story (input_loop stub origin + statusln smoke pattern): [Source: _bmad-output/implementation-artifacts/1-5-status-line-module-with-single-message-funnel.md]
- Story 1.4 prior story (BIOS_TICK_ADDR placeholder, W1 deferred to 1.12): [Source: _bmad-output/implementation-artifacts/1-4-bios-bdos-shims-with-bdos-call-macro.md]
- Story 1.12 (downstream consumer — hardware bring-up + real input_loop body): [Source: _bmad-output/planning-artifacts/epics.md] lines 781-846
- Z80 DI / EI reference: standard Zilog instruction set; encoded as `0xF3` (DI) and `0xFB` (EI)
- Z80 SBC HL, DE reference: standard Zilog instruction set; encoded as `0xED 0x52`; reads CF, must be cleared via `OR A` before use

## Dev Agent Record

### Agent Model Used

claude-opus-4-7 (Anthropic Claude Opus 4.7, 1M context)

### Debug Log References

**Build determinism (AC12) — `make clean && make` run twice (post-review):**
- Run 1 SHA: `37a2c835c08ddcbb76fc66b6b4ac1fce4ddfe017845bb5d059c68d25a3dd0f6f  vibe.com`
- Run 2 SHA: `37a2c835c08ddcbb76fc66b6b4ac1fce4ddfe017845bb5d059c68d25a3dd0f6f  vibe.com`
- Match → byte-deterministic rebuild (NFR18 ✅).
- Pre-review post-1.8 SHA was `cbb3a63cb487c9fe8f35e77d8f460fadbeec1aee335d12c7fed0272a62b25dd2` — differs from the post-review SHA because review patches F2/F3/F4 added the final `BIOS_CONINST` poll after `DJNZ`, the `BC`-wider `Trashes:` doc, and the `ASSERT ESC_TIMEOUT_TICKS > 0` in equates.inc.

**Pre-Story-1.8 baseline SHA (via `git stash` of working tree, fresh build):**
- `d80e950c9e28a02e1df921622b2ed257da9f848263515dbe50b6b8a7ca97f62c  vibe.com`
- Differs from post-1.8 SHA → AC12 second clause holds (deliberate layout shift from +2 state bytes + input.asm body).

**AR15 grep (AC9):**
```
$ grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY|BDOS_CALL' src/input.asm
$ echo $?
1
```
Zero matches (exit 1 = no lines selected). Input is BIOS-only.

**Headless test suite (AC13) — `make -C test test`:**
```
  pass     gapbuf_delete-at-bof
  pass     gapbuf_delete-mid
  pass     gapbuf_insert-empty
  pass     gapbuf_insert-fills-buffer
  pass     gapbuf_move-roundtrip
  pass     gapbuf_random-ops
  fail     harness_fail  (rc=0, output: FAIL E1 C0)
  pass     harness_pass

  7 pass, 1 fail
```
The deliberate `harness_fail` is the only fail; every `gapbuf_*` test still passes (state.inc layout shifted +2 bytes but tests use symbols, not raw addresses — invariant-by-construction).

NOTE: AC13's quoted "6-pass / 1-fail baseline from Story 1.7's debug log" is stale — Story 1.7's review added a 6th gapbuf test (`gapbuf_delete-mid`) post-spec, so the actual current baseline is 7 pass / 1 fail. The semantic AC13 invariant ("every `gapbuf_*` still passes; only fail is the deliberate `harness_fail`") holds.

### Completion Notes List

- Implementation followed Tasks 1-10 verbatim. Task 11 (optional `test/smoke/input_smoke.asm`) was skipped per the story's explicit guidance (AC14: "may be added... is not required" / Task 11: "Skipping it is fine — Story 1.12's hardware bring-up is the canonical UAT gate"). UAT for Esc/arrow timing is deferred to Story 1.12 as designed.
- One micro-edit during implementation: the original module-header docstring spelled `BDOS_CALL` literally inside its comments, which tripped AC9's grep. Reworded to mirror `src/gapbuf.asm`'s phrasing ("the BDOS macro" / "the BDOS-call macro") so the grep returns zero matches without losing the AR15 commentary.
- Held-byte queue ordering: byte stored before flag is set (matches the discipline called out in Dev Notes / Task 5 — interrupt-safe even though today's MicroBeast ISR doesn't recurse into `input_get_key`).
- `synthesize_arrow_key` hit paths each end with `OR A; RET` to deterministically clear CF (Z80 quirk: `LD A, imm` does not modify flags; the caller's `RET NC` would otherwise mis-branch on stale CF).
- `tick_wait_one` reads `BIOS_TICK_ADDR` under DI/EI per the bios.inc reader contract; compares deltas via `OR A; SBC HL, DE` and exits on any nonzero delta (wrap-safe vs the 0xFFFF→0x0000 boundary every ~21.8 minutes).
- AR25 INCLUDE order in `src/vibe.asm`: `RET stub → INCLUDE input.asm → INCLUDE statusln.asm → INCLUDE gapbuf.asm → input_loop stub → INCLUDE state.inc`. state.inc remains the last include (positional anchor for `static_data_base EQU $`).
- The `;; --- Input-loop abort target ---` comment block was retargeted from "Story 1.8 owns" to "Story 1.12 owns" per Task 8 / Dev Notes — the Story 1.5 prediction was stale (1.8 lands `input_get_key` only; the unified loop body needs `dispatch_key` (1.9) + `render_diff` (1.11) wired in 1.12).
- `state.inc` Public-block header updated to enumerate `input_held_byte` and `input_held_flag` under "Small state".

### File List

**Created:**
- `src/input.asm` — input layer module (`input_get_key` + `synthesize_arrow_key` + `tick_wait_one`).

**Modified:**
- `inc/state.inc` — appended `input_held_byte` and `input_held_flag` to the small-state block (post-`pending_motion_prefix`); updated header `Public:` enumeration.
- `src/vibe.asm` — inserted `INCLUDE "input.asm"` between the `RET` stub and `INCLUDE "statusln.asm"` (AR25 order); updated header `Public:` ownership note + `Dependencies:` line; rewrote the `;; --- Input-loop abort target ---` comment block to point at Story 1.12 as the owner.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — story status `ready-for-dev → in-progress → review`; `last_updated` reflects state.

### Review Findings

Code review on 2026-05-10 (Blind Hunter + Edge Case Hunter + Acceptance Auditor). All 14 ACs PASS in code-shape (UAT-deferred ACs unchanged); ~17 noise findings dismissed. Items below.

- [x] [Review][Defer] `input_held_flag` / `input_held_byte` uninitialised at boot — first-ever `input_get_key` returns garbage if the RAM at the EQU'd addresses is non-zero on warm boot. Spec defers init to Story 1.12, but `input_get_key` is callable today (Story 1.9 dispatch is the next consumer; the optional AC14 smoke also exercises). (Sources: Blind Hunter + Edge Case Hunter.) — deferred, can't do any sort of UAT until end of epic 1 anyway, so the gap closes naturally when Story 1.12's init lands.
- [x] [Review][Patch] `DJNZ .esc_poll` discards a follow-up byte that arrives during the very last tick window [src/input.asm:86-89] — fixed: inserted `CALL BIOS_CONINST; OR A; JR NZ, .have_followup` between the `DJNZ` and the bare-Esc return so a follow-up landing in the BIOS ring during the very last tick is recognised as a legit arrow-suffix instead of leaking into the next `input_get_key` call as a fresh keystroke. (Source: Blind Hunter.)
- [x] [Review][Patch] `C` is missing from `input_get_key`'s `Trashes:` line [src/input.asm:36-41] — fixed: widened the routine's `Trashes:` line to `A, BC, DE, HL, F (C via BIOS_CONIN/CONINST — see header)` and updated the module-level register-conventions block to spell out the worst-case `BC` clobber across BIOS routines plus an `IX/IY` caller-saved note. Latent footgun for Story 1.9 dispatch / 1.12 init now closed at the contract. (Sources: Blind Hunter + Edge Case Hunter.)
- [x] [Review][Patch] No `ASSERT ESC_TIMEOUT_TICKS > 0` in `inc/equates.inc` [inc/equates.inc:50] — fixed: added a build-time `ASSERT ESC_TIMEOUT_TICKS > 0` immediately after the `EQU 2` line plus a comment that explains the `LD B, 0 + DJNZ` 256-iteration trap so anyone tempted to set the knob to zero gets a build-time error instead. (Sources: Blind Hunter + Edge Case Hunter.)
- [x] [Review][Patch] AC13 baseline is stale [_bmad-output/implementation-artifacts/1-8-input-layer-with-esc-arrow-disambiguation.md AC13 + Testing requirements item 4] — fixed: AC13 BDD text and Testing requirements item 4 both updated to "7 pass / 1 fail" with a note that Story 1.7's review added `gapbuf_delete-mid` so the live baseline is one above Story 1.7's debug log. (Source: Acceptance Auditor.)
- [x] [Review][Defer] Queued-Esc bypasses Esc disambiguation (Esc-Esc-Arrow loses arrow synthesis) [src/input.asm:64-72] — when the user types `Esc Esc <arrow-suffix>`, the second Esc is unrecognised and gets queued; the next call pops it via the held-byte fast path which `RET`s without re-entering `.no_held` Esc-comparison, so the arrow letter on the call after that is read as a plain ASCII byte. Real-keyboard double-Esc is rare in vi (and typically intentional "assert normal mode"); fixing requires re-entering disambiguation from the queue path which is a meaningful redesign. Deferred — design accepts current queue semantics. (Sources: Blind Hunter + Edge Case Hunter.) — deferred, inherent to queue design; revisit only if hardware UAT shows it surfacing.
- [x] [Review][Defer] `tick_wait_one` hangs forever if the BIOS ISR isn't ticking the counter [src/input.asm:167-178] — `BIOS_TICK_ADDR` is a W1 placeholder (`0xFA00`); if the address is wrong or the ISR isn't armed, a bare-Esc keypress spins forever with no escape. Documented in `inc/bios.inc:51-65` as a Story 1.12 hardware bring-up concern; not the input layer's job to hedge. (Source: Edge Case Hunter.) — deferred to Story 1.12 BIOS confirmation.
- [x] [Review][Defer] `tick_wait_one` issues unconditional `EI`, clobbering caller's `DI` [src/input.asm:167-178] — no current caller runs with interrupts disabled; Story 1.12 init is the natural first context where this matters. Cleaner fix is the IFF-preservation pattern (`LD A, I; JP PE/PO; PUSH AF / DI / ... / POP AF / ret-with-IFF-restore`) folded into a project-wide convention when 1.12 lands. (Sources: Blind Hunter + Edge Case Hunter.) — deferred to Story 1.12; Story 1.8 has no caller that runs with DI.

## Change Log

| Date | Description |
|---|---|
| 2026-05-10 | Story 1.8 implemented: `src/input.asm` with `input_get_key` (Esc/arrow disambiguation per RI5, held-byte queue per AC6), `synthesize_arrow_key` helper, `tick_wait_one` (DI/EI-bracketed wrap-safe 50 Hz tick wait); `inc/state.inc` gains `input_held_byte` + `input_held_flag`; `src/vibe.asm` INCLUDEs the new module per AR25 and the input-loop comment block is retargeted to Story 1.12. Build determinism verified (matching SHA across two `make clean && make` rebuilds); pre/post-1.8 SHAs differ as expected. AR15 grep returns zero matches. Test suite: 7 pass / 1 fail (deliberate `harness_fail`); every `gapbuf_*` still passes. Status → review. |
| 2026-05-10 | Code review applied 4 patches: (1) `DJNZ .esc_poll` now does a final `BIOS_CONINST` poll after the last tick wait so a follow-up arriving in the very last tick window is recognised as an arrow rather than leaking into the next `input_get_key` call (AC5 boundary fix); (2) `input_get_key`'s `Trashes:` widened to `A, BC, DE, HL, F` with a register-conventions note that BIOS_CONIN/CONINST are not bound by a Z80 calling convention so callers must assume worst-case `BC` clobber and treat `IX`/`IY` as caller-saved; (3) `inc/equates.inc` gains `ASSERT ESC_TIMEOUT_TICKS > 0` to guard the `LD B, 0 + DJNZ` 256-iteration trap; (4) AC13 + Testing-requirements text updated from "6 pass / 1 fail" to "7 pass / 1 fail" (Story 1.7's review added `gapbuf_delete-mid`). Four items deferred (uninit `input_held_*` until Story 1.12 init; Esc-Esc-Arrow queue bypass; `tick_wait_one` ISR-not-armed hang; `tick_wait_one` unconditional `EI`). Re-built clean, deterministic SHA `37a2c835c08ddcbb76fc66b6b4ac1fce4ddfe017845bb5d059c68d25a3dd0f6f` across two consecutive `make clean && make` runs. Tests still 7 pass / 1 fail. AR15 grep still zero. Status → done. |
