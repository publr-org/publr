//! The record editor: `editor.zig` over the record operations, with what only a record
//! has in its aside: its terms (one section per `terms` field of the type) and, under
//! `serve --dev`, the dependency dialog. The drawer's picker of records is here too.
const std = @import("std");
const admin = @import("../../admin.zig");
const fields = @import("../fields.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const types = @import("../../../operations/content_type.zig");
const record_operations = @import("../../../operations/record.zig");
const term_operations = @import("../../../operations/term.zig");
const editor = @import("../editor.zig");
const impact_dialog = @import("impact.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;
const views = admin.views;
const Def = model.content_type.Def;
const Value = std.json.Value;
const print = fields.print;

const back = "/admin/content";

const Editor = editor.Editor(.{
    .base = back,
    .section = "content",
    .operations = record_operations,
    .key = "type",
    .row = "record",
    .definitions = types,
    .definition_key = "type",
    .crumb = crumb_of,
    .aside = aside_of,
    .versions = true,
});

pub const settings_page = Editor.settings_page;
pub const create_url = Editor.create_url;
pub const new_page = Editor.new_page;
pub const new_editor = Editor.new_editor;
pub const preview_node = Editor.preview_node;
pub const edit = Editor.edit;
pub const editor_fragment = Editor.editor;
pub const create = Editor.create;
pub const save = Editor.save;
pub const action = Editor.action;
pub const wants_fragment = Editor.wants_fragment;
pub const answer_record = Editor.answer_loaded;
pub const answer_gone = Editor.answer_gone;

fn crumb_of(arena: std.mem.Allocator, def: Def) Error![]const u8 {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(back.len > 0);

    return print(arena, "{s}?type={s}", .{ back, def.handle });
}

/// The record's aside: its app, its terms, then the dependency dialog when the server runs
/// `--dev`.
fn aside_of(
    session: *Session,
    def: Def,
    shape: editor.Shape,
    document: ?Value,
) Error!?admin.render.Node {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(session.signed_in());

    const row: ?fields.Record = if (shape.loaded) |full| full.row else null;
    const app = if (row) |found| try admin.app_scope.aside(session, found.id, found.app) else null;
    const terms_node = try terms_of(session, def, document);
    const impact = try impact_dialog.node_of(session, def, row);

    if (app == null and terms_node == null and impact == null) {
        return null;
    }

    return try admin.render.view(session.arena, views.RecordAside, .{
        .app = app,
        .terms = terms_node,
        .impact = impact,
    });
}

const TermField = views.RecordTerms.FieldsItem;
const TermNode = views.RecordTerms.NodesItem;
const tokens_bytes_max: u32 = 1 << 20;

/// One section per `terms` field: the taxonomy's terms in tree order, the selected ones
/// marked, and the tokens the script keeps the tree's selection in.
fn terms_of(session: *Session, def: Def, document: ?Value) Error!?admin.render.Node {
    std.debug.assert(def.fields.len <= model.field.fields_max);
    std.debug.assert(session.signed_in());

    var buffer: [model.field.fields_max]model.field.Def = undefined;
    var count: u32 = 0;

    for (def.fields) |field| {
        if (field.locked and std.mem.eql(u8, field.kind, "terms")) {
            buffer[count] = field;
            count += 1;
        }
    }

    const assigned = buffer[0..count];

    if (assigned.len == 0) {
        return null;
    }

    const arena = session.arena;
    var items: std.ArrayList(TermField) = .empty;
    var selected_tokens: std.Io.Writer.Allocating = .init(arena);
    var tree_tokens: std.Io.Writer.Allocating = .init(arena);

    for (assigned) |field| {
        const tokens: Tokens = .{ .selected = &selected_tokens, .tree = &tree_tokens };
        const item = try term_field_of(session, field, document, tokens) orelse continue;

        items.append(arena, item) catch return error.OutOfMemory;
    }

    std.debug.assert(selected_tokens.written().len <= tokens_bytes_max);

    return try admin.render.view(arena, views.RecordTerms, .{
        .fields = items.items,
        .selected_tokens = std.mem.trimEnd(u8, selected_tokens.written(), " "),
        .tree_tokens = std.mem.trimEnd(u8, tree_tokens.written(), " "),
    });
}

const types_taxonomy = @import("../../../operations/taxonomy.zig");
const display = @import("../display.zig");

/// Where the script's tokens of every field are gathered.
const Tokens = struct { selected: *std.Io.Writer.Allocating, tree: *std.Io.Writer.Allocating };

/// One field's section: its taxonomy's terms in tree order, the selected ones marked;
/// null when the taxonomy cannot be read.
fn term_field_of(
    session: *Session,
    field: model.field.Def,
    document: ?Value,
    tokens: Tokens,
) Error!?TermField {
    std.debug.assert(field.options.taxonomy.len > 0);
    std.debug.assert(session.signed_in());

    const arena = session.arena;
    const got = registry.SDK.dispatch(&session.ctx, types_taxonomy.Get, .{
        .taxonomy = field.options.taxonomy,
    }) catch return null;
    const tree = registry.SDK.dispatch(&session.ctx, term_operations.Tree, .{
        .taxonomy = field.options.taxonomy,
    }) catch return null;
    const chosen = chosen_of(document, field.name);
    const nodes = try arena.alloc(TermNode, tree.terms.len);
    var selected_text: std.Io.Writer.Allocating = .init(arena);

    for (tree.terms, nodes) |term, *node| {
        const selected = holds(chosen, term.id);

        node.* = .{
            .id = term.id,
            .title = term.title,
            .depth = term.depth,
            .indent = indent_of(term.depth),
            .selected = selected,
        };

        if (selected) {
            selected_text.writer.print("{s} ", .{term.id}) catch return error.OutOfMemory;
            tokens.selected.writer.print("{s}:{s} ", .{ field.name, term.id }) catch {
                return error.OutOfMemory;
            };
        }

        if (term.parent) |parent| {
            tokens.tree.writer.print("{s}>{s} ", .{ term.id, parent }) catch {
                return error.OutOfMemory;
            };
        }
    }

    return .{
        .name = field.name,
        .label = field.label,
        .help = field.help,
        .hierarchical = got.definition.hierarchical,
        .many = field.many,
        .nodes = nodes,
        .selected = std.mem.trimEnd(u8, selected_text.written(), " "),
    };
}

/// The ids a document holds under a field: one, many, or none.
fn chosen_of(document: ?Value, name: []const u8) []const Value {
    std.debug.assert(name.len > 0);
    std.debug.assert(fields.items_max > 0);

    const object = document orelse return &.{};

    if (object != .object) {
        return &.{};
    }

    const value = object.object.getPtr(name) orelse return &.{};

    return switch (value.*) {
        .array => |items| items.items,
        .string => value[0..1],
        else => &.{},
    };
}

fn holds(items: []const Value, id: []const u8) bool {
    std.debug.assert(id.len > 0);
    std.debug.assert(items.len <= fields.items_max);

    for (items) |item| {
        if (item == .string and std.mem.eql(u8, item.string, id)) {
            return true;
        }
    }

    return false;
}

/// The left padding of a term at a depth: layout classes the stylesheet carries.
pub fn indent_of(depth: u32) []const u8 {
    std.debug.assert(model.tree.depth_max == 16);
    std.debug.assert(depth < model.tree.depth_max);

    return switch (@min(depth, 5)) {
        0 => "",
        1 => "pl-4",
        2 => "pl-8",
        3 => "pl-12",
        4 => "pl-16",
        else => "pl-20",
    };
}

/// The drawer's picker: the target type's records, searchable, each with a Link button.
pub fn pick(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const handle = admin.query_param(&session, "type") orelse {
        return admin.fail(&session, error.NotFound, back);
    };
    const field = admin.query_param(&session, "field") orelse "";
    const search = admin.query_param(&session, "q");
    const got = registry.SDK.dispatch(&session.ctx, types.Get, .{ .type = handle }) catch |err| {
        return admin.fail(&session, err, back);
    };
    const live_only = admin.query_param(&session, "live") != null;
    const listed = registry.SDK.dispatch(&session.ctx, record_operations.List, .{
        .type = handle,
        .filters = if (live_only) &.{"status:is:published"} else &.{},
        .search = search,
        .order = .title_asc,
        .limit = record_operations.list_max,
    }) catch |err| return admin.fail(&session, err, back);
    const arena = session.arena;
    const rows = try arena.alloc(views.RecordPick.RowsItem, listed.records.len);
    const titles = try display.titles(&session.ctx, listed.records);

    for (listed.records, titles, 0..) |record, title, index| {
        const status = registry.Statuses.find(record.status);

        rows[index] = .{
            .id = record.id,
            .title = title,
            .status = if (status) |known| known.label else record.status,
            .published = registry.Statuses.is_live(record.status),
        };
    }

    const html = try admin.render.html(arena, views.RecordPick, .{
        .type = handle,
        .type_name = got.definition.name,
        .field = field,
        .search = search orelse "",
        .live = live_only,
        .rows = rows,
    });

    try session.response.set_header("Cache-Control", "private, no-store");
    try session.response.set_header("Vary", "Accept, Publr-Fragment, Publr-Drawer");

    const accept = session.request.header("accept") orelse "";

    if (std.mem.eql(u8, accept, "application/json")) {
        return session.response.json(.ok, .{ .html = html });
    }

    return session.response.set_body(.ok, "text/html; charset=utf-8", html);
}

test "a term's indent follows its depth and stops growing at five levels" {
    try std.testing.expectEqualStrings("", indent_of(0));
    try std.testing.expectEqualStrings("pl-4", indent_of(1));
    try std.testing.expectEqualStrings("pl-20", indent_of(5));
    try std.testing.expectEqualStrings("pl-20", indent_of(15));
}
