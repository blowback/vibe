; ============================================================
; Module: test/cases/gapbuf_delete-at-bof.asm
; Purpose: AC14 — verify gapbuf_delete refuses at BOF with
;          CF=1 and no state mutation.
;
; AC reference: AC14 (story 1.7); covers contract AC5.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — gapbuf_delete returned CF=0 at BOF (expected CF=1)
;   0xE2 — gap_start changed across BOF delete
;   0xE3 — gap_end changed across BOF delete
;   0xE4 — cursor_offset changed across BOF delete
;   0xE5 — status_dirty != 0 across BOF delete (AC5: gapbuf_delete
;          must NOT call status_set_message at this primitive layer
;          — caller composition decides surface)
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----
    CALL    gapbuf_init

    ;; Snapshot state pre-call (cursor_offset is 0 from init).
    LD      HL, (gap_start)
    LD      (snap_gs), HL
    LD      HL, (gap_end)
    LD      (snap_ge), HL
    LD      HL, (cursor_offset)
    LD      (snap_co), HL

    ;; Seed status_dirty := 0 so the post-call check has a
    ;; well-defined baseline (status_dirty is in static RAM
    ;; and CP/M does not zero the TPA on .com load — see
    ;; deferred-work item from Story 1.3 review). gapbuf_delete
    ;; on BOF must leave it at 0 (AC5: no status_set_message).
    XOR     A
    LD      (status_dirty), A

    ;; gapbuf_delete at BOF — expected CF=1.
    CALL    gapbuf_delete
    JR      C, .cf_ok
    LD      A, 0xE1
    LD      B, 0
    JP      test_fail
.cf_ok:

    ;; State-unchanged: gap_start.
    LD      HL, (gap_start)
    LD      DE, (snap_gs)
    OR      A
    SBC     HL, DE
    JR      Z, .gs_ok
    LD      A, 0xE2
    LD      B, 0
    JP      test_fail
.gs_ok:
    ;; State-unchanged: gap_end.
    LD      HL, (gap_end)
    LD      DE, (snap_ge)
    OR      A
    SBC     HL, DE
    JR      Z, .ge_ok
    LD      A, 0xE3
    LD      B, 0
    JP      test_fail
.ge_ok:
    ;; State-unchanged: cursor_offset.
    LD      HL, (cursor_offset)
    LD      DE, (snap_co)
    OR      A
    SBC     HL, DE
    JR      Z, .co_ok
    LD      A, 0xE4
    LD      B, 0
    JP      test_fail
.co_ok:

    ;; AC5: gapbuf_delete must NOT call status_set_message on
    ;; BOF (caller composition decides the surface — vi `x` at
    ;; BOF beeps via the unbound-key handler, not a status msg).
    ;; status_set_message sets status_dirty := 1; so status_dirty
    ;; remaining 0 (we seeded it) proves no message landed.
    LD      A, (status_dirty)
    OR      A
    JR      Z, .sd_ok
    LD      A, 0xE5
    LD      B, 0
    JP      test_fail
.sd_ok:

    JP      test_pass

;; ----- Per-test scratch -----
snap_gs:    DEFW 0
snap_ge:    DEFW 0
snap_co:    DEFW 0

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
