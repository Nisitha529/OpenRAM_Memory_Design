// Helpers shared by the test programs.
// gp (x3) holds the number of the check being run, t6 the expected value.

// Compare a register with a constant; jump to fail with gp = test number
.macro CHECK reg, val, num
  li   gp, \num
  li   t6, \val
  bne  \reg, t6, fail
.endm

// Compare two registers
.macro CHECKR reg1, reg2, num
  li   gp, \num
  bne  \reg1, \reg2, fail
.endm

// End of test: tohost <- 1 (pass) or (gp << 1) | 1 (fail at check gp)
.macro TEST_END
pass:
  li   a0, 1
  j    write_tohost
fail:
  slli a0, gp, 1
  ori  a0, a0, 1
write_tohost:
  la   t0, tohost
  sw   a0, 0(t0)
1: j 1b
.endm
