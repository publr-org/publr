//! Writes a value whose shape comes with the data (`free_value.zig`), part by part:
//!
//! ```zig
//! var builder: publr.value.Builder = .init(ctx.arena());
//! try builder.begin_map();
//! try builder.key("PLN");
//! try builder.int(12300);
//! try builder.end();
//! const value = try builder.done();
//! ```
const std = @import("std");
const free_value = @import("free_value.zig");

const Kind = free_value.Kind;
const Value = free_value.Value;

pub const Error = error{ Invalid, OutOfMemory };

const Open = struct {
    /// Where the list's or the map's first byte is.
    at: u32,
    count: u32 = 0,
    map: bool,
    /// A map's key was written and its value is awaited.
    keyed: bool = false,
};

pub const Builder = struct {
    arena: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    open: [free_value.depth_max]Open = undefined,
    depth: u32 = 0,
    /// Values written at the top: a finished builder holds exactly one.
    roots: u32 = 0,
    /// For whoever writes structs with it: a field holding nothing is left out, not `null`.
    leaves_nothing_out: bool = false,

    pub fn init(arena: std.mem.Allocator) Builder {
        return .{
            .arena = arena,
        };
    }

    /// One more value begins where the builder stands: counted in what holds it.
    fn begin(builder: *Builder, kind: Kind) Error!void {
        std.debug.assert(builder.depth <= free_value.depth_max);

        if (builder.depth == 0) {
            builder.roots += 1;
        } else {
            const holder = &builder.open[builder.depth - 1];

            // A map's value follows its key, and only its key.
            if (holder.map != holder.keyed) {
                return error.Invalid;
            }

            holder.keyed = false;
            holder.count += 1;
        }

        builder.bytes.append(builder.arena, @backingInt(kind)) catch return error.OutOfMemory;
    }

    fn word(builder: *Builder, value: u32) Error!void {
        var raw: [4]u8 = undefined;

        std.debug.assert(builder.bytes.items.len > 0 or builder.depth > 0);

        std.mem.writeInt(u32, &raw, value, .little);
        builder.bytes.appendSlice(builder.arena, &raw) catch return error.OutOfMemory;
    }

    pub fn nothing(builder: *Builder) Error!void {
        return builder.begin(.null);
    }

    pub fn boolean(builder: *Builder, value: bool) Error!void {
        return builder.begin(if (value) .true else .false);
    }

    pub fn int(builder: *Builder, value: i64) Error!void {
        var raw: [8]u8 = undefined;

        try builder.begin(.int);

        std.debug.assert(builder.bytes.items.len > 0);

        std.mem.writeInt(i64, &raw, value, .little);
        builder.bytes.appendSlice(builder.arena, &raw) catch return error.OutOfMemory;
    }

    pub fn float(builder: *Builder, value: f64) Error!void {
        var raw: [8]u8 = undefined;

        try builder.begin(.float);

        std.debug.assert(builder.bytes.items.len > 0);

        std.mem.writeInt(u64, &raw, @bitCast(value), .little);
        builder.bytes.appendSlice(builder.arena, &raw) catch return error.OutOfMemory;
    }

    pub fn text(builder: *Builder, value: []const u8) Error!void {
        if (value.len > std.math.maxInt(u32)) {
            return error.Invalid;
        }

        std.debug.assert(value.len <= std.math.maxInt(u32));

        try builder.begin(.text);
        try builder.word(@intCast(value.len));
        builder.bytes.appendSlice(builder.arena, value) catch return error.OutOfMemory;
    }

    /// A value made elsewhere, as it is.
    pub fn put(builder: *Builder, made: Value) Error!void {
        const len = free_value.span(made.bytes) orelse return error.Invalid;

        try builder.begin(made.kind());

        std.debug.assert(len >= 1);
        builder.bytes.appendSlice(builder.arena, made.bytes[1..len]) catch {
            return error.OutOfMemory;
        };
    }

    pub fn begin_list(builder: *Builder) Error!void {
        return builder.begin_holder(false);
    }

    pub fn begin_map(builder: *Builder) Error!void {
        return builder.begin_holder(true);
    }

    fn begin_holder(builder: *Builder, map: bool) Error!void {
        if (builder.depth >= free_value.depth_max) {
            return error.Invalid;
        }

        const at = builder.bytes.items.len;

        try builder.begin(if (map) .map else .list);
        try builder.word(0);
        try builder.word(0);

        std.debug.assert(at <= std.math.maxInt(u32));
        builder.open[builder.depth] = .{
            .at = @intCast(at),
            .map = map,
        };
        builder.depth += 1;
    }

    /// The name the next value of the map being written goes under.
    pub fn key(builder: *Builder, name: []const u8) Error!void {
        if (builder.depth == 0 or name.len > std.math.maxInt(u32)) {
            return error.Invalid;
        }

        const holder = &builder.open[builder.depth - 1];

        if (!holder.map or holder.keyed) {
            return error.Invalid;
        }

        std.debug.assert(builder.bytes.items.len >= holder.at + 9);

        holder.keyed = true;
        try builder.word(@intCast(name.len));
        builder.bytes.appendSlice(builder.arena, name) catch return error.OutOfMemory;
    }

    /// Ends the list or the map being written.
    pub fn end(builder: *Builder) Error!void {
        if (builder.depth == 0 or builder.open[builder.depth - 1].keyed) {
            return error.Invalid;
        }

        const holder = builder.open[builder.depth - 1];
        const size = builder.bytes.items.len - holder.at - 9;

        if (size > std.math.maxInt(u32)) {
            return error.Invalid;
        }

        std.debug.assert(builder.bytes.items.len >= holder.at + 9);

        std.mem.writeInt(u32, builder.bytes.items[holder.at + 1 ..][0..4], @intCast(size), .little);
        std.mem.writeInt(u32, builder.bytes.items[holder.at + 5 ..][0..4], holder.count, .little);
        builder.depth -= 1;
    }

    /// The one value written, everything begun ended.
    pub fn done(builder: *Builder) Error!Value {
        if (builder.depth != 0 or builder.roots != 1) {
            return error.Invalid;
        }

        std.debug.assert(free_value.complete(builder.bytes.items));

        return .{
            .bytes = builder.bytes.items,
        };
    }
};

test "a builder refuses what is no value: a key outside a map, a value without its key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var builder: Builder = .init(arena);

    try std.testing.expectError(error.Invalid, builder.key("a"));
    try std.testing.expectError(error.Invalid, builder.end());
    try std.testing.expectError(error.Invalid, builder.done());

    try builder.begin_map();
    try std.testing.expectError(error.Invalid, builder.int(1));
    try builder.key("a");
    try std.testing.expectError(error.Invalid, builder.key("b"));
    try std.testing.expectError(error.Invalid, builder.end());
    try builder.begin_list();
    try std.testing.expectError(error.Invalid, builder.key("c"));
    try builder.end();
    try std.testing.expectError(error.Invalid, builder.done());
    try builder.end();

    const made = try builder.done();

    try std.testing.expect(free_value.valid(made.bytes));
    try std.testing.expectEqual(@as(u32, 0), made.get("a").?.count());

    // A value made elsewhere goes in as it is; two values at the top are not one.
    var outer: Builder = .init(arena);

    try outer.begin_list();
    try outer.put(made);
    try outer.end();
    try std.testing.expect(free_value.valid((try outer.done()).bytes));
    try outer.nothing();
    try std.testing.expectError(error.Invalid, outer.done());

    // Nesting ends where a value's may.
    var deep: Builder = .init(arena);

    for (0..free_value.depth_max) |_| {
        try deep.begin_list();
    }

    try std.testing.expectError(error.Invalid, deep.begin_list());
}
