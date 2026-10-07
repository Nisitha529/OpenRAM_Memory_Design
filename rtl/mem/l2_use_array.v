// L2 "use" array (LRU state): 32 entries x 2 bits, one write port + one read port.
//
// OpenCache asks for this as an SRAM macro, but 64 bits is far too small for
// one: the OpenRAM macro is 521 x 582 um (mostly decoders, sense amps and
// control) and its layout had DRC errors. Small arrays like this are normally
// built from flip-flops, so this module replaces the macro in every flow.
module l2_use_array (
`ifdef USE_POWER_PINS
  inout        vccd1,
  inout        vssd1,
`endif
  input        clk0,
  input        csb0,
  input  [4:0] addr0,
  input  [1:0] din0,
  input        clk1,
  input        csb1,
  input  [4:0] addr1,
  output [1:0] dout1
);

  ff_ram_1r1w #(.DATA_WIDTH(2), .ADDR_WIDTH(5)) ram (
`ifdef USE_POWER_PINS
    .vccd1(vccd1), .vssd1(vssd1),
`endif
    .clk0(clk0), .csb0(csb0), .addr0(addr0), .din0(din0),
    .clk1(clk1), .csb1(csb1), .addr1(addr1), .dout1(dout1)
  );

endmodule
