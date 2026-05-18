# Story 3.4: Visual line mode

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `V` (capital V) in NORMAL mode to enter visual line mode — with `visual_anchor` pinned at the *line-start* of the entry cursor, mode-agnostic motions extending the selection in whole-line units (line count = `|line(cursor) - line(anchor)| + 1`), the status row reporting "`-- visual line -- N`", and Esc returning to NORMAL leaving the cursor at the extent,
So that FR34 (line-wise visual selection) closes — completing the visual-mode submodes pair with Story 3.3's VIS_CHAR — and the Story 3.6+ visual operators (d/y/c/>/</~) have a working VIS_LINE range to apply over.

## Acceptance Criteria

**AC1 — `dispatch_normal['V']` lands a new entry at the sorted slot between 'O' (0x4F) and 'a' (0x61), targeting `visual_enter_char`'s sibling `visual_enter_line` in `src/visual.asm`.**

**Given** `src/dispatch.asm:dispatch_normal` (currently 27 entries; the slot between `'O'` at line 542-544 and `'a'` at line 545-547 is unbound and falls through to `unbound_normal`)
**When** Story 3.4 lands
**Then** a new 3-byte entry `DEFB 'V' ; DEFW visual_enter_line` is inserted between the `'O'` and `'a'` entries, with `ASSERT 'V' > 'O'` and `ASSERT 'a' > 'V'` flanking it (matching the dispatch_normal pin convention at lines 494-598)
**And** `DISPATCH_NORMAL_COUNT` (the `($ - .entries) / 3` EQU at line 599) auto-recomputes from 0x1C (28) → 0x1D (29)
**And** `dispatch_normal` table grows by **+3 B** (the new entry; ASSERTs are assembly-time only)
**And** the `src/dispatch.asm` module-header Dependencies block's `src/visual.asm` entry (added by Story 3.3 at lines 150-156) extends by one line documenting `visual_enter_line` as the second forward-ref symbol in this module
**And** `'V'` is NOT bound in `dispatch_visual` for Story 3.4 — re-entering line mode from inside VIS_CHAR (vi convention: V toggles char→line) is **deferred to a polish story / Story 3.5's Ctrl-V neighbour decision** (Q1 pin); for now `V` in VISUAL falls through to `unbound_visual` and the user must `Esc` then `V`.

**AC2 — `visual_enter_line` (NEW in `src/visual.asm`) pins `visual_anchor` at the line-start of the entry cursor, sets submode VIS_LINE, composes the entry status, and tail-JPs `parser_clear`.**

**Given** `src/visual.asm` (the placeholders block at lines 212-220 — the comment-only future-symbol declaration that Story 3.3 left for this story to replace)
**When** Story 3.4 lands
**Then** the placeholder comment block is removed and `visual_enter_line:` lands as the second labelled entry in the module (immediately after `visual_extend`'s body at line 162, before `visual_compose_status` at line 188; OR adjacent to `visual_enter_char` — implementation choice for code-locality)
**And** the body performs in order:
1. `LD A, MODE_VISUAL ; LD (mode_byte), A` — flip mode (~5 B)
2. `LD A, VIS_LINE ; LD (visual_submode), A` — set sub-mode (~5 B)
3. `LD HL, (cursor_offset) ; CALL motion_find_line_start` — HL = line-start of the entry cursor (~6 B; motion_find_line_start at `src/motions.asm:636` walks backward through the gap buffer to the byte just past the previous 0x0A, or 0 for the first line)
4. `LD (visual_anchor), HL` — pin the anchor at the line-start (~3 B; vi-faithful — selection always grows in whole-line units from this anchor point)
5. `LD HL, 1` — entry line count = 1 (anchor and cursor are on the same line; line count math `|line(c) - line(a)| + 1` reduces to `0 + 1 = 1`) (~3 B)
6. `CALL visual_compose_status_line` — composes "`-- visual line -- 1`" into `status_compose_scratch` and tail-JPs `status_set_message` (~3 B; the new shared-tail entry per AC4)
7. `JP parser_clear` — drop any pending count/operator/prefix from before the `V` keystroke (~3 B; AC13 contract from Story 2.5)
**And** total `visual_enter_line` body size: **~28 B**
**And** AR23 docstring documents: `In: A = 'V' (MC4 — ignored after dispatch)`; `Out: mode_byte = MODE_VISUAL; visual_submode = VIS_LINE; visual_anchor = line-start offset of the entry cursor (NOT the cursor itself — frozen for the visual-line session); cursor_offset UNCHANGED; status_buffer = "-- visual line -- 1"; parser state zeroed.`; `Trashes: A, BC, DE, HL, F`; `Calls: motion_find_line_start (CALL — reads cursor_offset, walks via motion_byte_at_logical); visual_compose_status_line (CALL); parser_clear (tail-JP).`

**AC3 — `visual_extend` dispatches on `visual_submode`: VIS_CHAR uses the existing `|cursor - anchor| + 1` path; VIS_LINE walks the buffer counting LFs.**

**Given** `src/visual.asm:visual_extend` (the Story 3.3 body at lines 148-162 — currently single-path `|cursor - anchor| + 1`)
**When** Story 3.4 lands
**Then** `visual_extend` gains a submode-dispatch prologue: read `visual_submode`, branch to the existing CHAR arm or the new LINE arm:
```
visual_extend:
    LD      A, (visual_submode)
    CP      VIS_LINE
    JR      Z, .line_arm
    ;; existing VIS_CHAR body (Story 3.3) — fall through:
.char_arm:
    LD      HL, (cursor_offset)
    LD      DE, (visual_anchor)
    ; ... existing |cursor - anchor| + 1 compute ...
    INC     HL
    CALL    visual_compose_status        ; CHAR prefix ("-- visual -- N")
    JP      parser_clear
.line_arm:
    CALL    visual_count_lines           ; HL = line count
    CALL    visual_compose_status_line   ; LINE prefix ("-- visual line -- N")
    JP      parser_clear
```
**And** net cost in `visual_extend`: **+11 B** (the prologue: `LD A,(visual_submode)` 3 B + `CP VIS_LINE` 2 B + `JR Z, .line_arm` 2 B + the `.line_arm` body: `CALL visual_count_lines` 3 B + `CALL visual_compose_status_line` 3 B + `JP parser_clear` 3 B; the existing `.char_arm` body is unchanged; the `.line_arm` reuses the same `JP parser_clear` tail conceptually but is its own emit since labels can't share)
**And** VIS_BLOCK (Story 3.5) will land here as a third arm in the dispatch — `visual_extend`'s prologue extends to a 3-way branch. For Story 3.4 the VIS_BLOCK case is unreachable (no `visual_enter_block` writer yet); the JR-NZ fall-through to `.char_arm` is fine as a defensive path until Story 3.5 adds its `.block_arm`.
**And** AR23 docstring updated: add a "Story 3.4 — VIS_LINE arm" note documenting the submode dispatch and the line-count math.

**AC4 — `visual_compose_status` is refactored to share a common tail with `visual_compose_status_line` — both load their own prefix-source + length, then jump to a shared LDIR+digits+terminate+emit block.**

**Given** `src/visual.asm:visual_compose_status` (Story 3.3 body at lines 188-200) — currently hardcodes `LD HL, msg_mode_visual_prefix ; LD BC, MSG_MODE_VISUAL_PREFIX_LEN` before the LDIR
**When** Story 3.4 lands
**Then** the helper is split into two entry points sharing a common tail:
```
visual_compose_status_line:                ; LINE prefix ("-- visual line -- ")
    PUSH    HL                             ; save count across prefix copy
    LD      HL, msg_mode_visual_line_prefix
    LD      BC, MSG_MODE_VISUAL_LINE_PREFIX_LEN
    JR      _visual_compose_finish
visual_compose_status:                     ; CHAR prefix ("-- visual -- ")
    PUSH    HL
    LD      HL, msg_mode_visual_prefix
    LD      BC, MSG_MODE_VISUAL_PREFIX_LEN
    ;; fall through
_visual_compose_finish:
    LD      DE, status_compose_scratch
    LDIR
    POP     HL                             ; restore count
    CALL    status_u16_to_dec
    XOR     A
    LD      (DE), A
    LD      HL, status_compose_scratch
    XOR     A
    JP      status_set_message
```
**And** net cost: **+10 B** (the new `visual_compose_status_line` entry: PUSH HL 1 + LD HL,prefix 3 + LD BC,len 3 + JR 2 = 9 B; plus the `_visual_compose_finish` label is zero-cost; the existing `visual_compose_status` body shrinks by the LD DE moving down — wash within ±1 B). Choosing the JR-fall-through pattern over IX-parametrization (Q4 pin Option A) — adds one ~10 B entry point and keeps both call sites' ABI as `HL = count` (no register juggling).
**And** the existing `MSG_MODE_VISUAL_PREFIX_LEN EQU 13` at `src/visual.asm:209` is joined by a new `MSG_MODE_VISUAL_LINE_PREFIX_LEN EQU 18` constant (length of "`-- visual line -- `" — 2 dashes + space + "visual" + space + "line" + space + 2 dashes + space = 18 ASCII chars; NOT counting the NUL).
**And** AR23 docstrings: both entries get In/Out/Trashes/Calls; the common-tail label gets a "private label — entries fall through here; do NOT call directly" header comment.

**AC5 — `visual_count_lines` (NEW module-local helper in `src/visual.asm`) walks the gap buffer between `visual_anchor` and `motion_find_line_start(cursor_offset)`, counting LF bytes; returns line count = LF count + 1.**

**Given** `src/visual.asm` (new helper)
**When** invoked from `visual_extend`'s VIS_LINE arm (AC3)
**Then** the body performs:
1. `LD HL, (cursor_offset) ; CALL motion_find_line_start` — HL = cursor's line-start (~6 B)
2. `LD DE, (visual_anchor)` — DE = anchor (also a line-start, pinned by visual_enter_line per AC2) (~4 B)
3. **Compute min(HL, DE) and max(HL, DE) for the walk window:**
   - `OR A ; SBC HL, DE` — HL = cursor_ls - anchor (signed)
   - `JR Z, .single_line` — same line-start → line count = 1 (early exit; ~5 B branch + label)
   - `JR NC, .forward` — forward motion: cursor_ls > anchor; HL holds positive diff
   - `;; backward: cursor_ls < anchor — swap so HL=cursor_ls (min), DE=anchor (max)`
   - `ADD HL, DE ; EX DE, HL` — HL = anchor, DE = cursor_ls → swap them: HL = cursor_ls (min), DE = anchor (max)
   - `JR .walk`
   - `.forward: ADD HL, DE ; EX DE, HL` — HL = cursor_ls (max), DE = anchor (min); but we want HL=min — swap one more time → HL = anchor (min), DE = cursor_ls (max)
4. **Walk [HL, DE) counting LF bytes:**
   - `.walk: LD BC, 0` — LF count
   - `.loop: LD A, H ; CP D ; JR NZ, .scan ; LD A, L ; CP E ; JR Z, .done`  ← HL == DE → walked the full range
   - `.scan: CALL motion_byte_at_logical ; CP 0x0A ; JR NZ, .next ; INC BC`
   - `.next: INC HL ; JR .loop`
5. `.done: LD H, B ; LD L, C ; INC HL` — line count = LFs + 1 (~5 B)
6. `RET`
7. `.single_line: LD HL, 1 ; RET` — fast path for same-line case (~4 B)
**And** total `visual_count_lines` body: **~50-60 B**
**And** AR23 docstring documents: `In: (none — reads cursor_offset, visual_anchor)`; `Out: HL = line count (1..65535); cursor_offset / visual_anchor UNCHANGED.`; `Trashes: A, BC, DE, HL, F`; `Calls: motion_find_line_start (CALL — backward-resolves to src/motions.asm:636); motion_byte_at_logical (CALL — backward-resolves to src/motions.asm:557).`
**And** an inline comment notes the math identity: "Walking from offset min (line-start) to offset max (line-start or any byte on max's line), the number of LFs encountered in `[min, max)` equals the difference in line indices. Therefore `line_count = LFs + 1` regardless of where max lands within its line — the cursor doesn't have to be on its line-start for the math to come out right, but the anchor MUST be (which is the AC2 invariant)."

**AC6 — `src/statusln.asm` gains `msg_mode_visual_line_prefix: DEFB "-- visual line -- ", 0` (19 B incl NUL) adjacent to `msg_mode_visual_prefix` at line 339.**

**Given** `src/statusln.asm:339` (the Story 3.3 `msg_mode_visual_prefix: DEFB "-- visual -- ", 0` line — 14 B incl NUL)
**When** Story 3.4 lands
**Then** `msg_mode_visual_line_prefix: DEFB "-- visual line -- ", 0` is added immediately after (one line below; same alignment / comment style)
**And** a doc-comment block above the new label documents: "Story 3.4 — VIS_LINE submode prefix. 18 ASCII chars + NUL = 19 B. visual_compose_status_line LDIRs the first 18 bytes (without the NUL) into status_compose_scratch; the digits follow at offset 18; then visual_compose_status_line writes its own NUL terminator and hands off to status_set_message."
**And** the `src/statusln.asm` module-header Public block extends to list `msg_mode_visual_line_prefix` (parallel to the Story 3.3 `msg_mode_visual_prefix` listing)
**And** net cost in `src/statusln.asm`: **+19 B** of data-section bytes (one DEFB line; no code emit)

**AC7 — Status format is `"-- visual line -- N"` where N is the line count, 1..65535 decimal with leading zeros suppressed.**

**Given** the AC4 + AC5 compose path
**When** I inspect what lands in `status_buffer`
**Then** the format is the literal byte sequence `"-- visual line -- "` (18 chars + trailing space; matches the `"-- visual -- "` neighbour at `src/statusln.asm:339`) followed by the decimal line count, NUL-padded by `status_set_message`'s natural trailing-space fill
**And** the entry-time line count is `1` (single decimal digit): `V` at any cursor position on a non-empty line — anchor pinned at that line's start, cursor unchanged, `|line(cursor) - line(anchor)| = 0`, count = `0 + 1 = 1`
**And** examples on a buffer `"abc\nfoo\nbar\nxyz"` (4 lines; LFs at offsets 3, 7, 11; total 15 B):
- `V` from offset 0 (line 1, col 0) → anchor = 0; line count = 1; status `"-- visual line -- 1"`
- `V` from offset 2 (line 1, col 2) → anchor = 0 (line-start of line 1); cursor stays at 2; line count = 1; status `"-- visual line -- 1"`
- `V` from offset 0, then `j` → cursor advances to offset 4 (line 2 col 0 via motion_j's sticky-column path); cursor's line-start = 4; LF count in [0, 4) = 1 (the LF at offset 3); line count = 2; status `"-- visual line -- 2"`
- `V` from offset 0, then `j j j` → cursor at line 4 (offset 12 or 14 depending on sticky-column); cursor's line-start = 12; LFs in [0, 12) = 3; line count = 4; status `"-- visual line -- 4"`
- `V` from offset 8 (line 3 col 0), then `k` → cursor moves up to offset 4 (line 2 col 0); cursor's line-start = 4; anchor = 8 (line 3 start); SWAP — walk [4, 8); LFs in [4, 8) = 1 (the LF at 7); line count = 2; status `"-- visual line -- 2"` (backward arm of AC5)
- `V` from offset 0, then `5j` on a 4-line file → motion_j with count 5 lands at the last line (the motion handler clamps to file_length-aware destination per Story 2.5/2.7); line count clamps to the file's total line count; status updates accordingly

**AC8 — Esc returns to NORMAL via the existing `enter_normal_mode`; cursor stays at extent; `visual_anchor` and `visual_submode` are zombie state until the next visual entry.**

**Given** `mode_byte == MODE_VISUAL` with `visual_submode == VIS_LINE` and the user presses Esc (0x1B)
**When** `dispatch_visual['Esc']` routes to `enter_normal_mode` (entry 1 of dispatch_visual at `src/dispatch.asm:644-645`; UNCHANGED by Story 3.4)
**Then** `enter_normal_mode` body (at `src/dispatch.asm:294` — UNCHANGED) flips `mode_byte = MODE_NORMAL`, emits `msg_mode_normal` (empty banner — status pads with spaces), and tail-JPs `parser_clear`
**And** `cursor_offset` UNCHANGED (matches AC8 from Story 3.3 — vi-faithful "cursor stays at extent on cancel")
**And** `visual_anchor` UNCHANGED in state (it remains as the line-start of the entry's first line; meaningless until the next `V` or `v` re-pins it; matches the SR4 / visual.asm:42-45 zombie-state contract from Story 3.3)
**And** `visual_submode` UNCHANGED in state — remains VIS_LINE post-exit; the next `v` overwrites it to VIS_CHAR, the next `V` overwrites it back to VIS_LINE, the next Ctrl-V (Story 3.5) overwrites it to VIS_BLOCK. SR4 invariant: `visual_submode` is meaningful ONLY when `mode_byte == MODE_VISUAL`.
**And** the existing `enter_normal_mode` docstring at `src/dispatch.asm:282-283` ("Esc-from-COMMAND and Esc-from-VISUAL arrive here too") needs **zero changes** for Story 3.4 — it already covers VISUAL exit generically; submode-specific cleanup is unnecessary.

**AC9 — Hardware UAT passes the visual-line journey script on the real MicroBeast.**

**Given** I rebuild `vibe.com` with the Story-3.4 patch applied and `make push` it to MicroBeast
**When** I run the UAT script below from CCP
**Then** every step matches the predicted observation:

```
 1. STAT B:fizzbuzz.fs       → confirm fixture present (multi-line
                               source file with at least 8 lines —
                               e.g. the FORTH fizzbuzz that 3.3
                               UAT'd against; if not present, any
                               multi-line .fs / .txt file works)
 2. vibe fizzbuzz.fs         → cursor at offset 0 (first byte of
                               line 1); mode NORMAL; status banner
                               empty; visual_anchor irrelevant;
                               visual_submode irrelevant
                               [[feedback_uat_trace_cursor]]: post-:e
                               cursor lands at offset 0 (NOT EOF),
                               so V from this state pins anchor at 0
 3. V                        → status "-- visual line -- 1" (AC2);
                               mode = MODE_VISUAL; visual_submode =
                               VIS_LINE; visual_anchor = 0 (line-
                               start of line 1; since cursor was
                               at offset 0 already, anchor pins
                               there); cursor unchanged at 0
 4. j                        → motion_j advances cursor to next-
                               line, same-column-or-clamped (Story
                               2.7 sticky-column); cursor lands
                               somewhere on line 2; visual_extend
                               fires via edits_compose_or_clear's
                               MODE_VISUAL arm; visual_count_lines
                               computes LFs in [0, cursor_line_start)
                               = 1; line count = 2; status
                               "-- visual line -- 2"
 5. j j                      → cursor advances to line 4; line
                               count = 4; status
                               "-- visual line -- 4"
 6. k                        → backward motion; cursor moves up
                               to line 3; line count = 3; status
                               "-- visual line -- 3"
 7. l                        → cursor moves right one column on
                               the SAME line; cursor's line-start
                               unchanged from previous step;
                               line count UNCHANGED at 3; status
                               "-- visual line -- 3" (line-mode
                               semantic — within-line motion does
                               NOT change the line-count count;
                               AC5 math: LFs in [anchor, cursor_ls)
                               unchanged because cursor_ls
                               unchanged)
 8. 5j                       → AC4-pattern counted motion: digit
                               '5' accumulates into count_accumulator
                               via dispatch_visual['5'] →
                               parser_handle_digit (status remains
                               "-- visual line -- 3" momentarily;
                               Q6 quiet-on-digit policy from
                               Story 3.3 still applies); then 'j'
                               fires motion_j counted by 5 → cursor
                               jumps 5 lines down (or clamps to
                               last line if fewer); line count
                               recomputes; status updates
 9. gg                       → motion_gg via parser_handle_motion_prefix +
                               second 'g'; cursor returns to BOF
                               (offset 0); cursor's line-start = 0;
                               LFs in [0, 0) = 0; line count = 1;
                               status "-- visual line -- 1" (anchor
                               was 0, cursor's line-start is now 0,
                               same-line fast-path of AC5)
10. G                        → motion_G to last-line-start; cursor
                               jumps; line count = (total lines in
                               file); status updates with that
                               count (e.g. "-- visual line -- 12"
                               for a 12-line fizzbuzz)
11. Esc                      → enter_normal_mode (AC8); mode =
                               MODE_NORMAL; status pads to empty;
                               cursor stays at the last-line-start
                               extent; visual_anchor + visual_submode
                               unchanged in state (zombie)
12. v                        → re-enter VIS_CHAR (Story 3.3 path);
                               anchor re-pinned at the current
                               cursor (last-line-start); status
                               "-- visual -- 1" (CHAR prefix, NOT
                               line — submode flip from VIS_LINE
                               zombie to VIS_CHAR on the new entry)
13. Esc                      → exit; mode NORMAL; cursor stays
14. V                        → re-enter VIS_LINE; anchor re-pinned
                               at line-start of the current cursor
                               (last-line-start, which equals the
                               cursor since cursor is already at
                               a line-start); status
                               "-- visual line -- 1"
15. d                        → AC1 deferral: 'd' NOT bound in
                               dispatch_visual (operator wiring
                               lands Story 3.6); falls through to
                               unbound_visual; status "unbound key";
                               mode stays MODE_VISUAL with submode
                               VIS_LINE; cursor unchanged; selection
                               preserved
16. k                        → after the unbound 'd', motion_k
                               still works: cursor moves up; line
                               count recomputes; status
                               "-- visual line -- 2"
17. Esc                      → exit; mode NORMAL
18. :q                       → clean exit; buffer not dirty;
                               control returns to CCP
```

**AC10 — 5 headless tests under `test/cases/visual_*.asm` + 1 parser-dispatch test pass.**

**Given** `make test` runs from a fresh tree
**When** the new test cases are added (sentinel band 0xB5..0xB9 for the visual_* + 0xEC for the parser-dispatch coverage; band 0xB0..0xB4 + 0xEB consumed by Story 3.3; bands 0xBA..0xBD reserved for Story 3.5 V-block; 0xBE reserved by `harness_fail` infra)
**Then** the following 5 visual-line tests PASS:
- `visual_V-anchor-snaps-to-line-start.asm` (sentinel 0xB5) — buffer `"abc\nfoo\nbar"` (11 B); `cursor_offset = 5` (line 2, col 1 = the 'o' in "foo"); pre-set `mode_byte = MODE_NORMAL`, `visual_submode = VIS_CHAR` (sentinel value — confirms VIS_LINE writer overwrites). CALL `visual_enter_line`. Expect: `mode_byte = MODE_VISUAL`, `visual_submode = VIS_LINE`, `visual_anchor = 4` (line-start of line 2, NOT 5; AC2 — anchor snaps to line-start of cursor's line), `cursor_offset = 5` (UNCHANGED — AC2 — V does NOT move cursor on entry), `status_buffer` starts with `"-- visual line -- 1"` (19 chars: 18 prefix + '1'), `count_accumulator = 0` (parser_clear ran).
- `visual_line-forward-extends.asm` (sentinel 0xB6) — buffer `"abc\nfoo\nbar\nxyz"` (15 B; 4 lines, LFs at 3/7/11); `cursor_offset = 0`; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_LINE`, `visual_anchor = 0`. CALL `motion_j` (tail-JPs `edits_compose_or_clear` → MODE_VISUAL arm → `visual_extend` → `.line_arm` → `visual_count_lines`). Expect: `cursor_offset = 4` (line 2 start), `status_buffer` starts with `"-- visual line -- 2"`. CALL `motion_j` again. Expect: `cursor_offset = 8`, status `"-- visual line -- 3"`. CALL `motion_j` again. Expect: `cursor_offset = 12`, status `"-- visual line -- 4"`.
- `visual_line-backward-extends.asm` (sentinel 0xB7) — buffer `"abc\nfoo\nbar\nxyz"` (15 B); `cursor_offset = 12` (line 4 col 0); pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_LINE`, `visual_anchor = 12`. CALL `motion_k` (which tail-JPs edits_compose_or_clear). Expect: `cursor_offset = 8` (line 3 col 0), `status_buffer` starts with `"-- visual line -- 2"` (anchor=12, cursor_ls=8; backward arm: swap → walk [8, 12); 1 LF at 11; line count = 2). CALL `motion_k` again. Expect: `cursor_offset = 4`, status `"-- visual line -- 3"`. (Verifies the AC5 backward-swap arm).
- `visual_line-counted-motion.asm` (sentinel 0xB8) — buffer `"a\nb\nc\nd\ne"` (9 B; 5 lines, LFs at 1/3/5/7); `cursor_offset = 0`; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_LINE`, `visual_anchor = 0`, `count_accumulator = 3`. CALL `motion_j`. Expect: `cursor_offset = 6` (line 4 col 0; j × 3 advances 3 lines), `status_buffer` starts with `"-- visual line -- 4"` (LFs in [0, 6) = 3; line count = 4), `count_accumulator = 0` (parser_clear ran).
- `visual_line-within-line-motion-unchanged-count.asm` (sentinel 0xB9) — buffer `"abcde\nfgh"` (9 B; 2 lines); `cursor_offset = 0`; pre-set `mode_byte = MODE_VISUAL`, `visual_submode = VIS_LINE`, `visual_anchor = 0`. CALL `motion_l`. Expect: `cursor_offset = 1`, `status_buffer` starts with `"-- visual line -- 1"` (cursor_ls still 0; LFs in [0, 0) = 0; line count = 1; line count UNCHANGED across within-line motion — AC7 example 4). CALL `motion_l` four more times (advances cursor to offset 5, just past 'e'; per Story 2.5 motion_l does NOT cross the LF). Expect: `cursor_offset = 5` (or 4 — verify by reading motion_l's contract; Story 2.5 doc says "stops on the byte BEFORE the LF" — last cursor position on line 1 is offset 4 = 'e'; the LF at 5 itself is uncrossable. So 4 successive 'l' calls advance cursor 1→4, the fifth call is a no-op. Confirmed by `test/cases/motion_l-*.asm` patterns), status STILL `"-- visual line -- 1"` (LFs in [0, cursor_ls=0) still 0; line count still 1).

**And** the parser-dispatch coverage test PASSES:
- `parser_V-dispatch.asm` (sentinel 0xEC) — buffer `"hello\nworld"` (11 B); pre-set `cursor_offset = 3` (line 1 col 3 = 'l'), `mode_byte = MODE_NORMAL`, `status_dirty = 0x80` (sentinel — verify the dispatcher overwrote it). Drive `'V'` through `dispatch_key` with `dispatch_normal`: `LD A, 'V' ; LD HL, dispatch_normal ; LD B, DISPATCH_NORMAL_COUNT ; CALL dispatch_key`. Verify post-call: `mode_byte = MODE_VISUAL`, `visual_submode = VIS_LINE`, `visual_anchor = 0` (line-start of line 1; line 1 starts at offset 0; cursor was at 3 mid-line — AC2 line-start snap), `cursor_offset = 3` (UNCHANGED), `status_buffer` starts with `"-- visual line -- 1"`, `status_dirty = 1`. Confirms `dispatch_normal['V']` is wired end-to-end to `visual_enter_line` and the AC1 table-insertion landed in the right sorted slot (the binary-search must find 'V' between 'O' and 'a').

**Test count target: 220 → 226 PASS (+6) / 1 deliberate-fail (`harness_fail` sentinel) unchanged.**

## Tasks / Subtasks

- [x] **Task 0** (pre-dev pin with Ant — resolved Option A across the board):
  - [x] Q1 — `V`-in-VIS_CHAR submode-toggle policy. **Option A pinned.** `V` is bound only in `dispatch_normal`; pressing `V` while already in MODE_VISUAL falls through to `unbound_visual`. User must `Esc` then `V` to switch submodes.
  - [x] Q2 — Status format prefix for VIS_LINE. **Option A pinned.** `"-- visual line -- N"`.
  - [x] Q3 — Anchor pinning strategy. **Option A pinned.** `visual_anchor = motion_find_line_start(cursor_offset)`.
  - [x] Q4 — `visual_compose_status` parametrization. **Option A pinned.** Split into two entries with a shared fall-through tail `_visual_compose_finish`.
  - [x] Q5 — `visual_extend` submode dispatch. **Option A pinned.** Reads `visual_submode` at entry and branches inside visual.asm.
  - [x] Q6 — Line-count helper location. **Option A pinned.** Module-local `visual_count_lines` in `src/visual.asm`.
  - [x] Q7 — Test-count target. **Option A pinned.** +6 tests (5 visual + 1 parser-dispatch).
  - [x] Q8 — Commit strategy. **Option A pinned.** Single dev commit.

- [x] **Task 1** — Cross-cutting state + statusln plumbing:
  - [x] 1.1 — Added `msg_mode_visual_line_prefix: DEFB "-- visual line -- ", 0` (19 B incl NUL) to `src/statusln.asm` immediately after `msg_mode_visual_prefix`. Doc-comment block above per AC6.
  - [x] 1.2 — Extended the `src/statusln.asm` module-header Public block to include `msg_mode_visual_line_prefix` (Story 3.4).
  - [x] 1.3 — Confirmed `status_compose_scratch` (48 B; `inc/state.inc:122`) has 24 B slack over `"-- visual line -- 65535\0"` (24 B). No state.inc change.

- [x] **Task 2** — Extend `dispatch_normal` in `src/dispatch.asm`:
  - [x] 2.1 — Inserted 3-byte 'V' entry between 'O' and 'a' with `ASSERT 'V' > 'O'` and updated `ASSERT 'a' > 'V'`. Forward-refs `visual_enter_line`.
  - [x] 2.2 — `DISPATCH_NORMAL_COUNT` auto-recomputes via `($ - .entries) / 3` (build/vibe.lst confirms `LD B, DISPATCH_NORMAL_COUNT` resolves to `06 25` = 37). **Spec narrative drift caught**: story said "28 → 29" but actual count post-3.3 is 36 → 37 with this entry. Code is correct; sort-order ASSERTs pin it.
  - [x] 2.3 — Extended `src/dispatch.asm` module-header Dependencies block with a Story 3.4 paragraph documenting `visual_enter_line` as the second forward-ref symbol.
  - [x] 2.4 — `dispatch_visual` left UNCHANGED (Q1 Option A pin); still 20 entries post-3.3.

- [x] **Task 3** — Extend `src/visual.asm`:
  - [x] 3.1 — `visual_enter_line` body landed adjacent to `visual_enter_char` (the alternate placement option in AC2; chosen for code locality — both visual-entry handlers live together). AR23 docstring above per AC2's contract.
  - [x] 3.2 — Refactored `visual_compose_status` into the two-entry shared-tail shape: `visual_compose_status_line` enters first (LINE prefix), JRs to `_visual_compose_finish`; `visual_compose_status` (CHAR prefix) falls through to the same tail. `MSG_MODE_VISUAL_LINE_PREFIX_LEN EQU 18` added alongside the existing 13-B CHAR constant.
  - [x] 3.3 — Extended `visual_extend` with the submode-dispatch prologue. `.char_arm` label added for self-documentation; `.line_arm` calls `visual_count_lines` + `visual_compose_status_line` + tail-JP `parser_clear`. VIS_BLOCK falls through to .char_arm defensively (Story 3.5 will add `.block_arm`).
  - [x] 3.4 — `visual_count_lines` body landed as a module-local helper (~63 B emitted; mid-estimate of spec's 50-60 B range was 5 B short of the actual). The walk loop PUSHes DE around `motion_byte_at_logical` (which trashes DE per its contract — same gotcha that bit Story 2.6). AR23 docstring above; not in the Public block.
  - [x] 3.5 — Module-header Public block flipped `visual_enter_line` from PLACEHOLDER to LANDS; State-owned block now lists VIS_LINE as a `visual_submode` writer alongside VIS_CHAR; Dependencies block extended to include `src/motions.asm` (motion_find_line_start + motion_byte_at_logical).
  - [x] 3.6 — AR sweep clean: `BIOS_CONOUT`/`BDOS_CALL`/`CALL 0x0005` = zero matches; `LD (gap_(start|end)),` = zero matches. visual.asm remains a pure reader of buffer state.

- [x] **Task 4** — Headless tests (6 new files in `test/cases/`):
  - [x] 4.1 — `visual_V-anchor-snaps-to-line-start.asm` (sentinel 0xB5) — passes; pins anchor snaps to line-start (offset 4 from cursor=5), cursor unchanged, submode VIS_LINE, status "-- visual line -- 1", parser_clear ran.
  - [x] 4.2 — `visual_line-forward-extends.asm` (sentinel 0xB6) — passes; three motion_j calls verify forward arm + AC7 examples 3-4.
  - [x] 4.3 — `visual_line-backward-extends.asm` (sentinel 0xB7) — passes; two motion_k calls verify the backward-swap arm + AC7 example 5.
  - [x] 4.4 — `visual_line-counted-motion.asm` (sentinel 0xB8) — passes; count_accumulator=3 + motion_j → cursor=6, count=4.
  - [x] 4.5 — `visual_line-within-line-motion-unchanged-count.asm` (sentinel 0xB9) — passes; pins the LINE-mode signature semantic (within-line `l` does NOT change line count).
  - [x] 4.6 — `parser_V-dispatch.asm` (sentinel 0xEC) — passes; drives 'V' through dispatch_key end-to-end with cursor=3 mid-line, anchor pinned at line-start=0.
  - [x] 4.7 — Sentinel band reservations: 0xB5..0xB9 + 0xEC consumed; 0xBA..0xBD reserved for Story 3.5; 0xBE reserved by harness_fail.
  - [x] 4.8 — Fixture-seeding convention matches Stories 3.1/3.2/3.3.
  - [x] 4.9 — No bulk INCLUDE patch needed — visual.asm chain already wired by Story 3.3. Post-3.4 count: 214 tests INCLUDE visual.asm (208 pre-existing + 6 new).

- [x] **Task 5** — NFR18 byte-identical rebuild + UAT + sprint-status flip:
  - [x] 5.1 — NFR18 byte-identical SHA `4d3d7fa654aaa6c7bafe1c3e20c8f66cfc805070a15ada12a5ec14ffc7f9a110` across two `make clean && make all` cycles.
  - [x] 5.2 — `make sizes` reports **6708 B / ~81% of 8192 B / 1484 B headroom** (+129 B vs pre-3.4 6579 B; +3 B over the spec's 6705 B projection — well within budget; no NFR9 amend).
  - [x] 5.3 — Hardware UAT (AC9, 18 steps) deferred to user — script pasted inline at dev-handoff per [[feedback_uat_inline_at_dev_handoff]].
  - [x] 5.4 — Flipped `sprint-status.yaml` `3-4-visual-line-mode` `ready-for-dev` → `in-progress` → `review`; → `done` after Ant confirms hardware UAT.

## Dev Notes

### Architecture compliance

**AR boundaries — `src/visual.asm` remains a PURE READER of buffer state after Story 3.4.**
- AR13 (BIOS_CONOUT): zero call sites — visual.asm still never emits to screen. Status updates funnel through `status_set_message` (AR12 owner statusln.asm).
- AR14 (gap_start / gap_end WRITES): zero write sites. `visual_enter_line` reads cursor_offset; calls `motion_find_line_start` which reads gap-buffer state via `motion_byte_at_logical` (pure read); writes only to visual_anchor / visual_submode / mode_byte / status state. `visual_count_lines` walks via `motion_byte_at_logical` — no buffer mutation.
- AR15 (BDOS_CALL): zero call sites — visual.asm still never invokes BDOS.

**AR23 (per-module header convention)** — `visual_enter_line` and `visual_count_lines` each get a docstring with In/Out/Trashes/Calls per the Story 1.5+ pattern. `visual_compose_status` and `visual_compose_status_line` get parallel docstrings; the `_visual_compose_finish` shared-tail label gets a "private — entries fall through here; do NOT call directly" header note.

**AR25 (INCLUDE order)** — Story 3.4 adds NO new INCLUDEs. `src/visual.asm` is already in the chain (Story 3.3); `src/motions.asm` is already INCLUDEd BEFORE `src/visual.asm` (motions at line 136, visual at line 164 in `src/vibe.asm`); so `motion_find_line_start` + `motion_byte_at_logical` are backward-resolved from visual_count_lines' calls. `visual_enter_line` is forward-referenced from dispatch.asm's new `'V'` entry (resolves on sjasmplus's second pass — same shape as Story 3.3's forward-ref for `visual_enter_char`).

**MC4 register convention** — `visual_enter_line` accepts A = 'V' as the dispatched key (per MC4 contract); the value is ignored after dispatch. `visual_count_lines` reads no register state on entry (it pulls cursor_offset and visual_anchor from state.inc cells).

**SR4 mode-byte + submode invariant** — when `mode_byte == MODE_VISUAL`, `visual_submode` is one of `VIS_CHAR | VIS_LINE | VIS_BLOCK`. Story 3.3 landed the VIS_CHAR writer. Story 3.4 adds the VIS_LINE writer. Story 3.5 will add the VIS_BLOCK writer. The Esc-to-NORMAL transition does NOT clear visual_submode (per Story 3.3 dispatch.asm:19-20 — "the mode-change handler does NOT clear visual_submode; the value is meaningless in non-visual modes and the next visual entry overwrites it"). Story 3.4's AC8 reaffirms this contract — visual_submode remains VIS_LINE post-Esc until the next `v` (VIS_CHAR) or `V` (VIS_LINE) or Ctrl-V (VIS_BLOCK) overwrites it.

**SR-state ownership (state.inc):**
- `visual_anchor` (16-bit, `inc/state.inc:99`): WRITERS = `visual_enter_char` (Story 3.3, VIS_CHAR — anchor at cursor) AND `visual_enter_line` (Story 3.4, VIS_LINE — anchor at cursor's *line-start*). READERS = `visual_extend` (both arms — char and line); future `visual_enter_block` (Story 3.5; will pin anchor at cursor); future `visual_apply_operator` (Story 3.6+).
- `visual_submode` (1-byte, `inc/state.inc:52`): WRITERS = `visual_enter_char` (VIS_CHAR — Story 3.3) AND `visual_enter_line` (VIS_LINE — Story 3.4); future Story 3.5 adds VIS_BLOCK writer. READERS = `visual_extend` (the new submode-dispatch prologue per AC3); future `visual_apply_operator` (range-marshalling differs per submode).
- `status_compose_scratch` (48 B, `inc/state.inc:122`): WRITERS extend by one — `visual_compose_status_line` (Story 3.4) joins `visual_compose_status` (Story 3.3) and the fileio composers (Stories 2.2/2.3/2.4). The buffer's 48-B size has 24-B slack over the longest Story-3.4 banner ("-- visual line -- 65535\0" = 24 B); no resize needed.

### Files this story modifies (and what to preserve)

**`src/dispatch.asm`** (currently ~705 lines):
- INSERT one 3-byte entry + 2 ASSERTs at lines 542-547 area (between 'O' and 'a' in dispatch_normal) per Task 2.1.
- MODIFY the existing `ASSERT 'a' > 'O'` to `ASSERT 'a' > 'V'` per Task 2.1.
- MODIFY module-header Dependencies block — extend the existing visual.asm entry (lines 150-156) with `visual_enter_line` line per Task 2.3.
- PRESERVE: ALL of dispatch_normal's existing 27 entries (only the new 'V' entry inserts; sort order preserved by the ASSERT update); dispatch_insert, dispatch_command, dispatch_visual UNCHANGED; enter_normal_mode, enter_insert_mode, unbound_normal, unbound_visual, unbound_insert ALL UNCHANGED; the dispatch_key body UNCHANGED.

**`src/visual.asm`** (currently 221 lines):
- REPLACE comment-only placeholders block at lines 212-220 with `visual_enter_line` body per Task 3.1.
- MODIFY `visual_compose_status` (lines 188-200) — refactor to share tail with new `visual_compose_status_line` entry per Task 3.2.
- MODIFY `visual_extend` (lines 148-162) — add submode-dispatch prologue per Task 3.3; the existing CHAR body becomes the `.char_arm` fall-through.
- ADD `visual_count_lines` body (module-local) per Task 3.4.
- MODIFY module-header (lines 1-94) per Task 3.5 — Public block: flip `visual_enter_line` from PLACEHOLDER to LANDS; State-owned block: add VIS_LINE writer for visual_submode; Dependencies block: add `src/motions.asm` for the two new read-primitive call targets.
- ADD `MSG_MODE_VISUAL_LINE_PREFIX_LEN EQU 18` adjacent to `MSG_MODE_VISUAL_PREFIX_LEN EQU 13` at line 209.
- PRESERVE: `visual_enter_char` body (lines 113-122; UNCHANGED — calls visual_compose_status which is still the CHAR-prefix entry); the existing AR23 docstrings for visual_enter_char and visual_extend (extend the visual_extend one for the new submode arm).

**`src/statusln.asm`** (currently ~357 lines):
- ADD `msg_mode_visual_line_prefix: DEFB "-- visual line -- ", 0` (19 B) at line 340 (immediately after `msg_mode_visual_prefix`) per Task 1.1.
- MODIFY module-header Public block to list `msg_mode_visual_line_prefix` per Task 1.2.
- PRESERVE: `msg_mode_visual_prefix` (UNCHANGED); `status_u16_to_dec` body (UNCHANGED — both visual.asm composers call into it); all other message labels; `status_set_message` body.

**`inc/state.inc`** — NO CHANGES. `status_compose_scratch` is sized at 48 B (Story 3.3 sizing) with headroom for the new "-- visual line -- 65535" banner.

**`src/motions.asm`** — NO CHANGES. `motion_find_line_start` (line 636) and `motion_byte_at_logical` (line 557) are reused as-is; their contracts (HL-preserved-on-RET for byte_at, no register-clobbering surprises) are documented in their AR23 blocks.

**`src/edits.asm`** — NO CHANGES. `edits_compose_or_clear`'s MODE_VISUAL arm (Story 3.3, line 1357) routes to `visual_extend` which now internally dispatches on submode. The bare-motion bare-VISUAL routing is exhaustive and unchanged.

**`src/vibe.asm`** — NO CHANGES. visual.asm already INCLUDEd at line 164 by Story 3.3.

**Test files (`test/cases/*.asm`):**
- ADD 6 new test files per Task 4.
- NO bulk patch needed — the AR25 INCLUDE chain extension for visual.asm was done by Story 3.3 (208 tests already include it; verify with `grep -c "INCLUDE.*visual.asm" test/cases/*.asm | grep -c ":1"`).
- PRESERVE: All existing test bodies.

### Implementation choices and trade-offs

**Choice: `visual_anchor` snaps to line-start of cursor (not cursor itself).**
- Per Q3 Option A and epic AC narrative ("`visual_anchor = start of current line`"). The anchor lives in line-start space for line-mode; column information is meaningless and AC5's math relies on anchor being a line-start.
- Alternative considered: anchor at cursor (column-preserving); recompute line-start on every extend. Rejected — +20 B and no semantic benefit (column is unused).

**Choice: `visual_count_lines` walks LFs in `[min, max)` rather than counting line-indices from BOF.**
- Per Q6 Option A and AC5 math identity. Walking from one line-start to another line-start, the LF count in the half-open range IS the line difference. Anchor and cursor's line-start are both line-starts by construction (anchor pinned at line-start in AC2; cursor's line-start computed by motion_find_line_start in AC5). Net: O(max - min) bytes scanned per motion — bounded by the gap-buffer max (~22 KB) and sub-perceptible.
- Alternative considered: cache line numbers in state.inc (line_of_cursor + line_of_anchor); update on every motion. Rejected — speculative cache; adds 4 B state + cache invalidation logic on every edit; deferred to post-MVP per architecture SR7.

**Choice: `visual_extend` dispatches on submode internally.**
- Per Q5 Option A. The submode awareness belongs in visual.asm (the owner of visual_submode state); edits.asm should stay submode-agnostic.
- Alternative considered: edits_compose_or_clear branches on visual_submode and routes to per-submode entries (visual_extend_char / visual_extend_line / visual_extend_block). Rejected — pushes submode awareness into edits.asm; violates AR12 grain.

**Choice: shared-tail refactor of `visual_compose_status`.**
- Per Q4 Option A. Two named entries (CHAR + LINE) with a JR fall-through to a common LDIR+digits+terminate+emit block. ABI unchanged: `HL = count` on entry to either.
- Alternative considered: parametrize via IX = prefix-ptr. Rejected — ABI churn at call sites; cross-cutting register reservation.
- Alternative considered: duplicate the helper. Rejected — +22 B of code dup.

**Choice: `V` is bound ONLY in `dispatch_normal`; not in `dispatch_visual`.**
- Per Q1 Option A. Scope discipline — Story 3.4 closes the `V`-from-NORMAL entry; the v↔V↔Ctrl-V submode-toggle UX is a Story 3.5 sibling-decision (or post-MVP polish). For Story 3.4, `V` while in VISUAL falls through to `unbound_visual` with "unbound key" status; the user `Esc`s then `V`.
- Alternative considered: bind `V` in dispatch_visual to `visual_enter_line` (re-pin anchor). Rejected — vi-non-faithful (real vi preserves the active anchor's line on submode toggle, which requires a separate `visual_change_submode_line` entry adding ~30 B for a UX-only convenience).

**Choice: line count = LFs + 1 (vi-faithful).**
- Per epic AC narrative. At entry where cursor's line == anchor's line, LFs = 0, count = 1 (one line selected). Forward motion → cursor crosses N LFs → count = N + 1. Backward motion → swap → same math. Symmetric.
- Alternative considered: line count = LFs (entry shows 0). Rejected — confusing UX; the line under the cursor is always "in" the selection.

### Previous story intelligence

**From Story 3.3 (just completed, UAT confirmed):**
- `visual_compose_status` (the CHAR-prefix helper) was designed with a singleton prefix; Story 3.4's refactor extracts the common tail. Story 3.3's `MSG_MODE_VISUAL_PREFIX_LEN EQU 13` constant is paralleled by Story 3.4's `MSG_MODE_VISUAL_LINE_PREFIX_LEN EQU 18`.
- The Story 3.3 placeholders comment block at `src/visual.asm:212-220` was an explicit handoff to Story 3.4 — "Stories 3.4 / 3.5 / 3.6+ will land the bodies here as adjacent labels." Story 3.4 replaces this block with the `visual_enter_line` body.
- The Story 3.3 spec-drift caught during dev pass (`status_compose_scratch` sized at 48 B, not 32 B as the story said) — Story 3.4 inherits the 48-B sizing and verifies (24 B used by the longest VIS_LINE banner; 24 B slack). Per [[feedback_create_story_cross_check]], cross-checked the new banner length against the cell capacity before writing the story.
- The Story 3.3 sentinel-band reservation (closing note: "band 0xB5..0xBF reserved for 3.4 + 3.5") — Story 3.4 consumes 0xB5..0xB9 (5 visual tests); reserves 0xBA..0xBD for Story 3.5 V-block tests; 0xBE remains reserved by harness_fail infra. 0xEC consumed for parser_V-dispatch.
- The Story 3.3 retired-stub pattern (no analogue in 3.4 — 'V' is a NEW key with no prior stub). Story 3.4's dispatch_normal['V'] is a clean insert, not a retarget.
- The Story 3.3 Q4 status-format pin (`"-- visual -- N"`) is paralleled by Story 3.4's Q2 (`"-- visual line -- N"`) — same family, explicit unit.

**From Story 3.2 (`n` repeat search):**
- The Story 3.2 `parser_n-dispatch.asm` pattern is reused for `parser_V-dispatch.asm` (Task 4.6) — drive a key end-to-end through dispatch_key with the dispatch_normal table; verify the entry was added in the correct sorted slot.
- NFR18 byte-identical SHA discipline confirmed twice (3.2 and 3.3); Story 3.4 follows.

**From Story 3.1 (`/pattern` search):**
- The forward-reference pattern (visual_enter_line is forward-referenced from dispatch.asm to visual.asm) is the SAME shape as Story 3.1's search_begin and Story 3.3's visual_enter_char. sjasmplus's two-pass resolves cleanly.
- The bulk-INCLUDE-patch pattern from Story 3.1 (and Story 3.3) does NOT apply — visual.asm is already in the chain; Story 3.4 only ADDS new test files.

**From Story 2.13 (single-level undo `u`):**
- The dispatch_normal entry-addition pattern (one new key, one ASSERT pair update) is mirrored 1× in Story 3.4 (dispatch_normal['V']). Same shape as the Story 2.13 dispatch_normal['u'] insert.

**From Story 2.5 (basic motions):**
- AC13 contract — every NORMAL→other-mode handler tail-JPs `parser_clear`. Story 3.4's `visual_enter_line` tail-JPs parser_clear at step 7 of AC2's body.
- The motion handlers (motion_h/j/k/l + motion_w/b/G/gg + motion_dollar from Story 2.6) are mode-agnostic — they update cursor_offset from state and tail-JP edits_compose_or_clear. Story 3.3 wired the MODE_VISUAL arm at edits_compose_or_clear; Story 3.4 reuses that wiring with no change to the dispatcher.

**From Story 1.10 (parser FSM):**
- `parser_handle_digit` and `parser_handle_motion_prefix` remain mode-agnostic — used by both dispatch_normal and dispatch_visual since Story 3.3. Story 3.4 doesn't touch the parser.

### Git intelligence

**Recent commits (last 5; for context — Story 3.4 follows the same shape):**
- `a1ce47d Story 3.3: visual character mode lands; FR15/FR33 close; visual.asm module` — direct precursor; established the visual.asm module and the visual_compose_status helper that Story 3.4 refactors.
- `c0761fd Story 3.2: repeat last search n with wrap` — single-commit Epic-3 pattern; NFR18 SHA byte-identical discipline.
- `231ce3f Story 3.1: forward literal search /pattern lands; FR41 closes` — stub-retirement pattern (no analogue in 3.4 — 'V' has no prior stub).
- `c8fb896 Story 2.13: single-level undo u lands; FR45/FR46 closed; closes Epic 2` — dispatch_normal entry-addition pattern.
- `0756610 story 2.12: paste p / Np lands (KIND_CHAR + KIND_LINE; KIND_BLOCK reserved)` — KIND_BLOCK reservation pattern that aligns with Story 3.5 V-block (Story 3.4's sibling).

**Pattern:** every Epic-3 story so far has been single-commit, 5-6 new headless tests, NFR18 byte-identical rebuild required. Story 3.4 follows the same shape.

### Implementation Questions (resolve with Ant before dev starts)

See **Task 0** for the Q1-Q8 pin list. Recommended pins are all **Option A** consistent with the Story 3.3 precedent. Resolve in chat before Task 1; the pins shape AC details but the body is robust to any pin choice (LINE-mode is well-bounded vi-faithful behaviour).

### NFR9 budget arithmetic (worked example)

Pre-3.4 footprint: **6579 B / 80.3% of 8192 B / 1613 B headroom** (per Story 3.3 dev-pass actuals — 46 B under the story's projection).

Story 3.4 projected deltas (positive = grows footprint; negative = shrinks):
- `src/visual.asm` visual_enter_line body: **+28 B**
- `src/visual.asm` visual_count_lines body: **+55 B** (mid-estimate; AC5 worked example puts the body in the 50-60 B range)
- `src/visual.asm` visual_extend submode-dispatch prologue: **+11 B**
- `src/visual.asm` visual_compose_status_line entry + shared-tail refactor: **+10 B**
- `src/statusln.asm` msg_mode_visual_line_prefix (19 B incl NUL): **+19 B**
- `src/dispatch.asm` dispatch_normal['V'] entry: **+3 B** (ASSERTs are assembly-time, zero runtime)

Subtotal code growth: **+126 B**

State growth: **0 B** (no state.inc changes; status_compose_scratch already 48-B; visual_anchor + visual_submode already declared since Story 1.3).

**Projected post-3.4 footprint: 6579 + 126 = 6705 B / 81.8% of 8192 B / 1487 B headroom.**

Generous runway remaining for Stories 3.5-3.8:
- 3.5 (Ctrl-V-block): ~120-150 B (visual_enter_block + rectangle compute + Ctrl-V entry + status format with rows×cols)
- 3.6-3.8 (operators d/y/c/>/</~): ~200-300 B (visual_apply_operator + 6 per-operator bodies)
- Total Epic 3 remaining projection: ~320-450 B → post-Epic-3 ~7025-7155 B / 86-87% of 8192 B / ~1037-1167 B headroom. Within ceiling.

### Test count target

220 (post-3.3) → **226 PASS** (+6 new from Story 3.4) / 1 deliberate-fail (`harness_fail` sentinel) unchanged.

### Project Structure Notes

- `src/visual.asm` was the first new module since Story 3.1 added `src/search.asm`; Story 3.4 extends it with two more bodies (visual_enter_line public, visual_count_lines module-local).
- Sentinel band allocation (cumulative through Story 3.4):
  - 0xA0..0xAA + 0xE9 — Story 3.1 (`/pattern` search)
  - 0xAB..0xAF + 0xEA — Story 3.2 (`n` repeat)
  - 0xB0..0xB4 + 0xEB — Story 3.3 (VIS_CHAR)
  - 0xB5..0xB9 + 0xEC — Story 3.4 (VIS_LINE; THIS STORY)
  - 0xBA..0xBD reserved for Story 3.5 (Ctrl-V-block)
  - 0xBE reserved by `harness_fail` infra (the deliberate-fail sentinel — do not consume)
  - 0xBF available for future polish stories or operator coverage tests
- No project-context.md exists in planning-artifacts — Story 3.4 relies on the architecture / epics / PRD trio plus the Story 3.3 implementation artifact.
- Per [[feedback_create_story_cross_check]]: cross-checked the AC narrative against actual render/edit semantics:
  - **Cursor lands at offset 0 post-`:e`** ([[feedback_uat_trace_cursor]]) — verified in AC9 step 2 — UAT script V from offset 0 pins anchor at 0; no surprise.
  - **No `~` past-EOF marker** ([[project_no_tilde_marker]]) — no UAT step predicts a tilde. Past-EOF rows render as blank spaces (0x20).
  - **CR/CRLF and sjasmplus-hostile filenames** — not relevant to Story 3.4 (visual mode doesn't touch file I/O paths).
  - **NFR9 projection** — explicit at AC5/AC6 plus the budget arithmetic block.
  - **status_compose_scratch sizing** — verified 48-B cell (per Story 3.3 dev-pass adjustment) accommodates "-- visual line -- 65535\0" (24 B used; 24 B slack).

### References

- **Epic 3 narrative:** `_bmad-output/planning-artifacts/epics.md:1480-1484` (Epic 3 header + visual-highlighting platform-constraint note).
- **Story 3.4 epic AC source:** `_bmad-output/planning-artifacts/epics.md:1600-1627` (the original 5-AC narrative).
- **Architecture AR25 INCLUDE chain:** `_bmad-output/planning-artifacts/architecture.md:936-950` (the canonical order with visual.asm between edits and search; UNCHANGED).
- **Architecture mode-byte SR4:** `_bmad-output/planning-artifacts/architecture.md:447-451` (MODE_VISUAL implies visual_submode is VIS_CHAR/VIS_LINE/VIS_BLOCK).
- **Architecture visual.asm module purpose:** `_bmad-output/planning-artifacts/architecture.md:1304-1306` ("Visual-mode entry/exit, anchor management (SR5), block/line/char selection ops: d, y, c, >, <, ~").
- **Architecture module dependency graph:** `_bmad-output/planning-artifacts/architecture.md:1401-1432` (visual.asm sits under dispatch.asm; reads from motions.asm via the AR25 chain).
- **PRD FR34 (line selection):** `_bmad-output/planning-artifacts/prd.md:753`.
- **PRD FR15 + FR33 (already closed by 3.3):** `_bmad-output/planning-artifacts/prd.md:718, 752` (Story 3.4 builds atop both).
- **PRD NFR9 (8192 B ceiling, amended 2026-05-17):** `_bmad-output/planning-artifacts/prd.md:848`.
- **Existing visual.asm (to be extended):** `src/visual.asm:212-220` (Story 3.3's placeholder comment block — replaced by visual_enter_line body in Story 3.4).
- **Existing visual_compose_status (to be refactored):** `src/visual.asm:188-200`.
- **Existing visual_extend (to be extended with submode dispatch):** `src/visual.asm:148-162`.
- **Existing dispatch_normal table (to gain 'V' entry):** `src/dispatch.asm:489-599` (insert between 'O' at line 542 and 'a' at 545).
- **Existing motion_find_line_start (reused):** `src/motions.asm:636-647`.
- **Existing motion_byte_at_logical (reused):** `src/motions.asm:557-608` (AR23 contract documents HL preservation; visual_count_lines relies on it).
- **Existing msg_mode_visual_prefix (to be neighboured by msg_mode_visual_line_prefix):** `src/statusln.asm:339`.
- **Existing status_compose_scratch (48 B; capacity verified):** `inc/state.inc:107-123` (Story 3.3 dev-pass adjusted from 32 B to 48 B; 24 B slack for VIS_LINE's max banner).
- **state.inc visual_anchor + visual_submode declarations:** `inc/state.inc:52, 99` (UNCHANGED).
- **modes.inc MODE_VISUAL + VIS_CHAR + VIS_LINE equates:** `inc/modes.inc:26, 29, 30` (VIS_LINE = 1 — already declared since Epic-1 init).
- **Story 3.3 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-3-visual-character-mode.md` (full story file with the visual.asm module body + the placeholders-block handoff for this story).
- **Story 3.2 retrospective intelligence:** `_bmad-output/implementation-artifacts/3-2-repeat-last-search-n-with-wrap.md` (Q-pin structure precedent; tail-JP status_set_message; sentinel band allocation).
- **deferred-work.md (current backlog of polish items):** `_bmad-output/implementation-artifacts/deferred-work.md` — Story 3.4 does NOT add new entries; the v↔V submode-toggle UX (Q1 Option B) is the only candidate but is judged low-priority pending Story 3.5's Ctrl-V neighbour decision.

## Dev Agent Record

### Agent Model Used

claude-opus-4-7[1m] (Amelia / bmad-dev-story)

### Debug Log References

(no failures requiring debug-log capture; first-iteration dev pass — all 6 new tests passed on first run after the production patches)

### Completion Notes List

- All 8 Q-pins resolved Option A by Ant at dev-handoff; Story 3.3 precedent held cleanly.
- **NFR18 byte-identical SHA** `4d3d7fa654aaa6c7bafe1c3e20c8f66cfc805070a15ada12a5ec14ffc7f9a110` across two `make clean && make all` cycles.
- **Final size**: 6708 B / ~81% of 8192 B ceiling / **1484 B headroom** (+129 B vs pre-3.4 6579 B; +3 B over spec's 6705 B projection — `visual_count_lines` came in at ~63 B vs the spec's 55 B mid-estimate; the extra 8 B is the `PUSH DE / POP DE` bracketing around `motion_byte_at_logical` in the walk loop). No NFR9 amend needed.
- **Test count**: 220 → **226 PASS** (+6 new exactly per spec target) / 1 deliberate-fail (`harness_fail` sentinel) unchanged.
- **DE-trash gotcha**: `visual_count_lines`'s inner walk loop must PUSH/POP DE around `CALL motion_byte_at_logical` because the helper trashes DE per its AR23 contract. The spec body didn't explicitly call this out — same gotcha that bit Story 2.6's motion_dollar + motion_find_line_n. Caught at implementation time by re-reading the helper's contract; +2 B over the spec's body sketch.
- **Spec narrative drift caught**: AC1 + Task 2.2 said dispatch_normal grows "28 → 29". The pre-3.4 count was actually 36 (per the 'V' insert sort-slot it's now 37 = 0x25). Tests rely on `DISPATCH_NORMAL_COUNT` (auto-computed `($ - .entries) / 3`), so this was narrative-only drift — code is correct. Cross-check per [[feedback_create_story_cross_check]] caught it at dev review.
- **AR sweeps clean**: `BIOS_CONOUT|BDOS_CALL|CALL 0x0005` → zero matches in src/visual.asm; `LD (gap_(start|end)),` → zero matches. visual.asm remains a pure reader after Story 3.4.
- **AC1 / AC2 / AC3 / AC4 / AC5 / AC6 / AC7 / AC8 / AC10** all met. **AC9** (hardware UAT) deferred to Ant — script delivered inline at dev-handoff.
- **visual_enter_line placement**: chose adjacent to `visual_enter_char` (the alternate AC2-acceptable position) for code locality — both visual-entry handlers live together, easier to read.
- **visual_extend submode dispatch**: VIS_LINE submode falls through nothing; VIS_BLOCK falls through to `.char_arm` defensively (Story 3.5 will land `.block_arm` and convert the JR-Z prologue into a 3-way branch).
- **Shared-tail compose refactor**: `_visual_compose_finish` private label; entries fall through, do NOT call directly. Both `visual_compose_status` and `visual_compose_status_line` keep ABI = `HL = count` on entry (no caller-site churn).
- **No state.inc changes**. No equates.inc changes. No motions.asm changes. No edits.asm changes. No vibe.asm AR25 chain changes — visual.asm was already INCLUDEd post-3.3.

### File List

Modified:
- `src/visual.asm` — `visual_enter_line` body added (~28 B); `visual_count_lines` module-local helper added (~63 B); `visual_extend` submode-dispatch prologue added (+11 B); `visual_compose_status` refactored into shared-tail with new `visual_compose_status_line` entry (+10 B); `MSG_MODE_VISUAL_LINE_PREFIX_LEN EQU 18` added; module-header Public/State-owned/Dependencies blocks extended for Story 3.4.
- `src/statusln.asm` — `msg_mode_visual_line_prefix: DEFB "-- visual line -- ", 0` added (+19 B); module-header Public block extended.
- `src/dispatch.asm` — `dispatch_normal['V']` entry inserted between 'O' and 'a' with `ASSERT 'V' > 'O'` + `ASSERT 'a' > 'V'` (+3 B); module-header Dependencies block extended.

Added:
- `test/cases/visual_V-anchor-snaps-to-line-start.asm` (sentinel 0xB5).
- `test/cases/visual_line-forward-extends.asm` (sentinel 0xB6).
- `test/cases/visual_line-backward-extends.asm` (sentinel 0xB7).
- `test/cases/visual_line-counted-motion.asm` (sentinel 0xB8).
- `test/cases/visual_line-within-line-motion-unchanged-count.asm` (sentinel 0xB9).
- `test/cases/parser_V-dispatch.asm` (sentinel 0xEC).

Sprint tracking:
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `3-4-visual-line-mode` flipped `ready-for-dev` → `in-progress` → `review`.

### Change Log

| Date | Version | Description | Author |
|------|---------|-------------|--------|
| 2026-05-18 | 0.1.0 | Story 3.4 implementation: visual line mode `V` lands. FR34 closes. `src/visual.asm` extended with `visual_enter_line` (FR34 entry; anchor at line-start) and `visual_count_lines` (LF-walk in `[min, max)`); `visual_extend` gains submode-dispatch prologue (VIS_CHAR / VIS_LINE arms); `visual_compose_status` refactored into shared-tail with new `visual_compose_status_line`. `dispatch_normal['V']` lands between 'O' and 'a'. `msg_mode_visual_line_prefix` added to statusln. 6 new headless tests (5 visual + 1 parser-dispatch) — 226 pass / 1 deliberate-fail. NFR18 byte-identical SHA `4d3d7fa6…`. Size 6708 B / 81% of 8192 B / 1484 B headroom. | Amelia (claude-opus-4-7[1m]) |
