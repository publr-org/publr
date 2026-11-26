//! A value built for a plugin in the layout it described: its bytes as they will lie in the
//! plugin's memory, addressed from 0 until the plugin says where they go. Every byte is zero
//! until a value is written to it, so padding never carries anything of core's or of another
//! plugin's. `laid_json.zig` builds one from JSON, for what core keeps as JSON (a record's
//! document) and for the outer edge; `laid_typed.zig` builds from core's own structs.
const std = @import("std");
const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
const free_value = @import("../../publr/free_value.zig");
const described_module = @import("described.zig");
const laid_json = @import("laid_json.zig");

const Described = described_module.Described;
const Value = std.json.Value;

pub const Error = error{ Invalid, OutOfMemory };

/// The most one value may take once built: more than a plugin can hold.
pub const block_bytes_max: u64 = 32 << 20;

/// A value laid out at address 0; `place` moves it to where the plugin made room.
pub const Laid = struct {
    block: std.ArrayList(u8) = .empty,
    /// Where in the block an address is written, each moved with the block.
    addresses: std.ArrayList(u32) = .empty,
    table: std.ArrayList(shape_wire.Entry) = .empty,

    /// Moves every address by `base`, the block's place in the plugin.
    pub fn place(laid: *Laid, base: u32) void {
        std.debug.assert(base > 0);
        std.debug.assert(laid.block.items.len > 0);

        for (laid.addresses.items) |at| {
            const was = std.mem.readInt(u32, laid.block.items[at..][0..4], .little);

            std.mem.writeInt(u32, laid.block.items[at..][0..4], was +% base, .little);
        }

        // A payload that takes no bytes lies nowhere: its address stays zero.
        for (laid.table.items) |*entry| {
            if (entry.ptr != 0) {
                entry.ptr +%= base;
            }
        }
    }

    pub fn deinit(laid: *Laid, gpa: std.mem.Allocator) void {
        std.debug.assert(laid.addresses.items.len <= laid.block.items.len);

        laid.block.deinit(gpa);
        laid.addresses.deinit(gpa);
        laid.table.deinit(gpa);
        laid.* = .{};
    }
};

pub const Layout = struct {
    /// The block, its addresses and its side table grow here.
    gpa: std.mem.Allocator,
    /// What is needed for a moment: a field's default read from its JSON.
    scratch: std.mem.Allocator,
    described: *const Described,
    laid: *Laid,

    /// The root's room: an empty value still takes a byte, the plugin makes room for it like
    /// any other.
    pub fn begin(layout: *Layout) Error!void {
        std.debug.assert(layout.laid.block.items.len == 0);

        _ = try layout.reserve(@max(layout.described.span(Described.root), 1), 16);
    }

    /// `len` zeroed bytes at the block's end, aligned; where they are.
    pub fn reserve(layout: *Layout, len: u64, alignment: u32) Error!u32 {
        std.debug.assert(alignment > 0 and alignment <= 16);

        const block = &layout.laid.block;
        const at = std.mem.alignForward(u64, block.items.len, alignment);

        if (at + len > block_bytes_max) {
            return error.OutOfMemory;
        }

        block.appendNTimes(layout.gpa, 0, @intCast(at + len - block.items.len)) catch {
            return error.OutOfMemory;
        };

        return @intCast(at);
    }

    /// A slice's two words at `at`: where its items are, and how many.
    fn address(layout: *Layout, at: u32, target: u32, len: u32) Error!void {
        const block = layout.laid.block.items;

        std.debug.assert(@as(u64, at) + 8 <= block.len);

        std.mem.writeInt(u32, block[at..][0..4], target, .little);
        std.mem.writeInt(u32, block[at + 4 ..][0..4], len, .little);
        layout.laid.addresses.append(layout.gpa, at) catch return error.OutOfMemory;
    }

    pub fn text(layout: *Layout, at: u32, bytes: []const u8) Error!void {
        // Never at address zero, which says none: the root lies there.
        const where = try layout.reserve(bytes.len, 1);

        std.debug.assert(where > 0);

        @memcpy(layout.laid.block.items[where..][0..bytes.len], bytes);
        try layout.address(at, where, @intCast(bytes.len));
    }

    /// Room for `count` items of list `node`, its two words written at `at`; where the items
    /// begin.
    pub fn items(layout: *Layout, node: u32, at: u32, count: u64) Error!u32 {
        const list = layout.described.nodes[node];

        std.debug.assert(list.kind == .list);

        if (count > std.math.maxInt(u32)) {
            return error.Invalid;
        }

        const where = try layout.reserve(count * list.size, list.alignment);

        try layout.address(at, where, @intCast(count));

        return where;
    }

    /// An int of the size the description says; one that does not fit it is refused.
    pub fn int(layout: *Layout, node: u32, at: u32, value: i128) Error!void {
        const said = layout.described.nodes[node];
        const bits: u16 = @as(u16, @intCast(said.size)) * 8;

        std.debug.assert(said.kind == .int);

        const low: i128 = if (said.signed) -(@as(i128, 1) << @intCast(bits - 1)) else 0;
        const high: i128 = (@as(i128, 1) << @intCast(if (said.signed) bits - 1 else bits)) - 1;

        if (value < low or value > high) {
            return error.Invalid;
        }

        layout.number(at, said.size, @truncate(value));
    }

    fn number(layout: *Layout, at: u32, size: u32, value: i64) void {
        var bytes: [8]u8 = undefined;

        std.debug.assert(size <= 8);
        std.debug.assert(@as(u64, at) + size <= layout.laid.block.items.len);

        std.mem.writeInt(i64, &bytes, value, .little);
        @memcpy(layout.laid.block.items[at..][0..size], bytes[0..size]);
    }

    pub fn float(layout: *Layout, node: u32, at: u32, value: f64) void {
        const said = layout.described.nodes[node];
        const block = layout.laid.block.items;

        std.debug.assert(said.kind == .float);

        if (said.size == 4) {
            const narrow: f32 = @floatCast(value);

            std.mem.writeInt(u32, block[at..][0..4], @bitCast(narrow), .little);
        } else {
            std.mem.writeInt(u64, block[at..][0..8], @bitCast(value), .little);
        }
    }

    pub fn boolean(layout: *Layout, at: u32, value: bool) void {
        std.debug.assert(at < layout.laid.block.items.len);

        layout.laid.block.items[at] = @intFromBool(value);
    }

    /// The tag named `name` of enum `node`; a name that is none of its tags is refused.
    pub fn tag(layout: *Layout, node: u32, at: u32, name: []const u8) Error!void {
        const said = layout.described.nodes[node];

        std.debug.assert(said.kind == .enumeration);

        for (layout.described.tags_of(node)) |one| {
            if (std.mem.eql(u8, one.name, name)) {
                return layout.number(at, said.size, one.value);
            }
        }

        return error.Invalid;
    }

    pub fn tag_numbered(layout: *Layout, node: u32, at: u32, value: i64) Error!void {
        const said = layout.described.nodes[node];

        std.debug.assert(said.kind == .enumeration);

        for (layout.described.tags_of(node)) |one| {
            if (one.value == value) {
                return layout.number(at, said.size, one.value);
            }
        }

        return error.Invalid;
    }

    /// Marks the optional `node` at `at` as holding something. One without a byte of its
    /// own says so by its payload's address, which is never zero once written.
    pub fn present(layout: *Layout, node: u32, at: u32) void {
        const optional = layout.described.nodes[node];

        std.debug.assert(optional.kind == .optional);

        if (!optional.niche) {
            layout.laid.block.items[at + optional.size] = 1;
        }
    }

    /// A value whose shape comes with the data, its two words written at `at`; bytes that
    /// are not one well-made value are refused.
    pub fn free(layout: *Layout, at: u32, bytes: []const u8) Error!void {
        if (!free_value.valid(bytes)) {
            return error.Invalid;
        }

        std.debug.assert(bytes.len > 0);

        return layout.text(at, bytes);
    }

    /// Room for what pointer `node` points at, its address written at `at`; where it is.
    pub fn pointee(layout: *Layout, node: u32, at: u32) Error!u32 {
        const said = layout.described.nodes[node];
        const block = &layout.laid.block;

        std.debug.assert(said.kind == .pointer);

        // Never at address zero, which says none: the root lies there.
        const where = try layout.reserve(@max(said.size, 1), said.alignment);

        std.debug.assert(where > 0);

        std.mem.writeInt(u32, block.items[at..][0..4], where, .little);
        layout.laid.addresses.append(layout.gpa, at) catch return error.OutOfMemory;

        return where;
    }

    /// The union `node` holding its alternative `index`: an entry beside the block, and
    /// room for the payload; where that is.
    pub fn chosen(layout: *Layout, node: u32, index: u32) Error!u32 {
        const alternative = layout.described.alternatives_of(node)[index];
        const where = try layout.reserve(alternative.size, alternative.alignment);

        std.debug.assert(where > 0);

        layout.laid.table.append(layout.gpa, .{
            .ptr = if (alternative.size == 0) 0 else where,
            .len = index,
        }) catch return error.OutOfMemory;

        return where;
    }

    /// A field nothing was given for: its default as the description says it, nothing for
    /// an optional, and refused for anything else.
    pub fn left_out(layout: *Layout, field: described_module.Field, at: u32) Error!void {
        std.debug.assert(field.name.len > 0);

        return laid_json.left_out(layout, field, at);
    }

    /// `given` written at `at` as `node` says; `null` for a value that was left out.
    pub fn write(layout: *Layout, node: u32, given: ?Value, at: u32) Error!void {
        std.debug.assert(node < layout.described.nodes.len);

        return laid_json.write(layout, node, given, at);
    }
};

pub const from_json = laid_json.from_json;
