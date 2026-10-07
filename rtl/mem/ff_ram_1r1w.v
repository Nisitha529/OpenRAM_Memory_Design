// Flip-flop RAM with one write port and one read port, cycle-compatible with
// the OpenRAM 1r1w SRAM models used by the OpenCache caches:
//   * inputs are captured at the rising clock edge
//   * the write happens, and read data appears on dout1, at the following
//     falling edge (so dout1 is valid before the next rising edge)
// A write and a read of the same address in the same cycle return the old data,
// which OpenCache handles itself (data_hazard = True).
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
  output reg [DATA_WIDTH-1:0]  dout1
);

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
