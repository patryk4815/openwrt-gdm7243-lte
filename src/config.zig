const std = @import("std");

pub const PdpType = enum {
    ip,
    ipv6,
    ipv4v6,

    pub fn toAtStr(self: PdpType) []const u8 {
        return switch (self) {
            .ip => "IP",
            .ipv6 => "IPV6",
            .ipv4v6 => "IPV4V6",
        };
    }
};

pub const AuthType = enum(u8) {
    none = 0,
    pap = 1,
    chap = 2,
};

pub const NetMode = enum {
    netifd,
    ip,
};

pub const Config = struct {
    apn: [64]u8 = undefined,
    apn_len: usize = 0,
    pin: [16]u8 = undefined,
    pin_len: usize = 0,
    cid: u8 = 3,
    pdptype: PdpType = .ip,
    auth: AuthType = .none,
    username: [64]u8 = undefined,
    username_len: usize = 0,
    password: [64]u8 = undefined,
    password_len: usize = 0,
    allow_roaming: bool = true,
    mode: NetMode = .netifd,
    modem_ip: [4]u8 = .{ 169, 254, 0, 1 },
    at_port: u16 = 7788,
    keepalive_port: u16 = 4667,
    keepalive_interval_s: u32 = 5,
    monitor_interval_s: u32 = 15,
    iface: [32]u8 = undefined,
    iface_len: usize = 3,
    device: [32]u8 = undefined,
    device_len: usize = 0,
    leds_enabled: bool = true,
    use_apn_dns: bool = true,

    pub fn setApn(self: *Config, val: []const u8) void {
        const len = @min(val.len, self.apn.len);
        @memcpy(self.apn[0..len], val[0..len]);
        self.apn_len = len;
    }

    pub fn getApn(self: *const Config) []const u8 {
        return self.apn[0..self.apn_len];
    }

    pub fn setPin(self: *Config, val: []const u8) void {
        const len = @min(val.len, self.pin.len);
        @memcpy(self.pin[0..len], val[0..len]);
        self.pin_len = len;
    }

    pub fn getPin(self: *const Config) []const u8 {
        return self.pin[0..self.pin_len];
    }

    pub fn hasPin(self: *const Config) bool {
        return self.pin_len > 0;
    }

    pub fn setIface(self: *Config, val: []const u8) void {
        const len = @min(val.len, self.iface.len);
        @memcpy(self.iface[0..len], val[0..len]);
        self.iface_len = len;
    }

    pub fn getIface(self: *const Config) []const u8 {
        return self.iface[0..self.iface_len];
    }

    pub fn setDevice(self: *Config, val: []const u8) void {
        const len = @min(val.len, self.device.len);
        @memcpy(self.device[0..len], val[0..len]);
        self.device_len = len;
    }

    pub fn getDevice(self: *const Config) []const u8 {
        return self.device[0..self.device_len];
    }

    pub fn setUsername(self: *Config, val: []const u8) void {
        const len = @min(val.len, self.username.len);
        @memcpy(self.username[0..len], val[0..len]);
        self.username_len = len;
    }

    pub fn getUsername(self: *const Config) []const u8 {
        return self.username[0..self.username_len];
    }

    pub fn setPassword(self: *Config, val: []const u8) void {
        const len = @min(val.len, self.password.len);
        @memcpy(self.password[0..len], val[0..len]);
        self.password_len = len;
    }

    pub fn getPassword(self: *const Config) []const u8 {
        return self.password[0..self.password_len];
    }
};

/// Parse UCI config file /etc/config/gctd
/// Format: lines like "    option key 'value'" or "    option key value"
pub fn load(path: []const u8) Config {
    var cfg = Config{};
    cfg.setApn("internet");
    cfg.setIface("lte");

    const file = std.fs.openFileAbsolute(path, .{}) catch return cfg;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return cfg;
    const content = buf[0..n];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, "option ")) continue;
        const rest = trimmed["option ".len..];

        if (parseOption(rest, "apn")) |val| {
            cfg.setApn(val);
        } else if (parseOption(rest, "pin")) |val| {
            cfg.setPin(val);
        } else if (parseOption(rest, "cid")) |val| {
            cfg.cid = std.fmt.parseInt(u8, val, 10) catch 3;
        } else if (parseOption(rest, "pdptype")) |val| {
            if (std.mem.eql(u8, val, "ipv6")) {
                cfg.pdptype = .ipv6;
            } else if (std.mem.eql(u8, val, "ipv4v6")) {
                cfg.pdptype = .ipv4v6;
            } else {
                cfg.pdptype = .ip;
            }
        } else if (parseOption(rest, "auth")) |val| {
            if (std.mem.eql(u8, val, "pap")) {
                cfg.auth = .pap;
            } else if (std.mem.eql(u8, val, "chap")) {
                cfg.auth = .chap;
            } else {
                cfg.auth = .none;
            }
        } else if (parseOption(rest, "username")) |val| {
            cfg.setUsername(val);
        } else if (parseOption(rest, "password")) |val| {
            cfg.setPassword(val);
        } else if (parseOption(rest, "mode")) |val| {
            if (std.mem.eql(u8, val, "ip")) {
                cfg.mode = .ip;
            } else {
                cfg.mode = .netifd;
            }
        } else if (parseOption(rest, "modem_ip")) |val| {
            cfg.modem_ip = parseIp4(val) orelse cfg.modem_ip;
        } else if (parseOption(rest, "allow_roaming")) |val| {
            cfg.allow_roaming = !std.mem.eql(u8, val, "0");
        } else if (parseOption(rest, "at_port")) |val| {
            cfg.at_port = std.fmt.parseInt(u16, val, 10) catch 7788;
        } else if (parseOption(rest, "keepalive_port")) |val| {
            cfg.keepalive_port = std.fmt.parseInt(u16, val, 10) catch 4667;
        } else if (parseOption(rest, "keepalive_interval")) |val| {
            cfg.keepalive_interval_s = std.fmt.parseInt(u32, val, 10) catch 5;
        } else if (parseOption(rest, "monitor_interval")) |val| {
            cfg.monitor_interval_s = std.fmt.parseInt(u32, val, 10) catch 15;
        } else if (parseOption(rest, "iface")) |val| {
            cfg.setIface(val);
        } else if (parseOption(rest, "leds")) |val| {
            cfg.leds_enabled = !std.mem.eql(u8, val, "0");
        } else if (parseOption(rest, "use_apn_dns")) |val| {
            cfg.use_apn_dns = !std.mem.eql(u8, val, "0");
        }
    }

    return cfg;
}

fn parseIp4(val: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var i: usize = 0;
    var iter = std.mem.splitScalar(u8, val, '.');
    while (iter.next()) |octet| {
        if (i >= 4) return null;
        result[i] = std.fmt.parseInt(u8, octet, 10) catch return null;
        i += 1;
    }
    if (i != 4) return null;
    return result;
}

fn parseOption(rest: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, rest, key)) return null;
    if (rest.len <= key.len) return null;
    if (rest[key.len] != ' ') return null;
    var val = std.mem.trim(u8, rest[key.len + 1 ..], " \t");
    // Strip quotes
    if (val.len >= 2 and val[0] == '\'' and val[val.len - 1] == '\'') {
        val = val[1 .. val.len - 1];
    }
    return val;
}
