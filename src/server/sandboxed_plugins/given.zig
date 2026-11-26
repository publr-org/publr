//! A value a plugin hands over where it lies in its memory: copied out piece by piece as it
//! is read, every address and length checked against that plugin's memory, the bytes read in
//! all bounded, and how deep its addresses are followed bounded too. `given_json.zig` writes
//! one as JSON for what core keeps as JSON and for the outer edge.
const std = @import("std");
const wasm = @import("publr_wasm");
const shape_wire = @import("../../sdk/plugin/shape_wire.zig");
const free_value = @import("../../publr/free_value.zig");
const described_module = @import("described.zig");
const given_json = @import("given_json.zig");

const Described = described_module.Described;

pub const Error = error{ Invalid, OutOfMemory };

/// The most one value's reading copies out of a plugin, and the items one list may hold: a
/// plugin holds 16 MiB, and a value that points at the same bytes over and over is cut off.
pub const read_bytes_max: u64 = 32 << 20;
pub const items_max: u32 = 1 << 24;

/// How deep a value's addresses are followed: a list in a list, a tree's node in its node.
pub const depth_max: u32 = 64;

/// Where the bytes are: a plugin's memory, or a block laid out here and placed at `base`.
pub const Memory = union(enum) {
    guest: *wasm.Env,
    block: struct {
        base: u32,
        bytes: []const u8,
    },

    fn read(memory: Memory, at: u32, target: []u8) bool {
        std.debug.assert(target.len > 0);

        switch (memory) {
            .guest => |env| return env.read(at, target),
            .block => |block| {
                const end = @as(u64, at) + target.len;

                if (at < block.base or end > @as(u64, block.base) + block.bytes.len) {
                    return false;
                }

                @memcpy(target, block.bytes[at - block.base ..][0..target.len]);

                return true;
            },
        }
    }
};

/// How an optional holding nothing is written inside an object, as JSON.
pub const Absent = enum {
    /// Left out, as a plugin's own JSON writer leaves it out of a record's document.
    left_out,
    /// `null`.
    null,
};

pub const Given = struct {
    described: *const Described,
    memory: Memory,
    /// What is copied out is kept here.
    arena: std.mem.Allocator,
    /// The value's unions beside the block, met in the order of a walk.
    table: []const shape_wire.Entry = &.{},
    next: u32 = 0,
    left: u64 = read_bytes_max,
    depth: u32 = 0,

    /// `len` bytes at `at`, copied out of the plugin.
    pub fn copy(given: *Given, at: u32, len: u64) Error![]const u8 {
        if (len == 0) {
            return &.{};
        }

        if (len > given.left) {
            return error.Invalid;
        }

        given.left -= len;

        // A block kept here is read where it is: only a plugin's memory is copied out.
        if (given.memory == .block) {
            const block = given.memory.block;
            const end = @as(u64, at) + len;

            if (at < block.base or end > @as(u64, block.base) + block.bytes.len) {
                return error.Invalid;
            }

            return block.bytes[at - block.base ..][0..@intCast(len)];
        }

        const copied = given.arena.alloc(u8, @intCast(len)) catch return error.OutOfMemory;

        if (!given.memory.read(at, copied)) {
            return error.Invalid;
        }

        std.debug.assert(copied.len == len);

        return copied;
    }

    /// The bytes of the value described by `node` at `at`.
    pub fn window(given: *Given, node: u32, at: u32) Error![]const u8 {
        return given.copy(at, given.described.span(node));
    }

    /// A text's bytes: where the two words at `bytes` say, and only if they are UTF-8.
    pub fn text(given: *Given, bytes: []const u8) Error![]const u8 {
        std.debug.assert(bytes.len >= 8);

        const ptr = std.mem.readInt(u32, bytes[0..4], .little);
        const len = std.mem.readInt(u32, bytes[4..8], .little);
        const copied = try given.copy(ptr, len);

        if (!std.unicode.utf8ValidateSlice(copied)) {
            return error.Invalid;
        }

        return copied;
    }

    /// A list's items, copied out together: their bytes and how many.
    pub fn items(given: *Given, node: u32, bytes: []const u8) Error!Items {
        const list = given.described.nodes[node];
        const ptr = std.mem.readInt(u32, bytes[0..4], .little);
        const count = std.mem.readInt(u32, bytes[4..8], .little);

        std.debug.assert(list.kind == .list);

        if (count > items_max) {
            return error.Invalid;
        }

        // Items that take no bytes still take a step each.
        if (list.size == 0) {
            if (count > given.left) {
                return error.Invalid;
            }

            given.left -= count;
        }

        return .{
            .bytes = try given.copy(ptr, @as(u64, count) * list.size),
            .size = list.size,
            .count = count,
        };
    }

    pub const Items = struct {
        bytes: []const u8,
        size: u32,
        count: u32,

        pub fn at(list: Items, index: u32) []const u8 {
            std.debug.assert(index < list.count);

            return list.bytes[@as(usize, index) * list.size ..];
        }
    };

    /// Whether the optional `node` at `bytes` holds something.
    pub fn present(given: *const Given, node: u32, bytes: []const u8) bool {
        const optional = given.described.nodes[node];

        std.debug.assert(optional.kind == .optional);

        if (optional.niche) {
            return std.mem.readInt(u32, bytes[0..4], .little) != 0;
        }

        return bytes[optional.size] != 0;
    }

    /// An int of the size and sign the description says.
    pub fn int(given: *const Given, node: u32, bytes: []const u8) i128 {
        const said = given.described.nodes[node];
        var raw: [8]u8 = @splat(0);

        std.debug.assert(said.size <= 8);

        @memcpy(raw[0..said.size], bytes[0..said.size]);

        const unsigned = std.mem.readInt(u64, &raw, .little);

        if (!said.signed or said.size == 0) {
            return unsigned;
        }

        const shift: u6 = @intCast(64 - @as(u32, said.size) * 8);

        return @as(i64, @bitCast(unsigned << shift)) >> shift;
    }

    pub fn float(given: *const Given, node: u32, bytes: []const u8) f64 {
        const said = given.described.nodes[node];

        std.debug.assert(said.kind == .float);

        if (said.size == 4) {
            return @as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], .little)));
        }

        return @bitCast(std.mem.readInt(u64, bytes[0..8], .little));
    }

    /// The name of the enum tag at `bytes`; a number that is none of its tags is refused.
    pub fn tag(given: *const Given, node: u32, bytes: []const u8) Error![]const u8 {
        const said = given.described.nodes[node];
        var raw: [8]u8 = @splat(0);

        std.debug.assert(said.kind == .enumeration);

        @memcpy(raw[0..said.size], bytes[0..said.size]);

        const unsigned = std.mem.readInt(u64, &raw, .little);
        const shift: u6 = @intCast(64 - @as(u32, @max(said.size, 1)) * 8);
        const signed = @as(i64, @bitCast(unsigned << shift)) >> shift;

        for (given.described.tags_of(node)) |one| {
            // A tag past an unsigned enum's sign bit reads the same either way.
            if (one.value == signed or (one.value >= 0 and one.value == unsigned)) {
                return one.name;
            }
        }

        return error.Invalid;
    }

    /// A value whose shape comes with the data: the bytes the two words at `bytes` say, and
    /// only if they are one well-made value.
    pub fn free(given: *Given, bytes: []const u8) Error![]const u8 {
        std.debug.assert(bytes.len >= 8);

        const ptr = std.mem.readInt(u32, bytes[0..4], .little);
        const len = std.mem.readInt(u32, bytes[4..8], .little);
        const copied = try given.copy(ptr, len);

        if (!free_value.valid(copied)) {
            return error.Invalid;
        }

        return copied;
    }

    /// One step down an address (a list's items, a pointer's target, a union's payload); a
    /// value nested deeper than any honest one is refused. `leave` steps back up.
    pub fn enter(given: *Given) Error!void {
        std.debug.assert(given.depth <= depth_max);

        if (given.depth >= depth_max) {
            return error.Invalid;
        }

        given.depth += 1;
    }

    pub fn leave(given: *Given) void {
        std.debug.assert(given.depth > 0);

        given.depth -= 1;
    }

    /// The bytes of what the pointer `node` at `bytes` points at.
    pub fn pointee(given: *Given, node: u32, bytes: []const u8) Error![]const u8 {
        const said = given.described.nodes[node];

        std.debug.assert(said.kind == .pointer);

        return given.window(said.child, std.mem.readInt(u32, bytes[0..4], .little));
    }

    pub const Chosen = struct {
        /// Which alternative of the union, and the part its payload is.
        index: u32,
        node: u32,
        bytes: []const u8,
    };

    /// The next union beside the block, which must be `node`: its alternative, one of those
    /// the description says, and its payload's bytes.
    pub fn chosen(given: *Given, node: u32) Error!Chosen {
        const alternatives = given.described.alternatives_of(node);

        std.debug.assert(given.next <= given.table.len);

        if (given.next >= given.table.len) {
            return error.Invalid;
        }

        const entry = given.table[given.next];

        given.next += 1;

        if (entry.len >= alternatives.len) {
            return error.Invalid;
        }

        return .{
            .index = entry.len,
            .node = alternatives[entry.len].node,
            .bytes = try given.window(alternatives[entry.len].node, entry.ptr),
        };
    }

    /// Steps over the value of `node` at `bytes`: the unions inside it are passed, so the
    /// next one read is the next one written.
    pub fn skip(given: *Given, node: u32, bytes: []const u8) Error!void {
        const said = given.described.nodes[node];

        std.debug.assert(node < given.described.nodes.len);

        if (!said.choosy) {
            return;
        }

        switch (said.kind) {
            .int, .float, .bool, .text, .free, .enumeration => unreachable,
            .optional => if (given.present(node, bytes)) {
                try given.skip(said.child, bytes);
            },
            .choice => {
                const held = try given.chosen(node);

                try given.enter();
                defer given.leave();

                try given.skip(held.node, held.bytes);
            },
            .pointer => {
                try given.enter();
                defer given.leave();

                try given.skip(said.child, try given.pointee(node, bytes));
            },
            .list => {
                const list = try given.items(node, bytes);

                try given.enter();
                defer given.leave();

                for (0..list.count) |index| {
                    try given.skip(said.child, list.at(@intCast(index)));
                }
            },
            .object => for (given.described.fields_of(node)) |field| {
                try given.skip(field.node, bytes[field.offset..]);
            },
        }
    }

    pub const WriteError = given_json.WriteError;

    /// The value of `node` at `bytes`, written as JSON.
    pub fn write_json(
        given: *Given,
        writer: *std.Io.Writer,
        node: u32,
        bytes: []const u8,
        absent: Absent,
    ) WriteError!void {
        std.debug.assert(bytes.len >= given.described.span(node));

        return given_json.write(given, writer, node, bytes, absent);
    }

    /// The value of `node` at `bytes` as JSON text, in the arena.
    pub fn json_of(given: *Given, node: u32, bytes: []const u8, absent: Absent) Error![]const u8 {
        var output: std.Io.Writer.Allocating = .init(given.arena);

        given.write_json(&output.writer, node, bytes, absent) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => |other| return other,
        };

        std.debug.assert(output.written().len > 0);

        return output.written();
    }
};

pub const encoded = given_json.encoded;
