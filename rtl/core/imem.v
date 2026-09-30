module imem(
  input       [31:0] a,
  output wire [31:0] rd
);

  reg [7:0] ram [0:127];  // 128 bytes of instruction memory

  assign rd = {ram[a + 3], ram[a + 2], ram[a + 1], ram[a]};

  initial begin
    // Instruction: 00f00093
    ram[0]  = 8'h93;  ram[1]  = 8'h00;  ram[2]  = 8'hf0;  ram[3]  = 8'h00;
    // Instruction: 01600113
    ram[4]  = 8'h13;  ram[5]  = 8'h01;  ram[6]  = 8'h60;  ram[7]  = 8'h01;
    // Instruction: 002081b3
    ram[8]  = 8'hb3;  ram[9]  = 8'h81;  ram[10] = 8'h20;  ram[11] = 8'h00;
    // Instruction: 0021e233
    ram[12] = 8'h33;  ram[13] = 8'he2;  ram[14] = 8'h21;  ram[15] = 8'h00;
    // Instruction: 0041c2b3
    ram[16] = 8'hb3;  ram[17] = 8'hc2;  ram[18] = 8'h41;  ram[19] = 8'h00;
    // Instruction: 00428333
    ram[20] = 8'h33;  ram[21] = 8'h83;  ram[22] = 8'h42;  ram[23] = 8'h00;
    // Instruction: 02628863
    ram[24] = 8'h63;  ram[25] = 8'h88;  ram[26] = 8'h62;  ram[27] = 8'h02;
    // Instruction: 0041a233
    ram[28] = 8'h33;  ram[29] = 8'ha2;  ram[30] = 8'h41;  ram[31] = 8'h00;
    // Instruction: 00020463
    ram[32] = 8'h63;  ram[33] = 8'h04;  ram[34] = 8'h02;  ram[35] = 8'h00;
    // Instruction: 00000313
    ram[36] = 8'h13;  ram[37] = 8'h03;  ram[38] = 8'h00;  ram[39] = 8'h00;
    // Instruction: 0032a233
    ram[40] = 8'h33;  ram[41] = 8'ha2;  ram[42] = 8'h32;  ram[43] = 8'h00;
    // Instruction: 00520333
    ram[44] = 8'h33;  ram[45] = 8'h03;  ram[46] = 8'h52;  ram[47] = 8'h00;
    // Instruction: 40118133
    ram[48] = 8'h33;  ram[49] = 8'h81;  ram[50] = 8'h11;  ram[51] = 8'h40;
    // Instruction: 0411aa23
    ram[52] = 8'h23;  ram[53] = 8'haa;  ram[54] = 8'h11;  ram[55] = 8'h04;
    // Instruction: 0541a083
    ram[56] = 8'h83;  ram[57] = 8'ha0;  ram[58] = 8'h41;  ram[59] = 8'h05;
    // Instruction: 00008093
    ram[60] = 8'h93;  ram[61] = 8'h80;  ram[62] = 8'h00;  ram[63] = 8'h00;
    // Instruction: 003103b3
    ram[64] = 8'hb3;  ram[65] = 8'h03;  ram[66] = 8'h31;  ram[67] = 8'h00;
    // Instruction: 004001ef
    ram[68] = 8'hef;  ram[69] = 8'h01;  ram[70] = 8'h40;  ram[71] = 8'h00;
    // Instruction: 00910133
    ram[72] = 8'h33;  ram[73] = 8'h01;  ram[74] = 8'h91;  ram[75] = 8'h00;
    // Instruction: 00100213
    ram[76] = 8'h13;  ram[77] = 8'h02;  ram[78] = 8'h10;  ram[79] = 8'h00;
    // Instruction: 00108063
    ram[80] = 8'h63;  ram[81] = 8'h80;  ram[82] = 8'h10;  ram[83] = 8'h00;
  end

endmodule
