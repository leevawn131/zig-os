const std = @import("std");
const vectors = @import("vectors");
const build_options = @import("build_options");

const ViolationKind = enum {
    forbidden_vector,
    unresolved_operand,
};

const ForbiddenIntHit = struct {
    file_path: []const u8,
    line: usize,
    kind: ViolationKind,
    vector: ?u8,
    operand: []const u8,
    snippet: []const u8,

    fn deinit(self: *const ForbiddenIntHit, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.operand);
        allocator.free(self.snippet);
    }
};

const SymbolTable = std.StringHashMapUnmanaged(?u8);

fn deinitHits(allocator: std.mem.Allocator, hits: *std.ArrayList(ForbiddenIntHit)) void {
    for (hits.items) |*hit| {
        hit.deinit(allocator);
    }
    hits.deinit(allocator);
}

fn deinitSymbolTable(allocator: std.mem.Allocator, constants: *SymbolTable) void {
    var it = constants.keyIterator();
    while (it.next()) |key_ptr| {
        allocator.free(key_ptr.*);
    }
    constants.deinit(allocator);
}

fn putSymbol(
    allocator: std.mem.Allocator,
    constants: *SymbolTable,
    name: []const u8,
    value: ?u8,
) !void {
    const gop = try constants.getOrPut(allocator, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = try allocator.dupe(u8, name);
    }
    gop.value_ptr.* = value;
}

fn isIdentChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.';
}

fn isSymbolChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '$';
}

fn isHorizontalSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t';
}

fn matchesKeywordCaseInsensitive(source: []const u8, pos: usize, keyword: []const u8) bool {
    if (pos + keyword.len > source.len) return false;
    for (keyword, 0..) |expected, offset| {
        if (std.ascii.toLower(source[pos + offset]) != std.ascii.toLower(expected)) {
            return false;
        }
    }
    return true;
}

fn findStatementEnd(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len) : (i += 1) {
        const ch = source[i];
        if (ch == ';' or ch == '\n' or ch == '\r' or ch == '#') {
            return i;
        }
        if (ch == '/' and i + 1 < source.len and (source[i + 1] == '/' or source[i + 1] == '*')) {
            return i;
        }
    }
    return i;
}

/// Parses decimal (`14`), prefixed hex (`0x0e`), or Intel-suffixed hex (`0Eh`) vector literals,
/// stripping optional AT&T immediate prefix `$`. Returns null for non-literals or values > 255.
fn parseVectorLiteral(raw_token: []const u8) ?u8 {
    if (raw_token.len == 0) return null;

    const token = if (raw_token[0] == '$') raw_token[1..] else raw_token;
    if (token.len == 0) return null;

    var parsed: ?u16 = null;
    if (token.len >= 3 and token[0] == '0' and (token[1] == 'x' or token[1] == 'X')) {
        parsed = parseStrictDigits(u16, token[2..], 16);
    } else if (token.len >= 2 and (token[token.len - 1] == 'h' or token[token.len - 1] == 'H') and std.ascii.isDigit(token[0])) {
        parsed = parseStrictDigits(u16, token[0 .. token.len - 1], 16);
    } else if (std.ascii.isDigit(token[0])) {
        parsed = parseStrictDigits(u16, token, 10);
    }

    const value = parsed orelse return null;
    if (value > 255) return null;
    return @intCast(value);
}

fn parseStrictDigits(comptime T: type, digits: []const u8, radix: u8) ?T {
    if (digits.len == 0) return null;
    for (digits) |ch| {
        const ok = switch (radix) {
            10 => std.ascii.isDigit(ch),
            16 => std.ascii.isHex(ch),
            else => unreachable,
        };
        if (!ok) return null;
    }
    return std.fmt.parseInt(T, digits, radix) catch null;
}

/// Resolves either a numeric immediate (`$14`, `0x0e`, `0Eh`) or a known symbol
/// defined earlier via `.equ` / `.set` / `.equiv`. Returns null if unresolved.
fn resolveOperandValue(constants: *const SymbolTable, raw_operand: []const u8) ?u8 {
    const trimmed = std.mem.trim(u8, raw_operand, " \t");
    if (trimmed.len == 0) return null;

    if (parseVectorLiteral(trimmed)) |lit| {
        return lit;
    }

    const sym = if (trimmed[0] == '$') trimmed[1..] else trimmed;
    if (sym.len == 0) return null;
    for (sym) |ch| {
        if (!isSymbolChar(ch)) return null;
    }

    if (constants.get(sym)) |maybe_val| {
        return maybe_val;
    }
    return null;
}

/// Parses `.equ SYMBOL, EXPR`, `.set SYMBOL, EXPR`, or `.equiv SYMBOL, EXPR`
/// and records the resolved constant (or `null` if expression cannot be resolved).
fn tryParseEquDirective(
    allocator: std.mem.Allocator,
    constants: *SymbolTable,
    source: []const u8,
    pos: usize,
) !?usize {
    if (pos > 0 and isIdentChar(source[pos - 1])) return null;

    const keywords = [_][]const u8{ ".equiv", ".equ", ".set" };
    var matched_len: usize = 0;
    for (keywords) |kw| {
        if (matchesKeywordCaseInsensitive(source, pos, kw) and
            pos + kw.len < source.len and
            isHorizontalSpace(source[pos + kw.len]))
        {
            matched_len = kw.len;
            break;
        }
    }
    if (matched_len == 0) return null;

    const stmt_end = findStatementEnd(source, pos + matched_len);
    const tail = std.mem.trim(u8, source[pos + matched_len .. stmt_end], " \t");
    const comma_idx = std.mem.indexOfScalar(u8, tail, ',') orelse return stmt_end;

    const raw_sym = std.mem.trim(u8, tail[0..comma_idx], " \t");
    const raw_val = std.mem.trim(u8, tail[comma_idx + 1 ..], " \t");
    if (raw_sym.len == 0) return stmt_end;

    const resolved = resolveOperandValue(constants, raw_val);
    try putSymbol(allocator, constants, raw_sym, resolved);
    return stmt_end;
}

fn appendHit(
    allocator: std.mem.Allocator,
    hits: *std.ArrayList(ForbiddenIntHit),
    file_path: []const u8,
    line: usize,
    kind: ViolationKind,
    vector: ?u8,
    operand: []const u8,
    snippet: []const u8,
) !void {
    try hits.append(allocator, .{
        .file_path = try allocator.dupe(u8, file_path),
        .line = line,
        .kind = kind,
        .vector = vector,
        .operand = try allocator.dupe(u8, operand),
        .snippet = try allocator.dupe(u8, snippet),
    });
}

const Linemarker = struct {
    next_line: usize,
    filename: []const u8,
    after_eol: usize,
};

fn parseLinemarkerLine(source: []const u8, i: usize, line_start: usize) ?Linemarker {
    if (i != line_start or i >= source.len or source[i] != '#') return null;

    var pos = i + 1;
    while (pos < source.len and isHorizontalSpace(source[pos])) : (pos += 1) {}

    if (matchesKeywordCaseInsensitive(source, pos, "line") and
        pos + 4 < source.len and
        isHorizontalSpace(source[pos + 4]))
    {
        pos += 4;
        while (pos < source.len and isHorizontalSpace(source[pos])) : (pos += 1) {}
    }

    const digits_start = pos;
    while (pos < source.len and std.ascii.isDigit(source[pos])) : (pos += 1) {}
    if (pos == digits_start) return null;

    const next_line = std.fmt.parseInt(usize, source[digits_start..pos], 10) catch return null;
    while (pos < source.len and isHorizontalSpace(source[pos])) : (pos += 1) {}

    if (pos >= source.len or source[pos] != '"') return null;
    pos += 1;
    const name_start = pos;
    while (pos < source.len and source[pos] != '"' and source[pos] != '\n') : (pos += 1) {
        if (source[pos] == '\\' and pos + 1 < source.len and source[pos + 1] != '\n') {
            pos += 1;
        }
    }
    if (pos >= source.len or source[pos] != '"') return null;
    const filename = source[name_start..pos];

    var after_eol = pos + 1;
    while (after_eol < source.len and source[after_eol] != '\n') : (after_eol += 1) {}
    if (after_eol < source.len and source[after_eol] == '\n') after_eol += 1;

    return .{
        .next_line = next_line,
        .filename = filename,
        .after_eol = after_eol,
    };
}

/// Invokes the pinned Zig compiler's integrated C preprocessor (`zig clang -E`) in
/// freestanding x86_64 `assembler-with-cpp` mode on a `.S` file. Fails closed on errors.
fn preprocessAssemblyFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    disk_input_path: []const u8,
    include_dirs: []const []const u8,
    log_on_error: bool,
) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.appendSlice(allocator, &.{
        build_options.zig_exe,
        "clang",
        "-E",
        "-ffreestanding",
        "--target=x86_64-freestanding-none",
        "-x",
        "assembler-with-cpp",
    });
    for (include_dirs) |inc| {
        try argv.appendSlice(allocator, &.{ "-I", inc });
    }
    try argv.append(allocator, disk_input_path);

    const result = try std.process.run(allocator, io, .{
        .argv = argv.items,
        .stdout_limit = .limited(16 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);

    if (!result.term.success()) {
        if (log_on_error) {
            std.debug.print(
                "PREPROCESSOR FAILED for {s} ({f}):\n{s}\n",
                .{ disk_input_path, result.term, result.stderr },
            );
        }
        return error.PreprocessorFailed;
    }

    return result.stdout;
}

fn scanPreprocessedAssemblyFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    hits: *std.ArrayList(ForbiddenIntHit),
    logical_path: []const u8,
    disk_input_path: []const u8,
    include_dirs: []const []const u8,
    log_on_error: bool,
) !void {
    const preprocessed = try preprocessAssemblyFile(allocator, io, disk_input_path, include_dirs, log_on_error);
    defer allocator.free(preprocessed);

    try scanAssemblyTextWithOptions(
        allocator,
        hits,
        logical_path,
        disk_input_path,
        1,
        true,
        true,
        preprocessed,
    );
}

/// Direct assembly scanner wrapper for `.s`/`.asm` sources and decoded Zig inline assembly.
fn scanAssemblyText(
    allocator: std.mem.Allocator,
    hits: *std.ArrayList(ForbiddenIntHit),
    file_path: []const u8,
    base_line: usize,
    advance_lines_on_newline: bool,
    source: []const u8,
) !void {
    return scanAssemblyTextWithOptions(
        allocator,
        hits,
        file_path,
        null,
        base_line,
        advance_lines_on_newline,
        false,
        source,
    );
}

/// Scans an assembly buffer (raw or preprocessed) for forbidden or unresolved `int <operand>`
/// instructions while skipping comments and data strings.
/// Fails closed whenever an `int` operand cannot be proven to resolve to an allowed vector.
fn scanAssemblyTextWithOptions(
    allocator: std.mem.Allocator,
    hits: *std.ArrayList(ForbiddenIntHit),
    file_path: []const u8,
    disk_input_path: ?[]const u8,
    base_line: usize,
    advance_lines_on_newline: bool,
    parse_linemarkers: bool,
    source: []const u8,
) !void {
    var constants: SymbolTable = .empty;
    defer deinitSymbolTable(allocator, &constants);

    var owned_active_file: ?[]u8 = null;
    defer if (owned_active_file) |buf| allocator.free(buf);
    var active_file: []const u8 = file_path;

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

        if (parse_linemarkers and i == line_start and source[i] == '#') {
            if (parseLinemarkerLine(source, i, line_start)) |lm| {
                line = lm.next_line;
                if (!std.mem.eql(u8, lm.filename, "<built-in>") and
                    !std.mem.eql(u8, lm.filename, "<command line>") and
                    !std.mem.eql(u8, lm.filename, "<stdin>"))
                {
                    const mapped_to_logical = if (disk_input_path) |dp| std.mem.eql(u8, lm.filename, dp) else false;
                    if (mapped_to_logical) {
                        active_file = file_path;
                    } else {
                        if (owned_active_file) |prev| {
                            allocator.free(prev);
                            owned_active_file = null;
                        }
                        owned_active_file = try allocator.dupe(u8, lm.filename);
                        active_file = owned_active_file.?;
                    }
                }
                i = lm.after_eol;
                line_start = lm.after_eol;
                continue;
            }
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

        // Track `.equ`, `.set`, and `.equiv` absolute constant definitions
        if (ch == '.') {
            if (try tryParseEquDirective(allocator, &constants, source, i)) |stmt_end| {
                i = stmt_end;
                continue;
            }
        }

        // Match whole mnemonic `int` followed by horizontal space and evaluate operand fail-closed
        if (matchesKeywordCaseInsensitive(source, i, "int") and
            i + 3 < source.len and
            isHorizontalSpace(source[i + 3]) and
            (i == 0 or !isIdentChar(source[i - 1])))
        {
            var op_start = i + 3;
            while (op_start < source.len and isHorizontalSpace(source[op_start])) : (op_start += 1) {}

            const stmt_end = findStatementEnd(source, op_start);
            const raw_operand = std.mem.trim(u8, source[op_start..stmt_end], " \t");

            var line_end = i;
            while (line_end < source.len and source[line_end] != '\n' and source[line_end] != '\r') : (line_end += 1) {}
            const raw_snippet = std.mem.trim(u8, source[line_start..line_end], " \t");

            if (resolveOperandValue(&constants, raw_operand)) |vec| {
                if (vectors.isForbiddenSoftwareIntVector(vec)) {
                    try appendHit(allocator, hits, active_file, line, .forbidden_vector, vec, raw_operand, raw_snippet);
                }
            } else {
                try appendHit(allocator, hits, active_file, line, .unresolved_operand, null, raw_operand, raw_snippet);
            }

            i = stmt_end;
            continue;
        }

        i += 1;
    }
}

/// Decodes a Zig single-line string literal (`"..."`), returning the decoded bytes and the index after closing `"`.
/// Supports `\n`, `\r`, `\t`, `\\`, `\"`, `\'`, `\xNN`, and `\u{...}` (encoded to UTF-8).
fn decodeZigStringLiteral(
    allocator: std.mem.Allocator,
    source: []const u8,
    after_open_quote: usize,
    decoded: *std.ArrayList(u8),
) !struct { next_index: usize, hit_newline: bool } {
    var i = after_open_quote;
    while (i < source.len) {
        if (source[i] == '\\' and i + 1 < source.len) {
            const esc = source[i + 1];
            switch (esc) {
                'n' => {
                    try decoded.append(allocator, '\n');
                    i += 2;
                },
                'r' => {
                    try decoded.append(allocator, '\r');
                    i += 2;
                },
                't' => {
                    try decoded.append(allocator, '\t');
                    i += 2;
                },
                '\\', '"', '\'' => {
                    try decoded.append(allocator, esc);
                    i += 2;
                },
                'x' => {
                    if (i + 3 < source.len) {
                        if (parseStrictDigits(u8, source[i + 2 .. i + 4], 16)) |byte| {
                            try decoded.append(allocator, byte);
                            i += 4;
                            continue;
                        }
                    }
                    try decoded.appendSlice(allocator, source[i .. i + 2]);
                    i += 2;
                },
                'u' => {
                    if (i + 2 < source.len and source[i + 2] == '{') {
                        var close = i + 3;
                        while (close < source.len and source[close] != '}' and source[close] != '"' and source[close] != '\n') : (close += 1) {}
                        if (close < source.len and source[close] == '}') {
                            const hex = source[i + 3 .. close];
                            if (parseStrictDigits(u21, hex, 16)) |cp| {
                                var utf8_buf: [4]u8 = undefined;
                                if (std.unicode.utf8Encode(cp, &utf8_buf)) |len| {
                                    try decoded.appendSlice(allocator, utf8_buf[0..len]);
                                    i = close + 1;
                                    continue;
                                } else |_| {}
                            }
                        }
                    }
                    try decoded.appendSlice(allocator, source[i .. i + 2]);
                    i += 2;
                },
                else => {
                    try decoded.append(allocator, esc);
                    i += 2;
                },
            }
            continue;
        }
        if (source[i] == '\n') {
            return .{ .next_index = i + 1, .hit_newline = true };
        }
        if (source[i] == '"') {
            return .{ .next_index = i + 1, .hit_newline = false };
        }
        try decoded.append(allocator, source[i]);
        i += 1;
    }
    return .{ .next_index = i, .hit_newline = false };
}

/// Scans a Zig source file, ignoring `//` comments and character literals while decoding
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

            const res = try decodeZigStringLiteral(allocator, source, i + 1, &decoded);
            i = res.next_index;
            if (res.hit_newline) line += 1;

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

fn hasScannedExtension(path: []const u8) enum { none, zig, asm_src, preprocessed_asm_src } {
    if (std.mem.endsWith(u8, path, ".zig")) return .zig;
    if (std.mem.endsWith(u8, path, ".S")) return .preprocessed_asm_src;
    if (std.mem.endsWith(u8, path, ".s") or std.mem.endsWith(u8, path, ".asm")) {
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

    try std.testing.expect(!vectors.isPicOffsetValid(0x08, 0x70));
    try std.testing.expect(!vectors.isPicOffsetValid(0x00, 0x08));
    try std.testing.expect(!vectors.isPicOffsetValid(0x18, 0x20));

    try std.testing.expect(!vectors.isPicOffsetValid(0x21, 0x28));
    try std.testing.expect(!vectors.isPicOffsetValid(0x20, 0x2C));

    try std.testing.expect(!vectors.isPicOffsetValid(0x20, 0x20));
    try std.testing.expect(!vectors.isPicOffsetValid(0x30, 0x30));

    try std.testing.expect(!vectors.isPicOffsetValid(0xFA, 0x20));
    try std.testing.expect(!vectors.isPicOffsetValid(0x20, 0xF9));
}

test "vectors 5: pure IDT kernel interrupt gate validator checks flags, IST reserved bits, reserved, selector, offset" {
    const cs: u16 = 0x28;
    const addr: u64 = 0xffffffff80001234;

    try std.testing.expect(vectors.isValidKernelInterruptGate(vectors.IDT_GATE_FLAGS_KERNEL_INTERRUPT, 0, 0, cs, cs, addr, addr));
    try std.testing.expect(vectors.isValidKernelInterruptGate(0x8E, 7, 0, cs, cs, addr, addr));

    try std.testing.expect(!vectors.isValidKernelInterruptGate(0xEE, 0, 0, cs, cs, addr, addr));
    try std.testing.expect(!vectors.isValidKernelInterruptGate(0xAE, 0, 0, cs, cs, addr, addr));
    try std.testing.expect(!vectors.isValidKernelInterruptGate(0x0E, 0, 0, cs, cs, addr, addr));
    try std.testing.expect(!vectors.isValidKernelInterruptGate(0x8F, 0, 0, cs, cs, addr, addr));
    try std.testing.expect(!vectors.isValidKernelInterruptGate(0x9E, 0, 0, cs, cs, addr, addr));

    try std.testing.expect(!vectors.isValidKernelInterruptGate(0x8E, 8, 0, cs, cs, addr, addr));
    try std.testing.expect(!vectors.isValidKernelInterruptGate(0x8E, 0, 1, cs, cs, addr, addr));
    try std.testing.expect(!vectors.isValidKernelInterruptGate(0x8E, 0, 0, 0x08, cs, addr, addr));
    try std.testing.expect(!vectors.isValidKernelInterruptGate(0x8E, 0, 0, cs, cs, addr + 4, addr));
}

test "scanner 1: assembly scanner detects forbidden INT n in decimal/hex/AT&T/Intel while ignoring comments and strings" {
    const gpa = std.testing.allocator;

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
    try std.testing.expectEqual(ViolationKind.forbidden_vector, bad_hits.items[0].kind);
    try std.testing.expectEqual(@as(?u8, 14), bad_hits.items[0].vector);

    try std.testing.expectEqual(@as(usize, 4), bad_hits.items[1].line);
    try std.testing.expectEqual(@as(?u8, 14), bad_hits.items[1].vector);

    try std.testing.expectEqual(@as(usize, 5), bad_hits.items[2].line);
    try std.testing.expectEqual(@as(?u8, 14), bad_hits.items[2].vector);

    try std.testing.expectEqual(@as(usize, 6), bad_hits.items[3].line);
    try std.testing.expectEqual(@as(?u8, 8), bad_hits.items[3].vector);

    try std.testing.expectEqual(@as(usize, 7), bad_hits.items[4].line);
    try std.testing.expectEqual(@as(?u8, 1), bad_hits.items[4].vector);
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
    try std.testing.expectEqual(@as(?u8, 14), bad_hits.items[0].vector);

    try std.testing.expectEqual(@as(usize, 5), bad_hits.items[1].line);
    try std.testing.expectEqual(@as(?u8, 13), bad_hits.items[1].vector);

    try std.testing.expectEqual(@as(usize, 7), bad_hits.items[2].line);
    try std.testing.expectEqual(@as(?u8, 8), bad_hits.items[2].vector);
}

test "scanner 3 (Finding A): resolves .equ/.set constants and fails closed on unresolved INT operands" {
    const gpa = std.testing.allocator;

    // 1. `.equ BAD_VECTOR, 14` followed by `int $BAD_VECTOR`
    const equ_bad =
        \\.equ BAD_VECTOR, 14
        \\int $BAD_VECTOR
    ;
    var equ_hits: std.ArrayList(ForbiddenIntHit) = .empty;
    defer deinitHits(gpa, &equ_hits);
    try scanAssemblyText(gpa, &equ_hits, "synthetic_equ.s", 1, true, equ_bad);
    try std.testing.expectEqual(@as(usize, 1), equ_hits.items.len);
    try std.testing.expectEqual(@as(usize, 2), equ_hits.items[0].line);
    try std.testing.expectEqual(ViolationKind.forbidden_vector, equ_hits.items[0].kind);
    try std.testing.expectEqual(@as(?u8, 14), equ_hits.items[0].vector);

    // 2. `.set BAD_VECTOR, 0x0e` followed by `int $BAD_VECTOR` (plus safe redefinition case)
    const set_bad =
        \\.set SAFE_VEC, 32
        \\int $SAFE_VEC
        \\.set BAD_VECTOR, 0x0e
        \\int $BAD_VECTOR
        \\.set SAFE_VEC, 14
        \\int $SAFE_VEC
    ;
    var set_hits: std.ArrayList(ForbiddenIntHit) = .empty;
    defer deinitHits(gpa, &set_hits);
    try scanAssemblyText(gpa, &set_hits, "synthetic_set.s", 1, true, set_bad);
    try std.testing.expectEqual(@as(usize, 2), set_hits.items.len);
    try std.testing.expectEqual(@as(usize, 4), set_hits.items[0].line);
    try std.testing.expectEqual(ViolationKind.forbidden_vector, set_hits.items[0].kind);
    try std.testing.expectEqual(@as(?u8, 14), set_hits.items[0].vector);
    try std.testing.expectEqual(@as(usize, 6), set_hits.items[1].line);
    try std.testing.expectEqual(@as(?u8, 14), set_hits.items[1].vector);

    // 3. Unresolved symbol/template/expression operands must fail closed
    const unresolved_asm =
        \\int $3
        \\int $32
        \\int $UNKNOWN_SYMBOL
        \\int UNKNOWN_INTEL_SYM
        \\int %[vec]
        \\int 14 + 0
    ;
    var unresolved_hits: std.ArrayList(ForbiddenIntHit) = .empty;
    defer deinitHits(gpa, &unresolved_hits);
    try scanAssemblyText(gpa, &unresolved_hits, "synthetic_unresolved.s", 1, true, unresolved_asm);
    try std.testing.expectEqual(@as(usize, 4), unresolved_hits.items.len);

    try std.testing.expectEqual(@as(usize, 3), unresolved_hits.items[0].line);
    try std.testing.expectEqual(ViolationKind.unresolved_operand, unresolved_hits.items[0].kind);
    try std.testing.expectEqual(@as(?u8, null), unresolved_hits.items[0].vector);

    try std.testing.expectEqual(@as(usize, 4), unresolved_hits.items[1].line);
    try std.testing.expectEqual(ViolationKind.unresolved_operand, unresolved_hits.items[1].kind);

    try std.testing.expectEqual(@as(usize, 5), unresolved_hits.items[2].line);
    try std.testing.expectEqual(ViolationKind.unresolved_operand, unresolved_hits.items[2].kind);

    try std.testing.expectEqual(@as(usize, 6), unresolved_hits.items[3].line);
    try std.testing.expectEqual(ViolationKind.unresolved_operand, unresolved_hits.items[3].kind);
}

test "scanner 4 (Finding B): Zig string escape decoding detects \\xNN and \\u{...} encoded INT vectors" {
    const gpa = std.testing.allocator;

    const escaped_zig =
        \\fn escapes() void {
        \\    asm volatile ("int $3");
        \\    asm volatile ("\x69\x6e\x74 \x24\x33");
        \\    asm volatile ("\x69nt $14");
        \\    asm volatile ("\u{69}nt $14");
        \\    asm volatile ("\x69\x6e\x74 $0x0e");
        \\    asm volatile ("\u{69}nt $UNKNOWN_ESC_SYM");
        \\}
    ;
    var hits: std.ArrayList(ForbiddenIntHit) = .empty;
    defer deinitHits(gpa, &hits);
    try scanZigSource(gpa, &hits, "synthetic_escapes.zig", escaped_zig);

    // Lines 2 and 3 decode to valid `int $3`; lines 4, 5, 6 decode to vector 14; line 7 fails closed.
    try std.testing.expectEqual(@as(usize, 4), hits.items.len);

    try std.testing.expectEqual(@as(usize, 4), hits.items[0].line);
    try std.testing.expectEqual(ViolationKind.forbidden_vector, hits.items[0].kind);
    try std.testing.expectEqual(@as(?u8, 14), hits.items[0].vector);

    try std.testing.expectEqual(@as(usize, 5), hits.items[1].line);
    try std.testing.expectEqual(ViolationKind.forbidden_vector, hits.items[1].kind);
    try std.testing.expectEqual(@as(?u8, 14), hits.items[1].vector);

    try std.testing.expectEqual(@as(usize, 6), hits.items[2].line);
    try std.testing.expectEqual(ViolationKind.forbidden_vector, hits.items[2].kind);
    try std.testing.expectEqual(@as(?u8, 14), hits.items[2].vector);

    try std.testing.expectEqual(@as(usize, 7), hits.items[3].line);
    try std.testing.expectEqual(ViolationKind.unresolved_operand, hits.items[3].kind);
    try std.testing.expectEqual(@as(?u8, null), hits.items[3].vector);
}

fn scanSyntheticPreprocessedS(
    allocator: std.mem.Allocator,
    io: std.Io,
    hits: *std.ArrayList(ForbiddenIntHit),
    filename: []const u8,
    source: []const u8,
    log_on_error: bool,
) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = source });

    const disk_path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}",
        .{ std.testing.TmpDir.parent_dir_path, tmp.sub_path, filename },
    );
    defer allocator.free(disk_path);

    try scanPreprocessedAssemblyFile(allocator, io, hits, filename, disk_path, &.{}, log_on_error);
}

test "scanner 5 (Finding F-03-R2): preprocessed .S scanner catches macro-expanded INTs, keeps line provenance, and skips unused macros" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    // 1. Object-like mnemonic alias expanding to forbidden vector 14
    {
        const src =
            \\#define INT_MNEMONIC int
            \\INT_MNEMONIC $14
            \\
        ;
        var hits: std.ArrayList(ForbiddenIntHit) = .empty;
        defer deinitHits(gpa, &hits);
        try scanSyntheticPreprocessedS(gpa, io, &hits, "obj_macro_bad.S", src, true);
        try std.testing.expectEqual(@as(usize, 1), hits.items.len);
        try std.testing.expectEqualStrings("obj_macro_bad.S", hits.items[0].file_path);
        try std.testing.expectEqual(@as(usize, 2), hits.items[0].line);
        try std.testing.expectEqual(ViolationKind.forbidden_vector, hits.items[0].kind);
        try std.testing.expectEqual(@as(?u8, 14), hits.items[0].vector);
    }

    // 2. Function-like macro expanding to forbidden vector 14
    {
        const src =
            \\#define ISSUE_INT(v) int $v
            \\nop
            \\ISSUE_INT(14)
            \\
        ;
        var hits: std.ArrayList(ForbiddenIntHit) = .empty;
        defer deinitHits(gpa, &hits);
        try scanSyntheticPreprocessedS(gpa, io, &hits, "fn_macro_bad.S", src, true);
        try std.testing.expectEqual(@as(usize, 1), hits.items.len);
        try std.testing.expectEqualStrings("fn_macro_bad.S", hits.items[0].file_path);
        try std.testing.expectEqual(@as(usize, 3), hits.items[0].line);
        try std.testing.expectEqual(ViolationKind.forbidden_vector, hits.items[0].kind);
        try std.testing.expectEqual(@as(?u8, 14), hits.items[0].vector);
    }

    // 3 & 4 & 5. Valid macro expansions (#BP 3, external 32), ordinary `#` comment, and uninvoked forbidden macro
    {
        const src =
            \\#define INT_MNEMONIC int
            \\#define UNUSED_BAD() int $14
            \\#define UNUSED_HEX int $0x0e
            \\# ordinary assembler comment: int $14
            \\# 16 ordinary numeric comment without filename quotes
            \\INT_MNEMONIC $3
            \\INT_MNEMONIC $32
            \\
        ;
        var hits: std.ArrayList(ForbiddenIntHit) = .empty;
        defer deinitHits(gpa, &hits);
        try scanSyntheticPreprocessedS(gpa, io, &hits, "macro_clean.S", src, true);
        try std.testing.expectEqual(@as(usize, 0), hits.items.len);
    }

    // 6. Preprocessor failure must fail closed rather than silently skipping the file
    {
        const broken =
            \\#error intentional preprocessor failure for negative test
            \\nop
            \\
        ;
        var hits: std.ArrayList(ForbiddenIntHit) = .empty;
        defer deinitHits(gpa, &hits);
        try std.testing.expectError(
            error.PreprocessorFailed,
            scanSyntheticPreprocessedS(gpa, io, &hits, "broken.S", broken, false),
        );
    }
}

test "scanner 6: live kernel/ source tree contains zero forbidden or unresolved software INT instructions" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var kernel_dir = try std.Io.Dir.cwd().openDir(io, build_options.kernel_dir, .{ .iterate = true });
    defer kernel_dir.close(io);

    var walker = try kernel_dir.walk(gpa);
    defer walker.deinit();

    var hits: std.ArrayList(ForbiddenIntHit) = .empty;
    defer deinitHits(gpa, &hits);

    const kernel_src_inc = try std.fmt.allocPrint(gpa, "{s}/src", .{build_options.kernel_dir});
    defer gpa.free(kernel_src_inc);
    const include_dirs = [_][]const u8{ build_options.kernel_dir, kernel_src_inc };

    var scanned_files: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const kind = hasScannedExtension(entry.basename);
        if (kind == .none) continue;

        scanned_files += 1;
        switch (kind) {
            .zig => {
                const contents = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(4 * 1024 * 1024));
                defer gpa.free(contents);
                try scanZigSource(gpa, &hits, entry.path, contents);
            },
            .asm_src => {
                const contents = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(4 * 1024 * 1024));
                defer gpa.free(contents);
                try scanAssemblyText(gpa, &hits, entry.path, 1, true, contents);
            },
            .preprocessed_asm_src => {
                const disk_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ build_options.kernel_dir, entry.path });
                defer gpa.free(disk_path);
                try scanPreprocessedAssemblyFile(gpa, io, &hits, entry.path, disk_path, &include_dirs, true);
            },
            .none => unreachable,
        }
    }

    try std.testing.expect(scanned_files > 0);
    if (hits.items.len > 0) {
        for (hits.items) |hit| {
            std.debug.print(
                "FORBIDDEN/UNRESOLVED SOFTWARE INT ({s}) at kernel/{s}:{d} (vector={?d}, operand='{s}'): {s}\n",
                .{ @tagName(hit.kind), hit.file_path, hit.line, hit.vector, hit.operand, hit.snippet },
            );
        }
    }
    try std.testing.expectEqual(@as(usize, 0), hits.items.len);
}
