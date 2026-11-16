//! `zcaml run`: an executable built for another platform, on this machine.
const std = @import("std");
const clappy = @import("clappy");
const Runner = @import("../Runner.zig");
const exec = @import("../exec.zig");

const log = std.log.scoped(.zcaml);

const Self = @This();

exe: []const u8,
args: []const []const u8 = &.{},

pub const clappy_config = clappy.cmd.Config(Self){
    .description = "Run an executable built for another platform: under Wine or QEMU, as it needs",
    .values = .{
        .exe = .positional(.{ .description = "The executable: a file, or a program on PATH" }),
        .args = .rest(.{ .description = "Its arguments" }),
    },
};

pub fn run(self: *const Self, init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    // A file here, as a shell's `./exe`, or a program on `PATH`.
    const exe = exe: {
        if (std.fs.path.dirname(self.exe) != null) break :exe self.exe;
        if (std.Io.Dir.cwd().statFile(io, self.exe, .{})) |stat| {
            if (stat.kind == .file) break :exe self.exe;
        } else |_| {}
        break :exe try exec.which(arena, io, init.environ_map.get("PATH") orelse "", self.exe) orelse {
            log.err("there's no {s} here, nor on PATH", .{self.exe});
            return error.Reported;
        };
    };

    const runner = switch (try Runner.plan(arena, io, init.environ_map, exe)) {
        .run => |runner| runner,
        .impossible, .missing => |why| {
            log.err("{s}", .{why});
            return error.Reported;
        },
    };
    var environ = try runner.environMap(init.gpa, init.environ_map);
    defer environ.deinit();
    const term = try exec.run(arena, io, .{ .argv = try runner.argv(arena, exe, self.args), .environ = &environ });
    switch (term) {
        .exited => |code| std.process.exit(code),
        // As a shell reports it.
        .signal, .stopped => |signal| std.process.exit(@truncate(128 + @as(u32, @intCast(@backingInt(signal))))),
        .unknown => std.process.exit(1),
    }
}
