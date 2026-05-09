; ============================================================
; Module: bios.inc
; Purpose: BIOS jump-table addresses, CP/M zero-page well-known
;          addresses, and the BIOS-managed tick-counter address.
;          Pure equates — no emit. Populated in Story 1.4.
;
; Public:
;   BIOS jump table:  BIOS_CONIN, BIOS_CONINST, BIOS_CONOUT
;   CP/M zero page:   BDOS_ENTRY, DEFAULT_FCB, DEFAULT_DMA
;   Tick counter:     BIOS_TICK_ADDR
;
; State owned (read/write):
;   (none — equates and BIOS-managed addresses only)
;
; Register conventions (across public entry points):
;   (n/a)
;
; Dependencies:
;   (none — bios.inc is a leaf header in the include graph)
; ============================================================

    DEFINE BIOS_INC_LOADED   ; include-guard marker for bdos.inc

;; --- BIOS jump-table addresses (W1 — placeholders, confirm in Story 1.12) ---
; The MicroBeast BIOS exposes its routines via a jump table at fixed
; addresses high in memory. The values below are documented placeholders
; per architecture lines 1097-1099; the actual addresses must be
; confirmed against MicroBeast BIOS docs / disassembly when init.asm
; wires hardware bring-up in Story 1.12 (Watchpoint W1, architecture
; lines 1635-1637). Until then no code expands these — wrong values
; are inert at assembly time, but MUST be corrected before Story 1.12
; or the editor will not run on real hardware.
BIOS_CONIN     EQU 0xFA06   ; blocking byte read from console
BIOS_CONINST   EQU 0xFA09   ; nonzero in A if a byte is ready
BIOS_CONOUT    EQU 0xFA0C   ; emit byte in C to console

;; --- CP/M zero-page well-known addresses ---
; CP/M 2.2 conventions — NOT MicroBeast-specific, NOT W1 placeholders.
BDOS_ENTRY     EQU 0x0005   ; CP/M BDOS entry; gateway via BDOS_CALL only (AR15)
DEFAULT_FCB    EQU 0x005C   ; CP/M default FCB; cmd-line filename lands here
DEFAULT_DMA    EQU 0x0080   ; CP/M default DMA — 128-byte sector buffer

;; --- Tick counter (BIOS-managed, read-only — W1 placeholder) ---
; The MicroBeast 50 Hz timer ISR maintains a free-running 16-bit tick
; counter at this address. Used by Story 1.8 (input layer / RI5 / NFR4)
; to time the ESC_TIMEOUT_TICKS window for Esc / arrow disambiguation.
; Architecture line 1386 names the symbol exactly: LD HL, (BIOS_TICK_ADDR).
; Confirm address in Story 1.12 alongside the BIOS jump-table addresses
; above.
;
; Reader contract for Story 1.8 (and any other consumer):
;   1. The 16-bit `LD HL, (BIOS_TICK_ADDR)` is NON-ATOMIC vs. the ISR
;      — the ISR can fire between the L and H byte cycles and produce
;      a torn read off by 0x100 (~5 s at 50 Hz). Mitigate by reading
;      twice and retrying on mismatch (or by bracketing the read in
;      DI / EI; cheaper since the ISR is the only writer):
;          DI
;          LD   HL, (BIOS_TICK_ADDR)
;          EI
;   2. Comparisons MUST be unsigned to handle the 0xFFFF→0x0000 wrap
;      (~21.8 minutes). Use `SBC HL, DE` (HL-DE → carry-free unsigned
;      delta) and `JR C,...` / `JR NC,...`; do NOT use signed `JP M` /
;      `JP P` against the result — wrap inverts the sign bit. Same
;      trap GAP_BUFFER_MAX flagged in story 1.3.
BIOS_TICK_ADDR EQU 0xFA00   ; placeholder — confirm in Story 1.12 (W1)
