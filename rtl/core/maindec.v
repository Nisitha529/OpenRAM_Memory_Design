module maindec(
  input  [6:0]  op,
  output        regwrite,
  output [1:0]  resultsrc,
  output        memwrite,
  output        branch,
  output        alusrca,
  output [1:0]  alusrcb,
  output        jump,
  output [2:0]  immsrc,
  output [1:0]  aluop
);

  reg [13:0] controls;

  assign regwrite   = controls[13];
  assign immsrc     = controls[12:10];
  assign alusrca    = controls[9];
  assign alusrcb    = controls[8:7];
  assign memwrite   = controls[6];
  assign resultsrc  = controls[5:4];
  assign branch     = controls[3];
  assign aluop      = controls[2:1];
  assign jump       = controls[0];

  always @(*) begin
    case (op)
      7'b0000011: controls = 14'b1_000_0_01_0_01_0_00_0; // lw
      7'b0100011: controls = 14'b0_001_0_01_1_00_0_00_0; // sw
      7'b0110011: controls = 14'b1_000_0_00_0_00_0_10_0; // r-type
      7'b1100011: controls = 14'b0_010_0_00_0_00_1_01_0; // b-type
      7'b0010011: controls = 14'b1_000_0_01_0_00_0_10_0; // i-type
      7'b1101111: controls = 14'b1_011_0_00_0_10_0_00_1; // jal
      7'b0010111: controls = 14'b1_100_1_10_0_00_0_00_0; // auipc
      7'b0110111: controls = 14'b1_100_1_01_0_00_0_00_0; // lui
      7'b1100111: controls = 14'b1_000_0_01_0_10_0_00_1; // jalr
      7'b0000000: controls = 14'b0_000_0_00_0_00_0_00_0; // nop / reset
      default:    controls = 14'b0_000_0_00_0_00_0_00_0; // fallback safe
    endcase
  end

endmodule
