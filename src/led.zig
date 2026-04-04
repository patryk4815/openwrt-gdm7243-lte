const std = @import("std");

const led_base = "/sys/class/leds/";

var enabled: bool = true;

pub fn configure(leds_enabled: bool) void {
    enabled = leds_enabled;
}

pub fn set(name: []const u8, on: bool) void {
    if (!enabled) return;
    var path_buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}{s}/brightness", .{ led_base, name }) catch return;
    const file = std.fs.openFileAbsolute(path, .{ .mode = .write_only }) catch return;
    defer file.close();
    _ = file.write(if (on) "255" else "0") catch {};
}

pub fn setSignalBars(bars: u8) void {
    set("green:sig1", bars >= 1);
    set("green:sig2", bars >= 2);
    set("green:sig3", bars >= 3);
    set("green:sig4", bars >= 4);
}
