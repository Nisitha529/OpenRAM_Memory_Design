module imem_iw(
  input             clk,
  input             reset,
  input             enable,   // CACHE: low while a cache miss freezes the pipeline
  input      [31:0] aluresultm,
  input      [31:0] readdatam,
  input      [4:0]  rdm,
  input      [31:0] pcplus4m,
  output reg [31:0] aluresultw,
  output reg [31:0] readdataw,
  output reg [4:0]  rdw,
  output reg [31:0] pcplus4w
);

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      aluresultw <= 0;
      readdataw  <= 0;
      rdw        <= 0;
      pcplus4w   <= 0;
    end else if (enable) begin
      aluresultw <= aluresultm;
      readdataw  <= readdatam;
      rdw        <= rdm;
      pcplus4w   <= pcplus4m;
    end
  end

endmodule
