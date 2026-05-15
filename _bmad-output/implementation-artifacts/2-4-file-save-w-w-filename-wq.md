# Story 2.4: File save (:w, :w filename, :wq)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `:w` (save to the current filename), `:w filename` (save-as, which becomes the new current filename), and `:wq` (save-and-quit, with quit gated on save success), with every CP/M write error surfaced in the status line and `buffer_dirty` staying nonzero on failure,
So that Journey 1a's save half closes (FR4 / FR5 / FR7), the journey-1a flow `vibe newgame.fs` → type content → `:w` works against Story 2.3's preserved filename_buffer, and "no silent data loss" (NFR6 / FR52) holds across write-protect, disk-full, and partial-write failures.

## Acceptance Criteria

**AC1 — `cmd_write` and `cmd_write_quit` land in `exline_command_table`.**

**Given** `src/exline.asm`'s `exline_command_table` post-Story 2.3 (4 entries: `e`, `e!`, `q`, `q!`)
**When** I inspect the table post-Story 2.4
**Then** the table has 6 entries plus the terminator, in this order:
  - `e\0`   → `cmd_edit`        (Story 2.2, unchanged)
  - `e!\0`  → `cmd_edit_force`  (Story 2.2, unchanged)
  - `w\0`   → `cmd_write`       (NEW)
  - `wq\0`  → `cmd_write_quit`  (NEW)
  - `q\0`   → `cmd_quit`        (Story 2.1, unchanged)
  - `q!\0`  → `cmd_quit_force`  (Story 2.1, unchanged)
  - `\0`    (terminator)

**Order rationale.** Story 2.2's AC1 set the convention "file-IO commands first; quit commands last; future inserts before the terminator". Story 2.4 inserts `w` / `wq` between `e!` and `q` so the file-IO cluster stays contiguous (matches the cluster in fileio.asm). Story 3.1's `/`-search entry, when it arrives, will insert before `q` too — by then the table will have 7+ entries and is the natural point to land the deferred structural-ASSERT (deferred-work.md line 105) and the deferred init_teardown stub refactor (deferred-work.md line 118 — Story 2.4 is the natural moment per the existing deferral; this story formally promotes the cleanup, see AC15).

**No new exline_dispatch logic.** Story 2.2's tokenisation (split on first space; cmd_len from `exline_cmd_len`; arg-region ptr in HL, length in A) handles `:w` (cmd_len = 1, A = 0), `:w foo.fs` (cmd_len = 1, A = 7), and `:wq` (cmd_len = 2, A = 0) uniformly. No code change to `exline_dispatch`, `exline_compose_status`, `exline_append_literal`, `exline_backspace`, `exline_begin`, `exline_cancel`, or `exline_cancel_core` is required.

**AC2 — `cmd_write` handler refuses on missing filename, otherwise calls `fileio_save`.**

**Given** `cmd_write` is reached via `exline_dispatch`'s match on the `w` entry, with HL = pointer to arg region (just past the command token), A = arg-region length (0..63)
**When** the handler runs
**Then**:
  - **Arg region present (after leading-space strip A > 0):** parse the arg into `fcb_scratch` + `filename_buffer` via Story 2.2's `fileio_parse_filename` (this UPDATES filename_buffer per FR5 — subsequent bare `:w` saves to the new name); CALL `fileio_save`; JP `exline_cancel_core`.
  - **Arg region empty (after strip A == 0) AND `filename_buffer[0] == 0`:** `status_set_message msg_missing_filename` → JP `exline_cancel_core`. No save attempted; buffer unchanged; mode returns to NORMAL.
  - **Arg region empty AND `filename_buffer[0] != 0`:** re-parse the canonical `filename_buffer` text into `fcb_scratch` (via `fileio_parse_filename` with HL = `filename_buffer`, A = filename_buffer string length); CALL `fileio_save`; JP `exline_cancel_core`. The re-parse rebuilds `fcb_scratch` from the canonical display form so the save path does not depend on whatever `fcb_scratch` state survives from the last `:e` or launch.

**Note on filename_buffer string length.** `filename_buffer` is NUL-terminated (Story 2.2 / 2.3 invariant; max content 15 bytes). The handler walks bytes to find the NUL to derive the length; max length is 15 so `LD B, 16` + DJNZ scan is enough. Alternatively a known-bounded scan loop returning A.

**Why re-parse from filename_buffer rather than reuse the existing `fcb_scratch`?** Two reasons:
  1. **State decoupling.** The bare `:w` after a sequence like (load A: file → `:e B: file` → undo → `:w`) shouldn't depend on `fcb_scratch`'s history. Re-parsing from the canonical filename string in `filename_buffer` makes `:w`'s FCB state self-contained.
  2. **Round-trip correctness.** `filename_buffer` always holds the canonical display form (e.g., `"B:HELLO.TXT\0"`); re-parsing that string through `fileio_parse_filename` regenerates the identical `fcb_scratch` shape (drive 2 / basename `"HELLO   "` / ext `"TXT"`) regardless of how `fcb_scratch` was last populated.

**fileio_save banner preserves through cancel_core.** Same pattern as Story 2.2's `cmd_edit`: `fileio_save` sets its own status banner (success: `"FILENAME N bytes written"`; failure: surfaced via `bdos_error_pre_msg` through the funnel which terminally JPs to `input_loop`). On success the RET unwinds back to `cmd_write`, which JPs to `exline_cancel_core` — that path clears `ex_buffer` + mode but does NOT touch `status_buffer`, so the banner survives.

**AC3 — `cmd_write_quit` handler runs save first; quits only on save success.**

**Given** `cmd_write_quit` is reached via `exline_dispatch`'s match on the `wq` entry, with HL = arg region ptr, A = arg-region length (0..62 — `wq` is 2 bytes)
**When** the handler runs
**Then**:
  - The save half follows the same logic as `cmd_write` (AC2): handle missing filename → refuse; otherwise re-parse filename_buffer (or arg, if provided) → fcb_scratch; CALL `fileio_save`.
  - **On save success** (fileio_save returns normally with `buffer_dirty = 0` and the banner set): JP `init_teardown` (NOT `exline_cancel_core`). The warm-boot to CCP follows the Story 2.1 `cmd_quit_force` pattern.
  - **On save failure** (fileio_save's BDOS error funnel JPs terminally to `input_loop`, with the funnel's inline ex-line cleanup setting mode = NORMAL + ex_buffer length = 0): the `JP init_teardown` line in `cmd_write_quit` is BYPASSED — `buffer_dirty` stays nonzero (FR52), the error banner stays visible, the user is back at NORMAL mode in the editor.
  - **Missing-filename refusal**: emit `msg_missing_filename`; JP `exline_cancel_core`. The quit is NOT attempted (per Story 2.1's BH5 spirit — `cmd_quit` refuses on dirty buffer; analogously `cmd_write_quit` refuses to proceed if save couldn't even start).

**No `:wq filename` variant in MVP scope.** Spec choice: `:wq filename` is uncommon in real vi (most users type `:w filename` then `:q`), and the operator+motion design pressure (Stories 2.5..2.13) is the higher priority. **However**, the implementation MUST accept the arg-region (since `exline_dispatch` always passes HL + A) — the spec just doesn't require `:wq` to behave differently when an arg is present. Decision: `:wq foo.fs` runs the same save flow as `:w foo.fs` (filename_buffer updated per FR5) then warm-boots. Net effect: `:wq foo.fs` IS supported because the underlying primitives compose. No new code path is required.

**AC4 — `fileio_save` orchestrates the file-write flow.**

**Given** `cmd_write` / `cmd_write_quit` calls `fileio_save` with `fcb_scratch` populated (drive byte + 8-char basename + 3-char ext at offsets 0..11; bytes 12..35 zero) and `filename_buffer` populated (NUL-terminated canonical display form)
**When** `fileio_save` runs
**Then** it performs the following numbered sequence:

  1. **Pre-stage the "can't write FILENAME" banner** for the BDOS error funnel. Compose into `fileio_status_scratch` via a new helper `fileio_compose_cant_write` (AC9) that mirrors `fileio_compose_cant_open`'s shape but with prefix `"can't write "` (12 chars). Set `bdos_error_pre_msg = fileio_status_scratch`.
  2. **BDOS_DELETE** the FCB (AR15 SAVE CARVE-OUT — see AC5). Inline (NOT macro) because a clean save path expects DELETE to return 0xFF when no prior file exists, and the macro's `JP M` would falsely surface "can't write" on what is the NORMAL first-save case. The return code A is IGNORED (0 = file existed and was deleted; 0xFF = no file matched, also fine).
  3. **BDOS_MAKE** the FCB via `BDOS_CALL BDOS_MAKE` (function 22). The macro routing applies: on 0xFF (directory full / disk read-only / can't create), the funnel surfaces the pre-staged `"can't write FILENAME"` banner and JPs terminally to `input_loop`. `fileio_save` never returns on this path; `buffer_dirty` stays nonzero (FR52); funnel's inline cleanup sets mode = NORMAL + ex_buffer length = 0.
  4. **Defensive DMA set** via `BDOS_CALL BDOS_SET_DMA` with DE = `DEFAULT_DMA` (0x0080). The DMA may have been shifted by a prior operation; the save loop re-sets to the canonical default. Same defensive pattern as Story 2.2's `fileio_load_after_open` Step 6.
  5. **Compute total payload length.** `bytes_to_write = (gap_start - GAP_BUFFER_BASE) + (GAP_BUFFER_BASE + GAP_BUFFER_MAX - gap_end)` — sum of the before-gap and after-gap halves. Cache in a module-local 16-bit cell `fileio_write_count` (NEW; see AC10).
  6. **Walk gap buffer in two halves filling DMA, write each sector.** The walk visits the before-gap half first (logical offsets `[0, cursor_offset)`, physically `[GAP_BUFFER_BASE, gap_start)`), then the after-gap half (logical offsets `[cursor_offset, total)`, physically `[gap_end, GAP_BUFFER_BASE + GAP_BUFFER_MAX)`). The DMA buffer at `DEFAULT_DMA` (128 bytes) is filled byte-by-byte (or LDIR-fragment-by-fragment) from these two regions; when the DMA is full, `BDOS_CALL BDOS_WRITE_SEQ` writes one sector; the DMA is then re-used for the next sector. Implementation owns the boundary mechanics (see AC7 for the exact spec).
  7. **Emit final sector with `0x1A` EOF marker + space pad.** If the final DMA fill ends before the 128-byte boundary, append `0x1A` at the next byte, then pad the remainder of the 128-byte DMA with `0x20` (space) bytes. Issue one final `BDOS_CALL BDOS_WRITE_SEQ` to write the padded final sector.
     - **Special case: total payload is exactly a multiple of 128.** The story spec (epics line 1002) says "append `0x1A` + space-pad to next 128-byte boundary". Two reasonable interpretations: (a) write the final sector containing only `0x1A` + 127 spaces (i.e., always emit one trailing sector with EOF marker), or (b) skip the trailing sector when payload is sector-aligned. **Decision: always emit the EOF sector** — matches vi's reliability convention and the Story 2.2 read loop's 0x1A-scan logic (which stops at 0x1A wherever it lives in any sector, so the trailing sector won't corrupt a re-read). Empty-buffer save (0 bytes payload) thus writes a single sector containing `0x1A` + 127 spaces.
  8. **BDOS_CLOSE** via `BDOS_CALL BDOS_CLOSE`. The macro routing applies: on 0xFF, the funnel surfaces `"can't write FILENAME"` (the pre-staged banner is still set — `fileio_save` does not clear it across the WRITE_SEQ / CLOSE sequence). Same FR52 path as Step 3.
  9. **Clear the pre-staged banner pointer.** `LD HL, 0 ; LD (bdos_error_pre_msg), HL`. CRITICAL: this MUST run only AFTER all BDOS calls succeed — otherwise a stale "can't write FILENAME" pointer survives across an unrelated future BDOS error. (Same hygiene as Story 2.2's `fileio_load` Step 5.)
  10. **Set post-save state.** `XOR A ; LD (buffer_dirty), A`. cursor_offset is unchanged (the save did not move the cursor; the walk was read-only against the gap-buffer regions). gap_start / gap_end / filename_buffer are unchanged.
  11. **Compose + emit success banner.** Call a new helper `fileio_compose_written_status` (AC10) that builds `"<FILENAME> <N> bytes written"` into `fileio_status_scratch`. Hand to `status_set_message`. RET.

**AC5 — AR15 SAVE CARVE-OUT: inline BDOS_DELETE bypasses the funnel.**

**Given** Story 2.2's `BDOS_CALL` macro routes sign-bit (0xFF) BDOS returns through `bdos_error_funnel`, which surfaces a banner and terminally `JP input_loop`s
**When** `fileio_save` calls BDOS_DELETE as Step 2 of the save flow (AC4)
**Then** the call MUST be INLINED (not via the macro) because **0xFF (file-not-matched) is the NORMAL case** for a first save of a new file — routing through the funnel would surface "can't write FILENAME" on every first save and corrupt the journey-1a flow (`vibe newgame.fs` → type content → `:w` → would falsely refuse).

**Inline sequence:**
```asm
    ;; AR15 SAVE CARVE-OUT: inline BDOS_DELETE.
    ;; bdos_error_funnel would falsely surface "can't write
    ;; FILENAME" on the 0xFF return that simply means
    ;; "no prior file to delete" — the NORMAL first-save case.
    ;; A's return code is ignored: 0..3 = file existed and was
    ;; deleted, 0xFF = no matching file. Either result lets MAKE
    ;; proceed; pathological sign-bit failures from DELETE on
    ;; CP/M 2.2 are not documented (BIOS-disk-error class), and
    ;; MAKE will surface them on the next step if they exist.
    LD      C, BDOS_DELETE
    LD      DE, fcb_scratch
    CALL    BDOS_ENTRY              ; AR15 save carve-out
    ;; A discarded; fall through to MAKE.
```

**Documenting the carve-out.** Update `src/fileio.asm`'s module-header AR23 block "Architectural enforcement here" sub-bullet for AR15 to enumerate TWO carve-outs:
  1. Launch carve-out (Story 2.3): `fileio_load_initial`'s BDOS_OPEN, inlined so the funnel does not bypass `init_cold_start`'s Stages 6/7.
  2. **Save carve-out (Story 2.4)**: `fileio_save`'s BDOS_DELETE, inlined so the funnel does not surface a spurious "can't write" on the NORMAL "file did not exist" return.

Document the save carve-out's rationale in prose mirroring Story 2.3's launch carve-out wording (parallel structure for readability). The MAKE / SET_DMA / WRITE_SEQ / CLOSE calls in the save flow continue to use the BDOS_CALL macro — only the DELETE is carved out.

**AR15 enforcement greps need updating** (AC13): the `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/fileio.asm` invocation will newly match TWO sites: the Story-2.3 launch carve-out plus the Story-2.4 save carve-out. Annotate the new match with an inline `; AR15 save carve-out` comment (parallel to Story 2.3's `; AR15 launch carve-out` annotation). The grep sweep tolerates the annotated matches.

**AC6 — BDOS write-flow error semantics (FR51 / FR52 / NFR6).**

**Given** the save flow's interaction with the BDOS_CALL macro funnel
**When** any non-DELETE BDOS call returns a sign-bit error
**Then**:
  - **BDOS_MAKE returns 0xFF** (directory full, read-only disk, drive offline, write-protect): funnel surfaces "can't write FILENAME" (pre-staged), JPs to input_loop. `buffer_dirty` is unchanged (still nonzero per the dirty-pre-save state). The on-disk state is: no new file created (MAKE failed atomically — CP/M 2.2 BDOS_MAKE either creates the directory entry or leaves the directory untouched). **No partial file on disk.**
  - **BDOS_WRITE_SEQ returns A >= 1** (disk full mid-write, extent exhausted, write-protect surfaces mid-sequence, etc.): for sign-bit returns the macro funnels to "can't write FILENAME"; for A = 1..127 (the CP/M-documented "write error" codes from WRITE_SEQ) bit 7 is clear and the macro's JP M does NOT fire. The save loop MUST inspect A after each WRITE_SEQ and abort on A != 0 by routing to a shared abort body (see below).
  - **BDOS_CLOSE returns 0xFF** (rare; corrupted FCB or BIOS disk error post-write): funnel surfaces "can't write FILENAME". Partial file may exist on disk — directory entry may or may not be flushed depending on which BDOS internal step failed. **Documented limitation per PRD line 553** ("Direct unsafe write — no temp file, no rename dance. A crashed write may leave a half-written file.")
  - **Post-error state in every case**: `buffer_dirty` stays nonzero (no `LD (buffer_dirty), A` runs on error paths); pre-staged banner surfaced; mode = NORMAL (funnel's inline ex-line cleanup); ex_buffer cleared; user back at the editor with a clean error message — never crashed (NFR5).

**Shared abort path for WRITE_SEQ A != 0 (non-sign-bit error).** Define an internal `fileio_save_abort_write` label: re-stage `bdos_error_pre_msg = fileio_status_scratch` (defensive — the pointer should still be set from Step 1, but the abort is paranoid), then JP `bdos_error_funnel` directly. The funnel surfaces the pre-staged banner + runs the inline ex-line cleanup + JPs to input_loop. **The error funnel JP is the abort surface** — there's no need to invent a new "write_seq_error" message; "can't write FILENAME" covers the full set of write-side failures consistently.

  - Alternatively: open the question of whether disk-full deserves its own banner (`msg_disk_full`?). **Decision: NO** — "can't write FILENAME" is consistent with AR16 (lowercase, <30 chars, no period) and the PRD's status-message conventions don't enumerate disk-full as a distinct surface (PRD line 1015 lists "I/O errors: `can't write <filename>`, `can't open <filename>`" — single banner for the I/O-error class). Disk-full users will infer from "can't write" + the failed `:w` that disk space is the issue.

**AC7 — Gap-buffer walk: DMA fill mechanics across the gap.**

**Given** the gap buffer's two halves: `[GAP_BUFFER_BASE, gap_start)` (logical offsets `[0, cursor_offset)`) and `[gap_end, GAP_BUFFER_BASE + GAP_BUFFER_MAX)` (logical offsets `[cursor_offset, total)`)
**When** `fileio_save`'s walk phase (AC4 Step 6) fills the 128-byte DMA buffer at `DEFAULT_DMA` and issues `BDOS_WRITE_SEQ` per sector
**Then** the algorithm is:

```
;; Pseudocode — actual asm pinned in AC11 spec.
walk_state:
    src       = GAP_BUFFER_BASE        ; current source ptr (starts at first half)
    src_remain = gap_start - GAP_BUFFER_BASE   ; bytes left in current half
    half      = 0                      ; 0 = before-gap, 1 = after-gap, 2 = done
    dma_ptr   = DEFAULT_DMA            ; current dest within the 128-byte DMA
    dma_remain = 128                   ; bytes left in current DMA sector

main_loop:
    if src_remain == 0:
        if half == 0:
            src = gap_end
            src_remain = (GAP_BUFFER_BASE + GAP_BUFFER_MAX) - gap_end
            half = 1
            if src_remain == 0: goto eof_pad        ; gap occupies whole buffer
        else if half == 1:
            half = 2
            goto eof_pad

    chunk = min(src_remain, dma_remain)
    LDIR chunk bytes from src to dma_ptr
    src += chunk; src_remain -= chunk
    dma_ptr += chunk; dma_remain -= chunk

    if dma_remain == 0:
        BDOS_CALL BDOS_WRITE_SEQ        ; macro — funnel routing applies
        OR A; JR NZ, write_seq_abort    ; A != 0 -> abort (covers A = 1..127)
        dma_ptr = DEFAULT_DMA
        dma_remain = 128

    goto main_loop

eof_pad:
    LD (dma_ptr), 0x1A
    INC dma_ptr; DEC dma_remain
    ;; If dma_remain became 0 because we filled exactly to boundary,
    ;; the loop ABOVE would have written; the 0x1A goes into a fresh
    ;; sector. Otherwise dma_remain >= 1 here.
    while dma_remain > 0:
        LD (dma_ptr), 0x20              ; space pad
        INC dma_ptr; DEC dma_remain
    BDOS_CALL BDOS_WRITE_SEQ            ; final sector
    OR A; JR NZ, write_seq_abort
```

**Implementation note — the LDIR chunk.** Each iteration's `LDIR chunk bytes` is a literal `LD BC, chunk ; LDIR`. `chunk = min(src_remain, dma_remain)` is bounded by `min(src_remain, 128)`. The smaller-of-two computation is a 16-bit unsigned `SBC HL, DE`-based compare; the dev owns the exact register flow.

**Special-case rationale.** The boundary case where `dma_remain == 0` immediately before the EOF-pad has the trailing `0x1A` + spaces written as a fresh full sector. This matches the "always emit EOF sector" decision in AC4 Step 7. The empty-buffer case (src_remain = 0 on both halves at entry) skips the main loop entirely and goes straight to `eof_pad` with `dma_remain = 128` — producing one sector of `0x1A` + 127 spaces.

**AC8 — `:w filename` updates filename_buffer per FR5.**

**Given** `:w foo.fs` with prior `filename_buffer = "B:HELLO.TXT\0"`
**When** `cmd_write` parses the arg via `fileio_parse_filename`
**Then** `filename_buffer` is UPDATED to `"B:FOO.FS\0"` (the canonical display form of the new name; FR9 default-drive applies; FR10 explicit drive prefix accepted), AND a subsequent bare `:w` saves to `B:FOO.FS` (not `B:HELLO.TXT`).

**No "save-as preserves original" mode.** Real vi's `:w foo` saves a copy to `foo` but the editor's "current file" stays as the prior name. Vibe's spec (FR5 + epic AC) explicitly chooses the OTHER convention: `:w foo` changes the current file. The chosen convention matches the journey-1a workflow ("the user wanted to save the new name; that IS their working filename now") and saves the equates-and-machinery cost of tracking two filenames. **Document the divergence from real vi** in `cmd_write`'s AR23 contract block.

**AC9 — `fileio_compose_cant_write` composes the pre-staged failure banner.**

**Given** the funnel-routing on BDOS_MAKE / BDOS_WRITE_SEQ-sign-bit / BDOS_CLOSE failure needs a context-rich message
**When** `fileio_save` Step 1 pre-stages the banner
**Then** a new internal helper `fileio_compose_cant_write` builds `"can't write <FILENAME>\0"` in `fileio_status_scratch`. Contract:

```
fileio_compose_cant_write
  In:      (none — reads fileio_msg_cant_write_prefix + filename_buffer)
  Out:     fileio_status_scratch contains the composed banner.
           HL = fileio_status_scratch (ready to load into bdos_error_pre_msg).
  Trashes: A, BC, DE, HL, F.
```

**Implementation pattern.** Identical structure to Story 2.2's `fileio_compose_cant_open` (lines 894-914 in src/fileio.asm) — copy a NUL-terminated prefix DEFB into `fileio_status_scratch`, then copy the NUL-terminated `filename_buffer` after it, copying through the NUL terminator so the final banner is itself NUL-terminated. The prefix is a new DEFB `fileio_msg_cant_write_prefix: DEFB "can't write ", 0` (12 chars + NUL; AR16-compliant).

**Capacity check.** Max composed length = `len("can't write ") + len(filename_buffer) = 12 + 15 = 27` bytes; plus NUL terminator = 28 bytes. Well within `fileio_status_scratch`'s 48-byte allocation; the existing `ASSERT $ - fileio_status_scratch >= 48` tripwire continues to cover this new path.

**Placement.** Add `fileio_compose_cant_write` immediately after `fileio_compose_cant_open` in the module's internal-helper block. Add `fileio_msg_cant_write_prefix` immediately after `fileio_msg_cant_open_prefix` in the module-local data block.

**AC10 — `fileio_compose_written_status` composes the success banner.**

**Given** the save flow's Step 11 needs a "FILENAME N bytes written" status banner
**When** `fileio_save` composes the success status
**Then** a new internal helper `fileio_compose_written_status` builds the banner. Contract:

```
fileio_compose_written_status
  In:      BC = byte count (the value from fileio_write_count).
  Out:     fileio_status_scratch contains "<FILENAME> <N> bytes written\0".
           HL = fileio_status_scratch (ready for status_set_message).
  Trashes: A, BC, DE, HL, F.
```

**Implementation pattern.** Near-identical to Story 2.2's `fileio_compose_loaded_status` (lines 929-960 in src/fileio.asm). Three options for sharing:

  1. **Duplicate.** Copy the body wholesale and change only the trailing suffix DEFB (` " bytes\0"` → `" bytes written\0"`). ~30 B added.
  2. **Parameterise via DE.** Pass the suffix-DEFB pointer in DE; `fileio_compose_loaded_status` becomes a thin wrapper that loads its old `.suffix` into DE and tail-JPs into the shared body. ~10 B saved over option 1.
  3. **Share via a `fileio_compose_loaded_status_with_suffix` body** taking suffix-ptr in DE; both old and new callers funnel through it.

**Decision: option 2.** Smaller and avoids a new public-ish surface. Refactor `fileio_compose_loaded_status` to load its private suffix into DE and JP into a new shared label `fileio_compose_filename_count_suffix` (or similar — name owned by the dev). The new `fileio_compose_written_status` loads `.written_suffix` into DE then JPs in. Use a single suffix DEFB pair: `.bytes_suffix: DEFB " bytes", 0` (existing) + new `.written_suffix: DEFB " bytes written", 0`.

**fileio_write_count cell.** New module-local 16-bit cell `fileio_write_count` (DEFW 0) stores the total payload byte count computed at AC4 Step 5; consumed by Step 11. Placement: in the module-local data block alongside `fileio_dec_dest`. No state.inc change — this is internal save scratch.

**Capacity check.** Max composed length = `15 (filename) + 1 (' ') + 5 (decimal digits, max 32768) + 14 (" bytes written") + 1 (NUL) = 36` bytes; within `fileio_status_scratch`'s 48-byte allocation. The existing `ASSERT $ - fileio_status_scratch >= 48` continues to cover this; **bump the comment in fileio.asm noting the now-largest banner** so a future grower sees the updated max-content arithmetic (28 → 36 bytes).

**AC11 — `fileio_save` public entry contract.**

**Given** the save orchestration described in AC4
**When** I inspect `src/fileio.asm` post-Story-2.4
**Then** a new public entry `fileio_save` exists with the AR23 four-line contract:

```
fileio_save
  In:      fcb_scratch populated (drive byte at +0; 8-char space-padded
           uppercase basename at +1..+8; 3-char space-padded uppercase
           extension at +9..+11; zeros at +12..+35).
           filename_buffer populated (NUL-terminated canonical display
           form; first byte != 0).
           gap_start / gap_end / GAP_BUFFER_BASE / GAP_BUFFER_MAX
           defining the two-halves payload to serialise.
  Out:     Success: file written to disk; buffer_dirty = 0;
           filename_buffer + gap state unchanged; status row =
           "<FILENAME> N bytes written". RET.
           Failure (BDOS_MAKE / WRITE_SEQ / CLOSE error): no return;
           bdos_error_funnel surfaces "can't write FILENAME" then
           JPs to input_loop. buffer_dirty stays nonzero; ex_buffer
           cleared + mode = NORMAL by the funnel's inline cleanup.
  Trashes: A, BC, DE, HL, F.
  Calls:   fileio_compose_cant_write (pre-stage banner),
           BDOS_ENTRY (inline AR15 save carve-out for DELETE),
           BDOS_CALL (BDOS_MAKE / BDOS_SET_DMA / BDOS_WRITE_SEQ /
           BDOS_CLOSE), fileio_compose_written_status,
           status_set_message.
```

**Module-header `Public:` list grows by one entry** (`fileio_save`); update the AR23 block accordingly. Add a one-line summary mirroring the existing entries' style. Update the module's `State owned (read/write)` block:
  - `bdos_error_pre_msg` (already documented) now has a SECOND writer site (the save's Step 1 pre-stage) — update the comment.
  - `fileio_write_count` (new) — DEFW 0 in the data block; written at AC4 Step 5, read at AC4 Step 11.

**AC12 — Headless tests cover the save flow.**

**Given** four new headless tests under `test/cases/fileio_save-*.asm` (per the epic spec's enumeration)
**When** `make test` runs
**Then** the following pass:

  - **`fileio_save-roundtrip.asm`** — pre-populate `filename_buffer = "B:OUT.TXT\0"`; pre-populate `fcb_scratch` (drive 2, basename `"OUT     "`, ext `"TXT"`, bytes 12..35 zero); pre-populate the gap buffer via `gapbuf_init` + a sequence of `gapbuf_insert` calls (or by directly writing into the before-gap region — tests are AR-exempt) with the bytes `"hello world\r\n"` (13 bytes); CALL `fileio_save`. Assert:
    - Status_buffer prefix matches `"B:OUT.TXT 13 bytes written"`.
    - `buffer_dirty == 0`.
    - `bdos_error_pre_msg == 0` (cleared post-save).
    - `gap_start / gap_end / cursor_offset` unchanged (the save did not mutate the gap).
    - **Roundtrip check.** Immediately after the save, call `fileio_load` with HL = `filename_buffer + 0`, A = 9 (`"B:OUT.TXT"` is 9 chars). Assert post-load: `gap_end - GAP_BUFFER_BASE == GAP_BUFFER_MAX - 13` (loaded 13 bytes); after-gap content matches `"hello world\r\n"` byte-for-byte.
    - The fixture filesystem permits writes — `test/Makefile` mounts `fixtures/` as A: AND B:; both are RW under iz-cpm's mount semantics. Test cleanup: the dev needs to add an explicit `rm -f fixtures/OUT.TXT` to `test/Makefile`'s `clean` target so a stale post-test file doesn't leak across runs. **Spec the Makefile change**: extend the `clean:` recipe with `rm -f fixtures/OUT.TXT fixtures/PAD100.TXT fixtures/EMPTY.TXT` (the three save-test output files; see the other test specs).

  - **`fileio_save-empty-buffer.asm`** — pre-populate `filename_buffer = "B:EMPTY.TXT\0"`; pre-populate `fcb_scratch` accordingly; CALL `gapbuf_init` (gap empty, gap_start = BASE, gap_end = BASE + MAX, cursor = 0); CALL `fileio_save`. Assert:
    - Status_buffer prefix matches `"B:EMPTY.TXT 0 bytes written"`.
    - `buffer_dirty == 0`.
    - Single-sector file on disk: 128 bytes total — first byte `0x1A`, bytes 1..127 all `0x20`. **Verify via BDOS_OPEN + BDOS_READ_SEQ in-test**: open `B:EMPTY.TXT`, set DMA to a local 128-byte scratch buffer, read one sector, assert `BDOS_READ_SEQ` returned A = 0, assert `[scratch + 0] = 0x1A`, assert `[scratch + 1 .. scratch + 127]` are all `0x20`. A second `BDOS_READ_SEQ` returns A = 1 (clean EOF — file is exactly one sector long).
    - **NOTE on AR15 in tests:** test code is AR-exempt (see test_epilogue.inc lines 24-37). The in-test BDOS calls for roundtrip verification can use raw `LD C, fn ; CALL 0x0005` if desired, OR can route through the production `BDOS_CALL` macro (which the test includes via `src/fileio.asm` → `inc/bdos.inc`). The macro's funnel would JP to `input_loop` on failure, so tests using the macro need a local `input_loop:` stub that sets a sentinel (parallel to the Story-2.2 `fileio_load-not-found.asm` pattern via `test/inc/test_input_loop_stub.inc`).

  - **`fileio_save-1A-padding.asm`** — pre-populate `filename_buffer = "B:PAD100.TXT\0"` (wait: filename_buffer is 16 bytes max; "B:PAD100.TXT" is 12 chars + NUL = 13 — fits); pre-populate `fcb_scratch`; pre-populate the gap buffer with EXACTLY 100 bytes of `'A'` content (so the file ends mid-sector at offset 100 out of 128); CALL `fileio_save`. Assert:
    - Status_buffer prefix matches `"B:PAD100.TXT 100 bytes written"`.
    - Single-sector file on disk: 128 bytes total — bytes 0..99 are `'A'` (0x41), byte 100 is `0x1A`, bytes 101..127 are `0x20`. Verify via BDOS_OPEN + BDOS_READ_SEQ + byte-by-byte assert.
    - **Why this is the most important test:** the 0x1A-then-pad logic is the algorithm's correctness hinge — get the boundary wrong and either the file has trailing garbage or the read loop in Story 2.2 can't find the EOF marker.

  - **`fileio_save-write-protect.asm`** — pre-populate `filename_buffer = "B:RO.TXT\0"`; pre-populate `fcb_scratch`. Then pre-stage a directory entry on the iz-cpm B: drive with the file's R/O bit set:
    - **Mechanism A (preferred — filesystem-level):** the test Makefile pre-creates `fixtures/RO.TXT` with content "x" and `chmod 0444` it; iz-cpm's CP/M-emulation surfaces the host R/O bit as the BDOS R/O attribute. A BDOS_DELETE on a R/O file returns 0xFF (silently swallowed by the AR15 save carve-out — fine); a BDOS_MAKE attempt then either succeeds (replacing the directory entry, defeating the R/O) or fails (preserving R/O). **Reality check needed during dev**: confirm iz-cpm's behaviour against a CP/M 2.2 reference. If iz-cpm doesn't surface the R/O bit cleanly, fall back to Mechanism B.
    - **Mechanism B (fallback — FCB-level):** set FCB byte +9 (ext char 0) high bit before calling `fileio_save`. CP/M 2.2 BDOS_MAKE inspects this as the R/O attribute; the call should return 0xFF. The test then needs to clear the high bit before any verify step that opens the file.
    - **Mechanism C (deferred):** if neither A nor B works headlessly, defer the test to hardware UAT per the AC14 pattern. Document the deferral in `deferred-work.md` under Story 2.4.
    - Assert: `bdos_error_pre_msg` was cleared by the funnel (post-funnel-emit); `status_buffer` content matches `"can't write B:RO.TXT"`; `buffer_dirty` UNCHANGED (still whatever the pre-test value was — 1 in this test to verify FR52). **CRITICAL post-funnel sentinel**: the funnel terminally JPs to `input_loop` — the test needs a local `input_loop:` stub that sets a sentinel proving the funnel was entered. Same pattern as Story 2.2's `fileio_load-not-found.asm` (via `test/inc/test_input_loop_stub.inc`).

  - **Sentinel codes for the four save tests** (0xF0..0xFB range, separate from Stories 2.2 / 2.3's 0xE0..0xEF):
    - 0xF0 — primary post-call state mismatch
    - 0xF1 — status_buffer prefix mismatch
    - 0xF2 — buffer_dirty mismatch (B = expected vs actual)
    - 0xF3 — on-disk content mismatch (B = byte offset of first mismatch)
    - 0xF4 — gap_start / gap_end mismatch (the roundtrip after-state)
    - 0xF5 — bdos_error_pre_msg non-zero post-save (hygiene check)
    - 0xF6 — funnel_entered sentinel TOGGLED (for write-protect test: should be set; for others: should be UNSET)
    - 0xF7 — BDOS_READ_SEQ rc unexpected during in-test verification
    - Reserve 0xF8..0xFB for dev-discretion fail surfaces.

  - **Each test follows the Story-2.2/2.3 INCLUDE pattern**:
    1. Pre-ORG production EQU INCLUDEs (`equates.inc`, `bios.inc`, `bdos.inc`, `modes.inc`, `vt52.inc`).
    2. `test_prologue.inc` (ORG 0x0100, sentinel pre-zero).
    3. Test body (pre-zero state, populate fcb_scratch + filename_buffer + gap, CALL `fileio_save`, assert post-state, optionally CALL `fileio_load` to roundtrip-verify, assert).
    4. `test_epilogue.inc` (test_pass / test_fail labels).
    5. Production INCLUDEs in AR25 order: `statusln.asm`, `gapbuf.asm`, `render.asm`, `dispatch.asm`, `parser.asm`, `exline.asm`, `fileio.asm`.
    6. For tests that route through the BDOS_CALL macro and expect the funnel: `test/inc/test_input_loop_stub.inc` (the sentinel-setting stub from Story 2.2).
    7. Local `init_teardown:` stub if any code path tail-JPs there (the save tests probably don't reach it, but the macro's funnel cleanup writes mode = NORMAL etc. — confirm the dependency chain).
    8. `state.inc` LAST (positional anchor).

**Live baseline becomes at least 45 pass / 1 fail** (41 post-2.3 + 4 new + the deliberate `harness_fail`).

**AC13 — Build invariants and AR enforcement.**

**Given** Story 2.4's source changes
**When** `make clean && make` runs twice consecutively
**Then**:
  - Both runs succeed (NFR14 sjasmplus 1.23.0 pinned).
  - The two resulting `vibe.com` files are byte-identical (NFR18 reproducibility). Capture both SHA-256 values in Debug Log References.
  - `make sizes` reports the new code-section size. Capture verbatim. Expected growth: `fileio_save` body (~150-220 B including the gap-walk + DMA-fill + EOF-pad logic) + `fileio_compose_cant_write` (~30 B) + `fileio_compose_written_status` body (~20 B; via the parameterise-suffix refactor saving on its sibling) + `fileio_msg_cant_write_prefix` DEFB (~14 B) + `fileio_write_count` DEFW (2 B) + `cmd_write` + `cmd_write_quit` handlers (~50 B including the filename_buffer-strlen scan) + `exline_command_table` growth (~20 B for two new entries with NUL keys + DEFW handlers) + the refactor of `fileio_compose_loaded_status` (negligible net delta). **Expected delta: +280-360 B.** Post-2.3 baseline was 3235 B; expected post-2.4: **3515-3595 B / ~114-117% of the original NFR9 ceiling.** Still below the proposed 4096 B amended ceiling (deferred-work.md line 122).

**NFR9 amend follow-up unchanged.** Story 2.4 deepens the overshoot but does not yet cross the amended ceiling. The NFR9 amendment (deferred-work.md line 122) remains the load-bearing resolution — Stories 2.5+ will continue to grow code. **Action for the dev:** capture the new size verbatim. If footprint exceeds 4096 B (Ant's proposed amended ceiling), flag as a notable observation per Story 2.3's pattern; do NOT block the story on the original 3072 B ceiling.

**AR enforcement sweeps (grep against `src/`):**
  - `grep -nE 'BIOS_CONOUT' src/ | grep -v 'render.asm'` — comment matches only (AR13 unchanged).
  - `grep -nE 'gapbuf_(insert|delete|move_gap|load|init)' src/fileio.asm` — matches `gapbuf_init` (multiple sites from Story 2.2 / 2.3 — load, abort, load_initial step 3) and `gapbuf_move_gap` (single site in `fileio_load_after_open`). **NO new gap-mutation sites in `fileio_save`** — the save walk is READ-ONLY against the gap regions (LDIR from `[GAP_BUFFER_BASE, gap_start)` and `[gap_end, BASE + MAX)` is a read; the LDIR's destination is `DEFAULT_DMA`, not the gap). All AR14-compliant.
  - `grep -nE 'LD[ \t]+\(gap_start\)' src/fileio.asm` — TWO matches in `fileio_ingest_sector` (the Story-2.2 AR14 carve-out's linear-fill phase); both bear `; AR14 carve-out` annotations (unchanged from Story 2.2 / 2.3). **NO new write-to-gap_start sites in `fileio_save`.**
  - `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/fileio.asm` — **TWO matches**: the Story-2.3 launch carve-out (line ~465 in the current source) + the Story-2.4 save carve-out in `fileio_save` Step 2 (BDOS_DELETE). Both bear inline annotations (`; AR15 launch carve-out` / `; AR15 save carve-out`); the module's AR23 header now documents BOTH carve-outs (per AC5).
  - `grep -nE 'BDOS_CALL' src/fileio.asm` — multiple matches (BDOS_OPEN in fileio_load, BDOS_MAKE / BDOS_SET_DMA / BDOS_WRITE_SEQ / BDOS_CLOSE in fileio_save, plus the existing BDOS_SET_DMA / BDOS_READ_SEQ / BDOS_CLOSE in fileio_load_after_open + abort paths). All sign-bit-routing BDOS calls in the save flow continue to use the macro.
  - `grep -nE 'bdos_error_pre_msg' src/` — at least 4 matches (statusln.asm declaration + funnel body; fileio.asm pre-stage in fileio_load + post-OPEN clear; fileio.asm pre-stage in fileio_save + post-success clear). **Specifically check:** `fileio_save`'s pre-stage MUST be cleared on the success path (AC4 Step 9); the dev should verify the clear runs only after all BDOS calls succeed.
  - `grep -nE 'BDOS_DELETE|BDOS_MAKE|BDOS_WRITE_SEQ' src/` — matches only `src/fileio.asm` (in `fileio_save`). Confirms the new BDOS surface is correctly scoped.

**AC14 — Hardware UAT smokes `:w` / `:w filename` / `:wq` on real MicroBeast.**

**Given** UAT on hardware (Feersum MicroBeast)
**When** I:
  1. `make push` (SLIDE transfer) and from CCP type `vibe newgame.fs` — observe: editor launches; status row reads `B:NEWGAME.FS [new file]` (Story 2.3 carry-over); buffer empty; mode NORMAL.
  2. Press `:`, type `w`, Enter — observe: status reads `B:NEWGAME.FS 0 bytes written`; buffer_dirty cleared (visible only via subsequent `:q` behaving as clean-quit per step 3).
  3. Press `:`, type `q`, Enter — observe: clean quit to CCP (buffer was clean post-save).
  4. From CCP type `dir b:newgame.fs` — observe: the file exists on B:, 1 sector (128 bytes). **OPTIONAL** — confirms the on-disk artefact but UAT step 5 is the load-bearing roundtrip.
  5. From CCP type `vibe newgame.fs` — observe: status row now reads `B:NEWGAME.FS 0 bytes` (Story 2.3 load path; **note** — the change from `[new file]` to `0 bytes` is the visible confirmation that the previous step's `:w` created the file).
  6. **Insert-mode UAT is gated on Story 2.8** — the spec's epic-2.4 (epics line 1041-1044) notes the save-with-edits hardware UAT can't run until 2.8 lands. Step 6 here is therefore: in lieu of insert-mode editing, the dev can SKIP straight to the round-trip-verifies-empty-file path of step 5. Record the skip in Debug Log References per AC14's documented exception pattern (mirrors Story 2.3's huge-file AC14 step skip).
  7. Press `:`, type `q`, Enter — clean quit.
  8. From CCP type `vibe newgame.fs` then `:`, type `w other.fs`, Enter — observe: status reads `B:OTHER.FS 0 bytes written`; the filename_buffer per FR5 now points at `B:OTHER.FS`.
  9. Press `:`, type `w`, Enter — observe: status reads `B:OTHER.FS 0 bytes written` (saving to OTHER.FS, not back to NEWGAME.FS). Confirms FR5 the post-save-as filename_buffer update.
  10. Press `:`, type `wq`, Enter — observe: status briefly flashes `B:OTHER.FS 0 bytes written` then warm-boots to CCP. Confirms `:wq` save-then-quit composition.
  11. From CCP type `vibe newgame.fs` (the first file we created, still 0 bytes) → `:`, type `wq`, Enter — observe: same `:wq` behaviour but on the original file. Confirms the `:wq` path is filename-independent.
  12. **Write-protect smoke is OPTIONAL on hardware** — write-protect on the MicroBeast SD/CF card depends on whether the user can toggle a R/O bit at the card level. If the user has a R/O-flagged disk image, `:w` should surface `can't write B:WHATEVER.FS` and the buffer remain dirty. If no R/O mechanism is available, the headless test (AC12 `fileio_save-write-protect.asm`) is the only coverage for FR51 / FR52 in this story. Record the choice in Debug Log References.
  13. Sustained-typing regression (after Story 2.8 lands): with the buffer loaded, press `:` then Esc 30 times — observe no terminal corruption (Stories 1.12 / 2.1 / 2.2 / 2.3 regression net).

**Then** all observable steps behave as specified, no terminal corruption, no warm-boot from any non-`:wq` / non-`:q` step. The save flow's error funnel + AR15 save carve-out + filename_buffer update behave consistently with the spec.

**Note on `:wq` hardware UAT.** The `:wq` step warm-boots the editor — the dev needs to relaunch (`vibe newgame.fs`) between successive `:wq` UAT iterations. AC14 sequences the relaunches explicitly (step 11 relaunches the first file).

**Hardware UAT executed by user, per Stories 1.11 / 1.12 / 2.1 / 2.2 / 2.3 pattern.** The dev environment has no SLIDE / hardware connection; the user runs `make push` + steps through the UAT script after the headless gates are all green.

**AC15 — Test infrastructure cleanup: promote the duplicated `init_teardown` stub.**

**Given** the deferred-work entry at line 118 explicitly promotes the duplicated `init_teardown:` stub refactor to Story 2.4 ("Story 2.4's `:wq` tests will need the stub too, taking the count past 13 — the cleanup is mechanical")
**When** Story 2.4 lands its four new test cases
**Then** the dev promotes the refactor:
  - Create `test/inc/test_teardown_stub.inc` containing:
    ```asm
    ;; Standard headless-test init_teardown stub. Tests that exercise
    ;; ex-line command handlers (cmd_quit / cmd_write_quit / etc.) need
    ;; this label resolvable; the stub sets a sentinel for tests that
    ;; want to verify teardown was reached, and otherwise just RETs.
    init_teardown:
        LD      A, 1
        LD      (init_teardown_called), A
        RET
    init_teardown_called:
        DEFB    0
    ```
  - Replace the inline stub block in EVERY consumer test (the Story-2.1 set of 4, the Story-2.2 set of 8, the Story-2.3 set of 5, plus Story-2.4's new 4 — total ~21 sites) with `INCLUDE "../inc/test_teardown_stub.inc"`. **NOTE — the wq test is the natural verifier**: `fileio_save-roundtrip` or a new `cmd_wq-warm-boot-on-success.asm` test asserts that `init_teardown_called == 1` after a successful `:wq` (the stub catches the teardown JP without actually warm-booting).
  - Optional: add a 5th test `cmd_wq-failure-stays-dirty.asm` that drives `:wq` against a write-protect setup (mechanism A or B from AC12) and asserts `init_teardown_called == 0` (the funnel's input_loop JP bypassed the teardown).

**Scope discipline.** The stub refactor is mechanical but touches ~21 test files. The dev SHOULD do it (per the explicit deferral promotion); if the dev finds the scope too large for the story's session, the refactor can be split off as a separate cleanup commit ALONGSIDE Story 2.4 but committed separately. Either approach is acceptable; the deferral entry gets resolved either way. Document the choice in the dev notes.

**AC16 — fileio.asm AR23 header updates.**

**Given** the module-header documentation for `fileio.asm` post-Story-2.3 lists `fileio_load`, `fileio_load_initial`, `fileio_strip_leading_spaces` in the `Public:` block and one AR15 carve-out (launch) in the "Architectural enforcement here" block
**When** Story 2.4 lands
**Then**:
  - `Public:` grows by `fileio_save` (per AC11's contract block).
  - "Architectural enforcement here" block's AR15 sub-bullet expands to enumerate TWO carve-outs (launch + save) with parallel rationale prose (per AC5).
  - `State owned (read/write):` block adds `fileio_write_count` (new module-local cell) and updates `bdos_error_pre_msg` to note the second writer (save's Step 1).
  - `Dependencies:` block adds explicit notes:
    - `inc/bdos.inc (BDOS_DELETE, BDOS_MAKE, BDOS_WRITE_SEQ — Story 2.4 save path)` — all three are already EQUd in bdos.inc; the dependency was implicit, this elevates it.
    - `inc/bios.inc (BDOS_ENTRY — Story 2.3 launch AR15 carve-out + Story 2.4 save AR15 carve-out)` — update existing comment.
  - Top-of-module synopsis text (lines 12-21 in current source) extends to include the save flow:
    ```
    ; Entry surface for the ex-line (full post-2.4 shape):
    ;     cmd_edit / cmd_edit_force   (in src/exline.asm)
    ;             |
    ;             v
    ;     fileio_load -> fileio_load_after_open (shared body)
    ;     fileio_load_initial (Story 2.3 — launch path)
    ;             |
    ;             v
    ;     BDOS_OPEN -> SET_DMA -> READ_SEQ loop -> CLOSE
    ;
    ;     cmd_write / cmd_write_quit   (in src/exline.asm — Story 2.4)
    ;             |
    ;             v
    ;     fileio_save
    ;             |
    ;             v
    ;     BDOS_DELETE -> BDOS_MAKE -> BDOS_SET_DMA ->
    ;     BDOS_WRITE_SEQ loop -> BDOS_CLOSE
    ```

**Top-of-module Purpose line** extends to add "Story 2.4 lands the save side: fileio_save orchestrates DELETE / MAKE / WRITE_SEQ-loop / CLOSE with a second AR15 carve-out for the benign DELETE-of-nonexistent file."

## Tasks / Subtasks

- [x] **Task 1: Add `fileio_compose_cant_write` helper to `src/fileio.asm` (AC9)**
  - [x] Sub 1.1: Locate `fileio_compose_cant_open` (lines 894-914 in current source).
  - [x] Sub 1.2: Add `fileio_compose_cant_write` immediately AFTER `fileio_compose_cant_open`, mirroring its structure (copy prefix → copy filename_buffer through NUL → RET). AR23 contract block per AC9.
  - [x] Sub 1.3: Add `fileio_msg_cant_write_prefix: DEFB "can't write ", 0` to the module-local data block immediately AFTER `fileio_msg_cant_open_prefix`.
  - [x] Sub 1.4: Verify the existing `ASSERT $ - fileio_status_scratch >= 48` continues to cover the new max content (28 bytes; well within 48). Update the comment near the ASSERT (current text says "max content ... 28 bytes" — keep the bound but extend the example to cover the save banners).

- [x] **Task 2: Refactor `fileio_compose_loaded_status` for suffix-parameterisation (AC10)**
  - [x] Sub 2.1: Identify `fileio_compose_loaded_status` (lines 929-960 in current source) and its private `.suffix DEFB " bytes", 0`.
  - [x] Sub 2.2: Extract the body from "after filename copy + space + decimal emit" through the suffix copy as an internal label `fileio_compose_filename_count_suffix` (or similar — dev owns the name). Contract: In: BC = byte count, DE = suffix ptr; Out: HL = fileio_status_scratch; Trashes: A, BC, DE, HL, F.
  - [x] Sub 2.3: `fileio_compose_loaded_status` becomes: load private `.bytes_suffix` (renamed from `.suffix` for clarity) into DE; JP into the shared body.
  - [x] Sub 2.4: Add `fileio_compose_written_status`: same shape; loads private `.written_suffix: DEFB " bytes written", 0` into DE; JPs into the shared body.
  - [x] Sub 2.5: Verify the existing Story 2.2 tests pass byte-equivalently against the refactor (regression net).

- [x] **Task 3: Add `fileio_save` public entry + AR15 save carve-out to `src/fileio.asm` (AC4, AC5, AC7, AC11)**
  - [x] Sub 3.1: Add `fileio_write_count: DEFW 0` to the module-local data block (alongside `fileio_dec_dest`).
  - [x] Sub 3.2: Add `fileio_save` public entry with the AC4 numbered-step orchestration:
    - Step 1: `CALL fileio_compose_cant_write` + `LD (bdos_error_pre_msg), HL`.
    - Step 2: AR15 SAVE CARVE-OUT — inline `LD C, BDOS_DELETE ; LD DE, fcb_scratch ; CALL BDOS_ENTRY` (return code A discarded). Inline annotation: `; AR15 save carve-out: 0xFF is the benign "no prior file" case`.
    - Step 3: `LD DE, fcb_scratch` + `BDOS_CALL BDOS_MAKE` (macro routing on 0xFF).
    - Step 4: `LD DE, DEFAULT_DMA` + `BDOS_CALL BDOS_SET_DMA`.
    - Step 5: Compute `fileio_write_count` = `(gap_start - GAP_BUFFER_BASE) + (GAP_BUFFER_BASE + GAP_BUFFER_MAX - gap_end)`. Save 16-bit result.
    - Step 6: Gap-walk + DMA-fill loop per AC7 pseudocode. Each `BDOS_WRITE_SEQ` macro-routes on sign-bit; post-macro `OR A; JR NZ, .write_abort` catches A = 1..127 (disk-full class).
    - Step 7: EOF-pad: write `0x1A` at next DMA position, then space-pad to 128 boundary, then final `BDOS_CALL BDOS_WRITE_SEQ` + the same A != 0 abort check.
    - Step 8: `LD DE, fcb_scratch` + `BDOS_CALL BDOS_CLOSE` (macro routing).
    - Step 9: `LD HL, 0` + `LD (bdos_error_pre_msg), HL` (clear pre-stage).
    - Step 10: `XOR A; LD (buffer_dirty), A`.
    - Step 11: `LD BC, (fileio_write_count)` + `CALL fileio_compose_written_status` + `XOR A` + `JP status_set_message` (tail-JP).
    - `.write_abort`: re-stage pre_msg (defensive — should still be set from Step 1, but paranoid), JP `bdos_error_funnel`.
  - [x] Sub 3.3: Add the AR23 contract block per AC11.
  - [x] Sub 3.4: Update fileio.asm's module-header AR23 block per AC16:
    - `Public:` grows by `fileio_save`.
    - "Architectural enforcement here" AR15 sub-bullet enumerates TWO carve-outs (launch + save) with rationale prose.
    - `State owned (read/write):` adds `fileio_write_count`; updates `bdos_error_pre_msg` comment.
    - `Dependencies:` adds explicit BDOS_DELETE / BDOS_MAKE / BDOS_WRITE_SEQ notes.
    - Top-of-module purpose + entry-surface synopsis extends per AC16 template.

- [x] **Task 4: Add `cmd_write` and `cmd_write_quit` handlers to `src/exline.asm` (AC2, AC3)**
  - [x] Sub 4.1: Locate `cmd_edit` / `cmd_edit_force` in src/exline.asm (lines 625-679 in current source).
  - [x] Sub 4.2: Add `cmd_write` immediately AFTER `cmd_edit_force`. Body:
    - `CALL fileio_strip_leading_spaces` (Story 2.2 helper).
    - `OR A` + `JR Z, .no_arg` (no arg or all-space arg).
    - Otherwise: `CALL fileio_parse_filename` (HL = stripped arg, A = stripped length) — this updates fcb_scratch + filename_buffer per FR5.
    - `JR .do_save`.
    - `.no_arg`: check filename_buffer[0] != 0; if zero, set `msg_missing_filename` + `JP exline_cancel_core`.
    - If filename_buffer[0] != 0: scan filename_buffer for NUL (max 16 bytes) to derive length; `CALL fileio_parse_filename` with HL = filename_buffer, A = derived length.
    - `.do_save`: `CALL fileio_save` (which RETs on success or terminally JPs to input_loop on funnel).
    - `JP exline_cancel_core` (on success, banner survives).
    - AR23 contract block per AC2's "In / Out / Trashes / Calls" template.
  - [x] Sub 4.3: Add `cmd_write_quit` immediately AFTER `cmd_write`. Body is near-identical to `cmd_write` BUT the final disposition is:
    - `.do_save_then_quit`: `CALL fileio_save`; on RET (success path) `JP init_teardown`.
    - The `.no_arg`-with-empty-filename path stays as `JP exline_cancel_core` (refuse the quit on missing filename).
    - **Code-share opportunity:** `cmd_write` and `cmd_write_quit` share ~80% of their bodies. Per the existing Story 2.2 deferred-work entry W3 (line 125 — `cmd_edit_common` refactor opportunity), the dev MAY (not MUST) factor a shared `cmd_save_common` helper. If factored, the contract is `cmd_save_common: In: HL/A as the dispatch contract; Out: RET on save success (filename was resolvable) with filename_buffer + fcb_scratch + save executed; tail-JP exline_cancel_core on missing-filename refusal.` Then `cmd_write` becomes `CALL cmd_save_common ; JP exline_cancel_core` and `cmd_write_quit` becomes `CALL cmd_save_common ; JP init_teardown`. **Decision left to dev.** Factor if size budget pressure (AC13) warrants it; leave inline if duplication is cheaper than the helper's CALL/RET overhead.
    - AR23 contract block per AC3's template.
  - [x] Sub 4.4: Update `exline_command_table` (lines 729-738 in current source) — insert two new entries BEFORE the `q` entry:
    ```asm
    exline_command_table:
        DEFB    "e", 0
        DEFW    cmd_edit
        DEFB    "e!", 0
        DEFW    cmd_edit_force
        DEFB    "w", 0                       ; NEW (Story 2.4)
        DEFW    cmd_write
        DEFB    "wq", 0                      ; NEW (Story 2.4)
        DEFW    cmd_write_quit
        DEFB    "q", 0
        DEFW    cmd_quit
        DEFB    "q!", 0
        DEFW    cmd_quit_force
        DEFB    0                            ; terminator
    ```
  - [x] Sub 4.5: Update exline.asm's module-header AR23 block:
    - `Public:` adds `cmd_write` and `cmd_write_quit`.
    - `Dependencies:` updates `src/fileio.asm` line to include `fileio_save`.
    - `exline_command_table` comment updated to reflect 6 entries instead of 4.

- [x] **Task 5: Test infrastructure — promote the `init_teardown` stub refactor (AC15)**
  - [x] Sub 5.1: Create `test/inc/test_teardown_stub.inc` with the body specified in AC15.
  - [x] Sub 5.2: Replace inline `init_teardown:` blocks in all current test consumers with `INCLUDE "../inc/test_teardown_stub.inc"`:
    - Story-2.1 set: `exline_q-clean-buffer.asm`, `exline_q-dirty-buffer.asm`, `exline_q-bang-force.asm`, `exline_unknown-command.asm`, `exline_bare-enter.asm`.
    - Story-2.2 set: 8 `fileio_e-*` / `fileio_load-*` tests.
    - Story-2.3 set: 5 `init_default-fcb-*` tests + `init_cold_start-state-shape.asm`.
    - Story-2.1 dispatch / parser tests fixed by Story 2.3's regression net (3 dispatch + 7 parser).
  - [x] Sub 5.3: Verify all tests continue to pass post-refactor (regression net).
  - [x] Sub 5.4: **OPTIONAL** — split this task into a separate commit if the dev finds the scope distracting from the main story. The refactor's outcome is identical either way; the deferred-work entry (line 118) is resolved either way.

- [x] **Task 6: Add headless tests (AC12)**
  - [x] Sub 6.1: `test/cases/fileio_save-roundtrip.asm` — pre-populate gap with "hello world\r\n" (13 bytes via inline write into gap-buffer region; AR-exempt in tests) + filename_buffer + fcb_scratch; CALL `fileio_save`; assert post-save status banner + buffer_dirty=0 + gap unchanged; then CALL `fileio_load` (HL = filename_buffer, A = 9); assert post-load gap content matches "hello world\r\n" byte-for-byte. Sentinel range 0xF0..0xF7.
  - [x] Sub 6.2: `test/cases/fileio_save-empty-buffer.asm` — CALL `gapbuf_init` (empty), populate filename_buffer + fcb_scratch ("B:EMPTY.TXT"), CALL `fileio_save`. Assert: status banner = `"B:EMPTY.TXT 0 bytes written"`; in-test verify on-disk via BDOS_OPEN + SET_DMA + READ_SEQ: file is 128 bytes (one sector), byte 0 = 0x1A, bytes 1..127 = 0x20, second BDOS_READ_SEQ returns A=1.
  - [x] Sub 6.3: `test/cases/fileio_save-1A-padding.asm` — pre-populate gap with 100 bytes of 'A' (0x41), populate filename_buffer + fcb_scratch ("B:PAD100.TXT"); CALL `fileio_save`; in-test verify on-disk: bytes 0..99 = 'A', byte 100 = 0x1A, bytes 101..127 = 0x20.
  - [x] Sub 6.4: `test/cases/fileio_save-write-protect.asm` — pre-stage write-protected target via Mechanism A (filesystem-level R/O via `chmod 0444`) OR Mechanism B (FCB high-bit on ext char 0); pre-populate state; pre-set `buffer_dirty = 1` (to verify FR52 — dirty stays dirty on failure); CALL `fileio_save`; via `test/inc/test_input_loop_stub.inc` sentinel verify funnel was entered; assert `status_buffer` content matches `"can't write B:RO.TXT"`; assert `buffer_dirty` still = 1 (FR52 load-bearing).
  - [x] Sub 6.5: Each test follows the AR25-order INCLUDE pattern from Story 2.3's init_default-fcb tests. Includes `state.inc` LAST as the positional anchor.
  - [x] Sub 6.6: If a 5th test is added (`cmd_wq-warm-boot-on-success.asm` per AC15 Sub 5.4 option): drive `cmd_write_quit` (not just `fileio_save` directly) with a clean save path; assert `init_teardown_called == 1` (via the new stub).
  - [x] Sub 6.7: Update `test/Makefile`'s `clean:` recipe to add `rm -f fixtures/OUT.TXT fixtures/PAD100.TXT fixtures/EMPTY.TXT fixtures/RO.TXT` (the four save-test output files) so stale post-test files don't leak across runs.
  - [x] Sub 6.8: **Hardware-UAT-only fallback for write-protect (Mechanism C):** if both Mechanism A and B fail under iz-cpm during dev, defer the headless write-protect test, leaving only AC14 step 12's hardware UAT as coverage. Document the deferral in `deferred-work.md` under Story 2.4 with the rationale (iz-cpm limitations on R/O simulation). **CRITICAL — this deferral, if exercised, weakens FR51 / FR52 coverage**: the headless gates would no longer pin "write-protect surfaces 'can't write' + dirty stays dirty" — flag prominently in dev notes.

- [x] **Task 7: Build + headless test verification (AC13)**
  - [x] Sub 7.1: `make clean && make` succeeds; capture SHA-256 of `vibe.com`.
  - [x] Sub 7.2: Repeat `make clean && make`; verify byte-identical SHA (NFR18).
  - [x] Sub 7.3: `make sizes` reports the new code-section size. Capture verbatim. Note delta vs Story 2.3's 3235 B and the (still-unamended) NFR9 budget. Flag if footprint exceeds 4096 B (the proposed amended ceiling).
  - [x] Sub 7.4: AR grep sweeps per AC13 — all pass; the two AR15 carve-out sites in fileio.asm bear the documented annotations.
  - [x] Sub 7.5: `make test` from project root — all existing tests pass (regression net for the Task 2 refactor and the stub refactor in Task 5) + the new fileio_save-* tests pass. Live baseline becomes 45 pass + 1 deliberate fail (was 41 pre-2.4).

- [x] **Task 8: Update `_bmad-output/implementation-artifacts/deferred-work.md` (Story 2.3 context)**
  - [x] Sub 8.1: Mark deferred-work entry line 105 (`exline_command_table` structural ASSERTs) as either resolved or re-deferred. The table grew from 4 entries (post-2.2) to 6 entries (post-2.4); per the entry's own decision rule ("at 6+ entries the ASSERT is worth the bytes"), the dev SHOULD land the structural ASSERTs at the bottom of `exline_command_table` (e.g., assert entry count, assert each handler addr non-zero). If the dev judges the bytes overhead too high given AC13's footprint pressure, re-defer with rationale.
  - [x] Sub 8.2: Mark deferred-work entry line 118 (init_teardown stub refactor) as RESOLVED (Task 5 promotes it).
  - [x] Sub 8.3: Mark deferred-work entry line 125 (W3 — `cmd_edit_common` factoring opportunity) as either resolved (if Task 4 Sub 4.3 factored `cmd_save_common` AND it makes sense to also factor `cmd_edit_common` symmetrically for the size budget) or re-deferred with the size-budget context.
  - [x] Sub 8.4: Add a new "Deferred from: dev of story-2-4-file-save-w-w-filename-wq (2026-05-XX)" section with any new deferrals: NFR9 footprint observation, hardware UAT deferral (AC14), Mechanism-C write-protect test deferral if Sub 6.8 exercised it, AR15 carve-out documentation in architecture.md (deferred-work line 139 still pending — Story 2.4 makes it TWO carve-outs to document at the architecture-doc level, even more justified).
  - [x] Sub 8.5: Update deferred-work line 122 (NFR9 amend) noting Story 2.4 adds another ~280-360 B to the overshoot; the amendment is more urgent than ever.

- [x] **Task 9: Hardware UAT (AC14)** — *to be completed by user after headless gates are all green*.
  - [x] Sub 9.1: `make push` — SLIDE transfer to the MicroBeast.
  - [x] Sub 9.2: Step through AC14's 13 hardware UAT steps; record observations in Debug Log References.
  - [x] Sub 9.3: Particular regressions to watch for:
    - `:w` on a clean buffer (already saved) is allowed (vi convention) — no refusal, status reads `"FILENAME N bytes written"`.
    - `:w` after `vibe newgame.fs` (Story 2.3 [new file] state) creates the file — confirms the FR1 / FR52 / NFR6 load-bearing flow (Story 2.3 preserved filename_buffer; Story 2.4 saves to it).
    - `:wq` warm-boots immediately on success (no double "press a key" lag).
    - `:wq` on a failing save (e.g., write-protect) leaves the editor at the buffer with the error banner — the warm-boot is gated on success.
    - The on-disk file's 0x1A + space-pad survives a CCP `type b:foo.fs` (or similar) — confirms the EOF marker is honoured by CCP's text dump.
    - Sustained-typing regression post-Story-2.8 hardware UAT pass.

### Review Findings

Code review pass, 2026-05-15 (Blind Hunter + Edge Case Hunter + Acceptance Auditor). 1 decision-needed (resolved), 3 patches (applied), 12 deferred, ~16 dismissed. Post-patch SHA `60c07f73b8a690a6d0d200b9d6b6af4c82e0883448a2912d0a74c32ed61b1a58`, byte-identical second rebuild (NFR18). Size 3720 B / +6 B vs pre-review 3714 B; 376 B headroom against proposed 4096 B amended NFR9 ceiling. 45 pass / 1 deliberate fail (unchanged from pre-review).

#### Resolved (decision-needed → patch)

- [x] [Review][Patch] **`cmd_write_quit` warm-boots on Step-0 R/O refusal — FR52 violation (CRITICAL)** [src/fileio.asm:585-594]. `fileio_save`'s Step 0 R/O refusal originally `JP status_set_message` tail-jumped to a normal RET, unlike the `WRITE_SEQ .write_abort` path which `JP bdos_error_funnel`. `cmd_write_quit` does `CALL fileio_save / JP init_teardown` — `:wq` against a STAT-marked R/O file would have composed "can't write FILENAME" then RET'd, and cmd_write_quit would have warm-booted, discarding the unsaved buffer. The bug shipped latent against the exact failure mode the Step 0 pre-check was added to prevent. (Blind Hunter B1+B2+B3+B4 + Edge Case Hunter E1 + Acceptance Auditor convergence.) **Resolved**: Step 0 R/O refusal now sets `bdos_error_pre_msg = HL` after `fileio_compose_cant_write` and `JP bdos_error_funnel` — funnel's terminal `JP input_loop` bypasses cmd_write_quit's tail-JP, mirroring `.write_abort`. fileio_save contract block also updated to reflect the three-outcome reality (success-RET / R/O-refusal-no-return / funnel-no-return). +2 B.

#### Patches (applied)

- [x] [Review][Patch] **`cmd_save_strlen_filename_buffer` returns A=16 on 16-byte un-NUL buffer, violating documented 0..15 contract** [src/exline.asm:838-853]. Changed `CP FILENAME_BUFFER_SIZE` to `CP FILENAME_BUFFER_SIZE - 1` — caps the return at A=15. Behaviour-preserving for the spec'd cases; the pathological 16-non-NUL case now returns A=15 instead of A=16. (Blind Hunter B8 + Edge Case Hunter E2 + Acceptance Auditor F7.) 0 B.

- [x] [Review][Patch] **`fileio_save` Step 0 SAVE-PRECHECK trusts SEARCH_FIRST to return only {0..3, 0xFF}** [src/fileio.asm:568-572]. After `CP 0xFF / JR Z`, added `CP 4 / JR NC, .precheck_done` (treat any A ≥ 4 as "no R/O match"). Without the bound, a non-spec BDOS return of 4..127 would fall into the index decode (`ADD A,A` ×5 → E up to 0xE0), then `BIT 7, (HL)` would read from `DEFAULT_DMA + 9 + E` — TPA code memory — possibly false-positive R/O refusal. (Edge Case Hunter E3.) +4 B.

#### Deferred

- [x] [Review][Defer] **FCB bytes +12..15 not zeroed between `BDOS_SEARCH_FIRST` and the subsequent `BDOS_DELETE` / `BDOS_MAKE`** [src/fileio.asm:557-559]. CP/M 2.2 conformant SEARCH_FIRST should not modify the input FCB, but a defensive zero-fill of `fcb_scratch + 12..15` would protect against BDOS variants that mutate the FCB's current-extent / S1 / S2 / RC bytes. iz-cpm and real-CP/M-2.2 both honor the no-mutation invariant (Story 2.4 hardware UAT passes); cost is ~6-8 bytes against NFR9 pressure. Re-open if a real BIOS variant surfaces FCB drift. (Blind Hunter B5.)

- [x] [Review][Defer] **`fcb_scratch + 9` restore via `AND 0x7F` assumes BDOS preserves byte +9 across SEARCH_FIRST** [src/fileio.asm:560-563]. The restore path masks the high bit; if BDOS modified byte +9 (instead of preserving it), the mask is wrong. Safer pattern: `PUSH AF` original value at line 555 before `OR 0x80`, then `POP / LD (fcb_scratch + 9), A` at line 562. Same conformance question as the +12..15 entry above. Defer with same rationale. (Edge Case Hunter E6.)

- [x] [Review][Defer] **`bdos_error_pre_msg` stale-pointer risk widened by Step 0 R/O path (W8 family)** [src/fileio.asm:585-588]. The Step 0 R/O refusal doesn't touch `bdos_error_pre_msg` — relies on the "cell is zero outside the pre_msg→BDOS_CALL window" invariant. Adds a third nominal write/clear site to the existing two (load + save). Architectural concern; same forward-looking deferral as Story 2.2's W8. (Blind Hunter B6.)

- [x] [Review][Defer] **`exline_command_table` not in lexicographic order — would break a future binary search** [src/exline.asm:903-916]. Entries `e, e!, w, wq, q, q!`; lex order would be `e, e!, q, q!, w, wq`. Intentional per Story 2.2's "file-IO cluster grouped before quit cluster" convention; linear walk is the current dispatcher. Re-open when the structural-ASSERT deferral lands or when a binary-search variant is proposed. (Blind Hunter B7.)

- [x] [Review][Defer] **`fileio_save_flush_sector .write_abort` re-stages `bdos_error_pre_msg` redundantly** [src/fileio.asm:792-798]. The cell was already set at Step 1; nothing inside `fileio_save` clears it before the WRITE_SEQ failure surfaces. The inline comment calls the re-stage "paranoid". Removing it would save ~6 bytes against NFR9 pressure but adds a small fragility surface if a future intermediate step clears the cell. Defer to a code-shrink pass that audits all pre_msg writers as a unit. (Blind Hunter B12.)

- [x] [Review][Defer] **`fileio_save-make-failure.asm` uses sjasmplus cross-scope local-label (W5 family)** [test/cases/fileio_save-make-failure.asm:~end]. Repeats the `JP test_start.after_funnel` pattern from `fileio_load-not-found.asm` already flagged as fragile under sjasmplus 1.23.0 local-scope rules. Re-deferred; bundle with W5 in the next test-harness pass. (Blind Hunter B13.)

- [x] [Review][Defer] **`fileio_save-roundtrip` test has an implicit cross-call invariant — fcb_scratch+9 not asserted clean post-save** [test/cases/fileio_save-roundtrip.asm]. `fileio_load` is called immediately after `fileio_save` without re-zeroing `fcb_scratch`; a future fileio_load refactor that assumes fresh fcb_scratch state could regress without surfacing. Defer to test-strengthening pass. (Blind Hunter B15.)

- [x] [Review][Defer] **`fileio_save_walk_bytes` PUSH HL/BC live across funnel-trap entry — potential stack leak per failed save** [src/fileio.asm:730-753, 782-798]. If WRITE_SEQ hits sign-bit while walk_bytes has `PUSH HL / PUSH BC` pending, `bdos_error_funnel`'s terminal `JP input_loop` leaves ~4 bytes on the stack. Repeated save failures could accumulate. Architectural — relates to whether `bdos_error_funnel` should restore SP from an anchor; pre-existing concern at the funnel level, just widened by Story 2.4's walk_bytes' added PUSH state. (Edge Case Hunter E4.)

- [x] [Review][Defer] **`cmd_write` / `cmd_write_quit` `.no_arg` branch trusts a non-NUL `filename_buffer[0]` as a "filename present" sentinel** [src/exline.asm:743-820]. If a future bug leaves `filename_buffer[0]` non-NUL but the rest stale/corrupt (no successful parse since the last `:e`), the re-parse path feeds garbage to `fileio_parse_filename`. Today's writers all maintain the invariant. Defer; revisit if a filename_buffer-corruption surface appears. (Edge Case Hunter E5.)

- [x] [Review][Defer] **Gap-half H1 / H2 `SBC HL, DE` arithmetic has no underflow guard (Steps 5-6)** [src/fileio.asm:622-660]. If SR2 invariant breaches (gap_start > gap_end OR gap_end > GAP_BUFFER_BASE+GAP_BUFFER_MAX), the SBC underflow yields a huge BC; `walk_bytes` could read up to 64KB past the gap into yank/static/code memory. SR2 invariant is upstream — Story 1.7 gap-buffer invariants. Defer; an SR2 violation is a more fundamental bug than the save path needs to defend against. (Edge Case Hunter E8.)

- [x] [Review][Defer] **AC12 Sub 6.4 test renamed (`-write-protect` → `-make-failure`); R/O headless coverage gap acknowledged in deferred-work — but the `:wq` R/O path was not retested on hardware after the Step 0 fix.** Acceptance Auditor F1. Tied to the decision-needed FR52 fix (D1) — once D1 lands, the hardware UAT retry should include a `:wq` step against a STAT-R/O file. The headless test rename itself is spec-authorised per AC12 Sub 6.8 (Mechanism C deferral).

- [x] [Review][Defer] **Optional `cmd_wq-warm-boot-on-success.asm` test not created (AC12 Sub 6.6, AC15 Sub 5.4)**. Explicitly optional per spec; hardware UAT step 10 covers `:wq` warm-boot on real hardware. Without it, the headless suite never directly asserts the `init_teardown_called` sentinel flips after a successful `:wq`. (Acceptance Auditor F2.)

## Dev Notes

### Architecture compliance

This story closes the **save half of journey-1a** (PRD line 215+): `vibe foo.fs` → edit → `:w` / `:wq` → file on disk. With Story 2.4 done, the full one-keystroke load → edit → save → quit loop is in place at the file-I/O level; Stories 2.5..2.13 close the edit half (motions, operators, undo, paste, insert mode). The wider architecture mapping:

- **FR4 (Save to current filename).** Primary deliverable. `:w` reads filename_buffer (or re-parses on save-as), writes via `fileio_save`. AC2 + AC4.
- **FR5 (Save-as).** `:w foo.fs` updates filename_buffer (via `fileio_parse_filename` re-parse) so subsequent bare `:w` saves to the new name. AC8.
- **FR7 (Save-and-quit `:wq`).** Composes save + `init_teardown`; quit is gated on save success via the funnel's "JP input_loop on failure" semantics naturally bypassing the trailing `JP init_teardown`. AC3.
- **FR9 (Default-drive B:).** `cmd_write`'s arg parse re-uses `fileio_parse_filename` which already enforces FR9 (Story 2.2). No new FR9 logic in fileio_save.
- **FR10 (Explicit drive prefix).** Same path — `fileio_parse_filename` honours `A:foo.fs` / `B:foo.fs`.
- **FR51 (I/O failure surfacing).** `fileio_save` pre-stages `"can't write FILENAME"` via `bdos_error_pre_msg`; BDOS_MAKE / WRITE_SEQ-sign-bit / CLOSE failures surface this banner through the funnel.
- **FR52 / NFR6 (No silent data loss).** Load-bearing for the story. `buffer_dirty` is cleared ONLY on the success path (AC4 Step 10); any failure leaves it nonzero. The funnel's terminal `JP input_loop` ensures the success-only `LD (buffer_dirty), A` line is bypassed on failure. AC6 covers the cases.
- **AR12 (Single status-message funnel).** Every status emit goes through `status_set_message` — both the success "FILENAME N bytes written" banner and the failure "can't write FILENAME" banner (via the funnel's call into status_set_message). No direct status_buffer writes.
- **AR13 (Single screen-emission path).** `fileio_save` has zero `BIOS_CONOUT` references. Status banner change → `status_dirty=1` (set by status_set_message) → next render_diff emits the row.
- **AR14 (Single buffer-mutation owner — gapbuf.asm).** `fileio_save` reads the gap-buffer regions but does NOT write them. The save's LDIR copies FROM `[GAP_BUFFER_BASE, gap_start)` and `[gap_end, BASE+MAX)` INTO `DEFAULT_DMA` (a separate region). No new AR14 carve-out is required — the save is fully invariant-respecting on the buffer side.
- **AR15 (Single BDOS gateway — `BDOS_CALL` macro). NEW CARVE-OUT: save's BDOS_DELETE.** Documented in AC5. Carve-out is necessary because `0xFF` (file not found) is the NORMAL case for a first save, not an error; routing through the funnel would surface "can't write FILENAME" on every first save. Single-site, inline-annotated, AR23-documented (per AC5 + AC16). `fileio.asm` now has TWO documented AR15 carve-outs (launch + save), parallel structures.
- **AR16 (Status-message string convention).** Two new dynamic status strings:
  - `"<FILENAME> N bytes written"` — built by `fileio_compose_written_status` from filename_buffer + decimal count + " bytes written" suffix. Lowercase, no period, ≤ 36 chars (max). AR16-compliant.
  - `"can't write <FILENAME>"` — built by `fileio_compose_cant_write` from "can't write " prefix + filename_buffer. Lowercase, no period, ≤ 27 chars (max). AR16-compliant.
- **AR22 (Naming).** New public symbols: `cmd_write`, `cmd_write_quit`, `fileio_save`. Internal helpers (dotted-locals + named labels): `.no_arg`, `.do_save`, `.do_save_then_quit`, `.write_abort`, `fileio_compose_cant_write`, `fileio_compose_written_status`, `fileio_compose_filename_count_suffix` (the suffix-parameterised shared body, name owned by the dev). The `cmd_write*` prefix matches the existing `cmd_edit*` / `cmd_quit*` convention; `fileio_save` mirrors `fileio_load`.
- **AR23 (File structure and routine contracts).** Every new public / internal helper begins with the four-line `In:` / `Out:` / `Trashes:` / `Calls:` contract. `fileio.asm`'s and `exline.asm`'s module-header `Public:` lists grow. The "Architectural enforcement here" block in fileio.asm gains the AR15 save carve-out alongside the existing launch carve-out (AC16 details).
- **AR24 (Format).** 4-space indentation, UPPERCASE mnemonics, `;` line / `;;` section comments, no trailing periods.
- **AR25 (Module include order).** No new modules; fileio.asm's and exline.asm's positions are unchanged.

### Library / framework requirements

**sjasmplus 1.23.0:**
- Already pinned by Makefile's `check-toolchain`.
- **Forward-reference handling.** `cmd_write` / `cmd_write_quit` in `src/exline.asm` reference `fileio_save` (in `src/fileio.asm`, INCLUDEd AFTER exline.asm per AR25). The forward reference resolves on sjasmplus's two-pass model — same pattern as Story 2.2's `cmd_edit` referencing `fileio_load`. No new forward-reference complications.
- **The Story-2.3 dual-label trick is NOT needed here.** Story 2.3 used `.done_parse: / fileio_compose_filename_buffer:` consecutive labels to extract a tail-block without breaking dotted-local references. Story 2.4's helpers (`fileio_compose_cant_write`, `fileio_compose_written_status`, the suffix-parameterised shared body) are fresh entries — no extraction-with-reference-preservation gymnastics required.

**iz-cpm:**
- All four new headless tests run under iz-cpm.
- **Write tests need writable fixture dir.** test/Makefile already mounts `fixtures/` as both A: and B: in RW mode (no `:ro` flag). Confirms write tests can create files. The fixtures dir must be cleanable post-test; `make test` doesn't run a clean between cases, so a `make clean` (which Sub 6.7 extends) is the inter-iteration reset.
- **Write-protect testing under iz-cpm.** The major unknown for AC12 Sub 6.4. Three mechanisms enumerated; dev investigates during implementation. If all three fail, headless coverage of FR51 / FR52's write-protect path is deferred to hardware UAT (AC14 step 12) — explicit in Sub 6.8.
- **No new fixtures committed to git.** Sub 6.7 extends Makefile's `clean:` recipe to remove the post-test files; the fixtures themselves are output of the tests, not committed. (Same pattern as Story 2.2's `big.bin` — generated by `test/Makefile`, gitignored, regenerated each `make test`.)

**CP/M 2.2 BDOS / MicroBeast BIOS:**
- New BDOS surface used by the save flow: `BDOS_DELETE` (19), `BDOS_MAKE` (22), `BDOS_WRITE_SEQ` (21). All three are already EQUd in `inc/bdos.inc` (Story 1.4 / 2.2). No `inc/` changes are required.
- **BDOS_MAKE behaviour on existing file.** CP/M 2.2 BDOS_MAKE returns 0xFF (failure) if a directory entry for the same filename already exists. AC4 Step 2's DELETE-before-MAKE eliminates this case for normal flow. The directory-full case still surfaces as 0xFF from MAKE; the pre-staged banner handles it.
- **BDOS_WRITE_SEQ return code semantics.** A = 0 success; A = 1 directory entry could not be written (full / R/O / similar); A = 2 disk write error not in deferred queue; A = 3 ... (rare). The macro's `JP M` catches only the sign-bit (0xFF) class; A = 1..127 (the documented WRITE_SEQ error codes) DON'T fire the macro's JP M but DO require caller-side handling (AC6). The save loop's `OR A; JR NZ, .write_abort` covers this.
- **BDOS_DELETE behaviour.** A = 0..3 = file existed and was deleted; A = 0xFF = no matching file. AR15 save carve-out (AC5) inlines the call so the 0xFF (benign) doesn't enter the funnel.
- **No assumed atomicity.** Per PRD line 550-553 ("direct unsafe write — no temp file, no rename dance"). A crashed mid-save MAY leave a half-written file. Documented limitation; not addressed in this story.

### Filename re-parse — design choices

The `cmd_write` handler needs to populate `fcb_scratch` from `filename_buffer` (for bare `:w`) OR from the arg region (for `:w foo.fs`). Two design paths considered:

- **Path A (chosen): re-parse `filename_buffer` (or arg) via Story 2.2's `fileio_parse_filename`.** Pros: reuses existing helper, state-decouples save from prior fcb_scratch history, handles FR9 / FR10 uniformly with `:e`. Cons: ~30 cycles of redundant work on every bare `:w` (the canonical filename_buffer would already match a re-parse).
- **Path B (rejected): trust that `fcb_scratch` is still valid from the prior `:e` / launch / `:w`.** Pros: tiny code saving. Cons: subtle state coupling. A future story could call `gapbuf_init` or some other reset between the `:e` and the `:w` and not realise it doesn't disturb `fcb_scratch`, but if a maintenance pass moves the fcb_scratch zero-init to that reset path, suddenly the `:w` reads garbage. **Path A is the durable choice.**

### Read loop — performance and correctness

The save's gap-walk + DMA-fill (AC7) is the new performance-critical path. Per-sector cost is dominated by:
- One LDIR of up to 128 bytes per sector (~20 T-states + ~21 T-states/byte) ≈ 2700 T-states.
- One BDOS_WRITE_SEQ call (variable, but ~bracketed at ~10000-30000 T-states for the BIOS-disk-write).

For a 32 KB max-load buffer (256 sectors), worst-case save time is ~256 × (2700 + 20000) ≈ 5.8 M T-states ≈ 1.4 s at 4 MHz. Well within "interactive" tolerance (NFR3 governs single-keystroke latency, not bulk file ops); but the user will see a brief pause on max-size saves. **Documented as expected behaviour** — no spinner, no progress bar (would violate NFR1 / AR13 — render is single-path and not interruptible mid-save).

### Previous story intelligence

**From Story 2.3 (most relevant — fileio.asm's primary substrate):**
- `fileio_parse_filename` (Story 2.2) is the canonical text-form filename parser; `fileio_load_initial` (Story 2.3) added the FCB-form launch path via `fileio_setup_from_default_fcb`. Story 2.4's `cmd_write` re-uses `fileio_parse_filename` for both the bare-`:w` (re-parse filename_buffer) and `:w foo.fs` (parse arg) paths; no new FCB-construction helper needed.
- `filename_buffer` preservation contract (Story 2.3 AC4 — `[new file]` path keeps the filename across an open-fail): **load-bearing for Story 2.4's `:w` after `vibe newname.fs`**. The user's intent in `vibe newgame.fs` is "I want to edit a new file with this name"; without filename_buffer preservation, the subsequent `:w` would refuse with "no filename" and the user would lose typed content. AC14 step 2 + AC12's roundtrip test exercise this load-bearing path.
- `fileio_compose_filename_buffer` (Story 2.3 extraction): NOT used by Story 2.4 directly — `cmd_write` re-parses through `fileio_parse_filename` which itself tail-JPs to `fileio_compose_filename_buffer` internally. The re-parse path re-composes filename_buffer; the composed value is byte-identical to its input (canonical form is idempotent under re-parse), so `filename_buffer` is effectively unchanged on a bare `:w` and updated on `:w foo.fs`.

**From Story 2.2 (`:e` substrate):**
- `fileio_load`'s pre-stage-then-clear pattern with `bdos_error_pre_msg` is exactly the model `fileio_save` follows. The funnel-routing semantics + the "clear post-success" invariant + the W8 stale-pointer concern all apply equivalently. Story 2.4 introduces a SECOND writer to `bdos_error_pre_msg` (Story 2.3 added a non-writer — the launch path bypasses the funnel entirely). **Per W8's deferred concern (deferred-work.md line 130)**, the second writer increases the relevance of pinning the invariant via ASSERT or doc; consider as part of Task 8's deferred-work updates.
- `fileio_compose_cant_open` / `fileio_compose_loaded_status` are the shape-templates for the new save-side composers (AC9 + AC10).
- The Story-2.2 BDOS error funnel's "inline ex-line cleanup" (statusln.asm lines 184-191: clear ex_buffer length, mode = MODE_NORMAL, status_dirty = 1) handles the save-failure cleanup automatically. **No new funnel work in Story 2.4.**

**From Story 2.1 (`:q` / `:q!` precedent):**
- `cmd_quit_force` / `init_teardown` are the templates for `cmd_write_quit`'s tail-JP-to-teardown pattern. `cmd_write_quit`'s body ends with `CALL fileio_save ; JP init_teardown` — symmetric to `cmd_quit_force`'s `JP init_teardown`, just gated on the save-success precondition.
- The Story-2.1 `cmd_quit` dirty-refusal pattern (set msg + JP exline_cancel_core) is the template for `cmd_write`'s missing-filename refusal.

**From Story 1.7 (gap buffer — invariants reaffirmed):**
- `gap_start` and `gap_end` define the two halves the save walks. The walk is READ-ONLY against these — AR14 unchanged.
- The empty-buffer state (gap_start = BASE, gap_end = BASE + MAX) means `bytes_to_write = 0` at AC4 Step 5; AC7's special-case handling (skip main loop, go straight to eof_pad with dma_remain = 128) produces the correct one-sector empty file.

**From Story 1.5 (statusln — bdos_error_funnel):**
- The funnel's terminal `JP input_loop` is what makes `cmd_write_quit`'s "quit only on success" work cleanly. No funnel modification required.
- The Story-2.2 widening (bdos_error_pre_msg override + inline ex-line cleanup) covers the save path's needs.

### Git intelligence

Sixteen commits on `main` after the project skeleton (most-recent five per `git log`):

- `1515fc0` — story 2.3: vibe foo.fs opens the file; missing names get [new file].
- `0f1f980` — story 2.2: Wrote file load; :e opens a file, :e! forces past a dirty buffer.
- `be42853` — story 2.1: Wrote the : command-line; :q quits, :q! force-quits, Backspace and Esc work
- `0ef09de` — story 1.12: Wired init/teardown, the main input loop, and the first on-hardware smoke test.
- `dc2dd0d` — story 1.11: Wrote the screen renderer: dirty-row diff, scroll, Ctrl-L full redraw, status row.

Conventions visible in the tree (preserve in Story 2.4):
- One story per commit; short imperative subject + colon-separated context.
- AR23 header blocks on every `.asm` and `.inc` file.
- Every public routine has the `In:` / `Out:` / `Trashes:` / `Calls:` four-line contract.
- File-IO commits use plain-English style ("Wrote file load; :e opens a file"; "vibe foo.fs opens the file; missing names get [new file]").

Suggested commit message for Story 2.4 (when the dev finishes): `story 2.4: Wrote file save; :w writes the buffer, :w name renames, :wq saves and quits.` Match the prior stories' plain-English style.

### Testing requirements

Story 2.4's testing requirements split into four categories:

**Build-time / static:**

1. `make` from project root succeeds (NFR14 / AC13).
2. `make clean && make` produces byte-identical `vibe.com` across two consecutive runs (NFR18 / AC13). Capture both SHAs.
3. `make sizes` reports the new code-section size (NFR9 — overshoot deepening per Story 2.3; track the new size; flag as a notable observation if it exceeds Ant's proposed 4096 B amended ceiling).
4. AR grep sweeps (AC13) — all pass. The two AR15 carve-out sites in fileio.asm are annotated; the second (save) is documented in the module header alongside the launch carve-out.

**Headless test cases (4 new + optional 5th):**

5. `fileio_save-roundtrip.asm` — write 13 bytes; re-read; assert match.
6. `fileio_save-empty-buffer.asm` — write empty buffer; assert 1-sector file with 0x1A + space pad.
7. `fileio_save-1A-padding.asm` — write 100 bytes; assert sector layout exact.
8. `fileio_save-write-protect.asm` — funnel surfaces "can't write FILENAME"; buffer_dirty unchanged.
9. **OPTIONAL** `cmd_wq-warm-boot-on-success.asm` — end-to-end `cmd_write_quit` drives `init_teardown` stub; sentinel flips.

10. **Live baseline becomes at least 45 pass / 1 fail** (41 post-2.3 + 4 new + the deliberate `harness_fail`).

**Regression-net tests (unchanged source — must continue to pass after Task 2 refactor + Task 5 stub refactor):**

11. All 5 Story 2.2 `fileio_load-*` tests pass (regression net for the suffix-parameterise refactor in Task 2).
12. All 3 Story 2.2 `fileio_e-*` tests pass (cmd_edit / cmd_edit_force unchanged).
13. All 5 Story 2.3 `init_default-fcb-*` tests + `init_cold_start-state-shape.asm` pass.
14. All Story 2.1 `exline_*` tests pass (no exline regression; only additive command-table growth).
15. All Story 1.x tests pass (no Epic-1 module changes).
16. The Task-5 stub refactor doesn't change any test's runtime behaviour — every test that used to reach the inline `init_teardown:` block now reaches the same body via INCLUDE.

**Hardware UAT (AC14):**

17. SLIDE-push and exercise `vibe foo.fs` → `:w` → exit → relaunch → `:e foo.fs` → confirm content survived.
18. `vibe missing.fs` → `:w` creates the file (Story 2.3 + Story 2.4 composition test).
19. `:w other.fs` updates the current-file binding (FR5 hardware verification).
20. `:wq` warm-boots on save success; stays at editor on save failure.
21. Write-protect (if mechanism available on hardware): surfaces "can't write" + buffer stays dirty.
22. Sustained-typing regression post-Story-2.8.

### Project Structure Notes

After Story 2.4 the source tree is:

```
src/
├── vibe.asm          # Unchanged
├── init.asm          # Unchanged (Stage 5 = fileio_load_initial; teardown reached by cmd_write_quit's tail-JP)
├── input.asm         # Unchanged
├── statusln.asm      # Unchanged (bdos_error_funnel + inline ex-line cleanup serve the save flow's failure path)
├── gapbuf.asm        # Unchanged (save walks gap-buffer READ-ONLY)
├── render.asm        # Unchanged
├── dispatch.asm      # Unchanged
├── parser.asm        # Unchanged
├── exline.asm        # Story 2.4 — adds cmd_write + cmd_write_quit handlers; exline_command_table grows from 4 to 6 entries
└── fileio.asm        # Story 2.4 — adds fileio_save (public) + fileio_compose_cant_write + fileio_compose_written_status
                      #   + fileio_msg_cant_write_prefix DEFB + fileio_write_count DEFW;
                      #   refactors fileio_compose_loaded_status to share its body with the new written-status composer
                      #   via DE-passed suffix pointer; adds AR15 SAVE CARVE-OUT (inline BDOS_DELETE) documented in
                      #   the AR23 "Architectural enforcement here" block alongside the Story-2.3 launch carve-out.

inc/
├── equates.inc       # Unchanged
├── bios.inc          # Unchanged (DEFAULT_DMA / BDOS_ENTRY / DEFAULT_FCB all already EQUd)
├── bdos.inc          # Unchanged (BDOS_DELETE / BDOS_MAKE / BDOS_WRITE_SEQ all already EQUd per Story 1.4)
├── modes.inc         # Unchanged
├── vt52.inc          # Unchanged
└── state.inc         # Unchanged (fileio_write_count is module-local in fileio.asm, NOT in state.inc)

test/
├── README.md
├── Makefile          # Story 2.4 — clean target extended to rm fixtures/{OUT,EMPTY,PAD100,RO}.TXT
├── inc/
│   ├── test_prologue.inc
│   ├── test_epilogue.inc
│   ├── test_bios_conout_capture.inc
│   ├── test_input_loop_stub.inc
│   └── test_teardown_stub.inc            # NEW (Task 5)
├── fixtures/
│   ├── hello.txt
│   ├── eof1a.txt
│   └── big.bin
│   # (post-test outputs OUT.TXT / EMPTY.TXT / PAD100.TXT / RO.TXT are gitignored
│   #  via the existing fixtures-level *.TXT / *.BIN gitignore patterns or via
│   #  explicit additions if the patterns don't cover them; verify during dev)
└── cases/
    ├── ... (existing 41 cases; the ~21 with inline init_teardown stubs migrate to INCLUDE the new shared stub)
    ├── fileio_save-roundtrip.asm         # NEW
    ├── fileio_save-empty-buffer.asm      # NEW
    ├── fileio_save-1A-padding.asm        # NEW
    ├── fileio_save-write-protect.asm     # NEW
    └── cmd_wq-warm-boot-on-success.asm   # OPTIONAL NEW (per AC15 Sub 5.4)
```

### Files created and modified by this story

**Files created:**
- `test/inc/test_teardown_stub.inc` (Task 5 — the shared `init_teardown:` stub promoted from the duplicated inline block).
- `test/cases/fileio_save-roundtrip.asm`
- `test/cases/fileio_save-empty-buffer.asm`
- `test/cases/fileio_save-1A-padding.asm`
- `test/cases/fileio_save-write-protect.asm`
- `test/cases/cmd_wq-warm-boot-on-success.asm` (OPTIONAL — per Sub 5.4)

**Files modified (production):**
- `src/fileio.asm` — adds `fileio_save` (public) + `fileio_compose_cant_write` + `fileio_compose_written_status` + `fileio_msg_cant_write_prefix` (DEFB) + `fileio_write_count` (DEFW); refactors `fileio_compose_loaded_status` to share its decimal-and-suffix body with the new written-status composer via a DE-passed suffix pointer; AR23 header gains `fileio_save` in Public list, the AR15 save carve-out documentation in the "Architectural enforcement here" block (alongside the Story-2.3 launch carve-out), explicit BDOS_DELETE / BDOS_MAKE / BDOS_WRITE_SEQ Dependencies notes, and the extended top-of-module entry-surface synopsis per AC16.
- `src/exline.asm` — adds `cmd_write` and `cmd_write_quit` handlers; `exline_command_table` grows from 4 entries (e, e!, q, q!) to 6 (e, e!, w, wq, q, q!); AR23 header `Public:` list grows; `Dependencies:` updates `src/fileio.asm` line to include `fileio_save`.

**Files modified (test infrastructure):**
- `test/Makefile` — `clean:` recipe extended to `rm -f fixtures/OUT.TXT fixtures/EMPTY.TXT fixtures/PAD100.TXT fixtures/RO.TXT` (Sub 6.7).
- ~21 existing test files (per AC15) — inline `init_teardown:` blocks replaced with `INCLUDE "../inc/test_teardown_stub.inc"`. NO behavioural change to any test.

**Files modified (project artifacts):**
- `_bmad-output/implementation-artifacts/deferred-work.md` — Story-2.4 deferral updates (Task 8 / Sub 8.1..8.5): exline_command_table structural-ASSERTs resolution-or-redeferral; init_teardown stub refactor RESOLVED; W3 (cmd_edit_common factoring) update; new Story-2.4 deferrals section.

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md] lines 991-1044
- Previous story (Story 2.3 launch path — established filename_buffer preservation contract this story's `:w` depends on): [Source: _bmad-output/implementation-artifacts/2-3-launch-with-filename-argument.md]
- Earlier story (Story 2.2 — fileio.asm substrate, BDOS error funnel widening, bdos_error_pre_msg, fileio_compose_cant_open template): [Source: _bmad-output/implementation-artifacts/2-2-file-load-via-e-filename-incl-e.md]
- Earlier story (Story 2.1 — exline_command_table, cmd_quit / cmd_quit_force templates for cmd_write / cmd_write_quit): [Source: _bmad-output/implementation-artifacts/2-1-ex-command-line-infrastructure-q-q.md]
- FR1 (Launch with no args — Story 2.4 closes the "save creates the file" half): [Source: _bmad-output/planning-artifacts/prd.md] lines 696-697
- FR4 (Save to current filename): [Source: _bmad-output/planning-artifacts/prd.md] lines 696-697
- FR5 (Save-as `:w filename`): [Source: _bmad-output/planning-artifacts/prd.md] lines 698-699
- FR7 (`:wq` save-and-quit): [Source: _bmad-output/planning-artifacts/prd.md] lines 702
- FR9 (Bare filename → drive B:): [Source: _bmad-output/planning-artifacts/prd.md] line 705
- FR10 (Explicit drive prefix): [Source: _bmad-output/planning-artifacts/prd.md] lines 706-707
- FR51 (I/O failure surfacing): [Source: _bmad-output/planning-artifacts/prd.md] lines 793-797
- FR52 / NFR6 (No silent data loss): [Source: _bmad-output/planning-artifacts/prd.md] lines 799-802, 833-839
- NFR9 (code budget — overshoot deepens; amend pending in deferred-work.md): [Source: _bmad-output/planning-artifacts/prd.md] lines 848-851
- NFR14 (sjasmplus 1.23.0): [Source: _bmad-output/planning-artifacts/prd.md] lines 870-871
- NFR15 (CP/M 2.2 BDOS only): [Source: _bmad-output/planning-artifacts/prd.md] lines 872-874
- NFR18 (reproducible build): [Source: _bmad-output/planning-artifacts/prd.md] lines 886-887
- PRD save-flow design (BDOS function-22 MAKE, gap-walk in two halves, 0x1A pad, direct unsafe write): [Source: _bmad-output/planning-artifacts/prd.md] lines 544-553
- Architecture cross-cutting save-side concerns (single status funnel, BDOS return-code discipline): [Source: _bmad-output/planning-artifacts/architecture.md] lines 125-167
- AR12 / MC5 (status-message funnel): [Source: _bmad-output/planning-artifacts/architecture.md] lines 535-541
- AR13 (single screen-emission path): [Source: _bmad-output/planning-artifacts/architecture.md] (boundary properties section)
- AR14 (single buffer-mutation owner — save is read-only against gap; no new carve-out): [Source: _bmad-output/planning-artifacts/architecture.md] (boundary properties section)
- AR15 / MC6 (single BDOS gateway — Story 2.4 adds the SECOND carve-out for benign DELETE): [Source: _bmad-output/planning-artifacts/architecture.md] lines 543-548
- AR16 (status-message string convention — `can't write <filename>` form): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1003-1037
- AR22 (naming): [Source: _bmad-output/planning-artifacts/architecture.md] lines 788-850
- AR23 (file structure and routine contracts): [Source: _bmad-output/planning-artifacts/architecture.md] lines 852-916
- AR25 (module include order — unchanged by Story 2.4): [Source: _bmad-output/planning-artifacts/architecture.md] lines 940-956
- BH5 (`:q` dirty refusal pattern — the Story-2.1 template for `cmd_write_quit`'s missing-filename refusal): [Source: _bmad-output/planning-artifacts/architecture.md] lines 699-702
- BH6 (`:e` dirty refusal — not directly applicable to `:w`; `:w` doesn't have a "dirty refusal" path because saving IS the resolution of dirtiness): [Source: _bmad-output/planning-artifacts/architecture.md] lines 704-706
- Module Dependency Graph (exline → fileio → BDOS; init → fileio → BDOS for launch; new path: exline → fileio_save → BDOS_DELETE / MAKE / WRITE_SEQ / CLOSE): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1401-1452
- FR↔Module mapping (FR4 / FR5 / FR7 → exline.asm + fileio.asm): [Source: _bmad-output/planning-artifacts/architecture.md] line 1515
- inc/state.inc (filename_buffer; buffer_dirty; gap_start / gap_end): [Source: inc/state.inc]
- inc/equates.inc (FILENAME_BUFFER_SIZE = 16; GAP_BUFFER_MAX = 32768; STATUS_LINE_WIDTH = SCREEN_COLS): [Source: inc/equates.inc] lines 31, 41, 51
- inc/bios.inc (DEFAULT_FCB = 0x005C, DEFAULT_DMA = 0x0080, BDOS_ENTRY = 0x0005): [Source: inc/bios.inc] lines 63-65
- inc/bdos.inc (BDOS_DELETE = 19, BDOS_CLOSE = 16, BDOS_WRITE_SEQ = 21, BDOS_MAKE = 22, BDOS_SET_DMA = 26; BDOS_CALL macro contract): [Source: inc/bdos.inc] lines 35-88
- src/fileio.asm (fileio_load + fileio_load_initial + parse + compose + abort helpers — Story 2.4's substrate): [Source: src/fileio.asm]
- src/exline.asm (cmd_edit / cmd_edit_force templates for cmd_write / cmd_write_quit): [Source: src/exline.asm] lines 625-679
- src/statusln.asm (bdos_error_funnel + bdos_error_pre_msg override + inline ex-line cleanup — save's failure path): [Source: src/statusln.asm] lines 167-195, 244-250
- src/init.asm (init_teardown — cmd_write_quit's tail-JP target on save success): [Source: src/init.asm] lines 396-413
- src/vibe.asm (AR25 INCLUDE chain — unchanged by 2.4): [Source: src/vibe.asm]
- test/Makefile (fixture rules — extend `clean:` recipe per Sub 6.7): [Source: test/Makefile]
- test/inc/test_input_loop_stub.inc (sentinel-set stub for funnel-routing tests): [Source: test/inc/test_input_loop_stub.inc]
- Deferred-work entry for `init_teardown` stub refactor (RESOLVED by Story 2.4 Task 5): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 103-104, 118
- Deferred-work entry for `exline_command_table` structural ASSERTs (RESOLVED-or-RE-DEFERRED per Sub 8.1): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 105-106
- Deferred-work entry for `cmd_edit_common` factoring (W3 — RESOLVED-or-RE-DEFERRED per Sub 8.3): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 125
- Deferred-work entry for NFR9 amend (UPDATED per Sub 8.5 — Story 2.4 deepens the overshoot): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 122
- Deferred-work entry for AR15 carve-outs in architecture.md (now TWO carve-outs in fileio.asm — even more justified): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 139
- Deferred-work entry for W8 bdos_error_pre_msg stale-pointer invariant (Story 2.4 introduces a second writer): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 130-131

## Dev Agent Record

### Agent Model Used

claude-opus-4-7 (Opus 4.7)

### Debug Log References

**Build verification (AC13).** `make clean && make` succeeded byte-identically twice in succession:
- SHA-256: `48c22fbd1e86966999bb9f341f1af6e79c62739014f3e743678c698e9bd64a37` (run 1)
- SHA-256: `48c22fbd1e86966999bb9f341f1af6e79c62739014f3e743678c698e9bd64a37` (run 2)

NFR18 reproducibility holds.

**Size (`make sizes`).** `code_section: 3649 bytes (~118% of NFR9 ~3 KB budget)`. Delta vs Story 2.3's 3235 B: **+414 B** (above the spec's projected +280-360 B range; the per-byte gap-walk loop in `fileio_save_walk_bytes` was costlier than an LDIR-fragment design would have been). Still BELOW the proposed 4096 B amended NFR9 ceiling — 447 B of headroom remaining. NFR9 amend follow-up logged in deferred-work.md (line 122 escalation).

**Headless test count (AC13 Sub 7.5).** `45 pass + 1 deliberate fail` (was 41 pass + 1 fail post-2.3; +4 new fileio_save tests; the deliberate fail is `harness_fail` per the existing harness contract).

**AR enforcement sweeps (AC13 Sub 7.4) — all pass:**
- AR13 `grep -nE 'BIOS_CONOUT' src/ | grep -v 'render.asm'`: comment-only matches in exline.asm:19 + fileio.asm:47 + bios_1_7.inc:65 (vendor reference, not vibe production).
- AR14 `grep -nE 'gapbuf_(insert|delete|move_gap|load|init)' src/fileio.asm`: gapbuf_init at the existing :e / launch / abort sites and gapbuf_move_gap at fileio_load_after_open's Step 9. NO new gap-mutation sites in fileio_save — the save's gap-walk is READ-ONLY against the gap regions.
- AR14 `grep -nE 'LD[ \t]+\(gap_start\)' src/fileio.asm`: TWO matches at the existing Story-2.2 AR14 carve-out sites in fileio_ingest_sector — both annotated. NO new write-to-gap_start sites in fileio_save.
- AR15 `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/fileio.asm`: TWO matches — line 518 (Story 2.4 SAVE carve-out for inline BDOS_DELETE in fileio_save) and line 822 (Story 2.3 LAUNCH carve-out for inline BDOS_OPEN in fileio_load_initial); both annotated with their carve-out comments. The module header's AR15 sub-bullet enumerates BOTH carve-outs with parallel rationale.
- BDOS_CALL in fileio.asm: multiple matches across the load (BDOS_OPEN / SET_DMA / READ_SEQ / CLOSE) and save (BDOS_MAKE / SET_DMA / WRITE_SEQ / CLOSE) clusters. All sign-bit-routing calls in the save flow use the macro.
- bdos_error_pre_msg: TWO writer sites in fileio.asm now — fileio_load Step 3 (pre-stage cant_open, clear at Step 5) + fileio_save Step 1 (pre-stage cant_write, clear at Step 9). The funnel zeroes post-emit. fileio_save_flush_sector's `.write_abort` defensively re-stages before JP funnel.
- `BDOS_DELETE|BDOS_MAKE|BDOS_WRITE_SEQ` in src/: scoped to fileio.asm only (+ an exline.asm comment reference). New BDOS surface correctly contained.

**Write-protect test substitution (AC12 Sub 6.4 → fileio_save-make-failure.asm).** Mechanism A (chmod 0444) and Mechanism B (FCB ext-char-0 high bit) both failed to fire the funnel under iz-cpm (probed empirically: A → DELETE / MAKE both 0x00; B → DELETE 0xFF but MAKE 0x00, completing a green save). Per AC12 Sub 6.8 the dev option was Mechanism C (defer to hardware UAT). Substituted Mechanism D: address an unmounted drive (`D:NODISK.TXT`) so BDOS_MAKE returns 0xFF (drive offline). Test renamed `fileio_save-make-failure.asm` to reflect the substitution honestly; pins the same funnel routing + "can't write FILENAME" banner + FR52 buffer_dirty preservation a true R/O test would. Logged in deferred-work.md.

**iz-cpm stderr workaround.** iz-cpm prints `Bdos Err On D: Bad Sector` to stderr (via the harness's `2>&1`) WITHOUT a trailing newline; the test_epilogue's `PASS$` token would otherwise concatenate as `…SectorPASS`, failing the harness's `\bPASS\b` grep. `fileio_save-make-failure.asm` emits a CR/LF via BDOS print-string before `JP test_pass` so PASS lands on a fresh line. Workaround is test-local and harmless.

**Hardware UAT (AC14, Task 9).** Executed by Ant 2026-05-14. All 13 AC14 steps pass on real MicroBeast hardware post-fix iteration (see below). Steps 1-11 + 13 passed first try; step 12 (write-protect with STAT-R/O) initially surfaced a CP/M 2.2 BDOS R/O-write intercept that warm-booted the program before our funnel saw the failure — fixed in-story via the Step 0 R/O pre-check; retry confirmed clean refusal banner + buffer preservation.

**Hardware UAT fix iteration (2026-05-14, post-review).** AC14 step 12 hardware UAT report from Ant: STAT-marked R/O file caused `Bdos Err On B: File R/O` + warm-boot back to CCP. Real CP/M 2.2 BDOS intercepts R/O writes BEFORE returning to caller; our macro funnel is unreachable on that path; unsaved buffer content is lost to the warm-boot. FR52 / NFR6 violated. Fix: added Step 0 R/O pre-check to `fileio_save` — SET_DMA + AR15 SAVE-PRECHECK CARVE-OUT (inline BDOS_SEARCH_FIRST with FCB ext-char-0 high bit temporarily set; under real CP/M 2.2 this query matches only R/O directory entries) + DMA byte-9 high-bit inspection (defends against iz-cpm-style lenient attribute-bit filtering) + clean refusal via `fileio_compose_cant_write` + `status_set_message` tail-JP. Three AR15 carve-outs now documented in fileio.asm: launch / save-precheck / save — module-header AR15 sub-bullet enumerates all three. New build SHA: `5a0e86381209f8b6dc8870998157d29949732d437b2e6934aafbb5851a28ad83` (byte-identical across two clean builds — NFR18 holds). Size: 3714 B (was 3649 B; +65 B for the pre-check; still 382 B under proposed 4096 B amended NFR9 ceiling). 45 pass + 1 deliberate fail unchanged — the pre-check is effectively a no-op under iz-cpm because iz-cpm strips R/O attribute bits in all probed paths (MAKE / SEARCH_FIRST / OPEN / BDOS fn 30 — confirmed empirically). Headless R/O coverage gap remains; hardware UAT step 12 retry is the validator. Logged in deferred-work.md as a separate "AC14 step 12 hardware UAT fix" entry.

### Completion Notes List

**Tasks 1-8: complete. Task 9 (hardware UAT) deferred to user.**

- Task 1 — `fileio_compose_cant_write` + `fileio_msg_cant_write_prefix` added to fileio.asm, mirroring fileio_compose_cant_open's structure. AR23 contract block per AC9.
- Task 2 — `fileio_compose_loaded_status` refactored to load its private `fileio_msg_bytes_suffix` into DE and JP into the new shared body `fileio_compose_filename_count_suffix`. New `fileio_compose_written_status` mirrors the same shape with `fileio_msg_bytes_written_suffix`. Story-2.2 fileio_load tests pass byte-equivalently post-refactor.
- Task 3 — `fileio_save` public entry orchestrates AC4's 11 numbered steps; AR15 SAVE CARVE-OUT inlines BDOS_DELETE per AC5 with the inline `; AR15 save carve-out` annotation. The gap-walk uses `fileio_save_walk_bytes` (per-byte src → DMA copy with sector flush on DMA fill) and `fileio_save_flush_sector` (BDOS_WRITE_SEQ + non-sign-bit A check + dma_ptr/remain reset, or funnel-JP on error). EOF-pad fills remaining DMA slots with 0x1A then spaces (the empty-buffer case writes one sector of 0x1A + 127 spaces; the 128-byte exact-fill case writes 2 sectors per the spec's "always emit EOF" rule). Module-local cells `fileio_write_count` / `fileio_save_dma_ptr` / `fileio_save_dma_remain` added to the data block.
- Task 4 — `cmd_write` / `cmd_write_quit` / `cmd_save_strlen_filename_buffer` added to exline.asm; `exline_command_table` grew from 4 to 6 entries (`e`, `e!`, `w`, `wq`, `q`, `q!`). The two handlers share ~80% of their bodies but are intentionally NOT factored into a shared `cmd_save_common` helper — the CALL/RET + contract complexity didn't beat inline duplication on the byte budget (logged in deferred-work as a future code-shrink opportunity alongside W3's cmd_edit_common factoring).
- Task 5 — `test/inc/test_teardown_stub.inc` created and substituted into all 28 pre-existing test files via a Python batch (the 18 exline / fileio / init tests with the full sentinel stub plus the 10 dispatch / parser tests with the minimal `RET` stub; the latter gain a harmless +5 B sentinel cell). The 4 new Story 2.4 fileio_save tests INCLUDE the stub. Deferred-work line 118 marked RESOLVED.
- Task 6 — 4 new headless tests added: `fileio_save-roundtrip.asm` (13-byte payload, save → reload, byte-identical content); `fileio_save-empty-buffer.asm` (0-byte payload, in-test BDOS_OPEN/READ_SEQ verifies on-disk sector = 0x1A + 127 spaces); `fileio_save-1A-padding.asm` (100-byte payload, in-test verifies bytes 0..99 = 'A', byte 100 = 0x1A, bytes 101..127 = 0x20); `fileio_save-make-failure.asm` (Mechanism-D unmounted-drive proxy for write-protect; pins funnel routing + "can't write" banner + FR52 buffer_dirty preservation). All four pass under iz-cpm. test/Makefile clean target extended for the 4 output files.
- Task 7 — Two consecutive `make clean && make` runs produced byte-identical vibe.com (NFR18). Size 3649 B (+414 B vs Story 2.3 baseline; below proposed 4096 B amended ceiling). All AR grep sweeps clean. `make test` reports 45 pass + 1 deliberate fail.
- Task 8 — deferred-work.md updated: line 105 (table ASSERTs) re-deferred with Story-2.4 context; line 118 (init_teardown stub) marked RESOLVED; line 122 (NFR9 amend) escalated; line 125 (W3 cmd_edit_common) re-deferred with cmd_save_common context; line 139 (architecture.md carve-out docs) escalated to TWO AR15 carve-outs; new "Deferred from: dev of story-2-4-..." section added with 6 new entries.
- Task 9 — Hardware UAT executed by Ant 2026-05-14. All 13 AC14 steps pass on real MicroBeast. Step 12 initially surfaced a real FR52 / NFR6 violation (CP/M 2.2 BDOS R/O-write intercept warm-boots before our funnel sees the failure); fixed via Step 0 R/O pre-check (see Change Log entry 2026-05-14). Post-fix step 12 retry confirmed clean refusal + buffer preservation.

**Spec deviations (logged in deferred-work):**

1. AC12 Sub 6.4 test rename: `fileio_save-write-protect.asm` → `fileio_save-make-failure.asm` (Mechanism D unmounted-drive proxy; iz-cpm R/O mechanism probes documented).
2. AC4 Sub 4.3 `cmd_save_common` factoring: declined under NFR9 pressure (logged as future code-shrink opportunity).
3. AC15 `init_teardown` stub promotion: substituted into 28 files (not the spec's "~21"); the spec's count missed the 10 dispatch / parser tests that Story 2.3's regression net touched.

**NFR9 footprint:** 3649 B / ~118% of original 3072 B ceiling / ~89% of proposed 4096 B amended ceiling. The NFR9 amend (deferred-work line 122) is more urgent than ever; flagged for Story 2.5 planning.

### File List

**Files created:**
- `test/inc/test_teardown_stub.inc` (Task 5)
- `test/cases/fileio_save-roundtrip.asm` (Task 6)
- `test/cases/fileio_save-empty-buffer.asm` (Task 6)
- `test/cases/fileio_save-1A-padding.asm` (Task 6)
- `test/cases/fileio_save-make-failure.asm` (Task 6; renamed from spec's `fileio_save-write-protect.asm` per Mechanism-D substitution — logged in deferred-work)

**Files modified (production):**
- `src/fileio.asm` — Tasks 1, 2, 3: added `fileio_save` (public entry) + `fileio_save_walk_bytes` + `fileio_save_flush_sector` (internal helpers) + `fileio_compose_cant_write` + `fileio_compose_written_status` + `fileio_compose_filename_count_suffix` (shared body for the loaded / written composers) + `fileio_msg_cant_write_prefix` + `fileio_msg_bytes_suffix` (renamed from the dotted-local `.suffix` to a module-level DEFB) + `fileio_msg_bytes_written_suffix` + module-local cells `fileio_write_count` / `fileio_save_dma_ptr` / `fileio_save_dma_remain`. Refactored `fileio_compose_loaded_status` to load its private bytes suffix into DE and JP into the shared body. Updated the AR23 module-header `Purpose:` / `Public:` / `State owned (read/write):` / register conventions / `Dependencies:` blocks; the `Architectural enforcement here` AR15 sub-bullet now enumerates THREE carve-outs (launch + save-precheck + save) with parallel rationale. Step 0 R/O pre-check (AC14-step-12 fix, 2026-05-14) added to `fileio_save` — SET_DMA + AR15 save-precheck carve-out (inline BDOS_SEARCH_FIRST) + DMA byte-9 high-bit inspection + clean refusal via fileio_compose_cant_write + status_set_message tail-JP. Honors FR52 / NFR6 on real CP/M 2.2 STAT-R/O files (CP/M 2.2 BDOS intercepts R/O writes pre-return and warm-boots; pre-check is the only headless-uncoverable way to honor "no silent data loss").
- `inc/bdos.inc` — added `BDOS_SEARCH_FIRST EQU 17` (AC14-step-12 fix, 2026-05-14) for the new R/O pre-check.
- `src/exline.asm` — Task 4: added `cmd_write` + `cmd_write_quit` + `cmd_save_strlen_filename_buffer` (internal helper); extended `exline_command_table` from 4 to 6 entries. Updated the AR23 module-header `Public:` list, `Dependencies:` (adds FILENAME_BUFFER_SIZE + fileio_save / fileio_parse_filename references), AR14 / AR15 enforcement comments (cmd_write_quit's init_teardown tail-JP; cmd_write / cmd_write_quit's fileio_save CALL).

**Files modified (test infrastructure):**
- `test/Makefile` — `clean:` recipe extended to `rm -f` the 4 save-test output files in `fixtures/`.
- 28 existing test files — inline `init_teardown:` blocks replaced with `INCLUDE "../inc/test_teardown_stub.inc"`. NO behavioural change to any test.

**Files modified (project artifacts):**
- `_bmad-output/implementation-artifacts/deferred-work.md` — 5 existing entries updated (lines 105 / 118 / 122 / 125 / 139); new "Deferred from: dev of story-2-4-..." section appended (6 entries).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — Story 2.4 development_status flipped ready-for-dev → in-progress → review across the dev pass; one narrative `# last_updated:` comment added at the top of the file.
- `_bmad-output/implementation-artifacts/2-4-file-save-w-w-filename-wq.md` — Status flipped ready-for-dev → review; Tasks/Subtasks checkboxes marked [x] (less Task 9's hardware UAT, left [ ] for user execution); Dev Agent Record / File List / Change Log populated.

### Change Log

| Date       | Change |
|------------|--------|
| 2026-05-13 | Story 2.4 dev complete (less hardware UAT). 4 new headless tests; 2 production modules and 28 test files modified; 1 new shared test stub; deferred-work updates. Byte-identical reproducible build (SHA `48c22fbd1e86966999bb9f341f1af6e79c62739014f3e743678c698e9bd64a37`); 45 pass + 1 deliberate fail under iz-cpm; size 3649 B (118% original NFR9, 89% proposed 4096 B amended ceiling). |
| 2026-05-14 | AC14 hardware UAT step 12 fix: added Step 0 R/O pre-check to `fileio_save` (AR15 save-precheck carve-out — inline BDOS_SEARCH_FIRST + DMA byte-9 high-bit inspection) so CP/M 2.2's R/O-write BDOS intercept doesn't warm-boot the program with unsaved buffer content (FR52 / NFR6). New BDOS_SEARCH_FIRST EQU in inc/bdos.inc. fileio.asm's AR15 sub-bullet now enumerates THREE carve-outs (launch / save-precheck / save). Build SHA `5a0e86381209f8b6dc8870998157d29949732d437b2e6934aafbb5851a28ad83`; size 3714 B (+65 B; still 382 B under proposed 4096 B ceiling); 45 pass + 1 deliberate fail unchanged. Headless R/O coverage gap remains (iz-cpm strips R/O attributes everywhere); hardware UAT step 12 retry is the validator. |
