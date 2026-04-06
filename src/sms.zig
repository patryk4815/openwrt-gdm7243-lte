const std = @import("std");
const at = @import("at.zig");
const log = std.log.scoped(.sms);

pub const Sms = struct {
    index: u16 = 0,
    status: [16]u8 = undefined,
    status_len: usize = 0,
    sender: [32]u8 = undefined,
    sender_len: usize = 0,
    timestamp: [32]u8 = undefined,
    timestamp_len: usize = 0,
    text: [320]u8 = undefined,
    text_len: usize = 0,
    dcs: u8 = 0, // data coding scheme

    pub fn getStatus(self: *const Sms) []const u8 {
        return self.status[0..self.status_len];
    }
    pub fn getSender(self: *const Sms) []const u8 {
        return self.sender[0..self.sender_len];
    }
    pub fn getTimestamp(self: *const Sms) []const u8 {
        return self.timestamp[0..self.timestamp_len];
    }
    pub fn getText(self: *const Sms) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub fn querySmsList() !at.AtResponse {
    // Set PDU mode
    _ = try at.send("AT+CMGF=0");
    // List all messages (4 = all)
    return try at.sendWithTimeout("AT+CMGL=4", 15);
}

/// Stream SMS list — calls callback for each decoded SMS, no buffer limit
pub fn streamSmsList(ctx: *usize, cb: *const fn (*const Sms, *usize) void) !bool {
    _ = try at.send("AT+CMGF=0");

    var header_line: [256]u8 = undefined;
    var header_len: usize = 0;
    var have_header: bool = false;

    const Ctx = struct {
        header_line: *[256]u8,
        header_len: *usize,
        have_header: *bool,
        cb: *const fn (*const Sms, *usize) void,
        user_ctx: *usize,
    };

    var state = Ctx{
        .header_line = &header_line,
        .header_len = &header_len,
        .have_header = &have_header,
        .cb = cb,
        .user_ctx = ctx,
    };

    return try at.sendStreaming("AT+CMGL=4", 15, &state, struct {
        fn lineCb(line: []const u8, s: *Ctx) void {
            if (std.mem.startsWith(u8, line, "+CMGL: ")) {
                const len = @min(line.len, s.header_line.len);
                @memcpy(s.header_line[0..len], line[0..len]);
                s.header_len.* = len;
                s.have_header.* = true;
            } else if (s.have_header.*) {
                s.have_header.* = false;
                var msg = Sms{};

                const header = s.header_line["+CMGL: ".len..s.header_len.*];
                var fields = std.mem.splitScalar(u8, header, ',');
                if (fields.next()) |idx_str| {
                    msg.index = std.fmt.parseInt(u16, idx_str, 10) catch 0;
                }
                if (fields.next()) |status_raw| {
                    const st = std.mem.trim(u8, status_raw, "\"");
                    const slen = @min(st.len, msg.status.len);
                    @memcpy(msg.status[0..slen], st[0..slen]);
                    msg.status_len = slen;
                }

                decodePdu(line, &msg);
                s.cb(&msg, s.user_ctx);
            }
        }
    }.lineCb);
}

pub fn queryReadSms(index: u16) !at.AtResponse {
    _ = try at.send("AT+CMGF=0");
    var buf: [32]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "AT+CMGR={d}", .{index}) catch return error.ParseError;
    return try at.sendWithTimeout(cmd, 10);
}

pub fn deleteSms(index: u16) !bool {
    var buf: [32]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "AT+CMGD={d},0", .{index}) catch return error.ParseError;
    const resp = try at.send(cmd);
    return resp.ok;
}

pub fn deleteAllSms() !bool {
    const resp = try at.send("AT+CMGD=1,4");
    return resp.ok;
}

/// Parse CMGL response, calling callback for each SMS (no heap/stack buffer needed)
pub fn parseSmsListCb(data: []const u8, ctx: anytype, cb: fn (*const Sms, @TypeOf(ctx)) void) void {
    var lines = std.mem.splitSequence(u8, data, "\r\n");

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n");

        if (std.mem.startsWith(u8, trimmed, "+CMGL: ")) {
            const rest = trimmed["+CMGL: ".len..];
            var msg = Sms{};

            var fields = std.mem.splitScalar(u8, rest, ',');
            if (fields.next()) |idx_str| {
                msg.index = std.fmt.parseInt(u16, idx_str, 10) catch 0;
            }
            if (fields.next()) |status_raw| {
                const s = std.mem.trim(u8, status_raw, "\"");
                const len = @min(s.len, msg.status.len);
                @memcpy(msg.status[0..len], s[0..len]);
                msg.status_len = len;
            }

            if (lines.next()) |pdu_line| {
                const pdu_trimmed = std.mem.trim(u8, pdu_line, " \r\n");
                if (pdu_trimmed.len > 0) {
                    decodePdu(pdu_trimmed, &msg);
                    cb(&msg, ctx);
                }
            }
        }
    }
}

/// Decode PDU hex string into SMS fields
/// GDM7243 returns PDU without SMSC header — byte 0 is PDU type directly
fn decodePdu(hex: []const u8, msg: *Sms) void {
    var pdu: [256]u8 = undefined;
    const pdu_len = hexToBytes(hex, &pdu) catch return;
    if (pdu_len < 10) return;

    var pos: usize = 0;

    // PDU type (no SMSC header from this modem)
    const pdu_type = pdu[pos];
    const has_udhi = (pdu_type >> 6) & 1 == 1;
    pos += 1;

    // Sender address length (number of useful semi-octets/digits)
    if (pos >= pdu_len) return;
    const sender_digits = pdu[pos];
    pos += 1;

    // Sender type of address
    if (pos >= pdu_len) return;
    const sender_toa = pdu[pos];
    pos += 1;

    // Sender address data
    const sender_bytes = (sender_digits + 1) / 2;
    if (pos + sender_bytes > pdu_len) return;

    if (sender_toa & 0x70 == 0x50) {
        // Alphanumeric sender — GSM 7-bit encoded
        const alpha_chars: u8 = sender_digits * 4 / 7;
        var sender_buf: [320]u8 = undefined;
        var sender_len: usize = 0;
        decodeGsm7(pdu[pos .. pos + sender_bytes], alpha_chars, 0, &sender_buf, &sender_len);
        const copy_len = @min(sender_len, msg.sender.len);
        @memcpy(msg.sender[0..copy_len], sender_buf[0..copy_len]);
        msg.sender_len = copy_len;
    } else {
        // Numeric sender — BCD swapped
        decodeBcdNumber(pdu[pos .. pos + sender_bytes], sender_digits, sender_toa, &msg.sender, &msg.sender_len);
    }
    pos += sender_bytes;

    // PID
    if (pos >= pdu_len) return;
    pos += 1;

    // DCS (data coding scheme)
    if (pos >= pdu_len) return;
    msg.dcs = pdu[pos];
    pos += 1;

    // Timestamp (7 bytes, BCD swapped)
    if (pos + 7 > pdu_len) return;
    decodeTimestamp(pdu[pos .. pos + 7], &msg.timestamp, &msg.timestamp_len);
    pos += 7;

    // User data length (septets for 7-bit, bytes for UCS-2/8-bit)
    if (pos >= pdu_len) return;
    const ud_len = pdu[pos];
    pos += 1;

    if (pos >= pdu_len) return;
    const ud = pdu[pos..pdu_len];

    // Handle UDH if present
    var text_offset: usize = 0;
    var skip_bits: u3 = 0;
    var text_chars = ud_len;

    if (has_udhi and ud.len > 0) {
        const udh_len = ud[0];
        const udh_total = @as(usize, udh_len) + 1;
        text_offset = udh_total;

        if (msg.dcs & 0x0C == 0x00) {
            // GSM 7-bit: calculate fill bits for septet alignment
            const udh_bits = udh_total * 8;
            const fill = (7 - (udh_bits % 7)) % 7;
            skip_bits = @intCast(fill);
            const udh_septets: u8 = @intCast((udh_bits + fill) / 7);
            text_chars = if (ud_len > udh_septets) ud_len - udh_septets else 0;
        } else {
            // UCS-2/8-bit: UDH bytes are included in ud_len
            text_chars = if (ud_len > udh_total) @intCast(ud_len - udh_total) else 0;
        }
    }

    if (msg.dcs & 0x0C == 0x08) {
        // UCS-2 encoding
        if (text_offset < ud.len) {
            decodeUcs2(ud[text_offset..], text_chars, &msg.text, &msg.text_len);
        }
    } else if (msg.dcs & 0x0C == 0x00) {
        // GSM 7-bit encoding
        if (text_offset < ud.len) {
            decodeGsm7(ud[text_offset..], text_chars, skip_bits, &msg.text, &msg.text_len);
        }
    } else {
        // 8-bit or unknown — output as hex
        if (text_offset < ud.len) {
            const raw = ud[text_offset..];
            const len = @min(raw.len * 2, msg.text.len);
            for (raw[0..len / 2], 0..) |b, i| {
                msg.text[i * 2] = "0123456789ABCDEF"[b >> 4];
                msg.text[i * 2 + 1] = "0123456789ABCDEF"[b & 0x0F];
            }
            msg.text_len = len;
        }
    }
}

fn hexToBytes(hex: []const u8, out: []u8) !usize {
    if (hex.len % 2 != 0) return error.InvalidLength;
    const len = hex.len / 2;
    if (len > out.len) return error.BufferTooSmall;
    for (0..len) |i| {
        const hi: u8 = hexDigit(hex[i * 2]) orelse return error.InvalidHex;
        const lo: u8 = hexDigit(hex[i * 2 + 1]) orelse return error.InvalidHex;
        out[i] = (hi << 4) | lo;
    }
    return len;
}

fn hexDigit(c: u8) ?u4 {
    return switch (c) {
        '0'...'9' => @intCast(c - '0'),
        'A'...'F' => @intCast(c - 'A' + 10),
        'a'...'f' => @intCast(c - 'a' + 10),
        else => null,
    };
}

fn decodeBcdNumber(bcd: []const u8, digits: u8, toa: u8, out: *[32]u8, out_len: *usize) void {
    var pos: usize = 0;
    // International number prefix
    if (toa & 0x70 == 0x10) {
        if (pos < out.len) {
            out[pos] = '+';
            pos += 1;
        }
    }
    for (bcd) |b| {
        if (pos >= out.len or pos >= digits + 1) break;
        const lo = b & 0x0F;
        const hi = (b >> 4) & 0x0F;
        if (lo <= 9 and pos < digits + 1) {
            out[pos] = '0' + @as(u8, lo);
            pos += 1;
        }
        if (hi <= 9 and pos < digits + 1) {
            out[pos] = '0' + @as(u8, hi);
            pos += 1;
        }
    }
    // Remove trailing filler
    if (pos > 0 and pos > digits) pos = digits;
    if (toa & 0x70 == 0x10) pos += 0; // already counted +
    out_len.* = pos;
}

fn decodeTimestamp(ts: []const u8, out: *[32]u8, out_len: *usize) void {
    if (ts.len < 7) return;
    // BCD swapped: YY/MM/DD HH:MM:SS
    var fbs = std.io.fixedBufferStream(out);
    const w = fbs.writer();
    w.print("20{d:0>2}/{d:0>2}/{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        bcdSwap(ts[0]), bcdSwap(ts[1]), bcdSwap(ts[2]),
        bcdSwap(ts[3]), bcdSwap(ts[4]), bcdSwap(ts[5]),
    }) catch return;
    out_len.* = fbs.pos;
}

fn bcdSwap(b: u8) u8 {
    return (b & 0x0F) * 10 + ((b >> 4) & 0x0F);
}

/// Decode GSM 7-bit packed encoding
fn decodeGsm7(data: []const u8, char_count: u8, skip_bits: u3, out: *[320]u8, out_len: *usize) void {
    // GSM 03.38 basic character set (128 entries)
    const gsm7_table = [128]u8{
        '@',  0xA3, '$',  0xA5, 0xE8, 0xE9, 0xF9, 0xEC, // 0-7
        0xF2, 0xC7, '\n', 0xD8, 0xF8, '\r', 0xC5, 0xE5, // 8-15
        ' ',  '_',  ' ',  ' ',  ' ',  ' ',  ' ',  ' ',  // 16-23 (control chars → space)
        ' ',  ' ',  ' ',  ' ',  0xC6, 0xE6, 0xDF, 0xC9, // 24-31
        ' ',  '!',  '"',  '#',  0xA4, '%',  '&',  '\'', // 32-39
        '(',  ')',  '*',  '+',  ',',  '-',  '.',  '/',  // 40-47
        '0',  '1',  '2',  '3',  '4',  '5',  '6',  '7',  // 48-55
        '8',  '9',  ':',  ';',  '<',  '=',  '>',  '?',  // 56-63
        0xA1, 'A',  'B',  'C',  'D',  'E',  'F',  'G',  // 64-71
        'H',  'I',  'J',  'K',  'L',  'M',  'N',  'O',  // 72-79
        'P',  'Q',  'R',  'S',  'T',  'U',  'V',  'W',  // 80-87
        'X',  'Y',  'Z',  0xC4, 0xD6, 0xD1, 0xDC, 0xA7, // 88-95
        0xBF, 'a',  'b',  'c',  'd',  'e',  'f',  'g',  // 96-103
        'h',  'i',  'j',  'k',  'l',  'm',  'n',  'o',  // 104-111
        'p',  'q',  'r',  's',  't',  'u',  'v',  'w',  // 112-119
        'x',  'y',  'z',  0xE4, 0xF6, 0xF1, 0xFC, 0xE0, // 120-127
    };

    var bit_pos: usize = skip_bits;
    var chars: usize = 0;

    while (chars < char_count and chars < out.len) {
        const byte_idx = bit_pos / 8;
        const bit_offset: u3 = @intCast(bit_pos % 8);

        if (byte_idx >= data.len) break;

        var val: u8 = data[byte_idx] >> bit_offset;
        if (bit_offset > 1 and byte_idx + 1 < data.len) {
            const shift: u3 = @intCast(8 - @as(u4, bit_offset));
            val |= data[byte_idx + 1] << shift;
        }
        val &= 0x7F;

        out[chars] = gsm7_table[val];

        bit_pos += 7;
        chars += 1;
    }
    out_len.* = chars;
}

/// Decode UCS-2 (UTF-16 BE) to UTF-8
fn decodeUcs2(data: []const u8, char_count: u8, out: *[320]u8, out_len: *usize) void {
    var pos: usize = 0;
    var i: usize = 0;
    const byte_count = @as(usize, char_count);

    while (i + 1 < data.len and i < byte_count) {
        const code: u16 = (@as(u16, data[i]) << 8) | data[i + 1];

        if (code < 0x80) {
            if (pos >= out.len) break;
            out[pos] = @intCast(code);
            pos += 1;
        } else if (code < 0x800) {
            if (pos + 1 >= out.len) break;
            out[pos] = @intCast(0xC0 | (code >> 6));
            out[pos + 1] = @intCast(0x80 | (code & 0x3F));
            pos += 2;
        } else {
            if (pos + 2 >= out.len) break;
            out[pos] = @intCast(0xE0 | (code >> 12));
            out[pos + 1] = @intCast(0x80 | ((code >> 6) & 0x3F));
            out[pos + 2] = @intCast(0x80 | (code & 0x3F));
            pos += 3;
        }
        i += 2;
    }
    out_len.* = pos;
}

// --- Tests ---

test "hexToBytes" {
    var out: [8]u8 = undefined;
    const len = try hexToBytes("0123456789ABCDEF", &out);
    try std.testing.expectEqual(@as(usize, 8), len);
    try std.testing.expectEqual(@as(u8, 0x01), out[0]);
    try std.testing.expectEqual(@as(u8, 0xEF), out[7]);
}

test "bcdSwap" {
    try std.testing.expectEqual(@as(u8, 21), bcdSwap(0x12));
    try std.testing.expectEqual(@as(u8, 90), bcdSwap(0x09));
}

test "decodeGsm7 - hello" {
    // "hellohello" in GSM 7-bit packed
    const gsm7_packed = [_]u8{ 0xE8, 0x32, 0x9B, 0xFD, 0x46, 0x97, 0xD9, 0xEC, 0x37 };
    var out: [320]u8 = undefined;
    var len: usize = 0;
    decodeGsm7(&gsm7_packed, 10, 0, &out, &len);
    try std.testing.expectEqualStrings("hellohello", out[0..len]);
}

test "decodeUcs2 - ASCII" {
    const data = [_]u8{ 0x00, 0x48, 0x00, 0x69 }; // "Hi"
    var out: [320]u8 = undefined;
    var len: usize = 0;
    decodeUcs2(&data, 4, &out, &len);
    try std.testing.expectEqualStrings("Hi", out[0..len]);
}
