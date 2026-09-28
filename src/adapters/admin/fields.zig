//! A content type's fields as the record form's rows, one per top-level field, each in
//! the shape its kind and cardinality call for: one control, a list of them, a group's
//! fields inline, a repeater's items boxed, or a JSON textarea for what has no control.
//! Reading the form back is `fields/decode.zig`; adding, removing and moving values
//! without saving is `fields/reshape.zig`.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../app/registry.zig");
const model = @import("../../model.zig");
const record_operations = @import("../../operations/record.zig");
const time = @import("../../lib/time.zig");

pub const decode = @import("fields/decode.zig");
pub const reshape = @import("fields/reshape.zig");

const Error = admin.Error;
const Def = model.field.Def;
const Kind = model.kinds.Kind;
const Value = std.json.Value;
const views = admin.views.RecordFields;
pub const Row = views.FieldsItem;
pub const Record = record_operations.Record;

pub const json_bytes_max: u32 = 1 << 20;
pub const items_max: u32 = model.document.items_max;
const text_rows: f64 = 8;
const json_rows: f64 = 6;

/// A record a reference points at, resolved once so every card can name it.
pub const Referenced = struct { id: []const u8, record: Record, type_name: []const u8 };

/// A record type a reference field may point at.
pub const TypeOption = struct { handle: []const u8, name: []const u8 };

/// The record types the reference field at `path` (`tags`, `faq.link`) may point at.
pub const PathTypes = struct { path: []const u8, types: []const TypeOption };

/// A term of the taxonomy a terms field draws from, in tree order.
pub const TermOption = struct { id: []const u8, title: []const u8, depth: u32 };

/// The terms the terms field at `path` may select from.
pub const PathTerms = struct { path: []const u8, terms: []const TermOption };

/// How many target types a dropdown lists before it gets a search box.
pub const search_from: u32 = 8;

pub const Context = struct {
    arena: std.mem.Allocator,
    users: []const @import("../../operations/user.zig").Options.Option = &.{},
    referenced: []const Referenced,
    types: []const PathTypes,
    /// The terms every explicit terms field may select from, by field path.
    terms: []const PathTerms = &.{},
    /// `https://site/posts/` when the type has an address; empty otherwise.
    slug_prefix: []const u8,
    /// The record is live: a slug locked on publish is shown, not edited.
    live: bool = false,
};

const Option = struct { value: []const u8, label: []const u8, selected: bool };

/// One value as the form shows it, before it becomes an item, a part or a cell.
const Instance = struct {
    name: []const u8,
    label: []const u8,
    conditions: []const u8 = "[]",
    value_kind: []const u8 = "",
    required: bool,
    help: []const u8 = "",
    control: []const u8 = "input",
    value: []const u8 = "",
    checked: bool = false,
    readonly: bool = false,
    /// Text beside a switch or checkbox: what "on" means.
    label_on: []const u8 = "",
    placeholder: []const u8 = "",
    rows: f64 = 0,
    min: []const u8 = "",
    max: []const u8 = "",
    step: []const u8 = "",
    prefix: []const u8 = "",
    suffix: []const u8 = "",
    card_type: []const u8 = "",
    card_title: []const u8 = "",
    card_status: []const u8 = "",
    card_tone: []const u8 = "neutral",
    card_href: []const u8 = "",
    remove: []const u8 = "",
    up: []const u8 = "",
    down: []const u8 = "",
    options: []const Option = &.{},
};

/// One row per top-level field, filled from `document` when there is one.
pub fn rows_of(context: Context, fields: []const Def, document: ?Value) Error![]const Row {
    std.debug.assert(document == null or document.? == .object);
    std.debug.assert(fields.len <= model.field.fields_max);

    var rows: std.ArrayList(Row) = .empty;

    for (fields) |def| {
        const current: ?Value = if (document) |doc| doc.object.get(def.name) else null;

        // A taxonomy's own terms field is drawn in the aside (RecordTerms), not among the
        // rows; a terms field authored on the type is a control like any other.
        if (kind_of(def).has.taxonomy and def.locked) {
            continue;
        }

        const row = try row_of(context, def, current);

        rows.append(context.arena, row) catch return error.OutOfMemory;
    }

    return rows.items;
}

fn row_shell(context: Context, def: Def) Error!Row {
    std.debug.assert(def.name.len > 0);
    const kind = kind_of(def);
    return .{
        .name = def.name,
        .conditions = try std.json.Stringify.valueAlloc(context.arena, def.conditions, .{}),
        .value_kind = def.kind,
        .label = def.label,
        .required = def.required,
        .help = def.help,
        .collapsed = def.options.container.collapsed,
        .can_create = def.options.reference.create,
        .can_link = def.options.reference.link,
        .live_suffix = if (def.options.reference.live_only) ":live" else "",
        .shape = "single",
        .json_value = "",
        .json_rows = json_rows,
        .add = "",
        .add_label = "",
        .choices = &.{},
        .has_pick = kind.has.target,
        .targets = try type_items(context, def.name),
        .any_type = def.options.to.len == 0,
        .pick_search = path_types(context, def.name).len > search_from,
        .first_handle = first_handle_of(path_types(context, def.name)),
        .items = &.{},
        .parts = &.{},
        .entries = &.{},
    };
}

fn row_of(context: Context, def: Def, current: ?Value) Error!Row {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(def.label.len > 0);

    const kind = kind_of(def);
    var row = try row_shell(context, def);

    if (model.field.is_layout(def.kind)) {
        row.shape = def.kind;
    } else if (model.field.is_group(def.kind)) {
        row.shape = "group";
        row.parts = try parts_of(context, def, current);
    } else if (model.field.is_repeater(def.kind)) {
        row.shape = "repeater";
        row.entries = try entries_of(context, def, current);
        row.add = try print(context.arena, "add:{s}", .{def.name});
        row.add_label = add_label_of(def, "Add item");
    } else if (def.many and kind.has.taxonomy) {
        row.shape = "checks";
        row.choices = try term_checks_of(context, def, current);
    } else if (def.many and kind.control == .select and def.options.select.control != .dropdown) {
        row.shape = if (def.options.select.control == .buttons) "buttons" else "checks";
        row.choices = try checks_of(context.arena, def, current);
    } else if (is_json_edited(kind, def)) {
        row.shape = "json";
        row.json_value = if (current) |value| try json_text(context.arena, value) else "";
    } else if (def.many) {
        row.shape = "many";
        row.items = try items_of(context, def, kind, current);
        row.add = try print(context.arena, "add:{s}", .{def.name});
        row.add_label = add_label_of(def, if (kind.has.target) "Add reference" else "Add value");
        row.has_pick = kind.has.target;
    } else {
        const instance = try instance_of(context, def, kind, def.name, def.name, current, false);
        const one = [_]Instance{instance};

        row.items = try convert_all(
            views.ItemsItem,
            views.OptionsItem,
            "options",
            context.arena,
            &one,
        );
    }

    return row;
}

/// A group's fields, drawn inline under its label as `group.child`.
fn parts_of(context: Context, def: Def, current: ?Value) Error![]const views.PartsItem {
    std.debug.assert(model.field.is_group(def.kind));
    std.debug.assert(def.fields.len <= model.field.fields_max);

    const object: ?Value = if (current != null and current.? == .object) current else null;
    const instances = try context.arena.alloc(Instance, def.fields.len);

    for (def.fields, 0..) |child, index| {
        const name = try print(context.arena, "{s}.{s}", .{ def.name, child.name });
        const path = name;
        const value: ?Value = if (object) |present| present.object.get(child.name) else null;

        instances[index] = try nested_of(context, child, name, path, value);
    }

    return convert_all(
        views.PartsItem,
        views.Part_optionsItem,
        "part_options",
        context.arena,
        instances,
    );
}

/// A repeater's items, one box each, its fields as `name[index].child`.
fn entries_of(context: Context, def: Def, current: ?Value) Error![]const views.EntriesItem {
    std.debug.assert(model.field.is_repeater(def.kind));
    std.debug.assert(def.fields.len <= model.field.fields_max);

    const items = array_items(current);
    const count = @min(items.len, items_max);
    const entries = try context.arena.alloc(views.EntriesItem, count);

    for (items[0..count], 0..) |item, index| {
        const name = try print(context.arena, "{s}[{d}]", .{ def.name, index });
        const object: ?Value = if (item == .object) item else null;
        const cells = try context.arena.alloc(Instance, def.fields.len);

        for (def.fields, 0..) |child, child_index| {
            const cell_name = try print(context.arena, "{s}.{s}", .{ name, child.name });
            const path = try print(context.arena, "{s}.{s}", .{ def.name, child.name });
            const value: ?Value = if (object) |present| present.object.get(child.name) else null;

            cells[child_index] = try nested_of(context, child, cell_name, path, value);
        }

        entries[index] = .{
            .name = name,
            .label = try entry_label(context.arena, def, object, @intCast(index)),
            .remove = try print(context.arena, "remove:{s}", .{name}),
            .up = try print(context.arena, "up:{s}", .{name}),
            .down = try print(context.arena, "down:{s}", .{name}),
            .cells = try convert_all(
                views.CellsItem,
                views.Cell_optionsItem,
                "cell_options",
                context.arena,
                cells,
            ),
        };
    }

    return entries;
}

/// The add button's label: the field's own, else the shape's.
fn add_label_of(def: Def, fallback: []const u8) []const u8 {
    std.debug.assert(fallback.len > 0);
    std.debug.assert(def.name.len > 0);

    const own = def.options.container.add_label;

    return if (own.len > 0) own else fallback;
}

/// What names a repeater item in its header: the label field's value when the item has
/// one, else its number.
fn entry_label(arena: std.mem.Allocator, def: Def, item: ?Value, index: u32) Error![]const u8 {
    std.debug.assert(model.field.is_repeater(def.kind));
    std.debug.assert(index < items_max);

    const label_field = def.options.container.label_field;

    if (label_field.len > 0 and item != null) {
        const value = item.?.object.get(label_field);

        if (value != null and value.? == .string and value.?.string.len > 0) {
            return value.?.string;
        }
    }

    return print(arena, "Item {d}", .{index + 1});
}

/// A field inside a group or repeater: one level deep, so a list there is edited as JSON.
fn nested_of(
    context: Context,
    def: Def,
    name: []const u8,
    path: []const u8,
    current: ?Value,
) Error!Instance {
    std.debug.assert(name.len > def.name.len);
    std.debug.assert(model.field.is_leaf(def.kind));

    const kind = kind_of(def);

    if (def.many or kind.control == .json) {
        return .{
            .name = name,
            .label = def.label,
            .required = def.required,
            .help = def.help,
            .conditions = try std.json.Stringify.valueAlloc(context.arena, def.conditions, .{}),
            .value_kind = def.kind,
            .control = "json",
            .rows = json_rows,
            .value = if (current) |value| try json_text(context.arena, value) else "",
        };
    }

    return instance_of(context, def, kind, name, path, current, false);
}

/// A list's values, one control each as `name[index]`, with their move and remove actions.
fn items_of(context: Context, def: Def, kind: Kind, current: ?Value) Error![]const views.ItemsItem {
    std.debug.assert(def.many);
    std.debug.assert(std.mem.eql(u8, kind.id, def.kind));

    const values = array_items(current);
    const count = @min(values.len, items_max);
    const instances = try context.arena.alloc(Instance, count);

    for (values[0..count], 0..) |value, index| {
        const name = try print(context.arena, "{s}[{d}]", .{ def.name, index });

        instances[index] = try instance_of(context, def, kind, name, def.name, value, true);
    }

    return convert_all(views.ItemsItem, views.OptionsItem, "options", context.arena, instances);
}

/// One control for one value, drawn by the kind's descriptor.
fn instance_of(
    context: Context,
    def: Def,
    kind: Kind,
    name: []const u8,
    path: []const u8,
    current: ?Value,
    in_list: bool,
) Error!Instance {
    std.debug.assert(name.len > 0);
    std.debug.assert(path.len > 0);

    var instance: Instance = .{
        .name = name,
        .conditions = try std.json.Stringify.valueAlloc(context.arena, def.conditions, .{}),
        .value_kind = def.kind,
        .label = def.label,
        .required = def.required,
        .help = def.help,
        .placeholder = if (def.options.placeholder.len > 0)
            def.options.placeholder
        else
            kind.placeholder,
    };

    if (in_list) {
        instance.remove = try print(context.arena, "remove:{s}", .{name});
        instance.up = try print(context.arena, "up:{s}", .{name});
        instance.down = try print(context.arena, "down:{s}", .{name});
    }

    switch (kind.control) {
        .textarea => {
            instance.control = "textarea";
            instance.rows = if (def.options.rows) |rows| rows else text_rows;
            instance.value = try text_of(context.arena, current);
        },
        .checkbox => try fill_boolean(context, &instance, def, current),
        .select => {
            const listed = def.options.select.control != .dropdown;

            instance.control = if (listed and !in_list)
                (if (def.options.select.control == .buttons) "buttons" else "radios")
            else
                "select";
            instance.options = if (kind.has.taxonomy)
                try term_options(context, path, current)
            else
                try choice_options(context.arena, def, current);
        },
        .number => try fill_number(context, &instance, def, kind, current),
        .datetime => {
            const day_only = def.options.date.format == .date;

            instance.control = if (day_only) "date" else "datetime";
            instance.value = try datetime_text(context.arena, current, day_only);
        },
        .input => try fill_input(context, &instance, def, kind, path, current, in_list),
        .json => {
            instance.control = "json";
            instance.rows = json_rows;
            instance.value = if (current) |value| try json_text(context.arena, value) else "";
        },
    }

    return instance;
}

/// A switch, a checkbox, or two radios, each with the labels the field gives its states.
fn fill_boolean(context: Context, instance: *Instance, def: Def, current: ?Value) Error!void {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(context.referenced.len <= items_max);

    const flags = def.options.boolean;
    const on = current != null and current.? == .bool and current.?.bool;
    const yes = if (flags.true_label.len > 0) flags.true_label else "Yes";
    const no = if (flags.false_label.len > 0) flags.false_label else "No";

    instance.checked = on;

    switch (flags.control) {
        .toggle => {
            instance.control = "switch";
            instance.label_on = flags.true_label;
        },
        .checkbox => {
            instance.control = "checkbox";
            instance.label_on = flags.true_label;
        },
        .radio => {
            const options = try context.arena.alloc(Option, 2);

            options[0] = .{ .value = "1", .label = yes, .selected = on };
            options[1] = .{ .value = "0", .label = no, .selected = current != null and !on };
            instance.control = "radios";
            instance.options = options;
        },
    }
}

/// A number input with its unit, a slider over the range, a rating up to the maximum, or
/// a select when only listed values are allowed.
fn fill_number(
    context: Context,
    instance: *Instance,
    def: Def,
    kind: Kind,
    current: ?Value,
) Error!void {
    std.debug.assert(kind.control == .number);
    std.debug.assert(def.name.len > 0);

    const shape = def.options.number;
    const arena = context.arena;

    instance.control = "number";
    instance.value = try text_of(arena, current);
    instance.min = try number_text(arena, def.options.min);
    instance.max = try number_text(arena, def.options.max);
    instance.step = try step_text(arena, def);
    instance.prefix = if (shape.unit_after) "" else shape.unit;
    instance.suffix = if (shape.unit_after) shape.unit else "";

    if (def.options.choices.len > 0) {
        instance.control = "select";
        instance.options = try choice_options(arena, def, current);
        instance.prefix = "";
        instance.suffix = "";
    } else if (shape.control == .slider and def.options.max != null) {
        instance.control = "range";
    } else if (shape.control == .rating and kind.storage == .int) {
        instance.control = "radios";
        instance.options = try rating_options(arena, def, current);
    }
}

/// The step the input moves by: the field's, else what its decimal places imply.
fn step_text(arena: std.mem.Allocator, def: Def) Error![]const u8 {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(def.options.number.decimals == null or def.options.number.decimals.? <= 10);

    if (def.options.step) |step| {
        return number_text(arena, step);
    }

    const decimals = def.options.number.decimals orelse return "";

    if (decimals == 0) {
        return "1";
    }

    const fraction = try arena.alloc(u8, decimals + 2);

    fraction[0] = '0';
    fraction[1] = '.';
    @memset(fraction[2..], '0');
    fraction[fraction.len - 1] = '1';

    return fraction;
}

/// One radio per step from one to the maximum (five when the field has none).
fn rating_options(arena: std.mem.Allocator, def: Def, current: ?Value) Error![]const Option {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(rating_max > 0);

    const wanted: f64 = def.options.max orelse 5;
    const stars: u32 = @intFromFloat(@min(@max(wanted, 1), rating_max));
    const chosen: ?i64 = if (current != null and current.? == .integer) current.?.integer else null;
    const options = try arena.alloc(Option, stars);

    for (options, 1..) |*option, star| {
        const text = try print(arena, "{d}", .{star});

        const picked = chosen != null and chosen.? == star;

        option.* = .{ .value = text, .label = text, .selected = picked };
    }

    return options;
}

const rating_max: f64 = 10;

/// A select shown as checkboxes: one per choice, named by the choice's index in the list.
fn checks_of(arena: std.mem.Allocator, def: Def, current: ?Value) Error![]const views.ChoicesItem {
    std.debug.assert(def.options.choices.len <= model.field.choices_max);
    std.debug.assert(def.many);

    const chosen = array_items(current);
    const labels = def.options.labels;
    const items = try arena.alloc(views.ChoicesItem, def.options.choices.len);

    for (def.options.choices, 0..) |choice, index| {
        items[index] = .{
            .name = try print(arena, "{s}[{d}]", .{ def.name, index }),
            .value = choice,
            .label = if (labels.len == def.options.choices.len) labels[index] else choice,
            .selected = holds(chosen, choice),
        };
    }

    return items;
}

/// A terms field taking several terms: one checkbox per term of its taxonomy, every box
/// under the field's name, indented by the term's depth in its title.
fn term_checks_of(context: Context, def: Def, current: ?Value) Error![]const views.ChoicesItem {
    std.debug.assert(def.many);
    std.debug.assert(def.options.taxonomy.len > 0);

    const chosen = array_items(current);
    const terms = path_terms(context, def.name);
    const items = try context.arena.alloc(views.ChoicesItem, terms.len);

    for (terms, items) |term, *item| {
        item.* = .{
            .name = def.name,
            .value = term.id,
            .label = try indented(context.arena, term),
            .selected = holds(chosen, term.id),
        };
    }

    return items;
}

/// A terms field taking one term: a dropdown over its taxonomy's terms.
fn term_options(context: Context, path: []const u8, current: ?Value) Error![]const Option {
    std.debug.assert(path.len > 0);
    std.debug.assert(context.terms.len <= model.field.fields_max * model.field.fields_max);

    const chosen: ?[]const u8 = if (current != null and current.? == .string)
        current.?.string
    else
        null;
    const terms = path_terms(context, path);
    const options = try context.arena.alloc(Option, terms.len + 1);

    options[0] = .{ .value = "", .label = "", .selected = chosen == null };

    for (terms, 1..) |term, index| {
        options[index] = .{
            .value = term.id,
            .label = try indented(context.arena, term),
            .selected = chosen != null and std.mem.eql(u8, chosen.?, term.id),
        };
    }

    return options;
}

fn path_terms(context: Context, path: []const u8) []const TermOption {
    std.debug.assert(path.len > 0);
    std.debug.assert(context.terms.len <= model.field.fields_max * model.field.fields_max);

    for (context.terms) |entry| {
        if (std.mem.eql(u8, entry.path, path)) {
            return entry.terms;
        }
    }

    return &.{};
}

/// A term's title at its depth: two figure spaces and a dash per level.
fn indented(arena: std.mem.Allocator, term: TermOption) Error![]const u8 {
    std.debug.assert(term.depth < model.tree.depth_max);
    std.debug.assert(term.title.len <= model.kinds.string_len_max);

    if (term.depth == 0) {
        return term.title;
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    var level: u32 = 0;

    while (level < term.depth) : (level += 1) {
        out.writer.writeAll("\u{2007}\u{2007}") catch return error.OutOfMemory;
    }

    out.writer.print("- {s}", .{term.title}) catch return error.OutOfMemory;

    return out.written();
}

fn holds(items: []const Value, text: []const u8) bool {
    std.debug.assert(items.len <= items_max);
    std.debug.assert(text.len <= model.kinds.string_len_max);

    for (items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, text)) {
            return true;
        }
    }

    return false;
}

fn fill_user(context: Context, instance: *Instance) Error!void {
    std.debug.assert(instance.name.len > 0);
    std.debug.assert(context.users.len <= 1000);
    instance.control = "select";
    const options = try context.arena.alloc(Option, context.users.len + 2);
    options[0] = .{
        .value = "",
        .label = "Select a user",
        .selected = instance.value.len == 0,
    };

    for (context.users, 0..) |user, index| {
        options[index + 1] = .{
            .value = user.id,
            .label = user.label,
            .selected = std.mem.eql(
                u8,
                instance.value,
                user.id,
            ),
        };
    }

    options[context.users.len + 1] = .{
        .value = instance.value,
        .label = "Previously selected user",
        .selected = true,
    };
    var found = instance.value.len == 0;

    for (context.users) |user| {
        found = found or std.mem.eql(u8, user.id, instance.value);
    }

    instance.options = options[0 .. context.users.len + (if (found) @as(u32, 1) else 2)];
}

/// A plain input, unless the kind is a slug (the address in front of it) or a reference
/// (a card of the record it points at; a slot to pick one while it points nowhere).
fn fill_input(
    context: Context,
    instance: *Instance,
    def: Def,
    kind: Kind,
    path: []const u8,
    current: ?Value,
    in_list: bool,
) Error!void {
    std.debug.assert(kind.control == .input);
    std.debug.assert(path.len > 0);

    instance.value = try text_of(context.arena, current);

    const native = std.mem.eql(u8, def.kind, "color") or std.mem.eql(u8, def.kind, "time") or
        std.mem.eql(u8, def.kind, "password");

    if (native) {
        instance.control = def.kind;
        return;
    }

    if (std.mem.eql(u8, def.kind, "user")) {
        try fill_user(context, instance);
        return;
    }

    if (model.field.is_slug(def.kind)) {
        instance.control = "slug";
        instance.prefix = context.slug_prefix;
        instance.readonly = context.live and def.options.slug.lock_on_publish;

        return;
    }

    if (!kind.has.target) {
        return;
    }

    if (!in_list and instance.value.len == 0) {
        instance.control = "pick";

        return;
    }

    const found = referenced_of(context, instance.value);
    const status = if (found) |seen| registry.Statuses.find(seen.record.status) else null;

    instance.control = "card";
    instance.card_type = if (found) |seen| seen.type_name else "";
    instance.card_title = if (found) |seen| title_of(seen.record) else instance.value;
    instance.card_status = if (status) |known| known.label else "";
    instance.card_tone = if (status) |known| tone_of(known.color) else "neutral";
    instance.card_href = try print(context.arena, "/admin/content/{s}", .{instance.value});

    if (!in_list) {
        instance.remove = try print(context.arena, "clear:{s}", .{instance.name});
    }
}

/// The status registry's colour as the design system's status tone.
fn tone_of(color: model.status.Color) []const u8 {
    std.debug.assert(@intFromEnum(color) <= 4);
    std.debug.assert(@typeInfo(model.status.Color).@"enum".fields.len == 5);

    return switch (color) {
        .neutral => "neutral",
        .info => "accent",
        .success => "success",
        .warning => "warning",
        .danger => "error",
    };
}

fn referenced_of(context: Context, id: []const u8) ?Referenced {
    std.debug.assert(id.len <= model.validate.id_len_max or id.len == 0);
    std.debug.assert(context.referenced.len <= items_max);

    for (context.referenced) |seen| {
        if (std.mem.eql(u8, seen.id, id)) {
            return seen;
        }
    }

    return null;
}

fn path_types(context: Context, path: []const u8) []const TypeOption {
    std.debug.assert(path.len > 0);
    std.debug.assert(context.types.len <= model.field.fields_max * model.field.fields_max);

    for (context.types) |entry| {
        if (std.mem.eql(u8, entry.path, path)) {
            return entry.types;
        }
    }

    return &.{};
}

fn type_items(context: Context, path: []const u8) Error![]const views.TargetsItem {
    std.debug.assert(path.len > 0);
    std.debug.assert(context.types.len <= model.field.fields_max * model.field.fields_max);

    const types = path_types(context, path);
    const items = try context.arena.alloc(views.TargetsItem, types.len);

    for (types, 0..) |option, index| {
        items[index] = .{ .handle = option.handle, .name = option.name };
    }

    return items;
}

/// The one type a reference may point at, when it is exactly one: the plain buttons.
fn first_handle_of(types: []const TypeOption) []const u8 {
    std.debug.assert(types.len <= model.field.targets_max * 4);
    std.debug.assert(search_from > 0);

    return if (types.len == 1) types[0].handle else "";
}

fn array_items(current: ?Value) []const Value {
    std.debug.assert(items_max > 0);
    std.debug.assert(current == null or @intFromEnum(current.?) >= 0);

    const value = current orelse return &.{};

    return if (value == .array) value.array.items else &.{};
}

fn kind_of(def: Def) Kind {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(registry.Kinds.all.len > 0);

    return model.kinds.lookup(registry.Kinds.all, def.kind);
}

/// Groups, repeaters and lists have shapes of their own; a kind without a control, and a
/// list of booleans (a checkbox cannot say it is absent), are edited as JSON.
pub fn is_json_edited(kind: Kind, def: Def) bool {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(std.mem.eql(u8, kind.id, def.kind) or kind.id.len == 0);

    return kind.control == .json or (def.many and kind.storage == .bool);
}

fn choice_options(arena: std.mem.Allocator, def: Def, current: ?Value) Error![]const Option {
    std.debug.assert(def.options.choices.len <= model.field.choices_max);
    std.debug.assert(def.name.len > 0);

    const chosen: ?[]const u8 = if (current == null)
        null
    else switch (current.?) {
        .string => |text| text,
        .integer, .float => try text_of(arena, current),
        else => null,
    };
    const options = try arena.alloc(Option, def.options.choices.len + 1);

    options[0] = .{ .value = "", .label = "", .selected = chosen == null };

    const labels = def.options.labels;

    for (def.options.choices, 1..) |choice, index| {
        options[index] = .{
            .value = choice,
            .label = if (labels.len == def.options.choices.len) labels[index - 1] else choice,
            .selected = chosen != null and std.mem.eql(u8, chosen.?, choice),
        };
    }

    return options;
}

fn title_of(record: Record) []const u8 {
    std.debug.assert(record.id.len > 0);
    std.debug.assert(record.status.len > 0);

    return if (record.title.len > 0) record.title else record.id;
}

/// The same instance as whichever item type the view wants it in.
fn convert_all(
    comptime Item: type,
    comptime OptionItem: type,
    comptime options_field: []const u8,
    arena: std.mem.Allocator,
    instances: []const Instance,
) Error![]const Item {
    std.debug.assert(instances.len <= items_max);
    std.debug.assert(@hasField(Item, options_field));

    const items = try arena.alloc(Item, instances.len);

    for (instances, 0..) |instance, index| {
        const options = try arena.alloc(OptionItem, instance.options.len);

        for (instance.options, 0..) |option, option_index| {
            options[option_index] = .{
                .value = option.value,
                .label = option.label,
                .selected = option.selected,
            };
        }

        // A value in a list has no help line of its own: the field's row shows it once.
        inline for (std.meta.fields(Instance)) |info| {
            if (comptime !std.mem.eql(u8, info.name, "options") and @hasField(Item, info.name)) {
                @field(items[index], info.name) = @field(instance, info.name);
            }
        }

        @field(items[index], options_field) = options;
    }

    return items;
}

fn json_text(arena: std.mem.Allocator, value: Value) Error![]const u8 {
    std.debug.assert(json_bytes_max > 0);
    std.debug.assert(value != .null);

    return std.json.Stringify.valueAlloc(arena, value, .{}) catch error.OutOfMemory;
}

fn text_of(arena: std.mem.Allocator, current: ?Value) Error![]const u8 {
    std.debug.assert(json_bytes_max > 0);

    const value = current orelse return "";

    return switch (value) {
        .string => |text| text,
        .integer => |number| std.fmt.allocPrint(arena, "{d}", .{number}) catch error.OutOfMemory,
        .float => |number| std.fmt.allocPrint(arena, "{d}", .{number}) catch error.OutOfMemory,
        .bool => |flag| if (flag) "true" else "false",
        else => "",
    };
}

/// What a `datetime-local` input holds, or a `date` input for a field that shows days.
fn datetime_text(arena: std.mem.Allocator, current: ?Value, day_only: bool) Error![]const u8 {
    std.debug.assert(time.ms_max > 0);

    const value = current orelse return "";

    if (value != .integer or value.integer < 0 or value.integer >= time.ms_max) {
        return "";
    }

    if (day_only) {
        return time.date_text(arena, value.integer) catch error.OutOfMemory;
    }

    return time.datetime_local_text(arena, value.integer) catch error.OutOfMemory;
}

fn number_text(arena: std.mem.Allocator, number: ?f64) Error![]const u8 {
    std.debug.assert(json_bytes_max > 0);

    const value = number orelse return "";

    std.debug.assert(!std.math.isNan(value));

    return print(arena, "{d}", .{value});
}

pub fn print(
    arena: std.mem.Allocator,
    comptime template: []const u8,
    args: anytype,
) Error![]const u8 {
    std.debug.assert(template.len > 0);
    std.debug.assert(std.mem.indexOfScalar(u8, template, '{') != null);

    return std.fmt.allocPrint(arena, template, args) catch error.OutOfMemory;
}

test {
    std.testing.refAllDecls(@This());
}
