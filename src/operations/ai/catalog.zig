//! Where official plugins come from: Publr's plugin server, or the folder or address
//! `PUBLR_PLUGIN_CATALOG` names. It holds `catalog.json` and the built modules it lists.
//! From the web, it is read in queued work only: pages answer the copy the `ai_catalog` job
//! keeps, looked at again when it is an hour old.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const environment = @import("../../lib/environment.zig");
const store = @import("../../store.zig");
const jobs = @import("../job.zig");
const http = @import("../http.zig");
const lifecycle = @import("../plugin/lifecycle.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

pub const variable = "PUBLR_PLUGIN_CATALOG";
pub const address_default = "https://plugins.publr.app";
const catalog_bytes_max: u32 = 64 << 10;
/// How old a kept catalog may be before it is looked at again; one not reached, a minute.
const fresh_ms: i64 = 60 * 60 * 1000;
const retry_ms: i64 = 60 * 1000;
const kept_key = "plugin.catalog";

pub const Entry = struct {
    name: []const u8,
    label: []const u8,
    summary: []const u8 = "",
    kind: []const u8 = "",
    version: []const u8 = "",
    /// The built module, relative to the catalog.
    module: []const u8 = "",
    /// The plugins it needs installed first, by name.
    requires: []const []const u8 = &.{},
};

pub const File = struct {
    plugins: []const Entry = &.{},
};

pub const unreachable_failure: sdk.operation.Failure = .{
    .name = "CatalogUnreachable",
    .status = 502,
    .message = "The list of official plugins could not be reached",
};

const no_module: sdk.operation.Failure = .{
    .name = "NoModule",
    .status = 409,
    .message = "The catalog names no built module for it",
};

/// The folder or address the catalog is read from.
pub fn source() []const u8 {
    std.debug.assert(variable.len > 0);

    const named = environment.get(variable) orelse "";

    return if (named.len == 0) address_default else named;
}

fn on_the_web(from: []const u8) bool {
    std.debug.assert(from.len > 0);

    return std.mem.startsWith(u8, from, "https://") or std.mem.startsWith(u8, from, "http://");
}

/// The catalog as last looked at, in a page's request: read at once from a folder; from the
/// web, the kept copy (`looking` while none is), a look queued when it is old.
pub const Kept = struct {
    at: i64 = 0,
    reached: bool = false,
    plugins: []const Entry = &.{},
    /// A look is on its way and nothing was kept before it.
    looking: bool = false,
};

pub fn kept(ctx: *Ctx) Error!Kept {
    std.debug.assert(fresh_ms > retry_ms);

    if (!on_the_web(source())) {
        const file = read(ctx) catch |err| {
            if (err == error.OutOfMemory) {
                return error.OutOfMemory;
            }

            ctx.failure = null;

            return .{};
        };

        return .{
            .at = ctx.now_ms,
            .reached = true,
            .plugins = file.plugins,
        };
    }

    const text = try store.settings.get(ctx.db, ctx.arena, kept_key);
    var found: Kept = if (text) |json| std.json.parseFromSliceLeaky(Kept, ctx.arena, json, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch .{} else .{};
    const age_max = if (found.reached) fresh_ms else retry_ms;
    const waiting = try store.job_queue.waiting_for(ctx.db, jobs.core, "ai_catalog");

    if (ctx.now_ms - found.at >= age_max and !waiting) {
        try jobs.enqueue(ctx, "ai_catalog", struct {}{});
    }

    found.looking = text == null;

    return found;
}

/// The `ai_catalog` job: the catalog read from Publr's plugin server and kept; one that
/// cannot be reached is kept as not reached, and looked at again a minute later.
pub fn refresh(ctx: *Ctx, in: struct {}) Error!void {
    std.debug.assert(ctx.job.len > 0);
    std.debug.assert(fresh_ms > retry_ms);

    _ = in;

    const file = read(ctx) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => blk: {
            ctx.failure = null;
            break :blk null;
        },
    };
    const text = std.json.Stringify.valueAlloc(ctx.arena, Kept{
        .at = ctx.now_ms,
        .reached = file != null,
        .plugins = if (file) |found| found.plugins else &.{},
    }, .{}) catch return error.OutOfMemory;

    if (text.len > store.settings.value_len_max) {
        return ctx.fail(unreachable_failure);
    }

    try store.settings.set(ctx.db, kept_key, text, ctx.now_ms);
}

/// The catalog's entries; fails with `unreachable_failure` when it cannot be read. From the
/// web, queued work only.
pub fn read(ctx: *Ctx) Error!File {
    std.debug.assert(catalog_bytes_max > 0);

    const from = source();
    const path = std.fs.path.join(ctx.arena, &.{ from, "catalog.json" }) catch {
        return error.OutOfMemory;
    };
    const text = if (on_the_web(from))
        try fetched_text(ctx, path)
    else
        std.Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(catalog_bytes_max)) catch {
            return ctx.fail(unreachable_failure);
        };

    return std.json.parseFromSliceLeaky(File, ctx.arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch ctx.fail(unreachable_failure);
}

/// The entry's module, checked and staged as an upload is.
pub fn stage(ctx: *Ctx, entry: Entry) Error!lifecycle.Checked {
    std.debug.assert(entry.name.len > 0);

    const inside = entry.module.len > 0 and entry.module.len <= 256 and
        !std.fs.path.isAbsolute(entry.module) and
        std.mem.indexOf(u8, entry.module, "..") == null;

    if (!inside) {
        return ctx.fail(no_module);
    }

    const from = source();
    const path = std.fs.path.join(ctx.arena, &.{ from, entry.module }) catch {
        return error.OutOfMemory;
    };

    if (!on_the_web(from)) {
        return lifecycle.stage(ctx, path, true);
    }

    const allocator = std.heap.page_allocator;
    const downloaded = try fetched(ctx, allocator, path, model.sandboxed_plugin.bytes_max);
    defer allocator.free(downloaded.buffer);

    const file = std.fmt.allocPrint(ctx.arena, "catalog-{s}.wasm", .{entry.name}) catch {
        return error.OutOfMemory;
    };
    const sandboxed = try lifecycle.sandboxed(ctx);

    _ = try sandboxed.receive(file, 0, downloaded.bytes, true);
    defer sandboxed.consume(file);

    return lifecycle.stage(ctx, file, false);
}

fn fetched_text(ctx: *Ctx, url: []const u8) Error![]const u8 {
    std.debug.assert(url.len > 0);
    std.debug.assert(catalog_bytes_max > 0);

    const allocator = std.heap.page_allocator;
    const downloaded = try fetched(ctx, allocator, url, catalog_bytes_max);
    defer allocator.free(downloaded.buffer);

    return ctx.arena.dupe(u8, downloaded.bytes) catch error.OutOfMemory;
}

/// What `url` answered with 200, in `allocator`'s memory; any other answer is unreachable.
fn fetched(
    ctx: *Ctx,
    allocator: std.mem.Allocator,
    url: []const u8,
    bytes_max: u32,
) Error!http.Downloaded {
    std.debug.assert(url.len > 0);
    std.debug.assert(bytes_max > 0);

    const downloaded = http.download(ctx, allocator, url, bytes_max) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            ctx.failure = null;
            return ctx.fail(unreachable_failure);
        },
    };

    if (downloaded.status != 200 or downloaded.bytes.len == 0) {
        allocator.free(downloaded.buffer);

        return ctx.fail(unreachable_failure);
    }

    return downloaded;
}

test "the catalog defaults to Publr's plugin server" {
    try std.testing.expect(on_the_web(address_default));
    try std.testing.expect(!on_the_web("/srv/plugins"));
    try std.testing.expect(!on_the_web("plugins"));
}
