// Unit testbench: random CPU requests -> l1d (OpenCache RTL + OpenRAM SRAM models) -> DRAM
//
// Checks:
//   1. Every read returns the value a flat "golden" memory says it should.
//   2. After a flush, DRAM holds all written data (i.e. write-back works).
// Also reports hit/miss counts (a request with no stall cycles is a hit).
`timescale 1ns/1ps
module tb_l1d;

  localparam TAG_W = 9, SET_W = 5, OFF_W = 2;
  localparam ADDR_W = TAG_W + SET_W + OFF_W;   // 16-bit word address
  localparam WORD_W = 32, WORDS = 4;
  localparam LINE_W = WORD_W * WORDS;          // 128-bit line
  localparam LADDR_W = ADDR_W - OFF_W;         // 14-bit line address
  localparam NUM_OPS = 2000;
  localparam CLK_HALF = 5;

  reg clk = 1;
  reg rst = 0, flush = 0;
  reg cache_csb = 1, cache_web = 1;
  reg  [ADDR_W-1:0] cache_addr = 0;
  reg  [WORD_W-1:0] cache_din  = 0;
  wire [WORD_W-1:0] cache_dout;
  wire cache_stall;

  wire dram_csb, dram_web, dram_stall;
  wire [LADDR_W-1:0] dram_addr;
  wire [LINE_W-1:0]  dram_din, dram_dout;

  always #(CLK_HALF) clk = ~clk;

  l1d dut (
    .clk(clk), .rst(rst), .flush(flush),
    .csb(cache_csb), .web(cache_web), .addr(cache_addr),
    .din(cache_din), .dout(cache_dout), .stall(cache_stall),
    .main_csb(dram_csb), .main_web(dram_web), .main_addr(dram_addr),
    .main_din(dram_din), .main_dout(dram_dout), .main_stall(dram_stall)
  );

  dram #(.WORD_WIDTH(LINE_W), .ADDR_WIDTH(LADDR_W)) mem (
    .clk(clk), .rst(rst), .csb(dram_csb), .web(dram_web),
    .addr(dram_addr), .din(dram_din), .dout(dram_dout), .stall(dram_stall)
  );

  // Golden reference: what memory *should* contain, word by word
  reg [WORD_W-1:0] golden [0:(1<<ADDR_W)-1];

  integer i, n, stalls, errors = 0, hits = 0, misses = 0, reads = 0, writes = 0;
  reg [ADDR_W-1:0] a;
  reg [TAG_W-1:0]  t;
  reg [SET_W-1:0]  s;
  reg [OFF_W-1:0]  o;
  reg [WORD_W-1:0] d;
  reg is_write;

  // Wait out stall cycles; returns number of stalled cycles
  task wait_stall(output integer cycles);
    begin
      cycles = 0;
      while (cache_stall) begin
        #(CLK_HALF * 2);
        cycles = cycles + 1;
      end
    end
  endtask

  // One CPU request: inputs change 1 ns before a posedge, as in OpenCache's own TB
  task access(input w, input [ADDR_W-1:0] addr, input [WORD_W-1:0] data);
    begin
      cache_csb = 0; cache_web = !w; cache_addr = addr; cache_din = data;
      #(CLK_HALF * 2);
      wait_stall(stalls);
      if (stalls == 0) hits = hits + 1; else misses = misses + 1;
      if (!w && cache_dout !== golden[addr]) begin
        if (errors < 10)
          $display("READ MISMATCH addr=%h expected=%h got=%h", addr, golden[addr], cache_dout);
        errors = errors + 1;
      end
    end
  endtask

  initial begin
    $dumpfile("tb_l1d.vcd");
    $dumpvars(0, tb_l1d);

    // Fill DRAM with random data and mirror it into the golden model
    for (i = 0; i < (1 << LADDR_W); i = i + 1) begin
      mem.memory[i] = {$random, $random, $random, $random};
      for (n = 0; n < WORDS; n = n + 1)
        golden[{i[LADDR_W-1:0], n[OFF_W-1:0]}] = mem.memory[i][n*WORD_W +: WORD_W];
    end

    // Reset (the cache clears its tag array, so it stalls for a while)
    #(CLK_HALF * 2 - 1);
    rst = 1; #(CLK_HALF * 2); rst = 0;
    wait_stall(stalls);
    $display("Reset done after %0d stall cycles", stalls);

    // Random reads/writes
    for (i = 0; i < NUM_OPS; i = i + 1) begin
      is_write = $random;
      // Only 4 tags x 8 sets are used, so lines keep colliding in the
      // direct-mapped cache -> plenty of conflict misses and dirty evictions
      t = {$random} % 4;
      s = {$random} % 8;
      o = {$random} % 4;
      a = {t, s, o};
      d = $random;
      if (is_write) begin
        access(1, a, d);
        golden[a] = d;
        writes = writes + 1;
      end else begin
        access(0, a, 0);
        reads = reads + 1;
      end
    end

    // Flush: dirty lines must be written back to DRAM
    cache_csb = 1;
    flush = 1; #(CLK_HALF * 2); flush = 0;
    wait_stall(stalls);
    #(CLK_HALF * 2 * 5);
    $display("Flush done after %0d stall cycles", stalls);

    for (i = 0; i < (1 << LADDR_W); i = i + 1)
      for (n = 0; n < WORDS; n = n + 1)
        if (mem.memory[i][n*WORD_W +: WORD_W] !== golden[{i[LADDR_W-1:0], n[OFF_W-1:0]}]) begin
          if (errors < 10)
            $display("DRAM MISMATCH after flush line=%h word=%0d", i, n);
          errors = errors + 1;
        end

    $display("--------------------------------------------");
    $display("Requests: %0d (%0d reads, %0d writes)", NUM_OPS, reads, writes);
    $display("Hits: %0d  Misses: %0d  Hit rate: %0d%%", hits, misses, hits * 100 / NUM_OPS);
    if (errors == 0) $display("PASS: all reads correct and DRAM consistent after flush");
    else             $display("FAIL: %0d errors", errors);
    $display("--------------------------------------------");
    $finish;
  end
endmodule
