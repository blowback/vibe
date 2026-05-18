; ============================================================
; Module: test/cases/init_cold_start-state-shape.asm
; Purpose: AC16, AC2 — verify that init_cold_start produces the
;          documented state shape across the full state.inc
;          block: mode = NORMAL, cursor / top / parser state at
;          zero, gap buffer at SR2-empty, shadow seeded with
;          spaces, status row reconciled (status_dirty cleared
;          by the render_full inside cold-start), and the
;          Story-1.8 input_held_flag uninit-at-boot deferral
;          closed (now zero-init via the centralised LDIR).
;
;          Setup:
;            - Pre-poison the entire static_data_base..static_end
;              region with 0xAA so any field init_cold_start
;              "forgets" to clear surfaces as 0xAA, not as the
;              already-zero RAM iz-cpm leaves at .com load.
;            - Install BIOS_CONOUT capture override (Story
;              1.11 mechanism) so render_init's ESC J + cursor
;              home and render_full's status / cursor emits
;              don't escape to iz-cpm's adm3a emulation and
;              collide with the PASS/FAIL grep on stdout.
;            - Reset test_capture_len = 0 so the capture starts
;              clean (CP/M does NOT zero TPA; the DEFB in the
;              capture-stub include is the .com-load default).
;            - Replace the standard test_input_loop_stub.inc
;              with a local `input_loop:` that performs the
;              state-shape verification: init_cold_start ends
;              in `JP input_loop`, so the verifier runs as a
;              fall-through from cold-start (no return path).
;
;          Expected post-init_cold_start state:
;            - mode_byte           == MODE_NORMAL (= 0)
;            - cursor_offset       == 0 (16-bit)
;            - gap_start           == GAP_BUFFER_BASE
;            - gap_end             == GAP_BUFFER_BASE + GAP_BUFFER_MAX
;            - top_line_offset     == 0 (16-bit)
;            - dirty_rows[0..2]    == 0 (render_diff cleared
;                                        every bit after the
;                                        full-redraw frame)
;            - shadow_buffer[0]    == 0x20 (render_init seeded
;                                           the row with spaces)
;            - status_dirty        == 0 (render_diff cleared
;                                        the dirty flag after
;                                        reconciling the
;                                        msg_mode_normal-empty
;                                        status row)
;            - input_held_flag     == 0 (Story 1.8 deferral
;                                        resolved via the
;                                        centralised LDIR fill)
;            - pending_operator    == 0
;            - pending_motion_prefix == 0
;            - count_accumulator   == 0 (16-bit)
;
; AC reference: AC16 (init_cold_start state-shape test),
;               AC2 (init_cold_start stages 1-5 — every
;               documented post-condition), AC20 (Story 1.3 /
;               1.8 deferral resolution verification).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — mode_byte         != MODE_NORMAL
;   0xE2 — cursor_offset     != 0  (B = low byte)
;   0xE3 — gap_start         != GAP_BUFFER_BASE
;   0xE4 — gap_end           != GAP_BUFFER_BASE + GAP_BUFFER_MAX
;   0xE5 — top_line_offset   != 0  (B = low byte)
;   0xE6 — dirty_rows[i]     != 0  (B = offending byte)
;   0xE7 — shadow_buffer[0]  != 0x20
;   0xE8 — status_dirty      != 0
;   0xE9 — input_held_flag   != 0
;   0xEA — pending_operator  != 0
;   0xEB — pending_motion_prefix != 0
;   0xEC — count_accumulator != 0 (B = low byte)
;   B    — diagnostic byte (the offending value where applicable)
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
;; BIOS_CONOUT override: redirect render emits into a test-local
;; capture buffer rather than letting them escape to iz-cpm
;; stdout (where they would collide with the PASS/FAIL grep).
;; bios.inc wraps its production EQU in IFNDEF BIOS_CONOUT_OVERRIDE
;; (Story 1.11 / AC17); setting that marker plus the EQU below
;; redirects render.asm's CALL BIOS_CONOUT to the capture stub.
    DEFINE BIOS_CONOUT_OVERRIDE
BIOS_CONOUT EQU test_bios_conout
;; MBB_SET_USR_INT override: iz-cpm does not emulate the MicroBeast-
;; specific BIOS routines, so the real address (0xFDC7) sits over
;; uninitialised memory. Story 1.12's init_cold_start calls
;; MBB_SET_USR_INT twice (uninstall + install); pointing the symbol
;; at a local no-op stub keeps the test build clean without changing
;; production behaviour. Same IFNDEF guard pattern as
;; BIOS_CONOUT_OVERRIDE.
    DEFINE MBB_SET_USR_INT_OVERRIDE
MBB_SET_USR_INT EQU test_mbb_set_usr_int
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----

    ;; Pre-poison the entire static block with 0xAA. The LDIR
    ;; idiom mirrors init_cold_start's own zero-fill: seed at
    ;; HL, then LDIR propagates the seed forward over the
    ;; remaining static_block_size - 1 bytes. Any field that
    ;; init_cold_start forgets to clear surfaces as 0xAA in
    ;; the state-shape verifier below — not as the residual
    ;; zero iz-cpm leaves at .com load (which would mask a
    ;; missed init step).
    LD      HL, static_data_base
    LD      (HL), 0xAA
    LD      DE, static_data_base + 1
    LD      BC, static_end - static_data_base - 1
    LDIR

    ;; Reset the capture buffer length so the post-init capture
    ;; starts clean.
    XOR     A
    LD      (test_capture_len), A

    ;; Story 2.3: pre-set DEFAULT_FCB + 1 to a space so Stage 5's
    ;; fileio_load_initial takes the no-arg short-circuit (mirroring
    ;; the CCP space-pad invariant for `vibe` with no command-line
    ;; argument). Without this, iz-cpm's default-FCB contents at
    ;; .com launch could vary between host environments and cause
    ;; the test to attempt an unwanted load.
    LD      A, ' '
    LD      (DEFAULT_FCB + 1), A

    ;; Hand control to init_cold_start. init_cold_start's
    ;; stage-6 JP input_loop transfers control to the local
    ;; verifier defined below — there is no return path from
    ;; cold-start (it never RETs).
    JP      init_cold_start

;; ----- Verifier (entered via init_cold_start's fall-through JP) -----
; The production `input_loop` symbol is hijacked here so the
; standard test_input_loop_stub.inc is NOT INCLUDEd by this
; test. statusln.asm's bdos_error_funnel JPs to `input_loop`
; on a BDOS error — that path is not exercised here (no BDOS
; calls happen between the test body's reset and the verifier
; that fires post-init).
input_loop:
    ;; --- Subtest 1: mode_byte == MODE_NORMAL ---
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok_mode:

    ;; --- Subtest 2: cursor_offset == 0 (both bytes) ---
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      B, L                ; surface low byte
    LD      A, 0xE2
    JP      test_fail
.ok_cursor:

    ;; --- Subtest 3: gap_start == GAP_BUFFER_BASE ---
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_gapstart
    LD      B, L
    LD      A, 0xE3
    JP      test_fail
.ok_gapstart:

    ;; --- Subtest 4: gap_end == GAP_BUFFER_BASE + GAP_BUFFER_MAX ---
    LD      HL, (gap_end)
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_gapend
    LD      B, L
    LD      A, 0xE4
    JP      test_fail
.ok_gapend:

    ;; --- Subtest 5: top_line_offset == 0 (both bytes) ---
    LD      HL, (top_line_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_top
    LD      B, L
    LD      A, 0xE5
    JP      test_fail
.ok_top:

    ;; --- Subtest 6: dirty_rows[0..2] all zero ---
    LD      A, (dirty_rows)
    OR      A
    JR      NZ, .fail_dirty
    LD      A, (dirty_rows + 1)
    OR      A
    JR      NZ, .fail_dirty
    LD      A, (dirty_rows + 2)
    OR      A
    JR      Z, .ok_dirty
.fail_dirty:
    LD      B, A                ; offending byte
    LD      A, 0xE6
    JP      test_fail
.ok_dirty:

    ;; --- Subtest 7: shadow_buffer[0] == 0x20 (render_init seed) ---
    LD      A, (shadow_buffer)
    CP      0x20
    JR      Z, .ok_shadow
    LD      B, A
    LD      A, 0xE7
    JP      test_fail
.ok_shadow:

    ;; --- Subtest 8: status_dirty == 0 (render_diff cleared it
    ;; after reconciling the msg_mode_normal-empty status row) ---
    LD      A, (status_dirty)
    OR      A
    JR      Z, .ok_statusd
    LD      B, A
    LD      A, 0xE8
    JP      test_fail
.ok_statusd:

    ;; --- Subtest 9: input_held_flag == 0 (Story 1.8 deferral) ---
    LD      A, (input_held_flag)
    OR      A
    JR      Z, .ok_inputheld
    LD      B, A
    LD      A, 0xE9
    JP      test_fail
.ok_inputheld:

    ;; --- Subtest 10: pending_operator == 0 ---
    LD      A, (pending_operator)
    OR      A
    JR      Z, .ok_op
    LD      B, A
    LD      A, 0xEA
    JP      test_fail
.ok_op:

    ;; --- Subtest 11: pending_motion_prefix == 0 ---
    LD      A, (pending_motion_prefix)
    OR      A
    JR      Z, .ok_prefix
    LD      B, A
    LD      A, 0xEB
    JP      test_fail
.ok_prefix:

    ;; --- Subtest 12: count_accumulator == 0 (both bytes) ---
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count
    LD      B, L
    LD      A, 0xEC
    JP      test_fail
.ok_count:

    JP      test_pass

;; ----- MBB_SET_USR_INT stub (no-op for iz-cpm) -----
; init_cold_start's stage 0 (uninstall pre-existing ISR) and stage 2
; (install input_tick_isr) both call MBB_SET_USR_INT. The production
; address (0xFDC7) is MicroBeast-specific; iz-cpm has nothing there.
; A bare RET keeps both calls inert during the headless test.
test_mbb_set_usr_int:
    RET

;; ----- Capture stub + buffer + length -----
    INCLUDE "../inc/test_bios_conout_capture.inc"

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
; init.asm INCLUDEs first so init_cold_start / init_teardown are
; defined; input.asm follows even though this test does not call
; input_get_key (the production AR25 order is mirrored so the
; assembly layout matches src/vibe.asm's emission shape).
; dispatch.asm INCLUDEs init.asm's init_teardown via the
; mode_debug_quit re-point; parser.asm has no cross-module init
; reference but is included to honor AR25.
    INCLUDE "../../src/init.asm"
    INCLUDE "../../src/input.asm"
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"     ; Story 2.5: dispatch_normal forward-references motion_h/j/k/l
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"     ; Story 2.8: dispatch_normal forward-references edits_*, dispatch_insert table grows, unbound_insert tail-JPs edits_insert_literal
    ;; Story 2.3: init.asm Stage 5 now calls fileio_load_initial;
    ;; the exline + fileio modules are pulled in (in AR25 order)
    ;; so the test build resolves cmd_edit / fileio_load_initial
    ;; forward references inside dispatch.asm / init.asm.
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

;; ----- state.inc LAST (positional anchor: static_data_base = $) -----
    INCLUDE "../../inc/state.inc"
