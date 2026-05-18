; ============================================================
; Module: test/cases/parser_v-dispatch.asm
; Purpose: Story 3.3 AC2 / AC10 — verify dispatch_normal['v']
;          routes to visual_enter_char end-to-end (NOT to the
;          retired enter_visual_mode and NOT falling through to
;          unbound_normal). Mirrors the shape of Story 3.1's
;          parser_slash-dispatch.asm and Story 3.2's
;          parser_n-dispatch.asm.
;
;          Pre-seed: buffer "abcde" (5 B); cursor_offset = 2;
;          mode_byte = MODE_NORMAL; status_dirty = 0x80 (sentinel
;          — proves the dispatcher actually wrote it). Drive 'v'
;          through dispatch_key with HL = dispatch_normal (unbound
;          prefix base) and B = DISPATCH_NORMAL_COUNT.
;
;          Effect: dispatch lands in visual_enter_char →
;          visual_compose_status → status_set_message. Post-call:
;          mode_byte = MODE_VISUAL; visual_submode = VIS_CHAR;
;          visual_anchor = 2 (= entry cursor); status_buffer
;          starts "-- visual -- 1" (entry char count); status_dirty
;          = 1 (overwritten by status_set_message — sentinel 0x80
;          is gone).
;
; Sentinel 0xEB — context byte:
;   0 — mode_byte != MODE_VISUAL (dispatch fell through to unbound)
;   1 — visual_submode != VIS_CHAR
;   2 — visual_anchor != 2 (anchor not pinned at entry cursor)
;   3 — status_buffer[0..13] != "-- visual -- 1"
;   4 — status_dirty == 0x80 (sentinel survives — status_set_message
;       did NOT fire, suggesting the dispatch never reached
;       visual_enter_char)
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
    LD      BC, 5
    LDIR
    LD      HL, GAP_BUFFER_BASE + 5
    LD      (gap_start), HL

    LD      HL, 2
    LD      (cursor_offset), HL

    ;; Sentinel anchor — should be re-pinned by visual_enter_char.
    LD      HL, 0xDEAD
    LD      (visual_anchor), HL

    ;; Status-dirty sentinel — should be overwritten by
    ;; status_set_message inside visual_compose_status's tail-JP.
    LD      A, 0x80
    LD      (status_dirty), A

    LD      A, MODE_NORMAL
    LD      (mode_byte), A

    ;; Drive 'v' through the NORMAL dispatcher.
    LD      A, 'v'
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    CALL    dispatch_key

    ;; Check 1: mode_byte == MODE_VISUAL.
    LD      A, (mode_byte)
    CP      MODE_VISUAL
    JR      Z, .ok_mode
    LD      A, 0xEB
    LD      B, 0
    JP      test_fail

.ok_mode:
    ;; Check 2: visual_submode == VIS_CHAR.
    LD      A, (visual_submode)
    CP      VIS_CHAR
    JR      Z, .ok_submode
    LD      A, 0xEB
    LD      B, 1
    JP      test_fail

.ok_submode:
    ;; Check 3: visual_anchor == 2 (= entry cursor).
    LD      HL, (visual_anchor)
    LD      DE, 2
    OR      A
    SBC     HL, DE
    JR      Z, .ok_anchor
    LD      A, 0xEB
    LD      B, 2
    JP      test_fail

.ok_anchor:
    ;; Check 4: status_buffer[0..13] == "-- visual -- 1".
    LD      HL, status_buffer
    LD      DE, .expect_status
    LD      B, 14
.cmp_loop:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_status
    INC     HL
    INC     DE
    DJNZ    .cmp_loop
    JR      .ok_status

.fail_status:
    LD      A, 0xEB
    LD      B, 3
    JP      test_fail

.ok_status:
    ;; Check 5: status_dirty != 0x80 (sentinel was overwritten).
    LD      A, (status_dirty)
    CP      0x80
    JR      NZ, .ok_dirty
    LD      A, 0xEB
    LD      B, 4
    JP      test_fail

.ok_dirty:
    JP      test_pass

.payload:
    DEFB    "abcde"
.expect_status:
    DEFB    "-- visual -- 1"

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
