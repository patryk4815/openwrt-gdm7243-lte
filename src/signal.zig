const std = @import("std");
const at = @import("at.zig");
const log = std.log.scoped(.signal);

// --- Structs ---

pub const ConnStatus = struct {
    temperature: i32 = 0,
    band: u16 = 0,
    bandwidth_mhz: u8 = 0,
    dl_earfcn: u32 = 0,
    ul_earfcn: u32 = 0,
    mcc: u16 = 0,
    mnc: u16 = 0,
    tac: u32 = 0,
    pci: u16 = 0,
    cell_id: u32 = 0,
    rsrp: [2]i32 = .{ 0, 0 },
    rsrp_avg: i32 = 0,
    sinr: i32 = 0,
    rssi: [2]i32 = .{ 0, 0 },
    rssi_avg: i32 = 0,
    rsrq: [2]i32 = .{ 0, 0 },
    rsrq_avg: i32 = 0,
    // stored as x10 for one decimal place
    cinr: [2]i32 = .{ 0, 0 },
    tx_power_x10: i32 = 0,
};

pub const Carrier = struct {
    active: bool = false,
    scc_idx: u8 = 0,
    pci: u16 = 0,
    bw_code: u8 = 0,
    freq_mhz_x10: i32 = 0, // freq * 10 to avoid floats
    rssi: [2]i32 = .{ 0, 0 },
    rsrq: [2]i32 = .{ 0, 0 },
    rsrp: [2]i32 = .{ 0, 0 },
    cinr: [2]i32 = .{ 0, 0 },
};

pub const BandInfo = struct {
    bands: [32]u16 = undefined,
    count: usize = 0,
};

// --- Query functions (send AT + parse) ---

pub fn queryConnStatus() !ConnStatus {
    const resp = try at.sendWithTimeout("AT%GLTECONNSTATUS", 10);
    return parseConnStatus(resp.raw[0..resp.raw_len]);
}

pub fn queryCarriers() ![3]Carrier {
    const resp = try at.sendWithTimeout("AT%GDMITEM?", 10);
    return parseCarriers(resp.raw[0..resp.raw_len]);
}

pub fn queryBands() !BandInfo {
    const resp = try at.send("AT%GGETBAND?");
    return parseBands(resp.raw[0..resp.raw_len]);
}

pub const CellPair = struct {
    earfcn: []const u8,
    pci: []const u8,
};

/// Lock primary cell(s). Format: AT%GLOCKCELL=<numCell>,<earfcn1>,<pci1>[,<earfcn2>,<pci2>...]
pub fn lockCell(pairs: []const CellPair) !bool {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.print("AT%GLOCKCELL={d}", .{pairs.len}) catch return error.ParseError;
    for (pairs) |p| {
        w.print(",{s},{s}", .{ p.earfcn, p.pci }) catch return error.ParseError;
    }
    const cmd = buf[0..fbs.pos];
    const resp = try at.send(cmd);
    return resp.ok;
}

pub fn unlockCell() !bool {
    const resp = try at.send("AT%GLOCKCELL=1,0,0");
    return resp.ok;
}

/// Lock secondary cell(s) for CA. Format: AT%GLOCKSCELL=<numCell>,<earfcn1>,<pci1>[,...]
pub fn lockSCell(pairs: []const CellPair) !bool {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.print("AT%GLOCKSCELL={d}", .{pairs.len}) catch return error.ParseError;
    for (pairs) |p| {
        w.print(",{s},{s}", .{ p.earfcn, p.pci }) catch return error.ParseError;
    }
    const cmd = buf[0..fbs.pos];
    const resp = try at.send(cmd);
    return resp.ok;
}

pub fn unlockSCell() !bool {
    const resp = try at.send("AT%GLOCKSCELL=1,0,0");
    return resp.ok;
}

pub const FreqRange = struct {
    band: []const u8,
    start_earfcn: []const u8,
    end_earfcn: []const u8,
};

/// Set frequency range(s). Format: AT%GFREQRNG=<band1>,<st1>,<ed1>[,<band2>,<st2>,<ed2>,...]
pub fn setFreqRange(ranges: []const FreqRange) !bool {
    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.writeAll("AT%GFREQRNG=") catch return error.ParseError;
    for (ranges, 0..) |r, i| {
        if (i > 0) w.writeAll(",") catch return error.ParseError;
        w.print("{s},{s},{s}", .{ r.band, r.start_earfcn, r.end_earfcn }) catch return error.ParseError;
    }
    const cmd = buf[0..fbs.pos];
    const resp = try at.send(cmd);
    return resp.ok;
}

pub fn queryFreqRange() !at.AtResponse {
    return try at.send("AT%GFREQRNG?");
}

pub const FreqRangeBands = struct { bands: [8]u16 = undefined, count: usize = 0 };

/// Parse %GFREGRNG: response to extract band numbers
pub fn parseFreqRangeBands(data: []const u8) FreqRangeBands {
    var result = FreqRangeBands{};
    // Format: %GFREGRNG: 3,1800,1850,7,3000,3100
    const prefix = "%GFREGRNG: ";
    const start = std.mem.indexOf(u8, data, prefix) orelse return result;
    const vals_start = start + prefix.len;
    const line_end = std.mem.indexOfScalar(u8, data[vals_start..], '\r') orelse
        std.mem.indexOfScalar(u8, data[vals_start..], '\n') orelse
        (data.len - vals_start);
    const line = data[vals_start .. vals_start + line_end];
    if (line.len == 0) return result;

    // Every 3rd value is a band number (band,st,ed,band,st,ed,...)
    var iter = std.mem.splitScalar(u8, line, ',');
    var i: usize = 0;
    while (iter.next()) |field| {
        if (i % 3 == 0) {
            const band = std.fmt.parseInt(u16, std.mem.trim(u8, field, " "), 10) catch {
                i += 1;
                continue;
            };
            if (result.count < result.bands.len) {
                result.bands[result.count] = band;
                result.count += 1;
            }
        }
        i += 1;
    }
    return result;
}

/// Clear all frequency ranges by querying current bands and clearing each
pub fn clearFreqRange() !bool {
    const resp = try at.send("AT%GFREQRNG?");
    const info = parseFreqRangeBands(resp.raw[0..resp.raw_len]);
    if (info.count == 0) return true;

    var buf: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    w.writeAll("AT%GFREQRNG=") catch return error.ParseError;
    for (info.bands[0..info.count], 0..) |band, i| {
        if (i > 0) w.writeAll(",") catch return error.ParseError;
        w.print("{d},0,0", .{band}) catch return error.ParseError;
    }
    const cmd = buf[0..fbs.pos];
    const clear_resp = try at.send(cmd);
    return clear_resp.ok;
}

/// Unlock all locks (cell + secondary cell)
pub fn unlockAll() !bool {
    const r1 = try at.send("AT%GLOCKCELL=1,0,0");
    const r2 = try at.send("AT%GLOCKSCELL=1,0,0");
    return r1.ok and r2.ok;
}

// --- Parsers ---

pub fn parseConnStatus(data: []const u8) ConnStatus {
    var s = ConnStatus{};
    s.temperature = findInt(i32, data, "Temperature ") orelse 0;
    s.band = findInt(u16, data, "Band ") orelse 0;
    s.bandwidth_mhz = findInt(u8, data, "lteBW ") orelse 0;
    s.dl_earfcn = findInt(u32, data, "dlEarfcn ") orelse 0;
    s.ul_earfcn = findInt(u32, data, "ulEarfcn ") orelse 0;
    s.mcc = findInt(u16, data, "MCC ") orelse 0;
    s.mnc = findInt(u16, data, "MNC ") orelse 0;
    s.tac = findInt(u32, data, "Tac ") orelse 0;
    s.pci = findInt(u16, data, "phyCID ") orelse 0;
    s.cell_id = findInt(u32, data, "nasCID ") orelse 0;
    s.sinr = findInt(i32, data, "pccSINR ") orelse 0;

    if (findCsvInts(data, "pccRSRP ")) |vals| {
        s.rsrp[0] = vals[0];
        s.rsrp[1] = vals[1];
        if (findAvg(data, "pccRSRP ")) |avg| s.rsrp_avg = avg;
    }
    if (findCsvInts(data, "pccRSSI ")) |vals| {
        s.rssi[0] = vals[0];
        s.rssi[1] = vals[1];
        if (findAvg(data, "pccRSSI ")) |avg| s.rssi_avg = avg;
    }
    if (findCsvInts(data, "pccRSRQ ")) |vals| {
        s.rsrq[0] = vals[0];
        s.rsrq[1] = vals[1];
        if (findAvg(data, "pccRSRQ ")) |avg| s.rsrq_avg = avg;
    }
    if (findCsvFixed(data, "pccCINR ")) |vals| {
        s.cinr[0] = vals[0];
        s.cinr[1] = vals[1];
    }
    s.tx_power_x10 = findFixed(data, "tx_power ") orelse 0;

    return s;
}

pub fn parseCarriers(data: []const u8) [3]Carrier {
    var carriers: [3]Carrier = .{ Carrier{}, Carrier{}, Carrier{} };

    // Find each SCC block by "SCC_IDX, N"
    var search_from: usize = 0;
    while (search_from < data.len) {
        const idx_pos = std.mem.indexOf(u8, data[search_from..], "SCC_IDX, ") orelse break;
        const abs_pos = search_from + idx_pos;
        const val_pos = abs_pos + "SCC_IDX, ".len;
        if (val_pos >= data.len) break;

        const idx_val = std.fmt.parseInt(u8, data[val_pos .. val_pos + 1], 10) catch {
            search_from = val_pos + 1;
            continue;
        };
        if (idx_val < 1 or idx_val > 3) {
            search_from = val_pos + 1;
            continue;
        }

        // Block: from PCI line (before SCC_IDX) to next SCC_IDX or end
        // Find the PCI line start — go back to find "PCI, " before this SCC_IDX
        const line_start = if (std.mem.lastIndexOf(u8, data[0..abs_pos], "PCI, ")) |p| p else abs_pos;

        const next_scc = if (std.mem.indexOf(u8, data[val_pos + 1 ..], "SCC_IDX, ")) |p|
            val_pos + 1 + p
        else
            data.len;

        // Find PCI line start for the next block to get proper boundary
        const block_end = if (next_scc < data.len)
            if (std.mem.lastIndexOf(u8, data[0..next_scc], "PCI, ")) |p| p else next_scc
        else
            data.len;

        const block = data[line_start..block_end];
        var c = &carriers[idx_val - 1];
        c.active = true;
        c.scc_idx = idx_val;

        c.pci = findInt(u16, block, "PCI, ") orelse 0;
        c.bw_code = findInt(u8, block, "BW, ") orelse 0;
        c.freq_mhz_x10 = findFixed(block, "FREQ, ") orelse 0;

        c.rssi = parsePair(block, "M-RSSI, (", "D-RSSI, (");
        c.rsrq = parsePair(block, "M-RSRQ, (", "D-RSRQ, (");
        c.rsrp = parsePair(block, "M-RSRP, (", "D-RSRP, (");
        c.cinr = parsePair(block, "M-CINR, (", "D-CINR, (");

        search_from = val_pos + 1;
    }

    return carriers;
}

pub fn parseBands(data: []const u8) BandInfo {
    var info = BandInfo{};

    // Format: %GGETBAND: 8,1,3,7,8,20
    // First value is unknown/current, rest are supported bands
    const prefix = "%GGETBAND: ";
    const start = std.mem.indexOf(u8, data, prefix) orelse return info;
    const vals_start = start + prefix.len;
    const line_end = std.mem.indexOfScalar(u8, data[vals_start..], '\r') orelse
        std.mem.indexOfScalar(u8, data[vals_start..], '\n') orelse
        (data.len - vals_start);
    const line = data[vals_start .. vals_start + line_end];

    // Skip first value
    var iter = std.mem.splitScalar(u8, line, ',');
    _ = iter.next(); // skip first

    while (iter.next()) |field| {
        const trimmed = std.mem.trim(u8, field, " ");
        const band = std.fmt.parseInt(u16, trimmed, 10) catch continue;
        if (info.count < info.bands.len) {
            info.bands[info.count] = band;
            info.count += 1;
        }
    }

    return info;
}

pub fn bwCodeToMhz(code: u8) u8 {
    return switch (code) {
        0 => 1, // 1.4 MHz, approximate
        1 => 3,
        2 => 5,
        3 => 10,
        4 => 15,
        5 => 20,
        else => 0,
    };
}

// --- Helpers ---

fn findInt(comptime T: type, data: []const u8, key: []const u8) ?T {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    const start = pos + key.len;
    if (start >= data.len) return null;
    // Find end of number (digit, minus, or end)
    var end = start;
    if (end < data.len and data[end] == '-') end += 1;
    while (end < data.len and std.ascii.isDigit(data[end])) end += 1;
    if (end == start) return null;
    return std.fmt.parseInt(T, data[start..end], 10) catch null;
}

// Parse "key val1,val2,val3,val4" → first two as i32
fn findCsvInts(data: []const u8, key: []const u8) ?[2]i32 {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    const start = pos + key.len;
    if (start >= data.len) return null;

    const line_end = std.mem.indexOfScalar(u8, data[start..], '\n') orelse (data.len - start);
    const line = data[start .. start + line_end];

    var result: [2]i32 = .{ 0, 0 };
    var iter = std.mem.splitScalar(u8, line, ',');
    var i: usize = 0;
    while (iter.next()) |field| {
        if (i >= 2) break;
        const trimmed = std.mem.trim(u8, field, " \r");
        result[i] = std.fmt.parseInt(i32, trimmed, 10) catch break;
        i += 1;
    }
    if (i < 2) return null;
    return result;
}

// Find "A:value" after key line
fn findAvg(data: []const u8, key: []const u8) ?i32 {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    const rest = data[pos..];
    const a_pos = std.mem.indexOf(u8, rest, "A:") orelse return null;
    const start = a_pos + 2;
    if (start >= rest.len) return null;
    var end = start;
    if (end < rest.len and rest[end] == '-') end += 1;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    return std.fmt.parseInt(i32, rest[start..end], 10) catch null;
}

// Parse fixed-point: "8.9" → 89, "-55.0" → -550
fn parseFixedStr(s: []const u8) ?i32 {
    const trimmed = std.mem.trim(u8, s, " \r\n");
    if (std.mem.indexOfScalar(u8, trimmed, '.')) |dot| {
        const int_part = std.fmt.parseInt(i32, trimmed[0..dot], 10) catch return null;
        if (dot + 1 < trimmed.len and std.ascii.isDigit(trimmed[dot + 1])) {
            const frac = @as(i32, trimmed[dot + 1] - '0');
            return if (int_part < 0) int_part * 10 - frac else int_part * 10 + frac;
        }
        return int_part * 10;
    }
    return (std.fmt.parseInt(i32, trimmed, 10) catch return null) * 10;
}

// Find "key val1,val2,..." → first two as fixed x10
fn findCsvFixed(data: []const u8, key: []const u8) ?[2]i32 {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    const start = pos + key.len;
    const line_end = std.mem.indexOfScalar(u8, data[start..], '\n') orelse (data.len - start);
    const line = data[start .. start + line_end];

    var result: [2]i32 = .{ 0, 0 };
    var iter = std.mem.splitScalar(u8, line, ',');
    var i: usize = 0;
    while (iter.next()) |field| {
        if (i >= 2) break;
        result[i] = parseFixedStr(field) orelse break;
        i += 1;
    }
    if (i < 2) return null;
    return result;
}

// Find single fixed-point value after key, returns value * 10
fn findFixed(data: []const u8, key: []const u8) ?i32 {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    const start = pos + key.len;
    if (start >= data.len) return null;
    var end = start;
    if (end < data.len and data[end] == '-') end += 1;
    while (end < data.len and (std.ascii.isDigit(data[end]) or data[end] == '.')) end += 1;
    return parseFixedStr(data[start..end]);
}

// Parse "(val, 0)" pattern for M- and D- values
fn parsePair(data: []const u8, m_key: []const u8, d_key: []const u8) [2]i32 {
    return .{
        parseParenValue(data, m_key) orelse 0,
        parseParenValue(data, d_key) orelse 0,
    };
}

fn parseParenValue(data: []const u8, key: []const u8) ?i32 {
    const pos = std.mem.indexOf(u8, data, key) orelse return null;
    const start = pos + key.len;
    if (start >= data.len) return null;
    // Find comma or closing paren
    var end = start;
    if (end < data.len and data[end] == '-') end += 1;
    while (end < data.len and std.ascii.isDigit(data[end])) end += 1;
    return std.fmt.parseInt(i32, data[start..end], 10) catch null;
}

// --- JSON output ---

pub fn writeSignalJson(buf: []u8, status: *const ConnStatus, carriers: *const [3]Carrier) usize {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    w.print("{{\"temperature\":{d}", .{status.temperature}) catch return 0;
    w.print(",\"band\":{d}", .{status.band}) catch return 0;
    w.print(",\"bandwidth\":{d}", .{status.bandwidth_mhz}) catch return 0;
    w.print(",\"dl_earfcn\":{d}", .{status.dl_earfcn}) catch return 0;
    w.print(",\"ul_earfcn\":{d}", .{status.ul_earfcn}) catch return 0;
    w.print(",\"mcc\":{d},\"mnc\":{d}", .{ status.mcc, status.mnc }) catch return 0;
    w.print(",\"tac\":{d},\"pci\":{d},\"cell_id\":{d}", .{ status.tac, status.pci, status.cell_id }) catch return 0;
    w.print(",\"rsrp\":[{d},{d}],\"rsrp_avg\":{d}", .{ status.rsrp[0], status.rsrp[1], status.rsrp_avg }) catch return 0;
    w.print(",\"rsrq\":[{d},{d}],\"rsrq_avg\":{d}", .{ status.rsrq[0], status.rsrq[1], status.rsrq_avg }) catch return 0;
    w.print(",\"rssi\":[{d},{d}],\"rssi_avg\":{d}", .{ status.rssi[0], status.rssi[1], status.rssi_avg }) catch return 0;
    w.print(",\"sinr\":{d}", .{status.sinr}) catch return 0;
    writeFixed(w, ",\"cinr\":[", status.cinr[0]) catch return 0;
    writeFixed(w, ",", status.cinr[1]) catch return 0;
    w.writeAll("]") catch return 0;
    writeFixed(w, ",\"tx_power\":", status.tx_power_x10) catch return 0;

    // Carriers
    w.writeAll(",\"carriers\":[") catch return 0;
    var first = true;
    for (carriers) |c| {
        if (!c.active) continue;
        if (!first) w.writeAll(",") catch return 0;
        first = false;
        w.print("{{\"scc_idx\":{d},\"pci\":{d},\"bandwidth\":{d}", .{ c.scc_idx, c.pci, bwCodeToMhz(c.bw_code) }) catch return 0;
        writeFixed(w, ",\"frequency\":", c.freq_mhz_x10) catch return 0;
        w.print(",\"rsrp\":[{d},{d}]", .{ c.rsrp[0], c.rsrp[1] }) catch return 0;
        w.print(",\"rsrq\":[{d},{d}]", .{ c.rsrq[0], c.rsrq[1] }) catch return 0;
        w.print(",\"rssi\":[{d},{d}]", .{ c.rssi[0], c.rssi[1] }) catch return 0;
        w.print(",\"cinr\":[{d},{d}]", .{ c.cinr[0], c.cinr[1] }) catch return 0;
        w.writeAll("}") catch return 0;
    }
    w.writeAll("]}") catch return 0;

    return fbs.pos;
}

fn writeFixed(w: anytype, prefix: []const u8, val_x10: i32) !void {
    const abs = if (val_x10 < 0) @as(u32, @intCast(-val_x10)) else @as(u32, @intCast(val_x10));
    const sign: []const u8 = if (val_x10 < 0) "-" else "";
    try w.print("{s}{s}{d}.{d}", .{ prefix, sign, abs / 10, abs % 10 });
}

// --- Tests ---

const test_connstatus =
    \\%GLTECONNSTATUS:
    \\Temperature 41, Mode ONLINE,
    \\System mode LTE,
    \\csState 0, psState 1,
    \\Band 7, lteBW 15MHz,
    \\dlEarfcn 3025, ulEarfcn 21025,
    \\MCC 260, MNC 03,
    \\Tac 227(33), phyCID 270, nasCID 54884895,
    \\emmState 2, rrcState RRC IDLE,
    \\pccRSRP -112,-108,-140,-140,A:-108,
    \\pccCINR 8.9,13.0,-17.0,-17.0,
    \\pccSINR 12,
    \\pccRSSI -77,-75,-72,-74,A:-79,
    \\pccRSRQ -16,-13,-137,-133,A:-11,
    \\tx_power -55.0,
;

test "parseConnStatus - basic fields" {
    const s = parseConnStatus(test_connstatus);
    try std.testing.expectEqual(@as(i32, 41), s.temperature);
    try std.testing.expectEqual(@as(u16, 7), s.band);
    try std.testing.expectEqual(@as(u8, 15), s.bandwidth_mhz);
    try std.testing.expectEqual(@as(u32, 3025), s.dl_earfcn);
    try std.testing.expectEqual(@as(u32, 21025), s.ul_earfcn);
    try std.testing.expectEqual(@as(u16, 260), s.mcc);
    try std.testing.expectEqual(@as(u16, 3), s.mnc);
    try std.testing.expectEqual(@as(u32, 227), s.tac);
    try std.testing.expectEqual(@as(u16, 270), s.pci);
    try std.testing.expectEqual(@as(u32, 54884895), s.cell_id);
}

test "parseConnStatus - signal values" {
    const s = parseConnStatus(test_connstatus);
    try std.testing.expectEqual(@as(i32, -112), s.rsrp[0]);
    try std.testing.expectEqual(@as(i32, -108), s.rsrp[1]);
    try std.testing.expectEqual(@as(i32, -108), s.rsrp_avg);
    try std.testing.expectEqual(@as(i32, -77), s.rssi[0]);
    try std.testing.expectEqual(@as(i32, -75), s.rssi[1]);
    try std.testing.expectEqual(@as(i32, -79), s.rssi_avg);
    try std.testing.expectEqual(@as(i32, -16), s.rsrq[0]);
    try std.testing.expectEqual(@as(i32, -13), s.rsrq[1]);
    try std.testing.expectEqual(@as(i32, -11), s.rsrq_avg);
    try std.testing.expectEqual(@as(i32, 12), s.sinr);
}

test "parseConnStatus - fixed point" {
    const s = parseConnStatus(test_connstatus);
    try std.testing.expectEqual(@as(i32, 89), s.cinr[0]); // 8.9 * 10
    try std.testing.expectEqual(@as(i32, 130), s.cinr[1]); // 13.0 * 10
    try std.testing.expectEqual(@as(i32, -550), s.tx_power_x10); // -55.0 * 10
}

const test_gdmitem =
    \\%GDMITEM: "L1SCC", 3
    \\%GDMITEM: PCI, 270, BW, 4, FREQ, 2647.5, SCC_IDX, 1
    \\%GDMITEM: M-RSSI, (-42, 0), D-RSSI, (-88, 0)
    \\%GDMITEM: M-RSRQ, (-15, 0), D-RSRQ, (-102, 0)
    \\%GDMITEM: M-RSRP, (-76, 0), D-RSRP, (-140, 0)
    \\%GDMITEM: M-CINR, (3, 0), D-CINR, (-17, 0)
    \\%GDMITEM: DL_CW1_MCS, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    \\%GDMITEM: DL_CW2_MCS, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    \\
    \\%GDMITEM: PCI, 33, BW, 4, FREQ, 1857.5, SCC_IDX, 2
    \\%GDMITEM: M-RSSI, (-74, 0), D-RSSI, (-79, 0)
    \\%GDMITEM: M-RSRQ, (-158, 0), D-RSRQ, (-154, 0)
    \\%GDMITEM: M-RSRP, (-113, 0), D-RSRP, (-123, 0)
    \\%GDMITEM: M-CINR, (-17, 0), D-CINR, (-17, 0)
    \\%GDMITEM: DL_CW1_MCS, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    \\%GDMITEM: DL_CW2_MCS, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    \\
    \\%GDMITEM: PCI, 351, BW, 2, FREQ, 956.4, SCC_IDX, 3
    \\%GDMITEM: M-RSSI, (8, 0), D-RSSI, (-33, 0)
    \\%GDMITEM: M-RSRQ, (-17, 0), D-RSRQ, (-8, 0)
    \\%GDMITEM: M-RSRP, (-23, 0), D-RSRP, (-55, 0)
    \\%GDMITEM: M-CINR, (0, 0), D-CINR, (-17, 0)
    \\%GDMITEM: DL_CW1_MCS, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    \\%GDMITEM: DL_CW2_MCS, 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
;

test "parseCarriers - count and indices" {
    const carriers = parseCarriers(test_gdmitem);
    try std.testing.expect(carriers[0].active);
    try std.testing.expect(carriers[1].active);
    try std.testing.expect(carriers[2].active);
    try std.testing.expectEqual(@as(u8, 1), carriers[0].scc_idx);
    try std.testing.expectEqual(@as(u8, 2), carriers[1].scc_idx);
    try std.testing.expectEqual(@as(u8, 3), carriers[2].scc_idx);
}

test "parseCarriers - SCC1 values" {
    const c = parseCarriers(test_gdmitem)[0];
    try std.testing.expectEqual(@as(u16, 270), c.pci);
    try std.testing.expectEqual(@as(u8, 4), c.bw_code);
    try std.testing.expectEqual(@as(i32, -76), c.rsrp[0]);
    try std.testing.expectEqual(@as(i32, -140), c.rsrp[1]);
    try std.testing.expectEqual(@as(i32, -42), c.rssi[0]);
    try std.testing.expectEqual(@as(i32, -88), c.rssi[1]);
    try std.testing.expectEqual(@as(i32, -15), c.rsrq[0]);
    try std.testing.expectEqual(@as(i32, -102), c.rsrq[1]);
    try std.testing.expectEqual(@as(i32, 3), c.cinr[0]);
    try std.testing.expectEqual(@as(i32, -17), c.cinr[1]);
}

test "parseCarriers - SCC3 values" {
    const c = parseCarriers(test_gdmitem)[2];
    try std.testing.expectEqual(@as(u16, 351), c.pci);
    try std.testing.expectEqual(@as(u8, 2), c.bw_code);
    try std.testing.expectEqual(@as(i32, -23), c.rsrp[0]);
    try std.testing.expectEqual(@as(i32, -55), c.rsrp[1]);
    try std.testing.expectEqual(@as(i32, 8), c.rssi[0]);
}

test "parseBands" {
    const data = "%GGETBAND: 8,1,3,7,8,20\r\nOK";
    const info = parseBands(data);
    try std.testing.expectEqual(@as(usize, 5), info.count);
    try std.testing.expectEqual(@as(u16, 1), info.bands[0]);
    try std.testing.expectEqual(@as(u16, 3), info.bands[1]);
    try std.testing.expectEqual(@as(u16, 7), info.bands[2]);
    try std.testing.expectEqual(@as(u16, 8), info.bands[3]);
    try std.testing.expectEqual(@as(u16, 20), info.bands[4]);
}

test "bwCodeToMhz" {
    try std.testing.expectEqual(@as(u8, 5), bwCodeToMhz(2));
    try std.testing.expectEqual(@as(u8, 15), bwCodeToMhz(4));
    try std.testing.expectEqual(@as(u8, 20), bwCodeToMhz(5));
}

test "parseFixedStr" {
    try std.testing.expectEqual(@as(i32, 89), parseFixedStr("8.9").?);
    try std.testing.expectEqual(@as(i32, 130), parseFixedStr("13.0").?);
    try std.testing.expectEqual(@as(i32, -550), parseFixedStr("-55.0").?);
    try std.testing.expectEqual(@as(i32, -170), parseFixedStr("-17.0").?);
    try std.testing.expectEqual(@as(i32, 120), parseFixedStr("12").?);
}

test "writeSignalJson - produces valid json" {
    var status = parseConnStatus(test_connstatus);
    var carriers = parseCarriers(test_gdmitem);
    var buf: [4096]u8 = undefined;
    const len = writeSignalJson(&buf, &status, &carriers);
    try std.testing.expect(len > 0);
    const json = buf[0..len];
    // Check it starts and ends with braces
    try std.testing.expectEqual(@as(u8, '{'), json[0]);
    try std.testing.expectEqual(@as(u8, '}'), json[len - 1]);
    // Check key fields are present
    try std.testing.expect(std.mem.indexOf(u8, json, "\"band\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sinr\":12") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"carriers\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"scc_idx\":1") != null);
}

test "parseFreqRangeBands - multiple bands" {
    const data = "%GFREGRNG: 3,1800,1850,7,3000,3100\r\nOK";
    const info = parseFreqRangeBands(data);
    try std.testing.expectEqual(@as(usize, 2), info.count);
    try std.testing.expectEqual(@as(u16, 3), info.bands[0]);
    try std.testing.expectEqual(@as(u16, 7), info.bands[1]);
}

test "parseFreqRangeBands - empty" {
    const data = "%GFREGRNG: \r\nOK";
    const info = parseFreqRangeBands(data);
    try std.testing.expectEqual(@as(usize, 0), info.count);
}
