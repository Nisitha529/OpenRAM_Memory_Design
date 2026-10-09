// RISC-V core with a two-level cache hierarchy
//
//            imem_addr / instrf              dreq_* / readdatam
//   core  ───────────────────►  L1I      ───────────────────►  L1D
//                               (512 B, direct, read-only)     (512 B, direct, write-back)
//                                 │ main port (128-bit lines)    │
//                                 └──────────► l2_arbiter ◄──────┘
//                                                   │
//                                                  L2  (2 KB, 2-way LRU, write-back)
//                                                   │ main port (256-bit lines)
//                                                   ▼
//                                             off-chip memory (mem_*)
//
// The caches answer one cycle after a request (their SRAMs are synchronous) and
// raise "stall" on a miss. The core is frozen whenever an access it needs this
// cycle has not been answered yet.
//
// Addresses: the core uses byte addresses; the caches use 32-bit word addresses
// (addr[17:2]), so 256 KB of memory is reachable.
module riscv_soc (
  input          clk,
  input          rst,

  // Write dirty lines back (pulse; wait for l1d_busy / l2_busy to drop).
  // The busy flags are registered: they follow the cache stall one cycle late.
  input          l1d_flush,
  input          l2_flush,
  output reg     l1d_busy,
  output reg     l2_busy,

  // Off-chip memory (one 256-bit L2 line per address)
  output         mem_csb,
  output         mem_web,
  output [12:0]  mem_addr,
  output [255:0] mem_din,
  input  [255:0] mem_dout,
  input          mem_stall
);

  // ---------------- reset synchronizer ----------------
  // rst may arrive at any time; inside, it is asserted at once but released
  // only on a clock edge, two flops later. Every block uses rst_sync, so the
  // release is an ordinary timed path instead of an unconstrained input.
  reg [1:0] rst_sr;
  always @(posedge clk or posedge rst)
    if (rst) rst_sr <= 2'b11;
    else     rst_sr <= {rst_sr[0], 1'b0};
  wire rst_sync = rst_sr[1];

  // ---------------- core ----------------
  wire [31:0] pcf, instrf, readdatam, imem_addr;
  wire [31:0] dreq_addr, dreq_wdata;
  wire [31:0] aluresultm, writedatam;
  wire        dreq_we, dreq_re, memwritem, memreadm;
  wire        freeze;

  riscv_module core (
    .clk         (clk),
    .reset       (rst_sync),
    .pcf         (pcf),
    .instrf      (instrf),
    .memwritem   (memwritem),
    .aluresultm  (aluresultm),
    .writedatam  (writedatam),
    .readdatam   (readdatam),
    .freeze      (freeze),
    .imem_addr   (imem_addr),
    .memreadm    (memreadm),
    .dreq_we     (dreq_we),
    .dreq_re     (dreq_re),
    .dreq_addr   (dreq_addr),
    .dreq_wdata  (dreq_wdata)
  );

  // ---------------- L1 instruction cache ----------------
  wire        i_csb = rst_sync;          // always fetching
  wire        i_stall;
  wire        i_main_csb, i_main_stall;
  wire [13:0] i_main_addr;
  wire [127:0] i_main_dout;

  l1i u_l1i (
    .clk        (clk),
    .rst        (rst_sync),
    .csb        (i_csb),
    .addr       (imem_addr[17:2]),
    .dout       (instrf),
    .stall      (i_stall),
    .main_csb   (i_main_csb),
    .main_addr  (i_main_addr),
    .main_dout  (i_main_dout),
    .main_stall (i_main_stall)
  );

  // ---------------- L1 data cache ----------------
  wire        d_csb = ~(dreq_we | dreq_re);
  wire        d_stall;
  wire        d_main_csb, d_main_web, d_main_stall;
  wire [13:0] d_main_addr;
  wire [127:0] d_main_din, d_main_dout;

  l1d u_l1d (
    .clk        (clk),
    .rst        (rst_sync),
    .flush      (l1d_flush),
    .csb        (d_csb),
    .web        (~dreq_we),
    .addr       (dreq_addr[17:2]),
    .din        (dreq_wdata),
    .dout       (readdatam),
    .stall      (d_stall),
    .main_csb   (d_main_csb),
    .main_web   (d_main_web),
    .main_addr  (d_main_addr),
    .main_din   (d_main_din),
    .main_dout  (d_main_dout),
    .main_stall (d_main_stall)
  );

  // ---------------- freeze logic ----------------
  // A request is accepted at a clock edge when csb = 0 and the cache is not
  // stalling. Its answer is valid in the first following cycle with stall = 0.
  reg i_pend, d_pend;
  always @(posedge clk) begin
    if (rst_sync) begin
      i_pend <= 1'b0;
      d_pend <= 1'b0;
    end else begin
      if (!i_stall) i_pend <= ~i_csb;
      if (!d_stall) d_pend <= ~d_csb;
    end
  end

  wire i_valid = i_pend & ~i_stall;
  wire d_valid = d_pend & ~d_stall;

  // Fetch needs an instruction every cycle; the memory stage only needs data
  // when it holds a load or store.
  assign freeze = ~i_valid | ((memreadm | memwritem) & ~d_valid);

  // ---------------- L2 (shared by L1I and L1D) ----------------
  wire        l2_csb, l2_web, l2_stall;
  wire [13:0] l2_addr;
  wire [127:0] l2_din, l2_dout;

  l2_arbiter #(.ADDR_WIDTH(14), .LINE_WIDTH(128)) u_arb (
    .clk      (clk),
    .rst      (rst_sync),
    .i_csb    (i_main_csb),
    .i_addr   (i_main_addr),
    .i_dout   (i_main_dout),
    .i_stall  (i_main_stall),
    .d_csb    (d_main_csb),
    .d_web    (d_main_web),
    .d_addr   (d_main_addr),
    .d_din    (d_main_din),
    .d_dout   (d_main_dout),
    .d_stall  (d_main_stall),
    .l2_csb   (l2_csb),
    .l2_web   (l2_web),
    .l2_addr  (l2_addr),
    .l2_din   (l2_din),
    .l2_dout  (l2_dout),
    .l2_stall (l2_stall)
  );

  l2 u_l2 (
    .clk        (clk),
    .rst        (rst_sync),
    .flush      (l2_flush),
    .csb        (l2_csb),
    .web        (l2_web),
    .addr       (l2_addr),
    .din        (l2_din),
    .dout       (l2_dout),
    .stall      (l2_stall),
    .main_csb   (mem_csb),
    .main_web   (mem_web),
    .main_addr  (mem_addr),
    .main_din   (mem_din),
    .main_dout  (mem_dout),
    .main_stall (mem_stall)
  );

  // Status outputs come straight from flip-flops: driving the stall logic
  // directly out of the chip failed timing at the slow corner.
  always @(posedge clk) begin
    if (rst_sync) begin
      l1d_busy <= 1'b0;
      l2_busy  <= 1'b0;
    end else begin
      l1d_busy <= d_stall;
      l2_busy  <= l2_stall;
    end
  end

endmodule
