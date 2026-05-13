# Story 2.2: File load via :e filename (incl. :e!)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `:e filename` to load a file into the buffer (refused if the current buffer is dirty), and `:e!` to force-load discarding unsaved changes, with errors surfaced in the status line and oversize files refused without leaving the editor in an inconsistent state,
So that I can open and reopen files within a session (Journey 1b iteration), FR6 / FR9 / FR10 / FR11 / FR51 hold under every error path, and the `src/fileio.asm` BDOS gateway is in place for Stories 2.3 (launch-with-filename) and 2.4 (`:w` / `:w filename` / `:wq`) to extend.

## Acceptance Criteria

**AC1 — `:e` / `:e!` entries land in `exline_command_table`.**

**Given** `src/exline.asm`'s `exline_command_table` post-Story 2.1 (two entries: `q`, `q!`)
**When** I inspect the table post-Story 2.2
**Then** the table has four entries plus the terminator, in the order:
  - `e\0`   → `cmd_edit`
  - `e!\0`  → `cmd_edit_force`
  - `q\0`   → `cmd_quit`   (unchanged)
  - `q!\0`  → `cmd_quit_force` (unchanged)
  - `\0`    (terminator)

**Order rationale:** the dispatch walks entries linearly via `exline_dispatch`'s `.next_entry` loop; matching is by exact length+bytes of the parsed command token, NOT by sort order — so insertion order is free. Insert `e` / `e!` BEFORE `q` / `q!` because Stories 2.4 and 3.1 will add more entries; keeping the table grouped by Epic-2 file-IO commands first (`e`, `e!`, then `w`, `wq` arrives in 2.4) makes future inserts mechanically obvious.

**AC2 — `exline_dispatch` tokenises ex_buffer into command + args.**

**Given** Story 2.1's `exline_dispatch` matches the *entire* ex_buffer against each table key (exact length+bytes)
**When** Story 2.2's revised `exline_dispatch` runs
**Then** matching is performed against the FIRST WHITESPACE-DELIMITED TOKEN of ex_buffer:
  - Compute `cmd_len` = number of bytes in `ex_buffer_text` before the first space (0x20) or before `ex_buffer` length, whichever is shorter
  - Compare `cmd_len` + first `cmd_len` bytes against each table entry's NUL-terminated key
  - On match: tail-JP to the entry's handler **with HL = pointer to first byte after the command token (i.e. `ex_buffer_text + cmd_len`)** and **A = arg-region length (ex_buffer length - cmd_len)**.
    - For `:q` / `:q!` / bare `e` (no args): A = 0; HL points at the trailing slack inside `ex_buffer` (handler ignores HL when A = 0)
    - For `:e foo.fs`: cmd_len = 1, A = 7, HL = `ex_buffer_text + 1` (the space). Handlers strip the leading space themselves (see fileio_parse_filename, AC6).
  - On no-match (terminator reached): unchanged from Story 2.1 — set `msg_not_editor_command` via `status_set_message` then JP `exline_cancel_core`.

**And** bare-Enter short-circuit (Story 2.1 patch P5) stays: `LD A,(ex_buffer); OR A; JP Z, exline_cancel` at the top of `exline_dispatch`.

**Note on handler signature change:** Story 2.1's `cmd_quit` / `cmd_quit_force` ignored their inputs entirely. Post-Story-2.2 they still ignore HL and A (no behavioural change). The new contract is **additive**: handlers that need args (`cmd_edit`, future `cmd_write`) read HL + A; handlers that don't continue to ignore them. Update `cmd_quit`'s / `cmd_quit_force`'s contract comments to note "HL = ignored, A = ignored".

**AC3 — `cmd_edit` handler refuses on dirty buffer, otherwise calls fileio_load.**

**Given** `cmd_edit` is reached via `exline_dispatch`'s match on the `e` entry, with HL = pointer to arg region (just past the command token), A = arg-region length
**When** the handler runs
**Then**:
  - **No filename argument (A = 0, or arg region is all spaces):** set `msg_missing_filename` via `status_set_message`, then JP `exline_cancel_core`. The buffer is unchanged; mode returns to NORMAL.
  - **Buffer dirty (`buffer_dirty != 0`):** set `msg_no_write` via `status_set_message` (reusing the existing message — same banner as `:q`'s dirty refusal), JP `exline_cancel_core`. BH6.
  - **Otherwise:** strip leading spaces from the arg region, hand the trimmed filename pointer + length to `fileio_load`, then JP `exline_cancel` (the full-cancel form — fileio_load already set its own status banner, but cancel's `msg_mode_normal` would clobber it; so the actual exit JPs to `exline_cancel_core` to preserve fileio_load's banner).

**Wait — re-spec the post-load cleanup.** The cancel-vs-cancel-core decision mirrors Story 2.1's `cmd_quit`'s dirty path: any handler that has set its own status banner JPs to `exline_cancel_core`, NOT `exline_cancel`. So the spec is:

  - **No filename argument:** `status_set_message msg_missing_filename` → `JP exline_cancel_core`
  - **Buffer dirty:** `status_set_message msg_no_write` → `JP exline_cancel_core`
  - **Otherwise (clean buffer, filename present):** `CALL fileio_load` (which sets its own status banner on success or failure) → `JP exline_cancel_core`. The fileio_load banner ("foo.fs 134 bytes" on success, "can't open foo.fs" on open-fail, "file too large" on size-fail) survives the cleanup.

**AC4 — `cmd_edit_force` skips the dirty check, otherwise identical to cmd_edit.**

**Given** `cmd_edit_force` is reached via `exline_dispatch`'s match on the `e!` entry
**When** the handler runs
**Then**:
  - **No filename argument:** `status_set_message msg_missing_filename` → `JP exline_cancel_core`. (The user's `!` doesn't make a missing filename appear; preserve symmetry with `cmd_edit`.)
  - **Otherwise:** strip leading spaces, `CALL fileio_load` → `JP exline_cancel_core`. No `buffer_dirty` check — the `!` is the user's explicit consent to abandon any unsaved changes (BH6).

**Note on shared logic:** `cmd_edit` and `cmd_edit_force` share ~80% of their code (filename presence check, leading-space strip, fileio_load call). Implement as a shared internal helper (`cmd_edit_common: In: A = arg length, HL = arg ptr`) called by both, with `cmd_edit` branching to the dirty refusal on `buffer_dirty != 0` before calling the helper.

**AC5 — `fileio_load` orchestrates the file open + read + buffer-fill.**

**Given** `cmd_edit` / `cmd_edit_force` calls `fileio_load` with **HL = pointer to first byte of the filename text** (within `ex_buffer`), **A = filename length** (1..63 — bounded by `EX_COMMAND_BUFFER - 1`)
**When** `fileio_load` runs
**Then** it performs the following sequence (each numbered step pinned in the implementation):

  1. **Parse the filename** into the canonical FCB shape (`fileio_parse_filename`, AC6 below). Output:
     - File-local 36-byte `fcb_scratch` populated with drive byte, 8-char basename (space-padded, uppercase), 3-char extension (space-padded, uppercase), and zeros for the rest of the FCB.
     - `filename_buffer` (in state.inc) populated with the canonical display form (e.g., `B:FOO.FS\0` or `A:FOO.FS\0`) — NUL-terminated.
  2. **Empty the gap buffer** via `gapbuf_init`. This is the documented "reset to empty" state per FR11's "buffer presented is consistent on failure" guarantee. Any prior content is now gone — this is irreversible at this point and the caller (`cmd_edit` / `cmd_edit_force`) has already confirmed (via the AC3/AC4 dirty checks) that this is acceptable.
  3. **Open the file** via `BDOS_CALL BDOS_OPEN` with DE = `fcb_scratch`. The macro's `JP M` catches a sign-bit return (0xFF = file-not-found / not-open-able); the macro JPs to `bdos_error_funnel`. **Story 2.2 needs the funnel to NOT fire on file-not-found** because the desired behavior is a clean status message ("can't open foo.fs"), NOT the generic "bdos error" banner. See AC7 for the design.
  4. **On open success** (A = 0..3): set the DMA address to `DEFAULT_DMA` (0x0080) via `BDOS_CALL` function 26 (set-DMA-address). Architectural carve-out: this introduces a new BDOS function number (`BDOS_SET_DMA EQU 26`) into `inc/bdos.inc`. The CP/M default DMA at 0x0080 should already be set on entry, but we re-set it defensively (in case Story 2.4's save path or any future code has shifted it). See AC11.
  5. **Read loop** (`fileio_read_loop`):
     - **Pre-read budget check** (FR11): if `(gap_end - gap_start) < 128`, the next sector would overflow the gap buffer. Abort: close the file (BDOS_CALL BDOS_CLOSE), set `msg_file_too_large` via `status_set_message`, leave the buffer as `gapbuf_init`'d (empty). RET.
     - `BDOS_CALL BDOS_READ_SEQ` with DE = `fcb_scratch`. A = 0 → success; A = 1 → EOF (clean stop); A >= 2 → an unusual read error.
     - **A = 0 (success):** scan the 128 bytes at `DEFAULT_DMA` for `0x1A`. If found at index N (0..127): copy bytes `[0, N)` into the gap buffer (LDIR from DEFAULT_DMA to gap_start; advance gap_start by N). Goto step 6 (load complete). If not found: copy the full 128 bytes (LDIR from DEFAULT_DMA to gap_start; advance gap_start by 128). Loop back to the pre-read budget check.
     - **A = 1 (EOF):** loop done. Goto step 6.
     - **A >= 2 (read error):** close the file, set `msg_read_error` via `status_set_message`, reset buffer to empty (already empty from step 2, but `gapbuf_init` again defensively in case the loop has touched it). RET.
  6. **Close the file** via `BDOS_CALL BDOS_CLOSE` with DE = `fcb_scratch`. (Optional but matches CP/M discipline; CP/M doesn't require close-after-read, but it's the documented convention.)
  7. **Move the gap to offset 0** via `gapbuf_move_gap` with HL = 0. This LDDR-shifts the loaded bytes from the before-gap region to the after-gap region, so cursor=0 sits at the start of the file content with the gap at the end (vi-default cursor placement; PRD line 540-541).
  8. **Set post-load state:**
     - `cursor_offset = 0` (already set by gapbuf_move_gap's idempotence on its target — but write explicitly for clarity; gapbuf_move_gap does NOT modify cursor_offset)
     - `buffer_dirty = 0`
     - **Note:** `filename_buffer` was populated in step 1 (parse).
  9. **Mark all editable rows dirty** via `render_mark_all_dirty` (existing entry in render.asm; called by `render_full`). The next `render_diff` (run by the input loop after the handler returns) re-emits every editable row, picking up the new file content from the buffer via `byte_at_logical`.
  10. **Compose the success status row** via `fileio_compose_loaded_status` (new helper, AC8): produces "FILENAME N bytes" (e.g., "B:FOO.FS 134 bytes"). Hand to `status_set_message` via HL.
  11. **RET** back to cmd_edit / cmd_edit_force, which JPs to `exline_cancel_core` (preserving the status banner just set).

**AC6 — `fileio_parse_filename` normalises the filename string into FCB + filename_buffer.**

**Given** `fileio_parse_filename` is called with HL = filename text ptr, A = length (1..63)
**When** it parses the filename
**Then**:
  - **Drive prefix parse:** if the first two bytes are `[A-Za-z]` followed by `:` (case-insensitive), interpret as a drive letter and advance the pointer past the prefix.
    - `A:foo.fs` → drive byte = 1 (A:) (FR10)
    - `a:foo.fs` → drive byte = 1 (uppercase normalised)
    - `B:foo.fs` → drive byte = 2 (B:)
    - `b:foo.fs` → drive byte = 2
    - **No prefix (bare filename):** drive byte = 2 (B: — FR9 default)
  - **Basename parse:** copy up to 8 bytes from the post-prefix region, until either a `.` (extension delimiter) or end of filename string. Uppercase ASCII a-z → A-Z. Pad to 8 with spaces.
  - **Extension parse:** if a `.` was seen, copy up to 3 bytes from after the `.` until end of string. Uppercase. Pad to 3 with spaces.
  - **No extension:** the 3 extension bytes are 3 spaces.
  - **Filename overflow** (basename > 8 chars, or extension > 3 chars): the spec accepts truncation (silent, since CP/M's filesystem ALSO truncates). A future story may add a `msg_filename_too_long` refusal — for Story 2.2, follow CP/M's silent-truncate behavior.
  - **`fcb_scratch` (36 bytes) layout** (per CP/M 2.2 FCB convention):
    - Offset 0: drive byte (1 = A:, 2 = B:; never 0 since we always know the drive)
    - Offsets 1-8: basename (8 chars, space-padded, uppercase)
    - Offsets 9-11: extension (3 chars, space-padded, uppercase)
    - Offsets 12-35: zeros (extent, S1, S2, record count, allocation map, current record — all zero for a fresh open).
  - **`filename_buffer` (16 bytes in state.inc):** populated with the canonical text-form display string for the status row:
    - `<drive-letter>:<basename>.<extension>\0` (e.g., `B:FOO.FS\0` or `A:HELLO.TXT\0`)
    - The display form trims trailing spaces from basename and extension. Format: `<drive>:<basename-trimmed>` + (if extension is non-empty: `.<extension-trimmed>`) + `\0`.
    - Examples:
      - bare `foo.fs` → fcb_scratch[0]=2, ".......FOO.FS......" → filename_buffer = "B:FOO.FS\0"
      - `A:bar` → fcb_scratch[0]=1, basename="BAR     ", extension="   " → filename_buffer = "A:BAR\0"
    - **16 bytes** is enough: 2 (drive + colon) + 8 (basename) + 1 (dot) + 3 (ext) + 1 (NUL) = 15 bytes. The 16th byte is slack.

**AC7 — File-not-found surfaces a clean status message, NOT the generic "bdos error" banner.**

**Given** `BDOS_CALL BDOS_OPEN` returns 0xFF (file not found / cannot open)
**When** the `BDOS_CALL` macro's `JP M, bdos_error_funnel` fires
**Then** the user sees `"can't open FILENAME"` (AR16 format, lowercase, no trailing period) — NOT the generic `"bdos error"` from `bdos_error_funnel`'s default body.

**Design choice:** Story 1.5's `bdos_error_funnel` already documents the mechanism (statusln.asm:119-128): "per-fn message dispatch is deferred to fileio.asm; fileio sets a context-rich message via status_set_message BEFORE its BDOS call. When the BDOS call then fails into this funnel, the prior message remains the visible status — and the funnel's own write of msg_bdos_error gets superseded by fileio's pre-call message at most paths."

**Implementation: pre-write the message BEFORE calling BDOS_OPEN.** The sequence in `fileio_load`:
  1. Compose `"can't open FILENAME\0"` in a file-local scratch (`fileio_status_scratch`) via a new helper (`fileio_compose_cant_open`, see AC8). HL = pointer to scratch.
  2. `CALL status_set_message` — pre-stages the "can't open" banner.
  3. `BDOS_CALL BDOS_OPEN`.
  4. **If open succeeded** (A = 0..3, did not enter the funnel): clear the "can't open" banner by composing the loaded-status banner (step 10 of AC5) OR by simply continuing — the loaded-status banner at step 10 will overwrite via the AR12 funnel.
  5. **If open failed** (A = 0xFF, entered the funnel): `bdos_error_funnel` would call `status_set_message msg_bdos_error`, clobbering our pre-staged "can't open" message. To prevent this, we need a different mechanism — see "Decision: route file-not-found through cmd_edit, not the funnel" below.

**Decision: bypass `bdos_error_funnel` for the open path.** The above pre-stage-then-clobber pattern is what statusln.asm's design intended, but the funnel's body (statusln.asm:130-135) UNCONDITIONALLY overwrites the status banner with `msg_bdos_error`. So pre-staging doesn't survive.

Two clean resolutions:

  - **(a) Inline the open check, skip the funnel.** Don't use `BDOS_CALL BDOS_OPEN`; instead emit the raw `LD C, BDOS_OPEN; CALL BDOS_ENTRY` sequence followed by a per-fn A check that branches to a fileio-local error path. **But this violates AR15** (the BDOS_CALL macro is the single gateway).
  - **(b) Make `bdos_error_funnel`'s body conditional.** Add an "error message override" mechanism: if `bdos_error_pre_msg` (a 2-byte module-local pointer) is non-zero, the funnel uses it; else falls back to `msg_bdos_error`. Caller (fileio_load) sets it before BDOS_CALL, clears it after.

**Pick (b).** It preserves AR15 and the architectural intent of statusln.asm:119-128. The mechanism is small (~10 bytes in statusln.asm, ~6 bytes per use site). Spec:

  - **statusln.asm gains a new state cell** `bdos_error_pre_msg` (DEFW 0) — module-local; declared at the bottom of statusln.asm's data block. NOT in state.inc (it's an error-funnel internal). Stored as a 16-bit pointer to a NUL-terminated string. Zero means "fall back to msg_bdos_error" (the default).
  - **`bdos_error_funnel`'s body** is updated: read `bdos_error_pre_msg`; if zero, use `msg_bdos_error`; else use the pointed-to string. After the funnel calls `status_set_message`, zero `bdos_error_pre_msg` again (clear after use so a subsequent unrelated BDOS error doesn't pick up stale state).
  - **fileio_load's use** of the override:
    1. Compose "can't open FILENAME\0" into `fileio_status_scratch` (see AC8 for compose helper).
    2. `LD HL, fileio_status_scratch ; LD (bdos_error_pre_msg), HL`.
    3. `BDOS_CALL BDOS_OPEN`.
    4. **If open succeeded:** `LD HL, 0 ; LD (bdos_error_pre_msg), HL` (clear the override so a future unrelated BDOS error doesn't pick it up).
    5. **If open failed:** funnel fired, used our pre-msg, cleared the override, JP'd to `input_loop`. We never return here on failure (the funnel's JP-to-input_loop is the same flow as Story 1.5).

**Wait — JP to input_loop is a problem.** The funnel JPs to `input_loop` directly (statusln.asm:130-135). This bypasses our `JP exline_cancel_core` cleanup, leaving `ex_buffer` populated and `mode_byte = MODE_COMMAND` — the user is stuck in COMMAND mode with the failed `:e foo.fs` text still on the status row.

**Resolution: extend the funnel to also clean up ex-line state on its way to input_loop.** Two options:

  - **(b1)** funnel JPs to `exline_cancel_core` (which RETs), and `exline_cancel_core` returns up through the funnel's pushed return into input_loop. **But:** `exline_cancel_core` is in exline.asm, which depends on statusln.asm in the include order — pulling statusln.asm to forward-reference `exline_cancel_core` creates a circular dep at the symbol-resolution layer (sjasmplus's two-pass handles forward refs, but the source-tree layering would invert exline.asm/statusln.asm's relationship). Not great.
  - **(b2)** funnel does its own minimal cleanup: clear `ex_buffer` length to 0, set `mode_byte = MODE_NORMAL`, set `status_dirty = 1`, then JP `input_loop`. **Inline three writes** — duplicates `exline_cancel_core` but keeps modules layered.

**Pick (b2).** statusln.asm:130-135 gains three writes (clear ex_buffer length, set MODE_NORMAL, set status_dirty) before the JP input_loop. This is mechanically `exline_cancel_core` inlined; if a future story unifies them, fine — for now, the duplication is 9 bytes and keeps layering clean.

**Note on the override clear-after-use:** the funnel must clear `bdos_error_pre_msg` before JPing to input_loop, so a subsequent unrelated BDOS error (Story 2.4's :w writing a corrupt sector) doesn't inherit our stale "can't open" pointer. The funnel writes `LD HL, 0 ; LD (bdos_error_pre_msg), HL` after composing the message.

**This is the architectural choice that drives Story 2.2's statusln.asm changes — see AC11.**

**AC8 — Status-message composition helpers (`fileio_compose_cant_open`, `fileio_compose_loaded_status`).**

**Given** the load path needs two dynamic status strings — "can't open FILENAME\0" (open failure) and "FILENAME N bytes\0" (load success)
**When** I inspect `src/fileio.asm` post-Story 2.2
**Then** two file-local helpers exist:

  - **`fileio_compose_cant_open`** (called BEFORE BDOS_OPEN, since the override mechanism in AC7 pre-stages the message)
    - In: (none; reads `filename_buffer`)
    - Out: `fileio_status_scratch` contains `"can't open " + filename_buffer-contents + 0` (NUL-terminated). HL not loaded.
    - Trashes: A, BC, DE, HL, F.
    - The prefix `"can't open "` lives as a module-local string `fileio_msg_cant_open_prefix: DEFB "can't open ", 0`. The helper copies the prefix, then the filename_buffer contents (which is already NUL-terminated by `fileio_parse_filename`), then a NUL.

  - **`fileio_compose_loaded_status`** (called after load success, before the cmd_edit RET)
    - In: BC = byte count loaded (16-bit, 0..GAP_BUFFER_MAX)
    - Out: `fileio_status_scratch` contains `filename_buffer-contents + " " + decimal-BC + " bytes" + 0`. HL = `fileio_status_scratch` (ready to pass to `status_set_message`).
    - Trashes: A, BC, DE, HL, F.
    - Decimal conversion: a file-local `fileio_u16_to_dec` helper. In: HL = unsigned 16-bit value; DE = destination ptr; Out: DE = first byte past last digit. Standard "divide by 10000 / 1000 / 100 / 10 / 1, output digits, skip leading zeros (but always emit at least one digit)" routine. ~50 bytes; lives between routines in fileio.asm.

  - **`fileio_status_scratch`**: a 48-byte file-local DEFS block. Capacity check: max content is `"can't open "` (11) + `filename_buffer` display (15) + NUL (1) = 27 bytes; or `filename_buffer` (15) + space (1) + 5 decimal digits (5) + `" bytes"` (6) + NUL (1) = 28 bytes. 48 is generous; an ASSERT pins the lower bound.

  - **Status truncation note:** `status_set_message` (statusln.asm:77-99) truncates at `STATUS_LINE_WIDTH` (80 bytes) anyway, so an oversize `fileio_status_scratch` would only mean later padding. The local helper just needs to be wide enough that the entire composed string fits; we set 48 bytes with an `ASSERT $ - fileio_status_scratch >= 48` tripwire.

**AC9 — File-too-large on first read OR mid-read: oversize refusal with empty buffer.**

**Given** a file whose total size exceeds `GAP_BUFFER_MAX` (32768 bytes)
**When** `fileio_load` encounters the pre-read budget check failing (gap_end - gap_start < 128)
**Then**:
  - `BDOS_CALL BDOS_CLOSE` (close the file — courtesy, even though CP/M doesn't strictly require it for read-only access)
  - The buffer is left as `gapbuf_init`'d in step 2 of AC5 — but the read loop has already advanced `gap_start` by `floor(loaded_so_far / 128) * 128` bytes. To restore "empty buffer" state, call `gapbuf_init` again. (This is idempotent; resets gap_start back to `GAP_BUFFER_BASE`.)
  - `cursor_offset = 0` (already set by gapbuf_init).
  - `buffer_dirty = 0` (already set by gapbuf_init via the LDIR zero-fill at init? No — gapbuf_init does NOT touch buffer_dirty; it only resets gap_start / gap_end / cursor_offset. Buffer_dirty was zeroed implicitly because either: (a) cmd_edit's dirty refusal would have fired had it been nonzero, OR (b) cmd_edit_force was used and the user accepts dirty-was-discarded. For (b), buffer_dirty was nonzero at entry; we MUST zero it after the abort. **Spec: fileio_load explicitly writes `buffer_dirty = 0` after a too-large abort.**)
  - **`filename_buffer` cleanup**: leave it populated with the would-have-been-loaded filename. Rationale: the user's `:e bar.fs` failed; the next `:w` shouldn't pick up `bar.fs` as the save name (the buffer is empty; saving an empty buffer to `bar.fs` is silly but not destructive). The alternative — clear filename_buffer to zero — feels cleaner but adds code; for Story 2.2 we accept the lingering name. Story 2.4 (`:w`) will revisit this.
    - **Wait, refine:** if `filename_buffer` is left populated, a subsequent `:w` writes the empty buffer to the loaded-name file, **overwriting any earlier successful load's content**. That IS destructive. **Spec: zero `filename_buffer[0]` after a too-large abort** (sets the display name to NUL → empty C-string → `:w` will see "no filename" and refuse, per Story 2.4's planned behavior).
  - All editable rows marked dirty via `render_mark_all_dirty` (the screen needs to repaint to show the now-empty buffer).
  - `msg_file_too_large` (existing message, statusln.asm:159) via `status_set_message`.
  - RET back to cmd_edit / cmd_edit_force.

**AC10 — Mid-read I/O error (BDOS_READ_SEQ rc >= 2): clean abort.**

**Given** `BDOS_CALL BDOS_READ_SEQ` returns A = 2..9 mid-read (CP/M 2.2 documented codes: 2 = end of file in random-access mode (not applicable here); 9 = invalid FCB — and others depending on BIOS implementation)
**When** the read loop sees A >= 2 after the BDOS_READ_SEQ
**Then**:
  - Close the file (`BDOS_CALL BDOS_CLOSE`).
  - Reset buffer to empty (`gapbuf_init`).
  - Set `buffer_dirty = 0`, zero `filename_buffer[0]` (same as AC9).
  - Mark all editable rows dirty.
  - `msg_read_error` (new message, AC11) via `status_set_message`.
  - RET.

**Note:** the `BDOS_CALL` macro's `JP M` only catches sign-bit returns (0xFF — typically open-fail or write-protected-open). Mid-read rc >= 2 has bit 7 clear; the macro's JP M does NOT fire. fileio_load inspects A after the read and branches to the error path on `A >= 2`.

**AC11 — New statusln messages + bdos_error_pre_msg infrastructure.**

**Given** `src/statusln.asm` post-Story 2.2
**When** I inspect the message block
**Then** three new symbols exist:
  - `msg_missing_filename: DEFB "missing filename", 0` (AR16 format — lowercase, no trailing period, 16 chars payload)
  - `msg_read_error: DEFB "can't read file", 0` (15 chars)
  - **NO** new `msg_cant_open` — that string is composed dynamically by `fileio_compose_cant_open` because it needs the filename interpolated.

**And** statusln.asm's data block gains:
  - `bdos_error_pre_msg: DEFW 0` — 2-byte module-local pointer-or-zero. Zero = use msg_bdos_error (default); non-zero = use pointed-to string. Lives in the file-local data area (between routines per render.asm precedent; NOT in state.inc).

**And** `bdos_error_funnel`'s body is rewritten (statusln.asm:130-135):
  - Read `bdos_error_pre_msg` into HL; if zero, fall through to the existing `LD HL, msg_bdos_error` body.
  - If non-zero: skip the load (HL already has the right pointer).
  - `CALL status_set_message`.
  - **Clear `bdos_error_pre_msg`** to zero (so a subsequent unrelated BDOS error doesn't reuse our stale override).
  - **Inline ex-line cleanup** (AR12 layering — same writes as `exline_cancel_core`): zero `ex_buffer` length, set `mode_byte = MODE_NORMAL`, ensure `status_dirty = 1` (set by status_set_message above, redundant but defensive).
  - `JP input_loop` (unchanged).

**And** the funnel's header `Public:` and contract comments are updated to document the override mechanism.

**AC12 — `gapbuf_load` stub retirement.**

**Given** `src/gapbuf.asm` has a Story-1.7 stub `gapbuf_load` (lines 256-280) annotated `TODO Story 2.2: replace this stub with the real FCB-based load`
**When** Story 2.2 lands
**Then** the stub is **deleted entirely**. Story 2.2's `fileio_load` (in fileio.asm) is the orchestration entry; the buffer-fill mechanism within the load loop is a direct LDIR from DEFAULT_DMA into the gap-buffer's before-gap region (gap_start..gap_end), with `gap_start` advanced per-sector. **`fileio_load` writes `gap_start` directly** — which is a controlled exception to AR14 ("single buffer-mutation owner = gapbuf.asm").

**Architectural defence of the AR14 exception:** AR14's intent is to keep the *two-halves invariant* (SR2) in one place. fileio_load's writes:
  1. After `gapbuf_init`, gap_start = GAP_BUFFER_BASE, gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX, cursor_offset = 0. SR2 satisfied (gap covers full buffer, content empty).
  2. Per sector, fileio_load: LDIRs bytes into [gap_start, gap_start + N), advances gap_start by N. Through this entire phase, gap_start <= gap_end, cursor_offset = 0, content lives entirely in [GAP_BUFFER_BASE, gap_start) = the before-gap half. SR2 invariant holds at every intermediate state.
  3. After all reads, call `gapbuf_move_gap` with HL = 0 to LDDR-shift the content into the after-gap region. This is a gapbuf primitive — back inside AR14.
  4. cursor_offset = 0; SR2 holds.

**The exception is minimal:** fileio writes `gap_start` only during the linear-fill phase, and never violates SR2. The header comment for fileio.asm documents this carve-out explicitly (AR23). An alternative design — add a `gapbuf_bulk_append(HL = src, BC = count)` primitive in gapbuf.asm that fileio calls per-sector — would keep AR14 unviolated but at the cost of an extra public API surface (50+ bytes of code) and an extra CALL per sector (~20 T-states × 256 sectors max = ~1 ms — negligible, but cumulative across the load).

**Decision: take the AR14 carve-out, document it.** The cleaner alternative (gapbuf_bulk_append) is deferred to a future cleanup story if AR14 enforcement greps ever start surfacing the seam.

**And** the `make` build's AR enforcement greps (AC15) include a new check: `grep -nE 'gap_start|gap_end' src/fileio.asm` is allowed to match (in the documented load-loop block); a comment-attached `; AR14 carve-out — fileio_load linear-fill phase` marks the lines.

**AC13 — Headless tests cover the five file-load scenarios.**

**Given** five new headless tests under `test/cases/fileio_*.asm`
**When** `make test` runs
**Then** the following pass:
  - `fileio_load-small-file.asm` — load `B:hello.txt` (existing fixture, 13 bytes including CR/LF: `hello world\r\n`), verify post-load state: cursor_offset = 0; gap_start = GAP_BUFFER_BASE; gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX - 13; buffer_dirty = 0; filename_buffer = "B:HELLO.TXT\0"; first 13 bytes of after-gap region match the file content; status_dirty = 1; status_buffer opening bytes match `"B:HELLO.TXT 13 bytes"`. **Fixture extension**: existing `test/fixtures/hello.txt` works.
  - `fileio_load-with-1A-eof.asm` — load a fixture file that contains text data followed by a `0x1A` byte and some trailing garbage, verify the load stops at the 0x1A: gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX - (bytes-before-1A); after-gap content matches the bytes-before-1A. **New fixture**: `test/fixtures/eof1a.txt` — a small file with "abc" + 0x1A + "xyz" (the trailing "xyz" must not be loaded). Use `printf` in the Makefile or commit the bytes.
  - `fileio_load-not-found.asm` — call `fileio_load` with a filename that doesn't exist on the fixture B: drive (e.g., `B:nosuch.fs`), verify the path through `bdos_error_pre_msg`: status_buffer opening bytes = `"can't open B:NOSUCH.FS"`; buffer state = gapbuf_init'd (empty); mode_byte = MODE_NORMAL; ex_buffer length = 0. Local `input_loop` stub (the funnel JPs to it) lands a sentinel so the test can detect the funnel was entered.
  - `fileio_load-too-large.asm` — load a fixture file > GAP_BUFFER_MAX. Two options: (a) generate a 33 KB fixture (33792 bytes of repeated content) at test-Makefile time; (b) reduce `GAP_BUFFER_MAX` for the test build via a `DEFINE GAP_BUFFER_MAX_TEST` override and a small fixture (e.g., 256 bytes with GAP_BUFFER_MAX_TEST = 128). **Pick (a)**: simpler, no Makefile-level conditional. The fixture is generated by a Makefile rule (`test/fixtures/big.bin`: `dd if=/dev/zero of=$@ bs=128 count=264` for 33792 bytes ~= 33 KB) — gitignored, regenerated each `make test`. Verify post-abort state: gap_start = GAP_BUFFER_BASE, gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX; cursor_offset = 0; buffer_dirty = 0; filename_buffer[0] = 0; status_buffer opening bytes = `"file too large"`. **Note:** the test must not check that ALL gap-buffer bytes are zero — gapbuf_init does NOT zero the gap region (per SR2, gap bytes are read-as-undefined).
  - `fileio_load-drive-prefix.asm` — load `A:hello.txt` (mounting fixtures as both A: and B: in the test Makefile already supported per test/Makefile:53). Verify filename_buffer = "A:HELLO.TXT\0"; fcb_scratch's drive byte was 1 during the BDOS_OPEN call. (Inspect a captured copy of fcb_scratch in the test — fileio_load can be patched to expose a "last FCB" debug pointer, or the test instruments BDOS_OPEN by stubbing BDOS_ENTRY. The latter is more invasive; **pick the simpler path**: the test calls `fileio_load` then inspects `filename_buffer` only — proving the parse worked; the actual BDOS_OPEN call having reached BDOS with the right FCB is verified transitively because the load succeeded.)

**Each test follows the AR25-order INCLUDE pattern from Story 2.1's exline tests:**
  1. Pre-ORG production EQU INCLUDEs (equates, bios, bdos, modes, vt52).
  2. `test_prologue.inc` (ORG 0x0100, sentinel pre-zero).
  3. Test body (pre-zero state, set up ex_buffer if exercising cmd_edit, call fileio_load or cmd_edit, assert post-state).
  4. `test_epilogue.inc` (test_pass / test_fail labels).
  5. Production INCLUDEs in AR25 order: statusln + render + dispatch + parser + exline + fileio.
  6. `test_input_loop_stub.inc` (resolves bdos_error_funnel's JP target).
  7. **Local `init_teardown` stub** — same pattern as Story 2.1's tests; cmd_edit's path may not reach init_teardown, but cmd_edit_force tests that DO trigger a quit would. For pure fileio_load tests (the five above), the local stub is optional but harmless.
  8. `state.inc` LAST (positional anchor: static_data_base = $).

**Sentinel codes** for fileio tests (per the Story 1.10 / 2.1 pattern, 0xE0..0xEF range available; reserve 0xF0..0xFF for future):
  - 0xE0 — primary assertion failed (e.g., cursor_offset != 0)
  - 0xE1 — secondary state mismatch
  - 0xE2 — buffer content mismatch
  - 0xE3 — status_buffer content mismatch
  - B (context) = additional diagnostic byte per test.

**AC14 — Hardware UAT smokes :e on real MicroBeast.**

**Given** UAT on hardware (Feersum MicroBeast)
**When** I:
  1. `make push` (SLIDE-transfer) and launch `vibe` from CCP
  2. Press `:`, type `e bdos.txt`, press Enter
  3. Observe: screen re-renders to show the file content; status row reads `B:BDOS.TXT N bytes`; mode is NORMAL; cursor at row 0 col 0 (visually verified — the test character at offset 0 sits under the cursor)
  4. Press `:`, type `q`, Enter (clean buffer; just loaded a file, no edits)
  5. Observe: screen clears + CCP prompt appears (the load left buffer_dirty = 0; `:q` succeeds)
  6. Relaunch `vibe`; press `:`, type `e nosuch.fs`, Enter
  7. Observe: status row reads `can't open B:NOSUCH.FS` (or similar — see AR16 case); buffer remains empty; mode returns to NORMAL; cursor at row 0 col 0
  8. Press `:`, type `e a:test.fs`, Enter (where `test.fs` exists on A:)
  9. Observe: file loads from A: (if drive A is read-only the load still works for read; only :w would fail). Status row reads `A:TEST.FS N bytes`.
  10. Test the dirty refusal: press `i`, ... (deferred — see Note)

**Note on dirty-refusal hardware UAT:** until Story 2.8 lands real INSERT-mode literal-append, the user cannot organically dirty the buffer from the keyboard. Story 2.2's AC3 dirty-refusal path is covered by a headless test (`fileio_e-dirty-refusal.asm`, added as the sixth headless test); the hardware-side UAT for dirty-refusal is deferred to Story 2.8 (same trade-off Story 2.1's AC7 made).

**Then** all observable steps behave as specified, no terminal corruption, no warm-boot from any non-quit step.

**AC15 — Build invariants and AR enforcement.**

**Given** Story 2.2's source changes
**When** `make clean && make` runs twice consecutively
**Then**:
  - Both runs succeed (NFR14: sjasmplus 1.23.0 pinned via Makefile's `check-toolchain`)
  - The two resulting `vibe.com` files are byte-identical (NFR18 reproducibility). Capture both SHAs in Debug Log References.
  - `make sizes` reports the new code-section size (NFR9 ~3 KB budget). Capture verbatim. Expected growth: ~400-600 bytes over Story 2.1's 2243 B baseline (fileio.asm body ~350-500 B; new statusln messages ~50 B; cmd_edit / cmd_edit_force handlers ~80 B; gapbuf_load stub removal -15 B; net add ~470-615 B). Expected post-2.2 footprint: ~2700-2860 B / 3072 B ≈ 88-93% of NFR9 budget. **Watch:** the budget is tight — if the footprint exceeds 95% the dev must report it as a notable observation, not silently continue.

**AR enforcement sweeps (grep against `src/`):**
  - `grep -rnE 'BIOS_CONOUT' src/ | grep -v 'render.asm'` — zero matches (AR13: render owns every BIOS_CONOUT call site). The header comments in `src/exline.asm`, `src/init.asm` etc. may reference BIOS_CONOUT — these are comment-only and tolerated; the grep should be `-v '^[^:]*:[^:]*:[ \t]*;'` to exclude comments, or read by hand to confirm no call sites.
  - `grep -nE 'gapbuf_(insert|delete|move_gap|load|init)' src/fileio.asm` — matches `gapbuf_init` (step 2 + step 9-abort + step 10-abort of AC5) and `gapbuf_move_gap` (step 7 of AC5). These ARE the gapbuf API; matching them is correct. AR14 enforcement here is: fileio.asm goes through gapbuf entry points for everything EXCEPT the documented carve-out direct-`gap_start`-write in the load loop (AC12). The grep `grep -nE 'LD[ \t]+\(gap_start\)' src/fileio.asm` should match the documented carve-out site (and nowhere else); the comment `; AR14 carve-out` marks each match.
  - `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/fileio.asm` — zero matches (AR15: no raw BDOS calls; the BDOS gateway macro is the only path).
  - `grep -nE 'BDOS_CALL' src/fileio.asm` — multiple matches (BDOS_SET_DMA, BDOS_OPEN, BDOS_CLOSE, BDOS_READ_SEQ). These are the macro use sites; AR15 compliant.
  - `grep -nE 'BDOS_CALL|CALL[ \t]+BDOS_ENTRY|CALL[ \t]+0x0005' src/exline.asm` — comment matches only (no new call sites; cmd_edit / cmd_edit_force CALL fileio_load, which owns the BDOS work).
  - `grep -nE 'bdos_error_funnel' src/` — at least 3 matches: the BDOS_CALL macro definition (`inc/bdos.inc:87`), the funnel body (`src/statusln.asm`), and the file-local pre-msg site in fileio_load (no — fileio doesn't reference the funnel by symbol; it writes `bdos_error_pre_msg` instead). Confirm zero match in fileio.asm except header comments.
  - `grep -nE 'gapbuf_load' src/` — comment matches only (the stub is deleted; if any module's header still mentions gapbuf_load in its Dependencies list, sweep those comments). **Specifically check** `src/gapbuf.asm`'s header `Public:` list — `gapbuf_load` must be removed.

## Tasks / Subtasks

- [x] **Task 1: Create `src/fileio.asm` (AC5, AC6, AC8, AC9, AC10, AC12)**
  - [x] Sub 1.1: AR23 header block — Module / Purpose / Public list / State owned / State read-only / Register conventions per entry point / Dependencies. Document the AR14 carve-out (linear-fill phase writes gap_start directly) explicitly.
  - [x] Sub 1.2: Public entry `fileio_load` (HL = filename ptr, A = filename length 1..63):
    - Step 1: CALL `fileio_parse_filename` (Sub 1.3). On parse failure (length 0 or all spaces — shouldn't happen since cmd_edit pre-checks, but defensive): RET via msg_missing_filename. Actually, by contract cmd_edit has already stripped leading spaces and verified A > 0; fileio_load's input is non-empty trimmed text.
    - Step 2: `CALL gapbuf_init` — reset buffer.
    - Step 3: `CALL fileio_compose_cant_open` (Sub 1.5), then `LD HL, fileio_status_scratch ; LD (bdos_error_pre_msg), HL` — pre-stage the "can't open" message in case open fails.
    - Step 4: `LD DE, fcb_scratch ; BDOS_CALL BDOS_OPEN`. On 0xFF the macro JPs to bdos_error_funnel which now picks up our pre-staged message + JP input_loop (does not return).
    - Step 5: On open success — `LD HL, 0 ; LD (bdos_error_pre_msg), HL` (clear the override).
    - Step 6: `LD DE, DEFAULT_DMA ; BDOS_CALL BDOS_SET_DMA` — defensive DMA reset (per AC5 step 4 rationale).
    - Step 7: Initialise the local byte-counter (BC = 0) for the loaded-size tally.
    - Step 8: Read loop (`fileio_read_loop`):
      - Pre-read budget check (Sub 1.7) — abort to oversize path on insufficient gap room.
      - `LD DE, fcb_scratch ; BDOS_CALL BDOS_READ_SEQ`.
      - Branch on A: 0 = success (Sub 1.8); 1 = EOF (jump to post-load); >= 2 = read error (Sub 1.9).
    - Step 9: Post-load — `LD HL, 0 ; CALL gapbuf_move_gap` to flip content to the after-gap region. Then `LD HL, 0 ; LD (cursor_offset), HL`. `XOR A ; LD (buffer_dirty), A`. `CALL render_mark_all_dirty`.
    - Step 10: `CALL fileio_compose_loaded_status` (Sub 1.6) with BC = loaded byte count → HL = `fileio_status_scratch`. `XOR A ; CALL status_set_message`. RET.
  - [x] Sub 1.3: Internal helper `fileio_parse_filename` (HL = filename ptr, A = length):
    - Detect drive prefix (`[A-Za-z]:`), set drive byte (1 or 2). Default to 2 (B:) on no prefix.
    - Parse basename + extension; uppercase ASCII a-z → A-Z; pad to 8/3 with spaces.
    - Write 36-byte FCB into `fcb_scratch`: drive byte at +0, basename at +1..+8, extension at +9..+11, zeros at +12..+35.
    - Compose canonical display name `<D>:<basename-trimmed>[.<ext-trimmed>]\0` into `filename_buffer` (state.inc, 16 bytes).
  - [x] Sub 1.4: Internal helper `fileio_strip_leading_spaces` (HL = ptr, A = length) → HL', A' with leading 0x20 stripped. Used by cmd_edit / cmd_edit_force before calling fileio_load.
  - [x] Sub 1.5: Internal helper `fileio_compose_cant_open` — copies `"can't open "` (from `fileio_msg_cant_open_prefix`) + filename_buffer's NUL-terminated content + NUL into `fileio_status_scratch`.
  - [x] Sub 1.6: Internal helper `fileio_compose_loaded_status` (BC = byte count) — composes `<filename_buffer> + " " + <decimal-BC> + " bytes" + 0` into `fileio_status_scratch`. Returns HL = `fileio_status_scratch`. Calls `fileio_u16_to_dec` for the decimal conversion.
  - [x] Sub 1.7: Internal helper `fileio_check_budget` — returns CF=1 if (gap_end - gap_start) < 128 (insufficient room for next sector); CF=0 otherwise. Uses `LD HL,(gap_end) ; OR A ; SBC HL,(gap_start) ; LD DE, 128 ; SBC HL, DE ; JR C, .full` form (note: `SBC HL, (gap_start)` isn't a direct opcode — use `LD DE, (gap_start) ; SBC HL, DE`).
  - [x] Sub 1.8: Internal helper `fileio_ingest_sector` — scans DEFAULT_DMA for 0x1A; LDIRs the prefix into [gap_start, gap_start + N); advances gap_start by N; updates the loaded-byte tally. Returns CF=1 if 0x1A was found (caller breaks the read loop), CF=0 otherwise.
  - [x] Sub 1.9: Internal helper `fileio_abort_too_large` — close file; `CALL gapbuf_init`; zero filename_buffer[0]; `LD HL, msg_file_too_large ; CALL status_set_message`; `CALL render_mark_all_dirty`; RET.
  - [x] Sub 1.10: Internal helper `fileio_abort_read_error` — close file; `CALL gapbuf_init`; zero filename_buffer[0]; `LD HL, msg_read_error ; CALL status_set_message`; `CALL render_mark_all_dirty`; RET.
  - [x] Sub 1.11: Internal helper `fileio_u16_to_dec` (HL = value, DE = dest) — divide-and-emit; skips leading zeros except for the units digit; returns DE = first byte past last emitted digit. ~50 bytes.
  - [x] Sub 1.12: Data — module-local `fcb_scratch: DEFS 36, 0` (initialised to zero; parse_filename overwrites the front bytes).
  - [x] Sub 1.13: Data — module-local `fileio_status_scratch: DEFS 48, 0` with `ASSERT $ - fileio_status_scratch >= 48`.
  - [x] Sub 1.14: Data — module-local `fileio_msg_cant_open_prefix: DEFB "can't open ", 0` (11 chars + NUL).

- [x] **Task 2: Modify `src/exline.asm` — extend dispatch + add cmd_edit handlers (AC1, AC2, AC3, AC4)**
  - [x] Sub 2.1: Rework `exline_dispatch`'s match logic. New shape: scan ex_buffer_text for the first space, capture `cmd_len`. Compare `cmd_len` against each table entry's NUL-terminated key length; on length match, byte-compare the cmd region against the key; on match, tail-JP to the handler with HL = `ex_buffer_text + cmd_len`, A = (ex_buffer length - cmd_len). On no match, fall through to the existing no-match path (msg_not_editor_command + cancel_core).
  - [x] Sub 2.2: Add `cmd_edit` handler:
    - Strip leading spaces (CALL `fileio_strip_leading_spaces`); test A for zero; on zero, `LD HL, msg_missing_filename ; XOR A ; CALL status_set_message ; JP exline_cancel_core`.
    - Test `buffer_dirty`; on non-zero, `LD HL, msg_no_write ; XOR A ; CALL status_set_message ; JP exline_cancel_core`.
    - CALL `fileio_load` (HL = stripped filename ptr, A = stripped length); JP `exline_cancel_core`.
  - [x] Sub 2.3: Add `cmd_edit_force` handler:
    - Strip leading spaces; test A; on zero, `LD HL, msg_missing_filename ; ... ; JP exline_cancel_core`.
    - CALL `fileio_load`; JP `exline_cancel_core`. No dirty check.
  - [x] Sub 2.4: Extend `exline_command_table`: insert `e\0 / DEFW cmd_edit` and `e!\0 / DEFW cmd_edit_force` before the existing `q` entry. New shape:
    ```
    exline_command_table:
        DEFB    "e", 0
        DEFW    cmd_edit
        DEFB    "e!", 0
        DEFW    cmd_edit_force
        DEFB    "q", 0
        DEFW    cmd_quit
        DEFB    "q!", 0
        DEFW    cmd_quit_force
        DEFB    0          ; terminator
    ```
  - [x] Sub 2.5: Update exline.asm's header `Public:` list — add `cmd_edit`, `cmd_edit_force`. Update Dependencies — add `src/fileio.asm` (fileio_load, fileio_strip_leading_spaces). Update the `Architectural enforcement here:` block — note that cmd_edit / cmd_edit_force are AR15-clean (they don't make BDOS calls directly; they delegate to fileio_load which is the AR15 site).
  - [x] Sub 2.6: Update `exline_dispatch`'s contract comment — note the new "HL + A passed to handler" convention; note the tokenisation change.
  - [x] Sub 2.7: Update `cmd_quit` / `cmd_quit_force`'s contract comments — note "HL, A = ignored" (additive change; behaviour unchanged from Story 2.1).

- [x] **Task 3: Modify `src/gapbuf.asm` — retire gapbuf_load stub (AC12)**
  - [x] Sub 3.1: Delete the `gapbuf_load` body (lines 256-280 in gapbuf.asm) — including its contract block, the `TODO Story 2.2` marker, and the body.
  - [x] Sub 3.2: Remove `gapbuf_load` from the module header `Public:` list.
  - [x] Sub 3.3: Verify no callers remain (`grep -nE 'gapbuf_load' src/` — comments only, if any).

- [x] **Task 4: Modify `src/statusln.asm` — add messages + override mechanism (AC7, AC11)**
  - [x] Sub 4.1: Add `msg_missing_filename: DEFB "missing filename", 0` to the message block. Position alphabetically or by topic; recommend near `msg_no_write` since both are ex-line refusal banners.
  - [x] Sub 4.2: Add `msg_read_error: DEFB "can't read file", 0` near `msg_bdos_error` since both are I/O surface.
  - [x] Sub 4.3: Add `bdos_error_pre_msg: DEFW 0` data cell — module-local; positioned in the data section AFTER the message block (file-end-of-emit).
  - [x] Sub 4.4: Rewrite `bdos_error_funnel`'s body per AC11:
    - Read `bdos_error_pre_msg`; if non-zero use it as HL, else `LD HL, msg_bdos_error`.
    - `XOR A ; CALL status_set_message`.
    - Clear the override: `LD HL, 0 ; LD (bdos_error_pre_msg), HL`.
    - Inline ex-line cleanup (3 state writes mirroring exline_cancel_core): zero ex_buffer length, set mode_byte = MODE_NORMAL, set status_dirty = 1.
    - `JP input_loop`.
  - [x] Sub 4.5: Update statusln.asm's header `Public:` list — add `msg_missing_filename`, `msg_read_error`. Note the override mechanism in the bdos_error_funnel contract block.
  - [x] Sub 4.6: Update statusln.asm's Dependencies — add `inc/state.inc` references for `ex_buffer`, `mode_byte` (read/write) and `inc/modes.inc` for `MODE_NORMAL` (currently NOT in the dependency list since the pre-Story-2.2 funnel only touches status_buffer / status_dirty).

- [x] **Task 5: Modify `inc/bdos.inc` — add BDOS_SET_DMA (AC5 step 4)**
  - [x] Sub 5.1: Add `BDOS_SET_DMA EQU 26   ; set DMA address: DE = DMA buffer addr; A = 0 (always)` to the function-number block, sorted by number (between BDOS_WRITE_SEQ = 21 and BDOS_MAKE = 22 — wait, 26 > 22 so add after BDOS_MAKE).
  - [x] Sub 5.2: Update bdos.inc's header `Public:` Function-numbers list — add `BDOS_SET_DMA`.

- [x] **Task 6: Modify `src/vibe.asm` — INCLUDE fileio.asm (AC15)**
  - [x] Sub 6.1: Insert `INCLUDE "fileio.asm"` after the `exline.asm` INCLUDE (between exline.asm and the `input_loop:` body), with an AR25-style comment block above it noting Story 2.2.
  - [x] Sub 6.2: Update vibe.asm's header `Dependencies:` line — add `src/fileio.asm (Story 2.2)`.

- [x] **Task 7: Add test fixtures (AC13)**
  - [x] Sub 7.1: `test/fixtures/eof1a.txt` — small file with "abc\x1axyz" (8 bytes raw). Commit the file (binary). Alternatively, generate from the test Makefile via `printf 'abc\x1axyz' > $@`. Pick the Makefile-generation path so the binary doesn't have to be committed and `make clean` regenerates it cleanly.
  - [x] Sub 7.2: `test/fixtures/big.bin` — generated 33-KB file (33792 bytes = 264 × 128-byte sectors, exceeds GAP_BUFFER_MAX). Makefile rule: `test/fixtures/big.bin: ; dd if=/dev/zero of=$@ bs=128 count=264 2>/dev/null`. Add to `.gitignore` so it isn't committed.
  - [x] Sub 7.3: Confirm `test/fixtures/hello.txt` (existing — 13 bytes) is mounted as both A: and B: per test/Makefile:53.

- [x] **Task 8: Add headless tests (AC13)**
  - [x] Sub 8.1: `test/cases/fileio_load-small-file.asm` — verify load of `hello.txt` from B:. Sentinel codes: 0xE0 = cursor_offset != 0; 0xE1 = gap state mismatch; 0xE2 = buffer content mismatch; 0xE3 = filename_buffer mismatch; 0xE4 = status_buffer prefix mismatch.
  - [x] Sub 8.2: `test/cases/fileio_load-with-1A-eof.asm` — verify load stops at 0x1A; loaded bytes = "abc" (3 bytes), gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX - 3.
  - [x] Sub 8.3: `test/cases/fileio_load-not-found.asm` — verify the bdos_error_pre_msg path. The test sets up a custom `input_loop` stub (replaces test_input_loop_stub.inc's body) that sets a sentinel byte and returns to the test body via a long-jump; the funnel's `JP input_loop` lands in the stub. Post-stub: assert status_buffer prefix = "can't open ", ex_buffer length = 0, mode_byte = MODE_NORMAL.
    - **Implementation note**: the funnel's JP-to-input_loop is non-returning in production; in the test, the stub needs to either (a) cleanly RET back somewhere, or (b) jump to the test's epilogue (test_pass). Picking (b) is simpler — the stub does `LD A, 1 ; LD (funnel_entered), A ; JP after_assertions` where `after_assertions` is a label in the test body that runs the post-fail assertions and JPs to test_pass.
  - [x] Sub 8.4: `test/cases/fileio_load-too-large.asm` — verify oversize abort. Post-abort: gap state = empty, filename_buffer[0] = 0, status_buffer = "file too large".
  - [x] Sub 8.5: `test/cases/fileio_load-drive-prefix.asm` — verify A: drive prefix parse. Post-load: filename_buffer = "A:HELLO.TXT\0".
  - [x] Sub 8.6: `test/cases/fileio_e-dirty-refusal.asm` — verify cmd_edit's dirty refusal path. Pre-set buffer_dirty = 1; pre-load ex_buffer with `e foo.fs`; CALL exline_dispatch; assert: filename_buffer unchanged (zero), gap state unchanged, status_buffer prefix = "no write since last change", ex_buffer length = 0, mode_byte = MODE_NORMAL.
  - [x] Sub 8.7: `test/cases/fileio_e-bang-force-dirty.asm` — verify cmd_edit_force bypasses the dirty check. Pre-set buffer_dirty = 1; pre-load ex_buffer with `e! hello.txt`; CALL exline_dispatch; assert load succeeded (filename_buffer = "B:HELLO.TXT\0", buffer_dirty = 0 post-load).
  - [x] Sub 8.8: `test/cases/fileio_e-missing-filename.asm` — verify cmd_edit with no arg surfaces msg_missing_filename. Pre-load ex_buffer with just `e` (length 1) or `e   ` (length 4 trailing spaces); CALL exline_dispatch; assert status_buffer prefix = "missing filename", filename_buffer unchanged, gap state unchanged.

- [x] **Task 9: Update `_bmad-output/implementation-artifacts/deferred-work.md` (Story 2.1 deferral context)**
  - [x] Sub 9.1: Add a "Resolved (partial) by Story 2.2" sub-bullet under the Story-2.1 deferral "No structural ASSERTs on exline_command_table well-formedness" entry: note that Story 2.2 extends the table to 4 entries (was 2); the structural ASSERT decision is re-deferred to Story 2.4 or 3.1 (whichever next grows the table) since 4 entries remain hand-auditable.
  - [x] Sub 9.2: Add a "Resolved (partial) by Story 2.2" sub-bullet under the Story-2.1 deferral "Test stub refactor for `init_teardown`" entry — Story 2.2's tests reuse the same stub pattern; if a fifth consumer arrives (Story 2.4's :wq tests), the refactor goes there. Story 2.2 may or may not bring it forward; default = NO (cosmetic; keep the 4-way duplication, leave it for Story 2.4).
  - [x] Sub 9.3: If new Story-2.2-specific issues are deferred during the dev pass (e.g., a "fileio.asm's `fileio_u16_to_dec` is generic — promote to a shared util?" question), add them under a new "Deferred from: code review of story-2-2-file-load-via-e-filename-incl-e (date)" section. This is post-implementation work; the dev does it as part of the code-review triage step.

- [x] **Task 10: Build + headless test verification (AC13, AC15)**
  - [x] Sub 10.1: `make clean && make` succeeds; capture SHA256 of vibe.com.
  - [x] Sub 10.2: Repeat `make clean && make`; verify byte-identical SHA (NFR18).
  - [x] Sub 10.3: `make sizes` reports the new code-section size. Capture verbatim. Note delta vs Story 2.1's 2243 B and the NFR9 budget.
  - [x] Sub 10.4: AR grep sweeps per AC15 — all pass (comment-only matches OK; call-site matches only at documented carve-out sites).
  - [x] Sub 10.5: `make test` from project root — all existing tests pass + the new fileio_* / fileio_e-* tests pass. Live baseline becomes 28 (pre-2.2) + 8 (new) = 36 pass + 1 deliberate fail.

- [ ] **Task 11: Hardware UAT (AC14)** — *deferred to user review (cannot push from this dev environment)*
  - [ ] Sub 11.1: `make push` — SLIDE transfer to the MicroBeast.
  - [ ] Sub 11.2: Step through AC14's 10 hardware UAT steps; record observations in Debug Log References.
  - [ ] Sub 11.3: Particular regressions to watch for:
    - Cursor positioning after the full re-render (Story 2.1's COMMAND-mode cursor override interacts with the now-populated buffer — verify cursor lands at row 0 col 0 with the file content visible, not at the status row).
    - Status row rendering of the dynamic "B:FOO.TXT N bytes" string — verify trailing space-pad fills to STATUS_LINE_WIDTH (80 cols) per status_set_message contract.
    - File content with high-bit / TAB / NUL bytes — these would currently render raw and desync the shadow (deferred-work.md line 76 lists this as a Story-1.11 known issue). For Story 2.2's UAT, use only plain ASCII fixtures (`hello.txt`, etc.); reserve the control-char story for a future readiness pass.

### Review Findings

- [x] [Review][Decision-resolved] D1: NFR9 size budget overshoot — 3106 B vs 3072 B (+34 B, 101%). **Resolution (Ant, 2026-05-13): accept overshoot; amend NFR9 ceiling via a PRD/architecture follow-up.** No code change required for this story; an `amend-NFR9` follow-up is logged in `deferred-work.md` under the Story 2.2 code-review section.
- [x] [Review][Patch] P1: `fileio_status_scratch` ASSERT bound corrected from `>= 28` to `>= 48` per spec AC8 / Sub 1.13 [src/fileio.asm:750]
- [x] [Review][Patch] P2: `fileio_strip_leading_spaces` Trashes contract corrected to `A, B, F` with note that A is the in/out length parameter [src/fileio.asm:285]
- [x] [Review][Patch] P3: `fileio_load` State block tidied — `filename_buffer` moved into State owned (read/write); confusing "declared above" parenthetical removed from State read-only [src/fileio.asm:102-109]
- [x] [Review][Patch] P4: `fileio_u16_to_dec` contract now flags the read/write side-effect on module-local `fileio_dec_dest` [src/fileio.asm:638-641]
- [x] [Review][Patch] P5: `bdos_error_funnel` label renamed from `.have_override` to `.emit_status` (it's the common emit path, reached on both override and fallback) [src/statusln.asm:173-175]
- [x] [Review][Patch] P6: `fileio_e-bang-force-dirty` test status-buffer assertion extended from 12 chars (`"B:HELLO.TXT "`) to 20 chars (`"B:HELLO.TXT 13 bytes"`) so a digit-emit or " bytes" suffix regression is caught [test/cases/fileio_e-bang-force-dirty.asm:104-131]
- [x] [Review][Defer] W1: A file of exactly GAP_BUFFER_MAX (32768) bytes is falsely rejected as "file too large". The pre-read budget check (`free < 128 → abort`) fires after 256 successful sector reads (free=0) instead of letting the next READ_SEQ return A=1 (EOF). Spec AC9 says "exceeds GAP_BUFFER_MAX" → strictly `>`. Real-world impact low (no editing room left at exact-fit); fix is non-trivial (reorganise loop to budget-check post-read or attempt one EOF probe). [src/fileio.asm:207-216] — deferred, edge case
- [x] [Review][Defer] W2: Mid-call sign-bit BDOS error (A>=0x80) in BDOS_SET_DMA / BDOS_READ_SEQ / BDOS_CLOSE post-OPEN routes to `bdos_error_funnel` while `bdos_error_pre_msg` is cleared, surfacing generic "bdos error" instead of context-aware banner; FCB also stays open and the abort_common cleanup never runs. Spec AC10 explicitly accepts that "mid-read rc >= 2 has bit 7 clear; the macro's JP M does NOT fire" — out of spec scope. [src/fileio.asm:219, 202, 248] — deferred, out of spec scope
- [x] [Review][Defer] W3: `cmd_edit` / `cmd_edit_force` share ~80% of their bodies; spec AC3 Note suggested factoring `cmd_edit_common` (~15 B saving). May contribute to NFR9 resolution (see D1). [src/exline.asm:625-679] — deferred, pre-existing implementation choice
- [x] [Review][Defer] W4: Tests `fileio_e-dirty-refusal.asm` and `fileio_e-missing-filename.asm` don't pre-zero gap_start / gap_end. The current refusal paths don't touch gap state so tests pass, but a future regression adding gap reads to the refusal paths would land uninitialised. [test/cases/fileio_e-dirty-refusal.asm, fileio_e-missing-filename.asm] — deferred, asymmetric test setup
- [x] [Review][Defer] W5: `fileio_load-not-found.asm` uses cross-scope local-label JP (`JP test_start.after_funnel`) which relies on sjasmplus 1.23.0's local-label scope rules. Fragile across toolchain updates. [test/cases/fileio_load-not-found.asm] — deferred, sjasmplus quirk
- [x] [Review][Defer] W6: `fileio_load-small-file.asm` asserts status_buffer prefix (12 chars) and 13 bytes of after-gap content, but does not pin the exact byte-count digits in the status row. A bug miscounting N would pass. [test/cases/fileio_load-small-file.asm] — deferred, test gap
- [x] [Review][Defer] W7: `fileio_abort_common` zeros only filename_buffer[0]; bytes 1..15 retain stale parsed-filename content. Sufficient for `:w` refusal (NUL terminator) but a future reader scanning the full 16 bytes (cache/equality) sees stale state. [src/fileio.asm:725] — deferred, current contract is NUL-terminator-only
- [x] [Review][Defer] W8: `bdos_error_pre_msg` stale-pointer invariant is unpinned by ASSERT. Current flow zeros it on funnel emit and on post-OPEN success, but no compile-time / runtime check that it isn't left set across a non-fileio code path. Defensive concern only — no caller today does this. [src/statusln.asm] — deferred, defensive

## Dev Notes

### Architecture compliance

This story lands Architecture's **Implementation Sequence** step 9 partial (`fileio.asm`) and the FR6 / FR9 / FR10 / FR11 / FR51 surface from the PRD. The wider architecture mapping:

- **FR6 (User can open a different file, replacing the current buffer — `:e filename`).** First production realisation. `cmd_edit` parses the argument, dirty-checks (BH6), and delegates to `fileio_load`.
- **FR9 (Drive-B default for bare filenames).** `fileio_parse_filename` writes drive byte = 2 (B:) into fcb_scratch[0] when no `[A-Za-z]:` prefix is present.
- **FR10 (Explicit drive-letter prefix).** `fileio_parse_filename` recognises `[A-Za-z]:` and sets the drive byte accordingly (case-insensitive; uppercase-normalised).
- **FR11 (Oversize refusal).** `fileio_load`'s pre-read budget check (Sub 1.7) catches the impending overflow before BDOS_READ_SEQ. Buffer is left empty (gapbuf_init re-issued on abort), filename_buffer[0] zeroed, msg_file_too_large surfaced.
- **FR50 (No-op on unsupported commands).** Inherited from Story 2.1's exline_dispatch no-match path — applies if the user types `:exx` (no such command).
- **FR51 (CP/M file-I/O failure surfacing).** `bdos_error_pre_msg` mechanism (AC7/AC11) lets fileio_load surface "can't open FILENAME" instead of the generic "bdos error" funnel default. The read-error path (rc >= 2) goes through `fileio_abort_read_error` which surfaces msg_read_error.
- **FR52 / NFR6 (No silent data loss).** `cmd_edit`'s dirty refusal protects unsaved changes. `:e!`'s explicit consent bypasses the check.
- **AR12 (Single status-message funnel — `status_set_message`).** Every status row update in fileio.asm goes through `status_set_message` (composed scratch buffers are handed to the funnel via HL). bdos_error_funnel's revised body still routes through status_set_message; the override mechanism is purely in WHICH pointer the funnel hands to status_set_message.
- **AR13 (Single screen-emission path — render.asm only).** `fileio.asm` has zero BIOS_CONOUT references. The load's screen update flows: fileio_load → render_mark_all_dirty (sets dirty_rows to all-ones) → render_diff (next input loop) emits every row from the loaded buffer.
- **AR14 (Single buffer-mutation owner — `gapbuf.asm`).** **CARVE-OUT** documented in AC12 + the fileio.asm header. fileio writes `gap_start` during the linear-fill load loop; the SR2 two-halves invariant holds at every intermediate state (content lives entirely in [GAP_BUFFER_BASE, gap_start); after-gap region is unused; cursor at 0). After the final `gapbuf_move_gap(0)`, control returns to gapbuf's invariant-maintaining surface.
- **AR15 (Single BDOS gateway — `BDOS_CALL` macro).** Every BDOS call in fileio.asm uses the macro: BDOS_SET_DMA (Step 6), BDOS_OPEN (Step 4), BDOS_READ_SEQ (Step 8 loop), BDOS_CLOSE (Steps 6 of AC5 post-load and the two abort paths). No raw `CALL 0x0005` or `CALL BDOS_ENTRY`.
- **AR16 (Status-message string convention).** New messages — `msg_missing_filename` (16 chars), `msg_read_error` (15 chars), `fileio_msg_cant_open_prefix` "can't open " (11 chars + interpolated filename). All lowercase, no trailing period. The dynamic "FILENAME N bytes" status string composed at load-success — also lowercase except for the filename (which passes through as the user typed it, per AR16's "filenames are user-provided and pass through untouched"). Wait — the filename is stored in fcb_scratch and filename_buffer as **uppercase** (per CP/M convention). So the status row will show `B:FOO.FS 13 bytes` (uppercase filename + lowercase tail), which matches CP/M idiom and AR16's "filenames pass through". For Story 2.2 we explicitly chose uppercase storage; the AR16 "all lowercase" rule applies to the text MESSAGES, not the interpolated filename.
- **AR22 (Naming).** New public symbols: `fileio_load`, `cmd_edit`, `cmd_edit_force`. Internal labels (dotted-locals): `.next_entry`, `.no_match`, `.read_loop`, etc. Equates / macros (none new). The `cmd_*` prefix matches Story 2.1's `cmd_quit` / `cmd_quit_force` pattern.
- **AR23 (File structure and routine contracts).** `src/fileio.asm` starts with the standard header block (Module / Purpose / Public / State owned / State read-only / Register conventions / Dependencies). Every public routine and significant internal helper begins with the four-line `In:` / `Out:` / `Trashes:` / `Calls:` contract.
- **AR24 (Format).** 4-space indentation, UPPERCASE mnemonics, `;` line / `;;` section comments, no trailing periods.
- **AR25 (Module include order).** `fileio.asm` lands AFTER `exline.asm` in `src/vibe.asm`'s INCLUDE chain. The architecture's full order is `parser → motions → edits → visual → search → exline → fileio → undo`; with motions/edits/visual/search not yet present, fileio slots immediately after exline.

### Library / framework requirements

**sjasmplus 1.23.0:**
- Already pinned by Makefile's `check-toolchain`.
- **Forward references resolve on second pass.** In `fileio.asm`, the BDOS_CALL macro expansions reference `bdos_error_funnel` (backward — statusln.asm INCLUDEs before fileio.asm). `status_set_message`, `gapbuf_init`, `gapbuf_move_gap`, `render_mark_all_dirty`, `msg_file_too_large`, `msg_read_error`, `msg_missing_filename` are all backward references. The only forward references inside fileio.asm are within itself (file-local labels). No new forward-reference scenarios introduced.
- **In `exline.asm`**, the new `cmd_edit` / `cmd_edit_force` handlers reference `fileio_load` and `fileio_strip_leading_spaces` (in fileio.asm which is INCLUDEd AFTER exline.asm) — these are forward references resolved by sjasmplus's two-pass model. Same pattern as `dispatch.asm`'s table forward-references to exline_* symbols in Story 2.1.

**iz-cpm:**
- All eight new headless tests run under iz-cpm.
- Fixtures mounted via `-a` and `-b` flags (test/Makefile already does this).
- The new `big.bin` and `eof1a.txt` fixtures need Makefile rules to generate them; the rules go in `test/Makefile` (the test-side Makefile, not the project-root one — keep generation logic close to consumers).
- **`bdos_error_funnel`'s ex-line cleanup (AC11)** runs under iz-cpm too — the funnel's `JP input_loop` lands in the test's `input_loop` stub. The stub captures the funnel-entered sentinel and JPs to a labelled post-fail-assertions block in the test body. Same pattern as Story 1.12's `init_cold_start-state-shape.asm` used.

**CP/M 2.2 BDOS / MicroBeast BIOS:**
- New BDOS surface: BDOS_OPEN (15), BDOS_CLOSE (16), BDOS_READ_SEQ (20), BDOS_SET_DMA (26). All 2.2-standard functions; NFR15 holds.
- **`BDOS_SET_DMA` is new** to `inc/bdos.inc`. It's a 2.2-standard function (the architecture's enumeration listed only those used by Story 1.x; Story 2.2 is the first BDOS_SET_DMA caller).
- **FCB shape — 36 bytes:** drive byte (1), basename (8), extension (3), extent (1), S1 (1), S2 (1), record count (1), allocation map (16), current record (1), random record (3). For sequential read, the relevant bytes are drive + basename + extension + current-record (which is auto-managed by BDOS_OPEN's setting it to 0). Everything else stays zero from the initial DEFS 36, 0 + parse-overwrite-front.
- **DEFAULT_DMA at 0x0080** is the CP/M-standard initial DMA. CCP doesn't touch it during the .com load; our use is consistent with CP/M idiom.
- **No assumed file-size oracle.** CP/M 2.2 BDOS has no "stat" or "get file size" call (those arrived in CP/M 3.x and BDOS function numbers we don't use per NFR15). The only way to know a file's size is to read it. Hence the post-hoc oversize check at AC9.

### Filename parse — edge cases

- **Empty filename** (just `:e<Enter>` or `:e   <Enter>`): cmd_edit's pre-check fires (A=0 after strip-leading-spaces), surfaces msg_missing_filename, no fileio_load call. Test fileio_e-missing-filename.asm.
- **Lowercase filename `:e foo.fs`:** parse → uppercase → "FOO.FS" → fcb_scratch[1..8] = "FOO     ", [9..11] = "FS ". filename_buffer = "B:FOO.FS\0".
- **Uppercase filename `:e FOO.FS`:** same result (idempotent uppercase).
- **No extension `:e foo`:** fcb_scratch[1..8] = "FOO     ", [9..11] = "   " (all spaces). filename_buffer = "B:FOO\0" (no trailing dot for an empty extension).
- **Just an extension `:e .fs`:** ambiguous CP/M syntax. Pick: treat as empty basename. fcb_scratch[1..8] = "        ", [9..11] = "FS ". filename_buffer = "B:.FS\0" (with the leading dot). **CP/M will likely reject the open** (empty basename is not a valid filename). The user sees "can't open B:.FS" — acceptable.
- **Path-like `:e foo/bar`:** CP/M has no directories; the `/` is just a filename byte. fcb_scratch[1..8] = "FOO/BAR " (truncated to 8 with the `/`). The open will likely fail. Acceptable for Story 2.2; CP/M-conformant.
- **Lowercase drive `:e b:foo.fs`:** parse → drive byte 2, basename "FOO     ", extension "FS ". filename_buffer = "B:FOO.FS\0".
- **Multiple drive prefixes `:e a:b:foo.fs`:** parse consumes the first `[A-Za-z]:`, advances. The remaining `b:foo.fs` becomes the basename — uppercased: `B:FOO.FS` truncated to 8 → `B:FOO.FS` (exactly 8 chars including `:` — though `:` isn't valid in CP/M basenames). The open will fail; acceptable.

### Read loop — performance and correctness

- **Per-sector cost.** Each BDOS_READ_SEQ takes ~10-50 ms on a real CP/M host (depending on storage); on iz-cpm it's microseconds. 256 sectors max (32 KB / 128) → real-host load time ~3-13 seconds for a full-buffer file. Headless tests use small fixtures and run in <100 ms total.
- **128-byte LDIR.** From DEFAULT_DMA (0x0080) to gap_start: 21 T-states/byte × 128 = ~2700 T-states = ~675 µs at 4 MHz. Negligible.
- **0x1A scan.** Per-sector scan for 0x1A: 128 byte-compares = ~640 T-states. Cumulative across 256 sectors ≈ 41 ms — still negligible.
- **`gapbuf_move_gap(0)` post-load.** LDDR file_size bytes — 21 T-states/byte × file_size = ~5 ms for a 1-KB file, ~170 ms for a full 32-KB file. The 32-KB case is the worst case and only matters when loading a near-full file; acceptable for an on-demand operation.

### Previous story intelligence

**From Story 2.1 (most relevant — set up the exline infrastructure this story extends):**
- `exline_command_table`'s walk format (NUL-terminated keys + 2-byte handlers + zero-byte terminator) is preserved; Story 2.2 only adds entries and changes the match semantics from "whole ex_buffer" to "first token of ex_buffer".
- The dispatch tokenisation change is the principal logic refactor in exline.asm. Story 2.1's compare loop is replaced with: (1) find the first space in ex_buffer_text, capture `cmd_len`; (2) the table walk's length-check compares against `cmd_len` instead of ex_buffer's full length; (3) the byte-compare loop is unchanged.
- The cancel/banner split (`exline_cancel` vs `exline_cancel_core`) is preserved and reused by cmd_edit / cmd_edit_force.
- The pre-Story-2.2 `bdos_error_funnel` body in statusln.asm unconditionally surfaces `msg_bdos_error` and JPs input_loop. Story 2.2 modifies this; tests written against Story 2.1's assumption that the funnel writes msg_bdos_error must continue to pass — Story 2.2's override mechanism falls back to msg_bdos_error when no caller-side pre_msg pointer is set.
- The exline_command_table currently has 2 entries; Story 2.2 takes it to 4. The structural-ASSERTs deferral (deferred-work.md:104) considers 4 still hand-auditable; defer to Story 2.4 / 3.1.

**From Story 1.12 (init/teardown — the existing AR15 macro use site):**
- `init_teardown` is reached only from cmd_quit / cmd_quit_force. Story 2.2 adds new AR15 macro use sites (in fileio.asm) — the second cluster of BDOS_CALL invocations in the project. The macro's `JP M, bdos_error_funnel` contract is preserved across the new use sites.
- `init_cold_start` performs an LDIR fill across the entire static block. The new `filename_buffer` (16 bytes, declared in state.inc) gets zero-init from this fill. Story 2.2's first :e or :e! call writes filename_buffer in fileio_parse_filename's step.

**From Story 1.11 (render pipeline — relevant for the load's screen update):**
- `render_mark_all_dirty` is the canonical "mark every row dirty" entry. fileio_load's post-load step 9 calls it. The next `render_diff` (run by the input loop after cmd_edit returns) re-emits every editable row from the loaded buffer.
- The control-char rendering issue (deferred-work.md:76) is a known limitation: bytes like 0x09 (TAB), 0x0D (CR), high-bit bytes get emitted raw. For Story 2.2's hardware UAT, restrict fixtures to plain ASCII to avoid hitting this seam. The headless tests use deterministic fixtures so the seam doesn't matter at test time.

**From Story 1.7 (gap buffer — `gapbuf_load` stub being retired by Story 2.2):**
- The Story-1.7 gapbuf_load stub returned CF=1 + msg_not_implemented. Story 2.2 deletes the stub entirely (Task 3). Any future caller would need to use `fileio_load` or a new gapbuf primitive (none planned).
- `gapbuf_init` (the empty-buffer reset) is the load's reset target. SR2's "bytes inside the gap are read-as-undefined" means the post-init gap contains residual bytes — but they're invisible through the two-halves walk. fileio_load's linear-fill writes the loaded bytes into the before-gap region, overwriting the residue.
- `gapbuf_move_gap` accepts HL = target offset; for fileio_load's post-load shift, HL = 0 moves the gap to position 0, putting all content in the after-gap region. SR2 holds.

**From Story 1.5 (statusln — bdos_error_funnel modification target):**
- The funnel's existing JP-to-input_loop is preserved. Story 2.2's modification adds three pre-JP cleanup writes (ex_buffer length = 0, mode = NORMAL, status_dirty = 1) plus the override-pointer read + clear.
- `msg_bdos_error` ("bdos error") remains the default; the override mechanism only redirects when a caller has pre-staged a context-rich pointer.
- `msg_no_write` is reused by cmd_edit's dirty refusal (same banner as Story 2.1's cmd_quit's dirty refusal — vi-canonical "no write since last change").

**From Story 1.4 (BDOS_CALL macro — Story 2.2's first heavy user):**
- The macro `LD C, fn ; CALL BDOS_ENTRY ; OR A ; JP M, bdos_error_funnel` is unchanged. The `JP M` catches sign-bit (0xFF) returns. For BDOS_OPEN, 0xFF = not-found / cannot-open; for BDOS_READ_SEQ, sign-bit codes are rare (typically 0 or 1; 2-9 are bit-7-clear errors that don't trip JP M — caller checks A explicitly).
- The macro's per-fn arg passing: DE = FCB ptr is the universal convention for FCB ops. fileio_load loads `LD DE, fcb_scratch` before each call.

### Git intelligence

Thirteen commits on `main` after the project skeleton (most-recent five per `git log`):

- `be42853` — story 2.1: Wrote the : command-line; :q quits, :q! force-quits, Backspace and Esc work
- `0ef09de` — story 1.12: Wired init/teardown, the main input loop, and the first on-hardware smoke test.
- `dc2dd0d` — story 1.11: Wrote the screen renderer: dirty-row diff, scroll, Ctrl-L full redraw, status row.
- `e9f291a` — story 1.10: Wrote the command parser: counts, pending operators, and the gg motion-prefix.
- `6084103` — story 1.9: Wrote the key dispatcher: binary-searches a per-mode table to find the handler.

Conventions visible in the tree (preserve in Story 2.2):
- One story per commit; short imperative subject + colon-separated context. Match the user's plain-English style.
- AR23 header blocks on every `.asm` and `.inc` file.
- Every public routine has the `In:` / `Out:` / `Trashes:` / `Calls:` four-line contract.

Suggested commit message for Story 2.2 (when the dev finishes): `story 2.2: Wrote file load; :e and :e! open files via FCB-based BDOS reads.` Match the prior stories' plain-English style.

### Testing requirements

Story 2.2's testing requirements split into four categories:

**Build-time / static:**

1. `make` from project root succeeds (NFR14 / AC15).
2. `make clean && make` produces byte-identical `vibe.com` across two consecutive runs (NFR18 / AC15). Capture both SHAs.
3. `make sizes` reports the code-section size (NFR9 baseline / AC15). Capture verbatim; note delta vs Story 2.1's 2243 B.
4. AR grep sweeps (AC15) — all clean.

**Headless test cases (8 new):**

5. `fileio_load-small-file.asm` — clean load of hello.txt; post-state assertions.
6. `fileio_load-with-1A-eof.asm` — 0x1A mid-sector stops the load.
7. `fileio_load-not-found.asm` — bdos_error_pre_msg path; funnel writes the right banner; ex-line state cleaned.
8. `fileio_load-too-large.asm` — pre-read budget check fires; buffer empty post-abort.
9. `fileio_load-drive-prefix.asm` — A: prefix parses correctly.
10. `fileio_e-dirty-refusal.asm` — cmd_edit refuses on dirty buffer.
11. `fileio_e-bang-force-dirty.asm` — cmd_edit_force bypasses the dirty check.
12. `fileio_e-missing-filename.asm` — cmd_edit with no arg surfaces msg_missing_filename.

13. **Live baseline becomes at least 36 pass / 1 fail** (28 pre-2.2 + 8 new + the deliberate `harness_fail`).

**Hardware UAT (AC14):**

14. SLIDE-push and launch from CCP. `:e bdos.txt` loads the file; status shows the byte count; mode is NORMAL.
15. `:q` from a freshly-loaded clean buffer exits cleanly.
16. `:e nosuch.fs` surfaces "can't open B:NOSUCH.FS"; buffer remains empty; mode NORMAL.
17. `:e a:test.fs` loads from A: with the right filename_buffer display.
18. Dirty-refusal hardware UAT deferred to Story 2.8 (same trade-off as Story 2.1's AC7).

**Regression watch:**

19. Existing 28 headless tests continue to pass (no Story 1.x or 2.1 regressions from exline.asm's dispatch tokenisation change or statusln.asm's funnel modification).
20. The Story-1.12 hardware-UAT'd flows (Ctrl-L full refresh, mode banners, Esc-back-to-NORMAL from any mode, sustained typing) remain green on a 30-second sustained-typing UAT after Story 2.2.
21. Story 2.1's hardware UAT flows (`:q`, `:q!`, `:foo` unknown-command, `:` + Backspace + Esc + char entry) remain green after Story 2.2.

### Project Structure Notes

After Story 2.2 the source tree is:

```
src/
├── vibe.asm          # Top-level — Story 2.2 adds INCLUDE "fileio.asm" after exline.asm
├── init.asm          # Story 1.12 (unchanged by 2.2)
├── input.asm         # Story 1.8 (unchanged by 2.2)
├── statusln.asm      # Story 1.5 / 1.9 / 2.1 / 2.2 — msg_missing_filename / msg_read_error added;
│                     #   bdos_error_pre_msg cell + funnel override mechanism
├── gapbuf.asm        # Story 1.7 / 2.2 — gapbuf_load stub REMOVED
├── render.asm        # Story 1.11 / 2.1 (unchanged by 2.2)
├── dispatch.asm      # Story 1.9 / 2.1 (unchanged by 2.2)
├── parser.asm        # Story 1.10 (unchanged by 2.2)
├── exline.asm        # Story 2.1 / 2.2 — exline_dispatch tokenises; cmd_edit / cmd_edit_force added;
│                     #   exline_command_table extended to 4 entries
└── fileio.asm        # Story 2.2 — NEW (FCB-based file load + status composition)

inc/
├── equates.inc       # Story 1.2 (unchanged by 2.2)
├── bios.inc          # Story 1.4 / 1.12 (unchanged by 2.2)
├── bdos.inc          # Story 1.4 / 2.2 — BDOS_SET_DMA EQU 26 added
├── modes.inc         # Story 1.2 (unchanged by 2.2)
├── vt52.inc          # Story 1.2 / 1.12 (unchanged by 2.2)
└── state.inc         # Story 1.3 / 1.12 / 2.1 (unchanged by 2.2; filename_buffer already declared)

test/
├── README.md
├── Makefile          # Story 2.2 — Makefile rules for test/fixtures/eof1a.txt + big.bin
├── inc/              # (unchanged by 2.2)
├── fixtures/
│   ├── hello.txt     # (existing — 13 bytes)
│   ├── eof1a.txt     # Story 2.2 — generated by Makefile (printf'abc\x1axyz')
│   └── big.bin       # Story 2.2 — generated by Makefile (dd if=/dev/zero bs=128 count=264)
└── cases/
    ├── ... (existing 28 cases unchanged)
    ├── fileio_load-small-file.asm        # NEW
    ├── fileio_load-with-1A-eof.asm       # NEW
    ├── fileio_load-not-found.asm         # NEW
    ├── fileio_load-too-large.asm         # NEW
    ├── fileio_load-drive-prefix.asm      # NEW
    ├── fileio_e-dirty-refusal.asm        # NEW
    ├── fileio_e-bang-force-dirty.asm     # NEW
    └── fileio_e-missing-filename.asm     # NEW
```

### Files created and modified by this story

**Files created:**
- `src/fileio.asm` (new — primary deliverable; ~350-500 lines including AR23 header).
- `test/cases/fileio_load-small-file.asm` (new).
- `test/cases/fileio_load-with-1A-eof.asm` (new).
- `test/cases/fileio_load-not-found.asm` (new).
- `test/cases/fileio_load-too-large.asm` (new).
- `test/cases/fileio_load-drive-prefix.asm` (new).
- `test/cases/fileio_e-dirty-refusal.asm` (new).
- `test/cases/fileio_e-bang-force-dirty.asm` (new).
- `test/cases/fileio_e-missing-filename.asm` (new).

**Files modified:**
- `src/vibe.asm` — INCLUDE fileio.asm after exline per AR25; header Dependencies updated.
- `src/exline.asm` — exline_dispatch tokenisation refactor; cmd_edit / cmd_edit_force handlers added; exline_command_table extended to 4 entries; header Public list + Dependencies updated.
- `src/gapbuf.asm` — gapbuf_load stub deleted (body + contract + Public-list entry); header swept.
- `src/statusln.asm` — msg_missing_filename + msg_read_error added; bdos_error_pre_msg cell added; bdos_error_funnel body rewritten with override + inline ex-line cleanup; header swept.
- `inc/bdos.inc` — BDOS_SET_DMA EQU 26 added; header Public list updated.
- `test/Makefile` — rules added for fixture generation (eof1a.txt, big.bin) and the build chain.
- `test/.gitignore` (or repo-root `.gitignore`) — `test/fixtures/big.bin` added if not already covered.
- `_bmad-output/implementation-artifacts/deferred-work.md` — sub-bullets noting Story-2.1 deferrals' status (table-structure ASSERTs re-deferred to 2.4/3.1; test stub refactor remains deferred).

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md] lines 902-951
- Previous story (Ex command-line + :q/:q!, Story 2.1 — built the exline infrastructure this story extends): [Source: _bmad-output/implementation-artifacts/2-1-ex-command-line-infrastructure-q-q.md]
- Adjacent story (Launch with filename, Story 2.3 — uses the default FCB at 0x005C populated by CCP; calls into fileio_load with the parsed filename): [Source: _bmad-output/planning-artifacts/epics.md] lines 953-989
- Adjacent story (File save, Story 2.4 — extends exline_command_table with `w` / `wq` entries; reuses fcb_scratch and the BDOS_SET_DMA discipline; reuses bdos_error_pre_msg mechanism for write-fail context): [Source: _bmad-output/planning-artifacts/epics.md] lines 991-1044
- FR6 (User can open a different file, replacing the current buffer — `:e filename`): [Source: _bmad-output/planning-artifacts/prd.md] lines 700-701
- FR9 (VIBE resolves bare filenames to drive B:): [Source: _bmad-output/planning-artifacts/prd.md] line 705
- FR10 (VIBE accepts explicit drive-letter prefixes): [Source: _bmad-output/planning-artifacts/prd.md] lines 706-707
- FR11 (VIBE refuses to load files exceeding the gap buffer): [Source: _bmad-output/planning-artifacts/prd.md] lines 708-709
- FR51 (VIBE surfaces every CP/M file-I/O failure): [Source: _bmad-output/planning-artifacts/prd.md] lines 793-797
- FR52 (No silent data loss on save — sister of FR51 for the save side): [Source: _bmad-output/planning-artifacts/prd.md] lines 799-802
- NFR6 (No silent data loss): [Source: _bmad-output/planning-artifacts/prd.md] lines 833-839
- NFR8 (BDOS error handling completeness — every BDOS call checks rc): [Source: _bmad-output/planning-artifacts/prd.md] lines 840-842
- NFR9 (code budget): [Source: _bmad-output/planning-artifacts/prd.md] lines 848-851
- NFR14 (sjasmplus 1.23.0): [Source: _bmad-output/planning-artifacts/prd.md] lines 870-871
- NFR15 (CP/M 2.2 BDOS only): [Source: _bmad-output/planning-artifacts/prd.md] lines 872-874
- NFR16 (knob centralization in equates.inc): [Source: _bmad-output/planning-artifacts/prd.md] lines 879-881
- NFR18 (reproducible build): [Source: _bmad-output/planning-artifacts/prd.md] lines 886-887
- AR12 / MC5 (status-message funnel — `status_set_message`): [Source: _bmad-output/planning-artifacts/architecture.md] lines 535-541
- AR13 (single screen-emission path — render.asm only; fileio doesn't emit): [Source: _bmad-output/planning-artifacts/architecture.md] (PRD/EP refs); fileio.asm has zero BIOS_CONOUT.
- AR14 (single buffer-mutation owner — gapbuf.asm; fileio.asm takes a documented carve-out): see AC12 in this story.
- AR15 / MC6 (single BDOS gateway — BDOS_CALL macro): [Source: _bmad-output/planning-artifacts/architecture.md] lines 543-548
- AR16 (status-message string convention): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1003-1037
- AR22 (naming): module_action lowercase; UPPER_SNAKE for equates / macros: [Source: _bmad-output/planning-artifacts/architecture.md] lines 788-850
- AR23 (file structure and routine contracts): [Source: _bmad-output/planning-artifacts/architecture.md] lines 852-916
- AR24 (format conventions): [Source: _bmad-output/planning-artifacts/architecture.md] lines 958-1001
- AR25 (module include order — fileio between exline and undo): [Source: _bmad-output/planning-artifacts/architecture.md] lines 940-956
- BH5 (`:q` with unsaved changes — refusal pattern; reused by cmd_edit's dirty refusal): [Source: _bmad-output/planning-artifacts/architecture.md] lines 699-702
- BH6 (`:e` with unsaved changes — same policy as `:q`; `:e!` to force is in MVP scope): [Source: _bmad-output/planning-artifacts/architecture.md] lines 704-706
- PRD read-side architecture (`:e` BDOS open + sequential-read; 0x1A termination; vi-default initial gap position): [Source: _bmad-output/planning-artifacts/prd.md] lines 535-542
- PRD platform constraints (Drive B: default; explicit drive-letter prefix; no fallback search): [Source: _bmad-output/planning-artifacts/prd.md] lines 359-380
- Module Dependency Graph (exline → fileio → BDOS): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1417-1418
- FR↔Module mapping (FR6 / FR9 / FR10 / FR11 → fileio.asm): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1516-1519
- FR51 enforcement location (fileio.asm + BDOS_CALL macro + statusln.asm): [Source: _bmad-output/planning-artifacts/architecture.md] line 1533
- Data Flow (Keystroke Lifecycle — handler may CALL status_set_message; render_diff fires after handler returns): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1468-1505
- Static Memory Map (filename_buffer declaration; ex_buffer_text symbol for length-prefixed buffer access): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1341-1399
- Deferred-from-2.1 (exline_command_table structural ASSERTs — re-deferred by Story 2.2): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 104
- Deferred-from-2.1 (test stub refactor for init_teardown — stays deferred): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 103
- Deferred-from-1.11 (TAB / CR / NUL / high-bit byte rendering — known seam; UAT fixtures restricted to plain ASCII to avoid): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 76
- Deferred-from-1.6 (CP/M 0x1A EOF marker in fixtures — Story 2.2's fileio_load-with-1A-eof.asm exercises this): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 58
- inc/state.inc (filename_buffer at static_data_base + offset, 16 bytes; FILENAME_BUFFER_SIZE = 16 in equates.inc): [Source: inc/state.inc] line 108
- inc/equates.inc (FILENAME_BUFFER_SIZE = 16; GAP_BUFFER_MAX = 32768): [Source: inc/equates.inc] lines 31, 41
- inc/bdos.inc (BDOS_OPEN = 15, BDOS_CLOSE = 16, BDOS_READ_SEQ = 20; BDOS_CALL macro contract; bdos_error_funnel forward reference): [Source: inc/bdos.inc] lines 35-88
- inc/bios.inc (DEFAULT_FCB = 0x005C, DEFAULT_DMA = 0x0080, BDOS_ENTRY = 0x0005): [Source: inc/bios.inc] lines 63-65
- src/statusln.asm (bdos_error_funnel body — Story 2.2 modification target; msg_no_write, msg_file_too_large, msg_bdos_error): [Source: src/statusln.asm] lines 101-180
- src/exline.asm (exline_dispatch, exline_command_table, cmd_quit, cmd_quit_force, exline_cancel_core — Story 2.2 modification target): [Source: src/exline.asm]
- src/gapbuf.asm (gapbuf_load stub — Story 2.2 deletion target; gapbuf_init, gapbuf_move_gap — Story 2.2 callees): [Source: src/gapbuf.asm] lines 255-280, 55-62, 178-254
- src/render.asm (render_mark_all_dirty — Story 2.2 callee; render_diff handles all-dirty marking via the existing diff loop): [Source: src/render.asm]
- src/vibe.asm (input_loop body; AR25 INCLUDE chain — Story 2.2 adds INCLUDE "fileio.asm" after exline.asm): [Source: src/vibe.asm] lines 123-135
- test/Makefile (test infrastructure; iz-cpm -a / -b fixture mounting): [Source: test/Makefile]
- Story 2.1 (Ex command-line — primary prior-art reference): [Source: _bmad-output/implementation-artifacts/2-1-ex-command-line-infrastructure-q-q.md]
- Story 1.12 (init/teardown — first AR15 macro use site; precedent for the funnel→input_loop pattern): [Source: _bmad-output/implementation-artifacts/1-12-init-teardown-on-hardware-smoke-test.md]
- Story 1.7 (gap buffer — gapbuf_load stub origin; SR2 invariant; gapbuf_init and gapbuf_move_gap contracts): [Source: _bmad-output/implementation-artifacts/1-7-gap-buffer-primitives-headless-tests.md]
- Story 1.5 (statusln — AR12 funnel + bdos_error_funnel default body): [Source: _bmad-output/implementation-artifacts/1-5-status-line-module-with-single-message-funnel.md]

## Dev Agent Record

### Agent Model Used

claude-opus-4-7[1m] (Opus 4.7, 1M context)

### Debug Log References

**Build (NFR14 / NFR18 / NFR9 / AC15):**
- `make clean && make` — passes; sjasmplus 1.23.0 pinned by Makefile's `check-toolchain`.
- Two consecutive `make clean && make` runs produce byte-identical `vibe.com`:
  - SHA-256 (run 1): `30311cba5acd1f810c0015a82da90be54338b939bc8879cbd93c6001f547bd79`
  - SHA-256 (run 2): `30311cba5acd1f810c0015a82da90be54338b939bc8879cbd93c6001f547bd79` (matches)
- `make sizes` post-2.2: `code_section: 3106 bytes (~101% of NFR9 ~3 KB budget)`. Story-2.1 baseline was 2243 B; delta = +863 B. Story spec at AC15 projected +470-615 B (final 2700-2860 B / 88-93%). Actual is 246 B over the high estimate, and 34 B over the hard 3 KB ceiling — see Completion Notes for the size-budget observation and three applied optimisations.

**Headless tests (AC13):**
- `make test` — 36 pass / 1 deliberate fail (`harness_fail` — pinned-by-design). Matches story-spec target of 28 pre-2.2 + 8 new.
- New cases (8):
  - `fileio_e-missing-filename` — `:e` with no arg surfaces msg_missing_filename.
  - `fileio_e-dirty-refusal` — `:e foo.fs` on dirty buffer surfaces msg_no_write.
  - `fileio_e-bang-force-dirty` — `:e! hello.txt` on dirty buffer loads (buffer_dirty resets to 0).
  - `fileio_load-small-file` — load `hello.txt` (13 bytes); cursor=0, gap_start=BASE, content match, status prefix "B:HELLO.TXT ".
  - `fileio_load-with-1A-eof` — load `eof1a.txt` ("abc" + 0x1A + "xyz"); only 3 bytes loaded; status = "B:EOF1A.TXT 3 bytes".
  - `fileio_load-drive-prefix` — `a:hello.txt` → filename_buffer "A:HELLO.TXT\0".
  - `fileio_load-not-found` — funnel + override path; status_buffer = "can't open B:NOSUCH.FS"; ex_buffer cleared; mode = NORMAL.
  - `fileio_load-too-large` — `big.bin` (33792 B); pre-read budget check fires; buffer reset; filename_buffer[0] = 0; status = "file too large".

**AR enforcement greps (AC15):**
- AR13 (`BIOS_CONOUT` outside render.asm, call sites only): zero matches. The single hit in `src/bios_1_7.inc` is a vendor-reference EQU, not a call site.
- AR14 (`LD (gap_start)` writes outside gapbuf.asm): two matches in `src/fileio.asm:525,539` — both bear the inline `; AR14 carve-out: fileio_load linear-fill phase` annotation and are documented in the module's AR23 header.
- AR15 (raw `CALL 0x0005 / CALL BDOS_ENTRY` in fileio.asm): zero matches. Five `BDOS_CALL` macro use sites (BDOS_OPEN, BDOS_SET_DMA, BDOS_READ_SEQ, BDOS_CLOSE in fileio_load + BDOS_CLOSE in fileio_abort_common).
- `gapbuf_load` mentions: one comment-only match in `src/gapbuf.asm:16` (the retirement note). Stub body deleted; no callers anywhere.

### Completion Notes List

**Implementation summary:**
- `src/fileio.asm` (new) lands `fileio_load` orchestrating BDOS_OPEN → SET_DMA → READ_SEQ loop → CLOSE, with the 0x1A EOF scan in `fileio_ingest_sector` and the post-load `gapbuf_move_gap(0)` content shift. The AR14 carve-out (linear-fill phase writes `gap_start` directly) is documented in the AR23 header and at each call site.
- `fileio_parse_filename` handles drive prefixes (case-insensitive `[A-Za-z]:`), uppercases basename + extension into the 36-byte FCB scratch, and composes the canonical display form into `filename_buffer` (trimming trailing spaces; no dot if extension is empty).
- The bdos_error_pre_msg override mechanism in `src/statusln.asm`: file-local 2-byte pointer; the funnel surfaces the pointed-to message in place of `msg_bdos_error` if non-zero, clears the cell after use, and inlines the ex-line cleanup (ex_buffer length = 0, mode = MODE_NORMAL, status_dirty = 1) before JPing to `input_loop`. Wired by `fileio_load`'s pre-OPEN stage of the "can't open FILENAME" banner.
- `src/exline.asm` reworked: `exline_dispatch` tokenises ex_buffer at the first space, caches `cmd_len` in a 1-byte file-local cell, and walks the table with the new contract (handler entered with HL = arg-region ptr, A = arg-region length). `cmd_edit` / `cmd_edit_force` added; the command table grew from 2 to 4 entries (`e`, `e!`, `q`, `q!`).
- `src/gapbuf.asm` retired the Story-1.7 `gapbuf_load` stub entirely (body + Public list entry + dependencies sweep). Real load lives in fileio.asm.
- `inc/bdos.inc` gained `BDOS_SET_DMA EQU 26`; `src/vibe.asm` INCLUDEs fileio.asm after exline.asm per AR25.

**Three size optimisations applied to the first-cut implementation:**
1. `fileio_u16_to_dec`'s emit-flag check rewritten — combined the "digit is zero AND emit-flag clear" suppression into a single `LD A,B; OR C; RET Z`, saving 6 bytes.
2. `fileio_abort_too_large` + `fileio_abort_read_error` consolidated into a shared `fileio_abort_common` body (entry points differ only in the message-pointer load), saving 28 bytes.
3. The byte-count tally `fileio_loaded_count` cell retired — the loaded count is now derived from `gap_start - GAP_BUFFER_BASE` at post_load time, captured BEFORE `gapbuf_move_gap(0)` rearranges the halves; saved 20 bytes (per-sector tracking + the cell + the setup).

**Size-budget observation (AC15 — over 95%):**
- Post-2.2 footprint: 3106 B vs NFR9 hard ceiling 3072 B (~101%). Story spec at AC15 projected 88-93% and asked for a notable-observation report if >95%. The 34-byte overshoot persists after the three optimisations above; further trim is possible but trades readability (e.g. share basename/ext loops in `fileio_parse_filename`, extract a common upper-A helper). Architectural alternatives like a `gapbuf_bulk_append` primitive (replacing the AR14 carve-out) would push the overshoot further. Recommended decision: accept the 1% overage or open a follow-up code-shrink story. See deferred-work.md entry.

**Hardware UAT (AC14) deferred to user (Task 11):**
- Cannot SLIDE-push from this dev environment; requires `make push` + on-MicroBeast execution of the 10-step UAT script (`:e bdos.txt`, `:q`, `:e nosuch.fs`, `:e a:test.fs`, etc.). Same pattern as Stories 1.11 / 1.12 — the user runs the hardware UAT before marking the story done.

### File List

**Files created:**
- `src/fileio.asm`
- `test/cases/fileio_load-small-file.asm`
- `test/cases/fileio_load-with-1A-eof.asm`
- `test/cases/fileio_load-not-found.asm`
- `test/cases/fileio_load-too-large.asm`
- `test/cases/fileio_load-drive-prefix.asm`
- `test/cases/fileio_e-dirty-refusal.asm`
- `test/cases/fileio_e-bang-force-dirty.asm`
- `test/cases/fileio_e-missing-filename.asm`

**Files modified:**
- `src/vibe.asm` — INCLUDE fileio.asm after exline per AR25; header Dependencies updated.
- `src/exline.asm` — exline_dispatch tokenisation refactor; cmd_edit + cmd_edit_force handlers added; exline_command_table extended from 2 to 4 entries; new exline_cmd_len data cell; header Public list + Dependencies + AR-enforcement block updated; cmd_quit / cmd_quit_force contracts annotated "HL, A = ignored" (additive).
- `src/gapbuf.asm` — gapbuf_load stub body + Public list entry deleted; header Dependencies swept.
- `src/statusln.asm` — msg_missing_filename + msg_read_error added; bdos_error_pre_msg cell added; bdos_error_funnel body rewritten with override + inline ex-line cleanup; header Public list + State-owned + Dependencies updated.
- `src/fileio.asm` — Story 2.2 (the file is "created" above, but listed again for the AR14 carve-out inline annotations on the two `LD (gap_start), DE` sites).
- `inc/bdos.inc` — BDOS_SET_DMA EQU 26 added; header Public list updated.
- `test/Makefile` — `fixtures/eof1a.txt` and `fixtures/big.bin` generation rules added; test target depends on $(FIXTURES); clean target removes them.
- `.gitignore` — `test/fixtures/eof1a.txt` added (big.bin matched by existing `*.bin`).
- `_bmad-output/implementation-artifacts/deferred-work.md` — partial-resolution notes added under the Story-2.1 deferrals (test-stub refactor → 12 consumers now; table well-formedness ASSERTs → 4 entries still hand-auditable, re-deferred); new Story-2.2 deferral section opened with the NFR9 size-budget observation, the deferred hardware UAT, the BDOS_CLOSE failure-context observation, and the test-stub refactor cross-reference.

### Change Log

| Date       | Change                                                                                                                                                                                                                                                                                                  |
|------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 2026-05-13 | Story 2.2 implementation: `:e filename` and `:e!` land the FCB-based BDOS file-load surface in new `src/fileio.asm`; `src/exline.asm` rewired to tokenise dispatch and route cmd_edit / cmd_edit_force; `src/statusln.asm` gained the bdos_error_pre_msg override + inline ex-line cleanup in the funnel; `src/gapbuf.asm`'s 1.7-era stub retired. 8 new headless tests; build SHA `30311cba…7bd79`; code size 3106 B (~101% of NFR9, +863 B vs 2.1's 2243 B). Status → review. Hardware UAT (AC14) deferred to user. |
