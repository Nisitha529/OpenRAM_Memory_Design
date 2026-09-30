module regfile (
  input             clk,
  input             we3,
  input      [4:0]  a1,
  input      [4:0]  a2,
  input      [4:0]  a3,
  input      [31:0] wd3,
  output     [31:0] rd1,
  output     [31:0] rd2
);

  reg [31:0] rf [31:0];  // 32 x 32-bit register file

  assign rd1 = (a1 != 0) ? rf[a1] : 32'b0;
  assign rd2 = (a2 != 0) ? rf[a2] : 32'b0;

  always @(negedge clk) begin
    if (we3)
      rf[a3] <= wd3;
  end

endmodule
