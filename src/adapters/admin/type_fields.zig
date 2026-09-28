//! A content type's fields in the admin: the fields page (one row per field), the kind
//! picker, and the field form. Every change is the whole definition posted back through
//! `content_type update`, so existing records follow the same rules as from the CLI.
//! A field inside a group or repeater is addressed as `parent.name`, one level deep.
const std = @import("std");
const spaces = @import("schema_space.zig");
const admin = @import("../admin.zig");
const registry = @import("../../app/registry.zig");
const model = @import("../../model.zig");
const types = @import("../../operations/content_type.zig");
const type_pages = @import("types.zig");
const place_rules = @import("type_fields/place.zig");
const rules = @import("type_fields/rules.zig");
const default_value = @import("type_fields/default_value.zig");
const look = @import("type_fields/look.zig");
pub const columns = @import("type_fields/columns.zig");
pub const levels = @import("type_fields/levels.zig");
pub const writes = @import("type_fields/write.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Form = admin.Form;
const Session = admin.Session;
const views = admin.views;
const Def = model.content_type.Def;
const FieldDef = model.field.Def;
const Kind = model.kinds.Kind;
const KindCard = views.KindPanel.KindsItem;
const Target = views.FieldPanel.TargetsItem;
const Taxonomy = views.FieldPanel.TaxonomiesItem;
const taxonomy_operations = @import("../../operations/taxonomy.zig");
const Level = levels.Level;
const print = type_pages.print;
const count_text = rules.count_text;
const room_text = rules.room_text;

pub const back = "/admin/types";

/// Where the field form leads: back (the picker for a new field, the parent's page for a
/// field inside a group or repeater, the type's page otherwise), to its own posts, to its
/// children.
const Links = struct {
    type_href: []const u8,
    back_href: []const u8,
    action: []const u8,
    add_child_href: []const u8,
    delete_action: ?[]const u8,
};

/// What the step back from a level is called: the picker for a new field's form, else the
/// level under it as the page's script names it, else the fields page.
fn back_label_of(session: *const Session, path: ?[]const u8) []const u8 {
    std.debug.assert(path == null or path.?.len > 0);
    std.debug.assert(session.signed_in());

    if (path == null) {
        return "Kinds";
    }

    const under = levels.below(session);

    return if (under.len > 0) under else "Fields";
}

/// The kind's descriptor, or the placeholder for a kind no plugin provides any more.
pub fn text_of(kind: []const u8) Kind {
    std.debug.assert(kind.len <= model.kinds.string_len_max);
    std.debug.assert(registry.Kinds.all.len > 0);

    return model.kinds.lookup(registry.Kinds.all, kind);
}

/// String-like kinds take a length range.
fn has_length(kind: []const u8) bool {
    const lengthy = text_of(kind).has.length;

    std.debug.assert(!lengthy or model.field.is_leaf(kind));
    std.debug.assert(lengthy or !std.mem.eql(u8, kind, "string"));

    return lengthy;
}

/// Any kind may hold a list of values, except a slug (unique per type), a group, and a
/// repeater (the group that already repeats).
pub fn can_be_many(kind: []const u8) bool {
    const listable = text_of(kind).many_allowed;

    std.debug.assert(!listable or model.field.is_leaf(kind));
    std.debug.assert(listable or !std.mem.eql(u8, kind, "string"));

    return listable;
}

pub fn can_search(kind: []const u8) bool {
    const searchable = text_of(kind).searchable_allowed;

    std.debug.assert(!searchable or text_of(kind).storage != .int);
    std.debug.assert(searchable or !std.mem.eql(u8, kind, "string"));

    return searchable;
}

pub fn show(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const handle = try admin.param(&session, "handle", back) orelse return;
    const got = try load(&session, handle) orelse return;

    try levels.page(&session, handle, got.definition, null);
}

/// The type, or a not-found page.
pub fn load(session: *Session, handle: []const u8) Error!?types.Get.Out {
    std.debug.assert(handle.len > 0);
    std.debug.assert(session.signed_in());

    return @import("schema_fields.zig").load(session, handle) catch |err| {
        try admin.fail(session, err, spaces.of(session).base());

        return null;
    };
}

/// `GET fields/new`: the kind picker, or the field form once `kind` is chosen.
pub fn new_field(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const handle = try admin.param(&session, "handle", back) orelse return;
    const got = try load(&session, handle) orelse return;
    const parent = admin.query_param(&session, "parent") orelse "";
    const chosen = admin.query_param(&session, "kind");

    if (chosen != null) {
        const kind = registry.Kinds.find_kind(chosen.?) orelse {
            return admin.fail(&session, error.NotFound, back);
        };
        const blank: FieldDef = .{ .name = "", .label = "", .kind = kind.id };

        return render_form(&session, handle, got.definition, blank, parent, null, &.{});
    }

    try render_picker(&session, handle, got.definition, parent);
}

fn render_picker(session: *Session, handle: []const u8, def: Def, parent: []const u8) Error!void {
    std.debug.assert(handle.len > 0);
    std.debug.assert(session.signed_in());

    const arena = session.arena;
    const type_href = try spaces.hub(session, handle);
    var cards: std.ArrayList(KindCard) = .empty;

    for (registry.Kinds.all) |text| {
        if (parent.len > 0 and model.field.is_layout(text.id)) {
            continue;
        }
        if (parent.len > 0 and !model.field.is_leaf(text.id)) {
            continue;
        }

        cards.append(arena, .{
            .href = try print(arena, "{s}/fields/new?kind={s}&parent={s}", .{
                type_href,
                text.id,
                parent,
            }),
            .icon = std.meta.stringToEnum(
                @FieldType(KindCard, "icon"),
                text.icon,
            ) orelse unreachable,
            .label = text.label,
            .description = text.description,
        }) catch return error.OutOfMemory;
    }

    const description = if (parent.len > 0)
        try print(arena, "A field inside {s}", .{parent})
    else
        try print(arena, "A field of {s}", .{def.name});
    const back_href = if (parent.len > 0)
        try print(arena, "{s}/fields/{s}", .{ type_href, parent })
    else
        type_href;
    const panel = try admin.render.view(arena, views.KindPanel, .{
        .title = "Pick a kind",
        .description = description,
        .back_href = back_href,
        .back_label = back_label_of(session, null),
        .kinds = cards.items,
    });
    const url = if (parent.len > 0)
        try print(arena, "{s}/fields/new?parent={s}", .{ type_href, parent })
    else
        try print(arena, "{s}/fields/new", .{type_href});

    try levels.answer(session, handle, def, .{
        .url = url,
        .title = "Pick a kind",
        .panel = panel,
    });
}

/// The field form, for a new field (`path` null) or an existing one; `problems` is what
/// the last post was refused for, if it was.
pub fn render_form(
    session: *Session,
    handle: []const u8,
    def: Def,
    field: FieldDef,
    parent: []const u8,
    path: ?[]const u8,
    problems: []const model.field.Problem,
) Error!void {
    std.debug.assert(handle.len > 0);
    std.debug.assert(session.signed_in());

    const arena = session.arena;
    const panel = try panel_node(session, handle, def, field, parent, path, problems);
    const hub = try spaces.hub(session, handle);
    const url = if (path) |existing|
        try print(arena, "{s}/fields/{s}", .{ hub, existing })
    else
        try print(arena, "{s}/fields/new?kind={s}&parent={s}", .{
            hub,
            field.kind,
            parent,
        });

    try levels.answer(session, handle, def, .{
        .url = url,
        .title = if (path == null) "New field" else field.label,
        .panel = panel,
    });
}

/// The field form's panel.
pub fn panel_node(
    session: *Session,
    handle: []const u8,
    def: Def,
    field: FieldDef,
    parent: []const u8,
    path: ?[]const u8,
    problems: []const model.field.Problem,
) Error!admin.render.Node {
    std.debug.assert(handle.len > 0);
    std.debug.assert(session.signed_in());

    const arena = session.arena;
    const text = text_of(field.kind);
    const links = try links_of(arena, try spaces.hub(session, handle), field, parent, path);
    const set = field.options;

    return admin.render.view(arena, views.FieldPanel, .{
        .csrf = session.csrf_token(),
        .title = if (path == null) "New field" else field.label,
        .type_href = links.type_href,
        .form_id = if (parent.len > 0) "field-2" else "field-1",
        .back_href = links.back_href,
        .back_label = back_label_of(session, path),
        .action = links.action,
        .is_new = path == null,
        .is_layout = model.field.is_layout(field.kind),
        .problems = try problem_items(arena, problems),
        .kind = field.kind,
        .kind_label = text.label,
        .parent = parent,
        .name = field.name,
        .label = field.label,
        .label_count = try room_text(arena, field.label.len, model.field.label_len_max),
        .name_count = try room_text(arena, field.name.len, model.field.name_len_max),
        .can_be_many = can_be_many(field.kind),
        .many = field.many,
        .can_search = can_search(field.kind),
        .searchable = field.searchable,
        .can_title = text.title_allowed and parent.len == 0 and spaces.of(session) != .custom,
        .is_title = path != null and std.mem.eql(u8, def.title_field, field.name),
        .has_target = text.has.target,
        .targets = try targets_of(session, set.to),
        .has_taxonomy = text.has.taxonomy,
        .taxonomies = try taxonomies_of(session, set.taxonomy),
        .has_source = text.has.source,
        .source = set.source,
        .has_choices = text.control == .select,
        .choices = try choice_lines(arena, set.choices, set.labels),
        .on_delete = @tagName(set.reference.on_delete),
        .rules = try rules.node(arena, field),
        .defaults = try default_value.node(arena, field),
        .look = try look.node(arena, field),
        .conditions = try @import("field_conditions.zig").node(
            arena,
            field,
            place_rules.siblings_of(
                def,
                parent,
            ) orelse &.{},
        ),
        .is_container = !model.field.is_leaf(field.kind),
        .add_child_href = links.add_child_href,
        .children = try children_of(arena, links.type_href, field),
        .delete_action = links.delete_action,
    });
}

fn links_of(
    arena: std.mem.Allocator,
    handle: []const u8,
    field: FieldDef,
    parent: []const u8,
    path: ?[]const u8,
) Error!Links {
    std.debug.assert(handle.len > 0);
    std.debug.assert(path == null or path.?.len > 0);

    const type_href = handle;
    const action = if (path) |existing|
        try print(arena, "{s}/fields/{s}/update", .{ handle, existing })
    else
        try print(arena, "{s}/fields/create", .{handle});
    const back_href = if (path == null)
        try print(arena, "{s}/fields/new?parent={s}", .{ handle, parent })
    else if (parent.len > 0)
        try print(arena, "{s}/fields/{s}", .{ type_href, parent })
    else
        type_href;
    const delete_action: ?[]const u8 = if (path) |existing|
        try print(arena, "{s}/fields/{s}/delete", .{ handle, existing })
    else
        null;

    return .{
        .type_href = type_href,
        .back_href = back_href,
        .action = action,
        .add_child_href = try print(arena, "{s}/fields/new?parent={s}", .{ type_href, field.name }),
        .delete_action = delete_action,
    };
}

fn problem_items(
    arena: std.mem.Allocator,
    problems: []const model.field.Problem,
) Error![]const views.FieldPanel.ProblemsItem {
    std.debug.assert(problems.len <= model.field.problems_max);
    std.debug.assert(back.len > 0);

    const items = try arena.alloc(views.FieldPanel.ProblemsItem, problems.len);

    for (problems, 0..) |problem, index| {
        items[index] = .{ .path = problem.path, .message = problem.message };
    }

    return items;
}

/// The rows of a group or repeater's own fields, for its page.
fn children_of(
    arena: std.mem.Allocator,
    handle: []const u8,
    field: FieldDef,
) Error![]const views.FieldPanel.ChildrenItem {
    std.debug.assert(handle.len > 0);
    std.debug.assert(field.fields.len <= model.field.fields_max);

    const rows = try arena.alloc(views.FieldPanel.ChildrenItem, field.fields.len);

    for (field.fields, 0..) |child, index| {
        const row = try columns.row_of(arena, handle, child, field.name, false);

        rows[index] = .{
            .path = row.path,
            .label = row.label,
            .required = row.required,
            .icon = std.meta.stringToEnum(
                @FieldType(views.FieldPanel.ChildrenItem, "icon"),
                @tagName(row.icon),
            ) orelse unreachable,
            .summary = row.summary,
            .locked = row.locked,
            .edit_href = row.edit_href,
            .move_action = row.move_action,
            .delete_action = row.delete_action,
        };
    }

    return rows;
}

/// The record types a reference may point at, the chosen ones ticked.
fn targets_of(session: *Session, chosen: []const []const u8) Error![]const Target {
    std.debug.assert(session.signed_in());
    std.debug.assert(chosen.len <= model.field.targets_max);

    const listed = registry.SDK.dispatch(&session.ctx, types.List, .{}) catch {
        return error.OutOfMemory;
    };
    var targets: std.ArrayList(Target) = .empty;

    for (listed.types) |summary| {
        if (summary.kind != .record) {
            continue;
        }

        targets.append(session.arena, .{
            .value = summary.handle,
            .label = summary.name,
            .selected = contains(chosen, summary.handle),
        }) catch return error.OutOfMemory;
    }

    return targets.items;
}

/// The taxonomies a terms field may assign from, the chosen one selected.
fn taxonomies_of(session: *Session, chosen: []const u8) Error![]const Taxonomy {
    std.debug.assert(session.signed_in());
    std.debug.assert(chosen.len <= model.field.name_len_max);

    const listed = registry.SDK.dispatch(&session.ctx, taxonomy_operations.List, .{}) catch {
        return error.OutOfMemory;
    };
    var targets: std.ArrayList(Taxonomy) = .empty;

    for (listed.taxonomies) |summary| {
        targets.append(session.arena, .{
            .value = summary.handle,
            .label = summary.name,
            .selected = std.mem.eql(u8, chosen, summary.handle),
        }) catch return error.OutOfMemory;
    }

    return targets.items;
}

fn contains(list: []const []const u8, item: []const u8) bool {
    std.debug.assert(list.len <= model.field.targets_max);
    std.debug.assert(item.len > 0);

    for (list) |candidate| {
        if (std.mem.eql(u8, candidate, item)) {
            return true;
        }
    }

    return false;
}

/// A select's choices one per line, as `value | Label` where a label differs.
fn choice_lines(
    arena: std.mem.Allocator,
    choices: []const []const u8,
    labels: []const []const u8,
) Error![]const u8 {
    std.debug.assert(choices.len <= model.field.choices_max);
    std.debug.assert(labels.len == 0 or labels.len == choices.len);

    if (labels.len != choices.len) {
        return rules.join_lines(arena, choices);
    }

    const lines = try arena.alloc([]const u8, choices.len);

    for (choices, 0..) |choice, index| {
        lines[index] = if (std.mem.eql(u8, choice, labels[index]))
            choice
        else
            try print(arena, "{s} | {s}", .{ choice, labels[index] });
    }

    return rules.join_lines(arena, lines);
}

pub fn edit(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const handle = try admin.param(&session, "handle", back) orelse return;
    const path = try admin.param(&session, "name", back) orelse return;
    const got = try load(&session, handle) orelse return;
    const place = place_rules.locate(got.definition, path) orelse {
        return admin.fail(&session, error.NotFound, back);
    };

    try render_form(&session, handle, got.definition, place.field, place.parent, path, &.{});
}

test {
    std.testing.refAllDecls(@This());
}
