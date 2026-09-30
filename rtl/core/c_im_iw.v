module c_im_iw(
  input             clk,
  input             reset,
  input             enable,   // CACHE: low while a cache miss freezes the pipeline
  input             regwritem,
  input       [1:0] resultsrcm,
  output reg        regwritew,
  output reg  [1:0] resultsrcw
);

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      regwritew   <= 0;
      resultsrcw  <= 0;
    end
    else if (enable) begin
      regwritew   <= regwritem;
      resultsrcw  <= resultsrcm;
    end
  end

endmodule
