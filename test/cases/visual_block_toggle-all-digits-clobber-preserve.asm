; ============================================================
; Module: test/cases/visual_block_toggle-all-digits-clobber-preserve.asm
; Purpose: Story 4.1 AC5 T9 — BLOCK arm no-op all-digit case pins
;          the BLOCK arm's Q3 Option A DIVERGENCE from CHAR/LINE.
;          CHAR/LINE arms preserve prior undo on a no-op walk (per
;          Story 3.8 Q3 Option A). BLOCK arm UNCONDITIONALLY records
;          UNDO_KIND_TOO_LARGE upfront via undo_clear + undo_write_header
;          (multi-region undo deferred per Q1 Option A; mirrors
;          Story 3.6 BLOCK arm precedent). So even an all-digit
;          rectangle with no actual toggles clobbers the prior undo
;          with TOO_LARGE.
;
;          This is BY DESIGN: multi-region BLOCK undo is hard, so
;          the BLOCK arm punts with TOO_LARGE which surfaces
;          msg_undo_too_large on `u`. The divergence is documented
;          here as a regression-pin.
;
;          Set up: prior UNDO_KIND_INSERT (position=5, length=3).
;          Buffer "12345XYZ" (8 B). VIS_BLOCK anchor=0 cursor=2
;          (rectangle 1 row × 3 cols on the digit prefix "123" —
;          no alpha bytes). visual_apply_case_toggle A='~'.
;          Asserts:
;            - undo_kind = UNDO_KIND_TOO_LARGE (clobbered by BLOCK
;              arm's upfront record — Q3 Option A divergence pin)
;            - prior undo_position / undo_length OVERWRITTEN
;            - buffer first 8 B unchanged
;            - subsequent op_undo: UNDO_KIND_TOO_LARGE NOT consumed
;              (Q4 Option A from Story 2.13 — TOO_LARGE replay is
;              a no-op; second `u` re-surfaces the same message)
;
;          NB: if a future story switches the BLOCK arm to
;          "preserve prior undo on no-op walk" (matching CHAR/LINE
;          Q3 Option A), this test will fail and must be updated
;          to mirror visual_tilde-undo.asm's Phase 2 assertions.
;
; Sentinel 0x99 — context byte:
;   Phase 1 (post-toggle):
;     0 — undo_kind != UNDO_KIND_TOO_LARGE (Q3 divergence regressed)
;     1 — undo_position != 0 (top_ls = 0; BLOCK arm overwrites)
;     2 — buffer first 8 B != "12345XYZ" (toggle should not mutate digits)
;   Phase 2 (post-op_undo):
;     3 — undo_kind != UNDO_KIND_TOO_LARGE (Story 2.13 Q4: kind stays)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (status_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A
    LD      (yank_kind), A
    LD      (buffer_dirty), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 8
    LDIR
    LD      HL, GAP_BUFFER_BASE + 8
    LD      (gap_start), HL

    LD      HL, 2
    LD      (cursor_offset), HL
    LD      HL, 0
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_BLOCK
    LD      (visual_submode), A

    ;; Pre-set prior UNDO_KIND_INSERT entry.
    LD      A, UNDO_KIND_INSERT
    LD      (undo_kind), A
    LD      HL, 5
    LD      (undo_position), HL
    LD      HL, 3
    LD      (undo_length), HL

    LD      A, '~'
    CALL    visual_apply_case_toggle

    LD      A, (undo_kind)
    CP      UNDO_KIND_TOO_LARGE
    JR      Z, .p1_ok_uk
    LD      A, 0x99
    LD      B, 0
    JP      test_fail
.p1_ok_uk:
    LD      HL, (undo_position)
    LD      A, H
    OR      L
    JR      Z, .p1_ok_up
    LD      A, 0x99
    LD      B, 1
    JP      test_fail
.p1_ok_up:
    LD      HL, 0
    LD      DE, .payload
    LD      B, 8
.p1_buf_loop:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .p1_buf_next
    LD      A, 0x99
    LD      B, 2
    JP      test_fail
.p1_buf_next:
    INC     HL
    INC     DE
    DJNZ    .p1_buf_loop

    ;; --- Phase 2: op_undo on TOO_LARGE — replay is no-op, kind stays ---
    LD      A, 'u'
    CALL    op_undo

    LD      A, (undo_kind)
    CP      UNDO_KIND_TOO_LARGE
    JR      Z, .p2_ok_uk
    LD      A, 0x99
    LD      B, 3
    JP      test_fail
.p2_ok_uk:
    JP      test_pass

.payload:
    DEFB    "12345XYZ"

    INCLUDE "../inc/test_epilogue.inc"

    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
