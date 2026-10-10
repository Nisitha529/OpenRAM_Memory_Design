// RISC-V core with a two-level cache hierarchy and a matrix-multiply accelerator
//
//            imem_addr / instrf              dreq_* / readdatam
//   core  ───────────────────►  L1I      ───────────────────►  L1D
//                               (512 B, direct, read-only)     (512 B, direct, write-back)
//                                 │ main port (128-bit lines)    │
//                                 │                              │       ┌──────────────┐
//                                 │                 core MMIO ───┼──────►│ matmul_accel │
//                                 │                              │       └──────┬───────┘
//                                 └──────────► l2_arbiter ◄──────┘◄────── DMA ──┘
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
// Address map (byte addresses):
//   0x0000_0000 - 0x0003_FFFF  memory through the caches (addr[17:2]: 256 KB)
//   0x4000_0000 - 0x4000_1FFF  matmul_accel registers and buffers (not cached)
//   0x4001_0000                SYSCTRL  write bit 0: flush L1D (write dirty lines
//                                       back), bit 1: invalidate L1D (drop all
//                                       lines); read bit 0: busy
//   0x4001_0004                CYCLES   free-running cycle counter (read)
// Memory-mapped accesses never stall: the device answers in the next cycle.
//
// The accelerator's DMA reads and writes at the L2, below the L1D. Software
// keeps them coherent: flush L1D before a DMA job (A and B may still be dirty
// in L1D), invalidate L1D after it (L1D may hold stale copies of C).
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

  // ---------------- address decode ----------------
  // dreq_* is the access entering the memory stage at the next edge;
  // aluresultm is the address of the access in the memory stage now.
  wire dreq_mem    = dreq_we | dreq_re;
  wire dreq_mmio   = (dreq_addr[31:28] == 4'h4);
  wire mem_is_mmio = (aluresultm[31:28] == 4'h4);

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
  wire        maint_block;               // cache maintenance in progress (below)
  wire        maint_flush, maint_inv;
  wire        d_csb = ~(dreq_mem & ~dreq_mmio) | maint_block;
  wire        d_stall;
  wire        d_main_csb, d_main_web, d_main_stall;
  wire [13:0] d_main_addr;
  wire [127:0] d_main_din, d_main_dout;
  wire [31:0] d_dout;

  l1d u_l1d (
    .clk        (clk),
    .rst        (rst_sync | maint_inv),  // reset clears every tag: invalidate
    .flush      (l1d_flush | maint_flush),
    .csb        (d_csb),
    .web        (~dreq_we),
    .addr       (dreq_addr[17:2]),
    .din        (dreq_wdata),
    .dout       (d_dout),
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

  // Fetch needs an instruction every cycle; the memory stage only needs the
  // L1D when it holds a load or store to cached memory (MMIO answers at once).
  assign freeze = ~i_valid | ((memreadm | memwritem) & ~mem_is_mmio & ~d_valid);

  // ---------------- memory-mapped devices ----------------
  // A device takes the access when it enters the memory stage (no freeze), so
  // a frozen pipeline does not repeat it; read data is held until replaced.
  wire        mmio_req = dreq_mem & dreq_mmio & ~freeze;
  wire        acc_sel  = mmio_req & ~dreq_addr[16];
  wire        sys_sel  = mmio_req &  dreq_addr[16];
  wire [31:0] acc_rdata;
  reg  [31:0] sys_rdata;
  reg         rd_from_sys;

  always @(posedge clk) begin
    if (rst_sync)
      rd_from_sys <= 1'b0;
    else if (mmio_req && !dreq_we)
      rd_from_sys <= dreq_addr[16];
  end

  assign readdatam = mem_is_mmio ? (rd_from_sys ? sys_rdata : acc_rdata) : d_dout;

  // ---------------- SYSCTRL: cycle counter and L1D maintenance ----------------
  localparam M_IDLE = 3'd0, M_DRAIN = 3'd1, M_FLUSH = 3'd2, M_FWAIT = 3'd3,
             M_INV  = 3'd4, M_IWAIT = 3'd5;
  reg [2:0]  mstate;
  reg        m_do_flush, m_do_inv;
  reg [1:0]  m_settle;              // cycles before trusting d_stall again
  reg [31:0] cycles;

  assign maint_block = (mstate != M_IDLE);
  assign maint_flush = (mstate == M_FLUSH);
  assign maint_inv   = (mstate == M_INV);

  always @(posedge clk) begin
    if (rst_sync) begin
      mstate     <= M_IDLE;
      m_do_flush <= 1'b0;
      m_do_inv   <= 1'b0;
      m_settle   <= 2'd0;
      cycles     <= 32'd0;
      sys_rdata  <= 32'd0;
    end else begin
      cycles <= cycles + 1'b1;

      if (sys_sel && !dreq_we)
        sys_rdata <= dreq_addr[2] ? cycles : {31'd0, maint_block};

      case (mstate)
        M_IDLE:
          if (sys_sel && dreq_we && !dreq_addr[2] && (dreq_wdata[0] || dreq_wdata[1])) begin
            m_do_flush <= dreq_wdata[0];
            m_do_inv   <= dreq_wdata[1];
            mstate     <= M_DRAIN;   // from now on no new L1D requests
          end
        M_DRAIN:                     // let an access already in the L1D finish
          if (!d_stall && !d_pend)
            mstate <= m_do_flush ? M_FLUSH : M_INV;
        M_FLUSH: begin               // flush pulse
          m_settle <= 2'd2;
          mstate   <= M_FWAIT;
        end
        M_FWAIT:
          if (m_settle != 0)
            m_settle <= m_settle - 1'b1;
          else if (!d_stall)
            mstate <= m_do_inv ? M_INV : M_IDLE;
        M_INV: begin                 // reset pulse to the L1D
          m_settle <= 2'd2;
          mstate   <= M_IWAIT;
        end
        M_IWAIT:
          if (m_settle != 0)
            m_settle <= m_settle - 1'b1;
          else if (!d_stall)
            mstate <= M_IDLE;
        default: mstate <= M_IDLE;
      endcase
    end
  end

  // ---------------- matrix-multiply accelerator ----------------
  wire         x_csb, x_web, x_stall;
  wire [13:0]  x_addr;
  wire [127:0] x_din, x_dout;
  wire         acc_busy, acc_done;

  matmul_accel #(.N(8), .MAX_DIM(16), .DATA_WIDTH(16), .ACC_WIDTH(40), .LINE_ADDR_W(14)) u_accel (
    .clk     (clk),
    .rst_n   (~rst_sync),
    .sel     (acc_sel),
    .we      (dreq_we),
    .addr    (dreq_addr[12:0]),
    .wdata   (dreq_wdata),
    .rdata   (acc_rdata),
    .busy    (acc_busy),
    .done    (acc_done),
    .m_csb   (x_csb),
    .m_web   (x_web),
    .m_addr  (x_addr),
    .m_din   (x_din),
    .m_dout  (x_dout),
    .m_stall (x_stall)
  );

  // ---------------- L2 (shared by L1I, L1D and the accelerator DMA) ----------------
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
    .x_csb    (x_csb),
    .x_web    (x_web),
    .x_addr   (x_addr),
    .x_din    (x_din),
    .x_dout   (x_dout),
    .x_stall  (x_stall),
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
