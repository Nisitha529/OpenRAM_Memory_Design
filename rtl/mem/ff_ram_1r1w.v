// Flip-flop RAM with one write port and one read port, a drop-in for the
// OpenRAM 1r1w SRAMs used by the OpenCache caches (same ports, same cycle
// behaviour as seen by the cache):
//   * a request is presented before a rising clock edge and taken at that edge
//   * a write updates the array at that edge
//   * read data for that request is valid during the following cycle
//
// Unlike the OpenRAM model, everything here uses the rising edge only. The
// model writes and drives read data at the *falling* edge, which left the cache
// half a clock period to use the data (tag compare -> stall -> core freeze);
// those half-cycle paths failed timing in the sky130 SoC. Here the read is a
// mux behind the registered address, so data is ready early in the cycle.
//
// Reading and writing the same entry in the same cycle returns the new data.
// OpenCache is generated with data_hazard = True and resolves that case itself.
//
// Used where an OpenRAM macro is not suitable: arrays too small for a macro
// (l2_use_array), and the sky130 chip build (rtl/mem_ff/), where OpenRAM's
// sky130 macros for these sizes had DRC/LVS errors.
module ff_ram_1r1w #(
  parameter DATA_WIDTH = 32,
  parameter ADDR_WIDTH = 5
) (
`ifdef USE_POWER_PINS
  inout                        vccd1,
  inout                        vssd1,
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
  output     [DATA_WIDTH-1:0]  dout1
);

  localparam RAM_DEPTH = 1 << ADDR_WIDTH;

  reg [DATA_WIDTH-1:0] mem [0:RAM_DEPTH-1];
  reg [ADDR_WIDTH-1:0] addr1_reg;

  always @(posedge clk0)
    if (!csb0)
      mem[addr0] <= din0;

  // Only follow a new address when the port is selected; otherwise keep
  // showing the last word read (the OpenRAM model leaves dout undefined then).
  always @(posedge clk1)
    if (!csb1)
      addr1_reg <= addr1;

  assign dout1 = mem[addr1_reg];

endmodule
