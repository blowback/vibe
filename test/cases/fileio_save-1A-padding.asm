; ============================================================
; Module: test/cases/fileio_save-1A-padding.asm
; Purpose: AC12 — verify the EOF-pad algorithm's most important
;          boundary: a payload ending mid-sector. 100 bytes of
;          'A' (0x41) followed by 0x1A then 27 spaces fills one
;          sector cleanly. Get the algorithm wrong and either
;          the trailing 28 bytes leak garbage onto disk (FR51
;          regression) or the read-side 0x1A scan in fileio_load
;          can't find the EOF marker (FR4 round-trip regression).
;
;          The save runs against gap state populated by writing
;          100 'A' bytes directly into the before-gap region
;          (tests are AR-exempt — see fileio_save-roundtrip for
;          the same pattern).
;
; AC reference: AC12 Sub 6.3.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xF1 — status_buffer prefix mismatch (B = idx)
;   0xF2 — buffer_dirty != 0 (B = observed value)
;   0xF3 — on-disk content mismatch (B = offset of first mismatch)
;   0xF6 — funnel was entered on green save path
;   0xF7 — BDOS rc unexpected during verification (B = call site)
;   B    — diagnostic context
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"
    INCLUDE "../../inc/vt52.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----

    XOR     A
    LD      (funnel_entered), A
    LD      (init_teardown_called), A
    LD      (mode_byte), A
    LD      (status_dirty), A
    LD      (buffer_dirty), A

    CALL    gapbuf_init

    ;; Fill [BASE, BASE+100) with 'A' (0x41).
    LD      HL, GAP_BUFFER_BASE
    LD      B, 100
.fill_a:
    LD      (HL), 'A'
    INC     HL
    DJNZ    .fill_a

    ;; gap_start = BASE + 100; cursor = 100; gap_end untouched (BASE+MAX).
    LD      HL, GAP_BUFFER_BASE + 100
    LD      (gap_start), HL
    LD      HL, 100
    LD      (cursor_offset), HL

    ;; filename_buffer = "B:PAD100.TXT\0" (12 chars + NUL = 13).
    LD      HL, .filename_buf_init
    LD      DE, filename_buffer
    LD      BC, 13
    LDIR

    ;; fcb_scratch: drive 2, basename "PAD100  ", ext "TXT".
    LD      HL, fcb_scratch
    LD      DE, fcb_scratch + 1
    LD      (HL), 0
    LD      BC, 35
    LDIR
    LD      A, 2
    LD      (fcb_scratch + 0), A
    LD      HL, .fcb_basename
    LD      DE, fcb_scratch + 1
    LD      BC, 11
    LDIR

    CALL    fileio_save

    ;; --- Subtest 1: status banner ---
    LD      HL, .expected_status
    LD      DE, status_buffer
    LD      B, 30
    LD      C, 0
.cmp_status:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_status
    INC     HL
    INC     DE
    INC     C
    DJNZ    .cmp_status
    JR      .ok_status
.fail_status:
    LD      B, C
    LD      A, 0xF1
    JP      test_fail
.ok_status:

    ;; --- Subtest 2: buffer_dirty cleared ---
    LD      A, (buffer_dirty)
    OR      A
    JR      Z, .ok_dirty
    LD      B, A
    LD      A, 0xF2
    JP      test_fail
.ok_dirty:

    ;; --- Subtest 3: funnel not entered ---
    LD      A, (funnel_entered)
    OR      A
    JR      Z, .ok_funnel
    LD      B, A
    LD      A, 0xF6
    JP      test_fail
.ok_funnel:

    ;; --- Subtest 4: read sector 0, verify the layout ---
    LD      HL, .verify_fcb
    LD      DE, .verify_fcb + 1
    LD      (HL), 0
    LD      BC, 35
    LDIR
    LD      HL, fcb_scratch
    LD      DE, .verify_fcb
    LD      BC, 12
    LDIR

    LD      C, BDOS_OPEN
    LD      DE, .verify_fcb
    CALL    BDOS_ENTRY
    OR      A
    JP      M, .verify_fail
    LD      C, BDOS_SET_DMA
    LD      DE, .read_dma
    CALL    BDOS_ENTRY
    LD      C, BDOS_READ_SEQ
    LD      DE, .verify_fcb
    CALL    BDOS_ENTRY
    OR      A
    JR      NZ, .verify_fail

    ;; Bytes 0..99 = 'A'.
    LD      HL, .read_dma
    LD      C, 0
.cmp_a:
    LD      A, C
    CP      100
    JR      Z, .a_done
    LD      A, (HL)
    CP      'A'
    JR      NZ, .fail_content
    INC     HL
    INC     C
    JR      .cmp_a
.a_done:
    ;; Byte 100 = 0x1A.
    LD      A, (HL)
    CP      0x1A
    JR      NZ, .fail_content
    INC     HL
    INC     C
    ;; Bytes 101..127 = 0x20.
.cmp_pad:
    LD      A, C
    CP      128
    JR      Z, .pad_done
    LD      A, (HL)
    CP      ' '
    JR      NZ, .fail_content
    INC     HL
    INC     C
    JR      .cmp_pad
.pad_done:

    LD      C, BDOS_CLOSE
    LD      DE, .verify_fcb
    CALL    BDOS_ENTRY

    JP      test_pass

.fail_content:
    LD      B, C
    LD      A, 0xF3
    JP      test_fail
.verify_fail:
    LD      B, A
    LD      A, 0xF7
    JP      test_fail

.filename_buf_init:
    DEFB    "B:PAD100.TXT", 0
.fcb_basename:
    DEFB    "PAD100  TXT"
.expected_status:
    DEFB    "B:PAD100.TXT 100 bytes written"

.verify_fcb:
    DEFS    36, 0
.read_dma:
    DEFS    128, 0

;; ----- LOCAL init_teardown stub -----
    INCLUDE "../inc/test_teardown_stub.inc"

;; ----- LOCAL input_loop stub -----
input_loop:
    LD      A, 1
    LD      (funnel_entered), A
    LD      C, BDOS_EXIT
    CALL    BDOS_ENTRY
    RET
funnel_entered:    DEFB 0

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"
    INCLUDE "../../src/render.asm"
    INCLUDE "../../src/dispatch.asm"
    INCLUDE "../../src/parser.asm"
    INCLUDE "../../src/motions.asm"     ; Story 2.5: dispatch_normal forward-references motion_h/j/k/l
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"     ; Story 2.8: dispatch_normal forward-references edits_*, dispatch_insert table grows, unbound_insert tail-JPs edits_insert_literal
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
