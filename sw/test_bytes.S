// test_bytes.S - byte and half-word loads and stores (lb lh lbu lhu sb sh).
//
// 1. Loads from preloaded data at every byte / half-word offset: sign and
//    zero extension.
// 2. Byte and half-word stores into every lane of a word; the other bytes
//    must not change, and only the low byte / half of rs2 is stored. Most
//    stores are read back by the very next instruction (L1D hazard path).
// 3. Load-use: the extended value (not the raw word) must reach the next
//    instruction: ALU, branch comparator, store data.
// 4. A byte store that misses in L1D (the line is fetched, one byte merged),
//    and a partly rewritten dirty line evicted from L1D and L2, read back.
// 5. Byte and 6. half-word loops over 3 KB each (more than L1D + L2), read
//    back in reverse with both the zero- and the sign-extending load.
// The testbench also checks that DRAM matches every committed store.
#include "common.h"

#define BUF    0x20000        // scratch words for sections 2-3
#define BYTES  0x21000        // section 5
#define NBYTES 3072
#define HALVES 0x24000        // section 6
#define NHALF  1536

  .section .text.init
  .globl _start
_start:
  // ---- 1. loads from preloaded data ----
  la   s0, ldata              // 0x80817f01 = bytes 01 7f 81 80
  lb   a0, 0(s0)
  CHECK a0, 0x01, 1
  lb   a0, 1(s0)
  CHECK a0, 0x7f, 2
  lb   a0, 2(s0)
  CHECK a0, 0xffffff81, 3
  lb   a0, 3(s0)
  CHECK a0, 0xffffff80, 4
  lbu  a0, 2(s0)
  CHECK a0, 0x81, 5
  lbu  a0, 3(s0)
  CHECK a0, 0x80, 6
  lh   a0, 0(s0)
  CHECK a0, 0x7f01, 7
  lh   a0, 2(s0)
  CHECK a0, 0xffff8081, 8
  lhu  a0, 2(s0)
  CHECK a0, 0x8081, 9
  lhu  a0, 0(s0)
  CHECK a0, 0x7f01, 10
  lw   a0, 0(s0)
  CHECK a0, 0x80817f01, 11

  // ---- 2. stores into every lane ----
  li   s1, BUF
  li   t0, 0x11223344
  sw   t0, 0(s1)
  li   t0, 0x123456aa         // only the low byte may be written
  sb   t0, 0(s1)
  lw   a0, 0(s1)
  CHECK a0, 0x112233aa, 12
  li   t0, 0xbb
  sb   t0, 1(s1)
  lw   a0, 0(s1)
  CHECK a0, 0x1122bbaa, 13
  li   t0, 0xcc
  sb   t0, 2(s1)
  lw   a0, 0(s1)
  CHECK a0, 0x11ccbbaa, 14
  li   t0, 0xdd
  sb   t0, 3(s1)
  lw   a0, 0(s1)
  CHECK a0, 0xddccbbaa, 15
  lbu  a0, 3(s1)
  CHECK a0, 0xdd, 16

  li   t0, 0x11223344
  sw   t0, 4(s1)
  li   t0, 0xffffbeef         // only the low half may be written
  sh   t0, 4(s1)
  lw   a0, 4(s1)
  CHECK a0, 0x1122beef, 17
  li   t0, 0xcafe
  sh   t0, 6(s1)
  lw   a0, 4(s1)
  CHECK a0, 0xcafebeef, 18
  lh   a0, 6(s1)
  CHECK a0, 0xffffcafe, 19
  lhu  a0, 4(s1)
  CHECK a0, 0xbeef, 20

  // back-to-back partial stores to one word, then one load
  sw   x0, 8(s1)
  li   t0, 0x01
  li   t1, 0x02
  li   t2, 0x0403
  sb   t0, 8(s1)
  sb   t1, 9(s1)
  sh   t2, 10(s1)
  lw   a0, 8(s1)
  CHECK a0, 0x04030201, 21
  lw   a0, 0(s1)              // neighbours untouched
  CHECK a0, 0xddccbbaa, 22
  lw   a0, 4(s1)
  CHECK a0, 0xcafebeef, 23

  // ---- 3. load-use: the extended value is forwarded ----
  li   gp, 24
  li   t0, 0xff
  sb   t0, 12(s1)
  lb   t1, 12(s1)
  addi t2, t1, 1              // uses the lb result at once: -1 + 1 = 0
  bnez t2, fail
  li   gp, 25
  lbu  t1, 12(s1)
  addi t2, t1, 1              // 255 + 1
  li   t6, 256
  bne  t2, t6, fail
  li   gp, 26
  lb   t1, 12(s1)
  bltz t1, 1f                 // branch comparator on the lb result at once
  j    fail
1:li   gp, 27
  lh   t1, 6(s1)              // 0xcafe: negative
  nop
  srai t2, t1, 31             // one instruction later (forwarded from writeback)
  li   t6, -1
  bne  t2, t6, fail
  li   gp, 28
  lhu  t1, 6(s1)
  sw   t1, 16(s1)             // the zero-extended value as store data, at once
  lw   a0, 16(s1)
  li   t6, 0xcafe
  bne  a0, t6, fail

  // ---- 4. partial writes on L1D misses and evictions ----
  // mdata is preloaded and not in L1D yet: the byte store misses, the line is
  // fetched, and only byte 1 changes.
  la   s2, mdata              // 0x55667788
  li   t0, 0x99
  sb   t0, 1(s2)
  lw   a0, 0(s2)
  CHECK a0, 0x55669988, 29
  // Dirty the line again with a half-word, then evict it. Addresses 512 B
  // apart share an L1D line; 1 KB apart share an L2 set (2 ways, LRU).
  li   t0, 0x1234
  sh   t0, 2(s2)
  lw   a0, 512(s2)            // evicts mdata's line from L1D (write-back)
  lw   a0, 1024(s2)
  li   t3, 2048
  add  t3, s2, t3
  lw   a0, 0(t3)              // third line in the L2 set: evicts mdata's line
  lw   a0, 0(s2)              // back from DRAM
  CHECK a0, 0x12349988, 30
  lbu  a0, 3(s2)
  CHECK a0, 0x12, 31

  // ---- 5. byte loop: byte i = (3 + 7 i) & 0xff ----
  li   gp, 32
  li   s3, BYTES
  li   s4, NBYTES
  li   t0, 3
  li   t1, 0
2:add  t2, s3, t1
  sb   t0, 0(t2)
  addi t0, t0, 7
  andi t0, t0, 0xff
  addi t1, t1, 1
  bne  t1, s4, 2b
  addi t1, s4, -1             // read back from the last byte down
3:addi t0, t0, -7
  andi t0, t0, 0xff
  add  t2, s3, t1
  lbu  a0, 0(t2)
  bne  a0, t0, fail
  lb   a1, 0(t2)
  slli a2, t0, 24             // expected sign-extended byte
  srai a2, a2, 24
  bne  a1, a2, fail
  addi t1, t1, -1
  bgez t1, 3b
  lw   a0, 0(s3)              // bytes 03 0a 11 18
  CHECK a0, 0x18110a03, 33

  // ---- 6. half-word loop: half i = (0x8001 + 0x1235 i) & 0xffff ----
  li   gp, 34
  li   s5, HALVES
  li   s6, NHALF
  li   s7, 0x1235
  li   s8, 0xffff
  li   t0, 0x8001
  li   t1, 0
4:slli t2, t1, 1
  add  t2, t2, s5
  sh   t0, 0(t2)
  add  t0, t0, s7
  and  t0, t0, s8
  addi t1, t1, 1
  bne  t1, s6, 4b
  addi t1, s6, -1
5:sub  t0, t0, s7
  and  t0, t0, s8
  slli t2, t1, 1
  add  t2, t2, s5
  lhu  a0, 0(t2)
  bne  a0, t0, fail
  lh   a1, 0(t2)
  slli a2, t0, 16             // expected sign-extended half-word
  srai a2, a2, 16
  bne  a1, a2, fail
  addi t1, t1, -1
  bgez t1, 5b
  lw   a0, 0(s5)              // halves 0x8001, 0x9236
  CHECK a0, 0x92368001, 35

  j    pass

  TEST_END

  .data
  .balign 16
ldata: .word 0x80817f01
  .balign 64
mdata: .word 0x55667788
