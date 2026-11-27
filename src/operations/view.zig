const std = @import("std");
const sdk = @import("../sdk.zig");
const public = @import("../publr/operations/view.zig");
const registry = @import("../server/registry.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const views = store.views;
const shared_views = store.shared_views;
const Filters = model.view.Filters;

pub const namespace = public.namespace;

pub const name_len_max = model.view.name_len_max;
pub const query_bytes_max = model.view.query_bytes_max;
pub const per_user_max = views.per_user_max;

pub const Saved = public.Saved;

pub const List = struct {
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;

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
    pub const shape = public.Get;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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
    pub const shape = public.Create;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.name.len > 64 << 10) {
            return error.Invalid;
        }

        const owner = ctx.caller.user_id() orelse return error.Denied;
        const clean_name = try check_name(in.name);
        const query = try check_query(ctx, in.query.text);

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
    pub const shape = public.Update;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.id.len > 64 << 10) {
            return error.Invalid;
        }

        const found = try find_changing(ctx, in.id);

        switch (found) {
            .own => |row| {
                const clean_name = if (in.name) |text| try check_name(text) else row.name;
                const query = if (in.query) |text| try check_query(ctx, text.text) else row.query;

                try views.update(ctx.db, row.id, clean_name, query, ctx.now_ms);
            },
            .shared => |row| {
                const clean_name = if (in.name) |text| try check_name(text) else row.name;
                const query = if (in.query) |text| try check_query(ctx, text.text) else row.query;

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
    pub const shape = public.Delete;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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
        .query = .{
            .text = row.query,
        },
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
        .query = .{
            .text = row.query,
        },
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
        .roles = &.{"editor"},
    });
    const bob_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "bob@example.com",
        .display_name = "Bob",
        .roles = &.{"editor"},
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
        .query = .{
            .text = drafts_query,
        },
    });
    try std.testing.expectEqualStrings("Drafts", created.name);
    try std.testing.expect(std.mem.indexOf(u8, created.query.text, "\"value\":\"draft\"") != null);
    _ = try SDK.dispatch(&ada, Create, .{
        .name = "All",
        .query = .{
            .text = "{}",
        },
    });
    const mine_query = "{\"clauses\":[" ++
        "{\"key\":\"created\",\"operator\":\"by\",\"value\":\"me\"}]}";
    _ = try SDK.dispatch(&bob, Create, .{
        .name = "Bob's",
        .query = .{
            .text = mine_query,
        },
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
    try std.testing.expectEqualStrings(created.query.text, renamed.query.text);
    const refiltered = try SDK.dispatch(&ada, Update, .{
        .id = created.id,
        .query = .{
            .text = "{\"order\":\"title\"}",
        },
    });
    try std.testing.expectEqualStrings("My drafts", refiltered.name);
    try std.testing.expect(std.mem.indexOf(u8, refiltered.query.text, "\"title\"") != null);
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
            .query = .{
                .text = "{\"order\":\"no pe\"}",
            },
        }),
    );
    try std.testing.expectError(error.Invalid, SDK.dispatch(&ada, Create, .{
        .name = "",
    }));
    try std.testing.expectError(
        error.Invalid,
        SDK.dispatch(&ada, Create, .{
            .name = "Bad",
            .query = .{
                .text = "not json",
            },
        }),
    );
    const unknown = "{\"clauses\":[{\"key\":\"nope\",\"operator\":\"is\"}]}";
    try std.testing.expectError(
        error.Invalid,
        SDK.dispatch(&ada, Create, .{
            .name = "Bad",
            .query = .{
                .text = unknown,
            },
        }),
    );
    const wrong_operator = "{\"clauses\":[{\"key\":\"status\",\"operator\":\"within\"}]}";
    try std.testing.expectError(
        error.Invalid,
        SDK.dispatch(&ada, Create, .{
            .name = "Bad",
            .query = .{
                .text = wrong_operator,
            },
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
        .query = .{
            .text = "{\"order\":\"-total\"}",
        },
        .for_everyone = true,
    };
    try std.testing.expectError(error.Denied, SDK.dispatch(&ada, Create, everyone_in));

    const admin_account = try SDK.dispatch(&admin, users.Create, .{
        .email = "root@example.com",
        .display_name = "Root",
        .roles = &.{"editor"},
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
