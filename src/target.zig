//! The platforms zcaml builds for, and the one vocabulary for naming them: the
//! triples in its releases' archive names (`x86_64-linux-gnu`,
//! `aarch64-macos-none`, ...).
const std = @import("std");
const builtin = @import("builtin");

pub const Target = enum {
    @"x86_64-linux-gnu",
    @"aarch64-linux-gnu",
    @"riscv64-linux-gnu",
    @"powerpc64le-linux-gnu",
    @"s390x-linux-gnu",
    @"x86_64-linux-musl",
    @"aarch64-linux-musl",
    @"riscv64-linux-musl",
    @"powerpc64le-linux-musl",
    @"s390x-linux-musl",
    @"aarch64-macos-none",
    @"x86_64-macos-none",
    @"x86_64-windows-gnu",

    pub const all = std.enums.values(Target);

    pub const Arch = enum { x86_64, aarch64, riscv64, powerpc64le, s390x };
    pub const Os = enum { linux, macos, windows };
    pub const Abi = enum { gnu, musl, none };

    /// What `-t` takes: a triple, with or without its ABI (`aarch64-macos`,
    /// `x86_64-linux`: glibc), as dune's `-x` spells it (`x86_64_windows_gnu`), or
    /// with another common name for its architecture or OS (`arm64-darwin`).
    /// `native` is the caller's to resolve (`detectNative`).
    pub fn parse(text: []const u8) ?Target {
        for (all) |target| {
            if (std.mem.eql(u8, text, target.name()) or std.mem.eql(u8, text, target.duneName())) return target;
        }
        var fields = std.mem.splitScalar(u8, text, '-');
        const arch_text = fields.next() orelse return null;
        const os_text = fields.next() orelse return null;
        const abi_text = fields.next();
        if (fields.next() != null) return null;

        const target_arch = std.meta.stringToEnum(Arch, arch_text) orelse alias(Arch, &.{
            .{ "arm64", .aarch64 },
            .{ "amd64", .x86_64 },
            .{ "ppc64le", .powerpc64le },
        }, arch_text) orelse return null;
        const target_os = std.meta.stringToEnum(Os, os_text) orelse alias(Os, &.{
            .{ "darwin", .macos },
        }, os_text) orelse return null;
        const target_abi: Abi = if (abi_text) |a|
            std.meta.stringToEnum(Abi, a) orelse return null
        else switch (target_os) {
            .linux, .windows => .gnu,
            .macos => .none,
        };
        for (all) |target| {
            if (target.arch() == target_arch and target.os() == target_os and target.abi() == target_abi) return target;
        }
        return null;
    }

    /// This machine's target, if zcaml has one for it. Not this program's: a
    /// static one runs on glibc and musl systems alike, so the C library is the
    /// system's (as Zig finds it: `/usr/bin/env`'s).
    pub fn detectNative(io: std.Io) ?Target {
        const native = std.zig.system.resolveTargetQuery(io, .{}) catch builtin.target;
        return fromStd(&native);
    }

    pub fn fromStd(target: *const std.Target) ?Target {
        const target_arch: Arch = switch (target.cpu.arch) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
            .riscv64 => .riscv64,
            .powerpc64le => .powerpc64le,
            .s390x => .s390x,
            else => return null,
        };
        const target_os: Os, const target_abi: Abi = switch (target.os.tag) {
            .linux => .{ .linux, if (target.abi.isMusl()) .musl else if (target.abi.isGnu()) .gnu else return null },
            .macos => .{ .macos, .none },
            .windows => .{ .windows, .gnu },
            else => return null,
        };
        for (all) |t| {
            if (t.arch() == target_arch and t.os() == target_os and t.abi() == target_abi) return t;
        }
        return null;
    }

    /// The triple, as in the releases' archive names.
    pub fn name(target: Target) []const u8 {
        return @tagName(target);
    }

    /// The findlib toolchain `dune build -x` takes: the triple with `_` for `-`,
    /// which findlib's names can't have. The build context is `default.<this>`.
    pub fn duneName(target: Target) []const u8 {
        return switch (target) {
            inline else => |t| comptime blk: {
                var buf: [@tagName(t).len]u8 = @tagName(t)[0..].*;
                std.mem.replaceScalar(u8, &buf, '-', '_');
                const final = buf;
                break :blk &final;
            },
        };
    }

    pub fn arch(target: Target) Arch {
        return parts(target).arch;
    }

    pub fn os(target: Target) Os {
        return parts(target).os;
    }

    pub fn abi(target: Target) Abi {
        return parts(target).abi;
    }

    pub fn exeExt(target: Target) []const u8 {
        return if (target.os() == .windows) ".exe" else "";
    }

    /// The platform a lock directory's solution for this target is for, in opam's
    /// names: an entry of the workspace's `solve_for_platforms` and the lock's
    /// `solved_for_platforms`. zcaml's dune picks the solution by `arch` and `os`
    /// (build/dune/cross_pkg.ml); Windows' other variables are what opam's
    /// packages for it are conditional on.
    pub fn opamPlatform(target: Target) []const u8 {
        return switch (target) {
            inline else => |t| comptime std.fmt.comptimePrint("((arch {s}) (os {s}){s})", .{
                t.opamArch(),
                t.opamOs(),
                if (t.os() == .windows) " (sys-ocaml-arch x86_64) (sys-ocaml-cc cc) (sys-ocaml-libc msvc)" else "",
            }),
        };
    }

    pub fn opamArch(target: Target) []const u8 {
        return switch (target.arch()) {
            .x86_64 => "x86_64",
            .aarch64 => "arm64",
            .riscv64 => "riscv64",
            .powerpc64le => "ppc64",
            .s390x => "s390x",
        };
    }

    pub fn opamOs(target: Target) []const u8 {
        return switch (target.os()) {
            .linux => "linux",
            .macos => "macos",
            .windows => "win32",
        };
    }

    /// Whether dune's default `solve_for_platforms` covers this target: a project
    /// that doesn't set it has a lock for these only.
    pub fn inDuneDefaultPlatforms(target: Target) bool {
        return target.os() != .windows and (target.arch() == .x86_64 or target.arch() == .aarch64);
    }

    pub fn format(target: Target, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(target.name());
    }

    const Parts = struct { arch: Arch, os: Os, abi: Abi };

    fn parts(target: Target) Parts {
        return parts_table[@backingInt(target)];
    }

    const parts_table: [all.len]Parts = blk: {
        @setEvalBranchQuota(100_000);
        var table: [all.len]Parts = undefined;
        for (all) |target| {
            var it = std.mem.splitScalar(u8, @tagName(target), '-');
            table[@backingInt(target)] = .{
                .arch = std.meta.stringToEnum(Arch, it.next().?).?,
                .os = std.meta.stringToEnum(Os, it.next().?).?,
                .abi = std.meta.stringToEnum(Abi, it.next().?).?,
            };
        }
        break :blk table;
    };

    fn alias(comptime E: type, comptime table: []const struct { []const u8, E }, text: []const u8) ?E {
        inline for (table) |entry| {
            if (std.mem.eql(u8, text, entry[0])) return entry[1];
        }
        return null;
    }
};

test "canonical names round-trip" {
    for (Target.all) |target| {
        try std.testing.expectEqual(target, Target.parse(target.name()).?);
        try std.testing.expectEqual(target, Target.parse(target.duneName()).?);
    }
}

test "short forms and aliases" {
    try std.testing.expectEqual(Target.@"x86_64-linux-gnu", Target.parse("x86_64-linux").?);
    try std.testing.expectEqual(Target.@"aarch64-macos-none", Target.parse("aarch64-macos").?);
    try std.testing.expectEqual(Target.@"aarch64-macos-none", Target.parse("arm64-darwin").?);
    try std.testing.expectEqual(Target.@"x86_64-windows-gnu", Target.parse("amd64-windows").?);
    try std.testing.expectEqual(Target.@"powerpc64le-linux-musl", Target.parse("ppc64le-linux-musl").?);
    try std.testing.expectEqual(null, Target.parse("x86_64-windows-musl"));
    try std.testing.expectEqual(null, Target.parse("sparc-linux"));
    try std.testing.expectEqual(null, Target.parse("x86_64"));
    try std.testing.expectEqual(null, Target.parse("x86_64-linux-gnu-extra"));
}

test "names" {
    try std.testing.expectEqualStrings("x86_64_windows_gnu", Target.@"x86_64-windows-gnu".duneName());
    try std.testing.expectEqualStrings("((arch arm64) (os macos))", Target.@"aarch64-macos-none".opamPlatform());
    try std.testing.expectEqualStrings(
        "((arch x86_64) (os win32) (sys-ocaml-arch x86_64) (sys-ocaml-cc cc) (sys-ocaml-libc msvc))",
        Target.@"x86_64-windows-gnu".opamPlatform(),
    );
    try std.testing.expectEqualStrings(".exe", Target.@"x86_64-windows-gnu".exeExt());
}
