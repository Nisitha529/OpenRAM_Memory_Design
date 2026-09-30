module controller(
  input        clk,
  input        reset,
  input  [6:0] op,
  input  [2:0] funct3,
  input        funct7b5,
  input        zeroe,
  input        signe,
  input        flushe,
  input        freeze,        // CACHE: hold all pipeline registers
  output       resultsrce0,
  output [1:0] resultsrcw,
  output       memwritee,     // CACHE: store in execute (next data request)
  output       memreade,      // CACHE: load in execute
  output       memwritem,
  output       memreadm,      // CACHE: load in memory stage
  output       pcjalsrce,
  output       pcsrce,
  output       alusrcae,
  output [1:0] alusrcbe,
  output       regwritem,
  output       regwritew,
  output [2:0] immsrcd,
  output [3:0] alucontrole
);

  wire [1:0] aluopd;
  wire [1:0] resultsrcd, resultsrce, resultsrcm;
  wire [3:0] alucontrold;
  wire       branchd, branche, memwrited, jumpd, jumpe, jalre;
  wire       alusrcad, regwrited, regwritee;
  wire [1:0] alusrcbd;
  wire       zeroop, signop, branchop;
  wire [2:0] funct3e;

  maindec md (
    .op         (op),
    .resultsrc  (resultsrcd),
    .memwrite   (memwrited),
    .branch     (branchd),
    .alusrca    (alusrcad),
    .alusrcb    (alusrcbd),
    .regwrite   (regwrited),
    .jump       (jumpd),
    .immsrc     (immsrcd),
    .aluop      (aluopd)
  );

  aludec ad (
    .opb5       (op[5]),
    .funct3     (funct3),
    .funct7b5   (funct7b5),
    .aluop      (aluopd),
    .alucontrol (alucontrold)
  );

  c_id_iex pipreg_d_to_e (
    .clk         (clk),
    .reset       (reset),
    .clear       (flushe),
    .enable      (~freeze),
    .jalrd       (op == 7'b1100111),
    .funct3d     (funct3),
    .regwrited   (regwrited),
    .memwrited   (memwrited),
    .jumpd       (jumpd),
    .branchd     (branchd),
    .alusrcad    (alusrcad),
    .alusrcbd    (alusrcbd),
    .resultsrcd  (resultsrcd),
    .alucontrold (alucontrold),
    .regwritee   (regwritee),
    .memwritee   (memwritee),
    .jumpe       (jumpe),
    .branche     (branche),
    .alusrcae    (alusrcae),
    .alusrcbe    (alusrcbe),
    .resultsrce  (resultsrce),
    .alucontrole (alucontrole),
    .jalre       (jalre),
    .funct3e     (funct3e)
  );

  c_iex_im pipreg_e_to_m (
    .clk         (clk),
    .reset       (reset),
    .enable      (~freeze),
    .regwritee   (regwritee),
    .memwritee   (memwritee),
    .resultsrce  (resultsrce),
    .regwritem   (regwritem),
    .memwritem   (memwritem),
    .resultsrcm  (resultsrcm)
  );

  c_im_iw pipreg_m_to_w (
    .clk         (clk),
    .reset       (reset),
    .enable      (~freeze),
    .regwritem   (regwritem),
    .resultsrcm  (resultsrcm),
    .regwritew   (regwritew),
    .resultsrcw  (resultsrcw)
  );

  assign resultsrce0  = resultsrce[0];
  // FIX: the branch is resolved in execute, so use the execute-stage funct3
  // (the original used the decode-stage one, i.e. the *next* instruction's).
  // beq/bne: zero flag of rs1 - rs2. blt/bge/bltu/bgeu: ALU gives slt/sltu,
  // so zero flag = !(rs1 < rs2).
  assign zeroop       = zeroe ^ funct3e[0];
  assign signop       = ~zeroe ^ funct3e[0];
  assign branchop     = funct3e[2] ? signop : zeroop;
  assign pcsrce       = (branche & branchop) | jumpe;
  // FIX: select the JALR target (rs1 + imm) when the JALR is in *execute*.
  // The original decoded this from the decode-stage opcode, so JALR jumped to
  // PC + imm unless another JALR happened to be in decode at the same time.
  assign pcjalsrce    = jalre;
  assign memreade     = (resultsrce == 2'b01);
  assign memreadm     = (resultsrcm == 2'b01);

endmodule
