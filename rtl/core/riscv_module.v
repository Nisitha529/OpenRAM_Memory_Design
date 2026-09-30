/*
  Name: RISC V RV32I
  Description: Implements 27 instructions
               5 stage pipeline
               Hazard Unit is present for handling both control and data hazards

  CACHE: extra ports for synchronous memories / caches (answer one cycle later).
    freeze        - hold the whole pipeline (a cache has not answered yet)
    imem_addr     - fetch address for the next cycle; instrf must hold its
                    instruction in the next cycle
    dreq_*        - data request for the next cycle; readdatam must hold the
                    load result in the next cycle
  With freeze = 0 and the original combinational imem/dmem (pcf, aluresultm,
  memwritem ports) the core behaves exactly as before.
*/

module riscv_module(
  input  clk,
  input  reset,
  output [31:0] pcf,
  input  [31:0] instrf,
  output        memwritem,
  output [31:0] aluresultm,
  output [31:0] writedatam,
  input  [31:0] readdatam,
  // CACHE ports
  input         freeze,
  output [31:0] imem_addr,
  output        memreadm,
  output        dreq_we,
  output        dreq_re,
  output [31:0] dreq_addr,
  output [31:0] dreq_wdata
);

  wire        alusrcae;
  wire        regwritem;
  wire        regwritew;
  wire        zeroe;
  wire        signe;
  wire        pcjalsrce;
  wire        pcsrce;
  wire [1:0]  alusrcbe;
  wire        stalld;
  wire        stallf;
  wire        flushd;
  wire        flushe;
  wire        resultsrce0;
  wire [1:0]  resultsrcw;
  wire [2:0]  immsrcd;
  wire [3:0]  alucontrole;
  wire [31:0] instrd;
  wire [4:0]  rs1d, rs2d, rs1e, rs2e;
  wire [4:0]  rde, rdm, rdw;
  wire [1:0]  forwardae, forwardbe;
  wire        memwritee, memreade;
  wire [31:0] aluresulte, writedatae;

  // CACHE: the data request that should be served in the next cycle is the
  // execute-stage access (it moves to memory stage at the next edge). While
  // frozen nothing moves, so keep asking for the memory-stage access instead.
  assign dreq_we    = freeze ? memwritem  : memwritee;
  assign dreq_re    = freeze ? memreadm   : memreade;
  assign dreq_addr  = freeze ? aluresultm : aluresulte;
  assign dreq_wdata = freeze ? writedatam : writedatae;

  controller controller_01 (
    .clk           (clk),
    .reset         (reset),
    .op            (instrd[6:0]),
    .funct3        (instrd[14:12]),
    .funct7b5      (instrd[30]),
    .zeroe         (zeroe),
    .signe         (signe),
    .flushe        (flushe),
    .freeze        (freeze),
    .memwritee     (memwritee),
    .memreade      (memreade),
    .memreadm      (memreadm),
    .resultsrce0   (resultsrce0),
    .resultsrcw    (resultsrcw),
    .memwritem     (memwritem),
    .pcjalsrce     (pcjalsrce),
    .pcsrce        (pcsrce),
    .alusrcae      (alusrcae),
    .alusrcbe      (alusrcbe),
    .regwritem     (regwritem),
    .regwritew     (regwritew),
    .immsrcd        (immsrcd),
    .alucontrole   (alucontrole)
  );

  hazardunit hazardunit_01 (
    .rs1d        (rs1d),
    .rs2d        (rs2d),
    .rs1e        (rs1e),
    .rs2e        (rs2e),
    .rde         (rde),
    .rdm         (rdm),
    .rdw         (rdw),
    .regwritem   (regwritem),
    .regwritew   (regwritew),
    .resultsrce0 (resultsrce0),
    .pcsrce      (pcsrce),
    .forwardae   (forwardae),
    .forwardbe   (forwardbe),
    .stalld      (stalld),
    .stallf      (stallf),
    .flushd      (flushd),
    .flushe      (flushe)
  );

  datapath datapath_01 (
    .clk           (clk),
    .reset         (reset),
    .resultsrcw    (resultsrcw),
    .pcjalsrce     (pcjalsrce),
    .pcsrce        (pcsrce),
    .alusrcae      (alusrcae),
    .alusrcbe      (alusrcbe),
    .regwritew     (regwritew),
    .immsrcd       (immsrcd),
    .alucontrole   (alucontrole),
    .zeroe         (zeroe),
    .signe         (signe),
    .pcf           (pcf),
    .instrf        (instrf),
    .instrd        (instrd),
    .aluresultm    (aluresultm),
    .writedatam    (writedatam),
    .readdatam     (readdatam),
    .forwardae     (forwardae),
    .forwardbe     (forwardbe),
    .rs1d          (rs1d),
    .rs2d          (rs2d),
    .rs1e          (rs1e),
    .rs2e          (rs2e),
    .rde           (rde),
    .rdm           (rdm),
    .rdw           (rdw),
    .stalld        (stalld),
    .stallf        (stallf),
    .flushd        (flushd),
    .flushe        (flushe),
    .freeze        (freeze),
    .imem_addr     (imem_addr),
    .aluresulte    (aluresulte),
    .writedatae    (writedatae)
  );

endmodule
