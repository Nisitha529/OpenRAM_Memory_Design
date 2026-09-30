// System testbench: run a RISC-V program on the core.
//
//   +define+IDEAL : core with perfect single-cycle memories (reference)
//   default       : riscv_soc (core + L1I + L1D + L2) + DRAM model
//
// Plusargs:
//   +prog=<file.hex>   program image, one 32-bit word per line (from sw/)
//   +regs=<file>       where to dump the final register file
//   +max_cycles=<n>    timeout
//
// The program stores its result to "tohost" (1 = pass). In cached mode the
// testbench then flushes L1D and L2 and checks that DRAM holds exactly what
// the program stored.
`timescale 1ns/1ps
module tb_soc;

  localparam MEM_WORDS = 1 << 16;          // 256 KB
  localparam TOHOST    = 32'h0003ff00;
  localparam LINE_WORDS = 8;               // 256-bit DRAM line

  reg clk = 1, rst = 1;
  always #5 clk = ~clk;

  reg [31:0] image  [0:MEM_WORDS-1];       // program as loaded
  reg [31:0] shadow [0:MEM_WORDS-1];       // what memory should hold now

  reg [1023:0] prog, regs_file;
  integer max_cycles, cycles = 0, i, j, errors = 0, fd;

  // Signals every mode provides
  wire        memwritem, memreadm, freeze;
  wire [31:0] aluresultm, writedatam;

`ifdef IDEAL
  // ---------------- perfect memories ----------------
  wire [31:0] pcf, instrf, readdatam;
  reg  [31:0] dmem [0:MEM_WORDS-1];
  assign freeze = 1'b0;

  riscv_module core (
    .clk(clk), .reset(rst),
    .pcf(pcf), .instrf(instrf),
    .memwritem(memwritem), .aluresultm(aluresultm),
    .writedatam(writedatam), .readdatam(readdatam),
    .freeze(1'b0), .imem_addr(), .memreadm(memreadm),
    .dreq_we(), .dreq_re(), .dreq_addr(), .dreq_wdata()
  );
  assign instrf    = image[pcf[17:2]];
  assign readdatam = dmem[aluresultm[17:2]];
  always @(posedge clk) if (memwritem) dmem[aluresultm[17:2]] <= writedatam;
  `define CORE core
`else
  // ---------------- cache hierarchy + DRAM ----------------
  reg          l1d_flush = 0, l2_flush = 0;
  wire         l1d_busy, l2_busy;
  wire         mem_csb, mem_web, mem_stall;
  wire [12:0]  mem_addr;
  wire [255:0] mem_din, mem_dout;

  riscv_soc soc (
    .clk(clk), .rst(rst),
    .l1d_flush(l1d_flush), .l2_flush(l2_flush),
    .l1d_busy(l1d_busy), .l2_busy(l2_busy),
    .mem_csb(mem_csb), .mem_web(mem_web), .mem_addr(mem_addr),
    .mem_din(mem_din), .mem_dout(mem_dout), .mem_stall(mem_stall)
  );

  dram #(.WORD_WIDTH(256), .ADDR_WIDTH(13)) mem (
    .clk(clk), .rst(rst), .csb(mem_csb), .web(mem_web), .addr(mem_addr),
    .din(mem_din), .dout(mem_dout), .stall(mem_stall)
  );

  assign memwritem  = soc.memwritem;
  assign memreadm   = soc.memreadm;
  assign aluresultm = soc.aluresultm;
  assign writedatam = soc.writedatam;
  assign freeze     = soc.freeze;
  `define CORE soc.core

  // ---- statistics: every request an L1 sends to L2 is an L1 miss, etc. ----
  integer l1i_miss = 0, l1d_miss = 0, l1d_wb = 0, l2_miss = 0, l2_wb = 0;
  always @(posedge clk) if (!rst) begin
    if (soc.u_arb.i_go)             l1i_miss = l1i_miss + 1;
    if (soc.u_arb.d_go &&  soc.u_arb.d_web) l1d_miss = l1d_miss + 1;
    if (soc.u_arb.d_go && !soc.u_arb.d_web) l1d_wb   = l1d_wb + 1;
    if (!mem_csb && !mem_stall &&  mem_web) l2_miss  = l2_miss + 1;
    if (!mem_csb && !mem_stall && !mem_web) l2_wb    = l2_wb + 1;
  end
`endif

  // ---- statistics common to both modes ----
  integer loads = 0, stores = 0, frozen = 0;
  always @(posedge clk) if (!rst) begin
    cycles = cycles + 1;
    if (freeze) frozen = frozen + 1;
    else begin
      if (memreadm)  loads  = loads + 1;
      if (memwritem) stores = stores + 1;
    end
  end

  // ---- watch committed stores: keep the shadow memory, catch tohost ----
  reg        done = 0;
  reg [31:0] result;
  always @(posedge clk) if (!rst && memwritem && !freeze && !done) begin
    shadow[aluresultm[17:2]] <= writedatam;
    if (aluresultm == TOHOST) begin
      done   <= 1;
      result <= writedatam;
    end
  end

  initial begin
    if (!$value$plusargs("prog=%s", prog)) begin
      $display("usage: +prog=<file.hex>");
      $finish;
    end
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 500000;

    for (i = 0; i < MEM_WORDS; i = i + 1) image[i] = 32'h0;
    $readmemh(prog, image);
    for (i = 0; i < MEM_WORDS; i = i + 1) shadow[i] = image[i];
`ifdef IDEAL
    for (i = 0; i < MEM_WORDS; i = i + 1) dmem[i] = image[i];
`else
    for (i = 0; i < MEM_WORDS / LINE_WORDS; i = i + 1)
      for (j = 0; j < LINE_WORDS; j = j + 1)
        mem.memory[i][j*32 +: 32] = image[i*LINE_WORDS + j];
`endif

    // reset for two cycles
    #(19); rst = 0;

    while (!done && cycles < max_cycles) @(posedge clk);

    $display("------------------------------------------------------------");
    $display("Program : %0s", prog);
`ifdef IDEAL
    $display("Mode    : ideal memories");
`else
    $display("Mode    : L1I + L1D + L2 + DRAM");
`endif
    if (!done) begin
      $display("TIMEOUT after %0d cycles", cycles);
      errors = errors + 1;
    end else if (result == 1)
      $display("Program : PASS (tohost = 1)");
    else begin
      $display("Program : FAIL at check %0d (tohost = %0d)", result >> 1, result);
      errors = errors + 1;
    end
    $display("Cycles  : %0d  (frozen by caches: %0d)", cycles, frozen);
    $display("Loads   : %0d   Stores: %0d", loads, stores);

`ifndef IDEAL
    $display("L1I misses: %0d | L1D misses: %0d, write-backs: %0d | L2 misses: %0d, write-backs: %0d",
             l1i_miss, l1d_miss, l1d_wb, l2_miss, l2_wb);

    // Flush L1D into L2, then L2 into DRAM, and compare DRAM with the shadow
    @(negedge clk); l1d_flush = 1; @(negedge clk); l1d_flush = 0;
    while (l1d_busy) @(negedge clk);
    repeat (20) @(negedge clk);
    @(negedge clk); l2_flush = 1; @(negedge clk); l2_flush = 0;
    while (l2_busy) @(negedge clk);
    repeat (20) @(negedge clk);

    j = 0;
    for (i = 0; i < MEM_WORDS; i = i + 1)
      if (mem.memory[i / LINE_WORDS][(i % LINE_WORDS)*32 +: 32] !== shadow[i]) begin
        if (j < 5)
          $display("DRAM MISMATCH at 0x%05h: expected %08h, DRAM has %08h",
                   i*4, shadow[i], mem.memory[i / LINE_WORDS][(i % LINE_WORDS)*32 +: 32]);
        j = j + 1;
      end
    if (j) begin
      $display("DRAM    : %0d words differ after flush", j);
      errors = errors + 1;
    end else
      $display("DRAM    : matches every committed store after L1D + L2 flush");
`endif

    if ($value$plusargs("regs=%s", regs_file)) begin
      fd = $fopen(regs_file, "w");
      for (i = 1; i < 32; i = i + 1)
        $fdisplay(fd, "x%0d %08h", i, `CORE.datapath_01.u_rf.rf[i]);
      $fclose(fd);
    end

    $display("RESULT  : %0s", errors ? "FAIL" : "PASS");
    $display("------------------------------------------------------------");
    $finish;
  end

endmodule
