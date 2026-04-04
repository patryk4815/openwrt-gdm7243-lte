const std = @import("std");
const commands = @import("commands.zig");
const led = @import("led.zig");
const log = std.log.scoped(.monitor);

var keep_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var interval_ns: u64 = 15 * std.time.ns_per_s;
var iface_buf: [32]u8 = undefined;
var iface_len: usize = 0;

pub fn configure(interval_s: u32, iface: []const u8) void {
    interval_ns = @as(u64, interval_s) * std.time.ns_per_s;
    const len = @min(iface.len, iface_buf.len);
    @memcpy(iface_buf[0..len], iface[0..len]);
    iface_len = len;
}

pub fn stop() void {
    keep_running.store(false, .release);
}

pub fn run() void {
    log.info("Signal monitor started (interval: {d}s)", .{@as(u32, @intCast(interval_ns / std.time.ns_per_s))});

    while (keep_running.load(.acquire)) {
        updateSignal();
        updateRegistration();
        std.Thread.sleep(interval_ns);
    }
}

fn updateSignal() void {
    const info = commands.querySignal() catch {
        led.setSignalBars(0);
        return;
    };

    led.setSignalBars(info.bars);
    if (info.rsrp_dbm) |dbm| {
        log.debug("Signal: RSRP={d} dBm, bars={d}", .{ dbm, info.bars });
    }
}

fn updateRegistration() void {
    const status = commands.queryRegistration() catch {
        led.set("green:internet", false);
        return;
    };
    const registered = status == .home or status == .roaming;
    const name = iface_buf[0..iface_len];
    const has_ip = exec(&.{ "ip", "addr", "show", "dev", name });
    led.set("green:internet", registered and has_ip);
}

fn exec(argv: []const []const u8) bool {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Close;
    child.stderr_behavior = .Close;
    child.spawn() catch return false;
    const result = child.wait() catch return false;
    return result.Exited == 0;
}
