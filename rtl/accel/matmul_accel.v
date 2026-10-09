// Matrix-multiply accelerator: C = A x B on an N x N systolic array.
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
// Cycles per tile: 1 (clear) + K + 2N - 2 (feed) + N*N + 1 (copy results).
//
// Register bus: a request (sel, we, addr, wdata) is taken at a rising edge;
// read data appears on rdata in the next cycle (same timing as the caches).
//   0x0000  CTRL    write bit 0 = 1: start (ignored while busy)
//   0x0004  STATUS  bit 0 busy, bit 1 done (cleared by the next start)
//   0x0008  DIMS    [4:0] M, [12:8] K, [20:16] P
//   0x0400  A[i][k] at 0x0400 + 4*(i*16 + k), bits [15:0]   (write-only)
//   0x0800  B[k][j] at 0x0800 + 4*(k*16 + j), bits [15:0]   (write-only)
//   0x1000  C[i][j] at 0x1000 + 8*(i*16 + j): low 32 bits, then +4: bits 39:32
//           sign-extended                                  (read-only)
// A, B and DIMS are only written while the block is idle. The address map is
// laid out for MAX_DIM = 16 (256-entry buffers).
module matmul_accel #(
  parameter N          = 8,    // physical array size (power of 2)
  parameter MAX_DIM    = 16,   // largest M, K, P (power of 2, multiple of N)
  parameter DATA_WIDTH = 16,
  parameter ACC_WIDTH  = 40
) (
  input                 clk,
  input                 rst_n,

  input                 sel,
  input                 we,
  input      [12:0]     addr,
  input      [31:0]     wdata,
  output reg [31:0]     rdata,

  output                busy,
  output reg            done
);

  localparam IDX_W  = $clog2(MAX_DIM);                 // index into a matrix row/column
  localparam DIM_W  = IDX_W + 1;                       // holds 1 .. MAX_DIM
  localparam LOGN   = $clog2(N);
  localparam TILE_W = (IDX_W > LOGN) ? IDX_W - LOGN : 1;
  localparam STEP_W = $clog2(MAX_DIM + 2*N) + 1;
  localparam ELEMS  = MAX_DIM * MAX_DIM;

  // ---------------- buffers and configuration ----------------
  reg [DATA_WIDTH-1:0] abuf [0:ELEMS-1];   // A[i][k] at {i, k}
  reg [DATA_WIDTH-1:0] bbuf [0:ELEMS-1];   // B[k][j] at {k, j}
  reg [ACC_WIDTH-1:0]  cbuf [0:ELEMS-1];   // C[i][j] at {i, j}
  reg [DIM_W-1:0]      dim_m, dim_k, dim_p;

  // ---------------- control state ----------------
  localparam S_IDLE = 2'd0, S_CLEAR = 2'd1, S_FEED = 2'd2, S_DRAIN = 2'd3;
  reg [1:0]          state;
  reg [TILE_W-1:0]   ti, tj;       // current output tile
  reg [STEP_W-1:0]   t;            // feed step
  reg [2*LOGN:0]     dr;           // result being requested from the array
  reg [2*LOGN-1:0]   dr_q;         // result now on rd_data
  reg                drain_v;      // rd_data holds a result to store

  wire [DIM_W-1:0]   m_minus1 = dim_m - 1'b1;
  wire [DIM_W-1:0]   p_minus1 = dim_p - 1'b1;
  wire [TILE_W-1:0]  last_ti  = (IDX_W > LOGN) ? m_minus1[LOGN +: TILE_W] : {TILE_W{1'b0}};
  wire [TILE_W-1:0]  last_tj  = (IDX_W > LOGN) ? p_minus1[LOGN +: TILE_W] : {TILE_W{1'b0}};
  wire [STEP_W-1:0]  steps   = dim_k + 2*N - 2;

  assign busy = (state != S_IDLE);

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
  // top of wdata (DIMS ends at bit 20), and the low bits of M-1 / P-1.
  wire               unused_bits = &{1'b0, addr[1:0], wdata[31:21], m_minus1, p_minus1};

  // ---------------- sequencer ----------------
  always @(posedge clk) begin
    if (!rst_n) begin
      state <= S_IDLE;
      done  <= 1'b0;
      ti    <= 0;
      tj    <= 0;
      t     <= 0;
      dr    <= 0;
    end else begin
      case (state)
        S_IDLE:
          if (start) begin
            done  <= 1'b0;
            ti    <= 0;
            tj    <= 0;
            state <= S_CLEAR;
          end
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
                state <= S_IDLE;
                done  <= 1'b1;
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

  // ---------------- bus writes (A, B, DIMS only while idle) ----------------
  always @(posedge clk) begin
    if (!rst_n) begin
      dim_m <= MAX_DIM;
      dim_k <= MAX_DIM;
      dim_p <= MAX_DIM;
    end else if (wr && !busy && addr[12:2] == 11'd2) begin
      dim_m <= wdata[0  +: DIM_W];
      dim_k <= wdata[8  +: DIM_W];
      dim_p <= wdata[16 +: DIM_W];
    end
  end

  always @(posedge clk)
    if (wr && !busy) begin
      if (in_a) abuf[ab_idx] <= wdata[DATA_WIDTH-1:0];
      if (in_b) bbuf[ab_idx] <= wdata[DATA_WIDTH-1:0];
    end

  // ---------------- bus reads ----------------
  wire [ACC_WIDTH-1:0] c_word = cbuf[c_idx];

  always @(posedge clk) begin
    if (!rst_n)
      rdata <= 32'd0;
    else if (sel && !we) begin
      if (in_c)
        rdata <= addr[2] ? {{(64-ACC_WIDTH){c_word[ACC_WIDTH-1]}}, c_word[ACC_WIDTH-1:32]}
                         : c_word[31:0];
      else
        case (addr[12:2])
          11'd1:   rdata <= {30'd0, done, busy};
          11'd2:   rdata <= ({{(32-DIM_W){1'b0}}, dim_p} << 16) |
                            ({{(32-DIM_W){1'b0}}, dim_k} << 8)  |
                             {{(32-DIM_W){1'b0}}, dim_m};
          default: rdata <= 32'd0;
        endcase
    end
  end

endmodule
