//! How this machine runs an executable that may be another's: as it is, under
//! Wine, or under QEMU with the target's libraries. From the file itself, not
//! from what it was built for: `zcaml run` takes any executable.
const Runner = @This();

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const exec = @import("exec.zig");
const Target = @import("target.zig").Target;
const Arch = Target.Arch;

/// What goes before the executable on the command line.
prefix: []const []const u8 = &.{},
/// Variables to set, unless they are.
vars: []const Var = &.{},

pub const Var = struct { name: []const u8, value: []const u8 };

pub const Plan = union(enum) {
    run: Runner,
    /// This machine can't run it, whatever is installed: why.
    impossible: []const u8,
    /// It could, with what this says to install.
    missing: []const u8,
};

pub const Error = error{
    /// Reported: the file can't be read.
    Reported,
} || std.mem.Allocator.Error || Io.Cancelable;

/// How to run the file `exe`.
pub fn plan(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, exe: []const u8) Error!Plan {
    const binary = inspect(arena, io, exe) catch |err| switch (err) {
        error.OutOfMemory, error.Canceled => |e| return e,
        else => {
            std.log.scoped(.zcaml).err("reading {s} failed: {t}", .{ exe, err });
            return error.Reported;
        },
    };
    return planFor(arena, io, environ, exe, binary, this_machine);
}

/// The least any executable built for `target` needs to run here: Wine, QEMU.
/// Before there's one to look at, so not the libraries a dynamically linked one
/// needs as well.
pub fn planTarget(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, target: Target) std.mem.Allocator.Error!Plan {
    const binary: Binary = switch (target.os()) {
        .windows => .pe,
        .macos => .{ .macho = target.arch() },
        .linux => .{ .elf = .{ .arch = target.arch(), .interpreter = null } },
    };
    const subject = try std.fmt.allocPrint(arena, "{t}'s executables", .{target});
    return planFor(arena, io, environ, subject, binary, this_machine);
}

const this_machine: Machine = .{ .os = builtin.os.tag, .arch = hostArch() };

const Machine = struct { os: std.Target.Os.Tag, arch: ?Arch };

/// `subject`: what's run, as a message names it.
fn planFor(
    arena: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    subject: []const u8,
    binary: Binary,
    machine: Machine,
) std.mem.Allocator.Error!Plan {
    const path = environ.get("PATH") orelse "";
    switch (binary) {
        .other => return .{ .run = .{} },
        .pe => {
            if (machine.os == .windows) return .{ .run = .{} };
            const wine = try exec.which(arena, io, path, "wine") orelse return .{ .missing = try std.fmt.allocPrint(arena,
                \\running {s} here takes Wine, and there's no `wine` on PATH.
                \\Debian, Ubuntu: `apt-get install wine`. macOS: `brew install --cask wine-stable`.
            , .{subject}) };
            return .{
                .run = .{
                    .prefix = try arena.dupe([]const u8, &.{wine}),
                    // Wine's own messages: every missing driver of a machine with no display.
                    .vars = &.{.{ .name = "WINEDEBUG", .value = "-all" }},
                },
            };
        },
        .macho => |arch| {
            if (machine.os != .macos) return .{ .impossible = try std.fmt.allocPrint(arena, "running {s} takes a Mac", .{subject}) };
            const thin = arch orelse return .{ .run = .{} };
            if (thin == machine.arch) return .{ .run = .{} };
            if (thin == .aarch64) return .{ .impossible = try std.fmt.allocPrint(arena, "running {s} takes a Mac with Apple silicon", .{subject}) };
            if (!exists(io, "/Library/Apple/usr/libexec/oah/libRosettaRuntime")) return .{ .missing = try std.fmt.allocPrint(arena,
                \\running {s} here takes Rosetta, which isn't installed:
                \\`softwareupdate --install-rosetta --agree-to-license`.
            , .{subject}) };
            return .{ .run = .{} };
        },
        .elf => |elf| {
            if (machine.os != .linux) return .{ .impossible = try std.fmt.allocPrint(arena, "running {s} takes Linux", .{subject}) };
            const arch = elf.arch orelse return .{ .run = .{} };
            const foreign = arch != machine.arch;

            // Where its loader is: this machine's own root, or another's (QEMU's
            // `-L`), which then holds its libraries too.
            const root: []const u8 = if (elf.interpreter) |interpreter| root: {
                var candidates: [3][]const u8 = undefined;
                var n: usize = 0;
                candidates[n] = "";
                n += 1;
                if (environ.get("QEMU_LD_PREFIX")) |prefix| if (prefix.len != 0) {
                    candidates[n] = prefix;
                    n += 1;
                };
                candidates[n] = crossLibcRoot(arch);
                n += 1;
                for (candidates[0..n]) |candidate| {
                    if (exists(io, try std.fmt.allocPrint(arena, "{s}{s}", .{ candidate, interpreter }))) break :root candidate;
                }
                const musl = std.mem.startsWith(u8, std.fs.path.basename(interpreter), "ld-musl-");
                const install: ?[]const u8 = if (musl and !foreign)
                    "musl"
                else if (!musl and foreign)
                    try std.fmt.allocPrint(arena, "libc6-{s}-cross", .{debianArch(arch)})
                else
                    null;
                return .{ .missing = try std.fmt.allocPrint(arena,
                    \\running {s} here takes {s}, {t}'s {s} loader, which this machine doesn't have.
                    \\{s} QEMU_LD_PREFIX to a directory that has it and its libraries ({s}).
                , .{
                    subject,
                    interpreter,
                    arch,
                    if (musl) "musl" else "glibc",
                    if (install) |package|
                        try std.fmt.allocPrint(arena, "Debian, Ubuntu: `apt-get install {s}`. Elsewhere, set", .{package})
                    else
                        "Set",
                    if (musl) "Alpine's root file system" else "a root file system",
                }) };
            } else "";

            if (!foreign and root.len == 0) return .{ .run = .{} };
            const qemu_name = try std.fmt.allocPrint(arena, "qemu-{s}", .{qemuArch(arch)});
            const qemu = try exec.which(arena, io, path, qemu_name) orelse return .{ .missing = try std.fmt.allocPrint(arena,
                \\running {s} here{s} takes QEMU's user emulation, and there's no `{s}` on PATH.
                \\Debian, Ubuntu: `apt-get install qemu-user`.
            , .{
                subject,
                if (foreign) "" else try std.fmt.allocPrint(arena, ", with the libraries of {s},", .{root}),
                qemu_name,
            }) };
            return .{ .run = .{
                .prefix = if (root.len == 0)
                    try arena.dupe([]const u8, &.{qemu})
                else
                    try arena.dupe([]const u8, &.{ qemu, "-L", root }),
            } };
        },
    }
}

/// The command that runs `exe` with `args`.
pub fn argv(runner: *const Runner, arena: std.mem.Allocator, exe: []const u8, args: []const []const u8) ![]const []const u8 {
    // A name alone would be looked up in `PATH`.
    const file = if (std.fs.path.dirname(exe) == null) try std.fs.path.join(arena, &.{ ".", exe }) else exe;
    return std.mem.concat(arena, []const u8, &.{ runner.prefix, &.{file}, args });
}

/// `parent`'s environment, with what the runner needs.
pub fn environMap(runner: *const Runner, gpa: std.mem.Allocator, parent: *const std.process.Environ.Map) !std.process.Environ.Map {
    var map = try parent.clone(gpa);
    errdefer map.deinit();
    for (runner.vars) |v| {
        if (map.get(v.name) == null) try map.put(v.name, v.value);
    }
    return map;
}

pub const Binary = union(enum) {
    elf: Elf,
    /// Null: a universal binary, or another architecture's.
    macho: ?Arch,
    pe,
    /// A script, or what this machine knows better how to run.
    other,

    pub const Elf = struct {
        /// Null: not one zcaml has a target for.
        arch: ?Arch,
        /// The loader it asks for (`PT_INTERP`): null if it's static.
        interpreter: ?[]const u8,
    };
};

/// What kind of executable the file `path` is, from its header.
pub fn inspect(arena: std.mem.Allocator, io: Io, path: []const u8) !Binary {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return inspectReader(arena, &reader);
}

fn inspectReader(arena: std.mem.Allocator, reader: *Io.File.Reader) !Binary {
    const r = &reader.interface;
    const head = r.peek(64) catch |err| switch (err) {
        error.EndOfStream => return .other,
        else => |e| return e,
    };

    if (std.mem.eql(u8, head[0..4], "\x7fELF")) {
        // 64-bit only: zcaml's targets.
        if (head[4] != 2) return .{ .elf = .{ .arch = null, .interpreter = null } };
        const endian: std.builtin.Endian = if (head[5] == 2) .big else .little;
        const machine = std.mem.readInt(u16, head[18..20], endian);
        const arch: ?Arch = switch (machine) {
            62 => .x86_64,
            183 => .aarch64,
            243 => .riscv64,
            21 => if (endian == .little) .powerpc64le else null,
            22 => .s390x,
            else => null,
        };
        const phoff = std.mem.readInt(u64, head[32..40], endian);
        const phentsize = std.mem.readInt(u16, head[54..56], endian);
        const phnum = std.mem.readInt(u16, head[56..58], endian);
        if (phentsize < 56) return .{ .elf = .{ .arch = arch, .interpreter = null } };
        for (0..phnum) |i| {
            try reader.seekTo(phoff + i * phentsize);
            const header = r.take(56) catch break;
            if (std.mem.readInt(u32, header[0..4], endian) != 3) continue; // PT_INTERP
            const offset = std.mem.readInt(u64, header[8..16], endian);
            const size = std.mem.readInt(u64, header[32..40], endian);
            if (size == 0 or size > Io.Dir.max_path_bytes) break;
            try reader.seekTo(offset);
            const interpreter = try r.readAlloc(arena, size);
            return .{ .elf = .{ .arch = arch, .interpreter = std.mem.trimEnd(u8, interpreter, "\x00") } };
        }
        return .{ .elf = .{ .arch = arch, .interpreter = null } };
    }

    // Mach-O, 64-bit; or universal (which a Java class file starts like, with
    // more "architectures" than any binary has).
    if (std.mem.eql(u8, head[0..4], "\xcf\xfa\xed\xfe")) {
        return .{ .macho = switch (std.mem.readInt(u32, head[4..8], .little)) {
            0x0100_0007 => .x86_64,
            0x0100_000c => .aarch64,
            else => null,
        } };
    }
    if (std.mem.eql(u8, head[0..4], "\xca\xfe\xba\xbe") and std.mem.readInt(u32, head[4..8], .big) < 20) return .{ .macho = null };

    if (std.mem.eql(u8, head[0..2], "MZ")) {
        const pe_offset = std.mem.readInt(u32, head[60..64], .little);
        try reader.seekTo(pe_offset);
        const signature = r.take(4) catch return .other;
        if (std.mem.eql(u8, signature, "PE\x00\x00")) return .pe;
    }
    return .other;
}

fn hostArch() ?Arch {
    return switch (builtin.cpu.arch) {
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        .riscv64 => .riscv64,
        .powerpc64le => .powerpc64le,
        .s390x => .s390x,
        else => null,
    };
}

/// QEMU's name for an architecture: `qemu-<this>`.
fn qemuArch(arch: Arch) []const u8 {
    return switch (arch) {
        .powerpc64le => "ppc64le",
        else => @tagName(arch),
    };
}

/// Debian's name for an architecture.
fn debianArch(arch: Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .riscv64 => "riscv64",
        .powerpc64le => "ppc64el",
        .s390x => "s390x",
    };
}

/// Where Debian's and Ubuntu's `libc6-<arch>-cross` puts another
/// architecture's glibc.
fn crossLibcRoot(arch: Arch) []const u8 {
    return switch (arch) {
        inline else => |a| "/usr/" ++ @tagName(a) ++ "-linux-gnu",
    };
}

fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

const TestMachine = struct {
    tmp: std.testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    environ: std.process.Environ.Map,
    root: []const u8,

    /// A machine whose `PATH` has `programs`.
    fn init(programs: []const []const u8) !TestMachine {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        errdefer arena.deinit();
        var buffer: [Io.Dir.max_path_bytes]u8 = undefined;
        const root = try arena.allocator().dupe(u8, buffer[0..try tmp.dir.realPath(io, &buffer)]);
        try tmp.dir.createDirPath(io, "bin");
        for (programs) |program| {
            try tmp.dir.writeFile(io, .{ .sub_path = try std.fs.path.join(arena.allocator(), &.{ "bin", program }), .data = "" });
        }
        var environ: std.process.Environ.Map = .init(std.testing.allocator);
        errdefer environ.deinit();
        try environ.put("PATH", try std.fs.path.join(arena.allocator(), &.{ root, "bin" }));
        return .{ .tmp = tmp, .arena = arena, .environ = environ, .root = root };
    }

    fn deinit(machine: *TestMachine) void {
        machine.environ.deinit();
        machine.arena.deinit();
        machine.tmp.cleanup();
    }

    fn plan(machine: *TestMachine, binary: Binary, os: std.Target.Os.Tag, arch: Arch) !Plan {
        return planFor(machine.arena.allocator(), std.testing.io, &machine.environ, "hello", binary, .{ .os = os, .arch = arch });
    }
};

test "this machine's executables run as they are" {
    var machine: TestMachine = try .init(&.{});
    defer machine.deinit();
    try std.testing.expectEqual(0, (try machine.plan(.other, .linux, .x86_64)).run.prefix.len);
    try std.testing.expectEqual(0, (try machine.plan(.pe, .windows, .x86_64)).run.prefix.len);
    try std.testing.expectEqual(0, (try machine.plan(.{ .macho = .aarch64 }, .macos, .aarch64)).run.prefix.len);
    try std.testing.expectEqual(0, (try machine.plan(.{ .macho = null }, .macos, .x86_64)).run.prefix.len);
    const static: Binary = .{ .elf = .{ .arch = .x86_64, .interpreter = null } };
    try std.testing.expectEqual(0, (try machine.plan(static, .linux, .x86_64)).run.prefix.len);
}

test "what a machine can't run" {
    var machine: TestMachine = try .init(&.{});
    defer machine.deinit();
    const elf: Binary = .{ .elf = .{ .arch = .x86_64, .interpreter = null } };
    try std.testing.expect((try machine.plan(elf, .macos, .aarch64)) == .impossible);
    try std.testing.expect((try machine.plan(elf, .windows, .x86_64)) == .impossible);
    try std.testing.expect((try machine.plan(.{ .macho = .aarch64 }, .linux, .aarch64)) == .impossible);
    try std.testing.expect((try machine.plan(.{ .macho = .aarch64 }, .macos, .x86_64)) == .impossible);
}

test "Windows executables run under Wine" {
    var without: TestMachine = try .init(&.{});
    defer without.deinit();
    try std.testing.expect((try without.plan(.pe, .linux, .x86_64)) == .missing);

    var with: TestMachine = try .init(&.{"wine"});
    defer with.deinit();
    const runner = (try with.plan(.pe, .macos, .aarch64)).run;
    try std.testing.expectEqual(1, runner.prefix.len);
    try std.testing.expect(std.mem.endsWith(u8, runner.prefix[0], "/bin/wine"));
    try std.testing.expectEqualStrings("WINEDEBUG", runner.vars[0].name);
}

test "Linux executables of another architecture or libc run under QEMU" {
    const io = std.testing.io;
    var machine: TestMachine = try .init(&.{"qemu-aarch64"});
    defer machine.deinit();
    const static: Binary = .{ .elf = .{ .arch = .aarch64, .interpreter = null } };
    const glibc: Binary = .{ .elf = .{ .arch = .aarch64, .interpreter = "/lib/ld-linux-aarch64.so.1" } };
    const musl: Binary = .{ .elf = .{ .arch = .x86_64, .interpreter = "/lib/ld-musl-x86_64.so.1" } };

    // A static one needs no libraries.
    var runner = (try machine.plan(static, .linux, .x86_64)).run;
    try std.testing.expectEqual(1, runner.prefix.len);
    try std.testing.expect(std.mem.endsWith(u8, runner.prefix[0], "/bin/qemu-aarch64"));

    // The others, their loader: from QEMU_LD_PREFIX.
    if (!exists(io, "/lib/ld-linux-aarch64.so.1") and !exists(io, "/usr/aarch64-linux-gnu/lib/ld-linux-aarch64.so.1")) {
        const missing = (try machine.plan(glibc, .linux, .x86_64)).missing;
        try std.testing.expect(std.mem.find(u8, missing, "apt-get install libc6-arm64-cross") != null);
    }
    try machine.tmp.dir.createDirPath(io, "sysroot/lib");
    try machine.tmp.dir.writeFile(io, .{ .sub_path = "sysroot/lib/ld-linux-aarch64.so.1", .data = "" });
    try machine.tmp.dir.writeFile(io, .{ .sub_path = "sysroot/lib/ld-musl-x86_64.so.1", .data = "" });
    const sysroot = try std.fs.path.join(machine.arena.allocator(), &.{ machine.root, "sysroot" });
    try machine.environ.put("QEMU_LD_PREFIX", sysroot);
    if (!exists(io, "/lib/ld-linux-aarch64.so.1")) {
        runner = (try machine.plan(glibc, .linux, .x86_64)).run;
        try std.testing.expectEqual(3, runner.prefix.len);
        try std.testing.expectEqualStrings("-L", runner.prefix[1]);
        try std.testing.expectEqualStrings(sysroot, runner.prefix[2]);
    }

    // This architecture's musl, on a machine without it: QEMU too, for its `-L`.
    if (!exists(io, "/lib/ld-musl-x86_64.so.1")) {
        try std.testing.expect((try machine.plan(musl, .linux, .x86_64)) == .missing);
        try machine.tmp.dir.writeFile(io, .{ .sub_path = "bin/qemu-x86_64", .data = "" });
        runner = (try machine.plan(musl, .linux, .x86_64)).run;
        try std.testing.expectEqual(3, runner.prefix.len);
        try std.testing.expect(std.mem.endsWith(u8, runner.prefix[0], "/bin/qemu-x86_64"));
    }
}

test inspect {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const Case = struct {
        fn inspectBytes(a: std.mem.Allocator, dir: Io.Dir, bytes: []const u8) !Binary {
            try dir.writeFile(std.testing.io, .{ .sub_path = "exe", .data = bytes });
            const file = try dir.openFile(std.testing.io, "exe", .{});
            defer file.close(std.testing.io);
            var buffer: [256]u8 = undefined;
            var reader = file.reader(std.testing.io, &buffer);
            return inspectReader(a, &reader);
        }
    };

    try std.testing.expect((try Case.inspectBytes(arena, tmp.dir, "#!/bin/sh\necho hi\n")) == .other);
    try std.testing.expect((try Case.inspectBytes(arena, tmp.dir, "")) == .other);

    // An ELF header, one program header (PT_INTERP) and the loader's path.
    var elf: [64 + 56 + 32]u8 = @splat(0);
    @memcpy(elf[0..4], "\x7fELF");
    elf[4] = 2;
    elf[5] = 1;
    std.mem.writeInt(u16, elf[18..20], 183, .little);
    std.mem.writeInt(u64, elf[32..40], 64, .little);
    std.mem.writeInt(u16, elf[54..56], 56, .little);
    std.mem.writeInt(u16, elf[56..58], 1, .little);
    std.mem.writeInt(u32, elf[64..68], 3, .little);
    std.mem.writeInt(u64, elf[72..80], 120, .little);
    const interpreter = "/lib/ld-musl-aarch64.so.1\x00";
    std.mem.writeInt(u64, elf[96..104], interpreter.len, .little);
    @memcpy(elf[120..][0..interpreter.len], interpreter);
    const dynamic = (try Case.inspectBytes(arena, tmp.dir, &elf)).elf;
    try std.testing.expectEqual(Arch.aarch64, dynamic.arch.?);
    try std.testing.expectEqualStrings("/lib/ld-musl-aarch64.so.1", dynamic.interpreter.?);

    // s390x: big-endian, and static.
    var s390x: [64]u8 = @splat(0);
    @memcpy(s390x[0..4], "\x7fELF");
    s390x[4] = 2;
    s390x[5] = 2;
    std.mem.writeInt(u16, s390x[18..20], 22, .big);
    const static = (try Case.inspectBytes(arena, tmp.dir, &s390x)).elf;
    try std.testing.expectEqual(Arch.s390x, static.arch.?);
    try std.testing.expectEqual(null, static.interpreter);

    var macho: [64]u8 = @splat(0);
    @memcpy(macho[0..4], "\xcf\xfa\xed\xfe");
    std.mem.writeInt(u32, macho[4..8], 0x0100_000c, .little);
    try std.testing.expectEqual(Arch.aarch64, (try Case.inspectBytes(arena, tmp.dir, &macho)).macho.?);

    var pe: [128]u8 = @splat(0);
    @memcpy(pe[0..2], "MZ");
    std.mem.writeInt(u32, pe[60..64], 100, .little);
    @memcpy(pe[100..104], "PE\x00\x00");
    try std.testing.expect((try Case.inspectBytes(arena, tmp.dir, &pe)) == .pe);
}
