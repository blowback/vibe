; ============================================================
; Module: test/cases/gapbuf_insert-fills-buffer.asm
; Purpose: AC13 — verify the buffer-full path: CF=1, state
;          unchanged byte-for-byte, msg_file_too_large landed
;          in status_buffer, status_dirty != 0.
;
; AC reference: AC13 (story 1.7); covers contract AC4.
;
; Strategy: direct-poke (gap_start) := (gap_end) - 1 to reach
; the one-byte-left edge cheaply; one successful insert fills
; the buffer; second insert is the buffer-full case under test.
; (The 32K-iteration loop would assemble fine but burn ~50ms
; under iz-cpm — direct-poke is AC4-aligned and isolates the
; buffer-full primitive from the insert path.)
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — last successful insert returned CF=1 (setup error)
;   0xE2 — gap_start != gap_end after last successful insert
;   0xE3 — gapbuf_insert returned CF=0 on full buffer (expected CF=1)
;   0xE4 — gap_start changed across the buffer-full call
;   0xE5 — gap_end changed across the buffer-full call
;   0xE6 — cursor_offset changed across the buffer-full call
;   0xE7 — status_buffer[0] != 'f' (msg_file_too_large not landed)
;   0xE8 — status_buffer[13] != 'e' (last char of "file too large")
;   0xE9 — status_buffer[14] != ' ' (pad did not run after payload)
;   0xEA — status_dirty == 0 after buffer-full call
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----
    CALL    gapbuf_init

    ;; Force buffer to one-byte-left state.
    ;;   (gap_start) := (gap_end) - 1   ; one byte gap remains
    ;;   (cursor_offset) := GAP_BUFFER_MAX - 1
    ;; Maintains gap-tracks-cursor: gap_start - GAP_BUFFER_BASE
    ;; == cursor_offset (both = GAP_BUFFER_MAX - 1).
    LD      HL, (gap_end)
    DEC     HL
    LD      (gap_start), HL
    LD      HL, GAP_BUFFER_MAX - 1
    LD      (cursor_offset), HL

    ;; One last successful insert ('L') consumes the final byte.
    LD      A, 'L'
    CALL    gapbuf_insert
    JR      NC, .last_ok
    LD      A, 0xE1
    LD      B, 0
    JP      test_fail
.last_ok:
    ;; Verify gap_start == gap_end (gap fully consumed).
    LD      HL, (gap_start)
    LD      DE, (gap_end)
    OR      A
    SBC     HL, DE
    JR      Z, .full_ok
    LD      A, 0xE2
    LD      B, 0
    JP      test_fail
.full_ok:

    ;; Snapshot state pre-buffer-full call.
    LD      HL, (gap_start)
    LD      (snap_gs), HL
    LD      HL, (gap_end)
    LD      (snap_ge), HL
    LD      HL, (cursor_offset)
    LD      (snap_co), HL

    ;; Buffer-full insert ('F') — expected to fail with CF=1.
    LD      A, 'F'
    CALL    gapbuf_insert
    JR      C, .full_cf_ok
    LD      A, 0xE3
    LD      B, 0
    JP      test_fail
.full_cf_ok:

    ;; State-unchanged: gap_start.
    LD      HL, (gap_start)
    LD      DE, (snap_gs)
    OR      A
    SBC     HL, DE
    JR      Z, .gs_ok
    LD      A, 0xE4
    LD      B, 0
    JP      test_fail
.gs_ok:
    ;; State-unchanged: gap_end.
    LD      HL, (gap_end)
    LD      DE, (snap_ge)
    OR      A
    SBC     HL, DE
    JR      Z, .ge_ok
    LD      A, 0xE5
    LD      B, 0
    JP      test_fail
.ge_ok:
    ;; State-unchanged: cursor_offset.
    LD      HL, (cursor_offset)
    LD      DE, (snap_co)
    OR      A
    SBC     HL, DE
    JR      Z, .co_ok
    LD      A, 0xE6
    LD      B, 0
    JP      test_fail
.co_ok:

    ;; status_buffer starts with "file too large".
    LD      A, (status_buffer)
    CP      'f'
    JR      Z, .sb0_ok
    LD      A, 0xE7
    LD      B, 0
    JP      test_fail
.sb0_ok:
    LD      A, (status_buffer + 13)         ; "file too large" length 14, last byte index 13 = 'e'
    CP      'e'
    JR      Z, .sb13_ok
    LD      A, 0xE8
    LD      B, 0
    JP      test_fail
.sb13_ok:
    LD      A, (status_buffer + 14)         ; first pad byte
    CP      ' '
    JR      Z, .sb14_ok
    LD      A, 0xE9
    LD      B, 0
    JP      test_fail
.sb14_ok:

    ;; status_dirty != 0.
    LD      A, (status_dirty)
    OR      A
    JR      NZ, .dirty_ok
    LD      A, 0xEA
    LD      B, 0
    JP      test_fail
.dirty_ok:

    JP      test_pass

;; ----- Per-test scratch (snapshot of pre-call state) -----
;; 6 bytes; co-located with the test code rather than poked into
;; the 0xCFE0 scratch range to keep the test self-contained.
snap_gs:    DEFW 0
snap_ge:    DEFW 0
snap_co:    DEFW 0

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
