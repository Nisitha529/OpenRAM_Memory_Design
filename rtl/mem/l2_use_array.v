// L2 "use" array (LRU state): 32 entries x 2 bits, one write port + one read port.
//
// OpenCache asks for this as an SRAM macro, but 64 bits is far too small for
// one: the OpenRAM macro is 521 x 582 um (mostly decoders, sense amps and
// control) and its layout had DRC errors. Small arrays like this are normally
// built from flip-flops, so this module replaces the macro.
//
// Ports and cycle behaviour match the OpenRAM model exactly, so the cache RTL
// is unchanged:
//   * inputs are captured at the rising edge
//   * the write happens and read data appears at the following falling edge
module l2_use_array (
`ifdef USE_POWER_PINS
  inout                        vdd,
  inout                        gnd,
`endif
  // Port 0: write
  input                        clk0,
  input                        csb0,
  input      [ADDR_WIDTH-1:0]  addr0,
  input      [DATA_WIDTH-1:0]  din0,
  // Port 1: read
  input                        clk1,
  input                        csb1,
  input      [ADDR_WIDTH-1:0]  addr1,
  output reg [DATA_WIDTH-1:0]  dout1
);

  parameter DATA_WIDTH = 2;
  parameter ADDR_WIDTH = 5;
  localparam RAM_DEPTH = 1 << ADDR_WIDTH;

  reg [DATA_WIDTH-1:0] mem [0:RAM_DEPTH-1];

  reg                  csb0_reg, csb1_reg;
  reg [ADDR_WIDTH-1:0] addr0_reg, addr1_reg;
  reg [DATA_WIDTH-1:0] din0_reg;

  always @(posedge clk0) begin
    csb0_reg  <= csb0;
    addr0_reg <= addr0;
    din0_reg  <= din0;
  end

  always @(posedge clk1) begin
    csb1_reg  <= csb1;
    addr1_reg <= addr1;
  end

  always @(negedge clk0)
    if (!csb0_reg)
      mem[addr0_reg] <= din0_reg;

  always @(negedge clk1)
    if (!csb1_reg)
      dout1 <= mem[addr1_reg];

endmodule
