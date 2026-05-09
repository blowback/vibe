; ============================================================
; Module: test/smoke/statusln_smoke.asm
; Purpose: One-off smoke test for statusln.asm (Story 1.5 AC4).
;          Exercises every public entry point in the module:
;            - status_set_message (short message + 80-byte
;              truncation path)
;            - status_render (dirty-clear stub)
;            - bdos_error_funnel (writes msg_bdos_error then
;              JPs to input_loop)
;          Inspects status_buffer + status_dirty post-call;
;          writes a per-result sentinel byte at 0xCFFE (TH1
;          pattern); exits via BDOS_EXIT.
;
;          NOT part of the Story 1.6 harness. test/cases/ is
;          owned by Story 1.6 and may relocate or replace this
;          artifact.
;
; Sentinel codes at 0xCFFE:
;   0xAA — pre-run "never ran" sentinel
;   0x01 — pass (all phases — final state set by input_loop
;           after deliberate funnel test verifies the buffer)
;   0xE1 — status_dirty == 0 after short status_set_message
;   0xE2 — status_buffer[0] != 'h'
;   0xE3 — status_buffer[17] != ' '
;   0xE4 — status_buffer[79] != ' ' (short-msg pad tail)
;   0xE5 — input_loop entered without 0x01 pre-flag
;          (regression: unintended funnel entry mid-test)
;   0xE6 — status_dirty != 0 after status_render
;   0xE7 — status_dirty == 0 after 80-byte truncation call
;   0xE8 — status_buffer[0] != '0' (truncation: first byte)
;   0xE9 — status_buffer[79] != 'F' (truncation: would be ' '
;           if a buggy pad ran instead of clean truncation)
;   0xEA — status_buffer[0] != 'b' after funnel
;   0xEB — status_buffer[9] != 'r' after funnel
;          ("bdos error" — last char of payload)
;   0xEC — status_buffer[10] != ' ' after funnel
;          (funnel did not pad after msg_bdos_error)
; ============================================================
    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"

    ORG 0x0100

    ;; Pre-write a "never ran" sentinel so post-run inspection
    ;; can distinguish "smoke entered" from "memory was already
    ;; the pass-code from a prior run".
    ;; 0xCFFE is TPA scratch — sits above yank_end (~0x90xx with
    ;; the current static map) and below CCP at 0xD800; safe to
    ;; clobber for harness sentinels (TH1 convention).
    LD      A, 0xAA
    LD      (0xCFFE), A

    ;; ----- Phase 1: short-message status_set_message -----
    LD      HL, sample_msg
    XOR     A                       ; non-error-code arg
    CALL    status_set_message

    ;; Check 1: status_dirty must be nonzero.
    LD      A, (status_dirty)
    OR      A
    JR      Z, .fail_dirty

    ;; Check 2: status_buffer[0] must be 'h' (first byte of
    ;; "hello status line").
    LD      A, (status_buffer)
    CP      'h'
    JR      NZ, .fail_first

    ;; Check 3: status_buffer[17] must be 0x20 (first byte of
    ;; the pad — proves the pad loop ran).
    LD      A, (status_buffer + 17)
    CP      ' '
    JR      NZ, .fail_pad_short

    ;; Check 4: status_buffer[STATUS_LINE_WIDTH - 1] must be
    ;; 0x20 (last byte — proves the pad reached the end).
    LD      A, (status_buffer + STATUS_LINE_WIDTH - 1)
    CP      ' '
    JR      NZ, .fail_pad_tail

    ;; ----- Phase 2: status_render dirty-clear stub -----
    ;; Set dirty to a known nonzero, call render, verify it
    ;; was cleared. (Phase 1 already left dirty = 1, but we
    ;; force it here for clarity.)
    LD      A, 1
    LD      (status_dirty), A
    CALL    status_render
    LD      A, (status_dirty)
    OR      A
    JR      NZ, .fail_render

    ;; ----- Phase 3: 80-byte truncation path -----
    ;; long_msg is 80 non-null bytes "0123456789ABCDEF" × 5,
    ;; null-terminated at byte 80. The copy loop must:
    ;;   - copy exactly 80 bytes (status_buffer[0]='0',
    ;;     status_buffer[79]='F'),
    ;;   - NOT pad (status_buffer[79] would be ' ' if the
    ;;     null-then-pad branch ran),
    ;;   - re-set status_dirty (cleared by Phase 2).
    LD      HL, long_msg
    XOR     A
    CALL    status_set_message

    LD      A, (status_dirty)
    OR      A
    JR      Z, .fail_trunc_dirty

    LD      A, (status_buffer)
    CP      '0'
    JR      NZ, .fail_trunc_first

    LD      A, (status_buffer + STATUS_LINE_WIDTH - 1)
    CP      'F'
    JR      NZ, .fail_trunc_last

    ;; ----- Phase 4: bdos_error_funnel (terminal — does not return) -----
    ;; Write 0x01 first as the "all main phases passed" pre-flag.
    ;; The funnel calls status_set_message with msg_bdos_error
    ;; ("bdos error"), then JPs to input_loop. Our local input_loop
    ;; reads 0xCFFE: 0x01 means deliberate funnel test → verify
    ;; status_buffer matches the funnel's documented contract;
    ;; anything else means unintended funnel entry mid-test (0xE5).
    LD      A, 0x01
    LD      (0xCFFE), A
    CALL    bdos_error_funnel       ; does not return; JPs to input_loop

    ;; ----- failure paths (Phases 1–3; Phase 4 lives in input_loop) -----
.fail_dirty:
    LD      A, 0xE1
    LD      (0xCFFE), A
    JR      .exit
.fail_first:
    LD      A, 0xE2
    LD      (0xCFFE), A
    JR      .exit
.fail_pad_short:
    LD      A, 0xE3
    LD      (0xCFFE), A
    JR      .exit
.fail_pad_tail:
    LD      A, 0xE4
    LD      (0xCFFE), A
    JR      .exit
.fail_render:
    LD      A, 0xE6
    LD      (0xCFFE), A
    JR      .exit
.fail_trunc_dirty:
    LD      A, 0xE7
    LD      (0xCFFE), A
    JR      .exit
.fail_trunc_first:
    LD      A, 0xE8
    LD      (0xCFFE), A
    JR      .exit
.fail_trunc_last:
    LD      A, 0xE9
    LD      (0xCFFE), A

.exit:
    LD      C, BDOS_EXIT
    CALL    BDOS_ENTRY              ; warm-boot to CCP / iz-cpm
    RET                             ; defensive

sample_msg:
    DEFB    "hello status line", 0

long_msg:
    ;; 5 × 16 = 80 bytes; last byte 'F' at index 79.
    DEFB    "0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF", 0

    ;; Pull in statusln.asm's code and message strings so the
    ;; smoke is a standalone .com.
    INCLUDE "../../src/statusln.asm"

    ;; Local input_loop with two roles:
    ;;   1. Deliberate funnel test (Phase 4): 0xCFFE was pre-set
    ;;      to 0x01 right before CALL bdos_error_funnel; verify
    ;;      status_buffer contains "bdos error" + space pad. On
    ;;      pass, 0xCFFE keeps 0x01; on fail, write 0xEA/EB/EC.
    ;;   2. Regression trap: any OTHER value at 0xCFFE means
    ;;      input_loop was reached mid-test (e.g. status_set_message
    ;;      bug accidentally jumped here) — write 0xE5.
input_loop:
    LD      A, (0xCFFE)
    CP      0x01
    JR      NZ, .il_unintended

    ;; Deliberate funnel test: verify msg_bdos_error landed.
    LD      A, (status_buffer)
    CP      'b'
    JR      NZ, .il_fail_first
    LD      A, (status_buffer + 9)  ; "bdos error"[9] = 'r' (last char)
    CP      'r'
    JR      NZ, .il_fail_last
    LD      A, (status_buffer + 10) ; first pad byte after payload
    CP      ' '
    JR      NZ, .il_fail_pad
    ;; All checks passed — 0xCFFE already holds 0x01.
    JR      .il_exit

.il_fail_first:
    LD      A, 0xEA
    LD      (0xCFFE), A
    JR      .il_exit
.il_fail_last:
    LD      A, 0xEB
    LD      (0xCFFE), A
    JR      .il_exit
.il_fail_pad:
    LD      A, 0xEC
    LD      (0xCFFE), A
    JR      .il_exit
.il_unintended:
    LD      A, 0xE5
    LD      (0xCFFE), A
.il_exit:
    LD      C, BDOS_EXIT
    CALL    BDOS_ENTRY
    RET

    ;; state.inc anchors past all emitted code — same pattern
    ;; as production vibe.asm.
    INCLUDE "../../inc/state.inc"
