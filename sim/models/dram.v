// Simple main-memory (DRAM) model for simulation (not synthesizable).
// Same behaviour as OpenCache's generated DRAM model: one cache line per
// address, and a multi-cycle stall on every request to imitate slow memory.
module dram (clk, rst, csb, web, addr, din, dout, stall);

  parameter  WORD_WIDTH  = 128;   // one cache line
  parameter  ADDR_WIDTH  = 14;    // line address
  localparam DRAM_DEPTH  = 1 << ADDR_WIDTH;
  parameter  CYCLE_DELAY = 4;
  parameter  DELAY       = 3;

  input  clk;
  input  rst;
  input  csb;
  input  web;
  input  [ADDR_WIDTH-1:0] addr;
  input  [WORD_WIDTH-1:0] din;
  output [WORD_WIDTH-1:0] dout;
  output stall;

  reg [WORD_WIDTH-1:0] dout;
  reg stall;
  reg [WORD_WIDTH-1:0] memory [0:DRAM_DEPTH-1];

  always @(posedge clk) begin
    if (rst) begin
      dout  <= {WORD_WIDTH{1'bx}};
      stall <= 0;
    end else if (!csb && !stall) begin
      stall <= 1;
      stall <= #(CYCLE_DELAY * 5 * 2 + DELAY) 0;
      dout  <= #(DELAY) memory[addr];
      if (!web)
        memory[addr] <= #(DELAY) din;
    end
  end

endmodule
