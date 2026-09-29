# basic_config.py
# 32-bit word, 256 words = 8 Kbit SRAM
word_size = 32
num_words = 256

tech_name = "scn4m_subm"

output_path = "/media/nisitha/My_Passport/MOODLE/OpenRAM_Project/OpenRAM_Memory_Design"
output_name = "my_first_sram"

# Verification
check_lvsdrc = True
inline_lvsdrc = False

# Characterization
analytical_delay = True       # flip to False for SPICE-based timing
nominal_corner_only = True