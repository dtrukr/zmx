const std = @import("std");
const builtin = @import("builtin");
const lib_posix = @import("posix.zig");

/// Self-pipe woken by signal handlers. std.posix.poll loops on .INTR internally
/// (PollError has no Interrupted member), so a signal that lands during poll()
/// never surfaces; the handler writes a byte here and poll() wakes on POLLIN.
pub var sig_pipe: [2]lib_posix.fd_t = .{ -1, -1 };

pub fn wakeSignalPipe(_: lib_posix.SIG, _: *const lib_posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const saved = std.c._errno().*;
    _ = std.c.write(sig_pipe[1], "x", 1);
    std.c._errno().* = saved;
}

// std.posix.poll retries EINTR internally, so SA_RESTART is moot -- neither
// setting wakes the loop. The handler writes to sig_pipe instead; poll()
// wakes on its read end.
pub fn installWakeHandler(sig: u6) void {
    const act: lib_posix.Sigaction = .{
        .handler = .{ .sigaction = wakeSignalPipe },
        .mask = lib_posix.sigemptyset(),
        .flags = lib_posix.SA.SIGINFO,
    };
    lib_posix.sigaction(@as(lib_posix.SIG, @enumFromInt(sig)), &act, null);
}

pub fn ignoreSigpipe() void {
    const act: lib_posix.Sigaction = .{
        .handler = .{ .handler = lib_posix.SIG.IGN },
        .mask = lib_posix.sigemptyset(),
        .flags = 0,
    };
    lib_posix.sigaction(lib_posix.SIG.PIPE, &act, null);
}

pub fn openSignalPipe() !void {
    sig_pipe = try lib_posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
}

pub fn drainSignalPipe() void {
    var b: [16]u8 = undefined;
    while (true) {
        const n = lib_posix.read(sig_pipe[0], &b) catch return;
        if (n == 0) return;
    }
}

/// One delivered signal and who sent it, as the daemon's handler records it.
pub const Event = extern struct {
    sig: i32,
    pid: i32,
    uid: u32,
};

fn senderOf(info: *const lib_posix.siginfo_t) struct { pid: i32, uid: u32 } {
    if (builtin.os.tag == .linux) {
        const p = info.fields.common.first.piduid;
        return .{ .pid = @intCast(p.pid), .uid = @intCast(p.uid) };
    }
    return .{ .pid = @intCast(info.pid), .uid = @intCast(info.uid) };
}

pub fn reportSignalPipe(sig: lib_posix.SIG, info: *const lib_posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const saved = std.c._errno().*;
    const sender = senderOf(info);
    const event = Event{ .sig = @intCast(@intFromEnum(sig)), .pid = sender.pid, .uid = sender.uid };
    // Smaller than PIPE_BUF, so the write is atomic and records never interleave.
    _ = std.c.write(sig_pipe[1], @ptrCast(&event), @sizeOf(Event));
    std.c._errno().* = saved;
}

/// Like `installWakeHandler`, but the pipe carries an `Event` per signal so
/// the loop can tell who sent it. A handler (not SIG_IGN) is used on purpose:
/// handlers reset to the default on exec, so programs the daemon starts do
/// not inherit an ignored signal.
pub fn installReportingHandler(sig: lib_posix.SIG) void {
    const act: lib_posix.Sigaction = .{
        .handler = .{ .sigaction = reportSignalPipe },
        .mask = lib_posix.sigemptyset(),
        .flags = lib_posix.SA.SIGINFO,
    };
    lib_posix.sigaction(sig, &act, null);
}

/// Reads the next recorded signal, or null when the pipe is empty.
pub fn readSignalEvent() ?Event {
    var event: Event = undefined;
    const n = lib_posix.read(sig_pipe[0], std.mem.asBytes(&event)) catch return null;
    if (n != @sizeOf(Event)) return null;
    return event;
}

/// Signals that would otherwise end a session daemon. Its sessions outlive
/// stray `pkill`/`killall` runs: only `zmx kill` ends a session, plus SIGTERM
/// from pid 1 (launchd or systemd shutting the machine down). SIGKILL cannot
/// be caught, so `kill -9` still ends it.
pub const daemon_guarded_signals = [_]lib_posix.SIG{
    lib_posix.SIG.TERM,
    lib_posix.SIG.HUP,
    lib_posix.SIG.INT,
    lib_posix.SIG.QUIT,
    lib_posix.SIG.USR1,
    lib_posix.SIG.USR2,
};

/// Whether a signal the daemon received should shut the session down.
pub fn daemonShouldStop(event: Event) bool {
    return event.sig == @as(i32, @intCast(@intFromEnum(lib_posix.SIG.TERM))) and event.pid == 1;
}

test "daemon stops only on SIGTERM from pid 1" {
    const term: i32 = @intCast(@intFromEnum(lib_posix.SIG.TERM));
    const hup: i32 = @intCast(@intFromEnum(lib_posix.SIG.HUP));
    try std.testing.expect(daemonShouldStop(.{ .sig = term, .pid = 1, .uid = 0 }));
    try std.testing.expect(!daemonShouldStop(.{ .sig = term, .pid = 4242, .uid = 501 }));
    try std.testing.expect(!daemonShouldStop(.{ .sig = hup, .pid = 1, .uid = 0 }));
}
