//! `Extended` (`extended.zig`) as an installed plugin's module holds it: the rows' fields as
//! a value read where it lies, handed over with the list read's answer; what the plugin's
//! own `after` hook adds is kept beside them and written into one value when the hook is
//! done (`seal`), which Publr merges under the plugin's name.
const std = @import("std");
const free_value = @import("free_value.zig");
const free_builder = @import("free_builder.zig");
const free_typed = @import("free_typed.zig");
const Json = @import("operation/json.zig").Laid;

pub const Error = error{ Denied, Invalid, OutOfMemory };

pub const fields_max: u32 = 64;
pub const rows_max: u32 = 1000;

pub const Extended = struct {
    /// Null on a read nobody extends.
    open: ?*Open = null,

    pub const publr_form = .inner;
    pub const json_object = true;

    pub const Open = struct {
        /// `{ "<row id>": { "loyalty.points": 120 } }`.
        rows: Json = .{},
        /// Set while the plugin's own hook adds fields.
        adding: ?*Adding = null,

        pub const publr_form = .inner;
        pub const publr_local = .{"adding"};
    };

    const Added = struct {
        id: []const u8,
        name: []const u8,
        value: free_value.Value,
    };

    pub const Adding = struct {
        arena: std.mem.Allocator,
        plugin: *const []const u8,
        added: std.ArrayList(Added) = .empty,
    };

    /// A new, empty set of fields, extended as `plugin.*` names whoever runs.
    pub fn start(arena: std.mem.Allocator, plugin: *const []const u8) Error!Extended {
        const open = try arena.create(Open);
        const adding = try arena.create(Adding);

        std.debug.assert(plugin.len > 0);

        adding.* = .{
            .arena = arena,
            .plugin = plugin,
        };
        open.* = .{
            .adding = adding,
        };

        return .{
            .open = open,
        };
    }

    /// `name` on the row `id`: a field under the running plugin's name (`loyalty.points`).
    pub fn put(extended: Extended, id: []const u8, name: []const u8, value: anytype) Error!void {
        const open = extended.open orelse return error.Invalid;
        const adding = open.adding orelse return error.Invalid;
        const plugin = adding.plugin.*;

        std.debug.assert(id.len > 0);

        const own = plugin.len > 0 and std.mem.startsWith(u8, name, plugin) and
            name.len > plugin.len + 1 and name[plugin.len] == '.';

        if (!own) {
            return error.Denied;
        }

        if (adding.added.items.len >= rows_max * fields_max) {
            return error.Invalid;
        }

        try adding.added.append(adding.arena, .{
            .id = id,
            .name = name,
            .value = try free_typed.of(adding.arena, value),
        });
    }

    /// The field `name` on the row `id`; null when nobody extended it.
    pub fn get(extended: Extended, id: []const u8, name: []const u8) ?free_value.Value {
        const open = extended.open orelse return null;
        const rows: free_value.Value = .{
            .bytes = open.rows.bytes,
        };

        std.debug.assert(name.len > 0);

        if (open.adding) |adding| {
            for (adding.added.items) |one| {
                if (std.mem.eql(u8, one.id, id) and std.mem.eql(u8, one.name, name)) {
                    return one.value;
                }
            }
        }

        return (rows.get(id) orelse return null).get(name);
    }

    /// What the hook added, written as one value: each row's fields under its id.
    pub fn seal(extended: Extended) Error!void {
        const open = extended.open orelse return error.Invalid;
        const adding = open.adding orelse return error.Invalid;
        const added = adding.added.items;
        var builder: free_builder.Builder = .init(adding.arena);

        std.debug.assert(added.len <= rows_max * fields_max);

        try builder.begin_map();

        for (added, 0..) |first, index| {
            if (earlier(added[0..index], first.id)) {
                continue;
            }

            try builder.key(first.id);
            try builder.begin_map();

            for (added[index..]) |one| {
                if (std.mem.eql(u8, one.id, first.id)) {
                    try builder.key(one.name);
                    try builder.put(one.value);
                }
            }

            try builder.end();
        }

        try builder.end();
        open.rows = .{
            .bytes = (try builder.done()).bytes,
        };
    }

    fn earlier(added: []const Added, id: []const u8) bool {
        std.debug.assert(id.len > 0);

        for (added) |one| {
            if (std.mem.eql(u8, one.id, id)) {
                return true;
            }
        }

        return false;
    }
};

test "a hook's added fields are sealed into one value, each row's under its id" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const free_json = @import("../sdk/free_json.zig");
    var plugin: []const u8 = "loyalty";
    const extended = try Extended.start(arena, &plugin);

    try extended.put("u1", "loyalty.points", @as(i64, 120));
    try extended.put("u2", "loyalty.points", @as(i64, 5));
    try extended.put("u1", "loyalty.tier", "gold");
    try std.testing.expectError(error.Denied, extended.put("u1", "other.points", 1));
    try std.testing.expectEqual(@as(?i64, 5), extended.get("u2", "loyalty.points").?.int());
    try extended.seal();
    try std.testing.expectEqualStrings(
        "{\"u1\":{\"loyalty.points\":120,\"loyalty.tier\":\"gold\"},\"u2\":{\"loyalty.points\":5}}",
        try free_json.text_of(arena, .{
            .bytes = extended.open.?.rows.bytes,
        }),
    );
}
