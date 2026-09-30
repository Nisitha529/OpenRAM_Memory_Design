# basic_config.py
# 32-bit word, 256 words = 8 Kbit SRAM
word_size = 32
num_words = 256

tech_name = "scn4m_subm"

# Each configuration gets its own output folder so runs don't overwrite each other
output_path = "/media/nisitha/My_Passport/MOODLE/OpenRAM_Project/OpenRAM_Memory_Design/runs/sram_32x256"
output_name = "sram_32x256"

# Run magic/netgen directly from PATH instead of wrapping each call in
# `nix develop` (which fails because OpenRAM's temp dir has no flake.nix)
use_nix = False

# Verification
check_lvsdrc = True
inline_lvsdrc = False

# Characterization
analytical_delay = True       # flip to False for SPICE-based timing
nominal_corner_only = True
