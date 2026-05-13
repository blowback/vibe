; ============================================================
; Module: bdos.inc
; Purpose: CP/M 2.2 BDOS function numbers and the BDOS_CALL
;          macro — the project-wide gateway for every BDOS
;          interaction (AR15 / MC6 / NFR8: no raw CALL 0x0005
;          anywhere). Pure equates + macro definition — no emit.
;          Populated in Story 1.4.
;
; Public:
;   Function numbers: BDOS_EXIT, BDOS_CONOUT, BDOS_OPEN,
;                     BDOS_CLOSE, BDOS_DELETE, BDOS_READ_SEQ,
;                     BDOS_WRITE_SEQ, BDOS_MAKE, BDOS_SET_DMA
;   Macro:            BDOS_CALL
;
; State owned (read/write):
;   (none)
;
; Register conventions (across public entry points):
;   BDOS_CALL — see its documentation block below.
;
; Dependencies:
;   inc/bios.inc (BDOS_ENTRY) — guarded include below makes this header
;                              self-contained when INCLUDEd standalone
; ============================================================

    IFNDEF BIOS_INC_LOADED
        INCLUDE "bios.inc"
    ENDIF

;; --- CP/M 2.2 BDOS function numbers (NFR15 — only 2.2 functions used) ---
; FCB ops (OPEN/CLOSE/DELETE/MAKE) return A = 0..3 success / 0xFF fail.
; READ_SEQ / WRITE_SEQ return A = 0 success / 1 EOF or partial / 2-9 err.
; BDOS_CALL's JP M only catches the sign-bit (0xFF) family; positive
; failure codes from READ/WRITE_SEQ require a caller-side A check.
BDOS_EXIT       EQU 0    ; system reset / warm-boot return to CCP
BDOS_CONOUT     EQU 2    ; print byte in E — enumerated for AC2 completeness; console path uses BIOS-direct, do not call
BDOS_OPEN       EQU 15   ; open file: DE = FCB; A = 0..3 ok / 0xFF fail
BDOS_CLOSE      EQU 16   ; close file: DE = FCB; A = 0..3 ok / 0xFF fail
BDOS_DELETE     EQU 19   ; delete file: DE = FCB; A = 0..3 ok / 0xFF fail
BDOS_READ_SEQ   EQU 20   ; read sector to DMA: DE = FCB; A = 0 ok / 1 EOF
BDOS_WRITE_SEQ  EQU 21   ; write sector from DMA: DE = FCB; A = 0 ok / 1+ err
BDOS_MAKE       EQU 22   ; create file: DE = FCB; A = 0..3 ok / 0xFF fail
BDOS_SET_DMA    EQU 26   ; set DMA address: DE = DMA buffer addr; A = 0 (always)

;; --- BDOS_CALL macro (MC6 / AR15 / NFR8) ---
; The single, project-wide gateway to BDOS. Raw `CALL 0x0005` (or
; `CALL BDOS_ENTRY` outside this macro) is forbidden by AR15 — every
; BDOS call site MUST use BDOS_CALL so the rc check is automatic.
;
; Expansion (per architecture line 543-548, MC6):
;     LD   C, fn
;     CALL BDOS_ENTRY        ; 0x0005 from inc/bios.inc
;     OR   A                 ; sign flag set if A bit 7 is set (0xFF)
;     JP   M, bdos_error_funnel
;
; Caller contract:
;   In:      DE = FCB / param ptr (per BDOS function); other regs as
;            documented per BDOS function.
;   Out:     A = BDOS rc.
;            On sign-bit rc (0xFF): control transfers to
;            bdos_error_funnel — this expansion never returns
;            normally on a sign-bit return.
;            On non-sign rc (0..0x7F): caller MUST inspect A.
;            Examples: READ_SEQ rc=1 (EOF), WRITE_SEQ rc=1-2
;            (disk-full / read-only) — bit 7 clear, JP M does not
;            fire, caller branches on A.
;   Trashes: A, BC, DE, HL, F (BDOS function-specific contract)
;
; Caller MUST pass `fn` as a bareword token or numeric expression
; (e.g. BDOS_OPEN, 15, BDOS_OPEN+0). Macro args are textual
; substitution: parenthesising `fn` (e.g. BDOS_CALL (BDOS_OPEN))
; expands to `LD C, (BDOS_OPEN)` — a 16-bit memory load from
; address 15, silently dispatching the wrong BDOS function.
;
; bdos_error_funnel is a FORWARD REFERENCE resolved by Story 1.5
; (statusln.asm or sibling). Selects an error message by function
; number, routes through status_set_message (MC5), then aborts the
; current operation (returns to the input loop — never crashes,
; NFR5 / NFR8). For Story 1.4 the macro is defined only; no
; expansion site exists yet (vibe.com stays byte-identical, AC5).
;
; AR22: macro name UPPER_SNAKE per "equates and macros UPPER_SNAKE_CASE".

BDOS_CALL MACRO fn
    LD      C, fn
    CALL    BDOS_ENTRY
    OR      A
    JP      M, bdos_error_funnel
    ENDM
