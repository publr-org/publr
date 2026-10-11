//! The record form back into a document. Names are the paths the form was drawn with:
//! `title`, `tags[1]` for a value in a list, `seo.description` inside a group,
//! `faq[0].question` inside a repeater item. A list or a control-less kind inside a
//! group or repeater arrives as JSON text.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const time = @import("../../../lib/time.zig");

const Form = admin.Form;
const Def = model.field.Def;
const Kind = model.kinds.Kind;
const Value = std.json.Value;

pub const Error = error{ Invalid, OutOfMemory };
pub const json_bytes_max: u32 = 1 << 20;
pub const items_max: u32 = model.document.items_max;

/// The form as the JSON text the record operations take; null when it does not parse.
pub fn document_of(arena: std.mem.Allocator, fields: []const Def, form: *const Form) ?[]const u8 {
    std.debug.assert(fields.len <= model.field.fields_max);
    std.debug.assert(form.len <= admin.form_pairs_max);

    const value = value_of(arena, fields, form) catch return null;

    return std.json.Stringify.valueAlloc(arena, value, .{}) catch null;
}

/// The form as a JSON object.
pub fn value_of(arena: std.mem.Allocator, fields: []const Def, form: *const Form) Error!Value {
    std.debug.assert(fields.len <= model.field.fields_max);
    std.debug.assert(form.len <= admin.form_pairs_max);

    return object_of(arena, fields, form, "");
}

fn object_of(
    arena: std.mem.Allocator,
    fields: []const Def,
    form: *const Form,
    prefix: []const u8,
) Error!Value {
    std.debug.assert(fields.len <= model.field.fields_max);
    std.debug.assert(prefix.len <= model.document.path_len_max);

    var object: std.json.ObjectMap = .empty;

    for (fields) |def| {
        if (model.field.is_layout(def.kind)) {
            continue;
        }
        // Saving keeps a field the document leaves out, so a top-level field the form
        // posted blank (a list under its bare name) is written as null: cleared.
        const posted_blank = prefix.len == 0 and form.get(def.name) != null;
        const value = (try field_value(arena, def, form, prefix)) orelse
            if (posted_blank) Value.null else continue;

        object.put(arena, def.name, value) catch return error.OutOfMemory;
    }

    return .{
        .object = object,
    };
}

/// Null when the field was left empty; an error when what was typed does not parse.
fn field_value(
    arena: std.mem.Allocator,
    def: Def,
    form: *const Form,
    prefix: []const u8,
) Error!?Value {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(prefix.len <= model.document.path_len_max);

    const name = try print(arena, "{s}{s}", .{ prefix, def.name });
    const kind = model.kinds.lookup(registry.Kinds.all, def.kind);

    // A group drawn closed (past the fold) posts its value whole, as JSON.
    if (model.field.is_group(def.kind) and has_exact(form, name)) {
        return closed_value(arena, form, name);
    }

    if (model.field.is_group(def.kind)) {
        const child_prefix = try print(arena, "{s}.", .{name});
        const object = try object_of(arena, def.fields, form, child_prefix);

        return if (filled(object)) object else null;
    }

    if (model.field.is_repeater(def.kind)) {
        return entries_value(arena, def, form, name);
    }

    if (model.field.is_money(def.kind) and !has_exact(form, name)) {
        return money_value(arena, form, name);
    }

    if (kind.has.taxonomy) {
        return terms_value(arena, def, form, name);
    }

    const nested = prefix.len > 0;
    const as_json = kind.control == .json or (def.many and (nested or kind.storage == .bool));

    if (as_json) {
        return json_value(arena, form, name);
    }

    // A multi-select posts each chosen value under the field's own name.
    const multi = kind.control == .select and def.options.select.control == .dropdown;

    if (def.many and multi) {
        return terms_value(arena, def, form, name);
    }

    if (def.many) {
        return list_value(arena, def, kind, form, name);
    }

    return leaf_value(def, kind, form, name);
}

/// Whether a group was filled in: an unticked checkbox still posts `false`, so a group
/// holding nothing else was left empty, and its required parts are not asked for.
fn filled(object: Value) bool {
    std.debug.assert(object == .object);
    std.debug.assert(object.object.count() <= model.field.fields_max);

    for (object.object.values()) |value| {
        if (value != .bool or value.bool) {
            return true;
        }
    }

    return false;
}

/// A repeater's items, `name[0].`, `name[1].`, until an index no pair starts with.
fn entries_value(
    arena: std.mem.Allocator,
    def: Def,
    form: *const Form,
    name: []const u8,
) Error!?Value {
    std.debug.assert(model.field.is_repeater(def.kind));
    std.debug.assert(name.len > 0);

    var array = std.json.Array.init(arena);
    var index: u32 = 0;

    while (index < items_max) {
        const item_name = try print(arena, "{s}[{d}]", .{ name, index });
        const run_name = try print(arena, "{s}[{d}+]", .{ name, index });

        // An item drawn closed (past the fold) posts its value whole, as JSON.
        if (has_exact(form, item_name)) {
            const closed = try closed_value(arena, form, item_name) orelse return error.Invalid;

            array.append(closed) catch return error.OutOfMemory;
            index += 1;
            continue;
        }

        // A run of closed items posts their values as one JSON list.
        if (has_exact(form, run_name)) {
            const run = try json_value(arena, form, run_name) orelse return error.Invalid;

            if (run != .array or run.array.items.len == 0) {
                return error.Invalid;
            }

            if (index + run.array.items.len > items_max) {
                return error.Invalid;
            }

            array.appendSlice(run.array.items) catch return error.OutOfMemory;
            index += @intCast(run.array.items.len);
            continue;
        }

        const item_prefix = try print(arena, "{s}.", .{item_name});

        if (!has_prefix(form, item_prefix)) {
            break;
        }

        const item = try object_of(arena, def.fields, form, item_prefix);

        array.append(item) catch return error.OutOfMemory;
        index += 1;
    }

    return if (array.items.len == 0) null else .{
        .array = array,
    };
}

/// A list's values, `name[0]`, `name[1]`, until an index the form does not carry; a
/// value left blank is dropped.
fn list_value(
    arena: std.mem.Allocator,
    def: Def,
    kind: Kind,
    form: *const Form,
    name: []const u8,
) Error!?Value {
    std.debug.assert(name.len > 0);
    std.debug.assert(kind.storage != .bool);

    // A select drawn as checkboxes posts only the ticked choices, named by their index,
    // so the list has gaps; anything else stops at the first missing index.
    const gapped = kind.control == .select and def.options.select.control == .list;
    const bound: u32 = if (gapped) @intCast(def.options.choices.len) else items_max;
    var array = std.json.Array.init(arena);
    var index: u32 = 0;

    while (index < bound) : (index += 1) {
        const item_name = try print(arena, "{s}[{d}]", .{ name, index });

        if (form.get(item_name) == null) {
            if (gapped) {
                continue;
            }

            break;
        }

        const value = (try leaf_value(def, kind, form, item_name)) orelse continue;

        array.append(value) catch return error.OutOfMemory;
    }

    return if (array.items.len == 0) null else .{
        .array = array,
    };
}

/// A terms field's controls post the field's name once per selected term (a checkbox
/// per term, the combobox's hidden values, a dropdown's one value): every value under
/// the name, in order; a single field takes the first.
fn terms_value(
    arena: std.mem.Allocator,
    def: Def,
    form: *const Form,
    name: []const u8,
) Error!?Value {
    std.debug.assert(name.len > 0);
    std.debug.assert(form.len <= admin.form_pairs_max);

    var array = std.json.Array.init(arena);

    for (form.pairs[0..form.len]) |pair| {
        if (!std.mem.eql(u8, pair.name, name) or pair.value.len == 0) {
            continue;
        }

        if (array.items.len == items_max) {
            return error.Invalid;
        }

        array.append(.{
            .string = pair.value,
        }) catch return error.OutOfMemory;
    }

    if (array.items.len == 0) {
        return null;
    }

    if (!def.many) {
        return array.items[0];
    }

    return .{
        .array = array,
    };
}

fn json_value(arena: std.mem.Allocator, form: *const Form, name: []const u8) Error!?Value {
    std.debug.assert(name.len > 0);
    std.debug.assert(json_bytes_max > 0);

    const text = form.text(name) orelse return null;

    if (text.len > json_bytes_max) {
        return error.Invalid;
    }

    return @import("../../../lib/json.zig").parse(Value, arena, text, .{}) catch error.Invalid;
}

/// An item or group drawn closed: its value as JSON, an object; null when it had none.
fn closed_value(arena: std.mem.Allocator, form: *const Form, name: []const u8) Error!?Value {
    std.debug.assert(name.len > 0);
    std.debug.assert(has_exact(form, name));

    // A closed group that had no value posts its input blank.
    if (form.text(name) == null) {
        return null;
    }

    const value = try json_value(arena, form, name) orelse return null;

    if (value != .object) {
        return error.Invalid;
    }

    return value;
}

fn leaf_value(def: Def, kind: Kind, form: *const Form, name: []const u8) Error!?Value {
    std.debug.assert(name.len > 0);
    std.debug.assert(kind.storage != .none);

    if (kind.storage == .bool) {
        const posted = form.get(name) orelse return .{
            .bool = false,
        };

        return .{
            .bool = !std.mem.eql(u8, posted, "0"),
        };
    }

    const text = form.text(name) orelse return null;

    return switch (kind.storage) {
        .int => if (kind.control == .datetime)
            .{
                .integer = moment_of(def, text) orelse return error.Invalid,
            }
        else
            .{
                .integer = std.fmt.parseInt(i64, text, 10) catch return error.Invalid,
            },
        .real => .{
            .float = std.fmt.parseFloat(f64, text) catch return error.Invalid,
        },
        else => .{
            .string = text,
        },
    };
}

/// A date and time field posts what its control holds: a moment, or a day when the
/// field shows days alone; either is taken whatever the format says.
fn moment_of(def: Def, text: []const u8) ?i64 {
    std.debug.assert(text.len > 0);
    std.debug.assert(def.name.len > 0);

    return time.parse_datetime_local(text) orelse time.parse_date(text);
}

/// A money field's inputs, `price.GBP`, as `{ "GBP": 850 }`: each amount in the currency's
/// minor units; an empty input leaves the currency out.
fn money_value(arena: std.mem.Allocator, form: *const Form, name: []const u8) Error!?Value {
    std.debug.assert(name.len > 0);
    std.debug.assert(form.len <= Form.pairs_max);

    var object: std.json.ObjectMap = .empty;

    for (form.pairs[0..form.len]) |pair| {
        const under = pair.name.len == name.len + 4 and std.mem.startsWith(u8, pair.name, name) and
            pair.name[name.len] == '.';

        if (!under or std.mem.trim(u8, pair.value, " ").len == 0) {
            continue;
        }

        const code = pair.name[name.len + 1 ..];
        const currency = model.currency.find(code) orelse return error.Invalid;
        const amount = model.money.parse_decimal(pair.value, currency.digits) orelse {
            return error.Invalid;
        };

        object.put(arena, code, .{
            .integer = amount,
        }) catch return error.OutOfMemory;
    }

    return if (object.count() == 0) null else .{
        .object = object,
    };
}

/// Whether the form names exactly this field: a money field edited as JSON.
fn has_exact(form: *const Form, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (form.pairs[0..form.len]) |pair| {
        if (std.mem.eql(u8, pair.name, name)) {
            return true;
        }
    }

    return false;
}

fn has_prefix(form: *const Form, prefix: []const u8) bool {
    std.debug.assert(prefix.len > 0);
    std.debug.assert(form.len <= admin.form_pairs_max);

    for (form.pairs[0..form.len]) |pair| {
        if (std.mem.startsWith(u8, pair.name, prefix)) {
            return true;
        }
    }

    return false;
}

fn print(arena: std.mem.Allocator, comptime template: []const u8, args: anytype) Error![]const u8 {
    std.debug.assert(template.len > 0);
    std.debug.assert(std.mem.indexOfScalar(u8, template, '{') != null);

    return std.fmt.allocPrint(arena, template, args) catch error.OutOfMemory;
}

const test_fields = [_]Def{
    .{
        .name = "title",
        .label = "Title",
        .kind = "string",
    },
    .{
        .name = "live",
        .label = "Live",
        .kind = "boolean",
    },
    .{
        .name = "at",
        .label = "At",
        .kind = "datetime",
    },
    .{
        .name = "views",
        .label = "Views",
        .kind = "integer",
    },
    .{
        .name = "tags",
        .label = "Tags",
        .kind = "reference",
        .many = true,
        .options = .{
            .to = &.{"tag"},
        },
    },
    .{
        .name = "seo",
        .label = "SEO",
        .kind = "group",
        .fields = &.{
            .{
                .name = "description",
                .label = "Description",
                .kind = "text",
            },
            .{
                .name = "keywords",
                .label = "Keywords",
                .kind = "string",
                .many = true,
            },
        },
    },
    .{
        .name = "faq",
        .label = "FAQ",
        .kind = "repeater",
        .fields = &.{
            .{
                .name = "question",
                .label = "Q",
                .kind = "string",
            },
        },
    },
    .{
        .name = "topics",
        .label = "Topics",
        .kind = "terms",
        .many = true,
        .options = .{
            .taxonomy = "topics",
        },
    },
    .{
        .name = "section",
        .label = "Section",
        .kind = "terms",
        .options = .{
            .taxonomy = "sections",
        },
    },
};

test "items and groups drawn closed past the fold come back whole from their JSON" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // faq[0] drawn open, faq[1] closed, faq[2..] one run; seo closed.
    const body = "live=1&faq%5B0%5D.question=Why&" ++
        "faq%5B1%5D=%7B%22question%22%3A%22How%22%7D&" ++
        "faq%5B2%2B%5D=%5B%7B%22question%22%3A%22When%22%7D%2C" ++
        "%7B%22question%22%3A%22Who%22%7D%5D&" ++
        "seo=%7B%22description%22%3A%22About%22%7D";
    const form = Form.parse(arena, body).?;
    const text = document_of(arena, &test_fields, &form).?;

    try std.testing.expectEqualStrings(
        "{\"live\":true,\"seo\":{\"description\":\"About\"}," ++
            "\"faq\":[{\"question\":\"Why\"},{\"question\":\"How\"}," ++
            "{\"question\":\"When\"},{\"question\":\"Who\"}]}",
        text,
    );

    // A closed group that had no value posts blank: nothing, not an error.
    const empty = Form.parse(arena, "live=1&seo=").?;
    try std.testing.expectEqualStrings(
        "{\"live\":true,\"seo\":null}",
        document_of(arena, &test_fields, &empty).?,
    );

    const broken = Form.parse(arena, "faq%5B0%2B%5D=%5B%5D").?;
    try std.testing.expect(document_of(arena, &test_fields, &broken) == null);
}

test "the form's paths become the document: lists, groups, repeaters, JSON inside" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = "title=Hello&live=1&at=2026-09-03T12%3A05&views=3&tags%5B0%5D=t1&tags%5B1%5D=&" ++
        "tags%5B2%5D=t3&seo.description=About&seo.keywords=%5B%22a%22%2C%22b%22%5D&" ++
        "faq%5B0%5D.question=Why&faq%5B1%5D.question=";
    const form = Form.parse(arena, body).?;
    const text = document_of(arena, &test_fields, &form).?;

    try std.testing.expectEqualStrings(
        "{\"title\":\"Hello\",\"live\":true,\"at\":1788437100000,\"views\":3," ++
            "\"tags\":[\"t1\",\"t3\"]," ++
            "\"seo\":{\"description\":\"About\",\"keywords\":[\"a\",\"b\"]}," ++
            "\"faq\":[{\"question\":\"Why\"},{}]}",
        text,
    );

    const blank = Form.parse(arena, "live=1").?;
    const only_live = document_of(arena, &test_fields, &blank).?;
    try std.testing.expectEqualStrings("{\"live\":true}", only_live);

    const filed = Form.parse(arena, "live=1&topics=t1&topics=&topics=t2&section=s1&section=s2").?;
    const with_terms = document_of(arena, &test_fields, &filed).?;
    try std.testing.expectEqualStrings(
        "{\"live\":true,\"topics\":[\"t1\",\"t2\"],\"section\":\"s1\"}",
        with_terms,
    );

    const bad = Form.parse(arena, "views=x").?;
    try std.testing.expect(document_of(arena, &test_fields, &bad) == null);
}

test "a field the form posted blank is cleared; one it left out is kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cleared = Form.parse(arena, "title=&tags=&live=1").?;

    try std.testing.expectEqualStrings(
        "{\"title\":null,\"live\":true,\"tags\":null}",
        document_of(arena, &test_fields, &cleared).?,
    );
}

test "a group left empty but for an unticked checkbox is left out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parts = [_]Def{
        .{
            .name = "url",
            .label = "URL",
            .kind = "url",
            .required = true,
        },
        .{
            .name = "new_window",
            .label = "New window",
            .kind = "boolean",
        },
    };
    const link = [_]Def{
        .{
            .name = "link",
            .label = "Link",
            .kind = "group",
            .fields = &parts,
        },
    };

    const untouched = Form.parse(arena, "link.url=").?;
    const ticked = Form.parse(arena, "link.url=&link.new_window=1").?;

    try std.testing.expectEqualStrings("{}", document_of(arena, &link, &untouched).?);
    try std.testing.expectEqualStrings(
        "{\"link\":{\"new_window\":true}}",
        document_of(arena, &link, &ticked).?,
    );
}
