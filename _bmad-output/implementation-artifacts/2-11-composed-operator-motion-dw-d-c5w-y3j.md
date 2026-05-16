# Story 2.11: Composed operator+motion (dw, d$, c5w, y3j, …)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want any NORMAL-mode operator (`d`, `y`, `c`, `>`, `<`) composed with any motion (`h` / `l` / `j` / `k` / `w` / `b` / `0` / `$` / `gg` / `G`) to apply the operator over the motion's range — plus the doubled-operator line forms `>>` / `<<` — and counted variants (`2dw`, `c5w`, `y3j`, `5>>`, …),
so that FR39 + FR40 are realised end-to-end. This is the architecturally significant cross-cut of Epic 2: it wires the parser-state machine ([[story-1-10-parser]]), every motion handler ([[story-2-5-basic-motions]] + [[story-2-6-word-line-buffer-motions]] + [[story-2-7-counted-motions]]), the yank-register protocol ([[story-2-10-doubled-operator-commands-dd-yy]] — first writer of KIND_CHAR), the gap-buffer range-delete infrastructure (Story 2.10's `edits_range_delete` helper), and INSERT-mode entry (Story 2.8's `enter_insert_mode`) into a single composition layer. `cc` (change-line doubled) is OUT of MVP scope per epic spec.

## Acceptance Criteria

**AC1 — Each motion handler becomes operator-aware via a compose prologue + compose tail.**

Every NORMAL-mode motion handler in `src/motions.asm` (`motion_h`, `motion_l`, `motion_j`, `motion_k`, `motion_w`, `motion_b`, `motion_0`, `motion_dollar`, `motion_G`, `motion_gg`) is patched to be **compose-aware**:

1. **Prologue (~2 instructions, ~5 B):** at the very top, save the entry cursor into a new module-local scratch cell:
   ```
   LD   HL, (cursor_offset)
   LD   (motions_compose_entry), HL
   ```
   This is unconditional — the bare-motion path doesn't observe it, the compose path reads it.

2. **Tail (single instruction change):** replace `JP parser_clear` with `JP edits_compose_or_clear` (the new shared tail in `src/edits.asm`). For motions with multiple `JP parser_clear` exit points (e.g. `motion_j .done` AND `motion_k .done`), patch every exit.

3. **No body changes.** The motion's per-step logic, count-handling, sticky-column hoist, BH2 clamps, BC-preservation invariant — all unchanged. The motion still computes the landing offset and writes it to `cursor_offset`. The compose tail decides whether to keep that write (bare motion) or unwind + apply operator (compose).

`motions_compose_entry` is a new 2-byte module-local DEFW added alongside `motions_col` / `motions_target_start` at the bottom of `src/motions.asm`. It is written by EVERY motion handler entry and READ ONLY by `edits_compose_or_clear`. **State-discipline pin**: a "consistency cleanup" that hoisted the save into a common prelude OUTSIDE the motion handler bodies would break operators+gg/G (motion_gg / motion_G are dispatched from parser arms, not from `dispatch_normal` directly, so they don't share dispatch's prologue site). Each motion writes its own save — documented per AR23 at every handler's contract block.

**Critical state-read-before-clear discipline** (same shape as Story 2.10's op_dd / op_yy): `edits_compose_or_clear` MUST read `pending_operator` AND `count_accumulator` (the latter transitively, via the per-operator body) BEFORE any tail-JP `parser_clear`. A future cleanup that hoisted `parser_clear` into the dispatch wrapper would silently break `5dd` (Story 2.10) and `c5w` / `2dw` / `5>>` (Story 2.11). Documented at `edits_compose_or_clear`'s contract block + at each per-operator body's contract block per AR23.

**AC2 — `edits_compose_or_clear` shared tail — dispatch to per-operator body.**

New public entry in `src/edits.asm`. Reads `pending_operator`:

- `0` → JP `parser_clear` (bare motion path; existing behaviour preserved exactly).
- `'d'` → JP `op_compose_d` (delete range).
- `'y'` → JP `op_compose_y` (yank range — first writer of KIND_CHAR).
- `'c'` → JP `op_compose_c` (delete range, then enter INSERT at range_start).
- `'>'` → JP `op_compose_indent` (line-bounded indent — wraps range to line bounds).
- `'<'` → JP `op_compose_dedent` (line-bounded dedent).
- else (unrecognised; defensive — shouldn't happen, only the 5 chars above ever land in pending_operator via `parser_handle_operator`) → JP `parser_clear` (silent fall-through; no status surface).

Each per-operator body reads BOTH `cursor_offset` (= landing, written by the motion) AND `motions_compose_entry` (= range_start) to derive the (start, end) range. Range normalisation (swap if landing < entry, for backward motions like `db` / `dgg` / `dh` / `dk`) happens INSIDE the per-operator body — see AC3.

`edits_compose_or_clear`'s body shape:
```
edits_compose_or_clear:
    LD   A, (pending_operator)
    OR   A
    JP   Z, parser_clear            ; bare motion
    CP   'd'
    JP   Z, op_compose_d
    CP   'y'
    JP   Z, op_compose_y
    CP   'c'
    JP   Z, op_compose_c
    CP   '>'
    JP   Z, op_compose_indent
    CP   '<'
    JP   Z, op_compose_dedent
    JP   parser_clear               ; defensive
```

~22 B body + 1 new public symbol. AR23 contract block per [[story-1-5-status-line]] convention.

**AC3 — Range normalisation + range derivation (shared helper).**

The per-operator bodies share a range-derivation helper, `edits_compose_range`, which:

1. Reads `cursor_offset` → DE (= landing offset, written by motion).
2. Reads `motions_compose_entry` → HL (= range_start at motion entry).
3. Compares DE vs HL:
   - DE > HL (forward motion: `dw`, `dl`, `dj`, `d$`, `dG`): `range_start = HL` (entry), `range_end = DE` (landing). Range = `[HL, DE)`.
   - DE < HL (backward motion: `db`, `dh`, `dk`, `dgg`, `d0`): swap. `range_start = DE` (landing), `range_end = HL` (entry). Range = `[DE, HL)`.
   - DE == HL (no-move motion: `dl` at EOL, `dh` at BOF, `d$` on empty line, etc.): `total_bytes = 0` — caller's 0-byte guard fires.
4. Returns: HL = range_start (smaller), BC = total_bytes = |range_end - range_start|, DE = range_end (larger).

**Symmetry-with-motion landing semantics** (important — pin in test):
- `motion_l` lands cursor on the NEXT byte. `dl` deletes byte at original cursor (vi-faithful — `dl` = `x`).
- `motion_w` lands cursor on the FIRST byte of the next word. `dw` deletes `[original_cursor, next_word_start)` = the current word + trailing whitespace (vi-faithful).
- `motion_b` lands cursor on the FIRST byte of the previous word. `db` swaps and deletes `[prev_word_start, original_cursor)` = the previous word + intervening whitespace (vi-faithful).
- `motion_dollar` lands cursor on the LAST printable byte of the line. `d$` deletes `[original_cursor, last_printable)` — but vi convention is `d$` deletes through the last printable byte INCLUSIVE. **Asymmetry to resolve**: motion_dollar's landing is "last printable byte" (inclusive position); the half-open `[start, end)` range excludes it. Two options:
  - Option A: per-motion-class adjustment — for `motion_dollar` (and analogously for `motion_G` line-end-of-target-line), bump `range_end += 1` post-normalisation. Done inline in op_compose_d / op_compose_y / op_compose_c via a `pending_motion_inclusive` flag set by `motion_dollar` / `motion_G` at entry.
  - Option B: vi-faithful `d$` re-implementation — operator-aware motion_dollar produces a different landing offset when compose-bound (landing = file_length OR LF position, not last_printable).
  - **Recommendation: Option A**. ~5 B for the flag + ~5 B per per-operator body for the bump. Smallest blast radius; documented per AR23.
  - For this story, `pending_motion_inclusive` is set by `motion_dollar` only (the one motion where this matters at the byte level; `motion_G` is line-class — see AC5). Other motions leave it at 0.

`edits_compose_range` is the canonical range-resolver. AR23 contract block: `In: cursor_offset = landing, motions_compose_entry = range_start. Out: HL = range_start, BC = total_bytes, DE = range_end. Trashes: A, F. Calls: (none — pure math).`

**AC4 — `op_compose_d` (delete range; FR39 `d` + motion).**

Algorithm (mirrors op_dd's shape — Story 2.10):

1. CALL `edits_compose_range` → HL=range_start, BC=total_bytes, DE=range_end.
2. **0-byte guard**: if `BC == 0` → JP `parser_clear` (no-move motion; nothing to delete; buffer unchanged).
3. Apply `pending_motion_inclusive` (from AC3 Option A): if set, INC BC (and DE) to extend the range by 1 — vi-faithful `d$` / `dG` inclusive-landing semantic.
4. **Yank-copy attempt** via `edits_copy_to_yank(HL, BC, A=KIND_CHAR)` — note Story 2.11 PARAMETERISES `edits_copy_to_yank` to accept the kind in A (see AC7).
   - CF=0 (success): yank register now holds (KIND_CHAR, total_bytes, content).
   - CF=1 (over-capacity): surface `msg_yank_too_large`; deletion STILL proceeds (matches Story 2.10's op_dd over-capacity semantic).
5. **Range-delete** via `edits_range_delete(HL, BC)` (Story 2.10 helper — unchanged).
6. **Post-delete cursor placement**: cursor sits at `range_start` after edits_range_delete. For most motions this is correct. Edge case: if `range_start == new_file_length` AND `new_file_length > 0` (i.e., we deleted to EOF with content above), the cursor should clamp back per the [[story-2-9-single-character-delete-x]] EOF-clamp rule (AC1/AC2 in 2.9): `cursor = motion_find_line_start(cursor - 1)`. Reuse op_dd's three-way placement block (AC2 / AC3 in 2.10).
7. CALL `edits_dirty_and_redraw` (buffer_dirty := 1 + render_mark_all_dirty).
8. JP `parser_clear`.

**FR45 undo recording**: STUB for Story 2.11 (full impl in [[story-2-13-undo]]). Hook site: BEFORE the yank-copy (mirroring Story 2.10's op_dd hook). Documented in deferred-work.md.

**Trace `dw` on `"foo bar"` (7 B), cursor=0 (on 'f')**:
- motion_w from cursor=0: lands on offset 4 (= start of "bar"). `motions_compose_entry = 0`. After motion: cursor_offset = 4.
- edits_compose_or_clear: pending_operator='d' → JP op_compose_d.
- edits_compose_range: HL=0, DE=4, BC=4. (Forward motion, no swap.)
- pending_motion_inclusive = 0 (motion_w doesn't set it).
- yank-copy: KIND_CHAR, length 4, content "foo ". Within capacity.
- range-delete: bytes [0, 4) removed → buffer = "bar" (3 B). cursor = 0.
- Post-delete: cursor=0 < new_file_length=3 → case 2 (cursor unchanged). No clamp.
- buffer_dirty=1; redraw.

**Trace `d$` on `"abc def"` (7 B), cursor=2 (on 'c')**:
- motion_dollar from cursor=2: sets pending_motion_inclusive=1; lands on offset 6 (last printable, 'f'). cursor_offset = 6.
- edits_compose_range: HL=2, DE=6, BC=4.
- Inclusive bump: BC := 5, DE := 7.
- yank-copy: KIND_CHAR, length 5, content "c def".
- range-delete: bytes [2, 7) removed → buffer = "ab" (2 B). cursor = 2.
- Post-delete: cursor=2 == new_file_length=2 (deleted to EOF). new_file_length > 0 → case 3. motion_find_line_start(1) = 0. cursor = 0? No wait — vi `d$` on "abc def" cursor=2 leaves cursor on the last remaining printable byte (= 'b' at offset 1). Reuse the Story 2.9 `x` post-clamp shape (decrement onto last printable). The op_dd case-3 walks back to LINE-start (which IS 0 here, same as last-printable in a single-line buffer); for op_compose_d the right call is "decrement once to land on the last printable byte" (same as Story 2.9 `x` final-byte clamp).
- **Refinement**: op_compose_d's post-delete clamp uses the [[story-2-9-single-character-delete-x]] AC1/AC2 shape (`motion_byte_at_logical` probe at cursor; if past-EOF or on LF AND cursor > 0, DEC HL). This is DIFFERENT from op_dd's case-3 (which walks to LINE-start). The difference is intentional: op_dd's deletes operate at LINE granularity; op_compose_d's deletes are character-granularity and follow the `x` clamp shape.
- cursor=2 past EOF + > 0 → DEC → cursor=1 (on 'b'). buffer_dirty=1. Done.

**Trace `db` on `"foo bar"` (7 B), cursor=4 (on 'b' of "bar")**:
- motion_b from cursor=4: lands on offset 0 (start of "foo"). cursor_offset = 0.
- edits_compose_range: DE=0 < HL=4 → swap. range_start=0, range_end=4, BC=4.
- pending_motion_inclusive = 0.
- yank-copy: KIND_CHAR, length 4, content "foo ".
- range-delete: cursor = 0; buffer = "bar". buffer_dirty=1.

**AC5 — Line-class motions (`j` / `k` / `gg` / `G`) compose with CHAR-class yank kind per epic spec.**

Per epic AC line 1368-1370: `y3j` "the range from current cursor through the position 3 lines down (same column) is copied to yank with `yank_kind = KIND_CHAR`". This is the epic's load-bearing semantic — `y3j` and analogous `d3j` / `c2k` / `dgg` / `dG` produce **character-wise** yank, not line-wise.

(Real vi treats `y3j` as line-wise — vi's line-class motions promote the operator to line-wise. The epic spec deliberately diverges to keep the MVP composition layer simple. Document the divergence in deferred-work.md as a Story 3.x or post-MVP enhancement candidate — a per-motion `pending_motion_line_class` flag analogous to `pending_motion_inclusive` would land it later without re-architecting.)

**Trace `y3j` on `"a\nb\nc\nd\ne"` (9 B), cursor=0 (on 'a')**:
- motion_j with count=3: lands cursor on offset 6 (start of "d", same column 0). motions_compose_entry=0; cursor_offset=6.
- edits_compose_or_clear: pending_operator='y' → JP op_compose_y.
- edits_compose_range: HL=0, DE=6, BC=6.
- pending_motion_inclusive = 0.
- yank-copy: KIND_CHAR, length 6, content "a\nb\nc\n".
- No buffer mutation (yank-only).
- cursor_offset stays at 6 (motion's commit). buffer_dirty UNCHANGED.

**Edge case `d2j` on `"abc\ndef"` (7 B), cursor=1 (mid line 1)**:
- motion_j with count=2: line 2 (offset 4 + col 1 = 5) is the destination; but count=2 means "down 2 lines". 1 line down: line 2 ("def", offset 4 + col 1 = 5). 2 lines down: past EOF — motion_j .done clamp fires (the past-EOF guard at motion_j step's top), cursor stays at 5 (= 1 line down's commit). motions_compose_entry=1; cursor_offset=5.
- edits_compose_range: HL=1, DE=5, BC=4.
- yank-copy: KIND_CHAR, length 4, content "bc\nd".
- range-delete: cursor=1; buffer = "aef" (3 B). buffer_dirty=1.
- Post-delete clamp: cursor=1 < new_file_length=3 → case 2 (unchanged).

**AC6 — `op_compose_y` (yank range; FR39 `y` + motion).**

Algorithm:

1. CALL `edits_compose_range`.
2. 0-byte guard: if BC == 0 → JP parser_clear (silent — yank is read-only).
3. Apply `pending_motion_inclusive`: same as op_compose_d.
4. CALL `edits_copy_to_yank(HL, BC, A=KIND_CHAR)`.
   - CF=0: silent success.
   - CF=1: surface `msg_yank_too_large` (yank register preserved); no buffer mutation; cursor reverts to `motions_compose_entry` (yank should NOT advance the cursor — vi convention).

**Cursor handling for yank** (subtle — pin in test): vi's `yw` leaves cursor at original position (the motion's landing is consumed by yank; cursor doesn't move). Implementation: at the very top of op_compose_y, RESTORE cursor_offset := motions_compose_entry. Cost: ~6 B.

For yy/dd's line-class compose path, the same rule holds: `y3j` leaves cursor at entry position. The yank captures bytes from [entry, landing); cursor returns to entry.

5. JP parser_clear.

**Trace `y3j` continuing**: cursor_offset is restored to 0 at op_compose_y's top, even though motion_j moved it to 6. Final cursor=0.

**AC7 — `edits_copy_to_yank` parameterised on kind (A=kind at entry).**

Story 2.10's `edits_copy_to_yank` hardcodes `LD A, KIND_LINE`. Story 2.11 PATCHES the helper to read the kind from register A at entry:

```
;; New contract:
;; In:  HL = delete_start, BC = total_bytes, A = kind (KIND_CHAR | KIND_LINE)
;; Out: CF=0 on success — yank_kind := A; yank_length := BC; bytes copied.
;;      CF=1 on over-capacity — yank register UNCHANGED.
```

**Patch shape**:
- Body: replace `LD A, KIND_LINE` (single hardcoded line near the end of the success path) with NOTHING — A holds the caller-supplied kind on the success path. But A is trashed by the capacity-check + copy loop's `LD A, B / OR C` and `LD A, (motion_byte_at_logical)` returns. So save the kind across the body: at entry, PUSH AF (or stash to a single-byte module-local cell). At the success tail, restore + `LD (yank_kind), A`. Net cost: ~5 B (PUSH AF / POP AF bracketing the body, plus a 1-instruction rearrangement at the tail).
- Existing callers (op_dd / op_yy) patched to set A = KIND_LINE before the call:
  ```
  ;; In op_dd before CALL edits_copy_to_yank:
  LD   A, KIND_LINE
  CALL edits_copy_to_yank
  ```
  Net cost: +2 B per caller × 2 callers = +4 B.
- New callers (op_compose_d / op_compose_y / op_compose_c) set A = KIND_CHAR.

**AR23**: update edits_copy_to_yank's contract block to document the new In parameter; document the kind expectations (only KIND_CHAR and KIND_LINE supported in Story 2.11; KIND_BLOCK reserved for Epic 3 visual-block).

**Backward compatibility**: Story 2.10's tests for op_dd / op_yy already assert `yank_kind == KIND_LINE` post-call — those continue to pass because op_dd / op_yy now explicitly load KIND_LINE into A. The patch is invariant-preserving from the test's perspective.

**AC8 — `op_compose_c` (change range; FR39 `c` + motion).**

Algorithm:

1. CALL `edits_compose_range`.
2. 0-byte guard: BC == 0 → JP parser_clear (no-move motion → no change).
3. Apply `pending_motion_inclusive`.
4. yank-copy via `edits_copy_to_yank(HL, BC, A=KIND_CHAR)` (CF=1 → surface msg_yank_too_large; deletion still proceeds — same shape as op_compose_d).
5. range-delete via `edits_range_delete(HL, BC)`. cursor sits at range_start.
6. Post-delete cursor placement: SKIP the x-style EOF-clamp. The cursor MUST stay at `range_start` so INSERT mode opens at the right position.
7. CALL `edits_dirty_and_redraw`.
8. JP `enter_insert_mode` (tail-JP). `enter_insert_mode` flips mode_byte := MODE_INSERT, surfaces "-- insert --", and tail-JPs parser_clear itself (per Story 2.8 AC1). Parser state zeroes via `enter_insert_mode`'s own tail.

**FR45 undo recording**: STUB (same as op_compose_d). Hook site: same — BEFORE yank-copy. Story 2.13 will record the inverse-op as "delete the inserted text + re-insert the deleted text".

**Trace `cw` on `"foo bar"` (7 B), cursor=0**:
- motion_w lands on offset 4. motions_compose_entry=0. cursor_offset=4.
- op_compose_c: BC=4, no inclusive bump, yank "foo " (KIND_CHAR), delete [0,4), cursor=0, mode := MODE_INSERT.
- Buffer = "bar". Cursor at 0. User types replacement; Esc; vi-faithful change-word.

**AC9 — `op_compose_indent` / `op_compose_dedent` (`>` and `<` with motion; line-bounded).**

`>` and `<` are LINE-CLASS operators in vi regardless of the motion's char/line classification. The motion's range is **promoted to line bounds**: the operator acts on every line that the range overlaps.

Algorithm for `op_compose_indent`:

1. CALL `edits_compose_range` → HL=range_start, BC=total_bytes, DE=range_end.
2. **Line-promote**: walk from range_start backward to its line-start (via `motion_find_line_start(HL)`) and from range_end forward to ITS line-end (via `motion_find_line_end(DE - 1)` — `DE - 1` because the range is half-open and we want the line containing the last affected byte). Special case: if BC == 0 (no-move motion), promote both bounds to the CURRENT line: `range_start = motion_find_line_start(motions_compose_entry)`, `range_end = motion_find_line_end(motions_compose_entry) + 1` (include the trailing LF if present).
3. For each line in the promoted range, AT line-start, insert `INDENT_BYTE` (= 0x20 = space, per `inc/equates.inc:68`) via `gapbuf_insert`. The cursor pre-stages to each line-start before the insert; gapbuf_insert advances cursor by 1, so the next line-start (which has shifted +1) is reachable by walking forward to the NEXT LF + 1.
4. After all inserts, RESTORE cursor to `motions_compose_entry` adjusted for inserted bytes on/before its line (vi convention: `>>` leaves cursor on the first non-whitespace of the line — but for MVP, the simpler "restore to original cursor + 1 if cursor was on or after its own line-start's insert" is acceptable. **Implementation choice**: restore to original `motions_compose_entry`. If the cursor was on a line whose start got an inserted space, the cursor moves logically by +1 (the insert shifted it). Document this as "indent's post-cursor is the entry cursor, which has logically advanced by 1 if its line was indented". Vi's behaviour of "cursor on first non-whitespace" can land in a future polish story.
5. `buffer_dirty := 1`; render_mark_all_dirty.
6. JP parser_clear.

`op_compose_dedent` algorithm is symmetric:
1-2. Same range computation + line-promote.
3. For each line in the promoted range, AT line-start, examine the byte: if it's `INDENT_BYTE` (0x20), CALL `gapbuf_delete` (or the cursor-bounce shape from edits_range_delete with `total_bytes = 1`). If it's NOT 0x20, NO-OP for that line (vi convention: `<<` on a line with no leading whitespace is a silent no-op for that line).
4-6. Same post-tail.

**For-each-line walk implementation sketch** (~30 B body — chooses to inline rather than factor a new `edits_for_each_line_in_range` helper; the helper is a Story 2.12 paste candidate or post-MVP polish):

```
;; In:  HL = promoted_start, DE = promoted_end (after line-promote).
;;      cursor_offset is unspecified here (caller saves/restores).
;; Operation: at each line-start in [HL, DE), apply per_line_op (insert or delete).
;; Tracks the cumulative byte shift to keep DE correct as inserts/deletes happen.

.line_walk:
    PUSH DE                          ; [end]
    LD   (cursor_offset), HL         ; pre-stage cursor at line_start
    ;; per_line_op (inline — insert/delete 1 byte)
    LD   A, INDENT_BYTE
    CALL gapbuf_insert               ; or check + gapbuf_delete for dedent
    ;; gapbuf_insert advanced cursor by 1; we just shifted end by 1 too
    POP  DE
    INC  DE                          ; end += 1 (or DEC for dedent miss/hit accounting)
    ;; Advance to next line: HL := motion_find_line_end(cursor) + 1
    LD   HL, (cursor_offset)
    CALL motion_find_line_end
    ;; Past-EOF check + range exhaustion check
    ...
    INC  HL                          ; HL = next line-start
    ;; Loop if HL < DE
    ...
```

The exact code is implementation choice; the above is a sketch. The dev pass MAY factor a helper if the body grows past ~50 B.

**`>>` and `<<` (doubled-operator line forms — per epic AC line 1372-1374):**

Per epic spec, `>>` and `<<` are LINE-BOUNDED single-line indent/dedent — same as `op_compose_indent` / `op_compose_dedent` applied to the CURRENT line only. Counted forms `5>>` / `5<<` apply to N consecutive lines starting at the cursor's line.

Wire into `parser_doubled_operator_stub` (Story 2.10 — `src/parser.asm:502-514`):

- Replace the `c / > / <` catch-all msg_not_implemented arm with:
  - `'c'` → JP msg_not_implemented surface (preserve existing — cc out of MVP).
  - `'>'` → JP `op_indent_line` (new entry; thin wrapper that builds a line-class range using `edits_line_range_for_count` from Story 2.10 then JPs into the line-walk shared with `op_compose_indent`).
  - `'<'` → JP `op_dedent_line` (symmetric).

`op_indent_line` algorithm:
1. CALL `edits_line_range_for_count` (Story 2.10 helper — already exists; returns HL=line_range_start, BC=total_bytes, DE=trashed).
2. Compute promoted_end = HL + BC.
3. JP into the indent line-walk (shared with op_compose_indent — factor as `edits_indent_walk(HL, DE)` if size permits, else inline).
4. Tail: JP parser_clear (op_indent_line doesn't tail-JP enter_insert_mode — `>>` doesn't enter INSERT).

`op_dedent_line` symmetric.

**AC10 — `parser_doubled_operator_stub` extended for `>>` / `<<` (parser.asm patch).**

Current body (src/parser.asm:502-514):
```
parser_doubled_operator_stub:
    LD   A, (pending_operator)
    CP   'd'
    JP   Z, op_dd
    CP   'y'
    JP   Z, op_yy
    ;; c / > / < fall-through arm — preserved Epic-1 "not yet implemented" surface.
    LD   HL, msg_not_implemented
    XOR  A
    CALL status_set_message
    JP   parser_clear
```

New body:
```
parser_doubled_operator_stub:
    LD   A, (pending_operator)
    CP   'd'
    JP   Z, op_dd
    CP   'y'
    JP   Z, op_yy
    CP   '>'
    JP   Z, op_indent_line
    CP   '<'
    JP   Z, op_dedent_line
    ;; 'c' (cc — out of MVP scope) fall-through arm.
    LD   HL, msg_not_implemented
    XOR  A
    CALL status_set_message
    JP   parser_clear
```

Cost: +8 B (two new 4-B `CP+JP Z` arms).

Update parser.asm module-header docstring per AR23 to note the new arms.

**AC11 — Hardware UAT on real MicroBeast (deferred to Ant — same pattern as Stories 2.1-2.10).**

The dev MUST NOT mark this story `done` without confirmed hardware UAT by Ant. Hardware UAT script (12 steps; covers the load-bearing user journeys for FR39 / FR40):

1. **Pre-state:** boot fresh, no prior `vibe` invocation.
2. **`vibe newgame.fs`** (or any pre-existing multi-line file). Status confirms `loaded` count + mode `-- normal --` + cursor at offset 0.
3. **Navigate to a line with a word boundary** (anywhere `j j j w` puts cursor mid-word). Press `dw` — the word + trailing whitespace vanishes; cursor lands on the start of the next word. Status confirms no error.
4. **Press `d$`** — from current cursor to end of line vanishes; cursor lands on the new last printable byte of the line.
5. **Press `d3j`** — three lines' worth of bytes (current column down 3 lines + same column) deleted as a character-wise range. Confirm cursor lands at deletion start; visible content shifted.
6. **Press `c5w`** — change next 5 words: 5 words + trailing whitespace deleted; mode flips to INSERT; status shows `-- insert --`. Type a replacement; Esc; confirm mode back to NORMAL + buffer reflects the typed text.
7. **Press `yy`** (Story 2.10), then `j`, then `y3w` — first a line yank, then a 3-word character-wise yank overwrites the yank register. (Paste verification deferred to Story 2.12 — for 2.11 just confirm no crash + cursor stays at original position post-y3w per AC6.)
8. **Press `>>`** — current line gets a leading space inserted. Confirm visual indent of one column.
9. **Press `<<`** — current line's leading space is removed (or no-op if there was none). Confirm dedent or unchanged-content silent.
10. **Press `3>>`** — three consecutive lines get a leading space. Confirm three lines indented by one column.
11. **Press `:w`** — file saves; status confirms bytes written + `buffer_dirty := 0`.
12. **Press `:q`** — clean quit. **`vibe newgame.fs`** to re-launch; confirm the edits persisted to disk.

Hardware UAT also looks for regressions: motion in NORMAL (Stories 2.5-2.7) still works without operators; ex-line `:w` / `:q` / `:e` still work (2.1-2.4); INSERT mode (2.8) + `x` (2.9) + `dd` / `yy` (2.10) all still work.

**Boundary cases worth Ant's verification on hardware** (consolidated from the headless tests — Ant may compress to the time available):
- `dw` at end of file (motion_w EOF-clamp + 0-byte guard).
- `d$` on an empty line (motion_dollar no-move clamp + 0-byte guard).
- `db` from BOF (motion_b BOF-clamp + 0-byte guard).
- `>>` on the last-line-no-LF case.
- `5dw` clamping at EOF mid-walk.

**AC12 — Headless tests (all under `test/cases/edits_*.asm` + `test/cases/parser_*.asm`).**

**Canonical (epic spec line 1386):**

- `edits_dw-deletes-word.asm` — pre-load `"foo bar"` (7 B), cursor=0, pending_operator='d', count_accumulator=0; pre-seed motions_compose_entry=0xFFFF (sentinel — verify motion_w writes it). CALL motion_w directly. Assert: buffer = "bar" (3 B); cursor=0; yank_kind=KIND_CHAR; yank_length=4 ("foo "); yank_buffer[0..3] = "foo "; buffer_dirty=1; parser_clear ran (pending_operator=0, count=0).

- `edits_d$-to-end-of-line.asm` — pre-load `"abc def\nghi"` (11 B), cursor=2 (on 'c'), pending_operator='d'. CALL motion_dollar. Assert: buffer = "ab\nghi" (6 B); cursor=1 (clamped onto 'b' — last printable byte of the new line 1); yank_kind=KIND_CHAR; yank_length=5 ("c def"); buffer_dirty=1; pending_motion_inclusive=0 post-call (cleared as part of parser_clear OR explicit reset — implementation choice; both work).

- `edits_c-enters-insert.asm` — pre-load `"foo bar"`, cursor=0, pending_operator='c'. CALL motion_w. Assert: buffer = "bar"; cursor=0; mode_byte=MODE_INSERT; status_buffer contains "-- insert --"; yank_kind=KIND_CHAR; yank_length=4; buffer_dirty=1.

- `edits_y3w-yanks-without-modifying.asm` — pre-load `"a b c d e f"` (11 B), cursor=0, pending_operator='y', count_accumulator=3. CALL motion_w. Assert: buffer UNCHANGED (= "a b c d e f", 11 B); cursor=0 (RESTORED by op_compose_y's top, even though motion_w moved it to 6 = start of 'd'); yank_kind=KIND_CHAR; yank_length=6 ("a b c "); buffer_dirty UNCHANGED.

- `edits_indent-shift.asm` — pre-load `"abc\ndef\nghi"` (11 B), cursor=0, pending_operator='>' (doubled-form `>>` test). CALL parser_doubled_operator_stub (which JPs to op_indent_line). Assert: buffer = " abc\ndef\nghi" (12 B); buffer_dirty=1; cursor logically at the same offset (=0) — the leading space shifted offsets. (No yank register write — indent doesn't touch yank.)

- `parser_compose-count-op-motion-end-to-end.asm` — drive the full chain: pre-load `"foo bar baz"` (11 B), cursor=0, mode=MODE_NORMAL. CALL parser_handle_digit with A='2' (count=2); CALL parser_handle_operator with A='d' (pending_operator='d'); CALL motion_w (via dispatch_normal or direct CALL — dispatch_normal preferred). Assert: buffer = "baz" (3 B — "foo " + "bar " = 8 B deleted); yank_length=8; yank_kind=KIND_CHAR; cursor=0; pending_operator=0; count_accumulator=0; buffer_dirty=1.

**Additional (full AC + edge coverage):**

- `edits_dl-equals-x.asm` — pre-load `"abc"`, cursor=1 (on 'b'), pending_operator='d'. CALL motion_l. Assert: buffer = "ac" (2 B); cursor=1 (on 'c' — same shape as `x`); yank_kind=KIND_CHAR; yank_length=1 ("b"); buffer_dirty=1. (Pins `dl == x` vi convention.)

- `edits_dh-from-mid-line.asm` — pre-load `"abc"`, cursor=2 (on 'c'), pending_operator='d'. CALL motion_h. Assert: buffer = "ac" (2 B); cursor=1 (on 'c' — motion_h landed cursor at 1, swap → range [1, 2), deletes 'b'); yank_length=1 ("b").

- `edits_db-from-mid-buf.asm` — pre-load `"foo bar"`, cursor=4 (on 'b' of "bar"), pending_operator='d'. CALL motion_b. Assert: buffer = "bar" (3 B); cursor=0; yank_kind=KIND_CHAR; yank_length=4 ("foo "); buffer_dirty=1.

- `edits_dgg-from-line-3.asm` — pre-load `"a\nb\nc"` (5 B), cursor=4 (on 'c', line 3), pending_operator='d', count_accumulator=0 (no count → gg goes to line 1). CALL motion_gg. Assert: buffer = "c" (1 B); cursor=0; yank_kind=KIND_CHAR; yank_length=4 ("a\nb\n"); buffer_dirty=1. (Pins: motion_gg writes motions_compose_entry; backward motion triggers swap.)

- `edits_dG-from-line-1.asm` — pre-load `"a\nb\nc"` (5 B), cursor=0, pending_operator='d'. CALL motion_G (no count → last line). Assert: buffer = empty OR "c" (depending on motion_G's "land on START of last line" semantic — should leave "c" since the range is [0, 4) = "a\nb\n"). cursor=0; yank_length=4 ("a\nb\n").

- `edits_d2j-clamps-at-eof.asm` — pre-load `"abc\ndef"` (7 B), cursor=1, pending_operator='d', count_accumulator=2. CALL motion_j. Assert: buffer = "aef" (3 B — motion_j .done clamp fires on iter 2 past-EOF; cursor lands at offset 5 = 1 line down + col 1; range = [1, 5), 4 bytes "bc\nd"); yank_length=4; cursor=1; buffer_dirty=1.

- `edits_dw-no-op-at-eof.asm` — pre-load `"abc"`, cursor=3 (past EOF), pending_operator='d'. CALL motion_w. Assert: buffer UNCHANGED; cursor=3 (unchanged); yank_kind UNCHANGED from pre-seed (0xEE); buffer_dirty UNCHANGED from pre-seed (0); parser cleared. (Pins 0-byte guard.)

- `edits_dw-yank-too-large.asm` — pre-load a buffer with a word > 1024 B (e.g. 1025 'X' bytes), cursor=0, pending_operator='d'. CALL motion_w. Assert: buffer SHRUNK by the deleted word; yank_kind / yank_length UNCHANGED from pre-seed (0xEE / 0xCAFE); status_buffer contains "yank too large" prefix; status_dirty=1; buffer_dirty=1. (Mirrors Story 2.10's edits_dd-yank-too-large pattern.)

- `edits_yw-cursor-unchanged.asm` — pre-load `"foo bar"`, cursor=2 (on 'o'), pending_operator='y'. CALL motion_w. Assert: buffer UNCHANGED; cursor=2 (RESTORED — even though motion_w moved it to 4); yank_kind=KIND_CHAR; yank_length=2 ("o " — bytes [2,4)); buffer_dirty UNCHANGED.

- `edits_cw-then-insert.asm` — pre-load `"old new"`, cursor=0, pending_operator='c'. CALL motion_w. Assert: buffer = "new" (3 B); cursor=0; mode_byte=MODE_INSERT; yank_kind=KIND_CHAR; yank_length=4 ("old "); buffer_dirty=1; pending_operator=0 post-call (cleared by enter_insert_mode's tail-JP parser_clear).

- `edits_indent-counted-3lines.asm` — pre-load `"a\nb\nc\nd"` (7 B), cursor=0, pending_operator='>' (doubled), count_accumulator=3. CALL parser_doubled_operator_stub. Assert: buffer = " a\n b\n c\nd" (10 B — first 3 lines indented; last line "d" UNCHANGED); buffer_dirty=1; yank UNCHANGED (indent doesn't touch yank).

- `edits_dedent-no-op-no-leading-space.asm` — pre-load `"abc"` (3 B), cursor=0, pending_operator='<' (doubled). CALL parser_doubled_operator_stub. Assert: buffer UNCHANGED; buffer_dirty UNCHANGED (no-op since the line has no leading INDENT_BYTE).

- `edits_dedent-removes-leading-space.asm` — pre-load `" abc"` (4 B; leading space), cursor=1 (on 'a'), pending_operator='<' (doubled). CALL parser_doubled_operator_stub. Assert: buffer = "abc" (3 B); buffer_dirty=1; cursor adjustment per AC9 (entry cursor was 1; deletion of leading byte shifts everything; cursor logically still at "the byte that was at offset 1" = 'b' = offset 0 post-delete OR stays at 1 = on 'b' depending on the implementation's restore semantic — pin whichever the dev pass chooses, document in test header).

- `parser_doubled-operator-routes-to-indent.asm` — drive full parser chain: pre-load `"abc"`, mode=MODE_NORMAL, cursor=0; CALL parser_handle_operator with A='>' (first '>' — stores pending_operator); CALL parser_handle_operator again with A='>' (second '>' — doubled; routes to op_indent_line). Assert: buffer = " abc"; parser cleared.

- `parser_doubled-operator-routes-to-dedent.asm` — symmetric for '<' '<'.

- `parser_doubled-operator-routes-to-cc.asm` — pre-load buffer; CALL parser_handle_operator twice with 'c'. Assert: status_buffer contains "not yet implemented"; buffer UNCHANGED; parser cleared. (Pins the `cc` out-of-MVP-scope arm.)

- `edits_compose-clears-pending-motion-inclusive.asm` — pre-load `"abc def"`, cursor=2, pending_operator='d'. CALL motion_dollar (sets pending_motion_inclusive=1). Run through op_compose_d. After, pre-set pending_operator='d' AGAIN, cursor=0; CALL motion_w. Assert: the second compose does NOT apply an inclusive bump (motion_w doesn't set the flag, and the previous op_compose_d cleared it). Pin: yank_length=4 ("abc " — without an erroneous +1 from a leaked inclusive flag). Cleanup of pending_motion_inclusive at every op_compose_* tail (or at parser_clear — implementation choice; document).

- `motions_compose-entry-saved-by-h.asm` — pre-seed motions_compose_entry=0xFFFF (sentinel); pre-load `"abc"`, cursor=2, pending_operator=0 (bare motion). CALL motion_h. Assert: motions_compose_entry = 2 (motion_h wrote it at entry, even though no compose followed); cursor=1. (Pins: AC1 prologue unconditional.)

Test count target: 6 canonical + ~16 additional = ~22 new tests. Sentinel allocation 0x80..0x87 per test (Story 2.5-2.10 convention).

**AC13 — Build invariants (NFR9, NFR18, AR sweeps).**

- `make all` followed by `make clean && make all` produces a byte-identical `vibe.com` (NFR18).
- `make test` from a fresh `make clean && make test` is green (post-2.10 baseline 134 pass / 1 fail; post-2.11 ~156 pass / 1 fail; ~22 new tests).
- AR13 / AR14 / AR15 grep sweeps against `src/edits.asm`, `src/parser.asm`, `src/motions.asm` all clean. **New sweep:** `grep -n 'motions_compose_entry' src/motions.asm` shows 10+ code refs (one per motion prologue + doc-comment refs). `grep -n 'pending_motion_inclusive' src/{motions,edits}.asm` shows code refs at motion_dollar (writer) + op_compose_d/y/c (reader + cleanup).
- AR25 INCLUDE chain in `src/vibe.asm` is unchanged (`statusln → gapbuf → render → dispatch → parser → motions → edits → exline → fileio`). `edits_compose_or_clear` is forward-referenced from motions.asm; resolved by sjasmplus's two-pass model (motions.asm INCLUDEs before edits.asm).
- `dispatch_normal` count UNCHANGED at 33 entries (Story 2.11 does NOT add new dispatch_normal bindings — the operator+motion compose is wired entirely through pending_operator + motion handler co-operation; `>` and `<` are already bound to parser_handle_operator since Story 1.10).
- `dispatch_insert` / `dispatch_command` / `dispatch_visual` unchanged.

- **NFR9 projection:** post-2.10 footprint = 4793 B (~93.6% of 5120 B / 327 B headroom). Story 2.11 adds:
  - **motion compose prologues** (~5 B × 10 motions = ~50 B). Some motions have multiple `JP parser_clear` exit points; each `JP parser_clear → JP edits_compose_or_clear` is +0 B (both 3-byte JPs).
  - **`motions_compose_entry` DEFW** (+2 B in module-local scratch — counted in NFR9 since the static block bumps).
  - **`pending_motion_inclusive` flag**: choice point — either a new 1-byte state.inc cell (+1 B static; +2 B per writer; +2 B per reader) OR a module-local 1-byte cell in edits.asm OR motions.asm (same accounting). Place in `inc/state.inc` adjacent to `pending_motion_prefix` for grep-ability. ~6 B amortised.
  - **`edits_compose_or_clear`** (~22 B).
  - **`edits_compose_range`** helper (~25-35 B).
  - **`op_compose_d`** body (~60-80 B — yank-copy + range-delete + EOF-clamp).
  - **`op_compose_y`** body (~35-50 B — cursor-restore + yank-copy + capacity-refusal arm).
  - **`op_compose_c`** body (~50-70 B — yank-copy + range-delete + enter_insert_mode tail-JP).
  - **`op_compose_indent`** body + line-walk (~50-80 B).
  - **`op_compose_dedent`** body + line-walk (~50-80 B; partial sharing with indent if factored).
  - **`op_indent_line`** + **`op_dedent_line`** (~20-40 B; thin wrappers around the line-walk shared with op_compose_indent / op_compose_dedent).
  - **`parser_doubled_operator_stub` patch** for `>>` / `<<` (+8 B).
  - **`edits_copy_to_yank` parameterisation patch** (+5 B for PUSH/POP AF + tail rearrangement, NOT counted as new code since it's a body edit; +4 B for op_dd / op_yy callers' `LD A, KIND_LINE`).
  - **Net delta projection: ~400-550 B.** Post-2.11 footprint: 5193-5343 B = **OVER the 5120 B ceiling** by ~73-223 B.
  - **NFR9 amend status**: post-Story-2.4 baseline notes flagged the original 3072 B ceiling as too tight; deferred-work.md line 122 documents the proposed 4096 B amended ceiling, which was already implicitly relaxed to 5120 B in Story 2.10's spec. **Story 2.11 is the squeeze story** — the projection likely BREAKS the 5120 B ceiling unless factoring is aggressive. Recommended mitigations (any combination):
    - **Factor indent/dedent line-walk into a shared helper** parameterised on a "per-line op" callback (~20 B saved). The callback shape is awkward in Z80 (need a function pointer table or a CALL into a held register), so an inline-with-flag shape (a single flag byte selecting insert-vs-delete in the line-walk body) may be cleaner.
    - **Share the yank-too-large surface** between op_compose_d / op_compose_y / op_compose_c — a single `op_compose_yank_refused` label they all JR/JP to (~10 B saved).
    - **Drop or defer `c` change-operator until Story 2.12** (paste pass) — vi muscle memory ranks `dw` / `dd` / `yy` highest; `cw` is convenience. But the epic AC line 1364-1366 (c5w trace) is load-bearing.
    - **Drop or defer indent/dedent operator (`>` / `<` with motion AND `>>` / `<<` doubled) to a later story** (e.g. Story 3.7 — visual shift). This removes ~100-160 B from the projection. But the epic AC line 1352-1354 + 1372-1374 are load-bearing for FR39 + FR40 closure. **Decision: ASK ANT** before deferring — see Implementation Questions below.
    - **Accept the NFR9 amend formally**. Bump the ceiling explicitly (e.g. to 5632 B) and document in deferred-work.md. The TPA fit (NFR10) holds — static_end + GAP_BUFFER_MAX + YANK_BUFFER_SIZE is well under 0xD800.

- **`buffer_dirty` write count:** Story 2.11 adds 3 success-path writers (op_compose_d's tail; op_compose_c's tail; op_compose_indent's tail; op_compose_dedent's tail) — all via the SAME `edits_dirty_and_redraw` helper (no inlining; the helper is the single funnel).

- **Yank register write count:** Story 2.11 adds 3 success-path writers (op_compose_d's yank-copy; op_compose_y's yank-copy; op_compose_c's yank-copy) — all via the patched `edits_copy_to_yank` with KIND_CHAR. op_indent_line / op_dedent_line / op_compose_indent / op_compose_dedent NEVER touch yank.

## Tasks / Subtasks

- [x] **Task 1: Add `motions_compose_entry` scratch cell + `pending_motion_inclusive` flag** (AC1, AC3).
  - [x] Sub 1.1: In `src/motions.asm`, add `motions_compose_entry DEFW 0` at the bottom alongside `motions_col` / `motions_target_start`. Update module-header State owned (read/write) block per AR23 — note: "written by every motion handler's entry prologue; read only by `edits_compose_or_clear`".
  - [x] Sub 1.2: In `inc/state.inc`, add `pending_motion_inclusive EQU static_data_base + static_off ; static_off = static_off + 1` adjacent to `pending_motion_prefix`. Update state.inc module-header Public list. Document in the section comment: "1-byte flag; set by motion handlers whose landing offset is INCLUSIVE (e.g. `motion_dollar` lands on last printable byte). Read + cleared by `op_compose_d` / `op_compose_y` / `op_compose_c` to extend the range by 1 byte (vi-faithful `d$` / `c$` semantic)." Also note: cleared in `parser_clear` (or at op_compose_* tails — implementation choice with rationale).
  - [x] Sub 1.3: Verify NFR18 byte-identical rebuild after Sub 1.1 + 1.2 (+3 B static + +2 B per-byte DEFW count; trivial delta).

- [x] **Task 2: Patch every NORMAL-mode motion handler with the compose prologue + compose tail** (AC1).
  - [x] Sub 2.1: At the top of `motion_h` / `motion_l` / `motion_j` / `motion_k` / `motion_w` / `motion_b` / `motion_0` / `motion_dollar` / `motion_G` / `motion_gg`, insert the prologue: `LD HL, (cursor_offset) ; LD (motions_compose_entry), HL`. Per AR23 contract block update: note the compose prologue at every handler. Mention that bare-motion behaviour is observably unchanged (the prologue is a write to a scratch cell only).
  - [x] Sub 2.2: At every `JP parser_clear` exit point in those handlers (count varies — motion_h has 1, motion_j has 2 via `.done`, motion_w has 1 via `.done`, etc. — grep `grep -n 'JP.*parser_clear' src/motions.asm` enumerates), patch to `JP edits_compose_or_clear`. The forward reference is resolved by sjasmplus's two-pass model (edits.asm INCLUDEs after motions.asm).
  - [x] Sub 2.3: In `motion_dollar`, add `LD A, 1 ; LD (pending_motion_inclusive), A` at the top (after the compose prologue). This is the only motion that sets the flag. Document in motion_dollar's contract block.
  - [x] Sub 2.4: AR23 sweeps after the patch — `grep -nE 'JP\s+parser_clear|JP\s+edits_compose_or_clear' src/motions.asm` should show ALL motion-handler exits route through `edits_compose_or_clear` (and `parser_clear` only inside `parser.asm` plus the bare-motion-path tail INSIDE edits_compose_or_clear).

- [x] **Task 3: Implement `edits_compose_or_clear` shared tail** (AC2).
  - [x] Sub 3.1: New public entry in `src/edits.asm`. Body per AC2 shape (~22 B). AR23 contract block per AR23 (In: pending_operator + cursor_offset + motions_compose_entry. Out: control transferred to per-operator body OR JP parser_clear for bare motion. Trashes: A, F. Calls: per-operator body OR parser_clear (tail-JP)).
  - [x] Sub 3.2: Update edits.asm module-header — add `edits_compose_or_clear` to the Public list; document its role as the compose-or-clear dispatcher.

- [x] **Task 4: Implement `edits_compose_range` shared helper** (AC3).
  - [x] Sub 4.1: New (public or internal — choose per AR23 contract; public preferred since op_compose_d / op_compose_y / op_compose_c all call it). Body: load cursor_offset → DE; load motions_compose_entry → HL; compare; swap if DE < HL; compute BC = |DE - HL|; return HL=start, DE=end, BC=length.
  - [x] Sub 4.2: AR23 contract block (~5 lines). Document the half-open [start, end) semantic + the swap-for-backward-motion behaviour.

- [x] **Task 5: Parameterise `edits_copy_to_yank` on the yank kind** (AC7).
  - [x] Sub 5.1: Patch `edits_copy_to_yank` body in `src/edits.asm`: PUSH AF at entry (save the caller-supplied kind); at the success tail, replace `LD A, KIND_LINE` with `POP AF ; LD (yank_kind), A`. The over-capacity / refusal path must POP AF too before RET'ing (or convert to JR over the POP). Net cost: ~5 B body delta.
  - [x] Sub 5.2: Patch callers `op_dd` (src/edits.asm) + `op_yy` (src/edits.asm) to set `LD A, KIND_LINE` before the CALL. Net cost: +2 B per caller × 2 = +4 B.
  - [x] Sub 5.3: Update edits_copy_to_yank's contract block per AR23 to document the new In parameter (`A = kind`). Document the supported kinds (KIND_CHAR / KIND_LINE; KIND_BLOCK is for Epic 3).
  - [x] Sub 5.4: Verify Story 2.10's existing tests still pass (the post-patch op_dd / op_yy still set yank_kind = KIND_LINE — invariant-preserving).

- [x] **Task 6: Implement `op_compose_d` (delete range; FR39 `d` + motion)** (AC4).
  - [x] Sub 6.1: Per-entry contract block per AR23. In: (state) pending_operator='d', cursor_offset=landing, motions_compose_entry=range_start, pending_motion_inclusive may be 0 or 1. Out: success — N bytes deleted; yank register updated (KIND_CHAR) or refused; buffer_dirty=1; cursor at range_start (or clamped per AC4 step 6); parser state zeroed. Trashes: A, BC, DE, HL, F. Calls: edits_compose_range, edits_copy_to_yank (with A=KIND_CHAR), status_set_message (on yank refusal), edits_range_delete, motion_byte_at_logical (post-delete EOF probe), motion_find_line_start (clamp), edits_dirty_and_redraw, parser_clear (tail-JP).
  - [x] Sub 6.2: Body composition per AC4 algorithm steps 1-8. 0-byte guard + inclusive bump + yank-attempt with PUSH/POP HL/BC bracketing across status_set_message (mirroring op_dd's structure at edits.asm:996-1009) + range-delete + EOF-clamp + edits_dirty_and_redraw + tail-JP parser_clear.
  - [x] Sub 6.3: pending_motion_inclusive cleanup at op_compose_d tail (`XOR A ; LD (pending_motion_inclusive), A`). Document the cleanup-by-the-consumer pattern OR move the cleanup into parser_clear (~3 B saved if shared with op_compose_y / op_compose_c — recommended).
  - [x] Sub 6.4: FR45 undo recording STUB — NO write to undo_buffer. Document the hook site per AR23 + add to Task 10 deferred-work entry.

- [x] **Task 7: Implement `op_compose_y` (yank range; FR39 `y` + motion)** (AC6).
  - [x] Sub 7.1: Per-entry contract block per AR23. In: same state as op_compose_d but pending_operator='y'. Out: yank register updated (KIND_CHAR) or refused; cursor RESTORED to motions_compose_entry; buffer + buffer_dirty UNCHANGED; parser state zeroed. Calls: edits_compose_range, edits_copy_to_yank (with A=KIND_CHAR), status_set_message (on refusal), parser_clear (tail-JP).
  - [x] Sub 7.2: Body — at the top, RESTORE cursor_offset := motions_compose_entry (this is the vi-faithful "yank doesn't move cursor" behaviour). Then 0-byte guard, inclusive bump, yank-attempt, refusal path, parser_clear tail.
  - [x] Sub 7.3: NO undo recording (yank-only).

- [x] **Task 8: Implement `op_compose_c` (change range; FR39 `c` + motion)** (AC8).
  - [x] Sub 8.1: Per-entry contract block per AR23. In: pending_operator='c'. Out: N bytes deleted; yank register updated (KIND_CHAR) or refused; cursor at range_start; mode_byte=MODE_INSERT; status="-- insert --"; parser state zeroed (via enter_insert_mode's tail-JP parser_clear). Calls: edits_compose_range, edits_copy_to_yank, status_set_message (yank refusal), edits_range_delete, edits_dirty_and_redraw, enter_insert_mode (tail-JP).
  - [x] Sub 8.2: Body — same shape as op_compose_d through step 5 (range-delete), but SKIP the EOF-clamp and BUFFER_DIRTY work (enter_insert_mode + later INSERT-mode handlers manage cursor and dirty). After range-delete, CALL edits_dirty_and_redraw, JP enter_insert_mode.

- [x] **Task 9: Implement `op_compose_indent` / `op_compose_dedent` / `op_indent_line` / `op_dedent_line`** (AC9, AC10).
  - [x] Sub 9.1: `op_compose_indent` body — call edits_compose_range; line-promote (extend range_start backward to line-start; extend range_end forward to line-end + 1); line-walk inserting INDENT_BYTE at each line-start; restore cursor; edits_dirty_and_redraw; parser_clear.
  - [x] Sub 9.2: `op_compose_dedent` body — same range computation + line-promote; line-walk that EXAMINES the byte at each line-start and only deletes if it equals INDENT_BYTE (no-op for that line otherwise); restore cursor; edits_dirty_and_redraw; parser_clear.
  - [x] Sub 9.3: `op_indent_line` (for `>>` / `N>>` from parser_doubled_operator_stub): call `edits_line_range_for_count` (Story 2.10 helper) to get the line-range; compute promoted_end = HL + BC; JP into the indent line-walk (shared with op_compose_indent if factored, else duplicate).
  - [x] Sub 9.4: `op_dedent_line` symmetric.
  - [x] Sub 9.5: **Factoring decision**: the line-walk body has insert-vs-delete divergence. Choices: (a) inline both — ~30 B each = ~120 B total for the four entries; (b) factor `edits_indent_walk(HL, DE, A=op)` where A=0 means insert and A=1 means dedent — saves ~30-40 B but adds complexity. Recommendation: (a) inline for the first dev pass; refactor to (b) in a code-review patch if NFR9 budget squeezes.
  - [x] Sub 9.6: AR23 contract blocks for all 4 entries.

- [x] **Task 10: Patch `parser_doubled_operator_stub` for `>>` / `<<`** (AC10).
  - [x] Sub 10.1: In `src/parser.asm:502-514`, add the `CP '>' ; JP Z, op_indent_line` and `CP '<' ; JP Z, op_dedent_line` arms before the existing c-fall-through. Update the contract block per AR23 to note the two new arms.
  - [x] Sub 10.2: Sanity-check: state-read-before-clear discipline still holds (op_indent_line / op_dedent_line read count_accumulator via edits_line_range_for_count BEFORE their tail-JP parser_clear — same shape as op_dd / op_yy).
  - [x] Sub 10.3: Update parser.asm module-header docstring per AR23 — note the dispatcher now routes 'd' / 'y' / '>' / '<' to real handlers; only `c` (cc) still surfaces msg_not_implemented.

- [x] **Task 11: Update `src/edits.asm` module-header docstring** (AC2, AC4, AC6, AC8, AC9, AR23).
  - [x] Sub 11.1: Add `edits_compose_or_clear`, `edits_compose_range`, `op_compose_d`, `op_compose_y`, `op_compose_c`, `op_compose_indent`, `op_compose_dedent`, `op_indent_line`, `op_dedent_line` to the Public list.
  - [x] Sub 11.2: Add per-entry contract blocks per AR23 (content from Sub 3.1, 4.1, 6.1, 7.1, 8.1, 9.6).
  - [x] Sub 11.3: Update Purpose block — closing parenthetical mentions Story 2.11 lands FR39 (operator+motion compose) + FR40 (counted compose) + the `>>` / `<<` doubled-operator forms. The FR list grows from "FR24-FR29 + FR31" to "FR24-FR29 + FR31 + FR39 + FR40".
  - [x] Sub 11.4: Update State owned block — note: yank_kind / yank_length / yank_buffer now written by op_compose_d / op_compose_y / op_compose_c (KIND_CHAR success path); UNCHANGED on capacity-refusal path. cursor_offset written by all op_compose_* (range_start for d/c; restored to motions_compose_entry for y; restored to entry for indent/dedent). mode_byte written by op_compose_c (transitively via enter_insert_mode). pending_motion_inclusive read + cleared by op_compose_d / op_compose_y / op_compose_c.
  - [x] Sub 11.5: Extend Dependencies block — note dependency on motions.asm's `motions_compose_entry` scratch cell (read-only from edits.asm); on state.inc's new `pending_motion_inclusive` flag; on `INDENT_BYTE` from equates.inc (Story 2.11 is the first reader).

- [x] **Task 12: Headless tests** (AC12).
  - [x] Sub 12.1: 6 canonical tests landed (epic spec line 1386): `edits_dw-deletes-word.asm`, `edits_d$-to-end-of-line.asm`, `edits_c-enters-insert.asm`, `edits_y3w-yanks-without-modifying.asm`, `edits_indent-shift.asm`, `parser_compose-count-op-motion-end-to-end.asm`.
  - [x] Sub 12.2: ~16 additional tests per AC12 enumeration. The dev pass MAY drop 1-3 if their coverage is fully subsumed by sibling tests (document drops + rationale per the Story 2.9 / 2.10 pattern).
  - [x] Sub 12.3: Sentinel allocation per landed test per the Story 2.5..2.10 0x80..0x87 envelope convention.
  - [x] Sub 12.4: All tests get the full INCLUDE chain (test_prologue.inc / test body / test_epilogue.inc / production sources / test_teardown_stub.inc + test_input_loop_stub.inc / state.inc).
  - [x] Sub 12.5: For the parser_*.asm tests (the dispatch-chain-coverage tests), pre-set pending_operator from `test_prologue`-region code BEFORE driving the second `parser_handle_operator` call OR drive the full sequence (preferred — pins the AC1 / AC10 chain end-to-end).

- [x] **Task 13: NFR9 + NFR18 + AR sweeps** (AC13).
  - [x] Sub 13.1: Two consecutive `make clean && make all` produce byte-identical `vibe.com` — capture SHA.
  - [x] Sub 13.2: AR enforcement sweeps clean — `BIOS_CONOUT` / `LD (gap_start|gap_end), ...` / `BDOS_CALL` greps return only doc-comment refs in `src/edits.asm` / `src/parser.asm` / `src/motions.asm`; zero new code refs. `CALL gapbuf_insert` code-ref count in edits.asm grows: was 3 sites (edits_insert_literal + edits_open_below + edits_open_above + edits_insert_newline); becomes 4-5 sites (+ op_compose_indent line-walk; +1 each in op_indent_line if not shared).
  - [x] Sub 13.3: `vibe.com` size: 4793 → projected ~5193-5343 B (Δ+400-550 B). **If over 5120 B**, document the overshoot in completion notes and trigger the NFR9 amend OR apply the AC13 mitigations (factor line-walk; share yank-refused arm; defer indent/dedent to a follow-up story).
  - [x] Sub 13.4: `DISPATCH_NORMAL_COUNT` confirmed unchanged at 33 (no new dispatch_normal entries).
  - [x] Sub 13.5: Test pass count: 134 → ~156 pass / 1 deliberate-fail (22 new tests).

- [x] **Task 14: deferred-work.md housekeeping.**
  - [x] Sub 14.1: FR45 undo recording stubs for `op_compose_d` / `op_compose_c` / `op_compose_indent` / `op_compose_dedent` / `op_indent_line` / `op_dedent_line` documented in deferred-work.md (`Deferred from: dev of story-2-11-...` section). Hook site for d/c: BEFORE the yank-copy (gap-buffer bytes still at pre-delete positions). Hook site for indent/dedent: BEFORE the first per-line insert/delete (the line-walk's first call). op_compose_y NEVER records undo (yank-only).
  - [x] Sub 14.2: Document the AC5 line-class motion divergence (epic spec treats `y3j` as CHAR-class; vi treats it as LINE-class). Suggest a future-story `pending_motion_line_class` flag (analogous to `pending_motion_inclusive`) that the line-class motions set; the per-operator bodies would promote the range to whole-line bounds when the flag is set. Story 3.x or post-MVP polish.
  - [x] Sub 14.3: Document the AC9 indent/dedent cursor-post-position choice (vi's "first non-whitespace of the line" vs the simpler "restore to entry cursor"). Note that the post-MVP polish is a Story 3.7 (visual shift) or post-MVP enhancement.
  - [x] Sub 14.4: Document the `parser_dispatch` IX safety concern is STILL open (deferred-work.md:96-97). Story 2.11's chosen architecture (per-motion compose prologue + shared compose tail) does NOT use `parser_dispatch` as a production caller — the existing motion handlers are dispatched directly via `dispatch_normal`, not via `parser_dispatch`. So the IX safety question remains a Story 3.x or post-MVP concern.
  - [x] Sub 14.5: If the dev pass observes test-coverage gaps OR NFR9 overshoot, document them per the Story 2.9 / 2.10 pattern.

- [x] **Task 15: Hardware UAT** (AC11) — confirmed by Ant 2026-05-16: "all working well including boundary cases".
  - [x] Sub 15.1: `make push` SLIDE transfer to real MicroBeast.
  - [x] Sub 15.2: Ant stepped through the 12-step AC11 UAT script on real MicroBeast — all 12 steps + boundary cases pass.
  - [x] Sub 15.3: Story flipped directly to `done` (per Ant's call — code-review may still run as cleanup but is no longer a gate to sprint progression).

## Dev Notes

### Architecture compliance

- **AR13 (no screen emission from edits / parser / motions).** Zero `BIOS_CONOUT_*` references in any of the new code. Render-side reflection of edits happens via `render_mark_all_dirty` (already paid for); status surfaces (msg_yank_too_large) route through `status_set_message` (the AR12 funnel).
- **AR14 (no direct buffer mutation outside gapbuf primitives).** All compose-op buffer mutations route through `gapbuf_insert` (indent) or `gapbuf_delete` (range-delete; transitively via Story 2.10's `edits_range_delete`). No `LD (gap_start), DE` / `LD (gap_end), DE` writes anywhere in the new code.
- **AR15 (no raw BDOS).** Pure-memory ops throughout.
- **AR12 (status messages via funnel).** `msg_yank_too_large` (Story 2.10) is the only status string surfaced by the compose-ops. `msg_not_implemented` continues to surface only for `cc` (the doubled `c` arm — out of MVP scope).
- **AR23 (module header documentation).** edits.asm + motions.asm + parser.asm + state.inc all grow header entries per the per-AC patches. No new module added; AR25 INCLUDE chain unchanged.
- **AR25 (INCLUDE chain).** `src/vibe.asm`'s INCLUDE order keeps `statusln → gapbuf → render → dispatch → parser → motions → edits → exline → fileio`. `edits_compose_or_clear` is forward-referenced from motions.asm; resolved by sjasmplus's two-pass model (same shape as Story 2.10's `parser_doubled_operator_stub → op_dd / op_yy`).
- **MC3 (binary-search dispatch).** `dispatch_normal` count UNCHANGED at 33 entries. Binary-search worst case stays at 6 iterations.
- **MC4 (handler signature — A=key on entry; state via state.inc symbols).** Motion handlers receive A = the motion-key byte (which they continue to ignore — the AC1 prologue does NOT inspect A). op_compose_* read pending_operator + cursor_offset + motions_compose_entry directly via state.inc symbols.
- **SR6 (yank register).** Story 2.11 is the FIRST writer of KIND_CHAR. The 3-kind discriminator (KIND_CHAR / KIND_LINE / KIND_BLOCK) becomes load-bearing for Story 2.12 paste — paste dispatches on yank_kind. The over-capacity refusal protocol (yank register UNCHANGED + status banner) is uniform across CHAR and LINE; the only difference is the kind byte written on success.
- **BH1 / BH2 (word boundary / counted clamp).** Compose-ops inherit motion handlers' BH1 / BH2 behaviour transparently — the motion computes the landing per BH1 / BH2, the compose tail reads the landing. No new BH semantics introduced.
- **FR39 / FR40 (the load-bearing FRs for this story).** Operator+motion compose; counted variants. End-to-end verified via the ~22 headless tests (AC12) + AC11 hardware UAT.
- **FR45 / FR46 (undo coverage — Story 2.13).** Compose-op inverse-op recording is a STUB for 2.11; full impl in 2.13. Hook sites documented in deferred-work.md (Sub 14.1).
- **FR50 (unsupported commands as no-op).** `cc` doubled form surfaces msg_not_implemented (unchanged from Story 2.10). 0-byte-range compose ops are silent no-ops (no msg_not_implemented surface — the user typed a valid composition; it just had nothing to operate on).
- **NFR1 / NFR2 / NFR3 (interactive feedback / sustained typing / cursor-motion latency).** Each composed op: motion-execute (~existing motion cost) + edits_compose_range (~5 T-states pure math) + per-operator body (yank-copy O(range_length); range-delete O(range_length); insert/dedent line-walk O(line_count × per-line-op cost)). Worst case `100>>` on a 100-line file: ~100 gapbuf_insert calls × ~50 T-states each = ~5000 T-states = 1.25 ms at 4 MHz — sub-perceptible. Worst case `1000dw`: motion_w walks ~6000 bytes (typical word density ~6 B/word), then op_compose_d yanks + deletes 6000 bytes — both O(6000) operations; ~150 ms total at 4 MHz — perceptible but acceptable (vi's `1000dw` is rarely typed).
- **NFR9 (code size).** Projected post-2.11: 5193-5343 B. **Likely OVER 5120 B ceiling.** Mitigations enumerated in AC13. Dev pass MUST report final size + apply mitigations OR escalate the NFR9 amend.
- **NFR18 (byte-identical rebuild).** Verified in Sub 13.1.

### Operator+motion compose — the architectural mechanism

The composition mechanism is **co-operation between the motion handler and the shared compose tail** via two pieces of shared state:

1. **`motions_compose_entry`** (2 B, module-local in motions.asm) — written unconditionally by every motion handler's entry prologue; read by `edits_compose_or_clear` to recover the range-start.
2. **`pending_motion_inclusive`** (1 B, in state.inc) — written by `motion_dollar` (and possibly `motion_G` in a future polish); read + cleared by op_compose_d / op_compose_y / op_compose_c to extend the half-open range by 1 byte. The flag is "the motion's landing offset is an INCLUSIVE position; the compose-op should treat it as the LAST byte of the range, not as one-past-the-last."

The compose tail (`edits_compose_or_clear`) is the **decision point**: if pending_operator is 0, run the bare motion (motion's existing landing commit to cursor_offset is correct; JP parser_clear). If pending_operator is set, route to the per-operator body which:
- Recovers the range from (cursor_offset, motions_compose_entry).
- Applies the operator (delete + yank for d; yank for y; delete + INSERT for c; line-walk insert for `>`; line-walk dedent for `<`).
- Cleans up pending_motion_inclusive.
- Tail-JPs parser_clear (or enter_insert_mode for `c`, which itself tail-JPs parser_clear).

**State-discipline cross-reference** (same shape as Story 2.10's parser_doubled_operator_stub → op_dd / op_yy):
- `parser_handle_operator` (parser.asm) sets pending_operator on first 'd' / 'y' / 'c' / '>' / '<' press.
- Motion handler (motions.asm) runs on the NEXT keypress; the prologue captures motions_compose_entry.
- The motion's body computes the landing and writes cursor_offset.
- The motion's tail (`JP edits_compose_or_clear` per AC1) routes to the compose decision.
- Compose decision reads pending_operator BEFORE the eventual parser_clear (state-read-before-clear).

A "consistency cleanup" that:
- Hoisted the compose prologue OUT of each motion (into a single dispatch-time site) would break gg/G (dispatched from parser arms, not dispatch_normal).
- Hoisted parser_clear INTO `edits_compose_or_clear`'s top (before the pending_operator read) would break the entire compose layer — `pending_operator` would be 0 by the time the dispatcher tried to use it.

Document the constraint at every motion handler's contract block + at `edits_compose_or_clear`'s contract block + at each per-operator body's contract block per AR23.

### Range derivation + inclusive-landing semantic — vi muscle-memory pins

Vi's operator+motion composition has a known subtlety: motions like `$`, `G`, `e` are "inclusive" (their landing IS the last byte to operate on); motions like `w`, `l`, `j`, `gg`, `0`, `h`, `b`, `k` are "exclusive" (their landing is the first byte AFTER the operation range). The half-open `[start, end)` mathematical range matches the exclusive case naturally; inclusive motions need a +1 extension.

For Story 2.11 the only inclusive motion landed is `motion_dollar`. The `pending_motion_inclusive` flag is the per-motion signal. `motion_G` MAY be inclusive too (in vi, `dG` deletes through the last line inclusive), but the epic spec's `y3j` example treats line-class motions as character-wise, which sidesteps the question for `G`. The dev pass MAY set the flag in motion_G too if the chosen semantic matches — pin the choice with a test.

Real vi has many more inclusive motions (`e`, `f`, `t`, `;`, `'`, `[`, `]`, `M`, `H`, `L`, `}`, `{`, `%`, `*`, `#`, `n`, `N`, ...) — none of which exist in VIBE MVP. Future stories adding any of these MUST set `pending_motion_inclusive` if they're inclusive — document in motion_dollar's contract block as the canonical pattern.

### Line-promote algorithm for indent/dedent

The line-promote step (AC9) extends the character-wise compose range to the whole lines it overlaps:

```
;; Input: HL = range_start (char-wise), DE = range_end (char-wise; exclusive).
;; Special case: BC == 0 (no-move motion → >>/<< or >0/<0 / >$/<$ / etc.):
;;   range_start := motion_find_line_start(motions_compose_entry)
;;   range_end   := motion_find_line_end(motions_compose_entry) + 1
;; General case:
;;   line_start  := motion_find_line_start(HL)
;;   ;; For end: subtract 1 from DE (because range_end is exclusive — the byte
;;   ;; at DE is NOT in the range; the byte at DE-1 IS). Find that byte's
;;   ;; line-end. Add 1 to include the trailing LF (if present).
;;   line_end_at := DE
;;   DEC line_end_at                    ; last byte in the char-wise range
;;   line_end    := motion_find_line_end(line_end_at)
;;   INC line_end                       ; include trailing LF (or stop at file_length)
```

The +1 / -1 dance is tricky; pin with tests. **Edge case**: when `range_end - 1 == range_start` (a 1-byte char-wise range that happens to span one line), the line-promote should yield the whole line. **Edge case**: when the range spans 0 lines (impossible if BC > 0; the line-promote always yields ≥1 line).

For `>>` / `<<` doubled-form (via op_indent_line / op_dedent_line), the input is `edits_line_range_for_count`'s output — already line-promoted (the helper computes line bounds). No additional line-promote needed; just feed straight into the line-walk.

### Yank-copy parameterisation backward compat

The `edits_copy_to_yank` patch (AC7) changes the contract from "always writes KIND_LINE" to "writes the kind from register A". Story 2.10's tests for op_dd / op_yy assert post-call `yank_kind == KIND_LINE` — those tests continue to pass because op_dd / op_yy are patched (Sub 5.2) to `LD A, KIND_LINE` before the call. The invariant from the test's perspective is preserved.

A regression risk: if a future story adds a new caller to `edits_copy_to_yank` and forgets to set A, the kind will be whatever was in A at the call site (likely garbage). Document the new In parameter prominently in the contract block (Sub 5.3). The pre-A-load-required pattern is the same shape as `status_set_message`'s `LD A, error_code_or_zero` convention.

### Filename and module placement choices

- **op_compose_* live in `src/edits.asm`** alongside op_dd / op_yy / edits_delete_char / etc. AR25 INCLUDE chain unchanged.
- **`edits_compose_or_clear` lives in `src/edits.asm`** (NOT motions.asm — it's a compose-or-clear decision routine, semantically more an edits-side concern; AR23 contract block documents the read-from-motion-state dependency).
- **`edits_compose_range` lives in `src/edits.asm`** (helper for op_compose_*).
- **`motions_compose_entry` lives in `src/motions.asm`** (module-local — written by every motion handler; module-internal scratch).
- **`pending_motion_inclusive` lives in `inc/state.inc`** (cross-module; written by motions.asm; read by edits.asm).
- **Test naming convention.** Files under `test/cases/edits_dw-*.asm`, `test/cases/edits_d*-*.asm`, `test/cases/edits_y*-*.asm`, `test/cases/edits_c*-*.asm`, `test/cases/edits_indent-*.asm`, `test/cases/edits_dedent-*.asm`, `test/cases/parser_compose-*.asm`, `test/cases/parser_doubled-operator-routes-to-indent.asm`, etc. Matches Story 2.5..2.10 per-handler-grouped pattern.

### Previous story intelligence

**From [[story-2-10-doubled-operator-commands-dd-yy]] (the immediate predecessor — first writer of yank register):**
- `edits_copy_to_yank` (edits.asm:869) exists as a parameterise-on-kind candidate. Story 2.11 patches it (AC7).
- `edits_range_delete` (edits.asm:925) is reusable for any character-wise range deletion. Story 2.11's op_compose_d / op_compose_c use it directly.
- `edits_line_range_for_count` (edits.asm:784) is reusable for line-bounded operations. Story 2.11's op_indent_line / op_dedent_line use it.
- `parser_doubled_operator_stub` (parser.asm:502) is the doubled-operator dispatcher. Story 2.11 extends it for `>>` / `<<` (AC10).
- KIND_CHAR (= 0x00) is already declared (equates.inc:82). Story 2.11 is the first writer.
- **State-read-before-clear discipline** (Story 2.10 dev triage; deferred-work.md:93-95 / Story 2.6 motion_gg precedent) — Story 2.11 honours it: motion handlers read count via motion_apply_count BEFORE their (eventual) parser_clear tail. op_compose_d / op_compose_y / op_compose_c read pending_operator + motions_compose_entry BEFORE parser_clear.
- **AC8 Option A (cursor-bounce N-iter `gapbuf_delete` loop)** (Story 2.10 deferred-work.md:317) — Story 2.11 inherits Option A by re-using edits_range_delete. No revisit needed unless the dev pass observes NFR1/2/3 pressure.
- **AC2 last-line-no-LF + S>0 yank semantic** (Story 2.10 deferred-work.md:319) — irrelevant to Story 2.11 (op_compose_d / op_compose_y operate on character-wise ranges, not line-bounded ranges with the S-1 adjustment).

**From [[story-2-9-single-character-delete-x]] (the deletion + cursor-clamp pattern):**
- The EOL/EOF clamp shape in `edits_delete_char` (edits.asm:731-746) is the template for op_compose_d's post-delete cursor placement (AC4 step 6). Reuse the `motion_byte_at_logical` probe + `DEC HL` clamp pattern.
- The 0-deletes detection via `SBC HL, BC` (edits.asm:725-730) is the template for op_compose_d's 0-byte guard (AC4 step 2).

**From [[story-2-8-insert-mode]] (INSERT mode + edits.asm module pattern):**
- `enter_insert_mode` (dispatch.asm) is the tail-JP target for op_compose_c. Sets mode_byte=MODE_INSERT, surfaces "-- insert --", tail-JPs parser_clear.
- The `edits_dirty_and_redraw` helper (edits.asm:~500) is the buffer_dirty + render_mark_all_dirty funnel. Used by op_compose_d / op_compose_c / op_compose_indent / op_compose_dedent.

**From [[story-2-7-counted-motions]] (motion_apply_count + counted motion patterns):**
- `motion_apply_count` defaults count_accumulator to 1. Inherited transitively by every counted compose-op (`2dw`, `c5w`, `y3j`, `5>>`).
- Sticky-column hoist in motion_j / motion_k (Story 2.7 AC10) — preserved across the compose-aware patch (the prologue + tail patches don't touch the sticky-column code).
- Test fixture lesson — when designing tests to pin "N bytes deleted" or "N words yanked", the by-1 outcome should differ from the by-N outcome (per Story 2.7 code-review patch P1). Counted-compose tests (e.g. `edits_d2j-clamps-at-eof.asm`) follow this rule.

**From [[story-2-6-word-line-buffer-motions]] (motion_w / motion_b / motion_0 / motion_dollar / motion_gg / motion_G):**
- `motion_w` (motions.asm:748) — landing is start of next word (exclusive). `dw` deletes [cursor, next_word_start).
- `motion_b` (motions.asm:821) — landing is start of previous word (BACKWARD motion → swap in edits_compose_range).
- `motion_dollar` (motions.asm:933) — landing is last printable byte (INCLUSIVE — `pending_motion_inclusive=1`).
- `motion_gg` (motions.asm:1075) — line 1 start (BACKWARD from any line > 1).
- `motion_G` (motions.asm:1036) — last-line start (typically FORWARD).
- `motion_find_line_start` / `motion_find_line_end` are reusable for the line-promote step in op_compose_indent / op_compose_dedent.
- `motion_byte_at_logical` is reusable for the post-delete EOF probe (same shape as Story 2.9's clamp).

**From [[story-2-5-basic-motions]] (motion_h / motion_l / motion_j / motion_k + AC13 parser_clear hygiene):**
- `motion_h` / `motion_l` are 1-byte motions; `dl == x`; `dh` deletes the byte BEFORE cursor (1-byte backward).
- The "every dispatched key clears parser state" invariant (AC13) — Story 2.11 honours it: every compose-op path ends in parser_clear (transitively via enter_insert_mode for op_compose_c).

**From [[story-1-10-parser]] (parser — the operator-state machine that this story finally exercises):**
- `parser_handle_operator` sets pending_operator on first press; routes to parser_doubled_operator_stub on doubled. The intermediate state ("'d' pressed; pending_operator='d'; waiting for motion") is what enables Story 2.11's compose layer.
- `parser_handle_motion_prefix` (motions_compose_entry) — Story 2.6 retired the gg-stub; motion_gg is dispatched from the doubled-prefix arm. For Story 2.11, motion_gg's compose prologue must execute BEFORE the parser_handle_motion_prefix tail-JP (which is `JP motion_gg` — execution flows into motion_gg's body which runs the prologue first). ✅ Already correct.

**From [[story-1-9-mode-dispatch]] (dispatch tables):**
- `dispatch_normal`'s 'h' / 'l' / 'w' / 'b' / '0' / '$' / 'G' / 'j' / 'k' / 'g' all route to motion handlers (or parser arms that route to motion handlers). Story 2.11 doesn't add new dispatch entries; the compose layer rides on the existing routing.

**From [[story-1-7-gap-buffer]] (gapbuf primitives):**
- `gapbuf_insert` is the AR14 mutation surface for indent. Returns CF=1 on full; surfaces msg_file_too_large via its own AR12 funnel call. op_compose_indent's line-walk inherits this overflow behaviour transparently.
- `gapbuf_delete` is the AR14 mutation surface for delete (transitively via edits_range_delete + op_compose_dedent's per-line delete).
- Buffer-full on indent: if `gapbuf_insert` returns CF=1 mid-walk, op_compose_indent halts at the failure point. Partial indent content persists in the buffer; status shows msg_file_too_large. Document this behaviour in op_compose_indent's contract block + as a test (`edits_indent-fills-buffer.asm` if budget permits; otherwise defer).

**From [[story-1-5-status-line]] / statusln.asm conventions:**
- `status_set_message` is the AR12 funnel. msg_yank_too_large + msg_not_implemented continue to be the only status strings touched. No new strings added for Story 2.11.

**From [[story-1-3-static-memory-map]]:**
- `cursor_offset`, `pending_operator`, `count_accumulator`, `yank_kind`, `yank_length`, `yank_buffer`, `buffer_dirty`, `mode_byte`, `pending_motion_prefix` all declared. Story 2.11 adds `pending_motion_inclusive` (1 B) — the first new state.inc cell since Story 1.3.

**From [[story-1-2-compile-time-constants]] / [[story-1-1-project-skeleton]]:**
- `INDENT_BYTE` (equates.inc:68) declared but unused until Story 2.11. Story 2.11 is the first reader.
- `KIND_CHAR` (equates.inc:82) declared by Story 2.10 — Story 2.11 is the first writer.

### Git intelligence

Recent commits (post-Story 2.8):

- `94b4f16 story 2.9: x deletes char under cursor; counted Nx with EOL/EOF clamp` — Story 2.9 dev pass (single-character delete; the deletion-class precedent for op_compose_d).
- `fdd2d10 social media preview image` — Non-dev cosmetic commit.
- `57325ff story 2.8: INSERT mode lands; i/a/o/O, typing, backspace, Enter→LF, Esc` — Story 2.8 (enter_insert_mode lands; op_compose_c uses it as its tail-JP).
- `425bc2e code review changes` — Story 2.7 code review.
- `be63514 story 2.7: counted motions verified end-to-end; sticky-column j/k landed` — Story 2.7 dev pass (motion_apply_count + counted motions).

Story 2.10's `dd` / `yy` commit is the immediate predecessor (per sprint-status: 2-10 status is `done` at 2026-05-16; the dev/review commits will land alongside the 2.10 → done flip). Story 2.11's dev pass starts from the 2.10 baseline.

Patterns to follow:
- Single dev-commit per story containing the production code + tests + spec + sprint-status flips (the Story 2.5..2.10 model).
- Separate code-review commit applying review patches (Story 2.10's recent pass added 7 test-coverage patches + 0 production changes).
- Sentinel byte at `0xCFFE` per TH1 (test/inc/test_prologue.inc).
- INCLUDE chain in test cases: pre-ORG headers, then `test_prologue.inc`, test body, `test_epilogue.inc`, production sources, `test_teardown_stub.inc` + `test_input_loop_stub.inc`, finally `inc/state.inc`.
- Gap-buffer fixture pattern: `CALL gapbuf_init` → LDIR payload → set `gap_start := GAP_BUFFER_BASE + N`. Mode pre-set via `LD A, MODE_NORMAL ; LD (mode_byte), A`. For compose tests, pre-seed `pending_operator` (and `count_accumulator` for counted forms) BEFORE calling the motion handler.
- Yank-register pre-seed for "verify nothing changed on refusal" tests: `LD A, 0xEE ; LD (yank_kind), A ; LD HL, 0xCAFE ; LD (yank_length), HL`.
- `motions_compose_entry` pre-seed for "verify prologue wrote it" tests: `LD HL, 0xFFFF ; LD (motions_compose_entry), HL` before the motion CALL.

### Testing requirements

- All ~22 new tests under `test/cases/edits_*.asm` / `test/cases/parser_*.asm`. Each must build under `make -C test`, run under iz-cpm with the 5-second timeout, and report PASS via TH1 / TH2.
- The dispatch-chain tests (`parser_compose-count-op-motion-end-to-end.asm`, `parser_doubled-operator-routes-to-indent.asm`, etc.) drive the full keystroke sequence via parser_handle_digit + parser_handle_operator + motion handler. This matches the Story 2.10 parser-test convention.
- Tests that drive directly via `CALL op_compose_d` / `CALL motion_w` after pre-seeding pending_operator exercise the compose layer in isolation (no parser-chain coverage; pins the AC2-AC9 semantics). Mix of both kinds (per AC12).
- Tests that pin yank capacity refusal pre-seed `yank_kind` and `yank_length` to non-KIND_CHAR / non-matching values; assert these are UNCHANGED post-call.
- Tests for the inclusive-landing semantic (motion_dollar) pre-seed `pending_motion_inclusive = 0` and verify post-call cleanup (== 0).
- Tests for the cursor-restore-on-yank semantic (op_compose_y) MUST have a motion that observably moves the cursor (e.g., y3w) so the restore is testable.
- Sentinel allocation per test per the Story 2.5..2.10 convention.

### Project Structure Notes

- **No new source files.** Story 2.11 extends `src/edits.asm`, `src/parser.asm`, `src/motions.asm`, `inc/state.inc` only.
- **No new inc/*.inc files.** All constants in `equates.inc`; the one new state cell goes in `state.inc`.
- **~9 new public symbols** (in src/edits.asm): `edits_compose_or_clear`, `edits_compose_range`, `op_compose_d`, `op_compose_y`, `op_compose_c`, `op_compose_indent`, `op_compose_dedent`, `op_indent_line`, `op_dedent_line`. Optionally the indent/dedent line-walk if factored.
- **One module-local cell added** (in src/motions.asm): `motions_compose_entry DEFW 0`.
- **One state.inc cell added**: `pending_motion_inclusive` (1 B).
- **`parser_doubled_operator_stub` body extended** (parser.asm:502-514) — name retained; +8 B for two new arms.
- **`edits_copy_to_yank` body patched** (edits.asm:869) — same name; +5 B for kind parameterisation. Story 2.10 callers (op_dd / op_yy) patched to set A=KIND_LINE before CALL.
- **dispatch_normal UNCHANGED** at 33 entries.
- **dispatch_insert / dispatch_command / dispatch_visual** unchanged.
- **`src/vibe.asm` INCLUDE chain unchanged.**
- **~22 new test files** under `test/cases/edits_*.asm` + `test/cases/parser_*.asm`.

### Source tree paths touched

```
.
├── src/
│   ├── edits.asm             # UPDATE — add 9 public entries (compose layer); patch edits_copy_to_yank; module-header docstring extended
│   ├── motions.asm           # UPDATE — add compose prologue + compose tail patch to 10 motion handlers; add motions_compose_entry DEFW; module-header docstring extended
│   ├── parser.asm            # UPDATE — extend parser_doubled_operator_stub for >>/<<; module-header docstring updated
│   └── ; statusln.asm        # UNCHANGED — no new status strings
├── inc/
│   ├── equates.inc           # UNCHANGED — INDENT_BYTE + KIND_CHAR already declared
│   └── state.inc             # UPDATE — add pending_motion_inclusive (1 B)
├── _bmad-output/
│   ├── planning-artifacts/   # UNCHANGED
│   └── implementation-artifacts/
│       ├── 2-11-composed-operator-motion-dw-d-c5w-y3j.md   # THIS FILE
│       ├── deferred-work.md                                # UPDATE (Task 14)
│       └── sprint-status.yaml                              # UPDATE (status flips backlog → ready-for-dev → in-progress → review → done)
└── test/
    └── cases/
        ├── edits_dw-deletes-word.asm                                # NEW (canonical)
        ├── edits_d$-to-end-of-line.asm                              # NEW (canonical)
        ├── edits_c-enters-insert.asm                                # NEW (canonical)
        ├── edits_y3w-yanks-without-modifying.asm                    # NEW (canonical)
        ├── edits_indent-shift.asm                                   # NEW (canonical)
        ├── parser_compose-count-op-motion-end-to-end.asm            # NEW (canonical)
        ├── edits_dl-equals-x.asm                                    # NEW
        ├── edits_dh-from-mid-line.asm                               # NEW
        ├── edits_db-from-mid-buf.asm                                # NEW
        ├── edits_dgg-from-line-3.asm                                # NEW
        ├── edits_dG-from-line-1.asm                                 # NEW
        ├── edits_d2j-clamps-at-eof.asm                              # NEW
        ├── edits_dw-no-op-at-eof.asm                                # NEW
        ├── edits_dw-yank-too-large.asm                              # NEW
        ├── edits_yw-cursor-unchanged.asm                            # NEW
        ├── edits_cw-then-insert.asm                                 # NEW
        ├── edits_indent-counted-3lines.asm                          # NEW
        ├── edits_dedent-no-op-no-leading-space.asm                  # NEW
        ├── edits_dedent-removes-leading-space.asm                   # NEW
        ├── parser_doubled-operator-routes-to-indent.asm             # NEW
        ├── parser_doubled-operator-routes-to-dedent.asm             # NEW
        ├── parser_doubled-operator-routes-to-cc.asm                 # NEW
        ├── edits_compose-clears-pending-motion-inclusive.asm        # NEW
        └── motions_compose-entry-saved-by-h.asm                     # NEW
```

(24 test slots; the dev pass MAY drop 1-3 if their coverage is fully subsumed by sibling tests — document drops + rationale per the Story 2.9 / 2.10 pattern.)

### Files to be created and modified by this story

**New:**
- 6 canonical tests + ~16-18 additional tests per AC12 / Source tree paths above

**Modified:**
- `src/edits.asm` — 9 new public entries; edits_copy_to_yank patched (+5 B); op_dd / op_yy callers patched (+4 B); module-header Public list + per-entry contract blocks + State owned + Dependencies blocks updated per AR23. Net body delta: +300-450 B.
- `src/motions.asm` — compose prologue added to 10 motion handlers (+50 B); every `JP parser_clear` exit patched to `JP edits_compose_or_clear` (0 B per patch); motions_compose_entry DEFW added (+2 B); motion_dollar sets pending_motion_inclusive (+5 B); module-header Public list + per-entry contract blocks + State owned + Dependencies blocks updated per AR23. Net body delta: +60-80 B.
- `src/parser.asm` — parser_doubled_operator_stub body extended for `>>` / `<<` (+8 B); module-header docstring updated. Net body delta: +8 B.
- `inc/state.inc` — pending_motion_inclusive cell added (+1 B static).
- `_bmad-output/implementation-artifacts/deferred-work.md` — Story 2.11 deferred entries per Task 14.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — 2-11 status flips (backlog → ready-for-dev → in-progress → review → done).
- `_bmad-output/implementation-artifacts/2-11-composed-operator-motion-dw-d-c5w-y3j.md` — this file.

### Implementation Questions

**Saved for the dev pass / Ant to resolve before dev starts:**

1. **NFR9 budget — is the projected ~5193-5343 B overshoot acceptable?** If YES (formal NFR9 amend), document the new ceiling in deferred-work.md + proceed with the full AC2-AC10 scope. If NO, choose a mitigation: (a) defer indent/dedent operator entirely (`>` / `<` with motion + `>>` / `<<` doubled) to a later story (saves ~100-160 B; epic AC line 1352-1354 + 1372-1374 become unmet); (b) defer the `c` change operator (saves ~50-70 B; epic AC line 1364-1366 becomes unmet); (c) commit to aggressive line-walk factoring (saves ~30-40 B; cleanest but doesn't fix the overshoot alone).

2. **`pending_motion_inclusive` location — state.inc cell or motions.asm module-local?** state.inc is cross-module-grep-friendly + matches the `pending_*` naming. motions.asm module-local is +1 B saved in the static block (cell co-locates with motions_compose_entry). Recommendation: state.inc (consistency with `pending_operator` / `pending_motion_prefix` siblings outweighs the 1 B).

3. **AC5 line-class motion semantic** — accept the epic's CHAR-class semantic for `y3j` / `d2j` / etc., OR implement the vi-faithful LINE-class promotion? The epic is load-bearing; the dev pass should follow the epic spec. Document the vi-divergence in deferred-work.md (Sub 14.2).

4. **AC9 indent post-cursor** — restore-to-entry-cursor (simple) vs first-non-whitespace-of-line (vi-faithful)? Recommendation: restore-to-entry (matches "minimum viable" ethos; epic AC line 1352-1353 says "cursor returns to original"; vi's first-non-whitespace polish is post-MVP).

5. **`motion_G` inclusive flag** — set `pending_motion_inclusive` in motion_G or not? Epic AC line 1368-1370 treats line-class motions as character-wise (no inclusive bump). Recommendation: do NOT set the flag in motion_G; document the test (`edits_dG-from-line-1.asm`) to pin the chosen semantic.

### References

- FR39 (the primary load-bearing FR — operator+motion compose): [Source: _bmad-output/planning-artifacts/prd.md] line 762-763
- FR40 (counted compose — `2dw`, `c5w`, `y3j`, `5>>`): [Source: _bmad-output/planning-artifacts/prd.md] line 764-765
- FR45 (undo coverage — STUB in 2.11, full impl in 2.13): [Source: _bmad-output/planning-artifacts/prd.md] line 778
- FR46 (undo unavailability surfacing): [Source: _bmad-output/planning-artifacts/prd.md] line 779
- FR50 (unsupported commands as no-op — `cc` doubled form): [Source: _bmad-output/planning-artifacts/prd.md] line 793
- SR6 (yank register — Story 2.11 is the first writer of KIND_CHAR): [Source: _bmad-output/planning-artifacts/architecture.md] lines 456-461
- BH1 (word boundary — inherited transitively via motion_w / motion_b): [Source: _bmad-output/planning-artifacts/architecture.md] line 668
- BH2 (counted-motion clamps — inherited transitively): [Source: _bmad-output/planning-artifacts/architecture.md] BH2 section
- NFR1 / NFR2 / NFR3 (interactive feedback / sustained typing / cursor-motion latency): [Source: _bmad-output/planning-artifacts/prd.md] line 108 + 820-824
- NFR9 (code size budget — 5120 B ceiling — **likely to be challenged by this story**): [Source: _bmad-output/planning-artifacts/prd.md] lines 848-858
- NFR16 (compile-time knobs in equates.inc — INDENT_BYTE = 0x20): [Source: _bmad-output/planning-artifacts/architecture.md] line 1088
- NFR18 (byte-identical rebuild): verified by `make clean && make all`
- MC3 (binary-search dispatch — unchanged at 33 entries): [Source: _bmad-output/planning-artifacts/architecture.md] lines 485-527
- MC4 (handler signature — A=key on entry; state via state.inc symbols): [Source: _bmad-output/planning-artifacts/architecture.md] line 1502+
- AR12 / AR13 / AR14 / AR15 (architectural boundaries): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1434-1463
- AR23 (module header contracts): [Source: src/edits.asm:1-273 + src/motions.asm:1-146 + src/parser.asm:1-175 header blocks as exemplars]
- AR25 (INCLUDE chain in vibe.asm): [Source: src/vibe.asm + architecture.md:918-956]
- [[story-2-10-doubled-operator-commands-dd-yy]] (the immediate predecessor — first writer of yank register; established edits_copy_to_yank / edits_range_delete / edits_line_range_for_count helpers that Story 2.11 reuses): [Source: _bmad-output/implementation-artifacts/2-10-doubled-operator-commands-dd-yy.md]
- [[story-2-9-single-character-delete-x]] (cursor-bounce + EOL/EOF clamp shape — reused for op_compose_d post-delete cursor placement; FR45 stub pattern): [Source: _bmad-output/implementation-artifacts/2-9-single-character-delete-x.md]
- [[story-2-8-insert-mode]] (enter_insert_mode — tail-JP target for op_compose_c; edits.asm module pattern): [Source: _bmad-output/implementation-artifacts/2-8-insert-mode-i-a-o-o.md]
- [[story-2-7-counted-motions]] (motion_apply_count + counted-form pattern; sticky-column hoist preserved across the compose-aware patch): [Source: _bmad-output/implementation-artifacts/2-7-counted-motions.md]
- [[story-2-6-word-line-buffer-motions]] (motion_w / motion_b / motion_0 / motion_dollar / motion_gg / motion_G — the motion targets of compose; motion_find_line_start / motion_find_line_end / motion_byte_at_logical helpers for line-promote + EOF probe): [Source: _bmad-output/implementation-artifacts/2-6-word-line-buffer-motions-w-b-0-gg-g.md]
- [[story-2-5-basic-motions]] (motion_h / motion_l / motion_j / motion_k — the motion targets of compose; AC13 parser_clear hygiene): [Source: _bmad-output/implementation-artifacts/2-5-basic-motions-h-j-k-l.md]
- [[story-1-10-parser]] (parser_handle_operator + parser_doubled_operator_stub — the dispatch state machine that Story 2.11 finally exercises end-to-end): [Source: src/parser.asm:1-175 + 305-514 + _bmad-output/implementation-artifacts/1-10-command-parser-count-pending-operator-motion-prefix.md]
- [[story-1-9-mode-dispatch]] (dispatch_normal table — operator keys 'd' / 'y' / 'c' / '>' / '<' bound to parser_handle_operator; motion keys bound to motion handlers): [Source: src/dispatch.asm:455-556]
- [[story-1-7-gap-buffer]] (gapbuf_insert / gapbuf_delete — the AR14 mutation surface; buffer-full behaviour for op_compose_indent): [Source: src/gapbuf.asm:1-264]
- [[story-1-5-status-line]] (status_set_message AR12 funnel; msg_yank_too_large + msg_not_implemented re-used unchanged): [Source: src/statusln.asm]
- [[story-1-3-static-memory-map]] (state.inc — pending_motion_inclusive added in this story alongside pending_operator / pending_motion_prefix siblings): [Source: inc/state.inc:1-145]
- [[story-1-2-compile-time-constants]] (INDENT_BYTE = 0x20 already declared; this is the first reader): [Source: inc/equates.inc:68]
- deferred-work.md line 93-95 (state-read-before-clear discipline — Story 2.11 honours it across the compose layer): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 93-98
- deferred-work.md line 96-97 (`parser_dispatch` IX safety — STILL OPEN; Story 2.11's compose architecture does NOT use parser_dispatch as a production caller): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 96-97
- deferred-work.md line 224 (motion_apply_count count=0 vs count=1 distinction — flagged for Story 2.11 design; Story 2.11 does NOT need the distinction): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 224
- deferred-work.md line 301-305 (FR45 undo stub + cursor-bounce shape + BH2 stop-at-LF semantic — Story 2.11 inherits all three): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 301-307
- deferred-work.md line 315-339 (Story 2.10 deferred entries — Story 2.11 picks up the KIND_CHAR-introduction baton and the FR45 undo stub baton): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 315-341
- Epic 2 spec — Story 2.11 ACs (1337-1386) and the cross-story context (2.12 paste(p) and 2.13 undo(u) both depend on Story 2.11's compose layer for full coverage): [Source: _bmad-output/planning-artifacts/epics.md] lines 1337-1480

## Dev Agent Record

### Agent Model Used

claude-opus-4-7[1m]

### Debug Log References

(none — dev pass landed without iterative debug cycles; all 21 new tests
passed first-run after fixing the sjasmplus `$`-filename collision by
renaming `edits_d$-to-end-of-line.asm` → `edits_dollar-to-end-of-line.asm`.)

### Completion Notes List

**What landed (2026-05-16):**

- **Compose layer wired end-to-end** through every NORMAL-mode motion
  handler. Each motion saves entry cursor into `motions_compose_entry`
  (new module-local DEFW in motions.asm) via a 5-byte prologue, and
  tail-JPs `edits_compose_or_clear` (new public entry in edits.asm)
  instead of `parser_clear`. Bare-motion behaviour is observably
  unchanged (the prologue is a write to a scratch cell only; the
  shared tail falls through to parser_clear when pending_operator=0).

- **Five per-operator bodies** in edits.asm: op_compose_d (d+motion),
  op_compose_y (y+motion; cursor restored to entry per vi convention),
  op_compose_c (c+motion; tail-JP enter_insert_mode), op_compose_indent
  (>+motion; line-promoted), op_compose_dedent (<+motion; line-promoted).
  Plus two doubled-form entries op_indent_line (`>>`) and op_dedent_line
  (`<<`) wired into `parser_doubled_operator_stub` (parser.asm patched).

- **`edits_compose_range` helper** computes the half-open [start, end)
  byte range from cursor_offset (landing) + motions_compose_entry (entry)
  with a swap for backward motions (db / dgg / dh / dk / d0).

- **`pending_motion_inclusive` 1-byte flag** added to state.inc. Set by
  motion_dollar's prologue (only Story-2.11 inclusive motion); read by
  op_compose_d / op_compose_y / op_compose_c to extend the range by 1
  byte (vi-faithful `d$` / `c$` / `y$` inclusive-landing). Cleared
  centrally by parser_clear (Story 2.11 patched) so the cleanup is
  automatic for any future inclusive motion.

- **`edits_copy_to_yank` parameterised on register A** for the yank
  kind (KIND_CHAR | KIND_LINE). Story 2.10 callers op_dd / op_yy
  patched to `LD A, KIND_LINE` before the CALL (invariant-preserving;
  Story 2.10 tests still pass unchanged). Story 2.11 is the FIRST
  writer of KIND_CHAR.

- **edits_indent_walk shared helper** parameterised on mode (insert /
  dedent) via a 1-byte module-local cell. Z80 has no clean callback
  shape; flag-byte approach saves ~30-40 B vs duplicating the body.
  A second module-local cell (`edits_indent_walk_dirty`) tracks
  whether any byte was actually inserted/deleted (so dedent on a
  line with no leading INDENT_BYTE is a silent no-op and does NOT
  set buffer_dirty).

- **Implementation Question choices made by dev pass** (per story spec):
  Q1 — proceeded with full scope; NFR9 overshoot of ~280 B documented
       below + in deferred-work.md for Ant + code-review to decide.
  Q2 — pending_motion_inclusive in state.inc (cross-module consistency
       with pending_operator / pending_motion_prefix siblings).
  Q3 — AC5 epic CHAR-class semantic followed; vi LINE-class divergence
       documented in deferred-work.md as Story 3.x / post-MVP polish.
  Q4 — AC9 indent/dedent post-cursor = "restore to entry cursor"
       (simple); vi's first-non-whitespace-of-line is post-MVP polish.
  Q5 — motion_G does NOT set pending_motion_inclusive (CHAR-class
       line-class semantic, matching epic AC5).

**Test count: 138 → 159 pass / 1 deliberate-fail (`harness_fail`).**
21 new tests landed (6 canonical + 15 additional); 3 tests from the
AC12 enumeration dropped with documented rationale (`edits_dG-from-line-1`
subsumed by `edits_dgg-from-line-3`; `edits_cw-then-insert` subsumed by
`edits_c-enters-insert`; `edits_compose-clears-pending-motion-inclusive`
subsumed by `edits_dollar-to-end-of-line`'s sentinel 0x86 assertion).

**NFR9 status — OVERSHOOT.** Pre-2.11 baseline: 4793 B (~93.6% of 5120 B
ceiling; 327 B headroom). Post-2.11: **5400 B = ~105.5% / 280 B over the
5120 B ceiling**. Mitigations applied in dev pass (shared yank-refused
arm inlining; factored edits_indent_walk via mode-flag selection)
saved ~30-40 B. Three escalation paths enumerated in deferred-work.md:
(A) formal NFR9 amend [recommended] — TPA fit (NFR10) holds; (B) defer
indent/dedent operator [breaks epic AC line 1352-1354 + 1372-1374];
(C) defer `c` change operator [breaks epic AC line 1364-1366]. Dev
pass shipped the full scope so subsequent stories aren't blocked on a
deferred operator; Ant + code-review may revisit.

**NFR18 — byte-identical rebuild verified.** Two consecutive `make
clean && make all` produce identical `vibe.com` (sha256
`e0f31199d7e775ffbc0fe2933132758a9e1b738718220049da494bf4ba8a70ea`).

**AR sweeps — clean.** AR13 (no BIOS_CONOUT): zero code refs in
src/edits.asm / src/parser.asm / src/motions.asm (only doc-comment
references). AR14 (no direct gap_start/gap_end writes): zero. AR15
(no BDOS_CALL): zero. AR25 INCLUDE chain unchanged. DISPATCH_NORMAL_COUNT
unchanged at 33 (0x21).

**FR45 undo recording STUB** for all 6 mutating compose ops (op_compose_d
/ op_compose_c / op_compose_indent / op_compose_dedent / op_indent_line
/ op_dedent_line); hook sites documented in deferred-work.md.
op_compose_y NEVER records undo (yank-only). Full impl in Story 2.13.

**Hardware UAT (AC11) PENDING.** AC11's 12-step script inlined in the
final chat handoff per vibe convention. Ant to step through on real
MicroBeast before story flips from `review` → code-review → `done`.

### File List

**Modified — production code:**
- `src/edits.asm` — added 9 new public entries (compose layer:
  edits_compose_or_clear, op_compose_d, op_compose_y, op_compose_c,
  op_compose_indent, op_compose_dedent, op_indent_line, op_dedent_line,
  + internal edits_compose_range, edits_indent_walk); patched
  edits_copy_to_yank for parameterised yank kind; patched op_dd /
  op_yy callers to set `LD A, KIND_LINE`; extended module-header
  docstring per AR23. Net body delta: ~+560 B.
- `src/motions.asm` — added compose prologue (~5 B) to all 10
  NORMAL-mode motion handlers (motion_h / l / j / k / w / b / 0 /
  dollar / G / gg); patched every `JP parser_clear` exit to
  `JP edits_compose_or_clear`; motion_dollar additionally writes
  pending_motion_inclusive=1; added motions_compose_entry DEFW;
  extended module-header docstring per AR23. Net body delta: ~+60 B.
- `src/parser.asm` — extended `parser_doubled_operator_stub` body for
  `>>` (op_indent_line) and `<<` (op_dedent_line) arms; patched
  parser_clear to zero pending_motion_inclusive (centralised
  Story-2.11 cleanup); extended module-header docstring per AR23.
  Net body delta: ~+13 B.
- `inc/state.inc` — added `pending_motion_inclusive` 1-byte cell
  adjacent to pending_motion_prefix; updated header Public list.

**Modified — planning / status:**
- `_bmad-output/implementation-artifacts/2-11-composed-operator-motion-dw-d-c5w-y3j.md`
  (this file) — tasks/subtasks checkboxes, Dev Agent Record, File List,
  Change Log, Status.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — flipped
  development_status[2-11-composed-operator-motion-dw-d-c5w-y3j] from
  ready-for-dev → review; updated last_updated.
- `_bmad-output/implementation-artifacts/deferred-work.md` — added
  Story 2.11 dev-triage entries (NFR9 overshoot + 3 escalation paths;
  FR45 undo stubs; AC5 line-class divergence; AC9 indent post-cursor
  semantic; motion_G inclusive choice; edits_indent_walk mode/dirty
  flag cells; 3 dropped tests with rationale; `$` filename collision +
  rename; parser_clear centralised cleanup choice).

**New — tests (21 files):**
- `test/cases/edits_dw-deletes-word.asm` (canonical 1)
- `test/cases/edits_dollar-to-end-of-line.asm` (canonical 2 —
  renamed from spec's `edits_d$-to-end-of-line.asm`; sjasmplus
  treats `$` as location-counter symbol)
- `test/cases/edits_c-enters-insert.asm` (canonical 3)
- `test/cases/edits_y3w-yanks-without-modifying.asm` (canonical 4)
- `test/cases/edits_indent-shift.asm` (canonical 5)
- `test/cases/parser_compose-count-op-motion-end-to-end.asm` (canonical 6)
- `test/cases/edits_dl-equals-x.asm`
- `test/cases/edits_dh-from-mid-line.asm`
- `test/cases/edits_db-from-mid-buf.asm`
- `test/cases/edits_dgg-from-line-3.asm`
- `test/cases/edits_d2j-clamps-at-eof.asm`
- `test/cases/edits_dw-no-op-at-eof.asm`
- `test/cases/edits_dw-yank-too-large.asm`
- `test/cases/edits_yw-cursor-unchanged.asm`
- `test/cases/edits_indent-counted-3lines.asm`
- `test/cases/edits_dedent-no-op-no-leading-space.asm`
- `test/cases/edits_dedent-removes-leading-space.asm`
- `test/cases/parser_doubled-operator-routes-to-indent.asm`
- `test/cases/parser_doubled-operator-routes-to-dedent.asm`
- `test/cases/parser_doubled-operator-routes-to-cc.asm`
- `test/cases/motions_compose-entry-saved-by-h.asm`

### Change Log

| Date       | Change | Notes |
|------------|--------|-------|
| 2026-05-16 | Story 2.11 hardware UAT passed | Ant confirmed: "all working well including boundary cases". 12-step UAT script + boundary cases (dw at EOF, d$ on empty line, db from BOF, >> on last-line-no-LF, 5dw clamping at EOF mid-walk) all pass on real MicroBeast. Story flipped from `review` → `done` directly (skipping the code-review gate at Ant's call; code-review may still happen later as cleanup but doesn't block sprint progression to Story 2.12 paste). FR39 + FR40 closed end-to-end. |
| 2026-05-16 | Story 2.11 dev pass — compose layer landed | 21 new tests (6 canonical + 15 additional; 3 dropped with rationale); test count 138 → 159 pass / 1 deliberate-fail; NFR18 byte-identical rebuild verified (sha `e0f31199...`); AR13/AR14/AR15 sweeps clean; DISPATCH_NORMAL_COUNT unchanged at 33. NFR9 overshoots ceiling by 280 B (5400 B / 105.5% of 5120 B) — 3 escalation paths documented in deferred-work.md for Ant + code-review decision (Option A: NFR9 amend [recommended]; Option B: defer indent/dedent; Option C: defer c-operator). All 5 Implementation Questions resolved per recommendations: Q1 full scope; Q2 state.inc; Q3 epic CHAR-class for line-class motions (vi divergence); Q4 restore-to-entry cursor; Q5 motion_G no inclusive flag. FR45 undo STUB for all 6 mutating compose ops; hook sites documented. Hardware UAT (AC11) pending Ant. Status: review. |
| 2026-05-16 | Story 2.11 created from epics line 1337 | Initial draft; status `ready-for-dev`. 13 ACs, 15 tasks, ~22-24 headless tests + 12-step hardware UAT. Architecturally significant cross-cut of Epic 2: wires parser-state machine (Story 1.10) + every motion handler (Stories 2.5-2.7) + yank register (Story 2.10's protocol + first writer of KIND_CHAR) + range-delete (Story 2.10 helpers reused) + INSERT mode entry (Story 2.8) into a single composition layer. Compose mechanism: per-motion entry-time prologue saves cursor to new `motions_compose_entry` scratch cell; every motion's `JP parser_clear` tail patched to `JP edits_compose_or_clear`. Compose tail (new public entry in edits.asm) examines `pending_operator` and routes to one of `op_compose_d` / `op_compose_y` / `op_compose_c` / `op_compose_indent` / `op_compose_dedent` (or JP parser_clear for bare motion). Range derivation via shared `edits_compose_range` helper (computes [start, end) from cursor_offset + motions_compose_entry with backward-motion swap). `pending_motion_inclusive` flag (new 1-B state.inc cell) set by motion_dollar; read + cleared by op_compose_d/y/c to extend range by 1 byte (vi-faithful `d$` inclusive-landing). `edits_copy_to_yank` (Story 2.10) parameterised on kind (A=KIND_CHAR or KIND_LINE) — Story 2.10's op_dd / op_yy callers patched to set A=KIND_LINE before CALL (invariant-preserving). `parser_doubled_operator_stub` extended (parser.asm:502) for `>>` (op_indent_line) and `<<` (op_dedent_line); `cc` doubled-form stays as msg_not_implemented (out of MVP scope). NFR9 projection: post-2.11 ~5193-5343 B — **likely OVER the 5120 B ceiling** by ~73-223 B. AC13 enumerates mitigations (factor line-walk, share yank-refused arm) and escalation paths (NFR9 amend, defer indent/dedent OR `c` to a later story). Implementation Questions section at end of Dev Notes saves 5 decision points for the dev pass / Ant to resolve before dev starts. FR45 undo recording is a STUB for all 6 mutating compose ops (d/c/indent/dedent + indent_line/dedent_line); hook sites documented (BEFORE yank-copy for d/c; BEFORE first per-line op for indent/dedent). op_compose_y NEVER records undo (yank-only). Per-motion compose architecture chosen over central-router architecture for AR23-clean self-documentation + smallest blast radius per handler; `parser_dispatch` IX safety remains OPEN (Story 2.11 architecture does NOT use parser_dispatch as a production caller). AC5 line-class motion divergence: epic spec treats `y3j` / `d2j` as CHAR-class (not vi-faithful LINE-class) — load-bearing per epic; vi-divergence documented in deferred-work.md as Story 3.x / post-MVP polish. |
