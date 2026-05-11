; ============================================================
; Module: parser.asm
; Purpose: Command-parser state machine (MC4). Owns the count
;          accumulator, the pending-operator byte, and the
;          pending-motion-prefix byte — the three accumulator
;          fields that turn a stream of normal-mode keystrokes
;          into a (count, operator, motion) tuple. Provides:
;
;            parser_handle_digit          ; '0'..'9' accumulator
;                                          ; (FR23 counts; FR21
;                                          ; leading-zero is motion-0)
;            parser_handle_operator       ; 'd'/'y'/'c'/'>'/'<'
;                                          ; (FR39 operator+motion;
;                                          ; FR40 doubled-op dd/yy)
;            parser_handle_motion_prefix  ; 'g' (V3 / FR22 gg-motion)
;            parser_dispatch              ; invoke motion handler
;                                          ; (state visible to handler)
;                                          ; then parser_clear
;            parser_clear                 ; reset all three fields
;
;          Plus three Epic-1 placeholder stubs that surface
;          msg_not_implemented while the real motion / doubled-op
;          handlers wait for Epic 2 / 3 stories:
;
;            parser_motion_zero_stub      ; '0' as motion (FR21; Story 2.6)
;            parser_doubled_operator_stub ; dd/yy/cc/<<<>> (FR40; Story 2.10)
;            parser_gg_motion_stub        ; gg motion (FR22; Story 2.6)
;
;          Pure metadata module — no buffer mutation (AR14),
;          no screen emission (AR13), no raw BDOS (AR15). The
;          stubs surface user-visible feedback through the AR12
;          status-message funnel only.
;
;          Asymmetric-clear protocol for pending_motion_prefix
;          (the parser-state half of the Story 1.3 deferral on
;          state-coupling documentation):
;            - parser_handle_digit and parser_handle_operator
;              CLEAR pending_motion_prefix on entry, because a
;              non-prefix-aware key has arrived and any stale
;              'g' (e.g. from `5gg` mis-typed as `5g5`) must be
;              dropped.
;            - parser_handle_motion_prefix does NOT clear
;              pending_motion_prefix on entry, because the
;              doubled-prefix branch needs to test the prior
;              value to detect 'gg'.
;          Documented here and at each routine's contract block
;          so a future "consistency cleanup" cannot silently
;          break gg-detection.
;
; Public:
;   parser_handle_digit
;   parser_handle_operator
;   parser_handle_motion_prefix
;   parser_dispatch
;   parser_clear
;   parser_motion_zero_stub
;   parser_doubled_operator_stub
;   parser_gg_motion_stub
;
; State owned (read/write):
;   count_accumulator      ; 16-bit; writers = parser_handle_digit,
;                            parser_clear
;   pending_operator       ; 1 byte; writers = parser_handle_operator,
;                            parser_clear
;   pending_motion_prefix  ; 1 byte; writers = parser_handle_motion_prefix,
;                            parser_clear, plus the AC11 clear-on-entry
;                            path inside parser_handle_digit and
;                            parser_handle_operator
;
; Register conventions (across public entry points):
;   parser_handle_digit:          In:  A = digit char ('0'..'9')
;                                 Out: count_accumulator advanced
;                                      OR transferred control to
;                                      parser_motion_zero_stub on
;                                      leading-'0' with count == 0
;                                 Trashes: A, BC, DE, HL, F
;                                 Calls:   parser_motion_zero_stub
;                                          (only on leading-zero path)
;
;   parser_handle_operator:       In:  A = operator byte
;                                      ('d'/'y'/'c'/'>'/'<')
;                                 Out: pending_operator set (first)
;                                      OR transferred control to
;                                      parser_doubled_operator_stub
;                                      (doubled — stub tail-calls
;                                      parser_clear)
;                                 Trashes: A, BC, DE, HL, F
;                                 Calls:   parser_doubled_operator_stub
;
;   parser_handle_motion_prefix:  In:  A = prefix byte ('g' for
;                                      Epic 1 / 2)
;                                 Out: pending_motion_prefix set
;                                      (first) OR transferred control
;                                      to parser_gg_motion_stub
;                                      (doubled — stub tail-calls
;                                      parser_clear)
;                                 Trashes: A, BC, DE, HL, F
;                                 Calls:   parser_gg_motion_stub
;
;   parser_dispatch:              In:  HL = motion handler address
;                                 Out: motion handler invoked once
;                                      with parser state visible
;                                      (count_accumulator etc. readable
;                                      via state.inc symbols); after
;                                      motion's RET, parser_clear is
;                                      tail-called so all three fields
;                                      are zeroed on return.
;                                 Trashes: A, BC, DE, HL, F (motion
;                                      handler may trash more; caller
;                                      saved per MC1)
;                                 Calls:   motion handler (via JP (HL));
;                                          parser_clear (tail-call)
;
;   parser_clear:                 In:  (none)
;                                 Out: count_accumulator = 0,
;                                      pending_operator = 0,
;                                      pending_motion_prefix = 0;
;                                      no other state touched.
;                                 Trashes: A, HL, F
;                                 Calls:   (none)
;
;   Stub handlers (parser_motion_zero_stub,
;   parser_doubled_operator_stub, parser_gg_motion_stub):
;                                 In:  (none — A and HL freely
;                                      clobbered)
;                                 Out: status_buffer = "not yet
;                                      implemented"; status_dirty
;                                      set. parser_motion_zero_stub
;                                      does NOT clear parser state
;                                      (leading-'0' has nothing to
;                                      clear — see Dev Notes); the
;                                      other two tail-JP to
;                                      parser_clear (doubled-op and
;                                      gg consume their entire
;                                      pending-state).
;                                 Trashes: A, BC, DE, HL, F
;                                 Calls:   status_set_message;
;                                          parser_clear (tail-call
;                                          from doubled-op and gg
;                                          stubs only)
;
; Dependencies:
;   inc/state.inc    (count_accumulator, pending_operator,
;                     pending_motion_prefix)
;   src/statusln.asm (status_set_message + msg_not_implemented —
;                     for the three Epic-1 stubs)
; ============================================================

;; ============================================================
;; --- parser_clear ---
;; ============================================================

; ----------------------------------------------------------------
; parser_clear
; Zero all three parser-state fields. Silent reset path — no
; status-line side effect, no other state touched. Called by:
;   - parser_dispatch (after motion handler returns)
;   - parser_doubled_operator_stub (tail-JP)
;   - parser_gg_motion_stub (tail-JP)
;   - future Esc-from-NORMAL handler (Story 2.x) on count/op abort
;
; 4 bytes of state total: count_accumulator (2) + pending_operator
; (1) + pending_motion_prefix (1). The `LD HL, 0 : LD (nn), HL`
; idiom is the smallest 16-bit zero form on Z80 (6 bytes); a single
; `XOR A` followed by two `LD (nn), A` stores handles the two
; single-byte fields (saving the byte a redundant second `XOR A`
; would cost).
;
; In:      (none)
; Out:     count_accumulator = 0, pending_operator = 0,
;          pending_motion_prefix = 0
; Trashes: A, HL, F
; Calls:   (none)
; ----------------------------------------------------------------
parser_clear:
    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      HL, 0
    LD      (count_accumulator), HL
    RET


;; ============================================================
;; --- parser_handle_digit (FR21, FR23) ---
;; ============================================================

; ----------------------------------------------------------------
; parser_handle_digit
; MC4 handler for ASCII digits '0'..'9'. Two cases:
;
;   - Leading '0' (count_accumulator == 0): transfer control to
;     parser_motion_zero_stub. In vi, '0' with no pending count
;     is the motion to line-start (FR21). Epic 1 surfaces the
;     stub message; Story 2.6 lands the real motion.
;
;   - Otherwise (non-zero digit, OR '0' arriving after a prior
;     digit): accumulate into count_accumulator as
;     count_accumulator * 10 + (A - '0'). The leading-'0' branch
;     and the '0'-after-digit branch are disambiguated by the
;     CURRENT value of count_accumulator — see AC3 vs AC4.
;
; AC11 clear-on-entry: pending_motion_prefix is cleared to 0
; before any branch decision. A digit arriving means the user
; is starting (or extending) a count, not composing with a
; previously-pressed 'g'. The Dev Notes asymmetry note explains
; why parser_handle_motion_prefix is the one routine that does
; NOT clear.
;
; Overflow: count * 10 + digit wraps at 65536 silently. Vi
; tradition is no clamp (no real-world count reaches 6553).
;
; In:      A = digit char ('0'..'9' = 0x30..0x39)
; Out:     count_accumulator advanced (HL := HL * 10 + digit);
;          pending_motion_prefix = 0; OR control transferred to
;          parser_motion_zero_stub on leading-'0' with count == 0.
; Trashes: A, BC, DE, HL, F
; Calls:   parser_motion_zero_stub (only on leading-zero arm)
; ----------------------------------------------------------------
parser_handle_digit:
    LD      C, A                    ; C = digit char (saved across
                                    ; the prefix-clear and multiply)
    ;; AC11: clear pending_motion_prefix on entry.
    XOR     A
    LD      (pending_motion_prefix), A

    ;; Load count_accumulator once — used by both the leading-zero
    ;; check (AC3 / AC4 disambiguation) and the multiply.
    LD      HL, (count_accumulator)

    ;; AC3 vs AC4: if digit == '0', the next test is "is count 0?"
    ;; — semantically a 16-bit equality test. `LD A, H : OR L` ORs
    ;; both bytes so Z is set iff the full count is zero; a low-byte-
    ;; only test would mis-classify counts whose low byte happens to
    ;; be zero (e.g. 256) as a leading '0'.
    LD      A, C
    CP      '0'
    JR      NZ, .accumulate
    LD      A, H
    OR      L                       ; Z iff HL == 0 (both bytes)
    JR      NZ, .accumulate

    ;; Leading '0' with no count: motion-zero stub (FR21 / AC3).
    ;; count remains 0; pending_motion_prefix already cleared above;
    ;; pending_operator preserved (vi: 'd0' = delete to line-start).
    JP      parser_motion_zero_stub

.accumulate:
    ;; HL = count_accumulator (loaded above). Compute HL * 10
    ;; via ((count*4) + count) * 2 = count*10:
    ;;   LD DE, count       ; DE = count       (1 LD pair, 2 bytes)
    ;;   ADD HL, HL         ; HL = count*2     (1 byte)
    ;;   ADD HL, HL         ; HL = count*4     (1 byte)
    ;;   ADD HL, DE         ; HL = count*5     (1 byte)
    ;;   ADD HL, HL         ; HL = count*10    (1 byte)
    ;; Five instructions, six bytes of code, ~50 T-states.
    LD      D, H
    LD      E, L                    ; DE = count
    ADD     HL, HL                  ; HL = count * 2
    ADD     HL, HL                  ; HL = count * 4
    ADD     HL, DE                  ; HL = count * 5
    ADD     HL, HL                  ; HL = count * 10

    ;; HL += (digit - '0'), zero-extended to 16 bits.
    LD      A, C
    SUB     '0'                     ; A = 0..9
    LD      E, A
    LD      D, 0                    ; DE = digit
    ADD     HL, DE                  ; HL = count*10 + digit
    LD      (count_accumulator), HL
    RET


;; ============================================================
;; --- parser_handle_operator (FR39, FR40) ---
;; ============================================================

; ----------------------------------------------------------------
; parser_handle_operator
; MC4 handler for operator keys 'd' / 'y' / 'c' / '>' / '<'. Two
; cases:
;
;   - First operator (pending_operator differs from A): store A
;     in pending_operator. count_accumulator preserved (the count
;     survives across the operator press — '5dw' must reach the
;     motion handler with count=5).
;
;   - Doubled operator (pending_operator == A): transfer control
;     to parser_doubled_operator_stub (Epic 1 placeholder for
;     dd / yy / cc / >> / <<; Story 2.10 lands real). The stub
;     tail-JPs to parser_clear so all parser state is zeroed on
;     return.
;
; AC11 clear-on-entry: pending_motion_prefix is cleared to 0
; before the doubled-operator test. An operator arriving with a
; stale 'g' (e.g. user typed `gd` instead of `dgg`) drops the 'g'
; — `dgg` is NOT composed by the parser; only the operator+motion
; path is.
;
; Stale-pending-operator (e.g. 'd' then 'y'): last-operator-wins.
; The mismatch path stores the new operator in pending_operator,
; replacing the prior one. AC5/AC6 do not pin this case; this
; choice matches modern vim's operator-conflict behaviour.
;
; In:      A = operator byte ('d'/'y'/'c'/'>'/'<')
; Out:     pending_operator = A on the first-operator path;
;          control transferred to parser_doubled_operator_stub
;          on the doubled-operator path. pending_motion_prefix
;          = 0 in both paths.
; Trashes: A, BC, DE, HL, F (doubled-op path inherits
;          status_set_message and parser_clear clobbers)
; Calls:   parser_doubled_operator_stub (only on doubled path)
; ----------------------------------------------------------------
parser_handle_operator:
    LD      C, A                    ; C = operator (saved across
                                    ; the prefix-clear and the
                                    ; compare against pending_operator)
    ;; AC11: clear pending_motion_prefix on entry.
    XOR     A
    LD      (pending_motion_prefix), A

    ;; AC6: doubled-operator detection.
    LD      A, (pending_operator)
    CP      C
    JR      NZ, .first_operator
    ;; Doubled: tail-JP to stub (stub itself tail-JPs to
    ;; parser_clear, so the stub's return target is this
    ;; routine's caller).
    JP      parser_doubled_operator_stub

.first_operator:
    ;; AC5: store new operator. count_accumulator unchanged.
    LD      A, C
    LD      (pending_operator), A
    RET


;; ============================================================
;; --- parser_handle_motion_prefix (FR22) ---
;; ============================================================

; ----------------------------------------------------------------
; parser_handle_motion_prefix
; MC4 handler for motion-prefix keys (currently 'g' for Epic 1
; and Epic 2; future-extensible if a second prefix lands).
;
;   - First prefix (pending_motion_prefix != A): store A in
;     pending_motion_prefix. count_accumulator and
;     pending_operator preserved (a prefix can carry across
;     counts and operators — both `5gg` and `dgg` are valid
;     vi composes the parser must not mangle).
;
;   - Doubled prefix (pending_motion_prefix == A): transfer
;     control to parser_gg_motion_stub (Epic 1 placeholder for
;     gg buffer-start motion; Story 2.6 lands real). The stub
;     tail-JPs to parser_clear so all parser state is zeroed
;     on return.
;
; ASYMMETRY (critical — see module header): this routine does
; NOT clear pending_motion_prefix on entry. The doubled-prefix
; branch must test the prior value, so a clear-on-entry would
; make gg detection impossible. A future "consistency cleanup"
; that aligns this with parser_handle_digit / parser_handle_operator
; would silently break gg.
;
; In:      A = prefix byte ('g' = 0x67 for Epic 1 / 2)
; Out:     pending_motion_prefix = A on the first-prefix path;
;          control transferred to parser_gg_motion_stub on the
;          doubled-prefix path.
; Trashes: A, BC, DE, HL, F (doubled path inherits
;          status_set_message and parser_clear clobbers)
; Calls:   parser_gg_motion_stub (only on doubled path)
; ----------------------------------------------------------------
parser_handle_motion_prefix:
    LD      C, A                    ; C = prefix (saved across compare)
    ;; AC8: doubled-prefix detection. Note: NO clear-on-entry —
    ;; see the asymmetry note above.
    LD      A, (pending_motion_prefix)
    CP      C
    JR      NZ, .first_prefix
    ;; Doubled: tail-JP to gg stub (stub tail-JPs to parser_clear).
    JP      parser_gg_motion_stub

.first_prefix:
    ;; AC7: store prefix. count_accumulator and pending_operator
    ;; unchanged so '5gg' / 'dgg' compose correctly.
    LD      A, C
    LD      (pending_motion_prefix), A
    RET


;; ============================================================
;; --- parser_dispatch (FR39 operator+motion compose) ---
;; ============================================================

; ----------------------------------------------------------------
; parser_dispatch
; Invoke a motion handler with the full parser-state context
; visible (the handler reads count_accumulator etc. via state.inc
; symbols), then clear all three parser-state fields so the next
; compose starts fresh.
;
; Stack discipline — the standard Z80 "CALL .invoke / JP (HL)"
; trampoline:
;     CALL .invoke          ; pushes return-here address
; .invoke:
;     JP (HL)               ; transfer to motion handler
; The motion handler RETs, popping back into parser_dispatch
; immediately after the CALL, where the tail-JP parser_clear
; both zeroes state AND returns to parser_dispatch's caller.
;
; The motion handler MUST be RET-terminating (MC1 / MC4). An
; extra RET would unwind into the saved stack frame; a missing
; RET would hang the editor. Parser doesn't enforce this — it
; depends on it.
;
; In:      HL = motion handler address
; Out:     motion handler called once; then parser_clear runs
;          (count_accumulator / pending_operator /
;          pending_motion_prefix all = 0)
; Trashes: A, BC, DE, HL, F (motion handler may trash more —
;          caller-saved per MC1)
; Calls:   motion handler (via JP (HL)); parser_clear (tail-JP)
; ----------------------------------------------------------------
parser_dispatch:
    CALL    .invoke
    JP      parser_clear

.invoke:
    JP      (HL)                    ; Z80 footgun: this JPs to the
                                    ; address IN HL, not at memory[HL].


;; ============================================================
;; --- Epic-1 stub handlers ---
;; ============================================================
; All three surface msg_not_implemented via the AR12 status
; funnel. The two "command-complete" stubs (doubled-op and gg)
; tail-JP to parser_clear so the entire pending-state is consumed.
; The motion-zero stub does NOT clear: leading-'0' fires with
; count_accumulator already 0 by precondition; pending_operator
; and pending_motion_prefix may legitimately persist (vi: 'd0'
; is "delete to line-start" — operator + motion compose, the
; operator carries to the motion handler that the real Story 2.6
; motion-0 will become). For Epic 1 the stub message is the only
; observable effect.

; ----------------------------------------------------------------
; parser_motion_zero_stub
; Epic 1 placeholder for the '0' line-start motion (FR21).
; Story 2.6 replaces with the real motion handler.
;
; Reached via `JP parser_motion_zero_stub` from parser_handle_digit's
; leading-zero arm (a tail-call), so this stub's RET returns to
; *parser_handle_digit's caller*, not to parser_handle_digit. A
; future maintainer wrapping the stub in `CALL` would unbalance the
; stack — keep the `JP` at the caller and the bare `RET` here in
; sync.
;
; Unlike the doubled-op and gg stubs, this one does NOT tail-JP to
; parser_clear: leading-'0' fires with count==0 by precondition, and
; pending_operator / pending_motion_prefix may legitimately persist
; (vi 'd0' = delete-to-line-start).
;
; In:      (none — caller passed A = '0' but this stub ignores it)
; Out:     status line = "not yet implemented"
; Trashes: A, BC, DE, HL, F
; Calls:   status_set_message
; ----------------------------------------------------------------
parser_motion_zero_stub:
    LD      HL, msg_not_implemented
    XOR     A
    CALL    status_set_message
    RET

; ----------------------------------------------------------------
; parser_doubled_operator_stub
; Epic 1 placeholder for doubled-operator commands dd / yy / cc /
; >> / << (FR40). Story 2.10 replaces with the real handler.
; Tail-JPs to parser_clear so the doubled-op dispatch is atomic
; from the caller's perspective (status set + state cleared).
;
; In:      (none)
; Out:     status line = "not yet implemented";
;          count_accumulator / pending_operator /
;          pending_motion_prefix all = 0 (via parser_clear)
; Trashes: A, BC, DE, HL, F
; Calls:   status_set_message; parser_clear (tail-JP)
; ----------------------------------------------------------------
parser_doubled_operator_stub:
    LD      HL, msg_not_implemented
    XOR     A
    CALL    status_set_message
    JP      parser_clear

; ----------------------------------------------------------------
; parser_gg_motion_stub
; Epic 1 placeholder for the gg buffer-start motion (FR22).
; Story 2.6 replaces with the real motion. Tail-JPs to
; parser_clear (same atomic-dispatch shape as
; parser_doubled_operator_stub).
;
; In:      (none)
; Out:     status line = "not yet implemented";
;          count_accumulator / pending_operator /
;          pending_motion_prefix all = 0 (via parser_clear)
; Trashes: A, BC, DE, HL, F
; Calls:   status_set_message; parser_clear (tail-JP)
; ----------------------------------------------------------------
parser_gg_motion_stub:
    LD      HL, msg_not_implemented
    XOR     A
    CALL    status_set_message
    JP      parser_clear
