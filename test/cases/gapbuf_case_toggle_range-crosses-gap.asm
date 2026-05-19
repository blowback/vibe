; ============================================================
; Module: test/cases/gapbuf_case_toggle_range-crosses-gap.asm
; Purpose: Story 4.1 AC5 T7 — gapbuf_case_toggle_range straddles
;          the gap. Exercises the internal gapbuf_move_gap
;          relocation that makes the toggle region physically
;          contiguous at gap_end onwards.
;
;          Construct a buffer of file_length=5 with the gap between
;          logical offsets 2 and 3:
;            Physical [GAP_BUFFER_BASE..GAP_BUFFER_BASE+1] = "ab"
;            Gap [GAP_BUFFER_BASE+2..GAP_BUFFER_BASE+GAP_BUFFER_MAX-4]
;            Physical [gap_end..gap_end+2] = "cde"
;          Logical view: a(0) b(1) c(2) d(3) e(4).
;
;          CALL gapbuf_case_toggle_range with HL=0, BC=5 (whole
;          buffer). Internally gapbuf_move_gap(0) relocates the gap
;          to logical offset 0, making the bytes physically
;          contiguous at gap_end..gap_end+4 = "abcde", which then
;          XOR-toggle to "ABCDE".
;
;          Post-call: logical view "ABCDE", file_length unchanged
;          at 5, dirty flag Z=0 (5 alpha toggles), gap_start=0
;          (post-move_gap), gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX - 5.
;
; Sentinel 0x8F — context byte:
;   0 — Z flag set (no-op detected; primitive failed to toggle)
;   1 — logical view first 5 B != "ABCDE"
;   2 — file_length != 5 (mutated)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    ;; Construct the gap-straddled buffer directly. Skip gapbuf_init
    ;; — set up the cells by hand.
    LD      HL, GAP_BUFFER_BASE
    LD      (HL), 'a'
    INC     HL
    LD      (HL), 'b'

    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX - 3
    LD      (HL), 'c'
    INC     HL
    LD      (HL), 'd'
    INC     HL
    LD      (HL), 'e'

    LD      HL, GAP_BUFFER_BASE + 2
    LD      (gap_start), HL
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX - 3
    LD      (gap_end), HL

    LD      HL, 0
    LD      (cursor_offset), HL

    ;; Toggle the whole logical range [0..4] (BC=5).
    LD      HL, 0
    LD      BC, 5
    CALL    gapbuf_case_toggle_range
    JR      NZ, .ok_dirty
    LD      A, 0x8F
    LD      B, 0
    JP      test_fail
.ok_dirty:
    ;; Verify the logical view.
    LD      HL, 0
    LD      DE, .expect_buf
    LD      B, 5
.buf_loop:
    PUSH    DE
    PUSH    BC
    CALL    motion_byte_at_logical
    POP     BC
    POP     DE
    LD      C, A
    LD      A, (DE)
    CP      C
    JR      Z, .buf_next
    LD      A, 0x8F
    LD      B, 1
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    ;; Verify file_length still 5 (gap_start + GAP_BUFFER_MAX - gap_end == 5).
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_MAX
    ADD     HL, DE
    LD      DE, (gap_end)
    OR      A
    SBC     HL, DE                  ; HL = file_length
    LD      DE, 5
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_flen
    LD      A, 0x8F
    LD      B, 2
    JP      test_fail
.ok_flen:
    JP      test_pass

.expect_buf:
    DEFB    "ABCDE"

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
