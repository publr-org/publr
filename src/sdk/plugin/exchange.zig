//! `publr.ExchangeCtx`: what a sign-in provider's `exchange` runs with, the one step of a
//! sign-in that waits on another server. It can send requests to the provider plugin's own
//! `http.fetch` domains, through the same guard as `ctx.fetch` (secrets filled as they
//! leave, every hop logged), within what is left of the step's time, and log; nothing else:
//! no calls, no records, no session. Core runs it (`run`) and decides whose account it is.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const words = @import("words.zig");
const http_operations = @import("../../operations/http.zig");
const plugin_access = @import("../plugin_access.zig");
const provider = @import("../provider.zig");

pub const Error = sdk.Error;

/// A provider plugin built without grants: every request refused.
const nothing_granted: plugin_access.Access = .{
    .own_types = &.{},
};

pub const ExchangeCtx = struct {
    inner: *sdk.Ctx,
    fetcher: http_operations.Fetcher,
    /// When the step's time runs out, on the awake clock.
    deadline: std.Io.Timestamp,

    /// A request to the provider, as its plugin: only to its `http.fetch` domains,
    /// `{secret:NAME}` filled in as it leaves. `Unavailable` once the step's time is spent.
    pub fn fetch(
        self: *ExchangeCtx,
        request: http_operations.Fetch.In,
    ) Error!http_operations.Fetch.Out {
        std.debug.assert(request.url.len > 0);
        std.debug.assert(self.fetcher.name.len > 0);

        const moment = std.Io.Clock.awake.now(self.inner.io);
        const left = moment.durationTo(self.deadline).toMilliseconds();

        if (left <= 0) {
            return error.Unavailable;
        }

        const limit_ms: u32 = @intCast(@min(left, provider.exchange_ms_max));

        return http_operations.fetch_as(self.inner, self.fetcher, request, limit_ms);
    }

    /// The step's time, one value for the whole step.
    pub fn now(self: *const ExchangeCtx) words.Time {
        std.debug.assert(self.inner.now_ms >= 0);

        return .{
            .ms = self.inner.now_ms,
        };
    }

    /// Memory freed when the request ends.
    pub fn arena(self: *const ExchangeCtx) std.mem.Allocator {
        return self.inner.arena;
    }

    /// Formatted text in memory freed when the request ends.
    pub fn print(
        self: *const ExchangeCtx,
        comptime format: []const u8,
        args: anytype,
    ) error{OutOfMemory}![]const u8 {
        comptime std.debug.assert(format.len > 0);

        return std.fmt.allocPrint(self.inner.arena, format, args);
    }

    /// A line on the provider plugin's log, under `sign_in:<provider>`.
    pub fn log(
        self: *ExchangeCtx,
        comptime level: words.Level,
        comptime format: []const u8,
        args: anytype,
    ) void {
        comptime std.debug.assert(format.len > 0);

        const line = std.fmt.allocPrint(self.inner.arena, format, args) catch format;

        add(self.inner, self.fetcher.name, @field(sdk.trail.Level, @tagName(level)), line);
    }
};

/// Runs `declared.exchange` for `callback` as the provider plugin (`access`, its built
/// grants), within `limit_ms`; answers its claims, checked to be this provider's. Every line
/// it logs, its requests included, goes to the plugin's log under `sign_in:<provider>`. Any
/// failure, or no answer in time, is `Unavailable` (or what the provider said), logged.
pub fn run(
    ctx: *sdk.Ctx,
    declared: *const provider.SignInProvider,
    access: ?*const plugin_access.Access,
    callback: provider.Callback,
    limit_ms: u32,
) Error!provider.Claims {
    std.debug.assert(limit_ms > 0 and limit_ms <= provider.exchange_ms_max);
    std.debug.assert(callback.code.len > 0);

    const plugin = if (declared.plugin.len > 0) declared.plugin else declared.name;
    var lines: sdk.trail.Lines = .{
        .root = 0,
        .arena = ctx.arena,
    };
    const lines_before = ctx.lines;
    const plugin_before = ctx.plugin;

    ctx.lines = &lines;
    ctx.plugin = plugin;
    defer {
        ctx.lines = lines_before;
        ctx.plugin = plugin_before;
    }

    const started = std.Io.Clock.awake.now(ctx.io);
    var exchange: ExchangeCtx = .{
        .inner = ctx,
        .fetcher = .{
            .name = plugin,
            .access = access orelse &nothing_granted,
        },
        .deadline = started.addDuration(.fromMilliseconds(limit_ms)),
    };
    const claims = answered(&exchange, declared, callback, limit_ms);

    if (claims) |_| {} else |err| {
        const said = if (ctx.failure) |failure| failure.message else @errorName(err);

        add(ctx, plugin, .warn, std.fmt.allocPrint(ctx.arena, "Sign-in failed: {s}", .{
            said,
        }) catch "Sign-in failed");
        std.log.warn("sign-in with {s} failed: {s}", .{ declared.name, said });
    }

    kept(ctx, declared.name, &lines);

    return claims;
}

fn answered(
    exchange: *ExchangeCtx,
    declared: *const provider.SignInProvider,
    callback: provider.Callback,
    limit_ms: u32,
) Error!provider.Claims {
    std.debug.assert(limit_ms > 0);

    const claims = try declared.exchange(exchange, callback);
    const finished = std.Io.Clock.awake.now(exchange.inner.io);

    // Its own work ran past the step's time: given up on all the same.
    if (exchange.deadline.durationTo(finished).toMilliseconds() > 0) {
        return exchange.inner.fail(gave_up(limit_ms));
    }

    if (!std.mem.eql(u8, claims.provider, declared.name) or claims.subject.len == 0) {
        return exchange.inner.fail(.{
            .name = "BadClaims",
            .status = 502,
            .message = "The provider answered for another provider, or no one",
        });
    }

    return claims;
}

fn gave_up(limit_ms: u32) sdk.operation.Failure {
    std.debug.assert(limit_ms > 0);

    return .{
        .name = "TimedOut",
        .status = 504,
        .message = "The provider did not answer in time",
    };
}

fn add(ctx: *sdk.Ctx, plugin: []const u8, level: sdk.trail.Level, text: []const u8) void {
    std.debug.assert(plugin.len > 0);

    if (ctx.lines) |lines| {
        lines.add(.{
            .plugin = plugin,
            .level = level,
            .text = text,
        });

        return;
    }

    std.log.info("plugin {s}: {s}", .{ plugin, text });
}

/// The step's lines on the plugin's log, as a queued run's are.
fn kept(ctx: *sdk.Ctx, name: []const u8, lines: *const sdk.trail.Lines) void {
    std.debug.assert(name.len > 0);

    if (lines.items.items.len == 0) {
        return;
    }

    const registry = @import("../../server/registry.zig");
    const log = registry.registry.log orelse return;
    const call = std.fmt.allocPrint(ctx.arena, "sign_in:{s}", .{name}) catch return;

    registry.SDK.raise_failed(ctx, log.lines(ctx, call, lines.kept()));
}

const testing_provider = struct {
    const secret_name = "EXCHANGE_TEST_SECRET";
    const secret_value = "cs-0123456789";

    /// Asks `http://localhost:<code>/token` with the client secret in a header; `other` as
    /// the code answers for another provider.
    const declared: provider.SignInProvider = .{
        .name = "fake",
        .label = "Fake",
        .icon = "M2 2h20v20H2z",
        .available = &always,
        .authorize_url = &authorize_url,
        .exchange = &exchange,
        .plugin = "auth_fake",
    };

    fn always() bool {
        return true;
    }

    fn authorize_url(_: std.mem.Allocator, _: provider.Authorize) Error![]const u8 {
        return "http://localhost/authorize";
    }

    fn exchange(ctx: *ExchangeCtx, callback: provider.Callback) Error!provider.Claims {
        std.debug.assert(callback.code.len > 0);

        if (std.mem.eql(u8, callback.code, "other")) {
            return .{
                .provider = "github",
                .subject = "1",
            };
        }

        const url = try ctx.print("http://localhost:{s}/token", .{callback.code});
        const answer = try ctx.fetch(.{
            .method = "POST",
            .url = url,
            .headers = &.{.{
                .name = "Authorization",
                .value = "Basic {secret:EXCHANGE_TEST_SECRET}",
            }},
            .body = "code=x",
        });

        if (answer.status != 200) {
            return error.BadCredentials;
        }

        ctx.log(.info, "Answered for {s}", .{answer.body});

        return .{
            .provider = "fake",
            .subject = answer.body,
            .email = "ada@example.com",
            .verified = true,
        };
    }

    /// Answers one request: the subject `42` when it carries the secret, else 401; or, when
    /// `silent`, reads it and never answers.
    fn serve(io: std.Io, server: *std.Io.net.Server, silent: bool) void {
        std.debug.assert(secret_value.len > 0);

        const stream = server.accept(io) catch return;
        defer stream.close(io);

        var read_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &read_buffer);
        var keyed = false;

        for (0..64) |_| {
            const line = reader.interface.takeDelimiterExclusive('\n') catch return;

            reader.interface.toss(1);
            keyed = keyed or std.mem.startsWith(u8, line, "Authorization: Basic " ++ secret_value);

            if (line.len <= 1) {
                break;
            }
        }

        if (silent) {
            std.Io.sleep(io, .fromMilliseconds(1500), .awake) catch return;
            return;
        }

        var write_buffer: [256]u8 = undefined;
        var writer = stream.writer(io, &write_buffer);
        const ok = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n42";
        const refused = "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n" ++
            "Connection: close\r\n\r\n";

        writer.interface.writeAll(if (keyed) ok else refused) catch return;
        writer.interface.flush() catch return;
    }
};

test "the exchange fetches only to its domains, fills its secret, gives up in time" {
    const Environment = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    const plugin_log = @import("../../operations/plugin/log.zig");
    const registry = @import("../../server/registry.zig");
    const Ask = @import("../../model/sandboxed_plugin.zig").Ask;
    // Failures are among what this checks: their warnings are expected.
    std.testing.log_level = .err;

    const name = testing_provider.secret_name;
    const set = Environment.setenv(name, testing_provider.secret_value, 1);

    try std.testing.expectEqual(@as(c_int, 0), set);
    defer _ = Environment.unsetenv(name);

    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    const ask: Ask = .{
        .key = "http.fetch",
        .domains = &.{"localhost"},
        .reason = "Asks the provider who signed in",
    };
    const access: plugin_access.Access = .{
        .held = &.{ask.held()},
        .own_types = &.{},
        .secrets = &.{.{
            .name = name,
            .label = "Fake client secret",
        }},
    };
    const io = std.testing.io;
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(io, .{});
    defer server.deinit(io);

    var port_buffer: [8]u8 = undefined;
    const port = try std.fmt.bufPrint(&port_buffer, "{d}", .{server.socket.address.getPort()});
    const callback: provider.Callback = .{
        .callback_url = "http://localhost/auth/fake/callback",
        .code = port,
        .code_verifier = "v" ** 48,
    };
    const declared = &testing_provider.declared;

    // Development, its domain listed: the request carries the secret, the claims come back.
    var ctx = harness.ctx(.system);
    ctx.outside.production = false;
    const answering = try std.Thread.spawn(.{}, testing_provider.serve, .{ io, &server, false });
    const claims = try run(&ctx, declared, &access, callback, 2_000);

    answering.join();
    try std.testing.expectEqualStrings("42", claims.subject);

    var reading = harness.ctx(.system);
    const log = try registry.SDK.dispatch(&reading, plugin_log.Log, .{
        .name = "auth_fake",
    });

    try std.testing.expectEqualStrings("sign_in:fake", log.lines[0].call);
    try std.testing.expect(std.mem.startsWith(u8, log.lines[1].line, "POST localhost/token 200"));

    for (log.lines) |line| {
        try std.testing.expect(std.mem.indexOf(u8, line.line, "cs-0123") == null);
    }

    // No answer in time: given up on (within the 300 ms left), said why.
    var slow = harness.ctx(.system);
    slow.outside.production = false;
    const silent = try std.Thread.spawn(.{}, testing_provider.serve, .{ io, &server, true });

    try std.testing.expectError(error.Failed, run(&slow, declared, &access, callback, 300));
    silent.join();

    // Production: this machine is refused before anything leaves.
    var production = harness.ctx(.system);
    try std.testing.expectError(error.Failed, run(&production, declared, &access, callback, 300));

    // Claims for another provider are refused.
    var other = harness.ctx(.system);
    var elsewhere = callback;
    elsewhere.code = "other";
    try std.testing.expectError(error.Failed, run(&other, declared, &access, elsewhere, 300));

    var after = harness.ctx(.system);
    const failures = try registry.SDK.dispatch(&after, plugin_log.Log, .{
        .name = "auth_fake",
    });
    var gave_up_said = false;

    for (failures.lines) |line| {
        gave_up_said = gave_up_said or std.mem.indexOf(u8, line.line, "gave up after") != null;
    }

    try std.testing.expect(gave_up_said);
}
