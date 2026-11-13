//! Signing this computer in to a site for `publr mcp`, as `publr login` does, without a
//! terminal to talk in: the browser opens on the site's approve page, and a call waits for
//! the person a while before answering that it still waits. The token is kept with the
//! CLI's (`~/.publr/credentials`), one per site for every tool on this computer.
const std = @import("std");
const credentials = @import("../credentials.zig");
const login = @import("../login.zig");

/// How long one call waits for the person before answering; tools give up on a call that
/// takes minutes.
const wait_s_max: u32 = 40;
const name_len_max: u32 = 80;

/// A request a person has yet to approve, kept between calls. Its text lives in the
/// process's own arena: one per site the person is asked about.
pub const Pending = struct {
    address: []const u8,
    started: login.Started,
    link: []const u8,
};

pub const Outcome = union(enum) {
    token: []const u8,
    /// The approve page's address: the person has not decided yet.
    waiting: []const u8,
    /// Refused or expired: asking again starts over.
    refused: []const u8,
};

pub const SignIn = struct {
    /// Where pending requests live: the process's arena, not a call's.
    keep: std.mem.Allocator,
    pending: ?Pending = null,
    /// "Cursor on <computer>": what the person sees on Settings › Devices.
    name: []const u8 = "",

    /// The token for `address`, asking its person in the browser when there is none.
    pub fn token(sign_in: *SignIn, init: std.process.Init, address: []const u8) !Outcome {
        std.debug.assert(address.len > 0);

        if (try credentials.find(init, address)) |site| {
            return .{
                .token = site.token,
            };
        }

        const fresh = sign_in.pending == null or
            !std.mem.eql(u8, sign_in.pending.?.address, address);

        if (fresh) {
            sign_in.pending = try sign_in.start(init, address);
        }

        const pending = sign_in.pending.?;
        const state = try wait(init, pending);

        if (std.mem.eql(u8, state, "pending")) {
            return .{
                .waiting = pending.link,
            };
        }

        sign_in.pending = null;

        if (!std.mem.eql(u8, state, "approved")) {
            return .{
                .refused = state,
            };
        }

        return .{
            .token = try claim(init, pending, sign_in.name),
        };
    }

    fn start(sign_in: *SignIn, init: std.process.Init, address: []const u8) !Pending {
        std.debug.assert(sign_in.name.len > 0);

        const arena = init.arena.allocator();
        const body = try std.json.Stringify.valueAlloc(arena, .{
            .name = sign_in.name,
            .scope = "publish",
        }, .{});
        const path = "/api/device.start";
        const started = try login.call(init, login.Started, address, path, body, null);
        const link = try std.fmt.allocPrint(arena, "{s}{s}", .{ address, started.approve_path });

        login.open_browser(init, link);

        return .{
            .address = try sign_in.keep.dupe(u8, address),
            .started = .{
                .device_code = try sign_in.keep.dupe(u8, started.device_code),
                .user_code = "",
                .approve_path = "",
                .expires_at = started.expires_at,
                .interval_s = @max(started.interval_s, 1),
            },
            .link = try sign_in.keep.dupe(u8, link),
        };
    }
};

/// The request's state once the person decided, or "pending" after `wait_s_max`.
fn wait(init: std.process.Init, pending: Pending) ![]const u8 {
    std.debug.assert(pending.started.interval_s > 0);

    const body = try std.json.Stringify.valueAlloc(init.arena.allocator(), .{
        .device_code = pending.started.device_code,
    }, .{});
    const attempts_max = wait_s_max / pending.started.interval_s + 1;
    var attempt: u32 = 0;

    while (attempt < attempts_max) : (attempt += 1) {
        const path = "/api/device.poll";
        const polled = login.call(init, login.Polled, pending.address, path, body, null) catch {
            try std.Io.sleep(init.io, .fromSeconds(pending.started.interval_s), .awake);
            continue;
        };

        if (!std.mem.eql(u8, polled.state, "pending")) {
            return polled.state;
        }

        try std.Io.sleep(init.io, .fromSeconds(pending.started.interval_s), .awake);
    }

    return "pending";
}

fn claim(init: std.process.Init, pending: Pending, name: []const u8) ![]const u8 {
    std.debug.assert(name.len > 0);

    const body = try std.json.Stringify.valueAlloc(init.arena.allocator(), .{
        .device_code = pending.started.device_code,
        .name = name,
    }, .{});
    const path = "/api/device.claim";
    const claimed = try login.call(init, login.Claimed, pending.address, path, body, null);
    const site: credentials.Site = .{
        .address = pending.address,
        .token = claimed.token,
        .scope = claimed.scope,
    };
    const who = try login.current(init, site);

    try credentials.put(init, .{
        .address = site.address,
        .token = site.token,
        .email = who.email,
        .scope = site.scope,
    });

    return claimed.token;
}

/// "<tool> on <computer>", the tool as it names itself when it connects.
pub fn device_name(arena: std.mem.Allocator, client: []const u8) ![]const u8 {
    std.debug.assert(name_len_max > 0);

    var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host = std.posix.gethostname(&buffer) catch "this computer";
    const tool = tool_name(client);
    const computer = host[0..@min(host.len, 48)];
    const name = try std.fmt.allocPrint(arena, "{s} on {s}", .{ tool, computer });

    return name[0..@min(name.len, name_len_max)];
}

/// What people call the tool, from the name it gives itself (`cursor-vscode`, `claude-code`).
fn tool_name(client: []const u8) []const u8 {
    std.debug.assert(client.len <= 64 << 10);

    const known = [_]struct {
        []const u8,
        []const u8,
    }{
        .{ "cursor", "Cursor" },
        .{ "claude-code", "Claude Code" },
        .{ "codex", "Codex" },
        .{ "windsurf", "Windsurf" },
    };

    for (known) |pair| {
        if (std.ascii.indexOfIgnoreCase(client, pair[0]) != null) {
            return pair[1];
        }
    }

    return if (client.len > 0 and client.len <= 40) client else "An agent";
}

test "a device is named after the tool that asked for it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("Cursor", tool_name("cursor-vscode"));
    try std.testing.expectEqualStrings("Claude Code", tool_name("claude-code"));
    try std.testing.expectEqualStrings("Codex", tool_name("codex-mcp-client"));
    try std.testing.expectEqualStrings("zed", tool_name("zed"));
    try std.testing.expectEqualStrings("An agent", tool_name(""));
    try std.testing.expect(std.mem.startsWith(u8, try device_name(arena, "cursor"), "Cursor on "));
}
