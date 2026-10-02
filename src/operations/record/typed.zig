//! A plugin's records as typed values, never JSON text: `publr.records.of(Order, "order")`.
//! Every call is an ordinary record operation through `ctx.call`, so a native and a
//! sandboxed plugin take the same path and the same checks. Reads give the live document
//! and ignore fields the type does not name; a save writes only the fields it is given.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const record = @import("../record.zig");
const PluginCtx = @import("../../sdk/plugin/context.zig").PluginCtx;

const Error = sdk.Error;

/// One record: its id, version and status, and its document as `Document`.
pub fn Record(comptime Document: type) type {
    return struct {
        id: []const u8,
        version: i64,
        status: []const u8,
        changed: bool,
        value: Document,
    };
}

pub const Create = struct {
    /// The status it starts in; the type's initial one (`draft`) when null.
    status: ?[]const u8 = null,
};

pub const Save = struct {
    /// Refuse the save if the record's version moved since it was read.
    expected_version: ?i64 = null,
    /// Write straight into the live document and end in this status (see `record save`).
    status: ?[]const u8 = null,
};

pub const Page = struct { limit: u32 = 50, offset: u32 = 0 };

/// The records of content type `handle`, whose documents are `Document`.
pub fn of(comptime Document: type, comptime handle: []const u8) type {
    comptime std.debug.assert(@typeInfo(Document) == .@"struct");
    comptime std.debug.assert(handle.len > 0);

    return struct {
        pub const Item = Record(Document);

        /// The live record; not found when it is another type's or has never been live.
        pub fn get(ctx: *PluginCtx, id: []const u8) Error!Item {
            std.debug.assert(id.len > 0);

            const got = try ctx.call(record.Get, .{ .id = id });

            if (!std.mem.eql(u8, got.record.type, handle)) {
                return error.NotFound;
            }

            return item(ctx, got.record, got.document);
        }

        /// The one record whose unique `field` holds `value`, or null; two make a conflict.
        pub fn find_one(
            ctx: *PluginCtx,
            comptime field: std.meta.FieldEnum(Document),
            value: anytype,
        ) Error!?Item {
            const text = try filter_text(ctx, value);
            const listed = try ctx.call(record.List, .{
                .type = handle,
                .filter_field = @tagName(field),
                .filter_value = text,
                .limit = 2,
            });

            std.debug.assert(listed.records.len <= 2);

            if (listed.records.len > 1) {
                return error.Conflict;
            }

            if (listed.records.len == 0) {
                return null;
            }

            return try get(ctx, listed.records[0].id);
        }

        /// A new record holding `value`; its id.
        pub fn create(ctx: *PluginCtx, value: Document, options: Create) Error![]const u8 {
            const document = try encode(ctx, value);
            const created = try ctx.call(record.Create, .{
                .type = handle,
                .document = document,
                .status = options.status,
            });

            std.debug.assert(created.id.len > 0);

            return created.id;
        }

        /// Writes `fields`, a struct naming some of the document's fields; the others keep
        /// their values.
        pub fn save(
            ctx: *PluginCtx,
            id: []const u8,
            fields: anytype,
            options: Save,
        ) Error!record.Save.Out {
            comptime check_fields(@TypeOf(fields));
            std.debug.assert(id.len > 0);

            const document = try encode(ctx, fields);

            return ctx.call(record.Save, .{
                .id = id,
                .document = document,
                .expected_version = options.expected_version,
                .status = options.status,
            });
        }

        /// A page of records, newest first; `where` is `.{}` or names one field:
        /// `.{ .product = product_id }`.
        pub fn find(ctx: *PluginCtx, where: anytype, page: Page) Error![]const Item {
            const Where = @TypeOf(where);
            const keys = comptime std.meta.fieldNames(Where);

            comptime check_fields(Where);
            comptime std.debug.assert(keys.len <= 1);

            const field: ?[]const u8 = if (keys.len == 1) keys[0] else null;
            const value: ?[]const u8 = if (keys.len == 1)
                try filter_text(ctx, @field(where, keys[0]))
            else
                null;
            const listed = try ctx.call(record.List, .{
                .type = handle,
                .filter_field = field,
                .filter_value = value,
                .order = .created_desc,
                .limit = page.limit,
                .offset = page.offset,
            });
            const items = try ctx.arena().alloc(Item, listed.records.len);

            for (listed.records, items) |row, *target| {
                target.* = try get(ctx, row.id);
            }

            return items;
        }

        fn item(ctx: *PluginCtx, row: record.Record, document: []const u8) Error!Item {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(document.len > 0);

            const value = std.json.parseFromSliceLeaky(Document, ctx.arena(), document, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch return error.Invalid;

            return .{
                .id = row.id,
                .version = row.version,
                .status = row.status,
                .changed = row.changed,
                .value = value,
            };
        }

        fn check_fields(comptime Fields: type) void {
            comptime {
                if (@typeInfo(Fields) != .@"struct") {
                    @compileError("records: fields are a struct literal, `.{ .name = value }`");
                }

                for (std.meta.fieldNames(Fields)) |name| {
                    if (!@hasField(Document, name)) {
                        const document_name = @typeName(Document);

                        @compileError("records: " ++ document_name ++ " has no field " ++ name);
                    }
                }
            }
        }
    };
}

fn encode(ctx: *PluginCtx, value: anytype) Error![]const u8 {
    const options: std.json.Stringify.Options = .{ .emit_null_optional_fields = false };
    const text = std.json.Stringify.valueAlloc(ctx.arena(), value, options) catch {
        return error.OutOfMemory;
    };

    std.debug.assert(text.len > 0);
    std.debug.assert(text[0] == '{');

    return text;
}

/// How `record list` matches a field: text as it is, numbers in decimal, `true`/`false`, a
/// reference by its target's id.
fn filter_text(ctx: *PluginCtx, value: anytype) Error![]const u8 {
    const Value = @TypeOf(value);

    std.debug.assert(ctx.now_ms() >= 0);

    return switch (@typeInfo(Value)) {
        .int, .comptime_int => std.fmt.allocPrint(ctx.arena(), "{d}", .{value}) catch {
            return error.OutOfMemory;
        },
        .bool => if (value) "true" else "false",
        .@"enum" => @tagName(value),
        else => @as([]const u8, value),
    };
}

const registry = @import("../../server/registry.zig");
const fixture = @import("fixture.zig");

const Post = struct {
    title: []const u8,
    body: []const u8 = "",
    views: i64 = 0,
};
const posts = of(Post, "post");

test "typed records: create, get, save a field, find one, find many" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);
    try fixture.post_type(&system);

    system.parent = system.allocate_operation_id();
    var ctx: PluginCtx = .{ .inner = &system };
    const first = try posts.create(&ctx, .{ .title = "One", .body = "first", .views = 1 }, .{
        .status = "published",
    });
    _ = try posts.create(&ctx, .{ .title = "Two" }, .{});

    const got = try posts.get(&ctx, first);
    try std.testing.expectEqualStrings("One", got.value.title);
    try std.testing.expectEqualStrings("published", got.status);
    try std.testing.expectEqual(@as(i64, 1), got.value.views);

    _ = try posts.save(&ctx, first, .{ .views = 9 }, .{
        .expected_version = got.version,
        .status = "published",
    });
    const saved = try posts.get(&ctx, first);
    try std.testing.expectEqual(@as(i64, 9), saved.value.views);
    try std.testing.expectEqualStrings("first", saved.value.body);

    const stale = posts.save(&ctx, first, .{ .views = 10 }, .{ .expected_version = got.version });
    try std.testing.expectError(error.Conflict, stale);

    const found = (try posts.find_one(&ctx, .views, 9)).?;
    try std.testing.expectEqualStrings(first, found.id);
    try std.testing.expect(try posts.find_one(&ctx, .title, "Nobody") == null);

    _ = try posts.create(&ctx, .{ .title = "Two" }, .{});
    try std.testing.expectError(error.Conflict, posts.find_one(&ctx, .title, "Two"));

    const every = try posts.find(&ctx, .{}, .{});
    try std.testing.expectEqual(@as(usize, 3), every.len);

    const viewed = try posts.find(&ctx, .{ .views = 9 }, .{});
    try std.testing.expectEqual(@as(usize, 1), viewed.len);
    try std.testing.expectEqualStrings("One", viewed[0].value.title);
}

test "typed records: another type's record is not found" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try registry.SDK.bootstrap(&system);
    try fixture.post_type(&system);

    system.parent = system.allocate_operation_id();
    var ctx: PluginCtx = .{ .inner = &system };
    const id = try posts.create(&ctx, .{ .title = "One" }, .{});
    const others = of(struct { title: []const u8 }, "page");

    try std.testing.expectError(error.NotFound, others.get(&ctx, id));
}
