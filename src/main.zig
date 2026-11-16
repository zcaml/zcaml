const std = @import("std");
const clappy = @import("clappy");
const Cmd = @import("cmd/root.zig");

pub fn main(init: std.process.Init) !void {
    // Zig 0.17's `HostName.connect` (`std.http.Client`'s) tries a host's
    // addresses at once, and cancels the ones that lose. Once the pool has as
    // many busy threads as `async_limit` (one less than the CPUs), `async` runs a
    // task on the caller's thread, where a loser takes that cancelation and it's
    // gone: the rest aren't canceled, and the winner waits for them, for TCP's 2
    // minutes on one whose SYN went unanswered, till the server drops it.
    // zcaml's downloads, at once, keep the pool busy: an `async` task gets a thread.
    threaded(init.io).setAsyncLimit(.unlimited);

    try clappy.fmt.init(init);

    try Cmd.run(init);
}

/// The `Io` juicy main gives: start.zig's `Io.Threaded`.
fn threaded(io: std.Io) *std.Io.Threaded {
    const any: *std.Io.Threaded = undefined;
    std.debug.assert(io.vtable == any.io().vtable);
    return @ptrCast(@alignCast(io.userdata));
}

pub const std_options: std.Options = .{
    .logFn = clappy.fmt.logFn,
};

test {
    _ = @import("target.zig");
    _ = @import("Index.zig");
    _ = @import("minisign.zig");
    _ = @import("Store.zig");
    _ = @import("Environment.zig");
    _ = @import("sexp.zig");
    _ = @import("Project.zig");
    _ = @import("archive.zig");
    _ = @import("exec.zig");
    _ = @import("Runner.zig");
    _ = @import("Dist.zig");
}
