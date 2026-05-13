; ============================================================
; Module: test/inc/test_bios_conout_capture.inc
; Purpose: BIOS_CONOUT capture stub for headless render tests.
;          Replaces the production BIOS_CONOUT (which under iz-cpm
;          would forward to the host console — colliding with the
;          PASS/FAIL stdout grep) with a routine that appends every
;          emitted byte to test_capture_buffer.
;
;          Usage (in each render test, BEFORE the inc/bios.inc
;          INCLUDE):
;            BIOS_CONOUT EQU test_bios_conout
;            INCLUDE "../../inc/bios.inc"   ; IFNDEF guard skips
;                                            ; the production EQU
;          And BEFORE inspecting capture state, the test must
;          reset test_capture_len = 0 (CP/M does NOT zero TPA;
;          the DEFB below is the .com-load initial value only).
;
; Public:
;   test_bios_conout         ; routine — In: C = byte to emit;
;                              appends to buffer, increments len.
;                              Trashes: F (preserves A, BC, DE, HL).
;   test_capture_buffer      ; 256 bytes of emit-capture storage
;   test_capture_len         ; 1 byte; index of next free slot
;   TEST_CAPTURE_SIZE        ; equate, currently 256
;
; State owned (read/write):
;   test_capture_buffer, test_capture_len  (test-local only —
;                                          NOT in state.inc)
;
; Dependencies:
;   (none — purely standalone scratch)
; ============================================================

TEST_CAPTURE_SIZE EQU 256

; ----------------------------------------------------------------
; test_bios_conout
; BIOS_CONOUT override. Append C to test_capture_buffer at index
; test_capture_len, then increment test_capture_len. Preserves
; every register the production BIOS would also preserve (and
; then some — render_emit_byte's contract only requires A, BC, F
; trashable, so this stub is over-conservative on purpose).
;
; If test_capture_len wraps past 0xFF the next write lands at
; offset 0 again — harmless for the bounded emits the render
; tests produce (worst case ~50 bytes per frame in the cases
; written for this story). Tests can ASSERT len < expected if
; they need to surface buffer overflow as a fail.
;
; In:      C = byte to emit
; Out:     test_capture_buffer[test_capture_len] = C;
;          test_capture_len incremented (mod 256).
; Trashes: F (caller-saved per MC1 — A, BC, DE, HL preserved by
;          the explicit PUSH/POP fences below).
; Calls:   (none).
; ----------------------------------------------------------------
test_bios_conout:
    PUSH    AF
    PUSH    HL
    PUSH    DE
    LD      A, (test_capture_len)
    LD      H, 0
    LD      L, A
    LD      DE, test_capture_buffer
    ADD     HL, DE
    LD      (HL), C
    LD      A, (test_capture_len)
    INC     A
    LD      (test_capture_len), A
    POP     DE
    POP     HL
    POP     AF
    RET

;; --- Capture storage (initial bytes set at .com load; tests
;; ;; must reset test_capture_len = 0 before each render call) ---
test_capture_buffer:    DEFS TEST_CAPTURE_SIZE, 0
test_capture_len:       DEFB 0
