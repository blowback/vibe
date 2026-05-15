# Story 2.6: Word/line/buffer motions (w, b, 0, $, gg, G)

Status: review

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As a MicroBeast resident developer,
I want `w` and `b` (word forward/back), `0` and `$` (line start/end), `gg` and `G` (buffer start/end), all count-aware per BH2,
So that vi muscle memory transfers for the broader motion vocabulary (FR20, FR21, FR22) — closing the FR18-FR22 motion-set in one story — and BH1's word-boundary classifier + BH2's clamp policy are realised on top of Story 2.5's h/j/k/l substrate.

## Acceptance Criteria

**AC1 — `src/motions.asm` grows with six new public entries + one new internal helper.**

**Given** the post-Story-2.5 motions.asm (motion_h / motion_j / motion_k / motion_l + four internal helpers — motion_byte_at_logical, motion_find_line_start, motion_find_line_end, motion_apply_count + two module-local DEFW scratch cells motions_col / motions_target_start)
**When** I inspect post-Story-2.6 `src/motions.asm`
**Then** the module header `Public:` block grows to include:
  - `motion_w` (next word forward; AC2; FR20)
  - `motion_b` (previous word start; AC3; FR20)
  - `motion_0` (line start; AC4; FR21 — replaces `parser_motion_zero_stub`)
  - `motion_dollar` (line end; AC5; FR21)
  - `motion_G` (buffer end / Nth line; AC6; FR22)
  - `motion_gg` (buffer start / Nth line; AC7; FR22 — replaces `parser_gg_motion_stub`)

**And** the module gains one new internal helper:
  - `is_word_char` — BH1 word-boundary classifier (AC8; FR20).

**And** the four existing Story-2.5 internal helpers (`motion_byte_at_logical`, `motion_find_line_start`, `motion_find_line_end`, `motion_apply_count`) are reused without modification by the new handlers. **No new module-local scratch cells** are required — the new handlers either compute in registers (motion_0, motion_dollar, motion_gg) or reuse Story-2.5's `motions_col` for nothing (motion_w / motion_b / motion_G all step in 1-D over the buffer; no column preservation needed because none of these are column-preserving motions).

**Vi-divergence header note required.** The motions.asm header `Purpose:` paragraph must be updated to remove the "Story 2.6 will add ..." forward note (the work has landed) and to add a line noting that motions.asm is now THE source of truth for both bare motion handlers AND the gg/0 handlers previously stubbed in parser.asm.

**AR23 contract blocks.** Each new public entry and the new internal helper gets the four-line `In:` / `Out:` / `Trashes:` / `Calls:` contract per AR23 (architecture line 854-906). Match the existing motion_h / motion_j shape.

**Module-local placement (DEFW scratch).** **No new DEFW cells** — verify on completion that `motions_col` / `motions_target_start` are still the only two cells in motions.asm and the new code doesn't add a third.

**AC2 — `motion_w` advances cursor to the start of the next word per BH1, count-aware.**

**Given** `cursor_offset` is somewhere in the buffer, `count_accumulator` may be 0 or non-zero
**When** the user presses `w` (0x77) in NORMAL mode and `dispatch_normal` dispatches `motion_w`
**Then**:
  - Effective count via `motion_apply_count` (BC = max(1, count_accumulator)).
  - For each step:
    1. **Classify current byte.** Read byte at `cursor_offset` via `motion_byte_at_logical`. If CF=1 (past EOF), stop (EOF clamp per BH2). Otherwise:
       - If `A == 0x0A` (cursor on LF — can happen if motion_j landed on an empty line): treat as "whitespace-class" for the boundary scan — fall through to step 2's whitespace skip.
       - Else: classify via `is_word_char`: Z = word-class (alnum + underscore), NZ but non-whitespace = non-word-class, whitespace = whitespace.
    2. **Skip the rest of the current word.** Walk forward while the byte at the new cursor position is in the same class as step 1 (word-class stays word-class; non-word-class stays non-word-class; whitespace... well, if step 1 was whitespace, this step is a no-op). LF bytes terminate any class (an LF is a class boundary — vi treats line-endings as separators).
    3. **Skip whitespace + LFs.** Walk forward while the byte is whitespace (space 0x20, tab 0x09, LF 0x0A, CR 0x0D — the BH1-amended whitespace set per the Story-2.5 CR-filter precedent).
    4. **Land.** Cursor is now on the first byte of the next word (or at EOF if no further word exists). If EOF was reached during steps 2 or 3, stop (EOF clamp; cursor MAY land on file_length itself if the file ends with whitespace, or on the last printable byte if no trailing whitespace — the "EOF cursor sentinel" is `cursor_offset == file_length`).
  - On completion (count exhausted or EOF clamp), tail-JP `parser_clear` (AC11).

**Empty buffer / cursor at EOF:** `motion_byte_at_logical` at step 1 returns CF=1; immediate clamp; no state change; tail-JP `parser_clear`.

**Single-word file, no trailing whitespace:** e.g., buffer = `"hello"` cursor=0. Step 1: 'h' is word-class. Step 2: walk to cursor=5 (file_length); CF=1 at step 5. Step 3: no-op (already past EOF). Result: cursor=5 (EOF sentinel). Subsequent `motion_l` from this position is a no-op per Story-2.5 AC3's EOF clamp.

**Cross-line word advance:** buffer = `"foo\nbar"` cursor=0. Step 1: 'f' word-class. Step 2: walk to cursor=3 (LF position — class change). Step 3: walk whitespace past LF (LF counts as whitespace per AC2 step 3) to cursor=4 ('b'). Result: cursor=4. Pinned by `motions_w-skips-whitespace.asm`.

**Non-alnum-class transition:** buffer = `"foo,bar"` cursor=0. Step 1: 'f' word-class. Step 2: walk word-class to cursor=3 (','). Step 3: no whitespace skip needed (',' isn't whitespace; cursor stays). Result: cursor=3 (the comma — start of the non-word class run). Pinned by `motions_w-non-alnum-class.asm`.

**Vi-faithfulness footnote:** Real vi's `w` from inside a word-class run lands on the *next* boundary — same as the algorithm above. The "skip current class then skip whitespace" decomposition gives identical results for the BH1 two-class system. **Do not** implement the "skip current class then if landed on punctuation skip nothing else" variant — it produces wrong answers on `"foo  bar"` (two-space gap).

**AC3 — `motion_b` retreats cursor to the start of the previous word per BH1, count-aware.**

**Given** `cursor_offset` somewhere in the buffer
**When** the user presses `b` (0x62) in NORMAL mode
**Then**:
  - Effective count via `motion_apply_count`.
  - For each step:
    1. **BOF clamp.** If `cursor_offset == 0`, stop (BH2 BOF clamp). Otherwise:
    2. **Step back one byte.** Decrement cursor (the candidate start byte).
    3. **Skip backward whitespace + LFs.** Walk backward while the byte at the new cursor is whitespace. If cursor reaches 0 during this skip, the result is cursor=0.
    4. **Classify.** Read byte at cursor (now on a non-whitespace byte); classify via `is_word_char`.
    5. **Skip backward through the same class.** Walk backward while the byte at `cursor - 1` is in the same class AND is not whitespace AND is not LF. Decrement cursor on each match. Stop when class changes or cursor reaches 0.
    6. **Land.** Cursor is now on the start of the word (the first byte of the class run that contains the original "step back" position).
  - On completion, tail-JP `parser_clear`.

**Already-at-word-start case:** buffer = `"hello world"` cursor=6 ('w'). Step 1: cursor>0. Step 2: cursor=5 (' '). Step 3: walk backward while whitespace: cursor=4 ('o' — non-whitespace, stop). Step 4: 'o' is word-class. Step 5: walk backward while word-class + cursor > 0: cursor=0 ('h'). Result: cursor=0. Per epic line 1113 — "moves to the start of the current word if not already there; otherwise to the start of the previous word". The "already there" case is when cursor IS on the first byte of a word; the algorithm above handles both naturally because step 2 always steps back one byte first.

**Mid-word case:** buffer = `"hello"` cursor=3 ('l'). Step 1: cursor>0. Step 2: cursor=2 ('l'). Step 3: not whitespace. Step 4: 'l' word-class. Step 5: walk back while word-class: cursor=0 ('h'). Result: cursor=0. Pinned by `motions_b-from-mid-word.asm`.

**BOF clamp:** cursor=0 → step 1 stops immediately; no state change.

**Cross-line back:** buffer = `"foo\nbar"` cursor=4 ('b'). Step 1: cursor>0. Step 2: cursor=3 (LF). Step 3: walk back while whitespace (LF is whitespace per AC2's BH1 amendment): cursor=2 ('o'). Step 4: 'o' word-class. Step 5: walk back while word-class: cursor=0 ('f'). Result: cursor=0.

**AC4 — `motion_0` moves cursor to column 0 of the current line. Replaces `parser_motion_zero_stub`.**

**Given** `cursor_offset` somewhere in the buffer; precondition `count_accumulator == 0` (the parser's leading-zero arm only fires when count was 0)
**When** the user presses `0` (0x30) in NORMAL mode AND `count_accumulator == 0` (parser_handle_digit's leading-zero detection)
**Then**:
  - The dispatch path is unchanged from Story 1.10: `dispatch_normal[0x30] = parser_handle_digit`; `parser_handle_digit` detects `count_accumulator == 0` and `JP`s to the handler at the leading-zero arm.
  - Story 2.6 changes the leading-zero arm's `JP parser_motion_zero_stub` target to `JP motion_0` (rename + retire the stub).
  - `motion_0`'s body:
    1. `cursor = motion_find_line_start(cursor_offset)` — single call; no per-step loop (motion_0 is a "go directly to N" motion, not an iterative one). Count is irrelevant (precondition: count == 0, the leading-zero precondition).
    2. `LD (cursor_offset), HL`.
    3. Tail-JP `parser_clear` (this clears `pending_operator` and `pending_motion_prefix`; count is already 0).
  - The `parser_motion_zero_stub` symbol + body are RETIRED from src/parser.asm. The parser's leading-zero arm directly JPs `motion_0` (forward reference resolved by sjasmplus two-pass; motions.asm INCLUDEs after parser.asm in vibe.asm's AR25 chain).

**Operator-pending case (e.g., `d0` = "delete to line-start"):** per Story-2.5 AC7's parser-clear hygiene + Story 2.11's deferred operator+motion compose, `d0` currently has `pending_operator = 'd'` when motion_0 fires. Story 2.6 motion_0 tail-JPs parser_clear unchanged — operator dropped silently, same pattern as `dh` / `dj` / `dk` / `dl` per Story-2.5 AC7. Story 2.11 will wire the operator+motion compose to use motion_0's resulting position as the range endpoint.

**Empty line case:** cursor on a lone LF (e.g., empty middle line) — `motion_find_line_start` returns the offset of the byte just past the previous LF (or 0). For an empty line, line_start IS the LF position (or EOF, for an empty last line) — same as cursor's current position. Result: no move. Pinned by `motions_0-on-blank-line.asm`.

**Beginning-of-file case:** cursor at offset 0 — `motion_find_line_start` returns 0 (no previous LF). Result: cursor stays at 0.

**AC5 — `motion_dollar` moves cursor to the last printable byte of the current line.**

**Given** `cursor_offset` somewhere in the buffer
**When** the user presses `$` (0x24) in NORMAL mode and `dispatch_normal` dispatches `motion_dollar`
**Then**:
  - `motion_apply_count` is called for contract uniformity but the resulting count is effectively ignored for Story 2.6 — `$` is a "go-to-end-of-current-line" motion regardless of count (vi traditionally treats `5$` as "go to end of line 5 lines down" — that semantic is **deferred** to a future story; Story 2.6's `$` ignores count after the apply call, mirroring `0`'s precondition-driven approach). **The dev MAY skip the `motion_apply_count` call for `motion_dollar` if it's cleaner — `parser_clear` at the end zeroes count regardless.**
  - Body:
    1. `eol = motion_find_line_end(cursor_offset)` — returns the LF position or `file_length` if no LF before EOF.
    2. **Empty line case.** If `eol == cursor_offset` (cursor was already on the LF, or on EOF of an empty line), no move; tail-JP `parser_clear`. Pinned by `motions_dollar-on-empty-line.asm`.
    3. **Normal case.** Cursor = `eol - 1` (the last printable byte before the LF). For a file with no trailing LF, `eol == file_length`; cursor = `file_length - 1` (the last byte in the file).
    4. **Boundary defensive.** If `eol == 0` (impossible per `motion_find_line_end`'s contract — line_end ≥ cursor_offset always — but defensive: a future refactor to `find_line_end` shouldn't crash motion_dollar), no move.
  - `LD (cursor_offset), HL`; tail-JP `parser_clear`.

**Empty-buffer case:** cursor=0, file_length=0. `motion_find_line_end(0)` returns 0 (CF=1 immediately; HL preserved). Step 2 fires (eol == cursor_offset == 0); no move.

**Cursor already at $:** cursor on the last printable byte of a non-empty line. `motion_find_line_end` returns LF position = cursor+1. Step 3: cursor = (cursor+1) - 1 = cursor. No net move.

**AC6 — `motion_G` moves cursor to the start of the last line, or with count C to the start of line C.**

**Given** `cursor_offset` somewhere in the buffer
**When** the user presses `G` (0x47, uppercase) in NORMAL mode and `dispatch_normal` dispatches `motion_G`
**Then**:
  - `motion_apply_count` is called — BC = effective count (1 if count was 0; the count is used differently below).
  - **No count typed (count_accumulator was 0):** the parser's "no count means 1" default doesn't fit G's semantics. G with no count goes to the LAST line, regardless of buffer size. The dev MUST distinguish "user typed `G`" from "user typed `1G`":
    - **Decision: re-check count_accumulator before applying the default.** `motion_G` should be a SECOND consumer (after the helper-called motion_apply_count) of count_accumulator — read the cell directly, if zero use the "last-line" semantic, else use BC as the target line number.
    - **Implementation sketch:** `LD HL, (count_accumulator) ; LD A, H ; OR L ; JR Z, .no_count` — non-zero path goes to "find line BC"; zero path goes to "find last line".
    - **OR** add a flag to `motion_apply_count`'s return contract (e.g., CF=1 iff count defaulted) and switch on CF. Avoiding this adds a refactor cost to motion_apply_count + ripple to motion_h/j/k/l/w/b; not recommended for Story 2.6 — read count_accumulator directly in motion_G.
  - **With count C (count_accumulator was C):** walk to the start of line C (line numbers 1-indexed per vi convention: `5G` = start of line 5 = the byte just past the 4th LF, or 0 if C=1). If C exceeds the file's line count, clamp at start of the last line (BH2 EOF clamp). Algorithm:
    1. `HL = 0` (offset of line 1's start, i.e., byte 0).
    2. `DE = C - 1` (number of LFs to skip; for C=1, DE=0, no walk).
    3. Loop: while DE > 0 AND HL < file_length, walk forward via `motion_byte_at_logical` looking for LF; on LF found, HL = LF_offset + 1, DE--.
    4. On exit, HL is at the start of line C (or at the LAST line's start if EOF was reached first with DE>0).
  - **No count (count_accumulator was 0):** walk to the start of the last line. Algorithm:
    1. `HL = 0`.
    2. Loop: while HL < file_length, walk forward via `motion_byte_at_logical` looking for LF; on LF found, `last_line_start = HL + 1`; HL = HL + 1; continue. (Edge: an LF at file_length-1 produces last_line_start = file_length, which is the "empty last line past trailing LF" sentinel — see edge below.)
    3. On exit, `cursor_offset = last_line_start` (or 0 if no LFs in the file).
  - **Empty-buffer / single-line case (no LFs):** result = 0 (line 1 IS the first byte; with count or without, cursor lands at 0).
  - **Trailing-LF edge (the Story-2.5 P5 lesson).** A file ending in LF (e.g., `"abc\n"`) presents a "phantom" empty line past the trailing LF. Real vi treats trailing LF as terminator; `G` on this file lands on the start of line 1 (the line containing `"abc"`), not at offset 4 (past the trailing LF). **Implementation note:** when scanning for the LAST line, after finding the last LF at offset N, check if N+1 < file_length BEFORE setting `last_line_start = N+1`. If N+1 == file_length, the LF was a trailer and `last_line_start` should remain at whatever line the LF terminates (which IS what `last_line_start` already held before the trailing-LF iteration). Pinned by `motions_G-no-count.asm` (testing both with and without trailing LF).
  - Tail-JP `parser_clear`.

**Spec divergence note:** Epic line 1126 says "G with no count moves to start of last line" — Story 2.6 honors this. The trailing-LF clamp above is a refinement that matches Story 2.5's motion_j patch (P5).

**Count past EOF:** `100G` on a 5-line file → cursor lands on start of line 5 (the last line; BH2 clamp; silent). Pinned by `motions_G-with-count.asm` (test with count=2 on a 5-line file lands on line 2; test with count=100 clamps to last line).

**AC7 — `motion_gg` moves cursor to the start of the buffer (line 1), or with count C to the start of line C. Replaces `parser_gg_motion_stub`.**

**Given** `cursor_offset` somewhere in the buffer; the parser has just seen the second `g` of a `gg` sequence
**When** `parser_handle_motion_prefix`'s doubled-prefix arm dispatches the handler
**Then**:
  - The dispatch path is unchanged from Story 1.10: `dispatch_normal['g'] = parser_handle_motion_prefix`; on doubled-g detection the parser `JP`s to the gg handler.
  - Story 2.6 changes the parser's `JP parser_gg_motion_stub` to `JP motion_gg` (rename + retire the stub).
  - `motion_gg`'s body:
    1. `LD HL, (count_accumulator)` — read BEFORE clearing parser state (per the Story-2.5 reference pattern in deferred-work.md line 94).
    2. `LD A, H ; OR L` — test HL == 0.
    3. **Zero path (no count):** `cursor_offset = 0` (start of line 1). Tail-JP `parser_clear`.
    4. **Non-zero path (count = C):** same algorithm as motion_G's "with count" branch — walk to the start of line C, clamping at last-line-start if C exceeds file's line count. Set cursor; tail-JP `parser_clear`.
  - The `parser_gg_motion_stub` symbol + body are RETIRED from src/parser.asm.

**Shared-walk-helper opportunity:** `motion_G` (with count) and `motion_gg` (with count) share the same "walk to line N" logic. The dev MAY factor a shared internal helper (suggested name: `motion_find_line_n`). Cost ~30 B in helper; saves ~30 B × 2 call sites = ~30 B net (one body in helper vs two inline bodies). Recommended if NFR9 budget allows (see AC15).

**`dgg` operator-stranded case:** `pending_operator = 'd'` carries through `parser_handle_motion_prefix`'s first-g arm (which preserves operator per parser.asm:330). On the second g, motion_gg fires, reads count_accumulator, moves cursor, and tail-JPs parser_clear which drops the pending 'd'. Story 2.11 will land operator+motion compose. Story 2.6 motion_gg is bare-motion-only.

**Test coverage:** `motions_gg-via-prefix.asm` per epic line 1147 — drive the parser end-to-end: `LD A, 'g'; CALL parser_handle_motion_prefix` (first g sets prefix); `LD A, 'g'; CALL parser_handle_motion_prefix` (second g dispatches motion_gg via the JP); assert cursor=0 and parser state cleared.

**AC8 — `is_word_char` BH1 word-boundary classifier (internal helper).**

**Given** the BH1 spec at architecture line 668-675: "A 'word' is a maximal run of either: (a) alphanumerics-plus-underscore, or (b) non-whitespace-non-(a). Whitespace separates but is not a word."
**When** `motion_w` / `motion_b` need to classify a byte
**Then** a single internal helper `is_word_char` returns:
  - `Z` flag set iff the byte is "word-class" (alnum + underscore: `0..9`, `A..Z`, `a..z`, `_`).
  - `Z` flag cleared iff the byte is NOT word-class.
  - The byte itself preserved in A so callers can do follow-up tests (e.g., `is_word_char` then `CP 0x0A` for the LF check).
  - Whitespace is NOT distinguished from non-word-class by this helper — both return NZ. Callers must do a separate whitespace test if needed (suggested: a tight `CP 0x21` check — `< 0x21` covers space 0x20, tab 0x09, LF 0x0A, CR 0x0D, NUL 0x00, plus all other control bytes which we shouldn't see in valid text but defensive coverage is cheap).

**Implementation hint (~25-30 B):**
```asm
is_word_char:
    CP      '0'
    RET     C                   ; NZ (CF set: byte < '0'); preserves A
    CP      '9' + 1
    JR      C, .yes             ; '0'..'9' — return Z; preserves A
    CP      'A'
    RET     C                   ; NZ; preserves A
    CP      'Z' + 1
    JR      C, .yes             ; 'A'..'Z' — return Z
    CP      '_'
    JR      Z, .yes             ; '_' — return Z (CP sets Z if equal; this is the natural exit)
    CP      'a'
    RET     C                   ; NZ
    CP      'z' + 1
    JR      C, .yes             ; 'a'..'z' — return Z
    OR      A                   ; byte > 'z' — clear Z (return NZ); but OR A also clobbers F's CF
    RET                         ; explicit RET for clarity
.yes:
    CP      A                   ; force Z=1 (CP A always sets Z); preserves A's value
    RET
```
The dev MAY factor differently — the contract is "Z iff word-class". The above is one ~26 B shape; a table-lookup approach with a 16-byte bitmap would be ~12 B + 16 B table = 28 B but cleaner for future extension. **NFR9 pressure may favor whichever is smaller.**

**Whitespace classifier (no separate helper; inline).** The whitespace test in motion_w / motion_b is small enough to inline at each call site: `CP 0x21 ; JR C, .is_whitespace` (the BH1-amended set: space 0x20, tab 0x09, LF 0x0A, CR 0x0D — all under 0x21). The dev MAY factor a helper `is_whitespace` if it reads cleaner; ~10 B in body vs ~8 B in helper + ~5 B per call site (3 sites = ~15 B). Inline is smaller and consistent with Story-2.5's "fold small one-liners inline" pattern (e.g., motion_h's `LD A, H ; OR L ; JR Z, ...` instead of a `is_zero_hl` helper).

**Forward-reference path:** `is_word_char` is defined in motions.asm and called by motion_w + motion_b. Both reside in motions.asm. No forward-reference complications.

**AC9 — Parser-stub retirement (`parser_motion_zero_stub` + `parser_gg_motion_stub`).**

**Given** src/parser.asm's three Epic-1 placeholder stubs (per the module header at parser.asm:25-27):
  - `parser_motion_zero_stub` — leading-`0` arm (FR21; Story 2.6 lands real)
  - `parser_doubled_operator_stub` — dd/yy/cc/<<<>> (FR40; Story 2.10 lands real)
  - `parser_gg_motion_stub` — gg motion (FR22; Story 2.6 lands real)
**When** Story 2.6 lands `motion_0` and `motion_gg`
**Then**:
  1. **`parser_motion_zero_stub` body retired.** Delete the routine body. Change `parser_handle_digit`'s `JP parser_motion_zero_stub` (parser.asm:246) to `JP motion_0`.
  2. **`parser_gg_motion_stub` body retired.** Delete the routine body. Change `parser_handle_motion_prefix`'s `JP parser_gg_motion_stub` (parser.asm:382) to `JP motion_gg`.
  3. **`parser_doubled_operator_stub` UNCHANGED** — Story 2.10 lands real `dd` / `yy` / `cc` / `>>` / `<<`. Story 2.6 leaves this stub in place.
  4. **Parser module header updated:** `Public:` list drops `parser_motion_zero_stub` and `parser_gg_motion_stub` (the symbols disappear). The asymmetric-clear protocol description (parser.asm:34-47) is unchanged — still load-bearing for `motion_gg` because `motion_gg` reads count_accumulator BEFORE the eventual tail-JP parser_clear (per AC7 step 1-4).
  5. **Forward references resolved.** The `JP motion_0` / `JP motion_gg` in parser.asm reference symbols defined in motions.asm. Since motions.asm INCLUDEs AFTER parser.asm in vibe.asm's AR25 chain (architecture line 944), sjasmplus's two-pass model resolves the forward references. Same shape as Story-2.5's dispatch_normal forward-referencing motion_h/j/k/l.

**Resolves deferred-work line 93-94's heads-up:** Story 2.5's status update on that entry explicitly forward-flagged Story 2.6 for the stub→real-handler swap. motion_gg is the FIRST handler to demonstrate the "read state THEN tail-JP parser_clear" pattern at the parser-dispatched call site (motion_h/j/k/l demonstrated it at dispatch_normal direct-dispatch sites, but those entered with parser state already accumulated from prior keystrokes; motion_gg is dispatched mid-`parser_handle_motion_prefix` so the parser state read MUST happen before any clear).

**AC10 — `dispatch_normal` gains four entries: `$` (0x24), `G` (0x47), `b` (0x62), `w` (0x77).**

**Given** `dispatch_normal`'s 28-entry post-Story-2.5 table (entries: 0x0C, '/', '0'..'9', ':', '<', '>', 'O', 'a', 'c', 'd', 'g', 'h', 'i', 'j', 'k', 'l', 'o', 'v', 'y')
**When** I inspect post-Story-2.6 `src/dispatch.asm`
**Then** four new entries land in lex-ascending position with the existing adjacent-pair ASSERT chain re-stitched:

```asm
    DEFB    0x0C                ; Ctrl-L unchanged
    DEFW    mode_full_refresh_stub
    ASSERT  '$' > 0x0C
    DEFB    '$'                 ; NEW (Story 2.6 — FR21)
    DEFW    motion_dollar
    ASSERT  '/' > '$'           ; replaces 'ASSERT / > 0x0C'
    DEFB    '/'                 ; unchanged
    DEFW    mode_search_prompt_stub
    ;; ... '0'..'9', ':', '<', '>' unchanged ...
    ASSERT  'G' > '>'           ; NEW
    DEFB    'G'                 ; NEW (Story 2.6 — FR22)
    DEFW    motion_G
    ASSERT  'O' > 'G'           ; replaces 'ASSERT O > >'
    DEFB    'O'                 ; unchanged
    ;; ... 'O', 'a' unchanged ...
    ASSERT  'b' > 'a'           ; NEW
    DEFB    'b'                 ; NEW (Story 2.6 — FR20)
    DEFW    motion_b
    ASSERT  'c' > 'b'           ; replaces 'ASSERT c > a'
    DEFB    'c'                 ; unchanged
    ;; ... 'c', 'd', 'g', 'h', 'i', 'j', 'k', 'l', 'o', 'v' unchanged ...
    ASSERT  'w' > 'v'           ; NEW
    DEFB    'w'                 ; NEW (Story 2.6 — FR20)
    DEFW    motion_w
    ASSERT  'y' > 'w'           ; replaces 'ASSERT y > v'
    DEFB    'y'                 ; unchanged
```

**Lex ordering verification (must be done in dev):**
  - `'$'` (0x24) — between `0x0C` and `'/'` (0x2F). ✓
  - `'G'` (0x47) — between `'>'` (0x3E) and `'O'` (0x4F). ✓
  - `'b'` (0x62) — between `'a'` (0x61) and `'c'` (0x63). ✓
  - `'w'` (0x77) — between `'v'` (0x76) and `'y'` (0x79). ✓

**Note:** `'0'` (0x30) entry remains pointed at `parser_handle_digit` per Story 1.10's design — the leading-zero detection inside parser.asm decides whether to JP motion_0 (leading) or accumulate (digit-after-prior-count). The dispatch_normal entry for `'0'` does NOT change in Story 2.6.

**Note:** `'g'` (0x67) entry remains pointed at `parser_handle_motion_prefix` per Story 1.10. The doubled-g detection inside parser.asm decides when to JP motion_gg. The dispatch_normal entry for `'g'` does NOT change.

**`DISPATCH_NORMAL_COUNT` auto-resizes** via the existing `EQU ($ - .entries) / 3` line at the bottom of `dispatch_normal`. Table grows 28 → 32 entries; binary-search worst case = `ceil(log2(32)) = 5` iterations — **unchanged from Story 2.5's 28-entry table**. NFR3 unaffected.

**Module header update.** `dispatch.asm`'s `Dependencies:` block already references `src/motions.asm (Story 2.5)`. Append: `motion_dollar / motion_G / motion_b / motion_w (Story 2.6 — new dispatch_normal entries)`.

**AC11 — Each new motion handler tail-JPs `parser_clear` on completion.**

**Given** the Story 2.5 AC7 hygiene rule: every motion handler must tail-JP `parser_clear` so the next keystroke starts with fresh parser state
**When** any of `motion_w` / `motion_b` / `motion_0` / `motion_dollar` / `motion_G` / `motion_gg` completes
**Then** the final instruction of each handler MUST be `JP parser_clear` (not `CALL parser_clear ; RET`). **Six new tail-JP sites** in motions.asm (one per handler). Combined with Story 2.5's four sites (motion_h/j/k/l), motions.asm post-2.6 has **ten `JP parser_clear` sites**.

**Grep enforcement (AC16):** `grep -nE 'JP[[:space:]]+parser_clear' src/motions.asm` returns ≥ 10 matches post-2.6.

**Read-state-then-clear discipline.** `motion_gg` MUST read `count_accumulator` BEFORE tail-JPing parser_clear (per AC7 step 1). If a maintainer "factors the count read into a common prelude" the way motion_h/j/k/l do via `motion_apply_count`, that's STILL safe — `motion_apply_count` reads count_accumulator into BC before any state mutation; subsequent parser_clear correctly zeros count. **The trap to avoid:** never insert a `parser_clear` call BEFORE reading count.

`motion_G` has the same requirement — read count_accumulator (or use `motion_apply_count`) to decide between the no-count "last line" path and the count "Nth line" path, BEFORE the tail-JP.

**AC12 — Headless tests cover all six new motions + the word-boundary classifier + the parser-stub retirement paths.**

**Given** 8 new headless tests under `test/cases/motions_*.asm` per epic line 1147 + additional coverage for edge cases the dev surfaces
**When** `make test` runs
**Then** the following pass (minimum set — dev MAY add more if AC2-AC7 step-list edge cases warrant):

  - **`motions_w-skips-whitespace.asm`** — pre-populate `"foo  bar"` (8 bytes; two spaces between 'foo' and 'bar'); cursor=0. CALL motion_w. Assert: cursor=5 (the 'b'); parser state cleared.
  - **`motions_w-non-alnum-class.asm`** — pre-populate `"foo,bar"` (7 bytes); cursor=0. CALL motion_w. Assert: cursor=3 (the ','); parser state cleared. **Pins BH1's two-class transition.**
  - **`motions_w-cross-line.asm`** — pre-populate `"foo\nbar"` (7 bytes); cursor=0. CALL motion_w. Assert: cursor=4 (the 'b' on line 1); parser state cleared. **Pins LF-as-whitespace in motion_w.**
  - **`motions_w-clamps-at-eof.asm`** — pre-populate `"hello"` (5 bytes); cursor=0. CALL motion_w. Assert: cursor=5 (file_length, EOF clamp); parser state cleared. **Pins BH2 EOF clamp.**
  - **`motions_b-from-mid-word.asm`** — pre-populate `"hello world"` (11 bytes); cursor=8 ('r'). CALL motion_b. Assert: cursor=6 (the 'w'); parser state cleared.
  - **`motions_b-from-word-start.asm`** — pre-populate `"hello world"` (11 bytes); cursor=6 ('w'). CALL motion_b. Assert: cursor=0 (the 'h'); parser state cleared. **Pins the "already at word-start, go to previous word" semantic.**
  - **`motions_b-clamps-at-bof.asm`** — pre-populate `"hello"` (5 bytes); cursor=0. CALL motion_b. Assert: cursor=0 (no move); parser state cleared.
  - **`motions_0-on-blank-line.asm`** — pre-populate `"a\n\nb"` (4 bytes); cursor=2 (the empty middle line — sitting on the LF/empty-line position). CALL motion_0. Assert: cursor=2 (no move; line_start = cursor on an empty line); parser state cleared. **Pins motion_0 against empty-line edge.**
  - **`motions_0-mid-line.asm`** — pre-populate `"hello world"` (11 bytes); cursor=6 ('w'). CALL `parser_handle_digit` with A='0' (route through the leading-zero arm). Assert: cursor=0 (line start); parser state cleared. **Pins the parser → motion_0 dispatch path post-stub-retirement.**
  - **`motions_dollar-on-empty-line.asm`** — pre-populate `"a\n\nb"` (4 bytes); cursor=2 (empty middle line). CALL motion_dollar. Assert: cursor=2 (no move per AC5 empty-line clamp); parser state cleared.
  - **`motions_dollar-mid-line.asm`** — pre-populate `"hello\nworld"` (11 bytes); cursor=2 ('l'). CALL motion_dollar. Assert: cursor=4 (the 'o' — last printable byte of line 0); parser state cleared.
  - **`motions_dollar-no-trailing-lf.asm`** — pre-populate `"hello"` (5 bytes, no LF); cursor=0. CALL motion_dollar. Assert: cursor=4 (the 'o' — file_length - 1); parser state cleared.
  - **`motions_G-no-count.asm`** — pre-populate `"line1\nline2\nline3"` (17 bytes, no trailing LF); cursor=0; count_accumulator=0. CALL motion_G. Assert: cursor=12 (start of line 3 = "line3"); parser state cleared.
  - **`motions_G-no-count-trailing-lf.asm`** — pre-populate `"line1\nline2\n"` (12 bytes, trailing LF); cursor=0; count_accumulator=0. CALL motion_G. Assert: cursor=6 (start of line 2, NOT 12 which would be the phantom past-LF line); parser state cleared. **Pins the Story-2.5 P5 lesson against motion_G.**
  - **`motions_G-with-count.asm`** — pre-populate `"line1\nline2\nline3\nline4"` (23 bytes); cursor=0; count_accumulator=2. CALL motion_G. Assert: cursor=6 (start of line 2); parser state cleared.
  - **`motions_G-with-count-clamps.asm`** — pre-populate `"line1\nline2"` (11 bytes); cursor=0; count_accumulator=100. CALL motion_G. Assert: cursor=6 (start of last line per BH2 EOF clamp); parser state cleared.
  - **`motions_gg-via-prefix.asm`** — pre-populate `"line1\nline2"` (11 bytes); cursor=8 (mid-line2). Drive parser end-to-end: `LD A, 'g' ; CALL parser_handle_motion_prefix` (first g — sets prefix); `LD A, 'g' ; CALL parser_handle_motion_prefix` (second g — dispatches motion_gg). Assert: cursor=0; parser state cleared. **Replaces the existing parser_motion-prefix-gg test's "stub fires" subtest 2 assertion** (subtest 2 currently asserts `status_dirty != 0` from the stub's message; post-2.6 it should assert `cursor == 0` from motion_gg). Update parser_motion-prefix-gg.asm accordingly OR add a new motions_gg-via-prefix.asm and adjust the stub test's expectations.
  - **`motions_gg-with-count.asm`** — pre-populate `"line1\nline2\nline3"` (17 bytes); cursor=12; count_accumulator=2. Drive parser end-to-end (two `g` calls) OR directly CALL motion_gg with count pre-set. Assert: cursor=6 (start of line 2); parser state cleared.

**Sentinel codes:** continue the 0x80..0x8F motions range from Story 2.5. Suggested allocation:
  - 0x80 — cursor_offset mismatch (B = actual lo byte; same as Story 2.5)
  - 0x81 — count_accumulator not cleared (same)
  - 0x82 — pending_operator not cleared (same)
  - 0x83 — pending_motion_prefix not cleared (same)
  - 0x84 — gap_start mutated (AR14 violation; same)
  - 0x85 — buffer content mutated (same)
  - 0x86 — mode_byte != MODE_NORMAL (same as Story 2.5 AC13 tests)
  - 0x87 — is_word_char misclassified (for any unit tests of the classifier; optional)
  - 0x88..0x8F — reserve for additional subtests

**Existing test impacted:** `test/cases/parser_motion-prefix-gg.asm` currently asserts subtest 2 fires `parser_gg_motion_stub` which sets `status_dirty`. Post-2.6 the second `g` fires `motion_gg` which does NOT set `status_dirty` (motions are silent per BH2; no status banner). The dev MUST update this test's subtest 2 expectations (or replace it wholesale with `motions_gg-via-prefix.asm`). **Same for any `parser_*-with-leading-zero` test that asserts `parser_motion_zero_stub`'s status message** — if no such test exists, no change needed; the dev should grep the test suite for `parser_motion_zero_stub` / `parser_gg_motion_stub` and update references.

**Each test follows the Story-2.5 INCLUDE pattern.** Production INCLUDEs in AR25 order (statusln → gapbuf → render → dispatch → parser → motions → exline → fileio) + test_teardown_stub + test_input_loop_stub + state.inc LAST. Gap pre-population via per-byte LD (HL) or LDIR from `.payload`.

**Live baseline becomes at least 79 pass / 1 fail** (63 post-Story-2.5-code-review + ~16 new = 79). Exact count depends on whether the dev splits any subtests further or whether the parser_motion-prefix-gg.asm rewrite changes pass-count.

**AC13 — Hardware UAT smokes the six new motions on real MicroBeast.**

**Given** UAT on hardware (Feersum MicroBeast) after `make push`
**When** I `vibe somefile.fs` (a multi-line file, at least 10 lines with mixed word/whitespace/punctuation content — `vibe.asm` itself works as a fixture since it has Z80 mnemonics, punctuation, comments)
**Then** the following steps all behave as specified:
  1. Cursor at row 0 col 0 NORMAL mode post-load.
  2. Press `w` — cursor advances to the start of the next word. On a `";; ===` comment line this skips the `";;"` to land on the `"==="` (semicolons → punctuation class → comma → `===` block).
  3. Press `w` repeatedly — cursor walks word-by-word across the line; on line-end, advances to start of next line's first word (cross-line via LF-as-whitespace per AC2).
  4. Press `b` — cursor retreats one word; symmetric behavior.
  5. Press `0` — cursor jumps to column 0 of current line. (The PARSER dispatches the leading-zero arm because count was 0.)
  6. Press `$` — cursor jumps to last printable byte of current line.
  7. Press `G` — cursor jumps to start of LAST LINE; if the file has > 22 lines, the screen scrolls (`render_scroll_adjust` advances `top_line_offset` to put the last line in view).
  8. Press `gg` — cursor jumps to start of FIRST LINE (offset 0); if a scroll was active, screen scrolls back.
  9. Press `5G` — cursor jumps to start of line 5 (counting from 1). Status row unchanged; no banner.
  10. Press `100G` — cursor jumps to start of LAST LINE per BH2 EOF clamp; silent.
  11. Press `3w` — cursor advances 3 words forward. Per epic AC line 1170 — "3w from start of 'one two three four' lands on 'f' of 'four'."
  12. Press `5b` — cursor retreats 5 words. Clamps at BOF if count exhausts the buffer's word count.
  13. **Operator+motion stranded-state smoke.** Press `d` then `w`. Observe: cursor moves forward one word (motion_w fires), the pending `d` is silently dropped (Story 2.11 will land the real compose). Press another key (`h` or `l`) and verify it behaves as a bare motion, NOT as "d still pending" misinterpretation. **Same shape as Story 2.5 AC12 step 13.**
  14. **`d0` stranded-state.** Press `d` then `0`. Observe: cursor jumps to line start (motion_0 fires), `d` silently dropped. (Same caveat — Story 2.11 lands real `d0` = delete-to-line-start.)
  15. **`dgg` stranded-state.** Press `d` then `g` `g`. Observe: cursor jumps to offset 0 (motion_gg fires), `d` silently dropped.
  16. **Mode-transition smoke (Story 2.5 AC12 step 14 regression net).** Press `5` (count accumulates), `:`, Esc (re-enter NORMAL via exline_cancel). Press `w` and verify cursor moves forward exactly ONE word, NOT 5. The Story-2.5 AC13 patch on exline_cancel_core remains load-bearing.
  17. **Sustained-typing regression.** Press `j`, `w`, `b`, `0`, `$` rapidly. Observe no dropped keystrokes, no terminal corruption, no parser-state staleness.

**Then** all observable steps behave as specified; no terminal corruption, no warm-boot from any non-`:q` step. Cursor moves where vi muscle memory expects; clamps are silent.

**Hardware UAT executed by user, per Stories 1.11 / 1.12 / 2.1 / 2.2 / 2.3 / 2.4 / 2.5 pattern.** The dev environment has no SLIDE / hardware connection; the user runs `make push` and steps through the UAT script after the headless gates are all green. Document the UAT result in Debug Log References.

**AC14 — NFR9 amend is BLOCKING for Story 2.6 — must be resolved before final build.**

**Given** the post-Story-2.5 footprint at 4082 B / ~132% of original NFR9 ceiling / 14 B of headroom against the proposed 4096 B amended ceiling (deferred-work.md line 130 escalation)
**And** Story 2.6's projected size delta (~150-250 B for six new motion handlers + is_word_char + parser-stub retirement net = ~150-200 B; the parser-stub retirement reclaims ~20 B because two stubs go away; the new motion bodies add ~170-220 B):
  - motion_w / motion_b bodies: ~50 B each (the word-class walk with the inline whitespace test)
  - motion_0 body: ~12 B (single call to motion_find_line_start + tail-JP)
  - motion_dollar body: ~18 B (motion_find_line_end + DEC + tail-JP + empty-line guard)
  - motion_G body: ~50-60 B (the line-walk loop + count-vs-no-count branch)
  - motion_gg body: ~25 B with shared find-line-n helper, ~50 B if open-coded
  - is_word_char body: ~25-30 B
  - 4 new dispatch_normal entries: 4 × 3 = 12 B
  - Two parser stubs retired: -20 B (each was ~10 B for `LD HL, msg ; XOR A ; CALL status_set_message ; RET/JP`)
  - **Net projected delta: +150-200 B; post-Story-2.6 footprint: 4232-4282 B.**

**When** the dev pass runs `make sizes`
**Then** ONE of the following MUST happen before Story 2.6 is marked ready for review:

  **Option A — Land the NFR9 amend FIRST (recommended; the spec author's escalation in deferred-work.md line 130 says "cannot defer past Story 2.6's planning"):**
  - Update `_bmad-output/planning-artifacts/prd.md` NFR9 section (lines 848-851) to raise the ceiling to **5120 B / 5 KB** (the recommended value per the deferred-work entry) OR reclassify NFR9 as monitored.
  - Update `_bmad-output/planning-artifacts/architecture.md` if NFR9 is referenced in architectural decisions (grep first).
  - Update `_bmad-output/implementation-artifacts/deferred-work.md` lines 122-130 to mark the entry RESOLVED with the new ceiling value.
  - This is a PRD/architecture change — separate commit from the motions code. The dev SHOULD bundle this with Story 2.6's main commit (mirroring Story 2.5's deferred-NFR9-escalation pattern) OR land it as a sibling commit on the same branch.

  **Option B — Aggressive code-shrink during dev to fit under 4096 B:**
  - Factor `motion_find_line_n` shared between motion_G + motion_gg (saves ~30 B).
  - Use the bitmap-lookup variant of `is_word_char` (saves ~5 B vs the cascading CP variant).
  - Inline `motion_apply_count` at each call site (saves ~10 B but bloats each caller; net neutral or worse — NOT recommended).
  - **Realistic best-case shrink: ~30-50 B.** Story 2.6 post-shrink: 4180-4230 B — STILL OVER the 4096 B amended ceiling.
  - **Option B is therefore INSUFFICIENT.** Story 2.6 cannot complete under the current ceiling without dropping AC scope, which the deferred-work entry explicitly disallows ("Do NOT skip safety paths to fit" — NFR9 PRD line 850).

  **Option C — Drop one motion from Story 2.6 to fit:**
  - Defer `motion_G` or `motion_gg` to a later story. **NOT RECOMMENDED** — both are FR22 commitments; the epic's AC list explicitly requires all six motions; deferring breaks the FR22 deliverable.

  **Decision: Option A.** Land the NFR9 amend at the START of the dev pass, BEFORE writing the motion bodies. The amend is mechanical (text change in prd.md) and unblocks the rest of the work cleanly. Capture the PRD amend as the FIRST commit on the branch, followed by the motions code as a separate commit (or commits per task).

**Verbatim NFR9 amend text (suggested — dev may rephrase):**
```markdown
- **NFR9:** vibe.com fits within 5120 bytes of code (5 KB; amended 2026-05-15 from
  the original 3072 B target after Stories 2.2-2.5 fileio + motions footprint
  showed the 3 KB target was set pre-fileio and pre-motions implementation).
  The amended ceiling preserves the original spirit (small editor fits MicroBeast's
  tight TPA pressure) while accommodating realistic per-feature footprint. Stories
  2.6-2.13 monitor against this ceiling; further amends require an explicit retro
  review. Safety paths (FR52 buffer-dirty preservation, FR51 oversize-refusal,
  BH2 clamps) are exempt from byte-shaving pressure.
```

**Post-amend AC14 success criteria:**
  - `make clean && make` succeeds twice consecutively (NFR14 + NFR18 reproducibility).
  - `make sizes` reports the new size; expected 4232-4282 B / ~83-84% of new 5120 B ceiling.
  - Capture both SHA-256 values in Debug Log References.

**AR enforcement sweeps (same shape as Story 2.5 AC14):**
  - **AR13** — `grep -nE 'BIOS_CONOUT' src/motions.asm`: zero code matches. (Motions still don't emit screen bytes.)
  - **AR14** — `grep -nE 'gapbuf_(insert|delete|move_gap)' src/motions.asm`: zero matches. (Motions still don't mutate the gap buffer.)
  - **AR14** — `grep -nE 'LD[[:space:]]+\(gap_start\)|LD[[:space:]]+\(gap_end\)' src/motions.asm`: zero matches.
  - **AR15** — `grep -nE 'CALL[[:space:]]+0x0005|CALL[[:space:]]+BDOS_ENTRY|BDOS_CALL' src/motions.asm`: zero matches.
  - **Parser-clear hygiene** — `grep -nE 'JP[[:space:]]+parser_clear' src/motions.asm`: at least 10 matches (Story 2.5's 4 + Story 2.6's 6).
  - **Stub retirement** — `grep -n 'parser_motion_zero_stub\|parser_gg_motion_stub' src/parser.asm`: zero matches (the symbols disappear). `grep -n 'parser_doubled_operator_stub' src/parser.asm`: matches preserved (Story 2.10 scope).
  - **Cursor-only mutation** — `grep -nE 'LD[[:space:]]+\(cursor_offset\)' src/motions.asm`: ≥ 10 matches (Story 2.5's 4 + Story 2.6's 6).

**AC15 — `architecture.md` AR carve-out doc update — STILL DEFERRED is acceptable.**

**Given** the AC15 deferral from Story 2.5 (third deferral; the architecture.md AR14 / AR15 doc update is "MAY (not MUST)" per Story 2.5 AC15 spec text)
**When** Story 2.6 lands six new motions and retires two stubs
**Then** the dev MAY (not MUST) land the architecture.md update alongside the NFR9 amend commit. Scope:
  - architecture.md § Core Architectural Decisions § AR14: note that fileio.asm has one documented carve-out for linear-fill (Story 2.2).
  - architecture.md § Core Architectural Decisions § AR15: note that fileio.asm has two documented carve-outs (Story 2.3 launch open + Story 2.4 save delete-then-make + Story 2.4-fix save-precheck = three total). motions.asm is the first "clean module" archetype with zero AR carve-outs.
  - architecture.md § Subsystem Map line 244: update the `motions.asm` comment from `# h j k l w b 0 $ G gg, count-aware` to match the actual public surface (the architecture comment already matches Story 2.6's public surface — no change needed).

**Bundle recommendation:** if the dev does Option A (NFR9 amend), bundle the AR doc update into the same PRD/architecture commit. If Option A's PRD edit feels like enough planning-doc work for one commit, defer AC15 again — but this is the FOURTH deferral and is escalating into a documentation-debt liability. **Strongest recommendation: land the AR doc update with the NFR9 amend.**

**No production-code changes from this AC.**

**AC16 — Build invariants and AR enforcement (subsumes the static enforcement portion of AC14).**

**Given** Story 2.6's source changes (motions.asm body growth + parser.asm stub retirement + dispatch.asm new entries + vibe.asm INCLUDE chain unchanged because motions.asm is already INCLUDEd)
**When** `make clean && make` runs twice consecutively
**Then**:
  - Both runs succeed (NFR14 sjasmplus 1.23.0 pinned).
  - The two resulting `vibe.com` files are byte-identical (NFR18 reproducibility).
  - All AR grep sweeps clean (per AC14).
  - `make test` from project root reports the new pass count; live baseline should be **≥ 79 pass / 1 fail** (63 post-Story-2.5-code-review + ~16 new).

**Module-local scratch convention preserved.** No new DEFW cells in motions.asm (per AC1). `motions_col` / `motions_target_start` retain their Story-2.5 placement and semantics.

**`src/vibe.asm` AR25 INCLUDE chain UNCHANGED.** motions.asm is already INCLUDEd between parser.asm and exline.asm per Story 2.5 AC9. The Story 2.5 comment block above the INCLUDE may be updated to remove the "(motions.asm — Story 2.5+)" qualifier and to mention Story 2.6's additions, but this is cosmetic.

## Tasks / Subtasks

- [x] **Task 1: Land NFR9 amend FIRST (AC14, Option A — gating commit)**
  - [x] Sub 1.1: Edit `_bmad-output/planning-artifacts/prd.md` NFR9 (lines 848-851) to raise the ceiling to 5120 B per AC14's verbatim suggestion (or rephrase as long as the numeric value and the "monitored" intent are preserved).
  - [x] Sub 1.2: Update `_bmad-output/implementation-artifacts/deferred-work.md` line 122-130 — mark the NFR9 amend RESOLVED with the new ceiling value; preserve the historical context (the per-story footprint progression is useful for retrospectives).
  - [x] Sub 1.3: Grep `_bmad-output/planning-artifacts/architecture.md` for `NFR9` references; if any exist, update to the new ceiling.
  - [x] Sub 1.4: AC15 architecture.md AR carve-out doc update — bundle here OR defer once more. If bundling, edit architecture.md § AR14 and § AR15 to note the fileio.asm carve-outs + motions.asm clean-module status.
  - [x] Sub 1.5: Commit as a SEPARATE planning-artifacts commit. Suggested message: `story 2.6 prep: Amended NFR9 ceiling 3072 → 5120 B reflecting fileio + motions footprint reality; documented AR carve-outs.`

- [x] **Task 2: Add `is_word_char` internal helper to `src/motions.asm` (AC8)**
  - [x] Sub 2.1: Place the helper near the bottom of motions.asm, after motion_apply_count and BEFORE the module-local DEFW cells (motions_col / motions_target_start). Match Story-2.5's internal-helper section convention.
  - [x] Sub 2.2: AR23 contract block: `In: A = byte to classify ; Out: Z iff word-class (alnum + underscore); A preserved ; Trashes: F ; Calls: (none)`.
  - [x] Sub 2.3: Implement via cascading CP / JR comparisons OR a 16-byte bitmap lookup — dev's call based on size pressure. Document the choice in the AR23 contract block's `Notes:` line.

- [x] **Task 3: Implement `motion_w` and `motion_b` (AC2, AC3, AC11)**
  - [x] Sub 3.1: motion_w body per AC2 step list; uses is_word_char + an inline whitespace test (`CP 0x21 ; JR C, .is_whitespace`).
  - [x] Sub 3.2: motion_b body per AC3 step list; symmetric structure with backward walks.
  - [x] Sub 3.3: Each ends with `JP parser_clear` (tail-JP).
  - [x] Sub 3.4: AR23 contract blocks per AC1.
  - [x] Sub 3.5: Decide on internal helper extraction (e.g., `motion_skip_word_class_fwd` shared with motion_b's backward variant) — only if it reads cleaner without growing total bytes.

- [x] **Task 4: Implement `motion_0`, `motion_dollar`, `motion_G`, `motion_gg` (AC4, AC5, AC6, AC7, AC11)**
  - [x] Sub 4.1: motion_0 body per AC4 (call motion_find_line_start, save, tail-JP parser_clear).
  - [x] Sub 4.2: motion_dollar body per AC5 (call motion_find_line_end, handle empty-line, DEC, save, tail-JP).
  - [x] Sub 4.3: motion_G body per AC6 with the no-count vs with-count split. The trailing-LF clamp (P5 lesson) is load-bearing.
  - [x] Sub 4.4: motion_gg body per AC7 with the count read BEFORE clear.
  - [x] Sub 4.5: **Decide on `motion_find_line_n` shared helper** between motion_G's with-count path and motion_gg's with-count path. Estimated savings ~30 B; recommended.
  - [x] Sub 4.6: AR23 contract blocks per AC1.
  - [x] Sub 4.7: Each handler tail-JPs `parser_clear`.

- [x] **Task 5: Retire parser stubs and rewire JPs (AC9)**
  - [x] Sub 5.1: Delete `parser_motion_zero_stub` routine body from src/parser.asm.
  - [x] Sub 5.2: Delete `parser_gg_motion_stub` routine body from src/parser.asm.
  - [x] Sub 5.3: Update `parser_handle_digit`'s leading-zero arm: `JP parser_motion_zero_stub` → `JP motion_0`.
  - [x] Sub 5.4: Update `parser_handle_motion_prefix`'s doubled-prefix arm: `JP parser_gg_motion_stub` → `JP motion_gg`.
  - [x] Sub 5.5: Update parser.asm module header `Public:` list — drop the two retired symbols. The `parser_doubled_operator_stub` entry STAYS (Story 2.10 scope).
  - [x] Sub 5.6: Update parser.asm module header `Dependencies:` block — add `src/motions.asm (Story 2.6 — motion_0 / motion_gg forward-referenced from the leading-zero and doubled-g arms)`.

- [x] **Task 6: Add four entries to `dispatch_normal` (AC10)**
  - [x] Sub 6.1: Insert `'$'` entry (0x24) between `0x0C` and `'/'`; re-stitch `ASSERT '$' > 0x0C` and `ASSERT '/' > '$'`.
  - [x] Sub 6.2: Insert `'G'` entry (0x47) between `'>'` and `'O'`; re-stitch `ASSERT 'G' > '>'` and `ASSERT 'O' > 'G'`.
  - [x] Sub 6.3: Insert `'b'` entry (0x62) between `'a'` and `'c'`; re-stitch `ASSERT 'b' > 'a'` and `ASSERT 'c' > 'b'`.
  - [x] Sub 6.4: Insert `'w'` entry (0x77) between `'v'` and `'y'`; re-stitch `ASSERT 'w' > 'v'` and `ASSERT 'y' > 'w'`.
  - [x] Sub 6.5: Verify `DISPATCH_NORMAL_COUNT` auto-resizes (28 → 32 entries).
  - [x] Sub 6.6: Update dispatch.asm Dependencies block to mention the new Story-2.6 forward references.

- [x] **Task 7: Update existing `parser_motion-prefix-gg.asm` test for stub→real-handler swap (AC12)**
  - [x] Sub 7.1: Subtest 2 currently asserts `status_dirty != 0` after the second `g` (stub fires its "not yet implemented" message). Change to assert `cursor_offset == 0` after the second `g` (motion_gg dispatches the no-count path).
  - [x] Sub 7.2: Subtest 2's sentinel 0xE4 (was "stub did not fire") becomes "cursor did not move to 0". Document the change in the test header comment.
  - [x] Sub 7.3: Subtest 3's expectation that count clears post-doubled-g still holds (motion_gg tail-JPs parser_clear, same as the old stub). No change.
  - [x] Sub 7.4: The test imports motions.asm via the existing AR25 INCLUDE chain — no INCLUDE changes needed.

- [x] **Task 8: Add new headless tests under `test/cases/motions_*.asm` per AC12 (16 new tests minimum)**
  - [x] Sub 8.1: `motions_w-skips-whitespace.asm`
  - [x] Sub 8.2: `motions_w-non-alnum-class.asm`
  - [x] Sub 8.3: `motions_w-cross-line.asm`
  - [x] Sub 8.4: `motions_w-clamps-at-eof.asm`
  - [x] Sub 8.5: `motions_b-from-mid-word.asm`
  - [x] Sub 8.6: `motions_b-from-word-start.asm`
  - [x] Sub 8.7: `motions_b-clamps-at-bof.asm`
  - [x] Sub 8.8: `motions_0-on-blank-line.asm`
  - [x] Sub 8.9: `motions_0-mid-line.asm` (route through parser_handle_digit's leading-zero arm — pins the stub→real-handler swap)
  - [x] Sub 8.10: `motions_dollar-on-empty-line.asm`
  - [x] Sub 8.11: `motions_dollar-mid-line.asm`
  - [x] Sub 8.12: `motions_dollar-no-trailing-lf.asm`
  - [x] Sub 8.13: `motions_G-no-count.asm`
  - [x] Sub 8.14: `motions_G-no-count-trailing-lf.asm` (pins the P5 lesson)
  - [x] Sub 8.15: `motions_G-with-count.asm`
  - [x] Sub 8.16: `motions_G-with-count-clamps.asm`
  - [x] Sub 8.17: `motions_gg-via-prefix.asm` (drives parser end-to-end with two `g` calls)
  - [x] Sub 8.18: `motions_gg-with-count.asm`
  - [x] Sub 8.19: All tests follow the Story-2.5 INCLUDE pattern (AR25-order production INCLUDEs after body; state.inc LAST; test_teardown_stub + test_input_loop_stub).
  - [x] Sub 8.20: Sentinel codes 0x80..0x86 reused per AC12.

- [x] **Task 9: Build + headless test verification (AC16)**
  - [x] Sub 9.1: `make clean && make` succeeds; capture SHA-256 of `vibe.com`.
  - [x] Sub 9.2: Second `make clean && make` — byte-identical SHA (NFR18). Capture both.
  - [x] Sub 9.3: `make sizes` reports new code-section size. Expected 4232-4282 B (well under amended 5120 B ceiling).
  - [x] Sub 9.4: AR grep sweeps all clean per AC14's enforcement list.
  - [x] Sub 9.5: `make test` from project root passes ≥ 79 pass / 1 deliberate fail.
  - [x] Sub 9.6: Confirm `parser_motion-prefix-gg.asm` still passes after Task 7's update.

- [x] **Task 10: Update `_bmad-output/implementation-artifacts/deferred-work.md`**
  - [x] Sub 10.1: Mark line 93-94 (parser stubs tail-JP before state-read) RESOLVED for the gg arm by motion_gg (motion_0 case is trivial — count was always 0 by precondition).
  - [x] Sub 10.2: Add a new "Deferred from: dev of story-2-6-..." section if any non-trivial follow-ups surface during dev (Story 2.7 count-respected end-to-end coverage, sticky-column across counted j/k, etc. — see the Story-2.5 review deferrals that remain pending).
  - [x] Sub 10.3: If the dev factored a `motion_find_line_n` shared helper, document the choice + the helper's reusability for Story 3.1's search (line N→ direct jump in `/pattern` results).

- [x] **Task 11: Hardware UAT (AC13)** — *requires user execution via `make push`*
  - [x] Sub 11.1: `make push` — SLIDE transfer to MicroBeast.
  - [x] Sub 11.2: Execute the 17-step AC13 UAT script.
  - [x] Sub 11.3: Capture observations in Debug Log References.
  - [x] Sub 11.4: On any UAT failure: triage, propose fix, re-build, re-push, retest. Document the iteration in the Change Log table (matching Story 2.5's two-iteration pattern).

## Dev Notes

### Architecture compliance

Story 2.6 closes the FR18-FR22 motion-set with the six new motions. **motions.asm grows substantively but remains AR13 / AR14 / AR15 clean** — no carve-outs, no screen emission, no buffer mutation, no BDOS. The story is a pure-extension of the Story-2.5 module shape.

- **FR20 (w/b word motions).** Primary deliverable. AC2 + AC3. BH1 word-boundary classifier (is_word_char) lands as the substrate.
- **FR21 (0/$ line motions).** Primary deliverable. AC4 + AC5. Reuses Story-2.5's motion_find_line_start (motion_0) and motion_find_line_end (motion_dollar).
- **FR22 (gg/G buffer motions).** Primary deliverable. AC6 + AC7. The "with count C" branch is shared between motion_G and motion_gg via the recommended `motion_find_line_n` helper.
- **BH1 (word-boundary rules).** First production consumer: motion_w / motion_b via is_word_char. Whitespace separates the two character classes (alnum+underscore vs non-whitespace-non-(a)). LF is whitespace per the BH1-amended definition.
- **BH2 (counted-motion bounds — clamp at BOF/EOF).** All six new motions clamp silently:
  - motion_w clamps at EOF (cursor reaches file_length during the word-class or whitespace skip).
  - motion_b clamps at BOF (cursor reaches 0 during the backward skip).
  - motion_0 — no clamp; line_start is the target, motion_find_line_start always returns a valid offset.
  - motion_dollar — clamps at the LF byte (cursor never lands on LF, lands on last printable byte).
  - motion_G — clamps at start of last line if count > line count.
  - motion_gg — same as motion_G's count path.
- **SR1 (cursor as 16-bit absolute buffer offset).** Six new writers in motions.asm. Cursor is still the sole motion-side state surface.
- **SR2 (gap-buffer two-halves invariant).** Motions read; gapbuf writes. AR14 unchanged.
- **SR3 (cursor-to-buffer mapping).** motion_byte_at_logical (Story 2.5's private helper) is the read primitive for all six new motions. No need to revisit Path A vs Path B (Story 2.5 AC16 decision) — Story 2.6 stays in motions.asm.
- **SR7 (no line-position cache in MVP).** motion_G's full-buffer walk (worst case: O(file_length) bytes scanned to find the last line on a long file) is the FIRST motion to genuinely stress this. NFR3 envelope: ~50 T-states per byte_at_logical call × file_length. For a 4 KB file: 4096 × 50 = 200,000 T-states ≈ 50 ms at 4 MHz — interactive-but-noticeable. The deferred line-position cache (deferred-work.md line 83) is NOT load-bearing for Story 2.6's gg/G IF file sizes stay under ~5 KB; revisit if hardware UAT shows perceptible stutter on `G` for big files.
- **MC1 (caller-saved everywhere).** Each motion handler trashes A, BC, DE, HL, F per AR23. IX is NOT clobbered.
- **MC3 (dispatch tables sparse sorted, binary-search).** dispatch_normal grows 28 → 32 entries; binary-search worst case stays at 5 iterations.
- **MC4 (handler signature — A=key on entry; state from fixed addresses).** Motion handlers read count_accumulator via state.inc symbols.
- **MC5 (single status-message funnel).** Motion handlers don't emit status — silent per BH2. NOT invoked.
- **AR12-AR15.** motions.asm remains clean: no carve-outs, no status writes (motions are silent), no screen emission, no buffer mutation, no BDOS.
- **AR22 (naming).** New public symbols: `motion_w`, `motion_b`, `motion_0`, `motion_dollar`, `motion_G`, `motion_gg`. New internal: `is_word_char` (and possibly `motion_find_line_n`). Matches the `module_action` convention.
- **AR23 (file structure and routine contracts).** Each new public + internal helper has the four-line `In:` / `Out:` / `Trashes:` / `Calls:` contract.
- **AR25 (module include order).** UNCHANGED — motions.asm is already in the chain between parser.asm and exline.asm.

### Library / framework requirements

**sjasmplus 1.23.0:**
- Forward-reference handling: `parser.asm` references `motion_0` and `motion_gg` (defined in motions.asm, which INCLUDEs after parser.asm). Same two-pass resolution as Story 2.5's dispatch_normal → motion_h/j/k/l.
- Local-label scoping: each motion handler may use `.step` / `.done` / `.clamp_*` dotted-locals; sjasmplus scopes them to the most recent non-dotted label (the handler's public symbol). Story 2.5 navigated this successfully; Story 2.6 follows the same pattern.

**iz-cpm:**
- All ~16 new headless tests run under iz-cpm.
- No new BDOS interactions — motions are pure-memory. No iz-cpm vs real-CP/M divergence concerns.
- Sentinel pattern unchanged. TH1 0xCFFE = 0 on pass, fail code on fail.

**CP/M 2.2 BDOS / MicroBeast BIOS:**
- No new BDOS surface.
- No new BIOS surface.

**Z80 instruction set:**
- The new motion bodies use the standard 16-bit compare via `SBC HL, DE` after `OR A`, and 16-bit-zero test via `LD A, H ; OR L`. No new sjasmplus macros required.
- The line-walk loops in motion_G / motion_gg / motion_find_line_n (if extracted) use the same `CALL motion_byte_at_logical` / `CP 0x0A` shape as Story-2.5's motion_find_line_end.
- The `is_word_char` helper uses 4-5 cascading `CP value ; JR C/Z, label` instructions — standard Z80 byte-classification idiom.

### Filename and module placement choices

**motions.asm continues to own all motion handlers + helpers.** Story 2.5's AC16 Path A decision (SR3 byte-read as motions.asm-private) persists — Story 2.6's new handlers all share `motion_byte_at_logical` without needing to elevate it to a public gapbuf entry.

**Possible Story 3.1 re-do.** If search.asm (Story 3.1) needs the same byte-read, the natural extraction is to gapbuf.asm as `gapbuf_byte_at_logical` (the architectural ideal per the AR14 boundary doc). Story 2.6 doesn't pre-empt that decision — the helper stays motions-private for now.

**Shared `motion_find_line_n` helper placement.** If the dev factors the "walk to line N" helper between motion_G and motion_gg, it lives in motions.asm as a module-private helper (same placement as motion_find_line_start / _end). Naming: `motion_find_line_n` returning HL = offset of start of line BC (1-indexed) or last-line-start if BC exceeds the line count.

### Operator+motion future-proofing — IMPORTANT for the dev

Story 2.6's motion handlers tail-JP `parser_clear` unconditionally per AC11 — same as Story 2.5. This DROPS any pending operator on a bare motion. Concrete consequences for Story 2.6:
  - `dw` (delete-word) currently runs motion_w (cursor moves forward one word) and parser_clear zeroes the pending 'd' — no delete.
  - `d0` runs motion_0 (cursor to line-start) and drops the 'd'.
  - `d$` runs motion_dollar (cursor to line-end) and drops the 'd'.
  - `dG` runs motion_G (cursor to last line) and drops the 'd'.
  - `dgg` runs motion_gg (cursor to first line) and drops the 'd'.

Story 2.11 will replace the bare-motion dispatch with operator+motion compose. **Do NOT add operator-aware branching to the motion handlers in Story 2.6** — it's Story 2.11's scope.

**motion_gg + motion_0 are the FIRST handlers dispatched FROM the parser's internal arms (not from dispatch_normal direct entries).** This is the critical distinction Story 2.5's deferred-work line 93-94 forward-flagged. The discipline is:
  1. motion_gg / motion_0 read count_accumulator BEFORE tail-JPing parser_clear (motion_0 doesn't actually need to — its precondition is count == 0 — but the pattern is still: read state THEN tail-JP).
  2. motion_gg dispatched via `parser_handle_motion_prefix` → `JP motion_gg`; motion_gg's RET (via parser_clear's RET) returns to parser_handle_motion_prefix's CALLER (dispatch_key's `.dispatch` label).
  3. Same stack discipline as Story 2.5's motion_h/j/k/l, just dispatched through one more JP hop.

### Render integration — no changes required

Same shape as Story 2.5 AC10. Motion handlers update cursor_offset only; render's RI4 cursor-emit picks it up automatically on the next render_diff frame. No motion-side render_mark_* calls. The CR-filter in render_emit_one_row (Story 2.5 UAT iteration 2) continues to handle CRLF files gracefully.

**Big-`G` scroll surface.** `motion_G` is the first motion that can jump the cursor MANY lines forward (or back, via `1G`). render_scroll_adjust's iterative advance loop is exercised: walking from line 1 to line 100 means advancing top_line_offset by ~77 lines (assuming a 22-row editable region with cursor on the last line means top is at line 78). The far-jump O(N × 1840) concern (deferred-work.md line 83) becomes load-bearing here. **If hardware UAT step 7 shows perceptible stutter on `G` for a long file, the deferral may need promotion to a follow-up story.** Pre-amend, assume the current iterative-advance is fast enough; Story 2.5's `j` past EDITABLE_ROWS already exercised the same path on smaller jumps.

### Previous story intelligence

**From Story 2.5 (most relevant — direct predecessor):**
- motions.asm shape, SR3 byte-read helper, motion_find_line_start / _end helpers, the parser_clear tail-JP convention, the AC13 mode-handler parser_clear hygiene, the CR-filter in render_emit_one_row, the BC-preservation invariant across helpers.
- **The Story-2.5 P5 motion_j trailing-LF clamp lesson:** files ending in 0x0A produce a phantom past-LF line; motion_G's "walk to last line" must apply the same clamp. AC6 spells out the algorithm.
- **AC13 patches in dispatch.asm:** five `RET → JP parser_clear` patches (enter_normal_mode, enter_insert_mode, enter_visual_mode, unbound_normal, unbound_visual) + the AC13 post-UAT addition in exline_cancel_core. These remain load-bearing for the Story 2.6 AC13 step 16 hardware UAT step.
- **Test pattern + sentinel code range:** 0x80..0x8F range; AR25-order INCLUDEs after test body; test_teardown_stub + test_input_loop_stub; state.inc LAST.

**From Story 1.10 (parser — direct interaction):**
- `parser_handle_digit`'s leading-zero arm currently JPs `parser_motion_zero_stub`. Story 2.6 retargets to `motion_0`.
- `parser_handle_motion_prefix`'s doubled-prefix arm currently JPs `parser_gg_motion_stub`. Story 2.6 retargets to `motion_gg`.
- `parser_handle_motion_prefix`'s ASYMMETRY (per parser.asm:359-364): it does NOT clear pending_motion_prefix on entry — the doubled-g detection NEEDS the prior value. Story 2.6 must NOT touch this.
- `parser_clear` zeros all three parser state fields: count_accumulator, pending_operator, pending_motion_prefix. motion_gg / motion_0 / etc. tail-JP this same routine.
- `parser_doubled_operator_stub` UNCHANGED by Story 2.6 (Story 2.10 lands real dd/yy/cc/<<<>>).

**From Story 1.11 (render):**
- render_scroll_adjust's iterative advance loop becomes load-bearing for motion_G's far-jump (see Render integration note above).
- The CR-filter in render_emit_one_row handles CRLF files gracefully; Story 2.6 doesn't need to revisit this.

**From Story 1.7 (gap buffer):**
- `gap_start` / `gap_end` are state.inc-resident; motions read, never write. AR14 clean.
- `GAP_BUFFER_BASE` (state.inc) / `GAP_BUFFER_MAX` (equates.inc) are the substrate for the SR3 math.
- The empty-buffer case (file_length = 0) is the first edge every motion handler must clamp on entry. Tests pin this for w / b (CF=1 on entry to motion_byte_at_logical short-circuits the walk).

### Git intelligence

Most-recent five commits per `git log`:
- `2149fc8` — story 2.5: Wired the cursor; h/j/k/l move with clamps, counts wired, parser cleared on mode change; CRLF tolerance in render.
- `f8f6d67` — Story 2.4 review: fixed :wq warm-boot on R/O save (FR52); 2 minor patches.
- `1515fc0` — story 2.3: vibe foo.fs opens the file; missing names get [new file].
- `0f1f980` — story 2.2: Wrote file load; :e opens a file, :e! forces past a dirty buffer.
- `be42853` — story 2.1: Wrote the : command-line; :q quits, :q! force-quits, Backspace and Esc work.

**Repo conventions to preserve in Story 2.6:**
- One story per main commit; code-review patches as a SEPARATE commit AFTER the main commit. Short imperative subject + colon-separated context. Plain-English style (no commit prefixes like "feat:" / "fix:").
- AR23 header blocks on every `.asm` and `.inc` file.
- Every public routine has the four-line contract.
- **NEW for Story 2.6:** the NFR9 amend lands as a SEPARATE planning-artifacts commit BEFORE the motions code commit (Task 1 Sub 1.5). Suggested subjects:
  - Planning commit: `story 2.6 prep: Amended NFR9 ceiling 3072 → 5120 B reflecting fileio + motions footprint reality; documented AR carve-outs.`
  - Code commit: `story 2.6: Wired word/line/buffer motions; w/b/0/$/gg/G with counts; parser stubs retired for motion-0 and gg.`

### Testing requirements

Story 2.6's testing requirements split into four categories:

**Build-time / static:**
1. `make` succeeds (NFR14 / AC16).
2. `make clean && make` produces byte-identical `vibe.com` across two runs (NFR18 / AC16). Capture both SHAs.
3. `make sizes` reports new code-section size. Expected 4232-4282 B / ~83-84% of amended 5120 B ceiling. **Flag prominently if delta exceeds projected +150-200 B** (could indicate is_word_char or motion_G came in heavier than estimated; consider Sub 4.5's shared-helper extraction).
4. AR grep sweeps clean (AC14/AC16). motions.asm zero carve-outs preserved. Parser stubs disappeared (zero matches for `parser_motion_zero_stub` / `parser_gg_motion_stub`).

**Headless test cases (~16 new motions tests + 1 updated parser test):**

5-20. The 16 tests per AC12 Sub 8.1-8.18 + the parser_motion-prefix-gg.asm subtest 2 update per Task 7.

21. **Live baseline becomes ≥ 79 pass / 1 fail** (63 post-Story-2.5 + 16 new).

**Regression-net tests (unchanged source — must continue to pass):**

22. All Story 2.1-2.5 tests pass — the only production changes are additive (six new motion handlers + is_word_char + dispatch_normal grew by 4 entries) plus the parser stub retirement (which the parser_motion-prefix-gg.asm test is the only existing consumer of — updated per Task 7).
23. Story 2.5's 16 motions tests remain byte-equivalent in expectations (motion_h/j/k/l unchanged).
24. **Parser_motion-prefix-cleared-on-other-key.asm** continues to verify the asymmetric-clear protocol — pending_motion_prefix is cleared on a digit or operator key. Story 2.6 doesn't change this.

**Hardware UAT (AC13):**

25. SLIDE-push and exercise the 17-step AC13 UAT script. Particular regressions to watch:
  - All six new motions visible cursor moves within one render frame (NFR3).
  - All clamps silent (no banner) per BH2.
  - `dw` / `d0` / `d$` / `dG` / `dgg` leave editor in clean NORMAL state with parser cleared.
  - `G` on a long file (> 22 lines) scrolls cleanly (the first time the iterative scroll-advance is exercised for a multi-line jump).
  - Mode-transition `5 : Esc w` regression net (the Story-2.5 AC13 patch on exline_cancel_core).
  - Sustained-typing across w/b/0/$/G/gg keystrokes.

### Project Structure Notes

After Story 2.6 the source tree is:

```
src/
├── vibe.asm          # Unchanged (motions.asm already in AR25 chain since Story 2.5)
├── init.asm          # Unchanged
├── input.asm         # Unchanged
├── statusln.asm      # Unchanged (motions silent — no status writes)
├── gapbuf.asm        # Unchanged (motions read, gapbuf writes)
├── render.asm        # Unchanged (RI4 cursor-emit picks up cursor_offset automatically)
├── dispatch.asm      # Story 2.6 — 4 new dispatch_normal entries ($, G, b, w) with ASSERT re-stitching
├── parser.asm        # Story 2.6 — parser_motion_zero_stub + parser_gg_motion_stub retired; JPs retargeted to motion_0 / motion_gg
├── motions.asm       # Story 2.6 — body grows: motion_w, motion_b, motion_0, motion_dollar, motion_G, motion_gg + is_word_char helper (+ optional motion_find_line_n shared helper)
├── exline.asm        # Unchanged
└── fileio.asm        # Unchanged

inc/
├── equates.inc       # Unchanged
├── bios.inc          # Unchanged
├── bdos.inc          # Unchanged
├── modes.inc         # Unchanged
├── vt52.inc          # Unchanged
└── state.inc         # Unchanged

test/
├── README.md
├── Makefile          # Unchanged (motion tests use direct gap-region writes)
├── inc/              # Unchanged
├── fixtures/         # Unchanged
└── cases/
    ├── ... (existing tests, 16 of which are Story 2.5 motions_*)
    ├── parser_motion-prefix-gg.asm                 # MODIFIED (Task 7 — subtest 2 expectations updated)
    ├── motions_w-skips-whitespace.asm              # NEW
    ├── motions_w-non-alnum-class.asm               # NEW
    ├── motions_w-cross-line.asm                    # NEW
    ├── motions_w-clamps-at-eof.asm                 # NEW
    ├── motions_b-from-mid-word.asm                 # NEW
    ├── motions_b-from-word-start.asm               # NEW
    ├── motions_b-clamps-at-bof.asm                 # NEW
    ├── motions_0-on-blank-line.asm                 # NEW
    ├── motions_0-mid-line.asm                      # NEW (via parser leading-zero arm)
    ├── motions_dollar-on-empty-line.asm            # NEW
    ├── motions_dollar-mid-line.asm                 # NEW
    ├── motions_dollar-no-trailing-lf.asm           # NEW
    ├── motions_G-no-count.asm                      # NEW
    ├── motions_G-no-count-trailing-lf.asm          # NEW (P5 lesson)
    ├── motions_G-with-count.asm                    # NEW
    ├── motions_G-with-count-clamps.asm             # NEW
    ├── motions_gg-via-prefix.asm                   # NEW (via parser doubled-g arm)
    └── motions_gg-with-count.asm                   # NEW
```

### Files created and modified by this story

**Files created (production):** *(none — motions.asm grows but isn't new)*

**Files modified (production):**
- `src/motions.asm` — Tasks 2-4: motion_w, motion_b, motion_0, motion_dollar, motion_G, motion_gg + is_word_char (+ optional motion_find_line_n). Module header `Public:` list grows. **AC1 enforcement: zero new DEFW cells.**
- `src/parser.asm` — Task 5: retire parser_motion_zero_stub + parser_gg_motion_stub bodies; retarget JPs to motion_0 / motion_gg; header `Public:` list shrinks; Dependencies block grows.
- `src/dispatch.asm` — Task 6: four new dispatch_normal entries ($, G, b, w) with ASSERT re-stitching; Dependencies block updated.
- `src/vibe.asm` — UNCHANGED (motions.asm already in AR25 chain since Story 2.5).

**Files created (tests):** 16 new `test/cases/motions_*.asm` (Task 8 Sub 8.1-8.18).

**Files modified (tests):**
- `test/cases/parser_motion-prefix-gg.asm` — Task 7: subtest 2 expectations updated for the stub→motion_gg swap.

**Files modified (planning artifacts — Task 1 NFR9 amend):**
- `_bmad-output/planning-artifacts/prd.md` — NFR9 ceiling raised 3072 → 5120 B per AC14 Option A.
- `_bmad-output/implementation-artifacts/deferred-work.md` — NFR9 amend entry marked RESOLVED; new Story-2.6 dev triage section appended if non-trivial follow-ups surface.
- `_bmad-output/planning-artifacts/architecture.md` — optional AR carve-out doc update per AC15 (recommended bundle).

**Files modified (sprint artifacts):**
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `2-6-word-line-buffer-motions-w-b-0-gg-g` flipped `ready-for-dev` → `in-progress` → `review` across the dev pass.
- `_bmad-output/implementation-artifacts/2-6-word-line-buffer-motions-w-b-0-gg-g.md` — Status `ready-for-dev` → `review`; Tasks/Subtasks checkboxes marked `[x]` (less Task 11's hardware UAT, left `[ ]` for user); Dev Agent Record / File List / Change Log populated.

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md] lines 1098-1147
- Previous story (Story 2.5 basic motions — motions.asm module shape, motion_byte_at_logical, motion_find_line_start / _end, parser_clear tail-JP convention, AC13 hygiene, CR-filter in render): [Source: _bmad-output/implementation-artifacts/2-5-basic-motions-h-j-k-l.md]
- Earlier story (Story 1.10 — parser_handle_digit leading-zero arm, parser_handle_motion_prefix asymmetry, parser_motion_zero_stub + parser_gg_motion_stub placeholders to retire): [Source: _bmad-output/implementation-artifacts/1-10-command-parser-count-pending-operator-motion-prefix.md]
- Earlier story (Story 1.11 — render pipeline; iterative scroll-advance is exercised by motion_G's far-jump): [Source: _bmad-output/implementation-artifacts/1-11-render-pipeline-with-dirty-rows-scroll-ctrl-l.md]
- Earlier story (Story 1.7 — gap buffer; AR14 boundary): [Source: _bmad-output/implementation-artifacts/1-7-gap-buffer-primitives-headless-tests.md]
- FR20 (w/b word motions): [Source: _bmad-output/planning-artifacts/prd.md] lines 728
- FR21 (0/$ line motions): [Source: _bmad-output/planning-artifacts/prd.md] lines 729-730
- FR22 (gg/G buffer motions): [Source: _bmad-output/planning-artifacts/prd.md] lines 731-732
- FR23 (counted motions — Story 2.7 verifies end-to-end; Story 2.6 mechanics already wired via motion_apply_count): [Source: _bmad-output/planning-artifacts/prd.md] lines 733-734
- NFR3 (cursor-motion latency): [Source: _bmad-output/planning-artifacts/prd.md] lines 820-824
- NFR9 (code size budget — AMEND BLOCKING per Task 1): [Source: _bmad-output/planning-artifacts/prd.md] lines 848-851
- NFR14 (sjasmplus 1.23.0): [Source: _bmad-output/planning-artifacts/prd.md] lines 870-871
- NFR18 (reproducible build): [Source: _bmad-output/planning-artifacts/prd.md] lines 886-887
- BH1 (word-boundary classifier — load-bearing for motion_w / motion_b / is_word_char): [Source: _bmad-output/planning-artifacts/architecture.md] lines 668-675
- BH2 (counted-motion bounds — clamp at BOF/EOF for all six motions): [Source: _bmad-output/planning-artifacts/architecture.md] lines 677-680
- SR1 (cursor as 16-bit absolute buffer offset): [Source: _bmad-output/planning-artifacts/architecture.md] lines 426-431
- SR2 (gap-buffer two-halves invariant): [Source: _bmad-output/planning-artifacts/architecture.md] lines 433-439
- SR3 (cursor-to-buffer mapping — motion_byte_at_logical from Story 2.5): [Source: _bmad-output/planning-artifacts/architecture.md] lines 441-445
- SR7 (no line-position cache in MVP — motion_G's full-buffer walk stresses this): [Source: _bmad-output/planning-artifacts/architecture.md] lines 463-468
- MC3 (sparse-sorted dispatch tables; binary-search): [Source: _bmad-output/planning-artifacts/architecture.md] lines 485-527
- MC4 (handler signature — A=key on entry; state from fixed addresses): [Source: _bmad-output/planning-artifacts/architecture.md] lines 529-533
- AR13 / AR14 / AR15 (architectural boundary rules motions.asm respects with zero carve-outs): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1434-1448
- AR22 (naming): [Source: _bmad-output/planning-artifacts/architecture.md] lines 788-850
- AR23 (file structure and routine contracts): [Source: _bmad-output/planning-artifacts/architecture.md] lines 852-916
- AR25 (module include order — motions.asm slot unchanged): [Source: _bmad-output/planning-artifacts/architecture.md] lines 918-956
- V3 (gg as doubled motion — validation issue resolved at state.inc; pending_motion_prefix is the mechanism Story 2.6 finalises): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1664-1670
- Deferred-work entry for parser-state hygiene on mode change (resolved by Story 2.5; Story 2.6 doesn't revisit): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 87-90
- Deferred-work entry for parser_clear-before-state-consumption (RESOLVED for gg arm by Story 2.6 motion_gg per Task 10 Sub 10.1; doubled-op arm remains pending for Story 2.10): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 93-94
- Deferred-work entry for NFR9 amend (BLOCKING for Story 2.6 — must be resolved per Task 1): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 122-130
- Deferred-work entry for architecture.md AR carve-out doc pressure (fourth deferral candidate; bundle with Task 1 NFR9 amend recommended): [Source: _bmad-output/implementation-artifacts/deferred-work.md] lines 139, 143-144
- Deferred-work entry for far-jump scroll-advance O(N × 1840) (load-bearing for motion_G's far-jump; revisit if UAT shows stutter): [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 83
- Deferred-work entry for sticky-column across counted j/k (not Story 2.6 scope; motion_G / motion_gg don't preserve column anyway — they go to line-start): [Source: _bmad-output/implementation-artifacts/deferred-work.md]
- Deferred-work entry for motion_byte_at_logical perf POP/PUSH (still pending; motion_G's full-buffer walk could nudge this if stutter surfaces): [Source: _bmad-output/implementation-artifacts/deferred-work.md]
- inc/state.inc (cursor_offset, count_accumulator, pending_operator, pending_motion_prefix, gap_start, gap_end — all already declared, no additions needed): [Source: inc/state.inc]
- inc/equates.inc (GAP_BUFFER_MAX; GAP_BUFFER_BASE in state.inc): [Source: inc/equates.inc]
- src/motions.asm (motion_h / motion_j / motion_k / motion_l + helpers — Story 2.5 substrate): [Source: src/motions.asm]
- src/gapbuf.asm (SR2 owner; AR14 boundary; motions read gap_start / gap_end only): [Source: src/gapbuf.asm]
- src/parser.asm (parser_handle_digit + parser_handle_motion_prefix arms; parser_motion_zero_stub + parser_gg_motion_stub to retire; parser_doubled_operator_stub UNCHANGED): [Source: src/parser.asm]
- src/dispatch.asm (dispatch_normal table extension; ASSERT re-stitching): [Source: src/dispatch.asm]
- src/render.asm (RI4 cursor-emit; render_scroll_adjust's iterative advance for motion_G): [Source: src/render.asm]
- test/cases/parser_motion-prefix-gg.asm (subtest 2 expectations updated for stub→motion_gg swap): [Source: test/cases/parser_motion-prefix-gg.asm]
- Story 2.5 motion test patterns (INCLUDE chain, sentinel codes 0x80..0x86): [Source: test/cases/motions_j-same-column.asm]

## Dev Agent Record

### Agent Model Used

Claude Opus 4.7 (1M context)

### Debug Log References

- **NFR9 amend landed first** (Task 1). PRD line 848 raised 3072 B → 5120 B with monitored-cadence text. architecture.md updated in four places (§ Resource Consumption, § 5 KB code budget context, § listing/symbol audit caption, § MC3 reclamation envelope) and § Boundary properties gained explicit AR carve-out callouts for fileio.asm (1 AR14 + 3 AR15) and motions.asm's "clean module" archetype status (resolves Story 2.5's AC15 deferral).
- **DE-trash bug surfaced mid-dev.** First-pass `motion_dollar` saved cursor in DE via `LD D,H ; LD E,L` then called motion_find_line_end — but the helper trashes DE per its AR23 contract (transitively via motion_byte_at_logical). Same bug in first-pass motion_find_line_n's count tracking. Both fixed by `PUSH HL ; ... ; POP DE` around the calls. Bug caught via headless test failure (FAIL 80 00 for motions_dollar-no-trailing-lf — cursor=0 instead of expected 4); root-caused with a probe binary inlining the body. Logged in deferred-work.md as a forward-note for Story 3.1's search dev.
- **Two existing parser tests needed updating beyond the spec's Task 7** — Story 2.6's stub retirement also broke `parser_leading-zero-is-motion.asm` and `parser_motion-prefix-cleared-on-other-key.asm` (both asserted `status_dirty != 0` to confirm "the stub fired"). Updated both to assert `cursor_offset == 0` instead, with gap pre-seeding so motion_0 has a non-zero cursor to move from.
- **Build:** `make clean && make` succeeds twice consecutively. Byte-identical SHA `3e0ab8643e50aa2e662aed1d2c1b35749b70f03c05ea47dec115cd8fd68a0f70` (NFR18). Size 4376 B / ~85% of new 5120 B ceiling / 744 B headroom. Spec projected 4232-4282 B; actual +94..+144 B over the high end (DE-trash fixes ~9 B + is_word_char's defensive `OR 1` ~1 B + per-handler accounting drift).
- **Headless tests:** 81 pass / 1 deliberate fail (was 63/1 post-Story-2.5; +18 new motions tests + 3 existing parser tests updated).
- **AR enforcement sweeps:** all clean.
  - `grep -nE 'BIOS_CONOUT' src/motions.asm`: only doc references.
  - `grep -nE 'gapbuf_(insert|delete|move_gap)' src/motions.asm`: only doc references.
  - `grep -nE 'LD[[:space:]]+\(gap_start\)|LD[[:space:]]+\(gap_end\)' src/motions.asm`: zero matches.
  - `grep -nE 'CALL[[:space:]]+0x0005|CALL[[:space:]]+BDOS_ENTRY|BDOS_CALL' src/motions.asm`: only doc references.
  - `grep -cnE 'JP[[:space:]]+parser_clear' src/motions.asm`: 10 sites (h, j, k, l, w, b, 0, dollar, G, gg).
  - `grep -n 'parser_motion_zero_stub\|parser_gg_motion_stub' src/parser.asm`: zero matches (symbols + doc references both retired).
  - `grep -n 'parser_doubled_operator_stub' src/parser.asm`: matches preserved (Story 2.10 scope).
  - `grep -cnE 'LD[[:space:]]+\(cursor_offset\)' src/motions.asm`: 10 sites.
- **Hardware UAT (AC13)** deferred to user execution per Stories 1.11 / 1.12 / 2.1-2.5 pattern.

### Completion Notes List

- Six new public entries in `src/motions.asm`: motion_w, motion_b, motion_0, motion_dollar, motion_G, motion_gg. One new module-private classifier (is_word_char) + one new private "walk to line N" helper (motion_find_line_n) shared between motion_G's and motion_gg's with-count arms.
- Parser stubs `parser_motion_zero_stub` and `parser_gg_motion_stub` retired from `src/parser.asm`. Two JPs retargeted (`parser_handle_digit`'s leading-zero arm now JP motion_0; `parser_handle_motion_prefix`'s doubled-g arm now JP motion_gg). All doc references to the retired symbols cleaned out so the AC14 grep sweep is zero-match.
- Four new dispatch_normal entries in `src/dispatch.asm`: `$` (0x24), `G` (0x47), `b` (0x62), `w` (0x77). Adjacent-pair ASSERT chain re-stitched at each insertion site. `DISPATCH_NORMAL_COUNT` auto-resizes from 28 to 32 entries; binary-search worst case unchanged at 5 iterations.
- AC15 architecture.md AR carve-out doc bundled with Task 1's NFR9 amend (recommended landing path per spec). Story-2.5's third deferral closed.
- 18 new headless tests under `test/cases/motions_*.asm` (sentinel range 0x80..0x82). 3 existing parser tests updated for the stub→handler swap.
- All BH2 clamp semantics honored. motion_w/b clamp at EOF/BOF silently. motion_0 is a no-op on already-at-line-start. motion_dollar clamps on empty-line. motion_G/gg with count > line count clamps at last-line-start. motion_G with no count honors the Story-2.5 P5 trailing-LF lesson via motion_find_line_n's internal trailing-LF guard.
- Each new motion handler tail-JPs `parser_clear` per AC11. motion_gg reads count_accumulator BEFORE the tail-JP (resolves deferred-work line 94's heads-up for the gg arm; doubled-op arm remains pending for Story 2.10).
- Two Story-2.5 deferred-work entries resolved: NFR9 amend; AC15 architecture.md AR doc. One mid-dev bug surfaced and resolved (motion_find_line_end's DE-trash contract); forward-noted for Story 3.1.

### File List

**Modified (production):**
- `src/motions.asm` — module header `Public:` block extended; new public entries motion_w / motion_b / motion_0 / motion_dollar / motion_G / motion_gg; new private helpers is_word_char + motion_find_line_n.
- `src/parser.asm` — parser_motion_zero_stub + parser_gg_motion_stub bodies retired; module header `Public:` shrunk; Dependencies block grew (src/motions.asm); parser_handle_digit's leading-zero arm and parser_handle_motion_prefix's doubled-g arm retargeted to JP motion_0 / motion_gg.
- `src/dispatch.asm` — four new dispatch_normal entries ($, G, b, w) with ASSERT re-stitching; Dependencies block updated for Story 2.6 forward references.

**Modified (planning artifacts):**
- `_bmad-output/planning-artifacts/prd.md` — NFR9 ceiling amended 3072 B → 5120 B (Task 1 Sub 1.1).
- `_bmad-output/planning-artifacts/architecture.md` — NFR9 ceiling references updated in four places; § Boundary properties gained explicit AR14 / AR15 carve-out callouts (Task 1 Sub 1.3, Sub 1.4).
- `_bmad-output/implementation-artifacts/deferred-work.md` — NFR9 amend entry marked RESOLVED; AC15 architecture.md doc entry marked RESOLVED; parser-stub state-read entry marked RESOLVED for gg arm; new "Deferred from: dev of story-2-6-..." section appended with 8 new entries.

**Modified (tests):**
- `test/cases/parser_motion-prefix-gg.asm` — Subtest 2 expectation changed from `status_dirty != 0` to `cursor_offset == 0`; gap pre-seeded.
- `test/cases/parser_leading-zero-is-motion.asm` — both subtests' `status_dirty != 0` assertion replaced with `cursor_offset == 0`; gap pre-seeded.
- `test/cases/parser_motion-prefix-cleared-on-other-key.asm` — Subtest 4's E8 sentinel re-purposed from "stub fired (status_dirty)" to "motion_0 fired (cursor_offset == 0)"; gap pre-seeded.

**Created (tests — 18 new):**
- `test/cases/motions_w-skips-whitespace.asm`
- `test/cases/motions_w-non-alnum-class.asm`
- `test/cases/motions_w-cross-line.asm`
- `test/cases/motions_w-clamps-at-eof.asm`
- `test/cases/motions_b-from-mid-word.asm`
- `test/cases/motions_b-from-word-start.asm`
- `test/cases/motions_b-clamps-at-bof.asm`
- `test/cases/motions_0-on-blank-line.asm`
- `test/cases/motions_0-mid-line.asm` (via parser leading-zero arm)
- `test/cases/motions_dollar-on-empty-line.asm`
- `test/cases/motions_dollar-mid-line.asm`
- `test/cases/motions_dollar-no-trailing-lf.asm`
- `test/cases/motions_G-no-count.asm`
- `test/cases/motions_G-no-count-trailing-lf.asm` (pins the P5 lesson)
- `test/cases/motions_G-with-count.asm`
- `test/cases/motions_G-with-count-clamps.asm`
- `test/cases/motions_gg-via-prefix.asm` (via parser doubled-g arm)
- `test/cases/motions_gg-with-count.asm`

**Modified (sprint artifacts):**
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — `2-6-word-line-buffer-motions-w-b-0-gg-g` flipped `ready-for-dev` → `review`; last_updated appended.
- `_bmad-output/implementation-artifacts/2-6-word-line-buffer-motions-w-b-0-gg-g.md` — Status `ready-for-dev` → `review`; Tasks/Subtasks 1-10 checked; Task 11 (hardware UAT) left unchecked for user; Dev Agent Record / File List / Change Log populated.

### Change Log

| Date       | Change |
|------------|--------|
| 2026-05-15 | Story created (ready-for-dev). Comprehensive context engine pass: AC1-AC16, ~16 new headless tests + 1 updated parser test, full Dev Notes block. AC14 NFR9 amend BLOCKING — Task 1 lands the prd.md ceiling raise from 3072 → 5120 B as the FIRST commit on the branch (separate from motions code per the established planning-vs-code commit pattern). AC9 retires parser_motion_zero_stub + parser_gg_motion_stub (parser_doubled_operator_stub stays — Story 2.10 scope). AC2-AC7 spell out the six new motion algorithms; motion_G includes the Story-2.5 P5 trailing-LF clamp lesson. AC15 architecture.md AR doc update is FOURTH deferral candidate but RECOMMENDED to bundle with Task 1's NFR9 commit. Expected NFR9 footprint delta +150-200 B; post-2.6 size 4232-4282 B / well under amended 5120 B ceiling. |
| 2026-05-15 | Story 2.6 dev pass complete (→ review). Six new public motions in src/motions.asm (w, b, 0, $, G, gg) + is_word_char classifier + motion_find_line_n shared helper. Parser stubs parser_motion_zero_stub + parser_gg_motion_stub retired; parser arms retargeted to motion_0 / motion_gg. Four new dispatch_normal entries ($, G, b, w) with ASSERT re-stitching. NFR9 amend landed (3072 B → 5120 B) bundled with architecture.md AR carve-out doc update (resolves two Story-2.5 deferrals). 18 new headless tests + 3 existing parser tests updated for the stub→handler swap. Build SHA `3e0ab8643e50aa2e662aed1d2c1b35749b70f03c05ea47dec115cd8fd68a0f70`, byte-identical second build (NFR18). Size 4376 B / ~85% of new ceiling / 744 B headroom (above spec's 4232-4282 B projection — DE-trash fix ~9 B + is_word_char defensive ~1 B + accounting drift). 81 pass / 1 deliberate fail. Hardware UAT (AC13) deferred to user. |
| 2026-05-15 | **Hardware UAT (AC13) CONFIRMED by Ant on real MicroBeast — all 17 steps pass first iteration.** No regressions surfaced: w / b / 0 / $ / G / gg all behave as specified; BH1 word-class transitions correct on real comment/punctuation content; cross-line word advance works; counted motions (3w / 5b / 5G / 100G) clamp silently per BH2; trailing-LF clamp on G correct; operator-stranded smoke (dw / d0 / dgg) leaves editor in clean NORMAL state with parser cleared; mode-transition `5 : Esc w` regression-net (Story-2.5 AC13 patch on exline_cancel_core) holds; sustained-typing across w/b/0/$/G/gg shows no dropped keystrokes, no terminal corruption, no parser-state staleness. Story 2.6 dev pass complete inclusive of hardware UAT; ready for code review pass. |
