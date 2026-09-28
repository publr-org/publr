//! What the dependency index holds for a record or its type: the keys a change to it
//! raises, and every built artifact (a page, a fragment) that recorded reading one of them.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const deps = @import("../../lib/deps.zig");
const changes = @import("changes.zig");
const content_type = @import("../../model/content_type.zig");
const records = @import("../../store/records.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const Artifact = struct {
    /// The artifact as the build names it: a page's URL, or `/_islands/<key>`.
    name: []const u8,
    /// The keys it recorded, among those the change raises, in the order raised.
    keys: []const []const u8,
};

/// Artifacts one change may reach; past it the index itself refuses the batch.
pub const artifacts_max: u32 = 4096;

pub const Impact = struct {
    pub const name = "site.impact";
    pub const description =
        "What a change to a record rebuilds: the keys it raises and the built artifacts " ++
        "that recorded them";
    pub const details =
        \\Reads the dependency index the site's builds fill: every rendered page and fragment
        \\records the record ids and types it read, and a change to a record raises
        \\`record:<id>`, `type:<handle>` and `records`. This lists those keys for the record
        \\(or, without an id, for a record of the type that does not exist yet) and every
        \\artifact that recorded any of them: exactly what the next quiet moment rebuilds.
        \\Signed-in users may call it. Nothing is written. An empty list, as in the example,
        \\means no build has recorded the keys yet (a fresh install, or a site that renders
        \\live); after `publr build` a post's page answers, for instance, `{ "name":
        \\"/posts/hello", "keys": ["record:<id>", "type:post", "records"] }`.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct { type: []const u8, id: ?[]const u8 = null };
    pub const Out = struct { keys: []const []const u8, artifacts: []const Artifact };
    pub const example: In = .{ .type = "post", .id = "a1b2c3d4e5f60718293a4b5c" };
    pub const example_out: Out = .{
        .keys = &.{ "record:a1b2c3d4e5f60718293a4b5c", "type:post", "records" },
        .artifacts = &.{},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .type = "The record type's handle",
        .id = "The record; omitted for one that does not exist yet",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .keys = "The keys a change raises, in the order they are raised",
        .artifacts = "Every artifact that recorded one of the keys, once, by name, with the " ++
            "keys it recorded",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(changes.key_len_max > 0);

        if (in.type.len == 0 or in.type.len > content_type.handle_len_max) {
            return error.Invalid;
        }

        if (in.id) |id| {
            if (id.len == 0 or id.len > records.id_len) {
                return error.Invalid;
            }
        }

        const keys = try keys_of(ctx.arena, in);
        var index: deps.Index = .{ .db = ctx.db, .options = .{ .quiet_ms = deps.quiet_ms } };
        var artifacts: std.ArrayList(Artifact) = .empty;

        for (keys) |key| {
            const names = index.affected(ctx.arena, &.{key}) catch |err| switch (err) {
                error.FanOutExceeded,
                error.NameTooLong,
                error.InvalidLimit,
                error.UncommittedRead,
                => return error.Invalid,
                else => |other| return other,
            };

            for (names) |artifact| {
                try add(ctx.arena, &artifacts, artifact, key);
            }
        }

        std.mem.sort(Artifact, artifacts.items, {}, by_name);

        std.debug.assert(keys.len == 2 or keys.len == 3);

        return .{ .keys = keys, .artifacts = artifacts.items };
    }
};

/// The key onto the artifact's row, the row made on its first key. Keys arrive in the
/// order raised and each artifact is named once per key, so no key repeats on a row.
fn add(
    arena: std.mem.Allocator,
    artifacts: *std.ArrayList(Artifact),
    name: []const u8,
    key: []const u8,
) Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(key.len > 0);

    for (artifacts.items) |*artifact| {
        if (std.mem.eql(u8, artifact.name, name)) {
            const grown = try arena.alloc([]const u8, artifact.keys.len + 1);

            @memcpy(grown[0..artifact.keys.len], artifact.keys);
            grown[artifact.keys.len] = key;
            artifact.keys = grown;

            return;
        }
    }

    if (artifacts.items.len == artifacts_max) {
        return error.Invalid;
    }

    try artifacts.append(arena, .{ .name = name, .keys = try arena.dupe([]const u8, &.{key}) });
}

fn by_name(_: void, left: Artifact, right: Artifact) bool {
    std.debug.assert(left.name.len > 0);
    std.debug.assert(right.name.len > 0);

    return std.mem.lessThan(u8, left.name, right.name);
}

/// `record:<id>` (when there is a record), `type:<handle>`, `records`: what `changes`
/// raises for the record, in that order.
fn keys_of(arena: std.mem.Allocator, in: Impact.In) Error![]const []const u8 {
    std.debug.assert(in.type.len > 0);

    if (in.type.len > content_type.handle_len_max) {
        return error.Invalid;
    }

    var record_buffer: [changes.key_len_max]u8 = undefined;
    var type_buffer: [changes.key_len_max]u8 = undefined;
    var keys: std.ArrayList([]const u8) = .empty;

    if (in.id) |id| {
        const key = changes.record_key(&record_buffer, id) catch return error.Invalid;

        try keys.append(arena, try arena.dupe(u8, key));
    }

    const type_key = changes.type_key(&type_buffer, in.type) catch return error.Invalid;

    try keys.append(arena, try arena.dupe(u8, type_key));
    try keys.append(arena, changes.all_records_key);

    return keys.items;
}

const TestSDK = sdk.SDK(.{ .operations = &.{Impact} });

test "the keys of a record and of a type alone; the artifacts the index recorded for them" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var index = try deps.Index.open(&harness.fixture.connection, .{
        .quiet_ms = deps.quiet_ms,
    });
    try index.record("/", &.{ "type:post", "records", "template:content/index.publr" });
    try index.record("/_islands/latest", &.{ "type:post", "records" });
    try index.record("/posts/hello", &.{ "record:abc", "type:post", "records" });
    try index.record("/about", &.{"template:content/about.publr"});

    var editor = harness.ctx(.{ .user = .{ .id = "u1", .role = .editor } });
    const with_id = try TestSDK.dispatch(&editor, Impact, .{ .type = "post", .id = "abc" });
    try std.testing.expectEqual(@as(usize, 3), with_id.keys.len);
    try std.testing.expectEqualStrings("record:abc", with_id.keys[0]);
    try std.testing.expectEqualStrings("type:post", with_id.keys[1]);
    try std.testing.expectEqualStrings("records", with_id.keys[2]);
    try std.testing.expectEqual(@as(usize, 3), with_id.artifacts.len);
    try std.testing.expectEqualStrings("/", with_id.artifacts[0].name);
    try std.testing.expectEqual(@as(usize, 2), with_id.artifacts[0].keys.len);
    try std.testing.expectEqualStrings("type:post", with_id.artifacts[0].keys[0]);
    try std.testing.expectEqualStrings("records", with_id.artifacts[0].keys[1]);
    try std.testing.expectEqualStrings("/_islands/latest", with_id.artifacts[1].name);
    try std.testing.expectEqualStrings("/posts/hello", with_id.artifacts[2].name);
    try std.testing.expectEqual(@as(usize, 3), with_id.artifacts[2].keys.len);
    try std.testing.expectEqualStrings("record:abc", with_id.artifacts[2].keys[0]);

    const new_record = try TestSDK.dispatch(&editor, Impact, .{ .type = "note" });
    try std.testing.expectEqual(@as(usize, 2), new_record.keys.len);
    try std.testing.expectEqualStrings("type:note", new_record.keys[0]);
    try std.testing.expectEqual(@as(usize, 3), new_record.artifacts.len);
    try std.testing.expectEqual(@as(usize, 1), new_record.artifacts[0].keys.len);
    try std.testing.expectEqualStrings("records", new_record.artifacts[0].keys[0]);

    try std.testing.expectError(error.Invalid, TestSDK.dispatch(&editor, Impact, .{
        .type = "",
    }));
    try std.testing.expectError(error.Invalid, TestSDK.dispatch(&editor, Impact, .{
        .type = "post",
        .id = "",
    }));

    var anon = harness.ctx(.anonymous);
    try std.testing.expectError(error.Denied, TestSDK.dispatch(&anon, Impact, Impact.example));
}
