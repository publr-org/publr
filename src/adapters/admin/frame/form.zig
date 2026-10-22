//! A plugin's page by declaration: the admin draws the form itself, the fields of the
//! plugin's save operation filled from its read. No markup of the plugin's reaches the
//! page, so it is an admin page like any other, the same for an installed plugin.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const pages = @import("pages.zig");
const model = @import("../../../model/sandboxed_plugin.zig");
const manifest_module = @import("../../../sdk/plugin/manifest.zig");
const contract = @import("../../../model/contract.zig");

const Session = admin.Session;
const Error = admin.Error;
const PageField = admin.views.PluginFormPage.FieldsItem;

pub fn show(session: *Session, page: pages.Page) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(page.declared());

    const all = try pages.all(session);

    if (pages.parent_of(all, page)) |parent| {
        return show_tab(session, all, page, parent);
    }

    const fields = try fields_of(session, page, PageField) orelse return;
    const options: admin.chrome.Options = .{
        .settings_path = session.request.path(),
    };

    try admin.screen(session, .ok, admin.views.PluginFormPage, .{
        .title = page.label,
        .operation = page.save,
        .fields = fields,
        .preview = page.preview,
    }, options);
}

/// A tab of a tabbed page: that page's title and tab bar over the form, its entry lit in
/// the menu.
fn show_tab(
    session: *Session,
    all: []const pages.Page,
    page: pages.Page,
    parent: []const u8,
) Error!void {
    std.debug.assert(parent.len > 0);

    const fields = try fields_of(session, page, PageField) orelse return;
    const header = try pages.header_of(Tab, session, all, page, parent);

    try admin.screen(session, .ok, admin.views.PluginFormPage, .{
        .title = try session.declared(page.label),
        .operation = page.save,
        .fields = fields,
        .preview = page.preview,
        .parent = header.title,
        .description = header.description,
        .tabs = header.tabs,
        .action_label = page.action_label,
        .action_href = page.action_href,
    }, .{
        .settings_path = header.address,
    });
}

const Tab = admin.views.PluginFormPage.TabsItem;

/// The form's fields as the view `Item` takes them, filled from what its read answers; null
/// once a failure is shown.
pub fn fields_of(session: *Session, page: pages.Page, comptime Item: type) Error!?[]const Item {
    std.debug.assert(page.declared());

    const described = try described_of(session, page);
    const values = try answered(session, page.read) orelse return null;
    const suggested: std.json.Value = if (page.suggest.len == 0)
        .null
    else
        try answered(session, page.suggest) orelse return null;

    return try items_of(Item, session.arena, described, values, suggested, .{
        .multiline = page.multiline,
        .only_one = page.only_one,
    });
}

/// What the read `operation` answers, parsed; null once a failure is shown.
fn answered(session: *Session, operation: []const u8) Error!?std.json.Value {
    std.debug.assert(operation.len > 0);

    const read = registry.SDK.call_json(&session.ctx, operation, "{}") catch |err| {
        try admin.fail(session, err, "/admin/settings");
        return null;
    };

    return std.json.parseFromSliceLeaky(std.json.Value, session.arena, read, .{}) catch {
        try admin.fail(session, error.Invalid, "/admin/settings");
        return null;
    };
}

/// The save operation's input, and the shape the read answers in.
const Described = struct {
    fields: []const model.Field,
    output: []const contract.Node = &.{},
};

/// The form as its plugin describes it: from the build for a compiled-in plugin, from the
/// manifest for an installed one.
fn described_of(session: *const Session, page: pages.Page) Error!Described {
    std.debug.assert(page.save.len > 0);

    inline for (registry.pages) |owned| {
        if (owned.page.form) |declared| {
            const same = std.mem.eql(u8, owned.plugin, page.plugin) and
                std.mem.eql(u8, owned.page.path, page.path);

            if (same) {
                return .{
                    .fields = comptime manifest_module.fields_of(declared.save, owned.docs),
                    .output = comptime contract.describe(declared.read.Out),
                };
            }
        }
    }

    const sandboxed = session.ctx.sandboxed_plugins orelse return .{
        .fields = &.{},
    };
    var described: Described = .{
        .fields = &.{},
    };

    for (sandboxed.manifests()) |manifest| {
        if (!std.mem.eql(u8, manifest.name, page.plugin)) {
            continue;
        }

        for (manifest.operations) |operation| {
            if (std.mem.eql(u8, operation.name, page.save)) {
                described.fields = operation.fields;
            }

            if (std.mem.eql(u8, operation.name, page.read)) {
                described.output = operation.output;
            }
        }
    }

    return described;
}

/// How the page draws some fields: by name, those of several lines, and a list's boolean
/// columns true in one row only.
const Drawn = struct {
    multiline: []const []const u8 = &.{},
    only_one: []const []const u8 = &.{},
};

fn items_of(
    comptime Item: type,
    arena: std.mem.Allocator,
    described: Described,
    values: std.json.Value,
    suggested: std.json.Value,
    drawn: Drawn,
) Error![]const Item {
    std.debug.assert(described.fields.len <= 256);

    var items: std.ArrayList(Item) = .empty;

    for (described.fields) |field| {
        const kind = kind_of(field, drawn.multiline) orelse continue;
        const rows = std.mem.eql(u8, kind, "rows");
        const columns: []const model.Field = if (rows)
            try columns_of(arena, field, described.output)
        else
            &.{};

        try items.append(arena, .{
            .name = field.name,
            .label = try label_of(arena, field.name),
            .kind = kind,
            .required = field.required,
            .help = field.doc,
            .value = if (rows) "" else try text_of(arena, field.name, values),
            .choices = try choices_of(Each(Item, "choices"), arena, field),
            .columns = try view_columns_of(Item, arena, field, columns, drawn.only_one),
            .rows = try rows_of(Item, arena, field.name, columns, values, drawn.only_one),
            .suggestions = try suggestions_of(Item, arena, field.name, columns, suggested),
        });
    }

    return items.items;
}

/// How a field is drawn; null for one a form does not draw (a list of text, an object).
fn kind_of(field: model.Field, multiline: []const []const u8) ?[]const u8 {
    std.debug.assert(field.name.len > 0);

    return switch (field.shape) {
        .boolean => "boolean",
        .integer, .number => "number",
        .string => if (field.values.len > 0) "choice" else for (multiline) |name| {
            if (std.mem.eql(u8, name, field.name)) {
                break "text";
            }
        } else "string",
        .json => if (field.fields.len > 0) "rows" else null,
        .strings => null,
    };
}

fn Each(comptime Item: type, comptime field: []const u8) type {
    return @typeInfo(@FieldType(Item, field)).pointer.child;
}

/// A list's columns: each field of its items `save` takes, then each the read answers that
/// `save` does not take (`example`), shown as written: these have no shape of their own.
fn columns_of(
    arena: std.mem.Allocator,
    field: model.Field,
    output: []const contract.Node,
) Error![]const model.Field {
    std.debug.assert(field.fields.len > 0);
    std.debug.assert(output.len <= contract.nodes_max);

    var columns: std.ArrayList(model.Field) = .empty;

    try columns.appendSlice(arena, field.fields);

    const list = child_of(output, 0, field.name) orelse return columns.items;
    const item = child_of(output, list, "[]") orelse return columns.items;

    for (output, 0..) |node, index| {
        if (node.parent != item or index == 0) {
            continue;
        }

        const taken = for (field.fields) |own| {
            if (std.mem.eql(u8, own.name, node.name)) {
                break true;
            }
        } else false;
        const plain = node.kind == .string or node.kind == .integer or node.kind == .number;

        if (!taken and plain) {
            try columns.append(arena, .{
                .name = node.name,
                .shape = .json,
                .required = false,
            });
        }
    }

    return columns.items;
}

/// The node named `name` inside the node at `parent`.
fn child_of(nodes: []const contract.Node, parent: i32, name: []const u8) ?i32 {
    std.debug.assert(name.len > 0);
    std.debug.assert(nodes.len <= contract.nodes_max);

    for (nodes, 0..) |node, index| {
        if (node.parent == parent and index > 0 and std.mem.eql(u8, node.name, name)) {
            return @intCast(index);
        }
    }

    return null;
}

/// A column the read answers and `save` does not take: shown, never sent.
fn shown(column: model.Field) bool {
    return column.shape == .json;
}

/// `one`: a boolean column true in one row only, a choice between the rows.
fn cell_kind(column: model.Field, only_one: []const []const u8) []const u8 {
    std.debug.assert(column.name.len > 0);

    if (column.shape == .boolean) {
        for (only_one) |name| {
            if (std.mem.eql(u8, name, column.name)) {
                return "one";
            }
        }
    }

    return if (shown(column)) "shown" else kind_of(column, &.{}) orelse "string";
}

/// An enumeration's values, each in its own words (`1,000`), else its name as people
/// read it.
fn choices_of(comptime Choice: type, arena: std.mem.Allocator, field: model.Field) Error![]const Choice {
    std.debug.assert(field.values.len <= contract.values_max);
    std.debug.assert(field.words.len == 0 or field.words.len == field.values.len);

    const choices = try arena.alloc(Choice, field.values.len);

    for (field.values, choices, 0..) |value, *choice, at| {
        const words = if (at < field.words.len) field.words[at] else "";

        choice.* = .{
            .value = value,
            .label = if (words.len > 0) words else try label_of(arena, value),
        };
    }

    return choices;
}

fn view_columns_of(
    comptime Item: type,
    arena: std.mem.Allocator,
    field: model.Field,
    columns: []const model.Field,
    only_one: []const []const u8,
) Error![]const Each(Item, "columns") {
    std.debug.assert(columns.len <= 64);
    std.debug.assert(field.name.len > 0);

    const Column = Each(Item, "columns");
    const listed = try arena.alloc(Column, columns.len);

    for (columns, listed) |column, *drawn| {
        drawn.* = .{
            .name = column.name,
            .label = try label_of(arena, column.name),
            .kind = cell_kind(column, only_one),
            .choices = try choices_of(Each(Column, "choices"), arena, column),
        };
    }

    return listed;
}

/// Each item the read answered for the list `name`, a cell per column.
fn rows_of(
    comptime Item: type,
    arena: std.mem.Allocator,
    name: []const u8,
    columns: []const model.Field,
    values: std.json.Value,
    only_one: []const []const u8,
) Error![]const Each(Item, "rows") {
    std.debug.assert(name.len > 0);

    const Row = Each(Item, "rows");
    const Cell = Each(Row, "cells");
    const present = list_in(values, name);
    const rows = try arena.alloc(Row, present.len);

    for (present, rows) |item, *row| {
        const cells = try arena.alloc(Cell, columns.len);

        for (columns, cells) |column, *cell| {
            cell.* = .{
                .kind = cell_kind(column, only_one),
                .label = try label_of(arena, column.name),
                .value = try text_of(arena, column.name, item),
                .choices = try choices_of(Each(Cell, "choices"), arena, column),
            };
        }

        row.* = .{
            .cells = cells,
        };
    }

    return rows;
}

/// The items the suggest read offers for the list `name`, each named by its `label` (else
/// its first column) and its values by column.
fn suggestions_of(
    comptime Item: type,
    arena: std.mem.Allocator,
    name: []const u8,
    columns: []const model.Field,
    suggested: std.json.Value,
) Error![]const Each(Item, "suggestions") {
    std.debug.assert(name.len > 0);

    const Suggestion = Each(Item, "suggestions");
    const offered = list_in(suggested, name);
    const suggestions = try arena.alloc(Suggestion, offered.len);

    for (offered, suggestions) |item, *suggestion| {
        const texts = try arena.alloc([]const u8, columns.len);

        for (columns, texts) |column, *text| {
            text.* = try text_of(arena, column.name, item);
        }

        const label = try text_of(arena, "label", item);

        suggestion.* = .{
            .label = if (label.len > 0 or texts.len == 0) label else texts[0],
            .values = texts,
        };
    }

    return suggestions;
}

/// The list `name` in what a read answered; none when it answered no list.
fn list_in(values: std.json.Value, name: []const u8) []const std.json.Value {
    std.debug.assert(name.len > 0);

    if (values != .object) {
        return &.{};
    }

    const present = values.object.get(name) orelse return &.{};

    return if (present == .array) present.array.items else &.{};
}

/// `site_title` as `Site title`.
fn label_of(arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
    std.debug.assert(name.len > 0);

    const label = try arena.dupe(u8, name);

    std.mem.replaceScalar(u8, label, '_', ' ');
    label[0] = std.ascii.toUpper(label[0]);

    return label;
}

/// What the read answered for `name`, as the form shows it; empty when it answered none.
fn text_of(arena: std.mem.Allocator, name: []const u8, values: std.json.Value) Error![]const u8 {
    std.debug.assert(name.len > 0);

    if (values != .object) {
        return "";
    }

    const present = values.object.get(name) orelse return "";

    return switch (present) {
        .string => |text| text,
        .bool => |flag| if (flag) "true" else "false",
        .integer => |number| try std.fmt.allocPrint(arena, "{d}", .{number}),
        .float => |number| try std.fmt.allocPrint(arena, "{d}", .{number}),
        else => "",
    };
}

test "a declared form's fields: kinds, labels and values from what the read answers" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const described = [_]model.Field{
        .{
            .name = "site_title",
            .shape = .string,
            .required = true,
        },
        .{
            .name = "description",
            .shape = .string,
            .required = false,
            .doc = "Under the title",
        },
        .{
            .name = "visits",
            .shape = .integer,
            .required = false,
        },
        .{
            .name = "tags",
            .shape = .strings,
            .required = false,
        },
    };
    const values = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"site_title":"Acme","description":"Anvils","visits":3}
    , .{});
    const items = try items_of(PageField, arena, .{
        .fields = &described,
    }, values, .null, .{
        .multiline = &.{"description"},
    });

    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("Site title", items[0].label);
    try std.testing.expectEqualStrings("text", items[1].kind);
    try std.testing.expectEqualStrings("Under the title", items[1].help);
    try std.testing.expectEqualStrings("3", items[2].value);
}

test "a list of plain items is drawn as rows, a cell per item field" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const described = [_]model.Field{.{
        .name = "languages",
        .shape = .json,
        .required = true,
        .fields = &.{
            .{
                .name = "code",
                .shape = .string,
                .required = true,
            },
            .{
                .name = "main",
                .shape = .boolean,
                .required = false,
            },
        },
    }};
    const values = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"languages":[{"code":"en","main":true},{"code":"pl"}]}
    , .{});
    const items = try items_of(PageField, arena, .{
        .fields = &described,
    }, values, .null, .{});
    const one = try items_of(PageField, arena, .{
        .fields = &described,
    }, values, .null, .{
        .only_one = &.{"main"},
    });

    try std.testing.expectEqualStrings("rows", items[0].kind);
    try std.testing.expectEqual(@as(usize, 2), items[0].columns.len);
    try std.testing.expectEqualStrings("boolean", items[0].columns[1].kind);
    try std.testing.expectEqualStrings("one", one[0].columns[1].kind);
    try std.testing.expectEqualStrings("one", one[0].rows[1].cells[1].kind);
    try std.testing.expectEqual(@as(usize, 2), items[0].rows.len);
    try std.testing.expectEqualStrings("true", items[0].rows[0].cells[1].value);
    try std.testing.expectEqualStrings("pl", items[0].rows[1].cells[0].value);
    try std.testing.expectEqualStrings("", items[0].rows[1].cells[1].value);
}

test "a list's columns: a choice per enumeration, the read's own fields shown, items offered" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Answered = struct {
        currencies: []const struct {
            code: []const u8,
            decimal: enum { period, comma },
            example: []const u8,
        },
    };
    const described = [_]model.Field{.{
        .name = "currencies",
        .shape = .json,
        .required = true,
        .fields = &.{
            .{
                .name = "code",
                .shape = .string,
                .required = true,
            },
            .{
                .name = "decimal",
                .shape = .string,
                .required = false,
                .values = &.{ "period", "comma" },
                .words = &.{ "1.50", "" },
            },
        },
    }};
    const values = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"currencies":[{"code":"GBP","decimal":"period","example":"£1,234.56"}]}
    , .{});
    const suggested = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"currencies":[{"code":"PLN","decimal":"comma"}]}
    , .{});
    const items = try items_of(PageField, arena, .{
        .fields = &described,
        .output = comptime contract.describe(Answered),
    }, values, suggested, .{});
    const columns = items[0].columns;

    try std.testing.expectEqual(@as(usize, 3), columns.len);
    try std.testing.expectEqualStrings("choice", columns[1].kind);
    try std.testing.expectEqualStrings("1.50", columns[1].choices[0].label);
    try std.testing.expectEqualStrings("Comma", columns[1].choices[1].label);
    try std.testing.expectEqualStrings("shown", columns[2].kind);
    try std.testing.expectEqualStrings("£1,234.56", items[0].rows[0].cells[2].value);
    try std.testing.expectEqualStrings("PLN", items[0].suggestions[0].label);
    try std.testing.expectEqualStrings("comma", items[0].suggestions[0].values[1]);
}
