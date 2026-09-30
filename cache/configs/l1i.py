# L1 instruction cache: 512 B, direct-mapped, read-only
# Sizes are in BITS; addresses are 32-bit WORD addresses.
#   line = 4 x 32b = 128b, rows = 4096/128 = 32 -> index 5b, offset 2b, tag 9b
total_size = 4096
word_size = 32
words_per_line = 4
address_size = 16
num_ways = 1
read_only = True

output_path = "/media/nisitha/My_Passport/MOODLE/OpenRAM_Project/OpenRAM_Memory_Design/cache/output/"
output_name = "l1i"
# Same SRAM shape as the L1D data array, so both caches share one macro
data_array_name = "sram_128x32_1r1w"
