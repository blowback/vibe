# Story 2.13: Single-level undo (u)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `u` in NORMAL mode to undo the most recent edit (insert session, delete, paste, change, indent/dedent),
so that FR45 and FR46 are realized, B2 (insert sessions undo as a unit) holds, and journey-2 typo-recovery is one keystroke away.

This story is the **final mutating-handler infrastructure** for Epic 2: it wires `undo_buffer` write hooks across all six FR45-stubbed handlers from Stories 2.8–2.12 (insert session via `enter_normal_mode`, `edits_delete_char`, `op_dd`, `op_compose_d / c / indent / dedent`, `op_indent_line / op_dedent_line`, `op_paste`) and introduces the new `undo.asm` module + the `'u'` dispatch entry that consumes the recorded entry. It closes FR45 + FR46 end-to-end and realises the journey-2 typo-recovery loop (`dd u`, `x u`, `i…Esc u`, `dw u`, `p u`, `cw…Esc u`).

The story is **architecturally significant** because it touches every mutating code site in `src/edits.asm` (and the `enter_normal_mode` exit point in `src/dispatch.asm`) without breaking any existing behaviour. The cross-cut shape is naturally amenable to a **shared undo-record helper** (3 entry points: insert, delete, replace) that amortises per-handler hook cost — the spec recommends this path for NFR9 economy.

## Acceptance Criteria

**AC1 — `undo.asm` module lands as the AR25-final production module.**

A new `src/undo.asm` module is added to the AR25 INCLUDE chain in `src/vibe.asm` between `fileio.asm` and `input_loop` (the long-planned slot per architecture.md:950 — `INCLUDE "undo.asm"` — completing AR25's documented final-module shape). The module owns:

- **Public entries** (per AR23 contract blocks):
  - `op_undo` — NORMAL-mode `u` handler (AC4).
  - `undo_record_insert` — record an inverse-delete entry (insert-session, paste — AC2).
  - `undo_record_delete` — record an inverse-insert entry with saved bytes (x, dd, dw, indent — AC2).
  - `undo_record_replace` — record a composed delete+insert entry (cw, ~ — AC2).
  - `undo_clear` — mark the entry as empty (called after `u` consumes — AC5).
- **Internal helpers**: `undo_replay_insert` / `undo_replay_delete` / `undo_replay_replace` (per-kind replay bodies routed by `op_undo`).
- **Module-owned state cells** declared in `inc/state.inc` extension (see AC3): `undo_kind`, `undo_position`, `undo_length`, `undo_aux_length` (the existing `undo_buffer` 256-byte slot from `state.inc:126` holds the saved bytes payload).
- **Module-header docstring** per AR23 listing all public entries, state owned (read/write), register conventions, and the dependencies block.

**AC2 — Undo entry record protocol — 3 kinds + shared record entry points.**

Define three undo-record entry kinds via new `inc/equates.inc` constants (clustered with the existing `KIND_CHAR / KIND_LINE / KIND_BLOCK` SR6 yank-register kinds):

```
UNDO_KIND_EMPTY        EQU 0x00    ; cold-start / post-u consumed — nothing to replay
UNDO_KIND_INSERT       EQU 0x01    ; inverse-op = delete (insert sessions, paste)
UNDO_KIND_DELETE       EQU 0x02    ; inverse-op = insert (x, dd, dw, indent)
UNDO_KIND_REPLACE      EQU 0x03    ; inverse-op = delete-then-insert (cw, ~)
UNDO_KIND_TOO_LARGE    EQU 0x04    ; recorded but exceeds payload capacity — replay refuses
```

Header layout in `state.inc` (5-byte header + 256-byte payload — total static cost grows by 5 B over the pre-2.13 baseline; `undo_buffer` already reserves the 256-B payload slot at `state.inc:126`):

```
undo_kind          ; 1 byte: UNDO_KIND_*
undo_position      ; 2 bytes: logical offset where the inverse op acts
undo_length        ; 2 bytes: bytes count
                   ;   INSERT: bytes the inverse-delete must remove
                   ;   DELETE: bytes the inverse-insert must re-insert (≤ undo_buffer payload size)
                   ;   REPLACE: bytes to remove (the new content)
undo_aux_length    ; 2 bytes: REPLACE-only — bytes to re-insert (the old content saved in payload)
undo_buffer        ; 256 bytes (existing): saved-content payload for DELETE / REPLACE; ignored for INSERT
```

`undo_aux_length` is a new 2-byte state cell added in this story. Layout fits cleanly after the existing 16-bit state block in state.inc (positional EQU; static_off advance +2 B). Document the layout in undo.asm's module header.

**Three shared record entry points (per AR23, all in `src/undo.asm`):**

```
undo_record_insert:
;   In:  BC = bytes-inserted; cursor (or insertion-start) computed by caller and passed via HL.
;   Out: undo_kind=UNDO_KIND_INSERT; undo_position=HL; undo_length=BC.
;        On BC == 0: undo_kind=UNDO_KIND_EMPTY (defensive — no-op shouldn't have called).
;   Trashes: A, F.

undo_record_delete:
;   In:  HL = delete-start (logical offset); BC = bytes-to-delete (= bytes that will be removed).
;   Out: On BC <= UNDO_PAYLOAD_SIZE (= UNDO_BUFFER_SIZE = 256):
;          undo_kind=UNDO_KIND_DELETE; undo_position=HL; undo_length=BC; BC bytes copied
;          from logical [HL, HL+BC) into undo_buffer.
;        On BC > UNDO_PAYLOAD_SIZE:
;          undo_kind=UNDO_KIND_TOO_LARGE (entry recorded but unreplayable; consistent with FR46).
;          undo_position / undo_length still written for diagnostics.
;          NO BYTES COPIED to undo_buffer (avoid partial-state).
;        On BC == 0: undo_kind=UNDO_KIND_EMPTY (defensive — caller-side 0-byte guard preferred).
;   Trashes: A, BC, DE, HL, F (motion_byte_at_logical loop trashes DE).
;   Calls:   motion_byte_at_logical (source bytes may straddle the gap; same shape as
;            edits_copy_to_yank's per-byte loop).

undo_record_replace:
;   In:  HL = op-start; BC = bytes-to-delete (the new-content range that the inverse must remove);
;        DE = bytes-to-reinsert (the old-content range saved in payload — must equal the value
;             passed to undo_record_delete-style copy below).
;        Caller must have copied DE bytes from the OLD content range into undo_buffer BEFORE
;        the buffer mutation happens (else the source bytes are gone). Story 2.13 hooks for
;        op_compose_c handle this via a two-phase pattern (see AC11).
;   Out: undo_kind=UNDO_KIND_REPLACE; undo_position=HL; undo_length=BC; undo_aux_length=DE.
;        On DE > UNDO_PAYLOAD_SIZE: undo_kind=UNDO_KIND_TOO_LARGE (consistent surface).
;   Trashes: A, F.
```

**Critical state-discipline pin (matches Story 2.10 / 2.11 / 2.12 pattern):** the record helpers MUST NOT trigger a buffer mutation or status emit; they only write the undo header + payload bytes via `LD`. The hook sites in `src/edits.asm` invoke them BEFORE any `gapbuf_delete` / `gapbuf_insert` call so the source bytes (for DELETE / REPLACE kinds) are still at their pre-mutation logical offsets.

**AC3 — Insert session record (B2 — insert sessions undo as a unit).**

**Given** I enter INSERT mode via `i` / `a` / `o` / `O` / `c+motion` (any path that lands in `mode_byte = MODE_INSERT`)
**When** I type N characters (including the net effect of any Backspace presses that delete bytes during the session) and press Esc
**Then** a SINGLE undo entry captures the entire session as one B2 unit:

**Recording mechanism (cleanest hook site per architecture):**

1. **At INSERT entry** (every code site that sets `mode_byte = MODE_INSERT`): save the entry cursor into a new module-owned cell `insert_session_entry_cursor` (declared in `src/edits.asm` as a module-local DEFW; not cross-module so it does NOT live in state.inc — same pattern as `motions_compose_entry` / `edits_indent_walk_mode/dirty`). Five INSERT entry sites to patch:
   - `enter_insert_mode` (src/dispatch.asm:289) — covers `i` (FR13), `edits_open_below` / `edits_open_above` / `edits_enter_insert_after` (FR25-27 transitively via `JP enter_insert_mode` tail), `op_compose_c` (FR39 transitively via `JP enter_insert_mode` tail).
   - **Implementation choice (recommended):** patch `enter_insert_mode` ITSELF — single hook site covers all five user-visible entry paths. Trade-off: also fires on a hypothetical `JP enter_insert_mode` from a future Story 3.x VISUAL-c — that's the correct behaviour for B2 (VISUAL c is still an insert session).

2. **At INSERT exit** (Esc / overflow): in `enter_normal_mode` (src/dispatch.asm:263) AND in `edits_overflow_to_normal` (src/edits.asm:646 — the `MODE_INSERT → MODE_NORMAL` path triggered by `edits_insert_literal` / `edits_insert_newline` on buffer-overflow):
   - Check `mode_byte` BEFORE the `LD A, MODE_NORMAL ; LD (mode_byte), A` write — if it was `MODE_INSERT`, this is an exit from an insert session.
   - Compute the **session net effect**: `bytes_inserted_net = exit_cursor - entry_cursor` (signed). If positive, N bytes were net-inserted at `entry_cursor`; if negative, N bytes were net-deleted (the user's net Backspaces exceeded their typed chars — possible if they entered INSERT, hit Backspace beyond the line, and exited).
   - **For session with `bytes_inserted_net > 0`**: `undo_record_insert(entry_cursor, bytes_inserted_net)` — the inverse-op is "delete `bytes_inserted_net` bytes at `entry_cursor`". This is the canonical case (vi: `i hello Esc u` removes "hello").
   - **For session with `bytes_inserted_net <= 0`**: this case is **out of MVP scope** per the simpler-is-cleaner pin. Either:
     - **Option A (recommended)**: record `undo_kind = UNDO_KIND_EMPTY` — `u` reports `msg_nothing_to_undo`. Simpler; user loses the "undo my net deletions" path but that path requires saving the deleted bytes which complicates the entry layout. Document as a vi-divergence in `undo.asm`'s contract block.
     - **Option B**: record as `UNDO_KIND_DELETE` with saved bytes — requires capturing the bytes at session entry (overkill for the rare case).

3. **Important: `enter_normal_mode` is called from several non-INSERT-exit contexts** (e.g. COMMAND / VISUAL → NORMAL via Esc). The `mode_byte == MODE_INSERT` check before the `MODE_NORMAL` write filters: only the INSERT → NORMAL transition triggers the record.

**Cursor delta computation guard:**
- `exit_cursor - entry_cursor` is a signed 16-bit subtraction. Use `OR A ; SBC HL, DE` and check CF — if CF=0 and HL > 0, net-inserted; if CF=0 and HL == 0, net-zero (record UNDO_KIND_EMPTY — user entered+exited with no net change); if CF=1, net-deleted (Option A: UNDO_KIND_EMPTY).
- **TOO_LARGE handling**: if `bytes_inserted_net > UNDO_PAYLOAD_SIZE` (256) — `undo_kind = UNDO_KIND_TOO_LARGE`. Note INSERT-kind does NOT save bytes (the inverse is a range-delete of [pos, pos+length); no source bytes needed), so the 256-B limit is conceptually unnecessary for INSERT. But: the **16-bit `undo_length` cell** has the actual upper bound of 65535 — well within the gap buffer's max (~32 KB). Pin: INSERT entries have no payload-size limit; only DELETE / REPLACE entries can exceed UNDO_PAYLOAD_SIZE.

**Recommended decision pin (Q2 — see Implementation Questions):** patch `enter_insert_mode` entry to save entry-cursor; patch `enter_normal_mode` + `edits_overflow_to_normal` exit to compute delta + record-insert. Net-deleted sessions land as UNDO_KIND_EMPTY (Option A).

**AC4 — `op_undo` body — NORMAL-mode `u` handler.**

New public entry in `src/undo.asm`:

```
op_undo:
;; 1. Read undo_kind. Branch:
;;    UNDO_KIND_EMPTY    → msg_nothing_to_undo + JP parser_clear (FR46 path).
;;    UNDO_KIND_TOO_LARGE → msg_undo_too_large + JP parser_clear (FR46 path).
;;    UNDO_KIND_INSERT   → undo_replay_insert (delete bytes at undo_position).
;;    UNDO_KIND_DELETE   → undo_replay_delete (re-insert undo_buffer payload at undo_position).
;;    UNDO_KIND_REPLACE  → undo_replay_replace (delete then re-insert).
;;    Other (defensive)  → msg_nothing_to_undo + JP parser_clear.
;;
;; 2. Replay sets cursor to undo_position (the "operation's start" per epic AC).
;; 3. On success: undo_clear (sets undo_kind := UNDO_KIND_EMPTY so a second `u`
;;    reports "nothing to undo" — single-level; consumed entry).
;; 4. buffer_dirty := 1 always after a successful replay (MVP simplification — see Q5).
;; 5. CALL edits_dirty_and_redraw + JP parser_clear.

;; In:      A = 'u' (MC4; ignored).
;; Out:     success — undo entry replayed; cursor at undo_position; buffer_dirty=1;
;;          all rows dirty; undo_kind := UNDO_KIND_EMPTY; parser cleared.
;;          empty/too-large — status set; buffer unchanged; cursor unchanged;
;;          buffer_dirty unchanged; parser cleared.
;; Trashes: A, BC, DE, HL, F.
;; Calls:   undo_replay_insert / undo_replay_delete / undo_replay_replace;
;;          status_set_message (empty / too-large); undo_clear (post-replay);
;;          edits_dirty_and_redraw (success); parser_clear (tail-JP every path).
```

**Replay bodies — `undo_replay_insert / undo_replay_delete / undo_replay_replace`:**

- **`undo_replay_insert`** (inverse of an INSERT entry — DELETE undo_length bytes at undo_position):
  - Stage cursor at `undo_position + undo_length`.
  - Loop `undo_length` times: `gapbuf_delete` (cursor-bounce shape from Story 2.10's `edits_range_delete`).
  - On `gapbuf_delete` CF=1 (BOF — shouldn't happen if the recorded length was correct): halt; status to `msg_undo_too_large` (defensive; corrupt-state safety net).
  - Post-loop: cursor at `undo_position`.

- **`undo_replay_delete`** (inverse of a DELETE entry — INSERT undo_length bytes from undo_buffer at undo_position):
  - Stage cursor at `undo_position`.
  - Loop `undo_length` times: `LD A, (DE)` from undo_buffer; `gapbuf_insert`; increment DE.
  - On `gapbuf_insert` CF=1 (buffer full): halt with partial restore + `msg_file_too_large` (gapbuf_insert sets it); buffer_dirty=1 + parser_clear. **Partial restore is acceptable per FR52** — same shape as op_paste's partial-paste path. Document the divergence (in vi, undo never fails; here it can fail if the buffer is at capacity).
  - Post-loop: cursor at `undo_position + undo_length` — but per epic AC ("cursor returns to a sensible position, typically the operation's start"), DEC cursor back to `undo_position` (or, more precisely, set cursor := undo_position; matches what the original deleted-position cursor was). Pin: cursor := undo_position (NOT the post-insert position).

- **`undo_replay_replace`** (inverse of a REPLACE entry — DELETE undo_length new-content bytes, then INSERT undo_aux_length old-content bytes from undo_buffer, all at undo_position):
  - Stage cursor at `undo_position + undo_length` (after the new-content range).
  - Phase 1 — `undo_replay_insert`-shape: delete `undo_length` bytes (the new content from the cw operation).
  - Phase 2 — `undo_replay_delete`-shape: insert `undo_aux_length` bytes from undo_buffer (the saved old content).
  - Post-replay: cursor := undo_position.
  - On any CF=1 mid-replay: halt with partial state + status surface. **Partial REPLACE is messier than partial INSERT/DELETE** because two phases can each fail. Document trade-off: on any failure, the buffer is in a transient state; user gets the file_too_large banner; user can `:e!` to reload or `:w name.bak` to salvage.

**`undo_clear` helper:**

```
undo_clear:
;;   In:  (none).
;;   Out: undo_kind := UNDO_KIND_EMPTY. Other undo state cells left as-is (cheaper
;;        than full zero-fill; reads of undo_position / _length on UNDO_KIND_EMPTY
;;        path are by-construction skipped — op_undo's kind dispatch branches at
;;        the kind read).
;;   Trashes: A, F.
```

**State-discipline pin:** `op_undo` MUST end with `JP parser_clear` (not bare RET) — matches every NORMAL-mode handler (Story 2.5 AC13). A count from `5u` is ignored (single-level undo; counted-undo is not in MVP per AC6) and parser_clear consumes it for free.

**AC5 — Empty / too-large / second-u paths (FR46).**

**Given** the undo entry is `UNDO_KIND_EMPTY` (cold-start state, OR a previous `u` consumed the entry)
**When** I press `u` in NORMAL mode
**Then** `status_set_message msg_nothing_to_undo` (existing string at `src/statusln.asm:223`); buffer + cursor + buffer_dirty UNCHANGED; parser cleared.

**Given** the undo entry is `UNDO_KIND_TOO_LARGE`
**When** I press `u`
**Then** `status_set_message msg_undo_too_large` (existing string at `src/statusln.asm:222`); buffer + cursor + buffer_dirty UNCHANGED; parser cleared. **`undo_kind` is NOT cleared** — a second `u` shows the same message (the entry is "still there" but unreplayable; alternative: clear after surfacing — pin in Q4).

**Given** undo of undo (`u u`)
**When** the second `u` arrives
**Then** per architecture (PRD §Undo "Undo of undo (`u u`): not in MVP; flagged for later reconsideration") and epic AC ("second `u` is a no-op or shows nothing to undo"): the SECOND `u` reads `undo_kind = UNDO_KIND_EMPTY` (the first `u` cleared it via `undo_clear`) and shows `msg_nothing_to_undo`. Pin: cleared-after-consume is the chosen semantic.
**And** a comment in `src/undo.asm`'s module header documents "u-of-u is Growth-tier; the cleared-after-consume semantic is the MVP shape" (matches epic spec line 1469-1470).

**AC6 — Cursor placement on replay + buffer_dirty semantics.**

**Cursor placement (matches epic AC: "cursor returns to a sensible position, typically the operation's start offset"):** cursor := `undo_position` on every successful replay path (INSERT / DELETE / REPLACE). This is vi-faithful for the common cases (`x u` → cursor lands where the deleted byte was; `dd u` → cursor at start of restored line; `i hello Esc u` → cursor at the position where INSERT entered; `dw u` → cursor at the word's pre-delete start).

**`buffer_dirty` recomputation:** the epic AC says "buffer_dirty is recomputed (if undo restores the buffer to its last-saved state, dirty becomes 0; otherwise stays nonzero)". **MVP pin (Q5):** `buffer_dirty := 1` after a successful undo. Rationale: tracking the last-saved-state hash would cost ~40-60 B (snapshot at `:w` success + compare after undo) — significant under NFR9 pressure. Document the vi-divergence: in MVP, undoing an operation that takes the buffer back to its just-saved state still leaves it marked dirty; user can `:w` again to clear the flag (idempotent on identical content). Growth-tier polish.

**All rows dirty:** `CALL edits_dirty_and_redraw` (existing Story 2.8 helper at src/edits.asm:621) — sets `buffer_dirty=1` AND tail-JPs `render_mark_all_dirty`. The replay potentially touches multiple rows (an inserted LF shifts subsequent rows; a deleted multi-line range collapses rows); conservative all-dirty marking is correct + cheap.

**AC7 — Hook sites — all 6 mutating handlers in `src/edits.asm` write undo before mutating.**

The dev pass replaces every "FR45 undo recording: STUB" comment block in `src/edits.asm` with a real undo-record call. Each hook site is documented in the existing STUB comment with the exact insertion point:

**1. `edits_delete_char` (Story 2.9 `x` / `Nx`)** — hook at `.commit:` label (src/edits.asm:824 — AFTER the deletes-done check at `.exit_loop`, BEFORE `CALL edits_dirty_and_redraw`).
- Inverse-op: re-insert the deleted bytes.
- Capture: BEFORE the cursor-bounce loop (lines 786-804), save the bytes that WILL be deleted into `undo_buffer`. **Hard part:** the cursor-bounce loop deletes one byte per iter; capturing requires a pre-loop walk that copies the about-to-be-deleted bytes into `undo_buffer`.
- **Implementation shape:** add a pre-loop block that walks the same loop bounds (count + LF/EOF clamps), copying `motion_byte_at_logical(cursor + k)` to `undo_buffer + k` for k=0..deletes_planned-1; then call `undo_record_delete(cursor, deletes_planned)`. The planned-count must equal the actual count after the loop (the LF/EOF clamp could end the loop early — the planned-walk has to use the same clamp).
- **Simpler alternative:** do the cursor-bounce delete loop as currently, BUT capture each byte's value into `undo_buffer` JUST BEFORE the `CALL gapbuf_delete` (via `motion_byte_at_logical(cursor)` peek). Add a counter; at `.commit` call `undo_record_delete(original_cursor, counter)`.
- **Pin (recommended):** the "capture at each iter" alternative — cheaper (no pre-loop walk), uses the bytes-deleted counter that already lands in HL at `.exit_loop` (line 808's `HL = N - BC = deletes_done`). Code path: each iter writes A=byte_under_cursor to `undo_buffer + iter_index` before `gapbuf_delete`; at `.commit`, deletes_done is in HL; call `undo_record_delete(original_cursor, deletes_done)`. ~12-16 B per hook site after factoring.

**2. `op_dd` (Story 2.10 `dd` / `Ndd`)** — hook at the existing "(Story 2.13 FR45 undo hook site: HERE — before edits_copy_to_yank...)" comment (src/edits.asm:1085-1087).
- Inverse-op: re-insert the deleted line(s).
- The bytes are still at their pre-delete logical positions when this hook fires.
- **Implementation:** call `undo_record_delete(delete_start, total_bytes)` — the helper reads bytes via `motion_byte_at_logical` into `undo_buffer`. The 1024-B yank may overflow undo's 256-B payload (a 100-line delete with avg-3-char lines = 400 B → over capacity); `undo_record_delete` writes `UNDO_KIND_TOO_LARGE` and the deletion still proceeds. NO `msg_undo_too_large` SURFACE at record time — surfacing happens only when `u` is pressed (epic AC line 1463-1464). The yank-too-large status (if it also fired) wins the status banner.
- **State-discipline:** `undo_record_delete` reads `(cursor_offset)` ? — NO. The helper takes HL=position + BC=length explicitly. Position = `delete_start` (from `edits_line_range_for_count`); length = `total_bytes` (BC at that point). Push/pop the registers around the call to preserve them for the subsequent `edits_copy_to_yank` + `edits_range_delete` calls.

**3. `op_compose_d` (Story 2.11 `d` + motion)** — hook at "Yank-copy attempt (Story 2.13 FR45 undo hook site: HERE...)" comment (src/edits.asm:1367-1368).
- Same shape as op_dd's hook. Call `undo_record_delete(range_start, range_bytes)` BEFORE `edits_copy_to_yank`.
- Note: `op_compose_d`'s range may be up to ~32 KB (e.g. `dG` from line 1 on a max-buffer file). Most cases will exceed UNDO_PAYLOAD_SIZE for whole-buffer deletes → UNDO_KIND_TOO_LARGE. Document this as the expected user experience (mass deletes are unrecoverable in MVP — same single-level-undo limitation as vi).

**4. `op_compose_c` (Story 2.11 `c` + motion)** — TWO-PHASE REPLACE hook.
- **Phase 1 (in `op_compose_c` BEFORE `edits_copy_to_yank`)**: save the OLD content (about-to-be-deleted bytes) by calling `undo_record_delete(range_start, range_bytes)` — this writes UNDO_KIND_DELETE with the old bytes in `undo_buffer`. The kind will be UPGRADED to REPLACE at INSERT-session-exit.
- **Phase 2 (at INSERT exit via `enter_normal_mode`)**: the standard insert-session record runs (per AC3) and would normally call `undo_record_insert`. **But** the previous `undo_kind` is already UNDO_KIND_DELETE — the exit-record needs to check this and UPGRADE the entry to UNDO_KIND_REPLACE:
  - Read current `undo_kind`; if `UNDO_KIND_DELETE`, this is a c+motion REPLACE in progress.
  - Compute `bytes_inserted_net = exit_cursor - entry_cursor` (where entry_cursor was the post-c-delete cursor position = range_start).
  - Call `undo_record_replace(range_start, bytes_inserted_net, original_delete_length)`. The `original_delete_length` was stashed in `undo_length` by phase 1 — read it back; pass as DE. Phase 1's payload bytes (saved at `undo_buffer`) are NOT touched by phase 2.
  - **Critical:** if phase 1 wrote UNDO_KIND_TOO_LARGE (delete range too big), phase 2 still upgrades to REPLACE with TOO_LARGE-flagged behaviour — but the payload bytes are NOT in `undo_buffer`. Simplest: keep the kind as UNDO_KIND_TOO_LARGE; the REPLACE-upgrade is skipped. Document this corner.
- **Recommended pin (Q3):** the "phase 1 + phase 2 upgrade at exit" pattern. Costs ~25-35 B over phase 1 alone but realises journey-2 `cw word Esc u` (restore the original word).
- **Alternative**: defer REPLACE to a Growth-tier story; `cw` records as DELETE only (the new content stays, undo restores the old content prepended — produces "old-content + new-content" instead of just "old-content"). User confusion. **Strongly recommend full REPLACE**.

**5. `op_compose_indent` / `op_compose_dedent` / `op_indent_line` / `op_dedent_line` (Story 2.11 `>` / `<` / `>>` / `<<`)** — hook BEFORE `CALL edits_indent_walk` (src/edits.asm:1580 / 1639 / 1687 / 1729).
- Inverse-op: for indent → dedent (delete the inserted INDENT_BYTE at each affected line-start); for dedent → indent (re-insert INDENT_BYTE at each affected line-start).
- **Hard part**: the walk affects N lines (potentially many); each line gets 1 byte inserted (indent) or 0/1 byte deleted (dedent). The inverse-op is N separate line-mutations.
- **Implementation shape options:**
  - **Option A (recommended; encode as a single DELETE / INSERT range)**: the inverse mutation is "remove 1 INDENT_BYTE from each line in the affected range". Encode as a custom undo kind? OR — simpler — encode the FULL line-range BEFORE the indent walk into the payload (saves the entire pre-walk content of the affected lines), record as `UNDO_KIND_REPLACE(promoted_start, post_walk_bytes, pre_walk_bytes)`. Undo replays as: delete the post-walk lines, re-insert the pre-walk lines. **Expensive** in payload bytes (the entire line range is saved — quickly exceeds 256 B for any non-trivial indent).
  - **Option B**: dedicated `UNDO_KIND_INDENT_WALK` / `UNDO_KIND_DEDENT_WALK` kinds with payload = (start, end, mode) and replay = "walk every line in [start, end), apply the inverse op". Costs +2 new kinds + 2 new replay bodies; +~40-60 B in undo.asm.
  - **Option C (recommended pin; Q6)**: do NOT record undo for indent/dedent ops in Story 2.13 MVP. Document as a Growth-tier addition. User can manually re-dedent / re-indent. Saves ~80-120 B of payload-encoding complexity + 2 new kinds. The 6th-handler FR45 stub for indent ops becomes a "deferred to Growth" entry; the OTHER 5 hooks (insert-session, x, dd, dw/cw, paste) close FR45 for the journey-2-load-bearing typo-recovery flows.
- **Pin (Q6 — recommended Option C)**: skip indent/dedent undo in MVP; document. NFR9 savings ~80-120 B + simpler `undo.asm`.

**6. `op_paste` (Story 2.12 `p` / `Np`)** — hook at the existing "FR45 undo recording: STUB for Story 2.12. The hook site for Story 2.13 is in edits_paste_yank_bytes, AFTER the loop completes..." comment (src/edits.asm:1926-1929).
- Inverse-op: delete the inserted-by-paste bytes.
- Hook site: AT op_paste's `.commit:` label (src/edits.asm:2148), BEFORE `CALL edits_dirty_and_redraw`. At that point: insertion-start (for KIND_CHAR: pre-paste advance position; for KIND_LINE: entry_cursor's line-end + 1) is implicit in the cursor delta — but the cursor has already been DEC'd to "last byte of inserted range" by then.
- **Implementation shape:** compute insertion_start and inserted_length and call `undo_record_insert(insertion_start, inserted_length)`. The math:
  - For KIND_CHAR: `inserted_length = (current_cursor + 1) - pre_paste_cursor` (cursor was DEC'd to last byte; pre_paste_cursor was saved on stack at lines 2027-2030 — see `.pc_partial` path). **Easier:** stash the bytes-inserted count separately as a module-local DEFW (`edits_paste_bytes_inserted`) at the helper's exit; read it at `.commit`. ~3 B for the stash + ~3 B for the read.
  - For KIND_LINE: similar — bytes inserted = `cursor_after_count_loop - entry_cursor's_line_end_+_1`. Stash as the same DEFW.
- Note: paste partial-paste (`.pc_partial` / `.pl_partial` branches) DO commit via `.commit` (some bytes landed); they record undo too (for what got inserted). The bypass paths (zero-bytes-landed) skip `.commit` (already do) and don't record.

**Cross-cut state-discipline summary:** every hook site records BEFORE the mutating gapbuf primitive. The record helpers do NOT touch cursor_offset / mode_byte / pending_* / count_* state. parser_clear at handler tail-JP cleans up parser state as before.

**AC8 — Dispatch binding for `'u'`.**

`src/dispatch.asm` `dispatch_normal` table gains one new entry:
```
DEFB    'u'                         ; 'u' — single-level undo (FR45, Story 2.13)
DEFW    op_undo
```
Inserted in **sorted-ascending key order between `'p'` (0x70 → `op_paste`) and `'v'` (0x76 → `enter_visual_mode`)** — see existing entries at src/dispatch.asm:552-555. The ASSERT bracket follows the pattern: drop `ASSERT 'v' > 'p'` (line 555) and replace with `ASSERT 'u' > 'p'` + `ASSERT 'v' > 'u'`. `DISPATCH_NORMAL_COUNT` auto-recomputes 34 → 35.

`op_undo` is forward-referenced from dispatch.asm; resolved via sjasmplus's two-pass model (undo.asm INCLUDEs AFTER dispatch.asm per AR25). Same forward-reference pattern as `op_paste` from Story 2.12.

**AC9 — Counted `u` ignored (single-level — no `Nu`).**

**Given** I press `5u` in NORMAL mode
**When** dispatched
**Then** `op_undo` ignores the count (single-level undo; counted-undo is multi-level which is Growth-tier per architecture.md:416). Effective behaviour: same as bare `u` — replay one entry. `parser_clear` consumes the count for free at handler tail-JP.

**Pin** in `op_undo`'s contract block: "count_accumulator is ignored; `Nu` behaves identically to `u`".

**AC10 — Status surface conventions (AR12 + AR16).**

- **Empty undo** (`UNDO_KIND_EMPTY`): `msg_nothing_to_undo` (existing — src/statusln.asm:223).
- **Too-large undo** (`UNDO_KIND_TOO_LARGE`): `msg_undo_too_large` (existing — src/statusln.asm:222).
- **Successful replay**: silent. The visible buffer change IS the success signal (matches every other mutating op — `dd` / `dw` / `p` are all silent on success).
- **Replay overflow** (UNDO_KIND_DELETE / REPLACE replay hits gapbuf_insert CF=1 mid-replay; buffer at capacity): `msg_file_too_large` (set automatically by gapbuf_insert per its contract); replay halts at partial state; buffer_dirty=1; parser cleared. Documented divergence from vi (vi's undo is infallible).

**Critically:** the empty / too-large status messages are SURFACED ONLY WHEN `u` IS PRESSED — not when the entry is recorded (epic AC line 1442-1444 + 1462-1464). Recording a TOO_LARGE entry is silent at record time; the user finds out when they try to use it. Rationale: per-mutation status surface would be noisy on a normal-typing session.

**AC11 — Headless tests (canonical list per epic AC line 1476).**

All under `test/cases/undo_*.asm`. Sentinel allocation per test in the 0xC0..0xDF band (next free after Story 2.12's 0x90..0xB9 + 0xE1..0xE6); parser-driven dispatch tests in 0xE7..0xEC.

**Canonical (epic spec line 1476 — all 6 MUST land):**

- **`undo_x-restores-byte.asm`** — Pre-load `"abc"` (3 B), cursor=1 (on 'b'), buffer_dirty=0. Pre-seed `undo_kind=UNDO_KIND_EMPTY`. CALL `edits_delete_char` (simulates `x`); assert buffer = `"ac"`, cursor=1, undo_kind=UNDO_KIND_DELETE, undo_position=1, undo_length=1, undo_buffer[0]='b'. THEN CALL `op_undo`; assert buffer = `"abc"`, cursor=1, buffer_dirty=1, undo_kind=UNDO_KIND_EMPTY (consumed); parser cleared. (Pins: x → u round-trip; canonical journey-2 typo-recovery.)

- **`undo_dd-restores-line.asm`** — Pre-load `"abc\ndef\n"` (8 B), cursor=0, count_accumulator=0. Pre-seed undo_kind=UNDO_KIND_EMPTY. CALL `op_dd`; assert buffer = `"def\n"` (4 B), cursor=0, undo_kind=UNDO_KIND_DELETE, undo_position=0, undo_length=4, undo_buffer[0..3]="abc\n". THEN CALL `op_undo`; assert buffer = `"abc\ndef\n"`, cursor=0, buffer_dirty=1, undo_kind=UNDO_KIND_EMPTY. (Pins: dd → u round-trip; line-granularity.)

- **`undo_insert-session-as-unit.asm`** — Pre-load `"hello"` (5 B), cursor=5 (past 'o'), mode=MODE_NORMAL. CALL `enter_insert_mode` (saves entry_cursor=5); CALL `edits_insert_literal` 3 times with A='X', 'Y', 'Z' (cursor advances 5→6→7→8; buffer = "helloXYZ" 8 B). CALL `enter_normal_mode` (Esc); assert undo_kind=UNDO_KIND_INSERT, undo_position=5, undo_length=3. CALL `op_undo`; assert buffer = "hello", cursor=5, undo_kind=UNDO_KIND_EMPTY. (Pins: B2 single-undo-entry-per-session; the entire insert session undoes as a unit.)

- **`undo_capacity-refusal.asm`** — Pre-load a buffer with a 300-byte line (300 'A's + LF; total 301 B). cursor=0. CALL `op_dd`; assert buffer empty, undo_kind=UNDO_KIND_TOO_LARGE (delete length 301 > UNDO_PAYLOAD_SIZE 256), undo_position=0, undo_length=301 (recorded for diagnostics; payload bytes NOT copied). CALL `op_undo`; assert buffer still empty (replay refused), status_buffer prefix = "undo not possible" (msg_undo_too_large), parser cleared, undo_kind remains UNDO_KIND_TOO_LARGE (per Q4 — surfacing does NOT clear). (Pins: FR46 capacity refusal; epic AC line 1462-1464.)

- **`undo_nothing-to-undo.asm`** — Pre-load `"abc"`, cursor=0, undo_kind=UNDO_KIND_EMPTY (cold-start state). CALL `op_undo`; assert buffer unchanged, cursor=0, buffer_dirty=0, status_buffer prefix = "nothing to undo" (msg_nothing_to_undo), parser cleared. (Pins: FR46 nothing-to-undo path.)

- **`undo_buffer-dirty-recomputes.asm`** — Per epic AC line 1460 ("buffer_dirty recomputes"). **MVP simplification per Q5: buffer_dirty stays 1 after undo.** Test name kept (epic spec) but body asserts the MVP semantic: pre-load `"abc"`, cursor=1, buffer_dirty=0; CALL `edits_delete_char`; assert buffer_dirty=1. CALL `op_undo`; **assert buffer_dirty=1** (NOT 0 — see Q5 pin in Implementation Questions: MVP doesn't recompute against last-saved state). Test docstring documents the MVP divergence from epic AC.

**Additional tests (edge cases + dispatch coverage):**

- **`undo_dw-restores-word.asm`** — Pre-load `"hello world"` (11 B), cursor=0. Simulate `dw` via direct `op_compose_d` call with pending_operator='d', motions_compose_entry=0, cursor_offset=6 (post-w-motion); pending_motion_inclusive=0. CALL `op_compose_d`; assert buffer="world", undo_kind=UNDO_KIND_DELETE, undo_length=6, undo_buffer[0..5]="hello ". CALL `op_undo`; assert buffer="hello world", cursor=0. (Pins: dw → u; compose-d hook site.)

- **`undo_p-removes-paste.asm`** — Pre-load `"abc"` (3 B), cursor=0. Pre-seed yank: KIND_CHAR, length=2, content="XY". CALL `op_paste`; assert buffer="aXYbc" (5 B), cursor=2 (on 'Y'), undo_kind=UNDO_KIND_INSERT, undo_position=1, undo_length=2. CALL `op_undo`; assert buffer="abc", cursor=1 (= undo_position), buffer_dirty=1. (Pins: paste → u; KIND_CHAR.)

- **`undo_cw-replace.asm`** — Pre-load `"hello world"` (11 B), cursor=0. Two-phase: (1) Pre-seed pending_operator='c', motions_compose_entry=0, cursor_offset=6 (post-w); CALL `op_compose_c`. Buffer becomes "world" (5 B); mode=MODE_INSERT; undo_kind=UNDO_KIND_DELETE, undo_position=0, undo_length=6, undo_buffer[0..5]="hello ". (2) Simulate user typing "BIG " via 4× edits_insert_literal: buffer = "BIG world" (9 B); cursor=4. (3) CALL `enter_normal_mode`. Assert undo_kind=UNDO_KIND_REPLACE, undo_position=0, undo_length=4 (new content len), undo_aux_length=6 (old content len), undo_buffer[0..5]="hello ". (4) CALL `op_undo`; assert buffer="hello world", cursor=0, undo_kind=UNDO_KIND_EMPTY. (Pins: c+motion → INSERT session → Esc → u; the REPLACE two-phase upgrade per AC7 hook 4 + Q3.)

- **`undo_insert-after-backspace-net-zero.asm`** — Pre-load `"abc"` (3 B), cursor=3. CALL `enter_insert_mode` (entry_cursor=3). CALL `edits_insert_literal` A='X' (buffer="abcX"; cursor=4). CALL `edits_insert_backspace` (buffer="abc"; cursor=3). CALL `enter_normal_mode`. Assert undo_kind=UNDO_KIND_EMPTY (per Q2 pin: net-zero session records empty). CALL `op_undo`; assert buffer="abc" unchanged, status_buffer prefix = "nothing to undo". (Pins: Q2 Option A — net-zero insert session is unrecoverable; documented vi-divergence.)

- **`undo_5x-counted.asm`** — Pre-load `"abcdef"` (6 B), cursor=0. Pre-seed count_accumulator=5. CALL `edits_delete_char`; assert buffer="f" (1 B), cursor=0, undo_kind=UNDO_KIND_DELETE, undo_length=5, undo_buffer[0..4]="abcde". CALL `op_undo`; assert buffer="abcdef", cursor=0. (Pins: counted x → u; deletes_done in HL captured per AC7 hook 1 pin.)

- **`undo_3dd-counted.asm`** — Pre-load `"a\nb\nc\nd\n"` (8 B), cursor=0, count_accumulator=3. CALL `op_dd`; assert buffer="d\n", undo_kind=UNDO_KIND_DELETE, undo_length=6, undo_buffer[0..5]="a\nb\nc\n". CALL `op_undo`; assert buffer="a\nb\nc\nd\n". (Pins: Ndd → u.)

- **`undo_too-large-then-x.asm`** — Pre-load a 300-B-no-LF buffer, cursor=0, count=0. CALL `op_dd`; assert undo_kind=UNDO_KIND_TOO_LARGE. THEN cursor=0 (file empty now; manually reset), pre-load `"abc"` and cursor=1. CALL `edits_delete_char`; assert undo_kind=UNDO_KIND_DELETE (the prior TOO_LARGE is OVERWRITTEN — single-slot). CALL `op_undo`; assert buffer="abc" (the x-undo replays correctly; the TOO_LARGE was discarded). (Pins: single-slot semantics — second mutation overwrites first; TOO_LARGE doesn't persist past the next mutation.)

- **`undo_consumed-then-u-again.asm`** — Pre-load `"abc"`, cursor=1, undo_kind=UNDO_KIND_EMPTY. CALL `edits_delete_char` (records UNDO_KIND_DELETE 'b'). CALL `op_undo` (buffer="abc"; undo_kind=UNDO_KIND_EMPTY). CALL `op_undo` AGAIN; assert buffer unchanged, status_buffer prefix = "nothing to undo". (Pins: u-of-u semantic per AC5 + epic AC line 1467-1470.)

- **`parser_u-dispatch.asm`** — drive the full parser chain: pre-load `"abc"`, mode=MODE_NORMAL, cursor=1. Pre-seed undo as a DELETE entry (kind=UNDO_KIND_DELETE, position=1, length=1, undo_buffer[0]='b', simulating a prior `x`). Buffer pre-seeded to `"ac"` to match the post-x state. CALL `dispatch_key` with HL=`dispatch_normal`, B=DISPATCH_NORMAL_COUNT, A='u'. Assert dispatch routes to op_undo; buffer = "abc" (3 B); cursor=1; buffer_dirty=1; undo_kind=UNDO_KIND_EMPTY; parser cleared (count_accumulator + pending_operator + pending_motion_prefix + pending_motion_inclusive all 0). (Pins: AC8 dispatch wiring + AC4 success path through the dispatcher.)

- **`parser_5u-dispatch.asm`** — drive the full parser chain with a count: pre-load same as parser_u-dispatch.asm. CALL `parser_handle_digit` with A='5'; CALL dispatch_key with A='u'. Assert: same as parser_u-dispatch but additionally `count_accumulator==0` post-dispatch (consumed/ignored per AC9). (Pins: AC9 counted-u-ignored.)

**Test count target: 6 canonical + 9 additional = ~15 new tests.** Sentinel allocation: 0xC0..0xDF (32 slots for ~25 sub-assertions across the 13 tests; well-bounded) and 0xE7..0xE8 for the 2 parser-dispatch tests. Verify by `grep` against existing test/cases for the lowest unused codes before assigning.

**AC12 — Build invariants (NFR9, NFR18, AR sweeps).**

- `make all` followed by `make clean && make all` produces a byte-identical `vibe.com` (NFR18).
- `make test` from a fresh `make clean && make test` is green (post-2.12 baseline ~178 pass / 1 deliberate-fail; post-2.13 ~193 pass / 1 fail; ~15 new tests).
- AR13 / AR14 / AR15 grep sweeps clean for `src/undo.asm`:
  - **AR13** (no screen emission): undo.asm has zero BIOS_CONOUT references; replay paths route through `edits_dirty_and_redraw` → `render_mark_all_dirty` (existing helpers).
  - **AR14** (gap-buffer mutation only via gapbuf primitives): undo_replay_insert / undo_replay_delete call only `gapbuf_delete` / `gapbuf_insert`; no raw gap_start/gap_end writes. The `CALL gapbuf_insert` count in undo.asm = N (one per replay-insert site); `CALL gapbuf_delete` count = N (one per replay-delete site). Both AR14-compliant.
  - **AR15** (no raw BDOS): undo.asm has zero BDOS_CALL references.
- AR sweep for `src/edits.asm` + `src/dispatch.asm`: the hook-site additions add new `CALL undo_record_*` sites; verify these resolve via sjasmplus two-pass model (undo.asm INCLUDEs AFTER both edits.asm and dispatch.asm per AR25).
- AR23: every public entry in undo.asm has a 4-line `In: / Out: / Trashes: / Calls:` contract block. The module header lists Public / State owned / Register conventions / Dependencies blocks per the existing module pattern.
- AR25 INCLUDE chain in `src/vibe.asm`: `... fileio.asm → undo.asm → input_loop`. **First story to add a new module to the AR25 chain since the chain stabilised** (per architecture.md:950, undo.asm has always been the planned final module).
- `dispatch_normal` count grows 34 → 35 (the new `'u'` entry). MC3 binary-search worst-case unchanged (35 entries = 6 iterations worst case, same as 34).
- `dispatch_insert` / `dispatch_command` / `dispatch_visual` tables unchanged.

**NFR9 projection (the critical budget question):** post-2.12 footprint = 5603 B / 97.5% of 5760 B / **157 B headroom**. Story 2.13 adds:

- **`src/undo.asm` module body**: `op_undo` (~50-70 B) + `undo_record_insert` (~15-25 B) + `undo_record_delete` (~50-70 B incl. per-byte motion_byte_at_logical loop) + `undo_record_replace` (~20-30 B) + `undo_replay_insert` (~30-40 B) + `undo_replay_delete` (~40-60 B) + `undo_replay_replace` (~50-70 B) + `undo_clear` (~5 B) + module-header docstring (no bytes). **Estimated total module body: ~260-370 B.**
- **Hook-site additions in `src/edits.asm`**: 5 hook sites (per Q6 Option C — indent/dedent ops skip undo); each site ~6-12 B for the PUSH/POP + `CALL undo_record_*`. **Estimated total hook-site cost: ~30-60 B.**
- **`enter_insert_mode` patch** (src/dispatch.asm): save entry_cursor to module-local DEFW. ~6-8 B + 2 B storage.
- **`enter_normal_mode` patch** (src/dispatch.asm): check MODE_INSERT, compute delta, call undo_record_insert. ~20-30 B.
- **`edits_overflow_to_normal` patch** (src/edits.asm:646): same shape as enter_normal_mode patch — but this path is INSERT → NORMAL on overflow. Compute delta, record. ~15-20 B (or share with enter_normal_mode via a helper).
- **`dispatch_normal` 'u' entry**: +3 B (DEFB + DEFW).
- **`inc/state.inc` extension**: `undo_kind`, `undo_position`, `undo_length`, `undo_aux_length` new cells (1+2+2+2 = 7 B static). `undo_buffer` already reserved (256 B); no growth there.
- **`inc/equates.inc` extension**: 5 new UNDO_KIND_* EQUs + UNDO_PAYLOAD_SIZE alias (0 bytes — EQUs only).

**Total projected delta: ~340-490 B.** Pre-2.13 headroom = 157 B → projected post-2.13 footprint = **5943-6093 B = 103.2%-105.8% of 5760 B**. **OVER by ~183-333 B** (~3.2-5.8% over).

**Three escalation paths (Q1 — see Implementation Questions; matches Story 2.11 + 2.12 Option A/B/C pattern):**

- **Option A (recommended) — Formal NFR9 amend to 6144 B (~+384 B over current 5760).** Same shape as the Story 2.12 amend (5120 → 5760 B). Update PRD §NFR9 (line 848: amend-history block adds "amended 2026-05-XX from 5760 B to 6144 B") and architecture.md in the same 5 callsites (§Pillar 47 / line 200 / line 305 / line 735 / line 1334). TPA fit (NFR10) holds: static_end (+7 B from this story's state cells) + GAP_BUFFER_MAX (32768) + YANK_BUFFER_SIZE (1024) + undo_buffer (256, in static_data) + 6144 B code = well under 0xD800 = 55040 B. **Closes FR45 + FR46 cleanly + matches every prior Epic 2 story's "ship full scope, amend if needed" pattern.**

- **Option B — Defer the REPLACE kind (cw undo) to a Growth-tier story.** Save ~50-70 B in undo.asm (undo_record_replace + undo_replay_replace) + ~25-35 B in the op_compose_c hook (no two-phase upgrade). Net ~75-105 B. `cw word Esc u` becomes "u restores the original word AND the new content stays" → user confusion. **Strongly recommend against.**

- **Option C — Defer single-byte `x` undo to a Growth-tier story.** Save ~25-40 B in edits_delete_char's hook (the per-iter byte-capture). User loses `x u` typo recovery (journey-2 hot path). **Strongly recommend against** — `x u` is the canonical journey-2 example (PRD line 245).

- **Option D (orthogonal cost reduction) — Share an `undo_record_op` helper for the 5 mutating edit hooks** that takes a kind + position + length argument; the per-call-site cost drops from ~12 B to ~6 B. Saves ~30 B across 5 hooks. ALSO viable in combination with Option A.

**Decision: ASK ANT before dev pass starts.** Recommended: Option A formal NFR9 amend to 6144 B + Option D shared helper. Net projected footprint: ~5900-6020 B / ~96-98% of new 6144 B ceiling / ~125-245 B headroom (post-Story-2.13; the final Epic-2 story, so this is the closing-budget question).

- **`buffer_dirty` write count:** Story 2.13 adds 1 success-path writer (op_undo's tail via `edits_dirty_and_redraw`).
- **Yank register write count:** Story 2.13 adds 0 writers. (undo does not interact with the yank register.)
- **Undo register write count:** Story 2.13 introduces the undo register — 5 writers (the 5 mutating handlers from Q6 Option C: edits_delete_char, op_dd, op_compose_d, op_compose_c, op_paste — plus the insert-session-exit recorder; indent/dedent skipped per Q6) + 1 clearer (op_undo's `undo_clear` post-replay). Documented in undo.asm's module header per AR23.

**AC13 — Hardware UAT on real MicroBeast (deferred to Ant — same pattern as Stories 2.1-2.12; per memory `feedback_uat_inline_at_dev_handoff.md`).**

The dev MUST NOT mark this story `done` without confirmed hardware UAT by Ant. Hardware UAT script (12 steps; covers the load-bearing journey-2 typo-recovery flows for FR45 + FR46):

1. **Pre-state:** boot fresh, no prior `vibe` invocation. Push `vibe.com` to the MicroBeast via SLIDE / `make push`.
2. **`vibe newgame.fs`** (or any pre-existing multi-line file). Status confirms `loaded` count + mode `-- normal --` + cursor at offset 0. Hit `$a` to land cursor at EOF (per memory: post-`:e` cursor lands at offset 0 — vi-faithful — so `i` from BOF inserts BEFORE existing content; use `$a` to append at EOF).
3. **`u` from cold-start** (no prior edit since `:e`): status shows `nothing to undo`. Buffer unchanged. (Pins AC5 empty-undo cold-start path.)
4. **Hit `i`, type `hello`, press Esc, then press `u`** — the typed "hello" disappears; cursor returns to where INSERT started. Status silent. (Pins AC3 + B2 insert-session-as-unit.)
5. **Navigate to any line, press `dd`, then press `u`** — the deleted line reappears at its original position; cursor at start of restored line. (Pins AC7 hook 2: op_dd → u.)
6. **Navigate to mid-line; press `x`; press `u`** — the deleted byte reappears at its original position; cursor at undo_position. (Pins AC7 hook 1: edits_delete_char → u.)
7. **Press `dw` on a word; press `u`** — the deleted word reappears; cursor at the word's pre-delete start. (Pins AC7 hook 3: op_compose_d → u.)
8. **Yank a line (`yy`); navigate down; press `p`; press `u`** — the pasted line disappears; cursor at undo_position (= insert-start of the paste). (Pins AC7 hook 6: op_paste → u.)
9. **Press `cw`, type `BIG`, press Esc, press `u`** — the original word is restored (the `BIG` is removed). (Pins AC7 hook 4: op_compose_c → u; the REPLACE two-phase upgrade per Q3.)
10. **`u u` (two `u`s in succession)** — first `u` restores; second `u` shows `nothing to undo` (entry consumed). (Pins AC5 u-of-u single-level semantic.)
11. **Trigger a "too large" undo: `:e largefile.fs` (or load any file > 256 B); navigate to a line with > 256 chars (uncommon but possible) OR use `1G` then a counted `100dd` (deletes a large range)**; then press `u` — status shows `undo not possible — too large`; buffer unchanged. (Pins AC5 + FR46 too-large path.)
12. **`:w` to save; press `i`, type one char, Esc, `u`; `:w`** — confirm the editor state after undo + re-save is consistent (no crash, no garbled state). (Pins NFR5 + NFR6 — undo is robust.)

Hardware UAT also looks for regressions: motion in NORMAL (Stories 2.5-2.7) still works; ex-line `:w` / `:q` / `:e` still work (2.1-2.4); INSERT mode (2.8) + `x` (2.9) + `dd` / `yy` (2.10) + operator+motion compose (2.11) + paste (2.12) all still work.

**Boundary cases worth Ant's verification on hardware** (consolidated; Ant may compress to time available):
- `u` after `i` + only Backspace (net-zero insert session): status `nothing to undo` per Q2 Option A pin (documented divergence from vi).
- `u` after `>>` or `<<`: per Q6 Option C pin (indent/dedent skipped in MVP), status `nothing to undo` even though `>>` mutated the buffer. Documented divergence.
- `u` after a successful save (`:w`): MVP semantic — buffer_dirty stays 1 after undo even if undone state matches saved state. Document per Q5 pin.
- Counted `5u` — should behave like bare `u` (single-level undo; count ignored per AC9).

## Tasks / Subtasks

- [x] **Task 1: Resolve Implementation Questions with Ant** (before any code lands).
  - [x] Sub 1.1: NFR9 escalation (Q1) — **Option A + Option D**: formal amend to 6144 B + shared undo_record_op helper.
  - [x] Sub 1.2: Insert-session net-deleted semantic (Q2) — **Option A**: UNDO_KIND_EMPTY (documented vi-divergence).
  - [x] Sub 1.3: REPLACE kind (Q3) — **Option A**: two-phase upgrade (phase 1 DELETE in op_compose_c; phase 2 upgrade at INSERT exit).
  - [x] Sub 1.4: TOO_LARGE post-surface (Q4) — **Option A**: keep kind as TOO_LARGE; second u re-surfaces same message.
  - [x] Sub 1.5: buffer_dirty post-undo (Q5) — **Option A**: buffer_dirty := 1 after undo (documented vi-divergence).
  - [x] Sub 1.6: indent/dedent undo (Q6) — **Option B**: dedicated UNDO_KIND_INDENT_WALK / UNDO_KIND_DEDENT_WALK kinds + replay bodies. (Diverges from spec-recommended Option C — full indent/dedent coverage requested.)

- [x] **Task 2: Add `src/undo.asm` module + INCLUDE chain wire-up** (AC1, AC12).
  - [x] Sub 2.1: Create `src/undo.asm` with module-header docstring per AR23 (Public / State owned / Register conventions / Dependencies blocks).
  - [x] Sub 2.2: Add `INCLUDE "undo.asm"` to `src/vibe.asm` AFTER `fileio.asm` INCLUDE and BEFORE `input_loop` definition (per AR25; architecture.md:950 specifies this slot).
  - [x] Sub 2.3: Add UNDO_KIND_* equates to `inc/equates.inc` (cluster with the SR6 KIND_CHAR / KIND_LINE / KIND_BLOCK block; same comment-block style).
  - [x] Sub 2.4: Add `undo_kind` (1 B), `undo_position` (2 B), `undo_length` (2 B), `undo_aux_length` (2 B) to `inc/state.inc` after the existing 16-bit state block (positional EQU; advance static_off per AR11 / NFR16). Verify the ASSERT yank_end <= 0xD800 still passes.

- [x] **Task 3: Implement `undo_record_*` helpers** (AC2, AC7).
  - [x] Sub 3.1: `undo_record_insert` — write kind, position, length; no payload copy.
  - [x] Sub 3.2: `undo_record_delete` — capacity check; copy bytes via motion_byte_at_logical loop (BC-preserving per motions.asm contract); on overflow set UNDO_KIND_TOO_LARGE WITHOUT touching payload.
  - [x] Sub 3.3: `undo_record_replace` — write all 5 header cells (kind, position, length, aux_length); payload is already in undo_buffer from a prior undo_record_delete call (caller responsibility).
  - [x] Sub 3.4: Per-entry contract blocks per AR23 (In/Out/Trashes/Calls).

- [x] **Task 4: Wire 5 hook sites in `src/edits.asm`** (AC7).
  - [x] Sub 4.1: `edits_delete_char` (~src/edits.asm:786) — capture-per-iter pattern; call `undo_record_delete` at `.commit` with HL=original_cursor + BC=deletes_done.
  - [x] Sub 4.2: `op_dd` (src/edits.asm:1085-1087 hook site marker) — `undo_record_delete(delete_start, total_bytes)` BEFORE `edits_copy_to_yank`.
  - [x] Sub 4.3: `op_compose_d` (src/edits.asm:1367-1368 hook site marker) — same shape as op_dd.
  - [x] Sub 4.4: `op_compose_c` (src/edits.asm:1499 — BEFORE `edits_copy_to_yank`) — phase 1: `undo_record_delete(range_start, range_bytes)`. Phase 2 lands at the INSERT-exit hook (Task 5).
  - [x] Sub 4.5: `op_paste` at `.commit` (src/edits.asm:2148) — compute bytes_inserted + call `undo_record_insert(insertion_start, bytes_inserted)`. Use a module-local DEFW (`edits_paste_bytes_inserted`) stashed from edits_paste_yank_bytes' loop exit + a saved insertion_start (also DEFW).
  - [x] Sub 4.6: Skip indent/dedent ops per Q6 Option C (recommended). Document in deferred-work.md.

- [x] **Task 5: Wire INSERT-session record at `enter_insert_mode` entry + `enter_normal_mode` / `edits_overflow_to_normal` exit** (AC3).
  - [x] Sub 5.1: Add `insert_session_entry_cursor` DEFW module-local to `src/edits.asm` (or src/dispatch.asm — wherever both entry and exit hooks live with least cross-module reference cost; edits.asm hosts the overflow exit; dispatch.asm hosts the entry — pick the one that minimises EXTRA forward-refs).
  - [x] Sub 5.2: Patch `enter_insert_mode` (src/dispatch.asm:289) to save `(cursor_offset)` into `insert_session_entry_cursor` at entry, BEFORE the mode write.
  - [x] Sub 5.3: Patch `enter_normal_mode` (src/dispatch.asm:263) to check `mode_byte == MODE_INSERT` BEFORE the MODE_NORMAL write; if true, compute delta + call `undo_record_insert` OR `undo_record_replace` (if `undo_kind` is UNDO_KIND_DELETE from a prior phase-1 c+motion). Three sub-branches: net > 0 → INSERT; net < 0 → UNDO_KIND_EMPTY (Q2 Option A pin); net == 0 → UNDO_KIND_EMPTY.
  - [x] Sub 5.4: Patch `edits_overflow_to_normal` (src/edits.asm:646) with the same exit-record logic — share via a helper `edits_insert_exit_record` to minimise duplication.

- [x] **Task 6: Implement `op_undo` + replay bodies** (AC4, AC5, AC6, AC10).
  - [x] Sub 6.1: `op_undo` kind-dispatch body per the AC4 pseudocode.
  - [x] Sub 6.2: `undo_replay_insert` — stage cursor at undo_position + undo_length; cursor-bounce gapbuf_delete loop (Story 2.10 edits_range_delete shape).
  - [x] Sub 6.3: `undo_replay_delete` — stage cursor at undo_position; per-byte gapbuf_insert loop from undo_buffer (similar shape to edits_paste_yank_bytes).
  - [x] Sub 6.4: `undo_replay_replace` — phase 1 (delete new content) + phase 2 (insert old content from undo_buffer).
  - [x] Sub 6.5: `undo_clear` — set undo_kind := UNDO_KIND_EMPTY.
  - [x] Sub 6.6: Empty / too-large status surfaces via existing `msg_nothing_to_undo` / `msg_undo_too_large` strings.
  - [x] Sub 6.7: Success tail: cursor := undo_position; `CALL edits_dirty_and_redraw`; `CALL undo_clear`; `JP parser_clear`.

- [x] **Task 7: Wire 'u' in `dispatch_normal`** (AC8).
  - [x] Sub 7.1: In `src/dispatch.asm`, add the `'u'` entry between `'p'` (src/dispatch.asm:552) and `'v'` (src/dispatch.asm:555). Use the shape: `ASSERT 'u' > 'p' ; DEFB 'u' ; DEFW op_undo`. Update the existing `ASSERT 'v' > 'p'` to `ASSERT 'v' > 'u'`.
  - [x] Sub 7.2: Add the `; 'u' — single-level undo (FR45, Story 2.13)` doc-comment.
  - [x] Sub 7.3: Verify `DISPATCH_NORMAL_COUNT` auto-recomputes via the `$ - .entries / 3` math (no manual count update needed — should evaluate to 35 in build/vibe.lst).

- [x] **Task 8: Module-header docstring updates** (across src/edits.asm + src/dispatch.asm + src/undo.asm).
  - [x] Sub 8.1: src/undo.asm header — full module docstring per AR23 (Public list with op_undo + undo_record_* + undo_clear; State owned: undo_kind / undo_position / undo_length / undo_aux_length / undo_buffer payload writes; Register conventions; Dependencies block).
  - [x] Sub 8.2: src/edits.asm header — update "B2 undo recording is a STUB" comments throughout (lines 42-75) to reflect that Story 2.13 has wired the real recorders. Add note: "FR45 undo recording for X is wired to Y hook in src/undo.asm".
  - [x] Sub 8.3: src/dispatch.asm Dependencies block — add Story 2.13 note: op_undo forward-referenced from the new `'u'` dispatch_normal entry; insert-session record wired at enter_insert_mode / enter_normal_mode / edits_overflow_to_normal.

- [x] **Task 9: Headless tests** (AC11).
  - [x] Sub 9.1: Implement all 6 canonical tests per AC11 list (`undo_x-restores-byte`, `undo_dd-restores-line`, `undo_insert-session-as-unit`, `undo_capacity-refusal`, `undo_nothing-to-undo`, `undo_buffer-dirty-recomputes` — see AC11 for the MVP buffer_dirty=1 semantic).
  - [x] Sub 9.2: Implement all 9 additional tests per AC11 list (`undo_dw-restores-word`, `undo_p-removes-paste`, `undo_cw-replace`, `undo_insert-after-backspace-net-zero`, `undo_5x-counted`, `undo_3dd-counted`, `undo_too-large-then-x`, `undo_consumed-then-u-again`, `parser_u-dispatch`, `parser_5u-dispatch`).
  - [x] Sub 9.3: Sentinel allocation: 0xC0..0xDF for unit-level undo_* tests; 0xE7..0xE8 for parser-driven dispatch tests (matching the existing 0xE0..0xEC parser-test convention).
  - [x] Sub 9.4: Tests that drive through dispatch INCLUDE every transitive production module (dispatch.asm + parser.asm + motions.asm + edits.asm + statusln.asm + gapbuf.asm + render.asm + input.asm + fileio.asm + undo.asm) per the test-INCLUDE pattern established in Story 2.12 (parser_p-dispatch.asm shape).
  - [x] Sub 9.5: Pre-seed undo state explicitly per test (LD A,UNDO_KIND_*; LD (undo_kind),A; LD HL,position; LD (undo_position),HL; etc.).

- [x] **Task 10: NFR9 + NFR18 + AR sweep verification** (AC12).
  - [x] Sub 10.1: Measure final `vibe.com` size via `wc -c vibe.com`. Report as a percentage of the post-amend NFR9 ceiling (5760 B baseline OR 6144 B if Q1 Option A landed).
  - [x] Sub 10.2: NFR18 byte-identical rebuild verified twice: `make clean && make all` × 2 produces identical sha256sum.
  - [x] Sub 10.3: AR13 / AR14 / AR15 grep sweeps for `src/undo.asm`, `src/edits.asm`, `src/dispatch.asm`: all clean (zero CODE refs to BIOS_CONOUT outside render.asm; zero raw gap_start/gap_end writes; zero raw BDOS_CALL outside fileio.asm carve-outs). `CALL gapbuf_insert` count in undo.asm matches replay-insert sites; `CALL gapbuf_delete` count matches replay-delete sites.
  - [x] Sub 10.4: dispatch_normal count: `LD B, DISPATCH_NORMAL_COUNT` resolves to opcode `06 23` (hex 0x23 = 35 decimal) in build/vibe.lst — confirmed 34 → 35 grew correctly.

- [x] **Task 11: PRD + architecture amendment** (only if Q1 Option A formal NFR9 amend landed).
  - [x] Sub 11.1: Amend PRD §NFR9 (`_bmad-output/planning-artifacts/prd.md` ~line 848) — update the ceiling value + extend the amend-history block.
  - [x] Sub 11.2: Amend architecture.md in 5 callsites (matching Story 2.12's amend pattern; verify exact lines by `grep -n "5760" _bmad-output/planning-artifacts/architecture.md`).
  - [x] Sub 11.3: Document the amend in deferred-work.md under a new `## Deferred from: dev of story-2-13-single-level-undo-u` heading with date stamp + revisit-trigger.

- [x] **Task 12: Deferred-work + sprint-status updates** (housekeeping).
  - [x] Sub 12.1: Append `## Deferred from: dev of story-2-13-single-level-undo-u (2026-05-XX)` block to `_bmad-output/implementation-artifacts/deferred-work.md` with: (a) Q1-Q6 pin choices + revisit triggers; (b) Q6 indent/dedent undo deferred to Growth-tier (with the inverse-op encoding sketch for future work); (c) Q5 buffer_dirty=1 MVP divergence + future polish path (save snapshot at `:w` success + compare on undo); (d) FR45 NOW CLOSED end-to-end EXCEPT for indent/dedent ops; FR46 closed end-to-end; (e) the NFR9 closing-budget note: post-Story-2.13 footprint vs the (post-amend) ceiling — this is the LAST Epic-2 story.
  - [x] Sub 12.2: Sprint-status flips: backlog → ready-for-dev (this spec pass) → in-progress (dev pass start) → review (dev pass complete, awaiting Ant UAT) → done (after AC13 hardware UAT confirmed). Add detailed `last_updated` blocks per the Story 2.10 / 2.11 / 2.12 audit-trail pattern.

- [x] **Task 13: Hardware UAT script delivered to Ant verbatim** (AC13; per memory `feedback_uat_inline_at_dev_handoff.md`).
  - [x] Sub 13.1: Paste AC13's 12-step hardware UAT script inline at the end of the dev pass handoff message (post-test-results, post-build-verification). Story does NOT flip to `done` until Ant confirms hardware UAT on real MicroBeast.

## Dev Notes

### Architecture compliance

- **AR11 (single static memory map).** New cells `undo_kind` / `undo_position` / `undo_length` / `undo_aux_length` added to inc/state.inc following the existing positional-EQU + static_off-advance pattern. NFR9 7-byte static cost.
- **AR12 (status-line single funnel).** `op_undo` surfaces user feedback EXCLUSIVELY through `status_set_message` (empty / too-large / replay-overflow paths). No direct `status_buffer` writes.
- **AR13 (render-owned screen emission).** Replay paths call `edits_dirty_and_redraw` (which marks all rows dirty + sets buffer_dirty); render.asm handles the actual emit. Zero new BIOS_CONOUT call sites.
- **AR14 (gap-buffer mutation surface).** `undo_replay_insert` / `undo_replay_delete` mutate the gap buffer EXCLUSIVELY through `gapbuf_delete` / `gapbuf_insert` primitives. No raw gap_start / gap_end writes.
- **AR15 (no raw BDOS).** Pure-memory undo — no BDOS calls. The undo_buffer is in static_data (via state.inc's existing declaration at line 126); reads via `LD A, (HL)` are direct memory loads.
- **AR16 (status-message conventions — lowercase, no period, < 30 chars).** No NEW status strings (reuse msg_nothing_to_undo + msg_undo_too_large + msg_file_too_large — all existing).
- **AR23 (per-module + per-entry contract blocks).** `src/undo.asm` gets a full module-header docstring + per-entry 4-line `In: / Out: / Trashes: / Calls:` block for each public symbol.
- **AR25 (INCLUDE chain stability).** undo.asm added in the long-planned AR25 slot (after fileio.asm, before input_loop). No reordering of the existing chain. `op_undo` is forward-referenced from dispatch.asm; resolves via sjasmplus's two-pass model.
- **AR26 (reserved-pool earmarked for multi-level undo).** Single-level undo (this story) consumes the 256-byte `undo_buffer` slot in static_data. Multi-level undo (Growth-tier) will extend into the reserved-pool region between yank_end and 0xD800.
- **MC1 (caller-saved).** Standard caller-saved register discipline. `op_undo` PUSH/POPs registers across replay calls.
- **MC3 (binary-search dispatch — sparse sorted tables).** New `'u'` entry inserted at the correct sorted position (between 'p' = 0x70 and 'v' = 0x76); ASSERT brackets the insertion.
- **MC4 (handler signature).** A=key on entry (ignored — `op_undo` reads state via state.inc symbols); RET-terminating via tail-JP parser_clear.
- **MC5 (status as error sink).** All op_undo error surfaces (empty / too-large / overflow) route through status_set_message.
- **MC7 (single source of truth).** New state cells in inc/state.inc; new equates in inc/equates.inc. No magic numbers.

### Files this story modifies (and what to preserve)

**`src/undo.asm` (NEW — Story 2.13 introduces this module):**
- New module per AR25's documented final-module slot. Owns the FR45 + FR46 undo register state-machine, record helpers, and replay body.

**`src/edits.asm` (UPDATE):**
- **Current state:** Post-Story-2.12 left this module with FR45 STUB comment blocks at 5 mutating handler sites (edits_delete_char, op_dd, op_compose_d, op_compose_c, op_paste — explicit hook-site markers documented per AR23). Plus the existing INSERT entry/exit sites (edits_insert_literal via dispatch chain to enter_insert_mode; edits_overflow_to_normal exit). ~2160 lines.
- **What this story changes:** Replaces the 5 mutating-handler STUB comments with real `CALL undo_record_*` invocations (push/pop bracketing around the call to preserve registers for the subsequent mutation). Updates module-header docstring B2 / FR45 commentary to reflect Story 2.13 wired the recorders. Adds a module-local DEFW pair (`edits_paste_bytes_inserted` + `edits_paste_insertion_start`) for op_paste's undo hook math.
- **What must be preserved:** Every existing handler body (edits_delete_char's `.exit_loop` deletes_done math; op_dd's three-way cursor placement; op_compose_d's inclusive-bump + post-delete clamp; op_compose_c's two-phase RANGE-DELETE + enter_insert_mode tail-JP; op_paste's KIND_CHAR / KIND_LINE / partial-paste cursor placement; ALL the Q1-Q5 pins from Story 2.12). The undo hooks are PRE-mutation read-only — they do not alter post-mutation behaviour.

**`src/dispatch.asm` (UPDATE):**
- **Current state:** dispatch_normal table at src/dispatch.asm:463-567 has 34 entries (sorted ASCII-ascending). enter_normal_mode at line 263; enter_insert_mode at line 289; enter_visual_mode at line 312.
- **What this story changes:** (1) Insert `'u'` entry between `'p'` (line 553) and `'v'` (line 556). +3 B in the table + new `ASSERT 'u' > 'p'` (and update `ASSERT 'v' > 'p'` → `ASSERT 'v' > 'u'`). `DISPATCH_NORMAL_COUNT` auto-recomputes to 35. (2) Patch `enter_insert_mode` (line 289) to save entry cursor BEFORE mode write. (3) Patch `enter_normal_mode` (line 263) to check `mode_byte == MODE_INSERT` BEFORE mode write; if true, branch to insert-session-exit-record helper.
- **What must be preserved:** All 34 existing dispatch entries unchanged. dispatch_insert / dispatch_command / dispatch_visual tables unchanged. enter_visual_mode body unchanged. enter_command_mode body (if any) unchanged. The COMMAND/VISUAL → NORMAL Esc paths (line 579 / 598-599 — both DEFW enter_normal_mode in dispatch_command / dispatch_visual) continue to work unchanged (the `mode_byte == MODE_INSERT` check filters out their non-INSERT exits).

**`src/statusln.asm` (NO CHANGE):**
- msg_nothing_to_undo (line 223) + msg_undo_too_large (line 222) + msg_file_too_large (line 219) all already declared.

**`src/parser.asm` (NO CHANGE):**
- parser_clear is consumed by op_undo's tail-JP; no patches. The new `'u'` dispatch_normal binding routes directly to op_undo (not through any parser_handle_* gate) — `'u'` is a plain handler, not an operator (no compose semantics) and not a count digit and not a motion prefix.

**`src/motions.asm` (NO CHANGE):**
- motion_byte_at_logical is used by undo_record_delete for the per-byte source-read loop; no patches.

**`src/gapbuf.asm` (NO CHANGE):**
- gapbuf_insert + gapbuf_delete consumed by replay bodies; no patches.

**`inc/state.inc` (UPDATE):**
- **Current state:** state cells through `undo_buffer` (256 B) declared at line 126. `static_end EQU static_data_base + static_off` (line 130) anchors the end of static block. yank_buffer / yank_end declared after GAP_BUFFER_BASE. `ASSERT yank_end <= 0xD800` (line 156) guards TPA fit.
- **What this story changes:** Add 4 new cells (`undo_kind` 1 B, `undo_position` 2 B, `undo_length` 2 B, `undo_aux_length` 2 B = 7 B total) AFTER the existing 16-bit state block (after `input_tick_counter`) and BEFORE the buffers block. Total static_data growth: +7 B. The undo_buffer (256 B) declaration at line 126 stays unchanged — it's the payload slot, separate from the new header cells. Verify the TPA-fit ASSERT still passes (it will — 7 B growth is trivial).
- **What must be preserved:** Every existing declaration (mode_byte, cursor_offset, yank_kind/length/buffer, undo_buffer, etc.) unchanged. The static_off advance pattern preserved. The ASSERT static_data_base >= 0x0101 and ASSERT yank_end <= 0xD800 both still passing.

**`inc/equates.inc` (UPDATE):**
- **Current state:** UNDO_BUFFER_SIZE = 256 (line 33). KIND_CHAR / KIND_LINE / KIND_BLOCK at lines 82-84.
- **What this story changes:** Add UNDO_KIND_EMPTY = 0x00 / UNDO_KIND_INSERT = 0x01 / UNDO_KIND_DELETE = 0x02 / UNDO_KIND_REPLACE = 0x03 / UNDO_KIND_TOO_LARGE = 0x04 equates. Cluster with the KIND_* block (use the same comment-block style). Optional: add `UNDO_PAYLOAD_SIZE EQU UNDO_BUFFER_SIZE` alias for self-documenting payload-size references in undo.asm.
- **What must be preserved:** Every existing equate unchanged.

**`src/vibe.asm` (UPDATE):**
- **Current state:** AR25 INCLUDE chain documented at lines 69-168; ends with `INCLUDE "fileio.asm"` at line 168; `input_loop:` starts at line 183.
- **What this story changes:** Add `INCLUDE "undo.asm"` BETWEEN line 168 (fileio.asm) and line 183 (input_loop:). With the AR25 ordering comment block similar to the existing fileio.asm INCLUDE block (lines 160-167).
- **What must be preserved:** Every existing INCLUDE order unchanged. The state.inc INCLUDE at end (line 240+) unchanged.

### Undo state-machine — design choices and trade-offs

**Why 3 kinds (INSERT / DELETE / REPLACE) instead of 1 generic "saved-bytes-and-position" kind?**

A single generic kind `(position, bytes_to_remove, bytes_to_insert, saved_payload)` could encode all three operations: INSERT = (pos, length, 0, none); DELETE = (pos, 0, length, saved); REPLACE = (pos, new_length, old_length, saved). Saves ~30 B in op_undo (1 dispatch instead of 3-way branch) + simpler entry layout.

**Rejected because:** the per-kind replay bodies have meaningfully different structures (insert-loop vs delete-loop vs both-phases) and combining them costs more in branching complexity than separating saves. The 3-kind structure is also AR23-clean — each kind has a focused contract block.

**Pin: 3 kinds + per-kind replay body.**

**Why no recompute of buffer_dirty against last-saved state?**

Epic AC line 1460 mandates "buffer_dirty recomputes (if undo restores to last-saved, dirty becomes 0)". The clean implementation requires:
1. At `:w` success (src/fileio.asm), snapshot the entire buffer content into a "last-saved" hash (~30-40 B for a 16-bit hash of the buffer).
2. After every mutation (including undo replay), recompute the current-content hash.
3. Compare; if equal, buffer_dirty := 0; else 1.

**Cost:** ~60-80 B + NFR3 budget impact (hash compute on every mutation). **MVP pin (Q5 Option A):** buffer_dirty := 1 after undo. Documented divergence; future polish.

**Why hook record at PRE-mutation, not POST-mutation?**

The source bytes for a DELETE-kind undo are needed by the record helper (to copy into `undo_buffer`). If the record happens POST-mutation, the bytes are GONE (deleted from the gap buffer). Hook at PRE-mutation; the helper reads bytes still at their pre-delete logical offsets.

For INSERT-kind undo, only position + length are needed (no payload bytes). Hook AT-mutation or POST-mutation both work. Story 2.13 picks POST-mutation for INSERT (op_paste's hook at `.commit:` — bytes are inserted; length is known) because that's where the bytes-inserted count is finalised.

**Pin: PRE-mutation for DELETE/REPLACE (source bytes needed); POST-mutation for INSERT (length known after).**

**Why a module-local DEFW for `edits_paste_bytes_inserted` instead of recomputing at `.commit`?**

Recomputing the bytes-inserted count at op_paste's `.commit:` label would require either:
- Re-walking the cursor delta from a saved pre-paste cursor (already on stack; cleanest).
- Stashing in a module-local DEFW from inside `edits_paste_yank_bytes`'s loop exit.

The DEFW pattern matches the existing motion_compose_entry / edits_indent_walk_dirty pattern in edits.asm — module-local state for cross-call values. Costs +2 B static; saves the cursor-delta recompute math at `.commit`.

**Pin: module-local DEFW (matches existing edits.asm pattern).**

### Previous story intelligence

**From [[story-2-12-paste-p]] (the immediate predecessor):**
- **FR45 undo recording for op_paste is a STUB** — Story 2.13's clean hook site: AT op_paste's `.commit:` label (src/edits.asm:2148), with bytes-inserted derived from cursor delta. Stash in a module-local DEFW from edits_paste_yank_bytes' loop exit.
- **NFR9 ceiling now 5760 B (was 5120 B from Story 2.12 amend).** Post-Story-2.12 = 5603 B / 97.5% / 157 B headroom — INSUFFICIENT for Story 2.13's projected ~340-490 B addition. **Q1 NFR9 escalation question is the LOAD-BEARING decision** before dev starts.
- **Q2/Q3 silent surface pins** (empty-yank + KIND_BLOCK silent in op_paste) DON'T affect Story 2.13 — undo's status surfaces use existing strings.
- **Q4 KIND_LINE past-EOF always-insert-LF pin** in op_paste: produces the "extra blank line corner case" on dd-last-line-no-LF + p. **Recoverable via Story 2.13 undo** per the Q4 deferral note. Make sure the test set covers this: `undo_dd-last-line-then-p-then-u.asm` is NOT in the canonical 6 list — consider adding to the additional tests if scope allows.

**From [[story-2-11-composed-operator-motion]]:**
- **5 FR45 STUBs in compose layer** (op_compose_d / op_compose_y NEVER / op_compose_c / op_compose_indent / op_compose_dedent / op_indent_line / op_dedent_line). Story 2.13 wires op_compose_d + op_compose_c; indent/dedent ops deferred to Growth-tier per Q6.
- **AC5 line-class motion divergence** (y3j treated as KIND_CHAR per epic spec). Story 2.13 inherits this; undo of `d3j` records DELETE of byte-range (matches the actual deletion).

**From [[story-2-10-doubled-operator-commands-dd-yy]]:**
- **op_dd FR45 STUB hook site at src/edits.asm:1085-1087** — `undo_record_delete(delete_start, total_bytes)` BEFORE `edits_copy_to_yank`. The bytes are at pre-delete positions; undo is independent of yank capacity.
- **op_yy NEVER records undo** (yank-only; no mutation; nothing to undo).
- **AC2 last-line-no-LF semantic** (yank holds leading "\n" prefix): when undoing a `dd` of last-line-no-LF + S>0, the inverse-insert restores both the LF + the line content — symmetric to dd's delete range.

**From [[story-2-9-single-character-delete-x]]:**
- **edits_delete_char FR45 STUB hook site at `.commit:` (src/edits.asm:824)** — capture-per-iter pattern; `undo_record_delete(original_cursor, deletes_done)`. The deletes_done count lands in HL at `.exit_loop` (line 808).

**From [[story-2-8-insert-mode]]:**
- **B2 invariant**: insert sessions undo as a unit (epic AC line 1234 — "INSERT session is recorded as a single undo entry per B2; for 2.8 the entry recording is a stub"). Story 2.13's `enter_normal_mode` exit hook closes this.
- **Insert-session ENTRY hook**: `enter_insert_mode` itself (src/dispatch.asm:289) — covers `i` (FR13), `a` / `o` / `O` (FR25-27 transitively via tail-JP), `op_compose_c` (FR39 transitively). Single entry-hook covers all five user-visible INSERT entry paths.

**From [[story-1-12-init-teardown-on-hardware-smoke-test]]:**
- **`init_cold_start`'s LDIR zero-fill** zeroes the entire static_data block including the new `undo_kind` / `undo_position` / `undo_length` / `undo_aux_length` cells. Cold-start `undo_kind == UNDO_KIND_EMPTY` (= 0x00) → first `u` after boot shows "nothing to undo".

**From [[story-1-7-gap-buffer-primitives]]:**
- **gapbuf_insert + gapbuf_delete contracts** (AR14 mutation surface). Replay bodies in undo.asm consume these unchanged.

**From [[story-1-3-static-memory-map]]:**
- **undo_buffer slot** already declared at state.inc:126 (256 B). Story 2.13 USES this slot — no growth needed there. The 4 new header cells (7 B) grow the static block by 7 B; verify TPA fit ASSERT holds.

**From [[project_no_tilde_marker]] memory:**
- VIBE does NOT render `~` empty-line markers. Past-EOF screen rows show as blank spaces (0x20), not `~`. Story 2.13's UAT script avoids `~` references.

**From [[feedback_uat_trace_cursor]] memory:**
- Post-`:e` cursor lands at offset 0 (vi-faithful). UAT script uses `$a` to land cursor at EOF before any `i` test.

**From [[feedback_uat_inline_at_dev_handoff]] memory:**
- Dev pass delivers AC13 UAT script inline at handoff message end (not just pointing at the story file).

### Git intelligence

Recent commits (post-Story-2.12, providing direct lineage):

- `0756610 story 2.12: paste p / Np lands (KIND_CHAR + KIND_LINE; KIND_BLOCK reserved)` — Story 2.12 dev pass + done flip (5603 B / 97.5% NFR9 / 157 B headroom inherited).
- `84dd7d4 story 2.11: operator+motion compose (dw/d$/c5w/y3j) + >> / << landed` — Story 2.11 dev pass + done flip (compose layer; the 5 FR45 stub sites in op_compose_*).
- `94b4f16 story 2.9: x deletes char under cursor; counted Nx with EOL/EOF clamp` — Story 2.9 (the x handler; FR45 stub hook site at `.commit:`).
- `fdd2d10 social media preview image` — non-dev cosmetic.
- `57325ff story 2.8: INSERT mode lands; i/a/o/O, typing, backspace, Enter→LF, Esc` — Story 2.8 (INSERT entry/exit; B2 stub).

**Story 2.12 is the immediate predecessor.** Story 2.13's dev pass starts from the 2.12 baseline (5603 B / 157 B headroom / 5 FR45 stub sites + 1 for paste from 2.12 = 6 total stub sites, of which 5 are wired in Story 2.13 per Q6 Option C and 2 paths — indent/dedent — defer to Growth).

**Patterns to follow** (consolidated from the Story 2.5-2.12 dev passes):

- Single dev-commit per story containing production code + tests + spec updates + sprint-status flips.
- Separate code-review commit (optional; Story 2.10 ran this pattern; Story 2.11 / 2.12 skipped at Ant's call).
- Sentinel byte at `0xCFFE` per TH1 (test/inc/test_prologue.inc); unique sentinel per test in a chosen band.
- INCLUDE chain in test cases: pre-ORG headers, `test_prologue.inc`, test body, `test_epilogue.inc`, production sources (in AR25 order), `test_teardown_stub.inc`, `test_input_loop_stub.inc`, finally `inc/state.inc`. **Tests that drive through dispatch need every production module that the dispatch chain transitively references.**
- Gap-buffer fixture pattern: `CALL gapbuf_init` → LDIR payload → set `gap_start := GAP_BUFFER_BASE + N`. Cursor pre-set via `LD HL, N ; LD (cursor_offset), HL`. Mode pre-set via `LD A, MODE_NORMAL ; LD (mode_byte), A`.
- **Undo-register pre-seed for undo tests** (NEW pattern for Story 2.13):
  ```
  LD A, UNDO_KIND_DELETE (or UNDO_KIND_INSERT / etc.)
  LD (undo_kind), A
  LD HL, <position>
  LD (undo_position), HL
  LD HL, <length>
  LD (undo_length), HL
  ;; For DELETE / REPLACE: copy saved bytes to undo_buffer
  LD HL, .test_undo_payload
  LD DE, undo_buffer
  LD BC, <length>
  LDIR
  .test_undo_payload:
      DEFB "saved bytes here"
  ```
- **NFR18 verification pattern**: post-dev pass, `make clean && make all` produces a byte-identical `vibe.com` (sha256sum matches the previous build).

### Implementation Questions (resolve with Ant before dev starts)

**Q1 — NFR9 escalation strategy. Projected post-2.13 footprint OVER the 5760 B ceiling by ~183-333 B.** Pick a primary path (and optionally an orthogonal economy add-on):
- **Option A (recommended)**: Formal NFR9 amend to 6144 B (~+384 B; matches Story 2.11 / 2.12 amend pattern; TPA fit holds; closes FR45 + FR46 + indent/dedent skipped per Q6 cleanly).
- **Option B**: Defer REPLACE kind (cw undo) to Growth-tier. Save ~75-105 B. User loses `cw word Esc u` original-word restore. **Strongly recommend against.**
- **Option C**: Defer single-byte `x` undo to Growth-tier. Save ~25-40 B. User loses journey-2 hot path. **Strongly recommend against.**
- **Option D (orthogonal)**: Shared `undo_record_op` helper for the 5 mutating edit hooks. Save ~30 B. **Recommended add-on to Option A.**

Recommended decision: **Option A + Option D**.

**Q2 — Insert-session net-deleted semantic.** When a user enters INSERT, hits Backspace beyond their typed chars (net-deleted bytes from the pre-INSERT buffer), and Esc'es:
- **Option A (recommended)**: Record UNDO_KIND_EMPTY. User loses "undo my net deletions"; documented vi-divergence. Simpler.
- **Option B**: Record UNDO_KIND_DELETE with saved bytes (the bytes that were before the cursor and got Backspace'd). Requires capturing those bytes at session entry (cost ~20-30 B). Overkill for a rare case.

Recommended decision: **Option A**.

**Q3 — REPLACE kind for cw + motion.** `cw word Esc` deletes a range then enters INSERT; on Esc, the inserted bytes form a "replacement".
- **Option A (recommended)**: Two-phase upgrade. Phase 1 (in op_compose_c BEFORE delete): `undo_record_delete(range_start, range_bytes)`. Phase 2 (at INSERT exit): detect undo_kind == UNDO_KIND_DELETE, upgrade to UNDO_KIND_REPLACE. Costs ~25-35 B extra over phase 1 alone.
- **Option B**: Defer REPLACE entirely. cw records as DELETE only. `cw word Esc u` then restores the original word but ALSO keeps the new content (the cw-replaced text). User confusion. **Strongly recommend against.**

Recommended decision: **Option A**.

**Q4 — Post-surface behaviour for UNDO_KIND_TOO_LARGE.** After surfacing `msg_undo_too_large`:
- **Option A (recommended)**: KEEP the kind as UNDO_KIND_TOO_LARGE. A second `u` re-surfaces the same message. User can mentally model "this entry is permanently unrecoverable until I do another edit".
- **Option B**: Clear to UNDO_KIND_EMPTY. A second `u` shows "nothing to undo". Cheaper (~3 B saved by reusing undo_clear) but less informative.

Recommended decision: **Option A** (matches epic AC line 1463-1465's tone of "u reports unavailability" — implies the report can repeat).

**Q5 — buffer_dirty post-undo.** Epic AC line 1460 mandates "buffer_dirty recomputes". MVP can either:
- **Option A (recommended)**: `buffer_dirty := 1` after undo (no recompute). Documented vi-divergence. Saves ~40-60 B.
- **Option B**: Snapshot at `:w` success + compare on every mutation. ~60-80 B + NFR3 cost.

Recommended decision: **Option A**.

**Q6 — Indent/dedent ops (`>>` / `<<` / `>+motion` / `<+motion`) undo coverage.**
- **Option A**: Encode as REPLACE (save the whole line range pre-walk; replay deletes new range + inserts old range). Likely exceeds payload size for any non-trivial indent. ~40-60 B impl.
- **Option B**: Dedicated UNDO_KIND_INDENT_WALK / UNDO_KIND_DEDENT_WALK kinds + replay bodies. ~80-120 B impl.
- **Option C (recommended)**: Skip indent/dedent undo in MVP. Document as Growth-tier. `>>` followed by `u` shows `msg_nothing_to_undo` (the undo entry from the prior mutation IS still there — overwritten by `>>` mutating the buffer without recording — wait, that's wrong). Actually: `>>` MUST clear the prior undo entry (else `u` would replay the WRONG inverse-op). Pin: indent/dedent ops `CALL undo_clear` to mark UNDO_KIND_EMPTY at entry. ~3 B per op × 4 ops = ~12 B.

Recommended decision: **Option C** (skip + clear). Saves ~80-120 B; documented Growth-tier addition.

**Note on Q6 Option C subtlety:** if `>>` doesn't clear undo, then `dd >> u` would replay the DD's inverse — INCORRECT (the user expects `u` to undo `>>`). Pin: every mutating op MUST record SOMETHING (either a real entry or UNDO_KIND_EMPTY). Indent/dedent ops record UNDO_KIND_EMPTY (via `CALL undo_clear`) at entry.

### NFR9 budget arithmetic (worked example)

Assuming Option A + Option D pin:

| Component | Estimated bytes |
|---|---|
| src/undo.asm body (5 record entries + 4 replay entries + clear + dispatch) | ~280 B |
| 5 hook sites in edits.asm × ~6 B (shared helper per Option D) | ~30 B |
| enter_insert_mode + enter_normal_mode + edits_overflow_to_normal patches | ~50 B |
| dispatch_normal 'u' entry | +3 B |
| state.inc 7 new B | +7 B static |
| equates.inc | 0 B (EQUs only) |
| Module-header docstrings | 0 B (comments) |
| **Total** | **~370 B code + 7 B static** |

Post-2.13 projection: 5603 + ~370 = **~5973 B / 97.2% of 6144 B / ~171 B headroom**.

The "final Epic-2 closing-budget" — Stories 2.x are done after this; Epic 3 will reset the budget conversation.

### Test count target

15 new tests (6 canonical + 9 additional). Sentinel allocation: 0xC0..0xDF (unit-level) + 0xE7..0xE8 (parser-dispatch). Pre-existing test count post-2.12 = 178 pass / 1 deliberate-fail (`harness_fail`). Post-2.13 target = 193 pass / 1 fail.

### Project Structure Notes

- **No conflicts.** Story 2.13 fits cleanly in the existing project structure:
  - New module at `src/undo.asm` (AR25-final slot per architecture.md:950 — long-planned).
  - New tests at `test/cases/undo_*.asm` (matches AR21 + TH2 naming + architecture.md:1328's `undo_*.asm` projection).
  - State extension in `inc/state.inc` follows the positional-EQU pattern.
  - Equates extension in `inc/equates.inc` follows the SR6 KIND_* cluster pattern.

### References

- **PRD** (`_bmad-output/planning-artifacts/prd.md`):
  - FR45 (line 778), FR46 (line 779) — functional requirements.
  - Journey 2 typo-recovery (line 244-248) — load-bearing user scenario.
  - §Undo (line 454-467) — storage policy, capacity refusal, u-of-u Growth-tier deferral.
  - §NFR9 (line 848) — current 5760 B ceiling + amend history; Story 2.13 expected to be the final Epic-2 amend point.
  - B2 (line 1695-1703 of architecture, via PRD §Validation) — insert-sessions-undo-as-a-unit invariant.

- **Architecture** (`_bmad-output/planning-artifacts/architecture.md`):
  - AR25 (line 180) — INCLUDE chain ending in undo.asm.
  - AR26 (line 184) — reserved-pool for Growth-tier multi-level undo.
  - Line 254 (directory tree) — `src/undo.asm` slot.
  - Line 1314 (directory tree elaboration) — undo.asm description.
  - Line 1382 (state.inc layout) — undo_buffer 256 B already reserved.
  - Line 1422 (module dependency graph) — undo.asm receives `undo_record` calls from edits.asm.
  - Line 1540 (FR-to-module mapping) — FR45-FR46 → undo.asm with edits.asm + visual.asm as recorders.
  - Line 1695-1703 — B2 clarification.

- **Epics** (`_bmad-output/planning-artifacts/epics.md`):
  - Lines 1432-1480 — Story 2.13 epic spec with 7 acceptance clauses + 6 canonical tests.
  - Forward heads-up cross-references: Story 2.8 (line 1234), Story 2.9 (line 1281), Story 2.10 (line 1321-1323), Story 2.11 (line 1376-1378), Story 2.12 (line 1418-1422) all flag their FR45 stubs with explicit "full coverage in 2.13" notes.

- **Previous stories** (all under `_bmad-output/implementation-artifacts/`):
  - `2-12-paste-p.md` — paste hook site at op_paste's `.commit:`; NFR9 amend history; Q1-Q5 pin patterns.
  - `2-11-composed-operator-motion-dw-d-c5w-y3j.md` — 5 compose-layer FR45 stub sites + hook-site comment markers in src/edits.asm:1213-1220.
  - `2-10-doubled-operator-commands-dd-yy.md` — op_dd FR45 stub hook site at src/edits.asm:1052-1056.
  - `2-9-single-character-delete-x.md` — edits_delete_char FR45 stub hook site at src/edits.asm:766-772.
  - `2-8-insert-mode-i-a-o-o.md` — B2 invariant + INSERT entry/exit hook architecture.

- **Source files** (all under `src/`):
  - `edits.asm` — 6 FR45 STUB comment blocks + the 6 mutating handlers (edits_delete_char, op_dd, op_compose_d, op_compose_c, op_compose_indent/dedent/indent_line/dedent_line, op_paste).
  - `dispatch.asm` — dispatch_normal table; enter_insert_mode + enter_normal_mode + enter_visual_mode mode-change handlers.
  - `statusln.asm` — msg_nothing_to_undo (line 223) + msg_undo_too_large (line 222) — both existing, reused by Story 2.13.
  - `parser.asm` — parser_clear; parser_doubled_operator_stub (unchanged in this story).
  - `vibe.asm` — AR25 INCLUDE chain ending in fileio.asm; gets undo.asm INCLUDE added.

- **Memory pins applied** (from MEMORY.md):
  - [[feedback_uat_trace_cursor]] — post-`:e` cursor at 0; use `$a` for EOF append.
  - [[feedback_uat_inline_at_dev_handoff]] — UAT script delivered inline at handoff.
  - [[project_no_tilde_marker]] — no `~` empty-line marker references in UAT script.

- **Deferred work** (`_bmad-output/implementation-artifacts/deferred-work.md`):
  - Lines 313-341 — Story 2.10 FR45 stub forward heads-up + KIND_LINE yank semantic.
  - Lines 343-373 — Story 2.11 NFR9 overshoot + 5 compose-layer FR45 stub sites + line-class motion divergence + indent/dedent post-cursor pin.
  - Lines 375-393 — Story 2.12 NFR9 amend to 5760 + paste FR45 stub hook site.
  - Lines 397-402 — Story 2.12 code-review deferrals (motion_apply_count twice on KIND_LINE; yank_kind garbage defensive untested).

## Dev Agent Record

### Agent Model Used

Claude Opus 4.7 (claude-opus-4-7[1m]) via Claude Code CLI. Test-writing batches delegated to 4 parallel `general-purpose` subagents (3 hit stream-idle timeouts mid-debug; tests salvaged + completed via 4 fresh batches of 2-3 tests each — all PASS).

### Debug Log References

- **Q6 Option B over-walk bug** (found by test-writing subagent during undo_dedent-line.asm validation): `edits_record_walk` was reading the caller-stashed PRE-walk end (`edits_indent_undo_end`), causing the inverse `edits_indent_walk` in replay to over-extend (extra space inserted into the line BELOW the dedented one). Fixed: `edits_indent_walk` now stashes its current DE (dynamically-adjusted end bound) into a new module-local `edits_indent_walk_end` DEFW at every iter top + after every per-line mutation. `edits_record_walk` reads `edits_indent_walk_end` (post-walk effective end). Net: undo replay's bounds are symmetric across forward + inverse walks. ~30 B of pre-walk dead stash code left in place pending follow-up cleanup (documented in deferred-work.md).
- **`edits_delete_char` per-iter capture flag bug** (found during first test PASS validation): `PUSH AF / OR A / SBC HL,DE / POP AF` preserved the post-`OR A` flags (CF=0 always) rather than the post-SBC flags, so `JR NC, .x_no_capture` always took the skip branch — undo_buffer[0] never got populated for `x`. Fixed: rewrote the bounds check to preserve A via OR A's self-OR (A unchanged, flags clobbered) and use BIT 7,D as the underflow check. ~3 B net.

### Completion Notes List

**Q1-Q6 pins resolved with Ant before dev pass (sub-tasks 1.1-1.6 in Task 1):**
- Q1: **Option A + Option D** — formal NFR9 amend (initially to 6144 B; re-amended mid-dev to 6400 B; see Q6 below) + shared undo_write_header helper.
- Q2: **Option A** — net-deleted INSERT session records UNDO_KIND_EMPTY (documented vi-divergence).
- Q3: **Option A** — REPLACE two-phase upgrade for cw + motion (phase 1 DELETE in op_compose_c; phase 2 upgrade at INSERT exit via undo_insert_exit_record).
- Q4: **Option A** — keep UNDO_KIND_TOO_LARGE after u surfaces msg_undo_too_large.
- Q5: **Option A** — buffer_dirty := 1 after undo (no last-saved snapshot recompute).
- Q6: **Option B** (DIVERGES from spec-recommended Option C) — dedicated UNDO_KIND_INDENT_WALK / UNDO_KIND_DEDENT_WALK kinds + replay bodies. Q6 Option B's actual cost ran ~150-180 B (vs spec's ~80-120 B projection), pushing Q1's formal amend ceiling from 6144 B → 6400 B mid-dev.

**Implementation highlights:**
- Single dev-pass commit lands: new `src/undo.asm` module (~390 B body); 9 hook sites + 7 module-local DEFW scratch cells in `src/edits.asm`; `enter_insert_mode` + `enter_normal_mode` patches + new `'u'` dispatch entry in `src/dispatch.asm`; `INCLUDE "undo.asm"` added to `src/vibe.asm` AR25 chain (long-planned final-module slot per architecture.md:945); 4 new state cells (7 B) in `inc/state.inc`; 7 new equates in `inc/equates.inc` (5 kinds + INDENT/DEDENT_WALK + UNDO_PAYLOAD_SIZE alias).
- 18 new headless tests (6 canonical + 10 additional + 2 Q6 Option B). All 167 existing tests with INCLUDE chains touching edits.asm/dispatch.asm updated with `INCLUDE "../../src/undo.asm"` after `INCLUDE "../../src/fileio.asm"` (bulk sed).
- 196 pass / 1 deliberate-fail (was 178/1 post-2.12 + code review; +18 new). No regressions.
- NFR18 byte-identical rebuild verified twice (sha prefix `703af027db5bb5b4`; size 6256 B).
- PRD §NFR9 + architecture.md 5 callsites all updated 5760 → 6400 with full amend-history block.
- AR13/AR14/AR15 grep sweeps clean for `src/undo.asm`: zero BIOS_CONOUT (docstring negation only), zero raw gap_start/gap_end writes, zero BDOS_CALL. `CALL gapbuf_insert` count = 2 (replay_delete + replay_replace phase 2). `CALL gapbuf_delete` count in undo.asm = 0 (replay_insert uses edits_range_delete which internally CALLs gapbuf_delete — AR14 still holds via the helper).
- dispatch_normal grew 34 → 35 entries (DISPATCH_NORMAL_COUNT EQU 0x23).
- FR45 + FR46 closed end-to-end for all 5 mutating-handler categories + 4 indent/dedent ops + B2 INSERT-session-as-a-unit invariant.

**Closing-budget question for Epic 2:** the final dev pass for Epic 2's last story. Epic 3 will reset the NFR9 budget conversation.

### Change Log

- 2026-05-17: Story 2.13 dev pass complete. FR45 + FR46 closed end-to-end. NFR9 amended 5760 → 6400 B. 18 new tests; 196/1 pass/deliberate-fail. Awaiting Ant hardware UAT (AC13 12-step script delivered inline at handoff).
- 2026-05-17: Hardware UAT CONFIRMED by Ant — 11 of 12 AC13 steps tested first iteration, all pass ("everything is working beautifully"). Step 11 (TOO_LARGE on hardware) untested — hard to trigger naturally; coverage retained via headless `undo_capacity-refusal.asm` (sentinel 0xC3). Story flipped review → done. **Epic 2 closed** — all 13 Epic 2 stories now `done`.

### File List

**New files (created in this story):**
- `src/undo.asm` — FR45 + FR46 register state-machine + op_undo + 5 replay bodies + 6 record helpers + shared undo_write_header + undo_insert_exit_record + module-local insert_session_entry_cursor DEFW.
- `test/cases/undo_x-restores-byte.asm` (sentinel 0xC0)
- `test/cases/undo_dd-restores-line.asm` (sentinel 0xC1)
- `test/cases/undo_insert-session-as-unit.asm` (sentinel 0xC2)
- `test/cases/undo_capacity-refusal.asm` (sentinel 0xC3)
- `test/cases/undo_nothing-to-undo.asm` (sentinel 0xC4)
- `test/cases/undo_buffer-dirty-recomputes.asm` (sentinel 0xC5)
- `test/cases/undo_dw-restores-word.asm` (sentinel 0xC6)
- `test/cases/undo_p-removes-paste.asm` (sentinel 0xC7)
- `test/cases/undo_cw-replace.asm` (sentinel 0xC8)
- `test/cases/undo_insert-after-backspace-net-zero.asm` (sentinel 0xC9)
- `test/cases/undo_5x-counted.asm` (sentinel 0xCA)
- `test/cases/undo_3dd-counted.asm` (sentinel 0xCB)
- `test/cases/undo_too-large-then-x.asm` (sentinel 0xCC)
- `test/cases/undo_consumed-then-u-again.asm` (sentinel 0xCD)
- `test/cases/undo_indent-line.asm` (sentinel 0xCE — Q6 Option B coverage)
- `test/cases/undo_dedent-line.asm` (sentinel 0xCF — Q6 Option B coverage)
- `test/cases/parser_u-dispatch.asm` (sentinel 0xE7)
- `test/cases/parser_5u-dispatch.asm` (sentinel 0xE8)

**Modified files:**
- `src/vibe.asm` — added `INCLUDE "undo.asm"` between fileio.asm and input_loop (AR25 final-module slot).
- `src/dispatch.asm` — patched enter_insert_mode (save insert_session_entry_cursor at entry); patched enter_normal_mode (CALL Z, undo_insert_exit_record on MODE_INSERT exit); added `'u'` entry between `'p'` and `'v'` in dispatch_normal (34 → 35 entries; ASSERT bracket re-stitched).
- `src/edits.asm` — patched edits_overflow_to_normal (CALL undo_insert_exit_record); added 5 mutating-handler hook sites (edits_delete_char with per-iter capture; op_dd before edits_copy_to_yank; op_compose_d before edits_copy_to_yank; op_compose_c phase 1 before edits_copy_to_yank; op_paste with pre-clear at entry + start-capture at .pc_no_advance/.pl_count_setup + per-iter accumulator via new edits_paste_acc helper + record_insert at .commit); added 4 indent/dedent hook sites (op_compose_indent / _dedent / op_indent_line / op_dedent_line each pre-clear + post-walk-record via new edits_record_walk helper); added 7 module-local DEFW scratch cells. Modified edits_indent_walk to stash post-walk end into edits_indent_walk_end DEFW (Q6 Option B replay bug fix).
- `inc/equates.inc` — added 7 UNDO_KIND_* equates (EMPTY/INSERT/DELETE/REPLACE/TOO_LARGE/INDENT_WALK/DEDENT_WALK) + UNDO_PAYLOAD_SIZE alias.
- `inc/state.inc` — added 4 new cells (undo_kind 1 B; undo_position 2 B; undo_length 2 B; undo_aux_length 2 B = 7 B static growth) after input_tick_counter and before the buffers block. undo_buffer (256 B; already declared at line 126) unchanged.
- `_bmad-output/planning-artifacts/prd.md` — NFR9 ceiling 5760 B → 6400 B at line 848 with full amend-history block.
- `_bmad-output/planning-artifacts/architecture.md` — NFR9 ceiling 5760 B → 6400 B in 5 callsites (line 47 Resource Consumption; line 200 architectural-significance block; line 305 size-auditing reference; line 735 binary-search dispatch reclamation; line 1334 build/vibe.lst caption).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — 2-13-single-level-undo-u: ready-for-dev → in-progress → review. last_updated chain preserved.
- `_bmad-output/implementation-artifacts/deferred-work.md` — appended "Deferred from: dev of story-2-13-single-level-undo-u (2026-05-17)" block with 8 entries (Q1-Q6 pins + FR45/FR46 closure note + Q6 Option B replay bug fix + 18-test landing note).
- 167 existing test files under `test/cases/*.asm` — added `INCLUDE "../../src/undo.asm"` after `INCLUDE "../../src/fileio.asm"` (bulk sed; matches AR25 INCLUDE chain order). Required because edits.asm + dispatch.asm now forward-reference undo.asm symbols.
