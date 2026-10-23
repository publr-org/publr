//! The document editor, for records and for terms: a new document of a definition, or an
//! existing one. The editor is a fragment (RecordEditor) the page wraps in its shell and
//! the drawer fetches bare; a post from the editor's script asks, by the `Publr-Fragment`
//! header, for the editor drawn again (`editor`) or for a JSON verdict (`json`, the
//! autosave) instead of a redirect. `content/form.zig` and `terms.zig` instantiate it.
const std = @import("std");
const variants_module = @import("../../operations/variants.zig");
const nouns = @import("nouns.zig");
const sdk_operation = @import("../../sdk/operation.zig");
const admin = @import("../admin.zig");
const fields = @import("fields.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const model_time = @import("../../lib/time.zig");
const editor_site = @import("editor_site.zig");
const design_hand = @import("design.zig").hand;
const types = @import("../../operations/content_type.zig");
const record_operations = @import("../../operations/record.zig");
const term_operations = @import("../../operations/term.zig");
const definitions = @import("definitions.zig");
const display = @import("display.zig");
const schema_space = @import("schema_space.zig");

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
pub const Loaded = struct {
    row: Record,
    slot: []const u8,
    document: []const u8,
    /// The transition scheduled for it (`record.transition_at`).
    scheduled: ?Scheduled = null,
};

pub const Scheduled = @import("../../operations/document/crud.zig").Scheduled;

/// What the editor is about: the definition, and the document when there is one.
pub const Shape = struct {
    def: Def,
    loaded: ?Loaded,
    /// Drawn as a preview of the definition: the form alone, nothing posts.
    preview: bool = false,
    /// Items and groups past the fold drawn open: the form's `open` values, what the
    /// browser opened before the editor was drawn again.
    open: []const []const u8 = &.{},
    /// A preview drawn up to the fold only: past it, no field.
    cut: bool = false,
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

/// The definition's schema page, where its fields are changed: empty for a settings
/// group, whose line is its description, and for a person who may not change types.
fn type_href_of(session: *Session, def: Def, taxonomy: bool) Error![]const u8 {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(session.signed_in());

    if (def.kind == .settings or !registry.SDK.may(&session.ctx, types.Create)) {
        return "";
    }

    const base = if (taxonomy)
        schema_space.Space.taxonomies.base()
    else
        schema_space.Space.content.base();
    return print(session.arena, "{s}/{s}", .{ base, def.handle });
}

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
            const plain = try seeded(session.arena, shape.def, session.ctx.now_ms);
            const document = try pointed(&session, shape.def, plain);

            try answer(&session, shape, document, &.{}, .fragment);
        }

        /// The editor as a preview of `def` for the definition's fields page: a new
        /// document with every default filled in, without the title band, the status
        /// strip and the aside.
        /// Past the fold the preview stops, unless `all` asks for every field.
        pub fn preview_node(session: *Session, def: Def, all: bool) Error!admin.render.Node {
            std.debug.assert(def.handle.len > 0);
            std.debug.assert(session.signed_in());

            const shape: Shape = .{
                .def = def,
                .loaded = null,
                .preview = true,
                .cut = !all,
            };
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
            const shape: Shape = .{
                .def = def,
                .loaded = null,
            };

            if (try reshaped(session, shape, form)) {
                return;
            }

            const form_defs = try varied(session, def.fields, .{});
            const document = fields.decode.document_of(session.arena, form_defs, form) orelse {
                return admin.fail(session, error.Invalid, back);
            };
            var in = keyed(operations.Create.In, domain.key, handle, .{
                .document = document,
            });

            if (@hasField(operations.Create.In, "parent")) {
                in.parent = form.get("parent");
            }

            const created = registry.SDK.dispatch(&session.ctx, operations.Create, in) catch |err| {
                return refused(session, shape, form, err, document);
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

            const defs = try varied(session, shape.def.fields, .{});
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
                return refused(session, shape, form, err, document);
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
            } else if (std.mem.eql(u8, verb, "decline")) {
                if (comptime !@hasDecl(operations, "DeclineRequest")) {
                    return admin.fail(session, error.Invalid, location);
                } else {
                    _ = registry.SDK.dispatch(&session.ctx, operations.DeclineRequest, .{
                        .id = id,
                    }) catch |err| return admin.fail(session, err, location);
                }
            } else if (std.mem.eql(u8, verb, "schedule") or std.mem.eql(u8, verb, "unschedule")) {
                if (comptime !@hasDecl(operations, "TransitionAt")) {
                    return admin.fail(session, error.Invalid, location);
                } else {
                    const at = if (std.mem.eql(u8, verb, "schedule"))
                        model_time.parse_datetime_local(form.text("at") orelse "") orelse {
                            return admin.fail(session, error.Invalid, location);
                        }
                    else
                        null;

                    _ = registry.SDK.dispatch(&session.ctx, operations.TransitionAt, .{
                        .id = id,
                        .transition = form.text("transition") orelse "",
                        .at = at,
                    }) catch |err| return admin.fail(session, err, location);
                }
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
                const transition = form.text("transition") orelse {
                    return admin.fail(session, error.Invalid, location);
                };

                _ = registry.SDK.dispatch(&session.ctx, operations.Transition, .{
                    .id = id,
                    .transition = transition,
                    .expected_version = expected,
                }) catch |err| return admin.fail(session, err, location);
            }

            if (fragment) {
                return answer_loaded(session, id);
            }

            try response.redirect(.see_other, location);
        }

        /// The definition a new document is of, from the query, or a not-found page.
        fn may_of(session: *Session, row: Record) May {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(session.signed_in());

            return .{
                .purge = registry.SDK.may(&session.ctx, operations.Purge),
                .publish = registry.SDK.may_on_type(
                    &session.ctx,
                    operations.Publish.name,
                    row.type,
                ),
            };
        }

        fn load_definition(session: *Session) Error!?Shape {
            std.debug.assert(session.signed_in());
            std.debug.assert(back.len > 0);

            const handle = admin.query_param(session, "type") orelse {
                try admin.fail(session, error.NotFound, back);

                return null;
            };
            const def = try definition_of(session, handle) orelse return null;

            return .{
                .def = def,
                .loaded = null,
            };
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
                .{
                    .def = def,
                    .loaded = null,
                };
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

            return .{
                .def = def,
                .loaded = .{
                    .row = row,
                    .slot = full.slot,
                    .document = full.document,
                    .scheduled = if (@hasField(@TypeOf(full), "scheduled"))
                        full.scheduled
                    else
                        null,
                },
            };
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

            const flow = shape.def.flow;
            const status = flow.find(row.status);
            const actions = try actions_of(session, flow, row, may_of(session, row));

            session.response.json(.ok, .{
                .saved = true,
                .id = row.id,
                .version = row.version,
                .title = row.title,
                .status = row.status,
                .status_label = try status_label_of(session, status, row.status),
                .changed = row.changed,
                .parks = row.changed or flow.is_live(row.status),
                .actions = actions,
                .has_destructive = has_destructive(actions),
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
            const defs = try varied(session, shape.def.fields, .{});
            const posted = fields.decode.value_of(session.arena, defs, form) catch {
                try admin.fail(session, error.Invalid, back);

                return true;
            };
            const document = fields.reshape.apply(session.arena, defs, posted, verb, form) catch {
                try admin.fail(session, error.Invalid, back);

                return true;
            };
            const how: Answer = if (wants_fragment(session)) .fragment else .page;
            var opened = shape;

            opened.open = try open_of(session.arena, form, verb);

            try answer(session, opened, document, &.{}, how);

            return true;
        }

        /// The items and groups the form keeps open past the fold, where `verb` moves them.
        fn open_of(
            arena: std.mem.Allocator,
            form: *const Form,
            verb: []const u8,
        ) Error![]const []const u8 {
            std.debug.assert(form.len <= admin.form_pairs_max);

            var open: std.ArrayList([]const u8) = .empty;

            for (form.pairs[0..form.len]) |pair| {
                if (!std.mem.eql(u8, pair.name, "open") or pair.value.len == 0) {
                    continue;
                }

                // An item moved or removed takes its place in the list with it.
                const path = try fields.reshape.moved_path(arena, pair.value, verb) orelse continue;

                open.append(arena, path) catch return error.OutOfMemory;
            }

            return open.items;
        }

        /// A refused write: the JSON reason for the autosave, else the editor again with
        /// the document's problems when it was the document, else the message page.
        fn refused(
            session: *Session,
            shape: Shape,
            form: *const Form,
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
            var open: std.ArrayList([]const u8) = .empty;
            var opened = shape;

            // An item or group past the fold holding a problem is drawn open, so it shows.
            open.appendSlice(session.arena, try open_of(session.arena, form, "")) catch {
                return error.OutOfMemory;
            };

            for (problems) |problem| {
                open.append(session.arena, problem.code) catch return error.OutOfMemory;
            }

            opened.open = open.items;

            try answer(session, opened, value, problems, how);
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
            const verdict = .{
                .saved = false,
                .reason = reason,
                // Each under its field, as the write refused them.
                .problems = if (err == error.Invalid) session.ctx.problems else &.{},
            };

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
                return session.translated("Not saved: changed elsewhere, reload the page", .{});
            }

            if (err != error.Invalid) {
                return session.translated("Not saved", .{});
            }

            if (session.ctx.problems.len > 0) {
                return session.translated("Not saved: check the marked fields", .{});
            }

            const problems = try problems_of(session, shape, document);

            if (problems.len == 0) {
                return session.translated("Not saved: the document is not valid", .{});
            }

            const first = problems[0];

            return session.translated(
                "Not saved: {field} {problem}",
                .{
                    .values = &.{
                        .{
                            .name = "field",
                            .value = first.code,
                        },
                        .{
                            .name = "problem",
                            .value = first.text,
                        },
                    },
                },
            );
        }

        fn problems_of(
            session: *Session,
            shape: Shape,
            document: []const u8,
        ) Error![]const Problem {
            std.debug.assert(document.len > 0);
            std.debug.assert(shape.def.handle.len > 0);

            const Validate = operations.Validate;
            const in = keyed(Validate.In, domain.key, shape.def.handle, .{
                .document = document,
            });
            const checked = registry.SDK.dispatch(&session.ctx, Validate, in) catch |inner| {
                try admin.fail(session, inner, back);

                return &.{};
            };
            const problems = try session.arena.alloc(Problem, checked.problems.len);

            for (checked.problems, 0..) |problem, index| {
                problems[index] = .{
                    .code = problem.path,
                    .text = problem.message,
                };
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

            const def = shape.def;

            if (def.kind == .settings) {
                return admin.screen(session, .ok, views.SettingsDocument, .{
                    .title = def.name,
                    .description = def.description,
                    .has_fields = def.fields.len > 0,
                    .schema_href = try print(arena, "/admin/structure/settings/{s}", .{def.handle}),
                    .editor = editor_panel,
                }, .{});
            }

            const title = if (shape.loaded) |full|
                (if (full.row.title.len > 0) full.row.title else full.row.id)
            else
                try session.translated("New {type}", .{
                    .values = try nouns.values(session, def),
                });

            const parents = try arena.alloc(views.RecordForm.ParentsItem, 1);

            parents[0] = .{
                .label = def.name,
                .href = try domain.crumb(arena, def),
            };

            const one_type: admin.chrome.Options = .{
                .content = .{
                    .filters = .{
                        .types = &.{def.handle},
                        .type_view = true,
                    },
                },
            };

            // A visual type's record, new or saved: the block editor fills the sheet over its
            // field. A saved one also gets its template, parts and patterns.
            const visual = model.editor.field_of(def.editor, def.editor_config, def.fields);
            const record_app = if (shape.loaded) |full| full.row.app else null;
            const none: design_hand.Handed = .{};
            const handed = if (visual != null) handed_of(session, shape, title, document) else none;

            try admin.screen(session, .ok, views.RecordForm, .{
                .title = title,
                .parents = parents,
                .focus = std.mem.eql(u8, domain.section, "content"),
                .editor = editor_panel,
                .visual_field = if (visual) |field| field.name else "",
                .editor_site = try editor_site.json(session, record_app),
                .editor_templates = handed.templates,
                .editor_patterns = handed.patterns,
            }, one_type);
        }

        /// A visual record's template, parts and patterns for the block editor, a new one's
        /// too (its type's template, drawn without a record of its own); a page that cannot
        /// read them edits without.
        fn handed_of(
            session: *Session,
            shape: Shape,
            title: []const u8,
            document: ?Value,
        ) design_hand.Handed {
            std.debug.assert(shape.def.handle.len > 0);
            std.debug.assert(session.signed_in());

            const row = if (shape.loaded) |full| full.row else null;

            return design_hand.of(session, .{
                .handle = shape.def.handle,
                .app = if (row) |known| known.app else null,
                .slug = if (row) |known| known.slug else null,
                .title = title,
                .id = if (row) |known| known.id else "",
                .entry_title = if (row) |known| known.title else "",
                .document = document,
            }) catch .{};
        }

        /// What drawing `document`'s fields needs: the records, files, terms and choices
        /// it points at, looked up once.
        fn context_of(
            session: *Session,
            shape: Shape,
            document: ?Value,
            fold: ?*fields.Fold,
        ) Error!fields.Context {
            std.debug.assert(shape.def.handle.len > 0);
            std.debug.assert(session.signed_in());

            const def = shape.def;
            const status_now = if (shape.loaded) |full| full.row.status else "";
            const live = shape.loaded != null and def.flow.is_live(status_now);

            return .{
                .arena = session.arena,
                .session = session,
                .users = try user_options(session, def.fields),
                .referenced = try referenced_of(session, def, document),
                .statuses = statuses_known(session) catch return error.OutOfMemory,
                .types = try types_of(session, def),
                .terms = try terms_of(session, def),
                .slug_prefix = try slug_prefix_of(session, def),
                .slug_prefixes = try slug_prefixes_of(session, def),
                .live = live,
                .currencies = try currencies_of(session),
                .record_id = if (shape.loaded) |full| full.row.id else "",
                .fixed = if (shape.loaded == null) fixed_of(session, def) else "",
                .delete_notes = try delete_notes_of(session, def),
                .files = try fields.media.files_of(session, def.fields, document),
                .fold = fold,
                .open = shape.open,
                .cut = shape.cut,
            };
        }

        /// The fields of an item, group or run drawn closed past the fold, as JSON for the
        /// browser to draw when it is opened: `path` (`faq[60]`, `seo`, `faq[59+]`) and
        /// `value`, what the form holds for it, saved or not.
        pub fn cells(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .post);
            std.debug.assert(ctx.user_data != null);

            var post = try admin.accept(request, response, ctx, back) orelse return;
            var session = &post.session;
            const form = &post.form;
            const handle = form.text("type") orelse return admin.fail(session, error.Invalid, back);
            const path = form.text("path") orelse return admin.fail(session, error.Invalid, back);
            const def = try definition_of(session, handle) orelse return;
            const text = form.get("value") orelse "";
            // A closed group that had no value holds nothing: its fields are drawn empty.
            const value: Value = if (text.len == 0) .null else @import("../../lib/json.zig").parse(
                Value,
                session.arena,
                text,
                .{},
            ) catch return admin.fail(session, error.Invalid, back);
            const defs = try varied(session, def.fields, .{});
            const base = path[0 .. std.mem.indexOfScalar(u8, path, '[') orelse path.len];
            var document: std.json.ObjectMap = .empty;
            var held = std.json.Array.init(session.arena);

            // Lookups (records, files) run over a document holding only this value.
            if (value == .array) {
                held.appendSlice(value.array.items) catch return error.OutOfMemory;
            } else {
                held.append(value) catch return error.OutOfMemory;
            }

            const placed: Value = if (base.len == path.len) value else .{
                .array = held,
            };

            document.put(session.arena, base, placed) catch return error.OutOfMemory;

            const shape: Shape = .{
                .def = def,
                .loaded = null,
            };
            const context = try context_of(session, shape, .{
                .object = document,
            }, null);
            const opened = fields.opened_of(context, defs, path, value) catch |err| switch (err) {
                error.Invalid => return admin.fail(session, error.Invalid, back),
                else => |other| return other,
            };

            switch (opened) {
                .cells => |list| session.response.json(.ok, .{
                    .cells = list,
                }) catch return error.OutOfMemory,
                .lines => |list| session.response.json(.ok, .{
                    .lines = list,
                }) catch return error.OutOfMemory,
            }
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
            const def = shape.def;
            var fold: fields.Fold = .{};
            const context = try context_of(session, shape, document, &fold);
            const form_defs = try varied(session, def.fields, .{
                .document = document,
            });
            const rows = try fields.rows_of(context, form_defs, document);
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
            const taxonomy = comptime std.mem.eql(u8, domain.key, "taxonomy");
            // What the form opens with; the page counts again as values are added.
            const values_count: u32 = if (document) |value|
                model.validate.values_in(value, 0)
            else
                0;
            const aside = if (shape.preview)
                null
            else
                try domain.aside(session, def, shape, document);

            if (shape.loaded) |full| {
                const row = full.row;
                const parks = row.changed or def.flow.is_live(row.status);
                const status = def.flow.find(row.status);
                const may = may_of(session, row);
                const actions = try actions_of(session, def.flow, row, may);
                const requested = try requested_of(session, def.flow, row, may);
                const scheduled = try scheduled_of(session, def.flow, row, full.scheduled);
                const versions_href = if (domain.versions)
                    try print(arena, "{s}/{s}/revisions", .{ back, row.id })
                else
                    "";
                const previewed = admin.preview_pages.page_for(session.project, row.app, row.type);
                const preview_href = if (previewed != null)
                    try print(arena, "/admin/preview/{s}", .{row.id})
                else
                    "";

                return admin.render.view(arena, views.RecordEditor, .{
                    .values_count = @floatFromInt(values_count),
                    .values_max = @floatFromInt(model.validate.values_max),
                    .group_position = @tagName(def.group.presentation.position),
                    .csrf = session.csrf_token(),
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
                    .type_href = try type_href_of(session, def, taxonomy),
                    .title = if (def.kind == .settings)
                        def.name
                    else if (row.title.len > 0)
                        row.title
                    else
                        row.id,
                    .expected_version = try print(arena, "{d}", .{row.version}),
                    .status = row.status,
                    .status_label = try status_label_of(session, status, row.status),
                    .changed = row.changed,
                    .versions_href = versions_href,
                    .preview_href = preview_href,
                    .problems = problems,
                    .actions = actions,
                    .has_destructive = has_destructive(actions),
                    .fields = field_rows,
                    .parks = parks,
                    .preview = shape.preview,
                    .stacked = !drawer and
                        model.editor.field_of(def.editor, def.editor_config, def.fields) != null,
                    .focus = def.kind != .settings,
                    .aside = aside,
                    .impact = null,
                    .languages = try languages_of(views.RecordEditor.LanguagesItem, session),
                    .request_by = requested.by,
                    .request_label = requested.label,
                    .request_transition = requested.transition,
                    .request_may_approve = requested.may_approve,
                    .request_decline_label = requested.decline_label,
                    .may_schedule = if (comptime @hasDecl(operations, "TransitionAt"))
                        registry.SDK.may(&session.ctx, operations.TransitionAt)
                    else
                        false,
                    .scheduled_label = scheduled.label,
                    .scheduled_transition = scheduled.transition,
                    .scheduled_at = scheduled.at,
                });
            }

            return admin.render.view(arena, views.RecordEditor, .{
                .values_count = @floatFromInt(values_count),
                .values_max = @floatFromInt(model.validate.values_max),
                .group_position = @tagName(def.group.presentation.position),
                .csrf = session.csrf_token(),
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
                .type_href = try type_href_of(session, def, taxonomy),
                .title = if (def.kind == .settings) def.name else try session.translated(
                    "New {type}",
                    .{
                        .values = try nouns.values(session, def),
                    },
                ),
                .expected_version = "",
                .status = "",
                .status_label = "",
                .changed = false,
                .versions_href = "",
                .preview_href = if (admin.preview_pages.page_for(
                    session.project,
                    null,
                    def.handle,
                ) != null)
                    try print(arena, "{s}?type={s}", .{ admin.preview_pages.new_path, def.handle })
                else
                    "",
                .problems = problems,
                .actions = &.{},
                .has_destructive = false,
                .fields = field_rows,
                .parks = false,
                .preview = shape.preview,
                .stacked = !drawer and
                    model.editor.field_of(def.editor, def.editor_config, def.fields) != null,
                .aside = aside,
                .impact = null,
            });
        }
    };
}

/// The status actions a document offers from where it is: publish, discard, every transition
/// its type's flow makes out of the current status, and purge for whoever may purge.
pub fn actions_of(
    session: *const Session,
    flow: model.flow.Flow,
    row: Record,
    may: May,
) Error![]const Action {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(row.status.len > 0);

    const arena = session.arena;
    const status = row.status;
    const live = flow.is_live(status);
    const publishes = !live and flow.allows(status, "published");
    var actions: std.ArrayList(Action) = .empty;

    // Someone who may not publish asks for it: the `publish` transition, kept on the record.
    const verb = if (may.publish) "do" else "transition";

    if (live and row.changed) {
        const label = if (may.publish)
            try session.translated("Publish changes", .{})
        else
            try session.translated("Ask to publish changes", .{});

        try add_action(arena, &actions, verb, "publish", label, false);
    } else if (publishes) {
        const label = if (may.publish)
            try session.translated_in("verb", "Publish")
        else
            try session.translated("Ask to publish", .{});

        try add_action(arena, &actions, verb, "publish", label, false);
    }

    if (row.changed) {
        const label = try session.translated("Discard changes", .{});

        try add_action(arena, &actions, "do", "discard", label, true);
    }

    var buffer: [model.flow.transitions_max + 1]model.flow.Target = undefined;

    for (flow.out_of(status, &buffer)) |transition| {
        // Publishing has its own button; a type's other transitions into a live status do not.
        const covered = std.mem.eql(u8, transition.to, "published") and (publishes or live) or
            (!flow.own() and flow.is_live(transition.to));

        if (covered or std.mem.eql(u8, transition.to, status)) {
            continue;
        }

        const destructive = std.mem.eql(u8, transition.name, "trash");
        const label = try session.declared(transition.label);

        try add_action(arena, &actions, "transition", transition.name, label, destructive);
    }

    if (may.purge) {
        const label = try session.translated("Purge for good", .{});

        try add_action(arena, &actions, "do", "purge", label, true);
    }

    mark_primary(actions.items);

    return actions.items;
}

/// What the person may do beyond writing: purge, and put things live.
pub const May = struct {
    purge: bool = false,
    publish: bool = false,
};

/// The transition someone asked for on a document, as the editor's bar shows it.
pub const Requested = struct {
    /// Who asked, by name; empty when nothing waits.
    by: []const u8 = "",
    label: []const u8 = "",
    transition: []const u8 = "",
    may_approve: bool = false,
    /// `Decline`, or `Withdraw` for the asker; empty when the person may do neither.
    decline_label: []const u8 = "",
};

const Schedule = struct {
    /// "Publish on 2026-11-05 09:00 UTC"; empty when none is scheduled.
    label: []const u8 = "",
    transition: []const u8 = "",
    /// When, as a `datetime-local` input holds it, UTC.
    at: []const u8 = "",
};

/// The transition scheduled for the record, as its banner says it.
fn scheduled_of(
    session: *Session,
    flow: model.flow.Flow,
    row: Record,
    scheduled: ?Scheduled,
) Error!Schedule {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(session.signed_in());

    const kept = scheduled orelse return .{};
    const label = if (flow.named(kept.transition, row.status)) |target|
        try session.declared(target.label)
    else
        kept.transition;
    const when = model_time.datetime_text(session.arena, kept.at) catch "";

    return .{
        .label = try session.translated("{transition} on {when} UTC", .{
            .values = &.{
                .{
                    .name = "transition",
                    .value = label,
                },
                .{
                    .name = "when",
                    .value = when,
                },
            },
        }),
        .transition = kept.transition,
        .at = model_time.datetime_local_text(session.arena, kept.at) catch "",
    };
}

/// The bar over a document someone asked a transition for: who, what, and what the person
/// looking may do about it.
pub fn requested_of(
    session: *Session,
    flow: model.flow.Flow,
    row: Record,
    may: May,
) Error!Requested {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(session.signed_in());

    if (row.requested.len == 0) {
        return .{};
    }

    const asker = row.requested_by orelse "";
    const own = asker.len > 0 and std.mem.eql(u8, asker, session.ctx.caller.user_id() orelse "");
    const label = if (std.mem.eql(u8, row.requested, "publish") and flow.is_live(row.status))
        try session.translated("Publish changes", .{})
    else if (flow.named(row.requested, row.status)) |target|
        try session.declared(target.label)
    else
        row.requested;

    return .{
        .by = if (own) try session.translated("You", .{}) else try asker_name(session, asker),
        .label = label,
        .transition = row.requested,
        .may_approve = may.publish,
        .decline_label = if (own)
            try session.translated("Withdraw", .{})
        else if (may.publish)
            try session.translated("Decline", .{})
        else
            "",
    };
}

fn asker_name(session: *Session, id: []const u8) Error![]const u8 {
    std.debug.assert(session.signed_in());
    std.debug.assert(id.len <= 128);

    const someone = try session.translated("Someone", .{});
    const options = @import("../../operations/user.zig").Options;
    const got = registry.SDK.dispatch(&session.ctx, options, .{
        .limit = 200,
    }) catch return someone;

    for (got.users) |user| {
        if (std.mem.eql(u8, user.id, id)) {
            return user.label;
        }
    }

    return someone;
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

/// The virtual fields whose records need this one (their reference is required and
/// single): removing one deletes it, said in the confirmation.
fn delete_notes_of(session: *Session, def: Def) Error![]const fields.DeleteNote {
    std.debug.assert(def.fields.len <= model.field.fields_max);

    var notes: std.ArrayList(fields.DeleteNote) = .empty;

    for (def.fields) |field| {
        if (!model.field.is_virtual(field.kind) or field.options.to.len != 1) {
            continue;
        }

        const got = registry.SDK.dispatch(&session.ctx, types.Get, .{
            .type = field.options.to[0],
        }) catch continue;

        for (got.definition.fields) |child_field| {
            const named = std.mem.eql(u8, child_field.name, field.options.via);

            if (named and child_field.validation.required and !child_field.many) {
                const note = try delete_note(session, got.definition.name, child_field.label);

                try notes.append(session.arena, .{
                    .field = field.name,
                    .note = note,
                });
            }
        }
    }

    return notes.items;
}

/// Why removing a record from a virtual field deletes it: it cannot be left without the
/// record it is removed from.
fn delete_note(session: *const Session, type_name: []const u8, field: []const u8) Error![]const u8 {
    std.debug.assert(type_name.len > 0);
    std.debug.assert(field.len > 0);

    const deletes = try session.translated(
        "A {type} cannot be left without its {field}, so removing it from here deletes it.",
        .{
            .values = &.{
                .{
                    .name = "type",
                    .value = type_name,
                },
                .{
                    .name = "field",
                    .value = field,
                },
            },
        },
    );
    const restore = try session.translated("You can restore it from Deleted.", .{});

    return print(session.arena, "{s} {s}", .{ deletes, restore });
}

/// The reference a virtual field's "Create new item" sets (`via`, `parent`), when the
/// type has that single reference field.
fn fixed_of(session: *Session, def: Def) []const u8 {
    std.debug.assert(def.handle.len > 0);

    const via = admin.query_param(session, "via") orelse return "";
    const parent = admin.query_param(session, "parent") orelse return "";

    for (def.fields) |field| {
        const reference = std.mem.eql(u8, field.kind, "reference") and !field.many;

        if (reference and std.mem.eql(u8, field.name, via) and parent.len > 0) {
            return field.name;
        }
    }

    return "";
}

/// A new document from a virtual field starts pointing at the record that opened it.
fn pointed(session: *Session, def: Def, document: ?Value) Error!?Value {
    std.debug.assert(def.handle.len > 0);

    const via = fixed_of(session, def);

    if (via.len == 0) {
        return document;
    }

    const parent = admin.query_param(session, "parent") orelse return document;
    var object: std.json.ObjectMap = if (document) |given| given.object else .empty;

    object.put(session.arena, via, .{
        .string = parent,
    }) catch return error.OutOfMemory;

    return .{
        .object = object,
    };
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

    return .{
        .object = object,
    };
}

fn fragment_answer(session: *Session, html: []const u8) Error!void {
    std.debug.assert(session.signed_in());
    std.debug.assert(html.len > 0);

    const accept = session.request.header("accept") orelse "";

    try session.response.set_header("Cache-Control", "private, no-store");
    try session.response.set_header("Vary", "Accept, Publr-Fragment, Publr-Drawer");

    if (std.mem.eql(u8, accept, "application/json")) {
        return session.response.json(.ok, .{
            .html = html,
        });
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

    if (ids.items.len == 0) {
        return &.{};
    }

    const names = try type_names(session);
    const wanted = ids.items[0..@min(ids.items.len, record_operations.list_max)];
    const listed = registry.SDK.dispatch(&session.ctx, record_operations.List, .{
        .ids = wanted,
        .limit = @intCast(wanted.len),
    }) catch return &.{};
    const titles = try display.titles(&session.ctx, listed.records);
    const reachable = try reached_names(session, def);
    var seen: std.ArrayList(fields.Referenced) = .empty;

    for (listed.records, titles) |record, title| {
        var shown = record;

        shown.title = title;
        try seen.append(session.arena, .{
            .id = record.id,
            .record = shown,
            .type_name = name_of(names, record.type),
            .notice = if (summary_of(reachable, record.type) == null)
                try unshared_notice(session, def)
            else
                "",
        });
    }

    for (wanted) |id| {
        if (listed_has(listed.records, id)) {
            continue;
        }

        const restricted = try restricted_card(session, names, id) orelse continue;

        try seen.append(session.arena, restricted);
    }

    return seen.items;
}

fn listed_has(listed: []const record_operations.Record, id: []const u8) bool {
    std.debug.assert(id.len > 0);
    std.debug.assert(listed.len <= record_operations.list_max);

    for (listed) |record| {
        if (std.mem.eql(u8, record.id, id)) {
            return true;
        }
    }

    return false;
}

fn summary_of(names: []const types.Summary, handle: []const u8) ?types.Summary {
    std.debug.assert(handle.len > 0);
    std.debug.assert(names.len <= 4096);

    for (names) |summary| {
        if (std.mem.eql(u8, summary.handle, handle)) {
            return summary;
        }
    }

    return null;
}

/// What a card says of a record its type's app no longer reaches.
fn unshared_notice(session: *Session, def: Def) Error![]const u8 {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(session.signed_in());

    if (def.app.len == 0) {
        return session.translated("Not a Global type", .{});
    }

    const app = session.project.find(def.app);
    const label = if (app) |found| found.spec.label else def.app;

    return session.translated(
        "No longer shared with {app}",
        .{
            .values = &.{.{
                .name = "app",
                .value = label,
            }},
        },
    );
}

/// The card of a record a reference holds that the admin cannot list: deleted (leading to
/// it in the trash while it is there), or not readable here; null when it is simply not
/// published yet.
fn restricted_card(
    session: *Session,
    names: []const types.Summary,
    id: []const u8,
) Error!?fields.Referenced {
    std.debug.assert(id.len > 0);
    std.debug.assert(session.signed_in());

    const reach = registry.SDK.dispatch(&session.ctx, record_operations.Reach, .{
        .id = id,
    }) catch return null;
    const reason = reach.reason orelse return null;
    const gone = reach.type.len == 0;
    const type_name = if (gone) "" else name_of(names, reach.type);
    const notice = switch (reason) {
        .deleted => if (gone)
            try session.translated("Deleted for good", .{})
        else
            try session.translated("Deleted, in the trash", .{}),
        .access => try session.translated("Not readable here", .{}),
        .not_shared => try session.translated("Not shared with this app", .{}),
    };

    // The admin may read a record in the trash: its card keeps its title.
    const trashed = if (reason == .deleted and !gone)
        registry.SDK.dispatch(&session.ctx, record_operations.Get, .{
            .id = id,
        }) catch null
    else
        null;
    const fallback = if (gone) try session.translated("Removed record", .{}) else type_name;
    const title = if (trashed) |got| got.record.title else fallback;

    return .{
        .id = id,
        .record = .{
            .id = id,
            .type_id = "",
            .type = reach.type,
            .status = "trashed",
            .changed = false,
            .version = 0,
            .title = if (title.len > 0) title else fallback,
            .slug = null,
            .created_by = null,
            .updated_by = null,
            .created_at = 0,
            .updated_at = 0,
        },
        .type_name = type_name,
        .notice = notice,
        .link = reason == .deleted and !gone,
    };
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

    const listed = registry.SDK.dispatch(&session.ctx, types.List, .{
        .limit = sdk_operation.page_limit_max,
    }) catch return &.{};

    return listed.types;
}

/// The content types a record of `def` may link to: what its app reaches, as the app itself
/// would, whatever app the admin is narrowed to.
fn reached_names(session: *Session, def: Def) Error![]const types.Summary {
    std.debug.assert(session.signed_in());
    std.debug.assert(def.app.len <= 64);

    // Set aside before the copy, so the copy and every later read of the request share one.
    _ = try session.ctx.scratch();

    var reach = session.ctx;

    reach.app_reach = def.app;
    reach.app_plugins = null;

    const listed = registry.SDK.dispatch(&reach, types.List, .{
        .limit = sdk_operation.page_limit_max,
    }) catch return &.{};

    if (def.app.len > 0) {
        return listed.types;
    }

    var global: std.ArrayList(types.Summary) = .empty;

    for (listed.types) |summary| {
        if (summary.app.len == 0) {
            global.append(session.arena, summary) catch return error.OutOfMemory;
        }
    }

    return global.items;
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
/// names, or every record type when it names none; of those, only the ones the type's app
/// reaches (a Global type's: Global ones).
pub fn types_of(session: *Session, def: Def) Error![]const fields.PathTypes {
    std.debug.assert(def.fields.len <= model.field.fields_max);
    std.debug.assert(session.signed_in());

    const names = try reached_names(session, def);
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

        const design = model.design.is_design(summary.handle);

        if (summary.kind == .record and wanted and !design and
            (!field.validation.reference.public_only or summary.public))
        {
            options.append(session.arena, .{
                .handle = summary.handle,
                .name = summary.name,
            }) catch return error.OutOfMemory;
        }
    }

    entries.append(session.arena, .{
        .path = path,
        .types = options.items,
    }) catch {
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
        .limit = sdk_operation.page_limit_max,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else {};
    const terms = try session.arena.alloc(fields.TermOption, tree.terms.len);

    for (tree.terms, terms) |term, *option| {
        option.* = .{
            .id = term.id,
            .title = term.title,
            .depth = term.depth,
        };
    }

    entries.append(session.arena, .{
        .path = path,
        .terms = terms,
    }) catch {
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

/// Each other language's address before a translated slug: `https://site/pl/posts/`.
fn slug_prefixes_of(session: *Session, def: Def) Error![]const fields.SlugPrefix {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(session.signed_in());

    if (def.url.len == 0) {
        return &.{};
    }

    const others = variants_module.others(&session.ctx) catch return &.{};
    const base_url = try definitions.host_url_of(session);
    const out = try session.arena.alloc(fields.SlugPrefix, others.len);

    for (others, out) |variant, *entry| {
        entry.* = .{
            .code = variant.code,
            .prefix = try print(session.arena, "{s}{s}/{s}/", .{
                base_url,
                variant.address,
                def.url,
            }),
        };
    }

    return out;
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

fn statuses_known(session: *Session) ![]const model.status.Status {
    std.debug.assert(session.signed_in());
    std.debug.assert(session.ctx.now_ms > 0);

    return @import("../../operations/status.zig").known(&session.ctx);
}

test {
    std.testing.refAllDecls(@This());
}

/// The site's currencies, for its money fields; none when they cannot be read.
fn currencies_of(session: *Session) Error![]const model.money.Entry {
    std.debug.assert(session.signed_in());

    return @import("../../sdk/site_currencies.zig").of(&session.ctx) catch &.{};
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

/// The fields as the form draws and reads them: each varied field followed by its variants
/// (`name@pl`) on a site with more than one.
pub const VariedOptions = struct {
    /// The record being edited: each variant's placeholder is its main value.
    document: ?Value = null,
};

pub fn varied(
    session: *Session,
    defs: []const model.field.Def,
    options: VariedOptions,
) Error![]const model.field.Def {
    std.debug.assert(session.signed_in());
    std.debug.assert(defs.len <= model.field.fields_max);

    const codes = try variant_codes(session);

    return fields.variants.expanded(session.arena, defs, codes, options.document);
}

/// The codes of the site's variants other than the main one; none on a site with one.
pub fn variant_codes(session: *Session) Error![]const []const u8 {
    std.debug.assert(session.signed_in());

    const others = variants_module.others(&session.ctx) catch return &.{};
    const codes = try session.arena.alloc([]const u8, others.len);

    for (others, codes) |variant, *code| {
        code.* = variant.code;
    }

    return codes;
}

/// The site's languages for the editor's switch, the main one first under an empty code.
pub fn languages_of(comptime Item: type, session: *Session) Error![]const Item {
    std.debug.assert(session.signed_in());

    const listed = variants_module.listed(&session.ctx) catch return &.{};
    const items = try session.arena.alloc(Item, listed.len);

    for (listed, items) |variant, *item| {
        item.* = .{
            .code = if (variant.main) "" else variant.code,
            .label = variant.label,
        };
    }

    return items;
}

/// A status as the person reads it: its declared label in their language, else its id.
fn status_label_of(
    session: *const Session,
    status: anytype,
    id: []const u8,
) Error![]const u8 {
    std.debug.assert(id.len > 0);

    return if (status) |known| session.declared(known.label) else id;
}
