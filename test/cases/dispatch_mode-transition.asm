; ============================================================
; Module: test/cases/dispatch_mode-transition.asm
; Purpose: AC11 (+ AC7, AC8, AC9) — verify the production
;          mode-change handlers actually transition mode_byte
;          (and visual_submode for visual entry) per the
;          per-mode dispatch table contract.
;
;          Sequence exercised:
;            NORMAL --[ 'i' ]--> INSERT
;            INSERT --[ Esc ]--> NORMAL
;            NORMAL --[ ':' ]--> COMMAND
;            COMMAND -[ Esc ]--> NORMAL
;            NORMAL --[ 'v' ]--> VISUAL (with VIS_CHAR submode)
;            VISUAL -[ Esc ]--> NORMAL
;
;          Each transition is followed by a read of mode_byte
;          (and visual_submode for the 'v' step) and a
;          compare against the expected MODE_* constant.
;
; AC reference: AC7, AC8, AC9, AC11 (story 1.9).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xE1 — 'i' did not set mode_byte = MODE_INSERT
;   0xE2 — Esc-from-INSERT did not set mode_byte = MODE_NORMAL
;   0xE3 — ':' did not set mode_byte = MODE_COMMAND
;   0xE4 — Esc-from-COMMAND did not set mode_byte = MODE_NORMAL
;   0xE5 — 'v' did not set mode_byte = MODE_VISUAL
;   0xE6 — 'v' did not set visual_submode = VIS_CHAR
;   0xE7 — Esc-from-VISUAL did not set mode_byte = MODE_NORMAL
;   0xE8 — Esc-from-VISUAL cleared visual_submode (header invariant
;          at src/dispatch.asm:16-21 says it MUST remain VIS_CHAR)
;   0xE9 — Ctrl-L in NORMAL did not clear dirty_rows[0] (the
;          new Story-1.11 handler tail-JPs to render_full, which
;          marks-all then runs render_diff — render_diff's
;          terminal step zeroes dirty_rows[0..2]; a routing miss
;          would leave the pre-call 0x01 bit in place).
;   0xEA — '/' in NORMAL did not set status_dirty (stub did not
;          run; production-table layout regression)
;   0xEB — 'a' in NORMAL did not set mode_byte = MODE_INSERT (the
;          duplicate-handler entry at the production table's 'a'
;          row routes to enter_insert_mode; a row-swap typo would
;          break this without breaking the existing 'i' subtest)
;   B    — observed mode_byte / visual_submode / status_dirty
; ============================================================

;; --- Pre-ORG production headers (pure EQU; safe before ORG) ---
    INCLUDE "../../inc/equates.inc"
;; BIOS_CONOUT override — Story 1.11's Ctrl-L handler tail-JPs
;; into render_full, which emits bytes via BIOS_CONOUT. The
;; iz-cpm host does not install a BIOS at 0xFA0C (a Story-1.12
;; W1 placeholder), so calling the production address triggers
;; a cold restart. Capturing the bytes locally keeps the test
;; self-contained and observable.
    DEFINE BIOS_CONOUT_OVERRIDE
BIOS_CONOUT EQU test_bios_conout
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----

    ;; Pre-state: NORMAL.
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; Step 1: NORMAL --[ 'i' ]--> INSERT
    LD      A, 'i'
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key
    LD      A, (mode_byte)
    CP      MODE_INSERT
    JR      Z, .ok_to_insert
    LD      B, A
    LD      A, 0xE1
    JP      test_fail
.ok_to_insert:

    ;; Step 2: INSERT --[ Esc ]--> NORMAL
    LD      A, 0x1B
    LD      HL, dispatch_insert
    LD      B, DISPATCH_INSERT_COUNT
    CALL    dispatch_key
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_back_from_insert
    LD      B, A
    LD      A, 0xE2
    JP      test_fail
.ok_back_from_insert:

    ;; Step 3: NORMAL --[ ':' ]--> COMMAND
    LD      A, ':'
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key
    LD      A, (mode_byte)
    CP      MODE_COMMAND
    JR      Z, .ok_to_command
    LD      B, A
    LD      A, 0xE3
    JP      test_fail
.ok_to_command:

    ;; Step 4: COMMAND --[ Esc ]--> NORMAL
    LD      A, 0x1B
    LD      HL, dispatch_command
    LD      B, DISPATCH_COMMAND_COUNT
    CALL    dispatch_key
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_back_from_command
    LD      B, A
    LD      A, 0xE4
    JP      test_fail
.ok_back_from_command:

    ;; Step 5a: NORMAL --[ 'v' ]--> VISUAL (mode_byte)
    ;; Pre-clobber visual_submode so we can observe AC7's
    ;; "visual entry sets visual_submode = VIS_CHAR" guarantee.
    LD      A, 0xFF
    LD      (visual_submode), A
    LD      A, 'v'
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key
    LD      A, (mode_byte)
    CP      MODE_VISUAL
    JR      Z, .ok_to_visual
    LD      B, A
    LD      A, 0xE5
    JP      test_fail
.ok_to_visual:

    ;; Step 5b: visual_submode == VIS_CHAR (AC7)
    LD      A, (visual_submode)
    CP      VIS_CHAR
    JR      Z, .ok_visual_submode
    LD      B, A
    LD      A, 0xE6
    JP      test_fail
.ok_visual_submode:

    ;; Step 6: VISUAL --[ Esc ]--> NORMAL
    LD      A, 0x1B
    LD      HL, dispatch_visual
    LD      B, DISPATCH_VISUAL_COUNT
    CALL    dispatch_key
    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_back_from_visual
    LD      B, A
    LD      A, 0xE7
    JP      test_fail
.ok_back_from_visual:

    ;; Step 6b: visual_submode preserved across Esc-from-VISUAL.
    ;; Module-header invariant at src/dispatch.asm:16-21 says the
    ;; mode-change handler does NOT clear visual_submode. The
    ;; value is meaningless in NORMAL mode, but the documented
    ;; behaviour is preservation — guard against a future edit
    ;; that "cleans up" the value and breaks the invariant.
    LD      A, (visual_submode)
    CP      VIS_CHAR
    JR      Z, .ok_visual_preserved
    LD      B, A
    LD      A, 0xE8
    JP      test_fail
.ok_visual_preserved:

    ;; Step 7: Ctrl-L in NORMAL → mode_full_refresh_stub (which,
    ;; post-Story-1.11, tail-JPs to render_full). Verifies the
    ;; production dispatch_normal layout still resolves 0x0C
    ;; correctly AND the new handler runs render_full's clear-
    ;; dirty-rows post-condition. Mode_byte stays NORMAL.
    ;;
    ;; Setup is the minimum state render_diff needs to walk the
    ;; (empty) buffer without reading garbage memory: gap covers
    ;; the entire payload (file_length = 0), cursor at top of
    ;; visible window, shadow seeded with 0x20 so the row-walk's
    ;; per-cell diff finds nothing to emit. Pre-set dirty_rows[0]
    ;; = 0x01 so we observe the post-call zeroing; render_full's
    ;; mark-all-dirty then sets it to 0xFF, render_diff's terminal
    ;; clear zeroes it back. status_dirty stays 0 throughout.
    ;;
    ;; The emit stream this produces (cursor reposition only —
    ;; ESC 'Y' 0x20 0x20, 4 bytes) is captured by the
    ;; test_bios_conout stub installed at the top of this file
    ;; (DEFINE BIOS_CONOUT_OVERRIDE / BIOS_CONOUT EQU
    ;; test_bios_conout). The bytes never reach iz-cpm stdout
    ;; and so cannot collide with the harness' `\bPASS\b` /
    ;; `\bFAIL\b` regex. This step doesn't read the captured
    ;; bytes — it only verifies the post-call state (mode_byte,
    ;; dirty_rows, top_line_offset).
    LD      HL, GAP_BUFFER_BASE
    LD      (gap_start), HL
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      (gap_end), HL
    LD      HL, 0
    LD      (top_line_offset), HL
    LD      (cursor_offset), HL
    LD      HL, shadow_buffer
    LD      (HL), 0x20
    LD      DE, shadow_buffer + 1
    LD      BC, SCREEN_ROWS * SCREEN_COLS - 1
    LDIR
    XOR     A
    LD      (status_dirty), A
    LD      A, 0x01
    LD      (dirty_rows), A
    XOR     A
    LD      (dirty_rows + 1), A
    LD      (dirty_rows + 2), A

    LD      A, 0x0C
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key

    LD      A, (dirty_rows)
    OR      A
    JR      Z, .ok_ctrl_l
    LD      B, A
    LD      A, 0xE9
    JP      test_fail
.ok_ctrl_l:

    ;; Step 8: '/' in NORMAL → mode_search_prompt_stub.
    ;; Same shape as step 7; '/' lives at a different table
    ;; position so this also exercises a distinct binary-search
    ;; path on the production table.
    XOR     A
    LD      (status_dirty), A
    LD      A, '/'
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key
    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok_slash
    LD      B, A
    LD      A, 0xEA
    JP      test_fail
.ok_slash:

    ;; Step 9: 'a' in NORMAL → enter_insert_mode (duplicate-handler
    ;; entry). The existing 'i' subtest already covers
    ;; enter_insert_mode itself; this subtest covers the
    ;; production table's 'a' row specifically — a swap-typo
    ;; that put e.g. 'a' → enter_visual_mode would compile
    ;; cleanly past the ascending-key ASSERTs but fail here.
    LD      A, MODE_NORMAL
    LD      (mode_byte), A
    LD      A, 'a'
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key
    LD      A, (mode_byte)
    CP      MODE_INSERT
    JR      Z, .ok_a_to_insert
    LD      B, A
    LD      A, 0xEB
    JP      test_fail
.ok_a_to_insert:

    JP      test_pass

;; ----- Capture stub for BIOS_CONOUT override -----
    INCLUDE "../inc/test_bios_conout_capture.inc"

;; ----- LOCAL init_teardown stub (Story 2.3: exline.asm cmd_quit references init_teardown) -----
    INCLUDE "../inc/test_teardown_stub.inc"
;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test (AR25 INCLUDE order) -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/render.asm"

;; ----- input_loop stub (resolves bdos_error_funnel symbol) -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST (positional anchor: static_data_base = $) -----
    INCLUDE "../../inc/state.inc"
