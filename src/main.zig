const std = @import("std");
const clappy = @import("clappy");
const Cmd = @import("cmd/root.zig");

pub fn main(init: std.process.Init) !void {
    try clappy.fmt.init(init);

    try Cmd.run(init);
}

pub const std_options: std.Options = .{
    .logFn = clappy.fmt.logFn,
};
