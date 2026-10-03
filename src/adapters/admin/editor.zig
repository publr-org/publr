//! The document editor, for records and for terms: a new document of a definition, or an
//! existing one. The editor is a fragment (RecordEditor) the page wraps in its shell and
//! the drawer fetches bare; a post from the editor's script asks, by the `Publr-Fragment`
//! header, for the editor drawn again (`editor`) or for a JSON verdict (`json`, the
//! autosave) instead of a redirect. `content/form.zig` and `terms.zig` instantiate it.
const std = @import("std");
const admin = @import("../admin.zig");
const fields = @import("fields.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const types = @import("../../operations/content_type.zig");
const record_operations = @import("../../operations/record.zig");
const term_operations = @import("../../operations/term.zig");
const definitions = @import("definitions.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Form = admin.Form;
const Session = admin.Session;
const views = admin.views;
const Def = model.content_type.Def;
const Value = std.json.Value;
const Problem = views.RecordEditor.ProblemsItem;
const Action = views.RecordEditor.ActionsItem;
const print = fields.print;
const keyed = definitions.keyed;

pub const Record = fields.Record;

/// A loaded document: its row, the slot it was read from, its document as JSON text.
pub const Loaded = struct { row: Record, slot: []const u8, document: []const u8 };

/// What the editor is about: the definition, and the document when there is one.
pub const Shape = struct {
    def: Def,
    loaded: ?Loaded,
    /// Drawn as a preview of the definition: the form alone, nothing posts.
    preview: bool = false,
};

pub const Domain = struct {
    /// `/admin/content`, `/admin/terms`.
    base: []const u8,
    /// The layout section the pages belong to.
    section: []const u8,
    /// The document operations: `Create`, `Get`, `Save`, `Validate`, `Publish`,
    /// `DiscardChanges`, `Purge`, `Transition`.
    operations: type,
    /// The field naming the definition in `Create`/`Validate`: `type`, `taxonomy`.
    key: []const u8,
    /// The row's field in `Get.Out`: `record`, `term`.
    row: []const u8,
    /// The definition operations (`Get`) and their key.
    definitions: type,
    definition_key: []const u8,
    /// Where the definition's own list is: the crumb over the editor.
    crumb: fn (arena: std.mem.Allocator, def: Def) Error![]const u8,
    /// The sections of the aside the domain adds under the actions.
    aside: fn (
        session: *Session,
        def: Def,
        shape: Shape,
        document: ?Value,
    ) Error!?admin.render.Node,
    /// The record's revisions page, when the domain keeps one.
    versions: bool,
};

/// Where the answer goes: the whole page, or the editor fragment alone.
const Answer = enum { page, fragment };

pub fn Editor(comptime domain: Domain) type {
    return struct {
        const operations = domain.operations;
        const back = domain.base;
        pub const create_url = domain.base ++ "/create";

        pub fn new_page(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .get or request.method() == .head);
            std.debug.assert(ctx.user_data != null);

            var session = try admin.require(request, response, ctx) orelse return;
            const shape = try load_definition(&session) orelse return;
            const document = try seeded(session.arena, shape.def, session.ctx.now_ms);

            try answer(&session, shape, document, &.{}, .page);
        }

        pub fn new_editor(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .get or request.method() == .head);
            std.debug.assert(ctx.user_data != null);

            var session = try admin.require(request, response, ctx) orelse return;
            const shape = try load_definition(&session) orelse return;
            const document = try seeded(session.arena, shape.def, session.ctx.now_ms);

            try answer(&session, shape, document, &.{}, .fragment);
        }

        /// The editor as a preview of `def` for the definition's fields page: a new
        /// document with every default filled in, without the title band, the status
        /// strip and the aside.
        pub fn preview_node(session: *Session, def: Def) Error!admin.render.Node {
            std.debug.assert(def.handle.len > 0);
            std.debug.assert(session.signed_in());

            const shape: Shape = .{ .def = def, .loaded = null, .preview = true };
            const document = try seeded(session.arena, def, session.ctx.now_ms);

            return editor_node(session, shape, document, &.{});
        }

        pub fn edit(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .get or request.method() == .head);
            std.debug.assert(ctx.user_data != null);

            var session = try admin.require(request, response, ctx) orelse return;
            const id = try admin.param(&session, "id", back) orelse return;
            const shape = try load(&session, id) orelse return;
            const document = parse(session.arena, shape.loaded.?.document) orelse {
                return admin.fail(&session, error.Invalid, back);
            };

            try answer(&session, shape, document, &.{}, .page);
        }

        pub fn editor(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .get or request.method() == .head);
            std.debug.assert(ctx.user_data != null);

            var session = try admin.require(request, response, ctx) orelse return;
            const id = try admin.param(&session, "id", back) orelse return;

            try answer_loaded(&session, id);
        }

        pub fn create(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .post);
            std.debug.assert(ctx.user_data != null);

            var post = try admin.accept(request, response, ctx, back) orelse return;
            var session = &post.session;
            const form = &post.form;
            const handle = form.text("type") orelse return admin.fail(session, error.Invalid, back);
            const def = try definition_of(session, handle) orelse return;
            const shape: Shape = .{ .def = def, .loaded = null };

            if (try reshaped(session, shape, form)) {
                return;
            }

            const document = fields.decode.document_of(session.arena, def.fields, form) orelse {
                return admin.fail(session, error.Invalid, back);
            };
            var in = keyed(operations.Create.In, domain.key, handle, .{ .document = document });

            if (@hasField(operations.Create.In, "parent")) {
                in.parent = form.get("parent");
            }

            if (@hasField(operations.Create.In, "app")) {
                in.app = admin.app_scope.of(session).app_name();
            }

            const created = registry.SDK.dispatch(&session.ctx, operations.Create, in) catch |err| {
                return refused(session, shape, err, document);
            };

            try saved(session, created.id);
        }

        pub fn save(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .post);
            std.debug.assert(ctx.user_data != null);

            var post = try admin.accept(request, response, ctx, back) orelse return;
            var session = &post.session;
            const form = &post.form;
            const id = try admin.param(session, "id", back) orelse return;
            const shape = try load(session, id) orelse return;

            if (try reshaped(session, shape, form)) {
                return;
            }

            const defs = shape.def.fields;
            const document = fields.decode.document_of(session.arena, defs, form) orelse {
                return admin.fail(session, error.Invalid, back);
            };
            const location = try print(session.arena, "{s}/{s}", .{ back, id });
            const expected = expected_version_of(form) orelse {
                return admin.fail(session, error.Invalid, location);
            };
            var in: operations.Save.In = .{
                .id = id,
                .document = document,
                .expected_version = expected,
            };

            if (@hasField(operations.Save.In, "parent")) {
                in.parent = form.get("parent");
            }

            _ = registry.SDK.dispatch(&session.ctx, operations.Save, in) catch |err| {
                return refused(session, shape, err, document);
            };

            try saved(session, id);
        }

        /// A status action posted from the aside: publish, discard, purge, or a transition.
        pub fn action(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .post);
            std.debug.assert(ctx.user_data != null);

            var post = try admin.accept(request, response, ctx, back) orelse return;
            var session = &post.session;
            const form = &post.form;
            const id = try admin.param(session, "id", back) orelse return;
            const location = try print(session.arena, "{s}/{s}", .{ back, id });
            const verb = form.text("do") orelse "transition";
            const fragment = wants_fragment(session);
            const expected = expected_version_of(form) orelse {
                return admin.fail(session, error.Invalid, location);
            };

            if (std.mem.eql(u8, verb, "publish")) {
                _ = registry.SDK.dispatch(&session.ctx, operations.Publish, .{
                    .id = id,
                    .expected_version = expected,
                }) catch |err| return admin.fail(session, err, location);
            } else if (std.mem.eql(u8, verb, "discard")) {
                _ = registry.SDK.dispatch(&session.ctx, operations.DiscardChanges, .{
                    .id = id,
                    .expected_version = expected,
                }) catch |err| return admin.fail(session, err, location);
            } else if (std.mem.eql(u8, verb, "purge")) {
                _ = registry.SDK.dispatch(&session.ctx, operations.Purge, .{
                    .id = id,
                }) catch |err| return admin.fail(session, err, location);

                if (fragment) {
                    return answer_gone(session, back);
                }

                return response.redirect(.see_other, back);
            } else {
                const to = form.text("to") orelse {
                    return admin.fail(session, error.Invalid, location);
                };

                _ = registry.SDK.dispatch(&session.ctx, operations.Transition, .{
                    .id = id,
                    .to = to,
                    .expected_version = expected,
                }) catch |err| return admin.fail(session, err, location);
            }

            if (fragment) {
                return answer_loaded(session, id);
            }

            try response.redirect(.see_other, location);
        }

        /// The definition a new document is of, from the query, or a not-found page.
        fn load_definition(session: *Session) Error!?Shape {
            std.debug.assert(session.signed_in());
            std.debug.assert(back.len > 0);

            const handle = admin.query_param(session, "type") orelse {
                try admin.fail(session, error.NotFound, back);

                return null;
            };
            const def = try definition_of(session, handle) orelse return null;

            return .{ .def = def, .loaded = null };
        }

        fn definition_of(session: *Session, handle: []const u8) Error!?Def {
            std.debug.assert(handle.len > 0);
            std.debug.assert(session.signed_in());

            const Get = domain.definitions.Get;
            const in = keyed(Get.In, domain.definition_key, handle, .{});
            const got = registry.SDK.dispatch(&session.ctx, Get, in) catch |err| {
                try admin.fail(session, err, back);

                return null;
            };

            return got.definition;
        }

        /// Open singleton settings without creating data on a GET request.
        pub fn settings_page(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .get or request.method() == .head);
            var session = try admin.require(request, response, ctx) orelse return;
            const handle = try admin.param(&session, "handle", "/admin/settings") orelse return;
            const def = try definition_of(&session, handle) orelse return;

            if (def.kind != .settings) {
                return admin.fail(&session, error.NotFound, "/admin/settings");
            }

            const listed = registry.SDK.dispatch(&session.ctx, operations.List, .{
                .type = handle,
                .limit = 1,
            }) catch |err| return admin.fail(&session, err, "/admin/settings");
            const shape: Shape = if (listed.records.len > 0)
                try load(&session, listed.records[0].id) orelse return
            else
                .{ .def = def, .loaded = null };
            const document = if (shape.loaded) |full|
                parse(session.arena, full.document)
            else
                try seeded(session.arena, def, session.ctx.now_ms);
            try answer(&session, shape, document, &.{}, .page);
        }

        /// The document for editing and its definition, or a not-found page.
        pub fn load(session: *Session, id: []const u8) Error!?Shape {
            std.debug.assert(id.len > 0);
            std.debug.assert(session.signed_in());

            const full = registry.SDK.dispatch(&session.ctx, operations.Get, .{
                .id = id,
                .purpose = .edit,
            }) catch |err| {
                try admin.fail(session, err, back);

                return null;
            };
            const row: Record = @field(full, domain.row);
            const def = try definition_of(session, row.type) orelse return null;

            return .{ .def = def, .loaded = .{
                .row = row,
                .slot = full.slot,
                .document = full.document,
            } };
        }

        /// Whether the post came from the editor's script asking for the editor drawn again.
        pub fn wants_fragment(session: *const Session) bool {
            std.debug.assert(session.signed_in());
            std.debug.assert(back.len > 0);

            const wanted = session.request.header("publr-fragment") orelse return false;

            return std.mem.eql(u8, wanted, "editor");
        }

        fn wants_json(session: *const Session) bool {
            std.debug.assert(session.signed_in());
            std.debug.assert(back.len > 0);

            const wanted = session.request.header("publr-fragment") orelse return false;

            return std.mem.eql(u8, wanted, "json");
        }

        fn in_drawer(session: *const Session) bool {
            std.debug.assert(session.signed_in());
            std.debug.assert(back.len > 0);

            if (session.request.header("publr-drawer")) |flag| {
                return std.mem.eql(u8, flag, "1");
            }

            return admin.query_param(session, "in_drawer") != null;
        }

        /// A write that went through: the JSON verdict for the autosave, the editor drawn
        /// again for the script, the document's page for a plain form.
        fn saved(session: *Session, id: []const u8) Error!void {
            std.debug.assert(id.len > 0);
            std.debug.assert(session.signed_in());

            if (wants_json(session)) {
                return json_saved(session, id);
            }

            if (wants_fragment(session)) {
                return answer_loaded(session, id);
            }

            const location = try print(session.arena, "{s}/{s}", .{ back, id });

            try session.response.redirect(.see_other, location);
        }

        fn json_saved(session: *Session, id: []const u8) Error!void {
            std.debug.assert(id.len > 0);
            std.debug.assert(session.signed_in());

            const shape = try load(session, id) orelse return;
            const row = shape.loaded.?.row;

            session.response.json(.ok, .{
                .saved = true,
                .id = row.id,
                .version = row.version,
                .title = row.title,
                .status = row.status,
                .changed = row.changed,
            }) catch return error.OutOfMemory;
        }

        /// The editor fragment of a document, with its page's address for the script.
        pub fn answer_loaded(session: *Session, id: []const u8) Error!void {
            std.debug.assert(id.len > 0);
            std.debug.assert(session.signed_in());

            const shape = try load(session, id) orelse return;
            const document = parse(session.arena, shape.loaded.?.document) orelse {
                return admin.fail(session, error.Invalid, back);
            };
            const location = try print(session.arena, "{s}/{s}", .{ back, id });

            session.response.set_header("Publr-Location", location) catch return error.OutOfMemory;

            try answer(session, shape, document, &.{}, .fragment);
        }

        /// A document that is gone (purged): nothing to draw, the script goes to `location`.
        pub fn answer_gone(session: *Session, location: []const u8) Error!void {
            std.debug.assert(location.len > 0);
            std.debug.assert(session.signed_in());

            session.response.set_header("Publr-Location", location) catch return error.OutOfMemory;

            try session.response.set_body(.ok, "text/html; charset=utf-8", "");
        }

        /// A reshape post: the editor drawn again with the value added, removed or moved.
        /// Answers true when it was one and the answer went out.
        fn reshaped(session: *Session, shape: Shape, form: *const Form) Error!bool {
            std.debug.assert(session.signed_in());
            std.debug.assert(form.len <= admin.form_pairs_max);

            const verb = form.text("reshape") orelse return false;
            const posted = fields.decode.value_of(session.arena, shape.def.fields, form) catch {
                try admin.fail(session, error.Invalid, back);

                return true;
            };
            const defs = shape.def.fields;
            const document = fields.reshape.apply(session.arena, defs, posted, verb, form) catch {
                try admin.fail(session, error.Invalid, back);

                return true;
            };
            const how: Answer = if (wants_fragment(session)) .fragment else .page;

            try answer(session, shape, document, &.{}, how);

            return true;
        }

        /// A refused write: the JSON reason for the autosave, else the editor again with
        /// the document's problems when it was the document, else the message page.
        fn refused(
            session: *Session,
            shape: Shape,
            err: anyerror,
            document: []const u8,
        ) Error!void {
            std.debug.assert(document.len > 0);
            std.debug.assert(session.signed_in());

            if (wants_json(session)) {
                return json_refused(session, shape, err, document);
            }

            if (err != error.Invalid) {
                return admin.fail(session, err, back);
            }

            const problems = try problems_of(session, shape, document);
            const value = parse(session.arena, document) orelse {
                return admin.fail(session, error.Invalid, back);
            };
            const how: Answer = if (wants_fragment(session)) .fragment else .page;

            try answer(session, shape, value, problems, how);
        }

        fn json_refused(
            session: *Session,
            shape: Shape,
            err: anyerror,
            document: []const u8,
        ) Error!void {
            std.debug.assert(document.len > 0);
            std.debug.assert(session.signed_in());

            const reason = try reason_of(session, shape, err, document);
            const verdict = .{ .saved = false, .reason = reason };

            session.response.json(.ok, verdict) catch return error.OutOfMemory;
        }

        /// Why the autosave was refused, in the words the status strip shows.
        fn reason_of(
            session: *Session,
            shape: Shape,
            err: anyerror,
            document: []const u8,
        ) Error![]const u8 {
            std.debug.assert(document.len > 0);
            std.debug.assert(shape.def.handle.len > 0);

            if (err == error.Conflict) {
                return "Not saved: changed elsewhere, reload the page";
            }

            if (err != error.Invalid) {
                return "Not saved";
            }

            const problems = try problems_of(session, shape, document);

            if (problems.len == 0) {
                return "Not saved: the document is not valid";
            }

            const first = problems[0];

            return print(session.arena, "Not saved: {s} {s}", .{ first.path, first.message });
        }

        fn problems_of(
            session: *Session,
            shape: Shape,
            document: []const u8,
        ) Error![]const Problem {
            std.debug.assert(document.len > 0);
            std.debug.assert(shape.def.handle.len > 0);

            const Validate = operations.Validate;
            const in = keyed(Validate.In, domain.key, shape.def.handle, .{ .document = document });
            const checked = registry.SDK.dispatch(&session.ctx, Validate, in) catch |inner| {
                try admin.fail(session, inner, back);

                return &.{};
            };
            const problems = try session.arena.alloc(Problem, checked.problems.len);

            for (checked.problems, 0..) |problem, index| {
                problems[index] = .{ .path = problem.path, .message = problem.message };
            }

            return problems;
        }

        fn answer(
            session: *Session,
            shape: Shape,
            document: ?Value,
            problems: []const Problem,
            how: Answer,
        ) Error!void {
            std.debug.assert(shape.def.handle.len > 0);
            std.debug.assert(session.signed_in());

            const arena = session.arena;
            const editor_panel = try editor_node(session, shape, document, problems);

            if (how == .fragment) {
                const html = try admin.render.to_html(arena, editor_panel);

                return fragment_answer(session, html);
            }

            const shell = admin.shell_of(session);
            const def = shape.def;

            if (def.kind == .settings) {
                return admin.render.page(session.response, arena, .ok, views.SettingsDocument, .{
                    .user_name = shell.user_name,
                    .user_email = shell.user_email,
                    .can_structure = shell.can_structure,
                    .can_settings = shell.can_settings,
                    .top_bar = shell.top_bar,
                    .csrf = shell.csrf,
                    .title = def.name,
                    .description = def.description,
                    .has_fields = def.fields.len > 0,
                    .schema_href = try print(arena, "/admin/structure/settings/{s}", .{def.handle}),
                    .nav = try @import("settings_nav.zig").node(session, def.handle),
                    .editor = editor_panel,
                });
            }

            const title = if (shape.loaded) |full|
                (if (full.row.title.len > 0) full.row.title else full.row.id)
            else
                try print(arena, "New {s}", .{def.name});

            try admin.render.page(session.response, arena, .ok, views.RecordForm, .{
                .user_name = shell.user_name,
                .user_email = shell.user_email,
                .can_structure = shell.can_structure,
                .can_settings = shell.can_settings,
                .top_bar = shell.top_bar,
                .csrf = shell.csrf,
                .title = title,
                .section = domain.section,
                .crumb_label = def.name,
                .crumb_href = try domain.crumb(arena, def),
                .editor = editor_panel,
            });
        }

        fn editor_node(
            session: *Session,
            shape: Shape,
            document: ?Value,
            problems: []const Problem,
        ) Error!admin.render.Node {
            std.debug.assert(shape.def.handle.len > 0);
            std.debug.assert(session.signed_in());

            const arena = session.arena;
            const shell = admin.shell_of(session);
            const def = shape.def;
            const status_now = if (shape.loaded) |full| full.row.status else "";
            const live = shape.loaded != null and registry.Statuses.is_live(status_now);
            const context: fields.Context = .{
                .arena = arena,
                .users = try user_options(session, def.fields),
                .referenced = try referenced_of(session, def, document),
                .types = try types_of(session, def),
                .terms = try terms_of(session, def),
                .slug_prefix = try slug_prefix_of(session, def),
                .live = live,
                .currencies = try currencies_of(session),
            };
            const rows = try fields.rows_of(context, def.fields, document);
            const field_rows = try admin.render.view(arena, views.RecordFields, .{
                .group_visible = model.field_group.applies(def.group, .{
                    .destination = if (comptime std.mem.eql(
                        u8,
                        domain.key,
                        "taxonomy",
                    )) .taxonomy else if (def.kind == .settings) .settings else .content,
                    .type = def.handle,
                }),
                .group_labels = @tagName(def.group.presentation.labels),
                .group_instructions = @tagName(def.group.presentation.instructions),
                .fields = rows,
            });
            const drawer = in_drawer(session);
            const aside = if (shape.preview)
                null
            else
                try domain.aside(session, def, shape, document);

            if (shape.loaded) |full| {
                const row = full.row;
                const parks = row.changed or registry.Statuses.is_live(row.status);
                const status = registry.Statuses.find(row.status);
                const may_purge = registry.SDK.may(&session.ctx, operations.Purge);
                const actions = try actions_of(arena, row, may_purge);
                const versions_href = if (domain.versions)
                    try print(arena, "{s}/{s}/revisions", .{ back, row.id })
                else
                    "";

                return admin.render.view(arena, views.RecordEditor, .{
                    .group_position = @tagName(def.group.presentation.position),
                    .csrf = shell.csrf,
                    .id = row.id,
                    .record_url = try print(arena, "{s}/{s}", .{ back, row.id }),
                    .save_url = try print(arena, "{s}/{s}/save", .{ back, row.id }),
                    .create_url = create_url,
                    .base_url = back,
                    .is_new = false,
                    .in_drawer = drawer,
                    .action_route = try print(arena, "{s}/{s}/action", .{ back, row.id }),
                    .type = row.type,
                    .type_name = if (def.kind == .settings) def.description else def.name,
                    .title = if (def.kind == .settings)
                        def.name
                    else if (row.title.len > 0)
                        row.title
                    else
                        row.id,
                    .expected_version = try print(arena, "{d}", .{row.version}),
                    .status = row.status,
                    .status_label = if (status) |known| known.label else row.status,
                    .changed = row.changed,
                    .versions_href = versions_href,
                    .problems = problems,
                    .actions = actions,
                    .has_destructive = has_destructive(actions),
                    .fields = field_rows,
                    .parks = parks,
                    .preview = shape.preview,
                    .aside = aside,
                    .impact = null,
                });
            }

            return admin.render.view(arena, views.RecordEditor, .{
                .group_position = @tagName(def.group.presentation.position),
                .csrf = shell.csrf,
                .id = "",
                .record_url = "",
                .save_url = "",
                .create_url = create_url,
                .base_url = back,
                .is_new = true,
                .in_drawer = drawer,
                .action_route = "",
                .type = def.handle,
                .type_name = if (def.kind == .settings) def.description else def.name,
                .title = if (def.kind == .settings) def.name else try print(
                    arena,
                    "New {s}",
                    .{
                        def.name,
                    },
                ),
                .expected_version = "",
                .status = "",
                .status_label = "",
                .changed = false,
                .versions_href = "",
                .problems = problems,
                .actions = &.{},
                .has_destructive = false,
                .fields = field_rows,
                .parks = false,
                .preview = shape.preview,
                .aside = aside,
                .impact = null,
            });
        }
    };
}

/// The status actions a document offers from where it is: publish, discard, every
/// transition out of the current status, and purge for whoever may purge.
pub fn actions_of(arena: std.mem.Allocator, row: Record, may_purge: bool) Error![]const Action {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(row.status.len > 0);

    const status = row.status;
    const live = registry.Statuses.is_live(status);
    var actions: std.ArrayList(Action) = .empty;

    if (live and row.changed) {
        try add_action(arena, &actions, "do", "publish", "Publish changes", false);
    } else if (!live and registry.Statuses.allows(status, "published")) {
        try add_action(arena, &actions, "do", "publish", "Publish", false);
    }

    if (row.changed) {
        try add_action(arena, &actions, "do", "discard", "Discard changes", true);
    }

    for (registry.Statuses.all_transitions) |transition| {
        const from_here = std.mem.eql(u8, transition.from, "*") or
            std.mem.eql(u8, transition.from, status);
        const skip = registry.Statuses.is_live(transition.to) or
            std.mem.eql(u8, transition.to, status);

        if (!from_here or skip) {
            continue;
        }

        const destructive = std.mem.eql(u8, transition.to, "deleted");

        try add_action(arena, &actions, "to", transition.to, transition.label, destructive);
    }

    if (may_purge) {
        try add_action(arena, &actions, "do", "purge", "Purge for good", true);
    }

    mark_primary(actions.items);

    return actions.items;
}

/// The split button's face: publishing when it is on offer, else the first action that
/// can be undone; everything else goes in the menu.
fn mark_primary(actions: []Action) void {
    std.debug.assert(actions.len <= 64);
    std.debug.assert(fields.items_max > 0);

    for (actions) |*entry| {
        if (std.mem.eql(u8, entry.value, "publish")) {
            entry.primary = true;

            return;
        }
    }

    for (actions) |*entry| {
        if (!entry.destructive) {
            entry.primary = true;

            return;
        }
    }
}

pub fn has_destructive(actions: []const Action) bool {
    std.debug.assert(actions.len <= 64);
    std.debug.assert(fields.items_max > 0);

    for (actions) |entry| {
        if (entry.destructive) {
            return true;
        }
    }

    return false;
}

fn add_action(
    arena: std.mem.Allocator,
    actions: *std.ArrayList(Action),
    name: []const u8,
    value: []const u8,
    label: []const u8,
    destructive: bool,
) Error!void {
    std.debug.assert(name.len > 0);
    std.debug.assert(label.len > 0);

    actions.append(arena, .{
        .name = name,
        .value = value,
        .label = label,
        .destructive = destructive,
        .primary = false,
    }) catch return error.OutOfMemory;
}

/// What a new document starts with: the defaults of the definition's fields, or nothing
/// when no field has one.
fn seeded(arena: std.mem.Allocator, def: Def, now: i64) Error!?Value {
    std.debug.assert(def.fields.len <= model.field.fields_max);
    std.debug.assert(def.handle.len > 0);

    var object: std.json.ObjectMap = .empty;

    try model.defaults.apply(registry.Kinds.all, def.fields, arena, &object, now);

    if (object.count() == 0) {
        return null;
    }

    return .{ .object = object };
}

fn fragment_answer(session: *Session, html: []const u8) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(html.len > 0);

    const accept = session.request.header("accept") orelse "";

    try session.response.set_header("Cache-Control", "private, no-store");
    try session.response.set_header("Vary", "Accept, Publr-Fragment, Publr-Drawer");

    if (std.mem.eql(u8, accept, "application/json")) {
        return session.response.json(.ok, .{ .html = html });
    }

    return session.response.set_body(.ok, "text/html; charset=utf-8", html);
}

/// Every record the document points at, fetched once so the cards can name it, with
/// its type's name. Pointers are always at records, whatever the document is.
pub fn referenced_of(
    session: *Session,
    def: Def,
    document: ?Value,
) Error![]const fields.Referenced {
    std.debug.assert(def.fields.len <= model.field.fields_max);
    std.debug.assert(session.signed_in());

    const object = document orelse return &.{};

    if (object != .object) {
        return &.{};
    }

    var ids: std.ArrayList([]const u8) = .empty;

    for (def.fields) |field| {
        const value = object.object.get(field.name) orelse continue;

        if (model.field.is_group(field.kind) and value == .object) {
            try collect_ids(session.arena, &ids, field.fields, value.object);
        } else if (model.field.is_repeater(field.kind) and value == .array) {
            for (value.array.items) |item| {
                if (item == .object) {
                    try collect_ids(session.arena, &ids, field.fields, item.object);
                }
            }
        } else {
            try collect_field_ids(session.arena, &ids, field, value);
        }
    }

    const names = try type_names(session);
    var seen: std.ArrayList(fields.Referenced) = .empty;

    for (ids.items) |id| {
        const full = registry.SDK.dispatch(&session.ctx, record_operations.Get, .{
            .id = id,
            .purpose = .edit,
        }) catch continue;

        seen.append(session.arena, .{
            .id = id,
            .record = full.record,
            .type_name = name_of(names, full.record.type),
        }) catch return error.OutOfMemory;
    }

    return seen.items;
}

fn collect_ids(
    arena: std.mem.Allocator,
    ids: *std.ArrayList([]const u8),
    defs: []const model.field.Def,
    object: std.json.ObjectMap,
) Error!void {
    std.debug.assert(defs.len <= model.field.fields_max);
    std.debug.assert(ids.items.len <= fields.items_max);

    for (defs) |field| {
        const value = object.get(field.name) orelse continue;

        try collect_field_ids(arena, ids, field, value);
    }
}

fn collect_field_ids(
    arena: std.mem.Allocator,
    ids: *std.ArrayList([]const u8),
    field: model.field.Def,
    value: Value,
) Error!void {
    std.debug.assert(field.name.len > 0);
    std.debug.assert(ids.items.len <= fields.items_max);

    const kind = model.kinds.lookup(registry.Kinds.all, field.kind);

    if (!kind.has.target) {
        return;
    }

    const items: []const Value = if (value == .array) value.array.items else &.{value};

    for (items) |item| {
        if (item != .string or item.string.len == 0 or ids.items.len == fields.items_max) {
            continue;
        }

        ids.append(arena, item.string) catch return error.OutOfMemory;
    }
}

/// Every content type as (handle, name), for naming referenced records and dropdowns.
fn type_names(session: *Session) Error![]const types.Summary {
    std.debug.assert(session.signed_in());
    std.debug.assert(fields.items_max > 0);

    const listed = registry.SDK.dispatch(&session.ctx, types.List, .{}) catch return &.{};

    return listed.types;
}

fn name_of(names: []const types.Summary, handle: []const u8) []const u8 {
    std.debug.assert(handle.len > 0);
    std.debug.assert(names.len <= 4096);

    for (names) |summary| {
        if (std.mem.eql(u8, summary.handle, handle)) {
            return summary.name;
        }
    }

    return handle;
}

/// The record types every reference field may point at, by field path: the ones it
/// names, or every record type when it names none.
pub fn types_of(session: *Session, def: Def) Error![]const fields.PathTypes {
    std.debug.assert(def.fields.len <= model.field.fields_max);
    std.debug.assert(session.signed_in());

    const names = try type_names(session);
    var entries: std.ArrayList(fields.PathTypes) = .empty;

    for (def.fields) |field| {
        try add_path_types(session, &entries, names, field, "");

        for (field.fields) |child| {
            try add_path_types(session, &entries, names, child, field.name);
        }
    }

    return entries.items;
}

fn add_path_types(
    session: *Session,
    entries: *std.ArrayList(fields.PathTypes),
    names: []const types.Summary,
    field: model.field.Def,
    parent: []const u8,
) Error!void {
    std.debug.assert(field.name.len > 0);
    std.debug.assert(entries.items.len <= model.field.fields_max * model.field.fields_max);

    const kind = model.kinds.lookup(registry.Kinds.all, field.kind);

    if (!kind.has.target) {
        return;
    }

    const path = if (parent.len > 0)
        try print(session.arena, "{s}.{s}", .{ parent, field.name })
    else
        field.name;
    var options: std.ArrayList(fields.TypeOption) = .empty;

    for (names) |summary| {
        const wanted = field.options.to.len == 0 or names_target(field.options.to, summary.handle);

        if (summary.kind == .record and wanted and
            (!field.options.reference.public_only or summary.public))
        {
            options.append(session.arena, .{
                .handle = summary.handle,
                .name = summary.name,
            }) catch return error.OutOfMemory;
        }
    }

    entries.append(session.arena, .{ .path = path, .types = options.items }) catch {
        return error.OutOfMemory;
    };
}

fn names_target(handles: []const []const u8, handle: []const u8) bool {
    std.debug.assert(handles.len <= model.field.targets_max);
    std.debug.assert(handle.len > 0);

    for (handles) |candidate| {
        if (std.mem.eql(u8, candidate, handle)) {
            return true;
        }
    }

    return false;
}

/// The terms every terms field authored on the definition may select from, by path: the
/// taxonomy's tree, read once per field.
pub fn terms_of(session: *Session, def: Def) Error![]const fields.PathTerms {
    std.debug.assert(def.fields.len <= model.field.fields_max);
    std.debug.assert(session.signed_in());

    var entries: std.ArrayList(fields.PathTerms) = .empty;

    for (def.fields) |field| {
        try add_path_terms(session, &entries, field, "");

        for (field.fields) |child| {
            try add_path_terms(session, &entries, child, field.name);
        }
    }

    return entries.items;
}

fn add_path_terms(
    session: *Session,
    entries: *std.ArrayList(fields.PathTerms),
    field: model.field.Def,
    parent: []const u8,
) Error!void {
    std.debug.assert(field.name.len > 0);
    std.debug.assert(entries.items.len <= model.field.fields_max * model.field.fields_max);

    const kind = model.kinds.lookup(registry.Kinds.all, field.kind);

    if (!kind.has.taxonomy or field.locked) {
        return;
    }

    const path = if (parent.len > 0)
        try print(session.arena, "{s}.{s}", .{ parent, field.name })
    else
        field.name;
    const tree = registry.SDK.dispatch(&session.ctx, term_operations.Tree, .{
        .taxonomy = field.options.taxonomy,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else {};
    const terms = try session.arena.alloc(fields.TermOption, tree.terms.len);

    for (tree.terms, terms) |term, *option| {
        option.* = .{ .id = term.id, .title = term.title, .depth = term.depth };
    }

    entries.append(session.arena, .{ .path = path, .terms = terms }) catch {
        return error.OutOfMemory;
    };
}

/// `https://site/posts/` for a definition with an address; empty otherwise.
fn slug_prefix_of(session: *Session, def: Def) Error![]const u8 {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(session.signed_in());

    if (def.url.len == 0) {
        return "";
    }

    const base_url = try definitions.host_url_of(session);

    return print(session.arena, "{s}/{s}/", .{ base_url, def.url });
}

fn parse(arena: std.mem.Allocator, text: []const u8) ?Value {
    std.debug.assert(text.len > 0);
    std.debug.assert(fields.json_bytes_max > 0);

    const value = @import("../../lib/json.zig").parse(Value, arena, text, .{}) catch return null;

    return if (value == .object) value else null;
}

/// The version the form was rendered with; null when missing or malformed.
fn expected_version_of(form: *const Form) ?i64 {
    std.debug.assert(form.len <= admin.form_pairs_max);
    std.debug.assert(admin.form_pairs_max > 0);

    const text = form.text("expected_version") orelse return null;

    return std.fmt.parseInt(i64, text, 10) catch null;
}

test {
    std.testing.refAllDecls(@This());
}

/// The site's currencies, for its money fields; none when they cannot be read.
fn currencies_of(session: *Session) Error![]const model.money.Entry {
    std.debug.assert(session.signed_in());

    const Currencies = @import("../../operations/project/currencies.zig").Currencies;
    const listed = registry.SDK.dispatch(&session.ctx, Currencies, .{}) catch return &.{};

    return listed.currencies;
}

pub fn user_options(
    session: *Session,
    defs: []const model.field.Def,
) Error![]const @import("../../operations/user.zig").Options.Option {
    std.debug.assert(session.signed_in());

    if (!model.field.contains_kind(defs, "user")) {
        return &.{};
    }

    const got = registry.SDK.dispatch(
        &session.ctx,
        @import("../../operations/user.zig").Options,
        .{},
    ) catch |err| {
        if (err == error.OutOfMemory) {
            return error.OutOfMemory;
        }

        std.log.warn("user reference picker unavailable: {s}", .{@errorName(err)});
        return &.{};
    };
    return got.users;
}
