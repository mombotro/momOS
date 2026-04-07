/* momOS linker script — i686 bare metal
   Kernel loads at 1 MB physical (standard for multiboot)
*/

ENTRY(_start)

SECTIONS
{
    . = 1M;

    /* Multiboot1 header must be in the first 8 KB of the file */
    .multiboot : { *(.multiboot) }

    .text    ALIGN(4K) : { *(.text*)   }
    .rodata  ALIGN(4K) : { *(.rodata*) }
    .data    ALIGN(4K) : { *(.data*)   }

    .bss     ALIGN(4K) :
    {
        *(COMMON)
        *(.bss*)
    }

    _kernel_end = ALIGN(4K);
}
