//! Fields plugins add to the rows of a list read: an `after` hook on the read calls
//! `out.extend(row, "loyalty.points", value)` for the whole page at once, only under its own
//! plugin's name. Every caller of the read gets them, as `extended` beside the rows:
//! `{"<row id>": {"loyalty.points": 120}}`. A list read's `Out` carries an `Extended` and an
//! `extend` that hands it the row's id.
const std = @import("std");

const Value = std.json.Value;

pub const Error = error{ Denied, Invalid, OutOfMemory };

/// Fields on one row, at most; rows, at most (a list page holds fewer).
pub const fields_max: u32 = 64;
pub const rows_max: u32 = 1000;

pub const Extended = struct {
    /// Its keys are the rows' ids: described as an object, written by `jsonStringify`.
    pub const json_object = true;

    /// Set by core before the read's `after` hooks run; null on a read nobody extends.
    open: ?*Open = null,

    pub const Open = struct {
        arena: std.mem.Allocator,
        /// The plugin whose hook runs now: it extends only under its own name.
        plugin: *const []const u8,
        rows: std.json.ObjectMap,
    };

    /// A new, empty set of fields, extended as `plugin.*` names whoever runs.
    pub fn start(arena: std.mem.Allocator, plugin: *const []const u8) Error!Extended {
        const open = try arena.create(Open);

        open.* = .{
            .arena = arena,
            .plugin = plugin,
            .rows = .empty,
        };

        return .{
            .open = open,
        };
    }

    /// The set the read's hooks extend, as whoever runs (`plugin.*`) names: this one, or a
    /// new one when the read started none.
    pub fn bound(
        extended: Extended,
        arena: std.mem.Allocator,
        plugin: *const []const u8,
    ) Error!Extended {
        const open = extended.open orelse return start(arena, plugin);

        open.plugin = plugin;

        return extended;
    }

    /// `name` on the row `id`: a field under the running plugin's name (`loyalty.points`).
    pub fn put(extended: Extended, id: []const u8, name: []const u8, value: anytype) Error!void {
        const open = extended.open orelse return error.Invalid;
        const plugin = open.plugin.*;

        std.debug.assert(id.len > 0);

        const own = plugin.len > 0 and std.mem.startsWith(u8, name, plugin) and
            name.len > plugin.len + 1 and name[plugin.len] == '.';

        if (!own) {
            return error.Denied;
        }

        const text = try std.json.Stringify.valueAlloc(open.arena, value, .{});
        const parsed = std.json.parseFromSliceLeaky(Value, open.arena, text, .{}) catch {
            return error.Invalid;
        };

        return extended.set(id, name, parsed);
    }

    /// `name` on the row `id`, whoever's: core's own, a field a plugin stores on the type.
    pub fn set(extended: Extended, id: []const u8, name: []const u8, value: Value) Error!void {
        const open = extended.open orelse return error.Invalid;

        std.debug.assert(id.len > 0);
        std.debug.assert(name.len > 0);

        if (open.rows.count() >= rows_max and open.rows.get(id) == null) {
            return error.Invalid;
        }

        const row = try open.rows.getOrPut(open.arena, id);

        if (!row.found_existing) {
            row.key_ptr.* = try open.arena.dupe(u8, id);
            row.value_ptr.* = .{
                .object = .empty,
            };
        }

        if (row.value_ptr.object.count() >= fields_max) {
            return error.Invalid;
        }

        try row.value_ptr.object.put(open.arena, try open.arena.dupe(u8, name), value);
    }

    /// The field `name` on the row `id`; null when nobody extended it.
    pub fn get(extended: Extended, id: []const u8, name: []const u8) ?Value {
        const open = extended.open orelse return null;
        const row = open.rows.get(id) orelse return null;

        std.debug.assert(name.len > 0);

        return switch (row) {
            .object => |fields| fields.get(name),
            else => null,
        };
    }

    /// Every row's fields, to merge into another set (an installed plugin's, answered back).
    pub fn merge(extended: Extended, from: Value) Error!void {
        const open = extended.open orelse return error.Invalid;
        const rows = switch (from) {
            .object => |object| object,
            else => return error.Invalid,
        };

        for (rows.keys(), rows.values()) |id, fields| {
            const object = switch (fields) {
                .object => |object| object,
                else => return error.Invalid,
            };

            for (object.keys(), object.values()) |name, value| {
                try extended.put(id, name, value);
            }
        }

        std.debug.assert(open.rows.count() >= rows.count() or rows.count() == 0);
    }

    pub fn jsonStringify(extended: Extended, writer: anytype) !void {
        if (extended.open) |open| {
            std.debug.assert(open.rows.count() <= rows_max);

            return writer.write(Value{
                .object = open.rows,
            });
        }

        try writer.beginObject();
        try writer.endObject();
    }

    pub fn jsonParse(
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) std.json.ParseError(@TypeOf(source.*))!Extended {
        const value = try std.json.innerParse(Value, allocator, source, options);

        return jsonParseFromValue(allocator, value, options);
    }

    pub fn jsonParseFromValue(
        allocator: std.mem.Allocator,
        value: Value,
        _: std.json.ParseOptions,
    ) std.json.ParseFromValueError!Extended {
        const rows = switch (value) {
            .object => |object| object,
            else => return error.UnexpectedToken,
        };
        const open = try allocator.create(Open);

        open.* = .{
            .arena = allocator,
            .plugin = &no_plugin,
            .rows = rows,
        };

        return .{
            .open = open,
        };
    }
};

const no_plugin: []const u8 = "";

test "a plugin extends rows only under its own name, and every caller reads them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var plugin: []const u8 = "loyalty";
    const extended = try Extended.start(arena, &plugin);

    try extended.put("u1", "loyalty.points", @as(i64, 120));
    try std.testing.expectError(error.Denied, extended.put("u1", "other.points", 1));
    try std.testing.expectError(error.Denied, extended.put("u1", "loyaltypoints", 1));
    try std.testing.expectEqual(@as(i64, 120), extended.get("u1", "loyalty.points").?.integer);
    try std.testing.expect(extended.get("u2", "loyalty.points") == null);

    const text = try std.json.Stringify.valueAlloc(arena, extended, .{});
    try std.testing.expectEqualStrings("{\"u1\":{\"loyalty.points\":120}}", text);

    const read = try std.json.parseFromSliceLeaky(Extended, arena, text, .{});
    try std.testing.expectEqual(@as(i64, 120), read.get("u1", "loyalty.points").?.integer);

    plugin = "other";
    try std.testing.expectError(error.Denied, extended.merge(.{
        .object = read.open.?.rows,
    }));
}
