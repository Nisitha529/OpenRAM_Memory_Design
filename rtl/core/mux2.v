module mux2(
  input      [31:0] d0,
  input      [31:0] d1,
  input             s,
  output reg [31:0] y
);

  always @(*) begin
    y = s ? d1 : d0;
  end

endmodule
