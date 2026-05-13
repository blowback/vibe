; ============================================================
; Module: init.asm
; Purpose: Cold-start and teardown for vibe.com. The .com entry
;          at 0x0100 in src/vibe.asm `JP init_cold_start`s here;
;          init_cold_start zeroes the whole state.inc static
;          block (resolves the Story 1.3 / 1.8 zero-init
;          deferrals), then calls each sub-system's init entry
;          in AR25 order — gapbuf_init (SR2), render_init
;          (screen clear + shadow seed + cursor home),
;          status_set_message msg_mode_normal (seed status_dirty
;          for the first render pass), render_full (initial
;          frame) — and falls through to the main input loop.
;
;          init_teardown is the symmetric exit path: routes the
;          screen-clear through render_init (so AR13's "render
;          owns the single screen-emission path" stays single-
;          sited) and warm-boots to CCP via BDOS function 0.
;          Reached via tail-JP from cmd_quit / cmd_quit_force
;          in src/exline.asm — the Story-2.1 :q / :q! handlers
;          that retired the Story-1.12 mode_debug_quit bring-up
;          shim.
;
;          Architectural carve-outs enforced here:
;            AR13 — init.asm does NOT call the BIOS console-out
;                   entry. The Story-1.11-retired carve-out for
;                   an init-side initial clear stays retired:
;                   render_init absorbs the ESC J emit, and
;                   init_teardown's screen-clear-on-exit also
;                   routes through render_init.
;            AR14 — init.asm does NOT invoke the gap-buffer
;                   mutators (the insert / delete / move-gap
;                   entries). The only gap-buffer entry point
;                   this module touches is gapbuf_init
;                   (idempotent SR2-establishing reset to the
;                   empty-buffer state).
;            AR15 — init.asm's sole BDOS use site is the
;                   gateway-macro expansion inside
;                   init_teardown that warm-boots via function
;                   0. No raw call to the BDOS entry vector;
;                   no other BDOS function number is referenced
;                   (AR15 + NFR15).
;
; Public:
;   init_cold_start   ; ORG 0x0100 entry-point target; falls
;                     ; through to input_loop (no RET).
;                     ; Defensively uninstalls any pre-existing
;                     ; user ISR before the LDIR fill, then
;                     ; installs input_tick_isr via
;                     ; MBB_SET_USR_INT (resolves Story 1.4 W1).
;   init_teardown     ; cmd_quit / cmd_quit_force's tail-JP
;                     ; target (src/exline.asm); warm-boots
;                     ; to CCP via BDOS function 0 (no return
;                     ; on a real CP/M host; defensive RET).
;                     ; Uninstalls input_tick_isr before the
;                     ; warm-boot so the BIOS does not call
;                     ; into TPA memory CCP is about to reuse.
;
; State owned (read/write):
;   (none — init.asm performs a one-shot zero-init across the
;    whole state.inc block at cold-start but does not OWN any
;    field across the editor's lifetime. Ownership of each
;    field stays with the module that authored it in
;    Stories 1.3 / 1.5 / 1.7 / 1.8 / 1.10 / 1.11.)
;
; State read-only:
;   mode_byte — read implicitly: the stage-1 LDIR fills the
;     entire static block with 0x00, and MODE_NORMAL is EQUd to
;     0 in inc/modes.inc, so the post-fill mode_byte value IS the
;     editor's initial mode. No explicit `LD A, (mode_byte)` in
;     init.asm; the dependency is on the equate, not the
;     address. If MODE_NORMAL ever moves off zero (no reason it
;     would), init_cold_start needs an explicit
;     `LD A, MODE_NORMAL : LD (mode_byte), A` after the LDIR.
;   DEFAULT_FCB (0x005C) — the CP/M default FCB is at a well-
;     known address; CCP populates it with the filename
;     argument(s) typed at the prompt before transferring
;     control to the .com at 0x0100. Story 1.12 deliberately
;     SKIPS the parse — the editor launches with an empty
;     buffer regardless of whether the user typed `vibe` or
;     `vibe foo.fs`. Story 2.3 lands the real FCB ->
;     filename_buffer parse + fileio_load integration.
;     filename_buffer (16 bytes, declared in inc/state.inc) is
;     left zero-init from the stage-1 LDIR fill.
;
; Register conventions (across public entry points):
;   init_cold_start:  In: (none — entered from src/vibe.asm's
;                          ORG 0x0100 + JP init_cold_start with
;                          default CP/M state: SP at CCP-pushed
;                          warm-boot vector on stack, FCB at
;                          0x005C populated, DMA at 0x0080).
;                     Out: editor state fully initialised;
;                          mode = NORMAL; gap buffer at SR2
;                          empty; screen cleared with empty
;                          editing area + blank status row;
;                          cursor at row 0 / col 0; control
;                          transfers to input_loop via JP
;                          (no RET).
;                     Trashes: A, BC, DE, HL, F.
;                     Calls: MBB_SET_USR_INT (stages 0 and 2),
;                            gapbuf_init, render_init,
;                            status_set_message, render_full;
;                            falls through to input_loop.
;
;   init_teardown:    In: (none — entered via tail-JP from
;                          cmd_quit / cmd_quit_force in
;                          src/exline.asm).
;                     Out: screen cleared via ESC J + cursor
;                          home; control transfers to CCP via
;                          BDOS function 0 (warm-boot). Does
;                          not return on a real CP/M host; the
;                          defensive RET keeps the editor out
;                          of arbitrary memory on a misconfigured
;                          BIOS-during-bring-up (NFR5).
;                     Trashes: A, BC, DE, HL, F.
;                     Calls: MBB_SET_USR_INT (stage 1 uninstall),
;                            render_init, the BDOS gateway
;                            macro (function 0 = warm-boot).
;
; Dependencies:
;   inc/equates.inc  (header symbols only — sizes flow through
;                     state.inc EQU resolution)
;   inc/state.inc    (static_data_base, static_end — LDIR fill
;                     bounds; mode_byte / status_dirty / etc.
;                     are positional offsets within that range
;                     and are not named in code here, only
;                     covered by the fill)
;   inc/bios.inc     (DEFAULT_FCB — read-only, AC7 stub-parse;
;                     MBB_SET_USR_INT — Story 1.12 W1 resolution
;                     for the missing BIOS tick counter)
;   inc/bdos.inc     (gateway macro + BDOS_EXIT — init_teardown)
;   inc/modes.inc    (MODE_NORMAL = 0 — exploited implicitly by
;                     the LDIR fill: post-fill mode_byte = 0 =
;                     MODE_NORMAL; if MODE_NORMAL is ever
;                     re-EQUd to a non-zero value the cold-start
;                     will need an explicit LD A, MODE_NORMAL :
;                     LD (mode_byte), A after the LDIR)
;   inc/vt52.inc     (no direct reference — render.asm absorbs
;                     every VT52 emit per AR13)
;   src/statusln.asm (status_set_message, msg_mode_normal —
;                     Story 1.5 / 1.9)
;   src/input.asm    (input_tick_isr — installed at cold-start,
;                     uninstalled at teardown via MBB_SET_USR_INT)
;   src/gapbuf.asm   (gapbuf_init — Story 1.7)
;   src/render.asm   (render_init, render_full — Story 1.11;
;                     init_teardown reuses render_init for the
;                     screen-clear + cursor-home emit so AR13
;                     stays single-sited)
;   src/vibe.asm     (input_loop — fall-through target; this
;                     story rewrites input_loop's body)
; ============================================================

;; --- File-local equate ---
; LDIR byte-count for the static-block fill. Both anchors are
; EQU declarations in inc/state.inc; sjasmplus 1.23.0 resolves
; the subtraction at assembly time, so this is a literal
; integer at the LD BC site below — no runtime arithmetic.
;
; Guard: Stage 1's LDIR uses `LD BC, static_block_size - 1`. If
; static_block_size ever shrinks to 1 the BC=0 form would copy
; 65 536 bytes; if it shrinks to 0 the BC=0xFFFF form is also
; catastrophic. The assert below is a compile-time tripwire so
; a future state.inc layout never silently produces an LDIR
; that flattens the address space.
static_block_size       EQU static_end - static_data_base
    ASSERT static_block_size > 1

;; ============================================================
;; --- Public entry: init_cold_start ---
;; ============================================================

; ----------------------------------------------------------------
; init_cold_start
; Cold-start sequence. Runs once at .com entry; falls through to
; input_loop. Eight numbered stages (Stage 0 .. Stage 7),
; bracketed by `DI` at entry and `EI` after Stage 2 to close the
; .com-entry-to-Stage-0 race window against a stale user-ISR
; from a prior program firing on its 60 Hz tick during the few
; T-states before we clear the slot. EI re-enables interrupts
; once our own ISR (Stage 2 install) is registered, so the rest
; of the boot chain runs with interrupts on as CP/M expects.
;
;   Stage 0: uninstall any pre-existing user ISR via
;      MBB_SET_USR_INT (HL = 0). Vendor doc: ISRs survive warm
;      reboots, so this is defensive against a previous program
;      that didn't clean up — even a previous vibe.com run that
;      crashed out of cmd_quit / cmd_quit_force's tail-JP to
;      init_teardown.
;
;   Stage 1: Zero-init the entire static block (static_data_base
;      .. static_end) via the 1-byte-seed LDIR idiom. This
;      resolves the Story 1.3 deferral ("static state has no
;      zero-initialization story") and the Story 1.8 deferral
;      ("input_held_flag / input_held_byte uninitialised at
;      boot"). Every field declared in inc/state.inc lands at
;      0x00 — mode_byte = 0 = MODE_NORMAL is the convenient
;      consequence (see Dependencies note on inc/modes.inc).
;
;      Boundary: the fill MUST stop at static_end, NOT yank_end.
;      The yank-register region (GAP_BUFFER_BASE + GAP_BUFFER_MAX,
;      1024 B) is intentionally NOT zero-init: SR6 leaves the
;      yank pool as scratch RAM at boot (boot residue read on
;      the first paste before any yank is the documented sharp
;      edge). The gap buffer itself is also NOT zero-init: SR2
;      says "bytes inside the gap are read-as-undefined and
;      never visible through the two-halves walk"; Stage 3's
;      gapbuf_init establishes the SR2 invariant.
;
;      Cost: ~21 T-states/byte * ~2240 bytes ~= 47K T-states
;      ~= 12 ms at 4 MHz. Boot-time only; NFR3 governs frame-
;      rate cost, not boot-time.
;
;   Stage 2: install our own 60 Hz user ISR (input_tick_isr in
;      src/input.asm) via MBB_SET_USR_INT (HL = input_tick_isr).
;      Resolves the Story 1.4 W1 deferral on the BIOS tick
;      counter; src/input.asm's tick_wait_one consumes the
;      counter this ISR maintains. Immediately after this call
;      we `EI`: interrupts on; ISR tick chain live.
;
;   Stage 3: gapbuf_init (Story 1.7). Idempotent against the
;      just-zeroed state, but the call MUST happen — gapbuf_init
;      is the documented SR2-establishing entry point (AR14).
;      Routing through it makes the dependency explicit and
;      survives any future inc/state.inc layout shift that
;      breaks the "zeros happen to satisfy SR2" coincidence.
;
;   Stage 4: render_init (Story 1.11). Emits ESC H + ESC J (full
;      screen clear with cursor home — see render.asm's
;      Story-1.12 hardware-UAT-promoted patch on VT52 semantics),
;      fills shadow_buffer with 0x20, zeroes dirty_rows, zeroes
;      top_line_offset (idempotent).
;
;   Stage 5: status_set_message msg_mode_normal. msg_mode_normal
;      is the empty string per Story 1.9 (src/statusln.asm:170);
;      the funnel hits the null on byte 0 and pads
;      STATUS_LINE_WIDTH with spaces — matches vi's "no banner
;      in normal mode" convention (AR16). The call SETS
;      status_dirty so Stage 6's render_full picks up the row.
;
;      Going through status_set_message rather than directly
;      writing status_buffer / status_dirty preserves AR12's
;      funnel discipline at init time too: status_buffer's
;      WRITE path stays single-sited in statusln.asm.
;
;   Stage 6: render_full (mark all dirty + render_diff). Re-emits
;      the empty editing area (cells already match the shadow's
;      all-space target, so only the trailing cursor reposition
;      emits any bytes for the editing area; the status row
;      emit fires because Stage 5 set status_dirty).
;
;   Stage 7: Fall through to input_loop. MUST be a JP, not a
;      CALL: init_cold_start consumed its own stack discipline
;      at .com entry; init_teardown's BDOS gateway expansion
;      consumes the symmetric exit path.
;
; In:      (none — entered from src/vibe.asm's ORG 0x0100 +
;          JP init_cold_start)
; Out:     mode = NORMAL; gap buffer at SR2 empty; screen
;          cleared; shadow reconciled; cursor at row 0 / col 0;
;          control transfers to input_loop via JP.
; Trashes: A, BC, DE, HL, F.
; Calls:   MBB_SET_USR_INT (stages 0 and 2), gapbuf_init,
;          render_init, status_set_message, render_full; falls
;          through to input_loop.
; ----------------------------------------------------------------
init_cold_start:
    ;; --- DI: close the .com-entry-to-Stage-0 race window ---
    ;; Stale user-ISRs survive warm reboots (vendor BIOS doc);
    ;; without DI, a tick firing in the ~30 T-states from JP at
    ;; 0x0100 to the Stage-0 MBB_SET_USR_INT call would dispatch
    ;; to whatever stale slot the previous program left behind.
    ;; EI fires after Stage 2 once our own ISR is installed.
    DI

    ;; --- Stage 0: uninstall any pre-existing user ISR ---
    ;; Defensive against re-entry from a previous run that did
    ;; not exit through init_teardown (e.g. a crashed bring-up).
    ;; The MicroBeast BIOS doc explicitly warns that user-ISRs
    ;; survive warm reboots but their TPA memory does not — so
    ;; a stale pointer at MBB_SET_USR_INT would jump into the
    ;; just-loaded TPA bytes if we did not clear it before our
    ;; own LDIR fill scrambles them.
    LD      HL, 0                   ; HL = 0 -> disable
    CALL    MBB_SET_USR_INT

    ;; --- Stage 1: zero-init the entire static block ---
    ;; 1-byte-seed LDIR idiom: write 0x00 at HL, then LDIR
    ;; propagates the seed forward (static_block_size - 1) times.
    LD      HL, static_data_base
    XOR     A
    LD      (HL), A
    LD      DE, static_data_base + 1
    LD      BC, static_block_size - 1
    LDIR

    ;; --- Stage 2: install our 60 Hz user ISR (W1 — Story 1.4) ---
    ;; input_tick_isr (src/input.asm) increments input_tick_counter
    ;; on every BIOS keyboard-poll tick. Resolves the Story 1.4
    ;; deferral on the BIOS-managed tick counter that the
    ;; architecture assumed but the real BIOS does not expose.
    LD      HL, input_tick_isr
    CALL    MBB_SET_USR_INT

    ;; --- EI: interrupts back on; our ISR is now the live slot ---
    EI

    ;; --- Stage 3: establish SR2 (gap empty, cursor at offset 0) ---
    CALL    gapbuf_init

    ;; --- Stage 4: clear screen, seed shadow, home cursor ---
    CALL    render_init

    ;; --- Stage 5: seed status_dirty via msg_mode_normal (AR12) ---
    ;; msg_mode_normal is the empty string; status_set_message's
    ;; null-on-byte-0 path pads STATUS_LINE_WIDTH with spaces.
    LD      HL, msg_mode_normal
    XOR     A                       ; non-error code arg (AR16 convention)
    CALL    status_set_message

    ;; --- Stage 6: initial full redraw ---
    CALL    render_full

    ;; --- Stage 7: fall through to the main input loop ---
    JP      input_loop


;; ============================================================
;; --- Public entry: init_teardown ---
;; ============================================================

; ----------------------------------------------------------------
; init_teardown
; Teardown / warm-boot path. Entered via tail-JP from cmd_quit
; (':q' on a clean buffer) and cmd_quit_force (':q!') in
; src/exline.asm. Four numbered stages, in order:
;
;   1. Uninstall our user ISR via MBB_SET_USR_INT (HL = 0). The
;      vendor BIOS doc warns user-ISRs survive warm reboots —
;      without this uninstall, the BIOS would keep calling
;      input_tick_isr into TPA memory CCP is about to reuse and
;      crash the host. Mirrors Stage 0 of init_cold_start.
;
;   2. Clear screen + home cursor via render_init. The shadow
;      re-seed and dirty_rows / top_line_offset writes inside
;      render_init are inert at teardown (the editor is about
;      to warm-boot — no subsequent render pass will read them),
;      but routing through render_init keeps AR13 enforced
;      WITHOUT introducing a second console-emit call site in
;      init.asm. The alternative (a new render_clear_and_home
;      helper that emits only the ESC J + cursor home without
;      the shadow re-seed) is cleaner but adds a public symbol;
;      Story 1.12 picks the "reuse render_init" default. The
;      cost of the redundant 1920-byte LDIR (~10 ms at 4 MHz)
;      is irrelevant at teardown.
;
;   3. Warm-boot to CCP via the BDOS gateway macro on function
;      0. The macro expands to a `LD C, fn` + call into the
;      BDOS entry vector + sign-bit check (`OR A` /
;      `JP M, bdos_error_funnel`); the JP M is dead code on a
;      successful warm-boot but mandatory per AR15's uniform
;      macro contract. On a real CP/M host this never returns;
;      control transfers to CCP's warm-boot vector.
;
;   4. Defensive RET. Unreachable on every CP/M host the editor
;      supports (real MicroBeast + iz-cpm both honor function
;      0); retained so the editor stays out of arbitrary memory
;      if a misconfigured BIOS-during-bring-up lets function 0
;      fall through. NFR5: never crash into undefined behavior,
;      even on a brittle hardware state.
;
; In:      (none — entered via tail-JP from cmd_quit /
;          cmd_quit_force in src/exline.asm)
; Out:     screen cleared via ESC J + cursor home; control
;          transfers to CCP via BDOS function 0 (warm-boot).
;          Does not return on a real CP/M host; defensive RET
;          retained.
; Trashes: A, BC, DE, HL, F.
; Calls:   render_init, the BDOS gateway macro (function 0 =
;          warm-boot).
; ----------------------------------------------------------------
init_teardown:
    ;; --- Stage 1: uninstall our user ISR ---
    ;; The MicroBeast BIOS doc explicitly warns that user-ISRs
    ;; survive warm reboots — so we MUST disable ours before the
    ;; warm-boot, or the BIOS will keep calling into TPA memory
    ;; that CCP is about to reuse and crash the host.
    LD      HL, 0
    CALL    MBB_SET_USR_INT

    ;; --- Stage 2: clear screen + home cursor via render_init ---
    CALL    render_init

    ;; --- Stage 3: warm-boot to CCP via BDOS function 0 ---
    BDOS_CALL BDOS_EXIT

    ;; --- Stage 4: defensive RET (unreachable on a real host) ---
    RET
;; (Stage labels above match the four-stage header contract block.)
