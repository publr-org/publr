//! A plugin's internal records as typed values: `publr.internal.of(Movement, "movement")`.
//! Every call is an `internal` operation through `ctx.call`, so it reaches the calling
//! plugin's own records in the request's app, compiled in or installed alike.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const internal = @import("../internal.zig");
const PluginCtx = @import("../../sdk/plugin/context.zig").PluginCtx;

const Error = sdk.Error;

/// One record: its id and version, and its document as `Document`.
pub fn Record(comptime Document: type) type {
    return struct { id: []const u8, version: i64, value: Document };
}

pub const Page = sdk.operation.Page;

/// The calling plugin's records of collection `kind`, whose documents are `Document`.
pub fn of(comptime Document: type, comptime kind: []const u8) type {
    comptime std.debug.assert(@typeInfo(Document) == .@"struct");
    comptime std.debug.assert(kind.len > 0);

    return struct {
        pub const Item = Record(Document);

        pub fn get(ctx: *PluginCtx, id: []const u8) Error!Item {
            std.debug.assert(id.len > 0);

            const got = try ctx.call(internal.Get, .{ .kind = kind, .id = id });

            return item(ctx, got);
        }

        /// The one record whose indexed `field` holds `value`, or null; two make a conflict.
        pub fn find_one(
            ctx: *PluginCtx,
            comptime field: std.meta.FieldEnum(Document),
            value: anytype,
        ) Error!?Item {
            const text = try filter_text(ctx, value);
            const found = try ctx.call(internal.FindOne, .{
                .kind = kind,
                .field = @tagName(field),
                .value = text,
            });
            const record = found.record orelse return null;

            return try item(ctx, record);
        }

        /// A page of records, newest first; `where` is `.{}` or names one indexed field.
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
            const found = try ctx.call(internal.Find, .{
                .kind = kind,
                .field = field,
                .value = value,
                .limit = page.limit,
                .offset = page.offset,
            });
            const items = ctx.arena().alloc(Item, found.records.len) catch {
                return error.OutOfMemory;
            };

            for (found.records, items) |record, *target| {
                target.* = try item(ctx, record);
            }

            return items;
        }

        /// A new record holding `value`; its id.
        pub fn create(ctx: *PluginCtx, value: Document) Error![]const u8 {
            const created = try ctx.call(internal.Create, .{
                .kind = kind,
                .document = try encode(ctx, value),
            });

            std.debug.assert(created.id.len > 0);

            return created.id;
        }

        /// Writes `fields`, naming some of the document's fields; the others keep their
        /// values. Its new version.
        pub fn save(
            ctx: *PluginCtx,
            id: []const u8,
            fields: anytype,
            expected_version: ?i64,
        ) Error!i64 {
            comptime check_fields(@TypeOf(fields));
            std.debug.assert(id.len > 0);

            const saved = try ctx.call(internal.Save, .{
                .kind = kind,
                .id = id,
                .document = try encode(ctx, fields),
                .expected_version = expected_version,
            });

            return saved.version;
        }

        /// Whether the record was there to delete.
        pub fn delete(ctx: *PluginCtx, id: []const u8) Error!bool {
            std.debug.assert(id.len > 0);

            const deleted = try ctx.call(internal.Delete, .{ .kind = kind, .id = id });

            return deleted.deleted;
        }

        fn item(ctx: *PluginCtx, record: internal.Item) Error!Item {
            std.debug.assert(record.id.len > 0);
            std.debug.assert(record.document.len > 0);

            const value = std.json.parseFromSliceLeaky(Document, ctx.arena(), record.document, .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            }) catch return error.Invalid;

            return .{ .id = record.id, .version = record.version, .value = value };
        }

        fn check_fields(comptime Fields: type) void {
            comptime {
                if (@typeInfo(Fields) != .@"struct") {
                    @compileError("internal: fields are a struct literal, `.{ .name = value }`");
                }

                for (std.meta.fieldNames(Fields)) |name| {
                    if (!@hasField(Document, name)) {
                        const document_name = @typeName(Document);

                        @compileError("internal: " ++ document_name ++ " has no field " ++ name);
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

/// An indexed value as the index keeps it: text as it is, integers in decimal,
/// `true`/`false`.
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

const Visit = struct { name: []const u8, count: i64 = 0 };
const visits = of(Visit, "visit");

test "typed internal records: create, get, save a field, find one, find many, delete" {
    var project: internal.TestProject = undefined;
    try project.init();
    defer project.deinit();

    var running = project.ctx(.anonymous);
    running.plugin = "greeter";
    running.parent = running.allocate_operation_id();

    var ctx: PluginCtx = .{ .inner = &running };
    const ada = try visits.create(&ctx, .{ .name = "Ada", .count = 1 });
    _ = try visits.create(&ctx, .{ .name = "Bob" });

    const version = try visits.save(&ctx, ada, .{ .count = 5 }, 1);
    try std.testing.expectEqual(@as(i64, 2), version);

    const got = try visits.get(&ctx, ada);
    try std.testing.expectEqualStrings("Ada", got.value.name);
    try std.testing.expectEqual(@as(i64, 5), got.value.count);

    const found = (try visits.find_one(&ctx, .name, "Ada")).?;
    try std.testing.expectEqualStrings(ada, found.id);
    try std.testing.expect(try visits.find_one(&ctx, .name, "Nobody") == null);

    const every = try visits.find(&ctx, .{}, .{});
    try std.testing.expectEqual(@as(usize, 2), every.len);

    const named = try visits.find(&ctx, .{ .name = "Bob" }, .{});
    try std.testing.expectEqual(@as(usize, 1), named.len);

    try std.testing.expect(try visits.delete(&ctx, ada));
    try std.testing.expectError(error.NotFound, visits.get(&ctx, ada));
}

test "references in an installed plugin: the relay reads the record before it runs" {
    var project: internal.TestProject = undefined;
    try project.init();
    defer project.deinit();

    var system = project.ctx(.system);
    try @import("../record/fixture.zig").post_type(&system);

    const records = @import("../record.zig");
    const SDK = @import("../../server/registry.zig").SDK;
    const created = try SDK.dispatch(&system, records.Create, .{
        .type = "post",
        .document = "{\"title\":\"From the sandbox\"}",
        .status = "published",
    });
    const asked = try std.fmt.allocPrint(system.arena, "{{\"post\":\"{s}\"}}", .{created.id});
    const answer = try SDK.call_json(&system, "greeter.recall", asked);

    try std.testing.expect(std.mem.indexOf(u8, answer, "From the sandbox") != null);

    const unknown = SDK.call_json(&system, "greeter.recall", "{\"post\":\"nope\"}");
    try std.testing.expectError(error.NotFound, unknown);
}

test "rules in an installed plugin: the relay refuses a field that breaks one" {
    var project: internal.TestProject = undefined;
    try project.init();
    defer project.deinit();

    var system = project.ctx(.system);
    const SDK = @import("../../server/registry.zig").SDK;
    const long = "{\"note\":\"" ++ "x" ** 201 ++ "\"}";
    const refused = SDK.call_json(&system, "greeter.greet", long);

    try std.testing.expectError(error.Failed, refused);
    try std.testing.expect(std.mem.indexOf(u8, system.failure.?.message, "note") != null);
}
