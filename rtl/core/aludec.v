module aludec(
  input  [0:0]   opb5,
  input  [2:0]   funct3,
  input  [0:0]   funct7b5,
  input  [1:0]   aluop,
  output [3:0]   alucontrol
);

  wire rtypesub;
  reg  [3:0] alucontrol_reg;

  assign rtypesub   = funct7b5 & opb5;
  assign alucontrol = alucontrol_reg;

  always @(*) begin
    case (aluop)
      2'b00: alucontrol_reg = 4'b0000;
      2'b01: alucontrol_reg = 4'b0001;   // branch (result unused: the datapath has a comparator)
      default: begin
        case (funct3)
          3'b000: alucontrol_reg  = rtypesub ? 4'b0001 : 4'b0000;
          3'b001: alucontrol_reg  = 4'b0100;
          3'b010: alucontrol_reg  = 4'b0101;
          3'b011: alucontrol_reg  = 4'b1000;
          3'b100: alucontrol_reg  = 4'b0110;
          3'b101: alucontrol_reg  = (~funct7b5) ? 4'b0111 : 4'b1111;
          3'b110: alucontrol_reg  = 4'b0011;
          3'b111: alucontrol_reg  = 4'b0010;
          default: alucontrol_reg = 4'bxxxx;
        endcase
      end
    endcase
  end

endmodule
