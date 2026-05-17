# Story 2.12: Paste (p)

Status: done (code review applied 2026-05-17)

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `p` in NORMAL mode (and counted `Np`) to insert the contents of the yank register at the appropriate position based on `yank_kind`,
so that FR32 is realized and the yank/delete → paste loop closes end-to-end (`yy p`, `dd p`, `dw p`, `y3w p`).

This story is the **second reader** of the yank-register protocol established by Story 2.10 (`dd` / `yy` — first writer of `KIND_LINE`) and extended by Story 2.11 (`dw` / `d$` / `c5w` / `y3j` — first writer of `KIND_CHAR`). `KIND_BLOCK` is reserved for Epic 3 visual-block and is **out of MVP scope** for this story — paste MUST gracefully no-op (silent, or `not yet implemented` per FR50) when `yank_kind == KIND_BLOCK` to avoid corrupting the buffer with a misinterpreted byte stream. Block-paste lands when visual-block (Story 3.5) introduces the first writer of KIND_BLOCK.

Three discriminated paste flavours land here:
- **KIND_CHAR** — insert content **after the cursor**; cursor lands on the **last byte** of the inserted range (vi muscle memory: after `dw p`, cursor is on the last char of the pasted word).
- **KIND_LINE** — insert content as a **new line below** the current line; cursor lands at the **start of the inserted line** (vi muscle memory: after `dd p` or `yy p`, cursor is at the start of the restored / duplicated line — `0` column).
- **KIND_BLOCK** — out of MVP scope per epic spec; silent no-op + `msg_not_implemented` (or silent — implementation choice; pin in Dev Notes).

`p` is the **second reader** of `yank_buffer` / `yank_kind` / `yank_length` (the first reader was `edits_copy_to_yank`'s capacity-check overhead — but that reads `yank_length` only for write-time accounting; this story is the first reader that consumes the **content**). Paste flows through `gapbuf_insert` (Story 1.7's AR14 mutation surface) — N iterations of single-byte insert at cursor, with `gapbuf_insert`'s buffer-full CF=1 surface translating to a **partial-paste truncation** (epic AC: insertion stops at the failure point, status shows `msg_file_too_large`, buffer is consistent).

## Acceptance Criteria

**AC1 — Dispatch binding for `p` in NORMAL mode.**

`src/dispatch.asm` `dispatch_normal` table gains one new entry:
```
DEFB    'p'                         ; 'p' — paste from yank register (FR32, Story 2.12)
DEFW    op_paste
```
Inserted in **sorted-ascending key order between `'o'` (0x6F → `edits_open_below`) and `'v'` (0x76 → `enter_visual_mode`)** — see existing entries at src/dispatch.asm:541-546. The `ASSERT 'p' > 'o'` / `ASSERT 'v' > 'p'` bracket follows the existing MC3 ASSERT pattern. `DISPATCH_NORMAL_COUNT` increments from 33 → 34.

Story 2.10 + 2.11 did not touch dispatch_normal (Story 2.10 added `op_dd` / `op_yy` via the doubled-operator parser stub; Story 2.11 added `>` / `<` operator pairs via the existing parser_handle_operator binding). Story 2.12 is the **first epic-2 story that adds a new dispatch_normal entry** since Story 2.9's `x`.

**State-discipline pin (MC4 + Story 2.5 AC13):** `op_paste` MUST end with `JP parser_clear` (not bare `RET`) so a count from `Np` doesn't leak into the next command. This matches every NORMAL-mode handler post-Story-2.5 (`motion_*`, `op_dd`, `op_yy`, `op_compose_*`, `edits_delete_char`).

**AC2 — `op_paste` entry point + count handling (FR23 counted dispatch).**

New public entry in `src/edits.asm`:
- **In:** A = 'p' (MC4; ignored — dispatch chain consumed the byte). count_accumulator MAY be 0 or non-zero (`Np`).
- **Out:** success — yank content inserted N times; cursor placed per `yank_kind` rule; buffer_dirty = 1; all rows dirty; parser cleared.
  - no-op (empty yank `yank_length == 0`) — buffer + cursor + buffer_dirty unchanged; status shows `nothing to paste` OR silent (pin choice — see AC9); parser cleared.
  - partial-paste (gapbuf_insert returned CF=1 partway) — insertion stops at the failure point; status shows `msg_file_too_large`; what got inserted is preserved (FR52: no silent data loss); buffer consistent + cursor at the post-truncated-content position per `yank_kind`; buffer_dirty = 1; parser cleared.
  - KIND_BLOCK (reserved) — silent no-op OR `msg_not_implemented` (pin choice); buffer unchanged; parser cleared.
- **Trashes:** A, BC, DE, HL, F.
- **Calls:** `motion_apply_count` (reads count_accumulator → BC); `motion_byte_at_logical` (EOF / LF probe for KIND_CHAR cursor-after-cursor placement and KIND_LINE end-of-line walk); `motion_find_line_end` (KIND_LINE: walk to current line end before inserting `\n` + yank content); `gapbuf_insert` (per-byte insertion at cursor); `status_set_message` (empty / overflow / block paths); `edits_dirty_and_redraw` (success tail); `parser_clear` (tail-JP every path).

**Body shape (high level):**
```
op_paste:
    ;; 1. Empty-yank guard.
    LD   HL, (yank_length)
    LD   A, H
    OR   L
    JP   Z, .empty_yank             ; surface msg_nothing_to_paste OR silent; JP parser_clear

    ;; 2. KIND_BLOCK guard (reserved).
    LD   A, (yank_kind)
    CP   KIND_BLOCK
    JP   Z, .block_not_supported    ; surface msg_not_implemented OR silent; JP parser_clear

    ;; 3. Apply count (Np → N iterations).
    CALL motion_apply_count         ; BC = effective count (1 minimum)

    ;; 4. Branch on yank_kind.
    LD   A, (yank_kind)
    CP   KIND_LINE
    JP   Z, .paste_line             ; line-wise body
    ;; Else KIND_CHAR (default — yank_kind defaults to 0 = KIND_CHAR on cold start).
    JP   .paste_char                ; char-wise body
```

The two body branches (`.paste_char` / `.paste_line`) share the **inner per-iteration insert loop** — see AC3 (the shared helper).

**AC3 — `edits_paste_yank_bytes` internal helper (shared inner loop).**

Inner loop: write `yank_length` bytes from `yank_buffer` into the gap buffer via `gapbuf_insert` at cursor_offset. The loop advances cursor implicitly (each `gapbuf_insert` advances cursor by 1 on success). On `gapbuf_insert` CF=1 (buffer-full): the helper aborts the loop and returns CF=1 with HL = bytes-inserted-so-far (so the outer caller can post-place the cursor relative to what actually got pasted, and the surfaced `msg_file_too_large` matches what `gapbuf_insert` itself already wrote to status_buffer).

```
;; edits_paste_yank_bytes
;; In:  (none — reads yank_buffer + yank_length; inserts at cursor_offset)
;; Out: CF=0 on success — yank_length bytes inserted at cursor; cursor advanced by yank_length
;;      CF=1 on overflow — partial insert; HL = bytes successfully inserted (0..yank_length-1);
;;                          status_buffer already holds msg_file_too_large from gapbuf_insert.
;; Trashes: A, BC, DE, HL, F.
;; Calls:   gapbuf_insert.
edits_paste_yank_bytes:
    LD   BC, (yank_length)          ; BC = byte count
    LD   DE, yank_buffer            ; DE = read pointer (physical addr — yank_buffer is a static EQU)
    LD   HL, 0                      ; HL = bytes-inserted counter
.byte_loop:
    LD   A, B
    OR   C
    JR   Z, .done                   ; BC == 0 — full content inserted; CF=0 (success)
    LD   A, (DE)                    ; A = next yank byte
    PUSH BC                         ; gapbuf_insert trashes BC
    PUSH DE                         ; gapbuf_insert trashes DE
    PUSH HL                         ; preserve counter across the call
    CALL gapbuf_insert              ; CF=1 on buffer-full (state unchanged on that byte)
    POP  HL
    POP  DE
    POP  BC
    RET  C                          ; overflow — HL = bytes-inserted-so-far; CF=1 propagates
    INC  HL                         ; one more byte inserted
    INC  DE                         ; advance read pointer
    DEC  BC                         ; decrement remaining
    JR   .byte_loop
.done:
    OR   A                          ; CF=0 (success)
    RET
```

**Critical:** `yank_buffer` is at the **physical address** `GAP_BUFFER_BASE + GAP_BUFFER_MAX` (state.inc:144). It's a static EQU, NOT a logical offset into the gap buffer. The read pointer (DE) walks raw memory via `LD A, (DE)` — no `motion_byte_at_logical` needed (the source is outside the gap-buffer region; SR3 math doesn't apply to yank_buffer reads).

**State-discipline pin:** `gapbuf_insert` advances `cursor_offset` on success — so the cursor "follows" the inserted content automatically. After `edits_paste_yank_bytes` returns CF=0, `cursor_offset` is at `original_cursor + yank_length` (== position just after the inserted content). The outer caller (op_paste's char / line bodies) is responsible for the **final cursor placement** per yank_kind:
- **KIND_CHAR**: cursor = `original_cursor + yank_length - 1` (last byte of inserted range — DEC HL after the loop returns).
- **KIND_LINE**: cursor = `original_cursor` (start of the inserted-below line — the new LF separator went FIRST, so the line content starts where the cursor was BEFORE the paste — see AC5 for the exact mechanism).

**AC4 — KIND_CHAR paste body.**

Semantics (vi-faithful): `p` inserts content **AFTER the cursor**. If cursor is on 'a' in `"abc"` and yank = "XY" (KIND_CHAR), after `p` the buffer is `"aXYbc"` and cursor lands on the **last byte** of the inserted range (= 'Y', offset 2).

Implementation:
```
.paste_char:
    ;; Pre-advance cursor by 1 (vi's "insert AFTER cursor" = "insert AT cursor+1").
    ;; Special case: if cursor is past-EOF OR on the LF byte of a line, do NOT advance
    ;; — vi: `p` on an empty line or at EOF inserts AT cursor (not past it) so the
    ;; content lands within / continues the current line.
    LD   HL, (cursor_offset)
    CALL motion_byte_at_logical     ; A = byte at cursor; CF=1 if past EOF
    JR   C, .pc_no_advance          ; past EOF — insert AT cursor
    CP   0x0A
    JR   Z, .pc_no_advance          ; on LF — insert AT cursor (vi: paste before LF)
    INC  HL
    LD   (cursor_offset), HL        ; cursor := cursor + 1 (insert-after position)
.pc_no_advance:

    ;; Counted: BC = repeat count from motion_apply_count.
    ;; Outer loop: insert content BC times.
.pc_count_loop:
    PUSH BC                         ; [count]
    CALL edits_paste_yank_bytes     ; insert one copy of yank_length bytes; CF=1 on overflow
    POP  BC                         ; restore count
    JR   C, .pc_partial             ; overflow — bail with partial content
    DEC  BC
    LD   A, B
    OR   C
    JR   NZ, .pc_count_loop

    ;; All N copies inserted. cursor_offset = original_cursor (+1 if advanced) + N*yank_length.
    ;; Move cursor back by 1 so it lands on the LAST byte of the inserted range.
    LD   HL, (cursor_offset)
    DEC  HL
    LD   (cursor_offset), HL
    JP   .commit                    ; CALL edits_dirty_and_redraw ; JP parser_clear

.pc_partial:
    ;; Partial paste. cursor_offset = wherever gapbuf_insert left it (cursor advanced
    ;; per successfully-inserted bytes, NOT for the failing byte).
    ;; Place cursor on the LAST inserted byte if at least 1 byte landed; otherwise leave it.
    ;; Detection: was the cursor advanced beyond its pre-paste-iteration start?
    ;; Simplest: if cursor > pre_paste_cursor, DEC cursor. Otherwise leave it.
    ;; (msg_file_too_large already in status_buffer from gapbuf_insert.)
    JP   .commit
```

**Cursor placement edge cases** (pin in tests per AC10):
- Empty buffer + KIND_CHAR yank: cursor_offset is 0; pre-paste motion_byte_at_logical returns CF=1 (past EOF); no advance. After paste, cursor_offset = yank_length - 1 (last byte of inserted range). DEC HL is safe (yank_length ≥ 1 by AC2 empty-yank guard).
- KIND_CHAR yank on an empty line (cursor on LF): no advance; insertion happens BEFORE the LF; cursor lands on last inserted byte. Empty line becomes a line-with-content.
- 0-byte yank: guarded by AC2 empty-yank check before this branch is reached.

**AC5 — KIND_LINE paste body.**

Semantics (vi-faithful): line-paste inserts content as a **new line below** the current line. If cursor is on line 2 of `"a\nb\nc"` (cursor=2, on 'b') and yank = "X\n" (KIND_LINE, yank_length=2), after `p` the buffer is `"a\nb\nX\nc"` and cursor lands at the **start of the inserted line** (= 'X', offset 4).

The mechanism: paste an LF byte (if not already at start-of-line — i.e., move cursor to line-end first, insert LF, then insert yank content). But that produces an extra LF for yanks that ALREADY end in LF (the common case for `yy` — Story 2.10 AC2's yank-content for `dd` / `yy` always ends in LF for non-last-line yanks).

**Cleaner mechanism — exploit the fact that KIND_LINE yank content already ends in LF (Story 2.10 AC2 invariant for non-last-line yanks):**

1. **Move cursor to end of current line** (the LF byte position, or file_length if last-line-no-LF). Use `motion_find_line_end` from the current cursor.
2. **If at LF (not past-EOF):** advance cursor by 1 (insert position = AFTER the current line's LF = start of next line). The yank content (ending in LF) inserts as a complete new line. Cursor placement: at the cursor position BEFORE the loop = start of the inserted line.
3. **If past-EOF (last-line-no-LF case):** insert an LF FIRST (to terminate the current last line); then insert yank content. **Special case for the Story 2.10 AC2 leading-LF yank**: if `yank_buffer[0] == 0x0A` (the `dd` on last-line-no-LF case yanked content starts with the consumed cross-line LF), the yank content ALREADY supplies the separator LF; DO NOT insert an extra LF. Detection: peek `yank_buffer[0]` before the explicit-LF insert.

**Pin choice for the dev pass (see Implementation Questions):** the simpler "always insert LF if past-EOF; do NOT special-case the leading-LF yank" is acceptable as a minimum-viable choice — the user sees an extra blank line in the corner-case "dd the last line of a no-LF file → p" sequence, but it's recoverable via undo (Story 2.13) and vi muscle memory's accuracy on this corner is low. Document the trade-off; both choices satisfy FR32 in spirit.

Implementation skeleton:
```
.paste_line:
    ;; Save entry cursor for post-paste placement (start of inserted line).
    LD   HL, (cursor_offset)
    PUSH HL                         ; [entry_cursor]

    ;; Walk to end-of-line.
    CALL motion_find_line_end       ; HL = LF offset OR file_length (no-LF case)
    CALL motion_byte_at_logical     ; A = byte at HL; CF=1 if past EOF
    JR   C, .pl_past_eof
    ;; HL is on LF. Advance by 1 for insert-after-LF position.
    INC  HL
    LD   (cursor_offset), HL
    JR   .pl_advance_done
.pl_past_eof:
    ;; Last-line-no-LF case. Insert an LF FIRST (terminate the current last line).
    LD   (cursor_offset), HL        ; cursor = file_length (insert at EOF)
    LD   A, 0x0A
    CALL gapbuf_insert              ; cursor advances to file_length + 1 on success; CF=1 on full
    JR   C, .pl_overflow_no_content ; never got to insert yank content
.pl_advance_done:

    ;; Outer count loop: insert N copies of yank content.
    CALL motion_apply_count         ; BC = effective count
.pl_count_loop:
    PUSH BC
    CALL edits_paste_yank_bytes     ; CF=1 on overflow
    POP  BC
    JR   C, .pl_partial
    DEC  BC
    LD   A, B
    OR   C
    JR   NZ, .pl_count_loop

    ;; All N copies inserted. Place cursor at start-of-inserted-line.
    POP  HL                         ; HL = entry_cursor
    ;; If we walked to LF and advanced, the inserted line starts at (entry_cursor's
    ;; line's end + 1) which is the cursor position BEFORE the loop. Restore that:
    ;; we need the START of the first inserted line.
    ;; Equivalent: walk forward from entry_cursor to next LF + 1 (or file_length + 1
    ;; for the past-EOF case where we inserted an LF ourselves).
    ;; Simplest: re-do motion_find_line_end from entry_cursor, then +1.
    CALL motion_find_line_end       ; HL = LF offset (or file_length — but we just inserted past it)
    INC  HL
    LD   (cursor_offset), HL
    JP   .commit

.pl_partial:
    ;; Partial paste. Place cursor at start-of-inserted-line (same computation,
    ;; even if only some content landed — the start position is still the first
    ;; byte after the current line's LF).
    POP  HL                         ; discard entry_cursor (not needed for partial)
    ;; cursor_offset already advanced by what got inserted; clamp to start-of-inserted-line
    ;; by walking back to the last-LF position via motion_find_line_start.
    LD   HL, (cursor_offset)
    CALL motion_find_line_start
    LD   (cursor_offset), HL
    JP   .commit

.pl_overflow_no_content:
    POP  HL                         ; discard entry_cursor
    ;; cursor advanced by 0 or 1 (depending on whether the explicit LF made it in).
    ;; Whatever happened, cursor is consistent with the partial state; status_buffer
    ;; already holds msg_file_too_large.
    JP   .commit
```

**Pin choices for the dev pass to resolve / refine** (per Implementation Questions): the partial-paste cursor placement for KIND_LINE is a judgment call; document the chosen semantic in the contract block. The simple "cursor at start of inserted (or partial) line" choice is recommended.

**AC6 — Empty-yank, KIND_BLOCK, and zero-yank-length edge cases.**

- **Empty yank (`yank_length == 0`)**: no-op. AC2's guard handles this before any branch. The status surface choice — `msg_nothing_to_paste` (new string) OR silent — is a Dev Notes choice (see Implementation Questions). Recommendation: **silent** (matches vi convention; the user sees no buffer change and infers the cause; saves the ~17-25 B of a new status string). On boot, `init_cold_start`'s LDIR zero-fill leaves `yank_length = 0` and `yank_kind = KIND_CHAR (0)` — so the very first `p` after boot lands in this branch.
- **KIND_BLOCK (`yank_kind == 2`)**: reserved for Epic 3 visual-block. Story 2.12 MUST guard for this and treat as no-op. Surface: `msg_not_implemented` (existing string at statusln.asm:224, reused) OR silent. Recommendation: **`msg_not_implemented`** (gives the user a signal that the feature is reserved; cost is 0 B — the string already exists). The guard cost is ~6 B (LD A,(yank_kind) ; CP KIND_BLOCK ; JP Z, ...).
- **Other yank_kind values (e.g. corrupted state)**: pre-init residue in `yank_kind` is impossible (init zeroes it). A future bug that scribbles a non-0/1/2 value into yank_kind is implausible — yank_kind only has three writers (op_dd, op_yy, op_compose_d/y/c via edits_copy_to_yank). Defensive `else → fall to KIND_CHAR` is the safest interpretation (matches the AC2 body shape). Document this in op_paste's contract block.

**AC7 — Counted paste (`Np` — e.g. `3p`).**

`3p` after `yy` → 3 copies of the yanked line. `3p` after `dw` → 3 copies of the yanked word string. The count is consumed in `op_paste` via `motion_apply_count` (same pattern as `5dd` in Story 2.10 — see Story 2.10 AC2 `motion_apply_count` use). count_accumulator is preserved across the dispatch_normal binding of `'p'` (parser_handle_digit accumulates; dispatch_normal binding fires; op_paste reads count via motion_apply_count BEFORE the tail-JP parser_clear).

**State-read-before-clear discipline (Story 2.10 deferred-work.md:93-95 + Story 2.11 AC1):** `op_paste` MUST read count_accumulator (via motion_apply_count) BEFORE any tail-JP parser_clear. A future "consistency cleanup" that hoisted parser_clear into a common prelude would silently break `3p`.

For KIND_CHAR: insertion is `N × yank_length` bytes — cursor at insert-after position; N inner copies of the yank content; final cursor on the last byte of the FULL (Nth copy's last byte) inserted range.

For KIND_LINE: insertion is `N × yank_length` bytes — the first iteration walks to end-of-line + handles the past-EOF LF-insert; subsequent iterations just continue inserting at cursor (which is now mid-yanked-content). Cursor lands at the start of the FIRST inserted line (matches vi: cursor goes to the start of the pasted content's first line).

For KIND_BLOCK: AC6 guard fires; count is irrelevant (no-op).

**Edge case (counted overflow):** if the Nth iteration overflows mid-content, the partial-paste path engages — preserve what's in (truncated at the failure point per epic AC), status `msg_file_too_large`, parser cleared.

**AC8 — Partial-paste (buffer-overflow) handling per FR52 (no silent data loss).**

When `gapbuf_insert` returns CF=1 mid-paste (buffer is full):
1. **Insertion stops** at the failure point. The byte that didn't fit is NOT in the buffer; everything before it IS.
2. **`msg_file_too_large`** is already in status_buffer (gapbuf_insert called status_set_message before returning CF=1 — see src/gapbuf.asm:122-128). op_paste does NOT re-surface the message.
3. **`buffer_dirty := 1`** (some content DID land — see Story 2.10's "dd still proceeds with the deletion on yank-too-large refusal" precedent: partial state changes set buffer_dirty). EXCEPTION: if zero bytes landed (the very first gapbuf_insert call returned CF=1), buffer_dirty is **not** newly written — but the state was already buffer_dirty=1 if the buffer was non-empty (a paste into a full buffer means the buffer's been touched before). Practical effect: leave buffer_dirty handling to `edits_dirty_and_redraw` (it always sets buffer_dirty=1); if zero bytes landed, calling `edits_dirty_and_redraw` is mildly wasteful (re-sets a flag that was already 1, re-paints rows that didn't change) but is correct.
4. **Cursor placement on partial paste**: per AC4 / AC5 above. The simplest behaviour is "place cursor as if the paste succeeded for what got inserted" — i.e., apply the per-kind cursor rule to the truncated content. KIND_CHAR: cursor on last successfully-inserted byte. KIND_LINE: cursor at start of partial inserted line.
5. **Undo recording** (FR45, STUB in this story — see AC11): the partial-paste's undo entry would record only what got inserted, not what didn't. Story 2.13's hook site is documented in `op_paste`'s contract block.

**AC9 — Status surface choices (pin in Dev Notes; new strings minimised per NFR9 pressure).**

- **Empty yank**: silent (recommended; saves ~25 B of `msg_nothing_to_paste` + 1 byte status_dirty write per refusal). OR `msg_nothing_to_paste` if Ant prefers the explicit signal. Pin choice in op_paste's contract block + Implementation Questions resolution.
- **KIND_BLOCK reserved**: `msg_not_implemented` (existing string; 0 B cost). OR silent. Pin choice.
- **Partial paste / buffer-full**: `msg_file_too_large` — automatic (gapbuf_insert sets it). op_paste does NOT touch status_buffer for this path.
- **Successful paste**: silent (consistent with op_dd / op_yy / op_compose_d / op_compose_y / op_compose_c / op_compose_indent / op_compose_dedent — no success message). The visible buffer change IS the success signal.

**AC10 — Headless tests (all under `test/cases/edits_*.asm` + `test/cases/parser_*.asm`).**

**Canonical (epic spec line 1430):**

- `edits_p-after-yy.asm` — Pre-load `"abc\ndef\n"` (8 B), cursor=0 (on 'a', line 1). Pre-seed yank: yank_kind=KIND_LINE, yank_length=4, yank_buffer[0..3]="abc\n" (simulate prior `yy`). count_accumulator=0. CALL `op_paste`. Assert: buffer = `"abc\nabc\ndef\n"` (12 B); cursor = 4 (start of the new inserted line — duplicated "abc\n"); buffer_dirty=1; yank register UNCHANGED (paste is read-only on yank); parser cleared.

- `edits_p-after-dd.asm` — Pre-load `"def\n"` (4 B), cursor=0. Pre-seed yank: yank_kind=KIND_LINE, yank_length=4, yank_buffer[0..3]="abc\n" (simulate `dd` of a prior line; buffer is what's left after `dd`). count_accumulator=0. CALL `op_paste`. Assert: buffer = `"def\nabc\n"` (8 B); cursor = 4 (start of pasted "abc\n" line); buffer_dirty=1; parser cleared. (Pins: dd → p restores the deleted line BELOW the current line — vi-faithful.)

- `edits_p-after-dw.asm` — Pre-load `"abc"` (3 B), cursor=0 (on 'a'). Pre-seed yank: yank_kind=KIND_CHAR, yank_length=4, yank_buffer[0..3]="foo " (simulate prior `dw` on `"foo abc"` — yanked "foo "). count_accumulator=0. CALL `op_paste`. Assert: buffer = `"afoo bc"` (7 B); cursor = 4 (on the space — last byte of inserted "foo "); buffer_dirty=1; parser cleared. (Pins: dw → p pastes the word AFTER cursor; cursor on last inserted byte.)

- `edits_p-empty-yank.asm` — Pre-load `"abc"` (3 B), cursor=1 (on 'b'). Pre-seed yank: yank_kind=KIND_CHAR (or any; AC6 empty-yank guard fires before kind branch), yank_length=0, yank_buffer left uninitialised. CALL `op_paste`. Assert: buffer UNCHANGED (= "abc"); cursor=1 (unchanged); buffer_dirty UNCHANGED from pre-seed (0); status_buffer EITHER empty (silent choice) OR contains "nothing to paste" (msg_nothing_to_paste choice) — pin whichever the dev pass picks via the status_buffer assertion; parser cleared.

- `edits_3p-counted.asm` — Pre-load `"a"` (1 B), cursor=0. Pre-seed yank: yank_kind=KIND_CHAR, yank_length=1, yank_buffer[0]="b". count_accumulator=3 (simulating prior `3` + `p`). CALL `op_paste`. Assert: buffer = `"abbb"` (4 B); cursor=3 (on the last 'b' — last byte of inserted range); buffer_dirty=1; count_accumulator=0 (cleared by parser_clear); parser cleared. (Pins: counted paste runs N inner copies; cursor on the last byte of the FULL inserted range.)

- `edits_p-fills-buffer.asm` — Pre-load a buffer at near-capacity (e.g. GAP_BUFFER_MAX - 2 = 32766 B of payload 'A' starting at offset 0). Pre-seed yank: yank_kind=KIND_CHAR, yank_length=10, yank_buffer[0..9]="XXXXXXXXXX". cursor=0. CALL `op_paste`. Trace: pre-paste advance moves cursor 0 → 1 (cursor was on 'A', not LF, not past EOF); pre_cursor=1. Iter 1 of the count loop calls edits_paste_yank_bytes; it inserts the first X at offset 1 (cursor→2) and the second X at offset 2 (cursor→3) before the 3rd gapbuf_insert returns CF=1 (buffer reaches GAP_BUFFER_MAX). Helper returns CF=1 with HL=2 (bytes inserted). `.pc_partial`: cursor (3) - pre_cursor (1) = 2, nonzero → `.pc_partial_dec` → DEC cursor → 2. Assert: buffer is at GAP_BUFFER_MAX (full — 32768 B); 8 of the 10 yank bytes did NOT make it in; status_buffer contains "file too large" prefix; status_dirty=1; buffer_dirty=1; **cursor=2 (last successfully-inserted X — at logical position 2; original 'A' at 0, first inserted X at 1, second inserted X at 2, payload-shifted bytes at 3+).** Parser cleared. (Pins: AC8 partial-paste; FR52 no silent data loss; KIND_CHAR `.pc_partial_dec` arm.)

**Additional (edge + dispatch coverage):**

- `edits_p-into-empty-buffer.asm` — Pre-load empty buffer (`gapbuf_init`; file_length=0), cursor=0. Pre-seed yank: yank_kind=KIND_CHAR, yank_length=3, yank_buffer="xyz". CALL `op_paste`. Assert: buffer = `"xyz"` (3 B); cursor=2 (on 'z' — last byte); buffer_dirty=1. (Pins: empty-buffer + KIND_CHAR — past-EOF pre-paste probe; no advance; standard placement.)

- `edits_p-at-eof-no-lf.asm` — Pre-load `"abc"` (3 B, no trailing LF), cursor=2 (on 'c' — last printable). Pre-seed yank: yank_kind=KIND_CHAR, yank_length=2, yank_buffer="XY". CALL `op_paste`. Assert: buffer = `"abcXY"` (5 B — pasted AFTER 'c' since 'c' is not LF and not past-EOF; cursor advanced from 2 → 3 before paste); cursor=4 (on 'Y'); buffer_dirty=1. (Pins: AC4 cursor-advance branch when cursor is on a printable byte.)

- `edits_p-on-lf.asm` — Pre-load `"abc\ndef"` (7 B), cursor=3 (on the LF byte). Pre-seed yank: yank_kind=KIND_CHAR, yank_length=2, yank_buffer="XY". CALL `op_paste`. Assert: buffer = `"abcXY\ndef"` (9 B — no advance since cursor is on LF; insertion happens AT cursor, BEFORE the LF); cursor=4 (on 'Y' — last inserted byte); buffer_dirty=1. (Pins: AC4 `cursor on LF → no advance` branch.)

- `edits_p-line-with-no-trailing-lf.asm` — Pre-load `"abc"` (3 B, no LF). Pre-seed yank: yank_kind=KIND_LINE, yank_length=4, yank_buffer="xyz\n". cursor=1 (on 'b'). CALL `op_paste`. Assert: buffer = `"abc\nxyz\n"` (8 B — past-EOF LF-insert path: motion_find_line_end returns file_length=3; motion_byte_at_logical returns CF=1; insert explicit LF at offset 3 (cursor → 4); then insert yank content "xyz\n" at offset 4 (cursor → 8); start-of-inserted-line cursor = 4). cursor=4 (start of inserted "xyz" line); buffer_dirty=1. (Pins: AC5 past-EOF LF-insert path.)

- `edits_p-counted-line.asm` — Pre-load `"a\n"` (2 B), cursor=0. Pre-seed yank: yank_kind=KIND_LINE, yank_length=2, yank_buffer="b\n". count_accumulator=2. CALL `op_paste`. Assert: buffer = `"a\nb\nb\n"` (6 B — 2 copies of "b\n" inserted below "a\n"); cursor=2 (start of FIRST inserted line — first 'b'); buffer_dirty=1; count_accumulator=0; parser cleared. (Pins: AC7 counted line paste; cursor at start of FIRST inserted line.)

- `edits_p-kind-block-noop.asm` — Pre-load `"abc"`. Pre-seed yank: yank_kind=KIND_BLOCK, yank_length=2, yank_buffer="XY". cursor=0. CALL `op_paste`. Assert: buffer UNCHANGED; cursor=0 (unchanged); buffer_dirty UNCHANGED from pre-seed (0); status_buffer contains "not yet implemented" prefix (or empty if silent choice — pin whichever); parser cleared. (Pins: AC6 KIND_BLOCK guard.)

- `edits_p-after-y3w.asm` — Pre-load `"hello world"` (11 B), cursor=0. Pre-seed yank: yank_kind=KIND_CHAR, yank_length=6, yank_buffer="hello " (simulate prior y3w yanking "hello " — would be y2w actually for 2 word-walks; pick the realistic yank). count_accumulator=0. CALL `op_paste`. Assert: buffer = `"hhello ello world"` (17 B — yank "hello " inserted after cursor=0 → cursor advances to 1; 6-byte insert; final cursor=6 on the space); buffer_dirty=1. (Pins: KIND_CHAR paste after a Story-2.11 y+motion writer.)

- `parser_p-dispatch.asm` — drive the full parser chain: pre-load `"abc"`, mode=MODE_NORMAL, cursor=0. Pre-seed yank: yank_kind=KIND_CHAR, yank_length=1, yank_buffer="X". CALL `dispatch_key` with HL=`dispatch_normal`, B=DISPATCH_NORMAL_COUNT, A='p'. Assert: dispatch routes to op_paste; buffer = `"aXbc"` (4 B); cursor=1 (on 'X' — last inserted byte); buffer_dirty=1; parser cleared. (Pins: AC1 dispatch wiring.)

- `parser_3p-dispatch.asm` — drive the full parser chain with a count: pre-load `"a"`, mode=MODE_NORMAL, cursor=0. Pre-seed yank: yank_kind=KIND_CHAR, yank_length=1, yank_buffer="b". CALL parser_handle_digit with A='3'; CALL dispatch_key with A='p'. Assert: buffer = `"abbb"`; cursor=3 (on last 'b'); count_accumulator=0 (consumed); parser cleared. (Pins: counted-`Np` end-to-end through the parser chain.)

**Test count target: 6 canonical (epic line 1430) + ~8 additional = ~14 new tests.** Sentinel allocation 0x90..0x9D per test (next free band after Story 2.11's 0x80..0x87 + the 5 additional sentinels Story 2.11 consumed; verify by grepping test/cases for `EQU 0x8` and pick the lowest unused).

**AC11 — FR45 undo recording STUB (Story 2.13 hook site documented).**

Per epic AC line 1420-1422 + epic AC line 1440 ("every mutating handler in stories 2.8-2.12") + Story 2.10 / 2.11 FR45 stub pattern:

- `op_paste` does NOT write to `undo_buffer` in Story 2.12. The FR45 stub.
- **Hook site for Story 2.13**: BEFORE the first `gapbuf_insert` call in `edits_paste_yank_bytes`. At that point: `cursor_offset` holds the **insertion start** (the position the paste will land at, after the AC4 / AC5 pre-paste cursor adjustments); `yank_length` holds the byte count Story 2.13's `undo_record(KIND_INSERT, start, length)` needs to inverse-delete on undo. The inverse op is a range-delete of `[start, start + N*yank_length)` — Story 2.10's `edits_range_delete` is the natural call site for the undo replay.
- **Partial-paste interaction**: if Story 2.13's undo_record is hooked BEFORE the loop, it records the FULL intended insert length (`N * yank_length`). On partial paste, this would over-record. The clean shape is to hook the undo_record at AFTER the loop completes (success or partial) with the actual bytes-inserted count — which is `cursor_offset - pre_paste_cursor`. Document both shapes; Story 2.13 picks the implementation.
- Document the hook site in `op_paste`'s contract block + in `deferred-work.md`'s Task 12 housekeeping section per the Story 2.10 / 2.11 pattern.

`op_paste` is the **5th mutating handler with an FR45 stub** (after op_dd, op_compose_d, op_compose_c, op_compose_indent, op_compose_dedent — Story 2.11 added 5; this story adds 1; Story 2.13 will wire all of them).

**AC12 — Build invariants (NFR9, NFR18, AR sweeps).**

- `make all` followed by `make clean && make all` produces a byte-identical `vibe.com` (NFR18).
- `make test` from a fresh `make clean && make test` is green (post-2.11 baseline 159 pass / 1 deliberate-fail; post-2.12 ~173 pass / 1 fail; ~14 new tests).
- AR13 / AR14 / AR15 grep sweeps against `src/edits.asm` clean (op_paste adds 1 new gapbuf_insert caller — `gapbuf_insert` is the AR14 mutation surface; the call is AR14-compliant). The `CALL gapbuf_insert` count in edits.asm grows: was 5 code sites (edits_open_below at 412, edits_open_above at 453, edits_insert_literal at 578, edits_insert_newline at 697, edits_indent_walk at 1774); becomes 6 code sites (+ the new edits_paste_yank_bytes inner loop).
- AR25 INCLUDE chain in `src/vibe.asm` is unchanged (`statusln → gapbuf → render → dispatch → parser → motions → edits → exline → fileio`). `op_paste` is forward-referenced from dispatch.asm; resolved by sjasmplus's two-pass model (dispatch.asm INCLUDEs before edits.asm).
- `dispatch_normal` count grows 33 → 34 (the new `'p'` entry). The MC3 binary-search dispatch cost is unchanged in practice — worst-case 6 iterations was for 64 entries; 34 entries is still 6 iterations worst case. NFR3 budget unaffected.
- `dispatch_insert` / `dispatch_command` / `dispatch_visual` unchanged.

- **NFR9 projection:** post-2.11 footprint = 5400 B (~105.5% of 5120 B / **OVER the ceiling by 280 B already**). Story 2.12 adds:
  - **`op_paste`** body (~80-130 B — count-apply + empty-yank guard + KIND_BLOCK guard + KIND_CHAR + KIND_LINE branch bodies + partial-paste cursor handling + commit tail). The two branches share `edits_paste_yank_bytes` (the inner insert loop) so per-branch body is ~30-50 B excluding the shared loop.
  - **`edits_paste_yank_bytes`** helper (~25-35 B — single inner loop with PUSH/POP BC + DE + HL bracketing around gapbuf_insert).
  - **dispatch_normal `'p'` entry** (+3 B — 1 byte DEFB 'p' + 2 byte DEFW op_paste).
  - **NEW status string `msg_nothing_to_paste`** if chosen (+~17 B for the string + ~5 B for the call site). The silent choice saves these ~22 B. **Recommendation: silent** (NFR9 pressure is real; vi's silent-no-prior-yank convention is acceptable).
  - **Net delta projection: ~110-170 B without msg_nothing_to_paste, ~130-200 B with it.** Post-2.12 footprint: **5510-5600 B** if silent / **5530-5600 B** if msg_nothing_to_paste added. **OVER the 5120 B ceiling by 390-480 B (~7.6-9.4% over).**
  - **NFR9 amend status**: Story 2.11 closed at 5400 B / 105.5% (280 B over). The Option A formal NFR9 amend (raise ceiling to e.g. 5632 B) was recommended by Story 2.11's dev pass but never landed (deferred-work.md flags this as an OPEN question for a future story or formal NFR9 amend). **Story 2.12 inherits the overshoot AND extends it.** Three escalation paths:
    - **Option A (recommended) — Formal NFR9 amend to ~5632 B or ~5760 B.** Update PRD + architecture in the same places Story 2.10 / 2.6 amends touched (§ Resource Consumption, § code budget paragraph, § Listing/symbol size-audit caption). Cleanest path — keeps FR32 closed end-to-end and the paste flavours all land. The TPA fit (NFR10) holds — static_end + GAP_BUFFER_MAX + YANK_BUFFER_SIZE is well under 0xD800; another ~640 B of code budget is mathematically free.
    - **Option B — Defer KIND_LINE paste body to a sub-story (`2.12a`?).** Save ~30-50 B by shipping KIND_CHAR + KIND_BLOCK paste only. But epic AC line 1399-1400 + the canonical test `edits_p-after-yy.asm` are load-bearing — `yy p` is the muscle-memory hot path. Strongly recommend AGAINST.
    - **Option C — Drop the explicit-LF-on-past-EOF case in AC5.** Treat last-line-no-LF paste as a documented sharp edge (cursor lands on the last char of inserted content, no extra LF; user gets a continuation of the last line instead of a new line). Save ~15-25 B. Acceptable if the corner-case behaviour is documented in deferred-work.md as a vi-divergence. Recommended **secondary fallback** if Option A is rejected.

  **Decision: ASK ANT** before dev starts — Option A is the recommended path; Options B/C are fallbacks if Ant wants to defer the NFR9 amend further. Same shape as the Story 2.11 Option A/B/C decision (which Ant flipped to `done` directly without resolving in 2.11 — the 5400 B overshoot has been carried forward as an open question).

- **`buffer_dirty` write count:** Story 2.12 adds 1 success-path writer (op_paste's tail via `edits_dirty_and_redraw`). The partial-paste path also goes through `edits_dirty_and_redraw` (some bytes did land; FR52 no-silent-data-loss).

- **Yank register write count:** Story 2.12 adds 0 writers. **`op_paste` is the second non-trivial READER of yank_buffer / yank_kind / yank_length** (after `edits_copy_to_yank`'s write-time accounting; this is the first reader of the **content** at `yank_buffer`).

**AC13 — Hardware UAT on real MicroBeast (deferred to Ant — same pattern as Stories 2.1-2.11).**

The dev MUST NOT mark this story `done` without confirmed hardware UAT by Ant. Hardware UAT script (12 steps; covers the load-bearing user journeys for FR32):

1. **Pre-state:** boot fresh, no prior `vibe` invocation. Push `vibe.com` to the MicroBeast via SLIDE / `make push`.
2. **`vibe newgame.fs`** (or any pre-existing multi-line file). Status confirms `loaded` count + mode `-- normal --` + cursor at offset 0. Hit `$a` to land cursor at EOF (per memory: post-`:e` cursor lands at offset 0 — vi-faithful — so `i` from BOF inserts BEFORE existing content; use `$a` to append at EOF).
3. **`yy` then `p`** on any line — the line gets duplicated below. Cursor at start of the duplicated line. Status shows no error. (Pins `yy p` — the canonical line-yank/paste loop.)
4. **`yy` then `3p`** on any line — the line gets duplicated 3× below. Cursor at start of the FIRST duplicated line. (Pins counted line paste.)
5. **`dd`** to delete a line; **`j`** to move down a line; **`p`** to paste the deleted line below current cursor — the deleted line lands one line below the current. Cursor at start of pasted line. (Pins `dd p` — the canonical delete/restore loop.)
6. **`dw`** on a word; navigate to another position; **`p`** — the word gets pasted AFTER cursor. Cursor on the last character of the pasted word. (Pins `dw p` — the canonical char-yank/paste loop.)
7. **`y3w`** (yank 3 words char-wise per Story 2.11 AC5); navigate to another position; **`p`** — the 3-word range pastes AFTER cursor. (Pins `y3w p` — Story 2.11 + 2.12 interop.)
8. **`p` with no prior yank** (fresh boot, no yank action yet) — silent no-op OR `nothing to paste` banner per the pin choice. Buffer unchanged. (Pins AC6 empty-yank.)
9. **Multiple `p` in succession after one `yy`** — the yank register holds across the pastes; each `p` duplicates the same line. (Pins: paste does NOT consume the yank register; subsequent pastes work.)
10. **`yy` then move to last line then `p`** — the last line gets a copy inserted below it (the "paste below current line" semantic — covers the past-EOF / last-line-no-LF AC5 path).
11. **`:w`** — file saves; status confirms bytes written + `buffer_dirty := 0`. Confirm the paste content persisted to disk.
12. **`:q`** — clean quit. **`vibe newgame.fs`** to re-launch; confirm the pasted content survived save+reload.

Hardware UAT also looks for regressions: motion in NORMAL (Stories 2.5-2.7) still works; ex-line `:w` / `:q` / `:e` still work (2.1-2.4); INSERT mode (2.8) + `x` (2.9) + `dd` / `yy` (2.10) + operator+motion compose (2.11) all still work.

**Boundary cases worth Ant's verification on hardware** (consolidated from headless tests — Ant may compress to time available):
- `p` on an empty line (AC4 LF-no-advance branch).
- `p` into a near-full buffer (AC8 partial-paste; check status banner shows `file too large` and what got pasted is preserved).
- `dd` the last line of a no-trailing-LF file, then `p` — the AC5 last-line-no-LF + leading-LF-yank corner. Document what the user sees (per the chosen Option A/B/C).
- `3p` of a large yank (e.g. `yy` a long line, then `3p`) — counted line paste; verify all 3 copies land.

## Tasks / Subtasks

- [x] **Task 1: Wire `'p'` in `dispatch_normal` table** (AC1).
  - [x] Sub 1.1: In `src/dispatch.asm`, add the `'p'` entry between `'o'` (line 542) and `'v'` (line 545). Use the existing `ASSERT 'p' > 'o' ; DEFB 'p' ; DEFW op_paste` shape. Add the corresponding `ASSERT 'v' > 'p'` (or update the existing `ASSERT 'v' > 'o'` to `ASSERT 'v' > 'p'`). Verify `DISPATCH_NORMAL_COUNT` auto-recomputes via the `$ - .entries / 3` math (no manual count update needed).
  - [x] Sub 1.2: Add a `;; 'p' — paste from yank register (FR32, Story 2.12)` doc-comment to match the sibling-entry comment style.

- [x] **Task 2: Add `edits_paste_yank_bytes` internal helper** (AC3).
  - [x] Sub 2.1: In `src/edits.asm`, add a new `;; --- Internal helper: edits_paste_yank_bytes (Story 2.12) ---` block adjacent to the existing `edits_copy_to_yank` / `edits_range_delete` helpers (Story 2.10 — around src/edits.asm:899). Landed at src/edits.asm:1854 (block placed BEFORE the module-local scratch cells; storage stays at file-end).
  - [x] Sub 2.2: Implement per the AC3 pseudocode: read `yank_buffer` directly via `LD A, (DE)` (yank_buffer is a static EQU — physical address); per-byte `gapbuf_insert` calls; CF=1 abort with HL = bytes-inserted-so-far; CF=0 success with HL = yank_length.
  - [x] Sub 2.3: Per-entry contract block per AR23 — In: (none; reads state). Out: CF=0 success / CF=1 overflow with HL = bytes inserted. Trashes: A, BC, DE, HL, F. Calls: gapbuf_insert.

- [x] **Task 3: Implement `op_paste` body** (AC2, AC4, AC5, AC6, AC7, AC8).
  - [x] Sub 3.1: In `src/edits.asm`, add a new `;; ============ Public entry: op_paste (FR32; Story 2.12) ============` block at the end of the file (after the Story 2.11 compose layer). Place it adjacent to `op_dd` / `op_yy` for the natural reader/writer co-location. Landed at src/edits.asm:1904 (placed after edits_paste_yank_bytes; together they precede the module-local scratch block).
  - [x] Sub 3.2: Per-entry contract block per AR23 — In: A='p' (ignored, MC4). count_accumulator MAY be 0 or non-zero. yank_kind / yank_length / yank_buffer hold the most recent yank state. Out: success — N×yank_length bytes inserted; cursor per kind rule; buffer_dirty=1; parser cleared. Empty-yank — no-op + optional status + parser cleared. KIND_BLOCK — no-op + optional status + parser cleared. Partial — bytes-so-far inserted + msg_file_too_large + cursor per kind rule + buffer_dirty=1 + parser cleared. Trashes: A, BC, DE, HL, F. Calls: motion_apply_count, motion_byte_at_logical, motion_find_line_end, motion_find_line_start, gapbuf_insert (via edits_paste_yank_bytes and the KIND_LINE explicit-LF prelude), edits_dirty_and_redraw (success/partial tail), parser_clear (tail-JP every path).
  - [x] Sub 3.3: Body composition per AC2:
    1. Empty-yank guard (yank_length == 0): JP parser_clear directly (silent choice — Q2 pin).
    2. KIND_BLOCK guard (yank_kind == KIND_BLOCK = 2): JP parser_clear directly (silent choice — Q3 pin).
    3. Call motion_apply_count → BC = effective count.
    4. Branch on yank_kind: KIND_LINE → JR Z .paste_line; else (KIND_CHAR or fallback default) → fall through to .paste_char.
  - [x] Sub 3.4: `.paste_char` body per AC4 — pre-paste cursor advance (1 if not past-EOF and not on LF, BC preserved across motion_byte_at_logical per its contract); outer count loop calling edits_paste_yank_bytes per iter; on success DEC cursor to last byte; on CF=1 partial-place cursor (DEC iff cursor advanced past pre_cursor, else bypass .commit per Q5 zero-bytes-inserted guard); JP .commit.
  - [x] Sub 3.5: `.paste_line` body per AC5 — save entry cursor; walk to motion_find_line_end; branch past-EOF (insert explicit LF first via gapbuf_insert per Q4 always-insert pin) vs LF-found (advance by 1); CALL motion_apply_count to re-load count (preserved in state until parser_clear); outer count loop; post-loop cursor placement at start of FIRST inserted line via motion_find_line_end(entry_cursor) + 1; .pl_partial walks back via motion_find_line_start; .pl_overflow_no_content bypasses .commit (0 bytes landed).
  - [x] Sub 3.6: `.commit` tail — CALL edits_dirty_and_redraw; JP parser_clear. Empty-yank / KIND_BLOCK / overflow-with-zero-bytes-inserted paths bypass .commit and JP parser_clear directly (no buffer_dirty write if zero bytes changed).

- [x] **Task 4: Optionally add `msg_nothing_to_paste` status string** (AC6, AC9).
  - [x] Sub 4.1: SKIPPED per Q2 pin (silent empty-yank surface chosen). src/statusln.asm unchanged. ~22 B saved.

- [x] **Task 5: Module-header docstring updates per AR23** (across src/edits.asm + src/dispatch.asm).
  - [x] Sub 5.1: src/edits.asm header — added `op_paste` to the Public list (and `edits_paste_yank_bytes` to the Internal helpers list). Updated "State owned (read/write)" block to document op_paste as the SECOND non-trivial READER of the SR6 yank register, NEVER writes the yank register, writes cursor_offset per kind rule, writes buffer_dirty=1 on success/partial paths via edits_dirty_and_redraw, bypasses .commit on the explicit-LF-prelude-failed + KIND_CHAR 0-bytes-inserted paths.
  - [x] Sub 5.2: src/dispatch.asm Dependencies block — added Story 2.12 note: op_paste forward-referenced from the new `'p'` dispatch_normal entry; slot count grows 33 → 34; entry inserted at sorted ASCII position between `'o'` and `'v'`.

- [x] **Task 6: Headless tests** (AC10).
  - [x] Sub 6.1: Implemented all 6 canonical tests (epic line 1430 list): edits_p-after-yy / -after-dd / -after-dw / -empty-yank / 3p-counted / -fills-buffer.
  - [x] Sub 6.2: Implemented all 9 additional tests per AC10 list (zero dropped). Additional: edits_p-into-empty-buffer / -at-eof-no-lf / -on-lf / -line-with-no-trailing-lf / -counted-line / -kind-block-noop / -after-y3w / parser_p-dispatch / parser_3p-dispatch.
  - [x] Sub 6.3: Sentinel allocation per test: 0x90..0x97 band for unit-level edits_p-* tests (avoiding the 0x80..0x88 band used by Stories 2.5-2.11); 0xE1..0xE5 for the parser-driven dispatch tests (matching existing 0xE0..0xEC parser-test convention).
  - [x] Sub 6.4: All tests pre-seed yank_kind / yank_length / yank_buffer explicitly per the AC10 pre-seed pattern (LDIR from in-test .yank_content into yank_buffer). Pattern:
    ```
    LD A, KIND_CHAR (or KIND_LINE / KIND_BLOCK)
    LD (yank_kind), A
    LD HL, <yank_length>
    LD (yank_length), HL
    ;; copy yank content bytes to yank_buffer:
    LD HL, .test_yank_content
    LD DE, yank_buffer
    LD BC, <yank_length>
    LDIR
    ```
  - [x] Sub 6.5: Tests that drive through dispatch (parser_p-dispatch + parser_3p-dispatch) INCLUDE dispatch.asm + parser.asm + motions.asm + edits.asm — copied the parser_dispatch-key-routes-counted-motion.asm prelude pattern (test/Makefile dependency hygiene gap deferred-work.md:289 remains; not in scope for this story).

- [x] **Task 7: NFR9 + NFR18 + AR sweep verification** (AC12).
  - [x] Sub 7.1: Final `vibe.com` size = **5603 B** (`wc -c vibe.com`); 97.3% of the **NEW 5760 B ceiling** (Q1 Option A formal NFR9 amend landed at PRD §NFR9 + architecture.md in 5 callsites). **157 B headroom** — well under spec's projected 5510-5600 B band because Q2/Q3 silent pins saved ~28 B vs signalled option.
  - [x] Sub 7.2: NFR18 byte-identical rebuild verified twice: `91fde8e4971d8be23a3833b4b8b3530ce8bbd8cbf6412fcdcbaab54162520436` × 2 after `make clean && make all && make clean && make all`.
  - [x] Sub 7.3: AR13 / AR14 / AR15 grep sweeps clean for `src/edits.asm` and `src/dispatch.asm` — all BIOS_CONOUT / raw `LD (gap_start|gap_end)` / BDOS_CALL matches are in doc-comments only (zero CODE refs). `CALL gapbuf_insert` count in edits.asm grew 5 → 7 (was projected 5 → 6 in story spec; actual impl needed 2 new sites: edits_paste_yank_bytes inner loop + op_paste's KIND_LINE past-EOF explicit-LF prelude — both AR14-compliant; the two-site shape stays cleaner than folding the LF prelude into the helper).
  - [x] Sub 7.4: dispatch_normal count: `LD B, DISPATCH_NORMAL_COUNT` resolves to opcode `06 22` (hex 0x22 = 34 decimal) in build/vibe.lst — confirmed 33 → 34 grew correctly.

- [x] **Task 8: Deferred-work + sprint-status updates** (housekeeping).
  - [x] Sub 8.1: Appended `## Deferred from: dev of story-2-12-paste-p (2026-05-17)` block to `_bmad-output/implementation-artifacts/deferred-work.md` (line 374+; 8 entries):
    - NFR9 ceiling raise to 5760 B + revisit trigger for Story 2.13 (~400-500 B undo projection vs current 157 B headroom).
    - Q2 + Q3 silent surface pins (empty-yank + KIND_BLOCK) + revisit triggers if usability issues surface.
    - Q4 always-insert-LF pin (KIND_LINE past-EOF) + revisit trigger if the extra-blank-line corner becomes a friction point.
    - Q5 KIND_CHAR partial-paste DEC + zero-bytes-inserted guard pin.
    - FR45 undo recording STUB hook site for op_paste (Story 2.13 — AFTER count loop with actual bytes-inserted = cursor delta).
    - `CALL gapbuf_insert` count grew 5 → 7 (not 5 → 6 as projected) — rationale for the two-call-site shape over folding LF into the helper.
    - Spec narrative off-by-one for `edits_p-fills-buffer.asm` (cursor=2 actual semantic vs cursor=1 in spec text).
    - Sequential yank overwrite coverage gap (deferred-work line 335 carry-forward) — Story 2.12 partial-addresses by exercising paste-time read; full parser-driven two-yank test deferred to Story 3.x.
  - [x] Sub 8.2: Sprint-status flipped: backlog → ready-for-dev (Story 2.12 spec pass) → in-progress (dev pass start on 2026-05-16) → review (dev pass complete on 2026-05-17, awaiting Ant UAT). Added detailed `last_updated` blocks for both in-progress and review flips per Story 2.10 / 2.11 audit-trail pattern.

- [x] **Task 9: Hardware UAT script delivered to Ant verbatim** (AC13; per memory `feedback_uat_inline_at_dev_handoff.md`).
  - [x] Sub 9.1: AC13 12-step hardware UAT script pasted inline at the end of the dev pass handoff message (post-test-results, post-build-verification). Story does NOT flip to `done` until Ant confirms hardware UAT on real MicroBeast.

### Review Findings

Code review pass on 2026-05-17 (Blind Hunter + Edge Case Hunter + Acceptance Auditor). Acceptance Auditor returned 13/13 ACs MET with zero substantive findings. Blind Hunter + Edge Case Hunter independently flagged the cursor-leak issues on the two zero-bytes-landed branches.

- [x] [Review][Patch] `.pl_overflow_no_content` leaks cursor to file_length on zero-paste [src/edits.asm:2125-2131] — On KIND_LINE + last-line-no-LF + buffer-full, `(cursor_offset)` is written to `file_length` at line 2070 BEFORE the failed explicit-LF `gapbuf_insert`. `.pl_overflow_no_content` pops and discards entry_cursor. Cursor visibly jumps to EOF on a paste that inserted zero bytes. Fix: `POP HL ; LD (cursor_offset),HL ; JP parser_clear`. ~3 B. Flagged by Blind+Edge.
- [x] [Review][Patch] `.pc_partial` Z-branch leaves cursor advanced by 1 on zero-paste [src/edits.asm:2015-2057] — `pre_cursor` (line 2025-2026) is captured AFTER the pre-paste `INC HL` advance. On the first-byte-fails (0 bytes inserted) Z-branch the SBC HL,DE compares to post-advance cursor, returns 0, bypasses .commit — but cursor was already advanced by 1 and is never restored. Fix: save the raw entry cursor (before the optional INC HL) on the stack; restore on the Z-branch. ~5-7 B. Flagged by Blind+Edge.
- [x] [Review][Patch] Spec narrative off-by-one for `edits_p-fills-buffer.asm` [_bmad-output/implementation-artifacts/2-12-paste-p.md AC10] — AC10's `edits_p-fills-buffer.asm` description says `cursor=1`; actual semantic + test asserts `cursor=2` (logged in deferred-work.md:389 but spec narrative not amended). ~1 line edit.
- [x] [Review][Patch] Missing test for `.pl_overflow_no_content` branch [test/cases/] — Add `edits_p-line-prelude-full.asm`: gap_start==gap_end on last-line-no-LF buffer + KIND_LINE yank; assert cursor restored, buffer unchanged, parser cleared. Pins the (now-to-be-fixed) cursor restoration on the KIND_LINE prelude overflow path.
- [x] [Review][Patch] Missing test for `.pc_partial` Z-branch [test/cases/] — Add `edits_p-char-first-byte-full.asm`: near-full buffer + KIND_CHAR yank + cursor on non-LF non-EOF byte where the first `gapbuf_insert` fails. Assert cursor restored (post-fix), buffer_dirty unchanged, parser cleared.
- [x] [Review][Patch] Missing test for KIND_LINE 0-bytes-from-count-loop partial sub-case [test/cases/] — The LF-found prelude + first byte of yank content fails path (`.pl_partial` with 0 bytes from count loop) is uncovered. Author accepts this as "mildly wasteful but correct" (line 2117); a test would pin the accepted behavior.
- [x] [Review][Patch] Strengthen `parser_3p-dispatch.asm` parser-clear assertions [test/cases/parser_3p-dispatch.asm] — Currently asserts `count_accumulator == 0` only. The other `edits_p-*` tests assert all three parser fields (`count_accumulator`, `pending_operator`, `pending_motion_prefix`) cleared. A regression that cleared only `count_accumulator` would pass this test.
- [x] [Review][Patch] Missing test for counted KIND_CHAR `Np` with mid-iteration overflow [test/cases/] — Existing tests cover full success and first-iter-overflow. Add `edits_p-counted-mid-iter-overflow.asm`: iter 1 succeeds, iter 2 partially fails (e.g., `3p` of "foo" into a buffer with 5 bytes free → 5 of 9 inserted). Pins the outer-count-loop × partial-paste interaction.
- [x] [Review][Defer] `motion_apply_count` called twice on KIND_LINE path [src/edits.asm:2001,2087] — deferred, fragile coupling. Defensive PUSH/POP BC around the `.pl_past_eof` `gapbuf_insert` would eliminate the second call and save ~1 B. Not a current bug — count_accumulator is stable until parser_clear. Flagged by Blind+Edge.
- [x] [Review][Defer] `motion_byte_at_logical` HL-preservation comment asymmetric [src/edits.asm:2016 vs 2071] — deferred, cosmetic. The KIND_CHAR callsite documents "HL preserved"; the KIND_LINE past-EOF callsite at line 2071 relies on the same property without re-stating it. Add the same callout for consistency.
- [x] [Review][Defer] No test for unrecognised `yank_kind` value [test/cases/] — deferred, defensive-only. The fall-through-to-KIND_CHAR semantic at line 2003-2007 is by design (catches future corrupt state) but is untested.
- [x] [Review][Defer] Yank-register state-immutability asserted only in `edits_p-after-yy.asm` [test/cases/edits_p-after-yy.asm:503-522] — deferred, single-test coverage. The other 14 tests don't re-assert that `yank_kind`/`yank_length`/`yank_buffer` are unchanged after paste. A regression that zeroed yank on read would slip past all tests except this one.

**Dismissed (7):** stack-comment phrasing at line 311 (NIT); `edits_dirty_and_redraw` register contract not declared (NIT); magic `0x0A` instead of LF constant (project convention); hardcoded buffer-size numbers in `edits_p-fills-buffer.asm` docstring (NIT); `test_teardown_stub.inc` ordering inconsistency between parser-dispatch tests (NIT — both stubs harmless either way); `edits_p-fills-buffer.asm` `gap_end` setup (NIT — author already caveated); PRD/architecture amend date 2026-05-16 vs deferred-work 2026-05-17 (Auditor explicitly: "not a correctness issue").

## Dev Notes

### Architecture compliance

- **AR12 (status-line single funnel).** `op_paste` surfaces user feedback EXCLUSIVELY through `status_set_message` (and only on the empty-yank / KIND_BLOCK / partial-paste paths; partial-paste status is automatic via `gapbuf_insert`'s funnel). No direct `status_buffer` writes.
- **AR13 (render-owned screen emission).** `op_paste` calls `edits_dirty_and_redraw` (which marks all rows dirty + sets buffer_dirty); render.asm handles the actual emit. Zero new BIOS_CONOUT call sites.
- **AR14 (gap-buffer mutation surface).** `op_paste` mutates the gap buffer EXCLUSIVELY through `gapbuf_insert` (via `edits_paste_yank_bytes`). No `(gap_start)` / `(gap_end)` writes; no raw memory writes into the gap-buffer region.
- **AR15 (no raw BDOS).** Pure-memory paste — no BDOS calls. The yank_buffer is a static address (state.inc:144); reads via `LD A, (DE)` are direct memory loads, not BDOS reads.
- **AR16 (status-message conventions — lowercase, no period, < 30 chars).** Only NEW string is the optional `msg_nothing_to_paste` ("nothing to paste" — 16 chars; OK if added). Default: silent.
- **AR23 (per-module + per-entry contract blocks).** `op_paste` + `edits_paste_yank_bytes` each get a 4-line `In: / Out: / Trashes: / Calls:` block. src/edits.asm + src/dispatch.asm module headers updated to list the new entries.
- **AR25 (INCLUDE chain stability).** No reordering of `src/vibe.asm`'s INCLUDE chain. `op_paste` is forward-referenced from dispatch.asm; resolves via sjasmplus's two-pass model (dispatch.asm INCLUDEs before edits.asm per the existing chain).
- **MC1 (caller-saved).** Standard caller-saved register discipline. `op_paste` PUSH/POPs registers across calls to gapbuf_insert (which trashes BC, DE, HL, F per its contract).
- **MC3 (binary-search dispatch — sparse sorted tables).** New `'p'` entry inserted at the correct sorted position (between 'o' = 0x6F and 'v' = 0x76); ASSERT brackets the insertion per the existing pattern.
- **MC4 (handler signature).** A=key on entry (ignored — `op_paste` reads state via state.inc symbols); RET-terminating via tail-JP parser_clear.
- **MC5 (status as error sink).** All op_paste error surfaces (empty / block / overflow) route through status_set_message.
- **MC7 (single source of truth).** No new state.inc cells. yank_kind / yank_length / yank_buffer all already declared (state.inc:54 / 88 / 144). No new equates.inc constants (KIND_CHAR / KIND_LINE / KIND_BLOCK / YANK_BUFFER_SIZE all already declared).

### Files this story modifies (and what to preserve)

**`src/edits.asm` (UPDATE):**
- **Current state:** Story 2.11 left this module with `edits_open_below` / `edits_open_above` / `edits_insert_literal` / `edits_dirty_and_redraw` / `edits_insert_backspace` / `edits_insert_newline` / `edits_delete_char` / `edits_line_range_for_count` / `edits_copy_to_yank` / `edits_range_delete` / `op_dd` / `op_yy` + the entire Story 2.11 compose layer (`edits_compose_or_clear` / `edits_compose_range` / `op_compose_d` / `op_compose_y` / `op_compose_c` / `op_compose_indent` / `op_compose_dedent` / `op_indent_line` / `op_dedent_line` / `edits_indent_walk` + module-locals `edits_indent_walk_mode` / `edits_indent_walk_dirty`). ~1822 lines. yank_kind / yank_length / yank_buffer are documented as WRITER state in this module (via edits_copy_to_yank).
- **What this story changes:** Adds 2 public symbols (`op_paste` + `edits_paste_yank_bytes`). Module header: extend Public list; update "State owned (read/write)" to note op_paste is the first non-trivial READER of yank_buffer / yank_kind / yank_length CONTENT; Dependencies block already lists all transitive needs.
- **What must be preserved:** Every existing handler (op_dd / op_yy / op_compose_d/y/c/indent/dedent / op_indent_line / op_dedent_line) continues to write the yank register via edits_copy_to_yank with the same KIND_LINE / KIND_CHAR semantics. The edits_paste_yank_bytes helper reads through DE directly (no edits_copy_to_yank involvement on the read side). The existing edits_dirty_and_redraw / parser_clear / motion_byte_at_logical / motion_find_line_end / motion_apply_count call sites are unchanged.

**`src/dispatch.asm` (UPDATE):**
- **Current state:** dispatch_normal table at src/dispatch.asm:455-556 has 33 entries, sorted ASCII-ascending. Entries 0x0C (Ctrl-L) → '$' → '/' → '0'-'9' → ':' → '<' → '>' → 'G' → 'O' → 'a' → 'b' → 'c' → 'd' → 'g' → 'h' → 'i' → 'j' → 'k' → 'l' → 'o' → 'v' → 'w' → 'x' → 'y'.
- **What this story changes:** Insert `'p'` entry between `'o'` (line 542) and `'v'` (line 545). +3 B in the table + new `ASSERT 'p' > 'o'` (recycle the existing `ASSERT 'v' > 'o'` shape; either drop the old ASSERT or change it to `ASSERT 'v' > 'p'`). `DISPATCH_NORMAL_COUNT` auto-recomputes to 34.
- **What must be preserved:** All 33 existing entries unchanged. dispatch_insert / dispatch_command / dispatch_visual tables unchanged. The unbound_normal handler unchanged.

**`src/statusln.asm` (CONDITIONAL UPDATE):**
- **Current state:** msg_yank_too_large / msg_not_implemented / msg_file_too_large all already declared (lines 224 / 230 / 219). 13 status strings total.
- **What this story changes:** EITHER no change (silent empty-yank choice — DEFAULT recommendation) OR add `msg_nothing_to_paste: DEFB "nothing to paste", 0` (signalled choice — costs ~17 B + ~5 B at call site).
- **What must be preserved:** All existing strings unchanged. The module header's Public list updated only if the new string lands.

**`src/motions.asm` (NO CHANGE):**
- motion_apply_count / motion_byte_at_logical / motion_find_line_end are all consumed by op_paste; no patches to motions.asm.

**`src/parser.asm` (NO CHANGE):**
- parser_clear is consumed by op_paste's tail-JP; no patches. The new `'p'` dispatch_normal binding routes directly to op_paste (not through any parser_handle_* gate) — `'p'` is a plain handler, not an operator (no compose semantics) and not a count digit and not a motion prefix.

**`inc/state.inc` (NO CHANGE):**
- yank_kind / yank_length / yank_buffer all declared. No new state cells.

**`inc/equates.inc` (NO CHANGE):**
- KIND_CHAR / KIND_LINE / KIND_BLOCK / YANK_BUFFER_SIZE all declared.

### Paste algorithm — design choices and trade-offs

**Why `edits_paste_yank_bytes` (per-byte loop via `gapbuf_insert`) instead of a bulk-insert primitive?**

A `gapbuf_insert_range(src, length)` primitive that LDIRs the yank content directly into `gap_start` would be ~30 B in gapbuf.asm + cost ~5 B less per caller. Net savings ~25 B. Why not?

1. **AR14 surface widening.** Adding a new public gapbuf entry expands the AR14 mutation surface; every additional public entry needs its own contract block + module-header documentation + AR enforcement test. The single-byte gapbuf_insert primitive is the AR14-canonical shape; per-byte loops sit at the consumer level (edits.asm).
2. **Buffer-full handling.** The single-byte primitive returns CF=1 on the failing byte; the per-byte loop naturally captures "bytes-so-far" via HL. A bulk primitive would need to also surface "how many bytes did fit" — either a new register convention or a side-effect on cursor_offset (already happens incidentally). Cleaner to keep the contract simple.
3. **NFR3 cost.** A maxed 1024-byte yank pasted N=1 time via the per-byte loop: ~50 T-states/byte × 1024 = ~12.5 ms at 4 MHz. Sub-perceptible; within NFR3's interactive budget. The bulk primitive would shave ~5 ms — not user-visible.
4. **Future post-MVP optimisation.** If a profiling pass ever shows the per-byte loop dominating, the bulk primitive lands then. Defer until measured.

**Pin: per-byte loop. AR14 surface stays narrow; consumer-side loop is local to the paste use case.**

**Why `motion_find_line_end` for KIND_LINE walking (instead of a custom motion)?**

Story 2.5-2.6 established `motion_find_line_end` (motions.asm:672) as the "walk forward to next LF or file_length" helper. KIND_LINE paste needs exactly this walk — to find the position where the inserted line should land. Reusing motion_find_line_end:
- **Costs ~3 B per call** (CALL motion_find_line_end is 3 B).
- **Saves ~25-40 B** vs a duplicated walk inline.
- **AR23 pattern.** motion_find_line_end is module-internal to motions.asm but is already consumed by op_dd / op_yy / op_compose_d / op_compose_y / op_compose_c via edits_line_range_for_count. op_paste consuming it directly is one more consumer of the same helper — natural.

**Pin: reuse motion_find_line_end.**

**Why pre-paste cursor advance for KIND_CHAR (vs inserting AT cursor and post-paste DEC)?**

vi's "insert AFTER cursor" semantic for KIND_CHAR paste means the inserted bytes go at offset `cursor + 1`, not `cursor`. Two implementation options:
- **Option A (chosen):** Pre-paste, advance cursor by 1 (unless on LF or past-EOF). Then the gapbuf_insert loop runs at the right position. Post-paste, DEC cursor to land on the last inserted byte.
- **Option B:** Insert AT cursor, then post-paste advance cursor to "cursor + yank_length - 1".

Option A is ~2 B cheaper (no pre-paste cursor save needed; the post-paste DEC handles the "last byte" placement). Option B is conceptually simpler (no "advance before insert" mental model). **Pin: Option A** — byte-efficient + matches vi's mental model exactly.

### Previous story intelligence

**From [[story-2-10-doubled-operator-commands-dd-yy]]:**
- **First writer of `KIND_LINE`** via `op_dd` / `op_yy`. `yank_kind = KIND_LINE`; `yank_length = total_bytes`; `yank_buffer` holds verbatim deleted/yanked bytes.
- **AC2 last-line-no-LF semantic**: `dd` on the last line of a multi-line file (when prior lines exist) yanks `[S-1, file_length)` — content starts with a leading LF byte (the consumed cross-line LF). Documented in deferred-work.md line 319 as a Story 2.12 design point. **The simplest paste interpretation is "treat the leading LF as part of the line content; paste-back creates a blank line above the pasted content."** Document the choice; both interpretations satisfy FR32 in spirit.
- **`edits_copy_to_yank` parameterised on register A for kind** (Story 2.11 patched). Story 2.12 does NOT touch this helper — paste reads yank content, doesn't write to it.
- **Empty-buffer / 0-byte yank guards established**: `if total_bytes == 0 → JP parser_clear` (silent no-op). Story 2.12's empty-yank guard follows the same pattern.
- **YANK_BUFFER_SIZE = 1024 B** (equates.inc:41); yank_length is 16-bit; reads via DE-walk are physical-address direct (yank_buffer is a static EQU at GAP_BUFFER_BASE + GAP_BUFFER_MAX).

**From [[story-2-11-composed-operator-motion]]:**
- **First writer of `KIND_CHAR`** via `op_compose_d` / `op_compose_y` / `op_compose_c`. Same edits_copy_to_yank funnel; A=KIND_CHAR before the CALL.
- **Sequential yank overwrite untested in 2.11** (deferred-work.md:335 — "Defer to Story 2.12: paste's vi-faithful semantics require correct overwrite-on-second-yank behavior"). **Story 2.12's tests pin the second-yank-correctly-overwrites pattern** by exercising two yanks (yy then y3w; or dd then dw) and pasting the second.
- **`edits_paste_yank_bytes` is structurally similar to `edits_copy_to_yank`** — both walk yank-content bytes between yank_buffer and the gap buffer; one writes (copy_to_yank) and one reads (paste_yank_bytes). Symmetric pair.
- **NFR9 overshoot inherited:** post-2.11 = 5400 B / 105.5% of 5120 B. Story 2.12 adds ~110-200 B → projected 5510-5600 B (107.6-109.4%). Option A NFR9 amend is the recommended escalation path (same as Story 2.11's recommendation; Ant flipped 2.11 to `done` without resolving). **Story 2.12 should resolve this in the same pass.**

**From [[story-2-9-single-character-delete-x]]:**
- **Cursor placement post-mutation**: same pattern for op_paste's KIND_CHAR partial-paste (DEC cursor to last-inserted byte). The Story 2.9 EOL/EOF clamp shape is the proven precedent.

**From [[story-2-8-insert-mode]]:**
- **`enter_insert_mode` tail-JP pattern**: not used by op_paste (paste stays in NORMAL mode), but the AC11 contract block style is the template.

**From [[story-1-7-gap-buffer]]:**
- **`gapbuf_insert` contract**: A = byte; CF=0 success / CF=1 buffer-full; advances cursor on success; calls status_set_message msg_file_too_large on full. Trashes A, BC, DE, HL, F. This is the ONLY mutation primitive used by edits_paste_yank_bytes.
- **Buffer-full path**: state.gap_start = state.gap_end; status_buffer holds msg_file_too_large; cursor unchanged on the failing byte. op_paste's partial-paste cursor-placement logic handles the "cursor stopped at the failing byte" state.

**From [[story-1-9-mode-dispatch]] / [[story-1-3-static-memory-map]]:**
- **dispatch_normal sparse sorted table**: insertion at the sorted position; ASSERT brackets; DISPATCH_NORMAL_COUNT auto-recomputes. MC3 binary search worst-case unchanged.
- **yank_kind (1 B), yank_length (2 B), yank_buffer (1024 B reserved)** all declared. yank_buffer at GAP_BUFFER_BASE + GAP_BUFFER_MAX = `static_end + 32768`. Physical address; not part of the SR3 gap-buffer logical-offset space.

### Git intelligence

Recent commits (post-Story 2.11):

- `84dd7d4 story 2.11: operator+motion compose (dw/d$/c5w/y3j) + >> / << landed` — Story 2.11 dev pass + done flip (5400 B / 105.5% NFR9 overshoot inherited by 2.12).
- `94b4f16 story 2.9: x deletes char under cursor; counted Nx with EOL/EOF clamp` — Story 2.9 (the single-char delete; EOL/EOF clamp shape).
- `fdd2d10 social media preview image` — non-dev cosmetic.
- `57325ff story 2.8: INSERT mode lands; i/a/o/O, typing, backspace, Enter→LF, Esc` — Story 2.8 (enter_insert_mode).
- `425bc2e code review changes` — Story 2.7 code review.

**Story 2.11 is the immediate predecessor.** Story 2.12's dev pass starts from the 2.11 baseline. The compose layer (op_compose_d/y/c) writes KIND_CHAR; op_dd/op_yy write KIND_LINE. Story 2.12 is the consumer of both.

**Patterns to follow** (consolidated from the Story 2.5-2.11 dev passes):
- Single dev-commit per story containing production code + tests + spec updates + sprint-status flips.
- Separate code-review commit (optional; Story 2.10 ran this pattern; Story 2.11 skipped at Ant's call).
- Sentinel byte at `0xCFFE` per TH1 (test/inc/test_prologue.inc); unique sentinel per test in a chosen band.
- INCLUDE chain in test cases: pre-ORG headers, `test_prologue.inc`, test body, `test_epilogue.inc`, production sources (`src/dispatch.asm` + `src/motions.asm` + `src/edits.asm` + `src/parser.asm` + `src/statusln.asm` + `src/gapbuf.asm` + `src/input.asm` + `src/render.asm` + ...), `test_teardown_stub.inc`, `test_input_loop_stub.inc`, finally `inc/state.inc`. **Tests that drive through dispatch need every production module that the dispatch chain transitively references.**
- Gap-buffer fixture pattern: `CALL gapbuf_init` → LDIR payload → set `gap_start := GAP_BUFFER_BASE + N`. Cursor pre-set via `LD HL, N ; LD (cursor_offset), HL`. Mode pre-set via `LD A, MODE_NORMAL ; LD (mode_byte), A`.
- **Yank-register pre-seed for paste tests** (NEW pattern for Story 2.12):
  ```
  LD A, KIND_CHAR (or KIND_LINE)
  LD (yank_kind), A
  LD HL, <expected_length>
  LD (yank_length), HL
  LD HL, .test_yank_content
  LD DE, yank_buffer
  LD BC, <expected_length>
  LDIR
  .test_yank_content:
      DEFB "your yank bytes here"
  ```
  (The `.test_yank_content` block goes in the test's data section; LDIR copies it to `yank_buffer` at the static EQU address.)
- **NFR18 verification pattern**: post-dev pass, `make clean && make all` produces a byte-identical `vibe.com` (sha256sum matches the previous build).

### Testing requirements

- All ~14 new tests under `test/cases/edits_*.asm` + `test/cases/parser_*.asm`. Each builds under `make -C test`, runs under iz-cpm with the 5-second timeout, reports PASS via TH1 / TH2.
- The dispatch-chain tests (`parser_p-dispatch`, `parser_3p-dispatch`) drive the full keystroke sequence via dispatch_key. This matches the Story 2.10 / 2.11 parser-test convention.
- Tests that drive directly via `CALL op_paste` after pre-seeding yank_kind / yank_length / yank_buffer + count_accumulator exercise the paste body in isolation (no dispatch coverage; pins the AC2-AC8 semantics). Mix of both kinds (per AC10).
- Tests for partial-paste (`edits_p-fills-buffer`) MUST pre-load the gap buffer at a known near-full state — set `gap_start` via direct assignment (one of the documented AR14 carve-outs is fileio.asm's load-time bulk fill; tests use the same pattern: `LD HL, GAP_BUFFER_BASE + (GAP_BUFFER_MAX - 2); LD (gap_start), HL` to simulate a buffer 2 bytes short of full).
- Tests for KIND_BLOCK pre-seed `yank_kind = KIND_BLOCK = 2` and verify the no-op + optional status surface.
- Sentinel allocation per test per the Story 2.5..2.11 convention.

### Project Structure Notes

- **No new source files.** Story 2.12 extends `src/edits.asm` (~+130 B) + `src/dispatch.asm` (+3 B for the dispatch entry) + optionally `src/statusln.asm` (+22 B for msg_nothing_to_paste if signalled choice).
- **No new inc/*.inc files.** All constants (KIND_CHAR / KIND_LINE / KIND_BLOCK / YANK_BUFFER_SIZE) and all state cells (yank_kind / yank_length / yank_buffer) already declared.
- **2 new public symbols** in src/edits.asm: `op_paste` + `edits_paste_yank_bytes`.
- **1 new dispatch_normal entry**: `'p'`.
- **0 new module-local cells.**
- **0 new state.inc cells.**
- **`dispatch_normal` count grows 33 → 34.**
- **dispatch_insert / dispatch_command / dispatch_visual** unchanged.
- **`src/vibe.asm` INCLUDE chain unchanged.**
- **~14 new test files** under `test/cases/edits_p-*.asm` + `test/cases/parser_*-p-dispatch.asm`.

### Source tree paths touched

```
.
├── src/
│   ├── edits.asm             # UPDATE — add op_paste + edits_paste_yank_bytes; module-header docstring updated
│   ├── dispatch.asm          # UPDATE — add 'p' entry to dispatch_normal (between 'o' and 'v'); +3 B
│   ├── statusln.asm          # CONDITIONAL UPDATE — add msg_nothing_to_paste IF signalled-empty-yank choice taken (default: NO update)
│   ├── motions.asm           # UNCHANGED
│   ├── parser.asm            # UNCHANGED
│   └── gapbuf.asm            # UNCHANGED
├── inc/
│   ├── equates.inc           # UNCHANGED
│   └── state.inc             # UNCHANGED
├── _bmad-output/
│   ├── planning-artifacts/   # UNCHANGED
│   └── implementation-artifacts/
│       ├── 2-12-paste-p.md                            # THIS FILE
│       ├── deferred-work.md                           # UPDATE (Task 8)
│       └── sprint-status.yaml                         # UPDATE (status flips backlog → ready-for-dev → in-progress → review → done)
└── test/
    └── cases/
        ├── edits_p-after-yy.asm                        # NEW (canonical)
        ├── edits_p-after-dd.asm                        # NEW (canonical)
        ├── edits_p-after-dw.asm                        # NEW (canonical)
        ├── edits_p-empty-yank.asm                      # NEW (canonical)
        ├── edits_3p-counted.asm                        # NEW (canonical)
        ├── edits_p-fills-buffer.asm                    # NEW (canonical)
        ├── edits_p-into-empty-buffer.asm               # NEW
        ├── edits_p-at-eof-no-lf.asm                    # NEW
        ├── edits_p-on-lf.asm                           # NEW
        ├── edits_p-line-with-no-trailing-lf.asm        # NEW
        ├── edits_p-counted-line.asm                    # NEW
        ├── edits_p-kind-block-noop.asm                 # NEW
        ├── edits_p-after-y3w.asm                       # NEW
        ├── parser_p-dispatch.asm                       # NEW
        └── parser_3p-dispatch.asm                      # NEW
```

(15 test slots — 6 canonical + 9 additional; the dev pass MAY drop 1-2 if their coverage is fully subsumed by sibling tests — document drops + rationale per the Story 2.9 / 2.10 / 2.11 pattern.)

### Files to be created and modified by this story

**New:**
- 6 canonical tests + ~9 additional tests per AC10 / Source tree paths above.

**Modified:**
- `src/edits.asm` — 2 new public entries (op_paste + edits_paste_yank_bytes); module-header Public list + per-entry contract blocks + State owned + Dependencies blocks updated per AR23. Net body delta: +110-170 B (depending on KIND_LINE branch detail level + whether msg_nothing_to_paste lands).
- `src/dispatch.asm` — 1 new entry in dispatch_normal (`'p' → op_paste`); +3 B body + 1 new ASSERT. Module-header docstring touched only if the Public list / State owned blocks need updates (likely no — op_paste is a forward-reference target, not a new state owner from dispatch's perspective).
- `src/statusln.asm` — CONDITIONAL (Sub 4.1). DEFAULT: no change.
- `_bmad-output/implementation-artifacts/deferred-work.md` — Story 2.12 deferred entries per Task 8.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — 2-12 status flips (backlog → ready-for-dev → in-progress → review → done).
- `_bmad-output/implementation-artifacts/2-12-paste-p.md` — this file (initial create as `ready-for-dev`; dev pass appends to Dev Agent Record + Change Log).

### Implementation Questions

**Saved for the dev pass / Ant to resolve before dev starts:**

1. **NFR9 budget — is the projected ~5510-5600 B post-Story-2.12 (~107.6-109.4% of the 5120 B ceiling, ~390-480 B over) acceptable?** Story 2.11 closed at 5400 B / 280 B over, with the Option A "formal NFR9 amend to ~5632 B or ~5760 B" recommendation never resolved. **Story 2.12 inherits AND extends the overshoot.** Three paths:
   - **Option A (recommended) — Formal NFR9 amend to ~5760 B (12.5% over the original 5120 B; gives ~150-250 B headroom for Story 2.13 undo).** Update PRD §NFR9 + architecture.md (§ Resource Consumption + § code budget paragraph + § Listing/symbol size-audit caption). Document Story 2.6's earlier 3072 → 5120 amend as a prior precedent.
   - **Option B — Drop the KIND_LINE past-EOF explicit-LF insert (AC5 last-line-no-LF case).** Save ~15-25 B. Treat the corner case as a documented sharp edge in deferred-work.md.
   - **Option C — Drop the msg_nothing_to_paste / msg_not_implemented status surfaces and go fully silent on empty-yank and KIND_BLOCK.** Already the recommended DEFAULT (saves ~22 B vs the signalled choice). This is "free" savings — pick it regardless of A/B.

2. **Empty-yank status surface** — silent (DEFAULT recommendation; matches vi convention; saves ~22 B) OR `msg_nothing_to_paste` (signalled; user gets explicit feedback). Pin choice.

3. **KIND_BLOCK status surface** — `msg_not_implemented` (DEFAULT recommendation; reuses existing string; ~6 B guard cost) OR silent (saves ~6 B). Pin choice.

4. **AC5 last-line-no-LF + leading-LF yank** — Option A (always insert explicit LF on past-EOF; the user sees an extra blank line for the "dd last-line-no-LF → p" corner case) OR Option B (peek yank_buffer[0]==0x0A and skip the explicit LF). Recommendation: **Option A** (simpler; minimum-viable; the corner case is recoverable via Story 2.13 undo).

5. **KIND_CHAR partial-paste cursor placement** — DEC cursor to last-successfully-inserted byte (clean; matches success-path semantic) OR leave cursor wherever gapbuf_insert left it (slightly simpler; cursor lands one past the last-inserted byte). Recommendation: **DEC** (consistent with success path; +2-3 B).

### References

- FR32 (the primary load-bearing FR — paste): [Source: _bmad-output/planning-artifacts/prd.md] line 748
- FR45 (undo coverage — STUB in 2.12, full impl in 2.13): [Source: _bmad-output/planning-artifacts/prd.md] line 778
- FR50 (unsupported commands as no-op — KIND_BLOCK reserved + msg_not_implemented): [Source: _bmad-output/planning-artifacts/prd.md] line 793
- FR52 (no silent data loss — partial-paste preserves what got inserted): [Source: _bmad-output/planning-artifacts/prd.md] (NFR6 / FR52 section near line 858)
- SR6 (yank register — Story 2.12 is the first non-trivial READER of yank content): [Source: _bmad-output/planning-artifacts/architecture.md] lines 456-461
- NFR1 / NFR2 / NFR3 (interactive feedback / sustained typing / cursor-motion latency): [Source: _bmad-output/planning-artifacts/prd.md] line 108 + 820-824
- NFR9 (code size budget — 5120 B ceiling — **inherited overshoot from Story 2.11; Story 2.12 extends**): [Source: _bmad-output/planning-artifacts/prd.md] lines 848-858
- NFR10 (TPA fit — Option A NFR9 amend is mathematically free given TPA headroom): [Source: _bmad-output/planning-artifacts/prd.md] lines 859-861
- NFR16 (compile-time knobs in equates.inc — KIND_CHAR / KIND_LINE / KIND_BLOCK / YANK_BUFFER_SIZE): [Source: inc/equates.inc:41-84]
- NFR18 (byte-identical rebuild): verified by `make clean && make all`
- MC3 (binary-search dispatch — new 'p' entry; 33 → 34): [Source: _bmad-output/planning-artifacts/architecture.md] lines 485-527
- MC4 (handler signature — A=key on entry; state via state.inc symbols): [Source: _bmad-output/planning-artifacts/architecture.md] line 1502+
- AR12 / AR13 / AR14 / AR15 (architectural boundaries): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1434-1463
- AR23 (module header contracts): [Source: src/edits.asm:1-273 + src/parser.asm:1-200 header blocks as exemplars]
- AR25 (INCLUDE chain in vibe.asm): [Source: src/vibe.asm + architecture.md:918-956]
- [[story-2-11-composed-operator-motion-dw-d-c5w-y3j]] (first writer of KIND_CHAR; sequential-yank-overwrite deferral resolved here; NFR9 overshoot inherited): [Source: _bmad-output/implementation-artifacts/2-11-composed-operator-motion-dw-d-c5w-y3j.md]
- [[story-2-10-doubled-operator-commands-dd-yy]] (first writer of KIND_LINE; AC2 last-line-no-LF + leading-LF yank semantic; YANK_BUFFER_SIZE 1024 cap; edits_copy_to_yank parameterised by Story 2.11): [Source: _bmad-output/implementation-artifacts/2-10-doubled-operator-commands-dd-yy.md]
- [[story-2-9-single-character-delete-x]] (cursor-placement-post-mutation EOL/EOF clamp shape — reused for partial-paste KIND_CHAR cursor placement; FR45 stub pattern): [Source: _bmad-output/implementation-artifacts/2-9-single-character-delete-x.md]
- [[story-2-8-insert-mode]] (edits.asm module pattern + AR23 contract block template — op_paste follows the same shape): [Source: _bmad-output/implementation-artifacts/2-8-insert-mode-i-a-o-o.md]
- [[story-2-7-counted-motions]] (motion_apply_count consumed by op_paste for counted-`Np`; state-read-before-clear discipline): [Source: _bmad-output/implementation-artifacts/2-7-counted-motions.md]
- [[story-2-5-basic-motions]] (AC13 parser_clear hygiene — every NORMAL-mode handler tail-JPs parser_clear; op_paste follows): [Source: _bmad-output/implementation-artifacts/2-5-basic-motions-h-j-k-l.md]
- [[story-1-9-mode-dispatch]] (dispatch_normal sparse sorted table — `'p'` entry inserted at sorted position; MC3 binary-search dispatch): [Source: src/dispatch.asm:455-556]
- [[story-1-7-gap-buffer]] (gapbuf_insert primitive — the AR14 mutation surface used by edits_paste_yank_bytes; buffer-full CF=1 behaviour for FR52 partial-paste preservation): [Source: src/gapbuf.asm:68-128]
- [[story-1-5-status-line]] (status_set_message AR12 funnel; msg_not_implemented / msg_yank_too_large / msg_file_too_large all re-used unchanged; msg_nothing_to_paste optional): [Source: src/statusln.asm]
- [[story-1-3-static-memory-map]] (state.inc — yank_kind / yank_length / yank_buffer all declared; no new cells): [Source: inc/state.inc:1-156]
- [[story-1-2-compile-time-constants]] (equates.inc — KIND_CHAR / KIND_LINE / KIND_BLOCK / YANK_BUFFER_SIZE all declared): [Source: inc/equates.inc:1-95]
- deferred-work.md line 319 (Story 2.10 AC2 last-line-no-LF leading-LF yank semantic — Story 2.12 paste handler decision point): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 319
- deferred-work.md line 335 (sequential yank overwrite untested in Story 2.10 — Story 2.12 surfaces the coverage via paste-after-second-yank tests): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 335
- deferred-work.md line 345-346 (Story 2.11 NFR9 overshoot to 5400 B / 105.5% + Option A NFR9 amend recommendation — Story 2.12 inherits AND extends): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 345-346
- deferred-work.md line 19 (yank-buffer NOT zero-initialised on cold-start — Story 2.10 / 2.11 / 2.12 first-paste post-boot reads zero-initialised yank_kind=KIND_CHAR=0 and yank_length=0; the AC6 empty-yank guard catches this correctly): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 19
- Memory `[[feedback_uat_inline_at_dev_handoff]]` (paste AC13 UAT script verbatim into chat at end of dev pass): [Source: /home/ant/.claude/projects/-home-ant-src-microbeast-vibe/memory/feedback_uat_inline_at_dev_handoff.md]
- Memory `[[feedback_uat_trace_cursor]]` (post-`:e` cursor at offset 0; `$a` for EOF append in UAT scripts): [Source: /home/ant/.claude/projects/-home-ant-src-microbeast-vibe/memory/feedback_uat_trace_cursor.md]
- Memory `[[project_no_tilde_marker]]` (no `~` marker — past-EOF screen rows render as spaces; don't write UAT narratives that predict `~`): [Source: /home/ant/.claude/projects/-home-ant-src-microbeast-vibe/memory/project_no_tilde_marker.md]
- Epic 2 spec — Story 2.12 ACs (1388-1430) + the cross-story context (Story 2.13 undo depends on Story 2.12's paste-as-mutating-handler being undoable; epic AC line 1440 lists `p + u` as a load-bearing undo journey): [Source: _bmad-output/planning-artifacts/epics.md] lines 1388-1480

## Dev Agent Record

### Agent Model Used

claude-opus-4-7[1m]

### Debug Log References

- No interactive debug sessions needed during the dev pass. The red-green-refactor cycle worked cleanly on the first build: dispatch.asm + edits.asm edits compiled clean; all 15 new tests passed first-run.
- `make test` final: 174 pass / 1 deliberate-fail (`harness_fail`). Was 159/1 post-Story-2.11; +15 new.
- `make clean && make all` × 2 produced byte-identical `vibe.com` (sha256 `91fde8e4971d8be23a3833b4b8b3530ce8bbd8cbf6412fcdcbaab54162520436`). NFR18 verified.
- Final `vibe.com` size = 5603 B = 97.3% of NEW 5760 B ceiling = 157 B headroom.
- `DISPATCH_NORMAL_COUNT` resolved to 0x22 = 34 in build/vibe.lst (was 0x21 = 33 pre-Story-2.12).
- `CALL gapbuf_insert` code-site count in src/edits.asm grew 5 → 7 (spec projected 5 → 6; actual impl added 2 sites — the helper inner loop AND op_paste's KIND_LINE past-EOF explicit-LF prelude; rationale logged in deferred-work.md).

### Completion Notes List

- **Implementation Questions resolved pre-dev with Ant:**
  - Q1 (NFR9 budget): Option A formal amend to 5760 B. PRD §NFR9 line 848 + architecture.md in 5 callsites updated.
  - Q2 (empty-yank surface): silent (no msg_nothing_to_paste). Saved ~22 B.
  - Q3 (KIND_BLOCK surface): silent (no msg_not_implemented call). Saved ~6 B.
  - Q4 (AC5 leading-LF corner): Option A always-insert-LF. Saved ~15-25 B vs peek-and-skip; the `dd-last-line-no-LF → p` corner gives an extra blank line (recoverable via Story 2.13 undo).
  - Q5 (KIND_CHAR partial-paste cursor): DEC to last successfully-inserted byte with zero-bytes-inserted guard (skip DEC + bypass .commit if 0 bytes landed).
- **Production code lands:** 1 new public entry (`op_paste`) + 1 new internal helper (`edits_paste_yank_bytes`) in src/edits.asm at line 1854-2143 (just before the module-local scratch cells). 1 new dispatch_normal entry (`'p' → op_paste`) in src/dispatch.asm between `'o'` and `'v'` at line 544-546. Module-header docstrings updated per AR23 in both files.
- **NFR9 amend landed first** (PRD + architecture.md across 5 callsites) per spec sequencing — same Task-1-first pattern as Story 2.6's NFR9 amend. New ceiling: 5760 B. Final size 5603 B / 157 B headroom. Story 2.13 single-level undo projected +400-500 B → 157 B headroom is insufficient; deferred-work.md flags this revisit trigger for Story 2.13 spec (either shared undo-record helper to amortise per-handler cost OR another formal amend lands then).
- **AR sweeps all clean** for the touched modules (src/edits.asm + src/dispatch.asm): BIOS_CONOUT / raw gap_start/gap_end writes / BDOS_CALL all zero CODE refs (only doc-comment matches).
- **Test count: 174 pass / 1 deliberate-fail** (was 159/1 post-Story-2.11). +15 new tests landed (6 canonical + 9 additional). Zero dropped from AC10 enumeration. Sentinel allocation: 0x90..0x97 for unit-level edits_p-* tests; 0xE1..0xE5 for parser-driven dispatch tests. All 15 tests passed first build — no fixes needed.
- **NFR18 byte-identical rebuild verified twice:** sha256 `91fde8e4971d8be23a3833b4b8b3530ce8bbd8cbf6412fcdcbaab54162520436` × 2.
- **5 deferred-work entries logged + 3 misc entries** (8 total) per Story 2.10 / 2.11 housekeeping convention. Key forward-references: Story 2.13 NFR9 budget pressure; Q2/Q3 silent-surface revisit triggers; Q4 always-insert-LF revisit trigger; FR45 undo hook site documented for Story 2.13.
- **FR45 undo recording for op_paste is a STUB** for Story 2.12 (matches Story 2.8 B2 / 2.9 / 2.10 / 2.11 stub patterns). Story 2.13 hook site: AFTER the count loop with actual bytes-inserted derived from cursor delta. op_paste becomes the 6th mutating handler with an FR45 stub (5 from Story 2.11 + this).
- **Hardware UAT (AC13) deferred to Ant** per established Story 2.5..2.11 pattern. Story stays at `review` until Ant confirms hardware UAT on real MicroBeast.

### File List

**Modified (production code):**
- `src/edits.asm` — added `op_paste` (public entry) + `edits_paste_yank_bytes` (internal helper) — 2 new symbols, ~290 lines incl. AR23 contract blocks. Module-header docstrings updated (Public list + State owned block).
- `src/dispatch.asm` — added 1 entry in `dispatch_normal` for `'p'` (between `'o'` and `'v'`) with `ASSERT 'p' > 'o'` + `ASSERT 'v' > 'p'` brackets. Dependencies block updated to note the new forward-reference to op_paste.

**Modified (planning artifacts — NFR9 amend):**
- `_bmad-output/planning-artifacts/prd.md` — NFR9 ceiling raised 5120 → 5760 B (line 848-863); amend-history block extended.
- `_bmad-output/planning-artifacts/architecture.md` — NFR9 ceiling references updated in 5 callsites (line 47, 200, 305, 735, 1334).

**Modified (implementation artifacts):**
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — 2-12-paste-p status flipped backlog → ready-for-dev (Story 2.12 spec pass) → in-progress (2026-05-16) → review (2026-05-17). New `last_updated` audit-trail entries added per Story 2.10 / 2.11 convention.
- `_bmad-output/implementation-artifacts/deferred-work.md` — appended Story 2.12 dev block with 8 entries (line 374+).
- `_bmad-output/implementation-artifacts/2-12-paste-p.md` — this file. Tasks/Subtasks checkboxes marked; Status flipped review; Dev Agent Record + File List + Change Log populated.

**New (code review patches, 2026-05-17 — 4 additional tests under test/cases/):**
- `edits_p-char-first-byte-full.asm` (P5; sentinels 0xA0-0xA3) — pins P2 fix: KIND_CHAR pre-paste advance reverted on 0-bytes-landed Z-branch.
- `edits_p-line-prelude-full.asm` (P4; sentinels 0xA4-0xA7) — pins P1 fix: KIND_LINE prelude-overflow restores entry_cursor.
- `edits_p-line-zero-from-count-loop.asm` (P6; sentinels 0xA8-0xAE) — pins documented-accepted `.pl_partial` spurious-dirty behaviour on LF-found-prelude + 0-bytes-from-count-loop path.
- `edits_p-counted-mid-iter-overflow.asm` (P8; sentinels 0xB0-0xB9) — pins counted KIND_CHAR `Np` × mid-iteration overflow (existing `edits_p-fills-buffer.asm` covered first-iter overflow only).

**Modified (code review patches, 2026-05-17):**
- `src/edits.asm` — P1: `.pl_overflow_no_content` now restores entry_cursor (+3 B). P2: `.paste_char` pushes raw_entry before pre-paste advance; `.pc_partial` restores raw_entry on 0-bytes-landed Z-branch; new `.pc_partial_dec` label for the >0-bytes path (+9 B). Net +12 B.
- `test/cases/parser_3p-dispatch.asm` — P7: strengthened with pending_operator + pending_motion_prefix assertions (sentinel 0xE6 added).
- `_bmad-output/implementation-artifacts/2-12-paste-p.md` — P3: AC10 `edits_p-fills-buffer.asm` narrative corrected to cursor=2 (was off-by-one cursor=1). Review-findings checkboxes all marked done.

**New (test cases — 15 total from dev pass, all under test/cases/):**
- `edits_p-after-yy.asm` (canonical)
- `edits_p-after-dd.asm` (canonical)
- `edits_p-after-dw.asm` (canonical)
- `edits_p-empty-yank.asm` (canonical)
- `edits_3p-counted.asm` (canonical)
- `edits_p-fills-buffer.asm` (canonical)
- `edits_p-into-empty-buffer.asm` (additional)
- `edits_p-at-eof-no-lf.asm` (additional)
- `edits_p-on-lf.asm` (additional)
- `edits_p-line-with-no-trailing-lf.asm` (additional)
- `edits_p-counted-line.asm` (additional)
- `edits_p-kind-block-noop.asm` (additional)
- `edits_p-after-y3w.asm` (additional)
- `parser_p-dispatch.asm` (additional — full dispatcher chain)
- `parser_3p-dispatch.asm` (additional — counted dispatcher chain end-to-end)

**NOT modified (per story scope):**
- `src/statusln.asm` — no new strings (Q2 silent pin; msg_nothing_to_paste skipped).
- `src/motions.asm` — no new helpers (op_paste consumes existing motion_apply_count / motion_byte_at_logical / motion_find_line_end / motion_find_line_start).
- `src/parser.asm` — unchanged (op_paste tail-JPs parser_clear; no new parser hooks).
- `src/gapbuf.asm` — unchanged (op_paste mutates via existing gapbuf_insert primitive — AR14-clean).
- `inc/state.inc` — unchanged (yank_kind / yank_length / yank_buffer all declared since Story 1.3).
- `inc/equates.inc` — unchanged (KIND_CHAR / KIND_LINE / KIND_BLOCK / YANK_BUFFER_SIZE all declared since Story 2.10).
- `src/vibe.asm` — AR25 INCLUDE chain unchanged.

### Change Log

| Date | Change | Notes |
|------|--------|-------|
| 2026-05-16 | Story 2.12 created at ready-for-dev | Paste `p` / counted `Np` contexted from epics line 1388; 13 ACs / 9 tasks / ~14-15 tests + 12-step hardware UAT. |
| 2026-05-17 | NFR9 ceiling amend 5120 → 5760 B | Q1 Option A pin (formal amend); PRD §NFR9 + architecture.md in 5 callsites updated. Same shape as Story 2.6's 3072 → 5120 amend. |
| 2026-05-17 | Production code lands | `op_paste` + `edits_paste_yank_bytes` in src/edits.asm; `'p'` entry in dispatch_normal (33 → 34 entries). AR sweeps clean. Final size 5603 B / 97.3% of new 5760 B / 157 B headroom. |
| 2026-05-17 | 15 new headless tests land | 6 canonical + 9 additional (zero dropped from AC10). All pass first build. Test count 159 → 174 pass / 1 deliberate-fail (`harness_fail`). |
| 2026-05-17 | NFR18 verified | byte-identical rebuild × 2: sha `91fde8e4971d8be23a3833b4b8b3530ce8bbd8cbf6412fcdcbaab54162520436`. |
| 2026-05-17 | Story flipped to review | Awaiting Ant hardware UAT (AC13, 12 steps) on real MicroBeast. deferred-work.md updated with 8 entries (5 IQ pins + 3 misc). Sprint-status.yaml updated with detailed audit-trail entry. |
| 2026-05-17 | Hardware UAT confirmed; story → done | Ant confirmed all 12 AC13 steps pass first iteration on real MicroBeast; boundary cases (a) `p` on empty line and (c) `dd-last-line-no-LF → p` both pass. Boundary case (b) near-full buffer partial-paste not tested on hardware — coverage retained via headless `edits_p-fills-buffer.asm`. FR32 closed end-to-end. |
| 2026-05-17 | Code review applied: 8 patches, 4 deferred, 7 dismissed | Blind Hunter + Edge Case Hunter + Acceptance Auditor; Acceptance Auditor returned 13/13 ACs MET. Two substantive code defects (P1 `.pl_overflow_no_content` cursor leak to file_length; P2 `.pc_partial` Z-branch cursor leak by 1) both fixed at +12 B (5603 → 5615 B / 97.5% of 5760 B / 145 B headroom). 4 new tests pin the fixed paths + accepted-mild and mid-iter-overflow paths (`edits_p-char-first-byte-full`, `edits_p-line-prelude-full`, `edits_p-line-zero-from-count-loop`, `edits_p-counted-mid-iter-overflow`); 1 existing test strengthened (`parser_3p-dispatch` adds pending_operator + pending_motion_prefix asserts). Spec narrative cursor=1 → cursor=2 corrected in AC10. Test count 174 → 178 pass / 1 deliberate-fail. NFR18 byte-identical × 2: `ecca17f7fc9966e1b73e69d3b86398ce953258a4f809d278503d1be62e9574bd`. AR sweeps clean. 4 review items deferred to deferred-work.md under "code review of 2-12-paste-p (2026-05-17)" heading. |
| 2026-05-16 | Story 2.12 created from epics line 1388 | Initial draft; status `ready-for-dev`. 13 ACs, 9 tasks, ~14-15 headless tests + 12-step hardware UAT. Architecturally: the second non-trivial reader of the yank-register protocol (after edits_copy_to_yank's write-time accounting; this is the first reader of yank CONTENT at yank_buffer). Closes FR32 end-to-end — the yank/delete → paste loop. Discriminates on yank_kind: KIND_CHAR (insert after cursor, cursor on last byte), KIND_LINE (insert as new line below, cursor at start), KIND_BLOCK (reserved for Epic 3 visual-block — no-op + msg_not_implemented). Counted Np supported via motion_apply_count (state-read-before-clear discipline). Partial-paste on buffer-overflow preserves what got inserted (FR52); msg_file_too_large surfaced automatically by gapbuf_insert. Empty-yank silent (recommended) OR msg_nothing_to_paste (signalled). FR45 undo recording STUB; hook site documented for Story 2.13. Inner per-byte insert loop factored into `edits_paste_yank_bytes` helper (~30 B; AR14-compliant; reads yank_buffer directly via DE since yank_buffer is at a static physical address, not a logical gap-buffer offset). dispatch_normal grows 33 → 34 with the new `'p'` entry between `'o'` and `'v'`. NFR9 projection: post-2.12 ~5510-5600 B = ~107.6-109.4% of the 5120 B ceiling — **OVER by ~390-480 B** (inherits Story 2.11's 280 B overshoot AND extends by ~110-200 B). Three escalation paths documented (Option A formal NFR9 amend to ~5760 B [recommended; closes FR32 cleanly + gives ~150-250 B Story-2.13 headroom]; Option B drop AC5 past-EOF explicit-LF; Option C drop empty-yank + KIND_BLOCK status surfaces [free savings — already the recommended default]). 5 Implementation Questions saved for dev pass / Ant to resolve before dev starts (NFR9 budget; empty-yank status; KIND_BLOCK status; AC5 last-line-no-LF semantic; KIND_CHAR partial-paste cursor placement). All recommendations annotated. |
