//! The records a query reads, as the caller may read them: `*[...]` through `record.list`
//! (types in reach, statuses by perspective, own records when the grant says so), narrowed
//! by the filter's hints (`_type`, `_id`, one field's value); `->` by id, an unreadable
//! record named as such. Each record is a document: `_id`, `_type`, `_createdAt`,
//! `_updatedAt` and its fields, without the ones the grant hides.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const records = @import("../record.zig");

const groq = @import("../../lib/groq.zig");
const Value = groq.Value;
const Ctx = sdk.Ctx;
const Grant = sdk.Grant;

/// Records a query may read in all: past this it is refused, asking for less.
pub const documents_max: u32 = 50_000;
const page_size: u32 = records.list_max;

pub const Type = struct { handle: []const u8 };

pub const Source = struct {
    ctx: *Ctx,
    granted: *const Grant,
    /// Readable types, by handle.
    types: []const Type,
    /// Types the caller may not read: a query naming one is refused.
    out_of_reach: []const []const u8,
    /// The type a refused query named.
    refused_type: []const u8 = "",
    /// The statuses read: each live one (perspective `published`), or, when null, what a list
    /// shows by default (every listed status the grant allows).
    live: ?[]const []const u8,
    /// Fields the grant hides, left out of every document.
    mask: []const []const u8,
    /// Only this user's records, when the query's grant reaches no others.
    owner: ?[]const u8 = null,
    read: u32 = 0,

    const vtable: groq.Dataset.VTable = .{
        .everything = &everything,
        .candidates = &candidates,
        .find = &find,
    };

    pub fn dataset(source: *Source) groq.Dataset {
        return .{ .context = source, .vtable = &vtable };
    }

    fn of(context: *anyopaque) *Source {
        return @ptrCast(@alignCast(context));
    }

    fn everything(context: *anyopaque, arena: std.mem.Allocator) groq.DatasetError![]const Value {
        return candidates(context, arena, &.{});
    }

    /// The readable records the hints allow: of the hinted types (or every readable one),
    /// the hinted ids, the first hinted field's value.
    fn candidates(
        context: *anyopaque,
        arena: std.mem.Allocator,
        hints: []const groq.Hint,
    ) groq.DatasetError![]const Value {
        const source = of(context);
        var documents: std.ArrayList(Value) = .empty;
        const wanted_types = hint_values(hints, "_type");

        std.debug.assert(source.types.len <= 4096);

        if (wanted_types) |types| {
            for (source.out_of_reach) |handle| {
                if (holds_string(types, handle)) {
                    source.refused_type = handle;
                    return error.OutOfReach;
                }
            }
        }

        const ids = try id_list(arena, hints);
        const field = field_hint(hints);

        for (source.types) |each| {
            if (wanted_types) |types| {
                if (!holds_string(types, each.handle)) {
                    continue;
                }
            }

            try source.read_type(arena, each, ids, field, &documents);
        }

        // Ids are time-ordered: by id is the order records were made in, across types.
        std.mem.sort(Value, documents.items, {}, by_id);

        return documents.items;
    }

    fn read_type(
        source: *Source,
        arena: std.mem.Allocator,
        each: Type,
        ids: ?[]const []const u8,
        field: ?groq.Hint,
        documents: *std.ArrayList(Value),
    ) groq.DatasetError!void {
        const filter_value = if (field) |hint| text_of(arena, hint.values[0]) catch null else null;

        const own = if (source.owner) |user_id|
            try std.fmt.allocPrint(arena, "created:by:{s}", .{user_id})
        else
            null;

        if (source.live) |statuses| {
            for (statuses) |status| {
                const clause = try std.fmt.allocPrint(arena, "status:is:{s}", .{status});
                const clauses = try clauses_of(arena, clause, own);

                try source.read_pages(arena, each, ids, field, filter_value, clauses, documents);
            }

            return;
        }

        const clauses = try clauses_of(arena, null, own);

        try source.read_pages(arena, each, ids, field, filter_value, clauses, documents);
    }

    fn read_pages(
        source: *Source,
        arena: std.mem.Allocator,
        each: Type,
        ids: ?[]const []const u8,
        field: ?groq.Hint,
        filter_value: ?[]const u8,
        clauses: []const []const u8,
        documents: *std.ArrayList(Value),
    ) groq.DatasetError!void {
        var offset: u32 = 0;

        while (true) {
            const listed = registry.SDK.dispatch(source.ctx, records.List, .{
                .type = each.handle,
                .ids = ids orelse &.{},
                .filters = clauses,
                .filter_field = if (filter_value != null) field.?.attribute else null,
                .filter_value = filter_value,
                .order = .created_desc,
                .limit = page_size,
                .offset = offset,
                .documents = true,
            }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NotFound, error.Denied, error.Invalid => return,
                else => return error.DatasetFailed,
            };

            source.read += @intCast(listed.records.len);

            if (source.read > documents_max) {
                return error.TooMuchWork;
            }

            for (listed.records, listed.documents) |record, document| {
                try documents.append(arena, try document_of(arena, record, document, source.mask));
            }

            if (listed.records.len < page_size) {
                return;
            }

            offset += page_size;
        }
    }

    fn find(
        context: *anyopaque,
        arena: std.mem.Allocator,
        id: []const u8,
    ) groq.DatasetError!groq.Found {
        const source = of(context);

        if (id.len == 0 or id.len > 64) {
            return .missing;
        }

        const ids = try arena.alloc([]const u8, 1);

        ids[0] = id;

        const stored = store.records.get(source.ctx.db, arena, id) catch return error.DatasetFailed;
        const row = stored orelse return .missing;
        const readable = type_named(source.types, row.type) orelse {
            return .{ .unreadable = "type" };
        };
        var found: std.ArrayList(Value) = .empty;

        try source.read_type(arena, readable, ids, null, &found);

        if (found.items.len == 1) {
            return .{ .document = found.items[0] };
        }

        const statuses = source.live orelse return .{ .unreadable = "owner" };
        var live = false;

        for (statuses) |status| {
            live = live or std.mem.eql(u8, status, row.status);
        }

        return .{ .unreadable = if (live) "owner" else "status" };
    }
};

fn clauses_of(
    arena: std.mem.Allocator,
    status: ?[]const u8,
    own: ?[]const u8,
) error{OutOfMemory}![]const []const u8 {
    var clauses: std.ArrayList([]const u8) = .empty;

    if (status) |clause| {
        try clauses.append(arena, clause);
    }

    if (own) |clause| {
        try clauses.append(arena, clause);
    }

    return clauses.items;
}

fn by_id(_: void, left: Value, right: Value) bool {
    std.debug.assert(left == .object and right == .object);

    const left_id = left.object.get("_id").?.string;
    const right_id = right.object.get("_id").?.string;

    return std.mem.order(u8, left_id, right_id) == .lt;
}

fn type_named(types: []const Type, handle: []const u8) ?Type {
    std.debug.assert(handle.len > 0);

    for (types) |each| {
        if (std.mem.eql(u8, each.handle, handle)) {
            return each;
        }
    }

    return null;
}

fn hint_values(hints: []const groq.Hint, attribute: []const u8) ?[]const Value {
    std.debug.assert(attribute.len > 0);

    for (hints) |hint| {
        if (std.mem.eql(u8, hint.attribute, attribute)) {
            return hint.values;
        }
    }

    return null;
}

fn holds_string(values: []const Value, wanted: []const u8) bool {
    std.debug.assert(wanted.len > 0);

    for (values) |held| {
        if (held == .string and std.mem.eql(u8, held.string, wanted)) {
            return true;
        }
    }

    return false;
}

fn id_list(
    arena: std.mem.Allocator,
    hints: []const groq.Hint,
) error{OutOfMemory}!?[]const []const u8 {
    const values = hint_values(hints, "_id") orelse return null;
    var ids: std.ArrayList([]const u8) = .empty;

    for (values) |held| {
        if (held == .string and held.string.len <= 64) {
            try ids.append(arena, held.string);
        }
    }

    if (ids.items.len == 0 or ids.items.len > records.list_max) {
        return null;
    }

    return ids.items;
}

/// The first hint on one of the record's own fields with a single value.
fn field_hint(hints: []const groq.Hint) ?groq.Hint {
    std.debug.assert(hints.len <= 64);

    for (hints) |hint| {
        const own = hint.attribute.len > 0 and hint.attribute[0] != '_';

        if (own and hint.values.len == 1) {
            return hint;
        }
    }

    return null;
}

/// A value as `filter_value` takes it: text as it is, numbers and booleans written out.
fn text_of(arena: std.mem.Allocator, value: Value) ![]const u8 {
    std.debug.assert(value != .number or std.math.isFinite(value.number));

    return switch (value) {
        .string => |text| text,
        .boolean => |truth| if (truth) "true" else "false",
        .number => |number| blk: {
            var out: std.Io.Writer.Allocating = .init(arena);

            groq.values.write_number(&out.writer, number) catch return error.OutOfMemory;

            break :blk out.written();
        },
        else => error.OutOfMemory,
    };
}

/// A record as a query sees it: its columns as `_` attributes, then its fields as stored.
fn document_of(
    arena: std.mem.Allocator,
    record: records.Record,
    text: []const u8,
    mask: []const []const u8,
) groq.DatasetError!Value {
    var builder: groq.values.ObjectBuilder = .{};
    var buffer: [40]u8 = undefined;

    try builder.put(arena, "_id", .{ .string = record.id });
    try builder.put(arena, "_type", .{ .string = record.type });
    try builder.put(arena, "_createdAt", .{
        .string = try arena.dupe(u8, groq.datetimes.format(&buffer, .{
            .seconds = @divFloor(record.created_at, 1000),
            .nanoseconds = @intCast(@mod(record.created_at, 1000) * 1_000_000),
        })),
    });
    try builder.put(arena, "_updatedAt", .{
        .string = try arena.dupe(u8, groq.datetimes.format(&buffer, .{
            .seconds = @divFloor(record.updated_at, 1000),
            .nanoseconds = @intCast(@mod(record.updated_at, 1000) * 1_000_000),
        })),
    });

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
        return error.DatasetFailed;
    };
    const converted = try groq.values.from_json(arena, parsed);

    if (converted == .object) {
        for (converted.object.keys, converted.object.values) |key, held| {
            if (!hidden(mask, key)) {
                try builder.put(arena, key, held);
            }
        }
    }

    return .{ .object = builder.object() };
}

/// Whether the grant hides a field: named itself, or a field inside it (`seo.title` hides
/// `seo`, the safe way round).
fn hidden(mask: []const []const u8, key: []const u8) bool {
    std.debug.assert(key.len > 0);

    for (mask) |path| {
        const top = path[0 .. std.mem.indexOfScalar(u8, path, '.') orelse path.len];

        if (std.mem.eql(u8, top, key)) {
            return true;
        }
    }

    return false;
}
