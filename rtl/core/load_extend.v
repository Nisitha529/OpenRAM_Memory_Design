// Load extraction (writeback stage) for lb / lh / lw / lbu / lhu.
//
// Memory returns the whole aligned word. Pick the byte or half-word at
// addr[1:0] and sign- or zero-extend it.
//   funct3: 000 lb, 001 lh, 010 lw, 100 lbu, 101 lhu
// Misaligned accesses are not trapped: lh reads the half-word selected by
// addr[1], lw ignores addr[1:0].
module load_extend(
  input      [2:0]  funct3,
  input      [1:0]  addr,       // byte offset in the word
  input      [31:0] rdata,      // aligned word from memory
  output reg [31:0] y
);

  wire [7:0]  b = (addr == 2'd0) ? rdata[7:0]   :
                  (addr == 2'd1) ? rdata[15:8]  :
                  (addr == 2'd2) ? rdata[23:16] : rdata[31:24];
  wire [15:0] h = addr[1] ? rdata[31:16] : rdata[15:0];

  always @(*) begin
    case (funct3)
      3'b000:  y = {{24{b[7]}},  b};                  // lb
      3'b001:  y = {{16{h[15]}}, h};                  // lh
      3'b100:  y = {24'b0, b};                        // lbu
      3'b101:  y = {16'b0, h};                        // lhu
      default: y = rdata;                             // lw
    endcase
  end

endmodule
