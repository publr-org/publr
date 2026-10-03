const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const registry = @import("../../server/registry.zig");
const record = @import("../record.zig");
const types = @import("../content_type.zig");

const SDK = registry.SDK;
const Query = record.Query;

const author_type: model.content_type.Def = .{
    .handle = "author",
    .name = "Author",
    .public = true,
    .fields = &.{
        .{ .name = "name", .label = "Name", .kind = "string", .required = true },
        .{
            .name = "books",
            .label = "Books",
            .kind = "virtual",
            .many = true,
            .options = .{ .virtual = "referenced_by", .to = &.{"book"}, .via = "author" },
        },
    },
};
const book_type: model.content_type.Def = .{
    .handle = "book",
    .name = "Book",
    .public = true,
    .fields = &.{
        .{ .name = "title", .label = "Title", .kind = "string", .required = true },
        .{ .name = "views", .label = "Views", .kind = "integer" },
        .{
            .name = "author",
            .label = "Author",
            .kind = "reference",
            .options = .{ .to = &.{"author"} },
        },
    },
};
const ledger_type: model.content_type.Def = .{
    .handle = "ledger",
    .name = "Ledger",
    .fields = &.{.{ .name = "title", .label = "Title", .kind = "string", .required = true }},
};

const Library = struct {
    harness: sdk.testing.Harness = undefined,
    ada: []const u8 = "",
    hidden: []const u8 = "",

    fn init(library: *Library) !void {
        std.debug.assert(library.ada.len == 0);

        try library.harness.init();

        var system = library.harness.ctx(.system);

        try SDK.bootstrap(&system);

        for ([_]model.content_type.Def{ author_type, book_type, ledger_type }) |def| {
            const definition = try model.content_type.encode(system.arena, def);

            _ = try SDK.dispatch(&system, types.Create, .{ .definition = definition });
        }

        var admin = library.as_admin();
        const ada = try create(&admin, "author", "{\"name\":\"Ada\"}", "published");
        const hidden = try create(&admin, "author", "{\"name\":\"Hidden\"}", "draft");

        library.ada = ada;
        library.hidden = hidden;

        _ = try create(&admin, "book", try book(&admin, "First", 10, ada), "published");
        _ = try create(&admin, "book", try book(&admin, "Second", 30, ada), "published");
        _ = try create(&admin, "book", try book(&admin, "Unseen", 20, ada), "draft");
        _ = try create(&admin, "book", try book(&admin, "Orphan", 5, hidden), "published");
        _ = try create(&admin, "ledger", "{\"title\":\"Books\"}", "published");
    }

    fn as_admin(library: *Library) sdk.Ctx {
        return library.harness.ctx(.{ .user = .{ .id = "u_admin", .roles = &.{"admin"} } });
    }

    fn deinit(library: *Library) void {
        library.harness.deinit();
    }
};

fn book(ctx: *sdk.Ctx, title: []const u8, views: i64, author: []const u8) ![]const u8 {
    std.debug.assert(title.len > 0);

    const shape = "{{\"title\":\"{s}\",\"views\":{d},\"author\":\"{s}\"}}";

    return std.fmt.allocPrint(ctx.arena, shape, .{
        title,
        views,
        author,
    });
}

fn create(
    ctx: *sdk.Ctx,
    type_handle: []const u8,
    document: []const u8,
    status: []const u8,
) ![]const u8 {
    std.debug.assert(document.len > 0);

    const made = try SDK.dispatch(ctx, record.Create, .{
        .type = type_handle,
        .document = document,
        .status = status,
    });

    return made.id;
}

fn ask(ctx: *sdk.Ctx, query: []const u8) !Query.Out {
    std.debug.assert(query.len > 0);

    return SDK.dispatch(ctx, Query, .{ .query = query });
}

fn contains(text: []const u8, part: []const u8) bool {
    return std.mem.indexOf(u8, text, part) != null;
}

test "query: a visitor reads live public records, a draft reference is null with a problem" {
    var library: Library = .{};
    try library.init();
    defer library.deinit();

    var visitor = library.harness.ctx(.anonymous);
    const books = try ask(&visitor,
        \\*[_type == "book"] | order(views desc) { title, "by": author->name }
    );

    try std.testing.expectEqualStrings(
        \\[{"title":"Second","by":"Ada"},{"title":"First","by":"Ada"},{"title":"Orphan","by":null}]
    , books.result.text);
    try std.testing.expectEqual(@as(usize, 1), books.problems.len);
    try std.testing.expectEqualStrings(library.hidden, books.problems[0].id);
    try std.testing.expectEqualStrings("status", books.problems[0].reason);

    const nested = try ask(&visitor,
        \\*[_type == "author" && name == "Ada"][0]{ name,
        \\  "books": *[_type == "book" && author == ^._id] | order(views asc) { title } }
    );

    try std.testing.expectEqualStrings(
        \\{"name":"Ada","books":[{"title":"First"},{"title":"Second"}]}
    , nested.result.text);
    try std.testing.expectError(error.Denied, ask(&visitor, "*[_type == \"ledger\"]"));

    const perspective = SDK.dispatch(&visitor, Query, .{
        .query = "*[_type == \"book\"]{ title }",
        .perspective = .all,
    });
    const seen = try perspective;

    try std.testing.expect(!contains(seen.result.text, "Unseen"));
}

test "query: an editor reads drafts only when asking for every status" {
    var library: Library = .{};
    try library.init();
    defer library.deinit();

    var admin = library.as_admin();
    const published = try ask(&admin, "*[_type == \"book\"]{ title }");

    try std.testing.expect(!contains(published.result.text, "Unseen"));

    const everything = try SDK.dispatch(&admin, Query, .{
        .query = "*[_type == \"book\"]{ title, \"by\": author->name }",
        .perspective = .all,
    });

    try std.testing.expect(contains(everything.result.text, "Unseen"));
    try std.testing.expect(contains(everything.result.text, "\"Hidden\""));
    try std.testing.expectEqual(@as(usize, 0), everything.problems.len);
}

test "query: a hidden field is as if the type had none; own records are the caller's alone" {
    var library: Library = .{};
    try library.init();
    defer library.deinit();

    var admin = library.as_admin();

    admin.parent = admin.allocate_operation_id();

    const masked: sdk.Grant = .{ .field_mask = &.{"views"} };
    const spread = try Query.run(&admin, .{ .query = "*[_type == \"book\"][0]{ ... }" }, &masked);

    try std.testing.expect(!contains(spread.result.text, "views"));
    try std.testing.expect(contains(spread.result.text, "title"));
    // Filtering on a hidden field is as on a field the type does not have: nothing matches,
    // so the hidden value can never decide what comes back.
    const by_hidden = try Query.run(&admin, .{
        .query = "*[_type == \"book\" && views > 15]{ title }",
    }, &masked);

    try std.testing.expectEqualStrings("[]", by_hidden.result.text);

    var bob = library.harness.ctx(.{ .user = .{ .id = "u_bob", .roles = &.{"editor"} } });

    bob.parent = bob.allocate_operation_id();
    _ = try create(&bob, "book", try book(&bob, "Bob's", 1, library.ada), "published");

    const own: sdk.Grant = .{ .record_filter = .{ .flags = .{ .own_only = true } } };
    const mine = try Query.run(&bob, .{ .query = "*[_type == \"book\"]{ title }" }, &own);

    try std.testing.expectEqualStrings("[{\"title\":\"Bob's\"}]", mine.result.text);
}

test "virtual: an author's books are the books pointing at it, in the order kept, then made" {
    var library: Library = .{};
    try library.init();
    defer library.deinit();

    var visitor = library.harness.ctx(.anonymous);
    const titles = "*[_type == \"author\" && name == \"Ada\"][0]{ \"titles\": books[].title }";
    const made = try ask(&visitor, titles);

    // Live ones only for a visitor, in the order they were made: "Unseen" is a draft.
    try std.testing.expectEqualStrings("{\"titles\":[\"First\",\"Second\"]}", made.result.text);

    var admin = library.as_admin();
    const second = try ask(&admin, "*[_type == \"book\" && title == \"Second\"][0]._id");
    const first = try ask(&admin, "*[_type == \"book\" && title == \"First\"][0]._id");
    const order = try std.fmt.allocPrint(admin.arena, "{{\"books\":[{s},{s}]}}", .{
        second.result.text,
        first.result.text,
    });

    _ = try SDK.dispatch(&admin, record.Save, .{ .id = library.ada, .document = order });
    // Ada is published: the new order is a pending change until it is published too.
    _ = try SDK.dispatch(&admin, record.Publish, .{ .id = library.ada });

    const kept = try ask(&admin, titles);

    try std.testing.expectEqualStrings("{\"titles\":[\"Second\",\"First\"]}", kept.result.text);

    // One level deep: a book's author is its id, not the author with its books again.
    const nested = try ask(&admin, "*[_type == \"author\" && name == \"Ada\"][0].books[0].author");

    const ada_id = try std.fmt.allocPrint(admin.arena, "\"{s}\"", .{library.ada});

    try std.testing.expectEqualStrings(ada_id, nested.result.text);
}

test "virtual: saving the list repoints the records it adds and leaves out" {
    var library: Library = .{};
    try library.init();
    defer library.deinit();

    var admin = library.as_admin();
    const first = try ask(&admin, "*[_type == \"book\" && title == \"First\"][0]._id");
    const orphan = try ask(&admin, "*[_type == \"book\" && title == \"Orphan\"][0]._id");
    // Ada keeps First, drops Second and the draft, takes Orphan from Hidden.
    const list = try std.fmt.allocPrint(admin.arena, "{{\"books\":[{s},{s}]}}", .{
        orphan.result.text,
        first.result.text,
    });

    _ = try SDK.dispatch(&admin, record.Save, .{ .id = library.ada, .document = list });

    const got = try SDK.dispatch(&admin, record.Get, .{ .id = library.ada, .purpose = .edit });
    const expected = try std.fmt.allocPrint(admin.arena, "\"books\":[{s},{s}]", .{
        orphan.result.text,
        first.result.text,
    });

    try std.testing.expect(contains(got.document, expected));

    // A live book's reference changes live: Second has left Ada for site visitors too.
    const live = try ask(&admin, "*[_type == \"book\" && title == \"Second\"][0].author");

    try std.testing.expectEqualStrings("null", live.result.text);
}
