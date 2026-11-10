/* Linker script for ZIG-OS x86_64 higher-half kernel */

OUTPUT_FORMAT(elf64-x86-64)
OUTPUT_ARCH(i386:x86-64)

ENTRY(_start)

PHDRS
{
    text    PT_LOAD FLAGS((1 << 0) | (1 << 2)); /* Read + Execute */
    rodata  PT_LOAD FLAGS((1 << 2));            /* Read Only */
    data    PT_LOAD FLAGS((1 << 1) | (1 << 2)); /* Read + Write */
}

SECTIONS
{
    /* Limine higher-half kernel base: -2 GiB */
    . = 0xffffffff80000000;

    .text : {
        *(.text .text.*)
    } :text

    . = ALIGN(4096);

    .rodata : {
        *(.rodata .rodata.*)
    } :rodata

    . = ALIGN(4096);

    .data : {
        *(.data .data.*)

        /* Limine boot protocol request tags */
        KEEP(*(.limine_requests_start_marker))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end_marker))
    } :data

    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    } :data

    /DISCARD/ : {
        *(.eh_frame*)
        *(.note .note.*)
        *(.comment)
    }
}
