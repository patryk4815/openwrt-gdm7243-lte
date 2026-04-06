const std = @import("std");
const posix = std.posix;
const net = std.net;
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

var modem_ip: [4]u8 = .{ 169, 254, 0, 1 };
var modem_port: u16 = 7788;

pub fn configure(ip: [4]u8, port: u16) void {
    modem_ip = ip;
    modem_port = port;
}

/// Send AT command to modem, return response
/// Uses a static buffer — not thread-safe without external locking
pub fn send(cmd: []const u8) AtError!AtResponse {
    return sendWithTimeout(cmd, 5);
}

pub fn sendWithTimeout(cmd: []const u8, timeout_s: u32) AtError!AtResponse {
    const addr = net.Address.initIp4(modem_ip, modem_port);

    const sock = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch {
        return AtError.ConnectFailed;
    };
    defer posix.close(sock);

    // Set send/recv timeout
    const tv = posix.timeval{
        .sec = @intCast(timeout_s),
        .usec = 0,
    };
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch |e| {
        log.warn("Failed to set RCVTIMEO: {s}", .{@errorName(e)});
    };
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch |e| {
        log.warn("Failed to set SNDTIMEO: {s}", .{@errorName(e)});
    };

    posix.connect(sock, &addr.any, addr.getOsSockLen()) catch {
        return AtError.ConnectFailed;
    };

    // Send command with \r
    var send_buf: [256]u8 = undefined;
    const send_len = std.fmt.bufPrint(&send_buf, "{s}\r", .{cmd}) catch {
        return AtError.SendFailed;
    };
    _ = posix.send(sock, send_len, 0) catch {
        return AtError.SendFailed;
    };

    // Read response until OK or ERROR
    const S = struct {
        var recv_buf: [RECV_BUF_SIZE]u8 = undefined;
    };
    var total: usize = 0;

    while (total < RECV_BUF_SIZE - 1) {
        const n = posix.recv(sock, S.recv_buf[total..], 0) catch {
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
    const addr = net.Address.initIp4(modem_ip, modem_port);

    const sock = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch {
        return AtError.ConnectFailed;
    };
    defer posix.close(sock);

    const tv = posix.timeval{
        .sec = @intCast(timeout_s),
        .usec = 0,
    };
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};

    posix.connect(sock, &addr.any, addr.getOsSockLen()) catch {
        return AtError.ConnectFailed;
    };

    // Send command
    var send_buf: [256]u8 = undefined;
    const send_len = std.fmt.bufPrint(&send_buf, "{s}\r", .{cmd}) catch {
        return AtError.SendFailed;
    };
    _ = posix.send(sock, send_len, 0) catch {
        return AtError.SendFailed;
    };

    // Read and stream line by line
    var buf: [2048]u8 = undefined;
    var buf_len: usize = 0;
    var ok_result = false;

    while (true) {
        const n = posix.recv(sock, buf[buf_len..], 0) catch break;
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
