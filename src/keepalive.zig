const std = @import("std");
const posix = std.posix;
const net = std.net;
const log = std.log.scoped(.keepalive);

pub var modem_alive: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

var keep_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var modem_addr: net.Address = undefined;
var interval_ns: u64 = 5 * std.time.ns_per_s;

pub fn configure(ip: [4]u8, port: u16, interval_s: u32) void {
    modem_addr = net.Address.initIp4(ip, port);
    interval_ns = @as(u64, interval_s) * std.time.ns_per_s;
}

pub fn stop() void {
    keep_running.store(false, .release);
}

pub fn run() void {
    const msg = "IDU ALIVE";
    const expected = "ODU ALIVE";

    const sock = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0) catch {
        log.err("Failed to create UDP socket", .{});
        return;
    };
    defer posix.close(sock);

    // Recv timeout 2s
    const tv = posix.timeval{ .sec = 2, .usec = 0 };
    posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch |e| {
        log.warn("Failed to set RCVTIMEO: {s}", .{@errorName(e)});
    };

    var fail_count: u32 = 0;
    const max_fails: u32 = 6; // 6 * 5s = 30s

    while (keep_running.load(.acquire)) {
        // Send "IDU ALIVE"
        _ = posix.sendto(sock, msg, 0, &modem_addr.any, modem_addr.getOsSockLen()) catch |e| {
            fail_count += 1;
            log.warn("keepalive sendto failed: {s} (fail {d}/{d})", .{ @errorName(e), fail_count, max_fails });
            std.Thread.sleep(interval_ns);
            continue;
        };

        // Wait for "ODU ALIVE"
        var recv_buf: [64]u8 = undefined;
        const n = posix.recv(sock, &recv_buf, 0) catch |e| {
            fail_count += 1;
            if (fail_count >= max_fails) {
                if (modem_alive.load(.acquire)) {
                    log.warn("keepalive: modem not responding (fail {d}/{d}): {s}", .{ fail_count, max_fails, @errorName(e) });
                }
                modem_alive.store(false, .release);
            }
            std.Thread.sleep(interval_ns);
            continue;
        };

        if (n >= expected.len and std.mem.eql(u8, recv_buf[0..expected.len], expected)) {
            if (!modem_alive.load(.acquire)) {
                log.info("Modem alive", .{});
            }
            modem_alive.store(true, .release);
            fail_count = 0;
        } else {
            fail_count += 1;
            log.warn("keepalive: unexpected response ({d} bytes, fail {d}/{d})", .{ n, fail_count, max_fails });
        }

        std.Thread.sleep(interval_ns);
    }
}
