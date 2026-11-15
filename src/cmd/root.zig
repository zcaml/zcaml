const std = @import("std");
const clappy = @import("clappy");

const Self = @This();

command: union(enum) {
    // todo: not final yet
    doctor: @import("doctor.zig"),
    upgrade: @import("upgrade.zig"),
    target: struct {},
    env: struct {},
    shell: struct {},
},

pub const clappy_config = clappy.cmd.Config(Self){
    .description = "The zcaml toolchain manager for ocaml",
};

pub fn run(init: std.process.Init) !void {
    const args = try clappy.parse(Self, init, .{
        .name = "zcaml",
        .version = "0.0.1",
    });

    switch (args.command) {
        inline else => |c| {
            if (@hasDecl(@TypeOf(c), "run")) {
                try c.run(init);
            }
        },
    }
}
