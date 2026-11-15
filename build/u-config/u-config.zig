//! `skeeto`'s u-config, vendored and patched (see `README.md`): the host
//! `pkg-config` the toolchains install in `bin/`.
//!
//! ```zig
//! UConfig.addCheck(b, step);
//! const exe = UConfig.build(b, host);
//! UConfig.addInstall(b, step, host, sub_path);
//! ```
const std = @import("std");
const Platform = @import("../ocaml/platform.zig");

var exes: std.StringHashMapUnmanaged(*std.Build.Step.Compile) = .empty;

/// The patched u-config for `host` to run. Its OCAMLPATH change searches
/// `<entry>/<name>/pkgconfig` when `PKG_CONFIG_LIBDIR` is unset, which is where
/// dune pkg's dependencies install their `.pc` files.
pub fn build(b: *std.Build, host: Platform) *std.Build.Step.Compile {
    if (exes.get(host.triplet)) |exe| return exe;
    const windows = host.is_windows;
    const mod = b.createModule(.{
        .target = host.resolved,
        .optimize = .ReleaseSmall,
        .link_libc = !windows,
        .strip = true,
        // As upstream's mingw recipe: no unwind tables in the no-CRT image.
        .unwind_tables = if (windows) .none else null,
    });
    mod.addCSourceFile(.{
        .file = b.path(if (windows) "build/u-config/main_windows.c" else "build/u-config/main_posix.c"),
        .flags = if (windows) &.{
            // dune's `<lib>/<package>/pkgconfig` is one level deeper than
            // --define-prefix assumes.
            "-DPKG_CONFIG_DEFINE_PREFIX=0",
            "-fno-builtin",
        } else &.{},
    });
    const exe = b.addExecutable(.{ .name = "pkg-config", .root_module = mod });
    if (windows) {
        // No CRT: upstream's entry point, kernel32 only, and compiler-rt's
        // memset/memcpy plus the vendored wcslen. Zig-only, no system mingw.
        mod.addCSourceFile(.{ .file = b.path("build/u-config/win32_shim.c"), .flags = &.{} });
        mod.linkSystemLibrary("kernel32", .{});
        exe.entry = .{ .symbol_name = "mainCRTStartup" };
        exe.link_gc_sections = true;
    }
    exes.put(b.allocator, host.triplet, exe) catch @panic("OOM");
    return exe;
}

/// The build's Zig programs, for the build machine: `zig build check`.
pub fn addCheck(b: *std.Build, step: *std.Build.Step) void {
    step.dependOn(&build(b, .init(b, b.graph.host)).step);
}

/// Install `host`'s `pkg-config` and `pkg-config-zcaml` into `<sub_path>/bin`,
/// beside `ar` and `ranlib`. A copy of one binary, as for the binutils wrappers.
pub fn addInstall(b: *std.Build, step: *std.Build.Step, host: Platform, sub_path: []const u8) void {
    const exe = build(b, host).getEmittedBin();
    const ext = host.exeExt();
    step.dependOn(&b.addInstallFileWithDir(exe, .prefix, b.fmt("{s}/bin/pkg-config{s}", .{ sub_path, ext })).step);
    step.dependOn(&b.addInstallFileWithDir(exe, .prefix, b.fmt("{s}/bin/pkg-config-zcaml{s}", .{ sub_path, ext })).step);
}
