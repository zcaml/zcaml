//! `zcaml dist`: the project's executables, for each target, as archives.
const std = @import("std");
const clappy = @import("clappy");
const Dist = @import("../Dist.zig");

const Self = @This();

ocaml: []const u8,
target: []const []const u8 = &.{"native"},
package: []const []const u8 = &.{},
out: []const u8 = "dist",
name: ?[]const u8 = null,
version: ?[]const u8 = null,
profile: []const u8 = "release",
format: Dist.Options.Format = .auto,
@"test": []const []const u8 = &.{},
install_file: bool = false,

pub const clappy_config = clappy.cmd.Config(Self){
    .description = "Build the project for each target, and archive what its packages install",
    .values = .{
        .ocaml = .option(.{ .description = "The OCaml version, as the project's lock directory has it (5.5.1): its newest zcaml build, or one (5.5.1-13)" }),
        .target = .option(.{
            .names = &.{"-t"},
            .description = "Targets to build for, repeatable or comma separated",
            .delimiter = ',',
        }),
        .package = .option(.{
            .names = &.{"-p"},
            .description = "Packages whose files to archive, repeatable or comma separated [default: the project's]",
            .delimiter = ',',
        }),
        .out = .option(.{ .names = &.{"-o"}, .description = "The directory the archives go to" }),
        .name = .option(.{ .description = "The archives' name [default: dune-project's, or its only package's]" }),
        .version = .option(.{ .description = "The archives' version [default: dune-project's, or git's tag]" }),
        .profile = .option(.{ .description = "dune's build profile" }),
        .format = .option(.{ .description = "The archives' format; auto: zip for Windows, tar.gz for the others" }),
        .@"test" = .option(.{
            .description = "A command to run from each archive's bin/, which must succeed; repeatable",
        }),
        .install_file = .option(.{
            .description = "Add each package's <package>.install to the archives, for opam and dune to install them",
            .negate = .none,
        }),
    },
};

pub fn run(self: *const Self, init: std.process.Init) !void {
    return Dist.run(init, .{
        .ocaml = self.ocaml,
        .targets = self.target,
        .packages = self.package,
        .out = self.out,
        .name = self.name,
        .version = self.version,
        .profile = self.profile,
        .format = self.format,
        .tests = self.@"test",
        .install_file = self.install_file,
    });
}
