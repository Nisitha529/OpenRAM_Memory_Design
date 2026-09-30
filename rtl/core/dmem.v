module dmem(
  input        clk,
  input        we,
  input [31:0] a,
  input [31:0] wd,
  output [31:0] rd
);

  reg [31:0] ram [0:63];  // 64 x 32-bit memory
  
  // Initialize all memory locations to zero
  integer i;
  initial begin
    for (i = 0; i < 64; i = i + 1)
      ram[i] = 32'h0;
  end

  assign rd = ram[a[31:2]];

  always @(posedge clk) begin
    if (we) begin
      ram[a[31:2]] <= wd;
    end
  end
endmodule