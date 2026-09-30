// test_core.S - self-checking test of the RV32I subset the core supports.
// Also covers the pipeline behaviour: forwarding, load-use stalls, branches
// resolved in execute, and the bugs fixed when the core was imported.
#include "common.h"

  .section .text.init
  .globl _start
_start:
  // ---- immediates and ALU (the immediate bug made these all 0) ----
  addi a0, x0, 15
  CHECK a0, 15, 1
  addi a1, x0, -22
  CHECK a1, -22, 2
  add  a2, a0, a1
  CHECK a2, -7, 3
  sub  a3, a0, a1
  CHECK a3, 37, 4
  li   a4, 0x0ff0
  li   a5, 0x00ff
  and  a6, a4, a5
  CHECK a6, 0x00f0, 5
  or   a6, a4, a5
  CHECK a6, 0x0fff, 6
  xor  a6, a4, a5
  CHECK a6, 0x0f0f, 7
  andi a6, a4, 0x0f0
  CHECK a6, 0x0f0, 8
  ori  a6, a5, 0x700
  CHECK a6, 0x7ff, 9
  xori a6, a5, -1
  CHECK a6, -256, 10

  // ---- comparisons ----
  slt  a6, a1, a0          // -22 < 15
  CHECK a6, 1, 11
  sltu a6, a1, a0          // 0xffffffea < 15 unsigned? no
  CHECK a6, 0, 12
  slti a6, a1, -21
  CHECK a6, 1, 13
  sltiu a6, a0, 16
  CHECK a6, 1, 14

  // ---- shifts (srai was broken: shift amount used all 32 bits) ----
  li   s0, 0x80000010
  slli a6, s0, 4
  CHECK a6, 0x00000100, 15
  srli a6, s0, 4
  CHECK a6, 0x08000001, 16
  srai a6, s0, 4
  CHECK a6, 0xf8000001, 17
  li   s1, 36                // only the low 5 bits (4) count
  sll  a6, s0, s1
  CHECK a6, 0x00000100, 18
  sra  a6, s0, s1
  CHECK a6, 0xf8000001, 19

  // ---- lui / auipc ----
  lui  a6, 0x12345
  CHECK a6, 0x12345000, 20
  jal  ra, 1f
1:auipc a7, 0                // a7 = address of this auipc = ra
  CHECKR a7, ra, 21

  // ---- forwarding: each instruction needs the previous result ----
  li   a0, 1
  add  a0, a0, a0
  add  a0, a0, a0
  add  a0, a0, a0
  add  a0, a0, a0
  CHECK a0, 16, 22

  // ---- load-use stall ----
  la   s2, scratch
  li   a1, 1234
  sw   a1, 0(s2)
  lw   a2, 0(s2)
  addi a3, a2, 1             // uses the load result immediately
  CHECK a3, 1235, 23
  sw   a3, 4(s2)             // store right after
  lw   a4, 4(s2)
  CHECK a4, 1235, 24

  // ---- branches (funct3 was taken from the *next* instruction) ----
  li   a0, 5
  li   a1, 5
  li   a2, -3
  li   gp, 25
  beq  a0, a1, 2f
  j    fail
2:li   gp, 26
  bne  a0, a1, fail
  xor  x0, x0, x0            // next instruction has a different funct3
  li   gp, 27
  bne  a0, a2, 3f
  j    fail
3:li   gp, 28
  beq  a0, a2, fail
  and  x0, x0, x0
  li   gp, 29
  blt  a2, a0, 4f            // -3 < 5 signed
  j    fail
4:li   gp, 30
  bge  a2, a0, fail
  li   gp, 31
  bltu a0, a2, 5f            // 5 < 0xfffffffd unsigned
  j    fail
5:li   gp, 32
  bgeu a0, a2, fail
  li   gp, 33
  bge  a0, a1, 6f            // equal -> taken
  j    fail
6:

  // ---- jal / jalr (jalr used to jump to PC + imm) ----
  li   a0, 0
  jal  ra, add_ten
  CHECK a0, 10, 34
  la   t1, add_ten
  jalr ra, 0(t1)
  CHECK a0, 20, 35

  // ---- a loop: sum 1..100 ----
  li   a0, 0
  li   a1, 1
  li   a2, 101
7:add  a0, a0, a1
  addi a1, a1, 1
  bne  a1, a2, 7b
  CHECK a0, 5050, 36

  j    pass

add_ten:
  addi a0, a0, 10
  ret

  TEST_END

  .data
scratch: .word 0, 0
