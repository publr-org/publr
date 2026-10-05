//! The live documents of a page of listed records, read together: one query for all their
//! values, then each assembled with its type's fields. What a list asks for when it shows
//! documents, instead of one read per record.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const registry = @import("../../server/registry.zig");
const store = @import("../../store.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Record = store.documents.Record;

pub fn Of(comptime Domain: type) type {
    return struct {
        const values = Domain.values;
        const definitions = Domain.definition;

        /// Each record's live document as JSON text, in the records' order.
        pub fn documents_of(ctx: *Ctx, records: []const Record) Error![]const []const u8 {
            return documents_in(ctx, records, values.live);
        }

        /// What an editor sees: the pending copy of a record with unpublished changes, the
        /// live document of the others.
        pub fn edit_documents_of(ctx: *Ctx, records: []const Record) Error![]const []const u8 {
            std.debug.assert(records.len <= 1024);

            const live = try documents_in(ctx, records, values.live);
            var changed: std.ArrayList(Record) = .empty;

            for (records) |record| {
                if (record.changed) {
                    changed.append(ctx.arena, record) catch return error.OutOfMemory;
                }
            }

            if (changed.items.len == 0) {
                return live;
            }

            const pending = try documents_in(ctx, changed.items, values.pending);
            const texts = @constCast(live);
            var next: u32 = 0;

            for (records, texts) |record, *text| {
                if (record.changed) {
                    text.* = pending[next];
                    next += 1;
                }
            }

            return texts;
        }

        fn documents_in(
            ctx: *Ctx,
            records: []const Record,
            slot: []const u8,
        ) Error![]const []const u8 {
            std.debug.assert(records.len <= 1024);
            std.debug.assert(ctx.now_ms >= 0);

            const ids = ctx.arena.alloc([]const u8, records.len) catch return error.OutOfMemory;

            for (records, ids) |record, *id| {
                id.* = record.id;
            }

            const owned = try values.read_many(ctx.db, ctx.arena, ids, slot);
            const grouped = try group(ctx, owned);
            const texts = ctx.arena.alloc([]const u8, records.len) catch {
                return error.OutOfMemory;
            };
            var cached_type: []const u8 = "";
            var cached_def: store.definitions.Def = undefined;

            for (records, texts) |record, *text| {
                if (!std.mem.eql(u8, cached_type, record.type_id)) {
                    const found = try definitions.find(ctx, record.type_id) orelse {
                        return error.NotFound;
                    };

                    cached_type = record.type_id;
                    cached_def = found.def;
                }

                const rows = grouped.get(record.id) orelse &.{};
                const parsed = try model.document.assemble(
                    registry.Kinds.all,
                    ctx.arena,
                    cached_def.fields,
                    rows,
                );

                text.* = std.json.Stringify.valueAlloc(ctx.arena, parsed, .{}) catch {
                    return error.OutOfMemory;
                };
            }

            return texts;
        }

        /// The page's rows by record: they come grouped, so each record is one slice.
        fn group(
            ctx: *Ctx,
            owned: []const store.document_values.Owned,
        ) Error!std.StringHashMapUnmanaged([]const model.document.Row) {
            std.debug.assert(owned.len < 1 << 24);

            var map: std.StringHashMapUnmanaged([]const model.document.Row) = .empty;
            const rows = ctx.arena.alloc(model.document.Row, owned.len) catch {
                return error.OutOfMemory;
            };
            var start: u32 = 0;

            for (owned, rows, 0..) |item, *row, index| {
                row.* = item.row;

                const last = index + 1 == owned.len or
                    !std.mem.eql(u8, owned[index + 1].record, item.record);

                if (last) {
                    const end: u32 = @intCast(index + 1);

                    map.put(ctx.arena, item.record, rows[start..end]) catch {
                        return error.OutOfMemory;
                    };
                    start = end;
                }
            }

            return map;
        }
    };
}

test "listed documents: read with their page, the same as one read each, in list order" {
    const records = @import("../record.zig");
    const content_types = @import("../content_type.zig");
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);

    _ = try registry.SDK.dispatch(&system, content_types.Create, .{
        .definition = "{\"handle\":\"note\",\"name\":\"Note\",\"fields\":[" ++
            "{\"name\":\"title\",\"label\":\"Title\",\"kind\":\"string\",\"required\":true}," ++
            "{\"name\":\"tags\",\"label\":\"Tags\",\"kind\":\"string\",\"many\":true}]}",
    });
    _ = try registry.SDK.dispatch(&system, content_types.Create, .{
        .definition = "{\"handle\":\"memo\",\"name\":\"Memo\",\"fields\":[" ++
            "{\"name\":\"title\",\"label\":\"Title\",\"kind\":\"string\",\"required\":true}]}",
    });

    const first = try registry.SDK.dispatch(&system, records.Create, .{
        .type = "note",
        .document = "{\"title\":\"First\",\"tags\":[\"a\",\"b\"]}",
    });
    _ = try registry.SDK.dispatch(&system, records.Create, .{
        .type = "memo",
        .document = "{\"title\":\"Second\"}",
    });
    _ = try registry.SDK.dispatch(&system, records.Create, .{
        .type = "note",
        .document = "{\"title\":\"Empty\"}",
    });

    const listed = try registry.SDK.dispatch(&system, records.List, .{
        .types = &.{ "note", "memo" },
        .order = .created_desc,
        .documents = true,
    });

    try std.testing.expectEqual(listed.records.len, listed.documents.len);
    try std.testing.expectEqual(@as(usize, 3), listed.records.len);

    for (listed.records, listed.documents) |record, text| {
        const one = try registry.SDK.dispatch(&system, records.Get, .{ .id = record.id });

        try std.testing.expectEqualStrings(one.document, text);
    }

    const plain = try registry.SDK.dispatch(&system, records.List, .{ .type = "note" });
    try std.testing.expectEqual(@as(usize, 0), plain.documents.len);
    try std.testing.expect(first.id.len > 0);
}
