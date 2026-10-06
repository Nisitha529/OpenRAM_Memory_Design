module alu(
  input  [31:0] srca,
  input  [31:0] srcb,
  input  [3:0]  alucontrol,
  output reg [31:0] aluresult
);

  wire [31:0] sum;
  wire        overflow;

  assign sum      = srca + (alucontrol[0] ? ~srcb : srcb) + {31'b0, alucontrol[0]};  // sub using 1's complement
  assign overflow = ~(alucontrol[0] ^ srcb[31] ^ srca[31]) & 
                    (srca[31] ^ sum[31]) & 
                    (~alucontrol[1]);


  always @(*) begin
    casez (alucontrol)
      4'b000?: aluresult = sum;                             // add or sub
      4'b0010: aluresult = srca & srcb;                     // and
      4'b0011: aluresult = srca | srcb;                     // or
      4'b0100: aluresult = srca << srcb[4:0];   // FIX: shift amount is 5 bits                    // sll
      4'b0101: aluresult = {31'b0, overflow ^ sum[31]};     // slt
      4'b0110: aluresult = srca ^ srcb;                     // xor
      4'b0111: aluresult = srca >> srcb[4:0];   // FIX: shift amount is 5 bits                    // srl
      4'b1000: aluresult = (srca < srcb) ? 32'b1 : 32'b0;   // sltu
      4'b1111: aluresult = $signed(srca) >>> srcb[4:0];   // FIX: srai imm has bit 10 set          // sra
      default: aluresult = 32'bx;
    endcase
  end

endmodule
