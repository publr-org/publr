//! The records a query reads, as the caller may read them: `*[...]` through `record.list`
//! (types in reach, statuses by perspective, own records when the grant says so), narrowed
//! by the filter's hints (`_type`, `_id`, one field's value); `->` by id, an unreadable
//! record named as such. Each record is a document: `_id`, `_type`, `_createdAt`,
//! `_updatedAt` and its fields, without the ones the grant hides. Accounts are documents of
//! `_type == "user"` (`query_dataset/users.zig`).

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const records = @import("../record.zig");
const hinted = @import("query_dataset/hints.zig");
const documents_module = @import("query_dataset/documents.zig");
const users = @import("query_dataset/users.zig");

const groq = @import("../../lib/groq.zig");
const Value = groq.Value;
const Ctx = sdk.Ctx;
const Grant = sdk.Grant;

/// Records a query may read in all: past this it is refused, asking for less.
pub const documents_max: u32 = 50_000;
/// Records read at once, in the request's scratch: a page with its working copies stays
/// well inside it, and only what the filter keeps is copied out.
const page_size: u32 = 20;

pub const Type = struct {
    handle: []const u8,
    /// Its records read live only, whatever the rest of the query reads.
    live_only: bool = false,
};

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
    /// The live statuses a type read live only (`Type.live_only`) keeps to.
    live_statuses: []const []const u8 = &.{},
    /// Fields the grant hides, left out of every document.
    mask: []const []const u8,
    /// Only this user's records, when the query's grant reaches no others.
    owner: ?[]const u8 = null,
    /// Records in the trash too; every other read leaves them out.
    trashed: bool = false,
    /// What the caller may read of accounts, documents of `_type == "user"`.
    users: users.Reach = .none,
    read: u32 = 0,

    const vtable: groq.Dataset.VTable = .{
        .everything = &everything,
        .candidates = &candidates,
        .find = &find,
    };

    pub fn dataset(source: *Source) groq.Dataset {
        return .{
            .context = source,
            .vtable = &vtable,
        };
    }

    fn of(context: *anyopaque) *Source {
        return @ptrCast(@alignCast(context));
    }

    fn everything(context: *anyopaque, arena: std.mem.Allocator) groq.DatasetError![]const Value {
        return candidates(context, arena, &.{}, null);
    }

    /// The readable records the hints allow that `keep` keeps: of the hinted types (or
    /// every readable one), the hinted ids, the first hinted field's value.
    fn candidates(
        context: *anyopaque,
        arena: std.mem.Allocator,
        hints: []const groq.Hint,
        keep: ?groq.Keep,
    ) groq.DatasetError![]const Value {
        const source = of(context);
        var documents: std.ArrayList(Value) = .empty;
        const wanted_types = hinted.hint_values(hints, "_type");

        std.debug.assert(source.types.len <= 4096);

        if (wanted_types) |types| {
            for (source.out_of_reach) |handle| {
                if (hinted.holds_string(types, handle)) {
                    source.refused_type = handle;
                    return error.OutOfReach;
                }
            }

            if (source.users == .none and hinted.holds_string(types, users.handle)) {
                source.refused_type = users.handle;
                return error.OutOfReach;
            }
        }

        const ids = try hinted.id_list(arena, hints);
        const field = hinted.field_hint(hints);
        const wants_users = if (wanted_types) |types|
            hinted.holds_string(types, users.handle)
        else
            true;

        if (source.users != .none and wants_users) {
            try users.read(source.ctx, arena, source.users, ids, documents_max, &documents);
        }

        for (source.types) |each| {
            if (wanted_types) |types| {
                if (!hinted.holds_string(types, each.handle)) {
                    continue;
                }
            }

            try source.read_type(arena, .{
                .type = each,
                .ids = ids,
                .field = field,
                .keep = keep,
            }, &documents);
        }

        // Ids are time-ordered: by id is the order records were made in, across types.
        std.mem.sort(Value, documents.items, {}, documents_module.by_id);

        return documents.items;
    }

    /// The statuses a type's records are read in: the live ones when the query or the type
    /// reads live only; null for what a list shows.
    fn statuses_of(source: *const Source, readable: Type) ?[]const []const u8 {
        std.debug.assert(readable.handle.len > 0);
        std.debug.assert(source.live_statuses.len <= 64);

        if (source.live) |statuses| {
            return statuses;
        }

        return if (readable.live_only) source.live_statuses else null;
    }

    fn read_type(
        source: *Source,
        arena: std.mem.Allocator,
        read: Read,
        documents: *std.ArrayList(Value),
    ) groq.DatasetError!void {
        const filter_value = if (read.field) |hint|
            hinted.text_of(arena, hint.values[0]) catch null
        else
            null;

        const own = if (source.owner) |user_id|
            try std.fmt.allocPrint(arena, "created:by:{s}", .{user_id})
        else
            null;

        if (source.statuses_of(read.type)) |statuses| {
            for (statuses) |status| {
                const clause = try std.fmt.allocPrint(arena, "status:is:{s}", .{status});
                const clauses = try clauses_of(arena, clause, own);

                try source.read_pages(arena, read, .{
                    .value = filter_value,
                    .clauses = clauses,
                }, documents);
            }

            return;
        }

        const clauses = try clauses_of(arena, null, own);

        try source.read_pages(arena, read, .{
            .value = filter_value,
            .clauses = clauses,
        }, documents);

        if (source.trashed) {
            const in_trash = try clauses_of(arena, "status:is:trashed", own);

            try source.read_pages(arena, read, .{
                .value = filter_value,
                .clauses = in_trash,
            }, documents);
        }
    }

    /// A type's records a page at a time, each page in the request's scratch: its documents
    /// are built there, the ones `keep` keeps copied into `arena`, and the page given back.
    /// A page that does not fit (records with many virtual children) is read again with
    /// half as many records, down to one.
    fn read_pages(
        source: *Source,
        arena: std.mem.Allocator,
        read: Read,
        filter: Filter,
        documents: *std.ArrayList(Value),
    ) groq.DatasetError!void {
        std.debug.assert(read.type.handle.len > 0);
        std.debug.assert(filter.value == null or read.field != null);

        var offset: u32 = 0;
        var size: u32 = page_size;

        while (source.read <= documents_max) {
            const before = documents.items.len;
            const count = source.read_page(arena, read, filter, .{
                .offset = offset,
                .size = size,
            }, documents) catch |err| switch (err) {
                error.OutOfMemory => {
                    if (size == 1) {
                        return error.OutOfMemory;
                    }

                    documents.shrinkRetainingCapacity(before);
                    size /= 2;
                    continue;
                },
                else => |other| return other,
            };

            source.read += count;

            if (source.read > documents_max) {
                return error.TooMuchWork;
            }

            if (count < size) {
                return;
            }

            offset += size;
        }

        return error.TooMuchWork;
    }

    /// One page: how many records it read.
    fn read_page(
        source: *Source,
        arena: std.mem.Allocator,
        read: Read,
        filter: Filter,
        window: Window,
        documents: *std.ArrayList(Value),
    ) groq.DatasetError!u32 {
        std.debug.assert(window.size > 0 and window.size <= page_size);

        const scratch = try source.ctx.scratch();
        const begun = scratch.mark();
        defer scratch.rewind(begun);

        const page = scratch.allocator();
        var paged = source.ctx.*;

        paged.arena = page;
        defer source.ctx.next_operation_id = paged.next_operation_id;

        const listed = registry.SDK.dispatch(&paged, records.List, .{
            .type = read.type.handle,
            .ids = read.ids orelse &.{},
            .filters = filter.clauses,
            .filter_field = if (filter.value != null) read.field.?.attribute else null,
            .filter_value = filter.value,
            .order = .created_desc,
            .limit = window.size,
            .offset = window.offset,
            .documents = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotFound, error.Denied, error.Invalid => return 0,
            else => return error.DatasetFailed,
        };

        std.debug.assert(listed.records.len <= window.size);

        for (listed.records, listed.documents) |record, text| {
            const document = try documents_module.document_of(page, record, text, source.mask);
            const kept = if (read.keep) |keep| try keep.of(document) else true;

            if (kept) {
                try documents.append(arena, try groq.values.copy(arena, document));
            }
        }

        return @intCast(listed.records.len);
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

        if (source.users != .none) {
            if (try users.one(source.ctx, arena, source.users, id)) |account| {
                return .{
                    .document = account,
                };
            }
        }

        const ids = try arena.alloc([]const u8, 1);

        ids[0] = id;

        const stored = store.records.get(source.ctx.db, arena, id) catch return error.DatasetFailed;

        if (stored == null) {
            return restricted(source, arena, id, .missing);
        }

        const row = stored.?;
        const readable = type_named(source.types, row.type) orelse {
            return restricted(source, arena, id, .{
                .unreadable = "type",
            });
        };
        var found: std.ArrayList(Value) = .empty;

        try source.read_type(arena, .{
            .type = readable,
            .ids = ids,
        }, &found);

        if (found.items.len == 1) {
            return .{
                .document = found.items[0],
            };
        }

        const read_in = source.statuses_of(readable);
        const statuses = read_in orelse return restricted(source, arena, id, .{
            .unreadable = "owner",
        });
        var live = false;

        for (statuses) |status| {
            live = live or std.mem.eql(u8, status, row.status);
        }

        return restricted(source, arena, id, .{
            .unreadable = if (live) "owner" else "status",
        });
    }

    /// A reference the reader may not follow: what stands in its place (its type and why),
    /// else `otherwise` (not published yet).
    fn restricted(
        source: *Source,
        arena: std.mem.Allocator,
        id: []const u8,
        otherwise: groq.Found,
    ) groq.DatasetError!groq.Found {
        std.debug.assert(id.len > 0);
        std.debug.assert(otherwise != .document);

        const reach = @import("reach.zig");
        const why = reach.explain(source.ctx, source.granted, id) catch return error.DatasetFailed;

        if (why.reason == null) {
            return otherwise;
        }

        const json = try reach.payload(arena, why);

        return .{
            .document = try groq.values.from_json(arena, json),
        };
    }
};

/// What one type's read asks for: its ids, one field's value, and what to keep.
const Read = struct {
    type: Type,
    ids: ?[]const []const u8 = null,
    field: ?groq.Hint = null,
    keep: ?groq.Keep = null,
};

/// What every page of a read filters on: one field's value, the status and owner clauses.
const Filter = struct {
    value: ?[]const u8,
    clauses: []const []const u8,
};

const Window = struct {
    offset: u32,
    size: u32,
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

fn type_named(types: []const Type, handle: []const u8) ?Type {
    std.debug.assert(handle.len > 0);

    for (types) |each| {
        if (std.mem.eql(u8, each.handle, handle)) {
            return each;
        }
    }

    return null;
}
