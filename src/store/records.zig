//! The `records` table: `store/documents.zig` over the record domain's tables.

const std = @import("std");
const db = @import("../lib/db.zig");
const kinds = @import("../model/kinds.zig");
const documents = @import("documents.zig");
const tables = @import("tables.zig");

const Store = documents.Store(tables.records);

pub const id_len = documents.id_len;
pub const list_max = documents.list_max;
pub const statuses_filter_max = documents.statuses_filter_max;
pub const type_ids_max = documents.type_ids_max;
pub const document_bytes_max = documents.document_bytes_max;
pub const search_len_max = documents.search_len_max;
pub const Error = documents.Error;
pub const Record = documents.Record;
pub const Insert = documents.Insert;
pub const Order = documents.Order;
pub const Filter = documents.Filter;
pub const Author = documents.Author;
pub const Query = documents.Query;
pub const App = documents.App;
pub const insert = Store.insert;
pub const get = Store.get;
pub const save = Store.save;
pub const set_status = Store.set_status;
pub const delete = Store.delete;
pub const set_app = Store.set_app;
pub const move_app = Store.move_app;

/// Every table that names the record, the assignments included.
pub fn rename(connection: *db.Db, from: []const u8, to: []const u8) Error!void {
    std.debug.assert(from.len == id_len);
    std.debug.assert(to.len == id_len);

    try Store.rename(connection, from, to);
    try @import("record_terms.zig").rename(connection, from, to);
}
pub const count_by_type = Store.count_by_type;
pub const list = Store.list;

const content_type = @import("content_types.zig");
const model_content_type = @import("../model/content_type.zig");

fn seed_type(fixture: *db.testing.Fixture, arena: std.mem.Allocator) ![]const u8 {
    std.debug.assert(fixture.connection.transaction_depth == 0);
    std.debug.assert(model_content_type.test_post.fields.len > 0);

    return content_type.insert(&fixture.connection, arena, model_content_type.test_post, 0);
}

fn seed_record(
    fixture: *db.testing.Fixture,
    arena: std.mem.Allocator,
    type_id: []const u8,
    title: []const u8,
    status: []const u8,
    views: i64,
) ![]const u8 {
    return seed_record_by(fixture, arena, type_id, title, status, views, "u_1", 1_000);
}

fn seed_record_by(
    fixture: *db.testing.Fixture,
    arena: std.mem.Allocator,
    type_id: []const u8,
    title: []const u8,
    status: []const u8,
    views: i64,
    author: []const u8,
    now_ms: i64,
) ![]const u8 {
    const data = try std.fmt.allocPrint(
        arena,
        "{{\"title\":\"{s}\",\"body\":\"about {s}\",\"views\":{d}}}",
        .{ title, title, views },
    );
    const id = try insert(&fixture.connection, std.testing.io, arena, .{
        .type_id = type_id,
        .created_by = author,
        .status = status,
    }, now_ms);
    const document = try std.json.parseFromSliceLeaky(std.json.Value, arena, data, .{});
    const values = @import("values.zig");
    const fields = model_content_type.test_post.fields;

    try values.write(&kinds.core, &fixture.connection, id, values.live, type_id, fields, document);

    return id;
}

test "ids sort in the order records were made, within one millisecond too" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const type_id = try seed_type(&fixture, arena);
    const first = try seed_record_by(&fixture, arena, type_id, "A", "draft", 1, "u_1", 5_000);
    const second = try seed_record_by(&fixture, arena, type_id, "B", "draft", 1, "u_1", 5_000);
    const third = try seed_record_by(&fixture, arena, type_id, "C", "draft", 1, "u_1", 5_000);
    const later = try seed_record_by(&fixture, arena, type_id, "D", "draft", 1, "u_1", 5_001);

    try std.testing.expectEqualStrings(first[0..12], third[0..12]);
    try std.testing.expectEqualStrings("0002", third[12..16]);
    try std.testing.expect(std.mem.order(u8, first, second) == .lt);
    try std.testing.expect(std.mem.order(u8, second, third) == .lt);
    try std.testing.expect(std.mem.order(u8, third, later) == .lt);
    try std.testing.expectEqualStrings("0000", later[12..16]);
}

test "insert, get, save with version check, transition, delete" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const type_id = try seed_type(&fixture, arena);
    const id = try seed_record(&fixture, arena, type_id, "Hello", "draft", 3);

    const row = (try get(connection, arena, id)).?;
    try std.testing.expectEqual(@as(i64, 1), row.version);
    try std.testing.expectEqualStrings("draft", row.status);

    const saved = try save(connection, id, "u_2", 1, 2_000, true);
    try std.testing.expectEqual(@as(i64, 2), saved);
    try std.testing.expectEqualStrings("u_2", (try get(connection, arena, id)).?.updated_by.?);
    try std.testing.expect((try get(connection, arena, id)).?.changed);
    const stale = save(connection, id, "u_2", 1, 3_000, false);
    try std.testing.expectError(error.Conflict, stale);
    const missing = save(connection, "missing", "u_2", null, 3_000, false);
    try std.testing.expectError(error.NotFound, missing);

    const published = try set_status(connection, id, "published", null, 4_000, "u_1", false);
    try std.testing.expectEqual(@as(i64, 3), published);
    try std.testing.expectEqualStrings("published", (try get(connection, arena, id)).?.status);
    try std.testing.expect(!(try get(connection, arena, id)).?.changed);
    try std.testing.expect(try delete(connection, id));
    try std.testing.expect((try get(connection, arena, id)) == null);
    try std.testing.expectEqual(
        @as(usize, 0),
        (try @import("values.zig").read(connection, arena, id, "live")).len,
    );
}

test "list: by status, filter on a field value, full-text search, order and paging" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const type_id = try seed_type(&fixture, arena);

    _ = try seed_record(&fixture, arena, type_id, "Alpha", "published", 10);
    _ = try seed_record(&fixture, arena, type_id, "Beta", "draft", 20);
    _ = try seed_record(&fixture, arena, type_id, "Gamma", "published", 20);

    const all = try list(connection, arena, .{ .type_ids = &.{type_id}, .order = .title_asc });
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("Alpha", all[0].title);

    const live = try list(
        connection,
        arena,
        .{ .type_ids = &.{type_id}, .statuses = &.{"published"}, .order = .title_asc },
    );
    try std.testing.expectEqual(@as(usize, 2), live.len);

    const twenty = try list(
        connection,
        arena,
        .{
            .type_ids = &.{type_id},
            .filter = .{ .field = "views", .int = 20 },
            .order = .title_asc,
        },
    );
    try std.testing.expectEqual(@as(usize, 2), twenty.len);
    try std.testing.expectEqualStrings("Beta", twenty[0].title);

    const found = try list(connection, arena, .{ .type_ids = &.{type_id}, .search = "gamma" });
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings("Gamma", found[0].title);

    const page = try list(
        connection,
        arena,
        .{ .type_ids = &.{type_id}, .order = .title_asc, .limit = 2, .offset = 2 },
    );
    try std.testing.expectEqual(@as(usize, 1), page.len);
    try std.testing.expectEqualStrings("Gamma", page[0].title);
}

test "list: across types, by author and excluded author, within time bounds" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const post_id = try seed_type(&fixture, arena);
    var note = model_content_type.test_post;
    note.handle = "note";
    note.name = "Note";
    const note_id = try content_type.insert(connection, arena, note, 0);

    _ = try seed_record_by(&fixture, arena, post_id, "Alpha", "draft", 1, "u_1", 1_000);
    _ = try seed_record_by(&fixture, arena, note_id, "Beta", "draft", 2, "u_2", 2_000);
    _ = try seed_record_by(&fixture, arena, note_id, "Gamma", "draft", 3, "u_1", 3_000);

    const both = try list(connection, arena, .{ .type_ids = &.{ post_id, note_id } });
    try std.testing.expectEqual(@as(usize, 3), both.len);
    try std.testing.expectEqualStrings("Gamma", both[0].title);
    try std.testing.expectEqualStrings("note", both[0].type);
    const posts = try list(connection, arena, .{ .type_ids = &.{post_id} });
    try std.testing.expectEqual(@as(usize, 1), posts.len);

    const by_first = try list(connection, arena, .{
        .type_ids = &.{ post_id, note_id },
        .created_by = .{ .id = "u_1" },
        .order = .title_asc,
    });
    try std.testing.expectEqual(@as(usize, 2), by_first.len);
    try std.testing.expectEqualStrings("Alpha", by_first[0].title);
    const not_first = try list(connection, arena, .{
        .type_ids = &.{ post_id, note_id },
        .updated_by = .{ .id = "u_1", .exclude = true },
    });
    try std.testing.expectEqual(@as(usize, 1), not_first.len);
    try std.testing.expectEqualStrings("Beta", not_first[0].title);

    const middle = try list(connection, arena, .{
        .type_ids = &.{ post_id, note_id },
        .created_after_ms = 2_000,
        .updated_before_ms = 3_000,
    });
    try std.testing.expectEqual(@as(usize, 1), middle.len);
    try std.testing.expectEqualStrings("Beta", middle[0].title);
    const filtered_by_field = try list(connection, arena, .{
        .type_ids = &.{ post_id, note_id },
        .filter = .{ .field = "views", .int = 3 },
    });
    try std.testing.expectEqual(@as(usize, 1), filtered_by_field.len);
}

test "an app's records: set, cleared, listed by app or as the project's own, moved on" {
    var fixture: db.testing.Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const connection = &fixture.connection;
    const type_id = try seed_type(&fixture, arena);
    const site = try seed_record(&fixture, arena, type_id, "Site", "draft", 1);
    const shop = try seed_record(&fixture, arena, type_id, "Shop", "draft", 2);
    const own = try seed_record(&fixture, arena, type_id, "Own", "draft", 3);

    try std.testing.expect((try get(connection, arena, own)).?.app == null);
    try set_app(connection, site, "www");
    try set_app(connection, shop, "saas");
    try std.testing.expectError(error.NotFound, set_app(connection, "missing", "www"));
    try std.testing.expectEqualStrings("www", (try get(connection, arena, site)).?.app.?);
    try std.testing.expectEqual(1, (try get(connection, arena, site)).?.version);

    const in_www: documents.App = .{ .name = "www" };
    const www = try list(connection, arena, .{ .type_ids = &.{type_id}, .app = in_www });
    try std.testing.expectEqual(1, www.len);
    try std.testing.expectEqualStrings("Site", www[0].title);
    const project = try list(connection, arena, .{ .type_ids = &.{type_id}, .app = .none });
    try std.testing.expectEqual(1, project.len);
    try std.testing.expectEqualStrings("Own", project[0].title);
    try std.testing.expectEqual(3, (try list(connection, arena, .{ .type_ids = &.{type_id} })).len);

    try std.testing.expectEqual(1, try move_app(connection, "www", "site"));
    try std.testing.expectEqual(0, try move_app(connection, "www", "site"));
    try std.testing.expectEqualStrings("site", (try get(connection, arena, site)).?.app.?);
    try set_app(connection, shop, null);
    try std.testing.expectEqual(2, (try list(connection, arena, .{
        .type_ids = &.{type_id},
        .app = .none,
    })).len);
}
