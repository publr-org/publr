//! A reference to a record as an operation input takes it: `Entries.Ref`, from the record's
//! `publr.record.define` or `publr.remote.record`.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const PluginCtx = @import("../../sdk/plugin/context.zig").PluginCtx;

const Error = sdk.Error;

/// An operation input naming a record of content type `handle`: the caller sends its id,
/// and core reads the record, with the caller's access, before the operation runs. Unknown,
/// of another type, or not one the caller may see: the call is refused (`not found`). The
/// operation reads `.value.?`, the stored record, never anything the caller sent about it.
pub fn Ref(comptime Doc: type, comptime type_handle: []const u8) type {
    comptime std.debug.assert(@typeInfo(Doc) == .@"struct");
    comptime std.debug.assert(type_handle.len > 0);

    return struct {
        id: []const u8,
        /// The stored record; filled by core before the operation runs.
        value: ?Doc = null,

        pub const Document = Doc;
        pub const handle = type_handle;
        pub const reference = true;

        const Resolved = struct {
            id: []const u8,
            value: ?Doc = null,
        };

        /// An id, as callers send it, or `{ id, value }`, as core hands it on.
        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!@This() {
            if (try source.peekNextTokenType() == .string) {
                const id = try std.json.innerParse([]const u8, allocator, source, options);

                // A reference names a record: an empty one names none.
                if (id.len == 0) {
                    return error.UnexpectedToken;
                }

                return .{
                    .id = id,
                };
            }

            const resolved = try std.json.innerParse(Resolved, allocator, source, options);

            if (resolved.id.len == 0) {
                return error.UnexpectedToken;
            }

            return .{
                .id = resolved.id,
                .value = resolved.value,
            };
        }

        pub fn jsonParseFromValue(
            allocator: std.mem.Allocator,
            source: std.json.Value,
            options: std.json.ParseOptions,
        ) std.json.ParseFromValueError!@This() {
            if (source == .string) {
                if (source.string.len == 0) {
                    return error.UnexpectedToken;
                }

                return .{
                    .id = source.string,
                };
            }

            const resolved = try std.json.innerParseFromValue(Resolved, allocator, source, options);

            if (resolved.id.len == 0) {
                return error.UnexpectedToken;
            }

            return .{
                .id = resolved.id,
                .value = resolved.value,
            };
        }

        /// The id alone, whatever the record holds: what an input takes and a log keeps.
        pub fn jsonStringify(self: @This(), writer: anytype) !void {
            std.debug.assert(self.id.len > 0);

            return writer.write(self.id);
        }
    };
}

const registry = @import("../../server/registry.zig");
const fixture = @import("fixture.zig");

const Post = struct {
    title: []const u8,
    body: []const u8 = "",
    views: i64 = 0,
};
const posts = @import("../../sdk/plugin/record_define.zig").Store(Post, "post", false);

test "a record's reads and writes: create, get, save a field, find one" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);
    try fixture.post_type(&system);

    system.parent = system.allocate_operation_id();
    var ctx: PluginCtx = .{
        .inner = &system,
    };
    const first = try posts.create(&ctx, .{
        .title = "One",
        .body = "first",
        .views = 1,
    });
    _ = try posts.create(&ctx, .{
        .title = "Two",
    });

    const got = try posts.get(&ctx, first);
    try std.testing.expectEqualStrings("One", got.value.title);
    try std.testing.expectEqualStrings("draft", got.status);
    try std.testing.expectEqual(@as(i64, 1), got.value.views);

    try posts.save(&ctx, first, .{
        .views = 9,
    });
    const saved = try posts.get(&ctx, first);
    try std.testing.expectEqual(@as(i64, 9), saved.value.views);
    try std.testing.expectEqualStrings("first", saved.value.body);

    const found = (try posts.find_one(&ctx, "views", 9)).?;
    try std.testing.expectEqualStrings(first, found.id);
    try std.testing.expect(try posts.find_one(&ctx, "title", "Nobody") == null);

    _ = try posts.create(&ctx, .{
        .title = "Two",
    });
    try std.testing.expectError(error.Conflict, posts.find_one(&ctx, "title", "Two"));

    const pages = @import("../../sdk/plugin/record_define.zig").Store(Post, "page", false);
    try std.testing.expectError(error.NotFound, pages.get(&ctx, first));
}

const sdk_root = @import("../../sdk.zig");
const record_operations = @import("../record.zig");

const Takes = struct {
    pub const name = "test.takes";
    pub const description = "Test operation: the titles of the posts named";
    pub const kind: sdk_root.operation.Kind = .read;
    pub const open = true;
    pub const In = struct {
        post: Ref(Post, "post"),
        more: []const Ref(Post, "post") = &.{},
    };
    pub const Out = struct {
        title: []const u8,
        more: u32,
    };
    pub const example: In = .{
        .post = .{
            .id = "x",
        },
    };
    pub const example_out: Out = .{
        .title = "x",
        .more = 0,
    };

    pub fn run(_: *sdk_root.Ctx, in: In, _: *const sdk_root.Grant) Error!Out {
        std.debug.assert(in.post.id.len > 0);

        for (in.more) |more| {
            std.debug.assert(more.value != null);
        }

        return .{
            .title = in.post.value.?.title,
            .more = @intCast(in.more.len),
        };
    }
};

test "references: core reads the record named, as the caller may see it" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);
    try fixture.post_type(&system);

    system.parent = system.allocate_operation_id();
    var ctx: PluginCtx = .{
        .inner = &system,
    };
    const live = try posts.create(&ctx, .{
        .title = "Live",
    });
    const other = try posts.create(&ctx, .{
        .title = "Other",
    });
    const draft = try posts.create(&ctx, .{
        .title = "Draft",
    });

    for ([_][]const u8{ live, other }) |id| {
        _ = try registry.SDK.dispatch(&system, record_operations.Transition, .{
            .id = id,
            .transition = "publish",
        });
    }

    const operations = record_operations.operations ++ [_]type{Takes};
    const Checked = sdk_root.SDK(.{
        .operations = &operations,
    });
    var visitor = harness.ctx(.anonymous);

    const read = try Checked.dispatch(&visitor, Takes, .{
        .post = .{
            .id = live,
        },
        .more = &.{ .{
            .id = other,
        }, .{
            .id = live,
        } },
    });
    try std.testing.expectEqualStrings("Live", read.title);
    try std.testing.expectEqual(@as(u32, 2), read.more);

    const unseen = Checked.dispatch(&visitor, Takes, .{
        .post = .{
            .id = draft,
        },
    });
    try std.testing.expectError(error.NotFound, unseen);

    const unknown = Checked.dispatch(&visitor, Takes, .{
        .post = .{
            .id = "nope",
        },
    });
    try std.testing.expectError(error.NotFound, unknown);

    const Pages = Ref(Post, "page");
    const arena = harness.fixed.allocator();
    const parsed = try std.json.parseFromSliceLeaky(Pages, arena, "\"abc\"", .{});
    try std.testing.expectEqualStrings("abc", parsed.id);
}
