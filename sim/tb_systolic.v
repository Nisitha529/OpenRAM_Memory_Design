// Self-checking testbench for rtl/accel/systolic_array.v
//
// The testbench is the feeder: in step t it drives west row i with A[i][t-i]
// and north column j with B[t-j][j] (zero outside the matrix). After
// K + 2N - 2 steps it reads every C element through rd_row/rd_col and compares
// with a 64-bit reference product.
//
//   +define+N=<n>   array size (default 16)
`timescale 1ns/1ps
module tb_systolic;

`ifndef N
  `define N 16
`endif
  localparam N     = `N;
  localparam DW    = 16;
  localparam AW    = 40;
  localparam MAXK  = 64;

  reg clk = 0, rst_n = 0, clear = 0, en = 0;
  always #5 clk = ~clk;

  reg  [N*DW-1:0]      west_in = 0, north_in = 0;
  reg  [$clog2(N)-1:0] rd_row = 0, rd_col = 0;
  wire [AW-1:0]        rd_data;

  systolic_array #(.N(N), .DATA_WIDTH(DW), .ACC_WIDTH(AW)) dut (
    .clk(clk), .rst_n(rst_n), .clear(clear), .en(en),
    .west_in(west_in), .north_in(north_in),
    .rd_row(rd_row), .rd_col(rd_col), .rd_data(rd_data)
  );

  reg signed [DW-1:0] A [0:N-1][0:MAXK-1];
  reg signed [DW-1:0] B [0:MAXK-1][0:N-1];
  reg signed [63:0]   C [0:N-1][0:N-1];

  integer i, j, k, t, errors = 0, tests = 0, steps;

  // kind 0: random, 1: all -32768 (largest products), 2: small values
  task make_matrices(input integer K, input integer kind);
    begin
      for (i = 0; i < N; i = i + 1)
        for (k = 0; k < K; k = k + 1) begin
          case (kind)
            0: begin A[i][k] = $random; B[k][i] = $random; end
            1: begin A[i][k] = -16'sd32768; B[k][i] = -16'sd32768; end
            default: begin A[i][k] = ($random % 8); B[k][i] = ($random % 8); end
          endcase
        end
      for (i = 0; i < N; i = i + 1)
        for (j = 0; j < N; j = j + 1) begin
          C[i][j] = 0;
          for (k = 0; k < K; k = k + 1)
            C[i][j] = C[i][j] + A[i][k] * B[k][j];
        end
    end
  endtask

  // Feed the skewed operands; with stall = 1, en randomly drops for a cycle
  // (inputs are held), as when a feeder cannot supply data every cycle.
  task run_matmul(input integer K, input integer stall);
    begin
      @(negedge clk); clear = 1; en = 0;
      @(negedge clk); clear = 0;
      steps = K + 2*N - 2;
      t = 0;
      while (t < steps) begin
        for (i = 0; i < N; i = i + 1) begin
          west_in[i*DW +: DW]  = (t-i >= 0 && t-i < K) ? A[i][t-i] : 0;
          north_in[i*DW +: DW] = (t-i >= 0 && t-i < K) ? B[t-i][i] : 0;
        end
        en = stall ? ($random & 1) : 1;
        @(negedge clk);
        if (en) t = t + 1;
      end
      en = 0; west_in = 0; north_in = 0;
    end
  endtask

  task check(input [8*24-1:0] name);
    integer bad;
    begin
      bad = 0;
      for (i = 0; i < N; i = i + 1)
        for (j = 0; j < N; j = j + 1) begin
          rd_row = i; rd_col = j;
          @(negedge clk);
          if ($signed(rd_data) !== C[i][j][AW-1:0] || C[i][j] !== {{(64-AW){C[i][j][AW-1]}}, C[i][j][AW-1:0]}) begin
            if (bad < 3) $display("  MISMATCH C[%0d][%0d]: expected %0d, got %0d", i, j, C[i][j], $signed(rd_data));
            bad = bad + 1;
          end
        end
      tests = tests + 1;
      errors = errors + bad;
      $display("%-24s %s", name, bad ? "FAIL" : "pass");
    end
  endtask

  initial begin
    $dumpfile("tb_systolic.vcd");
    $dumpvars(0, tb_systolic);
    repeat (2) @(negedge clk);
    rst_n = 1;

    $display("Systolic array %0dx%0d, %0d-bit signed data, %0d-bit accumulators", N, N, DW, AW);
    make_matrices(N, 0);  run_matmul(N, 0);  check("random NxN");
    make_matrices(N, 1);  run_matmul(N, 0);  check("worst-case -32768");
    make_matrices(37, 0); run_matmul(37, 0); check("random K=37");
    make_matrices(N, 2);  run_matmul(N, 1);  check("random stalls");
    make_matrices(N, 0);  run_matmul(N, 1);  check("clear + stalls again");

    $display("RESULT  : %0s (%0d tests, %0d element errors)", errors ? "FAIL" : "PASS", tests, errors);
    $finish;
  end

endmodule
