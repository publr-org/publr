//! Accounts as a query sees them, documents of `_type == "user"`: `_id`, `_createdAt` and
//! `name` to whoever may see names (`users.names`); also `email`, `roles` and each plugin's
//! field group on the account (`sampler: { motto }`) to whoever may read accounts
//! (`users.read`). Nobody else reads any.
const std = @import("std");
const sdk = @import("../../../sdk.zig");
const store = @import("../../../store.zig");
const registry = @import("../../../server/registry.zig");
const user_fields = @import("../../user/fields.zig");
const groq = @import("../../../lib/groq.zig");

const Value = groq.Value;
const Ctx = sdk.Ctx;

pub const handle = "user";

/// Accounts read at once.
const page_size: u32 = 100;

pub const Reach = enum { none, names, accounts };

/// What the caller may read of accounts, as `user.options` and `user.list` let them.
pub fn reach_of(ctx: *const Ctx) Reach {
    std.debug.assert(ctx.now_ms >= 0);

    if (ctx.caller == .anonymous) {
        return .none;
    }

    if (registry.SDK.may_named(ctx, "user.list")) {
        return .accounts;
    }

    return if (registry.SDK.may_named(ctx, "user.options")) .names else .none;
}

/// Every account, or those of `ids`, oldest first, up to `max`.
pub fn read(
    ctx: *Ctx,
    arena: std.mem.Allocator,
    reach: Reach,
    ids: ?[]const []const u8,
    max: u32,
    documents: *std.ArrayList(Value),
) groq.DatasetError!void {
    std.debug.assert(reach != .none);
    std.debug.assert(max > 0);

    if (ids) |wanted| {
        for (wanted) |id| {
            if (try one(ctx, arena, reach, id)) |document| {
                try documents.append(arena, document);
            }
        }

        return;
    }

    var offset: u32 = 0;

    while (offset < max) : (offset += page_size) {
        const page = store.users.page(ctx.db, arena, .{
            .offset = offset,
            .limit = page_size,
        }) catch return error.DatasetFailed;

        for (page) |user| {
            try documents.append(arena, try document_of(ctx, arena, reach, user));
        }

        if (page.len < page_size) {
            return;
        }
    }

    return error.TooMuchWork;
}

/// The account `id` as a document; null when there is none.
pub fn one(
    ctx: *Ctx,
    arena: std.mem.Allocator,
    reach: Reach,
    id: []const u8,
) groq.DatasetError!?Value {
    std.debug.assert(reach != .none);

    if (id.len == 0 or id.len > store.users.id_len) {
        return null;
    }

    const found = store.users.find_by_id(ctx.db, arena, id) catch return error.DatasetFailed;
    const credentials = found orelse return null;

    return try document_of(ctx, arena, reach, credentials.user);
}

fn document_of(
    ctx: *Ctx,
    arena: std.mem.Allocator,
    reach: Reach,
    user: store.users.User,
) groq.DatasetError!Value {
    std.debug.assert(user.id.len > 0);

    var builder: groq.values.ObjectBuilder = .{};
    var buffer: [40]u8 = undefined;

    try builder.put(arena, "_id", .{
        .string = user.id,
    });
    try builder.put(arena, "_type", .{
        .string = handle,
    });
    try builder.put(arena, "_createdAt", .{
        .string = try arena.dupe(u8, groq.datetimes.format(&buffer, .{
            .seconds = @divFloor(user.created_at, 1000),
            .nanoseconds = @intCast(@mod(user.created_at, 1000) * 1_000_000),
        })),
    });
    try builder.put(arena, "name", .{
        .string = user.display_name,
    });

    if (reach == .accounts) {
        try builder.put(arena, "email", .{
            .string = user.email,
        });
        const roles = try strings(arena, user.roles);

        try builder.put(arena, "roles", try groq.values.from_json(arena, roles));

        const defs = user_fields.definition(ctx, user.id, user.roles) catch {
            return error.DatasetFailed;
        };
        const groups = user_fields.read(ctx, user.id, defs) catch return error.DatasetFailed;
        const converted = try groq.values.from_json(arena, groups);

        if (converted == .object) {
            for (converted.object.keys, converted.object.values) |key, held| {
                try builder.put(arena, key, held);
            }
        }
    }

    return .{
        .object = builder.object(),
    };
}

fn strings(arena: std.mem.Allocator, list: []const []const u8) error{OutOfMemory}!std.json.Value {
    var array: std.json.Array = .init(arena);

    std.debug.assert(list.len <= 64);

    for (list) |each| {
        try array.append(.{
            .string = each,
        });
    }

    return .{
        .array = array,
    };
}
