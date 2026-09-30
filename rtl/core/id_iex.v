module id_iex(
  input             clk,
  input             reset,
  input             clear,
  input             enable,   // CACHE: low while a cache miss freezes the pipeline
  input      [31:0] rd1d,
  input      [31:0] rd2d,
  input      [31:0] pcd,
  input      [4:0]  rs1d,
  input      [4:0]  rs2d,
  input      [4:0]  rdd,
  input      [31:0] immextd,
  input      [31:0] pcplus4d,
  output reg [31:0] rd1e,
  output reg [31:0] rd2e,
  output reg [31:0] pce,
  output reg [4:0]  rs1e,
  output reg [4:0]  rs2e,
  output reg [4:0]  rde,
  output reg [31:0] immexte,
  output reg [31:0] pcplus4e
);

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      rd1e      <= 32'b0;
      rd2e      <= 32'b0;
      pce       <= 32'b0;
      rs1e      <= 5'b0;
      rs2e      <= 5'b0;
      rde       <= 5'b0;
      immexte   <= 32'b0;
      pcplus4e  <= 32'b0;
    end
    else if (enable) begin
      if (clear) begin
        rd1e      <= 32'b0;
        rd2e      <= 32'b0;
        pce       <= 32'b0;
        rs1e      <= 5'b0;
        rs2e      <= 5'b0;
        rde       <= 5'b0;
        immexte   <= 32'b0;
        pcplus4e  <= 32'b0;
      end
      else begin
        rd1e      <= rd1d;
        rd2e      <= rd2d;
        pce       <= pcd;
        rs1e      <= rs1d;
        rs2e      <= rs2d;
        rde       <= rdd;
        immexte   <= immextd;
        pcplus4e  <= pcplus4d;
      end
    end
  end

endmodule
