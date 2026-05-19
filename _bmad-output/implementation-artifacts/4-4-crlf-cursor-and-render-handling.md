# Story 4.4: CRLF cursor + render handling (Option A — filter at render emit)

Status: ready-for-dev

<!-- Provenance: Theme A of _bmad-output/implementation-artifacts/deferred-work-triage-2026-05-19.md.
     Closes deferred entries:
       - L77 (1.11 review)  — render NUL / high-bit raw, desyncing shadow vs physical screen
       - L220 (2.5 review)  — motion_h / motion_l land cursor on CR in CRLF-imported files
       - L266 (2.6 review)  — motion_dollar lands cursor on CR in CRLF-terminated lines
     Q-A1 pinned to Option A (filter at render emit + motion CR clamps) by Ant 2026-05-19.
     Save semantics: bytes preserved verbatim (CRLF round-trip fidelity). -->

## Story

As a developer who edits files that were originally created or transferred on a PC (CRLF
line endings, possibly with NUL bytes or high-bit characters from a non-ASCII text editor),
I want `motion_h` / `motion_l` / `motion_dollar` to treat the CR (0x0D) byte before LF as a
line boundary like LF itself, and `render_emit_one_row` to render CR / NUL / high-bit bytes
as a visible space so the shadow buffer stays in sync with the physical screen across scroll
re-emits,
So that editing a CRLF-imported file doesn't strand the cursor on a phantom invisible CR
byte (which then makes `i<text>Esc` insert text BEFORE the CR — surfacing as a CRLFLF
sequence on save), and so the on-screen cursor position matches the logical buffer position
on every render path including the corruption-prone scroll-driven re-emit that Story 2.5's
UAT step 11 already partly addressed.

## Acceptance Criteria

**AC1 — `motion_h` clamps on CR like LF (backward motion CRLF tolerance).**

**Given** a buffer containing a CRLF-terminated line (e.g. `"abc\r\nxyz"`, cursor at offset
5 = the `\n` byte — already unreachable per the cursor-not-on-LF invariant; OR cursor at
offset 4 = the `\r` byte — REACHABLE today via `motion_l` from offset 3 because the existing
`motion_l` clamp only stops on LF, not CR)
**When** `h` is pressed (one step of `motion_h`)
**Then** the cursor walks backward from offset 4 (`\r`) toward offset 3 (`c`) — the existing
backward walk semantics. The new behaviour: if `motion_h`'s walk would speculatively DEC HL
onto a CR byte (which can only happen if the cursor was on the byte AFTER a CR, i.e. on LF
at offset 5 — unreachable today), the speculative DEC must `JR Z, .clamp_undo` like the LF
case. In practice, the CR clamp in `motion_h` is **structurally unreachable** in well-formed
buffers (cursor is never on LF) but is added for symmetry with `motion_l`'s forward clamp +
defense against future j-to-empty-CRLF-line paths.

**Hook implementation pattern** at `src/motions.asm:228-230` (motion_h backward walk):

```asm
    DEC     HL                          ; HL = cursor - 1 (candidate)
    CALL    motion_byte_at_logical      ; A = byte at HL; HL preserved
    CP      0x0A
    JR      Z, .clamp_undo              ; intra-line clamp: undo dec
    CP      0x0D                        ; Story 4.4 AC1: CR is line boundary
    JR      Z, .clamp_undo              ;   (CRLF tolerance, symmetric with motion_l)
```

Cost: +4 B per clamp site. The `.clamp_undo` path is unchanged (single INC HL + JR .done).

**AC2 — `motion_l` clamps on CR like LF (forward motion CRLF tolerance — the load-bearing
fix for L220).**

**Given** a buffer containing a CRLF-terminated line (e.g. `"abc\r\nxyz"`)
**When** `l` is pressed from cursor offset 2 (`c`)
**Then** the existing motion_l behaviour today walks 2→3 (the CR byte), then halts on the
next call because the destination LF stops it. After AC2: motion_l from offset 2 must clamp
in place (cursor stays at 2) because the destination at offset 3 is CR, which is now
recognized as a line boundary equivalent to LF.

Both clamp sites in `motion_l` (cursor-on-LF defensive guard at `src/motions.asm:292-293`,
destination-peek at `src/motions.asm:298-300`) get a parallel CR check:

```asm
    CALL    motion_byte_at_logical      ; A = byte at HL; CF=1 if HL >= file_length
    JR      C, .done                    ; HL == cursor (unchanged) → save as-is
    CP      0x0A
    JR      Z, .done                    ; on LF
    CP      0x0D                        ; Story 4.4 AC2: CR is line boundary
    JR      Z, .done                    ;   (CRLF tolerance)
    INC     HL
    CALL    motion_byte_at_logical
    JR      C, .clamp_undo
    CP      0x0A
    JR      Z, .clamp_undo
    CP      0x0D                        ; Story 4.4 AC2: CR is line boundary
    JR      Z, .clamp_undo
```

Cost: +8 B (4 B per clamp site × 2 sites). After AC2 lands, the cursor-on-CR position is
**unreachable from `motion_l`** — a CRLF-imported file's printable region for cursor
landing is exactly the same as the LF-only equivalent.

**Regression-pin coverage gap closes here:** Story 2.5 UAT step 11 fixed the RENDER side
(CR-as-space at `src/render.asm:1018-1038`); Story 4.4 AC2 closes the corresponding MOTION
side. Together they fully cover the CRLF case.

**AC3 — `motion_dollar` walks back past trailing CR (CRLF line-end fix — L266).**

**Given** a CRLF-terminated line (e.g. `"abc\r\n"`, cursor anywhere on the line)
**When** `$` is pressed
**Then** `motion_dollar` walks to `motion_find_line_end` (returns HL = offset of LF, e.g.
offset 4 in `"abc\r\n"`), does its existing `DEC HL` (HL = 3 = the CR byte), and the new
behaviour: if byte at HL is now `\r`, DEC HL once more so cursor lands on the last
PRINTABLE byte (offset 2 = `c`).

**Hook implementation pattern** at `src/motions.asm:1022-1024` (motion_dollar walk-back):

```asm
    ADD     HL, DE                      ; HL = eol
    DEC     HL                          ; HL = eol - 1 (last printable OR CR byte)
    CALL    motion_byte_at_logical      ; A = byte at HL; HL preserved
    CP      0x0D                        ; Story 4.4 AC3: trailing-CR skip (CRLF)
    JR      NZ, .commit
    DEC     HL                          ; HL = eol - 2 = last printable byte
.commit:
    LD      (cursor_offset), HL
```

Cost: ~+9 B (1 byte_at_logical call + CP + JR NZ + DEC + reshuffled label).
*Note: motion_byte_at_logical trashes DE per AR23 — but DE is no longer needed at this point
(it was used to compute eol-cursor delta, already consumed). Safe to call here.*

**Edge cases handled:**
- Empty line `"\r\n"` (offset 0 = `\r`): motion_find_line_end returns 1 (LF pos), DEC → 0
  (CR), CR check fires, DEC → 0xFFFF (underflow). MUST guard: if HL == 0 before the CR
  skip, leave HL unchanged (cursor stays at 0; line is empty for printable purposes).
  Add explicit `LD A, H ; OR L ; JR Z, .commit` between the CR check and the second DEC.
  Total cost revised: +11 B.
- LF-only line `"abc\n"` (no CR): DEC → 2 (`c`), CR check fails (byte is `c`, not CR),
  fall through to commit. Existing behaviour preserved.
- No-trailing-LF last line `"abc"`: motion_find_line_end returns file_length = 3, DEC → 2
  (`c`), CR check fails, commit. Existing behaviour preserved.

**AC4 — `render_emit_one_row` extends CR-as-space pattern to NUL + high-bit (L77 partial
close).**

**Given** a buffer containing NUL bytes (0x00) or high-bit characters (>= 0x80) — possible
in PC-imported files that aren't strict 7-bit ASCII
**When** `render_emit_one_row` walks the row
**Then** NUL bytes and high-bit bytes (>= 0x80) render as space (0x20), mirroring the
existing CR-as-space behaviour at `src/render.asm:1018-1038`. Shadow buffer is updated
with 0x20 in lock-step so the per-cell shadow vs physical-screen invariant holds across
subsequent scroll-driven re-emits (the same corruption pattern Story 2.5 step 11 fixed for
CR generalizes to NUL / high-bit).

**Hook implementation pattern** at `src/render.asm:1008-1038` (cell-target compute):

```asm
    CP      0x0A
    JR      Z, .hit_lf
    CP      0x0D
    JR      Z, .hit_cr                  ; Story 2.5 UAT step 11 (CR as space)
    CP      0x20                        ; Story 4.4 AC4: non-printable filter
    JR      C, .hit_nonprintable        ;   (NUL through 0x1F except CR/LF
                                        ;    handled above)
    BIT     7, A                        ; Story 4.4 AC4: high-bit filter
    JR      NZ, .hit_nonprintable       ;   (0x80..0xFF render as space too)
    ;; target = A; advance read_pos.
    INC     HL
    LD      (render_read_pos), HL
    JR      .have_target

.hit_nonprintable:
    ;; Same shape as .hit_cr: render as space, advance read_pos by 1,
    ;; do NOT set past_eol (a subsequent LF still needs .hit_lf
    ;; normally). Covers NUL (0x00), TAB (0x09 — see scope note below),
    ;; all other C0 controls except LF (0x0A) which is handled above,
    ;; and all 0x80..0xFF.
    INC     HL
    LD      (render_read_pos), HL
    LD      A, 0x20
    JR      .have_target
```

Cost: ~+12 B (4 byte check + branch + new label body partially shared with .hit_cr — dev
may consolidate `.hit_cr` and `.hit_nonprintable` into one label to save another ~5 B; left
to dev judgment at refactor time).

**TAB scope note.** TAB (0x09) IS in the `< 0x20` range and falls into `.hit_nonprintable`
under AC4. This is intentional for the corruption-safety contract (a raw TAB to a VT52
would advance the cursor by an indeterminate amount the shadow can't predict). It does
mean TAB-formatted files lose visual alignment in VIBE — the column-count semantics of TAB
are NOT preserved. Acceptable trade-off for Option A: the alternative (TAB-as-multi-cell
emit with shadow tracking) is the Option C scope which Ant explicitly rejected.

**AC5 — Save semantics preserve bytes verbatim (CRLF round-trip fidelity).**

**Given** a CRLF-imported file loaded into VIBE, edited (e.g. insert one character mid-line),
then saved
**When** the resulting on-disk file is inspected
**Then** every byte that was already in the buffer at save time is preserved EXACTLY —
including CR bytes between printable text and LF. Specifically:
- A file loaded as `"abc\r\nxyz\r\n"` (10 bytes), edited to insert `'X'` at offset 1, saved
  back, comes off disk as `"aXbc\r\nxyz\r\n"` (11 bytes) — CR bytes preserved at their
  pre-edit positions
- An LF-only file loaded as `"abc\nxyz\n"` (8 bytes), edited identically, saves as
  `"aXbc\nxyz\n"` (9 bytes) — no spurious CR injection

`fileio_save` does NOT receive any changes under Story 4.4 — it walks `gap_start` /
`gap_end` and emits the gap-buffer bytes verbatim. AC5 is an **invariant assertion**
(pinned by a regression test) that the AC1-AC4 changes do not accidentally introduce a
write-side modification.

**AC6 — NFR9 size budget honored.**

**Given** Story 4.4's projected delta is +4 B (AC1) + +8 B (AC2) + +11 B (AC3) + +12 B
(AC4) = **+35 B mid-estimate** (range +35..+39 B depending on whether Lever 2's high-bit
filter is in or out)
**When** `make sizes` is captured after Story 4.4 lands
**Then** `vibe.com` sits within `8562 B + 35 B ± 30 B drift = 8567..8627 B`, well within
the 10240 B NFR9 ceiling (post-4.4 projected headroom: ~1613-1673 B vs the 1678 B post-4.2
baseline)
**And** the listing is captured in the Dev Agent Record with the actual size + percentage
delta against the 10240 B ceiling.

**Per [[project_nfr9_cliff_edge]]:** add +50-100 B drift pad to the mid-estimate when
projecting. Adjusted: 35 + 50..100 = 85..135 B → post-4.4 `vibe.com` ≈ 8647..8697 B /
~84.5% / ~1543-1593 B headroom. Comfortably above the 1000 B-headroom convention.

**Shrink-down levers if needed:**
- Lever 1: consolidate `.hit_cr` and `.hit_nonprintable` in render.asm into a single label
  (saves ~5 B by sharing the INC HL + LD A, 0x20 + JR .have_target tail).
- Lever 2: drop the AC4 high-bit check if NFR9 pressure spikes (NUL/control filter alone
  closes L77's most-cited corruption case; high-bit is rarer in practice). Saves ~4 B.
- Lever 3: motion_h's CR clamp is structurally unreachable today (per AC1) — can be deferred
  to a future story if NFR9 pressure dictates. Saves ~4 B but breaks the symmetry argument.

**AC7 — NFR18 byte-identical rebuild held.**

**Given** NFR18 byte-identical rebuild
**When** the tree is built clean twice after Story 4.4 lands (`make clean && make all` × 2)
**Then** both `vibe.com` SHA-256 digests match
**And** the SHA is recorded in the Dev Agent Record / Completion Notes List for future
regression reference.

**AC8 — Hardware UAT on real MicroBeast with a CRLF-imported fixture.**

**Given** UAT on hardware (Feersum MicroBeast + serial-attached terminal)
**When** the dev runs the 9-step UAT script (paste inline at dev-handoff per
[[feedback_uat_inline_at_dev_handoff]] — see "Hardware UAT script" section below)
**Then** all 9 steps behave per the AC narrative without cursor drift, on-screen vs logical
divergence, or save-side corruption.

The UAT requires a **CRLF-imported test fixture** transferred to MicroBeast SD via the
standard transfer flow:
1. On the dev host, create `crlftest.txt` with explicit CRLF line endings via
   `printf 'abc\r\ndef\r\nghi\r\n' > crlftest.txt`. Confirm with
   `od -An -c crlftest.txt | head` shows `\r \n` pairs.
2. Transfer to MicroBeast SD via the standard CP/M file-transfer method.
3. Run UAT against `vibe crlftest.txt`.

**AC9 — 4 new regression tests pin the AC1-AC5 contract.**

**Given** the test-only AC4 / hardware-UAT-only AC8 paths
**When** Story 4.4 lands
**Then** four new test files in `test/cases/` headlessly pin the load-bearing behaviours:

| Test filename                                | Pins   | Sentinel |
|----------------------------------------------|--------|----------|
| `motions_l-clamps-at-cr-byte.asm`            | AC2    | new (PM picks from 4.4 band) |
| `motions_dollar-crlf-skips-cr.asm`           | AC3    | new |
| `render_emits-nonprintable-as-space.asm`     | AC4    | new |
| `fileio_save-crlf-roundtrip.asm`             | AC5    | new |

`motions_l-clamps-at-cr-byte.asm` template: copy `test/cases/motions_l-clamps-at-eol.asm`,
construct a buffer `"abc\r\n"` (5 bytes) via direct LDIR into GAP_BUFFER_BASE, advance
gap_start to GAP_BUFFER_BASE+5, set cursor_offset = 2 (`c`), call motion_l, assert
cursor_offset == 2 (unchanged — CR clamp fired). Subtest 2: with file_length matching the
CR-only case (`"abc\r"` — no LF), motion_l from offset 2 still clamps at 2 since CR alone
is now treated as line boundary.

`motions_dollar-crlf-skips-cr.asm` template: copy `motions_dollar-mid-line.asm`. Buffer
`"abc\r\ndef"` (8 bytes), cursor=0, call motion_dollar, assert cursor_offset == 2 (`c`,
NOT 3 = CR). Subtest 2: empty CRLF line `"\r\nxyz"` cursor=0, motion_dollar leaves cursor
at 0 (the empty-line clamp).

`render_emits-nonprintable-as-space.asm` template: new file; construct a buffer with NUL +
0x80 + 0xFF bytes interspersed with printable, call render_full or render_diff with a
BIOS_CONOUT capture stub, assert the captured byte stream substitutes 0x20 at each
non-printable position AND shadow_buffer[row*80+col] == 0x20 at those positions.

`fileio_save-crlf-roundtrip.asm` template: copy `test/cases/fileio_save-empty-buffer.asm`.
Construct gap buffer `"abc\r\nxyz\r\n"` (10 B), call fileio_save targeting B:CRLF.TXT,
re-open via BDOS_OPEN + read sector 0, assert the on-disk first 10 bytes match the gap
exactly (CRs preserved at offsets 3, 8 — between printable text and LF). This is the
**Option A round-trip-fidelity regression-pin** — if a future story accidentally
canonicalizes on save, this test fails immediately.

## Tasks / Subtasks

- [ ] **Task 0 — Cross-check + Q-pin resolution (per [[feedback_create_story_cross_check]])**
  - [ ] 0.1 Verify pre-state: `make sizes` reports the pre-4.4 baseline (post-4.3 — see
    note: 4.3 is test-only with NFR18 byte-identical, so pre-4.4 baseline = post-4.2
    baseline 8562 B / 83.6% / 1678 B headroom IFF 4.3 has landed cleanly). If 4.3 is still
    in-flight, pre-4.4 baseline IS 8562 B exactly.
  - [ ] 0.2 Confirm Q-pin choices (settled by Ant at story scoping; flagged here for the
    dev pass to double-check):
    - **Q-A1**: Filter at render emit (Option A). Adopted.
    - **Q-A2** (cursor landing on CR): CR treated as line boundary equivalent to LF —
      AC1/AC2/AC3 all clamp on CR. Follows naturally from Option A; no separate Q.
    - **Q-A3** (save semantics): bytes preserved verbatim (CRLF round-trip fidelity per
      AC5). Follows naturally from Option A; no save-side code touched.
  - [ ] 0.3 Confirm pre-4.4 `make test` baseline: `(272 + 7)` if 4.3 has landed, else 272.
    Story 4.4 adds 4 new tests → post-4.4 target is `(pre + 4)` PASS.

- [ ] **Task 1 — AC1: motion_h CR clamp** (AC: #1)
  - [ ] 1.1 At `src/motions.asm:228-230` (motion_h backward walk), add `CP 0x0D ; JR Z,
    .clamp_undo` immediately after the existing `CP 0x0A ; JR Z, .clamp_undo`. +4 B.
  - [ ] 1.2 Update motion_h's AR23 docstring (`src/motions.asm:112-120`) to note CR is
    treated as line boundary alongside LF.
  - [ ] 1.3 No new test required — the CR clamp in motion_h is structurally unreachable in
    well-formed buffers (cursor never lands on LF or CR). The change is symmetry +
    future-proofing against a j-to-empty-CRLF-line path.

- [ ] **Task 2 — AC2: motion_l CR clamp (load-bearing)** (AC: #2)
  - [ ] 2.1 At `src/motions.asm:292-293` (motion_l cursor-on-LF defensive guard), add `CP
    0x0D ; JR Z, .done` immediately after the existing LF check. +4 B.
  - [ ] 2.2 At `src/motions.asm:299-300` (motion_l destination-peek), add `CP 0x0D ; JR Z,
    .clamp_undo` immediately after the existing LF check. +4 B.
  - [ ] 2.3 Update motion_l's AR23 docstring (`src/motions.asm:251-279`) to note the CR
    clamp; specifically extend the "intra-line EOL" bullet to read "intra-line EOL: byte
    at cursor_offset + 1 is 0x0A OR 0x0D (CRLF tolerance) → stop."
  - [ ] 2.4 Create `test/cases/motions_l-clamps-at-cr-byte.asm` per AC9 template.

- [ ] **Task 3 — AC3: motion_dollar trailing-CR walkback** (AC: #3)
  - [ ] 3.1 At `src/motions.asm:1022-1024` (motion_dollar walk-back after DEC HL), insert
    the CR check + empty-line guard per AC3's hook pattern:

    ```asm
        ADD     HL, DE                      ; HL = eol
        DEC     HL                          ; HL = eol - 1
        ;; Story 4.4 AC3: trailing-CR walkback (CRLF tolerance).
        ;; If byte at HL is CR, DEC once more — but guard against
        ;; underflow if the line is just `\r\n` (HL == 0 here).
        LD      A, H
        OR      L
        JR      Z, .commit
        CALL    motion_byte_at_logical      ; A = byte at HL
        CP      0x0D
        JR      NZ, .commit
        DEC     HL
    .commit:
        LD      (cursor_offset), HL
    ```

    +11 B. *Verify the `motion_byte_at_logical` call doesn't trash registers needed
    downstream — at this point only HL matters; A/F/DE are scratch per the existing
    motion_dollar contract.*
  - [ ] 3.2 Update motion_dollar's AR23 docstring (`src/motions.asm:991-1004`) to note the
    CR walkback: "On CRLF-terminated lines (e.g. `"abc\r\n"`), DEC HL twice (once for LF
    skip, once for CR skip) so cursor lands on the last printable byte."
  - [ ] 3.3 Create `test/cases/motions_dollar-crlf-skips-cr.asm` per AC9 template.

- [ ] **Task 4 — AC4: render_emit_one_row non-printable filter** (AC: #4)
  - [ ] 4.1 At `src/render.asm:1008-1038` (cell-target compute in render_emit_one_row),
    add the non-printable + high-bit checks per AC4's hook pattern. New label
    `.hit_nonprintable` shares the body shape of `.hit_cr` — dev may consolidate to save
    ~5 B per Lever 1.
  - [ ] 4.2 Update the AR23 docstring for render_emit_one_row at `src/render.asm:949-970`
    to extend the existing CR-as-space note to cover NUL / control / high-bit.
  - [ ] 4.3 Create `test/cases/render_emits-nonprintable-as-space.asm` per AC9 template.

- [ ] **Task 5 — AC5: save round-trip regression-pin** (AC: #5)
  - [ ] 5.1 Create `test/cases/fileio_save-crlf-roundtrip.asm` per AC9 template. No
    production code changes — `fileio_save` is invariant under Story 4.4; this test pins
    that invariant against future-story drift.

- [ ] **Task 6 — AC6: NFR9 size verification** (AC: #6)
  - [ ] 6.1 `make sizes` after Tasks 1-5 land; capture the listing verbatim.
  - [ ] 6.2 Confirm `vibe.com` is within `8588..8648 B` projected range (or `8668..8718 B`
    with drift pad). At least 1000 B residual headroom under 10240 B ceiling.
  - [ ] 6.3 If actual size > 8718 B (yellow zone) or > 9240 B (red zone), apply Lever 1
    (consolidate render labels) then Lever 2 (drop high-bit check) per AC6's shrink-down
    section.

- [ ] **Task 7 — AC7: NFR18 byte-identical rebuild** (AC: #7)
  - [ ] 7.1 `make clean && make all` × 2; capture `vibe.com` SHA-256 both times.
  - [ ] 7.2 Verify SHAs match (NFR18); record in Completion Notes List.

- [ ] **Task 8 — AC8: Hardware UAT** (AC: #8)
  - [ ] 8.1 Paste UAT script inline at dev-handoff per
    [[feedback_uat_inline_at_dev_handoff]]; see "Hardware UAT script" section below.
  - [ ] 8.2 Generate `crlftest.txt` fixture: `printf 'abc\r\ndef\r\nghi\r\n' > crlftest.txt`.
    Confirm CRLF bytes via `od -An -c crlftest.txt | head`.
  - [ ] 8.3 Transfer to MicroBeast SD; run the 9-step UAT; capture observations.

- [ ] **Task 9 — `make test` regression check** (AC: #9)
  - [ ] 9.1 `make test`; capture per-case PASS/FAIL.
  - [ ] 9.2 Verify the 4 new tests all PASS; no existing test regresses.
  - [ ] 9.3 Per-AC pin-to-test map for diagnosis:
    - AC2 fail → `motions_l-clamps-at-cr-byte.asm` (check 0x0D vs 0x0A confusion in motion_l
      patch)
    - AC3 fail → `motions_dollar-crlf-skips-cr.asm` (check empty-line guard at HL==0)
    - AC4 fail → `render_emits-nonprintable-as-space.asm` (check `.hit_nonprintable` body
      mirrors `.hit_cr` exactly)
    - AC5 fail → `fileio_save-crlf-roundtrip.asm` (would indicate accidental save-side
      modification — should NEVER fail since fileio_save isn't touched)

- [ ] **Task 10 — Commit + close**
  - [ ] 10.1 Stage all modified/new files:
    - `src/motions.asm` (AC1+AC2+AC3 — 3 patch sites + AR23 doc updates)
    - `src/render.asm` (AC4 — 1 patch site + AR23 doc update)
    - 4 new `test/cases/*.asm` files per AC9
    - `_bmad-output/implementation-artifacts/deferred-work.md` (3 closure annotations:
      L77, L220, L266)
    - `_bmad-output/implementation-artifacts/4-4-crlf-cursor-and-render-handling.md`
      (Dev Agent Record + Completion Notes filled in)
    - `_bmad-output/implementation-artifacts/sprint-status.yaml` (status update)
  - [ ] 10.2 Commit message: `Story 4.4: CRLF cursor + render handling (Option A) —
    closes L77/L220/L266`
  - [ ] 10.3 Update sprint-status.yaml: flip
    `4-4-crlf-cursor-and-render-handling: ready-for-dev` → `review` post-dev; flip to `done`
    after Ant accepts the hardware UAT.

## Dev Notes

### Architecture compliance

- **AR12 (status funnel):** zero new direct call sites. AC1-AC4 changes are all inside
  motions / render which never call `status_set_message`.
- **AR13 (BIOS_CONOUT):** unchanged. AC4's `.hit_nonprintable` body emits via
  `render_emit_byte` (existing path); render.asm remains the sole BIOS_CONOUT executor.
- **AR14 (gap_start / gap_end WRITES):** unchanged. motion_h / motion_l / motion_dollar are
  read-only on gap state; render_emit_one_row is read-only on gap state.
- **AR15 (BDOS_CALL):** unchanged. Zero new fileio touches; AC5 is a read-side regression
  pin via the existing fileio_save path.
- **AR23 (per-module headers):** EXTENDS the docstrings on `motion_h`, `motion_l`,
  `motion_dollar`, and `render_emit_one_row` to note CR / non-printable handling. The
  module-level AR23 blocks at `src/motions.asm:39-99` and `src/render.asm:1-170` don't need
  changes (no new public symbols).
- **AR25 (INCLUDE order):** UNCHANGED. No new INCLUDEs.
- **MC1 (caller-saved register convention):** UNCHANGED. AC1-AC4 patches all preserve the
  existing per-function register contract.
- **MC4 (handler signature):** UNCHANGED. The motions still take A=key (ignored) and exit
  via parser_clear tail-JP.
- **MC5 (status-message funnel):** UNCHANGED. No new strings.
- **MC7 (static memory map):** UNCHANGED. No new state cells.
- **RI1-RI4 (render invariants):** UNCHANGED. AC4's non-printable filter follows the exact
  same shadow-update pattern as the existing `.hit_cr` body — shadow buffer stays in sync.
- **NFR1 (incremental render):** UNCHANGED. AC4 doesn't change WHICH cells emit; only WHAT
  byte is emitted for non-printable source bytes.
- **NFR3 (cursor latency):** UNCHANGED at user-perceivable scale. Per-cell cost in
  render_emit_one_row grows by ~4 T-states (one extra CP + JR per cell); at 80 cells × 23
  rows × ~4 T-states = ~7360 T-states ≈ ~1.8 ms additional per full-screen render. Below
  perception threshold; well under NFR3's per-keystroke ceiling.
- **NFR5 (no crashes):** UNCHANGED. AC3's HL==0 underflow guard is the only crash-adjacent
  edge; explicitly handled. AC4's `.hit_nonprintable` body mirrors the proven `.hit_cr`
  body shape.
- **NFR9 (code size):** +56 B mid-estimate (+106..156 B with drift pad). See AC6.
- **NFR18 (byte-identical rebuild):** UNCHANGED — no `INCBIN` or host-state dependencies
  introduced.

### Files this story modifies (and what to preserve)

**`src/motions.asm`** (currently ~1500+ lines):
- AMEND motion_h backward walk at line 229 — add `CP 0x0D ; JR Z, .clamp_undo` (+4 B).
- AMEND motion_l cursor-on-LF guard at line 292 — add `CP 0x0D ; JR Z, .done` (+4 B).
- AMEND motion_l destination-peek at line 299 — add `CP 0x0D ; JR Z, .clamp_undo` (+4 B).
- AMEND motion_dollar walk-back at line 1023 — insert CR check + HL==0 guard (+11 B).
- AMEND AR23 docstrings for motion_h / motion_l / motion_dollar to note CR handling.
- PRESERVE: every other line. The motion_w / motion_b / motion_0 / motion_gg / motion_G
  handlers are NOT touched by Story 4.4 — they use motion_find_line_start /
  motion_find_line_end which already locate LFs; whether they should ALSO locate CRs is a
  future-story question (deferred entry once Story 4.4 ships and we have CRLF UAT data).

**`src/render.asm`** (currently ~1320 lines):
- AMEND `render_emit_one_row` cell-target compute at line 1008-1011 — add `CP 0x20 ; JR C,
  .hit_nonprintable` + `BIT 7, A ; JR NZ, .hit_nonprintable` after the existing CR check.
- ADD new label `.hit_nonprintable` between `.hit_cr` (line 1018) and `.hit_lf` (line 1040)
  with the same body shape as `.hit_cr` (advance read_pos, emit space target, do NOT set
  past_eol).
- AMEND AR23 docstring for `render_emit_one_row` to note the extended non-printable filter.
- PRESERVE: `render_full`, `render_diff`, `render_init`, `render_byte_at_logical`,
  `render_emit_byte`, `render_emit_goto`, and all motion / cursor helpers — they're invariant
  under Story 4.4.

**4 new files under `test/cases/`** per AC9:
- `motions_l-clamps-at-cr-byte.asm`
- `motions_dollar-crlf-skips-cr.asm`
- `render_emits-nonprintable-as-space.asm`
- `fileio_save-crlf-roundtrip.asm`

Each follows the standard test layout enforced by the harness (test_prologue → body →
test_teardown_stub → test_epilogue → production INCLUDEs in AR25 order → state.inc LAST).

### Implementation choices and trade-offs

**Choice 1 (Q-A1): Option A — filter at render emit + motion CR clamps.**
- **Adopted.** Smallest scope, backward-compatible, preserves CRLF round-trip fidelity.
- Trade-off: doesn't display the CR byte to the user (it shows as a space) — but the
  cursor can never land on it, so the user has no need to see it. The bytes are still
  there in the buffer + on save.
- Rejected alternatives:
  - **Option B (canonicalize on load):** would simplify motions but breaks round-trip
    fidelity (CRLF → LF lossy save). Ant rejected at scoping.
  - **Option C (vi-style ^X notation):** largest scope, ~80-120 B NFR9 hit, requires
    motion semantics to track visual-width vs byte-position. Ant rejected at scoping.

**Choice 2 (Q-A2): CR treated as line boundary.**
- **Adopted.** Follows naturally from Option A. motion_h / motion_l / motion_dollar all
  clamp on CR symmetric to LF.
- Trade-off: the cursor cannot be positioned on a CR byte. For a CRLF-imported file, the
  rightmost reachable column on a line is the last printable byte before CR — exactly
  what the user would expect from a vi-like editor on a CRLF file.

**Choice 3 (Q-A3): Save preserves bytes verbatim.**
- **Adopted.** No fileio_save changes; the existing gap-buffer-walk emit is invariant.
  AC5's regression-pin test guards against accidental future drift.

**Choice 4: Story 4.4 scope explicitly excludes word/line motions (motion_w / motion_b /
motion_gg / motion_G).**
- These use `motion_find_line_start` / `motion_find_line_end` which look for LF. Whether
  they ALSO need CR clamps depends on real-world usage — does `w` skip past CR like
  whitespace? Probably yes (`is_word_char` returns false for CR — it's < 0x20). Does `gg`
  need to know about CR? No (line counting is LF-based; CR is just a byte in the line).
- **Adopted scope:** the 3 motions named in the source deferrals (L220 + L266). Word/line
  motions get a deferred-work entry post-4.4 if hardware UAT surfaces a problem.

**Choice 5: AC4 includes high-bit filter (BIT 7).**
- **Adopted.** ~4 B for a corruption-safety guarantee that aligns with L77's original
  "TAB / CR / NUL / high-bit" scope.
- Trade-off: a PC-imported text file with non-ASCII bytes (e.g. `0xA0` non-breaking space,
  curly quotes 0x91-0x94, etc.) shows those as spaces instead of garbage characters. This
  is an improvement, not a regression — the alternative (raw emit) corrupts the shadow vs
  physical screen invariant on scroll re-emit.
- Lever 2 (AC6) allows dropping this if NFR9 dictates; the NUL filter alone closes the
  load-bearing L77 case.

### Implementation Questions (resolve with Ant before dev starts)

All three Qs settled at story scoping (2026-05-19). Flagged here for the dev pass to
double-check in case Ant changed his mind.

**Q-A1 (CR/CRLF policy):** Option A — filter at render emit + motion CR clamps. ✓ pinned.
**Q-A2 (cursor landing on CR):** treat CR as line boundary equivalent to LF. ✓ pinned via
Option A consequence.
**Q-A3 (save semantics):** preserve bytes verbatim (CRLF round-trip fidelity). ✓ pinned via
Option A consequence.

If Ant has changed his mind on any of these, stop at Task 0 and re-scope.

### NFR9 budget arithmetic (worked example)

Pre-4.4 baseline: `vibe.com = 8562 B / 83.6% of 10240 B / 1678 B headroom` (post-4.2; 4.3
is byte-identical so this holds whether 4.3 has landed or not).

Mid-estimate delta breakdown:
| Patch                                            | Estimate |
|--------------------------------------------------|----------|
| AC1 — motion_h CR clamp                          | +4 B     |
| AC2 — motion_l CR clamp (2 sites)                | +8 B     |
| AC3 — motion_dollar trailing-CR walkback + guard | +11 B    |
| AC4 — render_emit_one_row non-printable filter   | +12 B    |
| AC4 — high-bit BIT 7 check (Lever 2 droppable)   | +4 B (already counted above; isolatable for shrink) |
| AR23 docstring updates                           | +0 B (comment-only) |
| **Total mid-estimate**                           | **+35-39 B** |

With +50-100 B drift pad (per [[project_nfr9_cliff_edge]]): +85..139 B → post-4.4
`vibe.com` ≈ 8647..8701 B / ~84.5%-85% / ~1539-1593 B headroom. Comfortably within ceiling.

Per Story 4.1 dev-pass discipline: dev MUST verify actual `vibe.com` size at Task 6; if
actual > 8800 B, apply Lever 1 (consolidate render labels) before commit.

### Test count target

**Pre-Story-4.4 baseline:** 272 pass / 1 deliberate-fail (if 4.3 not yet landed) OR 279
pass / 1 deliberate-fail (if 4.3 landed).

**Post-Story-4.4 target:** `(pre + 4)` pass / 1 deliberate-fail. Delta = +4 PASSes
(motions_l-clamps-at-cr-byte, motions_dollar-crlf-skips-cr,
render_emits-nonprintable-as-space, fileio_save-crlf-roundtrip).

### Project Structure Notes

- All production-code changes are inside existing files (`src/motions.asm`,
  `src/render.asm`). No new `.asm` files in `src/`.
- All test files live under `test/cases/` per existing convention.
- The triage doc's recommendation also mentioned `src/fileio.asm` MIGHT be touched under
  Option B (canonicalize on load). **Under Option A, `src/fileio.asm` is UNTOUCHED.** If
  the dev pass finds itself editing fileio.asm, stop — that means the Q-A1 pin has been
  violated.

### References

- Source deferrals: `_bmad-output/implementation-artifacts/deferred-work.md`:77, 220, 266
  (the three converging entries that Theme A scopes).
- Triage scoping: `_bmad-output/implementation-artifacts/deferred-work-triage-2026-05-19.md`
  Theme A (lines 116-149) — the policy-call story.
- Story 2.5 UAT step 11 fix (the existing CR-as-space render code that AC4 extends):
  `src/render.asm:1018-1038` + the post-2.5 retrospective.
- Motion implementations:
  - `src/motions.asm:215-244` (motion_h)
  - `src/motions.asm:280-316` (motion_l)
  - `src/motions.asm:1006-1027` (motion_dollar)
- Render cell-target compute: `src/render.asm:995-1056` (render_emit_one_row).
- Template tests to copy:
  - `test/cases/motions_l-clamps-at-eol.asm` (AC2 template)
  - `test/cases/motions_dollar-mid-line.asm` (AC3 template)
  - `test/cases/fileio_save-empty-buffer.asm` (AC5 template — BDOS round-trip pattern)

### Memory hooks (from [[memory]])

- **[[project_nfr9_cliff_edge]]** — NFR9 amended 8192 → 10240 B at Epic-4 entry; post-3.8
  baseline 8179 B; ~2060 B headroom. Story 4.4's +35-39 B mid-estimate is well within.
- **[[feedback_create_story_cross_check]]** — cross-check AC narrative against actual
  render/edit semantics before handoff. Done above (CR clamp sites verified against
  `src/motions.asm:215-316`, motion_dollar walkback verified against
  `src/motions.asm:1006-1027`, render path verified against `src/render.asm:995-1056`).
- **[[feedback_uat_inline_at_dev_handoff]]** — paste hardware UAT script verbatim at
  dev-handoff. Done below.
- **[[feedback_uat_trace_cursor]]** — UAT scripts trace cursor explicitly. Done below.

## Hardware UAT script (AC8 — paste into chat at dev-handoff per
[[feedback_uat_inline_at_dev_handoff]])

**Pre-UAT setup:**

1. On dev host: `printf 'abc\r\ndef\r\nghi\r\n' > crlftest.txt`. Verify with
   `od -An -c crlftest.txt | head` — expect `a b c \r \n d e f \r \n g h i \r \n`,
   15 bytes total.
2. Transfer `crlftest.txt` to MicroBeast SD via standard transfer flow. `DIR B:` should
   show `CRLFTEST.TXT` (CP/M reports the file rounded to its sector allocation, e.g. 1
   sector = 128 B — that's expected).
3. Boot VIBE with `vibe crlftest.txt`.

**Reference buffer layout** (15 bytes, used by every step below):

| Offset  | 0 | 1 | 2 | 3  | 4  | 5 | 6 | 7 | 8  | 9  | 10| 11| 12| 13 | 14 |
|---------|---|---|---|----|----|---|---|---|----|----|---|---|---|----|----|
| Byte    | a | b | c | \r | \n | d | e | f | \r | \n | g | h | i | \r | \n |

**UAT Steps (9):**

1. **Initial render.** Screen shows `abc` on row 1, `def` on row 2, `ghi` on row 3; blank
   rows 4-23. Cursor at internal (row 0, col 0) = user-facing (1, 1). The CR bytes at
   offsets 3 / 8 / 13 render as spaces (AC4); the shadow at row N col 3 holds 0x20, not
   the CR byte. **PASS:** screen identical to an LF-only `abc\ndef\nghi\n` would display.

2. **`l`** (cursor was at offset 0 = `a`). Cursor moves to offset 1 = `b`. No CR adjacent
   — existing behaviour.

3. **`l`** (now at offset 1 = `b`). Cursor moves to offset 2 = `c`. **AC2 trace point:**
   the NEXT `l` should be clamped — destination at offset 3 is CR, which AC2 makes a
   line-boundary equivalent.

4. **`l`** (attempt to advance past `c`). Cursor STAYS at offset 2 = `c`. **PASS for
   AC2:** cursor did NOT move to offset 3 (the CR position). Pre-4.4 behaviour would have
   allowed the advance.

5. **`j` then `$`.** `j` drops cursor to row 2 col 1 = offset 5 = `d`. `$` walks
   motion_find_line_end → LF at offset 9 → DEC → 8 (CR) → AC3 walkback DEC → 7 (`f`).
   **PASS for AC3:** cursor lands at offset 7 = `f` (row 2 col 3), NOT offset 8 (the CR
   position). Pre-4.4 behaviour landed on CR.

6. **`i X Esc`** (insert `X` at cursor offset 7). Buffer becomes 16 bytes:
   `abc\r\ndeXf\r\nghi\r\n` — `X` inserted at offset 7, shifting original offset 7+ right
   by 1. After Esc, cursor lands on offset 7 = `X` (vi-faithful: Esc steps cursor back 1
   from post-insert position 8). Screen row 2 shows `deXf`. **PASS:** insert landed
   between `e` and the original `f`; no visible CR appeared at any column.

7. **`:w Enter`.** Status banner reads `B:CRLFTEST.TXT 16 bytes written` (15 original + 1
   inserted = 16). **PASS for AC5:** byte count is 16 — all 3 CRs preserved. A broken
   save that stripped CRs would report 13.

8. **`:q Enter`.** Back at CP/M prompt.

9. **Off-VIBE verification (the binding AC5 / AC8 pin).** Transfer `crlftest.txt` back to
   the dev host (or `TYPE CRLFTEST.TXT` on CP/M with a serial capture). Run
   `od -An -c crlftest.txt | head`. **PASS:** output reads `a b c \r \n d e X f \r \n g h
   i \r \n` — 16 bytes, CRs preserved at offsets 3 / 8 / 13 (one position shifted from
   pre-edit because of the insert at offset 7), `X` at offset 7 between original `e` and
   `f`. A broken save shows missing `\r` bytes OR a different byte count.

**FAIL diagnosis:**
- Step 4 cursor advanced to offset 3: AC2 patch broken; check `src/motions.asm:299-300`
  for missing `CP 0x0D ; JR Z, .clamp_undo`.
- Step 5 cursor lands at offset 8: AC3 patch broken; check `src/motions.asm:1023-1027`
  for missing CR walkback + HL==0 guard.
- Step 7 banner reports byte count != 16: investigate. If 13 (= 15 - 2 missing CRs), AC5
  invariant broken — `fileio_save` was accidentally modified; revert and re-verify.
  If something else, capture the actual banner + run step 9 to inspect on-disk shape.
- Step 9 CRs missing from output: same diagnosis as Step 7's "13 byte" branch.

## Dev Agent Record

### Agent Model Used

(to be filled in by dev pass — e.g. `claude-opus-4-7[1m]`)

### Debug Log References

(to be filled in by dev pass)

### Completion Notes List

(to be filled in by dev pass; required entries:)
- `make sizes` post-4.4 snapshot — actual size + percentage delta against 10240 B ceiling
- `make sizes` pre-4.4 baseline (8562 B / 83.6% / 1678 B headroom OR post-4.3 equivalent
  if 4.3 has landed)
- `sha256sum build/vibe.com` post-4.4 (recorded twice via `make clean && make all` × 2
  per AC7)
- `make test` PASS/FAIL count delta — target +4 PASS over the pre-4.4 baseline
- Hardware UAT step 9 actual observed on-disk byte count + the CR-preservation
  confirmation

### File List

(to be filled in by dev pass; expected fileset per Task 10.1)

## Change Log

| Date       | Author | Change                                                                       |
|------------|--------|------------------------------------------------------------------------------|
| 2026-05-19 | Amelia | Story 4.4 scoped from Theme A of `deferred-work-triage-2026-05-19.md`. Q-A1 pinned to Option A (filter at render emit + motion CR clamps) by Ant 2026-05-19. Closes deferred entries L77/L220/L266. Production-code delta projected at +35-39 B. Ready for dev. |
