const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const views = store.views;
const shared_views = store.shared_views;
const Filters = model.view.Filters;

pub const namespace: sdk.operation.Namespace = .{
    .name = "view",
    .label = "Saved views",
    .area = .background,
    .summary = "Views of the content list: saved by name, and the default each type starts at",
    .details =
    \\A view is how the content list looks: which types, filter clauses, a search, an
    \\order, the columns shown, the page size, and the fields offered to filter and order
    \\by. It travels as JSON: one clause per filter (`{"key":"status","operator":"is",
    \\"value":"draft"}`, `{"key":"field.total","operator":"more","value":"4999"}`, as
    \\`record list --filters` takes them), `order` as `title` or `-updated` (descending)
    \\or a field (`-total`). `me` and durations are resolved when the list is drawn, so a
    \\saved view stays current.
    \\
    \\Saved views are a person's own, or made for everyone by an administrator
    \\(`for_everyone`): listed for all, copied by anyone, changed by administrators. A
    \\type's default view starts from its plugin's (`.data_view`), then the one
    \\administrators saved for everyone, then the person's own (`view default`,
    \\`view save-default`, `view reset-default`). Signed-in callers only.
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
    /// Made by an administrator for everyone.
    shared: bool = false,
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
    pub const description = "List the caller's saved views and those made for everyone";
    pub const details =
        \\The caller's own views by name, then the ones made for everyone (`shared`).
        \\`query` holds the view as the content list takes it.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        views: []const Saved,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .views = &.{example_saved},
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(@sizeOf(In) == 0);

        _ = in;

        const owner = ctx.caller.user_id() orelse return error.Denied;
        const rows = try views.list_by_user(ctx.db, ctx.arena, owner);
        const shared = try shared_views.list(ctx.db, ctx.arena);
        const out = ctx.arena.alloc(Saved, rows.len + shared.len) catch {
            return error.OutOfMemory;
        };

        for (rows, out[0..rows.len]) |row, *saved| {
            saved.* = saved_of(row);
        }

        for (shared, out[rows.len..]) |row, *saved| {
            saved.* = shared_of(row);
        }

        return .{
            .views = out,
        };
    }
};

pub const Get = struct {
    pub const name = "view.get";
    pub const description = "Read one saved view";
    pub const details =
        \\Not found unless the view is the caller's own or made for everyone.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        view: Saved,
    };
    pub const example: In = .{
        .id = example_id,
    };
    pub const example_out: Out = .{
        .view = example_saved,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The view's id",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        return .{
            .view = switch (try find(ctx, in.id)) {
                .own => |row| saved_of(row),
                .shared => |row| shared_of(row),
            },
        };
    }
};

pub const Create = struct {
    pub const name = "view.create";
    pub const description = "Save the content list as a view of the caller's own, or everyone's";
    pub const details =
        \\`name` is up to 80 characters; `query` is the view as JSON, every key optional:
        \\`types` (handles), `type_view` (one type's own view), `clauses` (each a `key`,
        \\an `operator` and a `value` of a filter the registry knows: `status is draft`,
        \\`created by me`, `updated within 7d`, `created before 2026-01-01`; or on a field,
        \\`field.total more 4999`), `search`, `order` (`title`, `-updated`, `-total`),
        \\`columns`, `per_page` (10, 20, 50, 100), `filterable`, `orderable`. Up to 64 views
        \\per user. `for_everyone` makes it everyone's (up to 64): administrators only.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
        query: []const u8 = "{}",
        for_everyone: bool = false,
    };
    pub const Out = Saved;
    pub const example: In = .{
        .name = "My drafts",
        .query = example_query,
    };
    pub const example_out: Out = example_saved;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The view's name, as the sidebar shows it",
        .query = "The view, as JSON",
        .for_everyone = "Made for everyone (administrators only)",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.name.len > 64 << 10) {
            return error.Invalid;
        }

        const owner = ctx.caller.user_id() orelse return error.Denied;
        const clean_name = try check_name(in.name);
        const query = try check_query(ctx, in.query);

        if (in.for_everyone) {
            return create_shared(ctx, owner, clean_name, query);
        }

        if (try views.count_by_user(ctx.db, owner) >= per_user_max) {
            return error.Invalid;
        }

        const now_ms = ctx.now_ms;
        const id = try views.insert(ctx.db, ctx.io, ctx.arena, owner, clean_name, query, now_ms);
        const row = try views.get(ctx.db, ctx.arena, id) orelse return error.NotFound;

        return saved_of(row);
    }
};

pub const Update = struct {
    pub const name = "view.update";
    pub const description = "Rename a saved view, or give it a new view, or both";
    pub const details =
        \\Fields left out keep their value. The caller's own views, and (administrators)
        \\the ones made for everyone.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
        name: ?[]const u8 = null,
        query: ?[]const u8 = null,
    };
    pub const Out = Saved;
    pub const example: In = .{
        .id = example_id,
        .name = "My drafts",
    };
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

        const found = try find_changing(ctx, in.id);

        switch (found) {
            .own => |row| {
                const clean_name = if (in.name) |text| try check_name(text) else row.name;
                const query = if (in.query) |text| try check_query(ctx, text) else row.query;

                try views.update(ctx.db, row.id, clean_name, query, ctx.now_ms);
            },
            .shared => |row| {
                const clean_name = if (in.name) |text| try check_name(text) else row.name;
                const query = if (in.query) |text| try check_query(ctx, text) else row.query;

                try shared_views.update(ctx.db, row.id, clean_name, query, ctx.now_ms);
            },
        }

        return switch (try find(ctx, in.id)) {
            .own => |row| saved_of(row),
            .shared => |row| shared_of(row),
        };
    }
};

pub const Delete = struct {
    pub const name = "view.delete";
    pub const description = "Delete a saved view";
    pub const details =
        \\The caller's own views, and (administrators) the ones made for everyone. Nothing
        \\else is touched: a view is only a way of looking at the content.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        id: []const u8,
    };
    pub const Out = struct {
        deleted: bool,
    };
    pub const example: In = .{
        .id = example_id,
    };
    pub const example_out: Out = .{
        .deleted = true,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The view's id",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        const deleted = switch (try find_changing(ctx, in.id)) {
            .own => |row| try views.delete(ctx.db, row.id),
            .shared => |row| try shared_views.delete(ctx.db, row.id),
        };

        return .{
            .deleted = deleted,
        };
    }
};

pub const operations = [_]type{ List, Get, Create, Update, Delete } ++
    @import("view_default.zig").operations;

const Found = union(enum) {
    own: views.View,
    shared: shared_views.View,
};

/// The caller's own view or one made for everyone, or `NotFound`: another user's view does
/// not exist to them.
fn find(ctx: *Ctx, id: []const u8) Error!Found {
    std.debug.assert(ctx.now_ms >= 0);

    if (id.len == 0 or id.len > 128) {
        return error.NotFound;
    }

    const owner = ctx.caller.user_id() orelse return error.Denied;

    if (try views.get(ctx.db, ctx.arena, id)) |row| {
        if (std.mem.eql(u8, row.user_id, owner)) {
            return .{
                .own = row,
            };
        }

        return error.NotFound;
    }

    const shared = try shared_views.get(ctx.db, ctx.arena, id) orelse return error.NotFound;

    return .{
        .shared = shared,
    };
}

/// A view the caller may change: their own, or one made for everyone when they administer.
fn find_changing(ctx: *Ctx, id: []const u8) Error!Found {
    const found = try find(ctx, id);

    std.debug.assert(id.len > 0);

    if (found == .shared and !ctx.caller.holds("admin")) {
        return error.Denied;
    }

    return found;
}

fn create_shared(
    ctx: *Ctx,
    owner: []const u8,
    clean_name: []const u8,
    query: []const u8,
) Error!Saved {
    std.debug.assert(owner.len > 0);
    std.debug.assert(clean_name.len > 0);

    if (!ctx.caller.holds("admin")) {
        return error.Denied;
    }

    if (try shared_views.count(ctx.db) >= shared_views.count_max) {
        return error.Invalid;
    }

    const id = try shared_views.insert(
        ctx.db,
        ctx.io,
        ctx.arena,
        clean_name,
        query,
        owner,
        ctx.now_ms,
    );
    const row = try shared_views.get(ctx.db, ctx.arena, id) orelse return error.NotFound;

    return shared_of(row);
}

fn check_name(text: []const u8) Error![]const u8 {
    std.debug.assert(name_len_max > 0);

    const trimmed = std.mem.trim(u8, text, " \r\n\t");

    if (trimmed.len == 0 or trimmed.len > name_len_max) {
        return error.Invalid;
    }

    return trimmed;
}

/// The view, checked and written back in one shape: every clause names a filter the
/// registry knows, one of its operators, and a value that operator takes; a clause on a
/// field (`field.total`) is checked by the list that reads it, against the type.
pub fn check_query(ctx: *Ctx, text: []const u8) Error![]const u8 {
    std.debug.assert(query_bytes_max > 0);

    const filters = model.view.decode(ctx.arena, text) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid => error.Invalid,
    };

    for (filters.clauses, 0..) |clause, index| {
        if (model.field_filter.field_of(clause.key) != null) {
            continue;
        }

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

fn shared_of(row: shared_views.View) Saved {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(row.name.len > 0);

    return .{
        .id = row.id,
        .name = row.name,
        .query = row.query,
        .created_at = row.created_at,
        .updated_at = row.updated_at,
        .shared = true,
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

    var admin = harness.ctx(.{
        .user = .{
            .id = "u_admin",
            .roles = &.{"admin"},
        },
    });
    const users = @import("user.zig");
    const ada_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "ada@example.com",
        .display_name = "Ada",
    });
    const bob_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "bob@example.com",
        .display_name = "Bob",
    });
    var ada = harness.ctx(.{
        .user = .{
            .id = ada_account.user_id,
            .roles = &.{"editor"},
        },
    });
    var bob = harness.ctx(.{
        .user = .{
            .id = bob_account.user_id,
            .roles = &.{"editor"},
        },
    });
    var anon = harness.ctx(.anonymous);

    const drafts_query = "{\"clauses\":[" ++
        "{\"key\":\"status\",\"operator\":\"is\",\"value\":\"draft\"}]}";
    const created = try SDK.dispatch(&ada, Create, .{
        .name = "  Drafts ",
        .query = drafts_query,
    });
    try std.testing.expectEqualStrings("Drafts", created.name);
    try std.testing.expect(std.mem.indexOf(u8, created.query, "\"value\":\"draft\"") != null);
    _ = try SDK.dispatch(&ada, Create, .{
        .name = "All",
        .query = "{}",
    });
    const mine_query = "{\"clauses\":[" ++
        "{\"key\":\"created\",\"operator\":\"by\",\"value\":\"me\"}]}";
    _ = try SDK.dispatch(&bob, Create, .{
        .name = "Bob's",
        .query = mine_query,
    });

    const mine = try SDK.dispatch(&ada, List, .{});
    try std.testing.expectEqual(@as(usize, 2), mine.views.len);
    try std.testing.expectEqualStrings("All", mine.views[0].name);
    try std.testing.expectEqual(@as(usize, 1), (try SDK.dispatch(&bob, List, .{})).views.len);
    try std.testing.expectError(error.Denied, SDK.dispatch(&anon, List, .{}));
    try std.testing.expectError(error.Denied, SDK.dispatch(&anon, Create, Create.example));

    const got = try SDK.dispatch(&ada, Get, .{
        .id = created.id,
    });
    try std.testing.expectEqualStrings("Drafts", got.view.name);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&bob, Get, .{
        .id = created.id,
    }));
    try std.testing.expectError(error.NotFound, SDK.dispatch(&ada, Get, .{
        .id = "nope",
    }));

    const renamed = try SDK.dispatch(&ada, Update, .{
        .id = created.id,
        .name = "My drafts",
    });
    try std.testing.expectEqualStrings("My drafts", renamed.name);
    try std.testing.expectEqualStrings(created.query, renamed.query);
    const refiltered = try SDK.dispatch(&ada, Update, .{
        .id = created.id,
        .query = "{\"order\":\"title\"}",
    });
    try std.testing.expectEqualStrings("My drafts", refiltered.name);
    try std.testing.expect(std.mem.indexOf(u8, refiltered.query, "\"title\"") != null);
    try std.testing.expectError(
        error.NotFound,
        SDK.dispatch(&bob, Update, .{
            .id = created.id,
            .name = "Stolen",
        }),
    );
    try std.testing.expectError(
        error.Invalid,
        SDK.dispatch(&ada, Update, .{
            .id = created.id,
            .query = "{\"order\":\"no pe\"}",
        }),
    );
    try std.testing.expectError(error.Invalid, SDK.dispatch(&ada, Create, .{
        .name = "",
    }));
    try std.testing.expectError(
        error.Invalid,
        SDK.dispatch(&ada, Create, .{
            .name = "Bad",
            .query = "not json",
        }),
    );
    const unknown = "{\"clauses\":[{\"key\":\"nope\",\"operator\":\"is\"}]}";
    try std.testing.expectError(
        error.Invalid,
        SDK.dispatch(&ada, Create, .{
            .name = "Bad",
            .query = unknown,
        }),
    );
    const wrong_operator = "{\"clauses\":[{\"key\":\"status\",\"operator\":\"within\"}]}";
    try std.testing.expectError(
        error.Invalid,
        SDK.dispatch(&ada, Create, .{
            .name = "Bad",
            .query = wrong_operator,
        }),
    );

    try std.testing.expectError(error.NotFound, SDK.dispatch(&bob, Delete, .{
        .id = created.id,
    }));
    try std.testing.expect((try SDK.dispatch(&ada, Delete, .{
        .id = created.id,
    })).deleted);
    try std.testing.expectError(error.NotFound, SDK.dispatch(&ada, Get, .{
        .id = created.id,
    }));
    try std.testing.expectEqual(@as(usize, 1), (try SDK.dispatch(&ada, List, .{})).views.len);

    const everyone_in: Create.In = .{
        .name = "Unpaid",
        .query = "{\"order\":\"-total\"}",
        .for_everyone = true,
    };
    try std.testing.expectError(error.Denied, SDK.dispatch(&ada, Create, everyone_in));

    const admin_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "root@example.com",
        .display_name = "Root",
    });
    var root = harness.ctx(.{
        .user = .{
            .id = admin_account.user_id,
            .roles = &.{"admin"},
        },
    });
    const everyone = try SDK.dispatch(&root, Create, everyone_in);
    try std.testing.expect(everyone.shared);

    const listed = try SDK.dispatch(&bob, List, .{});
    try std.testing.expectEqual(@as(usize, 2), listed.views.len);
    try std.testing.expect(listed.views[1].shared);
    try std.testing.expectEqualStrings("Unpaid", (try SDK.dispatch(&bob, Get, .{
        .id = everyone.id,
    })).view.name);
    try std.testing.expectError(error.Denied, SDK.dispatch(&bob, Update, .{
        .id = everyone.id,
        .name = "Mine now",
    }));
    try std.testing.expectError(error.Denied, SDK.dispatch(&bob, Delete, .{
        .id = everyone.id,
    }));
    try std.testing.expectEqualStrings("Unpaid orders", (try SDK.dispatch(&root, Update, .{
        .id = everyone.id,
        .name = "Unpaid orders",
    })).name);
    try std.testing.expect((try SDK.dispatch(&root, Delete, .{
        .id = everyone.id,
    })).deleted);
}
