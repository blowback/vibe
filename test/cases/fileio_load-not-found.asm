; ============================================================
; Module: test/cases/fileio_load-not-found.asm
; Purpose: AC7, AC11, AC13 — verify the bdos_error_pre_msg override
;          path. BDOS_OPEN on a non-existent file returns 0xFF;
;          the BDOS_CALL macro's `JP M` traps it into
;          bdos_error_funnel. Story 2.2's funnel reads
;          bdos_error_pre_msg (which fileio_load pre-staged to
;          point at "can't open B:NOSUCH.FS\0" composed in
;          fileio_status_scratch) and surfaces that banner in
;          place of msg_bdos_error. It then clears the override,
;          inlines the ex-line cleanup (ex_buffer length = 0,
;          mode = MODE_NORMAL, status_dirty = 1), and JPs to
;          input_loop. In production the loop body resumes; here
;          the local input_loop stub sets a sentinel and jumps
;          into the test body for assertions.
;
;          The test pre-sets ex_buffer length + mode = MODE_COMMAND
;          BEFORE the fileio_load call so the assertions can verify
;          the funnel's inline ex-line cleanup runs.
;
; AC reference: AC7 (file-not-found -> "can't open" banner),
;               AC11 (bdos_error_pre_msg override + ex-line
;               cleanup), AC13 (headless coverage).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE0 — funnel_entered != 1 (BDOS funnel never fired -> BDOS_OPEN
;          unexpectedly succeeded?)
;   0xE1 — status_buffer[0..21] != "can't open B:NOSUCH.FS" (B = idx)
;   0xE2 — ex_buffer length != 0 (funnel cleanup did not run)
;   0xE3 — mode_byte != MODE_NORMAL
;   0xE4 — status_dirty == 0
;   B    — diagnostic context
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----

    XOR     A
    LD      (funnel_entered), A
    LD      (init_teardown_called), A
    LD      (status_dirty), A
    LD      (buffer_dirty), A
    LD      (filename_buffer), A

    ;; Pre-set ex_buffer + mode to non-cleanup values so the
    ;; funnel's inline ex-line cleanup is observable.
    LD      A, 11                           ; pretend ex_buffer holds "e nosuch.fs"
    LD      (ex_buffer), A
    LD      A, MODE_COMMAND
    LD      (mode_byte), A
    CALL    gapbuf_init

    LD      HL, .filename
    LD      A, 9                            ; "nosuch.fs"
    CALL    fileio_load
    ;; Production: never returns here (funnel JPed to input_loop).
    ;; If we DO reach this point, the BDOS_OPEN unexpectedly
    ;; succeeded — fail with 0xE0.
    LD      B, 0
    LD      A, 0xE0
    JP      test_fail

;; The local input_loop stub below sets funnel_entered + JPs here.
.after_funnel:
    ;; --- Subtest 1: funnel_entered = 1 ---
    LD      A, (funnel_entered)
    OR      A
    JR      NZ, .ok_entered
    LD      B, A
    LD      A, 0xE0
    JP      test_fail
.ok_entered:

    ;; --- Subtest 2: status_buffer[0..21] = "can't open B:NOSUCH.FS" ---
    LD      HL, .expected_status
    LD      DE, status_buffer
    LD      B, 22
    LD      C, 0
.cmp_status:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_status
    INC     HL
    INC     DE
    INC     C
    DJNZ    .cmp_status
    JR      .ok_status
.fail_status:
    LD      B, C
    LD      A, 0xE1
    JP      test_fail
.ok_status:

    ;; --- Subtest 3: ex_buffer length cleared by funnel ---
    LD      A, (ex_buffer)
    OR      A
    JR      Z, .ok_exlen
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok_exlen:

    ;; --- Subtest 4: mode_byte = MODE_NORMAL ---
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok_mode:

    ;; --- Subtest 5: status_dirty set ---
    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok_dirty
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok_dirty:

    JP      test_pass

.filename:
    DEFB    "nosuch.fs"
.expected_status:
    DEFB    "can't open B:NOSUCH.FS"

;; ----- LOCAL init_teardown stub -----
    INCLUDE "../inc/test_teardown_stub.inc"
;; ----- LOCAL input_loop stub (REPLACES test_input_loop_stub.inc) -----
; The BDOS funnel's `JP input_loop` lands here on the file-not-
; found path. Set the funnel_entered sentinel and JP into the
; test body's assertions. The fileio_load CALL's return address
; is left on the stack — harmless, since the test exit path
; (test_pass / test_fail) issues BDOS_EXIT which discards the
; whole TPA.
input_loop:
    LD      A, 1
    LD      (funnel_entered), A
    JP      test_start.after_funnel         ; cross-scope dotted-local
funnel_entered:    DEFB 0

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"     ; Story 2.5: dispatch_normal forward-references motion_h/j/k/l
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/search.asm"     ; Story 2.8: dispatch_normal forward-references edits_*, dispatch_insert table grows, unbound_insert tail-JPs edits_insert_literal
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
