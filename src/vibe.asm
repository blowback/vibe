; ============================================================
; Module: vibe.asm
; Purpose: Top-level entry point for VIBE. The .com loader hands
;          control to ORG 0x0100; from there we JP into
;          init.asm's cold-start, which zeros the static block,
;          inits sub-systems, paints the first frame, and falls
;          through to input_loop below. The INCLUDE chain
;          assembles every production module in AR25 order;
;          state.inc anchors the static memory map past code as
;          the final positional INCLUDE.
;
; Public:
;   input_loop   ; Main input-loop top-of-frame: input_get_key
;                ; -> dispatch_key -> render_diff -> repeat.
;                ; Re-entered by bdos_error_funnel's JP from
;                ; src/statusln.asm — the abort path falls
;                ; back into the loop's top rather than warm-
;                ; booting (NFR5).
;
; State owned (read/write):
;   (declared in inc/state.inc; the cold-start path in
;    src/init.asm zero-inits every field via a one-shot
;    LDIR across static_data_base .. static_end)
;
; Register conventions (across public entry points):
;   input_loop:  In:  (none — entered by fall-through from
;                     init_cold_start or by re-entry from
;                     bdos_error_funnel's JP)
;                Out: never returns to caller (no caller —
;                     control transfers out via init_teardown's
;                     BDOS warm-boot or via re-entry from
;                     bdos_error_funnel)
;                Trashes: A, BC, DE, HL, F (transitively via
;                     input_get_key + dispatch_key + handler +
;                     render_diff)
;                Calls: input_get_key, dispatch_key, render_diff
;
; Dependencies:
;   inc/equates.inc, inc/bios.inc, inc/bdos.inc, inc/vt52.inc,
;   inc/modes.inc, inc/state.inc; src/init.asm (Story 1.12);
;   src/input.asm (Story 1.8); src/statusln.asm (Story 1.5);
;   src/gapbuf.asm (Story 1.7); src/render.asm (Story 1.11);
;   src/dispatch.asm (Story 1.9); src/parser.asm (Story 1.10);
;   src/exline.asm (Story 2.1); src/fileio.asm (Story 2.2)
; ============================================================

;; --- Compile-time-constant includes (dependency order per AR25) ---
; Pure-EQU headers that do NOT use $; safe to place before ORG.
; (state.inc is also EQU-only but DOES use $ to anchor the static
; map past code, so it is INCLUDEd after the input loop body, below.)
    INCLUDE "../inc/equates.inc"
    INCLUDE "../inc/bios.inc"
    INCLUDE "../inc/bdos.inc"
    INCLUDE "../inc/vt52.inc"
    INCLUDE "../inc/modes.inc"

    ORG 0x0100

    JP init_cold_start              ; Entry point: jump to init.asm's
                                    ; cold-start. See src/init.asm.
                                    ; The CCP-pushed warm-boot vector
                                    ; stays on the stack across init's
                                    ; lifetime; init_teardown's BDOS
                                    ; function 0 consumes the symmetric
                                    ; exit path.

;; --- Cold-start init + teardown (init.asm — Story 1.12) ---
; AR25 order: ORG 0x0100 -> init -> input -> statusln -> gapbuf
; -> render -> dispatch -> parser. init.asm owns the cold-start
; sequence (zero-init the static block, gapbuf_init, render_init,
; initial status banner via msg_mode_normal, render_full, fall-
; through to input_loop) and the teardown sequence (render_init
; for screen-clear + cursor home, then BDOS_CALL BDOS_EXIT for
; warm-boot to CCP).
    INCLUDE "init.asm"

;; --- Input layer (RI5; input.asm — Story 1.8) ---
; AR25 order: init -> input -> statusln -> gapbuf
; (architecture line 180). Production callers wired in this
; story's input_loop body — see `input_loop:` below.
    INCLUDE "input.asm"

;; --- Status-line module (MC5; statusln.asm — Story 1.5) ---
; statusln.asm INCLUDEs here so its emitted code lands after the
; JP at 0x0100 and before state.inc anchors the static map past
; code. Per AR25 module include order: statusln is "early —
; depended on by everything" (architecture line 939).
    INCLUDE "statusln.asm"

;; --- Gap-buffer module (AR14; gapbuf.asm — Story 1.7) ---
; AR25 order: statusln (load early — depended on by everything)
; -> gapbuf (architecture line 940). `gapbuf_init` is called
; from init.asm's cold-start (Story 1.12); gap-buffer mutators
; (insert/delete/move_gap) are still test-only — Epic 2 motions
; / edits land the production callers. Tests in test/cases/
; gapbuf_* exercise the primitives standalone.
    INCLUDE "gapbuf.asm"

;; --- Render pipeline (RI1-RI4; render.asm — Story 1.11) ---
; AR25 order: gapbuf -> render -> dispatch. render.asm owns
; shadow_buffer, dirty_rows, top_line_offset, and the single
; screen-emission path (AR13). `render_init` and `render_full`
; are called from init.asm's cold-start (Story 1.12);
; `render_diff` is called from the input loop body (this story);
; the Ctrl-L handler in dispatch.asm tail-JPs to render_full.
    INCLUDE "render.asm"

;; --- Mode dispatcher (MC3; dispatch.asm — Story 1.9 / 2.1) ---
; AR25 order: render -> dispatch -> parser. Production callers
; wired in this story's input_loop body — see `input_loop:`
; below. dispatch_command's table forward-references exline_*
; handlers from src/exline.asm (Story 2.1); the BDOS_CALL
; carve-out for mode_debug_quit was retired when :q / :q!
; arrived (dispatch.asm is AR15-clean post-Story-2.1).
    INCLUDE "dispatch.asm"

;; --- Command parser (MC4; parser.asm — Story 1.10) ---
; AR25 order: dispatch -> parser -> motions. motions.asm
; (Story 2.5+) does not yet exist; when it lands it will slot
; in AFTER parser.asm here. Production callers wired in this
; story's input_loop body — see `input_loop:` below.
    INCLUDE "parser.asm"

;; --- Ex command-line (FR14, FR3, FR8; exline.asm — Story 2.1) ---
; AR25 order: parser -> (motions / edits / visual / search yet
; to land) -> exline -> fileio -> undo. With the intermediate
; modules not yet present, exline slots in immediately after
; parser; future stories (2.5 motions, 2.8-2.13 edits, 3.x
; search/visual) will INCLUDE between parser.asm and exline.asm
; as they arrive. dispatch_command's table forward-references
; exline_begin / exline_append_literal / exline_backspace /
; exline_dispatch / exline_cancel; sjasmplus's two-pass
; assembly resolves them here.
    INCLUDE "exline.asm"

;; --- File I/O (FR6, FR9, FR10, FR11, FR51; fileio.asm — Story 2.2) ---
; AR25 order: exline -> fileio -> undo. fileio.asm lands the
; BDOS file-I/O cluster (OPEN / SET_DMA / READ_SEQ / CLOSE) and
; the FCB-based load orchestration that cmd_edit / cmd_edit_force
; in src/exline.asm forward-reference (sjasmplus two-pass).
; Story 2.4 (`:w` / `:wq`) will extend this module with the save
; side; Story 2.3 (launch-with-filename) will call into fileio_load
; from init.
    INCLUDE "fileio.asm"

;; --- Main input loop (Story 1.12 / 2.1) ---
; Main input loop. Falls into here from `init_cold_start`
; (src/init.asm) and is re-entered by `bdos_error_funnel`'s
; JP from src/statusln.asm. Loop body: `input_get_key` ->
; per-mode demultiplex -> `dispatch_key` -> `render_diff` ->
; repeat. Never returns to a caller — the only exits are via
; `cmd_quit` / `cmd_quit_force` (src/exline.asm) ->
; `init_teardown` -> warm-boot.
;
; The body lands AFTER every src/ INCLUDE so the symbols it
; references (input_get_key, dispatch_normal/insert/command/
; visual, DISPATCH_*_COUNT, dispatch_key, render_diff) resolve
; on sjasmplus's first pass.
input_loop:
    ;; 1. Get next keystroke. RI5 disambig (Esc / arrow,
    ;;    ~40 ms tick window) is internal to input_get_key.
    CALL    input_get_key

    ;; 2. Per-mode dispatch-table demultiplex. A holds the key;
    ;;    save it in C across the mode_byte read (which clobbers
    ;;    A). MODE_NORMAL is the default fall-through — a
    ;;    corrupted mode_byte (any value not in {0,1,2,3})
    ;;    lands here and keeps the editor usable (NFR5).
    LD      C, A
    LD      A, (mode_byte)
    CP      MODE_INSERT
    JR      Z, .insert
    CP      MODE_COMMAND
    JR      Z, .command
    CP      MODE_VISUAL
    JR      Z, .visual
    ;; Default + NORMAL: dispatch_normal.
    LD      HL, dispatch_normal
    LD      B, DISPATCH_NORMAL_COUNT
    JR      .dispatch
.insert:
    LD      HL, dispatch_insert
    LD      B, DISPATCH_INSERT_COUNT
    JR      .dispatch
.command:
    LD      HL, dispatch_command
    LD      B, DISPATCH_COMMAND_COUNT
    JR      .dispatch
.visual:
    LD      HL, dispatch_visual
    LD      B, DISPATCH_VISUAL_COUNT

.dispatch:
    ;; 3. Restore A = key for MC4 before CALL dispatch_key.
    LD      A, C
    CALL    dispatch_key            ; handler RETs back here

    ;; 4. Reconcile screen with any buffer / status changes the
    ;;    handler made. RI2 / RI4 — render runs after each
    ;;    input-loop iteration; idle = no emission except the
    ;;    trailing cursor reposition.
    CALL    render_diff

    ;; 5. Top of frame.
    JP      input_loop

;; --- Static memory map (positional; anchors past code) ---
; state.inc is the AR25-final include; positioned here (not in the
; pre-ORG block) so that `static_data_base EQU $` resolves to the
; first address past code, not 0x0000. EQU-only — no bytes emit.
;
; state.inc MUST be the last source emitted from vibe.asm. Anything
; below this INCLUDE would either emit bytes past static_data_base
; (overlapping declared statics with no build-time error) or land
; outside the ASSERT yank_end <= 0xD800 guard inside state.inc.
    INCLUDE "../inc/state.inc"
