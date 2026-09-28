//! The surgical rebuild that follows a change, planned by the dependency index: `flush`
//! between the server's ticks, and `refresh` at startup, which brings an existing build up
//! to date with the least work (nothing, the pending batches, or the whole site).

const std = @import("std");
const diagnostic_report = @import("../../lib/report.zig");
const sdk = @import("../../sdk.zig");
const registry = @import("../../app/registry.zig");
const identity_module = @import("../rest/identity.zig");
const record_operations = @import("../../operations/record.zig");
const deps = @import("../../lib/deps.zig");
const engine = @import("../../theme.zig");
const context_module = @import("context.zig");
const build = @import("build.zig");
const passthrough = @import("passthrough.zig");
const Site = @import("../../app/site.zig").Site;
const state = @import("state.zig");
const Public = state.Public;

const islands_prefix = context_module.islands_prefix;

/// The file a full build leaves in the output folder: the stamp of the theme that built it.
pub const marker_path = ".publr-build";
pub const marker_len_max: u32 = state.version_len + 1;
const batches_per_flush_max: u32 = 16;
/// How many batches a startup replays before giving up on the queue and building whole.
const batches_per_refresh_max: u32 = 1024;

/// What `refresh` did: nothing, the artifacts the pending changes reached, or everything.
pub const Outcome = enum { current, refreshed, built };

pub const Refreshed = struct {
    outcome: Outcome,
    /// Public files copied independently of generated pages.
    copied: u32 = 0,
    /// Pages and islands whose bytes changed and were written again.
    written: u32 = 0,
    /// Pages and islands the theme or the records no longer have.
    removed: u32 = 0,
    /// The full build's figures when `outcome` is `built`.
    full: build.Summary = .{},
};

const Counts = struct { written: u32 = 0, removed: u32 = 0 };

/// An existing build brought up to date: no work when its marker carries this theme's
/// stamp and no change waits; the pending batches replayed when they do; the whole site
/// when there is no build, the theme or the address changed, or a batch is too wide to
/// plan (`error.FanOutExceeded` is the index refusing, never a failure).
pub fn refresh(public: *Public, site: *const Site) !Refreshed {
    std.debug.assert(public.theme.routes.len > 0);
    std.debug.assert(site.connection.transaction_depth == 0);

    if (public.output == null) {
        public.open_existing_output();
    }

    if (public.output == null or !marker_matches(public)) {
        return .{ .outcome = .built, .full = try build.build(public, site) };
    }

    var arena_state = std.heap.ArenaAllocator.init(public.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Every queued change is due now: a quiet period is for a server that keeps running.
    const later = sdk.context.wall_clock_ms(site.io) + deps.quiet_ms;
    const copied = try passthrough.sync(public);
    var result: Refreshed = .{ .outcome = .current, .copied = copied.files };
    var batches: u32 = 0;

    while (batches < batches_per_refresh_max) : (batches += 1) {
        const batch = (try public.index.take(arena, later)) orelse break;
        const counts = rebuild_batch(public, site, arena, batch) catch |err| switch (err) {
            error.FanOutExceeded => return .{
                .outcome = .built,
                .full = try build.build(public, site),
            },
            else => return err,
        };

        result.written += counts.written;
        result.removed += counts.removed;
    }

    if (batches == batches_per_refresh_max) {
        return .{ .outcome = .built, .full = try build.build(public, site) };
    }

    if (result.written > 0 or result.removed > 0) {
        result.outcome = .refreshed;
        try build.write_sitemap(public, site);
    }

    return result;
}

/// Whether the output folder was built by this theme, at this address.
pub fn marker_matches(public: *const Public) bool {
    std.debug.assert(public.output != null);
    std.debug.assert(public.theme.templates.len > 0);

    var buffer: [marker_len_max]u8 = undefined;
    const out = public.output.?;
    const read = out.readFile(public.io, marker_path, &buffer) catch return false;
    const found = std.mem.trimEnd(u8, read, "\r\n");

    std.debug.assert(read.len <= marker_len_max);

    return std.mem.eql(u8, found, &public.build_stamp);
}

pub fn write_marker(public: *const Public) !void {
    std.debug.assert(public.output != null);
    std.debug.assert(public.theme.templates.len > 0);

    var buffer: [marker_len_max]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{s}\n", .{&public.build_stamp});

    std.debug.assert(line.len == marker_len_max);

    try public.output.?.writeFile(public.io, .{ .sub_path = marker_path, .data = line });
}

/// Takes every due batch and rebuilds its plan. Best effort: a failure leaves a stale file
/// and a line on stderr, never a failed request.
pub fn flush(public: *Public, site: *const Site, now_ms: i64) void {
    std.debug.assert(now_ms >= 0);
    std.debug.assert(site.connection.transaction_depth == 0);

    if (public.output == null) {
        return;
    }

    var arena_state = std.heap.ArenaAllocator.init(public.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var batches: u32 = 0;

    while (batches < batches_per_flush_max) : (batches += 1) {
        const batch = (public.index.take(arena, now_ms) catch return) orelse return;

        _ = rebuild_batch(public, site, arena, batch) catch |err| {
            diagnostic_report.err_reason(
                reason_of(public),
                "site: rebuild refused: {s}",
                .{
                    @errorName(err),
                },
            );

            return;
        };

        build.write_sitemap(public, site) catch |err| {
            std.debug.print("site: sitemap: {s}\n", .{@errorName(err)});
        };
    }
}

/// Whether a batch waits to be taken: what `serve` asks between ticks.
pub fn due(public: *Public, now_ms: i64) bool {
    std.debug.assert(now_ms >= 0);
    std.debug.assert(public.index.options.quiet_ms == deps.quiet_ms);

    if (public.output == null) {
        return false;
    }

    return public.index.due(now_ms) catch false;
}

/// One batch through its plan and marked done. A plan the index refuses
/// (`error.FanOutExceeded`) leaves the batch waiting for the caller to decide.
fn rebuild_batch(
    public: *Public,
    site: *const Site,
    arena: std.mem.Allocator,
    batch: deps.Batch,
) !Counts {
    std.debug.assert(batch.no > 0);
    std.debug.assert(public.output != null);

    var counts: Counts = .{};

    counts.written += ensure_record_pages(public, site, arena, batch.keys);

    const plan = try public.index.plan(arena, batch);

    for (plan) |url| {
        switch (rebuild_artifact(public, site, arena, batch.no, url)) {
            .written => counts.written += 1,
            .removed => counts.removed += 1,
            .identical, .failed => {},
        }
    }

    try public.index.done(batch);

    return counts;
}

/// Renders the page or the static island `url` names again. A page whose entry is gone,
/// or an artifact the theme no longer has, is removed and forgotten.
fn rebuild_artifact(
    public: *Public,
    site: *const Site,
    arena: std.mem.Allocator,
    batch: u64,
    url: []const u8,
) deps.Outcome {
    std.debug.assert(url.len > 0);
    std.debug.assert(batch > 0);

    const theme = public.theme;

    if (std.mem.startsWith(u8, url, islands_prefix)) {
        const key = url[islands_prefix.len..];

        if (theme.find_island(key)) |island| {
            if (!island.dynamic) {
                const rendered = build.render_island(public, site, island, .when_changed);
                const result = rendered catch |err| {
                    return report(public, batch, url, .failed, @errorName(err));
                };
                const outcome: deps.Outcome = if (result.wrote) .written else .identical;

                return report(public, batch, url, outcome, "");
            }
        }

        remove_island(public, arena, key);

        return report(public, batch, url, .removed, "");
    }

    const matched = theme.match(url) orelse {
        remove_url(public, url);

        return report(public, batch, url, .removed, "no route");
    };

    if (matched.route.live or matched.route.kind == .catch_all) {
        remove_url(public, url);

        return report(public, batch, url, .removed, "rendered per request");
    }

    // Only a `[slug]` page has a record to lose; anywhere else "not found" is a failed
    // render, and the file it had stays.
    const params: context_module.Params = .{ .slug = matched.slug };
    const rendered = build.render_url(public, site, matched.route, url, params, .when_changed);
    const result = rendered catch |err| {
        if (err == error.EntryNotFound and matched.slug != null) {
            remove_url(public, url);

            return report(public, batch, url, .removed, "its record is gone");
        }

        return report(public, batch, url, .failed, @errorName(err));
    };

    return report(public, batch, url, if (result.wrote) .written else .identical, "");
}

/// The observer's window into a rebuild. A removal or a failure is always said: a file
/// that vanished is what someone will ask about; the rest only under `log`.
fn report(
    public: *const Public,
    batch: u64,
    url: []const u8,
    outcome: deps.Outcome,
    detail: []const u8,
) deps.Outcome {
    std.debug.assert(url.len > 0);
    std.debug.assert(batch > 0);

    public.index.executed(batch, url, outcome, detail);

    if (public.options.log or outcome == .removed or outcome == .failed) {
        std.debug.print("site: rebuilt {s}: {s} {s}\n", .{ url, @tagName(outcome), detail });
    }

    return outcome;
}

/// A record that was just published has a page no plan can name yet: for every changed
/// record still readable by a visitor, its own routes are rendered outright (unchanged bytes
/// are not written), before the batch is planned like any other. How many were written.
fn ensure_record_pages(
    public: *Public,
    site: *const Site,
    arena: std.mem.Allocator,
    keys: []const []const u8,
) u32 {
    std.debug.assert(public.output != null);
    std.debug.assert(keys.len <= public.index.options.queue_cap);

    const prefix = "record:";
    var written: u32 = 0;

    for (keys) |key| {
        if (!std.mem.startsWith(u8, key, prefix)) {
            continue;
        }

        var sdk_ctx = identity_module.context(site, arena, .anonymous);
        const got = registry.SDK.dispatch(&sdk_ctx, record_operations.Get, .{
            .id = key[prefix.len..],
        }) catch continue;
        const slug = got.record.slug orelse continue;

        written += record_pages(public, site, arena, slug);
    }

    return written;
}

fn record_pages(
    public: *Public,
    site: *const Site,
    arena: std.mem.Allocator,
    slug: []const u8,
) u32 {
    std.debug.assert(slug.len > 0);
    std.debug.assert(public.output != null);

    var written: u32 = 0;

    for (public.theme.routes) |*route| {
        if (route.kind != .dynamic or route.live) {
            continue;
        }

        const url = engine.substitute(arena, route.pattern, slug) catch return written;
        const params: context_module.Params = .{ .slug = slug };
        const rendered = build.render_url(public, site, route, url, params, .when_changed);
        const result = rendered catch |err| {
            diagnostic_report.err_reason(
                reason_of(public),
                "site: {s}: {s}",
                .{
                    url,
                    @errorName(err),
                },
            );

            continue;
        };

        if (result.wrote) {
            written += 1;
        }
    }

    return written;
}

fn remove_url(public: *Public, url: []const u8) void {
    std.debug.assert(url.len > 0);
    std.debug.assert(public.output != null);

    const out = public.output.?;

    if (url.len <= 1) {
        out.deleteFile(public.io, "index.html") catch |err| report_removal(url, err);
    } else {
        out.deleteTree(public.io, url[1..]) catch |err| report_removal(url, err);
    }

    public.index.forget(url) catch |err| {
        std.debug.print("site: forget {s}: {s}\n", .{ url, @errorName(err) });
    };
}

/// A file that was already gone is what removal wanted; anything else is said.
fn report_removal(url: []const u8, err: anyerror) void {
    std.debug.assert(url.len > 0);
    std.debug.assert(@errorName(err).len > 0);

    if (err != error.FileNotFound) {
        std.debug.print("site: remove {s}: {s}\n", .{ url, @errorName(err) });
    }
}

fn remove_island(public: *Public, arena: std.mem.Allocator, key: []const u8) void {
    std.debug.assert(key.len > 0);
    std.debug.assert(public.output != null);

    const out = public.output.?;
    const path = build.island_path(arena, key) catch return;
    const url = std.fmt.allocPrint(arena, "{s}{s}", .{ islands_prefix, key }) catch return;

    out.deleteFile(public.io, path) catch |err| report_removal(url, err);
    public.index.forget(url) catch |err| {
        std.debug.print("site: forget {s}: {s}\n", .{ url, @errorName(err) });
    };
}

test "the marker file can never be served as a page" {
    // `built_page` refuses any path with a dot-segment, so the marker stays private.
    try std.testing.expect(std.mem.startsWith(u8, marker_path, "."));
    try std.testing.expect(std.mem.indexOfScalar(u8, marker_path, '/') == null);
}

fn reason_of(public: *const Public) []const u8 {
    return if (public.options.diagnostic) |reason| reason.text() else "";
}
