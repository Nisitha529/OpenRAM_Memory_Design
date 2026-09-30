// Arbiter: lets the L1 instruction cache and L1 data cache share one L2 port.
//
// OpenCache "main" protocol (the side of an L1 that faces the next level):
//   * A request is a single-cycle pulse: main_csb = 0 (main_web = 0 for a write).
//     The L1 only raises it while it sees main_stall = 0, and the request is
//     accepted at the next clock edge.
//   * After an accepted request, the first cycle in which main_stall is low is
//     the response cycle: main_dout is valid then.
//
// Rules implemented here:
//   * Data cache has priority over instruction cache when both ask at once.
//   * While a request is outstanding, only its owner watches the real L2 stall;
//     the other L1 sees stall = 1, so it can't mistake the response for its own.
//   * A port's stall never depends on that same port's csb, which keeps the
//     L1 (csb depends on stall) -> arbiter -> L1 path free of combinational loops.
module l2_arbiter #(
  parameter ADDR_WIDTH = 14,
  parameter LINE_WIDTH = 128
) (
  input                       clk,
  input                       rst,

  // L1 instruction cache (read-only)
  input                       i_csb,
  input      [ADDR_WIDTH-1:0] i_addr,
  output     [LINE_WIDTH-1:0] i_dout,
  output                      i_stall,

  // L1 data cache
  input                       d_csb,
  input                       d_web,
  input      [ADDR_WIDTH-1:0] d_addr,
  input      [LINE_WIDTH-1:0] d_din,
  output     [LINE_WIDTH-1:0] d_dout,
  output                      d_stall,

  // L2 cache (CPU side)
  output                      l2_csb,
  output                      l2_web,
  output     [ADDR_WIDTH-1:0] l2_addr,
  output     [LINE_WIDTH-1:0] l2_din,
  input      [LINE_WIDTH-1:0] l2_dout,
  input                       l2_stall
);

  localparam OWN_I = 1'b0, OWN_D = 1'b1;

  reg busy;   // a request has been accepted and its response is not yet delivered
  reg owner;  // which L1 issued it

  // Stall seen by each L1
  assign d_stall = busy ? (owner == OWN_D ? l2_stall : 1'b1) : l2_stall;
  assign i_stall = busy ? (owner == OWN_I ? l2_stall : 1'b1) : (l2_stall | ~d_csb);

  // A request goes through when the L1 asks while seeing no stall
  wire d_go = ~d_csb & ~d_stall;
  wire i_go = ~i_csb & ~i_stall;

  assign l2_csb  = ~(d_go | i_go);
  assign l2_web  = d_go ? d_web  : 1'b1;
  assign l2_addr = d_go ? d_addr : i_addr;
  assign l2_din  = d_din;

  // Data out is broadcast; only the port that sees stall = 0 uses it
  assign i_dout = l2_dout;
  assign d_dout = l2_dout;

  always @(posedge clk) begin
    if (rst) begin
      busy  <= 1'b0;
      owner <= OWN_I;
    end else if (d_go | i_go) begin
      busy  <= 1'b1;
      owner <= d_go ? OWN_D : OWN_I;
    end else if (~l2_stall) begin
      busy  <= 1'b0;
    end
  end

endmodule
