//! What plugins read of visitors' requests at the door, compiled in or installed: each
//! declares the query parameters and cookies it reads and the path prefixes it answers
//! (`.request`), and holds `request.read` or `request.redirect`, asked for at install. Core
//! keeps, per visitor, where they first and last landed with what the parameters some plugin
//! reads held (a referral code, campaign tags), the page that sent them there and when; a
//! plugin reads its own names back with `request.read`. A path under a prefix a plugin
//! answers (`/ref/ada`) runs its operation, which says where the visitor goes.
const std = @import("std");
const sdk = @import("../sdk.zig");
const store = @import("../store.zig");
const sandboxed_plugin = @import("../model/sandboxed_plugin.zig");

pub const RequestReads = sandboxed_plugin.RequestReads;

/// Where core keeps what visitors brought: its own internal records, one per visitor.
pub const visits: store.internal_records.Scope = .{
    .plugin = store.job_queue.core,
    .app = "",
    .kind = "visit",
};

pub const value_len_max: u32 = 256;

/// One query parameter as a visitor brought it.
pub const Value = struct {
    name: []const u8,
    value: []const u8,
};

/// Where a visitor landed, from where, when, with what.
pub const Touch = struct {
    landing: []const u8 = "",
    referrer: []const u8 = "",
    at_ms: i64 = 0,
    values: []const Value = &.{},
};

/// A visitor's first and latest landing that brought something a plugin reads.
pub const Visit = struct {
    first: Touch = .{},
    last: Touch = .{},
};

/// A plugin's declaration, with whether it holds each permission.
pub const Declared = struct {
    plugin: []const u8,
    reads: RequestReads,
    may_read: bool,
    may_redirect: bool,
};

/// Every plugin that declares `.request`, compiled in or installed.
pub fn declared(ctx: *const sdk.Ctx) error{OutOfMemory}![]const Declared {
    std.debug.assert(ctx.now_ms >= 0);

    const registry = @import("../server/registry.zig");
    var list: std.ArrayList(Declared) = .empty;

    for (registry.request_reads) |one| {
        const access = registry.SDK.compiled_access(one.plugin);
        const holds_read = if (access) |held| held.held_of("request.read") != null else false;
        const holds_redirect = if (access) |held|
            held.held_of("request.redirect") != null
        else
            false;

        try list.append(ctx.arena, .{
            .plugin = one.plugin,
            .reads = one.reads,
            .may_read = holds_read,
            .may_redirect = holds_redirect,
        });
    }

    const sandboxed = ctx.sandboxed_plugins orelse return list.items;

    for (sandboxed.manifests()) |manifest| {
        const reads = manifest.request;

        if (reads.query.len + reads.cookies.len + reads.redirects.len == 0) {
            continue;
        }

        try list.append(ctx.arena, .{
            .plugin = manifest.name,
            .reads = reads,
            .may_read = sandboxed.holds(manifest.name, "request.read"),
            .may_redirect = sandboxed.holds(manifest.name, "request.redirect"),
        });
    }

    return list.items;
}

/// Keeps what the visitor's landing brought of the query parameters plugins read: their
/// first landing that brought any, and their latest. Nothing when it brought none.
pub fn record(
    ctx: *sdk.Ctx,
    visitor: []const u8,
    landing: []const u8,
    query_text: []const u8,
    referrer: []const u8,
) sdk.Error!void {
    std.debug.assert(landing.len > 0);
    std.debug.assert(query_text.len <= 64 << 10);

    if (visitor.len == 0 or query_text.len == 0) {
        return;
    }

    var values: std.ArrayList(Value) = .empty;

    for (try declared(ctx)) |one| {
        if (!one.may_read) {
            continue;
        }

        for (one.reads.query) |name| {
            const value = query_value(query_text, name) orelse continue;

            if (value.len > 0 and value.len <= value_len_max and !named(values.items, name)) {
                try values.append(ctx.arena, .{
                    .name = name,
                    .value = value,
                });
            }
        }
    }

    if (values.items.len == 0) {
        return;
    }

    const touch: Touch = .{
        .landing = landing[0..@min(landing.len, 512)],
        .referrer = referrer[0..@min(referrer.len, 512)],
        .at_ms = ctx.now_ms,
        .values = values.items,
    };
    const kept = try visit_of(ctx, visitor);
    const visit: Visit = .{
        .first = if (kept) |was| was.first else touch,
        .last = touch,
    };
    const text = std.json.Stringify.valueAlloc(ctx.arena, visit, .{}) catch {
        return error.OutOfMemory;
    };

    if (kept == null) {
        try store.internal_records.insert_as(ctx.db, visits, visitor, text, ctx.now_ms);
    } else {
        _ = try store.internal_records.update(ctx.db, visits, visitor, text, null, ctx.now_ms);
    }
}

/// What was kept of the visitor's landings; null when nothing was.
pub fn visit_of(ctx: *sdk.Ctx, visitor: []const u8) sdk.Error!?Visit {
    std.debug.assert(visitor.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    const row = try store.internal_records.get(ctx.db, ctx.arena, visits, visitor) orelse {
        return null;
    };

    return std.json.parseFromSliceLeaky(Visit, ctx.arena, row.document, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch null;
}

/// The plugin and operation answering `path`, and the rest of the path after its prefix;
/// null when no plugin holding `request.redirect` answers it.
pub const Answering = struct {
    plugin: []const u8,
    operation: []const u8,
    rest: []const u8,
};

pub fn answering(ctx: *const sdk.Ctx, path: []const u8) error{OutOfMemory}!?Answering {
    std.debug.assert(path.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    for (try declared(ctx)) |one| {
        if (!one.may_redirect) {
            continue;
        }

        for (one.reads.redirects) |redirect| {
            if (redirect.prefix.len > 1 and std.mem.startsWith(u8, path, redirect.prefix)) {
                return .{
                    .plugin = one.plugin,
                    .operation = try std.mem.concat(ctx.arena, u8, &.{
                        one.plugin,
                        ".",
                        redirect.operation,
                    }),
                    .rest = path[redirect.prefix.len..],
                };
            }
        }
    }

    return null;
}

/// A value of `query_text` as sent: `?ref=ada` gives `ada`.
pub fn query_value(query_text: []const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(query_text.len <= 64 << 10);

    var parts = std.mem.splitScalar(u8, query_text, '&');

    while (parts.next()) |part| {
        const equals = std.mem.indexOfScalar(u8, part, '=') orelse continue;

        if (std.mem.eql(u8, part[0..equals], name)) {
            return part[equals + 1 ..];
        }
    }

    return null;
}

/// A cookie of a `Cookie` header, by name.
pub fn cookie_value(header: []const u8, name: []const u8) ?[]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(header.len <= 64 << 10);

    var parts = std.mem.splitScalar(u8, header, ';');

    while (parts.next()) |part| {
        const pair = std.mem.trim(u8, part, " ");
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;

        if (std.mem.eql(u8, pair[0..equals], name)) {
            return pair[equals + 1 ..];
        }
    }

    return null;
}

fn named(values: []const Value, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (values) |value| {
        if (std.mem.eql(u8, value.name, name)) {
            return true;
        }
    }

    return false;
}

test "a query's values and a cookie, by name" {
    try std.testing.expectEqualStrings("ada", query_value("utm_source=news&ref=ada", "ref").?);
    try std.testing.expect(query_value("ref=ada", "utm") == null);
    try std.testing.expectEqualStrings("yes", cookie_value("a=1; consent=yes", "consent").?);
    try std.testing.expect(cookie_value("a=1", "consent") == null);
}
