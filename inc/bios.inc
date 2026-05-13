; ============================================================
; Module: bios.inc
; Purpose: BIOS jump-table addresses, CP/M zero-page well-known
;          addresses, and the MicroBeast-specific BIOS routines
;          VIBE consumes. Pure equates — no emit. Populated in
;          Story 1.4; Story 1.12 confirmed real addresses against
;          MicroBeast BIOS 1.6+ (W1) and added the user-ISR hook.
;
; Public:
;   CP/M jump-table:  BIOS_START, BIOS_CONIN, BIOS_CONINST,
;                     BIOS_CONOUT
;   CP/M zero page:   BDOS_ENTRY, DEFAULT_FCB, DEFAULT_DMA
;   MicroBeast hook:  MBB_SET_USR_INT
;
; State owned (read/write):
;   (none — equates and BIOS-managed addresses only. The
;    VIBE-managed tick counter that resolves the Story-1.4 W1
;    deferral lives in inc/state.inc as `input_tick_counter`;
;    src/input.asm owns the ISR and the read site.)
;
; Register conventions (across public entry points):
;   (n/a)
;
; Dependencies:
;   (none — bios.inc is a leaf header in the include graph)
; ============================================================

    DEFINE BIOS_INC_LOADED   ; include-guard marker for bdos.inc

;; --- BIOS jump-table addresses (W1 confirmed — Story 1.12) ---
; The MicroBeast BIOS exposes its routines via a jump table starting
; at BIOS_START. The architecture's earlier placeholders (0xFA00 base
; per architecture lines 1097-1099) were a documented guess; the
; Story 1.12 W1 confirmation against the real MicroBeast BIOS 1.6+
; (see `src/bios_1_7.inc` for the vendor reference) pins the base at
; 0xEA00 and the slot ordering as CONIST / CONIN / CONOUT at +6 / +9
; / +0xC (the architecture's earlier placeholder had CONIN and CONIST
; swapped — easy to miss without hardware).
;
; If a future MicroBeast BIOS revision relocates the jump table, the
; vendor `bios_1_7.inc` header comment notes "If (WHEN) the BIOS
; start address changes, this will be invalidated" — re-confirm by
; reading the vendor header and updating BIOS_START here.
BIOS_START     EQU 0xEA00   ; MicroBeast BIOS 1.6+ jump-table base (W1 — Story 1.12)
BIOS_CONINST   EQU BIOS_START + 0x06   ; A = 0xFF if a byte is ready, 0x00 if not
                                       ;   (vendor symbol: BIOS_CONIST)
BIOS_CONIN     EQU BIOS_START + 0x09   ; blocking byte read from console — A = byte
; BIOS_CONOUT is wrapped in IFNDEF so test cases can override it
; (AC17 of Story 1.11). The guard tests a DEFINE-marker rather
; than the EQU symbol itself because sjasmplus 1.23.0's IFNDEF
; recognises DEFINE-created names but not EQU-created ones. Test
; cases that want a capture stub: `DEFINE BIOS_CONOUT_OVERRIDE`
; followed by `BIOS_CONOUT EQU <stub addr>` BEFORE INCLUDEing
; this header. Production code does not set the marker; the
; IFNDEF falls through to the BIOS_START + 0x0C path with zero
; effect on vibe.com bytes.
    IFNDEF BIOS_CONOUT_OVERRIDE
BIOS_CONOUT    EQU BIOS_START + 0x0C   ; emit byte in C to console
    ENDIF

;; --- CP/M zero-page well-known addresses ---
; CP/M 2.2 conventions — NOT MicroBeast-specific, NOT W1 placeholders.
BDOS_ENTRY     EQU 0x0005   ; CP/M BDOS entry; gateway via BDOS_CALL only (AR15)
DEFAULT_FCB    EQU 0x005C   ; CP/M default FCB; cmd-line filename lands here
DEFAULT_DMA    EQU 0x0080   ; CP/M default DMA — 128-byte sector buffer

;; --- MicroBeast-specific BIOS entries (vendor BIOS 1.6+) ---
; The MicroBeast BIOS exposes a small set of board-specific routines
; in a fixed-address block above the CP/M jump table. Only one entry
; is consumed by VIBE today; see `src/bios_1_7.inc` (vendor reference)
; for the full surface.
;
; MBB_SET_USR_INT is wrapped in IFNDEF so test cases can override it
; with a no-op stub (the headless harness under iz-cpm has no
; MicroBeast-specific BIOS routines — calling the real address would
; jump into uninitialised memory and crash). The override mechanism
; mirrors the Story-1.11 BIOS_CONOUT pattern: `DEFINE
; MBB_SET_USR_INT_OVERRIDE` + `MBB_SET_USR_INT EQU <stub addr>` before
; INCLUDEing this header. Production code leaves the marker unset; the
; IFNDEF falls through to the vendor address.
    IFNDEF MBB_SET_USR_INT_OVERRIDE
MBB_SET_USR_INT EQU 0xFDC7   ; install user ISR (HL = routine addr, or 0 to disable;
                             ;   HL = 0xFFFF queries the current value).
                             ;   ISR is called every 1/60 s after keyboard polling;
                             ;   the BIOS swaps the shadow register set (EXX) before
                             ;   invocation and preserves AF across the call. The
                             ;   ISR must RETurn normally and MUST NOT EXX or
                             ;   EX AF,AF' (that would corrupt the BIOS's saved
                             ;   state). Per the vendor doc: interrupt routines
                             ;   survive warm reboots, so every cold-start MUST
                             ;   defensively uninstall before installing its own
                             ;   (or before clearing the TPA region the previous
                             ;   ISR pointed at) — src/init.asm does this.
    ENDIF

;; --- Tick counter (VIBE-managed; resolves Story 1.4 W1 — Story 1.12) ---
; The architecture (line 1386) originally assumed a BIOS-managed 50 Hz
; tick counter at a fixed read-only address: `LD HL, (BIOS_TICK_ADDR)`.
; Story 1.12's W1 confirmation against MicroBeast BIOS 1.6+ found NO
; such counter at any documented address; the BIOS instead exposes the
; MBB_SET_USR_INT hook above (60 Hz, post-keyboard-poll). VIBE installs
; its own user ISR at cold-start that increments a 16-bit counter in
; the static memory map; src/input.asm's tick_wait_one reads that
; counter (declared in inc/state.inc as `input_tick_counter`).
;
; The Esc / arrow disambig timing math is unchanged: ESC_TIMEOUT_TICKS
; = 2 ticks at 60 Hz ~= 33 ms (NFR4 target 20-40 ms holds; the original
; architecture's 50 Hz assumption was 40 ms — close enough that no
; equate retune is needed). The 50 Hz comment in inc/equates.inc is
; updated to reflect the real rate.
;
; Reader contract for tick_wait_one (and any other consumer) survives
; unchanged from Story 1.4:
;   1. The 16-bit `LD HL, (input_tick_counter)` is NON-ATOMIC vs. the
;      ISR that updates it. Bracket reads in DI / EI to prevent
;      torn 16-bit reads (the ISR is the only writer).
;   2. Comparisons MUST be unsigned to handle the 0xFFFF -> 0x0000
;      wrap. Use `SBC HL, DE` + `JR C/NC`; do NOT use signed
;      `JP M / P` against the result.
;
; BIOS_TICK_ADDR is intentionally NOT EQUd here. The previous Story-1.4
; placeholder is retired; consumers read `input_tick_counter` from
; inc/state.inc directly. The named symbol stays a useful design
; landmark in this header but with no live binding — if a future BIOS
; revision exposes a real counter we re-introduce it as the canonical
; source-of-truth EQU.
