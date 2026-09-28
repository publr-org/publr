//! The two columns of a content type's page: its fields as rows (FieldList) and how a
//! record of it looks in the editor (RecordEditor drawn as a preview, every default
//! filled in). A field form asks for the preview of the definition as typed by posting
//! itself with `Publr-Fragment: preview`, and gets the editor fragment instead of a save.
const std = @import("std");
const spaces = @import("../schema_space.zig");
const admin = @import("../../admin.zig");
const model = @import("../../../model.zig");
const type_pages = @import("../types.zig");
const field_pages = @import("../type_fields.zig");
const record_form = @import("../content/form.zig");

const Error = admin.Error;
const Session = admin.Session;
const views = admin.views;
const Def = model.content_type.Def;
const FieldDef = model.field.Def;
const Row = views.FieldList.RowsItem;
const print = type_pages.print;
const text_of = field_pages.text_of;

/// What the preview calls a field the form has not named yet.
pub const untitled_label = "Untitled field";
pub const untitled_name = "untitled";

/// Whether the post asks for the preview of what it carries instead of a save.
pub fn wants_preview(session: *const Session) bool {
    std.debug.assert(session.signed_in());
    std.debug.assert(session.request.method() == .post);

    const wanted = session.request.header("publr-fragment") orelse return false;

    return std.mem.eql(u8, wanted, "preview");
}

/// The fields column.
pub fn list_node(session: *Session, handle: []const u8, def: Def) Error!admin.render.Node {
    std.debug.assert(handle.len > 0);
    std.debug.assert(session.signed_in());

    const arena = session.arena;
    const shell = admin.shell_of(session);
    const kind_label = if (spaces.of(session) == .custom)
        "Custom fields"
    else
        type_pages.kind_text(def.kind).label;
    const hub = try spaces.hub(session, handle);
    const content_href: ?[]const u8 = if (spaces.of(session) == .taxonomies)
        try print(arena, "/admin/taxonomies/{s}", .{handle})
    else if (def.kind == .component)
        null
    else if (def.kind == .settings)
        try print(arena, "/admin/settings/{s}", .{handle})
    else
        try print(arena, "/admin/content?type={s}", .{handle});

    return admin.render.view(arena, views.FieldList, .{
        .csrf = shell.csrf,
        .title = if (spaces.of(session) == .custom) "Fields" else def.name,
        .description = if (spaces.of(session) == .custom) "" else try print(
            arena,
            "{s} · {s}",
            .{
                handle,
                kind_label,
            },
        ),
        .group_href = "",
        .standalone = spaces.of(session) == .custom,
        .add_href = try print(arena, "{s}/fields/new", .{hub}),
        .settings_href = if (spaces.of(session) == .custom) null else try print(
            arena,
            "{s}/settings",
            .{
                hub,
            },
        ),
        .content_href = content_href,
        .rows = try rows_of(arena, hub, def),
    });
}

/// The preview column: the record editor for `def`, inert.
pub fn preview_node(session: *Session, def: Def) Error!admin.render.Node {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(session.signed_in());

    return record_form.preview_node(session, def);
}

/// The preview alone, as the answer to a field form's post.
pub fn answer_preview(session: *Session, def: Def) Error!void {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(wants_preview(session));

    const html = try admin.render.to_html(session.arena, try preview_node(session, def));

    try session.response.set_body(.ok, "text/html; charset=utf-8", html);
}

/// A field as typed so far, made drawable: the editor needs a label and a name, which
/// the form may not have yet.
pub fn presentable(field: FieldDef) FieldDef {
    std.debug.assert(field.kind.len > 0);
    std.debug.assert(untitled_label.len > 0);

    var shown = field;

    if (shown.label.len == 0) {
        shown.label = untitled_label;
    }

    if (shown.name.len == 0) {
        shown.name = untitled_name;
    }

    return shown;
}

/// Top-level fields in order, each group or repeater followed by its children.
fn rows_of(arena: std.mem.Allocator, handle: []const u8, def: Def) Error![]const Row {
    std.debug.assert(handle.len > 0);
    std.debug.assert(def.fields.len <= model.field.fields_max);

    var rows: std.ArrayList(Row) = .empty;

    for (def.fields) |field| {
        const is_title = std.mem.eql(u8, def.title_field, field.name);

        rows.append(arena, try row_of(arena, handle, field, "", is_title)) catch {
            return error.OutOfMemory;
        };

        if (model.field.is_leaf(field.kind)) {
            continue;
        }

        for (field.fields) |child| {
            const row = try row_of(arena, handle, child, field.name, false);

            rows.append(arena, row) catch return error.OutOfMemory;
        }
    }

    return rows.items;
}

pub fn row_of(
    arena: std.mem.Allocator,
    handle: []const u8,
    field: FieldDef,
    parent: []const u8,
    is_title: bool,
) Error!Row {
    std.debug.assert(handle.len > 0);
    std.debug.assert(field.name.len <= model.field.name_len_max);

    const nested = parent.len > 0;
    const path = if (nested)
        try print(arena, "{s}.{s}", .{ parent, field.name })
    else
        field.name;
    const base = try print(arena, "{s}/fields/{s}", .{ handle, path });
    const add_child_href: ?[]const u8 = if (!nested and !model.field.is_leaf(field.kind))
        try print(arena, "{s}/fields/new?parent={s}", .{ handle, field.name })
    else
        null;

    return .{
        .path = path,
        .label = field.label,
        .required = field.required,
        .icon = std.meta.stringToEnum(
            @FieldType(
                Row,
                "icon",
            ),
            text_of(field.kind).icon,
        ) orelse unreachable,
        .summary = try summary_of(arena, field, is_title),
        .nested = nested,
        .locked = field.locked,
        .edit_href = base,
        .move_action = try print(arena, "{s}/move", .{base}),
        .delete_action = try print(arena, "{s}/delete", .{base}),
        .add_child_href = add_child_href,
    };
}

/// The kind and what matters about it: `Reference (many) to address`, `Select, 3 choices`,
/// `Text, the title`.
fn summary_of(arena: std.mem.Allocator, field: FieldDef, is_title: bool) Error![]const u8 {
    std.debug.assert(field.name.len <= model.field.name_len_max);
    std.debug.assert(field.options.choices.len <= model.field.choices_max);

    const kind = text_of(field.kind);
    const label = kind.label;
    const required: []const u8 = if (is_title) ", the title" else "";
    const many: []const u8 = if (field.many) " (many)" else "";

    if (kind.has.target) {
        const targets = if (field.options.to.len == 0)
            "any type"
        else
            std.mem.join(arena, ", ", field.options.to) catch return error.OutOfMemory;

        return print(arena, "{s}{s} to {s}{s}", .{ label, many, targets, required });
    }

    if (kind.has.taxonomy) {
        const taxonomy = field.options.taxonomy;

        return print(arena, "{s}{s} of {s}{s}", .{ label, many, taxonomy, required });
    }

    if (kind.has.choices) {
        return print(arena, "{s}{s}, {d} choices{s}", .{
            label,
            many,
            field.options.choices.len,
            required,
        });
    }

    if (model.field.is_container(field.kind)) {
        return print(arena, "{s}, {d} fields{s}", .{ label, field.fields.len, required });
    }

    return print(arena, "{s}{s}{s}", .{ label, many, required });
}

test "a field the form has not named yet is drawn as untitled" {
    const blank: FieldDef = .{ .name = "", .label = "", .kind = "string" };
    const shown = presentable(blank);
    try std.testing.expectEqualStrings(untitled_label, shown.label);
    try std.testing.expectEqualStrings(untitled_name, shown.name);

    const named: FieldDef = .{ .name = "title", .label = "Title", .kind = "string" };
    try std.testing.expectEqualStrings("Title", presentable(named).label);
    try std.testing.expectEqualStrings("title", presentable(named).name);
}

test {
    std.testing.refAllDecls(@This());
}
