//! Publr's marketplace from a project: which of its plugins what someone wants needs
//! (`plugin.find`, decided by the marketplace on its side), and installing one with what it
//! requires (`plugin.install`). The catalog is the one `catalog.zig` reads.

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const catalog = @import("../ai/catalog.zig");
const lifecycle = @import("lifecycle.zig");
const timed = @import("../http_timed.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{ Find, Install };

/// Where the marketplace decides, under its address.
const select_path = "/_actions/app.marketplace.select";
const request_len_max: u32 = 4000;
const answer_bytes_max: u32 = 256 << 10;
/// How deep requirements go: a plugin that requires one that requires one…
const requires_depth_max: u32 = 8;

pub const Pick = struct {
    name: []const u8,
    label: []const u8 = "",
    summary: []const u8 = "",
    requires: []const []const u8 = &.{},
    /// How sure the marketplace is that it gives the request something it needs, 0 to 1.
    fit: f64 = 0,
};

pub const Find = struct {
    pub const name = "plugin.find";
    pub const description = "Ask Publr's marketplace which plugins what you want needs";
    pub const details =
        \\Administrators only. `request` is what someone wants to build, in their words; the
        \\marketplace (Publr's own, at plugins.publr.app, deciding with its own model) answers
        \\the plugins that give it something it needs, best first, leaving out those
        \\installed here. Install each with `plugin install`; build only what none of them
        \\gives. With `PUBLR_PLUGIN_CATALOG` naming a folder, every plugin there is listed.
        \\Fails `CatalogUnreachable` when the marketplace cannot be asked.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        request: []const u8,
    };
    pub const Out = struct {
        plugins: []const Pick,
    };
    pub const rules: sdk.operation.Rules(In) = .{
        .request = .{
            .max_len = request_len_max,
        },
    };
    pub const example: In = .{
        .request = "A shop with products in sizes, and orders I can manage",
    };
    pub const example_out: Out = .{
        .plugins = &.{.{
            .name = "products",
            .label = "Products",
            .summary = "Products and their variants, each variant with a price",
            .fit = 0.93,
        }},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .request = "What they want to build, in their words",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .plugins = "The plugins that fit, best first, with what each requires",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(in.request.len <= request_len_max);

        if (std.mem.trim(u8, in.request, " \n\t").len == 0) {
            return error.Invalid;
        }

        const installed = try installed_names(ctx);
        const source = catalog.source();

        if (!web(source)) {
            return .{
                .plugins = try listed(ctx, installed),
            };
        }

        return .{
            .plugins = try selected(ctx, source, in.request, installed),
        };
    }
};

pub const Install = struct {
    pub const name = "plugin.install";
    pub const description = "Install a plugin from Publr's marketplace, with what it requires";
    pub const details =
        \\Administrators only. Adds the plugin's built module from the marketplace, as
        \\uploading it does, after every plugin it requires (theirs first), and enables
        \\each: low and medium permissions are granted, high ones wait for an administrator
        \\under Settings › Plugins. One installed already is only enabled. All or none.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
    };
    pub const Out = struct {
        /// Every plugin installed or enabled, in the order it was.
        names: []const []const u8,
    };
    pub const example: In = .{
        .name = "checkout",
    };
    pub const example_out: Out = .{
        .names = &.{ "products", "cart", "checkout" },
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The plugin's name, as `plugin find` answers it",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .names = "Every plugin installed or enabled, requirements first",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const file = try catalog.read(ctx);
        var order: std.ArrayList([]const u8) = .empty;

        try visit(ctx, file, in.name, &order, 0);

        for (order.items) |plugin| {
            try install_one(ctx, file, plugin);
        }

        return .{
            .names = order.items,
        };
    }
};

/// `name` after everything it requires, each once.
fn visit(
    ctx: *Ctx,
    file: catalog.File,
    name: []const u8,
    order: *std.ArrayList([]const u8),
    depth: u32,
) Error!void {
    std.debug.assert(name.len > 0);

    if (depth > requires_depth_max) {
        return error.Invalid;
    }

    for (order.items) |done| {
        if (std.mem.eql(u8, done, name)) {
            return;
        }
    }

    const entry = entry_of(file, name) orelse return error.NotFound;

    for (entry.requires) |required| {
        try visit(ctx, file, required, order, depth + 1);
    }

    order.append(ctx.arena, entry.name) catch return error.OutOfMemory;
}

fn entry_of(file: catalog.File, name: []const u8) ?catalog.Entry {
    std.debug.assert(name.len > 0);

    for (file.plugins) |entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            return entry;
        }
    }

    return null;
}

fn install_one(ctx: *Ctx, file: catalog.File, name: []const u8) Error!void {
    std.debug.assert(name.len > 0);

    const entry = entry_of(file, name).?;

    if (try store.sandboxed_plugins.get(ctx.db, ctx.arena, entry.name) == null) {
        _ = try lifecycle.add(ctx, try catalog.stage(ctx, entry));
    }

    _ = try lifecycle.enable(ctx, entry.name, &.{});
}

fn installed_names(ctx: *Ctx) Error![]const []const u8 {
    std.debug.assert(ctx.now_ms >= 0);

    const rows = try store.sandboxed_plugins.list(ctx.db, ctx.arena);
    const names = ctx.arena.alloc([]const u8, rows.len) catch return error.OutOfMemory;

    for (rows, names) |row, *one| {
        one.* = row.name;
    }

    return names;
}

fn web(source: []const u8) bool {
    std.debug.assert(source.len > 0);

    return std.mem.startsWith(u8, source, "https://") or std.mem.startsWith(u8, source, "http://");
}

/// A folder's plugins that build something, without asking anyone: for developing.
fn listed(ctx: *Ctx, installed: []const []const u8) Error![]const Pick {
    std.debug.assert(ctx.now_ms >= 0);

    const file = try catalog.read(ctx);
    var picks: std.ArrayList(Pick) = .empty;

    for (file.plugins) |entry| {
        const builds = std.mem.eql(u8, entry.kind, "feature");

        if (!builds or contains(installed, entry.name)) {
            continue;
        }

        picks.append(ctx.arena, .{
            .name = entry.name,
            .label = entry.label,
            .summary = entry.summary,
            .requires = entry.requires,
        }) catch return error.OutOfMemory;
    }

    return picks.items;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (names) |one| {
        if (std.mem.eql(u8, one, name)) {
            return true;
        }
    }

    return false;
}

const Selected = struct {
    plugins: []const Pick = &.{},
};

/// What the marketplace at `source` decides, asked as a page of its own would ask.
fn selected(
    ctx: *Ctx,
    source: []const u8,
    request: []const u8,
    installed: []const []const u8,
) Error![]const Pick {
    std.debug.assert(source.len > 0);
    std.debug.assert(request.len > 0);

    if (builtin.os.tag == .wasi) {
        return error.Unavailable;
    }

    const arena = ctx.arena;
    const url = std.fmt.allocPrint(arena, "{s}{s}", .{ source, select_path }) catch {
        return error.OutOfMemory;
    };
    const body = std.json.Stringify.valueAlloc(arena, .{
        .request = request,
        .installed = installed,
    }, .{}) catch return error.OutOfMemory;
    const answered = timed.fetch(ctx.io, arena, .{
        .url = url,
        .method = .POST,
        .payload = body,
        .headers = &.{
            .{
                .name = "Content-Type",
                .value = "application/json",
            },
            .{
                .name = "Origin",
                .value = source,
            },
            .{
                .name = "Publr-Request",
                .value = "1",
            },
        },
        .body_max = answer_bytes_max,
    }, timed.timeout_ms) catch |err| {
        std.log.warn("plugin find: {t}", .{err});
        return ctx.fail(catalog.unreachable_failure);
    };

    if (answered.status != .ok) {
        std.log.warn("plugin find: {d}", .{@intFromEnum(answered.status)});
        return ctx.fail(catalog.unreachable_failure);
    }

    const parsed = std.json.parseFromSliceLeaky(Selected, arena, answered.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return ctx.fail(catalog.unreachable_failure);

    return parsed.plugins;
}

test "a plugin comes after what it requires, each once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();
    var ctx = harness.ctx(.system);
    ctx.arena = arena_state.allocator();

    const file: catalog.File = .{
        .plugins = &.{
            .{
                .name = "products",
                .label = "Products",
            },
            .{
                .name = "cart",
                .label = "Cart",
                .requires = &.{"products"},
            },
            .{
                .name = "checkout",
                .label = "Checkout",
                .requires = &.{ "cart", "products" },
            },
        },
    };
    var order: std.ArrayList([]const u8) = .empty;

    try visit(&ctx, file, "checkout", &order, 0);
    try std.testing.expectEqual(@as(usize, 3), order.items.len);
    try std.testing.expectEqualStrings("products", order.items[0]);
    try std.testing.expectEqualStrings("cart", order.items[1]);
    try std.testing.expectEqualStrings("checkout", order.items[2]);
    try std.testing.expectError(error.NotFound, visit(&ctx, file, "nope", &order, 0));
}
