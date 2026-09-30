// test_mem.S - stress the cache hierarchy.
//
// L1 (512 B, direct-mapped, 16 B lines): addresses 512 B apart share a line.
// L2 (2 KB, 2-way, 32 B lines): 32 sets, so addresses 1 KB apart share a set;
//   a third such address evicts one of the two ways (LRU).
//
// 1. Fill 4 regions of 1 KB each (4 KB total > L1 + L2) with a pattern.
//    Many dirty lines must be written back L1 -> L2 -> DRAM.
// 2. Read everything back in a different order and check every word.
// 3. Copy region 0 to a 5th region and verify the copy.
// 4. Ping-pong between addresses that collide in L1 and in both L2 ways.
#include "common.h"

#define BASE   0x10000
#define REGION 1024          // bytes
#define NREG   4
#define WORDS  (REGION/4)

  .section .text.init
  .globl _start
_start:
  // ---- 1. fill: word i of the whole 4 KB area = i * 0x9e3779b1 + 7 ----
  li   s0, BASE
  li   s1, NREG*WORDS         // number of words
  li   s2, 0x9e3779b1         // multiplier step (no mul instruction, so add)
  li   t0, 7                  // running value
  li   t1, 0                  // i
1:slli t2, t1, 2
  add  t2, t2, s0
  sw   t0, 0(t2)
  add  t0, t0, s2
  addi t1, t1, 1
  bne  t1, s1, 1b

  // ---- 2. check, walking the regions in reverse and words backwards ----
  li   gp, 1
  addi t1, s1, -1             // i = last word
2:mv   t3, t1                 // expected = i * step + 7, computed by shift-add
  li   t4, 7
  mv   t5, s2
3:beqz t3, 4f
  andi a0, t3, 1
  beqz a0, 5f
  add  t4, t4, t5
5:slli t5, t5, 1
  srli t3, t3, 1
  j    3b
4:slli t2, t1, 2
  add  t2, t2, s0
  lw   a1, 0(t2)
  bne  a1, t4, fail
  addi t1, t1, -1
  bgez t1, 2b

  // ---- 3. copy region 0 -> region at BASE + 8 KB and verify ----
  li   gp, 2
  li   s3, BASE + 8192
  li   t1, 0
  li   s4, WORDS
6:slli t2, t1, 2
  add  a2, t2, s0
  add  a3, t2, s3
  lw   a1, 0(a2)
  sw   a1, 0(a3)
  addi t1, t1, 1
  bne  t1, s4, 6b
  li   t1, 0
7:slli t2, t1, 2
  add  a2, t2, s0
  add  a3, t2, s3
  lw   a1, 0(a2)
  lw   a4, 0(a3)
  bne  a1, a4, fail
  addi t1, t1, 1
  bne  t1, s4, 7b

  // ---- 4. ping-pong: A, A+1K, A+2K share one L2 set (and one L1 line) ----
  li   gp, 3
  li   s5, BASE + 0x6000      // A
  li   t1, 0                  // round
  li   s6, 50
8:sw   t1, 0(s5)              // A        (dirty)
  sw   t1, 1024(s5)           // A + 1 KB (same L1 line, same L2 set)
  addi a5, t1, 100
  sw   a5, 2044(s5)           // A + 2 KB - 4 (different word; same L1 line and L2 set)
  lw   a1, 0(s5)
  bne  a1, t1, fail
  lw   a1, 1024(s5)
  bne  a1, t1, fail
  lw   a1, 2044(s5)
  bne  a1, a5, fail
  addi t1, t1, 1
  bne  t1, s6, 8b

  j    pass

  TEST_END
