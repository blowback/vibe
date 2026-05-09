; ============================================================
; Module: test/smoke/bdos_call_smoke.asm
; Purpose: One-off smoke test for the BDOS_CALL macro (Story 1.4
;          AC4). Issues BDOS_CALL BDOS_OPEN against an FCB naming
;          a file that does not exist on the mounted drive. The
;          macro's `OR A : JP M, bdos_error_funnel` should detect
;          the 0xFF return, transfer control to a local stub
;          funnel, write a sentinel byte at 0xCFFE (TH1 pattern),
;          and exit cleanly via BDOS function 0.
;
;          NOT part of the Story 1.6 harness — a one-off proof
;          that the macro expands and runs. test/cases/ is owned
;          by Story 1.6 and may relocate/replace this artifact.
; ============================================================

    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"

    ORG 0x0100

    ; Pre-write a distinct "never ran" marker so the post-run sentinel
    ; at 0xCFFE unambiguously distinguishes path-taken from boot-residue.
    ;   0xAA = "smoke entered, neither path taken yet"
    ;   0x01 = "funnel path taken (PASS)"
    ;   0xEE = "success path taken (FAIL — file unexpectedly opened)"
    LD      A, 0xAA
    LD      (0xCFFE), A

    LD      DE, fcb
    BDOS_CALL BDOS_OPEN     ; expansion: LD C,15 / CALL 0005
                            ; OR A / JP M, bdos_error_funnel

    ; Reaching here means OPEN returned with bit 7 clear — i.e. it
    ; reported success (A = 0..3) for a file we expect to be absent.
    ; Mark "unexpected success" and exit.
    LD      A, 0xEE
    LD      (0xCFFE), A
    JR      smoke_exit

bdos_error_funnel:
    ; Funnel was reached as expected — write non-zero sentinel.
    LD      A, 0x01
    LD      (0xCFFE), A
    JR      smoke_exit

smoke_exit:
    LD      C, BDOS_EXIT
    CALL    BDOS_ENTRY      ; warm-boot to CCP / iz-cpm exit
    RET                     ; defensive — BDOS_EXIT does not return

;; --- FCB naming a file that cannot exist on a CP/M filesystem ---
; CP/M FCB layout: drive byte (0 = current default) + 8-byte name
; (space-padded) + 3-byte extension + 24 bytes of metadata zeros.
;
; The name uses a `?` in the first byte to ensure no real disk file
; can match: CP/M filenames disallow `?` (it's the wildcard byte in
; directory matching, illegal in actual filenames). This makes the
; "file does not exist" precondition structural rather than relying
; on the user's mount being free of any specific name.
fcb:
    DEFB 0
    DEFB "?NOFILE "
    DEFB "XXX"
    DEFS 24
