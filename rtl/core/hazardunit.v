module hazardunit(
  input      [4:0] rs1d,
  input      [4:0] rs2d,
  input      [4:0] rs1e,
  input      [4:0] rs2e,
  input      [4:0] rde,
  input      [4:0] rdm,
  input      [4:0] rdw,
  input            regwritem,
  input            regwritew,
  input            resultsrce0,
  input            pcsrce,
  output reg [1:0] forwardae,
  output reg [1:0] forwardbe,
  output           stalld,
  output           stallf,
  output           flushd,
  output           flushe
);

  wire lwstall;

  always @(*) begin
    forwardae = 2'b00;
    forwardbe = 2'b00;

    if ((rs1e == rdm) && regwritem && (rs1e != 0))
      forwardae = 2'b10;
    else if ((rs1e == rdw) && regwritew && (rs1e != 0))
      forwardae = 2'b01;

    if ((rs2e == rdm) && regwritem && (rs2e != 0))
      forwardbe = 2'b10;
    else if ((rs2e == rdw) && regwritew && (rs2e != 0))
      forwardbe = 2'b01;
  end

  assign lwstall = resultsrce0 && ((rde == rs1d) || (rde == rs2d));
  assign stallf  = lwstall;
  assign stalld  = lwstall;
  assign flushe  = lwstall || pcsrce;
  assign flushd  = pcsrce;

endmodule
