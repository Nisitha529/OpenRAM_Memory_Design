// N x N output-stationary systolic array computing C = A x B.
//
// Data flow: row i of A enters PE(i,0) from the west and moves east; column j
// of B enters PE(0,j) from the north and moves south. PE(i,j) accumulates
// C[i][j] = sum_k A[i][k] * B[k][j].
//
// Inputs must be skewed (the feeder's job): in step t, west_in row i carries
// A[i][t-i] and north_in column j carries B[t-j][j], and zero outside the
// matrix. For an (N x K) x (K x N) product, K + 2N - 2 steps with en = 1
// complete every C element. clear starts a new product.
//
// Results are read one at a time: put (rd_row, rd_col) on the inputs and the
// element appears on rd_data in the next cycle.
//
// Based on systolic_array.v of the EN4020 Systolic_Array_Design (Group 4),
// rewritten with generate loops so N is a parameter (the original was a fixed
// 8 x 8 netlist of 64 hand-written instances).
module systolic_array #(
  parameter N          = 16,
  parameter DATA_WIDTH = 16,
  parameter ACC_WIDTH  = 40
) (
  input                         clk,
  input                         rst_n,
  input                         clear,
  input                         en,

  input      [N*DATA_WIDTH-1:0] west_in,    // row i at [i*DATA_WIDTH +: DATA_WIDTH]
  input      [N*DATA_WIDTH-1:0] north_in,   // column j at [j*DATA_WIDTH +: DATA_WIDTH]

  input      [$clog2(N)-1:0]    rd_row,
  input      [$clog2(N)-1:0]    rd_col,
  output reg [ACC_WIDTH-1:0]    rd_data
);

  // a_bus[i][j] / b_bus[i][j]: operand entering PE(i,j) from the west / north.
  // Column N of a_bus and row N of b_bus are the unused outputs at the edge.
  wire [DATA_WIDTH-1:0] a_bus [0:N-1][0:N];
  wire [DATA_WIDTH-1:0] b_bus [0:N][0:N-1];
  wire [ACC_WIDTH-1:0]  acc   [0:N-1][0:N-1];

  genvar i, j;
  generate
    for (i = 0; i < N; i = i + 1) begin : g_edge
      assign a_bus[i][0] = west_in[i*DATA_WIDTH +: DATA_WIDTH];
      assign b_bus[0][i] = north_in[i*DATA_WIDTH +: DATA_WIDTH];
    end
    for (i = 0; i < N; i = i + 1) begin : g_row
      for (j = 0; j < N; j = j + 1) begin : g_col
        systolic_pe #(.DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) pe (
          .clk   (clk),
          .rst_n (rst_n),
          .clear (clear),
          .en    (en),
          .a_in  (a_bus[i][j]),
          .b_in  (b_bus[i][j]),
          .a_out (a_bus[i][j+1]),
          .b_out (b_bus[i+1][j]),
          .acc   (acc[i][j])
        );
      end
    end
  endgenerate

  always @(posedge clk) begin
    if (!rst_n)
      rd_data <= {ACC_WIDTH{1'b0}};
    else
      rd_data <= acc[rd_row][rd_col];
  end

endmodule
