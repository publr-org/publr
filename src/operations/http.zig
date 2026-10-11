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
    .summary = "Requests a plugin sends out, its secrets filled in as they leave",
    .details =
    \\A plugin granted `http.fetch` sends a request to a domain it declared
    \\(`allowed_domains`): https, or plain http to this machine. Where it writes
    \\`{secret:NAME}` (in the address, a header or the body) the secret's value is filled
    \\in as the request leaves, when the plugin was granted `secret.NAME`; the plugin never
    \\holds it, and a value the answer echoes back is put back as `{secret:NAME}`. Plugins
    \\only.
    ,
};

pub const operations = [_]type{ Fetch, stream.Stream, stream.Read };

pub const stream = @import("http_stream.zig");
const timed = @import("http_timed.zig");

pub const headers_max: u32 = 16;
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
        \\Answers the status and the body (up to 1 MiB). Refused unless the caller is a plugin
        \\granted `http.fetch`, the address's host is one it declared, and every
        \\`{secret:NAME}` it names was granted (`secret.NAME`) and has a value.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        method: []const u8 = "GET",
        url: []const u8,
        headers: []const Header = &.{},
        body: []const u8 = "",
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
        .url = "https, or http to this machine; may hold {secret:NAME}",
        .headers = "Up to 16, as name and value; values may hold {secret:NAME}",
        .body = "Up to 8 MiB; may hold {secret:NAME}",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(headers_max > 0);

        const plugin = switch (ctx.caller) {
            .plugin => |plugin| plugin,
            else => return error.Denied,
        };
        const Method = std.http.Method;
        const method = std.meta.stringToEnum(Method, in.method) orelse return error.Invalid;
        const host = host_of(in.url) orelse return error.Invalid;

        if (in.headers.len > headers_max or in.body.len > body_bytes_max) {
            return error.Invalid;
        }

        if (!allowed(ctx, plugin.name, host)) {
            return ctx.fail(not_allowed);
        }

        var filling = try Filling.of(ctx, plugin, in);

        return send(ctx, method, &filling);
    }
};

pub const not_allowed: sdk.operation.Failure = .{
    .name = "NotAllowed",
    .status = 403,
    .message = "Not a domain the plugin declared",
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

    pub fn of(ctx: *Ctx, plugin: sdk.Caller.Plugin, in: Fetch.In) Error!Filling {
        std.debug.assert(in.url.len > 0);
        std.debug.assert(in.headers.len <= headers_max);

        var storage: [secrets_max][]const u8 = undefined;
        // Kept past this call: the answer is scrubbed of the values by these names.
        const names = ctx.arena.dupe([]const u8, try asked(ctx, in, &storage)) catch {
            return error.OutOfMemory;
        };
        const values = try ctx.arena.alloc([]const u8, names.len);

        for (names, values) |secret_name, *value| {
            const key = try std.fmt.allocPrint(ctx.arena, "secret.{s}", .{secret_name});
            const access = plugin.access orelse return error.Denied;

            if (!access.has(key)) {
                return ctx.fail(.{
                    .name = "SecretNotGranted",
                    .status = 403,
                    .message = key,
                });
            }

            value.* = try secret.value_of(ctx, secret_name) orelse {
                const missing: sdk.operation.Failure = .{
                    .name = "SecretMissing",
                    .status = 409,
                    .message = secret_name,
                };

                return ctx.fail(missing);
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

fn send(ctx: *Ctx, method: std.http.Method, filling: *const Filling) Error!Fetch.Out {
    std.debug.assert(filling.url.len > 0);
    std.debug.assert(answer_bytes_max > 0);

    if (builtin.os.tag == .wasi) {
        return error.Unavailable;
    }

    // In memory of its own (TLS loads the system's certificates, more than a request
    // holds), within the time limit; the answer is copied into the call's arena.
    const result = timed.fetch(ctx.io, ctx.arena, .{
        .url = filling.url,
        .method = method,
        .payload = if (filling.body.len > 0) filling.body else null,
        .headers = filling.headers,
        .body_max = answer_bytes_max,
    }, timed.timeout_ms) catch |err| {
        std.log.warn("http.fetch {s}: {t}", .{ ctx.plugin, err });

        return ctx.fail(unreachable_failure);
    };

    return .{
        .status = @intFromEnum(result.status),
        .body = try filling.scrub(ctx, result.body),
    };
}

/// What core itself downloads (a file to import): a plain GET of a public address.
pub const Downloaded = struct {
    status: u16,
    bytes: []const u8,
    /// What the caller frees with its allocator; `bytes` lie in it.
    buffer: []u8,
};

/// `url`, https or http, on a public host (never this machine or its network), up to
/// `bytes_max`, into `allocator`'s memory.
pub fn download(
    ctx: *Ctx,
    allocator: std.mem.Allocator,
    url: []const u8,
    bytes_max: u32,
) Error!Downloaded {
    std.debug.assert(bytes_max > 0);
    std.debug.assert(url.len > 0);

    const uri = std.Uri.parse(url) catch return error.Invalid;
    const host = switch (uri.host orelse return error.Invalid) {
        .raw, .percent_encoded => |text| text,
    };
    const web = std.mem.eql(u8, uri.scheme, "https") or std.mem.eql(u8, uri.scheme, "http");

    if (!web or host.len == 0 or on_this_machine(host) or on_its_network(host)) {
        return ctx.fail(not_public);
    }

    if (builtin.os.tag == .wasi) {
        return error.Unavailable;
    }

    const result = timed.fetch(ctx.io, allocator, .{
        .url = url,
        .body_max = bytes_max,
    }, timed.timeout_ms) catch |err| {
        std.log.warn("download {s}: {t}", .{ url, err });

        return ctx.fail(unreachable_failure);
    };

    return .{
        .status = @intFromEnum(result.status),
        .bytes = result.body,
        .buffer = result.body,
    };
}

const not_public: sdk.operation.Failure = .{
    .name = "NotPublic",
    .status = 422,
    .message = "Only an http or https address on the web: never this machine or its network",
};

/// A host on the web, never this machine or its network: what may be downloaded from.
pub fn public_host(host: []const u8) bool {
    std.debug.assert(host.len <= 64 << 10);

    return host.len > 0 and !on_this_machine(host) and !on_its_network(host);
}

/// A private address: never downloaded from on the server's behalf.
fn on_its_network(host: []const u8) bool {
    std.debug.assert(host.len <= 64 << 10);

    const prefixes = [_][]const u8{ "10.", "192.168.", "169.254.", "0.", "[fc", "[fd", "[fe80" };

    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, host, prefix)) {
            return true;
        }
    }

    if (std.mem.startsWith(u8, host, "172.")) {
        const rest = host[4..];
        const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return false;
        const second = std.fmt.parseInt(u8, rest[0..dot], 10) catch return false;

        return second >= 16 and second <= 31;
    }

    return std.mem.endsWith(u8, host, ".local") or std.mem.endsWith(u8, host, ".internal");
}

fn on_this_machine(host: []const u8) bool {
    std.debug.assert(host.len <= 64 << 10);

    return std.mem.eql(u8, host, "localhost") or std.mem.startsWith(u8, host, "127.") or
        std.mem.endsWith(u8, host, ".localhost") or std.mem.eql(u8, host, "[::1]");
}

/// The host of an https address, or of an http one on this machine; null otherwise.
pub fn host_of(url: []const u8) ?[]const u8 {
    std.debug.assert(url.len <= 64 << 10);

    const uri = std.Uri.parse(url) catch return null;
    const host = switch (uri.host orelse return null) {
        .raw, .percent_encoded => |text| text,
    };
    const secure = std.mem.eql(u8, uri.scheme, "https");
    const local = on_this_machine(host);

    if (host.len == 0 or !(secure or (std.mem.eql(u8, uri.scheme, "http") and local))) {
        return null;
    }

    return host;
}

/// Whether `plugin` declared `host` (or a domain it is under), or `*`: any address, but
/// never this machine, which a plugin names outright when it means it. A plugin compiled in
/// is the core's own: it may reach anywhere.
pub fn allowed(ctx: *Ctx, plugin: []const u8, host: []const u8) bool {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(host.len > 0);

    const sandboxed = ctx.sandboxed_plugins orelse return true;

    for (sandboxed.manifests()) |manifest| {
        if (!std.mem.eql(u8, manifest.name, plugin)) {
            continue;
        }

        for (manifest.allowed_domains) |domain| {
            const under = std.mem.endsWith(u8, host, domain) and host.len > domain.len and
                host[host.len - domain.len - 1] == '.';
            const anywhere = std.mem.eql(u8, domain, "*") and !on_this_machine(host);

            if (std.mem.eql(u8, host, domain) or under or anywhere) {
                return true;
            }
        }

        return false;
    }

    return true;
}

test "an address goes out over https, or plain http to this machine" {
    try std.testing.expectEqualStrings("api.example.com", host_of("https://api.example.com/v1").?);
    try std.testing.expectEqualStrings("localhost", host_of("http://localhost:11434/v1").?);
    try std.testing.expect(host_of("http://api.example.com/v1") == null);
    try std.testing.expect(host_of("ftp://example.com") == null);
    try std.testing.expect(host_of("not a url") == null);
}

test {
    _ = timed;
}
