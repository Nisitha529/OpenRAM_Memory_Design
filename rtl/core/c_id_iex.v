module c_id_iex(
  input              clk,
  input              reset,
  input              clear,
  input              enable,     // CACHE: low while a cache miss freezes the pipeline
  input              jalrd,      // JALR in decode
  input       [2:0]  funct3d,    // branch type in decode
  input              regwrited,
  input              memwrited,
  input              jumpd,
  input              branchd,
  input              alusrcad,
  input  [1:0]       alusrcbd,
  input  [1:0]       resultsrcd,
  input  [3:0]       alucontrold,
  output reg         regwritee,
  output reg         memwritee,
  output reg         jumpe,
  output reg         branche,
  output reg         alusrcae,
  output reg  [1:0]  alusrcbe,
  output reg  [1:0]  resultsrce,
  output reg  [3:0]  alucontrole,
  output reg         jalre,      // JALR in execute
  output reg  [2:0]  funct3e     // branch type in execute
);

  always @(posedge clk or posedge reset) begin
    if (reset) begin
      regwritee    <= 0;
      memwritee    <= 0;
      jumpe        <= 0;
      branche      <= 0;
      alusrcae     <= 0;
      alusrcbe     <= 0;
      resultsrce   <= 0;
      alucontrole  <= 0;
      jalre        <= 0;
      funct3e      <= 0;
    end
    else if (enable && clear) begin
      regwritee    <= 0;
      memwritee    <= 0;
      jumpe        <= 0;
      branche      <= 0;
      alusrcae     <= 0;
      alusrcbe     <= 0;
      resultsrce   <= 0;
      alucontrole  <= 0;
      jalre        <= 0;
      funct3e      <= 0;
    end
    else if (enable) begin
      regwritee    <= regwrited;
      memwritee    <= memwrited;
      jumpe        <= jumpd;
      branche      <= branchd;
      alusrcae     <= alusrcad;
      alusrcbe     <= alusrcbd;
      resultsrce   <= resultsrcd;
      alucontrole  <= alucontrold;
      jalre        <= jalrd;
      funct3e      <= funct3d;
    end
  end

endmodule
