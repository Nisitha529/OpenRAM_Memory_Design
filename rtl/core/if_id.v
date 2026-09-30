module if_id(
  input             clk,
  input             reset,
  input             clear,
  input             enable,
  input      [31:0] instrf,
  input      [31:0] pcf,
  input      [31:0] pcplus4f,
  output reg [31:0] instrd,
  output reg [31:0] pcd,
  output reg [31:0] pcplus4d
);

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      instrd     <= 0;
      pcd        <= 0;
      pcplus4d   <= 0;
    end else if (enable) begin
      if (clear) begin
        instrd     <= 0;
        pcd        <= 0;
        pcplus4d   <= 0;
      end else begin
        instrd     <= instrf;
        pcd        <= pcf;
        pcplus4d   <= pcplus4f;
      end
    end
  end

endmodule
