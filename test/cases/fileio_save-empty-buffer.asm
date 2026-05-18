; ============================================================
; Module: test/cases/fileio_save-empty-buffer.asm
; Purpose: AC12 — verify fileio_save's empty-buffer case (0
;          payload bytes). Per AC4 Step 7 + AC7 special-case
;          rationale, the save MUST always emit an EOF sector;
;          empty-buffer thus writes ONE sector of 0x1A + 127
;          spaces. The test verifies:
;            - status banner = "B:EMPTY.TXT 0 bytes written"
;            - buffer_dirty = 0
;            - on-disk file is exactly 1 sector (128 bytes)
;            - byte 0 = 0x1A, bytes 1..127 = 0x20
;            - second READ_SEQ returns A=1 (clean EOF)
;
;          In-test verification uses raw `CALL BDOS_ENTRY` for
;          OPEN / SET_DMA / READ_SEQ / CLOSE rather than the
;          BDOS_CALL macro — tests are AR-exempt and we don't
;          want the macro's funnel to fire on the second
;          READ_SEQ's A=1 (which is not a sign-bit error, so
;          the macro's JP M wouldn't fire anyway, but raw call
;          is cleaner).
;
; AC reference: AC12 Sub 6.2.
;
; Sentinel codes at 0xCFFE on failure (TH1):
;   0xF1 — status_buffer prefix mismatch (B = idx)
;   0xF2 — buffer_dirty != 0 (B = observed value)
;   0xF3 — on-disk content byte mismatch (B = offset)
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

    CALL    gapbuf_init                     ; empty gap

    ;; filename_buffer = "B:EMPTY.TXT\0"
    LD      HL, .filename_buf_init
    LD      DE, filename_buffer
    LD      BC, 12
    LDIR

    ;; fcb_scratch: drive 2, basename "EMPTY   ", ext "TXT".
    CALL    .zero_fcb
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

    ;; --- Subtest 4: open the file and read sector 0 ---
    ;; Zero a verify-FCB then populate from our fcb_scratch.
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
    JP      M, .verify_rc_fail              ; A bit7 = 1 → can't open
    LD      C, BDOS_SET_DMA
    LD      DE, .read_dma
    CALL    BDOS_ENTRY
    LD      C, BDOS_READ_SEQ
    LD      DE, .verify_fcb
    CALL    BDOS_ENTRY
    OR      A
    JR      NZ, .verify_rc_fail             ; expect A = 0 on first sector
    ;; Verify byte 0 = 0x1A, bytes 1..127 = 0x20.
    LD      HL, .read_dma
    LD      A, (HL)
    CP      0x1A
    JR      NZ, .fail_content_byte0
    LD      C, 0                            ; offset counter for diagnostics
.cmp_pad:
    INC     HL
    INC     C
    LD      A, C
    CP      128
    JR      Z, .pad_done
    LD      A, (HL)
    CP      ' '
    JR      Z, .cmp_pad
    LD      B, C
    LD      A, 0xF3
    JP      test_fail
.pad_done:

    ;; --- Subtest 5: second READ_SEQ returns A = 1 (clean EOF) ---
    LD      C, BDOS_READ_SEQ
    LD      DE, .verify_fcb
    CALL    BDOS_ENTRY
    CP      1
    JR      Z, .ok_eof
    LD      B, A
    LD      A, 0xF7
    JP      test_fail
.ok_eof:

    LD      C, BDOS_CLOSE
    LD      DE, .verify_fcb
    CALL    BDOS_ENTRY

    JP      test_pass

.fail_content_byte0:
    LD      B, 0
    LD      A, 0xF3
    JP      test_fail
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

.filename_buf_init:
    DEFB    "B:EMPTY.TXT", 0
.fcb_basename:
    DEFB    "EMPTY   TXT"
.expected_status:
    DEFB    "B:EMPTY.TXT 0 bytes written"

;; 36-byte verify FCB used by the in-test BDOS reads (separate
;; from production fcb_scratch so we don't disturb the just-
;; populated production state).
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
    INCLUDE "../../src/motions.asm"     ; Story 2.5: dispatch_normal forward-references motion_h/j/k/l
    INCLUDE "../../src/edits.asm"
    INCLUDE "../../src/visual.asm"
    INCLUDE "../../src/search.asm"     ; Story 2.8: dispatch_normal forward-references edits_*, dispatch_insert table grows, unbound_insert tail-JPs edits_insert_literal
    INCLUDE "../../src/exline.asm"
    INCLUDE "../../src/fileio.asm"
    INCLUDE "../../src/undo.asm"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
