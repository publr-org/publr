//! `publr cloud login`: this computer signed in to the person's Publr Cloud account, as Publr
//! Studio signs in (`cloud/docs/projects.md`, "Apps signed in to an account"): OAuth with
//! PKCE in the browser, back through a one-off listener on 127.0.0.1. The token is kept
//! with the CLI's others, under the dashboard's address; `cloud deploy` takes it from there.
const std = @import("std");
const report = @import("../../lib/report.zig");
const credentials = @import("../credentials.zig");
const login = @import("../login.zig");

const client_id = "publr-cli";
const scope = "account";
/// Requests to the listener that are not the callback (a favicon) are answered and waited
/// past, this many at most.
const callback_tries_max: u32 = 8;
const request_bytes_max: u32 = 8 << 10;

const back_page =
    \\<!doctype html><meta charset=utf-8><title>Publr</title>
    \\<body style="margin:0;height:100vh;display:grid;place-items:center;
    \\font:15px -apple-system,system-ui,sans-serif;color:#222"><div style="text-align:center">
    \\<p style="font-size:18px;font-weight:600;margin:0 0 8px">{s}</p>
    \\<p style="margin:0;color:#777">{s}</p></div>
;

/// The account's token for `dashboard`: `PUBLR_CLOUD_TOKEN`, else the one `cloud login` kept.
pub fn token_for(init: std.process.Init, dashboard: []const u8, variable: []const u8) !?[]const u8 {
    std.debug.assert(dashboard.len > 0);
    std.debug.assert(variable.len > 0);

    if (init.environ_map.get(variable)) |token| {
        return token;
    }

    const kept = try credentials.find(init, dashboard) orelse return null;

    return if (std.mem.eql(u8, kept.scope, scope)) kept.token else null;
}

pub fn run(init: std.process.Init, out: *std.Io.Writer, dashboard: []const u8) !u8 {
    std.debug.assert(dashboard.len > 0);
    std.debug.assert(!std.mem.endsWith(u8, dashboard, "/"));

    const arena = init.arena.allocator();
    const token = signed_in(init, arena, out, dashboard) catch |err| {
        report.err("publr cloud login: {s}", .{switch (err) {
            error.Denied => "the sign-in was cancelled in the browser",
            error.Refused => "Publr Cloud did not take the sign-in; try again",
            else => @errorName(err),
        }});
        return 1;
    };
    const email = account_email(init, arena, dashboard, token) catch "";

    try credentials.put(init, .{
        .address = dashboard,
        .token = token,
        .email = email,
        .scope = scope,
    });
    const as = if (email.len > 0) " as " else "";

    try out.print("Signed in to {s}{s}{s}. `publr cloud deploy` puts a site there.\n", .{
        dashboard,
        as,
        email,
    });

    return 0;
}

/// The browser opened on Cloud's sign-in; the token for the code it comes back with.
fn signed_in(
    init: std.process.Init,
    arena: std.mem.Allocator,
    out: *std.Io.Writer,
    dashboard: []const u8,
) ![]const u8 {
    std.debug.assert(dashboard.len > 0);

    const encoder = std.base64.url_safe_no_pad.Encoder;
    var verifier_bytes: [32]u8 = undefined;
    var state_bytes: [16]u8 = undefined;

    init.io.random(&verifier_bytes);
    init.io.random(&state_bytes);

    var verifier_text: [64]u8 = undefined;
    var challenge_text: [64]u8 = undefined;
    var state_text: [32]u8 = undefined;
    var digest: [32]u8 = undefined;
    const verifier = encoder.encode(&verifier_text, &verifier_bytes);

    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});

    const challenge = encoder.encode(&challenge_text, &digest);
    const state = encoder.encode(&state_text, &state_bytes);
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(init.io, .{
        .reuse_address = true,
    });
    defer listener.deinit(init.io);

    const port = listener.socket.address.getPort();
    const back = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/callback", .{port});
    const component: std.Uri.Component = .{
        .raw = back,
    };
    const escaped_back = std.fmt.alt(component, .formatEscaped);
    const page = try std.fmt.allocPrint(arena, "{s}/oauth/authorize?response_type=code" ++
        "&client_id={s}&redirect_uri={f}&code_challenge={s}&code_challenge_method=S256" ++
        "&state={s}", .{ dashboard, client_id, escaped_back, challenge, state });

    try out.print("Approve this computer in the browser: {s}\n", .{page});
    try out.flush();
    login.open_browser(init, page);

    const code = try code_from(init.io, arena, &listener, state);
    const form = try std.fmt.allocPrint(arena, "grant_type=authorization_code&code={s}" ++
        "&code_verifier={s}&client_id={s}&redirect_uri={f}", .{
        code,
        verifier,
        client_id,
        escaped_back,
    });

    return exchanged(init.io, arena, dashboard, form);
}

/// The code the browser comes back with, once; the person's no or a wrong state refuses.
fn code_from(
    io: std.Io,
    arena: std.mem.Allocator,
    listener: *std.Io.net.Server,
    state: []const u8,
) ![]const u8 {
    std.debug.assert(state.len > 0);

    var tries: u32 = 0;

    while (tries < callback_tries_max) : (tries += 1) {
        const stream = try listener.accept(io);
        defer stream.close(io);

        var in_buffer: [request_bytes_max]u8 = undefined;
        var out_buffer: [2 << 10]u8 = undefined;
        var reader = stream.reader(io, &in_buffer);
        var writer = stream.writer(io, &out_buffer);
        const line = reader.interface.takeDelimiterExclusive('\n') catch continue;
        var words = std.mem.tokenizeScalar(u8, std.mem.trimEnd(u8, line, "\r"), ' ');

        _ = words.next();

        const target = words.next() orelse "/";

        if (!std.mem.startsWith(u8, target, "/callback?")) {
            try writer.interface.writeAll("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n" ++
                "Connection: close\r\n\r\n");
            try writer.interface.flush();
            continue;
        }

        const found = try callback_of(arena, target["/callback?".len..], state);
        const body = try std.fmt.allocPrint(arena, back_page, if (found != null)
            .{ "Signed in to Publr Cloud", "You can close this tab and go back to the terminal." }
        else
            .{ "Sign-in cancelled", "Nothing was signed in. You can close this tab." });

        try writer.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8" ++
            "\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
        try writer.interface.flush();

        return found orelse error.Denied;
    }

    return error.TimedOut;
}

/// The code in the callback's query, null unless its state is ours and it was not refused.
fn callback_of(arena: std.mem.Allocator, query: []const u8, state: []const u8) !?[]const u8 {
    std.debug.assert(state.len > 0);

    var code: ?[]const u8 = null;
    var came_state: []const u8 = "";
    var pairs = std.mem.tokenizeScalar(u8, query, '&');

    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..equals];
        const value = pair[equals + 1 ..];

        if (std.mem.eql(u8, key, "error")) {
            return null;
        }

        if (std.mem.eql(u8, key, "code")) {
            code = try arena.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "state")) {
            came_state = value;
        }
    }

    return if (std.mem.eql(u8, came_state, state)) code else null;
}

/// The code traded for the account's token at `/oauth/token`.
fn exchanged(
    io: std.Io,
    arena: std.mem.Allocator,
    dashboard: []const u8,
    form: []const u8,
) ![]const u8 {
    std.debug.assert(form.len > 0);

    var client: std.http.Client = .{
        .allocator = arena,
        .io = io,
    };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(arena);
    const result = try client.fetch(.{
        .location = .{
            .url = try std.fmt.allocPrint(arena, "{s}/oauth/token", .{dashboard}),
        },
        .method = .POST,
        .payload = form,
        .keep_alive = false,
        .headers = .{
            .content_type = .{
                .override = "application/x-www-form-urlencoded",
            },
        },
        .response_writer = &body.writer,
    });

    if (result.status != .ok) {
        return error.Refused;
    }

    const Token = struct {
        access_token: []const u8,
    };
    const token = try std.json.parseFromSliceLeaky(Token, arena, body.written(), .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    return token.access_token;
}

/// Who signed in, as `cloud.spaces` says.
fn account_email(
    init: std.process.Init,
    arena: std.mem.Allocator,
    dashboard: []const u8,
    token: []const u8,
) ![]const u8 {
    std.debug.assert(token.len > 0);

    const reply = try @import("../remote.zig").post(init.io, arena, .{
        .url = try std.fmt.allocPrint(arena, "{s}/api/cloud.spaces", .{dashboard}),
        .payload = "{}",
        .token = token,
    });

    if (reply.status != .ok) {
        return error.Refused;
    }

    const Listing = struct {
        account: struct {
            email: []const u8 = "",
        } = .{},
    };
    const listing = try std.json.parseFromSliceLeaky(Listing, arena, reply.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });

    return listing.account.email;
}

test "a callback counts only with our state and no refusal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("c1", (try callback_of(arena, "code=c1&state=s", "s")).?);
    try std.testing.expect(try callback_of(arena, "code=c1&state=other", "s") == null);
    try std.testing.expect(try callback_of(arena, "error=access_denied&state=s", "s") == null);
    try std.testing.expect(try callback_of(arena, "state=s", "s") == null);
}
