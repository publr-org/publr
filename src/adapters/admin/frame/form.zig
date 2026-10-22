//! A plugin's page by declaration: the admin draws the form itself, the fields of the
//! plugin's save operation filled from its read. No markup of the plugin's reaches the
//! page, so it is an admin page like any other, the same for an installed plugin.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const pages = @import("pages.zig");
const model = @import("../../../model/sandboxed_plugin.zig");
const manifest_module = @import("../../../sdk/plugin/manifest.zig");

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
    }, options);
}

/// A tab of a tabbed page: that page's title and tab bar over the form, its entry lit in
/// the menu. System settings' own General leads its tabs.
fn show_tab(
    session: *Session,
    all: []const pages.Page,
    page: pages.Page,
    parent: []const u8,
) Error!void {
    std.debug.assert(parent.len > 0);

    const fields = try fields_of(session, page, PageField) orelse return;
    const system = std.mem.eql(u8, parent, pages.system);
    const tabs = try pages.tabs_of(session.arena, all, parent);
    var links: std.ArrayList(Tab) = .empty;
    var title: []const u8 = undefined;
    var description: []const u8 = "";
    var address: []const u8 = undefined;

    if (system) {
        const settings = @import("../settings.zig");

        title = try session.translated("System settings", .{});
        description = try session.translated(
            "How this Publr runs, and the conventions the site follows.",
            .{},
        );
        address = settings.page_path;
        try links.append(session.arena, .{
            .label = try session.translated("General", .{}),
            .href = settings.page_path,
            .active = false,
        });
    } else {
        var buffer: [128]u8 = undefined;
        const tabbed = for (all) |one| {
            if (one.tabs and std.mem.eql(u8, one.named(&buffer), parent)) {
                break one;
            }
        } else unreachable;

        title = try session.declared(tabbed.label);
        address = try tabbed.href(session.arena);
    }

    for (tabs) |tab| {
        try links.append(session.arena, .{
            .label = try session.declared(tab.label),
            .href = try tab.href(session.arena),
            .active = std.mem.eql(u8, tab.plugin, page.plugin) and
                std.mem.eql(u8, tab.path, page.path),
        });
    }

    try admin.screen(session, .ok, admin.views.PluginFormPage, .{
        .title = try session.declared(page.label),
        .operation = page.save,
        .fields = fields,
        .parent = title,
        .description = description,
        .tabs = links.items,
    }, .{
        .settings_path = address,
    });
}

const Tab = admin.views.PluginFormPage.TabsItem;

/// The form's fields as the view `Item` takes them, filled from what its read answers; null
/// once a failure is shown.
pub fn fields_of(session: *Session, page: pages.Page, comptime Item: type) Error!?[]const Item {
    std.debug.assert(page.declared());

    const described = try described_of(session, page);
    const read = registry.SDK.call_json(&session.ctx, page.read, "{}") catch |err| {
        try admin.fail(session, err, "/admin/settings");
        return null;
    };
    const values = std.json.parseFromSliceLeaky(std.json.Value, session.arena, read, .{}) catch {
        try admin.fail(session, error.Invalid, "/admin/settings");
        return null;
    };

    return try items_of(Item, session.arena, described, values, page.multiline);
}

/// The save operation's input as its plugin describes it: from the build for a compiled-in
/// plugin, from the manifest for an installed one.
fn described_of(session: *const Session, page: pages.Page) Error![]const model.Field {
    std.debug.assert(page.save.len > 0);

    inline for (registry.pages) |owned| {
        if (owned.page.form) |declared| {
            const same = std.mem.eql(u8, owned.plugin, page.plugin) and
                std.mem.eql(u8, owned.page.path, page.path);

            if (same) {
                return comptime manifest_module.fields_of(declared.save);
            }
        }
    }

    const sandboxed = session.ctx.sandboxed_plugins orelse return &.{};

    for (sandboxed.manifests()) |manifest| {
        if (!std.mem.eql(u8, manifest.name, page.plugin)) {
            continue;
        }

        for (manifest.operations) |operation| {
            if (std.mem.eql(u8, operation.name, page.save)) {
                return operation.fields;
            }
        }
    }

    return &.{};
}

fn items_of(
    comptime Item: type,
    arena: std.mem.Allocator,
    described: []const model.Field,
    values: std.json.Value,
    multiline: []const []const u8,
) Error![]const Item {
    std.debug.assert(described.len <= 256);

    var items: std.ArrayList(Item) = .empty;

    for (described) |field| {
        const kind = kind_of(field, multiline) orelse continue;
        const rows = std.mem.eql(u8, kind, "rows");

        try items.append(arena, .{
            .name = field.name,
            .label = try label_of(arena, field.name),
            .kind = kind,
            .required = field.required,
            .help = field.doc,
            .value = if (rows) "" else try text_of(arena, field, values),
            .columns = if (rows) try columns_of(Item, arena, field.fields) else &.{},
            .rows = if (rows) try rows_of(Item, arena, field, values) else &.{},
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
        .string => for (multiline) |name| {
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

fn columns_of(
    comptime Item: type,
    arena: std.mem.Allocator,
    fields: []const model.Field,
) Error![]const Each(Item, "columns") {
    std.debug.assert(fields.len <= 64);

    const Column = Each(Item, "columns");
    const columns = try arena.alloc(Column, fields.len);

    for (fields, columns) |field, *column| {
        column.* = .{
            .name = field.name,
            .label = try label_of(arena, field.name),
            .kind = kind_of(field, &.{}) orelse "string",
        };
    }

    return columns;
}

/// Each item the read answered for the list `field`, a cell per item field.
fn rows_of(
    comptime Item: type,
    arena: std.mem.Allocator,
    field: model.Field,
    values: std.json.Value,
) Error![]const Each(Item, "rows") {
    std.debug.assert(field.fields.len > 0);

    const Row = Each(Item, "rows");

    if (values != .object) {
        return &.{};
    }

    const present = values.object.get(field.name) orelse return &.{};

    if (present != .array) {
        return &.{};
    }

    const rows = try arena.alloc(Row, present.array.items.len);
    const Cell = @typeInfo(@FieldType(Row, "cells")).pointer.child;

    for (present.array.items, rows, 0..) |item, *row, index| {
        const cells = try arena.alloc(Cell, field.fields.len);

        for (field.fields, cells, 0..) |column, *cell, at| {
            cell.* = .{
                .at = @floatFromInt(at),
                .kind = kind_of(column, &.{}) orelse "string",
                .label = try label_of(arena, column.name),
                .value = try text_of(arena, column, item),
            };
        }

        row.* = .{
            .index = @floatFromInt(index),
            .cells = cells,
        };
    }

    return rows;
}

/// `site_title` as `Site title`.
fn label_of(arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
    std.debug.assert(name.len > 0);

    const label = try arena.dupe(u8, name);

    std.mem.replaceScalar(u8, label, '_', ' ');
    label[0] = std.ascii.toUpper(label[0]);

    return label;
}

/// What the read answered for `field`, as the form shows it; empty when it answered none.
fn text_of(arena: std.mem.Allocator, field: model.Field, values: std.json.Value) Error![]const u8 {
    std.debug.assert(field.name.len > 0);

    if (values != .object) {
        return "";
    }

    const present = values.object.get(field.name) orelse return "";

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
    const items = try items_of(PageField, arena, &described, values, &.{"description"});

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
    const items = try items_of(PageField, arena, &described, values, &.{});

    try std.testing.expectEqualStrings("rows", items[0].kind);
    try std.testing.expectEqual(@as(usize, 2), items[0].columns.len);
    try std.testing.expectEqualStrings("boolean", items[0].columns[1].kind);
    try std.testing.expectEqual(@as(usize, 2), items[0].rows.len);
    try std.testing.expectEqualStrings("true", items[0].rows[0].cells[1].value);
    try std.testing.expectEqualStrings("pl", items[0].rows[1].cells[0].value);
    try std.testing.expectEqualStrings("", items[0].rows[1].cells[1].value);
}
