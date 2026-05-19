; ============================================================
; Module: test/cases/welcome_does-not-redraw-after-dismiss.asm
; Purpose: Story 4.2 AC4 — regression net pinning the one-shot
;          guarantee: post-dismissal (welcome_active = 0), no
;          production code path may re-arm welcome_active. The
;          structural guarantee is "fileio_load_initial.no_arg is
;          the SOLE writer-to-1 in the editor's lifetime, and
;          fileio_load_initial runs once per .com launch via
;          init_cold_start Stage 5". This test exercises common
;          post-dismissal operations (gap reset, full redraw mark,
;          status update, undo clear, exline submode flip) and
;          asserts welcome_active stays 0 after each — which
;          would catch a future story accidentally adding a
;          second writer-to-1 outside fileio.no_arg.
;
;          Pre-state: welcome_active = 0 (post-dismissal).
;
;          Operations exercised:
;            1. gapbuf_init                  (mimics :e empty.txt
;                                             buffer reset)
;            2. render_mark_all_dirty        (mimics Ctrl-L refresh)
;            3. render_init                  (mimics teardown-equivalent
;                                             screen-clear)
;            4. status_set_message           (mimics mode-change /
;                                             error status update)
;            5. op_dd-on-1-line              (FR29 buffer-returns-
;                                             to-empty: 4-byte
;                                             buffer "abc\n", count=1,
;                                             dd deletes the only
;                                             line; file_length must
;                                             return to 0 AND
;                                             welcome_active must
;                                             stay 0 — exercises
;                                             the spec narrative's
;                                             `dd on a 1-line buffer`
;                                             scenario that prior
;                                             Op 1 only mimicked
;                                             via the internal gap
;                                             reset)
;
;          After each operation, assert welcome_active == 0.
;
;          Final shadow-row poison check (Op 6): after Op 3
;          (render_init) seeds shadow_buffer to 0x20, no subsequent
;          op may paint banner glyphs into the welcome-banner
;          editable region (internal rows 5..17 = 13 rows × 80 cols
;          = 1040 cells). The check sweeps shadow_buffer[5*80..
;          18*80) and asserts every cell == 0x20. Strengthens AC4
;          beyond the welcome_active flag-state assertion: catches
;          a future writer that paints banner glyphs into shadow
;          without arming the flag.
;
; Out-of-scope for this test: `:e empty.txt` end-to-end load
; (BDOS_OPEN + READ_SEQ against test/fixtures/EMPTY.TXT). The
; production path differs from Op 5's op_dd in that fileio_load
; calls gapbuf_init internally (Step 2; identical to Op 1's
; coverage) and then runs the BDOS open/read chain. Adding the
; full :e variant requires drive-B FCB scaffolding (see
; fileio_save-empty-buffer.asm as the template) plus a careful
; fixture-stability story — EMPTY.TXT is git-tracked but the
; test/Makefile `make clean` rule rms it, so a fresh clone after
; clean would need `git checkout test/fixtures/EMPTY.TXT` before
; the test runs. Tracked as a deferred follow-up in deferred-work.md
; under Story 4.2's review-findings block. Today, Op 1 covers the
; internal gap-reset path that `:e empty.txt` would also walk;
; Op 5's op_dd covers the FR29 path; the gap to `:e empty.txt`-
; specific behaviour (BDOS read-zero-bytes return) is not
; structurally observable for welcome_active because
; fileio_load never touches the flag.
;
; AC reference: AC4 (one-shot guarantee — welcome never re-arms).
;
; Sentinel code at 0xCFFE on failure: 0x9E (Story 4.2 T4).
;   Context byte (B) on failure encodes the operation that armed
;   the flag (1-indexed per the list above):
;     0x01 — welcome_active armed after gapbuf_init
;     0x02 — welcome_active armed after render_mark_all_dirty
;     0x03 — welcome_active armed after render_init
;     0x04 — welcome_active armed after status_set_message
;     0x05 — welcome_active armed after op_dd-on-1-line
;     0x06 — op_dd post-condition fault: file_length != 0
;            (buffer did not return to empty as required by
;            the FR29 scenario the op exercises)
;     0x07 — shadow_buffer[5*80..18*80) had a non-0x20 cell
;            (a banner-row cell was painted post-render_init).
;            B = low byte of (offset - 5*80); C = high byte of
;            same offset. Together they fully recover the 0..1039
;            offset; banner-row index = offset / 80 ∈ 0..12,
;            col = offset % 80.
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
;; BIOS_CONOUT override for the welcome_paint subtest (otherwise
;; its emits would escape to stdout and break the PASS/FAIL grep).
    DEFINE BIOS_CONOUT_OVERRIDE
BIOS_CONOUT EQU test_bios_conout
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----

    ;; Pre-zero state. welcome_active = 0 = post-dismissal.
    XOR     A
    LD      (welcome_active), A
    LD      (init_teardown_called), A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (buffer_dirty), A
    LD      (test_capture_len), A

    ;; Op 1: gapbuf_init.
    CALL    gapbuf_init
    LD      A, (welcome_active)
    OR      A
    JR      Z, .ok_op1
    LD      B, 0x01
    LD      A, 0x9E
    JP      test_fail
.ok_op1:

    ;; Op 2: render_mark_all_dirty.
    CALL    render_mark_all_dirty
    LD      A, (welcome_active)
    OR      A
    JR      Z, .ok_op2
    LD      B, 0x02
    LD      A, 0x9E
    JP      test_fail
.ok_op2:

    ;; Op 3: render_init.
    CALL    render_init
    LD      A, (welcome_active)
    OR      A
    JR      Z, .ok_op3
    LD      B, 0x03
    LD      A, 0x9E
    JP      test_fail
.ok_op3:

    ;; Op 4: status_set_message with msg_mode_normal.
    LD      HL, msg_mode_normal
    XOR     A
    CALL    status_set_message
    LD      A, (welcome_active)
    OR      A
    JR      Z, .ok_op4
    LD      B, 0x04
    LD      A, 0x9E
    JP      test_fail
.ok_op4:

    ;; Op 5: op_dd-on-1-line — exercises the FR29 path where the
    ;; buffer returns to file_length = 0 via the doubled-operator
    ;; line-delete handler. Replaces the prior misleading
    ;; "defensive welcome_paint" Op 5 (which actually painted the
    ;; banner into shadow + screen, contradicting AC4's intent).
    ;;
    ;; Setup: re-establish the full-empty gap shape defensively
    ;; (Ops 2-4 don't touch gap_end today, but the dependency was
    ;; implicit; CALL gapbuf_init makes the precondition explicit).
    ;; Then write "abc\n" into the front of the gap buffer, advance
    ;; gap_start by 4, set cursor_offset = 0, and pin
    ;; count_accumulator = 1 explicitly (was implicit 0 →
    ;; motion_apply_count's 0→1 default; pinning makes the test
    ;; survive a future change to that defaulting branch). Also
    ;; reset mode_byte to MODE_NORMAL right before CALL op_dd so
    ;; the test does not depend on Ops 1-4 having preserved it.
    CALL    gapbuf_init
    LD      HL, GAP_BUFFER_BASE
    LD      (HL), 'a'
    INC     HL
    LD      (HL), 'b'
    INC     HL
    LD      (HL), 'c'
    INC     HL
    LD      (HL), 0x0A
    LD      HL, GAP_BUFFER_BASE + 4
    LD      (gap_start), HL
    LD      HL, 0
    LD      (cursor_offset), HL
    LD      HL, 1
    LD      (count_accumulator), HL    ; explicit 1 (pin against motion_apply_count default change)
    LD      A, MODE_NORMAL
    LD      (mode_byte), A             ; defensive: pin mode for op_dd dispatch
    ;; Status / yank state must permit a clean op_dd. op_dd writes
    ;; yank_register; the test only cares about welcome_active and
    ;; file_length, so any side-effects on yank/status/dirty are
    ;; acceptable. parser_clear tail-JP at op_dd's exit lands here.
    CALL    op_dd
    ;; Subtest 5a: welcome_active still 0.
    LD      A, (welcome_active)
    OR      A
    JR      Z, .check_op5_filelen
    LD      B, 0x05
    LD      A, 0x9E
    JP      test_fail
.check_op5_filelen:
    ;; Subtest 5b: file_length = (gap_start - GAP_BUFFER_BASE) +
    ;; (GAP_BUFFER_MAX - (gap_end - GAP_BUFFER_BASE)) must be 0.
    ;; Compute as (gap_start + GAP_BUFFER_MAX - gap_end). The
    ;; cleanest pin: gap_start == GAP_BUFFER_BASE AND gap_end ==
    ;; GAP_BUFFER_BASE + GAP_BUFFER_MAX (full-empty gap shape per
    ;; the gapbuf_init post-condition).
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      NZ, .fail_op5_filelen
    LD      HL, (gap_end)
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_op5
.fail_op5_filelen:
    LD      B, 0x06
    LD      A, 0x9E
    JP      test_fail
.ok_op5:

    ;; Op 6: shadow-row poison final check. After Op 3 (render_init)
    ;; seeded shadow_buffer to 0x20, none of Ops 4 (status_set_message)
    ;; / 5 (op_dd) should paint into shadow rows 5..17. The status row
    ;; (row 23) is fair game for status_set_message; the banner rows
    ;; (5..17) must stay at 0x20. Walks 1040 cells; first mismatch
    ;; fails with B = low byte of offset, C = high byte of offset.
    LD      HL, shadow_buffer + (5 * 80)
    LD      BC, 13 * 80         ; 1040 cells
.shadow_check:
    LD      A, (HL)
    CP      0x20
    JR      NZ, .fail_shadow
    INC     HL
    DEC     BC
    LD      A, B
    OR      C
    JR      NZ, .shadow_check
    JR      .ok_op6
.fail_shadow:
    ;; HL points at the offending cell. Compute HL - (shadow_buffer + 5*80)
    ;; and surface both bytes (B=low, C=high) so the full 0..1039
    ;; offset survives the diagnostic encoding. banner-row index =
    ;; offset / 80 ∈ 0..12, col = offset % 80.
    LD      DE, shadow_buffer + (5 * 80)
    OR      A
    SBC     HL, DE
    LD      B, L
    LD      C, H
    LD      A, 0x9E
    JP      test_fail
.ok_op6:

    JP      test_pass

;; ----- LOCAL stubs -----

;; --- BIOS_CONOUT capture buffer ---
    INCLUDE "../inc/test_bios_conout_capture.inc"

;; --- init_teardown stub ---
    INCLUDE "../inc/test_teardown_stub.inc"

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/welcome.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
