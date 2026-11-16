//! Dune's S-expressions, as much as reading a project's `dune-project`,
//! `dune-workspace` and lock directory takes: atoms, quoted strings, lists and
//! `;` comments.
const std = @import("std");

pub const Value = union(enum) {
    atom: []const u8,
    list: []const Value,

    /// The atom's text, or null for a list.
    pub fn text(value: Value) ?[]const u8 {
        return switch (value) {
            .atom => |a| a,
            .list => null,
        };
    }

    /// The list's items, or none for an atom.
    pub fn items(value: Value) []const Value {
        return switch (value) {
            .atom => &.{},
            .list => |l| l,
        };
    }

    /// Whether this is `(<name> ...)`.
    pub fn is(value: Value, name: []const u8) bool {
        const l = value.items();
        if (l.len == 0) return false;
        return if (l[0].text()) |head| std.mem.eql(u8, head, name) else false;
    }

    /// The arguments of this list's first `(<name> ...)` field.
    pub fn field(value: Value, name: []const u8) ?[]const Value {
        return fieldOf(value.items(), name);
    }

    /// The one atom of this list's `(<name> <atom>)` field.
    pub fn fieldText(value: Value, name: []const u8) ?[]const u8 {
        const args = value.field(name) orelse return null;
        return if (args.len == 1) args[0].text() else null;
    }

    pub fn format(value: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (value) {
            .atom => |a| if (needsQuotes(a)) try w.print("\"{f}\"", .{std.zig.fmtString(a)}) else try w.writeAll(a),
            .list => |l| {
                try w.writeByte('(');
                for (l, 0..) |item, i| {
                    if (i != 0) try w.writeByte(' ');
                    try item.format(w);
                }
                try w.writeByte(')');
            },
        }
    }
};

/// The arguments of `values`' first `(<name> ...)`: a file's stanza, or a
/// stanza's field.
pub fn fieldOf(values: []const Value, name: []const u8) ?[]const Value {
    for (values) |value| {
        if (value.is(name)) return value.items()[1..];
    }
    return null;
}

pub const Error = error{
    /// With `Diagnostic` filled in.
    InvalidSexp,
} || std.mem.Allocator.Error;

pub const Diagnostic = struct {
    line: usize = 0,
    message: []const u8 = "",
};

/// A file's values. They point into `source` and `arena`.
pub fn parse(arena: std.mem.Allocator, source: []const u8, diagnostic: *Diagnostic) Error![]const Value {
    var parser: Parser = .{ .arena = arena, .source = source, .diagnostic = diagnostic };
    var values: std.ArrayList(Value) = .empty;
    while (true) {
        parser.skipBlank();
        if (parser.pos == source.len) return values.items;
        if (source[parser.pos] == ')') return parser.fail("a ')' without its '('");
        try values.append(arena, try parser.value());
    }
}

const Parser = struct {
    arena: std.mem.Allocator,
    source: []const u8,
    diagnostic: *Diagnostic,
    pos: usize = 0,

    fn value(p: *Parser) Error!Value {
        switch (p.source[p.pos]) {
            '(' => {
                const open = p.pos;
                p.pos += 1;
                var list: std.ArrayList(Value) = .empty;
                while (true) {
                    p.skipBlank();
                    if (p.pos == p.source.len) {
                        p.pos = open;
                        return p.fail("a '(' without its ')'");
                    }
                    if (p.source[p.pos] == ')') {
                        p.pos += 1;
                        return .{ .list = list.items };
                    }
                    try list.append(p.arena, try p.value());
                }
            },
            '"' => return .{ .atom = try p.quoted() },
            else => {
                const start = p.pos;
                while (p.pos < p.source.len) : (p.pos += 1) switch (p.source[p.pos]) {
                    ' ', '\t', '\r', '\n', 0x0c, '(', ')', '"', ';' => break,
                    else => {},
                };
                return .{ .atom = p.source[start..p.pos] };
            },
        }
    }

    fn quoted(p: *Parser) Error![]const u8 {
        const open = p.pos;
        p.pos += 1;
        // `"\|` and `"\>`: the rest of the line, as it is.
        if (std.mem.startsWith(u8, p.source[p.pos..], "\\|") or std.mem.startsWith(u8, p.source[p.pos..], "\\>")) {
            const start = p.pos + 2;
            p.pos = std.mem.findScalarPos(u8, p.source, start, '\n') orelse p.source.len;
            return p.source[start..p.pos];
        }
        var out: std.ArrayList(u8) = .empty;
        while (p.pos < p.source.len) {
            const c = p.source[p.pos];
            p.pos += 1;
            switch (c) {
                '"' => return out.items,
                '\\' => {
                    if (p.pos == p.source.len) break;
                    const e = p.source[p.pos];
                    p.pos += 1;
                    switch (e) {
                        'n' => try out.append(p.arena, '\n'),
                        't' => try out.append(p.arena, '\t'),
                        'r' => try out.append(p.arena, '\r'),
                        'b' => try out.append(p.arena, 0x08),
                        '\n' => while (p.pos < p.source.len and (p.source[p.pos] == ' ' or p.source[p.pos] == '\t')) : (p.pos += 1) {},
                        'x' => try out.append(p.arena, try p.escapedByte(2, 16)),
                        '0'...'9' => {
                            p.pos -= 1;
                            try out.append(p.arena, try p.escapedByte(3, 10));
                        },
                        // `\%{`: a `%{` that isn't a variable. Kept, as dune's own
                        // files have it.
                        '%' => try out.appendSlice(p.arena, "\\%"),
                        else => try out.append(p.arena, e),
                    }
                },
                else => try out.append(p.arena, c),
            }
        }
        p.pos = open;
        return p.fail("a string without its closing '\"'");
    }

    fn escapedByte(p: *Parser, digits: usize, base: u8) Error!u8 {
        if (p.pos + digits > p.source.len) return p.fail("a cut-off escape in a string");
        const byte = std.fmt.parseInt(u8, p.source[p.pos..][0..digits], base) catch return p.fail("an invalid escape in a string");
        p.pos += digits;
        return byte;
    }

    fn skipBlank(p: *Parser) void {
        while (p.pos < p.source.len) switch (p.source[p.pos]) {
            ' ', '\t', '\r', '\n', 0x0c => p.pos += 1,
            ';' => p.pos = std.mem.findScalarPos(u8, p.source, p.pos, '\n') orelse p.source.len,
            else => return,
        };
    }

    fn fail(p: *Parser, message: []const u8) Error {
        p.diagnostic.* = .{
            .line = 1 + std.mem.count(u8, p.source[0..p.pos], "\n"),
            .message = message,
        };
        return error.InvalidSexp;
    }
};

fn needsQuotes(atom: []const u8) bool {
    if (atom.len == 0) return true;
    for (atom) |c| switch (c) {
        ' ', '\t', '\r', '\n', 0x0c, '(', ')', '"', ';', '\\' => return true,
        else => {},
    };
    return false;
}

test parse {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostic: Diagnostic = .{};

    const values = try parse(arena,
        \\(lang dune 3.24) ; a comment
        \\(lock_dir
        \\ (solve_for_platforms
        \\  ((arch x86_64) (os linux))
        \\  ((arch arm64) (os "macos"))))
        \\(name "a \"b\"\n\x41\066")
    , &diagnostic);
    try std.testing.expectEqual(3, values.len);
    try std.testing.expectEqualStrings("3.24", fieldOf(values, "lang").?[1].atom);
    const platforms = values[1].field("solve_for_platforms").?;
    try std.testing.expectEqual(2, platforms.len);
    try std.testing.expectEqualStrings("arm64", platforms[1].fieldText("arch").?);
    try std.testing.expectEqualStrings("macos", platforms[1].fieldText("os").?);
    try std.testing.expectEqualStrings("a \"b\"\nAB", fieldOf(values, "name").?[0].atom);
    try std.testing.expectEqual(null, values[1].field("repositories"));

    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "((arch arm64) (os macos))",
        try std.fmt.bufPrint(&buffer, "{f}", .{platforms[1]}),
    );
}

test "errors have the line" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var diagnostic: Diagnostic = .{};
    try std.testing.expectError(error.InvalidSexp, parse(arena_state.allocator(), "(a)\n\n(b (c)\n", &diagnostic));
    try std.testing.expectEqual(3, diagnostic.line);
    try std.testing.expectError(error.InvalidSexp, parse(arena_state.allocator(), "(a)\n)", &diagnostic));
    try std.testing.expectEqual(2, diagnostic.line);
}
