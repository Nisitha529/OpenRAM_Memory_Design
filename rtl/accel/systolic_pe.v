// Processing element of the output-stationary systolic array.
//
// Each cycle with en = 1 it multiplies the operand arriving from the west (a,
// a row of matrix A) with the one from the north (b, a column of matrix B),
// adds the product to its own accumulator - which holds one element of C -
// and passes a east and b south to its neighbours one cycle later.
//
// Based on block.v of the EN4020 Systolic_Array_Design (Group 4), changed for
// the ASIC flow: signed operands, separate accumulator width, synchronous
// clear instead of rst_flush, parameterised widths.
module systolic_pe #(
  parameter DATA_WIDTH = 16,   // signed operands
  parameter ACC_WIDTH  = 40    // signed accumulator
) (
  input                              clk,
  input                              rst_n,
  input                              clear,    // zero accumulator and pipeline
  input                              en,       // advance one step

  input      signed [DATA_WIDTH-1:0] a_in,     // from the west
  input      signed [DATA_WIDTH-1:0] b_in,     // from the north
  output reg signed [DATA_WIDTH-1:0] a_out,    // to the east
  output reg signed [DATA_WIDTH-1:0] b_out,    // to the south
  output reg signed [ACC_WIDTH-1:0]  acc
);

  wire signed [2*DATA_WIDTH-1:0] product = a_in * b_in;

  always @(posedge clk) begin
    if (!rst_n || clear) begin
      a_out <= {DATA_WIDTH{1'b0}};
      b_out <= {DATA_WIDTH{1'b0}};
      acc   <= {ACC_WIDTH{1'b0}};
    end else if (en) begin
      a_out <= a_in;
      b_out <= b_in;
      acc   <= acc + {{(ACC_WIDTH-2*DATA_WIDTH){product[2*DATA_WIDTH-1]}}, product};
    end
  end

endmodule
