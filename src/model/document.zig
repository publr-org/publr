//! A record's document as data: the JSON object a caller sees, and the rows it becomes in
//! `record_values`. `flatten` turns the object into rows (one per field value, dotted
//! paths for groups, ordinals for repeaters and many-valued fields); `assemble` turns rows
//! back into the object. Title and slug rules live here too. No database anywhere.

const std = @import("std");
const field = @import("field.zig");
const kinds = @import("kinds.zig");

const Def = field.Def;
const Kind = kinds.Kind;
const Value = std.json.Value;
const content_type_rules = @import("content_type.zig");
const TypeDef = content_type_rules.Def;
const find_field = content_type_rules.find_field;

pub const path_len_max: u32 = 256;
pub const items_max: u32 = 1000;
pub const rows_max: u32 = 100_000;
pub const flat_max: u32 = 4096;
pub const Error = error{ Invalid, OutOfMemory };

pub const Stored = union(enum) { integer: i64, real: f64, text: []const u8 };

/// One stored value, typed by its storage class.
pub const Row = struct {
    field: []const u8,
    ordinal: i64,
    value: Stored,
};

/// One value ready to be stored: where it goes and what it is.
pub const Flat = struct {
    field: []const u8,
    ordinal: u32,
    column: field.Column,
    value: Stored,
    searchable: bool,
};

/// The document as rows. Field paths point into memory owned by the flattener, valid as
/// long as it is.
pub fn flatten(
    known: []const Kind,
    fields: []const Def,
    value: Value,
    buffer: *[flat_max]Flat,
) Error![]const Flat {
    std.debug.assert(fields.len <= field.fields_max);
    std.debug.assert(buffer.len == flat_max);

    if (value != .object) {
        return error.Invalid;
    }

    var flattener: Flattener = .{ .known = known, .out = buffer };

    try flattener.walk(fields, value.object, "", 0);

    return buffer[0..flattener.len];
}

const Flattener = struct {
    known: []const Kind,
    out: *[flat_max]Flat,
    len: u32 = 0,
    paths: [flat_max][path_len_max]u8 = undefined,
    fn walk(
        flattener: *Flattener,
        fields: []const Def,
        object: std.json.ObjectMap,
        prefix: []const u8,
        ordinal: u32,
    ) Error!void {
        std.debug.assert(fields.len <= field.fields_max);
        std.debug.assert(prefix.len <= path_len_max);

        for (fields) |def| {
            const value = object.get(def.name) orelse continue;

            if (value == .null) {
                continue;
            }

            var path_buffer: [path_len_max]u8 = undefined;
            const path = try join(&path_buffer, prefix, def.name);

            if (field.is_group(def.kind)) {
                try flattener.walk_group(def, value, path, ordinal);
            } else if (field.is_repeater(def.kind)) {
                try flattener.walk_repeater(def, value, path);
            } else if (def.many) {
                try flattener.walk_many(def, value, path);
            } else {
                try flattener.leaf(def, value, path, ordinal);
            }
        }
    }

    fn walk_group(
        flattener: *Flattener,
        def: Def,
        value: Value,
        path: []const u8,
        ordinal: u32,
    ) Error!void {
        std.debug.assert(field.is_group(def.kind));
        std.debug.assert(path.len > 0);

        if (value != .object) {
            return error.Invalid;
        }

        try flattener.walk(def.fields, value.object, path, ordinal);
    }

    fn walk_repeater(flattener: *Flattener, def: Def, value: Value, path: []const u8) Error!void {
        std.debug.assert(field.is_repeater(def.kind));
        std.debug.assert(path.len > 0);

        if (value != .array or value.array.items.len > items_max) {
            return error.Invalid;
        }

        for (value.array.items, 0..) |item, index| {
            if (item != .object) {
                return error.Invalid;
            }

            try flattener.walk(def.fields, item.object, path, @intCast(index));
        }
    }

    fn walk_many(flattener: *Flattener, def: Def, value: Value, path: []const u8) Error!void {
        std.debug.assert(def.many);
        std.debug.assert(path.len > 0);

        if (value != .array or value.array.items.len > items_max) {
            return error.Invalid;
        }

        for (value.array.items, 0..) |item, index| {
            try flattener.leaf(def, item, path, @intCast(index));
        }
    }

    fn leaf(
        flattener: *Flattener,
        def: Def,
        value: Value,
        path: []const u8,
        ordinal: u32,
    ) Error!void {
        std.debug.assert(field.is_leaf(def.kind));
        std.debug.assert(path.len > 0);

        if (flattener.len == flat_max) {
            return error.Invalid;
        }

        const kind = kinds.find(flattener.known, def.kind) orelse return error.Invalid;
        const stored: Stored = switch (kind.storage) {
            .text, .ref, .long => .{ .text = try expect_string(value) },
            .int, .bool => .{ .integer = try expect_int(kind.storage, value) },
            .real => .{ .real = try expect_real(value) },
            .none => unreachable,
        };
        const kept = flattener.paths[flattener.len][0..path.len];

        @memcpy(kept, path);
        flattener.out[flattener.len] = .{
            .field = kept,
            .ordinal = ordinal,
            .column = kinds.column_of(kind.storage),
            .value = stored,
            .searchable = def.searchable and value == .string,
        };
        flattener.len += 1;
    }
};

fn expect_string(value: Value) Error![]const u8 {
    std.debug.assert(value != .null);
    std.debug.assert(@intFromEnum(value) >= 0);

    return switch (value) {
        .string => |text| text,
        else => error.Invalid,
    };
}

fn expect_int(storage: kinds.Storage, value: Value) Error!i64 {
    std.debug.assert(storage == .int or storage == .bool);
    std.debug.assert(value != .null);

    return switch (value) {
        .integer => |number| number,
        .bool => |flag| if (storage == .bool) @as(i64, if (flag) 1 else 0) else error.Invalid,
        else => error.Invalid,
    };
}

fn expect_real(value: Value) Error!f64 {
    std.debug.assert(value != .null);
    std.debug.assert(@intFromEnum(value) >= 0);

    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| number,
        else => error.Invalid,
    };
}

pub fn join(buffer: *[path_len_max]u8, prefix: []const u8, name: []const u8) Error![]const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(prefix.len <= path_len_max);

    if (prefix.len == 0) {
        if (name.len > path_len_max) {
            return error.Invalid;
        }

        @memcpy(buffer[0..name.len], name);

        return buffer[0..name.len];
    }

    return std.fmt.bufPrint(buffer, "{s}.{s}", .{ prefix, name }) catch error.Invalid;
}

pub fn assemble(
    known: []const Kind,
    arena: std.mem.Allocator,
    fields: []const Def,
    rows: []const Row,
) Error!Value {
    std.debug.assert(fields.len <= field.fields_max);
    std.debug.assert(rows.len <= rows_max);

    return assemble_fields(known, arena, fields, rows, "", 0);
}

fn assemble_fields(
    known: []const Kind,
    arena: std.mem.Allocator,
    fields: []const Def,
    rows: []const Row,
    prefix: []const u8,
    ordinal: i64,
) Error!Value {
    std.debug.assert(prefix.len <= path_len_max);
    std.debug.assert(ordinal >= 0);

    var object: std.json.ObjectMap = .empty;

    for (fields) |def| {
        var path_buffer: [path_len_max]u8 = undefined;
        const path = try join(&path_buffer, prefix, def.name);
        const value: ?Value = if (field.is_group(def.kind))
            try assemble_group(known, arena, def, rows, path, ordinal)
        else if (field.is_repeater(def.kind))
            try assemble_repeater(known, arena, def, rows, path)
        else if (def.many)
            try assemble_many(known, arena, def, rows, path)
        else
            assemble_leaf(known, def, rows, path, ordinal);

        if (value) |present| {
            const key = arena.dupe(u8, def.name) catch return error.OutOfMemory;
            object.put(arena, key, present) catch return error.OutOfMemory;
        }
    }

    return .{ .object = object };
}

fn assemble_group(
    known: []const Kind,
    arena: std.mem.Allocator,
    def: Def,
    rows: []const Row,
    path: []const u8,
    ordinal: i64,
) Error!?Value {
    std.debug.assert(field.is_group(def.kind));
    std.debug.assert(path.len > 0);

    if (!has_prefix(rows, path)) {
        return null;
    }

    return try assemble_fields(known, arena, def.fields, rows, path, ordinal);
}

fn assemble_repeater(
    known: []const Kind,
    arena: std.mem.Allocator,
    def: Def,
    rows: []const Row,
    path: []const u8,
) Error!?Value {
    std.debug.assert(field.is_repeater(def.kind));
    std.debug.assert(path.len > 0);

    const count = item_count(rows, path);

    if (count == 0) {
        return null;
    }

    var array = std.json.Array.init(arena);
    var index: i64 = 0;

    while (index < count) : (index += 1) {
        const item = try assemble_fields(known, arena, def.fields, rows, path, index);
        array.append(item) catch return error.OutOfMemory;
    }

    return .{ .array = array };
}

fn assemble_many(
    known: []const Kind,
    arena: std.mem.Allocator,
    def: Def,
    rows: []const Row,
    path: []const u8,
) Error!?Value {
    std.debug.assert(def.many);
    std.debug.assert(path.len > 0);

    const storage = kinds.lookup(known, def.kind).storage;
    var array = std.json.Array.init(arena);

    for (rows) |row| {
        if (std.mem.eql(u8, row.field, path)) {
            array.append(leaf_value(storage, row)) catch return error.OutOfMemory;
        }
    }

    if (array.items.len == 0) {
        return null;
    }

    return .{ .array = array };
}

fn assemble_leaf(
    known: []const Kind,
    def: Def,
    rows: []const Row,
    path: []const u8,
    ordinal: i64,
) ?Value {
    std.debug.assert(field.is_leaf(def.kind));
    std.debug.assert(path.len > 0);

    const storage = kinds.lookup(known, def.kind).storage;

    for (rows) |row| {
        if (row.ordinal == ordinal and std.mem.eql(u8, row.field, path)) {
            return leaf_value(storage, row);
        }
    }

    return null;
}

fn leaf_value(storage: kinds.Storage, row: Row) Value {
    std.debug.assert(storage != .none);
    std.debug.assert(row.field.len > 0);

    return switch (row.value) {
        .text => |text| .{ .string = text },
        .real => |number| .{ .float = number },
        .integer => |number| if (storage == .bool)
            .{ .bool = number != 0 }
        else
            .{ .integer = number },
    };
}

fn has_prefix(rows: []const Row, path: []const u8) bool {
    std.debug.assert(path.len > 0);
    std.debug.assert(rows.len <= rows_max);

    for (rows) |row| {
        if (row.field.len > path.len and row.field[path.len] == '.' and
            std.mem.startsWith(u8, row.field, path))
        {
            return true;
        }
    }

    return false;
}

fn item_count(rows: []const Row, path: []const u8) i64 {
    std.debug.assert(path.len > 0);
    std.debug.assert(rows.len <= rows_max);

    var highest: i64 = -1;

    for (rows) |row| {
        const child = row.field.len > path.len and row.field[path.len] == '.' and
            std.mem.startsWith(u8, row.field, path);

        if (child and row.ordinal > highest) {
            highest = row.ordinal;
        }
    }

    return highest + 1;
}

/// The record's title: the value of the type's title field, which must be a non-empty
/// string; empty when the type has no title field.
pub fn title_of(def: TypeDef, document: std.json.Value) Error![]const u8 {
    std.debug.assert(document == .object);
    std.debug.assert(def.fields.len <= field.fields_max);

    const title_field = content_type_rules.title_field_of(def) orelse return "";
    const value = document.object.get(title_field.name) orelse return error.Invalid;

    return switch (value) {
        .string => |text| if (text.len == 0) error.Invalid else text,
        else => error.Invalid,
    };
}

pub fn slug_of(def: TypeDef, document: std.json.Value) ?[]const u8 {
    std.debug.assert(document == .object);
    std.debug.assert(def.fields.len <= field.fields_max);

    const slug_field = slug_field_of(def) orelse return null;
    const value = document.object.get(slug_field.name) orelse return null;

    return switch (value) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    };
}

pub fn slug_field_of(def: TypeDef) ?*const field.Def {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(def.fields.len <= field.fields_max);

    for (def.fields) |*candidate| {
        if (field.is_slug(candidate.kind)) {
            return candidate;
        }
    }

    return null;
}

pub fn slug_source(
    def: TypeDef,
    slug_field: ?*const field.Def,
    document: std.json.Value,
    title: []const u8,
) []const u8 {
    std.debug.assert(document == .object);
    std.debug.assert(def.fields.len <= field.fields_max);

    const found = slug_field orelse return title;

    if (found.options.source.len == 0) {
        return title;
    }

    std.debug.assert(field.is_slug(found.kind));

    const source = document.object.get(found.options.source) orelse return title;

    return switch (source) {
        .string => |text| if (text.len > 0) text else title,
        else => title,
    };
}

pub fn find_path(fields: []const field.Def, path: []const u8) ?*const field.Def {
    std.debug.assert(fields.len <= field.fields_max);
    std.debug.assert(path.len <= 64 << 10);

    const dot = std.mem.indexOfScalar(u8, path, '.');
    const head = if (dot) |index| path[0..index] else path;
    const found = find_field(fields, head) orelse return null;

    if (dot == null) {
        return if (field.is_leaf(found.kind)) found else null;
    }

    if (field.is_leaf(found.kind)) {
        return null;
    }

    return find_path(found.fields, path[dot.? + 1 ..]);
}

pub fn parse_int_like(text: []const u8) ?i64 {
    std.debug.assert(text.len <= 64 << 10);

    if (std.mem.eql(u8, text, "true")) {
        return 1;
    }

    if (std.mem.eql(u8, text, "false")) {
        return 0;
    }

    return std.fmt.parseInt(i64, text, 10) catch null;
}
