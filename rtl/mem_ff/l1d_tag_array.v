// l1d_tag_array: 32 x 11 bits, flip-flop version for the sky130 chip build.
// Used by: L1D tags (9-bit tag + valid + dirty).
// Same ports and cycle behaviour as the OpenRAM macro it replaces
// (OpenRAM's sky130 build of this array had DRC/LVS errors).
module l1d_tag_array (
`ifdef USE_POWER_PINS
  inout          vccd1,
  inout          vssd1,
`endif
  input          clk0,
  input          csb0,
  input  [4:0]   addr0,
  input  [10:0] din0,
  input          clk1,
  input          csb1,
  input  [4:0]   addr1,
  output [10:0] dout1
);

  ff_ram_1r1w #(.DATA_WIDTH(11), .ADDR_WIDTH(5)) ram (
`ifdef USE_POWER_PINS
    .vccd1(vccd1), .vssd1(vssd1),
`endif
    .clk0(clk0), .csb0(csb0), .addr0(addr0), .din0(din0),
    .clk1(clk1), .csb1(csb1), .addr1(addr1), .dout1(dout1)
  );

endmodule
