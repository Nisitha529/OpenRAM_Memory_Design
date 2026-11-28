# fp16 Matrix-Multiply Accelerator with fp32 Results: Design Proposal

**Status:** proposal, not implemented yet. The PE and the converter were checked as sketches
against an exact reference model.
**Date:** 2026-11-24 (revised 2026-11-26)
**Applies to:** the accelerator in `rtl/accel/` (the PE, the systolic array and `matmul_accel`), plus
the matching testbenches and software
**Related:** [low_power_proposal.md](low_power_proposal.md): clock gating, zero skipping and matrix
reductions for the same accelerator

--------

## 1. Summary

The accelerator today multiplies 16-bit **integers**: each processing element (PE) multiplies two
int16 values and adds the product into a 40-bit integer. This proposal changes it to:

- **inputs:** fp16 (IEEE half precision), for A and B
- **results:** fp32 (IEEE single precision), for C

The main idea is that **the array never rounds.**

- Every fp16 × fp16 product is a whole number of tiny units (2⁻⁴⁸).
- Each PE adds these whole numbers exactly in an 89-bit integer accumulator.
- One shared converter rounds each finished result to fp32, once, as it leaves the array.

| | Today (int16) | Proposal (fp16 in, fp32 out) |
|---|---|---|
| PE area (sky130, synthesis) | 14,400 µm² | **14,250 µm²** |
| PE critical path, fastest mapping | 7.7 ns | **9.3 ns** (clock is 35 ns) |
| Result accuracy | exact integer | **exact dot product, rounded once to fp32** (best possible) |
| Extra hardware | — | one converter for the whole array (10,500 µm²) |
| C buffer | 256 × 40 bits | 256 × 32 bits |
| Compute cycles, 16×16 · 16×16 | 385 | 389 (+1 per tile) |
| A/B buffers, feeding, port list | — | **unchanged** |

The accelerator's ports don't change, so the SoC around the `matmul_accel` macro stays as it is.
Only the macro is re-hardened.

---

## 2. Background

### 2.1 The accelerator today

- An 8×8 **output-stationary** systolic array.
  - A values move east and B values move south.
  - PE(i, j) keeps one element of C in its accumulator.
- Matrices up to 16×16 are computed in 8×8 output tiles.
- A, B and C are held in flip-flop buffers inside the accelerator. A DMA engine loads A and B from
  memory and stores C back, through the L2 cache.
- Each tile takes `1 (clear) + K + 2N − 2 (feed) + N² + 1 (copy results out)` cycles.
- Each PE multiplies two 16-bit signed integers and adds the product into a 40-bit accumulator.

### 2.2 The fp16 and fp32 formats

| | fp16 (half) | fp32 (single) |
|---|---|---|
| Bits: sign / exponent / fraction | 1 / 5 / 10 | 1 / 8 / 23 |
| Exponent bias | 15 | 127 |
| Significand (with hidden 1) | 11 bits | 24 bits |
| Largest value | 65,504 | ≈ 3.4 × 10³⁸ |
| Smallest normal value | 2⁻¹⁴ ≈ 6.1 × 10⁻⁵ | 2⁻¹²⁶ ≈ 1.2 × 10⁻³⁸ |
| Smallest subnormal value | 2⁻²⁴ ≈ 6.0 × 10⁻⁸ | 2⁻¹⁴⁹ |
| Precision | ≈ 3.3 decimal digits | ≈ 7.2 decimal digits |

How the bits are read:

- **Normal numbers** (exponent field 1 to 30): value = (−1)ˢ × 1.f × 2^(e − 15)
- **Subnormal numbers** (exponent field 0): value = (−1)ˢ × 0.f × 2^(1 − 15). These are tiny
  numbers with no hidden 1.
- **Exponent field 31:** infinity and NaN. These are not supported here (§4.4).

### 2.3 Why the add, not the multiply, is the hard part

**A float multiply is cheap.**

- It multiplies the two significands and adds the two exponents.
- The fp16 significand multiplier (11 × 11 bits) is 5,030 µm². Today's 16 × 16 integer multiplier
  is 11,940 µm².

**A float add is expensive.** It has to:

1. line up the two numbers (shift the smaller one by the exponent difference)
2. add them
3. find the new leading 1
4. shift the result back into place
5. round it

**The add also sits in the accumulate loop.**

- Each new sum depends on the previous one and must finish in one cycle, because the next product
  arrives in the next cycle.
- You can split the multiply into its own pipeline stage, but not this loop.
- A PE that rounds into an fp32 accumulator after every add needs a **19 ns** loop even with the
  fastest cells. It is also much less accurate (§8).

---

## 3. The key idea: exact fixed-point accumulation

### 3.1 Every fp16 value is a whole number of small units

Take the 11-bit significand (with the hidden bit) and the exponent field, where an exponent of 0
counts as 1 for subnormals. Every finite fp16 value is the significand times a power of two between
2⁻²⁴ and 2⁵. So:

- **every fp16 value is a whole number of 2⁻²⁴ units,** below 2⁴⁰ of them;
- **every product of two fp16 values is a whole number of 2⁻⁴⁸ units,** below 2⁸⁰ of them.

Think of money counted in cents: once everything is a whole number of the smallest coin, adding is
exact.

### 3.2 How wide the accumulator must be

Each product is below 2⁸⁰ units, so a sum of K products is below K × 2⁸⁰. The accumulator needs
80 bits, plus log₂(K) bits of headroom, plus a sign bit:

| Largest K | Accumulator width |
|---|---|
| 16 (today's largest matrix size) | 85 bits |
| 256 | **89 bits (proposed default)** |

With 89 bits, even 256 products of the largest fp16 value (65,504² each) cannot overflow. The width
is a parameter: 85 bits is enough for today's 16×16 limit and saves 4 flip-flops per PE.

### 3.3 Why the result is the best possible fp32 answer

- **Nothing is rounded inside the array,** so the accumulator holds the exact dot product.
- **It is rounded once,** to nearest-even, so the fp32 result is the *correctly rounded* dot
  product: the fp32 number closest to the true answer.
- **The order of the additions doesn't matter.** Integer addition is exact, so the result is the
  same in any order.
- **The converter needs no special cases.** The exact sum can never overflow fp32 or become a
  subnormal:
  - the largest possible |sum| is below 2⁴⁰ ≈ 1.1 × 10¹², far below fp32's limit of 3.4 × 10³⁸;
  - every sum is a multiple of 2⁻⁴⁸, so the smallest nonzero |sum| is 2⁻⁴⁸, far above fp32's
    smallest normal number, 2⁻¹²⁶.

### 3.4 Why the PE multiplies first and shifts afterwards

Another way would be to turn each fp16 into a 41-bit integer at the edge of the array, and then
multiply integers in every PE. But that needs a 41 × 41-bit multiplier per PE, roughly 14× the size
of an 11 × 11 one.

The proposal does it the cheap way:

1. multiply the small 11-bit significands;
2. shift the 22-bit product into place.

The shift is a plain feed-forward step. The only thing left in the loop is an integer add, just as
in today's PE.

**Worked example:** a = 1.5, b = −0.25

| Step | Value |
|---|---|
| Unpack a | exponent 15, significand 1536 (= 1.5 × 1024) |
| Unpack b | exponent 13, significand 1024, negative |
| Multiply significands | 1536 × 1024 = 1,572,864; sign negative |
| Shift into place | by 15 + 13 − 2 = 26 places: 1,572,864 × 2²⁶ units |
| Check | 1,572,864 × 2²⁶ × 2⁻⁴⁸ = 0.375 = 1.5 × 0.25 ✓ |
| Accumulate | subtract 0.375 × 2⁴⁸ units from the accumulator |

---

## 4. The new PE

### 4.1 Datapath

```
 A input (fp16) ─► unpack ─┐
                           ├─► multiply 11×11 ─► shift into place ─► add / subtract ─► [ 89-bit accumulator ]
 B input (fp16) ─► unpack ─┘   sign = XOR of signs                         ▲                     │
                                                                           └─────────────────────┘
 A and B are also passed on to the next PE (east / south), exactly as today.
```

### 4.2 What happens in each cycle

All five steps happen in one clock cycle, like today's PE.

| Step | What it does | Notes |
|---|---|---|
| 1. Unpack | splits each input into a sign, an exponent and an 11-bit significand | the hidden bit is 1 unless the exponent field is 0; a subnormal uses exponent 1 with hidden bit 0, which makes subnormal inputs exact |
| 2. Multiply | multiplies the two significands (22-bit result); the sign is the XOR of the two signs | an 11 × 11 multiplier, less than half the size of today's |
| 3. Shift | shifts the product left by (exponent A + exponent B − 2) places, 0 to 58 | places the product at its true position, counted in units of 2⁻⁴⁸, inside an 80-bit field |
| 4. Add | adds the product, or subtracts it if the sign is negative | subtraction uses two's complement (invert, then add 1); the +1 goes in as the adder's carry-in, so there is still one adder |
| 5. Pass on | sends A east and B south | unchanged from today |

The clear and enable controls behave exactly as in today's PE.

### 4.3 Cost and timing

Measured with Yosys and ABC for the sky130 standard cells at the slow corner (ss, 100 °C, 1.60 V),
register to register, before layout:

| | Area | Critical path (mapped for area) | Critical path (fastest mapping) |
|---|---|---|---|
| Today's PE | 14,376 µm² | 12.9 ns | 7.7 ns |
| **Proposed PE** | **14,250 µm²** | 15.7 ns | **9.3 ns** |

The new PE fits one 35 ns cycle with a wide margin, so it needs no extra pipeline stage.

### 4.4 Limits

- **Inputs must be finite.** An exponent field of 31 (infinity or NaN) gives a meaningless result
  and no warning. If you need them later, add a 1-bit "special input seen" flag per PE and make the
  converter output NaN when it is set (§13).
- **K must not exceed** 256 for an 89-bit accumulator, or 16 for 85 bits.

---

## 5. The converter (exact sum → fp32)

### 5.1 What it does

It turns the 89-bit exact sum into an fp32 number, rounded to nearest-even:

| Step | What it does |
|---|---|
| 1. Sign and size | takes the sign, and the magnitude (negating the value if it is negative) |
| 2. Count leading zeros | finds where the leading 1 of the magnitude is |
| 3. Normalize | shifts the magnitude left so the leading 1 is in the top bit |
| 4. Keep 24 bits and round | keeps 24 bits; the first dropped bit is the *guard* bit, and the OR of everything below it is the *sticky* bit; rounds up if the guard bit is 1 and either the sticky bit or the last kept bit is 1 ("ties to even") |
| 5. Exponent | the top bit of the magnitude is worth 2³⁹, so the fp32 exponent is 127 + 39 − (leading zeros), plus 1 if rounding carried out of the 24 bits |

Overflow and subnormal handling aren't needed (§3.3). A zero sum gives +0.

### 5.2 Cost, and why only one is needed

- **Cost:** 10,500 µm².
  - Its path is 33 ns when mapped for area, or 16 ns with the fastest mapping.
  - That is too close to 35 ns to share a cycle with the array's read-out multiplexer, so it gets
    **its own pipeline stage** (§6.2).
- **Why one is enough:** results already leave the array one per cycle while a tile is copied into
  the C buffer. A single converter on that path serves all 64 PEs, so rounding costs one converter,
  not 64.

---

## 6. Changes to the accelerator

### 6.1 Systolic array

- **New PE.** The array uses the new PE with an 89-bit accumulator. The 16-bit operand paths
  between PEs don't change.
- **Wider read-out.** Results are still read through the existing multiplexer, which now carries
  89 bits instead of 40.
- **Option:** keep the integer PE selectable with a build parameter, so the existing integer tests
  keep working.
- **Clock gating.** The rebuild is the natural point to add the gating described in
  [low_power_proposal.md](low_power_proposal.md) (proposals 2 and 3).

### 6.2 Copying results out (drain)

**Today:**

1. A counter steps through the 64 PEs of a tile.
2. The array outputs one result per cycle.
3. The next cycle writes that result into the C buffer.

**Proposal:** put the converter between the array output and the C buffer, with one pipeline
register after it. Make the copy-out phase one cycle longer, so the tile counters don't move on
before the last result is written.

| Copy-out step | What happens |
|---|---|
| step N² − 1 | the last result of the tile is requested from the array |
| step N² | it arrives at the array output and passes through the converter |
| step N² + 1 | it is written into the C buffer; the sequencer moves to the next tile in the same cycle, while the tile position is still correct |

**Cost:** +1 cycle per tile. For 16×16 · 16×16 (4 tiles) that is 385 → 389 cycles; for
8×8 · 8×8, 89 → 90.

### 6.3 C buffer

The C buffer holds fp32 values (32 bits) instead of 40-bit integers.

- That is 2,048 fewer flip-flops.
- Judging by the current buffer area (about 0.75 mm² for 18,432 bits), it saves roughly 0.08 mm².
  This is an estimate.

### 6.4 C in memory (DMA store)

| | Today | Proposal |
|---|---|---|
| Element type | 64-bit integer | fp32 (4 bytes) |
| Elements per 16-byte line | 2 | 4 |
| Traffic for C | — | **half of today's** |
| Store sequence | two elements, then the line is sent | four elements, one per cycle (reusing the load path's word counter), then the line is sent |
| Padding | 8 bytes of zeros when M·P is odd | zeros fill the rest of the last line when M·P is not a multiple of 4 |

As today, software must reserve C rounded up to a whole 16-byte line.

### 6.5 Reading C over the register bus

| | Today | Proposal |
|---|---|---|
| Address of C[i][j] | 0x1000 + 8·(16i + j): low word, then upper bits | 0x1000 + 4·(16i + j): one fp32 word |
| Region | 0x1000–0x17FF | 0x1000–0x13FF |

Alternative: keep the 8-byte spacing, with the second word reading as 0, so existing software
offsets keep working.

### 6.6 A and B

**Phase 1: no change.**

- The buffers stay 16 bits wide and now hold fp16 values.
- Bus writes still take the low 16 bits of the written word.
- The DMA still takes the low 16 bits of each 32-bit word in memory.

**Phase 2: packed fp16, two values per 32-bit word.**

- This halves the A and B traffic, and in memory A and B become plain arrays of 16-bit values. The
  core's half-word loads and stores (`lh` / `sh`) already support that.
- The DMA unpacks 8 values per 16-byte line instead of 4.
- There are half as many line requests. Each line takes 8 unpack cycles instead of 4.

### 6.7 Register map after the change

| Address | Register | Change |
|---|---|---|
| 0x0000 | CTRL: bit 0 start, bit 1 DMA job | — |
| 0x0004 | STATUS: bit 0 busy, bit 1 done | — |
| 0x0008 | DIMS: M, K, P | — |
| 0x000C / 0x0010 / 0x0014 | BASE_A / BASE_B / BASE_C | — |
| 0x0400 | A[i][k] at +4·(16i + k): fp16 in the low half (write-only) | value is fp16 |
| 0x0800 | B[k][j] at +4·(16k + j): fp16 in the low half (write-only) | value is fp16 |
| 0x1000 | C[i][j] at +4·(16i + j): fp32 (read-only) | 4-byte spacing, fp32 |

---

## 7. Software interface

### 7.1 Data formats

| Matrix | Phase 1 | Phase 2 |
|---|---|---|
| A, B | one 32-bit word per value, fp16 in the low half | two fp16 values per word |
| C | one fp32 value per element, total size rounded up to 16 bytes | same |

All matrices are row-major, with base addresses aligned to 16 bytes.

### 7.2 Running a job

The sequence is the same as in today's `test_matmul` program:

1. **Set up the job:** write the base addresses of A, B and C, then the sizes M, K and P.
2. **Flush the L1 data cache,** so A and B reach the L2 where the DMA can read them. Wait until
   the flush is finished.
3. **Start** a DMA job: CTRL = 3.
4. **Wait** until STATUS shows *done*.
5. **Invalidate the L1 data cache,** so the CPU doesn't read stale copies of C. Wait until this is
   finished.
6. **Read C** as fp32 values.

### 7.3 Checking results on the CPU

**Before Zfinx (upgrade 5):** the core has no floating point.

- The tests compare C bit for bit against expected fp32 values.
- Those values are computed at build time by a script, using exact arithmetic.

**With Zfinx:** the CPU can compute a reference with its fused multiply-add instruction.

- That reference rounds after every add, so it is *less* accurate than the accelerator, and the
  two will not always match bit for bit (§8).
- Compare with a tolerance scaled to the size of the terms (the sum of |a·b|), not to the result.
  With cancellation, the CPU's error can be large compared with a small result.

---

## 8. Accuracy

The table compares two kinds of accumulator against the correctly rounded fp32 dot product:

- **per-add fp32:** an accumulator that rounds to fp32 after every add. This is what a simple
  float PE or a CPU multiply-add loop does.
- **this proposal:** the exact accumulator, rounded once.

"ulp" means one step in the last bit of the fp32 result. The inputs are random fp16 values.

| Data | K | Per-add fp32: results not the best fp32 answer | Per-add fp32: worst error | This proposal |
|---|---|---|---|---|
| values around ±1, with cancellation | 16 | 53.9 % | 320 ulp | **0 %, ≤ 0.5 ulp** |
| values in [0, 1), sums only grow | 16 | 47.6 % | 2.6 ulp | **0 %, ≤ 0.5 ulp** |
| values around ±1, with cancellation | 256 | 89.2 % | 151 ulp | **0 %, ≤ 0.5 ulp** |
| values in [0, 1), sums only grow | 256 | 83.2 % | 9.4 ulp | **0 %, ≤ 0.5 ulp** |

There were 3,000 dot products for K = 16 and 400 for K = 256.

The large errors come from **cancellation**:

- When big positive and negative terms almost cancel, the result is small.
- But the rounding errors made along the way were sized to the big intermediate sums.
- The exact accumulator has no such errors.

---

## 9. Cost and timing summary

Synthesis estimates, sky130 standard cells at the slow corner, before layout:

| Block | Count | Area each | Total |
|---|---|---|---|
| PE, today (int16) | 64 | 14,376 µm² | 0.92 mm² |
| **PE, proposed** | 64 | **14,250 µm²** | **0.91 mm²** |
| Converter | 1 | 10,500 µm² | 0.01 mm² |
| C buffer | — | — | about −0.08 mm² (32 instead of 40 bits) |
| Read-out multiplexer | 1 | grows from 40 to 89 bits wide | not measured |

**Overall:** about the same size as today. These numbers come from a stand-alone synthesis, so they
compare designs against each other. The README's figures (64 PEs ≈ 1.27 mm²) come from the OpenLane
run.

**Timing:**

- The PE path is 9.3–15.7 ns.
- The converter path is 16–33 ns, in its own stage.
- Both are inside the 35 ns clock, before wire delay. The OpenLane run of the accelerator macro is
  the real check.

---

## 10. Alternatives considered

All of these were sketched, checked against an exact reference, and synthesized the same way.
"Area" is mapped for area at a 35 ns target; "fastest" is the shortest path the mapper could reach.

| Design (inputs → accumulator) | Area | Fastest path | Accuracy, fp32 results | Notes |
|---|---|---|---|---|
| **fp16 → exact 89-bit (proposal)** | **14,250 µm²** | **9.3 ns** | **always correctly rounded** | integer add in the loop |
| fp16 → fp32, rounded every add | 13,430 µm² | 19.1 ns | 48–89 % not the best answer, up to 320 ulp | matches the CPU's multiply-add bit for bit; long loop |
| bf16 → fp32, rounded every add | 11,211 µm² | 19.4 ns | fewer input bits (8 vs 11) | 8-bit exponent: an exact accumulator would need ~550 bits |
| fp16 → fp16 accumulator | 11,745 µm² | 20.2 ns | unusable (see §13.1) | not faster, only 18 % smaller |
| fp16 → exact, cut to 71 bits | 12,977 µm² | 8.8 ns | wrong for small results | saves 9 %; fails near fp16's smallest values |
| fp32 → fp32, one cycle | 41,445 µm² | 31.2 ns | — | misses 35 ns once mapped for area (37 ns) |
| fp32 → fp32, multiply pipelined | 37,754 µm² | 19.4 ns | — | 2.6× the PE; only a 4×4 array fits today's area |

Multipliers alone, for reference:

| Multiplier | Area |
|---|---|
| int16 × int16 (today) | 11,940 µm² |
| 11 × 11 bits (fp16) | 5,030 µm² |
| 8 × 8 bits (bf16) | 2,744 µm² |
| 24 × 24 bits (fp32) | 22,316 µm² |

**Why the proposal wins:**

- It keeps today's PE size and a short loop.
- It gives the best possible fp32 result.
- It needs no float adder anywhere, only one shared rounding unit.

---

## 11. Verification plan

### 11.1 Already done, at sketch level

The PE and the converter were compared with an exact reference model on 400 dot products of 16
terms each, including:

- random exponents over the whole fp16 range
- subnormal inputs (141 of the 400 cases)
- all-maximum inputs (±65,504)
- the smallest subnormals
- near-total cancellation

All accumulator values and all fp32 results matched exactly. An 85-bit build also matched.

### 11.2 To do with the real design

1. **PE unit test.**
   - The reference model must work differently from the PE, so it doesn't share its mistakes: it
     converts each fp16 to a large integer first, then multiplies and adds.
   - Compare the accumulator exactly.
2. **Converter unit test.**
   - Compare against expected values generated by a script (correctly rounded fp32 of exact
     values).
   - Include exact halfway ties, rounding that carries into the exponent, negative values and zero.
3. **Array test:** the same reference for every PE, with random stalls and clears between products,
   as today.
4. **Accelerator test:**
   - Products both through the register bus and through DMA.
   - Partial tiles, K = 1, 1×1 matrices, worst-case magnitudes, subnormals.
   - Check the new C memory layout: 4 values per line and zero padding.
5. **SoC test:** a new fp16 matrix-multiply program, with inputs and expected results generated by
   a script. It compares C bit for bit and joins the regression run.
6. **Mutation checks.** Each of these deliberate bugs must make a test fail:
   - a missing carry-in for negative products
   - an off-by-one shift
   - subnormals flushed to zero
   - no extra copy-out cycle
   - a converter that rounds halfway cases up instead of to even
7. **Gate level:** rerun the accelerator's gate-level test on the new macro netlist.

---

## 12. Implementation steps

| # | Step | Where |
|---|---|---|
| 1 | New PE and converter, with unit tests | `rtl/accel/`, `sim/` |
| 2 | Array: new PE and wider accumulator, with the integer PE kept as an option | systolic array and its testbench |
| 3 | Accelerator: converter stage, 32-bit C buffer, 4-per-line C store, C bus read | `matmul_accel` and its testbench |
| 4 | Software test with generated data | `sw/`, `sim/run.sh` |
| 5 | OpenLane: re-harden the accelerator macro, then the SoC | `asic/systolic_array/`, then the SoC run |
| 6 | Phase 2: packed fp16 DMA for A and B | `matmul_accel`, tests |
| 7 | Documentation | `README.md` accelerator section |

Steps 1–4 can be done and checked in simulation before any OpenLane run. Clock gating
([low_power_proposal.md](low_power_proposal.md), proposals 1–3) fits into steps 1–3, because the PE
and the buffers are being rebuilt then anyway.

---

## 13. Future extensions

### 13.1 fp16 results

Only the converter changes: it rounds to fp16 instead (9,650 µm²). Accuracy against the correctly
rounded fp16 result (random values around ±1):

| Accumulator | Results not the best fp16 answer, K = 16 | K = 256 |
|---|---|---|
| fp16, rounded every add | 62 % (up to 370 ulp) | 89 % (up to 3,600 ulp) |
| fp32, rounded every add, then to fp16 | 0.03 % | 0.25 % (≤ 1.1 ulp) |
| **exact (this design), then to fp16** | **0 %** | **0 %** |

Things to add for fp16 output:

- **Overflow:** fp16's largest value is 65,504, and a dot product passes it easily. Choose
  infinity or "saturate at 65,504"; either is free.
- **A power-of-2 output scale register:** with the exact accumulator this only moves the binary
  point, so it is almost free.
- **A 16-bit C buffer.**
- **Do not shorten the accumulator:** for small values, cutting it to 71 bits made 1.6 % of results
  wrong, and cutting it to 67 bits made 27 % wrong.

### 13.2 fp32 inputs

The exact trick doesn't work, because fp32's 8-bit exponent would need ~560-bit accumulators. You
would need:

- a fused fp32 multiply-add PE with the multiply in its own pipeline stage (37,750 µm²);
- a 4×4 array, to stay near today's area.

Moving data already takes most of a job (about 2,400 of 2,768 cycles for 16×16), so the smaller
array adds little total time: about 640 compute cycles instead of 385.

### 13.3 Others

- **Infinity / NaN inputs:** a "special input seen" flag per PE, and NaN output when it is set
  (§4.4).
- **Overlap the read-out of one tile with the next tile's compute.** Copying takes N² + 2 of the
  ≈ 97 cycles per tile.
- **Larger matrices:** the 89-bit accumulator already supports K up to 256. The buffer sizes set the
  limit.
- **Power:** see [low_power_proposal.md](low_power_proposal.md): clock gating, zero skipping,
  weight reuse, tile skipping, lower precision and low-rank factorization.

---

## Appendix: how the numbers were measured

- **Synthesis:**
  - **Tool and library:** Yosys 0.9 with ABC, using the sky130 high-density standard-cell library
    at the slow corner (ss, 100 °C, 1.60 V).
  - **Setup:** each block had registered inputs and outputs and was flattened.
  - **Two mappings per block:** one targeting 35 ns with the smallest area, one with the shortest
    path.
  - **Limits:** there are no wires, so treat the results as comparisons between designs.
- **Accuracy:**
  - Exact dot products and correct rounding were computed with exact rational arithmetic in Python.
  - The per-add accumulators were modelled with numpy's fp32 and fp16 types.
  - Products of two fp16 values are exact in fp32, so an fp32 loop reproduces the per-add fp32
    accumulator exactly.
- **Functional checks of the sketches:** Icarus Verilog simulations with random vectors, with every
  result compared against the exact model.
