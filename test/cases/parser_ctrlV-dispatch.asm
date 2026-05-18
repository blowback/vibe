; ============================================================
; Module: test/cases/parser_ctrlV-dispatch.asm
; Purpose: Story 3.5 AC1 / AC12 — verify dispatch_normal[0x16]
;          (Ctrl-V) routes to visual_enter_block end-to-end (NOT
;          falling through to unbound_normal). Mirrors the shape
;          of parser_V-dispatch.asm (Story 3.4), parser_v-dispatch.asm
;          (Story 3.3), parser_n-dispatch.asm (Story 3.2), and
;          parser_slash-dispatch.asm (Story 3.1).
;
;          Pre-seed: buffer "hello\nworld" (11 B; LF at 5);
;          cursor_offset = 3 (line 1 col 3 = 'l'); mode_byte =
;          MODE_NORMAL; status_dirty = 0x80 (sentinel — proves
;          status_set_message wrote it). Drive 0x16 through
;          dispatch_key with HL = dispatch_normal and B =
;          DISPATCH_NORMAL_COUNT.
;
;          Effect: dispatch lands in visual_enter_block →
;          visual_anchor = cursor_offset = 3 (offset space — NOT
;          line-start 0; AC2 BLOCK semantic) →
;          visual_compose_status_block → status_set_message.
;
; Sentinel 0xED — context byte:
;   0 — mode_byte != MODE_VISUAL (dispatch fell through to unbound
;       or visual_enter_block didn't write mode)
;   1 — visual_submode != VIS_BLOCK
;   2 — visual_anchor != 3 (entry cursor offset; NOT line-start 0;
;       KEY VIS_BLOCK semantic — anchor lives in offset space)
;   3 — cursor_offset != 3 (Ctrl-V must NOT move cursor on entry)
;   4 — status_buffer[0..21] != "-- visual block -- 1x1" (22 chars)
;   5 — status_dirty == 0x80 (sentinel survives — status_set_message
;       did NOT fire, suggesting dispatch never reached
;       visual_enter_block)
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    XOR     A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A
    LD      (pending_motion_inclusive), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (buffer_dirty), A
    LD      (command_submode), A
    LD      (ex_buffer), A
    LD      (visual_submode), A

    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 11
    LDIR
    LD      HL, GAP_BUFFER_BASE + 11
    LD      (gap_start), HL

    LD      HL, 3
    LD      (cursor_offset), HL

    ;; Sentinel anchor — should be re-pinned to cursor=3 (NOT
    ;; line-start 0; the KEY VIS_BLOCK semantic distinction).
    LD      HL, 0xDEAD
    LD      (visual_anchor), HL

    ;; Status-dirty sentinel — should be overwritten by
    ;; status_set_message inside visual_compose_status_block's tail-JP.
    LD      A, 0x80
    LD      (status_dirty), A

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; Drive 0x16 (Ctrl-V) through the NORMAL dispatcher.
    LD      A, 0x16
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key

    ;; Check 1: mode_byte == MODE_VISUAL.
    LD      A, (mode_byte)
    CP      MODE_VISUAL
    JR      Z, .ok_mode
    LD      A, 0xED
    LD      B, 0
    JP      test_fail

.ok_mode:
    ;; Check 2: visual_submode == VIS_BLOCK.
    LD      A, (visual_submode)
    CP      VIS_BLOCK
    JR      Z, .ok_submode
    LD      A, 0xED
    LD      B, 1
    JP      test_fail

.ok_submode:
    ;; Check 3: visual_anchor == 3 (entry cursor offset; NOT 0 =
    ;; line-start; KEY VIS_BLOCK semantic — anchor in offset space).
    LD      HL, (visual_anchor)
    LD      DE, 3
    OR      A
    SBC     HL, DE
    JR      Z, .ok_anchor
    LD      A, 0xED
    LD      B, 2
    JP      test_fail

.ok_anchor:
    ;; Check 4: cursor_offset still 3 (Ctrl-V must not move cursor).
    LD      HL, (cursor_offset)
    LD      DE, 3
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor
    LD      A, 0xED
    LD      B, 3
    JP      test_fail

.ok_cursor:
    ;; Check 5: status_buffer[0..21] == "-- visual block -- 1x1".
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
    LD      A, 0xED
    LD      B, 4
    JP      test_fail

.ok_status:
    ;; Check 6: status_dirty != 0x80 (sentinel was overwritten).
    LD      A, (status_dirty)
    CP      0x80
    JR      NZ, .ok_dirty
    LD      A, 0xED
    LD      B, 5
    JP      test_fail

.ok_dirty:
    JP      test_pass

.payload:
    DEFB    "hello", 0x0A, "world"
.expect_status:
    DEFB    "-- visual block -- 1x1"

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
