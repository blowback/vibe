; ============================================================
; Module: test/cases/edits_p-counted-mid-iter-overflow.asm
; Purpose: Code-review test P8 (2026-05-17) — counted `3p` KIND_CHAR
;          where iter 1 succeeds in full and iter 2 partially fails
;          mid-content. Pins the outer-count-loop × partial-paste
;          interaction (the existing edits_p-fills-buffer exercises
;          first-iter overflow only; this test pins iter-N>1).
;
;          Setup: GAP_BUFFER_MAX - 5 bytes of 'X' (file_length =
;          GAP_BUFFER_MAX - 5; 5 bytes free in the gap). gap_start =
;          base + max - 5; gap_end = base + max (from gapbuf_init).
;          cursor=100 (middle of payload, on 'X'). Pre-seed yank:
;          KIND_CHAR, len=3, "ABC". count_accumulator=3.
;
;          Trace: PUSH raw_entry=100; motion_byte_at_logical(100)
;          → A='X', CF=0; CP LF → not zero; INC HL → 101; LD
;          (cursor),HL → cursor=101. PUSH pre_cursor=101.
;          motion_apply_count returned BC=3.
;          - iter 1: PUSH BC=3; edits_paste_yank_bytes inserts
;            'A'@101, 'B'@102, 'C'@103; cursor → 104; HL counter
;            =3; CF=0. POP BC=3. DEC BC=2. NZ → continue.
;          - iter 2: PUSH BC=2; edits_paste_yank_bytes inserts
;            'A'@104 (cursor→105), 'B'@105 (cursor→106); TRIES
;            'C'@106 → gapbuf_insert sees gap_start==gap_end →
;            CF=1 with msg_file_too_large. Helper RET C with HL=2.
;            POP BC=2. JR C, .pc_partial.
;          .pc_partial: POP DE=pre_cursor=101; LD HL=(cursor)=106;
;          SBC HL,DE=5; OR L → nonzero; JR NZ .pc_partial_dec.
;          .pc_partial_dec: POP HL (discard raw_entry); DEC cursor
;          → 105; JP .commit.
;
;          Assert: cursor=105 (last successfully-inserted byte —
;          'B' of iter 2); buffer_dirty=1; status_dirty=1; parser
;          cleared; byte at pos 100='X' (unchanged), pos 101='A',
;          pos 102='B', pos 103='C', pos 104='A', pos 105='B'.
;
;          Pins: counted KIND_CHAR Np with mid-iter overflow;
;          outer count loop × .pc_partial DEC arm; FR52 partial-
;          paste preservation across iterations.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xB0 — cursor_offset != 105
;   0xB1 — buffer byte at pos 100 != 'X' (payload preserved at cursor-pre)
;   0xB2 — buffer byte at pos 101 != 'A' (iter 1 byte 1)
;   0xB3 — buffer byte at pos 102 != 'B' (iter 1 byte 2)
;   0xB4 — buffer byte at pos 103 != 'C' (iter 1 byte 3)
;   0xB5 — buffer byte at pos 104 != 'A' (iter 2 byte 1)
;   0xB6 — buffer byte at pos 105 != 'B' (iter 2 byte 2; cursor here)
;   0xB7 — buffer_dirty != 1
;   0xB8 — status_dirty == 0 (msg_file_too_large NOT set)
;   0xB9 — parser state not cleared
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (status_dirty), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (buffer_dirty), A
    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; Pre-load GAP_BUFFER_MAX - 5 bytes of 'X' via LDIR-propagate;
    ;; leaves a 5-byte gap.
    CALL    gapbuf_init
    LD      A, 'X'
    LD      (GAP_BUFFER_BASE), A
    LD      HL, GAP_BUFFER_BASE
    LD      DE, GAP_BUFFER_BASE + 1
    LD      BC, GAP_BUFFER_MAX - 6
    LDIR
    LD      HL, GAP_BUFFER_BASE + GAP_BUFFER_MAX - 5
    LD      (gap_start), HL

    LD      HL, 100
    LD      (cursor_offset), HL

    LD      HL, 3
    LD      (count_accumulator), HL

    LD      A, KIND_CHAR
    LD      (yank_kind), A
    LD      HL, 3
    LD      (yank_length), HL
    LD      HL, .yank_content
    LD      DE, yank_buffer
    LD      BC, 3
    LDIR

    CALL    op_paste

    LD      HL, (cursor_offset)
    LD      DE, 105
    OR      A
    SBC     HL, DE
    LD      A, H
    OR      L
    JR      Z, .ok_cursor
    LD      HL, (cursor_offset)
    LD      B, L
    LD      A, 0xB0
    JP      test_fail
.ok_cursor:

    LD      HL, 100
    CALL    motion_byte_at_logical
    CP      'X'
    JR      Z, .ok_pos100
    LD      B, A
    LD      A, 0xB1
    JP      test_fail
.ok_pos100:

    LD      HL, 101
    CALL    motion_byte_at_logical
    CP      'A'
    JR      Z, .ok_pos101
    LD      B, A
    LD      A, 0xB2
    JP      test_fail
.ok_pos101:

    LD      HL, 102
    CALL    motion_byte_at_logical
    CP      'B'
    JR      Z, .ok_pos102
    LD      B, A
    LD      A, 0xB3
    JP      test_fail
.ok_pos102:

    LD      HL, 103
    CALL    motion_byte_at_logical
    CP      'C'
    JR      Z, .ok_pos103
    LD      B, A
    LD      A, 0xB4
    JP      test_fail
.ok_pos103:

    LD      HL, 104
    CALL    motion_byte_at_logical
    CP      'A'
    JR      Z, .ok_pos104
    LD      B, A
    LD      A, 0xB5
    JP      test_fail
.ok_pos104:

    LD      HL, 105
    CALL    motion_byte_at_logical
    CP      'B'
    JR      Z, .ok_pos105
    LD      B, A
    LD      A, 0xB6
    JP      test_fail
.ok_pos105:

    LD      A, (buffer_dirty)
    CP      1
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xB7
    JP      test_fail
.ok_dirty:

    LD      A, (status_dirty)
    OR      A
    JR      NZ, .ok_status_dirty
    LD      A, 0xB8
    LD      B, 0
    JP      test_fail
.ok_status_dirty:

    LD      A, (pending_operator)
    OR      A
    JR      NZ, .parser_fail
    LD      A, (pending_motion_prefix)
    OR      A
    JR      NZ, .parser_fail
    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .parser_ok
.parser_fail:
    LD      A, 0xB9
    JP      test_fail
.parser_ok:

    JP      test_pass

.yank_content:
    DEFB    "ABC"

    INCLUDE "../inc/test_epilogue.inc"

    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"

    INCLUDE "../inc/test_teardown_stub.inc"
    INCLUDE "../inc/test_input_loop_stub.inc"
    INCLUDE "../../inc/state.inc"
