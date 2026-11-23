module c_im_iw(
  input             clk,
  input             reset,
  input             enable,   // CACHE: low while a cache miss freezes the pipeline
  input             regwritem,
  input       [1:0] resultsrcm,
  input       [2:0] funct3m,  // load size and sign (lb/lh/lw/lbu/lhu)
  output reg        regwritew,
  output reg  [1:0] resultsrcw,
  output reg  [2:0] funct3w
);

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      regwritew   <= 0;
      resultsrcw  <= 0;
      funct3w     <= 0;
    end
    else if (enable) begin
      regwritew   <= regwritem;
      resultsrcw  <= resultsrcm;
      funct3w     <= funct3m;
    end
  end

endmodule
