// Store alignment (execute stage) for sb / sh / sw.
//
// The store data is copied into every byte lane it could go to, and the byte
// mask picks the lanes the store really writes. Copying instead of shifting
// keeps the data independent of the address; only the 4-bit mask uses it.
//   size (funct3[1:0] of the store): 00 sb, 01 sh, 10 sw
// Misaligned accesses are not trapped: sh writes the half-word selected by
// addr[1], sw ignores addr[1:0].
module store_align(
  input      [1:0]  size,
  input      [1:0]  addr,       // byte offset in the word
  input      [31:0] wdata_in,   // rs2
  output reg [31:0] wdata,
  output reg [3:0]  wmask       // bit i writes byte i (bits 8i+7 : 8i)
);

  always @(*) begin
    case (size)
      2'b00: begin                                    // sb
        wdata = {4{wdata_in[7:0]}};
        wmask = 4'b0001 << addr;
      end
      2'b01: begin                                    // sh
        wdata = {2{wdata_in[15:0]}};
        wmask = addr[1] ? 4'b1100 : 4'b0011;
      end
      default: begin                                  // sw
        wdata = wdata_in;
        wmask = 4'b1111;
      end
    endcase
  end

endmodule
