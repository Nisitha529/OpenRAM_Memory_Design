# With the default words_per_row = 1, OpenRAM's router left one write driver's
# w_en input unconnected (LVS mismatch). Two words per row changes the column
# layout and gives a clean macro (DRC 0, LVS match).
words_per_row = 2
