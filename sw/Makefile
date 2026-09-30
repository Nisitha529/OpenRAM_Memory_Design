# Build the RV32I test programs into $readmemh images (one 32-bit word per line)
PREFIX ?= riscv64-unknown-elf-
AS_FLAGS = -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles -T link.ld

TESTS = test_core test_mem

all: $(TESTS:%=%.hex)

%.elf: %.S common.h link.ld
	$(PREFIX)gcc $(AS_FLAGS) -o $@ $<

%.hex: %.elf bin2hex.py
	$(PREFIX)objcopy -O binary $< $*.bin
	python3 bin2hex.py $*.bin $@
	$(PREFIX)objdump -d $< > $*.dis

.PRECIOUS: %.elf

clean:
	rm -f *.elf *.bin *.hex *.dis
