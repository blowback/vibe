; ============================================================
; Module: test/cases/undo_replay-interleaved-mutations.asm
; Purpose: Story 4.1 AC5 T10 — single-level undo replay correctness
;          under interleaved buffer history. Pin: after a sequence
;          of mutations INSERT → DELETE → REPLACE, only the MOST
;          RECENT operation (REPLACE) is undoable per Story 2.13
;          single-level undo; earlier mutations don't replay.
;
;          Setup simulates the post-sequence state directly:
;            Buffer "abc12def" (8 B) — represents the buffer
;            AFTER all three mutations have landed. The "12" at
;            offsets 3..4 is the NEW content from the REPLACE
;            (offset 3, new-length 2). The old content at the
;            replaced range was "XY" (held in undo_buffer for
;            replay).
;          Pre-set undo state mirroring what the REPLACE op would
;          have written (overwriting any prior INSERT / DELETE undo):
;            undo_kind        = UNDO_KIND_REPLACE
;            undo_position    = 3
;            undo_length      = 2 (new-content size)
;            undo_aux_length  = 2 (old-content size — same here)
;            undo_buffer      = "XY" (old content to restore)
;
;          CALL op_undo. undo_replay_replace runs phase 1
;          (edits_range_delete bytes [3..5) — removes "12") then
;          phase 2 (re-insert "XY" at offset 3). Buffer becomes
;          "abcXYdef" (8 B). cursor := 3. undo_kind := EMPTY.
;
;          The earlier INSERT / DELETE mutations were OVERWRITTEN
;          by the REPLACE — single-level undo per Story 2.13. The
;          test verifies only that the REPLACE replay works
;          correctly under the post-interleaved state.
;
; Sentinel 0x9A — context byte:
;   0 — buffer first 8 B != "abcXYdef" (replay incorrect)
;   1 — undo_kind != UNDO_KIND_EMPTY (replay should consume)
;   2 — cursor_offset != 3 (post-replay cursor)
;   3 — file_length != 8 (gap_start + GAP_BUFFER_MAX - gap_end)
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
    LD      HL, .post_seq_buffer
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 8
    LDIR
    LD      HL, GAP_BUFFER_BASE + 8
    LD      (gap_start), HL

    LD      HL, 3
    LD      (cursor_offset), HL

    ;; Pre-set REPLACE undo (overwriting any prior INSERT/DELETE).
    LD      A, UNDO_KIND_REPLACE
    LD      (undo_kind), A
    LD      HL, 3
    LD      (undo_position), HL
    LD      HL, 2
    LD      (undo_length), HL               ; new-content size = 2 ("12")
    LD      HL, 2
    LD      (undo_aux_length), HL           ; old-content size = 2 ("XY")
    LD      HL, .old_content
    LD      DE, undo_buffer
    LD      BC, 2
    LDIR

    LD      A, 'u'
    CALL    op_undo

    LD      HL, 0
    LD      DE, .expect_buf
    LD      B, 8
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
    LD      A, 0x9A
    LD      B, 0
    JP      test_fail
.buf_next:
    INC     HL
    INC     DE
    DJNZ    .buf_loop

    LD      A, (undo_kind)
    CP      UNDO_KIND_EMPTY
    JR      Z, .ok_uk
    LD      A, 0x9A
    LD      B, 1
    JP      test_fail
.ok_uk:
    LD      HL, (cursor_offset)
    LD      DE, 3
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      A, 0x9A
    LD      B, 2
    JP      test_fail
.ok_cursor:
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_MAX
    ADD     HL, DE
    LD      DE, (gap_end)
    OR      A
    SBC     HL, DE                  ; HL = file_length
    LD      DE, 8
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_flen
    LD      A, 0x9A
    LD      B, 3
    JP      test_fail
.ok_flen:
    JP      test_pass

.post_seq_buffer:
    DEFB    "abc12def"
.old_content:
    DEFB    "XY"
.expect_buf:
    DEFB    "abcXYdef"

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
