; ============================================================
; Module: test/cases/init_welcome-shown-no-arg.asm
; Purpose: Story 4.2 AC1 — verify end-to-end welcome-shown path:
;          fileio_load_initial.no_arg sets welcome_active = 1,
;          AND welcome_paint writes banner glyphs to shadow_buffer
;          in lock-step with screen emits (BIOS_CONOUT captured to
;          a test-local buffer rather than escaping to stdout).
;
;          Pre-state:
;            - Static block pre-poisoned with 0xAA (catches any
;              field that should be cleared but isn't).
;            - DEFAULT_FCB[0..11] = 0xAA poison.
;            - DEFAULT_FCB + 1    = 0x20 (no-arg sentinel).
;            - BIOS_CONOUT override installed (welcome_paint emits
;              get captured to test_capture_buffer; do not escape
;              to iz-cpm stdout where they would corrupt the
;              PASS/FAIL grep).
;
;          Post-state (after fileio_load_initial + render_init +
;          welcome_paint):
;            - welcome_active        == 1     (Story 4.2: AC1
;                                              "welcome shown"
;                                              decision pinned by
;                                              fileio.no_arg setting
;                                              the flag)
;            - shadow_buffer[5*80+0] == 0x20  (banner line 1 is
;                                              blank — internal
;                                              row 5 stays at the
;                                              render_init seed)
;            - shadow_buffer[6*80+21] == 'm'  (banner line 2 first
;                                              non-space glyph is
;                                              'm' at col 21 —
;                                              horizontal-center
;                                              col_start = 21 per
;                                              `(80 - 38) / 2`; `mm`
;                                              run start)
;            - shadow_buffer[6*80+0] == 0x20  (col 0 is pre-glyph
;                                              col_start; render_init
;                                              seed preserved since
;                                              welcome_paint skips
;                                              positions before
;                                              col_start)
;
; AC reference: AC1 (welcome shown on no-arg launch).
;
; Sentinel code at 0xCFFE on failure: 0x9B (Story 4.2 T1).
;   Context byte (B) on failure encodes the subtest:
;     0x01 — welcome_active != 1 (fileio.no_arg did not arm the
;            flag; cross-check that the new LD A,1; LD (welcome_active),A
;            pair at fileio.asm:.no_arg actually executes)
;     0x02 — shadow_buffer[6*80+21] != 'm' (welcome_paint failed
;            to write the first 'm' of banner line 2 at the
;            horizontal-center col_start = 21; check the RLE
;            decode + welcome_emit_cell shadow write)
;     0x03 — shadow_buffer[5*80+0] != 0x20 (banner line 1 blank
;            row clobbered shadow at row 5; the 0xFF blank-row
;            marker in welcome_banner_rle should advance the row
;            counter WITHOUT touching shadow)
;     0x04 — shadow_buffer[6*80+0] != 0x20 (col 0 before col_start;
;            welcome_paint should leave it at render_init's 0x20
;            seed)
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
;; BIOS_CONOUT override: redirect welcome_paint's ESC Y + glyph
;; emits into a test-local capture buffer (welcome_paint emits
;; ~340 B which would otherwise collide with the PASS/FAIL stdout
;; grep). The capture buffer wraps at 256 B; we do NOT inspect
;; capture content here (the contract under test is shadow_buffer
;; state, not the on-the-wire byte stream).
    DEFINE BIOS_CONOUT_OVERRIDE
BIOS_CONOUT EQU test_bios_conout
;; MBB_SET_USR_INT override: not exercised by this test path
;; (fileio_load_initial does NOT touch the user ISR), but the
;; symbol must resolve since bios.inc defines it. Stub to a
;; local no-op.
    DEFINE MBB_SET_USR_INT_OVERRIDE
MBB_SET_USR_INT EQU test_mbb_set_usr_int
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----

    ;; Pre-poison the static block with 0xAA so any field
    ;; init forgets to clear surfaces as 0xAA, not as boot
    ;; residue (iz-cpm-dependent).
    LD      HL, static_data_base
    LD      (HL), 0xAA
    LD      DE, static_data_base + 1
    LD      BC, static_end - static_data_base - 1
    LDIR

    ;; Reset the capture buffer length.
    XOR     A
    LD      (test_capture_len), A

    ;; Pre-poison DEFAULT_FCB[0..11] with 0xAA.
    LD      HL, DEFAULT_FCB
    LD      (HL), 0xAA
    LD      DE, DEFAULT_FCB + 1
    LD      BC, 11
    LDIR

    ;; Write the canonical no-arg sentinel: DEFAULT_FCB + 1 = ' '.
    LD      A, ' '
    LD      (DEFAULT_FCB + 1), A

    ;; Establish gap buffer SR2-empty state and seed shadow with
    ;; 0x20 spaces (mirrors init_cold_start Stages 3+4).
    CALL    gapbuf_init
    CALL    render_init

    ;; Fire Stage 5: fileio_load_initial. With DEFAULT_FCB+1==' '
    ;; the .no_arg branch runs and sets welcome_active=1.
    CALL    fileio_load_initial

    ;; Stage 6.5 equivalent: paint the welcome banner.
    CALL    welcome_paint

    ;; --- Subtest 1: welcome_active == 1 ---
    LD      A, (welcome_active)
    CP      1
    JR      Z, .ok_active
    LD      B, 0x01
    LD      A, 0x9B
    JP      test_fail
.ok_active:

    ;; --- Subtest 2: shadow_buffer[6*80+21] == 'm' (banner line 2 first 'm'
    ;; at horizontal-center col_start = (80-38)/2 = 21) ---
    LD      A, (shadow_buffer + 6*80 + 21)
    CP      'm'
    JR      Z, .ok_glyph_m
    LD      B, 0x02
    LD      A, 0x9B
    JP      test_fail
.ok_glyph_m:

    ;; --- Subtest 3: shadow_buffer[5*80+0] == 0x20 (banner line 1 blank) ---
    LD      A, (shadow_buffer + 5*80 + 0)
    CP      0x20
    JR      Z, .ok_blank_row
    LD      B, 0x03
    LD      A, 0x9B
    JP      test_fail
.ok_blank_row:

    ;; --- Subtest 4: shadow_buffer[6*80+0] == 0x20 (col 0 before col_start) ---
    LD      A, (shadow_buffer + 6*80 + 0)
    CP      0x20
    JR      Z, .ok_pre_glyph_col
    LD      B, 0x04
    LD      A, 0x9B
    JP      test_fail
.ok_pre_glyph_col:

    JP      test_pass

;; ----- LOCAL stubs -----

;; MBB_SET_USR_INT stub (defined for symbol resolution; not called
;; on this test path since fileio_load_initial doesn't touch ISRs).
test_mbb_set_usr_int:
    RET

;; --- BIOS_CONOUT capture buffer (test_bios_conout + storage) ---
    INCLUDE "../inc/test_bios_conout_capture.inc"

;; --- init_teardown stub (defensive; not exercised here) ---
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

;; ----- input_loop stub (statusln's bdos_error_funnel target) -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
