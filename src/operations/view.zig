const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const views = store.views;
const Filters = model.view.Filters;

pub const namespace: sdk.operation.Namespace = .{
    .name = "view",
    .summary = "Saved views: the content list's filters, named and kept per user",
    .details =
    \\A view is a name over a set of filters for the content list: which types, which
    \\status, whose records, since when, a search, an order. Views are private: each
    \\belongs to the user who saved it, and nobody else sees or changes it. The filters
    \\travel as JSON: the types, one clause per filter (`{"key":"status","operator":"is",
    \\"value":"draft"}`, as `record list --filters` takes them), a search, an order.
    \\`me` and durations are resolved when the list is drawn, so a saved view stays
    \\current. Signed-in callers only.
    ,
};

pub const name_len_max = model.view.name_len_max;
pub const query_bytes_max = model.view.query_bytes_max;
pub const per_user_max = views.per_user_max;

/// One saved view, as every operation answers it.
pub const Saved = struct {
    id: []const u8,
    name: []const u8,
    query: []const u8,
    created_at: i64,
    updated_at: i64,
};

pub const example_id = "5e6f7a8b9c0d1e2f3a4b5c6d";
const example_query = "{\"clauses\":[" ++
    "{\"key\":\"status\",\"operator\":\"is\",\"value\":\"draft\"}," ++
    "{\"key\":\"created\",\"operator\":\"by\",\"value\":\"me\"}]}";
const example_saved: Saved = .{
    .id = example_id,
    .name = "My drafts",
    .query = example_query,
    .created_at = 1789650000000,
    .updated_at = 1789653600000,
};

pub const List = struct {
    pub const name = "view.list";
    pub const description = "List the caller's saved views, by name";
    pub const details =
        \\Only the caller's own views: a view is never shared. `query` holds the filters as
        \\the content list takes them.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { views: []const Saved };
    pub const example: In = .{};
    pub const example_out: Out = .{ .views = &.{example_saved} };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(@sizeOf(In) == 0);

        _ = in;

        const owner = ctx.caller.user_id() orelse return error.Denied;
        const rows = try views.list_by_user(ctx.db, ctx.arena, owner);
        const out = ctx.arena.alloc(Saved, rows.len) catch return error.OutOfMemory;

        for (rows, out) |row, *saved| {
            saved.* = saved_of(row);
        }

        return .{ .views = out };
    }
};

pub const Get = struct {
    pub const name = "view.get";
    pub const description = "Read one saved view";
    pub const details =
        \\Not found unless the view is the caller's own.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { id: []const u8 };
    pub const Out = struct { view: Saved };
    pub const example: In = .{ .id = example_id };
    pub const example_out: Out = .{ .view = example_saved };
    pub const field_docs: sdk.operation.Docs(In) = .{ .id = "The view's id" };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        const row = try own(ctx, in.id);

        return .{ .view = saved_of(row) };
    }
};

pub const Create = struct {
    pub const name = "view.create";
    pub const description = "Save the content list's filters as a view of the caller's own";
    pub const details =
        \\`name` is up to 80 characters; `query` is the filters as JSON, every key optional:
        \\`types` (handles), `type_view` (one type's own view), `clauses` (each a `key`,
        \\an `operator` and a `value` of a filter the registry knows: `status is draft`,
        \\`created by me`, `updated within 7d`, `created before 2026-01-01`), `search`,
        \\`order` (`updated_desc`, `created_desc`, `title_asc`). Up to 64 views per user.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { name: []const u8, query: []const u8 = "{}" };
    pub const Out = Saved;
    pub const example: In = .{ .name = "My drafts", .query = example_query };
    pub const example_out: Out = example_saved;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The view's name, as the sidebar shows it",
        .query = "The filters, as JSON",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.name.len > 64 << 10) {
            return error.Invalid;
        }

        const owner = ctx.caller.user_id() orelse return error.Denied;
        const clean_name = try check_name(in.name);
        const query = try check_query(ctx, in.query);

        if (try views.count_by_user(ctx.db, owner) >= per_user_max) {
            return error.Invalid;
        }

        const now_ms = ctx.now_ms;
        const id = try views.insert(ctx.db, ctx.io, ctx.arena, owner, clean_name, query, now_ms);
        const row = try views.get(ctx.db, ctx.arena, id) orelse return error.NotFound;

        ctx.notice("view.created", id);

        return saved_of(row);
    }
};

pub const Update = struct {
    pub const name = "view.update";
    pub const description = "Rename a saved view, or give it new filters, or both";
    pub const details =
        \\Fields left out keep their value. The caller's own views only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8, name: ?[]const u8 = null, query: ?[]const u8 = null };
    pub const Out = Saved;
    pub const example: In = .{ .id = example_id, .name = "My drafts" };
    pub const example_out: Out = example_saved;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The view's id",
        .name = "A new name",
        .query = "New filters, as JSON",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        const row = try own(ctx, in.id);
        const clean_name = if (in.name) |text| try check_name(text) else row.name;
        const query = if (in.query) |text| try check_query(ctx, text) else row.query;

        try views.update(ctx.db, row.id, clean_name, query, ctx.now_ms);

        const updated = try views.get(ctx.db, ctx.arena, row.id) orelse return error.NotFound;

        ctx.notice("view.updated", row.id);

        return saved_of(updated);
    }
};

pub const Delete = struct {
    pub const name = "view.delete";
    pub const description = "Delete a saved view";
    pub const details =
        \\The caller's own views only. Nothing else is touched: a view is only a way of
        \\looking at the content.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8 };
    pub const Out = struct { deleted: bool };
    pub const example: In = .{ .id = example_id };
    pub const example_out: Out = .{ .deleted = true };
    pub const field_docs: sdk.operation.Docs(In) = .{ .id = "The view's id" };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        const row = try own(ctx, in.id);
        const deleted = try views.delete(ctx.db, row.id);

        ctx.notice("view.deleted", row.id);

        return .{ .deleted = deleted };
    }
};

pub const operations = [_]type{ List, Get, Create, Update, Delete };

/// The caller's own view, or `NotFound`: another user's view does not exist to them.
fn own(ctx: *Ctx, id: []const u8) Error!views.View {
    std.debug.assert(ctx.now_ms >= 0);

    if (id.len == 0 or id.len > 128) {
        return error.NotFound;
    }

    const owner = ctx.caller.user_id() orelse return error.Denied;
    const row = try views.get(ctx.db, ctx.arena, id) orelse return error.NotFound;

    if (!std.mem.eql(u8, row.user_id, owner)) {
        return error.NotFound;
    }

    return row;
}

fn check_name(text: []const u8) Error![]const u8 {
    std.debug.assert(name_len_max > 0);

    const trimmed = std.mem.trim(u8, text, " \r\n\t");

    if (trimmed.len == 0 or trimmed.len > name_len_max) {
        return error.Invalid;
    }

    return trimmed;
}

/// The filters, checked and written back in one shape: every clause names a filter the
/// registry knows, one of its operators, and a value that operator takes.
fn check_query(ctx: *Ctx, text: []const u8) Error![]const u8 {
    std.debug.assert(query_bytes_max > 0);

    const filters = model.view.decode(ctx.arena, text) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid => error.Invalid,
    };

    for (filters.clauses, 0..) |clause, index| {
        const def = registry.Filters.find(clause.key) orelse return error.Invalid;
        const operator = def.operator(clause.operator) orelse return error.Invalid;

        if (!model.filter.fits(operator, clause.value)) {
            return error.Invalid;
        }

        for (filters.clauses[index + 1 ..]) |other| {
            if (registry.Filters.clash(clause, other)) {
                return error.Invalid;
            }
        }
    }

    return model.view.encode(ctx.arena, filters) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid => error.Invalid,
    };
}

fn saved_of(row: views.View) Saved {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(row.name.len > 0);

    return .{
        .id = row.id,
        .name = row.name,
        .query = row.query,
        .created_at = row.created_at,
        .updated_at = row.updated_at,
    };
}

const SDK = registry.SDK;

test "views are private: create, list, get, update, delete, all owner-bound" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try SDK.bootstrap(&system);

    var admin = harness.ctx(.{ .user = .{ .id = "u_admin", .roles = &.{"admin"} } });
    const users = @import("user.zig");
    const ada_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "ada@example.com",
        .display_name = "Ada",
    });
    const bob_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "bob@example.com",
        .display_name = "Bob",
    });
    var ada = harness.ctx(.{ .user = .{ .id = ada_account.user_id, .roles = &.{"editor"} } });
    var bob = harness.ctx(.{ .user = .{ .id = bob_account.user_id, .roles = &.{"editor"} } });
    var anon = harness.ctx(.anonymous);

    const drafts_query = "{\"clauses\":[" ++
        "{\"key\":\"status\",\"operator\":\"is\",\"value\":\"draft\"}]}";
    const created = try SDK.dispatch(&ada, Create, .{ .name = "  Drafts ", .query = drafts_query });
    try std.testing.expectEqualStrings("Drafts", created.name);
    try std.testing.expect(std.mem.indexOf(u8, created.query, "\"value\":\"draft\"") != null);
    _ = try SDK.dispatch(&ada, Create, .{ .name = "All", .query = "{}" });
    const mine_query = "{\"clauses\":[" ++
        "{\"key\":\"created\",\"operator\":\"by\",\"value\":\"me\"}]}";
    _ = try SDK.dispatch(&bob, Create, .{ .name = "Bob's", .query = mine_query });

    const mine = try SDK.dispatch(&ada, List, .{});
    try std.testing.expectEqual(@as(usize, 2), mine.views.len);
    try std.testing.expectEqualStrings("All", mine.views[0].name);
    try std.testing.expectEqual(@as(usize, 1), (try SDK.dispatch(&bob, List, .{})).views.len);
    try std.testing.expectError(error.Denied, SDK.dispatch(&anon, List, .{}));
    try std.testing.expectError(error.Denied, SDK.dispatch(&anon, Create, Create.example));

    const got = try SDK.dispatch(&ada, Get, .{ .id = created.id });
    try std.testing.expectEqualStrings("Drafts", got.view.name);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&bob, Get, .{ .id = created.id }));
    try std.testing.expectError(error.NotFound, SDK.dispatch(&ada, Get, .{ .id = "nope" }));

    const renamed = try SDK.dispatch(&ada, Update, .{ .id = created.id, .name = "My drafts" });
    try std.testing.expectEqualStrings("My drafts", renamed.name);
    try std.testing.expectEqualStrings(created.query, renamed.query);
    const refiltered = try SDK.dispatch(&ada, Update, .{
        .id = created.id,
        .query = "{\"order\":\"title_asc\"}",
    });
    try std.testing.expectEqualStrings("My drafts", refiltered.name);
    try std.testing.expect(std.mem.indexOf(u8, refiltered.query, "title_asc") != null);
    try std.testing.expectError(
        error.NotFound,
        SDK.dispatch(&bob, Update, .{ .id = created.id, .name = "Stolen" }),
    );
    try std.testing.expectError(
        error.Invalid,
        SDK.dispatch(&ada, Update, .{ .id = created.id, .query = "{\"order\":\"nope\"}" }),
    );
    try std.testing.expectError(error.Invalid, SDK.dispatch(&ada, Create, .{ .name = "" }));
    try std.testing.expectError(
        error.Invalid,
        SDK.dispatch(&ada, Create, .{ .name = "Bad", .query = "not json" }),
    );
    const unknown = "{\"clauses\":[{\"key\":\"nope\",\"operator\":\"is\"}]}";
    try std.testing.expectError(
        error.Invalid,
        SDK.dispatch(&ada, Create, .{ .name = "Bad", .query = unknown }),
    );
    const wrong_operator = "{\"clauses\":[{\"key\":\"status\",\"operator\":\"within\"}]}";
    try std.testing.expectError(
        error.Invalid,
        SDK.dispatch(&ada, Create, .{ .name = "Bad", .query = wrong_operator }),
    );

    try std.testing.expectError(error.NotFound, SDK.dispatch(&bob, Delete, .{ .id = created.id }));
    try std.testing.expect((try SDK.dispatch(&ada, Delete, .{ .id = created.id })).deleted);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&ada, Get, .{ .id = created.id }));
    try std.testing.expectEqual(@as(usize, 1), (try SDK.dispatch(&ada, List, .{})).views.len);
}
