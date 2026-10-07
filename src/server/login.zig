//! `publr login <address>`: this machine asks the Publr there to act for someone (`device
//! start`), shows them the link to approve it in that Publr's admin, waits for the token
//! (`device poll`) and keeps it (`credentials.zig`). `logout` revokes it there and forgets it;
//! `whoami` says whose it is and what it may do.
const std = @import("std");
const builtin = @import("builtin");
const credentials = @import("credentials.zig");
const remote = @import("remote.zig");
const device = @import("../model/device.zig");

const Started = struct {
    device_code: []const u8,
    user_code: []const u8,
    approve_path: []const u8,
    expires_at: i64,
    interval_s: u32,
};
const Polled = struct { state: []const u8 };
const Claimed = struct { token: []const u8, scope: []const u8 };
const Item = struct {
    id: []const u8,
    name: []const u8,
    scope: []const u8,
    email: []const u8,
    current: bool,
};
const Listed = struct { devices: []const Item };

const Options = struct {
    address: ?[]const u8 = null,
    name: ?[]const u8 = null,
    scope: []const u8 = "drafts",
    browser: bool = true,
};

pub fn run(init: std.process.Init, out: *std.Io.Writer, args: []const []const u8) !u8 {
    std.debug.assert(args.len > 0);

    const command = args[0];
    const options = parse(args[1..]) orelse {
        std.debug.print(
            "usage: publr login <address> [--name <name>] [--scope read|drafts|write] " ++
                "[--no-browser]\n       publr logout [<address>]\n" ++
                "       publr whoami [<address>]\n",
            .{},
        );
        return 2;
    };

    if (std.mem.eql(u8, command, "logout")) {
        return logout(init, out, options.address);
    }

    if (std.mem.eql(u8, command, "whoami")) {
        return whoami(init, out, options.address);
    }

    std.debug.assert(std.mem.eql(u8, command, "login"));

    return login(init, out, options);
}

fn parse(args: []const []const u8) ?Options {
    std.debug.assert(args.len <= 128);

    var options: Options = .{};
    var index: u32 = 0;

    while (index < args.len) : (index += 1) {
        const arg = args[index];
        const valued = std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "--scope");

        if (valued and index + 1 == args.len) {
            return null;
        }

        if (std.mem.eql(u8, arg, "--name")) {
            index += 1;
            options.name = args[index];
        } else if (std.mem.eql(u8, arg, "--scope")) {
            index += 1;
            options.scope = args[index];
        } else if (std.mem.eql(u8, arg, "--no-browser")) {
            options.browser = false;
        } else if (std.mem.startsWith(u8, arg, "-") or options.address != null) {
            return null;
        } else {
            options.address = arg;
        }
    }

    return options;
}

fn login(init: std.process.Init, out: *std.Io.Writer, options: Options) !u8 {
    const arena = init.arena.allocator();

    std.debug.assert(options.scope.len > 0);

    const typed = options.address orelse return usage("login needs an address");
    const named = try credentials.normalize(arena, typed) orelse {
        return usage("that is not an address");
    };
    const address = remote.settle(init.io, arena, named) catch |err| switch (err) {
        error.NotHttps => return 1,
        else => return err,
    };

    if (device.Scope.parse(options.scope) == null) {
        return usage("--scope is read, drafts or write");
    }

    const name = options.name orelse try default_name(arena);
    const start_body = try std.json.Stringify.valueAlloc(arena, .{
        .name = name,
        .scope = options.scope,
    }, .{});
    const started = try call(init, Started, address, "/api/device/start", start_body, null);
    const link = try std.fmt.allocPrint(arena, "{s}{s}", .{ address, started.approve_path });

    try out.print("Open {s} to sign in.\n", .{link});
    try out.flush();

    if (options.browser) {
        open_browser(init, link);
    }

    if (!try wait(init, address, started)) {
        return 1;
    }

    const code_body = try std.json.Stringify.valueAlloc(arena, .{
        .device_code = started.device_code,
    }, .{});
    const claimed = try call(init, Claimed, address, "/api/device/claim", code_body, null);
    const scope = claimed.scope;
    const site: credentials.Site = .{ .address = address, .token = claimed.token, .scope = scope };
    const who = try current(init, site);

    try credentials.put(init, .{
        .address = address,
        .token = site.token,
        .email = who.email,
        .scope = scope,
    });
    try out.print("✓ {s} · {s} · {s}\n", .{ who.email, address, scope });

    return 0;
}

/// Asks until the person decides or the request lapses: true once approved, else false after
/// saying why not.
fn wait(init: std.process.Init, address: []const u8, started: Started) !bool {
    std.debug.assert(started.interval_s > 0);

    const arena = init.arena.allocator();
    const lifetime_s: u32 = @intCast(@divTrunc(device.request_lifetime_ms, std.time.ms_per_s));
    const attempts_max = lifetime_s / started.interval_s + 2;
    const body = try std.json.Stringify.valueAlloc(arena, .{
        .device_code = started.device_code,
    }, .{});
    var attempt: u32 = 0;

    while (attempt < attempts_max) : (attempt += 1) {
        try std.Io.sleep(init.io, .fromSeconds(started.interval_s), .awake);

        // A server restarting or a network blip while the person decides is no reason to
        // give up: the request waits for them there either way.
        const polled = call(init, Polled, address, "/api/device/poll", body, null) catch {
            continue;
        };

        if (std.mem.eql(u8, polled.state, "approved")) {
            return true;
        }

        if (!std.mem.eql(u8, polled.state, "pending")) {
            std.debug.print("publr: the request was {s}\n", .{polled.state});
            return false;
        }
    }

    std.debug.print("publr: the request expired\n", .{});

    return false;
}

fn logout(init: std.process.Init, out: *std.Io.Writer, address: ?[]const u8) !u8 {
    const site = try credentials.find(init, address) orelse {
        return usage("not signed in there; name the address");
    };

    std.debug.assert(site.token.len > 0);

    const arena = init.arena.allocator();
    const id = site.token[0..@min(site.token.len, 24)];
    const body = try std.json.Stringify.valueAlloc(arena, .{ .id = id }, .{});
    const url = try std.fmt.allocPrint(arena, "{s}/api/device/revoke", .{site.address});

    // Forgotten here whatever the answer: a device already revoked there is gone either way.
    const revoke: remote.Post = .{ .url = url, .payload = body, .token = site.token };

    if (remote.post(init.io, arena, revoke)) |reply| {
        if (reply.status != .ok) {
            const status = @intFromEnum(reply.status);

            std.debug.print("publr: {s} answered {d}\n", .{ site.address, status });
        }
    } else |err| {
        std.debug.print("publr: {s}: {t}\n", .{ site.address, err });
    }

    _ = try credentials.remove(init, site.address);
    try out.print("Signed out of {s}\n", .{site.address});

    return 0;
}

fn whoami(init: std.process.Init, out: *std.Io.Writer, address: ?[]const u8) !u8 {
    const site = try credentials.find(init, address) orelse {
        return usage("not signed in there; name the address");
    };

    std.debug.assert(site.address.len > 0);

    const who = current(init, site) catch |err| {
        std.debug.print("publr: {s}: {t}\n", .{ site.address, err });
        return 1;
    };

    try out.print("{s} · {s} · {s} · {s}\n", .{ who.email, site.address, who.scope, who.name });

    return 0;
}

/// The device a token is, as the Publr it belongs to lists it.
fn current(init: std.process.Init, site: credentials.Site) !Item {
    std.debug.assert(site.token.len > 0);

    const listed = try call(init, Listed, site.address, "/api/device/list", "{}", site.token);

    for (listed.devices) |item| {
        if (item.current) {
            return item;
        }
    }

    return error.DeviceNotFound;
}

fn call(
    init: std.process.Init,
    comptime Out: type,
    address: []const u8,
    path: []const u8,
    body: []const u8,
    token: ?[]const u8,
) !Out {
    std.debug.assert(path.len > 0);

    const arena = init.arena.allocator();
    const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ address, path });
    const reply = try remote.post(init.io, arena, .{ .url = url, .payload = body, .token = token });

    if (reply.status != .ok) {
        std.debug.print("publr: {s} answered {d}: {s}\n", .{
            address,
            @intFromEnum(reply.status),
            reply.body,
        });
        return error.Refused;
    }

    return std.json.parseFromSliceLeaky(Out, arena, reply.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

/// "The publr CLI on <this machine's name>".
fn default_name(arena: std.mem.Allocator) ![]const u8 {
    var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host = std.posix.gethostname(&buffer) catch "this machine";

    std.debug.assert(host.len > 0);

    return std.fmt.allocPrint(arena, "The publr CLI on {s}", .{host[0..@min(host.len, 48)]});
}

/// The link opened where a person can see it; nothing when there is no browser to open.
fn open_browser(init: std.process.Init, link: []const u8) void {
    std.debug.assert(link.len > 0);

    const opener = switch (builtin.os.tag) {
        .macos => "open",
        .linux => if (init.environ_map.get("DISPLAY") != null or
            init.environ_map.get("WAYLAND_DISPLAY") != null) "xdg-open" else return,
        else => return,
    };
    var child = std.process.spawn(init.io, .{
        .argv = &.{ opener, link },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;

    _ = child.wait(init.io) catch return;
}

fn usage(message: []const u8) u8 {
    std.debug.assert(message.len > 0);

    std.debug.print("publr: {s}\n", .{message});

    return 2;
}
