//! Publr's marketplace from a project: which of its plugins what someone wants needs
//! (`plugin.find`, decided by the marketplace on its side), and installing one with what it
//! requires (`plugin.install`). The catalog is the one `catalog.zig` reads. Both reach
//! another server, so both answer at once and run as core's queued work (`job.zig`).

const std = @import("std");
const public = @import("../../publr/operations/plugin/market.zig");
const builtin = @import("builtin");
const sdk = @import("../../sdk.zig");
const store = @import("../../store.zig");
const catalog = @import("../ai/catalog.zig");
const lifecycle = @import("lifecycle.zig");
const timed = @import("../http_timed.zig");
const jobs = @import("../job.zig");
const setup = @import("../ai/setup.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const operations = [_]type{ Find, Install };

/// Where the marketplace decides, under its address.
const select_path = "/_actions/app.marketplace.select";
const selected_path = "/_actions/app.marketplace.selected";
const request_len_max: u32 = 4000;
const answer_bytes_max: u32 = 256 << 10;
/// How deep requirements go: a plugin that requires one that requires one…
const requires_depth_max: u32 = 8;

pub const Pick = public.Pick;

pub const Find = struct {
    pub const shape = public.Find;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const Found = shape.Found;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        const characters = std.unicode.utf8CountCodepoints(in.request) catch in.request.len;

        if (characters > request_len_max) {
            return ctx.refuse(&.{.{
                .field = "request",
                .message = std.fmt.comptimePrint("A request is at most {d} characters.", .{
                    request_len_max,
                }),
            }});
        }

        if (std.mem.trim(u8, in.request, " \n\t").len == 0) {
            return error.Invalid;
        }

        return .{
            .asked = try jobs.ask(ctx, "find", Finding{
                .request = in.request,
            }),
        };
    }
};

pub const Finding = struct {
    asked: []const u8 = "",
    request: []const u8,
};

/// The `find` job: the plugins the marketplace picks, or, from a folder, every plugin there
/// that builds something; kept for whoever asked.
pub fn find_job(ctx: *Ctx, in: Finding) Error!void {
    std.debug.assert(ctx.job.len > 0);
    std.debug.assert(in.asked.len > 0);

    const installed = try installed_names(ctx);
    const source = catalog.source();

    if (web(source)) {
        // The marketplace keeps the request and decides in its own time: its picks are
        // asked for a moment later (`find_wait`).
        const kept = selection(ctx, source, in.request, installed) catch |err| {
            if (err == error.OutOfMemory) {
                return error.OutOfMemory;
            }

            return answer_listed(ctx, in.asked);
        };

        return jobs.enqueue_at(ctx, "find_wait", Waiting{
            .asked = in.asked,
            .selection = kept,
        }, ctx.now_ms + look_ms);
    }

    return answer_listed(ctx, in.asked);
}

/// Every catalog plugin that builds something and is not installed: a folder's answer, and
/// the web's when the marketplace cannot be asked, so the caller still has a list to choose
/// from.
fn answer_listed(ctx: *Ctx, asked: []const u8) Error!void {
    std.debug.assert(ctx.job.len > 0);
    std.debug.assert(asked.len > 0);

    const installed = try installed_names(ctx);
    const found = listed(ctx, installed) catch |err| {
        if (err == error.OutOfMemory) {
            return error.OutOfMemory;
        }

        return jobs.fail(ctx, asked, jobs.problem_of(ctx, err));
    };

    return jobs.answer(ctx, asked, Find.Found{
        .plugins = found,
    });
}

pub const Install = struct {
    pub const shape = public.Install;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.name.len == 0 or in.name.len > 64) {
            return error.Invalid;
        }

        return .{
            .asked = try jobs.ask(ctx, "install", Installing{
                .names = &.{in.name},
            }),
        };
    }
};

/// What the `install` job installs, `plugin.install`'s and `ai.set_up`'s.
pub const Installing = struct {
    asked: []const u8 = "",
    names: []const []const u8,
    /// Model providers: each granted too what a provider needs to answer (`ai.set_up`).
    providers: bool = false,
};

pub const Installed = struct {
    names: []const []const u8,
};

/// The `install` job: each module downloaded first, then all added and started in one
/// write, so a slow server never holds the database; how it went kept for whoever asked.
pub fn install_job(ctx: *Ctx, in: Installing) Error!void {
    std.debug.assert(ctx.job.len > 0);
    std.debug.assert(in.asked.len > 0);

    const names = installed_all(ctx, in) catch |err| {
        if (err == error.OutOfMemory) {
            return error.OutOfMemory;
        }

        return jobs.fail(ctx, in.asked, jobs.problem_of(ctx, err));
    };

    return jobs.answer(ctx, in.asked, Installed{
        .names = names,
    });
}

fn installed_all(ctx: *Ctx, in: Installing) Error![]const []const u8 {
    std.debug.assert(in.names.len > 0);

    const file = try catalog.read(ctx);
    var order: std.ArrayList([]const u8) = .empty;

    for (in.names) |wanted| {
        if (entry_of(file, wanted) == null) {
            return ctx.fail(not_in_catalog);
        }

        try visit(ctx, file, wanted, &order, 0);
    }

    const checked = ctx.arena.alloc(?lifecycle.Checked, order.items.len) catch {
        return error.OutOfMemory;
    };

    for (order.items, checked) |plugin, *one| {
        const there = try store.sandboxed_plugins.get(ctx.db, ctx.arena, plugin) != null;

        one.* = if (there) null else try catalog.stage(ctx, entry_of(file, plugin).?);
    }

    var transaction = try ctx.db.transaction();
    errdefer transaction.rollback();

    for (checked) |one| {
        if (one) |module| {
            _ = try lifecycle.add(ctx, module);
        }
    }

    try transaction.commit();

    // Started through their operations, so what changes is heard as anyone's change is.
    const SDK = @import("../../server/registry.zig").SDK;

    _ = try SDK.dispatch(ctx, @import("../plugin.zig").Enable, .{
        .names = order.items,
    });

    if (in.providers) {
        for (order.items) |plugin| {
            try setup.grant_provider(ctx, plugin);
        }
    }

    return order.items;
}

const not_in_catalog: sdk.operation.Failure = .{
    .name = "NotInCatalog",
    .status = 404,
    .message = "No plugin of that name in the catalog",
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

/// The catalog's plugins that build something, without asking anyone.
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

/// What the marketplace at `source` answers `action` with, posted as a page of its own
/// would post it.
fn posted(ctx: *Ctx, source: []const u8, action: []const u8, body: []const u8) Error![]const u8 {
    std.debug.assert(source.len > 0);
    std.debug.assert(action.len > 0);

    if (builtin.os.tag == .wasi) {
        return error.Unavailable;
    }

    // Nothing a request waits on reaches another server.
    std.debug.assert(ctx.job.len > 0);

    const url = std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ source, action }) catch {
        return error.OutOfMemory;
    };
    const answered = timed.fetch(ctx.io, ctx.arena, .{
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
        std.log.warn("plugin find: {d}", .{@backingInt(answered.status)});
        return ctx.fail(catalog.unreachable_failure);
    }

    return answered.body;
}

/// The marketplace's selection for `request`: its id, answered at once, the picks read
/// later with `selected` (the `find_wait` job).
fn selection(
    ctx: *Ctx,
    source: []const u8,
    request: []const u8,
    installed: []const []const u8,
) Error![]const u8 {
    std.debug.assert(request.len > 0);

    const body = std.json.Stringify.valueAlloc(ctx.arena, .{
        .request = request,
        .installed = installed,
    }, .{}) catch return error.OutOfMemory;
    const Kept = struct {
        id: []const u8,
    };
    const answered = try posted(ctx, source, select_path, body);
    const kept = std.json.parseFromSliceLeaky(Kept, ctx.arena, answered, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return ctx.fail(catalog.unreachable_failure);

    return kept.id;
}

const Selected = struct {
    answered: bool = false,
    plugins: []const Pick = &.{},
    problem: []const u8 = "",
};

pub const Waiting = struct {
    asked: []const u8,
    /// The marketplace's selection.
    selection: []const u8,
    /// How many times it was asked already.
    looks: u32 = 0,
};

/// How often, and how many times, `find_wait` asks the marketplace for its picks.
const look_ms: i64 = 1500;
const looks_max: u32 = 80;

/// The `find_wait` job: the marketplace's picks for a selection, once it answered; asked
/// again a moment later while it has not.
pub fn wait_job(ctx: *Ctx, in: Waiting) Error!void {
    std.debug.assert(ctx.job.len > 0);
    std.debug.assert(in.selection.len > 0);

    const body = std.json.Stringify.valueAlloc(ctx.arena, .{
        .id = in.selection,
    }, .{}) catch return error.OutOfMemory;
    const text = posted(ctx, catalog.source(), selected_path, body) catch |err| {
        if (err == error.OutOfMemory) {
            return error.OutOfMemory;
        }

        return answer_listed(ctx, in.asked);
    };
    const found = std.json.parseFromSliceLeaky(Selected, ctx.arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return answer_listed(ctx, in.asked);

    if (!found.answered) {
        if (in.looks + 1 >= looks_max) {
            return answer_listed(ctx, in.asked);
        }

        var again = in;

        again.looks += 1;

        return jobs.enqueue_at(ctx, "find_wait", again, ctx.now_ms + look_ms);
    }

    if (found.problem.len > 0) {
        return jobs.fail(ctx, in.asked, found.problem);
    }

    return jobs.answer(ctx, in.asked, Find.Found{
        .plugins = found.plugins,
    });
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
