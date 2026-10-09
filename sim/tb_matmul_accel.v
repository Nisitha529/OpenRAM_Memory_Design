// Self-checking testbench for rtl/accel/matmul_accel.v, driven only through
// its register bus, the way the CPU will use it: write A and B, write DIMS,
// start, poll STATUS until done, read C and compare with a 64-bit reference.
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

  matmul_accel #(.N(N), .MAX_DIM(MAX), .DATA_WIDTH(DW), .ACC_WIDTH(AW)) dut (
    .clk(clk), .rst_n(rst_n),
    .sel(sel), .we(we), .addr(addr), .wdata(wdata), .rdata(rdata),
    .busy(busy), .done(done)
  );

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
