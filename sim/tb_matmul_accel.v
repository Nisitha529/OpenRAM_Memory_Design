// Self-checking testbench for rtl/accel/matmul_accel.v, driven only through
// its register bus, the way the CPU uses it, plus a memory model on its DMA port.
//   run()     compute-only jobs: write A and B over the bus, start, poll STATUS,
//             read C over the bus
//   run_dma() DMA jobs: A and B placed in memory, start with CTRL = 3, poll,
//             then check C in memory
// Results are compared with a 64-bit reference product.
//
//   +define+N=<n>   physical array size (default 8)
`timescale 1ns/1ps
module tb_matmul_accel;

`ifndef N
  `define N 8
`endif
  localparam N   = `N;
  localparam MAX = 16;
  localparam DW  = 16;
  localparam AW  = 40;

  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  reg         sel = 0, we = 0;
  reg  [12:0] addr = 0;
  reg  [31:0] wdata = 0;
  wire [31:0] rdata;
  wire        busy, done;

  wire         m_csb, m_web, m_stall;
  wire [13:0]  m_addr;
  wire [127:0] m_din, m_dout;

  matmul_accel #(.N(N), .MAX_DIM(MAX), .DATA_WIDTH(DW), .ACC_WIDTH(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .sel(sel), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
    .busy(busy), .done(done),
    .m_csb(m_csb), .m_web(m_web), .m_addr(m_addr), .m_din(m_din),
    .m_dout(m_dout), .m_stall(m_stall)
  );

  // Main memory with multi-cycle stalls, one 128-bit line per address
  dram #(.WORD_WIDTH(128), .ADDR_WIDTH(14)) mem (
    .clk(clk), .rst(!rst_n), .csb(m_csb), .web(m_web), .addr(m_addr),
    .din(m_din), .dout(m_dout), .stall(m_stall)
  );

  // 32-bit word access to the memory model (word address = byte address / 4)
  task mem_wr(input integer waddr, input [31:0] d);
    mem.memory[waddr / 4][(waddr % 4)*32 +: 32] = d;
  endtask
  function [31:0] mem_rd(input integer waddr);
    mem_rd = mem.memory[waddr / 4][(waddr % 4)*32 +: 32];
  endfunction

  reg signed [DW-1:0] A [0:MAX-1][0:MAX-1];
  reg signed [DW-1:0] B [0:MAX-1][0:MAX-1];
  reg signed [63:0]   C [0:MAX-1][0:MAX-1];

  integer i, j, k, errors = 0, tests = 0, cycles;
  reg [31:0] lo, hi, st;

  // ---- bus transactions: request taken at the rising edge, data next cycle ----
  task bus_write(input [12:0] a, input [31:0] d);
    begin
      @(negedge clk); sel = 1; we = 1; addr = a; wdata = d;
      @(negedge clk); sel = 0; we = 0;
    end
  endtask

  task bus_read(input [12:0] a, output [31:0] d);
    begin
      @(negedge clk); sel = 1; we = 0; addr = a;
      @(negedge clk); sel = 0; d = rdata;
    end
  endtask

  // kind 0: random, 1: all -32768, 2: small values
  task run(input integer M, input integer K, input integer P, input integer kind, input [8*28-1:0] name);
    integer bad;
    begin
      for (i = 0; i < M; i = i + 1)
        for (k = 0; k < K; k = k + 1) begin
          A[i][k] = (kind == 1) ? -16'sd32768 : (kind == 2) ? ($random % 8) : $random;
          bus_write(13'h0400 + 4*(i*16 + k), {16'd0, A[i][k]});
        end
      for (k = 0; k < K; k = k + 1)
        for (j = 0; j < P; j = j + 1) begin
          B[k][j] = (kind == 1) ? -16'sd32768 : (kind == 2) ? ($random % 8) : $random;
          bus_write(13'h0800 + 4*(k*16 + j), {16'd0, B[k][j]});
        end
      for (i = 0; i < M; i = i + 1)
        for (j = 0; j < P; j = j + 1) begin
          C[i][j] = 0;
          for (k = 0; k < K; k = k + 1)
            C[i][j] = C[i][j] + A[i][k] * B[k][j];
        end

      bus_write(13'h0008, (P << 16) | (K << 8) | M);
      bus_write(13'h0000, 32'd1);
      cycles = 1;
      bus_read(13'h0004, st);
      while (!st[1]) begin
        bus_read(13'h0004, st);
        cycles = cycles + 2;
      end

      bad = 0;
      for (i = 0; i < M; i = i + 1)
        for (j = 0; j < P; j = j + 1) begin
          bus_read(13'h1000 + 8*(i*16 + j),     lo);
          bus_read(13'h1000 + 8*(i*16 + j) + 4, hi);
          if ({hi, lo} !== C[i][j]) begin
            if (bad < 3) $display("  MISMATCH C[%0d][%0d]: expected %0d, got %0d", i, j, C[i][j], $signed({hi, lo}));
            bad = bad + 1;
          end
        end
      tests = tests + 1;
      errors = errors + bad;
      $display("%-28s %2dx%2d * %2dx%2d  %4d cycles  %s", name, M, K, K, P, cycles, bad ? "FAIL" : "pass");
    end
  endtask

  // DMA job: A at byte 0x1000, B at 0x2000, C at 0x3000
  localparam BA = 32'h1000, BB = 32'h2000, BC = 32'h3000;
  task run_dma(input integer M, input integer K, input integer P, input integer kind, input [8*28-1:0] name);
    integer bad, e;
    begin
      for (e = 0; e < 4096; e = e + 1) mem_wr(BC/4 + e, 32'hdeadbeef);
      for (i = 0; i < M; i = i + 1)
        for (k = 0; k < K; k = k + 1) begin
          A[i][k] = (kind == 1) ? -16'sd32768 : (kind == 2) ? ($random % 8) : $random;
          mem_wr(BA/4 + i*K + k, {{16{A[i][k][15]}}, A[i][k]});
        end
      for (k = 0; k < K; k = k + 1)
        for (j = 0; j < P; j = j + 1) begin
          B[k][j] = (kind == 1) ? -16'sd32768 : (kind == 2) ? ($random % 8) : $random;
          mem_wr(BB/4 + k*P + j, {{16{B[k][j][15]}}, B[k][j]});
        end
      for (i = 0; i < M; i = i + 1)
        for (j = 0; j < P; j = j + 1) begin
          C[i][j] = 0;
          for (k = 0; k < K; k = k + 1)
            C[i][j] = C[i][j] + A[i][k] * B[k][j];
        end

      bus_write(13'h000C, BA);
      bus_write(13'h0010, BB);
      bus_write(13'h0014, BC);
      bus_write(13'h0008, (P << 16) | (K << 8) | M);
      bus_write(13'h0000, 32'd3);
      cycles = 1;
      bus_read(13'h0004, st);
      while (!st[1]) begin
        bus_read(13'h0004, st);
        cycles = cycles + 2;
      end
      repeat (2) @(negedge clk);   // the memory model completes writes after a short delay

      bad = 0;
      for (i = 0; i < M; i = i + 1)
        for (j = 0; j < P; j = j + 1) begin
          e = i*P + j;
          if ({mem_rd(BC/4 + 2*e + 1), mem_rd(BC/4 + 2*e)} !== C[i][j]) begin
            if (bad < 3) $display("  MISMATCH C[%0d][%0d]: expected %0d, got %0d", i, j, C[i][j],
                                  $signed({mem_rd(BC/4 + 2*e + 1), mem_rd(BC/4 + 2*e)}));
            bad = bad + 1;
          end
        end
      // nothing written beyond C, except the padding of an odd last line
      e = (M*P + 1) / 2 * 4;        // words covered by whole lines
      if (mem_rd(BC/4 + e) !== 32'hdeadbeef) begin
        $display("  memory after C was overwritten");
        bad = bad + 1;
      end
      tests = tests + 1;
      errors = errors + bad;
      $display("DMA %-24s %2dx%2d * %2dx%2d  %4d cycles  %s", name, M, K, K, P, cycles, bad ? "FAIL" : "pass");
    end
  endtask

  initial begin
    $dumpfile("tb_matmul_accel.vcd");
    $dumpvars(0, tb_matmul_accel);
    repeat (2) @(negedge clk);
    rst_n = 1;

    $display("matmul_accel: %0dx%0d array, matrices up to %0dx%0d", N, N, MAX, MAX);
    run(16, 16, 16, 0, "random full size");
    run(16, 16, 16, 1, "worst-case -32768");
    run( 8,  8,  8, 0, "one tile");
    run( 5, 13, 11, 0, "rectangular, partial tiles");
    run(16,  3,  9, 0, "short K");
    run( 1,  1,  1, 2, "1x1");
    run(12, 16,  4, 2, "small values");

    run_dma(16, 16, 16, 0, "random full size");
    run_dma(16, 16, 16, 1, "worst-case -32768");
    run_dma( 8,  8,  8, 0, "one tile");
    run_dma( 5, 13, 11, 0, "odd sizes (odd M*P)");
    run_dma( 1,  1,  1, 2, "1x1");
    run_dma(16,  3,  9, 0, "short K");

    // done must clear when a new product starts
    bus_write(13'h0000, 32'd1);
    bus_read(13'h0004, st);
    if (st[1] || !st[0]) begin
      $display("STATUS after start: busy=%0d done=%0d (expected busy=1 done=0)", st[0], st[1]);
      errors = errors + 1;
    end
    while (busy) @(negedge clk);

    $display("RESULT  : %0s (%0d products, %0d errors)", errors ? "FAIL" : "PASS", tests, errors);
    $finish;
  end

endmodule
