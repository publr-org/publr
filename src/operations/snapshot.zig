const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const record = @import("record.zig");
const access = record.access;
const document_module = record.document;
const types = @import("content_type.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const snapshot = store.snapshots;

pub const namespace: sdk.operation.Namespace = .{
    .name = "snapshot",
    .summary = "Frozen copies of a record's document: revisions and other archives",
    .details =
    \\A snapshot is a read-only, point-in-time copy of a record's document, numbered per
    \\record. The core takes one of kind `revision` whenever a live document is replaced;
    \\plugins take their own kinds (`order.completed`, ...). Snapshots are never edited;
    \\restoring one is a normal `record save` of its document. Signed-in callers only.
    ,
};

pub const Item = struct {
    seq: i64,
    kind: []const u8,
    at: i64,
    by: ?[]const u8,
    document: []const u8,
};

const example_id = "a1b2c3d4e5f60718293a4b5c";
const example_item: Item = .{
    .seq = 1,
    .kind = "revision",
    .at = 1789650000000,
    .by = "3f9c1e0a5b7d2c4e6f8a9b0c",
    .document = "{\"title\":\"Hello, world\",\"body\":\"<p>First post.</p>\"}",
};

pub const List = struct {
    pub const name = "snapshot.list";
    pub const description = "List a record's snapshots, oldest first";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { id: []const u8, kind: ?[]const u8 = null, limit: u32 = 100 };
    pub const Out = struct { snapshots: []const Item };
    pub const example: In = .{ .id = example_id, .kind = "revision" };
    pub const example_out: Out = .{ .snapshots = &.{example_item} };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .kind = "Only this kind (`revision`, ...); every kind when omitted",
        .limit = "How many, up to 1000",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.limit == 0 or in.limit > snapshot.list_max) {
            return error.Invalid;
        }

        const row = try access.load(ctx, in.id, granted) orelse return error.NotFound;
        const rows = try snapshot.list(ctx.db, ctx.arena, row.id, in.kind, in.limit);
        const items = try ctx.arena.alloc(Item, rows.len);

        for (rows, 0..) |found, index| {
            items[index] = item_of(found);
        }

        return .{ .snapshots = items };
    }
};

pub const Get = struct {
    pub const name = "snapshot.get";
    pub const description = "Read one snapshot of a record";
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { id: []const u8, seq: i64 };
    pub const Out = Item;
    pub const example: In = .{ .id = example_id, .seq = 1 };
    pub const example_out: Out = example_item;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.seq < 1) {
            return error.Invalid;
        }

        const row = try access.load(ctx, in.id, granted) orelse return error.NotFound;
        const found = try snapshot.get(ctx.db, ctx.arena, row.id, in.seq);

        return item_of(found orelse return error.NotFound);
    }
};

pub const Take = struct {
    pub const name = "snapshot.take";
    pub const description = "Freeze a record's live document under a kind of your own";
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8, kind: []const u8 };
    pub const Out = struct { seq: i64 };
    pub const example: In = .{ .id = example_id, .kind = "order.completed" };
    pub const example_out: Out = .{ .seq = 1 };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.kind.len == 0 or in.kind.len > snapshot.kind_len_max) {
            return error.Invalid;
        }

        const row = try access.load(ctx, in.id, granted) orelse return error.NotFound;
        const type_row = try types.find(ctx, row.type_id) orelse return error.NotFound;
        const live = store.values.live;
        const document = try document_module.document_of(ctx, row.id, live, type_row.def);
        const text = try std.json.Stringify.valueAlloc(ctx.arena, document, .{});
        const seq = try snapshot.take(
            ctx.db,
            row.id,
            in.kind,
            ctx.now_ms,
            ctx.caller.user_id(),
            text,
        );

        return .{ .seq = seq };
    }
};

pub const Restore = struct {
    pub const name = "snapshot.restore";
    pub const description = "Write a snapshot's document back through `record save`";
    pub const details =
        \\A normal save: on a live record the restored document lands as pending changes
        \\(publish to make it live), on a draft it replaces the document; either way the
        \\version it replaces is kept as a new revision snapshot.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { id: []const u8, seq: i64, expected_version: ?i64 = null };
    pub const Out = struct { version: i64, changed: bool };
    pub const example: In = .{ .id = example_id, .seq = 1 };
    pub const example_out: Out = .{ .version = 3, .changed = true };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .id = "The record id",
        .seq = "The snapshot to restore",
        .expected_version = "The record `version` you read; refuse if it changed",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.seq < 1) {
            return error.Invalid;
        }

        const row = try access.load(ctx, in.id, granted) orelse return error.NotFound;
        const found = try snapshot.get(ctx.db, ctx.arena, row.id, in.seq);
        const item = found orelse return error.NotFound;
        const record_operations = @import("record.zig");
        const saved = try registry.SDK.dispatch(ctx, record_operations.Save, .{
            .id = row.id,
            .document = item.document,
            .expected_version = in.expected_version,
        });

        ctx.notice("snapshot.restored", row.id);

        return .{ .version = saved.version, .changed = saved.changed };
    }
};

pub const Prune = struct {
    pub const name = "snapshot.prune";
    pub const description = "Keep only the newest snapshots of a kind for a record";
    pub const kind: sdk.operation.Kind = .write;
    pub const destroys = true;
    pub const In = struct { id: []const u8, kind: []const u8, keep: u32 };
    pub const Out = struct { removed: u32 };
    pub const example: In = .{ .id = example_id, .kind = "revision", .keep = 20 };
    pub const example_out: Out = .{ .removed = 0 };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.kind.len == 0 or in.kind.len > snapshot.kind_len_max) {
            return error.Invalid;
        }

        const row = try access.load(ctx, in.id, granted) orelse return error.NotFound;
        const removed = try snapshot.prune(ctx.db, row.id, in.kind, in.keep);

        return .{ .removed = removed };
    }
};

fn item_of(row: snapshot.Row) Item {
    std.debug.assert(row.seq >= 1);
    std.debug.assert(row.kind.len > 0);

    return .{
        .seq = row.seq,
        .kind = row.kind,
        .at = row.at,
        .by = row.by,
        .document = row.document,
    };
}

pub const operations = [_]type{ List, Get, Take, Restore, Prune };
