// test_matmul.S - matrix multiply on the accelerator (DMA job) vs. software.
//
// For each size (M x K) * (K x P):
//   1. fill A and B with pseudo-random signed 16-bit values (xorshift32)
//   2. software product into CREF (shift-add multiply, 64-bit accumulate),
//      timed with the SYSCTRL cycle counter
//   3. fill C with a marker through the cache, so L1D holds stale lines of C
//   4. accelerator: flush L1D, start a DMA job, poll done, invalidate L1D,
//      timed the same way
//   5. compare C with CREF word by word (backwards)
// Cycle counts go to the perf slots: Perf[2n] software, Perf[2n+1] accelerator.
#include "common.h"

#define A_BASE    0x10000          // int32 A[M][K]
#define B_BASE    0x10400          // int32 B[K][P]
#define C_BASE    0x11000          // int64 C[M][P]   written by the accelerator
#define CREF_BASE 0x12000          // int64 CREF[M][P] written by software
#define PERF_BASE 0x3ff10
#define ACC       0x40000000       // matmul_accel registers
#define SYS       0x40010000       // SYSCTRL: maintenance (0), cycle counter (4)
#define MARKER    0xdeadbeef

  .section .text.init
  .globl _start
_start:
  li   s11, 0x12345678            // xorshift32 state

  li   a0, 16                     // test 1: 16x16 * 16x16 (four 8x8 tiles)
  li   a1, 16
  li   a2, 16
  li   a3, 0                      // perf slot pair 0, check id 1
  jal  ra, run_test

  li   a0, 5                      // test 2: 5x13 * 13x11 (partial tiles, odd M*P)
  li   a1, 13
  li   a2, 11
  li   a3, 1                      // perf slot pair 1, check id 2
  jal  ra, run_test

  j    pass

// ---------------------------------------------------------------------------
// run_test(a0 = M, a1 = K, a2 = P, a3 = test index)
// ---------------------------------------------------------------------------
run_test:
  mv   s0, a0                     // M
  mv   s1, a1                     // K
  mv   s2, a2                     // P
  mv   s3, a3                     // test index
  mv   s10, ra

  // ---- 1. random A (M*K) and B (K*P) ----
  mv   a0, s0
  mv   a1, s1
  jal  t5, mul16
  mv   a1, a0
  li   a0, A_BASE
  jal  t5, fill_random
  mv   a0, s1
  mv   a1, s2
  jal  t5, mul16
  mv   a1, a0
  li   a0, B_BASE
  jal  t5, fill_random

  // ---- 2. software product, timed ----
  li   s5, SYS
  lw   s6, 4(s5)                  // start cycle
  jal  t6, sw_matmul
  lw   s7, 4(s5)                  // end of software

  // ---- 3. marker in C (2*M*P words + one padding line) ----
  // Written through the L1D just before the job, so the L1D holds stale
  // (dirty, then clean after the flush) copies of C when the job ends.
  mv   a0, s0
  mv   a1, s2
  jal  t5, mul16
  mv   s4, a0                     // s4 = M*P
  slli t0, s4, 1
  addi t0, t0, 4
  li   t1, C_BASE
  li   t2, MARKER
1:sw   t2, 0(t1)
  addi t1, t1, 4
  addi t0, t0, -1
  bnez t0, 1b
  lw   a6, 4(s5)                  // start of accelerator

  // ---- 4. accelerator DMA job, timed ----
  li   s8, ACC
  li   t0, A_BASE
  sw   t0, 12(s8)                 // BASE_A
  li   t0, B_BASE
  sw   t0, 16(s8)                 // BASE_B
  li   t0, C_BASE
  sw   t0, 20(s8)                 // BASE_C
  slli t0, s2, 16                 // DIMS = P << 16 | K << 8 | M
  slli t1, s1, 8
  or   t0, t0, t1
  or   t0, t0, s0
  sw   t0, 8(s8)
  li   t0, 1                      // flush L1D: A, B (and C markers) reach the L2
  sw   t0, 0(s5)
2:lw   t0, 0(s5)
  bnez t0, 2b
  li   t0, 3                      // start a DMA job
  sw   t0, 0(s8)
3:lw   t0, 4(s8)                  // poll STATUS.done
  andi t0, t0, 2
  beqz t0, 3b
  li   t0, 2                      // invalidate L1D: drop the stale C markers
  sw   t0, 0(s5)
4:lw   t0, 0(s5)
  bnez t0, 4b
  lw   s9, 4(s5)                  // end cycle

  // perf slots: [2n] software cycles, [2n+1] accelerator cycles
  li   t0, PERF_BASE
  slli t1, s3, 3
  add  t0, t0, t1
  sub  t1, s7, s6
  sw   t1, 0(t0)
  sub  t1, s9, a6
  sw   t1, 4(t0)

  // ---- 5. compare C with CREF (2*M*P words), last word first ----
  // Backwards, so the first reads hit the lines the marker fill left in the
  // L1D: without the invalidate they would return the stale markers.
  addi gp, s3, 1                  // check id = test index + 1
  slli t0, s4, 1
  slli t1, s4, 3
  addi t1, t1, -4                 // byte offset of the last word
  li   t2, CREF_BASE
  add  t2, t2, t1
  li   t3, C_BASE
  add  t1, t1, t3
5:lw   t3, 0(t1)
  lw   t4, 0(t2)
  bne  t3, t4, fail
  addi t1, t1, -4
  addi t2, t2, -4
  addi t0, t0, -1
  bnez t0, 5b

  mv   ra, s10
  ret

// ---------------------------------------------------------------------------
// fill_random(a0 = address, a1 = word count), link in t5
// Each word is a signed 16-bit value from xorshift32 (state in s11).
// ---------------------------------------------------------------------------
fill_random:
1:slli t0, s11, 13
  xor  s11, s11, t0
  srli t0, s11, 17
  xor  s11, s11, t0
  slli t0, s11, 5
  xor  s11, s11, t0
  slli t0, s11, 16                // sign-extend the low 16 bits
  srai t0, t0, 16
  sw   t0, 0(a0)
  addi a0, a0, 4
  addi a1, a1, -1
  bnez a1, 1b
  jalr x0, 0(t5)

// ---------------------------------------------------------------------------
// mul16(a0 = x, a1 = y) -> a0 = x * y, link in t5
// y is a signed 16-bit value; x any 32-bit value whose product fits in 32 bits.
// Shift-add over y's 16 bits; bit 15 has weight -2^15 (two's complement).
// Uses t0-t3 only.
// ---------------------------------------------------------------------------
mul16:
  li   t0, 0                      // product
  mv   t2, a0                     // x << bit
  li   t1, 15
1:andi t3, a1, 1
  beqz t3, 2f
  add  t0, t0, t2
2:slli t2, t2, 1
  srai a1, a1, 1
  addi t1, t1, -1
  bnez t1, 1b
  andi t3, a1, 1                  // bit 15
  beqz t3, 3f
  sub  t0, t0, t2
3:mv   a0, t0
  jalr x0, 0(t5)

// ---------------------------------------------------------------------------
// sw_matmul: CREF[M][P] (int64) = A[M][K] * B[K][P], M/K/P in s0/s1/s2,
// link in t6. Accumulates in a 64-bit {a5:a4} pair. Uses s7-s9 (free at
// this point in run_test) and keeps s0-s6, s10, s11.
// ---------------------------------------------------------------------------
sw_matmul:
  slli a6, s1, 2                  // A row stride (bytes)
  slli a7, s2, 2                  // B row stride (bytes)
  li   s8, A_BASE                 // A row pointer
  li   s9, CREF_BASE              // output pointer
  mv   gp, s0                     // rows left (gp is free until the compare)
1:li   t4, B_BASE                 // B column pointer
  mv   ra, s2                     // columns left
2:li   a4, 0                      // acc low
  li   a5, 0                      // acc high
  mv   a2, s8                     // &A[i][0]
  mv   a3, t4                     // &B[0][j]
  mv   s7, s1                     // k left
3:lw   a0, 0(a2)
  lw   a1, 0(a3)
  jal  t5, mul16                  // a0 = A[i][k] * B[k][j]
  add  a4, a4, a0                 // 64-bit add of the sign-extended product
  sltu t0, a4, a0                 // carry out of the low word
  srai t1, a0, 31
  add  a5, a5, t1
  add  a5, a5, t0
  addi a2, a2, 4
  add  a3, a3, a7
  addi s7, s7, -1
  bnez s7, 3b
  sw   a4, 0(s9)
  sw   a5, 4(s9)
  addi s9, s9, 8
  addi t4, t4, 4
  addi ra, ra, -1
  bnez ra, 2b
  add  s8, s8, a6
  addi gp, gp, -1
  bnez gp, 1b
  jalr x0, 0(t6)

  TEST_END
