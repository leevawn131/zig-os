// Kernel-Owned 64-Bit Global Descriptor Table (GDT), TSS, and IST1-IST3 Stack Management (BSP Only)
//
// Selector layout (per ADR-0005):
// - 0x00        (Index 0):     Null descriptor
// - 0x08..0x20  (Indices 1..4): Reserved (Not-Present)
// - 0x28        (Index 5):     64-bit Kernel Code Segment (DPL=0)
// - 0x30        (Index 6):     64-bit Kernel Data Segment (DPL=0)
// - 0x38..0x40  (Indices 7..8): Reserved (Not-Present; reserved for Ring 3 in Phase 2)
// - 0x48..0x57  (Indices 9..10): 16-byte 64-bit TSS System Descriptor
//
// `gdt.init()` enforces a strict BSP one-shot initialization contract and never clears an active Busy bit.

const std = @import("std");
const cpu = @import("../cpu.zig");
pub const gdt_model = @import("gdt_model.zig");

pub const GdtDescriptor = gdt_model.GdtDescriptor;
pub const Tss64 = gdt_model.Tss64;
pub const TssDescriptor16 = gdt_model.TssDescriptor16;

pub const KERNEL_CODE_SELECTOR = gdt_model.KERNEL_CODE_SELECTOR;
pub const KERNEL_DATA_SELECTOR = gdt_model.KERNEL_DATA_SELECTOR;
pub const TSS_SELECTOR = gdt_model.TSS_SELECTOR;

pub const StackRange = struct {
    base: u64,
    top: u64,
};

pub var gdt_table: [gdt_model.GDT_ENTRY_COUNT]u64 align(16) = gdt_model.makeInitialGdtTable();
pub var gdtr: GdtDescriptor = .{
    .limit = gdt_model.GDT_LIMIT,
    .base = 0,
};
pub var kernel_tss: Tss64 align(16) = .{};

pub var ist1_stack: [gdt_model.IST_STACK_SIZE]u8 align(16) = undefined; // Vector 8 (#DF)
pub var ist2_stack: [gdt_model.IST_STACK_SIZE]u8 align(16) = undefined; // Vector 2 (#NMI)
pub var ist3_stack: [gdt_model.IST_STACK_SIZE]u8 align(16) = undefined; // Vector 18 (#MC)

var initialized: bool = false;

fn stackTop(stack: *const [gdt_model.IST_STACK_SIZE]u8) u64 {
    return std.math.add(u64, @intFromPtr(stack), gdt_model.IST_STACK_SIZE) catch
        @panic("GDT: IST stack address overflow");
}

pub fn ist1Base() u64 {
    return @intFromPtr(&ist1_stack);
}

pub fn ist1Top() u64 {
    return stackTop(&ist1_stack);
}

pub fn ist2Base() u64 {
    return @intFromPtr(&ist2_stack);
}

pub fn ist2Top() u64 {
    return stackTop(&ist2_stack);
}

pub fn ist3Base() u64 {
    return @intFromPtr(&ist3_stack);
}

pub fn ist3Top() u64 {
    return stackTop(&ist3_stack);
}

/// Returns the half-open `[base, top)` virtual address range for IST index `1..3`, or `null` otherwise.
pub fn istRange(ist_index: u8) ?StackRange {
    return switch (ist_index) {
        1 => .{ .base = ist1Base(), .top = ist1Top() },
        2 => .{ .base = ist2Base(), .top = ist2Top() },
        3 => .{ .base = ist3Base(), .top = ist3Top() },
        else => null,
    };
}

pub fn isInitialized() bool {
    return initialized;
}

/// Atomically loads the kernel GDT and reloads CS (`0x28`) and data/stack/auxiliary selectors
/// within a single inline assembly block so no compiler-emitted instruction runs between `lgdt` and reload.
fn loadGdtAndReloadKernelSegments(desc: *const GdtDescriptor) void {
    comptime {
        if (gdt_model.KERNEL_CODE_SELECTOR != 0x28 or gdt_model.KERNEL_DATA_SELECTOR != 0x30) {
            @compileError("GDT reload inline assembly assumes 0x28 code and 0x30 data selectors");
        }
    }

    // Use `movw $0x00, %%ax` to preserve RFLAGS. Note that loading null selector `0x00`
    // into FS/GS has vendor-dependent hidden-base behavior on AMD64 vs Intel 64 and is
    // not relied upon to clear FS.base/GS.base (which Limine initializes to 0).
    asm volatile (
        \\ lgdt (%[gdtr])
        \\ pushq $0x28
        \\ leaq 1f(%%rip), %%rax
        \\ pushq %%rax
        \\ lretq
        \\ 1:
        \\ movw $0x30, %%ax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ movw %%ax, %%ss
        \\ movw $0x00, %%ax
        \\ movw %%ax, %%fs
        \\ movw %%ax, %%gs
        :
        : [gdtr] "r" (desc),
        : .{ .rax = true, .memory = true }
    );
}

/// Strict one-shot BSP initialization of kernel GDT, 64-bit TSS, and IST1-IST3 stacks.
/// Panics if called more than once; never resets a Busy TSS bit to simulate idempotency.
pub fn init() void {
    if (initialized) {
        @panic("GDT: gdt.init() is one-shot on BSP and must not be called twice");
    }

    kernel_tss = .{
        .ist1 = ist1Top(),
        .ist2 = ist2Top(),
        .ist3 = ist3Top(),
        .iomap_base = @sizeOf(Tss64),
    };

    const tss_desc = gdt_model.encodeTssDescriptor(@intFromPtr(&kernel_tss), gdt_model.TSS_MIN_LIMIT);
    gdt_table[gdt_model.TSS_DESCRIPTOR_INDEX] = tss_desc.low;
    gdt_table[gdt_model.TSS_DESCRIPTOR_INDEX + 1] = tss_desc.high;

    if (gdt_model.tssAccessByte(gdt_table[gdt_model.TSS_DESCRIPTOR_INDEX]) != gdt_model.TSS_ACCESS_AVAILABLE) {
        @panic("GDT: Initial TSS descriptor must be Available (0x89)");
    }

    gdtr = .{
        .limit = gdt_model.GDT_LIMIT,
        .base = @intFromPtr(&gdt_table),
    };

    loadGdtAndReloadKernelSegments(&gdtr);

    // Invoke `ltr` in a separate call after `lretq` so register allocation cannot alias `%rax`.
    cpu.ltr(TSS_SELECTOR);
    initialized = true;
}

/// Verifies live GDTR, TR, post-load Accessed/Busy descriptor bits, active segment selectors,
/// and three disjoint 16-byte-aligned BSP IST stacks.
pub fn testGdtAndTss() bool {
    if (!initialized) return false;

    var live_gdtr: GdtDescriptor = .{ .limit = 0, .base = 0 };
    cpu.sgdt(&live_gdtr);
    if (live_gdtr.limit != gdt_model.GDT_LIMIT) return false;
    if (live_gdtr.base != @intFromPtr(&gdt_table)) return false;

    if (getCs() != KERNEL_CODE_SELECTOR) return false;
    if (getDs() != KERNEL_DATA_SELECTOR) return false;
    if (getSs() != KERNEL_DATA_SELECTOR) return false;

    // Reserved slots 0..4 and 7..8 must remain zero (Not-Present).
    for ([_]usize{ 0, 1, 2, 3, 4, 7, 8 }) |slot| {
        if (gdt_table[slot] != 0) return false;
    }

    if (!gdt_model.isCodeDescriptorValidPostLoad(gdt_table[gdt_model.KERNEL_CODE_INDEX])) return false;
    if (!gdt_model.isDataDescriptorValidPostLoad(gdt_table[gdt_model.KERNEL_DATA_INDEX])) return false;

    if (cpu.str() != TSS_SELECTOR) return false;
    if (!gdt_model.isTssDescriptorBusyValid(
        gdt_table[gdt_model.TSS_DESCRIPTOR_INDEX],
        gdt_table[gdt_model.TSS_DESCRIPTOR_INDEX + 1],
        @intFromPtr(&kernel_tss),
        gdt_model.TSS_MIN_LIMIT,
    )) {
        return false;
    }

    if (kernel_tss.iomap_base != @sizeOf(Tss64)) return false;
    if (kernel_tss.ist1 != ist1Top() or (kernel_tss.ist1 & 0x0F) != 0) return false;
    if (kernel_tss.ist2 != ist2Top() or (kernel_tss.ist2 & 0x0F) != 0) return false;
    if (kernel_tss.ist3 != ist3Top() or (kernel_tss.ist3 & 0x0F) != 0) return false;

    const r1 = istRange(1) orelse return false;
    const r2 = istRange(2) orelse return false;
    const r3 = istRange(3) orelse return false;

    if (!gdt_model.areRangesDisjoint(r1.base, r1.top, r2.base, r2.top)) return false;
    if (!gdt_model.areRangesDisjoint(r1.base, r1.top, r3.base, r3.top)) return false;
    if (!gdt_model.areRangesDisjoint(r2.base, r2.top, r3.base, r3.top)) return false;

    return true;
}

pub inline fn getCs() u16 {
    return asm volatile ("mov %%cs, %[ret]"
        : [ret] "=r" (-> u16),
    );
}

pub inline fn getDs() u16 {
    return asm volatile ("mov %%ds, %[ret]"
        : [ret] "=r" (-> u16),
    );
}

pub inline fn getSs() u16 {
    return asm volatile ("mov %%ss, %[ret]"
        : [ret] "=r" (-> u16),
    );
}
