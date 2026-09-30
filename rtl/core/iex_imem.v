module iex_imem(
  input             clk,
  input             reset,
  input             enable,   // CACHE: low while a cache miss freezes the pipeline
  input      [31:0] aluresulte,
  input      [31:0] writedatae,
  input      [4:0]  rde,
  input      [31:0] pcplus4e,
  output reg [31:0] aluresulm,
  output reg [31:0] writedatm,
  output reg [4:0]  rdm,
  output reg [31:0] pcplus4m
);

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      aluresulm   <= 0;
      writedatm   <= 0;
      rdm         <= 0;
      pcplus4m    <= 0;
    end else if (enable) begin
      aluresulm   <= aluresulte;
      writedatm   <= writedatae;
      rdm         <= rde;
      pcplus4m    <= pcplus4e;
    end
  end

endmodule
