; ============================================================
; Module: test/cases/motions_l-clamps-at-cr-byte.asm
; Purpose: Story 4.4 AC2 — verify motion_l clamps when the
;          destination byte is CR (0x0D), treating CR as a line
;          boundary equivalent to LF (CRLF tolerance).
;
;          Subtest 1: gap "abc\r\n" (5 bytes); cursor at 2 (the
;          'c' — last printable on the CRLF line). Expected:
;          cursor stays at 2 (destination at offset 3 is CR; the
;          AC2 destination-peek CR clamp must fire).
;
;          Subtest 2: gap "abc\r" (4 bytes — CR-only, no LF);
;          cursor at 2. Expected: cursor stays at 2 (same clamp).
;
;          Subtest 3 (Story 4.4 review): gap "abc\r\n" with cursor
;          poked directly to offset 3 (on the CR byte). Structurally
;          unreachable in well-formed buffers post-AC2, but the
;          cursor-on-CR defensive guard at src/motions.asm:305-306
;          must clamp anyway — symmetry with the cursor-on-LF guard.
;          Expected: cursor stays at 3.
;
; AC reference: AC2 (Story 4.4) — motion_l forward CR clamp; the
;               load-bearing fix for deferred-work.md L220.
;               Subtest 3 added 2026-05-19 review (zero-defer
;               directive) to pin the structurally-unreachable
;               defensive guard.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0x80 — subtest 1 cursor_offset != 2 (CR clamp didn't fire)
;   0x81 — subtest 1 count_accumulator not cleared
;   0x82 — subtest 2 cursor_offset != 2 (CR-only clamp didn't fire)
;   0x83 — subtest 2 count_accumulator not cleared
;   0x84 — subtest 3 cursor_offset != 3 (cursor-on-CR defensive
;          guard didn't fire — line 305-306 regression)
;   0x85 — subtest 3 count_accumulator not cleared
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"
    INCLUDE "../inc/test_prologue.inc"

    ;; ----- Subtest 1: "abc\r\n", cursor on 'c', l should clamp -----
    XOR     A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    CALL    gapbuf_init
    LD      HL, GAP_BUFFER_BASE
    LD      (HL), 'a'
    INC     HL
    LD      (HL), 'b'
    INC     HL
    LD      (HL), 'c'
    INC     HL
    LD      (HL), 0x0D
    INC     HL
    LD      (HL), 0x0A
    LD      HL, GAP_BUFFER_BASE + 5
    LD      (gap_start), HL

    LD      HL, 2
    LD      (cursor_offset), HL

    LD      A, 'l'
    CALL    motion_l

    LD      HL, (cursor_offset)
    LD      DE, 2
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor_1
    LD      A, 0x80
    JP      test_fail
.ok_cursor_1:

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count_1
    LD      A, 0x81
    JP      test_fail
.ok_count_1:

    ;; ----- Subtest 2: "abc\r" (no LF), cursor on 'c', l should clamp -----
    XOR     A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    CALL    gapbuf_init
    LD      HL, GAP_BUFFER_BASE
    LD      (HL), 'a'
    INC     HL
    LD      (HL), 'b'
    INC     HL
    LD      (HL), 'c'
    INC     HL
    LD      (HL), 0x0D
    LD      HL, GAP_BUFFER_BASE + 4
    LD      (gap_start), HL

    LD      HL, 2
    LD      (cursor_offset), HL

    LD      A, 'l'
    CALL    motion_l

    LD      HL, (cursor_offset)
    LD      DE, 2
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor_2
    LD      A, 0x82
    JP      test_fail
.ok_cursor_2:

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count_2
    LD      A, 0x83
    JP      test_fail
.ok_count_2:

    ;; ----- Subtest 3 (review): cursor poked onto CR — defensive guard -----
    XOR     A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (count_accumulator), A
    LD      (count_accumulator + 1), A
    LD      (pending_operator), A
    LD      (pending_motion_prefix), A

    CALL    gapbuf_init
    LD      HL, GAP_BUFFER_BASE
    LD      (HL), 'a'
    INC     HL
    LD      (HL), 'b'
    INC     HL
    LD      (HL), 'c'
    INC     HL
    LD      (HL), 0x0D
    INC     HL
    LD      (HL), 0x0A
    LD      HL, GAP_BUFFER_BASE + 5
    LD      (gap_start), HL

    ;; Poke cursor directly onto the CR byte. Structurally unreachable
    ;; via in-band motion post-AC2 (motion_l / motion_h / motion_dollar
    ;; all clamp before landing here), but tested defensively so any
    ;; regression of motion_l's line 305-306 guard fails loud.
    LD      HL, 3
    LD      (cursor_offset), HL

    LD      A, 'l'
    CALL    motion_l

    LD      HL, (cursor_offset)
    LD      DE, 3
    OR      A
    SBC     HL, DE
    JR      Z, .ok_cursor_3
    LD      A, 0x84
    JP      test_fail
.ok_cursor_3:

    LD      HL, (count_accumulator)
    LD      A, H
    OR      L
    JR      Z, .ok_count_3
    LD      A, 0x85
    JP      test_fail
.ok_count_3:

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
