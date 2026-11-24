# fp16 Matrix-Multiply Accelerator with fp32 Results: Design Proposal

**Status:** proposal, not implemented yet. The PE and converter below exist as checked sketches;
the `matmul_accel` changes are proposed code, not simulated yet.
**Date:** 2026-11-24
**Applies to:** `rtl/accel/` (`systolic_pe.v`, `systolic_array.v`, `matmul_accel.v`) and the
matching testbenches and software.

---

## 1. Summary

The accelerator today multiplies 16-bit **integers**: each processing element (PE) computes
int16 × int16 and adds the product into a 40-bit integer. This proposal changes it to:

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

The accelerator's ports don't change, so the SoC RTL around the `matmul_accel` macro stays as it
is. Only the macro is re-hardened.

---

## 2. Background

### 2.1 The accelerator today

- An 8×8 **output-stationary** systolic array.
  - A values move east and B values move south.
  - PE(i, j) keeps one element of C in its accumulator.
- Matrices up to 16×16 (`MAX_DIM = 16`) are computed in 8×8 output tiles.
- A, B and C are held in flip-flop buffers inside the accelerator. A DMA engine loads A and B
  from memory and stores C back, through the L2.
- Cycles per tile: `1 (clear) + K + 2N − 2 (feed) + N² + 1 (copy results out)`.
- The PE ([systolic_pe.v](../rtl/accel/systolic_pe.v)) is
  `acc <= acc + a_in * b_in`, with 16-bit signed operands and a 40-bit accumulator.

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
- **Exponent field 31:** infinity and NaN. These are not supported here (see §4.4).

### 2.3 Why the add, not the multiply, is the hard part

**A float multiply is cheap.**

- It multiplies the two significands and adds the two exponents.
- The fp16 significand multiplier (11 × 11) is 5,030 µm². Today's 16 × 16 integer multiplier is
  11,940 µm².

**A float add is expensive.** It has to:

1. line up the two numbers (shift the smaller one by the exponent difference)
2. add them
3. find the new leading 1
4. shift the result back into place
5. round it

**The add also sits in the accumulate loop.**

- `acc(t+1) = acc(t) + product(t)` must finish in one cycle, because the next product arrives
  in the next cycle.
- You can split the multiply into its own pipeline stage, but not this loop.
- A PE that rounds into an fp32 accumulator after every add needs a **19 ns** loop even with the
  fastest cells. It is also much less accurate (§8).

---

## 3. The key idea: exact fixed-point accumulation

### 3.1 Every fp16 value is a whole number of small units

Write `sig` for the 11-bit significand (with the hidden bit). Write `e_eff` for the exponent
field, with 0 replaced by 1 for subnormals. Then every finite fp16 value is

```
value = ± sig × 2^(e_eff − 25)        so        value × 2^24 = ± sig × 2^(e_eff − 1)
```

The right-hand side is a whole number of magnitude below 2¹¹ × 2²⁹ = 2⁴⁰. So **every fp16 is a
whole number of 2⁻²⁴ units, and every product of two fp16 values is a whole number of 2⁻⁴⁸ units,
below 2⁸⁰.**

Think of money counted in cents: once everything is a whole number of the smallest coin, adding
is exact.

### 3.2 How wide the accumulator must be

Each product is below 2⁸⁰ units, so a sum of K products is below K × 2⁸⁰:

```
ACC_WIDTH = 80 + log2(K_max) + 1 (sign)
```

| K_max | ACC_WIDTH |
|---|---|
| 16 (today's `MAX_DIM`) | 85 |
| 256 | **89 (proposed default)** |

With 89 bits, even K = 256 products of the largest fp16 values (65,504² each) cannot overflow.
The width is a parameter: 85 bits is enough for today's `MAX_DIM` and saves 4 flip-flops per PE.

### 3.3 Why the result is the best possible fp32 answer

- **Nothing is rounded inside the array,** so the accumulator holds the exact dot product.
- **It is rounded once,** to nearest-even, so the fp32 result is the *correctly rounded* dot
  product: the fp32 number closest to the true answer.
- **The order of the additions doesn't matter.** Integer addition is exact, so the result is the
  same in any order.
- **The converter needs no special cases.** The exact sum can never overflow fp32 or become a
  subnormal:
  - the largest possible |sum| is below 2⁸⁸ units = 2⁴⁰ ≈ 1.1 × 10¹², far below 3.4 × 10³⁸;
  - every sum is a multiple of 2⁻⁴⁸, so the smallest nonzero |sum| is 2⁻⁴⁸, far above fp32's
    smallest normal number, 2⁻¹²⁶.

### 3.4 Why the PE multiplies first and shifts afterwards

Another way would be to turn each fp16 into a 41-bit integer at the edge of the array, and then
multiply integers in every PE. But that needs a 41 × 41 multiplier per PE, roughly (41/11)² ≈ 14×
the size of an 11 × 11 one.

The proposal does it the cheap way:

1. multiply the 11-bit significands;
2. shift the 22-bit product into place by `ea + eb − 2`.

The shift is a plain feed-forward step. The only thing in the loop is the integer add.

**Worked example:** `a = 1.5` (fp16 `0x3E00`), `b = −0.25` (fp16 `0xB400`)

| Step | a | b | Result |
|---|---|---|---|
| unpack | e = 15, sig = 1536 (1.5 × 1024) | e = 13, sig = 1024, negative | |
| multiply | | | 1536 × 1024 = 1,572,864; sign negative |
| shift | | | by 15 + 13 − 2 = 26: 1,572,864 × 2²⁶ units |
| check | | | 1,572,864 × 2²⁶ × 2⁻⁴⁸ = 0.375 = 1.5 × 0.25 ✓ |
| accumulate | | | `acc ← acc − 0.375 × 2⁴⁸` |

---

## 4. The PE: `systolic_pe_fp16`

### 4.1 Datapath

```
 a_in (fp16) ─► 1 unpack ─┐
                          ├─► 2 multiply 11×11 ─► 3 shift left ─► 4 add / subtract ─► [ acc, 89 bits ]
 b_in (fp16) ─► 1 unpack ─┘    sign = sa XOR sb     by ea+eb−2           ▲                    │
                                                                         └────────────────────┘
 5: a_in ─► [reg] ─► a_out (east)          b_in ─► [reg] ─► b_out (south)
```

1. **Unpack** each input into a sign, an exponent and an 11-bit significand.
   - The hidden bit is 1 unless the exponent field is 0.
   - A subnormal uses exponent 1 with hidden bit 0. This one rule makes subnormal inputs exact.
2. **Multiply** the significands, giving 22 bits. The sign is the XOR of the two signs.
3. **Shift** the product left by `ea + eb − 2` (0 to 58 places). It now sits at its true position,
   counted in units of 2⁻⁴⁸, inside an 80-bit field.
4. **Add** the product, or subtract it if the sign is negative.
   - Subtraction uses two's complement: invert the bits and add 1.
   - The +1 goes in as the adder's carry-in, so there is still just one adder.
5. **Pass on** `a_in` and `b_in` to the next PEs, exactly as today.

`clear` and `en` behave exactly as in today's PE.

### 4.2 Code (checked sketch)

```verilog
// Proposed PE: fp16 inputs, exact fixed-point accumulator.
//
// Every fp16 x fp16 product is a whole number of units of 2^-48, below 2^80,
// so the PE adds products as integers and never rounds. 8 spare bits allow
// K <= 256 even if every product is the largest possible. The result is
// rounded once, to fp32, by fixed_to_fp32 when it is read out of the array.
// Subnormal inputs are exact too; inf / NaN inputs are not supported.
module systolic_pe_fp16 #(
  parameter ACC_WIDTH = 89
) (
  input                             clk,
  input                             rst_n,
  input                             clear,
  input                             en,
  input      [15:0]                 a_in,    // fp16 from the west
  input      [15:0]                 b_in,    // fp16 from the north
  output reg [15:0]                 a_out,
  output reg [15:0]                 b_out,
  output reg signed [ACC_WIDTH-1:0] acc      // sum of a*b in units of 2^-48
);
  // 1. unpack: subnormals (exponent 0) have no hidden 1 and count as exponent 1
  wire        ha = |a_in[14:10],  hb = |b_in[14:10];
  wire [4:0]  ea = ha ? a_in[14:10] : 5'd1;
  wire [4:0]  eb = hb ? b_in[14:10] : 5'd1;
  // 2. multiply the 11-bit significands; the sign is the XOR of the signs
  wire [21:0] sig  = {ha, a_in[9:0]} * {hb, b_in[9:0]};
  wire        sign = a_in[15] ^ b_in[15];
  // 3. move the product to its place: shift by ea + eb - 2 (0 .. 58)
  wire [79:0] mag  = {58'd0, sig} << (ea + eb - 6'd2);
  // 4. add or subtract it (two's complement: invert and add 1 for negatives)
  wire [ACC_WIDTH-1:0] term = {ACC_WIDTH{sign}} ^ {{(ACC_WIDTH-80){1'b0}}, mag};

  always @(posedge clk) begin
    if (!rst_n || clear) begin
      a_out <= 16'd0;
      b_out <= 16'd0;
      acc   <= {ACC_WIDTH{1'b0}};
    end else if (en) begin
      a_out <= a_in;                         // 5. pass the operands on
      b_out <= b_in;
      acc   <= acc + term + sign;
    end
  end
endmodule
```

### 4.3 Cost and timing

Measured with Yosys + ABC for sky130_fd_sc_hd at the slow corner (ss, 100 °C, 1.60 V), register to
register, before layout:

| | Area | Critical path |
|---|---|---|
| Today's `systolic_pe` | 14,376 µm² | 12.9 ns (mapped for area) / 7.7 ns (fastest) |
| `systolic_pe_fp16` | **14,250 µm²** | 15.7 ns (mapped for area) / **9.3 ns** (fastest) |

The new PE fits one 35 ns cycle with a wide margin, so it needs no extra pipeline stage.

### 4.4 Limits

- **Inputs must be finite.** An exponent field of 31 (infinity or NaN) gives a meaningless result
  and no warning. If you need them later, add a 1-bit sticky "special input seen" flag per PE and
  make the converter output NaN when it is set (§13).
- **K must not exceed 2^(ACC_WIDTH − 81):** 256 for 89 bits, 16 for 85 bits.

---

## 5. The converter: `fixed_to_fp32`

### 5.1 What it does

It turns the 89-bit exact sum into fp32 with round-to-nearest-even:

1. **Sign and size:** take the sign bit and the magnitude (negate if negative).
2. **Leading-zero count:** count the leading zeros `lz` of the 88-bit magnitude.
3. **Normalize:** shift left by `lz`, so the leading 1 is in the top bit.
4. **Keep 24 bits** for the significand, then round. The first dropped bit is the *guard* bit,
   and the OR of everything below it is the *sticky* bit. Round up if guard = 1 and
   (sticky = 1 or the last kept bit = 1). That is "ties to even".
5. **Exponent:** the top bit of the magnitude is worth 2^(87 − 48) = 2³⁹, so the fp32 exponent
   field is `127 + 39 − lz`, plus 1 if rounding carried out of the 24 bits.

Overflow and subnormal handling aren't needed (§3.3). A zero sum gives +0.

### 5.2 Code (checked sketch)

```verilog
module fixed_to_fp32 #(parameter ACC_WIDTH = 89) (
  input  [ACC_WIDTH-1:0] x,        // exact sum, units of 2^-48, two's complement
  output [31:0]          f         // fp32, round to nearest, ties to even
);
  localparam MW = ACC_WIDTH - 1;                   // magnitude bits
  wire          s = x[ACC_WIDTH-1];
  wire [MW-1:0] m = s ? -x[MW-1:0] : x[MW-1:0];    // |x|
  reg  [6:0]    lz;                                // leading zeros of m
  integer i;
  always @* begin
    lz = MW;
    for (i = 0; i < MW; i = i + 1) if (m[i]) lz = MW - 1 - i;
  end
  wire [MW-1:0] n   = m << lz;                     // leading 1 moved to the top bit
  wire          rup = n[MW-25] & ((|n[MW-26:0]) | n[MW-24]);
  wire [24:0]   r   = {1'b0, n[MW-1 -: 24]} + rup; // keep 24 bits, round
  wire [8:0]    e   = 9'd127 + (MW - 1 - 48) - lz + r[24];
  assign f = (m == 0) ? 32'd0 : {s, e[7:0], r[24] ? r[23:1] : r[22:0]};
endmodule
```

### 5.3 Cost, and why only one is needed

- **Cost:** 10,500 µm².
  - Its path is 33 ns when mapped for area and 16.2 ns at the fastest mapping.
  - That is too close to 35 ns to share a cycle with the read-out mux, so it gets **its own
    pipeline register** (§6.2).
- **Why one is enough:** results already leave the array one per cycle, through `rd_data`, while
  the tile is copied into the C buffer. A single converter on that path serves all 64 PEs, so
  rounding costs one converter, not 64.

---

## 6. Changes to the accelerator

### 6.1 `systolic_array.v`

- Instantiate `systolic_pe_fp16` instead of `systolic_pe`, with `ACC_WIDTH = 89`. `DATA_WIDTH`
  stays 16.
- The read-out (`rd_data <= acc[rd_row][rd_col]`) stays the same but is now 89 bits wide, so the
  64-to-1 read mux grows from 40 to 89 bits.
- Option: keep the int16 PE selectable with a parameter (for example `parameter FP16 = 1` and a
  `generate if`), so the existing integer tests keep working.

### 6.2 Read-out (drain) pipeline in `matmul_accel.v`

**Today:**

1. During `S_DRAIN`, `dr` counts 0 … N².
2. The array registers `acc[dr]` into `rd_data`.
3. One cycle later, `drain_v` / `dr_q` write it into `cbuf`.

**Proposal:** add the converter and one register stage, `cvt_q` / `cvt_v` / `cvt_idx`, and let
`S_DRAIN` last one extra cycle. If the tile counters `ti` / `tj` advanced earlier, they would
change before the last result is written.

```verilog
  // copy array results into the C buffer, through the converter
  wire [31:0] rd_fp32;
  fixed_to_fp32 #(.ACC_WIDTH(ACC_WIDTH)) u_cvt (.x(rd_data), .f(rd_fp32));

  reg [31:0]       cvt_q;      // converted result
  reg              cvt_v;      // cvt_q holds a result to store
  reg [2*LOGN-1:0] cvt_idx;    // its position in the tile

  always @(posedge clk) begin
    if (!rst_n) begin
      drain_v <= 1'b0;  dr_q <= 0;  cvt_v <= 1'b0;  cvt_idx <= 0;
    end else begin
      drain_v <= (state == S_DRAIN) && (dr < N*N);   // was: dr != N*N
      dr_q    <= dr[2*LOGN-1:0];
      cvt_v   <= drain_v;
      cvt_idx <= dr_q;
    end
    cvt_q <= rd_fp32;
  end

  // c_row / c_col are now computed from cvt_idx instead of dr_q
  always @(posedge clk)
    if (cvt_v && c_row < dim_m && c_col < dim_p)
      cbuf[{c_row[IDX_W-1:0], c_col[IDX_W-1:0]}] <= cvt_q;
```

In the sequencer, `S_DRAIN` waits one more cycle before moving to the next tile:

```verilog
        S_DRAIN: begin
          if (dr != N*N + 1)          // was: N*N (one more cycle for the converter)
            dr <= dr + 1'b1;
          else begin
            ...                       // next tile / S_STORE / done, unchanged
          end
        end
```

Timing check:

- The last result is requested when `dr = N² − 1`, arrives in `rd_data` at `dr = N²`, and is
  converted into `cvt_q`.
- It is written into `cbuf` at `dr = N² + 1`, the same cycle the sequencer leaves `S_DRAIN`, so
  `ti` / `tj` are still correct.
- `dr` is `2·log2(N) + 1` bits wide (7 bits for N = 8), so it can hold N² + 1 = 65.

**Cost:** +1 cycle per tile. For 16×16 · 16×16 (4 tiles) that is 385 → 389 cycles; for
8×8 · 8×8, 89 → 90.

### 6.3 C buffer

`reg [31:0] cbuf [0:ELEMS-1]` holds fp32 bit patterns, instead of 40-bit integers.

- That is 2,048 fewer flip-flops.
- Judging by the current buffer area (about 0.75 mm² for 18,432 bits), it saves roughly
  0.08 mm². This is an estimate.

### 6.4 C in memory (DMA store)

**Layout:** C is `float C[M][P]`, row-major, 4 bytes per element, 4 elements per 16-byte line.
Today it is 8-byte int64, 2 per line. **This halves the C traffic.**

**Store sequence:** the `C_RD0` / `C_RD1` phases become one `C_FILL` phase. It writes word `ld_w`
of `line_q` each cycle and reuses the 2-bit word counter of the load path. After word 3 the
request goes out as today.

```verilog
            C_FILL: begin                                       // one fp32 per cycle
              line_q[{ld_w, 5'd0} +: 32] <= (left != 0) ? c_word : 32'd0;   // zero-pad the last line
              if (left != 0) begin
                left <= left - 1'b1;
                if (row_last) begin mj <= 0; mi <= mi + 1'b1; end
                else mj <= mj + 1'b1;
              end
              ld_w <= ld_w + 1'b1;
              if (ld_w == 2'd3) ph <= C_REQ;
            end
```

`ld_w` must be 0 when `S_STORE` starts and when each new line starts.

**Padding:** when M·P is not a multiple of 4, the rest of the last line is written as zeros.
Software must reserve C rounded up to 16 bytes, just as it does today.

### 6.5 C over the register bus

| | Today | Proposal |
|---|---|---|
| Address | `0x1000 + 8·(16i + j)`: low word, then upper bits | `0x1000 + 4·(16i + j)`: one fp32 word |
| Region | `0x1000`–`0x17FF` | `0x1000`–`0x13FF` |
| Decode | `c_idx = addr[3 +: 2*IDX_W]` | `c_idx = addr[2 +: 2*IDX_W]`, `in_c = (addr[12:10] == 3'b100)` |
| Read data | `addr[2] ? c_ext[63:32] : c_ext[31:0]` | `c_word` |

Alternative: keep the 8-byte stride, with `+4` reading as 0, so existing software offsets still
work.

### 6.6 A and B

**Phase 1: no change.**

- The buffers stay 16 bits wide and now hold fp16 bit patterns.
- Bus writes still take `wdata[15:0]`.
- The DMA still takes bits [15:0] of each 32-bit word.

**Phase 2: packed fp16, two per 32-bit word.**

- This halves the A/B traffic, and in memory A and B become plain `uint16_t` arrays. The core's
  `lh` / `sh` already support that.
- `ld_w` becomes 3 bits (8 elements per line), and the extraction becomes
  `dma_word = line_q[{ld_w, 4'd0} +: 16]`.
- The number of line requests is halved. Each line takes 8 unpack cycles instead of 4.

### 6.7 Register map after the change

| Address | Register | Change |
|---|---|---|
| `0x0000` | CTRL: bit 0 start, bit 1 DMA job | — |
| `0x0004` | STATUS: bit 0 busy, bit 1 done | — |
| `0x0008` | DIMS: [4:0] M, [12:8] K, [20:16] P | — |
| `0x000C` / `0x0010` / `0x0014` | BASE_A / BASE_B / BASE_C | — |
| `0x0400` | A[i][k] at `+4·(16i + k)`: fp16 in bits [15:0] (write-only) | value is fp16 |
| `0x0800` | B[k][j] at `+4·(16k + j)`: fp16 in bits [15:0] (write-only) | value is fp16 |
| `0x1000` | C[i][j] at `+4·(16i + j)`: fp32 (read-only) | 4-byte stride, fp32 |

---

## 7. Software interface

### 7.1 Data formats

| Matrix | Phase 1 | Phase 2 |
|---|---|---|
| A, B | `uint32_t[]`, fp16 bit pattern in the low half of each word | `uint16_t[]` (packed fp16) |
| C | `float[]` / `uint32_t[]` fp32 bit patterns, rows rounded up to 16 bytes in total | same |

All matrices are row-major, with bases aligned to 16 bytes.

### 7.2 Running a job

This is the same sequence as `sw/test_matmul.S`. Shown here in C as an illustration:

```c
#define ACC      ((volatile uint32_t *)0x40000000)
#define SYSCTRL  (*(volatile uint32_t *)0x40010000)

void accel_matmul(const void *A, const void *B, void *C, int m, int k, int p) {
  ACC[3] = (uint32_t)A;  ACC[4] = (uint32_t)B;  ACC[5] = (uint32_t)C;  // BASE_A/B/C
  ACC[2] = m | (k << 8) | (p << 16);                                   // DIMS
  SYSCTRL = 1;  while (SYSCTRL & 1);   // flush L1D: A and B reach the L2
  ACC[0] = 3;                          // start a DMA job
  while (!(ACC[1] & 2));               // wait for STATUS.done
  SYSCTRL = 2;  while (SYSCTRL & 1);   // invalidate L1D: drop stale copies of C
}
```

### 7.3 Checking results on the CPU

**Before Zfinx (upgrade 5):** the core has no floating point.

- The tests compare C bit for bit against expected fp32 patterns.
- Those patterns are computed at build time by a Python script, using exact fractions.

**With Zfinx:** the CPU can compute a reference with `fmadd.s`.

- That reference rounds after every add, so it is *less* accurate than the accelerator, and the
  two will not always match bit for bit (§8).
- Compare with a tolerance scaled to Σ|a·b| (the size of the terms), not to the result. With
  cancellation, the CPU's error can be large compared with a small result.

---

## 8. Accuracy

The table compares two kinds of accumulator against the correctly rounded fp32 dot product:

- **per-add fp32:** an accumulator that rounds to fp32 after every add. This is what a simple
  float PE or a CPU `fmadd.s` loop does.
- **this proposal:** the exact accumulator, rounded once.

"ulp" means one step in the last bit of the fp32 result. The inputs are random fp16 values.

| Data | K | Per-add fp32: results not the best fp32 answer | Per-add fp32: worst error | This proposal |
|---|---|---|---|---|
| values ~ N(0, 1), with cancellation | 16 | 53.9 % | 320 ulp | **0 %, ≤ 0.5 ulp** |
| values in [0, 1), sums only grow | 16 | 47.6 % | 2.6 ulp | **0 %, ≤ 0.5 ulp** |
| values ~ N(0, 1), with cancellation | 256 | 89.2 % | 151 ulp | **0 %, ≤ 0.5 ulp** |
| values in [0, 1), sums only grow | 256 | 83.2 % | 9.4 ulp | **0 %, ≤ 0.5 ulp** |

There were 3,000 dot products for K = 16 and 400 for K = 256.

The large errors come from **cancellation**:

- When big positive and negative terms almost cancel, the result is small.
- But the rounding errors made along the way were sized to the big intermediate sums.
- The exact accumulator has no such errors.

---

## 9. Cost and timing summary

Synthesis estimates, sky130_fd_sc_hd at the slow corner, before layout:

| Block | Count | Area each | Total |
|---|---|---|---|
| PE, today (int16) | 64 | 14,376 µm² | 0.92 mm² |
| **PE, proposed** | 64 | **14,250 µm²** | **0.91 mm²** |
| Converter `fixed_to_fp32` | 1 | 10,500 µm² | 0.01 mm² |
| C buffer | — | — | about −0.08 mm² (32 instead of 40 bits) |
| Read-out mux | 1 | grows from 40 to 89 bits wide | not measured |

**Overall:** about the same size as today. These numbers come from a stand-alone synthesis, so
they compare designs against each other. The README's figures (64 PEs ≈ 1.27 mm²) come from the
OpenLane run.

**Timing:**

- The PE path is 9.3–15.7 ns.
- The converter path is 16–33 ns in its own stage.
- Both are inside the 35 ns clock, before wire delay. The OpenLane run of the accelerator macro is
  the real check.

---

## 10. Alternatives considered

All of these were sketched, checked against a Python reference, and synthesized the same way.
"Area" is mapped for area at a 35 ns target; "fastest" is the shortest path the mapper could reach.

| Design (inputs → accumulator) | Area | Fastest path | Accuracy, fp32 results | Notes |
|---|---|---|---|---|
| **fp16 → exact 89-bit (proposal)** | **14,250 µm²** | **9.3 ns** | **always correctly rounded** | integer add in the loop |
| fp16 → fp32, rounded every add | 13,430 µm² | 19.1 ns | 48–89 % not best, up to 320 ulp | matches CPU `fmadd.s` bit for bit; long loop |
| bf16 → fp32, rounded every add | 11,211 µm² | 19.4 ns | fewer input bits (8 vs 11) | 8-bit exponent: an exact accumulator would need ~550 bits |
| fp16 → fp16 accumulator | 11,745 µm² | 20.2 ns | unusable (see §13.1) | not faster, only 18 % smaller |
| fp16 → exact, cut to 71 bits | 12,977 µm² | 8.8 ns | wrong for small results | saves 9 %; fails near fp16's bottom range |
| fp32 → fp32, one cycle | 41,445 µm² | 31.2 ns | — | misses 35 ns once mapped for area (37 ns) |
| fp32 → fp32, multiply pipelined | 37,754 µm² | 19.4 ns | — | 2.6× the PE; only a 4×4 array fits today's area |

Multipliers alone, for reference:

| Multiplier | Area |
|---|---|
| int16 × int16 (today) | 11,940 µm² |
| 11 × 11 (fp16) | 5,030 µm² |
| 8 × 8 (bf16) | 2,744 µm² |
| 24 × 24 (fp32) | 22,316 µm² |

**Why the proposal wins:**

- It keeps today's PE size and a short loop.
- It gives the best possible fp32 result.
- It needs no float adder anywhere, only one shared rounding unit.

---

## 11. Verification plan

### 11.1 Already done, at sketch level

The PE plus converter were compared with an exact Python model (`fractions.Fraction`) on 400
dot products of 16 terms each, including:

- random exponents over the whole fp16 range
- subnormal inputs (141 of the 400 cases)
- all-maximum inputs (±65,504)
- the smallest subnormals
- near-total cancellation

All 89-bit sums and all fp32 results matched exactly. An 85-bit build also matched.

### 11.2 To do with the real RTL

1. **PE unit test.**
   - Reference model in the testbench, written differently from the PE: turn each fp16 into a
     41-bit integer (`sig << (e_eff − 1)`), multiply, and add in a 128-bit integer.
   - Compare the 89-bit accumulator exactly.
2. **Converter unit test.**
   - Compare against vectors generated by Python: correctly rounded fp32 of exact values.
   - Include ties (exactly halfway), carries out of the significand (e.g. 0x…FFFF + 1), negative
     values, and zero.
3. **`tb_systolic`:** the same reference for every PE, with random `en` stalls and `clear`
   between products, as today.
4. **`tb_matmul_accel`:**
   - Products both through the bus (`CTRL = 1`) and through DMA (`CTRL = 3`).
   - Partial tiles, K = 1, 1×1, worst-case magnitudes, subnormals.
   - Expected fp32 values from Python.
   - Check the new C layout: 4 per line and zero padding.
5. **SoC test, `sw/test_matmul_fp.S`.**
   - Inputs and expected results generated by a script (e.g. `sw/gen_matmul_fp.py`) into a data
     section.
   - Compare C bit for bit. Add it to `sim/run.sh all`.
6. **Mutation checks.** Each of these must be caught:
   - dropping the `+ sign` carry-in
   - an off-by-one in the shift (`ea + eb − 1`)
   - flushing subnormals (hidden bit always 1)
   - removing the extra drain cycle
   - a round-half-up converter instead of ties-to-even
7. **Gate level:** `sim/run.sh gl-accel` on the new macro netlist.

---

## 12. Implementation steps

| # | Step | Files |
|---|---|---|
| 1 | Add the PE and the converter, with unit tests | `rtl/accel/systolic_pe_fp16.v`, `rtl/accel/fixed_to_fp32.v`, `sim/` |
| 2 | Array: new PE, `ACC_WIDTH = 89` (optional `FP16` parameter) | `rtl/accel/systolic_array.v`, `sim/tb_systolic.v` |
| 3 | Accelerator: converter stage, 32-bit `cbuf`, 4-per-line C store, C bus read | `rtl/accel/matmul_accel.v`, `sim/tb_matmul_accel.v` |
| 4 | Software test with generated data | `sw/test_matmul_fp.S`, `sw/gen_matmul_fp.py`, `sw/Makefile`, `sim/run.sh` |
| 5 | OpenLane: re-harden the accelerator macro, then the SoC | `asic/systolic_array/`, then the SoC run |
| 6 | Phase 2: packed fp16 DMA for A and B | `rtl/accel/matmul_accel.v`, tests |
| 7 | Documentation | `README.md` accelerator section |

Steps 1–4 can be done and checked in simulation before any OpenLane run.

---

## 13. Future extensions

### 13.1 fp16 results

Only the converter changes: it rounds to fp16 instead (9,650 µm²). Accuracy against the correctly
rounded fp16 result (random N(0, 1) values):

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

- **Infinity / NaN inputs:** a sticky flag per PE, and NaN output when it is set (§4.4).
- **Overlap the read-out of one tile with the next tile's compute.** Copying takes N² + 2 of the
  ≈ 97 cycles per tile.
- **Larger matrices:** the 89-bit accumulator already supports K up to 256. `MAX_DIM` and the
  buffers set the limit.

---

## Appendix: how the numbers were measured

**Synthesis.** Yosys 0.9 with ABC, `sky130_fd_sc_hd__ss_100C_1v60.lib`. Each block has registered
inputs and outputs and is flattened. There are no wires, so treat the results as estimates for
comparing designs.

```sh
L=/data/OpenLane/pdks/sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__ss_100C_1v60.lib
# mapped for area at a 35 ns target
yosys -p "read_verilog -sv design.v; synth -top TOP -flatten; dfflibmap -liberty $L; \
  abc -liberty $L -script +strash;dch,-f;map,-D,35000;topo;buffer;upsize,-D,35000;dnsize,-D,35000;stime,-p; \
  opt_clean; stat -liberty $L"
# fastest mapping: the same, with map;topo;buffer;upsize;dnsize;stime,-p
```

**Accuracy.**

- Python with `fractions.Fraction` computes the exact dot products and correct rounding.
- numpy `float32` / `float16` models the per-add accumulators.
- Products of two fp16 values are exact in fp32, so a numpy fp32 loop is exactly the per-add fp32
  accumulator.

**Functional checks of the sketches.** Icarus Verilog testbenches drive random vectors, and Python
compares the outputs against the exact model.
