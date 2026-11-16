//! What a dune pkg project's build needs from this machine, and nothing of the
//! project's: zcaml's dune and the OCaml toolchains for the targets, on `PATH`
//! and as findlib toolchains (`dune build -x <target>`), with the Zig they
//! compile C with. The project's own settings (its lock directory, repositories,
//! `solve_for_platforms`) stay dune's.
const Environment = @This();

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Store = @import("Store.zig");
const exec = @import("exec.zig");
const Index = @import("Index.zig");
const Target = @import("target.zig").Target;

const log = std.log.scoped(.zcaml);

release: *const Index.Ocaml,
/// This machine: the default context's builds are for it.
host: Target,
/// Every target, the host's among them or not, without duplicates.
targets: []const Target,
dune_exe: []const u8,
zig_exe: []const u8,
/// The host's own toolchain: the default context's compiler, the lock
/// directory's `ocaml-system`.
native_toolchain: []const u8,
/// `OCAMLFIND_CONF`: the toolchains `-x` takes.
findlib_conf: []const u8,
/// Directories that go first on `PATH`, in order.
path: []const []const u8,
/// Variables to set.
vars: []const Var,
/// Variables that must not be set: they'd point OCaml at another installation.
unset: []const []const u8 = &.{ "OCAMLLIB", "CAMLLIB", "OCAMLPATH", "OCAMLFIND_TOOLCHAIN" },

pub const Var = struct { name: []const u8, value: []const u8 };

pub const Options = struct {
    /// The OCaml version: `x.y.z`, its newest revision, or `x.y.z-<revision>`.
    ocaml: []const u8,
    /// What `-t` took: targets' names, or `native`.
    targets: []const []const u8,
};

/// What a build is with and for: `Options`, checked against the index.
pub const Selection = struct {
    release: *const Index.Ocaml,
    dune: *const Index.Dune,
    zig: *const Index.Zig,
    macos_sdk: *const Index.MacosSdk,
    /// This machine.
    host: Target,
    /// Without duplicates, in the order they were asked for.
    targets: []const Target,
};

pub const ResolveError = error{
    /// Reported: the index has no OCaml of that version, or not for this
    /// machine or a target.
    Unsupported,
} || std.mem.Allocator.Error;

/// Checks `options`, reporting everything that's wrong with them. It installs
/// nothing: a build's other checks come before `prepare`.
pub fn resolve(arena: std.mem.Allocator, io: Io, index: *const Index, options: Options) ResolveError!Selection {
    var ok = true;
    const release = index.ocamlRelease(options.ocaml) orelse release: {
        ok = false;
        log.err("zcaml has no OCaml {s}: it has {s}", .{ options.ocaml, try releaseList(arena, index) });
        break :release null;
    };
    const host = Target.detectNative(io) orelse {
        log.err("zcaml has no toolchains that run on this machine ({s}-{s})", .{
            @tagName(builtin.cpu.arch), @tagName(builtin.os.tag),
        });
        return error.Unsupported;
    };
    var targets: std.ArrayList(Target) = .empty;
    for (options.targets) |text| {
        const target = if (std.mem.eql(u8, text, "native")) host else Target.parse(text) orelse {
            ok = false;
            log.err("unknown target '{s}': zcaml's are {s}, and native", .{ text, try targetList(arena) });
            continue;
        };
        if (std.mem.findScalar(Target, targets.items, target) == null) try targets.append(arena, target);
    }
    if (release) |r| {
        if (r.archive(host, host) == null) {
            ok = false;
            log.err("zcaml's OCaml {s} has no toolchain that runs on {t}", .{ r.version, host });
        } else for (targets.items) |target| {
            if (r.archive(host, target) != null) continue;
            ok = false;
            log.err("zcaml's OCaml {s} has no toolchain on {t} that compiles for {t}", .{ r.version, host, target });
        }
    }
    const dune = index.latestDune();
    if (dune == null or dune.?.archive(host) == null) {
        ok = false;
        log.err("zcaml has no dune for {t}", .{host});
    }
    if (!ok) return error.Unsupported;
    log.info("OCaml {s}-{d}, dune {s}", .{ release.?.version, release.?.revision, dune.?.version });
    return .{
        .release = release.?,
        .dune = dune.?,
        .zig = index.zigRelease(release.?.zig),
        .macos_sdk = index.macosSdk(release.?.macos_sdk),
        .host = host,
        .targets = targets.items,
    };
}

/// "5.5.1 (revisions 13, 12), 5.4.0 (revision 1)".
fn releaseList(arena: std.mem.Allocator, index: *const Index) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    for (index.ocaml, 0..) |release, i| {
        // The newest first: a version's revisions are together.
        const first = i == 0 or !std.mem.eql(u8, index.ocaml[i - 1].version, release.version);
        const last = i + 1 == index.ocaml.len or !std.mem.eql(u8, index.ocaml[i + 1].version, release.version);
        if (first) try list.print(arena, "{s}{s} (revision", .{ if (i == 0) "" else ", ", release.version });
        if (first and !last) try list.append(arena, 's');
        try list.print(arena, "{s}{d}", .{ if (first) " " else ", ", release.revision });
        if (last) try list.append(arena, ')');
    }
    return if (list.items.len == 0) "none" else list.items;
}

pub const Error = Store.Error || std.process.RunError;

/// Installs what `selection` needs into `store`, if it isn't there.
pub fn prepare(store: *Store, selection: Selection) Error!Environment {
    const arena = store.arena;
    const host = selection.host;
    const release = selection.release;
    const targets = selection.targets;
    if (builtin.os.tag == .windows and !windows.RtlAreLongPathsEnabled().toBool()) log.warn(
        \\Windows' long paths are off: dune pkg builds a project's packages in directories
        \\whose paths can be longer than 260 characters, and those builds fail. To turn them
        \\on, as an administrator:
        \\
        \\  reg add HKLM\SYSTEM\CurrentControlSet\Control\FileSystem /v LongPathsEnabled /t REG_DWORD /d 1 /f
    , .{});

    // `resolve` checked zcaml ships them.
    var installs: std.ArrayList(Store.Install) = .empty;
    const dune = store.dune(selection.dune, host) catch |err| return notShipped(err);
    const native = store.ocaml(release, host, host) catch |err| return notShipped(err);
    try installs.appendSlice(arena, &.{ dune, native });
    const native_toolchain = native.dir;
    var cross: std.ArrayList(Toolchain) = .empty;
    for (targets) |target| {
        if (target == host) continue;
        const toolchain = store.ocaml(release, host, target) catch |err| return notShipped(err);
        try installs.append(arena, toolchain);
        try cross.append(arena, .{ .target = target, .dir = toolchain.dir });
    }

    var path: std.ArrayList([]const u8) = .empty;
    var vars: std.ArrayList(Var) = .empty;
    try path.append(arena, try std.fs.path.join(arena, &.{ dune.dir, "bin" }));
    try path.append(arena, try std.fs.path.join(arena, &.{ native_toolchain, "bin" }));
    for (cross.items) |toolchain| try path.append(arena, try std.fs.path.join(arena, &.{ toolchain.dir, "bin" }));

    const zig_exe = try findZig(store, selection.zig.version) orelse zig: {
        const zig = store.zig(selection.zig, host) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            error.NotShipped => {
                log.err("zcaml has no Zig for {t}: put Zig {s} on PATH, or in $ZIG", .{ host, selection.zig.version });
                return error.InstallFailed;
            },
        };
        try installs.append(arena, zig);
        break :zig try std.fs.path.join(arena, &.{ zig.dir, try exeName(arena, "zig", host) });
    };
    try vars.append(arena, .{ .name = "ZIG", .value = zig_exe });

    const findlib_conf = try store.generated("findlib.conf", try findlibConf(arena, native_toolchain, cross.items));
    try vars.append(arena, .{ .name = "OCAMLFIND_CONF", .value = findlib_conf });

    // On a Mac, Xcode's (or the Command Line Tools'). One the user set stays.
    const needs_sdk = host.os() != .macos and for (targets) |target| {
        if (target.os() == .macos) break true;
    } else false;
    if (needs_sdk and store.environ.get("ZCAML_MACOS_SDK") == null) {
        const sdk = try store.macosSdk(selection.macos_sdk);
        try installs.append(arena, sdk);
        try vars.append(arena, .{ .name = "ZCAML_MACOS_SDK", .value = sdk.dir });
    }

    try store.install(installs.items);

    return .{
        .release = release,
        .host = host,
        .targets = targets,
        .dune_exe = try std.fs.path.join(arena, &.{ dune.dir, "bin", try exeName(arena, "dune", host) }),
        .zig_exe = zig_exe,
        .native_toolchain = native_toolchain,
        .findlib_conf = findlib_conf,
        .path = path.items,
        .vars = vars.items,
    };
}

const windows = struct {
    /// Whether this process takes paths longer than `MAX_PATH`: the system's
    /// LongPathsEnabled, and zcaml's manifest (src/windows.manifest).
    extern "ntdll" fn RtlAreLongPathsEnabled() callconv(.winapi) std.os.windows.BOOLEAN;
};

/// `parent`'s environment, with this one's on top: a build's or a test's.
pub fn environMap(env: *const Environment, gpa: std.mem.Allocator, parent: *const std.process.Environ.Map) !std.process.Environ.Map {
    var map = try parent.clone(gpa);
    errdefer map.deinit();
    for (env.unset) |name| _ = map.swapRemove(name);
    for (env.vars) |v| try map.put(v.name, v.value);
    const new_path = try env.pathValue(gpa, parent.get("PATH"));
    defer gpa.free(new_path);
    try map.put("PATH", new_path);
    return map;
}

/// `PATH`, with this environment's directories ahead of `old`'s.
pub fn pathValue(env: *const Environment, gpa: std.mem.Allocator, old: ?[]const u8) ![]u8 {
    var value: std.ArrayList(u8) = .empty;
    errdefer value.deinit(gpa);
    for (env.path) |dir| {
        if (value.items.len != 0) try value.append(gpa, std.fs.path.delimiter);
        try value.appendSlice(gpa, dir);
    }
    if (old) |o| if (o.len != 0) {
        try value.append(gpa, std.fs.path.delimiter);
        try value.appendSlice(gpa, o);
    };
    return value.toOwnedSlice(gpa);
}

const Toolchain = struct { target: Target, dir: []const u8 };

/// The toolchains as findlib's configuration: the host's is the default, each
/// target's is the toolchain `-x <target.duneName()>` takes.
fn findlibConf(arena: std.mem.Allocator, native: []const u8, cross: []const Toolchain) ![]const u8 {
    var conf: std.Io.Writer.Allocating = .init(arena);
    const w = &conf.writer;
    writeToolchain(w, null, native) catch return error.OutOfMemory;
    for (cross) |toolchain| writeToolchain(w, toolchain.target, toolchain.dir) catch return error.OutOfMemory;
    return conf.written();
}

fn writeToolchain(w: *std.Io.Writer, target: ?Target, dir: []const u8) !void {
    // `path(<toolchain>)`: findlib's own syntax for a toolchain's variable.
    var suffix_buffer: [64]u8 = undefined;
    const suffix = if (target) |t| try std.fmt.bufPrint(&suffix_buffer, "({s})", .{t.duneName()}) else "";
    const exe = if (builtin.os.tag == .windows) ".exe" else "";
    try w.print("path{s}=\"{f}/lib/ocaml\"\n", .{ suffix, confPath(dir) });
    if (target != null) try w.print("destdir{s}=\"{f}/lib/ocaml\"\n", .{ suffix, confPath(dir) });
    for ([_][]const u8{ "ocamlc", "ocamlopt", "ocamldep" }) |tool| {
        try w.print("{s}{s}=\"{f}/bin/{s}.opt{s}\"\n", .{ tool, suffix, confPath(dir), tool, exe });
    }
    try w.print("ocamlmklib{s}=\"{f}/bin/ocamlmklib{s}\"\n", .{ suffix, confPath(dir), exe });
}

/// A path in findlib.conf's quotes: `\` is an escape there, and Windows takes `/`.
fn confPath(path: []const u8) std.fmt.Alt([]const u8, formatConfPath) {
    return .{ .data = path };
}

fn formatConfPath(path: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (path) |c| try w.writeByte(if (c == '\\') '/' else c);
}

/// The Zig the toolchains were built with, if `$ZIG` or `PATH`'s is that
/// version: otherwise, the store's is.
fn findZig(store: *Store, wanted: []const u8) Error!?[]const u8 {
    const arena = store.arena;
    const io = store.io;
    const candidate: ?[]const u8 = store.environ.get("ZIG") orelse
        try exec.which(arena, io, store.environ.get("PATH") orelse "", "zig");
    if (candidate) |zig| version: {
        const result = std.process.run(arena, io, .{ .argv = &.{ zig, "version" } }) catch break :version;
        const version = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (result.term.success() and std.mem.eql(u8, version, wanted)) return zig;
        log.info("{s} is Zig {s}, not the {s} zcaml's toolchains are built with", .{ zig, version, wanted });
    }
    return null;
}

/// For what `resolve` checked zcaml ships.
fn notShipped(err: Store.ResolveError) std.mem.Allocator.Error {
    return switch (err) {
        error.OutOfMemory => |e| e,
        error.NotShipped => unreachable,
    };
}

fn targetList(arena: std.mem.Allocator) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    for (Target.all, 0..) |target, i| try list.print(arena, "{s}{t}", .{ if (i == 0) "" else ", ", target });
    return list.items;
}

fn exeName(arena: std.mem.Allocator, name: []const u8, host: Target) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}{s}", .{ name, host.exeExt() });
}

test releaseList {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqualStrings("5.5.1 (revisions 13, 12)", try releaseList(arena_state.allocator(), &Index.testing));
}

test findlibConf {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const conf = try findlibConf(arena_state.allocator(), "/store/native", &.{
        .{ .target = .@"x86_64-windows-gnu", .dir = "/store/windows" },
    });
    try std.testing.expectEqualStrings(
        \\path="/store/native/lib/ocaml"
        \\ocamlc="/store/native/bin/ocamlc.opt"
        \\ocamlopt="/store/native/bin/ocamlopt.opt"
        \\ocamldep="/store/native/bin/ocamldep.opt"
        \\ocamlmklib="/store/native/bin/ocamlmklib"
        \\path(x86_64_windows_gnu)="/store/windows/lib/ocaml"
        \\destdir(x86_64_windows_gnu)="/store/windows/lib/ocaml"
        \\ocamlc(x86_64_windows_gnu)="/store/windows/bin/ocamlc.opt"
        \\ocamlopt(x86_64_windows_gnu)="/store/windows/bin/ocamlopt.opt"
        \\ocamldep(x86_64_windows_gnu)="/store/windows/bin/ocamldep.opt"
        \\ocamlmklib(x86_64_windows_gnu)="/store/windows/bin/ocamlmklib"
        \\
    , conf);
}
