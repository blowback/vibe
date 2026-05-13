; ============================================================
; Module: test/cases/gapbuf_random-ops.asm
; Purpose: AC16 — fuzz the four primitives via a deterministic
;          PRNG, asserting the SR2 two-halves invariant via a
;          running XOR-fold checksum after every operation.
;
; AC reference: AC16 (story 1.7); end-to-end stress of AC2-AC8.
;
; PRNG: 16-bit Galois LFSR, polynomial 0xB400, seeded 0xACE1.
;   prng_next: state := (state >> 1) XOR (CF ? 0xB400 : 0)
;   Period 65535; documented seed + tap so any failure is
;   reproducible by re-running `make test` (NFR18).
;
; Loop: 100 iterations. Each iteration:
;   1. Draw r; op = (r mod 3) -> 0=insert, 1=delete, 2=move.
;   2. Dispatch:
;        insert: byte = next_random's low byte; expected ^= byte
;                on success (CF=1 here is unexpected on a 32 KB
;                buffer, so we FAIL with 0xCF).
;        delete: at BOF (cursor_offset==0): expect CF=1;
;                mid-buffer: read byte at cursor-1 (SR3),
;                expected ^= byte, then delete (expect CF=0).
;        move:   target = r mod (file_length+1); call move_gap.
;   3. Walk-XOR-fold checksum the buffer; compare to expected.
;
; Failure encoding (per Task 13 step 6 recommendation — A
; carries the op-discriminating constant, B carries raw iter
; so the FAIL line reads e.g. `FAIL C1 20` = op 1 (delete),
; iter 32, with no overflow-wrap aliasing of the iter byte
; against the test_pass sentinel value 0x00):
;   walk mismatch: A = 0xC0 + op_code (0/1/2 -> C0/C1/C2), B = iter
;   insert unexpected CF=1: A = 0xCF, B = iter
;   mid-buffer delete unexpected CF=1: A = 0xCD, B = iter
;   BOF delete failed to return CF=1: A = 0xCE, B = iter
; ============================================================

;; --- Pre-ORG production headers ---
    INCLUDE "../../inc/equates.inc"
    INCLUDE "../../inc/bios.inc"
    INCLUDE "../../inc/bdos.inc"
    INCLUDE "../../inc/modes.inc"

;; --- ORG 0x0100, sentinel pre-zero, test_start ---
    INCLUDE "../inc/test_prologue.inc"

;; ----- Test body -----
    CALL    gapbuf_init

    ;; Initialise PRNG state, expected checksum, iter counter.
    LD      HL, 0xACE1
    LD      (prng_state), HL
    XOR     A
    LD      (expected_chk), A
    LD      (iter_counter), A

main_loop:
    LD      A, (iter_counter)
    CP      100
    JP      Z, all_done

    ;; Draw r; op = r mod 3.
    CALL    prng_next                   ; HL = new state
    LD      A, L
    CALL    mod3_a                      ; A = op in {0,1,2}
    LD      (current_op), A

    OR      A
    JP      Z, do_insert
    CP      1
    JP      Z, do_delete
    JP      do_move

do_insert:
    CALL    prng_next
    LD      A, L                        ; byte to insert
    LD      (insert_byte), A
    CALL    gapbuf_insert
    JP      C, insert_full_unexpected
    ;; Success: expected ^= byte.
    LD      A, (insert_byte)
    LD      HL, expected_chk
    XOR     (HL)
    LD      (HL), A
    JP      check_walk

do_delete:
    LD      HL, (cursor_offset)
    LD      A, H
    OR      L
    JP      Z, delete_at_bof

    ;; Mid-buffer: read byte at cursor-1, fold into expected, then delete.
    CALL    read_byte_before_cursor     ; A = byte
    LD      HL, expected_chk
    XOR     (HL)
    LD      (HL), A
    CALL    gapbuf_delete
    JP      C, delete_unexpected_cf
    JP      check_walk

delete_at_bof:
    CALL    gapbuf_delete
    JP      NC, bof_delete_no_cf
    ;; CF=1 as expected; expected_chk unchanged.
    JP      check_walk

do_move:
    CALL    prng_next                   ; HL = r (target candidate)
    PUSH    HL
    CALL    compute_file_length         ; HL = file_length
    LD      B, H
    LD      C, L                        ; BC = file_length
    POP     HL                          ; HL = r
    CALL    modn1_hl                    ; HL = r mod (file_length + 1)
    CALL    gapbuf_move_gap
    JP      check_walk

check_walk:
    CALL    walk_xor_checksum           ; A = actual
    LD      HL, expected_chk
    CP      (HL)
    JP      Z, next_iter
    ;; Mismatch: A = 0xC0 + op (op in 0..2 -> A in 0xC0..0xC2);
    ;; B = iter (raw, 0..99). Encoding chosen so the iter byte
    ;; never aliases the test_pass sentinel value (0x00) and so
    ;; the FAIL stdout token is unambiguous on op + iteration.
    LD      A, (iter_counter)
    LD      B, A                        ; B = iter
    LD      A, (current_op)
    ADD     A, 0xC0                     ; A = 0xC0 + op
    JP      test_fail

next_iter:
    LD      A, (iter_counter)
    INC     A
    LD      (iter_counter), A
    JP      main_loop

all_done:
    JP      test_pass

;; ----- Special-case failure exits (B = iter for diagnosis) -----
insert_full_unexpected:
    LD      A, (iter_counter)
    LD      B, A
    LD      A, 0xCF
    JP      test_fail

delete_unexpected_cf:
    LD      A, (iter_counter)
    LD      B, A
    LD      A, 0xCD
    JP      test_fail

bof_delete_no_cf:
    LD      A, (iter_counter)
    LD      B, A
    LD      A, 0xCE
    JP      test_fail

;; ----------------------------------------------------------------
;; prng_next
;; 16-bit Galois LFSR, polynomial 0xB400. Period 65535.
;; In:      (prng_state) holds current state (non-zero)
;; Out:     HL = (prng_state) = new state
;; Trashes: A, HL, F
;; ----------------------------------------------------------------
prng_next:
    LD      HL, (prng_state)
    SRL     H
    RR      L
    JR      NC, .no_tap
    LD      A, H
    XOR     0xB4
    LD      H, A
.no_tap:
    LD      (prng_state), HL
    RET

;; ----------------------------------------------------------------
;; mod3_a
;; Compute A mod 3 for A in 0..255 via subtract loop (max 85 iters).
;; In:      A = value
;; Out:     A = A mod 3
;; Trashes: F
;; ----------------------------------------------------------------
mod3_a:
.loop:
    CP      3
    RET     C
    SUB     3
    JR      .loop

;; ----------------------------------------------------------------
;; modn1_hl
;; Compute HL mod (BC + 1) via subtract loop. Worst case is
;; HL / M iterations: when M = 1 (file_length == 0 — a possible
;; mid-fuzz state after enough deletes) and HL is near 0xFFFF,
;; the loop runs up to ~65535 times. The test stays well under
;; the 5-second iz-cpm budget regardless. Typical case in this
;; fuzz harness: M < 200 (file_length grows but is bounded by
;; net-inserts <= 100 across the loop).
;; In:      HL = value, BC = n (modulus M = BC + 1)
;; Out:     HL = HL mod M
;; Trashes: A, BC, DE, F
;; ----------------------------------------------------------------
modn1_hl:
    INC     BC                          ; BC = M
.loop:
    LD      D, B
    LD      E, C                        ; DE = M
    OR      A
    SBC     HL, DE
    JR      NC, .loop                   ; HL still >= M
    ADD     HL, DE                      ; restore: HL = last positive value
    RET

;; ----------------------------------------------------------------
;; compute_file_length
;; file_length = GAP_BUFFER_MAX - (gap_end - gap_start)
;; In:      (gap_start), (gap_end)
;; Out:     HL = file_length
;; Trashes: A, DE, HL, F
;; ----------------------------------------------------------------
compute_file_length:
    LD      HL, (gap_end)
    LD      DE, (gap_start)
    OR      A
    SBC     HL, DE                      ; HL = gap_size
    EX      DE, HL                      ; DE = gap_size
    LD      HL, GAP_BUFFER_MAX
    OR      A
    SBC     HL, DE                      ; HL = GAP_BUFFER_MAX - gap_size
    RET

;; ----------------------------------------------------------------
;; read_byte_before_cursor
;; Read the byte at logical offset (cursor_offset - 1) via SR3
;; mapping. Read-only — does not modify gap state.
;; In:      (cursor_offset) > 0; (gap_start), (gap_end) describe buffer
;; Out:     A = byte at logical offset (cursor_offset - 1)
;; Trashes: A, BC, DE, HL, F
;; ----------------------------------------------------------------
read_byte_before_cursor:
    LD      HL, (cursor_offset)
    DEC     HL                          ; HL = i = cursor - 1

    ;; Compute gap_offset = gap_start - GAP_BUFFER_BASE into DE.
    PUSH    HL
    LD      HL, (gap_start)
    LD      DE, GAP_BUFFER_BASE
    OR      A
    SBC     HL, DE
    EX      DE, HL                      ; DE = gap_offset
    POP     HL                          ; HL = i

    ;; Compare i (HL) ?= gap_offset (DE) without losing HL.
    PUSH    HL
    OR      A
    SBC     HL, DE                      ; HL = i - gap_offset; CF=1 iff i < gap_offset
    POP     HL                          ; restore HL = i
    JR      C, .pre

    ;; i >= gap_offset: byte at gap_end + (i - gap_offset).
    OR      A
    SBC     HL, DE                      ; HL = i - gap_offset
    LD      DE, (gap_end)
    ADD     HL, DE                      ; HL = physical
    LD      A, (HL)
    RET

.pre:
    ;; i < gap_offset: byte at GAP_BUFFER_BASE + i.
    LD      DE, GAP_BUFFER_BASE
    ADD     HL, DE                      ; HL = physical
    LD      A, (HL)
    RET

;; ----------------------------------------------------------------
;; walk_xor_checksum
;; XOR-fold all file bytes via the two-halves walk (SR3).
;; In:      (gap_start), (gap_end) describe state.
;; Out:     A = XOR of all file bytes.
;; Trashes: A, BC, DE, HL, F.
;; ----------------------------------------------------------------
walk_xor_checksum:
    LD      C, 0                        ; checksum accumulator

    ;; Walk before-gap half: HL = GAP_BUFFER_BASE; until HL == gap_start.
    LD      HL, GAP_BUFFER_BASE
.pre:
    LD      DE, (gap_start)
    LD      A, L
    CP      E
    JR      NZ, .pre_more
    LD      A, H
    CP      D
    JR      Z, .post_setup
.pre_more:
    LD      A, (HL)
    XOR     C
    LD      C, A
    INC     HL
    JR      .pre

.post_setup:
    LD      HL, (gap_end)
.post:
    LD      DE, GAP_BUFFER_BASE + GAP_BUFFER_MAX
    LD      A, L
    CP      E
    JR      NZ, .post_more
    LD      A, H
    CP      D
    JR      Z, .done
.post_more:
    LD      A, (HL)
    XOR     C
    LD      C, A
    INC     HL
    JR      .post

.done:
    LD      A, C
    RET

;; ----- Per-test scratch -----
prng_state:    DEFW 0
expected_chk:  DEFB 0
iter_counter:  DEFB 0
current_op:    DEFB 0
insert_byte:   DEFB 0

;; ----- test_pass / test_fail labels -----
    INCLUDE "../inc/test_epilogue.inc"

;; ----- Production code under test -----
    INCLUDE "../../src/statusln.asm"
    INCLUDE "../../src/gapbuf.asm"

;; ----- input_loop stub -----
    INCLUDE "../inc/test_input_loop_stub.inc"

;; ----- state.inc LAST -----
    INCLUDE "../../inc/state.inc"
