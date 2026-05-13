; ============================================================
; Module: input.asm
; Purpose: Single keystroke acquisition (RI5). Polls BIOS_CONIN
;          for the next byte; on Esc, opens an ESC_TIMEOUT_TICKS
;          tick window (CONINST + tick counter) for an arrow-
;          key follow-up. Synthesises single-byte keycodes
;          (KEY_ARROW_UP/DOWN/LEFT/RIGHT) so the MC4 dispatch
;          contract holds (1-byte key in A, no register-passed
;          composites). PRD risk-rank-1 lives here.
;
;          Pure-BIOS module — no BDOS, no BDOS-call macro
;          (AR15: input does not invoke the BDOS entry vector
;          or the BDOS macro; AC9 grep enforces). Esc/arrow
;          timing is UAT-validated on real MicroBeast hardware
;          (AR21 carve-out — iz-cpm cannot meaningfully
;          validate the 50 Hz tick window).
;
; Public:
;   input_get_key   - read next keystroke (RI5: Esc disambig +
;                     arrow synthesis + 1-byte putback queue)
;   input_tick_isr  - 60 Hz user-ISR body installed by init.asm
;                     via MBB_SET_USR_INT; increments
;                     input_tick_counter (resolves Story 1.4 W1)
;
; State owned (read/write):
;   input_held_byte    - 1-byte putback slot (Esc + unrecognized
;                         follow-up: stash the follow-up here so
;                         the next call returns it directly,
;                         avoiding a dropped key for the common
;                         insert-Esc-then-motion vi pattern)
;   input_held_flag    - nonzero iff input_held_byte is valid
;   input_tick_counter - 16-bit counter; ISR writer
;                         (input_tick_isr) and tick_wait_one
;                         reader. Cleared by init's LDIR;
;                         ISR install / uninstall lives in init.
;
; Register conventions (across public entry points):
;   A  = output keycode (ASCII or KEY_ARROW_*); also working
;   BC = tick countdown in B; C is callee-clobbered through
;        BIOS_CONIN/CONINST (CP/M BIOS routines are not bound by
;        a register-preservation contract, so callers must assume
;        worst-case BC clobber across input_get_key)
;   HL = working / tick-counter snapshot
;   DE = working / tick-counter compare
;   F  = trashed
;   IX/IY = not used here, but BIOS may clobber per platform; treat
;        as caller-saved across input_get_key
;
; Dependencies:
;   inc/equates.inc  (ESC_TIMEOUT_TICKS)
;   inc/bios.inc     (BIOS_CONIN, BIOS_CONINST — MBB_SET_USR_INT
;                     is consumed by src/init.asm, not here)
;   inc/vt52.inc     (VT52_ESC = 0x1B — first-byte compare)
;   inc/modes.inc    (KEY_ARROW_UP / DOWN / LEFT / RIGHT)
;   inc/state.inc    (input_held_byte, input_held_flag,
;                     input_tick_counter — the third field
;                     added by Story 1.12 to back the user-ISR
;                     tick increments)
; ============================================================

;; ============================================================
;; --- Public entry points ---
;; ============================================================

; ----------------------------------------------------------------
; input_get_key
; Read the next keystroke from the BIOS, performing Esc/arrow
; disambiguation per RI5 and synthesising single-byte arrow
; keycodes. If a previous call queued a follow-up byte (Esc +
; unrecognised pattern, AC6), return that queued byte first
; without polling BIOS_CONIN.
;
; In:      (none)
; Out:     A = single-byte keycode (ASCII 0x00-0x7F or
;          KEY_ARROW_* 0x80-0x83). VT52_ESC (0x1B) on bare-Esc.
; Trashes: A, BC, DE, HL, F (C via BIOS_CONIN/CONINST — see header)
; Calls:   tick_wait_one, synthesize_arrow_key (internal)
; ----------------------------------------------------------------
input_get_key:
    LD      A, (input_held_flag)
    OR      A
    JR      Z, .no_held
    ;; --- queue path: pop and return ---
    XOR     A
    LD      (input_held_flag), A          ; clear flag first
    LD      A, (input_held_byte)
    RET                                   ; queued byte returned

.no_held:
    CALL    BIOS_CONIN              ; A = first byte (blocking)
    CP      VT52_ESC                ; was it Esc?
    RET     NZ                      ; not Esc — printable / ctrl, return as-is (AC2/AC3)

    ;; --- Esc seen — start tick-window poll (AC4 / AC5 / AC6) ---
    LD      B, ESC_TIMEOUT_TICKS    ; default 2 ticks (~40 ms, NFR4)
.esc_poll:
    CALL    BIOS_CONINST            ; A = nonzero iff byte ready
    OR      A
    JR      NZ, .have_followup
    CALL    tick_wait_one           ; block until next 50 Hz tick
    DJNZ    .esc_poll
    ;; --- final poll after the last tick wait: a follow-up that
    ;; landed in the BIOS ring during the very last tick is a
    ;; legit arrow-suffix; without this check it would be read as
    ;; a fresh keystroke on the next call (AC5 boundary case).
    CALL    BIOS_CONINST
    OR      A
    JR      NZ, .have_followup
    ;; --- timeout: bare Esc (AC4) ---
    LD      A, VT52_ESC
    RET

.have_followup:
    CALL    BIOS_CONIN              ; A = follow-up byte (consumed)
    CALL    synthesize_arrow_key    ; CF=0 hit (A=KEY_ARROW_*); CF=1 miss (A unchanged)
    RET     NC                      ; recognised arrow — A holds synthesised code (AC5)

    ;; --- AC6: unrecognised follow-up — queue + return bare Esc ---
    LD      (input_held_byte), A    ; stash follow-up FIRST (before flag)
    LD      A, 1
    LD      (input_held_flag), A    ; mark queue valid
    LD      A, VT52_ESC             ; report bare Esc this call
    RET

; ----------------------------------------------------------------
; input_tick_isr
; 60 Hz user-interrupt body installed by src/init.asm's cold-start
; via MBB_SET_USR_INT. The BIOS swaps the shadow register set in
; via EXX before invocation and preserves AF across the call; the
; ISR is free to use HL / BC / DE (the shadow set) without saving,
; but MUST NOT EXX or EX AF,AF' (that would corrupt the BIOS's
; saved state) and MUST RETurn normally.
;
; Resolves the Story 1.4 W1 deferral: the MicroBeast BIOS does not
; expose a free-running tick counter at any fixed address; VIBE
; maintains its own via this ISR + the state.inc-resident
; input_tick_counter. tick_wait_one reads the counter directly.
;
; Wrap: input_tick_counter is 16-bit and wraps 0xFFFF -> 0x0000
; roughly every 18 minutes at 60 Hz. tick_wait_one's unsigned
; SBC-delta compare is wrap-safe (Story 1.8 reader contract).
;
; In:      (none — fires on BIOS interrupt timer, ~60 Hz)
; Out:     input_tick_counter += 1 (mod 0x10000)
; Trashes: (none observable to the foreground) — body uses only
;          `LD HL,(nn) / INC HL / LD (nn),HL / RET`, none of
;          which affect F. The shadow-set HL IS written but the
;          BIOS swaps the shadow set back via EXX on return, so
;          main HL is intact.
; Calls:   (none)
; ----------------------------------------------------------------
input_tick_isr:
    LD      HL, (input_tick_counter)
    INC     HL
    LD      (input_tick_counter), HL
    RET

;; ============================================================
;; --- Internal helpers ---
;; ============================================================

; ----------------------------------------------------------------
; synthesize_arrow_key
; Map a VT52 Esc-suffix byte to the synthesised single-byte
; arrow keycode (KEY_ARROW_*) per RI5/V1. Recognised: 'A'..'D'.
; All other bytes return CF=1 (miss) with A preserved so the
; caller can queue the original byte.
;
; In:      A = follow-up byte (consumed by BIOS_CONIN)
; Out:     CF = 0, A = KEY_ARROW_UP/DOWN/LEFT/RIGHT on hit;
;          CF = 1, A unchanged on miss.
; Trashes: F (and A on hit only)
; Calls:   (none)
; ----------------------------------------------------------------
synthesize_arrow_key:
    CP      'A'
    JR      Z, .up
    CP      'B'
    JR      Z, .down
    CP      'C'
    JR      Z, .right
    CP      'D'
    JR      Z, .left
    SCF
    RET                             ; miss: CF=1, A unchanged
.up:
    LD      A, KEY_ARROW_UP
    OR      A                       ; CF=0 (LD A,imm leaves CF untouched)
    RET
.down:
    LD      A, KEY_ARROW_DOWN
    OR      A
    RET
.right:
    LD      A, KEY_ARROW_RIGHT
    OR      A
    RET
.left:
    LD      A, KEY_ARROW_LEFT
    OR      A
    RET

; ----------------------------------------------------------------
; tick_wait_one
; Block until the BIOS-managed 50 Hz tick counter advances by
; at least one tick from its value at routine entry. The
; underlying counter is at BIOS_TICK_ADDR (per inc/bios.inc).
;
; The tick counter is 16 bits and wraps from 0xFFFF to 0x0000
; every ~21.8 minutes. We compare deltas via SBC HL, DE — any
; nonzero delta unblocks (the wrap survives because we exit on
; "differs", not on "reaches a target value"). Reads are
; bracketed by DI/EI per the inc/bios.inc reader contract
; (lines 51-65) — the ISR is the only writer, so DI/EI is the
; cheap mitigation against torn 16-bit reads.
;
; In:      (none)
; Out:     (none — side effect: blocks ~20 ms)
; Trashes: A, DE, HL, F
; Calls:   (none)
; ----------------------------------------------------------------
tick_wait_one:
    DI
    LD      DE, (input_tick_counter)  ; snapshot tick at entry
    EI
.spin:
    DI
    LD      HL, (input_tick_counter)  ; current tick
    EI
    OR      A                       ; clear CF (SBC reads it)
    SBC     HL, DE                  ; HL = current - snapshot (wrap-safe)
    JR      Z, .spin                ; same tick — keep spinning
    RET                             ; differs — at least one tick passed
