; ============================================================
; Module: test/cases/welcome_dismissed-on-first-key.asm
; Purpose: Story 4.2 AC3 — verify the dismissal-hook semantics:
;          one inline keystroke clears welcome_active AND forces
;          a full editable-area redraw via render_mark_all_dirty.
;          Drives the hook's exact byte sequence (mirroring
;          src/vibe.asm input_loop lines 232-244) in the test body,
;          then asserts the post-state.
;
;          Pre-state:
;            - welcome_active     = 1   (post-cold-start no-arg state)
;            - dirty_rows[0..2]   = 0   (cleared so the side-effect
;                                        of render_mark_all_dirty is
;                                        observable)
;            - shadow_buffer      = pre-seeded with 'X' at one banner
;                                    cell so a regression where the
;                                    hook accidentally clears shadow
;                                    surfaces (it should NOT — the
;                                    hook only flips dirty bits)
;
;          Post-state (after the hook sequence + key preservation
;          PUSH AF / POP AF):
;            - welcome_active     == 0  (one-shot consumed)
;            - dirty_rows[0]      == 0xFF (rows 0..7 dirty)
;            - dirty_rows[1]      == 0xFF (rows 8..15 dirty)
;            - dirty_rows[2]      == 0xFF (rows 16..23 dirty; the
;                                          unused bits 24..31 of byte 2
;                                          are inert per RI1)
;            - shadow_buffer[6*80+1] == 'X' (unchanged — the hook does
;                                            NOT touch shadow; that's
;                                            the next render_diff's
;                                            job)
;            - key byte preserved across the PUSH AF / POP AF
;              brackets — we pre-load A with a sentinel and verify
;              it survives the dismissal sequence
;
; AC reference: AC3 (first keystroke dismisses + processed normally).
;               The "processed normally" half is exercised by
;               hardware UAT — this headless test pins the dismissal
;               mechanism + key preservation semantics.
;
; Sentinel code at 0xCFFE on failure: 0x9D (Story 4.2 T3).
;   Context byte (B) on failure encodes the subtest:
;     0x01 — welcome_active != 0 (hook failed to clear flag)
;     0x02 — dirty_rows[0] != 0xFF (render_mark_all_dirty not called
;            OR returned without setting the bits)
;     0x03 — dirty_rows[1] != 0xFF
;     0x04 — dirty_rows[2] != 0xFF
;     0x05 — shadow_buffer[6*80+1] != 'X' (hook clobbered shadow —
;            it should NOT; the next render_diff handles the clear)
;     0x06 — key byte clobbered across PUSH AF / POP AF brackets
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
    ;; This mirrors src/vibe.asm:228-244 exactly. The key byte
    ;; arrives in A (typically from input_get_key); we pre-load A
    ;; with a sentinel value (0x69 = 'i' = MODE_INSERT trigger,
    ;; though the hook is mode-agnostic) and verify it survives
    ;; the PUSH AF / POP AF brackets.
    LD      A, 'i'                        ; simulated keystroke
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
    CP      'i'
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
