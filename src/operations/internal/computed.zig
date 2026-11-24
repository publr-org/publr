//! Computed fields of internal records, as core keeps them: each worked out by its plugin's
//! own function (`computed.<record>.<field>`), then by every modifier of
//! `<record>.<field>`, and stored in the record's document. What the work read is noted
//! (`lib/deps` values), so a read finds a value stale when any of it changed since, and
//! works it out again before it answers. A write of the record works its values out in the
//! same write, after the record is written, so the work sees the record as it now is.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const deps = @import("../../lib/deps.zig");
const computed_reads = @import("computed_reads.zig");
const Noted = computed_reads.Noted;
const keys_max = computed_reads.keys_max;
const stamps_of = computed_reads.stamps_of;
pub const until_prefix = computed_reads.until_prefix;

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Value = std.json.Value;
const Collection = model.internal_record.Collection;
const Scope = store.internal_records.Scope;
const Row = store.internal_records.Row;
const records = store.internal_records;
const SDK = registry.SDK;

/// How deep values being worked out may read other values being worked out; past it a read
/// takes the value as stored.
pub const depth_max: u32 = 4;
/// The values one call to their plugin works out.
pub const batch_max: u32 = 8;
/// Longest name a value is noted under.
pub const name_len_max: u32 = 256;

/// The rows of one read, each stale computed value worked out again first, stored, and put
/// in the row the read answers. A page is worked out in one batch per field.
pub fn freshen(ctx: *Ctx, scope: Scope, collection: Collection, rows: []Row) Error!void {
    std.debug.assert(scope.plugin.len > 0);
    std.debug.assert(rows.len <= sdk.operation.page_limit_max);

    if (collection.computed.len == 0 or rows.len == 0) {
        return;
    }

    if (ctx.computing_depth >= depth_max) {
        return;
    }

    const stamps = try stamps_of(ctx, scope, collection);
    const stale = ctx.arena.alloc(bool, rows.len) catch return error.OutOfMemory;
    var any = false;

    for (rows, stale) |row, *is_stale| {
        is_stale.* = !try all_fresh(ctx, scope, collection, stamps, row.id);
        any = any or is_stale.*;
    }

    if (!any) {
        return;
    }

    var picked: std.ArrayList(Row) = .empty;

    for (rows, stale) |row, is_stale| {
        if (is_stale) {
            picked.append(ctx.arena, row) catch return error.OutOfMemory;
        }
    }

    const worked = try work_out(ctx, scope, collection, stamps, picked.items);
    var next: u32 = 0;

    for (rows, stale) |*row, is_stale| {
        if (is_stale) {
            row.document = worked[next];
            next += 1;
        }
    }
}

/// A record just written: its computed values worked out over the document as written, and
/// stored without raising anything more.
pub fn written(
    ctx: *Ctx,
    scope: Scope,
    collection: Collection,
    id: []const u8,
    document: []const u8,
) Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(document.len > 0);

    if (collection.computed.len == 0) {
        return;
    }

    var row = [_]Row{.{
        .id = id,
        .document = document,
        .version = 0,
        .created_at = 0,
        .updated_at = 0,
    }};

    const stamps = try stamps_of(ctx, scope, collection);

    _ = try work_out(ctx, scope, collection, stamps, &row);
}

/// A record gone: what its values read is forgotten with it.
pub fn forget(ctx: *Ctx, scope: Scope, collection: Collection, id: []const u8) Error!void {
    std.debug.assert(id.len > 0);
    std.debug.assert(collection.computed.len <= model.internal_record.computed_max);

    var index = index_of(ctx);

    for (collection.computed) |field| {
        var buffer: [name_len_max]u8 = undefined;
        const name = try value_name(&buffer, scope, id, field);

        index.forget_value(name) catch |err| return unavailable(err);
    }
}

/// Whether every computed value of the record is fresh. A page being built depends on what
/// each read, as if it had read it itself.
fn all_fresh(
    ctx: *Ctx,
    scope: Scope,
    collection: Collection,
    stamps: []const u64,
    id: []const u8,
) Error!bool {
    std.debug.assert(id.len > 0);
    std.debug.assert(stamps.len == collection.computed.len);

    var index = index_of(ctx);

    for (collection.computed, stamps) |field, stamp| {
        var buffer: [name_len_max]u8 = undefined;
        const name = try value_name(&buffer, scope, id, field);
        const asked: deps.Index.Asked = .{
            .now_ms = ctx.now_ms,
            .stamp = stamp,
        };

        if (!(index.fresh(name, asked) catch |err| return unavailable(err))) {
            return false;
        }

        if (ctx.reads == null) {
            continue;
        }

        const keys = index.value_keys(ctx.arena, name) catch |err| return unavailable(err);

        for (keys) |key| {
            ctx.depends_on(key);
        }
    }

    return true;
}

/// The rows' computed values worked out a few rows at a time: each batch's documents read,
/// every field worked out, noted and stored, and only the documents as stored kept, the rest
/// of its work given back before the next. Answered in the rows' order.
fn work_out(
    ctx: *Ctx,
    scope: Scope,
    collection: Collection,
    stamps: []const u64,
    rows: []const Row,
) Error![]const []const u8 {
    std.debug.assert(rows.len > 0);
    std.debug.assert(stamps.len == collection.computed.len);

    var index = index_of(ctx);
    const at = index.revision() catch |err| return unavailable(err);
    const texts = ctx.arena.alloc([]const u8, rows.len) catch return error.OutOfMemory;
    const noted = ctx.arena.alloc(Noted, collection.computed.len) catch return error.OutOfMemory;

    for (noted) |*one| {
        one.* = try Noted.init(ctx.arena, ctx.reads);
    }

    const batch: Batch = .{
        .scope = scope,
        .collection = collection,
        .stamps = stamps,
        .noted = noted,
        .at = at,
    };
    var start: u32 = 0;

    while (start < rows.len) {
        const end: u32 = @intCast(@min(rows.len, start + batch_max));
        const block = try kept_batch(ctx, batch, rows[start..end]);
        var lines = std.mem.splitScalar(u8, block, '\n');

        for (texts[start..end]) |*text| {
            text.* = lines.next() orelse return error.Invalid;
        }

        start = end;
    }

    return texts;
}

/// What every batch of one read shares.
const Batch = struct {
    scope: Scope,
    collection: Collection,
    stamps: []const u64,
    noted: []Noted,
    at: u64,
};

/// One batch worked out in memory given back after it; its documents as stored kept.
fn kept_batch(ctx: *Ctx, batch: Batch, rows: []const Row) Error![]const u8 {
    std.debug.assert(rows.len > 0);
    std.debug.assert(rows.len <= batch_max);

    // Inside a plugin's call core works in its working memory: the batch's work goes back
    // to where it began, its documents moved down there first.
    if (sdk.call_json.host_call_begun(ctx)) |begun| {
        const block = worked_batch(ctx, batch, rows) catch |err| {
            sdk.call_json.give_back(ctx, begun);

            return err;
        };

        return ctx.calls_set_aside.?.keep_at(begun, block);
    }

    var working = sdk.call_json.Working.begin(ctx) catch null;
    const answered = worked_batch(ctx, batch, rows);

    if (working) |*held| {
        held.end();

        const block = answered catch |err| {
            try held.give_back_failed();

            return err;
        };
        const kept = ctx.arena.dupe(u8, block) catch return error.OutOfMemory;

        held.give_back();

        return kept;
    }

    return answered;
}

/// A batch's documents read, each computed field worked out, noted and stored: the
/// documents as stored, one a line, in one piece allocated last.
fn worked_batch(ctx: *Ctx, batch: Batch, rows: []const Row) Error![]const u8 {
    std.debug.assert(rows.len > 0);
    std.debug.assert(batch.noted.len == batch.collection.computed.len);

    const documents = ctx.arena.alloc(Value, rows.len) catch return error.OutOfMemory;
    // Whether any of a row's values came out other than it was stored: only those rows are
    // written again.
    const changed = ctx.arena.alloc(bool, rows.len) catch return error.OutOfMemory;
    const kept = ctx.arena.alloc(bool, rows.len) catch return error.OutOfMemory;

    for (rows, documents, changed) |row, *document, *differs| {
        document.* = std.json.parseFromSliceLeaky(Value, ctx.arena, row.document, .{}) catch {
            return error.Invalid;
        };
        differs.* = false;
    }

    const fields = batch.collection.computed;

    for (fields, batch.stamps, batch.noted) |field, stamp, *noted| {
        const before = try values_of(ctx, documents, field);

        noted.reset();
        try field_worked_out(ctx, batch.scope, field, rows, documents, noted);

        const after = try values_of(ctx, documents, field);

        for (before, after, kept, changed) |was, now, *same, *differs| {
            same.* = std.mem.eql(u8, was, now);
            differs.* = differs.* or !same.*;
        }

        try note(ctx, batch.scope, field, rows, noted, kept, .{
            .at = batch.at,
            .until_ms = noted.until_ms,
            .stamp = stamp,
        });
    }

    return stored(ctx, batch.scope, rows, documents, changed);
}

/// Each document's value of `field` as JSON text; empty where it has none.
fn values_of(ctx: *Ctx, documents: []const Value, field: []const u8) Error![]const []const u8 {
    std.debug.assert(field.len > 0);
    std.debug.assert(documents.len > 0);

    const texts = ctx.arena.alloc([]const u8, documents.len) catch return error.OutOfMemory;

    for (documents, texts) |document, *text| {
        const value = document.object.get(field) orelse {
            text.* = "";
            continue;
        };

        text.* = std.json.Stringify.valueAlloc(ctx.arena, value, .{}) catch {
            return error.OutOfMemory;
        };
    }

    return texts;
}

/// `field` of every document worked out by its plugin, then by its modifiers, while what
/// they read is noted.
fn field_worked_out(
    ctx: *Ctx,
    scope: Scope,
    field: []const u8,
    rows: []const Row,
    documents: []Value,
    noted: *Noted,
) Error!void {
    std.debug.assert(field.len > 0);
    std.debug.assert(rows.len == documents.len);

    var buffer: [name_len_max]u8 = undefined;
    const record = try record_name(&buffer, scope, field);
    const items = ctx.arena.alloc(Value, rows.len) catch return error.OutOfMemory;

    for (rows, documents, items) |row, document, *item| {
        item.* = try handed(ctx.arena, row.id, document);
    }

    var batch: sdk.mods.Batch = .{
        .items = items,
    };
    var reading = unread(ctx);

    reading.reads = noted.reads();
    reading.computing_depth = ctx.computing_depth + 1;

    const done = worked_by_plugins(&reading, scope.plugin, record, &batch);

    // The refusal's words are the call's, whoever made them on the way.
    if (ctx.failure == null) {
        ctx.failure = reading.failure;
    }

    try done;

    for (items, documents) |item, *document| {
        const value = item.object.get("value") orelse return worked_out_not(ctx, record);

        if (value == .null) {
            return worked_out_not(ctx, record);
        }

        try document.object.put(ctx.arena, field, value);
    }
}

/// The owner's function of `record`, then every modifier of it.
fn worked_by_plugins(
    ctx: *Ctx,
    owner: []const u8,
    record: []const u8,
    batch: *sdk.mods.Batch,
) Error!void {
    std.debug.assert(owner.len > 0);
    std.debug.assert(record.len > 0);

    var buffer: [name_len_max]u8 = undefined;
    const compute = std.fmt.bufPrint(&buffer, "computed.{s}", .{record}) catch {
        return error.Invalid;
    };

    try SDK.compute(ctx, owner, compute, batch);
    try SDK.modify(ctx, record, batch);
}

/// The call as the work sees it: nobody reading. No person, visitor, cookie or page; the
/// main language; live records, as everyone reads them. A value is stored once for all
/// readers, so nothing about this one may go into it. What the work may read is its
/// plugin's grant (installed plugins are held to it whoever calls).
fn unread(ctx: *const Ctx) Ctx {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(ctx.computing_depth < depth_max);

    var reading = ctx.*;

    reading.caller = .system;
    reading.operator = "";
    reading.visitor = "";
    reading.cookies = "";
    reading.referer = "";
    reading.address = "";
    reading.view = .{};
    reading.language = .{};
    reading.address_code = "";
    reading.dimensions = &.{};
    reading.preview = false;
    reading.delivery = true;
    reading.failure = null;

    return reading;
}

/// What the function and the modifiers are handed: `{ id, record }`.
fn handed(arena: std.mem.Allocator, id: []const u8, document: Value) Error!Value {
    std.debug.assert(id.len > 0);
    std.debug.assert(document == .object);

    var object: std.json.ObjectMap = .empty;

    const named: Value = .{
        .string = id,
    };

    object.put(arena, "id", named) catch return error.OutOfMemory;
    object.put(arena, "record", document) catch return error.OutOfMemory;

    return .{
        .object = object,
    };
}

/// No value came back: the plugin is not there to work it out, or the record did not read
/// as its type. The read is refused rather than answered with a value never worked out.
fn worked_out_not(ctx: *Ctx, record: []const u8) Error {
    std.debug.assert(record.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    if (ctx.failure == null) {
        ctx.failure = .{
            .name = "NotComputed",
            .status = 409,
            .message = std.fmt.allocPrint(
                ctx.arena,
                "{s} could not be worked out: its plugin did not answer it",
                .{record},
            ) catch "A computed field could not be worked out",
        };
    }

    return error.Failed;
}

/// Each row's value noted with what the batch read, as of `at`. A batch that read more than
/// `keys_max` keys is not noted: its values are worked out again on every read.
fn note(
    ctx: *Ctx,
    scope: Scope,
    field: []const u8,
    rows: []const Row,
    noted: *const Noted,
    unchanged: []const bool,
    made: deps.Index.Made,
) Error!void {
    std.debug.assert(field.len > 0);
    std.debug.assert(rows.len == unchanged.len);

    var index = index_of(ctx);
    // A value worked out the same, by work that read nothing, holds as it was noted: an
    // order's line keeping what it was priced at. Nothing is written for it again.
    const read_nothing = noted.complete and noted.len == 0 and noted.until_ms == null;
    const asked: deps.Index.Asked = .{
        .now_ms = ctx.now_ms,
        .stamp = made.stamp,
    };

    for (rows, unchanged) |row, same| {
        var buffer: [name_len_max]u8 = undefined;
        const name = try value_name(&buffer, scope, row.id, field);

        if (same and read_nothing) {
            const holds = index.fresh(name, asked) catch |err| return unavailable(err);

            if (holds) {
                continue;
            }
        }

        if (!noted.complete) {
            std.log.warn("computed {s}: read over {d} keys, worked out on every read", .{
                name,
                keys_max,
            });
            index.forget_value(name) catch |err| return unavailable(err);
            continue;
        }

        index.note(name, noted.noted_keys(), made) catch |err| return unavailable(err);
    }
}

/// The documents written back with their values, their versions as they were: one a line,
/// in one piece allocated last.
fn stored(
    ctx: *Ctx,
    scope: Scope,
    rows: []const Row,
    documents: []const Value,
    changed: []const bool,
) Error![]const u8 {
    std.debug.assert(rows.len == documents.len);
    std.debug.assert(rows.len == changed.len);

    const texts = ctx.arena.alloc([]const u8, rows.len) catch return error.OutOfMemory;
    var total: u64 = 0;

    for (rows, documents, texts, changed) |row, document, *text, differs| {
        text.* = std.json.Stringify.valueAlloc(ctx.arena, document, .{}) catch {
            return error.OutOfMemory;
        };

        if (text.len > model.internal_record.document_bytes_max) {
            return error.Invalid;
        }

        if (differs) {
            try records.refresh(ctx.db, scope, row.id, text.*);
        }

        total += text.len + 1;
    }

    const joined = ctx.arena.alloc(u8, @intCast(total)) catch return error.OutOfMemory;
    var at: u32 = 0;

    for (texts) |text| {
        @memcpy(joined[at..][0..text.len], text);
        joined[at + text.len] = '\n';
        at += @intCast(text.len + 1);
    }

    return joined;
}

/// `<plugin>.<kind>.<field>`: what modifiers of the value take.
pub fn record_name(buffer: []u8, scope: Scope, field: []const u8) Error![]const u8 {
    std.debug.assert(field.len > 0);
    std.debug.assert(buffer.len == name_len_max);

    return std.fmt.bufPrint(buffer, "{s}.{s}.{s}", .{ scope.plugin, scope.kind, field }) catch
        error.Invalid;
}

/// `computed:<plugin>/<kind>/<id>/<field>`: what the value is noted under.
fn value_name(buffer: []u8, scope: Scope, id: []const u8, field: []const u8) Error![]const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(field.len > 0);

    const format = "computed:{s}/{s}/{s}/{s}";

    return std.fmt.bufPrint(buffer, format, .{ scope.plugin, scope.kind, id, field }) catch
        error.Invalid;
}

fn index_of(ctx: *Ctx) deps.Index {
    std.debug.assert(ctx.now_ms >= 0);
    std.debug.assert(deps.quiet_ms > 0);

    return .{
        .db = ctx.db,
        .options = .{
            .quiet_ms = deps.quiet_ms,
        },
    };
}

test "a value's names" {
    const scope: Scope = .{
        .plugin = "orders",
        .app = "",
        .kind = "line",
    };
    var buffer: [name_len_max]u8 = undefined;

    try std.testing.expectEqualStrings(
        "orders.line.priced",
        try record_name(&buffer, scope, "priced"),
    );
    try std.testing.expectEqualStrings(
        "computed:orders/line/abc/priced",
        try value_name(&buffer, scope, "abc", "priced"),
    );
}

/// The index could not answer: the read or write is refused, with why in the log.
fn unavailable(err: deps.Error) Error {
    std.debug.assert(@errorName(err).len > 0);
    std.debug.assert(depth_max > 0);

    std.log.warn("computed fields: the index failed: {t}", .{err});

    return error.Unavailable;
}

/// Records just written many at a time: their computed values worked out a few rows a call
/// and stored without raising anything more.
pub fn written_many(ctx: *Ctx, scope: Scope, collection: Collection, rows: []const Row) Error!void {
    std.debug.assert(rows.len <= sdk.operation.page_limit_max);
    std.debug.assert(scope.plugin.len > 0);

    if (collection.computed.len == 0 or rows.len == 0) {
        return;
    }

    const stamps = try stamps_of(ctx, scope, collection);

    _ = try work_out(ctx, scope, collection, stamps, rows);
}
