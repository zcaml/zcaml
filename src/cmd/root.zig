const std = @import("std");
const clappy = @import("clappy");

const Self = @This();

command: union(enum) {
    dist: @import("dist.zig"),
    run: @import("run.zig"),
    env: @import("env.zig"),
},

pub const clappy_config = clappy.cmd.Config(Self){
    .description = "Build dune pkg projects for other platforms, with zcaml's OCaml toolchains",
};

pub fn run(init: std.process.Init) !void {
    const args = try clappy.parse(Self, init, .{
        .name = "zcaml",
        .version = @import("build_options").version,
    });

    switch (args.command) {
        inline else => |c| c.run(init) catch |err| switch (@as(anyerror, err)) {
            // Reported where they happened.
            error.Reported, error.Unsupported, error.InstallFailed, error.IndexUnavailable => std.process.exit(1),
            else => |e| return e,
        },
    }
}
