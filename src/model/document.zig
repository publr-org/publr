//! A record's document as data: the JSON object a caller sees, and the rows it becomes in
//! `record_values`. `flatten` turns the object into rows (one per field value, dotted
//! paths for groups, ordinals for repeaters and many-valued fields); `assemble` turns rows
//! back into the object. Title and slug rules live here too. No database anywhere.

const std = @import("std");
const field = @import("field.zig");
const kinds = @import("kinds.zig");
const currency = @import("currency.zig");
const variant = @import("variant.zig");

const Def = field.Def;
const Kind = kinds.Kind;
const Value = std.json.Value;
const content_type_rules = @import("content_type.zig");
const TypeDef = content_type_rules.Def;
const find_field = content_type_rules.find_field;

pub const path_len_max: u32 = 256;
pub const items_max: u32 = 1000;
pub const rows_max: u32 = 100_000;
/// Values one document holds: the build's limit (`limits.zig`).
pub const flat_max: u32 = @import("limits.zig").entry_values_max;
pub const Error = error{ Invalid, OutOfMemory };

pub const Stored = union(enum) {
    integer: i64,
    real: f64,
    text: []const u8,
};

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
    /// The kind's `.text`, for the search index: a plugin's kind only.
    text: ?kinds.Text = null,
};

/// Where `each_row` hands each row of a document: `row` runs while the walk is at the
/// value, and the row's field path lives only during that call (copy it to keep it).
pub const Sink = struct {
    context: *anyopaque,
    row: *const fn (context: *anyopaque, flat: Flat) Error!void,
};

/// Each row of the document handed to `sink` as the walk reaches it, in document order;
/// how many there were. Past `flat_max` rows, or on a value the fields refuse, `Invalid`,
/// with the rows before already handed over: check first (`count_rows`) when that matters.
pub fn each_row(known: []const Kind, fields: []const Def, value: Value, sink: Sink) Error!u32 {
    std.debug.assert(fields.len <= field.fields_max);
    std.debug.assert(flat_max > 0);

    if (value != .object) {
        return error.Invalid;
    }

    var flattener: Flattener = .{
        .known = known,
        .sink = sink,
    };

    try flattener.walk(fields, value.object, "", 0);

    return flattener.len;
}

/// How many rows the document makes, every value checked as `each_row` checks it.
pub fn count_rows(known: []const Kind, fields: []const Def, value: Value) Error!u32 {
    std.debug.assert(fields.len <= field.fields_max);

    const Discard = struct {
        fn row(_: *anyopaque, flat: Flat) Error!void {
            std.debug.assert(flat.field.len > 0);
        }
    };
    var nothing: u8 = 0;

    return each_row(known, fields, value, .{
        .context = &nothing,
        .row = Discard.row,
    });
}

const Flattener = struct {
    known: []const Kind,
    sink: Sink,
    len: u32 = 0,
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
            if (object.get(def.name)) |value| {
                try flattener.walk_value(def, value, prefix, def.name, ordinal);
            }

            if (def.variants) {
                try flattener.walk_variants(def, object, prefix, ordinal);
            }
        }
    }

    /// Each `name@code` key beside the field, stored under that key as its path.
    fn walk_variants(
        flattener: *Flattener,
        def: Def,
        object: std.json.ObjectMap,
        prefix: []const u8,
        ordinal: u32,
    ) Error!void {
        std.debug.assert(def.variants);
        std.debug.assert(prefix.len <= path_len_max);

        var entries = object.iterator();

        while (entries.next()) |entry| {
            const key = variant.split(entry.key_ptr.*);

            if (key.code.len == 0 or !std.mem.eql(u8, key.name, def.name)) {
                continue;
            }

            if (!variant.valid_code(key.code)) {
                return error.Invalid;
            }

            try flattener.walk_value(def, entry.value_ptr.*, prefix, entry.key_ptr.*, ordinal);
        }
    }

    fn walk_value(
        flattener: *Flattener,
        def: Def,
        value: Value,
        prefix: []const u8,
        key: []const u8,
        ordinal: u32,
    ) Error!void {
        std.debug.assert(key.len >= def.name.len);
        std.debug.assert(std.mem.startsWith(u8, key, def.name));

        if (value == .null) {
            return;
        }

        var path_buffer: [path_len_max]u8 = undefined;
        const path = try join(&path_buffer, prefix, key);

        if (field.is_group(def.kind)) {
            try flattener.walk_group(def, value, path, ordinal);
        } else if (field.is_money(def.kind)) {
            try flattener.walk_money(def, value, path, ordinal);
        } else if (field.is_repeater(def.kind)) {
            try flattener.walk_repeater(def, value, path);
        } else if (def.many) {
            try flattener.walk_many(def, value, path);
        } else {
            try flattener.leaf(def, value, path, ordinal);
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

    /// One integer row per currency: `price.GBP`, `price.EUR`.
    fn walk_money(
        flattener: *Flattener,
        def: Def,
        value: Value,
        path: []const u8,
        ordinal: u32,
    ) Error!void {
        std.debug.assert(field.is_money(def.kind));
        std.debug.assert(path.len > 0);

        if (value != .object) {
            return error.Invalid;
        }

        var entries = value.object.iterator();

        while (entries.next()) |entry| {
            if (currency.find(entry.key_ptr.*) == null) {
                return error.Invalid;
            }

            var path_buffer: [path_len_max]u8 = undefined;
            const amount_path = try join(&path_buffer, path, entry.key_ptr.*);

            try flattener.leaf(def, entry.value_ptr.*, amount_path, ordinal);
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
            .text, .ref, .long => .{
                .text = try expect_string(value),
            },
            .int, .bool => .{
                .integer = try expect_int(kind.storage, value),
            },
            .real => .{
                .real = try expect_real(value),
            },
            .none => unreachable,
        };
        flattener.len += 1;
        try flattener.sink.row(flattener.sink.context, .{
            .field = path,
            .ordinal = ordinal,
            .column = kinds.column_of(kind.storage),
            .value = stored,
            .searchable = def.searchable and value == .string,
            .text = kind.text,
        });
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
        try assemble_key(known, arena, def, rows, prefix, def.name, ordinal, &object);

        if (def.variants) {
            const codes = try codes_under(arena, rows, prefix, def.name);

            for (codes) |code| {
                const key = try variant.key_of(arena, def.name, code);

                try assemble_key(known, arena, def, rows, prefix, key, ordinal, &object);
            }
        }
    }

    return .{
        .object = object,
    };
}

fn assemble_key(
    known: []const Kind,
    arena: std.mem.Allocator,
    def: Def,
    rows: []const Row,
    prefix: []const u8,
    key: []const u8,
    ordinal: i64,
    object: *std.json.ObjectMap,
) Error!void {
    std.debug.assert(std.mem.startsWith(u8, key, def.name));
    std.debug.assert(ordinal >= 0);

    var path_buffer: [path_len_max]u8 = undefined;
    const path = try join(&path_buffer, prefix, key);
    const value: ?Value = if (field.is_group(def.kind))
        try assemble_group(known, arena, def, rows, path, ordinal)
    else if (field.is_money(def.kind))
        try assemble_money(arena, rows, path, ordinal)
    else if (field.is_repeater(def.kind))
        try assemble_repeater(known, arena, def, rows, path)
    else if (def.many)
        try assemble_many(known, arena, def, rows, path)
    else
        assemble_leaf(known, def, rows, path, ordinal);

    if (value) |present| {
        const kept = arena.dupe(u8, key) catch return error.OutOfMemory;
        object.put(arena, kept, present) catch return error.OutOfMemory;
    }
}

/// The variant codes rows hold for `name` at this level: `prefix.name@code`, alone or
/// followed by a deeper path. Each once.
fn codes_under(
    arena: std.mem.Allocator,
    rows: []const Row,
    prefix: []const u8,
    name: []const u8,
) Error![]const []const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(rows.len <= rows_max);

    var head_buffer: [path_len_max]u8 = undefined;
    const path = try join(&head_buffer, prefix, name);
    var found: std.ArrayList([]const u8) = .empty;

    for (rows) |row| {
        const under = row.field.len > path.len + 1 and std.mem.startsWith(u8, row.field, path) and
            row.field[path.len] == variant.separator;

        if (!under) {
            continue;
        }

        const rest = row.field[path.len + 1 ..];
        const code = rest[0 .. std.mem.indexOfScalar(u8, rest, '.') orelse rest.len];

        if (!variant.valid_code(code) or has_code(found.items, code)) {
            continue;
        }

        found.append(arena, code) catch return error.OutOfMemory;
    }

    return found.items;
}

fn has_code(codes: []const []const u8, code: []const u8) bool {
    std.debug.assert(code.len > 0);
    std.debug.assert(codes.len <= rows_max);

    for (codes) |known_code| {
        if (std.mem.eql(u8, known_code, code)) {
            return true;
        }
    }

    return false;
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

/// `{ "GBP": 850 }` from the rows under `path`: one per currency.
fn assemble_money(
    arena: std.mem.Allocator,
    rows: []const Row,
    path: []const u8,
    ordinal: i64,
) Error!?Value {
    std.debug.assert(path.len > 0);
    std.debug.assert(ordinal >= 0);

    var object: std.json.ObjectMap = .empty;

    for (rows) |row| {
        const under = row.field.len == path.len + 4 and std.mem.startsWith(u8, row.field, path) and
            row.field[path.len] == '.';

        if (row.ordinal != ordinal or !under or row.value != .integer) {
            continue;
        }

        const code = arena.dupe(u8, row.field[path.len + 1 ..]) catch return error.OutOfMemory;

        object.put(arena, code, .{
            .integer = row.value.integer,
        }) catch return error.OutOfMemory;
    }

    return if (object.count() == 0) null else .{
        .object = object,
    };
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

    return .{
        .array = array,
    };
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

    return .{
        .array = array,
    };
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
        .text => |text| .{
            .string = text,
        },
        .real => |number| .{
            .float = number,
        },
        .integer => |number| if (storage == .bool)
            .{
                .bool = number != 0,
            }
        else
            .{
                .integer = number,
            },
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
    const key = variant.split(if (dot) |index| path[0..index] else path);
    const found = find_field(fields, key.name) orelse return null;

    if (key.code.len > 0 and (!found.variants or !variant.valid_code(key.code))) {
        return null;
    }

    if (dot == null) {
        return if (field.is_leaf(found.kind)) found else null;
    }

    if (field.is_money(found.kind)) {
        return if (currency.find(path[dot.? + 1 ..]) != null) found else null;
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

test "money: one row per currency, assembled back, and its paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fields = [_]Def{.{
        .name = "price",
        .label = "Price",
        .kind = "money",
    }};
    const text = "{\"price\":{\"GBP\":850,\"EUR\":990}}";
    const value = try std.json.parseFromSliceLeaky(Value, arena, text, .{});
    const flat = try collected(arena, &kinds.core, &fields, value);

    try std.testing.expectEqual(@as(usize, 2), flat.len);
    try std.testing.expectEqualStrings("price.GBP", flat[0].field);

    var rows: [2]Row = undefined;

    for (flat, &rows) |one, *row| {
        row.* = .{
            .field = one.field,
            .ordinal = 0,
            .value = one.value,
        };
    }

    const back = try assemble(&kinds.core, arena, &fields, &rows);

    const price = back.object.get("price").?;

    try std.testing.expectEqual(@as(i64, 990), price.object.get("EUR").?.integer);
    try std.testing.expect(find_path(&fields, "price.GBP") != null);
    try std.testing.expect(find_path(&fields, "price.ZZZ") == null);
}

test "variants: stored under name@code beside the field, nested too, and read back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const items = [_]Def{.{
        .name = "heading",
        .label = "Heading",
        .kind = "string",
        .variants = true,
    }};
    const fields = [_]Def{
        .{
            .name = "name",
            .label = "Name",
            .kind = "string",
            .variants = true,
        },
        .{
            .name = "sku",
            .label = "SKU",
            .kind = "string",
        },
        .{
            .name = "sections",
            .label = "Sections",
            .kind = "repeater",
            .fields = &items,
            .variants = true,
        },
    };
    const text =
        \\{"name":"Mug","name@pl":"Kubek","name@en-gb":"Mug","sku":"M1","sku@pl":"ignored",
        \\"sections":[{"heading":"One","heading@pl":"Jeden"}],
        \\"sections@de":[{"heading":"Eins"},{"heading":"Zwei"}]}
    ;
    const value = try std.json.parseFromSliceLeaky(Value, arena, text, .{});
    const flat = try collected(arena, &kinds.core, &fields, value);

    try std.testing.expectEqual(@as(usize, 8), flat.len);

    const rows = try arena.alloc(Row, flat.len);

    for (flat, rows) |one, *row| {
        row.* = .{
            .field = one.field,
            .ordinal = one.ordinal,
            .value = one.value,
        };
    }

    const back = try assemble(&kinds.core, arena, &fields, rows);

    try std.testing.expectEqualStrings("Kubek", back.object.get("name@pl").?.string);
    try std.testing.expectEqualStrings("Mug", back.object.get("name@en-gb").?.string);
    try std.testing.expect(back.object.get("sku@pl") == null);

    const sections = back.object.get("sections").?.array.items;
    const german = back.object.get("sections@de").?.array.items;

    try std.testing.expectEqualStrings("Jeden", sections[0].object.get("heading@pl").?.string);
    try std.testing.expectEqualStrings("Zwei", german[1].object.get("heading").?.string);
    try std.testing.expect(find_path(&fields, "name@pl") != null);
    try std.testing.expect(find_path(&fields, "sku@pl") == null);
    try std.testing.expect(find_path(&fields, "name@PL") == null);
    try std.testing.expect(find_path(&fields, "sections.heading@pl") != null);

    const bad = try std.json.parseFromSliceLeaky(Value, arena, "{\"name@PL\":\"x\"}", .{});

    try std.testing.expectError(error.Invalid, collected(arena, &kinds.core, &fields, bad));
}

/// The rows of a document, each path copied to outlive the walk: what a test reads.
fn collected(
    arena: std.mem.Allocator,
    known: []const Kind,
    fields: []const Def,
    value: Value,
) Error![]const Flat {
    std.debug.assert(fields.len <= field.fields_max);

    const Collect = struct {
        arena: std.mem.Allocator,
        rows: std.ArrayList(Flat) = .empty,

        fn row(context: *anyopaque, flat: Flat) Error!void {
            const collect: *@This() = @ptrCast(@alignCast(context));

            std.debug.assert(flat.field.len > 0);

            var kept = flat;

            kept.field = try collect.arena.dupe(u8, flat.field);
            try collect.rows.append(collect.arena, kept);
        }
    };
    var collect: Collect = .{
        .arena = arena,
    };

    _ = try each_row(known, fields, value, .{
        .context = &collect,
        .row = Collect.row,
    });

    return collect.rows.items;
}

test "a row's path is the one it was written at, however many rows follow" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fields = [_]Def{.{
        .name = "items",
        .label = "Items",
        .kind = "repeater",
        .fields = &.{
            .{
                .name = "a",
                .label = "A",
                .kind = "string",
            },
            .{
                .name = "b",
                .label = "B",
                .kind = "string",
            },
        },
    }};
    var items = std.json.Array.init(arena);
    var made: u32 = 0;

    while (made < 600) : (made += 1) {
        var item: std.json.ObjectMap = .empty;

        try item.put(arena, "a", .{
            .string = "x",
        });
        try item.put(arena, "b", .{
            .string = "y",
        });
        try items.append(.{
            .object = item,
        });
    }

    var document: std.json.ObjectMap = .empty;

    try document.put(arena, "items", .{
        .array = items,
    });

    const flat = try collected(arena, &kinds.core, &fields, .{
        .object = document,
    });

    try std.testing.expectEqual(@as(usize, 1200), flat.len);
    try std.testing.expectEqualStrings("items.a", flat[0].field);
    try std.testing.expectEqualStrings("items.b", flat[1199].field);
    try std.testing.expectEqual(@as(u32, 599), flat[1199].ordinal);
    try std.testing.expectEqual(1200, try count_rows(&kinds.core, &fields, .{
        .object = document,
    }));
}
