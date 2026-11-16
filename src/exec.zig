//! Running programs: a build's dune, a distribution's tests.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const log = std.log.scoped(.zcaml);

pub const Options = struct {
    /// `argv[0]`: a path, or a name looked up in `environ`'s `PATH`.
    argv: []const []const u8,
    environ: *const std.process.Environ.Map,
    cwd: std.process.Child.Cwd = .inherit,
    /// Its output goes to this process's standard error: standard output is
    /// zcaml's own.
    stdout_to_stderr: bool = false,
};

pub const Error = error{
    /// Reported: there's no such program, or it didn't start.
    Reported,
} || std.mem.Allocator.Error || Io.Cancelable;

/// Runs a program to its end, with this process's input and output.
pub fn run(arena: std.mem.Allocator, io: Io, options: Options) Error!std.process.Child.Term {
    const program = options.argv[0];
    const exe = try which(arena, io, options.environ.get("PATH") orelse "", program) orelse {
        log.err("there's no `{s}` on PATH", .{program});
        return error.Reported;
    };
    const argv = try arena.dupe([]const u8, options.argv);
    argv[0] = exe;
    var child = std.process.spawn(io, .{
        .argv = argv,
        .environ_map = options.environ,
        .cwd = options.cwd,
        .stdout = if (options.stdout_to_stderr) .{ .file = .stderr() } else .inherit,
    }) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => {
            log.err("running {s} failed: {t}", .{ exe, err });
            return error.Reported;
        },
    };
    return child.wait(io) catch |err| switch (err) {
        error.Canceled => |e| return e,
        else => {
            log.err("running {s} failed: {t}", .{ exe, err });
            return error.Reported;
        },
    };
}

/// The program `name` in `path` (a `PATH`): what a child with that `PATH` would
/// run. Spawning looks a program up in this process's.
pub fn which(arena: std.mem.Allocator, io: Io, path: []const u8, name: []const u8) std.mem.Allocator.Error!?[]const u8 {
    if (std.mem.findAny(u8, name, if (builtin.os.tag == .windows) "/\\" else "/") != null) return name;
    const extensions: []const []const u8 = if (builtin.os.tag == .windows) &.{ "", ".exe", ".cmd", ".bat" } else &.{""};
    var dirs = std.mem.tokenizeScalar(u8, path, std.fs.path.delimiter);
    while (dirs.next()) |dir| for (extensions) |ext| {
        const candidate = try std.fmt.allocPrint(arena, "{s}{c}{s}{s}", .{ dir, std.fs.path.sep, name, ext });
        const stat = Io.Dir.cwd().statFile(io, candidate, .{}) catch continue;
        if (stat.kind == .file) return candidate;
    };
    return null;
}

/// What a shell would show for how a program ended, if not with 0.
pub fn describe(term: std.process.Child.Term, buffer: []u8) []const u8 {
    return switch (term) {
        .exited => |code| std.fmt.bufPrint(buffer, "exited with {d}", .{code}),
        .signal => |sig| std.fmt.bufPrint(buffer, "was killed by signal {d}", .{@backingInt(sig)}),
        .stopped => |sig| std.fmt.bufPrint(buffer, "was stopped by signal {d}", .{@backingInt(sig)}),
        .unknown => |status| std.fmt.bufPrint(buffer, "ended with status {d}", .{status}),
    } catch "failed";
}

/// A command line as a shell splits it: words, with `'`, `"` and `\`.
pub fn splitCommand(arena: std.mem.Allocator, line: []const u8) error{ OutOfMemory, UnclosedQuote }![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        switch (c) {
            ' ', '\t', '\n' => if (in_word) {
                try words.append(arena, try word.toOwnedSlice(arena));
                in_word = false;
            },
            '\'' => {
                in_word = true;
                const end = std.mem.findScalarPos(u8, line, i + 1, '\'') orelse return error.UnclosedQuote;
                try word.appendSlice(arena, line[i + 1 .. end]);
                i = end;
            },
            '"' => {
                in_word = true;
                i += 1;
                while (i < line.len and line[i] != '"') : (i += 1) {
                    // In double quotes, `\` only escapes these.
                    if (line[i] == '\\' and i + 1 < line.len and std.mem.findScalar(u8, "\"\\$`", line[i + 1]) != null) i += 1;
                    try word.append(arena, line[i]);
                }
                if (i == line.len) return error.UnclosedQuote;
            },
            '\\' => {
                in_word = true;
                if (i + 1 < line.len) i += 1;
                try word.append(arena, line[i]);
            },
            else => {
                in_word = true;
                try word.append(arena, c);
            },
        }
    }
    if (in_word) try words.append(arena, try word.toOwnedSlice(arena));
    return words.items;
}

test splitCommand {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const words = try splitCommand(arena, "  hello --name 'a b'  \"c \\\"d\\\" \\n\" e\\ f '' ");
    try std.testing.expectEqual(6, words.len);
    try std.testing.expectEqualStrings("hello", words[0]);
    try std.testing.expectEqualStrings("--name", words[1]);
    try std.testing.expectEqualStrings("a b", words[2]);
    try std.testing.expectEqualStrings("c \"d\" \\n", words[3]);
    try std.testing.expectEqualStrings("e f", words[4]);
    try std.testing.expectEqualStrings("", words[5]);
    try std.testing.expectEqual(0, (try splitCommand(arena, "  ")).len);
    try std.testing.expectError(error.UnclosedQuote, splitCommand(arena, "a 'b"));
    try std.testing.expectError(error.UnclosedQuote, splitCommand(arena, "a \"b"));
}
