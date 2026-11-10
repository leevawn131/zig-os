// Limine Boot Protocol v12.9.6 Definitions (Pure Zig)
// Specifications from https://github.com/Limine-Bootloader/limine-protocol

pub const COMMON_MAGIC_0: u64 = 0xc7b1dd30df4c8b88;
pub const COMMON_MAGIC_1: u64 = 0x0a82e883a194f07b;

// Base Revision
pub export var base_revision: [3]u64 linksection(".limine_requests") = .{
    0xf9562b2d5c95a6c8,
    0x6a7b384944536bdc,
    3,
};

pub fn isBaseRevisionSupported() bool {
    return @as(*const volatile u64, &base_revision[2]).* == 0;
}

// Request Delimiters
pub export var requests_start_marker: [4]u64 linksection(".limine_requests_start_marker") = .{
    0xf6b8f4b39de7d1ae,
    0xfab91a6940fcb9cf,
    0x785c6ed015d3e316,
    0x181e920a7852b9d9,
};

pub export var requests_end_marker: [2]u64 linksection(".limine_requests_end_marker") = .{
    0xadc0e0531bb10d03,
    0x9572709f31764c62,
};

// Memory Map Feature
pub const MemmapType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad_memory = 4,
    bootloader_reclaimable = 5,
    executable_and_modules = 6,
    framebuffer = 7,
    reserved_mapped = 8,
    _,

    pub fn asString(self: MemmapType) []const u8 {
        return switch (self) {
            .usable => "Usable RAM",
            .reserved => "Reserved",
            .acpi_reclaimable => "ACPI Reclaimable",
            .acpi_nvs => "ACPI NVS",
            .bad_memory => "Bad Memory",
            .bootloader_reclaimable => "Bootloader Reclaimable",
            .executable_and_modules => "Kernel/Modules",
            .framebuffer => "Framebuffer",
            .reserved_mapped => "Reserved (Mapped)",
            _ => "Unknown",
        };
    }
};

pub const MemmapEntry = extern struct {
    base: u64,
    length: u64,
    type: MemmapType,
};

pub const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: [*]const *const MemmapEntry,
};

pub const MemmapRequest = extern struct {
    id: [4]u64 = .{
        COMMON_MAGIC_0,
        COMMON_MAGIC_1,
        0x67cf3d9d378a806f,
        0xe304acdfc50c3c62,
    },
    revision: u64 = 0,
    response: ?*const volatile MemmapResponse = null,
};

pub export var memmap_request: MemmapRequest linksection(".limine_requests") = .{};

// Bootloader Info Feature
pub const BootloaderInfoResponse = extern struct {
    revision: u64,
    name: [*:0]const u8,
    version: [*:0]const u8,
};

pub const BootloaderInfoRequest = extern struct {
    id: [4]u64 = .{
        COMMON_MAGIC_0,
        COMMON_MAGIC_1,
        0xf55038d8e2a1202f,
        0x279426fcf5f59740,
    },
    revision: u64 = 0,
    response: ?*const volatile BootloaderInfoResponse = null,
};

pub export var bootloader_info_request: BootloaderInfoRequest linksection(".limine_requests") = .{};

// Higher Half Direct Map (HHDM) Feature
pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

pub const HhdmRequest = extern struct {
    id: [4]u64 = .{
        COMMON_MAGIC_0,
        COMMON_MAGIC_1,
        0x48dcf1cb8ad2b852,
        0x63984e959a98244b,
    },
    revision: u64 = 0,
    response: ?*const volatile HhdmResponse = null,
};

pub export var hhdm_request: HhdmRequest linksection(".limine_requests") = .{};

// Stack Size Request Feature
pub const StackSizeResponse = extern struct {
    revision: u64,
};

pub const StackSizeRequest = extern struct {
    id: [4]u64 = .{
        COMMON_MAGIC_0,
        COMMON_MAGIC_1,
        0x224ef0460a8e8926,
        0xe1cb0fc25f46ea3d,
    },
    revision: u64 = 0,
    response: ?*const volatile StackSizeResponse = null,
    stack_size: u64 = 65536, // 64 KiB stack
};

pub export var stack_size_request: StackSizeRequest linksection(".limine_requests") = .{};
