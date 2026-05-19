; ============================================================
; Module: test/cases/visual_tilde-empty-buffer.asm
; Purpose: Story 4.1 review regression-pin — AC1 file_length=0
;          guard at gapbuf_case_toggle_range entry. Drives the
;          VIS_CHAR `~` arm on an empty buffer with cursor=anchor=0,
;          which produces BC=1 at the finalise step. Without the
;          AC1 guard, gapbuf_case_toggle_range(HL=0, BC=1) on an
;          empty buffer XOR-toggles the byte at
;          GAP_BUFFER_BASE + GAP_BUFFER_MAX = yank_buffer[0]
;          (Story 3.8 caller-bound finding 1). This test pre-seeds
;          yank_buffer[0] with sentinel 0xA5 and asserts it survives
;          unchanged. Also asserts the no-op path's downstream
;          contract: mode→NORMAL, cursor=range_start=0, file_length
;          unchanged at 0, buffer_dirty unchanged at 0, and undo_kind
;          preserved (Q3 Option A — no-op path does NOT clear the
;          prior undo register).
;
;          A future refactor that reorders gapbuf_case_toggle_range's
;          entry (e.g. moves the file_length=0 RET Z past the PUSH HL
;          or drops the explicit file_length compute in favour of a
;          gap_end-only check that false-positives at cursor-at-EOF)
;          will fail context byte 2 with a non-0xA5 value at
;          yank_buffer[0].
;
; Sentinel 0x97 — context byte:
;   0 — mode_byte != MODE_NORMAL post-toggle
;   1 — cursor_offset != 0 (= range_start)
;   2 — yank_buffer[0] != 0xA5 (AC1 REGRESSION-PIN: would be XORed
;       without the file_length=0 guard at gapbuf_case_toggle_range
;       entry — closes Story 3.8 caller-bound finding 1)
;   3 — undo_kind != 0 (Q3 Option A: no-op path preserves prior undo)
;   4 — buffer_dirty != 0 (no-op does not set dirty)
;   5 — file_length != 0 (gap_start unchanged at GAP_BUFFER_BASE;
;       gap_end unchanged at GAP_BUFFER_BASE + GAP_BUFFER_MAX)
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
    LD      (undo_kind), A
    LD      (yank_kind), A
    LD      (buffer_dirty), A
    LD      HL, 0
    LD      (undo_position), HL
    LD      (undo_length), HL

    CALL    gapbuf_init

    ;; Pre-seed yank_buffer[0] with 0xA5. Without AC1's guard,
    ;; gapbuf_case_toggle_range(0, 1) on the empty buffer would
    ;; XOR-toggle this exact byte. The guard suppresses the walk
    ;; entirely (Z=1 no-op return), so the sentinel must survive.
    LD      A, 0xA5
    LD      (yank_buffer), A

    LD      HL, 0
    LD      (cursor_offset), HL
    LD      HL, 0
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_CHAR
    LD      (visual_submode), A

    LD      A, '~'
    CALL    visual_apply_case_toggle

    LD      A, (mode_byte)
    CP      MODE_NORMAL
    JR      Z, .ok_mode
    LD      A, 0x97
    LD      B, 0
    JP      test_fail
.ok_mode:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0x97
    LD      B, 1
    JP      test_fail
.ok_cursor:
    LD      A, (yank_buffer)
    CP      0xA5
    JR      Z, .ok_yank
    LD      A, 0x97
    LD      B, 2
    JP      test_fail
.ok_yank:
    LD      A, (undo_kind)
    OR      A
    JR      Z, .ok_uk
    LD      A, 0x97
    LD      B, 3
    JP      test_fail
.ok_uk:
    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      A, 0x97
    LD      B, 4
    JP      test_fail
.ok_dirty:
    ;; file_length = gap_start + GAP_BUFFER_MAX - gap_end. On the
    ;; pristine post-gapbuf_init buffer, gap_start = GAP_BUFFER_BASE
    ;; and gap_end = GAP_BUFFER_BASE + GAP_BUFFER_MAX, so the
    ;; computed file_length must still be 0.
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_MAX
    ADD     HL, DE
    LD      DE, (gap_end)
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_flen
    LD      A, 0x97
    LD      B, 5
    JP      test_fail
.ok_flen:
    JP      test_pass

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
