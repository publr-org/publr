const std = @import("std");
const testing = @import("../testing.zig");

const Site = testing.Site;
const Who = testing.Who;

test "a site answers each caller as it would, runs its queue and opens other databases" {
    const roles = @import("../operations/role.zig");

    var site: Site = undefined;
    try site.init();
    defer site.deinit();

    try std.testing.expect(site.has("role.list"));
    try std.testing.expect(!site.has("nobody.nothing"));

    const listed = try site.call(roles.List, .admin, .{});

    try std.testing.expect(listed.roles.len > 0);
    try std.testing.expectError(error.Denied, site.call(roles.List, .{
        .visitor = "v_1",
    }, .{}));
    try std.testing.expectError(error.Denied, site.call(roles.List, .{
        .plugin = .{
            .name = "nobody",
        },
    }, .{}));
    try std.testing.expectEqualStrings("", site.failure);

    const text = try site.json(.admin, "role.list", "{}");

    try std.testing.expect(std.mem.indexOf(u8, text, "\"admin\"") != null);
    try std.testing.expectError(error.Denied, site.json(.{
        .user = .{
            .id = "u_1",
        },
    }, "role.list", "{}"));

    site.now_ms = 1_900_000_000_000;

    const as_admin = try site.ctx(.admin);

    try std.testing.expectEqual(@as(i64, 1_900_000_000_000), as_admin.now().ms);
    try std.testing.expectEqualStrings("u_admin", as_admin.caller().user_id().?);

    const computer: Who = .{
        .device = .{
            .user = .{
                .id = "u_admin",
                .roles = &.{"admin"},
            },
            .scope = .publish,
            .name = "laptop",
        },
    };
    const seen = (try site.ctx(computer)).caller();

    try std.testing.expect(seen.device);
    try std.testing.expect(seen.device_scope.? == .publish);
    try std.testing.expectEqualStrings("laptop", seen.device_name);
    try std.testing.expectEqualStrings("u_admin", seen.user_id().?);
    try std.testing.expect((try site.call(roles.List, computer, .{})).roles.len > 0);
    _ = try site.drain();
    _ = try site.deliver(.{
        .channel = "email",
        .to = "ada@example.com",
        .subject = "Hello",
        .text = "Hello, Ada",
    });

    var folder = std.testing.tmpDir(.{});
    defer folder.cleanup();

    const memory = site.keep.allocator();
    const root = try folder.dir.realPathFileAlloc(std.testing.io, ".", memory);
    const path = try std.fmt.allocPrintSentinel(memory, "{s}/copy.db", .{root}, 0);
    const made = try site.new_database(memory, path);

    made.close(memory);

    const opened = try site.databases().open(memory, path);
    defer opened.close(memory);

    try opened.run("SELECT 1 FROM users LIMIT 0");

    const copied = try std.fmt.allocPrint(memory, "{s}/copied.db", .{root});

    try opened.copy_to(copied);

    const Any = @import("../extend/database_any.zig").Any;
    var one = try opened.prepare("SELECT 1, 'a', NULL", .{});
    defer one.finalize();

    try std.testing.expect(try one.step());

    const read = try one.read(struct {
        number: Any,
        text: Any,
        nothing: Any,
    }, memory);

    try std.testing.expectEqual(@as(i64, 1), read.number.integer);
    try std.testing.expectEqualStrings("a", read.text.text);
    try std.testing.expect(read.nothing == .null);
    try std.testing.expect(!opened.in_transaction());
}

test "a refused input's problems reach the test, each beside its field" {
    const internal = @import("../operations/internal.zig");

    var site: Site = undefined;
    try site.init();
    defer site.deinit();

    const Json = @import("../operation.zig").Json;
    const blank: Json = .{
        .text = "{}",
    };
    const empty: [internal.many_max + 1]Json = @splat(blank);
    const keeper: Who = .{
        .plugin = .{
            .name = "keeper",
        },
    };

    try std.testing.expectError(error.Invalid, site.call(internal.CreateMany, keeper, .{
        .kind = "note",
        .documents = &empty,
    }));
    try std.testing.expectEqualStrings("documents", site.problems()[0].field);
    try std.testing.expect(site.problems()[0].message.len > 0);
    _ = try site.call(@import("../operations/role.zig").List, .admin, .{});
    try std.testing.expectEqual(@as(usize, 0), site.problems().len);
}
