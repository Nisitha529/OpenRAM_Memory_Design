// Matrix-multiply accelerator: C = A x B on an N x N systolic array, with a
// DMA engine that loads A and B from memory and stores C back.
//
// A is M x K, B is K x P, C is M x P, with 1 <= M, K, P <= MAX_DIM. The array
// is smaller than the matrices, so the product is computed in output tiles of
// N x N: for every tile (ti, tj) the block clears the array, streams the
// matching rows of A and columns of B through it, then copies the N x N
// results into the C buffer.
//
// Feeding: the A and B buffers are flip-flop arrays. In feed step t, array row
// r gets A[ti*N + r][t - r] and array column c gets B[t - c][tj*N + c] (zero
// outside the matrices). Every row and column reads its own small slice of the
// buffers, so all 2N operands are supplied every cycle, and the diagonal skew
// the systolic array needs comes from the "- r" / "- c" in the index.
//
// Two ways to run a product:
//   CTRL = 1  compute only: the CPU has written A and B through the register
//             bus, and reads C through it afterwards
//   CTRL = 3  full DMA job: load A and B from memory, compute, store C to memory
//
// Memory layout for DMA (byte addresses, 16-byte aligned bases):
//   A: M*K 32-bit words, row-major, value in bits [15:0]   (int32 A[M][K])
//   B: K*P 32-bit words, row-major                          (int32 B[K][P])
//   C: M*P 64-bit values, row-major, low word first          (int64 C[M][P])
//      written in whole 16-byte lines: when M*P is odd the last 8 bytes after C
//      are overwritten with zero, so reserve C rounded up to 16 bytes.
// The DMA port reads and writes the memory below the L1 caches, so software
// must write dirty L1D lines back before a job and drop stale L1D copies of C
// afterwards (riscv_soc SYSCTRL flush / invalidate).
//
// Cycles per tile: 1 (clear) + K + 2N - 2 (feed) + N*N + 1 (copy results).
//
// Register bus: a request (sel, we, addr, wdata) is taken at a rising edge;
// read data appears on rdata in the next cycle (same timing as the caches).
//   0x0000  CTRL    write: bit 0 start, bit 1 DMA job   (ignored while busy)
//   0x0004  STATUS  bit 0 busy, bit 1 done (cleared by the next start)
//   0x0008  DIMS    [4:0] M, [12:8] K, [20:16] P
//   0x000C  BASE_A  byte address of A in memory (DMA)
//   0x0010  BASE_B  byte address of B in memory (DMA)
//   0x0014  BASE_C  byte address of C in memory (DMA)
//   0x0400  A[i][k] at 0x0400 + 4*(i*16 + k), bits [15:0]   (write-only)
//   0x0800  B[k][j] at 0x0800 + 4*(k*16 + j), bits [15:0]   (write-only)
//   0x1000  C[i][j] at 0x1000 + 8*(i*16 + j): low 32 bits, then +4: bits 39:32
//           sign-extended                                  (read-only)
// Configuration and buffers are only written while the block is idle. The
// register map is laid out for MAX_DIM = 16 (256-entry buffers).
//
// DMA port: the OpenCache "main" protocol, one 128-bit line (4 words, word 0 in
// bits 31:0) per request. A request (m_csb = 0) is accepted at a rising edge
// where m_stall is low; its response is the first later cycle with m_stall low.
module matmul_accel #(
  parameter N           = 8,    // physical array size (power of 2)
  parameter MAX_DIM     = 16,   // largest M, K, P (power of 2, multiple of N)
  parameter DATA_WIDTH  = 16,
  parameter ACC_WIDTH   = 40,
  parameter LINE_ADDR_W = 14    // memory line address (16-byte lines)
) (
  input                        clk,
  input                        rst_n,

  // register bus
  input                        sel,
  input                        we,
  input      [12:0]            addr,
  input      [31:0]            wdata,
  output reg [31:0]            rdata,

  output                       busy,
  output reg                   done,

  // DMA port
  output                       m_csb,
  output                       m_web,
  output     [LINE_ADDR_W-1:0] m_addr,
  output     [127:0]           m_din,
  input      [127:0]           m_dout,
  input                        m_stall
);

  localparam IDX_W  = $clog2(MAX_DIM);                 // index into a matrix row/column
  localparam DIM_W  = IDX_W + 1;                       // holds 1 .. MAX_DIM
  localparam CNT_W  = 2*IDX_W + 1;                     // holds 0 .. MAX_DIM^2
  localparam LOGN   = $clog2(N);
  localparam TILE_W = (IDX_W > LOGN) ? IDX_W - LOGN : 1;
  localparam STEP_W = $clog2(MAX_DIM + 2*N) + 1;
  localparam ELEMS  = MAX_DIM * MAX_DIM;

  // ---------------- buffers and configuration ----------------
  reg [DATA_WIDTH-1:0]  abuf [0:ELEMS-1];   // A[i][k] at {i, k}
  reg [DATA_WIDTH-1:0]  bbuf [0:ELEMS-1];   // B[k][j] at {k, j}
  reg [ACC_WIDTH-1:0]   cbuf [0:ELEMS-1];   // C[i][j] at {i, j}
  reg [DIM_W-1:0]       dim_m, dim_k, dim_p;
  reg [LINE_ADDR_W-1:0] base_a, base_b, base_c;   // line addresses

  // ---------------- control state ----------------
  localparam S_IDLE  = 3'd0, S_LOAD  = 3'd1, S_CLEAR = 3'd2,
             S_FEED  = 3'd3, S_DRAIN = 3'd4, S_STORE = 3'd5;
  reg [2:0]          state;
  reg                dma_job;      // current job loads and stores through DMA
  reg [TILE_W-1:0]   ti, tj;       // current output tile
  reg [STEP_W-1:0]   t;            // feed step
  reg [2*LOGN:0]     dr;           // result being requested from the array
  reg [2*LOGN-1:0]   dr_q;         // result now on rd_data
  reg                drain_v;      // rd_data holds a result to store

  wire [DIM_W-1:0]   m_minus1 = dim_m - 1'b1;
  wire [DIM_W-1:0]   p_minus1 = dim_p - 1'b1;
  wire [TILE_W-1:0]  last_ti  = (IDX_W > LOGN) ? m_minus1[LOGN +: TILE_W] : {TILE_W{1'b0}};
  wire [TILE_W-1:0]  last_tj  = (IDX_W > LOGN) ? p_minus1[LOGN +: TILE_W] : {TILE_W{1'b0}};
  wire [STEP_W-1:0]  steps    = dim_k + 2*N - 2;

  assign busy = (state != S_IDLE);

  // ---------------- DMA state ----------------
  // Load:  L_REQ -> L_WAIT -> L_UNPACK (4 words, one per cycle) -> next line
  // Store: C_RD0 -> C_RD1 (two C elements into one line) -> C_REQ -> C_WAIT
  localparam L_REQ = 2'd0, L_WAIT = 2'd1, L_UNPACK = 2'd2;
  localparam C_RD0 = 2'd0, C_RD1  = 2'd1, C_REQ    = 2'd2, C_WAIT = 2'd3;
  reg [1:0]             ph;        // phase within S_LOAD / S_STORE
  reg                   ld_b;      // loading B (else A)
  reg [1:0]             ld_w;      // word of the line being unpacked
  reg [LINE_ADDR_W-1:0] mline;     // memory line being read / written
  reg [127:0]           line_q;
  reg [CNT_W-1:0]       left;      // elements still to load / store
  reg [IDX_W-1:0]       mi, mj;    // row / column of the element being moved

  wire [2*DIM_W-1:0]    tot_a = dim_m * dim_k;
  wire [2*DIM_W-1:0]    tot_b = dim_k * dim_p;
  wire [2*DIM_W-1:0]    tot_c = dim_m * dim_p;
  // row length of the matrix being moved: A rows have K elements, B and C rows P
  wire [DIM_W-1:0]      row_len  = (state == S_LOAD && !ld_b) ? dim_k : dim_p;
  wire                  row_last = ({1'b0, mj} == row_len - 1'b1);

  assign m_csb  = !((state == S_LOAD  && ph == L_REQ) ||
                    (state == S_STORE && ph == C_REQ));
  assign m_web  = !(state == S_STORE);
  assign m_addr = mline;
  assign m_din  = line_q;

  // ---------------- feeding: one slice of A / B per array row / column ----------------
  wire [N*DATA_WIDTH-1:0] west_in, north_in;

  genvar g;
  generate
    for (g = 0; g < N; g = g + 1) begin : g_feed
      wire [STEP_W-1:0] k      = t - g;
      wire              t_ok;                       // t >= g (always true for g = 0)
      if (g == 0) begin : g_t0
        assign t_ok = 1'b1;
      end else begin : g_tn
        assign t_ok = (t >= g);
      end
      wire              k_ok   = t_ok && (k < {{(STEP_W-DIM_W){1'b0}}, dim_k});
      wire [IDX_W:0]    row    = ti * N + g;
      wire [IDX_W:0]    col    = tj * N + g;
      wire              row_ok = row < dim_m;
      wire              col_ok = col < dim_p;
      assign west_in [g*DATA_WIDTH +: DATA_WIDTH] =
        (k_ok && row_ok) ? abuf[{row[IDX_W-1:0], k[IDX_W-1:0]}] : {DATA_WIDTH{1'b0}};
      assign north_in[g*DATA_WIDTH +: DATA_WIDTH] =
        (k_ok && col_ok) ? bbuf[{k[IDX_W-1:0], col[IDX_W-1:0]}] : {DATA_WIDTH{1'b0}};
    end
  endgenerate

  // ---------------- the array ----------------
  wire [ACC_WIDTH-1:0] rd_data;

  systolic_array #(.N(N), .DATA_WIDTH(DATA_WIDTH), .ACC_WIDTH(ACC_WIDTH)) u_array (
    .clk      (clk),
    .rst_n    (rst_n),
    .clear    (state == S_CLEAR),
    .en       (state == S_FEED),
    .west_in  (west_in),
    .north_in (north_in),
    .rd_row   (dr[2*LOGN-1:LOGN]),
    .rd_col   (dr[LOGN-1:0]),
    .rd_data  (rd_data)
  );

  // ---------------- register bus decode ----------------
  wire               wr     = sel && we;
  wire               in_a   = (addr[12:10] == 3'b001);
  wire               in_b   = (addr[12:10] == 3'b010);
  wire               in_c   = (addr[12:11] == 2'b10);
  wire [2*IDX_W-1:0] ab_idx = addr[2 +: 2*IDX_W];
  wire [2*IDX_W-1:0] c_idx  = addr[3 +: 2*IDX_W];
  wire               start  = wr && !busy && (addr[12:2] == 11'd0) && wdata[0];

  // Bits that are intentionally not used: byte offset of the word bus, the
  // top of wdata, the low bits of M-1 / P-1, and the top of the products.
  wire               unused_bits = &{1'b0, addr[1:0], wdata[31:21], m_minus1, p_minus1,
                                     tot_a, tot_b, tot_c};

  // ---------------- C buffer read (bus, or DMA while storing) ----------------
  wire [2*IDX_W-1:0]   c_rd_idx = (state == S_STORE) ? {mi, mj} : c_idx;
  wire [ACC_WIDTH-1:0] c_word   = cbuf[c_rd_idx];
  wire [63:0]          c_ext    = {{(64-ACC_WIDTH){c_word[ACC_WIDTH-1]}}, c_word};

  // ---------------- sequencer ----------------
  always @(posedge clk) begin
    if (!rst_n) begin
      state   <= S_IDLE;
      done    <= 1'b0;
      dma_job <= 1'b0;
      ti      <= 0;
      tj      <= 0;
      t       <= 0;
      dr      <= 0;
      ph      <= 0;
      ld_b    <= 1'b0;
      ld_w    <= 0;
      mline   <= 0;
      line_q  <= 128'd0;
      left    <= 0;
      mi      <= 0;
      mj      <= 0;
    end else begin
      case (state)
        S_IDLE:
          if (start) begin
            done    <= 1'b0;
            dma_job <= wdata[1];
            ti      <= 0;
            tj      <= 0;
            if (wdata[1]) begin
              state <= S_LOAD;
              ph    <= L_REQ;
              ld_b  <= 1'b0;
              mline <= base_a;
              left  <= tot_a[CNT_W-1:0];
              mi    <= 0;
              mj    <= 0;
            end else
              state <= S_CLEAR;
          end

        // ---- DMA: read A, then B, line by line ----
        S_LOAD:
          case (ph)
            L_REQ:
              if (!m_stall) ph <= L_WAIT;
            L_WAIT:
              if (!m_stall) begin
                line_q <= m_dout;
                ld_w   <= 0;
                ph     <= L_UNPACK;
              end
            default: begin  // L_UNPACK: one word per cycle (written in the buffer block)
              left <= left - 1'b1;
              if (row_last) begin
                mj <= 0;
                mi <= mi + 1'b1;
              end else
                mj <= mj + 1'b1;
              ld_w <= ld_w + 1'b1;
              if (left == 1) begin            // matrix complete
                mi <= 0;
                mj <= 0;
                ph <= L_REQ;
                if (!ld_b) begin
                  ld_b  <= 1'b1;
                  mline <= base_b;
                  left  <= tot_b[CNT_W-1:0];
                end else
                  state <= S_CLEAR;
              end else if (ld_w == 2'd3) begin  // line used up
                mline <= mline + 1'b1;
                ph    <= L_REQ;
              end
            end
          endcase

        // ---- compute, tile by tile ----
        S_CLEAR: begin
          t     <= 0;
          state <= S_FEED;
        end
        S_FEED: begin
          t <= t + 1'b1;
          if (t == steps - 1'b1) begin
            dr    <= 0;
            state <= S_DRAIN;
          end
        end
        S_DRAIN: begin
          if (dr != N*N)
            dr <= dr + 1'b1;
          else begin
            // the last result is stored in this cycle: go to the next tile
            if (tj == last_tj) begin
              tj <= 0;
              if (ti == last_ti) begin
                if (dma_job) begin
                  state <= S_STORE;
                  ph    <= C_RD0;
                  mline <= base_c;
                  left  <= tot_c[CNT_W-1:0];
                  mi    <= 0;
                  mj    <= 0;
                end else begin
                  state <= S_IDLE;
                  done  <= 1'b1;
                end
              end else begin
                ti    <= ti + 1'b1;
                state <= S_CLEAR;
              end
            end else begin
              tj    <= tj + 1'b1;
              state <= S_CLEAR;
            end
          end
        end

        // ---- DMA: write C, two 64-bit elements per line ----
        S_STORE:
          case (ph)
            C_RD0, C_RD1: begin
              if (left != 0) begin
                if (ph == C_RD0) line_q[63:0]   <= c_ext;
                else             line_q[127:64] <= c_ext;
                left <= left - 1'b1;
                if (row_last) begin
                  mj <= 0;
                  mi <= mi + 1'b1;
                end else
                  mj <= mj + 1'b1;
              end else
                line_q[127:64] <= 64'd0;      // odd element count: pad the last line
              ph <= (ph == C_RD0) ? C_RD1 : C_REQ;
            end
            C_REQ:
              if (!m_stall) ph <= C_WAIT;
            default:  // C_WAIT
              if (!m_stall) begin
                if (left == 0) begin
                  state <= S_IDLE;
                  done  <= 1'b1;
                end else begin
                  mline <= mline + 1'b1;
                  ph    <= C_RD0;
                end
              end
          endcase

        default: state <= S_IDLE;
      endcase
    end
  end

  // ---------------- copy array results into the C buffer ----------------
  wire [IDX_W:0] c_row = ti * N + {{(IDX_W+1-LOGN){1'b0}}, dr_q[2*LOGN-1:LOGN]};
  wire [IDX_W:0] c_col = tj * N + {{(IDX_W+1-LOGN){1'b0}}, dr_q[LOGN-1:0]};

  always @(posedge clk) begin
    if (!rst_n) begin
      drain_v <= 1'b0;
      dr_q    <= 0;
    end else begin
      drain_v <= (state == S_DRAIN) && (dr != N*N);
      dr_q    <= dr[2*LOGN-1:0];
    end
  end

  always @(posedge clk)
    if (drain_v && c_row < dim_m && c_col < dim_p)
      cbuf[{c_row[IDX_W-1:0], c_col[IDX_W-1:0]}] <= rd_data;

  // ---------------- configuration writes (only while idle) ----------------
  always @(posedge clk) begin
    if (!rst_n) begin
      dim_m  <= MAX_DIM;
      dim_k  <= MAX_DIM;
      dim_p  <= MAX_DIM;
      base_a <= 0;
      base_b <= 0;
      base_c <= 0;
    end else if (wr && !busy) begin
      case (addr[12:2])
        11'd2: begin
          dim_m <= wdata[0  +: DIM_W];
          dim_k <= wdata[8  +: DIM_W];
          dim_p <= wdata[16 +: DIM_W];
        end
        11'd3: base_a <= wdata[4 +: LINE_ADDR_W];
        11'd4: base_b <= wdata[4 +: LINE_ADDR_W];
        11'd5: base_c <= wdata[4 +: LINE_ADDR_W];
        default: ;
      endcase
    end
  end

  // ---------------- A / B buffer writes: bus while idle, DMA while loading ----------------
  wire                  dma_wr   = (state == S_LOAD) && (ph == L_UNPACK);
  wire [DATA_WIDTH-1:0] dma_word = line_q[{ld_w, 5'd0} +: DATA_WIDTH];

  always @(posedge clk) begin
    if (dma_wr) begin
      if (ld_b) bbuf[{mi, mj}] <= dma_word;
      else      abuf[{mi, mj}] <= dma_word;
    end else if (wr && !busy) begin
      if (in_a) abuf[ab_idx] <= wdata[DATA_WIDTH-1:0];
      if (in_b) bbuf[ab_idx] <= wdata[DATA_WIDTH-1:0];
    end
  end

  // ---------------- bus reads ----------------
  always @(posedge clk) begin
    if (!rst_n)
      rdata <= 32'd0;
    else if (sel && !we) begin
      if (in_c)
        rdata <= addr[2] ? c_ext[63:32] : c_ext[31:0];
      else
        case (addr[12:2])
          11'd1:   rdata <= {30'd0, done, busy};
          11'd2:   rdata <= ({{(32-DIM_W){1'b0}}, dim_p} << 16) |
                            ({{(32-DIM_W){1'b0}}, dim_k} << 8)  |
                             {{(32-DIM_W){1'b0}}, dim_m};
          11'd3:   rdata <= {{(28-LINE_ADDR_W){1'b0}}, base_a, 4'd0};
          11'd4:   rdata <= {{(28-LINE_ADDR_W){1'b0}}, base_b, 4'd0};
          11'd5:   rdata <= {{(28-LINE_ADDR_W){1'b0}}, base_c, 4'd0};
          default: rdata <= 32'd0;
        endcase
    end
  end

endmodule
