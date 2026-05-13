# Story 2.3: Launch with filename argument

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `vibe foo.fs` from CCP to launch directly into the loaded file (with `[new file]` semantics when the name doesn't exist on disk so I can `:w` it into being, and oversize-refusal symmetry with `:e`),
So that Journey 1a ("vibe game.fs and start typing") is realized in one keystroke from CCP, the default-FCB at 0x005C populated by CCP becomes the same load surface as `:e`, and Story 2.4's `:w` will have a filename to save to even when the user opened a name that didn't yet exist.

## Acceptance Criteria

**AC1 — `fileio_load_initial` is the new public launch entry in `src/fileio.asm`.**

**Given** the parsed default FCB at `DEFAULT_FCB` (= 0x005C in `inc/bios.inc`) populated by CCP at .com entry:
  - `DEFAULT_FCB + 0` = drive byte (0 = "default drive — no prefix", 1 = A:, 2 = B:, …)
  - `DEFAULT_FCB + 1..8` = 8-byte basename (CCP space-padded, uppercase)
  - `DEFAULT_FCB + 9..11` = 3-byte extension (CCP space-padded, uppercase)
  - `DEFAULT_FCB + 12..35` = extent, S1, S2, record count, allocation map, current record (all zero at .com entry; CCP does not populate these for the launch FCB)

**When** I inspect `src/fileio.asm` post-Story 2.3
**Then** a new public entry `fileio_load_initial` exists with contract:
  - In: (none — reads `DEFAULT_FCB` and the running gap-buffer state)
  - Out: one of four terminal states (all RET — see AC2 / AC3 / AC4 / AC5):
    1. **no-arg** — no filename in the FCB; gap buffer untouched (already empty post `gapbuf_init`); `filename_buffer[0] = 0`; status row composed via `msg_mode_normal` (empty banner; AR16 pad-to-width).
    2. **load-success** — file loaded; cursor=0; filename_buffer populated; status row = `"<FILENAME> N bytes"`.
    3. **new-file** — open failed (file does not exist on the resolved drive); gap buffer empty; filename_buffer populated; status row = `"<FILENAME> [new file]"`; `buffer_dirty = 0`.
    4. **too-large / read-error** — same path as `:e`'s `fileio_abort_too_large` / `fileio_abort_read_error`: buffer reset, `filename_buffer[0] = 0`, status row = `msg_file_too_large` / `msg_read_error`.
  - Trashes: A, BC, DE, HL, F.

**Note — no-funnel discipline.** Unlike `fileio_load`, `fileio_load_initial` MUST NOT route open-failure through the BDOS error funnel. The funnel's terminal `JP input_loop` (statusln.asm Story-2.2 body) would bypass `init_cold_start`'s remaining stages (Stage 6 render_full; Stage 7 fall-through to input_loop), corrupting cold-start sequencing. AC7 details the localised AR15 launch carve-out that achieves this without disturbing the production funnel.

**AC2 — Empty-arg path: `DEFAULT_FCB + 1 == ' '` short-circuits to the empty-status path.**

**Given** `DEFAULT_FCB + 1` (the first basename byte) is `0x20` (space) — CCP's "no filename argument" encoding (CP/M 2.2 CCP space-pads the basename when no arg is present)
**When** `fileio_load_initial` runs
**Then** the routine SHORT-CIRCUITS before any FCB-to-fcb_scratch copy:
  - Gap buffer untouched (already at SR2-empty from `init_cold_start`'s Stage 3 `gapbuf_init`).
  - `filename_buffer` untouched (already zero from Stage 1 LDIR fill — `filename_buffer[0] = 0` is the post-condition).
  - Status row composed via `LD HL, msg_mode_normal ; XOR A ; CALL status_set_message` — same semantics as the Story-1.12 Stage-5 it replaces (empty banner, pad to STATUS_LINE_WIDTH).
  - RET.

**Detection rule rationale.** CCP space-pads the basename when no filename is on the command tail; `DEFAULT_FCB + 1 == ' '` is sufficient and matches Story 2.2's `fileio_parse_filename` "all-space basename" handling. Checking the drive byte alone is INSUFFICIENT (a `vibe` with no arg leaves drive byte 0, but a `vibe a:` with a malformed prefix could leave drive byte 1 with an all-space basename; both must short-circuit). Checking the full 8-byte basename for spaces is more thorough but adds ~12 bytes of code for negligible safety gain — CCP guarantees the space-pad invariant.

**AC3 — Load-success path: parse FCB, populate fcb_scratch + filename_buffer, run the BDOS read loop.**

**Given** `DEFAULT_FCB + 1 != ' '` (CCP delivered a real filename argument)
**When** the read loop completes successfully (every BDOS_READ_SEQ returned 0 until either a 0x1A byte was seen in a sector or BDOS_READ_SEQ returned A=1 for clean EOF)
**Then** post-load state matches Story 2.2's `:e` semantics (AC5 of Story 2.2):
  - `cursor_offset = 0` (the `gapbuf_move_gap` to 0 then explicit write).
  - `gap_start = GAP_BUFFER_BASE` (post `move_gap(0)`).
  - `gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX - bytes_loaded`.
  - `buffer_dirty = 0`.
  - `filename_buffer` = canonical display form (`"B:HELLO.TXT\0"` for `vibe hello.txt`; `"A:FOO.FS\0"` for `vibe a:foo.fs`).
  - Status row = `"<FILENAME> N bytes"` (e.g., `"B:HELLO.TXT 13 bytes"`).
  - All editable rows dirty (`render_mark_all_dirty` called; `render_full` at Stage 6 picks up the now-loaded buffer).

**Implementation note — share the post-open body with `fileio_load`.** Steps 6-12 of Story 2.2's `fileio_load` (BDOS_SET_DMA → read loop → BDOS_CLOSE → gapbuf_move_gap(0) → cursor/dirty/render reset → compose_loaded_status → status_set_message) are identical in the launch case. Factor as `fileio_load_after_open` — see AC8. Both `fileio_load` and `fileio_load_initial` `JR` / `CALL` into this shared tail after their respective open paths complete.

**AC4 — New-file path: BDOS_OPEN returns 0xFF; filename_buffer is PRESERVED.**

**Given** `vibe missing.fs` where `B:MISSING.FS` does not exist on disk
**When** the launch flow's BDOS_OPEN returns 0xFF (file-not-found)
**Then** `fileio_load_initial` takes the NEW-FILE branch (NOT the funnel; AC7):
  - **filename_buffer is preserved** with the canonical display form `"B:MISSING.FS\0"` (set by the pre-open parse). This is the key divergence from `:e missing.fs`, where `bdos_error_funnel` surfaces `"can't open B:MISSING.FS"` and the filename is treated as transient.
  - Gap buffer is at the SR2-empty state set by `gapbuf_init` (called before the open attempt — see AC9 Step 2).
  - `buffer_dirty = 0`.
  - Status row composed dynamically as `"<FILENAME> [new file]"` (e.g., `"B:MISSING.FS [new file]"`) via a new helper `fileio_compose_new_file_status` (see AC10).
  - `render_mark_all_dirty` called so the (empty) buffer paints on Stage 6.
  - RET.

**Rationale.** Per the story narrative ("`:w` will create the file"), the user's intent in `vibe missing.fs` is to start a new file with that name. Stashing the parsed filename in `filename_buffer` means Story 2.4's bare `:w` (no arg) saves to `B:MISSING.FS` without the user re-typing the name. The vi convention `[new file]` annotation in the status row signals the not-yet-on-disk state.

**Decision: AR16 case for `[new file]`.** The suffix is bracketed-lowercase per vi convention. Final form: `" [new file]"` — leading space (separator from filename), open bracket, lowercase text, close bracket. No trailing period (AR16). Stored as `fileio_msg_new_file_suffix: DEFB " [new file]", 0` in fileio.asm's module-local data block, parallel to Story 2.2's `fileio_msg_cant_open_prefix`.

**AC5 — Too-large path: oversize file aborts; filename_buffer is CLEARED.**

**Given** `vibe big.bin` where `big.bin` exceeds `GAP_BUFFER_MAX` (32768 bytes)
**When** the read loop's pre-read budget check (`free < 128`) fires after 256 sectors
**Then** `fileio_load_initial` takes the SAME path as `:e big.bin`'s oversize abort:
  - `fileio_abort_too_large` (Story 2.2; close + gapbuf_init + buffer_dirty=0 + `filename_buffer[0] = 0` + render_mark_all_dirty + status_set_message msg_file_too_large) runs unchanged.
  - The launch FCB's parsed filename is DISCARDED (cleared from filename_buffer): rationale parallels `:e`'s — leaving a stale name in the buffer + an empty gap means a subsequent `:w` would silently overwrite the on-disk file (which the user just tried to load and could not). FR52 / NFR6 ("no silent data loss") dictates the clear.
  - RET.

**AC6 — Read-error path: mid-load BDOS_READ_SEQ rc >= 2 aborts; same as `:e`.**

**Given** a CP/M-conformant BDOS that returns `A >= 2` from `BDOS_READ_SEQ` mid-read (rare; e.g., a corrupt directory entry surfaces this way on some BIOSes)
**When** the read loop sees A >= 2 after a `BDOS_READ_SEQ`
**Then** `fileio_load_initial` takes the SAME path as `:e`'s read-error abort: `fileio_abort_read_error` (Story 2.2; close + gapbuf_init + filename clear + msg_read_error). Filename CLEARED (same FR52 / NFR6 reasoning as AC5).

**AC7 — AR15 launch carve-out: BDOS_OPEN bypasses the funnel for the launch path.**

**Given** Story 2.2's `BDOS_CALL` macro routes sign-bit returns through `bdos_error_funnel` which terminally `JP input_loop`s
**When** `fileio_load_initial` calls BDOS_OPEN
**Then** the launch path's open MUST NOT enter the funnel (per AC1 note: the JP-to-input_loop would skip `init_cold_start`'s Stage 6 / Stage 7). The launch carve-out uses an INLINE BDOS sequence (not the macro):

```asm
    ;; AR15 launch carve-out: inline BDOS_OPEN check.
    ;; bdos_error_funnel's terminal `JP input_loop` would bypass
    ;; init_cold_start's Stage 6 (render_full) and Stage 7
    ;; (fall-through to input_loop). The launch path needs to RET
    ;; through fileio_load_initial back to init_cold_start so the
    ;; remaining stages run, regardless of whether the open
    ;; succeeded (load-success) or failed (new-file).
    LD      C, BDOS_OPEN
    LD      DE, fcb_scratch
    CALL    BDOS_ENTRY
    OR      A
    JP      M, .new_file        ; A.bit7 = 1 -> file not found
    ;; A = 0..3 -> open succeeded; fall through to shared post-open.
```

**Documenting the carve-out.** Add to `src/fileio.asm`'s AR23 header block a new "Architectural enforcement here" sub-bullet documenting the AR15 launch carve-out at this single call site. Mirror the AR14 carve-out's annotation style (Story 2.2). Specifically:

```
;            AR15 — every BDOS call in this module uses the
;                   BDOS_CALL macro EXCEPT one site: the
;                   `fileio_load_initial` BDOS_OPEN is inlined
;                   (LD C / CALL BDOS_ENTRY / OR A / JP M) so the
;                   funnel's terminal JP-to-input_loop does NOT
;                   fire on open-fail. The launch path needs to
;                   surface a "[new file]" banner and RET back to
;                   init_cold_start; the funnel would skip the
;                   remaining cold-start stages.
```

**AR15 enforcement greps need updating** (AC15): the existing `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/fileio.asm` will newly match one site. Annotate the match with an inline `; AR15 launch carve-out` comment (mirrors the AR14 inline annotation on `LD (gap_start), DE` in `fileio_ingest_sector`). The grep sweep tolerates the annotated match.

**AC8 — Shared `fileio_load_after_open` body factored out of `fileio_load`.**

**Given** Story 2.2's `fileio_load` has Steps 6-12 (BDOS_SET_DMA → read loop → BDOS_CLOSE → gapbuf_move_gap(0) → cursor/dirty/render reset → compose_loaded_status → status_set_message) inline in the routine body
**When** Story 2.3 refactors fileio.asm
**Then** Steps 6-12 are extracted as an internal label `fileio_load_after_open` (NOT a CALL-able subroutine; control transfers via `JR` from the open-success branches and RETs at the end of the success path). Specifically:

  - `fileio_load`'s body becomes:
    1. Step 1: parse_filename
    2. Step 2: gapbuf_init
    3. Step 3: compose_cant_open + pre-stage bdos_error_pre_msg
    4. Step 4: BDOS_CALL BDOS_OPEN (funnel routing intact for `:e` semantics)
    5. Step 5: clear bdos_error_pre_msg (open succeeded)
    6. `JR fileio_load_after_open` (or fall through if labelled directly)
  - `fileio_load_after_open:` body is Steps 6-12 of Story 2.2's fileio_load, unchanged in behaviour.
  - `fileio_load_initial`'s success branch falls through (or `JR`s) to the same `fileio_load_after_open`.

**Behavioural-equivalence guarantee.** The refactor MUST be byte-equivalent (in observable post-state) to Story 2.2's `fileio_load` body. The existing Story 2.2 tests (`fileio_load-small-file.asm`, `fileio_load-with-1A-eof.asm`, `fileio_load-drive-prefix.asm`, `fileio_load-too-large.asm`, plus `fileio_e-bang-force-dirty.asm`, `fileio_e-dirty-refusal.asm`, `fileio_e-missing-filename.asm`) continue to pass unchanged — the refactor is the regression net.

**Note.** This refactor does NOT need a `CALL`/`RET` — a label inside the routine reached via JR-fall-through is enough. The two open paths converge and run the same straight-line code. Spec the implementation with falling-through, not a CALL site, to avoid an unnecessary push/pop.

**AC9 — `fileio_load_initial` orchestrates parse → open-check → branch.**

**Given** the AC1 contract
**When** `fileio_load_initial` runs
**Then** the body sequence is (each step pinned in the implementation):

  1. **No-arg short-circuit.** `LD A, (DEFAULT_FCB + 1) ; CP ' '`; if equal, take the `.no_arg` branch.
  2. **Copy + translate the launch FCB into `fcb_scratch`.** `fileio_setup_from_default_fcb` (new helper, AC11):
     - Copy `DEFAULT_FCB + 0..11` into `fcb_scratch + 0..11` (the drive byte plus the 8-byte basename plus the 3-byte extension). The remaining FCB bytes (`fcb_scratch + 12..35`) are zero from the previous load's `parse_filename` zero-fill (which runs `DEFS 36, 0` semantics each time it's called) — but `fileio_load_initial` does NOT call `parse_filename`. To preserve the invariant that `fcb_scratch + 12..35 == 0` at every BDOS_OPEN, the helper EXPLICITLY zeroes `fcb_scratch + 12..35` after the copy.
     - **Drive byte translation (FR9):** `fcb_scratch + 0 == 0` (CCP "default-drive" sentinel) is rewritten to `fcb_scratch + 0 = 2` (B: per FR9). FR10 explicit prefixes (CCP-encoded as 1 / 2 / 3 / ...) pass through unchanged.
     - **Filename_buffer compose.** Call `fileio_compose_filename_buffer` (new helper extracted from Story 2.2's `parse_filename` tail — AC12).
  3. **gapbuf_init.** Resets gap_start / gap_end / cursor_offset to the SR2-empty state. Idempotent against the already-empty post-Stage-3 state, but the architectural rule (AR14) says all SR2 establishment routes through `gapbuf_init` — we route through it for hygiene, not because the state needs resetting.
  4. **Inline BDOS_OPEN (AR15 launch carve-out — AC7).** `LD C, BDOS_OPEN ; LD DE, fcb_scratch ; CALL BDOS_ENTRY ; OR A ; JP M, .new_file`.
  5. **Open succeeded (A = 0..3).** Fall through (`JR fileio_load_after_open`) to the shared post-open body (AC8). After Steps 6-12 emit the "FILENAME N bytes" status, `fileio_load_after_open` RETs back to `fileio_load_initial`'s caller (`init_cold_start`).
  6. **`.new_file` branch.** `fileio_compose_new_file_status` (AC10) composes `"<FILENAME> [new file]\0"` into `fileio_status_scratch`. `XOR A ; LD (buffer_dirty), A`. `CALL render_mark_all_dirty`. `LD HL, fileio_status_scratch ; XOR A ; JP status_set_message` (tail-JP — `status_set_message`'s RET unwinds back to `fileio_load_initial`'s caller).
  7. **`.no_arg` branch.** `LD HL, msg_mode_normal ; XOR A ; JP status_set_message` (tail-JP — same Stage-5 semantics this routine replaces).

**Stack discipline note.** No PUSH / POP across the open call. Registers A, BC, DE, HL are all trashed by `fileio_setup_from_default_fcb` (it does an LDIR plus the filename_buffer compose); the open call's input (`DE = fcb_scratch`) is set immediately before the inline BDOS sequence; nothing else needs to survive.

**AC10 — `fileio_compose_new_file_status` composes `"<FILENAME> [new file]"`.**

**Given** the new-file path needs a dynamic status string interpolating the parsed filename
**When** I inspect `src/fileio.asm` post-2.3
**Then** a file-local helper `fileio_compose_new_file_status` exists:
  - In: (none — reads `filename_buffer`)
  - Out: `fileio_status_scratch` contains `<filename_buffer NUL-terminated content> + " [new file]" + 0`. HL on return = `fileio_status_scratch` (ready for `status_set_message`).
  - Trashes: A, BC, DE, HL, F.

**Implementation pattern.** Mirror `fileio_compose_loaded_status` but substitute the dynamic decimal-count emit with a static suffix copy:
  1. Copy `filename_buffer` (NUL-terminated, ≤ 15 bytes) into `fileio_status_scratch`, stopping at NUL (do NOT copy the NUL — DE points at where the NUL would go).
  2. Copy `fileio_msg_new_file_suffix` (`" [new file]\0"`) into `fileio_status_scratch` starting at DE, copying through the NUL terminator.
  3. `LD HL, fileio_status_scratch ; RET`.

**Status-scratch capacity check.** Max composed length = 15 (filename) + 11 (" [new file]") + 1 (NUL) = 27 bytes. Within Story 2.2's existing 48-byte `fileio_status_scratch` allocation — the `ASSERT $ - fileio_status_scratch >= 48` tripwire remains unchanged and continues to cover this new compose path.

**Suffix string.** Add `fileio_msg_new_file_suffix: DEFB " [new file]", 0` to fileio.asm's module-local data block, immediately after `fileio_msg_cant_open_prefix`. AR16-compliant (lowercase, no trailing period).

**AC11 — `fileio_setup_from_default_fcb` copies DEFAULT_FCB into `fcb_scratch` with FR9 translation.**

**Given** the launch FCB at `DEFAULT_FCB` (CCP-populated)
**When** `fileio_setup_from_default_fcb` runs
**Then** `fcb_scratch` is populated with:
  - `fcb_scratch + 0` = drive byte (FR9: 0 → 2; other values pass through).
  - `fcb_scratch + 1..8` = basename (copied byte-for-byte from `DEFAULT_FCB + 1..8`; CCP already space-padded uppercase per CP/M 2.2 conventions).
  - `fcb_scratch + 9..11` = extension (copied byte-for-byte from `DEFAULT_FCB + 9..11`; same CCP-uppercase invariant).
  - `fcb_scratch + 12..35` = zero (explicitly zeroed — the prior state may be the residue of a previous `:e` parse).

**And** `filename_buffer` is populated with the canonical display form via a shared helper (AC12).

**Helper contract.**
  - In: (none — reads `DEFAULT_FCB`)
  - Out: `fcb_scratch` + `filename_buffer` populated as above.
  - Trashes: A, BC, DE, HL, F.

**Implementation note.** Use two LDIR runs:
  1. Copy 12 bytes `DEFAULT_FCB → fcb_scratch` (`LD HL, DEFAULT_FCB ; LD DE, fcb_scratch ; LD BC, 12 ; LDIR`).
  2. Zero `fcb_scratch + 12..35` (24 bytes) via the 1-byte-seed-LDIR idiom (`LD HL, fcb_scratch + 12 ; XOR A ; LD (HL), A ; LD DE, fcb_scratch + 13 ; LD BC, 23 ; LDIR`).
  3. FR9 translation: `LD A, (fcb_scratch) ; OR A ; JR NZ, .skip_fr9 ; LD A, 2 ; LD (fcb_scratch), A ; .skip_fr9:`.
  4. `CALL fileio_compose_filename_buffer`.
  5. RET.

**AC12 — `fileio_compose_filename_buffer` extracted from `fileio_parse_filename`'s `.done_parse` tail.**

**Given** Story 2.2's `fileio_parse_filename` ends with a `.done_parse` block that composes `filename_buffer` from `fcb_scratch` (drive letter → `:` → trimmed basename → optional `.<trimmed ext>` → NUL)
**When** Story 2.3 refactors fileio.asm
**Then** that block is extracted as an internal callable helper `fileio_compose_filename_buffer`:
  - In: (none — reads `fcb_scratch`)
  - Out: `filename_buffer` populated with the canonical NUL-terminated display form.
  - Trashes: A, BC, DE, HL, F.

**And** `fileio_parse_filename`'s body ends with `JP fileio_compose_filename_buffer` (tail-JP — `compose`'s RET unwinds back to `parse_filename`'s caller). NO behavioural change; the existing Story 2.2 tests verify the composed `filename_buffer` content survives the refactor unchanged.

**Sharing rationale.** `fileio_load_initial`'s setup path needs to compose `filename_buffer` from `fcb_scratch` WITHOUT going through the text-form parse (it's already in FCB form from CCP). Extracting the compose tail lets both the text-form parse (Story 2.2's `:e`) and the FCB-form launch share one display-name composer.

**AC13 — `init_cold_start` Stage 5 invokes `fileio_load_initial`.**

**Given** Story 1.12's `init_cold_start` has Stage 5 = `LD HL, msg_mode_normal ; XOR A ; CALL status_set_message` (seed `status_dirty` for the first render_full)
**When** Story 2.3 modifies `init.asm`
**Then** Stage 5's body is REPLACED with `CALL fileio_load_initial`. The new helper internally calls `status_set_message` on every path (no-arg / load-success / new-file / too-large / read-error), so `status_dirty` is set by the time `fileio_load_initial` returns. Stages 6 (render_full) and 7 (`JP input_loop`) run unchanged.

**Stage 5 documentation.** Rewrite Stage 5's header comment in init.asm:

```
;   Stage 5: Parse the CCP-populated default FCB at DEFAULT_FCB
;      (0x005C). If no filename argument is present (basename[0]
;      is a space, per CCP space-pad convention), seed the status
;      row with msg_mode_normal — the empty banner that pads to
;      STATUS_LINE_WIDTH (preserves the pre-2.3 cold-start banner).
;      If a filename IS present, fileio_load_initial parses the
;      FCB, attempts BDOS_OPEN, and either: (a) loads the file
;      (success — status = "FILENAME N bytes"); (b) takes the
;      new-file path on open-fail (filename_buffer preserved,
;      status = "FILENAME [new file]", buffer empty); or
;      (c) refuses the load on oversize or read-error (filename
;      cleared, status = "file too large" / "can't read file",
;      buffer empty). All paths RET back here so Stages 6/7
;      complete; the launch flow does NOT route open-fail through
;      bdos_error_funnel (whose terminal JP-to-input_loop would
;      bypass Stages 6/7). See fileio.asm's AR15 launch carve-out.
```

**init.asm Dependencies updated.** Add `src/fileio.asm` (`fileio_load_initial`) to the Dependencies block. The existing `inc/bios.inc` dependency now also covers `DEFAULT_FCB` (already EQUd in bios.inc — no inc/ changes needed).

**AC14 — Hardware UAT smokes `vibe FILENAME` on real MicroBeast.**

**Given** UAT on hardware (Feersum MicroBeast)
**When** I:
  1. `make push` (SLIDE transfer; gated on the Story 1.1 BA4 tooling) and from CCP type `vibe bdos.txt`
  2. Observe: screen renders the file content; status row reads `B:BDOS.TXT N bytes`; mode is NORMAL; cursor at row 0 col 0
  3. Press `:`, type `q`, Enter — observe clean quit to CCP (buffer is clean from the load, so `:q` succeeds)
  4. From CCP type `vibe a:test.fs` (where `test.fs` exists on A:) — observe load from A:; status reads `A:TEST.FS N bytes`
  5. From CCP type `vibe missing.fs` — observe: editor still launches; status reads `B:MISSING.FS [new file]`; buffer empty; cursor at row 0 col 0; mode NORMAL
  6. Press `:`, type `q`, Enter — clean quit (buffer never dirtied, so `:q` is allowed)
  7. From CCP type `vibe huge.fs` (where `huge.fs` is a file > GAP_BUFFER_MAX on B:) — observe: editor still launches; status reads `file too large`; buffer empty; mode NORMAL. **Note:** a >32 KB fixture on B: must exist on the SD card for this step; reuse `test/fixtures/big.bin` (the Story 2.2 fixture) deployed via the test-image pipeline if available. If not, this step is verified headlessly only and the hardware step is skipped (record the skip in Debug Log References).
  8. From CCP type bare `vibe` (no argument) — observe: editor launches with empty buffer + empty status (mode_byte=NORMAL banner per Story 1.9); behaviour identical to Story 1.12's pre-2.3 launch
  9. Press `:`, type `e bdos.txt`, Enter — observe `:e` still works post-2.3 (Story 2.2 regression watch); status reads `B:BDOS.TXT N bytes`
  10. Sustained-typing regression: with the buffer loaded, press `:` then Esc 30 times — observe no terminal corruption (Story 2.1 / 1.12 hardware UAT smokes continue green)

**Then** all observable steps behave as specified, no terminal corruption, no warm-boot from any non-quit step. The launch flow's `init_cold_start` stages 6/7 complete in every case (the launch does NOT short-circuit to input_loop via the BDOS funnel — the AR15 carve-out is the load-bearing change).

**Note on `vibe huge.fs` hardware UAT.** If the test image on the SD card doesn't include a >32 KB file, the hardware step for AC5 is skipped and the headless `init_default-fcb-too-large.asm` test (AC16) is the only coverage. Acceptable trade-off; the same headless-only pattern applies to Story 2.2's AC9 (`big.bin` is generated by `test/Makefile`, not deployed to hardware).

**AC15 — Build invariants and AR enforcement.**

**Given** Story 2.3's source changes
**When** `make clean && make` runs twice consecutively
**Then**:
  - Both runs succeed (NFR14: sjasmplus 1.23.0 pinned via Makefile's `check-toolchain`).
  - The two resulting `vibe.com` files are byte-identical (NFR18 reproducibility). Capture both SHAs in Debug Log References.
  - `make sizes` reports the new code-section size. Capture verbatim. Expected growth: `fileio_load_initial` body (~60-90 B) + `fileio_compose_new_file_status` (~30 B) + `fileio_setup_from_default_fcb` (~50 B) + new suffix DEFB (~13 B) + init.asm Stage 5 swap (-15 B, +5 B net = -10 B) + the helper extractions (net-zero or slight saving from CALL/RET vs inline). **Expected delta: +130-180 B.** Post-2.2 baseline was 3106 B / 101%; expected post-2.3: **3236-3286 B / 105-107%**.

**NFR9 status note (deferred-work.md context).** The NFR9 hard ceiling at 3072 B / 3 KB has already been overshot by Story 2.2 (3106 B), and the resolution pending in deferred-work.md (line 122) is a PRD/architecture amendment raising the ceiling (proposed: 4096 B / 4 KB). Story 2.3 is expected to push deeper into the overshoot. **Action for the dev:** capture the new size verbatim; flag any growth that pushes the footprint past 4096 B (Ant's proposed new ceiling) as a notable observation. Do NOT block the story on NFR9 — the amend-NFR9 follow-up is the load-bearing resolution.

**AR enforcement sweeps (grep against `src/`):**
  - `grep -nE 'BIOS_CONOUT' src/ | grep -v 'render.asm'` — comment matches only (AR13 unchanged from Story 2.2).
  - `grep -nE 'gapbuf_(insert|delete|move_gap|load|init)' src/fileio.asm` — matches `gapbuf_init` (multiple sites: parse + abort + load_initial step 3) and `gapbuf_move_gap` (single site in `fileio_load_after_open`). All AR14-compliant.
  - `grep -nE 'LD[ \t]+\(gap_start\)' src/fileio.asm` — matches the two AR14 carve-out sites in `fileio_ingest_sector`; both bear `; AR14 carve-out` annotations (unchanged from Story 2.2).
  - `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/fileio.asm` — **ONE NEW MATCH** at the AR15 launch carve-out in `fileio_load_initial` (Step 4 of AC9). The match bears an inline `; AR15 launch carve-out` annotation; the module's AR23 header documents the carve-out in its "Architectural enforcement here" block per AC7.
  - `grep -nE 'BDOS_CALL' src/fileio.asm` — multiple matches (unchanged structure; the new launch path's open does NOT use the macro by design).
  - `grep -nE 'DEFAULT_FCB' src/` — matches `src/fileio.asm` (the new launch path's read site) and comment-only references in `src/init.asm` (header-block documentation). No other sites.
  - `grep -nE 'bdos_error_pre_msg' src/` — at least 3 matches (statusln.asm declaration + funnel body; fileio.asm pre-stage + post-OPEN clear). **Specifically check:** `fileio_load_initial` does NOT touch `bdos_error_pre_msg` (the launch path's open does not use the funnel, so the override mechanism is irrelevant; touching it would violate the W8 stale-pointer invariant flagged in deferred-work.md).

**AC16 — Headless tests cover the five launch scenarios.**

**Given** five new headless tests under `test/cases/init_default-fcb-*.asm`
**When** `make test` runs
**Then** the following pass:

  - **`init_default-fcb-no-arg.asm`** — pre-set `DEFAULT_FCB + 1 = 0x20` (space); call `fileio_load_initial`. Assert:
    - `filename_buffer[0] = 0` (unchanged from pre-call zero state).
    - `gap_start = GAP_BUFFER_BASE` (gap empty; the launch path's gapbuf_init in Step 3 of AC9 is NOT reached on the no-arg path — gap state survives from the pre-call `gapbuf_init`).
    - `status_dirty = 1` (status_set_message msg_mode_normal fired).
    - `status_buffer[0] = ' '` (msg_mode_normal is empty → padded with spaces).
    - The test harness pre-sets `DEFAULT_FCB + 0..11` to a deterministic non-zero pattern (e.g., 0xAA fill), then explicitly writes `DEFAULT_FCB + 1 = 0x20` to trigger the short-circuit. The 0xAA fill catches a regression where the short-circuit accidentally copies the FCB into `fcb_scratch` before the check.

  - **`init_default-fcb-loads-file.asm`** — pre-populate `DEFAULT_FCB` with: `+0 = 0` (default drive, FR9 → B:), `+1..+8 = "HELLO   "`, `+9..+11 = "TXT"`, `+12..+35 = 0`. Call `fileio_load_initial`. Assert:
    - `filename_buffer[0..11] = "B:HELLO.TXT" + NUL` (12 bytes incl NUL).
    - `gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX - 13` (the fixture's 13 bytes).
    - `buffer_dirty = 0`.
    - `status_buffer[0..11] = "B:HELLO.TXT "` (prefix; the byte-count digits follow).
    - Use `test/fixtures/hello.txt` (existing — 13 bytes, mounted as both A: and B:).

  - **`init_default-fcb-drive-prefix.asm`** — pre-populate `DEFAULT_FCB`: `+0 = 1` (A:), `+1..+8 = "HELLO   "`, `+9..+11 = "TXT"`, `+12..+35 = 0`. Call `fileio_load_initial`. Assert:
    - `filename_buffer[0..11] = "A:HELLO.TXT" + NUL`.
    - Load completes (status_buffer prefix matches `"A:HELLO.TXT "`).
    - `fcb_scratch + 0 = 1` (FR9 did NOT override an explicit drive).

  - **`init_default-fcb-not-found.asm`** — pre-populate `DEFAULT_FCB` with a filename absent from the fixture B: drive (e.g., `+1..+8 = "NOSUCH  "`, `+9..+11 = "FS "`). Call `fileio_load_initial`. Assert:
    - `filename_buffer[0..11] = "B:NOSUCH.FS" + NUL` (PRESERVED — the new-file divergence from `:e`).
    - `gap_start = GAP_BUFFER_BASE` (buffer empty).
    - `gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX` (gap fully open).
    - `buffer_dirty = 0`.
    - `status_buffer[0..22] = "B:NOSUCH.FS [new file]"` (22 chars).
    - `status_dirty = 1`.
    - **Coverage gap:** the test must verify the function RET'd (did not JP input_loop via funnel). Use the same pattern as Story 2.2's `fileio_load-not-found.asm` — local `input_loop` stub sets a sentinel; assert sentinel is UNTOUCHED post-call.

  - **`init_default-fcb-too-large.asm`** — pre-populate `DEFAULT_FCB` with `+1..+8 = "BIG     "`, `+9..+11 = "BIN"`, against the `test/fixtures/big.bin` 33-KB fixture (Story 2.2). Call `fileio_load_initial`. Assert:
    - `filename_buffer[0] = 0` (CLEARED — same as `:e big.bin` abort).
    - `gap_start = GAP_BUFFER_BASE` (buffer empty post-abort).
    - `buffer_dirty = 0`.
    - `status_buffer[0..13] = "file too large"` (14 chars; msg_file_too_large).

  - Each test follows the AR25-order INCLUDE pattern from Story 2.2's fileio tests:
    1. Pre-ORG production EQU INCLUDEs (equates, bios, bdos, modes, vt52).
    2. `test_prologue.inc` (ORG 0x0100, sentinel pre-zero).
    3. Test body (pre-zero state, populate DEFAULT_FCB, call `fileio_load_initial`, assert post-state).
    4. `test_epilogue.inc` (test_pass / test_fail labels).
    5. Production INCLUDEs in AR25 order: statusln + render + dispatch + parser + exline + fileio. **NOTE:** init.asm is NOT included by these tests — they exercise `fileio_load_initial` directly to keep each test focused. The full init_cold_start flow is regression-covered by the existing `init_cold_start-state-shape.asm` (which Story 2.3 may need to update — see AC17 below).
    6. `test_input_loop_stub.inc` — load-bearing for the not-found test (the sentinel-set stub catches any accidental funnel JP).
    7. Local `init_teardown` stub (defensive; the fileio tests don't reach it but a future regression might).
    8. `state.inc` LAST (positional anchor).

  - **Sentinel codes** for init_default-fcb tests (0xE0..0xEF range, mirroring Story 2.2's fileio tests):
    - 0xE0 — primary post-call state mismatch
    - 0xE1 — filename_buffer mismatch (B = index of mismatching byte)
    - 0xE2 — gap_start mismatch (B = low byte of delta)
    - 0xE3 — gap_end mismatch
    - 0xE4 — buffer_dirty != 0
    - 0xE5 — status_buffer prefix mismatch
    - 0xE6 — status_dirty != 1
    - 0xE7 — funnel-was-entered sentinel (for not-found test)

**AC17 — `init_cold_start-state-shape.asm` continues to pass post-Story-2.3.**

**Given** Story 1.12's `test/cases/init_cold_start-state-shape.asm` exercises the full `init_cold_start` flow and asserts the post-init state shape (mode = NORMAL, gap empty, status row reconciled, etc.)
**When** Story 2.3 lands the Stage 5 swap (msg_mode_normal → fileio_load_initial)
**Then** the existing test continues to PASS. The test's setup leaves `DEFAULT_FCB + 1 = 0x20` (the iz-cpm launch default with no command tail) — the no-arg short-circuit fires; `fileio_load_initial` falls through to `msg_mode_normal`; the post-init state matches the test's existing assertions byte-for-byte.

**And** the test's includes need updating — specifically, the production-code INCLUDE chain (state-shape currently does not INCLUDE fileio.asm because Story 1.12 had no fileio dependency). Story 2.3's init.asm now references `fileio_load_initial`, so state-shape MUST add `INCLUDE "../../src/fileio.asm"` after the existing `INCLUDE "../../src/parser.asm"` line (AR25 order). The test's other includes (statusln, gapbuf, render, dispatch, parser) stay in place.

**Defensive check.** If the test's startup poison (`0xAA` fill across the static block — line 113 of the test) accidentally lands on `DEFAULT_FCB`, the no-arg short-circuit might not fire (0xAA at `+1` is not 0x20). But `DEFAULT_FCB` is at 0x005C — well below `static_data_base` (which is in the TPA, post-ORG-0x0100) — the static-block LDIR doesn't touch it. **Spec confirmation:** `DEFAULT_FCB = 0x005C` and `static_data_base >= 0x0101` (ASSERTed at the top of state.inc). The 0xAA poison cannot reach 0x005C.

**But** the test DOES need to ensure `DEFAULT_FCB + 1` is a space at .com entry — under iz-cpm with no command-line filename to the test .com, this is already the case (CCP space-pads). Spec the test to NOT touch `DEFAULT_FCB` (let the iz-cpm default pre-zero or pre-space the FCB; either is fine for the no-arg short-circuit).

**Wait — defensive zeroing.** To eliminate iz-cpm-specific FCB defaults as a variable, the test should EXPLICITLY write `DEFAULT_FCB + 1 = 0x20` before calling `init_cold_start`. Add this write to the test body (just before the existing `JP init_cold_start` at line 127 of the test).

## Tasks / Subtasks

- [x] **Task 1: Refactor `src/fileio.asm` — extract `fileio_compose_filename_buffer` (AC12)**
  - [x] Sub 1.1: Locate the `.done_parse` block at the tail of `fileio_parse_filename` (lines 440-482 in the current `src/fileio.asm`).
  - [x] Sub 1.2: Extract the block as a new internal label `fileio_compose_filename_buffer` between `fileio_parse_filename` and `fileio_ingest_sector` (placement keeps related helpers contiguous).
  - [x] Sub 1.3: Update `fileio_parse_filename`'s body to fall through into `fileio_compose_filename_buffer` (no explicit JP — physical adjacency does the work; if a future story inserts a routine between them, change to explicit `JP`).
  - [x] Sub 1.4: Add an AR23 contract block above the new label: In, Out, Trashes per AC12.
  - [x] Sub 1.5: Verify the existing Story 2.2 tests pass byte-equivalently (regression net for the refactor).

- [x] **Task 2: Refactor `src/fileio.asm` — extract `fileio_load_after_open` (AC8)**
  - [x] Sub 2.1: Identify Steps 6-12 in the current `fileio_load` body (lines 197-268 — the body from `LD DE, DEFAULT_DMA` through the post-load `RET`).
  - [x] Sub 2.2: Insert label `fileio_load_after_open:` immediately before Step 6 (`LD DE, DEFAULT_DMA`).
  - [x] Sub 2.3: Update `fileio_load`'s Step 5 cleanup so the routine falls through naturally into the new label (no JR needed if physically contiguous). Verify no orphan labels.
  - [x] Sub 2.4: Update the AR23 contract block on `fileio_load_after_open` (internal helper):
    - In: A = 0..3 (BDOS_OPEN success result; not inspected here but documented for completeness)
    - Out: gap buffer populated with file content; status row reflects "FILENAME N bytes"; filename_buffer populated (by the caller).
    - Trashes: A, BC, DE, HL, F.
    - Calls: BDOS_CALL (SET_DMA / READ_SEQ / CLOSE), fileio_ingest_sector, gapbuf_move_gap, render_mark_all_dirty, fileio_compose_loaded_status, status_set_message, fileio_abort_too_large, fileio_abort_read_error.
  - [x] Sub 2.5: Verify the existing fileio_load-* and fileio_e-* tests pass byte-equivalently.

- [x] **Task 3: Add `fileio_load_initial` and supporting helpers to `src/fileio.asm` (AC1, AC2, AC4, AC7, AC9, AC10, AC11)**
  - [x] Sub 3.1: Add `fileio_setup_from_default_fcb` internal helper (AC11):
    - 12-byte LDIR `DEFAULT_FCB → fcb_scratch`.
    - 24-byte zero-fill at `fcb_scratch + 12`.
    - FR9 drive-byte translation: `0 → 2`.
    - CALL `fileio_compose_filename_buffer` (extracted in Task 1).
    - RET.
    - AR23 contract block per AC11.
  - [x] Sub 3.2: Add `fileio_compose_new_file_status` internal helper (AC10):
    - Copy `filename_buffer` (NUL-terminated) into `fileio_status_scratch`.
    - Copy `fileio_msg_new_file_suffix` (`" [new file]\0"`) after the filename.
    - Return HL = `fileio_status_scratch`.
    - AR23 contract block per AC10.
  - [x] Sub 3.3: Add `fileio_msg_new_file_suffix: DEFB " [new file]", 0` to the module-local data block (immediately after `fileio_msg_cant_open_prefix`).
  - [x] Sub 3.4: Add `fileio_load_initial` public entry (AC9):
    - Step 1: No-arg short-circuit (`LD A, (DEFAULT_FCB + 1) ; CP ' ' ; JR Z, .no_arg`).
    - Step 2: `CALL fileio_setup_from_default_fcb`.
    - Step 3: `CALL gapbuf_init`.
    - Step 4: AR15 launch carve-out — inline BDOS_OPEN (`LD C, BDOS_OPEN ; LD DE, fcb_scratch ; CALL BDOS_ENTRY ; OR A ; JP M, .new_file`). Inline annotation: `; AR15 launch carve-out: bypass funnel for the launch open`.
    - Step 5: Fall through (or `JR`) to `fileio_load_after_open` — shared with `:e`.
    - `.new_file` branch: `CALL fileio_compose_new_file_status ; XOR A ; LD (buffer_dirty), A ; CALL render_mark_all_dirty ; LD HL, fileio_status_scratch ; XOR A ; JP status_set_message`.
    - `.no_arg` branch: `LD HL, msg_mode_normal ; XOR A ; JP status_set_message`.
  - [x] Sub 3.5: Update fileio.asm's AR23 header block:
    - Add `fileio_load_initial` to the `Public:` list with a contract summary.
    - Add the AR15 launch carve-out to the "Architectural enforcement here" block (per AC7's documentation template).
    - Update `State owned (read/write)` to note that filename_buffer's preservation contract on new-file is a launch-only divergence.
  - [x] Sub 3.6: Update fileio.asm's `Dependencies:` block — add `inc/bios.inc (DEFAULT_FCB)` to the explicit dependency list (BIOS was already pulled in for `DEFAULT_DMA`; this just elevates DEFAULT_FCB from "implicit" to "explicit" in the header documentation).

- [x] **Task 4: Modify `src/init.asm` — wire Stage 5 to `fileio_load_initial` (AC13)**
  - [x] Sub 4.1: Replace the Stage 5 body in `init_cold_start`:
    - Remove: `LD HL, msg_mode_normal ; XOR A ; CALL status_set_message`.
    - Insert: `CALL fileio_load_initial`.
  - [x] Sub 4.2: Update the Stage 5 contract block in `init_cold_start`'s header (the prose at lines 232-242 of init.asm) per AC13's documentation template.
  - [x] Sub 4.3: Update init.asm's module-header `Dependencies:` block — add `src/fileio.asm (fileio_load_initial — Story 2.3)`.
  - [x] Sub 4.4: Update the existing comment near line 80 ("Story 2.3 lands the real FCB -> filename_buffer parse + fileio_load integration") to reflect the now-resolved state. Replace with: "Story 2.3 resolved: Stage 5 calls fileio_load_initial which parses DEFAULT_FCB and either seeds msg_mode_normal (no arg) or executes the launch load via the same fileio_load_after_open shared body that :e uses."

- [x] **Task 5: Update `test/cases/init_cold_start-state-shape.asm` for Story 2.3 (AC17)**
  - [x] Sub 5.1: Add `INCLUDE "../../src/fileio.asm"` to the production-code INCLUDE chain (after the existing `INCLUDE "../../src/parser.asm"` line, preserving AR25 order).
  - [x] Sub 5.2: Insert an explicit `DEFAULT_FCB + 1` zero/space pre-set in the test body, just before `JP init_cold_start`. Specifically: `LD A, ' ' ; LD (DEFAULT_FCB + 1), A`. This eliminates any iz-cpm-specific default-FCB content as a variable.
  - [x] Sub 5.3: Verify the test continues to pass — the post-init state shape is unchanged (no filename was loaded; gap stays empty; status reconciles to msg_mode_normal).

- [x] **Task 6: Add headless tests (AC16)**
  - [x] Sub 6.1: `test/cases/init_default-fcb-no-arg.asm` — pre-fill `DEFAULT_FCB + 0..11` with 0xAA; explicitly write `DEFAULT_FCB + 1 = 0x20`; CALL `fileio_load_initial`; assert: filename_buffer[0] = 0; gap_start = GAP_BUFFER_BASE; status_dirty = 1; status_buffer[0] = ' '. Sentinel range 0xE0..0xE7.
  - [x] Sub 6.2: `test/cases/init_default-fcb-loads-file.asm` — pre-populate DEFAULT_FCB with the FCB encoding of `hello.txt` (drive=0, basename="HELLO   ", ext="TXT"); CALL `fileio_load_initial`; assert load complete: filename_buffer = "B:HELLO.TXT\0"; gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX - 13; buffer_dirty = 0; status_buffer prefix = "B:HELLO.TXT ".
  - [x] Sub 6.3: `test/cases/init_default-fcb-drive-prefix.asm` — pre-populate DEFAULT_FCB with drive=1 (A:) + HELLO.TXT; CALL `fileio_load_initial`; assert filename_buffer = "A:HELLO.TXT\0"; fcb_scratch[0] = 1 (FR10 prefix preserved, NOT overridden by FR9).
  - [x] Sub 6.4: `test/cases/init_default-fcb-not-found.asm` — pre-populate DEFAULT_FCB with drive=0 + NOSUCH.FS; CALL `fileio_load_initial`; assert filename_buffer = "B:NOSUCH.FS\0" (PRESERVED — divergence from `:e`); gap empty; buffer_dirty = 0; status_buffer prefix = "B:NOSUCH.FS [new file]"; local input_loop stub sentinel UNTOUCHED (confirms no funnel entry).
  - [x] Sub 6.5: `test/cases/init_default-fcb-too-large.asm` — pre-populate DEFAULT_FCB with drive=0 + BIG.BIN (the existing `test/fixtures/big.bin` from Story 2.2); CALL `fileio_load_initial`; assert filename_buffer[0] = 0 (CLEARED); gap_start = GAP_BUFFER_BASE; buffer_dirty = 0; status_buffer = "file too large".

- [x] **Task 7: Update `_bmad-output/implementation-artifacts/deferred-work.md` (Story 2.2 context)**
  - [x] Sub 7.1: Add a "Touched by Story 2.3" sub-bullet under the Story-2.2-deferred "NFR9 code-budget overshoot" entry: Story 2.3 adds ~130-180 B, pushing the footprint deeper into the overshoot; the amend-NFR9 follow-up (line 122) becomes more urgent.
  - [x] Sub 7.2: Add a "Resolved by Story 2.3 (no-op behavioural)" sub-bullet under the Story-2.2-deferred "W7: fileio_abort_common zeros only filename_buffer[0]" entry IF the new-file path's filename_buffer preservation contract clarifies the invariant (it does — filename_buffer is preserved only when buffer_dirty[0..15] is wanted; the abort path's NUL-terminator-only zero is sufficient and now contractually pinned by Story 2.3's tests). Phrasing: "Story 2.3 added the new-file path which intentionally preserves filename_buffer bytes 0..15. The NUL-terminator-only zero in fileio_abort_common is sufficient for the abort contract; W7's concern (a future reader scanning bytes 1..15) remains a defensive question for future stories and is NOT in Story 2.3's scope."
  - [x] Sub 7.3: Open a NEW Story-2.3 section if any new deferrals arise during the dev pass (e.g., the W3 `cmd_edit_common` refactor opportunity from Story 2.2 line 125 might naturally grow into "factor `cmd_edit_common` AND `cmd_launch_common`"; if the dev notices an analogous opportunity in `fileio_load_initial` vs `fileio_load` Step 1-5 sharing, log it).

- [x] **Task 8: Build + headless test verification (AC15, AC16)**
  - [x] Sub 8.1: `make clean && make` succeeds; capture SHA256 of vibe.com.
  - [x] Sub 8.2: Repeat `make clean && make`; verify byte-identical SHA (NFR18).
  - [x] Sub 8.3: `make sizes` reports the new code-section size. Capture verbatim. Note delta vs Story 2.2's 3106 B and the (still-unamended) NFR9 budget.
  - [x] Sub 8.4: AR grep sweeps per AC15 — all pass; the one new AR15 launch carve-out site in fileio.asm bears the documented annotation.
  - [x] Sub 8.5: `make test` from project root — all existing tests pass (regression net for the Task 1 + Task 2 refactors) + the new init_default-fcb-* tests pass. Live baseline becomes 36 (post-2.2) + 5 (new) = 41 pass + 1 deliberate fail.

- [x] **Task 9: Hardware UAT (AC14)** — *completed by user 2026-05-13. Steps 1-5, 7-10 all green; step 6 (vibe huge.fs) skipped per AC14's documented exception (no >32 KB file on the SD card; headless `init_default-fcb-too-large.asm` stands in as coverage).*
  - [x] Sub 9.1: `make push` — SLIDE transfer to the MicroBeast.
  - [x] Sub 9.2: Step through AC14's 10 hardware UAT steps; record observations in Debug Log References.
  - [x] Sub 9.3: Particular regressions to watch for:
    - `vibe` with no arg behaves identically to the pre-2.3 launch (Story 1.12 hardware UAT regression net).
    - `vibe foo.fs` loads and renders correctly with the cursor at row 0 col 0 (Story 2.1 COMMAND-mode cursor override does NOT interfere; the cursor is in NORMAL mode at offset 0).
    - The `[new file]` status banner survives the first render_full cycle — verify the AR12 funnel's pad-to-STATUS_LINE_WIDTH didn't truncate (`B:MISSING.FS [new file]` = 22 chars; STATUS_LINE_WIDTH = 80; nowhere near truncation).
    - File content with control chars (TAB / CR / NUL) — same known seam as Story 2.2 (deferred-work.md line 76); restrict hardware UAT fixtures to plain ASCII.

### Review Findings

*(Empty pre-dev; the code-review pass appends patches / decisions / defers here per the Story 2.2 pattern.)*

## Dev Notes

### Architecture compliance

This story closes the **journey-1a launch path** (PRD line 215+): `vibe foo.fs` from CCP → editor opens with the file loaded → user types → `:w` saves → `:q` exits. With Story 2.3 done, the full one-keystroke entry path exists; Story 2.4 (`:w` / `:wq`) closes the save half; Stories 2.5..2.13 close the editing half. The wider architecture mapping:

- **FR1 (Launch with no args, save creates file).** Story 2.3 lands the no-arg short-circuit (AC2). The "save creates file" half is Story 2.4's `:w` work; Story 2.3 only ensures `filename_buffer` is empty (NUL at byte 0) when no arg is present so Story 2.4's `:w` can detect "no filename" and refuse cleanly per its planned AC.
- **FR2 (Launch with filename, file loads).** Primary Story 2.3 deliverable (AC3).
- **FR6 (User can open a different file — `:e filename`).** Unchanged from Story 2.2; the `fileio_load` refactor (Tasks 1 + 2) is the regression net.
- **FR9 (Drive-B default for bare filenames).** Now also applies to the launch path (AC11's drive-byte translation: CCP's drive-byte 0 ("default drive") → fcb_scratch[0] = 2 (B:)). Note: CCP's "default drive" is whatever drive the user is currently on at the CCP prompt — could be A:, could be B:. FR9 OVERRIDES that to always-B: for bare filenames in vi. The translation makes vi's launch consistent with vi's `:e` (which also defaults to B: for bare filenames). User-experience consistency note: a user on A: typing `vibe foo.fs` will see B:FOO.FS in vi's status row, NOT A:FOO.FS. This is intentional and AR16-spec.
- **FR10 (Explicit drive-letter prefix).** Now also applies to the launch path (AC11: drive byte > 0 passes through; the canonical display form correctly reads "A:FOO.FS" or "B:FOO.FS" depending on the prefix the user typed at CCP).
- **FR11 (Oversize refusal).** Same path as `:e` (AC5); `fileio_abort_too_large` handles it.
- **FR51 (CP/M file-I/O failure surfacing).** **DIVERGENCE from `:e` semantics for the new-file path (AC4).** `:e missing.fs` surfaces "can't open B:MISSING.FS" via the BDOS funnel; `vibe missing.fs` surfaces "B:MISSING.FS [new file]" via the launch path's local new-file branch. The divergence is intentional and stems from launch-mode's "ready to start editing the named file" intent vs `:e`'s "tried to switch buffers and failed" intent.
- **FR52 / NFR6 (No silent data loss).** The new-file path's `filename_buffer` preservation is what makes "no silent data loss" hold for the journey-1a flow: a user who typed `vibe newgame.fs`, typed insert-mode content, then `:w` would save to `B:NEWGAME.FS` (because Story 2.4's `:w` reads `filename_buffer`). If filename_buffer were cleared on open-fail (the `:e` semantics), the `:w` would refuse with "no filename" and the user would lose their typed content unless they remembered to `:w newgame.fs`. The preservation is FR52-load-bearing.
- **AR12 (Single status-message funnel — `status_set_message`).** Every status emit in Story 2.3 goes through `status_set_message` (no-arg path; new-file path; load-success and abort paths via the shared post-open body).
- **AR13 (Single screen-emission path — render.asm only).** `fileio_load_initial` has zero `BIOS_CONOUT` references. Screen-update flow: `fileio_load_initial` → `render_mark_all_dirty` (all paths set dirty_rows) → `render_full` (init Stage 6) → `render_diff` emits every row from the buffer + the status row.
- **AR14 (Single buffer-mutation owner — `gapbuf.asm`).** Story 2.2's AR14 carve-out (linear-fill phase in `fileio_ingest_sector`) is unchanged. Story 2.3's launch path REUSES the carve-out via the shared `fileio_load_after_open`. The launch's setup phase calls `gapbuf_init` (Step 3 of AC9) but does NOT directly write gap_start / gap_end — the AR14 surface is unchanged.
- **AR15 (Single BDOS gateway — `BDOS_CALL` macro). NEW CARVE-OUT documented in AC7:** `fileio_load_initial`'s BDOS_OPEN is inlined (one `CALL BDOS_ENTRY` site, not via the macro). The carve-out is necessary because the macro's `JP M, bdos_error_funnel` routing terminally `JP input_loop`s on open-fail; the launch path's intended behaviour (return to init_cold_start so Stages 6/7 run) is incompatible with the funnel's flow.
  - **Sanity check on the carve-out scope.** The launch path makes EXACTLY ONE inline BDOS call (the open). The post-open body (`fileio_load_after_open`) uses BDOS_CALL for SET_DMA / READ_SEQ / CLOSE — the standard macro routing. The carve-out is single-site and the AR23 header documents it.
- **AR16 (Status-message string convention).** Two new dynamic status strings:
  - `"<FILENAME> [new file]"` — filename uppercase (passes through from fcb_scratch); " [new file]" suffix is lowercase, bracketed, no trailing period. AR16-compliant.
  - The reused `"<FILENAME> N bytes"` (Story 2.2) covers the load-success path.
- **AR22 (Naming).** New public symbol: `fileio_load_initial`. Internal helpers (dotted-locals or shared module-internal): `.no_arg`, `.new_file`, `fileio_setup_from_default_fcb`, `fileio_compose_new_file_status`, `fileio_compose_filename_buffer`, `fileio_load_after_open`. The `fileio_*` prefix matches the existing convention; the `_initial` suffix mirrors the architecture-doc convention for cold-start-only entry points (parallel to `init_cold_start`).
- **AR23 (File structure and routine contracts).** Every new public / internal helper begins with the four-line `In:` / `Out:` / `Trashes:` / `Calls:` contract. `fileio.asm`'s module-header `Public:` list grows by one entry (`fileio_load_initial`). The "Architectural enforcement here" block gains the AR15 launch carve-out documentation.
- **AR24 (Format).** 4-space indentation, UPPERCASE mnemonics, `;` line / `;;` section comments, no trailing periods.
- **AR25 (Module include order).** No new modules; fileio.asm's position is unchanged. init.asm's INCLUDE chain (via vibe.asm) is unchanged.

### Library / framework requirements

**sjasmplus 1.23.0:**
- Already pinned by Makefile's `check-toolchain`.
- **No new forward-reference scenarios.** `fileio_load_initial` is in fileio.asm, called from init.asm. init.asm INCLUDEs BEFORE fileio.asm (via vibe.asm's chain — confirm by reading vibe.asm). The CALL from init.asm to `fileio_load_initial` is a forward reference; sjasmplus's two-pass model resolves it. Same pattern as Story 2.2's `cmd_edit` referencing `fileio_load`.
- **Internal label-scoping note for Task 1 + Task 2 refactors.** The extracted `fileio_compose_filename_buffer` is a NAMED label (not dotted-local), so it's globally visible and JP-target-safe across the file. The `.done_parse` -> `compose_filename_buffer` refactor changes the symbol from dotted-local-within-parse_filename to a top-level label; verify no other code references `fileio_parse_filename.done_parse` (Story 2.2's tests don't — they assert post-state, not control-flow waypoints).

**iz-cpm:**
- All five new headless tests run under iz-cpm.
- Fixtures: `test/fixtures/hello.txt` (existing, 13 bytes), `test/fixtures/big.bin` (existing, Story 2.2 — 33 KB). No new fixtures needed.
- **DEFAULT_FCB writes in tests.** The tests write to 0x005C..0x0067 (DEFAULT_FCB + 0..+11) at the top of the test body. Under iz-cpm, this region is RAM (not protected); writes succeed. iz-cpm's CCP-equivalent populates DEFAULT_FCB at .com launch based on the iz-cpm invocation; for our tests, the invocation has no filename, so iz-cpm space-pads. Our explicit overwrite ensures determinism regardless of iz-cpm's specific defaults.

**CP/M 2.2 BDOS / MicroBeast BIOS:**
- No new BDOS surface (BDOS_OPEN / SET_DMA / READ_SEQ / CLOSE are Story 2.2's surface).
- DEFAULT_FCB at 0x005C is CP/M-standard (already EQUd in inc/bios.inc line 64).
- Drive-byte encoding: CP/M 2.2 uses 0 for "default drive (the currently-selected drive at command time)", 1..16 for A:..P:. CCP's parse stores 0 when no prefix is on the command tail; 1 for `A:foo`, 2 for `B:foo`, etc. FR9's "bare → B:" override applies on top of CCP's encoding.
- **No assumed file-size oracle.** Same as Story 2.2 — no `stat`-equivalent in CP/M 2.2; oversize is detected post-hoc by the pre-read budget check.

### Filename parse — edge cases (FCB form)

The launch path's filename parse is FCB-form (CCP-pre-parsed), unlike `:e`'s text-form (user-typed). Edge cases:

- **Bare command (`vibe`):** CCP fills basename with 8 spaces, ext with 3 spaces, drive byte = 0. `DEFAULT_FCB + 1 = 0x20` → no-arg short-circuit fires; `fileio_load_initial` returns after `msg_mode_normal`. **Test:** `init_default-fcb-no-arg.asm`.

- **Lowercase filename (`vibe foo.fs`):** CCP uppercases at command-parse time → `DEFAULT_FCB + 1..8 = "FOO     "`, `+9..11 = "FS "`. No further uppercase work needed; `fileio_load_initial` copies as-is into fcb_scratch. Display: "B:FOO.FS\0".

- **Explicit drive (`vibe a:foo.fs`):** CCP fills drive byte = 1, basename = "FOO     ", ext = "FS ". `fileio_load_initial`'s FR9 translation sees `fcb_scratch[0] = 1`, leaves it alone. Display: "A:FOO.FS\0". **Test:** `init_default-fcb-drive-prefix.asm`.

- **No extension (`vibe foo`):** CCP fills basename = "FOO     ", ext = "   " (all spaces). `fileio_compose_filename_buffer`'s existing logic (Story 2.2) sees the space at ext[0] and omits the dot in the display form. Display: "B:FOO\0".

- **Overflow names (`vibe abcdefghi.fs`):** CCP truncates the basename to 8 chars at parse time → `+1..8 = "ABCDEFGH"`, ext = "FS ". Launch behaves the same as `:e abcdefghi.fs` post-truncation. Acceptable — CP/M does the same.

- **Path-like (`vibe foo/bar`):** CCP parses the `/` as a filename byte (CP/M has no directories). `+1..8 = "FOO/BAR "`. BDOS_OPEN likely fails (invalid filename byte); launch path takes the new-file branch with display "B:FOO/BAR\0 [new file]". Acceptable — user can `:q!` and try again.

- **Drive only (`vibe a:`):** CCP fills drive = 1, basename = 8 spaces, ext = 3 spaces. **Edge case for the no-arg detection:** `DEFAULT_FCB + 1 = 0x20` even though drive byte is non-zero. The space-only basename triggers the no-arg short-circuit — `fileio_load_initial` returns with msg_mode_normal, drive selection is IGNORED. Acceptable; vi's CCP-launch convention doesn't include "set default drive" semantics.

- **Multiple filenames (`vibe foo.fs bar.fs`):** CCP populates only the first FCB at DEFAULT_FCB; the second filename lands at DEFAULT_FCB + 16 (0x006C — overlapping the first FCB's allocation map region). `fileio_load_initial` reads only DEFAULT_FCB + 0..11; the second filename is ignored. Acceptable — vi doesn't support multi-file launch.

### Read loop — performance and correctness

Unchanged from Story 2.2 — the launch path reuses `fileio_load_after_open` which IS Story 2.2's read loop. Performance characteristics (per-sector cost, 128-byte LDIR, 0x1A scan, `gapbuf_move_gap(0)` post-load) are inherited.

### Previous story intelligence

**From Story 2.2 (most relevant — fileio.asm's primary substrate):**
- `fileio_load` (Story 2.2) is refactored into two parts in Story 2.3: the pre-open setup (parse + gapbuf_init + bdos_error_pre_msg pre-stage + BDOS_OPEN-with-funnel) stays in `fileio_load`; the post-open body (Steps 6-12) becomes the shared `fileio_load_after_open`. The refactor is byte-equivalent in observable behaviour (Task 1 / Task 2's regression-net assertion).
- `fileio_parse_filename`'s tail-block (`.done_parse`) is extracted as the shared `fileio_compose_filename_buffer`. The compose phase is now reachable from BOTH the text-form parse (Story 2.2's `:e`) and the FCB-form launch (Story 2.3's path).
- `fcb_scratch` (36 bytes; in fileio.asm's data block) is the canonical FCB for both `:e` and the launch path — they alternate ownership across launches but never overlap (each entry zeroes/repopulates as needed).
- `fileio_status_scratch` (48 bytes) is reused by the new `fileio_compose_new_file_status` helper. The 48-byte capacity (story 2.2's spec) covers the "B:FILENAME.EXT [new file]" max length (27 bytes); the existing ASSERT bound stays valid.
- The `bdos_error_pre_msg` override mechanism (statusln.asm + fileio_load) is NOT used by the launch path. The W8 stale-pointer invariant (deferred-work.md line 130) is preserved: `fileio_load_initial` neither writes nor reads `bdos_error_pre_msg`.

**From Story 1.12 (init/teardown — Stage 5 modification target):**
- `init_cold_start`'s 8-stage structure is preserved. Story 2.3 swaps Stage 5's body (msg_mode_normal seed → fileio_load_initial call). All other stages unchanged.
- The state-shape test (`init_cold_start-state-shape.asm`) is the regression net for Stage 5's behavioural-equivalence in the no-arg case. AC17 details the test update.
- DEFAULT_FCB at 0x005C is well below the static-block start (`static_data_base >= 0x0101` per state.inc's ASSERT) and well below the gap buffer. The LDIR fill in Stage 1 does NOT touch DEFAULT_FCB; CCP-populated content survives until `fileio_load_initial` reads it at the new Stage 5.

**From Story 2.1 (cmd_quit / cmd_quit_force precedent for tail-JP routing):**
- The Story 2.1 / 2.2 pattern of "handler sets status, then tail-JPs to cancel_core / cancel" doesn't directly apply to `fileio_load_initial` (which RETs to init_cold_start, not to exline_cancel_core). But the AR16 status-banner-preserves-on-cancel pattern is consistent: every fileio_load_initial path that emits a banner does so via `status_set_message`, and the caller's flow (init_cold_start's Stages 6/7) does NOT clobber the banner.

**From Story 1.7 (gap buffer — invariants reaffirmed):**
- `gapbuf_init` is the canonical SR2-establishing entry. `fileio_load_initial`'s Step 3 calls it for hygiene even though Stage 3 of init_cold_start already did. Idempotent.
- `gapbuf_move_gap(0)` (the post-load shift) lives in the shared `fileio_load_after_open`; Story 2.3 doesn't change its contract or call site.

**From Story 1.5 (statusln — bdos_error_funnel NOT used by Story 2.3):**
- The funnel's terminal `JP input_loop` is what makes the launch path's AR15 carve-out necessary. Story 2.2 added the override pointer + inline cleanup; Story 2.3 deliberately BYPASSES the funnel entirely for the launch open. The funnel is unchanged.

### Git intelligence

Fourteen commits on `main` after the project skeleton (most-recent five per `git log`):

- `0f1f980` — story 2.2: Wrote file load; :e opens a file, :e! forces past a dirty buffer.
- `be42853` — story 2.1: Wrote the : command-line; :q quits, :q! force-quits, Backspace and Esc work
- `0ef09de` — story 1.12: Wired init/teardown, the main input loop, and the first on-hardware smoke test.
- `dc2dd0d` — story 1.11: Wrote the screen renderer: dirty-row diff, scroll, Ctrl-L full redraw, status row.
- `e9f291a` — story 1.10: Wrote the command parser: counts, pending operators, and the gg motion-prefix.

Conventions visible in the tree (preserve in Story 2.3):
- One story per commit; short imperative subject + colon-separated context.
- AR23 header blocks on every `.asm` and `.inc` file.
- Every public routine has the `In:` / `Out:` / `Trashes:` / `Calls:` four-line contract.

Suggested commit message for Story 2.3 (when the dev finishes): `story 2.3: Wrote launch-with-filename; vibe foo.fs opens the file, vibe missing.fs gets [new file].` Match the prior stories' plain-English style.

### Testing requirements

Story 2.3's testing requirements split into four categories:

**Build-time / static:**

1. `make` from project root succeeds (NFR14 / AC15).
2. `make clean && make` produces byte-identical `vibe.com` across two consecutive runs (NFR18 / AC15). Capture both SHAs.
3. `make sizes` reports the code-section size (NFR9 — already overshot per Story 2.2; track the new size; flag as a notable observation if it exceeds Ant's proposed 4096 B amended ceiling).
4. AR grep sweeps (AC15) — all pass. The one new AR15 launch carve-out site in fileio.asm is annotated.

**Headless test cases (5 new):**

5. `init_default-fcb-no-arg.asm` — DEFAULT_FCB + 1 = ' ' → no-op short-circuit; msg_mode_normal seeded.
6. `init_default-fcb-loads-file.asm` — FCB-encoded `HELLO.TXT` → loads from B:; status reads byte count.
7. `init_default-fcb-drive-prefix.asm` — FCB-encoded `A:HELLO.TXT` → loads from A:; status shows A: prefix.
8. `init_default-fcb-not-found.asm` — FCB-encoded `NOSUCH.FS` → new-file path; filename_buffer preserved; status reads "[new file]"; funnel NOT entered.
9. `init_default-fcb-too-large.asm` — FCB-encoded `BIG.BIN` (33-KB fixture) → too-large abort; filename_buffer cleared.

10. **Live baseline becomes at least 41 pass / 1 fail** (36 post-2.2 + 5 new + the deliberate `harness_fail`).

**Regression-net tests (unchanged source — must continue to pass after Task 1 + Task 2 refactors):**

11. All 5 Story 2.2 `fileio_load-*` tests pass (regression net for the `fileio_compose_filename_buffer` extraction and the `fileio_load_after_open` refactor).
12. All 3 Story 2.2 `fileio_e-*` tests pass (cmd_edit / cmd_edit_force unchanged).
13. The state-shape test `init_cold_start-state-shape.asm` continues to pass post-AC17 update (Task 5).
14. All Story 2.1 `exline_*` tests pass (no exline changes in Story 2.3).
15. All Story 1.x tests pass (no Epic-1 module changes in Story 2.3).

**Hardware UAT (AC14):**

16. SLIDE-push and launch from CCP: `vibe foo.fs` loads; status shows the byte count; mode is NORMAL.
17. `vibe missing.fs` launches with `[new file]` banner; buffer empty; `:q` exits cleanly.
18. `vibe a:test.fs` loads from A:.
19. Bare `vibe` (no args) launches with empty buffer + empty status banner — Story 1.12 regression net.
20. `:e bdos.txt` post-launch still works — Story 2.2 regression net.
21. Sustained-typing regression (30+ keystrokes after a launch-load) — Stories 1.12 / 2.1 / 2.2 regression net.

### Project Structure Notes

After Story 2.3 the source tree is:

```
src/
├── vibe.asm          # Story 2.3 — unchanged (the AR25 INCLUDE chain already includes fileio.asm post-2.2)
├── init.asm          # Story 2.3 — Stage 5 body swapped from msg_mode_normal seed to fileio_load_initial CALL
├── input.asm         # Story 1.8 (unchanged)
├── statusln.asm      # Story 2.2 — unchanged by 2.3 (bdos_error_funnel still serves :e; launch path bypasses it)
├── gapbuf.asm        # Story 1.7 / 2.2 (unchanged)
├── render.asm        # Story 1.11 / 2.1 (unchanged)
├── dispatch.asm      # Story 1.9 / 2.1 (unchanged)
├── parser.asm        # Story 1.10 (unchanged)
├── exline.asm        # Story 2.1 / 2.2 (unchanged)
└── fileio.asm        # Story 2.2 / 2.3 — adds fileio_load_initial + fileio_setup_from_default_fcb
                      #   + fileio_compose_new_file_status + fileio_msg_new_file_suffix;
                      #   refactors fileio_parse_filename + fileio_load to share
                      #   fileio_compose_filename_buffer + fileio_load_after_open;
                      #   AR15 launch carve-out documented in the AR23 header.

inc/
├── equates.inc       # Story 1.2 (unchanged)
├── bios.inc          # Story 1.4 / 1.12 (unchanged — DEFAULT_FCB at 0x005C already EQUd)
├── bdos.inc          # Story 1.4 / 2.2 (unchanged)
├── modes.inc         # Story 1.2 (unchanged)
├── vt52.inc          # Story 1.2 / 1.12 (unchanged)
└── state.inc         # Story 1.3 / 1.12 / 2.1 (unchanged; filename_buffer / mode_byte etc. already declared)

test/
├── README.md
├── Makefile          # Story 2.2 — unchanged by 2.3 (existing fixture rules cover hello.txt + big.bin)
├── inc/              # (unchanged by 2.3)
├── fixtures/
│   ├── hello.txt     # (existing)
│   ├── eof1a.txt     # (existing — Story 2.2)
│   └── big.bin       # (existing — Story 2.2)
└── cases/
    ├── ... (existing 36 cases unchanged in source; the Story 1.12 init-state-shape gets AC17's update)
    ├── init_default-fcb-no-arg.asm           # NEW
    ├── init_default-fcb-loads-file.asm       # NEW
    ├── init_default-fcb-drive-prefix.asm     # NEW
    ├── init_default-fcb-not-found.asm        # NEW
    └── init_default-fcb-too-large.asm        # NEW
```

### Files created and modified by this story

**Files created:**
- `test/cases/init_default-fcb-no-arg.asm`
- `test/cases/init_default-fcb-loads-file.asm`
- `test/cases/init_default-fcb-drive-prefix.asm`
- `test/cases/init_default-fcb-not-found.asm`
- `test/cases/init_default-fcb-too-large.asm`

**Files modified:**
- `src/fileio.asm` — adds `fileio_load_initial` + helpers (`fileio_setup_from_default_fcb`, `fileio_compose_new_file_status`); refactors `fileio_parse_filename` to tail-into the new shared `fileio_compose_filename_buffer`; refactors `fileio_load` to fall through to the new shared `fileio_load_after_open`; AR23 header gains `fileio_load_initial` in Public list + AR15 launch carve-out in the enforcement block; new `fileio_msg_new_file_suffix` DEFB in the data section.
- `src/init.asm` — Stage 5 body replaced (`CALL fileio_load_initial`); Stage 5 contract block rewritten in the header; Dependencies updated to include `src/fileio.asm`; the existing "Story 2.3 lands the real FCB → filename_buffer parse" comment near line 80 updated to reflect the now-resolved state.
- `test/cases/init_cold_start-state-shape.asm` — INCLUDE chain adds `src/fileio.asm` (AR25 order); test body explicitly pre-sets `DEFAULT_FCB + 1 = ' '` for determinism.
- `_bmad-output/implementation-artifacts/deferred-work.md` — sub-bullets noting the Story-2.2 NFR9 deferral's growing pressure (now bigger overshoot); W7 invariant clarification (Story 2.3's new-file path codifies the NUL-terminator-only contract).

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md] lines 953-989
- Previous story (File load via :e, Story 2.2 — the fileio.asm + bdos_error_pre_msg substrate this story extends): [Source: _bmad-output/implementation-artifacts/2-2-file-load-via-e-filename-incl-e.md]
- Adjacent story (File save, Story 2.4 — will read `filename_buffer` written by this story's new-file path; needs the launch-mode preservation contract to hold): [Source: _bmad-output/planning-artifacts/epics.md] lines 991-1044
- FR1 / FR2 (Launch with no args / with filename): [Source: _bmad-output/planning-artifacts/prd.md] lines 696-699
- FR6 (User can open a different file — `:e filename`): [Source: _bmad-output/planning-artifacts/prd.md] lines 700-701
- FR9 (Drive-B default for bare filenames): [Source: _bmad-output/planning-artifacts/prd.md] line 705
- FR10 (Explicit drive-letter prefix): [Source: _bmad-output/planning-artifacts/prd.md] lines 706-707
- FR11 (Oversize refusal): [Source: _bmad-output/planning-artifacts/prd.md] lines 708-709
- FR51 (CP/M file-I/O failure surfacing): [Source: _bmad-output/planning-artifacts/prd.md] lines 793-797
- FR52 / NFR6 (No silent data loss): [Source: _bmad-output/planning-artifacts/prd.md] lines 799-802, 833-839
- NFR9 (code budget — already overshot per Story 2.2; amend pending in deferred-work.md): [Source: _bmad-output/planning-artifacts/prd.md] lines 848-851
- NFR14 (sjasmplus 1.23.0): [Source: _bmad-output/planning-artifacts/prd.md] lines 870-871
- NFR15 (CP/M 2.2 BDOS only): [Source: _bmad-output/planning-artifacts/prd.md] lines 872-874
- NFR18 (reproducible build): [Source: _bmad-output/planning-artifacts/prd.md] lines 886-887
- AR12 / MC5 (status-message funnel): [Source: _bmad-output/planning-artifacts/architecture.md] lines 535-541
- AR13 (single screen-emission path — render.asm only): [Source: _bmad-output/planning-artifacts/architecture.md] (boundary properties section)
- AR14 (single buffer-mutation owner — fileio's carve-out unchanged from Story 2.2): [Source: _bmad-output/implementation-artifacts/2-2-file-load-via-e-filename-incl-e.md] AC12 + src/fileio.asm AR23 header
- AR15 / MC6 (single BDOS gateway — `BDOS_CALL` macro; Story 2.3 adds a documented launch carve-out): [Source: _bmad-output/planning-artifacts/architecture.md] lines 543-548
- AR16 (status-message string convention): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1003-1037
- AR22 (naming): [Source: _bmad-output/planning-artifacts/architecture.md] lines 788-850
- AR23 (file structure and routine contracts): [Source: _bmad-output/planning-artifacts/architecture.md] lines 852-916
- AR25 (module include order): [Source: _bmad-output/planning-artifacts/architecture.md] lines 940-956
- BH6 (`:e` with unsaved changes — dirty refusal pattern; NOT applicable to launch since the buffer starts clean, but the design symmetry with `:e` is documented): [Source: _bmad-output/planning-artifacts/architecture.md] lines 704-706
- PRD launch-path semantics (journey 1a — "vibe game.fs and start typing"): [Source: _bmad-output/planning-artifacts/prd.md] lines 215-237
- PRD platform constraints (Drive B: default; explicit drive-letter prefix; FCB at 0x005C): [Source: _bmad-output/planning-artifacts/prd.md] lines 359-380
- Module Dependency Graph (init → fileio → BDOS at launch; exline → fileio → BDOS at `:e`): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1417-1418
- FR↔Module mapping (FR1/FR2 → init.asm + fileio.asm): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1515
- inc/state.inc (filename_buffer; static_data_base ≥ 0x0101 ASSERT): [Source: inc/state.inc]
- inc/equates.inc (FILENAME_BUFFER_SIZE = 16; GAP_BUFFER_MAX = 32768; STATUS_LINE_WIDTH = SCREEN_COLS): [Source: inc/equates.inc] lines 31, 41, 51
- inc/bios.inc (DEFAULT_FCB = 0x005C, DEFAULT_DMA = 0x0080, BDOS_ENTRY = 0x0005): [Source: inc/bios.inc] lines 63-65
- inc/bdos.inc (BDOS_OPEN = 15, BDOS_CLOSE = 16, BDOS_READ_SEQ = 20, BDOS_SET_DMA = 26; BDOS_CALL macro contract): [Source: inc/bdos.inc] lines 35-88
- src/fileio.asm (fileio_load + fileio_parse_filename + fileio_ingest_sector + abort helpers — Story 2.2's substrate that this story extends): [Source: src/fileio.asm]
- src/init.asm (init_cold_start's eight stages; Stage 5 modification target): [Source: src/init.asm] lines 265-323
- src/statusln.asm (msg_mode_normal, msg_file_too_large, msg_read_error — reused by the launch path; bdos_error_funnel — INTENTIONALLY bypassed by the launch carve-out): [Source: src/statusln.asm]
- src/vibe.asm (AR25 INCLUDE chain — unchanged by 2.3; fileio.asm already in the chain post-2.2): [Source: src/vibe.asm]
- test/Makefile (fixture rules for hello.txt + big.bin already cover the new tests' needs): [Source: test/Makefile]
- Story 2.2 deferred-work entries (W7 invariant clarification, NFR9 amend, BDOS_CLOSE failure-context): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 113-130
- Story 1.12 (init/teardown — the Stage 5 modification site; the state-shape test that is Story 2.3's regression net): [Source: _bmad-output/implementation-artifacts/1-12-init-teardown-on-hardware-smoke-test.md]
- Story 1.7 (gap buffer — SR2 invariant; gapbuf_init + gapbuf_move_gap contracts): [Source: _bmad-output/implementation-artifacts/1-7-gap-buffer-primitives-headless-tests.md]
- Story 1.5 (statusln — AR12 funnel + bdos_error_funnel default body; intentionally bypassed by Story 2.3's launch carve-out): [Source: _bmad-output/implementation-artifacts/1-5-status-line-module-with-single-message-funnel.md]
- Deferred-from-2.2 (NFR9 amend pending; growing pressure from Story 2.3): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 122
- Deferred-from-2.2 (W7 filename_buffer NUL-terminator-only invariant): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 129

## Dev Agent Record

### Agent Model Used

claude-opus-4-7 (Opus 4.7)

### Debug Log References

**Build (NFR14 / NFR18 / NFR9 / AC15):**
- `make clean && make` — succeeds; sjasmplus 1.23.0 pinned by Makefile's `check-toolchain`.
- Two consecutive `make clean && make` runs produce byte-identical `vibe.com`:
  - SHA-256 (run 1): `e3a422abe075c1e7e363579a0d5203f3c4d4e43d9ec938af6f54c030c410f3f8`
  - SHA-256 (run 2): `e3a422abe075c1e7e363579a0d5203f3c4d4e43d9ec938af6f54c030c410f3f8` (matches)
- `make sizes` post-2.3: `code_section: 3235 bytes (~105% of NFR9 ~3 KB budget)`. Story-2.2 baseline was 3106 B; delta = +129 B. Story spec at AC15 projected +130-180 B (final 3236-3286 B / 105-107%). Actual is at the low end of the prediction. Below the proposed amended ceiling of 4096 B (deferred-work line 122). The amend-NFR9 follow-up remains the load-bearing resolution.

**Headless tests (AC16 + regression net):**
- `make test` — 41 pass / 1 deliberate fail (`harness_fail` — pinned-by-design). Matches the story-spec target of 36 pre-2.3 + 5 new.
- New cases (5):
  - `init_default-fcb-no-arg` — no-arg short-circuit; FCB pre-poisoned with 0xAA except +1 set to ' '; filename_buffer untouched; status = msg_mode_normal (space).
  - `init_default-fcb-loads-file` — drive=0 + "HELLO.TXT" → FR9 translates to B:; filename_buffer = "B:HELLO.TXT\0"; gap_end = BASE + MAX - 13; status_buffer prefix = "B:HELLO.TXT "; after-gap content = "hello world\r\n".
  - `init_default-fcb-drive-prefix` — drive=1 + "HELLO.TXT" → FR10 prefix preserved; filename_buffer = "A:HELLO.TXT\0".
  - `init_default-fcb-not-found` — "NOSUCH.FS" → BDOS_OPEN returns 0xFF; AR15 launch carve-out catches JP M locally; filename_buffer = "B:NOSUCH.FS\0" PRESERVED; status_buffer prefix = "B:NOSUCH.FS [new file]"; funnel_entered sentinel = 0 (carve-out worked).
  - `init_default-fcb-too-large` — "BIG.BIN" (33-KB fixture) → pre-read budget check fires inside shared `fileio_load_after_open`; filename_buffer[0] = 0 CLEARED; status = "file too large".

**Regression-net coverage (out-of-spec sweeps applied during dev):**
- Pre-existing test-build breaks pulled forward and fixed: 3 dispatch_*.asm tests (broken since Story 2.1; dispatch.asm refs exline_* but tests didn't INCLUDE exline.asm), 5 exline_*.asm tests (broken since Story 2.2; cmd_edit refs fileio_* but tests didn't INCLUDE fileio.asm), 6 gapbuf_*.asm tests (broken since Story 2.2; statusln.asm's bdos_error_funnel refs MODE_NORMAL but tests didn't INCLUDE modes.inc). All 14 quietly-broken tests now build cleanly (sjasmplus exit=0). Logged the sjasmplus-lax-error-mode root cause in deferred-work.md as a Makefile hardening follow-up.
- Updated `test/cases/init_cold_start-state-shape.asm` per AC17 to add `INCLUDE "../../src/fileio.asm"` (and `exline.asm` for cmd_quit's init_teardown reference) and to explicitly pre-set `DEFAULT_FCB + 1 = ' '` for determinism.

**AR enforcement greps (AC15) — all clean:**
- AR13 (`BIOS_CONOUT` call sites outside render.asm): zero matches.
- AR14 (`LD (gap_start)` writes outside gapbuf.asm): two matches in `src/fileio.asm` (the Story-2.2 linear-fill carve-out in fileio_ingest_sector); both bear `; AR14 carve-out` annotations (unchanged from Story 2.2).
- AR15 (`CALL BDOS_ENTRY` / `CALL 0x0005` in fileio.asm): ONE new call-site match at the Story-2.3 launch carve-out in `fileio_load_initial` (line 465; bears `; AR15 launch carve-out` inline annotation; documented in the module header's "Architectural enforcement here" block).
- `BDOS_CALL` macro use in fileio.asm: multiple matches (BDOS_OPEN in fileio_load, BDOS_SET_DMA / READ_SEQ / CLOSE in fileio_load_after_open and abort paths). All non-launch BDOS calls continue to use the macro.
- `DEFAULT_FCB` references: read sites in fileio.asm (the launch path's pre-open check + setup helper); documentation in init.asm. No writes.

### Completion Notes List

**Implementation summary:**
- `src/fileio.asm` (modified): added `fileio_load_initial` public entry orchestrating the launch-with-filename flow. Pipeline: no-arg short-circuit (DEFAULT_FCB+1==' ') → fileio_setup_from_default_fcb (copy + FR9 translate + filename_buffer compose) → gapbuf_init → AR15 launch carve-out inline BDOS_OPEN → fall-through `JP fileio_load_after_open` (shared with :e) on success; `.new_file` branch on open-fail composes "FILENAME [new file]" status, preserves filename_buffer, RETs; `.no_arg` branch tail-JPs to status_set_message msg_mode_normal.
- Refactors extracted from Story-2.2's `fileio_load`:
  - `fileio_compose_filename_buffer` — extracted from `fileio_parse_filename`'s `.done_parse` tail via the dual-label trick (`.done_parse:` and `fileio_compose_filename_buffer:` resolve to the same address; preserves internal JR Z, .done_parse references; adds the external named entry).
  - `fileio_load_after_open` — extracted Steps 6-12 (SET_DMA → read loop → CLOSE → move_gap → cursor/dirty reset → status emit) as a top-level label entered by fall-through from BOTH `fileio_load` (post-OPEN success) and `fileio_load_initial` (via `JP fileio_load_after_open` — JR was out of range due to the three new Story-2.3 helpers between the sites).
- `fileio_compose_new_file_status` — new helper composes "<filename> [new file]\0" into the existing 48-byte `fileio_status_scratch` (Story 2.2 capacity holds: 15 + 11 + 1 = 27 ≤ 48).
- `fileio_setup_from_default_fcb` — new helper does 12-byte LDIR `DEFAULT_FCB → fcb_scratch`, 24-byte zero-fill at `fcb_scratch + 12`, FR9 translation (drive 0 → 2), then tail-JPs to `fileio_compose_filename_buffer`.
- `fileio_msg_new_file_suffix` — new DEFB " [new file]\0" in the module-local data block immediately after `fileio_msg_cant_open_prefix`.
- AR23 header updates: Public list grew by `fileio_load_initial`; "Architectural enforcement here" block documents the AR15 launch carve-out; Dependencies list gains explicit DEFAULT_FCB + BDOS_ENTRY notes; State-owned block updated to flag filename_buffer's launch-preservation contract.
- `src/init.asm` (modified): Stage 5 body swapped from `LD HL, msg_mode_normal ; XOR A ; CALL status_set_message` to `CALL fileio_load_initial` (which internally handles the msg_mode_normal seed on the no-arg path). Stage 5 contract block rewritten per AC13; Dependencies list grew by `src/fileio.asm`; DEFAULT_FCB header comment updated to reflect the Story-2.3 resolution.

**Key design / decision notes:**
- The AR15 launch carve-out is single-site (one `CALL BDOS_ENTRY` in `fileio_load_initial`), inline-annotated, and documented in the AR23 header. All other BDOS interactions on the launch path (SET_DMA / READ_SEQ / CLOSE inside `fileio_load_after_open`; the abort paths' CLOSE) continue to use the BDOS_CALL macro because their failure semantics align with the funnel's "JP input_loop" routing.
- The new-file branch's filename_buffer preservation is FR1/FR52/NFR6-load-bearing: Story 2.4's `:w` will read `filename_buffer` directly; without the preservation, `vibe newname.fs` → type content → `:w` would refuse with "no filename" and the user would lose work. AC4 + the headless test (`init_default-fcb-not-found.asm`) pin the contract.
- The dual-label `.done_parse: / fileio_compose_filename_buffer:` refactor avoided any code duplication or JR range concerns. Both labels EQU to the same address; sjasmplus accepts the consecutive-label-pair syntax.
- The AR15 launch carve-out's failure check `JP M` (not `JR M`) matches the macro's expansion exactly (3-byte JP for arbitrary range). Story 2.2's bdos_error_pre_msg override is NOT touched by the launch path (preserves the W8 stale-pointer invariant — the launch path is not a second writer).

**Pre-existing test-build hygiene fixes pulled forward (out of strict story scope but required for a clean regression net):**
- Story 2.1 left 3 dispatch_*.asm tests broken at build (label-not-found on exline_*); Story 2.2 added 5 broken exline_*.asm tests (fileio_*) and 6 broken gapbuf_*.asm tests (MODE_NORMAL). All 14 were quietly "passing" because sjasmplus's lax error mode emits .com files even on unresolved-label errors. Story 2.3 added the missing INCLUDEs (gapbuf.asm + exline.asm + fileio.asm where needed; modes.inc to gapbuf tests; init_teardown: RET stubs to dispatch tests). Logged the sjasmplus-lax-error-mode root-cause as a Makefile hardening follow-up in deferred-work.md.

**Size-budget observation (AC15 — over the proposed amended ceiling? No):**
- Post-2.3 footprint: 3235 B / ~105% of the original 3072 B NFR9 ceiling. Delta vs Story 2.2: +129 B (the AC15 projection was +130-180 B; actual is at the low end). Still below Ant's proposed 4096 B amended ceiling. The amend-NFR9 follow-up (deferred-work.md line 122) remains pending.

**Hardware UAT (AC14) deferred to user (Task 9):**
- Cannot SLIDE-push from this dev environment; requires `make push` + on-MicroBeast execution of the 10-step UAT script (`vibe foo.fs`, `vibe missing.fs`, `vibe a:test.fs`, `vibe huge.fs`, bare `vibe`, plus `:e bdos.txt` regression). Same pattern as Stories 1.11 / 1.12 / 2.1 / 2.2 — the user runs the hardware UAT before marking the story done.

### File List

**Files created:**
- `test/cases/init_default-fcb-no-arg.asm`
- `test/cases/init_default-fcb-loads-file.asm`
- `test/cases/init_default-fcb-drive-prefix.asm`
- `test/cases/init_default-fcb-not-found.asm`
- `test/cases/init_default-fcb-too-large.asm`

**Files modified (production):**
- `src/fileio.asm` — added `fileio_load_initial` (public entry) + `fileio_setup_from_default_fcb` + `fileio_compose_new_file_status` + `fileio_msg_new_file_suffix` (DEFB); refactored `fileio_parse_filename`'s `.done_parse` tail into the dual-label `fileio_compose_filename_buffer:` entry; refactored `fileio_load`'s Steps 6-12 into the shared `fileio_load_after_open:` label entered by fall-through from `fileio_load` and `JP` from `fileio_load_initial`; AR23 header gained `fileio_load_initial` in Public list, AR15 launch carve-out documentation in the "Architectural enforcement here" block, and explicit DEFAULT_FCB / BDOS_ENTRY dependency notes.
- `src/init.asm` — Stage 5 body swapped to `CALL fileio_load_initial`; Stage 5 contract block rewritten; Dependencies list adds `src/fileio.asm (fileio_load_initial — Story 2.3)`; DEFAULT_FCB header comment updated to reflect the Story-2.3 resolution.

**Files modified (test infrastructure — regression-net cleanup):**
- `test/cases/init_cold_start-state-shape.asm` — added INCLUDE chain for fileio.asm + exline.asm (AR25 order); pre-set `DEFAULT_FCB + 1 = ' '` for determinism per AC17.
- `test/cases/dispatch_binary-search-finds-key.asm` — added gapbuf.asm + exline.asm + fileio.asm INCLUDEs + local `init_teardown:` RET stub (pre-existing Story-2.1 build break).
- `test/cases/dispatch_binary-search-misses.asm` — same fix.
- `test/cases/dispatch_mode-transition.asm` — same fix.
- `test/cases/exline_bare-enter.asm` — added gapbuf.asm + fileio.asm INCLUDEs (pre-existing Story-2.2 build break).
- `test/cases/exline_q-bang-force.asm` — same fix.
- `test/cases/exline_q-clean-buffer.asm` — same fix.
- `test/cases/exline_q-dirty-buffer.asm` — same fix.
- `test/cases/exline_unknown-command.asm` — same fix.
- `test/cases/gapbuf_delete-at-bof.asm` — added modes.inc INCLUDE (pre-existing Story-2.2 build break).
- `test/cases/gapbuf_delete-mid.asm` — same fix.
- `test/cases/gapbuf_insert-empty.asm` — same fix.
- `test/cases/gapbuf_insert-fills-buffer.asm` — same fix.
- `test/cases/gapbuf_move-roundtrip.asm` — same fix.
- `test/cases/gapbuf_random-ops.asm` — same fix.
- `test/cases/parser_compose-count-op-motion.asm` — added gapbuf.asm + exline.asm + fileio.asm INCLUDEs + local `init_teardown:` RET stub (pre-existing Story-2.1 build break, same root cause as dispatch tests).
- `test/cases/parser_count-accumulator.asm` — same fix.
- `test/cases/parser_doubled-operator-dd.asm` — same fix.
- `test/cases/parser_leading-zero-is-motion.asm` — same fix.
- `test/cases/parser_motion-prefix-cleared-on-other-key.asm` — same fix.
- `test/cases/parser_motion-prefix-gg.asm` — same fix.
- `test/cases/parser_zero-after-digit.asm` — same fix.

**Files modified (project artifacts):**
- `_bmad-output/implementation-artifacts/deferred-work.md` — added "Deferred from: dev of story-2-3-launch-with-filename-argument (2026-05-13)" section with NFR9 footprint update, hardware UAT deferral, pre-existing test-build hygiene fixes pulled forward, sjasmplus lax-error-mode Makefile hardening follow-up, and the dual carve-out documentation pointer for the architecture doc; appended Story-2.3 status note under the Story-2.2 W8 entry (bdos_error_pre_msg invariant still holds — launch path does not introduce a second writer).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `2-3-launch-with-filename-argument: ready-for-dev → in-progress → review`.
- `_bmad-output/implementation-artifacts/2-3-launch-with-filename-argument.md` — Status → review; all Task / Sub checkboxes marked [x] except Task 9 hardware UAT (deferred); Dev Agent Record filled in.

### Change Log

| Date       | Change |
|------------|--------|
| 2026-05-13 | Story 2.3 implementation: `vibe FILENAME` from CCP now lands the launch-with-filename path via new `fileio_load_initial` in `src/fileio.asm` (read DEFAULT_FCB → no-arg short-circuit OR copy + FR9 translate + AR15 launch carve-out inline BDOS_OPEN → branch into shared `fileio_load_after_open` on success, `.new_file` banner with filename_buffer PRESERVED on open-fail, or fileio_abort_* on oversize/read-error). `src/init.asm` Stage 5 swapped from msg_mode_normal seed to `CALL fileio_load_initial`. Refactors extracted shared `fileio_compose_filename_buffer` (dual-label from `.done_parse`) and `fileio_load_after_open` (fall-through tail of `fileio_load`). 5 new headless tests cover all four `fileio_load_initial` branches. Build SHA `e3a422ab…0f3f8`, byte-identical second rebuild (NFR18), 41 pass / 1 deliberate fail under iz-cpm. Size 3235 B / ~105% (NFR9 amend pending per deferred-work.md:122). Pulled forward fixes for 14 pre-existing build-time-broken tests (dispatch / exline / gapbuf / parser — story-2.1 and story-2.2 INCLUDE-chain regressions that sjasmplus's lax error mode had been silently writing .com files for). Hardware UAT (AC14) deferred to user. Status → review. |
