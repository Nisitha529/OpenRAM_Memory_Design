# Low-Power Matrix-Multiply Accelerator: Neuromorphic Principles and Matrix Reductions

**Status:** proposal
**Date:** 2026-11-26
**Builds on:** [fp16_accelerator_design.md](fp16_accelerator_design.md) (fp16 inputs, exact
accumulation, fp32 results)
**Scope:** the `matmul_accel` macro and the software that drives it

---

## 1. Summary

**Today's accelerator spends most of its power keeping itself clocked, not doing arithmetic.**

- In the signoff power report, 76% of the estimated power is the clock tree and the flip-flops.
- 79% of the flip-flops are the A, B and C buffers. They are written only while a job loads or
  stores data, but they receive a clock edge on every cycle.
- In a typical job (16×16 × 16×16, 2,768 cycles), the array computes for only 120 cycles, about 4%
  of the time.

**Neuromorphic chips save power with one main rule: no event, no activity.** A neuron does nothing
until a spike arrives. This proposal applies that rule to our synchronous digital design. The parts
that have nothing to do stop receiving a clock, and work on zero values is skipped.

On top of that, it proposes ***matrix reductions***: ways to do less work and move less data for
the same product.

| # | Proposal | Type | Expected effect | Effort |
|---|---|---|---|---|
| 1 | Clock-gate the A, B and C buffers | event-driven | buffer power −83 % to −96 % (measured); buffer area −31 %; ~18,400 hold-fix cells removed | low |
| 2 | Clock-gate the PE array outside compute | event-driven | PE power while idle −99 % (measured) | low |
| 3 | Event-driven PE: skip zero products | event-driven + sparsity | −19 % PE power at 50 % zeros (measured) | low |
| 4 | Keep B loaded between jobs | data reuse | B traffic removed for repeated weights | low |
| 5 | Skip all-zero tiles | block sparsity | skipped tiles cost no time and no power | medium |
| 6 | Pack fp16 (and optionally fp8) data | lower precision | ½ (or ¼) of the A/B traffic | medium |
| 7 | Low-rank factorization | software | fewer multiplies and less data for suitable matrices | none (software) |
| 8 | Spike mode for spiking neural networks | neuromorphic | multiply-free, event-driven layers | high (research) |

Proposals 1–3 together cut the estimated power of the PE array and buffers over a job from about
31 mW to about 2 mW. This is a block-level estimate (§4.4), and it still needs confirming with a
full-chip, activity-based analysis.

---

## 2. Where the power goes today

### 2.1 Signoff power report

This is the accelerator macro, `accel_run5_antenna`, at the typical corner (tt, 25 °C, 1.8 V) with a
35 ns clock. OpenSTA estimated it without simulation data, using default switching rates.

| Group | Power | Share |
|---|---|---|
| Flip-flops (sequential) | 27.4 mW | 38 % |
| Clock tree | 26.9 mW | 38 % |
| Logic (combinational) | 17.3 mW | 24 % |
| **Total** | **71.6 mW** | |

Most of the flip-flop power is *internal* power: the flip-flop's own circuitry charging and
discharging on each clock edge. It is spent even when the stored value doesn't change.

### 2.2 Who owns the flip-flops

| Block | Flip-flops | Share |
|---|---|---|
| A buffer | 4,096 | 18 % |
| B buffer | 4,096 | 18 % |
| C buffer | 10,240 | 44 % |
| PE array (64 PEs) | ≈ 4,600 | 20 % |
| Control and pipeline | ≈ 300 | 1 % |
| **Total** | **23,363** | |

The netlist also has **21,434 hold-fix delay cells**. 18,434 of them sit in the buffers'
"keep my value" loops: flip-flop output → multiplexer → back into the same flip-flop. Such a loop
is very short, so the 0.2 ns hold margin forced a delay cell into nearly every buffer bit.

### 2.3 What a job does with its time

These are the 2,768 cycles of a 16×16 · 16×16 job, measured in `test_matmul`:

| Phase | Cycles | Array busy? |
|---|---|---|
| Feed (multiply-accumulate) | 120 (4 tiles × 30) | **yes** |
| Copy results out | 260 (4 tiles × 65) | read only |
| Clear | 4 | — |
| DMA load and store, cache flush and invalidate | ≈ 2,384 | no |

**The array computes in about 4% of the cycles, but it is clocked in 100% of them. So are the
buffers.**

### 2.4 Moving data costs more than computing

The well-known 45 nm figures (Horowitz, ISSCC 2014), as used in many accelerator papers:

| Operation (32-bit) | Energy |
|---|---|
| Integer add | 0.1 pJ |
| Float add | 0.9 pJ |
| Integer multiply | 3.1 pJ |
| Float multiply | 3.7 pJ |
| Small on-chip SRAM read | 5 pJ |
| Off-chip DRAM read | 640 pJ |

The absolute values differ in sky130, but the order holds. One off-chip memory access costs about
as much as 200 multiplies. **For the whole system, moving less data matters more than making the
multiplier cheaper.** That is why matrix reductions (§6) focus on data.

---

## 3. What neuromorphic hardware does, and what fits this chip

Neuromorphic chips such as IBM TrueNorth, Intel Loihi and SpiNNaker are built around spiking
neurons. They save power with five main ideas:

| Neuromorphic idea | What it means | How we apply it here | Fits? |
|---|---|---|---|
| **Event-driven** | logic works only when a spike (event) arrives | clock gating: blocks with no work get no clock; zero products are skipped | **yes**: proposals 1–3 |
| **Sparse activity** | most neurons are silent most of the time | skip zero values and all-zero tiles | **yes**: proposals 3 and 5 |
| **Accumulate, don't multiply** | a spike is 0 or 1, so a synapse just adds its weight | spike mode: the PE adds or subtracts weights and turns its multiplier off | **as an extension**: proposal 8 |
| **Memory next to compute** | weights stay where they are used | keep B in its buffer between jobs; partial sums already stay inside the PEs | **yes**: proposal 4 |
| **No global clock / analog in-memory computing** | asynchronous logic, memristor crossbars | — | **no**: needs a non-standard flow or devices that sky130 and OpenLane don't support |

**A spiking neural network is not a drop-in replacement for a matrix multiply.** An SNN computes
an *approximation* spread over several time steps, and the network has to be trained or converted
for it. The proposed accelerator computes an *exact* fp16 product. So this proposal does two things:

- It **adopts the principles** (event-driven, sparse, local memory) for the exact accelerator.
- It offers **spike mode** as an optional extra for SNN workloads.

---

## 4. Event-driven operation (proposals 1–3)

### 4.1 Proposal 1: clock-gate the buffers

**Idea:** split each buffer into rows, for example 16 entries of 16 bits. Give each row its own
*integrated clock-gating cell*. sky130 has one in its standard library: a latch plus an AND gate
that passes the clock only while its enable is high. A row's clock then runs only in a cycle when
that row is written.

- **A and B** are written only during the DMA load (or by bus writes before a job). During feeding
  they are only read, and reading needs no clock.
- **C** is written one entry per cycle while results are copied out, and read during the DMA store.

**Measured:** one 16 × 16-bit buffer slice, gate-level simulation plus OpenSTA, tt corner, 35 ns
clock.

| Activity | Today (enable mux) | Clock-gated | Saving |
|---|---|---|---|
| Idle (no reads or writes) | 298 µW | 12 µW | **−96 %** |
| Read every cycle (feeding) | 345 µW | 24 µW | **−93 %** |
| Write every cycle (loading) | 355 µW | 60 µW | **−83 %** |

There are 18,432 buffer bits, which is 72 such slices. That makes about **21.5 mW → 0.9 mW** when
idle.

**Side benefits:**

- **Smaller buffers.** The clock gate replaces the "keep my value" multiplexer in front of every
  flip-flop. A slice shrinks from 9,988 to 6,873 µm² (−31%), about −0.22 mm² for all buffers.
- **Far fewer hold-fix cells.** The short output-to-input loop disappears, so most of the
  ~18,400 hold-fix delay cells on the buffers are no longer needed. The shared write-data wires
  might still need a few.

### 4.2 Proposal 2: clock-gate the PE array outside compute

**Idea:** the PEs only need a clock while the array is cleared or fed. That is 124 of 2,768 cycles
in the job above. Results are read through the read-out multiplexer, which needs no clock. One
clock gate per PE (or per row of PEs), enabled by the existing `en` signal, stops the array in
every other phase.

**Measured,** for one proposed fp16 PE:

| Activity | Today (no gating) | Gated | Saving |
|---|---|---|---|
| Idle (waiting for DMA, copying results out) | 141 µW | 1.6 µW | **−99 %** |

### 4.3 Proposal 3: event-driven PE (skip zero products)

**Idea:** a PE does work only when a real "event" arrives, meaning a product that isn't zero. If
either operand is zero:

- the accumulator gets no clock;
- the multiplier and shifter inputs are held at zero, so they don't switch.

The operands are still passed on to the neighbouring PEs, because the systolic dataflow needs them.

**Measured,** for one PE, with random fp16 data:

| Data | Today | Event-driven | Saving |
|---|---|---|---|
| Dense (no zeros) | 273 µW | 288 µW | +5 % (cost of the gate) |
| Half of the A values zero (typical after ReLU in neural networks) | 232 µW | 189 µW | **−19 %** |

From these two points, zero-skipping pays off when more than about 1 product in 8 is zero.
Gating on `en` (proposal 2) costs nothing in dense compute, so it is worth doing in any case.

**What it doesn't change:** cycles. The systolic dataflow still steps through every value. To save
*time* on sparse data, see tile skipping (§6.2).

### 4.4 Estimate for a whole job

This combines the measured PE and buffer figures with the phase lengths of a 16×16 job (§2.3):

| | Today | With proposals 1–3 |
|---|---|---|
| 64 PEs, average over the job | 9.4 mW | 0.9 mW |
| Buffers (72 slices), average | 21.6 mW | ≈ 1.1 mW |
| **PE array and buffers** | **≈ 31 mW** | **≈ 2 mW** |
| Energy per job, these blocks | ≈ 3.0 µJ | ≈ 0.2 µJ |

As a cross-check, the block-level flip-flop power (≈ 30 mW) matches the signoff report's 27.4 mW
for flip-flops.

The clock tree (26.9 mW at signoff) should also shrink a lot, because the tree *behind* each clock
gate stops switching. Only the gates and the tree above them keep running. **A rough expectation
for the whole macro is 70 mW falling to around 10–15 mW.** The activity-based signoff analysis in
§8 must confirm that number.

### 4.5 Notes for implementation

- **Cell:** use the sky130 integrated clock-gating cell, not a hand-made AND gate. The cell
  contains a latch, so the gated clock has no glitches.
- **Clock tree:** clock-tree synthesis must build the tree *through* the gates. This needs to be
  checked in the OpenLane flow (clock-gate placement, skew, and the enable's timing to the gate).
- **Testing:**
  - gate-level simulation must show identical results with and without gating (the measurements
    above did);
  - the existing `tb_matmul_accel`, `test_matmul` and gate-level accelerator tests cover it.

---

## 5. Spike mode (proposal 8, optional neuromorphic extension)

### 5.1 Idea

In a spiking neural network (SNN), the inputs to a layer are spikes, 0 or 1 at each time step.
A synapse then needs no multiplier: a spike *adds* its weight, and no spike does nothing.

The proposed PE already turns each product into a shifted number and adds it into an exact
accumulator. In spike mode, the PE does this instead:

- **spike = 1:** add the weight (B) into the accumulator, with no multiply;
- **spike = 0:** do nothing, and the PE gets no clock (event-driven);
- **optionally, spike = −1** (ternary spikes): subtract the weight.

The multiplier stays switched off for the whole layer.

### 5.2 How an SNN layer maps onto the array

| Matrix | Matrix-multiply meaning | SNN meaning |
|---|---|---|
| A (M × K) | input matrix | spikes: row = time step, column = input neuron |
| B (K × P) | weights | synaptic weights: input neuron → output neuron |
| C (M × P) | result | input current of each output neuron at each time step |

A neuron also has state: its *membrane potential*. At each time step the potential:

1. leaks a little,
2. adds the input current,
3. fires a spike if it crosses a threshold, and then resets.

That work belongs in **one shared "neuron unit" on the read-out path**, in the same place as the
fp32 converter. It keeps one potential per output neuron (at most 16 values) and writes output
spikes instead of numbers. The tile order already delivers the time steps of each neuron in order,
so the potentials update correctly.

### 5.3 Benefits and limits

**Benefits:**

- No multiplies: an add costs a fraction of a multiply (§2.4).
- Spikes are sparse, typically a small fraction per time step, so most PE events are skipped.
- Spikes are 1 bit, so the A data shrinks 16×.

**Limits:**

- The network must be trained for spikes or converted to them.
- It needs several time steps per input.
- The results are approximate.

So spike mode is a **separate operating mode** for neural-network workloads, not a replacement for
the exact fp16 product. Treat it as a research extension once proposals 1–7 are in place.

---

## 6. Matrix reductions (proposals 4–7)

### 6.1 Zero skipping (unstructured sparsity)

This is proposal 3. It saves energy in proportion to the share of zero products. It does not save
time.

### 6.2 Proposal 5: skip all-zero tiles (block sparsity)

**Idea:** an output tile is all zeros if its 8 rows of A, or its 8 columns of B, are all zero.

- While the DMA loads A and B, record one "has a nonzero value" bit per row of A and per column of
  B. That is 32 bits in total.
- The sequencer skips any tile whose rows or columns are all zero, and writes zeros for it.

A skipped tile costs no feed cycles, no copy-out cycles and no PE energy. This pays off for pruned
neural-network weights and block-sparse matrices.

**Next step (bigger change):** store sparse matrices in a compressed form, with a bitmap of nonzero
blocks. The DMA then doesn't read the zero blocks at all, which saves the most expensive energy:
memory traffic.

### 6.3 Proposal 4: keep B loaded between jobs (weight reuse)

**Idea:** in neural networks the same weights (B) are multiplied with many inputs (A). Add a
control bit, "B unchanged", that skips the B load.

- B is half of all loaded data, so repeated jobs save that traffic and its time.
- The buffer contents already survive between jobs.

The software must make sure B really is unchanged; that is a software contract.

### 6.4 Proposal 6: lower precision

| Format | A/B traffic vs today's 32-bit words | Multiplier | Exact accumulator | Accuracy |
|---|---|---|---|---|
| fp16, two per word (phase 2 of the fp16 design) | ½ | 11 × 11 bits | 89 bits | ≈ 3 decimal digits per input |
| fp8 (E4M3), four per word (optional) | ¼ | 4 × 4 bits | ≈ 45 bits | ≈ 2 decimal digits per input; for neural networks only |

The exact-accumulator idea works even better for fp8. Its exponent range is so small that the
exact sum fits in about 45 bits, close to today's 40-bit integer accumulator. The results would
still be rounded once to fp32.

### 6.5 Proposal 7: low-rank factorization (software only)

**Idea:** many weight matrices are close to "low rank": W (K × P) ≈ U (K × r) · V (r × P), with
r much smaller than K and P. Then A·W ≈ (A·U)·V, which is two smaller products on the same
accelerator.

**Example,** 16×16 matrices, rank 4:

| | One full product | Two low-rank products |
|---|---|---|
| Multiply-adds | 4,096 | 2,048 (−50 %) |
| Weight values to load | 256 | 128 (−50 %) |
| Compute cycles on the 8×8 array | 385 | 528 (+37 %) |

The cycles go *up* at this size. Every tile pays a fixed 64-cycle copy-out, and the two products
need more tiles in total.

**Notes:**

- **Energy** still falls: there is less data, fewer real products, and idle PEs are gated
  (proposals 2–3).
- **Time** improves only for larger matrices.
- **Accuracy:** A·U comes out in fp32 but must be rounded to fp16 before the second product, which
  adds an extra rounding.
- **Suitability:** check each matrix's singular values. Low rank must actually fit the matrix.

### 6.6 Considered and not recommended

- **Strassen-type fast algorithms:**
  - They need 7 multiplications instead of 8 for each 2×2 block (−12.5%), but more additions and
    more data movement.
  - They add input matrices *before* multiplying, which in fp16 needs extra rounding and breaks
    the exact-result guarantee.
  - The saving is too small for the cost at these sizes.
- **Structured N:M sparsity** (for example, 2 of every 4 weights are zero): this halves the
  multiplies, but each PE then needs index-based operand selection. That is a large change to a
  systolic array. Revisit it later, after tile skipping.

---

## 7. Recommended plan

| Step | Work | Power / energy effect | Risk |
|---|---|---|---|
| 1 | Buffer clock gating (proposal 1) | largest single saving; also less area and fewer hold-fix cells | low: standard cells, check clock-tree build |
| 2 | Array clock gating on `en` (proposal 2) | PE idle power −99 % | low |
| 3 | Zero-skipping PE (proposal 3) | −19 % PE power at 50 % zeros | low |
| 4 | "B unchanged" control bit (proposal 4) | removes repeated B traffic | low: software contract |
| 5 | Tile skipping (proposal 5) | time and energy on block-sparse data | medium |
| 6 | fp16 packing, then optional fp8 (proposal 6) | ½ to ¼ of the A/B traffic | medium |
| 7 | Low-rank factorization in the driver software (proposal 7) | fewer multiplies and less data, for suitable matrices | none for hardware |
| 8 | Spike mode with a shared neuron unit (proposal 8) | multiply-free, event-driven SNN layers | high: research |

Steps 1–3 fit naturally into the fp16 redesign, because the PE and buffers are being rebuilt anyway.
Each step should be signed off with the measurement in §8 before the next one starts.

---

## 8. How the savings will be measured

The signoff report so far is *vectorless*: it assumes default switching rates. To measure real
savings:

1. **Record activity:** run gate-level simulations of real jobs. Use a dense one, a 50%-zero one,
   and a block-sparse one, and record switching activity (VCD files).
2. **Measure power:** run OpenSTA's activity-based power analysis on the *post-layout* netlist, so
   the clock tree and wires are included.
3. **Report energy:** give energy per job (µJ) and energy per multiply-accumulate (pJ/MAC), before
   and after each step, at the typical corner.
4. **Check results:** confirm the results are bit-identical with and without each power feature.

---

## 9. How the figures in this proposal were obtained

- **Signoff power and the cell census:** OpenLane run `accel_run5_antenna`. The power is OpenSTA's
  vectorless report at nom_tt_025C_1v80. The flip-flop and delay-cell counts come from the final
  netlist.
- **Block-level power:**
  - **Blocks:** one proposed fp16 PE (with and without event-driven gating) and one 16 × 16-bit
    buffer slice (with an enable multiplexer, or clock-gated).
  - **Synthesis and simulation:** each block was synthesized for sky130_fd_sc_hd and simulated at
    gate level for 2,000 cycles at 35 ns. Both versions gave identical outputs in every cycle.
  - **Power analysis:** OpenSTA computed power from the simulated activity at the tt corner.
  - **Limits:** these figures include no clock tree and no wires. The zero-delay simulation also
    leaves out glitch power, which is mostly in the multiplier. Read them as comparisons, not as
    signoff values.
- **Job phases:** from the cycle formula in the accelerator design and the measured `test_matmul`
  job (2,768 cycles).
- **Energy per operation (§2.4):** M. Horowitz, "Computing's energy problem (and what we can do
  about it)", ISSCC 2014, 45 nm figures.
