//! The `record_values` rows (and the `record_search` index): `store/document_values.zig`
//! over the record domain's tables.

const std = @import("std");
const db = @import("../lib/db.zig");
const field = @import("../model/field.zig");
const kinds = @import("../model/kinds.zig");
const document = @import("../model/document.zig");
const document_values = @import("document_values.zig");
const tables = @import("tables.zig");

const Store = document_values.Store(tables.records);
const Def = field.Def;
const Value = std.json.Value;

pub const Error = document_values.Error;
pub const live = document_values.live;
pub const pending = document_values.pending;
pub const slot_len_max = document_values.slot_len_max;
pub const Referrer = document_values.Referrer;
pub const slots_of = Store.slots_of;
pub const has_slot = Store.has_slot;
pub const read = Store.read;
pub const read_many = Store.read_many;
pub const Owned = document_values.Owned;
pub const referrers = Store.referrers;
pub const find_by_text = Store.find_by_text;
pub const find_by_integer = Store.find_by_integer;
pub const read_integer = Store.read_integer;
pub const delete_references = Store.delete_references;
pub const read_text = Store.read_text;
pub const delete_field = Store.delete_field;
pub const count_field = Store.count_field;

const record_terms = @import("record_terms.zig");
const taxonomy = @import("../model/taxonomy.zig");

/// The values, and, for every `terms` field, the assignments in `record_terms`.
pub fn write(
    known: []const kinds.Kind,
    connection: *db.Db,
    record_id: []const u8,
    slot: []const u8,
    type_id: []const u8,
    fields: []const Def,
    value: Value,
) Error!void {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(slot.len > 0);

    try Store.write(known, connection, record_id, slot, type_id, fields, value);

    var buffer: [field.fields_max]Def = undefined;

    for (taxonomy.terms_fields(fields, &buffer)) |assigned| {
        var ids: [record_terms.ids_max][]const u8 = undefined;
        const chosen = if (value == .object) value.object.get(assigned.name) else null;
        const assignment: record_terms.Assignment = .{
            .record = record_id,
            .slot = slot,
            .field = assigned.name,
        };

        try record_terms.write(connection, assignment, ids_of(chosen, &ids));
    }
}

/// The term ids a document holds under a terms field: one, many, or none.
fn ids_of(value: ?Value, buffer: *[record_terms.ids_max][]const u8) []const []const u8 {
    std.debug.assert(buffer.len == record_terms.ids_max);
    std.debug.assert(record_terms.ids_max > 0);

    const chosen = value orelse return &.{};
    var count: u32 = 0;

    switch (chosen) {
        .string => |id| {
            buffer[0] = id;
            count = 1;
        },
        .array => |items| {
            for (items.items) |item| {
                if (item == .string and count < record_terms.ids_max) {
                    buffer[count] = item.string;
                    count += 1;
                }
            }
        },
        else => {},
    }

    return buffer[0..count];
}

pub fn clear(connection: *db.Db, record_id: []const u8, slot: ?[]const u8) db.Error!void {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(connection.transaction_depth <= 8);

    try Store.clear(connection, record_id, slot);
    try record_terms.clear(connection, record_id, slot);
}

pub fn promote(
    connection: *db.Db,
    record_id: []const u8,
    from: []const u8,
    to: []const u8,
) db.Error!bool {
    std.debug.assert(record_id.len > 0);
    std.debug.assert(!std.mem.eql(u8, from, to));

    const promoted = try Store.promote(connection, record_id, from, to);

    if (promoted) {
        try record_terms.promote(connection, record_id, from, to);
    }

    return promoted;
}

const test_fields = [_]Def{
    .{ .name = "title", .label = "Title", .kind = "string", .searchable = true },
    .{ .name = "views", .label = "Views", .kind = "integer" },
    .{ .name = "score", .label = "Score", .kind = "number" },
    .{ .name = "live", .label = "Live", .kind = "boolean" },
    .{ .name = "body", .label = "Body", .kind = "richtext" },
    .{ .name = "cover", .label = "Cover", .kind = "media" },
    .{
        .name = "tags",
        .label = "Tags",
        .kind = "reference",
        .many = true,
        .options = .{ .to = &.{"tag"} },
    },
    .{ .name = "seo", .label = "SEO", .kind = "group", .fields = &.{
        .{ .name = "description", .label = "Description", .kind = "text" },
    } },
    .{ .name = "faq", .label = "FAQ", .kind = "repeater", .fields = &.{
        .{ .name = "question", .label = "Q", .kind = "string" },
        .{ .name = "answer", .label = "A", .kind = "text" },
        .{ .name = "link", .label = "Link", .kind = "reference", .options = .{ .to = &.{"post"} } },
    } },
};

fn seed_record(
    fixture: *db.testing.Fixture,
    arena: std.mem.Allocator,
    id: []const u8,
) ![]const u8 {
    std.debug.assert(id.len > 0);
    std.debug.assert(fixture.connection.transaction_depth == 0);

    const content_type = @import("content_types.zig");
    const type_id = try content_type.insert(&fixture.connection, arena, .{
        .handle = "page",
        .name = "Page",
        .fields = &test_fields,
    }, 0);
    var insert = try fixture.connection.prepare(
        "INSERT INTO records (id, type_id, status, changed, version, created_at, updated_at) " ++
            "VALUES (?1, ?2, 'draft', 0, 1, 0, 0)",
    );
    defer insert.finalize();

    try insert.bind_text(1, id);
    try insert.bind_text(2, type_id);
    try insert.exec();

    return type_id;
}

test "write then assemble round-trips every kind, groups, repeaters and many references" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    const type_id = try seed_record(&fixture, arena, "e1");

    const text =
        \\{"title":"Hello","views":3,"score":4.5,"live":true,"body":"<p>x</p>","cover":"m1",
        \\ "tags":["t1","t2"],"seo":{"description":"about"},
        \\ "faq":[{"question":"q1","answer":"a1","link":"p9"},{"question":"q2"}]}
    ;
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, text, .{});

    try write(&kinds.core, connection, "e1", live, type_id, &test_fields, parsed);

    const rows = try read(connection, arena, "e1", live);
    try std.testing.expectEqual(@as(usize, 13), rows.len);

    const back = try document.assemble(&kinds.core, arena, &test_fields, rows);
    var out: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(back, .{}, &out.writer);

    const expected = "{\"title\":\"Hello\",\"views\":3,\"score\":4.5,\"live\":true," ++
        "\"body\":\"<p>x</p>\"," ++
        "\"cover\":\"m1\",\"tags\":[\"t1\",\"t2\"],\"seo\":{\"description\":\"about\"}," ++
        "\"faq\":[{\"question\":\"q1\",\"answer\":\"a1\",\"link\":\"p9\"},{\"question\":\"q2\"}]}";
    try std.testing.expectEqualStrings(expected, out.written());

    const pointing = try referrers(connection, arena, "t2", .live);
    try std.testing.expectEqual(@as(usize, 1), pointing.len);
    try std.testing.expectEqualStrings("tags", pointing[0].field);
    try std.testing.expectEqualStrings(
        "faq.link",
        (try referrers(connection, arena, "p9", .live))[0].field,
    );

    try std.testing.expectEqualStrings(
        "e1",
        (try find_by_text(connection, arena, type_id, "title", "Hello", "")).?,
    );
    const nope = try find_by_text(connection, arena, type_id, "title", "Nope", "");
    try std.testing.expect(nope == null);

    var fts = try connection.prepare(
        "SELECT count(*) FROM record_search WHERE record_search MATCH 'hello'",
    );
    defer fts.finalize();
    try std.testing.expect(try fts.step());
    try std.testing.expectEqual(@as(i64, 1), fts.read_int());
}

test "a second write replaces everything; delete_field removes a field's rows including children" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;

    const type_id = try seed_record(&fixture, arena, "e1");

    const first = try std.json.parseFromSliceLeaky(
        Value,
        arena,
        "{\"title\":\"A\",\"tags\":[\"t1\",\"t2\",\"t3\"]}",
        .{},
    );
    try write(&kinds.core, connection, "e1", live, type_id, &test_fields, first);
    const second = try std.json.parseFromSliceLeaky(
        Value,
        arena,
        "{\"title\":\"B\",\"tags\":[\"t9\"],\"faq\":[{\"question\":\"q\"}]}",
        .{},
    );
    try write(&kinds.core, connection, "e1", live, type_id, &test_fields, second);

    const rows = try read(connection, arena, "e1", live);
    try std.testing.expectEqual(@as(usize, 3), rows.len);

    try std.testing.expectEqual(@as(u32, 1), try count_field(connection, type_id, "faq"));
    try std.testing.expectEqual(@as(u32, 1), try delete_field(connection, type_id, "faq"));
    try std.testing.expectEqual(@as(usize, 2), (try read(connection, arena, "e1", live)).len);
    try std.testing.expectEqual(@as(u32, 0), try count_field(connection, type_id, "faq"));
}

test "slots: a pending copy is invisible to lookups until promoted to live" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const type_id = try seed_record(&fixture, arena, "e1");

    const first = try std.json.parseFromSliceLeaky(Value, arena, "{\"title\":\"Live\"}", .{});
    try write(&kinds.core, connection, "e1", live, type_id, &test_fields, first);
    const second = try std.json.parseFromSliceLeaky(Value, arena, "{\"title\":\"Edited\"}", .{});
    try write(&kinds.core, connection, "e1", pending, type_id, &test_fields, second);

    try std.testing.expect(try has_slot(connection, "e1", pending));
    const live_title = (try read_text(connection, arena, "e1", live, "title")).?;
    const pending_title = (try read_text(connection, arena, "e1", pending, "title")).?;
    try std.testing.expectEqualStrings("Live", live_title);
    try std.testing.expectEqualStrings("Edited", pending_title);
    const parked = try find_by_text(connection, arena, type_id, "title", "Edited", "");
    try std.testing.expect(parked == null);

    try std.testing.expect(try promote(connection, "e1", pending, live));
    try std.testing.expect(!try promote(connection, "e1", pending, live));

    try std.testing.expect(!try has_slot(connection, "e1", pending));
    try std.testing.expectEqual(@as(usize, 1), (try slots_of(connection, arena, "e1")).len);
    const promoted_title = (try read_text(connection, arena, "e1", live, "title")).?;
    try std.testing.expectEqualStrings("Edited", promoted_title);
    const live_now = try find_by_text(connection, arena, type_id, "title", "Edited", "");
    try std.testing.expect(live_now != null);

    try clear(connection, "e1", null);
    try std.testing.expectEqual(@as(usize, 0), (try read(connection, arena, "e1", live)).len);
}
