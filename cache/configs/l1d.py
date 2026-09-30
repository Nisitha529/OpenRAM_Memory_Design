# L1 data cache: 512 B, direct-mapped, write-back
#   line = 4 x 32b = 128b, rows = 32 -> index 5b, offset 2b, tag 9b (+valid +dirty)
total_size = 4096
word_size = 32
words_per_line = 4
address_size = 16
num_ways = 1
write_policy = "write-back"

output_path = "/media/nisitha/My_Passport/MOODLE/OpenRAM_Project/OpenRAM_Memory_Design/cache/output/"
output_name = "l1d"
data_array_name = "sram_128x32_1r1w"
