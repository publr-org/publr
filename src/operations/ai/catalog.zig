//! Where official plugins come from: Publr's plugin server, or the folder or address
//! `PUBLR_PLUGIN_CATALOG` names. It holds `catalog.json` and the built modules it lists.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const environment = @import("../../lib/environment.zig");
const http = @import("../http.zig");
const lifecycle = @import("../plugin/lifecycle.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

pub const variable = "PUBLR_PLUGIN_CATALOG";
pub const address_default = "https://plugins.publr.app";
const catalog_bytes_max: u32 = 64 << 10;

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

/// The catalog's entries; fails with `unreachable_failure` when it cannot be read.
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
