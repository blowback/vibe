# Story 1.10: Command parser (count + pending operator + motion-prefix)

Status: done

<!-- Note: Validation is optional. Run validate-create-story for quality check before dev-story. -->

## Story

As the VIBE author,
I want `src/parser.asm` implementing the count accumulator, pending-operator byte, and motion-prefix byte state machines, with headless tests against stub motion handlers,
so that MC4's classic vi two-stage operator/motion structure is in place before any real motion or edit handler lands in Epic 2, and FR23 / FR39 / FR40 / NFR17 are realized at the substrate level.

## Acceptance Criteria

1. **Module header.**
   **Given** `src/parser.asm` module header
   **When** I inspect it
   **Then** it documents `Public: parser_handle_digit, parser_handle_operator, parser_handle_motion_prefix, parser_dispatch, parser_clear` plus the three Epic-1 stub handlers `parser_motion_zero_stub`, `parser_doubled_operator_stub`, `parser_gg_motion_stub`
   **And** `State owned (read/write): count_accumulator, pending_operator, pending_motion_prefix` (all declared in `inc/state.inc` since Story 1.3 — no new state.inc fields in this story)
   **And** register conventions across public entry points
   **And** dependencies on `inc/equates.inc`, `inc/state.inc`, `inc/modes.inc`, `src/statusln.asm` (for the stubs that surface `msg_not_implemented`).

2. **`parser_handle_digit` — non-zero digit accumulation.**
   **Given** `parser_handle_digit` (`In: A = '0'..'9' (0x30..0x39)`)
   **When** invoked with a non-zero digit (e.g. '5')
   **Then** `count_accumulator = count_accumulator * 10 + (A - '0')` (16-bit math; both bytes of `count_accumulator` written)
   **And** subsequent calls accumulate further digits (e.g. parser_handle_digit('1') then parser_handle_digit('2') yields count_accumulator = 12)
   **And** the handler is `RET`-terminating (MC4) and operates on the global `count_accumulator` (no register-passed parameters apart from the MC4 `A = key just consumed`).

3. **`parser_handle_digit` — leading '0' is the motion `0` (FR21).**
   **Given** `parser_handle_digit` called with A = '0' AND count_accumulator == 0 (no count yet)
   **When** invoked
   **Then** the parser does NOT accumulate
   **And** control transfers to `parser_motion_zero_stub` (Epic 1 placeholder for the line-start motion; Story 2.6 lands the real motion)
   **And** count_accumulator remains 0 (the stub does not modify count)
   **And** the stub's only observable side effect is a status_set_message msg_not_implemented call (sets status_dirty).

4. **`parser_handle_digit` — '0' after digit accumulates as count*10.**
   **Given** `parser_handle_digit` called with A = '0' AND count_accumulator > 0 (count already started)
   **When** invoked
   **Then** count_accumulator becomes count_accumulator * 10 (e.g., parser_handle_digit('1') then parser_handle_digit('0') yields count_accumulator = 10)
   **And** the leading-zero-is-motion branch (AC3) is NOT taken — the '0' is consumed as a digit because count is already non-zero.

5. **`parser_handle_operator` — first operator sets pending_operator.**
   **Given** `parser_handle_operator` (`In: A = operator byte 'd'/'y'/'c'/'>'/'<'`)
   **When** invoked with pending_operator == 0 (no pending operator)
   **Then** `pending_operator = A`
   **And** count_accumulator is unchanged (the count survives across the operator press, so '5d' followed by a motion fires the motion 5 times).

6. **`parser_handle_operator` — doubled-operator detection (FR40).**
   **Given** `parser_handle_operator` called with A == pending_operator (e.g. 'd' arrives while pending_operator == 'd')
   **When** invoked
   **Then** the parser dispatches the doubled-operator command via `parser_doubled_operator_stub` (Epic 1 placeholder for the doubled-operator handler — Story 2.10 lands `dd`/`yy`)
   **And** post-dispatch, `parser_clear` runs: count_accumulator, pending_operator, pending_motion_prefix all == 0
   **And** the stub's only observable side effect is a status_set_message msg_not_implemented call (sets status_dirty) — distinguishable from "no dispatch happened" by a status_dirty check in tests.

7. **`parser_handle_motion_prefix` — first prefix sets pending_motion_prefix.**
   **Given** `parser_handle_motion_prefix` (`In: A = prefix byte, currently 'g' (0x67) for Epic 1 / Epic 2`)
   **When** invoked with pending_motion_prefix != A
   **Then** `pending_motion_prefix = A`
   **And** count_accumulator and pending_operator are unchanged (the prefix can carry across counts and operators — `5gg` and `dgg` are valid composes the parser must not mangle).

8. **`parser_handle_motion_prefix` — doubled-prefix dispatches gg motion (V3 / FR22).**
   **Given** `parser_handle_motion_prefix` called with A == pending_motion_prefix (e.g. 'g' arrives while pending_motion_prefix == 'g')
   **When** invoked
   **Then** the parser dispatches the gg motion via `parser_gg_motion_stub` (Epic 1 placeholder for the buffer-start motion — Story 2.6 lands the real `gg`)
   **And** post-dispatch, `parser_clear` runs: count_accumulator, pending_operator, pending_motion_prefix all == 0
   **And** the stub's only observable side effect is a status_set_message msg_not_implemented call (sets status_dirty).

9. **`parser_dispatch` — invokes motion handler with parser state available, then clears.**
   **Given** `parser_dispatch` (`In: HL = motion handler address`)
   **When** invoked
   **Then** the motion handler is CALLed (control returns to parser_dispatch via the handler's `RET`)
   **And** count_accumulator / pending_operator / pending_motion_prefix remain readable by the handler during its execution (the motion handler reads count via `LD HL, (count_accumulator)` etc.)
   **And** after the handler returns, `parser_clear` is invoked (tail-call permissible) so count_accumulator, pending_operator, pending_motion_prefix all == 0
   **And** parser_dispatch is `RET`-terminating from the caller's perspective (post parser_clear).

10. **`parser_clear` — zeros all three accumulator bytes.**
    **Given** `parser_clear`
    **When** invoked (e.g. from an Esc handler in the future, or after a doubled-operator / gg dispatch, or post parser_dispatch)
    **Then** count_accumulator (2 bytes) = 0, pending_operator (1 byte) = 0, pending_motion_prefix (1 byte) = 0
    **And** no other state is touched (mode_byte, visual_submode, cursor_offset, gap pointers, status_dirty all unchanged).

11. **Pending-motion-prefix is cleared on any non-prefix-aware key.**
    **Given** pending_motion_prefix == 'g' (the user typed 'g' as a prefix)
    **When** the user types a non-'g' key that routes to `parser_handle_digit` or `parser_handle_operator` (i.e., '5' or 'd')
    **Then** pending_motion_prefix is cleared to 0 on entry to the parser handler
    **And** the new key is processed normally (digit accumulates, operator sets pending_operator)
    **And** the prior 'g' is discarded — it does NOT compose with the new key (vi behaviour: stale prefix on operator/count input clears).

12. **Headless tests pass.**
    **Given** seven headless tests under `test/cases/parser_*.asm` exercising the parser against stub motion handlers
    **When** I run `make test` from project root
    **Then** the following seven new tests pass:
    - `parser_count-accumulator.asm`
    - `parser_leading-zero-is-motion.asm`
    - `parser_zero-after-digit.asm`
    - `parser_doubled-operator-dd.asm`
    - `parser_compose-count-op-motion.asm`
    - `parser_motion-prefix-gg.asm`
    - `parser_motion-prefix-cleared-on-other-key.asm`
    **And** the live baseline becomes 17 pass / 1 fail (10 pre-1.10 passes from Story 1.9 + 7 new `parser_*` cases; the only `fail` remains the deliberate `harness_fail` from Story 1.6).

13. **`dispatch_normal` routes digits, operators, and the motion prefix to parser entries (NFR17).**
    **Given** the parser is stateless w.r.t. modes (it operates only when invoked from normal-mode dispatch)
    **When** I inspect `src/dispatch.asm`'s `dispatch_normal` table
    **Then** the table contains 16 new entries — '0'..'9' (0x30..0x39) → `parser_handle_digit`, '<' / '>' / 'c' / 'd' / 'y' → `parser_handle_operator`, 'g' → `parser_handle_motion_prefix` — sorted ascending by ASCII byte alongside the 9 entries from Story 1.9
    **And** `DISPATCH_NORMAL_COUNT` recomputes via the existing `EQU ($ - .entries) / 3` form (no manual count edit needed — the equate is positional)
    **And** the per-entry `ASSERT key_n > key_n_minus_1` lines are extended to cover every consecutive pair across the 25-entry table (24 ASSERTs after Story 1.10, vs 8 after Story 1.9)
    **And** the total dispatch-table footprint across all four mode tables remains under 256 bytes (dispatch_normal grows from 29 → 77 bytes; dispatch_insert/command/visual unchanged at 5 bytes each → total 92 bytes, well under 256).

14. **Calling convention (MC1, MC4).**
    **Given** the calling convention (MC1, MC4)
    **When** I inspect public parser entries (parser_handle_digit, parser_handle_operator, parser_handle_motion_prefix, parser_dispatch, parser_clear)
    **Then** each is a `RET`-terminating routine that operates on global state (no register-passed parameters apart from the documented per-entry contract: `A = key` for the *_handle_* entries, `HL = motion addr` for parser_dispatch, none for parser_clear)
    **And** caller-saved per MC1 (each entry's `Trashes:` line documents A/BC/DE/HL/F as appropriate; the stub handlers transitively trash via status_set_message).

15. **Build-time invariants and AR/NFR enforcement.**
    **Given** the project build invariants
    **When** I run `make` from project root
    **Then** `vibe.com` builds cleanly under sjasmplus 1.23.0 (NFR14)
    **And** two consecutive `make clean && make` runs produce byte-identical `vibe.com` (NFR18)
    **And** `grep -nE 'BIOS_CONOUT' src/parser.asm` returns zero matches (AR13 — parser never emits screen bytes; the stubs go through `status_set_message`, not direct `BIOS_CONOUT`)
    **And** `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/parser.asm` returns zero matches (AR15 — parser never invokes BDOS directly; `BDOS_CALL BDOS_EXIT` is also absent — parser does not exit the editor)
    **And** `grep -nE 'gapbuf_(insert|delete|move_gap|load|init)' src/parser.asm` returns zero matches (AR14 — parser does not mutate the gap buffer; the parser is metadata-only state).

16. **`vibe.asm` integration.**
    **Given** AR25's INCLUDE order (`init → input → statusln → gapbuf → render → dispatch → parser → motions → ...`)
    **When** I inspect `src/vibe.asm` after Story 1.10
    **Then** `INCLUDE "parser.asm"` lands AFTER `INCLUDE "dispatch.asm"` and BEFORE the `;; --- Input-loop abort target ---` comment block (since `motions.asm` does not yet exist — it slots in BEFORE no, AFTER `parser.asm` when Story 2.5 lands)
    **And** the `vibe.asm` header `Dependencies:` line adds `src/parser.asm (Story 1.10)`
    **And** the `;; --- Input-loop abort target ---` comment block in `vibe.asm` is NOT touched by this story (it already correctly points to Story 1.12 as the loop-body owner per Story 1.8's edit; Story 1.9's INCLUDE of dispatch.asm sits between gapbuf and parser, undisturbed).

## Tasks / Subtasks

- [x] Task 1 — Read foundational artifacts and previous-story dev-notes (no code change). (AC reference: all)
  - [x] Read `_bmad-output/planning-artifacts/architecture.md` § Module Calling Conventions (MC1, MC3, MC4) and § Project Structure & Boundaries (especially AR25 INCLUDE order and the parser/motion role split at architecture lines 1521-1524).
  - [x] Read `_bmad-output/implementation-artifacts/1-9-mode-dispatch-with-sparse-table-binary-search.md` § Dev Notes — the prior story's house style is the template for this one. Specific traps that recur for Story 1.10: (a) ASCII-byte sort order of new dispatch_normal entries, (b) `BDOS_CALL` macro arg-textual-substitution caveat (parser doesn't use BDOS but inherits the discipline via the status_set_message → status_dirty path), (c) every `RET` documented in the trashes line, (d) test-case scaffold INCLUDE order: prologue → body → epilogue → production INCLUDEs in AR25 order → input_loop_stub → state.inc LAST.
  - [x] Confirm `count_accumulator` (16-bit, line 73-74), `pending_operator` (1-byte, line 51-52), `pending_motion_prefix` (1-byte, line 57-58) already exist in `inc/state.inc` per the Story 1.3 layout. Story 1.10 adds NO new state.inc fields.

- [x] Task 2 — Create `src/parser.asm` with the standard module-header block per AR23. (AC: 1)
  - [x] Header block: Module / Purpose / Public / State owned / Register conventions / Dependencies. Mirror `src/dispatch.asm` lines 1-87 for shape — both modules are stateless w.r.t. their own routine state and own a small set of writes to fixed state.inc fields.
  - [x] Public block enumerates: `parser_handle_digit`, `parser_handle_operator`, `parser_handle_motion_prefix`, `parser_dispatch`, `parser_clear`, plus the three Epic-1 stubs `parser_motion_zero_stub`, `parser_doubled_operator_stub`, `parser_gg_motion_stub`.
  - [x] State owned: `count_accumulator` (writer = parser_handle_digit, parser_clear), `pending_operator` (writer = parser_handle_operator, parser_clear), `pending_motion_prefix` (writer = parser_handle_motion_prefix, parser_clear, plus the cleared-on-non-g-key path inside parser_handle_digit / parser_handle_operator).
  - [x] Dependencies line lists `inc/state.inc` (count_accumulator, pending_operator, pending_motion_prefix), `src/statusln.asm` (status_set_message + msg_not_implemented for the three stubs), `inc/modes.inc` is NOT a direct dependency (parser doesn't read MODE_*), `inc/bdos.inc` is NOT a dependency (parser doesn't BDOS), `inc/bios.inc` is NOT a dependency (parser doesn't BIOS).
  - [x] Document the AC11 invariant in the header: "On entry, `parser_handle_digit` and `parser_handle_operator` clear `pending_motion_prefix` to 0 (a non-prefix-aware key arriving discards a stale 'g'). `parser_handle_motion_prefix` does NOT clear it (so the doubled-prefix branch can fire)."

- [x] Task 3 — Implement `parser_clear`. (AC: 10, 14)
  - [x] Public entry. `In: (none). Out: count_accumulator (2 bytes) = 0, pending_operator = 0, pending_motion_prefix = 0. Trashes: A, HL, F. Calls: (none).`
  - [x] Implementation pattern (recommended):
    ```
    parser_clear:
        XOR     A
        LD      (pending_operator), A
        LD      (pending_motion_prefix), A
        LD      HL, 0
        LD      (count_accumulator), HL
        RET
    ```
    `LD HL, 0` then `LD (count_accumulator), HL` is the canonical 2-byte zero — emits 6 bytes of code vs 8 for two `LD (addr), A` pairs.
  - [x] No status-line side effect — parser_clear is the silent reset path. Not a status-emitting routine.

- [x] Task 4 — Implement `parser_handle_digit` per MC4. (AC: 2, 3, 4, 11, 14)
  - [x] Public entry. `In: A = digit char ('0'..'9' = 0x30..0x39). Out: side effects on count_accumulator and pending_motion_prefix (cleared on entry per AC11); on leading-zero-is-motion path, transfers control through parser_motion_zero_stub. Trashes: A, BC, DE, HL, F (the AC4 multiply path uses HL+DE; the stub call inherits status_set_message's clobber). Calls: parser_motion_zero_stub (only on the leading-zero path).`
  - [x] **Leading-zero-is-motion handling (AC3):** test if A == '0' AND count_accumulator == 0 (BOTH bytes zero). On true, `JP parser_motion_zero_stub` (tail-call — the stub's RET returns to parser_handle_digit's caller). On false, fall through to the accumulate path. Recommended sequence:
    ```
    parser_handle_digit:
        ;; AC11: clear pending_motion_prefix on entry — a digit
        ;; arriving discards any stale 'g' (5gg etc. is not a vi compose).
        XOR     C
        LD      C, A                  ; C = digit char (saved across status / motion calls)
        XOR     A
        LD      (pending_motion_prefix), A
        ;; Leading-zero-is-motion test (AC3)
        LD      A, C
        CP      '0'
        JR      NZ, .accumulate       ; non-zero digit → accumulate
        LD      HL, (count_accumulator)
        LD      A, H
        OR      L
        JR      NZ, .accumulate       ; '0' but count > 0 → accumulate (AC4)
        ;; Leading '0' with no count → motion-zero stub.
        ;; A still equals 0 here; that's fine — the stub only needs
        ;; HL = msg_not_implemented (which it loads itself).
        JP      parser_motion_zero_stub
    .accumulate:
        ;; HL holds count (loaded above on the leading-zero arm; reload
        ;; here for the non-zero-digit arm).
        LD      HL, (count_accumulator)
        ;; HL = HL * 10. Z80 idiom: count*10 = (count*4 + count) * 2.
        ;;   ADD HL, HL          ; *2
        ;;   ADD HL, HL          ; *4
        ;;   LD D, H : LD E, L   ; DE = count*4
        ;;   ADD HL, HL          ; *8
        ;;   ADD HL, DE          ; *10  ... actually *4+*8=*12, wrong.
        ;; Correct: count*10 = count*8 + count*2.
        ;;   LD D, H : LD E, L   ; DE = count
        ;;   ADD HL, HL          ; HL = count*2
        ;;   LD B, H : LD C, L   ; BC = count*2 (saved)
        ;;   ADD HL, HL          ; HL = count*4
        ;;   ADD HL, HL          ; HL = count*8
        ;;   ADD HL, BC          ; HL = count*8 + count*2 = count*10
        ;; (Or compute as ((count*4)+count)*2 = count*10:
        ;;   ADD HL, HL          ; *2
        ;;   ADD HL, HL          ; *4
        ;;   ADD HL, DE          ; *5
        ;;   ADD HL, HL          ; *10
        ;;  — simpler, fewer regs.)
        LD      D, H
        LD      E, L                  ; DE = count (original)
        ADD     HL, HL                ; HL = count*2
        ADD     HL, HL                ; HL = count*4
        ADD     HL, DE                ; HL = count*5
        ADD     HL, HL                ; HL = count*10
        ;; Add (digit - '0') as 8-bit zero-extended.
        LD      A, C                  ; A = digit char
        SUB     '0'                   ; A = digit value 0..9
        LD      E, A                  ; DE = digit (zero-extend)
        LD      D, 0
        ADD     HL, DE                ; HL = count*10 + digit
        LD      (count_accumulator), HL
        RET
    ```
    Document the multiply choice in a comment. The `(count*4 + count) * 2` shape uses 4 ADD HLs + 1 LD DE pair = ~50 T-states for the multiply.
  - [x] **No overflow protection.** count > 6553 followed by another digit overflows (HL wraps modulo 65536). Vi tradition: ignore — no real-world count is that big, and the wrap is harmless (the user gets a different count than they typed but no crash). Document as a known sharp edge, not a bug.
  - [x] **Sentinel preservation across multiply.** The multiply path uses HL/DE. C holds the digit char across the whole routine — it's where we stashed A on entry. After the multiply, `LD A, C` reloads the digit for the SUB '0' step. Don't trash C inside `.accumulate`.

- [x] Task 5 — Implement `parser_handle_operator` per MC4. (AC: 5, 6, 11, 14)
  - [x] Public entry. `In: A = operator byte ('d'/'y'/'c'/'>'/'<'). Out: side effects on pending_operator and pending_motion_prefix (cleared on entry per AC11); on doubled-operator path, dispatches via parser_doubled_operator_stub then parser_clear. Trashes: A, BC, DE, HL, F. Calls: parser_doubled_operator_stub (and transitively parser_clear and status_set_message) on the doubled-operator branch.`
  - [x] Implementation:
    ```
    parser_handle_operator:
        ;; AC11: clear pending_motion_prefix on entry (an operator arriving
        ;; discards any stale 'g' — dgg is not a valid vi compose; the d
        ;; keeps the count, the gg-prefix is dropped).
        LD      C, A                  ; C = operator (saved across compares)
        XOR     A
        LD      (pending_motion_prefix), A
        ;; Doubled-operator detection (AC6): A == pending_operator?
        LD      A, (pending_operator)
        CP      C
        JR      NZ, .first_operator
        ;; Doubled — dispatch via stub. parser_doubled_operator_stub
        ;; itself JPs to parser_clear after the status_set_message
        ;; (so this is a tail call: stub's terminal JP returns to
        ;; parser_handle_operator's caller).
        JP      parser_doubled_operator_stub
    .first_operator:
        ;; Set pending_operator = A (= C). count_accumulator unchanged
        ;; (AC5: the count survives across the operator press).
        LD      A, C
        LD      (pending_operator), A
        RET
    ```
  - [x] **Stale-pending-operator handling.** If pending_operator is set to a different operator (e.g. 'd' pending then 'y' arrives), this implementation REPLACES pending_operator with the new value. AC5/AC6 don't pin this case, so the simplest "last-operator-wins" behaviour is chosen — matches modern vim's tendency to abort the prior operator on operator-conflict. Document in dev-notes.
  - [x] **C is callee-saved across the compare.** A is loaded with pending_operator from memory; CP C compares. On match, dispatch to stub (which does parser_clear and never returns through .first_operator). On mismatch, restore A from C, store. No register-pressure surprises here.

- [x] Task 6 — Implement `parser_handle_motion_prefix` per MC4. (AC: 7, 8, 14)
  - [x] Public entry. `In: A = prefix byte ('g' for Epic 1; future-extensible). Out: side effects on pending_motion_prefix; on doubled-prefix path, dispatches via parser_gg_motion_stub then parser_clear. Trashes: A, BC, F. Calls: parser_gg_motion_stub (transitively parser_clear and status_set_message) on the doubled-prefix branch.`
  - [x] Implementation:
    ```
    parser_handle_motion_prefix:
        LD      C, A                  ; C = prefix char (saved across compare)
        ;; Doubled-prefix detection (AC8): A == pending_motion_prefix?
        LD      A, (pending_motion_prefix)
        CP      C
        JR      NZ, .first_prefix
        ;; Doubled — dispatch via gg stub (tail call to stub → parser_clear).
        JP      parser_gg_motion_stub
    .first_prefix:
        ;; Set pending_motion_prefix = A (= C). count_accumulator and
        ;; pending_operator unchanged (AC7: the prefix can carry across
        ;; counts and operators — '5gg' and 'dgg' are valid composes).
        LD      A, C
        LD      (pending_motion_prefix), A
        RET
    ```
  - [x] **Critical: `parser_handle_motion_prefix` does NOT clear `pending_motion_prefix` on entry** (unlike parser_handle_digit and parser_handle_operator). The whole point of the doubled-prefix branch is to *test* the prior prefix — clearing it on entry would make the gg-detection impossible. Document this asymmetry in the routine's contract comment so the next reader doesn't "fix" the inconsistency.

- [x] Task 7 — Implement `parser_dispatch`. (AC: 9, 14)
  - [x] Public entry. `In: HL = motion handler address. Out: motion handler called once with parser state visible (count_accumulator etc. readable by handler); after handler returns, parser_clear is invoked (count_accumulator / pending_operator / pending_motion_prefix all = 0); RET-terminating from caller's perspective. Trashes: A, BC, DE, HL, F (motion handler may trash more — caller-saved per MC1). Calls: motion handler (via JP (HL)), parser_clear (tail-call after motion returns).`
  - [x] Implementation pattern — the cleanest Z80 form for "call HL then tail-clear" is the inner CALL trick:
    ```
    parser_dispatch:
        ;; In: HL = motion handler address.
        ;; Standard Z80 idiom: CALL .invoke pushes a return into
        ;; parser_dispatch; .invoke does JP (HL) into the motion;
        ;; motion's RET pops back to parser_dispatch right after
        ;; the CALL, where we tail-JP to parser_clear.
        CALL    .invoke
        JP      parser_clear
    .invoke:
        JP      (HL)                  ; transfer to motion handler
    ```
    `JP (HL)` jumps to the address IN HL (not at memory[HL] — see Story 1.9 dev-notes for the classic Z80 footgun). The CALL .invoke pushes a return-here addr; .invoke's JP (HL) transfers to the motion. The motion's RET pops back into parser_dispatch right after the CALL, where the JP parser_clear is the canonical tail-call form.
  - [x] **The motion handler MUST be `RET`-terminating.** parser_dispatch's stack discipline requires exactly one RET from the motion handler — extra RETs unwind into garbage; missing RETs hang. MC1 / MC4 already require RET-termination; this routine merely depends on it.
  - [x] **count_accumulator is *visible* to the motion handler — not passed in a register.** The motion handler reads `LD HL, (count_accumulator)` itself. parser_dispatch does NOT zero count before calling the handler (count is what the handler operates on); parser_clear runs AFTER the handler returns.
  - [x] **No special handling of pending_operator inside parser_dispatch.** The motion handler can read pending_operator and either operate-then-clear (the operator-motion compose path: `dw` deletes a word) or simply move-then-clear (the bare-motion path: plain `w`). parser_clear at the end zeros all three regardless, so the next compose starts fresh.

- [x] Task 8 — Implement the three Epic-1 stub handlers. (AC: 3, 6, 8)
  - [x] **`parser_motion_zero_stub`** (Epic 1 placeholder for motion-0 / line-start; Story 2.6 lands real). Calls status_set_message with msg_not_implemented (sets status_dirty). RET. Recommended:
    ```
    parser_motion_zero_stub:
        LD      HL, msg_not_implemented
        XOR     A
        CALL    status_set_message
        RET
    ```
    No parser_clear call — the leading-zero-is-motion path does NOT have any pending state to clear (count was 0 by precondition; operator may or may not be pending; prefix may or may not be set). Vi behaviour: pressing '0' with operator pending (e.g. 'd0') means "delete to line start" — operator+motion compose. Story 2.6 (real motion-0) and Story 2.11 (compose with operator) will revise this stub. For Epic 1, status_set_message is the only side effect.
  - [x] **`parser_doubled_operator_stub`** (Epic 1 placeholder for doubled operators dd/yy/cc/<<<>>; Story 2.10 lands real). Sets the status surface AND clears parser state. Recommended:
    ```
    parser_doubled_operator_stub:
        LD      HL, msg_not_implemented
        XOR     A
        CALL    status_set_message
        JP      parser_clear          ; tail-call: parser_clear's RET returns to the original caller
    ```
    Tail-JP to parser_clear makes the dispatch atomic from the caller's perspective: doubled-op fires → status feedback → state cleared → control returns.
  - [x] **`parser_gg_motion_stub`** (Epic 1 placeholder for gg / buffer-start motion; Story 2.6 lands real). Same shape as parser_doubled_operator_stub:
    ```
    parser_gg_motion_stub:
        LD      HL, msg_not_implemented
        XOR     A
        CALL    status_set_message
        JP      parser_clear
    ```
    Tail-JP to parser_clear ensures the gg-dispatch leaves no stale pending_motion_prefix.

- [x] Task 9 — Extend `dispatch_normal` in `src/dispatch.asm` with 16 new entries (AC: 13)
  - [x] **Insert 16 new entries into `dispatch_normal` in ASCII-byte ascending order alongside the 9 existing entries.** The merged sorted layout (25 entries total):
    ```
    dispatch_normal:
        DEFW    unbound_normal
    .entries:
        DEFB    0x0C : DEFW mode_full_refresh_stub      ; Ctrl-L (existing — 1.9)
        ASSERT  0x11 > 0x0C
        DEFB    0x11 : DEFW mode_debug_quit             ; Ctrl-Q (existing — 1.9)
        ASSERT  '/' > 0x11
        DEFB    '/'  : DEFW mode_search_prompt_stub     ; / (existing — 1.9)
        ASSERT  '0' > '/'
        DEFB    '0'  : DEFW parser_handle_digit         ; '0' (NEW — 1.10)
        ASSERT  '1' > '0'
        DEFB    '1'  : DEFW parser_handle_digit         ; '1' (NEW — 1.10)
        ASSERT  '2' > '1'
        DEFB    '2'  : DEFW parser_handle_digit
        ASSERT  '3' > '2'
        DEFB    '3'  : DEFW parser_handle_digit
        ASSERT  '4' > '3'
        DEFB    '4'  : DEFW parser_handle_digit
        ASSERT  '5' > '4'
        DEFB    '5'  : DEFW parser_handle_digit
        ASSERT  '6' > '5'
        DEFB    '6'  : DEFW parser_handle_digit
        ASSERT  '7' > '6'
        DEFB    '7'  : DEFW parser_handle_digit
        ASSERT  '8' > '7'
        DEFB    '8'  : DEFW parser_handle_digit
        ASSERT  '9' > '8'
        DEFB    '9'  : DEFW parser_handle_digit         ; '9' (NEW — 1.10)
        ASSERT  ':' > '9'
        DEFB    ':'  : DEFW enter_command_mode          ; (existing — 1.9; was preceded by '/' before)
        ASSERT  '<' > ':'
        DEFB    '<'  : DEFW parser_handle_operator      ; '<' (NEW — 1.10)
        ASSERT  '>' > '<'
        DEFB    '>'  : DEFW parser_handle_operator      ; '>' (NEW — 1.10)
        ASSERT  'O' > '>'
        DEFB    'O'  : DEFW enter_insert_mode           ; (existing — 1.9; was preceded by ':' before)
        ASSERT  'a' > 'O'
        DEFB    'a'  : DEFW enter_insert_mode           ; (existing — 1.9)
        ASSERT  'c' > 'a'
        DEFB    'c'  : DEFW parser_handle_operator      ; 'c' (NEW — 1.10)
        ASSERT  'd' > 'c'
        DEFB    'd'  : DEFW parser_handle_operator      ; 'd' (NEW — 1.10)
        ASSERT  'g' > 'd'
        DEFB    'g'  : DEFW parser_handle_motion_prefix ; 'g' (NEW — 1.10)
        ASSERT  'i' > 'g'
        DEFB    'i'  : DEFW enter_insert_mode           ; (existing — 1.9; was preceded by 'a' before)
        ASSERT  'o' > 'i'
        DEFB    'o'  : DEFW enter_insert_mode           ; (existing — 1.9)
        ASSERT  'v' > 'o'
        DEFB    'v'  : DEFW enter_visual_mode           ; (existing — 1.9)
        ASSERT  'y' > 'v'
        DEFB    'y'  : DEFW parser_handle_operator      ; 'y' (NEW — 1.10)
    DISPATCH_NORMAL_COUNT EQU ($ - .entries) / 3
    ```
    25 entries × 3 + 2-byte unbound prefix = 77 bytes. `DISPATCH_NORMAL_COUNT` recomputes positionally — no manual edit.
  - [x] **Two existing ASSERTs need to be REPLACED** because the new entries break their adjacency: `':' > '/'` is now wrong (with '0'..'9' in between, it's `':' > '9'`); `'O' > ':'` is now wrong (it's `'O' > '>'`); `'a' > 'O'` is unchanged (still adjacent); `'i' > 'a'` is now wrong (it's `'i' > 'g'`). Replace these three; keep `'a' > 'O'` and `'o' > 'i'` and `'v' > 'o'` as-is. The 16 NEW entries each get one new ASSERT line.
  - [x] **Update the `src/dispatch.asm` header `Public:` block** to enumerate the parser entries are external dependencies, NOT public symbols of dispatch.asm — i.e., dispatch.asm's `Public:` block does NOT need to list parser_*. The dispatch tables REFERENCE parser symbols; the symbols themselves are public exports of parser.asm.
  - [x] **Update the `src/dispatch.asm` header `Dependencies:` line** to add the parser symbols dispatch_normal references: `src/parser.asm (Story 1.10 — parser_handle_digit, parser_handle_operator, parser_handle_motion_prefix)`. Sjasmplus's two-pass assembly resolves the forward references because dispatch.asm INCLUDEs before parser.asm in src/vibe.asm — first pass tolerates undefined symbols; second pass resolves them.

- [x] Task 10 — Insert `INCLUDE "parser.asm"` into `src/vibe.asm` per AR25. (AC: 16)
  - [x] Add `INCLUDE "parser.asm"` AFTER `INCLUDE "dispatch.asm"` (line 73 of current `src/vibe.asm`) and BEFORE the `;; --- Input-loop abort target ---` comment block (line 75) — i.e., between line 73's `INCLUDE "dispatch.asm"` and line 75's section divider.
  - [x] Add a per-INCLUDE comment block matching the prior INCLUDEs' style (see `src/vibe.asm` lines 67-73 for dispatch.asm's pattern). Citation: AR25 + Story 1.10 + a one-line role description.
    ```
    ;; --- Command parser (MC4; parser.asm — Story 1.10) ---
    ; AR25 order: dispatch -> parser -> motions. motions.asm
    ; (Story 2.5+) does not yet exist; when it lands it will slot
    ; in BEFORE no, AFTER parser.asm here. Production callers of
    ; parser_handle_digit / parser_handle_operator /
    ; parser_handle_motion_prefix arrive in Story 1.12 (the
    ; input_loop body wires input_get_key + dispatch_key + render_diff
    ; together; dispatch_normal's parser entries fire from there).
        INCLUDE "parser.asm"
    ```
  - [x] Update the `src/vibe.asm` header `Dependencies:` line (line 24) to add `src/parser.asm (Story 1.10)` alongside the existing entries.
  - [x] Do NOT modify the `input_loop:` body (lines 85-88) — it stays the Story 1.5 stub that warm-boots via `BDOS_CALL BDOS_EXIT`; Story 1.12 lands the real loop body that ties `input_get_key + dispatch_key + render_diff` together.
  - [x] Do NOT modify the `;; --- Input-loop abort target ---` comment block — it already correctly points to Story 1.12 as the loop-body owner.

- [x] Task 11 — Write `test/cases/parser_count-accumulator.asm`. (AC: 2, 12)
  - [x] Pre-zero count_accumulator (LD HL, 0 / LD (count_accumulator), HL) and pending_motion_prefix (XOR A / LD (pending_motion_prefix), A).
  - [x] **Subtest 1: single non-zero digit.** Call parser_handle_digit('5'). Verify count_accumulator == 5 (16-bit compare via LD HL, (count_accumulator) / LD A, H / OR A / JP NZ, fail / LD A, L / CP 5 / JP NZ, fail). Sentinel 0xE1 on failure with B = observed L byte.
  - [x] **Subtest 2: digit accumulation.** parser_handle_digit('1'); parser_handle_digit('2'). Verify count_accumulator == 12. Sentinel 0xE2.
  - [x] **Subtest 3: 3-digit accumulation.** Reset count, then parser_handle_digit('1'); parser_handle_digit('2'); parser_handle_digit('3'). Verify count_accumulator == 123 (= 0x7B). Sentinel 0xE3.
  - [x] **Subtest 4: large count.** Reset, then accumulate '9' '9' '9' '9'. Verify count_accumulator == 9999 (= 0x270F). Sentinel 0xE4.
  - [x] On all-pass, `JP test_pass`.
  - [x] Standard test prologue/epilogue + production INCLUDEs (statusln.asm + dispatch.asm + parser.asm + the test_input_loop_stub) + state.inc LAST. Mirror `test/cases/dispatch_mode-transition.asm` for shape.

- [x] Task 12 — Write `test/cases/parser_leading-zero-is-motion.asm`. (AC: 3, 12)
  - [x] Pre-zero count_accumulator, pending_operator, pending_motion_prefix, status_dirty.
  - [x] **Subtest 1: leading '0' fires motion-zero stub.** Call parser_handle_digit('0'). Verify (a) count_accumulator still == 0 (the stub does NOT modify count), (b) status_dirty != 0 (the stub set it via status_set_message). Sentinels 0xE1 (count not 0) / 0xE2 (status_dirty not set).
  - [x] **Subtest 2: leading '0' followed by another '0' BOTH fire motion-zero stub.** Reset state. Call parser_handle_digit('0') twice. After each, verify status_dirty != 0 (and reset it to 0 between calls so each invocation is observable). count_accumulator stays 0 throughout. Sentinels 0xE3 / 0xE4.
  - [x] On all-pass, `JP test_pass`.

- [x] Task 13 — Write `test/cases/parser_zero-after-digit.asm`. (AC: 4, 12)
  - [x] Pre-zero state. Call parser_handle_digit('1'). Verify count_accumulator == 1. Then parser_handle_digit('0'). Verify count_accumulator == 10 (NOT a motion-zero call — status_dirty MUST NOT have been set by parser_motion_zero_stub for this branch). Sentinels 0xE1 (intermediate count != 1) / 0xE2 (final count != 10) / 0xE3 (status_dirty != 0 — leading-zero branch was incorrectly taken).
  - [x] Bonus subtest: '1' '0' '0' yields 100 (= 0x64). Sentinel 0xE4.
  - [x] On all-pass, `JP test_pass`.

- [x] Task 14 — Write `test/cases/parser_doubled-operator-dd.asm`. (AC: 5, 6, 12)
  - [x] Pre-zero state.
  - [x] **Subtest 1: first 'd' sets pending_operator.** Call parser_handle_operator('d'). Verify (a) pending_operator == 'd' (= 0x64), (b) count_accumulator unchanged at 0, (c) status_dirty == 0 (no stub fired). Sentinels 0xE1 / 0xE2 / 0xE3.
  - [x] **Subtest 2: second 'd' fires doubled-operator stub.** With pending_operator already == 'd' from Subtest 1, call parser_handle_operator('d') again. Verify (a) status_dirty != 0 (the stub fired), (b) pending_operator == 0 (parser_clear ran), (c) count_accumulator == 0 (parser_clear ran), (d) pending_motion_prefix == 0 (parser_clear ran). Sentinels 0xE4 / 0xE5 / 0xE6 / 0xE7.
  - [x] **Subtest 3: yy variant (parameter test).** Reset state. Call parser_handle_operator('y') twice. Verify same post-conditions as Subtest 2. Sentinel 0xE8.
  - [x] **Subtest 4: 'd' then 'y' is NOT doubled.** Reset state. parser_handle_operator('d'); parser_handle_operator('y'). Verify pending_operator == 'y' (last-operator-wins; the doubled-detection saw `'d' != 'y'`), status_dirty == 0 (no stub fired). Sentinels 0xE9 / 0xEA.
  - [x] On all-pass, `JP test_pass`.

- [x] Task 15 — Write `test/cases/parser_compose-count-op-motion.asm`. (AC: 5, 9, 10, 12)
  - [x] Pre-zero state. Define a synthetic `test_motion_stub` in the test file that records the observed count_accumulator and pending_operator into TEST_CONTEXT bytes (or a 4-byte synthetic capture buffer) and RETs.
  - [x] **Subtest 1: count + operator + motion compose.** Call parser_handle_digit('5'); parser_handle_operator('d'); call parser_dispatch with HL = test_motion_stub. After the call, verify (a) the stub's capture shows count == 5 AND pending_operator == 'd' at handler-entry, (b) post-dispatch, count_accumulator == 0, pending_operator == 0, pending_motion_prefix == 0 (parser_clear ran). Sentinels 0xE1 (stub never ran) / 0xE2 (count seen by stub != 5) / 0xE3 (operator seen by stub != 'd') / 0xE4 (post-dispatch count != 0) / 0xE5 (post-dispatch pending_operator != 0).
  - [x] **Subtest 2: bare motion (no count, no operator).** Reset state. Call parser_dispatch with HL = test_motion_stub. Stub captures count == 0 AND pending_operator == 0. Post-dispatch all state is 0 (already was). Sentinels 0xE6 / 0xE7.
  - [x] On all-pass, `JP test_pass`.
  - [x] **Test stub motion handler shape** (mirrors `test/cases/dispatch_binary-search-finds-key.asm`'s sentinel handlers):
    ```
    test_motion_stub:
        ;; Capture parser state at handler entry into TEST_CONTEXT
        ;; and a synthetic 3-byte capture buffer (count = 2 bytes,
        ;; operator = 1 byte). The buffer is local to the test file
        ;; (DEFW / DEFB after the test body, before INCLUDEs).
        LD      HL, (count_accumulator)
        LD      (test_capture_count), HL
        LD      A, (pending_operator)
        LD      (test_capture_op), A
        ;; Mark "stub ran" so a non-firing dispatch is detectable.
        LD      A, 0xCA
        LD      (TEST_CONTEXT), A
        RET
    ```

- [x] Task 16 — Write `test/cases/parser_motion-prefix-gg.asm`. (AC: 7, 8, 12)
  - [x] Pre-zero state.
  - [x] **Subtest 1: first 'g' sets pending_motion_prefix.** parser_handle_motion_prefix('g'). Verify (a) pending_motion_prefix == 'g' (= 0x67), (b) status_dirty == 0 (no stub fired), (c) count_accumulator unchanged at 0. Sentinels 0xE1 / 0xE2 / 0xE3.
  - [x] **Subtest 2: second 'g' fires gg-motion stub.** With pending_motion_prefix already == 'g', call parser_handle_motion_prefix('g') again. Verify (a) status_dirty != 0 (stub fired), (b) pending_motion_prefix == 0 (parser_clear ran), (c) count_accumulator == 0 / pending_operator == 0 (parser_clear ran). Sentinels 0xE4 / 0xE5 / 0xE6 / 0xE7.
  - [x] **Subtest 3: count survives across 'g' but is cleared by gg dispatch.** Reset; parser_handle_digit('5') → count = 5; parser_handle_motion_prefix('g') → pending_motion_prefix = 'g', count still 5; parser_handle_motion_prefix('g') → gg dispatch fires + parser_clear runs → count == 0 again. Sentinels 0xE8 (count != 5 mid-sequence) / 0xE9 (count != 0 post-dispatch).
  - [x] On all-pass, `JP test_pass`.

- [x] Task 17 — Write `test/cases/parser_motion-prefix-cleared-on-other-key.asm`. (AC: 11, 12)
  - [x] Pre-zero state.
  - [x] **Subtest 1: 'g' then digit clears prefix.** parser_handle_motion_prefix('g') → pending_motion_prefix = 'g'. parser_handle_digit('5') → must clear pending_motion_prefix on entry. Verify post-call pending_motion_prefix == 0 AND count_accumulator == 5. Sentinels 0xE1 / 0xE2.
  - [x] **Subtest 2: 'g' then operator clears prefix.** Reset state. parser_handle_motion_prefix('g'); parser_handle_operator('d'). Verify pending_motion_prefix == 0 AND pending_operator == 'd'. Sentinels 0xE3 / 0xE4.
  - [x] **Subtest 3: 'g' alone leaves prefix set (no auto-clear).** Reset. parser_handle_motion_prefix('g'). Verify pending_motion_prefix == 'g'. Sentinel 0xE5. (This subtest guards against an "always clear on any parser entry" bug — the prefix MUST persist until a non-prefix-aware key arrives, otherwise gg detection is impossible.)
  - [x] On all-pass, `JP test_pass`.

- [x] Task 18 — Build, test, determinism check, AR-grep enforcement. (AC: 12, 15)
  - [x] `make` from project root → `vibe.com` builds cleanly under sjasmplus 1.23.0.
  - [x] `make clean && make` twice → byte-identical SHA across runs (NFR18). Capture both SHAs in Debug Log References.
  - [x] `make -C test test` → 17 pass / 1 fail (the deliberate `harness_fail` is the only `fail`; the 10 pre-1.10 cases — gapbuf × 6 + dispatch × 3 + harness_pass — still pass; the 7 new `parser_*` cases pass). Capture verbatim in Debug Log References.
  - [x] `grep -nE 'BIOS_CONOUT' src/parser.asm` → zero matches. (AR13)
  - [x] `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/parser.asm` → zero matches. (AR15 — parser doesn't use BDOS at all; the stubs route via status_set_message which itself doesn't BDOS.)
  - [x] `grep -nE 'gapbuf_(insert|delete|move_gap|load|init)' src/parser.asm` → zero matches. (AR14)
  - [x] Capture grep outputs in Debug Log References.

## Dev Notes

### Critical traps — what to watch for when implementing this story

**🛑 The 16-bit count*10 multiply has multiple right answers and one wrong one.** The recommended `(count*4 + count) * 2` form is 4 ADD HLs + 1 LD DE pair = ~50 T-states. An attractive-looking `count*8 + count*2` form requires a saved copy of count*2 (in BC) since the *8 path destroys it — works, but uses an extra register and is no faster. The wrong path is `count + count + count + count + count + count + count + count + count + count` (10 ADDs) — wastes ~50 T-states for no benefit. Pick the *5-then-*2 form, document it inline.

**🛑 `count*10 + digit` overflow is silent.** count > 6553 followed by another digit overflows HL modulo 65536. The architecture says nothing about overflow protection, vi tradition is "no real-world count is that big — let it wrap", and adding a clamp would consume bytes without surfacing real bugs. Document the wrap as a known sharp edge in the routine's comment block, not a hidden bug.

**🛑 `parser_handle_digit`'s leading-zero branch must check BOTH bytes of count_accumulator, not just the low byte.** A test like `LD A, (count_accumulator) : OR A` only checks the low byte. If a previous overflow or test-residue left count_accumulator with high byte != 0 and low byte == 0 (e.g. 0x100), the leading-zero branch would fire spuriously. Use `LD HL, (count_accumulator) : LD A, H : OR L : JR NZ, .accumulate` — both bytes ORed.

**🛑 `parser_handle_motion_prefix` does NOT clear pending_motion_prefix on entry — the OTHER two parser_handle_* DO.** This asymmetry is essential: the doubled-prefix branch needs to *test* the prior prefix value, so clearing it on entry would short-circuit gg detection. parser_handle_digit and parser_handle_operator clear the prefix because a non-prefix-aware key has arrived (AC11). Document the asymmetry in each routine's contract block; a future "consistency cleanup" that adds a clear-on-entry to parser_handle_motion_prefix would silently break gg.

**🛑 The "stale-pending-operator" case (e.g. 'd' then 'y') is not pinned by AC.** The chosen behaviour is "last-operator-wins" — pending_operator is replaced with the new value. This matches modern vim's tendency to abort the prior operator on operator-conflict. An equally valid alternative is "abort both — clear pending_operator and ignore the new operator" (some old vis do this). The current AC test (`parser_doubled-operator-dd.asm` Subtest 4) is written for "last-operator-wins"; if a future review prefers the abort path, the test changes.

**🛑 `parser_dispatch`'s `CALL .invoke` / `JP (HL)` / tail-`JP parser_clear` pattern is the cleanest Z80 form.** Alternatives: (a) self-modifying code (`LD (.target+1), HL : .target: CALL 0x0000 : JP parser_clear`) — works in CP/M .com (loaded into RAM), but ugly and harder to debug; (b) `PUSH HL : RET` — that's a tail-call to the motion, and parser_clear never runs. Stick with the `CALL .invoke` pattern documented in Task 7.

**🛑 `JP (HL)` is `JP HL`, not `JP (memory[HL])`.** The Story 1.9 dev-notes flagged this for dispatch_key; it recurs in parser_dispatch's `.invoke` helper. `JP (HL)` transfers control to the address IN HL, not to the address stored AT HL. Standard Z80 footgun for anyone arriving from a CISC mental model.

**🛑 `parser_clear` zeros 4 bytes of state — not 3.** count_accumulator is 16-bit (2 bytes); pending_operator and pending_motion_prefix are 1 byte each. Total 4. The recommended `LD HL, 0 : LD (count_accumulator), HL` + 2× `XOR A : LD (...), A` form emits 7 bytes of code (`LD HL, nn` = 3 bytes, `LD (nn), HL` = 3 bytes, `XOR A` = 1 byte, `LD (nn), A` = 3 bytes). Two `XOR A` + four `LD (nn), A` is 13 bytes — 6 bytes worse. Use the HL-zero form.

**🛑 `status_set_message` trashes A, BC, DE, HL, F (per its contract at `src/statusln.asm` lines 26-27).** The three Epic-1 stubs all call status_set_message. After the call, NONE of the previous register state survives — including the parser's own scratch (e.g. C holding the digit char in parser_handle_digit). The stubs are END-of-call paths for their callers, so this is fine, but if you ever interleave status_set_message with mid-routine work, save the relevant registers first (PUSH AF / PUSH BC / etc.).

**🛑 Forward references from `dispatch.asm` to `parser.asm` symbols rely on sjasmplus's two-pass assembly.** dispatch.asm INCLUDEs first (line 73 of vibe.asm); parser.asm INCLUDEs second (line ~75 after Story 1.10). The 16 new dispatch_normal entries reference `parser_handle_digit`, `parser_handle_operator`, `parser_handle_motion_prefix` — undefined on first pass, resolved on second. If sjasmplus errors with "Symbol parser_handle_digit not defined", the INCLUDE order is wrong (parser must come AFTER dispatch in vibe.asm).

**🛑 The dispatch_normal table's `DISPATCH_NORMAL_COUNT EQU ($ - .entries) / 3` recomputes positionally — do NOT manually edit the count.** Story 1.9's value (= 9) is implicit; Story 1.10's value (= 25) emerges from the 16 new entries. The `$ - .entries` form computes byte-distance and divides by entry size; sjasmplus does it at assembly time. Hand-editing the count to a literal is a common bug — don't.

**🛑 The 16 new ASSERT lines need consecutive-pair coverage.** Inserting digits between '/' and ':' breaks the ASSERT `':' > '/'` (now should be `':' > '9'`). Inserting '<' '>' between ':' and 'O' breaks `'O' > ':'` (now `'O' > '>'`). Inserting 'c' 'd' 'g' between 'a' and 'i' breaks `'i' > 'a'` (now `'i' > 'g'`). 16 NEW ASSERTs + 3 REPLACED ASSERTs + 5 EXISTING-UNCHANGED ASSERTs = 24 total. Total table sort-order coverage is one ASSERT per consecutive pair (24 pairs across 25 entries); a swap-typo at any pair fails sjasmplus immediately.

**🛑 The TEST_CONTEXT byte at 0xCFFF is a single-byte sentinel.** Tests that need to capture multiple bytes (e.g. parser_compose-count-op-motion's count + operator capture) must allocate a synthetic capture buffer in the test file (DEFW / DEFB after the test body). Don't try to pack count + operator into the 1-byte TEST_CONTEXT; the test will silently overwrite earlier captures. The synthetic buffer pattern (`test_capture_count: DEFW 0` etc.) costs only the bytes used and stays test-local — no state.inc pollution.

**🛑 Headless test status_dirty observation requires pre-zeroing.** Several tests check "did the stub fire?" via status_dirty != 0. status_dirty is in the static block which CP/M does NOT zero on .com load. Always pre-zero status_dirty before each subtest that checks it (`XOR A : LD (status_dirty), A`). Otherwise boot residue may set it, masquerading as "stub fired". The dispatch_mode-transition.asm Story 1.9 tests already follow this pattern — mirror it.

**🛑 The motion-zero stub (parser_motion_zero_stub) does NOT call parser_clear.** The leading-zero-is-motion branch fires when count_accumulator == 0 by precondition; there's nothing to clear. (pending_operator and pending_motion_prefix are NOT cleared because they may legitimately persist — `d0` is "delete to line start" in vi, a valid compose; the operator and prefix carry across.) When Story 2.6 lands the real motion-0, it inherits this — the motion-0 handler itself is just a "set cursor to line-start" action, parser state is handled by whatever wrapped the motion (parser_dispatch in the operator-motion compose path, or nothing in the bare-motion path).

**🛑 The doubled-operator and gg-motion stubs DO call parser_clear (via tail-JP).** These dispatch a complete command — the entire pending state is consumed. parser_clear resets count_accumulator + pending_operator + pending_motion_prefix to 0 so the next compose starts fresh. If the dev forgets the tail-JP, doubled-op fires but pending_operator still contains the operator byte — the very next operator press would re-trigger the doubled stub spuriously.

**🛑 The architecture's parser-ownership boundary: parser owns count_accumulator / pending_operator / pending_motion_prefix; motions.asm (Story 2.5+) owns nothing parser-related — motion handlers READ these via state.inc symbols and let parser_dispatch / parser_clear write them.** A motion handler that writes count_accumulator directly is breaking the parser-owns-parser-state invariant. Mention of "no module mutates parser state outside parser.asm" in the parser.asm header is good defensive documentation.

**🛑 No new state.inc fields in Story 1.10 — RESIST the urge to add `parser_test_sentinel` or similar test-only state.** Test stubs use TEST_CONTEXT (defined in test_prologue.inc, scope = test_*) and synthetic test-local capture buffers. Production state.inc stays clean of test-only fields.

**🛑 The architecture.md sample shows the parser as a state machine, but doesn't pin which routine clears pending_motion_prefix on a non-g key.** The story chooses parser_handle_digit and parser_handle_operator as the clearing sites. An alternative (clearing inside parser_dispatch) would be wrong — by the time parser_dispatch runs, the motion has already been chosen, and the prefix state is irrelevant. Clear at the entry of the *new* state-changing key.

**🛑 dispatch_normal's '0' entry is NOT a stub — it routes to parser_handle_digit, which itself contains the leading-zero-is-motion logic.** This is the cleanest design: the parser owns the digit/motion decision because it owns count_accumulator. dispatch_normal doesn't need to know about the ambiguity. A naive design would have '0' route to a "decide" stub that then dispatches to either digit-path or motion-path — that's a second level of dispatch with no benefit.

**🛑 `state.inc` MUST remain the LAST INCLUDE in `src/vibe.asm` AND in any test file.** Story 1.10 adds NO new state.inc fields, so the layout is unchanged. `vibe.com`'s SHA changes after Story 1.10 (deliberate — new code in parser.asm, +16 entries / +16 ASSERTs in dispatch.asm), but two consecutive rebuilds still produce byte-identical output (NFR18 holds; AC15 verifies).

### Architecture compliance — what AR* / SR* / NFR* / TH* rules this story locks in

| Rule | Story 1.10 obligation |
|---|---|
| AR6  | All compile-time knobs in `inc/equates.inc`. Story 1.10 reads no new equates; the per-table `DISPATCH_NORMAL_COUNT` recomputes positionally. NO new equates in `inc/equates.inc`. |
| AR10 | Mode IDs and synthesised arrow keycodes in `inc/modes.inc`. Story 1.10 does NOT read mode IDs (parser is mode-agnostic — it operates only when invoked from normal-mode dispatch, but doesn't itself check mode_byte). NO new mode equates. |
| AR12 | Single status-message funnel: every status-line write in `src/parser.asm` (the three stub handlers' status feedback) goes through `status_set_message`. Direct writes to `status_buffer` / `status_dirty` are forbidden. AC15 enforces by absence-of-direct-writes (parser.asm only references `mode_byte`/`visual_submode`/`status_dirty` indirectly through statusln.asm; tests directly read `status_dirty` for observability — that's read-only test scaffold use, not a violation). |
| AR13 | Single screen-emission path: `render.asm` (Story 1.11) is the only module that calls `BIOS_CONOUT`. Parser dispatches stub messages to `status_set_message`, NOT to `BIOS_CONOUT`. AC15 grep enforces. |
| AR14 | Single buffer-mutation owner: `gapbuf.asm` is the only mutator. Parser does NOT call `gapbuf_*` — it only reads/writes its own state.inc fields. AC15 grep enforces. |
| AR15 | Single BDOS gateway: `BDOS_CALL` macro. Parser uses NO BDOS at all (the stubs go via status_set_message, which itself does not BDOS — only bdos_error_funnel inside statusln.asm uses BDOS_CALL on the abort path, and parser stubs never enter that path). AC15 grep enforces source-level zero matches. |
| AR16 | Status-message string-table convention: parser uses ONLY `msg_not_implemented` (added in Story 1.7). NO new strings added by Story 1.10. (A future story could add a parser-specific msg_count_overflow if overflow protection lands — defer.) |
| AR21 | Headless coverage scope: parser is fully testable headlessly (it's pure-state logic — no BIOS, no tick counter, no BDOS). The seven new tests `parser_*.asm` are explicitly in the AR21 scope ("command parser ... operator+motion composition"). |
| AR22 | Naming: `parser_handle_digit`, `parser_handle_operator`, `parser_handle_motion_prefix`, `parser_dispatch`, `parser_clear`, `parser_motion_zero_stub`, `parser_doubled_operator_stub`, `parser_gg_motion_stub` are all `module_action`-style lowercase. Internal labels in the routines use dotted-locals (`.accumulate`, `.first_operator`, `.first_prefix`, `.invoke`). |
| AR23 | Module header block + four-line `In:` / `Out:` / `Trashes:` / `Calls:` per public routine AND per internal helper. AC1 + AC14 enforce. |
| AR24 | UPPERCASE mnemonics + registers; 4-space indent; `;` line / `;;` section comments. No new strings → no AR24-string concerns this story. |
| AR25 | `INCLUDE "parser.asm"` in `src/vibe.asm` lands AFTER `INCLUDE "dispatch.asm"` and BEFORE the `;; --- Input-loop abort target ---` divider. When Story 2.5 lands `motions.asm`, it slots in AFTER `parser.asm`. |
| MC1 | Caller-saved everywhere by default. Each routine's `Trashes:` line lists every register it touches; mode-change handlers' `Trashes:` lines list theirs (including A, BC, DE, HL, F where status_set_message is called). |
| MC4 | Handler signature: `A = key just consumed`. parser_handle_* entries respect this; parser_dispatch takes `HL = motion handler addr` as its sole parameter (documented exception per AC9; parser_dispatch is NOT a dispatch-table target — it's a helper for motion handlers). |
| MC7 | All cross-module state via symbols in `state.inc`. parser.asm reads/writes `count_accumulator`, `pending_operator`, `pending_motion_prefix` by symbol; never inline addresses. |
| NFR1 | Incremental render: parser never emits screen bytes (AR13 holds via grep); the only screen-state change a stub produces is `status_dirty` set by `status_set_message`. |
| NFR2 | Sustained typing: parser_handle_digit's worst-case path (multiply + add) ≈ 60-80 T-states; parser_handle_operator ≈ 30 T-states; parser_handle_motion_prefix ≈ 25 T-states. All three orders of magnitude under perceptible. Won't slow typing. |
| NFR9 | Code-size budget: estimated 100-180 bytes for parser.asm (parser_handle_digit ≈ 50 bytes including the multiply, parser_handle_operator ≈ 25 bytes, parser_handle_motion_prefix ≈ 20 bytes, parser_dispatch ≈ 10 bytes, parser_clear ≈ 12 bytes, three stubs ≈ 30 bytes, padding/headers/.invoke). dispatch.asm grows by ~55 bytes (16 × 3 entries + 16 ASSERT lines, though ASSERTs emit no bytes). Total ≈ 100-180 bytes added. Stay well within the ~3 KB envelope. |
| NFR10 | TPA fit: `inc/state.inc`'s `ASSERT yank_end <= 0xD800` covers static-block + gap + yank. parser.asm code adds ≈ 100-180 bytes of code (no static), well under the headroom. |
| NFR16 | Knob centralization: parser reads/writes only count_accumulator / pending_operator / pending_motion_prefix by state.inc symbol; no inline `LD (0xnnnn)` for state addresses; no inline literals for ASCII (uses `'0'`, `'d'`, `'g'` character literals which are compile-time constants, not magic numbers). |
| NFR17 | Mode/operator decoupling: parser tables (this story's dispatch_normal entries) reference parser handlers; parser logic itself does NOT check mode_byte or visual_submode. The parser is "stateless w.r.t. modes" per the architecture — its state lives in state.inc and is read by both normal-mode entries (via dispatch_normal) and any future visual-mode entries (3.6's visual operators may reuse pending_operator). |
| NFR18 | Reproducibility: `vibe.com` byte-identical across rebuilds (AC15). sjasmplus is deterministic on identical input. |

### Existing files — current state and what this story changes

**`src/parser.asm`** *(does not exist):*
- Current: not present.
- This story: create per Tasks 2-8. Five public entries (parser_handle_digit, parser_handle_operator, parser_handle_motion_prefix, parser_dispatch, parser_clear) plus three Epic-1 stubs (parser_motion_zero_stub, parser_doubled_operator_stub, parser_gg_motion_stub). Estimated ~100-180 bytes of code.

**`src/dispatch.asm`** *(483 lines after Story 1.9):*
- Current: provides dispatch_key (binary search), four mode tables (dispatch_normal at 9 entries, dispatch_insert/command/visual at 1 entry each), four mode-change handlers, three Epic-1 stubs (mode_full_refresh_stub, mode_search_prompt_stub, mode_debug_quit), four unbound handlers. dispatch_normal currently has 8 inline ASSERT lines covering its 9-entry sort order.
- This story: extend `dispatch_normal` with 16 new entries (Task 9). Three existing ASSERTs (`':' > '/'`, `'O' > ':'`, `'i' > 'a'`) need replacing because the new entries break their adjacency; 16 NEW ASSERTs (one per new pair); 5 existing ASSERTs (`0x11 > 0x0C`, `'/' > 0x11`, `'a' > 'O'`, `'o' > 'i'`, `'v' > 'o'`) stay unchanged. The header `Dependencies:` line gains `src/parser.asm (Story 1.10)`. NO changes to dispatch_key, mode tables, mode-change handlers, stubs, or unbound handlers.

**`src/vibe.asm`** *(99 lines after Story 1.9):*
- Current: pre-ORG INCLUDEs equates/bios/bdos/vt52/modes (lines 31-35), then `ORG 0x0100` (line 37), then `RET` stub (line 39), then `INCLUDE "input.asm"` (line 50), then `INCLUDE "statusln.asm"` (line 57), then `INCLUDE "gapbuf.asm"` (line 65), then `INCLUDE "dispatch.asm"` (line 73), then the `;; --- Input-loop abort target ---` comment block (lines 75-84) followed by the `input_loop:` Story 1.5 stub (lines 85-88), then `INCLUDE "../inc/state.inc"` LAST (line 99).
- This story: insert `INCLUDE "parser.asm"` between line 73's `INCLUDE "dispatch.asm"` and line 75's `;; --- Input-loop abort target ---` divider. Match the per-INCLUDE comment-block style of the prior INCLUDEs (2-3 line `;; --- ` block citing AR25 + a one-line "Story X.Y" reference). Update the `vibe.asm` header `Dependencies:` line (line 24) to add `src/parser.asm (Story 1.10)`. Do NOT modify the `input_loop:` body (Story 1.12 owns it) or the `;; --- Input-loop abort target ---` comment block.

**`src/statusln.asm`** *(196 lines after Story 1.9):*
- Current: provides `status_set_message`, `bdos_error_funnel`, `status_render`, message-string block at lines 174-195 (existing strings + Story 1.9's mode/unbound strings).
- This story: NOT modified. parser stubs reuse the existing `msg_not_implemented` (added in Story 1.7); no new strings needed for Epic 1's parser.

**`inc/state.inc`** *(127 lines after Story 1.8):*
- Current: declares all parser state — `pending_operator` (line 51), `pending_motion_prefix` (line 57), `count_accumulator` (lines 73-74) — since Story 1.3.
- This story: NOT modified. Story 1.10 reads/writes existing fields by symbol; no new layout changes.

**`src/input.asm`**, **`src/gapbuf.asm`**:
- All unchanged. Story 1.10 does not call `input_get_key` (the input-loop body that wires input → dispatch lands in Story 1.12) or any `gapbuf_*` (AR14: parser is metadata-only).

**`inc/equates.inc`**, **`inc/bios.inc`**, **`inc/bdos.inc`**, **`inc/modes.inc`**, **`inc/vt52.inc`**:
- All unchanged. Story 1.10 reads no new equates and no new mode IDs.

**`Makefile`** / **`test/Makefile`**:
- All unchanged. Build infrastructure picks up `src/parser.asm` automatically via the `wildcard src/*.asm` glob (top-level Makefile line 29). Test harness picks up the seven new `test/cases/parser_*.asm` files automatically via `wildcard cases/*.asm` (test/Makefile line 36).

**`test/cases/`** *(currently 11 files: harness × 2 + gapbuf × 6 + dispatch × 3):*
- Current: 11 cases. Live baseline 10 pass / 1 fail (only `harness_fail` fails by design).
- This story: add seven new cases — `parser_count-accumulator.asm`, `parser_leading-zero-is-motion.asm`, `parser_zero-after-digit.asm`, `parser_doubled-operator-dd.asm`, `parser_compose-count-op-motion.asm`, `parser_motion-prefix-gg.asm`, `parser_motion-prefix-cleared-on-other-key.asm`. New baseline: 18 cases, 17 pass / 1 fail.

**`test/inc/`**, **`test/fixtures/`**, **`test/smoke/`**:
- All unchanged. Existing prologue/epilogue/input_loop_stub support the new tests as-is.

**Files NOT touched by this story (do not edit):**
- `inc/equates.inc`, `inc/bios.inc`, `inc/bdos.inc`, `inc/modes.inc`, `inc/vt52.inc`, `inc/state.inc` — all referenced by symbol; no edits needed.
- `Makefile`, `test/Makefile` — wildcards pick up new sources / new tests automatically.
- `src/input.asm`, `src/gapbuf.asm`, `src/statusln.asm` — unchanged.
- `test/cases/*.asm` (existing — harness × 2, gapbuf × 6, dispatch × 3) — unchanged. All still pass.
- `test/inc/*.inc`, `test/fixtures/hello.txt`, `test/smoke/*.asm` — unchanged.

**Files created by this story:**
- `src/parser.asm` (new — primary deliverable).
- `test/cases/parser_count-accumulator.asm` (new).
- `test/cases/parser_leading-zero-is-motion.asm` (new).
- `test/cases/parser_zero-after-digit.asm` (new).
- `test/cases/parser_doubled-operator-dd.asm` (new).
- `test/cases/parser_compose-count-op-motion.asm` (new).
- `test/cases/parser_motion-prefix-gg.asm` (new).
- `test/cases/parser_motion-prefix-cleared-on-other-key.asm` (new).

**Files modified by this story:**
- `src/vibe.asm` — add `INCLUDE "parser.asm"` (per AR25); update header `Dependencies:` line.
- `src/dispatch.asm` — extend `dispatch_normal` with 16 new entries; replace 3 ASSERTs and add 16 new ASSERTs (24 total); update header `Dependencies:` line.

### Library / framework requirements

**sjasmplus 1.23.0:**
- Already pinned by `Makefile`'s `check-toolchain` (Story 1.1). No new toolchain pin in this story.
- **Multi-pass assembly resolves forward references.** `src/dispatch.asm`'s 16 new entries reference `parser_handle_digit`, `parser_handle_operator`, `parser_handle_motion_prefix` — defined in `src/parser.asm`, which INCLUDEs AFTER `src/dispatch.asm` in `src/vibe.asm` (per AR25). The first pass tolerates undefined symbols; the second pass resolves them. Same forward-reference pattern as Story 1.9's dispatch table referencing handlers in the same file.
- **`DEFW` emits 16-bit little-endian.** Mode-table entries `DEFB key : DEFW handler_addr` lay out as 1 byte + 2 bytes (low, high). dispatch_key's load `LD E, (HL); INC HL; LD D, (HL)` matches this byte order.
- **`ASSERT` is build-time only (operates on assembly-time constants).** The 16 new dispatch_normal ASSERTs are constant-vs-constant comparisons (`'1' > '0'` etc.) — sjasmplus evaluates at assembly. Emits zero bytes; SHA unchanged.
- **`ADD HL, HL` and `ADD HL, DE` are 16-bit shift-and-add primitives.** parser_handle_digit's count*10 multiply uses these (4 ADD HLs in the recommended `(count*4 + count) * 2` form). 11 T-states each = ~50 T-states for the multiply.

**iz-cpm:**
- Used for the seven new headless tests (`make -C test test`). All seven tests are pure-state logic; no BIOS_CONIN / BIOS_CONINST / BIOS_TICK_ADDR access. iz-cpm's full BDOS function 9 / function 0 emulation is exercised by the prologue/epilogue (CALL 0x0005); the test bodies don't rely on BDOS or BIOS for anything beyond the harness exit.
- `iz-cpm` runs each `.com` with a 5-second timeout (`test/Makefile` line 34). Even a runaway parser-loop bug (e.g., infinite digit accumulation) would terminate within 5 s.

**CP/M 2.2 BDOS:**
- NOT used by parser.asm directly. Production parser stubs route via `status_set_message`, which itself does NOT use BDOS — only `bdos_error_funnel` inside statusln.asm uses BDOS_CALL, and parser stubs never enter that path (no FCB ops). AC15 grep verifies zero raw BDOS calls in src/parser.asm.

**MicroBeast BIOS:**
- NOT called by `src/parser.asm` (AR13). The BIOS is reached only via `src/render.asm` (Story 1.11) and `src/input.asm` (Story 1.8); parser sits between dispatch and motion handlers in the data flow and never emits or polls.

### Previous story intelligence (Stories 1.1-1.9)

**From Story 1.1:**
- `make` from project root produces `vibe.com` deterministically. Adding `src/parser.asm` and 16 new dispatch entries shifts the layout but preserves byte-determinism (NFR18). AC15 verifies.

**From Story 1.2:**
- `inc/modes.inc` declares `MODE_NORMAL/INSERT/COMMAND/VISUAL` (lines 23-26) — parser does NOT read these (it's mode-agnostic). `KEY_ARROW_*` (lines 39-42) likewise irrelevant — arrows are not parser-handled.
- `inc/equates.inc` provides no parser-relevant constants; the multiply-by-10 uses inline 16-bit arithmetic, not an equate.

**From Story 1.3:**
- `inc/state.inc` declares all three parser state fields: `pending_operator` (line 51), `pending_motion_prefix` (line 57), `count_accumulator` (lines 73-74). Story 1.10 is the first writer of any of these — Stories 1.4-1.9 all left them as boot-residue (the static block has no zero-init until Story 1.12).
- **Mode-state protocol partially documented at top of `src/dispatch.asm` per Story 1.9's resolution of one third of the deferred-work item.** Story 1.10 adds the parser-state half: the asymmetric-clear protocol (parser_handle_digit / parser_handle_operator clear pending_motion_prefix on entry; parser_handle_motion_prefix does NOT) is documented in the parser.asm header. This resolves another third of the original Story 1.3 deferral. The remaining third (the visual_submode / visual_anchor coupling, FR33-FR38) is Story 3.3's natural home.

**From Story 1.4:**
- `inc/bdos.inc` lines 83-88 define the `BDOS_CALL` macro. Parser does NOT use it (no BDOS calls). The stubs route via status_set_message which itself doesn't BDOS. AC15 verifies.

**From Story 1.5:**
- `src/statusln.asm` is the AR12 / MC5 funnel. `status_set_message` (lines 76-98) takes `HL = msg ptr, A = code`, copies into status_buffer, sets status_dirty, returns. Story 1.10's three stubs are textbook callers.
- Message-string conventions: lowercase, no period, under 30 chars (AR16). Story 1.10 reuses `msg_not_implemented` (added in Story 1.7) for all three stubs — no new strings.
- `bdos_error_funnel` (lines 129-135) JPs to `input_loop` after writing `msg_bdos_error`. Story 1.10 doesn't add any new `BDOS_CALL` sites that could fail.

**From Story 1.6:**
- `make test` from project root runs the headless harness; `test/Makefile` greps stdout for `\bPASS\b` / `\bFAIL\b`. Each `.com` runs under iz-cpm with a 5-second timeout. Story 1.10 adds seven new `parser_*` cases, all pure-state logic.
- The harness picks up `test/cases/*.asm` automatically. No `test/Makefile` edits required.
- `test/inc/test_input_loop_stub.inc` (Story 1.6) provides the local `input_loop:` symbol so tests INCLUDEing `src/statusln.asm` resolve `bdos_error_funnel`'s `JP input_loop`. Story 1.10's tests INCLUDE statusln.asm + dispatch.asm + parser.asm + the input_loop_stub + state.inc — same scaffold as the dispatch tests.

**From Story 1.7:**
- `src/gapbuf.asm` is a prior-art module at the same architectural tier (single-mutator, headless-testable, zero BDOS). Its file structure (header block + `;;` section dividers + per-routine 4-line `In:`/`Out:`/`Trashes:`/`Calls:` contracts + dotted-local labels) is the template for `src/parser.asm`.
- Story 1.7's `gapbuf_load` STUB pattern (returns `status_set_message msg_not_implemented`) is the prior art for Story 1.10's three stubs.

**From Story 1.8:**
- `src/input.asm` (190 lines) is a prior-art module structurally similar to parser.asm — both are stateless w.r.t. their own routine state, both have multiple public entry points each with its own contract block. Mirror input.asm's header-block style for parser.asm.
- The "`vibe.asm` header `Dependencies:` line gets a new entry per story" pattern continues. Story 1.10 adds `src/parser.asm (Story 1.10)`.

**From Story 1.9:**
- `src/dispatch.asm` (483 lines) is the most-recent prior-art module — the parser is the natural successor in the AR25 chain (`init → input → statusln → gapbuf → render → dispatch → parser → motions → ...`). Mirror dispatch.asm's header-block style for parser.asm.
- The `dispatch_normal` table-extension pattern (insert in sorted order, add ASSERT per pair, recompute count via `($ - .entries) / 3`) is established. Story 1.10 follows the same shape for the 16 new entries.
- The "INCLUDE goes in AR25 order, slotting into the next-available position" pattern continues. Story 1.10 inserts parser.asm between dispatch.asm and the input_loop comment block.
- Story 1.9 deferred no items to Story 1.10 (the deferred-work.md last entry is from Story 1.8). No deferral pickup.
- **Story 1.9's Review Findings include a "production-table hit coverage" patch** that exercised Ctrl-L, '/', and 'a' against dispatch_normal in the test file. Story 1.10 doesn't need to extend that test — but it's worth being aware that adding 16 entries to dispatch_normal could *in principle* hide a bug if a previously-passing 'a' subtest became a 'c' or 'd' subtest by coincidence. Verify the `dispatch_mode-transition.asm` tests still pass after the dispatch_normal expansion (they should — the existing entries' positions in the binary search change but the routing is the same).
- **The parser-symbol forward references from dispatch.asm** rely on sjasmplus's two-pass behaviour. Already exercised by Story 1.9 (dispatch_normal references handlers in the same file); Story 1.10 extends the same pattern to cross-file references.

### Git intelligence

Nine commits on `main` after Story 1.0 (most-recent first per `git log`):

- `6084103` — story 1.9: Wrote the key dispatcher: binary-searches a per-mode table to find the handler.
- `5f5577e` — story 1.8: Wrote the input layer; tells Esc from arrows in ~40ms, with putback.
- `11a4560` — story 1.7: Wrote the gap buffer (insert, delete, move, load stub) with headless tests.
- `42af237` — story 1.6: make test builds, runs, and grades every test case off stdout.
- `b7ca9a8` — story 1.4: every BDOS call now goes through a macro that catches errors.
- `a298547` — story 1.3: Laid out the editor's full memory map at fixed addresses, build-time guarded.
- `eac5ba3` — story 1.2: Named every constant the editor needs, in three .inc headers, wired in.
- *(commit reflecting 1.5)* — story 1.5: every status message now goes through one funnel.
- `b561c9e` — story 1.1: Set up the VIBE build: Makefile pins sjasmplus 1.23.0, produces vibe.com.

Conventions visible in the tree (preserve in Story 1.10):
- 4-space indentation, UPPERCASE mnemonics, `;` line / `;;` section comments (AR24).
- AR23 header blocks on every `.asm` and `.inc` file. The new `src/parser.asm` follows the same shape.
- Every public routine and internal helper has the `In:` / `Out:` / `Trashes:` / `Calls:` four-line contract (AR23).
- One story per commit; short imperative subject + colon-separated context. Match the user's plain-English style.

Suggested commit message for Story 1.10 (when the dev finishes): `story 1.10: command parser builds counts, pending operators, and the gg motion-prefix from keystrokes.` Match the user's "tells Esc from arrows" / "Wrote the gap buffer" / "binary-searches a per-mode table" plain-English style.

### Testing requirements

Story 1.10's testing requirements split into two categories:

**Build-time / static (verifiable in this story):**

1. `make` from project root succeeds (AC15).
2. `make clean && make` produces byte-identical `vibe.com` across two consecutive runs (NFR18 / AC15). Capture both SHAs in Debug Log References.
3. `grep -nE 'BIOS_CONOUT' src/parser.asm` returns zero matches (AR13 / AC15).
4. `grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/parser.asm` returns zero matches (AR15 / AC15).
5. `grep -nE 'gapbuf_(insert|delete|move_gap|load|init)' src/parser.asm` returns zero matches (AR14 / AC15).
6. `make -C test test` reports 17 pass / 1 fail (AC12). Capture verbatim in Debug Log References.

**Headless test cases (this story):**

7. `parser_count-accumulator.asm` — single-digit, multi-digit, 3-digit, large-count accumulation (AC2).
8. `parser_leading-zero-is-motion.asm` — '0' with count=0 fires motion-zero stub; count stays 0 (AC3).
9. `parser_zero-after-digit.asm` — '0' with count>0 multiplies count*10; no stub fires (AC4).
10. `parser_doubled-operator-dd.asm` — first 'd' sets pending_operator; second 'd' fires stub + clears state; 'dy' is not doubled (AC5, AC6).
11. `parser_compose-count-op-motion.asm` — '5d<motion>' and '<motion>' both work via parser_dispatch with stub motion handler that captures parser state (AC5, AC9, AC10).
12. `parser_motion-prefix-gg.asm` — first 'g' sets prefix; second 'g' fires stub + clears state; count carries across 'g' and is cleared by gg dispatch (AC7, AC8).
13. `parser_motion-prefix-cleared-on-other-key.asm` — 'g' then digit clears prefix; 'g' then operator clears prefix; 'g' alone leaves prefix set (AC11).

**UAT (deferred to Story 1.12 hardware bring-up):**

14. End-to-end keystroke → dispatch → parser → motion stub on real MicroBeast hardware (Story 1.12 wires the input loop). Pre-1.12, parser is exercised only by the headless tests; the production input_loop body is still Story 1.5's BDOS_EXIT stub.

### Project Structure Notes

After Story 1.10 the source tree is:

```
src/
├── vibe.asm        # Top-level (now INCLUDEs input.asm + statusln.asm + gapbuf.asm + dispatch.asm + parser.asm)
├── input.asm       # Story 1.8 (unchanged)
├── statusln.asm    # Story 1.5 (+ Story 1.7's msg_not_implemented + Story 1.9's mode/unbound msgs) — UNCHANGED in 1.10
├── gapbuf.asm      # Story 1.7 (unchanged)
├── dispatch.asm    # Story 1.9 (+ Story 1.10: 16 new entries in dispatch_normal, 24 ASSERTs total)
└── parser.asm      # Story 1.10 — NEW (parser_handle_* + parser_dispatch + parser_clear + 3 Epic-1 stubs)

inc/
├── equates.inc     # Story 1.2 (unchanged)
├── bios.inc        # Story 1.4 (unchanged)
├── bdos.inc        # Story 1.4 (unchanged — Story 1.10 reads NO BDOS symbols)
├── modes.inc       # Story 1.2 (unchanged — Story 1.10 reads NO mode IDs)
├── vt52.inc        # Story 1.2 (unchanged)
└── state.inc       # Story 1.3 (+ Story 1.8's input_held_*) — UNCHANGED in 1.10

test/
├── README.md
├── Makefile
├── inc/
│   ├── test_prologue.inc
│   ├── test_epilogue.inc
│   └── test_input_loop_stub.inc
├── cases/
│   ├── harness_pass.asm
│   ├── harness_fail.asm
│   ├── gapbuf_delete-at-bof.asm
│   ├── gapbuf_delete-mid.asm
│   ├── gapbuf_insert-empty.asm
│   ├── gapbuf_insert-fills-buffer.asm
│   ├── gapbuf_move-roundtrip.asm
│   ├── gapbuf_random-ops.asm
│   ├── dispatch_binary-search-finds-key.asm
│   ├── dispatch_binary-search-misses.asm
│   ├── dispatch_mode-transition.asm
│   ├── parser_count-accumulator.asm                  # Story 1.10 — NEW
│   ├── parser_leading-zero-is-motion.asm             # Story 1.10 — NEW
│   ├── parser_zero-after-digit.asm                   # Story 1.10 — NEW
│   ├── parser_doubled-operator-dd.asm                # Story 1.10 — NEW
│   ├── parser_compose-count-op-motion.asm            # Story 1.10 — NEW
│   ├── parser_motion-prefix-gg.asm                   # Story 1.10 — NEW
│   └── parser_motion-prefix-cleared-on-other-key.asm # Story 1.10 — NEW
├── fixtures/
│   └── hello.txt
└── smoke/
    ├── bdos_call_smoke.asm
    └── statusln_smoke.asm
```

Architecture's reference layout (architecture.md lines 1278-1339) anticipates exactly this — `src/parser.asm` between `src/dispatch.asm` (Story 1.9) and `src/motions.asm` (Story 2.5+, not yet present). Story 1.11 (render) lands BEFORE Story 1.10 in the AR25 chain (`init → input → statusln → gapbuf → render → dispatch → parser`), but Story 1.10 lands BEFORE Story 1.11 in calendar order — render slots in BEFORE dispatch when 1.11 lands; parser stays where it is.

### References

- Story foundation (As a / I want / So that, BDD ACs): [Source: _bmad-output/planning-artifacts/epics.md] lines 662-720
- Adjacent story (dispatch, Story 1.9 — owns dispatch_normal which Story 1.10 extends): [Source: _bmad-output/planning-artifacts/epics.md] lines 609-660
- Adjacent story (motions, Story 2.5 — first real consumer of parser_dispatch): [Source: _bmad-output/planning-artifacts/epics.md] lines 1046-1097
- MC1 (caller-saved everywhere): [Source: _bmad-output/planning-artifacts/architecture.md] lines 472-476
- MC4 (handler signature: A=key just consumed, accumulator state in fixed addresses): [Source: _bmad-output/planning-artifacts/architecture.md] lines 529-533
- MC7 (static memory map via state.inc): [Source: _bmad-output/planning-artifacts/architecture.md] lines 550-555
- AR12 (single status-message funnel): [Source: _bmad-output/planning-artifacts/epics.md] line 161
- AR13 (single screen-emission path — render.asm only): [Source: _bmad-output/planning-artifacts/epics.md] line 162
- AR14 (single buffer-mutation owner — gapbuf.asm only): [Source: _bmad-output/planning-artifacts/epics.md] line 163
- AR15 (single BDOS gateway — BDOS_CALL macro): [Source: _bmad-output/planning-artifacts/epics.md] line 164
- AR16 (status-message string-table convention): [Source: _bmad-output/planning-artifacts/epics.md] line 165
- AR21 (headless coverage scope — command parser explicitly named): [Source: _bmad-output/planning-artifacts/epics.md] line 173
- AR22 (naming): [Source: _bmad-output/planning-artifacts/epics.md] line 177
- AR23 (file structure and routine contracts): [Source: _bmad-output/planning-artifacts/epics.md] line 178
- AR24 (format conventions): [Source: _bmad-output/planning-artifacts/epics.md] line 179
- AR25 (module include order — `init → input → statusln → gapbuf → render → dispatch → parser → motions → ...`): [Source: _bmad-output/planning-artifacts/epics.md] line 180, [Source: _bmad-output/planning-artifacts/architecture.md] lines 942-951
- FR21 (motion `0` line-start): [Source: _bmad-output/planning-artifacts/epics.md] line ~46 (FR18-22 cursor motions)
- FR22 (motion `gg` buffer-start): [Source: _bmad-output/planning-artifacts/epics.md] line ~47
- FR23 (counted motions): [Source: _bmad-output/planning-artifacts/epics.md] line 48
- FR39 (operator+motion composition): [Source: _bmad-output/planning-artifacts/epics.md] line 80
- FR40 (doubled operators dd/yy): [Source: _bmad-output/planning-artifacts/epics.md] line 81
- NFR2 (sustained typing): [Source: _bmad-output/planning-artifacts/epics.md] line 108
- NFR9 (code-size budget ~3 KB): [Source: _bmad-output/planning-artifacts/epics.md] line 121
- NFR16 (knob centralization): [Source: _bmad-output/planning-artifacts/epics.md] line 134
- NFR17 (mode/operator decoupling): [Source: _bmad-output/planning-artifacts/epics.md] line 135
- Module dependency graph (parser owns count_accumulator/pending_operator/pending_motion_prefix, motions reads): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1404-1432
- Data-flow keystroke lifecycle (step 5 = handler executes — parser handlers fire here): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1466-1502
- FR-to-module mapping (FR23 → parser.asm; FR39-40 → parser.asm): [Source: _bmad-output/planning-artifacts/architecture.md] lines 1521-1524
- inc/state.inc parser-state declarations (count_accumulator, pending_operator, pending_motion_prefix): [Source: inc/state.inc] lines 51, 57, 73-74
- src/dispatch.asm dispatch_normal table (extended in Task 9): [Source: src/dispatch.asm] lines 432-461
- src/dispatch.asm header block style: [Source: src/dispatch.asm] lines 1-87
- src/statusln.asm status_set_message contract + msg_not_implemented: [Source: src/statusln.asm] lines 76-98, 182
- test/cases/dispatch_mode-transition.asm prior-art test shape (multiple subtests + sentinel codes): [Source: test/cases/dispatch_mode-transition.asm] lines 1-233
- test/cases/dispatch_binary-search-finds-key.asm prior-art for synthetic test stubs: [Source: test/cases/dispatch_binary-search-finds-key.asm] lines 117-161
- Story 1.9 dev-notes prior art (file shape + critical-traps style): [Source: _bmad-output/implementation-artifacts/1-9-mode-dispatch-with-sparse-table-binary-search.md] lines 235-270
- Deferred-from-1.3: mode-state protocol partially documented at top of dispatch.asm by 1.9; Story 1.10 documents the parser-state half (the AC11 asymmetric-clear protocol) at top of parser.asm: [Source: _bmad-output/implementation-artifacts/deferred-work.md] line 18

## Dev Agent Record

### Agent Model Used

Claude Opus 4.7 (claude-opus-4-7[1m])

### Debug Log References

**Production build (NFR18 byte-identical determinism):**

```
$ make clean && make && sha256sum vibe.com && make clean && make && sha256sum vibe.com
rm -f vibe.com
rm -rf build
mkdir -p build
sjasmplus --nologo --msg=err --raw=vibe.com --lst=build/vibe.lst --sld=build/vibe.sld src/vibe.asm
2a894870aa5625b4f65771e14e447954c3b73492c50289b677d239f187fcba76  vibe.com
rm -f vibe.com
rm -rf build
mkdir -p build
sjasmplus --nologo --msg=err --raw=vibe.com --lst=build/vibe.lst --sld=build/vibe.sld src/vibe.asm
2a894870aa5625b4f65771e14e447954c3b73492c50289b677d239f187fcba76  vibe.com
```

Two consecutive `make clean && make` runs produced byte-identical `vibe.com` (SHA256
`2a894870aa5625b4f65771e14e447954c3b73492c50289b677d239f187fcba76`). NFR18 holds.

**Headless test results (AC12 — 17 pass / 1 fail):**

```
$ make -C test test
  pass     dispatch_binary-search-finds-key
  pass     dispatch_binary-search-misses
  pass     dispatch_mode-transition
  pass     gapbuf_delete-at-bof
  pass     gapbuf_delete-mid
  pass     gapbuf_insert-empty
  pass     gapbuf_insert-fills-buffer
  pass     gapbuf_move-roundtrip
  pass     gapbuf_random-ops
  fail     harness_fail  (rc=0, output: FAIL E1 C0)
  pass     harness_pass
  pass     parser_compose-count-op-motion
  pass     parser_count-accumulator
  pass     parser_doubled-operator-dd
  pass     parser_leading-zero-is-motion
  pass     parser_motion-prefix-cleared-on-other-key
  pass     parser_motion-prefix-gg
  pass     parser_zero-after-digit

  17 pass, 1 fail
```

10 pre-1.10 cases (gapbuf × 6 + dispatch × 3 + harness_pass) plus 7 new `parser_*`
cases all pass; the single `fail` is the deliberate `harness_fail` from Story 1.6.

**AR-grep enforcement on `src/parser.asm` (AC15):**

```
$ grep -nE 'BIOS_CONOUT' src/parser.asm                 # AR13
(no matches)
$ grep -nE 'CALL[ \t]+0x0005|CALL[ \t]+BDOS_ENTRY' src/parser.asm   # AR15
(no matches)
$ grep -nE 'gapbuf_(insert|delete|move_gap|load|init)' src/parser.asm  # AR14
(no matches)
```

Parser emits no screen bytes (AR13), invokes no BDOS (AR15), mutates no gap-buffer
state (AR14).

### Completion Notes List

- **Stale `XOR C` in the story's recommended `parser_handle_digit` opener corrected
  in implementation.** The Dev Notes' sample sequence began `XOR C` / `LD C, A` —
  the first instruction trashes A (= the just-arrived digit) by XORing it with the
  uninitialised C register, then the second stores the garbage into C. The intended
  shape (save A → C, then zero A for the pending_motion_prefix clear) reads:
  `LD C, A` / `XOR A` / `LD (pending_motion_prefix), A`. Implemented that way at
  `src/parser.asm:200-204`; behaviour matches AC2/AC3/AC11.
- **Single up-front load of count_accumulator in parser_handle_digit.** The story's
  sample loaded HL twice (once for the leading-zero check on the '0' arm, once
  again inside `.accumulate`). One load before the branch covers both arms with
  three fewer bytes and one less memory cycle on the hot path; the leading-zero
  arm needs HL only for the `OR H/L` test, the accumulate arm needs it as the
  multiplicand. `src/parser.asm:207-237`.
- **All three parser-state writers use the asymmetric AC11 clear-on-entry
  protocol.** `parser_handle_digit` (`src/parser.asm:200-205`) and
  `parser_handle_operator` (`src/parser.asm:268-274`) zero `pending_motion_prefix`
  on entry. `parser_handle_motion_prefix` (`src/parser.asm:309-322`) deliberately
  does NOT — the doubled-prefix branch needs the prior value to detect 'gg'. The
  asymmetry is called out in the module header (lines 38-54) and at each routine's
  contract block (line 167 for digit, line 248 for operator, line 295 for prefix).
- **parser_dispatch uses the standard `CALL .invoke / JP (HL)` trampoline.**
  `src/parser.asm:354-358`. CALL pushes a return into parser_dispatch right before
  the tail-JP parser_clear; .invoke's JP (HL) (not JP HL — Z80 mnemonic uses
  parens but the operand is HL itself, not memory[HL]) transfers to the motion
  handler. Motion's RET pops back into parser_dispatch where the tail-JP both
  zeroes state and returns to the caller. 4 bytes of trampoline code.
- **The three Epic-1 stubs all share the `LD HL, msg_not_implemented / XOR A /
  CALL status_set_message` opener.** parser_motion_zero_stub ends in RET (no
  parser_clear — leading-'0' fires with count=0 by precondition, pending_operator
  and pending_motion_prefix may legitimately persist per the `d0` "delete to line
  start" compose). parser_doubled_operator_stub and parser_gg_motion_stub tail-JP
  to parser_clear so the entire pending-state is consumed. `src/parser.asm:373-410`.
- **dispatch_normal grew from 9 to 25 entries; from 29 to 77 bytes.** Inserted 16
  new (key, handler) entries in ASCII-byte ascending order: '0'..'9' →
  parser_handle_digit, '<'/'>'/'c'/'d'/'y' → parser_handle_operator, 'g' →
  parser_handle_motion_prefix. Three prior ASSERTs (`':' > '/'`, `'O' > ':'`,
  `'i' > 'a'`) replaced with their post-insertion equivalents (`':' > '9'`,
  `'O' > '>'`, `'i' > 'g'`); 16 new ASSERTs added — 24 total. `src/dispatch.asm:432-509`.
  `DISPATCH_NORMAL_COUNT` recomputes positionally from `($ - .entries) / 3`.
- **Forward references from dispatch.asm to parser.asm symbols resolve via
  sjasmplus's two-pass assembly.** `src/vibe.asm:67-83` INCLUDEs dispatch.asm
  before parser.asm per AR25; first pass tolerates the three undefined parser
  entries, second pass resolves them. The clean build (above) confirms.
- **No new state.inc fields, equates, message strings, or mode IDs.** All
  parser state was declared in `inc/state.inc` by Story 1.3; the stubs reuse
  `msg_not_implemented` added by Story 1.7 in `src/statusln.asm`. Story 1.10
  is a pure code-addition story: `src/parser.asm` is new (~280 lines of code +
  contracts), `src/dispatch.asm` and `src/vibe.asm` get small edits; no other
  files modified.
- **Code-size estimate at the low end of the NFR9 envelope.** Rough breakdown
  from the .lst (not captured verbatim — sjasmplus emits per-line addresses):
  parser_clear ~12 bytes, parser_handle_digit ~50 bytes, parser_handle_operator
  ~25 bytes, parser_handle_motion_prefix ~20 bytes, parser_dispatch ~7 bytes,
  three stubs ~30 bytes total ≈ ~144 bytes. dispatch.asm grew by 48 bytes of
  table entries (16 × 3). Total Story 1.10 byte cost ≈ 200 bytes — well inside
  the ~3 KB code envelope (NFR9).

### File List

**Created (8 files):**
- `src/parser.asm` (new — primary deliverable)
- `test/cases/parser_count-accumulator.asm`
- `test/cases/parser_leading-zero-is-motion.asm`
- `test/cases/parser_zero-after-digit.asm`
- `test/cases/parser_doubled-operator-dd.asm`
- `test/cases/parser_compose-count-op-motion.asm`
- `test/cases/parser_motion-prefix-gg.asm`
- `test/cases/parser_motion-prefix-cleared-on-other-key.asm`

**Modified (2 files):**
- `src/dispatch.asm` — header `Dependencies:` line extended with `src/parser.asm
  (Story 1.10)`; `dispatch_normal` grew from 9 to 25 entries (16 new) with 24
  consecutive-pair ASSERTs (3 replaced + 16 new + 5 unchanged).
- `src/vibe.asm` — header `Dependencies:` line gained `src/parser.asm (Story
  1.10)`; new `INCLUDE "parser.asm"` block inserted between the dispatch
  INCLUDE and the input-loop abort-target comment, per AR25.

### Change Log

- 2026-05-10 — Story 1.10 implementation complete. Added `src/parser.asm` (parser
  state machine — count accumulator, pending operator, motion prefix, dispatch
  helper, and three Epic-1 stubs). Extended `dispatch_normal` with 16 new entries
  for digits, operators, and the 'g' prefix. INCLUDEd parser.asm into `src/vibe.asm`
  per AR25. Added seven `test/cases/parser_*.asm` headless tests. Build is byte-
  identical across two clean rebuilds; 17 pass / 1 fail (the deliberate
  `harness_fail` is the only failure); AR13/AR14/AR15 greps on parser.asm all
  return zero matches.

### Review Findings

Code review 2026-05-10 (three parallel layers: Blind Hunter, Edge Case Hunter, Acceptance Auditor). No critical or serious defects — all ACs implemented; build is byte-identical; AR-greps clean. Findings are doc/comment polish and test-coverage strengthening.

**Patches (9 applied + 1 false positive):**

- [x] [Review][Patch] `parser_clear` comment misdescribes its own code [src/parser.asm:163-165] — fixed: reworded to describe the actual one-XOR-A + two-`LD (nn), A` shape.
- [x] [Review][Patch] Leading-zero comment overstates the guard rationale [src/parser.asm:230-232] — fixed: reworded to "16-bit equality test; low-byte-only test would mis-classify counts like 256 as a leading '0'".
- [x] [Review][Patch] `parser_motion_zero_stub` per-routine block omits the tail-unwind note [src/parser.asm:445-453] — fixed: added explicit note that the stub's RET returns to parser_handle_digit's caller (tail-call from JP), plus a note on why this stub doesn't tail-JP to parser_clear.
- [~] [Review][Patch] `vibe.asm` INCLUDE block comment has stray "in" [src/vibe.asm:78] — **false positive on re-read.** "slot in AFTER parser.asm here" is correct English ("slot in" is the phrasal verb); the dev cleaned the spec's clear typo into a grammatical sentence. No change made.
- [x] [Review][Patch] `parser_doubled-operator-dd.asm` Subtest 3 (yy) is weaker than its sentinel description — fixed: added status_dirty != 0 (sentinel 0xEB) and pending_motion_prefix == 0 (sentinel 0xEC) checks to the yy variant.
- [x] [Review][Patch] [AC10] `parser_compose-count-op-motion.asm` Subtest 1 omits the post-dispatch `pending_motion_prefix == 0` check — fixed: added (sentinel 0xE8).
- [x] [Review][Patch] [AC11] `parser_motion-prefix-cleared-on-other-key.asm` Subtest 1 omits the "pending_operator unchanged" check — fixed: added (sentinel 0xE6).
- [x] [Review][Patch] [AC11] Add subtest for the 'g' then '0' (leading-zero) prefix-clear path — fixed: added Subtest 4 (sentinels 0xE7 / 0xE8 / 0xE9) covering prefix-clear, stub-fired, and count-unchanged on the leading-zero arm of `parser_handle_digit`.
- [x] [Review][Patch] Add overflow-wrap regression test — fixed: added Subtest 5 to `parser_count-accumulator.asm` (sentinel 0xE5) pre-loading count=6553 and verifying `6553*10+9 ≡ 3 mod 65536`.
- [x] [Review][Patch] Add 'dyy' subtest (last-operator-wins sharp edge) — fixed: added Subtest 5 to `parser_doubled-operator-dd.asm` (sentinels 0xED / 0xEE) verifying the second 'y' after 'd' 'y' fires the yy stub.

**Deferred (5) — real, but out of scope for Story 1.10:**

- [x] [Review][Defer] Mode transitions don't clear parser state — deferred, parser state is global; `enter_insert_mode` / `enter_visual_mode` / `enter_command_mode` / `enter_normal_mode` (in src/dispatch.asm) leave `count_accumulator`, `pending_operator`, and `pending_motion_prefix` untouched. `5v Esc d` composes count=5 with new operator d, against vi-like expectations. Cross-module concern; Story 1.12 or an explicit mode-transition story owns the policy. (Source: Edge Case Hunter.)
- [x] [Review][Defer] Unbound key in NORMAL doesn't clear parser state — deferred, `5gx` leaves count=5 and prefix='g' alive; the next 'g' fires gg-stub spuriously. dispatch.asm's `unbound_normal` would need to call `parser_clear` (or the policy could deliberately preserve state). Cross-module; defer to the mode-transition policy story. (Source: Edge Case Hunter.)
- [x] [Review][Defer] Stubs tail-JP `parser_clear` before count/operator can be captured by future real handlers — deferred, `parser_doubled_operator_stub` and `parser_gg_motion_stub` clear unconditionally. When Story 2.6 (gg) and Story 2.10 (dd/yy/cc/<<<>>) land real handlers, they must read `count_accumulator` and `pending_operator` BEFORE replacing the tail-JP. Add a `TODO(Story 2.x)` contract comment in the stubs when those stories begin. (Source: Edge Case Hunter.)
- [x] [Review][Defer] `parser_dispatch` IX safety — deferred, no production caller of `parser_dispatch` exists yet (only tests). If a future motion handler trashes IX and is invoked from within `dispatch_key`'s frame (which uses IX as the entries base), `dispatch_key` state corrupts. Document the IX constraint in motion-handler contracts when Story 2.5+ lands or add a `PUSH IX / POP IX` to `parser_dispatch`. (Source: Edge Case Hunter.)
- [x] [Review][Defer] `dispatch_visual` doesn't bind digits/operators/'g' — deferred, the parser-state fields are global but VISUAL mode currently routes everything except Esc to `unbound_visual`. Count entered in NORMAL persists into VISUAL and back. Story 3.3 (visual character mode) and FR33-FR38 own this; the choice of "VISUAL clears parser state on entry" vs "VISUAL composes with the count" is an explicit design decision pending. (Source: Edge Case Hunter.)

**Dismissed (~13)** — over-declared `Trashes:` lines (safer under MC1 caller-saved discipline), test scaffolding stylistic nitpicks, future-extensibility notes, intentional behaviors (d0 carrying operator, dgg keeping operator, HL=0 as caller responsibility).

Layers: Blind Hunter (`bmad-review-adversarial-general`), Edge Case Hunter (`bmad-review-edge-case-hunter`), Acceptance Auditor (custom prompt). All three returned findings; no failed layers.
