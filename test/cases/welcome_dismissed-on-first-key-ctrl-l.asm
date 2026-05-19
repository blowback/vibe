; ============================================================
; Module: test/cases/welcome_dismissed-on-first-key-ctrl-l.asm
; Purpose: Story 4.3 AC1 — Ctrl-L variant of the dismissal-hook
;          contract. Story 4.2 AC3 names 5 dismissal-key variants
;          (i, :, Esc, Ctrl-L, a literal digit); the canonical
;          welcome_dismissed-on-first-key.asm exercises only the
;          'i' variant. This replica rebinds the key byte to
;          0x0C (Ctrl-L / ASCII FF / form feed — the redraw
;          keystroke in normal mode) and asserts the identical
;          post-state contract: the dismissal hook is key-agnostic
;          for the welcome_active clear + render_mark_all_dirty
;          call, varying only in the key-preservation byte
;          (subtest 6).
;
;          Pre-state, hook drive sequence, and post-state checks
;          are identical to the canonical 'i' test — see that
;          file's header comment for the full state-machine doc.
;          This file rebinds:
;            - the simulated keystroke byte at the PUSH AF site
;              (was 'i'/0x69, now 0x0C)
;            - the subtest-6 CP comparison (was CP 'i', now CP 0x0C)
;
; AC reference: Story 4.3 AC1 (4-replica dismissal-key coverage).
;
; Sentinel code at 0xCFFE on failure: 0x9D (reused from Story 4.2
;   T3 per the Story 4.3 sentinel-reuse rule — assertion shape is
;   identical across all 5 dismissal-key files, distinguished only
;   by filename + B-context byte semantics).
;   Context byte (B) on failure encodes the subtest:
;     0x01 — welcome_active != 0 (hook failed to clear flag)
;     0x02 — dirty_rows[0] != 0xFF (render_mark_all_dirty not called
;            OR returned without setting the bits)
;     0x03 — dirty_rows[1] != 0xFF
;     0x04 — dirty_rows[2] != 0xFF
;     0x05 — shadow_buffer[6*80+1] != 'X' (hook clobbered shadow —
;            it should NOT; the next render_diff handles the clear)
;     0x06 — key byte clobbered across PUSH AF / POP AF brackets
;            (the Ctrl-L byte 0x0C was not preserved)
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

    ;; Pre-zero relevant state.
    XOR     A
    LD      (dirty_rows + 0), A
    LD      (dirty_rows + 1), A
    LD      (dirty_rows + 2), A

    ;; Arm welcome_active (mimic post-cold-start no-arg state).
    LD      A, 1
    LD      (welcome_active), A

    ;; Seed shadow_buffer[6*80+1] with 'X' (regression sentinel —
    ;; the hook must NOT touch shadow).
    LD      A, 'X'
    LD      (shadow_buffer + 6*80 + 1), A

    ;; --- Drive the dismissal hook's byte sequence inline ---
    ;; This mirrors src/vibe.asm:276-284 exactly. The key byte
    ;; arrives in A (typically from input_get_key); for the Ctrl-L
    ;; variant we pre-load A with 0x0C and verify it survives the
    ;; PUSH AF / POP AF brackets. The hook itself is mode-agnostic
    ;; and key-agnostic — it only cares about welcome_active.
    LD      A, 0x0C                       ; simulated keystroke: Ctrl-L / ASCII FF
    PUSH    AF
    LD      A, (welcome_active)
    OR      A
    JR      Z, .no_welcome
    XOR     A
    LD      (welcome_active), A
    CALL    render_mark_all_dirty
.no_welcome:
    POP     AF

    ;; Save the post-hook A in C for the subtest-6 assertion below
    ;; (the per-subtest checks below trash A; preserve in C).
    LD      C, A

    ;; --- Subtest 1: welcome_active == 0 (hook cleared it) ---
    LD      A, (welcome_active)
    OR      A
    JR      Z, .ok_active_cleared
    LD      B, 0x01
    LD      A, 0x9D
    JP      test_fail
.ok_active_cleared:

    ;; --- Subtest 2: dirty_rows[0] == 0xFF (render_mark_all_dirty fired) ---
    LD      A, (dirty_rows + 0)
    CP      0xFF
    JR      Z, .ok_dirty0
    LD      B, A
    LD      A, 0x9D
    JP      test_fail
.ok_dirty0:

    ;; --- Subtest 3: dirty_rows[1] == 0xFF ---
    LD      A, (dirty_rows + 1)
    CP      0xFF
    JR      Z, .ok_dirty1
    LD      B, A
    LD      A, 0x9D
    JP      test_fail
.ok_dirty1:

    ;; --- Subtest 4: dirty_rows[2] == 0xFF ---
    LD      A, (dirty_rows + 2)
    CP      0xFF
    JR      Z, .ok_dirty2
    LD      B, A
    LD      A, 0x9D
    JP      test_fail
.ok_dirty2:

    ;; --- Subtest 5: shadow_buffer[6*80+1] still == 'X' (hook didn't clobber) ---
    LD      A, (shadow_buffer + 6*80 + 1)
    CP      'X'
    JR      Z, .ok_shadow_unchanged
    LD      B, A
    LD      A, 0x9D
    JP      test_fail
.ok_shadow_unchanged:

    ;; --- Subtest 6: key byte preserved across PUSH AF / POP AF ---
    LD      A, C                          ; recover post-hook A
    CP      0x0C                          ; Ctrl-L byte preserved?
    JR      Z, .ok_key_preserved
    LD      B, A
    LD      A, 0x9D
    JP      test_fail
.ok_key_preserved:

    JP      test_pass

;; ----- LOCAL init_teardown stub -----
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
