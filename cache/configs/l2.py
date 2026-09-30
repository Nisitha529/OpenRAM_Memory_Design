# L2 unified cache: 2 KB, 2-way set-associative, LRU, write-back
# One L2 "word" is one L1 line (128b), so L1 misses map 1:1 onto L2 requests.
#   L2 line = 2 x 128b = 256b, row = 2 ways x 256b = 512b
#   rows = 16384/512 = 32 -> index 5b, offset 1b, tag 14-5-1 = 8b
total_size = 16384
word_size = 128
words_per_line = 2
address_size = 14
num_ways = 2
replacement_policy = "lru"
write_policy = "write-back"

output_path = "/media/nisitha/My_Passport/MOODLE/OpenRAM_Project/OpenRAM_Memory_Design/cache/output/"
output_name = "l2"
