const std = @import("std");
const vectors = @import("vectors");
const build_options = @import("build_options");

const ForbiddenIntHit = struct {
    file_path: []const u8,
    line: usize,
    vector: u8,
    snippet: []const u8,

    fn deinit(self: *const ForbiddenIntHit, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.snippet);
    }
};

fn deinitHits(allocator: std.mem.Allocator, hits: *std.ArrayList(ForbiddenIntHit)) void {
    for (hits.items) |*hit| {
        hit.deinit(allocator);
    }
    hits.deinit(allocator);
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.';
}

fn isHorizontalSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

fn isAsmBoundaryAfterOperand(ch: u8) bool {
    return isHorizontalSpace(ch) or ch == ';' or ch == '\n' or ch == '\r' or ch == '/' or ch == '#';
}

/// Parses decimal (`14`), prefixed hex (`0x0e`), or Intel-suffixed hex (`0Eh`) vector literals,
/// stripping optional AT&T immediate prefix `$`. Returns null for registers/symbols/out-of-range values.
fn parseVectorLiteral(raw_token: []const u8) ?u8 {
    if (raw_token.len == 0) return null;

    const token = if (raw_token[0] == '$') raw_token[1..] else raw_token;
    if (token.len == 0) return null;

    var parsed: ?u16 = null;
    if (token.len >= 3 and token[0] == '0' and (token[1] == 'x' or token[1] == 'X')) {
        parsed = parseStrictDigits(token[2..], 16);
    } else if (token.len >= 2 and (token[token.len - 1] == 'h' or token[token.len - 1] == 'H') and std.ascii.isDigit(token[0])) {
        parsed = parseStrictDigits(token[0 .. token.len - 1], 16);
    } else if (std.ascii.isDigit(token[0])) {
        parsed = parseStrictDigits(token, 10);
    }

    const value = parsed orelse return null;
    if (value > 255) return null;
    return @intCast(value);
}

fn parseStrictDigits(digits: []const u8, radix: u8) ?u16 {
    if (digits.len == 0) return null;
    for (digits) |ch| {
        const ok = switch (radix) {
            10 => std.ascii.isDigit(ch),
            16 => std.ascii.isHex(ch),
            else => unreachable,
        };
        if (!ok) return null;
    }
    return std.fmt.parseInt(u16, digits, radix) catch null;
}

/// Scans an assembly buffer (either a full .s/.S/.asm source file or extracted inline asm string)
/// for forbidden software `int <vector>` instructions while skipping comments and quoted strings.
fn scanAssemblyText(
    allocator: std.mem.Allocator,
    hits: *std.ArrayList(ForbiddenIntHit),
    file_path: []const u8,
    base_line: usize,
    advance_lines_on_newline: bool,
    source: []const u8,
) !void {
    var i: usize = 0;
    var line: usize = base_line;
    var in_block_comment = false;
    var line_start: usize = 0;

    while (i < source.len) {
        if (in_block_comment) {
            if (source[i] == '*' and i + 1 < source.len and source[i + 1] == '/') {
                in_block_comment = false;
                i += 2;
                continue;
            }
            if (source[i] == '\n') {
                if (advance_lines_on_newline) line += 1;
                line_start = i + 1;
            }
            i += 1;
            continue;
        }

        const ch = source[i];
        if (ch == '\n') {
            if (advance_lines_on_newline) line += 1;
            i += 1;
            line_start = i;
            continue;
        }

        // Line comments in GAS/Intel assembly: '#' or '//'
        if (ch == '#' or (ch == '/' and i + 1 < source.len and source[i + 1] == '/')) {
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            continue;
        }

        // C-style block comments in assembly sources
        if (ch == '/' and i + 1 < source.len and source[i + 1] == '*') {
            in_block_comment = true;
            i += 2;
            continue;
        }

        // Skip quoted strings/chars inside .s files (.ascii/.asciz/.string)
        if (ch == '"' or ch == '\'') {
            const quote = ch;
            i += 1;
            while (i < source.len) {
                if (source[i] == '\\' and i + 1 < source.len) {
                    if (source[i + 1] == '\n') {
                        if (advance_lines_on_newline) line += 1;
                        line_start = i + 2;
                    }
                    i += 2;
                    continue;
                }
                if (source[i] == '\n') {
                    if (advance_lines_on_newline) line += 1;
                    line_start = i + 1;
                }
                if (source[i] == quote) {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Match whole mnemonic `int` (case-insensitive) followed by horizontal whitespace + vector operand
        if (i + 3 < source.len and
            std.ascii.toLower(source[i]) == 'i' and
            std.ascii.toLower(source[i + 1]) == 'n' and
            std.ascii.toLower(source[i + 2]) == 't' and
            isHorizontalSpace(source[i + 3]) and
            (i == 0 or !isIdentChar(source[i - 1])))
        {
            var op_start = i + 3;
            while (op_start < source.len and isHorizontalSpace(source[op_start])) : (op_start += 1) {}

            var op_end = op_start;
            while (op_end < source.len and
                (std.ascii.isAlphanumeric(source[op_end]) or source[op_end] == '$' or source[op_end] == '_'))
            {
                op_end += 1;
            }

            if (op_end > op_start and (op_end == source.len or isAsmBoundaryAfterOperand(source[op_end]))) {
                if (parseVectorLiteral(source[op_start..op_end])) |vec| {
                    if (vectors.isForbiddenSoftwareIntVector(vec)) {
                        var line_end = i;
                        while (line_end < source.len and source[line_end] != '\n' and source[line_end] != '\r') : (line_end += 1) {}
                        const raw_snippet = std.mem.trim(u8, source[line_start..line_end], " \t");
                        try hits.append(allocator, .{
                            .file_path = try allocator.dupe(u8, file_path),
                            .line = line,
                            .vector = vec,
                            .snippet = try allocator.dupe(u8, raw_snippet),
                        });
                    }
                }
            }

            i += 3;
            continue;
        }

        i += 1;
    }
}

/// Scans a Zig source file, ignoring `//` comments and character literals while extracting
/// single-line `"..."` strings and contiguous multiline `\\...` blocks for assembly scanning.
fn scanZigSource(
    allocator: std.mem.Allocator,
    hits: *std.ArrayList(ForbiddenIntHit),
    file_path: []const u8,
    source: []const u8,
) !void {
    var i: usize = 0;
    var line: usize = 1;

    while (i < source.len) {
        const ch = source[i];
        if (ch == '\n') {
            line += 1;
            i += 1;
            continue;
        }

        // Ignore Zig line comments (`// ...`)
        if (ch == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            continue;
        }

        // Skip Zig character literals (`'...'`) so `'"'` does not start a string
        if (ch == '\'') {
            i += 1;
            while (i < source.len) {
                if (source[i] == '\\' and i + 1 < source.len) {
                    i += 2;
                    continue;
                }
                if (source[i] == '\n') {
                    line += 1;
                    i += 1;
                    break;
                }
                if (source[i] == '\'') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            continue;
        }

        // Decode single-line Zig string literal (`"..."`)
        if (ch == '"') {
            const start_line = line;
            var decoded: std.ArrayList(u8) = .empty;
            defer decoded.deinit(allocator);

            i += 1;
            while (i < source.len) {
                if (source[i] == '\\' and i + 1 < source.len) {
                    const esc = source[i + 1];
                    switch (esc) {
                        'n' => try decoded.append(allocator, '\n'),
                        'r' => try decoded.append(allocator, '\r'),
                        't' => try decoded.append(allocator, '\t'),
                        '\\', '"', '\'' => try decoded.append(allocator, esc),
                        else => try decoded.append(allocator, esc),
                    }
                    i += 2;
                    continue;
                }
                if (source[i] == '\n') {
                    line += 1;
                    i += 1;
                    break;
                }
                if (source[i] == '"') {
                    i += 1;
                    break;
                }
                try decoded.append(allocator, source[i]);
                i += 1;
            }

            try scanAssemblyText(allocator, hits, file_path, start_line, false, decoded.items);
            continue;
        }

        // Collect contiguous multiline Zig string block (`\\...`) preserving line numbers
        if (ch == '\\' and i + 1 < source.len and source[i + 1] == '\\') {
            const start_line = line;
            var block: std.ArrayList(u8) = .empty;
            defer block.deinit(allocator);

            while (true) {
                i += 2; // Skip `\\`
                while (i < source.len and source[i] != '\n') : (i += 1) {
                    if (source[i] != '\r') {
                        try block.append(allocator, source[i]);
                    }
                }
                if (i < source.len and source[i] == '\n') {
                    try block.append(allocator, '\n');
                    line += 1;
                    i += 1;
                } else {
                    break;
                }

                // Check if next line continues the multiline string literal block
                var lookahead = i;
                while (lookahead < source.len and (source[lookahead] == ' ' or source[lookahead] == '\t' or source[lookahead] == '\r')) : (lookahead += 1) {}
                if (lookahead + 1 < source.len and source[lookahead] == '\\' and source[lookahead + 1] == '\\') {
                    i = lookahead;
                    continue;
                }
                break;
            }

            try scanAssemblyText(allocator, hits, file_path, start_line, true, block.items);
            continue;
        }

        i += 1;
    }
}

fn hasScannedExtension(path: []const u8) enum { none, zig, asm_src } {
    if (std.mem.endsWith(u8, path, ".zig")) return .zig;
    if (std.mem.endsWith(u8, path, ".s") or
        std.mem.endsWith(u8, path, ".S") or
        std.mem.endsWith(u8, path, ".asm"))
    {
        return .asm_src;
    }
    return .none;
}

test "vectors 1: exact hardware error-code vector set {8,10,11,12,13,14,17,21,29,30}" {
    try std.testing.expectEqual(@as(usize, 10), vectors.ERROR_CODE_VECTORS.len);

    var error_code_count: usize = 0;
    for (0..vectors.IDT_ENTRY_COUNT) |v_usize| {
        const v: u8 = @intCast(v_usize);
        const expected = switch (v) {
            8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
            else => false,
        };
        try std.testing.expectEqual(expected, vectors.pushesHardwareErrorCode(v));
        if (expected) error_code_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 10), error_code_count);

    for (vectors.ERROR_CODE_VECTORS) |ev| {
        try std.testing.expect(vectors.pushesHardwareErrorCode(ev));
        try std.testing.expect(vectors.isExceptionVector(ev));
    }
}

test "vectors 2: reserved exception space (0..31) vs allowed external vectors (>= 32)" {
    try std.testing.expectEqual(@as(usize, 256), vectors.IDT_ENTRY_COUNT);
    try std.testing.expectEqual(@as(usize, 32), vectors.EXCEPTION_VECTOR_COUNT);
    try std.testing.expectEqual(@as(u8, 32), vectors.FIRST_EXTERNAL_VECTOR);

    for (0..vectors.EXCEPTION_VECTOR_COUNT) |v_usize| {
        const v: u8 = @intCast(v_usize);
        try std.testing.expect(vectors.isExceptionVector(v));
        try std.testing.expect(!vectors.isExternalVectorAllowed(v));
        try std.testing.expectError(error.ReservedExceptionVector, vectors.validateExternalVector(v));
    }

    for (vectors.EXCEPTION_VECTOR_COUNT..vectors.IDT_ENTRY_COUNT) |v_usize| {
        const v: u8 = @intCast(v_usize);
        try std.testing.expect(!vectors.isExceptionVector(v));
        try std.testing.expect(vectors.isExternalVectorAllowed(v));
        try std.testing.expectEqual(v, try vectors.validateExternalVector(v));
    }
}

test "vectors 3: software INT n policy forbids error-code and reserved exceptions except #BP (3)" {
    for (0..vectors.IDT_ENTRY_COUNT) |v_usize| {
        const v: u8 = @intCast(v_usize);
        const allowed = (v == vectors.CONTROLLED_BREAKPOINT_VECTOR) or (v >= vectors.FIRST_EXTERNAL_VECTOR);
        try std.testing.expectEqual(allowed, vectors.isAllowedKernelSoftwareIntVector(v));
        try std.testing.expectEqual(!allowed, vectors.isForbiddenSoftwareIntVector(v));
    }

    for (vectors.ERROR_CODE_VECTORS) |ev| {
        try std.testing.expect(vectors.isForbiddenSoftwareIntVector(ev));
    }
}

test "vectors 4: legacy 8259 PIC vector offset validation" {
    try std.testing.expect(vectors.isPicOffsetValid(vectors.LEGACY_PIC_MASTER_OFFSET, vectors.LEGACY_PIC_SLAVE_OFFSET));
    try std.testing.expect(vectors.isPicOffsetValid(0x28, 0x20));
    try std.testing.expect(vectors.isPicOffsetValid(0x30, 0xF8));
    try std.testing.expect(vectors.isPicOffsetValid(0xF0, 0xF8));

    // Legacy BIOS PIC offsets overlap architectural exceptions 0x08..0x0F
    try std.testing.expect(!vectors.isPicOffsetValid(0x08, 0x70));
    try std.testing.expect(!vectors.isPicOffsetValid(0x00, 0x08));
    try std.testing.expect(!vectors.isPicOffsetValid(0x18, 0x20));

    // Unaligned offsets
    try std.testing.expect(!vectors.isPicOffsetValid(0x21, 0x28));
    try std.testing.expect(!vectors.isPicOffsetValid(0x20, 0x2C));

    // Overlapping master and slave 8-vector windows
    try std.testing.expect(!vectors.isPicOffsetValid(0x20, 0x20));
    try std.testing.expect(!vectors.isPicOffsetValid(0x30, 0x30));

    // Out-of-bounds wrap beyond vector 255
    try std.testing.expect(!vectors.isPicOffsetValid(0xFA, 0x20));
    try std.testing.expect(!vectors.isPicOffsetValid(0x20, 0xF9));
}

test "vectors 5: pure IDT kernel interrupt gate validator checks flags, IST reserved bits, reserved, selector, offset" {
    const cs: u16 = 0x28;
    const addr: u64 = 0xffffffff80001234;

    try std.testing.expect(vectors.isValidKernelInterruptGate(vectors.IDT_GATE_FLAGS_KERNEL_INTERRUPT, 0, 0, cs, cs, addr, addr));
    try std.testing.expect(vectors.isValidKernelInterruptGate(0x8E, 7, 0, cs, cs, addr, addr));

    // Wrong DPL / Present / Type / S-bit
    try std.testing.expect(!vectors.isValidKernelInterruptGate(0xEE, 0, 0, cs, cs, addr, addr)); // DPL=3
    try std.testing.expect(!vectors.isValidKernelInterruptGate(0xAE, 0, 0, cs, cs, addr, addr)); // DPL=1
    try std.testing.expect(!vectors.isValidKernelInterruptGate(0x0E, 0, 0, cs, cs, addr, addr)); // Not Present
    try std.testing.expect(!vectors.isValidKernelInterruptGate(0x8F, 0, 0, cs, cs, addr, addr)); // Trap Gate instead of Interrupt Gate
    try std.testing.expect(!vectors.isValidKernelInterruptGate(0x9E, 0, 0, cs, cs, addr, addr)); // Storage bit set

    // Reserved upper IST bits / reserved field / selector / offset mismatch
    try std.testing.expect(!vectors.isValidKernelInterruptGate(0x8E, 8, 0, cs, cs, addr, addr));
    try std.testing.expect(!vectors.isValidKernelInterruptGate(0x8E, 0, 1, cs, cs, addr, addr));
    try std.testing.expect(!vectors.isValidKernelInterruptGate(0x8E, 0, 0, 0x08, cs, addr, addr));
    try std.testing.expect(!vectors.isValidKernelInterruptGate(0x8E, 0, 0, cs, cs, addr + 4, addr));
}

test "scanner 1: assembly scanner detects forbidden INT n in decimal/hex/AT&T/Intel while ignoring comments and strings" {
    const gpa = std.testing.allocator;

    // Clean fixture: comments, strings, identifiers, int $3 (#BP), int >= 32
    const clean_asm =
        \\// int $14 should be ignored
        \\# int 13 should also be ignored
        \\/*
        \\ * Multi-line comment: int $0x0e and int 0Eh
        \\ */
        \\msg: .asciz "int $14"
        \\print 14
        \\.int 14
        \\    int $3
        \\    int $32
        \\    int $0x20
        \\    int 20h
    ;
    var clean_hits: std.ArrayList(ForbiddenIntHit) = .empty;
    defer deinitHits(gpa, &clean_hits);
    try scanAssemblyText(gpa, &clean_hits, "synthetic_clean.s", 1, true, clean_asm);
    try std.testing.expectEqual(@as(usize, 0), clean_hits.items.len);

    // Negative fixture: multiple encodings of forbidden vectors
    const bad_asm =
        \\    nop
        \\    int $14
        \\    /* comment */
        \\    int $0x0e
        \\    INT 0Eh
        \\    int 8
        \\    int $1
    ;
    var bad_hits: std.ArrayList(ForbiddenIntHit) = .empty;
    defer deinitHits(gpa, &bad_hits);
    try scanAssemblyText(gpa, &bad_hits, "synthetic_bad.s", 1, true, bad_asm);
    try std.testing.expectEqual(@as(usize, 5), bad_hits.items.len);

    try std.testing.expectEqual(@as(usize, 2), bad_hits.items[0].line);
    try std.testing.expectEqual(@as(u8, 14), bad_hits.items[0].vector);

    try std.testing.expectEqual(@as(usize, 4), bad_hits.items[1].line);
    try std.testing.expectEqual(@as(u8, 14), bad_hits.items[1].vector);

    try std.testing.expectEqual(@as(usize, 5), bad_hits.items[2].line);
    try std.testing.expectEqual(@as(u8, 14), bad_hits.items[2].vector);

    try std.testing.expectEqual(@as(usize, 6), bad_hits.items[3].line);
    try std.testing.expectEqual(@as(u8, 8), bad_hits.items[3].vector);

    try std.testing.expectEqual(@as(usize, 7), bad_hits.items[4].line);
    try std.testing.expectEqual(@as(u8, 1), bad_hits.items[4].vector);
}

test "scanner 2: Zig inline-asm scanner inspects string literals and multiline \\\\ blocks accurately" {
    const gpa = std.testing.allocator;

    const clean_zig =
        \\// asm volatile ("int $14");
        \\const quote = '"';
        \\fn ok() void {
        \\    _ = quote;
        \\    asm volatile ("int $3");
        \\    asm volatile ("# int $14\nint $3");
        \\    asm volatile (
        \\        \\nop
        \\        \\int $0x20
        \\    );
        \\}
    ;
    var clean_hits: std.ArrayList(ForbiddenIntHit) = .empty;
    defer deinitHits(gpa, &clean_hits);
    try scanZigSource(gpa, &clean_hits, "synthetic_clean.zig", clean_zig);
    try std.testing.expectEqual(@as(usize, 0), clean_hits.items.len);

    const bad_zig =
        \\fn bad() void {
        \\    asm volatile ("int $14");
        \\    asm volatile (
        \\        \\cli
        \\        \\int 13
        \\    );
        \\    asm volatile ("int $0x08");
        \\}
    ;
    var bad_hits: std.ArrayList(ForbiddenIntHit) = .empty;
    defer deinitHits(gpa, &bad_hits);
    try scanZigSource(gpa, &bad_hits, "synthetic_bad.zig", bad_zig);
    try std.testing.expectEqual(@as(usize, 3), bad_hits.items.len);

    try std.testing.expectEqual(@as(usize, 2), bad_hits.items[0].line);
    try std.testing.expectEqual(@as(u8, 14), bad_hits.items[0].vector);

    try std.testing.expectEqual(@as(usize, 5), bad_hits.items[1].line);
    try std.testing.expectEqual(@as(u8, 13), bad_hits.items[1].vector);

    try std.testing.expectEqual(@as(usize, 7), bad_hits.items[2].line);
    try std.testing.expectEqual(@as(u8, 8), bad_hits.items[2].vector);
}

test "scanner 3: live kernel/ source tree contains zero forbidden software INT instructions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var kernel_dir = try std.Io.Dir.cwd().openDir(io, build_options.kernel_dir, .{ .iterate = true });
    defer kernel_dir.close(io);

    var walker = try kernel_dir.walk(gpa);
    defer walker.deinit();

    var hits: std.ArrayList(ForbiddenIntHit) = .empty;
    defer deinitHits(gpa, &hits);

    var scanned_files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const kind = hasScannedExtension(entry.basename);
        if (kind == .none) continue;

        scanned_files += 1;
        const contents = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(4 * 1024 * 1024));
        defer gpa.free(contents);

        switch (kind) {
            .zig => try scanZigSource(gpa, &hits, entry.path, contents),
            .asm_src => try scanAssemblyText(gpa, &hits, entry.path, 1, true, contents),
            .none => unreachable,
        }
    }

    try std.testing.expect(scanned_files > 0);
    if (hits.items.len > 0) {
        for (hits.items) |hit| {
            std.debug.print(
                "FORBIDDEN SOFTWARE INT at kernel/{s}:{d} (vector {d}): {s}\n",
                .{ hit.file_path, hit.line, hit.vector, hit.snippet },
            );
        }
    }
    try std.testing.expectEqual(@as(usize, 0), hits.items.len);
}
