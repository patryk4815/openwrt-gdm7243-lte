const std = @import("std");
const sys = @import("sys.zig");
const log = std.log.scoped(.at);

pub const AtError = error{
    ConnectFailed,
    SendFailed,
    Timeout,
    ModemError,
};

pub const AtResponse = struct {
    ok: bool,
    raw: []const u8,
    raw_len: usize,

    /// Get response line containing prefix (e.g. "+CESQ:")
    pub fn getLine(self: *const AtResponse, prefix: []const u8) ?[]const u8 {
        const data = self.raw[0..self.raw_len];
        var lines = std.mem.splitSequence(u8, data, "\r\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\n");
            if (trimmed.len > 0 and std.mem.startsWith(u8, trimmed, prefix)) {
                return trimmed;
            }
        }
        return null;
    }

    /// Parse "+PREFIX: val1,val2,val3" into fields split by comma
    /// Returns the part after ": " split by ","
    pub fn getFieldsAfterColon(self: *const AtResponse, prefix: []const u8) ?[]const u8 {
        const line = self.getLine(prefix) orelse return null;
        const colon_pos = std.mem.indexOf(u8, line, ": ") orelse return null;
        return line[colon_pos + 2 ..];
    }
};

const RECV_BUF_SIZE = 4096;

/// The modem's AT server (/usr/lte/ipatc in the GDM7243 rootfs, started with
/// `-p 7788`) serves one TCP client at a time: it keeps the client fd in a
/// single global, calls accept() only when that global is 0, and its HCI
/// thread writes every AT response to that global fd. A second connection
/// completes the TCP handshake (listen backlog 10) but its command is not
/// read until the current client disconnects, so the time spent queued
/// counts against our socket timeouts.
///
/// AT commands come from the daemon's main loop, its monitor thread and
/// separate `gctd` CLI processes (LuCI/rpcd), so one lock file serializes
/// them on our side: waiting happens on the lock instead of inside a socket
/// timeout. If the lock file can't be opened, commands are sent unserialized.
///
/// Caveat the lock can't fix: if a client gives up and disconnects before
/// the modem answers, the late response is written to whichever client the
/// modem accepts next.
const LOCK_PATH = "/var/lock/gctd-at.lock";

var modem_ip: [4]u8 = .{ 169, 254, 0, 1 };
var modem_port: u16 = 7788;

pub fn configure(ip: [4]u8, port: u16) void {
    modem_ip = ip;
    modem_port = port;
}

/// Send AT command to modem, return response
/// Response points into a per-thread buffer, valid until the same thread
/// sends the next command
pub fn send(cmd: []const u8) AtError!AtResponse {
    return sendWithTimeout(cmd, 5);
}

pub fn sendWithTimeout(cmd: []const u8, timeout_s: u32) AtError!AtResponse {
    const lock = sys.FileLock.acquire(LOCK_PATH);
    defer lock.release();

    const sock = sys.Socket.open(std.posix.SOCK.STREAM) catch {
        return AtError.ConnectFailed;
    };
    defer sock.close();

    // Set send/recv timeout
    sock.setTimeouts(timeout_s) catch |e| {
        log.warn("Failed to set socket timeouts: {s}", .{@errorName(e)});
    };

    sock.connect(modem_ip, modem_port) catch {
        return AtError.ConnectFailed;
    };

    // Send command with \r
    var send_buf: [256]u8 = undefined;
    const send_len = std.fmt.bufPrint(&send_buf, "{s}\r", .{cmd}) catch {
        return AtError.SendFailed;
    };
    _ = sock.send(send_len) catch {
        return AtError.SendFailed;
    };

    // Read response until OK or ERROR
    // Per-thread buffer: the main loop and the monitor thread send AT
    // commands concurrently, and the response is parsed after return.
    const S = struct {
        threadlocal var recv_buf: [RECV_BUF_SIZE]u8 = undefined;
    };
    var total: usize = 0;

    while (total < RECV_BUF_SIZE - 1) {
        const n = sock.recv(S.recv_buf[total..]) catch {
            break;
        };
        if (n == 0) break;
        total += n;

        const data = S.recv_buf[0..total];
        if (std.mem.indexOf(u8, data, "OK\r\n") != null) {
            return AtResponse{
                .ok = true,
                .raw = &S.recv_buf,
                .raw_len = total,
            };
        }
        if (std.mem.indexOf(u8, data, "ERROR\r\n") != null) {
            return AtResponse{
                .ok = false,
                .raw = &S.recv_buf,
                .raw_len = total,
            };
        }
    }

    if (total > 0) {
        return AtResponse{
            .ok = false,
            .raw = &S.recv_buf,
            .raw_len = total,
        };
    }
    return AtError.Timeout;
}

/// Send AT command and stream response lines to callback.
/// Calls cb for each complete line (between \r\n). Stops at OK or ERROR.
/// Uses a small rolling buffer — no limit on total response size.
pub fn sendStreaming(cmd: []const u8, timeout_s: u32, ctx: anytype, cb: fn ([]const u8, @TypeOf(ctx)) void) AtError!bool {
    const lock = sys.FileLock.acquire(LOCK_PATH);
    defer lock.release();

    const sock = sys.Socket.open(std.posix.SOCK.STREAM) catch {
        return AtError.ConnectFailed;
    };
    defer sock.close();

    sock.setTimeouts(timeout_s) catch {};

    sock.connect(modem_ip, modem_port) catch {
        return AtError.ConnectFailed;
    };

    // Send command
    var send_buf: [256]u8 = undefined;
    const send_len = std.fmt.bufPrint(&send_buf, "{s}\r", .{cmd}) catch {
        return AtError.SendFailed;
    };
    _ = sock.send(send_len) catch {
        return AtError.SendFailed;
    };

    // Read and stream line by line
    var buf: [2048]u8 = undefined;
    var buf_len: usize = 0;
    var ok_result = false;

    while (true) {
        const n = sock.recv(buf[buf_len..]) catch break;
        if (n == 0) break;
        buf_len += n;

        // Process complete lines
        while (true) {
            const line_end = std.mem.indexOf(u8, buf[0..buf_len], "\r\n") orelse break;
            const line = buf[0..line_end];

            if (std.mem.eql(u8, line, "OK")) {
                ok_result = true;
                return ok_result;
            }
            if (std.mem.eql(u8, line, "ERROR")) {
                return false;
            }

            if (line.len > 0) {
                cb(line, ctx);
            }

            // Shift remaining data
            const consumed = line_end + 2;
            if (consumed < buf_len) {
                std.mem.copyForwards(u8, buf[0 .. buf_len - consumed], buf[consumed..buf_len]);
            }
            buf_len -= consumed;
        }

        // Prevent buffer overflow — flush if nearly full
        if (buf_len >= buf.len - 256) {
            if (buf_len > 0) {
                cb(buf[0..buf_len], ctx);
            }
            buf_len = 0;
        }
    }

    return ok_result;
}

/// Split comma-separated fields. Returns slices into the input.
pub fn splitFields(data: []const u8, out: *[16][]const u8) usize {
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, data, ',');
    while (iter.next()) |field| {
        if (count >= 16) break;
        // Strip surrounding quotes
        var f = std.mem.trim(u8, field, " ");
        if (f.len >= 2 and f[0] == '"' and f[f.len - 1] == '"') {
            f = f[1 .. f.len - 1];
        }
        out[count] = f;
        count += 1;
    }
    return count;
}
