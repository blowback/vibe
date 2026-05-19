; ============================================================
; Module: test/cases/fileio_save-crlf-roundtrip.asm
; Purpose: Story 4.4 AC5 — verify CRLF round-trip fidelity. A gap
;          buffer containing `"abc\r\nxyz\r\n"` (10 bytes, 2 CR
;          bytes at offsets 3 and 8) must save back to disk with
;          every byte preserved verbatim — no save-side CR
;          canonicalization. fileio_save is invariant under Story
;          4.4 (it walks gap_start / gap_end and emits bytes
;          verbatim); this test pins that invariant so a future
;          story can't accidentally introduce a write-side filter.
;
;          Setup:
;            - gap buffer = "abc\r\nxyz\r\n" at logical [0..9]
;            - filename "B:CRLF.TXT"
;          Verify (Option A round-trip-fidelity regression-pin):
;            - status banner = "B:CRLF.TXT 10 bytes written"
;            - buffer_dirty cleared
;            - on-disk first 10 bytes match the gap exactly
;              (specifically: byte 3 = 0x0D, byte 4 = 0x0A,
;               byte 8 = 0x0D, byte 9 = 0x0A — CRs preserved)
;            - bytes 10..127 = 0x1A then 0x20-pad (CP/M soft-EOF
;              shape per Story 2.4 AC12 — fileio_save always emits
;              one EOF sector even when payload < 128 B)
;
; AC reference: AC5 (Story 4.4); also pins AC1 of fileio_save
;               (write side untouched by Story 4.4).
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xF1 — status banner mismatch (B = idx into status_buffer)
;   0xF2 — buffer_dirty != 0
;   0xF3 — on-disk byte mismatch in the 10-byte payload (B = offset)
;   0xF4 — on-disk byte 10 != 0x1A (soft-EOF marker missing)
;   0xF5 — on-disk pad byte != 0x20 (B = offset 11..127)
;   0xF6 — funnel entered on green save path
;   0xF7 — BDOS rc unexpected during verification (B = call-site
;          context byte)
;   B    — diagnostic
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

    ;; gap state: 10-byte payload at GAP_BUFFER_BASE..+9.
    CALL    gapbuf_init
    LD      HL, .payload
    LD      DE, GAP_BUFFER_BASE
    LD      BC, 10
    LDIR
    LD      HL, GAP_BUFFER_BASE + 10
    LD      (gap_start), HL
    ;; gap_end stays at GAP_BUFFER_BASE + GAP_BUFFER_MAX from
    ;; gapbuf_init — no after-gap content.

    ;; Mark buffer dirty so the save path actually executes the
    ;; write (mirrors how :w runs after an edit).
    LD      A, 1
    LD      (buffer_dirty), A

    ;; filename_buffer = "B:CRLF.TXT\0" (11 bytes including NUL).
    LD      HL, .filename_buf_init
    LD      DE, filename_buffer
    LD      BC, 11
    LDIR

    ;; fcb_scratch: drive 2 (B:), basename "CRLF    TXT".
    CALL    .zero_fcb
    LD      A, 2
    LD      (fcb_scratch + 0), A
    LD      HL, .fcb_basename
    LD      DE, fcb_scratch + 1
    LD      BC, 11
    LDIR

    ;; Story 4.4 review: BDOS_DELETE any stale B:CRLF.TXT from a
    ;; prior run before the save. Without this, a green save in
    ;; a prior pass leaves an identical 128-B sector on disk; a
    ;; future regression that breaks fileio_save (e.g. no-op write
    ;; when content matches) would round-trip successfully against
    ;; the leftover file and mask the bug. BDOS_DELETE rc is
    ;; ignored: 0..3 = entries-removed (ok), 0xFF = file not
    ;; found (also ok on first-ever run / post-clean state).
    LD      C, BDOS_DELETE
    LD      DE, fcb_scratch
    CALL    BDOS_ENTRY

    CALL    fileio_save

    ;; --- Subtest 1: status banner ---
    LD      HL, .expected_status
    LD      DE, status_buffer
    LD      B, 27
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

    ;; --- Subtest 4: open file + read sector 0; verify exact bytes ---
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
    JP      M, .verify_rc_fail              ; can't open
    LD      C, BDOS_SET_DMA
    LD      DE, .read_dma
    CALL    BDOS_ENTRY
    LD      C, BDOS_READ_SEQ
    LD      DE, .verify_fcb
    CALL    BDOS_ENTRY
    OR      A
    JR      NZ, .verify_rc_fail             ; expect A = 0 on first sector

    ;; Verify on-disk bytes 0..9 match .payload exactly (the
    ;; load-bearing CR-preservation assertion).
    LD      HL, .payload
    LD      DE, .read_dma
    LD      B, 10
    LD      C, 0
.cmp_payload:
    LD      A, (DE)
    CP      (HL)
    JR      NZ, .fail_payload
    INC     HL
    INC     DE
    INC     C
    DJNZ    .cmp_payload
    JR      .ok_payload
.fail_payload:
    LD      B, C
    LD      A, 0xF3
    JP      test_fail
.ok_payload:

    ;; Verify byte 10 = 0x1A (CP/M soft-EOF marker).
    LD      A, (.read_dma + 10)
    CP      0x1A
    JR      Z, .ok_eof_marker
    LD      B, 10
    LD      A, 0xF4
    JP      test_fail
.ok_eof_marker:

    ;; Verify bytes 11..127 = 0x20 (sector padding).
    LD      HL, .read_dma + 11
    LD      C, 11
.cmp_pad:
    LD      A, C
    CP      128
    JR      Z, .pad_done
    LD      A, (HL)
    CP      0x20
    JR      Z, .next_pad
    LD      B, C
    LD      A, 0xF5
    JP      test_fail
.next_pad:
    INC     HL
    INC     C
    JR      .cmp_pad
.pad_done:

    LD      C, BDOS_CLOSE
    LD      DE, .verify_fcb
    CALL    BDOS_ENTRY

    JP      test_pass

.verify_rc_fail:
    LD      B, A
    LD      A, 0xF7
    JP      test_fail

;; Zero the production fcb_scratch in-test. AR-exempt.
.zero_fcb:
    LD      HL, fcb_scratch
    LD      DE, fcb_scratch + 1
    LD      (HL), 0
    LD      BC, 35
    LDIR
    RET

.payload:
    DEFB    "abc", 0x0D, 0x0A, "xyz", 0x0D, 0x0A
.filename_buf_init:
    DEFB    "B:CRLF.TXT", 0
.fcb_basename:
    DEFB    "CRLF    TXT"
.expected_status:
    DEFB    "B:CRLF.TXT 10 bytes written"

;; 36-byte verify FCB used by the in-test BDOS reads.
.verify_fcb:
    DEFS    36, 0
;; 128-byte scratch DMA buffer for the in-test sector read.
.read_dma:
    DEFS    128, 0

;; ----- LOCAL init_teardown stub -----
    INCLUDE "../inc/test_teardown_stub.inc"

;; ----- LOCAL input_loop stub: set sentinel on funnel entry -----
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
    INCLUDE "../../src/motions.asm"
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
