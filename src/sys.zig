//! Thin Linux syscall helpers shared by all modules.
//!
//! Since Zig 0.16 file, process, sleep and logging APIs go through `std.Io`.
//! Pulling in the default `std.Io` implementation adds ~200 KB to the static
//! binary, which matters on small routers, so gctd talks to the kernel
//! directly instead. Everything here is async-signal/fork safe and
//! allocation-free.
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const empty_env = [_:null]?[*:0]const u8{};

/// Environment passed to spawned processes; set in main().
pub var envp: [*:null]const ?[*:0]const u8 = &empty_env;

fn failed(rc: usize) bool {
    return linux.errno(rc) != .SUCCESS;
}

// ---------------------------------------------------------------- time

pub fn sleepNs(ns: u64) void {
    var req = linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: linux.timespec = undefined;
    while (linux.errno(linux.nanosleep(&req, &rem)) == .INTR) req = rem;
}

// ---------------------------------------------------------------- stdio / log

pub fn writeFd(fd: linux.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        switch (linux.errno(rc)) {
            .SUCCESS => off += rc,
            .INTR => continue,
            else => return,
        }
    }
}

pub fn writeStdout(bytes: []const u8) void {
    writeFd(1, bytes);
}

pub fn writeStderr(bytes: []const u8) void {
    writeFd(2, bytes);
}

/// std.log backend: one write(2) per message so lines from different
/// threads don't interleave. Same "level(scope): msg" format as Zig's default.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buf: [512]u8 = undefined;
    const prefix = comptime level.asText() ++ "(" ++ @tagName(scope) ++ "): ";
    const msg = std.fmt.bufPrint(&buf, prefix ++ format ++ "\n", args) catch blk: {
        buf[buf.len - 4 ..].* = "...\n".*;
        break :blk &buf;
    };
    writeStderr(msg);
}

// ---------------------------------------------------------------- files

pub const File = struct {
    fd: linux.fd_t,

    pub const Mode = enum { read, write, create };

    pub fn open(path: []const u8, mode: Mode) !File {
        var path_z: [posix.PATH_MAX:0]u8 = undefined;
        if (path.len >= path_z.len) return error.NameTooLong;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;

        const flags: linux.O = switch (mode) {
            .read => .{ .ACCMODE = .RDONLY, .CLOEXEC = true },
            .write => .{ .ACCMODE = .WRONLY, .CLOEXEC = true },
            .create => .{ .ACCMODE = .WRONLY, .CLOEXEC = true, .CREAT = true, .TRUNC = true },
        };
        while (true) {
            const rc = linux.openat(linux.AT.FDCWD, &path_z, flags, 0o644);
            switch (linux.errno(rc)) {
                .SUCCESS => return .{ .fd = @intCast(rc) },
                .INTR => continue,
                else => return error.OpenFailed,
            }
        }
    }

    pub fn close(f: File) void {
        _ = linux.close(f.fd);
    }

    /// Read until buf is full or EOF.
    pub fn readAll(f: File, buf: []u8) !usize {
        var total: usize = 0;
        while (total < buf.len) {
            const rc = linux.read(f.fd, buf[total..].ptr, buf.len - total);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) break;
                    total += rc;
                },
                .INTR => continue,
                else => return error.ReadFailed,
            }
        }
        return total;
    }

    pub fn writeAll(f: File, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const rc = linux.write(f.fd, bytes[off..].ptr, bytes.len - off);
            switch (linux.errno(rc)) {
                .SUCCESS => off += rc,
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
    }
};

/// mkdir(2); succeeds if the directory already exists.
pub fn makeDir(path: [*:0]const u8) !void {
    switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, path, 0o755))) {
        .SUCCESS, .EXIST => {},
        else => return error.MakeDirFailed,
    }
}

// ---------------------------------------------------------------- processes

const search_dirs = [_][]const u8{ "/usr/sbin/", "/usr/bin/", "/sbin/", "/bin/" };

/// Run a command (argv[0] looked up in the standard OpenWrt PATH dirs) with
/// stdio redirected to /dev/null. Returns the exit code, or null if the
/// child was killed by a signal.
pub fn exec(argv: []const []const u8) !?u8 {
    if (argv.len == 0 or argv.len > 15) return error.InvalidArgv;

    // Build NUL-terminated argv and candidate paths before fork(), so the
    // child only has to make syscalls.
    var strbuf: [1024]u8 = undefined;
    var off: usize = 0;
    var argv_z: [16:null]?[*:0]const u8 = @splat(null);
    for (argv, 0..) |a, i| {
        if (off + a.len + 1 > strbuf.len) return error.ArgvTooLong;
        @memcpy(strbuf[off..][0..a.len], a);
        strbuf[off + a.len] = 0;
        argv_z[i] = @ptrCast(&strbuf[off]);
        off += a.len + 1;
    }

    var pathbuf: [search_dirs.len][128]u8 = undefined;
    var paths: [search_dirs.len][*:0]const u8 = undefined;
    var n_paths: usize = 0;
    if (std.mem.indexOfScalar(u8, argv[0], '/') != null) {
        paths[0] = argv_z[0].?;
        n_paths = 1;
    } else {
        for (search_dirs) |dir| {
            const p = std.fmt.bufPrintSentinel(&pathbuf[n_paths], "{s}{s}", .{ dir, argv[0] }, 0) catch
                return error.ArgvTooLong;
            paths[n_paths] = p.ptr;
            n_paths += 1;
        }
    }

    const pid_rc = linux.fork();
    if (failed(pid_rc)) return error.ForkFailed;
    const pid: linux.pid_t = @intCast(pid_rc);

    if (pid == 0) {
        const devnull = linux.openat(linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR }, 0);
        if (!failed(devnull)) {
            const fd: linux.fd_t = @intCast(devnull);
            _ = linux.dup2(fd, 0);
            _ = linux.dup2(fd, 1);
            _ = linux.dup2(fd, 2);
            if (fd > 2) _ = linux.close(fd);
        }
        for (paths[0..n_paths]) |p| _ = linux.execve(p, &argv_z, envp);
        linux.exit_group(127);
    }

    var status: i32 = 0;
    while (true) {
        switch (linux.errno(linux.waitpid(pid, &status, 0))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.WaitFailed,
        }
    }
    const s: u32 = @bitCast(status);
    return if (linux.W.IFEXITED(s)) linux.W.EXITSTATUS(s) else null;
}

// ---------------------------------------------------------------- sockets

pub const SocketError = error{ SocketFailed, ConnectFailed, SendFailed, RecvFailed };

pub const Socket = struct {
    fd: linux.fd_t,

    pub fn open(sock_type: u32) SocketError!Socket {
        const rc = linux.socket(linux.AF.INET, sock_type | linux.SOCK.CLOEXEC, 0);
        if (failed(rc)) return error.SocketFailed;
        return .{ .fd = @intCast(rc) };
    }

    pub fn close(s: Socket) void {
        _ = linux.close(s.fd);
    }

    /// Set both receive and send timeouts.
    pub fn setTimeouts(s: Socket, sec: u32) !void {
        try s.setRecvTimeout(sec);
        const tv = linux.timeval{ .sec = @intCast(sec), .usec = 0 };
        try posix.setsockopt(s.fd, linux.SOL.SOCKET, linux.SO.SNDTIMEO, std.mem.asBytes(&tv));
    }

    pub fn setRecvTimeout(s: Socket, sec: u32) !void {
        const tv = linux.timeval{ .sec = @intCast(sec), .usec = 0 };
        try posix.setsockopt(s.fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv));
    }

    pub fn connect(s: Socket, ip: [4]u8, port: u16) SocketError!void {
        const sa = inAddr(ip, port);
        while (true) {
            switch (linux.errno(linux.connect(s.fd, &sa, @sizeOf(linux.sockaddr.in)))) {
                .SUCCESS => return,
                .INTR => continue,
                else => return error.ConnectFailed,
            }
        }
    }

    pub fn send(s: Socket, buf: []const u8) SocketError!usize {
        return s.sendToRaw(buf, null);
    }

    pub fn sendTo(s: Socket, buf: []const u8, ip: [4]u8, port: u16) SocketError!usize {
        const sa = inAddr(ip, port);
        return s.sendToRaw(buf, &sa);
    }

    fn sendToRaw(s: Socket, buf: []const u8, sa: ?*const linux.sockaddr.in) SocketError!usize {
        const len: linux.socklen_t = if (sa != null) @sizeOf(linux.sockaddr.in) else 0;
        while (true) {
            const rc = linux.sendto(s.fd, buf.ptr, buf.len, linux.MSG.NOSIGNAL, @ptrCast(sa), len);
            switch (linux.errno(rc)) {
                .SUCCESS => return rc,
                .INTR => continue,
                else => return error.SendFailed,
            }
        }
    }

    /// Receive into buf. Returns 0 on orderly shutdown; error on timeout.
    pub fn recv(s: Socket, buf: []u8) SocketError!usize {
        while (true) {
            const rc = linux.recvfrom(s.fd, buf.ptr, buf.len, 0, null, null);
            switch (linux.errno(rc)) {
                .SUCCESS => return rc,
                .INTR => continue,
                else => return error.RecvFailed,
            }
        }
    }
};

fn inAddr(ip: [4]u8, port: u16) linux.sockaddr.in {
    return .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = @bitCast(ip),
    };
}
