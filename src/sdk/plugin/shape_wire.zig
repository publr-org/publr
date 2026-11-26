//! Structs across the sandbox's boundary: a value travels in the guest's own memory layout,
//! which the guest describes at build time (`describe`) and the host reads and writes
//! natively: into core's own types (`server/sandboxed_plugins/given_typed.zig`,
//! `laid_typed.zig`) or into another plugin's layout (`transfer.zig`). No text is written or
//! parsed by the guest. A union alone does not lie where the description can say (its tag's
//! place is the compiler's): which alternative it holds and where its payload is travel
//! beside the block, one entry of a side table each (`shape_parts.zig`).
//!
//! A description, byte by byte (numbers little-endian u32 unless said):
//! `i` size:u8 signed:u8 · `d` places:u8 (a decimal's i64 units) · `f` size:u8 · `b` ·
//! `s` (text) · `v` (a value whose shape comes with the data, `publr/free_value.zig`) ·
//! `e` size:u8 count, then name_len:u8 name value:i64 each ·
//! `l` keyed:u8 item_size item_align item · `p` size align target ·
//! `n` payload_size niche:u8 payload ·
//! `o` form:u8 size count, then name_len:u8 name offset default_len default_json part each ·
//! `u` count, then name_len:u8 name size align payload each ·
//! `r` up:u8 (the struct or union `up` of them above: a tree's node in its children).
const std = @import("std");
const shape_said = @import("shape_said.zig");

/// One union beside the block: where its payload lies, and which alternative it is.
pub const Entry = extern struct {
    ptr: u32,
    len: u32,
};

/// Where each part of a call is in the guest's memory, handed over as one struct: a host
/// function takes few arguments the same way on every platform.
pub const Call = extern struct {
    name: u32,
    name_len: u32,
    root: u32,
    asked: u32,
    asked_len: u32,
    table: u32,
    table_len: u32,
    answer: u32,
    answer_len: u32,
};

/// One of the envelopes a batch hands an entry (`publr_invoke_batch`): where the host laid
/// it, and its side table.
pub const Item = extern struct {
    block: u32,
    table: u32,
    count: u32,
};

/// A value handed to the host under a name, with no answer: an event's payload, a queued
/// job's input.
pub const Sent = extern struct {
    name: u32,
    name_len: u32,
    root: u32,
    asked: u32,
    asked_len: u32,
    table: u32,
    table_len: u32,
    /// A queued job runs never before this moment.
    due_ms: i64 = 0,
};

/// What the host answers with: the value's block and the side table's entries in it.
pub const Answer = extern struct {
    block: u32,
    block_len: u32,
    table: u32,
    table_len: u32,
};

/// How a struct lies and reads as JSON. A struct that writes its own JSON says which with
/// `pub const publr_form = .lone;`; any other is `.fields`.
pub const Form = enum {
    /// An object of its fields.
    fields,
    /// Its one field, as if the struct were not there: a time is its milliseconds.
    inner,
    /// Its fields where it lies; in JSON its first field alone (a reference is its id).
    lone,
    /// Its one field, a list of pairs, is an object keyed by each pair's first field:
    /// money's `{ "PLN": 12300 }`.
    keyed,
    /// Its one field, `units: i64`, is a decimal of `decimal_places` places: `"1.250"`.
    decimal,
    /// Its one field, `bytes`, is a value whose shape comes with the data.
    free,
    /// Its one field, `text`, is the JSON text of a value whose shape comes with the data:
    /// how Publr itself keeps one (`operation.Json` outside a plugin's module). Laid out,
    /// it is that value.
    json,
};

pub const form_tuple: u8 = 1;
pub const form_lone: u8 = 2;

pub fn form_of(comptime Shape: type) Form {
    comptime {
        const info = @typeInfo(Shape).@"struct";

        std.debug.assert(@sizeOf(Shape) < 1 << 24);

        if (@hasDecl(Shape, "publr_form")) {
            return Shape.publr_form;
        }

        if (info.layout == .@"packed") {
            @compileError(@typeName(Shape) ++ " is packed: a value handed to Publr or to " ++
                "another plugin is a plain struct");
        }

        // A struct that only writes its JSON (leaving defaults out) still reads by its fields.
        for (.{ "jsonParse", "jsonParseFromValue" }) |name| {
            if (std.meta.hasFn(Shape, name)) {
                @compileError(@typeName(Shape) ++ " reads its own JSON: it says how it " ++
                    "lies with `pub const publr_form = .lone;` or another form");
            }
        }

        return .fields;
    }
}

/// Whether field `index` of `Shape` is handed over. A struct keeps a field to itself by
/// naming it in `pub const publr_local = .{"state"};`: it is never read, and comes zeroed.
pub fn crosses(comptime Shape: type, comptime index: u32) bool {
    comptime {
        const info = @typeInfo(Shape).@"struct";
        const name = info.field_names[index];

        std.debug.assert(index < info.field_names.len);

        if (info.field_types[index] == void or info.field_attrs[index].@"comptime") {
            return false;
        }

        if (!@hasDecl(Shape, "publr_local")) {
            return true;
        }

        for (Shape.publr_local) |kept| {
            if (std.mem.eql(u8, kept, name)) {
                return false;
            }
        }

        return true;
    }
}

/// The one field of `Shape` that is handed over, for a struct that lies as it.
pub fn only_field(comptime Shape: type) []const u8 {
    comptime {
        var found: ?[]const u8 = null;

        std.debug.assert(@typeInfo(Shape) == .@"struct");

        for (@typeInfo(Shape).@"struct".field_names, 0..) |name, index| {
            if (crosses(Shape, index)) {
                if (found != null) {
                    @compileError(@typeName(Shape) ++ ": its `publr_form` is for a struct " ++
                        "that hands over one field");
                }

                found = name;
            }
        }

        return found orelse @compileError(@typeName(Shape) ++ " hands over no field");
    }
}

pub fn word(comptime value: u32) []const u8 {
    comptime {
        std.debug.assert(value <= std.math.maxInt(u32));

        var bytes: [4]u8 = undefined;

        std.mem.writeInt(u32, &bytes, value, .little);

        const kept = bytes;

        return &kept;
    }
}

/// How many types one description says at most, and the steps each takes to say.
pub const nodes_max: u32 = 4096;
pub const steps_per_node: u32 = 400;

/// How `Shape` is laid out in this build, as the host reads it.
pub fn describe(comptime Shape: type) []const u8 {
    comptime {
        // One build-time walk says a whole shape, every type in it: at most `nodes_max` of them,
        // each a few hundred steps (its name, its default, its fields).
        @setEvalBranchQuota(nodes_max * steps_per_node);

        const text = shape_said.said(Shape, &.{}, false);

        std.debug.assert(text.len > 0);

        return text;
    }
}

test "a description says each field's place and default" {
    const Money = struct {
        amounts: []const Amount = &.{},

        pub const publr_form = .keyed;

        const Amount = struct {
            currency: []const u8,
            minor: i64,
        };
    };
    const Line = struct {
        title: []const u8,
        count: u32 = 2,
        kind: enum { item, step } = .step,
        note: ?[]const u8 = null,
        money: Money = .{},
        tags: []const []const u8 = &.{ "a", "b" },
    };
    const text = comptime describe(Line);

    try std.testing.expectEqual(@as(u8, 'o'), text[0]);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"step\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[\"a\",\"b\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "l\x01") != null);
    try std.testing.expectEqual(@sizeOf(?[]const u8), @sizeOf([]const u8));
    try std.testing.expect(@sizeOf(?u32) > @sizeOf(u32));
}

test "a tree's node says its children as itself; a union says each alternative" {
    const Node = struct {
        name: []const u8,
        children: []const @This() = &.{},
        next: ?*const @This() = null,
    };
    const Choice = union(enum) {
        none,
        count: u32,
        node: Node,
    };
    const tree = comptime describe(Node);
    const choice = comptime describe(Choice);

    try std.testing.expect(std.mem.indexOf(u8, tree, "r\x01") != null);
    try std.testing.expectEqual(@as(u8, 'u'), choice[0]);
    try std.testing.expect(std.mem.indexOf(u8, choice, "\x05count") != null);
}

test "an optional's byte follows its payload; a slice's is its address" {
    var count: ?u32 = 5;
    const Wide = struct {
        ms: i64,
        on: bool,
    };
    var wide: ?Wide = .{
        .ms = 1,
        .on = true,
    };
    var none: ?[]const u8 = null;

    try std.testing.expectEqual(@as(u8, 1), std.mem.asBytes(&count)[@sizeOf(u32)]);
    try std.testing.expectEqual(@as(u8, 1), std.mem.asBytes(&wide)[@sizeOf(@TypeOf(wide.?))]);
    count = null;
    try std.testing.expectEqual(@as(u8, 0), std.mem.asBytes(&count)[@sizeOf(u32)]);
    const address = std.mem.readInt(u64, std.mem.asBytes(&none)[0..8], .little);

    try std.testing.expectEqual(@as(u64, 0), address);
}
