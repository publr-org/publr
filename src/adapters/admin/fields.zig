//! A content type's fields as the record form's rows, one per top-level field, each in
//! the shape its kind and cardinality call for: one control, a list of them, a group's
//! fields inline, a repeater's items boxed, or a JSON textarea for what has no control.
//! Reading the form back is `fields/decode.zig`; adding, removing and moving values
//! without saving is `fields/reshape.zig`.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const statuses = @import("../../operations/status.zig");
const record_operations = @import("../../operations/record.zig");
const time = @import("../../lib/time.zig");

pub const decode = @import("fields/decode.zig");
pub const reshape = @import("fields/reshape.zig");
pub const media = @import("fields/media.zig");
pub const variants = @import("fields/variants.zig");

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
pub const Referenced = struct {
    id: []const u8,
    record: Record,
    type_name: []const u8,
    /// Why the record cannot be linked here as it stands: no longer shared with the app,
    /// deleted, or not readable; empty when nothing is wrong.
    notice: []const u8 = "",
    /// Whether the card leads to the record (in its app, or in the trash).
    link: bool = true,
};

/// A record type a reference field may point at.
pub const TypeOption = struct {
    handle: []const u8,
    name: []const u8,
};

/// The record types the reference field at `path` (`tags`, `faq.link`) may point at.
pub const PathTypes = struct {
    path: []const u8,
    types: []const TypeOption,
};

/// A term of the taxonomy a terms field draws from, in tree order.
pub const TermOption = struct {
    id: []const u8,
    title: []const u8,
    depth: u32,
};

/// The terms the terms field at `path` may select from.
pub const PathTerms = struct {
    path: []const u8,
    terms: []const TermOption,
};

/// How many target types a dropdown lists before it gets a search box.
pub const search_from: u32 = 8;

/// The fold: how many fields a form draws before every repeater item and group after them
/// is drawn closed, its value carried as JSON until it is opened. Nested fields count.
pub const fields_open: u32 = 50;

/// The fields a form has drawn so far, against `fields_open`.
pub const Fold = struct {
    drawn: u32 = 0,
};

pub const Context = struct {
    arena: std.mem.Allocator,
    /// Whose language the form's own words are in.
    session: *const admin.Session,
    users: []const @import("../../operations/user.zig").Options.Option = &.{},
    referenced: []const Referenced,
    types: []const PathTypes,
    /// The terms every explicit terms field may select from, by field path.
    terms: []const PathTerms = &.{},
    /// `https://site/posts/` when the type has an address; empty otherwise.
    slug_prefix: []const u8,
    /// The address a translated slug (`slug@pl`) is under, by language code.
    slug_prefixes: []const SlugPrefix = &.{},
    /// Every status the site knows, core's and each type's own: a referenced record's.
    statuses: []const model.status.Status = &model.status.core_statuses,
    /// The record is live: a slug locked on publish is shown, not edited.
    live: bool = false,
    /// The site's currencies, the default first: one input each on a money field.
    currencies: []const model.money.Entry = &.{},
    /// The record edited, empty for a new one: what its virtual fields list for.
    record_id: []const u8 = "",
    /// A reference set by the virtual field that opened this new record: posted, not shown.
    fixed: []const u8 = "",
    /// Virtual fields whose records cannot be left without this one: removing deletes.
    delete_notes: []const DeleteNote = &.{},
    /// The library files the document's media fields point at, looked up once.
    files: []const media.File = &.{},
    /// Counts the fields drawn; null draws every item and group open.
    fold: ?*Fold = null,
    /// Items and groups past the fold drawn open anyway (`faq[60]`, `seo`): opened, or
    /// holding a problem (`faq[60].question`).
    open: []const []const u8 = &.{},
    /// Past the fold, stop: the rest is not drawn at all (a preview of a long type).
    cut: bool = false,
};

/// `https://site/pl/posts/`: where a page in one language lives.
pub const SlugPrefix = struct {
    code: []const u8,
    prefix: []const u8,
};

/// Why removing a virtual field's record deletes it, by field name.
pub const DeleteNote = struct {
    field: []const u8,
    note: []const u8,
};

const Option = struct {
    value: []const u8,
    label: []const u8,
    selected: bool,
};

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
    /// The formatting a rich text value's editor offers, comma separated.
    formats: []const u8 = "",
    /// The same card as the design system's ItemList takes its items, so a list of
    /// references is drawn by it: the field name as the id the buttons carry.
    id: []const u8 = "",
    title: []const u8 = "",
    type_label: []const u8 = "",
    status: []const u8 = "",
    tone: []const u8 = "neutral",
    href: []const u8 = "",
    remove: []const u8 = "",
    /// Set on a virtual field's cards when removing deletes the record: why.
    delete_note: []const u8 = "",
    up: []const u8 = "",
    down: []const u8 = "",
    options: []const Option = &.{},
    /// A media value inside a group or a repeater: its file as a tile, the families its rules
    /// take, what the file chooser offers, whether new files may be uploaded.
    files: []const media.File = &.{},
    types: []const media.Type = &.{},
    accept: []const u8 = "",
    can_upload: bool = true,
    /// A plugin kind's editor (`editor`): its frame's address, the value the form holds in it.
    src: []const u8 = "",
};

/// One row per top-level field, filled from `document` when there is one.
pub fn rows_of(context: Context, fields: []const Def, document: ?Value) Error![]const Row {
    std.debug.assert(document == null or document.? == .object);
    std.debug.assert(fields.len <= model.field.fields_max);

    var rows: std.ArrayList(Row) = .empty;

    for (fields) |def| {
        const current: ?Value = if (document) |doc| doc.object.get(def.name) else null;

        if (context.cut) {
            if (context.fold) |fold| {
                if (fold.drawn >= fields_open) break;
            }
        }

        // A taxonomy's own terms field is drawn in the aside (RecordTerms), not among the
        // rows; a terms field authored on the type is a control like any other.
        if (kind_of(context, def).has.taxonomy and model.taxonomy.is_implicit(def)) {
            continue;
        }

        const row = try row_of(context, def, current);

        // A repeater counts its items' cells as it draws them (`entries_of`).
        if (context.fold) |fold| {
            if (!std.mem.eql(u8, row.shape, "repeater")) {
                fold.drawn += if (row.closed) 1 else @max(1, @as(u32, @intCast(row.parts.len)));
            }
        }

        rows.append(context.arena, row) catch return error.OutOfMemory;
    }

    return rows.items;
}

/// Whether the item or group `name` is past the fold and not asked open: drawn closed.
fn closed_at(context: Context, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    const fold = context.fold orelse return false;

    return fold.drawn >= fields_open and !asked_open(context.open, name);
}

/// Whether the repeater `name` was asked to list every item: `open` names it alone.
fn listed_at(context: Context, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (context.open) |path| {
        if (std.mem.eql(u8, path, name)) {
            return true;
        }
    }

    return false;
}

/// Whether `name` is past the fold and drawn open because it was asked for.
fn opened_at(context: Context, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    const fold = context.fold orelse return false;

    return fold.drawn >= fields_open and asked_open(context.open, name);
}

/// Whether `open` names `name` or a path inside it (`faq[1]` holds `faq[1].question`).
fn asked_open(open: []const []const u8, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (open) |path| {
        if (!std.mem.startsWith(u8, path, name)) {
            continue;
        }

        if (path.len == name.len or path[name.len] == '.' or path[name.len] == '[') {
            return true;
        }
    }

    return false;
}

fn row_shell(context: Context, def: Def) Error!Row {
    std.debug.assert(def.name.len > 0);
    const kind = kind_of(context, def);
    return .{
        .name = def.name,
        .conditions = try std.json.Stringify.valueAlloc(context.arena, def.conditions, .{}),
        .value_kind = def.kind,
        .label = def.label,
        .required = def.validation.required,
        .help = def.help,
        .hint = try @import("fields/hint.zig").line(context.session, context.arena, def),
        .collapsed = def.options.container.collapsed,
        .closed = false,
        .opened = false,
        .listed = false,
        .can_create = def.options.reference.create,
        .can_link = def.options.reference.link,
        .live_suffix = if (def.validation.reference.live_only) ":live" else "",
        .opener_query = try opener_query_of(context, def),
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
        .many = def.many,
        .list_type = "",
        .types = &.{},
        .accept = "",
        .can_upload = def.options.media.create,
        .files = &.{},
        .items = &.{},
        .parts = &.{},
        .entries = &.{},
    };
}

/// What a virtual field's drawers are opened with: its reference field and this record, so
/// the picker knows where each record sits and a new record starts pointing here.
fn opener_query_of(context: Context, def: Def) Error![]const u8 {
    std.debug.assert(def.name.len > 0);

    if (!model.field.is_virtual(def.kind) or context.record_id.len == 0) {
        return "";
    }

    return print(context.arena, "&via={s}&parent={s}", .{ def.options.via, context.record_id });
}

fn row_of(context: Context, def: Def, current: ?Value) Error!Row {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(def.label.len > 0);

    const kind = kind_of(context, def);
    var row = try row_shell(context, def);
    const fixed = std.mem.eql(u8, def.name, context.fixed) and !def.many;

    if (fixed and current != null and current.? == .string) {
        row.shape = "fixed";
        row.json_value = current.?.string;
    } else if (model.field.is_layout(def.kind)) {
        row.shape = def.kind;
    } else if (model.field.is_group(def.kind)) {
        try fill_group_row(context, &row, def, current);
    } else if (model.field.is_money(def.kind) and (try money_entries(context, current)).len == 1) {
        row.items = try money_single_of(context, def, current);
    } else if (model.field.is_money(def.kind) and (try money_entries(context, current)).len > 0) {
        row.shape = "group";
        row.parts = try money_parts_of(context, def, current);
    } else if (model.field.is_repeater(def.kind)) {
        row.shape = "repeater";
        row.listed = listed_at(context, def.name);
        row.entries = try entries_of(context, def, current);
        row.add = try print(context.arena, "add:{s}", .{def.name});
        row.add_label = add_label_of(def, try context.session.translated("Add item", .{}));
    } else if (def.many and kind.has.taxonomy) {
        row.shape = "checks";
        row.choices = try term_checks_of(context, def, current);
    } else if (def.many and kind.control == .select and def.options.select.control == .dropdown) {
        row.shape = "multiselect";
        row.choices = try checks_of(context.arena, def, current);
        row.json_value = try chosen_tokens(context.arena, row.choices);
    } else if (def.many and kind.control == .select and def.options.select.control != .dropdown) {
        row.shape = if (def.options.select.control == .buttons) "buttons" else "checks";
        row.choices = try checks_of(context.arena, def, current);
    } else if (kind.has.media) {
        try fill_media_row(context, &row, def, current);
    } else if (is_json_edited(kind, def)) {
        row.shape = "json";
        row.json_value = if (current) |value| try json_text(context.arena, value) else "";
    } else if (def.many and list_type_of(def, kind) != null) {
        try fill_list_row(context, &row, def, kind, current);
    } else if (def.many) {
        row.shape = "many";
        row.items = try items_of(context, def, kind, current);

        for (context.delete_notes) |entry| {
            if (std.mem.eql(u8, entry.field, def.name)) {
                for (@constCast(row.items)) |*item| {
                    item.delete_note = entry.note;
                }
            }
        }

        row.add = try print(context.arena, "add:{s}", .{def.name});
        row.add_label = add_label_of(def, try many_add_label(context, kind));
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

/// A group's row: its parts, or past the fold closed with its value as JSON.
fn fill_group_row(context: Context, row: *Row, def: Def, current: ?Value) Error!void {
    std.debug.assert(model.field.is_group(def.kind));
    std.debug.assert(def.name.len > 0);

    row.shape = "group";

    if (closed_at(context, def.name)) {
        row.closed = true;
        row.json_value = if (current) |value| try json_text(context.arena, value) else "";
        return;
    }

    row.opened = opened_at(context, def.name);
    row.parts = try parts_of(context, def, current);
}

/// A media field's row: its files as tiles, and what its rules let people add.
fn fill_media_row(context: Context, row: *Row, def: Def, current: ?Value) Error!void {
    std.debug.assert(kind_of(context, def).has.media);
    std.debug.assert(def.name.len > 0);

    const families = def.validation.media.types;

    row.shape = "media";
    row.files = try media.placed(context.arena, context.files, def, def.name, current);
    row.accept = try media.accept_of(context.arena, families);
    row.types = try media.types_of(context.arena, families);
}

/// A list of plain values the browser edits on its own.
fn fill_list_row(context: Context, row: *Row, def: Def, kind: Kind, current: ?Value) Error!void {
    std.debug.assert(def.many);
    std.debug.assert(list_type_of(def, kind) != null);

    row.shape = "list";
    row.list_type = list_type_of(def, kind).?;
    row.choices = try list_values_of(context, def, kind, current);
    row.add_label = add_label_of(def, try context.session.translated("Add value", .{}));
}

/// A group's fields, drawn inline under its label as `group.child`.
fn parts_of(context: Context, def: Def, current: ?Value) Error![]const views.PartsItem {
    std.debug.assert(model.field.is_group(def.kind));

    return convert_all(
        views.PartsItem,
        views.Part_optionsItem,
        "part_options",
        context.arena,
        try group_instances(context, def, current),
    );
}

fn group_instances(context: Context, def: Def, current: ?Value) Error![]const Instance {
    std.debug.assert(model.field.is_group(def.kind));
    std.debug.assert(def.fields.len <= model.field.fields_max);

    const object: ?Value = if (current != null and current.? == .object) current else null;
    const instances = try context.arena.alloc(Instance, def.fields.len);

    for (def.fields, 0..) |child, index| {
        const name = try print(context.arena, "{s}.{s}", .{ def.name, child.name });
        const path = name;
        const value: ?Value = if (object) |present| present.object.get(child.name) else null;

        instances[index] = try nested_of(context, child, name, path, value);
        // A part is needed only when its group is: an optional link may stay empty whole.
        instances[index].required = child.validation.required and def.validation.required;
    }

    return instances;
}

/// An item line of a run the browser lists: what `ClosedItem` draws.
pub const Line = struct {
    name: []const u8,
    label: []const u8,
    value_json: []const u8,
};

/// What the browser draws when it opens something drawn closed past the fold.
pub const Opened = union(enum) {
    /// An item's or a group's fields.
    cells: []const views.CellsItem,
    /// A run's items, each a closed line.
    lines: []const Line,
};

/// What opening `path` draws (`faq[60]`, `seo`, `faq[59+]`), from `value`, the JSON the form
/// held for it, saved or not.
pub fn opened_of(
    context: Context,
    fields: []const Def,
    path: []const u8,
    value: Value,
) (Error || error{Invalid})!Opened {
    std.debug.assert(path.len > 0);
    std.debug.assert(fields.len <= model.field.fields_max);

    const bracket = std.mem.indexOfScalar(u8, path, '[');
    const base = path[0 .. bracket orelse path.len];
    const def = (model.content_type.find_field(fields, base) orelse return error.Invalid).*;

    if (bracket == null) {
        if (!model.field.is_group(def.kind)) {
            return error.Invalid;
        }

        const current: ?Value = if (value == .null) null else value;
        const instances = try group_instances(context, def, current);

        return .{
            .cells = try convert_all(
                views.CellsItem,
                views.Cell_optionsItem,
                "cell_options",
                context.arena,
                instances,
            ),
        };
    }

    const inner = path[bracket.? + 1 ..];

    if (!model.field.is_repeater(def.kind) or inner.len < 2 or inner[inner.len - 1] != ']') {
        return error.Invalid;
    }

    const digits = inner[0 .. inner.len - 1];

    if (std.mem.endsWith(u8, digits, "+")) {
        const start = std.fmt.parseInt(u32, digits[0 .. digits.len - 1], 10) catch {
            return error.Invalid;
        };

        return .{
            .lines = try lines_of(context, def, start, value),
        };
    }

    const index = std.fmt.parseInt(u32, digits, 10) catch return error.Invalid;

    if (index >= items_max or value != .object) {
        return error.Invalid;
    }

    const label = try entry_label(context, def, value, index);
    const entry = try open_entry(context, def, path, label, value);

    return .{
        .cells = entry.cells,
    };
}

/// A run's items from `start` on, each a closed line.
fn lines_of(
    context: Context,
    def: Def,
    start: u32,
    value: Value,
) (Error || error{Invalid})![]const Line {
    std.debug.assert(model.field.is_repeater(def.kind));

    if (value != .array or start + value.array.items.len > items_max) {
        return error.Invalid;
    }

    const lines = try context.arena.alloc(Line, value.array.items.len);

    for (value.array.items, lines, 0..) |item, *line, offset| {
        const index: u32 = start + @as(u32, @intCast(offset));
        const object: ?Value = if (item == .object) item else null;

        line.* = .{
            .name = try print(context.arena, "{s}[{d}]", .{ def.name, index }),
            .label = try entry_label(context, def, object, index),
            .value_json = try json_text(context.arena, item),
        };
    }

    return lines;
}

/// The currencies a money field shows an input for: the site's, else the ones it holds.
fn money_entries(context: Context, current: ?Value) Error![]const model.money.Entry {
    std.debug.assert(context.currencies.len <= 64);

    if (context.currencies.len > 0) {
        return context.currencies;
    }

    const held = if (current != null and current.? == .object) current.?.object.keys() else &.{};
    const entries = try context.arena.alloc(model.money.Entry, held.len);

    for (held, entries) |code, *entry| {
        entry.* = .{
            .code = code,
        };
    }

    return entries;
}

/// A money field as one decimal input per currency, `price.GBP`, its amount shown in the
/// currency's own decimals (850 is `8.50`).
fn money_parts_of(context: Context, def: Def, current: ?Value) Error![]const views.PartsItem {
    std.debug.assert(model.field.is_money(def.kind));
    std.debug.assert(def.name.len > 0);

    return convert_all(
        views.PartsItem,
        views.Part_optionsItem,
        "part_options",
        context.arena,
        try money_instances(context, def, current),
    );
}

/// A money field in one currency: the amount's input in the field's own row, not a group.
fn money_single_of(context: Context, def: Def, current: ?Value) Error![]const views.ItemsItem {
    std.debug.assert(model.field.is_money(def.kind));
    std.debug.assert(def.name.len > 0);

    const instances = try money_instances(context, def, current);

    std.debug.assert(instances.len == 1);
    @constCast(instances)[0].label = def.label;
    @constCast(instances)[0].required = def.validation.required;

    return convert_all(views.ItemsItem, views.OptionsItem, "options", context.arena, instances);
}

fn money_instances(context: Context, def: Def, current: ?Value) Error![]const Instance {
    std.debug.assert(model.field.is_money(def.kind));

    const entries = try money_entries(context, current);
    const instances = try context.arena.alloc(Instance, entries.len);

    for (entries, instances) |entry, *instance| {
        const code = entry.code;
        const currency = model.currency.find(code);
        const digits: u8 = if (currency) |found| found.digits else 2;
        const object = current != null and current.? == .object;
        const held: ?Value = if (object) current.?.object.get(code) else null;
        var buffer: [32]u8 = undefined;
        const amount = if (held != null and held.? == .integer)
            try context.arena.dupe(u8, model.money.format_minor(&buffer, held.?.integer, digits))
        else
            "";

        instance.* = .{
            .name = try print(context.arena, "{s}.{s}", .{ def.name, code }),
            .label = code,
            .required = false,
            .control = "number",
            .value = amount,
            .step = try step_of(context.arena, digits),
            .prefix = if (entry.symbol.len > 0) entry.symbol else code,
        };
    }

    return instances;
}

/// The step of an amount's input: `1` for a currency without decimals, `0.01` for two.
fn step_of(arena: std.mem.Allocator, digits: u8) Error![]const u8 {
    std.debug.assert(digits <= 4);

    if (digits == 0) {
        return "1";
    }

    return print(arena, "0.{s}1", .{"0000"[0 .. digits - 1]});
}

/// A repeater's items, one box each, its fields as `name[index].child`. Past the fold an
/// item is one line, its value as JSON; after `items_closed_max` such lines the rest is one
/// run (`name[10+]`, their values a JSON list), until the repeater is asked listed. An item
/// asked open (opened, or holding a problem) is drawn open wherever it is.
fn entries_of(context: Context, def: Def, current: ?Value) Error![]const views.EntriesItem {
    std.debug.assert(model.field.is_repeater(def.kind));
    std.debug.assert(def.fields.len <= model.field.fields_max);

    const items = array_items(current);
    const count = @min(items.len, items_max);
    const listed = listed_at(context, def.name);
    var entries: std.ArrayList(views.EntriesItem) = .empty;
    var closed_count: u32 = 0;
    var index: u32 = 0;

    while (index < count) : (index += 1) {
        const item = items[index];
        const name = try print(context.arena, "{s}[{d}]", .{ def.name, index });
        const object: ?Value = if (item == .object) item else null;

        if (closed_at(context, name) and closed_count >= items_closed_max and !listed) {
            const run = try run_of(context, def, items[0..count], index);

            entries.append(context.arena, run.entry) catch return error.OutOfMemory;
            index = run.end - 1;
            continue;
        }

        const label = try entry_label(context, def, object, index);
        const entry = if (closed_at(context, name))
            try closed_entry(context, name, label, item)
        else
            try open_entry(context, def, name, label, object);

        closed_count += @intFromBool(entry.closed);
        entries.append(context.arena, entry) catch return error.OutOfMemory;
    }

    return entries.items;
}

/// Closed items drawn as a line each before the rest of a repeater's become one run.
pub const items_closed_max: u32 = 10;

const Run = struct {
    entry: views.EntriesItem,
    /// One past the run's last item.
    end: u32,
};

/// The items from `start` up to the next one asked open, as one run.
fn run_of(context: Context, def: Def, items: []const Value, start: u32) Error!Run {
    std.debug.assert(start < items.len);
    std.debug.assert(model.field.is_repeater(def.kind));

    var end = start;

    while (end < items.len) : (end += 1) {
        const name = try print(context.arena, "{s}[{d}]", .{ def.name, end });

        if (asked_open(context.open, name)) {
            break;
        }
    }

    std.debug.assert(end > start);

    const values: Value = .{
        .array = .{
            .items = @constCast(items[start..end]),
            .capacity = end - start,
            .allocator = context.arena,
        },
    };
    const more = try print(context.arena, "{d}", .{end - start});

    return .{
        .entry = .{
            .name = try print(context.arena, "{s}[{d}+]", .{ def.name, start }),
            .label = try context.session.translated(
                "{count} more items",
                .{
                    .values = &.{.{
                        .name = "count",
                        .value = more,
                    }},
                },
            ),
            .closed = true,
            .run = true,
            .value_json = try json_text(context.arena, values),
            .opened = false,
            .remove = "",
            .up = "",
            .down = "",
            .cells = &.{},
        },
        .end = end,
    };
}

fn closed_entry(
    context: Context,
    name: []const u8,
    label: []const u8,
    item: Value,
) Error!views.EntriesItem {
    std.debug.assert(name.len > 0);
    std.debug.assert(label.len > 0);

    return .{
        .name = name,
        .label = label,
        .closed = true,
        .run = false,
        .value_json = try json_text(context.arena, item),
        .opened = false,
        .remove = "",
        .up = "",
        .down = "",
        .cells = &.{},
    };
}

fn open_entry(
    context: Context,
    def: Def,
    name: []const u8,
    label: []const u8,
    object: ?Value,
) Error!views.EntriesItem {
    std.debug.assert(name.len > 0);
    std.debug.assert(model.field.is_repeater(def.kind));

    const opened = opened_at(context, name);
    const cells = try context.arena.alloc(Instance, def.fields.len);

    for (def.fields, 0..) |child, child_index| {
        const cell_name = try print(context.arena, "{s}.{s}", .{ name, child.name });
        const path = try print(context.arena, "{s}.{s}", .{ def.name, child.name });
        const value: ?Value = if (object) |present| present.object.get(child.name) else null;

        cells[child_index] = try nested_of(context, child, cell_name, path, value);
    }

    if (context.fold) |fold| {
        fold.drawn += @intCast(def.fields.len);
    }

    return .{
        .name = name,
        .label = label,
        .closed = false,
        .run = false,
        .value_json = "",
        .opened = opened,
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

/// What a list of values or references adds another with, unless the field names it.
fn many_add_label(context: Context, kind: Kind) Error![]const u8 {
    std.debug.assert(context.referenced.len <= items_max);
    std.debug.assert(kind.id.len > 0);

    if (kind.has.target) {
        return context.session.translated("Add reference", .{});
    }

    return context.session.translated("Add value", .{});
}

/// The add button's label: the field's own, else the shape's.
fn add_label_of(def: Def, fallback: []const u8) []const u8 {
    std.debug.assert(fallback.len > 0);
    std.debug.assert(def.name.len > 0);

    const own = def.options.container.add_label;

    return if (own.len > 0) own else fallback;
}

/// What names a repeater item in its header: the label field's value when the item has
/// one; else, with no label field chosen, its first short text; else its number.
fn entry_label(context: Context, def: Def, item: ?Value, index: u32) Error![]const u8 {
    std.debug.assert(model.field.is_repeater(def.kind));
    std.debug.assert(index < items_max);

    const label_field = def.options.container.label_field;
    const object = if (item != null and item.? == .object) item.?.object else null;

    if (object) |fields_of_item| {
        for (def.fields) |child| {
            const chosen = if (label_field.len > 0)
                std.mem.eql(u8, child.name, label_field)
            else
                std.mem.eql(u8, child.kind, "string");

            if (!chosen) {
                continue;
            }

            const value = fields_of_item.get(child.name) orelse continue;

            if (value == .string and value.string.len > 0) {
                return value.string;
            }

            break;
        }
    }

    const number = try print(context.arena, "{d}", .{index + 1});

    return context.session.translated(
        "Item {number}",
        .{
            .values = &.{.{
                .name = "number",
                .value = number,
            }},
        },
    );
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
    std.debug.assert(def.fields.len <= model.field.fields_max);

    // A repeater or group inside a group is a list there too: edited as JSON.
    const nested = !model.field.is_leaf(def.kind);

    if (nested or def.many or kind_of(context, def).control == .json) {
        return .{
            .name = name,
            .label = def.label,
            .required = def.validation.required,
            .help = def.help,
            .conditions = try std.json.Stringify.valueAlloc(context.arena, def.conditions, .{}),
            .value_kind = def.kind,
            .control = "json",
            .rows = json_rows,
            .value = if (current) |value| try json_text(context.arena, value) else "",
        };
    }

    const kind = kind_of(context, def);
    var instance = try instance_of(context, def, kind, name, path, current, false);

    if (kind.has.media) {
        const families = def.validation.media.types;

        instance.control = "media";
        instance.files = try media.placed(context.arena, context.files, def, name, current);
        instance.types = try media.types_of(context.arena, families);
        instance.accept = try media.accept_of(context.arena, families);
        instance.can_upload = def.options.media.create;
    }

    return instance;
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
        .required = def.validation.required,
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

    if (kind.editor != null) {
        if (try editor_src(context.arena, kind.id, def, current)) |src| {
            instance.control = "editor";
            instance.src = src;
            instance.value = if (current != null and current.? != .null)
                try json_text(context.arena, current.?)
            else
                "";

            return instance;
        }
    }

    switch (kind.control) {
        .textarea => {
            const markdown = def.options.text.format == .markdown;

            instance.control = if (markdown) "markdown" else "textarea";
            instance.rows = if (def.options.rows) |rows| rows else text_rows;
            instance.value = try text_of(context.arena, current);
        },
        .rich => {
            instance.control = "rich";
            instance.rows = if (def.options.rows) |rows| rows else text_rows;
            instance.value = try text_of(context.arena, current);
            instance.formats = try formats_text(context.arena, def.options.richtext);
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
                try named_empty(context, def, instance.control, try choice_options(
                    context.arena,
                    def,
                    current,
                ));
        },
        .number => try fill_number(context, &instance, def, kind, current),
        .datetime => {
            const day_only = def.options.date.format == .date;

            instance.control = if (day_only) "date" else "datetime";
            instance.value = try datetime_text(context.arena, current, day_only);
            // Moments are kept and shown in UTC; the editor says so beside the time.
            instance.suffix = if (day_only) "" else "UTC";
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

/// The longest value an editor's frame is told in its address; a longer one is edited as JSON.
const editor_value_max: u32 = 4 << 10;

/// A plugin kind's editor frame, told the value the form holds and the field's options:
/// `/admin/plugin/places/kinds/location/frame?value=…`; null for a value too long to tell.
fn editor_src(
    arena: std.mem.Allocator,
    id: []const u8,
    def: Def,
    current: ?Value,
) Error!?[]const u8 {
    const dot = std.mem.indexOfScalar(u8, id, '.') orelse return null;
    const held = current != null and current.? != .null;
    const value = if (held) try json_text(arena, current.?) else "";

    std.debug.assert(dot > 0);

    if (value.len > editor_value_max) {
        return null;
    }

    return try print(arena, "/admin/plugin/{s}/kinds/{s}/frame?value={s}&placeholder={s}", .{
        id[0..dot],
        id[dot + 1 ..],
        try admin.query_value(arena, value),
        try admin.query_value(arena, def.options.placeholder),
    });
}

/// A switch, a checkbox, or two radios, each with the labels the field gives its states.
fn fill_boolean(context: Context, instance: *Instance, def: Def, current: ?Value) Error!void {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(context.referenced.len <= items_max);

    const flags = def.options.boolean;
    const on = current != null and current.? == .bool and current.?.bool;
    const yes = if (flags.true_label.len > 0)
        flags.true_label
    else
        try context.session.translated("Yes", .{});
    const no = if (flags.false_label.len > 0)
        flags.false_label
    else
        try context.session.translated("No", .{});

    instance.checked = on;

    switch (flags.control) {
        .toggle => {
            instance.control = "switch";
            instance.label_on = yes;
        },
        .checkbox => {
            instance.control = "checkbox";
            instance.label_on = flags.true_label;
        },
        .radio => {
            const options = try context.arena.alloc(Option, 2);

            options[0] = .{
                .value = "1",
                .label = yes,
                .selected = on,
            };
            options[1] = .{
                .value = "0",
                .label = no,
                .selected = current != null and !on,
            };
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
    instance.min = try number_text(arena, def.validation.min);
    instance.max = try number_text(arena, def.validation.max);
    instance.step = try step_text(arena, def);
    instance.prefix = if (shape.unit_after) "" else shape.unit;
    instance.suffix = if (shape.unit_after) shape.unit else "";

    if (def.options.choices.len > 0) {
        instance.control = "select";
        instance.options = try choice_options(arena, def, current);
        instance.prefix = "";
        instance.suffix = "";
    } else if (shape.control == .slider and def.validation.max != null) {
        instance.control = "range";
    } else if (shape.control == .rating) {
        instance.control = "rating";
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

/// One star per step from one to the maximum (five when the field has none), highest first.
fn rating_options(arena: std.mem.Allocator, def: Def, current: ?Value) Error![]const Option {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(rating_max > 0);

    const wanted: f64 = def.validation.max orelse 5;
    const stars: u32 = @intFromFloat(@min(@max(wanted, 1), rating_max));
    const chosen: ?i64 = if (current) |value| switch (value) {
        .integer => |whole| whole,
        .float => |real| @intFromFloat(@round(real)),
        else => null,
    } else null;
    const options = try arena.alloc(Option, stars);

    // Highest first: the control lays them out from one up, and a chosen star lights the
    // ones after it in the markup, which are the lower ones.
    for (options, 0..) |*option, index| {
        const star = stars - index;
        const text = try print(arena, "{d}", .{star});

        const picked = chosen != null and chosen.? == star;

        option.* = .{
            .value = text,
            .label = text,
            .selected = picked,
        };
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

/// The input a list of plain values is edited with in the browser, without a round trip:
/// null for the kinds whose control needs the server (a reference, rich text, a picker).
fn list_type_of(def: Def, kind: Kind) ?[]const u8 {
    std.debug.assert(def.many);
    std.debug.assert(def.kind.len > 0);

    if (kind.has.target or kind.has.taxonomy or kind.has.media) {
        return null;
    }

    return switch (kind.control) {
        .number => "number",
        .textarea => "textarea",
        .datetime => if (def.options.date.format == .date) "date" else "datetime-local",
        .input => input_type_of(def.kind),
        else => null,
    };
}

fn input_type_of(kind_id: []const u8) ?[]const u8 {
    std.debug.assert(kind_id.len > 0);

    const plain = [_][2][]const u8{
        .{ "string", "text" },
        .{ "email", "email" },
        .{ "url", "url" },
        .{ "embed", "url" },
        .{ "time", "time" },
    };

    for (plain) |pair| {
        if (std.mem.eql(u8, pair[0], kind_id)) {
            return pair[1];
        }
    }

    return null;
}

/// A plain list's values as the island starts from: each with the form name it posts under.
fn list_values_of(
    context: Context,
    def: Def,
    kind: Kind,
    current: ?Value,
) Error![]const views.ChoicesItem {
    std.debug.assert(def.many);
    std.debug.assert(list_type_of(def, kind) != null);

    const items = try items_of(context, def, kind, current);
    const values = try context.arena.alloc(views.ChoicesItem, items.len);

    for (items, values) |item, *value| {
        // The label is the value's key in the browser: it stays with the value as it moves.
        value.* = .{
            .name = item.name,
            .value = item.value,
            .label = item.name,
            .selected = false,
        };
    }

    return values;
}

/// The chosen values, space separated, as a multi-select starts from.
fn chosen_tokens(arena: std.mem.Allocator, choices: []const views.ChoicesItem) Error![]const u8 {
    std.debug.assert(choices.len <= model.field.choices_max);
    std.debug.assert(choices.len == 0 or choices[0].value.len > 0);

    var out: std.ArrayList(u8) = .empty;

    for (choices) |choice| {
        if (!choice.selected) {
            continue;
        }

        if (out.items.len > 0) {
            out.append(arena, ' ') catch return error.OutOfMemory;
        }

        out.appendSlice(arena, choice.value) catch return error.OutOfMemory;
    }

    return out.items;
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

    options[0] = .{
        .value = "",
        .label = "",
        .selected = chosen == null,
    };

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
        .label = try context.session.translated("Select a user", .{}),
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
        .label = try context.session.translated("Previously selected user", .{}),
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
        std.mem.eql(u8, def.kind, "password") or std.mem.eql(u8, def.kind, "embed");

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
        instance.prefix = slug_prefix_in(context, def.name);
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
    const status = if (found) |seen|
        statuses.find_in(context.statuses, seen.record.status)
    else
        null;

    const notice = if (found) |seen| seen.notice else "";
    const linked = if (found) |seen| seen.link else true;

    instance.control = "card";
    instance.card_type = if (found) |seen| seen.type_name else "";
    instance.card_title = if (found) |seen| title_of(seen.record) else instance.value;
    instance.card_status = if (status) |known| known.label else "";
    instance.card_tone = if (status) |known| tone_of(known.color) else "neutral";
    instance.card_href = if (linked)
        try print(context.arena, "/admin/content/{s}", .{instance.value})
    else
        "";

    if (found) |seen| {
        if (seen.record.changed) {
            instance.card_status = try print(context.arena, "{s} · changed", .{
                instance.card_status,
            });
            instance.card_tone = "accent";
        }
    }

    if (notice.len > 0) {
        instance.card_status = notice;
        instance.card_tone = "warning";
    }

    if (instance.card_title.len == 0) {
        instance.card_title = instance.card_type;
    }

    instance.id = instance.name;
    instance.title = instance.card_title;
    instance.type_label = instance.card_type;
    instance.status = instance.card_status;
    instance.tone = instance.card_tone;
    instance.href = instance.card_href;

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
        items[index] = .{
            .handle = option.handle,
            .name = option.name,
        };
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

fn kind_of(context: Context, def: Def) Kind {
    std.debug.assert(def.name.len > 0);

    return model.kinds.lookup(registry.kinds(&context.session.ctx), def.kind);
}

/// Groups, repeaters and lists have shapes of their own; a kind without a control or an
/// editor of its own, and a list of booleans (a checkbox cannot say it is absent), are
/// edited as JSON.
pub fn is_json_edited(kind: Kind, def: Def) bool {
    std.debug.assert(def.name.len > 0);
    std.debug.assert(std.mem.eql(u8, kind.id, def.kind) or kind.id.len == 0);

    return (kind.control == .json and kind.editor == null) or (def.many and kind.storage == .bool);
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

    options[0] = .{
        .value = "",
        .label = "",
        .selected = chosen == null,
    };

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

/// The empty choice as the control shows it: a placeholder in a dropdown, "None" among
/// radios and buttons, and no empty choice at all when the field must have a value.
fn named_empty(
    context: Context,
    def: Def,
    control: []const u8,
    options: []const Option,
) Error![]const Option {
    std.debug.assert(options.len > 0);
    std.debug.assert(options[0].value.len == 0);

    const listed = !std.mem.eql(u8, control, "select");

    if (listed and def.validation.required) {
        return options[1..];
    }

    const writable = @constCast(options);

    writable[0].label = if (listed)
        try context.session.translated("None", .{})
    else
        try context.session.translated("Choose…", .{});

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
                const Target = @FieldType(Item, info.name);

                @field(items[index], info.name) = if (comptime Target == info.type)
                    @field(instance, info.name)
                else
                    try copied(Target, arena, @field(instance, info.name));
            }
        }

        @field(items[index], options_field) = options;
    }

    return items;
}

/// A list of one view's items as another view's: each field by name, an enum by its tag.
fn copied(comptime Target: type, arena: std.mem.Allocator, source: anytype) Error!Target {
    const Element = @typeInfo(Target).pointer.child;
    const out = try arena.alloc(Element, source.len);

    std.debug.assert(source.len <= items_max);

    for (source, out) |item, *entry| {
        inline for (std.meta.fields(Element)) |info| {
            const value = @field(item, info.name);

            @field(entry, info.name) = if (comptime @typeInfo(info.type) == .@"enum")
                std.meta.stringToEnum(info.type, @tagName(value)).?
            else
                value;
        }
    }

    return out;
}

fn json_text(arena: std.mem.Allocator, value: Value) Error![]const u8 {
    std.debug.assert(json_bytes_max > 0);
    std.debug.assert(value != .null);

    return std.json.Stringify.valueAlloc(arena, value, .{}) catch error.OutOfMemory;
}

/// `bold,italic,link`: what the field allows, every format when it names none.
fn formats_text(arena: std.mem.Allocator, rich: model.field.options.RichText) Error![]const u8 {
    const all = std.enums.values(model.field.options.RichFormat);
    const formats = rich.formats orelse all;
    var text: std.ArrayList(u8) = .empty;

    std.debug.assert(formats.len <= model.field.options.list_max);

    for (formats, 0..) |format, index| {
        if (index > 0) {
            try text.append(arena, ',');
        }

        try text.appendSlice(arena, @tagName(format));
    }

    std.debug.assert(text.items.len <= formats.len * "italic,".len);

    return text.items;
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

/// The address before a slug: its language's, for a translated one (`slug@pl`).
fn slug_prefix_in(context: Context, name: []const u8) []const u8 {
    std.debug.assert(name.len > 0);
    std.debug.assert(context.slug_prefixes.len <= 64);

    const code = model.variant.split(name).code;

    for (context.slug_prefixes) |entry| {
        if (code.len > 0 and std.mem.eql(u8, entry.code, code)) {
            return entry.prefix;
        }
    }

    return context.slug_prefix;
}
