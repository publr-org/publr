const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const secret = @import("secret.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const secrets = model.secrets;

pub const namespace: sdk.operation.Namespace = .{
    .name = "http",
    .label = "Outside requests",
    .area = .system,
    .summary = "Requests a plugin sends out, its secrets filled in as they leave",
    .details =
    \\From queued work alone (a job, an `on` hook), never a request someone waits on, a
    \\plugin granted `http.fetch` sends a request to a domain on its grant (exact,
    \\`*.example.com`, or `*` for any public address): https, or in development plain
    \\http to this machine when listed. In production local and private addresses and the
    \\server itself are refused, whatever is listed; redirects stay within the domains, and
    \\each request is logged (host, path, status). Where it writes
    \\`{secret:NAME}` (in the address, a header or the body) the secret's value is filled
    \\in as the request leaves, when the plugin declares it in `.secrets`; the plugin never
    \\holds it, and a value the answer echoes back is put back as `{secret:NAME}`. Plugins
    \\only.
    ,
};

pub const operations = [_]type{ Fetch, stream.Stream, stream.Read };

pub const stream = @import("http_stream.zig");
/// A request given up on after its time limit: for host code calling its own servers.
pub const timed = @import("http_timed.zig");
const form_parts = @import("http_form.zig");
const guards = @import("http_guard.zig");
const downloads = @import("http_download.zig");
const request_log = @import("http_log.zig");
const plugin_access = @import("../sdk/plugin_access.zig");
const registry = @import("../server/registry.zig");

pub const headers_max: u32 = 16;
pub const FormPart = form_parts.Part;
/// What a plugin may send: a conversation with its pictures fits.
pub const body_bytes_max: u32 = 8 << 20;
/// What an answer may be.
pub const answer_bytes_max: u32 = 1 << 20;
const secrets_max: u32 = 8;

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Fetch = struct {
    pub const name = "http.fetch";
    /// A plugin's alone: not listed among the commands people and agents run.
    pub const plugins_only = true;
    pub const description = "Send a request out, as the calling plugin";
    pub const details =
        \\Answers the status and the body (up to 1 MiB). Refused outside queued work (a job, an
        \\`on` hook), and unless the caller is a plugin granted `http.fetch`, every hop's
        \\host is among the grant's domains (and, in production, resolves to no local or
        \\private address), and every `{secret:NAME}` it names is declared in the plugin's
        \\`.secrets` and has a value (else "<label> isn't set"). Logged under the call or
        \\run: method, host, path, status, time; never the query, headers or bodies.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        method: []const u8 = "GET",
        url: []const u8,
        headers: []const Header = &.{},
        body: []const u8 = "",
        /// A form upload (multipart/form-data) in place of `body`, files as base64; the
        /// `Content-Type` is set for it. No secret is filled in a form.
        form: []const form_parts.Part = &.{},
    };
    pub const Out = struct {
        status: u16,
        body: []const u8,
    };
    pub const example: In = .{
        .url = "https://api.example.com/quote",
        .headers = &.{.{
            .name = "Authorization",
            .value = "Bearer {secret:STOCKS_API_KEY}",
        }},
    };
    pub const example_out: Out = .{
        .status = 200,
        .body = "{\"price\":12.5}",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .method = "GET, POST, PUT, PATCH or DELETE",
        .url = "https, or http to this machine in development; may hold {secret:NAME}",
        .headers = "Up to 16, as name and value; values may hold {secret:NAME}",
        .body = "Up to 8 MiB; may hold {secret:NAME}",
        .form = "Up to 16 parts in place of the body: name, value, and for a file " ++
            "file_name and content_type, its value base64",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(headers_max > 0);

        const fetcher = fetcher_of(ctx) orelse return error.Denied;

        // Nothing a request waits on reaches another server.
        if (ctx.job.len == 0) {
            return ctx.fail(not_queued);
        }

        return fetch_as(ctx, fetcher, in, timed.timeout_ms);
    }
};

/// `in` sent for `fetcher` under its guard and secrets, given up on after `limit_ms`: what
/// `http.fetch` runs, and a sign-in provider's exchange with its own shorter limit.
pub fn fetch_as(ctx: *Ctx, fetcher: Fetcher, in: Fetch.In, limit_ms: u32) Error!Fetch.Out {
    std.debug.assert(fetcher.name.len > 0);
    std.debug.assert(limit_ms > 0 and limit_ms <= timed.timeout_ms);

    const Method = std.http.Method;
    const method = std.meta.stringToEnum(Method, in.method) orelse return error.Invalid;
    const uri = std.Uri.parse(in.url) catch return error.Invalid;

    if (in.headers.len > headers_max or in.body.len > body_bytes_max) {
        return error.Invalid;
    }

    const guard = guard_of(ctx, fetcher);

    if (guards.refusal_of_name(guard, uri)) |refusal| {
        request_log.refused(ctx, fetcher.name, in.method, uri, refusal);

        return ctx.fail(not_allowed);
    }

    var filling = Filling.of(ctx, fetcher.access, in) catch |err| {
        if (err == error.Failed) {
            const reason = if (ctx.failure) |failure| failure.message else "a secret";

            request_log.refused_because(ctx, fetcher.name, in.method, uri, reason);
        }

        return err;
    };

    if (in.form.len > 0) {
        try with_form(ctx, &filling, in);
    }

    return send(ctx, method, &filling, fetcher, guard, limit_ms);
}

/// The plugin a call goes out for: an installed one by its grants, a compiled-in one (its
/// code calling, whoever it runs for) by the grants it was built with. Null for core's own
/// code, which calls out by other ways.
pub const Fetcher = struct {
    name: []const u8,
    access: *const plugin_access.Access,
};

pub fn fetcher_of(ctx: *Ctx) ?Fetcher {
    std.debug.assert(ctx.now_ms >= 0);

    const name = switch (ctx.caller) {
        .plugin => |plugin| plugin.name,
        else => if (ctx.plugin_called) ctx.plugin else "",
    };

    if (name.len == 0) {
        return null;
    }

    const installed = switch (ctx.caller) {
        .plugin => |plugin| plugin.access,
        else => null,
    };
    const access = installed orelse registry.SDK.compiled_access(name) orelse return null;

    return .{
        .name = name,
        .access = access,
    };
}

/// Where `fetcher` may send: the domains on its `http.fetch` grant (none when it is off),
/// under the server's address rules.
pub fn guard_of(ctx: *const Ctx, fetcher: Fetcher) guards.Guard {
    std.debug.assert(fetcher.name.len > 0);

    const held = fetcher.access.held_of("http.fetch");

    return .{
        .domains = if (held) |grant| grant.domains else &.{},
        .rule = ctx.outside,
    };
}

pub const not_allowed: sdk.operation.Failure = .{
    .name = "NotAllowed",
    .status = 403,
    .message = "Not a domain on the plugin's http.fetch grant, or an address refused here",
};

pub const not_queued: sdk.operation.Failure = .{
    .name = "NotQueued",
    .status = 409,
    .message = "Outside calls run in queued work only: a job or an `on` hook",
};

pub const unreachable_failure: sdk.operation.Failure = .{
    .name = "Unreachable",
    .status = 502,
    .message = "The request did not go through",
};

/// The request with its secrets found, their values looked up, and filled in.
pub const Filling = struct {
    names: []const []const u8,
    values: []const []const u8,
    url: []const u8,
    headers: []const std.http.Header,
    body: []const u8,

    pub fn of(ctx: *Ctx, access: *const plugin_access.Access, in: Fetch.In) Error!Filling {
        std.debug.assert(in.url.len > 0);
        std.debug.assert(in.headers.len <= headers_max);

        var storage: [secrets_max][]const u8 = undefined;
        // Kept past this call: the answer is scrubbed of the values by these names.
        const names = ctx.arena.dupe([]const u8, try asked(ctx, in, &storage)) catch {
            return error.OutOfMemory;
        };
        const values = try ctx.arena.alloc([]const u8, names.len);

        for (names, values) |secret_name, *value| {
            const declared = secrets.declared_find(access.secrets, secret_name) orelse {
                return ctx.fail(.{
                    .name = "SecretNotDeclared",
                    .status = 403,
                    .message = "The plugin names a secret it does not declare in .secrets",
                });
            };

            value.* = try secret.value_of(ctx, secret_name) orelse {
                return ctx.fail(.{
                    .name = "SecretMissing",
                    .status = 409,
                    .message = try std.fmt.allocPrint(ctx.arena, "{s} isn't set", .{
                        declared.label,
                    }),
                });
            };
        }

        const headers = try ctx.arena.alloc(std.http.Header, in.headers.len);

        for (in.headers, headers) |header, *filled| {
            const value = try fill(ctx, header.value, names, values);

            filled.* = .{
                .name = header.name,
                .value = value,
            };
        }

        return .{
            .names = names,
            .values = values,
            .url = try fill(ctx, in.url, names, values),
            .headers = headers,
            .body = try fill(ctx, in.body, names, values),
        };
    }

    /// `text` with every value put back as `{secret:NAME}`: an answer never carries one.
    pub fn scrub(filling: *const Filling, ctx: *Ctx, text: []const u8) Error![]const u8 {
        std.debug.assert(filling.names.len == filling.values.len);

        var scrubbed = text;

        for (filling.names, filling.values) |secret_name, value| {
            const marker = try std.fmt.allocPrint(ctx.arena, "{{secret:{s}}}", .{secret_name});

            scrubbed = std.mem.replaceOwned(u8, ctx.arena, scrubbed, value, marker) catch {
                return error.OutOfMemory;
            };
        }

        return scrubbed;
    }
};

/// The request's body as the form `in` holds, and its `Content-Type`.
fn with_form(ctx: *Ctx, filling: *Filling, in: Fetch.In) Error!void {
    std.debug.assert(in.form.len > 0);

    const too_many = in.form.len > form_parts.parts_max or filling.headers.len >= headers_max;

    if (in.body.len > 0 or too_many) {
        return error.Invalid;
    }

    var form_bytes: u64 = 0;

    for (in.form) |part| {
        form_bytes += part.value.len;
    }

    if (form_bytes > body_bytes_max) {
        return error.Invalid;
    }

    var seed: [16]u8 = undefined;

    ctx.io.random(&seed);

    const written = form_parts.write(ctx.arena, in.form, seed) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid => error.Invalid,
    };
    const headers = try ctx.arena.alloc(std.http.Header, filling.headers.len + 1);

    @memcpy(headers[0..filling.headers.len], filling.headers);
    headers[filling.headers.len] = .{
        .name = "Content-Type",
        .value = written.content_type,
    };
    filling.headers = headers;
    filling.body = written.body;
    std.debug.assert(filling.body.len > 0);
}

fn asked(ctx: *Ctx, in: Fetch.In, storage: *[secrets_max][]const u8) Error![]const []const u8 {
    std.debug.assert(secrets_max > 0);

    var all: std.ArrayList(u8) = .empty;

    all.appendSlice(ctx.arena, in.url) catch return error.OutOfMemory;
    all.appendSlice(ctx.arena, in.body) catch return error.OutOfMemory;

    for (in.headers) |header| {
        all.appendSlice(ctx.arena, header.value) catch return error.OutOfMemory;
    }

    return secrets.names_in(all.items, storage) catch error.Invalid;
}

fn fill(
    ctx: *Ctx,
    text: []const u8,
    names: []const []const u8,
    values: []const []const u8,
) Error![]const u8 {
    std.debug.assert(names.len == values.len);

    if (names.len == 0) {
        return text;
    }

    return secrets.fill(ctx.arena, text, names, values) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Invalid,
    };
}

fn send(
    ctx: *Ctx,
    method: std.http.Method,
    filling: *const Filling,
    fetcher: Fetcher,
    guard: guards.Guard,
    limit_ms: u32,
) Error!Fetch.Out {
    std.debug.assert(filling.url.len > 0);
    std.debug.assert(answer_bytes_max > 0);

    if (builtin.os.tag == .wasi) {
        return error.Unavailable;
    }

    var trace: timed.Trace = .{
        .arena = ctx.arena,
    };
    const started = std.Io.Clock.awake.now(ctx.io);
    // In memory of its own (TLS loads the system's certificates, more than a request
    // holds), within the time limit; the answer is copied into the call's arena.
    const result = timed.fetch_traced(ctx.io, ctx.arena, .{
        .url = filling.url,
        .method = method,
        .payload = if (filling.body.len > 0) filling.body else null,
        .headers = filling.headers,
        .body_max = answer_bytes_max,
        .guard = guard,
    }, limit_ms, &trace);
    const elapsed = started.durationTo(std.Io.Clock.awake.now(ctx.io));

    try request_log.hops(ctx, fetcher.name, @tagName(method), filling, &trace, elapsed);

    const answer = result catch |err| {
        if (err == error.Refused) {
            return ctx.fail(not_allowed);
        }

        std.log.warn("http.fetch {s}: {t}", .{ fetcher.name, err });

        if (err == error.TimedOut) {
            try request_log.gave_up(ctx, fetcher.name, @tagName(method), filling, limit_ms);
        }

        return ctx.fail(unreachable_failure);
    };

    return .{
        .status = @intFromEnum(answer.status),
        .body = try filling.scrub(ctx, answer.body),
    };
}

pub const Downloaded = downloads.Downloaded;
pub const download = downloads.download;
pub const public_host = downloads.public_host;
pub const not_public = downloads.not_public;

test "http.fetch is refused outside queued work, whatever the plugin is granted" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);

    const held = [_]model.permission.Held{.{
        .key = "http.fetch",
        .domains = &.{"api.example.com"},
    }};
    const access: plugin_access.Access = .{
        .held = &held,
        .own_types = &.{},
    };
    var plugin = harness.ctx(.{
        .plugin = .{
            .name = "courier",
            .access = &access,
        },
    });
    const sent = registry.SDK.dispatch(&plugin, Fetch, .{
        .url = "https://api.example.com/quote",
    });

    try std.testing.expectError(error.Failed, sent);
    try std.testing.expectEqualStrings("NotQueued", plugin.failure.?.name);
}

test "a compiled-in plugin is held to its http.fetch domains, as an installed one is" {
    const plugin_module = @import("../sdk/plugin.zig");
    const Courier = struct {
        pub const manifest: plugin_module.Manifest = .{
            .name = "courier",
            .version = "0.1.0",
            .summary = "Test plugin: sends",
        };
        pub const permissions = [_]model.sandboxed_plugin.Ask{.{
            .key = "http.fetch",
            .domains = &.{ "api.supplier.com", "localhost" },
            .reason = "Sends prices",
        }};
    };
    const grants = comptime plugin_module.grants_of(Courier);
    var ctx: Ctx = undefined;

    ctx.outside = .{};

    const fetcher: Fetcher = .{
        .name = "courier",
        .access = &grants.access,
    };
    const guard = guard_of(&ctx, fetcher);
    const listed = try std.Uri.parse("https://api.supplier.com/prices");
    const elsewhere = try std.Uri.parse("https://elsewhere.example.org/");
    const under = try std.Uri.parse("https://eu.api.supplier.com/prices");
    const here = try std.Uri.parse("http://localhost:8080/");

    try std.testing.expectEqual(null, guards.refusal_of_name(guard, listed));
    try std.testing.expect(guards.refusal_of_name(guard, elsewhere).? == .not_listed);
    try std.testing.expect(guards.refusal_of_name(guard, under).? == .not_listed);
    try std.testing.expect(guards.refusal_of_name(guard, here).? == .local);

    ctx.outside.production = false;
    try std.testing.expectEqual(null, guards.refusal_of_name(guard_of(&ctx, fetcher), here));
}

test {
    _ = timed;
    _ = form_parts;
    _ = guards;
    _ = downloads;
    _ = request_log;
    _ = @import("http_hops.zig");
}
