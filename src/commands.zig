const std = @import("std");
const at = @import("at.zig");
const config_mod = @import("config.zig");
const log = std.log.scoped(.commands);

pub const CommandError = error{
    ParseError,
    NoData,
    PinRejected,
};

// --- SIM ---

pub const SimStatus = enum { ready, pin_required, puk_required, unknown };

pub fn querySimStatus() !SimStatus {
    const resp = try at.send("AT+CPIN?");
    if (resp.getLine("+CPIN: READY") != null) return .ready;
    if (resp.getLine("+CPIN: SIM PIN") != null) return .pin_required;
    if (resp.getLine("+CPIN: SIM PUK") != null) return .puk_required;
    return .unknown;
}

pub fn queryPinRetries() !u32 {
    const resp = try at.send("AT+CPINR");
    const fields_str = resp.getFieldsAfterColon("+CPINR:") orelse return error.NoData;
    var fields: [16][]const u8 = undefined;
    const count = at.splitFields(fields_str, &fields);
    if (count < 2) return error.ParseError;
    return std.fmt.parseInt(u32, fields[1], 10) catch return error.ParseError;
}

pub fn enterPin(pin: []const u8) !void {
    var cmd_buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "AT+CPIN=\"{s}\"", .{pin}) catch return error.ParseError;
    const resp = try at.send(cmd);
    if (!resp.ok) return error.PinRejected;
}

// --- Network ---

pub fn setFullFunctionality() !void {
    const resp = try at.send("AT+CFUN=1");
    if (!resp.ok) log.warn("AT+CFUN=1 returned error", .{});
}

pub fn attach() !void {
    const resp = try at.send("AT+CGATT=1");
    if (!resp.ok) log.warn("AT+CGATT=1 returned error", .{});
}

pub const RegStatus = enum { not_registered, home, searching, denied, roaming, unknown };

pub fn queryRegistration() !RegStatus {
    const resp = try at.send("AT+CEREG?");
    const fields_str = resp.getFieldsAfterColon("+CEREG:") orelse return error.NoData;
    var fields: [16][]const u8 = undefined;
    const count = at.splitFields(fields_str, &fields);
    if (count < 2) return error.ParseError;
    const stat = std.fmt.parseInt(u8, fields[1], 10) catch return error.ParseError;
    return switch (stat) {
        0 => .not_registered,
        1 => .home,
        2 => .searching,
        3 => .denied,
        5 => .roaming,
        else => .unknown,
    };
}

pub fn configureContext(cid: u8, pdptype: config_mod.PdpType, apn: []const u8) !void {
    var cmd_buf: [128]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "AT+CGDCONT={d},\"{s}\",\"{s}\"", .{ cid, pdptype.toAtStr(), apn }) catch return error.ParseError;
    const resp = try at.send(cmd);
    if (!resp.ok) log.warn("AT+CGDCONT returned error", .{});
}

pub fn configureAuth(cid: u8, auth: config_mod.AuthType, username: []const u8, password: []const u8) !void {
    var cmd_buf: [192]u8 = undefined;
    const cmd = if (auth == .none)
        std.fmt.bufPrint(&cmd_buf, "AT+CGAUTH={d},0", .{cid}) catch return error.ParseError
    else
        std.fmt.bufPrint(&cmd_buf, "AT+CGAUTH={d},{d},\"{s}\",\"{s}\"", .{ cid, @intFromEnum(auth), username, password }) catch return error.ParseError;
    const resp = try at.send(cmd);
    if (!resp.ok) log.warn("AT+CGAUTH returned error", .{});
}

pub fn activateContext(cid: u8) !void {
    var cmd_buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "AT+CGACT=1,{d}", .{cid}) catch return error.ParseError;
    const resp = try at.send(cmd);
    if (!resp.ok) log.warn("CGACT returned error (may already be active)", .{});
}

pub fn queryContextActive(cid: u8) !bool {
    const resp = try at.send("AT+CGACT?");
    // Response: +CGACT: 1,1\r\n+CGACT: 2,0\r\n...
    // Find our CID and check if active (1)
    var cid_buf: [16]u8 = undefined;
    const needle = std.fmt.bufPrint(&cid_buf, "+CGACT: {d},", .{cid}) catch return error.ParseError;
    const data = resp.raw[0..resp.raw_len];
    if (std.mem.indexOf(u8, data, needle)) |pos| {
        const val_pos = pos + needle.len;
        if (val_pos < data.len) {
            return data[val_pos] == '1';
        }
    }
    return false;
}

pub fn deactivateContext(cid: u8) !void {
    // AT+CGACT=0,N is rejected by GDM7243 — use AT+CGATT=0 (detach) instead
    _ = cid;
    const resp = try at.send("AT+CGATT=0");
    if (!resp.ok) log.warn("AT+CGATT=0 returned error", .{});
}

// --- Connection Details ---

pub const ConnectionDetails = struct {
    ip: [64]u8 = undefined,
    ip_len: usize = 0,
    prefix: u8 = 24,
    gateway: [64]u8 = undefined,
    gateway_len: usize = 0,
    dns1: [64]u8 = undefined,
    dns1_len: usize = 0,
    dns2: [64]u8 = undefined,
    dns2_len: usize = 0,
    mtu: u16 = 1500,
    is_ipv6: bool = false,

    pub fn getIp(self: *const ConnectionDetails) []const u8 {
        return self.ip[0..self.ip_len];
    }
    pub fn getGateway(self: *const ConnectionDetails) []const u8 {
        return self.gateway[0..self.gateway_len];
    }
    pub fn getDns1(self: *const ConnectionDetails) []const u8 {
        return self.dns1[0..self.dns1_len];
    }
    pub fn getDns2(self: *const ConnectionDetails) []const u8 {
        return self.dns2[0..self.dns2_len];
    }
};

pub fn queryConnectionDetails(cid: u8) !ConnectionDetails {
    var cmd_buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "AT+CGCONTRDP={d}", .{cid}) catch return error.ParseError;
    const resp = try at.sendWithTimeout(cmd, 10);

    const fields_str = resp.getFieldsAfterColon("+CGCONTRDP:") orelse {
        log.err("No CGCONTRDP response", .{});
        return error.NoData;
    };

    var fields: [16][]const u8 = undefined;
    const count = at.splitFields(fields_str, &fields);

    if (count < 5) {
        log.err("CGCONTRDP: too few fields ({d})", .{count});
        return error.ParseError;
    }

    var details = ConnectionDetails{};

    // Field 3 (index 3): IP.MASK concatenated (e.g. "10.1.2.3.255.255.255.0")
    parseIpMaskToDetails(fields[3], &details);

    // Field 4 (index 4): gateway
    copyFieldAutoIpv6(fields[4], &details.gateway, &details.gateway_len, details.is_ipv6);

    // Field 5 (index 5): DNS1
    if (count > 5) copyFieldAutoIpv6(fields[5], &details.dns1, &details.dns1_len, details.is_ipv6);

    // Field 6 (index 6): DNS2
    if (count > 6) copyFieldAutoIpv6(fields[6], &details.dns2, &details.dns2_len, details.is_ipv6);

    // Field 11 (index 11): MTU (0 or missing = use default)
    if (count > 11) {
        const mtu = std.fmt.parseInt(u16, fields[11], 10) catch 0;
        if (mtu > 0) details.mtu = mtu;
    }

    return details;
}

// --- Signal ---

pub const SignalInfo = struct {
    rsrp_dbm: ?i16,
    bars: u8,
};

pub fn querySignal() !SignalInfo {
    const resp = try at.send("AT+CESQ");
    const fields_str = resp.getFieldsAfterColon("+CESQ:") orelse return error.NoData;

    var fields: [16][]const u8 = undefined;
    const count = at.splitFields(fields_str, &fields);
    if (count < 6) return error.ParseError;

    // Field 6 (index 5): RSRP, 0-97, 255=unknown
    const rsrp_raw = std.fmt.parseInt(i16, fields[5], 10) catch return error.ParseError;

    if (rsrp_raw == 255 or rsrp_raw < 0) {
        return SignalInfo{ .rsrp_dbm = null, .bars = 0 };
    }

    const dbm = rsrp_raw - 141;
    var bars: u8 = 0;
    if (dbm >= -120) bars = 1;
    if (dbm >= -105) bars = 2;
    if (dbm >= -95) bars = 3;
    if (dbm >= -80) bars = 4;

    return SignalInfo{ .rsrp_dbm = dbm, .bars = bars };
}

// --- Operator ---

pub const OperatorInfo = struct {
    name: [64]u8 = undefined,
    name_len: usize = 0,

    pub fn getName(self: *const OperatorInfo) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub fn queryOperator() !OperatorInfo {
    const resp = try at.send("AT+COPS?");
    const fields_str = resp.getFieldsAfterColon("+COPS:") orelse return error.NoData;
    var fields: [16][]const u8 = undefined;
    const count = at.splitFields(fields_str, &fields);
    var info = OperatorInfo{};
    if (count >= 3) {
        // +COPS: <mode>,<format>,"<oper>",<AcT> — field[2] is operator name (unquoted)
        const n = @min(fields[2].len, info.name.len);
        @memcpy(info.name[0..n], fields[2][0..n]);
        info.name_len = n;
    }
    return info;
}

// --- Address ---

pub fn queryAddress(cid: u8, buf: []u8) ![]const u8 {
    var cmd_buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "AT+CGPADDR={d}", .{cid}) catch return error.ParseError;
    const resp = try at.send(cmd);
    const fields_str = resp.getFieldsAfterColon("+CGPADDR:") orelse return error.NoData;
    var fields: [16][]const u8 = undefined;
    const count = at.splitFields(fields_str, &fields);
    // +CGPADDR: <cid>,"<address>" — field[1] is IP (unquoted)
    if (count >= 2) {
        const addr = fields[1];
        // Check for IPv6 byte-decimal (16 dot-separated octets, no colons)
        if (std.mem.indexOfScalar(u8, addr, ':') == null) {
            var dot_count: usize = 0;
            for (addr) |c| {
                if (c == '.') dot_count += 1;
            }
            if (dot_count >= 15) {
                var octets: [16]u8 = .{0} ** 16;
                var iter = std.mem.splitScalar(u8, addr, '.');
                var i: usize = 0;
                while (iter.next()) |octet_str| {
                    if (i >= 16) break;
                    octets[i] = std.fmt.parseInt(u8, octet_str, 10) catch 0;
                    i += 1;
                }
                var out: [64]u8 = undefined;
                const len = bytesToIpv6Hex(&octets, &out);
                const n = @min(len, buf.len);
                @memcpy(buf[0..n], out[0..n]);
                return buf[0..n];
            }
        }
        const n = @min(addr.len, buf.len);
        @memcpy(buf[0..n], addr[0..n]);
        return buf[0..n];
    }
    return error.NoData;
}

// --- Private helpers ---

fn copyField(src: []const u8, dst: *[64]u8, len: *usize) void {
    const n = @min(src.len, 63);
    @memcpy(dst[0..n], src[0..n]);
    len.* = n;
}

/// Copy field, converting byte-decimal IPv6 (16 dot-separated octets) to hex if needed
fn copyFieldAutoIpv6(src: []const u8, dst: *[64]u8, len: *usize, is_ipv6: bool) void {
    if (is_ipv6 and std.mem.indexOfScalar(u8, src, ':') == null and src.len > 0) {
        // Byte-decimal IPv6 — count dots
        var dot_count: usize = 0;
        for (src) |c| {
            if (c == '.') dot_count += 1;
        }
        if (dot_count >= 15) {
            var octets: [16]u8 = .{0} ** 16;
            var iter = std.mem.splitScalar(u8, src, '.');
            var i: usize = 0;
            while (iter.next()) |octet_str| {
                if (i >= 16) break;
                octets[i] = std.fmt.parseInt(u8, octet_str, 10) catch 0;
                i += 1;
            }
            len.* = bytesToIpv6Hex(&octets, dst);
            return;
        }
    }
    copyField(src, dst, len);
}

/// Parse IP+mask field from CGCONTRDP into ConnectionDetails.
/// IPv4: "10.1.2.3.255.255.255.0" (8 dot-separated octets)
/// IPv6 hex: "2A00:...:BBD3 FFFF:...:0000" (space-separated IP and mask)
/// IPv6 byte-decimal: "42.0.15.65.24.215.186.128.0.0.0.55.63.87.204.1.255.255..." (32 octets)
fn parseIpMaskToDetails(input: []const u8, details: *ConnectionDetails) void {
    // Detect IPv6 hex by presence of ':'
    if (std.mem.indexOfScalar(u8, input, ':') != null) {
        details.is_ipv6 = true;
        if (std.mem.indexOfScalar(u8, input, ' ')) |space_pos| {
            copyField(input[0..space_pos], &details.ip, &details.ip_len);
            const mask_start = space_pos + 1;
            if (mask_start < input.len) {
                details.prefix = ipv6MaskToPrefix(input[mask_start..]);
            } else {
                details.prefix = 64;
            }
        } else {
            copyField(input, &details.ip, &details.ip_len);
            details.prefix = 64;
        }
        return;
    }

    // Count dots to distinguish IPv4 (7 dots = 8 octets) from IPv6 byte-decimal (31 dots = 32 octets)
    var dot_count: usize = 0;
    for (input) |c| {
        if (c == '.') dot_count += 1;
    }

    if (dot_count >= 31) {
        // IPv6 byte-decimal: 16 bytes IP + 16 bytes mask = 32 octets
        details.is_ipv6 = true;
        var octets: [32]u8 = .{0} ** 32;
        var iter = std.mem.splitScalar(u8, input, '.');
        var i: usize = 0;
        while (iter.next()) |octet_str| {
            if (i >= 32) break;
            octets[i] = std.fmt.parseInt(u8, octet_str, 10) catch 0;
            i += 1;
        }
        // Convert first 16 bytes to IPv6 hex string
        details.ip_len = bytesToIpv6Hex(octets[0..16], &details.ip);
        // Convert mask bytes to prefix
        details.prefix = bytesMaskToPrefix(octets[16..32]);
    } else if (dot_count >= 15) {
        // IPv6 byte-decimal without mask: 16 octets
        details.is_ipv6 = true;
        var octets: [16]u8 = .{0} ** 16;
        var iter = std.mem.splitScalar(u8, input, '.');
        var i: usize = 0;
        while (iter.next()) |octet_str| {
            if (i >= 16) break;
            octets[i] = std.fmt.parseInt(u8, octet_str, 10) catch 0;
            i += 1;
        }
        details.ip_len = bytesToIpv6Hex(octets[0..16], &details.ip);
        details.prefix = 64;
    } else {
        // IPv4: split at 4th dot
        var dots: usize = 0;
        var split_pos: usize = 0;
        for (input, 0..) |c, idx| {
            if (c == '.') {
                dots += 1;
                if (dots == 4) {
                    split_pos = idx;
                    break;
                }
            }
        }
        if (dots >= 4 and split_pos > 0) {
            copyField(input[0..split_pos], &details.ip, &details.ip_len);
            details.prefix = ipv4MaskToPrefix(input[split_pos + 1 ..]);
        } else {
            copyField(input, &details.ip, &details.ip_len);
            details.prefix = 24;
        }
    }
}

/// Convert 16 raw bytes to compact IPv6 hex string (e.g. "2a00:f41:18d7:ba80::37:3f57:cc01")
pub fn bytesToIpv6Hex(bytes: *const [16]u8, out: *[64]u8) usize {
    // Build 8 groups
    var groups: [8]u16 = undefined;
    for (0..8) |i| {
        groups[i] = (@as(u16, bytes[i * 2]) << 8) | @as(u16, bytes[i * 2 + 1]);
    }

    // Find longest run of zeros for :: compression
    var best_start: usize = 8;
    var best_len: usize = 0;
    var run_start: usize = 0;
    var run_len: usize = 0;
    for (0..8) |i| {
        if (groups[i] == 0) {
            if (run_len == 0) run_start = i;
            run_len += 1;
        } else {
            if (run_len > best_len) {
                best_start = run_start;
                best_len = run_len;
            }
            run_len = 0;
        }
    }
    if (run_len > best_len) {
        best_start = run_start;
        best_len = run_len;
    }
    if (best_len == 0) best_start = 8; // no zeros to compress

    var fbs = std.io.fixedBufferStream(out);
    const w = fbs.writer();

    var i: usize = 0;
    var need_sep = false;
    while (i < 8) {
        if (i == best_start) {
            w.writeAll("::") catch return 0;
            i += best_len;
            need_sep = false;
            continue;
        }
        if (need_sep) w.writeAll(":") catch return 0;
        w.print("{x}", .{groups[i]}) catch return 0;
        need_sep = true;
        i += 1;
    }

    return fbs.pos;
}

/// Convert 16 mask bytes to CIDR prefix length
fn bytesMaskToPrefix(mask: *const [16]u8) u8 {
    var prefix: u8 = 0;
    for (mask) |byte| {
        var b = byte;
        while (b & 0x80 != 0) {
            prefix += 1;
            b <<= 1;
        }
        if (b != 0) break; // non-contiguous mask
    }
    return prefix;
}

// --- Tests ---

test "bytesToIpv6Hex - basic" {
    var buf: [64]u8 = undefined;
    const bytes = [16]u8{ 0x2a, 0x00, 0x0f, 0x41, 0x18, 0xd7, 0xba, 0x80, 0x00, 0x00, 0x00, 0x37, 0x3f, 0x57, 0xcc, 0x01 };
    const len = bytesToIpv6Hex(&bytes, &buf);
    const result = buf[0..len];
    try std.testing.expectEqualStrings("2a00:f41:18d7:ba80::37:3f57:cc01", result);
}

test "bytesToIpv6Hex - all zeros" {
    var buf: [64]u8 = undefined;
    const bytes = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const len = bytesToIpv6Hex(&bytes, &buf);
    const result = buf[0..len];
    try std.testing.expectEqualStrings("::", result);
}

test "bytesToIpv6Hex - link local" {
    var buf: [64]u8 = undefined;
    const bytes = [16]u8{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x37, 0x3f, 0x57, 0xcc, 0x40 };
    const len = bytesToIpv6Hex(&bytes, &buf);
    const result = buf[0..len];
    try std.testing.expectEqualStrings("fe80::37:3f57:cc40", result);
}

test "bytesMaskToPrefix - /64" {
    const mask = [16]u8{ 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(u8, 64), bytesMaskToPrefix(&mask));
}

test "bytesMaskToPrefix - /128" {
    const mask = [16]u8{ 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255 };
    try std.testing.expectEqual(@as(u8, 128), bytesMaskToPrefix(&mask));
}

test "parseIpMaskToDetails - IPv4" {
    var details = ConnectionDetails{};
    parseIpMaskToDetails("10.67.57.91.255.255.255.0", &details);
    try std.testing.expectEqualStrings("10.67.57.91", details.getIp());
    try std.testing.expectEqual(@as(u8, 24), details.prefix);
    try std.testing.expect(!details.is_ipv6);
}

test "parseIpMaskToDetails - IPv6 byte-decimal" {
    var details = ConnectionDetails{};
    parseIpMaskToDetails("42.0.15.65.24.215.186.128.0.0.0.55.63.87.204.1.255.255.255.255.255.255.255.255.0.0.0.0.0.0.0.0", &details);
    try std.testing.expectEqualStrings("2a00:f41:18d7:ba80::37:3f57:cc01", details.getIp());
    try std.testing.expectEqual(@as(u8, 64), details.prefix);
    try std.testing.expect(details.is_ipv6);
}

test "copyFieldAutoIpv6 - gateway byte-decimal" {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    copyFieldAutoIpv6("254.128.0.0.0.0.0.0.0.0.0.55.63.87.204.64", &buf, &len, true);
    try std.testing.expectEqualStrings("fe80::37:3f57:cc40", buf[0..len]);
}

test "copyFieldAutoIpv6 - dns byte-decimal" {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    copyFieldAutoIpv6("42.1.23.0.0.2.255.255.0.0.0.0.0.0.159.1", &buf, &len, true);
    try std.testing.expectEqualStrings("2a01:1700:2:ffff::9f01", buf[0..len]);
}

test "copyFieldAutoIpv6 - ipv4 passthrough" {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    copyFieldAutoIpv6("10.67.57.164", &buf, &len, false);
    try std.testing.expectEqualStrings("10.67.57.164", buf[0..len]);
}

test "CGCONTRDP field indices - IPv4 with MTU 1500" {
    const line = "3,5,internet.mnc003.mcc260.gprs,10.67.57.91.255.255.255.0,10.67.57.164,194.204.159.1,194.204.152.34,,,0,0,1500";
    var fields: [16][]const u8 = undefined;
    const count = at.splitFields(line, &fields);
    try std.testing.expectEqual(@as(usize, 12), count);
    try std.testing.expectEqualStrings("3", fields[0]);       // cid
    try std.testing.expectEqualStrings("5", fields[1]);       // bearer
    try std.testing.expectEqualStrings("internet.mnc003.mcc260.gprs", fields[2]); // apn
    try std.testing.expectEqualStrings("10.67.57.91.255.255.255.0", fields[3]); // ip+mask
    try std.testing.expectEqualStrings("10.67.57.164", fields[4]); // gw
    try std.testing.expectEqualStrings("194.204.159.1", fields[5]); // dns1
    try std.testing.expectEqualStrings("194.204.152.34", fields[6]); // dns2
    try std.testing.expectEqualStrings("1500", fields[11]);   // MTU
}

test "CGCONTRDP field indices - IPv6 with MTU 0" {
    const line = "3,5,internetipv6.mnc003.mcc260.gprs,42.0.15.65.24.215.186.128.0.0.0.55.63.87.204.1.255.255.255.255.255.255.255.255.0.0.0.0.0.0.0.0,254.128.0.0.0.0.0.0.0.0.0.55.63.87.204.64,42.1.23.0.0.2.255.255.0.0.0.0.0.0.159.1,42.1.23.0.0.3.255.255.0.0.0.0.0.0.152.34,,,0,0,0";
    var fields: [16][]const u8 = undefined;
    const count = at.splitFields(line, &fields);
    try std.testing.expectEqual(@as(usize, 12), count);
    try std.testing.expectEqualStrings("42.0.15.65.24.215.186.128.0.0.0.55.63.87.204.1.255.255.255.255.255.255.255.255.0.0.0.0.0.0.0.0", fields[3]);
    try std.testing.expectEqualStrings("254.128.0.0.0.0.0.0.0.0.0.55.63.87.204.64", fields[4]); // gw
    try std.testing.expectEqualStrings("42.1.23.0.0.2.255.255.0.0.0.0.0.0.159.1", fields[5]); // dns1
    try std.testing.expectEqualStrings("42.1.23.0.0.3.255.255.0.0.0.0.0.0.152.34", fields[6]); // dns2
    try std.testing.expectEqualStrings("0", fields[11]); // MTU = 0 for IPv6
}

fn ipv4MaskToPrefix(mask_str: []const u8) u8 {
    var octets: [4]u8 = .{ 255, 255, 255, 0 };
    var iter = std.mem.splitScalar(u8, mask_str, '.');
    var i: usize = 0;
    while (iter.next()) |octet_str| {
        if (i >= 4) break;
        octets[i] = std.fmt.parseInt(u8, octet_str, 10) catch 0;
        i += 1;
    }

    var prefix: u8 = 0;
    for (octets) |octet| {
        var o = octet;
        while (o & 0x80 != 0) {
            prefix += 1;
            o <<= 1;
        }
    }
    return prefix;
}

fn ipv6MaskToPrefix(mask_str: []const u8) u8 {
    var groups: [8]u16 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    var iter = std.mem.splitScalar(u8, mask_str, ':');
    var i: usize = 0;
    while (iter.next()) |group_str| {
        if (i >= 8) break;
        groups[i] = std.fmt.parseInt(u16, group_str, 16) catch 0;
        i += 1;
    }

    var prefix: u8 = 0;
    for (groups) |group| {
        var g = group;
        var bits: u8 = 0;
        while (bits < 16 and g & 0x8000 != 0) {
            prefix += 1;
            g <<= 1;
            bits += 1;
        }
        if (bits < 16) break;
    }
    return prefix;
}
