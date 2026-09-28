//! Terms in the admin: a taxonomy's page (its terms as a tree), and the term editor,
//! `editor.zig` over the term operations, with the parent in its aside.
const std = @import("std");
const admin = @import("../admin.zig");
const fields = @import("fields.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const taxonomy_operations = @import("../../operations/taxonomy.zig");
const term_operations = @import("../../operations/term.zig");
const taxonomy_pages = @import("taxonomies.zig");
const record_form = @import("content/form.zig");
const editor = @import("editor.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Session = admin.Session;
const views = admin.views;
const Def = model.content_type.Def;
const Value = std.json.Value;
const print = fields.print;

pub const back = "/admin/terms";

const Editor = editor.Editor(.{
    .base = back,
    .section = "types",
    .operations = term_operations,
    .key = "taxonomy",
    .row = "term",
    .definitions = taxonomy_operations,
    .definition_key = "taxonomy",
    .crumb = crumb_of,
    .aside = aside_of,
    .versions = false,
});

pub const new_page = Editor.new_page;
pub const new_editor = Editor.new_editor;
pub const edit = Editor.edit;
pub const editor_fragment = Editor.editor;
pub const create = Editor.create;
pub const save = Editor.save;
pub const action = Editor.action;

fn crumb_of(arena: std.mem.Allocator, def: Def) Error![]const u8 {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(taxonomy_pages.back.len > 0);

    return print(arena, "{s}/{s}", .{ taxonomy_pages.back, def.handle });
}

/// A term's aside: its parent, in a hierarchical taxonomy: every other term but what is
/// below the term itself.
fn aside_of(
    session: *Session,
    def: Def,
    shape: editor.Shape,
    document: ?Value,
) Error!?admin.render.Node {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(document == null or document.? == .object);

    if (!def.hierarchical) {
        return null;
    }

    const own_id: ?[]const u8 = if (shape.loaded) |full| full.row.id else null;
    const current = try current_parent(session, own_id);
    const tree = registry.SDK.dispatch(&session.ctx, term_operations.Tree, .{
        .taxonomy = def.handle,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else null;
    var parents: std.ArrayList(views.TermParent.ParentsItem) = .empty;
    var below_depth: ?u32 = null;

    for (tree.terms) |term| {
        if (below_depth) |depth| {
            if (term.depth > depth) {
                continue;
            }

            below_depth = null;
        }

        if (own_id != null and std.mem.eql(u8, term.id, own_id.?)) {
            below_depth = term.depth;

            continue;
        }

        parents.append(session.arena, .{
            .id = term.id,
            .title = try titled(session.arena, term.title, term.depth),
            .selected = current != null and std.mem.eql(u8, current.?, term.id),
        }) catch return error.OutOfMemory;
    }

    return try admin.render.view(session.arena, views.TermParent, .{
        .parents = parents.items,
        .is_root = current == null,
    });
}

/// The parent the term has now (an existing term), or the one a new term is asked to
/// start under (`?parent=` on the editor's address).
fn current_parent(session: *Session, own_id: ?[]const u8) Error!?[]const u8 {
    std.debug.assert(session.signed_in());
    std.debug.assert(back.len > 0);

    const id = own_id orelse return admin.query_param(session, "parent");
    const got = registry.SDK.dispatch(&session.ctx, term_operations.Get, .{
        .id = id,
        .purpose = .edit,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else null;

    return got.parent;
}

/// A title shown at its depth: two spaces and a dash per level.
fn titled(arena: std.mem.Allocator, title: []const u8, depth: u32) Error![]const u8 {
    std.debug.assert(depth < model.tree.depth_max);
    std.debug.assert(title.len <= 64 << 10);

    if (depth == 0) {
        return title;
    }

    var out: std.Io.Writer.Allocating = .init(arena);
    var level: u32 = 0;

    while (level < depth) : (level += 1) {
        out.writer.writeAll("\u{2007}\u{2007}") catch return error.OutOfMemory;
    }

    out.writer.print("- {s}", .{title}) catch return error.OutOfMemory;

    return out.written();
}

/// A taxonomy's page: its terms in tree order.
pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .get or request.method() == .head);
    std.debug.assert(ctx.user_data != null);

    var session = try admin.require(request, response, ctx) orelse return;
    const handle = try admin.param(&session, "handle", taxonomy_pages.back) orelse return;
    const got = try taxonomy_pages.load(&session, handle) orelse return;
    const tree = registry.SDK.dispatch(&session.ctx, term_operations.Tree, .{
        .taxonomy = handle,
    }) catch |err| return admin.fail(&session, err, taxonomy_pages.back);
    const arena = session.arena;
    const def = got.definition;
    const rows = try arena.alloc(views.Terms.TermsItem, tree.terms.len);

    for (tree.terms, rows) |term, *row| {
        const status = registry.Statuses.find(term.status);
        const add_child_href = if (def.hierarchical)
            try print(arena, "{s}/new?type={s}&parent={s}", .{ back, handle, term.id })
        else
            "";

        row.* = .{
            .href = try print(arena, "{s}/{s}", .{ back, term.id }),
            .title = if (term.title.len > 0) term.title else term.id,
            .slug = term.slug orelse "",
            .status = if (status) |known| known.label else term.status,
            .published = registry.Statuses.is_live(term.status),
            .depth = term.depth,
            .indent = record_form.indent_of(term.depth),
            .add_child_href = add_child_href,
        };
    }

    const shell = admin.shell_of(&session);

    try admin.render.page(response, arena, .ok, views.Terms, .{
        .user_name = shell.user_name,
        .user_email = shell.user_email,
        .can_structure = shell.can_structure,
        .can_settings = shell.can_settings,
        .csrf = shell.csrf,
        .title = def.name,
        .handle = def.handle,
        .hierarchical = def.hierarchical,
        .settings_href = try print(arena, "{s}/{s}/settings", .{ taxonomy_pages.back, handle }),
        .new_href = try print(arena, "{s}/new?type={s}", .{ back, handle }),
        .terms = rows,
    });
}

test "a term's title is indented by its depth" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("Root", try titled(arena, "Root", 0));
    try std.testing.expectEqualStrings("\u{2007}\u{2007}- Child", try titled(arena, "Child", 1));
}
