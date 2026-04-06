const std = @import("std");
const keepalive = @import("keepalive.zig");
const config_mod = @import("config.zig");
const commands = @import("commands.zig");
const log = std.log.scoped(.connect);

pub const ConnectError = error{
    ModemNotAlive,
    SimError,
    PinRequired,
    PukRequired,
    RegistrationFailed,
    ActivationFailed,
    NoIpAssigned,
    NetworkSetupFailed,
};

/// Run the LTE connection sequence
/// Fast path: if context is already active (e.g. after link recovery), skip to CGCONTRDP
/// Full path: SIM check → PDP config → CFUN → CGATT → CEREG → CGACT → CGCONTRDP
pub fn connectLte(cfg: *const config_mod.Config) ConnectError!void {
    log.info("Starting LTE connection (APN: {s}, CID: {d})", .{ cfg.getApn(), cfg.cid });

    // 1. Wait for modem alive (keepalive thread must be running)
    waitForModem() catch return ConnectError.ModemNotAlive;

    // 2. Fast path — check if context is already active (link recovery, modem didn't restart LTE)
    if (commands.queryContextActive(cfg.cid) catch false) {
        log.info("Context already active, fast reconnect", .{});
        return setupFromContext(cfg);
    }

    // 3. Full connection sequence
    checkSim(cfg) catch |e| return e;

    commands.configureContext(cfg.cid, cfg.pdptype, cfg.getApn()) catch {
        log.warn("AT+CGDCONT failed to send", .{});
    };
    if (cfg.auth != .none) {
        commands.configureAuth(cfg.cid, cfg.auth, cfg.getUsername(), cfg.getPassword()) catch {
            log.warn("AT+CGAUTH failed to send", .{});
        };
    }

    commands.setFullFunctionality() catch {
        log.warn("AT+CFUN=1 failed to send", .{});
    };
    std.Thread.sleep(std.time.ns_per_s);

    commands.attach() catch {
        log.warn("AT+CGATT=1 failed to send", .{});
    };
    std.Thread.sleep(std.time.ns_per_s);

    waitForRegistration(cfg) catch return ConnectError.RegistrationFailed;

    commands.activateContext(cfg.cid) catch return ConnectError.ActivationFailed;
    std.Thread.sleep(std.time.ns_per_s);

    return setupFromContext(cfg);
}

/// Get connection details from modem and configure network interface
fn setupFromContext(cfg: *const config_mod.Config) ConnectError!void {
    var info = commands.queryConnectionDetails(cfg.cid) catch return ConnectError.NoIpAssigned;

    switch (cfg.mode) {
        .netifd => setupNetworkNetifd(cfg, &info) catch return ConnectError.NetworkSetupFailed,
        .ip => setupNetworkIp(cfg, &info) catch return ConnectError.NetworkSetupFailed,
    }

    log.info("LTE connected: IP={s}/{d} GW={s} DNS={s},{s} MTU={d}", .{
        info.getIp(), info.prefix, info.getGateway(),
        info.getDns1(), info.getDns2(), info.mtu,
    });
}

/// Lightweight reconnect — only reactivate PDP context and reconfigure network
/// Used when modem is registered but context dropped (no full CFUN/CGATT/CEREG cycle)
pub fn reactivateContext(cfg: *const config_mod.Config) ConnectError!void {
    log.info("Reactivating PDP context (CID: {d})", .{cfg.cid});

    commands.activateContext(cfg.cid) catch return ConnectError.ActivationFailed;
    std.Thread.sleep(std.time.ns_per_s);

    var info = commands.queryConnectionDetails(cfg.cid) catch return ConnectError.NoIpAssigned;

    switch (cfg.mode) {
        .netifd => setupNetworkNetifd(cfg, &info) catch return ConnectError.NetworkSetupFailed,
        .ip => setupNetworkIp(cfg, &info) catch return ConnectError.NetworkSetupFailed,
    }

    log.info("PDP context reactivated: IP={s}/{d} GW={s}", .{
        info.getIp(), info.prefix, info.getGateway(),
    });
}

fn waitForModem() !void {
    log.info("Waiting for modem...", .{});
    var attempts: u32 = 0;
    while (attempts < 30) : (attempts += 1) {
        if (keepalive.modem_alive.load(.acquire)) {
            log.info("Modem is alive", .{});
            return;
        }
        std.Thread.sleep(std.time.ns_per_s);
    }
    log.err("Modem not responding after 30s", .{});
    return error.Timeout;
}

fn checkSim(cfg: *const config_mod.Config) ConnectError!void {
    // Retry SIM check — modem may still be initializing after restart
    var sim_attempts: u32 = 0;
    const status = while (sim_attempts < 5) : (sim_attempts += 1) {
        break commands.querySimStatus() catch {
            log.warn("SIM status query failed, retrying ({d}/5)...", .{sim_attempts + 1});
            std.Thread.sleep(2 * std.time.ns_per_s);
            continue;
        };
    } else {
        log.err("Failed to check SIM status after 5 attempts", .{});
        return ConnectError.SimError;
    };

    switch (status) {
        .ready => {
            log.info("SIM ready", .{});
            return;
        },
        .pin_required => {
            if (!cfg.hasPin()) {
                log.err("SIM PIN required but not configured", .{});
                return ConnectError.PinRequired;
            }

            // Check retry count
            if (commands.queryPinRetries()) |retries| {
                if (retries <= 1) {
                    log.err("Only {d} PIN retries left, refusing to try", .{retries});
                    return ConnectError.PinRequired;
                }
                log.info("PIN retries remaining: {d}", .{retries});
            } else |_| {}

            // Enter PIN
            commands.enterPin(cfg.getPin()) catch {
                log.err("PIN rejected", .{});
                return ConnectError.PinRequired;
            };
            log.info("PIN accepted", .{});
            std.Thread.sleep(2 * std.time.ns_per_s);
        },
        .puk_required => {
            log.err("SIM PUK required — manual intervention needed", .{});
            return ConnectError.PukRequired;
        },
        .unknown => {
            log.err("Unknown SIM status", .{});
            return ConnectError.SimError;
        },
    }
}

fn waitForRegistration(cfg: *const config_mod.Config) !void {
    log.info("Waiting for network registration...", .{});
    var attempts: u32 = 0;
    while (attempts < 30) : (attempts += 1) {
        const status = commands.queryRegistration() catch {
            std.Thread.sleep(2 * std.time.ns_per_s);
            continue;
        };

        switch (status) {
            .home => {
                log.info("Registered (home network)", .{});
                return;
            },
            .roaming => {
                if (cfg.allow_roaming) {
                    log.info("Registered (roaming)", .{});
                    return;
                } else {
                    log.warn("Roaming detected but not allowed", .{});
                }
            },
            .searching => log.info("Searching...", .{}),
            .denied => {
                log.err("Registration denied", .{});
                return error.Denied;
            },
            .not_registered, .unknown => {},
        }
        std.Thread.sleep(2 * std.time.ns_per_s);
    }
    log.err("Registration timeout", .{});
    return error.Timeout;
}

/// Configure network via ubus call to netifd
fn setupNetworkNetifd(cfg: *const config_mod.Config, info: *const commands.ConnectionDetails) !void {
    const iface = cfg.getIface();
    const device = cfg.getDevice();

    log.info("Configuring {s} ({s}) via netifd (IP={s} GW={s})", .{ iface, device, info.getIp(), info.getGateway() });

    // Build JSON for notify_proto
    var json_buf: [1024]u8 = undefined;
    var pfx_buf: [4]u8 = undefined;
    const pfx_str = std.fmt.bufPrint(&pfx_buf, "{d}", .{info.prefix}) catch if (info.is_ipv6) "64" else "24";
    var prefix_cidr_buf: [80]u8 = undefined;

    // Build DNS array
    var dns_buf: [256]u8 = undefined;
    const dns_str = blk: {
        if (!cfg.use_apn_dns) break :blk "";
        if (info.dns1_len > 0 and info.dns2_len > 0) {
            break :blk std.fmt.bufPrint(&dns_buf, ",\"dns\":[\"{s}\",\"{s}\"]", .{ info.getDns1(), info.getDns2() }) catch "";
        } else if (info.dns1_len > 0) {
            break :blk std.fmt.bufPrint(&dns_buf, ",\"dns\":[\"{s}\"]", .{info.getDns1()}) catch "";
        } else break :blk "";
    };

    const json = if (info.is_ipv6)
        std.fmt.bufPrint(&json_buf,
            \\{{"action":0,"interface":"{s}","ifname":"{s}","link-up":true,"keep":false,"ip6addr":[{{"ipaddr":"{s}","mask":"128"}}],"ip6prefix":["{s}"],"routes6":[{{"target":"::","netmask":"0","gateway":"{s}"}}]{s}}}
        , .{ iface, device, info.getIp(), prefixCidr(&prefix_cidr_buf, info), info.getGateway(), dns_str }) catch return error.Overflow
    else
        std.fmt.bufPrint(&json_buf,
            \\{{"action":0,"interface":"{s}","ifname":"{s}","link-up":true,"keep":false,"ipaddr":[{{"ipaddr":"{s}","mask":"{s}"}}],"routes":[{{"target":"0.0.0.0","netmask":"0","gateway":"{s}"}}]{s}}}
        , .{ iface, device, info.getIp(), pfx_str, info.getGateway(), dns_str }) catch return error.Overflow;

    exec(&.{ "ubus", "call", "network.interface", "notify_proto", json }) catch |e| {
        log.err("ubus call notify_proto failed: {s}", .{@errorName(e)});
        return error.ExecFailed;
    };

}

/// Configure network via raw ip commands
fn setupNetworkIp(cfg: *const config_mod.Config, info: *const commands.ConnectionDetails) !void {
    const iface = cfg.getIface();

    // Set MTU
    var mtu_buf: [8]u8 = undefined;
    const mtu_str = std.fmt.bufPrint(&mtu_buf, "{d}", .{info.mtu}) catch "1500";
    exec(&.{ "ip", "link", "set", iface, "mtu", mtu_str }) catch |e| {
        log.warn("Failed to set MTU: {s}", .{@errorName(e)});
    };

    // Add IP — prefix already computed in ConnectionDetails
    var ip_cidr_buf: [80]u8 = undefined;
    var prefix_buf: [4]u8 = undefined;
    const prefix_str = std.fmt.bufPrint(&prefix_buf, "{d}", .{info.prefix}) catch if (info.is_ipv6) "64" else "24";
    const ip_cidr = std.fmt.bufPrint(&ip_cidr_buf, "{s}/{s}", .{ info.getIp(), prefix_str }) catch return error.Overflow;

    log.info("Configuring {s} with {s}", .{ iface, ip_cidr });

    if (info.is_ipv6) {
        exec(&.{ "ip", "-6", "addr", "flush", "dev", iface }) catch {};
        exec(&.{ "ip", "-6", "addr", "add", ip_cidr, "dev", iface }) catch |e| {
            log.err("Failed to add IPv6 address: {s}", .{@errorName(e)});
            return error.ExecFailed;
        };
    } else {
        exec(&.{ "ip", "addr", "flush", "dev", iface }) catch {};
        exec(&.{ "ip", "addr", "add", ip_cidr, "dev", iface }) catch |e| {
            log.err("Failed to add address: {s}", .{@errorName(e)});
            return error.ExecFailed;
        };
    }

    // Default route
    if (info.is_ipv6) {
        exec(&.{ "ip", "-6", "route", "replace", "default", "via", info.getGateway(), "dev", iface }) catch |e| {
            log.err("Failed to add IPv6 default route: {s}", .{@errorName(e)});
            return error.ExecFailed;
        };
    } else {
        exec(&.{ "ip", "route", "replace", "default", "via", info.getGateway(), "dev", iface }) catch |e| {
            log.err("Failed to add default route: {s}", .{@errorName(e)});
            return error.ExecFailed;
        };
    }

    // DNS (best-effort)
    if (cfg.use_apn_dns) {
        writeDns(info) catch |e| {
            log.warn("Failed to write DNS config: {s}", .{@errorName(e)});
        };
    } else {
        log.info("Skipping APN DNS (use_apn_dns=0)", .{});
    }
}

/// Build prefix CIDR from IPv6 address (e.g. "2a00:f41:18d7:ba80::37:3f57:cc01" /64 → "2a00:f41:18d7:ba80::/64")
fn prefixCidr(buf: *[80]u8, info: *const commands.ConnectionDetails) []const u8 {
    const addr = std.net.Address.parseIp6(info.getIp(), 0) catch return "::/64";
    var bytes = addr.in6.sa.addr;

    // Zero out host bits
    const pb = info.prefix / 8;
    const pbits = info.prefix % 8;
    if (pb < 16) {
        if (pbits > 0) {
            bytes[pb] &= @as(u8, 0xFF) << @intCast(8 - pbits);
            for (pb + 1..16) |i| bytes[i] = 0;
        } else {
            for (pb..16) |i| bytes[i] = 0;
        }
    }

    var ip_buf: [64]u8 = undefined;
    const ip_len = commands.bytesToIpv6Hex(&bytes, &ip_buf);
    var fbs = std.io.fixedBufferStream(buf);
    fbs.writer().print("{s}/{d}", .{ ip_buf[0..ip_len], info.prefix }) catch return "::/64";
    return buf[0..fbs.pos];
}

fn writeDns(info: *const commands.ConnectionDetails) !void {
    const path = "/tmp/resolv.conf.d/resolv.conf.auto";
    const dir_path = "/tmp/resolv.conf.d";

    // Ensure directory exists
    std.fs.makeDirAbsolute(dir_path) catch {};

    const file = std.fs.createFileAbsolute(path, .{}) catch return;
    defer file.close();

    var buf: [256]u8 = undefined;
    if (info.dns1_len > 0) {
        const line = std.fmt.bufPrint(&buf, "nameserver {s}\n", .{info.getDns1()}) catch return;
        file.writeAll(line) catch |e| {
            log.warn("Failed to write DNS1: {s}", .{@errorName(e)});
        };
    }
    if (info.dns2_len > 0) {
        const line = std.fmt.bufPrint(&buf, "nameserver {s}\n", .{info.getDns2()}) catch return;
        file.writeAll(line) catch |e| {
            log.warn("Failed to write DNS2: {s}", .{@errorName(e)});
        };
    }
}

fn exec(argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stdin_behavior = .Close;
    child.stdout_behavior = .Close;
    child.stderr_behavior = .Close;
    try child.spawn();
    const result = try child.wait();
    if (result.Exited != 0) {
        log.warn("Command exited with {d}", .{result.Exited});
    }
}

/// Disconnect LTE
pub fn disconnectLte(cfg: *const config_mod.Config) void {
    const iface = cfg.getIface();

    switch (cfg.mode) {
        .netifd => {
            var json_buf: [128]u8 = undefined;
            const json = std.fmt.bufPrint(&json_buf,
                \\{{"action":0,"interface":"{s}","link-up":false,"keep":false}}
            , .{iface}) catch return;
            exec(&.{ "ubus", "call", "network.interface", "notify_proto", json }) catch {};
        },
        .ip => {
            exec(&.{ "ip", "addr", "flush", "dev", iface }) catch {};
            exec(&.{ "ip", "route", "flush", "dev", iface }) catch {};
        },
    }

    // Deactivate PDP context
    commands.deactivateContext(cfg.cid) catch |e| {
        log.warn("Failed to deactivate context: {s}", .{@errorName(e)});
    };

    log.info("LTE disconnected", .{});
}
