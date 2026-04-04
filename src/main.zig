const std = @import("std");
const config_mod = @import("config.zig");
const at = @import("at.zig");
const keepalive = @import("keepalive.zig");
const connect = @import("connect.zig");
const monitor = @import("monitor.zig");
const commands = @import("commands.zig");
const led = @import("led.zig");
const signal = @import("signal.zig");
const log = std.log.scoped(.gctd);

const CONFIG_PATH = "/etc/config/gctd";

pub const std_options = std.Options{
    .log_level = .info,
};

fn writeOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stdout().writeAll(msg) catch {};
}

fn writeErr(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    std.fs.File.stderr().writeAll(msg) catch {};
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip(); // skip argv[0]

    const subcmd = args.next();

    if (subcmd == null) {
        printUsage();
        return;
    }

    const cmd = subcmd.?;

    if (std.mem.eql(u8, cmd, "daemon")) {
        return daemonMode(&args);
    } else if (std.mem.eql(u8, cmd, "at")) {
        return cmdAt(&args);
    } else if (std.mem.eql(u8, cmd, "status")) {
        return cmdStatus();
    } else if (std.mem.eql(u8, cmd, "status-json")) {
        return cmdStatusJson();
    } else if (std.mem.eql(u8, cmd, "signal")) {
        return cmdSignal();
    } else if (std.mem.eql(u8, cmd, "signal-json")) {
        return cmdSignalJson();
    } else if (std.mem.eql(u8, cmd, "bands")) {
        return cmdBands();
    } else if (std.mem.eql(u8, cmd, "lockcell")) {
        return cmdLockCell(&args);
    } else if (std.mem.eql(u8, cmd, "lockscell")) {
        return cmdLockSCell(&args);
    } else if (std.mem.eql(u8, cmd, "freqrange")) {
        return cmdFreqRange(&args);
    } else if (std.mem.eql(u8, cmd, "unlock")) {
        return cmdUnlock();
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printUsage();
    } else {
        writeErr("Unknown command: {s}\n", .{cmd});
        printUsage();
    }
}

fn printUsage() void {
    writeOut(
        \\gctd — GCT GDM7243 LTE modem daemon for ZTE MF258
        \\
        \\Usage:
        \\  gctd daemon        Run as daemon (keepalive + connect + monitor)
        \\  gctd at "CMD"     Send AT command to modem
        \\  gctd status       Show modem status (signal, registration, IP)
        \\  gctd status-json  Same as status, but JSON output (for LuCI)
        \\  gctd signal       Detailed signal info (human-readable)
        \\  gctd signal-json  Detailed signal info + carrier aggregation (JSON)
        \\  gctd bands                  Show supported LTE bands
        \\  gctd lockcell E P [E P ...]  Lock primary cell(s) (earfcn+pci pairs)
        \\  gctd lockscell E P [E P ..] Lock secondary cell(s) for CA
        \\  gctd freqrange BAND ST ED   Set EARFCN range for band
        \\  gctd freqrange              Show current frequency ranges
        \\  gctd unlock                 Remove all cell locks
        \\  gctd help         Show this help
        \\
    , .{});
}

fn loadConfig() config_mod.Config {
    return config_mod.load(CONFIG_PATH);
}

fn setupAt(cfg: *const config_mod.Config) void {
    at.configure(cfg.modem_ip, cfg.at_port);
}

// --- Subcommands ---

fn cmdAt(args: *std.process.ArgIterator) void {
    const cfg = loadConfig();
    setupAt(&cfg);

    const cmd = args.next() orelse {
        writeErr("Usage: gctd at \"AT+COMMAND\"\n", .{});
        return;
    };

    const resp = at.send(cmd) catch |e| {
        writeErr("Error: {s}\n", .{@errorName(e)});
        return;
    };

    std.fs.File.stdout().writeAll(resp.raw[0..resp.raw_len]) catch {};
}

fn cmdStatus() void {
    const cfg = loadConfig();
    setupAt(&cfg);

    // SIM
    if (commands.querySimStatus()) |status| {
        const status_str: []const u8 = switch (status) {
            .ready => "Ready",
            .pin_required => "PIN required",
            .puk_required => "PUK required",
            .unknown => "Unknown",
        };
        writeOut("SIM: {s}\n", .{status_str});
    } else |_| {}

    // Registration
    if (commands.queryRegistration()) |status| {
        writeOut("Registration: {s}\n", .{regStatusStr(status)});
    } else |_| {}

    // Operator
    if (commands.queryOperator()) |info| {
        if (info.name_len > 0) writeOut("Operator: {s}\n", .{info.getName()});
    } else |_| {}

    // Signal
    if (commands.querySignal()) |info| {
        if (info.rsrp_dbm) |dbm| {
            writeOut("Signal: {d} dBm ({d}/4 bars)\n", .{ dbm, info.bars });
        } else {
            writeOut("Signal: unknown\n", .{});
        }
    } else |_| {}

    // IP + DNS
    if (commands.queryConnectionDetails(cfg.cid)) |info| {
        writeOut("IP: {s}/{d}\n", .{ info.getIp(), info.prefix });
        writeOut("GW: {s}\n", .{info.getGateway()});
        if (info.dns1_len > 0) writeOut("DNS1: {s}\n", .{info.getDns1()});
        if (info.dns2_len > 0) writeOut("DNS2: {s}\n", .{info.getDns2()});
        if (info.mtu != 1500) writeOut("MTU: {d}\n", .{info.mtu});
    } else |_| {}
}

fn regStatusStr(status: commands.RegStatus) []const u8 {
    return switch (status) {
        .not_registered => "Not registered",
        .home => "Registered (home)",
        .searching => "Searching...",
        .denied => "Registration denied",
        .roaming => "Registered (roaming)",
        .unknown => "Unknown",
    };
}

fn cmdStatusJson() void {
    const cfg = loadConfig();
    setupAt(&cfg);

    writeOut("{{", .{});

    // Operator
    if (commands.queryOperator()) |info| {
        writeOut("\"operator\":\"{s}\",", .{info.getName()});
    } else |_| {
        writeOut("\"operator\":\"\",", .{});
    }

    // Registration
    if (commands.queryRegistration()) |status| {
        writeOut("\"registration\":\"{s}\",", .{@tagName(status)});
    } else |_| {
        writeOut("\"registration\":\"unknown\",", .{});
    }

    // Signal
    if (commands.querySignal()) |info| {
        if (info.rsrp_dbm) |dbm| {
            writeOut("\"signal_dbm\":{d},\"signal_bars\":{d},", .{ dbm, info.bars });
        } else {
            writeOut("\"signal_dbm\":null,\"signal_bars\":0,", .{});
        }
    } else |_| {
        writeOut("\"signal_dbm\":null,\"signal_bars\":0,", .{});
    }

    // Connection details
    if (commands.queryConnectionDetails(cfg.cid)) |info| {
        writeOut("\"ip\":\"{s}\",\"prefix\":{d},\"gateway\":\"{s}\",", .{ info.getIp(), info.prefix, info.getGateway() });
        writeOut("\"dns1\":\"{s}\",\"dns2\":\"{s}\",\"mtu\":{d},", .{ info.getDns1(), info.getDns2(), info.mtu });
    } else |_| {
        writeOut("\"ip\":\"\",\"prefix\":0,\"gateway\":\"\",\"dns1\":\"\",\"dns2\":\"\",\"mtu\":0,", .{});
    }

    // SIM (last — no trailing comma)
    if (commands.querySimStatus()) |status| {
        writeOut("\"sim\":\"{s}\"", .{@tagName(status)});
    } else |_| {
        writeOut("\"sim\":\"unknown\"", .{});
    }

    writeOut("}}\n", .{});
}

fn cmdSignal() void {
    const cfg = loadConfig();
    setupAt(&cfg);

    const s = signal.queryConnStatus() catch |e| {
        writeErr("Error: {s}\n", .{@errorName(e)});
        return;
    };

    writeOut("Band {d} ({d} MHz)  EARFCN {d}/{d}\n", .{ s.band, s.bandwidth_mhz, s.dl_earfcn, s.ul_earfcn });
    writeOut("Cell  PCI {d}  ID {d}  TAC {d}\n", .{ s.pci, s.cell_id, s.tac });
    writeOut("PLMN  {d}/{d:0>2}\n", .{ s.mcc, s.mnc });
    writeOut("RSRP  {d} / {d} dBm  (avg {d})\n", .{ s.rsrp[0], s.rsrp[1], s.rsrp_avg });
    writeOut("RSRQ  {d} / {d} dB   (avg {d})\n", .{ s.rsrq[0], s.rsrq[1], s.rsrq_avg });
    writeOut("RSSI  {d} / {d} dBm  (avg {d})\n", .{ s.rssi[0], s.rssi[1], s.rssi_avg });
    writeOut("SINR  {d} dB\n", .{s.sinr});
    writeFixed2("CINR  ", s.cinr[0]);
    writeFixed2(" / ", s.cinr[1]);
    writeOut(" dB\n", .{});
    writeFixed2("TX    ", s.tx_power_x10);
    writeOut(" dBm\n", .{});
    writeOut("Temp  {d} C\n", .{s.temperature});

    const carriers = signal.queryCarriers() catch return;

    var has_ca = false;
    for (carriers) |c| {
        if (c.active) has_ca = true;
    }
    if (!has_ca) return;

    writeOut("\nCarrier Aggregation:\n", .{});
    for (carriers) |c| {
        if (!c.active) continue;
        writeOut("  SCC{d}  PCI {d}  {d} MHz  ", .{ c.scc_idx, c.pci, signal.bwCodeToMhz(c.bw_code) });
        writeFixed2("", c.freq_mhz_x10);
        writeOut(" MHz\n", .{});
        writeOut("    RSRP {d} / {d}  RSRQ {d} / {d}  RSSI {d} / {d}  CINR {d} / {d}\n", .{
            c.rsrp[0], c.rsrp[1], c.rsrq[0], c.rsrq[1],
            c.rssi[0], c.rssi[1], c.cinr[0],  c.cinr[1],
        });
    }
}

fn writeFixed2(prefix: []const u8, val_x10: i32) void {
    const abs = if (val_x10 < 0) @as(u32, @intCast(-val_x10)) else @as(u32, @intCast(val_x10));
    const sign: []const u8 = if (val_x10 < 0) "-" else "";
    writeOut("{s}{s}{d}.{d}", .{ prefix, sign, abs / 10, abs % 10 });
}

fn cmdSignalJson() void {
    const cfg = loadConfig();
    setupAt(&cfg);

    var status = signal.queryConnStatus() catch |e| {
        writeErr("Error: {s}\n", .{@errorName(e)});
        return;
    };
    var carriers = signal.queryCarriers() catch |e| {
        writeErr("Error: {s}\n", .{@errorName(e)});
        return;
    };

    var buf: [4096]u8 = undefined;
    const len = signal.writeSignalJson(&buf, &status, &carriers);
    if (len > 0) {
        std.fs.File.stdout().writeAll(buf[0..len]) catch {};
        std.fs.File.stdout().writeAll("\n") catch {};
    }
}

fn cmdBands() void {
    const cfg = loadConfig();
    setupAt(&cfg);

    const info = signal.queryBands() catch |e| {
        writeErr("Error: {s}\n", .{@errorName(e)});
        return;
    };
    if (info.count == 0) {
        writeOut("No bands reported\n", .{});
        return;
    }
    writeOut("Supported bands:", .{});
    for (info.bands[0..info.count]) |b| {
        writeOut(" {d}", .{b});
    }
    writeOut("\n", .{});
}

const CellPairList = struct { pairs: [16]signal.CellPair = undefined, count: usize = 0 };

fn parseCellPairs(args: *std.process.ArgIterator) CellPairList {
    var result = CellPairList{};
    while (result.count < 16) {
        const earfcn = args.next() orelse break;
        const pci = args.next() orelse {
            writeErr("Each EARFCN must be followed by a PCI\n", .{});
            return result;
        };
        result.pairs[result.count] = .{ .earfcn = earfcn, .pci = pci };
        result.count += 1;
    }
    return result;
}

fn cmdLockCell(args: *std.process.ArgIterator) void {
    const cfg = loadConfig();
    setupAt(&cfg);
    const parsed = parseCellPairs(args);
    if (parsed.count == 0) {
        writeErr("Usage: gctd lockcell <earfcn> <pci> [<earfcn2> <pci2> ...]\n", .{});
        return;
    }
    const ok = signal.lockCell(parsed.pairs[0..parsed.count]) catch |e| {
        writeErr("Error: {s}\n", .{@errorName(e)});
        return;
    };
    if (ok) writeOut("Locked {d} cell(s)\n", .{parsed.count}) else writeOut("Failed\n", .{});
}

fn cmdLockSCell(args: *std.process.ArgIterator) void {
    const cfg = loadConfig();
    setupAt(&cfg);
    const parsed = parseCellPairs(args);
    if (parsed.count == 0) {
        writeErr("Usage: gctd lockscell <earfcn> <pci> [<earfcn2> <pci2> ...]\n", .{});
        return;
    }
    const ok = signal.lockSCell(parsed.pairs[0..parsed.count]) catch |e| {
        writeErr("Error: {s}\n", .{@errorName(e)});
        return;
    };
    if (ok) writeOut("Locked {d} secondary cell(s)\n", .{parsed.count}) else writeOut("Failed\n", .{});
}

fn cmdFreqRange(args: *std.process.ArgIterator) void {
    const cfg = loadConfig();
    setupAt(&cfg);

    // Collect triplets: band start end [band start end ...]
    var ranges: [8]signal.FreqRange = undefined;
    var count: usize = 0;

    while (count < 8) {
        const band = args.next() orelse break;
        // "clear" = query + clear all
        if (std.mem.eql(u8, band, "clear")) {
            const ok = signal.clearFreqRange() catch |e| {
                writeErr("Error: {s}\n", .{@errorName(e)});
                return;
            };
            if (ok) writeOut("All frequency ranges cleared\n", .{}) else writeOut("Failed\n", .{});
            return;
        }
        const st = args.next() orelse {
            writeErr("Each band must be followed by start and end EARFCN\n", .{});
            return;
        };
        const ed = args.next() orelse {
            writeErr("Each band must be followed by start and end EARFCN\n", .{});
            return;
        };
        ranges[count] = .{ .band = band, .start_earfcn = st, .end_earfcn = ed };
        count += 1;
    }

    if (count == 0) {
        // No args = query current
        const resp = signal.queryFreqRange() catch |e| {
            writeErr("Error: {s}\n", .{@errorName(e)});
            return;
        };
        const data = resp.raw[0..resp.raw_len];
        // Parse %GFREGRNG: band1,st1,ed1,band2,st2,ed2,...
        const prefix = "%GFREGRNG: ";
        if (std.mem.indexOf(u8, data, prefix)) |pos| {
            const vals_start = pos + prefix.len;
            const line_end = std.mem.indexOfScalar(u8, data[vals_start..], '\r') orelse
                std.mem.indexOfScalar(u8, data[vals_start..], '\n') orelse
                (data.len - vals_start);
            const line = data[vals_start .. vals_start + line_end];
            if (line.len == 0) {
                writeOut("No frequency restrictions\n", .{});
            } else {
                var iter = std.mem.splitScalar(u8, line, ',');
                while (iter.next()) |band| {
                    const st_earfcn = iter.next() orelse break;
                    const ed_earfcn = iter.next() orelse break;
                    writeOut("Band {s}: EARFCN {s}-{s}\n", .{
                        std.mem.trim(u8, band, " "),
                        std.mem.trim(u8, st_earfcn, " "),
                        std.mem.trim(u8, ed_earfcn, " "),
                    });
                }
            }
        } else {
            writeOut("No frequency restrictions\n", .{});
        }
        return;
    }

    const ok = signal.setFreqRange(ranges[0..count]) catch |e| {
        writeErr("Error: {s}\n", .{@errorName(e)});
        return;
    };
    if (ok) writeOut("Frequency range set for {d} band(s)\n", .{count}) else writeOut("Failed\n", .{});
}

fn cmdUnlock() void {
    const cfg = loadConfig();
    setupAt(&cfg);
    const ok = signal.unlockAll() catch |e| {
        writeErr("Error: {s}\n", .{@errorName(e)});
        return;
    };
    if (ok) writeOut("All locks removed\n", .{}) else writeOut("Failed\n", .{});
}

// --- Daemon mode ---

var daemon_cfg: ?*config_mod.Config = null;
var daemon_running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true);

fn handleSignal(_: c_int) callconv(.c) void {
    daemon_running.store(false, .release);
}

fn daemonMode(args: *std.process.ArgIterator) void {
    var cfg = loadConfig();

    // First two positional args: interface device (from proto handler)
    if (args.next()) |iface| cfg.setIface(iface);
    if (args.next()) |dev| cfg.setDevice(dev);

    // Parse --key value options (from proto handler)
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--apn")) {
            if (args.next()) |v| cfg.setApn(v);
        } else if (std.mem.eql(u8, arg, "--pdptype")) {
            if (args.next()) |v| {
                if (std.mem.eql(u8, v, "ipv6")) cfg.pdptype = .ipv6
                else if (std.mem.eql(u8, v, "ipv4v6")) cfg.pdptype = .ipv4v6
                else cfg.pdptype = .ip;
            }
        } else if (std.mem.eql(u8, arg, "--pin")) {
            if (args.next()) |v| cfg.setPin(v);
        } else if (std.mem.eql(u8, arg, "--auth")) {
            if (args.next()) |v| {
                if (std.mem.eql(u8, v, "pap")) cfg.auth = .pap
                else if (std.mem.eql(u8, v, "chap")) cfg.auth = .chap
                else cfg.auth = .none;
            }
        } else if (std.mem.eql(u8, arg, "--username")) {
            if (args.next()) |v| cfg.setUsername(v);
        } else if (std.mem.eql(u8, arg, "--password")) {
            if (args.next()) |v| cfg.setPassword(v);
        } else if (std.mem.eql(u8, arg, "--cid")) {
            if (args.next()) |v| cfg.cid = std.fmt.parseInt(u8, v, 10) catch 3;
        } else if (std.mem.eql(u8, arg, "--no-roaming")) {
            cfg.allow_roaming = false;
        } else if (std.mem.eql(u8, arg, "--no-leds")) {
            cfg.leds_enabled = false;
        } else if (std.mem.eql(u8, arg, "--no-apn-dns")) {
            cfg.use_apn_dns = false;
        }
    }
    daemon_cfg = &cfg;
    setupAt(&cfg);
    keepalive.configure(cfg.modem_ip, cfg.keepalive_port, cfg.keepalive_interval_s);
    led.configure(cfg.leds_enabled);
    monitor.configure(cfg.monitor_interval_s, cfg.getIface());

    // Install signal handlers for graceful shutdown
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = .{ 0, 0, 0, 0 },
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);

    log.info("gctd starting (APN: {s}, CID: {d}, iface: {s})", .{ cfg.getApn(), cfg.cid, cfg.getIface() });

    // Start keepalive thread
    const ka_thread = std.Thread.spawn(.{}, keepalive.run, .{}) catch {
        log.err("Failed to start keepalive thread", .{});
        return;
    };
    _ = ka_thread;

    // Connect
    connect.connectLte(&cfg) catch |e| {
        log.err("Initial connection failed: {s}", .{@errorName(e)});
    };

    // Start monitor thread
    const mon_thread = std.Thread.spawn(.{}, monitor.run, .{}) catch {
        log.err("Failed to start monitor thread", .{});
        return;
    };
    _ = mon_thread;

    // Main loop: reconnect if connection drops
    while (daemon_running.load(.acquire)) {
        // Sleep in 1s increments so SIGTERM is handled quickly
        var sleep_count: u32 = 0;
        while (sleep_count < 30 and daemon_running.load(.acquire)) : (sleep_count += 1) {
            std.Thread.sleep(std.time.ns_per_s);
        }

        if (!daemon_running.load(.acquire)) break;

        // Check if still connected by querying CEREG
        if (commands.queryRegistration()) |status| {
            if (status != .home and status != .roaming) {
                log.warn("Lost registration ({s}), reconnecting...", .{@tagName(status)});
                connect.connectLte(&cfg) catch |e| {
                    log.err("Reconnection failed: {s}", .{@errorName(e)});
                };
            }
        } else |_| {}
    }

    // Graceful shutdown
    log.info("Shutting down...", .{});
    keepalive.stop();
    monitor.stop();
    connect.disconnectLte(&cfg);
    log.info("gctd stopped", .{});
}
