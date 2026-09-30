module top_module (
  input         clk,
  input         reset,
  output [31:0] writedatam,
  output [31:0] dataadrm,
  output        memwritem
);

  wire [31:0] pcf;
  wire [31:0] instrf;
  wire [31:0] readdatam;

  // instantiate processor and memories
  riscv_module rv (
    .clk         (clk),
    .reset       (reset),
    .pcf         (pcf),
    .instrf      (instrf),
    .memwritem   (memwritem),
    .aluresultm  (dataadrm),
    .writedatam  (writedatam),
    .readdatam   (readdatam),
    .freeze      (1'b0),
    .imem_addr   (),
    .memreadm    (),
    .dreq_we     (),
    .dreq_re     (),
    .dreq_addr   (),
    .dreq_wdata  ()
  );

  imem imem_inst (
    .a  (pcf),
    .rd (instrf)
  );

  dmem dmem_inst (
    .clk   (clk),
    .we    (memwritem),
    .a     (dataadrm),
    .wd    (writedatam),
    .rd    (readdatam)
  );

endmodule
