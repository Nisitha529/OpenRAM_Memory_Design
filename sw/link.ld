/* Memory map (byte addresses, 256 KB total = what the caches can address)
 *   0x00000  code (.text)
 *   0x08000  data (.data/.bss)
 *   0x3ff00  tohost: the program stores its result here (1 = pass)
 */
OUTPUT_ARCH(riscv)
ENTRY(_start)
SECTIONS
{
  . = 0x00000;
  .text : { *(.text.init) *(.text*) }
  . = 0x08000;
  .data : { *(.data*) *(.rodata*) *(.sdata*) }
  .bss  : { *(.bss*) *(.sbss*) }
  tohost = 0x3ff00;
}
