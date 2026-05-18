# Story 3.3: Visual character mode

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `v` in NORMAL mode to enter visual character mode — with `visual_anchor` pinned at entry, mode-agnostic motions extending the selection, the status row reporting "`-- visual -- N`" where N = |cursor - anchor| + 1, and Esc returning to NORMAL leaving the cursor at the extent,
So that FR15 (visual-mode entry/exit) + FR33 (character-wise selection) close the foundation for visual line (3.4), visual block (3.5), and the visual operators d/y/c/>/</~ (3.6–3.8).

## Acceptance Criteria

**AC1 — `src/visual.asm` is a NEW module sitting between `edits.asm` and `search.asm` in the AR25 INCLUDE chain.**

**Given** `src/vibe.asm` (architecture.md:946 prescribes `edits → visual → search → exline → fileio → undo`; Story 3.1 acknowledged the slot was reserved for visual at vibe.asm:147-148)
**When** I inspect it
**Then** a new line `INCLUDE "visual.asm"` lands between the existing `INCLUDE "edits.asm"` (vibe.asm:149) and `INCLUDE "search.asm"` (vibe.asm:160), with a banner comment naming Story 3.3 and the FR15+FR33 closure
**And** `src/visual.asm` exists with the standard AR23 module header documenting:
- `Public:` block listing the FULL future surface — `visual_enter_char` (Story 3.3; LANDS in this story), `visual_extend` (Story 3.3; LANDS), `visual_enter_line` (Story 3.4; placeholder), `visual_enter_block` (Story 3.5; placeholder), `visual_apply_operator` (Story 3.6+; placeholder). `visual_cancel` is NOT a separate symbol — the existing `enter_normal_mode` in `src/dispatch.asm:276` handles VISUAL→NORMAL cleanly (it already names VISUAL exit in its docstring at line 282; vi-faithful no-op for the AC8 cursor-stays-at-extent semantic).
- `State owned (writes):` — `visual_anchor` (16-bit; written by `visual_enter_char` only; READ by `visual_extend` and by future visual operators). `visual_submode` (1-byte; written by `visual_enter_char` to `VIS_CHAR`; Stories 3.4/3.5 will add VIS_LINE/VIS_BLOCK writers).
- `State read:` — `cursor_offset` (read by `visual_extend` for the count math); `mode_byte` (read by `visual_extend`'s caller — `edits_compose_or_clear` — to decide between `parser_clear` tail vs `visual_extend` tail).
- `Dependencies:` block lists `inc/state.inc`, `inc/modes.inc`, `src/statusln.asm` (for `status_set_message` + the new `msg_mode_visual_prefix` + the relocated `status_u16_to_dec` per Q2 pin), `src/parser.asm` (`parser_clear` tail-JP target).
**And** AR sweeps land clean: `grep -nE 'BIOS_CONOUT|BDOS_CALL|^\s*CALL\s+0x0005' src/visual.asm` returns only doc-comments (zero call sites — AR13/AR15); `grep -nE 'LD\s*\(gap_(start|end)\),' src/visual.asm` returns zero write sites (AR14 — visual.asm is a pure reader of the buffer like `motions.asm` and `search.asm`).

**AC2 — `dispatch_normal['v']` retargets to `visual_enter_char`; the existing `enter_visual_mode` stub body in `src/dispatch.asm` is retired.**

**Given** `src/dispatch.asm:349-357` (the current 9-line `enter_visual_mode` body — `LD A, MODE_VISUAL; LD (mode_byte); LD A, VIS_CHAR; LD (visual_submode); LD HL, msg_mode_visual; XOR A; CALL status_set_message; JP parser_clear`)
**When** Story 3.3 lands
**Then** the entire `enter_visual_mode` body (lines 349-357 + the AR23 docstring block at lines 334-348) is DELETED from `src/dispatch.asm` — the symbol is retired entirely; same shape as Story 3.1's retirement of `mode_search_prompt_stub` when the real `search_begin` arrived in `src/search.asm`
**And** the `dispatch_normal` entry for `'v'` (currently `DEFW enter_visual_mode` at `src/dispatch.asm:583`) is retargeted to `DEFW visual_enter_char` — forward-referenced via sjasmplus's two-pass since `visual.asm` INCLUDEs AFTER `dispatch.asm` in the AR25 chain (same forward-reference shape as Story 3.1's `search_begin` entry at `src/dispatch.asm:486` and Story 3.2's `search_next` entry at line 562)
**And** the `src/dispatch.asm` module-header `Dependencies:` block is extended with a `src/visual.asm` block (parallel to the existing `src/search.asm` block at lines 135-148) documenting that `'v'` now forward-references `visual_enter_char` in the new module and that `enter_visual_mode` was retired
**And** `src/dispatch.asm`'s `enter_normal_mode` docstring at line 282 ("Esc-from-COMMAND and Esc-from-VISUAL arrive here too") stays VERBATIM — no change needed since VISUAL→NORMAL cleanup is unchanged by 3.3

**AC3 — `visual_enter_char` body sets `mode_byte`, `visual_submode`, `visual_anchor`, composes the entry status, and tail-JPs `parser_clear`.**

**Given** `src/visual.asm:visual_enter_char` (the new public entry)
**When** dispatched (control arrives via `dispatch_normal['v']` from NORMAL mode)
**Then** the body performs in order:
1. `LD A, MODE_VISUAL; LD (mode_byte), A` — flip mode (~5 B)
2. `LD A, VIS_CHAR; LD (visual_submode), A` — set sub-mode (~5 B)
3. `LD HL, (cursor_offset); LD (visual_anchor), HL` — pin anchor at the entry cursor (~7 B — the Story-3.3 critical addition that the retired stub did NOT do)
4. `CALL visual_compose_status` — composes "`-- visual -- 1`" into `status_compose_scratch` and tail-CALLs `status_set_message` (~3 B); visual_compose_status is described in AC6
5. `JP parser_clear` — drop any pending count/operator/prefix from before the `v` keystroke (~3 B; AC13 contract from Story 2.5 — every NORMAL→other-mode handler tail-JPs parser_clear; `unbound_visual` at dispatch.asm:426 mirrors this)
**And** total `visual_enter_char` body size: ~23 B
**And** AR23 docstring above the entry documents: `In: A = 'v' (MC4 — ignored after dispatch)`; `Out: mode_byte = MODE_VISUAL; visual_submode = VIS_CHAR; visual_anchor = cursor_offset (frozen — never re-written by extend); status row = "-- visual -- 1"; parser state zeroed.`; `Trashes: A, BC, DE, HL, F`; `Calls: visual_compose_status (CALL); parser_clear (tail-JP).`

**AC4 — `dispatch_visual` table is extended with motion + digit + `g`-prefix entries; motions are mode-agnostic and route through `edits_compose_or_clear`'s new MODE_VISUAL arm.**

**Given** `src/dispatch.asm:dispatch_visual` (currently 1 entry: Esc → `enter_normal_mode` at line 621-626)
**When** I inspect it after Story 3.3 lands
**Then** the table grows to **20 entries** (ascending by key):
1. `0x1B` (Esc) → `enter_normal_mode` (EXISTING)
2. `'$'` (0x24) → `motion_dollar`
3. `'0'` (0x30) → `parser_handle_digit`
4. `'1'` (0x31) → `parser_handle_digit`
5. `'2'` (0x32) → `parser_handle_digit`
6. `'3'` (0x33) → `parser_handle_digit`
7. `'4'` (0x34) → `parser_handle_digit`
8. `'5'` (0x35) → `parser_handle_digit`
9. `'6'` (0x36) → `parser_handle_digit`
10. `'7'` (0x37) → `parser_handle_digit`
11. `'8'` (0x38) → `parser_handle_digit`
12. `'9'` (0x39) → `parser_handle_digit`
13. `'G'` (0x47) → `motion_G`
14. `'b'` (0x62) → `motion_b`
15. `'g'` (0x67) → `parser_handle_motion_prefix` (for `gg` doubled — extends selection to BOF)
16. `'h'` (0x68) → `motion_h`
17. `'j'` (0x6A) → `motion_j`
18. `'k'` (0x6B) → `motion_k`
19. `'l'` (0x6C) → `motion_l`
20. `'w'` (0x77) → `motion_w`
**And** every adjacent key-ordering invariant is pinned with an `ASSERT` (matching the dispatch_normal convention at `src/dispatch.asm:486-583`) — 19 new `ASSERT key_new > key_prev` lines + the existing `ASSERT 0x1B > 0x0D` is RETAINED but unused (Esc remains the first entry).
**And** `DISPATCH_VISUAL_COUNT` auto-recomputes from `($ - .entries) / 3` — 0x01 → 0x14 (1 → 20).
**And** the dispatch_visual table grows by **57 B** (19 new entries × 3 B = 57 B; ASSERTs are assembly-time and reduce to zero runtime bytes).
**And** all 20 handlers route to EXISTING symbols — none of the bound handlers in dispatch_visual are NEW for Story 3.3. (motion_h/j/k/l from Story 2.5; motion_w/b/G from Story 2.6; motion_gg via parser_handle_motion_prefix from Story 2.6; motion_dollar from Story 2.6; parser_handle_digit from Story 1.10. All read mode-agnostic state and update cursor_offset.)
**And** counted-motion semantic: `5l` in VISUAL accumulates `5` into `count_accumulator` via parser_handle_digit, then `motion_l` consumes the count and advances cursor by 5; `edits_compose_or_clear`'s tail (AC5) calls `visual_extend` which recomputes the char count from (anchor, cursor) and updates status; parser_clear at exit drops the count for the next keystroke. (Q5 pin — recommended Option A from Implementation Questions.)
**And** the existing `unbound_visual` at `src/dispatch.asm:426` continues to catch every non-motion non-operator non-digit keystroke (e.g., `i`, `a`, `:`, `c`, `d`, `y`, `>`, `<`, `~`); operators and `~` will be wired in Stories 3.6/3.7/3.8 — for 3.3 they correctly surface "unbound key" status, preserve the selection, and JP parser_clear (the AC13 contract from Story 2.5).

**AC5 — `edits_compose_or_clear` (the motion shared-tail at `src/edits.asm:1321`) gains a MODE_VISUAL arm on the bare-motion branch.**

**Given** `src/edits.asm:1321-1335` — the current body reads `pending_operator`; if zero, `JP parser_clear`; otherwise dispatches to op_compose_d/y/c/indent/dedent.
**When** Story 3.3 lands
**Then** the `JP Z, parser_clear` line at `src/edits.asm:1324` becomes a 3-instruction MODE_VISUAL check on the bare-motion arm:
```
edits_compose_or_clear:
    LD      A, (pending_operator)
    OR      A
    JR      NZ, .has_operator           ; existing operator dispatch arm
    ;; bare motion — Story 3.3 adds MODE_VISUAL routing
    LD      A, (mode_byte)
    CP      MODE_VISUAL
    JP      Z, visual_extend            ; VISUAL: recompose count + status
    JP      parser_clear                ; NORMAL: existing behaviour
.has_operator:
    CP      'd'
    JP      Z, op_compose_d
    ; ... (existing op_compose_* dispatch unchanged)
```
**And** net cost: **+7 B** in `edits_compose_or_clear` (the new 3 instructions: `LD A,(mode_byte)` = 3 B + `CP MODE_VISUAL` = 2 B + `JP Z, visual_extend` = 3 B; offset by the existing `JP Z, parser_clear` becoming `JR NZ, .has_operator` which is a 1-B-shorter relative jump but adds a new `JP parser_clear` line — net wash within ±2 B).
**And** the `edits_compose_or_clear` AR23 docstring is updated to mention the MODE_VISUAL arm: "On bare motion (pending_operator == 0), routes to `parser_clear` when mode is NORMAL or `visual_extend` when mode is MODE_VISUAL — the post-motion selection-extent recomputation point per Story 3.3 AC5."
**And** the MODE_INSERT and MODE_COMMAND paths are unreachable on this code path: motion handlers are only bound in `dispatch_normal` and `dispatch_visual`; INSERT and COMMAND modes do not route any keys to motions (`dispatch_insert`'s body never JPs to motion_h/j/k/l; `dispatch_command`'s entries route to `exline_*` handlers only). So the `CP MODE_VISUAL` 2-way branch is exhaustive in practice — defensive `JP parser_clear` as the else arm is correct.

**AC6 — `visual_extend` (in `src/visual.asm`) recomputes the char count and refreshes status.**

**Given** `src/visual.asm:visual_extend` (the new public entry from AC5)
**When** invoked (control arrives via `JP visual_extend` from `edits_compose_or_clear`'s bare-motion MODE_VISUAL arm)
**Then** the body performs in order:
1. **Compute char count = |cursor - anchor| + 1** (~15 B):
   - `LD HL, (cursor_offset); LD DE, (visual_anchor); OR A; SBC HL, DE` — HL = cursor - anchor (signed)
   - On CF=1 (cursor < anchor; backward motion): `EX DE, HL; OR A; SBC HL, DE; ADD HL, DE; SBC HL, DE` (abs-value swap — or simpler: `JR NC, .pos; XOR A; SUB L; LD L, A; SBC A, A; SUB H; LD H, A; .pos:` for the negate-HL pattern). Hand off as 16-bit absolute value in HL.
   - `INC HL` — count = |delta| + 1 (anchor==cursor → 0+1 = 1; one byte selected)
2. **Call `visual_compose_status` with HL = count** (~3 B): formats "`-- visual -- <count>`" into the shared `status_compose_scratch` buffer and tail-CALLs `status_set_message`.
3. **`JP parser_clear`** — drop any stale count/prefix accumulated by the motion's preamble (~3 B). The motion handler's own tail-JP target (`edits_compose_or_clear`) hijacked the parser_clear call, so visual_extend must restore that contract before returning.
**And** total `visual_extend` body size: ~21 B (HL=count compute) + 3 B (CALL compose_status) + 3 B (JP parser_clear) = **~27 B**.
**And** AR23 docstring documents: `In: (none — reads cursor_offset, visual_anchor)`; `Out: status_buffer = "-- visual -- <count>" padded with spaces; status_dirty = 1; mode_byte / visual_submode / visual_anchor / cursor_offset UNCHANGED; parser state zeroed.`; `Trashes: A, BC, DE, HL, F.`; `Calls: visual_compose_status (CALL); status_set_message (transitively via compose_status); parser_clear (tail-JP).`
**And** `visual_compose_status` is a MODULE-LOCAL helper (lowercase prefix, no Public entry) — it's the shared composer between `visual_enter_char` (which calls with HL = 1 implicit since anchor==cursor) and `visual_extend` (which passes HL = computed count). Body: LDIR the 14-byte "`-- visual -- `" prefix from `msg_mode_visual_prefix` to `status_compose_scratch`; advance DE; CALL `status_u16_to_dec` (the relocated decimal helper per Q2 pin) to write the count digits at DE; write a NUL byte; `LD HL, status_compose_scratch; XOR A; JP status_set_message` (tail-JP). ~25 B body.
**And** `status_compose_scratch` is a new 32-byte cell in `inc/state.inc` declared between `top_line_offset` and `input_tick_counter` (the natural neighbour of status-line composition state; Q3 pin — recommended Option A: shared scratch for ALL status composers; future stories can amortise the cost). Cold-start LDIR-zero-fill from `init_cold_start` zeroes it (no special-case init needed).

**AC7 — Status format is `"-- visual -- N"` where N is 1..65535 decimal with leading zeros suppressed.**

**Given** the AC6 compose path
**When** I inspect what lands in `status_buffer`
**Then** the format is the literal byte sequence `"-- visual -- "` (13 chars + trailing space; matches the `"-- insert --"` neighbour at `src/statusln.asm:246`) followed by the decimal count, NUL-padded by `status_set_message`'s natural trailing-space fill
**And** `src/statusln.asm` gains ONE new label `msg_mode_visual_prefix: DEFB "-- visual -- ", 0` (14 B incl. NUL) placed adjacent to `msg_mode_visual` at line 247
**And** the EXISTING `msg_mode_visual` string at `src/statusln.asm:247` (`DEFB "-- visual --", 0`) is RETIRED — no remaining reader after the dispatch.asm stub deletes (`enter_visual_mode` was the only reader). Net: -14 B in statusln.asm string table; +14 B for the new prefix — wash (the trailing space is the only literal difference).
**And** the entry-time char count is `1` (single decimal digit), not `0` — matches vi convention: one byte selected at entry, `visual_anchor == cursor_offset`, count = 0 + 1 = 1.
**And** examples:
- `v` from BOF on `"abc\nfoo"` → status `"-- visual -- 1"`
- `v` from BOF, then `l` → cursor=1, count=|1-0|+1=2, status `"-- visual -- 2"`
- `v` from BOF, then `5l` → cursor=5, count=6, status `"-- visual -- 6"`
- `v` from offset 5, then `h` → cursor=4, count=|4-5|+1=2, status `"-- visual -- 2"` (backward motion still extends selection vi-faithfully)
- `v` at BOF on a 70KB file, then `G` → cursor at file_length-? (last-line-start), count up to ~70000 → status `"-- visual -- 65535"` (max 5 decimal digits; > 65535 wraps the count itself — defensible because the gap buffer max is ~22 KB anyway; the helper's max is 65535 which exceeds any reachable selection size in MVP).

**AC8 — Esc returns to NORMAL via the existing `enter_normal_mode`; cursor stays at extent; `visual_anchor` is no longer read until the next visual entry.**

**Given** `mode_byte == MODE_VISUAL` and the user presses Esc (0x1B)
**When** `dispatch_visual['Esc']` (entry 1 in the AC4 table) routes to `enter_normal_mode`
**Then** `enter_normal_mode` (at `src/dispatch.asm:276` — unchanged by Story 3.3) does:
1. `LD A, (mode_byte); CP MODE_INSERT; CALL Z, undo_insert_exit_record` — INSERT-hook guard fails (mode is VISUAL); skips the call
2. `LD A, MODE_NORMAL; LD (mode_byte), A` — mode flips
3. `LD HL, msg_mode_normal; XOR A; CALL status_set_message` — status pads with spaces (msg_mode_normal is the empty banner)
4. `JP parser_clear` — drop any stale parser state
**And** `cursor_offset` UNCHANGED (no write happens between `dispatch_key`'s call to `enter_normal_mode` and the RET back to input_loop)
**And** `visual_anchor` UNCHANGED in state (no write) — but it's effectively dead state until the next `v` re-pins it; the design pin per Story 1.3 / dispatch.asm:400 ("AC4-preserves-state guarantee: visual_anchor still unchanged" — vi convention: the anchor lives on as zombie state until the next visual entry; valid only when MODE_VISUAL is active)
**And** the existing `enter_normal_mode` docstring at line 282-283 ("Esc-from-COMMAND and Esc-from-VISUAL arrive here too") needs ZERO changes for Story 3.3 — the wiring was always in place; only the motion routing in dispatch_visual (AC4) needed to land for Esc to actually become reachable from a real visual session.

**AC9 — Hardware UAT passes the visual-character journey script.**

**Given** I rebuild `vibe.com` with the Story-3.3 patch applied and `make push` it to MicroBeast
**When** I run the UAT script below from CCP
**Then** every step matches the predicted observation:

```
 1. STAT B:fizzbuzz.fs       → confirm fixture present (multi-line
                               file with at least 3 lines)
 2. vibe fizzbuzz.fs         → cursor at offset 0; mode NORMAL;
                               status banner empty (msg_mode_normal
                               pad); visual_anchor irrelevant
 3. v                        → status "-- visual -- 1" (AC3);
                               mode = MODE_VISUAL; visual_submode =
                               VIS_CHAR; visual_anchor = 0; cursor
                               unchanged at 0
 4. l                        → motion_l advances cursor to 1;
                               edits_compose_or_clear's MODE_VISUAL
                               arm fires; visual_extend recomputes
                               count = |1-0|+1 = 2; status
                               "-- visual -- 2" (AC5+AC6)
 5. l l l                    → three more presses; cursor=4;
                               count=5; status "-- visual -- 5"
                               each frame (NOTE: same status string
                               re-emitted is OK — status_dirty is
                               set each motion; no flicker per the
                               RI4 frame discipline since the row
                               is identical bytes)
 6. h                        → backward motion; cursor=3;
                               count=|3-0|+1=4; status
                               "-- visual -- 4" (AC7 backward arm)
 7. 5l                       → AC4 counted-motion: digit '5'
                               accumulates into count_accumulator
                               via dispatch_visual['5'] →
                               parser_handle_digit; status remains
                               "-- visual -- 4" momentarily
                               (count_accumulator is parser-state,
                               not selection state; status is only
                               recomputed when a motion completes;
                               so the digit press SHOULD update
                               status — see Q6 implementation note);
                               then 'l' fires motion_l counted by 5
                               → cursor=8; count=9; status
                               "-- visual -- 9"
 8. j                        → motion_j moves to next line at
                               same column (sticky-column from
                               Story 2.7); cursor jumps to next-
                               line+col; count recomputes (likely
                               much larger — newline crossings
                               are 1 byte each in the buffer);
                               status updates with new count
 9. G                        → motion_G to last-line-start; count
                               = (last-line-start - 0) + 1 ≈
                               file_length - len(last_line);
                               status updates
10. gg                       → motion_gg via parser_handle_motion_prefix +
                               second 'g'; cursor returns to BOF;
                               count = |0-0|+1 = 1; status
                               "-- visual -- 1"
11. Esc                      → enter_normal_mode (AC8); mode =
                               MODE_NORMAL; status pads to empty;
                               cursor stays at 0 (the extent at
                               cancel time); visual_anchor
                               unchanged in state (zombie)
12. v                        → re-enter visual; anchor re-pinned
                               at cursor=0; status
                               "-- visual -- 1"
13. l l                      → status "-- visual -- 3"
14. d                        → AC4 deferral: 'd' is NOT bound in
                               dispatch_visual (operator wiring
                               lands in Story 3.6); falls through
                               to unbound_visual; status
                               "unbound key"; mode stays
                               MODE_VISUAL; cursor unchanged;
                               selection preserved
15. l                        → after the unbound 'd', motion_l
                               still works: cursor advances by 1;
                               visual_extend fires; status
                               "-- visual -- 4"
16. Esc                      → exit; mode NORMAL
17. :q                       → clean exit; buffer not dirty;
                               control returns to CCP
```

**AC10 — 6 headless tests under `test/cases/visual_*.asm` (and `test/cases/parser_v-dispatch.asm`) pass.**

**Given** `make test` runs from a fresh tree (with the Story-3.1 dep-hygiene Makefile fix already in place)
**When** the new test cases are added (sentinel band 0xB0..0xB4 for the 5 visual_* + 0xEB for the parser-dispatch coverage; bands 0xA0..0xAF + 0xE9..0xEA fully consumed by Stories 3.1 + 3.2)
**Then** the following 5 tests PASS:
- `visual_v-enters-mode.asm` (sentinel 0xB0) — buffer "abc\nfoo\nbar" (11 B); cursor=0; mode_byte=MODE_NORMAL pre-call; CALL `visual_enter_char`; expect `mode_byte = MODE_VISUAL`, `visual_submode = VIS_CHAR`, `visual_anchor = 0`, `status_buffer` starts with `"-- visual -- 1"` (14 chars: 13 prefix + '1' digit; remaining 66 chars padded with space by status_set_message), `cursor_offset = 0` (unchanged), `count_accumulator = 0` (parser_clear ran).
- `visual_motions-extend-selection.asm` (sentinel 0xB1) — buffer "abcdef" (6 B); cursor=0; pre-set `mode_byte=MODE_VISUAL`, `visual_submode=VIS_CHAR`, `visual_anchor=0`. CALL `motion_l` (which tail-JPs `edits_compose_or_clear` → MODE_VISUAL arm → `visual_extend`); expect `cursor_offset = 1`, `status_buffer` starts with `"-- visual -- 2"`. CALL `motion_l` again; expect `cursor_offset = 2`, status `"-- visual -- 3"`. CALL `motion_l` again; expect `cursor_offset = 3`, status `"-- visual -- 4"`.
- `visual_esc-cancels.asm` (sentinel 0xB2) — buffer "abcdef"; cursor=3; pre-set `mode_byte=MODE_VISUAL`, `visual_submode=VIS_CHAR`, `visual_anchor=1`. CALL `enter_normal_mode`; expect `mode_byte = MODE_NORMAL`, `cursor_offset = 3` (UNCHANGED — at extent per AC8), `status_buffer[0] = ' '` (msg_mode_normal pad), `visual_anchor = 1` (UNCHANGED — zombie state per AC8).
- `visual_backward-extends.asm` (sentinel 0xB3) — buffer "abcdef"; cursor=4; pre-set `mode_byte=MODE_VISUAL`, `visual_anchor=4`. CALL `motion_h`; expect `cursor_offset = 3`, status `"-- visual -- 2"` (|3-4|+1 = 2 — abs-value branch of AC6). CALL `motion_h` again; expect `cursor_offset = 2`, status `"-- visual -- 3"`.
- `visual_counted-motion.asm` (sentinel 0xB4) — buffer "abcdefghij" (10 B); cursor=0; pre-set `mode_byte=MODE_VISUAL`, `visual_anchor=0`, `count_accumulator=3` (simulates the user having pressed `3` before `l`). CALL `motion_l` (which reads count_accumulator and advances 3 bytes); expect `cursor_offset = 3`, status `"-- visual -- 4"` (|3-0|+1 = 4 — AC4 counted-motion + AC6 count math), `count_accumulator = 0` (parser_clear ran via visual_extend's tail-JP — AC6 part 3).

**And** the parser-dispatch coverage test PASSES:
- `parser_v-dispatch.asm` (sentinel 0xEB) — buffer "abcde"; pre-set `cursor_offset = 2`, `mode_byte = MODE_NORMAL`, `status_dirty = 0x80` (sentinel — to verify the dispatcher actually wrote it). Drive `'v'` through dispatch_key with `dispatch_normal` table: `LD A, 'v' ; LD HL, dispatch_normal ; LD B, DISPATCH_NORMAL_COUNT ; CALL dispatch_key`. Verify post-call: `mode_byte = MODE_VISUAL`, `visual_submode = VIS_CHAR`, `visual_anchor = 2` (= entry cursor), `status_buffer` starts with `"-- visual -- 1"` (entry char count), `status_dirty = 1` (overwritten by status_set_message). Confirms `dispatch_normal['v']` is wired to `visual_enter_char` end-to-end (NOT to the retired `enter_visual_mode` and NOT falling through to `unbound_normal`).

**Test count target: 214 → 220 PASS (+6) / 1 deliberate-fail unchanged.**

## Tasks / Subtasks

- [x] **Task 0** (pre-dev pin with Ant — resolve BEFORE writing code):
  - [x] Q1 — `enter_visual_mode` stub retirement strategy (recommended Option A — retarget dispatch_normal['v'] to visual_enter_char in src/visual.asm and DELETE the dispatch.asm stub body) vs Option B (keep stub as a forwarder).
  - [x] Q2 — Decimal-format helper location (recommended Option A — move `fileio_u16_to_dec` from `src/fileio.asm` to `src/statusln.asm` as `status_u16_to_dec`; update fileio's two callers + reference from visual.asm; ~0 B net) vs Option B (duplicate ~30 B inline in visual.asm) vs Option C (cross-module call from visual to fileio; AR-awkward).
  - [x] Q3 — Status compose scratch buffer (recommended Option A — new shared `status_compose_scratch` cell (32 B) in `inc/state.inc`; migrate fileio.asm's existing `fileio_status_scratch` use to share; future status composers benefit) vs Option B (each module owns its own scratch) vs Option C (alias fileio_status_scratch in-place; cross-module AR concern).
  - [x] Q4 — Status format for VISUAL (recommended Option A — `"-- visual -- N"` matching `"-- insert --"` neighbour style) vs Option B (`"-- VISUAL -- N chars"`) vs Option C (`"VISUAL N"`).
  - [x] Q5 — Counted-motion semantic in VISUAL (recommended Option A — dispatch_visual includes digits 0-9 → parser_handle_digit; counted motions work just like in NORMAL; closes the dispatch_visual open question per deferred-work.md:99) vs Option B (omit digits; counts dropped silently in VISUAL).
  - [x] Q6 — Should pressing a digit in VISUAL update the status row mid-count (e.g., `3` shows "-- visual -- 4 [3]" or similar) or stay quiet until the motion completes? (recommended Option A — STAY QUIET; the count_accumulator is internal parser state; status only refreshes on motion completion; matches vi UX). Cost: ~0 B (existing).
  - [x] Q7 — `visual_cancel` as a separate Public symbol in visual.asm or aliased via existing `enter_normal_mode` (recommended Option A — alias; no symbol needed; enter_normal_mode at dispatch.asm:276 already names VISUAL exit in its docstring; matches Stories 3.1/3.2 pattern of relying on existing handlers rather than spurious aliases).
  - [x] Q8 — Single dev commit per the 2.11/2.12/2.13/3.1/3.2 precedent (recommended).

- [x] **Task 1** — Cross-cutting state + statusln plumbing:
  - [x] 1.1 — Add `status_compose_scratch` (32 B) to `inc/state.inc` between `top_line_offset` and `input_tick_counter` (Q3 Option A). Cold-start LDIR-zero-fill zeroes it (no init.asm change needed). Document in the state.inc comment header as "shared scratch for status-line composition; writers = visual.asm, fileio.asm; capacity covers `'-- visual -- 65535'\\0` (19 B) and `'filename.ext NNNNN bytes written'\\0` (~36 B) headroom".
  - [x] 1.2 — Move `fileio_u16_to_dec` from `src/fileio.asm:1531` to `src/statusln.asm` and rename to `status_u16_to_dec` (Q2 Option A). Replace `fileio_dec_dest` module-local cell with a statusln-local `status_dec_dest` (1 cell; AR12 ownership unchanged — the cell is the helper's private marshalling state, not status_buffer / status_dirty). Update fileio.asm's two callers (`fileio_compose_filename_count_suffix:.line ~1497` is the only caller per the read above) to use the new name; same calling contract.
  - [x] 1.3 — Add `msg_mode_visual_prefix: DEFB "-- visual -- ", 0` (14 B) at `src/statusln.asm` adjacent to `msg_mode_visual` (line 247). Retire `msg_mode_visual` (the bare `"-- visual --"` string) — the only reader was `enter_visual_mode` in dispatch.asm which Task 2 deletes. Update the statusln.asm module-header Public block to list the prefix and drop msg_mode_visual.

- [x] **Task 2** — Retire `enter_visual_mode` in `src/dispatch.asm`:
  - [x] 2.1 — Delete `enter_visual_mode` body (lines 349-357) AND its AR23 docstring block (lines 334-348) — entire ~24-line section.
  - [x] 2.2 — Retarget `dispatch_normal['v']` entry at `src/dispatch.asm:583` from `DEFW enter_visual_mode` to `DEFW visual_enter_char` (forward-reference resolved by sjasmplus second pass).
  - [x] 2.3 — Extend `src/dispatch.asm` module-header Dependencies block with a new `src/visual.asm` entry parallel to the `src/search.asm` block (lines 135-148). Document: `'v'` retargeted to `visual_enter_char`; `enter_visual_mode` stub retired; Story 3.3 Story 3.1 stub-retirement pattern reference; `dispatch_visual` extended with motion/digit/g entries (count 1 → 20).
  - [x] 2.4 — Verify Public block of `src/dispatch.asm` (lines 30-42) no longer lists `enter_visual_mode` — delete the line. Net impact on the surface API of dispatch.asm.

- [x] **Task 3** — Extend `dispatch_visual` in `src/dispatch.asm` (lines 621-626):
  - [x] 3.1 — Add the 19 new entries per the AC4 table, in strict ascending key order (Esc 0x1B at the head; then $ 0x24 → 0..9 0x30..0x39 → G 0x47 → b 0x62 → g 0x67 → h 0x68 → j 0x6A → k 0x6B → l 0x6C → w 0x77). Each entry: ASSERT key_n > key_prev, DEFB key, DEFW handler. Sentinels at every step.
  - [x] 3.2 — Verify `DISPATCH_VISUAL_COUNT` auto-recomputes from `($ - .entries) / 3` (currently 0x01; post-Task 3 = 0x14). No explicit edit needed.
  - [x] 3.3 — Confirm by build that all 19 forward-referenced handler symbols (motion_dollar, parser_handle_digit, motion_G, motion_b, parser_handle_motion_prefix, motion_h, motion_j, motion_k, motion_l, motion_w) resolve cleanly — they all live in `src/motions.asm` and `src/parser.asm` which INCLUDE before dispatch.asm — so backward references, not forward. (Wait — actually parser.asm and motions.asm both INCLUDE AFTER dispatch.asm in the AR25 chain at vibe.asm:115-135; verify by reading vibe.asm and confirming forward-references resolve via sjasmplus's two-pass model. The dispatch.asm tables ALREADY forward-reference these symbols for dispatch_normal — same pattern; no surprise.)

- [x] **Task 4** — Create new module `src/visual.asm`:
  - [x] 4.1 — Standard AR23 module header (Module, Purpose, Public, State owned, State read, Register conventions, Dependencies) per AC1's specification.
  - [x] 4.2 — `visual_enter_char` body per AC3 (~23 B). AR23 docstring above.
  - [x] 4.3 — `visual_extend` body per AC6 (~27 B). AR23 docstring above. Compute |cursor - anchor| via SBC HL, DE with CF-based abs-value swap; INC HL for the +1; tail-CALL visual_compose_status; tail-JP parser_clear.
  - [x] 4.4 — `visual_compose_status` module-local helper per AC6 (~25 B). LDIR the 13-byte prefix (the `"-- visual -- "` glyphs without the NUL — copy STATUS_MODE_VISUAL_PREFIX_LEN bytes); advance DE; CALL status_u16_to_dec (writes 1-5 decimal digits); store 0 at DE (NUL terminator for status_set_message's null-aware copy_loop at statusln.asm:108-115); load HL = status_compose_scratch, XOR A (no-error code), tail-JP status_set_message.
  - [x] 4.5 — Forward-reference placeholders for `visual_enter_line` (Story 3.4), `visual_enter_block` (Story 3.5), `visual_apply_operator` (Story 3.6+) in the module-header Public block ONLY — NOT declared in this story's body. The Public-block placeholder text reads: `; visual_enter_line   ; LANDS Story 3.4 (V — line-wise selection)`.

- [x] **Task 5** — Extend `edits_compose_or_clear` in `src/edits.asm` (line 1321):
  - [x] 5.1 — Patch the bare-motion arm per AC5: convert the single `JP Z, parser_clear` line at 1324 into a 3-line MODE_VISUAL check (`LD A,(mode_byte); CP MODE_VISUAL; JP Z, visual_extend; JP parser_clear`). Re-flow the `JR NZ, .has_operator` label as needed; either keep the existing dispatch-after-Z arm as-is OR introduce a `.has_operator:` label to keep the new branch readable.
  - [x] 5.2 — Update the `edits_compose_or_clear` AR23 docstring at edits.asm:1295-1320: add a "Story 3.3 — MODE_VISUAL routing" note documenting the new arm. State that the MODE_INSERT and MODE_COMMAND paths are unreachable on this code path (motion handlers are only bound in dispatch_normal and dispatch_visual; INSERT/COMMAND modes don't dispatch to motions).
  - [x] 5.3 — Extend `src/edits.asm` module-header Dependencies block with a new `src/visual.asm` entry (forward reference for `visual_extend` — resolves via sjasmplus second pass since visual.asm INCLUDEs AFTER edits.asm in the new AR25 chain).

- [x] **Task 6** — Wire `INCLUDE "visual.asm"` into `src/vibe.asm` and bulk-patch all test/cases:
  - [x] 6.1 — `src/vibe.asm`: insert `INCLUDE "visual.asm"` between line 149 (`INCLUDE "edits.asm"`) and line 160 (`INCLUDE "search.asm"`). Add a comment banner matching the style of the surrounding modules (mention Story 3.3, FR15+FR33, the long-planned slot per architecture.md:946, and that visual.asm slots BEFORE search.asm per the architecture canonical order).
  - [x] 6.2 — Bulk patch every `test/cases/*.asm` to add `INCLUDE "../../src/visual.asm"` between the existing `edits.asm` and `search.asm` INCLUDE lines. Same shape as Story 3.1's bulk sed patch for search.asm. Actual file count: 215 .asm files in `test/cases/` (per `ls test/cases/*.asm | wc -l`); 202 of them currently INCLUDE the production chain (per `grep -l "INCLUDE.*search.asm"`). The bulk patch touches exactly those 202. Use a robust sed expression that only patches files containing BOTH `edits.asm` and `search.asm` INCLUDE lines to avoid touching the 13 unrelated tests. Verify via spot-check on 5 random tests post-patch.
  - [x] 6.3 — Verify the Story-3.1 Makefile dep-hygiene fix (Epic-2 retro action A1) catches the cross-cutting INCLUDE addition: test/Makefile's `cases/%.com` recipe depends on `$(wildcard ../src/*.asm)`, so the new visual.asm is automatically picked up — no Makefile change needed. Confirm by `make clean && make test` rebuilding every .com file (not relying on stale build artifacts that masked the Story 2.1/2.2 14-test breakage).

- [x] **Task 7** — Headless tests (6 new files in `test/cases/`):
  - [x] 7.1 — `visual_v-enters-mode.asm` (sentinel 0xB0) — AC10 spec; ~95 lines including pre-seed prologue and post-call assertions on mode_byte/visual_submode/visual_anchor/status_buffer/cursor/count_accumulator.
  - [x] 7.2 — `visual_motions-extend-selection.asm` (0xB1) — AC10 spec; ~120 lines; three CALL motion_l invocations with assertions between each.
  - [x] 7.3 — `visual_esc-cancels.asm` (0xB2) — AC10 spec; ~85 lines.
  - [x] 7.4 — `visual_backward-extends.asm` (0xB3) — AC10 spec; ~95 lines; two CALL motion_h invocations; verifies abs-value branch of AC6 compute.
  - [x] 7.5 — `visual_counted-motion.asm` (0xB4) — AC10 spec; ~95 lines; pre-seeds count_accumulator=3, calls motion_l, asserts cursor=3, status="-- visual -- 4", count_accumulator=0.
  - [x] 7.6 — `parser_v-dispatch.asm` (0xEB) — AC10 spec; drives 'v' through dispatch_key end-to-end; matches the pattern of `parser_slash-dispatch.asm` (0xE9; Story 3.1) and `parser_n-dispatch.asm` (0xEA; Story 3.2). ~85 lines.
  - [x] 7.7 — Fixture-seeding convention matches Stories 3.1/3.2: pre-seed mode_byte / visual_submode / visual_anchor / cursor_offset / count_accumulator / status_dirty / parser cells explicitly. NO reliance on cold-start LDIR (tests skip init_cold_start per the test_prologue.inc convention).
  - [x] 7.8 — All 6 tests added under sentinel-band reservations per Story 3.2's closing assertion (band 0xB0..0xB4 NEW; 0xEB extends the parser-dispatch band started by 3.1's 0xE9 and 3.2's 0xEA). No collisions with existing tests (verified via `grep "0xB[0-4]\|0xEB" test/cases/*.asm` returning zero matches pre-patch).

- [x] **Task 8** — NFR18 byte-identical rebuild + UAT + sprint-status flip:
  - [x] 8.1 — Two `make clean && make all` cycles produce byte-identical `vibe.com` SHAs. Capture the SHA in the Dev Agent Record Completion Notes.
  - [x] 8.2 — `make sizes` reports the new footprint. Projected: pre-3.3 6503 B + ~170 B (visual.asm body ~80 B + dispatch_visual +57 B + edits_compose_or_clear +7 B - dispatch enter_visual_mode -18 B + msg_mode_visual_prefix wash + status_compose_scratch is STATE not code + decimal-helper move is wash + 14-byte prefix string difference ~+1 B) = ~**6673 B / 81.5% of 8192 B / 1519 B headroom**. Within budget — no NFR9 amend.
  - [x] 8.3 — Hardware UAT (AC9, 17 steps) deferred to user — script pasted inline at dev-handoff per [[feedback_uat_inline_at_dev_handoff]].
  - [x] 8.4 — Flip `sprint-status.yaml` `3-3-visual-character-mode` `ready-for-dev` → `review` at dev-handoff; → `done` after Ant confirms hardware UAT.

## Dev Notes

### Architecture compliance

**AR boundaries — `src/visual.asm` is a PURE READER of buffer state.**
- AR13 (BIOS_CONOUT): zero call sites — visual.asm never emits to screen. Status updates funnel through `status_set_message` (AR12 owner statusln.asm); the screen emit happens later in `render_diff`'s status-row pass.
- AR14 (gap_start / gap_end WRITES): zero write sites. visual.asm reads `cursor_offset` and `visual_anchor`; never writes either via gap-buffer mutation. The cursor moves through motions.asm (which writes cursor_offset directly via the AR14 carve-out for cursor state; motions don't mutate the buffer).
- AR15 (BDOS_CALL): zero call sites — visual.asm never invokes BDOS.

**AR23 (per-module header convention)** — every public entry in src/visual.asm gets a docstring with In / Out / Trashes / Calls per the Story 1.5+ pattern.

**AR25 (INCLUDE order)** — Story 3.3 inserts `visual.asm` between `edits.asm` and `search.asm` per architecture.md:946 (the long-planned slot). Forward references from visual.asm's body resolve cleanly:
- `parser_clear` in `src/parser.asm` — INCLUDEs BEFORE visual.asm (parser.asm at line 125 in vibe.asm; visual.asm at the new line ~155); backward reference.
- `status_set_message` + `status_u16_to_dec` + `msg_mode_visual_prefix` in `src/statusln.asm` — INCLUDEs at the very top of the production chain (statusln.asm at vibe.asm line ~75; visual.asm at line ~155); backward reference.
- `visual_enter_char` and `visual_extend` are forward-referenced from dispatch.asm (which INCLUDEs BEFORE visual.asm; the dispatch_normal['v'] entry and the dispatch_visual motion-entry handler addresses are filled in by sjasmplus's second pass — exactly the same shape as Story 3.1's `search_begin` forward-reference at dispatch.asm:486 and Story 3.2's `search_next` at line 562).
- `visual_extend` is forward-referenced from edits.asm's `edits_compose_or_clear` (edits.asm INCLUDEs BEFORE visual.asm); resolves on second pass.

**MC4 register convention** — visual_enter_char accepts A = 'v' as the dispatched key (per MC4 contract); the value is ignored after dispatch. visual_extend reads no register state on entry (it pulls cursor_offset and visual_anchor from state.inc cells).

**SR4 mode-byte invariant** — when `mode_byte == MODE_VISUAL`, `visual_submode` is one of `VIS_CHAR | VIS_LINE | VIS_BLOCK`. Story 3.3 lands the VIS_CHAR writer only. Stories 3.4 and 3.5 will add VIS_LINE and VIS_BLOCK writers. The Esc-to-NORMAL transition does NOT clear visual_submode (per dispatch.asm:19-20 — "the mode-change handler does NOT clear visual_submode; the value is meaningless in non-visual modes and the next visual entry overwrites it").

**SR-state ownership (state.inc):**
- `visual_anchor` (16-bit, state.inc:96): WRITER = `visual_enter_char` (and the future visual_enter_line / visual_enter_block). READERS = `visual_extend` (Story 3.3); future `visual_apply_operator` (Story 3.6+).
- `visual_submode` (1-byte, state.inc:49): WRITER = `visual_enter_char` (VIS_CHAR); future visual_enter_line / visual_enter_block writers. READERS = render.asm (potentially — see Files-modified section); visual_apply_operator (Story 3.6+).
- `status_compose_scratch` (32 B, NEW in state.inc Task 1.1): WRITERS = `visual_compose_status` (visual.asm); `fileio_compose_filename_count_suffix` (fileio.asm — after Task 1.2 migration). READERS = `status_set_message`'s copy_loop, transitively.

### Files this story modifies (and what to preserve)

**`src/dispatch.asm`** (currently 705 lines):
- DELETE lines 334-357 (enter_visual_mode docstring + body) per Task 2.1
- MODIFY line 583 (`DEFW enter_visual_mode` → `DEFW visual_enter_char`) per Task 2.2
- ADD ~57 B to dispatch_visual table (lines 621-626 → expanded ~25 lines) per Task 3.1
- MODIFY module-header Dependencies block (lines 75-148) — add visual.asm block per Task 2.3
- DELETE one line from Public block (line 41 — `enter_visual_mode`) per Task 2.4
- PRESERVE: enter_normal_mode (lines 276-294); enter_insert_mode (lines 314-332); unbound_normal (lines 409-413); unbound_visual (lines 426-430); unbound_insert; mode_full_refresh_stub; ALL dispatch_normal/insert/command entries (lines 449-619); the dispatch_key body (lines 188-230).

**`src/edits.asm`** (currently 2200+ lines):
- MODIFY edits_compose_or_clear body (lines 1321-1335) per Task 5.1 — +7 B net.
- MODIFY edits_compose_or_clear AR23 docstring (lines 1295-1320) per Task 5.2.
- MODIFY module-header Dependencies block to add forward reference to visual.asm per Task 5.3.
- PRESERVE: All 11 motion-tail JP edits_compose_or_clear sites (motions.asm lines 215, 286, 414, 525, 834, 927, 953, 996, 1105, 1142, etc.) — they are UNTOUCHED; the MODE_VISUAL routing is invisible to the motion handlers.
- PRESERVE: op_compose_d / op_compose_y / op_compose_c / op_compose_indent / op_compose_dedent bodies (lines 1423-1789); edits_compose_range; all KIND_CHAR / KIND_LINE writers; the entire Story 2.10-2.13 yank/paste/undo surface.

**`src/vibe.asm`** (currently ~285 lines):
- INSERT one INCLUDE line + comment block (~5 lines total) per Task 6.1.
- PRESERVE: the entire AR25 chain comment narrative for surrounding modules (edits.asm and search.asm blocks at lines 137-160) — Story 3.3's banner sits between them.

**`src/fileio.asm`** (currently 1700+ lines):
- DELETE `fileio_u16_to_dec` body (lines 1531-~1560) per Task 1.2 — relocates to statusln.asm.
- DELETE `fileio_dec_dest` module-local cell (~1 line) per Task 1.2 — relocates to statusln.asm.
- MODIFY `fileio_compose_filename_count_suffix` CALL at line 1497 — change symbol name to `status_u16_to_dec` per Task 1.2.
- MODIFY module-header Dependencies block — drop the (internal) fileio_u16_to_dec reference; add statusln.asm dependency for the new shared helper.
- PRESERVE: `fileio_status_scratch` may be retired and replaced by the new shared `status_compose_scratch` per Task 1.1 — OR fileio_status_scratch stays and Story 3.3 only adds the new scratch. Pin under Q3 (recommended Option A: migrate and share).

**`src/statusln.asm`** (currently ~250 lines):
- ADD `msg_mode_visual_prefix: DEFB "-- visual -- ", 0` adjacent to msg_mode_visual at line 247 per Task 1.3.
- DELETE `msg_mode_visual` at line 247 per Task 1.3 (no remaining reader after dispatch.asm stub deletion).
- ADD `status_u16_to_dec` body (~50 B) + `status_dec_dest` (1 module-local DEFW) per Task 1.2.
- MODIFY module-header Public block to list `status_u16_to_dec` and the new prefix string; drop msg_mode_visual.
- PRESERVE: `status_set_message` body (lines 105-127); `bdos_error_funnel` (lines 145+); all error/info-message labels.

**`inc/state.inc`** (currently ~140 lines):
- ADD `status_compose_scratch` (32 B reserved via 32× `static_off = static_off + 1` increment block, OR a single `static_off = static_off + 32` and a `DEFS 32` equivalent) between `top_line_offset` and `input_tick_counter` per Task 1.1.
- PRESERVE: ALL existing 16-bit and 8-bit state cell declarations; the static_off running counter discipline; the AR23 module header.

**Test files (`test/cases/*.asm`):**
- BULK PATCH all production-chain-INCLUDEing tests per Task 6.2 — add `INCLUDE "../../src/visual.asm"` between edits.asm and search.asm INCLUDEs.
- ADD 6 new test files per Task 7.
- PRESERVE: All existing test bodies — the bulk patch only inserts an INCLUDE line.

### Implementation choices and trade-offs

**Choice: `visual_enter_char` ENTIRELY replaces `enter_visual_mode`; the dispatch.asm stub is DELETED, not refactored.**
- Per Q1 Option A (recommended). Matches Story 3.1's retirement of `mode_search_prompt_stub` when `search_begin` arrived.
- Alternative considered: keep `enter_visual_mode` in dispatch.asm as a forwarder (`JP visual_enter_char`); rejected — adds 3 B and a useless symbol; the Story 3.1 / 3.2 pattern is full retirement.

**Choice: motions in VISUAL go through the SAME handlers as NORMAL via dispatch_visual.**
- Per Q5 Option A and epic narrative. The motions are mode-agnostic by Story 2.5 design — they update `cursor_offset` from state, not from a parameter, and their tail-JP target (`edits_compose_or_clear`) is the central routing point. Adding the MODE_VISUAL arm there (AC5) cleanly extends the existing dispatch surface without per-motion patches.
- Alternative considered: per-motion VISUAL-aware handlers (e.g., `visual_motion_h` wrapping `motion_h`). Rejected — 10× per-motion thunks at 3 B each = 30 B + maintenance cost; the central routing in edits_compose_or_clear is one 7-B patch that covers every current and future motion.

**Choice: char count = |cursor - anchor| + 1 (vi-faithful).**
- Per Q8 Option A and epic AC narrative. At entry where cursor == anchor, count = 0+1 = 1 (one byte under the cursor is selected). Forward motion → cursor > anchor → count grows. Backward motion → cursor < anchor → abs-value swap → count grows. Symmetric.
- Alternative considered: count = |cursor - anchor| (entry shows 0). Rejected — confusing UX; one selected byte should show 1.

**Choice: shared status compose scratch in state.inc; decimal helper migrated to statusln.asm.**
- Per Q2 + Q3 Option A. Architecturally cleanest: statusln.asm owns status-line composition state (AR12); a shared helper and shared scratch follow the AR12 grain.
- Trade-off: ~50 B of code moves between modules + fileio.asm's caller is patched. Net code size unchanged. The migration is a one-time cost; future stories (line/column indicator, filename in status, undo-count display) all benefit.

**Choice: dispatch_visual grows to 20 entries; operators (d/y/c/>/</~) defer to Stories 3.6/3.7/3.8.**
- Per epic scope: 3.3 = visual entry + motions + Esc; 3.4 = V (line); 3.5 = Ctrl-V (block); 3.6-3.8 = operators. Operator keys in dispatch_visual will land in 3.6+.
- Trade-off: operators currently fall through to `unbound_visual` and surface "unbound key". From a vi muscle-memory perspective: pressing `d` in visual yields "unbound key" instead of the expected behaviour. This is acceptable for the intermediate state — the unbound_visual message is informative and the user discovers operator support in 3.6.

**Choice: `visual_cancel` is NOT a separate symbol; existing `enter_normal_mode` handles VISUAL exit.**
- Per Q7 Option A. enter_normal_mode at dispatch.asm:276 already names VISUAL exit in its docstring and was designed for this purpose since Epic 1. Adding a `visual_cancel` alias adds a symbol without behaviour change.
- Trade-off: future visual operators that need to apply-AND-exit (e.g., `vd` deletes selection and returns to NORMAL) will likely add `visual_apply_operator` which combines the apply + exit. That entry can call enter_normal_mode as its tail-JP. No need for a separate visual_cancel.

### Previous story intelligence

**From Story 3.2 (just completed, code-review applied):**
- The Q1 refactor pattern (RET-based shared helper between two callers) inspired this story's edits_compose_or_clear MODE_VISUAL routing — the existing `JP Z, parser_clear` becomes a two-way branch on mode_byte.
- The Q2 deferral pattern (counted-`n` deferred to a future polish story) does NOT apply here — counted motions in VISUAL are an epic-AC requirement and land in Story 3.3 (per Q5).
- Story 3.2's `parser_n-dispatch.asm` pattern (drive a key through dispatch_key end-to-end) is reused for `parser_v-dispatch.asm` (Task 7.6).
- The NFR18 SHA byte-identical discipline from 3.2: two `make clean && make all` cycles confirm reproducibility. Story 3.3 follows.

**From Story 3.1 (`/pattern` search):**
- The stub-retirement pattern (`mode_search_prompt_stub` → `search_begin`) is directly mirrored by Story 3.3's `enter_visual_mode` → `visual_enter_char`. Same forward-reference shape; same -18 B in dispatch.asm net; same module-header dependency-block extension.
- The bulk INCLUDE patch pattern (184 test files for search.asm) repeats for visual.asm at Task 6.2. The Makefile dep-hygiene fix from Story 3.1 (Epic-2 retro A1) catches the new INCLUDE — no Makefile change needed.
- The sentinel-band reservation pattern: 3.1 used 0xA0..0xAA + 0xE9; 3.2 used 0xAB..0xAF + 0xEA; 3.3 will use 0xB0..0xB4 + 0xEB. Band 0xB5..0xBF reserved for 3.4 (V-line) and 3.5 (Ctrl-V-block).

**From Story 2.11 (operator+motion compose):**
- The shared compose tail (`edits_compose_or_clear`) was designed precisely so future cross-cutting routing additions would land in ONE place. Story 3.3 is the first such addition since 2.11 — extending the bare-motion arm with a MODE_VISUAL check.
- The per-motion entry-time prologue from Story 2.11 (`LD HL,(cursor_offset); LD (motions_compose_entry), HL`) is NOT reused for visual — visual stores its anchor in `visual_anchor` on `v` entry, NOT on per-motion entry. The two state cells (motions_compose_entry for operator+motion; visual_anchor for visual mode) are independent.

**From Story 2.13 (single-level undo `u`):**
- The dispatch_normal['u'] addition pattern (~3 B + 1 ASSERT) is mirrored 19× in Story 3.3's dispatch_visual extension. Each new entry is the same shape.
- The 'u' handler tail-JPs parser_clear (per AC13 from Story 2.5); Story 3.3's `visual_enter_char` and `visual_extend` both tail-JP parser_clear too.

**From Story 1.10 (parser FSM):**
- `parser_handle_digit` is mode-agnostic — it reads `count_accumulator`, multiplies by 10, adds the digit, and writes back. Dispatched from dispatch_normal['0'..'9'] today; will be dispatched from dispatch_visual['0'..'9'] post-3.3 with no behavioural change.
- `parser_handle_motion_prefix` is mode-agnostic — sets pending_motion_prefix to 'g' (or whatever); the next motion key fires the doubled or composed motion. Works identically in VISUAL.

### Git intelligence

**Recent commits (last 5):**
- `c0761fd Story 3.2: repeat last search with wrap` — just landed; precedent for single-commit Story-3.x pattern.
- `231ce3f Story 3.1: forward literal search /pattern lands; FR41 closes` — the stub-retirement pattern that Story 3.3 mirrors.
- `c8fb896 Story 2.13: single-level undo u lands; FR45/FR46 closed; closes Epic 2` — the dispatch_normal entry-addition pattern.
- `0756610 story 2.12: paste p / Np lands (KIND_CHAR + KIND_LINE; KIND_BLOCK reserved)` — KIND_BLOCK reservation pattern that aligns with Story 3.5 visual-block.
- `84dd7d4 story 2.11: operator+motion compose (dw/d$/c5w/y3j) + >> / << landed` — the shared compose tail (edits_compose_or_clear) that Story 3.3 extends.

**Pattern:** every Epic-3 story so far has been single-commit, ~6-12 new headless tests, NFR18 byte-identical rebuild required. Story 3.3 follows the same shape.

### Implementation Questions (resolve with Ant before dev starts)

**Q1 — `enter_visual_mode` stub retirement strategy.**
- **Option A (recommended):** Retarget `dispatch_normal['v']` to `visual_enter_char` in `src/visual.asm`; DELETE the `enter_visual_mode` body + docstring in `src/dispatch.asm` entirely. Net: -24 lines + -18 B in dispatch.asm; +new module body in visual.asm. Matches Story 3.1's `mode_search_prompt_stub` retirement.
- **Option B:** Keep `enter_visual_mode` in dispatch.asm as a 3-B forwarder (`JP visual_enter_char`). Rejected — useless indirection; adds a stub symbol with zero readability gain.

**Q2 — Decimal-format helper location.**
- **Option A (recommended):** Move `fileio_u16_to_dec` from `src/fileio.asm` to `src/statusln.asm`; rename to `status_u16_to_dec`; share with visual.asm. ~0 B net (relocates ~50 B). Architecturally correct — statusln.asm owns status-line composition (AR12).
- **Option B:** Duplicate ~30 B of inline u16-to-dec inside visual.asm. AR-clean but code duplication. Quick-and-dirty fallback if Option A's migration uncovers a fileio caller bug.
- **Option C:** Cross-module call from visual.asm to fileio.asm. AR-awkward (fileio is below visual in the dependency graph at architecture.md:1415).

**Q3 — Status compose scratch buffer.**
- **Option A (recommended):** Add `status_compose_scratch` (32 B) in `inc/state.inc`; migrate `fileio_status_scratch` (currently 48 B per fileio.asm:1471 capacity comment) usage to share. Net: -16 B state, +0 B code.
- **Option B:** Each module owns its own scratch — visual gets `visual_status_scratch` (24 B); fileio keeps `fileio_status_scratch`. +24 B state, +0 B code. Cleaner ownership but more cells.
- **Option C:** Alias `fileio_status_scratch` in-place — visual.asm writes to a cell owned by fileio's AR12 boundary. Rejected — cross-module ownership of a stateful cell breaks AR12.

**Q4 — Status format for VISUAL.**
- **Option A (recommended):** `"-- visual -- N"` (matches `"-- insert --"` style at statusln.asm:246).
- **Option B:** `"-- VISUAL -- N chars"` — wordier, clearer about units.
- **Option C:** `"VISUAL N"` — terse.

**Q5 — Counted-motion semantic in VISUAL.**
- **Option A (recommended):** dispatch_visual includes digits 0-9 → parser_handle_digit; counted motions work just like in NORMAL. Closes the dispatch_visual open question per deferred-work.md:99 with a vi-faithful policy.
- **Option B:** Omit digits from dispatch_visual; counts dropped silently in VISUAL. Smaller dispatch table (-30 B); breaks vi muscle memory.

**Q6 — Digit-keystroke status update in VISUAL.**
- **Option A (recommended):** Stay quiet — count_accumulator is internal parser state; status only refreshes when a motion completes. Matches vi UX (the digit is not user-visible; the result of the count is).
- **Option B:** Update status on every digit (`v3` shows `"-- visual -- 1 [3]"`). Trade-off: more UX feedback at the cost of ~15 B of status-compose work + cognitive load.

**Q7 — `visual_cancel` as a separate Public symbol vs aliased.**
- **Option A (recommended):** Alias via existing `enter_normal_mode`. No new symbol.
- **Option B:** Add `visual_cancel` to visual.asm Public surface. Adds a symbol; same behaviour. Future visual_apply_operator (Story 3.6+) can tail-JP it for the apply-AND-exit pattern, but enter_normal_mode works equally.

**Q8 — Commit strategy.**
- **Option A (recommended):** Single dev commit per the 2.11/2.12/2.13/3.1/3.2 precedent.
- **Option B:** Two commits — one for the cross-cutting state+statusln plumbing (Task 1), one for the visual.asm body + dispatch + tests (Tasks 2-7). Cleaner bisect surface but breaks established pattern.

### NFR9 budget arithmetic (worked example)

Pre-3.3 footprint: **6503 B / 79.4% of 8192 B / 1689 B headroom** (per Story 3.2 close).

Story 3.3 projected deltas (positive = grows footprint; negative = shrinks):
- `src/visual.asm` new module body: visual_enter_char (~23 B) + visual_extend (~27 B) + visual_compose_status (~25 B) = **+75 B**
- `src/dispatch.asm` dispatch_visual extension: 19 new entries × 3 B = **+57 B**
- `src/dispatch.asm` enter_visual_mode retirement: -9 lines × ~2 B avg = **-18 B**
- `src/edits.asm` edits_compose_or_clear MODE_VISUAL arm: **+7 B**
- `src/statusln.asm` msg_mode_visual_prefix (14 B) - msg_mode_visual (13 B) retirement: **+1 B**
- `src/statusln.asm` status_u16_to_dec relocation (+~50 B) - `src/fileio.asm` fileio_u16_to_dec deletion (-~50 B): **+0 B net**
- `src/vibe.asm` new INCLUDE line + banner comment: **+0 B** (comments are stripped; INCLUDE is parsed not emitted)

Subtotal code growth: **+122 B**

State growth (NOT counted in NFR9 — state.inc is data, not code; 64 KB TPA budget):
- `status_compose_scratch` 32 B - retired `fileio_status_scratch` 48 B = **-16 B state** (Q3 Option A nets)

**Projected post-3.3 footprint: 6503 + 122 = 6625 B / 80.9% of 8192 B / 1567 B headroom.**

Generous runway remaining for Stories 3.4-3.8:
- 3.4 (V-line): ~80-100 B (visual_enter_line + V entry in dispatch_normal + V dispatch_visual extensions for line-anchored motions; reuses visual_compose_status with KIND_LINE-style formatting)
- 3.5 (Ctrl-V-block): ~120-150 B (visual_enter_block + rectangle compute + Ctrl-V entry + status format with rows×cols)
- 3.6-3.8 (operators d/y/c/>/</~): ~200-300 B (visual_apply_operator + 6 per-operator bodies)
- Total Epic 3 remaining projection: ~400-550 B → post-Epic-3 ~7025-7175 B / 86-88% of 8192 B / ~1017-1167 B headroom. Within ceiling.

### Test count target

214 (post-3.2) → **220 PASS** (+6 new from Story 3.3) / 1 deliberate-fail (`harness_fail` sentinel) unchanged.

### Project Structure Notes

- `src/visual.asm` is THE first NEW module since Story 3.1 added `src/search.asm`. AR25 chain order is fixed by architecture.md:946; insert between edits.asm and search.asm.
- `inc/state.inc` is the AR25-final INCLUDE (post-`ORG 0x0100`); the new `status_compose_scratch` cell follows the existing positional declaration discipline (advance `static_off` by 32 B).
- `test/cases/visual_*.asm` files follow the same INCLUDE-chain prologue/epilogue as Story 3.1's `test/cases/search_*.asm` files. The bulk patch (Task 6.2) extends the chain by ONE line.
- No project-context.md exists in the planning artifacts — Story 3.3 relies on the architecture / epics / PRD trio plus the previous-story implementation artifacts.

### References

- **Epic 3 narrative:** `_bmad-output/planning-artifacts/epics.md:1480-1635` (Epic 3 header + Stories 3.1-3.5).
- **Story 3.3 epic AC source:** `_bmad-output/planning-artifacts/epics.md:1557-1597` (the original 9-AC narrative).
- **Architecture AR25 INCLUDE chain:** `_bmad-output/planning-artifacts/architecture.md:937-950` (the canonical order with visual.asm between edits and search).
- **Architecture module dependency graph:** `_bmad-output/planning-artifacts/architecture.md:1402-1431` (visual.asm sits under dispatch.asm as a sibling of edits/motions/exline).
- **Architecture mode-byte SR4:** `_bmad-output/planning-artifacts/architecture.md:447-451` (MODE_VISUAL implies visual_submode is VIS_CHAR/VIS_LINE/VIS_BLOCK).
- **PRD FR15 (visual entry):** `_bmad-output/planning-artifacts/prd.md:718`.
- **PRD FR33 (character selection):** `_bmad-output/planning-artifacts/prd.md:752`.
- **PRD NFR9 (8192 B ceiling, amended 2026-05-17):** `_bmad-output/planning-artifacts/prd.md:848` with full amend history.
- **Existing enter_visual_mode (to be retired):** `src/dispatch.asm:334-357`.
- **Existing dispatch_visual table (to be extended):** `src/dispatch.asm:621-626`.
- **Existing enter_normal_mode (reused for VISUAL exit):** `src/dispatch.asm:276-294` with explicit VISUAL-exit docstring note at line 282-283.
- **Existing edits_compose_or_clear (to be extended):** `src/edits.asm:1321-1335`.
- **Existing parser_clear:** `src/parser.asm:228-235`.
- **Existing status_set_message:** `src/statusln.asm:105-127` (ends in RET — tail-JP safe per Story 3.2 verification).
- **Existing fileio_u16_to_dec (to be relocated):** `src/fileio.asm:1531-~1560`.
- **state.inc visual_anchor + visual_submode declarations:** `inc/state.inc:49, 96`.
- **modes.inc MODE_VISUAL + VIS_CHAR equates:** `inc/modes.inc:26, 29`.
- **Story 3.1 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-1-forward-literal-search-pattern.md` (full story file with stub-retirement pattern documented).
- **Story 3.2 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-2-repeat-last-search-n-with-wrap.md` (Q-pin structure; tail-JP status_set_message optimization; sentinel band allocation).
- **deferred-work.md:99 — dispatch_visual open question owned by Story 3.3:** `_bmad-output/implementation-artifacts/deferred-work.md:99` (the digits/operators/'g'-prefix policy decision; resolved by Q5 Option A).
- **deferred-work.md:88 — mode transitions clear parser state policy:** resolved by Story 2.5 AC13; visual_enter_char preserves this contract.

## Dev Agent Record

### Agent Model Used

Amelia (claude-opus-4-7 with bmad-dev-story / bmad-quick-dev skill set)

### Debug Log References

(no live debug-log surfaces from the dev pass — everything compiled clean on first build; all 6 new tests passed on first run; sjasmplus's forward-reference resolution caught zero issues.)

### Completion Notes List

**Q1–Q8 pins resolved (all Option A at handoff with Ant):**
- Q1 (stub retirement) — `enter_visual_mode` body + AR23 docstring DELETED from `src/dispatch.asm`; the Public-block listing for the symbol was retired; the AR23 block for the slot now contains a retirement marker pointing at `src/visual.asm:visual_enter_char` (matches Story 3.1's `mode_search_prompt_stub` pattern).
- Q2 (decimal helper) — `fileio_u16_to_dec` relocated to `src/statusln.asm` as `status_u16_to_dec`; module-local marshalling cell renamed `fileio_dec_dest` → `status_dec_dest`. fileio's one caller (`fileio_compose_filename_count_suffix`) updated. AR12 home — statusln owns status-line numeric composition.
- Q3 (shared scratch) — new `status_compose_scratch` cell in `inc/state.inc` (Q3 Option A). **Spec drift caught & adjusted:** Task 1.1 specified 32 B but `fileio_status_scratch`'s legacy `ASSERT $ - fileio_status_scratch >= 48` proves fileio's max banner needs 48 B (`<filename> N bytes written` = ~36 B per fileio.asm:1629). Sized the shared cell at **48 B** to preserve fileio's headroom; visual.asm uses only the first 19 B. Documented in the state.inc comment + this completion note. Memory `feedback_create_story_cross_check` cited.
- Q4 (status format) — `"-- visual -- N"` (matches `"-- insert --"` neighbour). `msg_mode_visual_prefix: DEFB "-- visual -- ", 0` (14 B incl NUL) in statusln.asm replaces the retired bare `msg_mode_visual`.
- Q5 (counted motions) — `dispatch_visual` includes digits `0..9` → `parser_handle_digit`. Counted-motion semantic verified by `test/cases/visual_counted-motion.asm` (0xB4) — `count_accumulator = 3` + `motion_l` → cursor=3, count=4.
- Q6 (digit keystroke quiet) — status unchanged on digit press; the count_accumulator update is parser-internal. Confirmed by the AC9 narrative ("status remains '-- visual -- N' momentarily ... then the motion fires").
- Q7 (visual_cancel) — NO separate symbol; the existing `enter_normal_mode` handles VISUAL exit (Q7 Option A). Verified by `test/cases/visual_esc-cancels.asm` (0xB2).
- Q8 (commit strategy) — single dev commit pending Ant's go.

**Byte-count delta vs projection:**
| Element | Projected | Actual | Note |
|---|---|---|---|
| Total ROM growth | +122 B | **+76 B** | -46 B vs projection |
| Pre-3.3 footprint | 6503 B | 6503 B | |
| Post-3.3 footprint | 6625 B | **6579 B** | 80.3% of 8192 B; 1613 B headroom |

The -46 B vs projection came primarily from the fileio.asm side: retiring `fileio_status_scratch` (DEFS 48,0 — emits 48 bytes of code-section zero fill) and `fileio_dec_dest` (DEFW 0 — 2 bytes) replaced them with state.inc EQUs (zero code emission). The story's NFR9 arithmetic mis-categorised these as "state, not code" — they were actually emitted bytes in fileio.asm's data section past its RET. Net effect: ~50 B of code-section savings absorbed into the visual.asm growth.

**NFR18 byte-identical rebuild:** two `make clean && make all` cycles produced identical `vibe.com` SHA-1: `57147c2609e1e99557414501363e2ebdeb8a353d`.

**Test count:** 214 → **220 PASS** (+6 new from Story 3.3) / 1 deliberate-fail (`harness_fail` sentinel) unchanged. Target hit exactly.

**Spec drift caught during dev pass (per `feedback_create_story_cross_check`):**
1. **Task 1.1 — `status_compose_scratch` sizing.** Story called for 32 B; fileio's legacy `ASSERT $ - fileio_status_scratch >= 48` pinned fileio's minimum at 48 B (max banner `"<filename> N bytes written"` ≈ 36 B with headroom; `FILENAME_BUFFER_SIZE = 16` per inc/equates.inc:49). Adjusted to 48 B; ASSERT removed since `static_off` discipline pins the value precisely.
2. **Task 3.1 — `parser_handle_motion_prefix` symbol.** Story said `dispatch_visual['g']` routes to `parser_handle_motion_prefix`; verified at `src/parser.asm` line 220+ (the symbol exists, mode-agnostic, sets `pending_motion_prefix='g'`; next motion key fires the gg motion via the dispatcher).
3. **Task 5.1 — net byte delta** for the `edits_compose_or_clear` arm: story projected `+7 B`; actual is `+5 B` (the existing `JP Z, parser_clear` 3-byte op became `JR NZ, .has_operator` 2-byte op, then 3 new instructions: `LD A,(mode_byte)` 3 B + `CP MODE_VISUAL` 2 B + `JP Z, visual_extend` 3 B = +8 B, less the 3 saved from JP→JR = +5 B). Inside projection tolerance.

### File List

**Modified:**
- `src/dispatch.asm` (Task 2 — retire `enter_visual_mode` stub + retarget `dispatch_normal['v']` to `visual_enter_char`; Task 3 — extend `dispatch_visual` 1 → 20 entries: Esc + $ + 0..9 + G + b + g + h/j/k/l + w; Dependencies block extended with src/visual.asm entry)
- `src/edits.asm` (Task 5 — `edits_compose_or_clear` MODE_VISUAL arm added on the bare-motion branch; docstring + Dependencies block updated)
- `src/fileio.asm` (Task 1.2 — `fileio_u16_to_dec` retired in favour of relocated `status_u16_to_dec`; Task 1.1 — `fileio_status_scratch` and `fileio_dec_dest` retired; module-header State block updated)
- `src/statusln.asm` (Task 1.2 — new public `status_u16_to_dec` body + `status_dec_dest` module-local cell; Task 1.3 — new `msg_mode_visual_prefix` string + retired bare `msg_mode_visual`; module-header Public + State blocks updated)
- `src/vibe.asm` (Task 6.1 — new `INCLUDE "visual.asm"` between edits.asm and search.asm per architecture.md:946 long-planned slot; comment narrative updated for surrounding modules)
- `inc/state.inc` (Task 1.1 — new shared 48-B `status_compose_scratch` cell between `top_line_offset` and `input_tick_counter`; module-header Public block updated)
- `_bmad-output/implementation-artifacts/sprint-status.yaml` (last_updated audit log + flip `3-3-visual-character-mode` to in-progress, then to review at handoff)
- `_bmad-output/implementation-artifacts/3-3-visual-character-mode.md` (this file — Status flip, task ticks, Dev Agent Record populated)

**Added:**
- `src/visual.asm` (Task 4 — NEW module; public `visual_enter_char` + `visual_extend`; module-local helper `visual_compose_status`; AR25 chain slot between edits.asm and search.asm)
- `test/cases/visual_v-enters-mode.asm` (Task 7.1 — sentinel 0xB0)
- `test/cases/visual_motions-extend-selection.asm` (Task 7.2 — sentinel 0xB1)
- `test/cases/visual_esc-cancels.asm` (Task 7.3 — sentinel 0xB2)
- `test/cases/visual_backward-extends.asm` (Task 7.4 — sentinel 0xB3)
- `test/cases/visual_counted-motion.asm` (Task 7.5 — sentinel 0xB4)
- `test/cases/parser_v-dispatch.asm` (Task 7.6 — sentinel 0xEB)

**Bulk-patched (Task 6.2 — INCLUDE chain extended):**
- 202 of the 215 files under `test/cases/*.asm` — every test that INCLUDEs the production chain (specifically `src/edits.asm` AND `src/search.asm`). Added one line `INCLUDE "../../src/visual.asm"` between the edits and search INCLUDEs. The 13 untouched tests are unit-level harnesses that don't INCLUDE the production chain (e.g., `dispatch_binary-search-*.asm`).

### Change Log

| Date | Story Version | Description | Author |
|------|---------------|-------------|--------|
| 2026-05-18 | UAT done | Hardware UAT CONFIRMED by Ant on real MicroBeast — all 17 AC9 steps checked out end-to-end. Story Status flipped review → done; sprint-status mirrors. FR15 + FR33 closed. Sentinel band 0xB0..0xB4 + 0xEB consumed; band 0xB5..0xBF reserved for Story 3.4 (V) + 3.5 (Ctrl-V). | Ant (UAT) |
| 2026-05-18 | Dev pass | Amelia (bmad-dev-story) implemented all 8 tasks per Q1-Q8 Option A pins (single dev pass; clean first build; 6/6 new tests PASS on first run; 202 bulk-patched tests still PASS). NFR18 byte-identical SHA-1 `57147c2609e1e99557414501363e2ebdeb8a353d` across two `make clean && make all` cycles. Final footprint 6579 B / 80.3% of 8192 B / 1613 B headroom — 46 B under projection (the unprojected fileio.asm savings from migrating DEFS 48,0 + DEFW 0 cells to state.inc EQUs). Test count 214 → 220 PASS (+6 visual_* + parser_v-dispatch) / 1 deliberate-fail unchanged. Spec drift caught: status_compose_scratch sized at 48 B (story said 32 B; fileio's legacy ASSERT proves 48 B is the floor). Status flipped ready-for-dev → review; sprint-status mirrors. AC9 hardware UAT script pasted inline at handoff to Ant. | Amelia (dev) |
| 2026-05-18 | Initial | Story 3.3 contexted from epics line 1557. FR15 (visual entry) + FR33 (character selection) closure. New `src/visual.asm` module (visual_enter_char + visual_extend public + visual_compose_status local); dispatch_visual extended from 1 → 20 entries (motions + digits + g-prefix); edits_compose_or_clear gains MODE_VISUAL routing arm; statusln.asm gains `msg_mode_visual_prefix` + relocated `status_u16_to_dec` (Q2 pin); inc/state.inc adds shared `status_compose_scratch` (32 B; Q3 pin); src/dispatch.asm enter_visual_mode stub retired (Q1 pin matches Story 3.1 mode_search_prompt_stub retirement). 10 ACs, 8 tasks, 6 new headless tests (sentinel band 0xB0..0xB4 + 0xEB), 17-step hardware UAT. Projected post-3.3 footprint: 6625 B / 80.9% of 8192 B / 1567 B headroom — within budget; no NFR9 amend. 8 implementation questions saved for pre-dev resolution with Ant. | Bob (SM) |
