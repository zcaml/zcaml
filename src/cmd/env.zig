//! `zcaml env`: the build environment, for the steps of a CI job (or a shell)
//! that run dune themselves.
const std = @import("std");
const clappy = @import("clappy");
const Environment = @import("../Environment.zig");
const Store = @import("../Store.zig");
const Index = @import("../Index.zig");

const log = std.log.scoped(.zcaml);

const Self = @This();

ocaml: []const u8,
target: []const []const u8 = &.{"native"},
github: bool = false,

pub const clappy_config = clappy.cmd.Config(Self){
    .description = "Install the toolchains for a build and print its environment",
    .values = .{
        .ocaml = .option(.{ .description = "The OCaml version, as the project's lock directory has it (5.5.1): its newest zcaml build, or one (5.5.1-13)" }),
        .target = .option(.{
            .names = &.{"-t"},
            .description = "Targets to build for, repeatable or comma separated",
            .delimiter = ',',
        }),
        .github = .option(.{
            .description = "Set it for a GitHub Actions job's next steps ($GITHUB_ENV, $GITHUB_PATH)",
            .negate = .none,
        }),
    },
};

pub fn run(self: *const Self, init: std.process.Init) !void {
    var store: Store = try .init(init);
    defer store.deinit();
    const index = try Index.load(&store);
    const selection = try Environment.resolve(init.arena.allocator(), init.io, &index, .{ .ocaml = self.ocaml, .targets = self.target });
    const env = try Environment.prepare(&store, selection);

    if (self.github) return writeGithub(&env, init);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const w = &stdout.interface;
    try w.writeAll("export PATH=");
    for (env.path) |dir| try w.print("{f}:", .{shQuote(dir)});
    try w.writeAll("\"$PATH\"\n");
    for (env.vars) |v| try w.print("export {s}={f}\n", .{ v.name, shQuote(v.value) });
    try w.writeAll("unset");
    for (env.unset) |name| try w.print(" {s}", .{name});
    try w.writeAll("\n");
    try w.flush();
}

/// A GitHub Actions job's later steps take their environment from the files
/// `$GITHUB_ENV` and `$GITHUB_PATH` name.
fn writeGithub(env: *const Environment, init: std.process.Init) !void {
    const io = init.io;
    const env_file = init.environ_map.get("GITHUB_ENV");
    const path_file = init.environ_map.get("GITHUB_PATH");
    if (env_file == null or path_file == null) {
        log.err("--github is for a GitHub Actions job: GITHUB_ENV and GITHUB_PATH aren't set", .{});
        return error.Reported;
    }
    // A job's variables can be set, not unset.
    var ok = true;
    for (env.unset) |name| if (init.environ_map.get(name)) |value| {
        ok = false;
        log.err("{s} is set ({s}): OCaml would use it instead of zcaml's toolchain. Remove it from the job's env.", .{ name, value });
    };
    if (!ok) return error.Reported;

    var content: std.Io.Writer.Allocating = .init(init.gpa);
    defer content.deinit();
    for (env.vars) |v| try content.writer.print("{s}={s}\n", .{ v.name, v.value });
    try append(io, env_file.?, content.written());

    // Each line goes ahead of the ones before it.
    content.clearRetainingCapacity();
    var i = env.path.len;
    while (i > 0) {
        i -= 1;
        try content.writer.print("{s}\n", .{env.path[i]});
    }
    try append(io, path_file.?, content.written());
}

fn append(io: std.Io, path: []const u8, data: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    var writer = file.writer(io, &.{});
    try writer.seekTo(try file.length(io));
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

fn shQuote(text: []const u8) std.fmt.Alt([]const u8, formatShQuote) {
    return .{ .data = text };
}

fn formatShQuote(text: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeByte('\'');
    for (text) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}
