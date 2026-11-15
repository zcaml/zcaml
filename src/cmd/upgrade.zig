const std = @import("std");
const clappy = @import("clappy");
const log = std.log.scoped(.zcaml);

const Self = @This();

pub const clappy_config = clappy.cmd.Config(Self){
    .description = "Upgrade zcaml to the latest version",
    .values = .{},
};

pub fn run(_: *const Self, _: std.process.Init) !void {
    log.info("{%blue,bold}Upgrading zcaml...{%}", .{});
}
