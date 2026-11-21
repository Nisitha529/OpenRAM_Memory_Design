module alu # 
  (parameter DATA_WIDTH = 32
)(
  input      [DATA_WIDTH - 1 : 0] srca,
  input      [DATA_WIDTH - 1 : 0] srcb,

  input      [3 : 0]              alucontrol,

  output reg [DATA_WIDTH - 1 : 0] aluresult
);

  localparam MSB         = DATA_WIDTH - 1;
  localparam SHAMT_WIDTH = $clog2 (DATA_WIDTH);

  wire [DATA_WIDTH - 1 : 0]  sum;
  wire                       overflow;

  wire [SHAMT_WIDTH - 1 : 0] shamt;

  assign shamt    = srcb [SHAMT_WIDTH - 1 : 0];

  assign sum      = srca + (alucontrol[0] ? ~srcb : srcb) + {{(DATA_WIDTH-1){1'b0}}, alucontrol[0]};  // sub using 1's complement
  assign overflow = ~(alucontrol[0] ^ srcb[DATA_WIDTH - 1] ^ srca[DATA_WIDTH - 1]) & (srca[DATA_WIDTH - 1] ^ sum[DATA_WIDTH - 1]) & (~alucontrol[1]);


  always @(*) begin
    casez (alucontrol)
      4'b000?: aluresult = sum;                                                                 // add or sub
      4'b0010: aluresult = srca & srcb;                                                         // and
      4'b0011: aluresult = srca | srcb;                                                         // or
      4'b0100: aluresult = srca << shamt;                                                       // sll
      4'b0101: aluresult = {{(DATA_WIDTH-1){1'b0}}, overflow ^ sum[DATA_WIDTH - 1]};            // slt
      4'b0110: aluresult = srca ^ srcb;                                                         // xor
      4'b0111: aluresult = srca >> shamt;                                                       // srl
      4'b1000: aluresult = (srca < srcb) ? {{(DATA_WIDTH-1){1'b0}}, 1'b1} : {DATA_WIDTH{1'b0}}; // sltu
      4'b1111: aluresult = $signed(srca) >>> shamt;                                             // sra
      default: aluresult = {DATA_WIDTH{1'bx}};
    endcase
  end

endmodule
