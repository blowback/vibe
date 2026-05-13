# Story 1.12: Init/teardown + on-hardware smoke test

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want a working `vibe.com` that I can SLIDE-push and run on real hardware, displaying an empty buffer with a status line, switching modes via `Esc`, refusing unbound keys, redrawing on `Ctrl-L`, and exiting cleanly via a temporary debug-quit key,
so that the Epic-1 foundation layer is end-to-end validated on the only platform that matters (NFR5 preliminary, NFR7 UAT), the AR25 INCLUDE chain is closed by a real `init.asm` + main-loop body, and Epic 2's feature work begins against a known-good base.

## Acceptance Criteria

1. **`src/init.asm` module header per AR23.**
   **Given** `src/init.asm` module header
   **When** I inspect it
   **Then** it documents `Public: init_cold_start, init_teardown`
   **And** `State owned (read/write): (none — init.asm performs a one-shot zero-init of the whole state.inc block but does not OWN any field across the editor's lifetime; ownership stays with the module that authored each field in Stories 1.3 / 1.5 / 1.7 / 1.8 / 1.10 / 1.11)`
   **And** State `read-only`: `mode_byte` (read in cold-start to flag the post-init mode for status_set_message; written exactly once via the canonical `enter_normal_mode`-equivalent path), `DEFAULT_FCB` at 0x005C (read for FCB-presence stub-parse — filename payload IGNORED in this story per the Story 2.3 deferral; see AC7)
   **And** register conventions across public entry points (`init_cold_start` falls through to `input_loop` and never RETs from a caller's perspective; `init_teardown` does not RET on a real CP/M host — it warm-boots via `BDOS_CALL BDOS_EXIT`; defensive RET retained per the existing `mode_debug_quit` precedent for NFR5)
   **And** dependencies on `inc/equates.inc`, `inc/state.inc`, `inc/bios.inc`, `inc/bdos.inc`, `inc/modes.inc`, `inc/vt52.inc` (header symbols only; no functional dependencies on the include headers); `src/statusln.asm` (`status_set_message`, `msg_mode_normal` — Story 1.5 / 1.9), `src/gapbuf.asm` (`gapbuf_init` — Story 1.7), `src/render.asm` (`render_init`, `render_full` — Story 1.11), and `src/vibe.asm` (`input_loop` — this story replaces its body).
   **And** the header documents the AR13 enforcement: "`init.asm` does NOT call `BIOS_CONOUT`. The Story-1.11-retired carve-out for an init-side initial clear stays retired: `render_init` performs the `ESC J` emit; `init_teardown`'s screen-clear-on-exit also routes through a render entry — see AC3."
   **And** the header documents the AR14 enforcement: "`init.asm` does NOT call `gapbuf_insert`, `gapbuf_delete`, or `gapbuf_move_gap`. The only gap-buffer entry it touches is `gapbuf_init` (idempotent reset to the SR2 empty-buffer state)."
   **And** the header documents the AR15 enforcement: "`init.asm`'s sole BDOS use site is `BDOS_CALL BDOS_EXIT` inside `init_teardown`. No raw `CALL 0x0005`; no other BDOS function number is referenced (AR15 + NFR15)."

2. **`init_cold_start` — zero-init, sub-system init, initial render, fall-through to main loop.**
   **Given** `init_cold_start` (`In: (none — entered from src/vibe.asm's ORG 0x0100 + JP init_cold_start with default CP/M state: SP at CCP-pushed warm-boot vector on stack, FCB at 0x005C populated, DMA at 0x0080`)
   **When** invoked at .com entry
   **Then** the routine executes the following stages in order:
     1. **Zero-init the entire static block (resolves Story 1.3 deferral; resolves Story 1.8 deferral).** Fill bytes from `static_data_base` (inclusive) to `static_end` (exclusive) with 0x00 via the 1-byte-seed LDIR idiom. This zeroes every field declared in `inc/state.inc`: `mode_byte` (0 = `MODE_NORMAL` per `inc/modes.inc:23` — convenient: post-LDIR mode is already NORMAL); `visual_submode`, `buffer_dirty`, `pending_operator`, `yank_kind`, `status_dirty`, `pending_motion_prefix`, `input_held_byte`, `input_held_flag` (all 1-byte); `cursor_offset`, `gap_start`, `gap_end`, `visual_anchor`, `count_accumulator`, `yank_length`, `top_line_offset` (all 2-byte); `status_buffer` (80 B), `search_pattern` (1 + 64 B), `ex_buffer` (1 + 64 B), `filename_buffer` (16 B), `shadow_buffer` (1920 B), `dirty_rows` (3 B), `undo_buffer` (256 B). Total ~2240 bytes. (Note: `shadow_buffer` and `gap_start/gap_end/cursor_offset` are immediately overwritten by `render_init` and `gapbuf_init` in stages 2-3 below; the upfront zero-init is the simplest correct shape — Story 1.3's "Static state has no zero-initialization story" deferral pins `init_cold_start` as the resolution site.)
        - **Boundary protection.** The fill MUST stop at `static_end` — NOT `yank_end`. The yank-register region (`yank_buffer` at `GAP_BUFFER_BASE + GAP_BUFFER_MAX`, 1024 B) is intentionally NOT zero-initialised: SR6's "yank register holds last-yank content across operations" contract leaves the yank pool as scratch RAM at boot (boot residue read on the first paste before any yank is the documented sharp edge). Likewise the gap buffer (`GAP_BUFFER_BASE..GAP_BUFFER_BASE + GAP_BUFFER_MAX`) is NOT zero-init: SR2 says "bytes inside the gap are read-as-undefined and never visible through the two-halves walk"; `gapbuf_init` in stage 2 establishes the SR2 invariant; bytes inside the gap stay garbage and stay invisible.
        - **The compile-time `static_block_size EQU static_end - static_data_base`** computes the LDIR byte count. Both `static_data_base` and `static_end` are EQU-resolved at assembly time per Story 1.3's `inc/state.inc` layout (lines 37 and 100); their difference is a literal sjasmplus-time integer. NO runtime subtraction; the LDIR uses an `LD BC, static_block_size` form.
     2. **`gapbuf_init` (Story 1.7).** Resets `gap_start = GAP_BUFFER_BASE`, `gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX`, `cursor_offset = 0`. Idempotent against the just-zeroed state but the call MUST happen — `gapbuf_init` is the documented SR2-establishing entry point (architecture lines 1290-1292, AR14); routing through it makes the dependency explicit and survives any future state.inc layout shift that breaks the "zeros happen to satisfy SR2" coincidence.
     3. **`render_init` (Story 1.11).** Emits one `ESC J` (the post-1.11 only `BIOS_CONOUT` site in init's responsibility chain), fills `shadow_buffer` with 0x20, zeroes `dirty_rows`, zeroes `top_line_offset` (idempotent), and emits the initial cursor-home `ESC Y 0x20 0x20`. Post-call: screen is cleared, shadow is fully reconciled with the empty editing area, cursor is at row 0 / col 0.
     4. **Initial status banner.** Invoke `status_set_message` with `HL = msg_mode_normal`, `A = 0` (non-error code arg). `msg_mode_normal` is the empty string per Story 1.9 (`src/statusln.asm:170`) — `status_set_message` hits the null terminator on byte 0 and pads the full `STATUS_LINE_WIDTH` with spaces, matching vi's "no banner in normal mode" convention. The call SETS `status_dirty = 1` so the upcoming `render_full` pass picks up the (blank) status row. Rationale for going through `status_set_message` rather than directly writing `status_buffer` / `status_dirty`: AR12's funnel discipline holds even at init time; the cost is one `LD HL, msg_mode_normal / XOR A / CALL status_set_message` (8 bytes) vs the inline-write alternative (~10 bytes) and the inline alternative would create a second WRITE site for `status_buffer` outside `statusln.asm`, breaking AR12.
     5. **`render_full` (Story 1.11).** `render_mark_all_dirty` + `render_diff` — re-emits the empty editing area (24 rows × 80 cols of spaces — only the trailing cursor-reposition emits any bytes since post-init the shadow already matches a 1920-cell all-space target; the status-row emit fires because `status_dirty` was set in stage 4 and the row 23 contents now differ from the pre-emit shadow's all-spaces). Post-call: `dirty_rows` is cleared; cursor is repositioned to row 0 / col 0 (the V2 scroll-adjust resolves cursor_offset=0 → cursor_row=0, cursor_col=0).
     6. **Fall through to `input_loop` (no `RET`).** `init_cold_start`'s last instruction is `JP input_loop` (the symbol in `src/vibe.asm` whose body this story rewrites — see AC9). The fall-through MUST be a `JP`, not a `CALL`: `init_cold_start` consumed its own stack discipline at .com entry (the CCP-pushed warm-boot vector remains on the stack; `init_teardown` invoked later POPs back to it via the `BDOS_CALL BDOS_EXIT` warm-boot — the stack discipline is symmetric with CCP's expectation that the .com either RETs to the warm-boot vector OR exits via BDOS function 0).
   **And** `init_cold_start`'s `Trashes:` declaration covers `A, BC, DE, HL, F` (the LDIR + gapbuf_init + render_init + status_set_message + render_full chain covers every general-purpose register).
   **And** `init_cold_start`'s `Calls:` line lists `gapbuf_init, render_init, status_set_message, render_full` (in invocation order) — every call is a CALL (not a tail-JP) until the final fall-through.

3. **`init_teardown` — clear screen, warm-boot to CCP (AR13-compliant emit).**
   **Given** `init_teardown` (`In: (none — entered from mode_debug_quit, which this story re-points; see AC11)`)
   **When** invoked
   **Then** the routine executes the following stages in order:
     1. **Clear screen + home cursor.** Reuse `render_init` (Story 1.11) for the emit path. `render_init`'s side effects: one `ESC J` (clear), shadow re-seed to 0x20, `dirty_rows = 0`, `top_line_offset = 0`, one `ESC Y 0x20 0x20` (cursor home). The shadow / dirty / top_line_offset writes are inert at teardown (the editor is about to warm-boot — no subsequent render pass will read them). Routing through `render_init` keeps AR13 enforced WITHOUT introducing a second BIOS_CONOUT call site in `init.asm`. The alternative (a new `render_clear_and_home` helper exported by render.asm that emits ONLY the `ESC J` + cursor home without the shadow re-seed) is cleaner but adds a public symbol; the dev MAY choose either implementation. Default: reuse `render_init`.
     2. **Warm-boot to CCP.** `BDOS_CALL BDOS_EXIT` (per AR15; the macro expands to `LD C, BDOS_EXIT (=0) / CALL BDOS_ENTRY / OR A / JP M, bdos_error_funnel`; the `JP M` is dead code on a successful warm-boot but mandatory per the AR15 contract — the macro form is uniform across every BDOS call site in the editor). On a real CP/M host this never returns; control transfers to CCP's warm-boot vector.
     3. **Defensive RET.** A trailing `RET` is retained per the existing `mode_debug_quit` precedent at `src/dispatch.asm:341-343`. The RET is unreachable on every CP/M host the editor supports (real MicroBeast + iz-cpm both honor function 0); it exists to keep the editor out of arbitrary memory if a misconfigured BIOS-during-bring-up lets function 0 fall through. NFR5 priority: never crash into undefined behavior, even on a brittle hardware state.
   **And** `init_teardown`'s `Trashes:` declaration covers `A, BC, DE, HL, F` (render_init + BDOS_CALL clobber).
   **And** `init_teardown`'s `Calls:` line lists `render_init` and `BDOS_ENTRY` (via `BDOS_CALL` macro).

4. **`src/vibe.asm`'s `0x0100` entry replaces the RET stub with `JP init_cold_start`.**
   **Given** `src/vibe.asm`'s current ORG 0x0100 region (lines 38-43 — single `RET` instruction)
   **When** I inspect `src/vibe.asm` after Story 1.12
   **Then** the body at `0x0100` is `JP init_cold_start` (3 bytes, replacing the 1-byte `RET` stub)
   **And** the trailing comment "Replaced by proper init/teardown in Story 1.12" is removed (the story has arrived); replace with a one-line "Entry point: jump to init.asm's cold-start. See src/init.asm."
   **And** the `src/vibe.asm` header `Dependencies:` line gains `src/init.asm (Story 1.12)` alongside the existing entries
   **And** the AR25 comment block above the `INCLUDE "input.asm"` site (currently lines 45-50 documenting "init lands in Story 1.12") is updated to reflect that init.asm now exists and is INCLUDEd above per AR25 (see AC13).

5. **Main input-loop body in `src/vibe.asm` — `input_get_key → dispatch_key → render_diff → repeat`.**
   **Given** `src/vibe.asm`'s current `input_loop:` body (lines 105-108: `BDOS_CALL BDOS_EXIT / RET` — Story 1.5 stub)
   **When** I inspect `src/vibe.asm` after Story 1.12
   **Then** the body is replaced with the real input-loop top-of-frame:
     1. `CALL input_get_key` — Story 1.8 entry; returns A = next 1-byte keycode (ASCII 0x00..0x7F OR `KEY_ARROW_*` 0x80..0x83 OR `VT52_ESC` 0x1B on bare-Esc).
     2. **Mode-table selection.** Read `(mode_byte)`; branch by value to load `HL = dispatch_<mode>` table base and `B = DISPATCH_<MODE>_COUNT`. Save the key (e.g. in `C`) across the mode-byte read because the read clobbers A. Four cases: `MODE_NORMAL` (0), `MODE_INSERT` (1), `MODE_COMMAND` (2), `MODE_VISUAL` (3). Default (any other byte value) falls through to NORMAL — defensive against a corrupted `mode_byte`; NFR5 priority. The selection block is documented as the "per-mode demultiplex" — small, flat, sub-200 T-states worst case.
     3. **Restore A = key for MC4** before `CALL dispatch_key` (the dispatch_key contract is `A = key, HL = mode-table base, B = entry count`).
     4. `CALL dispatch_key` — Story 1.9 entry; transfers control via the RET-to-pushed-address idiom to the matched handler (or per-mode unbound handler). Handler RETs back to the input loop here. `dispatch_key`'s contract documents this control-transfer pattern: from input_loop's perspective, `CALL dispatch_key` is a normal CALL whose called routine just happens to have done a stack-rewrite mid-flight; the post-call cursor is the instruction after the CALL.
     5. `CALL render_diff` — Story 1.11 entry; reconciles the screen with any buffer / status changes the handler made. RI2: render runs after each input-loop iteration; idle = no emission (except the RI4 cursor reposition).
     6. `JP input_loop` — top-of-frame branch. The loop never terminates from inside; the only exit paths are (a) `init_teardown` (via `mode_debug_quit`'s now-real handler — AC11), or (b) `bdos_error_funnel`'s `JP input_loop` (which lands at step 1 above — the abort path re-enters the loop, NFR5 "no crashes; never enters a state requiring a warm reboot for the user to recover" preserved).
   **And** the routine's contract block documents `In: (none — entered by fall-through from init_cold_start; re-entered by bdos_error_funnel's JP input_loop). Out: never returns to caller (no caller — control transfers via init_teardown's BDOS warm-boot OR via re-entry from bdos_error_funnel). Trashes: A, BC, DE, HL, F (transitively via input_get_key + dispatch_key + handler + render_diff). Calls: input_get_key, dispatch_key, render_diff.`
   **And** the body lands AFTER all module INCLUDEs (so all referenced symbols — `input_get_key`, `dispatch_normal/insert/command/visual`, `DISPATCH_*_COUNT`, `dispatch_key`, `render_diff` — are resolved on the first sjasmplus pass; reverse order would force a forward reference but sjasmplus's two-pass model resolves either way). The current `input_loop:` placement at lines 105-108 (between `INCLUDE "parser.asm"` and `INCLUDE "../inc/state.inc"`) is the correct location and the body replacement happens in place.

6. **`mode_debug_quit` re-points at `init_teardown`.**
   **Given** `src/dispatch.asm`'s current `mode_debug_quit` body (lines 341-343: `BDOS_CALL BDOS_EXIT / RET` — Story 1.9 stub that warm-boots WITHOUT the screen-clear)
   **When** I inspect `src/dispatch.asm` after Story 1.12
   **Then** the body is replaced with `JP init_teardown` (3 bytes, tail-JP — init_teardown's BDOS_EXIT chains the warm-boot; init_teardown's defensive RET returns to dispatch_key's caller, then back to input_loop, then back to the loop's top — defensive only, the BDOS_EXIT never returns)
   **And** the routine's contract block is updated: `Calls: init_teardown (tail-JP — handles screen-clear + warm-boot; see src/init.asm)`. `Trashes:` line is unchanged (`A, BC, DE, HL, F` — init_teardown's chain).
   **And** the routine's purpose comment is rewritten from "TEMPORARY exit handler for the Story 1.12 hardware bring-up. Removed when the editor exits via :q / :q! land in Story 2.1" to "TEMPORARY exit handler — bound to Ctrl-Q (0x11) for the Story 1.12 hardware bring-up. Tail-JPs to `init_teardown` (src/init.asm), which clears the screen + warm-boots to CCP. Removed in Story 2.1 when `:q` / `:q!` arrive as the proper vi exit mechanism."
   **And** `src/dispatch.asm`'s header `Dependencies:` line gains `src/init.asm (Story 1.12 — init_teardown, for mode_debug_quit's screen-clear-on-exit path)`.
   **And** the `dispatch_normal` table entry at `0x11` (line 449) is unchanged in form — `DEFB 0x11 : DEFW mode_debug_quit` — only `mode_debug_quit`'s body is rewritten.

7. **Default FCB stub-parse — filename ignored.**
   **Given** the default FCB at `DEFAULT_FCB = 0x005C` (per `inc/bios.inc:51`), which CP/M's CCP populates with the filename argument(s) from the command line before transferring control to the .com at `0x0100`
   **When** `init_cold_start` runs
   **Then** the FCB at 0x005C IS NOT parsed for content in this story — it's read-zero-or-more bytes and the result is discarded (the buffer always starts empty per the story spec; Story 2.3 lands the real FCB → `filename_buffer` parse + `fileio_load` integration)
   **And** the implementation MAY skip the FCB read entirely — there is no AC requiring an explicit `LD A, (DEFAULT_FCB)` or `LD HL, DEFAULT_FCB` reference; the contract is "the editor launches with an empty buffer regardless of whether the user typed `vibe` or `vibe foo.fs` at the CCP prompt"
   **And** `filename_buffer` (16 bytes at the address declared in `inc/state.inc:91`) is left zero-init from AC2 stage 1 (the LDIR fill covers it). On a future `render_diff` pass where the status row is rebuilt with the filename component (Story 2.3 wiring), the empty `filename_buffer` (first byte = 0) renders as "[no name]" via the AR16 message-string convention — the dev MAY add an `msg_no_filename` string for early use, but it is NOT required by this story (the Story-1.9 `msg_mode_normal` empty-string banner is the only status content this story emits at cold-start; the filename component is Story 2.3 territory).
   **And** the dev-notes Implementation section documents this deliberate skip — the FCB is at a well-known address but its parse is explicitly deferred. A future reader of `init_cold_start` who searches for "FCB" or "0x005C" needs to find an explanation, not silence.

8. **W1 — BIOS jump-table addresses confirmed against real MicroBeast BIOS.**
   **Given** the Watchpoint W1 from Story 1.4 (`inc/bios.inc:24-26`): `BIOS_CONIN = 0xFA06`, `BIOS_CONINST = 0xFA09`, `BIOS_CONOUT = 0xFA0C`, `BIOS_TICK_ADDR = 0xFA00` — all documented as placeholders to be confirmed at hardware bring-up
   **When** I run the editor on real MicroBeast hardware
   **Then** the dev physically verifies (via MicroBeast BIOS documentation, ROM disassembly, or empirical probing) the correct addresses of:
     - `CONIN` (blocking byte read from console) — the entry that `input_get_key` polls
     - `CONINST` (nonzero in A iff a byte is ready) — the entry that the Esc tick-window in `input_get_key`'s `.esc_poll` calls
     - `CONOUT` (emit byte in C to console) — the entry that every `render_emit_byte` call site (the sole BIOS_CONOUT site post-Story 1.11) writes through
     - `BIOS_TICK_ADDR` (free-running 16-bit tick counter at 50 Hz, BIOS-ISR-maintained) — the address `input.asm`'s `tick_wait_one` reads via `LD HL, (BIOS_TICK_ADDR)` per the inc/bios.inc reader contract at lines 63-75
   **And** if the placeholder addresses are wrong, `inc/bios.inc` is updated with the confirmed values — capture the before/after deltas in dev-notes Debug Log References
   **And** if the placeholder addresses are RIGHT (unlikely but possible — CP/M 2.2 BIOS layouts are largely conventional), a one-line confirmation note replaces the "placeholder per architecture lines 1097-1099" hedge in `inc/bios.inc:24-32`; the IFNDEF guard on `BIOS_CONOUT` (added by Story 1.11 for test-side override) is unchanged.
   **And** the Story 1.4 deferral entry on `BIOS_TICK_ADDR` overlapping the BIOS jump-table neighborhood (`deferred-work.md` line 27) is marked resolved with the confirmed BIOS layout. If the typical CP/M 2.2 BIOS layout (17 × 3-byte jumps from the base = 51 bytes) places `BIOS_TICK_ADDR` inside the jump-table on real hardware, the address is relocated to a non-conflicting BIOS-managed counter address (the architecture's intent is "a BIOS-managed 50 Hz tick counter at a fixed address," not the literal 0xFA00 — the literal is the Story-1.4 placeholder).
   **And** if the real hardware does NOT expose a BIOS-managed tick counter at any stable address (a configuration that breaks `input.asm`'s `tick_wait_one`), this is surfaced as a Story 1.12 blocker — the Esc/arrow disambig design (RI5 / NFR4) depends on the counter. The dev-notes Completion Notes section captures the resolution path (likely: hardware exposes the tick; if not, the editor's bring-up surfaces a real-hardware deviation from the architecture's assumed BIOS shape and the editor's input layer needs a redesign before Epic 2 motions land).

9. **AR25 INCLUDE order — `src/init.asm` first in `src/vibe.asm`.**
   **Given** AR25's INCLUDE order (`equates → bios → bdos → vt52 → modes → state → ORG 0x0100 → init → input → statusln → gapbuf → render → dispatch → parser → motions → edits → visual → search → exline → fileio → undo`)
   **When** I inspect `src/vibe.asm` after Story 1.12
   **Then** `INCLUDE "init.asm"` lands AS THE FIRST source-code INCLUDE after `ORG 0x0100` — BEFORE `INCLUDE "input.asm"` (Story 1.8) which is currently the first
   **And** the AR25 comment block above the new `INCLUDE "init.asm"` site documents: "AR25 order: ORG 0x0100 -> init -> input -> statusln -> gapbuf -> render -> dispatch -> parser. init.asm owns the cold-start sequence (zero-init -> gapbuf_init -> render_init -> initial status banner -> render_full -> fall-through to input_loop) and the teardown sequence (render_init for screen-clear + warm-boot via BDOS function 0)."
   **And** the AR25 comment block above the `INCLUDE "input.asm"` site (currently lines 45-50 noting "init lands in Story 1.12 ... input is the first module-include after the RET stub") is updated to reflect the new layout: init.asm is now the first INCLUDE after `0x0100`; input.asm slots in second.
   **And** the `src/vibe.asm` header `Dependencies:` line (lines 21-25) gains `src/init.asm (Story 1.12)` AS THE FIRST listed src/ dependency (matching the AR25 order).
   **And** sjasmplus 1.23.0 resolves `init_cold_start`'s forward references (`gapbuf_init`, `render_init`, `status_set_message`, `msg_mode_normal`, `render_full`, `input_loop`) on its second pass: init.asm INCLUDEs before all the source files that DEFINE those symbols, so first-pass tolerates undefined; second-pass resolves. The `JP init_cold_start` at `0x0100` is a backward reference at second pass (init.asm INCLUDEs immediately after `ORG 0x0100` — the label `init_cold_start` is defined within ~3 instructions of the `JP`).

10. **AR13 — `src/init.asm` has zero `BIOS_CONOUT` references.**
    **Given** the architecture rule AR13: only `render.asm` calls `BIOS_CONOUT`
    **When** I run `grep -nE 'BIOS_CONOUT' src/init.asm` from project root
    **Then** zero matches (the routine never emits screen bytes directly; the screen-clear at cold-start and teardown both delegate to `render_init`)
    **And** `grep -nE 'BIOS_CONOUT' src/*.asm | grep -v 'render.asm'` returns zero matches across the entire production code base (sweep extension of Story 1.11's AC10 to cover init.asm too).

11. **AR14 — `src/init.asm` does not mutate the gap buffer via the mutating primitives.**
    **Given** the architecture rule AR14: only `gapbuf.asm` mutates the gap buffer via `gapbuf_insert/delete/move_gap`
    **When** I run `grep -nE 'gapbuf_(insert|delete|move_gap|load)' src/init.asm`
    **Then** zero matches (init.asm calls `gapbuf_init` to ESTABLISH the SR2 invariant; the mutating primitives are out of scope for cold-start because the buffer starts empty)
    **And** `gapbuf_init` IS referenced from init.asm (one CALL site; AC2 stage 2). `gapbuf_init` is documented as an INITIALISATION entry, not a mutation entry — the AC14 grep is deliberately scoped to the mutating primitives.

12. **AR15 — `src/init.asm`'s only BDOS use is `BDOS_CALL BDOS_EXIT` in `init_teardown`.**
    **Given** the architecture rule AR15: every BDOS call via `BDOS_CALL` macro; raw `CALL 0x0005` forbidden
    **When** I run `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY|BDOS_CALL' src/init.asm`
    **Then** the ONLY match is `BDOS_CALL BDOS_EXIT` inside `init_teardown` (one line; the macro expansion satisfies AR15)
    **And** no raw `CALL 0x0005` / `CALL BDOS_ENTRY` lines anywhere in `init.asm` (the macro discipline holds at every BDOS use site, even the single one).

13. **NFR9 — `make sizes` is wired for real per-section size reporting.**
    **Given** the project Makefile's current `sizes:` target (line 61-62: a stub that echoes a deferred-message)
    **When** I run `make sizes` from project root after this story
    **Then** the target reports the production code-section size as a single number (or a per-module breakdown — implementation choice; the AC pins the single-number contract) measured against the NFR9 ~3 KB code budget. Acceptable shapes:
      - **Single number form (RECOMMENDED for Story 1.12).** Compute `static_data_base - 0x0100` from the sjasmplus listing or symbol output. The result is the bytes of emitted code between the .com entry and the static block — equivalent to "size of all production assembly code in the build". Print as `code_section: <N> bytes (~<N*100/3072>% of NFR9 budget)`. Implementation: post-process `build/vibe.lst` for the highest-address line emitted before `static_data_base` resolves, OR post-process the .sld file (sjasmplus debugger format includes symbol addresses), OR (simplest) ASSERT `static_data_base` is known at assembly time and use `grep` on the listing to extract its value, then subtract 0x0100. Whichever the dev picks, document the parse pipeline in the Makefile rule.
      - **Per-module breakdown (alternative).** Walk the listing's source-file markers (sjasmplus emits `# file <path>` between source switches) and accumulate bytes-per-file. More work; not required.
      - **Total .com size form (FALLBACK).** `wc -c vibe.com` — strictly the binary's size, which includes nothing beyond code in the current build (state.inc is EQU-only, no emit). This is the simplest form and would suffice for the AC; the only loss is the implicit boundary with the (currently empty) static-data-baseline.
    **And** the Makefile's `sizes:` rule documentation block (preceding comment) is updated from "stub until later story wires it" to "per-section size from listing — implements NFR9 audit baseline; see Story 1.12".
    **And** the test runner's `make test` (top-level) is NOT modified — sizes is a separate target.

14. **Hardware UAT smoke — the editor on real MicroBeast.**
    **Given** `make` produces `vibe.com` clean from a clean tree (NFR14 / NFR18 verified by AC18) and the dev SLIDE-pushes the artifact to the MicroBeast
    **When** I launch `vibe` from the CCP prompt
    **Then** the screen clears and the empty 23-row editing area + 80-col-wide status line at row 24 (= 0-indexed row 23, `STATUS_ROW`) are shown
    **And** the cursor is positioned at the top-left (row 0, col 0)
    **And** the status row is blank (vi convention — `msg_mode_normal` is the empty string; `status_set_message`'s null-on-byte-0 path pads the full width with 0x20)
    **And** pressing 'i' transitions to INSERT mode within one render frame: `enter_insert_mode` (Story 1.9 / `src/dispatch.asm:235-241`) sets `mode_byte = MODE_INSERT` and calls `status_set_message msg_mode_insert`; the next `render_diff` emits the "-- insert --" banner
    **And** in INSERT mode any subsequent printable keystroke routes through `unbound_insert` (the Story 1.9 stub at `src/dispatch.asm:406-407`, a silent RET) — NO buffer mutation, NO screen corruption, NO mode confusion. (Note: Story 2.8 replaces `unbound_insert` with the real literal-byte insert; for 1.12 the unbound stub is the documented behavior — typed bytes vanish into the no-op handler.)
    **And** in INSERT mode, pressing Esc transitions back to NORMAL within `ESC_TIMEOUT_TICKS` (2 ticks = ~40 ms): `input_get_key`'s `.esc_poll` waits for a follow-up byte; absent one, returns `VT52_ESC` (0x1B); `dispatch_insert`'s 0x1B entry routes to `enter_normal_mode` (Story 1.9); `mode_byte = MODE_NORMAL`; status row clears (msg_mode_normal empty → all spaces)
    **And** in NORMAL mode, pressing an unbound key (e.g. '!', 'q', 'z', 'x') routes through `unbound_normal` (`src/dispatch.asm:365-369`) which surfaces "unbound key" in the status row; `mode_byte` stays NORMAL; `cursor_offset` stays 0; `count_accumulator` / `pending_operator` / `pending_motion_prefix` stay 0 (the FR50 contract — leaves editor state unchanged on unbound input)
    **And** pressing Ctrl-L (0x0C) routes through `mode_full_refresh_stub` (the Story-1.11-replaced body that tail-JPs to `render_full`); the screen re-draws from buffer state without artefacts
    **And** in NORMAL mode, pressing ':' transitions to MODE_COMMAND (banner "-- command --"); 'v' → MODE_VISUAL ("-- visual --"); '/' shows "not yet implemented" (Story 3.1 stub, Story 1.9). Esc returns to NORMAL from each
    **And** pressing the temporary debug-quit key (Ctrl-Q, 0x11 — bound in `dispatch_normal` line 449-450) routes through `mode_debug_quit` → `init_teardown` → screen clears + cursor home + warm-boot to CCP. The terminal is left in a clean state (cursor visible, no stuck attributes, CCP prompt re-appears at column 0)
    **And** under sustained typing of arbitrary keys for 30 seconds (the NFR5 preliminary hardware-smoke test), there are no crashes, no terminal corruption, no stuck cursor, no mode confusion, and Ctrl-L at any point restores a clean screen
    **And** the UAT checklist outcomes are captured in Debug Log References (per-AC pass/fail notes; specific failure modes recorded so a regression can be reproduced).

15. **NFR3 / NFR4 — Esc/arrow timing on real hardware.**
    **Given** `input_get_key`'s 50 Hz tick-window Esc/arrow disambig (Story 1.8, RI5)
    **When** I exercise Esc/arrow patterns on real MicroBeast hardware
    **Then** bare-Esc keypresses (Esc pressed in isolation, no arrow follow-up) consistently route to `MODE_NORMAL` transitions within the 1-2 tick window (20-40 ms target per NFR4) — the `tick_wait_one` spin-loop in `input.asm` reads `BIOS_TICK_ADDR` and unblocks on a single-tick delta
    **And** VT52 arrow-key sequences (terminal emits `ESC A` / `ESC B` / `ESC C` / `ESC D` on the four arrow keys) are recognised: `synthesize_arrow_key` returns `KEY_ARROW_*` (0x80..0x83); the arrow keycodes route through `dispatch_normal` / `dispatch_visual` / `dispatch_insert` per-mode tables. For Story 1.12 NORMAL mode has NO arrow entries (arrows are unbound — FR50 fires; "unbound key" surfaces in the status row) — this is the documented behavior; Story 2.5 lands the h/j/k/l motions and arrow handlers (FR18, FR20)
    **And** if bare-Esc consistently times out longer than ~40 ms on hardware, the dev investigates: (a) `BIOS_TICK_ADDR` value (was Story 1.4 / W1 placeholder confirmed in AC8?); (b) `ESC_TIMEOUT_TICKS = 2` (per `inc/equates.inc:50`) is the right window or needs tuning; (c) `tick_wait_one`'s DI/EI bracket interacting with the BIOS ISR. Resolution paths logged in dev-notes.

16. **Headless tests — at least one new test for the init flow.**
    **Given** the AR21 headless coverage scope (gap buffer, command parser, search, undo, file I/O, render math — explicitly EXCLUDES "end-to-end editing journeys", which is what init's UAT covers) and the architecture's deliberate non-coverage of init-time UAT on the iz-cpm harness
    **When** I run `make -C test test` from project root after Story 1.12
    **Then** the live baseline is at least preserved at 22 pass / 1 fail (the Story 1.11 baseline)
    **And** at least ONE new headless test exercises `init_cold_start`'s state-shape contract — e.g. `test/cases/init_cold_start-state-shape.asm`. The test installs the BIOS_CONOUT capture override (per Story 1.11's mechanism: `DEFINE BIOS_CONOUT_OVERRIDE` + `BIOS_CONOUT EQU test_bios_conout` before `INCLUDE "../../inc/bios.inc"`), pre-poisons every state.inc field with a non-zero sentinel (e.g. 0xAA), calls `init_cold_start` (returning via a one-instruction RET trampoline since `init_cold_start` ends in `JP input_loop`; the test's `input_loop` is the standard `test_input_loop_stub.inc` — `BDOS_CALL BDOS_EXIT` — which warm-boots before the test can verify, so the test pattern must be: install a custom `input_loop` body that JPs to `test_pass` or `test_fail` based on post-init state inspection). Verify:
      - `mode_byte == MODE_NORMAL` (= 0)
      - `cursor_offset == 0` (16-bit zero)
      - `gap_start == GAP_BUFFER_BASE` (set by gapbuf_init)
      - `gap_end == GAP_BUFFER_BASE + GAP_BUFFER_MAX` (set by gapbuf_init)
      - `top_line_offset == 0`
      - `dirty_rows[0..2] == 0`
      - `shadow_buffer[0] == 0x20` (render_init's space-fill seed)
      - `status_dirty == 0` post-`render_full` (set by the `msg_mode_normal` `status_set_message` call in stage 5; cleared by `render_full` → `render_diff`'s status-row emit in stage 6, which clears `status_dirty` after reconciling row 23 — see Story 1.11 AC4 step 3)
      - `input_held_flag == 0` (resolves Story 1.8 deferral: the input layer's queue flag is now zero-init at boot)
      - `pending_operator / pending_motion_prefix / count_accumulator all == 0` (resolves Story 1.10 deferral surface: parser state is clean at boot; the mode-transition-clears-parser-state question is still open per AC22)
    **And** the test's sentinel codes are documented at the file head (e.g. 0xE1 = mode_byte not NORMAL; 0xE2 = cursor_offset not 0; etc.).
    **And** the post-1.12 live baseline becomes 23 pass / 1 fail (22 pre-1.12 passes + 1 new `init_cold_start-state-shape` + the deliberate `harness_fail`). If the dev writes additional init tests (init_teardown's screen-clear emit sequence, FCB-skip behavior, etc.), the count rises further.
    **And** the existing dispatch / parser / render tests STILL PASS — Story 1.12 changes the production-code main-loop body and the dispatch.asm `mode_debug_quit` body but leaves every test scaffold's INCLUDE chain unbroken. The Story 1.11 patch that added `INCLUDE "src/render.asm"` to the dispatch_* and parser_* tests already covers the transitive resolution of any new symbols init.asm introduces (init.asm exports `init_cold_start` and `init_teardown` only; nothing in the existing test suite references either symbol, so the harness picks up the new module's bytes via the AR25 INCLUDE-order propagation but does not need any test-side fixup).

17. **Calling convention (MC1, MC4).**
    **Given** the calling convention (MC1 caller-saved everywhere; MC4 handler signature)
    **When** I inspect `init_cold_start` and `init_teardown`
    **Then** both routines are documented per AR23: `In:` / `Out:` / `Trashes:` / `Calls:` four-line contract blocks
    **And** `init_cold_start` is a `JP input_loop`-terminating routine (no RET — falls through to the main loop; the contract block documents this explicitly so a future reader doesn't try to `CALL init_cold_start` from another module — there's no caller to return to)
    **And** `init_teardown` is a `RET`-terminating routine (the RET is dead on a real CP/M host; the BDOS_CALL BDOS_EXIT warm-boots before the RET fires — but the AR23 contract still requires the RET to be documented, and the RET serves the defensive NFR5 purpose per AC3 stage 3)
    **And** `init_cold_start`'s `Trashes:` covers `A, BC, DE, HL, F` (the LDIR plus the three sub-system inits plus the status_set_message); `init_teardown`'s `Trashes:` covers `A, BC, DE, HL, F` (render_init plus BDOS_CALL).
    **And** the new main-loop body in `src/vibe.asm`'s `input_loop:` IS the loop top — its contract block documents this as a non-RET-terminating routine (control transfers out only via `init_teardown` OR via the bdos_error_funnel re-entry).

18. **Build-time invariants and AR/NFR enforcement.**
    **Given** the project build invariants
    **When** I run `make` from project root
    **Then** `vibe.com` builds cleanly under sjasmplus 1.23.0 (NFR14)
    **And** two consecutive `make clean && make` runs produce byte-identical `vibe.com` (NFR18) — capture both SHAs in Debug Log References
    **And** the `make sizes` output (AC13) reports the code-section size, captured verbatim in Debug Log References as the NFR9 audit baseline (no enforcement yet — just a number; if the number exceeds ~3 KB this story surfaces it via the natural follow-up "do we redesign for size?" question — but for 1.12 it's a measurement, not a gate)
    **And** `grep -nE 'BIOS_CONOUT' src/*.asm | grep -v 'render.asm'` returns zero matches (AR13)
    **And** `grep -nE 'gapbuf_(insert|delete|move_gap|load)' src/init.asm` returns zero matches (AR14 — note `gapbuf_init` is intentionally NOT in the grep pattern; init.asm DOES call it)
    **And** `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/init.asm` returns zero matches (AR15 — raw BDOS calls forbidden; the macro is allowed)
    **And** `grep -nE 'BDOS_CALL' src/init.asm` returns exactly ONE match: the `BDOS_CALL BDOS_EXIT` line inside `init_teardown` (AC12 — the single AR15 gateway use site).
    **And** `make -C test test` reports at least 23 pass / 1 fail (AC16 — 22 pre-1.12 passes + at least 1 new init-state-shape test; the deliberate `harness_fail` is the only `fail`).

19. **Status row content — vi-faithful empty banner in NORMAL.**
    **Given** AR16's status-message convention (lowercase, no trailing period, under 30 chars) and Story 1.9's `msg_mode_normal` being the empty string (`src/statusln.asm:170`: `msg_mode_normal: DEFB 0`)
    **When** the editor is running and in NORMAL mode
    **Then** the status row is blank (80 spaces — `status_set_message`'s null-on-byte-0 path pads the full width with 0x20)
    **And** this is INTENTIONAL — vi convention is "no banner in normal mode" (architecture line 1170-ish AR16 + Story 1.5 / 1.9 dev-notes). The status row only carries content when there's a message: mode-change banners ("-- insert --", "-- command --", "-- visual --"), unbound-key feedback ("unbound key"), stub feedback ("not yet implemented"), or future fileio errors ("can't open foo")
    **And** the AC4 wording "status line displaying mode (NORMAL)" is interpreted as state-wise: `mode_byte == MODE_NORMAL`; the displayed banner is empty by deliberate design. A future story that adds a filename component (Story 2.3) will populate part of the status row with the filename; the mode component will continue to follow the empty-in-normal convention.

20. **Deferred-work resolutions.**
    **Given** the `deferred-work.md` entries marked for Story 1.12 resolution
    **When** I update `_bmad-output/implementation-artifacts/deferred-work.md` after this story
    **Then** the following entries are explicitly marked resolved with one-line Story-1.12 notes:
      - **Story 1.3 "Static state has no zero-initialization story"** (deferred-work.md line 17) — resolved by `init_cold_start` stage 1 LDIR-fill of `static_data_base..static_end` with 0x00. Notes that gap-buffer and yank-buffer regions stay zero-init-free per SR2 / SR6.
      - **Story 1.4 "BIOS_TICK_ADDR placeholder overlaps the BIOS jump-table"** (line 27) — resolved by AC8's W1 confirmation. If the address moved, the note records the before/after.
      - **Story 1.8 "input_held_flag / input_held_byte uninitialised at boot"** (line 58) — resolved by the centralised zero-init in stage 1; the queue branch in `input_get_key` now reads input_held_flag == 0 at first call, falls through to BIOS_CONIN as the contract intends.
    **And** the following entries are EVALUATED but the resolution may be a documentation update rather than a code change (each is a small policy call the dev makes within this story OR explicitly punts):
      - **Story 1.8 "tick_wait_one issues unconditional EI, clobbering caller's interrupt-disable state"** (line 60-61) — decision call: does `init_cold_start` enter `tick_wait_one`'s callers (via the input layer being polled for the first keystroke)? Yes, the input loop polls `input_get_key` immediately after init falls through. Does `init_cold_start` care about IFF state? On CP/M warm-boot the CCP-passed IFF state is "interrupts enabled" (BIOS ISR for keyboard / timer is running); init does nothing to disable. So `tick_wait_one`'s `DI / read / EI` bracket is a no-op on the IFF state — it disables, reads, re-enables, leaves IFF as it found it. The deferral is benign in Story 1.12's context. Mark "still deferred — pending a future story that legitimately enters tick_wait_one with IFF disabled (e.g. an ISR-driven future story)".
      - **Story 1.10 "Mode transitions don't clear parser state"** (line 75) — open policy question: should `enter_insert_mode / enter_visual_mode / enter_command_mode / enter_normal_mode` (in `src/dispatch.asm`) clear `count_accumulator / pending_operator / pending_motion_prefix` on entry? Vi convention: yes — mode change discards pending operator/count/prefix. The story decision is **defer to Story 2.5** (when real motion handlers land and the count/operator semantics become observable). For 1.12 the deferred-work entry is updated with: "deferred to Story 2.5+ — parser state is invisible at the user level until motion handlers consume it; mode transitions in Epic 1 don't produce a user-visible bug from the stale-state interaction."
      - **Story 1.10 "Unbound key in NORMAL doesn't clear parser state"** (line 76) — same policy bucket as the above; same deferral note.
      - **Story 1.11 "TAB / CR / NUL / high-bit bytes render raw"** (line 65) — out of scope; surfaces in Epic 2's input-text-handling stories.
      - **Story 1.11 "render_emit_goto does not save D/E around CALL render_emit_byte"** (line 67) — AC8's hardware UAT is the test; if the smoke test passes (status row + Ctrl-L + mode-banner emit don't garble), the BIOS preserves D/E enough that the current contract holds. If the smoke test reveals D/E corruption (manifests as wrong cursor positions or garbled banner emit), the dev applies the deferred defensive-scratch fix in this story (route D/E through module-local scratch); otherwise mark the deferral "still pending — hardware UAT did not surface a regression".
    **And** the dev-notes Implementation section captures any deferral promotion (deferred → patch) that this story's hardware smoke surfaces — surprises become commits, not silent deferrals.

21. **Behavioral safety net — bdos_error_funnel re-entry.**
    **Given** `bdos_error_funnel` (Story 1.5, `src/statusln.asm:127-133`) which ends with `JP input_loop` for the abort path
    **When** any future BDOS call (Story 2.2+ fileio chain) returns a sign-bit rc
    **Then** the funnel surfaces `msg_bdos_error` via `status_set_message` and JPs to `input_loop`'s top (`input_get_key` step 1 of AC5)
    **And** the editor recovers — no crash, no warm-boot, no stuck cursor (NFR5 holds); the next keystroke proceeds normally
    **And** Story 1.12's UAT does NOT actually exercise this path (no fileio in Epic 1) but the wiring guarantees the path works the moment Story 2.2's `:e filename` arrives. Mark in dev-notes: "the bdos_error_funnel ↔ input_loop coupling is now production-active (was a Story-1.5 stub-to-stub wiring); the first real exerciser is Story 2.2."

22. **`vibe.asm`'s INCLUDE block AR25 comment block sweep.**
    **Given** Story 1.5 through Story 1.11 have each left an AR25 comment block above their respective INCLUDE in `src/vibe.asm`, each referencing future stories
    **When** I inspect `src/vibe.asm` after Story 1.12
    **Then** the dispatch.asm INCLUDE block's comment (currently lines 77-82 referencing "Production callers of dispatch_key arrive in Story 1.12") is updated to: "Production callers wired in this story's input_loop body — see `input_loop:` below."
    **And** the parser.asm INCLUDE block's comment (lines 85-92 referencing "Production callers of parser_handle_digit ... arrive via dispatch_normal once the Story 1.12 input_loop body wires") is updated to: "Production callers wired in this story's input_loop body — see `input_loop:` below."
    **And** the input.asm INCLUDE block's comment (lines 45-50 referencing "Production callers of input_get_key arrive in Story 1.12") is updated to: "Production callers wired in this story's input_loop body — see `input_loop:` below."
    **And** the gapbuf.asm INCLUDE block's comment (lines 60-66 referencing "Production callers of gapbuf_init arrive in Story 1.12") is updated to: "`gapbuf_init` is called from `init.asm`'s cold-start (Story 1.12); gap-buffer mutators (insert/delete/move_gap) are still test-only — Epic 2 motions / edits land the production callers."
    **And** the render.asm INCLUDE block's comment (lines 68-75 referencing "Production callers of render_diff / render_full arrive in Story 1.12") is updated to: "`render_init` and `render_full` are called from `init.asm`'s cold-start (Story 1.12); `render_diff` is called from the input loop body (this story)."
    **And** the statusln.asm INCLUDE block's comment (lines 53-58) is unchanged (statusln has had production callers since Story 1.9's dispatch_normal table; no update needed).
    **And** the `;; --- Input-loop abort target ---` comment block above `input_loop:` (currently lines 95-104 referencing "Story 1.12 (init/teardown + on-hardware smoke test) replaces this body") is rewritten to reflect the now-present main-loop body: "Main input loop. Falls into here from `init_cold_start` (src/init.asm) and is re-entered by `bdos_error_funnel`'s JP from src/statusln.asm. Loop body: `input_get_key` → `dispatch_key` → `render_diff` → repeat. Never returns to a caller — the only exit is via `mode_debug_quit` → `init_teardown` → warm-boot (or, future, `:q` / `:q!` in Story 2.1)."

## Tasks / Subtasks

- [x] Task 1 — Read foundational artifacts and previous-story dev-notes (no code change). (AC reference: all)
  - [x] Read `_bmad-output/planning-artifacts/architecture.md` § Module Calling Conventions (MC1, MC4), § Rendering & Input (RI2, RI4), § Module Dependency Graph (lines 1401-1450), § Data Flow (Keystroke Lifecycle, lines 1468-1505), § Implementation Sequence (lines 1559-1579), § Watchpoints (lines 1635-1644 — W1 in particular).
  - [x] Read `_bmad-output/implementation-artifacts/1-11-render-pipeline-with-dirty-rows-scroll-ctrl-l.md` § Dev Notes — the prior story's house style is the template. Recurring traps: (a) state-shape headless test pattern (pre-poison sentinel + call → inspect post-state); (b) `BDOS_CALL` macro arg-textual-substitution caveat (init_teardown uses the macro — pass `BDOS_EXIT` bareword, not `(BDOS_EXIT)`); (c) every `RET` documented in the trashes line; (d) AR13/AR14/AR15 grep enforcement; (e) `render_init` is the canonical screen-clear + cursor-home entry post-1.11 — DO NOT duplicate the ESC J emit in init.asm.
  - [x] Read `_bmad-output/implementation-artifacts/deferred-work.md` — Stories 1.3, 1.4, 1.8, 1.10, 1.11 entries explicitly named in AC20. Map each to a resolution path BEFORE writing code: full resolution, partial resolution, documentation-only update, or "still deferred — pending future story" with the new story name.
  - [x] Confirm `static_data_base` and `static_end` are sjasmplus-time integers (resolved at assembly) — they're EQU declarations in `inc/state.inc:37` and `inc/state.inc:100`. `static_end - static_data_base` is a compile-time constant; the LDIR uses an `LD BC, static_block_size` form with `static_block_size EQU static_end - static_data_base` declared locally in `src/init.asm` or as a one-off `LD BC, static_end - static_data_base` inline (either form assembles; the named-equate form is more self-documenting).
  - [x] Confirm `inc/equates.inc` declares `ESC_TIMEOUT_TICKS` (= 2 per line 50) — exercised on hardware in AC15.
  - [x] Confirm `inc/modes.inc` declares `MODE_NORMAL = 0`, `MODE_INSERT = 1`, `MODE_COMMAND = 2`, `MODE_VISUAL = 3`, `KEY_ARROW_UP/DOWN/LEFT/RIGHT = 0x80..0x83` (lines 23-26 + 39-42) — used in main-loop body's mode-table demultiplex and exercised on hardware in AC14.
  - [x] Confirm `DISPATCH_NORMAL_COUNT / DISPATCH_INSERT_COUNT / DISPATCH_COMMAND_COUNT / DISPATCH_VISUAL_COUNT` are exported from `src/dispatch.asm` (lines 520, 527, 534, 541) — referenced as the `B` register input to `dispatch_key`.
  - [x] Confirm `msg_mode_normal` is the empty string in `src/statusln.asm:170` (one-byte `DEFB 0`).

- [x] Task 2 — Create `src/init.asm` with the standard module-header block per AR23. (AC: 1)
  - [x] Header block: Module / Purpose / Public / State owned / State read-only / Register conventions / Dependencies. Mirror `src/render.asm` lines 1-180 for shape (multiple public entry points each with their own contract block; module owns no permanent state but performs a one-shot LDIR-fill across the whole static block at cold-start).
  - [x] Public block enumerates `init_cold_start` and `init_teardown`. No internal helpers are exported (the optional `init_zero_init_static_block` helper, if extracted, stays file-local).
  - [x] State owned (read/write): explicitly `(none — init.asm performs a one-shot zero-init at cold-start but does not OWN any field across the editor's lifetime)`. Document the LDIR-fill as a Story-1.3 deferral resolution; ownership of each field stays with its authoring module.
  - [x] Dependencies line lists `inc/equates.inc` (no specific symbols — state.inc-via-EQU sizing), `inc/state.inc` (`static_data_base`, `static_end` for the LDIR fill bounds; `mode_byte`, `status_dirty` for the read references in stage 4), `inc/bios.inc` (`DEFAULT_FCB` for the AC7 FCB-skip — referenced by symbol even though no read is performed), `inc/bdos.inc` (`BDOS_CALL` macro + `BDOS_EXIT` for init_teardown), `inc/modes.inc` (no direct reference — `MODE_NORMAL = 0` is encoded by the LDIR's 0x00 fill, the module relies on the equate value), `inc/vt52.inc` (no direct reference — render.asm absorbs the VT52 emit per AR13), `src/statusln.asm` (`status_set_message`, `msg_mode_normal`), `src/gapbuf.asm` (`gapbuf_init`), `src/render.asm` (`render_init`, `render_full`), `src/vibe.asm` (`input_loop` — fall-through target).
  - [x] Document the AR13 / AR14 / AR15 enforcement at the head: three short paragraphs explaining what init.asm DOES NOT call. This is defensive against future "init should just emit a banner" patches that would silently break the screen-emission funnel.

- [x] Task 3 — Implement `init_cold_start`. (AC: 2, 17)
  - [x] Public entry. `In: (none — entered from src/vibe.asm's ORG 0x0100 + JP init_cold_start). Out: editor state fully initialised; mode = NORMAL; gap buffer at SR2 empty; screen cleared with empty editing area + blank status row; cursor at row 0/col 0; control transfers to input_loop via JP. Trashes: A, BC, DE, HL, F. Calls: gapbuf_init, render_init, status_set_message, render_full.`
  - [x] Implementation pattern (recommended):
    ```
    init_cold_start:
        ;; 1. Zero-init the entire static block (Story 1.3 deferral resolved).
        ;;    LDIR-fill: 1-byte seed at static_data_base, then LDIR
        ;;    propagates the seed across (static_end - static_data_base) - 1
        ;;    bytes. Cost: ~21 T-states/byte * static_block_size ~ 50K T-states
        ;;    ~ 12 ms at 4 MHz. Boot-time cost, acceptable per NFR3.
        LD      HL, static_data_base
        LD      DE, static_data_base + 1
        XOR     A
        LD      (HL), A
        LD      BC, static_end - static_data_base - 1
        LDIR

        ;; 2. Establish SR2 (gap buffer empty, cursor at offset 0).
        CALL    gapbuf_init

        ;; 3. Clear screen, seed shadow with spaces, home cursor.
        CALL    render_init

        ;; 4. Seed status_dirty so render_full's status-row emit fires.
        ;;    msg_mode_normal is the empty string — status_buffer is
        ;;    padded with 80 spaces; the blank banner matches vi's
        ;;    "no banner in normal mode" convention (AR16 + Story 1.9).
        LD      HL, msg_mode_normal
        XOR     A
        CALL    status_set_message

        ;; 5. Full-redraw initial frame. Cell content is all spaces
        ;;    (matching shadow); the only emitted bytes are the
        ;;    cursor-reposition (RI4) and the status-row emit (since
        ;;    status_dirty was just set).
        CALL    render_full

        ;; 6. Fall through to the main input loop.
        JP      input_loop
    ```
  - [x] **`LD BC, static_end - static_data_base - 1` is a compile-time constant.** sjasmplus 1.23.0 resolves the subtraction at assembly time. If the dev prefers, declare `static_block_size EQU static_end - static_data_base` at the top of init.asm (file-local equate) and use `LD BC, static_block_size - 1` for clarity.
  - [x] **The LDIR fill leaves `mode_byte = 0 = MODE_NORMAL`.** Convenient but not load-bearing — the LDIR fills WITH `XOR A` (= 0), and `MODE_NORMAL` is EQU'd to 0 in inc/modes.inc:23. If MODE_NORMAL ever moves (no reason it would, but the AR-style "single source of truth" principle says equates are knobs), the cold-start would need an explicit `LD A, MODE_NORMAL : LD (mode_byte), A` after the LDIR. For Story 1.12 the implicit-via-zero-fill form is acceptable; document the dependency in the implementation comment.
  - [x] **The LDIR fill is ~2240 bytes (the size of the static block).** Compare against the gap-buffer fill in render_init (1920 bytes for shadow_buffer). Total init-time fill: ~4160 bytes, ~90K T-states, ~22 ms at 4 MHz. Acceptable for a one-time boot cost (NFR3 governs frame-rate cost, not boot-time).

- [x] Task 4 — Implement `init_teardown`. (AC: 3, 17)
  - [x] Public entry. `In: (none). Out: screen cleared via ESC J + cursor home; control transfers to CCP via BDOS function 0 (warm-boot). Does not return on a real CP/M host; defensive RET retained per mode_debug_quit precedent. Trashes: A, BC, DE, HL, F. Calls: render_init, BDOS_ENTRY (via BDOS_CALL macro).`
  - [x] Implementation pattern (recommended):
    ```
    init_teardown:
        ;; 1. Clear screen + home cursor. Routing through render_init
        ;;    keeps AR13 enforced (init.asm has zero BIOS_CONOUT call
        ;;    sites). The shadow re-seed and dirty_rows / top_line_offset
        ;;    writes are inert at teardown — no subsequent render pass
        ;;    will read them. The cost of the redundant shadow LDIR
        ;;    (1920 bytes ~ 10 ms at 4 MHz) is irrelevant at teardown.
        CALL    render_init

        ;; 2. Warm-boot to CCP via BDOS function 0.
        BDOS_CALL BDOS_EXIT

        ;; 3. Defensive — BDOS_EXIT never returns on a real CP/M host,
        ;;    but a misconfigured BIOS-during-bring-up could in principle
        ;;    let it through. The RET keeps us out of arbitrary memory.
        ;;    Mirrors the existing mode_debug_quit precedent at
        ;;    src/dispatch.asm:341-343.
        RET
    ```
  - [x] **Optional alternative: add a `render_clear_and_home` public to `src/render.asm`** that emits ONLY the ESC J + cursor home WITHOUT the shadow re-seed. This adds 1 public symbol to render.asm and saves ~10 ms at teardown. The dev MAY choose this; for Story 1.12 the default is "reuse render_init" because (a) one public symbol fewer is cleaner, (b) the teardown is run-once-and-exit so the cost is irrelevant, (c) the alternative would require a render.asm patch in this story which the AC15-style "no new public symbols" deferral pattern argues against. Document the choice in the implementation comment.

- [x] Task 5 — Wire `src/vibe.asm`'s `0x0100` entry + main input-loop body. (AC: 4, 5, 22)
  - [x] Replace the existing `RET` at `src/vibe.asm:40` with `JP init_cold_start` (3 bytes; expands from 1 byte). The post-LDIR layout shift is ~2 bytes — every label past line 40 moves accordingly; sjasmplus rebuilds the layout cleanly on each `make`.
  - [x] Update the trailing comment at `src/vibe.asm:40-43` from "Stub exit: returns to warm-boot vector ... Replaced by proper init/teardown in Story 1.12" to a one-line "Entry point: jump to init.asm's cold-start. See src/init.asm." plus a brief stack-discipline note (the CCP-pushed warm-boot vector stays on the stack across init's lifetime; init_teardown's BDOS_EXIT consumes the symmetric exit path).
  - [x] Replace the existing `input_loop:` body at `src/vibe.asm:105-108` (the Story 1.5 stub: `BDOS_CALL BDOS_EXIT / RET`) with the real input-loop body per AC5. Recommended implementation:
    ```
    input_loop:
        ;; 1. Get next keystroke (RI5 disambig is internal to input_get_key).
        CALL    input_get_key

        ;; 2. Per-mode dispatch-table demultiplex.
        ;;    A holds the key; preserve it in C across the mode-byte read.
        LD      C, A
        LD      A, (mode_byte)
        CP      MODE_INSERT
        JR      Z, .insert
        CP      MODE_COMMAND
        JR      Z, .command
        CP      MODE_VISUAL
        JR      Z, .visual
        ;; Default + NORMAL: dispatch_normal.
        LD      HL, dispatch_normal
        LD      B, DISPATCH_NORMAL_COUNT
        JR      .dispatch
    .insert:
        LD      HL, dispatch_insert
        LD      B, DISPATCH_INSERT_COUNT
        JR      .dispatch
    .command:
        LD      HL, dispatch_command
        LD      B, DISPATCH_COMMAND_COUNT
        JR      .dispatch
    .visual:
        LD      HL, dispatch_visual
        LD      B, DISPATCH_VISUAL_COUNT

    .dispatch:
        LD      A, C                      ; restore key for MC4 (A = key)
        CALL    dispatch_key              ; handler RETs back here

        ;; 3. Reconcile screen with any buffer / status changes.
        CALL    render_diff

        ;; 4. Loop. Never falls through; the only exits are
        ;;    init_teardown (via mode_debug_quit) or bdos_error_funnel's
        ;;    JP input_loop (which lands at this label's top — abort
        ;;    path re-enters the loop).
        JP      input_loop
    ```
  - [x] **The `LD C, A` save-across-mode-byte-read.** `LD A, (mode_byte)` clobbers A. Save the key in C (which the existing dispatch_key contract uses internally; here we use C as a scratch). Restore A from C just before the CALL. Sub-30 T-states overhead per keystroke — well under NFR3's interactive budget.
  - [x] **The `JR Z, .insert` / `.command` / `.visual` chain.** Three CP+JR pairs (~3 bytes each = 9 bytes) for the mode demultiplex. An alternative is a 4-entry table indexed by `mode_byte` (`mode_table_base + mode_byte * 4` → load HL/B from the entry); ~10 bytes of table + ~12 bytes of indexing math = 22 bytes. The CP-chain form is slightly smaller and equally fast (worst case 3 CPs for VISUAL); pick the CP-chain.
  - [x] **Defensive fall-through to NORMAL.** A corrupted `mode_byte` (one with a value not in {0,1,2,3}) falls through to the `.dispatch` with `HL = dispatch_normal` — the editor stays usable even if some unforeseen bug poisons `mode_byte`. NFR5: never crash into undefined behavior.
  - [x] **The body's contract block** (preceding comment) MUST document the non-RET-terminating nature. Mirror the existing `bdos_error_funnel`'s "does not return" contract at `src/statusln.asm:113`.
  - [x] **Update the AR25 comment blocks above each src/ INCLUDE in `src/vibe.asm`** per AC22. Six INCLUDEs (init / input / statusln / gapbuf / render / dispatch / parser) — each loses its "Production callers arrive in Story 1.12" hedge.
  - [x] **Update the `;; --- Input-loop abort target ---` comment block** (lines 95-104) per AC22.
  - [x] **Update `src/vibe.asm`'s header `Dependencies:` line** (lines 21-25) to add `src/init.asm (Story 1.12)` AS THE FIRST listed src/ dependency.
  - [x] **Update `src/vibe.asm`'s header `Public:` block** — `input_loop` is still public (it's referenced by `bdos_error_funnel` in src/statusln.asm), but its purpose comment is updated from "Story 1.5 stub abort target — bdos_error_funnel JPs here. Story 1.12 replaces the body with the real input-loop top-of-frame" to a one-line "Main input-loop top-of-frame: input_get_key → dispatch_key → render_diff → repeat. Re-entered by bdos_error_funnel's abort path."

- [x] Task 6 — Insert `INCLUDE "init.asm"` into `src/vibe.asm` per AR25. (AC: 9)
  - [x] Add `INCLUDE "init.asm"` AS THE FIRST source-code INCLUDE after the `ORG 0x0100` + `JP init_cold_start` block (i.e., immediately after the entry-point line, BEFORE `INCLUDE "input.asm"`).
  - [x] Add a new AR25 comment block matching the prior INCLUDEs' style:
    ```
    ;; --- Cold-start init + teardown (init.asm — Story 1.12) ---
    ; AR25 order: ORG 0x0100 -> init -> input -> statusln ->
    ; gapbuf -> render -> dispatch -> parser. init.asm owns the
    ; cold-start sequence (zero-init the static block, gapbuf_init,
    ; render_init, initial status banner via msg_mode_normal,
    ; render_full, fall-through to input_loop) and the teardown
    ; sequence (render_init for screen-clear + cursor home, then
    ; BDOS_CALL BDOS_EXIT for warm-boot to CCP).
        INCLUDE "init.asm"
    ```

- [x] Task 7 — Re-point `mode_debug_quit` in `src/dispatch.asm`. (AC: 6)
  - [x] Locate `mode_debug_quit` at `src/dispatch.asm:341-343`. Current body: `BDOS_CALL BDOS_EXIT / RET`.
  - [x] Replace the body with `JP init_teardown`:
    ```
    mode_debug_quit:
        JP      init_teardown
    ```
    Net byte change: shrinks by ~4 bytes (removed: `BDOS_CALL` macro expansion ~7 bytes — `LD C, BDOS_EXIT` 2 + `CALL BDOS_ENTRY` 3 + `OR A` 1 + `JP M, bdos_error_funnel` 3 = 9 bytes — and `RET` 1 byte; added: `JP init_teardown` 3 bytes).
  - [x] Update the routine's contract block: `Out: does not return on a real CP/M host (init_teardown warm-boots via BDOS function 0). Trashes: A, BC, DE, HL, F (init_teardown's chain). Calls: init_teardown (tail-JP).`
  - [x] Update the routine's purpose comment per AC6.
  - [x] Update `src/dispatch.asm`'s header `Dependencies:` line to add `src/init.asm (Story 1.12 — init_teardown, for mode_debug_quit's screen-clear-on-exit path)`.

- [x] Task 8 — Confirm BIOS jump-table addresses on real hardware (W1). (AC: 8)
  - [x] **Step 1: verify the placeholder values against MicroBeast BIOS documentation.** The architecture lines 1095-1099 list `0xFA06 / 0xFA09 / 0xFA0C` as the placeholders. Find the MicroBeast BIOS jump-table base address (typically by running `vibe` on hardware and using a memory-inspection tool, or reading the BIOS source if available, or disassembling the BIOS image).
  - [x] **Step 2: if the addresses match, write a one-line confirmation note** in `inc/bios.inc:24-32`'s placeholder comment block. The `IFNDEF BIOS_CONOUT_OVERRIDE` guard (added by Story 1.11 for test-side override) is unchanged.
  - [x] **Step 3: if the addresses don't match, update `inc/bios.inc`** with the confirmed values. Capture before/after deltas in dev-notes Debug Log References.
  - [x] **Step 4: confirm `BIOS_TICK_ADDR`.** The Story-1.4 deferral (deferred-work.md line 27) flagged the placeholder 0xFA00 as overlapping the BIOS jump-table neighborhood. On a typical CP/M 2.2 BIOS (17 entries × 3 bytes = 51 bytes from base) the tick counter at 0xFA00 lands inside the table region. If real MicroBeast confirms this conflict, relocate `BIOS_TICK_ADDR` to a non-conflicting BIOS-managed counter address (look for the BIOS ISR's tick-store location in the BIOS image / docs).
  - [x] **Step 5: re-build and re-test.** After any `inc/bios.inc` update, re-build `vibe.com` and SLIDE-push. The hardware UAT in AC14 / AC15 is the regression test — Esc/arrow timing in particular surfaces a wrong `BIOS_TICK_ADDR` immediately (the tick_wait_one spin either never returns, returns immediately, or returns at the wrong rate).
  - [x] **Step 6: update `deferred-work.md`** with the resolution note for the Story-1.4 entry.

- [x] Task 9 — Wire `make sizes` for real per-section size reporting. (AC: 13)
  - [x] Locate `Makefile:61-62` (current stub). Replace the rule body with a real size-report.
  - [x] **Recommended implementation (single-number form):** parse `build/vibe.lst` for the `static_data_base` resolution and subtract 0x0100. sjasmplus emits the EQU's value in the listing at the line where the symbol is defined (typically as a hex value in a fixed column). One-line awk pipeline:
    ```
    sizes: build/vibe.lst
    \tawk '/static_data_base/ && /EQU/ { val = strtonum("0x" $$N); print "code_section:", val - 256, "bytes (~", int((val - 256) * 100 / 3072), "% of NFR9 ~3 KB budget)" }' build/vibe.lst
    ```
    (Replace `$$N` with the column index where the address appears; verify by inspecting a current `build/vibe.lst`.)
  - [x] **Alternative implementation (simplest — total .com size):**
    ```
    sizes: vibe.com
    \t@size=$$(wc -c < vibe.com); \\
    \t echo "code_section: $$size bytes (~$$((size * 100 / 3072))% of NFR9 ~3 KB budget)"
    ```
    Reports the binary file size, which IS the production code section (state.inc is EQU-only, emits no bytes; the .com is purely code as of Story 1.12).
  - [x] **Update the rule's preceding comment block** in `Makefile:1-17` (the per-target comment) — change `sizes` from "listing-file size audit (stub until later story wires it, per BA3)" to "per-section size from the binary — implements NFR9 audit baseline; see Story 1.12".
  - [x] **Document the chosen implementation** in dev-notes' Implementation section (which form: listing-parse vs wc -c). Capture the actual `make sizes` output verbatim in Debug Log References as the post-1.12 NFR9 baseline.

- [x] Task 10 — Write `test/cases/init_cold_start-state-shape.asm`. (AC: 16)
  - [x] **Test scaffold pattern.** The trickiest part: `init_cold_start` ends with `JP input_loop`, which in the test scaffold (via `test_input_loop_stub.inc`) warm-boots via `BDOS_CALL BDOS_EXIT`. The warm-boot happens BEFORE the test can inspect post-init state. Workaround: REPLACE the test's `input_loop` symbol with a custom verifier that does the state-shape inspection THEN JPs to test_pass / test_fail. The test file DOES NOT INCLUDE `test_input_loop_stub.inc`; instead it defines its own `input_loop:` that performs the verification.
  - [x] **Pre-poison the static block** before calling `init_cold_start`. Fill `static_data_base..static_end` with a sentinel byte (e.g. 0xAA) via LDIR. Don't touch the gap buffer or yank buffer (init_cold_start doesn't touch those either; pre-poisoning them adds nothing).
  - [x] **Install BIOS_CONOUT override** per Story 1.11's mechanism: `DEFINE BIOS_CONOUT_OVERRIDE` + `BIOS_CONOUT EQU test_bios_conout` BEFORE the `INCLUDE "../../inc/bios.inc"` line. This redirects render.asm's emit chain into the test_bios_conout capture buffer — otherwise the calls to BIOS_CONOUT at 0xFA0C (a W1 placeholder address) trigger an iz-cpm cold-restart that masquerades as a test failure.
  - [x] **Reset `test_capture_len = 0`** before calling `init_cold_start` so the post-call capture (~80+ bytes for an init sequence: ESC J, cursor home, status row emit, cursor reposition) starts clean.
  - [x] **Call `init_cold_start`.** It falls through to `input_loop` — the custom-defined one in this test file, which is the verifier.
  - [x] **Verifier body** (the test's local `input_loop:`):
    - Subtest 1: `mode_byte == MODE_NORMAL` (= 0). Sentinel 0xE1, context = observed mode_byte value.
    - Subtest 2: `cursor_offset == 0` (both bytes). Sentinel 0xE2.
    - Subtest 3: `gap_start == GAP_BUFFER_BASE`. Compare 16-bit. Sentinel 0xE3.
    - Subtest 4: `gap_end == GAP_BUFFER_BASE + GAP_BUFFER_MAX`. 16-bit. Sentinel 0xE4.
    - Subtest 5: `top_line_offset == 0`. 16-bit. Sentinel 0xE5.
    - Subtest 6: `dirty_rows[0..2] == 0`. Three byte compares. Sentinel 0xE6.
    - Subtest 7: `shadow_buffer[0] == 0x20`. Single byte read. Sentinel 0xE7.
    - Subtest 8: `status_dirty != 0`. The status_set_message call in stage 4 of init_cold_start sets this; the subsequent render_full in stage 5 CLEARS it (render_diff's status-row emit clears status_dirty after reconciling row 23 — see Story 1.11 AC4 step 3). So post-init_cold_start, `status_dirty == 0`. Sentinel 0xE8, expected value DOCUMENTED.
    - Subtest 9: `input_held_flag == 0` (Story 1.8 deferral resolved). Sentinel 0xE9.
    - Subtest 10: `pending_operator == 0`, `pending_motion_prefix == 0`, `count_accumulator == 0`. Three small checks. Sentinel 0xEA / 0xEB / 0xEC.
    - On all-pass, `JP test_pass`.
  - [x] **Standard test prologue/epilogue** (`test_prologue.inc` + `test_epilogue.inc`) wrap the verifier.
  - [x] **Production INCLUDEs in AR25 order** AFTER the test body / BEFORE `inc/state.inc` LAST: `src/init.asm`, `src/input.asm` (init.asm's input_loop reference; the test's local `input_loop` resolves it without including the production stub), `src/statusln.asm`, `src/gapbuf.asm`, `src/render.asm`, `src/dispatch.asm`, `src/parser.asm`. NB: this test does NOT include `test_input_loop_stub.inc` — the test defines its own `input_loop:` as the verifier.
  - [x] **state.inc LAST** per the test-scaffold positional anchor.
  - [x] **Test-local capture / sentinel buffers** sit between the test body and the production INCLUDEs (standard pattern from Story 1.11's render_*.asm tests).

- [x] Task 11 — Hardware UAT smoke (real MicroBeast). (AC: 14, 15)
  - [x] **Step 1: build clean.** `make clean && make`. Verify `vibe.com` exists and `make sizes` reports a number under ~3 KB. Capture SHA + size in dev-notes.
  - [x] **Step 2: SLIDE-push to MicroBeast.** Use the established `make push` target (or the SLIDE invocation form documented for the dev environment). Verify the artifact arrives on the MicroBeast's filesystem.
  - [x] **Step 3: launch `vibe` from CCP.** Verify the screen clears, the editing area is empty (24 rows × 80 cols of spaces), the status row at row 24 is blank, and the cursor is at the top-left.
  - [x] **Step 4: mode-transition smoke.** Press 'i' → INSERT banner appears. Press Esc → NORMAL (blank banner). Press ':' → COMMAND banner. Press Esc → NORMAL. Press 'v' → VISUAL banner. Press Esc → NORMAL. Press '/' → "not yet implemented" surfaces. Press Esc — '/' stays in NORMAL (no MODE_SEARCH yet; the stub doesn't transition mode). Press Ctrl-L → screen redraws cleanly. Document any deviation.
  - [x] **Step 5: unbound-key smoke (FR50).** In NORMAL, press '!', 'q', 'z', 'x', '~', '*'. Each surfaces "unbound key" in the status row. mode_byte stays NORMAL. cursor_offset stays 0. No crash.
  - [x] **Step 6: Esc-disambig smoke (NFR4 / RI5).** Press Esc in isolation 10x; each transitions to NORMAL within ~40 ms (subjectively imperceptible). Press an arrow key (Up/Down/Left/Right) — the VT52 emits `ESC A/B/C/D`; `input_get_key` synthesises `KEY_ARROW_*`; in NORMAL mode the arrows route to `unbound_normal` and surface "unbound key" (Epic 2 lands h/j/k/l motions and binds the arrows). No crash; no garbled state.
  - [x] **Step 7: sustained-typing smoke (NFR5).** In NORMAL mode, type arbitrary keys for 30 seconds (target: ~300+ keystrokes). No crash, no terminal corruption, no stuck cursor. Press Ctrl-L midway — screen restores clean. Continue typing through Ctrl-L. End the 30s by pressing Ctrl-Q.
  - [x] **Step 8: debug-quit smoke (AC6).** Press Ctrl-Q. Screen clears, cursor returns to top-left, CCP prompt re-appears. The terminal is in a clean state (no stuck attributes, no half-emitted escape sequences).
  - [x] **Step 9: re-launch.** Type `vibe` again. The editor comes up clean (the static-block zero-init means no boot residue from the prior run).
  - [x] **Step 10: capture the UAT outcome in dev-notes Debug Log References.** Per-step pass/fail notes; any failure modes recorded in enough detail to reproduce.

- [x] Task 12 — Build, byte-identical rebuild check, AR grep sweeps, all-tests pass. (AC: 18)
  - [x] `make clean && make` succeeds (NFR14).
  - [x] Capture two consecutive `make clean && make` SHAs of `vibe.com`; verify byte-identical (NFR18).
  - [x] `make sizes` reports the code-section size. Capture verbatim.
  - [x] `grep -rnE 'BIOS_CONOUT' src/ | grep -v 'render.asm'` → zero matches (AR13).
  - [x] `grep -nE 'gapbuf_(insert|delete|move_gap|load)' src/init.asm` → zero matches (AR14).
  - [x] `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/init.asm` → zero matches (AR15 — raw forms forbidden).
  - [x] `grep -nE 'BDOS_CALL' src/init.asm` → exactly one match (the BDOS_CALL BDOS_EXIT in init_teardown).
  - [x] `make -C test test` reports at least 23 pass / 1 fail (22 pre-1.12 + 1 new init test + harness_fail).

- [x] Task 13 — Update `deferred-work.md` to resolve the named entries. (AC: 20)
  - [x] Story 1.3 zero-init entry → resolved by Story 1.12.
  - [x] Story 1.4 BIOS_TICK_ADDR overlap entry → resolved by Story 1.12 AC8 (or partially resolved with a forward note if the address moved).
  - [x] Story 1.8 input_held_flag uninitialised entry → resolved by Story 1.12.
  - [x] Story 1.8 tick_wait_one unconditional EI entry → still deferred (the AC20 analysis explains why).
  - [x] Story 1.10 mode-transition / unbound-key parser-state-clear entries → still deferred (to Story 2.5+).
  - [x] Story 1.11 deferred items → unchanged unless the hardware smoke surfaced one as a regression.

- [ ] Task 14 — Commit. The suggested message style mirrors the prior stories' plain-English subjects: `story 1.12: Wired init/teardown, the main input loop, and the first on-hardware smoke test.`

## Dev Notes

### Architecture compliance

This story implements the architecture's **Implementation Sequence** step 1 (architecturally enforced bring-up order, architecture line 1559-1579): Stories 1.1 through 1.11 built the substrate (skeleton, headers, gap buffer, input, dispatch, parser, render); Story 1.12 ties them together in `init.asm` + `vibe.asm`'s main-loop body. Specific architectural decisions wired:

- **MC1 (caller-saved everywhere).** Every routine in this story's surface obeys: `init_cold_start` declares its trashes; `init_teardown` declares its trashes; the main-loop body documents transitive clobber via `input_get_key + dispatch_key + render_diff`.
- **MC4 (handler signature: A = key, accumulator state in fixed addresses).** The main-loop body restores `A = key` before `CALL dispatch_key` — the MC4 contract held by every dispatched handler since Story 1.9.
- **MC5 (status-message funnel — `status_set_message`).** `init_cold_start` calls `status_set_message msg_mode_normal` to seed `status_dirty` for the initial render pass. AR12's funnel discipline holds — init.asm does NOT write `status_buffer` or `status_dirty` directly.
- **MC6 (checked-BDOS-call macro — `BDOS_CALL` macro).** `init_teardown` uses `BDOS_CALL BDOS_EXIT`; init.asm is AR15-clean except for this one macro use.
- **MC7 (static memory map via state.inc).** `init_cold_start`'s LDIR fill operates on the state.inc-declared anchors `static_data_base` and `static_end`. No magic addresses; the symbols ARE the state map.
- **RI2 (render runs after each input-loop iteration; no periodic timer).** Story 1.12 wires this: `render_diff` is called once per loop iteration, after the handler returns.
- **RI4 (cursor-positioning emission emitted LAST in every render pass).** `render_diff`'s contract (Story 1.11 AC4 step 5) is invoked by the main-loop body once per iteration; the trailing cursor reposition is the documented defensive escape from cursor desync.
- **RI5 (Esc-disambig pattern).** `input_get_key` (Story 1.8) is the loop's entry. The 50 Hz tick-window for bare-Esc / arrow disambig is exercised in the AC15 hardware smoke.
- **RI6 (single `input_get_key → dispatch` loop; no interrupt-driven event queue).** Story 1.12's main-loop body IS this contract.

The story also resolves the architecture's **Watchpoint W1** (architecture lines 1635-1639): the BIOS jump-table placeholder addresses are confirmed against real MicroBeast hardware in AC8.

### Library / framework requirements

**sjasmplus 1.23.0:**
- Already pinned by `Makefile`'s `check-toolchain` (Story 1.1).
- **Forward references resolve on second pass.** init.asm's `JP input_loop`, `CALL gapbuf_init`, `CALL render_init`, `CALL status_set_message`, `LD HL, msg_mode_normal`, `CALL render_full` are all forward references at first pass (init.asm INCLUDEs first in `src/vibe.asm`; the referenced symbols are defined in modules INCLUDEd later). sjasmplus's two-pass model tolerates undefined-on-first-pass and resolves on second.
- **`LDIR` for the static-block fill.** ~21 T-states per byte × ~2240 bytes ≈ 47K T-states ≈ 12 ms at 4 MHz. Boot-time cost, acceptable per NFR3.
- **`BDOS_CALL` macro arg-textual-substitution discipline.** `BDOS_CALL BDOS_EXIT` expands to `LD C, BDOS_EXIT / CALL BDOS_ENTRY / OR A / JP M, bdos_error_funnel`. Bareword `BDOS_EXIT` is required; `BDOS_CALL (BDOS_EXIT)` would expand to `LD C, (BDOS_EXIT)` — a 16-bit memory load from address 0 (the `BDOS_EXIT` equate's value is 0; reading address 0 returns the warm-boot jump opcode byte) — silently dispatching the wrong BDOS function. Document at the call site.
- **Compile-time integer arithmetic.** `static_end - static_data_base` is resolved at assembly time (both are EQU declarations from `inc/state.inc`). The `LD BC, static_end - static_data_base - 1` form is canonical for an LDIR byte-count source.

**iz-cpm:**
- Used for the new `init_cold_start-state-shape.asm` headless test.
- **The test cannot exercise `init_cold_start`'s full fall-through to `input_loop`.** The production `input_loop` body would loop forever on `BIOS_CONIN` (a blocking read). Workaround: the test defines its own `input_loop:` as a verifier that JPs to test_pass / test_fail after inspecting state.inc fields. The standard `test_input_loop_stub.inc` is NOT INCLUDEd for this test.
- **The render_init / render_full calls inside `init_cold_start` need the BIOS_CONOUT capture override** (Story 1.11's `BIOS_CONOUT_OVERRIDE` mechanism). Without it, the test cold-restarts iz-cpm at the W1-placeholder address 0xFA0C.
- **5-second timeout per test.** init.asm's cold-start chain (LDIR + gapbuf_init + render_init + status_set_message + render_full) is bounded: LDIR ~12 ms + render_init's 1920-byte LDIR ~10 ms + render_full ~25 ms = ~50 ms total at 4 MHz iz-cpm clock. Comfortably under timeout.

**CP/M 2.2 BDOS:**
- `BDOS_EXIT` (function 0, warm-boot) is the only BDOS function `init.asm` references. NFR15 (CP/M 2.2 BDOS only — no 3.x extensions) holds.
- The default FCB at `DEFAULT_FCB = 0x005C` is a CP/M 2.2 convention — CCP populates it before transferring control. Story 1.12 skips the parse; Story 2.3 reads it.

**MicroBeast BIOS:**
- `BIOS_CONOUT` at 0xFA0C (W1 placeholder) — confirmed in AC8 against real hardware.
- `BIOS_CONIN` / `BIOS_CONINST` / `BIOS_TICK_ADDR` — same W1 confirmation in AC8.
- The 50 Hz timer ISR maintains the tick counter; `tick_wait_one` (in `src/input.asm`, Story 1.8) is the consumer. AC15 exercises the consumer on hardware.

### Previous story intelligence (Stories 1.1-1.11)

**From Story 1.1:**
- `make` from project root produces `vibe.com` deterministically. Adding `src/init.asm` (~150-250 bytes of code) plus the main-loop body edits in `src/vibe.asm` (~40-60 bytes) plus the `make sizes` rule plus the `mode_debug_quit` body shift (-4 bytes) plus the `JP init_cold_start` entry (+2 bytes vs `RET`) plus deferral-resolution comments leaves a ~200-byte growth budget for this story. AC18 verifies byte-determinism.
- The `Makefile`'s `sizes:` stub at line 61-62 is wired for real in this story per AC13.

**From Story 1.2:**
- `inc/equates.inc` declares the constants `init.asm` and the main loop rely on: `SCREEN_ROWS`, `SCREEN_COLS`, `STATUS_LINE_WIDTH`, `ESC_TIMEOUT_TICKS`. None are MODIFIED by this story.
- `inc/modes.inc` declares `MODE_NORMAL = 0` — exploited by the LDIR-fill (post-fill mode_byte is automatically NORMAL). Document the implicit dependency.
- `inc/vt52.inc` declares `VT52_ESC` / `VT52_GOTO` / etc. — consumed by `render.asm`, NOT by `init.asm` (init.asm has zero direct VT52 emit per AR13).

**From Story 1.3:**
- `inc/state.inc` declares every field this story zero-inits. `static_data_base` (line 37) and `static_end` (line 100) are the LDIR fill bounds. `GAP_BUFFER_BASE` (line 106) and `yank_buffer` / `yank_end` (lines 114-115) live PAST `static_end` and are deliberately NOT zero-init by this story.
- **Story 1.3 deferral on zero-init is resolved here (AC20).** The centralised LDIR fill at `init_cold_start` stage 1 covers every state.inc field declared between `static_data_base` and `static_end`.
- The Story 1.3 ASSERT `yank_end <= 0xD800` (state.inc:126) continues to hold post-1.12; the code growth from this story is within the TPA budget (NFR10).

**From Story 1.4:**
- `inc/bdos.inc`'s `BDOS_CALL` macro is the AR15 gateway. `init_teardown` uses it once.
- `inc/bios.inc` placeholder addresses at lines 33, 34 (CONIN/CONINST), the IFNDEF-guarded CONOUT at line 45, and BIOS_TICK_ADDR at line 76 — all confirmed on hardware in AC8.
- **Story 1.4 deferral on BIOS_TICK_ADDR overlap is resolved here (AC20)** — or moved forward with a confirmed address if the placeholder was wrong.
- The IFNDEF guard on `BIOS_CONOUT` (added by Story 1.11) is unchanged.

**From Story 1.5:**
- `src/statusln.asm` owns `status_set_message` and `msg_mode_normal`. `init_cold_start` invokes the funnel once at stage 4. AR12 holds.
- `bdos_error_funnel` continues to `JP input_loop` — Story 1.5's stub-to-stub wiring is now stub-to-production: the funnel re-enters the real input loop body (AC21).
- The Story-1.5 `status_render` retirement (done in Story 1.11) is irrelevant to this story; init.asm doesn't reference `status_render`.

**From Story 1.6:**
- `make test` from project root runs the headless harness. One new `init_cold_start-state-shape.asm` test added under `test/cases/`. The harness picks it up automatically (no test/Makefile edits).
- The test scaffold (`test_prologue.inc` + `test_epilogue.inc`) is unchanged.

**From Story 1.7:**
- `src/gapbuf.asm` owns `gapbuf_init`. `init_cold_start` invokes it once at stage 2. AR14 holds (no mutating primitives called).
- The two-halves walk in gapbuf.asm continues to be consumed by `render.asm` (Story 1.11); `init.asm` does not walk the buffer.

**From Story 1.8:**
- `src/input.asm`'s `input_get_key` is the loop's entry point. The Esc/arrow disambig is exercised on hardware in AC15.
- **Story 1.8 deferral on input_held_flag uninitialised at boot is resolved here (AC20).** The centralised zero-init in stage 1 covers `input_held_flag` and `input_held_byte`.
- The Story 1.8 deferral on `tick_wait_one`'s unconditional EI clobbering caller's IFF state is EVALUATED but stays deferred per AC20's analysis.

**From Story 1.9:**
- `src/dispatch.asm` owns `dispatch_key` and the four per-mode tables. The main-loop body in `src/vibe.asm` consumes them.
- `mode_debug_quit` (the Ctrl-Q stub) is re-pointed at `init_teardown` in AC6.
- `enter_normal_mode` / `enter_insert_mode` / `enter_command_mode` / `enter_visual_mode` (the four mode-change handlers) are exercised on hardware in AC14.
- `unbound_normal` / `unbound_insert` / `unbound_command` / `unbound_visual` (the four unbound handlers) are exercised on hardware in AC14 — FR50 validation.
- **Story 1.10 deferrals on mode-transition parser-state-clearing and unbound-key parser-state-clearing** are EVALUATED but deferred to Story 2.5+ per AC20.

**From Story 1.10:**
- `src/parser.asm`'s `parser_handle_digit / parser_handle_operator / parser_handle_motion_prefix` are exercised on hardware in AC14 (digits, operators, 'g' all surface "not yet implemented" since the doubled-op and gg stubs route through `parser_doubled_operator_stub` / `parser_gg_motion_stub`).
- `parser_clear` is not invoked from init.asm — parser state is zero-init by the centralised LDIR fill at stage 1; the field-by-field reset that `parser_clear` performs is equivalent at boot.

**From Story 1.11:**
- `src/render.asm` owns `render_init`, `render_full`, `render_diff`. All three are invoked across `init_cold_start` and `init_teardown`. AR13 holds.
- The `BIOS_CONOUT_OVERRIDE` mechanism (added to `inc/bios.inc` by Story 1.11) is consumed by the new `init_cold_start-state-shape.asm` headless test in this story.
- The Story 1.11 deferral on `render_emit_goto` D/E preservation is EVALUATED on hardware in AC14; if the smoke surfaces a regression, the dev applies the defensive-scratch fix in this story.
- The Story 1.11 deferral on iterative scroll cost is irrelevant to this story (no large-file scroll in the smoke).

### Git intelligence

Eleven commits on `main` after Story 1.0 (most-recent first per `git log`):

- `dc2dd0d` — story 1.11: Wrote the screen renderer: dirty-row diff, scroll, Ctrl-L full redraw, status row.
- `e9f291a` — story 1.10: Wrote the command parser: counts, pending operators, and the gg motion-prefix.
- `6084103` — story 1.9: Wrote the key dispatcher: binary-searches a per-mode table to find the handler.
- `5f5577e` — story 1.8: Wrote the input layer; tells Esc from arrows in ~40ms, with putback.
- `11a4560` — story 1.7: Wrote the gap buffer (insert, delete, move, load stub) with headless tests.
- (earlier stories continue further back in `git log`)

Conventions visible in the tree (preserve in Story 1.12):
- 4-space indentation, UPPERCASE mnemonics, `;` line / `;;` section comments (AR24).
- AR23 header blocks on every `.asm` and `.inc` file. The new `src/init.asm` follows the same shape.
- Every public routine and internal helper has the `In:` / `Out:` / `Trashes:` / `Calls:` four-line contract (AR23).
- One story per commit; short imperative subject + colon-separated context. Match the user's plain-English style.

Suggested commit message for Story 1.12 (when the dev finishes): `story 1.12: Wired init/teardown, the main input loop, and the first on-hardware smoke test.` Match the prior stories' "Wrote the gap buffer" / "binary-searches a per-mode table" / "dirty-row diff, scroll, Ctrl-L full redraw" plain-English style.

### Testing requirements

Story 1.12's testing requirements split into three categories — the third (hardware UAT) is the story's defining contribution:

**Build-time / static:**

1. `make` from project root succeeds (NFR14 / AC18).
2. `make clean && make` produces byte-identical `vibe.com` across two consecutive runs (NFR18 / AC18). Capture both SHAs in Debug Log References.
3. `make sizes` reports the code-section size (NFR9 baseline / AC13 / AC18). Capture verbatim.
4. `grep -rnE 'BIOS_CONOUT' src/ | grep -v 'render.asm'` zero matches (AR13 / AC10 / AC18).
5. `grep -nE 'gapbuf_(insert|delete|move_gap|load)' src/init.asm` zero matches (AR14 / AC11 / AC18).
6. `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/init.asm` zero matches (AR15 / AC12 / AC18).
7. `grep -nE 'BDOS_CALL' src/init.asm` exactly one match — the `BDOS_CALL BDOS_EXIT` in init_teardown (AR15 / AC12).

**Headless test cases:**

8. `init_cold_start-state-shape.asm` — pre-poison state.inc, install BIOS_CONOUT capture, call init_cold_start, inspect post-state shape (mode_byte, cursor_offset, gap_start, gap_end, top_line_offset, dirty_rows, shadow_buffer[0], status_dirty, input_held_flag, parser-state fields). At least 10 subtests.
9. **Live baseline becomes at least 23 pass / 1 fail** (22 pre-1.12 + 1 new init test + the deliberate `harness_fail`). Larger if the dev writes additional init tests.

**Hardware UAT (the defining contribution of this story):**

10. SLIDE-push and launch from CCP (AC14 / Task 11 Step 3).
11. Mode-transition smoke (AC14 / Task 11 Step 4): 'i', Esc, ':', Esc, 'v', Esc, '/', Esc, Ctrl-L.
12. Unbound-key smoke (AC14 / Task 11 Step 5): '!', 'q', 'z', 'x', '~', '*' all surface "unbound key" without state change.
13. Esc-disambig smoke (NFR4 / AC15 / Task 11 Step 6): bare-Esc 10x, arrow keys 4x.
14. Sustained-typing smoke (NFR5 / AC14 / Task 11 Step 7): 30 seconds of arbitrary keys without crash, terminal corruption, stuck cursor; Ctrl-L midway restores clean.
15. Debug-quit smoke (AC14 / Task 11 Step 8): Ctrl-Q clears screen + returns to CCP in clean state.
16. Re-launch smoke (Task 11 Step 9): re-running `vibe` produces a clean editor (no boot residue from prior run).

### Project Structure Notes

After Story 1.12 the source tree is:

```
src/
├── vibe.asm        # Top-level — ORG 0x0100 + JP init_cold_start, input_loop body wired
├── init.asm        # Story 1.12 — NEW (cold-start zero-init + sub-system init + main-loop fall-through;
│                   #                   teardown ESC-J + warm-boot via BDOS function 0)
├── input.asm       # Story 1.8 (unchanged)
├── statusln.asm    # Story 1.5 / 1.11 (unchanged by 1.12)
├── gapbuf.asm      # Story 1.7 (unchanged by 1.12)
├── render.asm      # Story 1.11 (unchanged by 1.12)
├── dispatch.asm    # Story 1.9 — Story 1.12 re-points mode_debug_quit at init_teardown
└── parser.asm      # Story 1.10 (unchanged by 1.12)

inc/
├── equates.inc     # Story 1.2 (unchanged by 1.12)
├── bios.inc        # Story 1.4 / 1.11 — Story 1.12 confirms W1 placeholders (or updates them)
├── bdos.inc        # Story 1.4 (unchanged by 1.12)
├── modes.inc       # Story 1.2 (unchanged by 1.12)
├── vt52.inc        # Story 1.2 (unchanged by 1.12)
└── state.inc       # Story 1.3 (unchanged by 1.12 — Story 1.3 deferral resolved by init.asm's LDIR fill, not by a state.inc edit)

test/
├── README.md
├── Makefile
├── inc/
│   ├── test_prologue.inc
│   ├── test_epilogue.inc
│   ├── test_input_loop_stub.inc
│   └── test_bios_conout_capture.inc
├── cases/
│   ├── ... (Story 1.6/1.7/1.9/1.10/1.11 cases unchanged)
│   └── init_cold_start-state-shape.asm  # Story 1.12 — NEW
├── fixtures/
│   └── hello.txt
└── smoke/
    ├── bdos_call_smoke.asm
    └── statusln_smoke.asm

Makefile                # Story 1.1 — Story 1.12 wires the `sizes:` rule for real
```

Architecture's reference layout (architecture.md lines 1278-1340) anticipates `src/init.asm` between `src/vibe.asm` and `src/input.asm` per AR25; Story 1.12 realises this ordering. The full AR25 sequence (`init → input → statusln → gapbuf → render → dispatch → parser → ...`) is now physically present in `src/vibe.asm`'s INCLUDE block.

### Files created and modified by this story

**Files created:**
- `src/init.asm` (new — primary deliverable).
- `test/cases/init_cold_start-state-shape.asm` (new — headless state-shape test).

**Files modified:**
- `src/vibe.asm` — replace `RET` at `0x0100` with `JP init_cold_start`; insert `INCLUDE "init.asm"` as the first source INCLUDE per AR25; rewrite `input_loop:` body with the real `input_get_key → dispatch_key → render_diff → repeat`; update header `Dependencies:` and the AR25 comment blocks above each src/ INCLUDE.
- `src/dispatch.asm` — replace `mode_debug_quit` body with `JP init_teardown`; update routine contract; update header `Dependencies:` to add `src/init.asm`.
- `inc/bios.inc` — confirm (or update) BIOS jump-table placeholder addresses per AC8 (W1 resolution).
- `Makefile` — wire `sizes:` rule for real per-section size reporting (AC13).
- `_bmad-output/implementation-artifacts/deferred-work.md` — mark Story-1.3 / 1.4 / 1.8 deferrals resolved; update Story-1.10 / 1.11 deferrals per AC20.

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md] lines 781-846
- Adjacent story (render pipeline, Story 1.11 — previous; structural prior art for module headers, AR-grep enforcement, deferred-work resolution, hardware UAT planning): [Source: _bmad-output/implementation-artifacts/1-11-render-pipeline-with-dirty-rows-scroll-ctrl-l.md]
- Adjacent story (ex command-line + :q / :q!, Story 2.1 — next; removes the Ctrl-Q debug-quit, lands the proper vi exit): [Source: _bmad-output/planning-artifacts/epics.md] lines 852-901
- Adjacent story (file load + launch with filename arg, Story 2.3 — next; lands the real FCB → filename_buffer → fileio_load chain that Story 1.12's FCB-skip explicitly defers): [Source: _bmad-output/planning-artifacts/epics.md] lines 953-991
- RI2 (render runs after each input-loop iteration; no periodic timer): [Source: _bmad-output/planning-artifacts/architecture.md] lines 567-569
- RI4 (cursor-positioning emission last in every render pass): [Source: _bmad-output/planning-artifacts/architecture.md] lines 575-579
- RI5 (Esc-disambiguation pattern): [Source: _bmad-output/planning-artifacts/architecture.md] lines 581-619
- RI6 (single input_get_key → dispatch loop): [Source: _bmad-output/planning-artifacts/architecture.md] lines 621-624
- MC1 (caller-saved everywhere): [Source: _bmad-output/planning-artifacts/architecture.md] lines 472-476
- MC4 (handler signature: A = key just consumed, accumulator state in fixed addresses): [Source: _bmad-output/planning-artifacts/architecture.md] lines 529-533
- MC5 (status-message funnel — status_set_message): [Source: _bmad-output/planning-artifacts/architecture.md] lines 535-541
- MC6 (checked-BDOS-call macro — BDOS_CALL): [Source: _bmad-output/planning-artifacts/architecture.md] lines 543-548
- MC7 (static memory map via state.inc): [Source: _bmad-output/planning-artifacts/architecture.md] lines 550-555
- Data Flow (Keystroke Lifecycle — step 6 = render_diff fires after handler returns): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1468-1505
- Module Dependency Graph (init.asm's role in the cold-start + teardown chain): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1401-1450
- External Boundaries (Termination = BDOS function 0 = warm boot, owned by init.asm + exline.asm): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1457-1463
- Implementation Sequence (init.asm bring-up step 1): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1559-1579
- Watchpoint W1 (BIOS jump-table placeholder addresses, init.asm bring-up confirms): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1635-1639
- FR1 (editor lifecycle — init/teardown): [Source: _bmad-output/planning-artifacts/epics.md] line 17 (PRD §FR1 — implicit; FR2 — launch with filename arg is Story 2.3)
- FR12-FR16 (mode transitions — exercised on hardware): [Source: _bmad-output/planning-artifacts/epics.md] lines 31-40
- FR47 / FR48 (render): [Source: _bmad-output/planning-artifacts/epics.md] lines 93-94
- FR50 (unsupported-command no-op — exercised on hardware): [Source: _bmad-output/planning-artifacts/epics.md] line 99
- NFR3 (cursor-motion latency — boot-time cost exempt): [Source: _bmad-output/planning-artifacts/prd.md] lines 820-824
- NFR4 (Esc 1-2 tick window — exercised on hardware): [Source: _bmad-output/planning-artifacts/epics.md] line 110
- NFR5 (no crashes — sustained typing smoke): [Source: _bmad-output/planning-artifacts/epics.md] line 114
- NFR7 (screen-state recoverable — Ctrl-L smoke): [Source: _bmad-output/planning-artifacts/epics.md] line 116
- NFR9 (code budget — make sizes baseline): [Source: _bmad-output/planning-artifacts/epics.md] line 121
- NFR10 (TPA fit): [Source: _bmad-output/planning-artifacts/epics.md] line 122
- NFR11 (single .COM artifact): [Source: _bmad-output/planning-artifacts/epics.md] line 123
- NFR13 (single platform target — Feersum MicroBeast): [Source: _bmad-output/planning-artifacts/epics.md] line 128
- NFR14 (sjasmplus 1.23.0): [Source: _bmad-output/planning-artifacts/epics.md] line 129
- NFR15 (CP/M 2.2 BDOS only): [Source: _bmad-output/planning-artifacts/epics.md] line 130
- NFR16 (knob centralization): [Source: _bmad-output/planning-artifacts/epics.md] line 134
- NFR18 (reproducible build): [Source: _bmad-output/planning-artifacts/epics.md] line 136
- AR11 (state.inc static memory map): [Source: _bmad-output/planning-artifacts/epics.md] line 157
- AR12 (status-message funnel): [Source: _bmad-output/planning-artifacts/epics.md] line 161
- AR13 (single screen-emission path — render.asm only; init.asm carve-out retired): [Source: _bmad-output/planning-artifacts/epics.md] line 162; [Source: _bmad-output/planning-artifacts/architecture.md] lines 1442-1446
- AR14 (single buffer-mutation owner — gapbuf.asm only): [Source: _bmad-output/planning-artifacts/epics.md] line 163
- AR15 (single BDOS gateway — BDOS_CALL macro): [Source: _bmad-output/planning-artifacts/epics.md] line 164
- AR21 (headless coverage scope — UAT excluded for end-to-end editing journeys): [Source: _bmad-output/planning-artifacts/epics.md] line 173
- AR22 (naming): [Source: _bmad-output/planning-artifacts/epics.md] line 177
- AR23 (file structure and routine contracts): [Source: _bmad-output/planning-artifacts/epics.md] line 178
- AR24 (format conventions): [Source: _bmad-output/planning-artifacts/epics.md] line 179
- AR25 (module include order — init first after ORG 0x0100): [Source: _bmad-output/planning-artifacts/epics.md] line 180; [Source: _bmad-output/planning-artifacts/architecture.md] lines 920-956
- BA1 (output path = vibe.com at project root): [Source: _bmad-output/planning-artifacts/architecture.md] lines 628-631
- BA2 (sjasmplus invocation flags — deterministic, NFR18-compliant): [Source: _bmad-output/planning-artifacts/architecture.md] lines 633-651
- BA3 (Make recursion — `sizes` per-section size from listing): [Source: _bmad-output/planning-artifacts/architecture.md] lines 654-659
- BH5 (`:q` with unsaved changes — refuse; `:q!` abandons): [Source: _bmad-output/planning-artifacts/architecture.md] lines 699-702 (relevant context for Story 2.1 follow-up)
- inc/state.inc layout (static_data_base, static_end, GAP_BUFFER_BASE, yank_end): [Source: inc/state.inc] lines 37, 100, 106, 115
- inc/equates.inc (ESC_TIMEOUT_TICKS, SCREEN_ROWS, etc.): [Source: inc/equates.inc] lines 42-50
- inc/modes.inc (MODE_NORMAL=0, KEY_ARROW_*): [Source: inc/modes.inc] lines 23-26, 39-42
- inc/bios.inc (W1 placeholders — to be confirmed): [Source: inc/bios.inc] lines 33-34, 45, 76
- inc/bdos.inc (BDOS_CALL macro, BDOS_EXIT=0): [Source: inc/bdos.inc] lines 35, 83-88
- src/vibe.asm (ORG 0x0100 + RET stub being replaced; input_loop body being rewritten; AR25 comment blocks being swept): [Source: src/vibe.asm] lines 38-43, 105-108, 45-93
- src/dispatch.asm (mode_debug_quit body being repointed): [Source: src/dispatch.asm] lines 341-343
- src/statusln.asm (status_set_message, msg_mode_normal, bdos_error_funnel + JP input_loop): [Source: src/statusln.asm] lines 74-96, 170, 127-133
- src/input.asm (input_get_key — RI5 disambig): [Source: src/input.asm] lines 69-114
- src/gapbuf.asm (gapbuf_init — SR2 establishing entry): [Source: src/gapbuf.asm] lines 55-62
- src/render.asm (render_init, render_full, render_diff — Story 1.11 entries): [Source: src/render.asm] lines 179-211, 309 et seq, 353 et seq
- src/dispatch.asm (dispatch_normal/insert/command/visual + DISPATCH_*_COUNT): [Source: src/dispatch.asm] lines 443, 522, 529, 536, 520, 527, 534, 541
- Story 1.11 (render pipeline — prior art for module structure, AR enforcement, deferred-work resolution, hardware UAT planning): [Source: _bmad-output/implementation-artifacts/1-11-render-pipeline-with-dirty-rows-scroll-ctrl-l.md]
- Story 1.10 (parser — structural prior art for AR23 contract blocks, tail-JP idioms, test scaffold INCLUDE order): [Source: _bmad-output/implementation-artifacts/1-10-command-parser-count-pending-operator-motion-prefix.md]
- Story 1.8 (input layer — RI5 / NFR4 source-of-truth for the Esc/arrow disambig the hardware smoke exercises): [Source: _bmad-output/implementation-artifacts/1-8-input-layer-with-esc-arrow-disambiguation.md]
- Story 1.3 (state.inc — Story-1.3 deferral on zero-init resolved by this story): [Source: _bmad-output/implementation-artifacts/1-3-static-memory-map-state-inc.md]; deferred-work.md line 17
- Deferred-from-1.4 (BIOS_TICK_ADDR overlap): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 27
- Deferred-from-1.8 (input_held_flag uninitialised at boot; tick_wait_one EI clobber): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 58, 60-61
- Deferred-from-1.10 (mode-transition / unbound-key parser-state-clear): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 75-76

## Dev Agent Record

### Agent Model Used

Claude Opus 4.7 (1M context). The `bmad-dev-story` skill (vibe project install).

### Debug Log References

**Build invariants (NFR14 / NFR18 — AC18, 2026-05-13):**
- Two consecutive `make clean && make` runs produce byte-identical `vibe.com`.
- SHA256 (initial, pre-W1 patch): `5242beffeb44a7afa1c18091ac53370ac60a2b2832f1e8a790e5b56449f80ae6`.
- SHA256 (after W1 address corrections): `4c750d266066d18b78093c7e13ebf9efd25a0354f829a501f22e594bfa636201`.
- SHA256 (after Option-A tick-ISR install): `630d44e546dcad4e256ea0b19ace15c238b27744937f7b6b43813b887f657ffe`.
- SHA256 (no-ISR diagnostic — never expected to pass UAT alone): `bbe412b7e8620021d4689e8a4386375485866c7e385fbbfee352f4636baa4c85`.
- SHA256 (after VT52 clear-screen + D/E preservation fixes — UAT iteration 2 passed): `d4c872e5ce3a2a3c5dad00ec831e92e5c42666458c572ba0a946cafa18157283`.
- SHA256 (final, production ISR + `tick_wait_one` body restored — UAT iteration 3 passed): `027bb92a5c473cb177e78fe6f13d03fd45f4b471a81f2b7c6718c1f153eec18d`.

**Code-section size baseline (NFR9 — AC13, 2026-05-13):**
- `make sizes` output (final, post-UAT):
  - `code_section: 1945 bytes (~63% of NFR9 ~3 KB budget)`
- Source: `awk` parse of `build/vibe.lst` for `static_data_base EQU` line; subtracts 0x0100 from the resolved address.
- Δ across the full Story-1.12 arc: 0 → 1945 bytes (Story 1.5's `RET` stub at 0x0100 became the real editor; total budget consumed = 1945 / 3072 ≈ 63%).

**AR enforcement sweeps (AC10 / AC11 / AC12 / AC18 — 2026-05-13):**
- AR13 `grep -nE 'BIOS_CONOUT' src/*.asm | grep -v 'render.asm'` — zero matches.
- AR14 `grep -nE 'gapbuf_(insert|delete|move_gap|load)' src/init.asm` — zero matches.
- AR15 raw form `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/init.asm` — zero matches.
- AR15 macro form `grep -nE 'BDOS_CALL' src/init.asm` — exactly one match: `297:    BDOS_CALL BDOS_EXIT` inside `init_teardown`.

**Headless test baseline (AR21 / AC16 — 2026-05-13):**
- `make -C test test`: `23 pass, 1 fail` (the deliberate `harness_fail`; new `init_cold_start-state-shape` passes; pre-1.12 baseline was 22 pass / 1 fail).
- Live count: 22 pre-1.12 passes + 1 new `init_cold_start-state-shape` + 1 deliberate `harness_fail` = 24 total, 23 pass.

**W1 BIOS jump-table confirmation (AC8 — RESOLVED via vendor header, 2026-05-13):**
- Vendor reference: `src/bios_1_7.inc` (MicroBeast BIOS 1.6+ jump-table + MicroBeast-specific routines).
- Architecture's earlier placeholders were off by a full 4 KB AND CONIN / CONIST slots were swapped:
  - `BIOS_CONIN`: 0xFA06 → **0xEA09** (slot was wrong AND base was wrong).
  - `BIOS_CONINST`: 0xFA09 → **0xEA06** (slot was wrong AND base was wrong).
  - `BIOS_CONOUT`: 0xFA0C → **0xEA0C** (slot right; base off by 4 KB).
- `inc/bios.inc` now defines `BIOS_START EQU 0xEA00` and derives CONINST / CONIN / CONOUT as `BIOS_START + 0x06 / 0x09 / 0x0C` — matches the vendor `BIOS_BOOT / WBOOT / CONIST / CONIN / CONOUT` layout.
- Tick counter: no BIOS-managed counter exists at any documented address. Resolved via Option A — VIBE installs a 60 Hz user ISR via `MBB_SET_USR_INT` (vendor `0xFDC7`); see Completion Notes below.

**Hardware UAT (AC14 / AC15 — PASS, 2026-05-13):**

Three iterations on hardware:

- **Iteration 1** (SHA `630d44e5…f657ffe`, software-side build with ISR + production tick_wait_one): screen does NOT clear; cursor jumps to random screen positions; mode banners surface as scattered `-` / `--` fragments at random bottom-row positions; cannot reach Ctrl-Q exit cleanly (its emits corrupted same way); reboot required to regain control.
- **Iteration 2** (SHA `d4c872e5…18157283`, diagnostic build with ISR install/uninstall + `tick_wait_one` stubbed, plus the two render fixes — see Completion Notes): screen clears at launch; cursor at top-left; `i` → "-- insert --" at row 24; Esc → blank; `:` / `v` / `/` all surface their banners coherently; unbound keys surface "unbound key"; Ctrl-Q exits cleanly.
- **Iteration 3** (SHA `027bb92a…f153eec18d`, ISR + production `tick_wait_one` restored — final): all Iteration 2 outcomes hold; bare Esc transitions to NORMAL within the 2-tick window; **arrow-after-Esc in INSERT stays in INSERT** (confirms the tick disambig is doing its job — without disambig, the editor would have left INSERT on Esc); arrow keys in NORMAL surface "unbound key" as expected (Epic 2 binds h/j/k/l); 30 s sustained typing leaves no debris; back-to-back `vibe` invocations both come up clean (init_teardown's ISR-uninstall is solid).

**Two bugs were promoted from deferred-work to patches during the UAT:**

1. **VT52 ESC J is "erase to end of screen", NOT "clear whole screen".** The architecture's earlier `VT52_CLEAR_SCREEN EQU 'J'` naming reinforced the mistake. Fix: renamed equate to `VT52_ERASE_TO_EOS` with a comment-block warning that the whole-screen clear requires `ESC H` + `ESC J`; `render_init` now emits ESC H (home) before ESC J (erase from home onward), and drops the now-redundant trailing ESC Y home.
2. **`render_emit_goto` D/E preservation deferral (Story 1.11, deferred-work line 67), promoted from "pending hardware UAT" to a resolved patch.** Hardware confirmed the latent risk: MicroBeast BIOS_CONOUT trashes D or E (or both) across the call, so every ESC Y emitted by `render_emit_goto` arrived with garbled row/col bytes — every render run landed at a random position. Fix (the Story-1.11 deferral patch): biased row/col now live in two file-local scratch cells (`render_goto_row` / `render_goto_col`) across the four emit_byte calls; the BIOS may now trash any register at will without breaking the ESC Y composition. Cost: +10 bytes.

### Completion Notes List

**Software side complete (2026-05-13):**

- `src/init.asm` (NEW, ~290 lines including AR23 header) defines `init_cold_start` (6 stages: LDIR-fill `static_data_base..static_end` with 0x00 → `gapbuf_init` (SR2) → `render_init` (clear / shadow / cursor home) → `status_set_message msg_mode_normal` (AR12 funnel for the empty NORMAL banner) → `render_full` (initial frame) → `JP input_loop`) and `init_teardown` (3 stages: `render_init` clears the screen → `BDOS_CALL BDOS_EXIT` warm-boots → defensive `RET`).
- `src/vibe.asm` rewritten: `JP init_cold_start` at `0x0100` replaces the Story-1.5 `RET` stub; `INCLUDE "init.asm"` lands as the first source-code INCLUDE per AR25; `input_loop:` body becomes the real main loop (`input_get_key` → per-mode demultiplex → `dispatch_key` → `render_diff` → `JP input_loop`); every AR25 comment block above each src/ INCLUDE updated; header `Dependencies:` adds `src/init.asm` first.
- `src/dispatch.asm` `mode_debug_quit` body becomes `JP init_teardown`; routine contract + purpose comment updated; header `Dependencies:` adds `src/init.asm`.
- `Makefile` `sizes:` rule wired: `awk`-parses `build/vibe.lst` for the `static_data_base EQU` line, subtracts 0x0100, prints `code_section: <N> bytes (~<%>% of NFR9 ~3 KB budget)`. Picked the listing-parse form over `wc -c vibe.com` for semantic clarity (measures code, not "everything emitted").
- `test/cases/init_cold_start-state-shape.asm` (NEW, ~270 lines): pre-poisons the static block with 0xAA, installs the `BIOS_CONOUT_OVERRIDE` capture stub, defines a local `input_loop:` verifier (so init's `JP input_loop` falls through to state-shape inspection), and runs 12 subtests covering `mode_byte`, `cursor_offset`, `gap_start`, `gap_end`, `top_line_offset`, `dirty_rows[0..2]`, `shadow_buffer[0]`, `status_dirty`, `input_held_flag`, `pending_operator`, `pending_motion_prefix`, `count_accumulator`. All 12 subtests pass.
- AR13 / AR14 / AR15 enforcement: comments in init.asm originally mentioned `BIOS_CONOUT`, `gapbuf_insert/delete/move_gap`, and `CALL 0x0005` / `CALL BDOS_ENTRY` / `BDOS_CALL` literally; per AC10 / AC11 / AC12 / AC18 the AR-grep sweeps return zero matches (or exactly one for the BDOS_CALL code line), so the prose was reworded to use natural-language equivalents ("BIOS console-out entry", "gap-buffer mutators (insert/delete/move-gap entries)", "the BDOS gateway macro", "raw call to the BDOS entry vector") that satisfy both human readers and the literal AR greps.
- Resolved deferrals in `deferred-work.md`: Story 1.3 zero-init (LDIR fill at cold-start stage 1), Story 1.8 `input_held_flag` uninit-at-boot (covered by the centralised LDIR). Evaluated and still-deferred: Story 1.8 `tick_wait_one` EI clobber (benign in 1.12's context — CP/M warm-boot leaves IFF enabled), Story 1.10 mode-transition / unbound-key parser-state-clear (deferred to Story 2.5+ — invisible at user level until motions land). Pending hardware run: Story 1.4 `BIOS_TICK_ADDR` overlap (rides on AC8), Story 1.11 `render_emit_goto` D/E preservation (rides on AC14).

**W1 BIOS confirmation (Task 8 / AC8) — RESOLVED (2026-05-13):**

User dropped `src/bios_1_7.inc` (vendor MicroBeast BIOS 1.6+ jump-table reference). Three address corrections + one structural change applied:

- Console-vector addresses patched in `inc/bios.inc`: the architecture's earlier placeholders had CONIN / CONIST slots swapped AND the base off by a full 4 KB (FA00 → real EA00). `inc/bios.inc` now uses `BIOS_START EQU 0xEA00` with derived `+0x06 / +0x09 / +0x0C` slots matching the vendor layout.
- No BIOS-managed tick counter exists. Resolved via Option A — VIBE installs its own 60 Hz user ISR via `MBB_SET_USR_INT` (vendor `0xFDC7`):
  - `src/input.asm` gained `input_tick_isr` (10-byte routine in the public interface — the BIOS swaps the shadow register set in via EXX before calling, so HL is the shadow set; no register save needed).
  - `inc/state.inc` gained `input_tick_counter` (16-bit) as the cross-module counter — written by the ISR, read by `tick_wait_one`.
  - `src/init.asm` gained ISR install/uninstall stages: stage 0 (cold-start) defensively uninstalls any pre-existing ISR before the LDIR fill (the vendor warns user ISRs survive warm reboots but their TPA memory does not); stage 2 installs `input_tick_isr` after the LDIR; teardown stage 1 uninstalls before the BDOS warm-boot.
  - `BIOS_TICK_ADDR` retired from `inc/bios.inc`; `tick_wait_one` reads `input_tick_counter` directly.
  - Rate is 60 Hz (vendor doc says "every 60th of a second" — not the 50 Hz the architecture originally assumed). `ESC_TIMEOUT_TICKS = 2` ≈ 33 ms, still inside NFR4's 20-40 ms target; `inc/equates.inc` comment updated.
  - Test override: `MBB_SET_USR_INT_OVERRIDE` (mirrors the Story-1.11 `BIOS_CONOUT_OVERRIDE` pattern). `test/cases/init_cold_start-state-shape.asm` defines a bare-RET stub so the iz-cpm headless build does not crash on the production address (which iz-cpm does not emulate).

Net build impact: `vibe.com` grew from 1903 → 1929 bytes (+26 bytes, still 62% of NFR9 ~3 KB budget). New SHA `630d44e546dcad4e256ea0b19ace15c238b27744937f7b6b43813b887f657ffe`, byte-identical across two clean rebuilds. AR13 / AR14 / AR15 sweeps clean; `make -C test test` reports 23 pass / 1 fail (deliberate).

**Hardware UAT (Task 11 / AC14 / AC15) — PASS (2026-05-13):**

Three iterations on hardware; see Debug Log References § Hardware UAT for the per-iteration outcomes. Net: final build (SHA `027bb92a…f153eec18d`) passes the full AC14 / AC15 checklist — screen clears at launch, mode banners coherent at row 24, unbound keys surface "unbound key", Ctrl-L redraws cleanly, Ctrl-Q exits to a clean CCP prompt, bare Esc transitions within the 2-tick (~33 ms) window, VT52 arrow sequences synthesise correctly (arrow-in-INSERT stays in INSERT), 30 s sustained typing leaves no debris, and back-to-back `vibe` invocations come up clean (init_teardown's ISR-uninstall works).

### File List

**Files created:**
- `src/init.asm`
- `test/cases/init_cold_start-state-shape.asm`

**Files modified:**
- `src/vibe.asm` (ORG 0x0100 entry; first INCLUDE per AR25; main input-loop body; header + comment-block sweeps)
- `src/dispatch.asm` (`mode_debug_quit` body + contract + header Dependencies)
- `src/input.asm` (W1 / Option A: `input_tick_isr` routine added; `tick_wait_one` now reads `input_tick_counter`; header Public + Dependencies updated)
- `src/init.asm` (W1 / Option A: stage 0 / 2 ISR install/uninstall in cold-start; stage 1 ISR uninstall in teardown; header Public + Dependencies updated; stage numbering shifted)
- `inc/bios.inc` (W1: addresses corrected to BIOS_START + offsets pattern; MBB_SET_USR_INT added with IFNDEF override; BIOS_TICK_ADDR retired; header Public / State / Purpose updated)
- `inc/state.inc` (`input_tick_counter` field added to the 16-bit block)
- `inc/equates.inc` (`ESC_TIMEOUT_TICKS` comment updated 50 → 60 Hz; ~4.3 s wrap note)
- `test/cases/init_cold_start-state-shape.asm` (`MBB_SET_USR_INT_OVERRIDE` stub for iz-cpm; test still passes)
- `Makefile` (`sizes:` rule wired; preceding comment-block updated)
- `inc/vt52.inc` (renamed `VT52_CLEAR_SCREEN` → `VT52_ERASE_TO_EOS` after the UAT surfaced that ESC J alone is "erase to end of screen", not a full clear)
- `src/render.asm` (UAT bug fixes: `render_init` now emits ESC H + ESC J for the full clear; `render_emit_goto` holds biased row/col in two new file-local scratch cells defensive against BIOS_CONOUT D/E clobber)
- `_bmad-output/implementation-artifacts/deferred-work.md` (resolution / evaluation notes on Story-1.3 / 1.4 / 1.8 / 1.10 / 1.11 entries)
- `_bmad-output/implementation-artifacts/sprint-status.yaml` (1-12 → in-progress; `last_updated` note)
- `_bmad-output/implementation-artifacts/1-12-init-teardown-on-hardware-smoke-test.md` (status; task checkboxes; Dev Agent Record)

**Files added (vendor reference, not built):**
- `src/bios_1_7.inc` (MicroBeast BIOS 1.6+ jump-table + MicroBeast-specific routines — dropped in by the user during W1 confirmation; vendor authoritative reference for `inc/bios.inc` symbol values)

### Change Log

- 2026-05-13 — Software side of Story 1.12 landed: `src/init.asm` (cold-start LDIR-fill + sub-system init chain + fall-through to input_loop; teardown via render_init + BDOS gateway macro) and `test/cases/init_cold_start-state-shape.asm` created; `src/vibe.asm` rewired (JP init_cold_start at 0x0100; INCLUDE init.asm first per AR25; real main input-loop body); `src/dispatch.asm` re-points `mode_debug_quit` at `init_teardown`; `Makefile` `sizes:` rule wired for NFR9 audit. Two clean rebuilds byte-identical (SHA `5242beff…f80ae6`); 23 pass / 1 deliberate fail across the headless suite; AR13 / AR14 / AR15 sweeps clean.
- 2026-05-13 — W1 BIOS jump-table confirmation against vendor `src/bios_1_7.inc`: architecture's earlier placeholders were off by a full 4 KB (0xFA00 → real 0xEA00) AND CONIN / CONIST slots were swapped. `inc/bios.inc` corrected with `BIOS_START EQU 0xEA00` + derived offsets; SHA → `4c750d26…fa636201` (still 1903 bytes).
- 2026-05-13 — W1 tick-counter resolution via Option A: no BIOS-managed counter exists; VIBE installs its own 60 Hz user ISR via `MBB_SET_USR_INT`. `src/input.asm` gained `input_tick_isr` (10 bytes) + state.inc-resident `input_tick_counter`; `src/init.asm` gained cold-start stage-0 uninstall + stage-2 install + teardown stage-1 uninstall; `BIOS_TICK_ADDR` retired; `inc/equates.inc` ESC_TIMEOUT_TICKS comment updated 50 → 60 Hz; test override `MBB_SET_USR_INT_OVERRIDE` added. Two clean rebuilds byte-identical (SHA `630d44e5…f657ffe`); size 1929 bytes (+26, still 62% of NFR9 budget); 23 pass / 1 fail.
- AC8 RESOLVED (W1 confirm + tick-counter resolution). AC14 / AC15 hardware UAT pending the dev's hardware run.
- 2026-05-13 — Hardware UAT iteration 1 (SHA `630d44e5…f657ffe`): catastrophic failure — screen does not clear, cursor jumps randomly, mode banners scatter as `-` / `--` fragments at random positions, cannot exit cleanly. Two root causes diagnosed: (a) VT52 ESC J is "erase to end of screen", not "clear whole screen" — needs ESC H + ESC J for full clear; (b) MicroBeast BIOS_CONOUT trashes D or E (or both) across the call, garbling every `render_emit_goto` ESC Y sequence.
- 2026-05-13 — Iteration 2 (SHA `d4c872e5…18157283`): diagnostic build with ISR install/uninstall + `tick_wait_one` stubbed (to isolate any ISR-related issues), plus two render fixes — `inc/vt52.inc` renamed `VT52_CLEAR_SCREEN` → `VT52_ERASE_TO_EOS` and `render_init` emits ESC H + ESC J; `render_emit_goto` holds biased row/col in two new file-local scratch cells (`render_goto_row` / `render_goto_col`) defensive against BIOS D/E clobber. Hardware UAT: screen clears, mode banners coherent at row 24, unbound keys correct, Ctrl-Q clean exit. The ISR was not the cause — it was a coincidence.
- 2026-05-13 — Iteration 3 (SHA `027bb92a…f153eec18d`): ISR install/uninstall + production `tick_wait_one` body restored. Hardware UAT: all Iteration 2 outcomes hold; Esc / arrow disambig works correctly (arrow-after-Esc in INSERT stays in INSERT); 30 s sustained typing clean; back-to-back `vibe` invocations clean. AC14 / AC15 RESOLVED. Story moves to `review`.

### Review Findings

Code review (2026-05-13) — three reviewers: Blind Hunter (diff only), Edge Case Hunter (diff + project), Acceptance Auditor (diff + spec). 13 patches, 3 deferred, 19 dismissed. Decision-needed (DI/EI placement) resolved to "EI after stage 2 ISR install". All 13 patches applied; post-patch rebuild SHA `5e7fb772ba48f4dd39c00bb3fe5dc71a4a3d433c7d00ecac232288c938ddcc6a`, size 1947 B / 63 % of NFR9 budget (+2 B for the DI/EI bracket; ASSERT emits no bytes; the other 11 patches are documentation-only), NFR18 byte-identical second rebuild confirmed, AR13/14/15 grep sweeps clean, 23 pass / 1 deliberate fail. Hardware UAT (AC14 / AC15) was performed on the pre-patch SHA `027bb92a…f153eec18d`; the DI/EI bracket is a tightening (defensive against a stale user-ISR from a prior program firing during the .com-entry-to-Stage-0 window) but the binary did shift by 2 bytes, so the dev should re-run the hardware smoke against the post-patch binary before marking the story `done`.

- [x] [Review][Patch] **DI at `init_cold_start:` entry, `EI` immediately after stage 2 ISR install** — closes the .com-entry-to-stage-0 race window (a stale user-ISR from a prior program firing on its 60 Hz tick during the ~7.5 µs from `JP init_cold_start` to `CALL MBB_SET_USR_INT` with HL=0). Minimal interrupt-disable window (~stage-0 + LDIR + stage-2 ~ 12 ms IFF=0); our 60 Hz ISR starts ticking immediately after `EI`. [src/init.asm:227, 256 — pre-stage-0 `DI`, post-stage-2 `EI`]
- [x] [Review][Patch] **`init_cold_start` header says "Six stages" but body has eight (Stage 0–7)** [src/init.asm:156]
- [x] [Review][Patch] **`init_cold_start` `Calls:` line omits `MBB_SET_USR_INT` (called twice, stages 0 and 2)** [src/init.asm:91, 224]
- [x] [Review][Patch] **`init_teardown` header says "Three stages" but body has four (Stage 1–4)** [src/init.asm:285]
- [x] [Review][Patch] **`init_teardown` `Calls:` line omits `MBB_SET_USR_INT` (stage 1 uninstall)** [src/init.asm:107]
- [x] [Review][Patch] **`render_init` `Calls:` lines still list `render_emit_goto` — body emits ESC H + ESC J via `render_emit_byte` only after the Story-1.12 promoted patch** [src/render.asm:90, 177]
- [x] [Review][Patch] **`input_tick_isr` `Trashes:` claims `F` but body uses only `LD HL,(nn)` / `INC HL` / `LD (nn),HL` / `RET` — none affect F** [src/input.asm:145]
- [x] [Review][Patch] **`init.asm` `State read-only:` block omits `mode_byte`** — AC1 names it; the LDIR-implicit MODE_NORMAL=0 dependency is real (documented under `inc/modes.inc` in `Dependencies:`) and should also surface in `State read-only:` per AR23. [src/init.asm:64–74]
- [x] [Review][Patch] **`src/dispatch.asm` header still describes `mode_debug_quit` as "temporary BDOS_EXIT"; `Mode-change handler` `Calls:` still names `BDOS_CALL BDOS_EXIT`; `Dependencies:` still lists `inc/bdos.inc (BDOS_CALL macro, BDOS_EXIT — for debug-quit)`** — after AC6, mode_debug_quit is `JP init_teardown` with no BDOS expansion in dispatch.asm. [src/dispatch.asm:45, 79, 83]
- [x] [Review][Patch] **`Makefile sizes` target silently no-ops if `awk` pattern misses** — add `END { if (!found) exit 1 }` (set `found = 1` inside the match block) so a future sjasmplus listing-format shift produces a loud failure rather than a 0-byte report. [Makefile:62–67]
- [x] [Review][Patch] **Spec AC16 sub-bullet 8 wording is wrong** — says `status_dirty != 0 (set by msg_mode_normal status_set_message call)`, but `render_full` → `render_diff` clears `status_dirty` after reconciling the status row. The test in `test/cases/init_cold_start-state-shape.asm` correctly asserts `== 0` and Task 10 sub-bullet 8 documents the corrected interpretation. Update AC16 sub-bullet 8 to `status_dirty == 0 (set by status_set_message in stage 5; cleared by render_full → render_diff's status-row emit in stage 7)`. [story spec line ~175]
- [x] [Review][Patch] **Add `ASSERT static_block_size > 1` in `src/init.asm`** — the LDIR uses `LD BC, static_block_size - 1`; a future state.inc shrink to a single byte would turn `BC=0` into 65 536 iterations and zero the address space. One-line guard at the file-local equate. [src/init.asm:147]
- [x] [Review][Patch] **Tighten `tick_wait_one` IFF rationale in `deferred-work.md`** — the "leaves IFF as it found it" phrasing is only equivalent when IFF=1 on entry (the CP/M warm-boot convention). The conclusion ("benign in Story 1.12's context") is correct; the rationale should say "leaves IFF=1 (CP/M warm-boot convention)" to avoid suggesting the code restores prior IFF state. [deferred-work.md:71]
- [x] [Review][Defer] **`MBB_SET_USR_INT` return value ignored at all 3 sites** — vendor doc returns previous ISR address in HL on every call; if install ever fails our 60 Hz tick never advances and the first bare-Esc spins `tick_wait_one` forever (NFR5 risk). Hardware UAT iterations 2 and 3 demonstrated reliable install/uninstall on the target board; defensive check would need a failure-policy decision (banner + refuse to enter loop? install retry? hang acceptable?). [src/init.asm 3 sites] — deferred, no observed failure
- [x] [Review][Defer] **`count_accumulator` first exposed by Story 1.12 input-loop wiring** — production code now reaches `parser_handle_digit` for the first time; with no motion consumers in Epic 1 the count accumulates without user-visible effect (and overflows on the 6th digit per the parser's saturate-or-wrap policy). Sister-finding to the already-deferred "mode transitions don't clear parser state" entries; same Story-2.5+ landing zone. — deferred, parser-state-clear policy lands with Story 2.5
- [x] [Review][Defer] **No `LD SP, ...` in `init_cold_start`** — editor runs on CCP's default stack across the full call chain (input_get_key → dispatch_key binary search → handler → render_diff → render_emit_one_row → render_byte_at_logical). 30 s sustained-typing UAT showed no overflow; a dedicated stack buffer touches state.inc and adds 64–128 bytes. — deferred, no observed overflow

#### Dismissals (kept for the record)

- Blind Hunter's "`render_emit_byte` D/E preservation only fixed in `render_emit_goto`, every other caller still exposed" — verified false positive: `render_emit_one_row` and `render_emit_status_row` save BC + HL across each `CALL render_emit_byte` and recompute DE from memory each iteration; only `render_emit_goto` held coordinates in D/E across the calls, and that's exactly what was patched.
- Blind Hunter's "`mode_debug_quit` `JP init_teardown` narrative is wrong about defensive-RET destination" — verified correct: dispatch_key enters mode_debug_quit via RET-to-pushed-address; top-of-stack at JP-time is `input_loop`'s `CALL dispatch_key` return; init_teardown's defensive RET pops back to input_loop as the comment says ("dispatch_key's caller").
- Blind Hunter's "`VT52_CLEAR_SCREEN` removal breaks out-of-diff consumers" — verified false positive: grep across source confirms no consumers; only BMAD-artifact text references the old name (intentional historical record).
- Acceptance Auditor's "AC2 specifies six stages, body has eight" / "AC3 specifies three stages, body has four" — same root cause as P1 + P3 (doc-vs-code drift); the AC literal vs. the W1-promoted ISR stages. Consolidated into P1 / P3.
- Acceptance Auditor's "render_init no longer matches AC2 stage 3 description (no trailing ESC Y)" — deliberately-promoted-from-deferred patch; sprint-status + Completion Notes + Change Log all document it as the iteration-2 hardware-UAT fix. Spec AC text intentionally not amended (Change Log is the source of truth for promoted patches).
- Acceptance Auditor's "AC4 one-line replacement exceeded by multi-line stack-discipline note" — Task 5 sub-bullet 2 explicitly permits "a brief stack-discipline note"; internal AC contradiction resolved by the Tasks list.
- Acceptance Auditor's "AC22 statusln.asm comment edited despite spec 'unchanged'" — edits are content-correct ("RET stub at 0x0100" → "JP at 0x0100") and AC22 was overstated; entry instruction changed, the comment had to.
- Acceptance Auditor's "AC22 input.asm AR25 chain abbreviated" — editorial; AC22 doesn't require the full chain in every block.
- Acceptance Auditor's "AC2 `Calls:` line adds 'falls through to input_loop' beyond literal" — duplication with `Out:`; editorial.
- Acceptance Auditor's "AC3 `Calls:` line paraphrases `BDOS_ENTRY`" — internal AC tension (AC18 grep requires zero literal `BDOS_ENTRY` matches in init.asm); dev chose the AC18-preserving phrasing. Editorial.
- Edge Case Hunter's "bdos_error_funnel re-entry after init_teardown hangs forever" — predicated on BDOS function 0 returning with sign bit set, which never happens on any CP/M host the editor supports.
- Edge Case Hunter's "render_init reuse in init_teardown wastes shadow LDIR + dirty_rows + top_line_offset writes" — explicitly accepted in init.asm:283–298 as the AR13-single-emit-site trade-off; cost irrelevant at teardown.
- Edge Case Hunter's "Stage 4 `status_set_message` clobbers HL/DE/BC; no inter-stage contract anchor" — each stage is independent by design; no cross-stage register dependencies exist.
- Edge Case Hunter's "input_loop accepts corrupted `mode_byte` as NORMAL silently — no scrub-back" — defensive fall-through to NORMAL is the documented NFR5 shape; scrub-back is over-engineering for a corruption that has no observed source.
- Edge Case Hunter's "render_goto_row/col module-local cells write-before-read fragility under re-entry" — render_emit_goto is not called from any ISR-side code; not a current re-entry hazard.
- Edge Case Hunter's "ISR install/uninstall race in init_cold_start stages 0–2" — between stage 0 (slot cleared with HL=0) and stage 2 (our ISR installed), the user-ISR slot is empty; BIOS dispatches no user-ISR. The DI/EI question (above as the decision-needed) is about the .com-entry-to-stage-0 window, not the inter-stage window.
- Edge Case Hunter's "no DI guard around render_init LDIR vs concurrent ISR firing" — vendor doc affirms BIOS EXX-swaps to shadow set before invoking user-ISR; our ISR uses only shadow HL; main HL across the LDIR is unaffected.
- Edge Case Hunter's "input_tick_counter not in test/cases/init_cold_start-state-shape coverage" — the field lives inside the static-block LDIR range; subtest 9 (input_held_flag) and the test's pre-poison-then-LDIR pattern transitively cover it.
- Edge Case Hunter's "test stubs MBB_SET_USR_INT — install/uninstall path not headlessly exercised" — necessary for iz-cpm (no MicroBeast-specific BIOS); same pattern as Story 1.11's BIOS_CONOUT capture override. Hardware UAT is the integration test.
- Edge Case Hunter's "input_loop has two entry contracts (init fall-through vs bdos_error_funnel JP) but body assumes a common entry" — the funnel's `JP input_loop` re-enters the loop at the top of the next iteration; loop body reads no caller-pushed state.
- Blind Hunter's "init_cold_start Stage 0 narrative misframes threat ('a previous vibe run' vs 'any prior program')" — narrative could be tighter; sub-cosmetic.
- Blind Hunter's "Stage 4 `XOR A` 'non-error code arg' comment opaque" — comment matches AR16's status_set_message contract; not opaque to a reader who knows the convention.
- Blind Hunter's "`init_teardown`'s render_init call carries inert shadow / dirty_rows writes" — same as Edge Case Hunter's parallel finding; explicitly accepted in init.asm narrative.
- Blind Hunter's "`mode_debug_quit`'s Trashes comment understates BIOS clobber risk" — chained trashes are caller-saved per MC1; the trashes line is a contract surface for the IMMEDIATE caller, not a transitive enumeration.
