const std = @import("std");
const sys = @import("sys.zig");
const commands = @import("commands.zig");
const led = @import("led.zig");
const config = @import("config.zig");
const log = std.log.scoped(.monitor);

var keep_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);
var interval_ns: u64 = 15 * std.time.ns_per_s;
var device_buf: [32]u8 = undefined;
var device_len: usize = 0;
var pdptype: config.PdpType = .ip;

/// `device` is the Linux network device carrying LTE traffic (e.g. wan.100),
/// not the netifd interface name. Empty means unknown: the internet LED then
/// follows registration only.
pub fn configure(interval_s: u32, device: []const u8, pdp: config.PdpType) void {
    interval_ns = @as(u64, interval_s) * std.time.ns_per_s;
    const len = @min(device.len, device_buf.len);
    @memcpy(device_buf[0..len], device[0..len]);
    device_len = len;
    pdptype = pdp;
}

pub fn stop() void {
    keep_running.store(false, .release);
}

pub fn run() void {
    log.info("Signal monitor started (interval: {d}s, device: {s})", .{
        @as(u32, @intCast(interval_ns / std.time.ns_per_s)),
        if (device_len > 0) device_buf[0..device_len] else "-",
    });

    while (keep_running.load(.acquire)) {
        updateSignal();
        updateRegistration();
        sys.sleepNs(interval_ns);
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
        led.set("green:wan", false);
        return;
    };
    const registered = status == .home or status == .roaming;
    led.set("green:wan", registered and hasAddress());
}

/// Whether the LTE device has the address family the PDP context provides.
fn hasAddress() bool {
    if (device_len == 0) return true;
    const dev = device_buf[0..device_len];
    const want_v4 = pdptype != .ipv6;
    const want_v6 = pdptype != .ip;
    return (want_v4 and sys.hasIpv4Addr(dev)) or (want_v6 and sys.hasGlobalIpv6Addr(dev));
}
