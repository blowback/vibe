; ============================================================
; Module: test/cases/visual_block-jagged-clamp.asm
; Purpose: Story 3.5 AC9 / AC12 — CRITICAL AR14 / BH3 invariant
;          test. Verify that VIS_BLOCK selection across a SHORT
;          intermediate line:
;            (a) reports the bounding-rectangle cols dimension
;                derived from the cursor's actual column (motion_j
;                clamped to line 2's EOL — NOT the sticky col from
;                line 1; vi's column-preserve semantics);
;            (b) leaves (gap_start) UNCHANGED;
;            (c) leaves (gap_end) UNCHANGED;
;            (d) leaves the buffer bytes byte-for-byte unchanged
;                (no jagged-line padding written to the gap
;                buffer).
;
;          Buffer "abcdef\nxy\nabcdef" (16 B; line 1 = 6 chars,
;          line 2 = 2 chars, line 3 = 6 chars; LFs at 6, 9).
;          Pre-set mode_byte = MODE_VISUAL, visual_submode =
;          VIS_BLOCK, visual_anchor = 0, cursor_offset = 0.
;
;          Sequence: motion_l × 5 → cursor=5 (line 1 col 5 = 'f');
;          then motion_j with sticky col 5 against line 2 = "xy"
;          (length 2; clamp_col = 1) → cursor lands at offset 8
;          (= 'y'; col 1). cols = |1 - 0| + 1 = 2; rows = LFs in
;          [0, 7) + 1 = 1 + 1 = 2. Status = "-- visual block -- 2x2".
;
;          AR14 / BH3 invariant: NO buffer mutation, even though
;          the bounding rectangle "spans" across a line that
;          can't physically host its full column range. The
;          rectangle is virtual; the operator (Story 3.6+) is
;          responsible for per-row clipping.
;
; Sentinel 0xBC — context byte:
;   0 — post-sequence: cursor_offset != 8
;   1 — post-sequence: status_buffer mismatch ("-- visual block -- 2x2")
;   2 — (gap_start) changed across the motion sequence (AR14)
;   3 — (gap_end) changed across the motion sequence (AR14)
;   4 — buffer bytes at GAP_BUFFER_BASE[0..15] differ from the
;       original .payload (AR14 — no jagged-line padding written)
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

    ;; Populate "abcdef\nxy\nabcdef" (16 B; LFs at 6, 9).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 16
    LDIR
    LD      HL, GAP_BUFFER_BASE + 16
    LD      (gap_start), HL

    ;; Capture (gap_start) and (gap_end) sentinels for AR14 check.
    LD      HL, (gap_start)
    LD      (.saved_gap_start), HL
    LD      HL, (gap_end)
    LD      (.saved_gap_end), HL

    LD      HL, 0
    LD      (cursor_offset), HL
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_BLOCK
    LD      (visual_submode), A

    ;; motion_l × 5: cursor 0 → 1 → 2 → 3 → 4 → 5.
    LD      A, 'l'
    CALL    motion_l
    LD      A, 'l'
    CALL    motion_l
    LD      A, 'l'
    CALL    motion_l
    LD      A, 'l'
    CALL    motion_l
    LD      A, 'l'
    CALL    motion_l

    ;; motion_j: sticky col=5; line 2 = "xy" (length 2; clamp_col=1);
    ;; new_col = min(5, 1) = 1; cursor = 7 + 1 = 8.
    LD      A, 'j'
    CALL    motion_j

    ;; Check 0: cursor_offset == 8.
    LD      HL, (cursor_offset)
    LD      DE, 8
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor
    LD      A, 0xBC
    LD      B, 0
    JP      test_fail

.ok_cursor:
    ;; Check 1: status_buffer[0..21] == "-- visual block -- 2x2".
    LD      HL, status_buffer
    LD      DE, .expect_status
    LD      B, 22
.cmp_loop:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_status
    INC     HL
    INC     DE
    DJNZ    .cmp_loop
    JR      .ok_status

.fail_status:
    LD      A, 0xBC
    LD      B, 1
    JP      test_fail

.ok_status:
    ;; Check 2: (gap_start) UNCHANGED — AR14 invariant.
    LD      HL, (gap_start)
    LD      DE, (.saved_gap_start)
    OR      A
    SBC     HL, DE
    JR      Z, .ok_gap_start
    LD      A, 0xBC
    LD      B, 2
    JP      test_fail

.ok_gap_start:
    ;; Check 3: (gap_end) UNCHANGED — AR14 invariant.
    LD      HL, (gap_end)
    LD      DE, (.saved_gap_end)
    OR      A
    SBC     HL, DE
    JR      Z, .ok_gap_end
    LD      A, 0xBC
    LD      B, 3
    JP      test_fail

.ok_gap_end:
    ;; Check 4: buffer bytes at GAP_BUFFER_BASE[0..15] match the
    ;; original .payload byte-for-byte — no jagged-line padding.
    LD      HL, GAP_BUFFER_BASE
    LD      DE, .payload
    LD      B, 16
.buf_loop:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_buf
    INC     HL
    INC     DE
    DJNZ    .buf_loop
    JR      .ok_buf

.fail_buf:
    LD      A, 0xBC
    LD      B, 4
    JP      test_fail

.ok_buf:
    JP      test_pass

.payload:
    DEFB    "abcdef", 0x0A, "xy", 0x0A, "abcdef"
.expect_status:
    DEFB    "-- visual block -- 2x2"
.saved_gap_start:
    DEFW    0
.saved_gap_end:
    DEFW    0

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
