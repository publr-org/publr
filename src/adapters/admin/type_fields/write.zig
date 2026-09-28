//! A field added, changed, removed or moved: the definition with that one change, posted
//! back through `content_type update`, so existing records follow the same rules as from
//! the CLI. A post asking for the preview (`Publr-Fragment: preview`) gets the editor
//! drawn for that definition instead, and nothing is saved.
const std = @import("std");
const spaces = @import("../schema_space.zig");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const model = @import("../../../model.zig");
const schemas = @import("../schema_fields.zig");
const type_pages = @import("../types.zig");
const field_pages = @import("../type_fields.zig");
const place_rules = @import("place.zig");
const options = @import("options.zig");
const columns = @import("columns.zig");
const levels = @import("levels.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Form = admin.Form;
const Session = admin.Session;
const Def = model.content_type.Def;
const FieldDef = model.field.Def;
const Place = place_rules.Place;
const Problem = model.field.Problem;
const print = type_pages.print;
const load = field_pages.load;
const siblings_of = place_rules.siblings_of;
const with_siblings = place_rules.with_siblings;

const back = field_pages.back;
const field_of = options.field_of;

pub fn create(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    var session = &post.session;
    const form = &post.form;
    const handle = try admin.param(session, "handle", back) orelse return;
    const got = try load(session, handle) orelse return;
    const hub = try spaces.hub(session, handle);
    const parent = form.text("parent") orelse "";
    const kind = registry.Kinds.find_kind(form.text("kind") orelse "") orelse {
        return admin.fail(session, error.Invalid, hub);
    };
    const siblings = siblings_of(got.definition, parent) orelse {
        return admin.fail(session, error.NotFound, hub);
    };
    const preview = columns.wants_preview(session);
    const typed = try field_of(session.arena, form, .{ .name = "", .label = "", .kind = kind.id });
    const field = if (preview) columns.presentable(typed) else typed;
    const grown = try session.arena.alloc(FieldDef, siblings.len + 1);

    @memcpy(grown[0..siblings.len], siblings);
    grown[siblings.len] = field;

    var def = try with_siblings(session.arena, got.definition, parent, grown);

    apply_title(&def, form, field.name, "", parent);

    if (preview) {
        return columns.answer_preview(session, def);
    }

    const another = std.mem.eql(u8, form.text("next") orelse "finish", "another");
    const next = if (another)
        try print(session.arena, "{s}/fields/new?parent={s}", .{ hub, parent })
    else if (!model.field.is_leaf(kind.id))
        try print(session.arena, "{s}/fields/{s}", .{ hub, field.name })
    else if (parent.len > 0)
        try print(session.arena, "{s}/fields/{s}", .{ hub, parent })
    else
        hub;
    const refused = try save(session, handle, def) orelse return moved(session, next);

    try field_pages.render_form(session, handle, got.definition, field, parent, null, refused);
}

pub fn update(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    var session = &post.session;
    const form = &post.form;
    const handle = try admin.param(session, "handle", back) orelse return;
    const path = try admin.param(session, "name", back) orelse return;
    const got = try load(session, handle) orelse return;
    const hub = try spaces.hub(session, handle);
    const place = try unlocked(session, got.definition, path, hub) orelse return;
    const changed = try session.arena.dupe(FieldDef, place.siblings);
    const preview = columns.wants_preview(session);
    const typed = try field_of(session.arena, form, place.field);
    const field = if (preview) columns.presentable(typed) else typed;

    changed[place.index] = field;

    var def = try with_siblings(session.arena, got.definition, place.parent, changed);

    apply_title(&def, form, field.name, place.field.name, place.parent);

    if (preview) {
        return columns.answer_preview(session, def);
    }

    const next = try parent_or_hub(session, hub, place.parent);
    const refused = try save(session, handle, def) orelse return moved(session, next);

    try field_pages.render_form(
        session,
        handle,
        got.definition,
        field,
        place.parent,
        path,
        refused,
    );
}

pub fn delete(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    var session = &post.session;
    const form = &post.form;
    const handle = try admin.param(session, "handle", back) orelse return;
    const path = try admin.param(session, "name", back) orelse return;
    const got = try load(session, handle) orelse return;
    const hub = try spaces.hub(session, handle);
    const place = try unlocked(session, got.definition, path, hub) orelse return;
    const kept = try session.arena.alloc(FieldDef, place.siblings.len - 1);

    @memcpy(kept[0..place.index], place.siblings[0..place.index]);
    @memcpy(kept[place.index..], place.siblings[place.index + 1 ..]);

    const def = try with_siblings(session.arena, got.definition, place.parent, kept);
    const definition = model.content_type.encode(session.arena, def) catch return error.OutOfMemory;

    schemas.update(
        session,
        handle,
        definition,
        form.get("drop_content") != null,
    ) catch |err| return held_or_problems(
        session,
        err,
        definition,
        path,
        hub,
    );

    try moved(session, try parent_or_hub(session, hub, place.parent));
}

/// A removed field that records still hold values for: say so, with the way back to
/// the field, where "also delete its values" is offered.
fn held_or_problems(
    session: *Session,
    err: anyerror,
    definition: []const u8,
    path: []const u8,
    hub: []const u8,
) Error!void {
    std.debug.assert(path.len > 0);
    std.debug.assert(hub.len > 0);

    if (err != error.Conflict) {
        const refused = try schemas.problems(session, err, definition);

        return admin.message(session, "The field was not removed", "", refused, hub);
    }

    const field_href = try print(session.arena, "{s}/fields/{s}", .{ hub, path });

    try admin.message(
        session,
        "Records hold values for this field",
        "Delete it from its own page, with \"also delete its values\" ticked.",
        &[_]model.field.Problem{},
        field_href,
    );
}

pub fn move(request: *Request, response: *Response, ctx: *Context) Error!void {
    std.debug.assert(request.method() == .post);
    std.debug.assert(ctx.user_data != null);

    var post = try admin.accept(request, response, ctx, back) orelse return;
    var session = &post.session;
    const form = &post.form;
    const handle = try admin.param(session, "handle", back) orelse return;
    const path = try admin.param(session, "name", back) orelse return;
    const got = try load(session, handle) orelse return;
    const hub = try spaces.hub(session, handle);
    const place = try unlocked(session, got.definition, path, hub) orelse return;
    const up = std.mem.eql(u8, form.text("direction") orelse "down", "up");
    const other: ?usize = if (up)
        (if (place.index > 0) place.index - 1 else null)
    else
        (if (place.index + 1 < place.siblings.len) place.index + 1 else null);
    const neighbour = other orelse return response.redirect(.see_other, hub);

    if (place.siblings[neighbour].locked) {
        return response.redirect(.see_other, hub);
    }

    const swapped = try session.arena.dupe(FieldDef, place.siblings);

    swapped[place.index] = place.siblings[neighbour];
    swapped[neighbour] = place.siblings[place.index];

    const def = try with_siblings(session.arena, got.definition, place.parent, swapped);

    try save_and_redirect(session, handle, def, try parent_or_hub(session, hub, place.parent));
}

/// The definition saved: null when it went through, else what was wrong with it (an
/// invalid definition lists its problems; any other refusal is one line).
pub fn save(session: *Session, handle: []const u8, def: Def) Error!?[]const Problem {
    std.debug.assert(handle.len > 0);
    std.debug.assert(session.signed_in());

    const definition = model.content_type.encode(session.arena, def) catch return error.OutOfMemory;

    schemas.update(
        session,
        handle,
        definition,
        false,
    ) catch |err| return try schemas.problems(
        session,
        err,
        definition,
    );

    return null;
}

fn save_and_redirect(session: *Session, handle: []const u8, def: Def, next: []const u8) Error!void {
    std.debug.assert(handle.len > 0);
    std.debug.assert(next.len > 0);

    const hub = try spaces.hub(session, handle);
    const refused = try save(session, handle, def) orelse return moved(session, next);

    try admin.message(session, "The content type is not valid", "", refused, hub);
}

/// A write that went through: the page's script is told where to go next, a plain form is
/// sent there.
fn moved(session: *Session, next: []const u8) Error!void {
    std.debug.assert(next.len > 0);
    std.debug.assert(session.signed_in());

    if (levels.wants_panel(session)) {
        return levels.answer_moved(session, next);
    }

    try session.response.redirect(.see_other, next);
}

/// Where a change inside a group or repeater lands: its parent's page; the type's page
/// at the top level.
fn parent_or_hub(session: *Session, hub: []const u8, parent: []const u8) Error![]const u8 {
    std.debug.assert(hub.len > 0);
    std.debug.assert(session.signed_in());

    if (parent.len == 0) {
        return hub;
    }

    return print(session.arena, "{s}/fields/{s}", .{ hub, parent });
}

/// "Title field" is one option among a top-level text field's: ticked, this field becomes
/// the type's title (and whichever field was, no longer is); unticked on the field that
/// was, the type has none. A renamed title field keeps the title.
fn apply_title(
    def: *Def,
    form: *const Form,
    name: []const u8,
    previous_name: []const u8,
    parent: []const u8,
) void {
    std.debug.assert(name.len <= model.field.name_len_max or name.len == 0);
    std.debug.assert(form.len <= admin.form_pairs_max);

    if (parent.len > 0) {
        return;
    }

    const was_title = previous_name.len > 0 and std.mem.eql(u8, def.title_field, previous_name);

    if (form.get("title") != null) {
        def.title_field = name;
    } else if (was_title) {
        def.title_field = "";
    }
}

/// The field at `path`, unless it is missing (not found) or declared in code (denied).
fn unlocked(session: *Session, def: Def, path: []const u8, hub: []const u8) Error!?Place {
    std.debug.assert(path.len > 0);
    std.debug.assert(hub.len > 0);

    const place = place_rules.locate(def, path) orelse {
        try admin.fail(session, error.NotFound, hub);

        return null;
    };

    if (place.field.locked) {
        try admin.fail(session, error.Denied, hub);

        return null;
    }

    return place;
}

test {
    std.testing.refAllDecls(@This());
}
