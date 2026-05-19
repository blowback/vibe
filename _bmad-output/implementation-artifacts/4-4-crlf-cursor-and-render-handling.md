# Story 4.4: CRLF cursor + render handling (Option A — filter at render emit)

Status: done

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
  Total cost revised: **+12 B** (post-review reconciliation 2026-05-19 — original
  spec wrote +11 B but `LD A,H` + `OR L` + `JR Z` + `CALL` + `CP 0x0D` + `JR NZ`
  + `DEC HL` = 1+1+2+3+2+2+1 = 12 B; the +1 B is harmless within the AC6 drift
  pad. After review patch the walkback became a 2-byte JR loop so the cost
  grew by +2 B more — see Review Findings section).
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

**Hook implementation pattern** at `src/render.asm:1008-1038` (cell-target compute).

**Post-implementation note (Story 4.4 review 2026-05-19):** Lever 1 was adopted —
`.hit_nonprintable` was merged into `.hit_cr` (the body shape is identical, and the
Story 2.5 attribution narrative + the Story 4.4 generalisation now share one comment
block). The hook pattern below describes the pre-consolidation design; in the
shipped code, both `JR C, ...` and `JR NZ, ...` target `.hit_cr` directly. The
0x7F (DEL) byte case was also added in review.

```asm
    CP      0x0A
    JR      Z, .hit_lf
    CP      0x0D
    JR      Z, .hit_cr                  ; Story 2.5 UAT step 11 (CR as space)
    CP      0x20                        ; Story 4.4 AC4: non-printable filter
    JR      C, .hit_cr                  ;   (NUL through 0x1F except CR/LF
                                        ;    handled above — merged into
                                        ;    .hit_cr per Lever 1)
    CP      0x7F                        ; Story 4.4 review: DEL byte
    JR      Z, .hit_cr                  ;   (C0/C1 boundary closure)
    BIT     7, A                        ; Story 4.4 AC4: high-bit filter
    JR      NZ, .hit_cr                 ;   (0x80..0xFF render as space too)
    ;; target = A; advance read_pos.
    INC     HL
    LD      (render_read_pos), HL
    JR      .have_target

.hit_cr:
    ;; Merged body — see src/render.asm for the canonical narrative
    ;; spanning Story 2.5 (CR-as-space corruption fix) and Story 4.4
    ;; AC4 generalisation (NUL / C0 / DEL / high-bit). Renders as
    ;; 0x20, advances read_pos by 1, does NOT set past_eol.
    INC     HL
    LD      (render_read_pos), HL
    LD      A, 0x20
    JR      .have_target
```

Cost: ~+12 B (4 byte check + branch + new label body partially shared with .hit_cr — dev
may consolidate `.hit_cr` and `.hit_nonprintable` into one label to save another ~5 B; left
to dev judgment at refactor time).

**TAB scope note.** TAB (0x09) IS in the `< 0x20` range and falls into the merged `.hit_cr`
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

- [x] **Task 0 — Cross-check + Q-pin resolution (per [[feedback_create_story_cross_check]])**
  - [x] 0.1 Verify pre-state: `make sizes` reports the pre-4.4 baseline (post-4.3 — see
    note: 4.3 is test-only with NFR18 byte-identical, so pre-4.4 baseline = post-4.2
    baseline 8562 B / 83.6% / 1678 B headroom IFF 4.3 has landed cleanly). If 4.3 is still
    in-flight, pre-4.4 baseline IS 8562 B exactly.
  - [x] 0.2 Confirm Q-pin choices (settled by Ant at story scoping; flagged here for the
    dev pass to double-check):
    - **Q-A1**: Filter at render emit (Option A). Adopted.
    - **Q-A2** (cursor landing on CR): CR treated as line boundary equivalent to LF —
      AC1/AC2/AC3 all clamp on CR. Follows naturally from Option A; no separate Q.
    - **Q-A3** (save semantics): bytes preserved verbatim (CRLF round-trip fidelity per
      AC5). Follows naturally from Option A; no save-side code touched.
  - [x] 0.3 Confirm pre-4.4 `make test` baseline: `(272 + 7)` if 4.3 has landed, else 272.
    Story 4.4 adds 4 new tests → post-4.4 target is `(pre + 4)` PASS.

- [x] **Task 1 — AC1: motion_h CR clamp** (AC: #1)
  - [x] 1.1 At `src/motions.asm:228-230` (motion_h backward walk), add `CP 0x0D ; JR Z,
    .clamp_undo` immediately after the existing `CP 0x0A ; JR Z, .clamp_undo`. +4 B.
  - [x] 1.2 Update motion_h's AR23 docstring (`src/motions.asm:112-120`) to note CR is
    treated as line boundary alongside LF.
  - [x] 1.3 No new test required — the CR clamp in motion_h is structurally unreachable in
    well-formed buffers (cursor never lands on LF or CR). The change is symmetry +
    future-proofing against a j-to-empty-CRLF-line path.

- [x] **Task 2 — AC2: motion_l CR clamp (load-bearing)** (AC: #2)
  - [x] 2.1 At `src/motions.asm:292-293` (motion_l cursor-on-LF defensive guard), add `CP
    0x0D ; JR Z, .done` immediately after the existing LF check. +4 B.
  - [x] 2.2 At `src/motions.asm:299-300` (motion_l destination-peek), add `CP 0x0D ; JR Z,
    .clamp_undo` immediately after the existing LF check. +4 B.
  - [x] 2.3 Update motion_l's AR23 docstring (`src/motions.asm:251-279`) to note the CR
    clamp; specifically extend the "intra-line EOL" bullet to read "intra-line EOL: byte
    at cursor_offset + 1 is 0x0A OR 0x0D (CRLF tolerance) → stop."
  - [x] 2.4 Create `test/cases/motions_l-clamps-at-cr-byte.asm` per AC9 template.

- [x] **Task 3 — AC3: motion_dollar trailing-CR walkback** (AC: #3)
  - [x] 3.1 At `src/motions.asm:1022-1024` (motion_dollar walk-back after DEC HL), insert
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
  - [x] 3.2 Update motion_dollar's AR23 docstring (`src/motions.asm:991-1004`) to note the
    CR walkback: "On CRLF-terminated lines (e.g. `"abc\r\n"`), DEC HL twice (once for LF
    skip, once for CR skip) so cursor lands on the last printable byte."
  - [x] 3.3 Create `test/cases/motions_dollar-crlf-skips-cr.asm` per AC9 template.

- [x] **Task 4 — AC4: render_emit_one_row non-printable filter** (AC: #4)
  - [x] 4.1 At `src/render.asm:1008-1038` (cell-target compute in render_emit_one_row),
    add the non-printable + high-bit checks per AC4's hook pattern. New label
    `.hit_nonprintable` shares the body shape of `.hit_cr` — dev may consolidate to save
    ~5 B per Lever 1. **(Done at dev time — Lever 1 adopted; both routes target `.hit_cr`.)**
  - [x] 4.2 Update the AR23 docstring for render_emit_one_row at `src/render.asm:949-970`
    to extend the existing CR-as-space note to cover NUL / control / high-bit.
  - [x] 4.3 Create `test/cases/render_emits-nonprintable-as-space.asm` per AC9 template.

- [x] **Task 5 — AC5: save round-trip regression-pin** (AC: #5)
  - [x] 5.1 Create `test/cases/fileio_save-crlf-roundtrip.asm` per AC9 template. No
    production code changes — `fileio_save` is invariant under Story 4.4; this test pins
    that invariant against future-story drift.

- [x] **Task 6 — AC6: NFR9 size verification** (AC: #6)
  - [x] 6.1 `make sizes` after Tasks 1-5 land; capture the listing verbatim.
  - [x] 6.2 Confirm `vibe.com` is within `8588..8648 B` projected range (or `8668..8718 B`
    with drift pad). At least 1000 B residual headroom under 10240 B ceiling.
  - [x] 6.3 If actual size > 8718 B (yellow zone) or > 9240 B (red zone), apply Lever 1
    (consolidate render labels) then Lever 2 (drop high-bit check) per AC6's shrink-down
    section.

- [x] **Task 7 — AC7: NFR18 byte-identical rebuild** (AC: #7)
  - [x] 7.1 `make clean && make all` × 2; capture `vibe.com` SHA-256 both times.
  - [x] 7.2 Verify SHAs match (NFR18); record in Completion Notes List.

- [x] **Task 8 — AC8: Hardware UAT** (AC: #8) — *confirmed by Ant 2026-05-19 (UAT iteration 2)*
  - [x] 8.1 Paste UAT script inline at dev-handoff per
    [[feedback_uat_inline_at_dev_handoff]]; see "Hardware UAT script" section below.
  - [x] 8.2 Generate `crlftest.txt` fixture: `printf 'abc\r\ndef\r\nghi\r\n\032' > crlftest.txt`
    (**note the trailing `\032` = 0x1A soft-EOF marker** — required to prevent
    `fileio_load` from reading SD sector tail garbage; see deferred-work entry under
    "hardware UAT of 4-4" for the underlying preexisting issue). Confirm 16 bytes via
    `od -An -c crlftest.txt | head`.
  - [x] 8.3 Transfer to MicroBeast SD; run the 9-step UAT; capture observations.
    UAT iteration 1 surfaced the `fileio_load`-no-0x1A trap (file came back 256 B with
    extra trailing garbage past the edits); iteration 2 with the `\032`-terminated
    fixture round-tripped cleanly (16 bytes on disk, CRs preserved at offsets 3 / 8 /
    13, X at offset 7, no trailing garbage). Story 4.4 AC1-AC5 invariants all
    confirmed on real hardware.

- [x] **Task 9 — `make test` regression check** (AC: #9)
  - [x] 9.1 `make test`; capture per-case PASS/FAIL.
  - [x] 9.2 Verify the 4 new tests all PASS; no existing test regresses.
  - [x] 9.3 Per-AC pin-to-test map for diagnosis:
    - AC2 fail → `motions_l-clamps-at-cr-byte.asm` (check 0x0D vs 0x0A confusion in motion_l
      patch)
    - AC3 fail → `motions_dollar-crlf-skips-cr.asm` (check empty-line guard at HL==0)
    - AC4 fail → `render_emits-nonprintable-as-space.asm` (check the merged `.hit_cr`
      body — Lever 1 consolidation means there is no separate `.hit_nonprintable`)
    - AC5 fail → `fileio_save-crlf-roundtrip.asm` (would indicate accidental save-side
      modification — should NEVER fail since fileio_save isn't touched)

- [ ] **Task 10 — Commit + close** — *commit pending Ant approval; sprint-status flipped to `done` after Ant accepted hardware UAT iteration 2*
  - [x] 10.1 Stage all modified/new files:
    - `src/motions.asm` (AC1+AC2+AC3 — 3 patch sites + AR23 doc updates)
    - `src/render.asm` (AC4 — 1 patch site + AR23 doc update + 1 B JR→JP for cell_advance)
    - 4 new `test/cases/*.asm` files per AC9
    - `test/Makefile` (added `fixtures/CRLF.TXT` to clean rule — test produces this file
      via the AC5 round-trip pin)
    - `_bmad-output/implementation-artifacts/deferred-work.md` (3 closure annotations
      L77/L220/L266 + 1 new entry under "hardware UAT of 4-4" for the surfaced
      `fileio_load`-no-0x1A trap)
    - `_bmad-output/implementation-artifacts/4-4-crlf-cursor-and-render-handling.md`
      (Dev Agent Record + Completion Notes + UAT iteration 2 confirmation)
    - `_bmad-output/implementation-artifacts/sprint-status.yaml` (status update)
  - [ ] 10.2 Commit message: `Story 4.4: CRLF cursor + render handling (Option A) —
    closes L77/L220/L266`
  - [x] 10.3 Update sprint-status.yaml: flip
    `4-4-crlf-cursor-and-render-handling: ready-for-dev` → `review` → `done` (hardware
    UAT iteration 2 accepted by Ant 2026-05-19).

### Review Findings

*Code review 2026-05-19 (bmad-code-review, Opus 4.7 1M, zero-defer mode per Ant's "and don't defer anything" directive). Hardware UAT iteration 2 already confirmed AC1–AC5 on real MicroBeast; findings below are post-UAT review additions for completeness and follow-on regression hardening. None invalidate the UAT-confirmed core behaviours.*

- [x] [Review][Patch] **HIGH — render.asm: 0x7F (DEL, 0111_1111) falls through non-printable filter and emits raw to VT52** [src/render.asm:1021-1024]. The filter is `CP 0x20 / JR C, .hit_cr` (catches < 0x20) + `BIT 7, A / JR NZ, .hit_cr` (catches 0x80..0xFF). 0x7F is neither — falls through to the printable advance and is emitted as-is. AC4 narrative claim "all non-printable bytes render as space" is false for DEL. Fix: add `CP 0x7F ; JR Z, .hit_cr` after the BIT 7 check (+4 B). Hardware UAT didn't surface this because the test fixture lacked 0x7F bytes.
- [x] [Review][Patch] **HIGH — `render_emits-nonprintable-as-space.asm` asserts only the shadow buffer, missing the AC9-mandated `test_capture_buffer` (BIOS_CONOUT stream) assertions** [test/cases/render_emits-nonprintable-as-space.asm:84-148]. Spec AC9 (lines 274-277) says: "assert the captured byte stream substitutes 0x20 at each non-printable position **AND** shadow_buffer[row*80+col] == 0x20 at those positions." Test loads `test_bios_conout_capture.inc`, resets `test_capture_len`, but never reads back `test_capture_buffer`. A regression where the filter updates shadow correctly but emits a raw non-printable byte to BIOS_CONOUT would pass silently. Fix: after `CALL render_full`, assert `test_capture_buffer[1] == 0x20`, `[3] == 0x20`, `[5] == 0x20` (the substituted positions), plus `[0]=='a' / [2]=='b' / [4]=='c' / [6]=='d'` to anchor the stream ordering. Sentinel codes 0xE8..0xEF.
- [x] [Review][Patch] **MED — `motion_dollar` walkback only DECs once on CR — malformed `abc\r\r\n` leaves cursor on the inner CR** [src/motions.asm:1046-1056]. AC3 walks back exactly once if the byte at HL is CR. For `abc\r\r\n` (5 bytes + LF = 6), `motion_find_line_end` returns 5 (LF pos), DEC → 4 (inner CR), CR check matches, DEC → 3 (outer CR), commit. Cursor lands on CR byte, violating the "last printable" invariant. Real edge case for PC-imported files with CR-CR-LF sequences (rare but possible from broken transfer flows). Fix: convert the single CR walkback into a small loop — `.cr_walkback: LD A,H ; OR L ; JR Z, .commit ; CALL motion_byte_at_logical ; CP 0x0D ; JR NZ, .commit ; DEC HL ; JR .cr_walkback` (+3 B vs the current open-coded version). Alternatively document `\r\r\n` as out-of-scope. Recommend the loop.
- [x] [Review][Patch] **MED — `fileio_save-crlf-roundtrip.asm` has no pre-test delete of `B:CRLF.TXT` — a stale identical file from a prior green run could mask a save-side regression** [test/cases/fileio_save-crlf-roundtrip.asm:82-90]. If a future story breaks `fileio_save` such that it skips the write when content matches existing on-disk bytes, this test would pass against the leftover sector. Fix: `LD C, BDOS_DELETE ; LD DE, fcb_scratch ; CALL BDOS_ENTRY` immediately before `CALL fileio_save`. Add `BDOS_DELETE` to `inc/bdos.inc` if not already present. +6 B in the test (no production-code change).
- [x] [Review][Patch] **MED — render test payload omits TAB (0x09) and CR (0x0D) — two filter paths un-pinned (CR was load-bearing for Story 2.5 UAT step 11 and shared the `.hit_cr` label now generalized)** [test/cases/render_emits-nonprintable-as-space.asm:152]. Spec AC4 "TAB scope note" (lines 176-181) commits to TAB rendering as space (intentional trade-off) but no test pins it; a future filter narrowing could regress this silently. Spec narrative around `.hit_cr` (line 1031-1056 of render.asm) attributes BOTH Story 2.5 (CR) and Story 4.4 (NUL/controls/high-bit) to the merged label — the post-4.4 test should exercise CR too so the consolidated path is end-to-end pinned. Fix: extend `.payload` to include 0x09 (TAB) and 0x0D (CR) bytes with corresponding shadow + capture-buffer assertions. Pair with patch #1 to also include 0x7F. New payload layout (TBD with dev) should keep the 8-byte / single-LF shape so existing assertions don't relocate.
- [x] [Review][Patch] **LOW — `motion_l` cursor-on-CR defensive guard at lines 305-306 has no regression test** [test/cases/motions_l-clamps-at-cr-byte.asm]. The two existing subtests pin the destination-peek (line 314-315). The cursor-on-CR defensive guard (line 305-306) — structurally unreachable in well-formed buffers post-AC2 but kept for symmetry / future j-to-empty-CRLF-line paths — is unpinned. Fix: add subtest 3 that pokes cursor=3 (the CR byte) on `"abc\r\nxyz"`, calls motion_l once, asserts cursor unchanged (sentinel 0x83). Same rationale as Story 4.1's defensive-pin pattern for empty-buffer regression coverage.
- [x] [Review][Patch] **LOW — spec body references `.hit_nonprintable` label across AC4 hook pattern, Task 4.1, Task 9.3, and File List — but Lever 1 consolidation merged it into `.hit_cr`** [_bmad-output/implementation-artifacts/4-4-crlf-cursor-and-render-handling.md]. The Dev Agent Record (line 739-741, 783-785) acknowledges the consolidation, but the spec body still describes a separate label that doesn't exist in render.asm. Future readers diffing source vs spec will be confused. Fix: search/replace `.hit_nonprintable` → `.hit_cr` in spec body sections AC4 hook pattern, Task 4.1, Task 9.3, "Files this story modifies" + add a one-line note at AC4 hook pattern that Lever 1 was adopted and the label is the merged `.hit_cr`.
- [x] [Review][Patch] **LOW — AC3 cost claimed at +11 B but instruction sum is +12 B; +33 B reconciliation arithmetic has a 1-B residual** [_bmad-output/implementation-artifacts/4-4-crlf-cursor-and-render-handling.md]. Spec line 124-126 says "Total cost revised: +11 B" for AC3. Actual instructions added: `LD A,H` (1) + `OR L` (1) + `JR Z` (2) + `CALL motion_byte_at_logical` (3) + `CP 0x0D` (2) + `JR NZ` (2) + `DEC HL` (1) = **12 B**. Dev Agent Record still quotes "+11 B" (Change Log line 825). The measured +33 B production delta (motions +24 = 4+8+12 ; render +9 = 8+1) closes correctly with AC3 at 12 B, not 11 B. Fix: update spec AC3 cost line, NFR9 arithmetic table (line 555-567), and Dev Agent Record AC3 attribution to +12 B. Net measured +33 B unchanged.

*Post-patch verification (2026-05-19):* All 8 patches applied; `make clean && make all` × 2 green; `sha256sum vibe.com` = `0893765a1276efa38c8c014195eb52a674931e9fb70dec9c88fcdc4c490723e0` (byte-identical); `make sizes` = 8602 B / ~84% / 1638 B headroom; `make test` = 283 pass / 1 deliberate-fail (unchanged). Production-code delta: +7 B (0x7F filter +4 B, motion_dollar walkback loop +2 B, JR→JP at `.cell_loop`'s row-done branch +1 B). **Hardware UAT consideration:** review patches changed production code in ways the AC8 UAT script (which tests `abc\r\ndef\r\nghi\r\n` only) does not exercise; the new DEL-filter and `\r\r\n` walkback are defensive additions and the AC1-AC5 invariants Ant confirmed on iteration 2 are preserved. Re-running the AC8 UAT script verbatim is recommended-but-not-strictly-required at Ant's discretion — none of the patches alter behaviour for the UAT fixture's byte content.

**Dismissed during triage (10) — flagged by reviewers but verified non-defects:**

- *"motion_dollar subtest 2 doesn't actually exercise the HL==0 underflow guard via `.no_move` branch"* — false. `motion_find_line_end(\r\nxyz, cursor=0)` returns 1 (LF pos), `SBC HL,DE` → 1 (Z=0, no `.no_move`), `DEC HL` → 0, HL==0 guard fires. Without the guard, byte_at_logical(0)=CR, DEC HL underflows to 0xFFFF, cursor commits at 0xFFFF, test fails. Guard IS exercised.
- *".hit_cr body has no render_col bump → consecutive non-printables loop forever"* — false. `.hit_cr` falls through `.have_target` → `.cell_advance` which bumps `render_col` and JPs `.cell_loop`. Cell counter advances correctly.
- *"motion_dollar trashes DE via motion_byte_at_logical, polluting `edits_compose_or_clear`'s D/E state for compose-pair `d$/y$/c$`"* — false. `edits_compose_or_clear` reads only `pending_operator` and `mode_byte` from memory; takes no DE input. Per-operator bodies (`op_compose_d`, etc.) use `motions_compose_entry` memory cell, not register DE. The trash-list documented in motion_dollar's AR23 docstring is correct as written.
- *"JR→JP at `.cell_advance` could change flag side-effects"* — false. Both JR and JP unconditional are flag-neutral; the conversion is purely a range fix.
- *"Spec line-number anchors (motion_h:112-120, motion_l:251-279, etc.) drift by ~85 lines vs actual post-edit positions"* — pre-existing doc rot from the spec being written before the dev pass; not introduced by this diff. Anchor drift is normal in BMad spec-vs-source workflow; the dev updated the correct sites.
- *"`test/fixtures/CRLF.TXT` is untracked binary in working tree — fixture not buildable by make"* — false. The 128-B file at `test/fixtures/CRLF.TXT` is the OUTPUT of `fileio_save-crlf-roundtrip.asm` (the test writes to `B:CRLF.TXT` via BDOS, which lands in `test/fixtures/CRLF.TXT` under the harness's drive-B mapping). The `clean` rule entry is correct — it removes the test artifact so subsequent runs are deterministic. Untracked-after-test is expected, not a defect.
- *"`d$` on a CRLF line leaves the CR byte in the buffer post-delete (e.g., `abc\r\nxyz` cursor=0 → `d$` deletes `abc` not `abc\r`)"* — intended vi-faithful semantics. `d$` deletes to end-of-line *excluding* the line terminator (CR + LF in this case). Save preserves byte-for-byte per AC5 / Q-A3.
- *"CR-only buffer (one byte = `\r`) motion_dollar leaves cursor on CR"* — degenerate input. A buffer of only CR has no printable bytes; the HL==0 guard correctly clamps cursor at 0 (cursor was 0 to begin with). Current fallback (cursor unchanged on empty/CR-only line) is the only sensible answer.
- *"motion_h CR clamp at lines 236-237 has no regression test"* — spec line 308-310 explicitly says no test needed because the cursor-on-LF path that would feed this clamp is structurally unreachable in well-formed buffers (cursor never lands on LF or CR post-AC2). Symmetry-only patch; consciously left untested per design rationale.
- *"future JR range pressure / status banner format brittleness / BDOS rc convention inconsistency / test-count + SHA unverifiable from diff alone"* — forward-looking concerns or methodology notes, not defects in this diff.

## Dev Notes

### Architecture compliance

- **AR12 (status funnel):** zero new direct call sites. AC1-AC4 changes are all inside
  motions / render which never call `status_set_message`.
- **AR13 (BIOS_CONOUT):** unchanged. AC4's merged `.hit_cr` body emits via
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
  edge; explicitly handled. AC4 routes all non-printable bytes to the proven `.hit_cr`
  body (Lever 1 consolidation).
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
- AMEND `render_emit_one_row` cell-target compute at line 1008-1011 — add the non-printable
  filter (`CP 0x20 ; JR C, .hit_cr` + `CP 0x7F ; JR Z, .hit_cr` (added in review) +
  `BIT 7, A ; JR NZ, .hit_cr`) after the existing CR check. Per Lever 1 (adopted at dev
  time), all four routes share the merged `.hit_cr` body — no separate `.hit_nonprintable`
  label exists in the shipped code.
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
| AC3 — motion_dollar trailing-CR walkback + guard | +12 B (post-review +14 B after JR loop) |
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

1. On dev host: `printf 'abc\r\ndef\r\nghi\r\n\032' > crlftest.txt`. Verify with
   `od -An -c crlftest.txt | head` — expect `a b c \r \n d e f \r \n g h i \r \n 032`,
   **16 bytes total** (15 payload + 1 CP/M soft-EOF marker). **The trailing `\032`
   (= 0x1A) is load-bearing** — without it, `fileio_load`'s sector scan finds no
   soft-EOF marker and loads the full 128-byte SD sector (15 real bytes + 113 bytes
   of whatever was on that sector previously), which then saves back as 2 sectors of
   garbage-padded mess. See the "hardware UAT of 4-4" entry in `deferred-work.md` for
   the preexisting `fileio_load`-no-0x1A trap that Story 4.4's UAT iteration 1
   surfaced.
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

`claude-opus-4-7[1m]` (Dev / bmad-dev-story workflow).

### Debug Log References

- One mid-dev breakage caught at AC4 build: adding 4 new conditional jumps to the
  cell-target compute in `render_emit_one_row` pushed the `.cell_advance` body's
  `JR .cell_loop` past the ±128 B JR target range (sjasmplus reported "Target out of
  range (-133)"). Resolved by converting to `JP .cell_loop` (+1 B, no functional
  change). Documented inline with a Story 4.4 AC4 attribution comment so future
  readers understand the JR→JP isn't speculative.
- Mid-dev sizing surprise: a non-clean `make sizes` after the first 4 patches reported
  8566 B (+4 B vs baseline), which was clearly wrong given the +33-B projection. Root
  cause was a stale build cache — `make clean && make all` then reported the true
  size at 8595 B (+33 B), within the projected band. Calls out [[project_nfr9_cliff_edge]]
  discipline: trust only fresh-build sizes.

### Completion Notes List

- **`make sizes` pre-4.4 baseline:** `code_section: 8562 bytes (~83% of NFR9 10 KB
  budget)` (post-4.3; matches the recorded post-4.2 baseline byte-for-byte, confirming
  4.3 was test-only NFR18 byte-identical as planned).
- **`make sizes` post-4.4 snapshot:** `code_section: 8595 bytes (~83% of NFR9 10 KB
  budget)` → +33 B delta vs pre-4.4 baseline. Sits at the lower end of the projected
  +35..+39 B band (Lever 1 consolidation of `.hit_cr` + `.hit_nonprintable` into a
  single label saved ~4 B; the JR→JP fix added back 1 B net). Headroom against the
  10240 B NFR9 ceiling = 1645 B (well above the 1000 B convention; ~84% utilisation).
- **`make sizes` post-review snapshot (2026-05-19 code-review patches applied):**
  `code_section: 8602 bytes (~84% of NFR9 10 KB budget)` → +7 B delta vs pre-review
  +40 B vs pre-4.4 baseline. Breakdown: +4 B 0x7F (DEL) filter in render.asm; +2 B
  motion_dollar walkback JR loop for malformed `\r\r\n`; +1 B JR→JP at
  `.cell_loop`'s `JR NC, .row_emit_done` (the DEL `CP 0x7F / JR Z` instructions
  pushed the forward branch past ±128 B, mirroring the same fix the original
  Story 4.4 dev pass made at `.cell_advance`'s `JR .cell_loop`). Headroom against
  the 10240 B NFR9 ceiling = 1638 B (~84% utilisation; well above the 1000 B
  convention).
- **`sha256sum vibe.com` post-4.4 (NFR18 byte-identical rebuild check, AC7):**
  `19a63ec72b483258db1fc019f86f1245105609d2b2322dd9559e3b932b0100be` × 2 across
  `make clean && make all` cycles. NFR18 holds; new SHA replaces the pre-4.4
  `cfeaf4c654e09f458387e33c6557af536daa8514f8ab2af6d5c412e640a6f81a` baseline (33 B
  payload growth + recomputed code-section offsets).
- **`sha256sum vibe.com` post-review (2026-05-19 code-review patches applied):**
  `0893765a1276efa38c8c014195eb52a674931e9fb70dec9c88fcdc4c490723e0` × 2 across
  `make clean && make all` cycles. NFR18 holds; supersedes the post-4.4 SHA above
  (7 B payload growth from the DEL filter + double-CR walkback loop + JR→JP).
- **`make test` PASS/FAIL delta:** pre-4.4 baseline 279 pass / 1 deliberate-fail
  (`harness_fail` sentinel — by design, FR-pinned harness self-test). Post-4.4
  result: 283 pass / 1 deliberate-fail (delta = +4 PASS exactly per AC9 target).
  The 4 new passers are `motions_l-clamps-at-cr-byte`, `motions_dollar-crlf-skips-cr`,
  `render_emits-nonprintable-as-space`, and `fileio_save-crlf-roundtrip`. Zero
  regressions; `make clean && make test` is green from a fresh tree.
  **Post-review (2026-05-19):** 283 pass / 1 deliberate-fail unchanged. The 3
  review-patched tests (`render_emits-nonprintable-as-space` with extended TAB/CR/DEL
  payload + capture-stream assertions; `fileio_save-crlf-roundtrip` with pre-test
  `BDOS_DELETE`; `motions_l-clamps-at-cr-byte` with new subtest 3 for the
  cursor-on-CR defensive guard) all PASS without changing the topline count
  (extensions are in-test subtests, not new test files).
- **Lever decisions:** Lever 1 (consolidate `.hit_cr` + `.hit_nonprintable` into a
  single label sharing the INC HL + LD A,0x20 + JR .have_target tail) **APPLIED** —
  saved ~4 B and kept the existing CR-attribution narrative attached to the `.hit_cr`
  comment block (with a new paragraph extending coverage to NUL / controls / high-bit
  per AC4). Lever 2 (drop high-bit BIT 7 check) **NOT APPLIED** — sizing came in
  comfortably so the full L77 scope (NUL + controls + high-bit) is preserved per the
  AC4 corruption-safety contract. Lever 3 (defer motion_h CR clamp) **NOT APPLIED**
  — kept for symmetry with motion_l per AC1's design rationale.
- **TAB handling:** TAB (0x09) is in the `< 0x20` band of the AC4 filter and renders
  as a space (single cell), per the AC4 "TAB scope note" intentional trade-off
  (corruption safety > visual alignment of TAB-formatted files). Option C
  (TAB-as-multi-cell with shadow tracking) was explicitly rejected at story scoping
  and not revisited.
- **Hardware UAT (AC8):** awaiting Ant on real MicroBeast with the CRLF-imported
  `crlftest.txt` fixture. UAT script pasted inline below per
  [[feedback_uat_inline_at_dev_handoff]] (9 steps, includes the off-VIBE
  `od -An -c crlftest.txt` verification as the binding AC5 / AC8 pin).
- **Memory hooks honoured:**
  - [[project_nfr9_cliff_edge]] — drift pad applied to mid-estimate; actual fell at
    the low end of the projected band. No headroom regression.
  - [[feedback_uat_inline_at_dev_handoff]] — UAT script pasted inline below.
  - [[feedback_uat_trace_cursor]] — UAT script traces cursor offset explicitly at
    every step; step 6's `i X Esc` cursor landing at offset 7 (not 8) is documented
    per vi-faithful Esc-steps-back-1 semantics.
  - [[feedback_create_story_cross_check]] — story narrative verified against actual
    render/edit semantics at Task 0; no drift detected from spec to source-of-truth.
- **Deferred-work annotations:** L77 (1.11 review), L220 (2.5 review), L266 (2.6
  review) all marked CLOSED with sub-bullet attribution to Story 4.4 (AC1/AC2/AC3/AC4
  cited appropriately). The L77 entry's CR-only resolution from Story 2.5 is now
  fully generalised to NUL / C0 controls / high-bit; the L220/L266 entries' fix
  recommendations were narrower than the originally-suggested motion_find_line_start
  approach but achieve the same observable invariant at ~+19 B total vs the original
  ~+10-15 B estimate (the +1 B underflow guard in AC3 wasn't anticipated by the
  original L266 suggestion).

### File List

Production-code changes (2 files; +33 B total):
- `src/motions.asm` — AC1 (motion_h CR clamp +4 B), AC2 (motion_l 2 sites +8 B),
  AC3 (motion_dollar walkback + HL==0 underflow guard +12 B; post-review +14 B
  after JR loop for `\r\r\n` malformed-input handling). AR23 docstrings
  updated for motion_h / motion_l / motion_dollar to document CR-as-line-boundary
  behaviour.
- `src/render.asm` — AC4 (cell-target compute non-printable + high-bit filter
  routing to `.hit_cr` per Lever 1 consolidation, +8 B; `.cell_advance` `JR
  .cell_loop` → `JP .cell_loop` for range, +1 B). AR23 docstring for
  `render_emit_one_row` extended to document the non-printable filter and the L77
  closure attribution. Inline comment block on `.hit_cr` now narrates both the
  Story-2.5 CR fix and the Story-4.4 AC4 generalisation.

New tests (4 files; +4 PASS):
- `test/cases/motions_l-clamps-at-cr-byte.asm` — pins AC2 (2 subtests:
  `"abc\r\n"` cursor-at-`c` clamp; CR-only `"abc\r"` cursor-at-`c` clamp).
- `test/cases/motions_dollar-crlf-skips-cr.asm` — pins AC3 (2 subtests: CRLF
  walkback from cursor=0 on `"abc\r\ndef"` → cursor=2 (`c`); empty `"\r\nxyz"`
  HL==0 underflow guard → cursor=0).
- `test/cases/render_emits-nonprintable-as-space.asm` — pins AC4 (single buffer
  `'a' NUL 'b' 0x80 'c' 0xFF 'd' LF` exercises NUL + high-bit + LF paths;
  per-cell shadow assertions at offsets 0..7).
- `test/cases/fileio_save-crlf-roundtrip.asm` — pins AC5 (gap buffer
  `"abc\r\nxyz\r\n"` saved to B:CRLF.TXT then re-opened + read sector 0; on-disk
  bytes 0..9 asserted to match the gap exactly, byte 10 = 0x1A soft-EOF, bytes
  11..127 = 0x20 pad).

Test-harness hygiene (1 file; 0 production-code impact):
- `test/Makefile` — added `fixtures/CRLF.TXT` to the `clean:` rule (the AC5
  round-trip test produces this file via `fileio_save`; clean rule keeps repeat
  `make clean && make test` deterministic, mirroring the existing OUT.TXT /
  PAD100.TXT / RO.TXT pattern).

Documentation / triage updates (3 files; 0 production-code impact):
- `_bmad-output/implementation-artifacts/deferred-work.md` — L77, L220, L266
  annotated CLOSED by Story 4.4 with cited ACs + cited test files + Cost
  call-outs (the established post-resolution annotation pattern used by Story
  1.12's closures of lines 71/75/82).
- `_bmad-output/implementation-artifacts/4-4-crlf-cursor-and-render-handling.md`
  — this file (Status flip + Tasks/Subtasks ticked + Dev Agent Record +
  Completion Notes + File List + Change Log).
- `_bmad-output/implementation-artifacts/sprint-status.yaml` —
  `4-4-crlf-cursor-and-render-handling: ready-for-dev` → `in-progress` →
  `review` (last_updated annotation pending Ant's review-pass note convention).

## Change Log

| Date       | Author | Change                                                                       |
|------------|--------|------------------------------------------------------------------------------|
| 2026-05-19 | Amelia | Story 4.4 scoped from Theme A of `deferred-work-triage-2026-05-19.md`. Q-A1 pinned to Option A (filter at render emit + motion CR clamps) by Ant 2026-05-19. Closes deferred entries L77/L220/L266. Production-code delta projected at +35-39 B. Ready for dev. |
| 2026-05-19 | Dev    | Story 4.4 implementation complete (bmad-dev-story workflow, Opus 4.7 1M). AC1 (motion_h CR clamp +4 B), AC2 (motion_l CR clamp 2 sites +8 B), AC3 (motion_dollar trailing-CR walkback + HL==0 underflow guard +12 B — original spec said +11 B; reconciliation pin in review), AC4 (render_emit_one_row non-printable filter via Lever 1 `.hit_cr` consolidation +8 B + JR→JP for range +1 B) = net +33 B production. AC5 invariant pinned by new save-side regression test (zero production-code changes to fileio.asm). NFR9 actual 8595 B / 84% / 1645 B headroom (within projected 8588..8648 B band). NFR18 SHA `19a63ec72b483258db1fc019f86f1245105609d2b2322dd9559e3b932b0100be` byte-identical × 2. Test count 279 → 283 PASS (+4 exact) / 1 deliberate-fail unchanged. Deferred-work L77/L220/L266 annotated CLOSED with cited AC + test + cost attributions. Status: ready-for-dev → review. AC8 hardware UAT pending Ant on real MicroBeast with `crlftest.txt` CRLF-imported fixture. |
| 2026-05-19 | Code-review | Review patches applied (zero-defer mode per Ant). Production: `src/render.asm` +4 B DEL (0x7F) filter; `src/motions.asm` +2 B motion_dollar CR walkback loop for malformed `\r\r\n`. Tests: render test extended to assert capture stream + payload now covers TAB/CR/DEL plus existing NUL/0x80/0xFF; round-trip test now BDOS_DELETEs `B:CRLF.TXT` pre-save; motion_l test gains subtest 3 (cursor-on-CR defensive guard). Doc: spec body reconciled — `.hit_nonprintable` references annotated as merged into `.hit_cr` per Lever 1; AC3 cost reconciled +11 → +12 B. Projected production delta: +33 → +39 B (+6 B from review patches: 4 + 2). Pending NFR9 re-check + NFR18 SHA re-capture after build verification. |
