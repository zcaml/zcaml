const std = @import("std");
const clappy = @import("clappy");
const log = std.log.scoped(.@"zcaml doctor");

const Self = @This();

fix: bool = false,

pub const clappy_config = clappy.cmd.Config(Self){
    .description = "Check the zcaml environment",
    .values = .{
        .fix = .option(.{
            .names = &.{"-f"},
            .description = "Attempt to fix the environment",
        }),
    },
};

pub fn run(self: *const Self, _: std.process.Init) !void {
    if (self.fix) {
        log.info("{%blue}Checking environment...{%}", .{});
    } else {
        log.info("{%green,b}[✓]{%} Zig (0.17.0) is installed", .{});
    }
}
