; ============================================================
; Module: test/cases/visual_line-within-line-motion-unchanged-count.asm
; Purpose: Story 3.4 AC5 / AC7 / AC10 — verify the LINE-mode
;          signature semantic: within-line motion (motion_l) does
;          NOT change the line count. The cursor advances but its
;          line-start does not — so LFs in [anchor, cursor_ls)
;          stays at 0; line count stays at 1.
;
;          Buffer "abcde\nfgh" (9 B; 2 lines; LF at 5). Pre-set
;          mode_byte = MODE_VISUAL, visual_submode = VIS_LINE,
;          visual_anchor = 0, cursor_offset = 0.
;
;          Motion sequence (5 CALL motion_l total — Story 2.5
;          contract: motion_l peeks (cursor+1), stops at the byte
;          BEFORE the LF, so on a 5-char line the cursor advances
;          0→1→2→3→4 then no-ops at 4):
;            1st: cursor = 1; line count stays 1
;            2nd: cursor = 2; line count stays 1
;            3rd: cursor = 3; line count stays 1
;            4th: cursor = 4; line count stays 1
;            5th: cursor = 4 (no-op — LF at 5 uncrossable); count stays 1
;
;          Assertions consolidated to two checkpoints (after the
;          1st motion_l and after the 5th) to keep the test lean.
;
; Sentinel 0xB9 — context byte:
;   0 — after 1st motion_l: cursor_offset != 1
;   1 — after 1st motion_l: status mismatch ("-- visual line -- 1")
;   2 — after 5 motion_l: cursor_offset != 4 (motion_l stopped at
;       the byte BEFORE the LF; 5th call was a no-op)
;   3 — after 5 motion_l: status mismatch ("-- visual line -- 1";
;       line count unchanged — within-line motions don't grow it)
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

    ;; Populate buffer "abcde\nfgh" (9 B; LF at 5).
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 9
    LDIR
    LD      HL, GAP_BUFFER_BASE + 9
    LD      (gap_start), HL

    LD      HL, 0
    LD      (cursor_offset), HL
    LD      (visual_anchor), HL

    LD      A, MODE_VISUAL
    LD      (mode_byte), A
    LD      A, VIS_LINE
    LD      (visual_submode), A

    ;; --- 1st motion_l: cursor 0 → 1; line count stays 1 ---
    LD      A, 'l'
    CALL    motion_l

    LD      HL, (cursor_offset)
    LD      DE, 1
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c1
    LD      A, 0xB9
    LD      B, 0
    JP      test_fail
.ok_c1:
    LD      HL, status_buffer
    LD      DE, .status_1
    CALL    .cmp_19
    JR      Z, .ok_s1
    LD      A, 0xB9
    LD      B, 1
    JP      test_fail
.ok_s1:

    ;; --- 4 more motion_l: cursor 1→2→3→4→4 (last is no-op);
    ;; line count stays 1 throughout (within-line) ---
    LD      A, 'l'
    CALL    motion_l
    LD      A, 'l'
    CALL    motion_l
    LD      A, 'l'
    CALL    motion_l
    LD      A, 'l'
    CALL    motion_l

    LD      HL, (cursor_offset)
    LD      DE, 4
    OR      A
    SBC     HL, DE
    JR      Z, .ok_c5
    LD      A, 0xB9
    LD      B, 2
    JP      test_fail
.ok_c5:
    LD      HL, status_buffer
    LD      DE, .status_1
    CALL    .cmp_19
    JR      Z, .ok_s5
    LD      A, 0xB9
    LD      B, 3
    JP      test_fail
.ok_s5:

    JP      test_pass

.cmp_19:
    LD      B, 19
.cmp_loop:
    LD      A, (DE)
    CP      (HL)
    RET     NZ
    INC     HL
    INC     DE
    DJNZ    .cmp_loop
    XOR     A
    RET

.payload:
    DEFB    "abcde", 0x0A, "fgh"
.status_1:
    DEFB    "-- visual line -- 1"

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
